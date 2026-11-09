[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$InputPath,
    [string]$Palette,
    [string]$StyleFile,
    [ValidateRange(0, 2147483647)][long]$Seed = 42,
    [ValidateRange(0.1, 4.0)][double]$Megapixels = 0.7,
    [ValidateRange(0,50)][int]$Steps=0,
    [ValidateSet('Fast','Detailed','BaseExperimental')][string]$Quality = 'Fast',
    [ValidateRange(0.2,1.0)][double]$Strength = 1.0,
    [ValidateRange(0,1.5)][double]$Consistency = 0,
    [ValidateSet('Auto','FP8','BF16')][string]$Precision = 'Auto',
    [ValidateSet('Preserve','Short','Minimal')][string]$PromptStyle = 'Preserve',
    [string]$OutputDirectory,
    [Alias('ProtectMaskPath')][string]$TextMaskPath,
    [ValidateSet('Original','Working')][string]$MaskSpace = 'Original',
    [int[]]$MaskPadding = @(0,0,0,0),
    [ValidateSet('Hard','Soft')][string]$MaskMode = 'Hard',
    [switch]$DebugOutput,
    [string]$ProtectionRegionsPath,
    [ValidateSet('Off','Report','Repair')][string]$CoverageMode = 'Report',
    [string]$ColorRegionsPath,
    [ValidateRange(32,192)][int]$CoverageMaxSide = 96,
    [ValidateRange(1,3)][int]$MaxRepairRegions = 1,
    [string]$PaletteFile,
    [object]$PaletteData,
    [ValidateSet('4B','9B')][string]$ModelSize = '4B',
    [string]$ReferenceImagePath,
    [switch]$NoOpen,
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
)
. "$PSScriptRoot/Common.ps1"
$totalWatch=[Diagnostics.Stopwatch]::StartNew()
if($StyleFile){
    if($PSBoundParameters.ContainsKey('Palette')){throw 'Choose -StyleFile or -Palette, not both.'}
    $Palette=Read-MangaStyleFile -Path $StyleFile
    Write-Host ('Color style file: '+[IO.Path]::GetFullPath($StyleFile))
}elseif (!$PSBoundParameters.ContainsKey('Palette')) { $Palette = Read-DefaultMangaStyle -Root $RepoRoot }
if ($ModelSize -eq '9B') {
    if ($Quality -ne 'Fast' -or $Consistency -gt 0 -or $Precision -eq 'BF16') { throw 'Use 9B with Fast quality, FP8 precision and no 4B consistency adapter.' }
    foreach ($required in @('diffusion_models/flux-2-klein-9b-fp8.safetensors','text_encoders/qwen_3_8b_fp8mixed.safetensors')) {
        if (!(Test-Path -LiteralPath (Join-Path $AiRoot ('models/'+$required)))) { throw "Missing 9B component: $required" }
    }
}
if ($Quality -eq 'BaseExperimental') {
    $qualityModel = Join-Path $AiRoot 'models/diffusion_models/flux-2-klein-base-4b-fp8.safetensors'
    if (!(Test-Path $qualityModel) -or (Get-Item $qualityModel).Length -ne 4089498488) {
        throw 'BaseExperimental mode needs the Base 4B model. Run scripts/local-manga/Setup.ps1 -IncludeQuality once.'
    }
    if (!$PSBoundParameters.ContainsKey('Megapixels')) { $Megapixels = 1.5 }
}
if ($Quality -eq 'Detailed') {
    if (!$PSBoundParameters.ContainsKey('Megapixels')) { $Megapixels=1.5 }
    if (!$PSBoundParameters.ContainsKey('PromptStyle')) { $PromptStyle='Minimal' }
    if (!$PSBoundParameters.ContainsKey('Consistency') -and (Test-Path (Join-Path $AiRoot 'models/loras/f2k_4B_consist_20260314.safetensors'))) { $Consistency=0.4 }
}
$fullModel = Join-Path $AiRoot 'models/diffusion_models/flux-2-klein-4b.safetensors'
if ($Precision -eq 'Auto') {
    $Precision = if ($Quality -eq 'Detailed' -and (Test-Path $fullModel)) { 'BF16' } else { 'FP8' }
}
if ($Precision -eq 'BF16') {
    if ($Quality -eq 'BaseExperimental') { throw 'BF16 precision is supported for the distilled checkpoint, not the optional Base experiment.' }
    if (!(Test-Path $fullModel) -or (Get-Item $fullModel).Length -ne 7751105712) { throw 'Install the full flux-2-klein-4b.safetensors checkpoint first.' }
}
if ($Consistency -gt 0) {
    $adapter = Join-Path $AiRoot 'models/loras/f2k_4B_consist_20260314.safetensors'
    if (!(Test-Path $adapter) -or (Get-Item $adapter).Length -ne 385379872) {
        throw 'Consistency mode needs its adapter. Run scripts/local-manga/Setup.ps1 -IncludeConsistency once.'
    }
}
if ([string]::IsNullOrWhiteSpace($InputPath)) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose a non-explicit manga image to colorize'
    $dialog.Filter = 'Images|*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.tif;*.tiff|All files|*.*'
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return }
        $InputPath = $dialog.FileName
    } finally { $dialog.Dispose() }
}
$paletteProfile = $null
if ($PaletteFile) {
    $paletteProfile = Read-ChapterPalette -Path $PaletteFile
    $Palette += "`n" + $(if ($PromptStyle -eq 'Preserve') { $paletteProfile.Instruction } else { $paletteProfile.CompactInstruction })
    if (!$ReferenceImagePath) { $ReferenceImagePath = $paletteProfile.Reference }
}
$source = Get-Item -LiteralPath $InputPath
if ($source.PSIsContainer) { throw 'Choose an image file. Use Batch.ps1 for a folder.' }
if ($source.Length -gt 512MB) { throw 'Input exceeds 512 MB. Export a smaller page or panel first.' }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $RepoRoot 'manga-output' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $outputRoot | Out-Null
Start-LocalBackend
$id = [Guid]::NewGuid().ToString('N')
$inputName = "mangacolorai-$id.png"
$inputFile = Join-Path $ComfyRoot "input/$inputName"
$sourceInfo=Get-MangaImageInfo -Path $source.FullName
$sourceWidth=[int]$sourceInfo.width;$sourceHeight=[int]$sourceInfo.height
$sourcePixels = [long]$sourceWidth * $sourceHeight
if(!$TextMaskPath -and !$ProtectionRegionsPath){
    $textCandidate=Join-Path $source.DirectoryName ($source.BaseName+'.text-mask.png')
    $protectCandidate=Join-Path $source.DirectoryName ($source.BaseName+'.protect-mask.png')
    $regionsCandidate=Join-Path $source.DirectoryName ($source.BaseName+'.protection.json')
    $found=@(@($textCandidate,$protectCandidate,$regionsCandidate) | Where-Object {Test-Path -LiteralPath $_})
    if($found.Count -gt 1){throw 'Found multiple protection sidecars. Keep one combined mask or select one explicitly.'}
    if($found.Count -eq 1){
        if($found[0] -eq $regionsCandidate){$ProtectionRegionsPath=$found[0]}else{$TextMaskPath=$found[0]}
        Write-Host ('Using original-resolution protection: '+$found[0])
    }
}
if (!$ColorRegionsPath) {
    $candidate=Join-Path $source.DirectoryName ($source.BaseName+'.color-regions.json')
    if (Test-Path -LiteralPath $candidate) { $ColorRegionsPath=$candidate }
}
if ($paletteProfile) { $PaletteData=$paletteProfile.Data }
$colorRegions=@(Read-ColorRegions -Path $ColorRegionsPath -Width $sourceWidth -Height $sourceHeight -PaletteData $PaletteData)
if ($sourcePixels -gt 256000000) { throw 'Input exceeds 256 megapixels. Export a smaller page or panel first.' }
if ($ProtectionRegionsPath) {
    if ($TextMaskPath) { throw 'Supply a protection mask OR a regions JSON, not both.' }
    $TextMaskPath=Join-Path $ComfyRoot "input/mangacolorai-$id-regions-mask.png"
    New-RegionProtectionMask -Path $ProtectionRegionsPath -Width $sourceWidth -Height $sourceHeight -Destination $TextMaskPath
}
if ($TextMaskPath) {
    $maskFile = Get-Item -LiteralPath $TextMaskPath
    if ($maskFile.Length -gt 512MB) { throw 'Text mask exceeds 512 MB.' }
    $maskHeader = [Drawing.Image]::FromFile($maskFile.FullName)
    try {
        if ($MaskSpace -eq 'Original' -and ($maskHeader.Width -ne $sourceWidth -or $maskHeader.Height -ne $sourceHeight -or @($MaskPadding | Where-Object { $_ -ne 0 }).Count)) {
            throw 'The text mask must have the same width and height as the source image.'
        }
        $null=Get-MaskGeometry -Width $maskHeader.Width -Height $maskHeader.Height -Padding $MaskPadding
    } finally { $maskHeader.Dispose() }
    # Keep the supplied mask in its own coordinates; restoration runs after resize.
}
if ($sourcePixels -gt 16000000) {
    $scale = [Math]::Sqrt($Megapixels * 1000000 / $sourcePixels)
    $width = [Math]::Max(64, [int]([Math]::Round($sourceWidth * $scale / 32) * 32))
    $height = [Math]::Max(64, [int]([Math]::Round($sourceHeight * $scale / 32) * 32))
    Resize-MangaImage -Source $source.FullName -Destination $inputFile -Width $width -Height $height
    Write-Host "Preparing a $width x $height working copy of this large scan; the full original stays untouched."
} else {
    Convert-MangaImage -Source $source.FullName -Destination $inputFile
}
$referenceName = $null
if ($ReferenceImagePath) {
    $referenceFile = Get-Item -LiteralPath $ReferenceImagePath
    if ($referenceFile.PSIsContainer -or $referenceFile.Length -gt 512MB) { throw 'Reference must be an image file under 512 MB.' }
    $referenceName = "mangacolorai-$id-reference.png"
    Convert-MangaImage -Source $referenceFile.FullName -Destination (Join-Path $ComfyRoot "input/$referenceName")
}
$instruction = 'Colorize this black-and-white manga image. Preserve the original composition, panel borders, black ink lines, faces, poses, clothing, and all lettering. Keep speech bubbles and page margins white. Keep all text black, unchanged and legible, including dialogue, captions and sound effects. Do not translate, replace, add or remove any text. Add clean, consistent anime-style colors and subtle cel shading. Do not add, remove, or redraw objects. ' + $Palette
$instruction += ' Preserve each eye exactly: closed eyes stay closed, open eyes stay open, and gaze direction, eyelids, pupils, iris size, catchlights and facial expression stay unchanged. Both irises of the same character must use the same base eye color unless the source explicitly specifies otherwise. Avoid multicolored or rainbow irises. Match each character across all panels. Keep blank areas blank: no invented speech bubbles, captions, lettering, bystanders or objects. Color only; do not redesign the artwork.'
if ($PromptStyle -eq 'Short') {
    $instruction = 'Add natural colors to this manga page. Keep the original drawing, faces, eye shapes and expressions, composition and lettering unchanged. Keep closed eyes closed and both irises the same base color. White speech bubbles and empty margins stay white. ' + $Palette
}
if ($PromptStyle -eq 'Minimal') {
    $instruction = 'Colorize this manga illustration. Keep its original drawing, facial expressions and existing lettering unchanged. ' + $Palette
}
if ($referenceName) {
    $instruction = 'Image 1 is the manga page to colorize. Image 2 is a COLOR REFERENCE ONLY: match corresponding hair, eyes, clothes and materials in image 1 to image 2. Keep the composition and all panels of image 1. Do not copy the layout or objects from image 2. ' + $instruction
}
$graph = New-ColorizeGraph -ImageName $inputName -Instruction $instruction -Seed $Seed `
    -Megapixels $Megapixels -Prefix "MangaColorAI/$id" -ReferenceImageName $referenceName `
    -Quality $Quality -Strength $Strength -Consistency $Consistency -Precision $Precision -ModelSize $ModelSize -SamplingSteps $Steps
