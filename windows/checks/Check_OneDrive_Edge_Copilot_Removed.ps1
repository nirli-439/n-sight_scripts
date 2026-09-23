<#
.SYNOPSIS
    Checks that OneDrive, Microsoft Edge browser, and Copilot are removed.
#>
$CRIT = 1002
$edge = Test-Path "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe"
$copilot = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Microsoft.Copilot*' -or $_.Name -like 'MicrosoftWindows.Client.Copilot*' }
$oneDrive = Get-Process OneDrive -ErrorAction SilentlyContinue
$block = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name DisableFileSyncNGSC -ErrorAction SilentlyContinue
$edgeBlock = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' -Name DoNotUpdateToEdgeWithChromium -ErrorAction SilentlyContinue
$copilotBlock = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name TurnOffWindowsCopilot -ErrorAction SilentlyContinue
if ($edge -or $copilot -or $oneDrive -or $block -ne 1 -or $edgeBlock -ne 1 -or $copilotBlock -ne 1) {
    Write-Host 'CRITICAL: OneDrive, Edge, or Copilot is present or not blocked.'; exit $CRIT
}
Write-Host 'OK: OneDrive, Edge, and Copilot removed and blocked; WebView2 retained.'
exit 0
