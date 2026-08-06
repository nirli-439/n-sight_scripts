<#
.SYNOPSIS
    Install OpenSSH Server and ensure the sshd service is running.

.DESCRIPTION
    Remediation script for when the readiness check reports OpenSSH Server
    is not installed. Sets policy to allow optional features from Windows Update
    (fixes 0x800f0950 in WSUS environments), then tries Add-WindowsCapability;
    on 0x800f0950 skips DISM and installs via Win32-OpenSSH MSI (silent /qn then
    /passive) or winget. Configures sshd for automatic start and starts it.
    Detects existing install by service or path so re-runs exit 0.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_OpenSSH.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_OpenSSH.ps1")
.NOTES
    Author: IT Admin
    Version: 1.2
    Requires: Administrator privileges
    Platform: Windows 10/11

.OUTPUTS
    Exit 0    = Success
    Exit 1001 = Warning
    Exit 1002 = Critical/Error
#>

# Do not use #Requires -RunAsAdministrator (would exit 1 and hide our exit codes)
# Error 0x800f0950 = Windows cannot get OpenSSH from Windows Update (WSUS/policy/no internet).
# This script: sets policy to allow optional content from WU, then capability; on 0x800f0950 skips DISM and uses MSI + winget.

$ErrorActionPreference = "Continue"
$ScriptName = "Install_OpenSSH"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002
$Script:ExitCode = $EXIT_CRITICAL

# Allow optional features/repair from Windows Update (fixes 0x800f0950 in WSUS environments)
function Set-OptionalComponentPolicyAllowWU {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing"
    try {
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name "RepairContentServerSource" -Value 2 -Type DWord -Force -ErrorAction Stop
        Write-Log "Policy set: optional component repair source = Windows Update (2)"
        return $true
    } catch {
        Write-Log "Could not set optional component policy: $_" -Level "WARN"
        return $false
    }
}

function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Administrator privileges required" -Level "ERROR"
    exit $EXIT_CRITICAL
}

# Detect existing install by service or binary (capability = System32; Win32-OpenSSH MSI = Program Files)
function Test-OpenSSHAlreadyInstalled {
    $svc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($svc) { return $true }
    if (Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe") { return $true }
    if (Test-Path "${env:ProgramFiles}\OpenSSH\sshd.exe") { return $true }
    if (Test-Path "${env:ProgramFiles(x86)}\OpenSSH\sshd.exe") { return $true }
    return $false
}

function Start-EnsureSshdService {
    # If Win32-OpenSSH MSI installed binaries but no service, run install-sshd.ps1
    $openSSHDir = "${env:ProgramFiles}\OpenSSH"
    if (-not (Test-Path $openSSHDir)) { $openSSHDir = "${env:ProgramFiles(x86)}\OpenSSH" }
    $installScript = "$openSSHDir\install-sshd.ps1"
    $svc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if (-not $svc -and (Test-Path $installScript)) {
        Write-Log "Installing sshd service via install-sshd.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript -ErrorAction SilentlyContinue
    }
    $svc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.StartType -ne 'Automatic') { Set-Service -Name "sshd" -StartupType Automatic -ErrorAction SilentlyContinue; Write-Log "sshd set to Automatic" }
        if ($svc.Status -ne 'Running') { Start-Service -Name "sshd" -ErrorAction SilentlyContinue; Write-Log "sshd started" }
    }
}

# MSI success exit codes: 0=OK, 3010=restart, 1641=restart required
function Test-MSISuccess { param([int]$Code) return $Code -eq 0 -or $Code -eq 3010 -or $Code -eq 1641 }

# Silent MSI install: try /qn first (fully silent), then /passive if needed (e.g. Session 0/RMM)
function Invoke-MSIInstall {
    param([string]$MsiPath, [string]$MsiLog)
    $argQn = "/i", "`"$MsiPath`"", "ADDLOCAL=Server", "/norestart", "/l*v", "`"$MsiLog`"", "/qn"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $argQn -Wait -PassThru
    $exitCode = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
    if (Test-MSISuccess $exitCode) { return $exitCode }
    Write-Log "MSI /qn returned $exitCode; trying /passive..." -Level "WARN"
    $argPassive = "/i", "`"$MsiPath`"", "ADDLOCAL=Server", "/norestart", "/l*v", "`"$MsiLog`"", "/passive"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $argPassive -Wait -PassThru
    $exitCode = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
    return $exitCode
}

