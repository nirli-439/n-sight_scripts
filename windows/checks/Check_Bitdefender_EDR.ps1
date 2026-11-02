<#
.SYNOPSIS
    Checks that the Bitdefender GravityZone agent (BEST / EDR) is installed, running and up to date.

.DESCRIPTION
    24x7 check for Bitdefender Endpoint Security Tools (BEST) - the GravityZone agent that hosts
    the EDR sensor. Read-only, makes no changes.

    Checks:
    1. Installed      - product.console.exe and the EPSecurityService service exist
    2. Services       - every Bitdefender service set to Automatic is Running
                        (EPSecurityService, EPProtectedService, EPUpdateService, EPIntegrationService,
                         EPRedline ... - discovered by display name, not hard-coded)
    3. Protection     - Windows Security Center (root\SecurityCenter2) reports Bitdefender real-time
                        protection ON and signatures up to date (workstations only - no SecurityCenter2 on Server)
    4. Signatures age - product.console.exe /c GetUpdateStatus antivirus (last successful update)
    5. Info only      - product + signature version (product.console.exe /c GetVersion product|antivirus)

    Remediation: Install_BitdefenderAgent.ps1 (when not installed). Stopped services / RTP off usually
    mean tampering, a broken install or a GravityZone policy - investigate in the GravityZone console.

    Vendor reference (BEST command line interface - product.console.exe):
      https://www.bitdefender.com/business/support/en/77211-36849-using-the-command-line-interface.html
      https://www.bitdefender.com/business/support/en/77211-199825--getupdatestatus.html

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Bitdefender_EDR.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/checks/Check_Bitdefender_EDR.ps1")

.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges (SYSTEM via N-Sight)
    Platform: Windows 10/11 (Server: SecurityCenter2 step is skipped)
    Timeout: default 60s is enough

    CHANGELOG:
    1.0 - Initial version

.OUTPUTS
    Exit 0    = OK       (installed, services running, RTP on, signatures fresh)
    Exit 1001 = WARNING  (signatures older than $SigWarnDays days / Security Center says out of date)
    Exit 1002 = CRITICAL (not installed, a Bitdefender service stopped, RTP off, or signatures older than $SigCritDays days)
#>

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName    = "Check_Bitdefender_EDR"
$ScriptVersion = "1.0"

$EXIT_SUCCESS  = 0
$EXIT_WARNING  = 1001
$EXIT_CRITICAL = 1002

$SigWarnDays = 3     # signatures older than this -> WARNING
$SigCritDays = 7     # signatures older than this -> CRITICAL

$BdDir      = "${env:ProgramFiles}\Bitdefender\Endpoint Security"
$BdConsole  = Join-Path $BdDir "product.console.exe"
$CoreService = "EPSecurityService"

$Critical = New-Object System.Collections.Generic.List[string]
$Warning  = New-Object System.Collections.Generic.List[string]
$Details  = New-Object System.Collections.Generic.List[string]

# ============================================================================
# FUNCTIONS
# ============================================================================
function Invoke-BdConsole {
    # Runs product.console.exe /c <args> with a timeout; returns stdout text ('' on failure)
    param([string]$Arguments, [int]$TimeoutMs = 20000)
    if (-not (Test-Path -LiteralPath $BdConsole)) { return "" }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $BdConsole
        $psi.Arguments = "/c $Arguments"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return ""
        }
        return ($out.Result | Out-String).Trim()
    } catch {
        return ""
    }
}

