# Remove and re-add, both instances ONLINE throughout, across two REAL Hollows.
#
#   powershell -File scripts\fleet_friend_readd.ps1                   # fresh keys, builds first
#   powershell -File scripts\fleet_friend_readd.ps1 -SkipBuild        # you just built
#   powershell -File scripts\fleet_friend_readd.ps1 -KeepIdentities   # drive the live fleet
#   powershell -File scripts\fleet_friend_readd.ps1 -KeepUp           # leave the instances up
#   powershell -File scripts\fleet_friend_readd.ps1 -LogOut C:\some\where.txt
#
# ## What it proves
#
# A re-add needs FRESH consent. a and b become friends, a removes b, a re-adds
# b, and the only thing that may turn that request into a friendship is b
# pressing Accept a second time. The bug this guards flipped a's fresh outgoing
# request to "accepted" off a COPY of the accept that answered the FIRST
# request: the relay parks a direct frame addressed into a room the target has
# left and replays it on the target's next join of THAT room, and the requester's
# next join of `inbox:{b}` is the re-add. So a re-friended b without b ever
# consenting, while b sat on a pending incoming request. CI caught it on the
# 0.11 release commit (`readd_while_online_requires_fresh_consent`, 2026-09-06).
#
# The fix has three parts and this journey walks the seam all three live in:
# the accept carries `requested_at` (the stamp of the request it answers) and a
# receiver drops a stamped accept older than its current row; every accept goes
# into the deterministic DM room rather than the first room the device happens
# to be listed in; and the redelivery queue only re-sends for a master whose row
# is still accepted.
#
# ## What it proves that the Rust harness cannot
#
# `readd_while_online_requires_fresh_consent` and
# `stale_friend_accept_replayed_after_readd_is_dropped` (node/test_harness.rs)
# prove the STORE converges, in one process against a mock relay. Three things
# live outside that process:
#
#   * the real relay, which is what parks and replays a direct frame in the
#     first place. The mock one has to be told to.
#   * the real widgets. "b must see a NEW request" is an Accept button on the
#     INCOMING tab, and "a must not be a friend yet" is the Friends tab still
#     reading "No friends yet" while the outgoing row sits there. A store row
#     that never reaches either surface is still the bug the user reports.
#   * the DM room after a re-add. The accept now routes into `dm_room_code`,
#     and the cheapest proof that the room survived the round trip is a message
#     crossing it (gate 5).
#
# ## The gates
#
#   G1 a requests, b accepts on the Incoming tab, BOTH list the other accepted.
#   G2 a removes b. Neither side lists the other any more (both dumps empty).
#   G3 a re-adds. b sees a NEW incoming request and does NOT list a as a friend;
#      a holds a PENDING OUTGOING row and does NOT list b as a friend. This is
#      the bug's surface, asserted after a settle window so a late stale accept
#      has had its chance to land.
#   G4 b accepts for real. Both list each other accepted again.
#   G5 the DM room survived the re-add: a message each way.
#   G6 the friends log agrees. `sent FriendAccept` / `(re)sending FriendAccept`
#      are the accept lines; `Ignoring stale FriendAccept` in the HAPPY path
#      means a legitimate accept was refused, so it fails this gate and prints
#      the lines around it.
#
# ## Why fresh identities by default
#
# The relay replays a buffered friend request to `inbox:{master}` for three
# days, so a reused identity hands this journey its own past: an earlier run's
# request satisfies "b sees a NEW incoming request" before a has sent anything,
# and an earlier run's parked accept is indistinguishable from the one under
# test. `-KeepIdentities` drives whatever fleet is live, which is what you want
# when you are iterating on the journey rather than on the behaviour.
#
# ## Why a script and not a scenario JSON
#
# The gates are assertions on the provider DUMP (a row can leave a tab while
# the provider behind it still holds the friend, and which of the two is
# telling the truth IS this journey), plus a read of both instances' logs. A
# scenario file has no op for either. Same shape as fleet_friend_decline.ps1
# and fleet_file_card_states.ps1, whose Step / gates / evidence this copies.
#
# Windows PowerShell 5.1 is what is installed here: no pwsh-only syntax, and
# `pwsh` is not a thing on this machine - run it with `powershell -File`.

