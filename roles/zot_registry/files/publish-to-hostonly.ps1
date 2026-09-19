<#
.SYNOPSIS
    Forward the host-only address to the Zot registry running in WSL.

.DESCRIPTION
    WSL2 is NAT'd on its own adapter, so VMs on 192.168.56.0/24 cannot reach it.
    This forwards <HostOnlyIp>:<Port> to the WSL VM and opens the firewall for
    that subnet only. WSL changes address on every restart, so this is re-run
    by the zot_registry role rather than once.

    Requires Administrator.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WslIp,
    [int]$Port = 5000,
    [string]$HostOnlyIp = '192.168.56.1',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ruleName = 'WSL Zot registry (homelab)'

if ($Remove) {
    netsh interface portproxy delete v4tov4 listenaddress=$HostOnlyIp listenport=$Port 2>$null | Out-Null
    try { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop } catch { }
    Write-Host "Removed forwarding for ${HostOnlyIp}:${Port}"
    return
}

$hasIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -eq $HostOnlyIp }
if (-not $hasIp) {
    throw "No interface holds $HostOnlyIp. Check the VirtualBox host-only adapter."
}

netsh interface portproxy delete v4tov4 listenaddress=$HostOnlyIp listenport=$Port 2>$null | Out-Null
netsh interface portproxy add v4tov4 `
    listenaddress=$HostOnlyIp listenport=$Port `
    connectaddress=$WslIp connectport=$Port

try { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop } catch { }
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $Port -LocalAddress $HostOnlyIp -RemoteAddress '192.168.56.0/24' | Out-Null

Write-Host "${HostOnlyIp}:${Port} -> ${WslIp}:${Port}"
