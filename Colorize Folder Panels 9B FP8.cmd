@echo off
call "%~dp0Colorize Folder.cmd" -PanelMode Off -ModelSize 9B -Precision FP8 -Megapixels 1.5 -PromptStyle Minimal -StyleFile "%~dp0manga-tested-style.txt" %*
