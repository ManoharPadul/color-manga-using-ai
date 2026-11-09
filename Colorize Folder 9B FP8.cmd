@echo off
call "%~dp0Colorize Folder.cmd" -ModelSize 9B -Precision FP8 -Quality Fast -Consistency 0 -Megapixels 0.7 -PromptStyle Preserve %*
