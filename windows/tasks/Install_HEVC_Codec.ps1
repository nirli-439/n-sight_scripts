<#
.SYNOPSIS
    Install HEVC (H.265) codec so Windows can play iPhone MOV / HEVC video files.
    
.DESCRIPTION
    Enables playback of iPhone-recorded videos (MOV container, HEVC/H.265) on Windows.
    Installs HEVC video codec support using multiple methods:
    - Primary: Microsoft HEVC Video Extensions from MS Store
    - Fallback: VLC Media Player (built-in HEVC/MOV support)
    - Fallback: LAV Filters + MPC-HC (DirectShow HEVC decoder stack)
    
    Designed for N-Sight RMM deployment as automated task.
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Install_HEVC_Codec.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_HEVC_Codec.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_HEVC_Codec.ps1")
.NOTES
    Author: IT Admin
    Version: 2.0
    Requires: Administrator privileges, winget (App Installer)
    Platform: Windows 10/11
    
.OUTPUTS
    Exit 0    = Success (at least one HEVC decoder installed)
    Exit 1001 = Warning (partial installation)
    Exit 1002 = Critical/Error (no HEVC decoder could be installed)
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up web requests/downloads

$ScriptName = "Install_HEVC_Codec"
$ScriptVersion = "2.0"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Exit codes for N-Sight
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# Installation tracking
$Script:InstallResults = @{
    MicrosoftHEVC = $false
    VLC = $false
    LAVFilters = $false
    MPCHC = $false
}

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message, 
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
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
        Writes a concise summary for N-Sight dashboard display.
        Keep under 255 characters for best visibility.
    #>
    param(
        [ValidateSet("OK", "WARNING", "CRITICAL")]
        [string]$Status,
        [string]$Message
    )
    # First line is most visible in N-Sight UI
    Write-Host ""
    Write-Host "${Status}: $Message"
}

function Get-WingetPath {
    <#
    .SYNOPSIS
        Finds winget.exe path - works in SYSTEM context where PATH may not be set
    #>
    $searchPaths = @(
        "$env:ProgramFiles\WindowsApps",
        "${env:ProgramFiles(x86)}\WindowsApps"
    )
    
    foreach ($basePath in $searchPaths) {
        if (Test-Path $basePath) {
            $winget = Get-ChildItem -Path $basePath -Recurse -Filter "winget.exe" -ErrorAction SilentlyContinue | 
                      Select-Object -First 1
            if ($winget) {
                return $winget.FullName
            }
        }
    }
    
    # Fallback: check PATH
    $wingetPath = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wingetPath) {
        return $wingetPath.Source
    }
    
    return $null
}