param(
    # Drive the identities that are already live instead of minting new ones.
    [switch]$KeepIdentities,
    # Leave the instances running after a PASS. A FAILED run always leaves them
    # up, whatever this says.
    [switch]$KeepUp,
    # Skip the build+stage step.
    [switch]$SkipBuild,
    # Where the [HOLLOW-FRIENDS] excerpt goes. Defaults into build\fleet_out.
    [string]$LogOut = '',
    # How long G3 waits before deciding no stale accept is coming. The bug lands
    # a beat after the re-add request, so a short window would pass for the
    # wrong reason.
    [int]$SettleSeconds = 25,
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag runs a journey nobody asked for and
# reports a clean pass for it.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepIdentities, -KeepUp, -SkipBuild, -LogOut, -SettleSeconds and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in every message: the relay holds undelivered traffic for three
# days, so a fixed string can be matched by an EARLIER run and pass before the
# send it was waiting for.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runTag = $script:FleetVars.RUN
$journeyPeers = @('a', 'b')
if (-not $LogOut) {
    $LogOut = Join-Path $script:FleetOutRoot "friend_readd_log_$runTag.txt"
}

function Say($message, $colour = 'Cyan') { Write-Host "[friend-readd] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{
    'G1 a and b are friends, and both sides say so'            = 'SKIP'
    'G2 the removal reaches both sides'                        = 'SKIP'
    'G3 the re-add needs consent: a new request, no friendship' = 'SKIP'
    'G4 b accepts for real and both list each other again'     = 'SKIP'
    'G5 the DM room survived the re-add'                       = 'SKIP'
    'G6 no legitimate accept was refused as stale'             = 'SKIP'
}
$script:Notes = New-Object System.Collections.ArrayList

function Set-Gate($name, $status) {
    if (-not $script:Gates.Contains($name)) { throw "unknown gate '$name'" }
    $script:Gates[$name] = $status
}

function Add-Note($text) {
    [void]$script:Notes.Add($text)
    Say "note: $text" 'DarkCyan'
}

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

function Invoke-SoftStep($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2} (soft)" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    return $answer
}

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
        if ((Get-Date) -ge $deadline) { return $null }
    }
}

# "This peer is up and on the network", without depending on which screen it
# booted into. `text:Online` is deliberately NOT in the list: the member panel
# prints that word as a section divider, so it would pass for an offline peer.
function Wait-ForConnected($peer, $timeoutSeconds = 120) {
    $hit = Wait-ForAnyTarget $peer @('tooltip:Online', 'text:Connected') $timeoutSeconds
    if (-not $hit) {
        throw "peer $peer never reported a settled connection within ${timeoutSeconds}s (no user-bar 'Online' tooltip, no Home 'Connected')"
    }
    return $hit
}

# --------------------------------------------------------------------------
# The Friends manager
# --------------------------------------------------------------------------

# The manager is a Material dialog with a barrier, so a second tap on the
# sidebar's Add-friend control while it is up lands on the barrier and fails.
# Every phase therefore opens it and closes it explicitly, and both helpers are
# idempotent so a failed phase cannot leave the next one guessing.
function Test-FriendsManagerOpen($peer) {
    $answer = Send-FleetStep $peer ([pscustomobject]@{
        op = 'wait_for'; target = 'type:_FriendsManager'; timeout_ms = 800
    }) 60
    return [bool]$answer.ok
}

function Open-Friends($peer) {
    if (Test-FriendsManagerOpen $peer) { return }
    Step $peer @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_FriendsManager'; timeout_ms = 15000 }
}

# Never a bare Escape: after Send Request and the waits that follow, focus has
# left the dialog and the key reaches nothing, and the barrier then covers the
# controls the next phase taps. And never a bare semantics:Close, which matches
# the window title bar first and ends the process.
function Close-Friends($peer) {
    if (-not (Test-FriendsManagerOpen $peer)) { return }
    Step $peer @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
}

