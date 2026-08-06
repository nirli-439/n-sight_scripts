<#
.SYNOPSIS
    Install Surfshark VPN for Windows (silent/unattended).

.DESCRIPTION
    Installs Surfshark when deployed as an N-Sight automated task.
    Idempotent: if already installed, exits 0.
    Tries winget first (Surfshark.Surfshark), then downloads the official EXE from
    Surfshark and runs: SurfsharkSetup.exe /exenoui /qn (see vendor silent-install docs).

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_Surfshark.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Surfshark.ps1")

.NOTES
    Requires: Administrator privileges
    Exit: 0 = OK, 1002 = Critical

.OUTPUTS
    Exit 0    = Success
    Exit 1002 = Critical/Error
#>

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ScriptName = "Install_Surfshark"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$Script:ExitCode = $EXIT_CRITICAL

# Official latest Windows installer (redirects to current build)
$SurfsharkSetupUrl = "https://downloads.surfshark.com/windows/latest/SurfsharkSetup.exe"
$DownloadPath = Join-Path $env:TEMP "SurfsharkSetup.exe"

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

function Test-SurfsharkInstalled {
    $exePaths = @(
        "${env:ProgramFiles}\Surfshark\Surfshark.exe",
        "${env:ProgramFiles(x86)}\Surfshark\Surfshark.exe"
    )
    foreach ($p in $exePaths) {
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $true }
    }
    $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Surfshark*" }
    return [bool]$reg
}

function Install-SurfsharkViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Log "winget not found" -Level "WARN"
        return $false
    }
    try {
        $null = & winget --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "winget not usable (version check failed)" -Level "WARN"
            return $false
        }
    } catch {
        Write-Log "winget cannot be executed: $_" -Level "WARN"
        return $false
    }

    Write-Log "Installing Surfshark via winget (Surfshark.Surfshark)..."
    try {
        $out = & winget install --id Surfshark.Surfshark --accept-package-agreements --accept-source-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "winget install succeeded"
            return $true
        }
        Write-Log "winget install failed (exit $LASTEXITCODE): $out" -Level "WARN"
        return $false
    } catch {
        Write-Log "winget exception: $_" -Level "WARN"
        return $false
    }
}

function Install-SurfsharkViaExe {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installerLog = Join-Path $LogDir "Surfshark_Installer_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    Write-Log "Downloading Surfshark from $SurfsharkSetupUrl"
    try {
        Invoke-WebRequest -Uri $SurfsharkSetupUrl -OutFile $DownloadPath -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
    } catch {
        Write-Log "Download failed: $_" -Level "ERROR"
        return $false
    }
    if (-not (Test-Path $DownloadPath)) {
        Write-Log "Downloaded file missing" -Level "ERROR"
        return $false
    }

    $sizeMb = [math]::Round((Get-Item $DownloadPath).Length / 1MB, 2)
    Write-Log "Downloaded SurfsharkSetup.exe ($sizeMb MB)"

    Write-Log "Running silent install (/exenoui /exelog /qn)..."
    # Vendor-documented silent EXE (e.g. /exenoui /exelog <path> /qn)
    $argList = @(
        "/exenoui"
        "/exelog"
        "`"$installerLog`""
        "/qn"
    )
    try {
        $proc = Start-Process -FilePath $DownloadPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
        $code = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
        Write-Log "Installer exit code: $code"
        # 0 = success; 3010/1641 = reboot may be required (treat as success for RMM)
        if ($code -in 0, 3010, 1641) {
            return $true
        }
        Write-Log "Non-zero installer exit: $code" -Level "WARN"
        # Still verify on disk — some wrappers return non-zero while install completed
        Start-Sleep -Seconds 5
        if (Test-SurfsharkInstalled) {
            Write-Log "Surfshark present despite exit $code; treating as success" -Level "WARN"
            return $true
        }
        return $false
    } catch {
        Write-Log "Start-Process failed: $_" -Level "ERROR"
        return $false
    } finally {
        Remove-Item -Path $DownloadPath -Force -ErrorAction SilentlyContinue
    }
}

try {
    if (Test-SurfsharkInstalled) {
        Write-Log "Surfshark already installed"
        Write-Host "OK: Surfshark VPN already installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    $ok = Install-SurfsharkViaWinget
    if (-not $ok) { $ok = Install-SurfsharkViaExe }

    Start-Sleep -Seconds 3
    if ($ok -or (Test-SurfsharkInstalled)) {
        Write-Host "OK: Surfshark VPN installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    Write-Log "Install failed" -Level "ERROR"
    Write-Host "CRITICAL: Surfshark VPN install failed. Log: $LogFile"
} catch {
    if (Test-SurfsharkInstalled) {
        Write-Log "Surfshark present after error; treating as success" -Level "WARN"
        Write-Host "OK: Surfshark VPN installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Install failed: $_" -Level "ERROR"
        Write-Host "CRITICAL: Surfshark VPN install failed - $_"
    }
}
exit $Script:ExitCode
