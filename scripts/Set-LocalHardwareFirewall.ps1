[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$LanIPAddress,
    [switch]$Remove,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Local-Lan.ps1')
if ($Remove) {
    # Permit removal after DHCP changes; only exact RAIOT-owned rule names apply.
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($LanIPAddress, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.ToString() -ne $LanIPAddress) { throw 'LanIPAddress must be a complete IPv4 address.' }
    $lan = [PSCustomObject]@{ IPAddress = $LanIPAddress }
} else {
    $lan = Resolve-LocalLanAddress -IPAddress $LanIPAddress
}
$rulePrefix = "RAIOT-Hardware-$($lan.IPAddress.Replace('.', '-'))"
$rules = @(
    @{ Name = "$rulePrefix-TCP"; Protocol = 'TCP'; Ports = @('8002', '9000', '9003', '1883') },
    @{ Name = "$rulePrefix-UDP"; Protocol = 'UDP'; Ports = @('8884') }
)
$action = if ($Remove) { 'Remove' } else { 'Allow' }
foreach ($rule in $rules) {
    if ($Remove) { Write-Host "Remove RAIOT-owned rule $($rule.Name), if present." }
    else { Write-Host "$action $($rule.Protocol) $($rule.Ports -join ',') on $($lan.IPAddress) from $($lan.Subnet) via $($lan.InterfaceAlias); all network profiles." }
}
if ($ValidateOnly) {
    Write-Host 'Validation only; no firewall rules changed.'
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator to apply or remove these limited firewall rules. -ValidateOnly requires no elevation.'
}
foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    if ($existing -and $existing.Group -ne 'RAIOT local hardware') {
        throw "A firewall rule with this name belongs to another group: $($rule.Name). No change applied to this rule."
    }
    if ($Remove) {
        if ($existing -and $PSCmdlet.ShouldProcess($rule.Name, 'Remove RAIOT hardware firewall rule')) {
            Remove-NetFirewallRule -Name $rule.Name
        }
        continue
    }
    if ($PSCmdlet.ShouldProcess($rule.Name, 'Allow hardware ports only on this LAN address and from this subnet')) {
        if ($existing) {
            Set-NetFirewallRule -Name $rule.Name -Enabled True -Direction Inbound -Action Allow -Profile Any `
                -InterfaceAlias $lan.InterfaceAlias -LocalAddress $lan.IPAddress -RemoteAddress $lan.Subnet `
                -Protocol $rule.Protocol -LocalPort $rule.Ports -EdgeTraversalPolicy Block | Out-Null
        } else {
            New-NetFirewallRule -Name $rule.Name -DisplayName "RAIOT hardware $($rule.Protocol) ($($lan.IPAddress))" `
                -Group 'RAIOT local hardware' -Enabled True -Direction Inbound -Action Allow -Profile Any `
                -InterfaceAlias $lan.InterfaceAlias -LocalAddress $lan.IPAddress -RemoteAddress $lan.Subnet `
                -Protocol $rule.Protocol -LocalPort $rule.Ports -EdgeTraversalPolicy Block | Out-Null
        }
    }
}