# Scoped to the tab WIDGET. Bare `text:Friends` also matches the dialog's own
# title and the sidebar heading behind it, and index 0 is one of those, so the
# tap lands on something the dialog is covering and fails as "on screen but a
# click at its centre does not reach it".
function Show-FriendsTab($peer, $tab) {
    Step $peer @{ op = 'tap'; target = "type:_TabButton>text:$tab"; index = 0 }
}

# --------------------------------------------------------------------------
# The provider dump, which is the authority the tabs are only a view of
# --------------------------------------------------------------------------

# providers.friends = [{peerId, status, direction?}], MASTER-keyed. A row can
# vanish from a tab while the provider still holds the friend, and this journey
# is precisely about which of the two is telling the truth.
function Get-DumpFriendRows($peer, $name) {
    $path = Join-Path $script:FleetOutRoot "$peer\map-$name.json"
    if (-not (Test-Path $path)) { throw "no dump for $peer at $path" }
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = $json.providers.friends
    if (-not $rows) { return @() }
    return @($rows)
}

function Format-FriendRows($rows) {
    # A function that returns an empty array hands back $null, and @($null) is a
    # one-element array, so an empty list would print as a blank row rather than
    # as nothing.
    $all = @(@($rows) | Where-Object { $_ })
    if ($all.Count -eq 0) { return '(none)' }
    $parts = @($all | ForEach-Object {
        $direction = ''
        if ($_.direction) { $direction = " ($($_.direction))" }
        "$($_.peerId) $($_.status)$direction"
    })
    return ($parts -join '; ')
}

function Get-RowFor($rows, $master) {
    return @(@($rows) | Where-Object { $_.peerId -eq $master }) | Select-Object -First 1
}

# Reads a fresh dump and returns its rows, so a gate never asserts on a file an
# earlier phase wrote.
function Read-Friends($peer, $name) {
    Step $peer @{ op = 'dump'; name = $name } | Out-Null
    $rows = Get-DumpFriendRows $peer $name
    Say "$peer friends: $(Format-FriendRows $rows)" 'DarkCyan'
    return $rows
}

# --------------------------------------------------------------------------
# The logs, from the moment the journey starts
# --------------------------------------------------------------------------

# hollow_debug.log lives NEXT TO THE EXE on Windows and is appended across runs,
# so every read is from a line mark taken once both instances are up.
$script:LogMark = @{}

function Get-PeerLogPath($peer) {
    return (Join-Path $script:FleetStageRoot "$peer\hollow_debug.log")
}

function Get-PeerLogLines($peer) {
    $path = Get-PeerLogPath $peer
    if (-not (Test-Path $path)) { return @() }
    try {
        # -Encoding UTF8, or every arrow and dash the Rust side writes comes
        # back as mojibake in the excerpt this run leaves behind.
        return @(Get-Content $path -Encoding UTF8 -ErrorAction Stop)
    } catch {
        Add-Note "could not read $peer's hollow_debug.log ($($_.Exception.Message))"
        return @()
    }
}

function Set-LogMark($peer) {
    $script:LogMark[$peer] = @(Get-PeerLogLines $peer).Count
    Say "$peer log mark at line $($script:LogMark[$peer])" 'DarkGray'
}

# `.Contains`, never `-like "*$pattern*"`: every pattern here is bracketed
# (`[HOLLOW-FRIENDS]`) and -like reads brackets as a character class, so the
# filter would match any line holding one of those letters, which is all of
# them.
function Get-RunLogLines($peer, $pattern) {
    $mark = $script:LogMark[$peer]
    if (-not $mark) { $mark = 0 }
    $lines = @(Get-PeerLogLines $peer)
    if ($lines.Count -le $mark) { return @() }
    $window = @($lines[$mark..($lines.Count - 1)])
    if (-not $pattern) { return $window }
    return @($window | Where-Object { "$_".Contains($pattern) })
}

