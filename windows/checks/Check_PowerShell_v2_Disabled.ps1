<#
.SYNOPSIS
    Check if PowerShell v2 Windows feature is disabled.
    
.DESCRIPTION
    This security monitoring script checks if the PowerShell v2 Windows Optional Feature
    is disabled. PowerShell v2 is a security risk because it:
    - Lacks AMSI (Antimalware Scan Interface) integration
    - Bypasses PowerShell script block logging
    - Bypasses constrained language mode
    - Can be used by attackers to evade modern security controls
    
    Designed for N-Sight RMM security compliance monitoring.
    
    Exit Codes:
    - 0 = PASS (PowerShell v2 is disabled - secure configuration)
    - 1 = FAIL (PowerShell v2 is enabled - security risk)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_PowerShell_v2_Disabled.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_PowerShell_v2_Disabled.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_PowerShell_v2_Disabled.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11, Windows Server 2016+
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\PowerShellV2Check_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "PowerShell v2 Security Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "FAIL: Script requires administrator privileges"
    exit 1001
}

try {
    # Check PowerShell v2 feature status
    Write-Log "Checking MicrosoftWindowsPowerShellV2 feature state..."
    
    $feature = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2 -ErrorAction SilentlyContinue
    
    if ($null -eq $feature) {
        # Feature not found - could be Windows Server Core or feature not available
        Write-Log "PowerShell v2 feature not found on this system" -Level "WARNING"
        Write-Log "This may be Windows Server Core or a stripped-down Windows edition"
        Write-Log "=========================================="
        
        Write-Host ""
        Write-Host "PASS: PowerShell v2 feature not present on this system"
        Write-Host "Computer: $env:COMPUTERNAME"
        
        exit 0
    }
    
    Write-Log "Feature Name: $($feature.FeatureName)"
    Write-Log "Feature State: $($feature.State)"
    
    if ($feature.State -eq "Disabled") {
        Write-Log "Security Status: COMPLIANT - PowerShell v2 is disabled"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "PASS: PowerShell v2 is disabled"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Feature State: $($feature.State)"
        
        exit 0
    }
    else {
        Write-Log "Security Status: NON-COMPLIANT - PowerShell v2 is enabled" -Level "WARNING"
        Write-Log "Recommendation: Disable PowerShell v2 to improve security posture"
        Write-Log "Command to disable: Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "FAIL: PowerShell v2 is enabled"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Feature State: $($feature.State)"
        Write-Host "Security Risk: PowerShell v2 can bypass modern security controls"
        Write-Host "Remediation: Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2"
        
        exit 1001
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "FAIL: PowerShell v2 check failed - $_"
    Write-Host "Computer: $env:COMPUTERNAME"
    
    exit 1001
}

