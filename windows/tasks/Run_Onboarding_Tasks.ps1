<#
.SYNOPSIS
    Run onboarding tasks from GitHub (unattended, N-Sight-friendly).
    Slack, hibernate, and screen lock start immediately and overlap McAfee.
    Tasks that use msiexec or winget run one at a time after McAfee exits.

.DESCRIPTION
    Downloads each task script from the repo (TLS 1.2, retries), runs via
    powershell.exe -NonInteractive -File (preserves exit codes; avoids iex/irm exit-code bugs).
    Per-task stdout/stderr is written under C:\logs\<date>\ to keep console output small for N-Sight
    (10,000 character capture limit).

    Task order:
    1. Remove_McAfee
    2. Remove_OneDrive
    3. Remediate_Hibernate_LidClose
    4. Install_Twingate
    5. Install_Slack
    6. Install_GoogleDrive
    7. Install_Chrome
    8. Enforce_Chrome_Default_Browser
    9. Install_Brother_MFC-L5750DW
    10. Remediate_ScreenLock_Timeout
    11. Install_GCPW
    12. Install_OpenSSH
    13. Install_AI_Stack (Claude Desktop, ChatGPT Desktop, Claude Code CLI, Codex CLI, Antigravity CLI)

    After GCPW install, optionally runs Check_GCPW_Registry.ps1 with -AutoRemediate:$false to verify
    identity/GCPW registry alignment (same expectations as Install_GCPW / your Admin Console).

    Default repo base URL is embedded below. Override with environment variable
    NSIGHT_SCRIPTS_REPO_BASE (raw content root, no trailing slash).

    Environment:
    - ONBOARDING_SKIP_GCPW_VERIFY=1  - skip post-install GCPW registry verification

.EXECUTION
    Windows (from GitHub - elevated PowerShell):
        iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Run_Onboarding_Tasks.ps1")
    Or: Run_Onboarding_From_GitHub.cmd (UAC prompt)

    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Run_Onboarding_Tasks.ps1"

.PARAMETER SkipGcpwVerify
    Do not run Check_GCPW_Registry.ps1 after the GCPW task.

.NOTES
    Author: IT Admin
    Version: 2.4
    Requires: Administrator privileges
    Platform: Windows 10/11
    Changelog:
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
    Exit 0    = All tasks completed (task exit 0 or 1001; GCPW verify 0 or 1001 if enabled)
    Exit 1002 = Administrator missing, download failures, task/GCPW verify critical failure
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipGcpwVerify
)

$Global:ProgressPreference = "SilentlyContinue"
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

$RepoBase = "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main"
if ($env:NSIGHT_SCRIPTS_REPO_BASE) {
    $custom = $env:NSIGHT_SCRIPTS_REPO_BASE.Trim().TrimEnd('/')
    if ($custom.Length -gt 0) { $RepoBase = $custom }
}

# Tasks in order: remove McAfee first, then installs/remediations
$Tasks = @(
    @{ Name = "Remove McAfee";          Script = "Remove_McAfee.ps1" },
    @{ Name = "Remove OneDrive";         Script = "Remove_OneDrive.ps1" },
    @{ Name = "Hibernate & Lid Close";  Script = "Remediate_Hibernate_LidClose.ps1" },
    @{ Name = "Twingate";               Script = "Install_Twingate.ps1" },
    @{ Name = "Slack";                  Script = "Install_Slack.ps1" },
    @{ Name = "Google Drive";           Script = "Install_GoogleDrive.ps1" },
    @{ Name = "Google Chrome";          Script = "Install_Chrome.ps1" },
    @{ Name = "Chrome default browser"; Script = "Enforce_Chrome_Default_Browser.ps1" },
    @{ Name = "Brother MFC-L5750DW";    Script = "Install_Brother_MFC-L5750DW.ps1" },
    @{ Name = "Screen lock timeout";    Script = "Remediate_ScreenLock_Timeout.ps1" },
    @{ Name = "GCPW";                   Script = "Install_GCPW.ps1" },
    @{ Name = "OpenSSH";                Script = "Install_OpenSSH.ps1" },
    @{ Name = "AI Stack (Claude/GPT/Codex)"; Script = "Install_AI_Stack.ps1" }
)

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

function Invoke-LocalPs1File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OutputLog,
        [string[]]$ExtraArgs = @()
    )
    $started = Start-LocalPs1File -Path $Path -OutputLog $OutputLog -ExtraArgs $ExtraArgs
    return (Finish-LocalPs1File $started)
}

