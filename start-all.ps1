param(
    [ValidateSet("dev", "test", "prod")]
    [string]$BackendProfile = "dev",
    [switch]$RestartAiServer,
    [string]$LogRoot = "logs\start-all",
    [string]$EnvFile = ".env.raiot",
    [switch]$SkipPortCleanup,
    [switch]$SkipEsp32HintWindow
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
[Console]::InputEncoding = $utf8NoBom

function Resolve-PathFromRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }
    return Join-Path $root $PathValue
}

function Read-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    $result = @{}
    if (-not (Test-Path -LiteralPath $PathValue)) {
        return $result
    }

    foreach ($rawLine in Get-Content -LiteralPath $PathValue -Encoding UTF8) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith("#")) { continue }
        if ($line.StartsWith("export ")) {
            $line = $line.Substring(7).Trim()
        }
        $sep = $line.IndexOf("=")
        if ($sep -lt 1) { continue }

        $key = $line.Substring(0, $sep).Trim()
        if (-not $key) { continue }

        $value = $line.Substring($sep + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $result[$key] = $value
    }

    return $result
}

function Get-SettingValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FileSettings,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$DefaultValue = ""
    )

    $envValue = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue.Trim()
    }

    if ($FileSettings.ContainsKey($Name)) {
        $fileValue = [string]$FileSettings[$Name]
        if (-not [string]::IsNullOrWhiteSpace($fileValue)) {
            return $fileValue.Trim()
        }
    }

    return $DefaultValue
}

function Convert-ToBool {
    param(
        [string]$Value,
        [bool]$DefaultValue = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "off" { return $false }
        default { return $DefaultValue }
    }
}

function Convert-ToPort {
    param(
        [string]$Value,
        [int]$DefaultValue,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    $port = 0
    if (-not [int]::TryParse($Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "Invalid port in ${Name}: $Value"
    }

    return $port
}

function Get-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }
    return $cmd.Source
}

function Get-MySqlCommand {
    $mysql = Get-ToolPath -Name "mysql"
    if ($mysql) {
        return $mysql
    }

    $fallbacks = @(
        "D:\MySQL\MySQL Server 8.0\bin\mysql.exe",
        "D:\MySQL\MySQL Server 8.4\bin\mysql.exe",
        "$env:ProgramFiles\MySQL\MySQL Server 8.0\bin\mysql.exe",
        "$env:ProgramFiles\MySQL\MySQL Server 8.4\bin\mysql.exe",
        "$env:ProgramFiles\MySQL\MySQL Server 9.0\bin\mysql.exe"
    )

    foreach ($path in $fallbacks) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return $null
}

function Escape-MySqlString {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return $Value.Replace("\", "\\").Replace("'", "''")
}

function Get-MySqlBaseArgs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MySqlHost,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [string]$User,
        [string]$Password = "",
        [string]$Database = ""
    )

    $args = @(
        "--host=$MySqlHost",
        "--port=$Port",
        "--user=$User",
        "--default-character-set=utf8mb4",
        "--batch",
        "--raw",
        "--skip-column-names"
    )

    if ($null -ne $Password) {
        $args += "--password=$Password"
    }

    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $args += "--database=$Database"
    }

    return $args
}

function Invoke-MySqlScalar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MySql,
        [Parameter(Mandatory = $true)]
        [string[]]$BaseArgs,
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $hadNativePref = $false
    $nativePrefOld = $null
    $nativePrefVar = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
    if ($nativePrefVar) {
        $hadNativePref = $true
        $nativePrefOld = [bool]$nativePrefVar.Value
    }

    try {
        if ($hadNativePref) {
            $global:PSNativeCommandUseErrorActionPreference = $false
        }
        $oldErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(& $MySql @BaseArgs -e $Sql 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorPreference
        }
    } finally {
        if ($hadNativePref) {
            $global:PSNativeCommandUseErrorActionPreference = $nativePrefOld
        }
    }

    $cleanLines = @()
    foreach ($line in $outputLines) {
        $text = [string]$line
        if ($text -match "^mysql:\s+\[Warning\]") {
            continue
        }
        $cleanLines += $text
    }

    if ($exitCode -ne 0) {
        $errorText = ($cleanLines -join " ").Trim()
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = "mysql exited with code $exitCode"
        }
        throw "mysql query failed: $errorText"
    }

    $raw = ($cleanLines | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ""
    }

    foreach ($line in ($raw -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line.Trim()
        }
    }

    return ""
}

function Invoke-MySqlNonQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MySql,
        [Parameter(Mandatory = $true)]
        [string[]]$BaseArgs,
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $hadNativePref = $false
    $nativePrefOld = $null
    $nativePrefVar = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
    if ($nativePrefVar) {
        $hadNativePref = $true
        $nativePrefOld = [bool]$nativePrefVar.Value
    }

    try {
        if ($hadNativePref) {
            $global:PSNativeCommandUseErrorActionPreference = $false
        }
        $oldErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(& $MySql @BaseArgs -e $Sql 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorPreference
        }
    } finally {
        if ($hadNativePref) {
            $global:PSNativeCommandUseErrorActionPreference = $nativePrefOld
        }
    }

    if ($exitCode -eq 0) {
        return
    }

    $cleanLines = @()
    foreach ($line in $outputLines) {
        $text = [string]$line
        if ($text -match "^mysql:\s+\[Warning\]") {
            continue
        }
        $cleanLines += $text
    }

    $errorText = ($cleanLines -join " ").Trim()
    if ([string]::IsNullOrWhiteSpace($errorText)) {
        $errorText = "mysql exited with code $exitCode"
    }
    throw "mysql command failed: $errorText"
}

