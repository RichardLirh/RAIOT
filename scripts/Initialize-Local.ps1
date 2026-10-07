[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$localDir = Join-Path $repoRoot '.local'
$envFile = Join-Path $repoRoot '.env.local'
New-Item -ItemType Directory -Path $localDir -Force | Out-Null
function New-LocalSecret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}
function Protect-LocalFile([string]$Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r "*$($sid):(F)" '*S-1-5-18:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict permissions: $Path" }
}
if (-not (Test-Path -LiteralPath $envFile)) {
    $lines = @(
        '# Local Docker credentials. Generated once; keep out of Git.'
        'LOCAL_BIND_IP=127.0.0.1'
        'LOCAL_ADVERTISE_IP=127.0.0.1'
        "LOCAL_DB_PASSWORD=$(New-LocalSecret)"
        "LOCAL_DB_ROOT_PASSWORD=$(New-LocalSecret)"
        "LOCAL_REDIS_PASSWORD=$(New-LocalSecret)"
        "LOCAL_MQTT_SIGNATURE_KEY=$(New-LocalSecret)"
        'LOCAL_SERVER_SECRET='
    )
    [IO.File]::WriteAllLines($envFile, $lines, [Text.UTF8Encoding]::new($false))
    Protect-LocalFile $envFile
}
$tokenFile = Join-Path $localDir 'task-tokens.json'
if (-not (Test-Path -LiteralPath $tokenFile)) {
    $tokens = @{ owner=(New-LocalSecret); admin=(New-LocalSecret); worker=(New-LocalSecret) }
    [IO.File]::WriteAllText($tokenFile, ($tokens | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Protect-LocalFile $tokenFile
}
Write-Host 'Local credentials and task tokens are ready. Existing values were preserved.'
