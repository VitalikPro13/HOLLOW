# A pending server join that outlives BOTH sessions, across two REAL instances.
#
#   powershell -File scripts\fleet_pending_join.ps1                    # fresh keys, builds first
#   powershell -File scripts\fleet_pending_join.ps1 -SkipBuild         # you just built
#   powershell -File scripts\fleet_pending_join.ps1 -KeepIdentities    # drive a live fleet
#   powershell -File scripts\fleet_pending_join.ps1 -KeepUp            # leave the windows open
#
# ## Why a script and not a scenario JSON
#
# The whole journey is peers going away and coming back, and a scenario file has
# no op for that: `quit` kills an instance and nothing relaunches it. Same reason
# as fleet_owner_offline.ps1 and the two friend journeys, whose Restart-Peer /
# Stop-Peer this copies (Start-Peer WITHOUT Reset-PeerData, because a fixture
# restore would throw away the very server the journey is about).
#
# ## What it proves, that the Rust harness cannot
#
# The harness proves the ops converge with every node in one process. This proves
# the app does it, in the widgets, over the real relay, with ZERO OVERLAP: a and
# b are never online together until the last step, so every hop has to survive in
# the relay's availability rings and be replayed on a room join.
#
#   1. b asks to join a server whose only member is CLOSED. Nothing can answer,
#      so the request PARKS: the Rust side stops waiting at 15s and the strip
#      shows a pending tile instead of a failure, and b holds no real server.
#   2. a comes back ALONE. Its own room-join catch-up replays b's buffered
#      request, the coordinator serves it, and a's member panel grows to two.
#      That is the gate that proves the ring path works.
#   3. b comes back ALONE, a long gone. The buffered admission (snapshot, welcome
#      and op log) has to reach it the same way, turning the pending tile into a
#      real server with a channel list. That is the return leg.
#   4. Only then do both come up together, and a message each way proves the MLS
#      group actually formed rather than the CRDT half landing on its own.
#
# Nobody is co-present for steps 1 to 3. That is the point: a journey where the
# two ever see each other proves the live path, which already worked.
#
# ## -DeleteBeforeMessage, and the hole it guards
#
# A peer admitted through the ring holds the CRDT half of the server and NO MLS
# leaf: the leaf only forms on first co-presence, when its bootstrap KeyPackage
# finally reaches somebody who can answer it (field-observed 2026-08-29, run
# 103348: `Received MlsChannelMessage for unknown group` then `MlsWelcome` in the
# same second). Anything sent to that peer as MLS-only in the meantime is dropped
# for good, and `handle_delete_server` used to broadcast its plaintext
# `CrdtOpBroadcast` twin only when the owner's MLS send FAILED - so a member with
# no leaf kept a server that had been deleted (seen in run 102016: a wrote the
# tombstone, b logged nothing and still listed the server minutes later).
#
# With the switch the journey replaces G7 with the case that catches it: a comes
# back and deletes the server IMMEDIATELY, before any message can pull b's leaf
# into existence, and b has to lose the server anyway. That only works if the
# plaintext twin is unconditional, which is what this proves in the field.
#
# Windows PowerShell 5.1 is what is installed here, so no pwsh-only syntax, and
# `pwsh` is not a thing on this machine: run it with `powershell -File`.

