<#
.SYNOPSIS
    Install GCPW (Google Credential Provider for Windows) and set registry.
.DESCRIPTION
    1. Install GCPW Enterprise 64-bit (MSI): downloads to %TEMP%\gcpw and installs from there.
    2. Apply GCPW registry keys from set_gcpw_token.reg (local file or embedded).
    Deploy script and optionally set_gcpw_token.reg via N-Sight. Edit embedded values or the
    .reg file with your token and domains.
    Prerequisite: Chrome 81+ must be installed (Google requirement; missing Chrome causes 73120).
.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_GCPW.ps1"
    N-Sight:         Upload script as payload; optionally upload set_gcpw_token.reg to the same
                     location as the script (or rely on embedded config below).
.NOTES
    Exit: 0=OK, 1001=Warning, 1002=Critical
#>

#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Config - embedded reg content (edit values below). Script is self-contained.
$GCPWConfig = @"
Windows Registry Editor Version 5.00
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\CloudManagement]
"EnrollmentToken"="5f8a8760-820d-404a-bc6e-0a7cda2bf96a"
[HKEY_LOCAL_MACHINE\SOFTWARE\Google\GCPW]
"domains_allowed_to_login"="helfy.co,doktorabc.com"
"is_enrolled_to_google"=dword:00000001
"enable_multi_user_login"=dword:00000001
"use_shorter_account_name"=dword:00000001
"enable_dm_enrollment"=dword:00000001
"validity_period_in_days"=dword:0000001e
"@

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# Log to C:\logs\<date> per WINDOWS_COMPLIANCE.md
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Install_GCPW_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Payload directory (GCPW MSI download)
$PayloadDir = Join-Path $env:TEMP "gcpw"
$GCPWUrl = "https://dl.google.com/credentialprovider/gcpwstandaloneenterprise64.msi"
# Reg file: same dir as script or ..\gcpw\ (when deployed via N-Sight with companion file)
$RegFileCandidates = @()
if ($PSScriptRoot) {
    $RegFileCandidates += Join-Path $PSScriptRoot "set_gcpw_token.reg"
    $RegFileCandidates += Join-Path (Join-Path $PSScriptRoot "..") "gcpw\set_gcpw_token.reg"
}
$CloudManagementPath = "HKLM:\SOFTWARE\Policies\Google\CloudManagement"
$GCPWPath = "HKLM:\SOFTWARE\Google\GCPW"

function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    if ($LogFile -and (Test-Path (Split-Path $LogFile -Parent))) { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue }
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ChromeInstalled {
    $paths = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    return $false
}

function Get-ConfigFromRegContent {
    param([string]$Content)
    $cfg = @{}
    if ($Content -match '"EnrollmentToken"="([^"]*)"') { $cfg.EnrollmentToken = $Matches[1] }
    if ($Content -match '"domains_allowed_to_login"="([^"]*)"') { $cfg.DomainsAllowed = $Matches[1] }
    if ($Content -match '"is_enrolled_to_google"=dword:([0-9a-fA-F]+)') { $cfg.IsEnrolled = [int][Convert]::ToInt32($Matches[1], 16) }
    if ($Content -match '"enable_multi_user_login"=dword:([0-9a-fA-F]+)') { $cfg.EnableMultiUserLogin = [int][Convert]::ToInt32($Matches[1], 16) }
    if ($Content -match '"use_shorter_account_name"=dword:([0-9a-fA-F]+)') { $cfg.UseShorterAccountName = [int][Convert]::ToInt32($Matches[1], 16) }
    if ($Content -match '"enable_dm_enrollment"=dword:([0-9a-fA-F]+)') { $cfg.EnableDmEnrollment = [int][Convert]::ToInt32($Matches[1], 16) }
    if ($Content -match '"validity_period_in_days"=dword:([0-9a-fA-F]+)') { $cfg.ValidityPeriodInDays = [int][Convert]::ToInt32($Matches[1], 16) }
    return $cfg
}

function Get-Config {
    foreach ($regPath in $RegFileCandidates) {
        if ($regPath -and (Test-Path -LiteralPath $regPath)) {
            $content = Get-Content -Path $regPath -Raw -ErrorAction SilentlyContinue
            if ($content) {
                $cfg = Get-ConfigFromRegContent -Content $content
                if ($cfg.EnrollmentToken -and $cfg.DomainsAllowed) {
                    $script:ConfigSource = "set_gcpw_token.reg (local)"
                    return $cfg
                }
            }
        }
    }
    $script:ConfigSource = "embedded"
    return Get-ConfigFromRegContent -Content $GCPWConfig
}

