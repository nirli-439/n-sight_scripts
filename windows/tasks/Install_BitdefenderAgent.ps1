<#
.SYNOPSIS
    Download and silently install the Bitdefender GravityZone Windows agent (setup downloader).

.DESCRIPTION
    Downloads the organization-specific setup downloader EXE from GravityZone to %TEMP% and runs:
    /bdparams /silent

    N-Sight "Deploy from URL" (same behavior): use the Source URL below, download to %TEMP%,
    Run File after download, parameters: /bdparams /silent

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_BitdefenderAgent.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_BitdefenderAgent.ps1")

.NOTES
    Requires: Administrator privileges
    Exit: 0 = OK, 1002 = Critical

    If the setup downloader exits with code 3, the install did not complete. Common causes are
    network or relay access (endpoint must reach your GravityZone relay / Control Center;
    firewalls often need rules such as TCP 7074 for relay communication — see Bitdefender
    GravityZone deployment and firewall documentation for your topology).

.OUTPUTS
    Exit 0    = Success (or reboot may be pending)
    Exit 1002 = Critical/Error
#>

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ScriptName = "Install_BitdefenderAgent"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$Script:ExitCode = $EXIT_CRITICAL

# Organization package URL (GravityZone setup downloader)
$SetupUrl = "https://cloudgz.gravityzone.bitdefender.com/Packages/BSTWIN/0/setupdownloader_[aHR0cHM6Ly9jbG91ZGd6LWVjcy5ncmF2aXR5em9uZS5iaXRkZWZlbmRlci5jb20vUGFja2FnZXMvQlNUV0lOLzAvaldldkFaL2luc3RhbGxlci54bWw-bGFuZz1lbi1VUw==].exe"
$DownloadPath = Join-Path $env:TEMP "BitdefenderGZ_SetupDownloader.exe"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Administrator privileges required" -Level "ERROR"
    Write-Host "CRITICAL: Administrator privileges required"
    exit $EXIT_CRITICAL
}

function Get-BitdefenderSetupExitHint {
    param([int]$Code)
    if ($Code -eq 3) {
        return "GravityZone setup often returns 3 when the endpoint cannot complete install over the network (relay unreachable, DNS, or firewall blocking required ports — e.g. TCP 7074 inbound on the relay from clients in common deployments). Confirm relay FQDN/IP, routing, and firewall rules. See Bitdefender GravityZone / BEST deployment troubleshooting for Windows."
    }
    return $null
}

try {

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "Downloading Bitdefender setup downloader..."
    try {
        Invoke-WebRequest -Uri $SetupUrl -OutFile $DownloadPath -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop
    } catch {
        Write-Log "Download failed: $_" -Level "ERROR"
        Write-Host "CRITICAL: Download failed. Log: $LogFile"
        exit $EXIT_CRITICAL
    }

    if (-not (Test-Path -LiteralPath $DownloadPath)) {
        Write-Log "Downloaded file missing" -Level "ERROR"
        Write-Host "CRITICAL: Downloaded file missing. Log: $LogFile"
        exit $EXIT_CRITICAL
    }

    $sizeMb = [math]::Round((Get-Item -LiteralPath $DownloadPath).Length / 1MB, 2)
    Write-Log "Downloaded ($sizeMb MB) to $DownloadPath"

    $argList = @("/bdparams", "/silent")
    Write-Log "Running installer: $($argList -join ' ')"
    try {
        $proc = Start-Process -FilePath $DownloadPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
        $code = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
        Write-Log "Installer exit code: $code"
        $hint = Get-BitdefenderSetupExitHint -Code $code
        if ($hint) {
            Write-Log $hint -Level "WARN"
        }
        # 0 = success; 3010/1641 = reboot may be required
        if ($code -in 0, 3010, 1641) {
            Write-Host "OK: Bitdefender agent install completed on $env:COMPUTERNAME (exit $code)"
            $Script:ExitCode = $EXIT_SUCCESS
        } else {
            Write-Log "Install did not report success (exit $code)" -Level "WARN"
            Write-Host "CRITICAL: Installer returned $code. Log: $LogFile"
            if ($hint) { Write-Host $hint }
        }
    } catch {
        Write-Log "Start-Process failed: $_" -Level "ERROR"
        Write-Host "CRITICAL: Failed to run installer - $_"
    } finally {
        Remove-Item -LiteralPath $DownloadPath -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log "Script error: $_" -Level "ERROR"
    Write-Host "CRITICAL: $_ — Log: $LogFile"
}

exit $Script:ExitCode
