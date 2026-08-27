# Owner-offline server join, driven across three REAL Hollow instances.
#
#   powershell -File scripts\fleet.ps1 -Live -Peers a,b,c
#   powershell -File scripts\fleet_owner_offline.ps1
#
# ## Why this is a script and not a scenario JSON
#
# The journey needs an instance to GO AWAY and COME BACK, and a scenario file
# has no op for that. `quit` kills an instance and nothing relaunches it, so the
# owner could never return to delete the server it created - which the fleet's
# own rule says it must. Driving it from here means the owner is stopped the way
# a user closes the app, and relaunched against the SAME data directory (its
# fixture is deliberately not restored), so the server survives the round trip.
#
# ## What it proves, that neither other harness can
#
#   1. A stranger joins a server whose OWNER is closed, served by a plain member
#      through the lowest-master fallback of the coordinator election. Both the
#      CRDT half (member row, channel list) and the MLS half (the joiner can
#      actually read the channel) have to land, in the widgets.
#   2. The owner comes back an epoch behind and heals from the reconnect alone,
#      with no channel traffic to fail a decrypt first. Before the 2026-08-27 fix
#      it stayed stale: `group_authority` named the returning owner, so its own
#      probe bailed and the member holding the newer epoch would not serve it.
#      The tell is the LAST assertion: a message sent after the owner is back
#      has to arrive, at an epoch the owner never committed.
#
# The Rust harness proves the ops converge, at five nodes and in seconds. This
# proves the app does it, in the widgets, over the real relay. Keep protocol
# depth in the harness; this stays at three instances and one journey.
#
# Windows PowerShell 5.1 is what is installed here, so no pwsh-only syntax.

param(
    # Leave the server behind instead of deleting it. For debugging only: the
    # fleet talks to servers it creates AND deletes, because these are real
    # identities on the real relay.
    [switch]$KeepServer,
    [int]$BootTimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in every message: the relay holds undelivered traffic for three
# days and these fixture identities are stable, so a fixed string can be matched
# by an EARLIER run's message and pass before the send it was waiting for.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$server = "fleet-oo-$($script:FleetVars.RUN)"

function Say($message, $colour = 'Cyan') { Write-Host "[owner-offline] $message" -ForegroundColor $colour }

function Step($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

# Relaunch ONE peer without touching its data directory. `fleet.ps1 -Live`
# restores every fixture, which would throw away the very server this journey is
# about; this is the same launch with that step deliberately left out.
function Restart-Peer($peer) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Join-Path $runRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    # The outbox is gone, so the read cursor for this peer has to go with it.
    $script:FleetConsumed[$peer] = 0

    $env:HOLLOW_DATA_DIR = $data
    $env:UI_PROBE_OUT = $out
    $env:UI_PROBE_MODE = 'live'
    $env:UI_PROBE_PEER = $peer
    $env:UI_PROBE_IDLE_MINUTES = '40'
    $env:UI_PROBE_SCENARIO_FILE = ''
    $env:UI_PROBE_STEPS = ''
    # No -RedirectStandardOutput/-RedirectStandardError, ever: they flip
    # Start-Process into inherit-handles mode and every instance then holds a
    # duplicate of this script's stdout pipe, so the script never returns.
    $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') -WorkingDirectory $dest -PassThru
    Say "relaunched $peer (pid $($proc.Id)) on its EXISTING data dir"

    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { Say "$peer is live again" 'Green'; return }
        if (-not (Get-PeerProcess $peer)) { throw "peer $peer died on relaunch.`n" + (Get-CrashTail $peer) }
        Start-Sleep -Milliseconds 300
    }
    throw "peer $peer never came back live.`n" + (Get-CrashTail $peer)
}

function Stop-Peer($peer) {
    $proc = Get-PeerProcess $peer
    if (-not $proc) { throw "peer $peer is not running, so it cannot be stopped" }
    $proc | Stop-Process -Force
    # The lock file and the SQLCipher WAL are released on exit; give the handles
    # time to drop before anything else touches that directory.
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - the owner is now OFFLINE" 'Yellow'
}

$live = Get-LivePeers
foreach ($peer in @('a', 'b', 'c')) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running. Start the fleet with: powershell -File scripts\fleet.ps1 -Live -Peers a,b,c (live: $($live -join ', '))"
    }
}
Say "run tag $($script:FleetVars.RUN), server $server"

