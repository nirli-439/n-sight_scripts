<#
.SYNOPSIS
    Checks the Windows AI Stack installed by Install_AI_Stack.ps1.
.DESCRIPTION
    Reports whether desktop apps, WSL, and CLI prerequisites are present.
    Does not change the device.

    Note: ChatGPT/Claude Desktop are installed via Add-AppxProvisionedPackage, which can show up
    in Get-AppxPackage -AllUsers (what this check reads) before the app is actually registered/
    launchable for a user - full registration happens at that user's next sign-in. A FAIL here
    right after Install_AI_Stack.ps1 ran, with no sign-in since, may just mean "not registered
    yet" rather than a real install failure - retry after a fresh logon before treating it as broken.
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
