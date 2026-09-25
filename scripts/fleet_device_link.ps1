# Multi-device LINKING across two REAL instances: a populated master hands its
# identity, friends, DMs and servers to an empty device, and the two then have
# to behave as siblings.
#
#   powershell -File scripts\fleet_device_link.ps1                 # fresh keys, builds first
#   powershell -File scripts\fleet_device_link.ps1 -SkipBuild      # you just built
#   powershell -File scripts\fleet_device_link.ps1 -KeepUp         # leave the windows open
#   powershell -File scripts\fleet_device_link.ps1 -EdgeGates      # the two refusal gates instead
#
# ## Why a script and not a scenario JSON
#
# The receiver RELAUNCHES ITSELF in the middle of the journey: the snapshot is
# stashed as `pending_link.hollow` and imported on the next launch, before the
# node starts, because the running process still holds the throwaway identity
# and open SQLCipher handles. A scenario file has no op for a peer that leaves
# and comes back, which is the same reason fleet_pending_join.ps1 is a script.
#
# ## The shape, and the one thing that is not obvious
#
# The empty device cannot reach the enter-code screen from Settings. On every
# platform `DeviceLinkMode.enterCode` is opened by ONE caller, the welcome flow
# (`hollow_shell.dart`, action `link_device`), so peer b is launched on an EMPTY
# data directory and walks Welcome > "Link a device". That is also why b never
# gets an onboarded fixture: an identity on disk means no welcome dialog.
#
#   G1  a and c are friends, DM both ways, a's server with #general traffic.
#   G2  a shows a link code (Settings > Devices > Link a device).
#   G3  b, empty, enters it and reaches "Linking this device".
#   G4  a confirms, reaches "Data sent"; b reaches "Device linked".
#   G5  THE RESTART. b's own relaunch (Rust waiter) is allowed to happen, and
#       the stash files are read BEFORE it. A fallback Stop+Restart is there for
#       when the self-relaunch does not come back, and the report says which
#       path ran.
#   G6  b is now a's MASTER: same identity, the server and its history, the
#       friend, the DM history, and two devices in both device lists.
#   G7  LIVE fan-out afterwards, every direction reported on its own.
#   G8  personal emotes converge (issue #76): a uploads one through the
#       picker, b lists it with its image, a removes it and b drops it, then
#       the reverse direction.
#   G9  read state converges (issue #80): what b posts is never unread on a,
#       a reading a DM or a channel clears b's badge, and a sibling that was
#       OFFLINE while a read comes back with nothing to clear.
#
# ## -EdgeGates: the two refusals
#
# E1 the OFFLINE gate. b is launched pointing at an unreachable relay (typed
# into the welcome dialog's own Advanced field, so nothing in the fleet has to
# grow a switch for it) and the enter-code screen has to say so and refuse.
# E2 the 60s WAITING timeout. b enters a real code and a NEVER confirms, so b
# has to give up on its own.
#
# Windows PowerShell 5.1 is what is installed here, so no pwsh-only syntax, and
# `pwsh` is not a thing on this machine: run it with `powershell -File`.

param(
    # Drive the identities that are already live instead of minting new ones.
    # Wrong for a first run: the relay replays buffered traffic for three days,
    # so a reused identity can be served an EARLIER run's messages.
    [switch]$KeepIdentities,
    # Leave the instances running after a PASS. A FAILED run always leaves them
    # up, whatever this says.
    [switch]$KeepUp,
    # Skip the build+stage step. Pass it when you have just run
    # `powershell -File scripts\fleet.ps1 -Build -Peers a,b,c` yourself.
    [switch]$SkipBuild,
    # Run the two refusal gates (offline, waiting timeout) instead of the link
    # journey. They need a and b only, and they consume b's one empty boot, so
    # they are deliberately NOT part of the same run as a successful link.
    [switch]$EdgeGates,
    # The domain E1 points b at. Reserved by RFC 2606, so it can never resolve.
    [string]$DeadRelay = 'relay.invalid',
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag would run a journey nobody asked for
# and report a clean pass for it.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepIdentities, -KeepUp, -SkipBuild, -EdgeGates, -DeadRelay and -BootTimeoutSeconds."
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

$runTag = $script:FleetVars.RUN
$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$server = "fleet-link-$runTag"
$journeyPeers = if ($EdgeGates) { @('a', 'b') } else { @('a', 'b', 'c') }
# G8's picked image: a 16x16 PNG carried inline so every backend has it, and
# names that fit the emote grammar (lowercase a-z, 0-9, _, at most 24).
$emotePngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAABNSURBVDhPY7hjY/OfEjycDfh/nQEDY1OH1QBsmmEYXS2GAdg0oWNk9dQ1AJtibBhZzyDzAgxj0wTD6GqxGgDCxGgGYZwGEIsH2gCb/wBSPnarPKl6tgAAAABJRU5ErkJggg=='
$emoteFixture = Join-Path $script:FleetOutRoot "emote-$runTag.png"
$emoteA = 'pea' + ($runTag.ToLower() -replace '[^a-z0-9_]', '')
$emoteB = 'peb' + ($runTag.ToLower() -replace '[^a-z0-9_]', '')
# a and c are the ones that onboard; b must have NO identity on disk or the
# welcome dialog never appears and the enter-code screen is unreachable.
$fixturePeers = if ($EdgeGates) { @('a') } else { @('a', 'c') }

function Say($message, $colour = 'Cyan') { Write-Host "[device-link] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates. Declared up front so the closing report has a line for every one of
# them, including the ones a failure meant we never reached.
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{}
if ($EdgeGates) {
    $script:Gates['E1 offline: the enter-code screen refuses while disconnected'] = 'SKIP'
    $script:Gates['E2 timeout: b gives up 60s after nobody confirms']             = 'SKIP'
    $script:CleanupGate = 'C  cleanup: nothing left on the relay'
} else {
    $script:Gates['G1 a and c are friends, DM both ways, server traffic both ways'] = 'SKIP'
    $script:Gates['G2 a minted a link code']                                        = 'SKIP'
    $script:Gates['G3 b, empty, entered it and is Linking this device']             = 'SKIP'
    $script:Gates['G4 a reached Data sent and b reached Device linked']             = 'SKIP'
    $script:Gates['G5 the stash landed and b came back up']                         = 'SKIP'
    $script:Gates['G6a b now holds a MASTER identity']                              = 'SKIP'
    $script:Gates['G6b b inherited the server and its #general history']            = 'SKIP'
    $script:Gates['G6c b inherited the friend and the DM history']                  = 'SKIP'
    $script:Gates['G6d both a and b list TWO devices']                              = 'SKIP'
    $script:Gates['G7a c DM after the link reaches a AND b']                        = 'SKIP'
    $script:Gates['G7b c channel post after the link reaches a AND b']              = 'SKIP'
    $script:Gates['G7c b channel post reaches a (sibling) AND c']                   = 'SKIP'
    $script:Gates['G7d b DM to c reaches c AND a (sibling)']                        = 'SKIP'
    $script:Gates['G8a a uploads a personal emote and its Mine tab lists it']       = 'SKIP'
    $script:Gates['G8b b lists the emote and its image arrived']                    = 'SKIP'
    $script:Gates['G8c a removes it and b stops listing it']                        = 'SKIP'
    $script:Gates['G8d b uploads one and a lists it with its image']                = 'SKIP'
    $script:Gates['G9a what b posts is never unread on a']                          = 'SKIP'
    $script:Gates['G9b a reading the DM clears the badge on b']                     = 'SKIP'
    $script:Gates['G9c a reading #general clears the badge on b']                   = 'SKIP'
    $script:Gates['G9d b, offline while a read, comes back with nothing unread']    = 'SKIP'
    $script:CleanupGate = 'C  cleanup: a deleted the server it created'
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
    $answer = Send-FleetStep $peer $obj 240
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
}

# Same, but a failure is an ANSWER rather than the end of the run.
function Invoke-SoftStep($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2} (soft)" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 240
    Write-FleetAnswer $peer $answer '     '
    return $answer
}

# Wait until ANY of several targets holds, and report which one did.
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
        # One full pass always happens before the clock is consulted.
        if ((Get-Date) -ge $deadline) { return $null }
    }
}

