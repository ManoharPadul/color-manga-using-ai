@echo off
call "%~dp0Colorize Manga.cmd" -ModelSize 9B -Precision FP8 -Quality Fast -Consistency 0 -Megapixels 1.5 -PromptStyle Minimal -Strength 1 -Seed 42 -StyleFile "%~dp0manga-tested-style.txt" %*
