<#
.SYNOPSIS
    Remove pre-installed McAfee from Windows (new PCs / OEM installs).

.DESCRIPTION
    Uses the official McAfee Consumer Product Removal (MCPR) tool, then cleans
    scheduled tasks, folders, and registry. Optionally sets policy to prevent
    reinstallation. Designed for N-Sight RMM deployment on new machines that
    ship with McAfee.

.PARAMETER Restart
    If set, restart the computer after removal. By default the script does NOT reboot (N-Sight can handle reboot via policy).

.PARAMETER PreventReinstall
    Set registry policy to discourage McAfee from being reinstalled (OEM/Windows Update).

.EXECUTION
    Windows (local):  iex (Get-Content ".\Remove_McAfee.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remove_McAfee.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remove_McAfee.ps1")
.NOTES
    Exit 0 = success; 1002 = failure (N-Sight reserved 1-999).
    Platform: Windows 10/11. Requires Administrator.
#>

[CmdletBinding()]
param(
    [switch]$Restart,
    [switch]$PreventReinstall
)

$ErrorActionPreference = 'Continue'
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Remove_McAfee_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$MCPRUrl = "https://download.mcafee.com/molbin/iss-loc/SupportTools/MCPR/MCPR.exe"
$MCPRPath = "$env:TEMP\MCPR.exe"
$MCPRTimeoutSeconds = 300

$McAfeeFolders = @(
    "$env:ProgramFiles\McAfee",
    "${env:ProgramFiles(x86)}\McAfee",
    "$env:ProgramData\McAfee",
    "$env:ProgramFiles\Common Files\McAfee",
    "${env:ProgramFiles(x86)}\Common Files\McAfee",
    "$env:ProgramFiles\McAfee.com",
    "${env:ProgramFiles(x86)}\McAfee.com"
)

$McAfeeRegistryKeys = @(
    "HKLM:\SOFTWARE\McAfee",
    "HKLM:\SOFTWARE\WOW6432Node\McAfee",
    "HKLM:\SOFTWARE\McAfee.com",
    "HKLM:\SOFTWARE\WOW6432Node\McAfee.com"
)

function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-McAfeeServices {
    Write-Log "Stopping McAfee services..."
    Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '(?i)mcafee|mfe|masvc|mcshield|mcagent' -or $_.DisplayName -match '(?i)mcafee|mfe'
    } | ForEach-Object {
        try {
            if ($_.Status -ne 'Stopped') { Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue }
            & sc.exe config $_.Name start= disabled 2>$null
            Write-Log "Stopped: $($_.Name)"
        } catch { Write-Log "Could not stop $($_.Name)" -Level "WARNING" }
    }
    Start-Sleep -Seconds 2
}

function Stop-McAfeeProcesses {
    Write-Log "Stopping McAfee processes..."
    $patterns = 'mcshield|mfevtp|masvc|mcafee|mfe|mcagent|mfetp|mcuicnt|mctray'
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $patterns } | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
            Write-Log "Stopped process: $($_.ProcessName)"
        } catch {
            try { & taskkill /F /PID $_.Id 2>$null } catch { }
        }
    }
    Start-Sleep -Seconds 2
}

function Invoke-MCPR {
    Write-Log "Downloading MCPR..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $MCPRUrl -OutFile $MCPRPath -UseBasicParsing -TimeoutSec 90
    } catch {
        Write-Log "MCPR download failed: $_" -Level "WARNING"
        return
    }
    if (-not (Test-Path $MCPRPath)) { return }
    Write-Log "Running MCPR /quiet (timeout ${MCPRTimeoutSeconds}s)..."
    $proc = Start-Process -FilePath $MCPRPath -ArgumentList "/quiet" -PassThru -NoNewWindow
    $done = $proc.WaitForExit($MCPRTimeoutSeconds * 1000)
    if (-not $done) {
        Write-Log "MCPR timed out; terminating." -Level "WARNING"
        try { $proc.Kill(); $proc.WaitForExit(5000) } catch { }
    } else {
        Write-Log "MCPR exit code: $($proc.ExitCode)"
    }
    Remove-Item -Path $MCPRPath -Force -ErrorAction SilentlyContinue
}

