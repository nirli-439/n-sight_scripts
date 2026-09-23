<#
.SYNOPSIS
    Adds every local user except the built-in Guest account to Administrators.
.DESCRIPTION
    N-Sight task for Windows 10/11. Uses well-known SIDs so it works on
    non-English Windows. Includes disabled local accounts; they receive the
    role if later enabled.
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$OK = 0; $CRIT = 1002
$AdminGroupSid = 'S-1-5-32-544'
$GuestRid = '-501$'
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
    $users = @(Get-LocalUser | Where-Object { $_.SID.Value -notmatch $GuestRid })
    $existing = @(Get-LocalGroupMember -SID $AdminGroupSid | ForEach-Object { $_.SID.Value })
    foreach ($user in $users) {
        if ($user.SID.Value -notin $existing) { Add-LocalGroupMember -SID $AdminGroupSid -Member $user }
    }
    $actual = @(Get-LocalGroupMember -SID $AdminGroupSid | ForEach-Object { $_.SID.Value })
    $missing = @($users | Where-Object { $_.SID.Value -notin $actual })
    if ($missing) { throw "Administrator membership verification failed: $($missing.Name -join ', ')" }
    Write-Host "OK: Added $($users.Count) local users except Guest to Administrators."
    exit $OK
} catch { Write-Host "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
