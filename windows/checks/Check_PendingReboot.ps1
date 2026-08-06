<#
.SYNOPSIS
    Detect whether Windows has a pending restart (updates, CBS, rename, etc.).

.DESCRIPTION
    Reads common reboot-pending signals: Component Based Servicing, Windows Update,
    Session Manager pending file operations, optional computer rename, and ConfigMgr
    client SDK when available.

    Exit Codes:
    - 0    = OK (no pending restart)
    - 1002 = CRITICAL (restart is pending)

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_PendingReboot.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_PendingReboot.ps1")

.NOTES
    Author: IT Admin
    Version: 1.0
    Platform: Windows 10/11, Windows Server 2016+
#>

$ErrorActionPreference = "Stop"
$EXIT_OK = 0
$EXIT_CRITICAL = 1002
$LogFile = "$env:TEMP\PendingRebootCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-PendingRebootDetails {
    <#
    .SYNOPSIS
        Returns whether a reboot is pending and human-readable reasons.
    #>
    $reasons = [System.Collections.Generic.List[string]]::new()

    # Component Based Servicing
    $cbsRoot = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing"
    if (Test-Path $cbsRoot) {
        if (Test-Path (Join-Path $cbsRoot "RebootPending")) {
            $reasons.Add("CBS: RebootPending")
        }
        Get-ChildItem -Path $cbsRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^PackagesPending' } |
            ForEach-Object { $reasons.Add("CBS: $($_.PSChildName)") }
    }

    # Windows Update
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $reasons.Add("Windows Update: RebootRequired")
    }

    # Session Manager — pending file renames (e.g. installers)
    $sm = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    $pfro = Get-ItemProperty -Path $sm -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($null -ne $pfro.PendingFileRenameOperations) {
        $v = $pfro.PendingFileRenameOperations
        $has = if ($v -is [System.Array]) { $v.Count -gt 0 } else { $v.ToString().Trim().Length -gt 0 }
        if ($has) { $reasons.Add("Session Manager: PendingFileRenameOperations") }
    }

    # Pending computer rename
    try {
        $cn = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        $active = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        if ($cn -and $active -and $cn -ne $active) {
            $reasons.Add("Computer name change pending (reboot to apply)")
        }
    }
    catch { }

    # ConfigMgr / SCCM client (optional)
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

Write-Log "Pending reboot check | Computer: $env:COMPUTERNAME | Log: $LogFile"

try {
    $info = Get-PendingRebootDetails
    if (-not $info.Pending) {
        Write-Log "No pending restart detected."
        Write-Host ""
        Write-Host "OK: No pending restart"
        exit $EXIT_OK
    }

    Write-Log "Pending restart detected:" -Level "WARN"
    foreach ($r in $info.Reasons) { Write-Log "  - $r" -Level "WARN" }
    Write-Host ""
    Write-Host "CRITICAL: Restart is pending"
    foreach ($r in $info.Reasons) { Write-Host "  - $r" }
    exit $EXIT_CRITICAL
}
catch {
    Write-Log "Check failed: $_" -Level "ERROR"
    Write-Host ""
    Write-Host "CRITICAL: Pending reboot check failed - $_"
    exit $EXIT_CRITICAL
}
