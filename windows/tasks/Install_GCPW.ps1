<#
.SYNOPSIS
    Install GCPW (Google Credential Provider for Windows) and configure registry.
.DESCRIPTION
    Downloads and installs GCPW Enterprise 64-bit MSI, then writes all required
    registry keys. Idempotent — safe to re-run.
    Prerequisite: Chrome 81+ must already be installed (Google requirement).
.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_GCPW.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_GCPW.ps1")
.NOTES
    Exit: 0=OK, 1001=Warning, 1002=Critical
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$EXIT_SUCCESS  = 0
$EXIT_WARNING  = 1001
$EXIT_CRITICAL = 1002

# --- Config ---
$EnrollmentToken = "5f8a8760-820d-404a-bc6e-0a7cda2bf96a"
$DomainsAllowed  = "helfy.co,doktorabc.com"
$ValidityDays    = 365

$CloudMgmtPath = "HKLM:\SOFTWARE\Policies\Google\CloudManagement"
$GCPWPath      = "HKLM:\SOFTWARE\Google\GCPW"
$GCPWUrl       = "https://dl.google.com/credentialprovider/gcpwstandaloneenterprise64.msi"

$LogDir  = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir "Install_GCPW_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log { param([string]$m, [string]$l = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$l] $m"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Set-RegKey { param([string]$Path, [string]$Name, [object]$Value, [string]$Type = "String")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Test-ChromeInstalled {
    foreach ($p in "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
                   "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") {
        if (Test-Path $p) { return $true }
    }
    return $false
}

# --- Main ---
Write-Log "Install_GCPW started on $env:COMPUTERNAME"

if (-not (Test-ChromeInstalled)) {
    Write-Log "Chrome 81+ required before GCPW. Install Chrome first." "ERROR"
    Write-Host "CRITICAL: Chrome not installed — install Chrome then retry."
    exit $EXIT_CRITICAL
}

try {
    $msi = Join-Path $env:TEMP "gcpwstandaloneenterprise64.msi"
    Write-Log "Downloading GCPW MSI..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $GCPWUrl -OutFile $msi -UseBasicParsing -TimeoutSec 300
    if (-not (Test-Path $msi)) { throw "Downloaded file missing" }

    Write-Log "Installing GCPW..."
    $proc = Start-Process msiexec.exe -ArgumentList "/i", "`"$msi`"", "/qn" -Wait -PassThru -NoNewWindow
    # 0=success, 3010/1641=restart required (still success)
    if ($proc.ExitCode -notin 0, 3010, 1641) { throw "msiexec exit code $($proc.ExitCode)" }

    Write-Log "Setting registry..."
    Set-RegKey $CloudMgmtPath "EnrollmentToken"          $EnrollmentToken
    Set-RegKey $GCPWPath      "domains_allowed_to_login" $DomainsAllowed
    Set-RegKey $GCPWPath      "is_enrolled_to_google"    1   "DWord"
    Set-RegKey $GCPWPath      "enable_multi_user_login"  1   "DWord"
    Set-RegKey $GCPWPath      "use_shorter_account_name" 1   "DWord"
    Set-RegKey $GCPWPath      "enable_dm_enrollment"     1   "DWord"
    Set-RegKey $GCPWPath      "validity_period_in_days"  $ValidityDays "DWord"

    Write-Log "Cleaning up..."
    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    Write-Host "OK: GCPW installed and configured on $env:COMPUTERNAME. Domains: $DomainsAllowed"
    Write-Log "Done" "INFO"
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Failed: $_" "ERROR"
    Write-Host "CRITICAL: GCPW install failed on $env:COMPUTERNAME — $_"
    exit $EXIT_CRITICAL
}
