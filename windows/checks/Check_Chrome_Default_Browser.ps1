<#
.SYNOPSIS
    Check if Google Chrome is the default browser on Windows 10/11.
    
.DESCRIPTION
    This monitoring script checks whether Google Chrome is configured as the
    system default browser for HTTP, HTTPS, and HTML files.
    
    Returns:
    - 0 = Chrome is the default browser (PASS)
    - 1001 = Warning - Browser may not be fully set as default
    - 1002 = Critical - Chrome is not the default browser
    
    Check Methods:
    1. Verifies Chrome is installed
    2. Checks registry for http/https protocol handlers
    3. Checks registry for .htm/.html file associations
    4. Verifies Chrome can handle URLs and HTML files
    
    Designed for N-Sight RMM 24x7 monitoring with configurable check intervals.
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Chrome_Default_Browser.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Chrome_Default_Browser.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Chrome_Default_Browser.ps1")

.NOTES
    Author: IT Admin
    Version: 1.1
    Requires: No special privileges (read-only check)
    Platform: Windows 10/11
    
    N-Sight Usage:
    - Deploy as a 24x7 check with 30-60 minute interval
    - Can trigger remediation via Enforce_Chrome_Default_Browser.ps1
    - Exit code 1002 triggers warning in dashboard
    
    Remediation:
    - Trigger: Enforce_Chrome_Default_Browser.ps1
    - Run frequency: On-demand or when check fails
#>

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Check Chrome Default Browser"
$ScriptVersion = "1.2"
$LogFile = "$env:TEMP\CheckChromeDefault_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Exit codes for N-Sight
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# Chrome identifiers
$ChromeProgID = "ChromeHTML"

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

function Get-ChromeInstallStatus {
    <#
    .SYNOPSIS
        Check if Chrome is installed
    #>
    $chromePaths = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    
    foreach ($path in $chromePaths) {
        if (Test-Path $path) {
            try {
                $fileInfo = Get-Item $path
                $version = $fileInfo.VersionInfo.ProductVersion
                return @{ 
                    Installed = $true
                    Path = $path
                    Version = $version
                }
            }
            catch {
                return @{ 
                    Installed = $true
                    Path = $path
                    Version = "Unknown"
                }
            }
        }
    }
    
    return @{ Installed = $false; Path = $null; Version = $null }
}

function Get-RegistryHandler {
    <#
    .SYNOPSIS
        Get (Default) handler for a class; checks HKCU first, then HKLM (Windows merge).
    #>
    param([string]$KeyName)
    $hive = "Software\Classes\$KeyName"
    # HKCU overrides HKLM; if HKCU has a value, use it
    $pathCU = "HKCU:\$hive"
    $pathLM = "HKLM:\$hive"
    foreach ($path in @($pathCU, $pathLM)) {
        if (Test-Path $path) {
            try {
                $val = (Get-ItemProperty -Path $path -Name "(Default)" -ErrorAction SilentlyContinue)."(Default)"
                if ($val) { return $val }
            }
            catch { }
        }
    }
    return $null
}

function Get-DefaultBrowserFromRegistry {
    <#
    .SYNOPSIS
        Check registry to see what's configured as default browser (HKCU + HKLM).
    #>
    Write-Log "Checking registry for default browser configuration (HKCU and HKLM)..."
    
    $findings = @{
        HTTPHandler = $null
        HTTPSHandler = $null
        HTMLHandler = $null
        IsChrome = $false
        PartiallyChrome = $false
    }
    
    $findings.HTTPHandler = Get-RegistryHandler -KeyName "http"
    $findings.HTTPSHandler = Get-RegistryHandler -KeyName "https"
    $findings.HTMLHandler = Get-RegistryHandler -KeyName ".html"
    
    Write-Log "HTTP handler: $(if ($findings.HTTPHandler) { $findings.HTTPHandler } else { '(not set)' })"
    Write-Log "HTTPS handler: $(if ($findings.HTTPSHandler) { $findings.HTTPSHandler } else { '(not set)' })"
    Write-Log "HTML handler: $(if ($findings.HTMLHandler) { $findings.HTMLHandler } else { '(not set)' })"
    
    # Check if Chrome is set as handler
    if ($findings.HTTPHandler -eq $ChromeProgID -and 
        $findings.HTTPSHandler -eq $ChromeProgID -and 
        $findings.HTMLHandler -eq $ChromeProgID) {
        $findings.IsChrome = $true
        Write-Log "All handlers are set to Chrome" -Level "SUCCESS"
    }
    elseif ($findings.HTTPHandler -eq $ChromeProgID -or 
            $findings.HTTPSHandler -eq $ChromeProgID -or 
            $findings.HTMLHandler -eq $ChromeProgID) {
        $findings.PartiallyChrome = $true
        Write-Log "Only some handlers are set to Chrome (partial)" -Level "WARN"
    }
    else {
        Write-Log "Chrome is NOT the default browser in registry" -Level "ERROR"
    }
    
    return $findings
}