function Resolve-BackendDatabaseName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackendProfile,
        [string]$DatabaseOverride = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($DatabaseOverride)) {
        return $DatabaseOverride.Trim()
    }

    $candidates = @(
        (Join-Path $root "Richard-backend\src\main\resources\application-$BackendProfile.yml"),
        (Join-Path $root "Richard-backend\src\main\resources\application.yml")
    )

    $regex = [regex]'jdbc:mysql://[^/]+/(?<db>[^?\s]+)'
    foreach ($file in $candidates) {
        if (-not (Test-Path -LiteralPath $file)) {
            continue
        }

        $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $match = $regex.Match($content)
        if ($match.Success) {
            return $match.Groups["db"].Value
        }
    }

    return "richard_esp32_server"
}

function Ensure-DatabaseExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DbName,
        [Parameter(Mandatory = $true)]
        [string]$MySqlHost,
        [Parameter(Mandatory = $true)]
        [int]$MySqlPort,
        [Parameter(Mandatory = $true)]
        [string]$MySqlUser,
        [string]$MySqlPassword = ""
    )

    $mysql = Get-MySqlCommand
    if (-not $mysql) {
        throw "mysql client not found; cannot ensure database '$DbName'."
    }

    $baseArgs = Get-MySqlBaseArgs -MySqlHost $MySqlHost -Port $MySqlPort -User $MySqlUser -Password $MySqlPassword
    $dbNameEscaped = Escape-MySqlString -Value $DbName
    $dbNameQuoted = $DbName

    $checkSql = "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$dbNameEscaped';"
    $exists = Invoke-MySqlScalar -MySql $mysql -BaseArgs $baseArgs -Sql $checkSql

    $status = "exists"
    if (-not $exists) {
        $createSql = "CREATE DATABASE IF NOT EXISTS ``$dbNameQuoted`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        Invoke-MySqlNonQuery -MySql $mysql -BaseArgs $baseArgs -Sql $createSql
        $status = "created"
    }

    $countSql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$dbNameEscaped';"
    $tableCountRaw = Invoke-MySqlScalar -MySql $mysql -BaseArgs $baseArgs -Sql $countSql
    $tableCount = 0
    if ($tableCountRaw -match "^\d+$") {
        $tableCount = [int]$tableCountRaw
    }

    return [pscustomobject]@{
        Status = $status
        DbName = $DbName
        TableCount = $tableCount
        MySqlPath = $mysql
    }
}

function Wait-SysParamsTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MySql,
        [Parameter(Mandatory = $true)]
        [string[]]$BaseArgs,
        [Parameter(Mandatory = $true)]
        [string]$DbName,
        [int]$TimeoutSeconds = 180,
        [int]$PollSeconds = 2
    )

    $dbNameEscaped = Escape-MySqlString -Value $DbName
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $sql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$dbNameEscaped' AND table_name='sys_params';"
            $existsRaw = Invoke-MySqlScalar -MySql $MySql -BaseArgs $BaseArgs -Sql $sql
            if ($existsRaw -match "^\d+$" -and [int]$existsRaw -gt 0) {
                return $true
            }
        } catch {
            # backend may still be migrating
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return $false
}

