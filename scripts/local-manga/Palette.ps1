# A chapter palette is data only. Read it once per batch and reuse the resolved
# instructions; never learn colors from generated pages, which compounds drift.
function Read-DefaultMangaStyle {
    param([string]$Root)
    $path = Join-Path $Root 'manga-color-style.txt'
    return Read-MangaStyleFile -Path $path
}
function Read-MangaStyleFile {
    param([string]$Path)
    $path=[IO.Path]::GetFullPath($Path)
    $file = Get-Item -LiteralPath $path
    if ($file.Length -gt 64KB) { throw 'Color style file exceeds 64 KB.' }
    $style = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($style)) { throw "Color style file must contain a color description: $path" }
    return $style
}
function Read-ChapterPalette {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Palette file not found: $Path" }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt 64KB) { throw 'Palette file exceeds 64 KB.' }
    $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $data.PSObject.Properties['version'] -or $data.version -ne 1) { throw 'Palette version must be 1.' }
    if ($null -eq $data.PSObject.Properties['characters'] -or @($data.characters).Count -eq 0 -or @($data.characters).Count -gt 20) {
        throw 'Palette must define between 1 and 20 characters.'
    }
    $lines = @('CHAPTER COLOR RULES: Apply these same base colors in EVERY panel and EVERY page, including small background depictions. Match characters by appearance, not their position. Lighting may change shading but must not change base hair, eye, or clothing colors. Do not invent wardrobe changes. If an outfit changes visibly, match its own description below. Never add a character just because it appears in these rules.')
    $compact = @()
    foreach ($character in $data.characters) {
        foreach ($field in @('name','identify','hair','eyes','outfit')) {
            $property = $character.PSObject.Properties[$field]
            if ($null -eq $property -or $property.Value -isnot [string] -or
                [string]::IsNullOrWhiteSpace($property.Value) -or $property.Value.Length -gt 2000) {
                throw "Each character needs a non-empty $field string (maximum 2000 characters)."
            }
        }
        $lines += "Character $($character.name): identify by $($character.identify). Hair: $($character.hair). Eyes: $($character.eyes). Clothing/outfit rules: $($character.outfit). Keep these colors consistent in every matching panel."
        $compact += "$($character.name) ($($character.identify)): hair $($character.hair); eyes $($character.eyes); clothing $($character.outfit)."
        foreach ($optional in @('skin','skin_shadow','hair_shadow','lips')) {
            $property=$character.PSObject.Properties[$optional]
            if ($null -ne $property) {
                if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value) -or $property.Value.Length -gt 500) { throw "Optional $optional must be a nonempty string up to 500 characters." }
                $rule="$($character.name) $($optional.Replace('_',' ')): $($property.Value)."
                $lines+=$rule; $compact+=$rule
            }
        }
        $custom=$character.PSObject.Properties['region_colors']
        if ($null -ne $custom) {
            if ($custom.Value -isnot [pscustomobject] -or @($custom.Value.PSObject.Properties).Count -gt 20) { throw 'region_colors must be an object with at most 20 color descriptions.' }
            foreach ($color in $custom.Value.PSObject.Properties) {
                if ($color.Name.Length -gt 80 -or $color.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($color.Value) -or $color.Value.Length -gt 300) { throw 'Invalid custom palette color.' }
                $rule="$($character.name) $($color.Name): $($color.Value)."
                $lines+=$rule;$compact+=$rule
            }
        }
    }
    if ($null -ne $data.PSObject.Properties['scene'] -and $data.scene) {
        if ($data.scene -isnot [string] -or $data.scene.Length -gt 2000) { throw 'Scene must be a string of at most 2000 characters.' }
        $lines += "Scene palette: $($data.scene)"
        $compact += $data.scene
    }
    $reference = $null
    if ($null -ne $data.PSObject.Properties['reference_image'] -and $data.reference_image) {
        if ($data.reference_image -isnot [string]) { throw 'reference_image must be a file path string.' }
        $reference = $data.reference_image
        if (![IO.Path]::IsPathRooted($reference)) { $reference = Join-Path $file.DirectoryName $reference }
        $reference = (Get-Item -LiteralPath $reference).FullName
    }
    [pscustomobject]@{ Instruction=($lines -join "`n"); CompactInstruction=($compact -join ' '); Reference=$reference; Data=$data; File=$file.FullName }
}
