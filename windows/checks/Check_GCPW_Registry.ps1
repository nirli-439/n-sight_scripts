<#
.SYNOPSIS
    Check GCPW installation and registry — auto-fix if wrong, auto-install if missing.
.DESCRIPTION
    1. If GCPW not installed  → runs Install_GCPW.ps1 from repo.
    2. If registry wrong       → fixes values in place.
    3. If all good             → PASS.
    Exit: 0=PASS, 1001=WARNING (auto-fixed), 1002=CRITICAL (install failed)
.EXECUTION
    Windows (repo): iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_GCPW_Registry.ps1")
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$EXIT_SUCCESS  = 0
$EXIT_WARNING  = 1001
$EXIT_CRITICAL = 1002

$LogDir  = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir "Check_GCPW_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Config — keep in sync with Install_GCPW.ps1
$EnrollmentToken  = "5f8a8760-820d-404a-bc6e-0a7cda2bf96a"
$DomainsAllowed   = "helfy.co,doktorabc.com"
$ValidityDays     = 365
$CloudMgmtPath    = "HKLM:\SOFTWARE\Policies\Google\CloudManagement"
$GCPWPath         = "HKLM:\SOFTWARE\Google\GCPW"
$InstallScriptUrl = "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_GCPW.ps1"

function Write-Log { param([string]$m, [string]$l = "INFO")
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$l] $m" -ErrorAction SilentlyContinue
}

function Set-RegKey { param([string]$Path, [string]$Name, [object]$Value, [string]$Type = "String")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Get-RegVal { param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Test-GCPWInstalled {
    foreach ($base in "${env:ProgramFiles}\Google\CredentialProvider", "${env:ProgramFiles(x86)}\Google\CredentialProvider") {
        if (Get-ChildItem "$base\*\gcp_eventlog_provider.dll", "$base\gcp_eventlog_provider.dll", "$base\*\Gaia.dll" -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
    }
    $keys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                          "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue
    foreach ($k in $keys) {
        if ((Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).DisplayName -match "Google Credential Provider|GCPW") { return $true }
    }
    return $false
}

try {
    Write-Log "Started on $env:COMPUTERNAME"

    # Step 1: Install if missing
    if (-not (Test-GCPWInstalled)) {
        Write-Log "GCPW not installed — invoking Install_GCPW.ps1" "WARN"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression (Invoke-WebRequest -Uri $InstallScriptUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content
        if (-not (Test-GCPWInstalled)) {
            Write-Host "CRITICAL: GCPW install failed on $env:COMPUTERNAME"
            Write-Log "Install failed" "ERROR"
            exit $EXIT_CRITICAL
        }
        Write-Log "GCPW installed successfully" "INFO"
        # Install_GCPW.ps1 already sets registry — fall through to verify
    }

    # Step 2: Registry check + auto-fix
    $fixes = @()

    if ((Get-RegVal $CloudMgmtPath "EnrollmentToken") -ne $EnrollmentToken) {
        Set-RegKey $CloudMgmtPath "EnrollmentToken" $EnrollmentToken
        $fixes += "EnrollmentToken"; Write-Log "Fixed EnrollmentToken" "WARN"
    }
    if ((Get-RegVal $GCPWPath "domains_allowed_to_login") -ne $DomainsAllowed) {
        Set-RegKey $GCPWPath "domains_allowed_to_login" $DomainsAllowed
        $fixes += "domains_allowed_to_login"; Write-Log "Fixed domains_allowed_to_login" "WARN"
    }
    if ([int](Get-RegVal $GCPWPath "is_enrolled_to_google") -ne 1) {
        Set-RegKey $GCPWPath "is_enrolled_to_google" 1 "DWord"
        $fixes += "is_enrolled_to_google"; Write-Log "Fixed is_enrolled_to_google" "WARN"
    }
    if ([int](Get-RegVal $GCPWPath "validity_period_in_days") -ne $ValidityDays) {
        Set-RegKey $GCPWPath "validity_period_in_days" $ValidityDays "DWord"
        $fixes += "validity_period_in_days"; Write-Log "Fixed validity_period_in_days" "WARN"
    }

    if ($fixes.Count -gt 0) {
        $msg = "GCPW registry auto-fixed on $env:COMPUTERNAME — $($fixes -join ', ')"
        Write-Host "WARNING: $msg"
        Write-Log $msg "WARN"
        exit $EXIT_WARNING
    }

    Write-Host "PASS: GCPW installed and configured correctly on $env:COMPUTERNAME"
    Write-Log "All checks passed" "INFO"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: GCPW check failed on $env:COMPUTERNAME — $_"
    Write-Log "Fatal: $_" "ERROR"
    exit $EXIT_CRITICAL
}
