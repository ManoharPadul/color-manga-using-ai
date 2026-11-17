[CmdletBinding()]
param([ValidateSet('4B','9B','None')][string]$ModelSize='4B', [switch]$IncludeQuality, [switch]$IncludeConsistency, [switch]$IncludeFullPrecision,
    [switch]$IncludeQwen21, [switch]$IncludeFlux1Kontext, [switch]$IncludeMiniMaxH3, [switch]$IncludeIllustriousXL)
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
    $archive = Join-Path $cache 'ComfyUI-v0.45.0-nvidia.7z'
    if (!(Test-Path $archive)) {
        Get-Download 'https://github.com/Comfy-Org/ComfyUI/releases/download/v0.45.0/ComfyUI_windows_portable_nvidia.7z' $archive
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
$models = if ($ModelSize -eq 'None') { @() } else { Get-Content (Join-Path $PSScriptRoot $modelManifest) -Raw | ConvertFrom-Json }
if ($IncludeQuality) { $models = @($models) + @(Get-Content "$PSScriptRoot/quality-model.json" -Raw | ConvertFrom-Json) }
if ($IncludeConsistency) { $models = @($models) + @(Get-Content "$PSScriptRoot/consistency-model.json" -Raw | ConvertFrom-Json) }
if ($IncludeFullPrecision) { $models = @($models) + @(Get-Content "$PSScriptRoot/full-precision-model.json" -Raw | ConvertFrom-Json) }
if ($IncludeQwen21) {
    $qwenRoot = Join-Path $AiRoot 'qwen21-cuda13'
    $qwenPythonRoot = Join-Path $qwenRoot 'python_embeded'
    $qwenPython = Join-Path $qwenPythonRoot 'python.exe'
    if (!(Test-Path -LiteralPath $qwenPython -PathType Leaf)) {
        if (Test-LocalBackend) { throw 'Stop the local backend before preparing the isolated Qwen runtime.' }
        New-Item -ItemType Directory -Force -Path $qwenRoot | Out-Null
        & robocopy.exe (Join-Path $PortableRoot 'python_embeded') $qwenPythonRoot /E /COPY:DAT /R:2 /W:2 /XJ /NFL /NDL /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Could not copy the isolated Qwen Python runtime (robocopy exit $LASTEXITCODE)." }
    }
    $pth = Join-Path $qwenPythonRoot 'python313._pth'
    if (!(Test-Path -LiteralPath $pth -PathType Leaf)) { throw 'The isolated Qwen Python runtime is missing python313._pth.' }
    $lines = [IO.File]::ReadAllLines($pth); $bound = $false
    for ($i = 0; $i -lt $lines.Length; $i++) { if ($lines[$i] -eq '../ComfyUI') { $lines[$i] = '../../ComfyUI_windows_portable/ComfyUI'; $bound = $true } }
    if (!$bound -and $lines -notcontains '../../ComfyUI_windows_portable/ComfyUI') { throw 'Could not bind the isolated Qwen runtime to the portable ComfyUI source.' }
    [IO.File]::WriteAllLines($pth, $lines, [Text.UTF8Encoding]::new($false))
    $qwenTorchVersion = & $qwenPython -s -c "import importlib.metadata; print(importlib.metadata.version('torch'))"
    if ($LASTEXITCODE -ne 0 -or $qwenTorchVersion.Trim() -ne '2.10.0+cu130') {
        if (Test-LocalBackend) { throw 'Stop the local backend before installing the isolated Qwen CUDA 13 runtime.' }
        & $qwenPython -s -m pip install --upgrade --force-reinstall 'torch==2.10.0' 'torchvision==0.25.0' 'torchaudio==2.10.0' --index-url 'https://download.pytorch.org/whl/cu130' --disable-pip-version-check --no-warn-script-location
        if ($LASTEXITCODE -ne 0) { throw 'Qwen CUDA 13 runtime installation failed. Rerun Setup.ps1 -IncludeQwen21.' }
    }
    $models = @($models) + @(Get-Content (Join-Path $PSScriptRoot 'qwen21-models.json') -Raw | ConvertFrom-Json)
}
if ($IncludeFlux1Kontext) {
    $fluxCheckpoint = Join-Path $AiRoot 'models/diffusion_models/flux1-kontext-dev-fp8-e4m3fn.safetensors'
    if (!(Test-Path -LiteralPath $fluxCheckpoint -PathType Leaf) -or (Get-Item -LiteralPath $fluxCheckpoint).Length -ne 11901540704) {
        throw 'FLUX.1 Kontext is gated. Accept the Black Forest Labs license, place flux1-kontext-dev-fp8-e4m3fn.safetensors in .local-ai/models/diffusion_models, then rerun Setup.ps1 -IncludeFlux1Kontext.'
    }
    $models = @($models) + @(Get-Content (Join-Path $PSScriptRoot 'flux1-kontext-models.json') -Raw | ConvertFrom-Json)
}
if ($IncludeMiniMaxH3) {
    $versionFile = Join-Path $ComfyRoot 'comfyui_version.py'
    $h3NodeFile = Join-Path $ComfyRoot 'comfy_extras/nodes_minimax_h3.py'
    $comfyVersion = if (Test-Path -LiteralPath $versionFile) { [regex]::Match((Get-Content -LiteralPath $versionFile -Raw), '__version__\s*=\s*["'']([^"'']+)["'']').Groups[1].Value } else { '' }
    $h3Node = if (Test-Path -LiteralPath $h3NodeFile) { Get-Content -LiteralPath $h3NodeFile -Raw } else { '' }
    if ($comfyVersion -notmatch '^0\.(45|[5-9][0-9])\.' -or $h3Node -notmatch 'MiniMaxH3ImageConditioning') { throw "MiniMax H3 Image requires ComfyUI 0.45.0 or newer. Detected '$comfyVersion'; no existing ComfyUI files were changed." }
    $models = @($models) + @(Get-Content (Join-Path $PSScriptRoot 'minimax-h3-models.json') -Raw | ConvertFrom-Json)
}
if ($IncludeIllustriousXL) {
    $models = @($models) + @(Get-Content (Join-Path $PSScriptRoot 'illustrious-xl-models.json') -Raw | ConvertFrom-Json)
}
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
Write-Host "Setup complete for $(if($ModelSize -eq 'None'){'selected additional models'}else{'FLUX.2 Klein '+$ModelSize+' and selected additional models'}). Run Start MangaColorAI.cmd to open the standalone studio."
