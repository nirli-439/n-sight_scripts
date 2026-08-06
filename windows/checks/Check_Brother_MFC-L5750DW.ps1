<#
.SYNOPSIS
    Check if Brother MFC-L5750DW printer is installed and ready.
    
.DESCRIPTION
    This monitoring script checks for Brother MFC-L5750DW printer and reports:
    - Installation status (installed/not installed)
    - Printer status (ready/offline/error)
    - Port configuration and connectivity
    - Driver status
    - Designed for N-Sight RMM monitoring checks
    
    Exit Codes:
    - 0 = OK (Printer is installed and ready)
    - 1 = Warning (Printer is installed but offline/has issues)
    - 2 = Critical (Printer is NOT installed)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Check_Brother_MFC-L5750DW.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Check_Brother_MFC-L5750DW.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/checks/Check_Brother_MFC-L5750DW.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
    Printer Configuration:
    - Address: brw30f77216d09b.local
    - Model: Brother MFC-L5750DW series
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "$env:TEMP\BrotherPrinterCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Printer Configuration
$PrinterAddress = "brw30f77216d09b.local"
$PrinterName = "Brother MFC-L5750DW"
$PrinterPortName = "IP_$PrinterAddress"

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

function Test-PrinterConnectivity {
    <#
    .SYNOPSIS
        Test if the printer is reachable on the network
    #>
    
    $result = @{
        IsReachable = $false
        ResolvedIP = $null
        OpenPort = $null
        ResponseTime = $null
    }
    
    # Try DNS resolution
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($PrinterAddress)
        if ($resolved) {
            $result.ResolvedIP = $resolved[0].IPAddressToString
        }
    }
    catch {
        # Could not resolve
    }
    
    # Test TCP connection on common printer ports
    $portsToTest = @(9100, 515, 631, 80)
    
    foreach ($port in $portsToTest) {
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connectResult = $tcpClient.BeginConnect($PrinterAddress, $port, $null, $null)
            $waitHandle = $connectResult.AsyncWaitHandle
            
            if ($waitHandle.WaitOne(3000, $false)) {
                if ($tcpClient.Connected) {
                    $stopwatch.Stop()
                    $result.IsReachable = $true
                    $result.OpenPort = $port
                    $result.ResponseTime = $stopwatch.ElapsedMilliseconds
                    $tcpClient.Close()
                    break
                }
            }
            $tcpClient.Close()
        }
        catch {
            # Continue to next port
        }
    }
    
    return $result
}

function Get-PrinterInstallInfo {
    <#
    .SYNOPSIS
        Get detailed information about the printer installation
    #>
    
    $result = @{
        IsInstalled = $false
        PrinterName = $null
        PortName = $null
        DriverName = $null
        PrinterStatus = $null
        Shared = $false
        Published = $false
        Location = $null
        Comment = $null
    }
    
    # Check for the specific printer by name
    $printer = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    
    if (-not $printer) {
        # Also check for any Brother MFC-L5750DW printer with different names
        $printer = Get-Printer -ErrorAction SilentlyContinue | 
                   Where-Object { $_.Name -like "*Brother*MFC*L5750*" -or 
                                  $_.DriverName -like "*Brother*MFC*L5750*" -or
                                  $_.PortName -like "*$PrinterAddress*" }
        
        if ($printer) {
            $printer = $printer | Select-Object -First 1
        }
    }
    
    if ($printer) {
        $result.IsInstalled = $true
        $result.PrinterName = $printer.Name
        $result.PortName = $printer.PortName
        $result.DriverName = $printer.DriverName
        $result.PrinterStatus = $printer.PrinterStatus.ToString()
        $result.Shared = $printer.Shared
        $result.Published = $printer.Published
        $result.Location = $printer.Location
        $result.Comment = $printer.Comment
    }
    
    return $result
}

function Get-PrinterPortInfo {
    <#
    .SYNOPSIS
        Get information about the printer port
    #>
    
    $result = @{
        PortExists = $false
        PortName = $null
        PortType = $null
        PrinterHostAddress = $null
    }
    
    # Check for the specific port
    $port = Get-PrinterPort -Name $PrinterPortName -ErrorAction SilentlyContinue
    
    if (-not $port) {
        # Check for any port that uses this address
        $port = Get-PrinterPort -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -like "*$PrinterAddress*" -or 
                              $_.PrinterHostAddress -like "*$PrinterAddress*" -or
                              $_.PrinterHostAddress -like "*brw30f77216d09b*" }
        
        if ($port) {
            $port = $port | Select-Object -First 1
        }
    }
    
    if ($port) {
        $result.PortExists = $true
        $result.PortName = $port.Name
        $result.PortType = $port.GetType().Name
        
        # Get host address if it's a TCP/IP port
        if ($port.PrinterHostAddress) {
            $result.PrinterHostAddress = $port.PrinterHostAddress
        }
    }
    
    return $result
}

