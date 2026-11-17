# MangaColorAI 0.3.14 for Windows x64

This Windows x64 release packages the native MangaColorAI studio, image preparation utility, optional Koharu text helper, and the separate Manga Upscale AI utility. The colorizer continues to use the 0.3.13 standalone workflow and supported FLUX.2 Klein models; this release does not change color inference or claim to fix generated lettering/text overlap.

## Changes

- Add a separate image/folder upscaler using Real-ESRGAN `realesrgan-x4plus-anime` at ×4, with FFmpeg decoding/encoding. Its setup script downloads the runtime tools on first use; they are not bundled in the ZIP.
- Keep only the colorizer start, stop, and build command files, plus the upscaler start command. Model setup is run directly through the documented PowerShell script.
- Update the launcher guide and README to match the reduced command-file set and explain both utilities.
- Keep original manga inputs unchanged. The upscaler writes results to a selected output location.

## Model/setup notes

The ZIP does not include ComfyUI, FLUX/Qwen weights, or the upscaler runtime tools. Colorization setup downloads the selected supported FLUX.2 Klein model and its shared components; the separate upscaler setup downloads Real-ESRGAN and FFmpeg. Review upstream software and model licenses before use.

## Choose the right model

- **4B FP8:** recommended default; about 12.45 GB of model files, BFL reports about 13 GB VRAM for this model family.
- **4B BF16:** about 16.13 GB of model files; higher memory pressure.
- **9B FP8:** about 18.43 GB of model files; 24 GB GPU memory is tight and higher-resolution jobs may run out of memory. Non-commercial BFL license applies.

For colorization, use the PowerShell setup command in README.md, then run `Start MangaColorAI.cmd`. For image enlargement, run `scripts/manga-upscale/Setup.ps1`, then `Start Manga Upscale AI.cmd`. See README.md and MANGA-UPSCALE.md for setup, supported formats, limitations, code provenance, and licenses.
