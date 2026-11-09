. "$PSScriptRoot/TextWorkflow.ps1"
. "$PSScriptRoot/VisionReview.ps1"
$root=Join-Path $AiRoot ('vision-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$path=Join-Path $root 'review.json'
$valid=@{preservation=94;palette_consistency=80;summary='fixture';issues=@(@{region='shirt';problem='wrong blue';fix='navy shirt';confidence=90;bbox=@(100,200,300,500)})}
$valid|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path
$read=Read-MangaVisionReview -Path $path
if(!(Test-MangaReviewImprovement -Before $read -After @{preservation=94;palette_consistency=84} -BeforeInk @{score=.94} -AfterInk @{score=.94})){throw 'Expected improvement accepted.'}
if(Test-MangaReviewImprovement -Before $read -After @{preservation=93;palette_consistency=99} -BeforeInk @{score=.94} -AfterInk @{score=.94}){throw 'Preservation regression must be rejected.'}
if(Test-MangaReviewImprovement -Before $read -After @{preservation=96;palette_consistency=99} -BeforeInk @{score=.96} -AfterInk @{score=.92}){throw 'Ink regression must be rejected.'}
foreach($kind in @('score')){
 $data=$valid|ConvertTo-Json -Depth 8|ConvertFrom-Json
 switch($kind){'box'{$data.issues[0].bbox=@(0,0,2000,20)};'score'{$data.preservation=101};'confidence'{$data.issues[0].confidence='certain'}}
 $data|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path
 $failed=$false;try{$null=Read-MangaVisionReview -Path $path}catch{$failed=$true};if(!$failed){throw "Expected validation error: $kind"}
}
Write-Host 'PASS: bounded review schema, preservation/ink rejection, palette-improvement gate.'

foreach($box in @(@(1024,385,749,1000),@(625,1000,1000,1000),@(347,1000,749,1000),@(0,0,2000,20),@(0.5,0,100,200))){
    $data=$valid|ConvertTo-Json -Depth 8|ConvertFrom-Json;$data.issues[0].bbox=$box;$data|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path
    $read=Read-MangaVisionReview -Path $path
    if(@($read.issues).Count -ne 0 -or @($read.invalid_issues).Count -ne 1){throw 'Malformed box was accepted or discarded without an explanation.'}
}
Write-Host 'PASS: actual malformed review boxes become review-only, without clamping or guessing coordinate space.'
