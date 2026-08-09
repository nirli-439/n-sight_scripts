<#
.SYNOPSIS
    Fixes Google Credential Provider for Windows (GCPW) token expiration issues that break Windows Hello (PIN/fingerprint) login.

.DESCRIPTION
    This script remediates GCPW token expiration issues by:
    - Configuring proper token lifetime registry settings
    - Ensuring Windows Hello for Business is properly configured
    - Setting refresh token policies to prevent premature expiration
    - Validating GCPW service health
    - Configuring credential provider order to prioritize Windows Hello

    When GCPW tokens expire too quickly, users cannot sign in with PIN/fingerprint
    and are forced to use password authentication.

.EXECUTION
    Windows (local):  iex (Get-Content ".\Remediate_GCPW_Token_Expiration.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remediate_GCPW_Token_Expiration.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Remediate_GCPW_Token_Expiration_1Year.ps1")

.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11 (Pro/Enterprise for Windows Hello for Business)
    Reference: https://support.google.com/a/answer/9250996 (GCPW Admin Guide)

.OUTPUTS
    Exit 0    = Success - GCPW token settings configured
    Exit 1001 = Warning - Partial fix applied, may need manual review
    Exit 1002 = Critical - Failed to apply fixes or GCPW not installed
#>

#Requires -RunAsAdministrator
#Requires -Version 5.1

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Remediate_GCPW_Token_Expiration"
$ScriptVersion = "1.0"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Exit codes for N-Sight
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# GCPW Registry Paths
$GCPWRegPath = "HKLM:\SOFTWARE\Google\GCPW"
$GCPWOW64RegPath = "HKLM:\SOFTWARE\WOW6432Node\Google\GCPW"
$WinLogonRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Summary {
    param(
        [ValidateSet("OK", "PASS", "WARNING", "CRITICAL", "Wait to Task")]
        [string]$Status,
        [string]$Message
    )
    Write-Host ""
    Write-Host "${Status}: $Message"
}

function Test-GCPWInstalled {
    $gcpwPaths = @(
        "${env:ProgramFiles}\Google\Credential Provider",
        "${env:ProgramFiles(x86)}\Google\Credential Provider"
    )
    foreach ($path in $gcpwPaths) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }
    # Also check for GCPW DLL registration
    $gcpwDll = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.(Get-Member -Name "(Default)" -ErrorAction SilentlyContinue) -match "GCPW" }
    if ($gcpwDll) { return $true }
    return $false
}

function Get-GCPWVersion {
    $gcpwExe = "${env:ProgramFiles}\Google\Credential Provider\gcpw.exe"
    $gcpwExe86 = "${env:ProgramFiles(x86)}\Google\Credential Provider\gcpw.exe"
    $exePath = if (Test-Path -LiteralPath $gcpwExe) { $gcpwExe } elseif (Test-Path -LiteralPath $gcpwExe86) { $gcpwExe86 } else { $null }
    if ($exePath) {
        try {
            $version = (Get-ItemProperty -Path $exePath -ErrorAction SilentlyContinue).VersionInfo.FileVersion
            return $version
        } catch {
            return "Unknown"
        }
    }
    return "Not Found"
}

function Set-GCPWTokenRegistry {
    param([ref]$WarningCount)
    Write-Log "Configuring GCPW token registry settings..."
    $paths = @($GCPWRegPath, $GCPWOW64RegPath)
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            try {
                New-Item -Path $path -Force -ErrorAction Stop | Out-Null
                Write-Log "Created registry path: $path" -Level "SUCCESS"
            } catch {
                Write-Log "Failed to create registry path $path : $_" -Level "WARN"
                $WarningCount.Value++
                continue
            }
        }
        # Token lifetime: 1 year (in seconds) - prevents rapid expiration
        try {
            Set-ItemProperty -Path $path -Name "TokenLifetimeSecs" -Value 31536000 -Type DWord -Force -ErrorAction Stop
            Write-Log "Set TokenLifetimeSecs = 31536000 (1 year) at $path" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to set TokenLifetimeSecs at $path : $_" -Level "WARN"
            $WarningCount.Value++
        }
        # Refresh token buffer: refresh 1 year before expiration
        try {
            Set-ItemProperty -Path $path -Name "RefreshBufferSecs" -Value 31536000 -Type DWord -Force -ErrorAction Stop
            Write-Log "Set RefreshBufferSecs = 31536000 (1 year) at $path" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to set RefreshBufferSecs at $path : $_" -Level "WARN"
            $WarningCount.Value++
        }
        # Enable automatic token refresh
        try {
            Set-ItemProperty -Path $path -Name "AutoRefreshToken" -Value 1 -Type DWord -Force -ErrorAction Stop
            Write-Log "Set AutoRefreshToken = 1 at $path" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to set AutoRefreshToken at $path : $_" -Level "WARN"
            $WarningCount.Value++
        }
        # Minimum token validity for login (ensure token doesn't expire mid-login)
        try {
            Set-ItemProperty -Path $path -Name "MinTokenValiditySecs" -Value 300 -Type DWord -Force -ErrorAction Stop
            Write-Log "Set MinTokenValiditySecs = 300 (5 minutes) at $path" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to set MinTokenValiditySecs at $path : $_" -Level "WARN"
            $WarningCount.Value++
        }
    }
}

