<#
.SYNOPSIS
    Run onboarding tasks from GitHub as an execute-and-verify checklist (unattended, N-Sight-friendly).

.DESCRIPTION
    For each step: (1) if it has a paired Check_*.ps1, run that first - if it already
    PASSes, skip the step entirely (already done, e.g. from a prior partial run);
    (2) otherwise download and run the task script with a hard per-step timeout - if it
    doesn't exit in time, the whole process tree is taskkilled (so one hung installer
    can't block every step after it); (3) if a paired check exists, run it again
    afterward to verify the real machine state rather than trusting the task's own exit
    code alone. A compact checklist prints at the end and is saved under C:\logs\<date>\.

    Because pre-checks skip anything already verified, re-running this SAME task after a
    partial failure (timeout, N-Sight killing it, a transient download error) is cheap and
    safe - it picks up where it left off instead of redoing finished steps. This matters
    because the worst-case total across all steps below can exceed N-Sight's 3,600s task
    timeout ceiling; if N-Sight kills a run partway, just trigger it again.

    Live progress: while running interactively (a console, not N-Sight's headless
    Session 0), this prints a heartbeat line every ~20s for whatever step is currently
    running ("... still running (Ns / Ts)"), shows two Write-Progress bars - overall
    step N of 14, and elapsed/timeout for the current step - and opens a self-refreshing
    HTML checklist page (C:\logs\<date>\Onboarding_Progress.html) in the default browser.
    In N-Sight, Write-Progress is a no-op, the heartbeat lines still land in the log/
    console capture, and the HTML page is just written to disk (nothing to open it on).

    Steps marked "optional" below (currently just OpenSSH) do not affect the overall
    result: if an optional step FAILs or TIMES OUT, it's still reported in the checklist,
    but it will not flip the run to CRITICAL/exit 1002.

    Task order (Script / paired Check / timeout / optional?):
     1. Remove_McAfee.ps1              / Check_McAfee_Installed.ps1        / 600s
     2. Remove_OneDrive.ps1             / (no paired check yet)             / 180s
     3. Remediate_Hibernate_LidClose.ps1/ Check_Hibernate_LidClose.ps1      / 60s
     4. Install_Twingate.ps1            / Check_Twingate_Installed.ps1     / 300s
     5. Install_Slack.ps1               / Check_Slack_Installed.ps1        / 240s
     6. Install_GoogleDrive.ps1         / Check_GoogleDrive_Installed.ps1  / 240s
     7. Install_Chrome.ps1              / Check_Chrome_Installed.ps1       / 300s
     8. Enforce_Chrome_Default_Browser.ps1 / Check_Chrome_Default_Browser.ps1 / 90s
     9. Install_Brother_MFC-L5750DW.ps1 / Check_Brother_MFC-L5750DW.ps1    / 300s
    10. Remediate_ScreenLock_Timeout.ps1/ Check_ScreenLock_Timeout.ps1     / 60s
    11. Install_GCPW.ps1                / Check_GCPW_Registry.ps1 (-AutoRemediate:$false) / 240s
    12. Install_AI_Stack.ps1            / Check_AI_Stack.ps1               / 1200s
    13. Pin_Onboarding_Apps.ps1         / (no paired check yet)            / 120s
    14. Install_OpenSSH.ps1             / Check_OpenSSH.ps1                / 900s  -- OPTIONAL, runs last

    OpenSSH moved last and marked optional (Sep 2026, per Nir): Add-WindowsCapability
    fetches its payload from Windows Update, which is routinely slow (minutes) - it was
    both timing out prematurely (fixed: 180s -> 900s in 3.1) and, being mandatory and in
    the middle of the list, made everything after it wait. Now nothing waits on it and a
    slow/failed OpenSSH no longer marks the whole run CRITICAL.

    Default repo base URL is embedded below. Override with environment variable
    NSIGHT_SCRIPTS_REPO_BASE (raw content root, no trailing slash).

    Environment:
    - ONBOARDING_SKIP_GCPW_VERIFY=1  - skip the paired check for the GCPW step only
      (task still runs; back-compat with the old -SkipGcpwVerify switch)

