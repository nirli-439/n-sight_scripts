<#
.SYNOPSIS
    Check N-sight Take Control (BASupSrvc) service health status.
    
.DESCRIPTION
    This monitoring script verifies the health of N-sight Take Control service:
    - BASupSrvc service status and configuration
    - BASupSrvc.exe process health
    - Recent crash events (EventID 1000)
    - Service recovery settings
    - Required files and installation integrity
    - Network connectivity for remote access
    
    Take Control (formerly BeAnywhere Support Express) is the remote access
    component of N-sight RMM.
    
    Designed for N-Sight RMM deployment monitoring.
    
    Exit Codes:
    - 0   = PASS (Take Control service is healthy)
    - 1001 = WARNING (Minor issues detected - service may need attention)
    - 1002 = FAIL (Critical issues found - Take Control likely not functional)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_TakeControl_Health.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_TakeControl_Health.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_TakeControl_Health.ps1")
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
$ErrorActionPreference = "Continue"
$LogFile = "$env:TEMP\TakeControlHealthCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Take Control service names (may vary by installation)
$TakeControlServices = @(
    "BASupSrvc",
    "BASupSrvcCnfg",
    "BASupportExpressStandalone",
    "BASupportExpressSrvcUpdater"
)

# Take Control process names
$TakeControlProcesses = @(
    "BASupSrvc",
    "BASupSrvcCnfg",
    "BASupTSHelper",
    "BASupApp",
    "BASupAppElev",
    "BASupAppSrvc"
)

# Common installation paths
$InstallPaths = @(
    "$env:ProgramFiles\Take Control Agent",
    "$env:ProgramFiles (x86)\Take Control Agent",
    "$env:ProgramFiles\BeAnywhere Support Express",
    "$env:ProgramFiles (x86)\BeAnywhere Support Express",
    "$env:ProgramFiles\Take Control",
    "$env:ProgramFiles (x86)\Take Control",
    "$env:ProgramData\GetSupportService_N-Central",
    "$env:ProgramData\GetSupportService",
    "$env:ProgramFiles\N-able Technologies\Take Control",
    "$env:ProgramFiles (x86)\N-able Technologies\Take Control",
    "$env:ProgramFiles\N-able Technologies\Take Control Agent",
    "$env:ProgramFiles (x86)\N-able Technologies\Take Control Agent",
    "$env:ProgramFiles\N-able Technologies\Windows Agent\Take Control",
    "$env:ProgramFiles (x86)\N-able Technologies\Windows Agent\Take Control",
    "$env:ProgramFiles\SolarWinds MSP\Take Control",
    "$env:ProgramFiles (x86)\SolarWinds MSP\Take Control",
    "$env:ProgramData\N-able Technologies\Take Control",
    "$env:ProgramData\MspPlatform\Take Control",
    "$env:ProgramData\SolarWinds MSP\Take Control"
)

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