if ($DebugOutput) {
    $graph | Add-Member -MemberType NoteProperty -Name '90' -Value @{class_type='SaveImage';inputs=@{images=@('2',0);filename_prefix="MangaColorAI/$id-input"}}
}
Write-Host "Source $sourceWidth x $sourceHeight; model $ModelSize $Precision; steps $($graph.'16'.inputs.steps); CFG $($graph.'13'.inputs.cfg); seed $Seed; strength $Strength; working target $Megapixels MP; inference padding 0,0,0,0."
$body = @{ prompt = $graph; client_id = "mangacolorai-$id" } | ConvertTo-Json -Depth 30
$queued = Invoke-RestMethod "$Api/prompt" -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body))
$promptId = $queued.prompt_id
Write-Host "Colorizing $($source.Name) locally. First run loads the model and takes longer..."
$watch = [Diagnostics.Stopwatch]::StartNew()
$result = $null
while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    try { $history = Invoke-RestMethod "$Api/history/$promptId" -TimeoutSec 10 }
    catch { throw "Lost contact with local inference job $promptId. Check .local-ai/logs/backend-errors.log. Details: $_" }
    $entry = $history.PSObject.Properties[$promptId]
    if ($null -ne $entry) {
        $result = $entry.Value
        if ($result.status.status_str -eq 'error') {
            throw ('Inference failed: ' + ($result.status.messages | ConvertTo-Json -Depth 15 -Compress))
        }
        if ($result.status.completed) { break }
    }
    Start-Sleep -Seconds 2
}
if ($null -eq $result -or !$result.status.completed) {
    # Do not interrupt a potentially unrelated job. This request remains in backend history.
    throw "Timed out waiting for job $promptId. Check $Api/history/$promptId before retrying."
}
$image = $result.outputs.'19'.images[0]
$stem = $source.BaseName + '-' + $id.Substring(0, 8)
$png = Join-Path $outputRoot "$stem-color.png"
$query = 'filename=' + [Uri]::EscapeDataString($image.filename) + '&subfolder=' +
    [Uri]::EscapeDataString($image.subfolder) + '&type=output'
