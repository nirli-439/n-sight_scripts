<#
.SYNOPSIS
    Downloads installer files for the Windows AI Stack into C:\Download. Does not install anything.
.DESCRIPTION
    Fetches the installer files for Git, Node.js LTS, Python, and the VC++ Redistributable via
    "winget download" (download only, no install), plus ChatGPT Desktop (MSIX + license XML),
    Claude Desktop (MSIX), and the Antigravity CLI installer script via direct download - all
    saved to C:\Download and left in place for a manual/offline install later.

    WSL/Ubuntu and the npm-based CLI tools (Claude Code, Codex) are intentionally skipped: neither
    has a standalone installer file to fetch (WSL is enabled via wsl.exe + a Microsoft Store
    package, the CLIs install via "npm install" from the npm registry), so there is nothing for
    a download-only task to grab for them.
.NOTES
    Requires: Administrator (bootstrapping the App Installer/winget package still needs it, even
    though nothing else here installs anything).
    "winget download" requires a reasonably current App Installer/winget version. If a given
    package's download fails or the subcommand isn't supported, this logs a WARNING for that one
    package and moves on rather than failing the whole run.
    Claude Desktop source: https://claude.ai/api/desktop/win32/x64/msix/latest/redirect
    ChatGPT source: https://learn.chatgpt.com/docs/enterprise/windows-deployment (same MSIX +
    License XML URLs used for the offline/system-context deployment pattern - downloaded here
    without being installed).
    Version: 4.0
    Changelog:
    - 4.0: Converted from an installer into a download-only task per Nir's request. This script
      no longer installs, registers, or runs anything - it only downloads the installer files
      listed above into C:\Download so they can be installed later (manually, by a separate task,
      or as part of an offline kit). Removed: winget install calls, the WSL/Ubuntu install step,
      Add-AppxProvisionedPackage calls, the npm global install of the CLIs, and Antigravity's
      installer-script execution. Kept: the same download + integrity checks for the MSIX/
      license/installer-script files (still written to C:\Download, still not deleted after use).
      Exit status is now based on how many of the 7 tracked installer files downloaded
      successfully (7/7 = OK, partial = WARNING, 0/7 = CRITICAL) rather than on install success.
      NOTE: the "ai-stack" entry in check-task-pairs.json was removed as part of this change -
      Check_AI_Stack.ps1 still checks whether the stack is actually INSTALLED, which this task no
      longer causes, so auto-remediating that check by re-running this task would just re-download
      files forever without ever fixing it. Re-pair them only if a task that actually installs
      from the C:\Download cache is added later.
    - 3.3 and earlier (superseded by 4.0 - kept for history): the script installed the full AI
      Stack (Git, Node, Python, WSL/Ubuntu, ChatGPT Desktop, Claude Desktop, Claude Code, Codex,
      Antigravity), downloading MSIX/license/installer-script files to %TEMP% (later C:\Download
      in 3.3) along the way. See git history for the full pre-4.0 changelog.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OK = 0; $WARN = 1001; $CRIT = 1002
