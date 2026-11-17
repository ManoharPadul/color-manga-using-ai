[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$global:UpscaleScriptDir = $PSScriptRoot

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw 'Manga Upscale AI must be launched in an STA PowerShell session. Use Start Manga Upscale AI.cmd.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$global:AppRoot = [IO.Path]::GetFullPath((Join-Path $global:UpscaleScriptDir '../..'))
$global:RuntimeRoot = Join-Path $global:AppRoot '.manga-upscale-runtime'
$global:RealExe = Join-Path $global:RuntimeRoot 'realesrgan/realesrgan-ncnn-vulkan.exe'
$global:ModelFolder = Join-Path $global:RuntimeRoot 'realesrgan/models'
$global:FFmpegExe = Join-Path $global:RuntimeRoot 'ffmpeg/ffmpeg.exe'
$global:InputMode = ''
$global:JobState = $null

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Manga Upscale AI" Width="920" Height="720" MinWidth="760" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#15181E" Foreground="#ECEFF4"
        FontFamily="Segoe UI" AllowDrop="True">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#252B35"/><Setter Property="Foreground" Value="#F3F5F8"/>
      <Setter Property="BorderBrush" Value="#3A4351"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,9"/><Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1E232B"/><Setter Property="Foreground" Value="#E9EDF3"/>
      <Setter Property="BorderBrush" Value="#39414D"/><Setter Property="Padding" Value="9,7"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#1E232B"/><Setter Property="Foreground" Value="#E9EDF3"/>
      <Setter Property="BorderBrush" Value="#39414D"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5"/><Setter Property="MinHeight" Value="36"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="ComboBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4"/>
              <ContentPresenter x:Name="SelectionPresenter" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"
                                HorizontalAlignment="Left" Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}" IsHitTestVisible="False"/>
              <ToggleButton x:Name="DropDownToggle" Focusable="False" ClickMode="Press" Background="Transparent"
                            BorderThickness="0" HorizontalAlignment="Right" Width="30"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <Path Data="M 0 0 L 4 4 L 8 0 Z" Fill="#AAB3C0" Width="8" Height="4" Stretch="Fill"/>
              </ToggleButton>
              <Popup x:Name="DropDownPopup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                <Border Background="#1E232B" BorderBrush="#39414D" BorderThickness="1" CornerRadius="4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="280" SnapsToDevicePixels="True">
                  <ScrollViewer CanContentScroll="True" Margin="2">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#596779"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#67C587"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ComboBorder" Property="Opacity" Value="0.55"/>
                <Setter Property="Foreground" Value="#9DA7B5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#1E232B"/><Setter Property="Foreground" Value="#E9EDF3"/>
      <Setter Property="Padding" Value="9,7"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#2A3542"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="#263B32"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#8893A1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#DDE2E9"/><Setter Property="Margin" Value="0,6,16,6"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E8EBF0"/><Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>
  <DockPanel LastChildFill="True">
    <Border DockPanel.Dock="Top" Background="#1B2028" BorderBrush="#303743" BorderThickness="0,0,0,1" Padding="24,18">
      <Grid>
        <StackPanel>
          <TextBlock Text="Manga Upscale AI" FontSize="24" FontWeight="SemiBold"/>
          <TextBlock Text="Upscale one image or a folder locally with Real-ESRGAN x4plus-anime" Foreground="#AAB3C0" Margin="0,4,0,0"/>
        </StackPanel>
        <Border HorizontalAlignment="Right" VerticalAlignment="Center" Background="#263B32" CornerRadius="12" Padding="12,6">
          <TextBlock Text="4× ANIME MODEL" Foreground="#BDE7CD" FontSize="11" FontWeight="Bold"/>
        </Border>
      </Grid>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel Margin="24,20,24,24">
        <TextBlock Text="Source" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
          <Button x:Name="PickImageButton" Content="Choose image"/>
          <Button x:Name="PickFolderButton" Content="Choose folder"/>
          <Button x:Name="ClearButton" Content="Clear" Margin="0"/>
          <TextBlock x:Name="InputSummary" Text="No source selected" Foreground="#AAB3C0" Margin="14,0,0,0"/>
        </StackPanel>
        <TextBox x:Name="InputPath" IsReadOnly="True" Height="38"/>

        <TextBlock Text="Output folder" FontSize="16" FontWeight="SemiBold" Margin="0,22,0,10"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBox x:Name="OutputPath" Height="38" VerticalContentAlignment="Center"/>
          <Button x:Name="PickOutputButton" Grid.Column="1" Content="Browse…" Margin="10,0,0,0"/>
        </Grid>

        <TextBlock Text="Upscale settings" FontSize="16" FontWeight="SemiBold" Margin="0,22,0,10"/>
        <Border Background="#1B2028" BorderBrush="#303743" BorderThickness="1" CornerRadius="8" Padding="14">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="1.2*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Margin="0,0,16,0">
              <TextBlock Text="Model" Foreground="#AAB3C0" FontSize="12"/>
              <TextBlock Text="Real-ESRGAN x4plus-anime" FontWeight="SemiBold" Margin="0,6,0,0"/>
              <TextBlock Text="Fixed model · 4× output" Foreground="#AAB3C0" FontSize="12" Margin="0,4,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Margin="0,0,16,0">
              <TextBlock Text="Output format" Foreground="#AAB3C0" FontSize="12"/>
              <ComboBox x:Name="OutputFormat" SelectedIndex="0" Margin="0,5,0,0">
                <ComboBoxItem Content="PNG" Tag="png"/><ComboBoxItem Content="JPEG" Tag="jpg"/><ComboBoxItem Content="WebP" Tag="webp"/>
              </ComboBox>
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="GPU tile size" Foreground="#AAB3C0" FontSize="12"/>
              <ComboBox x:Name="TileSize" SelectedIndex="0" Margin="0,5,0,0">
                <ComboBoxItem Content="Auto (recommended)" Tag="0"/><ComboBoxItem Content="256" Tag="256"/>
                <ComboBoxItem Content="512" Tag="512"/><ComboBoxItem Content="768" Tag="768"/>
              </ComboBox>
            </StackPanel>
          </Grid>
        </Border>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
          <CheckBox x:Name="Recurse" Content="Include subfolders" IsChecked="True"/>
          <TextBlock Text="The app uses Vulkan GPU acceleration when available. Auto tile is the starting setting for an RTX 4090." Foreground="#AAB3C0" FontSize="12" TextWrapping="Wrap" Margin="4,0,0,0"/>
        </StackPanel>

        <Border Background="#1B2028" BorderBrush="#303743" BorderThickness="1" CornerRadius="8" Padding="14" Margin="0,14,0,0">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock x:Name="RuntimeStatus" Text="Checking local tools…" FontWeight="SemiBold"/>
              <TextBlock Text="Setup downloads the portable upscaler and FFmpeg once. It does not start image processing." Foreground="#AAB3C0" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="SetupButton" Content="Install tools"/>
              <Button x:Name="RefreshButton" Content="Refresh" Margin="0"/>
            </StackPanel>
            <TextBlock x:Name="RuntimeDetails" Grid.Row="1" Grid.ColumnSpan="2" Foreground="#9DA7B5" FontSize="11" Margin="0,10,0,0"/>
          </Grid>
        </Border>

        <Grid Margin="0,20,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock x:Name="JobStatus" Text="Ready" FontSize="14" FontWeight="SemiBold"/>
            <ProgressBar x:Name="JobProgress" Minimum="0" Maximum="100" Value="0" Height="8" Margin="0,8,16,0" Background="#2B323D" Foreground="#67C587"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="StartButton" Content="Upscale ×4" Background="#28734A" BorderBrush="#3B9A62" FontWeight="SemiBold"/>
            <Button x:Name="OpenOutputButton" Content="Open output" IsEnabled="False"/>
            <Button x:Name="CancelButton" Content="Cancel job" IsEnabled="False" Margin="0"/>
          </StackPanel>
        </Grid>
        <TextBox x:Name="ActivityLog" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="112" Margin="0,12,0,0" Background="#101318" FontFamily="Consolas" FontSize="12"/>
        <TextBlock Text="Original files are kept unchanged. Animated GIF and multi-page TIFF inputs use the first frame/page." Foreground="#AAB3C0" FontSize="11" Margin="0,9,0,0"/>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

