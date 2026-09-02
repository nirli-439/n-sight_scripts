<#
.SYNOPSIS
    Removes consumer Windows apps from a business laptop.
.DESCRIPTION
    Removes Xbox apps, the built-in New Outlook app, and selected consumer apps
    for existing users and future profiles. Keeps Microsoft Store and core apps.
.EXECUTION
    iex (irm "https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tasks/Remove_Windows_Consumer_Bloat.ps1")
.NOTES
    Exit: 0=OK, 1001=WARNING, 1002=CRITICAL
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$EXIT_SUCCESS = 0
$EXIT_WARNING = 1001
$EXIT_CRITICAL = 1002
$Targets = @(
    "Microsoft.GamingApp",
    "Microsoft.XboxApp",
    "Microsoft.XboxGameOverlay",
    "Microsoft.XboxGamingOverlay",
    "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxSpeechToTextOverlay",
    "Microsoft.OutlookForWindows",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.GetHelp",
    "Microsoft.Getstarted",
    "Microsoft.People",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.WindowsMaps",
    "Microsoft.YourPhone",
    "Microsoft.ZuneMusic",
    "Microsoft.ZuneVideo",
    "Microsoft.BingNews",
    "Microsoft.BingWeather",
    "Microsoft.MicrosoftOfficeHub"
)

try {
    $removed = @()
    $failed = @()

    foreach ($target in $Targets) {
        Get-AppxPackage -AllUsers -Name $target -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
                $removed += $_.Name
            }
            catch {
                $failed += $_.Name
            }
        }

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $target } |
            ForEach-Object {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                    $removed += $_.DisplayName
                }
                catch {
                    $failed += $_.DisplayName
                }
            }
    }

    $remaining = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $Targets } |
        Select-Object -ExpandProperty Name -Unique

    if ($remaining) {
        Write-Host "WARNING: Removed $($removed.Count) packages; still present: $($remaining -join ', ')"
        exit $EXIT_WARNING
    }
    if ($failed) {
        Write-Host "WARNING: Removed $($removed.Count) packages; errors: $($failed -join ', ')"
        exit $EXIT_WARNING
    }

    Write-Host "OK: Business laptop cleanup complete. Removed $($removed.Count) packages."
    exit $EXIT_SUCCESS
}
catch {
    Write-Host "CRITICAL: Business laptop cleanup failed - $($_.Exception.Message)"
    exit $EXIT_CRITICAL
}
