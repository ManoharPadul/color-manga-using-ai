@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local-manga\Review-ExistingFolder.ps1" -Repair %*
pause
