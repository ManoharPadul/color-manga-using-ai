. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Panels.ps1"
. "$PSScriptRoot/Studio-Jobs.ps1"

function Find-MangaRegionAnnotation {
    param([string]$Source)
    $sidecar=Join-Path ([IO.Path]::GetDirectoryName($Source)) ([IO.Path]::GetFileNameWithoutExtension($Source)+'.quality.json')
    if(Test-Path -LiteralPath $sidecar){return $sidecar}
    $projects=Join-Path $AiRoot 'mangacolorai/region-projects'
    if(Test-Path -LiteralPath $projects){
        foreach($file in Get-ChildItem -LiteralPath $projects -Filter '*.json' -File|Select-Object -First 1000){
            if($file.Length -gt 2MB){continue}
            try{$data=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json;if($data.source -eq $Source){return $file.FullName}}catch{continue}
        }
    }
    return $null
}

function Resolve-MangaProtection {
    param([string]$Source,[string]$Colored)
    $metadata=[IO.Path]::ChangeExtension($Colored,'.json')
    if(Test-Path -LiteralPath $metadata){
        $data=Get-Content -LiteralPath $metadata -Raw -Encoding UTF8|ConvertFrom-Json
        foreach($key in @('protection_mask','text_mask')){
            $property=$data.PSObject.Properties[$key]
            if($null -ne $property -and $property.Value -and (Test-Path -LiteralPath $property.Value)){return [string]$property.Value}
        }
    }
    foreach($suffix in @('.protect-mask.png','.text-mask.png')){
        $candidate=Join-Path ([IO.Path]::GetDirectoryName($Source)) ([IO.Path]::GetFileNameWithoutExtension($Source)+$suffix)
        if(Test-Path -LiteralPath $candidate){return $candidate}
    }
    return $null
}

function Invoke-MangaTextTool {
    param([string[]]$Arguments)
    $exe=Join-Path $RepoRoot 'bin/MangaColorAI-Text.exe'
    if(!(Test-Path -LiteralPath $exe)){$exe=Join-Path $AiRoot 'mangacolorai/MangaColorAI-Text.exe'}
    $pointer=Join-Path $AiRoot 'mangacolorai/helper-current.txt'
    if(Test-Path -LiteralPath $pointer){
        $hash=([IO.File]::ReadAllText($pointer)).Trim()
        if($hash -notmatch '^[0-9A-Fa-f]{16}$'){throw 'Invalid local helper version pointer; rebuild MangaColorAI.'}
        $exe=Join-Path $AiRoot ('mangacolorai/helpers/'+$hash+'/MangaColorAI-Text.exe')
    }
    if(!(Test-Path -LiteralPath $exe)){throw 'MangaColorAI text helper is not built. Run Build MangaColorAI.cmd.'}
    $store=Join-Path $AiRoot 'mangacolorai/runtime'
    $null=[IO.Directory]::CreateDirectory($store)
    $argsList=@('--store',$store)+$Arguments
    $quoted=@($argsList|ForEach-Object{$e=[regex]::Replace($_,'(\\*)"','$1$1\"');'"'+[regex]::Replace($e,'(\\+)$','$1$1')+'"'})
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe;$start.Arguments=$quoted -join ' '
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8;$start.StandardErrorEncoding=[Text.Encoding]::UTF8
    $start.EnvironmentVariables['CUBLASLT_DISABLE_CPU_INSTRUCTIONS_MASK']='1'
    $stageWatch=[Diagnostics.Stopwatch]::StartNew()
    Write-Host ('Text/vision stage: '+$Arguments[0])
    $process=[Diagnostics.Process]::Start($start)
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        Wait-MangaChildProcess -Process $process;$output=$stdout.Result;$errors=$stderr.Result
        if($output){Write-Host $output};if($errors){Write-Host $errors}
        if($process.ExitCode -ne 0){throw "MangaColorAI text/vision stage failed (exit $($process.ExitCode)): $errors"}
    }finally{Write-Host ('Stage time: '+$Arguments[0]+' '+$stageWatch.Elapsed.TotalSeconds.ToString('F1',[Globalization.CultureInfo]::InvariantCulture)+' seconds');$process.Dispose()}
}

