@echo off
REM Double-click: UAC prompt, then runs onboarding from GitHub (tasks also load from same repo).
REM To use a fork/branch, edit the URL inside the PowerShell -Command string below.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command','iex (irm ''https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Run_Onboarding_Tasks.ps1'')'"
