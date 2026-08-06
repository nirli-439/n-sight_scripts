<#
.SYNOPSIS
    Rename a Windows computer to a new hostname.
    
.DESCRIPTION
    This script renames the local Windows computer to a specified hostname.
    - Validates hostname according to Windows naming conventions
    - Performs the rename operation
    - Optionally schedules an automatic restart
    - Designed for N-Sight RMM deployment
    
    The new hostname can be provided via:
    1. Command line parameter: -NewName "HOSTNAME"
    2. Environment variable: $env:NEW_HOSTNAME (for N-Sight RMM)
    
    Exit Codes:
    - 0 = Success (rename completed, restart pending)
    - 1 = Warning (validation issue or minor problem)
    - 2 = Critical (rename failed)
    
.PARAMETER NewName
    The new hostname for the computer (3-15 characters, alphanumeric and hyphens only)
    
.PARAMETER AutoRestart
    If specified, automatically restart the computer after rename (default: false)
    
.PARAMETER RestartDelay
    Delay in seconds before automatic restart (default: 60)
    
.EXAMPLE
    .\Rename_Computer.ps1 -NewName "PC-SALES-001"
    
.EXAMPLE
    .\Rename_Computer.ps1 -NewName "PC-SALES-001" -AutoRestart -RestartDelay 30
    
.EXAMPLE
    Rename to IA-454 (via repo):  $env:NEW_HOSTNAME='IA-454'; iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Rename_Computer.ps1")
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Rename_Computer.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Rename_Computer.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Rename_Computer.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11, Windows Server 2016+
    IMPORTANT: A restart is required for the rename to take effect
#>

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$false)]
    [string]$NewName,
    
    [Parameter(Mandatory=$false)]
    [switch]$AutoRestart = $false,
    
    [Parameter(Mandatory=$false)]
    [int]$RestartDelay = 60
)

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Rename_Computer_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Test-ValidHostname {
    <#
    .SYNOPSIS
        Validates hostname according to Windows naming conventions
    #>
    param([string]$Hostname)
    
    $result = @{
        Valid = $true
        Errors = @()
    }
    
    # Check length (1-15 characters for NetBIOS compatibility)
    if ($Hostname.Length -lt 1 -or $Hostname.Length -gt 15) {
        $result.Valid = $false
        $result.Errors += "Hostname must be between 1 and 15 characters (current: $($Hostname.Length))"
    }
    
    # Check for valid characters (alphanumeric and hyphens only)
    if ($Hostname -notmatch '^[a-zA-Z0-9-]+$') {
        $result.Valid = $false
        $result.Errors += "Hostname can only contain letters, numbers, and hyphens"
    }
    
    # Cannot start or end with hyphen
    if ($Hostname -match '^-' -or $Hostname -match '-$') {
        $result.Valid = $false
        $result.Errors += "Hostname cannot start or end with a hyphen"
    }
    
    # Cannot be all numbers
    if ($Hostname -match '^\d+$') {
        $result.Valid = $false
        $result.Errors += "Hostname cannot be entirely numeric"
    }
    
    # Check for reserved names
    $reservedNames = @('LOCALHOST', 'PRINTERS', 'USERS', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 
                       'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4',
                       'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9', 'CON', 'AUX', 'PRN')
    if ($Hostname.ToUpper() -in $reservedNames) {
        $result.Valid = $false
        $result.Errors += "Hostname '$Hostname' is a reserved name and cannot be used"
    }
    
    return $result
}

