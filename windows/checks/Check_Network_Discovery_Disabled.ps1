<#
.SYNOPSIS
    Checks that Windows LAN discovery broadcasts are disabled.
.DESCRIPTION
    Validates discovery services, Network Discovery firewall rules, LLMNR,
    mDNS, and NetBIOS. Does not inspect or disable Wi-Fi or Bluetooth.
.EXECUTION
    Windows (repo): iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_Network_Discovery_Disabled.ps1")
.OUTPUTS
    Exit 0 = Compliant; Exit 1002 = Non-compliant or error
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

try {
    $failures = @()
    $services = 'fdPHost','FDResPub','SSDPSRV','upnphost'
    $failures += Get-Service -Name $services -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Stopped' -or $_.StartType -ne 'Disabled' } | ForEach-Object { "service:$($_.Name)" }
    $failures += Get-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True' | ForEach-Object { "firewall:$($_.DisplayName)" }

    $llmnr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -ErrorAction SilentlyContinue).EnableMulticast
    $mdns = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name EnableMDNS -ErrorAction SilentlyContinue).EnableMDNS
    if ($llmnr -ne 0) { $failures += 'LLMNR' }
    if ($mdns -ne 0) { $failures += 'mDNS' }

    $netbios = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | Where-Object TcpipNetbiosOptions -ne 2
    if ($netbios) { $failures += 'NetBIOS' }

    if ($failures.Count) {
        Write-Host "CRITICAL: Network discovery enabled - $($failures -join ', ')"
        exit 1002
    }
    Write-Host 'OK: Network discovery broadcasts disabled; Wi-Fi and Bluetooth untouched'
    exit 0
} catch {
    Write-Host "CRITICAL: Network discovery check failed - $($_.Exception.Message)"
    exit 1002
}
