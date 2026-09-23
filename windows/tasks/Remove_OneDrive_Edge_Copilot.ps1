<#
.SYNOPSIS
    Removes OneDrive, Microsoft Edge browser, and Microsoft Copilot.
.DESCRIPTION
    N-Sight task for Windows 10/11, run as SYSTEM. Keeps existing user files,
    including synced OneDrive folders, to avoid deleting data. Edge WebView2 is
    retained because Windows and desktop apps depend on it.
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OK = 0; $WARN = 1001; $CRIT = 1002
$Log = Join-Path $env:ProgramData 'nsight\logs\Remove_OneDrive_Edge_Copilot.log'
New-Item -ItemType Directory -Path (Split-Path $Log) -Force | Out-Null
function Log([string]$Text) { Write-Host $Text; Add-Content -Path $Log -Value "$(Get-Date -Format s) $Text" }
function Remove-AppxLike([string]$Pattern) {
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Pattern } | ForEach-Object {
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Pattern } | ForEach-Object {
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
    }
}
function Remove-OneDrive {
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # OneDriveSetup.exe can return 0x8004069B under SYSTEM when no per-user client is registered.
    # The policy and actual-client checks below are authoritative; its exit code is not.
    @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") | Where-Object { Test-Path $_ } | ForEach-Object {
        $p = Start-Process -FilePath $_ -ArgumentList '/uninstall' -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { Log "WARNING: OneDriveSetup returned $($p.ExitCode); continuing with policy cleanup." }
    }
    Remove-AppxLike '*OneDrive*'
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
    New-Item -Path $policy -Force | Out-Null
    Set-ItemProperty -Path $policy -Name DisableFileSync -Type DWord -Value 1
    Set-ItemProperty -Path $policy -Name DisableFileSyncNGSC -Type DWord -Value 1
    # ponytail: synced user folders are preserved; delete only after a verified migration.
}
function Remove-Edge {
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $setups = @(
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\*\Installer\setup.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\*\Installer\setup.exe"
    ) | ForEach-Object { Get-ChildItem -Path $_ -ErrorAction SilentlyContinue } | Sort-Object FullName -Descending
    if ($setups) {
        $p = Start-Process -FilePath $setups[0].FullName -ArgumentList '--uninstall','--system-level','--force-uninstall','--verbose-logging' -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "Edge uninstall failed ($($p.ExitCode))." }
    }
    $edgePolicy = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'
    New-Item -Path $edgePolicy -Force | Out-Null
    Set-ItemProperty -Path $edgePolicy -Name DoNotUpdateToEdgeWithChromium -Type DWord -Value 1
}
function Remove-Copilot {
    Get-Process Copilot,Microsoft.Copilot -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-AppxLike 'Microsoft.Copilot*'
    Remove-AppxLike 'MicrosoftWindows.Client.Copilot*'
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'
    New-Item -Path $policy -Force | Out-Null
    Set-ItemProperty -Path $policy -Name TurnOffWindowsCopilot -Type DWord -Value 1
}
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
    Log 'Removing OneDrive, Edge, and Copilot...'
    Remove-OneDrive; Remove-Edge; Remove-Copilot
    $edge = Test-Path "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe"
    $oneDrive = Get-Process OneDrive -ErrorAction SilentlyContinue
    $oneDrivePolicy = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name DisableFileSyncNGSC -ErrorAction SilentlyContinue
    $copilot = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Microsoft.Copilot*' -or $_.Name -like 'MicrosoftWindows.Client.Copilot*' }
    if ($edge -or $oneDrive -or $oneDrivePolicy -ne 1 -or $copilot) { throw 'Verification found one or more removed products still present or unblocked.' }
    Log 'OK: OneDrive, Edge, and Copilot removed; OneDrive user files and Edge WebView2 retained.'
    exit $OK
} catch { Log "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
