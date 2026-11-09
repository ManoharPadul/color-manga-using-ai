param([switch]$BackendOnly)
. "$PSScriptRoot/Common.ps1"
Start-LocalBackend
if (!$BackendOnly) {
    $editor = Join-Path $RepoRoot 'bin/MangaColorAI.exe'
    if (!(Test-Path -LiteralPath $editor)) { throw "MangaColorAI executable not found: $editor. Build it with Build MangaColorAI.cmd or install the Windows release ZIP." }
    Start-Process -FilePath $editor -WorkingDirectory $RepoRoot | Out-Null
    Write-Host 'MangaColorAI is open. Choose an image or folder in the studio, or use the command launchers.'
}
