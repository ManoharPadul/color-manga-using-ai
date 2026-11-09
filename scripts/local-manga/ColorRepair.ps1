function Get-RepairInkAlignment {
    param([string]$OriginalPath,[string]$ColorPath)
    $a=Get-ImageLabGrid -Path $OriginalPath -GridWidth 96 -GridHeight 96
    $b=Get-ImageLabGrid -Path $ColorPath -GridWidth 96 -GridHeight 96
    $ink=0;$matched=0
    for($y=1;$y -lt 95;$y++){for($x=1;$x -lt 95;$x++){
        $i=$y*96+$x
        if($a.pixels[$i][0] -ge 25){continue};$ink++;$found=$false
        for($dy=-1;$dy -le 1;$dy++){for($dx=-1;$dx -le 1;$dx++){if($b.pixels[($y+$dy)*96+$x+$dx][0] -lt 35){$found=$true}}}
        if($found){$matched++}
    }}
    return @{score=if($ink -ge 20){$matched/[double]$ink}else{$null};ink_samples=$ink;
        limitation='Sampled dark-line overlap with one-grid-cell tolerance; not an anatomy or pose validator.'}
}

function Composite-ColorRepair {
    param([string]$ColorPath,[string]$RepairPath,[string]$RegionMask,[string]$CandidateMask,
        [string]$ProtectionMask,[int[]]$Padding,[int]$Width,[int]$Height,$Bounds,[string[]]$ExclusionMasks=@(),[string]$MaskMode='Hard')
    $id=[Guid]::NewGuid().ToString('N');$names=@{}
    foreach($pair in @(@('color',$ColorPath),@('repair',$RepairPath),@('region',$RegionMask),@('candidate',$CandidateMask))){
        $names[$pair[0]]='repair-'+$id+'-'+$pair[0]+'.png'
        Copy-Item -LiteralPath $pair[1] -Destination (Join-Path $ComfyRoot ('input/'+$names[$pair[0]]))
    }
    $g=@{
        '1'=@{class_type='LoadImage';inputs=@{image=$names.color}}
        '2'=@{class_type='LoadImage';inputs=@{image=$names.repair}}
        '3'=@{class_type='LoadImage';inputs=@{image=$names.region}}
        '4'=@{class_type='ImageCrop';inputs=@{image=@('3',0);x=$Bounds.x;y=$Bounds.y;width=$Bounds.width;height=$Bounds.height}}
        '5'=@{class_type='ImageToMask';inputs=@{image=@('4',0);channel='red'}}
        '6'=@{class_type='ThresholdMask';inputs=@{mask=@('5',0);value=0.5}}
        '7'=@{class_type='LoadImage';inputs=@{image=$names.candidate}}
        '8'=@{class_type='ImageScale';inputs=@{image=@('7',0);upscale_method='nearest-exact';width=$Width;height=$Height;crop='disabled'}}
        '9'=@{class_type='ImageCrop';inputs=@{image=@('8',0);x=$Bounds.x;y=$Bounds.y;width=$Bounds.width;height=$Bounds.height}}
        '10'=@{class_type='ImageToMask';inputs=@{image=@('9',0);channel='red'}}
        '11'=@{class_type='MaskComposite';inputs=@{destination=@('6',0);source=@('10',0);x=0;y=0;operation='multiply'}}
        '20'=@{class_type='ImageCompositeMasked';inputs=@{destination=@('1',0);source=@('2',0);mask=@('11',0);x=$Bounds.x;y=$Bounds.y;resize_source=$false}}
        '21'=@{class_type='SaveImage';inputs=@{images=@('20',0);filename_prefix=('MangaColorAI/repair-'+$id)}}
    }
    if($ProtectionMask){
        $name='repair-'+$id+'-protection'+[IO.Path]::GetExtension($ProtectionMask)
        Copy-Item -LiteralPath $ProtectionMask -Destination (Join-Path $ComfyRoot ('input/'+$name))
        $header=[Drawing.Image]::FromFile($ProtectionMask)
        try{$crop=Get-MaskGeometry -Width $header.Width -Height $header.Height -Padding $Padding}finally{$header.Dispose()}
        $g.'12'=@{class_type='LoadImage';inputs=@{image=$name}}
        $g.'13'=@{class_type='ImageCrop';inputs=@{image=@('12',0);x=$crop.x;y=$crop.y;width=$crop.width;height=$crop.height}}
        $g.'14'=@{class_type='ImageScale';inputs=@{image=@('13',0);upscale_method='nearest-exact';width=$Width;height=$Height;crop='disabled'}}
        $g.'15'=@{class_type='ImageCrop';inputs=@{image=@('14',0);x=$Bounds.x;y=$Bounds.y;width=$Bounds.width;height=$Bounds.height}}
        $g.'16'=@{class_type='ImageToMask';inputs=@{image=@('15',0);channel='red'}}
        $g.'17'=@{class_type='ThresholdMask';inputs=@{mask=@('16',0);value=$(if($MaskMode -eq 'Soft'){0.0}else{0.5})}}
        $g.'18'=@{class_type='InvertMask';inputs=@{mask=@('17',0)}}
        $g.'19'=@{class_type='MaskComposite';inputs=@{destination=@('11',0);source=@('18',0);x=0;y=0;operation='multiply'}}
        $g.'20'.inputs.mask=@('19',0)
    }
    $next=100
    foreach($exclude in $ExclusionMasks){
        # Crop sequentially with the native CLI; do not retain many full-page masks in RAM.
        $name='repair-'+$id+'-exclude-'+$next+'.png'
        Crop-MangaImage -Source $exclude -Destination (Join-Path $ComfyRoot ('input/'+$name)) -X $Bounds.x -Y $Bounds.y -Width $Bounds.width -Height $Bounds.height
        $a=[string]$next;$b=[string]($next+1);$c=[string]($next+2);$d=[string]($next+3);$e=[string]($next+4)
        $g[$a]=@{class_type='LoadImage';inputs=@{image=$name}}
        $g[$b]=@{class_type='ImageToMask';inputs=@{image=@($a,0);channel='red'}}
        $g[$c]=@{class_type='ThresholdMask';inputs=@{mask=@($b,0);value=0.5}}
        $g[$d]=@{class_type='InvertMask';inputs=@{mask=@($c,0)}}
        $g[$e]=@{class_type='MaskComposite';inputs=@{destination=$g.'20'.inputs.mask;source=@($d,0);x=0;y=0;operation='multiply'}}
        $g.'20'.inputs.mask=@($e,0);$next+=5
    }
    $result=Invoke-ImageGraph -Graph $g
    $output=$ColorPath+'.repair-candidate.png'
    Save-GraphImage -Result $result -Node '21' -Destination $output
    return $output
}

