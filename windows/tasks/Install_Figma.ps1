<#
.SYNOPSIS
    Install Figma Desktop for all users (machine-wide MSI).
.DESCRIPTION
    Figma publishes only versioned MSIs (desktop.figma.com/win/FigmaSetup.msi is 403), so the
    newest version is read from the winget catalog (microsoft/winget-pkgs, Figma.Figma, scope
    machine); if GitHub is unreachable or rate-limited, a pinned known-good version is used.
    msiexec /qn, then verified via the uninstall registry. Idempotent: exits OK if installed.
    Exit 0 = installed/already installed, 1002 = failed.
.EXECUTION
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install_Figma.ps1
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Install_Figma.ps1")
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$PinnedVersion = '126.12.7'   # verified 2026-11-25 (HTTP 200, 167 MB)
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$LogFile = Join-Path $LogDir "Install_Figma_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-Log([string]$m) { $l = "[$(Get-Date -Format 'HH:mm:ss')] $m"; Write-Host $l; Add-Content -Path $LogFile -Value $l -ErrorAction SilentlyContinue }

function Get-FigmaInstall {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Figma*' } | Select-Object -First 1
}

$existing = Get-FigmaInstall
if ($existing) { Write-Host "OK: Figma already installed ($($existing.DisplayVersion))"; exit 0 }

# Newest version from the winget catalog (folder names under manifests/f/Figma/Figma).
$version = $PinnedVersion
try {
    $dirs = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/f/Figma/Figma' -TimeoutSec 30 -Headers @{ 'User-Agent' = 'helfy-onboarding' }
    $latest = $dirs | Where-Object { $_.type -eq 'dir' -and $_.name -match '^\d+(\.\d+)+$' } |
        Sort-Object { [version]$_.name } | Select-Object -Last 1
    if ($latest) { $version = $latest.name }
} catch { Write-Log "winget catalog not reachable ($($_.Exception.Message)) - using pinned $PinnedVersion" }

$msi = Join-Path $env:TEMP "Figma-$version.msi"
$ok = $false
foreach ($v in @($version, $PinnedVersion) | Select-Object -Unique) {
    $url = "https://desktop.figma.com/win/build/Figma-$v.msi"
    for ($try = 1; $try -le 3 -and -not $ok; $try++) {
        try {
            Write-Log "Downloading $url (attempt $try)"
            Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 900
            if ((Get-Item $msi).Length -gt 50MB) { $ok = $true; $version = $v } else { throw 'file too small' }
        } catch { Write-Log "  failed: $($_.Exception.Message)"; Start-Sleep -Seconds (5 * $try) }
    }
    if ($ok) { break }
}
if (-not $ok) { Write-Host 'CRITICAL: Figma MSI download failed'; exit 1002 }

Write-Log "Installing Figma $version"
$p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$LogDir\Figma_msi.log`"" -PassThru -Wait
Remove-Item $msi -Force -ErrorAction SilentlyContinue
if ($p.ExitCode -notin 0, 3010) { Write-Host "CRITICAL: msiexec exit $($p.ExitCode) (log $LogDir\Figma_msi.log)"; exit 1002 }

$installed = Get-FigmaInstall
if ($installed) { Write-Host "OK: Figma $($installed.DisplayVersion) installed for all users"; exit 0 }
Write-Host 'CRITICAL: msiexec succeeded but Figma is not registered'
exit 1002
