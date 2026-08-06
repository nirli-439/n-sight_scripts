<#
.SYNOPSIS
    Checks if a specific website was visited across all major browsers.
    
.DESCRIPTION
    Searches Chrome, Edge, Brave, and Firefox history files across all user profiles
    for visits to a specified website (default: sofortarzt.com).
    Designed for N-Sight RMM deployment as a 24x7 Check.
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Sofortarzt.ps1" -Raw)
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Sofortarzt.ps1")
    
.NOTES
    Author: AI Assistant
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
.OUTPUTS
    Exit 0    = Success (Not visited)
    Exit 1002 = Critical/Error (Visited)
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Check_Sofortarzt"
$ScriptVersion = "1.0"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "${ScriptName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Target website to search for
$TargetWebsite = "sofortarzt.com"

# Exit codes for N-Sight
$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002

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
    <#
    .SYNOPSIS
        Writes a slim summary for N-Sight dashboard. Use OK, PASS, WARNING, CRITICAL, or Wait to Task.
        Keep under 255 characters (slim output format; see "General Script Requirements").
    #>
    param(
        [ValidateSet("OK", "PASS", "WARNING", "CRITICAL", "Wait to Task")]
        [string]$Status,
        [string]$Message
    )
    # First line is most visible in N-Sight UI (slim format)
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
Write-Log "Log File: $LogFile"

# Admin check
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Administrator privileges required"
    exit $EXIT_CRITICAL
}

try {
    # We will aggregate visits into this array
    $FoundVisits = @()

    # Look through all user profiles on the machine
    $UserProfiles = Get-WmiObject Win32_UserProfile | Where-Object { 
        $_.Special -eq $false -and $_.LocalPath -notmatch "System32|NetworkService|LocalService|UMFD"
    }

    # Create temp directory for copying locked databases
    $TempDir = Join-Path $env:TEMP "BrowserHistoryCheck"
    if (-not (Test-Path $TempDir)) { 
        New-Item -Path $TempDir -ItemType Directory -Force | Out-Null 
    }

    foreach ($Profile in $UserProfiles) {
        $UserPath = $Profile.LocalPath
        $UserName = Split-Path $UserPath -Leaf

        Write-Log "Scanning profile: $UserName" -Level "INFO"

        # Well-known paths to browser history SQLite files
        $HistoryPaths = @(
            (Join-Path $UserPath "AppData\Local\Google\Chrome\User Data\*\History"),
            (Join-Path $UserPath "AppData\Local\Microsoft\Edge\User Data\*\History"),
            (Join-Path $UserPath "AppData\Roaming\Mozilla\Firefox\Profiles\*\places.sqlite"),
            (Join-Path $UserPath "AppData\Local\BraveSoftware\Brave-Browser\User Data\*\History")
        )

        foreach ($PathPattern in $HistoryPaths) {
            $Files = Get-Item -Path $PathPattern -ErrorAction SilentlyContinue
            foreach ($File in $Files) {
                $TempFile = Join-Path $TempDir "$UserName-$($File.Name)-$([guid]::NewGuid().ToString().Substring(0,8))"
                
                try {
                    # Copy file locally because the browser generally holds a lock on its DB
                    Copy-Item -Path $File.FullName -Destination $TempFile -Force -ErrorAction Stop
                    
                    # Parse the binary file for strings matching the URL.
                    # Note: We do this because fetching an exact timestamp requires parsing the SQLite database structure
                    # using native libraries (System.Data.SQLite is rarely installed out-of-the-box Windows).
                    $RegexPattern = "(https?://[a-zA-Z0-9.\-]*$([regex]::Escape($TargetWebsite))[^`0]*)"
                    $Matches = Select-String -Path $TempFile -Pattern $RegexPattern -AllMatches -Encoding ASCII -ErrorAction SilentlyContinue
                    
                    if ($Matches) {
                        foreach ($Match in $Matches.Matches) {
                            $MatchValue = $Match.Value -replace '[^\x20-\x7E]', '' # Strip non-printable ascii
                            $FoundVisits += [PSCustomObject]@{
                                User = $UserName
                                DatabaseLocation = $File.FullName
                                MatchedURL = $MatchValue
                            }
                        }
                    }
                    
                    Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Log "Failed to process database '$($File.FullName)': $_" -Level "WARN"
                }
            }
        }
    }

    # Clean up temp dir
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($FoundVisits.Count -gt 0) {
        # Keep unique exact match lines (can be multiple entries if user visited multiple URLs under this domain)
        $UniqueVisits = $FoundVisits | Select-Object User, DatabaseLocation, MatchedURL -Unique

        foreach ($Visit in $UniqueVisits) {
            Write-Log "Visit detected by User ($($Visit.User)) - Database ($($Visit.DatabaseLocation)) - URL ($($Visit.MatchedURL))" -Level "WARN"
        }

        # Format string for summary without exceeding 255 chars
        $UsersList = ($UniqueVisits | Select-Object -ExpandProperty User -Unique) -join ', '
        Write-Summary -Status "CRITICAL" -Message "Website '$TargetWebsite' visits detected for users: $UsersList"
        
        Write-Host "--------------------------------------------------------"
        Write-Host "Detailed Visits Found:"
        Write-Host "--------------------------------------------------------"
        
        # Presenting findings
        $UniqueVisits | Select-Object User, MatchedURL, DatabaseLocation | Format-List | Out-String | Write-Host
        
        Write-Host "Note: Extracted from raw SQLite DB. Exact timestamps are unable to be provided generically via purely native PowerShell context without an SQLite parser/library."
        
        exit $EXIT_CRITICAL
    }
    else {
        Write-Log "No visits to $TargetWebsite found." -Level "SUCCESS"
        Write-Summary -Status "OK" -Message "No visits to $TargetWebsite detected on any profile."
        exit $EXIT_SUCCESS
    }
}
catch {
    Write-Log "Script failed: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Summary -Status "CRITICAL" -Message "Script failed - $_"
    exit $EXIT_CRITICAL
}
finally {
    Write-Log "=========================================="
    Write-Log "Script execution ended"
}
