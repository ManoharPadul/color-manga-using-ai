# CPU-only: synthetic clothed-region analogue, bubble and text-like strokes.
. "$PSScriptRoot/TextWorkflow.ps1"
Add-Type -AssemblyName System.Drawing
$root=Join-Path $AiRoot ('pass2-protection-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
foreach($name in @('source','base','region','text','bubble-protect-mask')){
    $bitmap=[Drawing.Bitmap]::new(137,193);$g=[Drawing.Graphics]::FromImage($bitmap)
    try{
        switch($name){
            'source'{$g.Clear([Drawing.Color]::White);$g.DrawRectangle([Drawing.Pens]::Black,10,12,116,168)}
            'base'{$g.Clear([Drawing.Color]::FromArgb(230,180,140));$g.DrawRectangle([Drawing.Pens]::Black,10,12,116,168);$g.FillRectangle([Drawing.Brushes]::Gray,30,110,12,12);$g.FillEllipse([Drawing.Brushes]::White,50,40,50,50);$g.DrawLine([Drawing.Pens]::Black,65,55,85,55);$g.DrawLine([Drawing.Pens]::Black,75,55,75,75)}
            'region'{$g.Clear([Drawing.Color]::Black);$g.FillRectangle([Drawing.Brushes]::White,20,25,90,130)}
            'text'{$g.Clear([Drawing.Color]::Black);$g.DrawLine([Drawing.Pens]::White,65,55,85,55);$g.DrawLine([Drawing.Pens]::White,75,55,75,75)}
            'bubble-protect-mask'{$g.Clear([Drawing.Color]::Black);$g.FillEllipse([Drawing.Brushes]::White,50,40,50,50)}
        }
        $bitmap.Save((Join-Path $root ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)
    }finally{$g.Dispose();$bitmap.Dispose()}
}
$source=Join-Path $root 'source.png';$base=Join-Path $root 'base.png';$text=Join-Path $root 'text.png';$regions=Join-Path $root 'regions.json';$output=Join-Path $root 'pass-2'
@{version=1;regions=@(@{id='approved-material';mask='region.png';category='skin';color='#E6B48C';confidence=1;intent='color';palette_key='person-1/skin'})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $regions -Encoding UTF8
$before=(Get-MangaFileHash -LiteralPath $source -Algorithm SHA256).Hash
Invoke-MangaTextTool -Arguments @('coverage','--source',$source,'--colored',$base,'--protect',$text,'--regions',$regions,'--output',$output,'--apply','--debug')
$report=Get-Content -LiteralPath (Join-Path $output 'coverage.json') -Raw|ConvertFrom-Json
if($report.repairs_accepted -ne 1){throw 'Synthetic missing patch was not accepted'}
if($report.approved_regions[0].suspected_pixels -ne 144){throw 'Bubble or text leaked into eligible missing-color selection'}
if($report.approved_regions[0].audit.changed_outside_mask -ne 0 -or $report.approved_regions[0].audit.changed_protected_pixels -ne 0){throw 'Exact repair invariants failed'}
if((Get-MangaFileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $before){throw 'Source changed'}
$original=[Drawing.Bitmap]::new($base);$result=[Drawing.Bitmap]::new([string]$report.result);$protect=[Drawing.Bitmap]::new((Join-Path $output 'unified-protection.png'))
try{
    $protectedChanges=0
    for($y=0;$y -lt 193;$y++){for($x=0;$x -lt 137;$x++){
        if($protect.GetPixel($x,$y).R -gt 0 -and $original.GetPixel($x,$y).ToArgb() -ne $result.GetPixel($x,$y).ToArgb()){$protectedChanges++}
    }}
    if($protectedChanges -ne 0){throw 'Protected exported pixels changed'}
    $montage=[Drawing.Bitmap]::new(274,193);$graphics=[Drawing.Graphics]::FromImage($montage)
    try{$graphics.DrawImageUnscaled($original,0,0);$graphics.DrawImageUnscaled($result,137,0);$montage.Save((Join-Path $root 'comparison.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$montage.Dispose()}
    @{fixture='synthetic only';missing_pixels=144;detected_missing_pixels=$report.approved_regions[0].suspected_pixels;eligible_false_positive_pixels=0;protected_pixel_changes=$protectedChanges;outside_mask_changes=$report.approved_regions[0].audit.changed_outside_mask;repairs_accepted=$report.repairs_accepted;repairs_rejected=$report.repairs_rejected;elapsed_seconds=$report.elapsed_seconds}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'metrics.json') -Encoding UTF8
}finally{$original.Dispose();$result.Dispose();$protect.Dispose()}
Write-Host ('Pass 2 protection tests passed: '+$root)
$profiles=Join-Path $root 'locked-profiles.json'
@{version=1;characters=@(@{id='person-1';skin='#123456'})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $profiles -Encoding UTF8
$conflict=Join-Path $root 'palette-conflict'
Invoke-MangaTextTool -Arguments @('coverage','--source',$source,'--colored',$base,'--protect',$text,'--regions',$regions,'--profiles',$profiles,'--output',$conflict,'--apply')
$blocked=Get-Content -LiteralPath (Join-Path $conflict 'coverage.json') -Raw|ConvertFrom-Json
if($blocked.repairs_accepted -ne 0 -or $blocked.changed_pixels -ne 0 -or $blocked.approved_regions[0].profile_palette_verified){throw 'Stale region color overrode authoritative character palette'}
Write-Host 'PASS: authoritative profile palette conflicts prevent automatic repair.'
$paleRegions=Get-Content -LiteralPath $regions -Raw|ConvertFrom-Json
$paleRegions.regions[0].color='#FFE4D5';$paleRegions|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $regions -Encoding UTF8
@{version=1;characters=@(@{id='person-1';skin='#FFE4D5'})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $profiles -Encoding UTF8
$pale=Join-Path $root 'pale-color'
Invoke-MangaTextTool -Arguments @('coverage','--source',$source,'--colored',$base,'--protect',$text,'--regions',$regions,'--profiles',$profiles,'--sensitivity','1','--output',$pale,'--apply')
$paleReport=Get-Content -LiteralPath (Join-Path $pale 'coverage.json') -Raw|ConvertFrom-Json
if($paleReport.repairs_attempted -ne 1 -or $paleReport.repairs_accepted -ne 1 -or $paleReport.approved_regions[0].classification -eq 'intentional_white_gray'){throw 'Approved pale peach incorrectly skipped as neutral or repair rejected'}
Write-Host 'PASS: approved pale peach at sensitivity 1 is evaluated for repair, not classified as intentional white/gray.'
$duplicate=$paleRegions.regions[0]|ConvertTo-Json -Depth 8|ConvertFrom-Json;$duplicate.id='same-approved-material';$paleRegions.regions=@($paleRegions.regions[0],$duplicate);$paleRegions|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $regions -Encoding UTF8
$overlap=Join-Path $root 'compatible-overlap'
Invoke-MangaTextTool -Arguments @('coverage','--source',$source,'--colored',$base,'--protect',$text,'--regions',$regions,'--profiles',$profiles,'--sensitivity','1','--output',$overlap,'--apply')
$overlapReport=Get-Content -LiteralPath (Join-Path $overlap 'coverage.json') -Raw|ConvertFrom-Json
if($overlapReport.repairs_accepted -ne 1 -or $overlapReport.final_measurements.ambiguous_region_overlap_pixels -ne 0){throw 'Identical approved material overlap incorrectly prevented repair'}
Write-Host 'PASS: same-identity/material/palette overlap is evaluated once without an ambiguous-overlap diagnosis.'