.EXECUTION
    Windows (from GitHub - elevated PowerShell):
        iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Run_Onboarding_Tasks.ps1")
    Or: Run_Onboarding_From_GitHub.cmd (UAC prompt)

    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Run_Onboarding_Tasks.ps1"

    N-Sight Automation Manager: set this task's timeout to the platform max (3,600s / 60
    min) - even without any hangs, this many sequential downloads+installs can
    realistically run long. If N-Sight still kills it partway, re-trigger the same task;
    already-verified steps are skipped so it resumes quickly.

.PARAMETER SkipGcpwVerify
    Do not run Check_GCPW_Registry.ps1 before/after the GCPW task (task still runs).

.NOTES
    Author: IT Admin
    Version: 3.3
    Requires: Administrator privileges
    Platform: Windows 10/11
    Changelog:
    - 3.3: Added a live HTML progress page (Onboarding_Progress.html under C:\logs\<date>\,
      auto-refreshing every 2s) that's opened automatically when run interactively - a
      checklist view of all 14 steps with the current one's live elapsed/timeout, as an
      alternative to watching console text scroll. This only does anything when there is
      a desktop to open a browser on; under N-Sight (Session 0, no desktop) opening it
      silently fails and the run is unaffected - the file is still written and can be
      opened manually from C:\logs\<date>\ afterward.
    - 3.2: Live progress (heartbeat line every ~20s + two Write-Progress bars: overall
      step N of 14, and elapsed/timeout for the current step) so a long step doesn't look
      frozen. Moved OpenSSH to run last and marked it optional (Critical=$false) - a slow,
      failed, or timed-out OpenSSH no longer blocks or fails the rest of the run. Downloads
      keep the fast/quiet Invoke-WebRequest behavior (progress suppressed only around that
      one call, not globally, so Write-Progress works for our own reporting).
    - 3.1: OpenSSH timeout 180s -> 900s. Add-WindowsCapability fetches the OpenSSH.Server
      payload from Windows Update, which is routinely slow (minutes, not seconds) - 180s
      was killing a step that was actually still working, not hung. Confirmed via a live
      run where every other step finished in seconds and OpenSSH was still running well
      past 180s.
    - 3.0: Rebuilt as an execute-and-verify checklist per Nir's request (a single
      unbroken run of all 14 steps was unreliable). Added: a hard per-step timeout with
      process-tree taskkill on expiry (a hung installer can no longer block every step
      after it); a pre-check against each step's paired Check_*.ps1 that skips the step
      when already satisfied (makes re-running this same task after a partial
      failure/timeout cheap - it resumes instead of restarting); a post-run verify
      against the same paired check instead of trusting the task's own exit code alone;
      a compact PASS/WARN/FAIL/TIMEOUT/SKIPPED checklist printed at the end and saved to
      C:\logs\<date>\Onboarding_Checklist_<host>_<timestamp>.txt. Folded the old
      GCPW-only post-verify special case into this generic mechanism (same behavior,
      less duplicate code).
    - 2.6: One script after another. Pin_Onboarding_Apps.ps1 is the last step.
    - 2.5: After installs, Pin_Onboarding_Apps.ps1 puts Chrome, Slack, Drive,
      Twingate, Claude, and ChatGPT on the public desktop and in one taskbar layout.
    - 2.4: Skip is in Remove_McAfee (no MCPR, no takeown /R, when McAfee is absent).
      Slack, hibernate, and screen lock overlap McAfee. msiexec/winget tasks stay
      serial after McAfee so Windows Installer does not deadlock.
    - 2.3: Added Install_AI_Stack.ps1 last (can prompt for a WSL reboot).
    - 2.2: Renamed step 3 to Remediate_Hibernate_LidClose.ps1 - it now enables hibernate
      (HiberbootEnabled=1) and shows the Hibernate button instead of disabling Fast
      Startup, per Nir's clarification (Sep 2026) of what was actually wanted. This
      also resolves the ThinkPad Hiberboot conflict flagged in 2.1.
    - 2.1: Added "Fast Boot & Lid Close" step (Remediate_FastBoot_LidClose.ps1, renamed
      from "Disable Fast Boot & Lid Close.ps1"). Fixed default repo base URL (was
      nirl-droid, should be nirli-439 per `git remote -v`).
    - 2.0: Prior version.

