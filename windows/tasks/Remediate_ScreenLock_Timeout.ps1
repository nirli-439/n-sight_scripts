<#
.SYNOPSIS
    Configure screen lock timeout to meet security policy (3 min battery, 8 min AC).

.DESCRIPTION
    Sets screen saver with password protection and timeout so the check passes:
    - Check requires: AC <= 8 minutes, DC (battery) <= 3 minutes.
    - This script sets timeout to 3 minutes (180 seconds) so both AC and DC are compliant.
    Also configures Machine Inactivity Limit (Group Policy) when possible.

    Aligns with Check_ScreenLock_Timeout.ps1 compliance rules.
    Designed for N-Sight RMM.

.EXECUTION
    Windows (local):  iex (Get-Content ".\Remediate_ScreenLock_Timeout.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remediate_ScreenLock_Timeout.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remediate_ScreenLock_Timeout.ps1")
.NOTES
    Author: IT Admin
    Version: 1.1
    Requires: Administrator
    Platform: Windows 10/11, Windows Server 2016+
    Exit: 0 = Success, 1002 = Critical
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Remediate_ScreenLock_Timeout_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Use 3 minutes so both AC (<=8min) and DC (<=3min) are compliant
$TimeoutSeconds = 180   # 3 minutes

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "Screen Lock Timeout Remediation"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "Setting timeout to $TimeoutSeconds seconds (3 minutes)"

try {
    # 1) GPO-style policy (HKCU) - enforces screen saver for user
    $PolicyPath = "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop"
    if (-not (Test-Path $PolicyPath)) {
        New-Item -Path $PolicyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $PolicyPath -Name "ScreenSaveActive"    -Value "1" -Type String -Force
    Set-ItemProperty -Path $PolicyPath -Name "ScreenSaveTimeOut"   -Value $TimeoutSeconds.ToString() -Type String -Force
    Set-ItemProperty -Path $PolicyPath -Name "ScreenSaverIsSecure" -Value "1" -Type String -Force
    Write-Log "Set GPO screen saver policy: enabled, ${TimeoutSeconds}s, password required"

    # 2) Current user desktop (so it takes effect immediately)
    $DesktopPath = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $DesktopPath -Name "ScreenSaveActive"    -Value "1" -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $DesktopPath -Name "ScreenSaveTimeOut"   -Value $TimeoutSeconds.ToString() -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $DesktopPath -Name "ScreenSaverIsSecure" -Value "1" -Type String -Force -ErrorAction SilentlyContinue
    Write-Log "Set current user desktop screen saver: ${TimeoutSeconds}s"

    # 3) Machine Inactivity Limit (HKLM) - "Interactive logon: Machine inactivity limit"
    $SecurityPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    if (Test-Path $SecurityPath) {
        Set-ItemProperty -Path $SecurityPath -Name "InactivityTimeoutSecs" -Value $TimeoutSeconds -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Log "Set Machine Inactivity Limit: ${TimeoutSeconds}s"
    }

    Write-Log "Remediation completed successfully" -Level "INFO"
    Write-Host ""
    Write-Host "SUCCESS: Screen lock timeout set to 3 minutes (180 seconds). AC and DC compliant."
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Re-run Check_ScreenLock_Timeout.ps1 to verify."
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Remediation failed: $_" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    Write-Host ""
    Write-Host "FAIL: Screen lock remediation failed - $_"
    Write-Host "Computer: $env:COMPUTERNAME"
    exit $EXIT_CRITICAL
}
