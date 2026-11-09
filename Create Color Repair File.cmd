@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local-manga\Create-ColorRegions.ps1" %*
if errorlevel 1 pause
