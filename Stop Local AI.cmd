@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local-manga\Stop.ps1"
if errorlevel 1 pause
