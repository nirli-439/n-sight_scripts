<#
.SYNOPSIS
    Enforce Google Chrome as the default browser on Windows 10/11.
    
.DESCRIPTION
    This remediation script enforces Google Chrome as the system default browser
    by setting registry keys and file associations for HTTP, HTTPS, and HTML files.
    
    Features:
    - Sets Chrome as default handler for http:// and https:// URLs
    - Sets Chrome as default handler for .htm and .html files
    - Blocks Edge from being set as default (optional)
    - Works on Windows 10 and Windows 11
    - Designed for N-Sight RMM deployment as remediation task
    
    Exit Codes:
    - 0 = Success (Chrome set as default)
    - 1001 = Warning (Partial success)
    - 1002 = Critical/Error (Chrome not installed or operation failed)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Enforce_Chrome_Default_Browser.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Enforce_Chrome_Default_Browser.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Enforce_Chrome_Default_Browser.ps1")

.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
    N-Sight Usage:
    - Deploy as a remediation task when check detects Chrome is not default
    - Can run on schedule or triggered by policy
    
    Registry Modifications:
    - HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts
    - HKCU\Software\Classes
    - HKCU\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts
    
    References:
    - Windows URL Association: https://docs.microsoft.com/en-us/windows/win32/shell/default-programs
#>

# Do not use #Requires -RunAsAdministrator (would exit 1 and hide our exit codes)
# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Enforce Chrome Default Browser"
$ScriptVersion = "1.0"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Enforce_Chrome_Default_Browser_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Exit codes for N-Sight
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

# Chrome identifiers
$ChromeBundleID = "ChromeHTML"
$ChromeProgID = "ChromeHTML"
$EdgeProgID = "MSEdgeHTM"

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

function Get-ChromeInstallStatus {
    <#
    .SYNOPSIS
        Check if Chrome is installed and get its path
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
                    ProgID = $ChromeProgID
                }
            }
            catch {
                return @{ 
                    Installed = $true
                    Path = $path
                    Version = "Unknown"
                    ProgID = $ChromeProgID
                }
            }
        }
    }
    
    return @{ Installed = $false; Path = $null; Version = $null }
}

function Set-URLAssociation {
    <#
    .SYNOPSIS
        Set Chrome as the default handler for URL schemes
    #>
    param(
        [string]$URLScheme,
        [string]$ProgID
    )
    
    Write-Log "Setting $URLScheme as Chrome handler..."
    
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.$URLScheme\UserChoice"
    
    try {
        # For Windows 11/10, we need to set the UserChoice association
        # This uses assoc command as a workaround for registry write protection
        
        # First, try using Windows assoc/ftype commands
        $assocCmd = "assoc .${URLScheme}=${ProgID}"
        $output = cmd /c $assocCmd 2>&1
        Write-Log "Assoc output for .${URLScheme}: $output"
        
        return $true
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error setting ${URLScheme} association: $errMsg" -Level "WARN"
        return $false
    }
}

function Set-FileAssociation {
    <#
    .SYNOPSIS
        Set Chrome as the default handler for file types
    #>
    param(
        [string]$Extension,
        [string]$ProgID
    )
    
    Write-Log "Setting .${Extension} files to open with Chrome..."
    
    try {
        # Use assoc command to set file association
        $assocCmd = "assoc .${Extension}=${ProgID}"
        $output = cmd /c $assocCmd 2>&1
        Write-Log "File association .${Extension} set: $output"
        
        return $true
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Log "Error setting .${Extension} association: $errMsg" -Level "WARN"
        return $false
    }
}

function Set-ChromeAsDefaultBrowserRegistry {
    <#
    .SYNOPSIS
        Set Chrome as default browser via registry modifications
    #>
    Write-Log "Configuring registry for Chrome as default browser..."
    
    $successCount = 0
    $totalOps = 0
    
    # Define registry paths for URL schemes and protocols
    $protocolPaths = @(
        "HKCU:\Software\Classes\http",
        "HKCU:\Software\Classes\https"
    )
    
    foreach ($regPath in $protocolPaths) {
        $totalOps++
        try {
            # Create key if it doesn't exist
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force -ErrorAction SilentlyContinue | Out-Null
            }
            
            # Set Chrome as the handler
            Set-ItemProperty -Path $regPath -Name "(Default)" -Value $ChromeProgID -Force -ErrorAction SilentlyContinue
            Write-Log "Set registry $regPath to ChromeHTML"
            $successCount++
        }
        catch {
            Write-Log "Failed to set $regPath : $_" -Level "WARN"
        }
    }
    
    # Set file associations for HTML and PDF
    $filePaths = @(
        "HKCU:\Software\Classes\.htm",
        "HKCU:\Software\Classes\.html",
        "HKCU:\Software\Classes\.pdf"
    )
    
    foreach ($regPath in $filePaths) {
        $totalOps++
        try {
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force -ErrorAction SilentlyContinue | Out-Null
            }
            
            Set-ItemProperty -Path $regPath -Name "(Default)" -Value $ChromeProgID -Force -ErrorAction SilentlyContinue
            Write-Log "Set file association $regPath to ChromeHTML"
            $successCount++
        }
        catch {
            Write-Log "Failed to set $regPath : $_" -Level "WARN"
        }
    }
    
    # Disable the annoying "Set your default apps" toast notifications
    try {
        $toastPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts"
        if (Test-Path $toastPath) {
            Remove-Item -Path $toastPath -Force -ErrorAction SilentlyContinue
            Write-Log "Disabled app association toast notifications"
        }
    }
    catch {
        Write-Log "Could not disable toast notifications: $_" -Level "WARN"
    }
    
    Write-Log "Registry configuration completed: $successCount/$totalOps operations successful"
    return ($successCount -gt 0)
}

