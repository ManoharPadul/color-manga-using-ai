function Read-MangaVisionReview {
    param([string]$Path)
    if((Get-Item -LiteralPath $Path).Length -gt 128KB){throw 'Vision review exceeds 128KB.'}
    $r=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    foreach($name in @('preservation','palette_consistency')){
        $v=$r.$name
        if($v -isnot [ValueType] -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v) -or [double]$v -lt 0 -or [double]$v -gt 100){throw 'Vision scores must be finite numbers in 0..100.'}
    }
    if(@($r.issues).Count -gt 20){throw 'Too many vision issues.'}
    $valid=@();$invalid=@()
    foreach($issue in @($r.issues)){
        try{
            foreach($field in @('region','problem','fix','confidence','bbox')){if(!$issue.PSObject.Properties[$field]){throw "Missing vision issue field: $field"}}
            if($issue.confidence -isnot [ValueType] -or [double]::IsNaN([double]$issue.confidence) -or [double]::IsInfinity([double]$issue.confidence) -or $issue.confidence -lt 0 -or $issue.confidence -gt 100){throw 'Invalid vision confidence.'}
            if($issue.confidence -le 1){$issue.confidence=[double]$issue.confidence*100}
            # The review prompt's contract is normalized xyxy 0..1000. With no trustworthy
            # alternative space declared, out-of-range/reversed boxes cannot be converted.
            if($r.PSObject.Properties['coordinate_space'] -and $r.coordinate_space -ne 'normalized_1000_xyxy'){throw 'Unknown vision coordinate space; requires manual annotation.'}
            if(@($issue.bbox).Count -ne 4){throw 'Vision box needs four coordinates.'}
            foreach($n in $issue.bbox){if($n -isnot [ValueType] -or [double]::IsNaN([double]$n) -or [double]::IsInfinity([double]$n) -or [double]$n -ne [Math]::Floor([double]$n) -or $n -lt 0 -or $n -gt 1000){throw 'Invalid normalized vision coordinates; not clamped or guessed.'}}
            if($issue.bbox[0] -ge $issue.bbox[2] -or $issue.bbox[1] -ge $issue.bbox[3]){throw 'Empty or reversed vision box; requires manual annotation.'}
            foreach($field in @('region','problem','fix')){if($issue.$field -isnot [string] -or $issue.$field.Length -gt 4000){throw 'Invalid vision issue text.'}}
            $valid+=$issue
        }catch{$invalid+=@{issue=$issue;reason=[string]$_;automatic_repair_authorized=$false}}
    }
    $r.issues=@($valid)
    $r|Add-Member -NotePropertyName invalid_issues -NotePropertyValue @($invalid) -Force
    $r|Add-Member -NotePropertyName requires_manual_review -NotePropertyValue $true -Force
    return $r
}

function Test-MangaReviewImprovement {
    param($Before,$After,$BeforeInk,$AfterInk)
    return ($null -ne $AfterInk.score -and $AfterInk.score -ge 0.90 -and
        ($null -eq $BeforeInk.score -or $AfterInk.score -ge $BeforeInk.score-0.01) -and
        $After.preservation -ge $Before.preservation -and $After.palette_consistency -ge $Before.palette_consistency+2)
}

