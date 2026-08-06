#Requires -Version 5.1
# Remove_Tailscale.ps1 - Remove Tailscale VPN (silent, N-Sight RMM). Same folder: Remove_Tailscale.cmd runs this via powershell -File.
# Stops services and processes, winget or registry uninstall, firewall and QoS cleanup, Program Files, ProgramData, user AppData.
# Idempotent. Administrator required. Exits 0 success, 1001 warning, 1002 critical. Vendor KB: tailscale dot com slash kb slash 1189.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ScriptName = 'Remove_Tailscale'
$ScriptVersion = '1.0'
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

$TailscaleFolders = @(
    "${env:ProgramFiles}\Tailscale",
    "${env:ProgramFiles(x86)}\Tailscale IPN"
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

function Test-TailscalePresent {
    $paths = @(
        "${env:ProgramFiles}\Tailscale\tailscale.exe",
        "${env:ProgramFiles}\Tailscale\tailscaled.exe",
        "${env:ProgramFiles}\Tailscale\tailscale-ipn.exe",
        "${env:ProgramFiles(x86)}\Tailscale IPN\tailscale-ipn.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $true }
    }
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Tailscale*' }
    if ($svc) { return $true }
    $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Tailscale*' }
    return [bool]$reg
}

function Wait-WindowsInstaller {
    param([int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $mutex = $null
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
            $mutex.Close()
            Write-Log 'Windows Installer busy; waiting 5s...' -Level 'INFO'
            Start-Sleep -Seconds 5
        }
        catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return
        }
        catch { return }
        finally {
            if ($mutex) { try { $mutex.Dispose() } catch { } }
        }
    }
    Write-Log "Windows Installer still busy after ${TimeoutSeconds}s; proceeding" -Level 'WARN'
}

function Stop-TailscaleServices {
    Write-Log 'Stopping Tailscale services...'
    Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Tailscale*' } | ForEach-Object {
        try {
            if ($_.Status -ne 'Stopped') { Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue }
            & sc.exe config $_.Name start= disabled 2>$null
            Write-Log "Stopped: $($_.Name)" -Level 'SUCCESS'
        }
        catch { Write-Log "Could not stop $($_.Name): $_" -Level 'WARN' }
    }
    Start-Sleep -Seconds 2
}

function Stop-TailscaleProcesses {
    param([int]$MaxRetries = 4)
    $names = @('tailscale', 'tailscaled', 'tailscale-ipn')
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })
        if (-not $procs -or $procs.Count -eq 0) {
            if ($attempt -gt 1) { Write-Log 'Tailscale processes ended.' -Level 'SUCCESS' }
            break
        }
        Write-Log "Stopping Tailscale processes (attempt $attempt/$MaxRetries)..."
        foreach ($p in $procs) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Log "Stopped: $($p.ProcessName) (PID $($p.Id))" -Level 'SUCCESS'
            }
            catch {
                try { & taskkill /F /PID $p.Id 2>$null }
                catch { Write-Log "Could not stop PID $($p.Id)" -Level 'WARN' }
            }
        }
        Start-Sleep -Seconds 2
        foreach ($n in $names) { & taskkill /F /IM "$n.exe" /T 2>$null }
        Start-Sleep -Seconds 1
    }
}

function Uninstall-TailscaleViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Log 'winget not found' -Level 'WARN'; return $false }
    try {
        $null = & winget --version 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    catch { return $false }

    Write-Log 'Trying winget uninstall Tailscale.Tailscale...'
    try {
        $out = & winget uninstall --id Tailscale.Tailscale --silent --accept-source-agreements 2>&1
        $ok = $LASTEXITCODE -eq 0
        if ($ok) {
            Write-Log 'winget uninstall succeeded' -Level 'SUCCESS'
            return $true
        }
        Write-Log "winget uninstall exit $LASTEXITCODE : $out" -Level 'WARN'
    }
    catch {
        Write-Log "winget uninstall failed: $_" -Level 'WARN'
    }
    return $false
}

function Uninstall-TailscaleViaRegistry {
    $script:ran = $false
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Wait-WindowsInstaller
    foreach ($keyPath in $uninstallKeys) {
        Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like '*Tailscale*'
        } | ForEach-Object {
            $uninstallString = $_.UninstallString
            $quiet = $_.QuietUninstallString
            if ($quiet) { $cmd = $quiet } else { $cmd = $uninstallString }
            if (-not $cmd) { return }
            $cmd = $cmd.Trim()
            if ($cmd -match 'msiexec' -and $cmd -notmatch '/[qxn]') { $cmd = "$cmd /qn /norestart" }
            if ($cmd -match 'msiexec.*/[xXI]') { if ($cmd -notmatch '/qn') { $cmd = "$cmd /qn /norestart" } }
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
                    if (-not $argList) {
                        $argList = @()
                    }
                    else {
                        $argList = @($argList -split '\s+' | ForEach-Object { if ($_) { $_ } })
                    }
                    $proc = Start-Process -FilePath $exePath -ArgumentList $argList -Wait -PassThru -NoNewWindow
                    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                    $script:ran = $true
                }
                else {
                    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Wait -PassThru -NoNewWindow
                    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                    $script:ran = $true
                }
            }
            catch {
                Write-Log "Uninstall failed: $_" -Level 'WARN'
            }
            Start-Sleep -Seconds 5
        }
    }
    if (-not $script:ran) { Write-Log 'No Tailscale uninstaller found in registry; continuing with cleanup.' -Level 'INFO' }
}

