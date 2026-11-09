function Read-MangaCharacterProfiles {
    param([string]$Path)
    if((Get-Item -LiteralPath $Path).Length -gt 128KB){throw 'Character profiles exceed 128KB.'}
    $data=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    if($data.version -ne 1 -or @($data.characters).Count -lt 1 -or @($data.characters).Count -gt 20){throw 'Use version 1 with 1-20 characters.'}
    $ids=@{};$lines=@('Approved chapter identities. These character-specific colors override generic palette suggestions. Apply only to matching EXISTING people; never add a person or garment. Reuse each approved identity color on every identified appearance, including small inset panels. Keep the same existing outfit colors across all pages and panels. Lighting may shade a base color without changing its identity.')
    foreach($c in $data.characters){
        if($c.id -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $ids.ContainsKey($c.id)){throw 'Character IDs must be unique safe names.'};$ids[$c.id]=$true
        foreach($field in @('name','identify','hair','eyes','skin')){if($c.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($c.$field) -or $c.$field.Length -gt 2000){throw "Character $($c.id) needs $field text, up to 2000 characters."}}
        $line="Character $($c.id) ($($c.name)), identified by $($c.identify): hair $($c.hair); both irises $($c.eyes); consistent skin base $($c.skin). Preserve the original eye shape and keep closed eyes closed."
        if($c.PSObject.Properties['skin_tones']){
            foreach($key in @('base','shadow','highlight','undertone')){
                $property=$c.skin_tones.PSObject.Properties[$key];$value=if($property){$property.Value}else{$null}
                if($value){if($value -notmatch '^#[0-9A-Fa-f]{6}$'){throw 'Optional skin tones require #RRGGBB.'};$line+=" Established skin $key color $value; apply only where appropriate to existing shading."}
            }
        }
        if($c.PSObject.Properties['region_colors']){
            if(@($c.region_colors).Count -gt 32){throw 'Use at most 32 named region colors.'}
            $names=@{}
            foreach($entry in @($c.region_colors)){
                if([string]::IsNullOrWhiteSpace($entry.name) -or $entry.name.Length -gt 80 -or $names.ContainsKey($entry.name) -or $entry.color -notmatch '^#[0-9A-Fa-f]{6}$'){throw 'Named colors need unique names and #RRGGBB values.'}
                $names[$entry.name]=$true;$line+=" Existing matching region '$($entry.name)' uses $($entry.color); do not add or redraw regions."
            }
        }
        if(@($c.outfits).Count -gt 20){throw 'Use at most 20 outfit variants per character.'}
        $outfitNames=@{}
        $outfitIds=@{};$garmentColors=@{}
        foreach($o in @($c.outfits)){
            if($outfitNames.ContainsKey($o.name)){throw 'Outfit names must be unique per character.'};$outfitNames[$o.name]=$true
            foreach($field in @('name','identify','colors')){if($o.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($o.$field) -or $o.$field.Length -gt 2000){throw 'Each outfit needs name, identify and colors text.'}}
            if($o.PSObject.Properties['id'] -and $o.id){if($o.id -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $outfitIds.ContainsKey($o.id)){throw 'Outfit IDs must be unique safe names per person.'};$outfitIds[$o.id]=$true}
            if($o.PSObject.Properties['garments']){
                if(@($o.garments).Count -gt 32){throw 'At most 32 garments per outfit.'};$garmentIds=@{}
                foreach($g in @($o.garments)){
                    if($g.id -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $garmentIds.ContainsKey($g.id) -or [string]::IsNullOrWhiteSpace($g.name) -or [string]::IsNullOrWhiteSpace($g.identify) -or $g.color -notmatch '^#[0-9A-Fa-f]{6}$'){throw 'Garments need unique IDs, names, descriptions and hex colors.'}
                    $garmentIds[$g.id]=$true
                    if($garmentColors.ContainsKey($g.id) -and $garmentColors[$g.id] -ne $g.color){throw 'A reused garment ID must retain its approved color.'};$garmentColors[$g.id]=$g.color
                    $line+=" Existing garment '$($g.id)', identified by '$($g.identify)', retains approved base $($g.color); apply only when visible."
                }
            }
            $line+=" When the existing outfit matches '$($o.identify)' ($($o.name)), its base garment colors are $($o.colors). Do not impose this outfit on a different existing outfit."
        }
        $lines+=$line
    }
    return [pscustomobject]@{data=$data;instruction=($lines -join "`n")}
}