function Install-GCPW {
    # Ensure payload directory exists
    if (-not (Test-Path $PayloadDir)) {
        New-Item -Path $PayloadDir -ItemType Directory -Force | Out-Null
        Write-Log "Created payload directory: $PayloadDir"
    }

    $msiName = "gcpwstandaloneenterprise64.msi"
    $downloadPath = Join-Path $PayloadDir $msiName

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "Downloading GCPW to $PayloadDir..."
    try {
        Invoke-WebRequest -Uri $GCPWUrl -OutFile $downloadPath -UseBasicParsing -TimeoutSec 300
    } catch {
        Write-Log "Download failed: $_" -Level "ERROR"
        throw
    }
    if (-not (Test-Path $downloadPath)) { throw "Downloaded file missing" }

    Write-Log "Installing GCPW from $PayloadDir..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$downloadPath`"", "/qn" -Wait -PassThru -NoNewWindow
    # 0=success, 3010/1641=restart required (success)
    if ($proc.ExitCode -notin 0, 3010, 1641) {
        Write-Log "Installer exit code: $($proc.ExitCode)" -Level "ERROR"
        throw "GCPW installation failed with exit code $($proc.ExitCode)."
    }
}

function Set-RegKey {
    param([string]$Path, [string]$Name, [object]$Value, [string]$Type = "String")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    try {
        $null = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force
    } catch {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
}

# --- Main ---
if (-not (Test-Admin)) {
    Write-Log "Requires Administrator." -Level "ERROR"
    exit $EXIT_CRITICAL
}

if (-not (Test-ChromeInstalled)) {
    Write-Log "Chrome 81+ is required before GCPW (Google requirement). Install Chrome first." -Level "ERROR"
    Write-Log "Run Install_Chrome.ps1 or install Chrome manually, then retry." -Level "ERROR"
    exit $EXIT_CRITICAL
}

$cfg = Get-Config
Write-Log "Config from: $ConfigSource"
$EnrollmentToken = $cfg.EnrollmentToken
$DomainsAllowed = $cfg.DomainsAllowed
$IsEnrolled = if ($cfg.IsEnrolled -ne $null) { $cfg.IsEnrolled } else { 1 }
$EnableMultiUserLogin = if ($cfg.EnableMultiUserLogin -ne $null) { $cfg.EnableMultiUserLogin } else { 1 }
$UseShorterAccountName = if ($cfg.UseShorterAccountName -ne $null) { $cfg.UseShorterAccountName } else { 1 }
$EnableDmEnrollment = if ($cfg.EnableDmEnrollment -ne $null) { $cfg.EnableDmEnrollment } else { 1 }
$ValidityPeriodInDays = if ($cfg.ValidityPeriodInDays -ne $null) { $cfg.ValidityPeriodInDays } else { 30 }

Write-Log "Payload directory: $PayloadDir"
try {
    Install-GCPW

    Write-Log "Setting registry..."
    Set-RegKey -Path $CloudManagementPath -Name "EnrollmentToken" -Value $EnrollmentToken
    Set-RegKey -Path $GCPWPath -Name "domains_allowed_to_login" -Value $DomainsAllowed
    Set-RegKey -Path $GCPWPath -Name "is_enrolled_to_google" -Value $IsEnrolled -Type "DWord"
    Set-RegKey -Path $GCPWPath -Name "enable_multi_user_login" -Value $EnableMultiUserLogin -Type "DWord"
    Set-RegKey -Path $GCPWPath -Name "use_shorter_account_name" -Value $UseShorterAccountName -Type "DWord"
    Set-RegKey -Path $GCPWPath -Name "enable_dm_enrollment" -Value $EnableDmEnrollment -Type "DWord"
    if ($ValidityPeriodInDays -gt 0) { Set-RegKey -Path $GCPWPath -Name "validity_period_in_days" -Value $ValidityPeriodInDays -Type "DWord" }

    Write-Host ""
    Write-Host "OK: GCPW installed and registry configured. Domains: $DomainsAllowed"
    Write-Host "Restart may be required for GCPW to take effect."
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Failed: $_" -Level "ERROR"
    exit $EXIT_CRITICAL
}
