<#
.SYNOPSIS
    Enforces a 15-minute inactive-session lock on Windows.

.DESCRIPTION
    Sets Interactive logon: Machine inactivity limit to 900 seconds. This is a
    machine-wide policy, so standard users cannot change it and N-Sight can run
    it as SYSTEM. An AD GPO is authoritative and will override this local policy.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remediate_ScreenLock_Timeout.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Remediate_ScreenLock_Timeout.ps1")

.OUTPUTS
    Exit 0    = configured and verified
    Exit 1002 = could not configure or verify
#>

$ErrorActionPreference = 'Stop'
$ExitCritical = 1002
$TimeoutSeconds = 900
$PolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'CRITICAL: Administrator privileges required'
    exit $ExitCritical
}

try {
    New-Item -Path $PolicyPath -Force | Out-Null
    New-ItemProperty -Path $PolicyPath -Name InactivityTimeoutSecs -PropertyType DWord -Value $TimeoutSeconds -Force | Out-Null

    if ((Get-ItemPropertyValue -Path $PolicyPath -Name InactivityTimeoutSecs) -ne $TimeoutSeconds) {
        throw 'Policy verification failed'
    }

    Write-Host "OK: Screen lock timeout set to $TimeoutSeconds seconds (15 minutes)"
    exit 0
}
catch {
    Write-Host "CRITICAL: Could not set screen lock timeout - $($_.Exception.Message)"
    exit $ExitCritical
}
