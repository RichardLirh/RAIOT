param([switch]$WithWorker)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskLocal=Join-Path $taskRoot '.local'
$taskLab=Join-Path (Split-Path $taskRoot -Parent) 'xiaozhi-sandbox-lab'
$taskPython=Join-Path $taskLab '.venv\Scripts\python.exe'
if (!(Test-Path -LiteralPath $taskPython)) { throw '需要 Python 3.12+；当前验证环境位于 xiaozhi-sandbox-lab\.venv。' }
if (!(Test-Path -LiteralPath (Join-Path $taskLocal 'task-tokens.json'))) { throw '缺少 .local/task-tokens.json，请先执行 Initialize-Local.ps1。' }
$taskPort=Get-NetTCPConnection -LocalPort 8010 -State Listen -ErrorAction SilentlyContinue
if (!$taskPort) {
    $taskProcess=Start-Process -FilePath $taskPython -ArgumentList 'app.py' -WorkingDirectory (Join-Path $taskRoot 'Richard-im') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskLocal 'task-api.log') -RedirectStandardError (Join-Path $taskLocal 'task-api.err.log') -PassThru
    $taskProcess.Id | Set-Content -LiteralPath (Join-Path $taskLocal 'task-api.pid')
}
$taskAdb=Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (Test-Path -LiteralPath $taskAdb) {
    & $taskAdb -s 264540ab reverse tcp:8010 tcp:8010
    & $taskAdb -s 264540ab reverse tcp:18765 tcp:18765
}
if ($WithWorker) { & (Join-Path $PSScriptRoot 'Start-AgentWorker.ps1') }
Write-Host '任务 API: http://127.0.0.1:8010/health。未指定 -WithWorker 时只启动本地任务存储，不创建云资源。'
