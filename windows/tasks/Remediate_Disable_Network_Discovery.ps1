<#
.SYNOPSIS
    Disables Windows LAN discovery and discovery-related broadcasts.
.DESCRIPTION
    Disables Network Discovery firewall rules, Function Discovery, SSDP/UPnP,
    LLMNR, multicast DNS, and NetBIOS over TCP/IP. This prevents LAN device
    discovery; local network printers/shares must be configured explicitly.
.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remediate_Disable_Network_Discovery.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Remediate_Disable_Network_Discovery.ps1")
.NOTES
    Requires: Administrator privileges
    Platform: Windows 10/11
.OUTPUTS
    Exit 0 = Success; Exit 1002 = Critical/Error
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$services = 'fdPHost','FDResPub','SSDPSRV','upnphost'

try {
    foreach ($service in $services) {
        $item = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($item) {
            if ($item.Status -ne 'Stopped') { Stop-Service -Name $service -Force }
            Set-Service -Name $service -StartupType Disabled
        }
    }

    Get-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue |
        Set-NetFirewallRule -Enabled False

    New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Force | Out-Null
    New-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast -PropertyType DWord -Value 0 -Force | Out-Null
    New-Item 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Force | Out-Null
    New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name EnableMDNS -PropertyType DWord -Value 0 -Force | Out-Null

    Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object {
        Invoke-CimMethod -InputObject $_ -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = 2 } | Out-Null
    }

    Write-Host "OK: Network discovery, SSDP/UPnP, LLMNR, mDNS, and NetBIOS broadcasts disabled"
    exit 0
} catch {
    Write-Host "CRITICAL: Failed to disable network discovery - $($_.Exception.Message)"
    exit 1002
}
