<#
.SYNOPSIS
    Install and configure Brother MFC-L5750DW network printer.
    
.DESCRIPTION
    This script installs and configures a Brother MFC-L5750DW network printer:
    - Adds a TCP/IP printer port for the network printer
    - Downloads and installs Brother MFC-L5750DW drivers
    - Configures the printer with the correct driver
    - Performs a test print with up to 5 retries if it fails
    
    Designed for N-Sight RMM deployment as remediation task.
    
    Exit Codes:
    - 0 = Success (Printer installed and test print successful)
    - 1 = Error (Installation or test print failed after retries)
    
.EXECUTION
    Windows (local):  iex (Get-Content ".\Install_Brother_MFC-L5750DW.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_Brother_MFC-L5750DW.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Install_Brother_MFC-L5750DW.ps1")
.NOTES
    Author: IT Admin
    Version: 1.0
    Requires: Administrator privileges
    Platform: Windows 10/11
    
    Printer Configuration:
    - Address: http://brw30f77216d09b.local/
    - Model: Brother MFC-L5750DW series
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up downloads

$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Install_Brother_MFC-L5750DW_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Printer Configuration
$PrinterAddress = "brw30f77216d09b.local"
$PrinterName = "Brother MFC-L5750DW"
$PrinterPortName = "IP_$PrinterAddress"
$DriverName = "Brother MFC-L5750DW series"

# Brother Driver Download Configuration
# Brother Universal Print Driver (PCL) - works for MFC-L5750DW
$BrotherDriverUrl = "https://download.brother.com/welcome/dlf104417/MFC-L5750DW-inst-B1-US.exe"
$DriverDownloadPath = "$env:TEMP\BrotherDriver.exe"
$DriverExtractPath = "$env:TEMP\BrotherDriver"

