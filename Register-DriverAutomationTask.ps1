#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers (or removes) a scheduled task that runs the Driver Automation Toolkit unattended.

.DESCRIPTION
    The task runs:
        Invoke-DriverAutomation.ps1 -All -WinVersion <ver> -OnlyNew -RefreshCatalog [-ConfigPath <path>]
    i.e. it refreshes the Lenovo/Dell catalogs and only builds packages for models in the
    model list where the vendor has published a new Windows 11 driver pack.

    The run-as account needs:
      - ConfigMgr RBAC rights to create/distribute packages and to create console folders
      - Write access to the package share and to the model list / history location
      - Local admin on this machine (driver pack extraction, BITS)
      - Internet access to download.lenovo.com and downloads.dell.com (directly or via proxy)

.PARAMETER WinVersion
    Windows 11 version used in the package names, e.g. 25H2.
.PARAMETER GmsaAccount
    Group managed service account, e.g. 'CONTOSO\gmsa-drvauto$'. This computer must be allowed to retrieve its password.
.PARAMETER Credential
    Regular service account (Task Scheduler stores the password).
.PARAMETER DayOfWeek
    Day of the weekly run (default Monday).
.PARAMETER At
    Start time HH:mm (default 06:00).
.PARAMETER WeeksInterval
    Run every N weeks (default 1).
.PARAMETER ConfigPath
    Optional settings file passed to the toolkit. Default: the toolkit's own config\DriverAutomation.Config.ps1.
.PARAMETER Unregister
    Removes the task.

.EXAMPLE
    .\Register-DriverAutomationTask.ps1 -WinVersion 25H2 -GmsaAccount 'CONTOSO\gmsa-drvauto$'

.EXAMPLE
    .\Register-DriverAutomationTask.ps1 -WinVersion 25H2 -Credential (Get-Credential CONTOSO\svc-drvauto) -DayOfWeek Tuesday -At 05:30

.EXAMPLE
    .\Register-DriverAutomationTask.ps1 -Unregister
#>
[CmdletBinding(DefaultParameterSetName = 'Gmsa')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Gmsa')]
    [Parameter(Mandatory, ParameterSetName = 'Credential')]
    [ValidatePattern('^\d{2}H[12]$')][string]$WinVersion,

    [Parameter(Mandatory, ParameterSetName = 'Gmsa')][string]$GmsaAccount,
    [Parameter(Mandatory, ParameterSetName = 'Credential')][pscredential]$Credential,

    [Parameter(ParameterSetName = 'Gmsa')]
    [Parameter(ParameterSetName = 'Credential')]
    [System.DayOfWeek]$DayOfWeek = 'Monday',

    [Parameter(ParameterSetName = 'Gmsa')]
    [Parameter(ParameterSetName = 'Credential')]
    [ValidatePattern('^\d{2}:\d{2}$')][string]$At = '06:00',

    [Parameter(ParameterSetName = 'Gmsa')]
    [Parameter(ParameterSetName = 'Credential')]
    [ValidateRange(1, 52)][int]$WeeksInterval = 1,

    [Parameter(ParameterSetName = 'Gmsa')]
    [Parameter(ParameterSetName = 'Credential')]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Unregister,

    [string]$TaskName   = 'Driver Automation Toolkit',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Invoke-DriverAutomation.ps1')
)

$ErrorActionPreference = 'Stop'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Task '$TaskName' removed." -ForegroundColor Green
    } else {
        Write-Host "Task '$TaskName' not found." -ForegroundColor Yellow
    }
    return
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script not found: $ScriptPath" }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath

$argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -All -WinVersion {1} -OnlyNew -RefreshCatalog' -f `
            $ScriptPath, $WinVersion.ToUpper()
if ($ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
    $argument += ' -ConfigPath "{0}"' -f (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
} elseif (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Path $ScriptPath -Parent) 'config\DriverAutomation.Config.ps1'))) {
    Write-Warning 'No config\DriverAutomation.Config.ps1 found next to the script - the task will fail until it exists.'
}

$psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action   = New-ScheduledTaskAction -Execute $psExe -Argument $argument -WorkingDirectory (Split-Path -Path $ScriptPath -Parent)
$trigger  = New-ScheduledTaskTrigger -Weekly -WeeksInterval $WeeksInterval -DaysOfWeek $DayOfWeek `
                                     -At ([datetime]::ParseExact($At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture))
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -MultipleInstances IgnoreNew `
                                         -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$desc     = "Builds ConfigMgr driver packages (Lenovo/Dell, Windows 11 $($WinVersion.ToUpper())) for new OEM driver pack releases. Script: $ScriptPath"

if ($PSCmdlet.ParameterSetName -eq 'Gmsa') {
    if (-not $GmsaAccount.EndsWith('$')) { $GmsaAccount = "$GmsaAccount`$" }
    $principal = New-ScheduledTaskPrincipal -UserId $GmsaAccount -LogonType Password -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
                           -Principal $principal -Description $desc -Force | Out-Null
    $runAs = $GmsaAccount
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
                           -User $Credential.UserName -Password $Credential.GetNetworkCredential().Password `
                           -RunLevel Highest -Description $desc -Force | Out-Null
    $runAs = $Credential.UserName
}

Write-Host "Task '$TaskName' registered." -ForegroundColor Green
Write-Host ('  Runs as : {0}' -f $runAs)
Write-Host ('  Schedule: every {0} week(s), {1} {2}' -f $WeeksInterval, $DayOfWeek, $At)
Write-Host ('  Command : {0} {1}' -f $psExe, $argument)
Write-Host ''
Write-Host "Test it now with:  Start-ScheduledTask -TaskName '$TaskName'   (log: <ToolRoot>\Logs)"
