$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
$taskLocal=Join-Path $taskRoot '.local'
$taskPython=Join-Path (Split-Path $taskRoot -Parent) 'xiaozhi-sandbox-lab\.venv\Scripts\python.exe'
$taskPidFile=Join-Path $taskLocal 'task-worker.pid'
if (Test-Path -LiteralPath $taskPidFile) {
    $taskPreviousId=[int](Get-Content -LiteralPath $taskPidFile -Raw)
    $taskPrevious=Get-CimInstance Win32_Process -Filter "ProcessId=$taskPreviousId" -ErrorAction SilentlyContinue
    if ($taskPrevious -and $taskPrevious.CommandLine -like '*worker.py*') {
        Write-Host '本机执行器已运行。'
        exit 0
    }
}
$taskProcess=Start-Process -FilePath $taskPython -ArgumentList 'worker.py' -WorkingDirectory (Join-Path $taskRoot 'Richard-im') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskLocal 'task-worker.log') -RedirectStandardError (Join-Path $taskLocal 'task-worker.err.log') -PassThru
$taskProcess.Id | Set-Content -LiteralPath $taskPidFile
Write-Host '真实 Hermes 执行器已启动。App 中创建任务后会申请 ACS 浏览器资源；取消或完成后执行器会回收。'
