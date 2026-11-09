param(
    [Parameter(Position = 0)][string]$InputDirectory,
    [string]$Palette,
    [string]$StyleFile,
    [ValidateRange(0, 2147483647)][long]$Seed = 42,
    [ValidateRange(0.1, 4.0)][double]$Megapixels = 0.7,
    [ValidateRange(0,50)][int]$Steps=0,
    [ValidateSet('Fast','Detailed','BaseExperimental')][string]$Quality = 'Fast',
    [ValidateRange(0.2,1.0)][double]$Strength = 1.0,
    [ValidateRange(0,1.5)][double]$Consistency = 0,
    [ValidateSet('Auto','FP8','BF16')][string]$Precision = 'Auto',
    [ValidateSet('Preserve','Short','Minimal')][string]$PromptStyle = 'Preserve',
    [string]$OutputDirectory,
    [string]$PaletteFile,
    [ValidateSet('4B','9B')][string]$ModelSize = '4B',
    [switch]$Recurse,
    [switch]$DebugOutput,
    [ValidateSet('Off','Report','Repair')][string]$CoverageMode='Report',
    [ValidateRange(1,3)][int]$MaxRepairRegions=1,
    [switch]$ListOnly,
    [ValidateSet('Off','AutoGutters')][string]$PanelMode='Off',
    [switch]$Resume
)
. "$PSScriptRoot/Common.ps1"
if($StyleFile){
    if($PSBoundParameters.ContainsKey('Palette')){throw 'Choose -StyleFile or -Palette, not both.'}
    $Palette=Read-MangaStyleFile -Path $StyleFile
    Write-Host ('Color style file: '+[IO.Path]::GetFullPath($StyleFile))
}elseif (!$PSBoundParameters.ContainsKey('Palette')) { $Palette = Read-DefaultMangaStyle -Root $RepoRoot }
if ($Quality -eq 'Detailed' -and !$PSBoundParameters.ContainsKey('Megapixels')) { $Megapixels=1.5 }
if ($Quality -eq 'Detailed' -and !$PSBoundParameters.ContainsKey('PromptStyle')) { $PromptStyle='Minimal' }
if ($Quality -eq 'Detailed' -and !$PSBoundParameters.ContainsKey('Consistency') -and (Test-Path (Join-Path $AiRoot 'models/loras/f2k_4B_consist_20260314.safetensors'))) { $Consistency=0.4 }
if ([string]::IsNullOrWhiteSpace($InputDirectory)) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a folder of non-explicit manga images to colorize'
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return }
        $InputDirectory = $dialog.SelectedPath
    } finally { $dialog.Dispose() }
}
$folder = Get-Item -LiteralPath $InputDirectory
if (!$folder.PSIsContainer) { throw 'Choose a folder, not an image file.' }
$sourceRoot = $folder.FullName.TrimEnd('\','/')
$chapterPalette = $null
$referencePath = $null
if ($PaletteFile) {
    $chapterPalette = Read-ChapterPalette -Path $PaletteFile
    $Palette += "`n" + $(if ($PromptStyle -eq 'Preserve') { $chapterPalette.Instruction } else { $chapterPalette.CompactInstruction })
    $referencePath = $chapterPalette.Reference
    Write-Host "Using chapter palette: $($chapterPalette.File)"
}
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $RepoRoot ('manga-output/' + $folder.Name + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if ($outputRoot -eq $sourceRoot) { throw 'Choose an output folder different from the source folder.' }
$colorMaskPaths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($regionFile in (Get-ChildItem -LiteralPath $sourceRoot -Filter '*.color-regions.json' -File -Recurse:$Recurse)){
    if($regionFile.Length -gt 64KB){continue}
    try{
        $regionData=Get-Content -LiteralPath $regionFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach($entry in $regionData.regions){
            if($entry.mask -is [string]){
                $maskPath=if([IO.Path]::IsPathRooted($entry.mask)){$entry.mask}else{Join-Path $regionFile.DirectoryName $entry.mask}
                $null=$colorMaskPaths.Add([IO.Path]::GetFullPath($maskPath))
            }
        }
    }catch{
        # The corresponding page reports its own malformed sidecar during processing.
        Write-Warning "Could not index mask references in $($regionFile.Name): $_"
    }
}
$files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse:$Recurse |
    Where-Object { $_.Extension -match '^\.(png|jpe?g|jpe|webp|bmp|tiff?|gif|tga|avif|hei[cf]|jxl|jp2|j2k|ppm|pgm|pbm|pnm)$' -and
        $_.Name -notlike '*.text-mask.png' -and
        $_.Name -notlike '*.protect-mask.png' -and
        $_.Name -notlike '*.recolor-mask.png' -and
        !$colorMaskPaths.Contains($_.FullName) -and
        $_.FullName -ne $referencePath -and
        !$_.FullName.StartsWith($outputRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) } |
    Sort-Object @{Expression={ [regex]::Replace($_.FullName, '\d+', { param($match) $match.Value.PadLeft(20,'0') }) }}, FullName)
if (!$files.Count) { throw 'No supported images found in the input folder.' }
if ($ListOnly) { $files | Select-Object FullName; return }
New-Item -ItemType Directory -Force $outputRoot | Out-Null
# Freeze the instructions for this batch even if the user edits the source JSON
# while inference is running. Keep the applied palette with the output for review.
if ($chapterPalette) {
    $chapterPalette.Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputRoot 'applied-palette.json') -Encoding UTF8
}
$Palette | Set-Content -LiteralPath (Join-Path $outputRoot 'applied-palette.txt') -Encoding UTF8
Write-Host "Found $($files.Count) images. Output: $outputRoot"
$failed = @()
$completed = @()
$index = 0
foreach ($file in $files) {
    $index++
    Write-Host "[$index/$($files.Count)] $($file.Name)"
    try {
        $relativeFolder = $file.DirectoryName.Substring($sourceRoot.Length).TrimStart('\','/')
        $target = if ($relativeFolder) { Join-Path $outputRoot $relativeFolder } else { $outputRoot }
        if($PanelMode -ne 'Off'){
            if($referencePath){throw 'Experimental panel mode uses text palettes; image references are not enabled.'}
            if($CoverageMode -eq 'Repair' -or $Quality -ne 'Fast' -or $Consistency -ne 0 -or $Strength -ne 1){throw 'Panel mode requires Fast, strength 1, consistency 0 and Report/Off coverage.'}
            $panelPrecision=if($Precision -eq 'Auto'){'FP8'}else{$Precision}
            $completed+= & "$PSScriptRoot/Colorize-Panels.ps1" -InputPath $file.FullName -OutputDirectory (Join-Path $target $file.Name) `
                -Palette $Palette -ModelSize $ModelSize -Precision $panelPrecision -Megapixels $Megapixels -Seed $Seed -Steps $(if($Steps){$Steps}else{4}) -Resume:$Resume -FullPage:$false
            continue
        }
        $options = @{InputPath=$file.FullName; Palette=$Palette; Seed=$Seed; Steps=$Steps; Megapixels=$Megapixels;
            OutputDirectory=$target; NoOpen=$true; Quality=$Quality; Strength=$Strength;
            Consistency=$Consistency; PromptStyle=$PromptStyle; Precision=$Precision; ModelSize=$ModelSize}
        if ($DebugOutput) { $options.DebugOutput=$true }
        $options.CoverageMode=$CoverageMode;$options.MaxRepairRegions=$MaxRepairRegions
        if ($chapterPalette) { $options.PaletteData=$chapterPalette.Data }
        if ($referencePath) { $options.ReferenceImagePath = $referencePath }
        $mask = Join-Path $file.DirectoryName ($file.BaseName + '.text-mask.png')
        if (Test-Path -LiteralPath $mask) { $options.TextMaskPath = $mask }
        $protect = Join-Path $file.DirectoryName ($file.BaseName + '.protect-mask.png')
        if (Test-Path -LiteralPath $protect) {
            if ($options.ContainsKey('TextMaskPath')) { throw 'Use one combined .protect-mask.png for text and faces when both need protection.' }
            $options.TextMaskPath = $protect
        }
        $regions=Join-Path $file.DirectoryName ($file.BaseName+'.protection.json')
        if (Test-Path -LiteralPath $regions) { $options.ProtectionRegionsPath=$regions }
        $completed += & "$PSScriptRoot/Colorize.ps1" @options
    } catch {
        $failed += @{ source=$file.FullName; error=[string]$_ }
        Write-Warning "$($file.Name): $_"
    }
}
@{completed=$completed; failed=$failed; total=$files.Count;style_file=$StyleFile} | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $outputRoot 'batch-report.json') -Encoding UTF8
$review=@(foreach($item in $completed){
    $coverage=$null
    if($item.coverage_report -and (Test-Path -LiteralPath $item.coverage_report)){$coverage=Get-Content -LiteralPath $item.coverage_report -Raw | ConvertFrom-Json}
    $state='not analyzed'
    if($coverage){
        $state=if($coverage.neutral_samples_restored_by_protection -gt 0){'review protection mask'}
            elseif($coverage.eligible_samples -gt 0 -and $coverage.estimated_uncolored_percent -gt 2){'review declared artwork'}
            elseif($coverage.eligible_samples -eq 0){'unclassified: no semantic masks'}else{'no sampled missing color in declared artwork'}
    }
    [pscustomobject]@{source=$item.source;model=$item.model;state=$state;
        suspected_uncolored_percent=if($coverage){$coverage.estimated_uncolored_percent}else{$null};
        candidates=if($coverage){@($coverage.components).Count}else{0};
        repairs=if($coverage){$coverage.repaired}else{0};image=$item.image;coverage_report=$item.coverage_report}
})
$review | Export-Csv -LiteralPath (Join-Path $outputRoot 'color-review.csv') -NoTypeInformation -Encoding UTF8
Write-Host "Finished: $($completed.Count) succeeded, $($failed.Count) failed. Output: $outputRoot"
if ($failed.Count) { throw "Some images failed. See $outputRoot/batch-report.json for details." }