function Enable-WindowsHelloForBusiness {
    param([ref]$WarningCount)
    Write-Log "Configuring Windows Hello for Business settings..."
    $whfbPaths = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork",
        "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork"
    )
    foreach ($path in $whfbPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            try {
                New-Item -Path $path -Force -ErrorAction Stop | Out-Null
                Write-Log "Created WHfB path: $path" -Level "SUCCESS"
            } catch {
                Write-Log "Failed to create WHfB path $path : $_" -Level "WARN"
                $WarningCount.Value++
                continue
            }
        }
        # Enable Windows Hello for Business
        try {
            Set-ItemProperty -Path $path -Name "Enabled" -Value 1 -Type DWord -Force -ErrorAction Stop
            Write-Log "Enabled Windows Hello for Business at $path" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to enable WHfB at $path : $_" -Level "WARN"
            $WarningCount.Value++
        }
        # Require PIN for fallback (ensures PIN is always available)
        try {
            Set-ItemProperty -Path $path -Name "RequirePIN" -Value 1 -Type DWord -Force -ErrorAction Stop
            Write-Log "Set RequirePIN = 1 at $path" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to set RequirePIN at $path : $_" -Level "WARN"
        }
    }
    # Configure PIN complexity settings (device level)
    $pinComplexityPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork\PINComplexity"
    if (-not (Test-Path -LiteralPath $pinComplexityPath)) {
        try {
            New-Item -Path $pinComplexityPath -Force -ErrorAction Stop | Out-Null
            Write-Log "Created PINComplexity path" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to create PINComplexity path : $_" -Level "WARN"
        }
    }
    if (Test-Path -LiteralPath $pinComplexityPath) {
        try {
            Set-ItemProperty -Path $pinComplexityPath -Name "MinimumPINLength" -Value 6 -Type DWord -Force -ErrorAction Stop
            Write-Log "Set MinimumPINLength = 6" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to set MinimumPINLength : $_" -Level "WARN"
        }
    }
}

function Set-CredentialProviderOrder {
    param([ref]$WarningCount)
    Write-Log "Configuring credential provider order for Windows Hello priority..."
    # Windows Hello credential provider GUIDs
    $pinProvider = "{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}"   # PIN
    $bioProvider = "{8AF662BF-65A0-4D0A-A540-A338A999D36F}"   # Biometric/Fingerprint
    $gcpwProvider = "{F347CFF8-9D68-4A2C-BA73-6F5E7C8CFEA2}" # GCPW
    $passwordProvider = "{6f45dc1e-5384-457a-bc13-2cd81b0d28ed}" # Password
    # DefaultCredentialProvider
    try {
        Set-ItemProperty -Path $WinLogonRegPath -Name "DefaultCredentialProvider" -Value $pinProvider -Type String -Force -ErrorAction Stop
        Write-Log "Set DefaultCredentialProvider to PIN provider" -Level "SUCCESS"
    } catch {
        Write-Log "Failed to set DefaultCredentialProvider : $_" -Level "WARN"
        $WarningCount.Value++
    }
    # LastLoggedOnProvider - prefer Windows Hello providers
    try {
        Set-ItemProperty -Path $WinLogonRegPath -Name "LastLoggedOnProvider" -Value $pinProvider -Type String -Force -ErrorAction Stop
        Write-Log "Set LastLoggedOnProvider to PIN provider" -Level "SUCCESS"
    } catch {
        Write-Log "Failed to set LastLoggedOnProvider : $_" -Level "WARN"
    }
}

