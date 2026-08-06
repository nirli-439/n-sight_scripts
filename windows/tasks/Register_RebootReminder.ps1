<#
.SYNOPSIS
    Register (or remove) a per-user scheduled task that runs Show_RebootReminder.ps1 at logon and every 4 hours.

.DESCRIPTION
    Creates a task in Task Scheduler for the current user: triggers at log on and on a
    repeating schedule (every 4 hours). The reminder script must live next to this file
    unless you pass -ReminderScript with a stable full path.

.PARAMETER Unregister
    Remove the scheduled task and exit.

.PARAMETER SnoozeHours
    Passed through to Show_RebootReminder.ps1 when the task runs (default 4).

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Register_RebootReminder.ps1"
    Per-user:         Run once in each profile that should get prompts (no elevation required).

.NOTES
    Author: IT Admin
    Version: 1.0
    Platform: Windows 10/11
#>

[CmdletBinding()]
param(
    [switch]$Unregister,
    [ValidateRange(1, 168)]
    [int]$SnoozeHours = 4,
    [string]$ReminderScript = ""
)

$ErrorActionPreference = "Stop"

$TaskName = "N-Sight-RebootReminder"

function Resolve-ReminderPath {
    if ($ReminderScript -and $ReminderScript.Trim()) {
        return (Resolve-Path -LiteralPath $ReminderScript).Path
    }
    $p = Join-Path $PSScriptRoot "Show_RebootReminder.ps1"
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Show_RebootReminder.ps1 not found at: $p"
    }
    return (Resolve-Path -LiteralPath $p).Path
}

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$TaskName' (if it existed)."
    exit 0
}

$reminderPath = Resolve-ReminderPath
$argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$reminderPath`" -SnoozeHours $SnoozeHours"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList

$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Logon: prompt soon after sign-in for this user
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $account

# Repeating: every 4 hours (long duration = effectively ongoing)
$start = (Get-Date).AddMinutes(2)
$triggerRepeat = New-ScheduledTaskTrigger -Once -At $start `
    -RepetitionInterval (New-TimeSpan -Hours 4) `
    -RepetitionDuration ([TimeSpan]::FromDays(36525))

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::FromHours(1))

$principal = New-ScheduledTaskPrincipal `
    -UserId $account `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($triggerLogon, $triggerRepeat) `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' for user $env:USERNAME"
Write-Host "Reminder script: $reminderPath"
Write-Host "Snooze (hours) when user chooses Remind me later: $SnoozeHours"
exit 0