# "This peer is up and on the network", without depending on which screen it
# booted into. The connection PROVIDER is the authority; the words "Connected"
# and "Online" are each printed by exactly one surface and neither is reliably
# on screen.
function Wait-ForConnected($peer, $timeoutSeconds = 150) {
    Step $peer @{
        op = 'wait_for'; provider = 'connection'; equals = 'connected'
        timeout_ms = $timeoutSeconds * 1000
    } | Out-Null
}

# Where a peer's app keeps its identity and database. On the simulator that is
# inside the app's own container, which is the only place an iOS app can write.
function Get-PeerDataDir($peer) {
    if (Test-SimBackend) { return Get-SimDataDir (Get-SimUdid $peer) }
    if (Test-LinuxBackend) { return (Join-Path (Join-Path (Get-LinuxFleetHome) 'run') $peer) }
    return (Join-Path $runRoot $peer)
}

function Stop-Peer($peer) {
    $proc = Get-PeerProcess $peer
    if (-not $proc) { Say "$peer is already closed" 'Yellow'; return }
    if (Test-SimBackend) {
        & xcrun simctl terminate $proc.Udid com.anonlisten.hollow 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1500
        if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
        Say "$peer is closed - OFFLINE" 'Yellow'
        return
    }
    $proc | Stop-Process -Force
    # The lock file and the SQLCipher WAL are released on exit; give the handles
    # time to drop before anything else touches that directory.
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - OFFLINE" 'Yellow'
}

# Relaunch ONE peer on its EXISTING data directory. `fleet.ps1 -Live` restores
# every fixture, which would throw away the very link this journey is about.
# Mirrors fleet_pending_join.ps1 / fleet_owner_offline.ps1.
function Restart-Peer($peer) {
    Start-PeerProcess $peer $false
}

# The same launch with the data directory EMPTIED first, which is the only way
# to reach the welcome dialog and therefore the enter-code screen.
function Start-EmptyPeer($peer) {
    Stop-Peer $peer
    $data = Get-PeerDataDir $peer
    if (Test-Path $data) { Remove-Item $data -Recurse -Force }
    Start-PeerProcess $peer $true
}

# The simulator launch, which differs from the desktop one only in where things
# live: an iOS app can write nowhere but its own container, and
# Platform.environment is EMPTY there, so the configuration goes in as a file.
function Start-SimPeerProcess($peer, $wipeData) {
    $udid = Get-SimUdid $peer
    Start-SimDevice $udid
    $documents = Join-Path (Get-SimContainer $udid) 'Documents'
    $data = Join-Path $documents 'hollow'
    $probeOut = Join-Path $documents 'probe_out'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    if (Test-Path $probeOut) { Remove-Item $probeOut -Recurse -Force }
    New-Item -ItemType Directory -Path $probeOut -Force | Out-Null
    $out = Join-Path $script:FleetOutRoot $peer
    New-Item -ItemType Directory -Path $script:FleetOutRoot -Force | Out-Null
    & rm -rf $out
    & ln -sfn $probeOut $out
    $config = @(
        "UI_PROBE_OUT=$probeOut",
        'UI_PROBE_MODE=live',
        "UI_PROBE_PEER=$peer",
        'UI_PROBE_IDLE_MINUTES=40',
        "HOLLOW_DATA_DIR=$data"
    )
    [System.IO.File]::WriteAllText((Join-Path $documents 'probe.env'),
        (($config -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $script:FleetConsumed[$peer] = 0
    $launched = "$(& xcrun simctl launch --terminate-running-process $udid com.anonlisten.hollow 2>&1)"
    if ($LASTEXITCODE -ne 0) { throw "simctl launch for $peer failed: $launched" }
    $what = if ($wipeData) { 'an EMPTY data dir' } else { 'its EXISTING data dir' }
    Say "launched $peer in simulator hollow-$peer on $what"
}

function Start-PeerProcess($peer, $wipeData) {
    if (Test-SimBackend) {
        Start-SimPeerProcess $peer $wipeData
        $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-PeerLive $peer) { Say "$peer is live" 'Green'; return }
            if (-not (Get-PeerProcess $peer)) { throw "peer $peer died on launch.`n" + (Get-CrashTail $peer) }
            Start-Sleep -Milliseconds 300
        }
        throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
    }
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Get-PeerDataDir $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    New-Item -ItemType Directory -Path $data -Force | Out-Null
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
    if (Test-LinuxBackend) {
        # The same launcher fleet.ps1 uses: its own session bus per instance and
        # stdio to files, never a pipe this script holds.
        $launcher = Join-Path $out 'launch.sh'
        $lines = @(
            '#!/bin/sh',
            ('exec dbus-run-session -- "{0}" >"{1}" 2>"{2}" </dev/null' -f (Join-Path $dest 'hollow'),
                (Join-Path $out 'native-stdout.log'), (Join-Path $out 'native-stderr.log'))
        )
        [System.IO.File]::WriteAllText($launcher, (($lines -join "`n") + "`n"))
        & chmod +x $launcher
        $proc = Start-Process -FilePath $launcher -WorkingDirectory $dest -PassThru
    } else {
        $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') -WorkingDirectory $dest -PassThru
    }
    $what = if ($wipeData) { 'an EMPTY data dir' } else { 'its EXISTING data dir' }
    Say "launched $peer (pid $($proc.Id)) on $what"

    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { Say "$peer is live" 'Green'; return }
        # The handle, not a path lookup: a process still initialising hides its
        # path and reads as dead for a poll or two.
        if ($proc.HasExited) { throw "peer $peer died on launch.`n" + (Get-CrashTail $peer) }
        Start-Sleep -Milliseconds 300
    }
    throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
}

# Hand the out directory over to a copy of the app that is about to replace
# this one. The live loop TRUNCATES the outbox on start but replays the whole
# INBOX from line 0, so a self-relaunch would re-run every step of the journey
# so far unless the inbox is emptied first; and `live-ready` is a file, so a
# stale one makes a dead peer look alive.
#
# Only ever call this on a peer that is ABOUT TO DIE. The live loop tracks its
# read position in memory, so truncating under a RUNNING instance leaves that
# position past the end of the file and every later command lands at an index
# it will never look at again: the peer stops answering for good.
function Reset-PeerMailbox($peer) {
    $out = Join-Path $script:FleetOutRoot $peer
    [System.IO.File]::WriteAllText((Join-Path $out 'inbox.jsonl'), '',
        (New-Object System.Text.UTF8Encoding($false)))
    $marker = Join-Path $out 'live-ready'
    if (Test-Path $marker) { Remove-Item $marker -Force }
    $script:FleetConsumed[$peer] = 0
}

# Screenshots and dumps taken before a Restart-Peer would go with the out
# directory, so anything worth keeping is copied out first.
function Backup-PeerArtifacts($peer, $label) {
    $out = Join-Path $script:FleetOutRoot $peer
    $kept = Join-Path $script:FleetOutRoot "kept\$runTag-$peer-$label"
    if (-not (Test-Path $out)) { return }
    New-Item -ItemType Directory -Path $kept -Force | Out-Null
    Get-ChildItem $out -File -Include *.png, *.json, *.md, *.log, results.jsonl -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $kept -Force -ErrorAction SilentlyContinue }
    Say "kept $peer's artifacts in $kept" 'DarkGray'
}