function Sync-SysParamsLanValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DbName,
        [Parameter(Mandatory = $true)]
        [string]$MySqlHost,
        [Parameter(Mandatory = $true)]
        [int]$MySqlPort,
        [Parameter(Mandatory = $true)]
        [string]$MySqlUser,
        [string]$MySqlPassword = "",
        [Parameter(Mandatory = $true)]
        [string]$HostIp,
        [Parameter(Mandatory = $true)]
        [int]$AiWsPort,
        [Parameter(Mandatory = $true)]
        [int]$BackendPort,
        [Parameter(Mandatory = $true)]
        [int]$AdminPort,
        [Parameter(Mandatory = $true)]
        [int]$MqttPort,
        [Parameter(Mandatory = $true)]
        [int]$UdpPort,
        [Parameter(Mandatory = $true)]
        [int]$MqttApiPort,
        [int]$WaitTimeoutSeconds = 180
    )

    $result = [ordered]@{
        Status = "failed"
        Message = ""
        Synced = 0
        Updated = 0
        Inserted = 0
        DbName = $DbName
    }

    if ([string]::IsNullOrWhiteSpace($HostIp) -or $HostIp -eq "127.0.0.1") {
        $result.Status = "skipped"
        $result.Message = "host ip is loopback, skip sys_params LAN sync"
        return [pscustomobject]$result
    }

    $mysql = Get-MySqlCommand
    if (-not $mysql) {
        $result.Status = "failed"
        $result.Message = "mysql client not found"
        return [pscustomobject]$result
    }

    $baseArgs = Get-MySqlBaseArgs -MySqlHost $MySqlHost -Port $MySqlPort -User $MySqlUser -Password $MySqlPassword -Database $DbName
    if (-not (Wait-SysParamsTable -MySql $mysql -BaseArgs $baseArgs -DbName $DbName -TimeoutSeconds $WaitTimeoutSeconds)) {
        $result.Status = "timeout"
        $result.Message = "sys_params table not ready within timeout"
        return [pscustomobject]$result
    }

    $items = @(
        [pscustomobject]@{
            Code = "server.websocket"
            Value = ("ws://{0}:{1}/richard/v1/" -f $HostIp, $AiWsPort)
            Remark = "websocket地址，多个用;分隔"
        },
        [pscustomobject]@{
            Code = "server.ota"
            Value = ("http://{0}:{1}/richard/ota/" -f $HostIp, $BackendPort)
            Remark = "ota地址"
        },
        [pscustomobject]@{
            Code = "server.fronted_url"
            Value = ("http://{0}:{1}/" -f $HostIp, $AdminPort)
            Remark = "下发六位验证码时显示的控制面板地址"
        },
        [pscustomobject]@{
            Code = "server.mqtt_gateway"
            Value = ("{0}:{1}" -f $HostIp, $MqttPort)
            Remark = "mqtt gateway 配置"
        },
        [pscustomobject]@{
            Code = "server.udp_gateway"
            Value = ("{0}:{1}" -f $HostIp, $UdpPort)
            Remark = "udp gateway 配置"
        },
        [pscustomobject]@{
            Code = "server.mqtt_manager_api"
            Value = ("{0}:{1}" -f $HostIp, $MqttApiPort)
            Remark = "MQTT网关管理API的地址"
        }
    )

    try {
        foreach ($item in $items) {
            $codeEscaped = Escape-MySqlString -Value $item.Code
            $valueEscaped = Escape-MySqlString -Value $item.Value
            $remarkEscaped = Escape-MySqlString -Value $item.Remark

            $existsSql = "SELECT id FROM sys_params WHERE param_code='$codeEscaped' LIMIT 1;"
            $existsId = Invoke-MySqlScalar -MySql $mysql -BaseArgs $baseArgs -Sql $existsSql

            if ($existsId -match "^\d+$") {
                $updateSql = "UPDATE sys_params SET param_value='$valueEscaped', update_date=NOW() WHERE id=$existsId;"
                Invoke-MySqlNonQuery -MySql $mysql -BaseArgs $baseArgs -Sql $updateSql
                $result.Updated++
            } else {
                $nextIdSql = "SELECT COALESCE(MAX(id), 0) + 1 FROM sys_params;"
                $nextIdRaw = Invoke-MySqlScalar -MySql $mysql -BaseArgs $baseArgs -Sql $nextIdSql
                $nextId = 1
                if ($nextIdRaw -match "^\d+$") {
                    $nextId = [int64]$nextIdRaw
                }

                $insertSql = @"
INSERT INTO sys_params (id, param_code, param_value, value_type, param_type, remark, create_date, update_date)
VALUES ($nextId, '$codeEscaped', '$valueEscaped', 'string', 1, '$remarkEscaped', NOW(), NOW());
"@
                Invoke-MySqlNonQuery -MySql $mysql -BaseArgs $baseArgs -Sql $insertSql
                $result.Inserted++
            }

            $result.Synced++
            Write-Host ("[sys_params] {0} = {1}" -f $item.Code, $item.Value) -ForegroundColor DarkCyan
        }

        $result.Status = "ok"
        $result.Message = ("synced={0}, updated={1}, inserted={2}" -f $result.Synced, $result.Updated, $result.Inserted)
    } catch {
        $result.Status = "failed"
        $result.Message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-PreferredIPv4 {
    $isInvalidIPv4 = {
        param([string]$Address)

        if ([string]::IsNullOrWhiteSpace($Address)) { return $true }
        if ($Address -eq "127.0.0.1") { return $true }
        if ($Address -like "169.254.*") { return $true }
        return $false
    }

    $isVirtualInterface = {
        param(
            [string]$Alias,
            [string]$Description
        )

        $identity = ("{0} {1}" -f $Alias, $Description).ToLowerInvariant()
        $markers = @(
            "meta",
            "vethernet",
            "hyper-v",
            "virtual",
            "vmware",
            "wsl",
            "loopback",
            "teredo",
            "isatap",
            "tunnel",
            "tap",
            "tun",
            "vpn",
            "bluetooth"
        )

        foreach ($marker in $markers) {
            if ($identity.Contains($marker)) {
                return $true
            }
        }
        return $false
    }

    try {
        $defaultRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.State -eq "Alive" -and $_.NextHop -ne "0.0.0.0" }

        $routeWeightByIndex = @{}
        foreach ($route in $defaultRoutes) {
            $ifIndex = [int]$route.InterfaceIndex
            $weight = [int]$route.RouteMetric + [int]$route.InterfaceMetric
            if (-not $routeWeightByIndex.ContainsKey($ifIndex) -or $weight -lt $routeWeightByIndex[$ifIndex]) {
                $routeWeightByIndex[$ifIndex] = $weight
            }
        }

        $adapterByIndex = @{}
        foreach ($adapter in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
            $adapterByIndex[[int]$adapter.ifIndex] = $adapter
        }

        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($config in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            $ifIndex = [int]$config.InterfaceIndex
            $ipv4 = $null
            foreach ($address in @($config.IPv4Address)) {
                if ($null -eq $address) { continue }
                if (-not (& $isInvalidIPv4 $address.IPAddress)) {
                    $ipv4 = $address.IPAddress
                    break
                }
            }
            if (-not $ipv4) { continue }

            $hasGateway = $false
            if ($config.IPv4DefaultGateway -and $config.IPv4DefaultGateway.NextHop -and $config.IPv4DefaultGateway.NextHop -ne "0.0.0.0") {
                $hasGateway = $true
            }

            $adapter = $null
            if ($adapterByIndex.ContainsKey($ifIndex)) {
                $adapter = $adapterByIndex[$ifIndex]
            }

            $alias = [string]$config.InterfaceAlias
            $description = ""
            $isUp = $true
            if ($adapter) {
                $description = [string]$adapter.InterfaceDescription
                $isUp = ($adapter.Status -eq "Up")
            }

            $isVirtual = & $isVirtualInterface $alias $description

            $typePriority = 2
            $adapterLabel = ("{0} {1}" -f $alias, $description)
            if ($adapterLabel -match "(?i)wlan|wi-?fi|wireless") {
                $typePriority = 0
            } elseif ($adapterLabel -match "(?i)ethernet") {
                $typePriority = 1
            }

            $routeWeight = 999999
            if ($routeWeightByIndex.ContainsKey($ifIndex)) {
                $routeWeight = [int]$routeWeightByIndex[$ifIndex]
            }

            $candidates.Add([pscustomobject]@{
                    IPAddress = $ipv4
                    InterfaceIndex = $ifIndex
                    InterfaceAlias = $alias
                    IsUp = $isUp
                    HasGateway = $hasGateway
                    IsVirtual = $isVirtual
                    TypePriority = $typePriority
                    RouteWeight = $routeWeight
                }) | Out-Null
        }

        $preferred = $candidates |
            Where-Object { $_.IsUp -and $_.HasGateway -and -not $_.IsVirtual } |
            Sort-Object -Property TypePriority, RouteWeight |
            Select-Object -First 1

        if (-not $preferred) {
            $preferred = $candidates |
                Where-Object { $_.IsUp -and -not $_.IsVirtual } |
                Sort-Object -Property TypePriority, RouteWeight |
                Select-Object -First 1
        }

        if (-not $preferred) {
            $preferred = $candidates |
                Where-Object { $_.HasGateway } |
                Sort-Object -Property RouteWeight |
                Select-Object -First 1
        }

        if ($preferred -and $preferred.IPAddress) {
            return $preferred.IPAddress
        }
    } catch {
        # fall through
    }

    try {
        $socket = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp
        )
        try {
            $socket.Connect("8.8.8.8", 53)
            $ip = $socket.LocalEndPoint.Address.ToString()
            if ($ip -and $ip -ne "0.0.0.0") {
                return $ip
            }
        } finally {
            $socket.Close()
            $socket.Dispose()
        }
    } catch {
        # fall through
    }

    return "127.0.0.1"
}

