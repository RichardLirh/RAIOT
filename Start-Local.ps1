[CmdletBinding()]
param([switch]$WithVoice, [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
& (Join-Path $repoRoot 'scripts\Initialize-Local.ps1')
$envFile = Join-Path $repoRoot '.env.local'
$dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
$dockerCli = if ($dockerCommand) { $dockerCommand.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe' }
if (-not (Test-Path -LiteralPath $dockerCli)) { throw 'Install Docker Desktop first.' }
$composeArgs = @('compose','--project-directory',$repoRoot,'--env-file',$envFile,'-f',(Join-Path $repoRoot 'compose.local.yml'))
function Invoke-LocalCompose {
    & $dockerCli @composeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed (exit $LASTEXITCODE). No processes or volumes were removed." }
}
function Read-LocalEnv {
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($envFile)) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') { $values[$Matches[1]]=$Matches[2] }
    }
    return $values
}
function Write-LocalSetting([string]$Key,[string]$Value) {
    $lines = [IO.File]::ReadAllLines($envFile)
    $found = $false
    $newLines = foreach ($line in $lines) {
        if ($line.StartsWith("$Key=")) { "$Key=$Value"; $found=$true } else { $line }
    }
    if (-not $found) { $newLines += "$Key=$Value" }
    [IO.File]::WriteAllLines($envFile, $newLines, [Text.UTF8Encoding]::new($false))
}
# Quiet validation avoids printing the expanded environment values.
Invoke-LocalCompose --profile voice config --quiet
if ($ValidateOnly) { Write-Host 'Compose configuration is valid; no containers started.'; exit 0 }
& $dockerCli info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Engine is unavailable. Restart Windows after the first WSL installation, then open Docker Desktop.' }
if ($WithVoice) {
    $senseModel = Join-Path $repoRoot 'Richard-ai-server\models\SenseVoiceSmall\model.pt'
    if (-not (Test-Path $senseModel) -or (Get-Item $senseModel -ErrorAction SilentlyContinue).Length -lt 10000000) {
        throw 'SenseVoiceSmall weights are absent. Download the official model.pt to Richard-ai-server/models/SenseVoiceSmall before using -WithVoice; see docs/local-docker.md.'
    }
}
# MySQL/Redis are private to this Compose project. Liquibase owns schema migration.
Invoke-LocalCompose up -d --build --wait --wait-timeout 360 mysql redis backend
$settings = Read-LocalEnv
$advertise = $settings['LOCAL_ADVERTISE_IP']
$parsedAddress = $null
if (-not [Net.IPAddress]::TryParse($advertise,[ref]$parsedAddress) -or $parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'LOCAL_ADVERTISE_IP must be an IPv4 address reachable by your device.'
}
if ($settings['LOCAL_MQTT_SIGNATURE_KEY'] -notmatch '^[0-9a-f]{64}$') { throw 'Invalid generated MQTT signing key.' }
$sqlClient = 'MYSQL_PWD="$MYSQL_PASSWORD" mysql --batch --skip-column-names -u "$MYSQL_USER" "$MYSQL_DATABASE"'
$secretQuery = "SELECT param_value FROM sys_params WHERE param_code='server.secret' LIMIT 1;"
$secretOutput = $secretQuery | & $dockerCli @composeArgs exec -T mysql sh -c $sqlClient
if ($LASTEXITCODE -ne 0) { throw 'Could not read the initialized local server secret.' }
$serverSecret = ([string]::Join('', $secretOutput)).Trim()
if ($serverSecret -notmatch '^[A-Za-z0-9_-]{16,128}$') { throw 'The local backend server secret was not initialized.' }
Write-LocalSetting 'LOCAL_SERVER_SECRET' $serverSecret
$updates = @"
UPDATE sys_params SET param_value='ws://${advertise}:9000/richard/v1/' WHERE param_code='server.websocket';
UPDATE sys_params SET param_value='http://${advertise}:8002/richard/ota/' WHERE param_code='server.ota';
UPDATE sys_params SET param_value='http://${advertise}:8001/' WHERE param_code='server.fronted_url';
UPDATE sys_params SET param_value='${advertise}:1883' WHERE param_code='server.mqtt_gateway';
UPDATE sys_params SET param_value='${advertise}:8884' WHERE param_code='server.udp_gateway';
UPDATE sys_params SET param_value='mqtt:8007' WHERE param_code='server.mqtt_manager_api';
UPDATE sys_params SET param_value='$($settings['LOCAL_MQTT_SIGNATURE_KEY'])' WHERE param_code='server.mqtt_signature_key';
"@
$updates | & $dockerCli @composeArgs exec -T mysql sh -c $sqlClient | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Local service address synchronization failed.' }
# Invalidate only server configuration caches in the dedicated local Redis.
Invoke-LocalCompose exec -T redis sh -c 'REDISCLI_AUTH="$LOCAL_REDIS_PASSWORD" redis-cli DEL sys:params server:config' | Out-Null
$aiConfig = @"
server:
  ip: 0.0.0.0
  port: 9000
  http_port: 9003
  websocket: ws://${advertise}:9000/richard/v1/
  vision_explain: http://${advertise}:9003/mcp/vision/explain
  auth_key: '$serverSecret'
manager-api:
  url: http://backend:8002/richard
  secret: '$serverSecret'
prompt_template: agent-base-prompt.txt
"@
$aiConfigPath = Join-Path $repoRoot '.local\ai-config.yaml'
[IO.File]::WriteAllText($aiConfigPath, $aiConfig, [Text.UTF8Encoding]::new($false))
& icacls.exe $aiConfigPath /inheritance:r /grant:r "*$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value):(F)" '*S-1-5-18:(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict AI config permissions.' }
Invoke-LocalCompose up -d --build --wait --wait-timeout 180 task-api admin
if ($WithVoice) { Invoke-LocalCompose --profile voice up -d --build --wait --wait-timeout 600 ai-server mqtt }
Invoke-LocalCompose ps
Write-Host 'Admin: http://127.0.0.1:8001/  Java API: http://127.0.0.1:8002/richard/  Task API: http://127.0.0.1:8010/'
Write-Host 'The cloud browser worker runs on Windows separately: scripts/Start-AgentWorker.ps1.'
