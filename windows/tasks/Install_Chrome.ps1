<#
.SYNOPSIS
    Installs Chrome, makes it the default browser, pins it for new profiles, and blocks Edge updates.
.DESCRIPTION
    Silent N-Sight task for Windows 10/11. A public desktop shortcut is created.
    Taskbar layouts only apply to new profiles; SYSTEM cannot reliably pin existing users.
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OK = 0; $CRIT = 1002
$Msi64 = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
$Msi32 = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise.msi'
function Get-ChromePath {
    @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
function Set-ChromeDesktopAndTaskbar([string]$Chrome) {
    $link = Join-Path $env:PUBLIC 'Desktop\Google Chrome.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $Chrome
    $shortcut.IconLocation = "$Chrome,0"
    $shortcut.Save()
    if (-not (Test-Path $link)) { throw 'Chrome desktop shortcut verification failed.' }
    $layout = Join-Path $env:ProgramData 'ChromeTaskbarLayout.xml'
    @'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" Version="1" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout">
  <CustomTaskbarLayoutCollection PinListPlacement="Append"><defaultlayout:TaskbarLayout><taskbar:TaskbarPinList><taskbar:DesktopApp DesktopApplicationLinkPath="%PUBLIC%\Desktop\Google Chrome.lnk" /></taskbar:TaskbarPinList></defaultlayout:TaskbarLayout></CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@ | Set-Content -Path $layout -Encoding UTF8
    $explorer = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
    New-Item $explorer -Force | Out-Null
    Set-ItemProperty $explorer -Name StartLayoutFile -Type String -Value $layout
    if ((Get-ItemPropertyValue $explorer -Name StartLayoutFile) -ne $layout) { throw 'Chrome taskbar layout verification failed.' }
}
function Set-ChromeDefault([string]$Chrome) {
    $xml = Join-Path $env:ProgramData 'ChromeDefaultAssociations.xml'
    @'
<?xml version="1.0" encoding="UTF-8"?><DefaultAssociations><Association Identifier=".htm" ProgId="ChromeHTML" ApplicationName="Google Chrome"/><Association Identifier=".html" ProgId="ChromeHTML" ApplicationName="Google Chrome"/><Association Identifier="http" ProgId="ChromeHTML" ApplicationName="Google Chrome"/><Association Identifier="https" ProgId="ChromeHTML" ApplicationName="Google Chrome"/></DefaultAssociations>
'@ | Set-Content -Path $xml -Encoding UTF8
    & dism.exe /Online "/Import-DefaultAppAssociations:$xml" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Default association import failed ($LASTEXITCODE)." }
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    New-Item $policy -Force | Out-Null
    Set-ItemProperty $policy -Name DefaultAssociationsConfiguration -Type String -Value $xml
    if ((Get-ItemPropertyValue $policy -Name DefaultAssociationsConfiguration) -ne $xml) { throw 'Default browser policy verification failed.' }
}
function Disable-Edge {
    $edgeUpdate = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    New-Item $edgeUpdate -Force | Out-Null
    Set-ItemProperty $edgeUpdate -Name InstallDefault -Type DWord -Value 0
    Set-ItemProperty $edgeUpdate -Name UpdateDefault -Type DWord -Value 0
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    New-Item $edge -Force | Out-Null
    Set-ItemProperty $edge -Name HideFirstRunExperience -Type DWord -Value 1
    if ((Get-ItemPropertyValue $edgeUpdate -Name InstallDefault) -ne 0) { throw 'Edge policy verification failed.' }
}
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
    $chrome = Get-ChromePath
    if (-not $chrome) {
        $msi = Join-Path $env:TEMP 'GoogleChromeEnterprise.msi'
        $url = if ([Environment]::Is64BitOperatingSystem) { $Msi64 } else { $Msi32 }
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $msi -TimeoutSec 300
        $install = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart ALLUSERS=1" -Wait -PassThru
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        if ($install.ExitCode -notin 0,3010,1641) { throw "Chrome install failed ($($install.ExitCode))." }
        $chrome = Get-ChromePath
    }
    if (-not $chrome) { throw 'Chrome executable not found after installation.' }
    Set-ChromeDesktopAndTaskbar $chrome
    Set-ChromeDefault $chrome
    Disable-Edge
    Write-Host "OK: Chrome $((Get-Item $chrome).VersionInfo.ProductVersion) installed/default; Edge updates blocked."
    exit $OK
} catch { Write-Host "CRITICAL: $($_.Exception.Message)"; exit $CRIT }
