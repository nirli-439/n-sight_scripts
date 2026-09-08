<#
.SYNOPSIS
    Checks and repairs GCPW registry configuration.
.DESCRIPTION
    Installs GCPW first if needed, then allows only Helfy and DoktorABC Google
    Workspace accounts to sign in. Google device-management enrollment is off.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_GCPW_Registry.ps1")
.NOTES
    Exit: 0=PASS, 1001=WARNING (repaired), 1002=CRITICAL
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002
$DomainsAllowed = "helfy.co,doktorabc.com"
$GCPWPath = "HKLM:\SOFTWARE\Google\GCPW"
$CloudMgmtPath = "HKLM:\SOFTWARE\Policies\Google\CloudManagement"
$InstallScriptUrl = "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_GCPW.ps1"

function Test-GCPWInstalled {
    $keys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue
    foreach ($key in $keys) {
        if ((Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).DisplayName -match "Google Credential Provider|GCPW") { return $true }
    }
    return $false
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Set-RegValue {
    param([string]$Path, [string]$Name, [object]$Value, [string]$Type = "String")
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

try {
    if (-not (Test-GCPWInstalled)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression (Invoke-WebRequest -Uri $InstallScriptUrl -UseBasicParsing -TimeoutSec 60).Content
        if (-not (Test-GCPWInstalled)) { throw "GCPW installation did not complete" }
    }

    $fixes = @()
    if ((Get-RegValue $GCPWPath "domains_allowed_to_login") -ne $DomainsAllowed) {
        Set-RegValue $GCPWPath "domains_allowed_to_login" $DomainsAllowed
        $fixes += "domains_allowed_to_login"
    }
    if ((Get-RegValue $GCPWPath "enable_dm_enrollment") -ne 0) {
        Set-RegValue $GCPWPath "enable_dm_enrollment" 0 "DWord"
        $fixes += "enable_dm_enrollment"
    }

    foreach ($entry in @(
        @{ Path = $CloudMgmtPath; Name = "EnrollmentToken" },
        @{ Path = $GCPWPath; Name = "is_enrolled_to_google" },
        @{ Path = $GCPWPath; Name = "enable_multi_user_login" },
        @{ Path = $GCPWPath; Name = "use_shorter_account_name" },
        @{ Path = $GCPWPath; Name = "validity_period_in_days" }
    )) {
        if (Get-RegValue $entry.Path $entry.Name) {
            Remove-ItemProperty -Path $entry.Path -Name $entry.Name -Force
            $fixes += $entry.Name
        }
    }

    if ($fixes.Count -gt 0) {
        Write-Host ("WARNING: GCPW registry repaired on {0}: {1}" -f $env:COMPUTERNAME, ($fixes -join ", "))
        exit $EXIT_WARNING
    }

    Write-Host "PASS: GCPW is installed and configured correctly on $env:COMPUTERNAME"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: GCPW check failed on $env:COMPUTERNAME - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
