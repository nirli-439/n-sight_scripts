<#
.SYNOPSIS
    Installs the Twingate Windows client for all users.
.DESCRIPTION
    Downloads Twingate's official EXE installer, which includes the required .NET runtime.
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
$TwingateUrl = "https://api.twingate.com/download/windows"

function Get-TwingatePath {
    @(
        "${env:ProgramFiles}\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

try {
    $twingate = Get-TwingatePath
    if ($twingate) {
        Write-Host "OK: Twingate $((Get-Item -LiteralPath $twingate).VersionInfo.ProductVersion) is already installed"
        exit $EXIT_SUCCESS
    }

    $installer = Join-Path $env:TEMP "TwingateWindowsInstaller.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $TwingateUrl -OutFile $installer -UseBasicParsing -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $installer)) { throw "Twingate installer download failed" }

    $process = Start-Process -FilePath $installer -ArgumentList "/qn", "auto_update=true" -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010, 1641) { throw "installer exit code $($process.ExitCode)" }

    $twingate = Get-TwingatePath
    if (-not $twingate) { throw "Twingate was not detected after installation" }

    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    Write-Host "OK: Twingate $((Get-Item -LiteralPath $twingate).VersionInfo.ProductVersion) installed at $twingate"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Twingate installation failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