$xmlReader = New-Object System.Xml.XmlNodeReader $xaml
$global:Window = [Windows.Markup.XamlReader]::Load($xmlReader)
$global:PickImageButton = $global:Window.FindName('PickImageButton')
$global:PickFolderButton = $global:Window.FindName('PickFolderButton')
$global:ClearButton = $global:Window.FindName('ClearButton')
$global:InputSummary = $global:Window.FindName('InputSummary')
$global:InputPath = $global:Window.FindName('InputPath')
$global:OutputPath = $global:Window.FindName('OutputPath')
$global:PickOutputButton = $global:Window.FindName('PickOutputButton')
$global:OutputFormat = $global:Window.FindName('OutputFormat')
$global:TileSize = $global:Window.FindName('TileSize')
$global:Recurse = $global:Window.FindName('Recurse')
$global:RuntimeStatus = $global:Window.FindName('RuntimeStatus')
$global:RuntimeDetails = $global:Window.FindName('RuntimeDetails')
$global:SetupButton = $global:Window.FindName('SetupButton')
$global:RefreshButton = $global:Window.FindName('RefreshButton')
$global:JobStatus = $global:Window.FindName('JobStatus')
$global:JobProgress = $global:Window.FindName('JobProgress')
$global:OpenOutputButton = $global:Window.FindName('OpenOutputButton')
$global:CancelButton = $global:Window.FindName('CancelButton')
$global:ActivityLog = $global:Window.FindName('ActivityLog')

