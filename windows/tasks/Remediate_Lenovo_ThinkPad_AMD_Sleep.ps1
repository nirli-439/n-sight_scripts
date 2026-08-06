<#
.SYNOPSIS
    Applies sleep/black-screen mitigations for Lenovo ThinkPad P14s Gen 6 AMD (Ryzen AI 350) class devices on Windows 11 Pro.

.DESCRIPTION
    Idempotent remediation for N-able N-sight RMM Automated Tasks (runs unattended as SYSTEM /
    Administrator, Session 0, no user interaction):
    - Disables Fast Startup / hybrid shutdown (hibernate off + HiberbootEnabled = 0)
    - Blocks automatic installation of drivers via Windows Update quality updates
    - Disables Wake-on-LAN magic packet and pattern match on active physical adapters (registry)
    - Sets PlatformAoAcOverride and adjusts active power plan (hybrid sleep off) to reduce Modern Standby conflicts

    Logs to C:\Logs\ThinkPadFix_<hostname>_<timestamp>.log

.NOTES
    Exit codes follow N-SIGHT_SCRIPT_STANDARDS.md (no script parameters required).

.EXECUTION
    Deploy as an N-sight Automated Task (PowerShell). No flags or arguments required.

.REQUIRES
    RunAsAdministrator

    Exit 0   = Success (all sections succeeded or were already compliant where measurable)
    Exit 1002 = Critical failure (see script output and log)
#>

#Requires -RunAsAdministrator

$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

$EXIT_OK = 0
$EXIT_CRITICAL = 1002

# --- Logging ---
$LogRoot = 'C:\Logs'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogRoot "ThinkPadFix_$($env:COMPUTERNAME)_$Stamp.log"
$script:LogFile = $LogFile

$script:SectionResults = [System.Collections.Generic.List[object]]::new()
$script:AnyFailure = $false

function Write-LogFile {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Last resort if log path fails
        [System.Diagnostics.Debug]::WriteLine($line)
    }
}

function ConvertTo-LiteralRegistryPath {
    param([string]$PsPath)
    $withoutProvider = $PsPath -replace '^Microsoft.PowerShell.Core\\Registry::', ''
    if ($withoutProvider -match '^HKEY_LOCAL_MACHINE\\(.+)$') {
        return 'HKLM:\' + $Matches[1]
    }
    if ($withoutProvider -match '^HKEY_CURRENT_USER\\(.+)$') {
        return 'HKCU:\' + $Matches[1]
    }
    return $null
}

function Add-SectionResult {
    param(
        [string]$Name,
        [ValidateSet('Fixed', 'AlreadyCorrect', 'Failed', 'Skipped')][string]$Status,
        [string]$Detail = ''
    )
    $script:SectionResults.Add([pscustomobject]@{ Section = $Name; Status = $Status; Detail = $Detail }) | Out-Null
}

try {
    if (-not (Test-Path -LiteralPath $LogRoot)) {
        New-Item -Path $LogRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    Write-LogFile "Remediation started. User: $($env:USERNAME); PID: $PID"
} catch {
    Write-LogFile "Failed to create log directory ${LogRoot}: $_" -Level ERROR
}

# --- Admin / elevation (SYSTEM passes as Administrator) ---
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Process is not elevated.'
    }
    Write-LogFile 'Elevation check passed.'
} catch {
    $script:AnyFailure = $true
    Write-LogFile "Elevation check failed: $_" -Level ERROR
    Write-Host "CRITICAL: Administrator privileges required."
    exit $EXIT_CRITICAL
}

