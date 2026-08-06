<#
.SYNOPSIS
    Check if OpenSSH Server is installed and running.

.DESCRIPTION
    This monitoring script checks for OpenSSH Server (Windows capability, Win32-OpenSSH MSI, or Program Files):
    - Windows capability OpenSSH.Server* Installed, or
    - sshd service present and running, or
    - sshd.exe in System32\OpenSSH or Program Files\OpenSSH
    Matches detection logic in Install_OpenSSH.ps1 and New_Employee_Readiness_Check.ps1.

    Exit Codes:
    - 0    = OK (OpenSSH Server installed and running)
    - 1001 = Warning (installed but service not running or service not found)
    - 1002 = Critical (OpenSSH Server NOT installed)

.EXECUTION
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_OpenSSH.ps1")
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_OpenSSH.ps1"
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"
$ScriptName = "Check_OpenSSH"
$LogFile = "$env:TEMP\${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# Installed = capability OR sshd service OR sshd.exe in known paths (same as Install_OpenSSH.ps1 / readiness check)
function Get-OpenSSHStatus {
    $result = @{
        Installed = $false
        ServiceFound = $false
        ServiceRunning = $false
        Details = $null
    }

    $sshCapability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object Name -like 'OpenSSH.Server*'
    if ($sshCapability -and $sshCapability.State -eq "Installed") {
        $result.Installed = $true
    }
    $sshdService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($sshdService) {
        $result.ServiceFound = $true
        $result.Installed = $true
        $result.ServiceRunning = ($sshdService.Status -eq "Running")
        $result.Details = "Status: $($sshdService.Status) | StartType: $($sshdService.StartType)"
    }
    if (-not $result.Installed) {
        $sshdBinary = Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe" -ErrorAction SilentlyContinue -or
                      Test-Path "${env:ProgramFiles}\OpenSSH\sshd.exe" -ErrorAction SilentlyContinue -or
                      Test-Path "${env:ProgramFiles(x86)}\OpenSSH\sshd.exe" -ErrorAction SilentlyContinue
        if ($sshdBinary) {
            $result.Installed = $true
            $result.Details = "Binary found (sshd service may need to be installed/started)"
        }
    }
    if ($result.Installed -and -not $result.Details) {
        $result.Details = "Capability or binary present"
    }
    return $result
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "OpenSSH Server check - $env:COMPUTERNAME"

$status = Get-OpenSSHStatus

if (-not $status.Installed) {
    Write-Log "OpenSSH Server is NOT installed" -Level "WARN"
    Write-Host "CRITICAL: OpenSSH Server is NOT installed. Run Install_OpenSSH.ps1 or install via Settings > Optional features."
    exit $EXIT_CRITICAL
}

if ($status.ServiceFound -and -not $status.ServiceRunning) {
    Write-Log "OpenSSH Server installed but sshd not running" -Level "WARN"
    Write-Host "WARNING: OpenSSH Server is installed but sshd is not running. $($status.Details)"
    exit $EXIT_WARNING
}

if ($status.Installed -and -not $status.ServiceFound) {
    Write-Log "OpenSSH Server binaries/capability present but sshd service not found" -Level "WARN"
    Write-Host "WARNING: OpenSSH Server appears installed but sshd service is missing. Run Install_OpenSSH.ps1. $($status.Details)"
    exit $EXIT_WARNING
}

Write-Log "OpenSSH Server is installed and running. $($status.Details)"
Write-Host "OK: OpenSSH Server is installed and running. $($status.Details)"
exit $EXIT_SUCCESS
