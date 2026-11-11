#requires -Version 5.1
<#
.SYNOPSIS
    Driver Automation Toolkit - Lenovo and Dell Windows 11 driver packs -> ZIP -> ConfigMgr standard package.

.DESCRIPTION
    Automates the "download OEM driver pack, extract, zip, create ConfigMgr package" workflow.

      1) Downloads the official OEM driver pack catalogs
           Lenovo : https://download.lenovo.com/cdrt/td/catalogv2.xml
           Dell   : https://downloads.dell.com/catalog/DriverPackCatalog.cab
      2) Lets you search the catalog by vendor, model name, machine type or system ID and add
         models to your own model list (Models.json), each with a short ModelTag.
      3) For the selected models and Windows 11 version:
           - resolves the matching Windows 11 driver pack from the catalog
           - downloads it (BITS, fallback Invoke-WebRequest) and verifies the catalog hash
           - extracts it to <LocalRoot>\<ModelId>\
           - compresses the extracted drivers to Drivers.zip
           - copies it to <ShareRoot>\<ModelId>\Drivers.zip
           - creates a ConfigMgr *standard* Package (not a Driver Package) in a console folder
           - distributes it to a distribution point group
             (or, if the package already exists, updates the content on the DPs)
      4) Keeps a build history (History.json) so scheduled runs only build NEW driver pack
         releases (-OnlyNew).

    Naming:
      ModelId  = <ModelTag>_<WinVersion>_<YYMM>          e.g. X1_Carbon_Gen12_25H2_2611
      Package  = "<PackageNamePrefix[Vendor]> <ModelId>"  e.g. "Lenovo X1_Carbon_Gen12_25H2_2611"

    Vendor behaviour:
      - Lenovo publishes packs per Windows 11 version (22H2, 23H2, 24H2, ...). If the requested
        version has no pack yet, the newest older pack is used (FALLBACK, see $LenovoAllowVersionFallback).
        GPU-only packs (*_nvidia_*) are ignored because they lack chipset/network drivers.
      - Dell publishes one Windows 11 pack per model (no per-version split); the newest one is used.

    Settings live in config\DriverAutomation.Config.ps1 (copy it from the .example file).
    Catalog search and model management work without it; building packages needs at least
    $SiteServer, $SiteCode and $ShareRoot.

.PARAMETER ModelTag
    Non-interactive: build only these ModelTags from the model list.
.PARAMETER All
    Non-interactive: build all models from the model list.
.PARAMETER WinVersion
    Windows 11 version label used in the ModelId, e.g. 24H2 or 25H2. Required in non-interactive mode.
.PARAMETER OnlyNew
    Skip models whose current catalog pack was already built successfully for this WinVersion.
.PARAMETER RefreshCatalog
    Force a fresh catalog download (otherwise catalogs are cached for $CatalogMaxAgeHours).
.PARAMETER PlanOnly
    Only show which driver pack would be used per model. Downloads catalogs, builds nothing.
.PARAMETER ConfigPath
    Path to the settings file. Default: config\DriverAutomation.Config.ps1 next to this script.

.EXAMPLE
    .\Invoke-DriverAutomation.ps1
    Interactive menu (search and add models, build, update check, manual build).

.EXAMPLE
    .\Invoke-DriverAutomation.ps1 -All -WinVersion 25H2 -PlanOnly
    Shows the resolved driver pack for every model, builds nothing.

.EXAMPLE
    .\Invoke-DriverAutomation.ps1 -ModelTag X1_Carbon_Gen12,5450 -WinVersion 25H2

.EXAMPLE
    .\Invoke-DriverAutomation.ps1 -All -WinVersion 25H2 -OnlyNew -RefreshCatalog
    Typical scheduled run: only builds packages when a vendor has published a new pack.

.NOTES
    Requires Windows PowerShell 5.1, the ConfigMgr console (PowerShell module), local admin
    rights for extraction and internet access to download.lenovo.com / downloads.dell.com.
    Project: https://github.com/mistermodernwork/sccm-driver-automation  (MIT License)
#>
[CmdletBinding()]
param(
    [string[]]$ModelTag,
    [switch]$All,
    [ValidatePattern('^\d{2}H[12]$')][string]$WinVersion,
    [switch]$OnlyNew,
    [switch]$RefreshCatalog,
    [switch]$PlanOnly,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\DriverAutomation.Config.ps1')
)

$ToolVersion = '1.0.0'

#region Defaults - override them in config\DriverAutomation.Config.ps1, not here
# --- ConfigMgr (required for building packages) ---
$SiteServer          = $null                    # SMS Provider, e.g. 'cm01.contoso.com'
$SiteCode            = $null                    # e.g. 'PS1'
$ShareRoot           = $null                    # package source root (UNC), e.g. '\\fileserver\Sources$\OSD\Drivers'
$CMConsoleModulePath = $null                    # optional explicit path to ConfigurationManager.psd1

# --- ConfigMgr package layout ---
$CMFolderPath      = 'Drivers\{Manufacturer}'   # console folder below "Packages"; {Manufacturer} = Lenovo / Dell
$PackageNamePrefix = @{ Lenovo = 'Lenovo'; Dell = 'Dell' }
$DistributionPointGroupName       = 'All Distribution Points'   # $null or '' = do not distribute
$DistributeToAllDPsIfGroupMissing = $false                      # fallback when the DP group does not exist

# --- Local folders ---
$ToolRoot    = 'C:\DriverAutomation'            # catalogs, downloads, logs, model list
$LocalRoot   = $null                            # extraction / staging, default <ToolRoot>\Staging
$ModelsFile  = $null                            # default <ToolRoot>\Models.json  (can live on a share for a team)
$HistoryFile = $null                            # default <ToolRoot>\History.json (used by -OnlyNew)
$CatalogDir  = $null                            # default <ToolRoot>\Catalogs
$DownloadDir = $null                            # default <ToolRoot>\Downloads
$LogDir      = $null                            # default <ToolRoot>\Logs

# --- Catalogs ---
$LenovoCatalogUrl   = 'https://download.lenovo.com/cdrt/td/catalogv2.xml'
$DellCatalogUrl     = 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
$DellDownloadBase   = 'https://downloads.dell.com/'
$CatalogMaxAgeHours = 24

$Win11Versions = @('23H2', '24H2', '25H2')      # offered in the menu, last one = default

# --- Network ---
$ProxyServer                = $null             # e.g. 'http://proxy.contoso.com:8080' ($null = system proxy, BITS first)
$ProxyUseDefaultCredentials = $true

# --- Behaviour ---
$VerifyHash                 = $true             # verify MD5/SHA1/SHA256 from the catalog (detected by length)
$LenovoSkipGpuOnlyPacks     = $true             # ignore *_nvidia_* packs (GPU drivers only)
$LenovoAllowVersionFallback = $true             # 25H2 requested, only 24H2 pack exists -> use the 24H2 pack
$CleanupStaging             = $true             # delete <LocalRoot>\<ModelId> and the local zip after publishing
$KeepDownloads              = $true             # keep vendor .exe/.cab files in Downloads as cache
$MinFreeSpaceGB             = 20                # on the drive of $LocalRoot
$LogRetentionDays           = 30
#endregion

$ConfigLoaded = $false
if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
    . $ConfigPath
    $ConfigLoaded = $true
}

