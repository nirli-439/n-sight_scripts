<#
.SYNOPSIS
    Checks whether hibernate is enabled on this ThinkPad (companion to Restore_Hibernate_ThinkPad.ps1).

.DESCRIPTION
    24x7 Check for N-Sight RMM. PASS if HiberbootEnabled=1 and a hiberfil.sys exists
    (hibernate on); WARNING otherwise (hibernate off, e.g. after the AMD sleep
    remediation task ran).

.EXECUTION
    Windows (local): powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Hibernate_Enabled.ps1"

.OUTPUTS
    Exit 0    = PASS (hibernate enabled)
    Exit 1001 = WARNING (hibernate disabled)
    Exit 1002 = CRITICAL (could not read state)
#>

$EXIT_OK = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

try {
    $powerReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $hiberboot = (Get-ItemProperty -LiteralPath $powerReg -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
    $hiberfilExists = Test-Path -LiteralPath "$env:SystemDrive\hiberfil.sys"

    if ($hiberboot -eq 1 -and $hiberfilExists) {
        Write-Host "PASS: Hibernate enabled (HiberbootEnabled=1, hiberfil.sys present) on $env:COMPUTERNAME"
        exit $EXIT_OK
    }

    Write-Host "WARNING: Hibernate disabled (HiberbootEnabled=$hiberboot, hiberfil.sys present=$hiberfilExists) on $env:COMPUTERNAME"
    exit $EXIT_WARNING
} catch {
    Write-Host "CRITICAL: Could not read hibernate state - $_"
    exit $EXIT_CRITICAL
}
