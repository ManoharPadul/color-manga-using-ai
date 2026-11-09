@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local-manga\Compare-Panels.ps1" %*
pause
