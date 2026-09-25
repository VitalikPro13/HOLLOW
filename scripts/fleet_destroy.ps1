# Identity destruction end to end, across FOUR real instances on the real relay:
# a master with two linked devices and a verified friend types DESTROY, and
# every one of them has to end up with nothing.
#
#   powershell -File scripts\fleet_destroy.ps1                 # fresh keys, builds first
#   powershell -File scripts\fleet_destroy.ps1 -SkipBuild      # you just built
#   powershell -File scripts\fleet_destroy.ps1 -KeepUp         # leave the windows open
#
# ## Why a script and not a scenario JSON
#
# Three of the four peers LEAVE and COME BACK: b and a destroy themselves and
# are relaunched by the Rust waiter, and d is closed at issue time so the relay
# has to park its order and hand it over at its next auth. A scenario file has
# no op for a peer that dies, which is the same reason fleet_device_link.ps1
# and fleet_pending_join.ps1 are scripts.
#
# ## The shape
#
#   G1  a and b are LINKED devices of ONE identity (the device-link journey's
#       own steps: b boots EMPTY, walks Welcome > Link a device, a confirms).
#   G2  c is a friend of that identity, DM both ways, and c has VERIFIED it.
#   G3  d is a THIRD linked device, and it is CLOSED before anything is issued.
#   G4  a types DESTROY with "Tell my friends" on. b wipes and exits; a wipes
#       last and exits. Neither data root holds an identity file or files/.
#   G5  c shows "This identity was destroyed", the verified mark is gone, and
#       c's own log carries the announce.
#   G6  d launches on its UNTOUCHED data dir, is handed the parked order at
#       auth, wipes and exits; a second launch lands on Welcome, root empty.
#   G7  a and b come back on their own to Welcome with empty roots.
#   C   cleanup: this journey creates no server, so there is nothing on the
#       relay to delete. It says so rather than reporting a pass it never made.
#
# ## What a probe instance does when the app relaunches itself
#
# `relaunchApp()` spawns the Rust waiter and calls exit(0), so a destroyed peer
# EXITS and a fresh copy takes its place seconds later. The exited process plus
# a wiped data root IS the proof; nothing here waits for a window. The live
# loop replays inbox.jsonl from line 0 on boot, so every peer that is about to
# die has its mailbox handed over (Reset-PeerMailbox) BEFORE the step that
# kills it, or the replacement re-runs the whole journey.
#
# Windows PowerShell 5.1 is what is installed here (`pwsh` is not), so no
# pwsh-only syntax: run it with `powershell -File`.

param(
    # Drive the identities that are already live instead of minting new ones.
    # Wrong for a first run: the relay replays buffered traffic for three days.
    [switch]$KeepIdentities,
    # Leave the instances running after a PASS. A FAILED run always leaves them
    # up, whatever this says.
    [switch]$KeepUp,
    # Skip the build+stage step. Pass it when you have just run
    # `powershell -File scripts\fleet.ps1 -Build -Peers a,b,c,d` yourself.
    [switch]$SkipBuild,
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag would run a journey nobody asked for
# and report a clean pass for it.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepIdentities, -KeepUp, -SkipBuild and -BootTimeoutSeconds."
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
$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
# a and c onboard; b and d must reach the WELCOME dialog, which only exists
# while there is no identity on disk, so they boot EMPTY.
$journeyPeers = @('a', 'b', 'c', 'd')
$fixturePeers = @('a', 'c')

if (Test-SimBackend) {
    throw 'this journey drives the DESKTOP Danger zone (Settings > Security); there is no iOS backend for it.'
}

function Say($message, $colour = 'Cyan') { Write-Host "[destroy] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates. Declared up front so the closing report has a line for every one of
# them, including the ones a failure meant we never reached.
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{
    'G1 a and b are LINKED devices of one identity'                  = 'SKIP'
    'G2 c is a friend of that identity and has VERIFIED it'          = 'SKIP'
    'G3 d is a THIRD linked device and is CLOSED'                    = 'SKIP'
    'G4a b wiped and exited on the order from a'                     = 'SKIP'
    'G4b a wiped and exited last, after publishing'                  = 'SKIP'
    'G5 c banners the destroyed identity and loses the verified mark' = 'SKIP'
    'G6a d took the parked order at its next auth and wiped'         = 'SKIP'
    'G6b d launched again lands on Welcome with an empty root'       = 'SKIP'
    'G7 a and b came back to Welcome with empty roots'               = 'SKIP'
    'C  cleanup: nothing of this journey is left on the relay'       = 'SKIP'
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
    # Deliberately no return value: these are called from helpers whose OWN
    # return value is read, and a stray answer on the output stream turns it
    # into an array.
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

# "This peer is up and on the network", without depending on which screen it
# booted into. The connection PROVIDER is the authority; "Connected" and
# "Online" are each printed by exactly one surface.
function Wait-ForConnected($peer, $timeoutSeconds = 150) {
    Step $peer @{
        op = 'wait_for'; provider = 'connection'; equals = 'connected'
        timeout_ms = $timeoutSeconds * 1000
    } | Out-Null
}

# --------------------------------------------------------------------------
# Processes and data roots
# --------------------------------------------------------------------------

function Get-PeerDataDir($peer) {
    if (Test-LinuxBackend) { return (Join-Path (Join-Path (Get-LinuxFleetHome) 'run') $peer) }
    return (Join-Path $runRoot $peer)
}

function Get-PeerPid($peer) {
    $proc = Get-PeerProcess $peer
    if ($proc) { return [int]$proc.Id }
    return 0
}

function Stop-Peer($peer) {
    $proc = Get-PeerProcess $peer
    if (-not $proc) { Say "$peer is already closed" 'Yellow'; return }
    $proc | Stop-Process -Force
    # The lock file and the SQLCipher WAL are released on exit; give the handles
    # time to drop before anything else touches that directory.
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - OFFLINE" 'Yellow'
}

function Start-PeerProcess($peer, $wipeData, $requireLive = $true) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Get-PeerDataDir $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if ($wipeData -and (Test-Path $data)) { Remove-Item $data -Recurse -Force }
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
        $launcher = Join-Path $out 'launch.sh'
        $lines = @(
            '#!/bin/sh',
            ('exec dbus-run-session -- "{0}" >"{1}" 2>"{2}" </dev/null' -f (Join-Path $dest 'hollow'),
                (Join-Path $out 'native-stdout.log'), (Join-Path $out 'native-stderr.log'))
        )
        [System.IO.File]::WriteAllText($launcher, (($lines -join "`n") + "`n"))
        & chmod +x $launcher | Out-Null
        $proc = Start-Process -FilePath $launcher -WorkingDirectory $dest -PassThru
    } else {
        $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') -WorkingDirectory $dest -PassThru
    }
    $what = if ($wipeData) { 'an EMPTY data dir' } else { 'its EXISTING data dir' }
    Say "launched $peer (pid $($proc.Id)) on $what"

    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { Say "$peer is live" 'Green'; return $proc.Id }
        if ($proc.HasExited) {
            # A peer launched to take a destruction order is SUPPOSED to die.
            if (-not $requireLive) { Say "$peer exited before it came live" 'Yellow'; return $proc.Id }
            throw "peer $peer died on launch.`n" + (Get-CrashTail $peer)
        }
        Start-Sleep -Milliseconds 300
    }
    if (-not $requireLive) { return $proc.Id }
    throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
}