.OUTPUTS
    Exit 0    = Checklist has no FAIL/TIMEOUT entries on any REQUIRED step (optional
                steps, WARN, and SKIPPED-OK do not affect this)
    Exit 1002 = Administrator missing, or a required step FAILed or TIMED OUT
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipGcpwVerify
)

$ProgressPreference = "Continue"
$ErrorActionPreference = "Continue"

$ScriptName = "Run_Onboarding_Tasks"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
}
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$Script:AnyCritical = $false
$CheckTimeoutSec = 120
$HeartbeatSec = 20

$RepoBase = "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main"
if ($env:NSIGHT_SCRIPTS_REPO_BASE) {
    $custom = $env:NSIGHT_SCRIPTS_REPO_BASE.Trim().TrimEnd('/')
    if ($custom.Length -gt 0) { $RepoBase = $custom }
}

$doGcpwVerify = -not $SkipGcpwVerify
if ($env:ONBOARDING_SKIP_GCPW_VERIFY -eq '1' -or $env:ONBOARDING_SKIP_GCPW_VERIFY -eq 'true') {
    $doGcpwVerify = $false
}

# Tasks in order: remove McAfee first, then installs/remediations, OpenSSH (slow, optional)
# last. Check = paired windows/checks/*.ps1 from check-task-pairs.json (omit if none yet).
# Critical = $false means a FAIL/TIMEOUT on this step is reported but does not fail the run.
$Tasks = @(
    @{ Name = "Remove McAfee";          Script = "Remove_McAfee.ps1";               TimeoutSec = 600;  Check = "Check_McAfee_Installed.ps1" },
    @{ Name = "Remove OneDrive";         Script = "Remove_OneDrive.ps1";             TimeoutSec = 180 },
    @{ Name = "Hibernate & Lid Close";  Script = "Remediate_Hibernate_LidClose.ps1"; TimeoutSec = 60;   Check = "Check_Hibernate_LidClose.ps1" },
    @{ Name = "Twingate";               Script = "Install_Twingate.ps1";             TimeoutSec = 300;  Check = "Check_Twingate_Installed.ps1" },
    @{ Name = "Slack";                  Script = "Install_Slack.ps1";                TimeoutSec = 240;  Check = "Check_Slack_Installed.ps1" },
    @{ Name = "Google Drive";           Script = "Install_GoogleDrive.ps1";          TimeoutSec = 240;  Check = "Check_GoogleDrive_Installed.ps1" },
    @{ Name = "Google Chrome";          Script = "Install_Chrome.ps1";               TimeoutSec = 300;  Check = "Check_Chrome_Installed.ps1" },
    @{ Name = "Chrome default browser"; Script = "Enforce_Chrome_Default_Browser.ps1"; TimeoutSec = 90; Check = "Check_Chrome_Default_Browser.ps1" },
    @{ Name = "Brother MFC-L5750DW";    Script = "Install_Brother_MFC-L5750DW.ps1"; TimeoutSec = 300;  Check = "Check_Brother_MFC-L5750DW.ps1" },
    @{ Name = "Screen lock timeout";    Script = "Remediate_ScreenLock_Timeout.ps1"; TimeoutSec = 60;   Check = "Check_ScreenLock_Timeout.ps1" },
    @{ Name = "GCPW";                   Script = "Install_GCPW.ps1";                 TimeoutSec = 240;  Check = $(if ($doGcpwVerify) { "Check_GCPW_Registry.ps1" } else { $null }); CheckArgs = @('-AutoRemediate:$false') },
    @{ Name = "AI Stack (Claude/GPT/Codex)"; Script = "Install_AI_Stack.ps1";        TimeoutSec = 1200; Check = "Check_AI_Stack.ps1" },
    @{ Name = "Pin desktop apps";        Script = "Pin_Onboarding_Apps.ps1";         TimeoutSec = 120 },
    @{ Name = "OpenSSH";                Script = "Install_OpenSSH.ps1";              TimeoutSec = 900;  Check = "Check_OpenSSH.ps1"; Critical = $false }
)