function Test-ChromeAsDefaultBrowser {
    <#
    .SYNOPSIS
        Verify Chrome is configured as default browser using assoc command
    #>
    Write-Log "Verifying Chrome as default browser using assoc command..."
    
    $isDefault = $true
    
    # Test protocols
    $protocols = @("http", "https")
    foreach ($protocol in $protocols) {
        try {
            # Capture output and convert to string, handling arrays and trimming whitespace
            $assocOutput = cmd /c "assoc .$protocol" 2>&1
            if ($assocOutput -is [array]) {
                $assoc = ($assocOutput | Where-Object { $_ -notmatch '^[A-Z]:' -and $_ -notmatch '^>' } | Select-Object -First 1).ToString().Trim()
            } else {
                $assoc = $assocOutput.ToString().Trim()
            }
            # Extract just the association part (e.g., ".http=ChromeHTML" from any output)
            if ($assoc -match '\.' + [regex]::Escape($protocol) + '=(.+)') {
                $assocValue = $matches[1].Trim()
            } else {
                $assocValue = $assoc
            }
            Write-Log "assoc .$protocol = $assoc (value: $assocValue)"
            
            if ([string]::IsNullOrWhiteSpace($assocValue)) {
                Write-Log "Protocol $protocol association is empty or not found" -Level "WARN"
                $isDefault = $false
            }
            elseif ($assocValue -notlike "*ChromeHTML*" -and $assocValue -notlike "*Chrome*") {
                Write-Log "Protocol $protocol is NOT associated with Chrome (found: $assocValue)" -Level "WARN"
                $isDefault = $false
            }
            else {
                Write-Log "Protocol $protocol is correctly associated with Chrome" -Level "SUCCESS"
            }
        }
        catch {
            $errorMsg = $_.Exception.Message
            Write-Log "Could not test protocol ${protocol}: $errorMsg" -Level "WARN"
            $isDefault = $false
        }
    }
    # Test file types
    $fileTypes = @("htm", "html")
    foreach ($fileType in $fileTypes) {
        try {
            # Capture output and convert to string, handling arrays and trimming whitespace
            $assocOutput = cmd /c "assoc .$fileType" 2>&1
            if ($assocOutput -is [array]) {
                $assoc = ($assocOutput | Where-Object { $_ -notmatch '^[A-Z]:' -and $_ -notmatch '^>' } | Select-Object -First 1).ToString().Trim()
            } else {
                $assoc = $assocOutput.ToString().Trim()
            }
            # Extract just the association part (e.g., ".html=ChromeHTML" from any output)
            if ($assoc -match '\.' + [regex]::Escape($fileType) + '=(.+)') {
                $assocValue = $matches[1].Trim()
            } else {
                $assocValue = $assoc
            }
            Write-Log "assoc .$fileType = $assoc (value: $assocValue)"
            
            if ([string]::IsNullOrWhiteSpace($assocValue)) {
                Write-Log "File type .$fileType association is empty or not found" -Level "WARN"
                $isDefault = $false
            }
            elseif ($assocValue -notlike "*ChromeHTML*" -and $assocValue -notlike "*Chrome*") {
                Write-Log "File type .$fileType is NOT associated with Chrome (found: $assocValue)" -Level "WARN"
                $isDefault = $false
            }
            else {
                Write-Log "File type .$fileType is correctly associated with Chrome" -Level "SUCCESS"
            }
        }
        catch {
            $errorMsg = $_.Exception.Message
            Write-Log "Could not test file type ${fileType}: $errorMsg" -Level "WARN"
            $isDefault = $false
        }
    }
    Write-Log "Test-ChromeAsDefaultBrowser returning: $isDefault"
    return $isDefault
}

