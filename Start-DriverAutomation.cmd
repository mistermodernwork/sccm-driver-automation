@echo off
rem Starts the Driver Automation Toolkit (interactive menu) in Windows PowerShell 5.1.
rem Run it from an elevated command prompt (or "Run as administrator").
rem Additional arguments are passed through, e.g.:
rem   Start-DriverAutomation.cmd -All -WinVersion 25H2 -PlanOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-DriverAutomation.ps1" %*
if errorlevel 1 pause
