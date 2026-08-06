<#
.SYNOPSIS
    Disables the built-in local Administrator account (SID ending in -500).

.DESCRIPTION
    Finds the well-known built-in Administrator by SID (not by display name), then disables it.
    Idempotent: if already disabled, exits success. Ensure another admin account exists before
    wide deployment. Designed for N-Sight RMM mass deploy (SYSTEM / Session 0).

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remediate_Disable_BuiltIn_Administrator.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remediate_Disable_BuiltIn_Administrator.ps1")

.NOTES
    Version: 1.0
    Requires: Administrator
    Platform: Windows 10/11, Windows Server 2016+
    Exit: 0 = Success, 1001 = Warning (account not found), 1002 = Critical (disable failed)
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Remediate_Disable_BuiltIn_Administrator"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Get-BuiltInAdministratorRecord {
    try {
        $u = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID -match '-500$' } | Select-Object -First 1
        if ($u) { return @{ Name = $u.Name; Enabled = $u.Enabled } }
    } catch {
        # Fall through to CIM (e.g. LocalAccounts unavailable)
    }
    $cim = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE '%-500'" -ErrorAction SilentlyContinue
    if ($cim) {
        return @{ Name = $cim.Name; Enabled = (-not $cim.Disabled) }
    }
    return $null
}

Write-Log "$ScriptName started"
Write-Log "Computer: $env:COMPUTERNAME"

try {
    $rec = Get-BuiltInAdministratorRecord
    if (-not $rec) {
        Write-Log "Built-in Administrator (RID 500) not found — may be removed or nonstandard." -Level "WARN"
        Write-Host ""
        Write-Host "WARNING: Built-in Administrator (SID *-500) not found. $env:COMPUTERNAME"
        exit $EXIT_WARNING
    }

    Write-Log "Resolved account: $($rec.Name), Enabled=$($rec.Enabled)"

    if (-not $rec.Enabled) {
        Write-Log "Account already disabled — no change."
        Write-Host ""
        Write-Host "OK: Built-in Administrator already disabled. $($rec.Name) @ $env:COMPUTERNAME"
        exit $EXIT_SUCCESS
    }

    Disable-LocalUser -Name $rec.Name -ErrorAction Stop
    Write-Log "Disable-LocalUser succeeded for $($rec.Name)."
    Write-Host ""
    Write-Host "SUCCESS: Built-in Administrator disabled ($($rec.Name)). $env:COMPUTERNAME"
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Failed: $_" -Level "ERROR"
    Write-Host ""
    Write-Host "FAIL: Could not disable built-in Administrator — $_ | $env:COMPUTERNAME"
    exit $EXIT_CRITICAL
}
