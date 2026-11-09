# Cooperative control: finish the current model stage, then pause/cancel safely.
if(!(Get-Variable MangaOwnerProcessId -Scope Script -ErrorAction SilentlyContinue)){$script:MangaOwnerProcessId=0;$script:MangaOwnerStartTicks=0}
if(!(Get-Variable MangaControlFile -Scope Script -ErrorAction SilentlyContinue)){$script:MangaControlFile=''}
function Set-MangaOwner {
    param([int]$ProcessId,[string]$ControlFile)
    $script:MangaControlFile=$ControlFile
    $script:MangaOwnerProcessId=$ProcessId;$script:MangaOwnerStartTicks=0
    if($ProcessId -gt 0){
        $owner=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if(!$owner){throw [OperationCanceledException]::new('The owning app already exited.')}
        $script:MangaOwnerStartTicks=$owner.StartTime.ToUniversalTime().Ticks
    }
}
function Open-MangaRunLock {
    param([string]$Directory,[string]$OutputDirectory)
    $null=[IO.Directory]::CreateDirectory($Directory)
    $path=Join-Path $Directory 'mangacolorai-run.lock'
    try{$handle=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{
        $reason=$_.Exception.GetBaseException();$code=$reason.HResult -band 0xFFFF
        if($code -in @(32,33)){
            $detail=''
            try{$owner=Get-Content -LiteralPath ($path+'.owner.json') -Raw|ConvertFrom-Json;$detail=" Worker PID $($owner.pid); output: $($owner.output)."}catch{}
            throw "Another worker holds the run lock.$detail An earlier app may have left a background worker. Completed files are kept; do not delete the lock to bypass it."
        }
        throw "Cannot open MangaColorAI run lock: $($reason.Message)"
    }
    try{
        @{pid=$PID;started_utc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');output=$OutputDirectory}|ConvertTo-Json|Set-Content -LiteralPath ($path+'.owner.json') -Encoding UTF8
    }catch{$handle.Dispose();throw}
    return $handle
}
function Test-MangaOwnerAlive {
    param([int]$ProcessId,[long]$StartTicks)
    if($ProcessId -le 0){return $true}
    $owner=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    return ($null -ne $owner -and ($StartTicks -le 0 -or $owner.StartTime.ToUniversalTime().Ticks -eq $StartTicks))
}
function Wait-MangaControl {
    param([string]$ControlFile)
    if(!$ControlFile){$ControlFile=$script:MangaControlFile}
    if($script:MangaOwnerProcessId -gt 0 -and !(Test-MangaOwnerAlive -ProcessId $script:MangaOwnerProcessId -StartTicks $script:MangaOwnerStartTicks)){
        throw [OperationCanceledException]::new('The owning app exited. Stopping at a safe boundary; completed files are kept.')
    }
    if(!$ControlFile){return}
    while(Test-Path -LiteralPath $ControlFile){
        $state=Get-Content -LiteralPath $ControlFile -Raw -Encoding UTF8
        if($state.Trim() -eq 'cancel'){throw [OperationCanceledException]::new('Canceled at a safe stage boundary; completed files are kept.')}
        if($state.Trim() -ne 'pause'){return}
        if($script:MangaOwnerProcessId -gt 0 -and !(Test-MangaOwnerAlive -ProcessId $script:MangaOwnerProcessId -StartTicks $script:MangaOwnerStartTicks)){throw [OperationCanceledException]::new('The owning app exited while paused.')}
        Start-Sleep -Milliseconds 300
    }
}
function Wait-MangaChildProcess {
    param([Diagnostics.Process]$Process)
    try{
        while(!$Process.WaitForExit(300)){Wait-MangaControl}
    }catch [OperationCanceledException]{
        # Stop only the helper created by this call, never the shared backend.
        if(!$Process.HasExited){$Process.Kill();$Process.WaitForExit()}
        throw
    }
}
function Close-MangaRunLock {
    param([IO.FileStream]$Handle,[string]$Directory)
    if(!$Handle){return}
    try{
        $path=Join-Path $Directory 'mangacolorai-run.lock.owner.json'
        if(Test-Path -LiteralPath $path){
            $owner=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
            if($owner.pid -eq $PID){Remove-Item -LiteralPath $path}
        }
    }catch{
        # Stale diagnostic metadata must never mask completion or prevent unlock.
    }finally{$Handle.Dispose()}
}
function Wait-MangaApproval {
    param([string]$Path,[string]$Kind,[string]$ControlFile)
    $approval=$Path+'.approved'
    if(Test-Path -LiteralPath $approval){Remove-Item -LiteralPath $approval}
    Write-Host ('['+$Kind+'] '+$Path)
    while(!(Test-Path -LiteralPath $approval)){
        Wait-MangaControl -ControlFile $ControlFile
        Start-Sleep -Milliseconds 300
    }
}
function Get-MangaJobFingerprint {
    param([string]$Source,[string]$Settings)
    $data=(Get-MangaFileHash -LiteralPath $Source -Algorithm SHA256).Hash+'|'+$Settings
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($data))).Replace('-','')}finally{$sha.Dispose()}
}
function Read-MangaCompletedJob {
    param([string]$Path,[string]$Fingerprint)
    if(!(Test-Path -LiteralPath $Path)){return $null}
    try{
        $saved=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
        if($saved.fingerprint -cne $Fingerprint -or !(Test-Path -LiteralPath $saved.record.final)){return $null}
        if((Get-MangaFileHash -LiteralPath $saved.record.final -Algorithm SHA256).Hash -cne $saved.final_hash){return $null}
        return $saved.record
    }catch{return $null}
}
function Save-MangaCompletedJob {
    param([string]$Path,[string]$Fingerprint,$Record)
    $temporary=$Path+'.tmp'
    @{fingerprint=$Fingerprint;record=$Record;final_hash=(Get-MangaFileHash -LiteralPath $Record.final -Algorithm SHA256).Hash}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Export-MangaFinalPage {
    param([string]$Source,[string]$Image,[string]$Directory)
    $stem=[IO.Path]::GetFileNameWithoutExtension($Source)
    $destination=Join-Path $Directory ($stem+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'-color.png')
    Copy-Item -LiteralPath $Image -Destination $destination
    return $destination
}

function Get-MangaRepairCrop {
    param($Bounds,[int]$Width,[int]$Height,[ValidateRange(0,1)][double]$Context=0.2)
    if($Width -lt 1 -or $Height -lt 1 -or [long]$Width*$Height -gt 120000000){throw 'Invalid repair canvas.'}
    foreach($name in @('x','y','width','height')){
        $value=$Bounds.$name
        if($value -isnot [ValueType] -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [double]$value -ne [Math]::Floor([double]$value)){throw 'Repair bounds must be finite integers.'}
    }
    if($Bounds.x -lt 0 -or $Bounds.y -lt 0 -or $Bounds.width -lt 1 -or $Bounds.height -lt 1 -or [long]$Bounds.x+$Bounds.width -gt $Width -or [long]$Bounds.y+$Bounds.height -gt $Height){throw 'Repair bounds lie outside the original page.'}
    $padding=[long][Math]::Ceiling([Math]::Max($Bounds.width,$Bounds.height)*$Context)
    $left=[Math]::Max(0,[long]$Bounds.x-$padding);$top=[Math]::Max(0,[long]$Bounds.y-$padding)
    $right=[Math]::Min($Width,[long]$Bounds.x+$Bounds.width+$padding);$bottom=[Math]::Min($Height,[long]$Bounds.y+$Bounds.height+$padding)
    return [pscustomobject]@{x=[int]$left;y=[int]$top;width=[int]($right-$left);height=[int]($bottom-$top)}
}