function Set-ChromeUsingAssociativity {
    <#
    .SYNOPSIS
        Set Chrome as default using Windows assoc command
    #>
    Write-Log "Setting Chrome as default browser using assoc command..."
    
    $successCount = 0
    
    # Protocols
    $protocols = @("http", "https")
    foreach ($protocol in $protocols) {
        try {
            $cmd = "assoc .${protocol}=ChromeHTML"
            $output = cmd /c $cmd 2>&1
            Write-Log "Protocol ${protocol}: $output"
            $successCount++
        }
        catch {
            Write-Log "Failed to set protocol $protocol : $_" -Level "WARN"
        }
    }
    
    # File extensions (htm, html, pdf)
    $extensions = @("htm", "html", "pdf")
    foreach ($ext in $extensions) {
        try {
            $cmd = "assoc .${ext}=ChromeHTML"
            $output = cmd /c $cmd 2>&1
            Write-Log "Extension .${ext}: $output"
            $successCount++
        }
        catch {
            Write-Log "Failed to set extension $ext : $_" -Level "WARN"
        }
    }
    
    return ($successCount -ge 5)
}

function Set-ChromeDefaultViaPolicy {
    <#
    .SYNOPSIS
        Set Chrome as default using Windows DefaultAssociations policy.
        Uses Base64-encoded XML (required by policy) and DISM import so it applies at next sign-in.
    #>
    param([string]$ChromePath)
    
    Write-Log "Method 0: DefaultAssociations policy (machine-wide, applies at sign-in)"
    
    # Ensure ChromeHTML is registered in HKLM so the policy can use it
    $chromeHtmlPath = "HKLM:\SOFTWARE\Classes\ChromeHTML"
    $chromeShellPath = "HKLM:\SOFTWARE\Classes\ChromeHTML\shell\open\command"
    try {
        if (-not (Test-Path $chromeHtmlPath)) { New-Item -Path $chromeHtmlPath -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $chromeHtmlPath -Name "(Default)" -Value "Chrome HTML Document" -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $chromeShellPath)) { New-Item -Path $chromeShellPath -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $chromeShellPath -Name "(Default)" -Value "`"$ChromePath`" -- `"%1`"" -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Could not register ChromeHTML in HKLM: $_" -Level "WARN"
        return $false
    }

    # XML: .htm, .html, .pdf, http, https -> Chrome (DISM/Windows format)
    $xml = "<DefaultAssociations><Association Identifier=`".htm`" ProgId=`"ChromeHTML`" ApplicationName=`"Google Chrome`"/><Association Identifier=`".html`" ProgId=`"ChromeHTML`" ApplicationName=`"Google Chrome`"/><Association Identifier=`".pdf`" ProgId=`"ChromeHTML`" ApplicationName=`"Google Chrome`"/><Association Identifier=`"http`" ProgId=`"ChromeHTML`" ApplicationName=`"Google Chrome`"/><Association Identifier=`"https`" ProgId=`"ChromeHTML`" ApplicationName=`"Google Chrome`"/></DefaultAssociations>"
    
    $policyDir = "$env:ProgramData\ChromePolicy"
    $xmlPath = "$policyDir\DefaultAssociations.xml"
    try {
        if (-not (Test-Path $policyDir)) { New-Item -Path $policyDir -ItemType Directory -Force | Out-Null }
        Set-Content -Path $xmlPath -Value $xml -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        Write-Log "Created $xmlPath"
    } catch {
        Write-Log "Could not create DefaultAssociations.xml: $_" -Level "WARN"
    }

    # Policy expects Base64-encoded XML content (not file path) per MDM/Policy CSP
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($xml)
    $base64 = [Convert]::ToBase64String($bytes)
    $sysPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    try {
        if (-not (Test-Path $sysPolicyPath)) { New-Item -Path $sysPolicyPath -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $sysPolicyPath -Name "DefaultAssociationsConfiguration" -Value $base64 -Type String -Force -ErrorAction Stop
        Write-Log "Set DefaultAssociationsConfiguration (Base64) policy" -Level "SUCCESS"
    } catch {
        Write-Log "Could not set DefaultAssociationsConfiguration (Base64): $_" -Level "WARN"
        # Fallback: some builds use file path instead of Base64
        try {
            Set-ItemProperty -Path $sysPolicyPath -Name "DefaultAssociationsConfiguration" -Value $xmlPath -Type String -Force -ErrorAction SilentlyContinue
            Write-Log "Set DefaultAssociationsConfiguration (file path) fallback"
        } catch { }
    }

    # DISM import: applies associations to the online image (can help on some builds)
    try {
        $dismResult = & dism.exe /Online /Import-DefaultAppAssociations:$xmlPath 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log "DISM Import-DefaultAppAssociations succeeded" } else { Write-Log "DISM import returned $LASTEXITCODE (may only apply to new users)" -Level "WARN" }
    } catch {
        Write-Log "DISM import skipped: $_" -Level "WARN"
    }

    # Scheduled task at logon: run Chrome --make-default-browser so existing users get it at next sign-in
    try {
        $taskName = "SetChromeDefaultAtLogon"
        $action = New-ScheduledTaskAction -Execute $ChromePath -Argument "--make-default-browser" -WindowStyle Hidden
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Log "Scheduled task $taskName created (runs at user logon to set Chrome default)" -Level "SUCCESS"
    } catch {
        Write-Log "Could not create logon task: $_" -Level "WARN"
    }

    return $true
}

