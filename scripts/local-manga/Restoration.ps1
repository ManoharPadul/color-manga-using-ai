# CPU image nodes only: restoration is independent of the diffusion checkpoint.
function New-RegionProtectionMask {
    param([string]$Path,[int]$Width,[int]$Height,[string]$Destination)
    $file=Get-Item -LiteralPath $Path
    if ($file.Length -gt 64KB) { throw 'Protection regions file exceeds 64 KB.' }
    $data=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.version -ne 1 -or @($data.regions).Count -lt 1 -or @($data.regions).Count -gt 200) { throw 'Protection JSON requires version 1 and 1..200 regions.' }
    foreach ($region in $data.regions) {
        foreach ($key in @('x','y','width','height')) {
            $value=$region.PSObject.Properties[$key]
            if ($null -eq $value -or $value.Value -isnot [ValueType] -or [double]$value.Value -ne [Math]::Floor([double]$value.Value)) { throw "Region $key must be an integer." }
        }
        if ($region.x -lt 0 -or $region.y -lt 0 -or $region.width -le 0 -or $region.height -le 0 -or
            ([long]$region.x+$region.width) -gt $Width -or ([long]$region.y+$region.height) -gt $Height) { throw 'Protection rectangle is outside the original image.' }
        if ($region.kind -notin @('text','bubble','panel-border','structure')) { throw 'Unknown protection region kind.' }
        if ($region.kind -eq 'structure' -and ($null -eq $region.PSObject.Properties['alignment_verified'] -or $region.alignment_verified -ne $true)) { throw 'Structural protection requires alignment_verified: true after inspecting generated alignment.' }
    }
    Add-Type -AssemblyName System.Drawing
    $bitmap=New-Object Drawing.Bitmap $Width,$Height
    $g=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.Clear([Drawing.Color]::Black)
        foreach ($region in $data.regions) { $g.FillRectangle([Drawing.Brushes]::White,[int]$region.x,[int]$region.y,[int]$region.width,[int]$region.height) }
        $bitmap.Save($Destination,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose();$bitmap.Dispose() }
}

function Get-MaskGeometry {
    param([int]$Width, [int]$Height, [int[]]$Padding = @(0,0,0,0))
    if ($Padding.Count -ne 4 -or @($Padding | Where-Object { $_ -lt 0 }).Count) { throw 'Mask padding must be four nonnegative integers: left, top, right, bottom.' }
    $w=[long]$Width-$Padding[0]-$Padding[2]
    $h=[long]$Height-$Padding[1]-$Padding[3]
    if ($w -le 0 -or $h -le 0) { throw 'Mask padding removes the entire image.' }
    return @{width=[int]$w; height=[int]$h; x=$Padding[0]; y=$Padding[1]}
}