function Get-PrinterDriverInfo {
    <#
    .SYNOPSIS
        Get information about installed Brother drivers
    #>
    
    $result = @{
        DriverInstalled = $false
        DriverName = $null
        DriverVersion = $null
        Manufacturer = $null
    }
    
    # Look for Brother MFC-L5750DW driver
    $driver = Get-PrinterDriver -ErrorAction SilentlyContinue | 
              Where-Object { $_.Name -like "*Brother*MFC*L5750*" -or 
                            $_.Name -like "*Brother MFC-L5750DW*" }
    
    if ($driver) {
        $driver = $driver | Select-Object -First 1
        $result.DriverInstalled = $true
        $result.DriverName = $driver.Name
        $result.Manufacturer = $driver.Manufacturer
        
        # Try to get driver version
        if ($driver.DriverVersion) {
            $result.DriverVersion = $driver.DriverVersion
        }
    }
    
    return $result
}

function Get-PrinterQueueStatus {
    <#
    .SYNOPSIS
        Get the current status of the print queue
    #>
    
    $result = @{
        QueueExists = $false
        JobCount = 0
        ErrorJobs = 0
        PrinterReady = $false
        StatusMessage = $null
    }
    
    try {
        # Get WMI printer info for detailed status
        $wmiPrinter = Get-CimInstance -ClassName Win32_Printer | 
                      Where-Object { $_.Name -eq $PrinterName -or 
                                    $_.Name -like "*Brother*MFC*L5750*" }
        
        if ($wmiPrinter) {
            $wmiPrinter = $wmiPrinter | Select-Object -First 1
            $result.QueueExists = $true
            
            # Check printer status
            # PrinterStatus values: 1=Other, 2=Unknown, 3=Idle, 4=Printing, 5=Warmup, 6=Stopped, 7=Offline
            $statusCodes = @{
                1 = "Other"
                2 = "Unknown"
                3 = "Idle"
                4 = "Printing"
                5 = "Warmup"
                6 = "Stopped Printing"
                7 = "Offline"
            }
            
            $printerStatusCode = $wmiPrinter.PrinterStatus
            $result.StatusMessage = $statusCodes[$printerStatusCode]
            
            if (-not $result.StatusMessage) {
                $result.StatusMessage = "Status Code: $printerStatusCode"
            }
            
            # Printer is ready if Idle, Printing, or Warmup
            $result.PrinterReady = ($printerStatusCode -in @(3, 4, 5))
            
            # Check for work offline mode
            if ($wmiPrinter.WorkOffline) {
                $result.StatusMessage += " (Work Offline)"
                $result.PrinterReady = $false
            }
        }
        
        # Get print jobs
        $jobs = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue
        
        if ($jobs) {
            $result.JobCount = $jobs.Count
            $result.ErrorJobs = ($jobs | Where-Object { $_.JobStatus -like "*Error*" }).Count
        }
    }
    catch {
        # Continue with partial info
    }
    
    return $result
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Brother MFC-L5750DW Printer Check"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"
Write-Log ""
Write-Log "Expected Configuration:"
Write-Log "  Printer Name: $PrinterName"
Write-Log "  Address: $PrinterAddress"
Write-Log "  Port: $PrinterPortName"
Write-Log ""

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "CRITICAL: Script requires administrator privileges"
    exit 1002
}

