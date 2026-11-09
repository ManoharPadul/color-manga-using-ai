param([Parameter(Position=0)][string]$InputDirectory)
. "$PSScriptRoot/Common.ps1"
if (!$InputDirectory) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose the non-explicit manga folder for this character palette'
    try { if ($dialog.ShowDialog() -ne 'OK') { return }; $InputDirectory=$dialog.SelectedPath }
    finally { $dialog.Dispose() }
}
$folder = Get-Item -LiteralPath $InputDirectory
if (!$folder.PSIsContainer) { throw 'Choose a folder.' }
$path = Join-Path $folder.FullName 'manga-palette.json'
if (Test-Path -LiteralPath $path) {
    Start-Process notepad.exe -ArgumentList ('"'+$path+'"') | Out-Null
    Write-Host 'Opened the existing palette for editing. Save it before starting the folder run.'
    return
}
Write-Host 'Define the colors once for this chapter. Use visible traits to identify each character.'
$characters = @()
do {
    $name = Read-Host 'Character name (or a short label)'
    $identify = Read-Host 'How to recognize them (hair length, hairstyle, glasses, etc.)'
    $hair = Read-Host 'Hair color'
    $eyes = Read-Host 'Eye color'
    $outfit = Read-Host 'Clothing descriptions and fixed colors (list separate outfits when needed)'
    foreach ($value in @($name,$identify,$hair,$eyes,$outfit)) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'All character fields are required. Rerun the palette creator.' }
    }
    $characters += @{name=$name; identify=$identify; hair=$hair; eyes=$eyes; outfit=$outfit}
    $again = Read-Host 'Add another character? y/N'
} while ($again -eq 'y' -and $characters.Count -lt 20)
$scene = Read-Host 'Background colors / lighting (optional)'
$reference = Read-Host 'Optional non-explicit colored reference image path (Enter to skip)'
$profile = @{version=1; characters=$characters; scene=$scene; reference_image=$reference.Trim('"')}
$profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Saved $path"
Write-Host 'Colorize Folder.cmd will automatically use this palette for every page in that folder.'
