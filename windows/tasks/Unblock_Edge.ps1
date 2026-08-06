<#
.SYNOPSIS
    Unblock Microsoft Edge (reverses Block_Edge.ps1 script).
    
.DESCRIPTION
    This script reverses the Edge blocking performed by Block_Edge.ps1:
    - Removes IFEO debugger entries that intercept Edge launches
    - Removes the blocker script folder (BrowserPolicy)
    - Removes Edge-related policies that disable default browser settings
    
    After running, Microsoft Edge will launch normally again.
    Designed for N-Sight RMM deployment.
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Unblock_Edge.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Unblock_Edge.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Unblock_Edge.ps1")
.NOTES
    Author: IT Admin
    Version: 1.1
    Requires: Administrator privileges
    Platform: Windows 10/11
    
.OUTPUTS
    Exit 0    = Success
    Exit 1001 = Warning (partial success)
    Exit 1002 = Critical/Error
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Unblock_Edge"
$ScriptVersion = "1.1"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Exit codes for N-Sight
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# Blocker script location (created by Block_Edge.ps1)
$BlockerFolder = "$env:ProgramData\BrowserPolicy"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message, 
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Summary {
    <#
    .SYNOPSIS
        Writes a concise summary for N-Sight dashboard display.
        Keep under 255 characters for best visibility.
    #>
    param(
        [ValidateSet("OK", "WARNING", "CRITICAL")]
        [string]$Status,
        [string]$Message
    )
    Write-Host ""
    Write-Host "${Status}: $Message"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName v$ScriptVersion Started"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User Context: $env:USERNAME"
Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Log File: $LogFile"

# Admin check
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    $changesCount = 0
    $warningsCount = 0
    
    # ========================================
    # Step 1: Remove IFEO debugger entries
    # ========================================
    Write-Log "Removing IFEO debugger entries..."
    
    $edgeExecutables = @("msedge.exe", "MicrosoftEdge.exe")
    
    foreach ($exe in $edgeExecutables) {
        $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
        
        if (Test-Path $ifeoPath) {
            # Check if Debugger property exists
            $debuggerValue = Get-ItemProperty -Path $ifeoPath -Name "Debugger" -ErrorAction SilentlyContinue
            
            if ($debuggerValue) {
                Remove-ItemProperty -Path $ifeoPath -Name "Debugger" -ErrorAction SilentlyContinue
                Write-Log "Removed IFEO debugger for: $exe" -Level "SUCCESS"
                $changesCount++
                
                # Remove key if empty (no other properties besides PS* metadata)
                $props = Get-ItemProperty -Path $ifeoPath -ErrorAction SilentlyContinue
                $customProps = $props.PSObject.Properties.Name | Where-Object { $_ -notlike "PS*" }
                if (-not $customProps -or $customProps.Count -eq 0) {
                    Remove-Item -Path $ifeoPath -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed empty IFEO key: $exe"
                }
            } else {
                Write-Log "No IFEO debugger found for: $exe (already clean)"
            }
        } else {
            Write-Log "IFEO key not found for: $exe (already clean)"
        }
    }
    
    # ========================================
    # Step 2: Remove blocker script folder
    # ========================================
    Write-Log "Removing blocker script folder..."
    
    if (Test-Path $BlockerFolder) {
        try {
            Remove-Item -Path $BlockerFolder -Recurse -Force -ErrorAction Stop
            Write-Log "Removed blocker script folder: $BlockerFolder" -Level "SUCCESS"
            $changesCount++
        } catch {
            Write-Log "Could not remove blocker folder: ${_}" -Level "WARN"
            $warningsCount++
        }
    } else {
        Write-Log "Blocker folder not found: $BlockerFolder (already clean)"
    }
    
    # ========================================
    # Step 3: Remove Edge-blocking policies
    # ========================================
    Write-Log "Removing Edge-blocking policies..."
    
    $edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    
    if (Test-Path $edgePolicyPath) {
        # Remove specific policies set by Block_Edge.ps1
        $policiesToRemove = @(
            "HideFirstRunExperience",
            "DefaultBrowserSettingEnabled",
            "AlwaysOpenPdfExternally"
        )
        
        foreach ($policy in $policiesToRemove) {
            try {
                $policyValue = Get-ItemProperty -Path $edgePolicyPath -Name $policy -ErrorAction SilentlyContinue
                if ($policyValue) {
                    Remove-ItemProperty -Path $edgePolicyPath -Name $policy -ErrorAction SilentlyContinue
                    Write-Log "Removed Edge policy: $policy" -Level "SUCCESS"
                    $changesCount++
                } else {
                    Write-Log "Edge policy not found: $policy (already clean)"
                }
            } catch {
                Write-Log "Could not remove policy ${policy}: ${_}" -Level "WARN"
                $warningsCount++
            }
        }
        
        # Check if policy key is now empty and remove if so
        $remainingProps = Get-ItemProperty -Path $edgePolicyPath -ErrorAction SilentlyContinue
        $customProps = $remainingProps.PSObject.Properties.Name | Where-Object { $_ -notlike "PS*" }
        if (-not $customProps -or $customProps.Count -eq 0) {
            Remove-Item -Path $edgePolicyPath -Force -ErrorAction SilentlyContinue
            Write-Log "Removed empty Edge policy key"
        }
    } else {
        Write-Log "Edge policy key not found (already clean)"
    }
    
    # ========================================
    # Completion summary
    # ========================================
    Write-Log "=========================================="
    Write-Log "$ScriptName completed"
    Write-Log "=========================================="
    Write-Log "Changes made: $changesCount"
    Write-Log "Warnings: $warningsCount"
    
    Write-Host ""
    Write-Host "Edge Unblock Summary:"
    Write-Host "  - IFEO debugger entries: Removed"
    Write-Host "  - Blocker script folder: Removed"
    Write-Host "  - Edge policies: Removed"
    Write-Host ""
    Write-Host "Microsoft Edge will now launch normally."
    
    if ($warningsCount -gt 0) {
        Write-Log "Script completed with warnings" -Level "WARN"
        Write-Summary -Status "WARNING" -Message "Edge unblocked with $warningsCount warning(s) on $env:COMPUTERNAME"
        exit $EXIT_WARNING
    } else {
        Write-Log "Script completed successfully!" -Level "SUCCESS"
        Write-Summary -Status "OK" -Message "Edge unblocked successfully on $env:COMPUTERNAME"
        exit $EXIT_SUCCESS
    }
}
catch {
    Write-Log "Script failed: ${_}" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Failed to unblock Edge - ${_}"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Script execution ended"
}
