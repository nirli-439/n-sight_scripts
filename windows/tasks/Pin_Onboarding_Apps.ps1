<#
.SYNOPSIS
    Public desktop shortcuts and one taskbar pin list for onboarding desktop apps.

.DESCRIPTION
    Creates a verified shortcut on the public desktop for each installed app:
    Chrome, Slack, Google Drive, Twingate, Claude, ChatGPT, and a Gemini web-app
    shortcut (chrome.exe --app=, chromeless window - Gemini has no native Windows
    desktop app, so this is the closest equivalent to the others). Writes one
    StartLayoutFile so those shortcuts pin for new profiles. Missing apps are
    skipped. No scheduled tasks.

.EXECUTION
    Windows (repo): iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Pin_Onboarding_Apps.ps1")

.NOTES
    Author: IT Admin
    Version: 1.1
    Changelog:
    - 1.1: Added a Gemini web-app shortcut (chrome.exe --app=https://gemini.google.com/app,
      a chromeless "app mode" window - long-documented Chromium behavior, not a real
      installed PWA/extension). Requires Chrome already installed; skipped otherwise.
    Exit 0 = shortcuts and layout written
    Exit 1001 = no onboarding desktop apps installed
    Exit 1002 = shortcut or layout write failed
#>
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OK = 0
$WARN = 1001
$CRIT = 1002
$LayoutPath = Join-Path $env:ProgramData 'OnboardingTaskbarLayout.xml'

function New-PublicLnk {
    param([string]$Name, [string]$Target, [string]$Arguments, [string]$Icon)
    $link = Join-Path $env:PUBLIC "Desktop\$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    if ($Icon) { $shortcut.IconLocation = $Icon }
    $shortcut.Description = $Name
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $link)) { throw "Desktop shortcut verification failed: $Name" }
    return $link
}

