[CmdletBinding()]
param([string]$MetadataPath,[string]$ColorRegionsPath,[string]$PaletteFile,[string]$OutputDirectory,
    [switch]$Repair,[ValidateRange(1,3)][int]$MaxRepairRegions=1)
. "$PSScriptRoot/Common.ps1"
Add-Type -AssemblyName System.Drawing
if(!$MetadataPath){
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=New-Object Windows.Forms.OpenFileDialog
    $dialog.Title='Choose the result JSON beside the colored PNG (not a coverage report)';$dialog.Filter='Result metadata|*.json'
    try{if($dialog.ShowDialog() -ne 'OK'){return};$MetadataPath=$dialog.FileName}finally{$dialog.Dispose()}
}
$metadata=Get-Item -LiteralPath $MetadataPath
if($metadata.Length -gt 512KB){throw 'Result metadata exceeds 512 KB.'}
$m=Get-Content -LiteralPath $metadata.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($key in @('source','image','model','palette','precision','quality','strength','consistency','megapixels','seed','prompt_style')){
    if($null -eq $m.PSObject.Properties[$key]){throw 'Choose the original per-image result metadata JSON.'}
}
if(!(Test-Path -LiteralPath $m.source) -or !(Test-Path -LiteralPath $m.image)){throw 'Original source or colored result moved; correct their paths in the selected metadata.'}
if($m.model -notmatch '^FLUX\.2 klein (4B|9B) (FP8|BF16)$'){throw 'This repair command supports the three distilled Klein configurations.'}
$size=$Matches[1]
if($m.quality -eq 'BaseExperimental'){throw 'This command preserves the four-step distilled workflow.'}
if(!$ColorRegionsPath){$ColorRegionsPath=Join-Path (Split-Path -Parent $m.source) (([IO.Path]::GetFileNameWithoutExtension($m.source))+'.color-regions.json')}
if(!(Test-Path -LiteralPath $ColorRegionsPath)){throw 'Supply -ColorRegionsPath with manually selected color-eligible regions. Existing good images are not regenerated.'}
$width=[int]$m.source_width;$height=[int]$m.source_height
if($width -le 0 -or $height -le 0 -or ([long]$width*$height) -gt 256000000){throw 'Invalid original dimensions in metadata.'}
$palette=$m.palette;$paletteData=$null
if($PaletteFile){$profile=Read-ChapterPalette -Path $PaletteFile;$palette=(Read-DefaultMangaStyle -Root $RepoRoot)+"`n"+$profile.Instruction;$paletteData=$profile.Data}
elseif($null -ne $m.PSObject.Properties['palette_file'] -and $m.palette_file -and (Test-Path -LiteralPath $m.palette_file)){$paletteData=(Read-ChapterPalette -Path $m.palette_file).Data}
$regions=@(Read-ColorRegions -Path $ColorRegionsPath -Width $width -Height $height -PaletteData $paletteData)
$id=[Guid]::NewGuid().ToString('N')
if(!$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('manga-output/selected-repair-'+$id.Substring(0,8))}
$root=[IO.Path]::GetFullPath($OutputDirectory);New-Item -ItemType Directory -Path $root -Force | Out-Null
$sourceHash=(Get-MangaFileHash -LiteralPath $m.source).Hash;$colorHash=(Get-MangaFileHash -LiteralPath $m.image).Hash
$color=Join-Path $root ($id+'-repaired.png')
$header=[Drawing.Image]::FromFile($m.image)
try{$matchesSize=$header.Width -eq $width -and $header.Height -eq $height}finally{$header.Dispose()}
if($matchesSize){Copy-Item -LiteralPath $m.image -Destination $color}else{
    Resize-MangaImage -Source $m.image -Destination $color -Width $width -Height $height
}
$watch=[Diagnostics.Stopwatch]::StartNew()
$ratio=96.0/[Math]::Max($width,$height);$gw=[Math]::Max(1,[int][Math]::Round($width*$ratio));$gh=[Math]::Max(1,[int][Math]::Round($height*$ratio))
# Normalize only a small analysis copy through the existing native color pipeline.
$analysisSource=Join-Path $root 'original-analysis.png'
Resize-MangaImage -Source $m.source -Destination $analysisSource -Width $gw -Height $gh
$original=Get-ImageLabGrid -Path $analysisSource -GridWidth $gw -GridHeight $gh
$before=Get-ImageLabGrid -Path $color -GridWidth $gw -GridHeight $gh
$raw=$before;$rawAvailable=$false
if($null -ne $m.PSObject.Properties['debug_directory'] -and $m.debug_directory){
    $rawPath=Join-Path $m.debug_directory 'raw-generated.png'
    if(Test-Path -LiteralPath $rawPath){$raw=Get-ImageLabGrid -Path $rawPath -GridWidth $gw -GridHeight $gh;$rawAvailable=$true}
}
$protection=$null
if($m.text_mask){if(!(Test-Path -LiteralPath $m.text_mask)){throw 'The saved protection mask moved; restore it before repairing.'};$protection=$m.text_mask}
$padding=@(0,0,0,0);$maskMode='Hard'
if($null -ne $m.PSObject.Properties['restoration'] -and $null -ne $m.restoration.PSObject.Properties['mode'] -and $m.restoration.mode -eq 'Soft'){$maskMode='Soft'}
if($null -ne $m.PSObject.Properties['restoration'] -and $null -ne $m.restoration.PSObject.Properties['padding']){$padding=@($m.restoration.padding)}
$report=Measure-ColorCoverage -Original $original -Raw $raw -Before $before -Final $before -Regions $regions -ProtectionMask $protection -MaskPadding $padding -ProtectionMaskMode $maskMode -Width $width -Height $height
$repairResult=@{attempted=0;repaired=0;regions=@();method='report only'}
if($Repair){
    # This branch is the only part that queues a diffusion job. Report mode is CPU-only.
    Start-LocalBackend
    $opts=@{ModelSize=$size;Precision=$m.precision;Quality=$m.quality;Strength=$m.strength;Consistency=$m.consistency;Megapixels=$m.megapixels;
        Seed=$m.seed;PromptStyle=$m.prompt_style;Palette=$palette;CoverageMode='Off';NoOpen=$true}
    $repairResult=Invoke-ColorRegionRepairs -SourcePath $m.source -ColorPath $color -Regions $regions -Report $report -ProtectionMask $protection -MaskPadding $padding `
        -Width $width -Height $height -ModelOptions $opts -MaxRegions $MaxRepairRegions -WorkDirectory (Join-Path $root 'repair-work') -CurrentGrid $before -MaskMode $maskMode
    if($protection -and $repairResult.repaired -gt 0){$null=Restore-OriginalRegions -SourcePath $m.source -ColorPath $color -MaskPath $protection -Width $width -Height $height -Padding $padding -MaskMode $maskMode}
}
$final=Get-ImageLabGrid -Path $color -GridWidth $gw -GridHeight $gh
$report=Measure-ColorCoverage -Original $original -Raw $raw -Before $before -Final $final -Regions $regions -ProtectionMask $protection -MaskPadding $padding -ProtectionMaskMode $maskMode -Width $width -Height $height -DebugDirectory $root
$report.repaired=$repairResult.repaired;$report | Add-Member -MemberType NoteProperty -Name repair -Value $repairResult
$report | Add-Member -MemberType NoteProperty -Name raw_available -Value $rawAvailable
$report | Add-Member -MemberType NoteProperty -Name processing_seconds -Value ([Math]::Round($watch.Elapsed.TotalSeconds,3))
$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $root 'coverage-report.json') -Encoding UTF8
if((Get-MangaFileHash -LiteralPath $m.source).Hash -ne $sourceHash -or (Get-MangaFileHash -LiteralPath $m.image).Hash -ne $colorHash){throw 'An original input changed.'}
Write-Host "Selected image processed; existing source and colored result unchanged. Accepted repairs: $($repairResult.repaired). Output: $root"
[pscustomobject]@{image=$color;report=(Join-Path $root 'coverage-report.json');repaired=$repairResult.repaired}