# --------------------------------------------------------------------------
# Reading a dump. The widgets are a view; these are the providers behind them.
# A dump has to be READ BEFORE its peer is relaunched when the relaunch wipes
# the output directory (the fallback path does; the self-relaunch does not).
# --------------------------------------------------------------------------
function Get-DumpJson($peer, $name) {
    $path = Join-Path $script:FleetOutRoot "$peer\map-$name.json"
    if (-not (Test-Path $path)) { throw "no dump for $peer at $path" }
    return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-DumpValue($peer, $name, $key) {
    $providers = (Get-DumpJson $peer $name).providers
    if (-not $providers) { return $null }
    return $providers.$key
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

function Get-DumpFriendRows($peer, $name) {
    $rows = (Get-DumpJson $peer $name).providers.friends
    if (-not $rows) { return @() }
    return @($rows)
}

function Format-FriendRows($rows) {
    # A function that returns an empty array hands back $null, and @($null) is a
    # one-element array, so an empty list would print as a blank row.
    $all = @(@($rows) | Where-Object { $_ })
    if ($all.Count -eq 0) { return '(none)' }
    return (@($all | ForEach-Object {
        $direction = ''
        if ($_.direction) { $direction = " ($($_.direction))" }
        "$($_.peerId) $($_.status)$direction"
    }) -join '; ')
}

# Every message body the dump holds for a conversation kind, flattened. The
# dump keeps the last three bodies per conversation, which is what a gate about
# "did the history come across" needs.
function Get-DumpBodies($peer, $name, $key) {
    $map = (Get-DumpJson $peer $name).providers.$key
    if (-not $map) { return @() }
    $bodies = @()
    foreach ($property in $map.PSObject.Properties) {
        foreach ($body in @($property.Value.last)) {
            if ($body) { $bodies += "$body" }
        }
    }
    return $bodies
}

# One badge, straight from the unread provider the strip and the friend chips
# render from. A missing entry is 0.
function Get-UnreadCount($peer, $name, $kind, $key) {
    $mapKey = if ($kind -eq 'dm') { 'dmUnreadCounts' } else { 'channelUnreadCounts' }
    $map = (Get-DumpJson $peer $name).providers.$mapKey
    if (-not $map) { return 0 }
    $entry = $map.PSObject.Properties[$key]
    if ($entry) { return [int]$entry.Value } else { return 0 }
}

# Poll a peer's badge until $test (a scriptblock over the count) holds. Returns
# the last count seen, so a caller reports the number and not just a verdict.
function Wait-UnreadCount($peer, $kind, $key, $test, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $count = 0
    while ($true) {
        Step $peer @{ op = 'dump'; name = "g9_$peer" }
        $count = Get-UnreadCount $peer "g9_$peer" $kind $key
        if (& $test $count) { return $count }
        if ((Get-Date) -ge $deadline) { return $count }
        Start-Sleep -Seconds 2
    }
}

function Get-DumpCount($peer, $name, $key) {
    $map = (Get-DumpJson $peer $name).providers.$key
    if (-not $map) { return 0 }
    $total = 0
    foreach ($property in $map.PSObject.Properties) {
        $total += [int]$property.Value.count
    }
    return $total
}

# What a peer's own log says. hollow_debug.log sits next to the exe, survives a
# relaunch and accumulates across runs, so every caller filters by this run's
# tag or by a string only this run could have written.
function Get-PeerLogLines($peer, $pattern) {
    $path = Join-Path $script:FleetStageRoot "$peer\hollow_debug.log"
    if (-not (Test-Path $path)) { return @() }
    try {
        return @(Get-Content $path -Encoding UTF8 -ErrorAction Stop |
            Where-Object { $_.Contains($pattern) })
    } catch {
        Add-Note "could not read $peer's hollow_debug.log ($($_.Exception.Message))"
        return @()
    }
}

# --------------------------------------------------------------------------
# The surfaces this journey drives
# --------------------------------------------------------------------------

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

# Never a bare Escape (focus has left the dialog by then and the key reaches
# nothing, leaving the barrier over the next phase's controls) and never a bare
# semantics:Close, which matches the window title bar first and ends the process.
function Close-Friends($peer) {
    if (-not (Test-FriendsManagerOpen $peer)) { return }
    Step $peer @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
}

function Show-FriendsTab($peer, $tab) {
    Step $peer @{ op = 'tap'; target = "type:HollowChip>text:$tab"; index = 0 }
}

function Open-Dm($peer, $friendName) {
    Step $peer @{ op = 'wait_for'; target = "semantics:$friendName"; timeout_ms = 60000 }
    Step $peer @{ op = 'tap'; target = "semantics:$friendName" }
    Step $peer @{ op = 'wait'; ms = 1500 }
    Step $peer @{ op = 'wait_for'; target = 'hint:Type a message...'; timeout_ms = 30000 }
}

# The composer is TAPPED first: enter_text on an unfocused field reports success
# into nothing. Every send waits for its OWN optimistic row, so a send that
# never happened cannot be mistaken for a delivery failure on the other side.
# Retried, because that wait has caught a real swallow before.
function Send-Dm($peer, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = 'hint:Type a message...' }
        Step $peer @{ op = 'enter_text'; target = 'hint:Type a message...'; value = $body }
        # Enter does not send on the mobile shell; the send button does.
        if (Test-SimBackend) {
            Step $peer @{ op = 'tap'; target = 'semantics:Send'; index = 0 }
        } else {
            Step $peer @{ op = 'key'; value = 'enter' }
        }
        $landed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }
        if ($landed.ok) { return }
        Add-Note "$peer's DM composer swallowed the send on attempt $attempt"
        Invoke-SoftStep $peer @{ op = 'shot'; name = "link-$runTag-$peer-dm-swallow-$attempt" } | Out-Null
    }
    throw "[$peer] the DM composer never produced a row for '$body' after 3 attempts"
}

# The emoji picker is an OverlayEntry on desktop and a bottom sheet on the
# mobile shell; the tab and upload labels inside are the same on both.
function Open-MineTab($peer) {
    $button = if (Test-SimBackend) { 'semantics:Emoji' } else { 'semantics:Insert emoji' }
    Step $peer @{ op = 'wait_for'; target = $button; timeout_ms = 30000 }
    Step $peer @{ op = 'tap'; target = $button }
    Step $peer @{ op = 'wait_for'; target = 'semantics:Mine emotes tab'; timeout_ms = 15000 }
    Step $peer @{ op = 'tap'; target = 'semantics:Mine emotes tab' }
    Step $peer @{ op = 'wait'; ms = 500 }
}

# Both hosts close on a tap outside the picker, and the top-left corner is
# never under it (it hangs off the composer at the bottom).
function Close-Picker($peer) {
    Invoke-SoftStep $peer @{ op = 'tap_at'; x = 40; y = 120 } | Out-Null
    Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'semantics:Mine emotes tab'; timeout_ms = 5000 } | Out-Null
}

# Uploads the fixture as a personal emote named $name and leaves the picker
# open on the Mine tab. `arm_image_pick` answers the pick, because the native
# dialog is an OS modal the probe cannot see.
function Invoke-EmoteUpload($peer, $name) {
    Open-MineTab $peer
    Step $peer @{ op = 'arm_image_pick'; path = $emoteFixture }
    Step $peer @{ op = 'tap'; target = 'semantics:Upload a personal emote image' }
    Step $peer @{ op = 'wait_for'; target = 'dialog > text:Name this emote'; timeout_ms = 15000 }
    Step $peer @{ op = 'enter_text'; target = 'dialog > field'; value = $name }
    Step $peer @{ op = 'tap'; target = 'dialog > text:Save' }
    $listed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "semantics:Emote $name"; timeout_ms = 20000 }
    if (-not $listed.ok) { Add-Note "$peer's Mine tab never listed $name after Save" }
    return $listed.ok
}

# The Mine tab on $peer lists $name AND its image has arrived (the image's
# own label only exists once the bytes came over the asset rail).
function Wait-MineEmote($peer, $name, $timeoutMs = 60000) {
    $listed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "semantics:Emote $name"; timeout_ms = $timeoutMs }
    if (-not $listed.ok) { Add-Note "$peer's Mine tab never listed $name"; return $false }
    $image = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "semantics::${name}: emote"; timeout_ms = $timeoutMs }
    if (-not $image.ok) { Add-Note "$peer listed $name but its image never arrived over the asset rail"; return $false }
    return $true
}

function Send-Channel($peer, $channel, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = "hint:Message #$channel" }
        Step $peer @{ op = 'enter_text'; target = "hint:Message #$channel"; value = $body }
        # Enter does not send on the mobile shell; the send button does.
        if (Test-SimBackend) {
            Step $peer @{ op = 'tap'; target = 'semantics:Send'; index = 0 }
        } else {
            Step $peer @{ op = 'key'; value = 'enter' }
        }
        $landed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }
        if ($landed.ok) { return }
        Add-Note "$peer's #$channel composer swallowed the send on attempt $attempt"
        Invoke-SoftStep $peer @{ op = 'shot'; name = "link-$runTag-$peer-ch-swallow-$attempt" } | Out-Null
    }
    throw "[$peer] the #$channel composer never produced a row for '$body' after 3 attempts"
}

