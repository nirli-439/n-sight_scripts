<#
.SYNOPSIS
    Checks whether Google Chrome is installed for all users.
.DESCRIPTION
    GCPW requires Chrome. This check passes only when chrome.exe exists in a
    supported system-wide installation path.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_Chrome_Installed.ps1")
.NOTES
    Exit: 0=PASS, 1002=CRITICAL
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

try {
    $chrome = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if (-not $chrome) {
        Write-Host "CRITICAL: Google Chrome is not installed"
        exit $EXIT_CRITICAL
    }

    $version = (Get-Item -LiteralPath $chrome).VersionInfo.ProductVersion
    Write-Host "PASS: Google Chrome $version is installed at $chrome"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Chrome check failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
