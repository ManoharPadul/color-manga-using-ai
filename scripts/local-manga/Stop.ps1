. "$PSScriptRoot/Common.ps1"
$pidFile = Join-Path $AiRoot 'backend.pid'
if (!(Test-Path $pidFile)) { Write-Host 'No owned backend process recorded.'; return }
$backendId = 0
if (![int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$backendId)) { throw 'Invalid backend PID file.' }
$process = Get-CimInstance Win32_Process -Filter "ProcessId = $backendId"
if ($null -eq $process) { Write-Host 'Backend is already stopped.'; return }
$expected = [IO.Path]::GetFullPath((Join-Path $PortableRoot 'python_embeded/python.exe'))
if ($process.ExecutablePath -ne $expected -or $process.CommandLine -notlike '*ComfyUI/main.py*' -or
    $process.CommandLine -notlike ('*' + (Join-Path $AiRoot 'model-paths.yaml') + '*')) {
    throw 'The recorded PID belongs to a different process; leaving it running.'
}
Stop-Process -Id $backendId -ErrorAction Stop
Write-Host 'Stopped the local inference backend and released its GPU memory.'
