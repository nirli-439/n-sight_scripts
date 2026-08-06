<#
.SYNOPSIS
    Check if screen lock timeout is set correctly (3 min battery, 8 min AC).
    
.DESCRIPTION
    This security monitoring script checks if the screen lock is configured with
    appropriate timeouts:
    - On battery (DC): 3 minutes (180 seconds) or less
    - On AC power: 8 minutes (480 seconds) or less
    
    The script checks multiple sources:
    - Screen saver timeout with password protection enabled
    - Machine inactivity limit (Group Policy setting)
    - Power plan display timeout settings
    
    A compliant system should automatically lock after the specified inactivity period.
    
    Designed for N-Sight RMM security compliance monitoring.
    
    Exit Codes:
    - 0 = PASS (Screen lock timeouts are within limits)
    - 1 = FAIL (Screen lock is disabled, not configured, or timeout exceeds limits)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_ScreenLock_Timeout.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_ScreenLock_Timeout.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_ScreenLock_Timeout.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11, Windows Server 2016+
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\ScreenLockCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Maximum allowed timeout in seconds
$MaxTimeoutAC = 480   # 8 minutes for AC (plugged in)
$MaxTimeoutDC = 180   # 3 minutes for DC (battery)

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScreenSaverSettings {
    <#
    .SYNOPSIS
        Get screen saver settings from registry (user-level)
    #>
    $result = @{
        Enabled = $false
        TimeoutSeconds = 0
        PasswordProtected = $false
        Source = "Not Configured"
    }
    
    try {
        # Check HKCU for current user settings
        $desktopPath = "HKCU:\Control Panel\Desktop"
        
        if (Test-Path $desktopPath) {
            $desktop = Get-ItemProperty -Path $desktopPath -ErrorAction SilentlyContinue
            
            # ScreenSaveActive: "1" = enabled
            if ($null -ne $desktop.ScreenSaveActive) {
                $result.Enabled = ($desktop.ScreenSaveActive -eq "1")
            }
            
            # ScreenSaveTimeOut: timeout in seconds
            if ($null -ne $desktop.ScreenSaveTimeOut) {
                $result.TimeoutSeconds = [int]$desktop.ScreenSaveTimeOut
            }
            
            # ScreenSaverIsSecure: "1" = password required on resume
            if ($null -ne $desktop.ScreenSaverIsSecure) {
                $result.PasswordProtected = ($desktop.ScreenSaverIsSecure -eq "1")
            }
            
            $result.Source = "Registry (HKCU)"
        }
    }
    catch {
        Write-Log "Error reading screen saver settings: $_" -Level "WARNING"
    }
    
    return $result
}

function Get-MachineInactivityLimit {
    <#
    .SYNOPSIS
        Get machine inactivity limit from Local Security Policy
        This is "Interactive logon: Machine inactivity limit"
    #>
    $result = @{
        Configured = $false
        TimeoutSeconds = 0
        Source = "Not Configured"
    }
    
    try {
        # Check registry for machine inactivity limit (set by Group Policy)
        $securityPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        
        if (Test-Path $securityPath) {
            $security = Get-ItemProperty -Path $securityPath -ErrorAction SilentlyContinue
            
            # InactivityTimeoutSecs: timeout in seconds (0 = disabled)
            if ($null -ne $security.InactivityTimeoutSecs -and $security.InactivityTimeoutSecs -gt 0) {
                $result.Configured = $true
                $result.TimeoutSeconds = [int]$security.InactivityTimeoutSecs
                $result.Source = "Group Policy (Machine Inactivity Limit)"
            }
        }
    }
    catch {
        Write-Log "Error reading machine inactivity limit: $_" -Level "WARNING"
    }
    
    return $result
}

