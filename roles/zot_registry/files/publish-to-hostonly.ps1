<#
.SYNOPSIS
    Make the Zot registry in WSL reachable from the VMs, permanently.

.DESCRIPTION
    WSL2 is NAT'd on its own adapter, so VMs on 192.168.56.0/24 cannot reach
    it. This forwards <HostOnlyIp>:<Port> to WSL's localhost relay on [::1]
    rather than to WSL's own IP: the relay address never changes, while the
    WSL IP changes on every restart and used to break the forward each time.

    It also registers a logon task that keeps the distro running with a
    hidden `sleep infinity`, because WSL otherwise stops a distro shortly
    after its last terminal closes, taking Zot down with it.

    Requires Administrator; run once.
#>
[CmdletBinding()]
param(
    [int]$Port = 5000,
    [string]$HostOnlyIp = '192.168.56.1',
    [string]$Distro = 'Ubuntu-24.04',
    [string]$TaskName = 'homelab-wsl',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ruleName = 'WSL Zot registry (homelab)'

# Clear both the current forward and the old per-IP one.
netsh interface portproxy delete v4tov6 listenaddress=$HostOnlyIp listenport=$Port 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenaddress=$HostOnlyIp listenport=$Port 2>$null | Out-Null
try { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop } catch { }

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed forwarding for ${HostOnlyIp}:${Port} and the $TaskName task"
    return
}

$hasIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -eq $HostOnlyIp }
if (-not $hasIp) {
    throw "No interface holds $HostOnlyIp. Check the VirtualBox host-only adapter."
}

netsh interface portproxy add v4tov6 `
    listenaddress=$HostOnlyIp listenport=$Port `
    connectaddress=::1 connectport=$Port

New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $Port -LocalAddress $HostOnlyIp -RemoteAddress '192.168.56.0/24' | Out-Null

# conhost --headless: wsl.exe is a console program and would otherwise leave
# a window open for as long as the distro runs.
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" `
    -Argument "--headless $env:WINDIR\System32\wsl.exe -d $Distro -u root -e sleep infinity"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "${HostOnlyIp}:${Port} -> [::1]:${Port}; $TaskName keeps $Distro running"
