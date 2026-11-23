<#
.SYNOPSIS
    Verifies the key machine-wide speed/focus tweaks from Optimize_Windows_AI_Workstation.ps1.

.DESCRIPTION
    Read-only. Checks the HKLM policies and services that matter most (consumer features,
    widgets, Copilot, Recall, telemetry service, Chrome background mode). Per-user settings
    are not checked (they vary by profile and apply at sign-in).

.EXECUTION
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_Windows_Optimized.ps1")

.NOTES
    Version: 1.0
    Paired task: windows/tasks/Optimize_Windows_AI_Workstation.ps1

.OUTPUTS
    Exit 0    = All key tweaks in place
    Exit 1001 = One or more missing - run the paired task
#>

$ErrorActionPreference = 'SilentlyContinue'

$P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$Expected = @(
    @("$P\CloudContent", 'DisableWindowsConsumerFeatures', 1),
    @("$P\WindowsCopilot", 'TurnOffWindowsCopilot', 1),
    @("$P\WindowsAI", 'DisableAIDataAnalysis', 1),
    @("$P\Windows Search", 'DisableWebSearch', 1),
    @("$P\GameDVR", 'AllowGameDVR', 0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'BackgroundModeEnabled', 0)
)

$missing = @()
foreach ($e in $Expected) {
    $v = (Get-ItemProperty -LiteralPath $e[0] -Name $e[1] -ErrorAction SilentlyContinue).($e[1])
    if ($null -eq $v -or [int]$v -ne $e[2]) { $missing += $e[1] }
}
$diag = Get-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue
if ($diag -and $diag.StartType -ne 'Disabled') { $missing += 'DiagTrack service' }

if ($missing.Count -gt 0) {
    Write-Host "WARNING: Windows not optimized - missing: $($missing -join ', ')"
    exit 1001
}
Write-Host 'OK: Windows speed/focus tweaks in place'
exit 0
