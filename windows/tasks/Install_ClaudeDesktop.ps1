<#
.SYNOPSIS
    Install Anthropic Claude Desktop (Windows) using the full MSIX package.

.DESCRIPTION
    The winget/EXE installer is a small stub that downloads the app at runtime.
    This script bypasses that by downloading the official MSIX from Anthropic
    (full package) and installing it with Add-AppxPackage or Add-AppxProvisionedPackage.

    See: Deploy Claude Desktop for Windows (MSIX) - support.claude.com

    Exit codes: 0 = success, 1001 = warning, 1002 = critical.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_ClaudeDesktop.ps1"
.NOTES
    x64 MSIX: https://claude.ai/api/desktop/win32/x64/msix/latest/redirect
    arm64:    https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect
    Prefer run elevated for machine-wide provisioning; per-user install uses Add-AppxPackage.
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Install_ClaudeDesktop"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
if (-not (Test-Path $LogDir)) {
    $LogDir = Join-Path $env:ProgramData "nsight\logs\$(Get-Date -Format 'yyyyMMdd')"
    if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
}
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

$MIN_MSIX_BYTES = 50MB

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    if ($LogFile -and (Test-Path (Split-Path $LogFile -Parent))) {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ClaudeMsixRedirectUrl {
    $pa = $env:PROCESSOR_ARCHITECTURE
    if ($pa -eq "ARM64") {
        return "https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect"
    }
    return "https://claude.ai/api/desktop/win32/x64/msix/latest/redirect"
}

function Get-ClaudeDesktopInstallStatus {
    try {
        $appx = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like "Anthropic.Claude*" -or
                ($_.Name -like "*Claude*" -and $_.Publisher -like "*Anthropic*")
            } | Select-Object -First 1
        if ($appx) {
            return @{
                Installed = $true
                Kind      = "Appx"
                Name      = $appx.Name
                Version   = $appx.Version
                Path      = $appx.InstallLocation
            }
        }
    } catch { }

    try {
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Claude*" -or $_.PackageName -like "*Claude*" } |
            Select-Object -First 1
        if ($prov) {
            return @{
                Installed = $true
                Kind      = "Provisioned"
                Name      = $prov.DisplayName
                Version   = $prov.Version
                Path      = $null
            }
        }
    } catch { }

    $exePaths = @(
        "$env:LOCALAPPDATA\Programs\claude\Claude.exe",
        "$env:LOCALAPPDATA\Anthropic\Claude\Claude.exe"
    )
    foreach ($path in $exePaths) {
        if (Test-Path $path) {
            try {
                $ver = (Get-Item $path).VersionInfo.ProductVersion
                return @{ Installed = $true; Kind = "Exe"; Name = "Claude"; Version = $ver; Path = $path }
            } catch {
                return @{ Installed = $true; Kind = "Exe"; Name = "Claude"; Version = "Unknown"; Path = $path }
            }
        }
    }

    return @{ Installed = $false; Kind = $null; Name = $null; Version = $null; Path = $null }
}

function Test-IsSystemAccount {
    return $env:USERPROFILE -eq "C:\Windows\System32\config\systemprofile"
}

function Install-ClaudeMsix {
    param([Parameter(Mandatory)][string]$MsixPath)

    $admin = Test-IsAdmin
    $isSystem = Test-IsSystemAccount

    if ($admin) {
        Write-Log "Installing MSIX for all users (provisioned)..."
        try {
            Add-AppxProvisionedPackage -Online -PackagePath $MsixPath -SkipLicense -Regions "all" -ErrorAction Stop
            Write-Log "Add-AppxProvisionedPackage completed"
            return $true
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "already been added|0x80073d06|already exists") {
                Write-Log "Provision reported already present: $msg" -Level "WARN"
                return $true
            }
            Write-Log "Add-AppxProvisionedPackage failed: $msg" -Level "ERROR"
            if ($isSystem) {
                Write-Log "Running as SYSTEM - cannot use per-user Add-AppxPackage" -Level "ERROR"
                return $false
            }
            Write-Log "Falling back to per-user Add-AppxPackage..."
        }
    } elseif ($isSystem) {
        Write-Log "Not elevated and running as SYSTEM - MSIX install not possible" -Level "ERROR"
        return $false
    }

    Write-Log "Installing MSIX for current user (Add-AppxPackage)..."
    try {
        Add-AppxPackage -Path $MsixPath -ErrorAction Stop
        Write-Log "Add-AppxPackage completed"
        return $true
    } catch {
        Write-Log "Add-AppxPackage failed: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# --- main ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Log "=========================================="
Write-Log "Claude Desktop installation (full MSIX) - $ScriptName"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "Log: $LogFile"
Write-Log "Elevated: $(Test-IsAdmin); Processor: $env:PROCESSOR_ARCHITECTURE"

$existing = Get-ClaudeDesktopInstallStatus
if ($existing.Installed) {
    Write-Log "Already installed ($($existing.Kind)): $($existing.Name) $($existing.Version)"
    Write-Host ""
    Write-Host "OK: Claude Desktop already installed ($($existing.Kind)) v$($existing.Version)"
    exit $EXIT_SUCCESS
}

$msixUrl = Get-ClaudeMsixRedirectUrl
$msixFile = Join-Path $env:TEMP "ClaudeDesktop_$(Get-Date -Format 'yyyyMMdd_HHmmss').msix"
Write-Log "Downloading full MSIX (redirect): $msixUrl"

try {
    Invoke-WebRequest -Uri $msixUrl -OutFile $msixFile -UseBasicParsing -MaximumRedirection 5
} catch {
    Write-Log "Download failed: $($_.Exception.Message)" -Level "ERROR"
    exit $EXIT_CRITICAL
}

if (-not (Test-Path $msixFile)) {
    Write-Log "Download file missing" -Level "ERROR"
    exit $EXIT_CRITICAL
}

$size = (Get-Item $msixFile).Length
Write-Log "Downloaded MSIX size: $size bytes"
if ($size -lt $MIN_MSIX_BYTES) {
    Write-Log "File too small - expected full MSIX, not a stub" -Level "ERROR"
    Remove-Item $msixFile -Force -ErrorAction SilentlyContinue
    exit $EXIT_CRITICAL
}

$ErrorActionPreference = "Continue"
$ok = Install-ClaudeMsix -MsixPath $msixFile
Remove-Item $msixFile -Force -ErrorAction SilentlyContinue

if (-not $ok) {
    exit $EXIT_CRITICAL
}

Start-Sleep -Seconds 2
$verify = Get-ClaudeDesktopInstallStatus
if ($verify.Installed) {
    Write-Log "Verified: $($verify.Kind) $($verify.Version)"
    Write-Host ""
    Write-Host "OK: Claude Desktop installed ($($verify.Kind)) v$($verify.Version)"
    exit $EXIT_SUCCESS
}

Write-Log "Install finished but verification did not find Appx/Exe yet" -Level "WARN"
Write-Host ""
Write-Host 'WARNING: Claude may need a sign-out or reboot. Check Start menu for Claude.'
exit $EXIT_WARNING
