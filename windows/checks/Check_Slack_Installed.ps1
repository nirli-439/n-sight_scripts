<#
.SYNOPSIS
    Check if Slack is installed on the system.
    
.DESCRIPTION
    This monitoring script checks for Slack installation and reports:
    - Installation status (installed/not installed)
    - Slack version if installed
    - Installation path and type (user/machine/store)
    - Designed for N-Sight RMM monitoring checks
    
    Exit Codes:
    - 0 = OK (Slack is installed)
    - 2 = Critical (Slack is NOT installed)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Slack_Installed.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Slack_Installed.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Slack_Installed.ps1")
.NOTES
    Author: IT Admin
    Version: 1.1
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\SlackCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Get-SlackInstallInfo {
    <#
    .SYNOPSIS
        Checks for Slack installation and returns detailed info
    #>
    
    $result = @{
        Installed = $false
        Path = $null
        Version = $null
        InstallType = $null
    }
    
    # Check 1: Machine-wide installation (MSI) in Program Files
    $machinePaths = @(
        "${env:ProgramFiles}\Slack\slack.exe",
        "${env:ProgramFiles(x86)}\Slack\slack.exe"
    )
    
    foreach ($path in $machinePaths) {
        if (Test-Path $path) {
            $result.Installed = $true
            $result.Path = $path
            $result.InstallType = "Machine (MSI)"
            
            try {
                $fileInfo = Get-Item $path
                $result.Version = $fileInfo.VersionInfo.ProductVersion
            }
            catch {
                $result.Version = "Unknown"
            }
            
            return $result
        }
    }
    
    # Check 2: User-level installation (default installer)
    # Check all user profiles for Slack installation
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    
    foreach ($profile in $userProfiles) {
        $userSlackPath = Join-Path $profile.FullName "AppData\Local\slack\slack.exe"
        
        if (Test-Path $userSlackPath) {
            $result.Installed = $true
            $result.Path = $userSlackPath
            $result.InstallType = "User ($($profile.Name))"
            
            try {
                $fileInfo = Get-Item $userSlackPath
                $result.Version = $fileInfo.VersionInfo.ProductVersion
            }
            catch {
                $result.Version = "Unknown"
            }
            
            return $result
        }
    }
    
    # Check 3: Windows Store / MSIX installation
    try {
        $storeApp = Get-AppxPackage -AllUsers -Name "*Slack*" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($storeApp) {
            $result.Installed = $true
            $result.Path = $storeApp.InstallLocation
            $result.Version = $storeApp.Version
            $result.InstallType = "Microsoft Store"
            
            return $result
        }
    }
    catch {
        # AppX check failed, continue to registry check
    }
    
    # Check 4: Provisioned MSIX (machine-wide; registered per-user on next sign-in)
    #    Note: Get-AppxProvisionedPackage does NOT have InstallLocation or Version properties.
    #    Path comes from InstallPath (Win10 1803+); version is embedded in PackageName.
    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -like "*slack*" -or $_.DisplayName -like "*Slack*" } |
            Select-Object -First 1
        
        if ($provisioned) {
            $result.Installed = $true
            # Extract version from PackageName (format: Publisher_Major.Minor.Build.Rev_arch__token)
            $verMatch = [regex]::Match($provisioned.PackageName, '_(\.?\d+\.\d+[\.\d]*)_')
            $result.Version = if ($verMatch.Success) { $verMatch.Groups[1].Value } else { "Unknown" }
            $result.Path = if ($provisioned.PSObject.Properties['InstallPath'] -and $provisioned.InstallPath) {
                               $provisioned.InstallPath
                           } else { "Provisioned (path available after first user sign-in)" }
            $result.InstallType = "Provisioned (MSIX)"
            return $result
        }
    }
    catch {
        # Continue to registry check
    }
    
    # Check 5: Registry for installation info (backup method)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($regPath in $regPaths) {
        try {
            $regItems = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue | 
                        Where-Object { $_.DisplayName -like "*Slack*" }
            
            if ($regItems) {
                $regItem = $regItems | Select-Object -First 1
                $result.Installed = $true
                $result.Version = $regItem.DisplayVersion
                $result.Path = $regItem.InstallLocation
                
                if ($regPath -like "*HKCU*") {
                    $result.InstallType = "User (Registry)"
                } else {
                    $result.InstallType = "Machine (Registry)"
                }
                
                return $result
            }
        }
        catch {
            # Continue checking other paths
        }
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Slack Installation Check"
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
    # Check Slack installation status
    $slackInfo = Get-SlackInstallInfo
    
    if ($slackInfo.Installed) {
        Write-Log "Slack Status: INSTALLED"
        Write-Log "Slack Path: $($slackInfo.Path)"
        Write-Log "Slack Version: $($slackInfo.Version)"
        Write-Log "Install Type: $($slackInfo.InstallType)"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "OK: Slack is installed"
        Write-Host "Version: $($slackInfo.Version)"
        Write-Host "Path: $($slackInfo.Path)"
        Write-Host "Install Type: $($slackInfo.InstallType)"
        
        exit 0
    }
    else {
        Write-Log "Slack Status: NOT INSTALLED" -Level "WARNING"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "CRITICAL: Slack is NOT installed"
        Write-Host "Computer: $env:COMPUTERNAME"
        
        exit 1002
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "CRITICAL: Slack check failed - $_"
    
    exit 1002
}
