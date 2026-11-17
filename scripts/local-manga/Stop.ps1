. "$PSScriptRoot/Common.ps1"
$pidFile = Join-Path $AiRoot 'backend.pid'
if (!(Test-Path $pidFile)) { Write-Host 'No owned backend process recorded.'; return }
$backendId = 0
if (![int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$backendId)) { throw 'Invalid backend PID file.' }
$process = Get-CimInstance Win32_Process -Filter "ProcessId = $backendId"
if ($null -eq $process) { Write-Host 'Backend is already stopped.'; return }
$allowed = @(
    @{ python=[IO.Path]::GetFullPath((Join-Path $PortableRoot 'python_embeded/python.exe')); config=[IO.Path]::GetFullPath((Join-Path $AiRoot 'model-paths.yaml')) },
    @{ python=[IO.Path]::GetFullPath((Join-Path $AiRoot 'qwen21-cuda13/python_embeded/python.exe')); config=[IO.Path]::GetFullPath((Join-Path $AiRoot 'qwen21-cuda13/model-paths.yaml')) }
)
$owned = @($allowed | Where-Object { $process.ExecutablePath -eq $_.python -and $process.CommandLine -like '*ComfyUI/main.py*' -and $process.CommandLine.IndexOf($_.config,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
if (!$owned.Count) {
    throw 'The recorded PID belongs to a different process; leaving it running.'
}
Stop-Process -Id $backendId -ErrorAction Stop
Write-Host 'Stopped the local inference backend and released its GPU memory.'
