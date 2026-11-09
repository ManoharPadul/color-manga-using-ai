. "$PSScriptRoot/Common.ps1"
$root=Join-Path $AiRoot ('studio-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$inputDir=Join-Path $root 'input';$null=[IO.Directory]::CreateDirectory($inputDir)
foreach($name in @('1.png','2.jpg','10.webp','1.protect-mask.png','note.txt')){[IO.File]::WriteAllText((Join-Path $inputDir $name),'fixture - list only')}
$single=@(& "$PSScriptRoot/Studio-Run.ps1" -InputPath (Join-Path $inputDir '1.png') -OutputDirectory (Join-Path $root 'single') -ListOnly)
if($single.Count -ne 1){throw 'Single-file discovery failed.'}
$folder=@(& "$PSScriptRoot/Studio-Run.ps1" -InputPath $inputDir -OutputDirectory (Join-Path $root 'folder') -ListOnly)
if($folder.Count -ne 3 -or [IO.Path]::GetFileName($folder[1].FullName) -ne '2.jpg'){throw 'Folder discovery, natural sort or mask exclusion failed.'}
Write-Host 'PASS: strict-mode single-file Count regression, folder discovery, natural sort, sidecar exclusion.'
$custom=New-ColorizeGraph -ImageName 'fixture.png' -Instruction 'test' -Seed 12345 -Megapixels 2.25 -SamplingSteps 8 -ModelSize 9B -Precision FP8
if($custom.'16'.inputs.steps -ne 8 -or $custom.'14'.inputs.noise_seed -ne 12345 -or $custom.'2'.inputs.megapixels -ne 2.25){throw 'Editable sampling settings did not reach the model graph.'}
$defaultBase=New-ColorizeGraph -ImageName 'fixture.png' -Instruction 'test' -Quality BaseExperimental
if($defaultBase.'16'.inputs.steps -ne 50){throw 'Base default sampling changed.'}
Write-Host 'PASS: custom steps, seed and MP reach the graph; Base defaults stay intact.'
