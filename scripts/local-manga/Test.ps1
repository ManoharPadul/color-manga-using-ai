param([switch]$CheckBackend, [switch]$SmokeTest)
. "$PSScriptRoot/Common.ps1"
$failures = @()
Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { $failures += $errors }
}
$graph = New-ColorizeGraph -ImageName 'test.png' -Instruction 'blue sky' -Seed 123 -Megapixels 0.4
$maskedGraph = New-ColorizeGraph -ImageName 'test.png' -Instruction 'blue sky' -TextMaskName 'text-mask.png'
$referenceGraph = New-ColorizeGraph -ImageName 'test.png' -Instruction 'blue sky' -ReferenceImageName 'reference.png'
$detailedGraph = New-ColorizeGraph -ImageName 'test.png' -Instruction 'color only' -Quality BaseExperimental -Strength 0.6
if ($detailedGraph.'16'.inputs.steps -ne 50 -or $detailedGraph.'13'.inputs.cfg -ne 4.0 -or
    $detailedGraph.'3'.inputs.unet_name -ne 'flux-2-klein-base-4b-fp8.safetensors' -or
    $detailedGraph.'17'.inputs.latent_image[0] -ne '7' -or $detailedGraph.'40'.inputs.step -ne 20) {
    $failures += 'Detailed preservation mode must use the Base model and source latent with the lower sigma schedule.'
}
$consistentGraph = New-ColorizeGraph -ImageName 'test.png' -Instruction 'color only' -Quality Detailed -Consistency 0.4
if ($consistentGraph.'16'.inputs.steps -ne 4 -or $consistentGraph.'13'.inputs.cfg -ne 1 -or
    $consistentGraph.'13'.inputs.model[0] -ne '41' -or $consistentGraph.'41'.inputs.strength_model -ne 0.4) {
    $failures += 'Detailed consistency must retain distilled settings and route the model through the adapter.'
}
$fullGraph = New-ColorizeGraph -ImageName 'test.png' -Instruction 'color only' -Quality Detailed -Precision BF16
$nineGraph = New-ColorizeGraph -ImageName 'test.png' -Instruction 'color only' -ModelSize 9B
if ($nineGraph.'3'.inputs.unet_name -ne 'flux-2-klein-9b-fp8.safetensors' -or
    $nineGraph.'4'.inputs.clip_name -ne 'qwen_3_8b_fp8mixed.safetensors' -or
    $nineGraph.'16'.inputs.steps -ne 4 -or $nineGraph.'13'.inputs.cfg -ne 1) {
    $failures += '9B must select its matching encoder and retain distilled settings.'
}
foreach ($invalidOptions in @(@{Consistency=0.4}, @{Precision='BF16'}, @{Quality='BaseExperimental'})) {
    $rejected9B=$false
    try { New-ColorizeGraph -ModelSize 9B @invalidOptions | Out-Null } catch { $rejected9B=$true }
    if (!$rejected9B) { $failures += 'Unsupported 9B settings must fail before inference.' }
}
if ($fullGraph.'3'.inputs.unet_name -ne 'flux-2-klein-4b.safetensors' -or $fullGraph.'16'.inputs.steps -ne 4) {
    $failures += 'Full precision must select the verified BF16 distilled checkpoint and retain four steps.'
}
if ($referenceGraph.'13'.inputs.positive[0] -ne '33' -or
    $referenceGraph.'33'.inputs.conditioning[0] -ne '9' -or
    $referenceGraph.'13'.inputs.negative[0] -ne '34' -or $referenceGraph.'30'.inputs.image -ne 'reference.png') {
    $failures += 'Reference graph must retain the page conditioning and append the color reference.'
}
$paletteTests = Join-Path $AiRoot 'palette-tests'
New-Item -ItemType Directory -Force $paletteTests | Out-Null
$testProfile = Join-Path $paletteTests 'valid.json'
@{version=1; characters=@(@{name='Alex'; identify='short wavy hair and round glasses';
    hair='dark brown'; eyes='green'; outfit='navy coat; white shirt'; skin='warm beige'; skin_shadow='muted peach'}); scene='warm daylight'} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $testProfile -Encoding UTF8