function Invoke-ColorRegionRepairs {
    param([string]$SourcePath,[string]$ColorPath,[object[]]$Regions,$Report,[string]$ProtectionMask,[int[]]$MaskPadding,
        [int]$Width,[int]$Height,[hashtable]$ModelOptions,[int]$MaxRegions,[string]$WorkDirectory,$CurrentGrid,[string]$MaskMode='Hard')
    New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
    $records=@();$attempted=0;$accepted=0
    foreach($region in $Regions){
        $summary=@($Report.regions | Where-Object {$_.id -eq $region.id})[0]
        $record=@{id=$region.id;status='skipped';reason='Requires color intent, repair:true, a chromatic expected_color and measurable evidence.'}
        $records+=$record
        if(!$region.repair -or $region.intent -ne 'color' -or !$region.expected_color -or $summary.sample_count -lt 2){continue}
        if($attempted -ge $MaxRegions){$record.reason='Per-image repair attempt limit reached';continue}
        if($summary.protected_overlap_samples -gt 0){$record.reason='Protection mask overlaps this color region; review the protection mask first';continue}
        if($summary.semantic_overlap_samples -gt 0){$record.reason='Color region overlaps a neutral exclusion or another character/region; refine the masks first';continue}
        $expected=@(Get-CoverageLab -Color ([Drawing.ColorTranslator]::FromHtml($region.expected_color)) -Cache @{})
        if([Math]::Sqrt($expected[1]*$expected[1]+$expected[2]*$expected[2]) -lt 10){$record.reason='Expected palette color is intentionally neutral';continue}
        $mismatch=$null -ne $summary.mean_ab_distance_from_palette -and $summary.mean_ab_distance_from_palette -gt 25
        if($summary.neutral_samples -lt 2 -and !$mismatch){$record.reason='No sufficiently sampled missing color or palette mismatch';continue}
        $evidence=@($Report.components | Where-Object {$_.region_ids -contains $region.id -and $_.cause -eq 'A_model_left_region_neutral' -and $_.confidence -ge 0.7})
        if(!$mismatch -and !$evidence.Count){$record.reason='Missing-color cause is ambiguous or postprocessing-related; no AI retry';continue}
        $gw=$Report.grid_width;$gh=$Report.grid_height
        $mask=Get-CoverageMaskGrid -Path $region.mask -GridWidth $gw -GridHeight $gh -OriginalWidth $Width -OriginalHeight $Height
        $minx=$gw;$maxx=-1;$miny=$gh;$maxy=-1
        $candidate=New-Object Drawing.Bitmap $gw,$gh
        try{
            for($y=0;$y -lt $gh;$y++){for($x=0;$x -lt $gw;$x++){
                $pixel=$CurrentGrid.pixels[$y*$gw+$x]
                $c=[Math]::Sqrt($pixel[1]*$pixel[1]+$pixel[2]*$pixel[2])
                if($mask[$y*$gw+$x] -gt 127 -and $pixel[0] -gt 12 -and ($mismatch -or $c -lt 8)){$candidate.SetPixel($x,$y,[Drawing.Color]::White);$minx=[Math]::Min($minx,$x);$maxx=[Math]::Max($maxx,$x);$miny=[Math]::Min($miny,$y);$maxy=[Math]::Max($maxy,$y)}
            }}
            if($maxx -lt 0){$record.reason='Mask is below analysis resolution';continue}
            $attempted++;$dir=Join-Path $WorkDirectory ([string]$attempted);New-Item -ItemType Directory -Path $dir | Out-Null
            $candidatePath=Join-Path $dir 'candidate-mask.png';$candidate.Save($candidatePath,[Drawing.Imaging.ImageFormat]::Png)
        }finally{$candidate.Dispose()}
        $pad=[Math]::Min(256,[Math]::Max(32,[int][Math]::Ceiling([Math]::Max($Width,$Height)*0.02)))
        $x0=[Math]::Max(0,[int][Math]::Floor($minx*$Width/$gw)-$pad);$y0=[Math]::Max(0,[int][Math]::Floor($miny*$Height/$gh)-$pad)
        $x1=[Math]::Min($Width,[int][Math]::Ceiling(($maxx+1)*$Width/$gw)+$pad);$y1=[Math]::Min($Height,[int][Math]::Ceiling(($maxy+1)*$Height/$gh)+$pad)
        $bounds=@{x=$x0;y=$y0;width=($x1-$x0);height=($y1-$y0)};$crop=$bounds | ConvertTo-Json -Compress
        $record.bounds=$bounds;$record.work_directory=$dir;$record.status='rejected'
        try{
            $original=Join-Path $dir 'original-crop.png';$reference=Join-Path $dir 'color-context.png';$localMask=Join-Path $dir 'region-crop.png'
            foreach($item in @(@($SourcePath,$original),@($ColorPath,$reference),@($region.mask,$localMask))){Crop-MangaImage -Source $item[0] -Destination $item[1] -X $bounds.x -Y $bounds.y -Width $bounds.width -Height $bounds.height}
            $options=@{};foreach($key in $ModelOptions.Keys){$options[$key]=$ModelOptions[$key]}
            $options.Palette+=' Match the established colors in the surrounding reference. For '+$region.character+' '+$region.category+' use base color '+$region.expected_color+' with natural matte shading. Fill unintended gray gaps; preserve existing ink, shapes and expression.'
            $options.ReferenceImagePath=$reference
            $repaired=& "$PSScriptRoot/Colorize.ps1" -InputPath $original -OutputDirectory $dir @options
            $alignment=Get-RepairInkAlignment -OriginalPath $original -ColorPath $repaired.image
            $record.alignment=$alignment
            if($null -eq $alignment.score -or $alignment.score -lt 0.9){$record.reason='Insufficient or poorly aligned source ink; manual review required';continue}
            $a=Get-ImageLabGrid -Path $reference -GridWidth 64 -GridHeight 64
            $b=Get-ImageLabGrid -Path $repaired.image -GridWidth 64 -GridHeight 64
            $local=Get-CoverageMaskGrid -Path $localMask -GridWidth 64 -GridHeight 64 -OriginalWidth $bounds.width -OriginalHeight $bounds.height
            $count=0;$beforeDistance=0.0;$afterDistance=0.0;$oldGray=0;$newGray=0
            for($i=0;$i -lt 4096;$i++){if($local[$i] -le 127 -or $a.pixels[$i][0] -lt 12){continue};$count++
                $aa=$a.pixels[$i];$bb=$b.pixels[$i]
                $beforeDistance+=[Math]::Sqrt([Math]::Pow($aa[1]-$expected[1],2)+[Math]::Pow($aa[2]-$expected[2],2))
                $afterDistance+=[Math]::Sqrt([Math]::Pow($bb[1]-$expected[1],2)+[Math]::Pow($bb[2]-$expected[2],2))
                if([Math]::Sqrt($aa[1]*$aa[1]+$aa[2]*$aa[2]) -lt 8){$oldGray++}
                if([Math]::Sqrt($bb[1]*$bb[1]+$bb[2]*$bb[2]) -lt 8){$newGray++}
            }
            $record.validation=@{samples=$count;old_neutral=$oldGray;new_neutral=$newGray;before_ab_distance=$beforeDistance;after_ab_distance=$afterDistance}
            if($count -lt 4 -or $afterDistance -ge $beforeDistance -or ($afterDistance/[Math]::Max(1,$count)) -gt 25 -or (!$mismatch -and $newGray -ge $oldGray*0.8)){$record.reason='Candidate did not measurably improve neutral coverage and match the target palette';continue}
            $composite=Composite-ColorRepair -ColorPath $ColorPath -RepairPath $repaired.image -RegionMask $region.mask -CandidateMask $candidatePath `
                -ProtectionMask $ProtectionMask -Padding $MaskPadding -Width $Width -Height $Height -Bounds $bounds -ExclusionMasks @($Regions | Where-Object {$_.id -ne $region.id} | Select-Object -ExpandProperty mask) -MaskMode $MaskMode
            $composedGrid=Get-ImageLabGrid -Path $composite -GridWidth $gw -GridHeight $gh
            $improved=0;$examined=0
            for($i=0;$i -lt ($gw*$gh);$i++){
                if($mask[$i] -le 127 -or $CurrentGrid.pixels[$i][0] -le 12){continue}
                $old=$CurrentGrid.pixels[$i];$new=$composedGrid.pixels[$i]
                $oldC=[Math]::Sqrt($old[1]*$old[1]+$old[2]*$old[2])
                if(!$mismatch -and $oldC -ge 8){continue};$examined++
                $oldD=[Math]::Sqrt([Math]::Pow($old[1]-$expected[1],2)+[Math]::Pow($old[2]-$expected[2],2))
                $newD=[Math]::Sqrt([Math]::Pow($new[1]-$expected[1],2)+[Math]::Pow($new[2]-$expected[2],2))
                if($newD -lt $oldD-1){$improved++}
            }
            $record.validation.composited_improved_samples=$improved
            if($improved -lt [Math]::Max(1,$examined*0.2)){
                Move-Item -LiteralPath $composite -Destination (Join-Path $dir 'rejected-composite.png') -Force
                $record.reason='Final masked composite did not improve enough sampled target pixels';continue
            }
            Move-Item -LiteralPath $composite -Destination $ColorPath -Force
            $record.status='accepted';$record.reason='User-authorized region; better palette agreement and sampled ink alignment; inspect before publishing';$accepted++
        }catch{$record.reason=[string]$_}
    }
    return @{attempted=$attempted;repaired=$accepted;regions=$records;max_attempts=$MaxRegions;
        method='Context crop plus final masked compositing; not diffusion-mask conditioning or semantic segmentation.'}
}
