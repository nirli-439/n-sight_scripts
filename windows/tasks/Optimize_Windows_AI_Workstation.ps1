<#
.SYNOPSIS
    Speed + focus tweaks for a Claude / Chrome work laptop (inspired by ChrisTitusTech winutil "standard" tweaks).

.DESCRIPTION
    Safe, reversible subset only - nothing that breaks Slack/Claude notifications, sign-in,
    Windows Update, Bitdefender, GCPW, hibernate or screen-lock policies (other scripts own those).

    Machine (HKLM / services / tasks):
      - System restore point first (best effort)
      - Telemetry to "Required", DiagTrack + dmwappushservice disabled, CEIP/telemetry tasks off
      - Consumer features / suggested apps / cloud content off
      - Widgets, News feed, Windows Copilot, Recall (AI data analysis), Activity history off
      - Bing / web results in Start search off, Cortana off
      - Game DVR off, advertising ID off, feedback prompts off
      - Xbox / Maps / RetailDemo services to Manual/Disabled
      - Power: "Best performance" power mode when plugged in (battery stays balanced)
      - Chrome policies: Memory Saver on, no background mode after close, no promo tabs,
        managed "Work" bookmarks folder (Claude, Gmail, Calendar, Drive)
    Per user (every loaded user profile + Default profile for new users):
      - File extensions shown, Explorer opens "This PC"
      - Taskbar: search as icon, no Task View / Chat / Copilot button, "End task" on right-click
      - Start/Settings/lock-screen suggestions, tips and silently-installed apps off
      - Fewer animations (minimize/taskbar/peek), shorter menu delay, no startup-app delay
    Cleanup: temp files older than 2 days (Windows + each user). -DeepClean adds DISM
    component cleanup (slow, several minutes).

    Every change is independent and wrapped - one failure never stops the rest.
    Changes apply fully after sign-out or reboot.

.PARAMETER NoRestorePoint
    Skip the system restore point.
.PARAMETER NoCleanup
    Skip the temp-file cleanup.
.PARAMETER DeepClean
    Also run DISM /StartComponentCleanup (slow).

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Optimize_Windows_AI_Workstation.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Optimize_Windows_AI_Workstation.ps1")

.NOTES
    Version: 1.0
    Requires: Administrator (works as SYSTEM under N-Sight too)
    Platform: Windows 10/11
    Paired check: windows/checks/Check_Windows_Optimized.ps1
    Undo: System Restore point "Before Optimize_Windows_AI_Workstation".

.OUTPUTS
    Exit 0    = All tweaks applied
    Exit 1001 = Some tweaks could not be applied (listed)
    Exit 1002 = Not Administrator
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$NoRestorePoint,
    [switch]$NoCleanup,
    [switch]$DeepClean
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ScriptName = 'Optimize_Windows_AI_Workstation'
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

$Script:Applied = 0
$Script:Failed = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        $Script:Applied++
    } catch {
        $Script:Failed.Add("$Path\$Name")
        Write-Log "Could not set $Path\$Name : $($_.Exception.Message)" 'WARN'
    }
}

function Set-ServiceStart {
    param([string]$Name, [ValidateSet('Disabled', 'Manual')][string]$Mode)
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $s) { return }   # not present on this build - nothing to do
    try {
        Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop
        if ($Mode -eq 'Disabled' -and $s.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        $Script:Applied++
    } catch {
        $Script:Failed.Add("service $Name")
        Write-Log "Could not set service $Name to $Mode : $($_.Exception.Message)" 'WARN'
    }
}

function Disable-Task {
    param([string]$TaskPath, [string]$TaskName)
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return }
    try { Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null; $Script:Applied++ }
    catch { Write-Log "Could not disable task $TaskPath$TaskName : $($_.Exception.Message)" 'WARN' }   # not counted as failure
}

# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'CRITICAL: Run as Administrator.'; exit $EXIT_CRITICAL }

Write-Log "$ScriptName on $env:COMPUTERNAME"

# --- 0. Restore point (best effort, never fails the run) ---
if (-not $NoRestorePoint) {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        Checkpoint-Computer -Description "Before $ScriptName" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created'
    } catch {
        Write-Log "Restore point skipped: $($_.Exception.Message)" 'WARN'
    }
}

# --- 1. Machine policies ---
$P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
Set-Reg "$P\DataCollection" 'AllowTelemetry' 1
Set-Reg "$P\DataCollection" 'DoNotShowFeedbackNotifications' 1
Set-Reg "$P\DataCollection" 'DisableTailoredExperiencesWithDiagnosticData' 1
Set-Reg "$P\CloudContent" 'DisableWindowsConsumerFeatures' 1
Set-Reg "$P\CloudContent" 'DisableConsumerAccountStateContent' 1
Set-Reg "$P\CloudContent" 'DisableSoftLanding' 1
Set-Reg "$P\CloudContent" 'DisableCloudOptimizedContent' 1
Set-Reg "$P\System" 'EnableActivityFeed' 0
Set-Reg "$P\System" 'PublishUserActivities' 0
Set-Reg "$P\System" 'UploadUserActivities' 0
Set-Reg "$P\Windows Search" 'AllowCortana' 0
Set-Reg "$P\Windows Search" 'DisableWebSearch' 1
Set-Reg "$P\Windows Search" 'ConnectedSearchUseWeb' 0
Set-Reg "$P\Windows Feeds" 'EnableFeeds' 0
Set-Reg "$P\WindowsCopilot" 'TurnOffWindowsCopilot' 1
Set-Reg "$P\WindowsAI" 'DisableAIDataAnalysis' 1
Set-Reg "$P\GameDVR" 'AllowGameDVR' 0
Set-Reg "$P\AdvertisingInfo" 'DisabledByGroupPolicy' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0

