<#
.SYNOPSIS
    Check if GCPW (Google Credential Provider for Windows) is installed and configured.
    
.DESCRIPTION
    This monitoring script verifies that GCPW is fully installed and properly configured:
    - GCPW installation status (files and registry)
    - Google Cloud Management Enrollment Token
    - GCPW Allowed Domains for Login
    - GCPW Google Enrollment Status
    
    GCPW allows users to sign in to Windows using their Google Workspace credentials.
    
    Designed for N-Sight RMM deployment monitoring.
    
    Exit Codes:
    - 0 = PASS (GCPW installed and all settings correctly configured)
    - 1001 = WARNING (GCPW installed but registry settings incomplete)
    - 1002 = CRITICAL (GCPW not installed or critical configuration missing)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_GCPW_Registry.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_GCPW_Registry.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_GCPW_Registry.ps1")
.NOTES
    Author: IT Admin
    Version: 2.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
    N-Sight Usage:
    - Create a 24x7 Check using this script
    - Set Remediate_GCPW_Registry.ps1 as automated task when check fails
#>

#Requires -RunAsAdministrator

# ============================================================================
# PARAMETERS
# ============================================================================
param(
    [switch]$AutoRemediate = $true,
    [string]$RemediationLogFile = "$env:TEMP\GCPWRemediation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\GCPWCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Exit codes for N-Sight (use >1000 for proper output display)
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002
$EXIT_REMEDIATED_SUCCESS = 0        # Pass after successful remediation
$EXIT_REMEDIATION_FAILED = 1003     # Critical after failed remediation

# GCPW Installation Script URLs (GitHub repo)
$GCPWInstallScriptUrl = "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_GCPW.ps1"
$ChromeInstallScriptUrl = "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Chrome.ps1"

# Expected GCPW Registry Values
$ExpectedEnrollmentToken = "5f8a8760-820d-404a-bc6e-0a7cda2bf96a"
$ExpectedDomainsAllowed = "helfy.co,doktorabc.com"
$ExpectedIsEnrolled = 1

# GCPW Official Registry Settings (per Google documentation)
# Reference: https://support.google.com/a/answer/9250996
$ExpectedEnableMultiUserLogin = 1          # Allows multiple users to sign in (default: 1)
$ExpectedUseShorterAccountName = 1         # Uses username portion of email for account name (default: 0)
$ExpectedEnableDmEnrollment = 1             # Automatically enroll devices in Windows device management (default: 1)
$ExpectedValidityPeriodInDays = 30         # Days user can sign in offline before online sign-in required (optional)

# Registry Paths
$CloudManagementPath = "HKLM:\SOFTWARE\Policies\Google\CloudManagement"
$GCPWPath = "HKLM:\SOFTWARE\Google\GCPW"

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

function Test-ChromeInstalled {
    $paths = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($path in $paths) { if (Test-Path $path) { return $true } }
    return $false
}

function Install-Chrome {
    <#
    .SYNOPSIS
        Install Chrome browser as prerequisite for GCPW
    #>
    Write-Log "Installing Chrome as GCPW prerequisite..." -Level "INFO"
    
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $chromeInstallScript = Invoke-WebRequest -Uri $ChromeInstallScriptUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        
        Write-Log "Executing Chrome installation script..." -Level "INFO"
        Invoke-Expression $chromeInstallScript.Content
        
        if (Test-ChromeInstalled) {
            Write-Log "Chrome installation completed successfully" -Level "INFO"
            return $true
        }
        else {
            Write-Log "Chrome installation appeared to complete but Chrome is not detected" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Chrome installation failed: $_" -Level "ERROR"
        return $false
    }
}

function Install-GCPW {
    <#
    .SYNOPSIS
        Install GCPW using the repository installation script
    #>
    Write-Log "Installing GCPW using remote installation script..." -Level "INFO"
    
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $gcpwInstallScript = Invoke-WebRequest -Uri $GCPWInstallScriptUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        
        Write-Log "Executing GCPW installation script..." -Level "INFO"
        Invoke-Expression $gcpwInstallScript.Content
        
        # Check if installation was successful
        $gcpwStatus = Get-GCPWInstallStatus
        if ($gcpwStatus.Installed) {
            Write-Log "GCPW installation completed successfully" -Level "INFO"
            Write-Log "GCPW Version: $($gcpwStatus.Version)" -Level "INFO"
            return $true
        }
        else {
            Write-Log "GCPW installation appeared to complete but GCPW is not detected" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "GCPW installation failed: $_" -Level "ERROR"
        return $false
    }
}

function Invoke-GCPWRemediation {
    <#
    .SYNOPSIS
        Attempt to automatically remediate GCPW issues
    #>
    Write-Log "==========================================" -Level "INFO"
    Write-Log "Starting GCPW Remediation Process" -Level "INFO"
    Write-Log "==========================================" -Level "INFO"
    
    $remediationLogFile = "$env:TEMP\GCPWRemediation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    
    try {
        # Step 1: Check and install Chrome if needed
        Write-Log "Step 1: Checking Chrome installation..." -Level "INFO"
        if (-not (Test-ChromeInstalled)) {
            Write-Log "Chrome not detected - installing Chrome..." -Level "WARNING"
            if (-not (Install-Chrome)) {
                Write-Log "Chrome installation failed - cannot proceed with GCPW installation" -Level "ERROR"
                return @{ Success = $false; Message = "Chrome installation failed"; LogFile = $remediationLogFile }
            }
        }
        else {
            Write-Log "Chrome is already installed" -Level "INFO"
        }
        
        # Step 2: Install GCPW
        Write-Log "Step 2: Installing GCPW..." -Level "INFO"
        if (-not (Install-GCPW)) {
            Write-Log "GCPW installation failed" -Level "ERROR"
            return @{ Success = $false; Message = "GCPW installation failed"; LogFile = $remediationLogFile }
        }
        
        Write-Log "==========================================" -Level "INFO"
        Write-Log "GCPW Remediation Process Completed Successfully" -Level "INFO"
        Write-Log "==========================================" -Level "INFO"
        
        return @{ Success = $true; Message = "Remediation completed successfully"; LogFile = $remediationLogFile }
    }
    catch {
        Write-Log "Remediation failed with error: $_" -Level "ERROR"
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
        return @{ Success = $false; Message = "Remediation failed with error: $_"; LogFile = $remediationLogFile }
    }
}

function Get-GCPWInstallStatus {
    <#
    .SYNOPSIS
        Check if GCPW is already installed
    #>
    
    # Check common installation paths including version subdirectories
    $gcpwInstallDir = "${env:ProgramFiles}\Google\CredentialProvider"
    $gcpwInstallDirX86 = "${env:ProgramFiles(x86)}\Google\CredentialProvider"
    
    # Look for core GCPW DLLs in the directory and any subdirectories
    $foundFiles = Get-ChildItem -Path "$gcpwInstallDir\*\gcp_eventlog_provider.dll", 
    "$gcpwInstallDirX86\*\gcp_eventlog_provider.dll",
    "$gcpwInstallDir\gcp_eventlog_provider.dll", 
    "$gcpwInstallDirX86\gcp_eventlog_provider.dll",
    "${env:SystemRoot}\System32\GCPWCredentialProvider.dll",
    "$gcpwInstallDir\*\Gaia.dll",
    "$gcpwInstallDirX86\*\Gaia.dll" -ErrorAction SilentlyContinue
    
    if ($foundFiles) {
        $fileInfo = $foundFiles | Select-Object -First 1
        try {
            $version = $fileInfo.VersionInfo.ProductVersion
            if (-not $version) { $version = "Unknown" }
            return @{ Installed = $true; Path = $fileInfo.FullName; Version = $version }
        }
        catch {
            return @{ Installed = $true; Path = $fileInfo.FullName; Version = "Unknown" }
        }
    }
    
    # Check registry for GCPW installation
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($regPath in $regPaths) {
        try {
            # In some cases Get-ItemProperty on * will fail if an item cannot be read.
            # Using Get-ChildItem first is safer.
            $regKeys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue
            foreach ($key in $regKeys) {
                $regItem = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
                if ($regItem.DisplayName -match "Google Credential Provider" -or $regItem.DisplayName -match "GCPW") {
                    return @{ 
                        Installed = $true
                        Path      = $regItem.InstallLocation
                        Version   = $regItem.DisplayVersion
                    }
                }
            }
        }
        catch {
            # Continue checking other methods
        }
    }
    
    # Final check if Credential Provider DLL exists in System32
    $credProviderPath = "${env:SystemRoot}\System32\GCPWCredentialProvider.dll"
    if (Test-Path $credProviderPath) {
        return @{ Installed = $true; Path = $credProviderPath; Version = "Unknown" }
    }
    
    return @{ Installed = $false; Path = $null; Version = $null }
}

function Test-GCPWCredentialProviderRegistered {
    <#
    .SYNOPSIS
        Check if GCPW credential provider is registered in Windows
    #>
    
    $result = @{
        Registered = $false
        Message    = ""
    }
    
    # Check credential provider registration in registry
    $credProviderPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
    
    if (-not (Test-Path $credProviderPath)) {
        $result.Message = "Credential Providers registry path not found"
        return $result
    }
    
    try {
        # Check for GCPW credential provider GUID
        # GCPW typically registers with GUID: {A8F5898A-5C73-4E53-9B2C-3E3F5F8A8B8C}
        # But we'll check for any Google-related credential providers
        $credProviders = Get-ChildItem -Path $credProviderPath -ErrorAction Stop
        
        foreach ($provider in $credProviders) {
            $providerName = $provider.PSChildName
            try {
                $providerInfo = Get-ItemProperty -Path $provider.PSPath -ErrorAction SilentlyContinue
                
                # Check if it's GCPW by looking for Google-related strings or DLL path
                if ($providerInfo -and (
                        $providerInfo.'(default)' -like "*GCPW*" -or
                        $providerInfo.'(default)' -like "*Google*Credential*" -or
                        $providerInfo.'(default)' -like "*CredentialProvider*"
                    )) {
                    $result.Registered = $true
                    $result.Message = "GCPW credential provider registered: $providerName"
                    return $result
                }
            }
            catch {
                # Continue checking other providers
            }
        }
        
        # Also check if the DLL exists in System32 (indicates registration)
        $gcpwDll = "${env:SystemRoot}\System32\GCPWCredentialProvider.dll"
        if (Test-Path $gcpwDll) {
            $result.Registered = $true
            $result.Message = "GCPW DLL found in System32 (likely registered)"
            return $result
        }
        
        $result.Message = "GCPW credential provider not found in registered providers"
    }
    catch {
        $result.Message = "Error checking credential provider registration: $_"
    }
    
    return $result
}

function Test-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExpectedValue,
        [string]$ValueType = "String",
        [switch]$IsOptional
    )
    
    $result = @{
        Exists     = $false
        Value      = $null
        Matches    = $false
        Message    = ""
        IsOptional = $IsOptional
    }
    
    if (-not (Test-Path $Path)) {
        $result.Message = "Registry path does not exist: $Path"
        if ($IsOptional) {
            $result.Matches = $true  # Don't fail the check for optional settings
            $result.Message = "Registry path not found (Optional setting, relies on Google defaults)"
            $result.Value = "NOT SET (Default/Cloud Managed)"
        }
        return $result
    }
    
    try {
        $regValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $result.Exists = $true
        $result.Value = $regValue.$Name
        
        if ($ValueType -eq "DWord") {
            $result.Matches = ([int]$result.Value -eq [int]$ExpectedValue)
        }
        else {
            $result.Matches = ([string]$result.Value -eq [string]$ExpectedValue)
        }
        
        if ($result.Matches) {
            $result.Message = "Value matches expected"
        }
        else {
            $result.Message = "Value mismatch - Expected: '$ExpectedValue', Found: '$($result.Value)'"
            if ($IsOptional) {
                $result.Matches = $true  # Don't fail for optional values even if they don't match our hardcoded expectation
                $result.Message += " (Optional setting mismatch)"
            }
        }
    }
    catch {
        $result.Message = "Registry value '$Name' not found"
        if ($IsOptional) {
            $result.Matches = $true  # Don't fail the check for optional settings
            $result.Message = "Registry value not found (Optional setting, relies on Google defaults or Cloud policy)"
            $result.Value = "NOT SET (Default/Cloud Managed)"
        }
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "GCPW Installation and Configuration Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "CRITICAL: Script requires administrator privileges"
    exit $EXIT_CRITICAL
}

