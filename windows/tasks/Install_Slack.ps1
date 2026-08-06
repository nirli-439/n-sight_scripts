<#
.SYNOPSIS
    Install Slack for Desktop for all users.
    
.DESCRIPTION
    This remediation script installs Slack when the check script
    (Check_Slack_Installed.ps1) reports Slack is not installed.
    
    Features:
    - Downloads Slack MSIX (Slack's supported enterprise format; MSI CDN path from their API is currently broken)
    - Provisions Slack for all users via Add-AppxProvisionedPackage
    - Uses official Slack API (api.slack.com) for latest release redirect
    - Designed for N-Sight RMM deployment as remediation task

    Exit Codes:
    - 0    = Success (Slack installed successfully or already installed)
    - 1001 = Warning (non-critical issue)
    - 1002 = Critical error (installation failed)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Install_Slack.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_Slack.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Slack.ps1")
.NOTES
    Author: IT Admin
    Version: 1.2
    Requires: Administrator privileges
    Platform: Windows 10/11
    
    N-Sight Usage:
    - Create a Check using Check_Slack_Installed.ps1
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

$ScriptName    = "Install_Slack"
$ScriptVersion = "1.2"
$LogDir  = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS  = 0
$EXIT_WARNING  = 1001
$EXIT_CRITICAL = 1002

# Official latest-release redirect (variant=msi points at a missing CDN object as of 2026; msix works)
$SlackPackageUrl = "https://api.slack.com/api/desktop.latestRelease?arch=x64&variant=msix&redirect=true"
$DownloadPath    = "$env:TEMP\SlackSetup.msix"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry  = "[$Timestamp] [$Level] $Message"
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

function Get-SlackInstallStatus {
    <#
    .SYNOPSIS
        Check if Slack is already installed (machine, user, Store, provisioned, or registry).
    #>
    
    # 1. Machine-wide installation (MSI) in Program Files
    $machinePaths = @(
        "${env:ProgramFiles}\Slack\slack.exe",
        "${env:ProgramFiles(x86)}\Slack\slack.exe"
    )
    foreach ($path in $machinePaths) {
        if (Test-Path $path) {
            try   { $version = (Get-Item $path).VersionInfo.ProductVersion }
            catch { $version = "Unknown" }
            return @{ Installed = $true; Path = $path; Version = $version; InstallType = "Machine" }
        }
    }
    
    # 2. User-level installation
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($profile in $userProfiles) {
        $userSlackPath = Join-Path $profile.FullName "AppData\Local\slack\slack.exe"
        if (Test-Path $userSlackPath) {
            try   { $version = (Get-Item $userSlackPath).VersionInfo.ProductVersion }
            catch { $version = "Unknown" }
            return @{ Installed = $true; Path = $userSlackPath; Version = $version; InstallType = "User ($($profile.Name))" }
        }
    }
    
    # 3. Windows Store / MSIX per-user registration
    try {
        $storeApp = Get-AppxPackage -AllUsers -Name "*Slack*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($storeApp) {
            return @{
                Installed   = $true
                Path        = $storeApp.InstallLocation
                Version     = $storeApp.Version
                InstallType = "Store (AppxPackage)"
            }
        }
    }
    catch { }
    
    # 4. Provisioned MSIX (machine-wide staging; registered per-user on next sign-in)
    #    Note: Get-AppxProvisionedPackage does NOT have InstallLocation or Version properties.
    #    Path comes from InstallPath (Win10 1803+); version is embedded in PackageName.
    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -like "*slack*" -or $_.DisplayName -like "*Slack*" } |
            Select-Object -First 1
        if ($provisioned) {
            # PackageName format: Publisher_Major.Minor.Build.Rev_arch__token
            $verMatch = [regex]::Match($provisioned.PackageName, '_(\d+\.\d+[\.\d]*)_')
            $version  = if ($verMatch.Success) { $verMatch.Groups[1].Value } else { "Unknown" }
            $instPath = if ($provisioned.PSObject.Properties['InstallPath'] -and $provisioned.InstallPath) {
                            $provisioned.InstallPath
                        } else { "Provisioned (path available after first user sign-in)" }
            return @{
                Installed   = $true
                Path        = $instPath
                Version     = $version
                InstallType = "Provisioned (MSIX)"
            }
        }
    }
    catch { }
    
    # 5. Registry (backup method)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($regPath in $regPaths) {
        try {
            $regItem = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -like "*Slack*" } |
                       Select-Object -First 1
            if ($regItem) {
                return @{
                    Installed   = $true
                    Path        = $regItem.InstallLocation
                    Version     = $regItem.DisplayVersion
                    InstallType = "Machine (Registry)"
                }
            }
        }
        catch { }
    }
    
    return @{ Installed = $false; Path = $null; Version = $null; InstallType = $null }
}

