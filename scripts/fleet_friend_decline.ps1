# Async-friend DECLINE stays sticky, across two REAL Hollow instances.
#
#   powershell -File scripts\fleet_friend_decline.ps1                   # fresh keys
#   powershell -File scripts\fleet_friend_decline.ps1 -Decliner c
#   powershell -File scripts\fleet_friend_decline.ps1 -KeepIdentities   # reuse a live fleet
#
# By DEFAULT this stops any running fleet, re-onboards a and the decliner from
# BRAND-NEW keys and boots them itself, so it needs no fleet to be up first.
# The relay replays every buffered friend request to inbox:{master} for three
# days, and this journey's whole assertion is "Incoming is EMPTY after a
# re-delivery": on a reused identity an earlier run's request satisfies exactly
# the thing the test says must not appear. With -KeepIdentities it drives the
# fleet that is already live (start one with
# `powershell -File scripts\fleet.ps1 -Live -Peers a,b`).
#
# Companion to fleet_friend_offline.ps1. a is the REQUESTER, b the DECLINER.
#
# What it proves (the regression for the sticky-decline fix): the relay inbox
# mailbox is TTL-only, so a declined request would otherwise re-deliver on b's
# next reboot and resurface in Incoming for up to three days. With decline
# writing a `declined` tombstone, the re-delivery is ignored: after b declines
# and reboots, Incoming stays empty and no friend is created.
#
# Four gates, and the last two are the ones a single-sided test misses:
#   1. b's Incoming is empty after its reboot (the tombstone swallowed the
#      re-delivery).
#   2. b has no friend: a declined request never quietly became a friendship.
#   3. a, opened ALONE afterwards, no longer shows the outgoing request. It
#      has to learn the decline from its own mailbox with zero overlap, the
#      same way b learned the request.
#   4. b reboots a SECOND time and Incoming is still empty, which is where a
#      re-deposit on a's wake would show up.
#
# Windows PowerShell 5.1 (no pwsh-only syntax).

param(
    # The decliner. b by default. Any other peer works too (c gets its own
    # staged copy and its own data directory); the identity it onboards with is
    # new either way, so no peer is "cleaner" than another any more.
    [string]$Decliner = 'b',
    # Drive the fleet that is already running instead of minting new identities
    # for a and the decliner. Faster, but those identities then still carry
    # whatever earlier runs left in their relay mailboxes, which is the one
    # thing this journey cannot tolerate.
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

function Say($message, $colour = 'Cyan') { Write-Host "[friend-decline] $message" -ForegroundColor $colour }

function Step($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

# Relaunch ONE peer on its EXISTING data dir (fixture NOT restored). Mirrors
# fleet_owner_offline.ps1 / fleet_friend_offline.ps1.
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

# Reads the friends list out of the map-<name>.json that a `dump` step just
# wrote, as "peerId status (direction)" lines. The dump is the authority the
# widgets are only a view of: a row can vanish from the Outgoing tab while the
# provider behind it still holds the friend, and this journey is precisely
# about which of the two is telling the truth. Shape is providers.friends =
# [{peerId, status, direction?}].
#
# A dump has to be read BEFORE its peer is relaunched: Restart-Peer wipes that
# peer's output directory.
function Get-DumpFriends($peer, $name) {
    $path = Join-Path $script:FleetOutRoot "$peer\map-$name.json"
    if (-not (Test-Path $path)) { throw "no dump for $peer at $path" }
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = $json.providers.friends
    if (-not $rows) { return @() }
    return @($rows | ForEach-Object {
        $direction = ''
        if ($_.direction) { $direction = " ($($_.direction))" }
        "$($_.peerId) $($_.status)$direction"
    })
}

function Stop-Peer($peer) {
    $proc = Get-PeerProcess $peer
    if (-not $proc) { throw "peer $peer is not running, so it cannot be stopped" }
    $proc | Stop-Process -Force
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - OFFLINE" 'Yellow'
}

$journeyPeers = @('a', $Decliner)
if ($Decliner -eq 'a') { throw "the decliner cannot be 'a': a is the requester" }

if ($KeepIdentities) {
    Say 'keeping the identities that are already live (their relay mailboxes are not empty)' 'Yellow'
} else {
    Start-FreshFleet $journeyPeers
}

$live = Get-LivePeers
foreach ($peer in $journeyPeers) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running. Start the fleet with: powershell -File scripts\fleet.ps1 -Live -Peers a,$Decliner (live: $($live -join ', '))"
    }
}

# --- 0. capture BOTH master ids: a addresses the request to b's, and the
#        closing dump assertions name a's. -----------------------------------
Step a @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step $Decliner @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step $Decliner @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }
Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }

# --- 1. b offline; a sends -> deposited in b's mailbox. ----------------------
Stop-Peer $Decliner
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
# kill in the gap loses it (the fresh decliner has no prior buffer to mask it).
Step a @{ op = 'wait'; ms = 5000 }
Say "a sent the request to an offline b (deposited in the relay mailbox)"