# The lines on either side of a hit, so a refused accept is readable rather
# than merely counted.
function Get-RunLogContext($peer, $pattern, $before = 4, $after = 4) {
    $mark = $script:LogMark[$peer]
    if (-not $mark) { $mark = 0 }
    $lines = @(Get-PeerLogLines $peer)
    if ($lines.Count -le $mark) { return @() }
    $window = @($lines[$mark..($lines.Count - 1)])
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $window.Count; $i++) {
        if (-not "$($window[$i])".Contains($pattern)) { continue }
        $from = [Math]::Max(0, $i - $before)
        $to = [Math]::Min($window.Count - 1, $i + $after)
        [void]$out.Add("--- around line $($mark + $i + 1) ---")
        for ($j = $from; $j -le $to; $j++) { [void]$out.Add($window[$j]) }
    }
    return @($out)
}

function Write-Evidence($label) {
    Say "evidence for $label" 'Yellow'
    foreach ($peer in $journeyPeers) {
        foreach ($pattern in @(
            '[HOLLOW-FRIENDS]',
            'FriendAccept',
            'FriendRemove',
            'friend request',
            'Friend accepted')) {
            $hits = @(Get-RunLogLines $peer $pattern)
            if ($hits.Count -eq 0) { continue }
            Write-Host "  --- $peer :: $pattern ($($hits.Count)) ---" -ForegroundColor DarkYellow
            foreach ($line in ($hits | Select-Object -Last 15)) { Write-Host "     $line" -ForegroundColor DarkGray }
        }
    }
}

# --------------------------------------------------------------------------
# DMs
# --------------------------------------------------------------------------

# Opens the DM with a friend from wherever the shell happens to be. The chip in
# the rail carries the friend's display name as a HollowTooltip, which is also
# the assertion that the profile crossed.
function Open-Dm($peer, $friendName) {
    Step $peer @{ op = 'wait_for'; target = "tooltip:$friendName"; timeout_ms = 60000 }
    Step $peer @{ op = 'tap'; target = "tooltip:$friendName" }
    Step $peer @{ op = 'wait'; ms = 1500 }
    Step $peer @{ op = 'wait_for'; target = 'hint:Type a message...'; timeout_ms = 30000 }
}

# The composer is tapped first: enter_text on an unfocused field reports success
# into nothing. And every send waits for its OWN optimistic row, so a send that
# never happened cannot be mistaken for a delivery failure on the other side.
#
# Retried, because that wait has caught a real swallow: run 2 of 2026-09-06 typed
# "readd dm from b 183312" into a composer that ended up holding "dw" and then
# lost focus, so Enter reached nothing (build\fleet_out\b\live-43-enter_text.png).
# The same fragment shape as the "nh" the peer-id field once held. A re-tap and a
# retype land the whole string, which is also what a user does, so the gate stays
# about the DM room rather than about the composer.
function Send-Dm($peer, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = 'hint:Type a message...' }
        Step $peer @{ op = 'enter_text'; target = 'hint:Type a message...'; value = $body }
        Step $peer @{ op = 'key'; value = 'enter' }
        $landed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }
        if ($landed.ok) { return }
        Add-Note "$peer's composer swallowed the send on attempt $attempt (enter_text reported success, no row appeared)"
        Invoke-SoftStep $peer @{ op = 'shot'; name = "readd-$runTag-$peer-swallowed-$attempt" } | Out-Null
    }
    throw "[$peer] the composer never produced a row for '$body' after 3 attempts"
}

# --------------------------------------------------------------------------
# Boot
# --------------------------------------------------------------------------

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
Say "run tag $runTag"

$failure = $null

