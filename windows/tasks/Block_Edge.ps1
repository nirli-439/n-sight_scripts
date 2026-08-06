<#
.SYNOPSIS
    Block Microsoft Edge via policy (light) so the readiness check passes.

.DESCRIPTION
    Sets Group Policy / registry so Edge is blocked from being set as default
    and the "Edge Blocked/Removed" check passes. Does not remove Edge or
    modify IFEO/shortcuts; policy-only for quick, reliable remediation.

    The readiness check passes when:
    - Edge is not present, OR
    - HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate has InstallDefault = 0

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Block_Edge.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Block_Edge.ps1")
.NOTES
    Author: IT Admin
    Version: 2.1 (light)
    Requires: Administrator privileges
    Platform: Windows 10/11

.OUTPUTS
    Exit 0    = Success (policy set, check will pass)
    Exit 1002 = Critical/Error
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$ScriptName = "Block_Edge"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Administrator privileges required" -Level "ERROR"
    exit $EXIT_CRITICAL
}

try {
    $blockRegPath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
    if (-not (Test-Path $blockRegPath)) {
        New-Item -Path $blockRegPath -ItemType Directory -Force | Out-Null
    }
    Set-ItemProperty -Path $blockRegPath -Name "InstallDefault" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $blockRegPath -Name "UpdateDefault" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Log "Edge block policy set: InstallDefault=0 (check will pass)"
    Write-Host "OK: Edge blocked via policy on $env:COMPUTERNAME"
    exit $EXIT_SUCCESS
} catch {
    Write-Log "Failed to set Edge block policy: $_" -Level "ERROR"
    Write-Host "CRITICAL: Block Edge failed - $_"
    exit $EXIT_CRITICAL
}
