<#
.SYNOPSIS
    Tests VPN connectivity by checking access to a specific internal/VPN-protected resource.

.DESCRIPTION
    This script verifies if the VPN (e.g., Tailscale or Twingate) is functioning correctly
    by testing DNS resolution, ICMP reachability (ping), TCP port connectivity, and 
    HTTP access to 'bo.doktorabc.com'. It also measures the full page load time by 
    parsing the HTML and downloading its associated elements (images, scripts, styles).

.EXECUTION
    Windows (local):  .\Test-VpnConnectivity.ps1
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/exprimental/Test-VpnConnectivity.ps1?v=$([guid]::NewGuid())")

.OUTPUTS
    Exit 0    = Success (VPN seems to be working and resource is reachable)
    Exit 1001 = Warning (Partial connectivity issues)
    Exit 1002 = Critical/Error (Resource is completely unreachable or DNS failed)
#>

$TargetHost = "bo.doktorabc.com"
$TargetUrl = "https://$TargetHost"
$TargetPort = 443

$BaselineHost = "google.com"

$overallStatus = 0
$loadTimeMs = 0
$pingTimeMs = 0

Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "CLIENT PROFILE & BASELINE METRICS" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. GeoIP, Adapter Profile, and Baseline Speed
Write-Host "`n[1/8] Gathering Connection Profile & Baseline Speed..." -ForegroundColor Yellow

$geoCity = "Unknown"
$geoCountry = "Unknown"
$adapterType = "Unknown"
$linkSpeedMbps = "Unknown"
$baselineSpeedMbps = 0

try {
    # 1A. GeoIP (Fast API call)
    $geoData = Invoke-RestMethod -Uri "https://ipinfo.io/json" -TimeoutSec 3 -ErrorAction SilentlyContinue
    if ($geoData) {
        $geoCity = $geoData.city
        $geoCountry = $geoData.country
    }
    
    # 1B. Active Network Adapter Type & Link Speed
    $activeAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Virtual -eq $False } | Sort-Object LinkSpeed -Descending | Select-Object -First 1
    if ($activeAdapter) {
        if ($activeAdapter.InterfaceDescription -match "(?i)Wireless|Wi-Fi|802.11") {
            $adapterType = "Wi-Fi"
        }
        else {
            $adapterType = "Ethernet (Cable)"
        }
        # LinkSpeed comes back formatted like "1 Gbps" or "100 Mbps", we just grab the string or convert to Mbps
        $linkSpeedMbps = $activeAdapter.LinkSpeed
    }

    # 1C. Quick Internet Download Benchmark (Downloading a 1MB payload from Cloudflare)
    $speedTestStart = [System.Diagnostics.Stopwatch]::StartNew()
    $tempTestFile = [System.IO.Path]::GetTempFileName()
    # Download 1MB of zeros from Cloudflare speedtest server
    $null = & curl.exe -s -L -k --max-time 5 -o $tempTestFile "https://speed.cloudflare.com/__down?bytes=1048576" 
    $speedTestStart.Stop()
    
    if (Test-Path $tempTestFile) {
        $fileSize = (Get-Item $tempTestFile).Length
        if ($fileSize -gt 0 -and $speedTestStart.Elapsed.TotalSeconds -gt 0) {
            $bytesPerSec = $fileSize / $speedTestStart.Elapsed.TotalSeconds
            $baselineSpeedMbps = [math]::Round(($bytesPerSec * 8) / 1000000, 2)
        }
        Remove-Item $tempTestFile -ErrorAction SilentlyContinue
    }
    
    Write-Host "      Location:         $geoCity, $geoCountry" -ForegroundColor Gray
    Write-Host "      Connection Type:  $adapterType" -ForegroundColor Gray
    Write-Host "      Adapter Capacity: $linkSpeedMbps" -ForegroundColor Gray
    Write-Host "      Internet Speed:   $baselineSpeedMbps Mbps" -ForegroundColor Gray
}
catch {
    Write-Host "      [WARNING] Could not determine full client profile." -ForegroundColor Yellow
}

Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "VPN CONNECTIVITY CHECKS" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 2. Baseline Internet Check
Write-Host "`n[2/8] Baseline Internet Check ($BaselineHost)..." -ForegroundColor Yellow
$baselinePing = Test-Connection -ComputerName $BaselineHost -Count 1 -Quiet -ErrorAction SilentlyContinue
if ($baselinePing) {
    Write-Host "      [SUCCESS] General internet connectivity is working." -ForegroundColor Green
}
else {
    Write-Host "      [WARNING] Baseline test to $BaselineHost failed! You might not have general internet access." -ForegroundColor Red
}

