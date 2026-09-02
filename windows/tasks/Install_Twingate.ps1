<#
.SYNOPSIS
    Installs Twingate and .NET Desktop Runtime 8.0.29 x64 for all users.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_Twingate.ps1")
.NOTES
    Exit: 0=OK, 1002=CRITICAL
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

    $process = Start-Process -FilePath $installer -ArgumentList "/qn", "auto_update=true" -Wait -PassThru
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