# Test print retry configuration
$MaxTestPrintRetries = 5
$RetryDelaySeconds = 10

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
    Write-Log "Testing printer connectivity to $PrinterAddress..."
    
    # Try DNS resolution first
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($PrinterAddress)
        Write-Log "Printer resolved to IP: $($resolved.IPAddressToString -join ', ')"
    }
    catch {
        Write-Log "Could not resolve hostname $PrinterAddress - trying direct connection anyway" -Level "WARNING"
    }
    
    # Test TCP connection on common printer ports
    $portsToTest = @(9100, 515, 631, 80)
    $connected = $false
    
    foreach ($port in $portsToTest) {
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connectResult = $tcpClient.BeginConnect($PrinterAddress, $port, $null, $null)
            $waitHandle = $connectResult.AsyncWaitHandle
            
            if ($waitHandle.WaitOne(3000, $false)) {
                if ($tcpClient.Connected) {
                    Write-Log "Printer is reachable on port $port"
                    $connected = $true
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
    
    if (-not $connected) {
        Write-Log "Warning: Could not verify printer connectivity. Proceeding with installation anyway." -Level "WARNING"
    }
    
    return $connected
}

function Test-PrinterExists {
    <#
    .SYNOPSIS
        Check if the printer is already installed
    #>
    $existingPrinter = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    return $null -ne $existingPrinter
}

function Test-PrinterPortExists {
    <#
    .SYNOPSIS
        Check if the printer port already exists
    #>
    $existingPort = Get-PrinterPort -Name $PrinterPortName -ErrorAction SilentlyContinue
    return $null -ne $existingPort
}

function Test-PrinterDriverExists {
    <#
    .SYNOPSIS
        Check if the Brother driver is already installed
    #>
    $existingDriver = Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue
    return $null -ne $existingDriver
}

function Add-PrinterPortIfNeeded {
    <#
    .SYNOPSIS
        Add TCP/IP printer port if it doesn't exist
    #>
    if (Test-PrinterPortExists) {
        Write-Log "Printer port '$PrinterPortName' already exists"
        return $true
    }
    
    Write-Log "Creating TCP/IP printer port: $PrinterPortName"
    
    try {
        Add-PrinterPort -Name $PrinterPortName -PrinterHostAddress $PrinterAddress
        Write-Log "Printer port created successfully"
        return $true
    }
    catch {
        Write-Log "Failed to create printer port: $_" -Level "ERROR"
        return $false
    }
}

function Install-BrotherDriver {
    <#
    .SYNOPSIS
        Download and install Brother MFC-L5750DW driver
    #>
    
    # Check if driver is already installed
    if (Test-PrinterDriverExists) {
        Write-Log "Brother driver '$DriverName' is already installed"
        return $true
    }
    
    Write-Log "Brother driver not found. Attempting to install..."
    
    # First, try to use Windows Update to find the driver
    Write-Log "Checking if driver is available via Windows Update..."
    
    try {
        # Try to add driver from Windows driver store first
        $windowsDrivers = Get-WindowsDriver -Online -All | Where-Object { $_.ProviderName -like "*Brother*" -and $_.ClassName -eq "Printer" }
        
        if ($windowsDrivers) {
            Write-Log "Found Brother drivers in Windows driver store"
            
            # Try to use pnputil to install the driver
            foreach ($driver in $windowsDrivers) {
                if ($driver.OriginalFileName -like "*MFC*L5750*" -or $driver.OriginalFileName -like "*mfcl5750*") {
                    Write-Log "Installing driver from: $($driver.OriginalFileName)"
                    $result = pnputil /add-driver $driver.OriginalFileName /install 2>&1
                    Write-Log "PnPUtil result: $result"
                }
            }
        }
    }
    catch {
        Write-Log "Could not check Windows driver store: $_" -Level "WARNING"
    }
    
    # Check again if driver is now available
    if (Test-PrinterDriverExists) {
        Write-Log "Brother driver is now available"
        return $true
    }
    
    # Try to use built-in Brother driver if available
    Write-Log "Attempting to add driver from Windows built-in drivers..."
    
    try {
        # Look for any Brother drivers that might be compatible
        $infPath = "$env:SystemRoot\System32\DriverStore\FileRepository"
        $brotherInfs = Get-ChildItem -Path $infPath -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue | 
                       Where-Object { $_.FullName -like "*brother*" -or $_.FullName -like "*brohl*" }
        
        foreach ($inf in $brotherInfs) {
            Write-Log "Found Brother INF: $($inf.FullName)"
            
            try {
                # Add the driver using the INF file
                $result = pnputil /add-driver $inf.FullName /install 2>&1
                Write-Log "Driver install result: $result"
                
                # Add the printer driver
                Add-PrinterDriver -Name $DriverName -InfPath $inf.FullName -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "Could not add driver from $($inf.Name): $_" -Level "WARNING"
            }
        }
    }
    catch {
        Write-Log "Could not search for Brother INF files: $_" -Level "WARNING"
    }
    
    # Check again if driver is now available
    if (Test-PrinterDriverExists) {
        Write-Log "Brother driver is now available"
        return $true
    }
    
    # Download driver package from Brother
    Write-Log "Downloading Brother driver package..."
    
    # Set TLS 1.2 for secure download
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    try {
        Invoke-WebRequest -Uri $BrotherDriverUrl -OutFile $DriverDownloadPath -UseBasicParsing
        Write-Log "Driver package downloaded: $DriverDownloadPath"
    }
    catch {
        Write-Log "Failed to download Brother driver: $_" -Level "ERROR"
        Write-Log "Trying alternative driver source..."
        
        # Try alternative URL
        $altUrl = "https://download.brother.com/welcome/dlf104414/MFC-L5750DW-inst-C1-US.exe"
        try {
            Invoke-WebRequest -Uri $altUrl -OutFile $DriverDownloadPath -UseBasicParsing
            Write-Log "Alternative driver package downloaded"
        }
        catch {
            Write-Log "Failed to download driver from alternative source: $_" -Level "ERROR"
            return $false
        }
    }
    
    # Verify download
    if (-not (Test-Path $DriverDownloadPath)) {
        Write-Log "Downloaded driver file not found!" -Level "ERROR"
        return $false
    }
    
    $fileSize = (Get-Item $DriverDownloadPath).Length / 1MB
    Write-Log "Downloaded file size: $([math]::Round($fileSize, 2)) MB"
    
    # Extract/Install the driver
    Write-Log "Extracting/Installing Brother driver..."
    
    # Create extraction directory
    if (Test-Path $DriverExtractPath) {
        Remove-Item $DriverExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $DriverExtractPath -Force | Out-Null
    
    try {
        # Brother driver installers typically support silent installation
        # Try silent extraction first
        $silentArgs = @("/S", "/extract:$DriverExtractPath")
        $process = Start-Process -FilePath $DriverDownloadPath -ArgumentList $silentArgs -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        
        if ($process.ExitCode -ne 0) {
            # Try alternative silent install
            Write-Log "Trying alternative silent installation..."
            $silentArgs = @("/s", "/TYPE:FULL", "/NOUI")
            $process = Start-Process -FilePath $DriverDownloadPath -ArgumentList $silentArgs -Wait -PassThru -NoNewWindow
        }
        
        Write-Log "Driver installation exit code: $($process.ExitCode)"
    }
    catch {
        Write-Log "Error during driver installation: $_" -Level "WARNING"
    }
    
    # Wait for driver to be available
    Write-Log "Waiting for driver to become available..."
    $maxWait = 60
    $waited = 0
    
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5
        
        if (Test-PrinterDriverExists) {
            Write-Log "Brother driver is now available after $waited seconds"
            return $true
        }
        
        # Check for any Brother driver that might work
        $brotherDrivers = Get-PrinterDriver | Where-Object { $_.Name -like "*Brother*MFC*L5750*" -or $_.Name -like "*Brother*" }
        if ($brotherDrivers) {
            Write-Log "Found Brother driver(s): $($brotherDrivers.Name -join ', ')"
            # Update driver name to match what's available
            $script:DriverName = ($brotherDrivers | Select-Object -First 1).Name
            Write-Log "Using driver: $DriverName"
            return $true
        }
    }
    
    # Last resort: Try using a generic PCL driver
    Write-Log "Brother-specific driver not found. Attempting to use generic driver..." -Level "WARNING"
    
    $genericDrivers = @(
        "Microsoft Print To PDF",
        "Microsoft IPP Class Driver",
        "HP Universal Printing PCL 6",
        "Generic / Text Only"
    )
    
    foreach ($genericDriver in $genericDrivers) {
        $driver = Get-PrinterDriver -Name $genericDriver -ErrorAction SilentlyContinue
        if ($driver) {
            Write-Log "Found generic driver: $genericDriver" -Level "WARNING"
            Write-Log "Note: For best results, install the official Brother driver from https://support.brother.com" -Level "WARNING"
            $script:DriverName = $genericDriver
            return $true
        }
    }
    
    Write-Log "No suitable driver found!" -Level "ERROR"
    return $false
}

function Add-BrotherPrinter {
    <#
    .SYNOPSIS
        Add the Brother printer using the installed driver
    #>
    
    if (Test-PrinterExists) {
        Write-Log "Printer '$PrinterName' already exists"
        return $true
    }
    
    Write-Log "Adding printer '$PrinterName' with driver '$DriverName' on port '$PrinterPortName'"
    
    try {
        Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PrinterPortName
        Write-Log "Printer added successfully"
        return $true
    }
    catch {
        Write-Log "Failed to add printer: $_" -Level "ERROR"
        return $false
    }
}

function Invoke-TestPrint {
    <#
    .SYNOPSIS
        Send a test page to the printer
    #>
    param(
        [int]$AttemptNumber = 1
    )
    
    Write-Log "Sending test page (Attempt $AttemptNumber of $MaxTestPrintRetries)..."
    
    try {
        # Get the printer object
        $printer = Get-CimInstance -ClassName Win32_Printer | Where-Object { $_.Name -eq $PrinterName }
        
        if (-not $printer) {
            Write-Log "Could not find printer '$PrinterName' in WMI" -Level "ERROR"
            return $false
        }
        
        # Send test page using WMI method
        $result = Invoke-CimMethod -InputObject $printer -MethodName PrintTestPage
        
        if ($result.ReturnValue -eq 0) {
            Write-Log "Test page sent successfully"
            
            # Wait a moment for print job to be processed
            Start-Sleep -Seconds 5
            
            # Check for print job errors
            $printJobs = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue
            
            if ($printJobs) {
                $errorJobs = $printJobs | Where-Object { $_.JobStatus -like "*Error*" -or $_.JobStatus -like "*Offline*" }
                
                if ($errorJobs) {
                    Write-Log "Print job has error status: $($errorJobs.JobStatus)" -Level "WARNING"
                    return $false
                }
            }
            
            Write-Log "Test print appears successful"
            return $true
        }
        else {
            Write-Log "PrintTestPage returned error code: $($result.ReturnValue)" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Error during test print: $_" -Level "WARNING"
        return $false
    }
}

function Invoke-TestPrintWithRetry {
    <#
    .SYNOPSIS
        Attempt test print with retries
    #>
    
    for ($attempt = 1; $attempt -le $MaxTestPrintRetries; $attempt++) {
        Write-Log "=========================================="
        Write-Log "Test Print Attempt $attempt of $MaxTestPrintRetries"
        Write-Log "=========================================="
        
        $success = Invoke-TestPrint -AttemptNumber $attempt
        
        if ($success) {
            Write-Log "Test print successful on attempt $attempt"
            return $true
        }
        
        if ($attempt -lt $MaxTestPrintRetries) {
            Write-Log "Test print failed. Waiting $RetryDelaySeconds seconds before retry..."
            
            # Clear any stuck print jobs before retry
            try {
                $printJobs = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue
                foreach ($job in $printJobs) {
                    Remove-PrintJob -InputObject $job -ErrorAction SilentlyContinue
                    Write-Log "Cleared print job: $($job.Id)"
                }
            }
            catch {
                Write-Log "Could not clear print jobs: $_" -Level "WARNING"
            }
            
            # Try to restart the print spooler if having issues
            if ($attempt -ge 3) {
                Write-Log "Restarting Print Spooler service..."
                try {
                    Restart-Service -Name Spooler -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 5
                    Write-Log "Print Spooler restarted"
                }
                catch {
                    Write-Log "Could not restart Print Spooler: $_" -Level "WARNING"
                }
            }
            
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    
    Write-Log "Test print failed after $MaxTestPrintRetries attempts" -Level "ERROR"
    return $false
}

# ============================================================================
# CLEANUP FUNCTION
# ============================================================================

function Invoke-Cleanup {
    <#
    .SYNOPSIS
        Clean up temporary files
    #>
    Write-Log "Cleaning up temporary files..."
    
    if (Test-Path $DriverDownloadPath) {
        Remove-Item $DriverDownloadPath -Force -ErrorAction SilentlyContinue
        Write-Log "Removed: $DriverDownloadPath"
    }
    
    if (Test-Path $DriverExtractPath) {
        Remove-Item $DriverExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed: $DriverExtractPath"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Log "=========================================="
Write-Log "Brother MFC-L5750DW Printer Installation"
Write-Log "=========================================="
Write-Log "Computer Name: $env:COMPUTERNAME"
Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Log "Script Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Log File: $LogFile"
Write-Log ""
Write-Log "Printer Configuration:"
Write-Log "  Address: $PrinterAddress"
Write-Log "  Name: $PrinterName"
Write-Log "  Driver: $DriverName"
Write-Log "  Port: $PrinterPortName"
Write-Log ""

# Check for admin privileges
if (-not (Test-IsAdmin)) {
    Write-Log "This script requires administrator privileges!" -Level "ERROR"
    Write-Host "ERROR: Script requires administrator privileges"
    exit 1001
}

try {
    # Step 1: Test printer connectivity
    Write-Log "=========================================="
    Write-Log "Step 1: Testing Printer Connectivity"
    Write-Log "=========================================="
    Test-PrinterConnectivity
    
    # Step 2: Create printer port
    Write-Log "=========================================="
    Write-Log "Step 2: Creating Printer Port"
    Write-Log "=========================================="
    if (-not (Add-PrinterPortIfNeeded)) {
        throw "Failed to create printer port"
    }
    
    # Step 3: Install printer driver
    Write-Log "=========================================="
    Write-Log "Step 3: Installing Printer Driver"
    Write-Log "=========================================="
    if (-not (Install-BrotherDriver)) {
        throw "Failed to install printer driver"
    }
    
    # Step 4: Add the printer
    Write-Log "=========================================="
    Write-Log "Step 4: Adding Printer"
    Write-Log "=========================================="
    if (-not (Add-BrotherPrinter)) {
        throw "Failed to add printer"
    }
    
    # Verify printer is ready
    Write-Log "Verifying printer is ready..."
    Start-Sleep -Seconds 3
    
    $printer = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if ($printer) {
        Write-Log "Printer Status: $($printer.PrinterStatus)"
        Write-Log "Printer Port: $($printer.PortName)"
        Write-Log "Driver Name: $($printer.DriverName)"
    }
    
    # Step 5: Test print with retries
    Write-Log "=========================================="
    Write-Log "Step 5: Test Print (with $MaxTestPrintRetries retries)"
    Write-Log "=========================================="
    $testPrintSuccess = Invoke-TestPrintWithRetry
    
    # Final status
    Write-Log "=========================================="
    Write-Log "Installation Summary"
    Write-Log "=========================================="
    
    if ($testPrintSuccess) {
        Write-Log "SUCCESS: Brother MFC-L5750DW printer installed and test print successful!"
        Write-Log "=========================================="
        
        Write-Host ""
        Write-Host "SUCCESS: Brother MFC-L5750DW printer installed successfully!"
        Write-Host "  Printer Name: $PrinterName"
        Write-Host "  Address: $PrinterAddress"
        Write-Host "  Driver: $DriverName"
        Write-Host "  Test Print: PASSED"
        Write-Host ""
        
        exit 0
    }
    else {
        Write-Log "WARNING: Printer installed but test print failed after $MaxTestPrintRetries attempts" -Level "WARNING"
        Write-Log "The printer may still work - please verify manually" -Level "WARNING"
        Write-Log "=========================================="
        
        Write-Host ""
        Write-Host "WARNING: Printer installed but test print failed"
        Write-Host "  Printer Name: $PrinterName"
        Write-Host "  Address: $PrinterAddress"
        Write-Host "  Driver: $DriverName"
        Write-Host "  Test Print: FAILED after $MaxTestPrintRetries attempts"
        Write-Host ""
        Write-Host "Please verify the printer manually."
        Write-Host ""
        
        # Return error since test print failed
        exit 1001
    }
}
catch {
    Write-Log "Script failed with error: $_" -Level "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Log "=========================================="
    
    Write-Host ""
    Write-Host "ERROR: Brother printer installation failed - $_"
    
    exit 1001
}
finally {
    Invoke-Cleanup
}