# 3. Test DNS Resolution
Write-Host "`n[3/8] Testing DNS Resolution for '$TargetHost'..." -ForegroundColor Yellow
try {
    $dnsResult = Resolve-DnsName -Name $TargetHost -ErrorAction Stop
    $ips = $dnsResult | Select-Object -ExpandProperty IPAddress -ErrorAction SilentlyContinue
    if (-not $ips) {
        # Fallback if IPAddress property is missing (e.g. CNAME record only)
        $ips = [System.Net.Dns]::GetHostAddresses($TargetHost) | Select-Object -ExpandProperty IPAddressToString
    }
    Write-Output "      [SUCCESS] Resolved to IP(s): $($ips -join ', ')"
}
catch {
    try {
        # Fallback to .NET DNS resolution if Resolve-DnsName fails or is missing
        $ips = [System.Net.Dns]::GetHostAddresses($TargetHost) | Select-Object -ExpandProperty IPAddressToString
        Write-Output "      [SUCCESS] Resolved to IP(s): $($ips -join ', ')"
    }
    catch {
        Write-Host "      [FAILED] Could not resolve '$TargetHost'. Check DNS or VPN connection." -ForegroundColor Red
        $overallStatus = 1002
    }
}

# 4. Test ICMP Ping
# Only test if DNS hasn't completely failed
if ($overallStatus -ne 1002) {
    Write-Host "`n[4/8] Testing ICMP Ping to '$TargetHost'..." -ForegroundColor Yellow
    $pingResult = Test-Connection -ComputerName $TargetHost -Count 2 -ErrorAction SilentlyContinue
    if ($pingResult) {
        $pingTimeMs = ($pingResult | Measure-Object -Property ResponseTime -Average).Average
        Write-Host "      [SUCCESS] Ping successful. Average Response Time: $([math]::Round($pingTimeMs, 2)) ms" -ForegroundColor Green
    }
    else {
        Write-Host "      [FAILED] Ping failed. ICMP might be blocked, or host is unreachable." -ForegroundColor Red
        if ($overallStatus -eq 0) { $overallStatus = 1001 }
    }
}

# 5. Test Network Hops (Traceroute)
if ($overallStatus -ne 1002) {
    Write-Host "`n[5/8] Tracing route to '$TargetHost' (checking network hops)..." -ForegroundColor Yellow
    try {
        $traceStart = [System.Diagnostics.Stopwatch]::StartNew()
        # Max 15 hops (-h 15), no name resolution (-d), fast timeout (-w 1000)
        $traceOutput = tracert.exe -d -h 15 -w 1000 $TargetHost
        $traceStart.Stop()
        
        $hops = @($traceOutput | Where-Object { $_ -match "^\s*\d+" }).Count
        Write-Host "      [SUCCESS] Checked $TargetHost across $hops network hops in $([math]::Round($traceStart.Elapsed.TotalSeconds, 2)) seconds." -ForegroundColor Green
    }
    catch {
        Write-Host "      [WARNING] Traceroute failed to execute properly." -ForegroundColor Red
    }
}

# 6. Test TCP Port Connectivity
if ($overallStatus -ne 1002) {
    Write-Host "`n[6/8] Testing TCP connection to '$TargetHost' on port $TargetPort..." -ForegroundColor Yellow
    try {
        $tcpResult = Test-NetConnection -ComputerName $TargetHost -Port $TargetPort -WarningAction SilentlyContinue
        if ($tcpResult.TcpTestSucceeded) {
            Write-Host "      [SUCCESS] TCP connection to port $TargetPort succeeded." -ForegroundColor Green
        }
        else {
            Write-Host "      [FAILED] TCP connection to port $TargetPort failed." -ForegroundColor Red
            if ($overallStatus -eq 0) { $overallStatus = 1001 }
        }
    }
    catch {
        Write-Host "      [FAILED] Error testing TCP connection." -ForegroundColor Red
        if ($overallStatus -eq 0) { $overallStatus = 1001 }
    }
}

