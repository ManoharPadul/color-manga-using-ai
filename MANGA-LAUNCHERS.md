# Launcher guide

The portable ZIP contains the native MangaColorAI studio and image helper in `bin/`. Run `Start MangaColorAI.cmd` to open the studio. The only colorizer command files are `Start MangaColorAI.cmd`, `Stop Local AI.cmd`, and `Build MangaColorAI.cmd`; model-specific and one-off launcher files have been removed. Model files are not included in the release ZIP.

Install the recommended 4B model and runtime from the repository folder with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\local-manga\Setup.ps1 -ModelSize 4B
```

Use `-ModelSize 9B` for the 9B setup. Setup downloads several gigabytes and verifies model hashes.

Image enlargement is handled by a separate utility: run `scripts/manga-upscale/Setup.ps1` once, then use `Start Manga Upscale AI.cmd`. It only upscales single images or folders with Real-ESRGAN x4plus-anime and FFmpeg; it does not invoke the MangaColorAI colorization backend. See [MANGA-UPSCALE.md](MANGA-UPSCALE.md).

The studio is the supported interface for choosing one image or a folder. Advanced users can invoke the PowerShell workflows in `scripts/local-manga` directly. Folder processing is sequential; add `-Recurse` to include subfolders. The defaults are four steps and seed 42. The working image may be scaled for inference; PNG export is resized to the original width and height. This restores dimensions, not fine details discarded by downscaling.

The studio can manage palettes, character/outfit profiles, references, region masks, CPU coverage analysis, color repair previews, source-ink restoration, text processing, and optional vision review. Automatic color suggestions are fallible; inspect and approve repairs. The original image is not overwritten.

Edit `manga-color-style.txt` to change the default prompt palette. Chapter JSON palette and reference examples are documented in the root README. Run `Stop Local AI.cmd` to stop only the backend process MangaColorAI recorded as its own.