# Relaunch ONE peer on its EXISTING data directory. `fleet.ps1 -Live` restores
# every fixture, which would throw away the very state this journey is about.
function Restart-Peer($peer, $requireLive = $true) {
    return Start-PeerProcess $peer $false $requireLive
}

# The same launch with the data directory EMPTIED first, the only way to reach
# the welcome dialog and therefore the enter-code screen.
function Start-EmptyPeer($peer) {
    $proc = Get-PeerProcess $peer
    if ($proc) { Stop-Peer $peer }
    return Start-PeerProcess $peer $true
}

# Hand the out directory over to a copy of the app that is about to replace
# this one: the live loop replays the INBOX from line 0 on boot, and
# `live-ready` is a file, so a stale one makes a dead peer look alive.
#
# Only ever call this on a peer that is ABOUT TO DIE. The live loop tracks its
# read position in memory, so truncating under a RUNNING instance leaves that
# position past the end of the file and the peer stops answering for good.
function Reset-PeerMailbox($peer) {
    $out = Join-Path $script:FleetOutRoot $peer
    [System.IO.File]::WriteAllText((Join-Path $out 'inbox.jsonl'), '',
        (New-Object System.Text.UTF8Encoding($false)))
    $marker = Join-Path $out 'live-ready'
    if (Test-Path $marker) { Remove-Item $marker -Force }
    $script:FleetConsumed[$peer] = 0
}

# Screenshots and dumps taken before a relaunch go with the out directory, so
# anything worth keeping is copied out first.
function Backup-PeerArtifacts($peer, $label) {
    $out = Join-Path $script:FleetOutRoot $peer
    $kept = Join-Path $script:FleetOutRoot "kept\destroy-$runTag-$peer-$label"
    if (-not (Test-Path $out)) { return }
    New-Item -ItemType Directory -Path $kept -Force | Out-Null
    Get-ChildItem $out -File -Include *.png, *.json, *.md, *.log, results.jsonl -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $kept -Force -ErrorAction SilentlyContinue }
    Say "kept $peer's artifacts in $kept" 'DarkGray'
}

# THIS pid is gone. Not "the peer is not running": the Rust waiter starts a
# replacement seconds later at the same path, so a peer that destroyed itself
# can look alive again before this is even asked.
function Wait-PidGone($thePid, $timeoutSeconds) {
    $started = Get-Date
    $deadline = $started.AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Id $thePid -ErrorAction SilentlyContinue
        if (-not $proc) { return [math]::Round(((Get-Date) - $started).TotalSeconds, 1) }
        Start-Sleep -Milliseconds 250
    }
    return -1
}

# A NEW process under build\fleet\<peer> that has written live-ready.
function Wait-PeerRelaunch($peer, $oldPid, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $now = Get-PeerProcess $peer
        if ($now -and $now.Id -ne $oldPid -and (Test-PeerLive $peer)) { return [int]$now.Id }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

# What is in a peer's data root right now, as a printable list.
function Get-RootInventory($peer) {
    $root = Get-PeerDataDir $peer
    if (-not (Test-Path $root)) { return @('(the data root does not exist)') }
    $items = @(Get-ChildItem $root -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            $count = @(Get-ChildItem $_.FullName -Force -Recurse -ErrorAction SilentlyContinue).Count
            "$($_.Name)/ ($count entries)"
        } else {
            "$($_.Name) ($($_.Length) bytes)"
        }
    })
    if ($items.Count -eq 0) { return @('(empty)') }
    return $items
}

# Everything the wipe promises is gone. `profiles.json`, `*.lock` and the
# `pending_wipe.marker` are deliberately absent from this list: the marker IS
# the promise that the next launch finishes the job.
#
# `messages.db` can outlive the wipe on Windows (an open handle refuses the
# unlink), so it is a remnant only once the app has launched again.
$script:KeyFiles = @('identity.key', 'identity.device', 'identity.duress', 'identity.dpapi')

# The wipe ZEROES a key file before it unlinks it, and on Windows the unlink of
# an open file is refused. A name left behind holding nothing but zeros is
# therefore the documented case, not a survivor: the key material is gone and
# the marker takes the name at the next launch. A name left behind holding
# BYTES is the real thing, and that is what the gates fail on.
function Test-FileIsZeroed($path) {
    try { $bytes = [System.IO.File]::ReadAllBytes($path) } catch { return $false }
    foreach ($b in $bytes) { if ($b -ne 0) { return $false } }
    return $true
}

# Key files the wipe zeroed but could not unlink, as printable evidence.
function Get-ZeroedKeyFiles($peer) {
    $root = Get-PeerDataDir $peer
    $zeroed = @()
    foreach ($name in $script:KeyFiles) {
        $path = Join-Path $root $name
        if ((Test-Path $path) -and (Test-FileIsZeroed $path)) {
            $zeroed += "$name ($((Get-Item $path).Length) zero bytes)"
        }
    }
    return $zeroed
}

# SHA-256 of every key file a peer holds right now, so "the wipe left the file
# behind" can be told apart from "something wrote a NEW one afterwards". The
# first is the destroyed key surviving on disk; the second is only untidy.
function Get-KeyFileHashes($peer) {
    $root = Get-PeerDataDir $peer
    $hashes = @{}
    foreach ($name in $script:KeyFiles) {
        $path = Join-Path $root $name
        if (-not (Test-Path $path)) { continue }
        try { $hashes[$name] = (Get-FileHash $path -Algorithm SHA256).Hash } catch { }
    }
    return $hashes
}