function Find-TakeControlInstallation {
    <#
    .DESCRIPTION
        Locates the Take Control installation directory.
        First checks running processes, then predefined paths, then registry.
    #>
    
    $result = @{
        Found = $false
        Path = ""
        Version = "Unknown"
        ExecutablePath = ""
        DetectionMethod = ""
    }
    
    # METHOD 1: Find from running process (most reliable)
    foreach ($procName in $TakeControlProcesses) {
        try {
            $proc = Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                # Get the executable path from the process
                $exePath = $null
                
                # Try multiple methods to get the path
                try {
                    $exePath = $proc.Path
                }
                catch { }
                
                if (-not $exePath) {
                    try {
                        $exePath = (Get-CimInstance -Class Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).ExecutablePath
                    }
                    catch { }
                }
                
                if (-not $exePath) {
                    try {
                        $exePath = (Get-WmiObject -Class Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).ExecutablePath
                    }
                    catch { }
                }
                
                if ($exePath -and (Test-Path $exePath)) {
                    $result.Found = $true
                    $result.ExecutablePath = $exePath
                    $result.Path = Split-Path -Path $exePath -Parent
                    $result.DetectionMethod = "Running Process"
                    
                    # Get version
                    try {
                        $fileVersion = (Get-Item $exePath).VersionInfo.FileVersion
                        $result.Version = $fileVersion
                    }
                    catch {
                        $result.Version = "Could not determine"
                    }
                    
                    return $result
                }
            }
        }
        catch { }
    }
    
    # METHOD 2: Check common installation paths
    foreach ($path in $InstallPaths) {
        if (Test-Path $path) {
            $exePath = Get-ChildItem -Path $path -Filter "BASupSrvc.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exePath) {
                $result.Found = $true
                $result.Path = $path
                $result.ExecutablePath = $exePath.FullName
                $result.DetectionMethod = "Known Path"
                
                # Get version
                try {
                    $fileVersion = (Get-Item $exePath.FullName).VersionInfo.FileVersion
                    $result.Version = $fileVersion
                }
                catch {
                    $result.Version = "Could not determine"
                }
                return $result
            }
        }
    }
    
    # METHOD 3: Check registry for installation info
    $regPaths = @(
        "HKLM:\SOFTWARE\BeAnywhere",
        "HKLM:\SOFTWARE\WOW6432Node\BeAnywhere",
        "HKLM:\SOFTWARE\N-able Technologies\Take Control",
        "HKLM:\SOFTWARE\SolarWinds MSP\Take Control",
        "HKLM:\SOFTWARE\N-able Technologies",
        "HKLM:\SOFTWARE\WOW6432Node\N-able Technologies"
    )
    
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            try {
                $installDir = Get-ItemProperty -Path $regPath -Name "InstallDir" -ErrorAction SilentlyContinue
                if ($installDir -and $installDir.InstallDir -and (Test-Path $installDir.InstallDir)) {
                    $result.Found = $true
                    $result.Path = $installDir.InstallDir
                    $result.DetectionMethod = "Registry"
                    return $result
                }
            }
            catch { }
        }
    }
    
    # METHOD 4: Search for service with BASupSrvc in the path
    try {
        $services = Get-CimInstance -Class Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            $_.PathName -match "BASupSrvc|BeAnywhere|TakeControl"
        }
        
        if ($services) {
            $svc = $services | Select-Object -First 1
            # Extract path from service PathName (may include arguments)
            $svcPath = $svc.PathName -replace '"', '' -replace '\s+--.*$', '' -replace '\s+-.*$', ''
            
            if (Test-Path $svcPath) {
                $result.Found = $true
                $result.ExecutablePath = $svcPath
                $result.Path = Split-Path -Path $svcPath -Parent
                $result.DetectionMethod = "Service Registration"
                
                try {
                    $fileVersion = (Get-Item $svcPath).VersionInfo.FileVersion
                    $result.Version = $fileVersion
                }
                catch { }
                
                return $result
            }
        }
    }
    catch { }
    
    return $result
}

