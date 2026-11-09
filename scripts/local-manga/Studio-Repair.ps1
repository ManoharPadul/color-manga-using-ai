[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Colored,
    [Parameter(Mandatory=$true)][string]$Mask,[Parameter(Mandatory=$true)][string]$StyleFile,
    [int]$OwnerProcessId=0,
    [string]$ProtectMask,
    [ValidateRange(0,1)][double]$Context=0.2,
    [switch]$RestoreSourceInk,
    [ValidatePattern('^#[0-9A-Fa-f]{6}$')][string]$ExpectedColor,
    [ValidateSet('9B FP8','4B FP8','4B BF16')][string]$Model='9B FP8',
    [ValidateRange(1,50)][int]$Steps=4,[ValidateRange(0,2147483647)][long]$Seed=42,
    [ValidateRange(0.1,4)][double]$Megapixels=1.5,[Parameter(Mandatory=$true)][string]$OutputDirectory)
. "$PSScriptRoot/TextWorkflow.ps1"
. "$PSScriptRoot/Studio-Jobs.ps1"
Set-MangaOwner -ProcessId $OwnerProcessId
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$lock=$null
try{
    $lock=Open-MangaRunLock -Directory $AiRoot -OutputDirectory $OutputDirectory
    Wait-MangaControl
    $null=[IO.Directory]::CreateDirectory($OutputDirectory)
    $normalized=Join-Path $OutputDirectory 'source.png'
    $null=ConvertTo-MangaPanelInput -Source $Source -Destination $normalized
    if(!$ProtectMask){$ProtectMask=Resolve-MangaProtection -Source $Source -Colored $Colored}
    $validation=@('audit','--source',$normalized,'--base',$Colored,'--candidate',$Colored,'--mask',$Mask,'--output',(Join-Path $OutputDirectory 'input-audit.json'))
    if($ProtectMask){$validation+=@('--protect',$ProtectMask)}
    Invoke-MangaTextTool -Arguments $validation
    $preflight=Get-Content -LiteralPath (Join-Path $OutputDirectory 'input-audit.json') -Raw|ConvertFrom-Json
    if($preflight.selected_pixels_evaluated -lt 1){throw 'No eligible unprotected pixels in the repair mask.'}
    $boundsPath=[IO.Path]::ChangeExtension($Mask,'.bounds.json')
    $panel=$null;$modelSource=$normalized
    if(Test-Path -LiteralPath $boundsPath){
        $panel=Get-Content -LiteralPath $boundsPath -Raw|ConvertFrom-Json
        $header=[Drawing.Bitmap]::new($normalized)
        try{$panel=Get-MangaRepairCrop -Bounds $panel -Width $header.Width -Height $header.Height -Context $Context}finally{$header.Dispose()}
        $modelSource=Join-Path $OutputDirectory 'crop.png';Export-MangaPanelCrop -Source $normalized -Panel $panel -Destination $modelSource
    }
    $parts=$Model -split ' '

    $result=& "$PSScriptRoot/Colorize.ps1" -InputPath $modelSource -OutputDirectory (Join-Path $OutputDirectory 'candidate') -StyleFile $StyleFile -ModelSize $parts[0] -Precision $parts[1] -Steps $Steps -Seed $Seed -Megapixels $Megapixels -Quality Fast -Consistency 0 -Strength 1 -PromptStyle Minimal -NoOpen
    Wait-MangaControl
    $ink=$result.image
    if($RestoreSourceInk){$ink=Join-Path $OutputDirectory 'candidate-original-ink.png';Invoke-MangaTextTool -Arguments @('ink','--source',$modelSource,'--colored',$result.image,'--output',$ink)}
    if($panel){
        $page=Join-Path $OutputDirectory 'candidate-page.png'
        Merge-MangaPanels -Source $Colored -Panels @($panel) -Images @($ink) -Destination $page
        $ink=$page
    }
    $final=Join-Path $OutputDirectory 'repaired.png'
    $compositeArgs=@('composite','--base',$Colored,'--candidate',$ink,'--mask',$Mask,'--output',$final)
    if($ProtectMask){$compositeArgs+=@('--protect',$ProtectMask)}
    Invoke-MangaTextTool -Arguments $compositeArgs
    $auditPath=Join-Path $OutputDirectory 'repair-audit.json'
    $auditArgs=@('audit','--source',$normalized,'--base',$Colored,'--candidate',$final,'--mask',$Mask,'--output',$auditPath)
    if($ProtectMask){$auditArgs+=@('--protect',$ProtectMask)}
    if($ExpectedColor){$auditArgs+=@('--color',$ExpectedColor)}
    Invoke-MangaTextTool -Arguments $auditArgs
    $audit=Get-Content -LiteralPath $auditPath -Raw|ConvertFrom-Json
    Write-Host ('[QUALITY] '+$auditPath)
    @{protection_mask=$ProtectMask;source=$Source;base=$Colored;mask=$Mask;candidate=$ink;final=$final;requires_visual_review=$true}|ConvertTo-Json|Set-Content -LiteralPath ([IO.Path]::ChangeExtension($final,'.json')) -Encoding UTF8
    if($audit.accepted -or $audit.safe_to_preview){Write-Host ('[CANDIDATE] '+$final);Write-Host '[REVIEWABLE] Inspect source geometry before accepting; current image unchanged.'}else{Write-Warning ('Candidate rejected: '+$audit.reason)}
}finally{Close-MangaRunLock -Handle $lock -Directory $AiRoot}
