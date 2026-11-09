[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Colored,[Parameter(Mandatory=$true)][string]$Mask,
    [Parameter(Mandatory=$true)][ValidatePattern('^#[0-9A-Fa-f]{6}$')][string]$Color,[ValidateRange(0,1)][double]$Strength=1,[string]$ProtectMask,
    [string]$Category='unspecified',[int]$OwnerProcessId=0,[Parameter(Mandatory=$true)][string]$OutputDirectory)
. "$PSScriptRoot/TextWorkflow.ps1"
if($Category -in @('text','intentional_uncolored')){throw 'This approved region is protected/uncolored; change its category explicitly before recoloring.'}
Set-MangaOwner -ProcessId $OwnerProcessId
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$normalized=Join-Path $OutputDirectory 'source.png';$null=ConvertTo-MangaPanelInput -Source $Source -Destination $normalized
if(!$ProtectMask){$ProtectMask=Resolve-MangaProtection -Source $Source -Colored $Colored}
$argsList=@('recolor','--source',$normalized,'--colored',$Colored,'--mask',$Mask,'--color',$Color,'--strength',$Strength.ToString([Globalization.CultureInfo]::InvariantCulture),'--output',(Join-Path $OutputDirectory 'repair'))
if($ProtectMask){$argsList+=@('--protect',$ProtectMask)}
Invoke-MangaTextTool -Arguments $argsList
$reportPath=Join-Path $OutputDirectory 'repair/repair-report.json'
Write-Host ('[QUALITY] '+$reportPath)
$report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
if($report.accepted){
    $final=Join-Path $OutputDirectory 'repair/recolored.png'
    @{category=$Category;source=$Source;base=$Colored;protection_mask=$ProtectMask;repair_report=$reportPath}|ConvertTo-Json|Set-Content -LiteralPath ([IO.Path]::ChangeExtension($final,'.json')) -Encoding UTF8
    Write-Host ('[CANDIDATE] '+$final)
    Write-Host '[REVIEWABLE] Numerical checks passed; preview and accept explicitly.'
}
else{Write-Host ('[CANDIDATE] '+(Join-Path $OutputDirectory 'repair/candidate.png'));Write-Host 'Candidate retained; no sufficient measured improvement. Base unchanged.'}
