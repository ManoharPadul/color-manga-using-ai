@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local-manga\Batch.ps1" %*
if errorlevel 1 (pause) else (echo Finished. Results are in the manga-output folder. & pause)