try {
    # Gather all printer information
    Write-Log "Checking printer installation..."
    $printerInfo = Get-PrinterInstallInfo
    
    Write-Log "Checking printer port..."
    $portInfo = Get-PrinterPortInfo
    
    Write-Log "Checking printer driver..."
    $driverInfo = Get-PrinterDriverInfo
    
    Write-Log "Checking network connectivity..."
    $connectivityInfo = Test-PrinterConnectivity
    
    Write-Log "Checking print queue status..."
    $queueInfo = Get-PrinterQueueStatus
    
    # Log all gathered information
    Write-Log ""
    Write-Log "=========================================="
    Write-Log "Check Results"
    Write-Log "=========================================="
    
    Write-Log "Installation: $(if ($printerInfo.IsInstalled) { 'INSTALLED' } else { 'NOT INSTALLED' })"
    
    if ($printerInfo.IsInstalled) {
        Write-Log "  Printer Name: $($printerInfo.PrinterName)"
        Write-Log "  Port Name: $($printerInfo.PortName)"
        Write-Log "  Driver: $($printerInfo.DriverName)"
        Write-Log "  Status: $($printerInfo.PrinterStatus)"
    }
    
    Write-Log ""
    Write-Log "Port: $(if ($portInfo.PortExists) { 'EXISTS' } else { 'NOT FOUND' })"
    
    if ($portInfo.PortExists) {
        Write-Log "  Port Name: $($portInfo.PortName)"
        Write-Log "  Host Address: $($portInfo.PrinterHostAddress)"
    }
    
    Write-Log ""
    Write-Log "Driver: $(if ($driverInfo.DriverInstalled) { 'INSTALLED' } else { 'NOT FOUND' })"
    
    if ($driverInfo.DriverInstalled) {
        Write-Log "  Driver Name: $($driverInfo.DriverName)"
        Write-Log "  Manufacturer: $($driverInfo.Manufacturer)"
    }
    
    Write-Log ""
    Write-Log "Network: $(if ($connectivityInfo.IsReachable) { 'REACHABLE' } else { 'NOT REACHABLE' })"
    
    if ($connectivityInfo.ResolvedIP) {
        Write-Log "  Resolved IP: $($connectivityInfo.ResolvedIP)"
    }
    
    if ($connectivityInfo.IsReachable) {
        Write-Log "  Open Port: $($connectivityInfo.OpenPort)"
        Write-Log "  Response Time: $($connectivityInfo.ResponseTime)ms"
    }
    
    Write-Log ""
    Write-Log "Queue: $(if ($queueInfo.QueueExists) { 'EXISTS' } else { 'NOT FOUND' })"
    
    if ($queueInfo.QueueExists) {
        Write-Log "  Status: $($queueInfo.StatusMessage)"
        Write-Log "  Ready: $($queueInfo.PrinterReady)"
        Write-Log "  Jobs in Queue: $($queueInfo.JobCount)"
        
        if ($queueInfo.ErrorJobs -gt 0) {
            Write-Log "  Error Jobs: $($queueInfo.ErrorJobs)" -Level "WARNING"
        }
    }
    
    Write-Log "=========================================="
    
    # Determine exit code based on status
    if ($printerInfo.IsInstalled) {
        # Printer is installed - check if it's working properly
        $warnings = @()
        
        if (-not $connectivityInfo.IsReachable) {
            $warnings += "Printer not reachable on network"
        }
        
        if (-not $queueInfo.PrinterReady) {
            $warnings += "Printer not ready: $($queueInfo.StatusMessage)"
        }
        
        if ($queueInfo.ErrorJobs -gt 0) {
            $warnings += "$($queueInfo.ErrorJobs) jobs with errors in queue"
        }
        
        if ($printerInfo.PrinterStatus -eq "Offline") {
            $warnings += "Printer is offline"
        }
        
        if ($warnings.Count -eq 0) {
            # Everything looks good
            Write-Host ""
            Write-Host "OK: Brother MFC-L5750DW printer is installed and ready"
            Write-Host "  Printer Name: $($printerInfo.PrinterName)"
            Write-Host "  Driver: $($printerInfo.DriverName)"
            Write-Host "  Status: $($queueInfo.StatusMessage)"
            Write-Host "  Address: $PrinterAddress"
            
            if ($connectivityInfo.ResolvedIP) {
                Write-Host "  IP Address: $($connectivityInfo.ResolvedIP)"
            }
            
            Write-Host "  Response Time: $($connectivityInfo.ResponseTime)ms"
            
            exit 0
        }
        else {
            # Printer installed but has issues
            Write-Host ""
            Write-Host "WARNING: Brother MFC-L5750DW printer has issues"
            Write-Host "  Printer Name: $($printerInfo.PrinterName)"
            Write-Host "  Issues:"
            
            foreach ($warning in $warnings) {
                Write-Host "    - $warning"
            }
            
            exit 1001
        }
    }
    else {
        # Printer not installed
        Write-Log "Printer not installed" -Level "WARNING"
        
        # Provide additional diagnostic info
        $diagnostics = @()
        
        if ($driverInfo.DriverInstalled) {
            $diagnostics += "Driver is installed ($($driverInfo.DriverName))"
        }
        else {
            $diagnostics += "Driver is NOT installed"
        }
        
        if ($portInfo.PortExists) {
            $diagnostics += "Port exists ($($portInfo.PortName))"
        }
        else {
            $diagnostics += "Port does NOT exist"
        }
        
        if ($connectivityInfo.IsReachable) {
            $diagnostics += "Printer is reachable on network (IP: $($connectivityInfo.ResolvedIP))"
        }
        else {
            $diagnostics += "Printer is NOT reachable on network"
        }
        
        Write-Host ""
        Write-Host "CRITICAL: Brother MFC-L5750DW printer is NOT installed"
        Write-Host "  Expected Name: $PrinterName"
        Write-Host "  Expected Address: $PrinterAddress"
        Write-Host "  Diagnostics:"
        
        foreach ($diag in $diagnostics) {
            Write-Host "    - $diag"
        }
        
        exit 1002
    }
}
catch {
    Write-Log "Check failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "CRITICAL: Brother printer check failed - $_"
    
    exit 1002
}