$ProgressHtmlPath = Join-Path $LogDir "Onboarding_Progress.html"

function Write-ProgressHtml {
    <#
        Regenerates the HTML checklist page from current state. Cheap local file write -
        called every ~1s while a step is running plus once per step transition, so the
        page (auto-refreshing every 2s via <meta http-equiv=refresh>) stays live. -Final
        stops the auto-refresh once the run is done so the page settles instead of
        reloading forever.
    #>
    param(
        [int]$CurStepIndex = 0,
        [string]$CurLabel = "",
        [int]$CurElapsed = 0,
        [int]$CurTimeout = 0,
        [switch]$Final
    )
    $rows = ""
    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        $t = $Tasks[$i]
        $entry = $null
        foreach ($e in $Checklist) { if ($e.Name -eq $t.Name) { $entry = $e } }
        $isCurrent = (-not $Final) -and (-not $entry) -and ($i -eq ($CurStepIndex - 1))
        $statusText = if ($entry) { $entry.Status } elseif ($isCurrent) { 'RUNNING' } else { 'PENDING' }
        $cls = switch ($statusText) {
            'OK' { 'ok' }; 'SKIPPED-OK' { 'ok' }; 'WARN' { 'warn' }; 'WARN-UNVERIFIED' { 'warn' }
            'FAIL' { 'fail' }; 'TIMEOUT' { 'fail' }; 'RUNNING' { 'running' }; default { 'pending' }
        }
        $icon = switch ($statusText) {
            'OK' { '&#10003;' }; 'SKIPPED-OK' { '&#10003;' }; 'WARN' { '!' }; 'WARN-UNVERIFIED' { '!' }
            'FAIL' { '&#10007;' }; 'TIMEOUT' { '&#8987;' }; 'RUNNING' { '&#9679;' }; default { '&#9675;' }
        }
        $optTag = if ($t.Critical -eq $false) { '<span class="opt">optional</span>' } else { '' }
        $detail = ''
        if ($isCurrent -and $CurLabel) { $detail = "<span class='detail'>$CurLabel - ${CurElapsed}s / ${CurTimeout}s</span>" }
        elseif ($entry) { $detail = "<span class='detail'>$statusText</span>" }
        $rows += "<tr class='$cls'><td class='num'>$($i+1)</td><td class='icon'>$icon</td><td class='name'>$($t.Name) $optTag</td><td class='status'>$detail</td></tr>`n"
    }
    $doneCount = ($Checklist | Measure-Object).Count
    $pct = [int](($doneCount / $Tasks.Count) * 100)
    $refreshTag = if ($Final) { "<meta http-equiv='refresh' content='3600'>" } else { "<meta http-equiv='refresh' content='2'>" }
    $bannerText = if ($Final) {
        if ($Script:AnyCritical) { "Done - one or more required steps need attention" } else { "Done - onboarding complete" }
    } else { "Running - refreshes every 2s" }
    $html = @"
