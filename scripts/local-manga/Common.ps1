Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:AiRoot = Join-Path $RepoRoot '.local-ai'
$script:PortableRoot = Join-Path $AiRoot 'ComfyUI_windows_portable'
$script:ComfyRoot = Join-Path $PortableRoot 'ComfyUI'
$script:Api = 'http://127.0.0.1:8188'
function Get-MangaFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LiteralPath,[ValidateSet('SHA256')][string]$Algorithm='SHA256')
    # Stream through .NET directly: Windows PowerShell module auto-loading can
    # omit Get-FileHash when launched from a desktop app with a different environment.
    $path=[IO.Path]::GetFullPath($LiteralPath)
    $stream=[IO.File]::OpenRead($path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')
        return [pscustomobject]@{Algorithm=$Algorithm;Hash=$hash;Path=$path}
    }finally{$sha.Dispose();$stream.Dispose()}
}
$script:MangaImage = Join-Path $RepoRoot 'bin/MangaColorAI-Image.exe'
if (!(Test-Path -LiteralPath $script:MangaImage)) { $script:MangaImage = Join-Path $AiRoot 'mangacolorai/MangaColorAI-Image.exe' }
. "$PSScriptRoot/Palette.ps1"
. "$PSScriptRoot/Restoration.ps1"
. "$PSScriptRoot/ColorCoverage.ps1"
. "$PSScriptRoot/ColorRepair.ps1"

function Test-LocalBackend {
    try {
        $stats = Invoke-RestMethod "$Api/system_stats" -TimeoutSec 3
        return $null -ne $stats.system
    } catch { return $false }
}

function Enable-MangaLargeSafetensorsPread {
    param([Parameter(Mandatory=$true)][string]$ComfyPath)
    $utilsPath = Join-Path $ComfyPath 'comfy/utils.py'
    if (!(Test-Path -LiteralPath $utilsPath -PathType Leaf)) { throw "Cannot configure the Windows large-checkpoint reader; missing $utilsPath" }
    $source = [IO.File]::ReadAllText($utilsPath)
    $marker = '# MangaColorAI: use pread for large Windows safetensors to avoid mmap access violations.'
    if ($source.Contains($marker)) { return }
    $needle = '                with safetensors.safe_open(ckpt, framework="pt", device=device.type) as f:'
    if (!$source.Contains($needle)) { throw 'ComfyUI safetensors loader layout is unsupported; no runtime file was modified.' }
    $replacement = @'
                # MangaColorAI: use pread for large Windows safetensors to avoid mmap access violations.
                safetensors_backend = "pread" if os.name == "nt" and os.path.getsize(ckpt) >= 10 * 1024 ** 3 else "mmap"
                with safetensors.safe_open(ckpt, framework="pt", device=device.type, backend=safetensors_backend) as f:
'@
    $backupPath = "$utilsPath.mangacolorai-original"
    if (!(Test-Path -LiteralPath $backupPath -PathType Leaf)) { Copy-Item -LiteralPath $utilsPath -Destination $backupPath }
    [IO.File]::WriteAllText($utilsPath, $source.Replace($needle, $replacement.TrimEnd("`r", "`n")), [Text.UTF8Encoding]::new($false))
}

