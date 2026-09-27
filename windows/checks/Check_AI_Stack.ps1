<#
.SYNOPSIS
    Checks whether the Windows AI Stack (Git, curl, Node, Python, WSL, ChatGPT Desktop, Claude
    Desktop, Claude Code, Codex, Antigravity) is actually installed.
.DESCRIPTION
    Reports whether desktop apps, WSL, and CLI prerequisites are present.
    Does not change the device.

    NOTE (added when Install_AI_Stack.ps1 became download-only, v4.0): this check is no longer
    paired with Install_AI_Stack.ps1 in check-task-pairs.json. That task now only downloads
    installer files to C:\Download - it does not install anything - so a FAIL here will no
    longer be auto-remediated by re-running it. Nothing currently installs this stack
    automatically; re-pair a task here only once one exists that installs from the C:\Download
    cache (or elsewhere).

    Note: ChatGPT/Claude Desktop, when installed via Add-AppxProvisionedPackage, can show up in
    Get-AppxPackage -AllUsers (what this check reads) before the app is actually registered/
    launchable for a user - full registration happens at that user's next sign-in. A FAIL here
    right after an install, with no sign-in since, may just mean "not registered yet" rather than
    a real install failure - retry after a fresh logon before treating it as broken.
#>
$ErrorActionPreference = 'SilentlyContinue'
$OK = 0; $CRIT = 1002
$Root = Join-Path $env:ProgramFiles 'AIStack'
$Npm = Join-Path $Root 'npm'
$Bin = Join-Path $Root 'bin'
$items = [ordered]@{
    Git = (Test-Path (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
    Curl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
    Node = (Test-Path (Join-Path $env:ProgramFiles 'nodejs\node.exe'))
    Python = [bool](Get-Command py.exe -ErrorAction SilentlyContinue)
    WSL = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
    ChatGPT = [bool](Get-AppxPackage -AllUsers | Where-Object { $_.Name -like 'OpenAI.ChatGPT*' } | Select-Object -First 1)
    ClaudeDesktop = [bool](Get-AppxPackage -AllUsers | Where-Object { $_.Name -like 'Anthropic.Claude*' } | Select-Object -First 1)
    ClaudeCode = (Test-Path (Join-Path $Npm 'claude.cmd'))
    Codex = (Test-Path (Join-Path $Npm 'codex.cmd'))
    Antigravity = (Test-Path (Join-Path $Bin 'agy.exe'))
}
$missing = @($items.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
if ($missing.Count) { Write-Host "CRITICAL: AI Stack missing: $($missing -join ', ')"; exit $CRIT }
Write-Host 'OK: AI Stack ready (Git, curl, Node, Python, WSL, ChatGPT, Claude Desktop, Claude Code, Codex, Antigravity).'
exit $OK
