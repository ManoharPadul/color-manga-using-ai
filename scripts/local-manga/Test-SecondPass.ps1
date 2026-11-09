# Entirely CPU-only; no backend/model startup.
. "$PSScriptRoot/TextWorkflow.ps1"
Add-Type -AssemblyName System.Drawing
$root=Join-Path $AiRoot ('second-pass-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
foreach($name in @('source','base','skin','neutral','protect')){
    $bmp=[Drawing.Bitmap]::new(64,64);$g=[Drawing.Graphics]::FromImage($bmp)
    try{
        switch($name){
            'source'{$g.Clear([Drawing.Color]::White);$g.DrawRectangle([Drawing.Pens]::Black,15,15,25,25);$g.DrawLine([Drawing.Pens]::Black,20,25,35,25)}
            'base'{$g.Clear([Drawing.Color]::Gray);$g.DrawRectangle([Drawing.Pens]::Black,15,15,25,25);$g.DrawLine([Drawing.Pens]::Black,20,25,35,25);$g.FillRectangle([Drawing.Brushes]::LightGray,44,44,12,12)}
            'skin'{$g.Clear([Drawing.Color]::Black);$g.FillRectangle([Drawing.Brushes]::White,16,16,24,24)}
            'neutral'{$g.Clear([Drawing.Color]::Black);$g.FillRectangle([Drawing.Brushes]::White,44,44,12,12)}
            'protect'{$g.Clear([Drawing.Color]::Black);$g.FillRectangle([Drawing.Brushes]::White,18,18,3,3)}
        }
        $bmp.Save((Join-Path $root ($name+'.png')),[Drawing.Imaging.ImageFormat]::Png)
    }finally{$g.Dispose();$bmp.Dispose()}
}
$source=Join-Path $root 'source.png';$base=Join-Path $root 'base.png';$protect=Join-Path $root 'protect.png';$annotation=Join-Path $root 'regions.json'
$skin=@{id='arm';mask='skin.png';category='skin';intent='color';color='#E6B48C';confidence=1;palette_key='p1/skin'}
$gray=@{id='gray-shirt';mask='neutral.png';category='clothing';intent='neutral';color='#808080';confidence=1}
@{version=1;regions=@($skin,$gray)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $annotation -Encoding UTF8
$sourceHash=(Get-MangaFileHash -LiteralPath $source).Hash
$baseHash=(Get-MangaFileHash -LiteralPath $base).Hash
foreach($case in @('preview','apply','limit-zero','no-approved-regions','uncertain','background','black-palette','white-clothing','overlap')){
    $output=Join-Path $root $case
    $arguments=@('coverage','--source',$source,'--colored',$base,'--protect',$protect,'--output',$output,'--debug')
    if($case -ne 'no-approved-regions'){$arguments+=@('--regions',$annotation)}
    if($case -ne 'preview'){$arguments+='--apply'}
    if($case -eq 'limit-zero'){$arguments+=@('--attempts','0')}
    if($case -eq 'uncertain'){$skin.confidence=0.5;@{version=1;regions=@($skin,$gray)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $annotation -Encoding UTF8}
    if($case -eq 'background'){$skin.confidence=1;$skin.category='background';@{version=1;regions=@($skin,$gray)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $annotation -Encoding UTF8}
    if($case -eq 'black-palette'){$skin.confidence=1;$skin.category='hair';$skin.color='#000000';@{version=1;regions=@($skin,$gray)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $annotation -Encoding UTF8}
    if($case -eq 'white-clothing'){$skin.category='clothing';$skin.color='#FFFFFF';@{version=1;regions=@($skin,$gray)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $annotation -Encoding UTF8}
    if($case -eq 'overlap'){$skin.category='skin';$skin.color='#E6B48C';$gray.mask='skin.png';@{version=1;regions=@($skin,$gray)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $annotation -Encoding UTF8}
    Invoke-MangaTextTool -Arguments $arguments
    $report=Get-Content -LiteralPath (Join-Path $output 'coverage.json') -Raw|ConvertFrom-Json
    if($case -eq 'apply'){
        if($report.repairs_attempted -ne 1 -or $report.repairs_accepted -ne 1 -or $report.changed_pixels -lt 1){throw 'Approved missing color not repaired.'}
        $audit=$report.approved_regions[0].audit
        if($audit.changed_outside_mask -ne 0 -or $audit.changed_protected_pixels -ne 0){throw 'Repair escaped its mask or protection.'}
        $a=[Drawing.Bitmap]::new($base);$b=[Drawing.Bitmap]::new([string]$report.result)
        try{if($a.Size -ne $b.Size){throw 'Dimensions changed.'};if($a.GetPixel(48,48) -ne $b.GetPixel(48,48)){throw 'Intentional gray clothing changed.'};if($a.GetPixel(18,18) -ne $b.GetPixel(18,18)){throw 'Protected text changed.'};if($a.GetPixel(2,2) -ne $b.GetPixel(2,2)){throw 'Outside selection changed.'}}finally{$a.Dispose();$b.Dispose()}
    }elseif($report.repairs_attempted -ne 0 -or $report.changed_pixels -ne 0){throw "Conservative no-op failed: $case"}
}
if((Get-MangaFileHash -LiteralPath $source).Hash -ne $sourceHash -or (Get-MangaFileHash -LiteralPath $base).Hash -ne $baseHash){throw 'An original input was overwritten.'}
$bounds=[pscustomobject]@{x=0;y=10;width=20;height=30};$crop=Get-MangaRepairCrop -Bounds $bounds -Width 64 -Height 64 -Context 0.5
if($crop.x -ne 0 -or $crop.y -ne 0 -or $crop.width -ne 35 -or $crop.height -ne 55){throw 'Context crop expansion incorrect.'}
$failed=$false;try{$null=Get-MangaRepairCrop -Bounds ([pscustomobject]@{x=60;y=0;width=10;height=10}) -Width 64 -Height 64}catch{$failed=$true};if(!$failed){throw 'Outside crop accepted.'}
Write-Host "PASS: two-pass CPU repair, preview-only, gray clothing, protection, exact isolation, unchanged inputs, attempt cap, uncertain/unknown-category rejection and contextual crop. $root"
