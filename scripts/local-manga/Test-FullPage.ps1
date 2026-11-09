. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Panels.ps1"
$root=Join-Path $AiRoot ('full-page-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$source=Join-Path $root '[chapter page].png'
$bitmap=[Drawing.Bitmap]::new(320,700);$graphics=[Drawing.Graphics]::FromImage($bitmap)
try{$graphics.Clear([Drawing.Color]::White);$graphics.FillRectangle([Drawing.Brushes]::Black,5,5,310,300);$graphics.FillRectangle([Drawing.Brushes]::Black,5,335,310,360);$bitmap.Save($source,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
$legacy=Get-MangaStripPanels -Path $source
if($legacy.Count -ne 2){throw 'Fixture must have a clear strip boundary'}
$sidecar=[IO.Path]::ChangeExtension($source,'.panels.json')
@{version=1;approved=$true;width=320;height=700;panels=$legacy}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $sidecar -Encoding UTF8
$plan=& "$PSScriptRoot/Colorize-Panels.ps1" -InputPath $source -OutputDirectory (Join-Path $root 'whole-page') -FullPage -PlanOnly
$saved=Get-Content -LiteralPath $plan.settings -Raw|ConvertFrom-Json
if($saved.processing_mode -ne 'FullPage' -or @($saved.panels).Count -ne 1){throw 'Full-page mode split the input'}
$p=$saved.panels[0]
if($p.id -ne 'page-01' -or $p.x -ne 0 -or $p.y -ne 0 -or $p.width -ne 320 -or $p.height -ne 700){throw 'Whole-page bounds differ from source'}
$rejected=$false
try{$null=& "$PSScriptRoot/Colorize-Panels.ps1" -InputPath $source -OutputDirectory (Join-Path $root 'bad-split') -FullPage -PlanPath $sidecar -PlanOnly}catch{$rejected=$true}
if(!$rejected){throw 'An explicit split plan silently overrode whole-page mode'}
Write-Host 'PASS: full-page mode ignores auto-strip gutters/sidecars, covers original dimensions and rejects split plans; no model loaded.'
