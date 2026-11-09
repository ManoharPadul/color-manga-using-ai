[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Colored,[string]$Raw,[string]$Regions,[string]$ProtectMask,
    [ValidateRange(0,1)][double]$Sensitivity=0.5,[int]$OwnerProcessId=0,[Parameter(Mandatory=$true)][string]$OutputDirectory)
. "$PSScriptRoot/TextWorkflow.ps1"
Set-MangaOwner -ProcessId $OwnerProcessId
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$normalized=Join-Path $OutputDirectory 'source.png';$null=ConvertTo-MangaPanelInput -Source $Source -Destination $normalized
if(!$Regions){$Regions=Find-MangaRegionAnnotation -Source $Source}
if(!$ProtectMask){$ProtectMask=Resolve-MangaProtection -Source $Source -Colored $Colored}
$argsList=@('quality','--source',$normalized,'--colored',$Colored,'--output',(Join-Path $OutputDirectory 'report'))
if($Raw){$argsList+=@('--raw',$Raw)};if($Regions){$argsList+=@('--regions',$Regions)};if($ProtectMask){$argsList+=@('--protect',$ProtectMask)}
Invoke-MangaTextTool -Arguments $argsList
Write-Host ('[QUALITY] '+(Join-Path $OutputDirectory 'report/quality.json'))

$reportPath=Join-Path $OutputDirectory 'report/quality.json'
$autoDir=Join-Path $OutputDirectory 'suggestions'
$autoArgs=@('coverage','--source',$normalized,'--colored',$Colored,'--output',$autoDir,'--debug','--attempts','0','--sensitivity',$Sensitivity.ToString([Globalization.CultureInfo]::InvariantCulture))
if($Regions){$autoArgs+=@('--regions',$Regions)};if($ProtectMask){$autoArgs+=@('--protect',$ProtectMask)}
Invoke-MangaTextTool -Arguments $autoArgs
$report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
$report|Add-Member -NotePropertyName automatic -NotePropertyValue (Get-Content -LiteralPath (Join-Path $autoDir 'coverage.json') -Raw|ConvertFrom-Json) -Force
$report|ConvertTo-Json -Depth 24|Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host ('[QUALITY] '+$reportPath)
