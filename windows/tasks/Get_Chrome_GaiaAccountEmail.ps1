<#
.SYNOPSIS
    Reads Chrome Default profile Preferences and outputs the Google account email from gaia_cookie data.

.DESCRIPTION
    - Reads: %LOCALAPPDATA%\Google\Chrome\User Data\Default\Preferences
    - Parses JSON, reads gaia_cookie.last_list_accounts_binary_data
    - Base64-decodes to UTF-8, then extracts the first email via regex
    - Designed for N-Sight RMM; must run as the logged-on user (not SYSTEM)

    N-Sight: Create script, set execution to run as logged-in user so LOCALAPPDATA resolves correctly.

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Get_Chrome_GaiaAccountEmail.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Get_Chrome_GaiaAccountEmail.ps1")

.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Run as the target user (not SYSTEM / not elevated-only service context)
    Platform: Windows 10/11 (Chrome Default profile)

.OUTPUTS
    Exit 0     = Success (email found)
    Exit 1002  = Critical / not found or unreadable
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

$PreferencesPath = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data\Default\Preferences"
$EmailPattern = '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'

try {
    if ($env:USERNAME -eq 'SYSTEM' -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Write-Host "CRITICAL: Run this script as the signed-in user, not SYSTEM."
        exit $EXIT_CRITICAL
    }

    if (-not (Test-Path -LiteralPath $PreferencesPath)) {
        Write-Host "CRITICAL: Chrome Preferences not found at $PreferencesPath"
        exit $EXIT_CRITICAL
    }

    $jsonText = Get-Content -LiteralPath $PreferencesPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        Write-Host "CRITICAL: Chrome Preferences file is empty."
        exit $EXIT_CRITICAL
    }

    $prefs = $jsonText | ConvertFrom-Json
    $gaia = $prefs.gaia_cookie
    if ($null -eq $gaia) {
        Write-Host "CRITICAL: gaia_cookie section missing in Preferences."
        exit $EXIT_CRITICAL
    }

    $b64 = $gaia.last_list_accounts_binary_data
    if ([string]::IsNullOrWhiteSpace([string]$b64)) {
        Write-Host "CRITICAL: last_list_accounts_binary_data not present or empty."
        exit $EXIT_CRITICAL
    }

    $bytes = [System.Convert]::FromBase64String([string]$b64)
    $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)

    if ([string]::IsNullOrWhiteSpace($decoded)) {
        Write-Host "CRITICAL: Decoded gaia data is empty."
        exit $EXIT_CRITICAL
    }

    $m = [regex]::Match($decoded, $EmailPattern)
    if (-not $m.Success) {
        Write-Host "CRITICAL: No email address pattern found in decoded data."
        exit $EXIT_CRITICAL
    }

    $email = $m.Value
    Write-Host "OK: $email"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
