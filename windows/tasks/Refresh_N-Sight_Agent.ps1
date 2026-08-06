<#
.SYNOPSIS
    Refresh N-Sight agent, TakeControl, and background checks. First and last line of defense.

.DESCRIPTION
    Restarts/refreshes the N-Sight RMM agent service, TakeControl (BASupSrvc), and
    triggers background tasks so the dashboard gets current checks and scans.
    Logs to C:\policies and gives full feedback for N-Sight. Runs as NT AUTHORITY\SYSTEM.

    Exit Codes: 0 = Success, 1001 = Warning (some steps failed), 1002 = Critical.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Refresh_N-Sight_Agent.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Refresh_N-Sight_Agent.ps1")

.OUTPUTS
    0 = All refreshed. 1001 = Partial. 1002 = Agent or TakeControl not found/failed.

.NOTES
    Version: 1.0
    Platform: Windows 10/11
    Requires: Administrator. Execution context: SYSTEM / Session 0.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$POLICIES_ROOT = "C:\policies"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir ("RefreshNsightAgent_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$EXIT_SUCCESS  = 0
$EXIT_WARNING  = 1001
$EXIT_CRITICAL = 1002

# N-Sight / N-Able agent service names (modern and legacy)
$AgentServiceNames = @("MSPAgent", "WindowsAgent", "N-able Agent", "NAbleAgent", "RMMAgent", "MspAgent")
# TakeControl service names (from Check_TakeControl_Health.ps1)
$TakeControlServiceNames = @("BASupSrvc", "BASupSrvcCnfg", "BASupportExpressStandalone")

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if (Test-Path (Split-Path $LogFile -Parent)) {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Ensure-PoliciesFolder {
    if (-not (Test-Path $POLICIES_ROOT)) {
        try {
            New-Item -Path $POLICIES_ROOT -ItemType Directory -Force | Out-Null
        } catch { return $false }
    }
    return $true
}

function Restart-ServiceSafe {
    param($Service, [string]$Label)
    if (-not $Service) { return $false }
    try {
        $name = $Service.Name
        if ($Service.Status -eq 'Running') {
            Restart-Service -Name $name -Force -ErrorAction Stop
        } else {
            Start-Service -Name $name -ErrorAction Stop
        }
        Start-Sleep -Seconds 3
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($s.Status -eq 'Running') {
            Write-Log "$Label ($name) restarted and running"
            return $true
        }
        Write-Log "$Label ($name) not running after restart" -Level "WARNING"
        return $false
    } catch {
        Write-Log "$Label restart failed: $_" -Level "ERROR"
        return $false
    }
}

# ============================================================================
# MAIN
# ============================================================================

Ensure-PoliciesFolder | Out-Null
Write-Log "Refresh N-Sight Agent - $env:COMPUTERNAME"
Write-Log "Context: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

$agentSvc = $null
$tcSvc = $null
foreach ($n in $AgentServiceNames) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { $agentSvc = $s; break }
}
if (-not $agentSvc) {
    $agentSvc = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match "msp-agent|mspagent|rmmagent|n-able.*agent"
    } | Select-Object -First 1
    if ($agentSvc) {
        $agentSvc = Get-Service -Name $agentSvc.Name -ErrorAction SilentlyContinue
    }
}

foreach ($n in $TakeControlServiceNames) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { $tcSvc = $s; break }
}
if (-not $tcSvc) {
    $tc = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match "BASupSrvc|TakeControl|BeAnywhere"
    } | Select-Object -First 1
    if ($tc) { $tcSvc = Get-Service -Name $tc.Name -ErrorAction SilentlyContinue }
}

$agentOk = $false
$tcOk = $false

if ($agentSvc) {
    $agentOk = Restart-ServiceSafe -Service $agentSvc -Label "N-Sight Agent"
} else {
    Write-Log "N-Sight agent service not found (checked: $($AgentServiceNames -join ', '))" -Level "WARNING"
}

if ($tcSvc) {
    $tcOk = Restart-ServiceSafe -Service $tcSvc -Label "TakeControl"
} else {
    Write-Log "TakeControl service not found (checked: $($TakeControlServiceNames -join ', '))" -Level "WARNING"
}

# Background Tasks: trigger N-Able scheduled tasks that run checks (common task name patterns)
$taskPaths = @("\N-Able\", "\Nable\", "\MSP\", "\")
$taskPatterns = @("*Agent*", "*Check*", "*Scan*", "*Background*", "*RMM*")
$triggered = 0
try {
    $allTasks = Get-ScheduledTask -TaskPath "\" -ErrorAction SilentlyContinue
    foreach ($task in $allTasks) {
        $name = $task.TaskName
        $path = $task.TaskPath
        if ($path -match "N-Able|Nable|MSP|N-able" -or $name -match "Agent|Check|Scan|Background|RMM|MSP") {
            if ($task.State -eq 'Ready') {
                try {
                    Start-ScheduledTask -TaskName $name -TaskPath $path -ErrorAction SilentlyContinue
                    $triggered++
                    Write-Log "Triggered task: $path$name"
                } catch { }
            }
        }
    }
} catch {
    Write-Log "Scheduled task enumeration failed: $_" -Level "WARNING"
}
if ($triggered -gt 0) {
    Write-Log "Triggered $triggered N-Sight-related scheduled task(s)"
}

# Summary
if (-not $agentSvc) {
    Write-Host "CRITICAL: N-Sight agent service not found. Log: $LogFile"
    exit $EXIT_CRITICAL
}
if (-not $agentOk) {
    Write-Host "CRITICAL: N-Sight agent could not be restarted. Log: $LogFile"
    exit $EXIT_CRITICAL
}
if (-not $tcSvc) {
    Write-Host "WARNING: TakeControl service not found; agent refreshed. Log: $LogFile"
    exit $EXIT_WARNING
}
if (-not $tcOk) {
    Write-Host "WARNING: TakeControl could not be restarted; agent refreshed. Log: $LogFile"
    exit $EXIT_WARNING
}
Write-Host "OK: Agent and TakeControl refreshed; $triggered task(s) triggered. Log: $LogFile"
exit $EXIT_SUCCESS
