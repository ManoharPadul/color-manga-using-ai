[CmdletBinding()]
param([ValidateSet('4B','9B')][string]$ModelSize='4B', [switch]$IncludeQuality, [switch]$IncludeConsistency, [switch]$IncludeFullPrecision)
. "$PSScriptRoot/Common.ps1"
New-Item -ItemType Directory -Force $AiRoot | Out-Null
$cache = Join-Path $AiRoot 'downloads'
New-Item -ItemType Directory -Force $cache | Out-Null

function Get-Download {
    param([string]$Url, [string]$Destination)
    New-Item -ItemType Directory -Force (Split-Path $Destination -Parent) | Out-Null
    $partial = $Destination + '.partial'
    & curl.exe -L --fail --retry 5 --retry-all-errors --speed-time 60 --speed-limit 1024 `
        -C - -o $partial $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed; rerun Setup.ps1 to resume: $Url" }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

if (!(Test-Path (Join-Path $PortableRoot 'python_embeded/python.exe'))) {
    $archive = Join-Path $cache 'ComfyUI-v0.44.0-nvidia.7z'
    if (!(Test-Path $archive)) {
        Get-Download 'https://github.com/Comfy-Org/ComfyUI/releases/download/v0.44.0/ComfyUI_windows_portable_nvidia.7z' $archive
    }
    & tar.exe -xf $archive -C $AiRoot
    if ($LASTEXITCODE -ne 0) { throw 'ComfyUI extraction failed.' }
}
# Pin the tested CUDA runtime inside the portable environment only. The stock
# 2.14/CUDA 13 build raised an illegal-instruction exception during GPU inference
# on this machine. This does not modify the user's system Python installation.
$python = Join-Path $PortableRoot 'python_embeded/python.exe'
$torchVersion = & $python -s -c "import importlib.metadata; print(importlib.metadata.version('torch'))"
if ($torchVersion -ne '2.10.0+cu128') {
    if (Test-LocalBackend) { throw 'Close the local backend with Stop.ps1 before updating its runtime.' }
    & $python -s -m pip install 'torch==2.10.0' 'torchvision==0.25.0' 'torchaudio==2.10.0' `
        --index-url 'https://download.pytorch.org/whl/cu128' --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw 'CUDA runtime installation failed. Rerun Setup.ps1.' }
}
$modelManifest = if ($ModelSize -eq '9B') { '9b-models.json' } else { 'models.json' }
$models = Get-Content (Join-Path $PSScriptRoot $modelManifest) -Raw | ConvertFrom-Json
if ($IncludeQuality) { $models = @($models) + @(Get-Content "$PSScriptRoot/quality-model.json" -Raw | ConvertFrom-Json) }
if ($IncludeConsistency) { $models = @($models) + @(Get-Content "$PSScriptRoot/consistency-model.json" -Raw | ConvertFrom-Json) }
if ($IncludeFullPrecision) { $models = @($models) + @(Get-Content "$PSScriptRoot/full-precision-model.json" -Raw | ConvertFrom-Json) }
foreach ($model in $models) {
    $destination = Join-Path $AiRoot ('models/' + $model.path)
    if (!(Test-Path $destination) -or (Get-Item $destination).Length -ne $model.bytes) {
        # Preserve partial downloads so a disconnected setup can resume.
        if (Test-Path $destination) { Move-Item -LiteralPath $destination -Destination ($destination + '.partial') -Force }
        Get-Download $model.url $destination
    }
    Write-Host "Verifying $($model.path)..."
    if ((Get-MangaFileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $model.sha256) {
        throw "Checksum mismatch for $destination. Move it out of the model folder and rerun setup."
    }
}
Write-Host "Setup complete for Klein $ModelSize. Run Start MangaColorAI.cmd to open the standalone studio; the ComfyUI backend starts when needed."
