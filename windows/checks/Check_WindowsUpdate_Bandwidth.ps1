<#
.SYNOPSIS
    Check whether Windows Update (Delivery Optimization) bandwidth is capped to 1MB/s up/down.

.DESCRIPTION
    Exit Codes:
    - 0 = PASS (all 4 DO bandwidth policy keys set to <= 1024 KB/s)
    - 1 = FAIL (any key missing or over limit)

.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_WindowsUpdate_Bandwidth.ps1" -Raw)
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_WindowsUpdate_Bandwidth.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Platform: Windows 10/11, Windows Server 2016+
#>

$ErrorActionPreference = "Stop"
$MaxKBps = 1024
$DOPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
$Keys = @("DOMaxDownloadBandwidth","DOMaxForegroundDownloadBandwidth","DOMaxBackgroundDownloadBandwidth","DOMaxUploadBandwidth")

$fail = $false
foreach ($k in $Keys) {
    $val = (Get-ItemProperty -Path $DOPath -Name $k -ErrorAction SilentlyContinue).$k
    if ($null -eq $val -or $val -eq 0 -or $val -gt $MaxKBps) {
        Write-Host "FAIL: $k = $val (expected 1-$MaxKBps KB/s)"
        $fail = $true
    } else {
        Write-Host "OK: $k = $val KB/s"
    }
}

if ($fail) { Write-Host "FAIL: Windows Update bandwidth not capped to ${MaxKBps}KB/s"; exit 1 }
Write-Host "PASS: Windows Update bandwidth capped to ${MaxKBps}KB/s up/down"
exit 0
