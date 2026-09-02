<#
.SYNOPSIS
    Installs Google Credential Provider for Windows (GCPW).
.DESCRIPTION
    Downloads the GCPW Enterprise 64-bit MSI and installs it silently.
    Registry configuration is handled by Check_GCPW_Registry.ps1.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_GCPW.ps1")
.NOTES
    Exit: 0=OK, 1002=Critical
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002
$GCPWUrl = "https://dl.google.com/credentialprovider/gcpwstandaloneenterprise64.msi"

function Test-GCPWInstalled {
    $keys = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue
    foreach ($key in $keys) {
        if ((Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).DisplayName -match "Google Credential Provider|GCPW") { return $true }
    }
    return $false
}

try {
    if (Test-GCPWInstalled) {
        Write-Host "OK: GCPW is already installed on $env:COMPUTERNAME"
        exit $EXIT_SUCCESS
    }

    $msi = Join-Path $env:TEMP "gcpwstandaloneenterprise64.msi"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $GCPWUrl -OutFile $msi -UseBasicParsing -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $msi)) { throw "GCPW MSI download failed" }

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010, 1641) { throw "msiexec exit code $($process.ExitCode)" }
    if (-not (Test-GCPWInstalled)) { throw "GCPW was not detected after installation" }

    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    Write-Host "OK: GCPW installed on $env:COMPUTERNAME"
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: GCPW installation failed on $env:COMPUTERNAME - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
