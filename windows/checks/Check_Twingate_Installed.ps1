<#
.SYNOPSIS
    Checks whether Twingate and .NET Desktop Runtime 8.0.29 x64 are installed.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_Twingate_Installed.ps1")
.NOTES
    Exit: 0=PASS, 1002=CRITICAL
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$RuntimeVersion = "8.0.29"
$RuntimePath = "${env:ProgramFiles}\dotnet\shared\Microsoft.WindowsDesktop.App\$RuntimeVersion"

try {
    $twingate = @(
        "${env:ProgramFiles}\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if (-not $twingate) { throw "Twingate is not installed" }
    if (-not (Test-Path -LiteralPath $RuntimePath)) { throw ".NET Desktop Runtime $RuntimeVersion x64 is not installed" }

    $version = (Get-Item -LiteralPath $twingate).VersionInfo.ProductVersion
    Write-Host "PASS: Twingate $version and .NET Desktop Runtime $RuntimeVersion x64 are installed"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Twingate check failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
