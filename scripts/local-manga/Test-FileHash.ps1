. "$PSScriptRoot/Common.ps1"
$root=Join-Path $AiRoot ('hash-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$path=Join-Path $root 'file [1].txt';[IO.File]::WriteAllText($path,'abc')
# Simulate an unavailable/broken native hashing command. Runtime must not call it.
function Get-FileHash {throw 'The native hashing command is unavailable in this regression fixture.'}
$actual=Get-MangaFileHash -LiteralPath $path -Algorithm SHA256
if($actual.Hash -cne 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'){throw 'SHA256 known-vector mismatch'}
if($actual.Path -cne [IO.Path]::GetFullPath($path)){throw 'Literal path changed'}
[IO.File]::WriteAllBytes($path,[byte[]]@())
if((Get-MangaFileHash -LiteralPath $path).Hash -cne 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'){throw 'Empty-file hash mismatch'}
Write-Host 'PASS: .NET SHA256 known vectors and bracket paths without the native Get-FileHash command.'
Add-Type -AssemblyName System.Drawing
$image=Join-Path $root 'page [1].png';$bitmap=[Drawing.Bitmap]::new(64,64)
try{$bitmap.Save($image,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
$plan=& "$PSScriptRoot/Colorize-Panels.ps1" -InputPath $image -OutputDirectory (Join-Path $root 'plan') -PlanOnly
$saved=Get-Content -LiteralPath $plan.settings -Raw|ConvertFrom-Json
if($saved.source_hash -cne (Get-MangaFileHash -LiteralPath $image).Hash){throw 'Panel preflight did not use independent hashing'}
Write-Host 'PASS: actual panel normalization/planning/hashing with native Get-FileHash disabled; no model loaded.'