function Invoke-MangaVisionRetries {
    param($PanelResult,[string]$Source,[string]$StyleFile,[string]$ReviewPath,$Vision,[int]$MaxAttempts=1,[string]$Directory,[string]$ReferenceImage,[double]$ShadowStrength=0,[switch]$OriginalInk,[switch]$StrictInk)
    $settings=Get-Content -LiteralPath $PanelResult.settings -Raw|ConvertFrom-Json
    $panelSource=Join-Path ([IO.Path]::GetDirectoryName($PanelResult.settings)) 'decoded-original.png'
    if(!(Test-Path -LiteralPath $panelSource)){$panelSource=$Source}
    # Advisory vision scores never authorize replacing source artwork. Repairs require an approved mask.
    if(@($settings.panels).Count -eq 1){
        $null=[IO.Directory]::CreateDirectory($Directory)
        @{accepted=0;reason='Full-page rerender skipped. Select a local repair mask and review the candidate.';review=$ReviewPath}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Directory 'attempts.json') -Encoding UTF8
        Write-Host 'Vision review is advisory. Full-page retry skipped; use a selected repair mask.'
        return [pscustomobject]@{image=$PanelResult.image;attempts=@();accepted=0;requires_visual_review=$true}
    }
    $panels=@($settings.panels);$images=@($PanelResult.panels|ForEach-Object{$_.image})
    $best=$PanelResult.image;$review=Read-MangaVisionReview -Path $ReviewPath
    $records=@();$done=@{};$accepted=0
    $null=[IO.Directory]::CreateDirectory($Directory)
    for($attempt=1;$attempt -le $MaxAttempts;$attempt++){
        $candidates=@($review.issues|Where-Object{$_.confidence -ge 85 -and !$done.ContainsKey($_.fix) -and $_.problem -notmatch 'anatomy|pose|composition|redraw|letter|balloon|text|line.?art'}|Sort-Object confidence -Descending)
        if(!$candidates.Count){break}
        $issue=$candidates[0];$done[$issue.fix]=$true
        $cx=($issue.bbox[0]+$issue.bbox[2])/2000.0*$settings.width
        $cy=($issue.bbox[1]+$issue.bbox[3])/2000.0*$settings.height
        $index=-1
        for($i=0;$i -lt $panels.Count;$i++){$p=$panels[$i];if($cx -ge $p.x -and $cy -ge $p.y -and $cx -lt $p.x+$p.width -and $cy -lt $p.y+$p.height){$index=$i;break}}
        if($index -lt 0){continue}
        $p=$panels[$index];$dir=Join-Path $Directory ('attempt-'+$attempt);$null=[IO.Directory]::CreateDirectory($dir)
        $panelInput=Join-Path $dir 'input.png';Export-MangaPanelCrop -Source $panelSource -Panel $p -Destination $panelInput
        $mask=Join-Path ([IO.Path]::GetDirectoryName($Source)) ([IO.Path]::GetFileNameWithoutExtension($Source)+'.protect-mask.png')
        if(Test-Path -LiteralPath $mask){Export-MangaPanelCrop -Source $mask -Panel $p -Destination (Join-Path $dir 'input.protect-mask.png')}
        $palette=$settings.palette+"`n"+$p.style+"`nCorrect only the reported color assignment while retaining the original drawing and all approved colors: "+$issue.fix
        Write-Host "Vision retry $attempt/$MaxAttempts : $($p.id), $($issue.region). Candidate kept separately."
        $candidate=& "$PSScriptRoot/Colorize.ps1" -InputPath $panelInput -OutputDirectory (Join-Path $dir 'color') -Palette $palette -ModelSize $settings.model -Precision $settings.precision -Megapixels $settings.megapixels -Seed $settings.seed -Steps $settings.steps -Quality Fast -Consistency 0 -Strength 1 -PromptStyle Minimal -NoOpen
        $oldInk=Get-RepairInkAlignment -OriginalPath $panelInput -ColorPath $images[$index]
        $newInk=Get-RepairInkAlignment -OriginalPath $panelInput -ColorPath $candidate.image
        $record=@{attempt=$attempt;panel=$p.id;issue=$issue;image=$candidate.image;accepted=$false;old_ink=$oldInk;new_ink=$newInk;reason='Ink preservation gate rejected candidate.'}
        if($null -ne $newInk.score -and $newInk.score -ge 0.9 -and ($null -eq $oldInk.score -or $newInk.score -ge $oldInk.score-0.01)){
            $nextImages=@($images);$nextImages[$index]=$candidate.image
            $next=Join-Path $dir 'candidate-page.png';Merge-MangaPanels -Source $panelSource -Panels $panels -Images $nextImages -Destination $next
            if($OriginalInk){
                $inkColor=Join-Path $dir 'candidate-ink.png';$inkArgs=@('ink','--source',$panelSource,'--colored',$next,'--output',$inkColor)
                if($StrictInk){$inkArgs+='--strict'}
                if(Test-Path -LiteralPath $mask){$inkArgs+=@('--mask',$mask)}
                Invoke-MangaTextTool -Arguments $inkArgs;$next=$inkColor
            }
            if($ShadowStrength -gt 0){
                $shaded=Join-Path $dir 'candidate-shaded.png'
                $shadowArgs=@('shadows','--source',$panelSource,'--colored',$next,'--output',$shaded,'--strength',$ShadowStrength.ToString([Globalization.CultureInfo]::InvariantCulture))
                if(Test-Path -LiteralPath $mask){$shadowArgs+=@('--mask',$mask)}
                Invoke-MangaTextTool -Arguments $shadowArgs;$next=$shaded
            }
            Release-MangaGpu
            $nextReview=Join-Path $dir 'vision-review.json'
            $reviewArgs=@('review','--source',$Source,'--colored',$next,'--model',$Vision.model,'--projector',$Vision.projector,'--style',$StyleFile,'--output',$nextReview)
            if($ReferenceImage){$reviewArgs+=@('--reference',[IO.Path]::GetFullPath($ReferenceImage))}
            Invoke-MangaTextTool -Arguments $reviewArgs
            $scored=Read-MangaVisionReview -Path $nextReview
            $record.reason='No sufficient improvement in advisory review scores.';$record.review=$nextReview
            $record.reason='Candidate retained for manual masked review; advisory scores do not authorize acceptance.'
        }
        $records+=$record
        $records|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Directory 'attempts.json') -Encoding UTF8
    }
    return [pscustomobject]@{image=$best;attempts=$records;accepted=$accepted;requires_visual_review=$true}
}
