<#
.SYNOPSIS
    Bundles common N-sight RMM / N-able Windows agent log folders into one ZIP (silent, no GUI).

.DESCRIPTION
    Use when N-able support needs agent-side logs and the official GUI log collector cannot run
    (e.g. Session 0 only). Output is a ZIP on the public Desktop. Complements N-able's own
    Support Log Collector: https://s3.amazonaws.com/new-swmsp-net-supportfiles/PermanentFiles/N-ableSupportLogCollector.zip

    By default only **Logs** (and similar) directories are copied so the archive stays under the
    PowerShell 5.1 Compress-Archive ~2GB stream limit. Set environment variable NSIGHT_BUNDLE_WIDE=1
    before running to include full legacy install roots (may still fail on large disks — use tar).

.NOTES
    Exit: 0 success, 1001 warning (partial/empty), 1002 critical failure.
    First stdout line: OK | WARNING | CRITICAL per N-SIGHT_SCRIPT_STANDARDS.md
    Intentionally no #Requires -RunAsAdministrator: that breaks Invoke-Expression (iex) of remote
    script text because there is no script file path. Admin is enforced below.
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "CRITICAL: Run elevated (Administrator or SYSTEM). iex (irm ...) must run in an elevated PowerShell session."
    exit 1002
}

$EXIT_OK = 0
$EXIT_WARN = 1001
$EXIT_CRIT = 1002

function Get-DiscoveredLogPaths {
    $logCandidates = @(
        "$env:ProgramData\MspPlatform\Logs",
        "$env:ProgramData\MspPlatform\Agent\Logs",
        "$env:ProgramData\MspPlatform\Diagnostics",
        "${env:ProgramFiles(x86)}\N-able Technologies\Windows Agent\Logs",
        "$env:ProgramFiles\N-able Technologies\Windows Agent\Logs",
        "$env:ProgramData\N-able Technologies\Logs",
        "$env:ProgramData\N-able Technologies\Windows Agent\Logs",
        "$env:ProgramData\SolarWinds MSP\Logs",
        "${env:ProgramFiles(x86)}\SolarWinds MSP\Logs",
        "$env:ProgramFiles\SolarWinds MSP\Logs"
    )
    $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $logCandidates) {
        if (Test-Path -LiteralPath $p) { [void]$found.Add((Resolve-Path -LiteralPath $p).Path) }
    }
    $rootsToScan = @(
        "$env:ProgramData\MspPlatform",
        "$env:ProgramData\N-able Technologies",
        "$env:ProgramData\SolarWinds MSP",
        "$env:ProgramFiles\N-able Technologies\Windows Agent",
        "${env:ProgramFiles(x86)}\N-able Technologies\Windows Agent",
        "$env:ProgramFiles\SolarWinds MSP",
        "${env:ProgramFiles(x86)}\SolarWinds MSP"
    )
    foreach ($root in $rootsToScan) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($leaf in @("Logs", "Log", "logging")) {
            $lp = Join-Path $root $leaf
            if (Test-Path -LiteralPath $lp) { [void]$found.Add((Resolve-Path -LiteralPath $lp).Path) }
        }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($leaf in @("Logs", "Log")) {
                $lp = Join-Path $_.FullName $leaf
                if (Test-Path -LiteralPath $lp) { [void]$found.Add((Resolve-Path -LiteralPath $lp).Path) }
            }
        }
    }
    return @($found)
}

function New-ZipFromStagedFolder {
    param(
        [string]$StageRoot,
        [string]$ZipPath
    )
    $tarExe = Join-Path $env:SystemRoot "System32\tar.exe"
    if (Test-Path -LiteralPath $tarExe) {
        $parent = Split-Path -Parent $StageRoot
        $leaf = Split-Path -Leaf $StageRoot
        Push-Location -LiteralPath $parent
        try {
            if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
            # -a: infer format from .zip extension (Windows bsdtar)
            & $tarExe -a -c -f $ZipPath $leaf
            if ($LASTEXITCODE -ne 0) {
                throw "tar.exe exited with code $LASTEXITCODE"
            }
        }
        finally {
            Pop-Location
        }
        return
    }
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Compress-Archive -Path (Join-Path $StageRoot "*") -DestinationPath $ZipPath -CompressionLevel Fastest -Force
}

$wide = $env:NSIGHT_BUNDLE_WIDE -eq "1"
if ($wide) {
    $candidatePaths = @(
        "$env:ProgramData\MspPlatform",
        "$env:ProgramData\N-able Technologies",
        "$env:ProgramData\SolarWinds MSP",
        "$env:ProgramFiles\N-able Technologies\Windows Agent",
        "${env:ProgramFiles(x86)}\N-able Technologies\Windows Agent",
        "$env:ProgramFiles\SolarWinds MSP",
        "${env:ProgramFiles(x86)}\SolarWinds MSP"
    )
    $existing = @($candidatePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}
else {
    $existing = @(Get-DiscoveredLogPaths)
}

if ($existing.Count -eq 0) {
    Write-Host "WARNING: No N-sight/N-able log folders found. Set NSIGHT_BUNDLE_WIDE=1 and re-run to try full install trees, or use N-able Support Log Collector."
    exit $EXIT_WARN
}

$stageRoot = Join-Path $env:TEMP ("NsightRmmLogBundle_" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

$included = [System.Collections.Generic.List[string]]::new()
$copyIssues = [System.Collections.Generic.List[string]]::new()
foreach ($src in $existing) {
    $leaf = ($src -replace "^[a-zA-Z]:\\", "") -replace "\\", "_"
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = "folder" }
    $dest = Join-Path $stageRoot $leaf
    try {
        Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force -ErrorAction Stop
        $included.Add($src) | Out-Null
    }
    catch {
        $copyIssues.Add("$src — $($_.Exception.Message)") | Out-Null
    }
}

if ($included.Count -eq 0) {
    Write-Host "CRITICAL: Staging copy failed for all paths."
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit $EXIT_CRIT
}

$desktop = [Environment]::GetFolderPath("Desktop")
if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
}
if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = Join-Path $env:PUBLIC "Desktop"
}
$zipName = "N-sight-RMM-AgentLogs-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
$zipPath = Join-Path $desktop $zipName

try {
    New-ZipFromStagedFolder -StageRoot $stageRoot -ZipPath $zipPath
}
catch {
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    Write-Host "CRITICAL: Could not create ZIP ($($_.Exception.Message)). For very large trees use N-able Support Log Collector or keep default log-only (clear NSIGHT_BUNDLE_WIDE)."
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit $EXIT_CRIT
}
finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $zipPath)) {
    Write-Host "CRITICAL: ZIP was not created."
    exit $EXIT_CRIT
}

$sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
if ($copyIssues.Count -gt 0) {
    Write-Host "WARNING: Agent log bundle saved ($sizeMb MB) but some paths failed to copy. Send ZIP to N-able support; detail follows."
}
else {
    Write-Host "OK: Agent log bundle saved ($sizeMb MB). Send this ZIP to N-able support with your ticket number."
}
Write-Host "ZIP: $zipPath"
Write-Host "Included folders: $($included.Count) — $($included -join '; ')"
if ($copyIssues.Count -gt 0) {
    Write-Host "Copy issues: $($copyIssues -join ' | ')"
    exit $EXIT_WARN
}

exit $EXIT_OK