function Get-IdentityRemnants($peer, $afterRelaunch = $false) {
    $root = Get-PeerDataDir $peer
    $bad = @()
    foreach ($name in $script:KeyFiles) {
        $path = Join-Path $root $name
        # After a relaunch the marker has had its turn, so even a zeroed name is
        # a survivor.
        if (-not (Test-Path $path)) { continue }
        if ($afterRelaunch -or -not (Test-FileIsZeroed $path)) { $bad += $name }
    }
    $files = @('pending_link.hollow', 'pending_link.code')
    if ($afterRelaunch) { $files += @('messages.db', 'messages.db-wal', 'messages.db-shm') }
    foreach ($name in $files) {
        if (Test-Path (Join-Path $root $name)) { $bad += $name }
    }
    foreach ($dir in @('files', 'vault', 'vault_cache', 'shares', 'audio_cache')) {
        $path = Join-Path $root $dir
        if (Test-Path $path) { $bad += "$dir/" }
    }
    return $bad
}

function Write-Inventory($peer, $label) {
    Say "$peer data root ($label):" 'DarkGray'
    foreach ($line in (Get-RootInventory $peer)) {
        Write-Host "     $line" -ForegroundColor Gray
    }
}

# --------------------------------------------------------------------------
# Logs. hollow_debug.log sits next to the exe on Windows, survives the wipe and
# ACCUMULATES across runs, so it is emptied before the journey boots: after
# that every [HOLLOW-DESTROY] line in it belongs to this run.
# --------------------------------------------------------------------------
function Get-PeerLogPath($peer) {
    if (Test-LinuxBackend) { return (Join-Path (Get-PeerDataDir $peer) 'hollow_debug.log') }
    return (Join-Path $script:FleetStageRoot "$peer\hollow_debug.log")
}

function Clear-PeerLog($peer) {
    $path = Get-PeerLogPath $peer
    if (-not (Test-Path $path)) { return }
    try { Remove-Item $path -Force -ErrorAction Stop }
    catch { Add-Note "could not clear $peer's hollow_debug.log, so its lines may predate this run" }
}

function Get-PeerLogContains($peer, $needle) {
    $path = Get-PeerLogPath $peer
    if (-not (Test-Path $path)) { return @() }
    try {
        # .Contains, never -like: brackets in the pattern read as a character
        # class and match every line.
        return @(Get-Content $path -Encoding UTF8 -ErrorAction Stop |
            Where-Object { $_.Contains($needle) })
    } catch {
        Add-Note "could not read $peer's hollow_debug.log ($($_.Exception.Message))"
        return @()
    }
}

# A log line can trail its cause by a moment, and a fixed sleep long enough to
# cover that is long enough to hide a regression.
function Wait-ForPeerLog($peer, $needle, $timeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $hits = @(Get-PeerLogContains $peer $needle)
        if ($hits.Count -gt 0) { return $hits }
        if ((Get-Date) -ge $deadline) { return @() }
        Start-Sleep -Milliseconds 500
    }
}

# Lines a peer logged AFTER an anchor line, for a claim about what it did once
# something had already happened to it.
function Get-PeerLogAfter($peer, $anchor, $needle) {
    $path = Get-PeerLogPath $peer
    if (-not (Test-Path $path)) { return @() }
    $lines = @()
    try { $lines = @(Get-Content $path -Encoding UTF8 -ErrorAction Stop) } catch { return @() }
    $at = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Contains($anchor)) { $at = $i } }
    if ($at -lt 0) { return @() }
    $hits = @()
    for ($i = $at + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Contains($needle)) { $hits += $lines[$i] }
    }
    return $hits
}

function Write-LogHits($peer, $needle, $max = 4) {
    $hits = @(Get-PeerLogContains $peer $needle)
    foreach ($line in @($hits | Select-Object -Last $max)) {
        Write-Host "     [$peer] $line" -ForegroundColor Gray
    }
    return $hits
}

# --------------------------------------------------------------------------
# Reading a dump
# --------------------------------------------------------------------------
function Get-DumpJson($peer, $name) {
    $path = Join-Path $script:FleetOutRoot "$peer\map-$name.json"
    if (-not (Test-Path $path)) { throw "no dump for $peer at $path" }
    return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-DumpFriendRows($peer, $name) {
    $rows = (Get-DumpJson $peer $name).providers.friends
    if (-not $rows) { return @() }
    return @($rows)
}

function Format-FriendRows($rows) {
    $all = @(@($rows) | Where-Object { $_ })
    if ($all.Count -eq 0) { return '(none)' }
    return (@($all | ForEach-Object {
        $direction = ''
        if ($_.direction) { $direction = " ($($_.direction))" }
        "$($_.peerId) $($_.status)$direction"
    }) -join '; ')
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

# Never a bare Escape (focus has left the dialog by then) and never a bare
# semantics:Close, which matches the window title bar first and ends the
# process.
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
function Send-Dm($peer, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = 'hint:Type a message...' }
        Step $peer @{ op = 'enter_text'; target = 'hint:Type a message...'; value = $body }
        Step $peer @{ op = 'key'; value = 'enter' }
        $landed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }
        if ($landed.ok) { return }
        Add-Note "$peer's DM composer swallowed the send on attempt $attempt"
        Invoke-SoftStep $peer @{ op = 'shot'; name = "destroy-$runTag-$peer-dm-swallow-$attempt" } | Out-Null
    }
    throw "[$peer] the DM composer never produced a row for '$body' after 3 attempts"
}

function Test-SettingsOpen($peer) {
    $answer = Send-FleetStep $peer ([pscustomobject]@{
        op = 'wait_for'; target = 'type:_UserSettingsContent'; timeout_ms = 800
    }) 60
    return [bool]$answer.ok
}

# The settings dialog on one of its categories. The category tap is SCOPED to
# the dialog: the Home dashboard has rows of the same names behind it, they
# come first in tree order, and the dialog is sitting on top of them.
function Open-Settings($peer, $category) {
    if (-not (Test-SettingsOpen $peer)) {
        Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
        Step $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent'; timeout_ms = 20000 }
    }
    Step $peer @{ op = 'tap'; target = "type:_UserSettingsContent > text:$category"; index = 0 }
    Step $peer @{ op = 'wait'; ms = 800 }
}

