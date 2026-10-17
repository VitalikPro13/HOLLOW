# The far end of a cross-machine fleet journey (fleet_remote.ps1): a server, started
# DETACHED by scripts/fleet_agent_attach.sh (fleet_agent_attach.ps1 on Windows), that
# runs fleet_lib's per-peer commands for the peers of THIS machine. It outlives any one ssh connection: a dropped connection
# loses no device, process or probe read position, and the driver reconnects.
#
# Requests are files in <dir>/req/<key>.json. Each is claimed by a rename to run/,
# answered in ans/<key>.json and never run again, so a request the driver re-sends
# after a reconnect is answered from ans/. It ends on <dir>/quit, or when no request
# came for $IdleMinutes.
#
# Not meant to be run by hand. To drive this machine's fleet directly, use fleet.ps1
# and fleet_send.ps1 as usual.

param(
    [Parameter(Mandatory = $true)][string]$Serve,
    [int]$IdleMinutes = 30,
    # Answers kept for re-sent requests.
    [int]$KeepAnswers = 300,
    # Windows (fleet_agent_attach.ps1): the attach cannot learn the pid of a server a
    # scheduled task started, so the server writes it.
    [switch]$WritePid,
    # KEY=VALUE lines applied before fleet_lib loads: a scheduled task inherits none
    # of the connection's environment.
    [string]$EnvFile = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
$dir = (Resolve-Path $Serve).Path
if ($WritePid) { [System.IO.File]::WriteAllText((Join-Path $dir 'pid'), "$PID") }
if ($EnvFile -and (Test-Path $EnvFile)) {
    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
    }
}

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet'
$script:FleetOutRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet_out'
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$utf8 = New-Object System.Text.UTF8Encoding($false)
# Save-PeerEvidence ships it with the peer's evidence: the driver no longer sees these lines live.
$script:FleetAgentLog = Join-Path (Join-Path $repoRoot '.team') ("agent-" + ((Split-Path -Leaf $dir) -replace '^agent-', '') + '.log')

# An answer appears whole or not at all: the attach script polls for the file.
function Write-Answer($name, $object) {
    $json = $object | ConvertTo-Json -Depth 24 -Compress
    $target = Join-Path $dir $name
    $tmp = Join-Path (Split-Path -Parent $target) ('.' + (Split-Path -Leaf $target) + '.tmp')
    [System.IO.File]::WriteAllText($tmp, $json, $utf8)
    Move-Item -LiteralPath $tmp -Destination $target -Force
}

function Write-AgentLog($text) { Write-Host "[agent $((Get-Date).ToString('HH:mm:ss'))] $text" }

$req = Join-Path $dir 'req'
$run = Join-Path $dir 'run'
$ans = Join-Path $dir 'ans'
foreach ($d in @($req, $run, $ans)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

Write-AgentLog "serving $dir (pid $PID)"
Write-Answer 'hello.json' @{ id = 0; ok = $true; result = (Invoke-FleetPeerCommand ([pscustomobject]@{ cmd = 'ping' })) }

$lastRequest = Get-Date
while ($true) {
    if (Test-Path (Join-Path $dir 'quit')) { Write-AgentLog 'quit'; break }
    $next = Get-ChildItem -LiteralPath $req -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc | Select-Object -First 1
    if (-not $next) {
        if (((Get-Date) - $lastRequest).TotalMinutes -ge $IdleMinutes) { Write-AgentLog "idle ${IdleMinutes} min"; break }
        [System.Threading.Thread]::Sleep(50)
        continue
    }
    $key = [System.IO.Path]::GetFileNameWithoutExtension($next.Name)
    $claimed = Join-Path $run $next.Name
    try { Move-Item -LiteralPath $next.FullName -Destination $claimed -ErrorAction Stop } catch { continue }
    $lastRequest = Get-Date
    if (Test-Path (Join-Path $ans $next.Name)) { Remove-Item -LiteralPath $claimed -Force; continue }
    $request = $null
    try {
        $request = [System.IO.File]::ReadAllText($claimed, $utf8) | ConvertFrom-Json
        Write-AgentLog "run $key $($request.cmd) $($request.peer)"
        $result = Invoke-FleetPeerCommand $request
        Write-Answer "ans/$key.json" @{ id = $key; ok = $true; result = $result }
    } catch {
        Write-AgentLog "run $key failed: $($_.Exception.Message)"
        Write-Answer "ans/$key.json" @{ id = $key; ok = $false; error = "$($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $claimed -Force -ErrorAction SilentlyContinue
    $old = @(Get-ChildItem -LiteralPath $ans -Filter '*.json' -File | Sort-Object LastWriteTimeUtc)
    if ($old.Count -gt $KeepAnswers) { $old | Select-Object -First ($old.Count - $KeepAnswers) | Remove-Item -Force -ErrorAction SilentlyContinue }
}
Remove-Item -LiteralPath (Join-Path $dir 'pid') -Force -ErrorAction SilentlyContinue