function Invoke-ImageGraph {
    param($Graph, [int]$TimeoutSeconds=900)
    $body=@{prompt=$Graph; client_id=('mangacolorai-post-'+[Guid]::NewGuid().ToString('N'))} | ConvertTo-Json -Depth 30
    $queued=Invoke-RestMethod "$Api/prompt" -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $history=Invoke-RestMethod "$Api/history/$($queued.prompt_id)" -TimeoutSec 30
        $entry=$history.PSObject.Properties[$queued.prompt_id]
        if ($null -ne $entry) {
            if ($entry.Value.status.status_str -eq 'error') { throw ('Image restoration failed: '+($entry.Value.status.messages | ConvertTo-Json -Depth 15 -Compress)) }
            if ($entry.Value.status.completed) { return $entry.Value }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Image processing timed out: $($queued.prompt_id). The queued job was not interrupted."
}

function Save-GraphImage {
    param($Result, [string]$Node, [string]$Destination)
    $img=$Result.outputs.PSObject.Properties[$Node].Value.images[0]
    $query='filename='+[Uri]::EscapeDataString($img.filename)+'&subfolder='+[Uri]::EscapeDataString($img.subfolder)+'&type=output'
    Save-LocalImage -Uri "$Api/view?$query" -Destination $Destination
}

function Restore-OriginalRegions {
    param([string]$SourcePath, [string]$ColorPath, [string]$MaskPath,
        [int]$Width, [int]$Height, [int[]]$Padding=@(0,0,0,0),
        [ValidateSet('Hard','Soft')][string]$MaskMode='Hard', [string]$DebugDirectory,
        [int]$TimeoutSeconds=900)
    Add-Type -AssemblyName System.Drawing
    if ($Width -le 0 -or $Height -le 0 -or ([long]$Width*$Height) -gt 256000000) { throw 'Invalid restoration dimensions (maximum 256 megapixels).' }
    foreach ($path in @($SourcePath,$ColorPath)) {
        $header=$null
        try {
            try {$header=[Drawing.Image]::FromFile($path);$actualWidth=$header.Width;$actualHeight=$header.Height}
            catch {$info=Get-MangaImageInfo -Path $path;$actualWidth=$info.width;$actualHeight=$info.height}
            if ($actualWidth -ne $Width -or $actualHeight -ne $Height) { throw 'Restore source and color result must already match original dimensions.' }
        } finally { if($header){$header.Dispose()} }
    }
    $maskHeader=[Drawing.Image]::FromFile($MaskPath)
    try { $maskWidth=$maskHeader.Width; $maskHeight=$maskHeader.Height } finally { $maskHeader.Dispose() }
    $crop=Get-MaskGeometry -Width $maskWidth -Height $maskHeight -Padding $Padding
    $id=[Guid]::NewGuid().ToString('N')
    $names=@{}
    foreach ($pair in @(@('source',$SourcePath),@('color',$ColorPath),@('mask',$MaskPath))) {
        $name='restore-'+$id+'-'+$pair[0]+[IO.Path]::GetExtension($pair[1])
        Copy-Item -LiteralPath $pair[1] -Destination (Join-Path $ComfyRoot ('input/'+$name))
        $names[$pair[0]]=$name
    }
    $graph=@{
        '1'=@{class_type='LoadImage';inputs=@{image=$names.source}}
        '2'=@{class_type='LoadImage';inputs=@{image=$names.color}}
        '3'=@{class_type='LoadImage';inputs=@{image=$names.mask}}
        '4'=@{class_type='ImageCrop';inputs=@{image=@('3',0);x=$crop.x;y=$crop.y;width=$crop.width;height=$crop.height}}
        '5'=@{class_type='ImageScale';inputs=@{image=@('4',0);upscale_method='nearest-exact';width=$Width;height=$Height;crop='disabled'}}
        '6'=@{class_type='ImageToMask';inputs=@{image=@('5',0);channel='red'}}
        '7'=@{class_type='ThresholdMask';inputs=@{mask=@('6',0);value=0.5}}
        '8'=@{class_type='ImageCompositeMasked';inputs=@{destination=@('2',0);source=@('1',0);mask=@('7',0);x=0;y=0;resize_source=$false}}
        '9'=@{class_type='SaveImage';inputs=@{images=@('8',0);filename_prefix=('MangaColorAI/restored-'+$id)}}
    }
    if ($MaskMode -eq 'Soft') { $graph.'8'.inputs.mask=@('6',0) }
    if ($DebugDirectory) {
        $graph.'10'=@{class_type='MaskToImage';inputs=@{mask=$graph.'8'.inputs.mask}}
        $graph.'11'=@{class_type='SaveImage';inputs=@{images=@('10',0);filename_prefix=('MangaColorAI/mask-'+$id)}}
    }
    Write-Host "Restoring original pixels AFTER output resize: $Width x $Height; mask $maskWidth x $maskHeight; padding $($Padding -join ','); mode $MaskMode."
    $result=Invoke-ImageGraph -Graph $graph -TimeoutSeconds $TimeoutSeconds
    $restored=$ColorPath+'.restored.png'
    Save-GraphImage -Result $result -Node '9' -Destination $restored
    Move-Item -LiteralPath $restored -Destination $ColorPath -Force
    if ($DebugDirectory) { Save-GraphImage -Result $result -Node '11' -Destination (Join-Path $DebugDirectory 'protection-mask-original-space.png') }
    return @{status='restored';coordinate_space='original';mask_width=$maskWidth;mask_height=$maskHeight;
        padding=$Padding;content_width=$crop.width;content_height=$crop.height;
        scale_x=($Width/[double]$crop.width);scale_y=($Height/[double]$crop.height);mode=$MaskMode}
}