param(
    # Drive the identities that are already live instead of minting new ones.
    # Faster, and wrong for a first run: the relay replays buffered room traffic
    # for three days, so a reused identity can be served an EARLIER run's join.
    [switch]$KeepIdentities,
    # Leave the instances running after a PASS. A FAILED run always leaves them
    # up, whatever this says - a failure is exactly when the screen is worth
    # looking at.
    [switch]$KeepUp,
    # Skip the build+stage step. Pass it when you have just run
    # `powershell -File scripts\fleet.ps1 -Build -Peers a,b` yourself.
    [switch]$SkipBuild,
    # Replace G7 (a message each way) with the tombstone case: a deletes the
    # server the moment it is back, BEFORE anything can give b an MLS leaf, and
    # b still has to lose it. See the header. Everything up to G6 is unchanged.
    [switch]$DeleteBeforeMessage,
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped (or, on 2026-08-29, a not-yet-declared)
# -DeleteBeforeMessage ran the STANDARD journey and reported a clean pass for a
# journey nobody asked for. A run that was asked for something else is a failed
# run, so say so before anything boots.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepIdentities, -KeepUp, -SkipBuild, -DeleteBeforeMessage and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in the server name and in every message: the relay holds
# undelivered traffic for three days, so a fixed string can be matched by an
# EARLIER run and pass before the send it was waiting for.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$server = "pj-$($script:FleetVars.RUN)"
$journeyPeers = @('a', 'b')

function Say($message, $colour = 'Cyan') { Write-Host "[pending-join] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates. Declared up front so the closing report has a line for every one of
# them, including the ones a failure meant we never reached.
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{
    'G1 a created pj-RUN, #general is there, invite captured' = 'SKIP'
    'G2 b saw the Joining server toast (soft)'                = 'SKIP'
    'G3 b shows the PENDING tile with nobody online'          = 'SKIP'
    'G4 b holds NO real server yet (dump)'                    = 'SKIP'
    'G5 a returns alone and admits b from the ring (2 rows)'  = 'SKIP'
    'G6 b returns alone to a REAL server with a channel list' = 'SKIP'
}
# The last two depend on which journey this is, and the report prints exactly
# the gates that were actually meant to run.
if ($DeleteBeforeMessage) {
    $script:Gates['G7d a deleted pj-RUN before b could form an MLS leaf'] = 'SKIP'
    $script:Gates['G8d b lost the server WITHOUT a leaf (plaintext twin)'] = 'SKIP'
    $script:CleanupGate = 'C  cleanup: no fleet server left on the relay'
} else {
    $script:Gates['G7 a message each way once both are finally up'] = 'SKIP'
    $script:CleanupGate = 'G8 cleanup: a deleted the server it created'
}
$script:Gates[$script:CleanupGate] = 'SKIP'
$script:Notes = New-Object System.Collections.ArrayList

function Set-Gate($name, $status) {
    if (-not $script:Gates.Contains($name)) { throw "unknown gate '$name'" }
    $script:Gates[$name] = $status
}

function Add-Note($text) {
    [void]$script:Notes.Add($text)
    Say "note: $text" 'DarkCyan'
}

# The first gate that never got its verdict is where the run died.
function Set-FirstUnreachedGateFailed {
    foreach ($key in @($script:Gates.Keys)) {
        if ($script:Gates[$key] -eq 'SKIP') { $script:Gates[$key] = 'FAIL'; return $key }
    }
    return $null
}

# --------------------------------------------------------------------------
# Talking to an instance
# --------------------------------------------------------------------------

function Step($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

# Same, but a failure is an ANSWER rather than the end of the run. For the
# checks worth reporting and not worth failing on: a toast that may already have
# faded, a badge whose wording is not load-bearing.
function Invoke-SoftStep($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2} (soft)" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    return $answer
}

# Wait until ANY of several targets holds, and report which one did.
# The pending tile is being built right now, so its addressable label is the one
# thing here that could reasonably differ from what this was written against:
# try the semantics label, the plain text and a substring rather than fail a
# whole journey on a target string.
function Wait-ForAnyTarget($peer, $targets, $timeoutSeconds, $sliceMs = 3000) {
    Write-Host ("  [{0}] wait_for ANY of: {1} (up to {2}s)" -f $peer, ($targets -join ' | '), $timeoutSeconds) -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        foreach ($target in $targets) {
            $answer = Send-FleetStep $peer ([pscustomobject]@{
                op = 'wait_for'; target = $target; timeout_ms = $sliceMs
            }) 180
            if ($answer.ok) {
                Write-Host "     ok   matched $target" -ForegroundColor DarkGray
                return $target
            }
        }
        # One full pass always happens before the clock is consulted, so a short
        # timeout can never mean "no candidate was ever tried".
        if ((Get-Date) -ge $deadline) { return $null }
    }
}

# "This peer is up and on the network", without depending on which screen it
# booted into. The WORD "Connected" is only printed by the Home dashboard: the
# user bar renders `connectionVisual()`, whose label for a settled connection is
# "Online", and in Dock mode that label lives ONLY in the dot's tooltip. A peer
# that lands straight in a server view (which is what a freshly-arrived server
# does - it selects itself) therefore never shows the word, and waiting for it
# cost a whole run on 2026-08-29 while the peer was connected the entire time.
# `text:Online` is deliberately NOT in the list: the member panel prints that
# word as a section divider, so it would pass for a peer that is offline.
function Wait-ForConnected($peer, $timeoutSeconds = 120) {
    $hit = Wait-ForAnyTarget $peer @('tooltip:Online', 'text:Connected') $timeoutSeconds
    if (-not $hit) {
        throw "peer $peer never reported a settled connection within ${timeoutSeconds}s (no user-bar 'Online' tooltip, no Home 'Connected')"
    }
    return $hit
}

# Relaunch ONE peer on its EXISTING data directory. `fleet.ps1 -Live` restores
# every fixture, which would throw away the pending join and the server this
# journey is about; this is the same launch with that step left out. Mirrors
# fleet_owner_offline.ps1 / fleet_friend_*.ps1.
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

# --------------------------------------------------------------------------
# Reading a dump. The widgets are a view; these are the providers behind them,
# and "the tile is pending" versus "the server is real" is exactly the kind of
# disagreement a screenshot cannot settle.
#
# A dump has to be READ BEFORE its peer is relaunched: Restart-Peer wipes that
# peer's output directory.
# --------------------------------------------------------------------------
function Get-DumpJson($peer, $name) {
    $path = Join-Path $script:FleetOutRoot "$peer\map-$name.json"
    if (-not (Test-Path $path)) { throw "no dump for $peer at $path" }
    return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-DumpServerNames($peer, $name) {
    $rows = (Get-DumpJson $peer $name).providers.servers
    if (-not $rows) { return @() }
    return @($rows | ForEach-Object { $_.name })
}

function Get-DumpChannelNames($peer, $name) {
    $rows = (Get-DumpJson $peer $name).providers.channels
    if (-not $rows) { return @() }
    return @($rows | ForEach-Object { $_.name })
}

# The strip, as the layout itself claims it: "server X", "pending join <id>",
# "folder ...". A parked join is a StripItem of its own (PendingStripItem), so
# this is where "parked" versus "a real server" is stated rather than inferred
# from a tile that happens to look dimmed.
function Get-DumpStripOutline($peer, $name) {
    $rows = (Get-DumpJson $peer $name).providers.stripOutline
    if (-not $rows) { return @() }
    return @($rows)
}

# What a peer's own log says. `hollow_debug.log` sits next to the exe, survives
# a Restart-Peer (which only wipes the probe's output directory) and accumulates
# across runs, so EVERY caller filters by this run's server id - a fixed string
# would match an earlier run's server just as happily.
function Get-PeerLogLines($peer, $pattern) {
    $path = Join-Path $script:FleetStageRoot "$peer\hollow_debug.log"
    if (-not (Test-Path $path)) { return @() }
    try {
        return @(Get-Content $path -ErrorAction Stop | Where-Object { $_ -like "*$pattern*" })
    } catch {
        # The app holds the file open for append. A read that loses that race is
        # not a verdict, so say so rather than reporting "no such line".
        Add-Note "could not read $peer's hollow_debug.log ($($_.Exception.Message))"
        return @()
    }
}

function Get-DumpServerId($peer, $name, $serverName) {
    $rows = (Get-DumpJson $peer $name).providers.servers
    if (-not $rows) { return '' }
    $row = @($rows | Where-Object { $_.name -eq $serverName }) | Select-Object -First 1
    if (-not $row) { return '' }
    return $row.id
}

# Delete a server through the UI, as its owner. Used by the tombstone journey
# AND by the cleanup, so the two can never drift apart.
function Remove-Server($peer, $name) {
    Step $peer @{ op = 'wait_for'; target = "server:$name"; timeout_ms = 60000 }
    Step $peer @{ op = 'right_click'; target = "server:$name" }
    Step $peer @{ op = 'tap'; target = 'menu > text:Server settings' }
    Step $peer @{ op = 'tap'; target = 'text:Danger'; index = 0 }
    Step $peer @{ op = 'tap'; target = 'text:Delete server'; index = 0 }
    # index 1: index 0 is the dialog's TITLE, and tapping a title silently does
    # nothing and PASSES.
    Step $peer @{ op = 'tap'; target = 'dialog > text:Delete server'; index = 1 }
    Step $peer @{ op = 'wait_for'; gone = "server:$name"; timeout_ms = 60000 }
}

# --------------------------------------------------------------------------
# Boot
# --------------------------------------------------------------------------

if (-not $SkipBuild) {
    # -Build stages only a,b unless told otherwise, and a,b is all this needs.
    Say 'building and staging a,b (pass -SkipBuild when you have just built)'
    Invoke-FleetScript @('-Build', '-Peers', 'a,b')
}

if ($KeepIdentities) {
    Say 'keeping the identities that are already live (their relay rings are not empty)' 'Yellow'
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
Say "run tag $($script:FleetVars.RUN), server $server"

$failure = $null
$serverCreated = $false
$serverDeleted = $false
# The id, not the name: every log line and every strip row names the server by
# id. Learned from the parked row at G4, confirmed against the dump at G6.
$serverId = ''

try {
    Wait-ForConnected a | Out-Null
    Wait-ForConnected b | Out-Null
    # Both ids up front: they go in the closing report, and a run that cannot say
    # which identities it drove cannot be checked against a relay log later.
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

    # ---- 1. the owner creates the server and copies its invite --------------
    Say '1/8 a creates the server and copies the invite'
    Step a @{ op = 'tap'; target = 'semantics:Create a server' }
    Step a @{ op = 'enter_text'; target = 'hint:My Awesome Server'; value = $server }
    Step a @{ op = 'tap'; target = 'text:Create'; index = 0 }
    Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }
    $serverCreated = $true
    Step a @{ op = 'open_server'; name = $server }
    Step a @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }

    Step a @{ op = 'right_click'; target = "server:$server" }
    Step a @{ op = 'tap'; target = 'menu > text:Invite people' }
    Step a @{ op = 'wait_for'; target = 'type:SelectableText'; timeout_ms = 20000 }
    # The capture crosses instances: b pastes it as ${INVITE} below.
    Step a @{ op = 'capture'; target = 'type:SelectableText'; as = 'INVITE' }
    Step a @{ op = 'key'; value = 'escape' }
    Set-Gate 'G1 a created pj-RUN, #general is there, invite captured' 'PASS'

    # ---- 2. the owner closes. Nobody who knows this server is online now. ----
    Say '2/8 closing a - from here NOBODY who knows the server is online'
    Stop-Peer a

    # ---- 3. the stranger asks to join, with nobody there to answer ----------
    Say '3/8 b joins with nobody online - THE PARK'
    Step b @{ op = 'tap'; target = 'semantics:Create a server' }
    Step b @{ op = 'enter_text'; target = 'hint:Invite link or server ID'; value = '${INVITE}' }
    Step b @{ op = 'tap'; target = 'text:Join'; index = 0 }
    # Soft: the toast is three seconds of reassurance, not the behaviour under
    # test, and a poll can arrive after it has faded.
    $toast = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:Joining server...'; timeout_ms = 15000 }
    if ($toast.ok) {
        Set-Gate 'G2 b saw the Joining server toast (soft)' 'PASS'
    } else {
        Set-Gate 'G2 b saw the Joining server toast (soft)' 'WARN'
        Add-Note 'the "Joining server..." toast was not caught (it may simply have faded first)'
    }

    # The park itself. Rust stops waiting for an answer at 15s and turns the
    # request into a parked one, so 30s is the budget with room to spare.
    #
    # The tile is an ICON, not a row of text: `pendingJoinTitle()` reaches the
    # screen as the HollowTooltip message and, with ", show actions" appended,
    # as the Semantics label (`pending_join_ui.dart`, `server_strip.dart`).
    # Both forms are tried, then the plain-text ones in case the wording moves
    # into a label; whichever matched is printed, so the run says which.
    $tileTargets = @(
        'tooltip:Join request pending',
        'semantics:Join request pending, show actions',
        'text:Join request pending',
        'contains:Join request pending'
    )
    $tileHit = Wait-ForAnyTarget b $tileTargets 30
    if (-not $tileHit) {
        throw "b never showed a pending-join tile within 30s. Tried: $($tileTargets -join ', ')"
    }
    Say "b shows the pending tile (matched $tileHit)" 'Green'
    Set-Gate 'G3 b shows the PENDING tile with nobody online' 'PASS'

    # ...and it is a PENDING tile, not a server. A parked join that quietly
    # created a real, empty server would look much the same in the strip.
    Step b @{ op = 'dump'; name = 'pending_tile' }
    $bServers = @(Get-DumpServerNames b 'pending_tile')
    if ($bServers -contains $server) {
        throw "b already holds a REAL server named $server while the join is only parked. Servers in the dump: $($bServers -join '; ')"
    }
    $bStrip = @(Get-DumpStripOutline b 'pending_tile')
    $parked = @($bStrip | Where-Object { $_ -like 'pending join*' })
    if ($parked.Count -eq 0) {
        throw "b's strip outline holds no parked join. Outline: $($bStrip -join '; ')"
    }
    $serverId = ($parked[0] -replace '^pending join\s+', '').Trim()
    $bServerList = 'none'
    if ($bServers.Count -gt 0) { $bServerList = ($bServers -join '; ') }
    Say "b holds no real server yet (servers: $bServerList; strip: $($parked -join '; '))" 'Green'
    Set-Gate 'G4 b holds NO real server yet (dump)' 'PASS'

    # ---- 4. b closes too. The request now exists only in the relay's ring. ---
    Say '4/8 closing b - the request now lives only in the relay ring'
    Stop-Peer b

    # ---- 5. the owner comes back ALONE and serves the buffered request ------
    Say '5/8 a returns ALONE - THE RING PATH'
    Restart-Peer a
    Wait-ForConnected a | Out-Null
    # The strip is painted from the local DB, but not in the first frame: an
    # open_server whose tile is not there yet fails as "nothing matches".
    Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }
    Step a @{ op = 'open_server'; name = $server }
    Step a @{ op = 'open_channel'; name = 'general' }
    # b's ROW, by key, not by name: b's profile has never met a, so the row may
    # still read as a truncated id (and every peer id starts with the same eight
    # characters, so a truncated one identifies nobody). Each member tile is
    # keyed `mem-<peerId>`, which names b and only b. The catch-up fires on
    # RoomMembers and the coordinator then serves it, so 45s.
    Step a @{ op = 'wait_for'; target = 'key:mem-${PEER_B}'; timeout_ms = 45000 }
    # And exactly two rows: a ghost or duplicate row would satisfy the line above.
    Step a @{ op = 'wait_for'; target = 'type:_ServerMemberTile'; count = 2; timeout_ms = 15000 }
    Set-Gate 'G5 a returns alone and admits b from the ring (2 rows)' 'PASS'
    $namedB = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:probe-b'; timeout_ms = 20000 }
    if ($namedB.ok) {
        Add-Note 'the new member renders as probe-b, so b profile rode along with the request'
    } else {
        Add-Note 'the new member row is there but not named probe-b yet (profile has not propagated)'
    }
    Step a @{ op = 'dump'; name = 'ring_admitted' }

    # ---- 6. and a leaves again, before b ever sees it -----------------------
    Say '6/8 closing a again - b has still never been online with it'
    Stop-Peer a

    # ---- 7. b comes back ALONE to a real server ----------------------------
    Say '7/8 b returns ALONE - THE RETURN LEG'
    Restart-Peer b
    Wait-ForConnected b | Out-Null
    # The tile carries the server NAME only once the snapshot has landed: b joined
    # by id and never knew the name, so this target cannot be satisfied by the
    # pending tile b already had.
    $realHit = Wait-ForAnyTarget b @("server:$server", "text:$server") 45
    if (-not $realHit) {
        throw "b never got the real server tile for $server within 45s (the buffered admission did not come back)"
    }
    Say "b shows the real server tile (matched $realHit)" 'Green'
    # Soft, and worth knowing either way: admitted-but-not-synced is a state the
    # design gives its own flair (AwaitingSetupBadge, a Semantics label rather
    # than any text), and it may legitimately be gone by the time we look.
    $badge = Invoke-SoftStep b @{ op = 'wait_for'; target = 'semantics:Waiting for a member to finish setup'; timeout_ms = 3000 }
    if ($badge.ok) {
        Add-Note 'b is showing the awaiting-setup flair (admitted, not synced yet)'
    } else {
        Add-Note 'no awaiting-setup flair on b (already synced by the time we looked, or never set)'
    }
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 45000 }
    Step b @{ op = 'dump'; name = 'return_leg' }
    $bServersNow = @(Get-DumpServerNames b 'return_leg')
    if ($bServersNow -notcontains $server) {
        throw "b's strip shows the tile but its server list does not hold $server. Servers: $($bServersNow -join '; ')"
    }
    $bChannels = @(Get-DumpChannelNames b 'return_leg')
    if ($bChannels.Count -eq 0) {
        throw "b holds the server but its channel list is EMPTY - the snapshot half of the admission never landed"
    }
    $joinedId = Get-DumpServerId b 'return_leg' $server
    if ($joinedId -and $serverId -and $joinedId -ne $serverId) {
        Add-Note "the parked id ($serverId) and the joined id ($joinedId) differ - using the joined one"
    }
    if ($joinedId) { $serverId = $joinedId }
    Say "b's channel list: $($bChannels -join ', ') (server id $serverId)" 'Green'
    Set-Gate 'G6 b returns alone to a REAL server with a channel list' 'PASS'

    # The parked entry has to become the server, not sit next to it. A second
    # tile for the same id is a strip bug and not a delivery one, so it is
    # reported rather than fatal - and it gets one retry, because the swap and
    # the sync do not have to land in the same frame.
    $stripNow = @(Get-DumpStripOutline b 'return_leg')
    $stillParked = @($stripNow | Where-Object { $_ -like 'pending join*' })
    if ($stillParked.Count -gt 0) {
        Step b @{ op = 'wait'; ms = 5000 }
        Step b @{ op = 'dump'; name = 'return_leg_settled' }
        $stripNow = @(Get-DumpStripOutline b 'return_leg_settled')
        $stillParked = @($stripNow | Where-Object { $_ -like 'pending join*' })
    }
    if ($stillParked.Count -gt 0) {
        Set-Gate 'G6 b returns alone to a REAL server with a channel list' 'WARN'
        Add-Note "b still shows a parked tile beside the real server: $($stillParked -join '; ')"
    }

    # ---- 8. both up at last -------------------------------------------------
    if ($DeleteBeforeMessage) {

        # The tombstone variant: a comes back and deletes the server BEFORE anything
        # can pull b's MLS leaf into existence, and b still has to lose it. See the
        # header for the hole this guards.
        Say '8/8 a returns and DELETES the server before b can form a leaf - THE TWIN'
        Restart-Peer a
        Wait-ForConnected a | Out-Null
        Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }

        # Informational, and read as late as possible: b must still hold NO leaf for
        # this server, or the tombstone had an encrypted path available after all and
        # the run proves less than it looks. a merely coming online can be enough to
        # answer b's bootstrap, which is a race this journey cannot win outright - so
        # it is a WARN and a note, never a failure.
        $leaf = @(Get-PeerLogLines b "Joined MLS group $serverId")
        if ($leaf.Count -eq 0) {
            Set-Gate 'G7d a deleted pj-RUN before b could form an MLS leaf' 'PASS'
            Add-Note "b holds no MLS leaf for $serverId at delete time (no 'Joined MLS group' line in its log)"
        } else {
            Set-Gate 'G7d a deleted pj-RUN before b could form an MLS leaf' 'WARN'
            Add-Note "b ALREADY had a leaf before the delete, so the encrypted path was also available: $($leaf[-1])"
        }

        Remove-Server a $server
        $serverDeleted = $true
        Say 'a deleted it; b now has to lose it with no leaf of its own' 'Yellow'

        # THE GATE. b never sent a message, so it never had a reason to form a leaf:
        # the only way this tombstone reaches it is the plaintext twin.
        Step b @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 30000 }
        Step b @{ op = 'dump'; name = 'tombstone_no_leaf' }
        $bAfter = @(Get-DumpServerNames b 'tombstone_no_leaf')
        if ($bAfter -contains $server) {
            throw "b's tile went but its server list still holds $server. Servers: $($bAfter -join '; ')"
        }
        $stripAfter = @(Get-DumpStripOutline b 'tombstone_no_leaf')
        $ghost = @($stripAfter | Where-Object { ($_ -like "*$serverId*") -or ($_ -like "*$server*") })
        if ($ghost.Count -gt 0) {
            throw "b's strip still carries a row for the deleted server: $($ghost -join '; ')"
        }
        # The widgets can also lose a tile because the provider never loaded. b's own
        # log saying it APPLIED the tombstone is what separates the two.
        $applied = @(Get-PeerLogLines b "Server deleted: $serverId")
        if ($applied.Count -eq 0) {
            throw "b dropped the server from its UI but its log has no 'Server deleted: $serverId' line, so nothing proves the tombstone was applied rather than the state simply not loading"
        }
        Say "b applied the tombstone: $($applied[-1])" 'Green'
        Set-Gate 'G8d b lost the server WITHOUT a leaf (plaintext twin)' 'PASS'

    } else {

        Say '8/8 a returns, both are up, and traffic has to flow BOTH ways'
        Restart-Peer a
        Wait-ForConnected a | Out-Null
        Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }
        Step a @{ op = 'open_server'; name = $server }
        Step a @{ op = 'open_channel'; name = 'general' }
        Step b @{ op = 'open_channel'; name = 'general' }

        # TAP the composer before typing: enter_text has reported success into a
        # composer that stayed empty, twice, both times right after a reconnect
        # rebuilt the chat pane. And every send waits for its OWN optimistic row
        # before the other peer waits on it, or a send that never happened is
        # indistinguishable from a delivery failure.
        Step a @{ op = 'tap'; target = 'hint:Message #general' }
        Step a @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'from a ${RUN}' }
        Step a @{ op = 'key'; value = 'enter' }
        Step a @{ op = 'wait_for'; target = 'text:from a ${RUN}'; timeout_ms = 20000 }
        # b's MLS leaf only forms once the two are co-present, so the first message
        # across is the slow one.
        Step b @{ op = 'wait_for'; target = 'text:from a ${RUN}'; timeout_ms = 30000 }

        Step b @{ op = 'tap'; target = 'hint:Message #general' }
        Step b @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'from b ${RUN}' }
        Step b @{ op = 'key'; value = 'enter' }
        Step b @{ op = 'wait_for'; target = 'text:from b ${RUN}'; timeout_ms = 20000 }
        Step a @{ op = 'wait_for'; target = 'text:from b ${RUN}'; timeout_ms = 30000 }
        Set-Gate 'G7 a message each way once both are finally up' 'PASS'

        Step a @{ op = 'dump'; name = 'pending_join_converged' }
        Step b @{ op = 'dump'; name = 'pending_join_converged' }
    }
    Say 'the journey converged' 'Green'
} catch {
    $failure = $_
    $where = Set-FirstUnreachedGateFailed
    Say "FAILED at [$where]: $($_.Exception.Message)" 'Red'
}

