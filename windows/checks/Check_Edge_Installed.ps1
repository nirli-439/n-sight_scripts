<#
.SYNOPSIS
    Check if Microsoft Edge is installed on the system.
    
.DESCRIPTION
    This monitoring script checks for Microsoft Edge installation and reports:
    - Installation status (installed/not installed)
    - Edge version if installed
    - Installation path
    - Designed for N-Sight RMM monitoring checks
    
    For Google Workspace environments where only Chrome should be installed.
    
    Exit Codes:
    - 0 = OK (Edge is NOT installed - compliant)
    - 2 = Critical (Edge IS installed - non-compliant)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Edge_Installed.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Edge_Installed.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Edge_Installed.ps1")
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
$LogFile = "$env:TEMP\EdgeCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Get-EdgeInstallInfo {
    <#
    .SYNOPSIS
        Checks for Microsoft Edge installation and returns detailed info
    #>
    
    $result = @{
        Installed = $false
        Path = $null
        Version = $null
        Architecture = $null
        Channel = $null
        InstallType = $null
    }
    
    # Check standard installation paths for Edge
    $edgePaths = @(
        @{ Path = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"; Arch = "x64"; Channel = "Stable" },
        @{ Path = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"; Arch = "x86"; Channel = "Stable" },
        @{ Path = "${env:ProgramFiles}\Microsoft\Edge Beta\Application\msedge.exe"; Arch = "x64"; Channel = "Beta" },
        @{ Path = "${env:ProgramFiles(x86)}\Microsoft\Edge Beta\Application\msedge.exe"; Arch = "x86"; Channel = "Beta" },
        @{ Path = "${env:ProgramFiles}\Microsoft\Edge Dev\Application\msedge.exe"; Arch = "x64"; Channel = "Dev" },
        @{ Path = "${env:ProgramFiles(x86)}\Microsoft\Edge Dev\Application\msedge.exe"; Arch = "x86"; Channel = "Dev" }
    )
    
    foreach ($edge in $edgePaths) {
        if (Test-Path $edge.Path) {
            $result.Installed = $true
            $result.Path = $edge.Path
            $result.Architecture = $edge.Arch
            $result.Channel = $edge.Channel
            
            # Get version from file properties
            try {
                $fileInfo = Get-Item $edge.Path
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
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
        )
        
        foreach ($regPath in $regPaths) {
            if (Test-Path $regPath) {
                try {
                    $regInfo = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                    if ($regInfo) {
                        $result.Installed = $true
                        if ($regInfo.DisplayVersion) {
                            $result.Version = $regInfo.DisplayVersion
                        }
                        if ($regInfo.InstallLocation) {
                            $result.Path = $regInfo.InstallLocation
                        } elseif ($regInfo.'(default)') {
                            $result.Path = $regInfo.'(default)'
                        }
                        if ($regPath -like "*WOW6432Node*") {
                            $result.Architecture = "x86"
                        } else {
                            $result.Architecture = "x64"
                        }
                        $result.Channel = "Stable"
                        break
                    }
                }
                catch {
                    # Continue checking other paths
                }
            }
        }
    }
    
    # Check for Windows built-in Edge (UWP/AppX)
    if (-not $result.Installed) {
        try {
            $appxEdge = Get-AppxPackage -Name "Microsoft.MicrosoftEdge*" -ErrorAction SilentlyContinue
            if ($appxEdge) {
                $result.Installed = $true
                $result.Version = $appxEdge.Version
                $result.InstallType = "AppX/UWP"
                $result.Path = "Windows Store App"
                $result.Channel = "Legacy"
            }
        }
        catch {
            # AppX check failed, continue
        }
    }
    
    # Check for Edge in Windows Apps (provisioned)
    if (-not $result.Installed) {
        try {
            $provisionedEdge = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | 
                Where-Object { $_.DisplayName -like "*MicrosoftEdge*" }
            if ($provisionedEdge) {
                $result.Installed = $true
                $result.Version = $provisionedEdge.Version
                $result.InstallType = "Provisioned"
                $result.Path = "System Provisioned"
                $result.Channel = "Provisioned"
            }
        }
        catch {
            # Provisioned check failed, continue
        }
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Microsoft Edge Installation Check"
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
    # Check Edge installation status
    $edgeInfo = Get-EdgeInstallInfo
    
    if ($edgeInfo.Installed) {
        Write-Log "Edge Status: INSTALLED (NON-COMPLIANT)" -Level "WARNING"
        Write-Log "Edge Path: $($edgeInfo.Path)"
        Write-Log "Edge Version: $($edgeInfo.Version)"
        Write-Log "Architecture: $($edgeInfo.Architecture)"
        Write-Log "Channel: $($edgeInfo.Channel)"
        if ($edgeInfo.InstallType) {
            Write-Log "Install Type: $($edgeInfo.InstallType)"
        }
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "CRITICAL: Microsoft Edge is installed (Policy Violation)"
        Write-Host "Google Workspace policy requires Chrome as the only browser"
        Write-Host "Version: $($edgeInfo.Version)"
        Write-Host "Path: $($edgeInfo.Path)"
        Write-Host "Channel: $($edgeInfo.Channel)"
        if ($edgeInfo.InstallType) {
            Write-Host "Install Type: $($edgeInfo.InstallType)"
        }
        Write-Host "Action Required: Remove Microsoft Edge"
        
        exit 1002
    }
    else {
        Write-Log "Edge Status: NOT INSTALLED (COMPLIANT)"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "OK: Microsoft Edge is NOT installed"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Status: Compliant with Google Workspace browser policy"
        
        exit 0
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "CRITICAL: Edge check failed - $_"
    
    exit 1002
}
