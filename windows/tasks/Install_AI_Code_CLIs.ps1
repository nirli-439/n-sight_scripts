# Install_AI_Code_CLIs.ps1 - Claude Code, OpenAI Codex, Google Gemini CLI via winget and npm.
# Log under C:\logs\yyyyMMdd or ProgramData\nsight\logs or TEMP. Exit 0 ok, 1002 fail.
# Run elevated. Deploy from GitHub raw or paste; do not edit comment lines into code.

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Install_AI_Code_CLIs"
# Prefer C:\logs\yyyyMMdd per N-Sight tasks; fallback if C:\ is not writable (e.g. some agents)
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
if (-not (Test-Path $LogDir)) {
    $LogDir = Join-Path $env:ProgramData "nsight\logs\$(Get-Date -Format 'yyyyMMdd')"
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
}
if (-not (Test-Path $LogDir)) {
    $LogDir = Join-Path $env:TEMP "nsight_logs_$(Get-Date -Format 'yyyyMMdd')"
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
}
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

$WINGET_IDS = @{
    Git          = "Git.Git"
    ClaudeCode   = "Anthropic.ClaudeCode"
    Codex        = "OpenAI.Codex"
    NodeLTS      = "OpenJS.NodeJS.LTS"
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if ($LogFile -and (Test-Path (Split-Path $LogFile -Parent))) {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Get-WingetPath {
    $searchPaths = @(
        "$env:ProgramFiles\WindowsApps",
        "${env:ProgramFiles(x86)}\WindowsApps"
    )
    foreach ($basePath in $searchPaths) {
        if (Test-Path $basePath) {
            $winget = Get-ChildItem -Path $basePath -Recurse -Filter "winget.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($winget) { return $winget.FullName }
        }
    }
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [string]$DisplayName = $PackageId
    )
    $wingetPath = Get-WingetPath
    if (-not $wingetPath) {
        Write-Log "winget.exe not found" -Level "ERROR"
        return $false
    }
    try {
        $null = & $wingetPath --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "winget not usable" -Level "ERROR"
            return $false
        }
    } catch {
        Write-Log "winget check failed: $_" -Level "ERROR"
        return $false
    }

    Write-Log "winget install $DisplayName ($PackageId)..."
    try {
        $proc = Start-Process -FilePath $wingetPath -ArgumentList @(
            "install", "--id", $PackageId,
            "--accept-source-agreements", "--accept-package-agreements", "--silent"
        ) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop

        $code = $proc.ExitCode
        # 0 = success; -1978335189 = package already installed (winget)
        if ($code -eq 0) {
            Write-Log "$DisplayName installed successfully" -Level "INFO"
            return $true
        }
        if ($code -eq -1978335189) {
            Write-Log "$DisplayName already installed (winget)" -Level "INFO"
            return $true
        }
        Write-Log "winget exit $code for $DisplayName" -Level "WARN"
        return $false
    } catch {
        Write-Log "winget install failed: $_" -Level "ERROR"
        return $false
    }
}

function Get-NpmCmdPath {
    $candidates = @(
        (Join-Path $env:ProgramFiles "nodejs\npm.cmd"),
        (Join-Path "${env:ProgramFiles(x86)}" "nodejs\npm.cmd")
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Update-CurrentPathFromMachine {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machine, $user) -join ";"
}

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-GeminiCliViaNpm {
    Update-CurrentPathFromMachine

    if (Test-CommandAvailable "gemini") {
        Write-Log "gemini CLI already on PATH"
        return $true
    }

    if (-not (Test-CommandAvailable "node")) {
        Write-Log "Node.js not found; installing LTS via winget..."
        if (-not (Invoke-WingetInstall -PackageId $WINGET_IDS.NodeLTS -DisplayName "Node.js LTS")) {
            return $false
        }
        Start-Sleep -Seconds 2
        Update-CurrentPathFromMachine
    }

    $npm = Get-NpmCmdPath
    if (-not $npm) {
        Write-Log "npm.cmd not found after Node install" -Level "ERROR"
        return $false
    }

    Write-Log "npm install -g @google/gemini-cli..."
    try {
        $out = & $npm install -g "@google/gemini-cli" 2>&1
        $logLine = if ($out) { $out | Out-String } else { "(no output)" }
        Write-Log $logLine
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
            Write-Log "npm exit code: $LASTEXITCODE" -Level "WARN"
        }
    } catch {
        Write-Log "npm failed: $_" -Level "ERROR"
        return $false
    }

    Update-CurrentPathFromMachine
    Start-Sleep -Seconds 1
    if (Test-CommandAvailable "gemini") {
        Write-Log "Gemini CLI installed"
        return $true
    }
    Write-Log "gemini not on PATH after npm install" -Level "WARN"
    return $false
}

# --- main ---
Write-Log "=========================================="
Write-Log "$ScriptName - $($env:COMPUTERNAME)"
Write-Log "Log File: $LogFile"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Administrator required" -Level "ERROR"
    Write-Host "CRITICAL: Run as Administrator."
    exit $EXIT_CRITICAL
}

$wingetOk = [bool](Get-WingetPath)
if (-not $wingetOk) {
    Write-Log "winget not found - install App Installer (Microsoft.DesktopAppInstaller)" -Level "ERROR"
    Write-Host "CRITICAL: winget not available. Log File: $LogFile"
    exit $EXIT_CRITICAL
}

$okGit = $true
if (-not (Test-CommandAvailable "git")) {
    $okGit = Invoke-WingetInstall -PackageId $WINGET_IDS.Git -DisplayName "Git for Windows"
    Update-CurrentPathFromMachine
} else {
    Write-Log "git already on PATH"
}

$okClaude = $false
if (Test-CommandAvailable "claude") {
    Write-Log "claude already on PATH"
    $okClaude = $true
} else {
    $okClaude = Invoke-WingetInstall -PackageId $WINGET_IDS.ClaudeCode -DisplayName "Claude Code"
    Update-CurrentPathFromMachine
    Start-Sleep -Seconds 2
    $okClaude = $okClaude -or (Test-CommandAvailable "claude")
}

$okCodex = $false
if (Test-CommandAvailable "codex") {
    Write-Log "codex already on PATH"
    $okCodex = $true
} else {
    $okCodex = Invoke-WingetInstall -PackageId $WINGET_IDS.Codex -DisplayName "OpenAI Codex"
    Update-CurrentPathFromMachine
    Start-Sleep -Seconds 2
    $okCodex = $okCodex -or (Test-CommandAvailable "codex")
}

$okGemini = Install-GeminiCliViaNpm

$allOk = $okGit -and $okClaude -and $okCodex -and $okGemini
if ($allOk) {
    Write-Log "All AI code CLIs ready (git/claude/codex/gemini)."
    Write-Host "OK: Claude Code, Codex, and Gemini CLI installed or already present. Log File: $LogFile"
    exit $EXIT_SUCCESS
}

Write-Log "One or more steps failed (Git:$okGit Claude:$okClaude Codex:$okCodex Gemini:$okGemini)" -Level "ERROR"
Write-Host "CRITICAL: Install incomplete. Log File: $LogFile"
exit $EXIT_CRITICAL
