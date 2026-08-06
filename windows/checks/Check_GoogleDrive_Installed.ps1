<#
.SYNOPSIS
    Check if Google Drive is installed on the system.

.DESCRIPTION
    This monitoring script checks for Google Drive system-wide (machine) installation and reports:
    - Installation status (installed/not installed)
    - Google Drive version and path if installed
    Only Program Files and machine registry are checked; user-level installs are ignored.
    Designed for N-Sight RMM monitoring checks.

    Exit Codes:
    - 0 = OK (Google Drive is installed)
    - 2 = Critical (Google Drive is NOT installed)

.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_GoogleDrive_Installed.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_GoogleDrive_Installed.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_GoogleDrive_Installed.ps1")
.NOTES
    Author: IT Admin
    Version: 1.2
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\GoogleDriveCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Get-GoogleDriveInstallInfo {
    <#
    .SYNOPSIS
        Checks for Google Drive installation and returns info
    #>
    $result = @{
        Installed = $false
        Path      = $null
        Version   = $null
        InstallType = $null
    }

    # Check 1: System-wide installation in Program Files only
    $machinePaths = @(
        "${env:ProgramFiles}\Google\Drive File Stream\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\Drive File Stream\GoogleDriveFS.exe",
        "${env:ProgramFiles}\Google\DriveFS\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\DriveFS\GoogleDriveFS.exe"
    )

    foreach ($path in $machinePaths) {
        if (Test-Path $path) {
            $result.Installed = $true
            $result.Path = $path
            $result.InstallType = "Machine (Program Files)"
            try {
                $fileInfo = Get-Item $path
                $result.Version = $fileInfo.VersionInfo.ProductVersion
            } catch {
                $result.Version = "Unknown"
            }
            return $result
        }
    }

    # Check 2: Machine registry only (HKLM) - no user (HKCU) registry
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($regPath in $regPaths) {
        try {
            $regItems = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*Google Drive*" -or $_.DisplayName -like "*Drive File Stream*" }
            if ($regItems) {
                $regItem = $regItems | Select-Object -First 1
                $result.Installed = $true
                $result.Version = $regItem.DisplayVersion
                $result.Path = $regItem.InstallLocation
                $result.InstallType = "Machine (Registry)"
                return $result
            }
        } catch { }
    }

    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Google Drive Installation Check (system-wide only)"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "CRITICAL: Script requires administrator privileges"
    exit 1002
}

try {
    $googleDriveInfo = Get-GoogleDriveInstallInfo

    if ($googleDriveInfo.Installed) {
        Write-Log "Google Drive Status: INSTALLED"
        Write-Log "Path: $($googleDriveInfo.Path)"
        Write-Log "Version: $($googleDriveInfo.Version)"
        Write-Log "Install Type: $($googleDriveInfo.InstallType)"
        Write-Log "=========================================="

        Write-Host ""
        Write-Host "OK: Google Drive is installed"
        Write-Host "Version: $($googleDriveInfo.Version)"
        Write-Host "Path: $($googleDriveInfo.Path)"
        Write-Host "Install Type: $($googleDriveInfo.InstallType)"
        exit 0
    } else {
        Write-Log "Google Drive Status: NOT INSTALLED" -Level "WARNING"
        Write-Log "=========================================="

        Write-Host ""
        Write-Host "CRITICAL: Google Drive is NOT installed"
        Write-Host "Computer: $env:COMPUTERNAME"
        exit 1002
    }
} catch {
    Write-Log "Check failed: $_" -Level "ERROR"
    Write-Host ""
    Write-Host "CRITICAL: Google Drive check failed - $_"
    exit 1002
}