$parsedPalette = Read-ChapterPalette -Path $testProfile
if ($parsedPalette.Instruction -notlike '*navy coat*' -or $parsedPalette.Instruction -notlike '*EVERY panel*') {
    $failures += 'Character colors and cross-panel instructions were lost.'
}
if ($parsedPalette.CompactInstruction -notlike '*skin: warm beige*' -or $parsedPalette.Instruction -notlike '*skin shadow: muted peach*') {
    $failures += 'Optional character skin colors were lost.'
}
$invalidProfile = Join-Path $paletteTests 'invalid.json'
'{"version":1,"characters":[{"name":"Incomplete"}]}' | Set-Content -LiteralPath $invalidProfile
$rejected = $false
try { Read-ChapterPalette -Path $invalidProfile | Out-Null } catch { $rejected=$true }
if (!$rejected) { $failures += 'Incomplete palettes must fail before inference.' }
if ($maskedGraph.'19'.inputs.images[0] -ne '23' -or
    $maskedGraph.'23'.inputs.source[0] -ne '2' -or $maskedGraph.'20'.inputs.image -ne 'text-mask.png') {
    $failures += 'Text preservation graph does not restore original working-image pixels.'
}
if ($graph.'1'.inputs.image -ne 'test.png' -or $graph.'5'.inputs.text -ne 'blue sky' -or
    $graph.'14'.inputs.noise_seed -ne 123 -or $graph.'2'.inputs.megapixels -ne 0.4) {
    $failures += 'Graph parameter substitution failed.'
}
$nodes = @($graph.PSObject.Properties.Name)
foreach ($node in $graph.PSObject.Properties) {
    foreach ($input in $node.Value.inputs.PSObject.Properties) {
        if ($input.Value -is [array] -and $input.Value.Count -eq 2 -and $nodes -notcontains [string]$input.Value[0]) {
            $failures += "Broken graph link at $($node.Name).$($input.Name)"
        }
    }
}
if ($CheckBackend) {
    if (!(Test-LocalBackend)) { throw 'Start the backend before running -CheckBackend.' }
    # Regression: Windows PowerShell 5 treats [] in Invoke-WebRequest -OutFile
    # as wildcard syntax. Verify the literal-path transport without GPU work.
    $literalDir = Join-Path $AiRoot 'path-tests/[brackets] and spaces'
    $probe = Join-Path $literalDir ([Guid]::NewGuid().ToString('N') + '.json')
    Save-LocalImage -Uri "$Api/system_stats" -Destination $probe
    $downloaded = Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
    if (!(Test-Path -LiteralPath $probe) -or $null -eq $downloaded.system) {
        $failures += 'Literal bracket-path HTTP output regression.'
    }
    $info = Invoke-RestMethod "$Api/object_info" -TimeoutSec 30
    foreach ($node in $graph.PSObject.Properties) {
        $definition = $info.PSObject.Properties[$node.Value.class_type]
        if ($null -eq $definition) { $failures += "Missing backend node $($node.Value.class_type)"; continue }
        foreach ($required in $definition.Value.input.required.PSObject.Properties) {
            if ($null -eq $node.Value.inputs.PSObject.Properties[$required.Name]) {
                $failures += "Missing input $($node.Value.class_type).$($required.Name)"
            }
        }
    }
    $stats = Invoke-RestMethod "$Api/system_stats"
    Write-Host ($stats.devices | ConvertTo-Json -Compress)
}
if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'PASS: script syntax, graph substitutions and links, and requested backend checks.'
if ($SmokeTest) {
    Add-Type -AssemblyName System.Drawing
    $testDir = Join-Path $AiRoot 'smoke-test'
    New-Item -ItemType Directory -Force $testDir | Out-Null
    $inputFile = Join-Path $testDir 'line-art.png'
    $bitmap = New-Object Drawing.Bitmap 768,768
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::Black),4
    $font = New-Object Drawing.Font 'Arial',22
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.SmoothingMode = 'AntiAlias'
        $graphics.DrawRectangle($pen,24,24,720,720)
        $graphics.DrawEllipse($pen,570,85,90,90)
        $graphics.DrawLine($pen,25,570,742,570)
        $graphics.DrawRectangle($pen,200,340,290,230)
        $points = [Drawing.Point[]]@((New-Object Drawing.Point 160,340),
            (New-Object Drawing.Point 345,190),(New-Object Drawing.Point 530,340))
        $graphics.DrawPolygon($pen,$points)
        $graphics.DrawRectangle($pen,315,430,65,140)
        $graphics.DrawRectangle($pen,225,380,65,60)
        $graphics.DrawRectangle($pen,405,380,65,60)
        $graphics.DrawRectangle($pen,590,390,30,180)
        $graphics.DrawEllipse($pen,530,225,150,190)
        $graphics.DrawEllipse($pen,65,80,265,90)
        $graphics.DrawString('A NEW DAY!',$font,[Drawing.Brushes]::Black,90,105)
        $bitmap.Save($inputFile,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose(); $pen.Dispose(); $font.Dispose() }
    $before = (Get-MangaFileHash -LiteralPath $inputFile).Hash
    $result = & "$PSScriptRoot/Colorize.ps1" -InputPath $inputFile -NoOpen -OutputDirectory $testDir `
        -Megapixels 0.7 -Palette 'A red roof, cream walls, green foliage, blue sky and yellow sun.'
    if ((Get-MangaFileHash -LiteralPath $inputFile).Hash -ne $before) { throw 'Source image was modified.' }
    if (!(Test-Path -LiteralPath $result.image)) { throw 'Missing colorized PNG output.' }
    $pngInfo = Get-MangaImageInfo -Path $result.image
    if ($pngInfo.width -ne 768 -or $pngInfo.height -ne 768) {
        throw 'Colorized PNG must retain the source dimensions despite AI working-size scaling.'
    }
    Write-Host "PASS: local GPU inference, $($pngInfo.width) x $($pngInfo.height) PNG output, unchanged source. Review $($result.image) visually."
}
