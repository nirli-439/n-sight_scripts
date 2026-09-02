<#
.SYNOPSIS
    Checks whether Twingate is installed for all users.
.DESCRIPTION
    This check passes only when the Twingate system-wide executable exists.
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

try {
    $twingate = @(
        "${env:ProgramFiles}\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if (-not $twingate) {
        Write-Host "CRITICAL: Twingate is not installed"
        exit $EXIT_CRITICAL
    }

    $version = (Get-Item -LiteralPath $twingate).VersionInfo.ProductVersion
    Write-Host "PASS: Twingate $version is installed at $twingate"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Twingate check failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
