<#
.SYNOPSIS
    Silently installs the Windows AI Stack for N-Sight.
.DESCRIPTION
    Installs Git, curl, Node.js LTS, Python, WSL 2/Ubuntu, ChatGPT Desktop,
    Claude Desktop, Claude Code, Codex CLI, and Antigravity CLI. CLI binaries
    are installed machine-wide under Program Files so they work outside SYSTEM.
.NOTES
    Requires: Administrator. Claude Desktop source: https://claude.ai/api/desktop/win32/x64/msix/latest/redirect
    ChatGPT source: https://learn.chatgpt.com/docs/enterprise/windows-deployment
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OK = 0; $WARN = 1001; $CRIT = 1002
$Root = Join-Path $env:ProgramFiles 'AIStack'
$Bin = Join-Path $Root 'bin'
$NpmPrefix = Join-Path $Root 'npm'
$Log = Join-Path $env:ProgramData 'nsight\logs\AIStack.log'
New-Item -ItemType Directory -Force -Path (Split-Path $Log), $Root, $Bin | Out-Null
function Log([string]$Text) { Write-Host $Text; Add-Content -Path $Log -Value "$(Get-Date -Format s) $Text" }
function Add-MachinePath([string]$Path) {
    $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($p -split ';' | Where-Object { $_ -eq $Path }).Count -eq 0) { [Environment]::SetEnvironmentVariable('Path', "$p;$Path", 'Machine') }
    if (($env:Path -split ';' | Where-Object { $_ -eq $Path }).Count -eq 0) { $env:Path += ";$Path" }
}
function Winget([string]$Id, [string]$Source = 'winget') {
    $w = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    if (-not $w) { throw 'winget.exe is required; install Microsoft App Installer first.' }
    & $w install --id $Id --exact --source $Source --silent --accept-source-agreements --accept-package-agreements | Out-Null
    if ($LASTEXITCODE -notin 0, -1978335189) { throw "winget failed for $Id ($LASTEXITCODE)" }
}
function Appx([string]$Name) { return [bool](Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Name } | Select-Object -First 1) }
function Install-ClaudeDesktop {
    if (Appx 'Anthropic.Claude*') { return }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $msix = Join-Path $env:TEMP 'ClaudeDesktop.msix'
    Invoke-WebRequest -UseBasicParsing -Uri "https://claude.ai/api/desktop/win32/$arch/msix/latest/redirect" -OutFile $msix
    if ((Get-Item $msix).Length -lt 50MB) { throw 'Claude Desktop download was not the full MSIX.' }
    Add-AppxProvisionedPackage -Online -PackagePath $msix -SkipLicense -Regions all | Out-Null
    Remove-Item $msix -Force -ErrorAction SilentlyContinue
    if (-not (Appx 'Anthropic.Claude*')) { throw 'Claude Desktop verification failed.' }
}
function Install-Antigravity {
    $agy = Join-Path $Bin 'agy.exe'
    if (Test-Path $agy) { return }
    $installer = Join-Path $env:TEMP 'antigravity-install.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://antigravity.google/cli/install.ps1' -OutFile $installer
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer --dir $Bin | Out-Null
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $agy)) { throw 'Antigravity CLI verification failed.' }
}
try {
    $admin = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
    Log 'Installing AI Stack...'
    Winget 'Git.Git'; Winget 'OpenJS.NodeJS.LTS'; Winget 'Python.Python.3.14'; Winget 'Microsoft.VCRedist.2015+.x64'
    $env:Path = ([Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User') -join ';')
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is missing after prerequisites.' }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { Winget 'Microsoft.WSL' }
    & wsl.exe --install --distribution Ubuntu --no-launch | Out-Null
    if ($LASTEXITCODE -notin 0, 3010) { throw "WSL install failed ($LASTEXITCODE)" }
    Winget '9PLM9XGG6VKS' 'msstore'
    if (-not (Appx 'OpenAI.ChatGPT*')) { Log 'WARNING: ChatGPT package accepted; Store provisioning may complete after Windows Update.' }
    Install-ClaudeDesktop
    $npm = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
    if (-not (Test-Path $npm)) { throw 'npm.cmd missing after Node.js installation.' }
    & $npm install --global --prefix $NpmPrefix '@anthropic-ai/claude-code' '@openai/codex' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "npm CLI install failed ($LASTEXITCODE)" }
    Add-MachinePath $NpmPrefix; Add-MachinePath $Bin
    Install-Antigravity
    $required = @((Join-Path $NpmPrefix 'claude.cmd'), (Join-Path $NpmPrefix 'codex.cmd'), (Join-Path $Bin 'agy.exe'))
    if ($required | Where-Object { -not (Test-Path $_) }) { throw 'One or more AI CLI binaries are missing.' }
    # Taskbar pinning is per-user; N-Sight runs as SYSTEM and Windows blocks silent SYSTEM-to-user pinning.
    # Desktop apps are provisioned and placed in Start. Pin through Intune TaskbarLayout for managed user profiles.
    Log 'OK: AI Stack installed. Reboot if WSL requests it. ChatGPT and Claude Desktop are in Start; CLI: claude, codex, agy.'
    exit $OK
} catch { Log "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
