<#
    Unit tests for Invoke-DriverAutomation.ps1 (Pester 5; also runs on Pester 4.10).
    They need no ConfigMgr, no network and no admin rights: the vendor catalogs come from
    tests\fixtures and ConfigMgr cmdlets are replaced by small stub functions.

    Run:  Invoke-Pester -Path .\tests
#>

Describe 'Invoke-DriverAutomation' {

    BeforeAll {
        $repoRoot   = Split-Path -Path $PSScriptRoot -Parent
        $scriptPath = Join-Path $repoRoot 'Invoke-DriverAutomation.ps1'
        $fixtures   = Join-Path $PSScriptRoot 'fixtures'

        # Dot-sourcing loads defaults and functions only (the script returns before its main block).
        . $scriptPath -ConfigPath (Join-Path $TestDrive 'no-config.ps1')

        $ToolRoot    = Join-Path $TestDrive 'tool'
        $LocalRoot   = Join-Path $ToolRoot 'Staging'
        $CatalogDir  = Join-Path $ToolRoot 'Catalogs'
        $ModelsFile  = Join-Path $ToolRoot 'Models.json'
        $HistoryFile = Join-Path $ToolRoot 'History.json'
        $DownloadDir = Join-Path $ToolRoot 'Downloads'

        # Fresh copies of the fixtures count as a cached catalog, so nothing is downloaded.
        New-Item -Path $CatalogDir -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtures 'lenovo-catalogv2.xml') -Destination (Join-Path $CatalogDir 'Lenovo_DriverPackCatalog.xml')
        Copy-Item -LiteralPath (Join-Path $fixtures 'dell-driverpackcatalog.xml') -Destination (Join-Path $CatalogDir 'Dell_DriverPackCatalog.xml')

        $lenovoPacks = @(ConvertFrom-LenovoCatalog -Xml (Import-XmlFile -Path (Join-Path $fixtures 'lenovo-catalogv2.xml')))
        $dellPacks   = @(ConvertFrom-DellCatalog -Xml (Import-XmlFile -Path (Join-Path $fixtures 'dell-driverpackcatalog.xml')))

        $x1   = [pscustomobject]@{ Manufacturer = 'Lenovo'; ModelName = 'ThinkPad X1 Carbon Gen 12 (Type 21KC, 21KD)'; ModelTag = 'X1_Carbon_Gen12'; MatchIds = @('21KC', '21KD') }
        $p16s = [pscustomobject]@{ Manufacturer = 'Lenovo'; ModelName = 'ThinkPad P16s Gen 3 (Type 21KS, 21KT)'; ModelTag = 'P16s_Gen3'; MatchIds = @('21KS') }
        $m70q = [pscustomobject]@{ Manufacturer = 'Lenovo'; ModelName = 'ThinkCentre M70q Gen 5 (Type 12TD, 12TE)'; ModelTag = 'M70q_Gen5'; MatchIds = @('12TD') }
        $lat  = [pscustomobject]@{ Manufacturer = 'Dell'; ModelName = 'Latitude 5450'; ModelTag = '5450'; MatchIds = @('0C9A') }
    }

    Context 'Script files' {
        It '<Name> parses without errors' -TestCases @(
            @{ Name = 'Invoke-DriverAutomation.ps1' }
            @{ Name = 'Register-DriverAutomationTask.ps1' }
            @{ Name = 'config\DriverAutomation.Config.example.ps1' }
        ) {
            param($Name)
            $errors = $null
            $path = Join-Path $repoRoot ($Name -replace '\\', [IO.Path]::DirectorySeparatorChar)
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0
        }

        It 'example config sets the three required values' {
            $exampleConfig = Join-Path (Join-Path $repoRoot 'config') 'DriverAutomation.Config.example.ps1'
            $values = & {
                . $exampleConfig
                [pscustomobject]@{ SiteServer = $SiteServer; SiteCode = $SiteCode; ShareRoot = $ShareRoot }
            }
            $values.SiteServer | Should -Not -BeNullOrEmpty
            $values.SiteCode   | Should -Match '^[A-Za-z0-9]{3}$'
            $values.ShareRoot  | Should -Match '^\\\\'
        }

        It 'example model list is valid JSON with all fields' {
            # Read it the way the toolkit does (Windows PowerShell 5.1 returns a JSON array as one object).
            $ModelsFile = Join-Path (Join-Path $repoRoot 'config') 'Models.example.json'
            $models = @(Get-ModelList)
            $models.Count | Should -Be 2
            foreach ($m in $models) {
                $m.Manufacturer | Should -Not -BeNullOrEmpty
                $m.ModelName    | Should -Not -BeNullOrEmpty
                (Test-ModelTag $m.ModelTag) | Should -BeTrue
            }
        }
    }

    Context 'Lenovo catalog parsing' {
        It 'returns only Windows 11 entries' {
            $lenovoPacks.Count | Should -Be 6
            @($lenovoPacks | Where-Object { $_.Model -like 'ThinkPad L14*' }).Count | Should -Be 0
        }

        It 'trims the URL and reads file name, hash and version' {
            $p = $lenovoPacks | Where-Object { $_.Model -like 'ThinkPad X1*' -and $_.OsVersion -eq '24H2' }
            $p.Url         | Should -Be 'https://download.lenovo.com/pccbbs/mobiles/tp_x1carbon_g12_w11_24h2_202606.exe'
            $p.FileName    | Should -Be 'tp_x1carbon_g12_w11_24h2_202606.exe'
            $p.Hash        | Should -Be '5d41402abc4b2a76b9719d911017c592'
            $p.VersionNum  | Should -Be 242
            $p.PackVersion | Should -Be '202606'
            $p.IdList      | Should -Contain '21KD'
        }

        It 'flags NVIDIA-only packs' {
            $gpu = @($lenovoPacks | Where-Object { $_.IsGpuOnly })
            $gpu.Count | Should -Be 1
            $gpu[0].FileName | Should -Match 'nvidia'
        }
    }

    Context 'Dell catalog parsing' {
        It 'skips WinPE and Windows 10-only packs' {
            @($dellPacks | Where-Object { $_.FileName -like 'WinPE*' }).Count | Should -Be 0
            @($dellPacks | Where-Object { $_.Model -like '*5420*' }).Count | Should -Be 0
        }

        It 'prefixes the brand and builds the download URL' {
            $p = $dellPacks | Where-Object { $_.PackVersion -eq 'A05' }
            $p.Model    | Should -Be 'Latitude 5450'
            $p.Url      | Should -Be 'https://downloads.dell.com/FOLDER10000002M/1/Latitude-5450-WIN11-A05-BBBB2.EXE'
            $p.Released | Should -Be '2026-09-15'
            $p.IdList   | Should -Contain '0C9A'
        }

        It 'creates one entry per model of a multi-model pack' {
            @($dellPacks | Where-Object { $_.Model -like 'OptiPlex 7020*' }).Count | Should -Be 2
        }
    }

    Context 'Catalog model list and search' {
        It 'lists only models with a usable Windows 11 pack' {
            $list = @(Get-CatalogModelList -Manufacturer Lenovo)
            $list.Count | Should -Be 3
            ($list | Where-Object { $_.Model -like 'ThinkPad P16s*' }).Win11Versions | Should -Be '23H2'
        }

        It 'finds models by name tokens (case-insensitive)' {
            $hits = @(Find-CatalogModel -List @(Get-CatalogModelList -Manufacturer Lenovo) -SearchTerm 'x1 gen 12')
            $hits.Count | Should -Be 1
        }

        It 'finds models by machine type' {
            $hits = @(Find-CatalogModel -List @(Get-CatalogModelList -Manufacturer Lenovo) -SearchTerm '21KS')
            $hits[0].Model | Should -BeLike 'ThinkPad P16s*'
        }

        It 'returns everything for an empty search' {
            @(Find-CatalogModel -List @(Get-CatalogModelList -Manufacturer Dell) -SearchTerm '').Count | Should -Be 3
        }
    }

    Context 'Resolve-DriverPack' {
        It 'picks the exact Lenovo version' {
            $r = Resolve-DriverPack -Model $x1 -WinVersion '25H2'
            $r.Match         | Should -Be 'Exact (25H2)'
            $r.Pack.FileName | Should -Be 'tp_x1carbon_g12_w11_25h2_202610.exe'
        }

        It 'falls back to the newest older Lenovo version' {
            $r = Resolve-DriverPack -Model $x1 -WinVersion '26H1'
            $r.Match     | Should -Be 'FALLBACK 25H2'
        }

        It 'skips GPU-only packs before falling back' {
            $r = Resolve-DriverPack -Model $p16s -WinVersion '24H2'
            $r.Match         | Should -Be 'FALLBACK 23H2'
            $r.Pack.FileName | Should -Not -Match 'nvidia'
        }

        It 'returns nothing when the fallback is disabled' {
            $LenovoAllowVersionFallback = $false
            Resolve-DriverPack -Model $p16s -WinVersion '24H2' | Should -BeNullOrEmpty
        }

        It 'uses an all-versions (*) Lenovo pack' {
            (Resolve-DriverPack -Model $m70q -WinVersion '25H2').Match | Should -Be 'All versions (*)'
        }

        It 'matches by machine type when the vendor renamed the model' {
            $renamed = [pscustomobject]@{ Manufacturer = 'Lenovo'; ModelName = 'Old catalog name'; ModelTag = 'X1'; MatchIds = @('21KC') }
            (Resolve-DriverPack -Model $renamed -WinVersion '25H2').Pack.Model | Should -BeLike 'ThinkPad X1 Carbon*'
        }

        It 'picks the newest Dell pack' {
            $r = Resolve-DriverPack -Model $lat -WinVersion '25H2'
            $r.Pack.PackVersion | Should -Be 'A05'
            $r.Match            | Should -Be 'Dell Win11 pack'
        }

        It 'returns nothing for an unknown model' {
            $unknown = [pscustomobject]@{ Manufacturer = 'Dell'; ModelName = 'Nope 0000'; ModelTag = 'nope'; MatchIds = @('ZZZZ') }
            Resolve-DriverPack -Model $unknown -WinVersion '25H2' | Should -BeNullOrEmpty
        }
    }

    Context 'Helpers' {
        It 'suggests ModelTag <Expected> for <Name>' -TestCases @(
            @{ Vendor = 'Lenovo'; Name = 'ThinkPad X1 Carbon Gen 12 (Type 21KC, 21KD)'; Expected = 'X1_Carbon_Gen12' }
            @{ Vendor = 'Lenovo'; Name = 'ThinkPad T16 Gen 3 Type 21MN 21MQ'; Expected = 'T16_Gen3' }
            @{ Vendor = 'Lenovo'; Name = 'ThinkCentre M70q Gen 5'; Expected = 'M70q_Gen5' }
            @{ Vendor = 'Dell'; Name = 'Latitude 5450'; Expected = '5450' }
            @{ Vendor = 'Dell'; Name = 'OptiPlex 7020 Micro'; Expected = '7020_Micro' }
        ) {
            param($Vendor, $Name, $Expected)
            Get-SuggestedModelTag -Manufacturer $Vendor -ModelName $Name | Should -Be $Expected
        }

        It 'converts Windows versions to sortable numbers' {
            ConvertTo-WinVerNum '25H2' | Should -Be 252
            ConvertTo-WinVerNum '*'    | Should -Be 0
        }

        It 'formats the YYMM stamp' {
            Get-YYMM -Date ([datetime]'2026-11-05') | Should -Be '2611'
        }

        It 'validates ModelTags' {
            Test-ModelTag 'X1_Carbon-Gen12' | Should -BeTrue
            Test-ModelTag 'with space'      | Should -BeFalse
            Test-ModelTag ''                | Should -BeFalse
        }

        It 'builds package names from the prefix table' {
            Get-PackageName -Manufacturer Lenovo -ModelId 'X1_25H2_2611' | Should -Be 'Lenovo X1_25H2_2611'
            $PackageNamePrefix = @{ Lenovo = 'ThinkPad' }
            Get-PackageName -Manufacturer Lenovo -ModelId 'X1_25H2_2611' | Should -Be 'ThinkPad X1_25H2_2611'
            Get-PackageName -Manufacturer Dell -ModelId '5450_25H2_2611' | Should -Be 'Dell 5450_25H2_2611'
        }

        It 'verifies hashes by length' {
            $file = Join-Path $TestDrive 'hash.bin'
            [IO.File]::WriteAllText($file, 'hello')
            Test-PackHash -Path $file -Expected '5d41402abc4b2a76b9719d911017c592' | Should -BeTrue
            Test-PackHash -Path $file -Expected ('0' * 64) | Should -BeFalse
            Test-PackHash -Path $file -Expected 'abc' | Should -BeNullOrEmpty
            $VerifyHash = $false
            Test-PackHash -Path $file -Expected ('0' * 64) | Should -BeNullOrEmpty
        }
    }

    Context 'Assert-BuildConfig' {
        It 'names the missing values' {
            $err = $null; try { Assert-BuildConfig } catch { $err = $_.Exception.Message }
            $err | Should -Match '\$SiteServer'
        }

        It 'rejects an invalid site code' {
            $SiteServer = 'cm01.contoso.com'; $SiteCode = 'TOOLONG'; $ShareRoot = '\\fs\share\drivers'
            $err = $null; try { Assert-BuildConfig } catch { $err = $_.Exception.Message }
            $err | Should -Match 'site code'
        }

        It 'rejects a local share path' {
            $SiteServer = 'cm01.contoso.com'; $SiteCode = 'PS1'; $ShareRoot = 'C:\Drivers'
            $err = $null; try { Assert-BuildConfig } catch { $err = $_.Exception.Message }
            $err | Should -Match 'UNC'
        }

        It 'accepts a complete configuration' {
            $SiteServer = 'cm01.contoso.com'; $SiteCode = 'PS1'; $ShareRoot = '\\fs\share\drivers'
            { Assert-BuildConfig } | Should -Not -Throw
        }
    }

    Context 'Model list and build history' {
        It 'round-trips 0, 1 and 2 models' {
            Save-ModelList -Models @()
            @(Get-ModelList).Count | Should -Be 0

            Save-ModelList -Models @($lat)
            $one = @(Get-ModelList)
            $one.Count | Should -Be 1
            $one[0].MatchIds | Should -Contain '0C9A'

            Save-ModelList -Models @($x1, $lat)
            (@(Get-ModelList) | ForEach-Object { $_.ModelTag }) -join ',' | Should -Be '5450,X1_Carbon_Gen12'
        }

        It 'appends to the build history' {
            Add-BuildHistory -Record ([pscustomobject]@{ ModelTag = 'a'; Status = 'OK' })
            Add-BuildHistory -Record ([pscustomobject]@{ ModelTag = 'b'; Status = 'OK' })
            @(Get-BuildHistory).Count | Should -Be 2
        }
    }

    Context 'Get-BuildPlan' {
        BeforeAll {
            $HistoryFile = Join-Path $TestDrive 'plan-history.json'
        }

        It 'marks packs without history as new and builds the ModelId' {
            $plan = @(Get-BuildPlan -Models @($x1) -WinVersion '25H2')
            $plan[0].IsNew   | Should -BeTrue
            $plan[0].ModelId | Should -Be ('X1_Carbon_Gen12_25H2_{0}' -f (Get-YYMM))
        }

        It 'marks an already built pack as not new' {
            $pack = (Resolve-DriverPack -Model $x1 -WinVersion '25H2').Pack
            Add-BuildHistory -Record ([pscustomobject]@{
                Date = (Get-Date -Format s); ModelTag = 'X1_Carbon_Gen12'; WinVersion = '25H2'; Status = 'OK'; Url = $pack.Url; ModelId = 'x'
            })
            (@(Get-BuildPlan -Models @($x1) -WinVersion '25H2'))[0].IsNew | Should -BeFalse
        }

        It 'skips models without a pack' {
            $unknown = [pscustomobject]@{ Manufacturer = 'Dell'; ModelName = 'Nope'; ModelTag = 'nope'; MatchIds = @() }
            @(Get-BuildPlan -Models @($unknown, $lat) -WinVersion '25H2').Count | Should -Be 1
        }
    }

    Context 'ConfigMgr helpers (stubbed)' {
        BeforeAll {
            $cmCalls = New-Object System.Collections.ArrayList
            $existingFolders = New-Object System.Collections.ArrayList
            $dpGroupExists = $true

            function Get-CMFolder { param([string]$FolderPath) if ($existingFolders -contains $FolderPath) { $FolderPath } }
            function New-CMFolder { param([string]$ParentFolderPath, [string]$Name) [void]$cmCalls.Add("folder:$ParentFolderPath\$Name") }
            function Get-CMDistributionPointGroup { param([string]$Name) if ($dpGroupExists) { [pscustomobject]@{ Name = $Name } } }
            function Get-CMDistributionPoint { @([pscustomobject]@{ ServerName = 'dp1.contoso.com' }, [pscustomobject]@{ ServerName = $null; NetworkOSPath = '\\dp2.contoso.com' }) }
            function Start-CMContentDistribution {
                param([string]$PackageId, [string]$DistributionPointGroupName, [string]$DistributionPointName)
                if (-not $PackageId) { throw 'PackageId missing' }
                if ($DistributionPointGroupName) { [void]$cmCalls.Add("group:$DistributionPointGroupName") }
                if ($DistributionPointName) { [void]$cmCalls.Add("dp:$DistributionPointName") }
            }
            $pkg = [pscustomobject]@{ PackageID = 'PS100001' }
        }

        BeforeEach {
            $cmCalls.Clear()
            $existingFolders.Clear()
        }

        It 'creates the full folder chain below Packages' {
            $CMFolderPath = 'OSD\{Manufacturer}\Drivers'
            Initialize-CMFolderPath -Manufacturer Lenovo | Should -Be 'Package\OSD\Lenovo\Drivers'
            ($cmCalls -join '|') | Should -Be 'folder:Package\OSD|folder:Package\OSD\Lenovo|folder:Package\OSD\Lenovo\Drivers'
        }

        It 'only creates missing folders' {
            [void]$existingFolders.Add('Package\Drivers')
            Initialize-CMFolderPath -Manufacturer Dell | Should -Be 'Package\Drivers\Dell'
            ($cmCalls -join '|') | Should -Be 'folder:Package\Drivers\Dell'
        }

        It 'uses the Packages root for an empty folder path' {
            $CMFolderPath = ''
            Initialize-CMFolderPath -Manufacturer Dell | Should -Be 'Package'
            $cmCalls.Count | Should -Be 0
        }

        It 'distributes to the DP group' {
            Start-PackageDistribution -PackageObject $pkg | Should -BeLike 'distributed to*'
            ($cmCalls -join '|') | Should -Be "group:$DistributionPointGroupName"
        }

        It 'does not distribute when the group is missing and the fallback is off' {
            $dpGroupExists = $false
            Start-PackageDistribution -PackageObject $pkg | Should -Be 'not distributed'
            $cmCalls.Count | Should -Be 0
        }

        It 'falls back to all DPs when enabled' {
            $dpGroupExists = $false
            $DistributeToAllDPsIfGroupMissing = $true
            Start-PackageDistribution -PackageObject $pkg | Should -Be 'distributed to 2 DP(s)'
            ($cmCalls -join '|') | Should -Be 'dp:dp1.contoso.com|dp:dp2.contoso.com'
        }
    }
}