function Get-ComputerDomainStatus {
    <#
    .SYNOPSIS
        Gets domain/workgroup membership status
    #>
    try {
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
        return @{
            IsDomainJoined = ($computerSystem.PartOfDomain -eq $true)
            Domain = $computerSystem.Domain
            Workgroup = if ($computerSystem.PartOfDomain) { $null } else { $computerSystem.Domain }
        }
    }
    catch {
        return @{
            IsDomainJoined = $false
            Domain = $null
            Workgroup = "WORKGROUP"
        }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Windows Computer Rename Script"
Write-Log "=========================================="
Write-Log "Current Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "CRITICAL: Script requires administrator privileges"
    exit 1002
}

# Get the new hostname from parameter or environment variable
if ([string]::IsNullOrWhiteSpace($NewName)) {
    # Try to get from N-Sight RMM environment variable
    $NewName = $env:NEW_HOSTNAME
}

if ([string]::IsNullOrWhiteSpace($NewName)) {
    Write-Log "No new hostname specified!" -Level "ERROR"
    Write-Log "Provide hostname via -NewName parameter or NEW_HOSTNAME environment variable" -Level "ERROR"
    Write-Host ""
    Write-Host "CRITICAL: No new hostname specified"
    Write-Host "Usage: .\Rename_Computer.ps1 -NewName 'NEW-HOSTNAME'"
    Write-Host "   Or: Set NEW_HOSTNAME environment variable in N-Sight RMM"
    exit 1002
}

# Trim and clean the hostname
$NewName = $NewName.Trim().ToUpper()
Write-Log "Target Hostname: $NewName"

# Check if already named correctly (current or pending)
try {
    $pendingName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue).ComputerName
    if ($env:COMPUTERNAME -eq $NewName -or $pendingName -eq $NewName) {
        if ($env:COMPUTERNAME -eq $NewName) {
            $msg = "Computer is already named '$NewName'"
            Write-Log "$msg - no action needed" -Level "INFO"
            Write-Host ""
            Write-Host "OK: $msg"
        }
        else {
            $msg = "Computer is already pending rename to '$NewName'"
            Write-Log "$msg - no action needed" -Level "INFO"
            Write-Host ""
            Write-Host "OK: $msg"
            Write-Host "IMPORTANT: Manual restart required for changes to take effect"
        }
        exit 0
    }
}
catch {
    # Fallback to current name check only
    if ($env:COMPUTERNAME -eq $NewName) {
        Write-Log "Computer is already named '$NewName' - no action needed" -Level "INFO"
        Write-Host ""
        Write-Host "OK: Computer is already named '$NewName'"
        exit 0
    }
}

try {
    # Validate hostname
    Write-Log "Validating hostname format..."
    $validation = Test-ValidHostname -Hostname $NewName
    
    if (-not $validation.Valid) {
        foreach ($error in $validation.Errors) {
            Write-Log "Validation Error: $error" -Level "ERROR"
        }
        Write-Host ""
        Write-Host "CRITICAL: Invalid hostname '$NewName'"
        foreach ($error in $validation.Errors) {
            Write-Host "  - $error"
        }
        exit 1002
    }
    Write-Log "Hostname validation passed"
    
    # Check domain status
    $domainStatus = Get-ComputerDomainStatus
    if ($domainStatus.IsDomainJoined) {
        Write-Log "Computer is domain-joined to: $($domainStatus.Domain)"
        Write-Log "Note: Domain credentials may be required for rename" -Level "WARNING"
    } else {
        Write-Log "Computer is in workgroup: $($domainStatus.Workgroup)"
    }
    
    # Perform the rename
    Write-Log "=========================================="
    Write-Log "Initiating computer rename..."
    Write-Log "From: $env:COMPUTERNAME"
    Write-Log "To: $NewName"
    Write-Log "=========================================="
    
    # Use Rename-Computer cmdlet (PowerShell 3.0+)
    Rename-Computer -NewName $NewName -Force -ErrorAction Stop
    
    Write-Log "Rename command executed successfully!"
    Write-Log "IMPORTANT: A restart is required for changes to take effect"
    
    # Handle auto-restart if requested
    if ($AutoRestart) {
        Write-Log "Auto-restart enabled - scheduling restart in $RestartDelay seconds..."
        
        # Schedule restart using shutdown command
        $shutdownResult = Start-Process -FilePath "shutdown.exe" -ArgumentList "/r /t $RestartDelay /c `"Computer rename to $NewName - Restarting in $RestartDelay seconds`"" -NoNewWindow -PassThru -Wait
        
        if ($shutdownResult.ExitCode -eq 0) {
            Write-Log "Restart scheduled successfully"
        } else {
            Write-Log "Failed to schedule restart (exit code: $($shutdownResult.ExitCode))" -Level "WARNING"
        }
        
        Write-Host ""
        Write-Host "OK: Computer renamed from '$env:COMPUTERNAME' to '$NewName'"
        Write-Host "Restart scheduled in $RestartDelay seconds"
    } else {
        Write-Host ""
        Write-Host "OK: Computer renamed from '$env:COMPUTERNAME' to '$NewName'"
        Write-Host "IMPORTANT: Manual restart required for changes to take effect"
    }
    
    Write-Log "=========================================="
    Write-Log "Script completed successfully!"
    Write-Log "=========================================="
    
    exit 0
}
catch {
    Write-Log "Rename failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    # Provide helpful error messages for common issues
    if ($_.Exception.Message -like "*Access is denied*") {
        Write-Log "Hint: Ensure the script is running with full administrator privileges" -Level "ERROR"
    }
    elseif ($_.Exception.Message -like "*domain*" -or $_.Exception.Message -like "*credential*") {
        Write-Log "Hint: Domain-joined computers may require domain admin credentials" -Level "ERROR"
    }
    
    Write-Host ""
    Write-Host "CRITICAL: Failed to rename computer - $_"
    
    exit 1002
}

