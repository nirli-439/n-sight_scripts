#Requires -Version 5.1
# Remove_Twingate.ps1 - Remove Twingate client (silent, N-Sight RMM). Same folder: Remove_Twingate.cmd runs this via powershell -File.
# Stops services and processes (including WebView2 children), registry uninstaller or bundled uninstall EXE, Appx, scheduled tasks, folders, registry.
# Idempotent. Administrator required. Exits 0 success, 1001 warning, 1002 critical.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ScriptName = 'Remove_Twingate'
$ScriptVersion = '1.0'
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

$TwingateFolders = @(
    "$env:ProgramFiles\Twingate",
    "${env:ProgramFiles(x86)}\Twingate",
    "$env:ProgramData\Twingate"
)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Summary {
    param([string]$Status, [string]$Message)
    Write-Host ''
    Write-Host "${Status}: $Message"
}

function Stop-TwingateServices {
    Write-Log 'Stopping Twingate services...'
    Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '*Twingate*' -or $_.DisplayName -like '*Twingate*'
    } | ForEach-Object {
        try {
            if ($_.Status -ne 'Stopped') { Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue }
            & sc.exe config $_.Name start= disabled 2>$null
            Write-Log "Stopped: $($_.Name)" -Level 'SUCCESS'
        }
        catch { Write-Log "Could not stop $($_.Name)" -Level 'WARN' }
    }
    Start-Sleep -Seconds 2
}

function Stop-TwingateProcesses {
    param([int]$MaxRetries = 5)
    $patterns = 'twingate'
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $patterns })

        try {
            $webViewWmi = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match $patterns }
            foreach ($wmiProc in $webViewWmi) {
                $wvProc = Get-Process -Id $wmiProc.ProcessId -ErrorAction SilentlyContinue
                if ($wvProc) { $procs += $wvProc }
            }
        }
        catch { }

        if ($procs.Count -gt 0) { $procs = $procs | Sort-Object -Property Id -Unique }

        if (-not $procs -or $procs.Count -eq 0) {
            if ($attempt -gt 1) { Write-Log "All Twingate processes ended after $attempt attempts." -Level 'SUCCESS' }
            break
        }
        Write-Log "Stopping Twingate processes (attempt $attempt/$MaxRetries)..."
        foreach ($p in $procs) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Log "Stopped process: $($p.ProcessName) (PID $($p.Id))" -Level 'SUCCESS'
            }
            catch {
                try {
                    & taskkill /F /PID $p.Id 2>$null
                    Write-Log "Killed via taskkill: $($p.ProcessName) (PID $($p.Id))" -Level 'SUCCESS'
                }
                catch { Write-Log "Could not stop PID $($p.Id)" -Level 'WARN' }
            }
        }
        Start-Sleep -Seconds 2
        & taskkill /F /T /IM Twingate.exe 2>$null
        Start-Sleep -Seconds 2
    }
    if (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $patterns }) {
        Write-Log "Some Twingate processes may still be running after $MaxRetries attempts." -Level 'WARN'
    }
}

function Uninstall-Twingate {
    $script:uninstallRan = $false
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($keyPath in $uninstallKeys) {
        Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like '*Twingate*'
        } | ForEach-Object {
            $uninstallString = $_.UninstallString
            $quiet = $_.QuietUninstallString
            if ($quiet) { $cmd = $quiet } else { $cmd = $uninstallString }
            if (-not $cmd) { return }
            $cmd = $cmd.Trim()
            if ($cmd -match 'msiexec' -and $cmd -notmatch '/[qxn]') { $cmd = "$cmd /qn" }
            if ($cmd -match 'msiexec.*/x') { $cmd = $cmd -replace '\s*$', ' /qn' }
            Write-Log "Running uninstall: $cmd"
            try {
                $exePath = $null
                $argList = $null
                if ($cmd -match '^"([^"]+)"\s*(.*)$') {
                    $exePath = $matches[1].Trim()
                    $argList = $matches[2].Trim()
                }
                elseif ($cmd -match '^(.+?\.exe)(?:\s+(.*))?$') {
                    $exePath = $matches[1].Trim()
                    $argList = $matches[2].Trim()
                }
                if ($exePath -and (Test-Path -LiteralPath $exePath -ErrorAction SilentlyContinue)) {
                    if (-not $argList) { $argList = @() } else { $argList = @($argList -split '\s+' | ForEach-Object { if ($_) { $_ } }) }
                    $proc = Start-Process -FilePath $exePath -ArgumentList $argList -Wait -PassThru -NoNewWindow
                    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                    $script:uninstallRan = $true
                }
                else {
                    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Wait -PassThru -NoNewWindow
                    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                    $script:uninstallRan = $true
                }
            }
            catch {
                Write-Log "Uninstall failed: $_" -Level 'WARN'
            }
            Start-Sleep -Seconds 5
        }
    }
    $exePaths = @(
        "$env:ProgramFiles\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
    )
    foreach ($path in $exePaths) {
        if (-not $script:uninstallRan -and (Test-Path -LiteralPath $path)) {
            $dir = Split-Path -Parent $path
            $uninstallExe = Join-Path $dir 'Uninstall Twingate.exe'
            if (Test-Path -LiteralPath $uninstallExe) {
                Write-Log "Running: $uninstallExe /qn REMOVE=ALL"
                try {
                    $proc = Start-Process -FilePath $uninstallExe -ArgumentList '/qn', 'REMOVE=ALL' -Wait -PassThru -NoNewWindow
                    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                    $script:uninstallRan = $true
                }
                catch { Write-Log "Uninstall failed: $_" -Level 'WARN' }
                Start-Sleep -Seconds 5
            }
        }
    }
    Get-AppxPackage -AllUsers -Name '*Twingate*' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "Removing Appx: $($_.Name)"
        try {
            Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
            Write-Log "Removed Appx: $($_.Name)" -Level 'SUCCESS'
            $script:uninstallRan = $true
        }
        catch { Write-Log "Appx remove failed: $_" -Level 'WARN' }
        Start-Sleep -Seconds 3
    }
    if (-not $script:uninstallRan) { Write-Log 'No Twingate uninstaller found; continuing with cleanup.' -Level 'INFO' }
}