# -----------------------------------------------------------------------------
# 1) Disable Fast Startup / hybrid shutdown
# -----------------------------------------------------------------------------
try {
    $powerReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $hiberBefore = $null
    try {
        $hiberBefore = (Get-ItemProperty -LiteralPath $powerReg -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
    } catch {
        $hiberBefore = $null
    }

    $hibOffOutput = & powercfg.exe /hibernate off 2>&1 | Out-String
    Write-LogFile "powercfg /hibernate off output: $hibOffOutput"

    if (-not (Test-Path -LiteralPath $powerReg)) {
        New-Item -LiteralPath $powerReg -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $powerReg -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force
    $hiberAfter = (Get-ItemProperty -LiteralPath $powerReg -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled

    if ($hiberBefore -eq 0 -and $hiberAfter -eq 0) {
        Add-SectionResult -Name 'Fast Startup / hibernate' -Status 'AlreadyCorrect' -Detail 'HiberbootEnabled already 0; hibernate left disabled via powercfg'
    } else {
        Add-SectionResult -Name 'Fast Startup / hibernate' -Status 'Fixed' -Detail 'Set HiberbootEnabled=0 and ensured hibernate off'
    }
    Write-LogFile "HiberbootEnabled before=$hiberBefore after=$hiberAfter"
} catch {
    $script:AnyFailure = $true
    Write-LogFile "Section Fast Startup failed: $_" -Level ERROR
    Add-SectionResult -Name 'Fast Startup / hibernate' -Status 'Failed' -Detail "$_"
}

# -----------------------------------------------------------------------------
# 2) Block Windows Update from installing drivers automatically
# -----------------------------------------------------------------------------
try {
    $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if (-not (Test-Path -LiteralPath $wuPath)) {
        New-Item -LiteralPath $wuPath -Force | Out-Null
    }
    $prev = $null
    try {
        $prev = (Get-ItemProperty -LiteralPath $wuPath -Name ExcludeWUDriversInQualityUpdate -ErrorAction Stop).ExcludeWUDriversInQualityUpdate
    } catch {
        $prev = $null
    }
    Set-ItemProperty -LiteralPath $wuPath -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 -Type DWord -Force
    $new = (Get-ItemProperty -LiteralPath $wuPath -Name ExcludeWUDriversInQualityUpdate -ErrorAction Stop).ExcludeWUDriversInQualityUpdate

    if ($prev -eq 1) {
        Add-SectionResult -Name 'WU driver exclusion policy' -Status 'AlreadyCorrect' -Detail 'ExcludeWUDriversInQualityUpdate already 1'
    } else {
        Add-SectionResult -Name 'WU driver exclusion policy' -Status 'Fixed' -Detail 'ExcludeWUDriversInQualityUpdate set to 1'
    }
    Write-LogFile "ExcludeWUDriversInQualityUpdate before=$prev after=$new"
} catch {
    $script:AnyFailure = $true
    Write-LogFile "Section WU driver exclusion failed: $_" -Level ERROR
    Add-SectionResult -Name 'WU driver exclusion policy' -Status 'Failed' -Detail "$_"
}

# -----------------------------------------------------------------------------
# 3) Disable WoL on active adapters (registry)
# -----------------------------------------------------------------------------
try {
    $nicClassRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $activeAdapters = Get-NetAdapter -ErrorAction Stop |
        Where-Object {
            $_.Status -eq 'Up' -and
            ($true -ne $_.Virtual) -and
            $_.InterfaceOperationalStatus -eq 'Up'
        }

    if (-not $activeAdapters) {
        Write-LogFile 'No eligible physical Up adapters found; skipping WoL registry tweaks.'
        Add-SectionResult -Name 'Wake-on-LAN registry' -Status 'Skipped' -Detail 'No active non-virtual adapters'
    } else {
        $wakeKeysAppliedFix = $false
        $hadWakeCapableAdapter = $false

        foreach ($na in $activeAdapters) {
            $guidText = $na.InterfaceGuid.ToString().Trim('{').Trim('}')
            $guidBraced = "{$guidText}"

            $matchKey = Get-ChildItem -LiteralPath $nicClassRoot -ErrorAction SilentlyContinue |
                Where-Object {
                    try {
                        $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                        [string]::Equals([string]$p.NetCfgInstanceId, $guidBraced, [System.StringComparison]::OrdinalIgnoreCase)
                    } catch {
                        $false
                    }
                } | Select-Object -First 1

            if (-not $matchKey) {
                Write-LogFile "No registry class key for adapter $($na.Name) ($guidBraced)." -Level WARN
                continue
            }

            $regPath = ConvertTo-LiteralRegistryPath -PsPath $matchKey.PSPath
            if (-not $regPath) {
                Write-LogFile "Could not map PSPath to literal registry path for $($na.Name)." -Level WARN
                continue
            }

            $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
            if (-not $props) {
                Write-LogFile "Could not read properties for $($na.Name) at $regPath." -Level WARN
                continue
            }

            $hadMagic = $props.PSObject.Properties.Name -contains '*WakeOnMagicPacket'
            $hadPattern = $props.PSObject.Properties.Name -contains '*WakeOnPattern'

            if (-not $hadMagic -and -not $hadPattern) {
                Write-LogFile "Adapter $($na.Name): no *WakeOnMagicPacket/*WakeOnPattern keys present (driver-specific)." -Level WARN
                continue
            }

            $hadWakeCapableAdapter = $true
            $magicBefore = if ($hadMagic) { [int]$props.'*WakeOnMagicPacket' } else { $null }
            $patternBefore = if ($hadPattern) { [int]$props.'*WakeOnPattern' } else { $null }

            if ($hadMagic -and $magicBefore -ne 0) {
                Set-ItemProperty -LiteralPath $regPath -Name '*WakeOnMagicPacket' -Value 0 -Type DWord -Force
                $wakeKeysAppliedFix = $true
                Write-LogFile "Adapter $($na.Name): set *WakeOnMagicPacket 0 (was $magicBefore)."
            }
            if ($hadPattern -and $patternBefore -ne 0) {
                Set-ItemProperty -LiteralPath $regPath -Name '*WakeOnPattern' -Value 0 -Type DWord -Force
                $wakeKeysAppliedFix = $true
                Write-LogFile "Adapter $($na.Name): set *WakeOnPattern 0 (was $patternBefore)."
            }

            if ((-not $hadMagic -or $magicBefore -eq 0) -and (-not $hadPattern -or $patternBefore -eq 0)) {
                Write-LogFile "Adapter $($na.Name): WoL registry already disabled."
            }
        }

        if (-not $hadWakeCapableAdapter) {
            Add-SectionResult -Name 'Wake-on-LAN registry' -Status 'Skipped' -Detail 'Active adapters did not expose WoL registry keys'
        } elseif ($wakeKeysAppliedFix) {
            Add-SectionResult -Name 'Wake-on-LAN registry' -Status 'Fixed' -Detail 'Disabled magic packet / pattern match where keys exist'
        } else {
            Add-SectionResult -Name 'Wake-on-LAN registry' -Status 'AlreadyCorrect' -Detail 'WoL registry values already 0 on adapters with keys'
        }
    }
} catch {
    $script:AnyFailure = $true
    Write-LogFile "Section WoL registry failed: $_" -Level ERROR
    Add-SectionResult -Name 'Wake-on-LAN registry' -Status 'Failed' -Detail "$_"
}

# -----------------------------------------------------------------------------
# 4) Modern Standby / power plan tuning
# -----------------------------------------------------------------------------
try {
    $powerCtl = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    if (-not (Test-Path -LiteralPath $powerCtl)) {
        New-Item -LiteralPath $powerCtl -Force | Out-Null
    }
    $aoacBefore = $null
    try {
        $aoacBefore = (Get-ItemProperty -LiteralPath $powerCtl -Name PlatformAoAcOverride -ErrorAction Stop).PlatformAoAcOverride
    } catch {
        $aoacBefore = $null
    }
    Set-ItemProperty -LiteralPath $powerCtl -Name 'PlatformAoAcOverride' -Value 0 -Type DWord -Force
    $aoacAfter = (Get-ItemProperty -LiteralPath $powerCtl -Name PlatformAoAcOverride -ErrorAction Stop).PlatformAoAcOverride

    # Hybrid sleep off on active scheme (reduces conflicts with S0ix-related resume paths)
    $SUB_SLEEP = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    $HYBRID_SLEEP = '94ac6d29-73ce-41a6-809f-6363ba21b47e'
    $hybridOut = @(
        & powercfg.exe /setacvalueindex SCHEME_CURRENT $SUB_SLEEP $HYBRID_SLEEP 0 2>&1 | Out-String
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT $SUB_SLEEP $HYBRID_SLEEP 0 2>&1 | Out-String
        & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-String
    ) -join "`n"
    Write-LogFile "Hybrid sleep disable / apply output: $hybridOut"

    $platformDetail = "PlatformAoAcOverride=$aoacAfter; hybrid sleep AC/DC=0 on active plan"
    if ($aoacBefore -eq 0 -and $aoacAfter -eq 0) {
        Add-SectionResult -Name 'Modern Standby / power plan' -Status 'AlreadyCorrect' -Detail $platformDetail
    } else {
        Add-SectionResult -Name 'Modern Standby / power plan' -Status 'Fixed' -Detail $platformDetail
    }
    Write-LogFile "PlatformAoAcOverride before=$aoacBefore after=$aoacAfter"
} catch {
    $script:AnyFailure = $true
    Write-LogFile "Section Modern Standby / power plan failed: $_" -Level ERROR
    Add-SectionResult -Name 'Modern Standby / power plan' -Status 'Failed' -Detail "$_"
}

# -----------------------------------------------------------------------------
# Summary (stdout for N-sight capture; first line follows dashboard convention)
# -----------------------------------------------------------------------------
$counts = @{
    Fixed            = @($script:SectionResults | Where-Object Status -EQ 'Fixed').Count
    AlreadyCorrect   = @($script:SectionResults | Where-Object Status -EQ 'AlreadyCorrect').Count
    Failed           = @($script:SectionResults | Where-Object Status -EQ 'Failed').Count
    Skipped          = @($script:SectionResults | Where-Object Status -EQ 'Skipped').Count
}

Write-LogFile ("Summary counts: Fixed={0} AlreadyCorrect={1} Failed={2} Skipped={3}" -f $counts.Fixed, $counts.AlreadyCorrect, $counts.Failed, $counts.Skipped)
foreach ($row in $script:SectionResults) {
    Write-LogFile ("{0,-36} {1,-15} {2}" -f $row.Section, $row.Status, $row.Detail)
}

if ($script:AnyFailure -or $counts.Failed -gt 0) {
    Write-Host "CRITICAL: Lenovo ThinkPad AMD sleep remediation finished with failures (see log: $LogFile)."
    Write-Host ""
    Write-Host "Summary: Fixed=$($counts.Fixed), AlreadyCorrect=$($counts.AlreadyCorrect), Failed=$($counts.Failed), Skipped=$($counts.Skipped)"
    $script:SectionResults | Sort-Object Section | Format-Table -AutoSize | Out-String | Write-Host
    exit $EXIT_CRITICAL
}

Write-Host "OK: Lenovo ThinkPad AMD sleep remediation completed successfully."
Write-Host ""
Write-Host "Summary: Fixed=$($counts.Fixed), AlreadyCorrect=$($counts.AlreadyCorrect), Failed=$($counts.Failed), Skipped=$($counts.Skipped)"
Write-Host "Log file: $LogFile"
$script:SectionResults | Sort-Object Section | Format-Table -AutoSize | Out-String | Write-Host

exit $EXIT_OK
