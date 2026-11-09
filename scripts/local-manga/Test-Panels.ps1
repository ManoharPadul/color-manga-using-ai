$ErrorActionPreference='Stop'
. "$PSScriptRoot/Panels.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('mangacolorai-panel-tests-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
function Assert($Condition,$Message){if(!$Condition){throw $Message}}
$source=Join-Path $root '[source].png'
$b=[Drawing.Bitmap]::new(320,700);$b.SetResolution(144,144);$g=[Drawing.Graphics]::FromImage($b)
try{$g.Clear([Drawing.Color]::White);$g.FillRectangle([Drawing.Brushes]::Black,5,5,310,300);$g.FillRectangle([Drawing.Brushes]::Black,5,335,310,360);$b.Save($source)}finally{$g.Dispose();$b.Dispose()}
$p=Get-MangaStripPanels -Path $source
Assert ($p.Count -eq 2) 'Expected split at blank gutter.'
Assert (($p[0].height+$p[1].height) -eq 700) 'Strip coverage must be complete.'
$crops=@()
foreach($panel in $p){
 $dest=Join-Path $root ($panel.id+'.png');Export-MangaPanelCrop -Source $source -Panel $panel -Destination $dest
 $differentDpi=[Drawing.Bitmap]::new($dest);$differentDpi.SetResolution(96,96)
 $dpiPath=Join-Path $root ($panel.id+'-96dpi.png');try{$differentDpi.Save($dpiPath)}finally{$differentDpi.Dispose()};$crops+=$dpiPath
}
$final=Join-Path $root 'merged.png';Merge-MangaPanels -Source $source -Panels $p -Images $crops -Destination $final
$a=[Drawing.Bitmap]::new($source);$b=[Drawing.Bitmap]::new($final)
try{for($y=0;$y -lt 700;$y++){for($x=0;$x -lt 320;$x++){Assert ($a.GetPixel($x,$y).ToArgb() -eq $b.GetPixel($x,$y).ToArgb()) 'Crop/stitch must be pixel exact.'}}}finally{$a.Dispose();$b.Dispose()}
$plan=Join-Path $root 'panels.json'
@{version=1;approved=$true;width=320;height=700;panels=@(@{id='one';x=10;y=20;width=100;height=100;style='navy shirt'},@{id='two';x=120;y=20;width=100;height=100;style=''})}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $plan
$valid=Read-MangaPanelPlan -Path $plan -Width 320 -Height 700
Assert ($valid.Count -eq 2) 'Manual plan accepted.'
foreach($bad in @('overlap','bounds','fraction','duplicate','approval','dimensions')){
 $data=Get-Content -LiteralPath $plan -Raw|ConvertFrom-Json
 switch($bad){'overlap'{$data.panels[1].x=20};'bounds'{$data.panels[1].width=999};'fraction'{$data.panels[0].x=1.5};'duplicate'{$data.panels[1].id='one'};'approval'{$data.approved=$false};'dimensions'{$data.width=999}}
 $file=Join-Path $root ($bad+'.json');$data|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $file
 $failed=$false;try{$null=Read-MangaPanelPlan -Path $file -Width 320 -Height 700}catch{$failed=$true};Assert $failed ('Expected rejection: '+$bad)
}
# A line joining the two artworks must prevent a false gutter split.
$b=[Drawing.Bitmap]::new($source);$g=[Drawing.Graphics]::FromImage($b)
try{$g.DrawLine([Drawing.Pens]::Black,160,0,160,699);$b.Save((Join-Path $root 'connected.png'))}finally{$g.Dispose();$b.Dispose()}
$connected=Get-MangaStripPanels -Path (Join-Path $root 'connected.png')
Assert ($connected.Count -eq 1) 'Do not split through connecting art.'
Write-Host "PASS: geometry, 224000 exact pixels, literal paths, invalid plans, connected-art fallback. $root"