try {
    Wait-ForConnected a | Out-Null
    Wait-ForConnected b | Out-Null
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }
    $masterA = $script:FleetVars['PEER_A']
    $masterB = $script:FleetVars['PEER_B']
    if (-not $masterA -or -not $masterB) { throw 'could not read both peer ids' }
    foreach ($peer in $journeyPeers) { Set-LogMark $peer }

    # ---- G1: a requests, b accepts, both agree ------------------------------
    Say '1/6 a sends the request, b accepts it on the Incoming tab'
    Open-Friends a
    Show-FriendsTab a 'Add Friend'
    # Assert the id really IS in the field before sending: enter_text has
    # reported success into this field while it held only a fragment, which the
    # app then resolved as a nickname and never sent, and that failure is
    # indistinguishable downstream from the request being lost.
    Step a @{ op = 'enter_text'; target = 'hint:Peer ID or nickname...'; value = '${PEER_B}' }
    Step a @{ op = 'wait_for'; target = 'text:${PEER_B}'; timeout_ms = 15000 }
    Step a @{ op = 'tap'; target = 'text:Send Request'; index = 0 }

    # The Accept button only exists on the INCOMING tab. Waiting for it from the
    # Friends tab is a 60-second timeout that reads exactly like a delivery
    # failure and is not one.
    Open-Friends b
    Show-FriendsTab b 'Incoming'
    Step b @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 90000 }
    Step b @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }

    Step a @{ op = 'wait_for'; target = 'text:probe-b'; timeout_ms = 90000 }
    Step b @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 90000 }
    Step a @{ op = 'shot'; name = "readd-$runTag-a-g1" }
    Step b @{ op = 'shot'; name = "readd-$runTag-b-g1" }

    $aRows = Read-Friends a 'readd_g1_a'
    $bRows = Read-Friends b 'readd_g1_b'
    $aOnB = Get-RowFor $aRows $masterB
    $bOnA = Get-RowFor $bRows $masterA
    if (-not $aOnB -or $aOnB.status -ne 'accepted') {
        Set-Gate 'G1 a and b are friends, and both sides say so' 'FAIL'
        Add-Note "G1: a's row for b is $(Format-FriendRows $aRows)"
        Write-Evidence 'G1'
        throw 'G1 failed: a does not list b as an accepted friend'
    }
    if (-not $bOnA -or $bOnA.status -ne 'accepted') {
        Set-Gate 'G1 a and b are friends, and both sides say so' 'FAIL'
        Add-Note "G1: b's row for a is $(Format-FriendRows $bRows)"
        Write-Evidence 'G1'
        throw 'G1 failed: b does not list a as an accepted friend'
    }
    Set-Gate 'G1 a and b are friends, and both sides say so' 'PASS'
    Say 'PASS G1: both sides hold the other as accepted' 'Green'

    # ---- G2: a removes b, and it reaches b ----------------------------------
    Say '2/6 a removes b while both are online'
    Close-Friends b
    Open-Friends a
    Show-FriendsTab a 'Friends'
    Step a @{ op = 'wait_for'; target = 'semantics:Remove friend'; timeout_ms = 15000 }
    Step a @{ op = 'tap'; target = 'semantics:Remove friend'; index = 0 }
    # The sidebar's friends bar prints this too, so it is the same signal
    # whether or not the manager happens to be the surface showing it.
    Step a @{ op = 'wait_for'; target = 'text:No friends yet'; timeout_ms = 30000 }
    Step b @{ op = 'wait_for'; target = 'text:No friends yet'; timeout_ms = 90000 }
    Step a @{ op = 'shot'; name = "readd-$runTag-a-g2" }
    Step b @{ op = 'shot'; name = "readd-$runTag-b-g2" }

    $aRows = Read-Friends a 'readd_g2_a'
    $bRows = Read-Friends b 'readd_g2_b'
    # Not "the other's row is gone" but "there is nothing here at all": a
    # removal that left a tombstone row behind would still leak into every
    # friends-list consumer, and the empty-state widget cannot see it.
    if (@($aRows).Count -ne 0) {
        Set-Gate 'G2 the removal reaches both sides' 'FAIL'
        Add-Note "G2: a's friends list should be empty, it holds $(Format-FriendRows $aRows)"
        Write-Evidence 'G2'
        throw 'G2 failed: a still holds a friend row after removing b'
    }
    if (@($bRows).Count -ne 0) {
        Set-Gate 'G2 the removal reaches both sides' 'FAIL'
        Add-Note "G2: b's friends list should be empty, it holds $(Format-FriendRows $bRows)"
        Write-Evidence 'G2'
        throw 'G2 failed: the removal did not reach b'
    }
    Set-Gate 'G2 the removal reaches both sides' 'PASS'
    Say 'PASS G2: neither side holds a row for the other' 'Green'

    # ---- G3: the re-add needs consent ---------------------------------------
    Say '3/6 a re-adds b: b must see a NEW request, and nobody may be a friend yet'
    Show-FriendsTab a 'Add Friend'
    Step a @{ op = 'enter_text'; target = 'hint:Peer ID or nickname...'; value = '${PEER_B}' }
    Step a @{ op = 'wait_for'; target = 'text:${PEER_B}'; timeout_ms = 15000 }
    Step a @{ op = 'tap'; target = 'text:Send Request'; index = 0 }

    Open-Friends b
    Show-FriendsTab b 'Incoming'
    Step b @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 120000 }
    Say 'b sees a new incoming request'

    # The bug lands a beat AFTER the request, when the parked copy of the first
    # accept is replayed on the requester's room join. Asserting immediately
    # would pass for the wrong reason.
    Say "settling ${SettleSeconds}s so a late stale accept has its chance"
    Start-Sleep -Seconds $SettleSeconds

    Show-FriendsTab a 'Friends'
    $aFriendsTabEmpty = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:No friends yet'; timeout_ms = 10000 }
    Show-FriendsTab a 'Outgoing'
    # `Cancel friend request` is the outgoing ROW's own action, so it is on
    # screen only while a still believes the request is pending.
    $aOutgoing = Invoke-SoftStep a @{ op = 'wait_for'; target = 'semantics:Cancel friend request'; timeout_ms = 20000 }
    Show-FriendsTab b 'Friends'
    $bFriendsTabEmpty = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:No friends yet'; timeout_ms = 10000 }
    Step a @{ op = 'shot'; name = "readd-$runTag-a-g3" }
    Step b @{ op = 'shot'; name = "readd-$runTag-b-g3" }

    $aRows = Read-Friends a 'readd_g3_a'
    $bRows = Read-Friends b 'readd_g3_b'
    $aOnB = Get-RowFor $aRows $masterB
    $bOnA = Get-RowFor $bRows $masterA
    $problems = New-Object System.Collections.ArrayList
    if (-not $aOnB) {
        [void]$problems.Add("a holds no row for b at all, so the re-add never took: $(Format-FriendRows $aRows)")
    } elseif ($aOnB.status -eq 'accepted') {
        [void]$problems.Add("a lists b as ACCEPTED off a stale accept, b never consented: $(Format-FriendRows $aRows)")
    } elseif ($aOnB.status -ne 'pending' -or $aOnB.direction -ne 'outgoing') {
        [void]$problems.Add("a's row for b should be pending outgoing, it is $(Format-FriendRows $aRows)")
    }
    if (-not $bOnA) {
        [void]$problems.Add("b holds no row for a, so the re-add request never arrived: $(Format-FriendRows $bRows)")
    } elseif ($bOnA.status -eq 'accepted') {
        [void]$problems.Add("b auto-accepted a without consent: $(Format-FriendRows $bRows)")
    } elseif ($bOnA.status -ne 'pending' -or $bOnA.direction -ne 'incoming') {
        [void]$problems.Add("b's row for a should be pending incoming, it is $(Format-FriendRows $bRows)")
    }
    if (-not $aOutgoing.ok) { [void]$problems.Add("a's Outgoing tab never showed a cancellable request") }
    if (-not $aFriendsTabEmpty.ok) { [void]$problems.Add("a's Friends tab does not read 'No friends yet'") }
    if (-not $bFriendsTabEmpty.ok) { [void]$problems.Add("b's Friends tab does not read 'No friends yet'") }
    if ($problems.Count -gt 0) {
        Set-Gate 'G3 the re-add needs consent: a new request, no friendship' 'FAIL'
        foreach ($problem in $problems) { Add-Note "G3: $problem" }
        Invoke-SoftStep a @{ op = 'look'; max = 60 } | Out-Null
        Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
        Write-Evidence 'G3'
        throw 'G3 failed: the re-add did not require fresh consent'
    }
    Set-Gate 'G3 the re-add needs consent: a new request, no friendship' 'PASS'
    Say 'PASS G3: a pending request on both sides and no friendship anywhere' 'Green'

    # ---- G4: b accepts for real ---------------------------------------------
    Say '4/6 b accepts the new request'
    Show-FriendsTab b 'Incoming'
    Step b @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 20000 }
    Step b @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }
    Step a @{ op = 'wait_for'; target = 'text:probe-b'; timeout_ms = 90000 }
    Step b @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 90000 }
    Step a @{ op = 'shot'; name = "readd-$runTag-a-g4" }
    Step b @{ op = 'shot'; name = "readd-$runTag-b-g4" }

    $aRows = Read-Friends a 'readd_g4_a'
    $bRows = Read-Friends b 'readd_g4_b'
    $aOnB = Get-RowFor $aRows $masterB
    $bOnA = Get-RowFor $bRows $masterA
    if (-not $aOnB -or $aOnB.status -ne 'accepted' -or -not $bOnA -or $bOnA.status -ne 'accepted') {
        Set-Gate 'G4 b accepts for real and both list each other again' 'FAIL'
        Add-Note "G4: a=$(Format-FriendRows $aRows) b=$(Format-FriendRows $bRows)"
        Write-Evidence 'G4'
        throw 'G4 failed: the genuine accept did not converge on both sides'
    }
    Set-Gate 'G4 b accepts for real and both list each other again' 'PASS'
    Say 'PASS G4: both sides are friends again, this time with consent' 'Green'

    # ---- G5: the DM room survived -------------------------------------------
    # The accept now routes into `dm_room_code` rather than the first room the
    # device is listed in, so the cheapest proof the room is intact after a
    # remove and re-add is a message crossing it in both directions.
    Say '5/6 a message each way, which is the DM room after the re-add'
    Close-Friends a
    Close-Friends b
    Open-Dm a 'probe-b'
    Send-Dm a "readd dm from a $runTag"
    Step b @{ op = 'wait_for'; target = "text:readd dm from a $runTag"; timeout_ms = 90000 }
    Open-Dm b 'probe-a'
    Send-Dm b "readd dm from b $runTag"
    Step a @{ op = 'wait_for'; target = "text:readd dm from b $runTag"; timeout_ms = 90000 }
    # One row per message: the optimistic write and the one that arrives have to
    # reconcile, and a re-add is exactly where a second conversation key could
    # split them.
    Step a @{ op = 'expect_count'; target = "text:readd dm from a $runTag"; value = 1 }
    Step b @{ op = 'expect_count'; target = "text:readd dm from b $runTag"; value = 1 }
    Step a @{ op = 'shot'; name = "readd-$runTag-a-g5" }
    Step b @{ op = 'shot'; name = "readd-$runTag-b-g5" }
    Set-Gate 'G5 the DM room survived the re-add' 'PASS'
    Say 'PASS G5: a message crossed each way after the re-add' 'Green'
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
    $unreached = Set-FirstUnreachedGateFailed
    if ($unreached) { Say "first gate without a verdict: $unreached" 'Red' }
}

