# Onboarding_Menu_windows.ps1 - interactive Windows technician menu (counterpart of macos/tools/Onboarding_Menu_mac.sh).
#
# Run (any PowerShell window; it asks for admin by itself):
#   irm https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tools/Onboarding_Menu_windows.ps1 | iex
# Or double-click windows/tools/Onboarding_Menu_windows.cmd
#
# Before running: download the N-sight Windows agent from the dashboard into Downloads
# (links expire, so nothing is baked in). Type item numbers to toggle, Enter to run.
# Every task is downloaded fresh from the repo (cache-busted), checked for syntax, then run
# one at a time with a timeout - a hung installer is killed and the menu moves on.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$BaseUrl = 'https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main'
if ($env:NSIGHT_SCRIPTS_REPO_BASE) { $BaseUrl = $env:NSIGHT_SCRIPTS_REPO_BASE.Trim().TrimEnd('/') }
$SelfUrl = "$BaseUrl/windows/tools/Onboarding_Menu_windows.ps1"

# --- Elevate (re-launch itself as admin) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Asking for Administrator rights (UAC)...'
    if ($PSCommandPath) {
        $relaunch = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } else {
        $relaunch = "-NoProfile -ExecutionPolicy Bypass -Command `"iex (irm '$SelfUrl" + "?v=$([guid]::NewGuid())')`""
    }
    try { Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $relaunch -ErrorAction Stop }
    catch { Write-Host 'Cancelled - Administrator rights are required.' -ForegroundColor Red }
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { $Host.UI.RawUI.WindowTitle = 'Windows onboarding' } catch {}

$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$LogFile = Join-Path $LogDir "Onboarding_Menu_windows_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Work = Join-Path $env:TEMP ('onboarding_' + [IO.Path]::GetRandomFileName())
New-Item -Path $Work -ItemType Directory -Force | Out-Null

function New-Item2 { param($Name, $Script, $Timeout, $On = $true, $Launch = $null)
    [pscustomobject]@{ Name = $Name; Script = $Script; Timeout = $Timeout; Selected = $On; Result = $(if ($On) { 'Ready' } else { 'Optional' }); Launch = $Launch; Ok = $false }
}

# Order matters: agent first (machine shows up in N-sight), removals before installs, tweaks/pins last.
$Items = @(
    (New-Item2 'N-sight agent'             'tasks/Install_NSight_Agent.ps1'              900)
    (New-Item2 'Remove McAfee'             'tasks/Remove_McAfee.ps1'                     600)
    (New-Item2 'Remove consumer bloat'     'tasks/Remove_Windows_Consumer_Bloat.ps1'     600)
    (New-Item2 'Remove OneDrive'           'tasks/Remove_OneDrive.ps1'                   180)
    (New-Item2 'Bitdefender'               'tasks/Install_BitdefenderAgent.ps1'          1200)
    (New-Item2 'Google Chrome'             'tasks/Install_Chrome.ps1'                    300  $true 'chrome')
    (New-Item2 'Chrome default browser'    'tasks/Enforce_Chrome_Default_Browser.ps1'    90)
    (New-Item2 'Google Drive'              'tasks/Install_GoogleDrive.ps1'               240)
    (New-Item2 'Slack'                     'tasks/Install_Slack.ps1'                     240  $true 'Slack')
    (New-Item2 'Twingate'                  'tasks/Install_Twingate.ps1'                  300)
    (New-Item2 'GCPW (Google sign-in)'     'tasks/Install_GCPW.ps1'                      240)
    (New-Item2 'Claude Desktop'            'tasks/Install_ClaudeDesktop.ps1'             600  $true 'Claude')
    (New-Item2 'Figma Desktop'             'tasks/Install_Figma.ps1'                     900  $true 'Figma')
    (New-Item2 'Claude Code + AI CLIs'     'tasks/Install_AI_Code_CLIs.ps1'              1200 $false)
    (New-Item2 'Speed & focus tweaks'      'tasks/Optimize_Windows_AI_Workstation.ps1'   900)
    (New-Item2 'Hibernate & lid close'     'tasks/Remediate_Hibernate_LidClose.ps1'      60)
    (New-Item2 'Screen lock timeout'       'tasks/Remediate_ScreenLock_Timeout.ps1'      60)
    (New-Item2 'Pin desktop apps'          'tasks/Pin_Onboarding_Apps.ps1'               120)
    (New-Item2 'OpenSSH (slow)'            'tasks/Install_OpenSSH.ps1'                   900  $false)
)

function Write-Log { param([string]$Message)
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ErrorAction SilentlyContinue
}

function Show-Menu {
    Clear-Host
    Write-Host "Windows onboarding - $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $it = $Items[$i]
        $mark = if ($it.Selected) { 'x' } else { ' ' }
        $color = switch -Wildcard ($it.Result) { 'Done*' { 'Green' } 'Warning*' { 'Yellow' } 'Failed*' { 'Red' } 'Timed*' { 'Red' } default { 'Gray' } }
        Write-Host ('[{0}] {1,2}. {2,-26}' -f $mark, ($i + 1), $it.Name) -NoNewline
        Write-Host $it.Result -ForegroundColor $color
    }
    Write-Host ''
    Write-Host 'Type numbers to toggle (e.g. 13 18 or 2-4), a = all, n = none, Enter = run selected, q = quit'
}

function Get-RemoteScript { param([string]$RelPath, [string]$Dest)
    $url = "$BaseUrl/windows/$RelPath" + "?v=$([guid]::NewGuid())"   # defeat raw.githubusercontent CDN cache
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($Dest, [ref]$null, [ref]$errs)
            if ($errs -and $errs.Count -gt 0) { throw "syntax error in $RelPath : $($errs[0].Message)" }
            return $true
        } catch {
            Write-Log "Download $RelPath attempt $try failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (3 * $try)
        }
    }
    return $false
}

function Invoke-Item2 { param($It, [string]$File)
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$File`"") -NoNewWindow -PassThru
    $null = $p.Handle   # keeps ExitCode readable after exit
    if (-not $p.WaitForExit($It.Timeout * 1000)) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null
        return 'timeout'
    }
    return $p.ExitCode
}

