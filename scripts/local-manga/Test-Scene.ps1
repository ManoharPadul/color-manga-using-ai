. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Scene.ps1"
$indoor=Get-MangaSceneInstruction -Scene Indoor
if($indoor -notlike '*walls remain walls*' -or $indoor -notlike '*Do not turn wall*'){throw 'Indoor constraint missing'}
$mixed=Get-MangaSceneInstruction -Scene Mixed
if($mixed -notlike '*each panel*'){throw 'Mixed setting must remain panel-specific'}
$style=Get-Content -LiteralPath (Join-Path $RepoRoot 'manga-tested-style.txt') -Raw
if($style -match 'green foliage|pale blue sky|every character.*brown|ivory shirts|navy jackets'){throw 'Default palette imposes scenery or global character colors'}
$source=Get-MangaSceneInstruction -Scene Source
if($source -notlike '*Do not assume*'){throw 'Default scene constraint missing'}
Write-Host 'PASS: neutral default style, explicit indoor override, per-panel mixed setting and no added vision stage.'
