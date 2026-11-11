# Driver Automation Toolkit for ConfigMgr

[![CI](https://github.com/mistermodernwork/sccm-driver-automation/actions/workflows/ci.yml/badge.svg)](https://github.com/mistermodernwork/sccm-driver-automation/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A PowerShell toolkit that downloads **Windows 11 driver packs from Lenovo and Dell**, zips them, and publishes
each one as a **standard ConfigMgr package** (not a Driver Package), ready for your task sequence.

You search the OEM catalogs by model name, machine type or system ID, keep your own list of models, and
let the toolkit build packages on demand or on a schedule. Only new driver pack releases are rebuilt.

```
OEM catalog ──► pick model ──► download + hash check ──► extract ──► Drivers.zip ──► share ──► ConfigMgr package ──► DPs
```

## Why a standard package with a ZIP?

Driver Packages import every driver into the ConfigMgr driver catalog, which grows large and slow over time.
A standard package that contains a single `Drivers.zip` per model is faster to distribute, keeps the site
database small, and lets the task sequence apply exactly the drivers of one model (see
[Using the packages in a task sequence](#using-the-packages-in-a-task-sequence)).

## Features

- Searches the official catalogs ([Lenovo catalogv2.xml](https://download.lenovo.com/cdrt/td/catalogv2.xml),
  [Dell DriverPackCatalog](https://downloads.dell.com/catalog/DriverPackCatalog.cab))
- Keeps your model list in a JSON file, which you can share with a team
- Picks the right pack per Windows 11 version, falling back to the newest older Lenovo pack if needed
- Ignores Lenovo GPU-only (`*_nvidia_*`) packs, which lack chipset and network drivers
- Downloads via BITS with an `Invoke-WebRequest` fallback, supports an explicit proxy, and verifies catalog hashes
- Creates console folders, places the package and distributes it to a DP group
- Updates the content of an existing package instead of creating a duplicate
- Build history plus `-OnlyNew` for unattended runs, a lock against parallel runs, and log retention
- `-PlanOnly` shows which pack would be used, without building anything
- Comes with a scheduled task helper (gMSA or service account)

## Requirements

| | |
|---|---|
| OS / shell | Windows, **Windows PowerShell 5.1** |
| ConfigMgr | Console installed (for the `ConfigurationManager` module); rights to create and distribute packages and console folders |
| Rights | Local administrator (driver pack extraction) |
| Share | Write access to the package source share |
| Network | HTTPS to `download.lenovo.com` and `downloads.dell.com` (direct or via proxy) |
| Disk | A few GB per model (download, extracted, ZIP); default minimum 20 GB free |

## Quick start

```powershell
git clone https://github.com/mistermodernwork/sccm-driver-automation.git
cd sccm-driver-automation
Copy-Item .\config\DriverAutomation.Config.example.ps1 .\config\DriverAutomation.Config.ps1
notepad .\config\DriverAutomation.Config.ps1      # set $SiteServer, $SiteCode, $ShareRoot
```

Then start `Start-DriverAutomation.cmd` **as administrator**, or run `.\Invoke-DriverAutomation.ps1` from an elevated
Windows PowerShell.

`config\DriverAutomation.Config.ps1` is ignored by git, so your environment details stay out of the repository.

## Menu

```
=== Driver Automation Toolkit 1.0.0 ===
  1  Refresh vendor catalogs (Lenovo + Dell)
  2  Search catalog & add model(s)
  3  Show / rename / remove my models
  4  Build driver packages (select models + Windows 11 version)
  5  Check for new driver pack releases & build only new ones
  6  Show plan only (which pack would be used, builds nothing)
  7  Manual build from an extracted driver folder
  Q  Quit
```

**Add models (2).** Choose the vendor and type a search term, for example `X1 Carbon Gen 12`, `5450` or the
machine type `21KC`. Select one or more models in the grid. The toolkit suggests a short **ModelTag**
(`X1_Carbon_Gen12`, `5450`), which you can accept or change.

**Build (4).** Select models and a Windows 11 version. You first get a plan that shows the pack, whether it falls
back to another version and whether it is new. Building starts after you confirm.

**Manual build (7).** Use this for a driver folder you already extracted yourself. It goes through the same
ZIP, share and package steps.

## The model list

The model list is `Models.json`, by default in `C:\DriverAutomation\`. An entry looks like this:

```json
{
  "Manufacturer": "Lenovo",
  "ModelName": "ThinkPad X1 Carbon Gen 12 (Type 21KC, 21KD)",
  "ModelTag": "X1_Carbon_Gen12",
  "MatchIds": ["21KC", "21KD"],
  "Added": "2026-11-01"
}
```

`ModelName` and `MatchIds` tie the entry to the catalog. If a vendor renames a model, the machine types and
system IDs in `MatchIds` still find it. `ModelTag` is your short name and goes into the package name.

To share one list across a team, point `$ModelsFile` and `$HistoryFile` to a file share in your config.

## Naming

| | Format | Example |
|---|---|---|
| ModelId | `<ModelTag>_<WinVersion>_<YYMM>` | `X1_Carbon_Gen12_25H2_2611` |
| Package | `<PackageNamePrefix> <ModelId>` | `Lenovo X1_Carbon_Gen12_25H2_2611` |
| Content | `<ShareRoot>\<ModelId>\Drivers.zip` | |
| Console folder | `Packages\<CMFolderPath>` | `Packages\Drivers\Lenovo` |

If you rebuild in the same month, the toolkit replaces the ZIP and updates the DPs. It does not create a
second package.

## Configuration

All settings go into `config\DriverAutomation.Config.ps1`. Use `-ConfigPath` to load a different file.

| Setting | Default | Purpose |
|---|---|---|
| `$SiteServer` | *(required)* | SMS Provider, e.g. `cm01.contoso.com` |
| `$SiteCode` | *(required)* | Site code, e.g. `PS1` |
| `$ShareRoot` | *(required)* | Package source root (UNC) |
| `$CMFolderPath` | `Drivers\{Manufacturer}` | Console folder below *Packages* |
| `$PackageNamePrefix` | `@{ Lenovo = 'Lenovo'; Dell = 'Dell' }` | Package name prefix per vendor |
| `$DistributionPointGroupName` | `All Distribution Points` | DP group; `$null` = do not distribute |
| `$DistributeToAllDPsIfGroupMissing` | `$false` | Use every DP if the group does not exist |
| `$ToolRoot` | `C:\DriverAutomation` | Catalogs, downloads, logs, model list |
| `$LocalRoot` | `<ToolRoot>\Staging` | Extraction / staging |
| `$ModelsFile` / `$HistoryFile` | `<ToolRoot>\*.json` | Model list / build history |
| `$Win11Versions` | `23H2, 24H2, 25H2` | Menu choices (last = default) |
| `$ProxyServer` | `$null` | Explicit proxy; otherwise the system proxy via BITS |
| `$VerifyHash` | `$true` | Verify the catalog hash of each download |
| `$LenovoSkipGpuOnlyPacks` | `$true` | Ignore NVIDIA-only packs |
| `$LenovoAllowVersionFallback` | `$true` | Use an older Lenovo pack if the version is missing |
| `$CleanupStaging` | `$true` | Remove the extracted files and local ZIP after publishing |
| `$KeepDownloads` | `$true` | Keep vendor downloads as a cache |
| `$MinFreeSpaceGB` | `20` | Minimum free space for staging |
| `$CatalogMaxAgeHours` | `24` | Catalog cache lifetime |
| `$LogRetentionDays` | `30` | Log cleanup |

## Unattended runs

```powershell
# Show what would be built
.\Invoke-DriverAutomation.ps1 -All -WinVersion 25H2 -PlanOnly

# Build two models
.\Invoke-DriverAutomation.ps1 -ModelTag X1_Carbon_Gen12,5450 -WinVersion 25H2

# Scheduled: refresh catalogs, build only new driver pack releases
.\Invoke-DriverAutomation.ps1 -All -WinVersion 25H2 -OnlyNew -RefreshCatalog
```

The exit code is `1` if any model failed. Logs go to `<ToolRoot>\Logs`.

To register a weekly scheduled task, run this from an elevated prompt:

```powershell
.\Register-DriverAutomationTask.ps1 -WinVersion 25H2 -GmsaAccount 'CONTOSO\gmsa-drvauto$'
.\Register-DriverAutomationTask.ps1 -WinVersion 25H2 -Credential (Get-Credential) -DayOfWeek Tuesday -At 05:30
.\Register-DriverAutomationTask.ps1 -Unregister
```

## Vendor behaviour

**Lenovo** publishes SCCM packs per Windows 11 version. If there is no pack for the requested version yet, the
newest older one is used, and the plan shows it as `FALLBACK`. You can turn this off with
`$LenovoAllowVersionFallback = $false`.

**Dell** publishes one Windows 11 pack per model, without a split per feature update. The newest pack is used,
and the Windows version you choose only goes into the name.

## Using the packages in a task sequence

Here is one common pattern, placed after *Apply Operating System* in WinPE (requires the WinPE PowerShell
component):

1. **Download Package Content**: select the model's package and save the path in the variable `DRIVERS`.
   Add a WMI condition for the model, for example:
   - Lenovo: `SELECT * FROM Win32_ComputerSystemProduct WHERE Version LIKE "%X1 Carbon Gen 12%"`
   - Dell: `SELECT * FROM Win32_ComputerSystem WHERE Model LIKE "%Latitude 5450%"`
2. **Run Command Line** (expand):
   `powershell.exe -ExecutionPolicy Bypass -Command "Expand-Archive -Path '%DRIVERS01%\Drivers.zip' -DestinationPath '%_SMSTSMDataPath%\Drivers' -Force"`
3. **Run Command Line** (inject):
   `DISM.exe /Image:%OSDTargetSystemDrive%\ /Add-Driver /Driver:%_SMSTSMDataPath%\Drivers /Recurse`

## Troubleshooting

| Message | Cause / fix |
|---|---|
| `Not configured: $SiteServer ...` | Create `config\DriverAutomation.Config.ps1` from the example |
| `ConfigurationManager module not found` | Install the ConfigMgr console or set `$CMConsoleModulePath` |
| `Could not download ... catalog` | Check internet / proxy, set `$ProxyServer` if needed |
| `Hash mismatch` | Retry. If it hits every pack of one vendor, the vendor may have changed its hash format: `$VerifyHash = $false` |
| `Extraction produced no .inf files` | Corrupt download or new pack format. Delete the file in `Downloads` and retry, or use menu 7 |
| `No Windows 11 driver pack ... for '<model>'` | The model has no Windows 11 pack yet, or the vendor changed its IDs. Add the model again |
| `Another Driver Automation run is active` | A scheduled run is in progress. Wait, or delete `<ToolRoot>\run.lock` if that process no longer exists |
| `Package was NOT distributed` | The DP group does not exist. Fix `$DistributionPointGroupName` or enable the fallback |

## Development

The tests need no ConfigMgr and no network. They parse the trimmed catalogs in `tests\fixtures` and replace
the ConfigMgr cmdlets with stubs.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

Dot-sourcing the script (`. .\Invoke-DriverAutomation.ps1`) loads its functions without starting the menu.

## Limitations

- Lenovo and Dell only (no HP or Microsoft Surface yet)
- Older packages are never deleted. Each month with a new pack produces a new package, so retire old ones yourself
- Package content is a ZIP, so the task sequence has to expand it (see above)

## Disclaimer

This is not an official Lenovo, Dell or Microsoft tool. Test it in a lab first. It is provided as is, without
warranty; see [LICENSE](LICENSE).
