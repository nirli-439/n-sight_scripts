<#
.SYNOPSIS
    Disables Fast Boot and sets laptop lid close behavior.
.DESCRIPTION
    Lid close does nothing on AC power and sleeps on battery power.
    Designed for N-Sight RMM deployment.
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$OK = 0; $CRIT = 1002
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
    Write-Host 'Disabling Fast Boot...'
    & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Fast Boot registry update failed ($LASTEXITCODE)." }
    Write-Host 'Setting lid close: Do Nothing on AC; Sleep on battery...'
    & powercfg.exe /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    if ($LASTEXITCODE -ne 0) { throw "AC lid action update failed ($LASTEXITCODE)." }
    & powercfg.exe /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 1
    if ($LASTEXITCODE -ne 0) { throw "Battery lid action update failed ($LASTEXITCODE)." }
    & powercfg.exe /SETACTIVE SCHEME_CURRENT
    if ($LASTEXITCODE -ne 0) { throw "Power scheme activation failed ($LASTEXITCODE)." }
    $fastBoot = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled
    $scheme = (& powercfg.exe /GETACTIVESCHEME) -replace '.*: ', ''
    $ac = (& powercfg.exe /Q SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current AC Power Setting Index').ToString()
    $dc = (& powercfg.exe /Q SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current DC Power Setting Index').ToString()
    if ($fastBoot -ne 0 -or $ac -notmatch '0x00000000' -or $dc -notmatch '0x00000001') { throw 'Power setting verification failed.' }
    Write-Host 'OK: Fast Boot disabled; lid does nothing on AC and sleeps on battery.'
    exit $OK
} catch { Write-Host "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
