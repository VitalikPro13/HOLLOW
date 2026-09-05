# A GIF's BYTES reach a receiver that was closed when the message was sent,
# driven across two REAL Hollow instances.
#
#   powershell -File scripts\fleet_asset_offline.ps1                   # fresh keys
#   powershell -File scripts\fleet_asset_offline.ps1 -KeepIdentities   # reuse a live fleet
#
# ## Why a script, not a scenario JSON
#
# The journey needs an instance to GO AWAY and COME BACK, twice, in a
# particular order, and a scenario file has no op for that (same reason as
# fleet_owner_offline.ps1 and fleet_friend_offline.ps1).
#
# ## What it proves, that the Rust harness cannot
#
# The harness proves the pull retries at the protocol level. This proves the
# WIDGET: the box that reserves the GIF's size flips from "GIF loading" to the
# picture, on the real relay, after the holder was unreachable at the moment
# the token first rendered.
#
#   Gate 1: a and b are friends and can talk both ways.
#   Gate 2: b is CLOSED. a picks a GIF from the trending grid and sends it with
#           a caption. The message rides the relay's offline ring; the BYTES
#           never do - they live only on a.
#   Gate 3: b opens with a still up. The row arrives from the ring and the
#           picture arrives over the asset rail behind it.
#   Gate 4: THE REGRESSION. b is closed, a sends a second GIF, and then a
#           closes too. b opens ALONE: the row replays, the picture cannot,
#           and the box has to sit at "GIF loading" (before the fix it sat
#           there forever, because the single ask went into an empty room and
#           nothing ever asked again). a comes back, and the picture has to
#           follow it in with nothing re-asking from the UI.
#
# The fleet talks only to servers it creates and deletes; this journey creates
# none, so there is nothing to clean up but the fleet itself. It never wears or
# changes a profile.
#
# Windows PowerShell 5.1 is what is installed here, so no pwsh-only syntax.

param(
    # Drive the fleet that is already running instead of minting new
    # identities. Faster while iterating on the journey; the relay's mailbox
    # then still holds whatever earlier runs addressed to those identities.
    [switch]$KeepIdentities,
    # Skip the build+stage step (Start-FreshFleet builds by default).
    [switch]$SkipBuild,
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag runs a journey nobody asked for and
# reports a clean pass for it.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepIdentities, -SkipBuild and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in every message: the relay holds undelivered traffic for three
# days, so a fixed caption can be matched by an EARLIER run's message and pass
# before the send it was waiting for.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'

function Say($message, $colour = 'Cyan') { Write-Host "[asset-offline] $message" -ForegroundColor $colour }

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
# friendship, the DM history and the cached GIF bytes survive the round trip.
# Mirrors fleet_owner_offline.ps1.
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
    Say "$peer is closed - OFFLINE" 'Yellow'
}

# Open the DM with the other peer from the friends bar, so the composer is the
# DM's. The chip is addressed by TOOLTIP, the way the friend_dm scenario does
# it: a bare name matches a friend row, a dialog row and a member row alike.
function Open-Dm($peer, $friendName) {
    Step $peer @{ op = 'tap'; target = "tooltip:$friendName" }
    Step $peer @{ op = 'wait_for'; target = 'hint:Type a message...'; timeout_ms = 30000 }
    # The pane is up before the Olm session behind it necessarily is, and a
    # send into that gap is delivered one way only. There is no widget for
    # "the session is confirmed", so this is a settle rather than a wait.
    Step $peer @{ op = 'wait'; ms = 2500 }
}