function Install-Slack {
    <#
    .SYNOPSIS
        Download Slack MSIX and provision for all users.
        Slack no longer serves a working MSI at the API redirect target as of 2026.
    #>
    Write-Log "Starting Slack installation..."
    
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    Write-Log "Download URL: $SlackPackageUrl"

    # -- Download with retry --
    $maxRetries    = 3
    $retryCount    = 0
    $downloadOk    = $false

    while (-not $downloadOk -and $retryCount -lt $maxRetries) {
        try {
            if ($retryCount -gt 0) {
                Write-Log "Retry attempt $retryCount of $maxRetries (waiting 15 s)..." -Level "WARNING"
                Start-Sleep -Seconds 15
            }
            Write-Log "Downloading Slack MSIX (attempt $($retryCount + 1))..."
            Invoke-WebRequest -Uri $SlackPackageUrl -OutFile $DownloadPath -UseBasicParsing -TimeoutSec 600
            if (Test-Path $DownloadPath) { $downloadOk = $true }
        }
        catch {
            $retryCount++
            Write-Log "Download attempt failed: $($_.Exception.Message)" -Level "WARNING"
            if (Test-Path $DownloadPath) { Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue }
        }
    }

    if (-not $downloadOk) {
        throw "Failed to download Slack MSIX after $maxRetries attempts"
    }

    $fileSize = (Get-Item $DownloadPath).Length / 1MB
    Write-Log "Downloaded: $DownloadPath ($([math]::Round($fileSize, 2)) MB)"
    
    if ($fileSize -lt 80) {
        Write-Log "Downloaded file appears too small (expected ~150 MB for MSIX)" -Level "WARNING"
    }
    
    Write-Log "Provisioning Slack MSIX for all users (Add-AppxProvisionedPackage)..."
    try {
        $provResult = Add-AppxProvisionedPackage -Online -PackagePath $DownloadPath -SkipLicense -Regions "all" -ErrorAction Stop
        Write-Log "Slack provisioned successfully (DisplayName: $($provResult.DisplayName))"
        return $true
    }
    catch {
        Write-Log "Provisioning error: $_" -Level "ERROR"
        throw
    }
    finally {
        if (Test-Path $DownloadPath) {
            Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
            Write-Log "Cleaned up temporary installer"
        }
    }
}

function Wait-ForSlackInstall {
    param([int]$MaxWaitSeconds = 60)
    Write-Log "Waiting for Slack to be detectable (max $MaxWaitSeconds s)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
        $s = Get-SlackInstallStatus
        if ($s.Installed) {
            Write-Log "Slack detected after $([math]::Round($sw.Elapsed.TotalSeconds, 0)) s"
            return $s
        }
        Start-Sleep -Seconds 5
    }
    $sw.Stop()
    Write-Log "Verification wait timed out after $MaxWaitSeconds s" -Level "WARNING"
    return $null
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName v$ScriptVersion Started"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User Context: $env:USERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "Script Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    # -- Check if already installed --
    $slackStatus = Get-SlackInstallStatus
    
    if ($slackStatus.Installed) {
        Write-Log "Slack is already installed"
        Write-Log "Path: $($slackStatus.Path)"
        Write-Log "Version: $($slackStatus.Version)"
        Write-Log "Install Type: $($slackStatus.InstallType)"
        Write-Log "=========================================="
        Write-Summary -Status "OK" -Message "Slack already installed v$($slackStatus.Version)"
        Write-Host "Path: $($slackStatus.Path)"
        Write-Host "Install Type: $($slackStatus.InstallType)"
        exit $EXIT_SUCCESS
    }
    
    # -- Install --
    Write-Log "Slack not installed. Starting installation..."
    Install-Slack
    
    # -- Verify --
    $verifyStatus = Wait-ForSlackInstall -MaxWaitSeconds 60

    if ($verifyStatus -and $verifyStatus.Installed) {
        Write-Log "Installation verified"
        Write-Log "Version: $($verifyStatus.Version)"
        Write-Log "Path: $($verifyStatus.Path)"
        Write-Log "=========================================="
        Write-Log "Script completed successfully!"
        Write-Summary -Status "OK" -Message "Slack installed successfully v$($verifyStatus.Version)"
        Write-Host "Path: $($verifyStatus.Path)"
        Write-Host "Install Type: $($verifyStatus.InstallType)"
        exit $EXIT_SUCCESS
    }
    else {
        Write-Log "Slack not detected after install - provisioning may still be in progress" -Level "WARNING"
        Write-Summary -Status "WARNING" -Message "Slack install ran but could not be immediately verified (may finalise on next user sign-in)"
        exit $EXIT_WARNING
    }
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Slack installation failed - $_"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Script execution ended"
}