function Get-PowerPlanLockTimeout {
    <#
    .SYNOPSIS
        Get console lock display off timeout from active power plan
    #>
    $result = @{
        ACTimeoutSeconds = 0
        DCTimeoutSeconds = 0
        Configured = $false
        Source = "Not Configured"
    }
    
    try {
        # Get active power plan
        $activePlan = powercfg /getactivescheme 2>$null
        if ($activePlan -match "([a-fA-F0-9-]{36})") {
            $planGuid = $matches[1]
            
            # Console lock display off timeout GUID
            # SUB_VIDEO = 7516b95f-f776-4464-8c53-06167f40cc99
            # VIDEOCONLOCK = 8EC4B3A5-6868-48c2-BE75-4F3044BE88A7
            $subVideoGuid = "7516b95f-f776-4464-8c53-06167f40cc99"
            $consoleLockGuid = "8EC4B3A5-6868-48c2-BE75-4F3044BE88A7"
            
            # Query the console lock timeout
            $queryResult = powercfg /query $planGuid $subVideoGuid $consoleLockGuid 2>$null
            
            if ($queryResult) {
                # Parse AC and DC power settings
                $lines = $queryResult -split "`n"
                foreach ($line in $lines) {
                    if ($line -match "Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)") {
                        $result.ACTimeoutSeconds = [Convert]::ToInt32($matches[1], 16)
                        $result.Configured = $true
                    }
                    if ($line -match "Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)") {
                        $result.DCTimeoutSeconds = [Convert]::ToInt32($matches[1], 16)
                        $result.Configured = $true
                    }
                }
                
                if ($result.Configured) {
                    $result.Source = "Power Plan Settings"
                }
            }
        }
    }
    catch {
        Write-Log "Error reading power plan settings: $_" -Level "WARNING"
    }
    
    return $result
}

