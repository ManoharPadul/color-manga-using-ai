# MangaColorAI 0.3.13 for Windows x64

This release packages the native MangaColorAI studio and image preparation utility. FLUX, Qwen, ComfyUI, OCR and translation model files are not included; the setup scripts download only the selected color model and shared VAE, then validate its expected file hashes.

## Choose the right model

- **4B FP8:** recommended default; about 12.45 GB of model files, BFL reports about 13 GB VRAM for this model family.
- **4B BF16:** about 16.13 GB of model files; higher memory pressure.
- **9B FP8:** about 18.43 GB of model files; 24 GB GPU memory is tight and higher-resolution jobs may run out of memory. Non-commercial BFL license applies.

Run `Setup MangaColorAI 4B.cmd` or `Setup MangaColorAI 9B.cmd`, then `Start MangaColorAI.cmd`. Consult README.md for complete setup, limitations, code provenance and model licensing.
