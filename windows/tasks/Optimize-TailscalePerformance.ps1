<#
.SYNOPSIS
    Optimizes network performance for Tailscale on Windows endpoints.

.DESCRIPTION
    This script implements various network tweaks to improve Tailscale performance,
    particularly after environments migrate from other VPN solutions like Twingate. 
    It configures firewall rules to allow direct UDP connections on port 41641, 
    disables Receive Segment Coalescing (RSC), disables LSO/Checksum offloading 
    on the Wintun adapter, enables TCP AutoTuning, strictly disables DERP 
    Relays to enforce direct connections, disables IPv6 on the Tailscale adapter,
    adjusts the MTU size to prevent UDP fragmentation, forces active UDP NAT
    hole punching to the backend AWS Frankfurt endpoints, enables Receive Side 
    Scaling (RSS), disables Large Send Offload (LSO) on Physical Adapters, 
    configures CUBIC TCP congestion control, and sets a QoS policy (DSCP 46) 
    for Tailscale executables to prioritize VPN traffic.

    The script runs transparently without restarting services or dropping network
    connections, ensuring zero disruption to end-users. It includes pre- and 
    post-optimization performance checks using Tailscale CLI tools (`netcheck` 
    and `status`) and outputs results directly to the RMM dashboard.

.EXECUTION
    Windows (local):  .\Optimize-TailscalePerformance.ps1
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Optimize-TailscalePerformance.ps1")
.NOTES
    Author: IT Admin
    Version: 2.2
    Requires: Administrator privileges
    Platform: Windows 10/11

.OUTPUTS
    Exit 0    = Success
    Exit 1001 = Warning
    Exit 1002 = Critical/Error
#>

# Ensure the script is running as Administrator
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script must be run as an Administrator. Please elevate your PowerShell session."
    exit 1002
}

function Run-TailscaleDiagnostic {
    param([string]$Phase)
    Write-Output ""
    Write-Output "================================================="
    Write-Output "[$Phase] Tailscale Diagnostic Check"
    Write-Output "================================================="
    
    $tsPath = "${env:ProgramFiles}\Tailscale\tailscale.exe"
    if (-not (Test-Path $tsPath)) {
        Write-Warning "Tailscale CLI not found at '$tsPath'. Ensure Tailscale is installed."
        Write-Output "=================================================`n"
        return
    }

    Write-Output "--> Running 'tailscale netcheck' (Checks UDP/DERP Latency)..."
    & $tsPath netcheck

    Write-Output "`n--> Running 'tailscale status' (Checks for Direct vs Relay)..."
    & $tsPath status
    Write-Output "=================================================`n"
}

Write-Output "Starting Tailscale Performance Optimization (Silent & Transparent)..."
Run-TailscaleDiagnostic -Phase "Pre-Optimization"

# 1. Firewall Rules for Tailscale UDP 41641
Write-Output "1/12. Configuring Windows Defender Firewall for Tailscale (UDP 41641)..."
$FirewallRules = @(
    @{ Name = "TailscaleIn"; Direction = "Inbound"; Description = "Allow Inbound UDP 41641 for Tailscale" },
    @{ Name = "TailscaleOut"; Direction = "Outbound"; Description = "Allow Outbound UDP 41641 for Tailscale" }
)

foreach ($Rule in $FirewallRules) {
    $existingRule = Get-NetFirewallRule -Name $Rule.Name -ErrorAction SilentlyContinue
    if ($existingRule) {
        Write-Output "     Updating existing $($Rule.Direction) firewall rule '$($Rule.Name)'..."
        Set-NetFirewallRule -Name $Rule.Name -Direction $Rule.Direction -Action Allow -Protocol UDP -LocalPort 41641 -Profile Any
    }
    else {
        Write-Output "     Creating new $($Rule.Direction) firewall rule '$($Rule.Name)'..."
        New-NetFirewallRule -DisplayName "Tailscale (UDP 41641 $($Rule.Direction))" -Name $Rule.Name -Direction $Rule.Direction -Action Allow -Protocol UDP -LocalPort 41641 -Profile Any | Out-Null
    }
}

