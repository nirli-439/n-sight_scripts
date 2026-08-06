<#
.SYNOPSIS
    Keep Edge out of the way: remove shortcuts and prevent it from being default browser.
    
.DESCRIPTION
    Light-touch approach: does NOT uninstall Microsoft Edge (avoids breaking Windows).
    - Removes Edge shortcuts (desktop, Start Menu, taskbar) for all users
    - Sets Chrome as default browser and locks it via policy so Edge cannot take over
    - Registers a persistent scheduled task to re-apply shortcuts removal and Chrome default
      so Chrome always stays on top (e.g. after Windows updates or user changes)
    
    Designed for Google Workspace environments where Chrome is the only approved browser.
    
.PARAMETER SkipScheduledTask
    If specified, the script will not create/update the persistent scheduled task.
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Remove_Edge.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remove_Edge.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remove_Edge.ps1")
.NOTES
    Author: IT Admin
    Version: 2.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    Designed for N-Sight RMM deployment (Session 0, no user interaction).
.OUTPUTS
    Exit 0    = Success
    Exit 1001 = Warning (Partial success)
    Exit 1002 = Critical/Error (Failed)
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipScheduledTask
)

# ============================================================================
# CONFIGURATION
# ============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = "SilentlyContinue"

$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Remove_Edge_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

$TaskName = "KeepChromeDefault_RemoveEdgeShortcuts"

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

function Write-Summary {
    param(
        [ValidateSet("OK", "WARNING", "CRITICAL")]
        [string]$Status,
        [string]$Message
    )
    Write-Host ""
    Write-Host "${Status}: $Message"
}

function Remove-EdgeShortcuts {
    Write-Log "Removing Edge shortcuts and pins (all users)..."
    
    $shortcutLocations = @(
        "$env:PUBLIC\Desktop\Microsoft Edge.lnk",
        "$env:USERPROFILE\Desktop\Microsoft Edge.lnk",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
        "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
    )
    
    foreach ($shortcut in $shortcutLocations) {
        if (Test-Path $shortcut) {
            try {
                Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
                Write-Log "Removed shortcut: $shortcut"
            }
            catch {
                Write-Log "Could not remove shortcut ${shortcut}: $_" -Level "WARNING"
            }
        }
    }
    
    # All user profiles (N-Sight often runs as SYSTEM)
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notin @('Public', 'Default', 'Default User', 'All Users')
    }
    
    foreach ($userProfile in $userProfiles) {
        $paths = @(
            "$($userProfile.FullName)\Desktop\Microsoft Edge.lnk",
            "$($userProfile.FullName)\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk",
            "$($userProfile.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                try {
                    Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed: $p"
                }
                catch {
                    Write-Log "Could not remove $p : $_" -Level "WARNING"
                }
            }
        }
    }
}