function global:Add-LogLine {
    param([string]$Message)
    $stamp = [DateTime]::Now.ToString('HH:mm:ss')
    $global:ActivityLog.AppendText("[$stamp] $Message`r`n")
    $global:ActivityLog.ScrollToEnd()
}

function global:Get-ImageExtensions {
    return @('.png','.jpg','.jpeg','.webp','.bmp','.tif','.tiff','.gif')
}

function global:Get-OutputFormatValue {
    $selected = [System.Windows.Controls.ComboBoxItem]$global:OutputFormat.SelectedItem
    if ($null -eq $selected -or [string]::IsNullOrWhiteSpace([string]$selected.Tag)) { return 'png' }
    return [string]$selected.Tag
}

function global:Get-RuntimeReady {
    return (Test-Path -LiteralPath $global:RealExe -PathType Leaf) -and
        (Test-Path -LiteralPath $global:FFmpegExe -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $global:ModelFolder 'realesrgan-x4plus-anime.param') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $global:ModelFolder 'realesrgan-x4plus-anime.bin') -PathType Leaf)
}

function global:Refresh-RuntimeStatus {
    if (Get-RuntimeReady) {
        $global:RuntimeStatus.Text = 'Upscale tools are ready'
        $global:RuntimeStatus.Foreground = [Windows.Media.Brushes]::LightGreen
        $global:RuntimeDetails.Text = "Real-ESRGAN x4plus-anime + FFmpeg · $global:RuntimeRoot"
        $global:SetupButton.Content = 'Repair / update tools'
    } else {
        $global:RuntimeStatus.Text = 'Setup is required before upscaling'
        $global:RuntimeStatus.Foreground = [Windows.Media.Brushes]::Khaki
        $global:RuntimeDetails.Text = 'No image processing starts until you press Upscale.'
        $global:SetupButton.Content = 'Install tools'
    }
}

function global:Set-DefaultOutput {
    param([string]$SelectedPath,[ValidateSet('file','folder')][string]$Mode)
    if ([string]::IsNullOrWhiteSpace($SelectedPath)) { return }
    if ($Mode -eq 'file') {
        $base = [IO.Path]::GetDirectoryName($SelectedPath)
        $default = Join-Path $base 'Upscaled'
    } else {
        $full = [IO.Path]::GetFullPath($SelectedPath).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $parent = [IO.Path]::GetDirectoryName($full)
        $leaf = [IO.Path]::GetFileName($full)
        $default = Join-Path $parent ($leaf + '-Upscaled')
    }
    $global:OutputPath.Text = $default
}

function global:Update-InputSummary {
    if ([string]::IsNullOrWhiteSpace($global:InputPath.Text)) {
        $global:InputSummary.Text = 'No source selected'
        return
    }
    if ($global:InputMode -eq 'file') {
        $global:InputSummary.Text = '1 image selected'
        return
    }
    if ($global:InputMode -eq 'folder') {
        try {
            $folder = $global:InputPath.Text
            $options = @{ LiteralPath=$folder; File=$true; ErrorAction='SilentlyContinue' }
            if ($global:Recurse.IsChecked) { $options.Recurse = $true }
            $count = @(Get-ChildItem @options | Where-Object { (Get-ImageExtensions) -contains $_.Extension.ToLowerInvariant() }).Count
            $global:InputSummary.Text = "$count supported images found"
        } catch { $global:InputSummary.Text = 'Folder selected' }
    }
}

function global:Get-SelectedFiles {
    param([string]$OutputRoot)
    $selected = [IO.Path]::GetFullPath($global:InputPath.Text)
    if ($global:InputMode -eq 'file') {
        if (!(Test-Path -LiteralPath $selected -PathType Leaf)) { throw 'Choose an existing image file.' }
        if ((Get-ImageExtensions) -notcontains ([IO.Path]::GetExtension($selected).ToLowerInvariant())) { throw 'Choose a supported image: PNG, JPEG, WebP, BMP, TIFF, or GIF.' }
        return @([pscustomobject]@{ Source=$selected; Relative=[IO.Path]::GetFileName($selected) })
    }
    if ($global:InputMode -ne 'folder' -or !(Test-Path -LiteralPath $selected -PathType Container)) { throw 'Choose an image or a folder first.' }
    $sourceRoot = $selected.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $outputFull = [IO.Path]::GetFullPath($OutputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $outputPrefix = $outputFull + [IO.Path]::DirectorySeparatorChar
    $options = @{ LiteralPath=$sourceRoot; File=$true; ErrorAction='Stop' }
    if ($global:Recurse.IsChecked) { $options.Recurse = $true }
    $files = @(Get-ChildItem @options | Where-Object {
        $ext = $_.Extension.ToLowerInvariant()
        $insideOutput = $_.FullName.StartsWith($outputPrefix,[StringComparison]::OrdinalIgnoreCase)
        ((Get-ImageExtensions) -contains $ext) -and !$insideOutput
    } | Sort-Object FullName)
    $result = @()
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))
        $result += [pscustomobject]@{ Source=$file.FullName; Relative=$relative }
    }
    return $result
}

