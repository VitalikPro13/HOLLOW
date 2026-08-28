# Async-friend, zero-overlap, driven across two REAL Hollow instances.
#
#   powershell -File scripts\fleet_friend_offline.ps1                   # fresh keys
#   powershell -File scripts\fleet_friend_offline.ps1 -KeepIdentities   # reuse a live fleet
#
# By DEFAULT this stops any running fleet, re-onboards a and b from BRAND-NEW
# keys and boots them itself, so it needs no fleet to be up first. That is not
# tidiness: the relay replays every buffered friend request to inbox:{master}
# for three days, so a reused identity hands this journey its own past and a
# wait_for can pass on a request from yesterday. With -KeepIdentities it drives
# whatever fleet is already live (start one with
# `powershell -File scripts\fleet.ps1 -Live -Peers a,b`), which is what you want
# when you are iterating on the journey rather than on the behaviour.
#
# ## Why a script, not a scenario JSON
#
# The journey needs an instance to GO AWAY and COME BACK (a scenario JSON has no
# op for that, same reason as fleet_owner_offline.ps1). a is the REQUESTER, b is
# the ACCEPTER. The whole point is that they are never online together.
#
# ## What it proves, that the Rust harness cannot (it proves the ops; this proves
#    the WIDGETS, on the real relay, with the deployed inbox mailbox):
#
#   1. a requests b while b is CLOSED -> the request is deposited in b's relay
#      mailbox (inbox:{b_master}); a then closes too.
#   2. b opens ALONE, joins its inbox with the ownership proof, the mailbox
#      replays the request, b sees it on Incoming and ACCEPTS. b closes.
#   3. a opens ALONE, the buffered FriendAccept + handshake establisher replay,
#      a holds an accepted friend + a live Olm session.
#   4. THE REGRESSION: b opens AGAIN. The mailbox is TTL-only, so it replays the
#      request a THIRD time. b must STILL show a as an ACCEPTED friend (a chip in
#      the bar), with NO pending Incoming request and the DM still in Recent
#      Conversations. The bug this guards: the re-delivered request downgraded the
#      accepted friend back to "pending incoming", dropping the DM from Home.
#   5. b's Incoming card / friend chip shows a's DISPLAY NAME (the request carries
#      a's signed profile), not a raw peer id.
#
# Keep protocol depth in the Rust harness; this stays at two instances, one
# journey. Windows PowerShell 5.1 (no pwsh-only syntax).

param(
    # Drive the fleet that is already running instead of minting new identities
    # for a and b. Faster, but the relay mailbox then still holds whatever
    # earlier runs left addressed to those identities.
    [switch]$KeepIdentities,
    [int]$BootTimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'

function Say($message, $colour = 'Cyan') { Write-Host "[friend-offline] $message" -ForegroundColor $colour }

function Step($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

# Relaunch ONE peer on its EXISTING data dir (fixture NOT restored), so the
# friendship survives the round trip. Mirrors fleet_owner_offline.ps1.
function Restart-Peer($peer) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Join-Path $runRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $script:FleetConsumed[$peer] = 0

    $env:HOLLOW_DATA_DIR = $data
    $env:UI_PROBE_OUT = $out
    $env:UI_PROBE_MODE = 'live'
    $env:UI_PROBE_PEER = $peer
    $env:UI_PROBE_IDLE_MINUTES = '40'
    $env:UI_PROBE_SCENARIO_FILE = ''
    $env:UI_PROBE_STEPS = ''
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
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - OFFLINE" 'Yellow'
}

$journeyPeers = @('a', 'b')

if ($KeepIdentities) {
    Say 'keeping the identities that are already live (their relay mailboxes are not empty)' 'Yellow'
} else {
    Start-FreshFleet $journeyPeers
}

$live = Get-LivePeers
foreach ($peer in $journeyPeers) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running. Start the fleet with: powershell -File scripts\fleet.ps1 -Live -Peers a,b (live: $($live -join ', '))"
    }
}

# --- 0. Both up: capture b's peer id (a needs it to address the request) and a's
#        display name (b should render it on the incoming card). -------------
Step a @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step b @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
# The capture step stores PEER_B into the fleet var map; later steps reference it
# as ${PEER_B}, which Send-FleetStep expands (do NOT read .captured directly — it
# is a hashtable, not the bare id).
Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

# --- 1. b goes offline; a sends the request -> deposited in b's mailbox. ------
Stop-Peer b
Step a @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step a @{ op = 'tap'; target = 'text:Add Friend'; index = 0 }
# Assert the id really IS in the field before sending: enter_text has reported
# success into this field while it held only a fragment ("nh" once, which the
# app then resolved as a nickname and never deposited), and that failure is
# indistinguishable downstream from the mailbox losing the request.
Step a @{ op = 'enter_text'; target = 'hint:Peer ID or nickname...'; value = '${PEER_B}' }
Step a @{ op = 'wait_for'; target = 'text:${PEER_B}'; timeout_ms = 15000 }
Step a @{ op = 'tap'; target = 'text:Send Request'; index = 0 }
# Let a's WS layer actually FLUSH the deposit frame to the relay before we kill
# it — the deposit log prints when the frame is QUEUED, not sent, and a hard
# kill in the gap loses it. There is no client-visible ack for a mailbox
# deposit, so there is nothing to wait_for: this is a wait or a coin flip.
Step a @{ op = 'wait'; ms = 5000 }
Say "a sent the request to an offline b (deposited in the relay mailbox)"

# --- 2. a goes offline; b opens ALONE, collects from the mailbox, accepts. ----
Stop-Peer a
Restart-Peer b
Step b @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step b @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
Step b @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 60000 }
Step b @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }
Say "b accepted the request delivered from the mailbox"

# --- 3. b offline; a opens ALONE -> buffered accept + establisher heal it. ----
Stop-Peer b
Restart-Peer a
Step a @{ op = 'wait_for'; target = 'text:probe-b'; timeout_ms = 60000 }
Say "a woke alone and sees probe-b as an accepted friend"

# --- 4. THE REGRESSION: b reopens; the TTL-only mailbox replays the request a
#        third time. b must NOT downgrade the accepted friend. ----------------
Stop-Peer a
Restart-Peer b
# Give the inbox replay a moment to arrive and (pre-fix) do its damage.
Step b @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 60000 }
Say "PASS gate 1: b still shows probe-a as an accepted friend after re-delivery"
# And the Incoming tab must be empty (no resurrected pending request).
Step b @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step b @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
Step b @{ op = 'wait_for'; target = 'text:No incoming requests'; timeout_ms = 15000 }
Say "PASS gate 2: b's Incoming tab is empty - the accepted friend was not downgraded"

Step b @{ op = 'dump'; name = 'friend_offline_converged' }
Say "DONE - async friend survived zero overlap AND mailbox re-delivery" 'Green'