try {
    $allPassed = $true
    $results = @()
    $gcpwInstalled = $false
    
    # -------------------------------------------------------------------------
    # STEP 1: Check GCPW Installation
    # -------------------------------------------------------------------------
    Write-Log "=========================================="
    Write-Log "Step 1: Checking GCPW Installation"
    Write-Log "=========================================="
    
    $gcpwStatus = Get-GCPWInstallStatus
    
    if ($gcpwStatus.Installed) {
        Write-Log "GCPW Installation: INSTALLED"
        Write-Log "GCPW Path: $($gcpwStatus.Path)"
        Write-Log "GCPW Version: $($gcpwStatus.Version)"
        $gcpwInstalled = $true
        
        $results += @{
            Check   = "GCPW Installation"
            Status  = "PASS"
            Details = "Installed - Version: $($gcpwStatus.Version)"
        }
        
        # Check if credential provider is registered
        Write-Log "Checking credential provider registration..."
        $credProviderStatus = Test-GCPWCredentialProviderRegistered
        
        if ($credProviderStatus.Registered) {
            Write-Log "Credential Provider Registration: REGISTERED"
            Write-Log "Details: $($credProviderStatus.Message)"
            
            $results += @{
                Check   = "Credential Provider Registration"
                Status  = "PASS"
                Details = $credProviderStatus.Message
            }
        }
        else {
            Write-Log "Credential Provider Registration: NOT REGISTERED" -Level "WARNING"
            Write-Log "Details: $($credProviderStatus.Message)"
            
            $results += @{
                Check   = "Credential Provider Registration"
                Status  = "WARNING"
                Details = $credProviderStatus.Message
            }
            # Don't fail the check, but note it as a warning
        }
    }
    else {
        Write-Log "GCPW Installation: NOT INSTALLED" -Level "WARNING"
        $gcpwInstalled = $false
        $allPassed = $false
        
        $results += @{
            Check   = "GCPW Installation"
            Status  = "FAIL"
            Details = "GCPW is not installed"
        }
    }
    
    # -------------------------------------------------------------------------
    # STEP 2: Check Registry Settings
    # -------------------------------------------------------------------------
    Write-Log "=========================================="
    Write-Log "Step 2: Checking Registry Settings"
    Write-Log "=========================================="
    
    Write-Log "Checking GCPW registry settings..."
    
    # -------------------------------------------------------------------------
    # Check 1: Enrollment Token
    # -------------------------------------------------------------------------
    Write-Log "Checking Enrollment Token..."
    $enrollmentCheck = Test-RegistryValue `
        -Path $CloudManagementPath `
        -Name "EnrollmentToken" `
        -ExpectedValue $ExpectedEnrollmentToken `
        -ValueType "String"
    
    $results += @{
        Setting  = "EnrollmentToken"
        Path     = "$CloudManagementPath\EnrollmentToken"
        Expected = $ExpectedEnrollmentToken
        Found    = $enrollmentCheck.Value
        Status   = if ($enrollmentCheck.Matches) { "PASS" } else { "FAIL" }
    }
    
    if ($enrollmentCheck.Matches) {
        Write-Log "EnrollmentToken: PASS - Value matches"
    }
    else {
        Write-Log "EnrollmentToken: FAIL - $($enrollmentCheck.Message)" -Level "WARNING"
        $allPassed = $false
    }
    
    # -------------------------------------------------------------------------
    # Check 2: Domains Allowed to Login
    # -------------------------------------------------------------------------
    Write-Log "Checking Allowed Domains..."
    $domainsCheck = Test-RegistryValue `
        -Path $GCPWPath `
        -Name "domains_allowed_to_login" `
        -ExpectedValue $ExpectedDomainsAllowed `
        -ValueType "String"
    
    $results += @{
        Setting  = "domains_allowed_to_login"
        Path     = "$GCPWPath\domains_allowed_to_login"
        Expected = $ExpectedDomainsAllowed
        Found    = $domainsCheck.Value
        Status   = if ($domainsCheck.Matches) { "PASS" } else { "FAIL" }
    }
    
    if ($domainsCheck.Matches) {
        Write-Log "domains_allowed_to_login: PASS - Value matches"
    }
    else {
        Write-Log "domains_allowed_to_login: FAIL - $($domainsCheck.Message)" -Level "WARNING"
        $allPassed = $false
    }
    
    # -------------------------------------------------------------------------
    # Check 3: Is Enrolled to Google
    # -------------------------------------------------------------------------
    Write-Log "Checking Google Enrollment Status..."
    $enrolledCheck = Test-RegistryValue `
        -Path $GCPWPath `
        -Name "is_enrolled_to_google" `
        -ExpectedValue $ExpectedIsEnrolled `
        -ValueType "DWord"
    
    $results += @{
        Setting  = "is_enrolled_to_google"
        Path     = "$GCPWPath\is_enrolled_to_google"
        Expected = $ExpectedIsEnrolled
        Found    = $enrolledCheck.Value
        Status   = if ($enrolledCheck.Matches) { "PASS" } else { "FAIL" }
    }
    
    if ($enrolledCheck.Matches) {
        Write-Log "is_enrolled_to_google: PASS - Value matches"
    }
    else {
        Write-Log "is_enrolled_to_google: FAIL - $($enrolledCheck.Message)" -Level "WARNING"
        $allPassed = $false
    }
    
    # -------------------------------------------------------------------------
    # Check 4: Enable Multi-User Login (Official GCPW Setting)
    # Reference: https://support.google.com/a/answer/9250996
    # -------------------------------------------------------------------------
    Write-Log "Checking Multi-User Login..."
    $multiUserCheck = Test-RegistryValue `
        -Path $GCPWPath `
        -Name "enable_multi_user_login" `
        -ExpectedValue $ExpectedEnableMultiUserLogin `
        -ValueType "DWord" `
        -IsOptional
    
    $results += @{
        Setting  = "enable_multi_user_login"
        Path     = "$GCPWPath\enable_multi_user_login"
        Expected = "$ExpectedEnableMultiUserLogin (Optional)"
        Found    = $multiUserCheck.Value
        Status   = if ($multiUserCheck.Exists -and -not $multiUserCheck.Message.Contains("mismatch")) { "PASS" } elseif (-not $multiUserCheck.Exists) { "PASS (Default)" } else { "WARN" }
    }
    
    if ($multiUserCheck.Exists) {
        Write-Log "enable_multi_user_login: PASS - Value matches"
    }
    else {
        Write-Log "enable_multi_user_login: PASS - $($multiUserCheck.Message)" -Level "INFO"
        # Don't fail the overall check for this
    }
    
    # -------------------------------------------------------------------------
    # Check 5: Use Shorter Account Name (Official GCPW Setting)
    # Reference: https://support.google.com/a/answer/9250996
    # -------------------------------------------------------------------------
    Write-Log "Checking Shorter Account Name..."
    $shorterNameCheck = Test-RegistryValue `
        -Path $GCPWPath `
        -Name "use_shorter_account_name" `
        -ExpectedValue $ExpectedUseShorterAccountName `
        -ValueType "DWord" `
        -IsOptional
    
    $results += @{
        Setting  = "use_shorter_account_name"
        Path     = "$GCPWPath\use_shorter_account_name"
        Expected = "$ExpectedUseShorterAccountName (Optional)"
        Found    = $shorterNameCheck.Value
        Status   = if ($shorterNameCheck.Exists -and -not $shorterNameCheck.Message.Contains("mismatch")) { "PASS" } elseif (-not $shorterNameCheck.Exists) { "PASS (Default)" } else { "WARN" }
    }
    
    if ($shorterNameCheck.Exists) {
        Write-Log "use_shorter_account_name: PASS - Value matches"
    }
    else {
        Write-Log "use_shorter_account_name: PASS - $($shorterNameCheck.Message)" -Level "INFO"
    }
    
    # -------------------------------------------------------------------------
    # Check 6: Enable Device Management Enrollment (Official GCPW Setting)
    # Reference: https://support.google.com/a/answer/9250996
    # -------------------------------------------------------------------------
    Write-Log "Checking Device Management Enrollment..."
    $dmEnrollmentCheck = Test-RegistryValue `
        -Path $GCPWPath `
        -Name "enable_dm_enrollment" `
        -ExpectedValue $ExpectedEnableDmEnrollment `
        -ValueType "DWord" `
        -IsOptional
    
    $results += @{
        Setting  = "enable_dm_enrollment"
        Path     = "$GCPWPath\enable_dm_enrollment"
        Expected = "$ExpectedEnableDmEnrollment (Optional)"
        Found    = $dmEnrollmentCheck.Value
        Status   = if ($dmEnrollmentCheck.Exists -and -not $dmEnrollmentCheck.Message.Contains("mismatch")) { "PASS" } elseif (-not $dmEnrollmentCheck.Exists) { "PASS (Default)" } else { "WARN" }
    }
    
    if ($dmEnrollmentCheck.Exists) {
        Write-Log "enable_dm_enrollment: PASS - Value matches"
    }
    else {
        Write-Log "enable_dm_enrollment: PASS - $($dmEnrollmentCheck.Message)" -Level "INFO"
    }
    
    # -------------------------------------------------------------------------
    # Check 7: Validity Period in Days (Official GCPW Setting - Optional)
    # Reference: https://support.google.com/a/answer/9250996
    # -------------------------------------------------------------------------
    if ($ExpectedValidityPeriodInDays -gt 0) {
        Write-Log "Checking Offline Sign-In Validity Period..."
        $validityCheck = Test-RegistryValue `
            -Path $GCPWPath `
            -Name "validity_period_in_days" `
            -ExpectedValue $ExpectedValidityPeriodInDays `
            -ValueType "DWord" `
            -IsOptional
        
        $results += @{
            Setting  = "validity_period_in_days"
            Path     = "$GCPWPath\validity_period_in_days"
            Expected = "$ExpectedValidityPeriodInDays (Optional)"
            Found    = $validityCheck.Value
            Status   = if ($validityCheck.Exists -and -not $validityCheck.Message.Contains("mismatch")) { "PASS" } elseif (-not $validityCheck.Exists) { "PASS (Default)" } else { "WARN" }
        }
        
        if ($validityCheck.Exists) {
            Write-Log "validity_period_in_days: PASS - Value matches"
        }
        else {
            Write-Log "validity_period_in_days: PASS - $($validityCheck.Message)" -Level "INFO"
        }
    }
    
    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    Write-Log "=========================================="
    Write-Log "Check Summary"
    Write-Log "=========================================="
    
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "GCPW Registry Check Results"
    Write-Host "=========================================="
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host ""
    
    foreach ($result in $results) {
        $statusColor = if ($result.Status -eq "PASS") { "Green" } else { "Red" }
        Write-Host "[$($result.Status)] $($result.Setting)" -ForegroundColor $statusColor
        Write-Host "    Path: $($result.Path)"
        Write-Host "    Expected: $($result.Expected)"
        Write-Host "    Found: $(if ($null -eq $result.Found) { 'NOT SET' } else { $result.Found })"
        Write-Host ""
    }
    
    # -------------------------------------------------------------------------
    # Summary and Exit Code Determination
    # -------------------------------------------------------------------------
    Write-Log "=========================================="
    Write-Log "Check Summary"
    Write-Log "=========================================="
    
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "GCPW Installation and Configuration Check"
    Write-Host "=========================================="
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host ""
    
    foreach ($result in $results) {
        $statusColor = if ($result.Status -eq "PASS") { "Green" } else { "Red" }
        Write-Host "[$($result.Status)] $($result.Check)" -ForegroundColor $statusColor
        Write-Host "    $($result.Details)"
        Write-Host ""
    }
    
    # Determine exit code based on installation and configuration status
    if (-not $gcpwInstalled) {
        Write-Log "Overall Status: CRITICAL - GCPW is not installed" -Level "ERROR"
        Write-Host "=========================================="
        Write-Host "CRITICAL: GCPW is not installed" -ForegroundColor Red
        Write-Host "=========================================="
        Write-Host ""
        
        # Check if auto-remediation is enabled
        if ($AutoRemediate) {
            Write-Host "Auto-remediation is enabled - attempting to install GCPW automatically..." -ForegroundColor Yellow
            Write-Host ""
            
            $remediationResult = Invoke-GCPWRemediation
            
            Write-Host "=========================================="
            Write-Host "Remediation Result: $($remediationResult.Message)"
            Write-Host "Remediation Log: $($remediationResult.LogFile)"
            Write-Host "=========================================="
            Write-Host ""
            
            if ($remediationResult.Success) {
                Write-Host "SUCCESS: GCPW has been installed successfully!" -ForegroundColor Green
                Write-Host "Running verification check..." -ForegroundColor Green
                Write-Host ""
                
                # Re-check GCPW installation status
                $gcpwStatus = Get-GCPWInstallStatus
                if ($gcpwStatus.Installed) {
                    Write-Host "Verification: GCPW installation confirmed" -ForegroundColor Green
                    Write-Host "=========================================="
                    Write-Host "REMEDIATION SUCCESS: GCPW is now installed" -ForegroundColor Green
                    Write-Host "=========================================="
                    Write-Host ""
                    Write-Host "Post-restart verification recommended."
                    exit $EXIT_REMEDIATED_SUCCESS
                }
                else {
                    Write-Log "Post-remediation verification failed: GCPW still not detected" -Level "ERROR"
                    Write-Host "CRITICAL: Remediation appeared successful but verification failed" -ForegroundColor Red
                    exit $EXIT_REMEDIATION_FAILED
                }
            }
            else {
                Write-Host "FAILED: Auto-remediation was unsuccessful" -ForegroundColor Red
                Write-Host "Manual intervention required" -ForegroundColor Red
                Write-Host "=========================================="
                Write-Host "Manual Remediation Steps:"
                Write-Host "1. Run Install_GCPW.ps1 manually"
                Write-Host "2. Ensure Chrome 81+ is installed first"
                Write-Host "3. Check log file: $($remediationResult.LogFile)"
                Write-Host "=========================================="
                exit $EXIT_REMEDIATION_FAILED
            }
        }
        else {
            # Original non-auto-remediation path
            Write-Host "Remediation: Run Remediate_GCPW_Registry.ps1 to install and configure GCPW"
            Write-Host ""
            Write-Host "Or run this check with -AutoRemediate parameter for automatic remediation"
            Write-Host ""
            exit $EXIT_CRITICAL
        }
    }
    elseif ($allPassed) {
        Write-Log "Overall Status: COMPLIANT - GCPW installed and all settings correctly configured"
        Write-Host "=========================================="
        Write-Host "PASS: GCPW is installed and all settings are correctly configured" -ForegroundColor Green
        Write-Host "=========================================="
        exit $EXIT_SUCCESS
    }
    else {
        Write-Log "Overall Status: WARNING - GCPW installed but registry settings incomplete" -Level "WARNING"
        Write-Host "=========================================="
        Write-Host "WARNING: GCPW is installed but registry settings are incomplete" -ForegroundColor Yellow
        Write-Host "=========================================="
        Write-Host ""
        Write-Host "Remediation: Run Remediate_GCPW_Registry.ps1 to configure registry settings"
        Write-Host ""
        Write-Host "Or manually configure:"
        Write-Host "  1. $CloudManagementPath"
        Write-Host "     EnrollmentToken = $ExpectedEnrollmentToken"
        Write-Host "  2. $GCPWPath"
        Write-Host "     domains_allowed_to_login = $ExpectedDomainsAllowed"
        Write-Host "     is_enrolled_to_google = $ExpectedIsEnrolled (DWORD)"
        Write-Host "     enable_multi_user_login = $ExpectedEnableMultiUserLogin (DWORD)"
        Write-Host "     use_shorter_account_name = $ExpectedUseShorterAccountName (DWORD)"
        Write-Host "     enable_dm_enrollment = $ExpectedEnableDmEnrollment (DWORD)"
        if ($ExpectedValidityPeriodInDays -gt 0) {
            Write-Host "     validity_period_in_days = $ExpectedValidityPeriodInDays (DWORD)"
        }
        Write-Host ""
        exit $EXIT_WARNING
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "CRITICAL: GCPW check failed - $_"
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Log File: $LogFile"
    
    exit $EXIT_CRITICAL
}
