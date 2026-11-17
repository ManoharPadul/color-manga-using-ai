# Changelog

## 0.3.15 — Additional local color models

- Add full-page model selection and ComfyUI workflows for Qwen Image 2.1 INT8 ConvRot, gated FLUX.1 Kontext Dev FP8, and MiniMax H3 Image INT8/NVFP4.
- Add an explicitly experimental Illustrious XL v2.0 SDXL img2img option with a low-denoise default.
- Add size/checksum-pinned model setup manifests and per-model runtime checks. Weights remain external and are not packaged.
- Keep the FLUX.2 Klein 4B FP8 default and its four-step/guidance/strength settings unchanged.
- Update the README, model-license attribution, and setup notes. No GPU inference was run; output quality and model-specific VRAM fit remain unevaluated.

## 0.3.14 — Separate Manga Upscale AI utility

- Add a standalone Windows GUI for upscaling one image or a folder with Real-ESRGAN x4plus-anime and FFmpeg.
- Remove the per-model, setup, repair, and one-off `.cmd` launchers. Keep the MangaColorAI start, stop, and build commands, plus the separate upscaler start command.
- Document direct PowerShell setup for the colorizer and upscaler.
- No changes to the color inference workflow or sampling defaults. Text/lettering fidelity remains model-dependent and is not claimed fixed in this release.

## 0.3.13 — Standalone Windows package

- Extract MangaColorAI workflows and native studio into the dedicated repository.
- Remove PhotoCraft runtime installation, editor launch, CLI calls, and native `.pcraft` output expectations.
- Add standalone Rust image conversion/resize/crop utility and model-selectable setup manifests.
- Document upstream code/model sources, license boundaries, and approximate disk/VRAM requirements.
