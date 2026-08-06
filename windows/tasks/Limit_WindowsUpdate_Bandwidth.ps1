<#
.SYNOPSIS
    Cap Windows Update (Delivery Optimization) bandwidth to 1MB/s up and down.

.DESCRIPTION
    Sets Delivery Optimization max upload/download bandwidth (foreground +
    background) to 1024 KB/s (1MB/s) via policy registry keys. Covers both
    direct CDN downloads and peer-to-peer DO traffic.

.EXECUTION
    Windows (local):  iex (Get-Content ".\Limit_WindowsUpdate_Bandwidth.ps1" -Raw)
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Limit_WindowsUpdate_Bandwidth.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator
    Platform: Windows 10/11, Windows Server 2016+
    Exit: 0 = Success, 1002 = Critical
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

$LimitKBps = 1024  # 1MB/s

try {
    $DOPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (-not (Test-Path $DOPath)) { New-Item -Path $DOPath -Force | Out-Null }

    # KB/s, applies to both foreground and background DO/WU traffic
    Set-ItemProperty -Path $DOPath -Name "DOMaxDownloadBandwidth"           -Value $LimitKBps -Type DWord -Force
    Set-ItemProperty -Path $DOPath -Name "DOMaxForegroundDownloadBandwidth" -Value $LimitKBps -Type DWord -Force
    Set-ItemProperty -Path $DOPath -Name "DOMaxBackgroundDownloadBandwidth" -Value $LimitKBps -Type DWord -Force
    Set-ItemProperty -Path $DOPath -Name "DOMaxUploadBandwidth"             -Value $LimitKBps -Type DWord -Force

    Write-Host "SUCCESS: Windows Update (Delivery Optimization) capped to ${LimitKBps}KB/s up/down."
    Write-Host "Computer: $env:COMPUTERNAME"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "FAIL: Windows Update bandwidth limit failed - $_"
    Write-Host "Computer: $env:COMPUTERNAME"
    exit $EXIT_CRITICAL
}
