# Explicit GPU test: run only when the user's normal conversion is idle.
param([switch]$AllowInference)
if(!$AllowInference){throw 'GPU test requires -AllowInference after checking the backend queue and user authorization.'}
. "$PSScriptRoot/Common.ps1"
Start-LocalBackend
Add-Type -AssemblyName System.Drawing
$root=Join-Path $AiRoot ('color-repair-model-tests/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$source=Join-Path $root 'original.png';$base=Join-Path $root 'incomplete.png';$mask=Join-Path $root 'gable-mask.png'
$roof=[Drawing.Point[]]@((New-Object Drawing.Point 160,340),(New-Object Drawing.Point 345,190),(New-Object Drawing.Point 530,340))
$patch=[Drawing.Point[]]@((New-Object Drawing.Point 190,330),(New-Object Drawing.Point 345,220),(New-Object Drawing.Point 490,330))
$bmp=New-Object Drawing.Bitmap 768,768;$g=[Drawing.Graphics]::FromImage($bmp);$pen=New-Object Drawing.Pen ([Drawing.Color]::Black),4
try{
    $g.Clear([Drawing.Color]::White);$g.DrawRectangle($pen,24,24,720,720);$g.DrawPolygon($pen,$roof);$g.DrawRectangle($pen,200,340,290,230)
    $g.DrawRectangle($pen,225,380,65,60);$g.DrawRectangle($pen,405,380,65,60);$g.DrawRectangle($pen,315,430,65,140);$g.DrawLine($pen,25,570,742,570)
    $bmp.Save($source,[Drawing.Imaging.ImageFormat]::Png)
    $g.Clear([Drawing.Color]::LightSkyBlue);$g.FillRectangle([Drawing.Brushes]::Beige,25,570,717,172);$g.FillPolygon([Drawing.Brushes]::Firebrick,$roof)
    $g.FillRectangle([Drawing.Brushes]::Beige,200,340,290,230);$g.FillPolygon([Drawing.Brushes]::LightGray,$patch)
    $line=[Drawing.Image]::FromFile($source);$attrs=New-Object Drawing.Imaging.ImageAttributes
    try{$attrs.SetColorKey([Drawing.Color]::White,[Drawing.Color]::White);$rect=New-Object Drawing.Rectangle 0,0,768,768;$g.DrawImage($line,$rect,0,0,768,768,[Drawing.GraphicsUnit]::Pixel,$attrs)}finally{$attrs.Dispose();$line.Dispose()}
    $bmp.Save($base,[Drawing.Imaging.ImageFormat]::Png)
    $g.Clear([Drawing.Color]::Black);$g.FillPolygon([Drawing.Brushes]::White,$patch);$bmp.Save($mask,[Drawing.Imaging.ImageFormat]::Png)
}finally{$pen.Dispose();$g.Dispose();$bmp.Dispose()}
$sourceHash=(Get-MangaFileHash -LiteralPath $source).Hash
$region=[pscustomobject]@{id='gable';category='background';intent='color';mask=$mask;expected_color='#EAD9A6';repair=$true;character='cottage'}
$o=Get-ImageLabGrid -Path $source -GridWidth 96 -GridHeight 96
$b=Get-ImageLabGrid -Path $base -GridWidth 96 -GridHeight 96
$report=Measure-ColorCoverage -Original $o -Raw $b -Before $b -Final $b -Regions @($region) -Width 768 -Height 768
$records=@()
foreach($variant in @(@{size='4B';precision='FP8'},@{size='4B';precision='BF16'},@{size='9B';precision='FP8'})){
    $label=$variant.size+'-'+$variant.precision;$dir=Join-Path $root $label;New-Item -ItemType Directory -Path $dir | Out-Null
    $output=Join-Path $dir 'repaired.png';Copy-Item -LiteralPath $base -Destination $output
    $opts=@{ModelSize=$variant.size;Precision=$variant.precision;Quality='Fast';Strength=1;Consistency=0;Megapixels=0.7;Seed=42;
        PromptStyle='Preserve';Palette='Cream front gable and walls, red roof trim, blue sky, natural matte colors.';CoverageMode='Off';NoOpen=$true}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=Invoke-ColorRegionRepairs -SourcePath $source -ColorPath $output -Regions @($region) -Report $report -Width 768 -Height 768 -ModelOptions $opts -MaxRegions 1 -WorkDirectory (Join-Path $dir 'work') -CurrentGrid $b
    if($result.attempted -gt 1 -or $result.repaired -gt 1){throw 'Repair attempt limit exceeded'}
    $before=[Drawing.Bitmap]::FromFile($base);$after=[Drawing.Bitmap]::FromFile($output);$selection=[Drawing.Bitmap]::FromFile($mask)
    $outside=0
    try{for($y=0;$y -lt 768;$y++){for($x=0;$x -lt 768;$x++){if($selection.GetPixel($x,$y).R -le 127 -and $before.GetPixel($x,$y).ToArgb() -ne $after.GetPixel($x,$y).ToArgb()){$outside++}}}}finally{$before.Dispose();$after.Dispose();$selection.Dispose()}
    if($outside -ne 0){throw 'Color bled outside the manual mask'}
    if((Get-MangaFileHash -LiteralPath $source).Hash -ne $sourceHash){throw 'Source modified'}
    $records+=@{model=$label;repair=$result;seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);outside_mask_changes=$outside;output=$output}
    Write-Host "PASS $label`: bounded attempt, accepted=$($result.repaired), no outside-mask changes. Rejected candidates remain unchanged for manual review."
}
$records | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $root 'model-test-results.json') -Encoding UTF8
Write-Host "GPU tests complete. Inspect acceptance/rejection and images: $root"
