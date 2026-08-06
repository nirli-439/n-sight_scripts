<#
.SYNOPSIS
    Remove Microsoft OneDrive from Windows 11 completely (for environments using Google Drive).

.DESCRIPTION
    Stops OneDrive processes, runs the official uninstaller (OneDriveSetup.exe /uninstall),
    removes AppX packages, scheduled tasks, folders, registry entries, and blocks OneDrive
    from reinstalling. Removes OneDrive from File Explorer and fixes folder redirection
    (Documents, Desktop, Pictures) to local paths for all user profiles.
    Designed for N-Sight RMM deployment. Idempotent: safe to run when OneDrive is not installed.

.PARAMETER NoRestart
    Do not restart the computer after removal. N-Sight can handle reboot via policy.

.EXECUTION
    Windows (local):  iex (Get-Content ".\Remove_OneDrive.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remove_OneDrive.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remove_OneDrive.ps1")
.NOTES
    Exit 0 = success; 1001 = warning; 1002 = failure (N-Sight reserved 1-999).
    Platform: Windows 10/11. Requires Administrator.
    Use with Google Drive for Desktop; no user prompts (Session 0 safe).
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$NoRestart
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Remove_OneDrive_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

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
    param([ValidateSet("OK", "WARNING", "CRITICAL")][string]$Status, [string]$Message)
    Write-Host ""
    Write-Host "${Status}: $Message"
}

function Stop-OneDriveProcesses {
    Write-Log "Stopping OneDrive processes..."
    Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
            Write-Log "Stopped process: OneDrive (PID: $($_.Id))" -Level "SUCCESS"
        } catch {
            try { & taskkill /F /PID $_.Id 2>$null } catch { }
        }
    }
    Start-Sleep -Seconds 2
}

function Uninstall-OneDriveApp {
    Write-Log "Uninstalling OneDrive..."

    # Try winget first (Windows 11)
    try {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            $proc = Start-Process -FilePath "winget" -ArgumentList "uninstall", "Microsoft.OneDrive", "--silent", "--accept-source-agreements", "--accept-package-agreements" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0) {
                Write-Log "OneDrive uninstalled via winget." -Level "SUCCESS"
                return $true
            }
        }
    } catch {
        Write-Log "Winget uninstall failed or not available: $_" -Level "WARN"
    }

    # OneDriveSetup.exe /uninstall (per-user and system)
    $setupPaths = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )
    foreach ($path in $setupPaths) {
        if (Test-Path -LiteralPath $path) {
            Write-Log "Running uninstaller: $path /uninstall"
            try {
                $proc = Start-Process -FilePath $path -ArgumentList "/uninstall" -Wait -PassThru -NoNewWindow
                Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                Start-Sleep -Seconds 3
                return $true
            } catch {
                Write-Log "Uninstall failed: $_" -Level "WARN"
            }
        }
    }

    # Run OneDrive.exe /shutdown then /uninstall from user install location (all users)
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($userDir in $userProfiles) {
        $userOneDrive = "$($userDir.FullName)\AppData\Local\Microsoft\OneDrive\OneDrive.exe"
        if (Test-Path -LiteralPath $userOneDrive) {
            try {
                Start-Process -FilePath $userOneDrive -ArgumentList "/shutdown" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Start-Process -FilePath $userOneDrive -ArgumentList "/uninstall" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                Write-Log "Ran per-user uninstall for: $($userDir.Name)"
            } catch { }
        }
    }

    Write-Log "OneDrive uninstall step completed." -Level "INFO"
    return $false
}