# The Devices surface. Desktop reaches it through the settings dialog's
# category rail; the mobile shell pushes a sub-page from a row addressed by its
# SUBTITLE, and the row is far enough down the list to need scrolling into
# existence first (a ListView does not build what is off screen, so a wait_for
# on an unscrolled row times out for a correct app).
function Open-SettingsDevices($peer) {
    if (Test-SimBackend) {
        Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
        Step $peer @{ op = 'wait_for'; target = 'text:Appearance'; timeout_ms = 20000 }
        for ($i = 0; $i -lt 6; $i++) {
            $row = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'text:Linked devices & multi-device tools'; timeout_ms = 1200 }
            if ($row.ok) { break }
            Invoke-SoftStep $peer @{ op = 'scroll'; target = 'text:Appearance'; dy = -600 } | Out-Null
        }
        Step $peer @{ op = 'tap'; target = 'text:Linked devices & multi-device tools'; index = 0 }
        Step $peer @{ op = 'wait_for'; target = 'text:Link a device'; timeout_ms = 20000 }
        return
    }
    Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent'; timeout_ms = 20000 }
    # SCOPED to the dialog: the Home dashboard's stats card has a "Devices" row
    # of its own, it comes first in tree order, and the settings dialog is
    # sitting on top of it, so the unscoped tap lands on something covered.
    Step $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > text:Devices'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent > text:Link a device'; timeout_ms = 20000 }
}

function Close-Settings($peer) {
    if (Test-SimBackend) {
        for ($i = 0; $i -lt 3; $i++) {
            $back = Invoke-SoftStep $peer @{ op = 'tap'; target = 'semantics:Back'; index = 0 }
            if (-not $back.ok) { break }
        }
        Invoke-SoftStep $peer @{ op = 'tap'; target = 'semantics:Chats'; index = 0 } | Out-Null
        return
    }
    $open = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent'; timeout_ms = 1500 }
    if (-not $open.ok) { return }
    # Escape first: after a failed gate the link-code screen still covers the
    # Close button, and a tap that cannot reach it used to sink the cleanup.
    Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
    $gone = Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 3000 }
    if ($gone.ok) { return }
    Step $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 10000 }
}

# Opens "Link a device" on the populated side and reads the code off the screen.
#
# The dialog renders the code SPACED OUT (`code.split('').join(' ')`), and until
# the notifier has minted one it renders six dots, so the capture is a regex for
# six spaced code characters and it is retried rather than failed: the mint
# happens a frame or two after the dialog appears.
function Get-LinkCode($peer) {
    $button = if (Test-SimBackend) { 'text:Link a device' } else { 'type:_UserSettingsContent > text:Link a device' }
    Step $peer @{ op = 'tap'; target = $button; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_DeviceLinkContent'; timeout_ms = 20000 }
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $answer = Invoke-SoftStep $peer @{
            op = 'capture'; target = 'type:_DeviceLinkContent'; as = 'LINKCODE_RAW'
            regex = '([A-Z2-9](?: [A-Z2-9]){5})'
        }
        if ($answer.ok) {
            $code = ($script:FleetVars['LINKCODE_RAW'] -replace '\s', '')
            if ($code.Length -eq 6) {
                $script:FleetVars['LINKCODE'] = $code
                Say "$peer is showing link code $code" 'Green'
                return $code
            }
        }
        Start-Sleep -Milliseconds 700
    }
    throw "[$peer] never rendered a 6-character link code"
}

# Walks the welcome dialog to the enter-code screen. `relayDomain` empty leaves
# the official relay in place; anything else is typed into the Advanced field,
# which is how E1 gets a peer that cannot reach a relay without the fleet
# growing a switch of its own.
function Open-EnterCode($peer, $relayDomain) {
    Step $peer @{ op = 'wait_for'; target = 'text:Create New Identity'; timeout_ms = 90000 }
    if ($relayDomain) {
        Step $peer @{ op = 'tap'; target = 'text:Advanced'; index = 0 }
        Step $peer @{ op = 'wait_for'; target = 'hint:relay.anonlisten.com'; timeout_ms = 10000 }
        Step $peer @{ op = 'enter_text'; target = 'hint:relay.anonlisten.com'; value = $relayDomain }
        Step $peer @{ op = 'wait_for'; target = "text:$relayDomain"; timeout_ms = 10000 }
    }
    Step $peer @{ op = 'tap'; target = 'text:Link a device'; index = 0 }
    # A throwaway identity is created and the node started before the dialog
    # appears, so this is the slow one.
    Step $peer @{ op = 'wait_for'; target = 'text:Link this device'; timeout_ms = 180000 }
    Step $peer @{ op = 'wait_for'; target = 'hint:ABC123'; timeout_ms = 20000 }
}

# Delete a server through the UI, as its owner. Used by the cleanup only, so
# the journey and the cleanup can never disagree about how it is done.
function Remove-Server($peer, $name) {
    Step $peer @{ op = 'wait_for'; target = "server:$name"; timeout_ms = 60000 }
    Step $peer @{ op = 'right_click'; target = "server:$name" }
    Step $peer @{ op = 'tap'; target = 'menu > text:Server settings' }
    Step $peer @{ op = 'reveal'; target = 'text:Delete server'; index = 0 }
    Step $peer @{ op = 'tap'; target = 'text:Delete server'; index = 0 }
    # index 1: index 0 is the dialog's TITLE, and tapping a title silently does
    # nothing and PASSES.
    Step $peer @{ op = 'tap'; target = 'dialog > text:Delete server'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = "server:$name"; timeout_ms = 60000 }
}

# --------------------------------------------------------------------------
# Boot
# --------------------------------------------------------------------------

if (-not $SkipBuild) {
    Say "building and staging $($journeyPeers -join ',') (pass -SkipBuild when you have just built)"
    Invoke-FleetScript @('-Build', '-Peers', ($journeyPeers -join ','))
}

if ($KeepIdentities) {
    Say 'keeping the identities that are already live (their relay rings are not empty)' 'Yellow'
    if ((Get-LivePeers).Count -eq 0) {
        Say 'nothing is live (a build stops the fleet) - booting the existing fixtures'
        Invoke-FleetScript @('-Live', '-Peers', ($fixturePeers -join ','))
        foreach ($peer in $fixturePeers) { $script:FleetConsumed[$peer] = 0 }
    }
} else {
    # Only the populated peers onboard. b must reach the WELCOME dialog, which
    # only exists while there is no identity on disk.
    Start-FreshFleet $fixturePeers
}

$live = Get-LivePeers
foreach ($peer in $fixturePeers) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running (live: $($live -join ', '))"
    }
}
Say "run tag $runTag, server $server"

$failure = $null
$serverCreated = $false
$serverDeleted = $false
$masterA = ''
$masterC = ''
$relaunchPath = 'not reached'

