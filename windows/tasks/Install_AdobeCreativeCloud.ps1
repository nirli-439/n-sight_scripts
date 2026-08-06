<#
.SYNOPSIS
    Installs the Adobe Creative Cloud desktop app (the Creative Cloud “suite” hub; bootstrapper, silent).

.DESCRIPTION
    Installs the Creative Cloud desktop application used to download and manage Adobe apps
    (Photoshop, Illustrator, Acrobat, etc.). This is the standard “Adobe Cloud / Creative Cloud suite”
    installer—not individual apps by themselves.

    Downloads Adobe’s official Creative Cloud Set-Up bootstrapper, runs it silently, then
    waits for the Creative Cloud desktop app to appear. Use after Fix_AdobeCreativeCloud_Loading.ps1
    if OOBE/cache was cleared.

    Default source: Adobe CDN bootstrapper (small EXE; may download additional payloads).
    Optional: -PreferWinget uses winget package Adobe.CreativeCloud when winget is available.

    Users must sign in to Creative Cloud with an Adobe ID after install (not automated).

.EXECUTION
    Windows (local):  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install_AdobeCreativeCloud.ps1"
    Windows (repo):   iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/<COMMIT>/windows/tasks/Install_AdobeCreativeCloud.ps1")

.PARAMETER PreferWinget
    Use winget install -e --id Adobe.CreativeCloud instead of the Adobe CDN bootstrapper.

.PARAMETER InstallerUrl
    Override download URL for the bootstrapper EXE (advanced).

.PARAMETER MaxWaitMinutes
    Max time to wait for Creative Cloud.exe after the installer exits (default 25).

.PARAMETER Force
    Run the installer even if Creative Cloud.exe is already present (repair / reinstall attempt).

.NOTES
    Requires: Administrator privileges
    Platform: Windows 10/11 (x64)
    Exit 0 = Already installed or install verified
    Exit 1001 = Failure

    When run via iex (irm ...), this script avoids calling exit so your PowerShell window is not closed.
    For N-Sight / Task Scheduler, run with powershell.exe -File so exit codes propagate.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$PreferWinget,
    [switch]$Force,
    [string]$InstallerUrl = "https://ccmdls.adobe.com/AdobeProducts/KCCC/1/win32/CreativeCloudSet-Up.exe",
    [int]$MaxWaitMinutes = 25
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
}
$LogFile = Join-Path $LogDir "Install_AdobeCreativeCloud_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$DownloadPath = Join-Path $env:TEMP "CreativeCloudSet-Up.exe"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CreativeCloudInstallStatus {
    $paths = @(
        "${env:ProgramFiles(x86)}\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe",
        "${env:ProgramFiles}\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe"
    )
    foreach ($exe in $paths) {
        if (Test-Path -LiteralPath $exe) {
            try {
                $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
                return @{ Installed = $true; Path = $exe; Version = $v }
            }
            catch {
                return @{ Installed = $true; Path = $exe; Version = "Unknown" }
            }
        }
    }
    return @{ Installed = $false; Path = $null; Version = $null }
}

function Wait-CreativeCloudApp {
    param([int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log "Waiting up to $TimeoutMinutes minute(s) for Creative Cloud desktop app..."
    $nextLog = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $st = Get-CreativeCloudInstallStatus
        if ($st.Installed) {
            return $st
        }
        if ((Get-Date) -ge $nextLog) {
            $left = [math]::Round(($deadline - (Get-Date)).TotalMinutes, 1)
            Write-Log "Still waiting for Creative Cloud.exe (~$left min left)..."
            $nextLog = (Get-Date).AddMinutes(2)
        }
        Start-Sleep -Seconds 15
    }
    return (Get-CreativeCloudInstallStatus)
}

function Install-ViaWinget {
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Log "winget not found; cannot use -PreferWinget" "ERROR"
        return $false
    }
    Write-Log "Installing via winget (Adobe.CreativeCloud)..."
    $args = @(
        "install", "-e", "--id", "Adobe.CreativeCloud",
        "--silent", "--accept-package-agreements", "--accept-source-agreements"
    )
    $p = Start-Process -FilePath $wingetCmd.Source -ArgumentList $args -Wait -PassThru -NoNewWindow
    Write-Log "winget exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne $null) {
        Write-Log "winget reported failure; continuing to wait for Creative Cloud.exe (may still be installing)." "WARN"
    }
    return $true
}

function Install-ViaAdobeBootstrapper {
    Write-Log "Downloading Creative Cloud bootstrapper from Adobe..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $DownloadPath -UseBasicParsing
    if (-not (Test-Path $DownloadPath)) {
        throw "Download failed: file missing at $DownloadPath"
    }
    $size = (Get-Item $DownloadPath).Length
    Write-Log "Downloaded $DownloadPath ($size bytes)"

    # Parent Set-Up.exe often returns immediately while download/install continues in child processes — do not -Wait.
    Write-Log "Launching Creative Cloud Set-Up (silent); installer may run in the background for several minutes..."
    $null = Start-Process -FilePath $DownloadPath -ArgumentList @("--silent") -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 5
}

Write-Log "=========================================="
Write-Log "Install Adobe Creative Cloud desktop app"
Write-Log "Log: $LogFile"
Write-Log "=========================================="

# Use a single exit path: plain `exit` inside iex closes the whole PowerShell window.
$exitCode = 1001

if (-not (Test-IsAdmin)) {
    Write-Log "Administrator required." "ERROR"
    Write-Host "ERROR: Run PowerShell as Administrator (or use -File from an elevated task)."
}
else {
    $existing = Get-CreativeCloudInstallStatus
    if ($existing.Installed -and -not $Force) {
        Write-Log "Creative Cloud is already installed: $($existing.Path) ($($existing.Version))"
        Write-Host "SUCCESS: Already installed — $($existing.Path)"
        Write-Host "Tip: use -Force to run the installer anyway."
        $exitCode = 0
    }
    else {
        if ($Force -and $existing.Installed) {
            Write-Log "-Force: proceeding even though Creative Cloud.exe exists at $($existing.Path)" "WARN"
        }
        try {
            if ($PreferWinget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                $null = Install-ViaWinget
            }
            elseif ($PreferWinget) {
                Write-Log "PreferWinget but winget not found; using Adobe bootstrapper." "WARN"
                Install-ViaAdobeBootstrapper
            }
            else {
                Install-ViaAdobeBootstrapper
            }

            $final = Wait-CreativeCloudApp -TimeoutMinutes $MaxWaitMinutes
            if ($final.Installed) {
                Write-Log "Verified: $($final.Path) version $($final.Version)" "SUCCESS"
                Write-Host "SUCCESS: Creative Cloud installed — $($final.Path)"
                $exitCode = 0
            }
            else {
                Write-Log "Creative Cloud.exe not detected after wait. Set-Up may still be running in the background; check Task Manager and Adobe logs, or reboot and sign in to the app." "ERROR"
                $exitCode = 1001
            }
        }
        catch {
            Write-Log "Error: $($_.Exception.Message)" "ERROR"
            Write-Host "ERROR: $($_.Exception.Message)"
            $exitCode = 1001
        }
        finally {
            if (Test-Path $DownloadPath) {
                Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($PSCommandPath) {
    exit $exitCode
}
Write-Host "[Install_AdobeCreativeCloud] Finished with exit code $exitCode (console left open for iex). Log: $LogFile"
if (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue) {
    $global:LASTEXITCODE = $exitCode
}
