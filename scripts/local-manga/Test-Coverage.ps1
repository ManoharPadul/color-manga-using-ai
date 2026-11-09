param()
. "$PSScriptRoot/Common.ps1"
$portrait=Get-CoverageAnalysisSize -Width 1280 -Height 1813 -MaxSide 96
if($portrait.width -ne 68 -or $portrait.height -ne 96){throw 'Portrait coverage collapsed or lost aspect ratio'}
$landscape=Get-CoverageAnalysisSize -Width 1813 -Height 1280 -MaxSide 96
if($landscape.width -ne 96 -or $landscape.height -ne 68){throw 'Landscape coverage grid incorrect'}
Add-Type -AssemblyName System.Drawing
$root=Join-Path $AiRoot ('coverage-tests/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$source=Join-Path $root 'source.png';$raw=Join-Path $root 'raw.png';$final=Join-Path $root 'final.png'
$definitions=@(
    @{id='skin';category='skin';intent='color';expected_color='#DBA588';repair=$true;x=10;y=10;color='Gray'},
    @{id='white-shirt';category='clothing';intent='neutral';expected_color='#FFFFFF';repair=$false;x=70;y=10;color='White'},
    @{id='black-hair';category='hair';intent='color';expected_color='#000000';repair=$false;x=130;y=10;color='Black'},
    @{id='gray-object';category='background';intent='neutral';expected_color='#808080';repair=$false;x=10;y=70;color='Gray'},
    @{id='hair';category='hair';intent='color';expected_color='#795338';repair=$true;x=70;y=70;color='Blue'}
)
$bitmap=New-Object Drawing.Bitmap 192,128;$g=[Drawing.Graphics]::FromImage($bitmap)
try{
    $g.Clear([Drawing.Color]::White)
    foreach($d in $definitions){$brush=New-Object Drawing.SolidBrush ([Drawing.Color]::FromName($d.color));try{$g.FillRectangle($brush,$d.x,$d.y,40,40)}finally{$brush.Dispose()}}
    $bitmap.Save($raw,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Save($final,[Drawing.Imaging.ImageFormat]::Png)
    $g.FillRectangle([Drawing.Brushes]::Gray,70,70,40,40)
    $bitmap.Save($source,[Drawing.Imaging.ImageFormat]::Png)
}finally{$g.Dispose();$bitmap.Dispose()}
$items=@()
foreach($d in $definitions){
    $mask=Join-Path $root ($d.id+'.png');$bitmap=New-Object Drawing.Bitmap 192,128;$g=[Drawing.Graphics]::FromImage($bitmap)
    try{$g.Clear([Drawing.Color]::Black);$g.FillRectangle([Drawing.Brushes]::White,$d.x,$d.y,40,40);$bitmap.Save($mask,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()}
    $items+=@{id=$d.id;category=$d.category;intent=$d.intent;expected_color=$d.expected_color;repair=$d.repair;mask=$mask}
}
$json=Join-Path $root 'regions.json';@{version=1;regions=$items} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $json -Encoding UTF8
$regions=@(Read-ColorRegions -Path $json -Width 192 -Height 128)
$o=Get-ImageLabGrid -Path $source -GridWidth 96 -GridHeight 64
$r=Get-ImageLabGrid -Path $raw -GridWidth 96 -GridHeight 64
$a=Measure-ColorCoverage -Original $o -Raw $r -Before $r -Final $r -Regions $regions -Width 192 -Height 128 -DebugDirectory $root
if($a.estimated_uncolored_percent -ne 50 -or @($a.components | Where-Object {$_.cause -eq 'A_model_left_region_neutral'}).Count -eq 0){throw 'Missing-color coverage detection failed'}
if(@($a.components | Where-Object {$_.region_ids -contains 'white-shirt' -or $_.region_ids -contains 'black-hair' -or $_.region_ids -contains 'gray-object'}).Count){throw 'Intentional neutral false positive'}
if(@($a.regions | Where-Object {$_.id -eq 'hair'})[0].mean_ab_distance_from_palette -lt 25){throw 'Hair palette mismatch not reported'}
$unknown=Measure-ColorCoverage -Original $o -Raw $r -Before $r -Final $r -Width 192 -Height 128
if($null -ne $unknown.estimated_uncolored_percent){throw 'Coverage percentage reported without eligible regions'}
$bitmap=[Drawing.Bitmap]::FromFile($raw);$g=[Drawing.Graphics]::FromImage($bitmap)
try{$brush=New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#DBA588'));try{$g.FillRectangle($brush,10,10,40,40)}finally{$brush.Dispose()};$bitmap.Save((Join-Path $root 'colored.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()}
$colored=Get-ImageLabGrid -Path (Join-Path $root 'colored.png') -GridWidth 96 -GridHeight 64
$b=Measure-ColorCoverage -Original $o -Raw $colored -Before $colored -Final $r -Regions $regions -ProtectionMask $regions[0].mask -Width 192 -Height 128
if($b.neutral_samples_restored_by_protection -ne 400){throw 'Protection-caused color loss not diagnosed'}
$c=Measure-ColorCoverage -Original $o -Raw $colored -Before $r -Final $r -Regions $regions -Width 192 -Height 128
if($c.possible_postprocess_loss_samples -ne 400){throw 'Postprocessing loss not diagnosed'}
$complete=Measure-ColorCoverage -Original $o -Raw $colored -Before $colored -Final $colored -Regions $regions -Width 192 -Height 128
if($complete.estimated_uncolored_percent -ne 0){throw 'Complete eligible colorization marked missing'}
$partial=Join-Path $root 'partial.png';$bitmap=[Drawing.Bitmap]::FromFile((Join-Path $root 'colored.png'));$g=[Drawing.Graphics]::FromImage($bitmap)
try{$g.FillRectangle([Drawing.Brushes]::Gray,20,20,8,8);$bitmap.Save($partial,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()}
$partialGrid=Get-ImageLabGrid -Path $partial -GridWidth 96 -GridHeight 64
$small=Measure-ColorCoverage -Original $o -Raw $partialGrid -Before $partialGrid -Final $partialGrid -Regions $regions -Width 192 -Height 128
if($small.estimated_uncolored_percent -ne 2 -or @($small.components | Where-Object {$_.region_ids -contains 'skin' -and $_.sample_count -eq 16}).Count -ne 1){throw 'Isolated neutral patch was not detected'}
$eye=[pscustomobject]@{id='eyes';category='eyes';intent='color';mask=$regions[4].mask;expected_color='#657A44';repair=$false;character='Alex'}
$eyeReport=Measure-ColorCoverage -Original $o -Raw $r -Before $r -Final $r -Regions @($eye) -Width 192 -Height 128
if($eyeReport.regions[0].mean_ab_distance_from_palette -lt 25){throw 'Eye palette mismatch was not detected'}
# CIELAB implementation sanity: gray is nearly achromatic; red has substantial chroma.
$gray=@(Get-CoverageLab -Color ([Drawing.Color]::Gray) -Cache @{});$red=@(Get-CoverageLab -Color ([Drawing.Color]::Red) -Cache @{})
if([Math]::Abs($gray[1])+[Math]::Abs($gray[2]) -gt 0.01 -or $red[1] -lt 70){throw 'CIELAB conversion regression'}
# A persistent character palette supplies the same explicit target for later crops.
$palette=[pscustomobject]@{characters=@([pscustomobject]@{name='Alex';skin='warm base #DBA588';region_colors=[pscustomobject]@{'shirt'='navy #304050'}})}
$inherited=Join-Path $root 'inherited.json'
@{version=1;regions=@(@{id='face';character='Alex';category='face';intent='color';mask=$regions[0].mask;repair=$false})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $inherited -Encoding UTF8
$resolved=@(Read-ColorRegions -Path $inherited -Width 192 -Height 128 -PaletteData $palette)
if($resolved[0].expected_color -ne '#DBA588'){throw 'Character palette color was not inherited'}
# No model call or output mutation is permitted for a good/neutral region.
$beforeHash=(Get-MangaFileHash -LiteralPath $final).Hash
$neutralOnly=@($regions | Where-Object {$_.intent -eq 'neutral'})
$repair=Invoke-ColorRegionRepairs -SourcePath $source -ColorPath $final -Regions $neutralOnly -Report $complete -Width 192 -Height 128 -ModelOptions @{} -MaxRegions 1 -WorkDirectory (Join-Path $root 'no-op') -CurrentGrid $colored
if($repair.attempted -ne 0 -or $repair.repaired -ne 0 -or (Get-MangaFileHash -LiteralPath $final).Hash -ne $beforeHash){throw 'No-op repair modified a neutral region'}
Write-Host "PASS: missing color, neutral exclusions, palette mismatch, mask loss, resize loss, uncertainty and complete coverage. Fixtures: $root"