function Install-OpenSSHViaMSI {
    $is64 = [Environment]::Is64BitOperatingSystem
    $msiUrls = @(
        "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0/OpenSSH-Win64-9.5.0.0.msi",
        "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.4.0.0p1-Beta/OpenSSH-Win64-9.4.0.0p1-Beta.msi"
    )
    if (-not $is64) {
        $msiUrls = @(
            "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0/OpenSSH-Win32-9.5.0.0.msi",
            "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.4.0.0p1-Beta/OpenSSH-Win32-9.4.0.0p1-Beta.msi"
        )
    }
    $msiPath = "$env:TEMP\OpenSSH-Server.msi"
    $msiLog = "$env:TEMP\OpenSSH-MSI-install.log"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($msiUrl in $msiUrls) {
        try {
            Write-Log "Downloading MSI: $msiUrl"
            Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Log "MSI download failed: $_" -Level "WARN"
            continue
        }
        if (-not (Test-Path $msiPath)) { continue }

        Write-Log "Running MSI silent install (log: $msiLog)..."
        $exitCode = Invoke-MSIInstall -MsiPath $msiPath -MsiLog $msiLog
        if (Test-MSISuccess $exitCode) {
            Write-Log "Win32-OpenSSH MSI install succeeded (exit $exitCode)"
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            return $true
        }
        Write-Log "MSI install failed with exit $exitCode for this URL; trying next..." -Level "WARN"
    }

    Write-Log "MSI install failed. Check log: $msiLog" -Level "WARN"
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    return $false
}

# Winget install OpenSSH Server (no Windows Update; works when MSI download fails)
function Install-OpenSSHViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Log "winget not found; skipping winget install" -Level "WARN"; return $false }
    Write-Log "Installing OpenSSH.Server via winget (silent)..."
    $out = & winget install --id Microsoft.OpenSSH.Preview --accept-package-agreements --accept-source-agreements --silent 2>&1
    $ok = $LASTEXITCODE -eq 0
    if ($ok) { Write-Log "winget install succeeded" } else { Write-Log "winget install failed: $out" -Level "WARN" }
    return $ok
}

try {
    # If already installed (service or binary), ensure running and exit 0
    if (Test-OpenSSHAlreadyInstalled) {
        Write-Log "OpenSSH Server already present (service or binary)"
        Start-EnsureSshdService
        Write-Host "OK: OpenSSH Server installed and running"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    # Get capability (may be null in remote session)
    $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1

    if ($cap -and $cap.State -eq 'Installed') {
        Write-Log "OpenSSH Server capability already installed"
        Start-EnsureSshdService
        Write-Host "OK: OpenSSH Server installed and running"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    $capName = $null
    if ($cap) { $capName = $cap.Name } else { $capName = "OpenSSH.Server~~~~0.0.1.0" }

    # Allow optional features from Windows Update (fixes 0x800f0950 in WSUS/locked environments)
    Set-OptionalComponentPolicyAllowWU | Out-Null

    # Try Add-WindowsCapability first
    $installed = $false
    $is0x800f0950 = $false
    try {
        Write-Log "Installing OpenSSH Server capability: $capName"
        $result = Add-WindowsCapability -Online -Name $capName -ErrorAction Stop
        if ($result.RestartNeeded) { Write-Log "Install succeeded; restart may be required" -Level "WARN" }
        $installed = $true
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Add-WindowsCapability failed: $errMsg" -Level "WARN"
        if ($errMsg -match "0x800f09") { $is0x800f0950 = $true; Write-Log "Error 0x800f09xx: Windows could not get OpenSSH from Windows Update. Using MSI/winget." -Level "WARN" }

        if ($is0x800f0950) {
            # DISM uses same source and fails with same error; skip DISM and go straight to MSI
            Write-Log "Skipping DISM (same 0x800f0950); installing via MSI..."
            $installed = Install-OpenSSHViaMSI
            if (-not $installed) { $installed = Install-OpenSSHViaWinget }
        } else {
            # Other errors: try DISM once, then MSI, then winget
            Write-Log "Trying DISM fallback..."
            $null = & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "DISM install succeeded"
                $installed = $true
            } else {
                Write-Log "DISM failed; trying MSI then winget..." -Level "WARN"
                $installed = Install-OpenSSHViaMSI
                if (-not $installed) { $installed = Install-OpenSSHViaWinget }
            }
        }
    }

    if ($installed) {
        Start-EnsureSshdService
        Write-Host "OK: OpenSSH Server installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    # One more check: maybe install completed but detection was delayed
    if (Test-OpenSSHAlreadyInstalled) {
        Write-Log "OpenSSH detected after install attempt; treating as success"
        Start-EnsureSshdService
        Write-Host "OK: OpenSSH Server installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    Write-Log "Install failed" -Level "ERROR"
    Write-Host "CRITICAL: OpenSSH Server install failed."
    Write-Host "Tip: Run this script locally on the machine (not via remote session) if install fails."
    $Script:ExitCode = $EXIT_CRITICAL
} catch {
    if (Test-OpenSSHAlreadyInstalled) {
        Write-Log "OpenSSH is already installed; treating as success" -Level "WARN"
        Start-EnsureSshdService
        Write-Host "OK: OpenSSH Server already installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Install failed: $_" -Level "ERROR"
        Write-Host "CRITICAL: OpenSSH Server install failed - $_"
        $Script:ExitCode = $EXIT_CRITICAL
    }
}

exit $Script:ExitCode