# --------------------------------------------------------------------------
# Cleanup. Runs whatever happened: the fleet talks only to servers it creates
# AND deletes, because these are real identities on the real relay.
# --------------------------------------------------------------------------
if (-not $serverCreated) {
    Say 'cleanup: nothing to delete (the server was never created)' 'Yellow'
} elseif ($serverDeleted) {
    # The tombstone journey already deleted it, as the journey itself. Nothing
    # is left on the relay, so the cleanup gate is satisfied by that.
    Say 'cleanup: the server was already deleted by the journey' 'Green'
    Set-Gate $script:CleanupGate 'PASS'
} else {
    Say 'cleanup: deleting the server as its owner'
    try {
        # a is the owner, so a has to be up for this even if the failure left it down.
        if (-not (Get-PeerProcess 'a')) { Restart-Peer a }
        Wait-ForConnected a | Out-Null
        Remove-Server a $server
        $serverDeleted = $true
        # b only has to lose it if b is up; the tombstone reaches it on its next
        # boot either way, and this run is not the place to prove that.
        if (Get-PeerProcess 'b') {
            Invoke-SoftStep b @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 120000 } | Out-Null
        }
        Set-Gate $script:CleanupGate 'PASS'
        Say 'cleanup done' 'Green'
    } catch {
        Set-Gate $script:CleanupGate 'FAIL'
        Say "cleanup FAILED (the server may still exist as $server): $($_.Exception.Message)" 'Red'
    }
}

