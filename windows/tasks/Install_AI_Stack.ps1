<#
.SYNOPSIS
    Silently installs the Windows AI Stack for N-Sight.
.DESCRIPTION
    Installs Git, curl, Node.js LTS, Python, WSL 2/Ubuntu, ChatGPT Desktop,
    Claude Desktop, Claude Code, Codex CLI, and Antigravity CLI. CLI binaries
    are installed machine-wide under Program Files so they work outside SYSTEM.
.NOTES
    Requires: Administrator. Claude Desktop source: https://claude.ai/api/desktop/win32/x64/msix/latest/redirect
    ChatGPT source: https://learn.chatgpt.com/docs/enterprise/windows-deployment (offline/system-context
    deployment: MSIX + companion License XML via Add-AppxProvisionedPackage, no Microsoft Store account
    needed - confirmed with Nir directly against the doc, Sep 2026). MSIX/License URLs are OpenAI's own
    static CDN links from that page, not tenant-specific.
    Version: 3.2
    Changelog:
    - 3.2: Real root cause of "AI Stack step never gets to ChatGPT/Claude Desktop at all" found
      from an actual run's AIStack.log: `winget install Python.Python.3.14` was failing every
      time with 0x8A150006 (APPINSTALLER_CLI_ERROR_SHELLEXEC_INSTALL_FAILED) before the script
      ever reached the ChatGPT/Claude Desktop steps, so the CRITICAL exit happened at Python, not
      at either AI app. Cause: Python 3.14 replaced the classic installer with a new "Python
      Install Manager" distribution mechanism (per docs.python.org/3/using/windows.html) that is
      new and has open winget-pkgs issues specifically around machine/system-scope installs
      (winget-pkgs #355596, python/pymanager #287) - i.e. a Python 3.14-specific packaging
      problem, not a general "winget can't run as SYSTEM" problem (Git/Node/VCRedist via winget
      were not affected). Fix: pinned to Python.Python.3.13 instead, which still uses the classic,
      well-established installer. Also wrapped the Winget() helper in a retry (2 attempts, 5s
      apart) since the same log showed one transient 0x80072EFD (WININET_E_CANNOT_CONNECT, i.e.
      no network yet) on Git.Git right at the start of a fresh run, before the machine's network
      was fully up - self-heals now instead of failing the whole run over a timing blip.
    - 3.1: Replaced the ChatGPT step's `winget install --source msstore` with the same
      Add-AppxProvisionedPackage MSIX+License sideload pattern already used for Claude Desktop.
      msstore/Store installs need a signed-in Microsoft account context to complete licensing,
      which SYSTEM (N-Sight's execution context) does not have - this was the likely reason
      ChatGPT never actually installed. NOTE (applies to Claude Desktop too): even once
      Add-AppxProvisionedPackage succeeds, Windows only finishes registering the package - Start
      Menu tile, launchable - for a user at their NEXT sign-in, not the current admin/SYSTEM
      session. A fresh login is expected before either app appears; that is not a failure.
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
    $attempts = 2
    for ($i = 1; $i -le $attempts; $i++) {
        & $w install --id $Id --exact --source $Source --silent --accept-source-agreements --accept-package-agreements | Out-Null
        if ($LASTEXITCODE -in 0, -1978335189) { return }
        if ($i -lt $attempts) {
            Log "WARNING: winget failed for $Id ($LASTEXITCODE), retrying in 5s (attempt $i of $attempts)..."
            Start-Sleep -Seconds 5
        }
    }
    throw "winget failed for $Id ($LASTEXITCODE) after $attempts attempts"
}
function Appx([string]$Name) { return [bool](Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Name } | Select-Object -First 1) }
function Install-ChatGPTDesktop {
    if (Appx 'OpenAI.ChatGPT*') { return }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $msix = Join-Path $env:TEMP 'ChatGPT.msix'
    $license = Join-Path $env:TEMP 'ChatGPT-License.xml'
    Invoke-WebRequest -UseBasicParsing -Uri "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-$arch.msix" -OutFile $msix
    Invoke-WebRequest -UseBasicParsing -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml' -OutFile $license
    $fs = [System.IO.File]::OpenRead($msix)
    $sig = New-Object byte[] 2
    [void]$fs.Read($sig, 0, 2)
    $fs.Close()
    if ($sig[0] -ne 0x50 -or $sig[1] -ne 0x4B) { throw 'ChatGPT Desktop MSIX download does not look like a valid package (missing PK zip signature - likely an HTML error page instead).' }
    if ((Get-Item $license).Length -lt 10) { throw 'ChatGPT Desktop license file download was empty or missing.' }
    Add-AppxProvisionedPackage -Online -PackagePath $msix -LicensePath $license -Regions all | Out-Null
    Remove-Item $msix, $license -Force -ErrorAction SilentlyContinue
    if (-not (Appx 'OpenAI.ChatGPT*')) { throw 'ChatGPT Desktop verification failed.' }
}
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
    Winget 'Git.Git'; Winget 'OpenJS.NodeJS.LTS'; Winget 'Python.Python.3.13'; Winget 'Microsoft.VCRedist.2015+.x64'
    $env:Path = ([Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User') -join ';')
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is missing after prerequisites.' }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { Winget 'Microsoft.WSL' }
    & wsl.exe --install --distribution Ubuntu --no-launch | Out-Null
    if ($LASTEXITCODE -notin 0, 3010) { throw "WSL install failed ($LASTEXITCODE)" }
    Install-ChatGPTDesktop
    Install-ClaudeDesktop
    $npm = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
    if (-not (Test-Path $npm)) { throw 'npm.cmd missing after Node.js installation.' }
    & $npm install --global --prefix $NpmPrefix '@anthropic-ai/claude-code' '@openai/codex' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "npm CLI install failed ($LASTEXITCODE)" }
    Add-MachinePath $NpmPrefix; Add-MachinePath $Bin
    Install-Antigravity
    $required = @((Join-Path $NpmPrefix 'claude.cmd'), (Join-Path $NpmPrefix 'codex.cmd'), (Join-Path $Bin 'agy.exe'))
    if ($required | Where-Object { -not (Test-Path $_) }) { throw 'One or more AI CLI binaries are missing.' }
    Log 'OK: AI Stack installed. Reboot if WSL requests it. Claude Desktop and ChatGPT Desktop are provisioned but only register (Start Menu tile, launchable) for a user at their NEXT sign-in - not this admin/SYSTEM session. Desktop shortcuts and taskbar pins are applied by Pin_Onboarding_Apps.ps1. CLI: claude, codex, agy.'
    exit $OK
} catch { Log "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
