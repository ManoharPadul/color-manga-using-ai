# Third-party notices

## Real-ESRGAN

The optional Real-ESRGAN NCNN Vulkan executable and `realesrgan-x4plus-anime` model are downloaded from [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), Windows portable release `v0.2.5.0`. Upstream license: BSD 3-Clause. The setup script places the upstream license beside the downloaded runtime.

## FFmpeg

FFmpeg is downloaded at setup time from [FFmpeg-Builds](https://github.com/FFmpeg-Builds/FFmpeg-Builds) as the Windows x64 static LGPL 9.0 build. The exact current archive version is recorded in `.manga-upscale-runtime/versions.txt`. The setup copies available upstream notices beside `ffmpeg.exe`; run `ffmpeg.exe -L` for the build's configuration and license summary.

## Manga Upscale AI

The app launcher and orchestration scripts in this project are available under the included MIT or Apache-2.0 license files. The app invokes the two downloaded tools as independent local processes and contains neither their source code nor model weights.