function Sync-Esp32OtaUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostIp,
        [Parameter(Mandatory = $true)]
        [int]$BackendPort
    )

    $result = [ordered]@{
        Status = "failed"
        Message = ""
        FilePath = Join-Path $root "Richard-esp32\sdkconfig"
        OtaUrl = ("http://{0}:{1}/richard/ota/" -f $HostIp, $BackendPort)
    }

    if ([string]::IsNullOrWhiteSpace($HostIp) -or $HostIp -eq "127.0.0.1") {
        $result.Status = "skipped"
        $result.Message = "host ip is loopback, skip OTA sync"
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $result.FilePath)) {
        $result.Status = "missing"
        $result.Message = "Richard-esp32/sdkconfig not found"
        return [pscustomobject]$result
    }

    try {
        $raw = Get-Content -LiteralPath $result.FilePath -Raw -Encoding UTF8
        if ($null -eq $raw) {
            $raw = ""
        }

        $line = "CONFIG_OTA_URL=`"$($result.OtaUrl)`""
        if ($raw -match "(?m)^CONFIG_OTA_URL=") {
            $updated = [regex]::Replace($raw, "(?m)^CONFIG_OTA_URL=.*$", $line, 1)
        } else {
            if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) {
                $raw += "`r`n"
            }
            $updated = $raw + $line + "`r`n"
        }

        if ($updated -ne $raw) {
            [System.IO.File]::WriteAllText($result.FilePath, $updated, $utf8NoBom)
            $result.Status = "updated"
            $result.Message = "CONFIG_OTA_URL synced"
        } else {
            $result.Status = "unchanged"
            $result.Message = "CONFIG_OTA_URL already up to date"
        }
    } catch {
        $result.Status = "failed"
        $result.Message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-Esp32IdfExportBatPath {
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidateSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    $addCandidate = {
        param([string]$PathValue)
        if ([string]::IsNullOrWhiteSpace($PathValue)) { return }

        $normalized = $PathValue.Trim()
        if ($candidateSet.Add($normalized)) {
            $candidates.Add($normalized) | Out-Null
        }
    }

    $envIdfPath = [Environment]::GetEnvironmentVariable("IDF_PATH")
    if (-not [string]::IsNullOrWhiteSpace($envIdfPath)) {
        & $addCandidate (Join-Path $envIdfPath "export.bat")
    }

    $flashScript = Join-Path $root "Richard-esp32\flash.cmd"
    if (Test-Path -LiteralPath $flashScript) {
        $defaultMatch = Select-String -LiteralPath $flashScript -Pattern '^set\s+"DEFAULT_IDF_PATH=(?<path>[^"]+)"' -CaseSensitive -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($defaultMatch -and $defaultMatch.Matches.Count -gt 0) {
            $defaultIdfPath = $defaultMatch.Matches[0].Groups["path"].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($defaultIdfPath)) {
                & $addCandidate (Join-Path $defaultIdfPath "export.bat")
            }
        }
    }

    $frameworkRoot = "D:\Espressif\frameworks"
    if (Test-Path -LiteralPath $frameworkRoot) {
        foreach ($dir in (Get-ChildItem -LiteralPath $frameworkRoot -Directory -Filter "esp-idf-v5.5*" -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)) {
            & $addCandidate (Join-Path $dir.FullName "export.bat")
        }
    }

    $existing = @()
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $existing += $candidate
        }
    }

    foreach ($candidate in $existing) {
        if ($candidate -match '(?i)\\esp-idf-v5\.5') {
            return $candidate
        }
    }

    if ($existing.Count -gt 0) {
        return $existing[0]
    }

    return $null
}

function Show-Esp32HintWindow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostIp,
        [Parameter(Mandatory = $true)]
        [int]$BackendPort,
        [Parameter(Mandatory = $true)]
        [psobject]$SyncResult,
        [psobject]$SysParamsSyncResult
    )

    try {
        $esp32Dir = Join-Path $root "Richard-esp32"
        $hintScript = Join-Path ([System.IO.Path]::GetTempPath()) ("raiot-esp32-hint-{0}.cmd" -f ([guid]::NewGuid().ToString("N")))
        $idfExportBat = Get-Esp32IdfExportBatPath
        $otaUrl = "http://{0}:{1}/richard/ota/" -f $HostIp, $BackendPort
        $syncStatus = "{0} - {1}" -f $SyncResult.Status, $SyncResult.Message
        $sysParamsStatus = "not-run"
        if ($SysParamsSyncResult) {
            $sysParamsStatus = "{0} - {1}" -f $SysParamsSyncResult.Status, $SysParamsSyncResult.Message
        }

        $content = @(
            "@echo off"
            "title RAIOT ESP32 提示"
            "chcp 65001 >nul"
            "echo ================================================================"
            "echo RAIOT ESP32 局域网配置提示"
            "echo ================================================================"
            "echo 当前 LAN IP      : $HostIp"
            "echo OTA 地址         : $otaUrl"
            "echo 同步结果         : $syncStatus"
            "echo sys_params 同步  : $sysParamsStatus"
            "echo 配置文件         : $($SyncResult.FilePath)"
            "echo."
            "where idf.py >nul 2>nul"
            "if errorlevel 1 ("
            "  echo [提示] 当前 CMD 未检测到 idf.py。"
            "  if defined IDF_PATH ("
            "    if exist `"%IDF_PATH%\export.bat`" echo 可先执行: call `"%IDF_PATH%\export.bat`""
            "  )"
            "  echo 也可以使用 ESP-IDF Command Prompt 打开此目录后再编译烧录。"
            ") else ("
            "  echo [OK] 已检测到 idf.py 环境。"
            ")"
            "echo."
            "echo 建议操作："
            "echo   1^) cd /d `"$esp32Dir`""
            "echo   2^) idf.py build"
            "echo   3^) flash.cmd --port COM3 --monitor"
            "echo."
            "echo 如果要打包固件："
            "echo   python scripts\\release.py ^<board_type^>"
            "echo."
            "echo 关闭此窗口不会影响 start-all 服务。"
            "echo ================================================================"
            "echo."
        ) -join "`r`n"

        [System.IO.File]::WriteAllText($hintScript, $content, $utf8NoBom)
        if ($idfExportBat) {
            Start-Process -FilePath "cmd.exe" -WorkingDirectory $esp32Dir -ArgumentList "/d /k call `"$idfExportBat`" & call `"$hintScript`"" | Out-Null
        } else {
            Write-Warning "[esp32] ESP-IDF export.bat not found, using normal CMD window."
            Start-Process -FilePath "cmd.exe" -WorkingDirectory $esp32Dir -ArgumentList "/d /k call `"$hintScript`"" | Out-Null
        }
    } catch {
        Write-Warning ("[esp32] failed to open hint window: {0}" -f $_.Exception.Message)
    }
}

function Merge-Hashtable {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Base,
        [Parameter(Mandatory = $true)]
        [hashtable]$Extra
    )

    $merged = @{}
    foreach ($key in $Base.Keys) {
        $merged[$key] = $Base[$key]
    }
    foreach ($key in $Extra.Keys) {
        $merged[$key] = $Extra[$key]
    }
    return $merged
}

function Get-OwnerPidsByPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $pidSet = New-Object System.Collections.Generic.HashSet[int]

    $tcpConns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($tcpConns) {
        foreach ($conn in $tcpConns) {
            $procId = [int]$conn.OwningProcess
            if ($procId -gt 0) {
                [void]$pidSet.Add($procId)
            }
        }
    }

    $udpEndpoints = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    if ($udpEndpoints) {
        foreach ($endpoint in $udpEndpoints) {
            $procId = [int]$endpoint.OwningProcess
            if ($procId -gt 0) {
                [void]$pidSet.Add($procId)
            }
        }
    }

    return @($pidSet)
}

function Stop-ProcessesOnPorts {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Ports
    )

    $targets = @{}
    foreach ($port in ($Ports | Sort-Object -Unique)) {
        $ownerPids = Get-OwnerPidsByPort -Port $port
        foreach ($procId in $ownerPids) {
            if ($procId -eq $PID) { continue }
            if ($procId -le 4) { continue }
            if (-not $targets.ContainsKey($procId)) {
                $targets[$procId] = New-Object System.Collections.Generic.List[int]
            }
            $targets[$procId].Add($port)
        }
    }

    if ($targets.Count -eq 0) {
        Write-Host "[cleanup] no occupied target ports"
        return
    }

    foreach ($procId in ($targets.Keys | Sort-Object)) {
        $portsText = (($targets[$procId] | Sort-Object -Unique) -join ",")
        $name = "unknown"
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) {
                $name = $proc.ProcessName
            }
        } catch {
            # ignore
        }

        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            Write-Host ("[cleanup] stopped pid={0} name={1} ports={2}" -f $procId, $name, $portsText) -ForegroundColor Yellow
        } catch {
            Write-Warning ("[cleanup] failed to stop pid={0} name={1} ports={2}: {3}" -f $procId, $name, $portsText, $_.Exception.Message)
        }
    }

    Start-Sleep -Milliseconds 300
}

function New-ManagedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Service,
        [Parameter(Mandatory = $true)]
        [string]$SessionLogDir,
        [Parameter(Mandatory = $true)]
        [string]$CombinedLog
    )

    $workDir = Join-Path $root $Service.RelativePath
    if (-not (Test-Path -LiteralPath $workDir)) {
        throw "Service path not found: $($Service.RelativePath)"
    }

    $serviceLog = Join-Path $SessionLogDir ("{0}.log" -f $Service.Name)
    New-Item -ItemType File -Path $serviceLog -Force | Out-Null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Service.FileName
    $psi.Arguments = $Service.Arguments
    $psi.WorkingDirectory = $workDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom

    if ($Service.ContainsKey("Env") -and $Service.Env) {
        foreach ($item in $Service.Env.GetEnumerator()) {
            if (-not $item.Key) { continue }
            if ($null -eq $item.Value) { continue }
            $value = [string]$item.Value
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $psi.EnvironmentVariables[[string]$item.Key] = $value
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true

    $stdoutSource = "raiot-{0}-stdout-{1}" -f $Service.Name, ([guid]::NewGuid().ToString("N"))
    $stderrSource = "raiot-{0}-stderr-{1}" -f $Service.Name, ([guid]::NewGuid().ToString("N"))
    $exitSource = "raiot-{0}-exit-{1}" -f $Service.Name, ([guid]::NewGuid().ToString("N"))

    $eventMeta = @{
        Name = $Service.Name
        Color = $Service.Color
        ServiceLog = $serviceLog
        CombinedLog = $CombinedLog
    }

    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -SourceIdentifier $stdoutSource -MessageData $eventMeta -Action {
        param($sender, $eventArgs)
        if ([string]::IsNullOrEmpty($eventArgs.Data)) { return }
        $m = $event.MessageData
        $line = "[{0}] {1}" -f $m.Name, $eventArgs.Data
        Write-Host $line -ForegroundColor $m.Color
        Add-Content -Path $m.ServiceLog -Value $eventArgs.Data -Encoding utf8
        Add-Content -Path $m.CombinedLog -Value $line -Encoding utf8
    } | Out-Null

    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -SourceIdentifier $stderrSource -MessageData $eventMeta -Action {
        param($sender, $eventArgs)
        if ([string]::IsNullOrEmpty($eventArgs.Data)) { return }
        $m = $event.MessageData
        $line = "[{0}][err] {1}" -f $m.Name, $eventArgs.Data
        Write-Host $line -ForegroundColor Red
        Add-Content -Path $m.ServiceLog -Value ("[err] " + $eventArgs.Data) -Encoding utf8
        Add-Content -Path $m.CombinedLog -Value $line -Encoding utf8
    } | Out-Null

    Register-ObjectEvent -InputObject $process -EventName Exited -SourceIdentifier $exitSource -MessageData $eventMeta -Action {
        param($sender, $eventArgs)
        $m = $event.MessageData
        $line = "[{0}] exited with code {1}" -f $m.Name, $sender.ExitCode
        $color = if ($sender.ExitCode -eq 0) { $m.Color } else { "Yellow" }
        Write-Host $line -ForegroundColor $color
        Add-Content -Path $m.ServiceLog -Value $line -Encoding utf8
        Add-Content -Path $m.CombinedLog -Value $line -Encoding utf8
    } | Out-Null

    if (-not $process.Start()) {
        throw "Failed to start service: $($Service.Name)"
    }

    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    return @{
        Name = $Service.Name
        Process = $process
        SourceIds = @($stdoutSource, $stderrSource, $exitSource)
    }
}

function Stop-ManagedProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable]$Items
    )

    foreach ($item in $Items) {
        $proc = $item.Process
        if ($null -eq $proc) { continue }
        if ($proc.HasExited) { continue }
        try {
            $proc.Kill()
            $proc.WaitForExit(5000) | Out-Null
        } catch {
            Write-Warning ("Failed to stop {0}: {1}" -f $item.Name, $_.Exception.Message)
        }
    }
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Warning "npm was not found in PATH. admin and mqtt-gateway may fail to start."
}

$envFilePath = Resolve-PathFromRoot -PathValue $EnvFile
$envSettings = Read-EnvFile -PathValue $envFilePath
$hasEnvFile = Test-Path -LiteralPath $envFilePath

$hostSetting = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_HOST_IP" -DefaultValue "auto"
$ipAutoDetect = Convert-ToBool -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_IP_AUTO_DETECT" -DefaultValue "true") -DefaultValue $true
$hostSettingLower = $hostSetting.Trim().ToLowerInvariant()
$autoMarkers = @("auto", "detect", "autodetect")

$resolvedHostIp = ""
$ipSource = ""
if (-not [string]::IsNullOrWhiteSpace($hostSetting) -and -not ($autoMarkers -contains $hostSettingLower)) {
    $resolvedHostIp = $hostSetting.Trim()
    $ipSource = "env"
} elseif ($ipAutoDetect) {
    $resolvedHostIp = Get-PreferredIPv4
    $ipSource = "auto-detected"
} else {
    $resolvedHostIp = "127.0.0.1"
    $ipSource = "fallback"
}

$mqttPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MQTT_PORT" -DefaultValue "1883") -DefaultValue 1883 -Name "RAIOT_MQTT_PORT"
$udpPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_UDP_PORT" -DefaultValue "8884") -DefaultValue 8884 -Name "RAIOT_UDP_PORT"
$mqttApiPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MQTT_API_PORT" -DefaultValue "8007") -DefaultValue 8007 -Name "RAIOT_MQTT_API_PORT"
$aiWsPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_AI_WS_PORT" -DefaultValue "9000") -DefaultValue 9000 -Name "RAIOT_AI_WS_PORT"
$aiHttpPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_AI_HTTP_PORT" -DefaultValue "9003") -DefaultValue 9003 -Name "RAIOT_AI_HTTP_PORT"
$adminPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_ADMIN_PORT" -DefaultValue "8001") -DefaultValue 8001 -Name "RAIOT_ADMIN_PORT"
$backendPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_BACKEND_PORT" -DefaultValue "8002") -DefaultValue 8002 -Name "RAIOT_BACKEND_PORT"
$mySqlHost = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MYSQL_HOST" -DefaultValue "127.0.0.1"
$mySqlPort = Convert-ToPort -Value (Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MYSQL_PORT" -DefaultValue "3306") -DefaultValue 3306 -Name "RAIOT_MYSQL_PORT"
$mySqlUser = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MYSQL_USER" -DefaultValue "root"
$mySqlPassword = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MYSQL_PASSWORD" -DefaultValue "123456"
$mySqlDatabaseOverride = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MYSQL_DATABASE" -DefaultValue ""
$resolvedDatabase = Resolve-BackendDatabaseName -BackendProfile $BackendProfile -DatabaseOverride $mySqlDatabaseOverride

$chatServerPath = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_CHAT_SERVER_PATH" -DefaultValue "/richard/v1/?from=mqtt_gateway"
if (-not $chatServerPath.StartsWith("/")) {
    $chatServerPath = "/" + $chatServerPath
}
$chatServerUrl = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_CHAT_SERVER_URL" -DefaultValue ""
if ([string]::IsNullOrWhiteSpace($chatServerUrl)) {
    $chatServerUrl = "ws://{0}:{1}{2}" -f $resolvedHostIp, $aiWsPort, $chatServerPath
}
$chatServerHost = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_CHAT_SERVER_HOST" -DefaultValue ""
if ([string]::IsNullOrWhiteSpace($chatServerHost)) {
    $chatServerHost = $resolvedHostIp
}

$mqttSignatureKey = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_MQTT_SIGNATURE_KEY" -DefaultValue ""
$serverSecret = Get-SettingValue -FileSettings $envSettings -Name "RAIOT_SERVER_SECRET" -DefaultValue ""

$aiArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($root)\Richard-ai-server\start_local.ps1`""
if ($RestartAiServer) {
    $aiArgs += " -RestartExisting"
}

$backendArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($root)\Richard-backend\start_manager_api.ps1`" -Profile $BackendProfile"

$sharedRuntimeEnv = @{
    RAIOT_HOST_IP = $resolvedHostIp
    RAIOT_MQTT_PORT = "$mqttPort"
    RAIOT_UDP_PORT = "$udpPort"
    RAIOT_MQTT_API_PORT = "$mqttApiPort"
    RAIOT_AI_WS_PORT = "$aiWsPort"
    RAIOT_AI_HTTP_PORT = "$aiHttpPort"
    RAIOT_MQTT_GATEWAY = ("{0}:{1}" -f $resolvedHostIp, $mqttPort)
    RAIOT_UDP_GATEWAY = ("{0}:{1}" -f $resolvedHostIp, $udpPort)
}
if (-not [string]::IsNullOrWhiteSpace($mqttSignatureKey)) {
    $sharedRuntimeEnv["RAIOT_MQTT_SIGNATURE_KEY"] = $mqttSignatureKey
}

$aiEnv = Merge-Hashtable -Base $sharedRuntimeEnv -Extra @{
    PYTHONUTF8 = "1"
    PYTHONIOENCODING = "utf-8"
    PYTHONLEGACYWINDOWSSTDIO = "0"
}

$mqttEnvExtra = @{
    PUBLIC_IP = $resolvedHostIp
    SERVER_IP = $resolvedHostIp
    CHAT_SERVER_HOST = $chatServerHost
    CHAT_SERVER_URL = $chatServerUrl
    MQTT_PORT = "$mqttPort"
    UDP_PORT = "$udpPort"
    API_PORT = "$mqttApiPort"
    MQTT_ENDPOINT = ("{0}:{1}" -f $resolvedHostIp, $mqttPort)
}
if (-not [string]::IsNullOrWhiteSpace($mqttSignatureKey)) {
    $mqttEnvExtra["MQTT_SIGNATURE_KEY"] = $mqttSignatureKey
}
if (-not [string]::IsNullOrWhiteSpace($serverSecret)) {
    $mqttEnvExtra["SERVER_SECRET"] = $serverSecret
}

$mqttEnv = Merge-Hashtable -Base $sharedRuntimeEnv -Extra $mqttEnvExtra

$services = @(
    @{
        Name = "admin"
        RelativePath = "Richard-admin"
        FileName = "cmd.exe"
        Arguments = "/d /c npm run dev -- --port $adminPort"
        Color = "Cyan"
    },
    @{
        Name = "ai-server"
        RelativePath = "Richard-ai-server"
        FileName = "powershell.exe"
        Arguments = $aiArgs
        Color = "Green"
        Env = $aiEnv
    },
    @{
        Name = "backend"
        RelativePath = "Richard-backend"
        FileName = "powershell.exe"
        Arguments = $backendArgs
        Color = "Magenta"
    },
    @{
        Name = "mqtt-gateway"
        RelativePath = "Richard-mqtt-gateway"
        FileName = "cmd.exe"
        Arguments = "/d /c npm start"
        Color = "Blue"
        Env = $mqttEnv
    }
)

$resolvedLogRoot = Resolve-PathFromRoot -PathValue $LogRoot
$sessionLogDir = Join-Path $resolvedLogRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Path $sessionLogDir -Force | Out-Null
$combinedLog = Join-Path $sessionLogDir "combined.log"
New-Item -ItemType File -Path $combinedLog -Force | Out-Null
$esp32SyncResult = Sync-Esp32OtaUrl -HostIp $resolvedHostIp -BackendPort $backendPort
$dbEnsureResult = Ensure-DatabaseExists `
    -DbName $resolvedDatabase `
    -MySqlHost $mySqlHost `
    -MySqlPort $mySqlPort `
    -MySqlUser $mySqlUser `
    -MySqlPassword $mySqlPassword

if ($hasEnvFile) {
    Write-Host ("[info] env file: {0}" -f $envFilePath)
} else {
    Write-Host ("[info] env file not found, using defaults: {0}" -f $envFilePath)
}
Write-Host ("[info] host ip: {0} ({1})" -f $resolvedHostIp, $ipSource)
Write-Host ("[info] mqtt endpoint: {0}:{1}" -f $resolvedHostIp, $mqttPort)
Write-Host ("[info] udp endpoint: {0}:{1}" -f $resolvedHostIp, $udpPort)
Write-Host ("[info] mqtt chat server: {0}" -f $chatServerUrl)
Write-Host ("[info] backend profile: {0}" -f $BackendProfile)
Write-Host ("[info] admin port: {0}" -f $adminPort)
Write-Host ("[info] backend port: {0}" -f $backendPort)
Write-Host ("[info] mysql: {0}:{1} user={2}" -f $mySqlHost, $mySqlPort, $mySqlUser)
Write-Host ("[info] backend database: {0}" -f $resolvedDatabase)
Write-Host ("[info] database ensure: {0}, tables={1}" -f $dbEnsureResult.Status, $dbEnsureResult.TableCount)
Write-Host ("[info] esp32 ota: {0}" -f $esp32SyncResult.OtaUrl)
Write-Host ("[info] esp32 sdkconfig sync: {0} ({1})" -f $esp32SyncResult.Status, $esp32SyncResult.Message)
Write-Host ("[info] logs: {0}" -f $sessionLogDir)
Write-Host "[flow] 1/4 database ready"
Write-Host "[info] press Ctrl+C to stop all services"
Write-Host ""

$managed = @()
$overallExit = 0
$sysParamsSyncResult = [pscustomobject]@{
    Status = "not-run"
    Message = "sync not started"
}

try {
    $portsToCleanup = @($adminPort, $backendPort, $aiWsPort, $aiHttpPort, $mqttPort, $udpPort, $mqttApiPort) | Sort-Object -Unique
    if ($SkipPortCleanup) {
        Write-Host ("[cleanup] skipped for ports: {0}" -f ($portsToCleanup -join ",")) -ForegroundColor Yellow
    } else {
        Write-Host ("[cleanup] checking ports: {0}" -f ($portsToCleanup -join ",")) -ForegroundColor Yellow
        Stop-ProcessesOnPorts -Ports $portsToCleanup
    }

    foreach ($service in $services) {
        $item = New-ManagedProcess -Service $service -SessionLogDir $sessionLogDir -CombinedLog $combinedLog
        $managed += $item
        Write-Host ("[started] {0}" -f $service.Name)
    }

    Write-Host "[flow] 2/4 services started"

    $sysParamsSyncResult = Sync-SysParamsLanValues `
        -DbName $resolvedDatabase `
        -MySqlHost $mySqlHost `
        -MySqlPort $mySqlPort `
        -MySqlUser $mySqlUser `
        -MySqlPassword $mySqlPassword `
        -HostIp $resolvedHostIp `
        -AiWsPort $aiWsPort `
        -BackendPort $backendPort `
        -AdminPort $adminPort `
        -MqttPort $mqttPort `
        -UdpPort $udpPort `
        -MqttApiPort $mqttApiPort

    if ($sysParamsSyncResult.Status -eq "ok") {
        Write-Host ("[flow] 3/4 sys_params synced ({0})" -f $sysParamsSyncResult.Message)
    } else {
        Write-Warning ("[flow] 3/4 sys_params sync {0}: {1}" -f $sysParamsSyncResult.Status, $sysParamsSyncResult.Message)
    }

    if (-not $SkipEsp32HintWindow) {
        Show-Esp32HintWindow `
            -HostIp $resolvedHostIp `
            -BackendPort $backendPort `
            -SyncResult $esp32SyncResult `
            -SysParamsSyncResult $sysParamsSyncResult
        Write-Host "[flow] 4/4 esp32 hint window opened"
    } else {
        Write-Host "[flow] 4/4 esp32 hint window skipped"
    }

    while ($true) {
        $running = $managed | Where-Object { -not $_.Process.HasExited }
        if ($running.Count -eq 0) {
            break
        }
        Start-Sleep -Seconds 1
    }

    $nonZero = $managed | Where-Object { $_.Process.ExitCode -ne 0 }
    if ($nonZero.Count -gt 0) {
        $overallExit = 1
    }
} finally {
    Stop-ManagedProcesses -Items $managed

    foreach ($item in $managed) {
        foreach ($sid in $item.SourceIds) {
            Unregister-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue
            Remove-Job -Name $sid -Force -ErrorAction SilentlyContinue
        }
    }
}

exit $overallExit