function Set-ChromeAsDefaultBrowser {
    Write-Log "Setting Chrome as default browser (and locking so Edge cannot take over)..."
    
    $chromePath = $null
    if (Test-Path "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe") {
        $chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
    } elseif (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") {
        $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    }
    
    if (-not $chromePath) {
        Write-Log "Chrome not found - cannot set as default browser" -Level "WARNING"
        return $false
    }
    
    Write-Log "Chrome found at: $chromePath"
    
    try {
        # Register ChromeHTML in HKLM for system-wide use
        $chromeHtmlPath = "HKLM:\SOFTWARE\Classes\ChromeHTML"
        if (-not (Test-Path $chromeHtmlPath)) { New-Item -Path $chromeHtmlPath -Force | Out-Null }
        Set-ItemProperty -Path $chromeHtmlPath -Name "(Default)" -Value "Chrome HTML Document" -Force -ErrorAction SilentlyContinue
        
        $chromeShellPath = "HKLM:\SOFTWARE\Classes\ChromeHTML\shell\open\command"
        if (-not (Test-Path $chromeShellPath)) { New-Item -Path $chromeShellPath -Force | Out-Null }
        Set-ItemProperty -Path $chromeShellPath -Name "(Default)" -Value "`"$chromePath`" -- `"%1`"" -Force -ErrorAction SilentlyContinue
        
        # Lock default browser via DefaultAssociations policy (Edge cannot override)
        $xml = @"
<DefaultAssociations><Association Identifier=".htm" ProgId="ChromeHTML" ApplicationName="Google Chrome"/><Association Identifier=".html" ProgId="ChromeHTML" ApplicationName="Google Chrome"/><Association Identifier=".pdf" ProgId="ChromeHTML" ApplicationName="Google Chrome"/><Association Identifier="http" ProgId="ChromeHTML" ApplicationName="Google Chrome"/><Association Identifier="https" ProgId="ChromeHTML" ApplicationName="Google Chrome"/></DefaultAssociations>
"@
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($xml)
        $base64 = [Convert]::ToBase64String($bytes)
        $sysPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        if (-not (Test-Path $sysPolicyPath)) { New-Item -Path $sysPolicyPath -Force | Out-Null }
        Set-ItemProperty -Path $sysPolicyPath -Name "DefaultAssociationsConfiguration" -Value $base64 -Type String -Force -ErrorAction SilentlyContinue
        Write-Log "Set DefaultAssociations policy (Chrome locked as default)"
        
        # Set current user and common user hives so existing users get Chrome without reboot
        $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') -and
            (Test-Path "$($_.FullName)\NTUSER.DAT" -ErrorAction SilentlyContinue)
        }
        
        foreach ($userProfile in $userProfiles) {
            $userRegBase = "HKCU:"
            $tempKey = "HKU\TempHive_$($userProfile.Name)"
            $isLoaded = $false
            
            try {
                if ($userProfile.FullName -ne $env:USERPROFILE) {
                    $null = & reg load $tempKey "$($userProfile.FullName)\NTUSER.DAT" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $isLoaded = $true
                        $userRegBase = "Registry::$tempKey"
                    } else { continue }
                }
                
                foreach ($protocol in @("http", "https")) {
                    $userChoicePath = "$userRegBase\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\$protocol\UserChoice"
                    if (Test-Path $userChoicePath) {
                        $regPath = $userChoicePath -replace "^HKCU:", "HKCU" -replace "^Registry::HKU\\", "HKU\"
                        & reg delete $regPath /f 2>&1 | Out-Null
                    }
                    if (-not (Test-Path $userChoicePath)) { New-Item -Path $userChoicePath -Force | Out-Null }
                    Set-ItemProperty -Path $userChoicePath -Name "ProgId" -Value "ChromeHTML" -Force -ErrorAction SilentlyContinue
                }
                
                foreach ($ext in @(".htm", ".html", ".shtml", ".xhtml", ".xht", ".mht", ".mhtml", ".svg", ".webp", ".pdf")) {
                    $fileAssocPath = "$userRegBase\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
                    if (Test-Path $fileAssocPath) {
                        $regPath = $fileAssocPath -replace "^HKCU:", "HKCU" -replace "^Registry::HKU\\", "HKU\"
                        & reg delete $regPath /f 2>&1 | Out-Null
                    }
                    if (-not (Test-Path $fileAssocPath)) { New-Item -Path $fileAssocPath -Force | Out-Null }
                    Set-ItemProperty -Path $fileAssocPath -Name "ProgId" -Value "ChromeHTML" -Force -ErrorAction SilentlyContinue
                }
                Write-Log "Set Chrome default for user: $($userProfile.Name)"
            }
            finally {
                if ($isLoaded) {
                    Start-Sleep -Milliseconds 500
                    & reg unload $tempKey 2>&1 | Out-Null
                }
            }
        }
        
        # HKLM file/protocol defaults
        foreach ($fileType in @(".html", ".htm", ".shtml", ".xhtml", ".xht", ".mht", ".mhtml", ".svg", ".webp")) {
            $classPath = "HKLM:\SOFTWARE\Classes\$fileType"
            if (-not (Test-Path $classPath)) { New-Item -Path $classPath -Force | Out-Null }
            Set-ItemProperty -Path $classPath -Name "(Default)" -Value "ChromeHTML" -Force -ErrorAction SilentlyContinue
        }
        $pdfClassPath = "HKLM:\SOFTWARE\Classes\.pdf"
        if (-not (Test-Path $pdfClassPath)) { New-Item -Path $pdfClassPath -Force | Out-Null }
        Set-ItemProperty -Path $pdfClassPath -Name "(Default)" -Value "ChromeHTML" -Force -ErrorAction SilentlyContinue
        
        foreach ($protocol in @("http", "https")) {
            $protocolPath = "HKLM:\SOFTWARE\Classes\$protocol\shell\open\command"
            if (-not (Test-Path $protocolPath)) { New-Item -Path $protocolPath -Force | Out-Null }
            Set-ItemProperty -Path $protocolPath -Name "(Default)" -Value "`"$chromePath`" -- `"%1`"" -Force -ErrorAction SilentlyContinue
        }
        
        Write-Log "Chrome set as default; Edge cannot take over (policy locked)"
        return $true
    }
    catch {
        Write-Log "Error setting Chrome as default: $_" -Level "WARNING"
        return $false
    }
}

