. "$PSScriptRoot/TextWorkflow.ps1"
. "$PSScriptRoot/Chapter.ps1"
. "$PSScriptRoot/Characters.ps1"
$root=Join-Path $AiRoot ('chapter-tests/'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$page=Join-Path $root 'page.dat';$profiles=Join-Path $root 'profiles.json';$plan=Join-Path $root 'plan.json';$restored=Join-Path $root 'restored.json'
[IO.File]::WriteAllText($page,'synthetic page content')
$shirt=@{id='shirt';name='Shirt';identify='round collar';color='#EEAABB'}
$person=@{id='p1';name='A';identify='round glasses';hair='#302521';eyes='#795338';skin='#F1CEB6';outfits=@(@{id='casual';name='Casual';identify='round collar and jeans';colors='pink shirt blue jeans';garments=@($shirt)},@{id='no-jacket';name='No jacket';identify='same shirt without jacket';colors='pink shirt blue jeans';garments=@($shirt)})}
@{version=1;characters=@($person)}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $profiles -Encoding UTF8
$null=Read-MangaCharacterProfiles -Path $profiles
$cache=Get-MangaAssignmentCache -ChapterSource $page -ImageSource $page -Profiles $profiles -Style 'natural'
@{approved=$true;profiles=@{characters=@($person)};panels=@(@{x=0;y=0;width=100;height=200;vision_assignment=@{people=@(@{id='p1';outfit='casual';confidence=1;source_bbox=@(0,0,50,100)})}})}|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $plan -Encoding UTF8
Save-MangaApprovedAssignment -Cache $cache -Plan $plan -ChapterSource $page -OutputDirectory $root
if(!(Restore-MangaApprovedAssignment -Cache $cache -Destination $restored)){throw 'Approved assignment was not reused'}
if((Get-Content -LiteralPath $restored -Raw|ConvertFrom-Json).panels[0].vision_assignment.people[0].outfit -ne 'casual'){throw 'Outfit assignment lost'}
$different=Get-MangaAssignmentCache -ChapterSource (Join-Path $root 'another-chapter/page.dat') -ImageSource $page -Profiles $profiles -Style 'natural'
if($different.chapter_id -eq $cache.chapter_id -or (Restore-MangaApprovedAssignment -Cache $different -Destination $restored)){throw 'Chapters were silently merged'}
$changed=Get-MangaAssignmentCache -ChapterSource $page -ImageSource $page -Profiles $profiles -Style 'changed'
if(Restore-MangaApprovedAssignment -Cache $changed -Destination $restored){throw 'Changed style reused stale assignment'}
[IO.File]::WriteAllText($page,'changed source');$changed=Get-MangaAssignmentCache -ChapterSource $page -ImageSource $page -Profiles $profiles -Style 'natural'
if(Restore-MangaApprovedAssignment -Cache $changed -Destination $restored){throw 'Changed source reused stale assignment'}
$person.outfits[1].garments=@(@{id='shirt';name='Shirt';identify='round collar';color='#123456'})
@{version=1;characters=@($person)}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $profiles -Encoding UTF8
$rejected=$false;try{$null=Read-MangaCharacterProfiles -Path $profiles}catch{$rejected=$true};if(!$rejected){throw 'Conflicting approved garment colors accepted'}
@{approved=$false;panels=@()}|ConvertTo-Json|Set-Content -LiteralPath $plan -Encoding UTF8
$rejected=$false;try{Save-MangaApprovedAssignment -Cache $cache -Plan $plan -ChapterSource $page -OutputDirectory $root}catch{$rejected=$true};if(!$rejected){throw 'Unapproved matches were cached'}
Write-Host ('PASS: chapter isolation, approved appearance/outfit reuse, source/style invalidation, partial outfit garment reuse, conflict rejection, no unapproved caching. '+$root)