# Type a caption, then pick the FIRST cell of the trending grid. The picker
# sends on click and the composer text rides along as the caption, so the row
# the receiver waits for and the GIF it waits for are the same message.
#
# The cell is addressed by widget TYPE, not by label: every cell's purpose
# label carries the GIF's own title ("Insert GIF <title>"), which is the right
# thing for a screen reader and useless as an address.
#
# $cell exists because the two sends must be DIFFERENT GIFs. Assets are
# content-addressed, so sending the same trending cell twice sends the same
# hash, the receiver already holds the bytes from the first one, and gate 4
# has nothing to watch arrive (this cost one run). A collision now fails
# loudly at gate 4's "GIF loading" rather than passing on the wrong evidence.
function Send-Gif($peer, $caption, $cell = 0) {
    Step $peer @{ op = 'tap'; target = 'hint:Type a message...' }
    Step $peer @{ op = 'enter_text'; target = 'hint:Type a message...'; value = $caption }
    Step $peer @{ op = 'tap'; target = 'semantics:Insert GIF'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_GifCell'; timeout_ms = 60000 }
    Step $peer @{ op = 'tap'; target = 'type:_GifCell'; index = $cell }
    # The row FIRST, and only then the dismiss: the pick downloads and
    # re-encodes before it hands the token over, and it checks `mounted` on
    # the way - tearing the panel down in that window swallows the send.
    #
    # `contains`, never `text`: a caption plus a token is one Text.rich whose
    # plain text carries the token's placeholder character, so an exact match
    # can never hit it (this cost one run).
    Step $peer @{ op = 'wait_for'; target = "contains:$caption"; timeout_ms = 60000 }
    # The picker is an OverlayEntry with a full-screen dismiss barrier, NOT a
    # route, so escape does nothing to it. Tapping through the barrier is what
    # closes it, and allowMiss is honest here: the barrier IS what we mean to
    # hit.
    Step $peer @{ op = 'tap'; target = 'hint:Type a message...'; allowMiss = $true }
    Step $peer @{ op = 'wait_for'; gone = 'type:_GifCell'; timeout_ms = 20000 }
    # The sender holds the bytes it just fetched, so nothing in its thread may
    # sit at "GIF loading" (a positive wait on "GIF" would pass on an EARLIER
    # GIF).
    Step $peer @{ op = 'wait_for'; gone = 'semantics:GIF loading'; timeout_ms = 60000 }
}

$journeyPeers = @('a', 'b')

if (-not $SkipBuild) {
    Say 'building and staging a,b (pass -SkipBuild when you have just built)'
    Invoke-FleetScript @('-Build', '-Peers', 'a,b')
}

if ($KeepIdentities) {
    Say 'keeping the identities that are already live (their relay mailboxes are not empty)' 'Yellow'
    if ((Get-LivePeers).Count -eq 0) {
        Say 'nothing is live (a build stops the fleet) - booting the existing fixtures'
        Invoke-FleetScript @('-Live', '-Peers', 'a,b')
        foreach ($peer in $journeyPeers) { $script:FleetConsumed[$peer] = 0 }
    }
} else {
    Start-FreshFleet $journeyPeers
}

$live = Get-LivePeers
foreach ($peer in $journeyPeers) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running. Start the fleet with: powershell -File scripts\fleet.ps1 -Live -Peers a,b (live: $($live -join ', '))"
    }
}
Say "run tag $($script:FleetVars.RUN)"

