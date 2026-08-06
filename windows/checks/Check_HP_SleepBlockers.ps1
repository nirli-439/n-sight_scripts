<#
.SYNOPSIS
    Check if HP/print services known to block sleep are stopped and disabled.

.DESCRIPTION
    Detects HPPrintScanDoctorService, Print Spooler (spooler), and Windows Search
    (WSearch) running or set to Automatic — any of which can prevent the machine
    from entering sleep via active wake timers or power requests.

    Exit Codes:
    - 0    = PASS  (all three services stopped + non-Automatic)
    - 1001 = FAIL  (one or more services still active or Automatic)

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_HP_SleepBlockers.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_HP_SleepBlockers.ps1")

.NOTES
    Author:   IT Admin
    Version:  1.0
    Ref:      IA-805
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# Services that must be stopped + not Automatic for healthy sleep
$targets = @("HPPrintScanDoctorService", "spooler", "WSearch")

$failures = @()

foreach ($name in $targets) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { continue }   # not installed = not a problem

    $startMode = (Get-WmiObject Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue).StartMode

    $running  = $svc.Status -eq "Running"
    $autoStart = $startMode -eq "Auto"

    if ($running -or $autoStart) {
        $failures += "$name (Status=$($svc.Status), StartMode=$startMode)"
    }
}

if ($failures.Count -eq 0) {
    Write-Host "PASS: No HP/print sleep-blocking services are active."
    exit 0
} else {
    Write-Host "FAIL: The following services may block sleep:"
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1001
}
