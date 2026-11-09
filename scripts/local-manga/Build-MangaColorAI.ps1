[CmdletBinding()]
param([switch]$SkipTextHelper)
. "$PSScriptRoot/Common.ps1"

$cargo = Join-Path $AiRoot 'rust/cargo/bin/cargo.exe'
if (!(Test-Path -LiteralPath $cargo)) {
    $cargoCommand = Get-Command cargo.exe -ErrorAction SilentlyContinue
    if ($null -eq $cargoCommand) { $cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue }
    if ($null -eq $cargoCommand) { throw 'Install the stable Rust toolchain before building. See README.md, Build from source.' }
    $cargo = $cargoCommand.Source
} else {
    $env:CARGO_HOME = Join-Path $AiRoot 'rust/cargo'
    $env:RUSTUP_HOME = Join-Path $AiRoot 'rust/rustup'
}
$clang = Join-Path $AiRoot 'build-deps/libclang/clang/native'
if (Test-Path -LiteralPath $clang) { $env:LIBCLANG_PATH = $clang }

$bin = Join-Path $RepoRoot 'bin'
$null = [IO.Directory]::CreateDirectory($bin)

$imageTarget = Join-Path $AiRoot 'mangacolorai-image-build'
$env:CARGO_TARGET_DIR = $imageTarget
& $cargo build --locked --release --manifest-path (Join-Path $RepoRoot 'tools/manga-image/Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'MangaColorAI image helper build failed.' }
Copy-Item -LiteralPath (Join-Path $imageTarget 'release/mangacolorai-image.exe') -Destination (Join-Path $bin 'MangaColorAI-Image.exe') -Force

$appTarget = Join-Path $AiRoot 'mangacolorai-build'
$env:CARGO_TARGET_DIR = $appTarget
& $cargo build --locked --release --manifest-path (Join-Path $RepoRoot 'tools/mangacolorai/Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'MangaColorAI studio build failed.' }
Copy-Item -LiteralPath (Join-Path $appTarget 'release/mangacolorai.exe') -Destination (Join-Path $bin 'MangaColorAI.exe') -Force

if (!$SkipTextHelper) {
    $repo = Join-Path $AiRoot 'research-repos/koharu-rs__koharu'
    $pin = 'c1a43cf7de2a0d40dc92afcbb0a55bbce0468dd8'
    if (!(Test-Path -LiteralPath $repo)) {
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $repo))
        $env:GIT_LFS_SKIP_SMUDGE = '1'
        git clone --filter=blob:none --no-checkout https://github.com/koharu-rs/koharu.git $repo
        if ($LASTEXITCODE -ne 0) { throw 'Could not clone Koharu. Re-run the build after checking network access.' }
        git -C $repo sparse-checkout init --cone
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the sparse Koharu checkout.' }
        git -C $repo sparse-checkout set crates .cargo
        if ($LASTEXITCODE -ne 0) { throw 'Could not select the Koharu library sources.' }
        git -C $repo checkout $pin
        if ($LASTEXITCODE -ne 0) { throw 'Could not check out the pinned Koharu revision.' }
    }
    if ((git -C $repo rev-parse HEAD) -ne $pin) { throw 'Koharu checkout changed; use the documented pinned revision.' }
    $textTarget = Join-Path $AiRoot 'mangacolorai-text-build'
    $env:CARGO_TARGET_DIR = $textTarget
    & $cargo build --locked --release --manifest-path (Join-Path $RepoRoot 'tools/manga-text/Cargo.toml') --bin mangacolorai-text
    if ($LASTEXITCODE -ne 0) { throw 'Optional Koharu text helper build failed. Re-run with -SkipTextHelper to build the core colorizer.' }
    Copy-Item -LiteralPath (Join-Path $textTarget 'release/mangacolorai-text.exe') -Destination (Join-Path $bin 'MangaColorAI-Text.exe') -Force
}

Write-Host "Built standalone MangaColorAI Windows binaries in $bin"
if ($SkipTextHelper) { Write-Host 'Koharu OCR/translation helper was skipped.' }