$failure = $null
try {
    # ---- Gate 1: a and b become friends and talk both ways. ----------------
    Say '1/4 friending a and b'
    Step a @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
    Step b @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
    # The capture stores PEER_B into the fleet var map; later steps reference
    # it as ${PEER_B} (do NOT read .captured directly - it is a hashtable).
    Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

    Step a @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step a @{ op = 'tap'; target = 'text:Add Friend'; index = 0 }
    # Assert the id really IS in the field before sending: enter_text has
    # reported success into this field while it held only a fragment.
    Step a @{ op = 'enter_text'; target = 'hint:Peer ID or nickname...'; value = '${PEER_B}' }
    Step a @{ op = 'wait_for'; target = 'text:${PEER_B}'; timeout_ms = 15000 }
    Step a @{ op = 'tap'; target = 'text:Send Request'; index = 0 }
    # Close the dialog before anything waits on a name: a friend row and a
    # dialog row read identically to the probe, so an open dialog turns the
    # next wait_for into a match on itself.
    Step a @{ op = 'key'; value = 'escape' }
    Step a @{ op = 'wait_for'; gone = 'type:HollowDialog'; timeout_ms = 15000 }

    Step b @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step b @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
    Step b @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 90000 }
    Step b @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }
    Step b @{ op = 'key'; value = 'escape' }
    Step b @{ op = 'wait_for'; gone = 'type:HollowDialog'; timeout_ms = 15000 }
    Step a @{ op = 'wait_for'; target = 'text:probe-b'; timeout_ms = 90000 }
    Step b @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 90000 }

    Open-Dm a 'probe-b'
    Step a @{ op = 'enter_text'; target = 'hint:Type a message...'; value = 'hello from a ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 30000 }
    Open-Dm b 'probe-a'
    Step b @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 90000 }
    Step b @{ op = 'enter_text'; target = 'hint:Type a message...'; value = 'hello from b ${RUN}' }
    Step b @{ op = 'key'; value = 'enter' }
    Step b @{ op = 'wait_for'; target = 'text:hello from b ${RUN}'; timeout_ms = 30000 }
    Step a @{ op = 'wait_for'; target = 'text:hello from b ${RUN}'; timeout_ms = 90000 }
    Say 'PASS gate 1: a and b are friends and talk both ways' 'Green'

    # ---- Gate 2: b is closed; a sends a GIF into the offline ring. ---------
    Say '2/4 b closes, a sends a GIF'
    Stop-Peer b
    Send-Gif a 'gif one ${RUN}'
    Say 'PASS gate 2: a sent a GIF to a receiver that was not there' 'Green'

    # ---- Gate 3: b opens with the sender STILL UP. ------------------------
    Say '3/4 b returns while a is still up'
    Restart-Peer b
    Step b @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
    Open-Dm b 'probe-a'
    Step b @{ op = 'wait_for'; target = 'contains:gif one ${RUN}'; timeout_ms = 120000 }
    Step b @{ op = 'wait_for'; target = 'semantics:GIF'; timeout_ms = 120000 }
    Step b @{ op = 'shot'; name = 'asset_offline_gate3_rendered' }
    Say 'PASS gate 3: the row arrived from the ring and the picture followed' 'Green'

    # ---- Gate 4: the sender is offline when the receiver boots. -----------
    Say '4/4 b closes, a sends a second GIF, then a closes too - THE TEST'
    Stop-Peer b
    # A DIFFERENT cell: see Send-Gif. The same hash would already be cached on
    # the receiver and there would be nothing to wait for. Index 1 and not
    # something further down the list: the grid is a two-column masonry laid
    # out column by column, so tree index 1 is the cell directly BELOW the
    # first one and still inside the panel, while index 3 is under the fold
    # and cannot be clicked.
    Send-Gif a 'gif two ${RUN}' 1
    Stop-Peer a

    Restart-Peer b
    Step b @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
    Open-Dm b 'probe-a'
    Step b @{ op = 'wait_for'; target = 'contains:gif two ${RUN}'; timeout_ms = 120000 }
    # The row is here and the picture cannot be: nobody online holds the bytes.
    Step b @{ op = 'wait_for'; target = 'semantics:GIF loading'; timeout_ms = 60000 }
    Step b @{ op = 'wait'; ms = 15000 }
    Step b @{ op = 'wait_for'; target = 'semantics:GIF loading'; timeout_ms = 5000 }
    Step b @{ op = 'shot'; name = 'asset_offline_gate4_loading' }
    Say 'the second GIF is parked at "GIF loading" with its only holder away' 'Yellow'

    # The holder comes back. Nothing in the UI re-asks - the pull has to
    # restart itself off the holder appearing in the DM room.
    Restart-Peer a
    Step a @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
    # "gone", not "GIF": the FIRST GIF is already cached here and would match a
    # positive wait on its own, so the only honest assertion is that nothing in
    # this thread is still waiting on bytes.
    Step b @{ op = 'wait_for'; gone = 'semantics:GIF loading'; timeout_ms = 60000 }
    Step b @{ op = 'shot'; name = 'asset_offline_gate4_rendered' }
    Say 'PASS gate 4: the parked pull retried on its own and the picture landed' 'Green'

    Step a @{ op = 'dump'; name = 'asset_offline_a' }
    Step b @{ op = 'dump'; name = 'asset_offline_b' }
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
}

# No servers were created, so there is nothing on the relay to take back. Stop
# the fleet either way so the next journey starts from a known state.
Say 'stopping the fleet'
try { Invoke-FleetScript @('-Stop') } catch { Say "stop failed: $($_.Exception.Message)" 'Red' }

if ($failure) { throw $failure }
Say 'PASS - a GIF sent to a closed receiver renders once its holder is back' 'Green'
