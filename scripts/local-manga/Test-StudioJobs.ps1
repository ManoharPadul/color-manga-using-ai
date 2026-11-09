. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Studio-Jobs.ps1"
$root=Join-Path $AiRoot ('studio-job-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$source=Join-Path $root 'source.txt';$final=Join-Path $root 'result.txt';$checkpoint=Join-Path $root 'completed.json'
[IO.File]::WriteAllText($source,'source');[IO.File]::WriteAllText($final,'result')
$fingerprint=Get-MangaJobFingerprint -Source $source -Settings 'steps=4'
Save-MangaCompletedJob -Path $checkpoint -Fingerprint $fingerprint -Record @{source=$source;final=$final}
if(!(Read-MangaCompletedJob -Path $checkpoint -Fingerprint $fingerprint)){throw 'Valid checkpoint rejected'}
if(Read-MangaCompletedJob -Path $checkpoint -Fingerprint 'changed'){throw 'Changed settings reused'}
[IO.File]::WriteAllText($final,'tampered')
if(Read-MangaCompletedJob -Path $checkpoint -Fingerprint $fingerprint){throw 'Changed output reused'}
[IO.File]::WriteAllText($source,'changed source')
if((Get-MangaJobFingerprint -Source $source -Settings 'steps=4') -eq $fingerprint){throw 'Source hash ignored'}
$control=Join-Path $root 'control.txt';[IO.File]::WriteAllText($control,'cancel')
$canceled=$false
try{Wait-MangaControl -ControlFile $control}catch [OperationCanceledException]{$canceled=$true}
if(!$canceled){throw 'Cancel not honored'}
[IO.File]::WriteAllText($control,'run');Wait-MangaControl -ControlFile $control
Write-Host 'PASS: verified checkpoint reuse, changed settings/source/output rejection, cooperative cancellation and resume.'
$approval=Join-Path $root 'review.json';[IO.File]::WriteAllText($approval,'{}')
$worker=Start-Job -ScriptBlock {param($path) Start-Sleep -Milliseconds 500;[IO.File]::WriteAllText($path+'.approved','approved')} -ArgumentList $approval
try{Wait-MangaApproval -Path $approval -Kind 'TEST_REVIEW' -ControlFile $control;$null=Wait-Job $worker -Timeout 15;if($worker.State -ne 'Completed'){throw 'Approval worker failed'}}finally{Remove-Job $worker -Force}
[IO.File]::WriteAllText($control,'pause')
$worker=Start-Job -ScriptBlock {param($path) Start-Sleep -Milliseconds 500;[IO.File]::WriteAllText($path,'run')} -ArgumentList $control
try{Wait-MangaControl -ControlFile $control;$null=Wait-Job $worker -Timeout 15;if($worker.State -ne 'Completed'){throw 'Resume worker failed'}}finally{Remove-Job $worker -Force}
[IO.File]::WriteAllText($control,'cancel')
$canceledRun=Join-Path $root 'canceled-run'
& "$PSScriptRoot/Studio-Run.ps1" -InputPath $source -OutputDirectory $canceledRun -ControlFile $control
$report=Get-Content -LiteralPath (Join-Path $canceledRun 'studio-report.json') -Raw|ConvertFrom-Json
if(!$report.canceled -or @($report.completed).Count){throw 'Studio cancellation checkpoint failed'}
Write-Host 'PASS: approval wait, pause/resume handoff and full studio cancellation before model loading.'
$lockRoot=Join-Path $root 'lock-fixture'
$first=Open-MangaRunLock -Directory $lockRoot -OutputDirectory $root
try{
    $rejected=$false
    try{$second=Open-MangaRunLock -Directory $lockRoot -OutputDirectory $root;$second.Dispose()}catch{if([string]$_ -notlike '*Worker PID*'){throw};$rejected=$true}
    if(!$rejected){throw 'Concurrent lock not rejected'}
}finally{$first.Dispose()}
# The persistent file and old owner metadata alone must never block a new run.
$next=Open-MangaRunLock -Directory $lockRoot -OutputDirectory $root;$next.Dispose()
if(!(Test-MangaOwnerAlive -ProcessId $PID -StartTicks (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)){throw 'Live owner rejected'}
if(Test-MangaOwnerAlive -ProcessId $PID -StartTicks 1){throw 'Reused PID accepted'}
$script:MangaOwnerProcessId=2147483647;$script:MangaOwnerStartTicks=1;$orphanStopped=$false
try{Wait-MangaControl}catch [OperationCanceledException]{$orphanStopped=$true}finally{Set-MangaOwner -ProcessId 0}
if(!$orphanStopped){throw 'Orphaned worker not canceled'}
Write-Host 'PASS: real concurrent lock, stale-file reuse, owner PID/start-time identity and orphan cancellation.'
$export=Export-MangaFinalPage -Source 'page [1].webp' -Image $final -Directory $root
if((Split-Path -Parent $export) -ne $root -or (Split-Path -Leaf $export) -notmatch '^page \[1\]-[a-f0-9]{8}-color\.png$'){throw 'Flat final-page layout failed'}
if((Get-MangaFileHash -LiteralPath $export).Hash -ne (Get-MangaFileHash -LiteralPath $final).Hash){throw 'Final export changed contents'}
Write-Host 'PASS: CMD-style flat final image naming, literal bracket paths and unchanged final export.'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName='powershell.exe';$start.Arguments='-NoProfile -Command "Start-Sleep -Seconds 30"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($start)
$watch=[Diagnostics.Stopwatch]::StartNew();$interrupted=$false
[IO.File]::WriteAllText($control,'cancel');Set-MangaOwner -ProcessId 0 -ControlFile $control
try{Wait-MangaChildProcess -Process $child}catch [OperationCanceledException]{$interrupted=$true}finally{
    if(!$child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose();Set-MangaOwner -ProcessId 0
}
if(!$interrupted -or $watch.Elapsed.TotalSeconds -gt 5){throw 'Native helper cancellation did not stop promptly'}
$held=Open-MangaRunLock -Directory $lockRoot -OutputDirectory $root
Close-MangaRunLock -Handle $held -Directory $lockRoot
if(Test-Path -LiteralPath (Join-Path $lockRoot 'mangacolorai-run.lock.owner.json')){throw 'Exited owner metadata left behind'}
$again=Open-MangaRunLock -Directory $lockRoot -OutputDirectory $root;Close-MangaRunLock -Handle $again -Directory $lockRoot
Write-Host 'PASS: cancellation interrupts only the owned helper promptly; owner metadata clears and immediate restart succeeds.'
