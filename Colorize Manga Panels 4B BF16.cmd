@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local-manga\Colorize-Panels.ps1" -FullPage -ModelSize 4B -Precision BF16 -Megapixels 1.5 -Seed 42 -StyleFile "%~dp0manga-tested-style.txt" %*
if errorlevel 1 echo Colorization failed. See the error above.
pause
