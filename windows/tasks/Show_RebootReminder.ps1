<#
.SYNOPSIS
    If a restart is pending, prompt the user to reboot or snooze reminders for 4 hours.

.DESCRIPTION
    Intended to run in the logged-on user session (e.g. scheduled task). When Windows
    reports a pending restart, shows a message box. The user can restart (60-second
    countdown via shutdown.exe) or postpone; the next prompt is suppressed until the
    snooze period elapses. When no restart is pending, clears snooze state under HKCU.

.PARAMETER SnoozeHours
    Hours to wait before showing the prompt again after the user chooses Remind me later.
    Default: 4.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Show_RebootReminder.ps1"
    Deploy schedule:  Run Register_RebootReminder.ps1 once per user profile.

.NOTES
    Author: IT Admin
    Version: 1.0
    Platform: Windows 10/11
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$SnoozeHours = 4
)

$ErrorActionPreference = "Stop"

$RegPath = "HKCU:\Software\N-Sight\RebootReminder"
$ValueName = "SnoozeUntilUtc"

function Get-PendingRebootDetails {
    $reasons = [System.Collections.Generic.List[string]]::new()

    $cbsRoot = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing"
    if (Test-Path $cbsRoot) {
        if (Test-Path (Join-Path $cbsRoot "RebootPending")) {
            $reasons.Add("CBS: RebootPending")
        }
        Get-ChildItem -Path $cbsRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^PackagesPending' } |
            ForEach-Object { $reasons.Add("CBS: $($_.PSChildName)") }
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $reasons.Add("Windows Update: RebootRequired")
    }

    $sm = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    $pfro = Get-ItemProperty -Path $sm -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($null -ne $pfro.PendingFileRenameOperations) {
        $v = $pfro.PendingFileRenameOperations
        $has = if ($v -is [System.Array]) { $v.Count -gt 0 } else { $v.ToString().Trim().Length -gt 0 }
        if ($has) { $reasons.Add("Session Manager: PendingFileRenameOperations") }
    }

    try {
        $cn = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        $active = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        if ($cn -and $active -and $cn -ne $active) {
            $reasons.Add("Computer name change pending")
        }
    }
    catch { }

    try {
        $ccm = Invoke-CimMethod -Namespace "root\ccm\clientsdk" -ClassName "CCM_ClientUtilities" -MethodName "DetermineIfRebootPending" -ErrorAction SilentlyContinue
        if ($ccm) {
            if ($ccm.SoftRebootPending) { $reasons.Add("CCM: SoftRebootPending") }
            if ($ccm.HardRebootPending) { $reasons.Add("CCM: HardRebootPending") }
        }
    }
    catch { }

    return [PSCustomObject]@{
        Pending = ($reasons.Count -gt 0)
        Reasons = $reasons
    }
}

function Clear-Snooze {
    if (Test-Path $RegPath) {
        Remove-Item -Path $RegPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-SnoozeUntil {
    if (-not (Test-Path $RegPath)) { return $null }
    $p = Get-ItemProperty -Path $RegPath -Name $ValueName -ErrorAction SilentlyContinue
    if ($null -eq $p -or $null -eq $p.$ValueName) { return $null }
    try {
        return [datetime]::Parse($p.$ValueName, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Set-SnoozeUntil([datetime]$UtcTime) {
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    $s = $UtcTime.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
    Set-ItemProperty -Path $RegPath -Name $ValueName -Value $s -Type String
}

# --- main ---
Add-Type -AssemblyName System.Windows.Forms | Out-Null

$info = Get-PendingRebootDetails
if (-not $info.Pending) {
    Clear-Snooze
    exit 0
}

$nowUtc = [datetime]::UtcNow
$snoozeUntil = Get-SnoozeUntil
if ($null -ne $snoozeUntil -and $nowUtc -lt $snoozeUntil) {
    exit 0
}

$reasonText = if ($info.Reasons.Count -gt 0) {
    ($info.Reasons | Select-Object -First 5) -join "`n"
}
else {
    "A system restart is required."
}

$body = @"
Your computer needs to restart to finish applying updates or other changes.

Details:
$reasonText

Click Yes to restart in about 60 seconds (save your work first).
Click No to be reminded again in $SnoozeHours hours.
"@

$result = [System.Windows.Forms.MessageBox]::Show(
    $body,
    "Restart required",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
)

if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
    $msg = "Restart scheduled by IT reminder. Save your work; the PC will restart in 60 seconds."
    Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList @("/r", "/t", "60", "/c", $msg) -WindowStyle Hidden
    exit 0
}

Set-SnoozeUntil -UtcTime $nowUtc.AddHours($SnoozeHours)
exit 0