function Get-FirstPath {
    param([string[]]$Candidates)
    foreach ($p in $Candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-UserExe {
    param([string[]]$Relative)
    $roots = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
    foreach ($root in $roots) {
        foreach ($rel in $Relative) {
            $p = Join-Path $root.FullName $rel
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

function Get-AppUserModelId {
    param([string]$NameLike)
    $pkg = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $NameLike } |
        Select-Object -First 1
    if (-not $pkg) {
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $NameLike -or $_.PackageName -like $NameLike } |
            Select-Object -First 1
        if (-not $prov) { return $null }
        $pkg = $prov
    }
    $id = 'App'
    $root = $pkg.InstallLocation
    if ($root) {
        $manifest = Join-Path $root 'AppxManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            try {
                [xml]$xml = Get-Content -LiteralPath $manifest -Raw
                $app = @($xml.Package.Applications.Application)[0]
                if ($app.Id) { $id = [string]$app.Id }
            } catch { }
        }
    }
    $family = $pkg.PackageFamilyName
    if (-not $family -and $pkg.PackageName -match '^(?<n>.+?)_[\d.]+_[^_]+__(?<p>[A-Za-z0-9]+)$') {
        $family = "$($Matches.n)_$($Matches.p)"
    }
    if (-not $family) { return $null }
    return "$family!$id"
}

function Get-OnboardingShortcuts {
    $links = @()
    $chrome = Get-FirstPath @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    if ($chrome) { $links += New-PublicLnk -Name 'Google Chrome' -Target $chrome -Icon "$chrome,0" } else { $script:Skipped += 'Google Chrome' }

    if ($chrome) {
        $links += New-PublicLnk -Name 'Gemini' -Target $chrome -Arguments '--app=https://gemini.google.com/app --profile-directory=Default' -Icon "$chrome,0"
    } else { $script:Skipped += 'Gemini' }

    $slackExe = Get-FirstPath @(
        "$env:ProgramFiles\Slack\slack.exe",
        "${env:ProgramFiles(x86)}\Slack\slack.exe"
    )
    if (-not $slackExe) { $slackExe = Get-UserExe @('AppData\Local\slack\slack.exe') }
    $slackId = Get-AppUserModelId 'SlackTechnologies.Slack*'
    if (-not $slackId) { $slackId = Get-AppUserModelId '*Slack*' }
    if ($slackId) {
        $icon = if ($slackExe) { "$slackExe,0" } else { "$env:SystemRoot\System32\imageres.dll,15" }
        $links += New-PublicLnk -Name 'Slack' -Target "$env:SystemRoot\explorer.exe" -Arguments "shell:AppsFolder\$slackId" -Icon $icon
    } elseif ($slackExe) {
        $links += New-PublicLnk -Name 'Slack' -Target $slackExe -Icon "$slackExe,0"
    } else { $script:Skipped += 'Slack' }

    $drive = Get-FirstPath @(
        "$env:ProgramFiles\Google\Drive File Stream\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\Drive File Stream\GoogleDriveFS.exe",
        "$env:ProgramFiles\Google\DriveFS\GoogleDriveFS.exe",
        "${env:ProgramFiles(x86)}\Google\DriveFS\GoogleDriveFS.exe"
    )
    if (-not $drive) {
        $drive = Get-UserExe @(
            'AppData\Local\Google\DriveFS\GoogleDriveFS.exe',
            'AppData\Local\Google\Drive File Stream\GoogleDriveFS.exe',
            'AppData\Local\Programs\Google\Drive File Stream\GoogleDriveFS.exe'
        )
    }
    if ($drive) { $links += New-PublicLnk -Name 'Google Drive' -Target $drive -Icon "$drive,0" }
    else { $script:Skipped += 'Google Drive' }

    $twingate = Get-FirstPath @(
        "$env:ProgramFiles\Twingate\Twingate.exe",
        "${env:ProgramFiles(x86)}\Twingate\Twingate.exe"
    )
    if ($twingate) { $links += New-PublicLnk -Name 'Twingate' -Target $twingate -Icon "$twingate,0" }
    else { $script:Skipped += 'Twingate' }

    foreach ($app in @(
        @{ Name = 'Claude'; Like = '*Claude*' },
        @{ Name = 'ChatGPT'; Like = '*ChatGPT*' }
    )) {
        $id = Get-AppUserModelId $app.Like
        if ($id) {
            $links += New-PublicLnk -Name $app.Name -Target "$env:SystemRoot\explorer.exe" -Arguments "shell:AppsFolder\$id" -Icon "$env:SystemRoot\System32\imageres.dll,15"
        } else { $script:Skipped += $app.Name }
    }
    return @($links | Where-Object { $_ })
}

function Set-OnboardingTaskbarLayout {
    param([string[]]$Links)
    $pins = ($Links | ForEach-Object {
        $name = Split-Path -Leaf $_
        "        <taskbar:DesktopApp DesktopApplicationLinkPath=`"%PUBLIC%\Desktop\$name`" />"
    }) -join "`r`n"
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" Version="1" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout">
  <CustomTaskbarLayoutCollection PinListPlacement="Append">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
$pins
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
    Set-Content -Path $LayoutPath -Value $xml -Encoding UTF8
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
    New-Item -Path $policy -Force | Out-Null
    Set-ItemProperty -Path $policy -Name StartLayoutFile -Type String -Value $LayoutPath
    if ((Get-ItemPropertyValue -Path $policy -Name StartLayoutFile) -ne $LayoutPath) {
        throw 'Taskbar layout verification failed.'
    }
}

function Invoke-TaskbarPin {
    param([string]$Lnk)
    $dir = Split-Path -Parent $Lnk
    $leaf = Split-Path -Leaf $Lnk
    $shell = New-Object -ComObject Shell.Application
    $item = $shell.NameSpace($dir).ParseName($leaf)
    if (-not $item) { throw "Shortcut not visible: $Lnk" }
    $verbs = @($item.Verbs())
    $unpin = $verbs | Where-Object { ($_.Name -replace '&','') -match 'Unpin from taskbar' } | Select-Object -First 1
    if ($unpin) {
        Write-Host "OK: $leaf already pinned"
        return
    }
    $pin = $verbs | Where-Object { ($_.Name -replace '&','') -match 'Pin to taskbar|taskbarpin' } | Select-Object -First 1
    if ($pin) { $pin.DoIt() } else { $item.InvokeVerb('taskbarpin') }
    Write-Host "OK: pin requested for $leaf"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'CRITICAL: Run as Administrator.'; exit $CRIT }

try {
    $script:Skipped = @()
    $links = @(Get-OnboardingShortcuts)
    if ($links.Count -eq 0) {
        Write-Host 'WARNING: no onboarding desktop apps installed.'
        exit $WARN
    }
    Set-OnboardingTaskbarLayout -Links $links
    foreach ($link in $links) {
        try { Invoke-TaskbarPin $link } catch { Write-Host "WARNING: pin failed for $link - $($_.Exception.Message)" }
    }
    Write-Host ("OK: {0} desktop shortcuts on Public Desktop." -f $links.Count)
    $links | ForEach-Object { Write-Host "  $_" }
    if ($script:Skipped) { Write-Host ("Not installed, skipped: {0}" -f ($script:Skipped -join ', ')) }
    exit $OK
}
catch {
    Write-Host "CRITICAL: $($_.Exception.Message)"
    exit $CRIT
}
