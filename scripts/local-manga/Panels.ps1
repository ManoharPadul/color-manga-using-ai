# CPU-only geometry helpers for the external local-manga adapter.
Add-Type -AssemblyName System.Drawing

function New-MangaFullPagePlan {
    param([int]$Width,[int]$Height)
    if($Width -lt 1 -or $Height -lt 1 -or [long]$Width*$Height -gt 120000000){throw 'Full page must contain 1-120 million pixels.'}
    return [pscustomobject]@{id='page-01';x=0;y=0;width=$Width;height=$Height;style=''}
}

function ConvertTo-MangaPanelInput {
    param([string]$Source,[string]$Destination)
    $header=$null
    try {
        try{$header=[Drawing.Image]::FromFile($Source);$width=$header.Width;$height=$header.Height}
        catch{$info=Get-MangaImageInfo -Path $Source;$width=$info.width;$height=$info.height}
    }finally{if($header){$header.Dispose()}}
    if($width -lt 1 -or $height -lt 1 -or [long]$width*$height -gt 120000000){throw 'Panel input must contain 1-120 million pixels.'}
    try {
        Convert-MangaImage -Source $Source -Destination $Destination
    }catch{throw "Could not decode image '$Source' with MangaColorAI: $_"}
    $decoded=[Drawing.Bitmap]::new($Destination)
    try{if($decoded.Width -ne $width -or $decoded.Height -ne $height){throw 'Decoded image dimensions changed.'}}finally{$decoded.Dispose()}
    return [pscustomobject]@{width=$width;height=$height;path=$Destination}
}

function Get-MangaStripPanels {
    param([string]$Path)
    $img=[Drawing.Bitmap]::new($Path)
    try {
        if ([long]$img.Width*$img.Height -gt 120000000) { throw 'Panel input exceeds 120 megapixels.' }
        $sw=[Math]::Min(1200,$img.Width)
        $sh=[Math]::Max(1,[int][Math]::Round($img.Height*$sw/[double]$img.Width))
        $small=[Drawing.Bitmap]::new($sw,$sh)
        $g=[Drawing.Graphics]::FromImage($small)
        try { $g.DrawImage($img,0,0,$sw,$sh) } finally { $g.Dispose() }
        try {
            $gaps=@();$start=-1
            for($y=0;$y -lt $sh;$y++) {
                $dark=0
                for($x=0;$x -lt $sw;$x++) {
                    $p=$small.GetPixel($x,$y)
                    if([Math]::Min($p.R,[Math]::Min($p.G,$p.B)) -lt 245){$dark++}
                }
                # Almost completely blank, not merely a pale band through artwork.
                $blank=$dark -le [Math]::Floor($sw*0.001)
                if($blank -and $start -lt 0){$start=$y}
                if((!$blank -or $y -eq $sh-1) -and $start -ge 0){
                    $end=if($blank){$y+1}else{$y}
                    if($start -gt 0 -and $end -lt $sh -and $end-$start -ge 4){
                        $gaps+= [int][Math]::Round((($start+$end)/2.0)*$img.Height/$sh)
                    }
                    $start=-1
                }
            }
        } finally {$small.Dispose()}
        $cuts=@(0);$minHeight=[Math]::Max(128,[int]($img.Height*0.08))
        foreach($cut in $gaps){if($cut-$cuts[-1] -ge $minHeight -and $img.Height-$cut -ge $minHeight){$cuts+=$cut}}
        $cuts+=$img.Height
        if($cuts.Count -gt 14){return ,@([pscustomobject]@{id='page';x=0;y=0;width=$img.Width;height=$img.Height;style=''})}
        $panels=@()
        for($i=0;$i -lt $cuts.Count-1;$i++){
            $panels+=[pscustomobject]@{id=('strip-{0:d2}' -f ($i+1));x=0;y=$cuts[$i];width=$img.Width;height=($cuts[$i+1]-$cuts[$i]);style=''}
        }
        return ,$panels
    } finally {$img.Dispose()}
}