function Save-LocalImage {
    param([string]$Uri, [string]$Destination)
    # Windows PowerShell's Invoke-WebRequest -OutFile expands brackets as
    # wildcards. A FileStream treats the output path literally on both PS 5/7.
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object Net.Http.HttpClient $handler
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination)))
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Start-LocalBackend {
    param([ValidateSet('4B','9B','Qwen21','Flux1Kontext','MiniMaxH3','IllustriousXL')][string]$ModelSize='4B')
    $requiredModels = switch ($ModelSize) {
        '9B' { Get-Content "$PSScriptRoot/9b-models.json" -Raw | ConvertFrom-Json; break }
        'Qwen21' { Get-Content "$PSScriptRoot/qwen21-models.json" -Raw | ConvertFrom-Json; break }
        'Flux1Kontext' { Get-Content "$PSScriptRoot/flux1-kontext-models.json" -Raw | ConvertFrom-Json; break }
        'MiniMaxH3' { Get-Content "$PSScriptRoot/minimax-h3-models.json" -Raw | ConvertFrom-Json; break }
        'IllustriousXL' { Get-Content "$PSScriptRoot/illustrious-xl-models.json" -Raw | ConvertFrom-Json; break }
        default { Get-Content "$PSScriptRoot/models.json" -Raw | ConvertFrom-Json }
    }
    foreach ($model in $requiredModels) {
        $file = Join-Path $AiRoot ('models/' + $model.path)
        if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -ne [long]$model.bytes) {
            throw "Missing or incomplete model $($model.path). Run scripts/local-manga/Setup.ps1 with the matching -Include switch."
        }
    }
    $python = Join-Path $PortableRoot 'python_embeded/python.exe'
    $config = Join-Path $AiRoot 'model-paths.yaml'
    $logs = Join-Path $AiRoot 'logs'
    if ($ModelSize -eq 'Qwen21') {
        $qwenRoot = Join-Path $AiRoot 'qwen21-cuda13'
        $python = Join-Path $qwenRoot 'python_embeded/python.exe'
        $config = Join-Path $qwenRoot 'model-paths.yaml'
        $logs = Join-Path $qwenRoot 'logs'
        if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Install the isolated Qwen runtime with scripts/local-manga/Setup.ps1 -IncludeQwen21.' }
        $torchVersion = & $python -s -c "import importlib.metadata; print(importlib.metadata.version('torch'))"
        if ($LASTEXITCODE -ne 0 -or $torchVersion.Trim() -ne '2.10.0+cu130') { throw "Qwen runtime needs PyTorch 2.10.0+cu130; found '$torchVersion'. Rerun Setup.ps1 -IncludeQwen21." }
    }
    if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Run scripts/local-manga/Setup.ps1 first.' }
    if ($ModelSize -eq 'MiniMaxH3') {
        $comfyVersionFile = Join-Path $ComfyRoot 'comfyui_version.py'
        $h3NodeFile = Join-Path $ComfyRoot 'comfy_extras/nodes_minimax_h3.py'
        $comfyVersion = if (Test-Path -LiteralPath $comfyVersionFile) { [regex]::Match((Get-Content -LiteralPath $comfyVersionFile -Raw), '__version__\s*=\s*["'']([^"'']+)["'']').Groups[1].Value } else { '' }
        $h3NodeSource = if (Test-Path -LiteralPath $h3NodeFile) { Get-Content -LiteralPath $h3NodeFile -Raw } else { '' }
        if ($comfyVersion -notmatch '^0\.(45|[5-9][0-9])\.' -or $h3NodeSource -notmatch 'node_id="MiniMaxH3ImageConditioning"') {
            throw "MiniMax H3 Image needs ComfyUI 0.45.0 or newer with native MiniMaxH3ImageConditioning support. Found '$comfyVersion'. No runtime was changed. Run Setup.ps1 to install/update ComfyUI first."
        }
        Enable-MangaLargeSafetensorsPread -ComfyPath $ComfyRoot
    }
    if (!(Test-LocalBackend)) {
        $modelRoot = (Join-Path $AiRoot 'models').Replace('\', '/')
    @"
mangacolorai_local:
  base_path: '$modelRoot'
  diffusion_models: diffusion_models
  checkpoints: checkpoints
  text_encoders: text_encoders
  vae: vae
  loras: loras
"@ | Set-Content -LiteralPath $config -Encoding UTF8
    New-Item -ItemType Directory -Force $logs | Out-Null
    $env:HF_HUB_OFFLINE = '1'
    $env:HF_HUB_DISABLE_TELEMETRY = '1'
    # cuBLASLt detects AVX-512 on this Ryzen but Windows exposes only AVX2.
    # NVIDIA's documented mask avoids an illegal CPU instruction in its GPU library.
    $env:CUBLASLT_DISABLE_CPU_INSTRUCTIONS_MASK = '1'
    $runtimeArgs = if ($ModelSize -eq 'MiniMaxH3') {
        @('-s', 'ComfyUI/main.py', '--windows-standalone-build', '--listen', '127.0.0.1', '--port', '8188', '--disable-auto-launch', '--offline', '--reserve-vram', '4', '--extra-model-paths-config', ('"' + $config + '"'))
    } else {
        @('-s', 'ComfyUI/main.py', '--windows-standalone-build', '--listen', '127.0.0.1', '--port', '8188', '--disable-auto-launch', '--offline', '--reserve-vram', '3', '--disable-dynamic-vram', '--disable-async-offload', '--fp32-vae', '--extra-model-paths-config', ('"' + $config + '"'))
    }
    $process = Start-Process -FilePath $python -ArgumentList $runtimeArgs -WorkingDirectory $PortableRoot `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logs 'backend.log') `
        -RedirectStandardError (Join-Path $logs 'backend-errors.log')
    $process.Id | Set-Content (Join-Path $AiRoot 'backend.pid')
    Write-Host 'Starting local inference on your GPU...'
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-LocalBackend) { return }
        if ($process.HasExited) { throw "Backend exited. See $logs/backend-errors.log" }
        Start-Sleep -Seconds 2
    }
    throw "Backend startup timed out. See $logs/backend-errors.log"
    }
    # Never switch runtimes under queued or running jobs. The tracked backend
    # must be stopped explicitly before choosing a CUDA-incompatible model.
    if ($TestBackend = Test-LocalBackend) {
        $listener = Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        $tracked = 0
        $pidFile = Join-Path $AiRoot 'backend.pid'
        if (!$listener -or !(Test-Path -LiteralPath $pidFile) -or ![int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$tracked) -or [int]$listener.OwningProcess -ne $tracked) {
            throw 'Port 8188 is used by an untracked ComfyUI process. Stop it manually; MangaColorAI will not interrupt it.'
        }
        $active = Get-CimInstance Win32_Process -Filter "ProcessId = $tracked"
        $expectedPython = [IO.Path]::GetFullPath($python)
        $expectedConfig = [IO.Path]::GetFullPath($config)
        if (!$active -or [IO.Path]::GetFullPath([string]$active.ExecutablePath) -ne $expectedPython -or [string]$active.CommandLine -notlike ('*' + $expectedConfig + '*')) {
            throw "The tracked backend runtime does not match $ModelSize. Finish jobs, run scripts/local-manga/Stop.ps1, then retry."
        }
        if ($ModelSize -eq 'MiniMaxH3') {
            if ([string]$active.CommandLine -match '--disable-dynamic-vram|--disable-async-offload' -or [string]$active.CommandLine -notmatch '--reserve-vram\s+4') {
                throw 'The tracked backend was not started with MiniMax H3 offload settings. Finish jobs, run scripts/local-manga/Stop.ps1, then retry.'
            }
        } elseif ([string]$active.CommandLine -notmatch '--disable-dynamic-vram' -or [string]$active.CommandLine -notmatch '--disable-async-offload' -or [string]$active.CommandLine -notmatch '--reserve-vram\s+3') {
            throw "The tracked backend flags do not match $ModelSize. Finish jobs, run scripts/local-manga/Stop.ps1, then retry."
        }
    }
}