function Restart-GCPWService {
    param([ref]$WarningCount)
    Write-Log "Restarting GCPW service to apply changes..."
    $gcpwService = Get-Service -Name "gcpw*" -ErrorAction SilentlyContinue
    if ($gcpwService) {
        try {
            Restart-Service -Name $gcpwService.Name -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
            $status = (Get-Service -Name $gcpwService.Name).Status
            if ($status -eq "Running") {
                Write-Log "GCPW service restarted successfully" -Level "SUCCESS"
            } else {
                Write-Log "GCPW service status after restart: $status" -Level "WARN"
                $WarningCount.Value++
            }
        } catch {
            Write-Log "Failed to restart GCPW service : $_" -Level "WARN"
            $WarningCount.Value++
        }
    } else {
        Write-Log "GCPW service not found - may be integrated with Windows" -Level "INFO"
    }
}

function Clear-TokenCache {
    param([ref]$WarningCount)
    Write-Log "Clearing stale GCPW token cache..."
    $tokenPaths = @(
        "$env:ProgramData\Google\Credential Provider\Tokens",
        "$env:LOCALAPPDATA\Google\Credential Provider"
    )
    foreach ($path in $tokenPaths) {
        if (Test-Path -LiteralPath $path) {
            try {
                Remove-Item -Path "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Cleared token cache at $path" -Level "SUCCESS"
            } catch {
                Write-Log "Could not clear token cache at $path : $_" -Level "WARN"
            }
        }
    }
    # Also clear Windows credential cache for GCPW
    try {
        $gcpwCreds = cmdkey /list | Select-String -Pattern "Google|GCPW|gcpw" -ErrorAction SilentlyContinue
        if ($gcpwCreds) {
            Write-Log "Found GCPW-related credentials in Windows Credential Manager" -Level "INFO"
            Write-Log "Note: Users may need to re-authenticate once after token fix" -Level "INFO"
        }
    } catch {
        # cmdkey not available or failed
    }
}

function Get-CurrentSettings {
    Write-Log "Reading current GCPW and Windows Hello settings..."
    # Check GCPW registry settings
    foreach ($path in @($GCPWRegPath, $GCPWOW64RegPath)) {
        if (Test-Path -LiteralPath $path) {
            try {
                $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                Write-Log "Current settings at $path :" -Level "INFO"
                if ($props.TokenLifetimeSecs) { Write-Log "  TokenLifetimeSecs = $($props.TokenLifetimeSecs)" -Level "INFO" }
                if ($props.RefreshBufferSecs) { Write-Log "  RefreshBufferSecs = $($props.RefreshBufferSecs)" -Level "INFO" }
                if ($props.AutoRefreshToken) { Write-Log "  AutoRefreshToken = $($props.AutoRefreshToken)" -Level "INFO" }
            } catch {
                Write-Log "Could not read settings at $path" -Level "WARN"
            }
        } else {
            Write-Log "GCPW registry path not found: $path" -Level "INFO"
        }
    }
    # Check Windows Hello status
    try {
        $whfbStatus = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsHelloForBusiness" -ErrorAction SilentlyContinue
        if ($whfbStatus) {
            Write-Log "Windows Hello registry exists" -Level "INFO"
        }
    } catch {
        # Not critical
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName v$ScriptVersion Started"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User Context: $env:USERNAME"
Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Log File: $LogFile"

# Admin check
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

# Check if GCPW is installed
if (-not (Test-GCPWInstalled)) {
    Write-Log "Google Credential Provider for Windows (GCPW) not detected!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "GCPW not installed - cannot apply token fixes"
    exit $EXIT_CRITICAL
}

$gcpwVersion = Get-GCPWVersion
Write-Log "GCPW detected (version: $gcpwVersion)" -Level "SUCCESS"

# Track warnings
$warningCount = 0

try {
    # Read current settings before changes
    Get-CurrentSettings
    # Apply fixes
    Set-GCPWTokenRegistry -WarningCount ([ref]$warningCount)
    Enable-WindowsHelloForBusiness -WarningCount ([ref]$warningCount)
    Set-CredentialProviderOrder -WarningCount ([ref]$warningCount)
    Clear-TokenCache -WarningCount ([ref]$warningCount)
    Restart-GCPWService -WarningCount ([ref]$warningCount)
    Write-Log "=========================================="
    Write-Log "GCPW token expiration remediation completed" -Level "SUCCESS"
    Write-Log "Warnings: $warningCount" -Level $(if ($warningCount -gt 0) { "WARN" } else { "INFO" })
    Write-Log "=========================================="
    if ($warningCount -gt 0) {
        Write-Summary -Status "WARNING" -Message "GCPW token settings applied with $warningCount warnings - review logs"
        exit $EXIT_WARNING
    } else {
        Write-Summary -Status "OK" -Message "GCPW token expiration fixed - Windows Hello should work now"
        exit $EXIT_SUCCESS
    }
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Failed to fix GCPW token expiration - $_"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Script execution ended"
}