if (-not $LocalRoot)   { $LocalRoot   = [IO.Path]::Combine($ToolRoot, 'Staging') }
if (-not $ModelsFile)  { $ModelsFile  = [IO.Path]::Combine($ToolRoot, 'Models.json') }
if (-not $HistoryFile) { $HistoryFile = [IO.Path]::Combine($ToolRoot, 'History.json') }
if (-not $CatalogDir)  { $CatalogDir  = [IO.Path]::Combine($ToolRoot, 'Catalogs') }
if (-not $DownloadDir) { $DownloadDir = [IO.Path]::Combine($ToolRoot, 'Downloads') }
if (-not $LogDir)      { $LogDir      = [IO.Path]::Combine($ToolRoot, 'Logs') }

$ErrorActionPreference = 'Stop'
$script:LogFile     = $null
$script:PackCache   = @{}
$script:CMConnected = $false

#region Helpers
function Write-ToolLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Step', 'Ok', 'Warn', 'Error', 'Detail')][string]$Level = 'Info'
    )
    $colors = @{ Info = 'Gray'; Step = 'Cyan'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Detail = 'DarkGray' }
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $colors[$Level]
    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Encoding UTF8 `
                -Value ('{0} [{1}] {2}' -f (Get-Date -Format s), $Level.ToUpper(), $Message)
        } catch {
            Write-Verbose "Could not write to log file: $($_.Exception.Message)"
        }
    }
}

function Write-ToolTable {
    # Renders a table with a fixed width (works without a console window, e.g. in a scheduled task)
    # and also writes it to the log file.
    param([object[]]$InputObject, [object[]]$Property = @('*'))
    $rows = @($InputObject | Where-Object { $null -ne $_ })
    if (-not $rows) { return }
    $text = ($rows | Format-Table -Property $Property -AutoSize | Out-String -Width 250).Trim("`r", "`n")
    Write-Host $text
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value $text }
        catch { Write-Verbose "Could not write to log file: $($_.Exception.Message)" }
    }
}

function Get-YYMM {
    param([datetime]$Date = (Get-Date))
    '{0:D2}{1:D2}' -f ($Date.Year % 100), $Date.Month
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function ConvertTo-WinVerNum {
    # '24H2' -> 242, '25H2' -> 252, anything else -> 0
    param([string]$Version)
    if ($Version -match '^(\d{2})H([12])$') { return ([int]$Matches[1] * 10 + [int]$Matches[2]) }
    return 0
}

function Get-XmlText {
    param($Node)
    if ($null -eq $Node) { return '' }
    if ($Node -is [array]) { $Node = $Node[0] }
    if ($Node -is [string]) { return $Node.Trim() }
    return ([string]$Node.InnerText).Trim()
}

function Import-XmlFile {
    # Honours BOM / XML declaration encoding and never resolves external entities.
    param([Parameter(Mandatory)][string]$Path)
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.Load($Path)
    return $doc
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PackageName {
    param([Parameter(Mandatory)][string]$Manufacturer, [Parameter(Mandatory)][string]$ModelId)
    $prefix = $null
    if ($PackageNamePrefix -is [hashtable]) { $prefix = $PackageNamePrefix[$Manufacturer] }
    if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = $Manufacturer }
    return ('{0} {1}' -f $prefix.Trim(), $ModelId)
}

function Assert-BuildConfig {
    # Building packages needs a configured ConfigMgr site and package share.
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($SiteServer)) { $missing += '$SiteServer' }
    if ([string]::IsNullOrWhiteSpace($SiteCode))   { $missing += '$SiteCode' }
    if ([string]::IsNullOrWhiteSpace($ShareRoot))  { $missing += '$ShareRoot' }
    if ($missing) {
        throw ("Not configured: {0}. Copy config\DriverAutomation.Config.example.ps1 to {1} and set these values." -f `
               ($missing -join ', '), $ConfigPath)
    }
    if ($SiteCode -notmatch '^[A-Za-z0-9]{3}$') { throw "`$SiteCode '$SiteCode' is not a valid 3-character site code." }
    if ($ShareRoot -notmatch '^\\\\[^\\]+\\[^\\]+') { throw "`$ShareRoot '$ShareRoot' must be a UNC path (\\server\share\...)." }
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [string]$Default)
    while ($true) {
        $a = Read-Host ('{0} [{1}] (default: {2})' -f $Prompt, ($Options -join '/'), $Default)
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        $hit = $Options | Where-Object { $_ -ieq $a.Trim() } | Select-Object -First 1
        if ($hit) { return $hit }
        Write-Host "Please enter one of: $($Options -join ', ')" -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a.Trim() -match '^(y|yes|j|ja)$')
}

function Read-WinVersion {
    $default = $Win11Versions[-1]
    while ($true) {
        $a = Read-Host ('Windows 11 version ({0}) (default: {1})' -f ($Win11Versions -join ', '), $default)
        if ([string]::IsNullOrWhiteSpace($a)) { return $default }
        $a = $a.Trim().ToUpper()
        if ($a -match '^\d{2}H[12]$') { return $a }
        Write-Host 'Format: e.g. 24H2 or 25H2' -ForegroundColor Yellow
    }
}

function Select-ListItem {
    # Out-GridView (its filter box acts as search) or, without a GUI, a numbered console list.
    param([object[]]$Items, [string]$Title, [string[]]$Columns, [switch]$Single)
    $Items = @($Items)
    if ($Items.Count -eq 0) { return }

    $i = 0
    $display = foreach ($it in $Items) {
        $i++
        $row = [ordered]@{ '#' = $i }
        foreach ($c in $Columns) { $row[$c] = $it.$c }
        [pscustomobject]$row
    }

    $useGrid = [Environment]::UserInteractive -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)
    if ($useGrid) {
        $mode   = if ($Single) { 'Single' } else { 'Multiple' }
        $picked = @($display | Out-GridView -Title $Title -OutputMode $mode)
    } else {
        Write-Host $Title -ForegroundColor Cyan
        Write-ToolTable -InputObject $display
        $ans  = Read-Host 'Select number(s), e.g. 1,3,5 (empty = cancel)'
        $nums = @($ans -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        if ($Single) { $nums = @($nums | Select-Object -First 1) }
        $picked = @($display | Where-Object { $nums -contains $_.'#' })
    }
    foreach ($p in $picked) { $Items[$p.'#' - 1] }
}