function Invoke-MangaImage {
    param([Parameter(Mandatory=$true)][ValidateSet('info','convert','resize','crop')][string]$Operation,
        [Parameter(Mandatory=$true)][string]$InputPath,[string]$OutputPath,
        [int]$X=0,[int]$Y=0,[int]$Width=0,[int]$Height=0)
    if (!(Test-Path -LiteralPath $MangaImage)) { throw "MangaColorAI image helper not found at $MangaImage. Start with the Windows release ZIP or run Build MangaColorAI.cmd." }
    $imageArgs = @($Operation, $InputPath)
    if ($Operation -ne 'info') {
        if (!$OutputPath) { throw 'Image output path is required.' }
        $imageArgs += $OutputPath
    }
    if ($Operation -eq 'resize') { $imageArgs += @('--width', [string]$Width, '--height', [string]$Height) }
    if ($Operation -eq 'crop') { $imageArgs += @('--x', [string]$X, '--y', [string]$Y, '--width', [string]$Width, '--height', [string]$Height) }
    $quoted = @($imageArgs | ForEach-Object {
        $escaped = [regex]::Replace($_, '(\\*)"', '$1$1\"')
        '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
    })
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $MangaImage
    $start.Arguments = $quoted -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'Could not start the MangaColorAI image helper.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.Result
        $errors = $stderr.Result
        if ($process.ExitCode -ne 0) { throw "MangaColorAI image operation failed (exit $($process.ExitCode)): $errors" }
        return $output
    } finally { $process.Dispose() }
}