function Remove-TwingateTasks {
    Write-Log 'Removing Twingate scheduled tasks...'
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like '*Twingate*' -or $_.TaskPath -like '*Twingate*'
    } | ForEach-Object {
        try {
            Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log "Removed task: $($_.TaskPath)$($_.TaskName)" -Level 'SUCCESS'
        }
        catch { Write-Log "Could not remove task $($_.TaskName)" -Level 'WARN' }
    }
}

function Remove-TwingateFolders {
    Write-Log 'Removing Twingate folders...'
    $dq = [char]34
    foreach ($folder in $TwingateFolders) {
        if (Test-Path -LiteralPath $folder) {
            try {
                & takeown /F "$folder" /R /A /D Y 2>$null
                & icacls "$folder" /reset /T /C /Q 2>$null
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $folder" -Level 'SUCCESS'
            }
            catch {
                $rdCmd = 'rd /s /q ' + $dq + ($folder.Replace($dq, '')) + $dq
                try { & cmd.exe /c $rdCmd 2>$null } catch { }
                if (-not (Test-Path -LiteralPath $folder)) { Write-Log "Removed via cmd: $folder" -Level 'SUCCESS' }
            }
        }
    }
    $userProfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($userDir in $userProfiles) {
        @('AppData\Local', 'AppData\Local\Programs', 'AppData\Roaming', 'AppData\LocalLow') | ForEach-Object {
            $basePath = Join-Path $userDir.FullName $_
            if (Test-Path -LiteralPath $basePath) {
                Get-ChildItem -Path $basePath -Filter '*Twingate*' -ErrorAction SilentlyContinue | ForEach-Object {
                    $p = $_.FullName
                    try {
                        Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
                        Write-Log "Removed: $p" -Level 'SUCCESS'
                    }
                    catch {
                        if (Test-Path -LiteralPath $p -PathType Container) {
                            $rdCmd2 = 'rd /s /q ' + $dq + ($p.Replace($dq, '')) + $dq
                            try { & cmd.exe /c $rdCmd2 2>$null } catch { }
                        }
                    }
                }
            }
        }
    }
    Get-Item -Path "$env:TEMP\Twingate*" -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Remove-TwingateRegistry {
    Write-Log 'Cleaning Twingate registry...'
    $keysToRemove = @(
        'HKLM:\SOFTWARE\Twingate',
        'HKLM:\SOFTWARE\WOW6432Node\Twingate',
        'HKCU:\SOFTWARE\Twingate'
    )
    foreach ($key in $keysToRemove) {
        if (Test-Path -LiteralPath $key) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $key" -Level 'SUCCESS'
            }
            catch { Write-Log "Could not remove $key" -Level 'WARN' }
        }
    }
    Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).DisplayName -like '*Twingate*' } |
        ForEach-Object {
            try {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed Uninstall key: $($_.PSPath)" -Level 'SUCCESS'
            }
            catch { Write-Log "Could not remove $($_.PSPath)" -Level 'WARN' }
        }
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($runKey in $runKeys) {
        if (-not (Test-Path -LiteralPath $runKey)) { continue }
        try {
            (Get-ItemProperty -Path $runKey -ErrorAction Stop).PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS' -and $_.Name -like '*Twingate*' } |
                ForEach-Object {
                    Remove-ItemProperty -Path $runKey -Name $_.Name -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed Run: $($_.Name)" -Level 'SUCCESS'
                }
        }
        catch { }
    }
}

Write-Log '=========================================='
Write-Log "$ScriptName v$ScriptVersion | N-Sight RMM"
Write-Log '=========================================='
Write-Log "Computer: $env:COMPUTERNAME | Log: $LogFile"

if (-not (Test-IsAdmin)) {
    Write-Log 'Requires Administrator.' -Level 'ERROR'
    Write-Summary -Status 'CRITICAL' -Message 'Administrator privileges required'
    exit $EXIT_CRITICAL
}

try {
    Stop-TwingateServices
    Stop-TwingateProcesses
    Uninstall-Twingate
    Stop-TwingateProcesses
    Stop-TwingateServices
    Remove-TwingateTasks
    Remove-TwingateFolders
    Remove-TwingateRegistry

    Write-Log 'Twingate removal and cleanup completed.' -Level 'SUCCESS'
    Write-Summary -Status 'OK' -Message 'Twingate stopped and removed.'
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Removal failed: $_" -Level 'ERROR'
    Write-Summary -Status 'CRITICAL' -Message "Twingate removal failed - $_"
    exit $EXIT_CRITICAL
}
