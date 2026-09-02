<#
.SYNOPSIS
    Checks and repairs GCPW registry configuration.
.DESCRIPTION
    Installs GCPW first if needed by invoking Install_GCPW.ps1, then verifies
    and repairs the required GCPW registry values.
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
$EnrollmentToken = "5f8a8760-820d-404a-bc6e-0a7cda2bf96a"
$DomainsAllowed = "helfy.co,doktorabc.com"
$ValidityDays = 365
$CloudMgmtPath = "HKLM:\SOFTWARE\Policies\Google\CloudManagement"
$GCPWPath = "HKLM:\SOFTWARE\Google\GCPW"
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
    $wanted = @(
        @{ Path = $CloudMgmtPath; Name = "EnrollmentToken"; Value = $EnrollmentToken; Type = "String" },
        @{ Path = $GCPWPath; Name = "domains_allowed_to_login"; Value = $DomainsAllowed; Type = "String" },
        @{ Path = $GCPWPath; Name = "is_enrolled_to_google"; Value = 1; Type = "DWord" },
        @{ Path = $GCPWPath; Name = "enable_multi_user_login"; Value = 1; Type = "DWord" },
        @{ Path = $GCPWPath; Name = "use_shorter_account_name"; Value = 1; Type = "DWord" },
        @{ Path = $GCPWPath; Name = "enable_dm_enrollment"; Value = 1; Type = "DWord" },
        @{ Path = $GCPWPath; Name = "validity_period_in_days"; Value = $ValidityDays; Type = "DWord" }
    )

    foreach ($entry in $wanted) {
        if ((Get-RegValue -Path $entry.Path -Name $entry.Name) -ne $entry.Value) {
            Set-RegValue -Path $entry.Path -Name $entry.Name -Value $entry.Value -Type $entry.Type
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
