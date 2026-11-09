# Non-explicit synthetic color-patch fixture. CPU only; no model or network.
. "$PSScriptRoot/TextWorkflow.ps1"
Add-Type -AssemblyName System.Drawing
$root=Join-Path $AiRoot ('seam-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
foreach($name in @('source','base','mask')){
    $bitmap=[Drawing.Bitmap]::new(128,128);$g=[Drawing.Graphics]::FromImage($bitmap)
    try{
        if($name -eq 'base'){$g.Clear([Drawing.Color]::FromArgb(170,180,200));$brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(180,180,180));try{$g.FillRectangle($brush,32,32,64,64)}finally{$brush.Dispose()}}
        else{$g.Clear([Drawing.Color]::White)}
        $bitmap.Save((Join-Path $root ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)
    }finally{$g.Dispose();$bitmap.Dispose()}
}
$source=Join-Path $root 'source.png';$base=Join-Path $root 'base.png';$regions=Join-Path $root 'regions.json'
@{version=1;regions=@(@{id='synthetic-material';category='clothing';intent='color';color='#FFE4D5';confidence=1;mask='mask.png';palette_key='fixture/material'})}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $regions -Encoding UTF8
$before=(Get-MangaFileHash -LiteralPath $base).Hash
Invoke-MangaTextTool -Arguments @('coverage','--source',$source,'--colored',$base,'--regions',$regions,'--sensitivity','1','--apply','--debug','--output',(Join-Path $root 'pass-2'))
$report=Get-Content -LiteralPath (Join-Path $root 'pass-2/coverage.json') -Raw|ConvertFrom-Json
$region=$report.approved_regions[0]
if($report.repairs_accepted -ne 0 -or $report.repairs_rejected -ne 1 -or !$region.boundary_evidence.requires_boundary_review -or $report.changed_pixels -ne 0){throw 'Unsupported material boundary was silently accepted'}
if($region.audit.changed_outside_mask -ne 0 -or $region.audit.changed_protected_pixels -ne 0 -or (Get-MangaFileHash -LiteralPath $base).Hash -ne $before){throw 'Repair isolation/source invariant failed'}
$left=[Drawing.Bitmap]::new($base);$right=[Drawing.Bitmap]::new((Join-Path $root 'pass-2/repair-1-candidate.png'));$montage=[Drawing.Bitmap]::new(256,128);$g=[Drawing.Graphics]::FromImage($montage)
try{$g.DrawImageUnscaled($left,0,0);$g.DrawImageUnscaled($right,128,0);$montage.Save((Join-Path $root 'comparison.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$montage.Dispose();$left.Dispose();$right.Dispose()}
Write-Host ('PASS: unsupported boundary is review-only even if numeric seam scores pass; final image unchanged, exact outside/protection and source integrity. '+$root)
