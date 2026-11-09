[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Colored,[string]$Regions,[string]$ProtectMask,
    [switch]$Apply,[switch]$DebugImages,[ValidateRange(0,1)][double]$Sensitivity=0.5,[ValidateRange(0,8)][int]$MaxAttempts=3,[int]$OwnerProcessId=0,[Parameter(Mandatory=$true)][string]$OutputDirectory)
. "$PSScriptRoot/TextWorkflow.ps1"
Set-MangaOwner -ProcessId $OwnerProcessId
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$normalized=Join-Path $OutputDirectory 'source.png';$null=ConvertTo-MangaPanelInput -Source $Source -Destination $normalized
if(!$Regions){$Regions=Find-MangaRegionAnnotation -Source $Source}
if(!$ProtectMask){$ProtectMask=Resolve-MangaProtection -Source $Source -Colored $Colored}
$argsList=@('coverage','--source',$normalized,'--colored',$Colored,'--output',(Join-Path $OutputDirectory 'pass-2'),'--sensitivity',$Sensitivity.ToString([Globalization.CultureInfo]::InvariantCulture),'--attempts',[string]$MaxAttempts)
if($Apply){$argsList+='--apply'};if($DebugImages){$argsList+='--debug'};if($Regions){$argsList+=@('--regions',$Regions)};if($ProtectMask){$argsList+=@('--protect',$ProtectMask)}
Invoke-MangaTextTool -Arguments $argsList
$reportPath=Join-Path $OutputDirectory 'pass-2/coverage.json';$data=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
$unified=$data.PSObject.Properties['unified_protection'];if($null -ne $unified -and $unified.Value -and (Test-Path -LiteralPath $unified.Value)){$ProtectMask=[string]$unified.Value}
Write-Host ('[QUALITY] '+$reportPath)
if($data.repairs_accepted -gt 0){
    $final=[string]$data.result
    @{source=$Source;base=$Colored;protection_mask=$ProtectMask;automatic_report=$reportPath}|ConvertTo-Json|Set-Content -LiteralPath ([IO.Path]::ChangeExtension($final,'.json')) -Encoding UTF8
    Write-Host ('[RESULT] '+$final)
}
