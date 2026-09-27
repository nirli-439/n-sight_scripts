<#
.SYNOPSIS
    Installs Twingate and .NET Desktop Runtime 8.0.29 x64 for all users.

.DESCRIPTION
    Login/startup/tray behavior (per Twingate's own installer, no extra config needed):
    - The installer places a Startup-folder shortcut (Twingate.lnk, all users) that runs
      "Twingate.exe --startup" at every login, and installs "Twingate.Service" set to
      Automatic - so Twingate is already running and connected before the user does
      anything.
    - Launched via that --startup shortcut, the client goes straight to the system tray;
      it does not open its main window. Per Twingate's docs, "Once started, Twingate
      runs from the Notification Area on the right-hand side of the Windows Taskbar."
    - `no_optional_updates=true` is passed to the installer below to stop the client from
      prompting the user to accept optional in-app updates.
    Source: Twingate Windows / Windows Managed Devices docs (twingate.com/docs/windows,
    twingate.com/docs/windows-managed-devices) and community confirmation of the
    Startup-shortcut + Twingate.Service mechanism (github.com/gbarwis/twingate-on-demand).

    NOT yet addressed: a specific "connected" toast/notification popup, if that's what's
    meant - Twingate's docs don't publish a supported setting for it, so nothing has been
    guessed here. Tell me exactly which popup you mean (a screenshot or when it appears)
    and I'll find or verify the right fix rather than hardcode an unconfirmed registry key.

.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_Twingate.ps1")

.NOTES
    Author: IT Admin
    Version: 1.1
    Exit: 0=OK, 1002=CRITICAL
    Changelog:
    - 1.1: Added no_optional_updates=true to the installer command; documented that
      login autostart + tray-only launch are Twingate's own defaults (no script change
      needed for those two).
    - 1.0: Initial version.
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$RuntimeVersion = "8.0.29"
$RuntimePath = "${env:ProgramFiles}\dotnet\shared\Microsoft.WindowsDesktop.App\$RuntimeVersion"
$RuntimeUrl = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.29/windowsdesktop-runtime-8.0.29-win-x64.exe"
$TwingateUrl = "https://api.twingate.com/download/windows"

function Get-TwingatePath {
    @(
        "${env:ProgramFiles}\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Install-Runtime {
    if (Test-Path -LiteralPath $RuntimePath) { return }
    $installer = Join-Path $env:TEMP "windowsdesktop-runtime-$RuntimeVersion-win-x64.exe"
    Invoke-WebRequest -Uri $RuntimeUrl -OutFile $installer -UseBasicParsing -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $installer)) { throw ".NET Desktop Runtime download failed" }
    $process = Start-Process -FilePath $installer -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if ($process.ExitCode -notin 0, 3010, 1641) { throw ".NET Desktop Runtime installer exit code $($process.ExitCode)" }
    if (-not (Test-Path -LiteralPath $RuntimePath)) { throw ".NET Desktop Runtime $RuntimeVersion x64 was not detected after installation" }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-Runtime

    $twingate = Get-TwingatePath
    if ($twingate) {
        Write-Host "OK: Twingate $((Get-Item -LiteralPath $twingate).VersionInfo.ProductVersion) and .NET Desktop Runtime $RuntimeVersion x64 are installed"
        exit $EXIT_SUCCESS
    }

    $installer = Join-Path $env:TEMP "TwingateWindowsInstaller.exe"
    Invoke-WebRequest -Uri $TwingateUrl -OutFile $installer -UseBasicParsing -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $installer)) { throw "Twingate installer download failed" }

    $process = Start-Process -FilePath $installer -ArgumentList "/qn", "auto_update=true", "no_optional_updates=true" -Wait -PassThru
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if ($process.ExitCode -notin 0, 3010, 1641) { throw "Twingate installer exit code $($process.ExitCode)" }

    $twingate = Get-TwingatePath
    if (-not $twingate) { throw "Twingate was not detected after installation" }

    Write-Host "OK: Twingate $((Get-Item -LiteralPath $twingate).VersionInfo.ProductVersion) and .NET Desktop Runtime $RuntimeVersion x64 installed"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Twingate installation failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