function Close-Settings($peer) {
    if (-not (Test-SettingsOpen $peer)) { return }
    # Escape first: after a failed gate a sub-screen still covers the Close
    # button, and a tap that cannot reach it used to sink the cleanup.
    Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
    $gone = Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 3000 }
    if ($gone.ok) { return }
    Step $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 10000 }
}

function Open-SettingsDevices($peer) {
    Open-Settings $peer 'Devices'
    Step $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent > text:Link a device'; timeout_ms = 20000 }
}

# Opens "Link a device" on the populated side and reads the code off the screen.
#
# The dialog renders the code SPACED OUT and shows six dots until the notifier
# has minted one, so the capture is a regex for six spaced code characters and
# it is retried rather than failed.
function Get-LinkCode($peer) {
    # Each linked device adds a row above the button, so by the third link it
    # can be below the fold: the tap is what says it is reachable, not a
    # wait_for, which sees a built widget a click cannot get to.
    $opened = $false
    for ($i = 0; $i -lt 8 -and -not $opened; $i++) {
        $tap = Invoke-SoftStep $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > text:Link a device'; index = 0 }
        if ($tap.ok) {
            $shown = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'type:_DeviceLinkContent'; timeout_ms = 15000 }
            $opened = $shown.ok
        }
        if (-not $opened) {
            Invoke-SoftStep $peer @{ op = 'scroll'; target = 'type:_UserSettingsContent'; dy = -350 } | Out-Null
        }
    }
    if (-not $opened) { throw "[$peer] could not open the Link a device screen" }
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $answer = Invoke-SoftStep $peer @{
            op = 'capture'; target = 'type:_DeviceLinkContent'; as = 'LINKCODE_RAW'
            regex = '([A-Z2-9](?: [A-Z2-9]){5})'
        }
        if ($answer.ok) {
            $code = ($script:FleetVars['LINKCODE_RAW'] -replace '\s', '')
            if ($code.Length -eq 6) {
                Say "$peer is showing link code $code" 'Green'
                return $code
            }
        }
        Start-Sleep -Milliseconds 700
    }
    throw "[$peer] never rendered a 6-character link code"
}

# Walks the welcome dialog to the enter-code screen on an EMPTY peer.
function Open-EnterCode($peer) {
    Step $peer @{ op = 'wait_for'; target = 'text:Create New Identity'; timeout_ms = 90000 }
    Step $peer @{ op = 'tap'; target = 'text:Link a device'; index = 0 }
    # A throwaway identity is created and the node started before the dialog
    # appears, so this is the slow one.
    Step $peer @{ op = 'wait_for'; target = 'text:Link this device'; timeout_ms = 180000 }
    Step $peer @{ op = 'wait_for'; target = 'hint:ABC123'; timeout_ms = 20000 }
}

# The whole link leg for one empty peer, from a's code to the sibling coming
# back up. Returns the device id the new sibling authenticates as, which is
# what the relay's kill list is keyed by.
function Invoke-DeviceLink($peer, $masterA) {
    Close-Settings a
    Open-SettingsDevices a
    $code = Get-LinkCode a

    Start-EmptyPeer $peer | Out-Null
    Open-EnterCode $peer
    Wait-ForConnected $peer
    Step $peer @{ op = 'enter_text'; target = 'hint:ABC123'; value = $code }
    Step $peer @{ op = 'wait_for'; target = "text:$code"; timeout_ms = 15000 }
    Step $peer @{ op = 'tap'; target = 'text:Link'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 }

    Step a @{ op = 'wait_for'; target = 'text:Send your data?'; timeout_ms = 60000 }
    Step a @{ op = 'tap'; target = 'text:Send data'; index = 0 }
    Step a @{ op = 'wait_for'; target = 'text:Data sent'; timeout_ms = 180000 }
    Step $peer @{ op = 'wait_for'; target = 'text:Device linked'; timeout_ms = 120000 }
    Step $peer @{ op = 'shot'; name = "destroy-$runTag-$peer-linked" }

    # The receiver stashes the snapshot and schedules its own relaunch through
    # the Rust waiter. Nothing here can stop it, so the stash is read NOW and
    # the mailbox handed over before the replacement reads the inbox from 0.
    $data = Get-PeerDataDir $peer
    $blob = Join-Path $data 'pending_link.hollow'
    $blobSeen = $false
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path $blob) { $blobSeen = $true; break }
        Start-Sleep -Milliseconds 250
    }
    $oldPid = Get-PeerPid $peer
    Backup-PeerArtifacts $peer 'pre-relaunch'
    Reset-PeerMailbox $peer
    if ($blobSeen) {
        Say "$peer stashed pending_link.hollow" 'Green'
    } else {
        Add-Note "$peer's pending_link stash was never seen (it may have been imported before the first poll)"
    }

    # a's link dialog is a barrier over the settings dialog behind it.
    Step a @{ op = 'tap'; target = 'text:Done'; index = 0 }
    Step a @{ op = 'wait_for'; gone = 'type:_DeviceLinkContent'; timeout_ms = 15000 }
    Close-Settings a

    $newPid = Wait-PeerRelaunch $peer $oldPid 150
    if ($newPid -eq 0) {
        Add-Note "$peer did not come back on its own within 150s, so the script restarted it"
        Stop-Peer $peer
        Restart-Peer $peer | Out-Null
    } else {
        Say "$peer relaunched itself: pid $oldPid -> $newPid" 'Green'
    }

    Wait-ForConnected $peer
    Step $peer @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'LINKED_MASTER' }
    if ($script:FleetVars['LINKED_MASTER'] -ne $masterA) {
        throw "$peer's identity after the link is $($script:FleetVars['LINKED_MASTER']), a's master is $masterA"
    }
    Step $peer @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'LINKED_DEVICE' }
    $device = $script:FleetVars['LINKED_DEVICE']
    Say "$peer is now a device of $masterA (device $device)" 'Green'
    return $device
}