function Start-OnboardTask {
    param($Task)
    $url = "$RepoBase/windows/tasks/$($Task.Script)"
    $tmp = $null
    try {
        $tmp = Save-RemoteScript -Url $url
        $part = Get-SafeLogNamePart -Text $Task.Name
        $taskLog = Join-Path $LogDir ("task_{0}_{1}.log" -f $part, (Get-Date -Format 'HHmmss'))
        Write-Log "Starting: $($Task.Name) ($($Task.Script)). Detail: $taskLog"
        $started = Start-LocalPs1File -Path $tmp -OutputLog $taskLog
        return @{ Task = $Task; Tmp = $tmp; Started = $started; TaskLog = $taskLog }
    }
    catch {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Complete-OnboardTask {
    param($Handle)
    $task = $Handle.Task
    try {
        $code = Finish-LocalPs1File $Handle.Started
        if ($task.Script -eq 'Install_GCPW.ps1') {
            $script:gcpwTaskRan = $true
            if ($code -eq 0 -or $code -eq 1001) { $script:gcpwTaskOk = $true }
        }
        if ($code -eq 0) {
            Write-Log "  -> $($task.Name) OK (exit $code). Detail: $($Handle.TaskLog)"
        }
        elseif ($code -eq 1001) {
            Write-Log "  -> $($task.Name) WARNING (exit $code). Detail: $($Handle.TaskLog)" -Level "WARN"
        }
        else {
            Write-Log "  -> $($task.Name) FAIL (exit $code). Detail: $($Handle.TaskLog)" -Level "WARN"
            $Script:AnyCritical = $true
        }
    }
    catch {
        Write-Log "  -> $($task.Name) exception: $_" -Level "WARN"
        $Script:AnyCritical = $true
    }
    finally {
        if ($Handle.Tmp -and (Test-Path -LiteralPath $Handle.Tmp)) {
            Remove-Item -LiteralPath $Handle.Tmp -Force -ErrorAction SilentlyContinue
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

$doGcpwVerify = -not $SkipGcpwVerify
if ($env:ONBOARDING_SKIP_GCPW_VERIFY -eq '1' -or $env:ONBOARDING_SKIP_GCPW_VERIFY -eq 'true') {
    $doGcpwVerify = $false
}

Write-Log "Run_Onboarding_Tasks started - $env:COMPUTERNAME"
Write-Log "Script source repo base: $RepoBase"
Write-Log "Main log: $LogFile"
Write-Log "NonInteractive: TLS 1.2; per-task logs under: $LogDir"
Write-Log "Post-GCPW registry verify: $(if ($doGcpwVerify) { 'enabled (AutoRemediate off)' } else { 'skipped' })"

$gcpwTaskRan = $false
$gcpwTaskOk = $false

# Slack/hibernate/screen lock do not take the Windows Installer lock. They overlap McAfee.
# msiexec and winget tasks stay serial, and start only after McAfee has exited.
$FastScripts = @(
    'Remediate_Hibernate_LidClose.ps1',
    'Remediate_ScreenLock_Timeout.ps1',
    'Install_Slack.ps1'
)

$fastHandles = [System.Collections.Generic.List[object]]::new()
foreach ($task in $Tasks) {
    if ($FastScripts -notcontains $task.Script) { continue }
    try {
        $fastHandles.Add((Start-OnboardTask $task))
    }
    catch {
        Write-Log "  -> $($task.Name) exception: $_" -Level "WARN"
        $Script:AnyCritical = $true
    }
}

foreach ($task in $Tasks) {
    if ($task.Script -ne 'Remove_McAfee.ps1') { continue }
    try {
        Complete-OnboardTask (Start-OnboardTask $task)
    }
    catch {
        Write-Log "  -> $($task.Name) exception: $_" -Level "WARN"
        $Script:AnyCritical = $true
    }
}

foreach ($task in $Tasks) {
    if ($FastScripts -contains $task.Script) { continue }
    if ($task.Script -eq 'Remove_McAfee.ps1') { continue }
    try {
        Complete-OnboardTask (Start-OnboardTask $task)
    }
    catch {
        Write-Log "  -> $($task.Name) exception: $_" -Level "WARN"
        $Script:AnyCritical = $true
    }
}

foreach ($handle in $fastHandles) {
    Complete-OnboardTask $handle
}

# Optional: verify GCPW registry vs. expected identity settings (no auto-install from check in this flow)
if ($doGcpwVerify -and $gcpwTaskRan -and $gcpwTaskOk -and -not $Script:AnyCritical) {
    $verifyUrl = "$RepoBase/windows/checks/Check_GCPW_Registry.ps1"
    Write-Log "Running GCPW registry verification: Check_GCPW_Registry.ps1 (-AutoRemediate:`$false)..."
    try {
        $tmp = Save-RemoteScript -Url $verifyUrl
        $verifyLog = Join-Path $LogDir ("Check_GCPW_verify_{0}.log" -f (Get-Date -Format 'HHmmss'))
        $vCode = Invoke-LocalPs1File -Path $tmp -OutputLog $verifyLog -ExtraArgs @('-AutoRemediate:$false')
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if ($vCode -eq 0) {
            Write-Log "  -> GCPW registry verify PASS (exit 0). Detail: $verifyLog"
        }
        elseif ($vCode -eq 1001) {
            Write-Log "  -> GCPW registry verify WARNING (exit 1001). Detail: $verifyLog" -Level "WARN"
        }
        else {
            Write-Log "  -> GCPW registry verify CRITICAL (exit $vCode). Detail: $verifyLog" -Level "WARN"
            $Script:AnyCritical = $true
        }
    }
    catch {
        Write-Log "  -> GCPW verify failed: $_" -Level "WARN"
        $Script:AnyCritical = $true
    }
}
elseif ($doGcpwVerify -and -not $gcpwTaskOk) {
    Write-Log "Skipping GCPW registry verify (GCPW task did not complete with OK/warning)." -Level "WARN"
}

Write-Log "Run_Onboarding_Tasks finished."

$summary = if ($Script:AnyCritical) {
    "CRITICAL: One or more steps failed - see $LogFile"
}
else {
    "OK: Onboarding completed - see $LogFile"
}
Write-Host $summary
if ($Script:AnyCritical) {
    exit $EXIT_CRITICAL
}
exit $EXIT_SUCCESS