# 7. Test HTTP/HTTPS Access & Page Load Time
if ($overallStatus -ne 1002) {
    Write-Host "`n[7/8] Testing HTTP/HTTPS access to '$TargetUrl' and measuring load time..." -ForegroundColor Yellow
    try {
        # Ignore SSL errors in case the VPN endpoint uses a self-signed cert
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        
        # Enforce TLS 1.2 and aim for TLS 1.3 if supported by the OS/Framework
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor 3072 #-bor 12288 (TLS 1.3)
        }
        catch {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }
        
        $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        
        $urlsToTest = @(
            $TargetUrl,
            "https://bo.doktorabc.com/orders?page=1",
            "https://bo.doktorabc.com/pharmacies",
            "https://bo.doktorabc.com/customers"
        )
        
        $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $totalElements = 0
        
        foreach ($testUrl in $urlsToTest) {
            Write-Output "      -> Requesting document: $testUrl (via native curl)..."
            
            $tempFile = [System.IO.Path]::GetTempFileName()
            $mainRequestStart = [System.Diagnostics.Stopwatch]::StartNew()
            
            # Use native curl.exe which handles SNI and modern TLS smoothly compared to old .NET WebRequest
            $curlOptions = @("-s", "-L", "-k", "-A", $userAgent, "--max-time", "10", "-w", "%{http_code}", "-o", $tempFile, $testUrl)
            $statusCode = & curl.exe @curlOptions
            
            $mainRequestStart.Stop()
            $mainRequestTotalMs = $mainRequestStart.Elapsed.TotalMilliseconds
            
            # Allow 401/403 as well since we are "assuming logged in" without actually passing auth cookies
            if ($statusCode -match "^20|^30|^401|^403") {
                Write-Output "      [SUCCESS] HTTP request returned status code $statusCode in $([math]::Round($mainRequestTotalMs, 2)) ms."
                
                # Extract links for resources: scripts, images, css to simulate full load
                $html = Get-Content $tempFile -Raw -ErrorAction SilentlyContinue
                Remove-Item $tempFile -ErrorAction SilentlyContinue
                if (-not $html) { $html = "" }
                
                # Simple regex to find src="..." and href="..."
                $regexMatches = [regex]::Matches($html, '(?i)(?:src|href)=["'']([^"?'']+)["'']')
                $resourceUrls = @()
                
                foreach ($match in $regexMatches) {
                    $url = $match.Groups[1].Value
                    if ($url -match "\.(js|css|png|jpg|jpeg|gif|svg|ico)$" -or ($url -match "^/" -and $url -notmatch "^//")) {
                        if ($url -match "^http") {
                            $resourceUrls += $url
                        }
                        elseif ($url -match "^/") {
                            # Handle relative URLs by appending to the base URL
                            $trimmedUrl = $url.TrimStart('/')
                            $resourceUrls += "$TargetUrl/$trimmedUrl"
                        }
                    }
                }
                
                $resourceUrls = $resourceUrls | Select-Object -Unique
                $totalElements += $resourceUrls.Count
                
                if ($resourceUrls.Count -gt 0) {
                    foreach ($resUrl in $resourceUrls) {
                        try {
                            & curl.exe -s -k -A $userAgent --max-time 5 -o NUL $resUrl
                        }
                        catch {}
                    }
                }
            }
            else {
                Write-Host "      [WARNING] HTTP request for $testUrl returned unusual status code $statusCode." -ForegroundColor Red
                if ($overallStatus -eq 0) { $overallStatus = 1001 }
                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
        }
        
        $totalStopwatch.Stop()
        $loadTimeMs = $totalStopwatch.Elapsed.TotalMilliseconds
        Write-Host "      [SUCCESS] Full tests (with $totalElements elements) completed in $([math]::Round($loadTimeMs, 2)) ms." -ForegroundColor Green
        
        # Average the load time for the scoring section to keep thresholds balanced
        $loadTimeMs = $loadTimeMs / $urlsToTest.Count
    }
    catch {
        Write-Host "      [FAILED] HTTP request failed. Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($overallStatus -eq 0) { $overallStatus = 1001 }
    }
}

# 8. Tailscale Native Tunnel Diagnostics
Write-Host "`n[8/8] Checking Native Tailscale Tunnel Status..." -ForegroundColor Yellow
try {
    $tsPath = "${env:ProgramFiles}\Tailscale\tailscale.exe"
    if (Test-Path $tsPath) {
        # Extract the Tailscale IP of the destination if possible
        $tsPingOutput = & $tsPath ping -c 1 -timeout 2s $TargetHost 2>&1
        $tsPingString = $tsPingOutput -join " "
        
        if ($tsPingString -match "direct") {
            Write-Host "      [SUCCESS] Tailscale tunnel to '$TargetHost' is DIRECT." -ForegroundColor Green
        }
        elseif ($tsPingString -match "relay" -or $tsPingString -match "derp") {
            Write-Host "      [WARNING] Tailscale tunnel to '$TargetHost' is using a RELAY (DERP). Performance will be degraded." -ForegroundColor Yellow
        }
        else {
            Write-Output "      [INFO] Could not determine direct/relay status. (Server might restrict ICMP or not be a direct Tailscale node)."
        }
    }
    else {
        Write-Output "      [SKIP] Tailscale CLI not found. Assuming standard VPN."
    }
}
catch {
    Write-Output "      [SKIP] Error checking Tailscale CLI."
}


Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "FINAL DIAGNOSTIC REPORT" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# Determine Health Score (1-4)
$scoreMsg = ""
$scoreColor = "White"
$suggestedFix = ""