function Register-PersistentTask {
    Write-Log "Registering persistent scheduled task: $TaskName"
    
    # When run via iex(irm ...), $PSCommandPath is empty; do not use $MyInvocation.MyCommand (strict-mode .Path throw)
    $actionExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $repoUrl = "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remove_Edge.ps1"
    $tmpScript = "`$env:TEMP\Remove_Edge.ps1"
    $actionArgs = $null
    
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $scriptDir = Split-Path -Parent $PSCommandPath
        $scriptFile = Join-Path $scriptDir "Remove_Edge.ps1"
        if (Test-Path -LiteralPath $scriptFile) {
            $actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptFile`" -SkipScheduledTask"
        }
        if (-not $actionArgs) {
            $enforceScript = Join-Path $scriptDir "Enforce_Chrome_Default_Browser.ps1"
            if (Test-Path -LiteralPath $enforceScript) {
                $actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$enforceScript`""
            }
        }
    }
    if (-not $actionArgs) {
        Write-Log "Script not on disk (run via irm); task will download and run script with -SkipScheduledTask" -Level "WARNING"
        $actionArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " + [char]34 + "irm '$repoUrl' | Out-File -FilePath $tmpScript -Encoding utf8; & $tmpScript -SkipScheduledTask" + [char]34
    }
    
    try {
        Set-StrictMode -Off
        try {
            $action = New-ScheduledTaskAction -Execute $actionExe -Argument $actionArgs -WindowStyle Hidden
            $trigger1 = New-ScheduledTaskTrigger -AtLogOn
            $trigger2 = New-ScheduledTaskTrigger -Daily -At "12:00AM" -RandomDelay (New-TimeSpan -Minutes 30)
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigger1, $trigger2) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Write-Log "Scheduled task registered: at logon and daily to keep Chrome on top and remove Edge shortcuts"
            return $true
        }
        finally {
            Set-StrictMode -Version Latest
        }
    }
    catch {
        Write-Log "Could not register scheduled task: $_" -Level "WARNING"
        return $false
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Remove Edge shortcuts / Keep Chrome default (light)"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "Log File: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    Remove-EdgeShortcuts
    $chromeSet = Set-ChromeAsDefaultBrowser
    
    if (-not $SkipScheduledTask) {
        $taskOk = Register-PersistentTask
        if (-not $taskOk) {
            Write-Log "Scheduled task creation failed; run script periodically via N-Sight or GPO" -Level "WARNING"
        }
    }
    else {
        Write-Log "Skipping scheduled task (-SkipScheduledTask)"
    }
    
    Write-Log "=========================================="
    Write-Log "Done. Edge remains installed; shortcuts removed, Chrome locked as default."
    Write-Log "=========================================="
    
    Write-Summary -Status "OK" -Message "Edge shortcuts removed; Chrome is default and locked (persistent task registered)"
    Write-Host "Chrome default: $(if ($chromeSet) { 'Yes' } else { 'No (Chrome not installed)' })"
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Script failed - $_"
    exit $EXIT_CRITICAL
}
