<#
.SYNOPSIS
    Check if HEVC/MOV (e.g. iPhone video) playback is available on Windows.
    
.DESCRIPTION
    Verifies that at least one HEVC decoder or player is installed so the system
    can play iPhone MOV/HEVC video files. Checks for:
    - Microsoft HEVC Video Extensions (Store)
    - VLC Media Player
    - LAV Filters (DirectShow HEVC)
    - MPC-HC
    
    Designed for N-Sight RMM monitoring; use with Install_HEVC_Codec.ps1 as remediation.
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_HEVC_Installed.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_HEVC_Installed.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_HEVC_Installed.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
.OUTPUTS
    Exit 0    = Success (HEVC/MOV playback available)
    Exit 1002 = Critical (no HEVC decoder or player found)
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Check_HEVC_Installed"
$LogFile = "$env:TEMP\${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

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

function Test-HEVCAvailable {
    <#
    .SYNOPSIS
        Returns $true if any HEVC/MOV playback capability is present.
    #>
    # Microsoft HEVC Video Extensions (Store package)
    $hevcPkgs = @(
        "Microsoft.HEVCVideoExtensions"
    )
    foreach ($id in $hevcPkgs) {
        $pkg = Get-AppxPackage -Name $id -AllUsers -ErrorAction SilentlyContinue
        if ($pkg) {
            Write-Log "Found: Microsoft HEVC Video Extensions" -Level "SUCCESS"
            return $true
        }
    }

    # VLC (built-in HEVC/MOV)
    $vlcPaths = @(
        "${env:ProgramFiles}\VideoLAN\VLC\vlc.exe",
        "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe"
    )
    foreach ($p in $vlcPaths) {
        if (Test-Path $p) {
            Write-Log "Found: VLC Media Player at $p" -Level "SUCCESS"
            return $true
        }
    }

    # LAV Filters (DirectShow HEVC)
    $lavPaths = @(
        "${env:ProgramFiles}\LAV Filters\LAVVideo.ax",
        "${env:ProgramFiles(x86)}\LAV Filters\LAVVideo.ax"
    )
    foreach ($p in $lavPaths) {
        if (Test-Path $p) {
            Write-Log "Found: LAV Filters at $p" -Level "SUCCESS"
            return $true
        }
    }

    # MPC-HC (uses LAV or built-in)
    $mpcPaths = @(
        "${env:ProgramFiles}\MPC-HC\mpc-hc64.exe",
        "${env:ProgramFiles(x86)}\MPC-HC\mpc-hc.exe"
    )
    foreach ($p in $mpcPaths) {
        if (Test-Path $p) {
            Write-Log "Found: MPC-HC at $p" -Level "SUCCESS"
            return $true
        }
    }

    return $false
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName - HEVC/MOV playback check"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "Log File: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "Administrator privileges required" -Level "ERROR"
    Write-Host ""
    Write-Host "CRITICAL: Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    $available = Test-HEVCAvailable
    if ($available) {
        Write-Log "HEVC/MOV playback is available on this system."
        Write-Host ""
        Write-Host "OK: HEVC or MOV (iPhone video) playback is available"
        exit $EXIT_SUCCESS
    }

    Write-Log "No HEVC decoder or player found." -Level "ERROR"
    Write-Host ""
    Write-Host "CRITICAL: No HEVC/MOV playback - run Install_HEVC_Codec.ps1 to install"
    exit $EXIT_CRITICAL
}
catch {
    Write-Log "Check failed: $_" -Level "ERROR"
    Write-Host ""
    Write-Host "CRITICAL: Check failed - $_"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Check ended"
}
