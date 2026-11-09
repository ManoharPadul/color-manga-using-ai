[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [ValidateSet('9B FP8','4B FP8','4B BF16')][string]$Model='4B FP8',
    [string]$StyleFile,
    [ValidateSet('FullPage','AutoStrips')][string]$ProcessingMode='FullPage',
    [ValidateSet('Source','Indoor','Outdoor','Mixed')][string]$Scene='Source',
    [string]$CharacterFile,
    [switch]$AssignCharacters,
    [ValidateRange(1,50)][int]$Steps=4,
    [ValidateRange(0,2147483647)][long]$Seed=42,
    [ValidateRange(0.1,4.0)][double]$Megapixels=1.5,
    [switch]$TextWorkflow,
    [switch]$PreserveText,
    [ValidateRange(0,1)][double]$SourceShadows=0,
    [switch]$OriginalInk,
    [switch]$QualityReport,
    [switch]$SecondPass,[switch]$AutoRepair,
    [ValidateRange(0,1)][double]$MissingColorSensitivity=0.5,
    [ValidateRange(0,8)][int]$MaxColorRepairs=3,
    [switch]$StrictInk,
    [string]$TargetLanguage='source',
    [ValidateSet('paddle','manga')][string]$Ocr='paddle',
    [switch]$Review,
    [string]$ReviewConfig,
    [string]$ReferenceImage,
    [ValidateRange(0,2)][int]$Retries=0,
    [string]$OutputDirectory,
    [int]$OwnerProcessId=0,
    [string]$ControlFile,
    [switch]$Resume,
    [switch]$ReviewBeforeColor,
    [switch]$ListOnly
)
. "$PSScriptRoot/TextWorkflow.ps1"
. "$PSScriptRoot/VisionReview.ps1"
. "$PSScriptRoot/Characters.ps1"
. "$PSScriptRoot/Chapter.ps1"
. "$PSScriptRoot/Scene.ps1"
. "$PSScriptRoot/Studio-Jobs.ps1"
Set-MangaOwner -ProcessId $OwnerProcessId -ControlFile $ControlFile
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if(!$StyleFile){$StyleFile=Join-Path $RepoRoot 'manga-tested-style.txt'}
$palette=(Read-MangaStyleFile -Path $StyleFile)+"`n"+(Get-MangaSceneInstruction -Scene $Scene)
$reviewPalette=$palette
if($CharacterFile){$characters=Read-MangaCharacterProfiles -Path $CharacterFile;$reviewPalette+="`n"+$characters.instruction;if(!$AssignCharacters){$palette=$reviewPalette}}
$sourceItem=Get-Item -LiteralPath $InputPath
if(!$OutputDirectory){$OutputDirectory=Join-Path $RepoRoot ('manga-output/'+$(if($sourceItem.PSIsContainer){$sourceItem.Name}else{$sourceItem.BaseName})+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
$root=[IO.Path]::GetFullPath($OutputDirectory);$null=[IO.Directory]::CreateDirectory($root)
$files=@(if($sourceItem.PSIsContainer){Get-ChildItem -LiteralPath $sourceItem.FullName -File|Where-Object{$_.Extension -match '^\.(png|jpe?g|webp|bmp|tiff?|gif|tga|avif|hei[cf]|jxl|jp2|j2k|p[pgbn]m)$' -and $_.Name -notmatch '\.(protect|text|recolor|quality)-mask\.'}|Sort-Object @{Expression={[regex]::Replace($_.Name,'\d+',{param($m)$m.Value.PadLeft(20,'0')})}}}else{$sourceItem})
if(!$files.Count){throw 'No supported input images.'}
if($ListOnly){$files|Select-Object FullName;return}
if($ControlFile -and (Test-Path -LiteralPath $ControlFile) -and ([IO.File]::ReadAllText($ControlFile)).Trim() -eq 'cancel'){
    $report=Join-Path $root 'studio-report.json'
    if(!(Test-Path -LiteralPath $report)){@{completed=@();failed=@();canceled=$true}|ConvertTo-Json|Set-Content -LiteralPath $report -Encoding UTF8}
    Write-Host '[CANCELED] No stages started; completed files kept.'
    return
}
$runLock=$null
try{
$runLock=Open-MangaRunLock -Directory $AiRoot -OutputDirectory $root
$frozenStyle=Join-Path $root 'applied-style.txt';$palette|Set-Content -LiteralPath $frozenStyle -Encoding UTF8
if($CharacterFile){$characters.data|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $root 'applied-characters.json') -Encoding UTF8}
$reviewStyle=Join-Path $root 'review-style.txt';$reviewPalette|Set-Content -LiteralPath $reviewStyle -Encoding UTF8
@{processing_mode=$ProcessingMode;scene=$Scene;model=$Model;steps=$Steps;seed=$Seed;megapixels=$Megapixels;megapixels_per_panel=$(if($ProcessingMode -eq 'AutoStrips'){$Megapixels}else{$null});megapixels_per_full_page=$(if($ProcessingMode -eq 'FullPage'){$Megapixels}else{$null});text_workflow=[bool]$TextWorkflow;preserve_original_text=[bool]$PreserveText;source_shadows=$SourceShadows;second_pass=[bool]$SecondPass;auto_repair=[bool]$AutoRepair;missing_color_sensitivity=$MissingColorSensitivity;max_color_repairs=$MaxColorRepairs;quality_report=[bool]$QualityReport;original_ink=[bool]$OriginalInk;strict_ink=[bool]$StrictInk;assign_characters=[bool]$AssignCharacters;character_file=$CharacterFile;target_language=$TargetLanguage;review=[bool]$Review;max_retries=$Retries;style_file=$StyleFile;review_config=$ReviewConfig;reference=$ReferenceImage}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'run-settings.json') -Encoding UTF8
$workRoot=Join-Path $root '_work';$null=[IO.Directory]::CreateDirectory($workRoot)
[IO.File]::WriteAllText((Join-Path $workRoot 'README.txt'),'Intermediate diagnostic files only. The color directory contains the full-page color-stage result before optional source-ink restoration; any text protection may already have been applied. Use the final *-color.png files directly in the parent chapter folder.')
$parts=$Model -split ' ';$size=$parts[0];$precision=$parts[1]
$records=@();$failures=@();$canceled=$false
$config=Get-Content -LiteralPath (Join-Path $root 'run-settings.json') -Raw|ConvertFrom-Json
$orderedConfig=[ordered]@{};foreach($property in ($config.PSObject.Properties|Sort-Object Name)){$orderedConfig[$property.Name]=$property.Value}
$fingerprintSettings=$orderedConfig|ConvertTo-Json -Depth 12 -Compress
$fingerprintSettings+=$palette+$reviewPalette
if($CharacterFile){$fingerprintSettings+=Get-Content -LiteralPath $CharacterFile -Raw}
if($ReferenceImage){$fingerprintSettings+=(Get-MangaFileHash -LiteralPath $ReferenceImage).Hash}
foreach($file in $files){
    try{
        Wait-MangaControl -ControlFile $ControlFile
        Write-Host ('[PAGE_SOURCE] '+$file.FullName)
        $pageSettings=$fingerprintSettings
        foreach($suffix in @('.protect-mask.png','.text-mask.png','.panels.json','.protection.json','.quality.json')){
            $sidecar=Join-Path $file.DirectoryName ($file.BaseName+$suffix)
            if(Test-Path -LiteralPath $sidecar){$pageSettings+=(Get-MangaFileHash -LiteralPath $sidecar).Hash}
        }
        if($QualityReport -or $SecondPass -or $AutoRepair){
            $annotation=Find-MangaRegionAnnotation -Source $file.FullName
            if($annotation -and (Test-Path -LiteralPath $annotation)){
                try{
                    $pageSettings+=(Get-MangaFileHash -LiteralPath $annotation).Hash
                    $annotationData=Get-Content -LiteralPath $annotation -Raw|ConvertFrom-Json
                    foreach($region in @($annotationData.regions)|Select-Object -First 32){
                        $regionMask=[string]$region.mask
                        if($regionMask){if(![IO.Path]::IsPathRooted($regionMask)){$regionMask=Join-Path ([IO.Path]::GetDirectoryName($annotation)) $regionMask};if(Test-Path -LiteralPath $regionMask){$pageSettings+=(Get-MangaFileHash -LiteralPath $regionMask).Hash}}
                    }
                }catch{$pageSettings+='invalid-quality-annotation'}
            }
        }
        $fingerprint=Get-MangaJobFingerprint -Source $file.FullName -Settings $pageSettings
        $checkpoint=Join-Path $root ($file.Name+'.completed.json')
        if($Resume){$saved=Read-MangaCompletedJob -Path $checkpoint -Fingerprint $fingerprint;if($saved){$records+=$saved;Write-Host ('[RESULT] '+$saved.final);Write-Host ('Skipped verified completed page: '+$file.Name);continue}}
        $pageWatch=[Diagnostics.Stopwatch]::StartNew()
        Write-Host "MangaColorAI: $($file.Name)"
        $job=Join-Path $workRoot $file.Name
        if(Test-Path -LiteralPath $job){$job=Join-Path $workRoot ($file.Name+'-attempt-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
        $null=[IO.Directory]::CreateDirectory($job)
        $source=$file.FullName;$manifest=$null;$protection=$null
        if($TextWorkflow){
            Release-MangaGpu
            $normalized=Join-Path $job 'normalized.png';$null=ConvertTo-MangaPanelInput -Source $source -Destination $normalized
            $textDir=Join-Path $job 'text'
            Invoke-MangaTextTool -Arguments @('analyze','--input',$normalized,'--output',$textDir,'--ocr',$Ocr)
            $manifest=Join-Path $textDir 'text.json'
            Invoke-MangaTextTool -Arguments @('translate','--manifest',$manifest,'--language',$TargetLanguage)
            if($ReviewBeforeColor){Wait-MangaApproval -Path $manifest -Kind 'TEXT_REVIEW' -ControlFile $ControlFile}
            Wait-MangaControl -ControlFile $ControlFile
            Invoke-MangaTextTool -Arguments @('clean','--manifest',$manifest)
            $source=Join-Path $textDir 'cleaned.png'
        }elseif($PreserveText){
            Release-MangaGpu
            $normalized=Join-Path $job 'normalized.png';$null=ConvertTo-MangaPanelInput -Source $source -Destination $normalized
            $textDir=Join-Path $job 'text'
            Invoke-MangaTextTool -Arguments @('analyze','--input',$normalized,'--output',$textDir,'--ocr','none')
            $source=Join-Path $textDir 'original.png'
        }
        $planOptions=@{};$pageOptions=@{FullPage=($ProcessingMode -eq 'FullPage')};$assignmentError=$null
        if($AssignCharacters -and $CharacterFile){
            try{
            $proposal=& "$PSScriptRoot/Colorize-Panels.ps1" -InputPath $source -OutputDirectory (Join-Path $job 'panel-proposal') -Palette $palette -Steps $Steps -Seed $Seed -Megapixels $Megapixels -PlanOnly @pageOptions
            $planOptions.PlanPath=Join-Path $job 'assigned-panels.json'
            $assignmentCache=Get-MangaAssignmentCache -ChapterSource $file.FullName -ImageSource $source -Profiles (Join-Path $root 'applied-characters.json') -Style $palette
            $reused=Restore-MangaApprovedAssignment -Cache $assignmentCache -Destination $planOptions.PlanPath
            if(!$reused){
            if(!$ReviewConfig){$ReviewConfig=Join-Path $AiRoot 'review-model.json'}
            $vision=Get-Content -LiteralPath $ReviewConfig -Raw|ConvertFrom-Json
            Release-MangaGpu
            $assignArgs=@('assign','--input',(Join-Path $job 'panel-proposal/decoded-original.png'),'--plan',$proposal.settings,'--profiles',(Join-Path $root 'applied-characters.json'),'--model',$vision.model,'--projector',$vision.projector,'--output',$planOptions.PlanPath)
            if($ReferenceImage){$assignArgs+=@('--reference',[IO.Path]::GetFullPath($ReferenceImage))}
            Invoke-MangaTextTool -Arguments $assignArgs
            if($ReviewBeforeColor){Wait-MangaApproval -Path $planOptions.PlanPath -Kind 'ASSIGNMENT_REVIEW' -ControlFile $ControlFile}
            }else{Write-Host 'Reusing this page''s approved chapter identity/outfit assignment; vision stage skipped.'}
            if($reused -or $ReviewBeforeColor){
                Save-MangaApprovedAssignment -Cache $assignmentCache -Plan $planOptions.PlanPath -ChapterSource $file.FullName -OutputDirectory $root
            }else{
                $planOptions.AllowAutomaticPlan=$true
                Write-Host '[APPEARANCE] Applied the automatic match for this page without waiting; it was not added to the approved reuse cache.'
            }
            }catch [OperationCanceledException]{throw}catch{$assignmentError=[string]$_;$planOptions=@{};Write-Warning ('Optional appearance matching unavailable; no identity/outfit guesses applied: '+$assignmentError);Write-Host '[COLOR_REVIEW] Appearance matching unavailable; inspect identity and outfit consistency.'}
        }
        Wait-MangaControl -ControlFile $ControlFile
        $result=& "$PSScriptRoot/Colorize-Panels.ps1" -InputPath $source -OutputDirectory (Join-Path $job 'color') -ModelSize $size -Precision $precision -Palette $palette -Steps $Steps -Seed $Seed -Megapixels $Megapixels -ControlFile $ControlFile -OwnerProcessId $OwnerProcessId @pageOptions @planOptions
        $stages=@()
        $rawColor=$result.image
        $stages+=@{name='color-stage';path=$rawColor}
        $color=$result.image
        $protection=Resolve-MangaProtection -Source $source -Colored $color
        if($TextWorkflow){$replacementMask=Join-Path $textDir 'removal-mask.png';if(Test-Path -LiteralPath $replacementMask){$protection=$replacementMask}}
        Wait-MangaControl -ControlFile $ControlFile
        if($OriginalInk){
            $inkSource=Join-Path ([IO.Path]::GetDirectoryName($result.settings)) 'decoded-original.png'
            $inkColor=Join-Path $job 'color-with-original-ink.png'
            $inkArgs=@('ink','--source',$inkSource,'--colored',$color,'--output',$inkColor)
            if($StrictInk){$inkArgs+='--strict'}
            $mask=Join-Path ([IO.Path]::GetDirectoryName($source)) ([IO.Path]::GetFileNameWithoutExtension($source)+'.protect-mask.png')
            if(Test-Path -LiteralPath $mask){$inkArgs+=@('--mask',$mask)}
            Invoke-MangaTextTool -Arguments $inkArgs;$color=$inkColor;$stages+=@{name='after-source-ink';path=$color}
        }
        if($SourceShadows -gt 0){
            $shadowSource=Join-Path ([IO.Path]::GetDirectoryName($result.settings)) 'decoded-original.png'
            $shaded=Join-Path $job 'color-with-source-shadows.png'
            $shadowArgs=@('shadows','--source',$shadowSource,'--colored',$color,'--output',$shaded,'--strength',$SourceShadows.ToString([Globalization.CultureInfo]::InvariantCulture))
            $mask=Join-Path ([IO.Path]::GetDirectoryName($source)) ([IO.Path]::GetFileNameWithoutExtension($source)+'.protect-mask.png')
            if(Test-Path -LiteralPath $mask){$shadowArgs+=@('--mask',$mask)}
            Invoke-MangaTextTool -Arguments $shadowArgs
            $color=$shaded;$stages+=@{name='after-source-shadows';path=$color}
        }
        Wait-MangaControl -ControlFile $ControlFile
        $reviewError=$null;$reviewWarningPath=$null
        if($Review){
            try{
            if(!$ReviewConfig){$ReviewConfig=Join-Path $AiRoot 'review-model.json'}
            $vision=Get-Content -LiteralPath $ReviewConfig -Raw|ConvertFrom-Json
            Release-MangaGpu
            $reviewPath=Join-Path $job 'vision-review.json'
            $reviewArgs=@('review','--source',$source,'--colored',$color,'--model',$vision.model,'--projector',$vision.projector,'--style',$reviewStyle,'--output',$reviewPath)
            if($ReferenceImage){$reviewArgs+=@('--reference',[IO.Path]::GetFullPath($ReferenceImage))}
            Invoke-MangaTextTool -Arguments $reviewArgs
            $validatedReview=Read-MangaVisionReview -Path $reviewPath
            $reviewWarningPath=Join-Path $job 'vision-review-validated.json';$validatedReview|ConvertTo-Json -Depth 14|Set-Content -LiteralPath $reviewWarningPath -Encoding UTF8
            if(@($validatedReview.invalid_issues).Count){Write-Warning 'Vision returned invalid boxes. These issues are review-only; color output is preserved.'}
            if($Retries -gt 0){
                $result.image=$color
                $retry=Invoke-MangaVisionRetries -PanelResult $result -Source $source -StyleFile $reviewStyle -ReviewPath $reviewPath -Vision $vision -MaxAttempts $Retries -Directory (Join-Path $job 'retries') -ReferenceImage $ReferenceImage -ShadowStrength $SourceShadows -OriginalInk:$OriginalInk -StrictInk:$StrictInk
                $color=$retry.image
            }
            }catch [OperationCanceledException]{throw}catch{$reviewError=[string]$_;Write-Warning ('Optional vision review failed; exporting completed color image: '+$reviewError)}
        }
        $final=$color
        if($TextWorkflow){$final=Join-Path $job 'final.png';Render-MangaText -ManifestPath $manifest -ColorPath $color -Destination $final}
        $workingFinal=$final
        $final=Export-MangaFinalPage -Source $file.FullName -Image $workingFinal -Directory $root
        $pass1Final=$final;$automaticPath=$null;$automaticError=$null
        @{source=$file.FullName;raw_color=$rawColor;protection_mask=$protection;pass=1;requires_manual_review=$true}|ConvertTo-Json|Set-Content -LiteralPath ([IO.Path]::ChangeExtension($pass1Final,'.json')) -Encoding UTF8
        if($SecondPass -or $AutoRepair){
            try{
                Wait-MangaControl -ControlFile $ControlFile
                $pass2Source=Join-Path $job 'pass2-source.png';$null=ConvertTo-MangaPanelInput -Source $file.FullName -Destination $pass2Source
                $automaticDir=Join-Path $job 'pass-2';$autoArgs=@('coverage','--source',$pass2Source,'--colored',$final,'--raw',$rawColor,'--output',$automaticDir,'--sensitivity',$MissingColorSensitivity.ToString([Globalization.CultureInfo]::InvariantCulture),'--attempts',[string]$MaxColorRepairs)
                $annotation=Find-MangaRegionAnnotation -Source $file.FullName;if($annotation){$autoArgs+=@('--regions',$annotation)};if($protection){$autoArgs+=@('--protect',$protection)}
                if($CharacterFile){$autoArgs+=@('--profiles',(Join-Path $root 'applied-characters.json'))}
                if($AutoRepair){$autoArgs+='--apply'};if($QualityReport){$autoArgs+='--debug'}
                Invoke-MangaTextTool -Arguments $autoArgs;$automaticPath=Join-Path $automaticDir 'coverage.json'
                $automatic=Get-Content -LiteralPath $automaticPath -Raw|ConvertFrom-Json
                if($automatic.repairs_rejected -gt 0){Write-Host '[COLOR_REVIEW] Repairs rejected by quality checks; final image still contains unresolved candidates.'}
                $unified=$automatic.PSObject.Properties['unified_protection'];if($null -ne $unified -and $unified.Value -and (Test-Path -LiteralPath $unified.Value)){$protection=[string]$unified.Value}
                $stages+=@{name='pass-1-final';path=$pass1Final}
                if($automatic.repairs_accepted -gt 0){$final=Export-MangaFinalPage -Source $file.FullName -Image $automatic.result -Directory $root;$workingFinal=$automatic.result;$stages+=@{name='after-pass-2';path=$final}}
                Write-Host ('[QUALITY] '+$automaticPath)
            }catch [OperationCanceledException]{throw}catch{$automaticError=[string]$_;Write-Warning ('CPU second pass unavailable; pass 1 image kept: '+$automaticError)}
        }
        $qualityPath=$null;$qualityError=$null
        if($QualityReport){
            try{
                $diagnosticSource=Join-Path $job 'quality-source.png';$null=ConvertTo-MangaPanelInput -Source $file.FullName -Destination $diagnosticSource
                $stages+=@{name='final-export';path=$final};$stageManifest=Join-Path $job 'stages.json';@{version=1;stages=$stages}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $stageManifest -Encoding UTF8
                $qualityDir=Join-Path $job 'quality';$qualityArgs=@('quality','--source',$diagnosticSource,'--raw',$rawColor,'--colored',$final,'--stages',$stageManifest,'--output',$qualityDir)
                $regions=Find-MangaRegionAnnotation -Source $file.FullName;if($regions -and (Test-Path -LiteralPath $regions)){$qualityArgs+=@('--regions',$regions)}
                if($protection){$qualityArgs+=@('--protect',$protection)}
                Invoke-MangaTextTool -Arguments $qualityArgs;$qualityPath=Join-Path $qualityDir 'quality.json'
                if($automaticPath){$quality=Get-Content -LiteralPath $qualityPath -Raw|ConvertFrom-Json;$quality|Add-Member -NotePropertyName automatic -NotePropertyValue (Get-Content -LiteralPath $automaticPath -Raw|ConvertFrom-Json) -Force;$quality|ConvertTo-Json -Depth 24|Set-Content -LiteralPath $qualityPath -Encoding UTF8}
                Write-Host ('[QUALITY] '+$qualityPath)
            }catch [OperationCanceledException]{throw}catch{$qualityError=[string]$_;Write-Warning ('Quality report unavailable; final image kept: '+$qualityError)}
        }
        $record=@{pass1_final=$pass1Final;automatic_report=$automaticPath;automatic_error=$automaticError;vision_review_error=$reviewError;vision_review_validated=$reviewWarningPath;quality_report=$qualityPath;quality_error=$qualityError;protection_mask=$protection;raw_color=$rawColor;source=$file.FullName;colored=$color;final=$final;working_final=$workingFinal;original_ink=[bool]$OriginalInk;strict_ink=[bool]$StrictInk;scene=$Scene;text_manifest=$manifest;elapsed_seconds=[Math]::Round($pageWatch.Elapsed.TotalSeconds,2)}
        $record.assignment_error=$assignmentError
        $record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath ([IO.Path]::ChangeExtension($final,'.json')) -Encoding UTF8
        Save-MangaCompletedJob -Path $checkpoint -Fingerprint $fingerprint -Record $record
        $records+=$record
        @{completed=$records;failed=$failures;canceled=$false}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'studio-report.json') -Encoding UTF8
        Write-Host ('Page time: '+$pageWatch.Elapsed.TotalSeconds.ToString('F1',[Globalization.CultureInfo]::InvariantCulture)+' seconds')
        Write-Host ('[RESULT] '+$final)
    }catch [OperationCanceledException]{$canceled=$true;Write-Host '[CANCELED] Completed files kept.';break}catch{$failures+=@{source=$file.FullName;error=[string]$_};Write-Warning "$($file.Name): $_"}
}
@{completed=$records;failed=$failures;canceled=$canceled}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'studio-report.json') -Encoding UTF8
if($failures.Count){throw "$($failures.Count) pages failed; completed pages kept. See $root/studio-report.json"}
}finally{Close-MangaRunLock -Handle $runLock -Directory $AiRoot}
