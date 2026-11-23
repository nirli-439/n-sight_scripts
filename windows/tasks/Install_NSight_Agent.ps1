<#
.SYNOPSIS
    Silent install of the N-able N-Sight Windows agent from a site installer the technician downloaded.

.DESCRIPTION
    Windows counterpart of macos/tasks/Install_NSight_Agent_mac.sh. Dashboard download links
    expire, so the normal path is: N-Sight dashboard > Add > Download Agent > Windows, save to
    Downloads, then run this (or the onboarding menu, which calls this).

    Installer source, first match wins:
      1. -Path <file>                     (EXE, MSI or ZIP)
      2. $env:NSIGHT_AGENT_PATH
      3. newest *AGENT*.exe / .msi / .zip in any C:\Users\*\Downloads or C:\Download
      4. $env:NSIGHT_AGENT_URL            (download fallback)

    Idempotent: exits OK when the "Advanced Monitoring Agent" service is already running.
    EXE runs with /S, MSI with msiexec /qn. Verifies the service is running afterwards.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_NSight_Agent.ps1" [-Path C:\Users\me\Downloads\AGENT.EXE]
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_NSight_Agent.ps1")

.NOTES
    Version: 1.0
    Requires: Administrator
    Platform: Windows 10/11

.OUTPUTS
    Exit 0    = Installed now, or already installed and running
    Exit 1001 = Installer finished but the agent service is not running yet
    Exit 1002 = No installer found, install failed, or not Administrator
#>

#Requires -Version 5.1
[CmdletBinding()]
param([string]$Path)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ScriptName = 'Install_NSight_Agent'
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002
$InstallTimeoutSec = 900
$VerifyTimeoutSec = 180

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Finish {
    param([int]$Code, [string]$Message)
    Write-Log $Message
    Write-Host $Message
    exit $Code
}

function Get-AgentService {
    # N-Sight RMM: service "Advanced Monitoring Agent" (winagent.exe). Older/other names kept as fallback.
    $names = @('Advanced Monitoring Agent', 'WindowsAgent', 'MSPAgent', 'N-able Agent', 'RMMAgent')
    foreach ($n in $names) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { return $s }
    }
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Advanced Monitoring Agent' } |
        Select-Object -First 1
}

function Test-AgentRunning {
    $s = Get-AgentService
    return [bool]($s -and $s.Status -eq 'Running')
}

function Find-Installer {
    if ($Path) { return $Path }
    if ($env:NSIGHT_AGENT_PATH) { return $env:NSIGHT_AGENT_PATH }
    $dirs = @('C:\Download')
    $dirs += Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'Downloads' }
    $found = foreach ($d in $dirs) {
        if (Test-Path -LiteralPath $d) {
            Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'AGENT' -and
                    $_.Extension -match '^\.(exe|msi|zip)$' -and
                    $_.Name -notmatch 'OSX|LINUX|MAC|setupdownloader|bitdefender'
                }
        }
    }
    $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Invoke-Installer {
    param([string]$File)
    $ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
    if ($ext -eq '.msi') {
        $msiLog = Join-Path $LogDir "${ScriptName}_msi.log"
        $exe = "$env:SystemRoot\System32\msiexec.exe"
        $argList = @('/i', "`"$File`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"")
    } else {
        $exe = $File
        $argList = @('/S')
    }
    Write-Log "Running: $exe $($argList -join ' ')"
    $p = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden
    $null = $p.Handle   # keeps ExitCode readable after exit
    if (-not $p.WaitForExit($InstallTimeoutSec * 1000)) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null
        Write-Log "Installer did not finish in ${InstallTimeoutSec}s - killed" 'WARN'
        return $null
    }
    Write-Log "Installer exit code: $($p.ExitCode)"
    return $p.ExitCode
}

# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Finish $EXIT_CRITICAL 'CRITICAL: Run as Administrator.' }

Write-Log "$ScriptName on $env:COMPUTERNAME"

if (Test-AgentRunning) {
    Finish $EXIT_SUCCESS "OK: N-Sight agent already installed and running ($((Get-AgentService).Name)) - nothing to do"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$work = Join-Path $env:TEMP ("nsight_agent_" + [IO.Path]::GetRandomFileName())
New-Item -Path $work -ItemType Directory -Force | Out-Null

try {
    # 1. Locate (or download) the installer
    $src = Find-Installer
    if (-not $src -and $env:NSIGHT_AGENT_URL) {
        $src = Join-Path $work 'agent_download.exe'
        Write-Log "Downloading $env:NSIGHT_AGENT_URL"
        try {
            Invoke-WebRequest -Uri $env:NSIGHT_AGENT_URL -OutFile $src -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
            if (((Get-Content -LiteralPath $src -Encoding Byte -TotalCount 2) -join ",") -eq "208,207") {
                Rename-Item -LiteralPath $src -NewName 'agent_download.msi'; $src = Join-Path $work 'agent_download.msi'
            }
        } catch { Finish $EXIT_CRITICAL "CRITICAL: download failed ($($_.Exception.Message)) - dashboard links expire; download the agent manually" }
    }
    if (-not $src) {
        Finish $EXIT_CRITICAL 'CRITICAL: no agent installer found - download it from N-Sight dashboard (Download Agent > Windows) to Downloads, then re-run'
    }
    if (-not (Test-Path -LiteralPath $src)) { Finish $EXIT_CRITICAL "CRITICAL: installer not found: $src" }
    Write-Log "Using installer: $src"
    Unblock-File -LiteralPath $src -ErrorAction SilentlyContinue

    # 2. ZIP -> find the EXE/MSI inside
    if ($src -match '\.zip$') {
        $x = Join-Path $work 'x'
        Expand-Archive -LiteralPath $src -DestinationPath $x -Force -ErrorAction Stop
        $inner = Get-ChildItem -LiteralPath $x -Recurse -File |
            Where-Object { $_.Extension -match '^\.(exe|msi)$' } | Select-Object -First 1
        if (-not $inner) { Finish $EXIT_CRITICAL 'CRITICAL: ZIP has no EXE/MSI inside' }
        $src = $inner.FullName
        Write-Log "Extracted: $src"
    }

    # 3. Signature: log it; only refuse a file that was tampered with
    $sig = Get-AuthenticodeSignature -LiteralPath $src -ErrorAction SilentlyContinue
    Write-Log "Signature: $($sig.Status) / $($sig.SignerCertificate.Subject)"
    if ($sig -and $sig.Status -eq 'HashMismatch') { Finish $EXIT_CRITICAL 'CRITICAL: installer signature hash mismatch - file is corrupt or modified' }

    # 4. Install
    $code = Invoke-Installer -File $src

    # 5. Verify
    $waited = 0
    while (-not (Test-AgentRunning) -and $waited -lt $VerifyTimeoutSec) {
        $svc = Get-AgentService
        if ($svc -and $svc.Status -eq 'Stopped') { Start-Service -InputObject $svc -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 5; $waited += 5
    }
    if (Test-AgentRunning) {
        Finish $EXIT_SUCCESS "OK: N-Sight agent installed and running ($((Get-AgentService).Name)) in ${waited}s"
    }
    if ($null -ne $code -and $code -ne 0 -and $code -ne 3010) {
        Finish $EXIT_CRITICAL "CRITICAL: installer exit $code and agent service not running - see $LogFile"
    }
    Finish $EXIT_WARNING "WARNING: installer finished but agent service not running after ${VerifyTimeoutSec}s - check dashboard registration"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