# Settings > Security is one long scroller and the Danger zone is its last
# card, so the button is BUILT long before a click can reach it: the tap is
# what tells us it is in view, not a wait_for.
function Open-DestroyDialog($peer) {
    for ($i = 0; $i -lt 14; $i++) {
        $tap = Invoke-SoftStep $peer @{ op = 'tap'; target = 'text:Destroy my identity everywhere'; index = 0 }
        if ($tap.ok) {
            $dialog = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'dialog > text:Destroy your data'; timeout_ms = 10000 }
            if ($dialog.ok) { return $true }
        }
        Invoke-SoftStep $peer @{ op = 'scroll'; target = 'type:_UserSettingsContent'; dy = -400 } | Out-Null
    }
    return $false
}

# --------------------------------------------------------------------------
# Boot
# --------------------------------------------------------------------------

if (-not $SkipBuild) {
    Say "building and staging $($journeyPeers -join ',') (pass -SkipBuild when you have just built)"
    Invoke-FleetScript @('-Build', '-Peers', ($journeyPeers -join ','))
}

# Emptied BEFORE anything launches: the log survives the wipe (it lives next to
# the exe on Windows) and accumulates across runs, so an earlier run's
# [HOLLOW-DESTROY] line would satisfy every assertion in this journey.
Invoke-FleetScript @('-Stop')
foreach ($peer in $journeyPeers) { Clear-PeerLog $peer }

if ($KeepIdentities) {
    Say 'keeping the identities that are already live (their relay rings are not empty)' 'Yellow'
    if ((Get-LivePeers).Count -eq 0) {
        Invoke-FleetScript @('-Live', '-Peers', ($fixturePeers -join ','))
        foreach ($peer in $fixturePeers) { $script:FleetConsumed[$peer] = 0 }
    }
} else {
    # Only a and c onboard. b and d must reach the WELCOME dialog, which only
    # exists while there is no identity on disk.
    Start-FreshFleet $fixturePeers
}

$live = Get-LivePeers
foreach ($peer in $fixturePeers) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running (live: $($live -join ', '))"
    }
}
Say "run tag $runTag"

$failure = $null
$masterA = ''
$masterC = ''
$deviceA = ''
$deviceB = ''
$deviceD = ''
$dKeysBefore = @{}

