@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\manga-upscale\Studio.ps1"
if errorlevel 1 (
  echo.
  echo Manga Upscale AI stopped with an error.
  pause
)
