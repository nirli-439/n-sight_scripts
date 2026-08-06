<#
.SYNOPSIS
    Remediates Adobe Creative Cloud installer or app stuck on infinite loading.

.DESCRIPTION
    Stops Adobe-related processes and services, then renames (backs up) common OOBE
    and updater cache folders so a fresh install or Creative Cloud Desktop can
    rebuild them. Use when the Creative Cloud installer or login screen spins forever.

    Does not download installers or run Adobe Cleaner; run this, reboot if prompted,
    then retry installation from Adobe’s offline installer if needed.
    To install the Creative Cloud desktop app afterward, run Install_AdobeCreativeCloud.ps1 (elevated).

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Fix_AdobeCreativeCloud_Loading.ps1"
    Windows (repo):   Prefer commit-pinned raw URL (main branch CDN can be stale), e.g.
                      iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/<COMMIT_SHA>/windows/tasks/Fix_AdobeCreativeCloud_Loading.ps1")

.PARAMETER SkipCacheRename
    Only stop processes and services; do not rename cache folders.

.NOTES
    Requires: Administrator privileges
    Platform: Windows 10/11
    Exit 0 = Completed (review log for warnings)
    Exit 1 = Fatal error
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipCacheRename
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Bump when behavior changes (shown in log; confirms iex downloaded current script, not cached /main/).
$ScriptRevision = "5-service-stop-fallback"
$ScriptName = "Fix_AdobeCreativeCloud_Loading"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
}
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Stop-AdobeProcesses {
    $names = @(
        "Creative Cloud",
        "Adobe Desktop Service",
        "AdobeIPCBroker",
        "CoreSync",
        "CCXProcess",
        "Adobe CEF Helper",
        "Adobe Crash Processor",
        "Set-up",
        "Adobe Installer",
        "AdobeGCInvoker",
        "Adobe Collaboration Synchronizer",
        "AdobeUpdateService"
    )
    # armsvc: stop via AdobeARMservice (services stopped before processes)
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            $proc = $_
            $label = "$($proc.ProcessName) (PID $($proc.Id))"
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Log "Stopped process: $label"
            }
            catch {
                Write-Log "Could not stop $label : $($_.Exception.Message)" "WARN"
            }
        }
    }
}

function Stop-OneAdobeService {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$LogLabel
    )
    $firstErr = $null
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        Write-Log "Stopped service: $LogLabel"
        return
    }
    catch {
        $firstErr = $_.Exception.Message
    }

    try {
        $sc = Join-Path $env:SystemRoot "System32\sc.exe"
        $p = Start-Process -FilePath $sc -ArgumentList @("stop", $ServiceName) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        $again = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($again -and $again.Status -ne "Running") {
            Write-Log "Stopped service (sc.exe): $LogLabel"
            return
        }
    }
    catch { }

    try {
        $w = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($ServiceName.Replace("'","''"))'" -ErrorAction Stop
        if ($w) {
            $r = Invoke-CimMethod -InputObject $w -MethodName StopService -ErrorAction Stop
            if ($r.ReturnValue -eq 0) {
                Write-Log "Stopped service (WMI): $LogLabel"
                return
            }
        }
    }
    catch { }

    if ($ServiceName -eq "AdobeARMservice") {
        Write-Log "Could not stop $LogLabel ($firstErr). Skipping — Acrobat updater service; Creative Cloud steps continue." "INFO"
    }
    else {
        Write-Log "Could not stop service $LogLabel : $firstErr" "WARN"
    }
}

function Stop-AdobeServices {
    $svcs = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "Adobe" -or $_.DisplayName -match "Adobe"
    }
    foreach ($s in $svcs) {
        if ($s.Status -ne "Running") { continue }
        $svcLabel = "$($s.DisplayName) ($($s.Name))"
        Stop-OneAdobeService -ServiceName $s.Name -LogLabel $svcLabel
    }
}

function Rename-AdobeCacheFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Skip (not found): $Label → $Path" "INFO"
        return
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $leaf = Split-Path -Leaf $Path
    $newName = "${leaf}_bak_${stamp}"
    try {
        Rename-Item -LiteralPath $Path -NewName $newName -Force -ErrorAction Stop
        Write-Log "Renamed: $Path → $(Join-Path (Split-Path -Parent $Path) $newName) ($Label)"
    }
    catch {
        Write-Log "Rename failed ($Label): $($_.Exception.Message)" "WARN"
    }
}

Write-Log "Starting $ScriptName rev=$ScriptRevision (SkipCacheRename=$SkipCacheRename)"

try {
    # Stop services before processes so service-hosted EXEs (e.g. armsvc / Adobe ARM) exit cleanly
    Write-Log "Stopping Adobe-related services..."
    Stop-AdobeServices
    Start-Sleep -Seconds 2

    Write-Log "Stopping Adobe-related processes..."
    Stop-AdobeProcesses
    Start-Sleep -Seconds 1

    if (-not $SkipCacheRename) {
        Write-Log "Backing up OOBE / updater caches (folders recreated on next Adobe run)..."
        $folders = @(
            @{ Path = "$env:ProgramData\Adobe\OOBE"; Label = "ProgramData OOBE" },
            @{ Path = "$env:LOCALAPPDATA\Adobe\OOBE"; Label = "User OOBE" },
            @{ Path = "$env:LOCALAPPDATA\Adobe\AAMUpdater"; Label = "AAMUpdater" },
            @{ Path = "$env:ProgramData\Adobe\SLStore"; Label = "SLStore" },
            @{ Path = "$env:LOCALAPPDATA\Adobe\Creative Cloud Libraries"; Label = "CCL Libraries cache" }
        )
        foreach ($f in $folders) {
            Rename-AdobeCacheFolder -Path $f.Path -Label $f.Label
        }
    }
    else {
        Write-Log "SkipCacheRename: no folders renamed."
    }

    Write-Log "Done. Reboot, then run the Creative Cloud installer again (prefer Adobe offline installer if web installer still hangs)." "SUCCESS"
    Write-Log "If issues persist, use Adobe’s Creative Cloud Cleaner Tool and reinstall."
    exit 0
}
catch {
    Write-Log "Fatal: $($_.Exception.Message)" "ERROR"
    exit 1
}