function Use-ToolLock {
    # Prevents two builds (e.g. scheduled task + interactive session) from running at the same time.
    param([Parameter(Mandatory)][scriptblock]$Action)
    New-DirectoryIfMissing -Path $ToolRoot
    $lockFile = Join-Path $ToolRoot 'run.lock'
    if (Test-Path -LiteralPath $lockFile) {
        $otherPid = (Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1) -as [int]
        if ($otherPid -and $otherPid -ne $PID -and (Get-Process -Id $otherPid -ErrorAction SilentlyContinue)) {
            throw "Another Driver Automation run is active (PID $otherPid). Lock file: $lockFile"
        }
        Write-ToolLog 'Removing stale lock file.' -Level Detail
    }
    Set-Content -LiteralPath $lockFile -Value $PID
    try { & $Action }
    finally { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
}
#endregion

#region Download
function Invoke-Download {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'   # function scope only; makes Invoke-WebRequest fast

    New-DirectoryIfMissing -Path (Split-Path -Path $OutFile -Parent)
    $part = "$OutFile.part"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }

    $done = $false
    # BITS uses the system proxy. With an explicit $ProxyServer we go straight to Invoke-WebRequest.
    if (-not $ProxyServer -and (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
        try {
            Start-BitsTransfer -Source $Url -Destination $part -Priority Foreground `
                -DisplayName 'DriverAutomation' -Description ([IO.Path]::GetFileName($Url)) -ErrorAction Stop
            $done = $true
        } catch {
            Write-ToolLog "BITS failed ($($_.Exception.Message)) - falling back to Invoke-WebRequest." -Level Detail
            Get-BitsTransfer -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'DriverAutomation' } |
                Remove-BitsTransfer -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        }
    }

    if (-not $done) {
        $iwr = @{ Uri = $Url; OutFile = $part; UseBasicParsing = $true; ErrorAction = 'Stop' }
        if ($ProxyServer) {
            $iwr.Proxy = $ProxyServer
            if ($ProxyUseDefaultCredentials) { $iwr.ProxyUseDefaultCredentials = $true }
        }
        Invoke-WebRequest @iwr
    }

    if (-not (Test-Path -LiteralPath $part)) { throw "Download failed: $Url" }
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
    return $OutFile
}

function Test-PackHash {
    # $true = match, $false = mismatch, $null = nothing to verify
    param([string]$Path, [string]$Expected)
    if (-not $VerifyHash -or [string]::IsNullOrWhiteSpace($Expected)) { return $null }
    $exp = $Expected.Trim()
    $alg = switch ($exp.Length) { 32 { 'MD5' } 40 { 'SHA1' } 64 { 'SHA256' } default { $null } }
    if (-not $alg) { return $null }
    $act = (Get-FileHash -LiteralPath $Path -Algorithm $alg).Hash
    return [bool]($act -ieq $exp)
}

function Get-DriverPackFile {
    param([Parameter(Mandatory)]$Pack)
    $target = Join-Path (Join-Path $DownloadDir $Pack.Manufacturer) $Pack.FileName

    if (Test-Path -LiteralPath $target) {
        $ok = Test-PackHash -Path $target -Expected $Pack.Hash
        if ($ok -ne $false) {
            Write-ToolLog "Using cached download: $target" -Level Detail
            return $target
        }
        Write-ToolLog 'Cached file hash mismatch - downloading again.' -Level Warn
        Remove-Item -LiteralPath $target -Force
    }

    Write-ToolLog "Downloading $($Pack.Url)" -Level Step
    Invoke-Download -Url $Pack.Url -OutFile $target | Out-Null

    $ok = Test-PackHash -Path $target -Expected $Pack.Hash
    if ($ok -eq $false) {
        Remove-Item -LiteralPath $target -Force
        throw "Hash mismatch for $($Pack.FileName). (Set `$VerifyHash = `$false only if the vendor changed the hash format.)"
    }
    $state  = if ($ok) { 'hash verified' } else { 'no hash to verify' }
    $sizeMB = [math]::Round((Get-Item -LiteralPath $target).Length / 1MB)
    Write-ToolLog "Download complete ($sizeMB MB, $state)." -Level Ok
    return $target
}
#endregion

#region Catalogs
function Get-CatalogFile {
    param([Parameter(Mandatory)][ValidateSet('Lenovo', 'Dell')][string]$Manufacturer, [switch]$Force)

    New-DirectoryIfMissing -Path $CatalogDir
    $xmlPath = Join-Path $CatalogDir ('{0}_DriverPackCatalog.xml' -f $Manufacturer)
    $isFresh = (Test-Path -LiteralPath $xmlPath) -and
               ((Get-Item -LiteralPath $xmlPath).LastWriteTime -gt (Get-Date).AddHours(-$CatalogMaxAgeHours))
    if ($isFresh -and -not $Force) { return $xmlPath }

    Write-ToolLog "Downloading $Manufacturer catalog..." -Level Step
    $tmp = "$xmlPath.new"
    try {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        if ($Manufacturer -eq 'Lenovo') {
            Invoke-Download -Url $LenovoCatalogUrl -OutFile $tmp | Out-Null
        } else {
            $cab = Join-Path $CatalogDir 'DriverPackCatalog.cab'
            Invoke-Download -Url $DellCatalogUrl -OutFile $cab | Out-Null
            $out = & expand.exe $cab $tmp 2>&1
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { throw "expand.exe failed: $out" }
            Remove-Item -LiteralPath $cab -Force -ErrorAction SilentlyContinue
        }
        Import-XmlFile -Path $tmp | Out-Null   # validate before replacing the cached catalog
        Move-Item -LiteralPath $tmp -Destination $xmlPath -Force
        $script:PackCache.Remove($Manufacturer)
        Write-ToolLog "$Manufacturer catalog updated." -Level Ok
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $xmlPath) {
            Write-ToolLog ('{0} catalog download failed ({1}). Using cached catalog from {2}.' -f `
                $Manufacturer, $_.Exception.Message, (Get-Item -LiteralPath $xmlPath).LastWriteTime) -Level Warn
        } else {
            throw "Could not download $Manufacturer catalog: $($_.Exception.Message)"
        }
    }
    return $xmlPath
}

function ConvertFrom-LenovoCatalog {
    param([Parameter(Mandatory)][xml]$Xml)
    foreach ($m in @($Xml.ModelList.Model)) {
        if (-not $m) { continue }
        $name  = ([string]$m.name).Trim()
        $types = @(@($m.Types.Type) | ForEach-Object { (Get-XmlText $_) } | Where-Object { $_ })
        foreach ($s in @($m.SCCM)) {
            if (-not $s -or $s.os -ne 'win11') { continue }
            $url = Get-XmlText $s
            if (-not $url) { continue }
            $ver   = ([string]$s.version).Trim()
            $file  = [IO.Path]::GetFileName($url)
            $stamp = if ($file -match '_(\d{6})\.exe$') { $Matches[1] } else { '' }
            [pscustomobject]@{
                Manufacturer = 'Lenovo'
                Model        = $name
                IdList       = $types
                OsVersion    = $ver
                VersionNum   = (ConvertTo-WinVerNum $ver)
                PackVersion  = $stamp
                Released     = [string]$s.date
                SortKey      = '{0} {1}' -f $stamp, [string]$s.date
                Url          = $url
                FileName     = $file
                Hash         = [string]$s.crc
                IsGpuOnly    = ($file -match '(?i)_nvidia_')
            }
        }
    }
}

