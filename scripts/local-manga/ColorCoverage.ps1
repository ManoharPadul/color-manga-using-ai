# Bounded, sampled diagnostics for the existing 8-bit RGB model boundary.
# Low chroma alone is never treated as a semantic label or permission to repair.
function Get-CoverageAnalysisSize {
    param([ValidateRange(1,2147483647)][int]$Width,[ValidateRange(1,2147483647)][int]$Height,[ValidateRange(1,4096)][int]$MaxSide)
    # Both operands must be doubles: Min(1, fractionalRatio) selects an integer
    # overload in Windows PowerShell and collapses large-page grids to 1x1.
    $ratio=[Math]::Min(1.0,$MaxSide/[double][Math]::Max($Width,$Height))
    return [pscustomobject]@{width=[Math]::Max(1,[int][Math]::Round($Width*$ratio));height=[Math]::Max(1,[int][Math]::Round($Height*$ratio))}
}
function Get-CoverageLab {
    param([Drawing.Color]$Color, [hashtable]$Cache)
    $key=$Color.ToArgb()
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    $rgb=@(($Color.R/255.0),($Color.G/255.0),($Color.B/255.0))
    for ($i=0;$i -lt 3;$i++) { $v=$rgb[$i]; $rgb[$i]=if ($v -le 0.04045) {$v/12.92} else {[Math]::Pow(($v+0.055)/1.055,2.4)} }
    $xyz=@(((0.4124564*$rgb[0]+0.3575761*$rgb[1]+0.1804375*$rgb[2])/0.95047),
        (0.2126729*$rgb[0]+0.7151522*$rgb[1]+0.0721750*$rgb[2]),
        ((0.0193339*$rgb[0]+0.1191920*$rgb[1]+0.9503041*$rgb[2])/1.08883))
    for ($i=0;$i -lt 3;$i++) { $v=$xyz[$i]; $xyz[$i]=if ($v -gt 0.008856451679) {[Math]::Pow($v,1.0/3)} else {7.787037037*$v+16.0/116} }
    $lab=@((116*$xyz[1]-16),(500*($xyz[0]-$xyz[1])),(200*($xyz[1]-$xyz[2])))
    if ($Cache.Count -lt 40000) { $Cache[$key]=$lab }
    return $lab
}

function Get-ImageLabGrid {
    param([string]$Path,[int]$GridWidth,[int]$GridHeight)
    Add-Type -AssemblyName System.Drawing
    $bitmap=[Drawing.Bitmap]::FromFile($Path)
    $values=New-Object 'object[]' ($GridWidth*$GridHeight)
    $cache=@{}
    try {
        for ($y=0;$y -lt $GridHeight;$y++) { for ($x=0;$x -lt $GridWidth;$x++) {
            $px=[Math]::Min($bitmap.Width-1,[int][Math]::Floor(($x+0.5)*$bitmap.Width/$GridWidth))
            $py=[Math]::Min($bitmap.Height-1,[int][Math]::Floor(($y+0.5)*$bitmap.Height/$GridHeight))
            $values[$y*$GridWidth+$x]=@(Get-CoverageLab -Color $bitmap.GetPixel($px,$py) -Cache $cache)
        } }
        return [pscustomobject]@{width=$GridWidth;height=$GridHeight;pixels=$values;image_width=$bitmap.Width;image_height=$bitmap.Height}
    } finally { $bitmap.Dispose() }
}

