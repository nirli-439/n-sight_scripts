<#
.SYNOPSIS
    Verifies hibernate is enabled (and visible) and lid-close power actions match policy
    (Do Nothing on AC, Sleep on battery).

.DESCRIPTION
    24x7 Check for N-Sight RMM. Companion to Remediate_Hibernate_LidClose.ps1.
    PASS if HiberbootEnabled=1, hiberfil.sys exists, and the active power scheme's
    lid-close action is "Do Nothing" on AC (LIDACTION=0) and "Sleep" on battery (LIDACTION=1).
    WARNING if any setting has drifted from policy.

    Same intent as Check_Hibernate_Enabled.ps1 (companion to Restore_Hibernate_ThinkPad.ps1) -
    both now expect HiberbootEnabled=1, so they no longer conflict.

.EXECUTION
    Windows (local): powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Hibernate_LidClose.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_Hibernate_LidClose.ps1")

.NOTES
    Author: IT Admin
    Version: 2.0
    Platform: Windows 10/11
    Changelog:
    - 2.0: Reversed to match Remediate_Hibernate_LidClose.ps1 v2.0 (now expects
      HiberbootEnabled=1, hibernate enabled). Renamed from Check_FastBoot_LidClose.ps1.
    - 1.0: Initial version (expected HiberbootEnabled=0 - superseded, see 2.0).

.OUTPUTS
    Exit 0    = PASS (hibernate enabled; lid does nothing on AC, sleeps on battery)
    Exit 1001 = WARNING (one or more settings have drifted from policy)
    Exit 1002 = CRITICAL (could not read power/registry state)
#>

$EXIT_OK = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

try {
    $hiberboot = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
    $hiberfilExists = Test-Path -LiteralPath "$env:SystemDrive\hiberfil.sys"
    $ac = (& powercfg.exe /Q SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current AC Power Setting Index').ToString()
    $dc = (& powercfg.exe /Q SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current DC Power Setting Index').ToString()

    $hibernateOk = ($hiberboot -eq 1) -and $hiberfilExists
    $acOk = ($ac -match '0x00000000')
    $dcOk = ($dc -match '0x00000001')

    if ($hibernateOk -and $acOk -and $dcOk) {
        Write-Host "PASS: Hibernate enabled; lid does nothing on AC, sleeps on battery on $env:COMPUTERNAME"
        exit $EXIT_OK
    }

    Write-Host "WARNING: Drift detected on $env:COMPUTERNAME (HiberbootEnabled=$hiberboot, hiberfil.sys present=$hiberfilExists, AC=$ac, DC=$dc) - run Remediate_Hibernate_LidClose.ps1"
    exit $EXIT_WARNING
} catch {
    Write-Host "CRITICAL: Could not read hibernate / lid-close state - $_"
    exit $EXIT_CRITICAL
}
