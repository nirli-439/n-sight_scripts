<#
.SYNOPSIS
    Checks if McAfee products are installed on the system.
    
.DESCRIPTION
    Detects McAfee installation by checking:
    - Registry uninstall entries
    - Running services
    - Running processes
    - Installation folders
    - Registry keys
    
    Designed for N-Sight RMM deployment as a monitoring check.
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_McAfee_Installed.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_McAfee_Installed.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_McAfee_Installed.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
.OUTPUTS
    Exit 0 = McAfee NOT installed (OK)
    Exit 1001 = McAfee IS installed (Warning)
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$LogFile = "$env:TEMP\Check_McAfee_Installed_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "McAfee Installation Check Started"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "Log File: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    exit 1002
}

# Track findings
$mcafeeFound = $false
$findings = @()

# ============================================================================
# CHECK 1: Registry Uninstall Entries
# ============================================================================
Write-Log "Checking registry uninstall entries..."

$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

$mcafeeProducts = @()

foreach ($root in $uninstallPaths) {
    try {
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $props = Get-ItemProperty -Path $_.PsPath -ErrorAction SilentlyContinue
                if ($props -and $props.DisplayName -match '(?i)mcafee|mfe|mvk|mcafee agent|endpoint security') {
                    $mcafeeProducts += [PSCustomObject]@{
                        Name = $props.DisplayName
                        Version = $props.DisplayVersion
                        Publisher = $props.Publisher
                    }
                }
            } catch { }
        }
    } catch { }
}

if ($mcafeeProducts.Count -gt 0) {
    $mcafeeFound = $true
    foreach ($product in $mcafeeProducts) {
        $msg = "Found installed product: $($product.Name) (Version: $($product.Version))"
        Write-Log $msg -Level "WARN"
        $findings += $msg
    }
} else {
    Write-Log "No McAfee products found in registry uninstall keys"
}

# ============================================================================
# CHECK 2: McAfee Services
# ============================================================================
Write-Log "Checking for McAfee services..."

$mcafeeServices = Get-Service | Where-Object { 
    $_.Name -match '(?i)mcafee|mfetp|mfe\.|masvc|mcshield|mfemms|mcagent' -or 
    $_.DisplayName -match '(?i)mcafee|mfe' 
}

if ($mcafeeServices) {
    $mcafeeFound = $true
    foreach ($svc in $mcafeeServices) {
        $msg = "Found service: $($svc.Name) - $($svc.DisplayName) [Status: $($svc.Status)]"
        Write-Log $msg -Level "WARN"
        $findings += $msg
    }
} else {
    Write-Log "No McAfee services found"
}

# ============================================================================
# CHECK 3: McAfee Processes
# ============================================================================
Write-Log "Checking for McAfee processes..."

$processPatterns = @('mcshield','mfevtp','masvc','mfemms','mcafee','mfetp','mcagent','mfewc')

$mcafeeProcesses = Get-Process | Where-Object {
    $procName = $_.ProcessName
    $processPatterns | Where-Object { $procName -match "(?i)$_" }
}

if ($mcafeeProcesses) {
    $mcafeeFound = $true
    foreach ($proc in $mcafeeProcesses) {
        $msg = "Found running process: $($proc.ProcessName) (PID: $($proc.Id))"
        Write-Log $msg -Level "WARN"
        $findings += $msg
    }
} else {
    Write-Log "No McAfee processes running"
}

# ============================================================================
# CHECK 4: McAfee Folders
# ============================================================================
Write-Log "Checking for McAfee installation folders..."

$folders = @(
    "$env:ProgramFiles\McAfee",
    "${env:ProgramFiles(x86)}\McAfee",
    "$env:ProgramData\McAfee",
    "C:\Program Files\Common Files\McAfee"
)

foreach ($folder in $folders) {
    if (Test-Path $folder) {
        $mcafeeFound = $true
        $msg = "Found folder: $folder"
        Write-Log $msg -Level "WARN"
        $findings += $msg
    }
}

if (-not ($findings | Where-Object { $_ -match "Found folder" })) {
    Write-Log "No McAfee folders found"
}

# ============================================================================
# CHECK 5: McAfee Registry Keys
# ============================================================================
Write-Log "Checking for McAfee registry keys..."

$regKeys = @(
    "HKLM:\SOFTWARE\McAfee",
    "HKLM:\SOFTWARE\Wow6432Node\McAfee"
)

foreach ($key in $regKeys) {
    if (Test-Path $key) {
        $mcafeeFound = $true
        $msg = "Found registry key: $key"
        Write-Log $msg -Level "WARN"
        $findings += $msg
    }
}

if (-not ($findings | Where-Object { $_ -match "Found registry key" })) {
    Write-Log "No McAfee registry keys found"
}

# ============================================================================
# RESULTS SUMMARY
# ============================================================================
Write-Log "=========================================="
Write-Log "Check Complete - Summary"
Write-Log "=========================================="

if ($mcafeeFound) {
    Write-Log "RESULT: McAfee IS INSTALLED on this system" -Level "WARN"
    Write-Log "Total findings: $($findings.Count)"
    Write-Host ""
    Write-Host "WARNING: McAfee detected on $env:COMPUTERNAME" -ForegroundColor Yellow
    foreach ($finding in $findings) {
        Write-Host "  - $finding" -ForegroundColor Yellow
    }
    exit 1001
} else {
    Write-Log "RESULT: McAfee is NOT installed on this system"
    Write-Host ""
    Write-Host "OK: No McAfee installation detected on $env:COMPUTERNAME" -ForegroundColor Green
    exit 0
}
