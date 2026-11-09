# CPU-only integration checks. Never starts ComfyUI or loads ML models.
. "$PSScriptRoot/TextWorkflow.ps1"
. "$PSScriptRoot/Characters.ps1"
$root=Join-Path $AiRoot ('fidelity-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
Add-Type -AssemblyName System.Drawing
foreach($name in @('source','base','selection','protect')){
    $bmp=[Drawing.Bitmap]::new(64,64);$g=[Drawing.Graphics]::FromImage($bmp)
    try{
        switch($name){
            'source'{$g.Clear([Drawing.Color]::White);$g.DrawLine([Drawing.Pens]::Black,20,25,35,25)}
            'base'{$g.Clear([Drawing.Color]::Gray)}
            'selection'{$g.Clear([Drawing.Color]::Black);$g.FillRectangle([Drawing.Brushes]::White,16,16,24,24)}
            'protect'{$g.Clear([Drawing.Color]::Black);$g.FillRectangle([Drawing.Brushes]::White,18,18,3,3)}
        }
        $bmp.Save((Join-Path $root ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)
    }finally{$g.Dispose();$bmp.Dispose()}
}
$source=Join-Path $root 'source.png';$base=Join-Path $root 'base.png';$mask=Join-Path $root 'selection.png';$protect=Join-Path $root 'protect.png'
@{protection_mask=$protect}|ConvertTo-Json|Set-Content -LiteralPath ([IO.Path]::ChangeExtension($base,'.json')) -Encoding UTF8
if((Resolve-MangaProtection -Source $source -Colored $base) -ne $protect){throw 'Protection metadata not resolved.'}
@{version=1;regions=@(@{id='material';mask='selection.png';intent='color';expected_color='#E6B48C';confidence=1;palette_key='person-1/base'})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $root 'regions.json') -Encoding UTF8
$hash=(Get-MangaFileHash -LiteralPath $source).Hash
& "$PSScriptRoot/Studio-Quality.ps1" -Source $source -Colored $base -Regions (Join-Path $root 'regions.json') -OutputDirectory (Join-Path $root 'quality')
$quality=Get-Content -LiteralPath (Join-Path $root 'quality/report/quality.json') -Raw|ConvertFrom-Json
if($quality.coverage_percent -ne 0 -or $quality.protection_conflict_pixels -ne 9){throw 'Coverage or protection conflict counts incorrect.'}
& "$PSScriptRoot/Studio-PaletteRepair.ps1" -Source $source -Colored $base -Mask $mask -Color '#E6B48C' -OutputDirectory (Join-Path $root 'repair')
$report=Get-Content -LiteralPath (Join-Path $root 'repair/repair/repair-report.json') -Raw|ConvertFrom-Json
if(!$report.accepted -or $report.changed_outside_mask -ne 0 -or $report.changed_protected_pixels -ne 0){throw 'Repair acceptance/isolation failed.'}
if((Get-MangaFileHash -LiteralPath $source).Hash -ne $hash){throw 'Source changed.'}
$fixed=Join-Path $root 'repair/repair/recolored.png'
if((Resolve-MangaProtection -Source $source -Colored $fixed) -ne $protect){throw 'Repair lost protection metadata.'}
& "$PSScriptRoot/Studio-PaletteRepair.ps1" -Source $source -Colored $fixed -Mask $mask -Color '#E6B48C' -OutputDirectory (Join-Path $root 'repeat')
$repeat=Get-Content -LiteralPath (Join-Path $root 'repeat/repair/repair-report.json') -Raw|ConvertFrom-Json
if($repeat.accepted){throw 'Repeated no-improvement candidate accepted.'}
foreach($mode in @('geometry','texture')){
    & "$PSScriptRoot/Studio-Detail.ps1" -Source $source -Colored $base -Mask $mask -ProtectMask $protect -Mode $mode -OutputDirectory (Join-Path $root $mode)
    $detail=Get-Content -LiteralPath (Join-Path $root ($mode+'/detail/detail-report.json')) -Raw|ConvertFrom-Json
    if(!$detail.accepted -or $detail.changed_outside_mask -ne 0 -or $detail.changed_protected_pixels -ne 0 -or $detail.after.mean_source_gradient_error -ge $detail.before.mean_source_gradient_error){throw 'Source-detail metric or isolation failed.'}
}
$blocked=$false;try{& "$PSScriptRoot/Studio-PaletteRepair.ps1" -Source $source -Colored $base -Mask $mask -Color '#E6B48C' -Category intentional_uncolored -OutputDirectory (Join-Path $root 'blocked')}catch{$blocked=$true};if(!$blocked){throw 'Intentional uncolored category recolored.'}
$stageFile=Join-Path $root 'stages.json';@{version=1;stages=@(@{name='before';path=$base},@{name='after';path=$fixed})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $stageFile -Encoding UTF8
Invoke-MangaTextTool -Arguments @('quality','--source',$source,'--colored',$fixed,'--regions',(Join-Path $root 'regions.json'),'--protect',$protect,'--stages',$stageFile,'--output',(Join-Path $root 'stage-report'))
$stageReport=Get-Content -LiteralPath (Join-Path $root 'stage-report/quality.json') -Raw|ConvertFrom-Json
if(@($stageReport.stage_observations).Count -ne 2 -or $stageReport.stage_observations[0].report.coverage_percent -ne 0 -or $stageReport.stage_observations[1].report.coverage_percent -ne 100){throw 'Stage-by-stage final validation failed.'}
# Graph construction only, for every installed model variant.
foreach($variant in @(@{size='4B';precision='FP8'},@{size='4B';precision='BF16'},@{size='9B';precision='FP8'})){
    $graph=New-ColorizeGraph -ImageName 'fixture.png' -Instruction 'Color existing artwork' -Seed 42 -Megapixels 1.5 -SamplingSteps 4 -ModelSize $variant.size -Precision $variant.precision
    if($graph.'16'.inputs.steps -ne 4 -or $graph.'14'.inputs.noise_seed -ne 42 -or $graph.'2'.inputs.megapixels -ne 1.5){throw 'Baseline graph defaults changed.'}
}
$c=@{id='person-1';name='A';identify='round glasses';hair='black';eyes='brown';skin='tan';skin_tones=@{base='#D5A180';shadow='#B88065';highlight='';undertone=''};region_colors=@(@{name='fabric trim';color='#7A4954'});outfits=@()}
$profiles=Join-Path $root 'profiles.json';@{version=1;characters=@($c)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $profiles -Encoding UTF8
$compiled=Read-MangaCharacterProfiles -Path $profiles
if($compiled.instruction -notlike '*#B88065*' -or $compiled.instruction -notlike '*fabric trim*'){throw 'New palette slots not compiled.'}
$c.region_colors+=@{name='fabric trim';color='#AA9977'};@{version=1;characters=@($c)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $profiles -Encoding UTF8
$failed=$false;try{$null=Read-MangaCharacterProfiles -Path $profiles}catch{$failed=$true};if(!$failed){throw 'Duplicate region colors accepted.'}
Write-Host "PASS: full-resolution coverage, protected text, source integrity, CPU repair acceptance/rejection, palette schema, all three model graphs. Fixtures: $root"
