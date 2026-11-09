param([Parameter(Position=0)][string]$InputDirectory,[string]$OutputDirectory,[switch]$Repair,[switch]$Recurse)
. "$PSScriptRoot/Common.ps1"
if(!$InputDirectory){
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Choose a folder of existing colored results and their per-image JSON files'
    try{if($dialog.ShowDialog() -ne 'OK'){return};$InputDirectory=$dialog.SelectedPath}finally{$dialog.Dispose()}
}
$inputRoot=(Get-Item -LiteralPath $InputDirectory).FullName
if(!$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('manga-output/selected-folder-repair-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
if($outputRoot -eq $inputRoot){throw 'Select a separate output directory.'}
$files=@(Get-ChildItem -LiteralPath $inputRoot -Filter '*.json' -File -Recurse:$Recurse |
    Where-Object {!$_.FullName.StartsWith($outputRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)})
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$rows=@();$index=0
foreach($file in $files){
    if($file.Length -gt 512KB){continue}
    try{$m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json}catch{continue}
    if($null -eq $m.PSObject.Properties['source'] -or $null -eq $m.PSObject.Properties['image'] -or $null -eq $m.PSObject.Properties['model']){continue}
    $index++;$row=@{metadata=$file.FullName;source=$m.source;status='skipped';reason='No manually selected color-region file';output=''}
    $rows+=$row
    $regions=Join-Path $file.DirectoryName ($file.BaseName+'.color-regions.json')
    if(!(Test-Path -LiteralPath $regions)){$regions=Join-Path (Split-Path -Parent $m.source) (([IO.Path]::GetFileNameWithoutExtension($m.source))+'.color-regions.json')}
    if(!(Test-Path -LiteralPath $regions)){continue}
    try{
        $options=@{MetadataPath=$file.FullName;ColorRegionsPath=$regions;OutputDirectory=(Join-Path $outputRoot ([string]$index));Repair=$Repair}
        $result=& "$PSScriptRoot/Repair-Existing.ps1" @options
        $row.status=if($Repair -and $result.repaired -gt 0){'repaired'}else{'analyzed; no accepted repair'}
        $row.reason='Only manually selected regions considered';$row.output=$result.image
    }catch{$row.status='error';$row.reason=[string]$_;Write-Warning $_}
}
$rows | ForEach-Object {[pscustomobject]$_} | Export-Csv -LiteralPath (Join-Path $outputRoot 'selected-results.csv') -NoTypeInformation -Encoding UTF8
Write-Host "Reviewed $index existing results. Good/unselected pages were not regenerated or overwritten. Report: $outputRoot"
