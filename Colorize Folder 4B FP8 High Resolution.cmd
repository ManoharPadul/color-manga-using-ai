@echo off
call "%~dp0Colorize Folder.cmd" -ModelSize 4B -Precision FP8 -Quality Fast -Consistency 0 -Megapixels 1.5 -PromptStyle Preserve %*
