# Sends commands to a running fleet, one at a time, in order, and prints each
# answer. This is the interactive half of the tool: `fleet.ps1 -Live` once, then
# everything else through here.
#
#   powershell -File scripts\fleet_send.ps1 -Command '[{"peer":"a","op":"look"}]'
#   powershell -File scripts\fleet_send.ps1 -Peer b -Command '{"op":"dump","name":"now"}'
#   powershell -File scripts\fleet_send.ps1 -Command '[
#      {"peer":"a","op":"enter_text","target":"field","value":"hi"},
#      {"peer":"a","op":"key","value":"enter"},
#      {"peer":"b","op":"wait_for","target":"text:hi","timeout_ms":30000},
#      {"peer":"b","op":"look"}]'
#
# **A batch can mix peers**, and that is the point: a round trip through this
# script costs about a second, but a round trip through whoever is running it
# costs a great deal more, so "A sends, B waits for it, B shows me what it has"
# should be ONE call and not three. Steps run strictly in order, each waiting
# for its answer before the next is sent.
#
# `-Peer` is the default for commands that do not carry one; `-Peer all` sends
# every command to every instance. Values captured by one step are NOT carried
# across invocations - use fleet.ps1 with a scenario file for that.
#
# The op vocabulary and target grammar live in integration_test\probe\. Start
# with `look`: it answers "what can I click here" inline, which used to cost a
# `dump`, a file read and a grep.

param(
    [string]$Peer = '',
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$live = Get-LivePeers
if ($live.Count -eq 0) {
    throw "no fleet is running. Start one with: powershell -File scripts\fleet.ps1 -Live"
}

$parsed = $Command | ConvertFrom-Json
$commands = @()
if ($parsed -is [System.Array]) { $commands = $parsed } else { $commands = @($parsed) }

$failed = $false
$index = 0
foreach ($step in $commands) {
    $index++
    $named = $step.peer
    if (-not $named) { $named = $Peer }
    if (-not $named) {
        if ($live.Count -eq 1) {
            $named = $live[0]
        } else {
            throw "command $index has no ""peer"" and -Peer was not given. Running: $($live -join ', ')"
        }
    }

    $targets = if ($named -eq 'all') { $live } else { @($named) }
    foreach ($peerName in $targets) {
        if ($live -notcontains $peerName) {
            throw "peer '$peerName' is not running. Live: $($live -join ', ')"
        }
        $what = @($step.target, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
        Write-Host ("[{0}] {1} {2}" -f $peerName, $step.op, $what) -ForegroundColor DarkGray
        $answer = Send-FleetStep $peerName $step $TimeoutSeconds
        Write-FleetAnswer $peerName $answer '   '
        if (-not $answer.ok) { $failed = $true }
    }
}

if ($failed) { exit 1 }
exit 0