function Start-AsUser { param([string]$Target)
    # explorer.exe starts things un-elevated, as the signed-in user (never Chrome/Claude as admin).
    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$Target`"" -ErrorAction SilentlyContinue
}

function Open-App { param([string]$Key)
    if ($Key -eq 'chrome') {
        foreach ($c in "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") {
            if (Test-Path $c) { Start-AsUser $c; return $true }
        }
        return $false
    }
    $app = Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$Key*" } | Select-Object -First 1
    if ($app) { Start-AsUser "shell:AppsFolder\$($app.AppID)"; return $true }
    return $false
}

function Invoke-Selected {
    $sel = @($Items | Where-Object Selected)
    if ($sel.Count -eq 0) { return }

    # Stage everything first, so a download failure is known before anything changes.
    Write-Host "`nDownloading $($sel.Count) task(s)..." -ForegroundColor Cyan
    foreach ($it in $sel) {
        $it | Add-Member -NotePropertyName File -NotePropertyValue (Join-Path $Work ([IO.Path]::GetFileName($it.Script))) -Force
        if (-not (Get-RemoteScript $it.Script $it.File)) { $it.Result = 'Failed (download)'; $it.Ok = $false }
        else { $it.Result = 'Queued' }
    }

    $n = 0
    foreach ($it in $sel) {
        $n++
        if ($it.Result -ne 'Queued') { continue }
        Write-Host "`n===== [$n/$($sel.Count)] $($it.Name) =====" -ForegroundColor Cyan
        $it.Result = 'Running'
        $code = Invoke-Item2 $it $it.File
        if ($code -is [string]) { $it.Result = "Timed out after $($it.Timeout)s"; $it.Ok = $false }
        elseif ($code -eq 0)    { $it.Result = 'Done'; $it.Ok = $true }
        elseif ($code -eq 3010) { $it.Result = 'Done - reboot needed'; $it.Ok = $true }
        elseif ($code -eq 1001) { $it.Result = 'Warning - check output'; $it.Ok = $true }
        else                    { $it.Result = "Failed (exit $code)"; $it.Ok = $false }
        Write-Host "$($it.Name): $($it.Result)"
        Write-Log "$($it.Name): $($it.Result)"
    }

    # Open the work apps once, after all installs.
    foreach ($it in $sel) {
        if ($it.Ok -and $it.Launch) { if (Open-App $it.Launch) { $it.Result += ' - opened' } }
    }

    $bad = @($sel | Where-Object { -not $_.Ok })
    $summary = ($sel | ForEach-Object { "$($_.Name): $($_.Result)" }) -join "`n"
    $title = if ($bad.Count) { 'Setup finished with warnings or failures' } else { 'Setup finished' }
    Write-Log "== $title"
    try { $null = (New-Object -ComObject WScript.Shell).Popup("$summary`n`nLog: $LogFile`nTask logs: $LogDir", 120, $title, $(if ($bad.Count) { 48 } else { 64 })) } catch {}
}

# --- Main loop ---
Write-Log "Onboarding menu started on $env:COMPUTERNAME from $BaseUrl"
try {
    while ($true) {
        Show-Menu
        $in = (Read-Host '>').Trim().ToLowerInvariant()
        if ($in -eq 'q') { break }
        if ($in -eq '' -or $in -eq 'r') {
            Invoke-Selected
            Write-Host "`nDone. Log: $LogFile  - press Enter to return to the menu" -ForegroundColor Cyan
            [void](Read-Host)
            continue
        }
        if ($in -eq 'a') { $Items | ForEach-Object { $_.Selected = $true }; continue }
        if ($in -eq 'n') { $Items | ForEach-Object { $_.Selected = $false }; continue }
        foreach ($tok in ($in -split '[\s,]+')) {
            if ($tok -match '^(\d+)-(\d+)$') { $range = [int]$Matches[1]..[int]$Matches[2] }
            elseif ($tok -match '^\d+$') { $range = @([int]$tok) }
            else { continue }
            foreach ($k in $range) { if ($k -ge 1 -and $k -le $Items.Count) { $Items[$k - 1].Selected = -not $Items[$k - 1].Selected } }
        }
    }
} finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
