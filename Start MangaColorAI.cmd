@echo off
pushd "%~dp0"
if not exist "%~dp0bin\MangaColorAI.exe" (
  echo MangaColorAI.exe was not found in bin. Extract the Windows release ZIP or run Build MangaColorAI.cmd.
  pause
  popd
  exit /b 1
)
start "MangaColorAI" /D "%~dp0" "%~dp0bin\MangaColorAI.exe"
popd
