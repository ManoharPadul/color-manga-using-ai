. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Panels.ps1"
$root=Join-Path $AiRoot ('panel-format-tests/'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$source=Join-Path $root 'fixture.png'
$b=[Drawing.Bitmap]::new(171,239);$g=[Drawing.Graphics]::FromImage($b)
try{$g.Clear([Drawing.Color]::White);$g.FillRectangle([Drawing.Brushes]::Black,11,20,87,93);$b.Save($source)}finally{$g.Dispose();$b.Dispose()}
foreach($ext in @('png','jpg','jpeg','webp','bmp','tif','tiff','gif','tga','ppm','pgm','pbm','pnm')){
    $input=Join-Path $root ('input [test].'+$ext)
    Convert-MangaImage -Source $source -Destination $input
    $hash=(Get-MangaFileHash -LiteralPath $input).Hash
    $normalized=Join-Path $root ($ext+'-decoded.png')
    $result=ConvertTo-MangaPanelInput -Source $input -Destination $normalized
    if($result.width -ne 171 -or $result.height -ne 239){throw "Dimensions lost: $ext"}
    $panels=Get-MangaStripPanels -Path $normalized
    $crop=Join-Path $root ($ext+'-crop.png');Export-MangaPanelCrop -Source $normalized -Panel $panels[0] -Destination $crop
    Merge-MangaPanels -Source $normalized -Panels $panels -Images @($crop) -Destination (Join-Path $root ($ext+'-assembled.png'))
    if((Get-MangaFileHash -LiteralPath $input).Hash -ne $hash){throw "Source modified: $ext"}
    Write-Host "PASS $ext : decode, crop, assemble, dimensions and unchanged source."
}
Write-Host "Format fixtures: $root"
