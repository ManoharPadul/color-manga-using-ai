[CmdletBinding()]
param([string]$Version='0.3.13')
. "$PSScriptRoot/Common.ps1"
$required = @('MangaColorAI.exe','MangaColorAI-Image.exe','MangaColorAI-Text.exe')
foreach ($name in $required) {
    $path = Join-Path $RepoRoot ('bin/' + $name)
    if (!(Test-Path -LiteralPath $path)) { throw "Release binary is missing: $path. Build MangaColorAI first." }
}
$gitFiles = @(& git -C $RepoRoot ls-files --cached)
if ($LASTEXITCODE -ne 0 -or !$gitFiles.Count) { throw 'Commit the standalone source files before packaging the Windows ZIP.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$stage = Join-Path $tempRoot ('MangaColorAI-0.3.13-package-' + [Guid]::NewGuid().ToString('N'))
$folder = 'MangaColorAI-' + $Version + '-windows-x64'
$packageRoot = Join-Path $stage $folder
$null = [IO.Directory]::CreateDirectory($packageRoot)
foreach ($relative in $gitFiles) {
    if ($relative -match '(^|/)(\.git|\.local-ai|manga-output|target|release)(/|$)' -or $relative -match '\.(png|jpe?g|webp|bmp|tiff?|gif|safetensors|gguf|log)$') { continue }
    $source = Join-Path $RepoRoot $relative
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "Tracked release source is missing: $source" }
    $destination = Join-Path $packageRoot $relative
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Copy-Item -LiteralPath $source -Destination $destination
}
$null = [IO.Directory]::CreateDirectory((Join-Path $packageRoot 'bin'))
foreach ($name in $required) { Copy-Item -LiteralPath (Join-Path $RepoRoot ('bin/' + $name)) -Destination (Join-Path $packageRoot ('bin/' + $name)) }
$releaseDirectory = Join-Path $RepoRoot 'release'
$null = [IO.Directory]::CreateDirectory($releaseDirectory)
$zip = Join-Path $releaseDirectory ($folder + '.zip')
if (Test-Path -LiteralPath $zip) { throw "Release ZIP already exists; move it before packaging again: $zip" }
Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zip -CompressionLevel Optimal
if (!(Test-Path -LiteralPath $zip) -or (Get-Item -LiteralPath $zip).Length -lt 1MB) { throw 'The Windows release ZIP was not created or looks incomplete.' }
Write-Host "Windows release ZIP created: $zip"
Write-Host ('ZIP size: {0:N1} MB' -f ((Get-Item -LiteralPath $zip).Length / 1MB))
