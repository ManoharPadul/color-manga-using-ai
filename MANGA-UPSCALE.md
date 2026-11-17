# Manga Upscale AI

Manga Upscale AI is a separate Windows desktop utility for enlarging one image or a folder of images. It does not start MangaColorAI, ComfyUI, FLUX, or any colorization workflow.

## Start

1. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\manga-upscale\Setup.ps1` once. It downloads the portable Real-ESRGAN Vulkan package and an FFmpeg LGPL build into `.manga-upscale-runtime`.
2. Run `Start Manga Upscale AI.cmd`.
3. Choose one image or a folder, choose the destination and output format, then select **Upscale ×4**.

The UI processes files sequentially. Folder outputs preserve their relative subfolder paths. Source files are never overwritten. Animated GIF and multi-page TIFF inputs use their first frame/page. Supported inputs are PNG, JPEG, WebP, BMP, TIFF, and GIF; FFmpeg handles input decoding and output encoding. Outputs can be PNG, JPEG, or WebP.

## Engine and options

- Model: `realesrgan-x4plus-anime`, fixed for anime/manga artwork.
- Scale: 4×.
- Device: Vulkan auto-detection. The portable upstream build supports NVIDIA, AMD, and Intel GPUs; an RTX 4090 is supported through the installed NVIDIA Vulkan driver.
- Tile size: Auto (`0`) by default; smaller tiles are available if a driver reports an allocation failure.
- FFmpeg is used to decode supported inputs into a temporary PNG and encode the selected output format. The Real-ESRGAN program receives one page at a time.
- Setup downloads about 200 MB of compressed tools and needs extra temporary disk space while extracting. Model weights are already in the official Real-ESRGAN portable archive.

Upscaling increases pixel dimensions and can reconstruct small details, but it cannot guarantee recovery of details absent from the input. Inspect outputs at 100% and use the original when the model invents or changes line details.

## Files

- `Start Manga Upscale AI.cmd` opens the separate desktop UI.
- `scripts/manga-upscale/Setup.ps1` installs or repairs the two local tools.
- `scripts/manga-upscale/Studio.ps1` is the UI and batch coordinator.
- `scripts/manga-upscale/Setup.ps1` downloads and verifies the expected files in the official archives.
- Runtime files stay under `.manga-upscale-runtime` and are not committed.

## Third-party software

The Real-ESRGAN portable package and its model are provided by [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) under its BSD 3-Clause license. FFmpeg is downloaded as the Windows x64 static LGPL build from [FFmpeg-Builds](https://github.com/FFmpeg-Builds/FFmpeg-Builds); the build archive's license/notices are copied alongside the executable when available. See the separate [third-party notices](scripts/manga-upscale/THIRD-PARTY-NOTICES.md) and the included upstream notices in the runtime folder.

This utility invokes the downloaded executables as separate local processes. It does not include their code in MangaColorAI and does not upload images.
