# Changelog

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
