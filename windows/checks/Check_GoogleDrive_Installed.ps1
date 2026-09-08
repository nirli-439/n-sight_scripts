<#
.SYNOPSIS
    Checks whether Google Drive for desktop is installed and runnable.
.DESCRIPTION
    Passes only when GoogleDriveFS.exe exists in a supported system-wide path
    and its product version can be read.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_GoogleDrive_Installed.ps1")
.NOTES
    Exit: 0=PASS, 1002=CRITICAL
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

function Get-GoogleDriveExecutable {
    @(
        "${env:ProgramFiles}\Google\Drive File Stream\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\Drive File Stream\GoogleDriveFS.exe",
        "${env:ProgramFiles}\Google\DriveFS\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\DriveFS\GoogleDriveFS.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

try {
    $drive = Get-GoogleDriveExecutable
    if (-not $drive) {
        Write-Host "CRITICAL: Google Drive is not installed in a supported system-wide path"
        exit $EXIT_CRITICAL
    }

    $version = (Get-Item -LiteralPath $drive).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Google Drive executable was found but its product version could not be read"
    }

    Write-Host "PASS: Google Drive $version is installed at $drive"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Google Drive check failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