function ConvertFrom-DellCatalog {
    param([Parameter(Mandatory)][xml]$Xml)
    foreach ($p in @($Xml.DriverPackManifest.DriverPackage)) {
        if (-not $p) { continue }
        $osCodes = @(@($p.SupportedOperatingSystems.OperatingSystem) | ForEach-Object { ([string]$_.osCode).Trim() })
        if (-not ($osCodes -match 'Windows11')) { continue }
        if ($osCodes -match '(?i)winpe') { continue }

        $released = ''
        try { $released = ([datetime]$p.dateTime).ToString('yyyy-MM-dd') } catch { $released = '' }
        $path    = ([string]$p.path).Trim().TrimStart('/')
        $version = ([string]$p.dellVersion).Trim()

        foreach ($brand in @($p.SupportedSystems.Brand)) {
            if (-not $brand) { continue }
            $brandName = Get-XmlText $brand.Display
            foreach ($mod in @($brand.Model)) {
                if (-not $mod) { continue }
                $name = ([string]$mod.name).Trim()
                if (-not $name) { $name = Get-XmlText $mod.Display }
                if ($brandName -and $name -notmatch [regex]::Escape($brandName)) { $name = "$brandName $name" }
                [pscustomobject]@{
                    Manufacturer = 'Dell'
                    Model        = $name
                    IdList       = @(([string]$mod.systemID).Trim())
                    OsVersion    = 'Win11'
                    VersionNum   = 0
                    PackVersion  = $version
                    Released     = $released
                    SortKey      = '{0} {1}' -f $released, $version
                    Url          = $DellDownloadBase + $path
                    FileName     = [IO.Path]::GetFileName($path)
                    Hash         = [string]$p.hashMD5
                    IsGpuOnly    = $false
                }
            }
        }
    }
}

function Get-VendorPack {
    param([Parameter(Mandatory)][ValidateSet('Lenovo', 'Dell')][string]$Manufacturer, [switch]$Refresh)
    if (-not $Refresh -and $script:PackCache.ContainsKey($Manufacturer)) { return $script:PackCache[$Manufacturer] }

    $xmlPath = Get-CatalogFile -Manufacturer $Manufacturer -Force:$Refresh
    Write-ToolLog "Indexing $Manufacturer catalog..." -Level Detail
    $xml = Import-XmlFile -Path $xmlPath
    $packs = if ($Manufacturer -eq 'Lenovo') { @(ConvertFrom-LenovoCatalog -Xml $xml) } else { @(ConvertFrom-DellCatalog -Xml $xml) }
    $script:PackCache[$Manufacturer] = $packs
    Write-ToolLog ('{0}: {1} Windows 11 driver pack entries indexed.' -f $Manufacturer, $packs.Count) -Level Detail
    return $packs
}

function Get-CatalogModelList {
    # One row per model with the available Windows 11 versions - used for search / add.
    param([Parameter(Mandatory)][ValidateSet('Lenovo', 'Dell')][string]$Manufacturer)
    $packs = @(Get-VendorPack -Manufacturer $Manufacturer)
    foreach ($g in ($packs | Group-Object -Property Model)) {
        $usable = @($g.Group | Where-Object { -not ($LenovoSkipGpuOnlyPacks -and $_.IsGpuOnly) })
        if (-not $usable) { continue }
        $newest = $usable | Sort-Object SortKey -Descending | Select-Object -First 1
        [pscustomobject]@{
            Manufacturer  = $Manufacturer
            Model         = $g.Name
            Ids           = (@($g.Group | ForEach-Object { $_.IdList } | Select-Object -Unique) -join ', ')
            Win11Versions = (@($usable | ForEach-Object { $_.OsVersion } | Select-Object -Unique | Sort-Object) -join ', ')
            LatestPack    = $newest.FileName
            Released      = $newest.Released
        }
    }
}

function Find-CatalogModel {
    # All search tokens must appear in the model name or its machine types / system IDs.
    param([object[]]$List, [string]$SearchTerm)
    $List = @($List)
    if ([string]::IsNullOrWhiteSpace($SearchTerm)) { return $List }
    $tokens = @($SearchTerm.Trim() -split '\s+' | Where-Object { $_ })
    foreach ($entry in $List) {
        $hay = "$($entry.Model) $($entry.Ids)"
        if (-not ($tokens | Where-Object { $hay -notlike "*$_*" })) { $entry }
    }
}

function Resolve-DriverPack {
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)][string]$WinVersion)

    $packs = @(Get-VendorPack -Manufacturer $Model.Manufacturer)
    $ids   = @($Model.MatchIds | Where-Object { $_ })

    # 1) exact model name, 2) machine type / system ID (survives vendor renames)
    $cand = @($packs | Where-Object { $_.Model -eq $Model.ModelName })
    if (-not $cand -and $ids) {
        $cand = @($packs | Where-Object { $pIds = $_.IdList; @($ids | Where-Object { $pIds -contains $_ }).Count -gt 0 })
    }
    if ($Model.Manufacturer -eq 'Lenovo' -and $LenovoSkipGpuOnlyPacks) {
        $cand = @($cand | Where-Object { -not $_.IsGpuOnly })
    }
    if (-not $cand) { return $null }

    if ($Model.Manufacturer -eq 'Dell') {
        $pick = $cand | Sort-Object SortKey -Descending | Select-Object -First 1
        return [pscustomobject]@{ Pack = $pick; Match = 'Dell Win11 pack' }
    }

    # Lenovo: exact version -> '*' (all versions) -> newest older version
    $exact = @($cand | Where-Object { $_.OsVersion -ieq $WinVersion })
    $match = "Exact ($WinVersion)"
    if (-not $exact) {
        $exact = @($cand | Where-Object { $_.OsVersion -eq '*' })
        $match = 'All versions (*)'
    }
    if ($exact) {
        $pick = $exact | Sort-Object SortKey -Descending | Select-Object -First 1
        return [pscustomobject]@{ Pack = $pick; Match = $match }
    }
    if ($LenovoAllowVersionFallback) {
        $req = ConvertTo-WinVerNum $WinVersion
        $fb  = $cand | Where-Object { $_.VersionNum -gt 0 -and $_.VersionNum -lt $req } |
               Sort-Object VersionNum, SortKey -Descending | Select-Object -First 1
        if ($fb) { return [pscustomobject]@{ Pack = $fb; Match = "FALLBACK $($fb.OsVersion)" } }
    }
    return $null
}
#endregion

#region Model list / history
function Get-ModelList {
    if (-not (Test-Path -LiteralPath $ModelsFile)) { return }
    $raw = Get-Content -LiteralPath $ModelsFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    foreach ($m in (ConvertFrom-Json -InputObject $raw)) { $m }
}

function Save-ModelList {
    param([object[]]$Models)
    New-DirectoryIfMissing -Path (Split-Path -Path $ModelsFile -Parent)
    $sorted = @($Models | Where-Object { $_ } | Sort-Object Manufacturer, ModelTag)
    ConvertTo-Json -InputObject $sorted -Depth 5 | Set-Content -LiteralPath $ModelsFile -Encoding UTF8
}

function Get-BuildHistory {
    if (-not (Test-Path -LiteralPath $HistoryFile)) { return }
    $raw = Get-Content -LiteralPath $HistoryFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    foreach ($h in (ConvertFrom-Json -InputObject $raw)) { $h }
}

function Add-BuildHistory {
    param([Parameter(Mandatory)]$Record)
    $all = @(Get-BuildHistory) + $Record
    New-DirectoryIfMissing -Path (Split-Path -Path $HistoryFile -Parent)
    ConvertTo-Json -InputObject @($all) -Depth 5 | Set-Content -LiteralPath $HistoryFile -Encoding UTF8
}

