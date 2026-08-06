<#
.SYNOPSIS
    Check that Tailscale VPN is not installed (compliance / removal verification).

.DESCRIPTION
    Inverse of Check_Tailscale_Installed.ps1: desired state is no Tailscale.
    Uses the same detection (binaries, uninstall registry, services) as the install check.

    Exit Codes:
    - 0    = OK (Tailscale not present)
    - 1001 = Warning (Tailscale still present but service not running)
    - 1002 = Critical (Tailscale installed and service running, or installed without the warning path)

.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Tailscale_Not_Installed.ps1" -Raw)
    Or:               powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Tailscale_Not_Installed.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Tailscale_Not_Installed.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"
$ScriptName = "Check_Tailscale_Not_Installed"
$LogFile = "$env:TEMP\${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-TailscaleStatus {
    $result = @{
        Installed = $false
        Path = $null
        Version = $null
        ServiceFound = $false
        ServiceRunning = $false
        Details = $null
    }

    $paths = @(
        "${env:ProgramFiles}\Tailscale\tailscale.exe",
        "${env:ProgramFiles}\Tailscale\tailscale-ipn.exe",
        "${env:ProgramFiles(x86)}\Tailscale IPN\tailscale-ipn.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) {
            $result.Installed = $true
            $result.Path = $p
            try {
                $result.Version = (Get-Item -LiteralPath $p -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
            } catch { $result.Version = "Unknown" }
            break
        }
    }

    if (-not $result.Installed) {
        $uninstall = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Tailscale*" } | Select-Object -First 1
        if ($uninstall) {
            $result.Installed = $true
            $result.Version = $uninstall.DisplayVersion
            $result.Path = $uninstall.InstallLocation
            $result.Details = "Registry"
        }
    }

    $svcNames = @("Tailscale", "tailscale-ipn")
    foreach ($name in $svcNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
            $result.ServiceFound = $true
            $result.ServiceRunning = ($svc.Status -eq "Running")
            $result.Details = "Service: $($svc.Status) | StartType: $($svc.StartType)"
            break
        }
    }

    if ($result.Installed -and -not $result.Details) { $result.Details = "Binary or registry" }
    return $result
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "Tailscale absence check - $env:COMPUTERNAME"
$status = Get-TailscaleStatus

if (-not $status.Installed) {
    Write-Log "Tailscale is not installed (compliant)" -Level "INFO"
    Write-Host "OK: Tailscale is not installed on this machine."
    exit $EXIT_SUCCESS
}

if ($status.ServiceFound -and -not $status.ServiceRunning) {
    Write-Log "Tailscale still present; service not running" -Level "WARN"
    Write-Host "WARNING: Tailscale is still installed (service not running). Run Remove_Tailscale.ps1. $($status.Details)"
    exit $EXIT_WARNING
}

$ver = if ($status.Version) { " v$($status.Version)" } else { "" }
Write-Log "Tailscale is installed (non-compliant)$ver" -Level "ERROR"
Write-Host "CRITICAL: Tailscale VPN is installed$ver. Run Remove_Tailscale.ps1. $($status.Details)"
exit $EXIT_CRITICAL