<!doctype html><html><head><meta charset='utf-8'>$refreshTag
<title>Onboarding - $env:COMPUTERNAME</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:24px}
 h1{font-size:18px;margin:0 0 4px} .sub{color:#94a3b8;font-size:13px;margin-bottom:16px}
 .bar{background:#1e293b;border-radius:8px;height:10px;overflow:hidden;margin-bottom:20px}
 .bar>div{background:#22c55e;height:100%;transition:width .3s}
 table{width:100%;border-collapse:collapse;font-size:14px}
 td{padding:8px 10px;border-bottom:1px solid #1e293b;vertical-align:middle}
 .num{color:#64748b;width:28px} .icon{width:24px;font-size:15px;text-align:center}
 .name{min-width:220px} .opt{color:#64748b;font-size:11px;margin-left:6px;border:1px solid #334155;border-radius:4px;padding:1px 5px}
 .detail{color:#94a3b8;font-size:12px}
 tr.ok .icon{color:#22c55e} tr.warn .icon{color:#f59e0b} tr.fail .icon{color:#ef4444}
 tr.running .icon{color:#38bdf8} tr.running .name{color:#38bdf8}
 tr.pending{opacity:.55}
</style></head><body>
<h1>Windows first-time setup - $env:COMPUTERNAME</h1>
<div class='sub'>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $bannerText - $doneCount / $($Tasks.Count) steps done</div>
<div class='bar'><div style='width:${pct}%'></div></div>
<table>$rows</table>
</body></html>
"@
    Set-Content -Path $ProgressHtmlPath -Value $html -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-SafeLogNamePart {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "task" }
    return (($Text -replace '[^\w\-]+', '_').Trim('_'))
}

function Save-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$MaxAttempts = 3
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $dest = Join-Path $env:TEMP ("nsight_onboard_{0}.ps1" -f ([IO.Path]::GetRandomFileName()))
    $attempt = 0
    $lastErr = $null
    # Suppress Write-Progress just for this call - Invoke-WebRequest's own progress bar
    # is slow, but we don't want to silence Write-Progress everywhere (see $ProgressPreference above).
    $prevProgressPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        while ($attempt -lt $MaxAttempts) {
            $attempt++
            try {
                Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 180 -OutFile $dest -ErrorAction Stop
                return $dest
            }
            catch {
                $lastErr = $_
                Write-Log "Download attempt $attempt/$MaxAttempts failed: $($_.Exception.Message)" -Level "WARN"
                if ($attempt -lt $MaxAttempts) {
                    Start-Sleep -Seconds (4 * $attempt)
                }
            }
        }
        throw "Failed to download script after $MaxAttempts attempts: $Url; $lastErr"
    }
    finally {
        $ProgressPreference = $prevProgressPref
    }
}

function Start-LocalPs1File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OutputLog,
        [string[]]$ExtraArgs = @()
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Script not found: $Path" }
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path))
    foreach ($a in $ExtraArgs) { $argList.Add($a) }
    $errFile = "${OutputLog}.err"
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $argList -PassThru -NoNewWindow `
        -RedirectStandardOutput $OutputLog -RedirectStandardError $errFile
    return @{ Process = $proc; OutputLog = $OutputLog; ErrFile = $errFile }
}

function Finish-LocalPs1File {
    param($Started)
    $null = $Started.Process.WaitForExit()
    $errFile = $Started.ErrFile
    if (Test-Path -LiteralPath $errFile) {
        if ((Get-Item -LiteralPath $errFile).Length -gt 0) {
            Add-Content -Path $Started.OutputLog -Value "`n--- stderr ---`n" -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue | Add-Content -Path $Started.OutputLog -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    $code = $Started.Process.ExitCode
    if ($null -eq $code) { return 0 }
    return [int]$code
}

function Invoke-RemoteScriptTimed {
    <#
        Downloads $Url and runs it with a hard timeout, polling every second so we can
        print a heartbeat and update Write-Progress instead of blocking silently. On
        timeout, taskkills the WHOLE process tree (/T) - not just the wrapper
        powershell.exe - so a stuck child installer (msiexec, an EXE installer, etc.)
        can't keep holding a lock (e.g. the Windows Installer mutex) and break steps
        that run after it.
        Returns @{ Code = <int or $null>; TimedOut = <bool> }.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutputLog,
        [string[]]$ExtraArgs = @(),
        [int]$TimeoutSec = 300,
        [string]$Label = "step"
    )
    $tmp = $null
    try {
        $tmp = Save-RemoteScript -Url $Url
        $started = Start-LocalPs1File -Path $tmp -OutputLog $OutputLog -ExtraArgs $ExtraArgs
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastBeat = 0
        while (-not $started.Process.HasExited) {
            Start-Sleep -Seconds 1
            $elapsed = [int]$sw.Elapsed.TotalSeconds
            $pct = [Math]::Min(99, [int](($elapsed / [double]$TimeoutSec) * 100))
            Write-Progress -Id 1 -ParentId 0 -Activity $Label -Status "${elapsed}s / ${TimeoutSec}s" -PercentComplete $pct
            if ($elapsed -ge $TimeoutSec) {
                try { & "$env:SystemRoot\System32\taskkill.exe" /PID $started.Process.Id /T /F 2>&1 | Out-Null } catch {}
                Add-Content -Path $OutputLog -Value "`n--- TIMEOUT after ${TimeoutSec}s: process tree killed ---" -ErrorAction SilentlyContinue
                Write-Progress -Id 1 -ParentId 0 -Activity $Label -Status "timed out" -Completed
                return @{ Code = $null; TimedOut = $true }
            }
            if (($elapsed - $lastBeat) -ge $HeartbeatSec) {
                $lastBeat = $elapsed
                Write-Log "  ... $Label still running (${elapsed}s / ${TimeoutSec}s)"
            }
            try { Write-ProgressHtml -CurStepIndex $StepIndex -CurLabel $Label -CurElapsed $elapsed -CurTimeout $TimeoutSec } catch {}
        }
        Write-Progress -Id 1 -ParentId 0 -Activity $Label -Status "finishing" -PercentComplete 100
        $code = Finish-LocalPs1File $started
        return @{ Code = $code; TimedOut = $false }
    }
    finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "This script requires Administrator privileges." -Level "WARN"
    Write-Host "CRITICAL: Run as Administrator."
    exit $EXIT_CRITICAL
}

