<#
.SYNOPSIS
    Validate check/task pairs from check-task-pairs.json, or run check → task → check on Windows.

.DESCRIPTION
    Default: validate manifest paths + PowerShell parse. -ListPairs prints pairs. -RunPair runs
    pre-check, task, post-check (N-Sight-style). Validator exits 0 or 1002.

.EXAMPLE
    .\Invoke-CheckTaskValidation.ps1
    .\Invoke-CheckTaskValidation.ps1 -ListPairs
    .\Invoke-CheckTaskValidation.ps1 -RunPair -PairId chrome-installed -WhatIf
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$ListPairs,
    [string]$PairId,
    [switch]$RunPair,
    [bool]$SkipTaskIfCheckPasses = $true,
    [int]$PostTaskDelaySeconds = 0,
    [switch]$WhatIf,
    [string]$WindowsRoot = ""
)

$ErrorActionPreference = "Stop"
$ok = 0
$fail = 1002

function Get-WindowsRootResolved {
    if ($WindowsRoot -and $WindowsRoot.Trim()) {
        return (Resolve-Path -LiteralPath $WindowsRoot).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}

function Read-PairManifest {
    param([string]$Root)
    $p = Join-Path $Root "check-task-pairs.json"
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-ScriptParses {
    param([string]$Path)
    $err = $null
    $tok = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
    if ($err -and $err.Count -gt 0) {
        $msg = ($err | ForEach-Object { $_.ToString() }) -join "; "
        throw "Parse error in ${Path}: $msg"
    }
}

function Invoke-NsightScript {
    param([string]$Path)
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path
    return $LASTEXITCODE
}

if (-not $ValidateOnly -and -not $ListPairs -and -not $RunPair) { $ValidateOnly = $true }
$n = 0
if ($ValidateOnly) { $n++ }
if ($ListPairs) { $n++ }
if ($RunPair) { $n++ }
if ($n -gt 1) {
    Write-Error "Use one of: -ValidateOnly, -ListPairs, -RunPair."
    exit $fail
}

$root = Get-WindowsRootResolved
$manifest = Read-PairManifest -Root $root

if ($ListPairs) {
    foreach ($pair in $manifest.pairs) {
        Write-Output ("{0,-28} {1} -> {2}" -f $pair.id, $pair.check, $pair.task)
    }
    exit $ok
}

if ($ValidateOnly) {
    $checksDir = Join-Path $root "checks"
    $tasksDir = Join-Path $root "tasks"
    $seen = @{}
    foreach ($pair in $manifest.pairs) {
        if ($seen.ContainsKey($pair.id)) {
            Write-Error "Duplicate id: $($pair.id)"
            exit $fail
        }
        $seen[$pair.id] = $true
        $checkPath = Join-Path $checksDir $pair.check
        $taskPath = Join-Path $tasksDir $pair.task
        if (-not (Test-Path -LiteralPath $checkPath)) {
            Write-Error "Missing check: $checkPath ($($pair.id))"
            exit $fail
        }
        if (-not (Test-Path -LiteralPath $taskPath)) {
            Write-Error "Missing task: $taskPath ($($pair.id))"
            exit $fail
        }
        try {
            Test-ScriptParses -Path $checkPath
            Test-ScriptParses -Path $taskPath
        }
        catch {
            Write-Error $_
            exit $fail
        }
    }
    Write-Host "OK: $($manifest.pairs.Count) pair(s) — $root"
    exit $ok
}

if (-not $RunPair) {
    Write-Error "No action matched (unexpected)."
    exit $fail
}

if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Error "-RunPair requires Windows."
    exit $fail
}
if (-not $PairId) {
    Write-Error "Use -PairId <id> with -RunPair. List: -ListPairs."
    exit $fail
}

$pair = $manifest.pairs | Where-Object { $_.id -eq $PairId } | Select-Object -First 1
if (-not $pair) {
    Write-Error "Unknown PairId: $PairId"
    exit $fail
}

$checksDir = Join-Path $root "checks"
$tasksDir = Join-Path $root "tasks"
$checkPath = Join-Path $checksDir $pair.check
$taskPath = Join-Path $tasksDir $pair.task

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Run elevated (SYSTEM/admin) for production-like results."
}

Write-Host "=== Pre-check: $($pair.check) ==="
$pre = if ($WhatIf) { -1 } else { Invoke-NsightScript -Path $checkPath }
Write-Host "Exit: $pre"

if ($SkipTaskIfCheckPasses -and $pre -eq 0) {
    Write-Host "Check already PASS; skipping task."
    exit $ok
}

Write-Host "=== Task: $($pair.task) ==="
if (-not $WhatIf) {
    $taskExit = Invoke-NsightScript -Path $taskPath
    Write-Host "Task exit: $taskExit"
    if ($PostTaskDelaySeconds -gt 0) { Start-Sleep -Seconds $PostTaskDelaySeconds }
}

Write-Host "=== Post-check: $($pair.check) ==="
if ($WhatIf) {
    Write-Host "WhatIf: would re-run check."
    exit $ok
}

$post = Invoke-NsightScript -Path $checkPath
Write-Host "Post-check exit: $post"
if ($post -eq 0) {
    Write-Host "OK: post-check PASS."
    exit $ok
}
Write-Warning "Post-check exit $post (expected 0)."
exit $fail
