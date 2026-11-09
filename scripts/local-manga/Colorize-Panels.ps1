[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$InputPath,
    [string]$OutputDirectory,
    [string]$PlanPath,
    [switch]$AllowAutomaticPlan,
    [string]$StyleFile,
    [string]$Palette,
    [ValidateSet('4B','9B')][string]$ModelSize='9B',
    [ValidateSet('FP8','BF16')][string]$Precision='FP8',
    [ValidateRange(0.1,4.0)][double]$Megapixels=1.5,
    [ValidateRange(1,50)][int]$Steps=4,
    [ValidateRange(0,2147483647)][long]$Seed=42,
    [int]$OwnerProcessId=0,
    [string]$ControlFile,
    [switch]$Resume,
    [switch]$FullPage=$true,
    [switch]$PlanOnly
)
. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Panels.ps1"
. "$PSScriptRoot/Studio-Jobs.ps1"
Set-MangaOwner -ProcessId $OwnerProcessId -ControlFile $ControlFile
if([string]::IsNullOrWhiteSpace($InputPath)){
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=[Windows.Forms.OpenFileDialog]::new()
    $dialog.Title='Choose a manga image for panel colorization'
    $dialog.Filter='Images|*.png;*.jpg;*.jpeg;*.jpe;*.webp;*.bmp;*.tif;*.tiff;*.gif;*.tga;*.avif;*.heic;*.heif;*.jxl;*.jp2;*.j2k;*.ppm;*.pgm;*.pbm;*.pnm|All files|*.*'
    try{if($dialog.ShowDialog() -ne 'OK'){return};$InputPath=$dialog.FileName}finally{$dialog.Dispose()}
}
$source=Get-Item -LiteralPath $InputPath
if($ModelSize -eq '9B' -and $Precision -eq 'BF16'){throw '9B requires FP8.'}
if($StyleFile -and $PSBoundParameters.ContainsKey('Palette')){throw 'Choose StyleFile or Palette.'}
if($StyleFile){$Palette=Read-MangaStyleFile -Path $StyleFile}
elseif(!$PSBoundParameters.ContainsKey('Palette')){$Palette=Read-MangaStyleFile -Path (Join-Path $RepoRoot 'manga-tested-style.txt')}
if(!$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('manga-output/panels-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
$root=[IO.Path]::GetFullPath($OutputDirectory)
if($root.TrimEnd('\') -eq $source.DirectoryName.TrimEnd('\')){throw 'Choose a separate output directory.'}
$null=[IO.Directory]::CreateDirectory($root)
$decoded=ConvertTo-MangaPanelInput -Source $source.FullName -Destination (Join-Path $root 'decoded-original.png')
$workingSource=$decoded.path;$w=$decoded.width;$h=$decoded.height
if(!$FullPage -and !$PlanPath){$candidate=Join-Path $source.DirectoryName ($source.BaseName+'.panels.json');if(Test-Path -LiteralPath $candidate){$PlanPath=$candidate}}
$panels=if($PlanPath){Read-MangaPanelPlan -Path $PlanPath -Width $w -Height $h -AllowAutomatic:$AllowAutomaticPlan}elseif($FullPage){,@((New-MangaFullPagePlan -Width $w -Height $h))}else{Get-MangaStripPanels -Path $workingSource}
if($FullPage -and ($panels.Count -ne 1 -or $panels[0].x -ne 0 -or $panels[0].y -ne 0 -or $panels[0].width -ne $w -or $panels[0].height -ne $h)){throw 'Full-page processing needs one plan covering the complete image; split plans are not used.'}
$sourceHash=(Get-MangaFileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
$maskPath=$null
foreach($suffix in @('.text-mask.png','.protect-mask.png')){
    $candidate=Join-Path $source.DirectoryName ($source.BaseName+$suffix)
    if(Test-Path -LiteralPath $candidate){if($maskPath){throw 'Use one combined protection mask.'};$maskPath=$candidate}
}
if(Test-Path -LiteralPath (Join-Path $source.DirectoryName ($source.BaseName+'.protection.json'))){throw 'Panel mode currently requires a combined .protect-mask.png rather than protection.json.'}
$maskHash=''
if($maskPath){
    $mask=[Drawing.Bitmap]::new($maskPath)
    try{if($mask.Width -ne $w -or $mask.Height -ne $h){throw 'Protection mask must match original dimensions.'}}finally{$mask.Dispose()}
    $maskHash=(Get-MangaFileHash -LiteralPath $maskPath).Hash
}
$settings=[ordered]@{version=3;processing_mode=$(if($FullPage){'FullPage'}else{'Panels'});source=$source.FullName;source_hash=$sourceHash;width=$w;height=$h;panels=@($panels);palette=$Palette;model=$ModelSize;precision=$Precision;megapixels=$Megapixels;seed=$Seed;mask_hash=$maskHash;steps=$Steps;cfg=1;strength=1;prompt_style='Minimal'}
# Exact frozen settings gate reuse. Changed source, mask, palette or geometry forces a new run.
$settingsText=$settings | ConvertTo-Json -Depth 12
$settingsPath=Join-Path $root 'applied-panel-settings.json'
if(Test-Path -LiteralPath $settingsPath){
    if(!$Resume){throw 'Output already has a run. Use Resume for unchanged settings, or a fresh directory.'}
    $oldCanonical=Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress
    $newCanonical=$settingsText | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress
    if($oldCanonical -cne $newCanonical){throw 'Resume settings changed. Choose a new output directory.'}
}else{$settingsText | Set-Content -LiteralPath $settingsPath -Encoding UTF8}
$overlay=[Drawing.Bitmap]::new($workingSource);$g=[Drawing.Graphics]::FromImage($overlay)
$pen=[Drawing.Pen]::new([Drawing.Color]::Red,3)
try{foreach($p in $panels){$g.DrawRectangle($pen,[int]$p.x,[int]$p.y,[int]$p.width-1,[int]$p.height-1)};$overlay.Save((Join-Path $root 'panel-boxes.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$pen.Dispose();$g.Dispose();$overlay.Dispose()}
Write-Host "$($panels.Count) $(if($FullPage){'full-page job'}else{'panel jobs'}); source $w x $h. Layout preview: $root/panel-boxes.png"
if($PlanOnly){return [pscustomobject]@{panels=$panels;settings=$settingsPath}}
$records=@();$images=@()
foreach($p in $panels){
    Wait-MangaControl -ControlFile $ControlFile
    $job=Join-Path $root $p.id;$null=[IO.Directory]::CreateDirectory($job)
    $crop=Join-Path $job 'input.png';if($FullPage){Copy-Item -LiteralPath $workingSource -Destination $crop -Force}else{Export-MangaPanelCrop -Source $workingSource -Panel $p -Destination $crop}
    $cropMask=Join-Path $job 'input.protect-mask.png'
    if($maskPath){Export-MangaPanelCrop -Source $maskPath -Panel $p -Destination $cropMask}
    $recordPath=Join-Path $job 'completed.json';$record=$null
    if($Resume -and (Test-Path -LiteralPath $recordPath)){
        $saved=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if((Test-Path -LiteralPath $saved.image) -and (Get-MangaFileHash -LiteralPath $saved.image).Hash -eq $saved.output_hash){$record=$saved;Write-Host "Reusing verified $($p.id)"}
    }
    if(!$record){
        $style=$Palette;if($p.style){$style+="`nPanel-specific approved colors: "+$p.style}
        $record=& "$PSScriptRoot/Colorize.ps1" -InputPath $crop -OutputDirectory (Join-Path $job 'result') -Palette $style -ModelSize $ModelSize -Precision $Precision -Megapixels $Megapixels -Seed $Seed -Steps $Steps -Quality Fast -Consistency 0 -Strength 1 -PromptStyle Minimal -CoverageMode Report -NoOpen
        $record | Add-Member NoteProperty output_hash (Get-MangaFileHash -LiteralPath $record.image).Hash
        $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    }
    $records+=$record;$images+=$record.image
}
if((Get-MangaFileHash -LiteralPath $source.FullName).Hash -ne $sourceHash){throw 'Source changed during processing.'}
$final=Join-Path $root ($source.BaseName+$(if($FullPage){'-full-page-color.png'}else{'-panels-color.png'}))
$pending=Join-Path $root ('pending-'+[Guid]::NewGuid().ToString('N')+'.png')
Merge-MangaPanels -Source $workingSource -Panels $panels -Images $images -Destination $pending
Move-Item -LiteralPath $pending -Destination $final -Force
$report=@{source=$source.FullName;source_hash=$sourceHash;image=$final;width=$w;height=$h;model=$ModelSize;precision=$Precision;panels=$records;settings=$settingsPath;status='complete';requires_visual_review=$true;coverage_report=$null}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $root 'panel-report.json') -Encoding UTF8
[pscustomobject]$report
