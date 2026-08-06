<#
.SYNOPSIS
    Install Google Chrome Enterprise for all users.
    
.DESCRIPTION
    This remediation script installs Google Chrome when the check script
    (Check_Chrome_Installed.ps1) reports Chrome is not installed.
    
    Features:
    - Downloads Google Chrome Enterprise MSI installer
    - Installs Chrome silently for all users (system-wide)
    - Supports both x64 and x86 architectures
    - Designed for N-Sight RMM deployment as remediation task
    
    Exit Codes:
    - 0 = Success (Chrome installed successfully)
    - 1 = Error (Installation failed)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Install_Chrome.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_Chrome.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Chrome.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
    N-Sight Usage:
    - Create a Check using Check_Chrome_Installed.ps1
    - Set this script as the automated task when check fails
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up downloads

$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Install_Chrome_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ChromeMsiUrl64 = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
$ChromeMsiUrl32 = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise.msi"
$DownloadPath = "$env:TEMP\GoogleChromeEnterprise.msi"

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

function Get-ChromeInstallStatus {
    <#
    .SYNOPSIS
        Check if Chrome is already installed
    #>
    $chromePaths = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    
    foreach ($path in $chromePaths) {
        if (Test-Path $path) {
            try {
                $fileInfo = Get-Item $path
                $version = $fileInfo.VersionInfo.ProductVersion
                return @{ Installed = $true; Path = $path; Version = $version }
            }
            catch {
                return @{ Installed = $true; Path = $path; Version = "Unknown" }
            }
        }
    }
    
    return @{ Installed = $false; Path = $null; Version = $null }
}

function Get-SystemArchitecture {
    if ([Environment]::Is64BitOperatingSystem) {
        return "x64"
    }
    return "x86"
}

function Install-GoogleChrome {
    <#
    .SYNOPSIS
        Download and install Google Chrome Enterprise MSI
    #>
    Write-Log "Starting Google Chrome Enterprise installation..."
    
    # Determine architecture and download URL
    $arch = Get-SystemArchitecture
    $downloadUrl = if ($arch -eq "x64") { $ChromeMsiUrl64 } else { $ChromeMsiUrl32 }
    Write-Log "System architecture: $arch"
    Write-Log "Download URL: $downloadUrl"
    
    # Set TLS 1.2 for secure download
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    # Download Chrome Enterprise MSI
    Write-Log "Downloading Google Chrome Enterprise MSI..."
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $DownloadPath -UseBasicParsing
        Write-Log "Download completed: $DownloadPath"
    }
    catch {
        Write-Log "Failed to download Chrome: $_" -Level "ERROR"
        throw "Download failed: $_"
    }
    
    # Verify download exists and has reasonable size
    if (-not (Test-Path $DownloadPath)) {
        Write-Log "Downloaded file not found!" -Level "ERROR"
        throw "Chrome MSI download failed - file not found"
    }
    
    $fileSize = (Get-Item $DownloadPath).Length / 1MB
    Write-Log "Downloaded file size: $([math]::Round($fileSize, 2)) MB"
    
    if ($fileSize -lt 50) {
        Write-Log "Downloaded file appears too small (expected ~90MB)" -Level "WARNING"
    }
    
    # Install Chrome silently for all users
    Write-Log "Installing Google Chrome for all users..."
    $msiArgs = @(
        "/i"
        "`"$DownloadPath`""
        "/qn"           # Quiet, no UI
        "/norestart"    # Don't restart
        "ALLUSERS=1"    # Install for all users
        "/l*v"          # Verbose logging
        "`"$env:TEMP\ChromeMSI_Install.log`""
    )
    
    try {
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
        
        switch ($process.ExitCode) {
            0 {
                Write-Log "Chrome installation completed successfully (Exit Code: 0)"
                return $true
            }
            3010 {
                Write-Log "Chrome installation completed, reboot required (Exit Code: 3010)"
                return $true
            }
            1602 {
                Write-Log "Installation cancelled by user (Exit Code: 1602)" -Level "ERROR"
                throw "MSI installation was cancelled"
            }
            1603 {
                Write-Log "Fatal error during installation (Exit Code: 1603)" -Level "ERROR"
                throw "MSI installation failed with fatal error"
            }
            default {
                Write-Log "Chrome installation failed with exit code: $($process.ExitCode)" -Level "ERROR"
                throw "MSI installation failed with exit code: $($process.ExitCode)"
            }
        }
    }
    catch {
        Write-Log "Installation error: $_" -Level "ERROR"
        throw
    }
    finally {
        # Cleanup downloaded file
        if (Test-Path $DownloadPath) {
            Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
            Write-Log "Cleaned up temporary installer"
        }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Google Chrome Installation Task"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Log "Script Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "ERROR: Script requires administrator privileges"
    exit 1001
}

try {
    # Check if Chrome is already installed
    $chromeStatus = Get-ChromeInstallStatus
    
    if ($chromeStatus.Installed) {
        Write-Log "Google Chrome is already installed"
        Write-Log "Path: $($chromeStatus.Path)"
        Write-Log "Version: $($chromeStatus.Version)"
        Write-Log "=========================================="
        
        Write-Host ""
        Write-Host "SUCCESS: Google Chrome is already installed"
        Write-Host "Version: $($chromeStatus.Version)"
        Write-Host "Path: $($chromeStatus.Path)"
        
        exit 0
    }
    
    # Chrome not installed - proceed with installation
    Write-Log "Google Chrome is not installed. Starting installation..."
    Install-GoogleChrome
    
    # Verify installation succeeded
    Write-Log "Verifying Chrome installation..."
    Start-Sleep -Seconds 3
    
    $verifyStatus = Get-ChromeInstallStatus
    if ($verifyStatus.Installed) {
        Write-Log "Installation verified successfully"
        Write-Log "Chrome Version: $($verifyStatus.Version)"
        Write-Log "Chrome Path: $($verifyStatus.Path)"
        Write-Log "=========================================="
        Write-Log "Script completed successfully!"
        Write-Log "=========================================="
        
        Write-Host ""
        Write-Host "SUCCESS: Google Chrome installed successfully"
        Write-Host "Version: $($verifyStatus.Version)"
        Write-Host "Path: $($verifyStatus.Path)"
        
        exit 0
    }
    else {
        Write-Log "Installation verification failed - Chrome not found after install!" -Level "ERROR"
        Write-Host "ERROR: Chrome installation could not be verified"
        exit 1001
    }
}
catch {
    Write-Log "Script failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Log "=========================================="
    
    Write-Host ""
    Write-Host "ERROR: Chrome installation failed - $_"
    
    exit 1001
}