function global:Get-NonClobberPath {
    param([string]$Directory,[string]$RelativePath,[string]$Format)
    $relativeDirectory = [IO.Path]::GetDirectoryName($RelativePath)
    $destinationDirectory = if ([string]::IsNullOrWhiteSpace($relativeDirectory)) { $Directory } else { Join-Path $Directory $relativeDirectory }
    $null = [IO.Directory]::CreateDirectory($destinationDirectory)
    $name = [IO.Path]::GetFileNameWithoutExtension($RelativePath)
    $extension = if ($Format -eq 'jpg') { 'jpg' } else { $Format }
    $candidate = Join-Path $destinationDirectory ($name + '-upscaled-x4.' + $extension)
    $index = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $destinationDirectory ($name + '-upscaled-x4-' + $index + '.' + $extension)
        $index++
    }
    return $candidate
}

function global:Quote-WindowsArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped = [regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"' + $escaped + '"'
}

function global:Start-ToolProcess {
    param([Parameter(Mandatory=$true)][string]$Executable,[Parameter(Mandatory=$true)][string[]]$Arguments,[Parameter(Mandatory=$true)][string]$WorkingDirectory,[Parameter(Mandatory=$true)][string]$LogBase)
    if (!(Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Required tool not found: $Executable. Run Setup Manga Upscale AI.cmd." }
    $argumentLine = (($Arguments | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' ')
    $exitCodePath = $LogBase + '.exitcode.txt'
    $exe64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Executable))
    $argumentsJson = ConvertTo-Json -InputObject $Arguments -Compress
    $arguments64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentsJson))
    $exitPath64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($exitCodePath))
    $worker = '$ErrorActionPreference = ''Stop''; ' +
        '$exe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $exe64 + ''')); ' +
        '$nativeArgsJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $arguments64 + ''')); ' +
        '$nativeArgs = @([string[]](ConvertFrom-Json -InputObject $nativeArgsJson)); ' +
        '$exitPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $exitPath64 + ''')); ' +
        'try { & $exe @nativeArgs; $toolCode = $LASTEXITCODE; if ($null -eq $toolCode) { $toolCode = 127 }; [IO.File]::WriteAllText($exitPath,[string]$toolCode); exit [int]$toolCode } ' +
        'catch { [Console]::Error.WriteLine($_.Exception.ToString()); [IO.File]::WriteAllText($exitPath,''127''); exit 127 }'
    $encodedWorker = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
    $workerArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encodedWorker
    $powerShellExe = (Get-Command 'powershell.exe' -CommandType Application -ErrorAction Stop).Source
    $process = Start-Process -FilePath $powerShellExe -ArgumentList $workerArgs -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput ($LogBase + '.stdout.txt') -RedirectStandardError ($LogBase + '.stderr.txt')
    Add-Member -InputObject $process -NotePropertyName MangaUpscaleCommandLine -NotePropertyValue ('"' + $Executable + '" ' + $argumentLine) -Force
    Add-Member -InputObject $process -NotePropertyName MangaUpscaleExitCodePath -NotePropertyValue $exitCodePath -Force
    return $process
}