function Test-WingetAvailable {
    <#
    .SYNOPSIS
        Verifies winget is available and functional
    #>
    $wingetPath = Get-WingetPath
    if (-not $wingetPath) {
        return $false
    }
    
    try {
        $result = & $wingetPath --version 2>&1
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Install-WithWinget {
    <#
    .SYNOPSIS
        Installs a package using winget with proper error handling
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,
        [string]$Source = "",
        [string]$DisplayName = ""
    )
    
    $name = if ($DisplayName) { $DisplayName } else { $PackageId }
    $wingetPath = Get-WingetPath
    
    if (-not $wingetPath) {
        Write-Log "winget.exe not found - cannot install $name" -Level "ERROR"
        return $false
    }
    
    # Build argument list
    $wingetArgs = @(
        "install"
        "--id", $PackageId
        "--accept-source-agreements"
        "--accept-package-agreements"
        "--silent"
    )
    
    if ($Source -ne "") {
        $wingetArgs += @("--source", $Source)
    }
    
    Write-Log "Installing $name..."
    
    try {
        $process = Start-Process -FilePath $wingetPath -ArgumentList $wingetArgs -Wait -PassThru -WindowStyle Hidden
        
        switch ($process.ExitCode) {
            0 {
                Write-Log "$name installed successfully" -Level "SUCCESS"
                return $true
            }
            -1978335189 {
                # Package already installed
                Write-Log "$name is already installed" -Level "INFO"
                return $true
            }
            default {
                Write-Log "Failed to install $name (Exit code: $($process.ExitCode))" -Level "WARN"
                return $false
            }
        }
    }
    catch {
        Write-Log "Error installing ${name}: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Install-MicrosoftHEVC {
    <#
    .SYNOPSIS
        Attempts to install Microsoft HEVC Video Extensions from MS Store
    #>
    Write-Log "Attempting Microsoft HEVC Video Extensions installation..."
    
    # Try from MS Store first
    $result = Install-WithWinget -PackageId "Microsoft.HEVCVideoExtensions" -Source "msstore" -DisplayName "Microsoft HEVC Video Extensions"
    
    if (-not $result) {
        # Retry without explicit source
        Write-Log "Retrying without explicit source..."
        $result = Install-WithWinget -PackageId "Microsoft.HEVCVideoExtensions" -DisplayName "Microsoft HEVC Video Extensions"
    }
    
    return $result
}

function Install-OpenSourceStack {
    <#
    .SYNOPSIS
        Installs open-source HEVC decoder stack (VLC, LAV Filters, MPC-HC)
    #>
    Write-Log "Installing open-source HEVC decoder stack..."
    
    # VLC - has built-in HEVC decoder
    $Script:InstallResults.VLC = Install-WithWinget -PackageId "VideoLAN.VLC" -DisplayName "VLC Media Player"
    
    # LAV Filters - DirectShow HEVC decoder
    $Script:InstallResults.LAVFilters = Install-WithWinget -PackageId "Gyan.LAVFilters" -DisplayName "LAV Filters"
    
    # MPC-HC - lightweight player using LAV Filters
    $Script:InstallResults.MPCHC = Install-WithWinget -PackageId "MPC-HC.MPC-HC" -DisplayName "MPC-HC"
}

function Get-InstallationSummary {
    <#
    .SYNOPSIS
        Returns a summary string of what was installed
    #>
    $installed = @()
    $failed = @()
    
    if ($Script:InstallResults.MicrosoftHEVC) { $installed += "MS HEVC" } else { $failed += "MS HEVC" }
    if ($Script:InstallResults.VLC) { $installed += "VLC" } else { $failed += "VLC" }
    if ($Script:InstallResults.LAVFilters) { $installed += "LAV Filters" } else { $failed += "LAV Filters" }
    if ($Script:InstallResults.MPCHC) { $installed += "MPC-HC" } else { $failed += "MPC-HC" }
    
    return @{
        Installed = $installed
        Failed = $failed
        HasHEVCCapability = ($Script:InstallResults.MicrosoftHEVC -or $Script:InstallResults.VLC -or $Script:InstallResults.LAVFilters)
    }
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
    # Verify winget is available
    if (-not (Test-WingetAvailable)) {
        Write-Log "winget not found - install App Installer (Microsoft.DesktopAppInstaller) first" -Level "ERROR"
        Write-Summary -Status "CRITICAL" -Message "winget not available - install App Installer first"
        exit $EXIT_CRITICAL
    }
    
    Write-Log "winget is available"
    
    # ========================================
    # Step 1: Try Microsoft HEVC Extension
    # ========================================
    $Script:InstallResults.MicrosoftHEVC = Install-MicrosoftHEVC
    
    if ($Script:InstallResults.MicrosoftHEVC) {
        Write-Log "Microsoft HEVC Extension installed - this is the preferred codec" -Level "SUCCESS"
    }
    else {
        Write-Log "Microsoft HEVC Extension unavailable (may require purchase) - trying alternatives" -Level "WARN"
    }
    
    # ========================================
    # Step 2: Install Open Source Alternatives
    # ========================================
    Install-OpenSourceStack
    
    # ========================================
    # Step 3: Generate Summary
    # ========================================
    Write-Log ""
    Write-Log "=========================================="
    Write-Log "Installation Summary"
    Write-Log "=========================================="
    
    $summary = Get-InstallationSummary
    
    foreach ($item in @("MicrosoftHEVC", "VLC", "LAVFilters", "MPCHC")) {
        $status = if ($Script:InstallResults[$item]) { "Installed" } else { "Not Installed" }
        $displayName = switch ($item) {
            "MicrosoftHEVC" { "Microsoft HEVC Video Extensions" }
            "VLC" { "VLC Media Player" }
            "LAVFilters" { "LAV Filters (DirectShow)" }
            "MPCHC" { "MPC-HC Media Player" }
        }
        Write-Log "${displayName}: $status"
    }
    
    Write-Log "=========================================="
    
    # Determine exit code based on results
    if ($summary.HasHEVCCapability) {
        if ($summary.Failed.Count -eq 0) {
            Write-Log "All components installed successfully!" -Level "SUCCESS"
            Write-Summary -Status "OK" -Message "HEVC codec installed - $($summary.Installed -join ', ')"
            exit $EXIT_SUCCESS
        }
        else {
            Write-Log "HEVC capability available but some components failed" -Level "SUCCESS"
            Write-Summary -Status "OK" -Message "HEVC codec available via $($summary.Installed -join ', ')"
            exit $EXIT_SUCCESS
        }
    }
    else {
        Write-Log "No HEVC decoder could be installed!" -Level "ERROR"
        Write-Summary -Status "CRITICAL" -Message "Failed to install any HEVC decoder"
        exit $EXIT_CRITICAL
    }
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "HEVC installation failed - $_"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Script execution ended"
    Write-Log "Log saved to: $LogFile"
}