$DownloadDir = 'C:\Download'
$Log = Join-Path $env:ProgramData 'nsight\logs\AIStack.log'
New-Item -ItemType Directory -Force -Path (Split-Path $Log), $DownloadDir | Out-Null
function Log([string]$Text) { Write-Host $Text; Add-Content -Path $Log -Value "$(Get-Date -Format s) $Text" }
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
function Download-WingetPackage([string]$Id, [string]$Source = 'winget') {
    $w = Get-WingetPath
    if (-not $w) { Log 'Bootstrapping Microsoft App Installer/winget...'; $w = Install-Winget }
    $attempts = 2
    for ($i = 1; $i -le $attempts; $i++) {
        & $w download --id $Id --exact --source $Source --download-directory $DownloadDir --accept-source-agreements --accept-package-agreements | Out-Null
        if ($LASTEXITCODE -eq 0) { Log "Downloaded $Id installer to C:\Download."; return $true }
        if ($i -lt $attempts) {
            Log "WARNING: winget download failed for $Id ($LASTEXITCODE), retrying in 5s (attempt $i of $attempts)..."
            Start-Sleep -Seconds 5
        }
    }
    Log "WARNING: winget download failed for $Id ($LASTEXITCODE) after $attempts attempts - skipping."
    return $false
}
function Download-ChatGPTDesktop {
    $msix = Join-Path $DownloadDir 'ChatGPT.msix'
    $license = Join-Path $DownloadDir 'ChatGPT-License.xml'
    if ((Test-Path $msix) -and (Test-Path $license)) { Log 'ChatGPT Desktop installer already present in C:\Download - skipping.'; return $true }
    try {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        Invoke-WebRequest -UseBasicParsing -Uri "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-$arch.msix" -OutFile $msix
        Invoke-WebRequest -UseBasicParsing -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml' -OutFile $license
        $fs = [System.IO.File]::OpenRead($msix)
        $sig = New-Object byte[] 2
        [void]$fs.Read($sig, 0, 2)
        $fs.Close()
        if ($sig[0] -ne 0x50 -or $sig[1] -ne 0x4B) { throw 'ChatGPT Desktop MSIX download does not look like a valid package (missing PK zip signature - likely an HTML error page instead).' }
        if ((Get-Item $license).Length -lt 10) { throw 'ChatGPT Desktop license file download was empty or missing.' }
        Log 'Downloaded ChatGPT Desktop (MSIX + license) to C:\Download.'
        return $true
    } catch {
        Log "WARNING: ChatGPT Desktop download failed: $($_.Exception.Message)"
        Remove-Item $msix, $license -Force -ErrorAction SilentlyContinue
        return $false
    }
}
function Download-ClaudeDesktop {
    $msix = Join-Path $DownloadDir 'ClaudeDesktop.msix'
    if (Test-Path $msix) { Log 'Claude Desktop installer already present in C:\Download - skipping.'; return $true }
    try {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        Invoke-WebRequest -UseBasicParsing -Uri "https://claude.ai/api/desktop/win32/$arch/msix/latest/redirect" -OutFile $msix
        if ((Get-Item $msix).Length -lt 50MB) { throw 'Claude Desktop download was not the full MSIX.' }
        Log 'Downloaded Claude Desktop (MSIX) to C:\Download.'
        return $true
    } catch {
        Log "WARNING: Claude Desktop download failed: $($_.Exception.Message)"
        Remove-Item $msix -Force -ErrorAction SilentlyContinue
        return $false
    }
}
function Download-Antigravity {
    $installer = Join-Path $DownloadDir 'antigravity-install.ps1'
    if (Test-Path $installer) { Log 'Antigravity CLI installer already present in C:\Download - skipping.'; return $true }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri 'https://antigravity.google/cli/install.ps1' -OutFile $installer
        if ((Get-Item $installer).Length -eq 0) { throw 'Antigravity installer script download was empty.' }
        Log 'Downloaded Antigravity CLI installer script to C:\Download.'
        return $true
    } catch {
        Log "WARNING: Antigravity CLI installer download failed: $($_.Exception.Message)"
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        return $false
    }
}
try {
    $admin = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
    Log 'Downloading AI Stack installers to C:\Download (download only - nothing will be installed)...'
    $failed = @()
    foreach ($id in @('Git.Git', 'OpenJS.NodeJS.LTS', 'Python.Python.3.13', 'Microsoft.VCRedist.2015+.x64')) {
        if (-not (Download-WingetPackage $id)) { $failed += $id }
    }
    if (-not (Download-ChatGPTDesktop)) { $failed += 'ChatGPT Desktop' }
    if (-not (Download-ClaudeDesktop)) { $failed += 'Claude Desktop' }
    if (-not (Download-Antigravity)) { $failed += 'Antigravity CLI' }
    $total = 7
    if ($failed.Count -eq 0) {
        Log 'OK: All AI Stack installer files are in C:\Download (Git, Node.js LTS, Python, VC++ Redist, ChatGPT Desktop, Claude Desktop, Antigravity CLI). WSL/Ubuntu and the npm CLIs (Claude Code, Codex) were skipped - no installer file exists for those.'
        exit $OK
    } elseif ($failed.Count -lt $total) {
        Log "WARNING: $($failed.Count) of $total installer(s) failed to download: $($failed -join ', '). The rest are in C:\Download."
        exit $WARN
    } else {
        Log 'CRITICAL: All installer downloads failed - check network access and winget availability.'
        exit $CRIT
    }
} catch { Log "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