try {
    foreach ($peer in $fixturePeers) { Wait-ForConnected $peer }
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    $masterA = $script:FleetVars['PEER_A']
    if (-not $masterA) { throw "could not read a's master identity" }
    Step a @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'DEVICE_A' }
    $deviceA = $script:FleetVars['DEVICE_A']
    Step c @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_C' }
    $masterC = $script:FleetVars['PEER_C']
    if (-not $masterC) { throw "could not read c's master identity" }

    # ---- the friendship the announce will travel down ---------------------
    Say '1/7 a and c become friends and DM both ways'
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

    # ---- G1: b becomes a second device ------------------------------------
    Say '2/7 b boots EMPTY and is linked as a second device'
    $deviceB = Invoke-DeviceLink 'b' $masterA
    if (-not $deviceB) { throw 'b came back linked but never reported a device id' }
    if ($deviceB -eq $deviceA) { throw "b reports a's device id ($deviceA), so it is not a second device" }
    Close-Settings a
    Open-SettingsDevices a
    Step a @{ op = 'wait_for'; target = 'type:DeviceRowShell'; count = 2; timeout_ms = 90000 }
    Step a @{ op = 'shot'; name = "destroy-$runTag-a-two-devices" }
    Close-Settings a
    Set-Gate 'G1 a and b are LINKED devices of one identity' 'PASS'
    Say "PASS G1: a=$deviceA b=$deviceB on master $masterA" 'Green'

    # ---- G2: c verifies the contact ---------------------------------------
    Say '3/7 c verifies the contact'
    Open-Dm c 'probe-a'
    Step c @{ op = 'tap'; target = 'text:Verify contact'; index = 0 }
    Step c @{ op = 'wait_for'; target = 'dialog > text:Mark verified'; timeout_ms = 20000 }
    Step c @{ op = 'tap'; target = 'dialog > text:Mark verified'; index = 0 }
    Step c @{ op = 'wait_for'; target = 'dialog > contains:You verified'; timeout_ms = 20000 }
    Step c @{ op = 'shot'; name = "destroy-$runTag-c-verified" }
    Step c @{ op = 'tap'; target = 'dialog > semantics:Close'; index = 0 }
    Step c @{ op = 'wait_for'; gone = 'type:HollowDialog'; timeout_ms = 10000 }
    # The DM's own button is the standing mark, and it is what has to go away
    # when the identity behind it is destroyed.
    Step c @{ op = 'wait_for'; target = 'text:Verified: view number'; timeout_ms = 20000 }
    Step c @{ op = 'dump'; name = 'g2_c' }
    $cFriends = @(Get-DumpFriendRows c 'g2_c')
    Say "c's friends: $(Format-FriendRows $cFriends)" 'DarkCyan'
    $rowA = @(@($cFriends) | Where-Object { $_.peerId -eq $masterA }) | Select-Object -First 1
    if (-not $rowA -or $rowA.status -ne 'accepted') {
        throw "c does not hold an accepted friendship with $masterA. Rows: $(Format-FriendRows $cFriends)"
    }
    Set-Gate 'G2 c is a friend of that identity and has VERIFIED it' 'PASS'
    Say 'PASS G2: c is a verified friend' 'Green'

    # ---- G3: d becomes a third device, then leaves ------------------------
    Say '4/7 d boots EMPTY, is linked as a third device, then closes'
    $deviceD = Invoke-DeviceLink 'd' $masterA
    if (-not $deviceD) { throw 'd came back linked but never reported a device id' }
    if ($deviceD -eq $deviceA -or $deviceD -eq $deviceB) {
        throw "d reports a device id it shares with another peer ($deviceD)"
    }
    Close-Settings a
    Open-SettingsDevices a
    Step a @{ op = 'wait_for'; target = 'type:DeviceRowShell'; count = 3; timeout_ms = 90000 }
    Step a @{ op = 'shot'; name = "destroy-$runTag-a-three-devices" }
    Close-Settings a
    Step d @{ op = 'dump'; name = 'g3_d' }
    Backup-PeerArtifacts d 'g3-linked'
    Write-Inventory d 'linked, about to close'
    # The bytes of the keys that are about to be destroyed, so a file left
    # behind later can be identified rather than guessed at.
    $dKeysBefore = Get-KeyFileHashes 'd'
    Say ("d key files before the destroy: " + (($dKeysBefore.Keys | ForEach-Object { "$_=$($dKeysBefore[$_].Substring(0,12))" }) -join ', ')) 'DarkGray'
    Stop-Peer d
    Set-Gate 'G3 d is a THIRD linked device and is CLOSED' 'PASS'
    Say "PASS G3: d=$deviceD is linked and offline" 'Green'

    # ---- G4: the destruction ----------------------------------------------
    Say '5/7 a destroys the identity everywhere'
    # Everyone looks at the surface their evidence will land on first.
    Open-Dm c 'probe-a'
    # b's own surface is evidence, not a gate: what matters is that its process
    # goes and its root empties.
    try { Open-Dm b 'probe-c' } catch { Add-Note "b could not open a DM before the destroy: $($_.Exception.Message)" }
    Step b @{ op = 'dump'; name = 'g4_b_before' }
    Step b @{ op = 'shot'; name = "destroy-$runTag-b-before" }
    Write-Inventory a 'before the destroy'
    Write-Inventory b 'before the destroy'
    $bBefore = @(Get-IdentityRemnants 'b')
    if ($bBefore -notcontains 'identity.key') {
        throw "b's data root holds no identity.key before the destroy, so a wipe would prove nothing"
    }

    Close-Settings a
    Open-Settings a 'Security'
    if (-not (Open-DestroyDialog a)) {
        Invoke-SoftStep a @{ op = 'look' } | Out-Null
        throw 'a could not reach "Destroy my identity everywhere" in Settings > Security'
    }
    # The friend announcement is OFF by default, and it is the only thing that
    # makes G5 possible.
    Step a @{ op = 'tap'; target = 'dialog > type:HollowToggle'; index = 0 }
    Step a @{ op = 'wait'; ms = 600 }
    Step a @{ op = 'tap'; target = 'dialog > hint:DESTROY' }
    Step a @{ op = 'enter_text'; target = 'dialog > hint:DESTROY'; value = 'DESTROY' }
    Step a @{ op = 'wait_for'; target = 'dialog > text:DESTROY'; timeout_ms = 15000 }
    Step a @{ op = 'shot'; name = "destroy-$runTag-a-confirm" }
    Invoke-SoftStep a @{ op = 'look'; filter = 'Destroy' } | Out-Null
    Backup-PeerArtifacts a 'g4-confirm'
    Backup-PeerArtifacts b 'g4-before'

    $aPid = Get-PeerPid 'a'
    $bPid = Get-PeerPid 'b'
    if ($aPid -eq 0 -or $bPid -eq 0) { throw 'a or b is not running at the moment of the destroy' }
    # b dies on the ORDER, at a moment nothing here controls, so its mailbox is
    # handed over now: it is asked nothing else, and the copy that replaces it
    # would otherwise replay this whole journey from line 0.
    Reset-PeerMailbox b

    # a's goes AFTER its last command, never before. The live loop keeps its
    # read position IN MEMORY, so truncating the inbox under a running instance
    # leaves that position past the end of the file and the command written
    # next lands at an index it will never look at again.
    $t0 = Get-Date
    try {
        # A short wait on purpose: the answer is a bonus, and the mailbox has to
        # be emptied before the copy the waiter starts gets to read it.
        Send-FleetStep a ([pscustomobject]@{
            op = 'tap'; target = 'dialog > text:Destroy'; index = 0
        }) 20 | Out-Null
        Say 'a answered the Destroy tap before it went' 'DarkGray'
    } catch {
        # Normal: the process is usually gone before it can write its answer.
        Say "a did not answer the Destroy tap ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" 'DarkGray'
    } finally {
        Reset-PeerMailbox a
    }

    $bGone = Wait-PidGone $bPid 30
    $bInventory = @(Get-RootInventory 'b')
    $bRemnants = @(Get-IdentityRemnants 'b')
    $bZeroed = @(Get-ZeroedKeyFiles 'b')
    $bAccepted = @(Wait-ForPeerLog 'b' '[HOLLOW-DESTROY] Destruction order accepted for this device' 20)
    $bWiped = @(Get-PeerLogContains 'b' '[HOLLOW-DESTROY] Local data destroyed')
    Say "b data root (right after its process went):" 'DarkGray'
    foreach ($line in $bInventory) { Write-Host "     $line" -ForegroundColor Gray }
    Write-LogHits 'b' '[HOLLOW-DESTROY]' 6 | Out-Null
    if ($bGone -lt 0) { Add-Note "b's process was still alive 30s after the confirm" }
    if ($bZeroed.Count -gt 0) { Add-Note "b's wipe zeroed but could not unlink: $($bZeroed -join ', ')" }
    if ($bRemnants.Count -gt 0) { Add-Note "b's data root still holds: $($bRemnants -join ', ')" }
    if ($bAccepted.Count -eq 0) { Add-Note "b never logged that it accepted the order" }
    if ($bGone -ge 0 -and $bRemnants.Count -eq 0 -and $bAccepted.Count -ge 1 -and $bWiped.Count -ge 1) {
        Set-Gate 'G4a b wiped and exited on the order from a' 'PASS'
        Say "PASS G4a: b exited ${bGone}s after the confirm with an empty root" 'Green'
    } else {
        Set-Gate 'G4a b wiped and exited on the order from a' 'FAIL'
        Add-Note "G4a: gone=$bGone remnants=$($bRemnants.Count) accepted=$($bAccepted.Count) wiped=$($bWiped.Count)"
    }

    $aGone = Wait-PidGone $aPid 90
    $aInventory = @(Get-RootInventory 'a')
    $aRemnants = @(Get-IdentityRemnants 'a')
    $aZeroed = @(Get-ZeroedKeyFiles 'a')
    $aOrder = @(Get-PeerLogContains 'a' '[HOLLOW-DESTROY] Destruction order:')
    $aFriends = @(Get-PeerLogContains 'a' '[HOLLOW-DESTROY] Destruction announced to')
    $aWiped = @(Get-PeerLogContains 'a' '[HOLLOW-DESTROY] Local data destroyed')
    Say "a data root (right after its process went):" 'DarkGray'
    foreach ($line in $aInventory) { Write-Host "     $line" -ForegroundColor Gray }
    Write-LogHits 'a' '[HOLLOW-DESTROY]' 6 | Out-Null
    if ($aGone -lt 0) { Add-Note "a's process was still alive 90s after the confirm" }
    if ($aZeroed.Count -gt 0) { Add-Note "a's wipe zeroed but could not unlink: $($aZeroed -join ', ')" }
    if ($aRemnants.Count -gt 0) { Add-Note "a's data root still holds: $($aRemnants -join ', ')" }
    if ($aFriends.Count -eq 0) { Add-Note 'a never logged an announcement to its friends, so "Tell my friends" may not have been on' }
    if ($aGone -ge 0 -and $aRemnants.Count -eq 0 -and $aOrder.Count -ge 1 -and $aWiped.Count -ge 1) {
        Set-Gate 'G4b a wiped and exited last, after publishing' 'PASS'
        Say "PASS G4b: a exited ${aGone}s after the confirm with an empty root" 'Green'
    } else {
        Set-Gate 'G4b a wiped and exited last, after publishing' 'FAIL'
        Add-Note "G4b: gone=$aGone remnants=$($aRemnants.Count) order=$($aOrder.Count) wiped=$($aWiped.Count)"
    }

    # ---- G5: what the friend sees -----------------------------------------
    Say '6/7 c banners the destroyed identity'
    $banner = Invoke-SoftStep c @{ op = 'wait_for'; target = 'contains:This identity was destroyed'; timeout_ms = 120000 }
    $markGone = Invoke-SoftStep c @{ op = 'wait_for'; gone = 'text:Verified: view number'; timeout_ms = 60000 }
    $backToUnverified = Invoke-SoftStep c @{ op = 'wait_for'; target = 'text:Verify contact'; timeout_ms = 30000 }
    Step c @{ op = 'shot'; name = "destroy-$runTag-c-banner" }
    Step c @{ op = 'dump'; name = 'g5_c' }
    $cAnnounce = @(Get-PeerLogContains 'c' "[HOLLOW-DESTROY] Friend identity $masterA reported destroyed")
    Write-LogHits 'c' '[HOLLOW-DESTROY]' 4 | Out-Null
    if (-not $banner.ok) { Add-Note 'c never showed the destroyed banner in the DM' }
    if (-not $markGone.ok) { Add-Note "c still shows the verified mark for a" }
    if ($cAnnounce.Count -eq 0) { Add-Note 'c never logged the friend announce' }
    if ($banner.ok -and $markGone.ok -and $backToUnverified.ok -and $cAnnounce.Count -ge 1) {
        Set-Gate 'G5 c banners the destroyed identity and loses the verified mark' 'PASS'
        Say 'PASS G5: the friend was told, and the verification is gone' 'Green'
    } else {
        Set-Gate 'G5 c banners the destroyed identity and loses the verified mark' 'FAIL'
    }

    # ---- G6: the device that was away -------------------------------------
    Say '7/7 d comes back and takes the parked order'
    # No reset: d has to boot on the identity it went away with.
    $dPid = Restart-Peer 'd' $false
    $dParked = @(Wait-ForPeerLog 'd' '[HOLLOW-DESTROY] Relay parked order issued_at=' 120)
    $dAccepted = @(Wait-ForPeerLog 'd' '[HOLLOW-DESTROY] Destruction order accepted for this device' 60)
    $dGone = Wait-PidGone $dPid 90
    $dInventory = @(Get-RootInventory 'd')
    $dRemnants = @(Get-IdentityRemnants 'd')
    $dZeroed = @(Get-ZeroedKeyFiles 'd')
    $dKeysAfter = Get-KeyFileHashes 'd'
    $dSurvived = @()
    $dRewritten = @()
    foreach ($name in @($dKeysAfter.Keys)) {
        if ($dKeysBefore.ContainsKey($name) -and $dKeysBefore[$name] -eq $dKeysAfter[$name]) {
            $dSurvived += $name
        } else {
            $dRewritten += $name
        }
    }
    Say "d data root (right after its process went):" 'DarkGray'
    foreach ($line in $dInventory) { Write-Host "     $line" -ForegroundColor Gray }
    Write-LogHits 'd' '[HOLLOW-DESTROY]' 6 | Out-Null
    if ($dParked.Count -eq 0) { Add-Note 'd was never handed a parked order at auth' }
    if ($dAccepted.Count -eq 0) { Add-Note 'd never logged that it accepted the order' }
    if ($dGone -lt 0) { Add-Note "d's process was still alive 90s after it launched" }
    # destroy_local leaves the node RUNNING for the Dart side's last steps, and a
    # device that took the order while still booting keeps answering until it
    # exits a second or two later.
    $dServed = @(Get-PeerLogAfter 'd' '[HOLLOW-DESTROY] Local data destroyed' '[HOLLOW-SYNC] Sending')
    if ($dServed.Count -gt 0) {
        Add-Note "d answered $($dServed.Count) sync request(s) between the wipe and its exit"
    }
    if ($dZeroed.Count -gt 0) { Add-Note "d's wipe zeroed but could not unlink: $($dZeroed -join ', ')" }
    if ($dSurvived.Count -gt 0) {
        Add-Note "d STILL HOLDS THE DESTROYED KEY BYTES: $($dSurvived -join ', ') (same SHA-256 as before the order)"
    }
    if ($dRewritten.Count -gt 0) {
        Add-Note "d holds key files written AFTER the wipe, not the destroyed ones: $($dRewritten -join ', ')"
    }
    if ($dRemnants.Count -gt 0) { Add-Note "d's data root still holds: $($dRemnants -join ', ')" }
    $dOrderTaken = ($dParked.Count -ge 1 -and $dAccepted.Count -ge 1 -and $dGone -ge 0)
    # Only the DESTROYED bytes surviving is a failure of the feature. A name
    # rewritten after the wipe is untidy, and the marker takes it at the next
    # launch, which G6b is the gate for.
    $dOnlyRewritten = ($dSurvived.Count -eq 0 -and
        @($dRemnants | Where-Object { $script:KeyFiles -notcontains $_ }).Count -eq 0 -and
        $dRewritten.Count -gt 0)
    if ($dOrderTaken -and $dRemnants.Count -eq 0) {
        Set-Gate 'G6a d took the parked order at its next auth and wiped' 'PASS'
        Say "PASS G6a: d wiped ${dGone}s after launching" 'Green'
    } elseif ($dOrderTaken -and $dOnlyRewritten) {
        Set-Gate 'G6a d took the parked order at its next auth and wiped' 'WARN'
        Say 'WARN G6a: d wiped, then wrote a fresh identity file before it exited' 'Yellow'
    } else {
        Set-Gate 'G6a d took the parked order at its next auth and wiped' 'FAIL'
        Add-Note "G6a: parked=$($dParked.Count) accepted=$($dAccepted.Count) gone=$dGone remnants=$($dRemnants.Count) survived=$($dSurvived.Count)"
    }

    # The marker is a promise about the NEXT launch, so the next launch is the
    # gate: a welcome screen, and nothing of the identity left behind it.
    $dBackPid = Wait-PeerRelaunch 'd' $dPid 120
    if ($dBackPid -eq 0) {
        Add-Note 'd did not relaunch itself, so the script launched it for the second-launch gate'
        Restart-Peer 'd' $false | Out-Null
    } else {
        Say "d relaunched itself: pid $dPid -> $dBackPid" 'Green'
    }
    $dWelcome = Invoke-SoftStep d @{ op = 'wait_for'; target = 'text:Create New Identity'; timeout_ms = 120000 }
    Invoke-SoftStep d @{ op = 'shot'; name = "destroy-$runTag-d-welcome" } | Out-Null
    $dAfter = @(Get-IdentityRemnants 'd' $true)
    Write-Inventory d 'after the second launch'
    if (-not $dWelcome.ok) { Add-Note 'd did not land on the welcome screen' }
    if ($dAfter.Count -gt 0) { Add-Note "d's data root still holds: $($dAfter -join ', ')" }
    if ($dWelcome.ok -and $dAfter.Count -eq 0) {
        Set-Gate 'G6b d launched again lands on Welcome with an empty root' 'PASS'
    } else {
        Set-Gate 'G6b d launched again lands on Welcome with an empty root' 'FAIL'
    }

    # ---- G7: the two that destroyed themselves ----------------------------
    Say 'and the two that destroyed themselves come back to Welcome'
    $verdicts = @{}
    foreach ($pair in @(@('a', $aPid), @('b', $bPid))) {
        $peer = $pair[0]
        $backPid = Wait-PeerRelaunch $peer $pair[1] 150
        if ($backPid -eq 0) {
            Add-Note "$peer did not relaunch itself, so the script launched it"
            Restart-Peer $peer | Out-Null
        } else {
            Say "$peer relaunched itself: pid $($pair[1]) -> $backPid" 'Green'
        }
        $welcome = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'text:Create New Identity'; timeout_ms = 120000 }
        Invoke-SoftStep $peer @{ op = 'shot'; name = "destroy-$runTag-$peer-welcome" } | Out-Null
        $remnants = @(Get-IdentityRemnants $peer $true)
        Write-Inventory $peer 'after coming back'
        if (-not $welcome.ok) { Add-Note "$peer did not land on the welcome screen" }
        if ($remnants.Count -gt 0) { Add-Note "$peer's data root still holds: $($remnants -join ', ')" }
        $verdicts[$peer] = ($welcome.ok -and $remnants.Count -eq 0)
    }
    if ($verdicts['a'] -and $verdicts['b']) {
        Set-Gate 'G7 a and b came back to Welcome with empty roots' 'PASS'
        Say 'PASS G7: nothing of the identity survived on either device' 'Green'
    } else {
        Set-Gate 'G7 a and b came back to Welcome with empty roots' 'FAIL'
    }

    Say 'the journey ran to the end' 'Green'
} catch {
    $failure = $_
    $where = Set-FirstUnreachedGateFailed
    Say "FAILED at [$where]: $($_.Exception.Message)" 'Red'
}