function Remove-TailscaleNetworkTweaks {
    Write-Log 'Removing Tailscale firewall rules (if present)...'
    foreach ($name in @('TailscaleIn', 'TailscaleOut')) {
        Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($name in @('Tailscale Priority', 'Tailscaled Priority')) {
        Remove-NetQosPolicy -Name $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
}

function Remove-TailscaleFolders {
    Write-Log 'Removing Tailscale folders...'
    $dq = [char]34
    foreach ($folder in $TailscaleFolders) {
        if (Test-Path -LiteralPath $folder) {
            try {
                & takeown /F "$folder" /R /A /D Y 2>$null
                & icacls "$folder" /grant Administrators:F /T /C /Q 2>$null
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $folder" -Level 'SUCCESS'
            }
            catch {
                $rdCmd = 'rd /s /q ' + $dq + ($folder.Replace($dq, '')) + $dq
                try { & cmd.exe /c $rdCmd 2>$null } catch { }
                if (-not (Test-Path -LiteralPath $folder)) { Write-Log "Removed via cmd: $folder" -Level 'SUCCESS' }
                else { Write-Log "Could not fully remove $folder" -Level 'WARN' }
            }
        }
    }
    if (Test-Path -LiteralPath "$env:ProgramData\Tailscale") {
        try {
            Remove-Item -Path "$env:ProgramData\Tailscale" -Recurse -Force -ErrorAction Stop
            Write-Log "Removed: $env:ProgramData\Tailscale" -Level 'SUCCESS'
        }
        catch { Write-Log "ProgramData\Tailscale cleanup: $_" -Level 'WARN' }
    }
    $userProfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($userDir in $userProfiles) {
        foreach ($rel in @('AppData\Local\Tailscale', 'AppData\Roaming\Tailscale')) {
            $p = Join-Path $userDir.FullName $rel
            if (Test-Path -LiteralPath $p) {
                try {
                    Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed: $p" -Level 'SUCCESS'
                }
                catch { Write-Log "Could not remove $p" -Level 'WARN' }
            }
        }
    }
}

function Remove-TailscaleRegistry {
    Write-Log 'Cleaning Tailscale uninstall registry keys...'
    Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).DisplayName -like '*Tailscale*' } |
        ForEach-Object {
            try {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $($_.PSPath)" -Level 'SUCCESS'
            }
            catch { Write-Log "Could not remove $($_.PSPath)" -Level 'WARN' }
        }
    foreach ($key in @('HKLM:\SOFTWARE\Tailscale', 'HKLM:\SOFTWARE\WOW6432Node\Tailscale')) {
        if (Test-Path -LiteralPath $key) {
            try {
                Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $key" -Level 'SUCCESS'
            }
            catch { Write-Log "Could not remove $key" -Level 'WARN' }
        }
    }
}

function Remove-OrphanTailscaleService {
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Tailscale*' }
    foreach ($s in $svc) {
        try {
            & sc.exe delete $s.Name 2>$null
            Write-Log "Deleted service: $($s.Name)" -Level 'SUCCESS'
        }
        catch { Write-Log "Could not delete service $($s.Name)" -Level 'WARN' }
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
    if (-not (Test-TailscalePresent)) {
        Write-Log 'Tailscale does not appear to be installed. Nothing to do.' -Level 'SUCCESS'
        Write-Summary -Status 'OK' -Message 'Tailscale not installed (already removed).'
        exit $EXIT_SUCCESS
    }

    Stop-TailscaleServices
    Stop-TailscaleProcesses
    $wingetOk = Uninstall-TailscaleViaWinget
    if (-not $wingetOk) {
        Uninstall-TailscaleViaRegistry
    }
    Stop-TailscaleProcesses
    Stop-TailscaleServices
    Remove-TailscaleNetworkTweaks
    Remove-TailscaleFolders
    Remove-OrphanTailscaleService
    Remove-TailscaleRegistry

    Start-Sleep -Seconds 2
    if (Test-TailscalePresent) {
        Write-Log 'Tailscale components may still be present after removal steps.' -Level 'ERROR'
        Write-Summary -Status 'CRITICAL' -Message "Tailscale removal incomplete. See log: $LogFile"
        exit $EXIT_CRITICAL
    }

    Write-Log 'Tailscale removed successfully.' -Level 'SUCCESS'
    Write-Summary -Status 'OK' -Message "Tailscale removed from $env:COMPUTERNAME."
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Removal failed: $_" -Level 'ERROR'
    Write-Summary -Status 'CRITICAL' -Message "Tailscale removal failed - $_"
    exit $EXIT_CRITICAL
}
