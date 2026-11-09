. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Characters.ps1"
$root=Join-Path $AiRoot ('character-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$path=Join-Path $root 'characters.json'
$c=@{id='person-1';name='Person 1';identify='long hair and round glasses';hair='chestnut';eyes='brown';skin='warm peach';outfits=@(@{name='casual';identify='button-front dress';colors='ivory dress, tan ribbon'},@{name='winter';identify='long coat and scarf';colors='camel coat, cream scarf'})}
@{version=1;characters=@($c)}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $path
$valid=Read-MangaCharacterProfiles -Path $path
if($valid.instruction -notlike '*camel coat*' -or $valid.instruction -notlike '*ivory dress*'){throw 'Outfit variants not included.'}
@{version=1;characters=@($c,$c)}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $path
$failed=$false;try{$null=Read-MangaCharacterProfiles -Path $path}catch{$failed=$true};if(!$failed){throw 'Duplicate character ID accepted.'}
Write-Host 'PASS: reusable identities, outfit variants and duplicate-ID rejection.'
