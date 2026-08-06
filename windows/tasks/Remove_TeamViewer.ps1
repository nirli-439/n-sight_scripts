<#
.SYNOPSIS
    Remove TeamViewer from Windows and clean leftover services, tasks, folders, and registry.

.DESCRIPTION
    Stops TeamViewer services and processes, runs the official uninstaller (/S), then removes
    scheduled tasks, Program Files/ProgramData/user folders, and registry keys. Designed for
    N-Sight RMM deployment. Idempotent: safe to run when TeamViewer is not installed.

.PARAMETER NoRestart
    Do not restart the computer after removal. N-Sight can handle reboot via policy.

.EXECUTION
    Windows (local):  iex (Get-Content ".\Remove_TeamViewer.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remove_TeamViewer.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remove_TeamViewer.ps1")
.NOTES
    Exit 0 = success; 1002 = failure (N-Sight reserved 1-999).
    Uninstall: TeamViewer uninstall.exe uses capital /S for silent uninstall.
    Platform: Windows 10/11. Requires Administrator.
#>

[CmdletBinding()]
param(
    [switch]$NoRestart
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Remove_TeamViewer_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

$TeamViewerFolders = @(
    "$env:ProgramFiles\TeamViewer",
    "${env:ProgramFiles(x86)}\TeamViewer",
    "$env:ProgramData\TeamViewer",
    "$env:ProgramData\TeamViewer Meeting"
)

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Summary {
    param([ValidateSet("OK", "CRITICAL")][string]$Status, [string]$Message)
    Write-Host ""
    Write-Host "${Status}: $Message"
}

function Stop-TeamViewerServices {
    Write-Log "Stopping TeamViewer services..."
    Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '(?i)teamviewer' -or $_.DisplayName -match '(?i)teamviewer'
    } | ForEach-Object {
        try {
            if ($_.Status -ne 'Stopped') { Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue }
            & sc.exe config $_.Name start= disabled 2>$null
            Write-Log "Stopped: $($_.Name)" -Level "SUCCESS"
        } catch { Write-Log "Could not stop $($_.Name)" -Level "WARN" }
    }
    Start-Sleep -Seconds 2
}

function Stop-TeamViewerProcesses {
    Write-Log "Stopping TeamViewer processes..."
    $patterns = 'teamviewer|teamviewer_service|teamviewer_desk'
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $patterns } | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
            Write-Log "Stopped process: $($_.ProcessName)" -Level "SUCCESS"
        } catch {
            try { & taskkill /F /PID $_.Id 2>$null } catch { }
        }
    }
    Start-Sleep -Seconds 2
}

function Uninstall-TeamViewer {
    $uninstallPaths = @(
        "$env:ProgramFiles\TeamViewer\uninstall.exe",
        "${env:ProgramFiles(x86)}\TeamViewer\uninstall.exe"
    )
    $ran = $false
    foreach ($path in $uninstallPaths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Write-Log "Running uninstaller: $path /S"
        try {
            $proc = Start-Process -FilePath $path -ArgumentList "/S" -Wait -PassThru -NoNewWindow
            Write-Log "Uninstaller exit code: $($proc.ExitCode)"
            $ran = $true
        } catch {
            Write-Log "Uninstall failed: $_" -Level "WARN"
        }
        Start-Sleep -Seconds 3
    }
    if (-not $ran) { Write-Log "No TeamViewer uninstall.exe found; continuing with cleanup." -Level "INFO" }
}

function Remove-TeamViewerTasks {
    Write-Log "Removing TeamViewer scheduled tasks..."
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -match '(?i)teamviewer' -or $_.TaskPath -match '(?i)teamviewer'
    } | ForEach-Object {
        try {
            Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log "Removed task: $($_.TaskPath)$($_.TaskName)" -Level "SUCCESS"
        } catch { Write-Log "Could not remove task $($_.TaskName)" -Level "WARN" }
    }
}

function Remove-TeamViewerFolders {
    Write-Log "Removing TeamViewer folders..."
    foreach ($folder in $TeamViewerFolders) {
        if (Test-Path -LiteralPath $folder) {
            try {
                & takeown /F "$folder" /R /A /D Y 2>$null
                & icacls "$folder" /reset /T /C /Q 2>$null
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $folder" -Level "SUCCESS"
            } catch {
                try { & cmd.exe /c "rd /s /q `"$folder`"" 2>$null } catch { }
                if (-not (Test-Path -LiteralPath $folder)) { Write-Log "Removed via cmd: $folder" -Level "SUCCESS" }
            }
        }
    }
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($userDir in $userProfiles) {
        @("AppData\Local\TeamViewer", "AppData\Roaming\TeamViewer", "AppData\LocalLow\TeamViewer") | ForEach-Object {
            $p = Join-Path $userDir.FullName $_
            if (Test-Path -LiteralPath $p) {
                try { Remove-Item -Path $p -Recurse -Force -ErrorAction Stop; Write-Log "Removed: $p" -Level "SUCCESS" } catch { }
            }
        }
    }
    Get-Item -Path "$env:TEMP\TeamViewer*" -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Remove-TeamViewerRegistry {
    Write-Log "Cleaning TeamViewer registry..."
    $keysToRemove = @(
        "HKLM:\SOFTWARE\TeamViewer",
        "HKLM:\SOFTWARE\WOW6432Node\TeamViewer"
    )
    foreach ($key in $keysToRemove) {
        if (Test-Path -LiteralPath $key) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $key" -Level "SUCCESS"
            } catch { Write-Log "Could not remove $key" -Level "WARN" }
        }
    }
    Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).DisplayName -match '(?i)teamviewer' } |
        ForEach-Object {
            try {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed Uninstall key: $($_.PSPath)" -Level "SUCCESS"
            } catch { Write-Log "Could not remove $($_.PSPath)" -Level "WARN" }
        }
    $runKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($runKey in $runKeys) {
        if (-not (Test-Path -LiteralPath $runKey)) { continue }
        try {
            (Get-ItemProperty -Path $runKey -ErrorAction Stop).PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS' -and $_.Name -match '(?i)teamviewer' } |
                ForEach-Object {
                    Remove-ItemProperty -Path $runKey -Name $_.Name -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed Run: $($_.Name)" -Level "SUCCESS"
                }
        } catch { }
    }
    foreach ($key in @("HKCU:\SOFTWARE\TeamViewer")) {
        if (Test-Path -LiteralPath $key) {
            try { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue; Write-Log "Removed: $key" -Level "SUCCESS" } catch { }
        }
    }
}

# ========== MAIN ==========
Write-Log "=========================================="
Write-Log "Remove TeamViewer - N-Sight RMM"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME | Log: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "Requires Administrator." -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    Stop-TeamViewerServices
    Stop-TeamViewerProcesses
    Uninstall-TeamViewer
    Stop-TeamViewerProcesses
    Stop-TeamViewerServices
    Remove-TeamViewerTasks
    Remove-TeamViewerFolders
    Remove-TeamViewerRegistry

    Write-Log "TeamViewer removal and cleanup completed." -Level "SUCCESS"
    Write-Summary -Status "OK" -Message "TeamViewer removed and cleaned. Reboot recommended."

    if (-not $NoRestart) {
        Write-Log "Restarting in 30 seconds..."
        Start-Sleep -Seconds 30
        Restart-Computer -Force
    } else {
        Write-Log "NoRestart: manual reboot recommended."
    }
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Removal failed: $_" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "TeamViewer removal failed - $_"
    exit $EXIT_CRITICAL
}
