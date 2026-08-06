<#
.SYNOPSIS
    Check if Twingate is installed and configured on the system.
    
.DESCRIPTION
    This monitoring script checks for Twingate installation and reports:
    - Installation status (installed/not installed)
    - Twingate version if installed
    - Installation path and type (user/machine/store)
    - Service status (running/stopped)
    - Designed for N-Sight RMM monitoring checks
    
    Exit Codes:
    - 0 = OK (Twingate is installed and running)
    - 1 = Warning (Twingate is installed but service not running)
    - 2 = Critical (Twingate is NOT installed)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Twingate_Installed.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Twingate_Installed.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Twingate_Installed.ps1")
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
$LogFile = "$env:TEMP\TwingateCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Get-TwingateInstallInfo {
    <#
    .SYNOPSIS
        Checks for Twingate installation and returns detailed info
    #>
    
    $result = @{
        Installed = $false
        Path = $null
        Version = $null
        InstallType = $null
    }
    
    # Check 1: Machine-wide installation (MSI) in Program Files
    $machinePaths = @(
        "${env:ProgramFiles}\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
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
    
    # Check 2: User-level installation
    # Check all user profiles for Twingate installation
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    
    foreach ($profile in $userProfiles) {
        $userTwingatePaths = @(
            (Join-Path $profile.FullName "AppData\Local\Twingate\Twingate.exe"),
            (Join-Path $profile.FullName "AppData\Local\Programs\Twingate\Twingate.exe")
        )
        
        foreach ($userTwingatePath in $userTwingatePaths) {
            if (Test-Path $userTwingatePath) {
                $result.Installed = $true
                $result.Path = $userTwingatePath
                $result.InstallType = "User ($($profile.Name))"
                
                try {
                    $fileInfo = Get-Item $userTwingatePath
                    $result.Version = $fileInfo.VersionInfo.ProductVersion
                }
                catch {
                    $result.Version = "Unknown"
                }
                
                return $result
            }
        }
    }
    
    # Check 3: Windows Store / MSIX installation
    try {
        $storeApp = Get-AppxPackage -AllUsers -Name "*Twingate*" -ErrorAction SilentlyContinue | Select-Object -First 1
        
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
    
    # Check 4: Registry for installation info (backup method)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($regPath in $regPaths) {
        try {
            $regItems = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue | 
                        Where-Object { $_.DisplayName -like "*Twingate*" }
            
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

function Get-TwingateServiceStatus {
    <#
    .SYNOPSIS
        Checks the Twingate service status
    #>
    
    $result = @{
        ServiceExists = $false
        ServiceStatus = $null
        ServiceStartType = $null
    }
    
    # Check for Twingate service
    $serviceNames = @("Twingate", "TwingateService", "twingate")
    
    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            
            if ($service) {
                $result.ServiceExists = $true
                $result.ServiceStatus = $service.Status.ToString()
                $result.ServiceStartType = $service.StartType.ToString()
                
                return $result
            }
        }
        catch {
            # Continue checking other service names
        }
    }
    
    # Also check for running Twingate process as fallback
    $twingateProcess = Get-Process -Name "Twingate" -ErrorAction SilentlyContinue
    
    if ($twingateProcess) {
        $result.ServiceExists = $true
        $result.ServiceStatus = "Running (Process)"
        $result.ServiceStartType = "N/A"
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Twingate Installation Check"
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
    # Check Twingate installation status
    $twingateInfo = Get-TwingateInstallInfo
    $serviceInfo = Get-TwingateServiceStatus
    
    if ($twingateInfo.Installed) {
        Write-Log "Twingate Status: INSTALLED"
        Write-Log "Twingate Path: $($twingateInfo.Path)"
        Write-Log "Twingate Version: $($twingateInfo.Version)"
        Write-Log "Install Type: $($twingateInfo.InstallType)"
        
        if ($serviceInfo.ServiceExists) {
            Write-Log "Service Status: $($serviceInfo.ServiceStatus)"
            Write-Log "Service Start Type: $($serviceInfo.ServiceStartType)"
        } else {
            Write-Log "Service Status: No service found" -Level "WARNING"
        }
        
        Write-Log "=========================================="
        
        # Determine exit code based on service status
        if ($serviceInfo.ServiceExists -and ($serviceInfo.ServiceStatus -eq "Running" -or $serviceInfo.ServiceStatus -eq "Running (Process)")) {
            # Twingate installed and running
            Write-Host ""
            Write-Host "OK: Twingate is installed and running"
            Write-Host "Version: $($twingateInfo.Version)"
            Write-Host "Path: $($twingateInfo.Path)"
            Write-Host "Install Type: $($twingateInfo.InstallType)"
            Write-Host "Service Status: $($serviceInfo.ServiceStatus)"
            
            exit 0
        }
        else {
            # Twingate installed but not running
            Write-Host ""
            Write-Host "WARNING: Twingate is installed but not running"
            Write-Host "Version: $($twingateInfo.Version)"
            Write-Host "Path: $($twingateInfo.Path)"
            Write-Host "Install Type: $($twingateInfo.InstallType)"
            Write-Host "Service Status: $($serviceInfo.ServiceStatus)"
            
            exit 1001
        }
    }
    else {
        Write-Log "Twingate Status: NOT INSTALLED" -Level "WARNING"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "CRITICAL: Twingate is NOT installed"
        Write-Host "Computer: $env:COMPUTERNAME"
        
        exit 1002
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "CRITICAL: Twingate check failed - $_"
    
    exit 1002
}
