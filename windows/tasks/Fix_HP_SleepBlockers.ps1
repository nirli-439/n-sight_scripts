<#
.SYNOPSIS
    Stop and disable HP/print services that prevent the machine from sleeping.

.DESCRIPTION
    Stops and disables HPPrintScanDoctorService, Print Spooler (spooler), and
    Windows Search (WSearch). These services hold wake timers or power requests
    that prevent Windows from entering S3/Modern Standby sleep.

    Root cause documented in Jira IA-805.

    Exit Codes:
    - 0    = Success  (all present services stopped + disabled)
    - 1001 = Warning  (partial — at least one service could not be stopped/disabled)
    - 1002 = Critical (unexpected error)

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Fix_HP_SleepBlockers.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Fix_HP_SleepBlockers.ps1")

.NOTES
    Author:   IT Admin
    Version:  1.0
    Ref:      IA-805
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

# Do not use #Requires -RunAsAdministrator — hides our exit codes in N-Sight
$ErrorActionPreference = "Continue"

$ScriptName = "Fix_HP_SleepBlockers"
$LogDir  = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS  = 0
$EXIT_WARNING  = 1001
$EXIT_CRITICAL = 1002
$Script:ExitCode = $EXIT_CRITICAL

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ── main ─────────────────────────────────────────────────────────────────────

try {
    Write-Log "=== $ScriptName started ==="
    Write-Log "Computer: $env:COMPUTERNAME"

    if (-not (Test-IsAdmin)) {
        Write-Log "Script requires administrator privileges." "ERROR"
        exit $EXIT_CRITICAL
    }

    # Services to neutralise — order matters: HP first, then dependents
    $targets = @("HPPrintScanDoctorService", "spooler", "WSearch")
    $warnings = @()

    foreach ($name in $targets) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Log "$name — not installed, skipping."
            continue
        }

        Write-Log "$name — current status: $($svc.Status)"

        # Stop
        if ($svc.Status -eq "Running") {
            try {
                Stop-Service -Name $name -Force -ErrorAction Stop
                Write-Log "$name — stopped."
            } catch {
                Write-Log "$name — could not stop: $_" "WARNING"
                $warnings += "$name (stop failed)"
            }
        }

        # Disable
        try {
            Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
            Write-Log "$name — startup set to Disabled."
        } catch {
            Write-Log "$name — could not disable: $_" "WARNING"
            $warnings += "$name (disable failed)"
        }
    }

    # Verify
    Write-Log "--- verification ---"
    $stillActive = @()
    foreach ($name in $targets) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        $startMode = (Get-WmiObject Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue).StartMode
        Write-Log "$name — Status=$($svc.Status), StartMode=$startMode"
        if ($svc.Status -eq "Running" -or $startMode -eq "Auto") {
            $stillActive += $name
        }
    }

    if ($stillActive.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Log "All sleep-blocking services stopped and disabled. System should now sleep." "INFO"
        Write-Host "SUCCESS: HP/print sleep blockers removed. Run 'powercfg /requests' to confirm no remaining wake locks."
        $Script:ExitCode = $EXIT_SUCCESS
    } elseif ($stillActive.Count -gt 0) {
        Write-Log "Services still active after remediation: $($stillActive -join ', ')" "WARNING"
        Write-Host "WARNING: Some services could not be fully stopped/disabled: $($stillActive -join ', ')"
        $Script:ExitCode = $EXIT_WARNING
    } else {
        # Warnings during stop/disable but final state looks ok
        Write-Log "Completed with warnings: $($warnings -join ', ')" "WARNING"
        Write-Host "WARNING: Completed with warnings — check log: $LogFile"
        $Script:ExitCode = $EXIT_WARNING
    }

} catch {
    Write-Log "Unexpected error: $_" "ERROR"
    Write-Host "CRITICAL: $ScriptName failed — $_"
    $Script:ExitCode = $EXIT_CRITICAL
} finally {
    Write-Log "=== $ScriptName exiting with code $($Script:ExitCode) ==="
    exit $Script:ExitCode
}
