# MangaColorAI

Local Windows manga colorization and review tools using FLUX.2 Klein, Qwen Image 2.1, FLUX.1 Kontext, MiniMax H3 Image, or experimental Illustrious XL through ComfyUI. The repository includes a native Rust desktop studio, command-line folder/single-page workflows, CPU image preparation and color-region review tools, and an optional Koharu-based text/OCR helper.

> **Model files are not included in the Windows ZIP.** First setup downloads the selected model and ComfyUI runtime. Check each model's current license before use, especially the non-commercial FLUX.2 Klein 9B weights.

## Windows quick start

1. Download and extract `MangaColorAI-0.3.15-windows-x64.zip` from the [Releases page](https://github.com/ManoharPadul/color-manga-using-ai/releases). Keep the extracted folder together; the app locates its scripts relative to that folder.
2. For the recommended 4B FP8 setup, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\local-manga\Setup.ps1 -ModelSize 4B`. For 9B FP8, use `-ModelSize 9B`. Setup downloads ComfyUI's portable Windows runtime, installs its pinned CUDA PyTorch runtime, downloads the chosen model files, and checks their SHA-256 hashes. Keep at least 40 GB free for 4B or 50 GB for 9B so there is room for runtime, model and working files.
3. Run `Start MangaColorAI.cmd` and choose an image or a folder. The local ComfyUI service binds to `127.0.0.1`; it starts when the app needs it. No image is uploaded by these workflows.
4. Outputs go to `manga-output`. Inputs are not overwritten. Folder jobs process images one by one and save reports/settings alongside the results.

For image enlargement only, use the separate [Manga Upscale AI](MANGA-UPSCALE.md) utility. It uses Real-ESRGAN x4plus-anime and FFmpeg; it does not start the colorization model or modify MangaColorAI settings.

Supported image inputs in the standalone preparation helper: PNG, JPEG, WebP, BMP, TIFF, and GIF (one decoded frame). Colorized output is PNG at the input image's pixel dimensions. Color models may work at a smaller megapixel target and resize back afterward; original-size output does not restore fine detail that was lost during model downscaling.

### Windows command files

The repository keeps a small set of launch/build commands: `Start MangaColorAI.cmd`, `Stop Local AI.cmd`, and `Build MangaColorAI.cmd`. The separate upscaler has its own `Start Manga Upscale AI.cmd`. The desktop colorization studio handles both single images and folders, model selection, palettes, character/outfit profiles, reference pages, source-ink controls, optional text processing, color-coverage diagnostics, painted repair masks, and before/after review. See [launcher notes](MANGA-LAUNCHERS.md).

Default colorization settings are four inference steps, guidance 1, strength 1, and seed 42. These are a speed-oriented baseline, not quality guarantees. Keep a fixed seed when making controlled prompt/settings comparisons. The separate upscaler is launched with `Start Manga Upscale AI.cmd` after its PowerShell setup step; see [MANGA-UPSCALE.md](MANGA-UPSCALE.md).

## Models and machine requirements

| Selection | What it does | Downloaded weights (approx.) | License / practical hardware |
|---|---|---:|---|
| Klein 4B FP8 | Distilled FLUX image edit/color model; recommended starting point | 4.07 GB transformer + 8.04 GB Qwen3 4B text encoder + 0.34 GB VAE = **12.45 GB** | BFL states about **13 GB VRAM**; a 24 GB RTX 4090 has useful headroom at normal page sizes. Apache-2.0 model card. |
| Klein 4B BF16 | Same 4B family at higher transformer precision | 7.75 GB transformer + 8.04 GB text encoder + 0.34 GB VAE = **16.13 GB** | Larger VRAM demand than FP8; at 24 GB, use conservative resolution and expect less headroom. Apache-2.0 model card. |
| Klein 9B FP8 | Larger distilled model with a Qwen3 8B text encoder | 9.43 GB transformer + 8.66 GB text encoder + 0.34 GB VAE = **18.43 GB** | Fits near the capacity of a 24 GB card on disk alone, but runtime buffers, VAE, resolution and Windows display use add VRAM. **24 GB is tight and OOM is possible**; begin at low MP. BFL non-commercial license and access terms. |
| Klein Base 4B FP8 (optional) | Undistilled/experimental 4B path; separate 50-step settings | Adds 4.09 GB | Optional download via `Setup.ps1 -ModelSize 4B -IncludeQuality`; much slower than the distilled default. Apache-2.0 model card. |
| Qwen Image 2.1 INT8 ConvRot | Full-page image edit/color workflow with a separate isolated CUDA 13 Python runtime | About **17.3 GB** across diffusion model, Qwen text encoder and VAE | Qwen Research License: non-commercial/research purposes only unless separately licensed. 25 steps / 1.5 MP default. Model use has not been inference-tested in this release. |
| FLUX.1 Kontext Dev FP8 | Full-page image-edit workflow; separate reference image is supported | About **17.6 GB** including its gated 11.9 GB checkpoint and shared text/VAE files | Requires accepting the Black Forest Labs license and manually placing the gated checkpoint. BFL non-commercial terms apply; 20 steps / 1.5 MP default. 24 GB is tight; OOM may occur. |
| MiniMax H3 Image INT8 + NVFP4 text encoder | Full-page edit/color workflow with image reference support | About **37.8 GB** across model, text encoder and VAE | ComfyUI 0.45.0+ required; setup will not silently replace an older runtime. Dynamic offload is enabled and 6 steps / 4 MP are selected. **24 GB VRAM is not guaranteed**; OOM or slow offload is possible. Its license excludes use in the US, EU, UK and South Korea and has revenue/hosted-service terms; review the complete agreement. |
| Illustrious XL v2.0 (experimental) | SDXL img2img workflow using the complete checkpoint | **6.94 GB** | CreativeML OpenRAIL-M. 20 steps / 1.0 MP / 0.35 denoise default. It is an experimental general image model, not a source-locked manga colorizer; it can redraw text or geometry. Quality and VRAM use are not evaluated here. |

Figures above are decimal GB from the checked-in setup manifest file sizes, not observed peak VRAM. BFL's public 4B card says the family can run at about 13 GB VRAM; the repo does not claim that as an exact peak for every page/settings combination. 9B peak use depends strongly on ComfyUI offload behavior and resolution. A **32 GB system RAM floor** and **64 GB recommended** for 9B, large pages, or optional vision/OCR work are project planning recommendations, not guarantees from the model authors. Use an SSD and additional free space for ComfyUI, PyTorch, caches and working images.

The ZIP contains only MangaColorAI source/resources and executables. None of these model weights are bundled. You can install each added model separately from the repository folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\local-manga\Setup.ps1 -ModelSize None -IncludeQwen21
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\local-manga\Setup.ps1 -ModelSize None -IncludeFlux1Kontext
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\local-manga\Setup.ps1 -ModelSize None -IncludeMiniMaxH3
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\local-manga\Setup.ps1 -ModelSize None -IncludeIllustriousXL
```

You may combine switches, but allow disk space for every selected weight set. FLUX.1 Kontext is gated: accept BFL's terms and put `flux1-kontext-dev-fp8-e4m3fn.safetensors` (11,901,540,704 bytes) in `.local-ai\models\diffusion_models` before running its setup command. For MiniMax H3, if your existing portable ComfyUI is older than 0.45.0, stop its backend and rename `.local-ai\ComfyUI_windows_portable` to keep a backup; setup will then install the required runtime while the separate `.local-ai\models` folder keeps downloaded weights. Do not move/replace a runtime while a job is running. Qwen setup creates a separate Python/CUDA 13 runtime. No model setup or GPU inference is run by the release package itself.

### Optional vision and text models

These are additional tasks, separate from FLUX colorization:

- The **Qwen3 4B or Qwen3 8B text encoder** is part of the FLUX model file set and encodes prompts. It is not an independent chat assistant or a manga color classifier.
- **Qwen3.5 4B GGUF** is used by Koharu's optional vision review / character-matching flows when configured. The Koharu helper pins the `unsloth/Qwen3.5-4B-GGUF` snapshot and selects `Qwen3.5-4B-UD-Q4_K_XL.gguf` (about 2.91 GB) plus `mmproj-F16.gguf` (about 0.67 GB). Those files are downloaded separately when its `setup-vision` path is requested. They add about 3.6 GB disk; GPU/RAM use varies with Koharu backend/device settings. It provides advisory OCR/vision information, not the color diffusion.
- Koharu's text pipeline also supports manga text detection/OCR, inpainting, translation and text rendering. In-app choices depend on installed Koharu models and provider configuration; this release does not bundle those weights or API credentials.

## How the color workflow works

1. **Prepare.** A standalone Rust image helper decodes supported formats, checks dimensions/allocation limits, converts input to PNG for the ComfyUI API, and optionally resizes the working image to the chosen megapixel target.
2. **Color.** The PowerShell workflow sends a ComfyUI API graph to the local portable backend. Its unchanged default is FLUX.2 Klein 4B FP8, four steps, guidance 1, strength 1. Klein models can condition on a separate reference image. The added Qwen 2.1, FLUX.1 Kontext and MiniMax H3 options use their model-specific full-page edit graphs. Illustrious uses an SDXL image-to-image graph at a conservative denoise setting, but can still redraw page content. These added model paths have CPU-side wiring and setup manifests only; this release was not run with their weights/GPU inference, so color quality, text preservation and hardware fit are unverified.
3. **Restore and inspect.** The workflow exports a PNG at source dimensions, can restore approved protected source regions such as text, and can restore ink/shadow detail. CPU color-coverage diagnostics compare source and output; optional region repair uses user-approved masks/palettes. Uncertain repairs are for human review and should not silently replace the output.
4. **Optional text tools.** A separate Rust adapter calls selected Koharu libraries for manga OCR/text cleanup/translation workflows. Its model lifecycle is handled separately from the FLUX backend to avoid holding both model families in VRAM at once.

Diffusion models infer colors from the page and prompt; they do not know the official colors unless you provide a useful character palette/reference. They can change facial details, eye state, lettering, object geometry, or colors between panels. A saved palette and reference can improve consistency but cannot guarantee it. For reliable fixes, inspect the original and intermediate outputs and use a painted mask plus an approved category/color; do not trust saturation-only heuristics to identify skin, clothing, or hair.

## Included code, adaptations and third-party components

- **MangaColorAI desktop and CLI workflows:** native Rust `eframe` app in `tools/mangacolorai`; standalone image utility in `tools/manga-image`; PowerShell orchestration and ComfyUI API graph in `scripts/local-manga` and `workflows/local-manga`. The app is a native desktop program; it does not use Tauri, Electron, JavaScript, a webview, or PhotoCraft's editor UI.
- **What came from the PhotoCraft workspace:** MangaColorAI was originally developed as a local-manga feature inside a PhotoCraft checkout and then extracted/refactored into this repository. This repo contains the MangaColorAI-specific UI, helper crates and scripts, but **does not include PhotoCraft's editor, engine, CLI, workspace crates, or `.pcraft` document integration**. It calls no PhotoCraft executable or library at runtime. The extracted source remains under the originating MIT/Apache dual license; see the bundled license files and [ATTRIBUTION.md](ATTRIBUTION.md).
- **Koharu:** the optional `tools/manga-text` binary links against Koharu library crates from upstream commit `c1a43cf7de2a0d40dc92afcbb0a55bbce0468dd8` (MIT OR Apache-2.0). The Koharu application is not copied or bundled. See [Koharu](https://github.com/koharu-rs/koharu) and [ATTRIBUTION.md](ATTRIBUTION.md).
- **ComfyUI:** setup installs the upstream portable Windows distribution at v0.45.0 when no runtime is present; it is not committed or embedded in the MangaColorAI source ZIP. MiniMax H3 needs this version or newer. Review [ComfyUI v0.45.0](https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.45.0).
- **Model weights:** all weights download separately. See the [Klein 4B](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B) and [9B](https://huggingface.co/black-forest-labs/FLUX.2-klein-9B) model cards, [Qwen Image 2.1](https://huggingface.co/Comfy-Org/Qwen-Image-2.1), [FLUX.1 Kontext Dev](https://huggingface.co/black-forest-labs/FLUX.1-Kontext-dev), [MiniMax H3 Image](https://huggingface.co/Comfy-Org/MiniMax-H3-Image), and [Illustrious XL v2.0](https://huggingface.co/OnomaAIResearch/Illustrious-XL-v2.0). Follow each license and gated-download condition; model licenses do not grant rights to source manga or generated images.

## Build from source

Requirements: Windows x64, Rust stable toolchain (edition 2024 support), Git, Microsoft C++ Build Tools for MSVC, and a network connection for Cargo/Koharu dependencies. A LibClang install may be required by Koharu transitive dependencies. The release ZIP includes the compiled MangaColorAI and image-helper executables; building source is optional.

1. Install Rust and Git.
2. Run `Build MangaColorAI.cmd`. It builds the native studio and `MangaColorAI-Image.exe` into `bin/`, then checks out the pinned Koharu source and builds its optional text helper. Use `-SkipTextHelper` with `scripts/local-manga/Build-MangaColorAI.ps1` to skip Koharu.
3. Install inference dependencies and model files with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\local-manga\Setup.ps1 -ModelSize 4B` or change `4B` to `9B`.

The Rust binaries can also be built individually with Cargo manifests under `tools/`. Tests and CPU-only diagnostics are available under `scripts/local-manga`; GPU inference smoke testing is opt-in and requires local model files.

## License and attribution

MangaColorAI source is distributed under MIT OR Apache-2.0. Third-party model weights, Koharu, ComfyUI, and any downloaded OCR/vision assets retain their own licenses; see [ATTRIBUTION.md](ATTRIBUTION.md) and the upstream model cards. Do not redistribute model weights in the project release ZIP.
