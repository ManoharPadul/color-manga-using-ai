@echo off
call "%~dp0Colorize Folder.cmd" -PanelMode Off -ModelSize 4B -Precision BF16 -Megapixels 1.5 -PromptStyle Minimal -StyleFile "%~dp0manga-tested-style.txt" %*
