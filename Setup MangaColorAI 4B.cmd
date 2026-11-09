@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local-manga\Setup.ps1" -ModelSize 4B
if errorlevel 1 (echo Setup failed. See the error above. & pause)