# --------------------------------------------------------------------------
# The report
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '===== pending server join =====' -ForegroundColor Cyan
foreach ($key in @($script:Gates.Keys)) {
    $status = $script:Gates[$key]
    $colour = 'DarkGray'
    if ($status -eq 'PASS') { $colour = 'Green' }
    elseif ($status -eq 'FAIL') { $colour = 'Red' }
    elseif ($status -eq 'WARN') { $colour = 'Yellow' }
    Write-Host ("  {0,-4} {1}" -f $status, $key) -ForegroundColor $colour
}
Write-Host ''
$journeyKind = 'messages (standard)'
if ($DeleteBeforeMessage) { $journeyKind = 'delete-before-message (tombstone twin)' }
Write-Host ("  journey : {0}" -f $journeyKind) -ForegroundColor Gray
Write-Host ("  run tag : {0}   server: {1} [{2}]" -f $script:FleetVars.RUN, $server, $serverId) -ForegroundColor Gray
Write-Host ("  peer a  : {0}" -f $script:FleetVars['PEER_A']) -ForegroundColor Gray
Write-Host ("  peer b  : {0}" -f $script:FleetVars['PEER_B']) -ForegroundColor Gray
foreach ($note in $script:Notes) { Write-Host ("  note    : {0}" -f $note) -ForegroundColor DarkCyan }

if ($failure) {
    Write-Host ''
    Say 'the fleet is left UP for diagnosis. Logs:' 'Yellow'
    foreach ($peer in $journeyPeers) {
        Write-Host ("    $peer  " + (Join-Path $script:FleetOutRoot "$peer\stdout.log")) -ForegroundColor DarkGray
        Write-Host ("       " + (Join-Path $script:FleetOutRoot "$peer\errors.log")) -ForegroundColor DarkGray
        Write-Host ("       " + (Join-Path $script:FleetStageRoot "$peer\hollow_debug.log")) -ForegroundColor DarkGray
    }
    throw $failure
}

if ($KeepUp) {
    Say 'PASS - fleet left up (-KeepUp)' 'Green'
} else {
    Invoke-FleetScript @('-Stop')
    Say 'PASS' 'Green'
}