function Remove-OneDriveAppx {
    Write-Log "Removing OneDrive AppX packages..."
    try {
        Get-AppxPackage -AllUsers -Name "*OneDrive*" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                Write-Log "Removed AppX: $($_.Name)" -Level "SUCCESS"
            } catch { Write-Log "Could not remove AppX $($_.Name)" -Level "WARN" }
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*OneDrive*" } |
            ForEach-Object {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
                    Write-Log "Removed provisioned: $($_.DisplayName)" -Level "SUCCESS"
                } catch { Write-Log "Could not remove provisioned $($_.DisplayName)" -Level "WARN" }
            }
    } catch {
        Write-Log "AppX removal error: $_" -Level "WARN"
    }
}

function Remove-OneDriveTasks {
    Write-Log "Removing OneDrive scheduled tasks..."
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match '(?i)onedrive' -or $_.TaskPath -match '(?i)onedrive' } |
        ForEach-Object {
            try {
                Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
                Write-Log "Removed task: $($_.TaskPath)$($_.TaskName)" -Level "SUCCESS"
            } catch { Write-Log "Could not remove task $($_.TaskName)" -Level "WARN" }
        }
}

function Remove-OneDriveFolders {
    Write-Log "Removing OneDrive folders..."
    $folders = @(
        "$env:ProgramData\Microsoft OneDrive",
        "$env:ProgramData\Microsoft\OneDrive",
        "${env:ProgramFiles(x86)}\Microsoft OneDrive",
        "$env:LOCALAPPDATA\Microsoft\OneDrive",
        "$env:APPDATA\Microsoft\OneDrive"
    )
    foreach ($folder in $folders) {
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
        @(
            "AppData\Local\Microsoft\OneDrive",
            "AppData\Roaming\Microsoft\OneDrive",
            "OneDrive"
        ) | ForEach-Object {
            $p = Join-Path $userDir.FullName $_
            if (Test-Path -LiteralPath $p) {
                try {
                    & takeown /F "$p" /R /A /D Y 2>$null
                    & icacls "$p" /reset /T /C /Q 2>$null
                    Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed: $p" -Level "SUCCESS"
                } catch { Write-Log "Could not remove $p" -Level "WARN" }
            }
        }
    }
}

function Remove-OneDriveRegistry {
    Write-Log "Cleaning OneDrive registry..."
    $keysToRemove = @(
        "HKLM:\SOFTWARE\Microsoft\OneDrive",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
    )
    foreach ($key in $keysToRemove) {
        if (Test-Path -LiteralPath $key) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $key" -Level "SUCCESS"
            } catch { Write-Log "Could not remove $key" -Level "WARN" }
        }
    }
    # Remove Run entries (OneDrive startup)
    foreach ($runPath in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run")) {
        if (Test-Path -LiteralPath $runPath) {
            try {
                $props = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
                if ($props) {
                    $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and (($_.Value -match '(?i)onedrive') -or ($_.Name -eq 'OneDrive')) } |
                        ForEach-Object {
                            Remove-ItemProperty -Path $runPath -Name $_.Name -Force -ErrorAction SilentlyContinue
                            Write-Log "Removed Run: $($_.Name)" -Level "SUCCESS"
                        }
                }
            } catch { }
        }
    }
    # Uninstall entries
    Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).DisplayName -match '(?i)onedrive' } |
        ForEach-Object {
            try {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed Uninstall key: $($_.PSPath)" -Level "SUCCESS"
            } catch { Write-Log "Could not remove $($_.PSPath)" -Level "WARN" }
        }
}

function Remove-OneDriveFromExplorer {
    Write-Log "Removing OneDrive from File Explorer (CLSID)..."
    $clsids = @(
        "Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
        "Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
    )
    foreach ($clsid in $clsids) {
        if (Test-Path $clsid) {
            try {
                Remove-Item -Path $clsid -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Removed OneDrive CLSID from Explorer." -Level "SUCCESS"
            } catch { Write-Log "Could not remove CLSID: $_" -Level "WARN" }
        }
    }
    $nameSpace = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
    if (Test-Path $nameSpace) {
        try {
            Remove-Item -Path $nameSpace -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed OneDrive from Desktop NameSpace." -Level "SUCCESS"
        } catch { }
    }
}

