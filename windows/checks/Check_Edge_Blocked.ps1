<#
.SYNOPSIS
    Check if Microsoft Edge is blocked and Chrome is set as default.
    
.DESCRIPTION
    This monitoring script checks if Edge is properly blocked:
    - Checks if IFEO debugger is set for Edge executables
    - Verifies the blocker script exists
    - Checks if Chrome is set as default browser (HTTP/HTTPS)
    - Checks if Chrome is set as PDF handler
    - Verifies Chrome shortcuts exist (Desktop, Start Menu, Taskbar)
    - Verifies Edge shortcuts are removed (Desktop, Taskbar)
    
    For Google Workspace environments where only Chrome should be used.
    
    Exit Codes:
    - 0 = OK (Edge is blocked - compliant)
    - 2 = Critical (Edge is NOT blocked - non-compliant)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Edge_Blocked.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Edge_Blocked.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Edge_Blocked.ps1")
.NOTES
    Author: IT Admin
    Version: 1.2
    Requires: Administrator privileges
    Platform: Windows 10/11
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\EdgeBlockCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Test-EdgeBlocked {
    <#
    .SYNOPSIS
        Checks if Edge is blocked via IFEO
    #>
    
    $result = @{
        IsBlocked = $false
        BlockedExecutables = @()
        BlockerScriptExists = $false
        Details = ""
    }
    
    # Check IFEO for Edge executables
    $edgeExecutables = @("msedge.exe", "MicrosoftEdge.exe")
    
    foreach ($exe in $edgeExecutables) {
        $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
        
        if (Test-Path $ifeoPath) {
            try {
                $debugger = Get-ItemProperty -Path $ifeoPath -Name "Debugger" -ErrorAction SilentlyContinue
                if ($debugger -and $debugger.Debugger) {
                    $result.BlockedExecutables += $exe
                }
            }
            catch { }
        }
    }
    
    # Check if blocker script exists
    $blockerScript = "$env:ProgramData\BrowserPolicy\EdgeBlocked.vbs"
    if (Test-Path $blockerScript) {
        $result.BlockerScriptExists = $true
    }
    
    # Determine if properly blocked
    if ($result.BlockedExecutables.Count -gt 0) {
        $result.IsBlocked = $true
        $result.Details = "Blocked: $($result.BlockedExecutables -join ', ')"
    }
    else {
        $result.Details = "No IFEO blocks found for Edge"
    }
    
    return $result
}

