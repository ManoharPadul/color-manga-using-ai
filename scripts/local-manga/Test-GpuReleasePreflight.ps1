# All backend calls are mocked. No server launch, network call or model load.
. "$PSScriptRoot/TextWorkflow.ps1"
$script:started=0;$script:freed=0;$script:active=$false
function Start-LocalBackend {$script:started++}
function Test-LocalBackend {return $true}
function Invoke-RestMethod {
    param([string]$Uri,[string]$Method,[string]$ContentType,[string]$Body,[int]$TimeoutSec)
    if($script:started -lt 1){throw 'Backend queried before startup preflight'}
    if($Uri.EndsWith('/queue')){return [pscustomobject]@{queue_running=@($(if($script:active){'owned-external-job'}));queue_pending=@()}}
    if($Uri.EndsWith('/free')){$script:freed++;return @{}}
    if($Uri.EndsWith('/system_stats')){return [pscustomobject]@{devices=@([pscustomobject]@{torch_vram_total=0})}}
    throw 'Unexpected endpoint'
}
Release-MangaGpu
if($script:started -ne 1 -or $script:freed -ne 1){throw 'Idle startup/release ordering incorrect'}
$script:active=$true;$blocked=$false
try{Release-MangaGpu}catch{$blocked=$true}
if(!$blocked -or $script:freed -ne 1){throw 'Active queue was not preserved'}
Write-Host 'PASS: startup precedes queue access; active queue blocks memory release. Mock-only, no inference.'
