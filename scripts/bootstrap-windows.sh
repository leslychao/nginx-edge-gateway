#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
operation=${1:?Usage: bootstrap-windows.sh install-transport|activate-transport|firewall|schedule-renewal}
case "$(uname -s)" in MINGW*|MSYS*) ;; *) fail 'Run this bootstrap in Git Bash on Windows .107.' ;; esac
EDGE_REPO_WINDOWS=$(cygpath -w "$ROOT")
export EDGE_REPO_WINDOWS
powershell.exe -NoProfile -NonInteractive -Command "$(cat <<'POWERSHELL'
& {
    $ErrorActionPreference = "Stop"
    if (-not (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq "192.168.0.107")) { throw "Run on 192.168.0.107" }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Open Git Bash as Administrator on .107" }
}
POWERSHELL
)" || fail 'Windows bootstrap prerequisites failed.'
case "$operation" in
    install-transport)
        printf '%s\n' 'Installing GOST 3.3.0 as LocalService on temporary LAN ports 28080/28443. Public 80/443 stay unchanged.'
        mkdir -p .work/gost
        curl --fail --location --proto '=https' --tlsv1.2 \
            https://github.com/go-gost/gost/releases/download/v3.3.0/gost_3.3.0_windows_amd64.zip \
            -o .work/gost/gost.zip
        printf '%s\n' 'cc8ac946f86994a3aed47ef1f838cfb6b7649d9245c91fcb9899654b33d61170  .work/gost/gost.zip' | sha256sum -c -
        sed 's/0.0.0.0:80/192.168.0.107:28080/; s/0.0.0.0:443/192.168.0.107:28443/' deploy/gost.yaml > .work/gost/gost-test.yaml
        powershell.exe -NoProfile -NonInteractive -Command "$(cat <<'POWERSHELL'
& {
    $ErrorActionPreference = "Stop"
    if (Get-Service NginxEdgeTransport -ErrorAction SilentlyContinue) { throw "Service already exists; inspect it before replacing anything" }
    $target = Join-Path $env:ProgramData "nginx-edge-gateway"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    & icacls.exe $target /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-19:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Cannot protect the service directory" }
    Expand-Archive -LiteralPath (Join-Path $env:EDGE_REPO_WINDOWS ".work/gost/gost.zip") -DestinationPath $target -Force
    Copy-Item -LiteralPath (Join-Path $env:EDGE_REPO_WINDOWS ".work/gost/gost-test.yaml") -Destination (Join-Path $target "gost.yaml")
    $binary = Join-Path $target "gost.exe"
    $config = Join-Path $target "gost.yaml"
    $command = ([char]34 + $binary + [char]34 + " -C " + [char]34 + $config + [char]34)
    & sc.exe create NginxEdgeTransport binPath= $command start= auto obj= "NT AUTHORITY\LocalService"
    if ($LASTEXITCODE -ne 0) { throw "Service registration failed" }
    & sc.exe failure NginxEdgeTransport reset= 86400 actions= restart/5000/restart/15000/restart/60000
    if ($LASTEXITCODE -ne 0) { throw "Service recovery configuration failed" }
    Start-Service NginxEdgeTransport
}
POWERSHELL
)"
        ;;
    activate-transport)
        printf '%s\n' 'Switching the prepared GOST service to public TCP/80 and TCP/443. Helmglass must already have released those ports.'
        powershell.exe -NoProfile -NonInteractive -Command "$(cat <<'POWERSHELL'
& {
    $ErrorActionPreference = "Stop"
    if (Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 80,443) { throw "80/443 are still occupied; preserve the existing service" }
    $target = Join-Path $env:ProgramData "nginx-edge-gateway/gost.yaml"
    $backup = $target + ".previous"
    Copy-Item -LiteralPath $target -Destination $backup -Force
    Stop-Service NginxEdgeTransport
    try {
        Copy-Item -LiteralPath (Join-Path $env:EDGE_REPO_WINDOWS "deploy/gost.yaml") -Destination $target -Force
        Start-Service NginxEdgeTransport
    } catch {
        Copy-Item -LiteralPath $backup -Destination $target -Force
        Start-Service NginxEdgeTransport
        throw
    }
}
POWERSHELL
)"
        ;;
    firewall)
        printf '%s\n' 'Adding explicit Windows Firewall rules: public TCP/80,443; LAN-only test TCP/28080,28443; block LAN access to 18080/18443.'
        powershell.exe -NoProfile -NonInteractive -Command "$(cat <<'POWERSHELL'
& {
    $ErrorActionPreference = "Stop"
    if (-not (Get-NetFirewallRule -Name NginxEdgePublic -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name NginxEdgePublic -DisplayName "Nginx Edge HTTP HTTPS" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80,443
    }
    if (-not (Get-NetFirewallRule -Name NginxEdgeTest -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name NginxEdgeTest -DisplayName "Nginx Edge LAN test" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 28080,28443 -RemoteAddress LocalSubnet
    }
    if (-not (Get-NetFirewallRule -Name NginxEdgeLoopback -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name NginxEdgeLoopback -DisplayName "Nginx Edge protect PROXY listeners" -Direction Inbound -Action Block -Protocol TCP -LocalPort 18080,18443 -LocalAddress 192.168.0.107
    }
}
POWERSHELL
)"
        ;;
    schedule-renewal)
        printf '%s\n' 'Registering NginxEdgeRenew at 00:00, 06:00, 12:00, 18:00 under the current Windows user. Docker Desktop must be running.'
        powershell.exe -NoProfile -NonInteractive -Command "$(cat <<'POWERSHELL'
& {
    $ErrorActionPreference = "Stop"
    $bash = Join-Path $env:ProgramFiles "Git/bin/bash.exe"
    if (-not (Test-Path -LiteralPath $bash)) { throw "Git Bash not found" }
    $script = Join-Path $env:EDGE_REPO_WINDOWS "scripts/renew-scheduled.sh"
    $action = New-ScheduledTaskAction -Execute $bash -Argument ([char]34 + $script + [char]34)
    $triggers = @(0,6,12,18 | ForEach-Object { New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($_)) })
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    Register-ScheduledTask -TaskName NginxEdgeRenew -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
}
POWERSHELL
)"
        ;;
    *) fail 'Unknown Windows bootstrap operation' ;;
esac
