<#
.SYNOPSIS
    Install Tailscale VPN client (silent/unattended).

.DESCRIPTION
    Installs Tailscale for Windows when the check reports it missing.
    Tries winget first, then MSI from Tailscale packages (TS_NOLAUNCH=1 for silent).
    Idempotent: if already installed, exits 0. Aligns with Tailscale docs:
    https://tailscale.com/kb/1189/install-windows-msi

.EXECUTION
    Windows (local):  iex (Get-Content ".\Install_Tailscale.ps1" -Raw)
    Or:               powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_Tailscale.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Tailscale.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11

.OUTPUTS
    Exit 0    = Success
    Exit 1001 = Warning
    Exit 1002 = Critical/Error
#>

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ScriptName = "Install_Tailscale"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$Script:ExitCode = $EXIT_CRITICAL

function Write-Log { param([string]$Message, [string]$Level = "INFO")
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

function Test-TailscaleAlreadyInstalled {
    $paths = @(
        "${env:ProgramFiles}\Tailscale\tailscale.exe",
        "${env:ProgramFiles}\Tailscale\tailscale-ipn.exe",
        "${env:ProgramFiles(x86)}\Tailscale IPN\tailscale-ipn.exe"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $true } }
    $svc = Get-Service -Name "Tailscale","tailscale-ipn" -ErrorAction SilentlyContinue
    if ($svc) { return $true }
    $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Tailscale*" }
    return [bool]$reg
}

# MSI success: 0, 3010 (restart), 1641 (restart)
function Test-MSISuccess { param([int]$Code) return $Code -eq 0 -or $Code -eq 3010 -or $Code -eq 1641 }

# Wait for the _MSIExecute mutex to be released (error 1618 = installer already running)
function Wait-WindowsInstaller {
    param([int]$TimeoutSeconds = 120)
    Write-Log "Checking Windows Installer availability..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $mutex = $null
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting("Global\_MSIExecute")
            $mutex.Close()
            Write-Log "Windows Installer busy (_MSIExecute held); waiting 5s..." -Level "INFO"
            Start-Sleep -Seconds 5
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            Write-Log "Windows Installer is available"
            return $true
        } catch {
            return $true
        } finally {
            if ($mutex) { try { $mutex.Dispose() } catch {} }
        }
    }
    Write-Log "Windows Installer still busy after ${TimeoutSeconds}s; proceeding anyway" -Level "WARN"
    return $false
}

function Install-TailscaleViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Log "winget not found" -Level "WARN"; return $false }
    
    # Test if winget is actually usable (not just present)
    try {
        $testOut = & winget --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "winget found but not usable (version check failed): $testOut" -Level "WARN"
            return $false
        }
    } catch {
        Write-Log "winget found but cannot be executed: $_" -Level "WARN"
        return $false
    }
    
    Write-Log "Installing Tailscale via winget (Tailscale.Tailscale)..."
    try {
        $out = & winget install --id Tailscale.Tailscale --accept-package-agreements --accept-source-agreements --silent 2>&1
        $ok = $LASTEXITCODE -eq 0
        if ($ok) { 
            Write-Log "winget install succeeded" 
            return $true
        } else { 
            Write-Log "winget install failed: $out" -Level "WARN" 
            return $false
        }
    } catch {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -like "*cannot be accessed*" -or $errorMsg -like "*failed to run*") {
            Write-Log "winget.exe access error (may be locked or corrupted): $errorMsg" -Level "WARN"
            Write-Log "Falling back to MSI installation method" -Level "INFO"
        } else {
            Write-Log "winget install exception: $errorMsg" -Level "WARN"
        }
        return $false
    }
}

function Install-TailscaleViaMSI {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $is64 = [Environment]::Is64BitOperatingSystem
    $arch = if ($is64) { "amd64" } else { "x86" }
    $versions = @("1.94.2", "1.92.5", "1.90.9")
    $msiPath = "$env:TEMP\tailscale-setup.msi"
    $msiLog = "$env:TEMP\tailscale-msi-install.log"

    Wait-WindowsInstaller | Out-Null

    foreach ($ver in $versions) {
        $url = "https://pkgs.tailscale.com/stable/tailscale-setup-$ver-$arch.msi"
        try {
            Write-Log "Downloading MSI: $url"
            Invoke-WebRequest -Uri $url -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Log "Download failed: $_" -Level "WARN"
            continue
        }
        if (-not (Test-Path $msiPath)) { continue }

        Write-Log "Running MSI silent install (TS_NOLAUNCH=1 /qn)..."
        $arg = "TS_NOLAUNCH=1", "/i", "`"$msiPath`"", "/qn", "/norestart", "/l*v", "`"$msiLog`""
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $arg -Wait -PassThru
        $exitCode = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }

        if ($exitCode -eq 1618) {
            Write-Log "MSI install returned 1618 (installer busy); waiting for installer and retrying..." -Level "WARN"
            Wait-WindowsInstaller | Out-Null
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $arg -Wait -PassThru
            $exitCode = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
        }

        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        if (Test-MSISuccess $exitCode) {
            Write-Log "MSI install succeeded (exit $exitCode)"
            return $true
        }
        Write-Log "MSI install returned $exitCode; trying next version..." -Level "WARN"
    }
    return $false
}

try {
    if (Test-TailscaleAlreadyInstalled) {
        Write-Log "Tailscale already installed"
        Write-Host "OK: Tailscale VPN already installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    $installed = Install-TailscaleViaWinget
    if (-not $installed) { $installed = Install-TailscaleViaMSI }

    if ($installed -or (Test-TailscaleAlreadyInstalled)) {
        Write-Host "OK: Tailscale VPN installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    Write-Log "Install failed" -Level "ERROR"
    Write-Host "CRITICAL: Tailscale VPN install failed. Check log: $LogFile"
} catch {
    if (Test-TailscaleAlreadyInstalled) {
        Write-Log "Tailscale is present after error; treating as success" -Level "WARN"
        Write-Host "OK: Tailscale VPN installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Install failed: $_" -Level "ERROR"
        Write-Host "CRITICAL: Tailscale VPN install failed - $_"
    }
}
exit $Script:ExitCode