function Test-TakeControlService {
    <#
    .DESCRIPTION
        Checks the status of Take Control services.
        Searches by known names first, then by executable path.
    #>
    
    $result = @{
        ServiceFound = $false
        ServiceName = ""
        DisplayName = ""
        Status = "Unknown"
        StartType = "Unknown"
        Healthy = $false
        RecoveryConfigured = $false
        ServicePath = ""
        Message = ""
    }
    
    # METHOD 1: Check by known service names
    foreach ($serviceName in $TakeControlServices) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $result.ServiceFound = $true
            $result.ServiceName = $serviceName
            $result.DisplayName = $service.DisplayName
            $result.Status = $service.Status.ToString()
            $result.StartType = $service.StartType.ToString()
            
            # Get service path
            try {
                $svcInfo = Get-CimInstance -Class Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
                if ($svcInfo) {
                    $result.ServicePath = $svcInfo.PathName
                }
            }
            catch { }
            
            # Check if running
            if ($service.Status -eq "Running") {
                $result.Healthy = $true
                $result.Message = "Service '$serviceName' is running"
            }
            else {
                $result.Message = "Service '$serviceName' is $($service.Status)"
            }
            
            # Check recovery options
            try {
                $scQuery = sc.exe qfailure $serviceName 2>&1
                if ($scQuery -match "RESTART") {
                    $result.RecoveryConfigured = $true
                }
            }
            catch { }
            
            return $result
        }
    }
    
    # METHOD 2: Find service by executable path (for non-standard installations)
    # Prioritize the main BASupSrvc.exe service, not the updater
    try {
        $tcServices = Get-CimInstance -Class Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            $_.PathName -match "BASupSrvc|BeAnywhere|TakeControl|GetSupportService"
        }
        
        if ($tcServices) {
            # Prioritize: main BASupSrvc.exe service first, then others
            # Exclude updater services when looking for main service
            $mainService = $tcServices | Where-Object { 
                $_.PathName -match "BASupSrvc\.exe" -and 
                $_.PathName -notmatch "Updater|Update" 
            } | Select-Object -First 1
            
            # If no main service found, try any BASupSrvc service
            if (-not $mainService) {
                $mainService = $tcServices | Where-Object { 
                    $_.PathName -match "BASupSrvc" -and 
                    $_.PathName -notmatch "Updater|Update" 
                } | Select-Object -First 1
            }
            
            # If still not found, use the updater as fallback
            if (-not $mainService) {
                $mainService = $tcServices | Select-Object -First 1
            }
            
            $svc = $mainService
            $result.ServiceFound = $true
            $result.ServiceName = $svc.Name
            $result.DisplayName = $svc.DisplayName
            $result.Status = $svc.State
            $result.StartType = $svc.StartMode
            $result.ServicePath = $svc.PathName
            
            if ($svc.State -eq "Running") {
                $result.Healthy = $true
                $result.Message = "Service '$($svc.Name)' ($($svc.DisplayName)) is running"
            }
            else {
                $result.Message = "Service '$($svc.Name)' is $($svc.State)"
            }
            
            # Check recovery options
            try {
                $scQuery = sc.exe qfailure $svc.Name 2>&1
                if ($scQuery -match "RESTART") {
                    $result.RecoveryConfigured = $true
                }
            }
            catch { }
            
            return $result
        }
    }
    catch { }
    
    # METHOD 3: Check if processes are running without a service (standalone mode)
    $runningProcs = @()
    foreach ($procName in $TakeControlProcesses) {
        $proc = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($proc) {
            $runningProcs += $procName
        }
    }
    
    if ($runningProcs.Count -gt 0) {
        $result.ServiceFound = $false
        $result.Status = "Process Running (No Service)"
        $result.Healthy = $true  # Processes are running, even without a service
        $result.Message = "Take Control running as process(es): $($runningProcs -join ', ') - No Windows service detected"
    }
    else {
        $result.Message = "Take Control service not found"
    }
    
    return $result
}

