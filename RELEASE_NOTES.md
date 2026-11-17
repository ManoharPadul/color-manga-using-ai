# MangaColorAI 0.3.15 for Windows x64

This Windows x64 release packages the native MangaColorAI studio, image preparation utility, optional Koharu text helper, and the separate Manga Upscale AI utility. It adds Qwen Image 2.1, FLUX.1 Kontext, MiniMax H3 Image and experimental Illustrious XL v2.0 choices alongside the existing FLUX.2 Klein workflow. The Klein default and sampling settings are unchanged. No GPU inference was run for the new models; this release does not claim that their manga color quality, text fidelity, or 24 GB VRAM fit is validated.

## Changes

- Add a separate image/folder upscaler using Real-ESRGAN `realesrgan-x4plus-anime` at ×4, with FFmpeg decoding/encoding. Its setup script downloads the runtime tools on first use; they are not bundled in the ZIP.
- Keep only the colorizer start, stop, and build command files, plus the upscaler start command. Model setup is run directly through the documented PowerShell script.
- Update the launcher guide and README to match the reduced command-file set and explain both utilities.
- Keep original manga inputs unchanged. The upscaler writes results to a selected output location.
- Add Qwen Image 2.1 INT8, FLUX.1 Kontext Dev FP8, MiniMax H3 Image INT8/NVFP4, and an experimental Illustrious XL SDXL img2img workflow with separate setup switches and pinned checksums.
- Pin new-model use to their own workflow/runtime checks. MiniMax H3 requires ComfyUI 0.45.0 or newer; Qwen uses an isolated CUDA 13 Python runtime; Kontext checkpoint remains gated and user-supplied.

## Model/setup notes

The ZIP does not include ComfyUI, any FLUX/Qwen/MiniMax/Illustrious weights, or the upscaler runtime tools. Colorization setup downloads the selected model components; FLUX.1 Kontext checkpoint is gated and user-supplied. The separate upscaler setup downloads Real-ESRGAN and FFmpeg. Review upstream software and model licenses before use.

## Choose the right model

- **4B FP8:** recommended default; about 12.45 GB of model files, BFL reports about 13 GB VRAM for this model family.
- **4B BF16:** about 16.13 GB of model files; higher memory pressure.
- **9B FP8:** about 18.43 GB of model files; 24 GB GPU memory is tight and higher-resolution jobs may run out of memory. Non-commercial BFL license applies.

For colorization, use the PowerShell setup command in README.md, then run `Start MangaColorAI.cmd`. For image enlargement, run `scripts/manga-upscale/Setup.ps1`, then `Start Manga Upscale AI.cmd`. See README.md and MANGA-UPSCALE.md for setup, supported formats, limitations, code provenance, and licenses.

## Additional models

Qwen 2.1 uses 25 steps and an isolated CUDA 13 runtime; FLUX.1 Kontext uses 20 steps and requires accepted gated-model terms; MiniMax H3 uses 6 steps at 4 MP and needs ComfyUI 0.45.0 or newer; Illustrious uses an experimental 20-step SDXL img2img workflow at 1 MP and 0.35 denoise. Model downloads and GPU inference are not part of release validation, so output fidelity and VRAM behavior are not evaluated.