function Set-LocalShellFoldersAllUsers {
    Write-Log "Setting local shell folders (Documents, Desktop, Pictures) for all users..."
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') -and (Test-Path "$($_.FullName)\NTUSER.DAT" -ErrorAction SilentlyContinue) }
    foreach ($userDir in $userProfiles) {
        $tempKey = "HKU\TempHive_$($userDir.Name)"
        $userRegBase = "HKCU:"
        $isLoaded = $false
        try {
            if ($userDir.FullName -ne $env:USERPROFILE) {
                $null = & reg load $tempKey "$($userDir.FullName)\NTUSER.DAT" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $isLoaded = $true
                    $userRegBase = "Registry::$tempKey"
                } else { continue }
            }
            $userShell = "$userRegBase\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
            $shellFolders = "$userRegBase\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
            $documents = "$($userDir.FullName)\Documents"
            $desktop = "$($userDir.FullName)\Desktop"
            $pictures = "$($userDir.FullName)\Pictures"
            if (Test-Path $userShell) {
                Set-ItemProperty -Path $userShell -Name "Personal" -Value $documents -Type ExpandString -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $userShell -Name "Desktop" -Value $desktop -Type ExpandString -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $userShell -Name "My Pictures" -Value $pictures -Type ExpandString -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path $shellFolders) {
                Set-ItemProperty -Path $shellFolders -Name "Personal" -Value $documents -Type String -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $shellFolders -Name "Desktop" -Value $desktop -Type String -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $shellFolders -Name "My Pictures" -Value $pictures -Type String -Force -ErrorAction SilentlyContinue
            }
            # Remove OneDrive from this user's Explorer namespace
            $ns = "$userRegBase\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
            if (Test-Path $ns) {
                Remove-Item -Path $ns -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Set local shell folders for: $($userDir.Name)" -Level "SUCCESS"
        } finally {
            if ($isLoaded) {
                Start-Sleep -Milliseconds 500
                & reg unload $tempKey 2>&1 | Out-Null
            }
        }
    }
}

function Block-OneDriveReinstall {
    Write-Log "Blocking OneDrive from reinstalling (Group Policy registry)..."
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
    try {
        if (-not (Test-Path -LiteralPath $policyPath)) {
            New-Item -Path $policyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $policyPath -Name "DisableFileSync" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $policyPath -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -Force
        Write-Log "OneDrive reinstall blocked." -Level "SUCCESS"
    } catch {
        Write-Log "Could not set block policy: $_" -Level "WARN"
    }
}

# ========== MAIN ==========
Write-Log "=========================================="
Write-Log "Remove OneDrive - N-Sight RMM (Google Drive environment)"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME | Log: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "Requires Administrator." -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    Stop-OneDriveProcesses
    Uninstall-OneDriveApp
    Stop-OneDriveProcesses
    Remove-OneDriveAppx
    Remove-OneDriveTasks
    Remove-OneDriveRegistry
    Remove-OneDriveFromExplorer
    Set-LocalShellFoldersAllUsers
    Block-OneDriveReinstall
    Remove-OneDriveFolders

    Write-Log "OneDrive removal and cleanup completed." -Level "SUCCESS"
    Write-Summary -Status "OK" -Message "OneDrive removed. Reboot recommended for Explorer/GP. Use Google Drive for cloud sync."

    if (-not $NoRestart) {
        Write-Log "Scheduling reboot in 60 seconds with user notification..."
        $msg = "OneDrive has been removed. Computer will restart in 1 minute to apply changes. Use Google Drive for cloud storage."
        Start-Process -FilePath "shutdown.exe" -ArgumentList "/r", "/t", "60", "/c", $msg -NoNewWindow
    } else {
        Write-Log "NoRestart: manual reboot recommended."
    }
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Removal failed: $_" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "OneDrive removal failed - $_"
    exit $EXIT_CRITICAL
}
