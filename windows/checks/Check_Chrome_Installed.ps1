<#
.SYNOPSIS
    Check if Google Chrome is installed on the system.
    
.DESCRIPTION
    This monitoring script checks for Google Chrome installation and reports:
    - Installation status (installed/not installed)
    - Chrome version if installed
    - Installation path
    - Designed for N-Sight RMM monitoring checks
    
    Exit Codes:
    - 0 = OK (Chrome is installed)
    - 2 = Critical (Chrome is NOT installed)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Chrome_Installed.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Chrome_Installed.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Chrome_Installed.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\ChromeCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Get-ChromeInstallInfo {
    <#
    .SYNOPSIS
        Checks for Chrome installation and returns detailed info
    #>
    
    $result = @{
        Installed = $false
        Path = $null
        Version = $null
        Architecture = $null
    }
    
    # Check standard installation paths
    $chromePaths = @(
        @{ Path = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"; Arch = "x64" },
        @{ Path = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"; Arch = "x86" }
    )
    
    foreach ($chrome in $chromePaths) {
        if (Test-Path $chrome.Path) {
            $result.Installed = $true
            $result.Path = $chrome.Path
            $result.Architecture = $chrome.Arch
            
            # Get version from file properties
            try {
                $fileInfo = Get-Item $chrome.Path
                $result.Version = $fileInfo.VersionInfo.ProductVersion
            }
            catch {
                $result.Version = "Unknown"
            }
            
            break
        }
    }
    
    # Also check registry for installation info (backup method)
    if (-not $result.Installed) {
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome"
        )
        
        foreach ($regPath in $regPaths) {
            if (Test-Path $regPath) {
                try {
                    $regInfo = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                    if ($regInfo.DisplayName -like "*Chrome*") {
                        $result.Installed = $true
                        $result.Version = $regInfo.DisplayVersion
                        $result.Path = $regInfo.InstallLocation
                        if ($regPath -like "*WOW6432Node*") {
                            $result.Architecture = "x86"
                        } else {
                            $result.Architecture = "x64"
                        }
                        break
                    }
                }
                catch {
                    # Continue checking other paths
                }
            }
        }
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Google Chrome Installation Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "CRITICAL: Script requires administrator privileges"
    exit 1002
}

try {
    # Check Chrome installation status
    $chromeInfo = Get-ChromeInstallInfo
    
    if ($chromeInfo.Installed) {
        Write-Log "Chrome Status: INSTALLED"
        Write-Log "Chrome Path: $($chromeInfo.Path)"
        Write-Log "Chrome Version: $($chromeInfo.Version)"
        Write-Log "Architecture: $($chromeInfo.Architecture)"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "OK: Google Chrome is installed"
        Write-Host "Version: $($chromeInfo.Version)"
        Write-Host "Path: $($chromeInfo.Path)"
        Write-Host "Architecture: $($chromeInfo.Architecture)"
        
        exit 0
    }
    else {
        Write-Log "Chrome Status: NOT INSTALLED" -Level "WARNING"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "CRITICAL: Google Chrome is NOT installed"
        Write-Host "Computer: $env:COMPUTERNAME"
        
        exit 1002
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "CRITICAL: Chrome check failed - $_"
    
    exit 1002
}

