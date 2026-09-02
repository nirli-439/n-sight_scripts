<#
.SYNOPSIS
    Installs Google Chrome Enterprise for all users.
.DESCRIPTION
    Downloads Chrome's Enterprise MSI and installs it silently. GCPW requires Chrome.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_Chrome.ps1")
.NOTES
    Exit: 0=OK, 1002=CRITICAL
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$ChromeMsiUrl64 = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
$ChromeMsiUrl32 = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise.msi"

function Get-ChromePath {
    @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

try {
    $chrome = Get-ChromePath
    if ($chrome) {
        Write-Host "OK: Google Chrome $((Get-Item -LiteralPath $chrome).VersionInfo.ProductVersion) is already installed"
        exit $EXIT_SUCCESS
    }

    $msi = Join-Path $env:TEMP "GoogleChromeEnterprise.msi"
    $url = if ([Environment]::Is64BitOperatingSystem) { $ChromeMsiUrl64 } else { $ChromeMsiUrl32 }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $msi)) { throw "Chrome MSI download failed" }

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$msi`" /qn /norestart ALLUSERS=1" -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010, 1641) { throw "msiexec exit code $($process.ExitCode)" }

    $chrome = Get-ChromePath
    if (-not $chrome) { throw "Chrome was not detected after installation" }

    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    Write-Host "OK: Google Chrome $((Get-Item -LiteralPath $chrome).VersionInfo.ProductVersion) installed at $chrome"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Chrome installation failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