function Get-SuggestedModelTag {
    # "ThinkPad X1 Carbon Gen 12 (Type 21KC, 21KD)" -> "X1_Carbon_Gen12" ; "Latitude 5450" -> "5450"
    param([string]$Manufacturer, [string]$ModelName)
    $n = $ModelName -replace '\s*\(.*?\)', ''
    $n = $n -replace '(?i)\s+Types?\b.*$', ''
    $prefix = if ($Manufacturer -eq 'Lenovo') { '^(ThinkPad|ThinkCentre|ThinkStation|ThinkBook|Lenovo)\s+' }
              else { '^(Dell|Latitude|OptiPlex|Precision|Vostro|XPS)\s+' }
    for ($i = 0; $i -lt 2; $i++) { $n = $n.Trim() -replace $prefix, '' }
    $n = $n -replace '(?i)\s+Gen\s*(\d+)', '_Gen$1'
    $n = ($n.Trim() -replace '[^A-Za-z0-9_]+', '_') -replace '_{2,}', '_'
    return $n.Trim('_')
}

function Test-ModelTag {
    param([string]$Tag)
    return (-not [string]::IsNullOrWhiteSpace($Tag)) -and ($Tag -match '^[A-Za-z0-9_\-]+$')
}

function Add-ModelInteractive {
    $vendor = Read-Choice -Prompt 'Manufacturer' -Options @('Lenovo', 'Dell') -Default 'Lenovo'
    $term   = Read-Host "Search term (e.g. 'X1 Carbon Gen 12', '5450', '21KC'; empty = show all)"
    $list   = @(Find-CatalogModel -List @(Get-CatalogModelList -Manufacturer $vendor) -SearchTerm $term)
    if (-not $list) { Write-ToolLog "No Windows 11 driver packs found for '$term' ($vendor)." -Level Warn; return }

    $picked = @(Select-ListItem -Items $list -Title "$vendor - select model(s) to add" `
                                -Columns Model, Ids, Win11Versions, LatestPack, Released)
    if (-not $picked) { return }

    $models = @(Get-ModelList)
    foreach ($p in $picked) {
        $existing = $models | Where-Object { $_.Manufacturer -eq $vendor -and $_.ModelName -eq $p.Model } | Select-Object -First 1
        if ($existing) { Write-ToolLog "Already in list: $($p.Model) -> $($existing.ModelTag)" -Level Warn; continue }

        $suggest = Get-SuggestedModelTag -Manufacturer $vendor -ModelName $p.Model
        while ($true) {
            $tag = Read-Host "ModelTag for '$($p.Model)' (default: $suggest)"
            if ([string]::IsNullOrWhiteSpace($tag)) { $tag = $suggest }
            $tag = $tag.Trim()
            if (-not (Test-ModelTag $tag)) { Write-Host 'Only letters, digits, _ and - are allowed.' -ForegroundColor Yellow; continue }
            if ($models | Where-Object { $_.ModelTag -ieq $tag }) { Write-Host "ModelTag '$tag' is already used." -ForegroundColor Yellow; continue }
            break
        }

        $models += [pscustomobject]@{
            Manufacturer = $vendor
            ModelName    = $p.Model
            ModelTag     = $tag
            MatchIds     = @($p.Ids -split ',\s*' | Where-Object { $_ })
            Added        = (Get-Date -Format 'yyyy-MM-dd')
        }
        Write-ToolLog "Added: [$vendor] $($p.Model) -> $tag" -Level Ok
    }
    Save-ModelList -Models $models
}

function Edit-ModelInteractive {
    $models = @(Get-ModelList)
    if (-not $models) { Write-ToolLog 'Model list is empty. Use menu 2 to add models.' -Level Warn; return }

    Write-ToolTable -InputObject @($models | Sort-Object Manufacturer, ModelTag) `
                    -Property Manufacturer, ModelTag, ModelName, @{ n = 'Ids'; e = { $_.MatchIds -join ', ' } }, Added

    $action = Read-Choice -Prompt 'Action: (R)ename ModelTag, (D)elete, (B)ack' -Options @('R', 'D', 'B') -Default 'B'
    switch ($action) {
        'R' {
            $sel = @(Select-ListItem -Items $models -Title 'Select the model to rename' -Columns Manufacturer, ModelTag, ModelName -Single)
            if (-not $sel) { return }
            $old = $sel[0].ModelTag
            $new = (Read-Host "New ModelTag for '$old'").Trim()
            if (-not (Test-ModelTag $new)) { throw 'Only letters, digits, _ and - are allowed.' }
            if ($models | Where-Object { $_.ModelTag -ieq $new -and $_.ModelTag -ne $old }) { throw "ModelTag '$new' is already used." }
            foreach ($m in $models) { if ($m.ModelTag -eq $old) { $m.ModelTag = $new } }
            Save-ModelList -Models $models
            Write-ToolLog "Renamed: $old -> $new (existing packages keep their old name)." -Level Ok
        }
        'D' {
            $remove = @(Select-ListItem -Items $models -Title 'Select model(s) to REMOVE' -Columns Manufacturer, ModelTag, ModelName)
            if (-not $remove) { return }
            $tags = @($remove | ForEach-Object { $_.ModelTag })
            Save-ModelList -Models @($models | Where-Object { $tags -notcontains $_.ModelTag })
            Write-ToolLog "Removed: $($tags -join ', ')" -Level Ok
        }
    }
}
#endregion

#region Staging / ZIP / share
function Copy-SourceToLocal {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$LocalTarget
    )
    Write-ToolLog 'Copying source to local staging folder...' -Level Step
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Source folder not found: $Source" }
    if ([IO.Path]::GetFullPath($Source).TrimEnd('\') -ieq [IO.Path]::GetFullPath($LocalTarget).TrimEnd('\')) {
        throw "Source and target are the same: '$Source'."
    }
    if (-not (Get-ChildItem -LiteralPath $Source -Force | Select-Object -First 1)) { throw "Source folder is empty: $Source" }

    New-DirectoryIfMissing -Path $LocalTarget
    # -Path (not -LiteralPath) so the wildcard expands
    Copy-Item -Path (Join-Path $Source '*') -Destination $LocalTarget -Recurse -Force -ErrorAction Stop

    $count = (Get-ChildItem -Path $LocalTarget -Recurse -Force | Measure-Object).Count
    Write-ToolLog "Local staging contains $count items." -Level Detail
}

function Expand-DriverPack {
    param(
        [Parameter(Mandatory)][ValidateSet('Lenovo', 'Dell')][string]$Manufacturer,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) {
        Write-ToolLog "Cleaning existing staging folder: $Destination" -Level Detail
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-DirectoryIfMissing -Path $Destination

    $ext = [IO.Path]::GetExtension($File).ToLower()
    Write-ToolLog "Extracting $([IO.Path]::GetFileName($File)) to $Destination ..." -Level Step
    $exitCode = $null
    switch ($ext) {
        '.exe' {
            # Lenovo SCCM packs are Inno Setup self-extractors, Dell driver packs use the DUP format.
            $argLine = if ($Manufacturer -eq 'Lenovo') { "/VERYSILENT /SUPPRESSMSGBOXES /DIR=`"$Destination`" /EXTRACT=YES" }
                       else                             { "/s /e=`"$Destination`"" }
            $proc = Start-Process -FilePath $File -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
            $exitCode = $proc.ExitCode
            Write-ToolLog "Extractor exit code: $exitCode" -Level Detail
        }
        '.cab' {
            $out = & expand.exe $File -F:* $Destination 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw "expand.exe failed ($exitCode): $out" }
        }
        '.zip'  { Expand-Archive -LiteralPath $File -DestinationPath $Destination -Force }
        default { throw "Unsupported driver pack format: $ext" }
    }

    # Exit codes differ between vendors and pack generations - the real check is whether drivers came out.
    $infCount = @(Get-ChildItem -LiteralPath $Destination -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue).Count
    if ($infCount -eq 0) { throw "Extraction produced no .inf files in '$Destination' (exit code $exitCode)." }
    Write-ToolLog "Extracted: $infCount .inf files." -Level Ok
}

function New-DriverZip {
    param([Parameter(Mandatory)][string]$SourceFolder, [Parameter(Mandatory)][string]$ZipPath)

    $infCount = @(Get-ChildItem -LiteralPath $SourceFolder -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue).Count
    if ($infCount -eq 0) { throw "No .inf files in '$SourceFolder' - nothing to package." }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

    # The ZIP is written next to the staging folder (no self-inclusion); content sits at the ZIP root.
    Write-ToolLog "Creating ZIP: $ZipPath" -Level Step
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceFolder, $ZipPath, [IO.Compression.CompressionLevel]::Fastest, $false)

    $sizeMB = [math]::Round((Get-Item -LiteralPath $ZipPath).Length / 1MB)
    Write-ToolLog "ZIP ready ($sizeMB MB, $infCount .inf files)." -Level Ok
}

function Publish-ToShare {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ModelId
    )
    if (-not (Test-Path -LiteralPath $ShareRoot)) { throw "Share root not accessible: $ShareRoot" }

    $destFolder = Join-Path $ShareRoot $ModelId
    New-DirectoryIfMissing -Path $destFolder

    $destZip = Join-Path $destFolder 'Drivers.zip'
    $tmpZip  = "$destZip.part"
    Write-ToolLog "Copying ZIP to share: $destZip" -Level Step
    Copy-Item -LiteralPath $ZipPath -Destination $tmpZip -Force -ErrorAction Stop
    if ((Get-Item -LiteralPath $tmpZip).Length -ne (Get-Item -LiteralPath $ZipPath).Length) {
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        throw "Size mismatch after copy to share: $destZip"
    }
    # Swap in only once the copy is complete, so DPs never pick up a half-written file.
    Move-Item -LiteralPath $tmpZip -Destination $destZip -Force
    return $destFolder
}
#endregion