$workingOutput = Join-Path $outputRoot "$stem-working.png"
Save-LocalImage -Uri "$Api/view?$query" -Destination $workingOutput
$debugDirectory=$null
if ($DebugOutput) {
    $debugDirectory=Join-Path $outputRoot "$stem-debug"
    New-Item -ItemType Directory -Path $debugDirectory | Out-Null
    Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $debugDirectory ('original'+$source.Extension))
    Copy-Item -LiteralPath $workingOutput -Destination (Join-Path $debugDirectory 'raw-generated.png')
    Save-GraphImage -Result $result -Node '90' -Destination (Join-Path $debugDirectory 'model-input.png')
}
$workingHeader = [Drawing.Image]::FromFile($workingOutput)
try {
    $workingWidth = $workingHeader.Width
    $workingHeight = $workingHeader.Height
} finally { $workingHeader.Dispose() }
$coverageWatch=[Diagnostics.Stopwatch]::StartNew()
$coverageReportPath=$null;$coverageReport=$null;$repairResult=@{attempted=0;repaired=0;regions=@()}
if ($CoverageMode -ne 'Off') {
    $analysisSize=Get-CoverageAnalysisSize -Width $sourceWidth -Height $sourceHeight -MaxSide $CoverageMaxSide
    $gridWidth=$analysisSize.width;$gridHeight=$analysisSize.height
    $sourceGrid=Get-ImageLabGrid -Path $inputFile -GridWidth $gridWidth -GridHeight $gridHeight
    $rawGrid=Get-ImageLabGrid -Path $workingOutput -GridWidth $gridWidth -GridHeight $gridHeight
}
if ($workingWidth -ne $sourceWidth -or $workingHeight -ne $sourceHeight) {
    Write-Host "Saving at original dimensions: $sourceWidth x $sourceHeight (AI working size: $workingWidth x $workingHeight)."
    Resize-MangaImage -Source $workingOutput -Destination $png -Width $sourceWidth -Height $sourceHeight
    $savedHeader = [Drawing.Image]::FromFile($png)
    try {
        if ($savedHeader.Width -ne $sourceWidth -or $savedHeader.Height -ne $sourceHeight) {
            throw 'Output dimensions do not match the original image. The working output was retained.'
        }
    } finally { $savedHeader.Dispose() }
    Remove-Item -LiteralPath $workingOutput
} else {
    Move-Item -LiteralPath $workingOutput -Destination $png
}
if ($CoverageMode -ne 'Off') {
    $beforeGrid=Get-ImageLabGrid -Path $png -GridWidth $gridWidth -GridHeight $gridHeight
    if ($CoverageMode -eq 'Repair') {
        $beforeReport=Measure-ColorCoverage -Original $sourceGrid -Raw $rawGrid -Before $beforeGrid -Final $beforeGrid `
            -Regions $colorRegions -ProtectionMask $TextMaskPath -MaskPadding $MaskPadding -ProtectionMaskMode $MaskMode -Width $sourceWidth -Height $sourceHeight
        $repairOptions=@{ModelSize=$ModelSize;Precision=$Precision;Quality=$Quality;Strength=$Strength;Consistency=$Consistency;
            Megapixels=$Megapixels;Seed=$Seed;Steps=$graph.'16'.inputs.steps;PromptStyle=$PromptStyle;Palette=$Palette;CoverageMode='Off';NoOpen=$true}
        $repairResult=Invoke-ColorRegionRepairs -SourcePath $source.FullName -ColorPath $png -Regions $colorRegions -Report $beforeReport `
            -ProtectionMask $TextMaskPath -MaskPadding $MaskPadding -Width $sourceWidth -Height $sourceHeight `
            -ModelOptions $repairOptions -MaxRegions $MaxRepairRegions -WorkDirectory (Join-Path $AiRoot "repairs/$id") -CurrentGrid $beforeGrid -MaskMode $MaskMode
    }
}
$restoration=@{status='no mask supplied';coordinate_space='original'}
if($DebugOutput){Copy-Item -LiteralPath $png -Destination (Join-Path $debugDirectory 'before-text-restoration.png')}
if ($TextMaskPath) {
    $restoration=Restore-OriginalRegions -SourcePath $source.FullName -ColorPath $png -MaskPath $maskFile.FullName `
        -Width $sourceWidth -Height $sourceHeight -Padding $MaskPadding -MaskMode $MaskMode -DebugDirectory $debugDirectory -TimeoutSeconds $TimeoutSeconds
}
if ($DebugOutput) { Copy-Item -LiteralPath $png -Destination (Join-Path $debugDirectory 'final-restored.png') }
if ($CoverageMode -ne 'Off') {
    $finalGrid=Get-ImageLabGrid -Path $png -GridWidth $gridWidth -GridHeight $gridHeight
    $coverageReport=Measure-ColorCoverage -Original $sourceGrid -Raw $rawGrid -Before $beforeGrid -Final $finalGrid `
        -Regions $colorRegions -ProtectionMask $TextMaskPath -MaskPadding $MaskPadding -ProtectionMaskMode $MaskMode -Width $sourceWidth -Height $sourceHeight -DebugDirectory $debugDirectory
    $coverageReport.repaired=$repairResult.repaired
    $coverageReport.skipped=@($colorRegions).Count-$repairResult.attempted
    $coverageReport | Add-Member -MemberType NoteProperty -Name repair -Value $repairResult
    $coverageReport | Add-Member -MemberType NoteProperty -Name output_dimensions -Value @($sourceWidth,$sourceHeight)
    $coverageReport | Add-Member -MemberType NoteProperty -Name processing_seconds -Value ([Math]::Round($totalWatch.Elapsed.TotalSeconds,3))
    $coverageReport | Add-Member -MemberType NoteProperty -Name coverage_stage_seconds -Value ([Math]::Round($coverageWatch.Elapsed.TotalSeconds,3))
    $coverageReportPath=Join-Path $outputRoot "$stem-coverage.json"
    $coverageReport | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $coverageReportPath -Encoding UTF8
    Write-Host "Coverage: $($coverageReport.components.Count) review candidates; $($repairResult.repaired) accepted repairs. Report: $coverageReportPath"
    if ($coverageReport.neutral_samples_restored_by_protection -gt 0) { Write-Warning 'A protection mask restored gray pixels inside declared color-eligible artwork. Review mask overlap; protected text was not overridden.' }
}
$modelLabel = if ($Quality -eq 'BaseExperimental') { 'FLUX.2 klein Base 4B FP8' } else { "FLUX.2 klein $ModelSize $Precision" }
$metadata = @{ source = $source.FullName; model = $modelLabel; quality = $Quality; strength=$Strength;
    consistency=$Consistency; precision=$Precision; prompt_style=$PromptStyle; seed = $Seed;
    megapixels = $Megapixels; palette = $Palette; palette_file = $PaletteFile; reference_image = $ReferenceImagePath;
    text_mask = $TextMaskPath; prompt = $instruction; prompt_id = $promptId;
    source_width = $sourceWidth; source_height = $sourceHeight;
    output_width = $sourceWidth; output_height = $sourceHeight;
    working_width = $workingWidth; working_height = $workingHeight;
    output_resized = ($workingWidth -ne $sourceWidth -or $workingHeight -ne $sourceHeight);
    steps=$graph.'16'.inputs.steps;guidance=$graph.'13'.inputs.cfg;sampler=$graph.'15'.inputs.sampler_name;scheduler='Flux2Scheduler';
    restoration=$restoration; mask_space=$MaskSpace; debug_directory=$debugDirectory;
    protection_regions=$ProtectionRegionsPath;
    color_regions=$ColorRegionsPath;coverage_mode=$CoverageMode;coverage_report=$coverageReportPath;
    style_file=$StyleFile;
    scale_x=($workingWidth/[double]$sourceWidth);scale_y=($workingHeight/[double]$sourceHeight);padding=@(0,0,0,0);
    elapsed_seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 2); image = $png }
$metadata.total_seconds=[Math]::Round($totalWatch.Elapsed.TotalSeconds,3)
if($coverageReport){$coverageReport.processing_seconds=$metadata.total_seconds;$coverageReport | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $coverageReportPath -Encoding UTF8}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot "$stem.json") -Encoding UTF8
Write-Host "Saved $png"
if (!$NoOpen) {
    Start-Process -FilePath $png -WorkingDirectory $outputRoot | Out-Null
}
[pscustomobject]$metadata