function global:Save-JobDiagnostics {
    param([Parameter(Mandatory=$true)]$Job,[string]$ExitCode='unknown',[string]$ErrorText='')
    try {
        $logRoot = $Job.LogRoot
        if ([string]::IsNullOrWhiteSpace([string]$logRoot)) {
            $logRoot = Join-Path $Job.OutputRoot '.manga-upscale-logs'
        }
        $null = [IO.Directory]::CreateDirectory($logRoot)
        $item = $Job.Files[$Job.Index]
        $sourceName = [IO.Path]::GetFileNameWithoutExtension($item.Source)
        $safeName = [regex]::Replace($sourceName,'[^A-Za-z0-9._-]','_')
        $prefix = Join-Path $logRoot ('{0:D2}-{1}-{2}' -f ($Job.Index + 1),$safeName,$Job.Stage)
        if (![string]::IsNullOrWhiteSpace([string]$Job.WorkDir)) {
            foreach ($suffix in @('stdout.txt','stderr.txt')) {
                $sourceLog = Join-Path $Job.WorkDir ($Job.Stage + '.' + $suffix)
                if (Test-Path -LiteralPath $sourceLog -PathType Leaf) {
                    Copy-Item -LiteralPath $sourceLog -Destination ($prefix + '-' + $suffix) -Force
                }
            }
        }
        $statusSource = [string]$Job.LastExitCodePath
        if (![string]::IsNullOrWhiteSpace($statusSource) -and (Test-Path -LiteralPath $statusSource -PathType Leaf)) {
            Copy-Item -LiteralPath $statusSource -Destination ($prefix + '-exitcode.txt') -Force
        }
        $commandLine = [string]$Job.LastCommandLine
        if (![string]::IsNullOrWhiteSpace([string]$Job.LastExitCode)) { $ExitCode = [string]$Job.LastExitCode }
        $report = @(
            "Source: $($item.Source)"
            "Stage: $($Job.Stage)"
            "Exit code: $ExitCode"
            "Process id: $($Job.LastProcessId)"
            "Process reported exited: $($Job.LastProcessExited)"
            "Expected output: $($Job.LastExpectedOutput)"
            "Expected output bytes: $($Job.LastExpectedOutputBytes)"
            "Command: $commandLine"
            "Error: $ErrorText"
        )
        $reportPath = $prefix + '-report.txt'
        Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8
        return $reportPath
    } catch { return '' }
}

function global:Start-CurrentStage {
    $job = $global:JobState
    $item = $job.Files[$job.Index]
    switch ($job.Stage) {
        'decode' {
            $args = @('-hide_banner','-loglevel','error','-y','-i',$item.Source,'-frames:v','1','-pix_fmt','rgba','-f','image2',$job.Decoded)
            $job.Process = Start-ToolProcess -Executable $global:FFmpegExe -Arguments $args -WorkingDirectory (Split-Path -Parent $global:FFmpegExe) -LogBase (Join-Path $job.WorkDir 'decode')
            $global:JobStatus.Text = "[$($job.Index + 1)/$($job.Files.Count)] Decoding $([IO.Path]::GetFileName($item.Source))…"
        }
        'upscale' {
            $args = @('-i',$job.Decoded,'-o',$job.Upscaled,'-n','realesrgan-x4plus-anime','-s','4','-t',[string]$job.Tile,'-m',$global:ModelFolder,'-f','png')
            $job.Process = Start-ToolProcess -Executable $global:RealExe -Arguments $args -WorkingDirectory (Split-Path -Parent $global:RealExe) -LogBase (Join-Path $job.WorkDir 'upscale')
            $global:JobStatus.Text = "[$($job.Index + 1)/$($job.Files.Count)] Upscaling ×4 $([IO.Path]::GetFileName($item.Source))…"
        }
        'encode' {
            $args = @('-hide_banner','-loglevel','error','-y','-i',$job.Upscaled,'-frames:v','1')
            if ($job.Format -eq 'jpg') {
                $args += @('-q:v','2','-pix_fmt','yuvj420p','-f','image2',$job.Encoded)
            } elseif ($job.Format -eq 'webp') {
                $args += @('-q:v','95','-compression_level','6','-f','webp',$job.Encoded)
            } else {
                $args += @('-compression_level','6','-f','image2',$job.Encoded)
            }
            $job.Process = Start-ToolProcess -Executable $global:FFmpegExe -Arguments $args -WorkingDirectory (Split-Path -Parent $global:FFmpegExe) -LogBase (Join-Path $job.WorkDir 'encode')
            $global:JobStatus.Text = "[$($job.Index + 1)/$($job.Files.Count)] Saving $([IO.Path]::GetFileName($job.Final))…"
        }
        default { throw "Invalid upscaling stage: $($job.Stage)" }
    }
    $global:JobState = $job
}

