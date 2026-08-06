<#
.SYNOPSIS
    Checks if network performance optimizations for Tailscale are applied.

.DESCRIPTION
    This monitoring script checks if the Tailscale network tweaks are active:
    - UDP 41641 Inbound/Outbound Firewall rules are present.
    - Receive Segment Coalescing (RSC) is disabled on active adapters.
    - LSO and Checksum Offload are disabled on the Tailscale (Wintun) adapter.
    - TCP Window Auto-Tuning is set to 'Normal'.
    
    It also outputs standard Tailscale diagnostic information (netcheck and status) 
    for visibility within the N-Sight RMM dashboard.

    Exit Codes:
    - 0    = OK (All optimizations are applied correctly)
    - 1001 = Warning (One or more optimizations are missing or misconfigured)
    - 1002 = Critical (Tailscale is not installed or CLI is missing)

.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Tailscale_Performance.ps1" -Raw)
    Or:               powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Tailscale_Performance.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Tailscale_Performance.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

# Ensure the script is running as Administrator
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "CRITICAL: This check must be run as an Administrator (SYSTEM)."
    exit 1002
}

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

$issues = @()

# Validate Tailscale CLI exists
$tsPath = "${env:ProgramFiles}\Tailscale\tailscale.exe"
if (-not (Test-Path $tsPath)) {
    Write-Host "CRITICAL: Tailscale CLI not found at '$tsPath'. Ensure Tailscale is installed."
    exit $EXIT_CRITICAL
}

# 1. Check Firewall Rules
$rules = Get-NetFirewallRule -Name "TailscaleIn", "TailscaleOut" -ErrorAction SilentlyContinue
if ($rules.Count -lt 2) {
    $issues += "Firewall UDP 41641 rules missing/incomplete"
}

# 2. Check RSC
try {
    $rscEnabled = Get-NetAdapterRsc -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Enabled -eq $true -or $_.IPv6Enabled -eq $true }
    if ($rscEnabled) {
        $adapters = $rscEnabled.Name -join ', '
        $issues += "RSC is still enabled ($adapters)"
    }
}
catch {
    $issues += "Could not check RSC status"
}

# 3. Check Tailscale Adapter Offloading
$tsAdapters = Get-NetAdapter -Name "Tailscale*" -ErrorAction SilentlyContinue
if ($tsAdapters) {
    $lsoFail = $false
    $chkFail = $false
    foreach ($adapter in $tsAdapters) {
        $lso = Get-NetAdapterLso -Name $adapter.Name -ErrorAction SilentlyContinue
        if ($lso -and ($lso.IPv4Enabled -eq $true -or $lso.IPv6Enabled -eq $true)) { $lsoFail = $true }
        
        $chk = Get-NetAdapterChecksumOffload -Name $adapter.Name -ErrorAction SilentlyContinue
        if ($chk -and ($chk.IpIPv4Enabled -eq $true -or $chk.TcpIPv4Enabled -eq $true -or $chk.UdpIPv4Enabled -eq $true)) { $chkFail = $true }
    }
    if ($lsoFail -or $chkFail) {
        $issues += "LSO or Checksum Offload is enabled on Tailscale adapter"
    }
}
else {
    $issues += "Tailscale virtual network adapter not found"
}

# 4. Check TCP Auto-Tuning
try {
    $tcpSetting = Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue
    if ($tcpSetting.AutoTuningLevelLocal -ne "Normal") {
        $issues += "TCP Auto-Tuning is '$($tcpSetting.AutoTuningLevelLocal)' (expected 'Normal')"
    }
}
catch {
    $issues += "Could not check TCP Auto-Tuning"
}

# -----------------------------------------------------------------------------
# First line output (critical for N-Sight dashboard)
# -----------------------------------------------------------------------------
if ($issues.Count -eq 0) {
    Write-Host "OK: All Tailscale network optimizations are applied."
    $finalExitCode = $EXIT_SUCCESS
}
else {
    $issueText = $issues -join " | "
    Write-Host "WARNING: Missing optimizations: $issueText"
    $finalExitCode = $EXIT_WARNING
}

# -----------------------------------------------------------------------------
# Detailed Diagnostic Output
# -----------------------------------------------------------------------------
Write-Host "`n================================================="
Write-Host "Tailscale Diagnostic Report"
Write-Host "================================================="
try {
    Write-Host "--> Running 'tailscale netcheck':"
    & $tsPath netcheck
    Write-Host "`n--> Running 'tailscale status':"
    & $tsPath status
}
catch {
    Write-Host "Failed to run tailscale diagnostic commands."
}
Write-Host "================================================="

exit $finalExitCode
