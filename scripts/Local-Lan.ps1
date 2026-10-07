# Shared read-only address validation. Dot sourcing does not change networking.
function Resolve-LocalLanAddress {
    [CmdletBinding()]
    param([string]$IPAddress)

    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) {
        throw 'LAN mode requires Windows NetAdapter and NetTCPIP commands.'
    }
    if ($IPAddress) {
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($IPAddress, [ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $parsed.ToString() -ne $IPAddress) {
            throw 'LanIPAddress must be a complete IPv4 address, for example 192.168.0.105.'
        }
    }

    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    $indexes = @($adapters | ForEach-Object { $_.InterfaceIndex })
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.InterfaceIndex -in $indexes -and $_.AddressState -eq 'Preferred' -and
        $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' -and
        $_.PrefixLength -ge 1 -and $_.PrefixLength -le 30
    })
    if ($IPAddress) { $addresses = @($addresses | Where-Object { $_.IPAddress -eq $IPAddress }) }
    if ($addresses.Count -ne 1) {
        if ($IPAddress) { throw 'LanIPAddress is not a preferred IPv4 address on a connected physical Windows network adapter.' }
        throw 'LAN address is ambiguous or unavailable. Supply -LanIPAddress with the IPv4 of your connected Wi-Fi or Ethernet adapter.'
    }

    $address = $addresses[0]
    $bytes = [Net.IPAddress]::Parse($address.IPAddress).GetAddressBytes()
    $networkBytes = New-Object byte[] 4
    $maskBits = [int]$address.PrefixLength
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $maskBits - 8 * $i))
        $mask = if ($bits -eq 0) { 0 } else { 256 - [Math]::Pow(2, 8 - $bits) }
        $networkBytes[$i] = $bytes[$i] -band [int]$mask
    }
    $adapter = $adapters | Where-Object { $_.InterfaceIndex -eq $address.InterfaceIndex } | Select-Object -First 1
    [PSCustomObject]@{
        IPAddress = [string]$address.IPAddress
        InterfaceAlias = [string]$adapter.Name
        InterfaceIndex = [int]$address.InterfaceIndex
        PrefixLength = [int]$address.PrefixLength
        Subnet = "$($networkBytes -join '.')/$($address.PrefixLength)"
    }
}
