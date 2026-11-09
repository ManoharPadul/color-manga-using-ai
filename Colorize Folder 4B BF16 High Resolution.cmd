@echo off
call "%~dp0Colorize Folder.cmd" -ModelSize 4B -Precision BF16 -Quality Fast -Consistency 0 -Megapixels 1.5 -PromptStyle Preserve %*
