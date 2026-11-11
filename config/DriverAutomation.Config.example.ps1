# ---------------------------------------------------------------------------
# DriverAutomation.Config.example.ps1
#
# Copy this file to "DriverAutomation.Config.ps1" in the same folder and adjust it.
# Invoke-DriverAutomation.ps1 loads it on start. The copy is excluded from git
# (.gitignore), so your environment details never end up in the repository.
#
# Only the three values in the first block are required. Everything else is
# optional - uncomment a line to override the default.
# ---------------------------------------------------------------------------

# --- Required for building packages ---
$SiteServer = 'cm01.contoso.com'                     # SMS Provider (usually the primary site server)
$SiteCode   = 'PS1'
$ShareRoot  = '\\fileserver.contoso.com\Sources$\OSD\Drivers'

# --- ConfigMgr package layout ---
# Console folder below "Packages". {Manufacturer} becomes Lenovo or Dell.
# $CMFolderPath = 'Drivers\{Manufacturer}'           # e.g. 'OSD\{Manufacturer}\Drivers'
# Package name = "<prefix> <ModelId>", e.g. "Lenovo X1_Carbon_Gen12_25H2_2611"
# $PackageNamePrefix = @{ Lenovo = 'Lenovo'; Dell = 'Dell' }
# $DistributionPointGroupName       = 'All Distribution Points'   # $null = do not distribute
# $DistributeToAllDPsIfGroupMissing = $false
# $CMConsoleModulePath = 'D:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'

# --- Local folders ---
# $ToolRoot  = 'D:\DriverAutomation'                 # catalogs, downloads, logs, model list (needs a few GB)
# $LocalRoot = 'D:\DriverAutomation\Staging'         # extraction / staging (default: <ToolRoot>\Staging)

# --- Shared model list for a team ---
# $ModelsFile  = '\\fileserver.contoso.com\Sources$\OSD\Drivers\_DriverAutomation\Models.json'
# $HistoryFile = '\\fileserver.contoso.com\Sources$\OSD\Drivers\_DriverAutomation\History.json'

# --- Windows 11 versions offered in the menu (last = default) ---
# $Win11Versions = @('24H2', '25H2')

# --- Proxy (default: system proxy via BITS, fallback Invoke-WebRequest) ---
# $ProxyServer                = 'http://proxy.contoso.com:8080'
# $ProxyUseDefaultCredentials = $true

# --- Behaviour ---
# $VerifyHash                 = $true                # set to $false only if a vendor changes its hash format
# $LenovoSkipGpuOnlyPacks     = $true
# $LenovoAllowVersionFallback = $true                # 25H2 requested, only 24H2 pack exists -> use 24H2
# $CleanupStaging             = $true
# $KeepDownloads              = $true
# $MinFreeSpaceGB             = 20
# $CatalogMaxAgeHours         = 24
# $LogRetentionDays           = 30