function Get-CoverageMaskGrid {
    param([string]$Path,[int]$GridWidth,[int]$GridHeight,[int]$OriginalWidth,[int]$OriginalHeight,[int[]]$Padding=@(0,0,0,0))
    $values=New-Object 'byte[]' ($GridWidth*$GridHeight)
    if (!$Path) { return ,$values }
    $bitmap=[Drawing.Bitmap]::FromFile($Path)
    try {
        $geometry=Get-MaskGeometry -Width $bitmap.Width -Height $bitmap.Height -Padding $Padding
        for ($y=0;$y -lt $GridHeight;$y++) { for ($x=0;$x -lt $GridWidth;$x++) {
            $ox=[Math]::Floor(($x+0.5)*$OriginalWidth/$GridWidth);$oy=[Math]::Floor(($y+0.5)*$OriginalHeight/$GridHeight)
            $mx=$geometry.x+[Math]::Min($geometry.width-1,[int][Math]::Floor(($ox+0.5)*$geometry.width/$OriginalWidth))
            $my=$geometry.y+[Math]::Min($geometry.height-1,[int][Math]::Floor(($oy+0.5)*$geometry.height/$OriginalHeight))
            $values[$y*$GridWidth+$x]=$bitmap.GetPixel($mx,$my).R
        } }
    } finally {$bitmap.Dispose()}
    return ,$values
}

function Read-ColorRegions {
    param([string]$Path,[int]$Width,[int]$Height,$PaletteData)
    if (!$Path) { return }
    $file=Get-Item -LiteralPath $Path
    if ($file.Length -gt 64KB) { throw 'Color region JSON exceeds 64 KB.' }
    $data=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.version -ne 1 -or @($data.regions).Count -gt 32) { throw 'Color regions require version 1 and at most 32 regions.' }
    $seen=@{}
    foreach ($region in $data.regions) {
        if ($region.id -isnot [string] -or [string]::IsNullOrWhiteSpace($region.id) -or $region.id.Length -gt 80 -or $seen.ContainsKey($region.id)) { throw 'Color region IDs must be nonempty and unique (maximum 80 characters).' }
        $seen[$region.id]=$true
        if ($region.category -notin @('skin','face','neck','arms','hands','torso','legs','feet','hair','eyes','lips','clothing','accessories','background','artwork')) { throw 'Unsupported color region category.' }
        if ($region.intent -notin @('color','neutral','exclude')) { throw 'Region intent must be color, neutral or exclude.' }
        $mask=if ([IO.Path]::IsPathRooted($region.mask)) {$region.mask} else {Join-Path $file.DirectoryName $region.mask}
        $mask=(Get-Item -LiteralPath $mask).FullName
        $header=[Drawing.Image]::FromFile($mask)
        try { if ($header.Width -ne $Width -or $header.Height -ne $Height) { throw 'Color region masks must match original image dimensions.' } } finally {$header.Dispose()}
        $expected=$null
        if ($null -ne $region.PSObject.Properties['expected_color']) {
            if ($region.expected_color -isnot [string] -or $region.expected_color -notmatch '^#[0-9a-fA-F]{6}$') { throw 'expected_color must be a six-digit hex color.' }
            $expected=$region.expected_color
        }
        $repair=$false
        if ($null -ne $region.PSObject.Properties['repair']) {
            if ($region.repair -isnot [bool]) { throw 'repair must be true or false.' }
            $repair=$region.repair
        }
        $character=''
        if ($null -ne $region.PSObject.Properties['character']) {
            if ($region.character -isnot [string] -or $region.character.Length -gt 120) { throw 'character must be a short identifier.' }
            $character=$region.character
        }
        if (!$expected -and $PaletteData -and $character) {
            $people=@($PaletteData.characters | Where-Object {$_.name -eq $character})
            if ($people.Count -eq 1) {
                $person=$people[0];$description=$null
                $custom=$person.PSObject.Properties['region_colors']
                if ($null -ne $custom -and $null -ne $custom.Value.PSObject.Properties[$region.id]) { $description=$custom.Value.PSObject.Properties[$region.id].Value }
                $field=switch ($region.category) {'face' {'skin'} 'neck' {'skin'} 'arms' {'skin'} 'hands' {'skin'} 'torso' {'skin'} 'legs' {'skin'} 'feet' {'skin'} default {$region.category}}
                if (!$description -and $null -ne $person.PSObject.Properties[$field]) { $description=$person.PSObject.Properties[$field].Value }
                if ($description -is [string] -and $description -match '#[0-9a-fA-F]{6}') { $expected=$Matches[0] }
            }
        }
        $intent=$region.intent
        if ($intent -eq 'color' -and $expected) {
            $lab=@(Get-CoverageLab -Color ([Drawing.ColorTranslator]::FromHtml($expected)) -Cache @{})
            if ([Math]::Sqrt($lab[1]*$lab[1]+$lab[2]*$lab[2]) -lt 8) { $intent='neutral' }
        }
        [pscustomobject]@{id=$region.id;category=$region.category;intent=$intent;mask=$mask;expected_color=$expected;repair=$repair;character=$character}
    }
}