if ($overallStatus -eq 1002) {
    $scoreMsg = "POOR (Level 1) - Complete Failure"
    $scoreColor = "DarkRed"
    if (-not $baselinePing) {
        $suggestedFix = "Your machine cannot reach google.com. Check your local Wi-Fi, Ethernet cable, and ISP modem."
    }
    else {
        $suggestedFix = "DNS failed for $TargetHost. If using a VPN, ensure it is fully connected. If Tailscale is installed, right-click the icon and verify you are Logged In. Check that the DNS IP assigned by your VPN is reachable."
    }
}
elseif ($overallStatus -eq 1001) {
    $scoreMsg = "FAIR (Level 2) - Partial Connection Issues"
    $scoreColor = "Yellow"
    $suggestedFix = "DNS resolved but traffic is being blocked. A firewall or Anti-Virus might be blocking port $TargetPort or ICMP. Check if your VPN interface is designated as 'Public' instead of 'Private/Domain' in Windows Firewall."
}
else {
    # It passed everything, now check performance for a score
    if ($loadTimeMs -lt 1500 -and $pingTimeMs -lt 90 -and $baselineSpeedMbps -gt 10) {
        $scoreMsg = "EXCELLENT (Level 4) - Flawless Performance"
        $scoreColor = "Green"
        $suggestedFix = "Your connection is optimal! Note: A 'perfect' direct connection to the Germany server relies on the speed of light. From the Israel branch this is ~40-50ms. From the Georgia (Tbilisi) branch this is ~70-85ms. You are seeing peak physical speeds."
    }
    elseif ($loadTimeMs -lt 3000 -and $pingTimeMs -lt 150) {
        $scoreMsg = "GOOD (Level 3) - Acceptable Performance"
        $scoreColor = "Cyan"
        if ($adapterType -eq "Wi-Fi" -and $baselineSpeedMbps -lt 25) {
            $suggestedFix = "Your VPN connection is functional, but your local Wi-Fi feels sluggish (only $baselineSpeedMbps Mbps). Try moving closer to the router or plugging in an Ethernet cable."
        }
        else {
            $suggestedFix = "Connection is functional. Since you connect internationally (Georgia/Israel to Germany), anything under 150ms is highly acceptable. If it feels sluggish, try running 'Optimize-TailscalePerformance.ps1'."
        }
    }
    else {
        $scoreMsg = "FAIR (Level 2) - Slow Performance Detected"
        $scoreColor = "Yellow"
        if ($baselineSpeedMbps -lt 10) {
            $suggestedFix = "Your core internet speed is EXTREMELY SLOW right now ($baselineSpeedMbps Mbps). This is not a VPN issue; your local network (ISP or $adapterType) is choking. Reset your modem or switch away from a hotspot."
        }
        elseif ($tsPingString -match "relay") {
            $suggestedFix = "Your internet is fast ($baselineSpeedMbps Mbps), but your VPN is struggling because your local router is blocking direct connections. The VPN is falling back to a distant Relay (DERP). Run the 'Optimize-TailscalePerformance.ps1' script to force direct UDP connections."
        }
        else {
            $suggestedFix = "High latency detected ($([math]::Round($pingTimeMs, 0))ms). Run the 'Optimize-TailscalePerformance.ps1' script to force direct UDP connections, or try toggling your VPN off and on."
        }
    }
}

Write-Host "Connection Score: " -NoNewline; Write-Host $scoreMsg -ForegroundColor $scoreColor
if ($overallStatus -eq 0) {
    Write-Host "Overall Status:   PASS" -ForegroundColor Green
}
else {
    Write-Host "Overall Status:   FAIL/WARNING" -ForegroundColor Red
}

Write-Host "`nSuggested Action: $suggestedFix" -ForegroundColor White
Write-Host "=================================================`n" -ForegroundColor Cyan

Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

exit $overallStatus