# --------------------------------------------------------------------------
# G6: what the two instances wrote about friends while this ran
# --------------------------------------------------------------------------
$logReport = New-Object System.Collections.ArrayList
[void]$logReport.Add("[HOLLOW-FRIENDS] for run $runTag, written $(Get-Date -Format o)")
[void]$logReport.Add("a = $($script:FleetVars['PEER_A'])")
[void]$logReport.Add("b = $($script:FleetVars['PEER_B'])")
$staleTotal = 0
foreach ($peer in $journeyPeers) {
    [void]$logReport.Add('')
    [void]$logReport.Add("=== $peer :: $(Get-PeerLogPath $peer) ===")
    $lines = @(Get-RunLogLines $peer '[HOLLOW-FRIENDS]')
    if ($lines.Count -eq 0) {
        [void]$logReport.Add('(no [HOLLOW-FRIENDS] lines in this run window)')
    }
    foreach ($line in $lines) { [void]$logReport.Add($line) }
    $stale = @(Get-RunLogLines $peer 'Ignoring stale FriendAccept')
    $staleTotal += $stale.Count
    if ($stale.Count -gt 0) {
        [void]$logReport.Add('')
        [void]$logReport.Add("!!! $peer refused $($stale.Count) accept(s) as stale, with context:")
        foreach ($line in (Get-RunLogContext $peer 'Ignoring stale FriendAccept')) {
            [void]$logReport.Add($line)
        }
    }
}
$logDir = Split-Path -Parent $LogOut
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
[System.IO.File]::WriteAllLines($LogOut, [string[]]$logReport)
Say "friends log excerpt -> $LogOut"