function Release-MangaGpu {
    # Matching/text can precede the first color stage. Ensure the local API is
    # available before querying its queue; starting the server loads no model.
    Start-LocalBackend
    if(!(Test-LocalBackend)){return}
    $queue=Invoke-RestMethod "$Api/queue" -TimeoutSec 10
    if($queue.queue_running.Count -or $queue.queue_pending.Count){throw 'Another colorization job is running. Finish it before starting text/vision processing.'}
    Invoke-RestMethod "$Api/free" -Method Post -ContentType 'application/json' -Body '{"unload_models":true,"free_memory":true}' | Out-Null
    # /free signals the worker asynchronously; do not race the next GGUF load.
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        $stats=Invoke-RestMethod "$Api/system_stats" -TimeoutSec 10
        $reserved=($stats.devices|Measure-Object torch_vram_total -Sum).Sum
        if($reserved -lt 512MB){return}
        Start-Sleep -Milliseconds 300
    }while($watch.Elapsed.TotalSeconds -lt 30)
    throw 'Color backend did not release GPU memory within 30 seconds; no second model was loaded.'
}

function Render-MangaText {
    param([string]$ManifestPath,[string]$ColorPath,[string]$Destination,[string]$FontFamily='Segoe UI')
    if((Get-Item -LiteralPath $ManifestPath).Length -gt 2MB){throw 'Text manifest exceeds 2MB.'}
    $m=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($m.version -ne 1 -or @($m.regions).Count -gt 200){throw 'Invalid text manifest.'}
    if([IO.Path]::GetFullPath($ColorPath) -eq [IO.Path]::GetFullPath($Destination)){throw 'Text output must be a separate file.'}
    if($m.language -eq 'source'){
        # Reapply the actual original glyph pixels; OCR is editable metadata,
        # never an excuse to replace correct original typography.
        Copy-Item -LiteralPath $ColorPath -Destination $Destination -Force
        $mask=Join-Path ([IO.Path]::GetDirectoryName($ManifestPath)) 'removal-mask.png'
        Start-LocalBackend
        $null=Restore-OriginalRegions -SourcePath $m.source -ColorPath $Destination -MaskPath $mask -Width $m.width -Height $m.height
        return
    }
    $canvas=[Drawing.Bitmap]::new($ColorPath)
    if($canvas.Width -ne $m.width -or $canvas.Height -ne $m.height){$canvas.Dispose();throw 'Text manifest dimensions do not match color image.'}
    $layer=[Drawing.Bitmap]::new($canvas.Width,$canvas.Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics=[Drawing.Graphics]::FromImage($layer)
    $format=[Drawing.StringFormat]::new();$format.Alignment=[Drawing.StringAlignment]::Center;$format.LineAlignment=[Drawing.StringAlignment]::Center
    if($m.language -match 'Arabic|Hebrew|Persian|^ar-|^he-|^fa-'){$format.FormatFlags=$format.FormatFlags -bor [Drawing.StringFormatFlags]::DirectionRightToLeft}
    $graphics.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    try {
        foreach($r in $m.regions){
            if(!$r.selected){continue}
            if($r.translation -isnot [string] -or $r.translation.Length -gt 16000){throw 'Translation must be text under 16000 characters.'}
            if([string]::IsNullOrWhiteSpace($r.translation)){throw "Missing translation for $($r.id). Correct text.json before exporting."}
            if($r.x -lt 0 -or $r.y -lt 0 -or $r.width -lt 1 -or $r.height -lt 1 -or [long]$r.x+$r.width -gt $m.width -or [long]$r.y+$r.height -gt $m.height){throw 'Text rectangle outside image.'}
            $rect=[Drawing.RectangleF]::new($r.x,$r.y,$r.width,$r.height)
            $font=$null;$size=[Math]::Min(70,[Math]::Max(12,$r.height*0.45))
            while($size -ge 8){
                if($font){$font.Dispose()}
                $font=[Drawing.Font]::new($FontFamily,[single]$size,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
                $measure=$graphics.MeasureString($r.translation,$font,[Drawing.SizeF]::new($r.width,100000),$format)
                if($measure.Height -le $r.height -and $measure.Width -le $r.width){break}
                $size-=1
            }
            try{if($size -lt 8){throw "Text $($r.id) will overflow. Enlarge its box or shorten the translation in text.json."};$graphics.DrawString($r.translation,$font,[Drawing.Brushes]::Black,$rect,$format)}finally{if($font){$font.Dispose()}}
        }
        $textLayer=[IO.Path]::ChangeExtension($Destination,'.text-layer.png')
        $layer.Save($textLayer,[Drawing.Imaging.ImageFormat]::Png)
        $g=[Drawing.Graphics]::FromImage($canvas)
        try{$dest=[Drawing.Rectangle]::new(0,0,$canvas.Width,$canvas.Height);$g.DrawImage($layer,$dest,0,0,$layer.Width,$layer.Height,[Drawing.GraphicsUnit]::Pixel)}finally{$g.Dispose()}
        $canvas.Save($Destination,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$format.Dispose();$graphics.Dispose();$layer.Dispose();$canvas.Dispose()}
}