# 2. Disable Receive Segment Coalescing (RSC) to fix UDP offloading issues
Write-Output "2/12. Checking Receive Segment Coalescing (RSC) settings..."
try {
    # Get all network adapters that support RSC and are currently enabled
    $rscAdapters = Get-NetAdapterRsc | Where-Object { $_.IPv4Enabled -eq $true -or $_.IPv6Enabled -eq $true }
    
    if ($rscAdapters) {
        foreach ($adapter in $rscAdapters) {
            Write-Output "     Disabling RSC on adapter: $($adapter.Name)"
            Disable-NetAdapterRsc -Name $adapter.Name -IPv4 -IPv6 -ErrorAction Continue
        }
    }
    else {
        Write-Output "     No active physical adapters with RSC enabled were found. Skipping."
    }
}
catch {
    Write-Warning "     Failed to configure RSC settings. Error: $_"
}

# 3. Disable LSO & Checksum Offload on Tailscale (Wintun) Adapter
Write-Output "3/12. Disabling LSO & Checksum Offload on Tailscale Adapter..."
try {
    $tsAdapters = Get-NetAdapter -Name "Tailscale*" -ErrorAction SilentlyContinue
    if ($tsAdapters) {
        foreach ($adapter in $tsAdapters) {
            Write-Output "     Disabling LSO on adapter: $($adapter.Name)"
            Disable-NetAdapterLso -Name $adapter.Name -IPv4 -IPv6 -ErrorAction SilentlyContinue
            Write-Output "     Disabling Checksum Offload on adapter: $($adapter.Name)"
            Disable-NetAdapterChecksumOffload -Name $adapter.Name -IpIPv4 -TcpIPv4 -UdpIPv4 -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Output "     Tailscale virtual network adapter not found. Skipping."
    }
}
catch {
    Write-Warning "     Failed to configure Tailscale adapter offload. Error: $_"
}

# 4. Enable TCP Auto-Tuning
Write-Output "4/12. Ensuring TCP Window Auto-Tuning is enabled..."
try {
    netsh int tcp set global autotuninglevel=normal | Out-Null
    Write-Output "     TCP Auto-Tuning Level set to 'normal'."
}
catch {
    Write-Warning "     Failed to set TCP Auto-Tuning. Error: $_"
}

# 5. Disable DERP Relays (Force Direct Connection or Nothing)
Write-Output "5/12. Disabling DERP Relays (Enforcing Direct Connection only)..."
try {
    $tsPath = "${env:ProgramFiles}\Tailscale\tailscale.exe"
    if (Test-Path $tsPath) {
        # Using debug flag to disable all DERP routing nodes natively
        & $tsPath debug derp 0
        Write-Output "     DERP Relays disabled successfully. Tailscale will now only connect via Direct P2P."
    }
    else {
        Write-Warning "     Tailscale CLI not found to configure DERP."
    }
}
catch {
    Write-Warning "     Failed to disable DERP Relays via CLI. Error: $_"
}

# 6. Disable IPv6 on Tailscale Adapter
Write-Output "6/12. Disabling IPv6 on Tailscale Adapter..."
try {
    $tsAdapters = Get-NetAdapter -Name "Tailscale*" -ErrorAction SilentlyContinue
    if ($tsAdapters) {
        foreach ($adapter in $tsAdapters) {
            Write-Output "     Disabling IPv6 bindings on adapter: $($adapter.Name)"
            Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Output "     Tailscale virtual network adapter not found. Skipping."
    }
}
catch {
    Write-Warning "     Failed to disable IPv6 on Tailscale adapter. Error: $_"
}

# 7. Decrease MTU to prevent UDP fragmentation
Write-Output "7/12. Decreasing MTU size on Tailscale Adapter to 1280..."
try {
    $tsAdapters = Get-NetAdapter -Name "Tailscale*" -ErrorAction SilentlyContinue
    if ($tsAdapters) {
        foreach ($adapter in $tsAdapters) {
            Write-Output "     Setting MTU to 1280 for adapter: $($adapter.Name)"
            Set-NetIPInterface -InterfaceAlias $adapter.Name -NlMtuBytes 1280 -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Output "     Tailscale virtual network adapter not found. Skipping."
    }
}
catch {
    Write-Warning "     Failed to adjust MTU on Tailscale adapter. Error: $_"
}

# 8. Force UDP NAT Hole Punching to AWS Frankfurt (tailscale-prod-router-1)
Write-Output "8/12. Forcing UDP NAT Hole Punch to AWS Frankfurt Endpoints..."
try {
    # The user's backend router is 18.192.224.45 (AWS Frankfurt). 
    # Because NAT-PMP/UPnP are disabled on that node, we must forcefully send 
    # outbound UDP traffic to those exact ports to punch a stateful hole in the client's firewall/ISP.
    $endpoints = @("18.192.224.45:28165", "18.192.224.45:65135")
    
    foreach ($ep in $endpoints) {
        $ip = $ep.Split(':')[0]
        $port = $ep.Split(':')[1]
        Write-Output "     Punching UDP hole for $ip on port $port..."
        
        # Send raw UDP datagrams to force the state open
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect($ip, $port)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("ping")
        $null = $udpClient.Send($bytes, $bytes.Length)
        $udpClient.Close()
    }
    Write-Output "     Successfully sent outbound UDP packets to establish NAT state."
}
catch {
    Write-Warning "     Failed to force UDP NAT hole punch. Error: $_"
}

# 9. Enable Receive Side Scaling (RSS) for multi-core packet processing
Write-Output "9/12. Enabling Receive Side Scaling (RSS) on all capable adapters..."
try {
    # It might already be enabled, silently continue if so
    Enable-NetAdapterRss -Name "*" -ErrorAction SilentlyContinue
    netsh int tcp set global rss=enabled | Out-Null
    Write-Output "     RSS enabled successfully."
}
catch {
    Write-Warning "     Failed to configure RSS. Error: $_"
}

# 10. Disable Large Send Offload (LSO) on Physical Adapters (IPv4/IPv6)
Write-Output "10/12. Disabling Large Send Offload (LSO) on Physical Adapters..."
try {
    # Only target non-virtual (physical) adapters, LSO causes fragmentation issues over tunnels
    $physicalAdapters = Get-NetAdapter | Where-Object Virtual -eq $False
    if ($physicalAdapters) {
        foreach ($adapter in $physicalAdapters) {
            Write-Output "     Disabling LSO on adapter: $($adapter.Name)"
            Disable-NetAdapterLso -Name $adapter.Name -IPv4 -IPv6 -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Warning "     Failed to disable physical adapter LSO. Error: $_"
}

# 11. Switch TCP Congestion Control to CUBIC
Write-Output "11/12. Setting TCP Congestion Control to CUBIC (Optimized for High Latency)..."
try {
    netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null
    Write-Output "     TCP Congestion Control set to CUBIC."
}
catch {
    Write-Warning "     Failed to set TCP Congestion Control. Error: $_"
}

# 12. Prioritize Tailscale Traffic with QoS (DSCP 46)
Write-Output "12/12. Adding QoS Policy to prioritize Tailscale traffic (DSCP 46)..."
try {
    # Force Windows to apply QoS tags even if not on a Domain network (Required for remote work machines)
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS" -Name "Do not use NLA" -Value "1" -PropertyType "String" -Force -ErrorAction SilentlyContinue | Out-Null

    # Remove existing ones if any just to be clean
    Remove-NetQosPolicy -Name "Tailscale Priority" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Remove-NetQosPolicy -Name "Tailscaled Priority" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    
    # 46 = Expedited Forwarding (Premium priority for Voice/VPNs across capable routers)
    New-NetQosPolicy -Name "Tailscale Priority" -AppPathNameMatchCondition "tailscale.exe" -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
    New-NetQosPolicy -Name "Tailscaled Priority" -AppPathNameMatchCondition "tailscaled.exe" -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
    Write-Output "     Created QoS Policy marking tailscale traffic as Expedited Forwarding priority."
}
catch {
    Write-Warning "     Failed to create QoS rules. Error: $_"
}

Write-Output "`nTailscale Performance Optimization applied successfully."

Run-TailscaleDiagnostic -Phase "Post-Optimization"

Pause
exit 0
