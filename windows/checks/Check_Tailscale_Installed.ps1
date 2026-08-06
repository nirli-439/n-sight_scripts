<#
.SYNOPSIS
    Check if Tailscale VPN is installed and (optionally) running.

.DESCRIPTION
    This monitoring script checks for Tailscale installation:
    - Installation path (Program Files\Tailscale or Tailscale IPN)
    - tailscale-ipn service or Tailscale service
    - Version from executable or registry
    Designed for N-Sight RMM monitoring. Exit codes per N-Sight standards.

    Exit Codes:
    - 0    = OK (Tailscale installed; service running if present)
    - 1001 = Warning (installed but service not running)
    - 1002 = Critical (Tailscale NOT installed)

.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Tailscale_Installed.ps1" -Raw)
    Or:               powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Tailscale_Installed.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Tailscale_Installed.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"
$ScriptName = "Check_Tailscale_Installed"
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

Write-Log "Tailscale VPN check - $env:COMPUTERNAME"
$status = Get-TailscaleStatus

if (-not $status.Installed) {
    Write-Log "Tailscale is NOT installed" -Level "WARN"
    Write-Host "CRITICAL: Tailscale VPN is NOT installed. Run Install_Tailscale.ps1."
    exit $EXIT_CRITICAL
}

if ($status.ServiceFound -and -not $status.ServiceRunning) {
    Write-Log "Tailscale installed but service not running" -Level "WARN"
    Write-Host "WARNING: Tailscale is installed but service is not running. $($status.Details)"
    exit $EXIT_WARNING
}

$ver = if ($status.Version) { " v$($status.Version)" } else { "" }
Write-Log "Tailscale is installed and OK. $($status.Details)"
Write-Host "OK: Tailscale VPN is installed$ver. $($status.Details)"
exit $EXIT_SUCCESS