# --- 2. a offline; b opens ALONE, collects from the mailbox, DECLINES. -------
Stop-Peer a
Restart-Peer $Decliner
Step $Decliner @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step $Decliner @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
Step $Decliner @{ op = 'wait_for'; target = 'semantics:Reject friend request'; timeout_ms = 60000 }
Step $Decliner @{ op = 'tap'; target = 'semantics:Reject friend request'; index = 0 }
Say "b declined the request delivered from the mailbox"

# --- 3. THE REGRESSION: b reboots; the TTL-only mailbox replays the request.
#        The declined tombstone must swallow it - no resurrection. -----------
Stop-Peer $Decliner
Restart-Peer $Decliner
Step $Decliner @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step $Decliner @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step $Decliner @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
Step $Decliner @{ op = 'wait_for'; target = 'text:No incoming requests'; timeout_ms = 15000 }
Say "PASS gate 1: b's Incoming is empty after re-delivery - the decline stuck"
# And no friendship was created. Scope the tab tap to the tab WIDGET: bare
# 'text:Friends' also matches the FRIENDS heading in the sidebar behind the
# dialog, and index 0 is that one, so the tap lands on something the dialog is
# covering and fails as "on screen but a click at its centre does not reach it".
# (The row's own 'tabs' semantic label is not reachable as a target; the tab
# button type is, the way probe_targets already scopes _ServerContent.)
Step $Decliner @{ op = 'tap'; target = 'type:_TabButton>text:Friends'; index = 0 }
Step $Decliner @{ op = 'wait_for'; target = 'text:No friends yet'; timeout_ms = 15000 }
Say "PASS gate 2: b has no friend - a declined request never became a friendship"

Step $Decliner @{ op = 'dump'; name = 'friend_decline_converged' }

# --- 4. a learns the DECLINE with zero overlap too: b closes, a opens alone
#        and collects the rejection from its OWN mailbox. A decline that only
#        ever reaches a while both are online is not the thing being tested.
Stop-Peer $Decliner
Restart-Peer a
Step a @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step a @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step a @{ op = 'tap'; target = 'type:_TabButton>text:Outgoing'; index = 0 }
# 'Cancel friend request' is the outgoing ROW's own action, so it is on screen
# only while a still believes the request is pending. gone: proves it left.
Step a @{ op = 'wait_for'; gone = 'semantics:Cancel friend request'; timeout_ms = 60000 }
# gone: also passes for something that was never there, so assert the empty
# state positively rather than trusting a disappearance that may not have
# needed to happen.
Step a @{ op = 'wait_for'; target = 'text:No outgoing requests'; timeout_ms = 30000 }
Say "PASS gate 3: a's outgoing request is gone - a learned the decline from its own mailbox"
Step a @{ op = 'dump'; name = 'friend_decline_requester' }
# Not "b's row is absent" but "there is nothing here at all": a declined
# request that left a tombstone row behind would still be a leak into every
# friends-list consumer, and the widget gate above cannot see the difference.
$aFriends = @(Get-DumpFriends a 'friend_decline_requester')
if ($aFriends.Count -ne 0) {
    throw "a's friends list should be EMPTY after the decline, but the dump holds $($aFriends.Count): $($aFriends -join '; ')"
}
Say "PASS gate 3b: a's friends list is empty in the dump, not just missing b's row"

# --- 5. Nothing is being re-deposited: b reboots once more and its Incoming is
#        STILL empty. If a had re-sent on waking, this is where it would show.
Stop-Peer a
Restart-Peer $Decliner
Step $Decliner @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step $Decliner @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step $Decliner @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
Step $Decliner @{ op = 'wait_for'; target = 'text:No incoming requests'; timeout_ms = 30000 }
Say "PASS gate 4: a second reboot still finds no incoming request - nothing was re-deposited"
Step $Decliner @{ op = 'dump'; name = 'friend_decline_second_reboot' }
# b is the side that has to REMEMBER: the declined tombstone is what swallows
# every re-delivery for the next three days, so it must still be there, keyed
# by a's MASTER, and be the only thing there.
$bFriends = @(Get-DumpFriends $Decliner 'friend_decline_second_reboot')
$wantA = $script:FleetVars['PEER_A']
if ($bFriends.Count -ne 1) {
    throw "b should hold exactly one friend row (a, declined), but the dump holds $($bFriends.Count): $($bFriends -join '; ')"
}
if ($bFriends[0] -notlike "*$wantA*") {
    throw "b's one friend row should be a ($wantA), but it is: $($bFriends[0])"
}
if ($bFriends[0] -notmatch 'declined') {
    throw "b's row for a should be declined, but it is: $($bFriends[0])"
}
Say "PASS gate 4b: b still holds exactly one row, a as declined, keyed by a's master"

Say "DONE - decline stays sticky across mailbox re-delivery, on BOTH sides" 'Green'
