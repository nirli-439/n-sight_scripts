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
function Get-WingetPath {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $app = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app -and (Test-Path (Join-Path $app.InstallLocation 'winget.exe'))) { return (Join-Path $app.InstallLocation 'winget.exe') }
    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    Get-ChildItem -Path $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
function Install-Winget {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
    $assets = @($release.assets)
    $bundle = $assets | Where-Object { $_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' } | Select-Object -First 1
    $deps = $assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } | Select-Object -First 1
    if (-not $bundle -or -not $deps) { throw 'Microsoft App Installer release assets were incomplete.' }
    $dir = Join-Path $env:TEMP 'winget-bootstrap'
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $dir | Out-Null
    $bundlePath = Join-Path $dir $bundle.name; $depsZip = Join-Path $dir $deps.name
    Invoke-WebRequest -UseBasicParsing -Uri $bundle.browser_download_url -OutFile $bundlePath
    Invoke-WebRequest -UseBasicParsing -Uri $deps.browser_download_url -OutFile $depsZip
    foreach ($asset in @(@($bundle, $deps))) {
        $path = if ($asset.name -eq $bundle.name) { $bundlePath } else { $depsZip }
        $expected = $asset.digest -replace '^sha256:', ''
        if ($expected -and (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower() -ne $expected.ToLower()) { throw "Checksum verification failed: $($asset.name)" }
    }
    Expand-Archive -Path $depsZip -DestinationPath (Join-Path $dir 'deps') -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $dependencyPaths = @(Get-ChildItem -Path (Join-Path $dir 'deps') -Recurse -File -Include '*.appx','*.msix','*.appxbundle','*.msixbundle' |
        Where-Object { $_.Name -match "($arch|neutral)" } | Select-Object -ExpandProperty FullName)
    Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -DependencyPackagePath $dependencyPaths -SkipLicense | Out-Null
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    $winget = Get-WingetPath
    if (-not $winget) { throw 'Microsoft App Installer installed but winget.exe is unavailable.' }
    return $winget
}
function Winget([string]$Id, [string]$Source = 'winget') {
    $w = Get-WingetPath
    if (-not $w) { Log 'Bootstrapping Microsoft App Installer/winget...'; $w = Install-Winget }
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