function global:Remove-CurrentWork {
    $job = $global:JobState
    if ($null -eq $job) { return }
    if ($null -ne $job.Process) {
        try { $job.Process.Dispose() } catch { }
        $job.Process = $null
    }
    if (![string]::IsNullOrWhiteSpace($job.WorkDir) -and (Test-Path -LiteralPath $job.WorkDir)) {
        Remove-Item -LiteralPath $job.WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function global:Complete-CurrentFile {
    param([bool]$Success,[string]$Message)
    $job = $global:JobState
    $item = $job.Files[$job.Index]
    if (!$Success) {
        $diagnosticPath = Save-JobDiagnostics -Job $job -ErrorText $Message
        if (![string]::IsNullOrWhiteSpace($diagnosticPath)) { $Message += " Diagnostics: $diagnosticPath" }
    }
    Remove-CurrentWork
    if ($Success) {
        $job.Succeeded++
        Add-LogLine "Saved: $($job.Final)"
    } else {
        $job.Failed++
        Add-LogLine "FAILED: $($item.Source) — $Message"
    }
    $job.Index++
    $global:JobState = $job
    $global:JobProgress.Value = [Math]::Min(100,[Math]::Round(($job.Index / [double]$job.Files.Count) * 100))
    Start-NextFile
}

function global:Start-NextFile {
    $job = $global:JobState
    if ($null -eq $job) { return }
    if ($job.Cancelled) {
        if ($null -ne $job.Process) {
            try { if (!$job.Process.HasExited) { $job.Process.Kill(); $job.Process.WaitForExit(3000) } } catch { }
        }
        Remove-CurrentWork
        $global:Timer.Stop()
        $global:JobStatus.Text = "Cancelled · $($job.Succeeded) completed · $($job.Failed) failed"
        $global:JobState = $null
        $global:CancelButton.IsEnabled = $false
        $global:PickImageButton.IsEnabled = $true
        $global:PickFolderButton.IsEnabled = $true
        $global:OpenOutputButton.IsEnabled = Test-Path -LiteralPath $job.OutputRoot
        return
    }
    if ($job.Index -ge $job.Files.Count) {
        $global:Timer.Stop()
        $global:JobStatus.Text = "Finished · $($job.Succeeded) completed · $($job.Failed) failed"
        Add-LogLine $global:JobStatus.Text
        $global:JobState = $null
        $global:CancelButton.IsEnabled = $false
        $global:PickImageButton.IsEnabled = $true
        $global:PickFolderButton.IsEnabled = $true
        $global:OpenOutputButton.IsEnabled = Test-Path -LiteralPath $job.OutputRoot
        return
    }
    try {
        $item = $job.Files[$job.Index]
        $job.Final = Get-NonClobberPath -Directory $job.OutputRoot -RelativePath $item.Relative -Format $job.Format
        $job.WorkDir = Join-Path (Split-Path -Parent $job.Final) ('.manga-upscale-work-' + [Guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($job.WorkDir)
        $job.Decoded = Join-Path $job.WorkDir 'decoded.png'
        $job.Upscaled = Join-Path $job.WorkDir 'upscaled.png'
        $job.Encoded = Join-Path $job.WorkDir ('encoded.' + $(if ($job.Format -eq 'jpg') { 'jpg' } else { $job.Format }))
        $job.Stage = 'decode'
        $global:JobState = $job
        Start-CurrentStage
    } catch {
        $message = $_.Exception.Message
        $diagnosticPath = Save-JobDiagnostics -Job $job -ErrorText $message
        if (![string]::IsNullOrWhiteSpace($diagnosticPath)) { $message += " Diagnostics: $diagnosticPath" }
        Remove-CurrentWork
        Add-LogLine "FAILED: $($job.Files[$job.Index].Source) — $message"
        $job.Failed++
        $job.Index++
        $global:JobState = $job
        $global:JobProgress.Value = [Math]::Min(100,[Math]::Round(($job.Index / [double]$job.Files.Count) * 100))
        Start-NextFile
    }
}

function global:Update-ActiveJob {
    $job = $global:JobState
    if ($null -eq $job) { return }
    if ($job.Cancelled) { Start-NextFile; return }
    if ($null -eq $job.Process) { return }
    try { $job.Process.Refresh(); $exited = $job.Process.HasExited } catch { $exited = $true }
    if (!$exited) { return }
    $exitCode = $null
    $exitReadError = ''
    $job.LastProcessId = $job.Process.Id
    $job.LastProcessExited = $exited
    if ($job.Process.PSObject.Properties['MangaUpscaleExitCodePath']) {
        $job.LastExitCodePath = [string]$job.Process.MangaUpscaleExitCodePath
    }
    if ($job.Process.PSObject.Properties['MangaUpscaleCommandLine']) {
        $job.LastCommandLine = [string]$job.Process.MangaUpscaleCommandLine
    }
    try {
        $job.Process.WaitForExit()
        $job.Process.Refresh()
        $exitCode = $job.Process.ExitCode
    } catch { $exitReadError = $_.Exception.Message }
    if (![string]::IsNullOrWhiteSpace($job.LastExitCodePath) -and (Test-Path -LiteralPath $job.LastExitCodePath -PathType Leaf)) {
        try {
            $statusText = (Get-Content -LiteralPath $job.LastExitCodePath -Raw -ErrorAction Stop).Trim()
            $parsedStatus = 0
            if ([int]::TryParse($statusText,[ref]$parsedStatus)) {
                $exitCode = $parsedStatus
                $exitReadError = ''
            } else {
                $exitReadError = "Worker wrote a non-integer exit status: $statusText"
            }
        } catch { $exitReadError = "Could not read tool exit status: $($_.Exception.Message)" }
    }
    $job.LastExitCode = if ($null -eq $exitCode) { 'unknown' } else { [string]$exitCode }
    $expectedOutput = switch ($job.Stage) {
        'decode' { $job.Decoded }
        'upscale' { $job.Upscaled }
        'encode' { $job.Encoded }
        default { '' }
    }
    $expectedOutputBytes = 0L
    if (![string]::IsNullOrWhiteSpace($expectedOutput) -and (Test-Path -LiteralPath $expectedOutput -PathType Leaf)) {
        try { $expectedOutputBytes = (Get-Item -LiteralPath $expectedOutput).Length } catch { $expectedOutputBytes = 0L }
    }
    $job.LastExpectedOutput = $expectedOutput
    $job.LastExpectedOutputBytes = $expectedOutputBytes
    $outputLooksComplete = $expectedOutputBytes -gt 100
    $stderrPath = Join-Path $job.WorkDir ($job.Stage + '.stderr.txt')
    $toolError = ''
    if (Test-Path -LiteralPath $stderrPath) {
        try {
            $toolError = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($toolError.Length -gt 1200) { $toolError = $toolError.Substring($toolError.Length - 1200) }
        } catch { $toolError = '' }
    }
    try { $job.Process.Dispose() } catch { }
    $job.Process = $null
    $global:JobState = $job
    if ($null -eq $exitCode -and $outputLooksComplete) {
        Add-LogLine "$($job.Stage) exit status was unavailable, but its output exists ($expectedOutputBytes bytes); validating and continuing."
    } elseif ($null -eq $exitCode -or $exitCode -ne 0) {
        $exitDisplay = if ($null -eq $exitCode) { 'unknown' } else { [string]$exitCode }
        $hint = if ($job.Stage -eq 'upscale') { "Real-ESRGAN exited with code $exitDisplay. Try a smaller GPU tile size and check the NVIDIA driver." } else { "The $($job.Stage) process exited with code $exitDisplay." }
        if (![string]::IsNullOrWhiteSpace($exitReadError)) { $hint += " Exit status read error: $exitReadError" }
        if (![string]::IsNullOrWhiteSpace($toolError)) { $hint += ' ' + $toolError }
        Complete-CurrentFile -Success $false -Message $hint
        return
    }
    try {
        switch ($job.Stage) {
            'decode' {
                if (!(Test-Path -LiteralPath $job.Decoded -PathType Leaf)) { throw 'FFmpeg completed without producing a decoded page.' }
                $job.Stage = 'upscale'
                $global:JobState = $job
                Start-CurrentStage
            }
            'upscale' {
                if (!(Test-Path -LiteralPath $job.Upscaled -PathType Leaf) -or (Get-Item -LiteralPath $job.Upscaled).Length -lt 100) { throw 'Real-ESRGAN produced no usable PNG. Try a smaller tile size.' }
                $job.Stage = 'encode'
                $global:JobState = $job
                Start-CurrentStage
            }
            'encode' {
                if (!(Test-Path -LiteralPath $job.Encoded -PathType Leaf) -or (Get-Item -LiteralPath $job.Encoded).Length -lt 100) { throw 'FFmpeg produced no usable output image.' }
                if (Test-Path -LiteralPath $job.Final) { throw 'The output filename was created by another process; no existing file was overwritten.' }
                [IO.File]::Move($job.Encoded,$job.Final)
                Complete-CurrentFile -Success $true -Message ''
            }
        }
    } catch {
        Complete-CurrentFile -Success $false -Message $_.Exception.Message
    }
}

function global:Start-UpscaleJob {
    if (!(Get-RuntimeReady)) {
        [System.Windows.MessageBox]::Show('Install the local upscaling tools first.','Manga Upscale AI','OK','Information') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($global:OutputPath.Text)) {
        [System.Windows.MessageBox]::Show('Choose an output folder.','Manga Upscale AI','OK','Information') | Out-Null
        return
    }
    try {
        $outputRoot = [IO.Path]::GetFullPath($global:OutputPath.Text.Trim())
        $files = @(Get-SelectedFiles -OutputRoot $outputRoot)
        if ($files.Count -eq 0) { throw 'No supported images were found in that selection.' }
        $tileItem = [System.Windows.Controls.ComboBoxItem]$global:TileSize.SelectedItem
        $tile = [int]$tileItem.Tag
        $format = Get-OutputFormatValue
        $null = [IO.Directory]::CreateDirectory($outputRoot)
        $runLogRoot = Join-Path (Join-Path $outputRoot '.manga-upscale-logs') ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'))
        $null = [IO.Directory]::CreateDirectory($runLogRoot)
        $global:ActivityLog.Clear()
        $global:JobProgress.Value = 0
        Add-LogLine "Queued $($files.Count) image(s) · model realesrgan-x4plus-anime · ×4 · tile $tile · $($format.ToUpperInvariant())"
        Add-LogLine "Failure diagnostics will be kept in: $runLogRoot"
        $global:JobState = @{
            Files=$files; OutputRoot=$outputRoot; LogRoot=$runLogRoot; Format=$format; Tile=$tile; Index=0; Succeeded=0; Failed=0
            Stage=''; Process=$null; LastCommandLine=''; LastExitCode=''; LastExitCodePath=''; LastProcessId=''; LastProcessExited=$false
            LastExpectedOutput=''; LastExpectedOutputBytes=0L; WorkDir=''; Decoded=''; Upscaled=''; Encoded=''; Final=''; Cancelled=$false
        }
        $global:CancelButton.IsEnabled = $true
        $global:PickImageButton.IsEnabled = $false
        $global:PickFolderButton.IsEnabled = $false
        $global:OpenOutputButton.IsEnabled = $false
        $global:Timer.Start()
        Start-NextFile
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message,'Manga Upscale AI','OK','Warning') | Out-Null
    }
}

$global:Timer = New-Object Windows.Threading.DispatcherTimer
$global:Timer.Interval = [TimeSpan]::FromMilliseconds(300)
$global:Timer.Add_Tick({ Update-ActiveJob })

$global:PickImageButton.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Choose one image to upscale'
    $dialog.Filter = 'Supported images|*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.tif;*.tiff;*.gif|All files|*.*'
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($global:Window)) {
        $global:InputMode = 'file'
        $global:InputPath.Text = $dialog.FileName
        $global:Recurse.IsEnabled = $false
        $global:InputSummary.Text = '1 image selected'
        Set-DefaultOutput -SelectedPath $dialog.FileName -Mode file
    }
})
$global:PickFolderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a folder containing images'
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $global:InputMode = 'folder'
        $global:InputPath.Text = $dialog.SelectedPath
        $global:Recurse.IsEnabled = $true
        Update-InputSummary
        Set-DefaultOutput -SelectedPath $dialog.SelectedPath -Mode folder
    }
})
$global:ClearButton.Add_Click({
    $global:InputMode = ''
    $global:InputPath.Clear()
    $global:InputSummary.Text = 'No source selected'
    $global:Recurse.IsEnabled = $true
})
$global:PickOutputButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose where upscaled copies should be saved'
    $dialog.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $global:OutputPath.Text -PathType Container) { $dialog.SelectedPath = $global:OutputPath.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $global:OutputPath.Text = $dialog.SelectedPath }
})
$global:Recurse.Add_Click({ if ($global:InputMode -eq 'folder') { Update-InputSummary } })
$global:SetupButton.Add_Click({
    $setupScript = Join-Path $global:UpscaleScriptDir 'Setup.ps1'
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $setupScript + '"'))
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $global:AppRoot | Out-Null
})
$global:RefreshButton.Add_Click({ Refresh-RuntimeStatus })
$global:Window.FindName('CancelButton').Add_Click({
    if ($null -ne $global:JobState) {
        $global:JobState.Cancelled = $true
        $global:JobStatus.Text = 'Stopping after the active image…'
        if ($null -ne $global:JobState.Process) {
            try { if (!$global:JobState.Process.HasExited) { $global:JobState.Process.Kill() } } catch { }
        }
    }
})
$global:Window.FindName('OpenOutputButton').Add_Click({
    if (!(Test-Path -LiteralPath $global:OutputPath.Text -PathType Container)) { return }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + [IO.Path]::GetFullPath($global:OutputPath.Text) + '"') | Out-Null
})
$global:Window.FindName('StartButton').Add_Click({ Start-UpscaleJob })
$global:Window.Add_Closing({ param($sender,$e)
    if ($null -ne $global:JobState) {
        $answer = [System.Windows.MessageBox]::Show('An image is being processed. Stop it and close Manga Upscale AI?','Manga Upscale AI','YesNo','Warning')
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true; return }
        $global:JobState.Cancelled = $true
        if ($null -ne $global:JobState.Process) { try { if (!$global:JobState.Process.HasExited) { $global:JobState.Process.Kill(); $global:JobState.Process.WaitForExit(3000) } } catch { } }
        Remove-CurrentWork
    }
    $global:Timer.Stop()
})

Refresh-RuntimeStatus
$global:JobStatus.Text = 'Ready · choose an image or folder'
$global:Application = New-Object System.Windows.Application
$null = $global:Application.Run($global:Window)