function Test-EdgeInstalled {
    <#
    .SYNOPSIS
        Checks if Edge is installed
    #>
    
    $edgePaths = @(
        "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    
    foreach ($path in $edgePaths) {
        if (Test-Path $path) {
            return $true
        }
    }
    
    return $false
}

function Test-ChromeShortcuts {
    <#
    .SYNOPSIS
        Checks if Chrome shortcuts exist and Edge shortcuts are removed
    #>
    
    $result = @{
        ChromeDesktop = $false
        ChromeStartMenu = $false
        ChromeTaskbar = $false
        EdgeDesktopRemoved = $true
        EdgeTaskbarRemoved = $true
    }
    
    # Check Chrome desktop shortcut
    if ((Test-Path "$env:PUBLIC\Desktop\Google Chrome.lnk") -or 
        (Test-Path "$env:USERPROFILE\Desktop\Google Chrome.lnk")) {
        $result.ChromeDesktop = $true
    }
    
    # Check Chrome Start Menu shortcut
    if ((Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk") -or
        (Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk")) {
        $result.ChromeStartMenu = $true
    }
    
    # Check Chrome taskbar pin
    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Google Chrome.lnk"
    if (Test-Path $taskbarPath) {
        $result.ChromeTaskbar = $true
    }
    
    # Check if Edge desktop shortcuts exist (should be removed)
    if ((Test-Path "$env:PUBLIC\Desktop\Microsoft Edge.lnk") -or 
        (Test-Path "$env:USERPROFILE\Desktop\Microsoft Edge.lnk")) {
        $result.EdgeDesktopRemoved = $false
    }
    
    # Check if Edge taskbar pin exists (should be removed)
    $edgeTaskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk"
    if (Test-Path $edgeTaskbarPath) {
        $result.EdgeTaskbarRemoved = $false
    }
    
    return $result
}

function Test-ChromeDefaultBrowser {
    <#
    .SYNOPSIS
        Checks if Chrome is set as the default browser and file handler
    #>
    
    $result = @{
        IsDefault = $false
        HttpHandler = ""
        HttpsHandler = ""
        PdfHandler = ""
        PdfIsChrome = $false
        Details = ""
    }
    
    try {
        # Check current user's http protocol association
        $httpPath = "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice"
        $httpsPath = "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice"
        
        if (Test-Path $httpPath) {
            $httpChoice = Get-ItemProperty -Path $httpPath -Name "ProgId" -ErrorAction SilentlyContinue
            if ($httpChoice) {
                $result.HttpHandler = $httpChoice.ProgId
            }
        }
        
        if (Test-Path $httpsPath) {
            $httpsChoice = Get-ItemProperty -Path $httpsPath -Name "ProgId" -ErrorAction SilentlyContinue
            if ($httpsChoice) {
                $result.HttpsHandler = $httpsChoice.ProgId
            }
        }
        
        # Check PDF handler
        $pdfPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pdf\UserChoice"
        if (Test-Path $pdfPath) {
            $pdfChoice = Get-ItemProperty -Path $pdfPath -Name "ProgId" -ErrorAction SilentlyContinue
            if ($pdfChoice) {
                $result.PdfHandler = $pdfChoice.ProgId
            }
        }
        
        # Check if handlers are set to Chrome
        $chromeProgIds = @("ChromeHTML", "ChromeHTML.", "ChromeBHTML")
        
        $httpIsChrome = $chromeProgIds | Where-Object { $result.HttpHandler -like "$_*" }
        $httpsIsChrome = $chromeProgIds | Where-Object { $result.HttpsHandler -like "$_*" }
        $pdfIsChrome = $chromeProgIds | Where-Object { $result.PdfHandler -like "$_*" }
        
        $result.PdfIsChrome = [bool]$pdfIsChrome
        
        if ($httpIsChrome -and $httpsIsChrome) {
            $result.IsDefault = $true
            $pdfStatus = if ($pdfIsChrome) { "Chrome" } else { $result.PdfHandler }
            $result.Details = "Chrome is default browser, PDF: $pdfStatus"
        }
        elseif ($result.HttpHandler -or $result.HttpsHandler) {
            $result.Details = "HTTP=$($result.HttpHandler), HTTPS=$($result.HttpsHandler), PDF=$($result.PdfHandler)"
        }
        else {
            $result.Details = "Could not determine default browser"
        }
    }
    catch {
        $result.Details = "Error checking default browser: $_"
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Microsoft Edge Block Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "CRITICAL: Script requires administrator privileges"
    exit 1002
}

try {
    $edgeInstalled = Test-EdgeInstalled
    $blockStatus = Test-EdgeBlocked
    $chromeDefault = Test-ChromeDefaultBrowser
    $shortcuts = Test-ChromeShortcuts
    
    Write-Log "Edge Installed: $edgeInstalled"
    Write-Log "Edge Blocked: $($blockStatus.IsBlocked)"
    Write-Log "Details: $($blockStatus.Details)"
    Write-Log "Blocker Script Exists: $($blockStatus.BlockerScriptExists)"
    Write-Log "Chrome Default Browser: $($chromeDefault.IsDefault)"
    Write-Log "Chrome PDF Handler: $($chromeDefault.PdfIsChrome)"
    Write-Log "Default Browser Details: $($chromeDefault.Details)"
    Write-Log "Chrome Desktop Shortcut: $($shortcuts.ChromeDesktop)"
    Write-Log "Chrome Start Menu: $($shortcuts.ChromeStartMenu)"
    Write-Log "Chrome Taskbar Pin: $($shortcuts.ChromeTaskbar)"
    Write-Log "Edge Desktop Removed: $($shortcuts.EdgeDesktopRemoved)"
    Write-Log "Edge Taskbar Removed: $($shortcuts.EdgeTaskbarRemoved)"
    
    # Helper function for shortcut status display
    function Get-ShortcutStatus {
        param($shortcuts)
        $status = @()
        $status += "Chrome Desktop: $(if ($shortcuts.ChromeDesktop) { 'Yes' } else { 'No' })"
        $status += "Chrome Start Menu: $(if ($shortcuts.ChromeStartMenu) { 'Yes' } else { 'No' })"
        $status += "Chrome Taskbar: $(if ($shortcuts.ChromeTaskbar) { 'Yes' } else { 'No' })"
        $status += "Edge Desktop Removed: $(if ($shortcuts.EdgeDesktopRemoved) { 'Yes' } else { 'No' })"
        $status += "Edge Taskbar Removed: $(if ($shortcuts.EdgeTaskbarRemoved) { 'Yes' } else { 'No' })"
        return $status
    }
    
    if (-not $edgeInstalled) {
        # Edge not installed - compliant
        Write-Log "Status: COMPLIANT (Edge not installed)"
        Write-Host ""
        Write-Host "OK: Microsoft Edge is not installed"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Chrome is default browser: $(if ($chromeDefault.IsDefault) { 'Yes' } else { 'No' })"
        Write-Host "Chrome is PDF handler: $(if ($chromeDefault.PdfIsChrome) { 'Yes' } else { 'No - ' + $chromeDefault.PdfHandler })"
        Write-Host ""
        Write-Host "Shortcuts:"
        Get-ShortcutStatus $shortcuts | ForEach-Object { Write-Host "  $_" }
        exit 0
    }
    elseif ($blockStatus.IsBlocked -and $chromeDefault.IsDefault) {
        # Edge blocked AND Chrome is default - fully compliant
        Write-Log "Status: COMPLIANT (Edge blocked, Chrome default)"
        Write-Host ""
        Write-Host "OK: Microsoft Edge is blocked and Chrome is default browser"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Blocked executables: $($blockStatus.BlockedExecutables -join ', ')"
        Write-Host "Blocker script: $(if ($blockStatus.BlockerScriptExists) { 'Present' } else { 'Missing' })"
        Write-Host "Default browser: Chrome"
        Write-Host "PDF handler: $(if ($chromeDefault.PdfIsChrome) { 'Chrome' } else { $chromeDefault.PdfHandler })"
        Write-Host ""
        Write-Host "Shortcuts:"
        Get-ShortcutStatus $shortcuts | ForEach-Object { Write-Host "  $_" }
        exit 0
    }
    elseif ($blockStatus.IsBlocked) {
        # Edge blocked but Chrome not default - partially compliant
        Write-Log "Status: PARTIAL (Edge blocked, Chrome not default)" -Level "WARNING"
        Write-Host ""
        Write-Host "OK: Microsoft Edge is blocked (Chrome not default)"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Blocked executables: $($blockStatus.BlockedExecutables -join ', ')"
        Write-Host "Blocker script: $(if ($blockStatus.BlockerScriptExists) { 'Present' } else { 'Missing' })"
        Write-Host "Default browser: $($chromeDefault.Details)"
        Write-Host "PDF handler: $(if ($chromeDefault.PdfIsChrome) { 'Chrome' } else { $chromeDefault.PdfHandler })"
        Write-Host ""
        Write-Host "Shortcuts:"
        Get-ShortcutStatus $shortcuts | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "Note: Run Block_Edge.ps1 again to set Chrome as default"
        exit 0
    }
    else {
        # Edge installed and not blocked - non-compliant
        Write-Log "Status: NON-COMPLIANT (Edge not blocked)" -Level "WARNING"
        Write-Host ""
        Write-Host "CRITICAL: Microsoft Edge is NOT blocked"
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Policy requires Edge to be blocked - Chrome only"
        Write-Host "Default browser: $($chromeDefault.Details)"
        Write-Host "PDF handler: $(if ($chromeDefault.PdfIsChrome) { 'Chrome' } else { $chromeDefault.PdfHandler })"
        Write-Host ""
        Write-Host "Shortcuts:"
        Get-ShortcutStatus $shortcuts | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "Action Required: Run Block_Edge.ps1 task"
        exit 1002
    }
}
catch {
    Write-Log "Check failed: $_" -Level "ERROR"
    Write-Host "CRITICAL: Check failed - $_"
    exit 1002
}
