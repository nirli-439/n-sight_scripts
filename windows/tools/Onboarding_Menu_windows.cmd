@echo off
REM Double-click: opens the Windows onboarding menu (it asks for admin / UAC by itself).
REM Put the N-sight Windows agent installer in Downloads first.
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/nirli-439/n-sight_scripts/main/windows/tools/Onboarding_Menu_windows.ps1')"