Write-Log "Run_Onboarding_Tasks started - $env:COMPUTERNAME"
Write-Log "Script source repo base: $RepoBase"
Write-Log "Main log: $LogFile"
Write-Log "Per-task logs under: $LogDir"
Write-Log "GCPW registry check: $(if ($doGcpwVerify) { 'enabled (AutoRemediate off)' } else { 'skipped' })"

$Checklist = [System.Collections.Generic.List[object]]::new()
$StepIndex = 0
Write-ProgressHtml -CurStepIndex 0
try {
    Start-Process -FilePath $ProgressHtmlPath -ErrorAction Stop
    Write-Log "Progress page opened: $ProgressHtmlPath"
} catch {
    Write-Log "Could not open the progress page automatically (no desktop/browser in this session) - open manually: $ProgressHtmlPath" -Level "WARN"
}
function Add-ChecklistEntry {
    param([string]$Name, [string]$Status, [string]$Detail, [bool]$Optional = $false)
    $Checklist.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Optional = $Optional })
    try { Write-ProgressHtml -CurStepIndex $StepIndex } catch {}
}

foreach ($task in $Tasks) {
    $StepIndex++
    $isCritical = ($task.Critical -ne $false)
    $optTag = if ($isCritical) { "" } else { " (optional)" }
    Write-Progress -Id 0 -Activity "Onboarding - $env:COMPUTERNAME" -Status "Step $StepIndex of $($Tasks.Count): $($task.Name)$optTag" -PercentComplete ([int]((($StepIndex - 1) / $Tasks.Count) * 100))

    $checkArgs = if ($task.CheckArgs) { $task.CheckArgs } else { @() }

    # --- Pre-check: already satisfied from a prior run? Skip re-running the task. ---
    if ($task.Check) {
        $ppart = Get-SafeLogNamePart -Text "$($task.Name)_precheck"
        $preLog = Join-Path $LogDir ("check_{0}_{1}.log" -f $ppart, (Get-Date -Format 'HHmmss'))
        try {
            $pre = Invoke-RemoteScriptTimed -Url "$RepoBase/windows/checks/$($task.Check)" -OutputLog $preLog -ExtraArgs $checkArgs -TimeoutSec $CheckTimeoutSec -Label "$($task.Name) (checking)"
            if (-not $pre.TimedOut -and $pre.Code -eq 0) {
                Write-Log "  -> $($task.Name)$optTag SKIPPED - already OK per $($task.Check). Detail: $preLog"
                Add-ChecklistEntry -Name $task.Name -Status 'SKIPPED-OK' -Detail $preLog -Optional (-not $isCritical)
                if ($task.Script -eq 'Install_GCPW.ps1') { $script:gcpwTaskRan = $true; $script:gcpwTaskOk = $true }
                continue
            }
        }
        catch {
            Write-Log "  -> $($task.Name) pre-check could not run: $_" -Level "WARN"
        }
    }

    # --- Run the task, with a hard timeout ---
    $part = Get-SafeLogNamePart -Text $task.Name
    $taskLog = Join-Path $LogDir ("task_{0}_{1}.log" -f $part, (Get-Date -Format 'HHmmss'))
    Write-Log "Starting: $($task.Name)$optTag ($($task.Script)), timeout $($task.TimeoutSec)s. Detail: $taskLog"
    $result = $null
    try {
        $result = Invoke-RemoteScriptTimed -Url "$RepoBase/windows/tasks/$($task.Script)" -OutputLog $taskLog -TimeoutSec $task.TimeoutSec -Label "$($task.Name) (installing)"
    }
    catch {
        Write-Log "  -> $($task.Name) exception: $_" -Level "WARN"
        Add-ChecklistEntry -Name $task.Name -Status 'FAIL' -Detail "exception: $_" -Optional (-not $isCritical)
        if ($isCritical) { $Script:AnyCritical = $true }
        continue
    }

    if ($result.TimedOut) {
        Write-Log "  -> $($task.Name)$optTag TIMEOUT after $($task.TimeoutSec)s - process tree killed. Detail: $taskLog" -Level "WARN"
        Add-ChecklistEntry -Name $task.Name -Status 'TIMEOUT' -Detail $taskLog -Optional (-not $isCritical)
        if ($isCritical) { $Script:AnyCritical = $true }
        continue
    }

    $code = $result.Code
    if ($task.Script -eq 'Install_GCPW.ps1') {
        $script:gcpwTaskRan = $true
        if ($code -eq 0 -or $code -eq 1001) { $script:gcpwTaskOk = $true }
    }

    # --- Post-verify with the paired check, when there is one ---
    if ($task.Check) {
        $vpart = Get-SafeLogNamePart -Text "$($task.Name)_verify"
        $verifyLog = Join-Path $LogDir ("check_{0}_{1}.log" -f $vpart, (Get-Date -Format 'HHmmss'))
        try {
            $verify = Invoke-RemoteScriptTimed -Url "$RepoBase/windows/checks/$($task.Check)" -OutputLog $verifyLog -ExtraArgs $checkArgs -TimeoutSec $CheckTimeoutSec -Label "$($task.Name) (verifying)"
            if ($verify.TimedOut) {
                Write-Log "  -> $($task.Name) task exit $code, but verify TIMED OUT. Detail: $verifyLog" -Level "WARN"
                Add-ChecklistEntry -Name $task.Name -Status 'WARN-UNVERIFIED' -Detail $verifyLog -Optional (-not $isCritical)
            }
            elseif ($verify.Code -eq 0) {
                Write-Log "  -> $($task.Name) OK - verified by $($task.Check). Detail: $taskLog"
                Add-ChecklistEntry -Name $task.Name -Status 'OK' -Detail $taskLog -Optional (-not $isCritical)
            }
            elseif ($verify.Code -eq 1001) {
                Write-Log "  -> $($task.Name) WARNING per $($task.Check) (task itself exit $code). Detail: $verifyLog" -Level "WARN"
                Add-ChecklistEntry -Name $task.Name -Status 'WARN' -Detail $verifyLog -Optional (-not $isCritical)
            }
            else {
                Write-Log "  -> $($task.Name)$optTag FAIL per $($task.Check) (exit $($verify.Code); task itself exit $code). Detail: $verifyLog" -Level "WARN"
                Add-ChecklistEntry -Name $task.Name -Status 'FAIL' -Detail $verifyLog -Optional (-not $isCritical)
                if ($isCritical) { $Script:AnyCritical = $true }
            }
        }
        catch {
            Write-Log "  -> $($task.Name) verify could not run: $_ (task itself exit $code)" -Level "WARN"
            Add-ChecklistEntry -Name $task.Name -Status 'WARN-UNVERIFIED' -Detail "$_" -Optional (-not $isCritical)
        }
    }
    else {
        # No paired check yet for this step - trust the task's own exit code.
        if ($code -eq 0) {
            Write-Log "  -> $($task.Name) OK (exit $code, no paired check). Detail: $taskLog"
            Add-ChecklistEntry -Name $task.Name -Status 'OK' -Detail $taskLog -Optional (-not $isCritical)
        }
        elseif ($code -eq 1001) {
            Write-Log "  -> $($task.Name) WARNING (exit $code, no paired check). Detail: $taskLog" -Level "WARN"
            Add-ChecklistEntry -Name $task.Name -Status 'WARN' -Detail $taskLog -Optional (-not $isCritical)
        }
        else {
            Write-Log "  -> $($task.Name)$optTag FAIL (exit $code, no paired check). Detail: $taskLog" -Level "WARN"
            Add-ChecklistEntry -Name $task.Name -Status 'FAIL' -Detail $taskLog -Optional (-not $isCritical)
            if ($isCritical) { $Script:AnyCritical = $true }
        }
    }
}

