<#
.SYNOPSIS
    Run onboarding tasks by executing GitHub-hosted scripts in sequence (unattended, N-Sight-friendly).

.DESCRIPTION
    Downloads each task script from the repo (TLS 1.2, retries), runs via
    powershell.exe -NonInteractive -File (preserves exit codes; avoids iex/irm exit-code bugs).
    Per-task stdout/stderr is written under C:\logs\<date>\ to keep console output small for N-Sight
    (10,000 character capture limit).

    Task order:
    1. Remove_McAfee
    2. Remove_OneDrive
    3. Install_Twingate
    4. Install_Slack
    5. Install_GoogleDrive
    6. Install_Chrome
    7. Enforce_Chrome_Default_Browser
    8. Install_Brother_MFC-L5750DW
    9. Remediate_ScreenLock_Timeout
    10. Install_GCPW
    11. Install_OpenSSH

    After GCPW install, optionally runs Check_GCPW_Registry.ps1 with -AutoRemediate:$false to verify
    identity/GCPW registry alignment (same expectations as Install_GCPW / your Admin Console).

    Default repo base URL is embedded below. Override with environment variable
    NSIGHT_SCRIPTS_REPO_BASE (raw content root, no trailing slash).

    Environment:
    - ONBOARDING_SKIP_GCPW_VERIFY=1  - skip post-install GCPW registry verification

.EXECUTION
    Windows (from GitHub - elevated PowerShell):
        iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Run_Onboarding_Tasks.ps1")
    Or: Run_Onboarding_From_GitHub.cmd (UAC prompt)

    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Run_Onboarding_Tasks.ps1"

.PARAMETER SkipGcpwVerify
    Do not run Check_GCPW_Registry.ps1 after the GCPW task.

.NOTES
    Author: IT Admin
    Version: 2.0
    Requires: Administrator privileges
    Platform: Windows 10/11

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

$RepoBase = "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main"
if ($env:NSIGHT_SCRIPTS_REPO_BASE) {
    $custom = $env:NSIGHT_SCRIPTS_REPO_BASE.Trim().TrimEnd('/')
    if ($custom.Length -gt 0) { $RepoBase = $custom }
}

# Tasks in order: remove McAfee first, then installs/remediations
$Tasks = @(
    @{ Name = "Remove McAfee";          Script = "Remove_McAfee.ps1" },
    @{ Name = "Remove OneDrive";         Script = "Remove_OneDrive.ps1" },
    @{ Name = "Twingate";               Script = "Install_Twingate.ps1" },
    @{ Name = "Slack";                  Script = "Install_Slack.ps1" },
    @{ Name = "Google Drive";           Script = "Install_GoogleDrive.ps1" },
    @{ Name = "Google Chrome";          Script = "Install_Chrome.ps1" },
    @{ Name = "Chrome default browser"; Script = "Enforce_Chrome_Default_Browser.ps1" },
    @{ Name = "Brother MFC-L5750DW";    Script = "Install_Brother_MFC-L5750DW.ps1" },
    @{ Name = "Screen lock timeout";    Script = "Remediate_ScreenLock_Timeout.ps1" },
    @{ Name = "GCPW";                   Script = "Install_GCPW.ps1" },
    @{ Name = "OpenSSH";                Script = "Install_OpenSSH.ps1" }
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

function Invoke-LocalPs1File {
    <#
    Run a downloaded .ps1 with preserved exit code; merge stdout/stderr into a log file (N-Sight output limit).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OutputLog,
        [string[]]$ExtraArgs = @()
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Script not found: $Path"
    }
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path))
    foreach ($a in $ExtraArgs) { $argList.Add($a) }

    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $argList -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $OutputLog -RedirectStandardError "${OutputLog}.err"
    $errFile = "${OutputLog}.err"
    if (Test-Path -LiteralPath $errFile) {
        $errSize = (Get-Item -LiteralPath $errFile).Length
        if ($errSize -gt 0) {
            Add-Content -Path $OutputLog -Value "`n--- stderr ---`n" -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue | Add-Content -Path $OutputLog -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    $code = $p.ExitCode
    if ($null -eq $code) { return 0 }
    return [int]$code
}

function Invoke-RemoteTaskScript {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$TaskLabel
    )
    $tmp = $null
    try {
        $tmp = Save-RemoteScript -Url $Url
        $part = Get-SafeLogNamePart -Text $TaskLabel
        $taskLog = Join-Path $LogDir ("task_{0}_{1}.log" -f $part, (Get-Date -Format 'HHmmss'))
        $code = Invoke-LocalPs1File -Path $tmp -OutputLog $taskLog
        return @{ ExitCode = $code; TaskLog = $taskLog }
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

foreach ($task in $Tasks) {
    $url = "$RepoBase/windows/tasks/$($task.Script)"
    Write-Log "Running: $($task.Name) ($($task.Script))..."
    try {
        $run = Invoke-RemoteTaskScript -Url $url -TaskLabel $task.Name
        $code = $run.ExitCode
        $taskLogPath = $run.TaskLog
        if ($task.Script -eq 'Install_GCPW.ps1') {
            $gcpwTaskRan = $true
            if ($code -eq 0 -or $code -eq 1001) { $gcpwTaskOk = $true }
        }
        if ($code -eq 0) {
            Write-Log "  -> $($task.Name) OK (exit $code). Detail: $taskLogPath"
        }
        elseif ($code -eq 1001) {
            Write-Log "  -> $($task.Name) WARNING (exit $code). Detail: $taskLogPath" -Level "WARN"
        }
        else {
            Write-Log "  -> $($task.Name) FAIL (exit $code). Detail: $taskLogPath" -Level "WARN"
            $Script:AnyCritical = $true
        }
    }
    catch {
        Write-Log "  -> $($task.Name) exception: $_" -Level "WARN"
        $Script:AnyCritical = $true
    }
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
