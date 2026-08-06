<#
.SYNOPSIS
    Install Dropbox desktop app for all users (enterprise MSI, silent).

.DESCRIPTION
    This remediation script installs Dropbox when a check script reports Dropbox
    is not installed.

    Features:
    - Downloads the official Dropbox Enterprise MSI for the OS architecture
      (32-bit, 64-bit, or ARM64) per Dropbox Help (enterprise installer).
    - Installs silently machine-wide to Program Files (x86)\Dropbox\Client
    - Verifies Dropbox.exe after install
    - Designed for N-Sight RMM deployment as remediation task

    Vendor alignment: Silent MSI deployment per Dropbox Help - Install Dropbox
    for all team members (enterprise installer).

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_Dropbox.ps1"
    Windows (repo):     iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Dropbox.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11

    N-Sight Usage:
    - Create a Check using Check_Dropbox_Installed.ps1 (when available)
    - Set this script as the automated task when check fails

.OUTPUTS
    Exit 0    = Success
    Exit 1001 = Warning
    Exit 1002 = Critical/Error
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Install_Dropbox"
$ScriptVersion = "1.0"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$DownloadPath = Join-Path $env:TEMP "DropboxEnterprise_$(Get-Date -Format 'yyyyMMdd_HHmmss').msi"
$MsiVerboseLog = Join-Path $env:TEMP "DropboxMSI_Install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# Official enterprise MSI URLs (Dropbox Help - Jun 2025)
$DropboxMsiUrlX86 = "https://client.dropbox.com/desktop/desktop-dropbox/requestdownload?install_type=enterprise_install&platform=win&arch=x86"
$DropboxMsiUrlX64 = "https://client.dropbox.com/desktop/desktop-dropbox/requestdownload?install_type=enterprise_install&platform=win&arch=x86_64"
$DropboxMsiUrlArm64 = "https://client.dropbox.com/desktop/desktop-dropbox/requestdownload?install_type=enterprise_install&platform=win&arch=arm64"

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

function Write-Summary {
    param(
        [ValidateSet("OK", "WARNING", "CRITICAL")]
        [string]$Status,
        [string]$Message
    )
    Write-Host ""
    Write-Host "${Status}: $Message"
}

function Get-DropboxEnterpriseMsiUrl {
    <#
    .SYNOPSIS
        Resolve Dropbox Enterprise MSI download URL for current Windows architecture.
    #>
    $pa = $env:PROCESSOR_ARCHITECTURE
    switch ($pa) {
        "ARM64" {
            Write-Log "Architecture: ARM64 - using ARM64 MSI"
            return $DropboxMsiUrlArm64
        }
        "AMD64" {
            Write-Log "Architecture: AMD64 - using x86_64 MSI"
            return $DropboxMsiUrlX64
        }
        default {
            Write-Log "Architecture: $pa - using 32-bit MSI"
            return $DropboxMsiUrlX86
        }
    }
}

function Get-DropboxInstallStatus {
    <#
    .SYNOPSIS
        Check if Dropbox desktop is installed (machine or per-user).
    #>
    $pfX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    $pf = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $machinePaths = @(
        (Join-Path $pfX86 "Dropbox\Client\Dropbox.exe"),
        (Join-Path $pf "Dropbox\Client\Dropbox.exe")
    )

    foreach ($path in $machinePaths) {
        if (Test-Path $path) {
            try {
                $fileInfo = Get-Item $path
                $version = $fileInfo.VersionInfo.ProductVersion
                return @{ Installed = $true; Path = $path; Version = $version; InstallType = "Machine" }
            }
            catch {
                return @{ Installed = $true; Path = $path; Version = "Unknown"; InstallType = "Machine" }
            }
        }
    }

    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }

    foreach ($userProfile in $userProfiles) {
        $userPaths = @(
            (Join-Path $userProfile.FullName "AppData\Local\Dropbox\bin\Dropbox.exe"),
            (Join-Path $userProfile.FullName "AppData\Local\Dropbox\Dropbox.exe")
        )
        foreach ($userPath in $userPaths) {
            if (Test-Path $userPath) {
                try {
                    $fileInfo = Get-Item $userPath
                    $version = $fileInfo.VersionInfo.ProductVersion
                    return @{ Installed = $true; Path = $userPath; Version = $version; InstallType = "User ($($userProfile.Name))" }
                }
                catch {
                    return @{ Installed = $true; Path = $userPath; Version = "Unknown"; InstallType = "User ($($userProfile.Name))" }
                }
            }
        }
    }

    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($regPath in $regPaths) {
        try {
            $regItems = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*Dropbox*" -and $_.DisplayName -notlike "*Paper*" }

            if ($regItems) {
                $regItem = $regItems | Select-Object -First 1
                return @{
                    Installed = $true
                    Path = $regItem.InstallLocation
                    Version = $regItem.DisplayVersion
                    InstallType = "Machine (Registry)"
                }
            }
        }
        catch { }
    }

    return @{ Installed = $false; Path = $null; Version = $null; InstallType = $null }
}

