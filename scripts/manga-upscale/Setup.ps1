[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$runtimeRoot = Join-Path $appRoot '.manga-upscale-runtime'
$downloadRoot = Join-Path $runtimeRoot 'downloads'
$extractRoot = Join-Path $runtimeRoot 'extract'
$realesrganRoot = Join-Path $runtimeRoot 'realesrgan'
$ffmpegRoot = Join-Path $runtimeRoot 'ffmpeg'
$realesrganUrl = 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip'
$ffmpegUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-win64-lgpl-9.0.zip'

function Download-Archive {
    param([Parameter(Mandatory=$true)][string]$Uri,[Parameter(Mandatory=$true)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Write-Host "Downloading $([IO.Path]::GetFileName($Destination)) ..."
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    if (!(Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -lt 1MB) {
        throw "Download is missing or too small: $Destination"
    }
}

function Expand-ArchiveFresh {
    param([Parameter(Mandatory=$true)][string]$Archive,[Parameter(Mandatory=$true)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    $null = [IO.Directory]::CreateDirectory($Destination)
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
}

$null = [IO.Directory]::CreateDirectory($downloadRoot)
$null = [IO.Directory]::CreateDirectory($realesrganRoot)
$null = [IO.Directory]::CreateDirectory($ffmpegRoot)
$realesrganArchive = Join-Path $downloadRoot 'realesrgan-ncnn-vulkan-windows.zip'
$ffmpegArchive = Join-Path $downloadRoot 'ffmpeg-win64-lgpl.zip'
$realesrganExtract = Join-Path $extractRoot 'realesrgan'
$ffmpegExtract = Join-Path $extractRoot 'ffmpeg'

try {
    Download-Archive -Uri $realesrganUrl -Destination $realesrganArchive
    Expand-ArchiveFresh -Archive $realesrganArchive -Destination $realesrganExtract
    $realExe = Get-ChildItem -LiteralPath $realesrganExtract -Filter 'realesrgan-ncnn-vulkan.exe' -File -Recurse | Select-Object -First 1
    $models = Get-ChildItem -LiteralPath $realesrganExtract -Directory -Recurse | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'realesrgan-x4plus-anime.param')) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'realesrgan-x4plus-anime.bin'))
    } | Select-Object -First 1
    if ($null -eq $realExe -or $null -eq $models) {
        throw 'The downloaded Real-ESRGAN archive did not contain its executable and x4plus-anime model files.'
    }
    Copy-Item -LiteralPath $realExe.FullName -Destination (Join-Path $realesrganRoot 'realesrgan-ncnn-vulkan.exe') -Force
    $modelDestination = Join-Path $realesrganRoot 'models'
    if (Test-Path -LiteralPath $modelDestination) { Remove-Item -LiteralPath $modelDestination -Recurse -Force }
    Copy-Item -LiteralPath $models.FullName -Destination $modelDestination -Recurse
    $realLicense = Get-ChildItem -LiteralPath $realesrganExtract -File -Recurse | Where-Object { $_.Name -match '^(LICENSE|COPYING)(\..*)?$' } | Select-Object -First 1
    if ($null -ne $realLicense) { Copy-Item -LiteralPath $realLicense.FullName -Destination (Join-Path $realesrganRoot 'LICENSE-Real-ESRGAN.txt') -Force }
    $licenseDestination = Join-Path $realesrganRoot 'LICENSE-Real-ESRGAN.txt'
    if (!(Test-Path -LiteralPath $licenseDestination)) {
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/xinntao/Real-ESRGAN/v0.2.5.0/LICENSE' -OutFile $licenseDestination -UseBasicParsing
    }

    Download-Archive -Uri $ffmpegUrl -Destination $ffmpegArchive
    Expand-ArchiveFresh -Archive $ffmpegArchive -Destination $ffmpegExtract
    $ffmpegExe = Get-ChildItem -LiteralPath $ffmpegExtract -Filter 'ffmpeg.exe' -File -Recurse | Select-Object -First 1
    if ($null -eq $ffmpegExe) { throw 'The downloaded FFmpeg archive did not contain ffmpeg.exe.' }
    Copy-Item -LiteralPath $ffmpegExe.FullName -Destination (Join-Path $ffmpegRoot 'ffmpeg.exe') -Force
    $ffprobeExe = Join-Path $ffmpegExe.Directory.FullName 'ffprobe.exe'
    if (Test-Path -LiteralPath $ffprobeExe) { Copy-Item -LiteralPath $ffprobeExe -Destination (Join-Path $ffmpegRoot 'ffprobe.exe') -Force }
    $ffmpegNotices = Get-ChildItem -LiteralPath $ffmpegExtract -File -Recurse | Where-Object { $_.Name -match '^(LICENSE|COPYING|README)(\..*)?$' }
    foreach ($notice in $ffmpegNotices) {
        $safeName = 'FFmpeg-' + $notice.Name
        Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $ffmpegRoot $safeName) -Force -ErrorAction SilentlyContinue
    }
    if (@(Get-ChildItem -LiteralPath $ffmpegRoot -Filter '*COPYING*' -File).Count -eq 0 -and @(Get-ChildItem -LiteralPath $ffmpegRoot -Filter '*LICENSE*' -File).Count -eq 0) {
        Write-Warning 'FFmpeg archive did not include a separately named notice file. Run ffmpeg.exe -L and consult the FFmpeg-Builds licensing page before redistribution.'
    }

    $exePath = Join-Path $realesrganRoot 'realesrgan-ncnn-vulkan.exe'
    $modelPath = Join-Path $realesrganRoot 'models'
    $ffmpegPath = Join-Path $ffmpegRoot 'ffmpeg.exe'
    if (!(Test-Path -LiteralPath $exePath) -or !(Test-Path -LiteralPath $ffmpegPath) -or
        !(Test-Path -LiteralPath (Join-Path $modelPath 'realesrgan-x4plus-anime.param')) -or
        !(Test-Path -LiteralPath (Join-Path $modelPath 'realesrgan-x4plus-anime.bin'))) {
        throw 'Runtime validation failed after extraction. Re-run setup to repair the installation.'
    }
    @(
        'Real-ESRGAN NCNN Vulkan: v0.2.5.0 (official portable Windows release)'
        'Model: realesrgan-x4plus-anime'
        'FFmpeg: 9.0 LGPL static Windows x64 build (FFmpeg-Builds latest release at installation time)'
        "Installed: $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    ) | Set-Content -LiteralPath (Join-Path $runtimeRoot 'versions.txt') -Encoding UTF8
    Write-Host ''
    Write-Host 'Upscale runtime installed and checked.' -ForegroundColor Green
    Write-Host "Runtime folder: $runtimeRoot"
    Write-Host 'You can now run Start Manga Upscale AI.cmd.'
}
finally {
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $downloadRoot) { Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