#region ConfigMgr
function Connect-CM {
    if ($script:CMConnected) { return }
    Write-ToolLog 'Loading ConfigurationManager module...' -Level Step

    if (-not (Get-Module -Name ConfigurationManager)) {
        $candidates = @()
        if ($CMConsoleModulePath) { $candidates += $CMConsoleModulePath }
        if ($Env:SMS_ADMIN_UI_PATH) {
            # SMS_ADMIN_UI_PATH points to ...\AdminConsole\bin\i386; the module sits one level up.
            $uiBin = Split-Path -Path $Env:SMS_ADMIN_UI_PATH -Parent
            $candidates += (Join-Path $uiBin 'ConfigurationManager.psd1')
        }
        $candidates += @(
            "$Env:ProgramFiles\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1",
            "${Env:ProgramFiles(x86)}\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
        )
        $module = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if (-not $module) { throw 'ConfigurationManager module not found. Install the ConfigMgr console or set $CMConsoleModulePath.' }
        Import-Module $module -ErrorAction Stop
    }

    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
    }
    $script:CMConnected = $true
    Write-ToolLog "Connected to site '$SiteCode' on '$SiteServer'." -Level Ok
}

function Initialize-CMFolderPath {
    # Creates the console folder chain below "Packages" and returns its path (e.g. 'Package\Drivers\Lenovo').
    # Must run while the location is on the site drive.
    param([Parameter(Mandatory)][string]$Manufacturer)
    $current  = 'Package'
    $relative = ([string]$CMFolderPath -replace '\{Manufacturer\}', $Manufacturer).Trim('\', ' ')
    if (-not $relative) { return $current }
    foreach ($segment in @($relative -split '\\' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $next = "$current\$segment"
        if (-not (Get-CMFolder -FolderPath $next -ErrorAction SilentlyContinue)) {
            New-CMFolder -ParentFolderPath $current -Name $segment | Out-Null
        }
        $current = $next
    }
    return $current
}

function Move-PackageToFolder {
    param([Parameter(Mandatory)]$PackageObject, [Parameter(Mandatory)][string]$FolderPath)
    if ($FolderPath -eq 'Package') { return }
    try {
        Write-ToolLog "Moving package to console folder '$FolderPath'..." -Level Step
        Move-CMObject -InputObject $PackageObject -FolderPath ('{0}:\{1}' -f $SiteCode, $FolderPath) | Out-Null
    } catch {
        Write-ToolLog "Move-CMObject failed - the package stays in the Packages root. Error: $($_.Exception.Message)" -Level Warn
    }
}

function Start-PackageDistribution {
    # Returns a short status text for the summary.
    param([Parameter(Mandatory)]$PackageObject)

    if ($DistributionPointGroupName) {
        $grp = Get-CMDistributionPointGroup -Name $DistributionPointGroupName -ErrorAction SilentlyContinue
        if ($grp) {
            Write-ToolLog "Distributing to DP group '$DistributionPointGroupName'." -Level Step
            Start-CMContentDistribution -PackageId $PackageObject.PackageID -DistributionPointGroupName $DistributionPointGroupName | Out-Null
            return "distributed to '$DistributionPointGroupName'"
        }
        Write-ToolLog "DP group '$DistributionPointGroupName' not found." -Level Warn
    }

    if (-not $DistributeToAllDPsIfGroupMissing) {
        Write-ToolLog 'Package was NOT distributed (no DP group; $DistributeToAllDPsIfGroupMissing is off).' -Level Warn
        return 'not distributed'
    }

    $dps = @(Get-CMDistributionPoint)
    if (-not $dps) { throw 'No distribution points found in the site.' }
    foreach ($dp in $dps) {
        $dpName = if ($dp.ServerName) { $dp.ServerName } else { ($dp.NetworkOSPath -replace '^\\\\', '') }
        Start-CMContentDistribution -PackageId $PackageObject.PackageID -DistributionPointName $dpName | Out-Null
        Write-ToolLog "Distribution triggered to DP: $dpName" -Level Detail
    }
    return "distributed to $($dps.Count) DP(s)"
}

function Publish-CMContentPackage {
    param(
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][string]$WinVersion,
        [Parameter(Mandatory)][string]$ShareModelFolder,
        [Parameter(Mandatory)][ValidateSet('Lenovo', 'Dell')][string]$Manufacturer,
        [Parameter(Mandatory)][string]$Description
    )
    $pkgName = Get-PackageName -Manufacturer $Manufacturer -ModelId $ModelId

    # All CM cmdlets run on the site drive; file system work (UNC paths) stays outside.
    Push-Location -Path "$($SiteCode):\"
    try {
        $existing = Get-CMPackage -Name $pkgName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($existing) {
            Write-ToolLog "Package '$pkgName' ($($existing.PackageID)) already exists - updating content on DPs." -Level Warn
            Set-CMPackage -InputObject $existing -Description $Description -ErrorAction SilentlyContinue | Out-Null
            Update-CMDistributionPoint -PackageId $existing.PackageID | Out-Null
            return [pscustomobject]@{ Package = $existing; Action = 'content updated (existing package)' }
        }

        Write-ToolLog "Creating ConfigMgr package: $pkgName" -Level Step
        $pkg = New-CMPackage -Name $pkgName -Description $Description -Manufacturer $Manufacturer `
                             -Version $WinVersion -Path $ShareModelFolder
        $folder = Initialize-CMFolderPath -Manufacturer $Manufacturer
        Move-PackageToFolder -PackageObject $pkg -FolderPath $folder
        $dist = Start-PackageDistribution -PackageObject $pkg
        Write-ToolLog "Package $($pkg.PackageID) '$pkgName' created." -Level Ok
        return [pscustomobject]@{ Package = $pkg; Action = "created, $dist" }
    } finally {
        Pop-Location
    }
}
#endregion

#region Pipeline
function Invoke-PackagePipeline {
    # The staging folder already contains the extracted drivers -> ZIP -> share -> ConfigMgr package
    param(
        [Parameter(Mandatory)][ValidateSet('Lenovo', 'Dell')][string]$Manufacturer,
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][string]$WinVersion,
        [Parameter(Mandatory)][string]$StagingFolder,
        [string]$SourceInfo
    )
    $zipPath = Join-Path $LocalRoot ('{0}_Drivers.zip' -f $ModelId)
    New-DriverZip -SourceFolder $StagingFolder -ZipPath $zipPath

    $shareFolder = Publish-ToShare -ZipPath $zipPath -ModelId $ModelId

    $desc = "Driver content for $ModelId ($WinVersion), ZIP; created $(Get-Date -Format 'yyyy-MM-dd HH:mm'); $SourceInfo"
    if ($desc.Length -gt 127) { $desc = $desc.Substring(0, 127) }

    Connect-CM
    $cm = Publish-CMContentPackage -ModelId $ModelId -WinVersion $WinVersion -ShareModelFolder $shareFolder `
                                   -Manufacturer $Manufacturer -Description $desc

    if ($CleanupStaging) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StagingFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $cm
}

function Test-FreeSpace {
    New-DirectoryIfMissing -Path $LocalRoot
    $root   = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($LocalRoot))
    $freeGB = [math]::Round(([IO.DriveInfo]::new($root)).AvailableFreeSpace / 1GB, 1)
    if ($freeGB -lt $MinFreeSpaceGB) { throw "Only $freeGB GB free on $root (minimum $MinFreeSpaceGB GB)." }
}

function Get-BuildPlan {
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][string]$WinVersion
    )
    $yymm    = Get-YYMM
    $history = @(Get-BuildHistory)
    foreach ($m in $Models) {
        $r = Resolve-DriverPack -Model $m -WinVersion $WinVersion
        if (-not $r) {
            Write-ToolLog "[$($m.ModelTag)] No Windows 11 driver pack in the $($m.Manufacturer) catalog for '$($m.ModelName)'." -Level Warn
            continue
        }
        $last = $history |
                Where-Object { $_.ModelTag -eq $m.ModelTag -and $_.WinVersion -eq $WinVersion -and $_.Status -eq 'OK' } |
                Sort-Object Date -Descending | Select-Object -First 1
        [pscustomobject]@{
            ModelTag  = $m.ModelTag
            Vendor    = $m.Manufacturer
            ModelId   = '{0}_{1}_{2}' -f $m.ModelTag, $WinVersion, $yymm
            Match     = $r.Match
            PackFile  = $r.Pack.FileName
            Released  = $r.Pack.Released
            IsNew     = ((-not $last) -or ($last.Url -ne $r.Pack.Url))
            LastBuild = if ($last) { $last.ModelId } else { '-' }
            Model     = $m
            Pack      = $r.Pack
        }
    }
}