function Get-MangaImageInfo { param([string]$Path) (Invoke-MangaImage -Operation info -InputPath $Path | ConvertFrom-Json) }
function Convert-MangaImage { param([string]$Source,[string]$Destination) Invoke-MangaImage -Operation convert -InputPath $Source -OutputPath $Destination | Out-Null }
function Resize-MangaImage { param([string]$Source,[string]$Destination,[int]$Width,[int]$Height) Invoke-MangaImage -Operation resize -InputPath $Source -OutputPath $Destination -Width $Width -Height $Height | Out-Null }
function Crop-MangaImage { param([string]$Source,[string]$Destination,[int]$X,[int]$Y,[int]$Width,[int]$Height) Invoke-MangaImage -Operation crop -InputPath $Source -OutputPath $Destination -X $X -Y $Y -Width $Width -Height $Height | Out-Null }

function New-ColorizeGraph {
    param([string]$ImageName, [string]$Instruction, [long]$Seed = 42,
        [double]$Megapixels = 0.7, [string]$Prefix = 'MangaColorAI/colorized', [string]$TextMaskName,
        [string]$ReferenceImageName, [ValidateSet('Fast','Detailed','BaseExperimental')][string]$Quality = 'Fast',
        [ValidateRange(0.2,1.0)][double]$Strength = 1.0,
        [ValidateRange(0,1.5)][double]$Consistency = 0,
        [ValidateSet('Auto','FP8','BF16','INT8')][string]$Precision = 'FP8',
        [ValidateSet('4B','9B','Qwen21','Flux1Kontext','MiniMaxH3','IllustriousXL')][string]$ModelSize = '4B',
        [ValidateRange(0,50)][int]$SamplingSteps=0)
    if ($ModelSize -eq 'Qwen21') {
        if ($Precision -ne 'INT8' -or $Quality -eq 'BaseExperimental' -or $Consistency -gt 0) { throw 'Qwen Image 2.1 requires INT8, Fast or Detailed quality and no FLUX consistency adapter.' }
        $graph = Get-Content -LiteralPath (Join-Path $RepoRoot 'workflows/local-manga/qwen-image-2.1-api.json') -Raw | ConvertFrom-Json
        $graph.'4'.inputs.image = $ImageName
        $graph.'5'.inputs.prompt = $Instruction
        $graph.'5'.inputs.resolution = [Math]::Max(256, [int]([Math]::Round([Math]::Sqrt($Megapixels * 1000000) / 32) * 32))
        $graph.'6'.inputs.seed = $Seed
        $graph.'6'.inputs.steps = if ($SamplingSteps -gt 0) { $SamplingSteps } else { 25 }
        $graph.'6'.inputs.denoise = $Strength
        $graph.'8'.inputs.filename_prefix = $Prefix
        if ($ReferenceImageName) {
            $graph | Add-Member -MemberType NoteProperty -Name '30' -Value @{class_type='LoadImage';inputs=@{image=$ReferenceImageName}}
            $graph.'5'.inputs | Add-Member -MemberType NoteProperty -Name 'images.image_2' -Value @('30',0)
        }
        return $graph
    }
    if ($ModelSize -eq 'Flux1Kontext') {
        if ($Precision -ne 'FP8' -or $Quality -eq 'BaseExperimental' -or $Consistency -gt 0) { throw 'FLUX.1 Kontext requires FP8 and no FLUX.2 consistency adapter.' }
        $graph = Get-Content -LiteralPath (Join-Path $RepoRoot 'workflows/local-manga/flux1-kontext-api.json') -Raw | ConvertFrom-Json
        $graph.'1'.inputs.image = $ImageName
        $graph.'7'.inputs.text = $Instruction
        $graph.'11'.inputs.seed = $Seed
        $graph.'11'.inputs.steps = if ($SamplingSteps -gt 0) { $SamplingSteps } else { 20 }
        $graph.'11'.inputs.denoise = $Strength
        $graph.'13'.inputs.filename_prefix = $Prefix
        if ($ReferenceImageName) {
            $nodes = @{
                '30' = @{class_type='LoadImage';inputs=@{image=$ReferenceImageName}}
                '31' = @{class_type='FluxKontextImageScale';inputs=@{image=@('30',0)}}
                '32' = @{class_type='VAEEncode';inputs=@{pixels=@('31',0);vae=@('5',0)}}
                '33' = @{class_type='ReferenceLatent';inputs=@{conditioning=@('8',0);latent=@('32',0)}}
            }
            foreach ($key in $nodes.Keys) { $graph | Add-Member -MemberType NoteProperty -Name $key -Value $nodes[$key] }
            $graph.'9'.inputs.conditioning = @('33',0)
        }
        return $graph
    }
    if ($ModelSize -eq 'MiniMaxH3') {
        if ($Precision -ne 'INT8' -or $Quality -eq 'BaseExperimental' -or $Consistency -gt 0 -or $Strength -ne 1.0) { throw 'MiniMax H3 Image requires INT8, strength 1.0 and no FLUX consistency adapter.' }
        $graph = Get-Content -LiteralPath (Join-Path $RepoRoot 'workflows/local-manga/minimax-h3-image-api.json') -Raw | ConvertFrom-Json
        $graph.'1'.inputs.image = $ImageName
        $graph.'2'.inputs.megapixels = $Megapixels
        $graph.'7'.inputs.prompt = $Instruction
        $graph.'9'.inputs.seed = $Seed
        $graph.'9'.inputs.steps = if ($SamplingSteps -gt 0) { $SamplingSteps } else { 6 }
        $graph.'11'.inputs.filename_prefix = $Prefix
        if ($ReferenceImageName) {
            $graph | Add-Member -MemberType NoteProperty -Name '30' -Value @{class_type='LoadImage';inputs=@{image=$ReferenceImageName}}
            $graph.'7'.inputs | Add-Member -MemberType NoteProperty -Name 'images.image_2' -Value @('30',0)
        }
        return $graph
    }
    if ($ModelSize -eq 'IllustriousXL') {
        if ($Consistency -gt 0 -or $Quality -eq 'BaseExperimental') { throw 'Illustrious XL uses its standalone SDXL img2img workflow; FLUX consistency and BaseExperimental are unavailable.' }
        if ($ReferenceImageName) { throw 'Illustrious XL img2img does not use a separate reference image in this release. Remove -ReferenceImagePath or choose another model.' }
        $graph = Get-Content -LiteralPath (Join-Path $RepoRoot 'workflows/local-manga/illustrious-xl-img2img-api.json') -Raw | ConvertFrom-Json
        $graph.'1'.inputs.image = $ImageName
        $graph.'2'.inputs.ckpt_name = 'Illustrious-XL-v2.0.safetensors'
        $graph.'3'.inputs.text = $Instruction
        $graph.'4'.inputs.text = 'text, lettering, duplicated words, altered glyphs, extra objects, changed face, changed eyes, changed pose, changed clothing boundaries, blurry, low quality'
        $graph.'6'.inputs.seed = $Seed
        $graph.'6'.inputs.steps = if ($SamplingSteps -gt 0) { $SamplingSteps } else { 20 }
        $graph.'6'.inputs.denoise = $Strength
        $graph.'8'.inputs.filename_prefix = $Prefix
        return $graph
    }
    if ($ModelSize -eq '9B' -and ($Precision -ne 'FP8' -or $Consistency -gt 0 -or $Quality -ne 'Fast')) {
        throw '9B currently supports FP8, Fast quality and no 4B consistency adapter.'
    }
    $path = Join-Path $RepoRoot 'workflows/local-manga/klein-4b-api.json'
    $graph = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $graph.'1'.inputs.image = $ImageName
    $graph.'5'.inputs.text = $Instruction
    $graph.'2'.inputs.megapixels = $Megapixels
    $graph.'14'.inputs.noise_seed = $Seed
    $graph.'19'.inputs.filename_prefix = $Prefix
    if ($Precision -eq 'BF16') { $graph.'3'.inputs.unet_name = 'flux-2-klein-4b.safetensors' }
    if ($ModelSize -eq '9B') {
        $graph.'3'.inputs.unet_name = 'flux-2-klein-9b-fp8.safetensors'
        $graph.'4'.inputs.clip_name = 'qwen_3_8b_fp8mixed.safetensors'
    }
    $steps = 4
    if ($Quality -eq 'BaseExperimental') {
        $steps = 50
        $graph.'3'.inputs.unet_name = 'flux-2-klein-base-4b-fp8.safetensors'
        $graph.'13'.inputs.cfg = 4.0
    }
    if($SamplingSteps -gt 0){$steps=$SamplingSteps}
    $graph.'16'.inputs.steps = $steps
    if ($Consistency -gt 0) {
        $adapter = @{class_type='LoraLoaderModelOnly'; inputs=@{model=@('3',0);
            lora_name='f2k_4B_consist_20260314.safetensors'; strength_model=$Consistency}}
        $graph | Add-Member -MemberType NoteProperty -Name '41' -Value $adapter
        $graph.'13'.inputs.model = @('41',0)
    }
    if ($Strength -lt 1.0) {
        $skip = [int][Math]::Floor($steps * (1.0 - $Strength))
        $split = @{class_type='SplitSigmas'; inputs=@{sigmas=@('16',0); step=$skip}}
        $graph | Add-Member -MemberType NoteProperty -Name '40' -Value $split
        $graph.'17'.inputs.sigmas = @('40',1)
        $graph.'17'.inputs.latent_image = @('7',0)
    }
    if ($ReferenceImageName) {
        $referenceNodes = @{
            '30' = @{class_type='LoadImage'; inputs=@{image=$ReferenceImageName}}
            '31' = @{class_type='ImageScaleToTotalPixels'; inputs=@{image=@('30',0); upscale_method='lanczos'; megapixels=0.4; resolution_steps=32}}
            '32' = @{class_type='VAEEncode'; inputs=@{pixels=@('31',0); vae=@('6',0)}}
            '33' = @{class_type='ReferenceLatent'; inputs=@{conditioning=@('9',0); latent=@('32',0)}}
            '34' = @{class_type='ReferenceLatent'; inputs=@{conditioning=@('10',0); latent=@('32',0)}}
        }
        foreach ($key in $referenceNodes.Keys) { $graph | Add-Member -MemberType NoteProperty -Name $key -Value $referenceNodes[$key] }
        $graph.'13'.inputs.positive = @('33',0)
        $graph.'13'.inputs.negative = @('34',0)
    }
    if ($TextMaskName) {
        # White mask regions are copied from the source after generation. This
        # preserves their pixels at working resolution rather than trusting a prompt.
        $extra = @{
            '20' = @{class_type='LoadImage'; inputs=@{image=$TextMaskName}}
            '21' = @{class_type='ImageScale'; inputs=@{image=@('20',0); upscale_method='nearest-exact'; width=@('11',0); height=@('11',1); crop='disabled'}}
            '22' = @{class_type='ImageToMask'; inputs=@{image=@('21',0); channel='red'}}
            '23' = @{class_type='ImageCompositeMasked'; inputs=@{destination=@('18',0); source=@('2',0); x=0; y=0; resize_source=$false; mask=@('22',0)}}
        }
        foreach ($key in $extra.Keys) { $graph | Add-Member -MemberType NoteProperty -Name $key -Value $extra[$key] }
        $graph.'19'.inputs.images = @('23',0)
    }
    return $graph
}