function Write-Summary {
    <#
    .SYNOPSIS
        Write summary for N-Sight dashboard
    #>
    param(
        [ValidateSet("OK", "WARNING", "CRITICAL")]
        [string]$Status,
        [string]$Message
    )
    Write-Host ""
    Write-Host "${Status}: $Message"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "$ScriptName v$ScriptVersion"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $env:USERNAME"
Write-Log "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log ""

try {
    # Step 1: Check if Chrome is installed
    Write-Log "Step 1: Checking Chrome installation..."
    $chromeStatus = Get-ChromeInstallStatus
    
    if (-not $chromeStatus.Installed) {
        Write-Log "Chrome is NOT installed" -Level "ERROR"
        Write-Summary -Status "CRITICAL" -Message "Chrome is not installed on this computer"
        Write-Host "Install Chrome using Install_Chrome.ps1"
        exit $EXIT_CRITICAL
    }
    
    Write-Log "Chrome installed: v$($chromeStatus.Version)"
    Write-Log ""
    
    # Step 2: Check registry settings
    Write-Log "Step 2: Checking default browser registry settings..."
    $regFindings = Get-DefaultBrowserFromRegistry
    Write-Log ""
    
    # Step 3: Verify using assoc command
    Write-Log "Step 3: Verifying associations with assoc command..."
    $assocTest = Test-ChromeAsDefaultBrowser
    Write-Log "Assoc test result: $assocTest (type: $($assocTest.GetType().Name))"
    Write-Log ""
    
    # Step 4: Determine overall status
    # assoc reflects actual OS behavior (merged HKCU/HKLM); treat it as authoritative when it shows Chrome for all.
    Write-Log "Step 4: Determining overall status..."
    
    if ($assocTest) {
        # Associations show Chrome for http, https, .htm, .html - system will use Chrome
        Write-Log "Chrome is the default browser (verified via associations)" -Level "SUCCESS"
        Write-Summary -Status "OK" -Message "Chrome v$($chromeStatus.Version) is the default browser"
        Write-Host "All protocols and file types are set to open in Chrome"
        if (-not $regFindings.IsChrome) {
            Write-Log "Note: Registry (HKCU/HKLM) did not show Chrome for all handlers; associations take precedence." -Level "INFO"
        }
        exit $EXIT_SUCCESS
    }
    elseif ($regFindings.IsChrome) {
        Write-Log "Registry shows Chrome but associations do not (unusual)" -Level "WARN"
        Write-Summary -Status "WARNING" -Message "Chrome is set in registry but associations differ - run Enforce_Chrome_Default_Browser.ps1 to align"
        Write-Host "HTTP: $($regFindings.HTTPHandler)"
        Write-Host "HTTPS: $($regFindings.HTTPSHandler)"
        Write-Host "HTML: $($regFindings.HTMLHandler)"
        exit $EXIT_WARNING
    }
    elseif ($regFindings.PartiallyChrome -or $regFindings.HTTPHandler -eq $ChromeProgID -or $regFindings.HTTPSHandler -eq $ChromeProgID -or $regFindings.HTMLHandler -eq $ChromeProgID) {
        Write-Log "Chrome is partially configured as default browser (WARNING)" -Level "WARN"
        Write-Summary -Status "WARNING" -Message "Chrome is partially set as default - some settings may need adjustment"
        Write-Host "HTTP: $(if ($regFindings.HTTPHandler) { $regFindings.HTTPHandler } else { '(not set)' })"
        Write-Host "HTTPS: $(if ($regFindings.HTTPSHandler) { $regFindings.HTTPSHandler } else { '(not set)' })"
        Write-Host "HTML: $(if ($regFindings.HTMLHandler) { $regFindings.HTMLHandler } else { '(not set)' })"
        exit $EXIT_WARNING
    }
    else {
        Write-Log "Chrome is NOT the default browser (CRITICAL)" -Level "ERROR"
        Write-Summary -Status "CRITICAL" -Message "Chrome is NOT the default browser"
        Write-Host "HTTP Handler: $(if ($regFindings.HTTPHandler) { $regFindings.HTTPHandler } else { '(not set)' })"
        Write-Host "HTTPS Handler: $(if ($regFindings.HTTPSHandler) { $regFindings.HTTPSHandler } else { '(not set)' })"
        Write-Host "HTML Handler: $(if ($regFindings.HTMLHandler) { $regFindings.HTMLHandler } else { '(not set)' })"
        Write-Host ""
        Write-Host "Run Enforce_Chrome_Default_Browser.ps1 to fix this"
        exit $EXIT_CRITICAL
    }
}
catch {
    Write-Log "Script error: $_" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Check failed with error"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Check completed"
}
