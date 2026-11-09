[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][int]$X,
    [Parameter(Mandatory=$true)][int]$Y,
    [Parameter(Mandatory=$true)][int]$Width,
    [Parameter(Mandatory=$true)][int]$Height,
    [string]$TextMaskPath,
    [string]$PaletteFile,
    [string]$OutputDirectory,
    [switch]$DebugOutput
)
. "$PSScriptRoot/Common.ps1"
Add-Type -AssemblyName System.Drawing
$source=Get-Item -LiteralPath $InputPath
$header=[Drawing.Image]::FromFile($source.FullName)
try {
    if ($X -lt 0 -or $Y -lt 0 -or $Width -le 0 -or $Height -le 0 -or
        ([long]$X+$Width) -gt $header.Width -or ([long]$Y+$Height) -gt $header.Height) { throw 'Panel rectangle must be inside the original image.' }
    $sourceWidth=$header.Width;$sourceHeight=$header.Height
} finally { $header.Dispose() }
$hash=(Get-MangaFileHash -LiteralPath $source.FullName).Hash
if (!$OutputDirectory) { $OutputDirectory=Join-Path $RepoRoot ('manga-output/panel-comparison-'+[Guid]::NewGuid().ToString('N').Substring(0,8)) }
$root=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $root -Force | Out-Null
$panel=Join-Path $root 'original-panel.png'
Crop-MangaImage -Source $source.FullName -Destination $panel -X $X -Y $Y -Width $Width -Height $Height
$panelMask=$null
if ($TextMaskPath) {
    $maskHeader=[Drawing.Image]::FromFile([IO.Path]::GetFullPath($TextMaskPath))
    try { if ($maskHeader.Width -ne $sourceWidth -or $maskHeader.Height -ne $sourceHeight) { throw 'Comparison mask must be in original coordinates.' } } finally { $maskHeader.Dispose() }
    $panelMask=Join-Path $root 'panel.protect-mask.png'
    Crop-MangaImage -Source ([IO.Path]::GetFullPath($TextMaskPath)) -Destination $panelMask -X $X -Y $Y -Width $Width -Height $Height
}
# Freeze editable files once so all six jobs receive identical instructions.
$palette=Read-DefaultMangaStyle -Root $RepoRoot
if ($PaletteFile) { $profile=Read-ChapterPalette -Path $PaletteFile; $palette+="`n"+$profile.Instruction }
$palette | Set-Content -LiteralPath (Join-Path $root 'applied-style.txt') -Encoding UTF8
$records=@()
foreach ($variant in @(@{size='4B';precision='FP8'},@{size='4B';precision='BF16'},@{size='9B';precision='FP8'})) {
    $label=$variant.size+'-'+$variant.precision
    $dir=Join-Path $root $label
    $shared=@{ModelSize=$variant.size;Precision=$variant.precision;Quality='Fast';Strength=1.0;Consistency=0;
        Megapixels=0.7;Seed=42;PromptStyle='Preserve';Palette=$palette;NoOpen=$true;DebugOutput=$DebugOutput}
    if ($PaletteFile -and $profile.Reference) { $shared.ReferenceImagePath=$profile.Reference }
    $fullOptions=@{}; foreach ($key in $shared.Keys) { $fullOptions[$key]=$shared[$key] }
    $panelOptions=@{}; foreach ($key in $shared.Keys) { $panelOptions[$key]=$shared[$key] }
    if ($TextMaskPath) { $fullOptions.TextMaskPath=[IO.Path]::GetFullPath($TextMaskPath);$panelOptions.TextMaskPath=$panelMask }
    $full=& "$PSScriptRoot/Colorize.ps1" -InputPath $source.FullName -OutputDirectory (Join-Path $dir 'full-page') @fullOptions
    $single=& "$PSScriptRoot/Colorize.ps1" -InputPath $panel -OutputDirectory (Join-Path $dir 'single-panel') @panelOptions
    if ($full.prompt -cne $single.prompt -or $full.seed -ne $single.seed) { throw 'Comparison settings drifted.' }
    $fullCrop=Join-Path $dir 'full-page-same-region.png'
    Crop-MangaImage -Source $full.image -Destination $fullCrop -X $X -Y $Y -Width $Width -Height $Height
    $paths=@($panel,$fullCrop,$single.image)
    $labels=@('Original','Full page - same region','Single panel')
    $thumbWidth=[Math]::Min(650,$Width)
    $thumbHeight=[int][Math]::Round($Height*$thumbWidth/[double]$Width)
    $canvas=New-Object Drawing.Bitmap ($thumbWidth*3),($thumbHeight+40)
    $g=[Drawing.Graphics]::FromImage($canvas);$font=New-Object Drawing.Font 'Arial',14
    try {
        $g.Clear([Drawing.Color]::White)
        for ($i=0;$i -lt 3;$i++) {
            $img=[Drawing.Image]::FromFile($paths[$i])
            try { $g.DrawImage($img,($i*$thumbWidth),40,$thumbWidth,$thumbHeight) } finally { $img.Dispose() }
            $g.DrawString($labels[$i],$font,[Drawing.Brushes]::Black,($i*$thumbWidth+8),8)
        }
        $preview=Join-Path $dir 'comparison.png'
        $canvas.Save($preview,[Drawing.Imaging.ImageFormat]::Png)
    } finally {$font.Dispose();$g.Dispose();$canvas.Dispose()}
    $records+=@{model=$full.model;full_page=$full.image;single_panel=$single.image;full_page_crop=$fullCrop;preview=$preview;
        full_page_seconds=$full.elapsed_seconds;single_panel_seconds=$single.elapsed_seconds;
        full_page_coverage=$full.coverage_report;single_panel_coverage=$single.coverage_report;
        roi=@{x=$X;y=$Y;width=$Width;height=$Height};seed=42;steps=4;cfg=1;strength=1;palette=$palette}
}
if ((Get-MangaFileHash -LiteralPath $source.FullName).Hash -ne $hash) { throw 'Source image changed.' }
$records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'comparison-report.json') -Encoding UTF8
Write-Host "Finished comparison for all three models: $root"
