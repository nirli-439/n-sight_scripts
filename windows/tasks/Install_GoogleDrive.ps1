<#
.SYNOPSIS
    Install Google Drive for Desktop for all users.
    
.DESCRIPTION
    This remediation script installs Google Drive when the check script
    (Check_GoogleDrive_Installed.ps1) reports Google Drive is not installed.
    
    Features:
    - Downloads Google Drive for Desktop installer
    - Installs Google Drive silently for all users (system-wide)
    - Supports automatic startup configuration
    - Designed for N-Sight RMM deployment as remediation task
    
    Vendor alignment: Google Drive for Desktop install URL and silent switches
    per Google Workspace Admin Help (Deploy Drive for desktop).
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Install_GoogleDrive.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_GoogleDrive.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_GoogleDrive.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
    N-Sight Usage:
    - Create a Check using Check_GoogleDrive_Installed.ps1
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
$ProgressPreference = "SilentlyContinue"  # Speeds up downloads

$ScriptName = "Install_GoogleDrive"
$ScriptVersion = "1.0"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$GoogleDriveInstallerUrl = "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe"
$DownloadPath = "$env:TEMP\GoogleDriveSetup_$(Get-Date -Format 'yyyyMMdd_HHmmss').exe"

# Exit codes for N-Sight (1-999 reserved for N-Sight system)
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
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

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Summary {
    <#
    .SYNOPSIS
        Writes a concise summary for N-Sight dashboard display (first 255 chars).
    #>
    param(
        [ValidateSet("OK", "WARNING", "CRITICAL")]
        [string]$Status,
        [string]$Message
    )
    Write-Host ""
    Write-Host "${Status}: $Message"
}

function Get-GoogleDriveInstallStatus {
    <#
    .SYNOPSIS
        Check if Google Drive is already installed
    #>
    
    # Check machine-wide installation paths
    $machinePaths = @(
        "${env:ProgramFiles}\Google\Drive File Stream\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\Drive File Stream\GoogleDriveFS.exe",
        "${env:ProgramFiles}\Google\DriveFS\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\DriveFS\GoogleDriveFS.exe"
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
    
    # Check user-level installations
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    
    foreach ($userProfile in $userProfiles) {
        $userPaths = @(
            (Join-Path $userProfile.FullName "AppData\Local\Google\DriveFS\GoogleDriveFS.exe"),
            (Join-Path $userProfile.FullName "AppData\Local\Google\Drive File Stream\GoogleDriveFS.exe"),
            (Join-Path $userProfile.FullName "AppData\Local\Programs\Google\Drive File Stream\GoogleDriveFS.exe")
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
    
    # Check registry as backup method
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
                return @{ 
                    Installed = $true
                    Path = $regItem.InstallLocation
                    Version = $regItem.DisplayVersion
                    InstallType = "Machine (Registry)"
                }
            }
        }
        catch {
            # Continue checking other paths
        }
    }
    
    return @{ Installed = $false; Path = $null; Version = $null; InstallType = $null }
}