$failure = $null
try {
    # ---- 1. Owner (a) creates the server, member (b) joins it normally ----
    foreach ($peer in @('a', 'b', 'c')) {
        Step $peer @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
    }

    Say '1/6 owner creates the server'
    Step a @{ op = 'tap'; target = 'semantics:Create a server' }
    Step a @{ op = 'enter_text'; target = 'hint:My Awesome Server'; value = $server }
    Step a @{ op = 'tap'; target = 'text:Create'; index = 0 }
    Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }
    Step a @{ op = 'open_server'; name = $server }
    Step a @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }

    Step a @{ op = 'right_click'; target = "server:$server" }
    Step a @{ op = 'tap'; target = 'menu > text:Invite people' }
    Step a @{ op = 'wait_for'; target = 'type:SelectableText'; timeout_ms = 20000 }
    Step a @{ op = 'capture'; target = 'type:SelectableText'; as = 'INVITE' }
    Step a @{ op = 'key'; value = 'escape' }

    Say '2/6 member b joins while the owner is up'
    Step b @{ op = 'tap'; target = 'semantics:Create a server' }
    Step b @{ op = 'enter_text'; target = 'hint:Invite link or server ID'; value = '${INVITE}' }
    Step b @{ op = 'tap'; target = 'text:Join'; index = 0 }
    Step b @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 90000 }
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'open_channel'; name = 'general' }
    Step a @{ op = 'open_channel'; name = 'general' }
    Step a @{ op = 'wait_for'; target = 'text:probe-b'; timeout_ms = 60000 }

    # A message both ways, so the a<->b MLS group is proven up BEFORE the owner
    # leaves. Without this a later failure could just as well be a group that
    # never formed at all.
    Step a @{ op = 'tap'; target = 'hint:Message #general' }
    Step a @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'from a ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:from a ${RUN}'; timeout_ms = 20000 }
    Step b @{ op = 'wait_for'; target = 'text:from a ${RUN}'; timeout_ms = 60000 }

    # ---- 2. The owner closes the app ----
    Say '3/6 closing the owner'
    Stop-Peer a

    # ---- 3. A stranger joins with only a plain member there to serve it ----
    Say '4/6 stranger c joins with the owner offline - THE TEST'
    Step c @{ op = 'tap'; target = 'semantics:Create a server' }
    Step c @{ op = 'enter_text'; target = 'hint:Invite link or server ID'; value = '${INVITE}' }
    Step c @{ op = 'tap'; target = 'text:Join'; index = 0 }
    Step c @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 120000 }
    Step c @{ op = 'open_server'; name = $server }
    Step c @{ op = 'open_channel'; name = 'general' }
    Step b @{ op = 'wait_for'; target = 'text:probe-c'; timeout_ms = 90000 }

    # The MLS half. A member row proves the CRDT converged and nothing else; the
    # joiner reading the channel is what proves b committed the add and the
    # Welcome landed.
    Step b @{ op = 'tap'; target = 'hint:Message #general' }
    Step b @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'owner away ${RUN}' }
    Step b @{ op = 'key'; value = 'enter' }
    Step b @{ op = 'wait_for'; target = 'text:owner away ${RUN}'; timeout_ms = 20000 }
    Step c @{ op = 'wait_for'; target = 'text:owner away ${RUN}'; timeout_ms = 90000 }
    Step c @{ op = 'tap'; target = 'hint:Message #general' }
    Step c @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'hello from c ${RUN}' }
    Step c @{ op = 'key'; value = 'enter' }
    Step c @{ op = 'wait_for'; target = 'text:hello from c ${RUN}'; timeout_ms = 20000 }
    Step b @{ op = 'wait_for'; target = 'text:hello from c ${RUN}'; timeout_ms = 90000 }

    # ---- 4. The owner comes back, an epoch behind ----
    Say '5/6 the owner returns'
    Restart-Peer a
    Step a @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
    Step a @{ op = 'open_server'; name = $server }
    Step a @{ op = 'open_channel'; name = 'general' }
    Step a @{ op = 'wait_for'; target = 'text:probe-c'; timeout_ms = 90000 }

    # The heal, in the widgets. A message sent AFTER the owner is back is
    # encrypted at an epoch the owner never committed and never saw commit, so it
    # only decrypts if the reconnect's own epoch hint healed the group.
    Step b @{ op = 'tap'; target = 'hint:Message #general' }
    Step b @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'welcome back ${RUN}' }
    Step b @{ op = 'key'; value = 'enter' }
    Step b @{ op = 'wait_for'; target = 'text:welcome back ${RUN}'; timeout_ms = 20000 }
    Step a @{ op = 'wait_for'; target = 'text:welcome back ${RUN}'; timeout_ms = 120000 }
    # And what it missed while it was closed has to be there too.
    Step a @{ op = 'wait_for'; target = 'text:hello from c ${RUN}'; timeout_ms = 120000 }

    Say '6/6 all three converged' 'Green'
    foreach ($peer in @('a', 'b', 'c')) { Step $peer @{ op = 'dump'; name = 'owner-offline' } }
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
}

# Cleanup runs whatever happened. Leaving a fleet server alive is worse than a
# noisy log: these are real identities on the real relay.
if (-not $KeepServer) {
    Say 'cleanup: deleting the server as its owner'
    try {
        if (-not (Get-PeerProcess 'a')) { Restart-Peer a }
        Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 60000 }
        Step a @{ op = 'right_click'; target = "server:$server" }
        Step a @{ op = 'tap'; target = 'menu > text:Server settings' }
        Step a @{ op = 'tap'; target = 'text:Danger'; index = 0 }
        Step a @{ op = 'tap'; target = 'text:Delete server'; index = 0 }
        # index 1: index 0 is the dialog's TITLE, and tapping a title silently
        # does nothing and PASSES.
        Step a @{ op = 'tap'; target = 'dialog > text:Delete server'; index = 1 }
        Step a @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 60000 }
        Step b @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 120000 }
        Step c @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 120000 }
        Say 'cleanup done' 'Green'
    } catch {
        Say "cleanup failed (the server may still exist): $($_.Exception.Message)" 'Red'
    }
}

if ($failure) { throw $failure }
Say 'PASS' 'Green'