function Install-DropboxEnterpriseMsi {
    <#
    .SYNOPSIS
        Download and install Dropbox Enterprise MSI silently.
    #>
    Write-Log "Starting Dropbox Enterprise MSI installation..."

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $msiUrl = Get-DropboxEnterpriseMsiUrl
    Write-Log "Download URL: $msiUrl"

    $maxRetries = 3
    $retryCount = 0
    $downloadSuccess = $false

    while (-not $downloadSuccess -and $retryCount -lt $maxRetries) {
        try {
            if ($retryCount -gt 0) {
                Write-Log "Retry attempt $($retryCount) of $maxRetries..." -Level "WARNING"
                Start-Sleep -Seconds 30
            }

            Write-Log "Downloading Dropbox Enterprise MSI (attempt $($retryCount + 1))..."
            Invoke-WebRequest -Uri $msiUrl -OutFile $DownloadPath -UseBasicParsing -TimeoutSec 600

            if (Test-Path $DownloadPath) {
                $downloadSuccess = $true
                Write-Log "Download completed: $DownloadPath"
            }
        }
        catch {
            $retryCount++
            Write-Log "Download attempt failed: $($_.Exception.Message)" -Level "WARNING"
            if (Test-Path $DownloadPath) {
                Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $downloadSuccess) {
        Write-Log "Failed to download Dropbox MSI after $maxRetries attempts" -Level "ERROR"
        throw "Download failed after $maxRetries attempts"
    }

    if (-not (Test-Path $DownloadPath)) {
        throw "Dropbox MSI download failed - file not found"
    }

    $fileSize = (Get-Item $DownloadPath).Length / 1MB
    Write-Log "Downloaded file size: $([math]::Round($fileSize, 2)) MB"

    if ($fileSize -lt 10) {
        Write-Log "Downloaded file appears too small for Dropbox MSI" -Level "WARNING"
    }

    Write-Log "Installing Dropbox silently (msiexec /qn)..."
    $msiArgs = @(
        "/i"
        "`"$DownloadPath`""
        "/qn"
        "/norestart"
        "/l*v"
        "`"$MsiVerboseLog`""
    )

    try {
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
        $installerExitCode = $process.ExitCode

        switch ($installerExitCode) {
            0 {
                Write-Log "Dropbox installation completed successfully (Exit Code: 0)"
                return $true
            }
            3010 {
                Write-Log "Dropbox installation completed; reboot may be required (Exit Code: 3010)"
                return $true
            }
            1641 {
                Write-Log "Dropbox installation triggered restart (Exit Code: 1641)"
                return $true
            }
            default {
                Write-Log "msiexec failed with exit code: $installerExitCode" -Level "ERROR"
                throw "MSI exited with code $installerExitCode"
            }
        }
    }
    finally {
        if (Test-Path $DownloadPath) {
            Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
            Write-Log "Removed temporary MSI"
        }
    }
}

function Wait-ForDropboxInstallation {
    param([int]$MaxWaitSeconds = 120)

    Write-Log "Waiting for Dropbox files (max $MaxWaitSeconds seconds)..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
        $status = Get-DropboxInstallStatus
        if ($status.Installed) {
            Write-Log "Dropbox detected after $([math]::Round($stopwatch.Elapsed.TotalSeconds, 0)) seconds"
            return $true
        }
        Start-Sleep -Seconds 5
    }

    $stopwatch.Stop()
    Write-Log "Verification wait timed out after $MaxWaitSeconds seconds" -Level "WARNING"
    return $false
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName v$ScriptVersion Started"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $env:USERNAME"
Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Log File: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "Administrator privileges required." -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    $status = Get-DropboxInstallStatus

    if ($status.Installed) {
        Write-Log "Dropbox is already installed"
        Write-Log "Path: $($status.Path)"
        Write-Log "Version: $($status.Version)"
        Write-Log "Install Type: $($status.InstallType)"
        Write-Log "=========================================="
        Write-Summary -Status "OK" -Message "Dropbox already installed v$($status.Version)"
        Write-Host "Path: $($status.Path)"
        exit $EXIT_SUCCESS
    }

    Write-Log "Dropbox not found. Starting installation..."
    Install-DropboxEnterpriseMsi

    Write-Log "Verifying Dropbox installation..."
    $verified = Wait-ForDropboxInstallation -MaxWaitSeconds 120

    if ($verified) {
        $verifyStatus = Get-DropboxInstallStatus
        if ($verifyStatus.Installed) {
            Write-Log "Installation verified"
            Write-Log "Version: $($verifyStatus.Version)"
            Write-Log "Path: $($verifyStatus.Path)"
            Write-Log "=========================================="
            Write-Summary -Status "OK" -Message "Dropbox installed v$($verifyStatus.Version)"
            Write-Host "Path: $($verifyStatus.Path)"
            Write-Host "NOTE: Users must sign in to Dropbox on first launch if not yet linked."
            exit $EXIT_SUCCESS
        }
    }

    Write-Log "Could not verify Dropbox after install" -Level "ERROR"
    Write-Summary -Status "WARNING" -Message "Dropbox install could not be verified (may still be finishing)"
    exit $EXIT_WARNING
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Dropbox installation failed - $_"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Script execution ended"
}