function Remove-McAfeeTasks {
    Write-Log "Removing McAfee scheduled tasks..."
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -match '(?i)mcafee|mfe' -or $_.TaskPath -match '(?i)mcafee|mfe'
    } | ForEach-Object {
        try {
            Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log "Removed task: $($_.TaskPath)$($_.TaskName)"
        } catch { Write-Log "Could not remove task $($_.TaskName)" -Level "WARNING" }
    }
}

function Remove-McAfeeFolders {
    Write-Log "Removing McAfee folders..."
    foreach ($folder in $McAfeeFolders) {
        if (Test-Path $folder) {
            try {
                & takeown /F "$folder" /R /A /D Y 2>$null
                & icacls "$folder" /reset /T /C /Q 2>$null
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $folder"
            } catch {
                try { & cmd.exe /c "rd /s /q `"$folder`"" 2>$null } catch { }
                if (-not (Test-Path $folder)) { Write-Log "Removed via cmd: $folder" }
            }
        }
    }
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($userDir in $userProfiles) {
        @("AppData\Local\McAfee", "AppData\Roaming\McAfee", "AppData\LocalLow\McAfee") | ForEach-Object {
            $p = Join-Path $userDir.FullName $_
            if (Test-Path $p) {
                try { Remove-Item -Path $p -Recurse -Force -ErrorAction Stop; Write-Log "Removed: $p" } catch { }
            }
        }
    }
    Get-Item -Path "$env:TEMP\McAfee*", "$env:TEMP\mfe*" -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Remove-McAfeeRegistry {
    Write-Log "Cleaning McAfee registry..."
    foreach ($key in $McAfeeRegistryKeys) {
        if (Test-Path $key) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $key"
            } catch { Write-Log "Could not remove $key" -Level "WARNING" }
        }
    }
    $runKeys = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run")
    foreach ($runKey in $runKeys) {
        if (-not (Test-Path $runKey)) { continue }
        try {
            (Get-ItemProperty -Path $runKey -ErrorAction Stop).PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS' -and $_.Name -match '(?i)mcafee|mfe' } |
                ForEach-Object {
                    Remove-ItemProperty -Path $runKey -Name $_.Name -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed Run: $($_.Name)"
                }
        } catch { }
    }
    foreach ($key in @("HKCU:\SOFTWARE\McAfee", "HKCU:\SOFTWARE\McAfee.com")) {
        if (Test-Path $key) {
            try { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue; Write-Log "Removed: $key" } catch { }
        }
    }
}

function Set-PreventReinstall {
    if (-not $PreventReinstall) { return }
    Write-Log "Setting policy to prevent McAfee reinstall..."
    $path = "HKLM:\SOFTWARE\Policies\McAfee"
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "BlockInstall" -Value 1 -Type DWord -Force
        Write-Log "Policy set: BlockInstall = 1"
    } catch { Write-Log "Could not set policy" -Level "WARNING" }
}

# ========== MAIN ==========
Write-Log "Remove McAfee (pre-installed / OEM) - N-Sight"
Write-Log "Computer: $env:COMPUTERNAME | Log: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log "Requires Administrator." -Level "ERROR"
    exit 1002
}

try {
    Stop-McAfeeServices
    Stop-McAfeeProcesses
    Invoke-MCPR
    Stop-McAfeeProcesses
    Remove-McAfeeTasks
    Remove-McAfeeFolders
    Remove-McAfeeRegistry
    Set-PreventReinstall

    Write-Log "McAfee removal completed. Log: $LogFile"
    Write-Host "SUCCESS: McAfee removed. Reboot recommended." -ForegroundColor Green

    if ($Restart) {
        Write-Log "Restarting in 30 seconds..."
        Write-Host "Restarting in 30 seconds (Ctrl+C to cancel)." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        Restart-Computer -Force
    } else {
        Write-Log "Skipping reboot (default). Manual reboot recommended if needed."
    }
    exit 0
}
catch {
    Write-Log "Removal failed: $_" -Level "ERROR"
    Write-Host "ERROR: $_. Check log: $LogFile" -ForegroundColor Red
    exit 1002
}
