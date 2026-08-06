<#
.SYNOPSIS
    Restores proper sleep + hibernate behavior on Lenovo ThinkPad devices (reverts Remediate_Lenovo_ThinkPad_AMD_Sleep.ps1).

.DESCRIPTION
    Idempotent N-Sight Automated Task (SYSTEM/Administrator, Session 0, no user interaction).
    Fixes the "laptop stays awake in a closed backpack, overheats, drains battery" symptom by
    restoring the out-of-the-box sleep -> hibernate chain that the AMD remediation disabled:
    - Runs `powercfg /hibernate on`, sets HiberbootEnabled = 1 (Fast Startup)
    - Shows the Hibernate button in the Start menu power flyout
    - Lid close on battery = Sleep (LIDACTION=1) on Balanced plan
    - Sleep (standby) after $StandbyMinutesDC idle on battery, then Hibernate after $HibernateMinutesDC idle
    - Sets Balanced as the active plan
    Logs to C:\Logs\RestoreHibernate_<hostname>_<timestamp>.log

.PARAMETER StandbyMinutesDC
    Minutes on battery (DC) idle before Sleep. Default 10.

.PARAMETER HibernateMinutesDC
    Minutes on battery (DC) idle before Hibernate (counted from idle start, must be > StandbyMinutesDC). Default 30.

.EXECUTION
    Deploy as an N-sight Automated Task (PowerShell). Defaults work with no arguments;
    override e.g. -StandbyMinutesDC 5 -HibernateMinutesDC 20 for tighter timeouts.

.REQUIRES
    RunAsAdministrator

.OUTPUTS
    Exit 0    = Success
    Exit 1002 = Critical failure (see script output and log)
#>

#Requires -RunAsAdministrator

param(
    [int]$StandbyMinutesDC = 10,
    [int]$HibernateMinutesDC = 30
)

$ProgressPreference = 'SilentlyContinue'
$EXIT_OK = 0
$EXIT_CRITICAL = 1002

if ($HibernateMinutesDC -le $StandbyMinutesDC) {
    Write-Host "CRITICAL: HibernateMinutesDC ($HibernateMinutesDC) must be greater than StandbyMinutesDC ($StandbyMinutesDC)."
    exit $EXIT_CRITICAL
}

$LogRoot = 'C:\Logs'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogRoot "RestoreHibernate_$($env:COMPUTERNAME)_$Stamp.log"

function Write-LogFile {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogFile -Value "[$ts] [$Level] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $LogRoot)) { New-Item -Path $LogRoot -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-LogFile 'Elevation check failed.' -Level ERROR
    Write-Host "CRITICAL: Administrator privileges required."
    exit $EXIT_CRITICAL
}

try {
    $hibOnOutput = & powercfg.exe /hibernate on 2>&1 | Out-String
    Write-LogFile "powercfg /hibernate on output: $hibOnOutput"

    $powerReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    if (-not (Test-Path -LiteralPath $powerReg)) { New-Item -LiteralPath $powerReg -Force | Out-Null }
    Set-ItemProperty -LiteralPath $powerReg -Name 'HiberbootEnabled' -Value 1 -Type DWord -Force
    $hiberAfter = (Get-ItemProperty -LiteralPath $powerReg -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
    Write-LogFile "HiberbootEnabled after=$hiberAfter"

    if ($hiberAfter -ne 1) { throw "HiberbootEnabled did not apply (value=$hiberAfter)" }

    $flyoutReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
    if (-not (Test-Path -LiteralPath $flyoutReg)) { New-Item -Path $flyoutReg -Force | Out-Null }
    Set-ItemProperty -LiteralPath $flyoutReg -Name 'ShowHibernateOption' -Value 1 -Type DWord -Force
    Write-LogFile "ShowHibernateOption set to 1 (Start menu power flyout)."

    $activeSchemeOutput = & powercfg.exe /setactive SCHEME_BALANCED 2>&1 | Out-String
    Write-LogFile "powercfg /setactive SCHEME_BALANCED output: $activeSchemeOutput"

    # Lid close: Sleep on battery, do-nothing on AC (screen locks on idle/turn-off, not lid)
    # ponytail: LIDACTION is hidden on some OEM images (powercfg /q shows nothing for it) -
    # unhide before setting, otherwise setdcvalueindex/setacvalueindex silently no-op.
    $unhideOutput = & powercfg.exe -attributes SUB_BUTTONS LIDACTION -ATTRIB_HIDE 2>&1 | Out-String
    Write-LogFile "powercfg unhide LIDACTION output: $unhideOutput"
    $lidOutput = @(
        & powercfg.exe /setdcvalueindex SCHEME_BALANCED SUB_BUTTONS LIDACTION 1 2>&1 | Out-String
        & powercfg.exe /setacvalueindex SCHEME_BALANCED SUB_BUTTONS LIDACTION 0 2>&1 | Out-String
    ) -join "`n"
    Write-LogFile "powercfg lid-action (DC=Sleep, AC=DoNothing) output: $lidOutput"

    # Sleep after StandbyMinutesDC idle, hibernate after HibernateMinutesDC idle (battery only)
    $standbySeconds = $StandbyMinutesDC * 60
    $hibernateSeconds = $HibernateMinutesDC * 60
    $timeoutOutput = @(
        & powercfg.exe /setdcvalueindex SCHEME_BALANCED SUB_SLEEP STANDBYIDLE $standbySeconds 2>&1 | Out-String
        & powercfg.exe /setdcvalueindex SCHEME_BALANCED SUB_SLEEP HIBERNATEIDLE $hibernateSeconds 2>&1 | Out-String
    ) -join "`n"
    Write-LogFile "powercfg standby/hibernate idle timeouts (DC=${StandbyMinutesDC}m/${HibernateMinutesDC}m) output: $timeoutOutput"

    $activeSchemeOutput2 = & powercfg.exe /setactive SCHEME_BALANCED 2>&1 | Out-String
    Write-LogFile "powercfg /setactive SCHEME_BALANCED (re-apply) output: $activeSchemeOutput2"

    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Write-LogFile "Explorer restarted to apply flyout menu change."

    Write-Host "OK: Sleep/hibernate restored (hibernate on, HiberbootEnabled=1, flyout button shown, lid=Sleep on battery, standby=${StandbyMinutesDC}m, hibernate=${HibernateMinutesDC}m, active plan=Balanced)."
    Write-Host "Log file: $LogFile"
    exit $EXIT_OK
} catch {
    Write-LogFile "Restore hibernate failed: $_" -Level ERROR
    Write-Host "CRITICAL: Failed to restore hibernate - $_ (see log: $LogFile)"
    exit $EXIT_CRITICAL
}