# ============================================================================
# MAIN
# ============================================================================
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "CRITICAL: Administrator privileges required"
        exit $EXIT_CRITICAL
    }

    # --- 1. Installed --------------------------------------------------------
    $core = Get-Service -Name $CoreService -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $BdConsole) -and -not $core) {
        Write-Host "CRITICAL: Bitdefender GravityZone agent (BEST) is NOT installed on $env:COMPUTERNAME - run Install_BitdefenderAgent.ps1"
        exit $EXIT_CRITICAL
    }
    if (-not $core) { $Critical.Add("core service $CoreService missing (broken install)") }

    # --- 2. Services ----------------------------------------------------------
    $bdServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Bitdefender*" })
    foreach ($svc in $bdServices) {
        $startType = try { (Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction Stop).StartMode } catch { "Unknown" }
        $Details.Add("Service $($svc.Name) [$($svc.DisplayName)]: $($svc.Status) ($startType)")
        if ($startType -eq "Auto" -and $svc.Status -ne "Running") {
            $Critical.Add("service $($svc.Name) is $($svc.Status)")
        }
    }
    if ($core -and $core.Status -ne "Running" -and -not ($Critical -match $CoreService)) {
        $Critical.Add("service $CoreService is $($core.Status)")
    }

    # --- 3. Windows Security Center (workstations) ----------------------------
    $isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1
    if (-not $isServer) {
        try {
            $avs = @(Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop)
            $bdAv = $avs | Where-Object { $_.displayName -like "*Bitdefender*" } | Select-Object -First 1
            $others = ($avs | Where-Object { $_.displayName -notlike "*Bitdefender*" } | ForEach-Object { $_.displayName }) -join ", "
            if ($others) { $Details.Add("Other AV registered: $others") }
            if (-not $bdAv) {
                $Critical.Add("Bitdefender not registered in Windows Security Center")
            } else {
                $state = [int]$bdAv.productState
                $rtpByte = ($state -shr 8) -band 0xFF       # 0x10/0x11 = real-time ON
                $sigByte = $state -band 0xFF                # 0x00 = up to date
                $rtpOn   = $rtpByte -in 0x10, 0x11
                $Details.Add("Security Center: $($bdAv.displayName) productState=0x$('{0:X6}' -f $state) RTP=$(if ($rtpOn) {'ON'} else {'OFF'}) Signatures=$(if ($sigByte -eq 0) {'up to date'} else {'out of date'})")
                if (-not $rtpOn) { $Critical.Add("real-time protection is OFF") }
                if ($sigByte -ne 0) { $Warning.Add("Security Center reports signatures out of date") }
            }
        } catch {
            $Details.Add("Security Center query failed: $($_.Exception.Message)")
        }
    } else {
        $Details.Add("Windows Server - Security Center check skipped")
    }

    # --- 4. Signature age (product.console.exe) -------------------------------
    $updOut = Invoke-BdConsole -Arguments "GetUpdateStatus antivirus"
    if ($updOut) {
        $Details.Add("GetUpdateStatus antivirus: $(($updOut -replace '\s+', ' ').Substring(0, [Math]::Min(200, ($updOut -replace '\s+', ' ').Length)))")
        if ($updOut -match 'lastSucceededTime\D{0,5}(\d{9,11})') {
            $lastOk = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Matches[1]).LocalDateTime
            $ageDays = [Math]::Round(((Get-Date) - $lastOk).TotalDays, 1)
            $Details.Add("Last successful signature update: $($lastOk.ToString('yyyy-MM-dd HH:mm')) ($ageDays days ago)")
            if ($ageDays -gt $SigCritDays) { $Critical.Add("signatures not updated for $ageDays days") }
            elseif ($ageDays -gt $SigWarnDays) { $Warning.Add("signatures not updated for $ageDays days") }
        }
    } else {
        $Details.Add("product.console.exe GetUpdateStatus returned nothing (skipped)")
    }

    # --- 5. Versions (info) -----------------------------------------------------
    $prodVer = (Invoke-BdConsole -Arguments "GetVersion product") -replace '\s+', ' '
    $sigVer  = (Invoke-BdConsole -Arguments "GetVersion antivirus") -replace '\s+', ' '
    if (-not $prodVer) {
        $prodVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "Bitdefender Endpoint Security Tools*" } | Select-Object -First 1).DisplayVersion
    }
    if (-not $prodVer) { $prodVer = "unknown" }
    if (-not $sigVer)  { $sigVer  = "unknown" }

    # --- Result ------------------------------------------------------------------
    $summary = "Bitdefender BEST $prodVer, signatures $sigVer"
    if ($Critical.Count -gt 0) {
        Write-Host "CRITICAL: Bitdefender EDR - $($Critical -join '; ') ($summary)"
        $rc = $EXIT_CRITICAL
    } elseif ($Warning.Count -gt 0) {
        Write-Host "WARNING: Bitdefender EDR - $($Warning -join '; ') ($summary)"
        $rc = $EXIT_WARNING
    } else {
        Write-Host "OK: Bitdefender EDR healthy - $summary, all services running"
        $rc = $EXIT_SUCCESS
    }
    $Details | ForEach-Object { Write-Host "  $_" }
    exit $rc
}
catch {
    Write-Host "CRITICAL: $ScriptName failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
