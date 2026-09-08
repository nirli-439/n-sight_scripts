<#
.SYNOPSIS
    Checks whether Google Chrome is installed and runnable for all users.
.DESCRIPTION
    Passes only when chrome.exe is present in a supported system-wide path and
    its file version can be read. This avoids a false pass from an uninstall
    registry entry or a broken shortcut.
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

function Get-ChromeExecutable {
    @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

try {
    $chrome = Get-ChromeExecutable
    if (-not $chrome) {
        Write-Host "CRITICAL: Google Chrome is not installed in a supported system-wide path"
        exit $EXIT_CRITICAL
    }

    $version = (Get-Item -LiteralPath $chrome).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Chrome executable was found but its product version could not be read"
    }

    Write-Host "PASS: Google Chrome $version is installed at $chrome"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Chrome browser check failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
