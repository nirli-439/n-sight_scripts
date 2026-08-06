<#
.SYNOPSIS
    Check if the computer name starts with "IA" (Inventory Asset naming convention).
    
.DESCRIPTION
    This monitoring script checks for proper computer naming convention compliance:
    - Verifies computer name starts with "IA" prefix
    - Reports computer name details for inventory tracking
    - Designed for N-Sight RMM monitoring checks
    
    Exit Codes:
    - 0 = OK (Computer name starts with IA)
    - 2 = Critical (Computer name does NOT start with IA)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_ComputerName_Inventory.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_ComputerName_Inventory.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_ComputerName_Inventory.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\ComputerNameCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Naming convention prefix
$RequiredPrefix = "IA"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ComputerNameInfo {
    <#
    .SYNOPSIS
        Gets detailed computer name information including pending renames
    #>
    
    $result = @{
        ComputerName = $env:COMPUTERNAME
        PendingComputerName = $null
        IsRestartPending = $false
        DNSHostName = $null
        Domain = $null
        StartsWithIA = $false
        PendingStartsWithIA = $false
    }
    
    # Check if current name starts with required prefix (case-insensitive)
    $result.StartsWithIA = $result.ComputerName -like "$RequiredPrefix*"
    
    # Check for pending rename in registry
    try {
        $activeName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -ErrorAction SilentlyContinue).ComputerName
        $pendingName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
        
        if ($activeName -and $pendingName -and $activeName -ne $pendingName) {
            $result.IsRestartPending = $true
            $result.PendingComputerName = $pendingName
            $result.PendingStartsWithIA = $pendingName -like "$RequiredPrefix*"
        }
    }
    catch {
        # Continue without pending info
    }
    
    # Get additional computer info
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computerSystem) {
            $result.DNSHostName = $computerSystem.DNSHostName
            $result.Domain = $computerSystem.Domain
        }
    }
    catch {
        # Continue without additional info
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Computer Name Inventory Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "Required Prefix: $RequiredPrefix"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "CRITICAL: Script requires administrator privileges"
    exit 1002
}

try {
    # Check computer name compliance
    $nameInfo = Get-ComputerNameInfo
    
    Write-Log "Current Computer Name: $($nameInfo.ComputerName)"
    Write-Log "DNS Host Name: $($nameInfo.DNSHostName)"
    Write-Log "Domain: $($nameInfo.Domain)"
    Write-Log "Starts with '$RequiredPrefix': $($nameInfo.StartsWithIA)"
    
    if ($nameInfo.IsRestartPending) {
        Write-Log "Pending Computer Name: $($nameInfo.PendingComputerName)"
        Write-Log "Pending Starts with '$RequiredPrefix': $($nameInfo.PendingStartsWithIA)"
    }
    
    if ($nameInfo.StartsWithIA) {
        Write-Log "Computer Name Status: COMPLIANT"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard
        Write-Host ""
        Write-Host "OK: Computer name complies with inventory naming convention"
        Write-Host "Computer Name: $($nameInfo.ComputerName)"
        Write-Host "Naming Convention: Starts with '$RequiredPrefix'"
        if ($nameInfo.Domain) {
            Write-Host "Domain: $($nameInfo.Domain)"
        }
        
        exit 0
    }
    elseif ($nameInfo.IsRestartPending -and $nameInfo.PendingStartsWithIA) {
        Write-Log "Computer Name Status: PENDING RESTART" -Level "WARNING"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard (WARNING: 1001)
        Write-Host ""
        Write-Host "WARNING: Computer name change to '$($nameInfo.PendingComputerName)' is pending"
        Write-Host "Current Name: $($nameInfo.ComputerName)"
        Write-Host "Action Required: Manual restart required for rename to take effect"
        Write-Host "Note: Rename script was already executed, pending reboot"
        
        exit 1001
    }
    else {
        Write-Log "Computer Name Status: NON-COMPLIANT" -Level "WARNING"
        Write-Log "Expected prefix: $RequiredPrefix" -Level "WARNING"
        Write-Log "=========================================="
        
        # Output for N-Sight RMM dashboard (CRITICAL: 1002)
        Write-Host ""
        Write-Host "CRITICAL: Computer name does NOT comply with inventory naming convention"
        Write-Host "Current Name: $($nameInfo.ComputerName)"
        if ($nameInfo.IsRestartPending) {
            Write-Host "Pending Name: $($nameInfo.PendingComputerName) (Also non-compliant)"
        }
        Write-Host "Required: Name must start with '$RequiredPrefix'"
        if ($nameInfo.Domain) {
            Write-Host "Domain: $($nameInfo.Domain)"
        }
        
        exit 1002
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "CRITICAL: Computer name check failed - $_"
    
    exit 1002
}
