<#
.SYNOPSIS
    Install Twingate Windows client (silent / unattended).

.DESCRIPTION
    For N-Sight RMM: run this script with no arguments. Downloads the official EXE from api.twingate.com,
    runs silent install (/qn) with vendor defaults (no_optional_updates, auto_update). Falls back to MSI if needed.
    Idempotent: exits 0 if Twingate is already installed.

.EXECUTION
    N-Sight:          Deploy as PowerShell task, Run as System / Administrator, no parameters.
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_Twingate.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Twingate.ps1")

.NOTES
    https://docs.twingate.com/docs/windows-managed-devices
    Exit 0 = success, 1002 = failure (N-Sight aligned).
#>

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ScriptName = "Install_Twingate"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$Script:ExitCode = $EXIT_CRITICAL

$DownloadExeUrl = "https://api.twingate.com/download/windows"
$DownloadMsiUrl = "https://api.twingate.com/download/windows?installer=msi"

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

function Test-TwingateAlreadyInstalled {
    $machinePaths = @(
        "${env:ProgramFiles}\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
    )
    foreach ($p in $machinePaths) {
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $true }
    }
    $reg = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    ) | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -like "*Twingate*" }
    return [bool]$reg
}

function Test-MSISuccess {
    param([int]$Code)
    return $Code -eq 0 -or $Code -eq 3010 -or $Code -eq 1641
}

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

function Get-TwingateVendorOptions {
    # Fixed defaults per Twingate managed-device guidance (no script parameters for N-Sight).
    return @(
        "no_optional_updates=true"
        "auto_update=true"
    )
}

function Test-DotNet8DesktopRuntime {
    $base = "${env:ProgramFiles}\dotnet\shared\Microsoft.WindowsDesktop.App"
    if (-not (Test-Path -LiteralPath $base -ErrorAction SilentlyContinue)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "8.*" })
}

function Install-DotNet8DesktopRuntimeViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Log "winget not available; cannot auto-install .NET 8 Desktop Runtime" -Level "WARN"
        return $false
    }
    Write-Log "Installing .NET 8 Desktop Runtime via winget (Microsoft.DotNet.DesktopRuntime.8)..."
    try {
        $out = & winget install --id Microsoft.DotNet.DesktopRuntime.8 --accept-package-agreements --accept-source-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "dotnet runtime install succeeded"
            return $true
        }
        Write-Log "winget dotnet install failed: $out" -Level "WARN"
    } catch {
        Write-Log "winget dotnet install exception: $_" -Level "WARN"
    }
    return $false
}

function Install-TwingateViaExe {
    param([string[]]$VendorOptions)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installer = Join-Path $env:TEMP "TwingateWindowsInstaller.exe"
    try {
        Write-Log "Downloading Twingate EXE from $DownloadExeUrl"
        Invoke-WebRequest -Uri $DownloadExeUrl -OutFile $installer -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Log "Download failed: $_" -Level "ERROR"
        return $false
    }
    if (-not (Test-Path -LiteralPath $installer)) { return $false }

    $exeArgs = @("/qn") + @($VendorOptions)
    Write-Log "Running silent install: $($exeArgs -join ' ')"
    $proc = Start-Process -FilePath $installer -ArgumentList $exeArgs -Wait -PassThru
    $exitCode = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue

    if ($exitCode -eq 0) {
        Write-Log "Installer exit code 0"
        return $true
    }
    Write-Log "Installer returned exit code $exitCode" -Level "WARN"
    return $false
}

function Install-TwingateViaMsi {
    param([string[]]$VendorOptions)
    if (-not (Test-DotNet8DesktopRuntime)) {
        Write-Log ".NET 8 Desktop Runtime not detected; attempting install via winget" -Level "WARN"
        if (-not (Install-DotNet8DesktopRuntimeViaWinget)) {
            Write-Log "MSI install may fail without .NET 8 Desktop Runtime. See https://docs.twingate.com/docs/windows-managed-devices" -Level "WARN"
        }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $msiPath = Join-Path $env:TEMP "TwingateWindowsInstaller.msi"
    $msiLog = Join-Path $env:TEMP "twingate-msi-install.log"
    try {
        Write-Log "Downloading Twingate MSI from $DownloadMsiUrl"
        Invoke-WebRequest -Uri $DownloadMsiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Log "MSI download failed: $_" -Level "ERROR"
        return $false
    }
    if (-not (Test-Path -LiteralPath $msiPath)) { return $false }

    Wait-WindowsInstaller | Out-Null

    # msiexec: pass Twingate properties as separate arguments after /i ... /qn (same tokens as EXE per vendor docs)
    $msiArgs = [System.Collections.Generic.List[string]]::new()
    [void]$msiArgs.Add("/i")
    [void]$msiArgs.Add($msiPath)
    [void]$msiArgs.Add("/qn")
    [void]$msiArgs.Add("/norestart")
    [void]$msiArgs.Add("/l*v")
    [void]$msiArgs.Add($msiLog)
    foreach ($a in $VendorOptions) { [void]$msiArgs.Add($a) }

    Write-Log "Running msiexec $($msiArgs -join ' ')"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @($msiArgs) -Wait -PassThru
    $exitCode = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }

    if ($exitCode -eq 1618) {
        Write-Log "MSI 1618 (installer busy); retrying after wait..." -Level "WARN"
        Wait-WindowsInstaller | Out-Null
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @($msiArgs) -Wait -PassThru
        $exitCode = if ($proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
    }

    Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue

    if (Test-MSISuccess $exitCode) {
        Write-Log "MSI install finished (exit $exitCode)"
        return $true
    }
    Write-Log "MSI install failed (exit $exitCode). Log: $msiLog" -Level "ERROR"
    return $false
}

try {
    if (Test-TwingateAlreadyInstalled) {
        Write-Log "Twingate already installed"
        Write-Host "OK: Twingate already installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    $vendorOpts = Get-TwingateVendorOptions
    $ok = Install-TwingateViaExe -VendorOptions $vendorOpts
    if (-not $ok) {
        Write-Log "EXE install did not report success; trying MSI fallback..." -Level "WARN"
        $ok = Install-TwingateViaMsi -VendorOptions $vendorOpts
    }

    if ($ok -or (Test-TwingateAlreadyInstalled)) {
        Write-Host "OK: Twingate installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
        exit $Script:ExitCode
    }

    Write-Log "Install failed" -Level "ERROR"
    Write-Host "CRITICAL: Twingate install failed. Check log: $LogFile"
} catch {
    if (Test-TwingateAlreadyInstalled) {
        Write-Log "Twingate present after error; treating as success" -Level "WARN"
        Write-Host "OK: Twingate installed on $env:COMPUTERNAME"
        $Script:ExitCode = $EXIT_SUCCESS
    } else {
        Write-Log "Install failed: $_" -Level "ERROR"
        Write-Host "CRITICAL: Twingate install failed - $_"
    }
}
exit $Script:ExitCode