function Get-LockOnScreenSaverGPO {
    <#
    .SYNOPSIS
        Check if "Enable screen saver" and "Password protect the screen saver" 
        are set via Group Policy
    #>
    $result = @{
        ScreenSaverEnabled = $false
        PasswordRequired = $false
        TimeoutSeconds = 0
        Configured = $false
        Source = "Not Configured"
    }
    
    try {
        # Group Policy paths for screen saver settings
        $gpoPath = "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop"
        
        if (Test-Path $gpoPath) {
            $gpo = Get-ItemProperty -Path $gpoPath -ErrorAction SilentlyContinue
            
            # ScreenSaveActive set by policy
            if ($null -ne $gpo.ScreenSaveActive) {
                $result.ScreenSaverEnabled = ($gpo.ScreenSaveActive -eq "1")
                $result.Configured = $true
            }
            
            # ScreenSaverIsSecure set by policy
            if ($null -ne $gpo.ScreenSaverIsSecure) {
                $result.PasswordRequired = ($gpo.ScreenSaverIsSecure -eq "1")
            }
            
            # ScreenSaveTimeOut set by policy
            if ($null -ne $gpo.ScreenSaveTimeOut) {
                $result.TimeoutSeconds = [int]$gpo.ScreenSaveTimeOut
            }
            
            if ($result.Configured) {
                $result.Source = "Group Policy (Screen Saver)"
            }
        }
    }
    catch {
        Write-Log "Error reading GPO screen saver settings: $_" -Level "WARNING"
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Screen Lock Timeout Security Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"
Write-Log "Maximum Allowed Timeout (AC/Plugged In): $MaxTimeoutAC seconds ($($MaxTimeoutAC / 60) minutes)"
Write-Log "Maximum Allowed Timeout (DC/Battery): $MaxTimeoutDC seconds ($($MaxTimeoutDC / 60) minutes)"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "FAIL: Script requires administrator privileges"
    exit 1001
}

try {
    $isCompliantAC = $false
    $isCompliantDC = $false
    $effectiveTimeoutAC = $null
    $effectiveTimeoutDC = $null
    $effectiveSourceAC = "None"
    $effectiveSourceDC = "None"
    $findings = @()
    
    # Check if this is a laptop/portable device
    $isLaptop = $false
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        $isLaptop = ($null -ne $battery)
    }
    catch {
        Write-Log "Could not determine if device has battery: $_" -Level "WARNING"
    }
    Write-Log "Device Type: $(if($isLaptop){'Laptop/Portable (has battery)'}else{'Desktop (no battery)'})"
    
    # Check 1: Screen Saver Settings (applies to both AC and DC)
    Write-Log "Checking screen saver settings..."
    $screenSaver = Get-ScreenSaverSettings
    Write-Log "Screen Saver Enabled: $($screenSaver.Enabled)"
    Write-Log "Screen Saver Timeout: $($screenSaver.TimeoutSeconds) seconds"
    Write-Log "Screen Saver Password Protected: $($screenSaver.PasswordProtected)"
    
    if ($screenSaver.Enabled -and $screenSaver.PasswordProtected -and $screenSaver.TimeoutSeconds -gt 0) {
        $findings += "Screen Saver: Enabled with password, timeout $($screenSaver.TimeoutSeconds)s"
        # Screen saver applies to both AC and DC
        if ($screenSaver.TimeoutSeconds -le $MaxTimeoutAC) {
            $isCompliantAC = $true
            $effectiveTimeoutAC = $screenSaver.TimeoutSeconds
            $effectiveSourceAC = "Screen Saver"
        }
        if ($screenSaver.TimeoutSeconds -le $MaxTimeoutDC) {
            $isCompliantDC = $true
            $effectiveTimeoutDC = $screenSaver.TimeoutSeconds
            $effectiveSourceDC = "Screen Saver"
        }
    }
    else {
        if (-not $screenSaver.Enabled) {
            $findings += "Screen Saver: Disabled"
        }
        elseif (-not $screenSaver.PasswordProtected) {
            $findings += "Screen Saver: No password protection"
        }
        elseif ($screenSaver.TimeoutSeconds -eq 0) {
            $findings += "Screen Saver: No timeout configured"
        }
    }
    
    # Check 2: Machine Inactivity Limit (Group Policy) - applies to both AC and DC
    Write-Log "Checking machine inactivity limit..."
    $inactivityLimit = Get-MachineInactivityLimit
    Write-Log "Machine Inactivity Limit Configured: $($inactivityLimit.Configured)"
    Write-Log "Machine Inactivity Limit Timeout: $($inactivityLimit.TimeoutSeconds) seconds"
    
    if ($inactivityLimit.Configured -and $inactivityLimit.TimeoutSeconds -gt 0) {
        $findings += "Machine Inactivity Limit: $($inactivityLimit.TimeoutSeconds)s"
        # GPO setting applies to both AC and DC - takes precedence
        if ($inactivityLimit.TimeoutSeconds -le $MaxTimeoutAC) {
            $isCompliantAC = $true
            $effectiveTimeoutAC = $inactivityLimit.TimeoutSeconds
            $effectiveSourceAC = "Group Policy (Inactivity Limit)"
        }
        if ($inactivityLimit.TimeoutSeconds -le $MaxTimeoutDC) {
            $isCompliantDC = $true
            $effectiveTimeoutDC = $inactivityLimit.TimeoutSeconds
            $effectiveSourceDC = "Group Policy (Inactivity Limit)"
        }
    }
    else {
        $findings += "Machine Inactivity Limit: Not configured"
    }
    
    # Check 3: Group Policy Screen Saver Settings - applies to both AC and DC
    Write-Log "Checking GPO screen saver settings..."
    $gpoScreenSaver = Get-LockOnScreenSaverGPO
    Write-Log "GPO Screen Saver Configured: $($gpoScreenSaver.Configured)"
    Write-Log "GPO Screen Saver Enabled: $($gpoScreenSaver.ScreenSaverEnabled)"
    Write-Log "GPO Password Required: $($gpoScreenSaver.PasswordRequired)"
    Write-Log "GPO Timeout: $($gpoScreenSaver.TimeoutSeconds) seconds"
    
    if ($gpoScreenSaver.Configured -and $gpoScreenSaver.ScreenSaverEnabled -and $gpoScreenSaver.PasswordRequired -and $gpoScreenSaver.TimeoutSeconds -gt 0) {
        $findings += "GPO Screen Saver: Enabled with password, timeout $($gpoScreenSaver.TimeoutSeconds)s"
        # GPO takes precedence over local settings
        if ($gpoScreenSaver.TimeoutSeconds -le $MaxTimeoutAC) {
            $isCompliantAC = $true
            $effectiveTimeoutAC = $gpoScreenSaver.TimeoutSeconds
            $effectiveSourceAC = "Group Policy (Screen Saver)"
        }
        if ($gpoScreenSaver.TimeoutSeconds -le $MaxTimeoutDC) {
            $isCompliantDC = $true
            $effectiveTimeoutDC = $gpoScreenSaver.TimeoutSeconds
            $effectiveSourceDC = "Group Policy (Screen Saver)"
        }
    }
    
    # Check 4: Power Plan Console Lock Timeout - separate AC and DC checks
    Write-Log "Checking power plan lock timeout..."
    $powerPlan = Get-PowerPlanLockTimeout
    Write-Log "Power Plan Lock Configured: $($powerPlan.Configured)"
    Write-Log "Power Plan AC Timeout: $($powerPlan.ACTimeoutSeconds) seconds"
    Write-Log "Power Plan DC Timeout: $($powerPlan.DCTimeoutSeconds) seconds"
    
    if ($powerPlan.Configured) {
        $findings += "Power Plan Console Lock: AC=$($powerPlan.ACTimeoutSeconds)s, DC=$($powerPlan.DCTimeoutSeconds)s"
        
        # Check AC timeout (0 means never, which is non-compliant)
        if ($powerPlan.ACTimeoutSeconds -gt 0 -and $powerPlan.ACTimeoutSeconds -le $MaxTimeoutAC) {
            if ($null -eq $effectiveTimeoutAC -or $powerPlan.ACTimeoutSeconds -lt $effectiveTimeoutAC) {
                $isCompliantAC = $true
                $effectiveTimeoutAC = $powerPlan.ACTimeoutSeconds
                $effectiveSourceAC = "Power Plan (Console Lock)"
            }
        }
        
        # Check DC timeout (0 means never, which is non-compliant)
        if ($powerPlan.DCTimeoutSeconds -gt 0 -and $powerPlan.DCTimeoutSeconds -le $MaxTimeoutDC) {
            if ($null -eq $effectiveTimeoutDC -or $powerPlan.DCTimeoutSeconds -lt $effectiveTimeoutDC) {
                $isCompliantDC = $true
                $effectiveTimeoutDC = $powerPlan.DCTimeoutSeconds
                $effectiveSourceDC = "Power Plan (Console Lock)"
            }
        }
    }
    else {
        $findings += "Power Plan Console Lock: Not configured"
    }
    
    # Output results
    Write-Log "=========================================="
    Write-Log "Findings Summary:"
    foreach ($finding in $findings) {
        Write-Log "  - $finding"
    }
    Write-Log "=========================================="
    
    # Determine overall compliance
    # For desktops (no battery): only AC matters
    # For laptops: both AC and DC must be compliant
    $isOverallCompliant = $false
    
    if ($isLaptop) {
        $isOverallCompliant = $isCompliantAC -and $isCompliantDC
    }
    else {
        # Desktop - only AC matters
        $isOverallCompliant = $isCompliantAC
    }
    
    $timeoutACStr = if ($null -ne $effectiveTimeoutAC) { "$effectiveTimeoutAC s" } else { "Not configured" }
    $timeoutDCStr = if ($null -ne $effectiveTimeoutDC) { "$effectiveTimeoutDC s" } else { "Not configured" }
    Write-Log "AC Compliant: $isCompliantAC (Timeout: $timeoutACStr, Source: $effectiveSourceAC)"
    Write-Log "DC Compliant: $isCompliantDC (Timeout: $timeoutDCStr, Source: $effectiveSourceDC)"
    Write-Log "Device is Laptop: $isLaptop"
    Write-Log "Overall Compliant: $isOverallCompliant"
    
    if ($isOverallCompliant) {
        Write-Log "Security Status: COMPLIANT - Screen lock timeouts are within limits"
        Write-Log "=========================================="
        
        Write-Host ""
        Write-Host "PASS: Screen lock is configured correctly"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Device Type: $(if($isLaptop){'Laptop'}else{'Desktop'})"
        Write-Host ""
        Write-Host "AC (Plugged In):"
        Write-Host "  Timeout: $effectiveTimeoutAC seconds ($([math]::Round($effectiveTimeoutAC / 60, 1)) minutes)"
        Write-Host "  Source: $effectiveSourceAC"
        Write-Host "  Required: <= $MaxTimeoutAC seconds ($($MaxTimeoutAC / 60) minutes)"
        
        if ($isLaptop) {
            Write-Host ""
            Write-Host "DC (Battery):"
            Write-Host "  Timeout: $effectiveTimeoutDC seconds ($([math]::Round($effectiveTimeoutDC / 60, 1)) minutes)"
            Write-Host "  Source: $effectiveSourceDC"
            Write-Host "  Required: <= $MaxTimeoutDC seconds ($($MaxTimeoutDC / 60) minutes)"
        }
        
        exit 0
    }
    else {
        Write-Log "Security Status: NON-COMPLIANT - Screen lock timeouts exceed limits" -Level "WARNING"
        Write-Log "=========================================="
        
        Write-Host ""
        Write-Host "FAIL: Screen lock is not properly configured"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Device Type: $(if($isLaptop){'Laptop'}else{'Desktop'})"
        Write-Host ""
        Write-Host "AC (Plugged In) - Required: <= $MaxTimeoutAC seconds ($($MaxTimeoutAC / 60) minutes)"
        Write-Host "  Status: $(if($isCompliantAC){'COMPLIANT'}else{'NON-COMPLIANT'})"
        if ($null -ne $effectiveTimeoutAC) {
            Write-Host "  Current: $effectiveTimeoutAC seconds ($([math]::Round($effectiveTimeoutAC / 60, 1)) minutes)"
        }
        else {
            Write-Host "  Current: Not configured"
        }
        
        if ($isLaptop) {
            Write-Host ""
            Write-Host "DC (Battery) - Required: <= $MaxTimeoutDC seconds ($($MaxTimeoutDC / 60) minutes)"
            Write-Host "  Status: $(if($isCompliantDC){'COMPLIANT'}else{'NON-COMPLIANT'})"
            if ($null -ne $effectiveTimeoutDC) {
                Write-Host "  Current: $effectiveTimeoutDC seconds ($([math]::Round($effectiveTimeoutDC / 60, 1)) minutes)"
            }
            else {
                Write-Host "  Current: Not configured"
            }
        }
        
        Write-Host ""
        Write-Host "Current Settings:"
        foreach ($finding in $findings) {
            Write-Host "  - $finding"
        }
        Write-Host ""
        Write-Host "Remediation Options:"
        Write-Host "  1. Group Policy: Configure 'Interactive logon: Machine inactivity limit'"
        Write-Host "  2. Group Policy: Enable screen saver with password and appropriate timeout"
        Write-Host "  3. Power Settings: Set 'Console lock display off timeout' - AC: $($MaxTimeoutAC/60)min, DC: $($MaxTimeoutDC/60)min"
        Write-Host "  4. Local Settings: Control Panel > Personalization > Lock Screen > Screen saver settings"
        
        exit 1001
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "FAIL: Screen lock check failed - $_"
    Write-Host "Computer: $env:COMPUTERNAME"
    
    exit 1001
}