function Invoke-DriverPackBuild {
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][string]$WinVersion,
        [switch]$OnlyNew,
        [switch]$PlanOnly,
        [switch]$Interactive
    )
    Write-ToolLog "Resolving driver packs for Windows 11 $WinVersion ..." -Level Step
    $plan = @(Get-BuildPlan -Models $Models -WinVersion $WinVersion)
    if (-not $plan) { Write-ToolLog 'Nothing to do.' -Level Warn; return }

    Write-ToolTable -InputObject $plan -Property ModelTag, Vendor, ModelId, Match, PackFile, Released, IsNew, LastBuild
    if ($PlanOnly) { Write-ToolLog 'PlanOnly - nothing was built.' -Level Ok; return }

    if ($OnlyNew) {
        $plan = @($plan | Where-Object { $_.IsNew })
    } elseif ($Interactive -and ($plan | Where-Object { -not $_.IsNew })) {
        if (-not (Read-YesNo -Prompt 'Some packs were already built (IsNew = False). Rebuild them anyway?')) {
            $plan = @($plan | Where-Object { $_.IsNew })
        }
    }
    if (-not $plan) { Write-ToolLog 'All selected models are up to date - nothing to build.' -Level Ok; return }
    if ($Interactive -and -not (Read-YesNo -Prompt ('Build {0} package(s) now?' -f $plan.Count) -Default $true)) { return }

    Assert-BuildConfig
    if (-not (Test-IsAdministrator)) { throw 'Building packages needs an elevated session (driver pack extraction).' }
    Test-FreeSpace
    Connect-CM    # fail early if the console is missing

    $results = Use-ToolLock -Action {
        foreach ($item in $plan) {
            $tag = $item.ModelTag
            Write-ToolLog ('=' * 70) -Level Detail
            Write-ToolLog "[$tag] $($item.Vendor) $($item.Model.ModelName) -> $($item.ModelId)" -Level Step
            if ($item.Match -like 'FALLBACK*') {
                Write-ToolLog "[$tag] Lenovo has no $WinVersion pack yet - using the $($item.Pack.OsVersion) pack." -Level Warn
            }

            $status = 'OK'; $msg = ''; $pkgId = ''
            try {
                $file  = Get-DriverPackFile -Pack $item.Pack
                $stage = Join-Path $LocalRoot $item.ModelId
                Expand-DriverPack -Manufacturer $item.Vendor -File $file -Destination $stage
                $cm = Invoke-PackagePipeline -Manufacturer $item.Vendor -ModelId $item.ModelId -WinVersion $WinVersion `
                                             -StagingFolder $stage -SourceInfo ('src: {0}' -f $item.Pack.FileName)
                $pkgId = $cm.Package.PackageID
                $msg   = $cm.Action
                if (-not $KeepDownloads) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            } catch {
                $status = 'FAILED'
                $msg    = $_.Exception.Message
                Write-ToolLog "[$tag] FAILED: $msg" -Level Error
            }

            Add-BuildHistory -Record ([pscustomobject]@{
                Date          = (Get-Date -Format s)
                ModelTag      = $tag
                WinVersion    = $WinVersion
                ModelId       = $item.ModelId
                Status        = $status
                Url           = $item.Pack.Url
                PackFile      = $item.Pack.FileName
                PackOsVersion = $item.Pack.OsVersion
                PackageId     = $pkgId
                Message       = $msg
            })
            [pscustomobject]@{ ModelTag = $tag; ModelId = $item.ModelId; Status = $status; PackageId = $pkgId; Result = $msg }
        }
    }

    Write-ToolLog ('=' * 70) -Level Detail
    Write-ToolLog 'Summary:' -Level Step
    Write-ToolTable -InputObject @($results)
    return $results
}
#endregion

#region Interactive actions
function Invoke-BuildInteractive {
    param([switch]$PlanOnly)
    $models = @(Get-ModelList)
    if (-not $models) { Write-ToolLog 'Model list is empty. Use menu 2 to add models first.' -Level Warn; return }
    $sel = @(Select-ListItem -Items $models -Title 'Select model(s)' -Columns Manufacturer, ModelTag, ModelName)
    if (-not $sel) { return }
    $winVer = Read-WinVersion
    Invoke-DriverPackBuild -Models $sel -WinVersion $winVer -Interactive -PlanOnly:$PlanOnly | Out-Null
}

function Invoke-UpdateCheckInteractive {
    $models = @(Get-ModelList)
    if (-not $models) { Write-ToolLog 'Model list is empty. Use menu 2 to add models first.' -Level Warn; return }
    $winVer = Read-WinVersion
    foreach ($v in @($models | ForEach-Object { $_.Manufacturer } | Select-Object -Unique)) {
        Get-VendorPack -Manufacturer $v -Refresh | Out-Null
    }
    Invoke-DriverPackBuild -Models $models -WinVersion $winVer -OnlyNew -Interactive | Out-Null
}

function Invoke-ManualBuild {
    # Already extracted driver folder -> same ZIP / share / ConfigMgr pipeline
    Assert-BuildConfig
    $source = Read-Host 'Source driver folder (full path)'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Source folder not found: $source" }

    $tag = ("" + (Read-Host 'ModelTag (e.g. X1_Carbon_Gen12 or 5450)')).Trim()
    if (-not (Test-ModelTag $tag)) { throw 'ModelTag is required (letters, digits, _ and - only).' }

    $known = @(Get-ModelList) | Where-Object { $_.ModelTag -ieq $tag } | Select-Object -First 1
    $manufacturer = if ($known) { $known.Manufacturer } else { Read-Choice -Prompt 'Manufacturer' -Options @('Lenovo', 'Dell') -Default 'Lenovo' }
    $winVer  = Read-WinVersion
    $modelId = '{0}_{1}_{2}' -f $tag, $winVer, (Get-YYMM)
    Write-ToolLog "Model ID: $modelId" -Level Ok

    Test-FreeSpace
    Use-ToolLock -Action {
        $stage = Join-Path $LocalRoot $modelId
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        Copy-SourceToLocal -Source $source -LocalTarget $stage

        $cm = Invoke-PackagePipeline -Manufacturer $manufacturer -ModelId $modelId -WinVersion $winVer `
                                     -StagingFolder $stage -SourceInfo 'src: manual'
        Add-BuildHistory -Record ([pscustomobject]@{
            Date = (Get-Date -Format s); ModelTag = $tag; WinVersion = $winVer; ModelId = $modelId; Status = 'OK'
            Url = "manual:$source"; PackFile = ''; PackOsVersion = ''; PackageId = $cm.Package.PackageID; Message = $cm.Action
        })
        Write-ToolLog "Done: $($cm.Package.PackageID) - $($cm.Action)" -Level Ok
    }
}

function Show-Menu {
    while ($true) {
        $count = @(Get-ModelList).Count
        $site  = if ($SiteCode -and $SiteServer) { "$SiteCode @ $SiteServer" } else { 'not configured' }
        Write-Host ''
        Write-Host "=== Driver Automation Toolkit $ToolVersion ===" -ForegroundColor Cyan
        Write-Host "    Models: $count  |  Site: $site  |  Staging: $LocalRoot" -ForegroundColor DarkGray
        Write-Host '  1  Refresh vendor catalogs (Lenovo + Dell)'
        Write-Host '  2  Search catalog & add model(s)'
        Write-Host '  3  Show / rename / remove my models'
        Write-Host '  4  Build driver packages (select models + Windows 11 version)'
        Write-Host '  5  Check for new driver pack releases & build only new ones'
        Write-Host '  6  Show plan only (which pack would be used, builds nothing)'
        Write-Host '  7  Manual build from an extracted driver folder'
        Write-Host '  Q  Quit'
        $choice = ("" + (Read-Host 'Select')).Trim().ToUpper()
        try {
            switch ($choice) {
                '1' { foreach ($v in @('Lenovo', 'Dell')) { Get-VendorPack -Manufacturer $v -Refresh | Out-Null } }
                '2' { Add-ModelInteractive }
                '3' { Edit-ModelInteractive }
                '4' { Invoke-BuildInteractive }
                '5' { Invoke-UpdateCheckInteractive }
                '6' { Invoke-BuildInteractive -PlanOnly }
                '7' { Invoke-ManualBuild }
                'Q' { return }
                default { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
            }
        } catch {
            Write-ToolLog "Error: $($_.Exception.Message)" -Level Error
        }
    }
}
#endregion

# Dot-sourcing (". .\Invoke-DriverAutomation.ps1") only loads the functions - used by the tests.
if ($MyInvocation.InvocationName -eq '.') { return }

# -------- Main --------
New-DirectoryIfMissing -Path $ToolRoot
New-DirectoryIfMissing -Path $LogDir
$script:LogFile = Join-Path $LogDir ('DriverAutomation_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Get-ChildItem -LiteralPath $LogDir -Filter 'DriverAutomation_*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$startLocation = Get-Location
$exitCode      = 0
Write-ToolLog "Driver Automation Toolkit $ToolVersion" -Level Detail
if ($ConfigLoaded) { Write-ToolLog "Config: $ConfigPath" -Level Detail }
else { Write-ToolLog "No config file at $ConfigPath - catalog search works, building packages needs it." -Level Warn }
Write-ToolLog "Model list: $ModelsFile" -Level Detail

try {
    if ($ModelTag -or $All) {
        # ---- Non-interactive (scheduled task) ----
        if (-not $WinVersion) { throw '-WinVersion is required in non-interactive mode (e.g. -WinVersion 25H2).' }
        $WinVersion = $WinVersion.ToUpper()

        $models = @(Get-ModelList)
        if ($ModelTag) {
            $unknown = @($ModelTag | Where-Object { $t = $_; -not ($models | Where-Object { $_.ModelTag -ieq $t }) })
            if ($unknown) { Write-ToolLog "Unknown ModelTag(s) (not in the model list): $($unknown -join ', ')" -Level Warn }
            $models = @($models | Where-Object { $t = $_.ModelTag; $ModelTag | Where-Object { $_ -ieq $t } })
        }
        if (-not $models) { throw "No matching models in $ModelsFile." }

        if ($RefreshCatalog) {
            foreach ($v in @($models | ForEach-Object { $_.Manufacturer } | Select-Object -Unique)) {
                Get-VendorPack -Manufacturer $v -Refresh | Out-Null
            }
        }
        $res = @(Invoke-DriverPackBuild -Models $models -WinVersion $WinVersion -OnlyNew:$OnlyNew -PlanOnly:$PlanOnly)
        if ($res | Where-Object { $_.Status -eq 'FAILED' }) { $exitCode = 1 }
    } else {
        # ---- Interactive ----
        if ($RefreshCatalog) { foreach ($v in @('Lenovo', 'Dell')) { Get-VendorPack -Manufacturer $v -Refresh | Out-Null } }
        Show-Menu
    }
}
catch {
    Write-ToolLog $_.Exception.Message -Level Error
    $exitCode = 1
}
finally {
    Set-Location $startLocation
    Write-ToolLog "Log: $script:LogFile" -Level Detail
}
exit $exitCode