# An accept refused as stale in the HAPPY path means a legitimate one was
# thrown away, which is the fix overshooting rather than working.
if ($staleTotal -gt 0) {
    Set-Gate 'G6 no legitimate accept was refused as stale' 'FAIL'
    Add-Note "G6: $staleTotal 'Ignoring stale FriendAccept' line(s) in a journey where every accept was legitimate. See $LogOut."
    foreach ($peer in $journeyPeers) {
        foreach ($line in (Get-RunLogContext $peer 'Ignoring stale FriendAccept')) {
            Write-Host "     [$peer] $line" -ForegroundColor Red
        }
    }
} else {
    $sent = 0
    foreach ($peer in $journeyPeers) {
        $sent += @(Get-RunLogLines $peer 'sent FriendAccept').Count
        $sent += @(Get-RunLogLines $peer '(re)sending FriendAccept').Count
    }
    if ($sent -eq 0) {
        # Two accepts happened, so their lines must be there. Nothing means the
        # log was not readable, and a gate that passes on a missing file is a
        # gate that never ran.
        Set-Gate 'G6 no legitimate accept was refused as stale' 'WARN'
        Add-Note 'G6: no accept lines were found at all, so the log was not readable and this gate proves nothing'
    } else {
        Set-Gate 'G6 no legitimate accept was refused as stale' 'PASS'
        Say "PASS G6: $sent accept line(s), none refused as stale" 'Green'
    }
}

