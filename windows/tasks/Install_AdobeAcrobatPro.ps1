<#
.SYNOPSIS
    Install Adobe Acrobat Pro DC (Windows) via winget.

.DESCRIPTION
    Remediation script for N-Sight: installs Adobe Acrobat Pro when a check reports
    it is missing. Uses winget package Adobe.Acrobat.Pro (official).

    Licensing is not automated: users typically sign in with an Adobe ID or your
    org’s serial/Named User licensing after install (Creative Cloud / Acrobat plan).

    Exit codes: 0 = success, 1001 = warning/already handled failure, 1002 = critical.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_AdobeAcrobatPro.ps1"
.NOTES
    Package: Adobe.Acrobat.Pro (typical binary: Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe).
    Requires: winget (App Installer). Run elevated if your deployment policy requires it.
#>

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Install_AdobeAcrobatPro"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
if (-not (Test-Path $LogDir)) {
    $LogDir = Join-Path $env:ProgramData "nsight\logs\$(Get-Date -Format 'yyyyMMdd')"
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
}
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

$WINGET_PACKAGE_ID = "Adobe.Acrobat.Pro"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if ($LogFile -and (Test-Path (Split-Path $LogFile -Parent))) {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Get-WingetPath {
    $searchPaths = @(
        "$env:ProgramFiles\WindowsApps",
        "${env:ProgramFiles(x86)}\WindowsApps"
    )
    foreach ($basePath in $searchPaths) {
        if (Test-Path $basePath) {
            $winget = Get-ChildItem -Path $basePath -Recurse -Filter "winget.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($winget) { return $winget.FullName }
        }
    }
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-AcrobatProInstallStatus {
    $candidates = @(
        "${env:ProgramFiles}\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat DC\Acrobat\Acrobat.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            try {
                $ver = (Get-Item $path).VersionInfo.ProductVersion
                return @{ Installed = $true; Path = $path; Version = $ver }
            } catch {
                return @{ Installed = $true; Path = $path; Version = "Unknown" }
            }
        }
    }
    try {
        $regPaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($rp in $regPaths) {
            $reg = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Publisher -match "Adobe" -and
                    $_.DisplayName -match "Adobe Acrobat" -and
                    $_.DisplayName -notmatch "Reader"
                } | Select-Object -First 1
            if ($reg) {
                return @{ Installed = $true; Path = $reg.InstallLocation; Version = $reg.DisplayVersion }
            }
        }
    } catch { }
    return @{ Installed = $false; Path = $null; Version = $null }
}

function Invoke-WingetInstallAcrobatPro {
    $wingetPath = Get-WingetPath
    if (-not $wingetPath) {
        Write-Log "winget.exe not found" -Level "ERROR"
        return $false
    }
    Write-Log "winget install $WINGET_PACKAGE_ID..."
    try {
        $proc = Start-Process -FilePath $wingetPath -ArgumentList @(
            "install", "--id", $WINGET_PACKAGE_ID,
            "--accept-source-agreements", "--accept-package-agreements", "--silent"
        ) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        $code = $proc.ExitCode
        if ($code -eq 0) { return $true }
        if ($code -eq -1978335189) { Write-Log "Package already installed (winget)" -Level "INFO"; return $true }
        if ($code -eq -1978335212) { Write-Log "No newer package versions (may already be current)" -Level "INFO"; return $true }
        Write-Log "winget exit code: $code" -Level "WARN"
        return $false
    } catch {
        Write-Log "winget install failed: $_" -Level "ERROR"
        return $false
    }
}

Write-Log "=========================================="
Write-Log "Adobe Acrobat Pro installation — $ScriptName"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "Log: $LogFile"

$status = Get-AcrobatProInstallStatus
if ($status.Installed) {
    Write-Log "Acrobat Pro already present: $($status.Path) ($($status.Version))"
    Write-Host ""
    Write-Host "OK: Adobe Acrobat Pro already installed (v$($status.Version))"
    exit $EXIT_SUCCESS
}

if (-not (Invoke-WingetInstallAcrobatPro)) {
    Write-Log "Installation step failed" -Level "ERROR"
    exit $EXIT_CRITICAL
}

Start-Sleep -Seconds 2
$verify = Get-AcrobatProInstallStatus
if ($verify.Installed) {
    Write-Log "Verified: $($verify.Path) ($($verify.Version))"
    Write-Host ""
    Write-Host "OK: Adobe Acrobat Pro installed (v$($verify.Version))"
    exit $EXIT_SUCCESS
}

Write-Log "Install reported success but Acrobat.exe not found in expected locations" -Level "WARN"
Write-Host ""
Write-Host "WARNING: Acrobat Pro may need a sign-out or reboot. Sign in with your Adobe ID if prompted."
exit $EXIT_WARNING