function Install-GoogleDrive {
    <#
    .SYNOPSIS
        Download and install Google Drive for Desktop
    #>
    Write-Log "Starting Google Drive for Desktop installation..."
    
    # Set TLS 1.2 for secure download
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    Write-Log "Download URL: $GoogleDriveInstallerUrl"
    
    # Download Google Drive installer with retry logic
    $maxRetries = 3
    $retryCount = 0
    $downloadSuccess = $false
    
    while (-not $downloadSuccess -and $retryCount -lt $maxRetries) {
        try {
            if ($retryCount -gt 0) {
                Write-Log "Retry attempt $($retryCount) of $maxRetries..." -Level "WARNING"
                Start-Sleep -Seconds 30
            }
            
            Write-Log "Downloading Google Drive for Desktop installer (Attempt $($retryCount + 1))..."
            # Use Invoke-WebRequest with a 10-minute timeout (600 seconds)
            Invoke-WebRequest -Uri $GoogleDriveInstallerUrl -OutFile $DownloadPath -UseBasicParsing -TimeoutSec 600
            
            if (Test-Path $DownloadPath) {
                $downloadSuccess = $true
                Write-Log "Download completed: $DownloadPath"
            }
        }
        catch {
            $retryCount++
            Write-Log "Download attempt $retryCount failed: $($_.Exception.Message)" -Level "WARNING"
            
            # Clean up partial download before retry
            if (Test-Path $DownloadPath) {
                Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    if (-not $downloadSuccess) {
        Write-Log "Failed to download Google Drive installer after $maxRetries attempts" -Level "ERROR"
        throw "Download failed after $maxRetries attempts"
    }
    
    # Verify download exists and has reasonable size
    if (-not (Test-Path $DownloadPath)) {
        Write-Log "Downloaded file not found!" -Level "ERROR"
        throw "Google Drive installer download failed - file not found"
    }
    
    $fileSize = (Get-Item $DownloadPath).Length / 1MB
    Write-Log "Downloaded file size: $([math]::Round($fileSize, 2)) MB"
    
    if ($fileSize -lt 1) {
        Write-Log "Downloaded file appears too small (expected several MB)" -Level "WARNING"
    }
    
    # Install Google Drive silently
    # Silent installation switches for GoogleDriveSetup.exe:
    # --silent               = Silent installation
    # --desktop_shortcut     = Create desktop shortcut (0 = no, 1 = yes)
    # --skip_launch_new      = Don't launch after installation
    Write-Log "Installing Google Drive for Desktop silently..."
    
    $installArgs = @(
        "--silent"
        "--desktop_shortcut=0"
        "--skip_launch_new"
    )
    
    try {
        $process = Start-Process -FilePath $DownloadPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        
        # Per N-Sight standards: treat installer non-success codes as failure; log and exit 1002
        $installerExitCode = $process.ExitCode
        switch ($installerExitCode) {
            0 {
                Write-Log "Google Drive installation completed successfully (Exit Code: 0)"
                return $true
            }
            3010 {
                Write-Log "Google Drive installation completed, reboot may be required (Exit Code: 3010)"
                return $true
            }
            1641 {
                Write-Log "Google Drive installation triggered restart (Exit Code: 1641)"
                return $true
            }
            1 {
                # Exit code 1 can mean "already installed" or minor issues - verify installation
                Write-Log "Google Drive installer returned exit code 1 - verifying installation status..."
                return $true
            }
            default {
                Write-Log "Google Drive installer failed with exit code: $installerExitCode" -Level "ERROR"
                throw "Installer exited with code $installerExitCode (not a known success code)"
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

function Wait-ForInstallation {
    <#
    .SYNOPSIS
        Wait for Google Drive installation to complete (background processes)
    #>
    param([int]$MaxWaitSeconds = 120)
    
    Write-Log "Waiting for installation to complete (max $MaxWaitSeconds seconds)..."
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    while ($stopwatch.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
        $status = Get-GoogleDriveInstallStatus
        
        if ($status.Installed) {
            Write-Log "Installation detected after $([math]::Round($stopwatch.Elapsed.TotalSeconds, 0)) seconds"
            return $true
        }
        
        Start-Sleep -Seconds 5
    }
    
    $stopwatch.Stop()
    Write-Log "Installation verification timed out after $MaxWaitSeconds seconds" -Level "WARNING"
    return $false
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName v$ScriptVersion Started"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User Context: $env:USERNAME"
Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Log File: $LogFile"

# Admin check
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    # Check if Google Drive is already installed
    $googleDriveStatus = Get-GoogleDriveInstallStatus
    
    if ($googleDriveStatus.Installed) {
        Write-Log "Google Drive is already installed"
        Write-Log "Path: $($googleDriveStatus.Path)"
        Write-Log "Version: $($googleDriveStatus.Version)"
        Write-Log "Install Type: $($googleDriveStatus.InstallType)"
        Write-Log "=========================================="
        Write-Summary -Status "OK" -Message "Google Drive already installed v$($googleDriveStatus.Version)"
        Write-Host "Path: $($googleDriveStatus.Path)"
        Write-Host "Install Type: $($googleDriveStatus.InstallType)"
        exit $EXIT_SUCCESS
    }
    
    # Google Drive not installed - proceed with installation
    Write-Log "Google Drive is not installed. Starting installation..."
    Install-GoogleDrive
    
    # Verify installation succeeded (with retry/wait since installer may run background processes)
    Write-Log "Verifying Google Drive installation..."
    
    $installComplete = Wait-ForInstallation -MaxWaitSeconds 120
    
    if ($installComplete) {
        $verifyStatus = Get-GoogleDriveInstallStatus
        
        if ($verifyStatus.Installed) {
            Write-Log "Installation verified successfully"
            Write-Log "Google Drive Version: $($verifyStatus.Version)"
            Write-Log "Google Drive Path: $($verifyStatus.Path)"
            Write-Log "Install Type: $($verifyStatus.InstallType)"
            Write-Log "=========================================="
            Write-Log "Script completed successfully!" -Level "SUCCESS"
            Write-Summary -Status "OK" -Message "Google Drive installed v$($verifyStatus.Version)"
            Write-Host "Path: $($verifyStatus.Path)"
            Write-Host "NOTE: User must sign in to Google Drive after first launch"
            exit $EXIT_SUCCESS
        }
    }
    
    # Installation could not be verified (timing - installer may still be running)
    Write-Log "Installation verification failed - Google Drive not found after install!" -Level "ERROR"
    Write-Log "This may be a timing issue - Google Drive might still be installing in the background" -Level "WARNING"
    Write-Summary -Status "WARNING" -Message "Google Drive installation could not be verified (may still be installing)"
    Write-Host "Installer may still be running in the background. Check again in a few minutes."
    exit $EXIT_WARNING
}
catch {
    Write-Log "Script failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Log "=========================================="
    Write-Summary -Status "CRITICAL" -Message "Google Drive installation failed - $_"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Script execution ended"
}