function Measure-ColorCoverage {
    param($Original,$Raw,$Before,$Final,[object[]]$Regions=@(),[string]$ProtectionMask,
        [int[]]$MaskPadding=@(0,0,0,0),[ValidateSet('Hard','Soft')][string]$ProtectionMaskMode='Hard',[int]$Width,[int]$Height,[string]$DebugDirectory)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $gw=$Final.width;$gh=$Final.height;$n=$gw*$gh
    $protected=Get-CoverageMaskGrid -Path $ProtectionMask -GridWidth $gw -GridHeight $gh -OriginalWidth $Width -OriginalHeight $Height -Padding $MaskPadding
    if($ProtectionMaskMode -eq 'Hard'){for($i=0;$i -lt $n;$i++){if($protected[$i] -le 127){$protected[$i]=0}else{$protected[$i]=255}}}
    $eligible=New-Object 'bool[]' $n;$neutral=New-Object 'bool[]' $n
    $owners=New-Object 'object[]' $n;$chroma=New-Object 'double[]' $n;$rawChroma=New-Object 'double[]' $n
    $regionMasks=@{}
    foreach ($region in $Regions) {
        $mask=Get-CoverageMaskGrid -Path $region.mask -GridWidth $gw -GridHeight $gh -OriginalWidth $Width -OriginalHeight $Height
        $regionMasks[$region.id]=$mask
        for ($i=0;$i -lt $n;$i++) { if ($mask[$i] -gt 127) {
            if ($region.intent -ne 'color') {$neutral[$i]=$true} elseif ($null -eq $owners[$i]) {$eligible[$i]=$true;$owners[$i]=$region.id} else {$owners[$i]='__overlap__'}
        } }
    }
    $candidate=New-Object 'bool[]' $n;$causes=New-Object 'object[]' $n
    $eligibleCount=0;$missingCount=0;$maskLoss=0;$postLoss=0
    for ($i=0;$i -lt $n;$i++) {
        $f=$Final.pixels[$i];$r=$Raw.pixels[$i];$b=$Before.pixels[$i];$o=$Original.pixels[$i]
        $chroma[$i]=[Math]::Sqrt($f[1]*$f[1]+$f[2]*$f[2])
        $rawChroma[$i]=[Math]::Sqrt($r[1]*$r[1]+$r[2]*$r[2])
        $beforeChroma=[Math]::Sqrt($b[1]*$b[1]+$b[2]*$b[2])
        if ($eligible[$i] -and $owners[$i] -ne '__overlap__' -and !$neutral[$i] -and $protected[$i] -eq 0 -and $f[0] -gt 12) {$eligibleCount++}
        if ($neutral[$i] -or $f[0] -le 12) {continue}
        if ($chroma[$i] -lt 8) {
            if ($protected[$i] -gt 0) {
                if ($beforeChroma -ge 12 -and $eligible[$i]) {$candidate[$i]=$true;$causes[$i]='B_protection_restored_gray';$maskLoss++}
                continue
            }
            $candidate[$i]=$true
            if ($beforeChroma -ge 12 -or $rawChroma[$i] -ge 12) {$causes[$i]='C_color_lost_in_processing';$postLoss++}
            elseif ($eligible[$i] -and [Math]::Abs($f[0]-$o[0]) -lt 25) {$causes[$i]='A_model_left_region_neutral'}
            else {$causes[$i]='E_ambiguous_neutral'}
            if ($eligible[$i] -and $owners[$i] -ne '__overlap__') {$missingCount++}
        }
    }
    # Bounded four-connected components on the analysis grid, not semantic segmentation.
    $visited=New-Object 'bool[]' $n;$components=New-Object 'System.Collections.Generic.List[object]'
    for ($start=0;$start -lt $n;$start++) {
        if (!$candidate[$start] -or $visited[$start]) {continue}
        $queue=New-Object 'System.Collections.Generic.Queue[int]';$queue.Enqueue($start);$visited[$start]=$true
        $count=0;$minx=$gw;$miny=$gh;$maxx=0;$maxy=0;$kinds=@{};$ownerSet=@{};$neighbors=0;$coloredNeighbors=0;$isEligible=0
        while ($queue.Count) {
            $i=$queue.Dequeue();$x=$i%$gw;$y=[int][Math]::Floor($i/$gw)
            $count++;$minx=[Math]::Min($minx,$x);$maxx=[Math]::Max($maxx,$x);$miny=[Math]::Min($miny,$y);$maxy=[Math]::Max($maxy,$y)
            $kinds[$causes[$i]]=1
            if ($owners[$i]) {$ownerSet[$owners[$i]]=1;$isEligible++}
            $adj=@();if($x -gt 0){$adj+=($i-1)};if($x -lt $gw-1){$adj+=($i+1)};if($y -gt 0){$adj+=($i-$gw)};if($y -lt $gh-1){$adj+=($i+$gw)}
            foreach ($j in $adj) {
                if ($candidate[$j] -and !$visited[$j] -and $causes[$j] -eq $causes[$start] -and $owners[$j] -eq $owners[$start]) {$visited[$j]=$true;$queue.Enqueue($j)}
                elseif (!$candidate[$j] -and !$neutral[$j] -and $protected[$j] -eq 0) {$neighbors++;if($chroma[$j] -ge 12){$coloredNeighbors++}}
            }
        }
        $confidence=0.25
        if ($isEligible -eq $count -and $ownerSet.Count -eq 1 -and !$ownerSet.ContainsKey('__overlap__')) {$confidence=0.7}
        if ($neighbors -gt 0 -and $coloredNeighbors/[double]$neighbors -ge 0.5) {$confidence=[Math]::Min(0.95,$confidence+0.15)}
        if ($kinds.ContainsKey('B_protection_restored_gray')) {$confidence=0.95}
        if ($count -lt 2) {$confidence=[Math]::Min($confidence,0.5)}
        $components.Add(@{sample_count=$count;cause=$causes[$start];confidence=$confidence;region_ids=@($ownerSet.Keys);
            bounds=@{x=[int][Math]::Floor($minx*$Width/$gw);y=[int][Math]::Floor($miny*$Height/$gh);
                width=[int][Math]::Ceiling(($maxx-$minx+1)*$Width/$gw);height=[int][Math]::Ceiling(($maxy-$miny+1)*$Height/$gh)};
            action=if($kinds.ContainsKey('B_protection_restored_gray')){'review protection overlap; never override protected text automatically'}else{'review semantic region and palette before repair'}})
    }
    $summaries=@()
    foreach ($region in $Regions) {
        $mask=$regionMasks[$region.id];$total=0;$missing=0;$overlap=0;$semanticOverlap=0;$sumA=0.0;$sumB=0.0;$colorCount=0
        for ($i=0;$i -lt $n;$i++) {if($mask[$i] -le 127){continue};$total++
            if($protected[$i] -gt 0){$overlap++;continue}
            if($region.intent -eq 'color' -and ($neutral[$i] -or $owners[$i] -eq '__overlap__')){$semanticOverlap++;continue}
            if($neutral[$i] -or $Final.pixels[$i][0] -le 12){continue}
            if($chroma[$i] -lt 8){$missing++}else{$sumA+=$Final.pixels[$i][1];$sumB+=$Final.pixels[$i][2];$colorCount++}
        }
        $mismatch=$null
        if ($region.expected_color -and $colorCount -gt 0) {
            $expected=@(Get-CoverageLab -Color ([Drawing.ColorTranslator]::FromHtml($region.expected_color)) -Cache @{})
            $mismatch=[Math]::Round([Math]::Sqrt([Math]::Pow($sumA/$colorCount-$expected[1],2)+[Math]::Pow($sumB/$colorCount-$expected[2],2)),2)
        }
        $summaries+=@{id=$region.id;category=$region.category;intent=$region.intent;sample_count=$total;neutral_samples=$missing;protected_overlap_samples=$overlap;
            semantic_overlap_samples=$semanticOverlap;
            interpretation=if($region.intent -ne 'color'){'D_declared_intentional_or_excluded'}else{'manual color-eligible artwork'};
            expected_color=$region.expected_color;mean_ab_distance_from_palette=$mismatch;repair_authorized=$region.repair}
    }
    $debug=@{}
    if($DebugDirectory) {
        $heat=New-Object Drawing.Bitmap $gw,$gh;$segment=New-Object Drawing.Bitmap $gw,$gh;$candidateImage=New-Object Drawing.Bitmap $gw,$gh
        try {for($y=0;$y -lt $gh;$y++){for($x=0;$x -lt $gw;$x++){$i=$y*$gw+$x
            $c=if($candidate[$i]){[Drawing.Color]::OrangeRed}else{[Drawing.Color]::Black};$heat.SetPixel($x,$y,$c)
            $c=if($protected[$i] -gt 0){[Drawing.Color]::Blue}elseif($neutral[$i]){[Drawing.Color]::Gray}elseif($eligible[$i]){[Drawing.Color]::LimeGreen}else{[Drawing.Color]::Black};$segment.SetPixel($x,$y,$c)
            $c=if($candidate[$i] -and $eligible[$i] -and $owners[$i] -ne '__overlap__' -and $causes[$i] -eq 'A_model_left_region_neutral'){[Drawing.Color]::White}else{[Drawing.Color]::Black};$candidateImage.SetPixel($x,$y,$c)
        }}
        $debug.heatmap=Join-Path $DebugDirectory 'uncolored-candidate-heatmap.png';$debug.regions=Join-Path $DebugDirectory 'manual-region-preview.png'
        $heat.Save($debug.heatmap,[Drawing.Imaging.ImageFormat]::Png);$segment.Save($debug.regions,[Drawing.Imaging.ImageFormat]::Png)
        $debug.candidate_mask=Join-Path $DebugDirectory 'eligible-candidate-mask.png';$candidateImage.Save($debug.candidate_mask,[Drawing.Imaging.ImageFormat]::Png)
        }finally{$heat.Dispose();$segment.Dispose();$candidateImage.Dispose()}
    }
    return [pscustomobject]@{version=1;analysis='sampled CIELAB D65/sRGB heuristic; not semantic segmentation';grid_width=$gw;grid_height=$gh;
        eligible_samples=$eligibleCount;estimated_uncolored_percent=if($eligibleCount){[Math]::Round(100.0*$missingCount/$eligibleCount,2)}else{$null};
        declared_neutral_or_excluded_samples=@($neutral | Where-Object {$_}).Count;protected_samples=@($protected | Where-Object {$_ -gt 0}).Count;
        neutral_samples_restored_by_protection=$maskLoss;possible_postprocess_loss_samples=$postLoss;components=@($components.ToArray());regions=$summaries;
        repaired=0;skipped=0;unresolved=$components.Count;analysis_seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3);debug=$debug;
        limitation='Only manually declared color-eligible artwork has a percentage. Unknown neutral areas are review candidates, not failures. Thin/sub-grid regions may be missed.'}
}
