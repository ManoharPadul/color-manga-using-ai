param([switch]$WithModels)
. "$PSScriptRoot/Common.ps1"
Start-LocalBackend
Add-Type -AssemblyName System.Drawing
$root=Join-Path $AiRoot ('restoration-tests/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$cases=@(
    @{w=83;h=121;mw=83;mh=121;pad=@(0,0,0,0)},
    @{w=131;h=61;mw=37;mh=29;pad=@(2,1,3,2)},
    @{w=193;h=17;mw=23;mh=11;pad=@(0,0,0,0)}
)
$index=0
foreach ($case in $cases) {
    $index++
    $dir=Join-Path $root "case-$index"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $source=Join-Path $dir 'original.png'; $color=Join-Path $dir 'color.png'; $mask=Join-Path $dir 'mask.png'
    $bitmap=New-Object Drawing.Bitmap $case.w,$case.h
    $g=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.Clear([Drawing.Color]::White)
        for ($x=1;$x -lt $case.w;$x+=3) { $g.DrawLine([Drawing.Pens]::Black,$x,0,$x,($case.h-1)) }
        $bitmap.Save($source,[Drawing.Imaging.ImageFormat]::Png)
        $g.Clear([Drawing.Color]::CornflowerBlue)
        $bitmap.Save($color,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose();$bitmap.Dispose() }
    $geometry=Get-MaskGeometry -Width $case.mw -Height $case.mh -Padding $case.pad
    $maskBitmap=New-Object Drawing.Bitmap $case.mw,$case.mh
    $g=[Drawing.Graphics]::FromImage($maskBitmap)
    $rx=2;$ry=1;$rw=[Math]::Max(1,[int][Math]::Floor($geometry.width/2));$rh=[Math]::Max(1,[int][Math]::Floor($geometry.height/2))
    try {
        $g.Clear([Drawing.Color]::Black)
        $g.FillRectangle([Drawing.Brushes]::White,($rx+$geometry.x),($ry+$geometry.y),$rw,$rh)
        $maskBitmap.Save($mask,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose();$maskBitmap.Dispose() }
    $before=(Get-MangaFileHash -LiteralPath $source).Hash
    $null=Restore-OriginalRegions -SourcePath $source -ColorPath $color -MaskPath $mask -Width $case.w -Height $case.h -Padding $case.pad -DebugDirectory $dir
    $actual=[Drawing.Bitmap]::FromFile($color);$original=[Drawing.Bitmap]::FromFile($source)
    try {
        if ($actual.Width -ne $case.w -or $actual.Height -ne $case.h) { throw 'Output size mismatch' }
        for ($y=0;$y -lt $case.h;$y++) { for ($x=0;$x -lt $case.w;$x++) {
            $mx=[int][Math]::Floor(($x+0.5)*$geometry.width/$case.w)
            $my=[int][Math]::Floor(($y+0.5)*$geometry.height/$case.h)
            $inside=$mx -ge $rx -and $mx -lt ($rx+$rw) -and $my -ge $ry -and $my -lt ($ry+$rh)
            $expected=if ($inside) { $original.GetPixel($x,$y).ToArgb() } else { [Drawing.Color]::CornflowerBlue.ToArgb() }
            if ($actual.GetPixel($x,$y).ToArgb() -ne $expected) { throw "Pixel mismatch case $index at $x,$y; protected=$inside" }
        } }
    } finally { $actual.Dispose();$original.Dispose() }
    if ((Get-MangaFileHash -LiteralPath $source).Hash -ne $before) { throw 'Original changed' }
    Write-Host "PASS case $index`: exact protected pixels, unchanged unmasked pixels, coordinates, PNG size and source hash."
}
$bad=$false
try { Get-MaskGeometry -Width 10 -Height 10 -Padding @(5,0,5,0) | Out-Null } catch { $bad=$true }
if (!$bad) { throw 'Invalid padding accepted' }
$regions=Join-Path $root 'regions.json'
$regionsMask=Join-Path $root 'regions.png'
@{version=1;regions=@(@{kind='text';x=3;y=4;width=10;height=8})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $regions -Encoding UTF8
New-RegionProtectionMask -Path $regions -Width 32 -Height 24 -Destination $regionsMask
$bitmap=[Drawing.Bitmap]::FromFile($regionsMask)
try {
    if ($bitmap.GetPixel(3,4).R -ne 255 -or $bitmap.GetPixel(12,11).R -ne 255 -or $bitmap.GetPixel(13,11).R -ne 0 -or $bitmap.GetPixel(2,4).R -ne 0) { throw 'Protection rectangle bounds changed' }
} finally { $bitmap.Dispose() }
foreach ($region in @(@{kind='structure';x=0;y=0;width=2;height=2},@{kind='text';x=31;y=0;width=2;height=2})) {
    @{version=1;regions=@($region)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $regions -Encoding UTF8
    $bad=$false
    try { New-RegionProtectionMask -Path $regions -Width 32 -Height 24 -Destination $regionsMask } catch { $bad=$true }
    if (!$bad) { throw 'Unverified structure or out-of-bounds region accepted' }
}
Write-Host 'PASS targeted region bounds and rejection of unverified structure.'
if ($WithModels) {
    # Harmless cottage fixture created by Test.ps1 -SmokeTest.
    $fixture=Join-Path $AiRoot 'smoke-test/line-art.png'
    if (!(Test-Path -LiteralPath $fixture)) { throw 'Run Test.ps1 -SmokeTest to create the cottage fixture first.' }
    $mask=Join-Path $root 'cottage-mask.png'
    $bmp=New-Object Drawing.Bitmap 768,768;$g=[Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([Drawing.Color]::Black)
        $g.FillRectangle([Drawing.Brushes]::White,55,70,300,115)
        $bmp.Save($mask,[Drawing.Imaging.ImageFormat]::Png)
    } finally {$g.Dispose();$bmp.Dispose()}
    foreach ($variant in @(@{size='4B';precision='FP8'},@{size='4B';precision='BF16'},@{size='9B';precision='FP8'})) {
        $result=& "$PSScriptRoot/Colorize.ps1" -InputPath $fixture -ModelSize $variant.size -Precision $variant.precision `
            -Palette 'Red roof, cream walls, green leaves, pale blue sky.' -TextMaskPath $mask -DebugOutput -NoOpen -OutputDirectory $root
        $actual=[Drawing.Bitmap]::FromFile($result.image);$original=[Drawing.Bitmap]::FromFile($fixture)
        try {
            for ($y=70;$y -lt 185;$y++) { for ($x=55;$x -lt 355;$x++) {
                if ($actual.GetPixel($x,$y).ToArgb() -ne $original.GetPixel($x,$y).ToArgb()) { throw "Model integration restoration mismatch: $($result.model)" }
            } }
        } finally {$actual.Dispose();$original.Dispose()}
        Write-Host "PASS $($result.model): full-resolution original lettering restored exactly."
    }
}
Write-Host "PASS restoration regression suite. Artifacts: $root"
