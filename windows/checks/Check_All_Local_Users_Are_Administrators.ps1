<#
.SYNOPSIS
    Checks that every local user except built-in Guest is an Administrator.
#>
$CRIT = 1002
$users = @(Get-LocalUser | Where-Object { $_.SID.Value -notmatch '-501$' })
$admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object { $_.SID.Value })
$missing = @($users | Where-Object { $_.SID.Value -notin $admins })
if ($missing) { Write-Host "CRITICAL: Non-admin local users: $($missing.Name -join ', ')"; exit $CRIT }
Write-Host "OK: All $($users.Count) local users except Guest are Administrators."
exit 0
