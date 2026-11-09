# Approved assignment reuse is scoped to the original chapter directory and
# exact source/profile/style content. It never infers an unseen-page identity.
function Get-MangaTextDigest {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}finally{$sha.Dispose()}
}
function Get-MangaAssignmentCache {
    param([string]$ChapterSource,[string]$ImageSource,[string]$Profiles,[string]$Style)
    $chapter=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ChapterSource)).ToLowerInvariant()
    $chapterId=Get-MangaTextDigest -Text $chapter
    $sourceHash=(Get-MangaFileHash -LiteralPath $ImageSource -Algorithm SHA256).Hash
    $profileHash=(Get-MangaFileHash -LiteralPath $Profiles -Algorithm SHA256).Hash
    $key=Get-MangaTextDigest -Text ('appearance-v2|'+$sourceHash+'|'+$profileHash+'|'+$Style)
    return [pscustomobject]@{chapter=$chapter;chapter_id=$chapterId;source_hash=$sourceHash;profile_hash=$profileHash;key=$key;path=(Join-Path $AiRoot ('mangacolorai/chapter-assignments/'+$chapterId+'/'+$key+'.json'))}
}
function Restore-MangaApprovedAssignment {
    param($Cache,[string]$Destination)
    if(!(Test-Path -LiteralPath $Cache.path)){return $false}
    try{
        if((Get-Item -LiteralPath $Cache.path).Length -gt 2MB){return $false}
        $record=Get-Content -LiteralPath $Cache.path -Raw -Encoding UTF8|ConvertFrom-Json
        if($record.version -ne 2 -or $record.key -ne $Cache.key -or $record.chapter -ne $Cache.chapter -or !$record.plan.approved){return $false}
        if(@($record.plan.panels).Count -lt 1 -or @($record.plan.panels).Count -gt 64){return $false}
        $record.plan|ConvertTo-Json -Depth 32|Set-Content -LiteralPath $Destination -Encoding UTF8
        return $true
    }catch{Write-Warning ('Assignment cache ignored: '+[string]$_);return $false}
}
function Save-MangaApprovedAssignment {
    param($Cache,[string]$Plan,[string]$ChapterSource,[string]$OutputDirectory)
    $data=Get-Content -LiteralPath $Plan -Raw -Encoding UTF8|ConvertFrom-Json
    if(!$data.approved){throw 'Only explicitly approved assignments may enter the chapter cache.'}
    $parent=[IO.Path]::GetDirectoryName($Cache.path);$null=[IO.Directory]::CreateDirectory($parent)
    $record=@{version=2;chapter=$Cache.chapter;chapter_id=$Cache.chapter_id;key=$Cache.key;source=$ChapterSource;source_hash=$Cache.source_hash;profile_hash=$Cache.profile_hash;provenance='explicit user approval';plan=$data}
    $temp=$Cache.path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{$record|ConvertTo-Json -Depth 32|Set-Content -LiteralPath $temp -Encoding UTF8;Move-Item -LiteralPath $temp -Destination $Cache.path -Force}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp}}
    # One page record per source; distinct identities and outfits remain separate.
    $journal=Join-Path $OutputDirectory 'chapter-assignments.json'
    $pages=@();if(Test-Path -LiteralPath $journal){$existing=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json;$pages=@($existing.pages|Where-Object{$_.source -ne $ChapterSource})}
    $pages+=@{source=$ChapterSource;cache_key=$Cache.key;approved=$true;panels=$data.panels}
    @{version=2;chapter=$Cache.chapter;profiles=$data.profiles;pages=$pages}|ConvertTo-Json -Depth 32|Set-Content -LiteralPath $journal -Encoding UTF8
}
