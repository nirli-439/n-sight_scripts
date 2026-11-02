<#
.SYNOPSIS
    Verifies Windows automatically locks an inactive session within 15 minutes.

.DESCRIPTION
    Checks the machine-wide Interactive logon: Machine inactivity limit policy.
    A value from 1 through 900 seconds is compliant; 900 seconds is 15 minutes.
    This policy locks the workstation, independent of the user profile running
    the N-Sight agent. Standard users cannot change this machine policy.
    An AD GPO, when present, remains the authoritative enforcement source.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_ScreenLock_Timeout.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_ScreenLock_Timeout.ps1")

.OUTPUTS
    Exit 0    = compliant
    Exit 1002 = missing, disabled, or over 15 minutes
#>

$ErrorActionPreference = 'Stop'
$ExitCritical = 1002
$MaxTimeoutSeconds = 900
$PolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'CRITICAL: Administrator privileges required'
    exit $ExitCritical
}

try {
    $timeout = (Get-ItemProperty -Path $PolicyPath -Name InactivityTimeoutSecs -ErrorAction Stop).InactivityTimeoutSecs
    if ($timeout -is [int] -and $timeout -gt 0 -and $timeout -le $MaxTimeoutSeconds) {
        Write-Host "OK: Screen locks after $timeout seconds (maximum 900 seconds)"
        exit 0
    }

    $current = if ($null -eq $timeout -or $timeout -eq 0) { 'disabled or not configured' } else { "$timeout seconds" }
    Write-Host "CRITICAL: Screen lock timeout is $current; maximum is 900 seconds"
    exit $ExitCritical
}
catch {
    Write-Host "CRITICAL: Could not read machine inactivity policy - $($_.Exception.Message)"
    exit $ExitCritical
}