function Test-TakeControlProcess {
    <#
    .DESCRIPTION
        Checks the health of Take Control processes.
    #>
    
    $result = @{
        ProcessFound = $false
        ProcessCount = 0
        Responding = $true
        MemoryMB = 0
        CPUPercent = 0
        Hung = $false
        ProcessDetails = @()
        Message = ""
    }
    
    foreach ($procName in $TakeControlProcesses) {
        $processes = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($processes) {
            $result.ProcessFound = $true
            
            foreach ($proc in $processes) {
                $result.ProcessCount++
                
                $procInfo = @{
                    Name = $proc.ProcessName
                    PID = $proc.Id
                    Responding = $proc.Responding
                    MemoryMB = [math]::Round($proc.WorkingSet64 / 1MB, 2)
                    StartTime = if ($proc.StartTime) { $proc.StartTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
                }
                
                $result.ProcessDetails += $procInfo
                $result.MemoryMB += $procInfo.MemoryMB
                
                if (-not $proc.Responding) {
                    $result.Responding = $false
                    $result.Hung = $true
                }
            }
        }
    }
    
    if ($result.ProcessFound) {
        if ($result.Hung) {
            $result.Message = "Found $($result.ProcessCount) process(es) - SOME NOT RESPONDING"
        }
        else {
            $result.Message = "Found $($result.ProcessCount) healthy process(es)"
        }
    }
    else {
        $result.Message = "No Take Control processes running"
    }
    
    return $result
}

function Get-TakeControlCrashEvents {
    <#
    .DESCRIPTION
        Retrieves recent crash events (EventID 1000) for BASupSrvc.exe.
    #>
    
    $result = @{
        CrashCount = 0
        RecentCrashes = @()
        LastCrashTime = $null
        FaultModules = @()
        Message = ""
    }
    
    try {
        $startTime = (Get-Date).AddDays(-7)  # Check last 7 days
        
        # EventID 1000 = Application Error (crash)
        # EventID 1001 = Windows Error Reporting
        $crashEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            Id = 1000, 1001
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -match "BASupSrvc|BASupApp|BASupTSHelper|BeAnywhere|Take.?Control"
        }
        
        if ($crashEvents) {
            $result.CrashCount = $crashEvents.Count
            $result.LastCrashTime = ($crashEvents | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
            
            # Get last 5 crashes for details
            $result.RecentCrashes = $crashEvents | Sort-Object TimeCreated -Descending | Select-Object -First 5 | ForEach-Object {
                # Parse fault module from message
                $faultModule = ""
                if ($_.Message -match "Faulting module name:\s*([^\s,]+)") {
                    $faultModule = $Matches[1]
                    if ($faultModule -notin $result.FaultModules) {
                        $result.FaultModules += $faultModule
                    }
                }
                
                @{
                    Time = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId = $_.Id
                    FaultModule = $faultModule
                    Message = $_.Message.Substring(0, [Math]::Min(300, $_.Message.Length))
                }
            }
            
            $result.Message = "$($result.CrashCount) crash event(s) in last 7 days. Last crash: $($result.LastCrashTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        }
        else {
            $result.Message = "No crash events found in last 7 days"
        }
    }
    catch {
        $result.Message = "Could not query event logs: $_"
    }
    
    return $result
}

function Get-TakeControlServiceEvents {
    <#
    .DESCRIPTION
        Retrieves service-related events (start, stop, failures).
    #>
    
    $result = @{
        StartCount = 0
        StopCount = 0
        FailureCount = 0
        RecentEvents = @()
        Message = ""
    }
    
    try {
        $startTime = (Get-Date).AddDays(-7)
        
        # Service Control Manager events
        # EventID 7034 = Service terminated unexpectedly
        # EventID 7031 = Service terminated unexpectedly, taking action
        # EventID 7036 = Service state change
        # EventID 7000 = Service failed to start
        $serviceEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Service Control Manager'
            Id = 7034, 7031, 7036, 7000
            StartTime = $startTime
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -match "BASupSrvc|BASupportExpress|BeAnywhere|Take.?Control"
        }
        
        if ($serviceEvents) {
            foreach ($evt in $serviceEvents) {
                switch ($evt.Id) {
                    7034 { $result.FailureCount++ }
                    7031 { $result.FailureCount++ }
                    7000 { $result.FailureCount++ }
                    7036 {
                        if ($evt.Message -match "running") { $result.StartCount++ }
                        elseif ($evt.Message -match "stopped") { $result.StopCount++ }
                    }
                }
            }
            
            $result.RecentEvents = $serviceEvents | Sort-Object TimeCreated -Descending | Select-Object -First 5 | ForEach-Object {
                @{
                    Time = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    EventId = $_.Id
                    Message = $_.Message.Substring(0, [Math]::Min(200, $_.Message.Length))
                }
            }
            
            $result.Message = "Service events: $($result.StartCount) starts, $($result.StopCount) stops, $($result.FailureCount) failures"
        }
        else {
            $result.Message = "No service events found in last 7 days"
        }
    }
    catch {
        $result.Message = "Could not query service events: $_"
    }
    
    return $result
}

function Test-TakeControlConnectivity {
    <#
    .DESCRIPTION
        Tests network connectivity for Take Control using TCP port tests.
        ICMP ping may be blocked, so we test actual HTTPS connectivity.
    #>
    
    $result = @{
        CanResolve = $false
        CanConnect = $false
        Latency = 0
        TestedEndpoints = @()
        SuccessfulEndpoint = ""
        Message = ""
    }
    
    # N-able Take Control endpoints - test on port 443 (HTTPS)
    $endpoints = @(
        @{ Host = "support-services.n-able.com"; Port = 443 },
        @{ Host = "download.beanywhere.com"; Port = 443 },
        @{ Host = "systemmonitor.co.uk"; Port = 443 },
        @{ Host = "systemmonitor.us"; Port = 443 },
        @{ Host = "www.n-able.com"; Port = 443 }
    )
    
    foreach ($endpoint in $endpoints) {
        $testResult = @{
            Host = $endpoint.Host
            Port = $endpoint.Port
            DnsResolved = $false
            TcpConnected = $false
        }
        
        try {
            # Test DNS resolution
            $dns = Resolve-DnsName -Name $endpoint.Host -ErrorAction SilentlyContinue
            if ($dns) {
                $result.CanResolve = $true
                $testResult.DnsResolved = $true
                
                # Test TCP connectivity on port 443 (HTTPS)
                # This is more reliable than ICMP ping which is often blocked
                $tcpTest = Test-NetConnection -ComputerName $endpoint.Host -Port $endpoint.Port -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                
                if ($tcpTest.TcpTestSucceeded) {
                    $result.CanConnect = $true
                    $result.SuccessfulEndpoint = "$($endpoint.Host):$($endpoint.Port)"
                    $testResult.TcpConnected = $true
                    
                    # Get latency if available
                    if ($tcpTest.PingReplyDetails -and $tcpTest.PingReplyDetails.RoundtripTime) {
                        $result.Latency = $tcpTest.PingReplyDetails.RoundtripTime
                    }
                    
                    $result.Message = "Connected to $($endpoint.Host):$($endpoint.Port)"
                    if ($result.Latency -gt 0) {
                        $result.Message += " ($($result.Latency)ms)"
                    }
                    
                    $result.TestedEndpoints += $testResult
                    break  # Found working endpoint, stop testing
                }
            }
        }
        catch { }
        
        $result.TestedEndpoints += $testResult
    }
    
    if (-not $result.CanResolve) {
        $result.Message = "Cannot resolve Take Control endpoints - check DNS settings"
    }
    elseif (-not $result.CanConnect) {
        $result.Message = "DNS resolves but TCP connection failed - check firewall/proxy for HTTPS (443)"
    }
    
    return $result
}

function Test-TakeControlFileIntegrity {
    <#
    .DESCRIPTION
        Verifies Take Control files are present and not corrupted.
    #>
    
    $result = @{
        FilesIntact = $true
        MissingFiles = @()
        CorruptedFiles = @()
        Message = ""
    }
    
    $installation = Find-TakeControlInstallation
    
    if (-not $installation.Found) {
        $result.FilesIntact = $false
        $result.Message = "Installation directory not found"
        return $result
    }
    
    # Check for critical files
    $criticalFiles = @(
        "BASupSrvc.exe",
        "BASupSrvcCnfg.exe",
        "BASupTSHelper.exe"
    )
    
    foreach ($file in $criticalFiles) {
        $filePath = Get-ChildItem -Path $installation.Path -Filter $file -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if (-not $filePath) {
            $result.FilesIntact = $false
            $result.MissingFiles += $file
        }
        else {
            # Check if file can be read (not corrupted/locked)
            try {
                $null = Get-FileHash -Path $filePath.FullName -Algorithm MD5 -ErrorAction Stop
            }
            catch {
                $result.CorruptedFiles += $file
            }
        }
    }
    
    if ($result.MissingFiles.Count -gt 0) {
        $result.Message = "Missing files: $($result.MissingFiles -join ', ')"
    }
    elseif ($result.CorruptedFiles.Count -gt 0) {
        $result.Message = "Corrupted/locked files: $($result.CorruptedFiles -join ', ')"
    }
    else {
        $result.Message = "All critical files present and accessible"
    }
    
    return $result
}

function Get-ServiceRecoverySettings {
    param([string]$ServiceName)
    
    $result = @{
        FirstFailure = "Unknown"
        SecondFailure = "Unknown"
        SubsequentFailures = "Unknown"
        ResetPeriod = 0
        Configured = $false
    }
    
    try {
        $scOutput = sc.exe qfailure $ServiceName 2>&1
        
        if ($scOutput -match "FIRST FAILURE:\s*(.+)") {
            $result.FirstFailure = $Matches[1].Trim()
        }
        if ($scOutput -match "SECOND FAILURE:\s*(.+)") {
            $result.SecondFailure = $Matches[1].Trim()
        }
        if ($scOutput -match "SUBSEQUENT FAILURES:\s*(.+)") {
            $result.SubsequentFailures = $Matches[1].Trim()
        }
        if ($scOutput -match "RESET_PERIOD.*?:\s*(\d+)") {
            $result.ResetPeriod = [int]$Matches[1]
        }
        
        if ($result.FirstFailure -match "RESTART" -or $result.SecondFailure -match "RESTART") {
            $result.Configured = $true
        }
    }
    catch { }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "N-sight Take Control Health Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "FAIL: Script requires administrator privileges"
    exit 1002
}

try {
    $criticalIssues = 0
    $warningIssues = 0
    $allResults = @()
    
    Write-Log ""
    Write-Log "Starting health checks..."
    
    # -------------------------------------------------------------------------
    # Check 1: Installation
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "--- Check 1: Take Control Installation ---"
    $installation = Find-TakeControlInstallation
    
    if ($installation.Found) {
        Write-Log "Installation found via: $($installation.DetectionMethod)"
        Write-Log "Path: $($installation.Path)"
        Write-Log "Executable: $($installation.ExecutablePath)"
        Write-Log "Version: $($installation.Version)"
        
        $allResults += @{
            Category = "Installation"
            Check = "Take Control Installation"
            Status = "PASS"
            Details = "Version: $($installation.Version) | Found via: $($installation.DetectionMethod)"
            Message = "Installed at: $($installation.Path)"
        }
    }
    else {
        # Check if processes are running even without found installation
        $runningProcs = @()
        foreach ($procName in $TakeControlProcesses) {
            $proc = Get-Process -Name $procName -ErrorAction SilentlyContinue
            if ($proc) {
                $runningProcs += $procName
            }
        }
        
        if ($runningProcs.Count -gt 0) {
            Write-Log "Installation path not found in standard locations" -Level "WARN"
            Write-Log "However, Take Control processes ARE running: $($runningProcs -join ', ')"
            $warningIssues++
            
            $allResults += @{
                Category = "Installation"
                Check = "Take Control Installation"
                Status = "WARNING"
                Details = "Path unknown, but processes running"
                Message = "Running processes: $($runningProcs -join ', ') - Path detection failed"
            }
        }
        else {
            Write-Log "Take Control installation not found!" -Level "ERROR"
            $criticalIssues++
            
            $allResults += @{
                Category = "Installation"
                Check = "Take Control Installation"
                Status = "FAIL"
                Details = "Not installed"
                Message = "Take Control is not installed on this system"
            }
        }
    }
    
    # -------------------------------------------------------------------------
    # Check 2: Service Status
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "--- Check 2: Take Control Service ---"
    $serviceHealth = Test-TakeControlService
    
    $serviceStatus = "PASS"
    $serviceCheckName = "Take Control Service"
    
    if ($serviceHealth.ServiceFound) {
        $serviceCheckName = "Take Control Service ($($serviceHealth.ServiceName))"
        
        if ($serviceHealth.Healthy) {
            Write-Log "Service found: $($serviceHealth.ServiceName)"
            Write-Log "Display Name: $($serviceHealth.DisplayName)"
            Write-Log "Status: $($serviceHealth.Status) | StartType: $($serviceHealth.StartType)"
            if ($serviceHealth.ServicePath) {
                Write-Log "Path: $($serviceHealth.ServicePath)"
            }
        }
        else {
            $serviceStatus = "FAIL"
            $criticalIssues++
            Write-Log "Service is not running: $($serviceHealth.Status)" -Level "ERROR"
        }
    }
    elseif ($serviceHealth.Healthy) {
        # Processes running without a registered service (standalone mode)
        $serviceStatus = "WARNING"
        $warningIssues++
        Write-Log "No Windows service found, but Take Control is running as standalone process(es)" -Level "WARN"
        Write-Log "$($serviceHealth.Message)"
    }
    else {
        $serviceStatus = "FAIL"
        $criticalIssues++
        Write-Log "Take Control service not found and no processes running" -Level "ERROR"
    }
    
    $allResults += @{
        Category = "Service"
        Check = $serviceCheckName
        Status = $serviceStatus
        Details = "Status: $($serviceHealth.Status) | StartType: $($serviceHealth.StartType)"
        Message = $serviceHealth.Message
    }
    
    # Check recovery settings (only if service exists)
    if ($serviceHealth.ServiceFound -and $serviceHealth.ServiceName) {
        $recovery = Get-ServiceRecoverySettings -ServiceName $serviceHealth.ServiceName
        
        $recoveryStatus = if ($recovery.Configured) { "PASS" } else { "WARNING" }
        if (-not $recovery.Configured) {
            $warningIssues++
            Write-Log "Service recovery not configured for auto-restart" -Level "WARN"
        }
        else {
            Write-Log "Service recovery configured: First=$($recovery.FirstFailure), Second=$($recovery.SecondFailure)"
        }
        
        $allResults += @{
            Category = "Service"
            Check = "Service Recovery Configuration"
            Status = $recoveryStatus
            Details = "1st: $($recovery.FirstFailure) | 2nd: $($recovery.SecondFailure)"
            Message = if ($recovery.Configured) { "Auto-restart on failure is configured" } else { "Auto-restart NOT configured - recommended for reliability" }
        }
    }
    
    # -------------------------------------------------------------------------
    # Check 3: Process Health
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "--- Check 3: Process Health ---"
    $processHealth = Test-TakeControlProcess
    
    $processStatus = "PASS"
    if (-not $processHealth.ProcessFound) {
        if ($serviceHealth.Healthy) {
            $processStatus = "WARNING"
            $warningIssues++
            Write-Log "Service running but no processes found - may be starting up" -Level "WARN"
        }
        else {
            $processStatus = "FAIL"
            Write-Log "No Take Control processes running" -Level "ERROR"
        }
    }
    elseif ($processHealth.Hung) {
        $processStatus = "FAIL"
        $criticalIssues++
        Write-Log "CRITICAL: Process is hung/not responding!" -Level "ERROR"
    }
    else {
        Write-Log "Processes healthy: $($processHealth.Message)"
        foreach ($proc in $processHealth.ProcessDetails) {
            Write-Log "  - $($proc.Name) (PID: $($proc.PID)) - $($proc.MemoryMB) MB - Started: $($proc.StartTime)"
        }
    }
    
    $allResults += @{
        Category = "Process"
        Check = "BASupSrvc Process"
        Status = $processStatus
        Details = "Count: $($processHealth.ProcessCount) | Memory: $($processHealth.MemoryMB) MB"
        Message = $processHealth.Message
    }
    
    # -------------------------------------------------------------------------
    # Check 4: Crash Events (EventID 1000)
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "--- Check 4: Crash Events (EventID 1000) ---"
    $crashEvents = Get-TakeControlCrashEvents
    
    $crashStatus = "PASS"
    if ($crashEvents.CrashCount -gt 10) {
        $crashStatus = "FAIL"
        $criticalIssues++
        Write-Log "CRITICAL: Excessive crashes detected ($($crashEvents.CrashCount) in 7 days)" -Level "ERROR"
    }
    elseif ($crashEvents.CrashCount -gt 3) {
        $crashStatus = "WARNING"
        $warningIssues++
        Write-Log "WARNING: Multiple crashes detected ($($crashEvents.CrashCount) in 7 days)" -Level "WARN"
    }
    elseif ($crashEvents.CrashCount -gt 0) {
        $crashStatus = "WARNING"
        $warningIssues++
        Write-Log "Some crashes detected: $($crashEvents.Message)" -Level "WARN"
    }
    else {
        Write-Log "No crashes detected in last 7 days"
    }
    
    if ($crashEvents.FaultModules.Count -gt 0) {
        Write-Log "Faulting modules: $($crashEvents.FaultModules -join ', ')" -Level "WARN"
    }
    
    $allResults += @{
        Category = "Stability"
        Check = "Crash Events (EventID 1000)"
        Status = $crashStatus
        Details = "Crashes (7 days): $($crashEvents.CrashCount)"
        Message = $crashEvents.Message
    }
    
    # -------------------------------------------------------------------------
    # Check 5: Service Events
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "--- Check 5: Service Events ---"
    $serviceEvents = Get-TakeControlServiceEvents
    
    $eventStatus = "PASS"
    if ($serviceEvents.FailureCount -gt 5) {
        $eventStatus = "WARNING"
        $warningIssues++
        Write-Log "Multiple service failures detected: $($serviceEvents.FailureCount)" -Level "WARN"
    }
    else {
        Write-Log "Service events: $($serviceEvents.Message)"
    }
    
    $allResults += @{
        Category = "Stability"
        Check = "Service Control Events"
        Status = $eventStatus
        Details = "Starts: $($serviceEvents.StartCount) | Stops: $($serviceEvents.StopCount) | Failures: $($serviceEvents.FailureCount)"
        Message = $serviceEvents.Message
    }
    
    # -------------------------------------------------------------------------
    # Check 6: File Integrity
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "--- Check 6: File Integrity ---"
    $fileIntegrity = Test-TakeControlFileIntegrity
    
    $fileStatus = "PASS"
    if (-not $fileIntegrity.FilesIntact) {
        if ($fileIntegrity.MissingFiles.Count -gt 0) {
            $fileStatus = "FAIL"
            $criticalIssues++
            Write-Log "Missing critical files!" -Level "ERROR"
        }
        else {
            $fileStatus = "WARNING"
            $warningIssues++
            Write-Log "File integrity issues detected" -Level "WARN"
        }
    }
    else {
        Write-Log "File integrity: $($fileIntegrity.Message)"
    }
    
    $allResults += @{
        Category = "Installation"
        Check = "File Integrity"
        Status = $fileStatus
        Details = "Missing: $($fileIntegrity.MissingFiles.Count) | Corrupted: $($fileIntegrity.CorruptedFiles.Count)"
        Message = $fileIntegrity.Message
    }
    
    # -------------------------------------------------------------------------
    # Check 7: Network Connectivity
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "--- Check 7: Network Connectivity ---"
    $connectivity = Test-TakeControlConnectivity
    
    $netStatus = "PASS"
    if (-not $connectivity.CanConnect) {
        $netStatus = "WARNING"
        $warningIssues++
        Write-Log "Network connectivity issues: $($connectivity.Message)" -Level "WARN"
    }
    else {
        Write-Log "Network connectivity OK: $($connectivity.Message)"
    }
    
    $allResults += @{
        Category = "Network"
        Check = "Take Control Connectivity"
        Status = $netStatus
        Details = "DNS: $($connectivity.CanResolve) | Connect: $($connectivity.CanConnect)"
        Message = $connectivity.Message
    }
    
    # =========================================================================
    # SUMMARY OUTPUT
    # =========================================================================
    Write-Log ""
    Write-Log "=========================================="
    Write-Log "Check Summary"
    Write-Log "=========================================="
    
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "TAKE CONTROL HEALTH CHECK RESULTS"
    Write-Host "=========================================="
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""
    
    # Group results by category
    $categories = $allResults | Group-Object -Property Category
    
    foreach ($category in $categories) {
        Write-Host "--- $($category.Name) ---" -ForegroundColor Cyan
        
        foreach ($result in $category.Group) {
            $statusColor = switch ($result.Status) {
                "PASS" { "Green" }
                "FAIL" { "Red" }
                "WARNING" { "Yellow" }
                default { "White" }
            }
            
            Write-Host "  [$($result.Status)] $($result.Check)" -ForegroundColor $statusColor
            Write-Host "       $($result.Details)"
            Write-Host "       $($result.Message)"
            Write-Host ""
        }
    }
    
    # Show recent crashes if any
    if ($crashEvents.RecentCrashes.Count -gt 0) {
        Write-Host "--- Recent Crash Events ---" -ForegroundColor Yellow
        foreach ($crash in $crashEvents.RecentCrashes | Select-Object -First 3) {
            Write-Host "  [$($crash.Time)] EventID $($crash.EventId)"
            Write-Host "       Faulting Module: $($crash.FaultModule)"
            Write-Host ""
        }
    }
    
    # Final verdict
    Write-Host "=========================================="
    
    if ($criticalIssues -gt 0) {
        Write-Log "Overall Status: CRITICAL - $criticalIssues critical issue(s) found" -Level "ERROR"
        Write-Host "FAIL: $criticalIssues critical issue(s) detected - Take Control likely not functional" -ForegroundColor Red
        Write-Host "=========================================="
        Write-Host ""
        Write-Host "RECOMMENDED ACTIONS:" -ForegroundColor Yellow
        Write-Host "1. Run the Remediate_TakeControl_Service.ps1 script"
        Write-Host "2. If crashes persist, reinstall Take Control from N-sight dashboard"
        Write-Host "3. Check Windows Event Viewer for additional details"
        Write-Host "4. Verify .NET Framework is up to date"
        Write-Host ""
        exit 1002
    }
    elseif ($warningIssues -gt 0) {
        Write-Log "Overall Status: WARNING - $warningIssues warning(s) found" -Level "WARN"
        Write-Host "WARNING: $warningIssues issue(s) may need attention" -ForegroundColor Yellow
        Write-Host "=========================================="
        Write-Host ""
        Write-Host "RECOMMENDATIONS:" -ForegroundColor Yellow
        Write-Host "1. Run remediation script to restart service and configure recovery"
        Write-Host "2. Monitor for continued crashes"
        Write-Host "3. Consider scheduling automatic service restart"
        Write-Host ""
        exit 1001
    }
    else {
        Write-Log "Overall Status: HEALTHY - No issues detected"
        Write-Host "PASS: Take Control service is healthy and operational" -ForegroundColor Green
        Write-Host "=========================================="
        Write-Host ""
        exit 0
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "FAIL: Take Control health check failed - $_" -ForegroundColor Red
    Write-Host "Computer: $env:COMPUTERNAME"
    
    exit 1002
}
