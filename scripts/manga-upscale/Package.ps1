[CmdletBinding()]
param([string]$OutputPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $releaseRoot = Join-Path $appRoot 'release'
    $OutputPath = Join-Path $releaseRoot 'MangaUpscaleAI-windows-x64.zip'
} else {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    $releaseRoot = Split-Path -Parent $OutputPath
}
$null = [IO.Directory]::CreateDirectory($releaseRoot)
if (Test-Path -LiteralPath $OutputPath) { throw "Package already exists; move it before creating another: $OutputPath" }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('MangaUpscaleAI-package-' + [Guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stage 'MangaUpscaleAI-windows-x64'
$null = [IO.Directory]::CreateDirectory($packageRoot)
$files = @(
    'Start Manga Upscale AI.cmd',
    'Setup Manga Upscale AI.cmd',
    'Package Manga Upscale AI.cmd',
    'MANGA-UPSCALE.md',
    'LICENSE',
    'LICENSE-APACHE',
    'scripts/manga-upscale/Studio.ps1',
    'scripts/manga-upscale/Setup.ps1',
    'scripts/manga-upscale/Package.ps1',
    'scripts/manga-upscale/THIRD-PARTY-NOTICES.md'
)
try {
    foreach ($relative in $files) {
        $source = Join-Path $appRoot $relative
        if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required package file is missing: $source" }
        $destination = Join-Path $packageRoot $relative
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $source -Destination $destination
    }
    $null = [IO.Directory]::CreateDirectory($releaseRoot)
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $OutputPath -CompressionLevel Optimal
    if (!(Test-Path -LiteralPath $OutputPath) -or (Get-Item -LiteralPath $OutputPath).Length -lt 10KB) {
        throw 'The standalone upscaler ZIP is missing or unexpectedly small.'
    }
    Write-Host "Standalone Manga Upscale AI ZIP created: $OutputPath" -ForegroundColor Green
    Write-Host 'The ZIP contains the separate WPF launcher and setup scripts. First run downloads the Real-ESRGAN/FFmpeg runtime.'
    Write-Host ('ZIP size: {0:N1} KB' -f ((Get-Item -LiteralPath $OutputPath).Length / 1KB))
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
