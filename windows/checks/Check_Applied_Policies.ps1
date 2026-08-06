<#
.SYNOPSIS
    List all Group Policy Objects (GPOs) applied to the computer.

.DESCRIPTION
    Reports which Windows Group Policies are applied to this machine (computer side).
    Uses gpresult to get the applied GPO list. Output is suitable for N-Sight dashboard
    and audit/compliance (first line summary, then one GPO per line).

    Exit Codes:
    - 0 = OK (successfully listed applied policies)
    - 1002 = Error (could not retrieve policy list)

    Designed for N-Sight RMM monitoring and inventory.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Applied_Policies.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Applied_Policies.ps1")

.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges (for reliable gpresult)
    Platform: Windows 10/11, Windows Server 2016+
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$ScriptName = "Check_Applied_Policies"
$LogFile = "$env:TEMP\${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-AppliedGPOs {
    $gpresultOut = $null
    try {
        $gpresultOut = & gpresult.exe /scope computer /r 2>&1 | Out-String
    } catch {
        Write-Log "gpresult failed: $_" -Level "ERROR"
        return $null
    }

    $gpos = [System.Collections.Generic.List[string]]::new()
    $inApplied = $false
    $lines = $gpresultOut -split "`r?`n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        # Start of "Applied Group Policy Objects" section (en-US and common variants)
        if ($trimmed -match "Applied Group Policy Objects|Group Policy Objects applied to the computer|GPOs applied to the computer") {
            $inApplied = $true
            continue
        }
        if ($inApplied) {
            # End of applied list: "not applied" section or next major section
            if ($trimmed -match "The following GPOs were not applied|were not applied|User Configuration|Computer Configuration\s*$") {
                break
            }
            # Skip separators and section headers; collect lines that look like GPO names
            if ($trimmed.Length -gt 0 -and $trimmed -notmatch "^\s*\-+\s*$" -and $trimmed -notmatch "^\s*Computer Configuration\s*$") {
                $gpos.Add($trimmed.Trim())
            }
        }
    }

    # Workgroup / no domain: sometimes only "Local Group Policy" or similar appears
    if ($gpos.Count -eq 0 -and $gpresultOut -match "Local (Group )?Policy|workgroup") {
        $gpos.Add("Local Group Policy")
    }

    return $gpos
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "Listing applied Group Policies - $env:COMPUTERNAME"

$applied = Get-AppliedGPOs
if ($null -eq $applied) {
    Write-Host "CRITICAL: Could not retrieve applied policies (gpresult failed)."
    exit $EXIT_CRITICAL
}

# Dedupe and filter empty
$unique = $applied | Where-Object { $_.Length -gt 0 } | Sort-Object -Unique
$count = @($unique).Count

Write-Host "OK: $count applied GPO(s) on $env:COMPUTERNAME"
Write-Log "Applied GPO count: $count" -Level "INFO"
foreach ($gpo in $unique) {
    Write-Host "  $gpo"
    Write-Log "  $gpo" -Level "INFO"
}

exit $EXIT_SUCCESS