Write-Progress -Id 1 -ParentId 0 -Activity "step" -Completed
Write-Progress -Id 0 -Activity "Onboarding" -Completed

Write-Log "Run_Onboarding_Tasks finished."

try { Write-ProgressHtml -Final } catch {}

$symbol = @{
    'OK' = '[OK]'; 'WARN' = '[WARN]'; 'FAIL' = '[FAIL]'; 'TIMEOUT' = '[TIMEOUT]'
    'SKIPPED-OK' = '[SKIP-OK]'; 'WARN-UNVERIFIED' = '[WARN?]'
}
$ChecklistFile = Join-Path $LogDir "Onboarding_Checklist_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$lines = foreach ($e in $Checklist) {
    $tag = if ($e.Optional) { " (optional)" } else { "" }
    "$($symbol[$e.Status]) $($e.Name)$tag"
}
$lines | Set-Content -Path $ChecklistFile -Encoding UTF8 -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "CHECKLIST ($($Checklist.Count)/$($Tasks.Count)):"
$lines | ForEach-Object { Write-Host $_ }
Write-Host "Full checklist: $ChecklistFile"

$summary = if ($Script:AnyCritical) {
    "CRITICAL: One or more required steps FAILed/TIMED OUT - re-run this task to retry only what's left. See $ChecklistFile"
}
else {
    "OK: Onboarding checklist complete - see $ChecklistFile"
}
Write-Host ""
Write-Host $summary
if ($Script:AnyCritical) {
    exit $EXIT_CRITICAL
}
exit $EXIT_SUCCESS