try {
    foreach ($peer in $fixturePeers) { Wait-ForConnected $peer }
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    $masterA = $script:FleetVars['PEER_A']
    if (-not $masterA) { throw "could not read a's master identity" }

    if ($EdgeGates) {

        # ---- E1: the offline refusal ---------------------------------------
        Say "1/2 b boots against an unreachable relay ($DeadRelay) and must refuse"
        Start-EmptyPeer b
        Open-EnterCode b $DeadRelay
        Step b @{ op = 'shot'; name = "link-$runTag-b-offline" }
        $conn = Invoke-SoftStep b @{ op = 'capture'; from = 'provider'; key = 'connection'; as = 'B_CONN' }
        if ($conn.ok -and $script:FleetVars['B_CONN'] -eq 'connected') {
            throw "b reports connection=connected against $DeadRelay, so this gate proves nothing"
        }
        Add-Note "b's connection provider against $DeadRelay reads '$($script:FleetVars['B_CONN'])'"
        Step b @{ op = 'wait_for'; target = 'contains:Hollow is not connected to the relay yet'; timeout_ms = 30000 }
        # And it holds at the PRESS, not only in the caption: a disabled button
        # that silently did nothing would look identical from the outside.
        Step b @{ op = 'enter_text'; target = 'hint:ABC123'; value = 'ABC234' }
        Step b @{ op = 'tap'; target = 'text:Link'; index = 0 }
        Step b @{ op = 'wait'; ms = 6000 }
        Step b @{ op = 'expect_no_text'; value = 'Linking this device' }
        Step b @{ op = 'expect_text'; value = 'Hollow is not connected to the relay yet' }
        Step b @{ op = 'shot'; name = "link-$runTag-b-offline-after-press" }
        Set-Gate 'E1 offline: the enter-code screen refuses while disconnected' 'PASS'
        Say 'PASS E1: the enter-code screen says so and the press does nothing' 'Green'

        # ---- E2: the 60s waiting timeout -----------------------------------
        Say '2/2 b enters a real code and a never confirms'
        # E2 relaunches b, and a launch recreates the output directory, so E1's
        # screenshots are copied out before they go.
        Backup-PeerArtifacts b 'e1-offline'
        Start-EmptyPeer b
        Open-EnterCode b ''
        Wait-ForConnected b
        Open-SettingsDevices a
        $code = Get-LinkCode a
        Step b @{ op = 'enter_text'; target = 'hint:ABC123'; value = $code }
        Step b @{ op = 'wait_for'; target = "text:$code"; timeout_ms = 15000 }
        Step b @{ op = 'tap'; target = 'text:Link'; index = 0 }
        Step b @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 }
        # a is deliberately left sitting on the confirm: the gate is that b
        # gives up on its own rather than waiting forever for a human.
        $confirm = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:Send your data?'; timeout_ms = 45000 }
        if ($confirm.ok) {
            Add-Note 'a reached the confirm prompt and was deliberately left there'
        } else {
            Add-Note 'a never reached the confirm prompt, so b timed out with nobody even asked'
        }
        Step b @{ op = 'wait_for'; target = 'contains:Your other device did not answer'; timeout_ms = 90000 }
        Step b @{ op = 'shot'; name = "link-$runTag-b-timeout" }
        Step b @{ op = 'expect_text'; value = 'Link failed' }
        Set-Gate 'E2 timeout: b gives up 60s after nobody confirms' 'PASS'
        Say 'PASS E2: b gave up on its own' 'Green'

        if ($confirm.ok) {
            Invoke-SoftStep a @{ op = 'tap'; target = 'text:Decline'; index = 0 } | Out-Null
        }
        Close-Settings a
        Set-Gate $script:CleanupGate 'PASS'

    } else {

        Step c @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_C' }
        $masterC = $script:FleetVars['PEER_C']
        if (-not $masterC) { throw "could not read c's master identity" }

        # ---- G1: give a something worth inheriting -------------------------
        Say '1/7 a and c become friends, DM both ways, and share a server'
        Open-Friends a
        Show-FriendsTab a 'Add friend'
        # Assert the id really IS in the field before sending: enter_text has
        # reported success into this field while it held only a fragment.
        Step a @{ op = 'enter_text'; target = 'hint:Paste an ID, or type a nickname'; value = '${PEER_C}' }
        Step a @{ op = 'wait_for'; target = 'text:${PEER_C}'; timeout_ms = 15000 }
        Step a @{ op = 'tap'; target = 'text:Send request'; index = 0 }

        # The Accept button only exists on the INCOMING tab.
        Open-Friends c
        Show-FriendsTab c 'Requests'
        Step c @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 90000 }
        Step c @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }
        Step a @{ op = 'wait_for'; target = 'text:probe-c'; timeout_ms = 90000 }
        Step c @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 90000 }
        Close-Friends a
        Close-Friends c

        Open-Dm a 'probe-c'
        Send-Dm a 'dm a to c ${RUN}'
        Step c @{ op = 'wait_for'; target = 'text:dm a to c ${RUN}'; timeout_ms = 90000 }
        Open-Dm c 'probe-a'
        Send-Dm c 'dm c to a ${RUN}'
        Step a @{ op = 'wait_for'; target = 'text:dm c to a ${RUN}'; timeout_ms = 90000 }

        Step a @{ op = 'tap'; target = 'semantics:Create a server' }
        Step a @{ op = 'enter_text'; target = 'hint:My Awesome Server'; value = $server }
        Step a @{ op = 'tap'; target = 'text:Create'; index = 0 }
        Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }
        $serverCreated = $true
        Step a @{ op = 'open_server'; name = $server }
        Step a @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }

        # A voice channel as well as #general: it rides the join snapshot to c
        # and the link snapshot to b, and it is what the channel-settings shot
        # below is of. Soft, because the journey is about linking.
        $voiceMade = $false
        $vc = Invoke-SoftStep a @{ op = 'tap'; target = 'semantics:Create channel'; index = 0 }
        if ($vc.ok) {
            Invoke-SoftStep a @{ op = 'tap'; target = 'dialog > text:Voice'; index = 0 } | Out-Null
            Invoke-SoftStep a @{ op = 'enter_text'; target = 'dialog > type:TextField'; value = 'vc-link' } | Out-Null
            Invoke-SoftStep a @{ op = 'tap'; target = 'dialog > text:Create'; index = 0 } | Out-Null
            $made = Invoke-SoftStep a @{ op = 'wait_for'; target = 'channel:vc-link'; timeout_ms = 30000 }
            $voiceMade = $made.ok
        }
        if ($voiceMade) {
            Add-Note 'the server carries a voice channel vc-link as well as #general'
        } else {
            Add-Note 'the voice channel could not be created; the journey continues on #general alone'
        }

        Step a @{ op = 'right_click'; target = "server:$server" }
        Step a @{ op = 'tap'; target = 'menu > text:Invite people' }
        Step a @{ op = 'wait_for'; target = 'type:SelectableText'; timeout_ms = 20000 }
        Step a @{ op = 'capture'; target = 'type:SelectableText'; as = 'INVITE' }
        Step a @{ op = 'key'; value = 'escape' }

        Step c @{ op = 'tap'; target = 'semantics:Create a server' }
        Step c @{ op = 'enter_text'; target = 'hint:Invite link or server ID'; value = '${INVITE}' }
        Step c @{ op = 'tap'; target = 'text:Join'; index = 0 }
        Step c @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 120000 }
        Step c @{ op = 'open_server'; name = $server }
        Step c @{ op = 'open_channel'; name = 'general' }
        Step a @{ op = 'wait_for'; target = 'text:probe-c'; timeout_ms = 90000 }

        Step a @{ op = 'open_channel'; name = 'general' }
        Send-Channel a 'general' 'ch a before link ${RUN}'
        Step c @{ op = 'wait_for'; target = 'text:ch a before link ${RUN}'; timeout_ms = 90000 }
        Send-Channel c 'general' 'ch c before link ${RUN}'
        Step a @{ op = 'wait_for'; target = 'text:ch c before link ${RUN}'; timeout_ms = 90000 }
        Step a @{ op = 'dump'; name = 'g1_a' }
        Step a @{ op = 'shot'; name = "link-$runTag-a-g1" }
        Set-Gate 'G1 a and c are friends, DM both ways, server traffic both ways' 'PASS'
        Say 'PASS G1: a has friends, DMs, a server and channel history to inherit' 'Green'

        # The issue #71 channel-settings surface, while a server with a voice
        # channel is open. Soft: it is evidence, not a gate.
        if ($voiceMade) {
            $shot = Invoke-SoftStep a @{ op = 'right_click'; target = "server:$server" }
            if ($shot.ok) {
                Invoke-SoftStep a @{ op = 'tap'; target = 'menu > text:Server settings' } | Out-Null
                Invoke-SoftStep a @{ op = 'tap'; target = 'text:Channels'; index = 0 } | Out-Null
                Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:vc-link'; timeout_ms = 15000 } | Out-Null
                Invoke-SoftStep a @{ op = 'shot'; name = "link-$runTag-a-channels-tab" } | Out-Null
                Invoke-SoftStep a @{ op = 'look' } | Out-Null
                # By its own control, scoped: a bare semantics:Close matches the
                # window title bar first, and that tap ends the process.
                Invoke-SoftStep a @{ op = 'tap'; target = 'type:ServerSettingsPanel > semantics:Close'; index = 0 } | Out-Null
                Invoke-SoftStep a @{ op = 'wait_for'; gone = 'type:ServerSettingsPanel'; timeout_ms = 10000 } | Out-Null
                Add-Note "channels-tab screenshot: build\fleet_out\a\live-*-link-$runTag-a-channels-tab.png"
            }
        }

        # ---- G2: a mints a code --------------------------------------------
        Say '2/7 a opens Settings > Devices and shows a link code'
        # Belt and braces: the channels-tab shot above leaves a barriered panel
        # open if its own Close missed, and Settings is unreachable behind it.
        Invoke-SoftStep a @{ op = 'tap'; target = 'type:ServerSettingsPanel > semantics:Close'; index = 0 } | Out-Null
        Open-SettingsDevices a
        $alone = Invoke-SoftStep a @{ op = 'expect_text'; value = 'Only this device is linked to your identity' }
        if (-not $alone.ok) { Add-Note 'a was not showing the single-device copy before the link' }
        $code = Get-LinkCode a
        Step a @{ op = 'shot'; name = "link-$runTag-a-code" }
        Set-Gate 'G2 a minted a link code' 'PASS'

        # ---- G3: the empty device enters it --------------------------------
        Say '3/7 b boots EMPTY, walks Welcome > Link a device and enters the code'
        Start-EmptyPeer b
        Open-EnterCode b ''
        Wait-ForConnected b
        Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B_THROWAWAY' }
        Add-Note "b's throwaway identity before the link: $($script:FleetVars['PEER_B_THROWAWAY'])"
        Step b @{ op = 'enter_text'; target = 'hint:ABC123'; value = $code }
        Step b @{ op = 'wait_for'; target = "text:$code"; timeout_ms = 15000 }
        Step b @{ op = 'tap'; target = 'text:Link'; index = 0 }
        Step b @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 }
        Step b @{ op = 'shot'; name = "link-$runTag-b-linking" }
        Set-Gate 'G3 b, empty, entered it and is Linking this device' 'PASS'

        # ---- G4: a confirms and the bytes cross ----------------------------
        Say '4/7 a confirms the push'
        Step a @{ op = 'wait_for'; target = 'text:Send your data?'; timeout_ms = 60000 }
        Step a @{ op = 'shot'; name = "link-$runTag-a-confirm" }
        Step a @{ op = 'tap'; target = 'text:Send data'; index = 0 }
        Step a @{ op = 'wait_for'; target = 'text:Data sent'; timeout_ms = 180000 }
        Step a @{ op = 'shot'; name = "link-$runTag-a-sent" }
        $bData = Get-PeerDataDir 'b'
        $blob = Join-Path $bData 'pending_link.hollow'
        $codeFile = Join-Path $bData 'pending_link.code'
        $blobSeen = $false
        $blobBytes = 0
        $oldPid = 0
        if (Test-LinuxBackend) {
            # On Linux the copy that replaces b boots about four seconds after
            # the stash and truncates the outbox as it starts, so the "Device
            # linked" answer is never read here. The stash on disk is the proof
            # the bytes crossed, and the mailbox is handed over the moment it
            # appears, while the doomed process is still showing the done view.
            for ($i = 0; $i -lt 480; $i++) {
                if ((Test-Path $blob) -and (Test-Path $codeFile)) {
                    $blobSeen = $true
                    $blobBytes = (Get-Item $blob).Length
                    break
                }
                Start-Sleep -Milliseconds 250
            }
            if (-not $blobSeen) { throw 'b never stashed pending_link.hollow after a reported Data sent' }
            $bProc = Get-PeerProcess b
            $oldPid = if ($bProc) { $bProc.Id } else { 0 }
            Backup-PeerArtifacts b 'pre-relaunch'
            Reset-PeerMailbox b
        } else {
            Step b @{ op = 'wait_for'; target = 'text:Device linked'; timeout_ms = 120000 }
            Step b @{ op = 'shot'; name = "link-$runTag-b-linked" }
        }
        Set-Gate 'G4 a reached Data sent and b reached Device linked' 'PASS'
        Say 'PASS G4: the snapshot crossed' 'Green'

        # ---- G5: THE RESTART -----------------------------------------------
        # b stashed the blob and schedules its own relaunch 1.5s after the done
        # view appears, through the Rust waiter. Nothing here can stop it, so
        # the stash is read NOW and the out directory is handed over before the
        # copy that replaces this one starts reading the inbox from line 0.
        Say '5/7 b restarts itself to import the snapshot'
        if (-not (Test-LinuxBackend)) {
            for ($i = 0; $i -lt 40; $i++) {
                if ((Test-Path $blob) -and (Test-Path $codeFile)) {
                    $blobSeen = $true
                    $blobBytes = (Get-Item $blob).Length
                    break
                }
                Start-Sleep -Milliseconds 250
            }
            $bProc = Get-PeerProcess b
            $oldPid = if ($bProc) { $bProc.Id } else { 0 }
            Backup-PeerArtifacts b 'pre-relaunch'
            Reset-PeerMailbox b
        }
        if ($blobSeen) {
            Say "b stashed pending_link.hollow ($blobBytes bytes) + pending_link.code" 'Green'
        } else {
            Add-Note 'the pending_link stash was never seen on disk (it may have been imported before the first poll)'
        }

        # a's link dialog is a barrier over the settings dialog behind it, so
        # everything a does from here needs it gone first. It waits until the
        # stash has been read: b imports it on its next launch, seconds away.
        Step a @{ op = 'tap'; target = 'text:Done'; index = 0 }
        Step a @{ op = 'wait_for'; gone = 'type:_DeviceLinkContent'; timeout_ms = 15000 }
        Close-Settings a

        # Wait for the self-relaunch: the old pid has to go and a NEW one has to
        # take its place under build\fleet\b.
        $deadline = (Get-Date).AddSeconds(120)
        $newPid = 0
        while ((Get-Date) -lt $deadline) {
            $now = Get-PeerProcess b
            if ($now -and $now.Id -ne $oldPid -and (Test-PeerLive b)) { $newPid = $now.Id; break }
            Start-Sleep -Milliseconds 400
        }
        if ($newPid -gt 0) {
            $relaunchPath = "self-relaunch through the Rust waiter (pid $oldPid -> $newPid)"
            Say "b relaunched itself: pid $oldPid -> $newPid" 'Green'
        } else {
            $relaunchPath = 'fallback: Stop-Peer + Restart-Peer by the script'
            Add-Note 'b did not come back on its own within 120s, so the script restarted it'
            Stop-Peer b
            Restart-Peer b
        }
        Set-Gate 'G5 the stash landed and b came back up' $(if ($blobSeen) { 'PASS' } else { 'WARN' })

        # ---- G6: b IS a now -------------------------------------------------
        Say '6/7 b comes back as a sibling of a'
        Wait-ForConnected b
        Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B_AFTER' }
        $masterB = $script:FleetVars['PEER_B_AFTER']
        if ($masterB -ne $masterA) {
            throw "b's identity after the link is $masterB, a's master is $masterA"
        }
        Say "b's identity is now a's master ($masterB)" 'Green'
        Set-Gate 'G6a b now holds a MASTER identity' 'PASS'

        Step b @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 120000 }
        Step b @{ op = 'open_server'; name = $server }
        Step b @{ op = 'open_channel'; name = 'general' }
        Step b @{ op = 'wait_for'; target = 'text:ch a before link ${RUN}'; timeout_ms = 90000 }
        Step b @{ op = 'wait_for'; target = 'text:ch c before link ${RUN}'; timeout_ms = 90000 }
        Step b @{ op = 'dump'; name = 'g6_b' }
        Step b @{ op = 'shot'; name = "link-$runTag-b-inherited" }
        $bServers = @(Get-DumpServerNames b 'g6_b')
        if ($bServers -notcontains $server) {
            throw "b's tile is there but its server list does not hold $server. Servers: $($bServers -join '; ')"
        }
        $bChannels = @(Get-DumpChannelNames b 'g6_b')
        Say "b's channels: $($bChannels -join ', ')" 'Green'
        Set-Gate 'G6b b inherited the server and its #general history' 'PASS'

        $bFriends = @(Get-DumpFriendRows b 'g6_b')
        Say "b's friends: $(Format-FriendRows $bFriends)" 'DarkCyan'
        $rowC = @(@($bFriends) | Where-Object { $_.peerId -eq $masterC }) | Select-Object -First 1
        if (-not $rowC -or $rowC.status -ne 'accepted') {
            throw "b did not inherit the friendship with c ($masterC). Rows: $(Format-FriendRows $bFriends)"
        }
        Open-Dm b 'probe-c'
        Step b @{ op = 'wait_for'; target = 'text:dm a to c ${RUN}'; timeout_ms = 60000 }
        Step b @{ op = 'wait_for'; target = 'text:dm c to a ${RUN}'; timeout_ms = 60000 }
        Step b @{ op = 'dump'; name = 'g6_b_dm' }
        Say "b's DM rows: $(Get-DumpCount b 'g6_b_dm' 'dms')" 'Green'
        Set-Gate 'G6c b inherited the friend and the DM history' 'PASS'

        foreach ($peer in @('a', 'b')) {
            Close-Settings $peer
            Open-SettingsDevices $peer
            Step $peer @{ op = 'wait_for'; target = 'contains:Devices linked to your identity'; timeout_ms = 90000 }
            Step $peer @{ op = 'wait_for'; target = 'type:DeviceRowShell'; count = 2; timeout_ms = 60000 }
            Step $peer @{ op = 'shot'; name = "link-$runTag-$peer-devices" }
            Close-Settings $peer
        }
        Set-Gate 'G6d both a and b list TWO devices' 'PASS'
        Say 'PASS G6: b is a second device on the same identity' 'Green'

        # ---- G7: does it all keep syncing ----------------------------------
        # Every peer looks at the surface the message is going to land on FIRST.
        # `wait_for` only sees BUILT widgets, so a peer sitting in a server view
        # never renders an arriving DM and the wait reads as a delivery failure
        # that is nothing of the kind. The channel half runs while all three are
        # in #general; the DM half runs after they have all switched.
        Say '7/7 live traffic after the link, every direction on its own'
        foreach ($peer in @('a', 'b', 'c')) {
            Step $peer @{ op = 'open_server'; name = $server }
            Step $peer @{ op = 'open_channel'; name = 'general' }
        }

        Send-Channel c 'general' 'ch c after link ${RUN}'
        $chA = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:ch c after link ${RUN}'; timeout_ms = 90000 }
        $chB = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:ch c after link ${RUN}'; timeout_ms = 90000 }
        if (-not $chA.ok) { Add-Note 'c channel post after the link did NOT reach a' }
        if (-not $chB.ok) { Add-Note 'c channel post after the link did NOT reach b (the new device)' }
        Set-Gate 'G7b c channel post after the link reaches a AND b' $(if ($chA.ok -and $chB.ok) { 'PASS' } else { 'FAIL' })

        $bSent = $true
        try { Send-Channel b 'general' 'ch b after link ${RUN}' } catch { $bSent = $false; Add-Note "b could not post in #general: $($_.Exception.Message)" }
        $bChA = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:ch b after link ${RUN}'; timeout_ms = 90000 }
        $bChC = Invoke-SoftStep c @{ op = 'wait_for'; target = 'text:ch b after link ${RUN}'; timeout_ms = 90000 }
        if (-not $bChA.ok) { Add-Note "b's channel post did NOT reach a (its own sibling)" }
        if (-not $bChC.ok) { Add-Note "b's channel post did NOT reach c" }
        Set-Gate 'G7c b channel post reaches a (sibling) AND c' $(if ($bSent -and $bChA.ok -and $bChC.ok) { 'PASS' } else { 'FAIL' })

        # Now the DM half: all three on the DM surface before anything is sent.
        Open-Dm a 'probe-c'
        Open-Dm b 'probe-c'
        Open-Dm c 'probe-a'
        Send-Dm c 'dm c after link ${RUN}'
        $toA = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:dm c after link ${RUN}'; timeout_ms = 90000 }
        $toB = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:dm c after link ${RUN}'; timeout_ms = 90000 }
        if (-not $toA.ok) { Add-Note 'c DM after the link did NOT reach a' }
        if (-not $toB.ok) { Add-Note 'c DM after the link did NOT reach b (the new device)' }
        Set-Gate 'G7a c DM after the link reaches a AND b' $(if ($toA.ok -and $toB.ok) { 'PASS' } else { 'FAIL' })

        $bDm = $true
        try { Send-Dm b 'dm b after link ${RUN}' } catch { $bDm = $false; Add-Note "b could not send a DM: $($_.Exception.Message)" }
        $bDmC = Invoke-SoftStep c @{ op = 'wait_for'; target = 'text:dm b after link ${RUN}'; timeout_ms = 90000 }
        $bDmA = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:dm b after link ${RUN}'; timeout_ms = 90000 }
        if (-not $bDmC.ok) { Add-Note "b's DM did NOT reach c" }
        if (-not $bDmA.ok) { Add-Note "b's DM did NOT echo to a (its own sibling)" }
        Set-Gate 'G7d b DM to c reaches c AND a (sibling)' $(if ($bDm -and $bDmC.ok -and $bDmA.ok) { 'PASS' } else { 'FAIL' })

        Step a @{ op = 'dump'; name = 'g7_a' }
        Step b @{ op = 'dump'; name = 'g7_b' }
        Step c @{ op = 'dump'; name = 'g7_c' }
        foreach ($peer in $journeyPeers) { Step $peer @{ op = 'shot'; name = "link-$runTag-$peer-g7" } }

        # ---- G8: personal emotes converge between the two devices ---------
        Say '8/8 personal emotes: upload on one device, listed with its image on the other'
        [System.IO.File]::WriteAllBytes($emoteFixture, [Convert]::FromBase64String($emotePngBase64))
        foreach ($peer in @('a', 'b')) {
            Step $peer @{ op = 'open_server'; name = $server }
            Step $peer @{ op = 'open_channel'; name = 'general' }
        }

        $upA = Invoke-EmoteUpload a $emoteA
        Set-Gate 'G8a a uploads a personal emote and its Mine tab lists it' $(if ($upA) { 'PASS' } else { 'FAIL' })

        Open-MineTab b
        $seenB = Wait-MineEmote b $emoteA
        Set-Gate 'G8b b lists the emote and its image arrived' $(if ($seenB) { 'PASS' } else { 'FAIL' })
        Step b @{ op = 'shot'; name = "link-$runTag-b-g8-listed" }
        Close-Picker b

        # a's picker is still open on its Mine tab from the upload.
        $removedA = $false
        $rc = Invoke-SoftStep a @{ op = 'right_click'; target = "semantics:Emote $emoteA" }
        if ($rc.ok) {
            $item = Invoke-SoftStep a @{ op = 'wait_for'; target = 'text:Remove from my emotes'; timeout_ms = 5000 }
            if ($item.ok) {
                Invoke-SoftStep a @{ op = 'tap'; target = 'text:Remove from my emotes' } | Out-Null
                $removedA = (Invoke-SoftStep a @{ op = 'wait_for'; gone = "semantics:Emote $emoteA"; timeout_ms = 15000 }).ok
            }
        }
        if (-not $removedA) { Add-Note "a could not remove $emoteA from its own Mine tab" }
        Close-Picker a
        Open-MineTab b
        $goneB = Invoke-SoftStep b @{ op = 'wait_for'; gone = "semantics:Emote $emoteA"; timeout_ms = 60000 }
        if (-not $goneB.ok) { Add-Note "b still lists $emoteA after a removed it" }
        Set-Gate 'G8c a removes it and b stops listing it' $(if ($removedA -and $goneB.ok) { 'PASS' } else { 'FAIL' })
        Close-Picker b

        $upB = Invoke-EmoteUpload b $emoteB
        if (-not $upB) { Add-Note "b's own upload of $emoteB did not land" }
        Open-MineTab a
        $seenA = Wait-MineEmote a $emoteB
        Set-Gate 'G8d b uploads one and a lists it with its image' $(if ($upB -and $seenA) { 'PASS' } else { 'FAIL' })
        foreach ($peer in @('a', 'b')) { Step $peer @{ op = 'shot'; name = "link-$runTag-$peer-g8" } }
        Close-Picker a
        Close-Picker b

        # ---- G9: read state converges between the two devices (#80) -------
        # Every peer looks at a surface the message will NOT land on, so an
        # arrival has to show as a badge instead of being marked seen on the
        # spot. Badges are read from the provider, never from pixels.
        Say '9/9 read state: own posts never unread, reading on one device clears the other'
        foreach ($peer in @('a', 'b')) {
            Step $peer @{ op = 'open_server'; name = $server }
            Step $peer @{ op = 'open_channel'; name = 'general' }
        }
        Step a @{ op = 'dump'; name = 'g9_ids' }
        $serverRow = @((Get-DumpJson a 'g9_ids').providers.servers | Where-Object { $_.name -eq $server }) | Select-Object -First 1
        $generalRow = @((Get-DumpJson a 'g9_ids').providers.channels | Where-Object { $_.name -eq 'general' }) | Select-Object -First 1
        if (-not $serverRow -or -not $generalRow) { throw "could not resolve the ids of $server / #general from a's dump" }
        $chanKey = "$($serverRow.id):$($generalRow.id)"
        $isZero = { param($n) $n -eq 0 }
        $isSome = { param($n) $n -ge 1 }

        # G9a: b posts a DM while a sits in #general, then a channel message
        # while a sits in the DM. Neither may badge a: they are a's own posts.
        Open-Dm b 'probe-c'
        Send-Dm b 'dm b own ${RUN}'
        Step a @{ op = 'wait'; ms = 6000 }
        $ownDm = Wait-UnreadCount a 'dm' $masterC $isZero 1
        Step b @{ op = 'open_server'; name = $server }
        Step b @{ op = 'open_channel'; name = 'general' }
        Open-Dm a 'probe-c'
        Send-Channel b 'general' 'ch b own ${RUN}'
        Step a @{ op = 'wait'; ms = 6000 }
        $ownCh = Wait-UnreadCount a 'ch' $chanKey $isZero 1
        if ($ownDm -ne 0) { Add-Note "a badged its own DM (sent from b) with $ownDm unread" }
        if ($ownCh -ne 0) { Add-Note "a badged its own #general post (sent from b) with $ownCh unread" }
        Set-Gate 'G9a what b posts is never unread on a' $(if ($ownDm -eq 0 -and $ownCh -eq 0) { 'PASS' } else { 'FAIL' })

        # G9b: c DMs while both a and b sit in #general; both badge; a opens
        # the DM; b's badge has to clear without b touching anything.
        foreach ($peer in @('a', 'b')) {
            Step $peer @{ op = 'open_server'; name = $server }
            Step $peer @{ op = 'open_channel'; name = 'general' }
        }
        Open-Dm c 'probe-a'
        Send-Dm c 'dm c unread ${RUN}'
        $badgeA = Wait-UnreadCount a 'dm' $masterC $isSome 30
        $badgeB = Wait-UnreadCount b 'dm' $masterC $isSome 30
        if ($badgeA -lt 1) { Add-Note "a never badged c's DM (count $badgeA)" }
        if ($badgeB -lt 1) { Add-Note "b never badged c's DM (count $badgeB)" }
        Open-Dm a 'probe-c'
        Step a @{ op = 'wait_for'; target = 'text:dm c unread ${RUN}'; timeout_ms = 30000 }
        $clearedB = Wait-UnreadCount b 'dm' $masterC $isZero 45
        if ($clearedB -ne 0) { Add-Note "b still shows $clearedB unread for c after a read the DM" }
        Set-Gate 'G9b a reading the DM clears the badge on b' $(if ($badgeA -ge 1 -and $badgeB -ge 1 -and $clearedB -eq 0) { 'PASS' } else { 'FAIL' })

        # G9c: the channel twin. Both in the DM, c posts in #general, a opens it.
        Open-Dm a 'probe-c'
        Open-Dm b 'probe-c'
        Step c @{ op = 'open_server'; name = $server }
        Step c @{ op = 'open_channel'; name = 'general' }
        Send-Channel c 'general' 'ch c unread ${RUN}'
        $chBadgeA = Wait-UnreadCount a 'ch' $chanKey $isSome 30
        $chBadgeB = Wait-UnreadCount b 'ch' $chanKey $isSome 30
        if ($chBadgeA -lt 1) { Add-Note "a never badged c's #general post (count $chBadgeA)" }
        if ($chBadgeB -lt 1) { Add-Note "b never badged c's #general post (count $chBadgeB)" }
        Step a @{ op = 'open_server'; name = $server }
        Step a @{ op = 'open_channel'; name = 'general' }
        Step a @{ op = 'wait_for'; target = 'text:ch c unread ${RUN}'; timeout_ms = 30000 }
        $chClearedB = Wait-UnreadCount b 'ch' $chanKey $isZero 45
        if ($chClearedB -ne 0) { Add-Note "b still shows $chClearedB unread for #general after a read it" }
        Set-Gate 'G9c a reading #general clears the badge on b' $(if ($chBadgeA -ge 1 -and $chBadgeB -ge 1 -and $chClearedB -eq 0) { 'PASS' } else { 'FAIL' })
        foreach ($peer in @('a', 'b')) { Step $peer @{ op = 'shot'; name = "link-$runTag-$peer-g9-live" } }

        # G9d: b goes OFFLINE. c DMs, a reads it. b comes back: the message has
        # to be there (backfill) and already read (the marker snapshot), in
        # whichever order those two arrive.
        Backup-PeerArtifacts b 'g9-before-offline'
        Stop-Peer b
        Step a @{ op = 'open_server'; name = $server }
        Step a @{ op = 'open_channel'; name = 'general' }
        Open-Dm c 'probe-a'
        Send-Dm c 'dm c offline ${RUN}'
        $offBadgeA = Wait-UnreadCount a 'dm' $masterC $isSome 30
        if ($offBadgeA -lt 1) { Add-Note "a never badged c's DM while b was offline (count $offBadgeA)" }
        Open-Dm a 'probe-c'
        Step a @{ op = 'wait_for'; target = 'text:dm c offline ${RUN}'; timeout_ms = 30000 }
        Step a @{ op = 'wait'; ms = 2000 }
        Restart-Peer b
        Wait-ForConnected b
        $backBadgeB = Wait-UnreadCount b 'dm' $masterC $isZero 90
        Open-Dm b 'probe-c'
        $backfilled = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:dm c offline ${RUN}'; timeout_ms = 90000 }
        if (-not $backfilled.ok) { Add-Note "b never received c's offline-window DM after coming back" }
        if ($backBadgeB -ne 0) { Add-Note "b came back with $backBadgeB unread for c although a had read it" }
        Set-Gate 'G9d b, offline while a read, comes back with nothing unread' $(if ($offBadgeA -ge 1 -and $backfilled.ok -and $backBadgeB -eq 0) { 'PASS' } else { 'FAIL' })
        Step b @{ op = 'shot'; name = "link-$runTag-b-g9-back" }
    }
    Say 'the journey ran to the end' 'Green'
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
    if (-not $EdgeGates) { Say 'cleanup: nothing to delete (the server was never created)' 'Yellow' }
    Set-Gate $script:CleanupGate 'PASS'
} elseif ($serverDeleted) {
    Set-Gate $script:CleanupGate 'PASS'
} else {
    Say 'cleanup: deleting the server as its owner'
    try {
        if (-not (Get-PeerProcess 'a')) { Restart-Peer a }
        Wait-ForConnected a
        Close-Settings a
        Remove-Server a $server
        $serverDeleted = $true
        foreach ($peer in @('b', 'c')) {
            if (Get-PeerProcess $peer) {
                Invoke-SoftStep $peer @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 120000 } | Out-Null
            }
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
$title = if ($EdgeGates) { 'device link: refusal gates' } else { 'device link: the full journey' }
Write-Host "===== $title =====" -ForegroundColor Cyan
foreach ($key in @($script:Gates.Keys)) {
    $status = $script:Gates[$key]
    $colour = 'DarkGray'
    if ($status -eq 'PASS') { $colour = 'Green' }
    elseif ($status -eq 'FAIL') { $colour = 'Red' }
    elseif ($status -eq 'WARN') { $colour = 'Yellow' }
    Write-Host ("  {0,-4} {1}" -f $status, $key) -ForegroundColor $colour
}
Write-Host ''
Write-Host ("  run tag  : {0}   server: {1}" -f $runTag, $server) -ForegroundColor Gray
Write-Host ("  master a : {0}" -f $masterA) -ForegroundColor Gray
if (-not $EdgeGates) {
    Write-Host ("  master c : {0}" -f $masterC) -ForegroundColor Gray
    Write-Host ("  b after  : {0}" -f $script:FleetVars['PEER_B_AFTER']) -ForegroundColor Gray
    Write-Host ("  relaunch : {0}" -f $relaunchPath) -ForegroundColor Gray
}
foreach ($note in $script:Notes) { Write-Host ("  note     : {0}" -f $note) -ForegroundColor DarkCyan }

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

$failed = @($script:Gates.Values | Where-Object { $_ -eq 'FAIL' }).Count
if ($KeepUp -or $failed -gt 0) {
    Say "fleet left up ($failed gate(s) failed)" $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
} else {
    Invoke-FleetScript @('-Stop')
}
if ($failed -gt 0) { exit 1 }
Say 'PASS' 'Green'
