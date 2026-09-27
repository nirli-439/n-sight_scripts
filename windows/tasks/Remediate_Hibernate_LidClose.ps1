<#
.SYNOPSIS
    Enables hibernate (visible in the Start menu power flyout) and sets lid-close behavior:
    do nothing on AC power, sleep on battery.

.DESCRIPTION
    Corrects the original "Disable Fast Boot & Lid Close" task, which turned Fast Startup
    OFF (HiberbootEnabled = 0). Per Nir (Sep 2026): what people actually want is Hibernate
    back as a power-menu option, plus a machine that stays awake while plugged in with the
    lid closed. This task now:
    - Runs `powercfg /hibernate on` and sets HiberbootEnabled = 1
    - Shows the Hibernate button in the Start menu power flyout (ShowHibernateOption = 1)
    - Sets lid close on the active power scheme: do nothing on AC, sleep on battery
    - Restarts Explorer so the flyout change is visible immediately
    Designed for N-Sight RMM deployment (idempotent; safe to re-run).

    This now intentionally matches Restore_Hibernate_ThinkPad.ps1's hibernate/flyout
    settings (HiberbootEnabled = 1), so it no longer conflicts with that script or its
    companion check, Check_Hibernate_Enabled.ps1. Restore_Hibernate_ThinkPad.ps1 additionally
    tunes battery idle timeouts and forces the Balanced plan for the ThinkPad AMD sleep bug;
    this task only sets hibernate + lid behavior on whatever scheme is already active.

.EXECUTION
    Windows (local):  iex (Get-Content ".\Remediate_Hibernate_LidClose.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remediate_Hibernate_LidClose.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Remediate_Hibernate_LidClose.ps1")

.NOTES
    Author: IT Admin
    Version: 2.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    Changelog:
    - 2.0: Reversed intent per Nir's clarification (Sep 2026) - was disabling Fast Startup
      (HiberbootEnabled=0); now enables hibernate (HiberbootEnabled=1) and shows the
      Hibernate button, which is what was actually wanted. Renamed from
      Remediate_FastBoot_LidClose.ps1. Resolves the ThinkPad Hiberboot conflict flagged
      in v1.1 by aligning with Restore_Hibernate_ThinkPad.ps1. Paired check renamed to
      Check_Hibernate_LidClose.ps1.
    - 1.1: Renamed from "Disable Fast Boot & Lid Close.ps1"; added standard header.
    - 1.0: Initial version (disabled Fast Startup - superseded, see 2.0).

.OUTPUTS
    Exit 0    = Success (hibernate enabled + visible; lid does nothing on AC, sleeps on battery)
    Exit 1002 = Critical (not running as Administrator, a setting failed to apply, or
                verification failed)
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$OK = 0; $CRIT = 1002
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }

    Write-Host 'Enabling hibernate...'
    $hibOut = & powercfg.exe /hibernate on 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "powercfg /hibernate on failed ($LASTEXITCODE): $hibOut" }

    & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' /v HiberbootEnabled /t REG_DWORD /d 1 /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "HiberbootEnabled registry update failed ($LASTEXITCODE)." }

    Write-Host 'Showing Hibernate in the Start menu power flyout...'
    $flyoutReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
    if (-not (Test-Path -LiteralPath $flyoutReg)) { New-Item -Path $flyoutReg -Force | Out-Null }
    Set-ItemProperty -LiteralPath $flyoutReg -Name 'ShowHibernateOption' -Value 1 -Type DWord -Force

    Write-Host 'Setting lid close: Do Nothing on AC; Sleep on battery...'
    & powercfg.exe -attributes SUB_BUTTONS LIDACTION -ATTRIB_HIDE | Out-Null
    & powercfg.exe /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    if ($LASTEXITCODE -ne 0) { throw "AC lid action update failed ($LASTEXITCODE)." }
    & powercfg.exe /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 1
    if ($LASTEXITCODE -ne 0) { throw "Battery lid action update failed ($LASTEXITCODE)." }
    & powercfg.exe /SETACTIVE SCHEME_CURRENT
    if ($LASTEXITCODE -ne 0) { throw "Power scheme activation failed ($LASTEXITCODE)." }

    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

    $hiberboot = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled
    $hiberfilExists = Test-Path -LiteralPath "$env:SystemDrive\hiberfil.sys"
    $ac = (& powercfg.exe /Q SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current AC Power Setting Index').ToString()
    $dc = (& powercfg.exe /Q SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current DC Power Setting Index').ToString()
    if ($hiberboot -ne 1 -or -not $hiberfilExists -or $ac -notmatch '0x00000000' -or $dc -notmatch '0x00000001') {
        throw 'Power setting verification failed.'
    }
    Write-Host 'OK: Hibernate enabled; lid does nothing on AC and sleeps on battery.'
    exit $OK
} catch { Write-Host "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
