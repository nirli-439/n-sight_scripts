<#
.SYNOPSIS
    Removes stale GCPW enrollment policy that blocks an allowed Google account.
.DESCRIPTION
    Run as LocalSystem from N-Sight or from an elevated local Administrator
    PowerShell session. Reboot Windows after it completes.
.NOTES
    Exit: 0=OK, 1002=CRITICAL
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$GCPWPath = "HKLM:\SOFTWARE\Google\GCPW"
$CloudMgmtPath = "HKLM:\SOFTWARE\Policies\Google\CloudManagement"
$DomainsAllowed = "helfy.co,doktorabc.com"

try {
    if (-not (Test-Path -LiteralPath $GCPWPath)) { New-Item -Path $GCPWPath -Force | Out-Null }
    New-ItemProperty -Path $GCPWPath -Name "domains_allowed_to_login" -Value $DomainsAllowed -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $GCPWPath -Name "enable_dm_enrollment" -Value 0 -PropertyType DWord -Force | Out-Null

    foreach ($entry in @(
        @{ Path = $CloudMgmtPath; Name = "EnrollmentToken" },
        @{ Path = $GCPWPath; Name = "is_enrolled_to_google" },
        @{ Path = $GCPWPath; Name = "enable_multi_user_login" },
        @{ Path = $GCPWPath; Name = "use_shorter_account_name" },
        @{ Path = $GCPWPath; Name = "validity_period_in_days" }
    )) {
        Remove-ItemProperty -Path $entry.Path -Name $entry.Name -Force -ErrorAction SilentlyContinue
    }

    Write-Host "OK: GCPW sign-in policy reset. Reboot before trying @helfy.co or @doktorabc.com."
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: GCPW sign-in policy reset failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