function Read-MangaPanelPlan {
    param([string]$Path,[int]$Width,[int]$Height,[switch]$AllowAutomatic)
    $file=Get-Item -LiteralPath $Path
    if($file.Length -gt 256KB){throw 'Panel plan exceeds 256KB.'}
    $plan=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if($plan.version -ne 1){throw 'Panel plan needs version 1.'}
    $approved=$plan.approved -is [bool] -and $plan.approved
    $automatic=$AllowAutomatic -and $plan.approved -is [bool] -and !$plan.approved
    if(!$approved -and !$automatic){throw 'Panel plan needs approved: true; an explicitly unapproved automatic match is allowed only for its current run.'}
    if($plan.width -ne $Width -or $plan.height -ne $Height){throw 'Panel plan dimensions must match original pixels.'}
    $panels=@($plan.panels)
    if($panels.Count -lt 1 -or $panels.Count -gt 64){throw 'Panel plan needs 1-64 panels.'}
    $ids=@{}
    $cast=@{}
    if($plan.PSObject.Properties['characters']){
        foreach($character in @($plan.characters)){
            if($character.id -notmatch '^[a-zA-Z0-9_-]{1,64}$' -or $cast.ContainsKey($character.id)){throw 'Character IDs must be unique safe names.'}
            foreach($field in @('identify','hair','eyes','outfit')){
                if($character.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($character.$field) -or $character.$field.Length -gt 2000){throw 'Each character needs identify, hair, eyes and outfit text (1-2000 characters).'}
            }
            $cast[$character.id]=$character
        }
        if($cast.Count -gt 20){throw 'Use at most 20 chapter characters.'}
    }
    foreach($p in $panels){
        if($p.id -notmatch '^[a-zA-Z0-9_-]{1,64}$' -or $ids.ContainsKey($p.id)){throw 'Panel IDs must be unique safe names.'}
        $ids[$p.id]=$true
        foreach($key in @('x','y','width','height')){
            $v=$p.$key
            if($null -eq $v -or $v -is [string] -or [double]$v -ne [Math]::Floor([double]$v)){throw 'Panel coordinates must be integers.'}
        }
        if($p.x -lt 0 -or $p.y -lt 0 -or $p.width -lt 1 -or $p.height -lt 1 -or [long]$p.x+$p.width -gt $Width -or [long]$p.y+$p.height -gt $Height){throw 'Panel rectangle outside source.'}
        if(!$p.PSObject.Properties['style']){$p | Add-Member NoteProperty style ''}
        if($p.style -isnot [string] -or $p.style.Length -gt 8000){throw 'Panel style must be text up to 8000 characters.'}
        if($p.PSObject.Properties['character_ids']){
            if(@($p.character_ids).Count -gt 20){throw 'Too many panel character assignments.'}
            foreach($characterId in @($p.character_ids)){
                if(!$cast.ContainsKey($characterId)){throw "Unknown assigned character: $characterId"}
                $c=$cast[$characterId]
                $p.style+=" Existing character ($($c.identify)): hair $($c.hair); both irises $($c.eyes); existing outfit $($c.outfit). Apply only to this matching existing character."
            }
        }
    }
    for($i=0;$i -lt $panels.Count;$i++){for($j=$i+1;$j -lt $panels.Count;$j++){
        $a=$panels[$i];$b=$panels[$j]
        if($a.x -lt $b.x+$b.width -and $b.x -lt $a.x+$a.width -and $a.y -lt $b.y+$b.height -and $b.y -lt $a.y+$a.height){throw 'Overlapping panel rectangles need manual separation; no ambiguous overwrite allowed.'}
    }}
    return ,$panels
}

function Export-MangaPanelCrop {
    param([string]$Source,[object]$Panel,[string]$Destination)
    $rect=[Drawing.Rectangle]::new([int]$Panel.x,[int]$Panel.y,[int]$Panel.width,[int]$Panel.height)
    $img=[Drawing.Bitmap]::new($Source)
    try {
        $crop=$img.Clone($rect,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {$crop.Save($Destination,[Drawing.Imaging.ImageFormat]::Png)}finally{$crop.Dispose()}
    }finally{$img.Dispose()}
}

function Merge-MangaPanels {
    param([string]$Source,[object[]]$Panels,[string[]]$Images,[string]$Destination)
    if($Panels.Count -ne $Images.Count){throw 'Missing panel result; source is retained.'}
    $canvas=[Drawing.Bitmap]::new($Source)
    try {
        $g=[Drawing.Graphics]::FromImage($canvas)
        try {
            $g.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceCopy
            for($i=0;$i -lt $Panels.Count;$i++){
                $p=$Panels[$i];$img=[Drawing.Bitmap]::new($Images[$i])
                try {
                    if($img.Width -ne $p.width -or $img.Height -ne $p.height){throw 'Panel result dimensions changed.'}
                    # Explicit pixel rectangles avoid source/result DPI changing placement.
                    $dest=[Drawing.Rectangle]::new([int]$p.x,[int]$p.y,[int]$p.width,[int]$p.height)
                    $g.DrawImage($img,$dest,0,0,$img.Width,$img.Height,[Drawing.GraphicsUnit]::Pixel)
                }finally{$img.Dispose()}
            }
        }finally{$g.Dispose()}
        $canvas.Save($Destination,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$canvas.Dispose()}
}