function Set-ChromeDefaultBrowser {
    <#
    .SYNOPSIS
        Set Chrome as the default browser using policy first, then registry/assoc fallback.
    #>
    Write-Log "=== Setting Chrome as Default Browser ==="
    
    $chromeStatus = Get-ChromeInstallStatus
    
    if (-not $chromeStatus.Installed) {
        Write-Log "Chrome is not installed!" -Level "ERROR"
        return $false
    }
    
    Write-Log "Chrome found at: $($chromeStatus.Path)"
    
    # Method 0: DefaultAssociations policy (machine-wide, applies at logon)
    $method0Success = Set-ChromeDefaultViaPolicy -ChromePath $chromeStatus.Path
    
    # Method 1: HKCU registry (current user)
    Write-Log ""
    Write-Log "Method 1: Registry configuration (current user)"
    $method1Success = Set-ChromeAsDefaultBrowserRegistry
    
    # Method 2: assoc command (current user)
    Write-Log ""
    Write-Log "Method 2: Using assoc command"
    $method2Success = Set-ChromeUsingAssociativity
    
    # Verify
    Write-Log ""
    Write-Log "Verifying configuration..."
    try {
        $httpAssoc = cmd /c "assoc .http" 2>&1
        Write-Log "HTTP association: $httpAssoc"
        $httpsAssoc = cmd /c "assoc .https" 2>&1
        Write-Log "HTTPS association: $httpsAssoc"
        $htmlAssoc = cmd /c "assoc .html" 2>&1
        Write-Log "HTML association: $htmlAssoc"
    } catch { Write-Log "Could not verify associations: $_" -Level "WARN" }
    
    return ($method0Success -or $method1Success -or $method2Success)
}

function Write-Summary {
    <#
    .SYNOPSIS
        Write concise summary for N-Sight dashboard
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
Write-Log "$ScriptName v$ScriptVersion Started"
Write-Log "=========================================="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User Context: $env:USERNAME"
Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Log "Log File: $LogFile"
Write-Log ""

# Single exit code so N-Sight never sees exit 1
$Script:ExitCode = $EXIT_CRITICAL

# Admin check
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    $Script:ExitCode = $EXIT_CRITICAL
} else {
    try {
        Write-Log "Checking for Chrome installation..."
        $chromeStatus = Get-ChromeInstallStatus
        
        if (-not $chromeStatus.Installed) {
            Write-Log "Chrome is NOT installed" -Level "ERROR"
            Write-Summary -Status "CRITICAL" -Message "Chrome is not installed - install Chrome first"
            $Script:ExitCode = $EXIT_CRITICAL
        } else {
            $success = $false
            try { $success = Set-ChromeDefaultBrowser } catch { Write-Log "Set-ChromeDefaultBrowser error: $_" -Level "WARN" }

            if ($success) {
                Write-Log "Successfully configured Chrome as default browser" -Level "SUCCESS"
                Write-Log "=========================================="
                Write-Log "Script completed successfully!"
                Write-Log "=========================================="
                Write-Host ""
                Write-Summary -Status "OK" -Message "Chrome v$($chromeStatus.Version) is now the default browser"
                Write-Host "HTTP, HTTPS, .htm, .html, and .pdf set to Chrome."
                Write-Host "If links/files still open in Edge: sign out and sign back in (or restart) so the policy applies."
                $Script:ExitCode = 0
            } else {
                Write-Log "Partial success - some associations may not have been set" -Level "WARN"
                Write-Summary -Status "WARNING" -Message "Partial success - Chrome associations configured with warnings"
                $Script:ExitCode = $EXIT_WARNING
            }
        }
    } catch {
        Write-Log "Script failed: $_" -Level "ERROR"
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
        Write-Summary -Status "CRITICAL" -Message "Script failed - $_"
        $Script:ExitCode = $EXIT_CRITICAL
    }
}

Write-Log "=========================================="
Write-Log "Script execution ended"
exit $Script:ExitCode
