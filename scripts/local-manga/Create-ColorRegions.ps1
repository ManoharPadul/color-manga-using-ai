param([Parameter(Position=0)][string]$InputPath,[switch]$NoOpen)
. "$PSScriptRoot/Common.ps1"
if(!$InputPath){
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Title='Choose the original manga page to configure a color repair';$dialog.Filter='Images|*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.tif;*.tiff'
    try{if($dialog.ShowDialog() -ne 'OK'){return};$InputPath=$dialog.FileName}finally{$dialog.Dispose()}
}
$source=Get-Item -LiteralPath $InputPath
if($source.PSIsContainer){throw 'Choose the original image file.'}
$path=Join-Path $source.DirectoryName ($source.BaseName+'.color-regions.json')
if(!(Test-Path -LiteralPath $path)){
    @{version=1;regions=@(@{id='clothing-repair';character='Character A';category='clothing';intent='color';
        mask=($source.BaseName+'.recolor-mask.png');expected_color='#577DA3';repair=$false})} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}
Write-Host "Edit $path. Create the named original-size mask: white = selected artwork, black = everything else. Set repair true only for the intended region."
if(!$NoOpen){Start-Process notepad.exe -ArgumentList ('"'+$path+'"') | Out-Null}