# --------------------------------------------------------------------------
# Cleanup. This journey creates no server, so the rule it has to satisfy is
# "create nothing you cannot delete": the only thing it puts on the relay is a
# friendship between two throwaway identities, one of which no longer exists.
# --------------------------------------------------------------------------
$leftovers = @()
foreach ($peer in $journeyPeers) {
    $remnants = @(Get-IdentityRemnants $peer $true)
    if ($remnants.Count -gt 0 -and @('a', 'b', 'd') -contains $peer) {
        $leftovers += "$peer : $($remnants -join ', ')"
    }
}
if ($leftovers.Count -eq 0) {
    Set-Gate 'C  cleanup: nothing of this journey is left on the relay' 'PASS'
    Add-Note 'no server was ever created; the destroyed identity is gone from all three of its devices'
} else {
    Set-Gate 'C  cleanup: nothing of this journey is left on the relay' 'FAIL'
    foreach ($line in $leftovers) { Add-Note "left behind: $line" }
}

# --------------------------------------------------------------------------
# The report
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '===== identity destruction: the full journey =====' -ForegroundColor Cyan
foreach ($key in @($script:Gates.Keys)) {
    $status = $script:Gates[$key]
    $colour = 'DarkGray'
    if ($status -eq 'PASS') { $colour = 'Green' }
    elseif ($status -eq 'FAIL') { $colour = 'Red' }
    elseif ($status -eq 'WARN') { $colour = 'Yellow' }
    Write-Host ("  {0,-4} {1}" -f $status, $key) -ForegroundColor $colour
}
Write-Host ''
Write-Host ("  run tag  : {0}" -f $runTag) -ForegroundColor Gray
Write-Host ("  master a : {0}" -f $masterA) -ForegroundColor Gray
Write-Host ("  master c : {0}" -f $masterC) -ForegroundColor Gray
Write-Host ("  devices  : a={0} b={1} d={2}" -f $deviceA, $deviceB, $deviceD) -ForegroundColor Gray
foreach ($note in $script:Notes) { Write-Host ("  note     : {0}" -f $note) -ForegroundColor DarkCyan }

if ($failure) {
    Write-Host ''
    Say 'the fleet is left UP for diagnosis. Logs:' 'Yellow'
    foreach ($peer in $journeyPeers) {
        Write-Host ("    $peer  " + (Join-Path $script:FleetOutRoot "$peer\stdout.log")) -ForegroundColor DarkGray
        Write-Host ("       " + (Join-Path $script:FleetOutRoot "$peer\errors.log")) -ForegroundColor DarkGray
        Write-Host ("       " + (Get-PeerLogPath $peer)) -ForegroundColor DarkGray
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