# --------------------------------------------------------------------------
# Report. No cleanup step: this journey creates no server, and the fixtures the
# next run restores take the friendship and the DMs with them.
# --------------------------------------------------------------------------
Write-Host ''
Say "gates for run $runTag" 'White'
foreach ($key in $script:Gates.Keys) {
    $status = $script:Gates[$key]
    $colour = 'DarkGray'
    if ($status -eq 'PASS') { $colour = 'Green' }
    if ($status -eq 'FAIL') { $colour = 'Red' }
    if ($status -eq 'WARN') { $colour = 'Yellow' }
    Write-Host ("  {0,-5} {1}" -f $status, $key) -ForegroundColor $colour
}
if ($script:Notes.Count -gt 0) {
    Write-Host ''
    Say 'notes' 'White'
    foreach ($note in $script:Notes) { Write-Host "  - $note" -ForegroundColor Gray }
}
Write-Host ''
Say "a = $($script:FleetVars['PEER_A'])" 'DarkCyan'
Say "b = $($script:FleetVars['PEER_B'])" 'DarkCyan'
Say "artifacts in $script:FleetOutRoot" 'DarkCyan'

if ($failure) { throw $failure }
if ($script:Gates['G6 no legitimate accept was refused as stale'] -eq 'FAIL') {
    throw "G6 failed: a legitimate accept was refused as stale. See $LogOut."
}
if (-not $KeepUp) {
    Say 'stopping the fleet'
    Invoke-FleetScript @('-Stop')
}
Say 'PASS' 'Green'
