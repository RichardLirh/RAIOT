[CmdletBinding()]
param([Parameter(Mandatory=$true)][string[]]$DeviceId)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$localDir = Join-Path $repoRoot '.local'
$devices = @($DeviceId | ForEach-Object { $_.ToLowerInvariant().Replace('_',':').Replace('-',':') } | Select-Object -Unique)
if ($devices.Count -eq 0 -or @($devices | Where-Object { $_ -notmatch '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' }).Count -gt 0) {
    throw 'Provide explicit bound device MAC addresses.'
}
New-Item -ItemType Directory -Path $localDir -Force | Out-Null
$tokenFile = Join-Path $localDir 'voice-token.txt'
$allowlistFile = Join-Path $localDir 'voice-devices.json'
function Protect-VoiceFile([string]$Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r "*$($sid):(F)" '*S-1-5-18:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict local file: $Path" }
}
if (-not (Test-Path -LiteralPath $tokenFile)) {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $secret = ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
    [IO.File]::WriteAllText($tokenFile, $secret, [Text.UTF8Encoding]::new($false))
}
if ([IO.File]::ReadAllText($tokenFile).Trim().Length -lt 32) { throw 'Existing voice token is invalid; it was not replaced.' }
Protect-VoiceFile $tokenFile
if (Test-Path -LiteralPath $allowlistFile) {
    $existing = @(Get-Content -LiteralPath $allowlistFile -Raw | ConvertFrom-Json)
    if (@(Compare-Object $existing $devices).Count -ne 0) {
        throw 'Existing device allowlist differs. Review it explicitly before changing device access.'
    }
} else {
    [IO.File]::WriteAllText($allowlistFile, (ConvertTo-Json -InputObject @($devices)), [Text.UTF8Encoding]::new($false))
}
Protect-VoiceFile $allowlistFile
Write-Host 'Voice-mail credential and explicit device allowlist are ready; existing role tokens were preserved.'
