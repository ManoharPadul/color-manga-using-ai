[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Colored,[Parameter(Mandatory=$true)][string]$Mask,
    [ValidateSet('geometry','texture')][string]$Mode='geometry',[ValidateRange(0,1)][double]$Strength=1,[string]$ProtectMask,[int]$OwnerProcessId=0,[Parameter(Mandatory=$true)][string]$OutputDirectory)
. "$PSScriptRoot/TextWorkflow.ps1"
Set-MangaOwner -ProcessId $OwnerProcessId
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$normalized=Join-Path $OutputDirectory 'source.png';$null=ConvertTo-MangaPanelInput -Source $Source -Destination $normalized
if(!$ProtectMask){$ProtectMask=Resolve-MangaProtection -Source $Source -Colored $Colored}
$argsList=@('detail','--source',$normalized,'--colored',$Colored,'--mask',$Mask,'--mode',$Mode,'--strength',$Strength.ToString([Globalization.CultureInfo]::InvariantCulture),'--output',(Join-Path $OutputDirectory 'detail'))
if($ProtectMask){$argsList+=@('--protect',$ProtectMask)}
Invoke-MangaTextTool -Arguments $argsList
$reportPath=Join-Path $OutputDirectory 'detail/detail-report.json';$report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
Write-Host ('[QUALITY] '+$reportPath)
if($report.accepted){
    $final=Join-Path $OutputDirectory 'detail/corrected.png'
    @{source=$Source;base=$Colored;protection_mask=$ProtectMask;detail_report=$reportPath}|ConvertTo-Json|Set-Content -LiteralPath ([IO.Path]::ChangeExtension($final,'.json')) -Encoding UTF8
    Write-Host ('[CANDIDATE] '+$final);Write-Host '[REVIEWABLE] Source-detail metric improved; preview before accepting.'
}else{Write-Host ('[CANDIDATE] '+(Join-Path $OutputDirectory 'detail/candidate.png'));Write-Host 'Numerical gate rejected correction; base unchanged.'}
