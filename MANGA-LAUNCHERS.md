# Launcher guide

The portable ZIP contains the native MangaColorAI studio and image helper in `bin/`. Run `Start MangaColorAI.cmd` to open the studio. On first setup, run `Setup MangaColorAI 4B.cmd` or `Setup MangaColorAI 9B.cmd` to install ComfyUI's portable runtime and the selected weights. Setup downloads several gigabytes; model files are not included in the release ZIP.

The other launchers are optional PowerShell wrappers for users who prefer a direct single-image or folder job:

| Model | Single image | Folder |
|---|---|---|
| Klein 4B FP8 | `Colorize Manga 4B FP8.cmd` | `Colorize Folder 4B FP8.cmd` |
| Klein 4B BF16 | `Colorize Manga 4B BF16.cmd` | `Colorize Folder 4B BF16.cmd` |
| Klein 9B FP8 | `Colorize Manga 9B FP8.cmd` | `Colorize Folder 9B FP8.cmd` |

Double-click to select an image or folder, or drag a path onto a launcher. Folder processing is sequential; add `-Recurse` to include subfolders. The defaults are four steps and seed 42. The working image may be scaled for inference; PNG export is resized to the original width and height. This restores dimensions, not fine details discarded by downscaling.

The studio can manage palettes, character/outfit profiles, references, region masks, CPU coverage analysis, color repair previews, source-ink restoration, text processing, and optional vision review. Automatic color suggestions are fallible; inspect and approve repairs. The original image is not overwritten.

Edit `manga-color-style.txt` to change the default prompt palette. Chapter JSON palette and reference examples are documented in the root README. Run `Stop Local AI.cmd` to stop only the backend process MangaColorAI recorded as its own.