# --- 2. Services and scheduled tasks ---
Set-ServiceStart 'DiagTrack' 'Disabled'
Set-ServiceStart 'dmwappushservice' 'Disabled'
Set-ServiceStart 'RetailDemo' 'Disabled'
Set-ServiceStart 'MapsBroker' 'Manual'
foreach ($s in 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc') { Set-ServiceStart $s 'Manual' }

Disable-Task '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraiser'
Disable-Task '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater'
Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'
Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'
Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'
Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'

# --- 3. Power: Best performance when plugged in (Windows 11 power mode overlay) ---
$pw = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
if (Test-Path $pw) { Set-Reg $pw 'ActiveOverlayAcPowerScheme' 'ded574b5-45a0-4f42-8737-46345c09c238' 'String' }

# --- 4. Chrome: lean + work bookmarks ---
$C = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
Set-Reg $C 'HighEfficiencyModeEnabled' 1
Set-Reg $C 'BackgroundModeEnabled' 0
Set-Reg $C 'PromotionalTabsEnabled' 0
$bookmarks = '[{"toplevel_name":"Work"},{"name":"Claude","url":"https://claude.ai"},{"name":"Gmail","url":"https://mail.google.com"},{"name":"Calendar","url":"https://calendar.google.com"},{"name":"Drive","url":"https://drive.google.com"}]'
Set-Reg $C 'ManagedBookmarks' $bookmarks 'String'
Set-Reg $C 'BookmarkBarEnabled' 1

# --- 5. Per-user settings: every loaded profile + Default (new users) ---
$UserTweaks = @(
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'HideFileExt', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'LaunchTo', 1),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowTaskViewButton', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'TaskbarMn', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowCopilotButton', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'TaskbarAnimations', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ListviewShadow', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings', 'TaskbarEndTask', 1),
    @('Software\Microsoft\Windows\CurrentVersion\Search', 'SearchboxTaskbarMode', 1),
    @('Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0),
    @('Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SilentInstalledAppsEnabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SystemPaneSuggestionsEnabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SoftLandingEnabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'PreInstalledAppsEnabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'OemPreInstalledAppsEnabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'RotatingLockScreenOverlayEnabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-310093Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338388Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338389Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338393Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353694Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353696Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', 'ScoobeSystemSettingEnabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Privacy', 'TailoredExperiencesWithDiagnosticDataEnabled', 0),
    @('Software\Microsoft\Siuf\Rules', 'NumberOfSIUFInPeriod', 0),
    @('Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled', 0),
    @('System\GameConfigStore', 'GameDVR_Enabled', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects', 'VisualFXSetting', 3),
    @('Software\Microsoft\Windows\DWM', 'EnableAeroPeek', 0),
    @('Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize', 'StartupDelayInMSec', 0),
    @('Software\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1),
    @('Control Panel\Desktop', 'MenuShowDelay', '100', 'String'),
    @('Control Panel\Desktop\WindowMetrics', 'MinAnimate', '0', 'String')
)

function Set-UserTweaks {
    param([string]$HiveRoot)   # e.g. Registry::HKEY_USERS\S-1-5-21-...
    foreach ($t in $UserTweaks) {
        $type = if ($t.Count -ge 4) { $t[3] } else { 'DWord' }
        Set-Reg "$HiveRoot\$($t[0])" $t[1] $t[2] $type
    }
}

$sids = Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
    Select-Object -ExpandProperty PSChildName
foreach ($sid in $sids) {
    Write-Log "Applying user settings to loaded profile $sid"
    Set-UserTweaks "Registry::HKEY_USERS\$sid"
}

$defaultHive = "$env:SystemDrive\Users\Default\NTUSER.DAT"
if (Test-Path -LiteralPath $defaultHive) {
    & reg.exe load 'HKU\NSOPT_DEFAULT' $defaultHive 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Applying user settings to Default profile (new users)'
        Set-UserTweaks 'Registry::HKEY_USERS\NSOPT_DEFAULT'
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
        & reg.exe unload 'HKU\NSOPT_DEFAULT' 2>&1 | Out-Null
    } else {
        Write-Log 'Default profile hive is in use - skipped (existing users still done)' 'WARN'
    }
}

# --- 6. Cleanup ---
if (-not $NoCleanup) {
    $cutoff = (Get-Date).AddDays(-2)
    $tempDirs = @("$env:SystemRoot\Temp")
    $tempDirs += Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' }
    $freed = 0
    foreach ($d in $tempDirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                $len = $_.Length
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $_.FullName)) { $freed += $len }
            }
    }
    Write-Log ("Temp cleanup freed {0:N0} MB" -f ($freed / 1MB))
}
if ($DeepClean) {
    Write-Log 'DISM component cleanup (slow)...'
    & "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image /StartComponentCleanup /NoRestart | Out-Null
    Write-Log "DISM exit $LASTEXITCODE"
}

# --- Result ---
Write-Log "Applied $($Script:Applied) settings; $($Script:Failed.Count) failed. Log: $LogFile"
if ($Script:Failed.Count -gt 0) {
    Write-Host "WARNING: $($Script:Applied) tweaks applied, $($Script:Failed.Count) failed: $(($Script:Failed | Select-Object -First 5) -join '; ')"
    exit $EXIT_WARNING
}
Write-Host "OK: $($Script:Applied) speed/focus tweaks applied - sign out or reboot to see all of them"
exit $EXIT_SUCCESS
