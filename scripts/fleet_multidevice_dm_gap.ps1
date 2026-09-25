# Issue #90 on real instances: a DM thread with a friend must be whole on BOTH
# of a user's devices, whichever device was offline when a message was sent.
#
#   powershell -File scripts\fleet_multidevice_dm_gap.ps1              # fresh keys, builds first
#   powershell -File scripts\fleet_multidevice_dm_gap.ps1 -SkipBuild   # you just built
#   powershell -File scripts\fleet_multidevice_dm_gap.ps1 -KeepUp      # leave the windows open
#
# a and b are TWO devices of one identity (b is linked from a exactly the way
# fleet_device_link.ps1 does it), c is the friend ("user B" in the issue).
#
#   L   a and c are friends with DM history, b is linked as a's second device.
#   H1  both siblings online: a's DM reaches c AND b, c's reply reaches a AND b.
#   H2  the issue verbatim: b offline, a sends X, c replies Y, b returns while a
#       is online and must show X then Y.
#   H3  peer fallback: b offline for X2/Y2, then a goes offline BEFORE b returns,
#       so only c can serve X2. Then a returns and must still hold everything.
#   H4  the reverse: a offline while b sends X3 and c replies Y3; a returns.
#   H5  restart churn: a and b restarted in alternation, every message still on
#       both, and the per-thread count equals the number sent (no duplicates).
#
# Every H gate after H1 has a device offline while its sibling sends, so it
# rides the relay-buffered sibling copy and the BACKFILL paths behind it: the
# sibling `DmSiblingSyncRequest` and the friend `DmSyncRequest
# { both_directions }`. The gaps here are seconds long; gaps longer than the
# 30-minute sync lookback are covered by the Rust harness.
#
# Every gate is judged on the SCREEN (the text is built in the open thread) and
# on the chat PROVIDER (the dump's per-thread count and last bodies, which is
# what the pane renders from), and each gate's slice of every peer's
# hollow_debug.log is kept under build\fleet_out\kept\dm_gap_<run>\.
#
# Windows only: the stop/relaunch helpers are the desktop ones from
# fleet_device_link.ps1. Windows PowerShell 5.1, so no pwsh-only syntax.

param(
    # Leave the instances running after a PASS. A FAILED gate always leaves
    # them up, whatever this says.
    [switch]$KeepUp,
    # Skip the build+stage step. Pass it when you have just run
    # `powershell -File scripts\fleet.ps1 -Build -Peers a,b,c` yourself.
    [switch]$SkipBuild,
    # How long a returning device gets to backfill a message it missed.
    [int]$SyncWaitSeconds = 90,
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag would run a journey nobody asked for.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepUp, -SkipBuild, -SyncWaitSeconds and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in every message: the relay holds undelivered traffic for three
# days, so a fixed string can be matched by an EARLIER run.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

if (-not (Test-WindowsBackend)) { throw 'fleet_multidevice_dm_gap.ps1 drives the Windows backend only' }

$runTag = $script:FleetVars.RUN
$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$evidenceRoot = Join-Path $script:FleetOutRoot "kept\dm_gap_$runTag"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$startedAt = Get-Date

function Say($message, $colour = 'Cyan') { Write-Host "[dm-gap] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates, declared up front so the report has a line for every one of them.
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{}
$script:Gates['L   a+c friends with DM history, b linked as a second device']       = 'SKIP'
$script:Gates['H1a both online: a DM reaches c AND sibling b']                     = 'SKIP'
$script:Gates['H1b both online: c reply reaches a AND b']                          = 'SKIP'
$script:Gates['H2  b offline for X+Y, returns with a online: X then Y on b']       = 'SKIP'
$script:Gates['H3a b offline for X2+Y2, returns with a OFFLINE: c serves both']    = 'SKIP'
$script:Gates['H3b a returns after H3 and still holds everything']                 = 'SKIP'
$script:Gates['H4  a offline while b sends X3 and c replies Y3: a gets both']      = 'SKIP'
$script:Gates['H5  restart churn: whole thread on a and b, no duplicates']         = 'SKIP'
$script:Notes = New-Object System.Collections.ArrayList
$script:GateDetail = [ordered]@{}

function Set-Gate($name, $status, $detail = '') {
    if (-not $script:Gates.Contains($name)) { throw "unknown gate '$name'" }
    $script:Gates[$name] = $status
    if ($detail) { $script:GateDetail[$name] = $detail }
    $colour = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Say "$status $name $detail" $colour
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

function Wait-ForConnected($peer, $timeoutSeconds = 150) {
    Step $peer @{
        op = 'wait_for'; provider = 'connection'; equals = 'connected'
        timeout_ms = $timeoutSeconds * 1000
    } | Out-Null
}

function Get-PeerDataDir($peer) { return (Join-Path $runRoot $peer) }

function Stop-Peer($peer) {
    $proc = Get-PeerProcess $peer
    if (-not $proc) { Say "$peer is already closed" 'Yellow'; return }
    # By the process object (its pid), never by image name: the user's own
    # Hollow may be running.
    $proc | Stop-Process -Force
    # The SQLCipher WAL and the lock file are released on exit.
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - OFFLINE" 'Yellow'
}

# A launch recreates the out directory, so dumps and shots from before it are
# copied out first.
function Backup-PeerArtifacts($peer, $label) {
    $out = Join-Path $script:FleetOutRoot $peer
    $kept = Join-Path $evidenceRoot "$peer-$label"
    if (-not (Test-Path $out)) { return }
    New-Item -ItemType Directory -Path $kept -Force | Out-Null
    Get-ChildItem $out -File -Include *.png, *.json, *.md, *.log, results.jsonl -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $kept -Force -ErrorAction SilentlyContinue }
}

function Start-PeerProcess($peer, $wipeData) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Get-PeerDataDir $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    $script:FleetConsumed[$peer] = 0

    $env:HOLLOW_DATA_DIR = $data
    $env:UI_PROBE_OUT = $out
    $env:UI_PROBE_MODE = 'live'
    $env:UI_PROBE_PEER = $peer
    $env:UI_PROBE_IDLE_MINUTES = '40'
    $env:UI_PROBE_SCENARIO_FILE = ''
    $env:UI_PROBE_STEPS = ''
    # No -RedirectStandardOutput/-RedirectStandardError, ever: they flip
    # Start-Process into inherit-handles mode and the script never returns.
    $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') -WorkingDirectory $dest -PassThru
    $what = if ($wipeData) { 'an EMPTY data dir' } else { 'its EXISTING data dir' }
    Say "launched $peer (pid $($proc.Id)) on $what"

    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { Say "$peer is live" 'Green'; return }
        if ($proc.HasExited) { throw "peer $peer died on launch.`n" + (Get-CrashTail $peer) }
        Start-Sleep -Milliseconds 300
    }
    throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
}

function Restart-Peer($peer, $label) {
    Backup-PeerArtifacts $peer "before-$label"
    Start-PeerProcess $peer $false
}

function Start-EmptyPeer($peer) {
    Stop-Peer $peer
    $data = Get-PeerDataDir $peer
    if (Test-Path $data) { Remove-Item $data -Recurse -Force }
    Start-PeerProcess $peer $true
}

# Only ever on a peer that is ABOUT TO DIE (see fleet_device_link.ps1): the
# live loop replays the inbox from line 0 on boot, and truncating it under a
# running instance wedges that instance for good.
function Reset-PeerMailbox($peer) {
    $out = Join-Path $script:FleetOutRoot $peer
    [System.IO.File]::WriteAllText((Join-Path $out 'inbox.jsonl'), '',
        (New-Object System.Text.UTF8Encoding($false)))
    $marker = Join-Path $out 'live-ready'
    if (Test-Path $marker) { Remove-Item $marker -Force }
    $script:FleetConsumed[$peer] = 0
}

# --------------------------------------------------------------------------
# The logs. hollow_debug.log sits next to the exe, survives relaunches and
# accumulates across runs, so a gate reads only the lines written after its
# own mark. Shared read: the app holds the file open for writing.
# --------------------------------------------------------------------------
function Read-PeerLog($peer) {
    $path = Join-Path $script:FleetStageRoot "$peer\hollow_debug.log"
    if (-not (Test-Path $path)) { return @() }
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    return ,($text -split "`r?`n")
}

$script:LogMarks = @{}
function Set-LogMarks {
    foreach ($peer in @('a', 'b', 'c')) { $script:LogMarks[$peer] = (Read-PeerLog $peer).Count }
}

# The sync story of one gate, as the three logs tell it.
$script:EvidencePatterns = @(
    '[HOLLOW-SYNC]', 'DmSiblingSyncRequest', 'Dropped', 'REJECTED', 'Sibling DM sync',
    'DM sync', '[HOLLOW-SIBLING]', '[HOLLOW-MULTIDEV]', 'MessageSendFailed', 'no session'
)
# The lines worth printing in the console; the rest go to the evidence file.
$script:HeadlinePatterns = @(
    'Requesting sibling DM backfill', 'DmSiblingSyncRequest from', 'Sending ', 'Received ',
    'DmSyncRequest from', 'Post-rekey DM resync', 'Dropped', 'REJECTED', 'Verified sibling',
    'Sibling device', 'MessageSendFailed'
)

function Format-LogLine($line) {
    if ($line -match '^\[(\d{9,})\]\s*(.*)$') {
        $when = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Matches[1]).ToLocalTime().ToString('HH:mm:ss')
        return "$when $($Matches[2])"
    }
    return $line
}

function Save-GateEvidence($gate) {
    $headline = @()
    foreach ($peer in @('a', 'b', 'c')) {
        $all = Read-PeerLog $peer
        $from = [int]$script:LogMarks[$peer]
        if ($all.Count -lt $from) {
            Add-Note "$peer's hollow_debug.log shrank during $gate (rotated?), reading it from the top"
            $from = 0
        }
        $slice = @()
        if ($all.Count -gt $from) { $slice = @($all[$from..($all.Count - 1)]) }
        $hits = @($slice | Where-Object {
            $line = $_
            @($script:EvidencePatterns | Where-Object { $line.Contains($_) }).Count -gt 0
        } | ForEach-Object { Format-LogLine $_ })
        $file = Join-Path $evidenceRoot "$gate-$peer.log"
        [System.IO.File]::WriteAllLines($file, [string[]]$hits, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($hit in $hits) {
            if ($hit.Contains('dm item mid=')) { continue }
            if (@($script:HeadlinePatterns | Where-Object { $hit.Contains($_) }).Count -gt 0) {
                $headline += "[$peer] $hit"
            }
        }
    }
    if ($headline.Count -gt 0) {
        Say "$gate log headlines:" 'DarkCyan'
        foreach ($h in $headline | Select-Object -First 60) { Write-Host "    $h" -ForegroundColor DarkGray }
    } else {
        Say "${gate}: no sync lines in any log" 'Yellow'
    }
    Set-LogMarks
}

# --------------------------------------------------------------------------
# Reading a thread. The screen answers "is it rendered", the dump's chat
# provider answers "how many rows and in which order", which is what catches a
# duplicate or a reorder.
# --------------------------------------------------------------------------
function Get-DumpJson($peer, $name) {
    $path = Join-Path $script:FleetOutRoot "$peer\map-$name.json"
    if (-not (Test-Path $path)) { throw "no dump for $peer at $path" }
    return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-Thread($peer, $name, $convo) {
    $map = (Get-DumpJson $peer $name).providers.dms
    if (-not $map) { return [pscustomobject]@{ count = 0; last = @() } }
    $entry = $map.PSObject.Properties[$convo]
    if (-not $entry) { return [pscustomobject]@{ count = 0; last = @() } }
    return [pscustomobject]@{ count = [int]$entry.Value.count; last = @($entry.Value.last) }
}

function Open-Dm($peer, $friendName) {
    Step $peer @{ op = 'wait_for'; target = "semantics:$friendName"; timeout_ms = 60000 }
    Step $peer @{ op = 'tap'; target = "semantics:$friendName" }
    Step $peer @{ op = 'wait'; ms = 1500 }
    Step $peer @{ op = 'wait_for'; target = 'hint:Type a message...'; timeout_ms = 30000 }
}

# The composer is TAPPED first (enter_text on an unfocused field reports
# success into nothing), and every send waits for its OWN row, so a swallowed
# send is never mistaken for a delivery failure on the other side.
function Send-Dm($peer, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = 'hint:Type a message...' }
        Step $peer @{ op = 'enter_text'; target = 'hint:Type a message...'; value = $body }
        Step $peer @{ op = 'key'; value = 'enter' }
        $landed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }
        if ($landed.ok) { [void]$script:Thread.Add((Expand-FleetVars $body)); return }
        Add-Note "$peer's DM composer swallowed the send on attempt $attempt"
        Invoke-SoftStep $peer @{ op = 'shot'; name = "gap-$runTag-$peer-swallow-$attempt" } | Out-Null
    }
    throw "[$peer] the DM composer never produced a row for '$body' after 3 attempts"
}

# Every body in $bodies is on $peer's screen in the open thread with
# $friendName, then the provider's count and order are read. The first body
# gets the full sync budget and the rest $restWaitMs each.
function Test-Thread($peer, $friendName, $convo, $bodies, $label, $firstWaitSeconds, $restWaitMs = 15000) {
    Open-Dm $peer $friendName
    $missing = @()
    $dups = @()
    $first = $true
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($body in $bodies) {
        $ms = if ($first) { $firstWaitSeconds * 1000 } else { $restWaitMs }
        $seen = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = $ms }
        if (-not $seen.ok) { $missing += $body } elseif ((Get-MatchCount $seen) -gt 1) { $dups += $body }
        $first = $false
    }
    $seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
    # A reversed list builds only the rows near the newest, and the fleet window
    # is short, so older rows have to be wheeled into existence before a missing
    # one means anything. Wheel UP (negative) is toward older on this list.
    if ($missing.Count -gt 0) {
        for ($i = 0; $i -lt 8 -and $missing.Count -gt 0; $i++) {
            Invoke-SoftStep $peer @{ op = 'wheel'; target = 'type:ScrollablePositionedList'; dy = -400 } | Out-Null
            $still = @()
            foreach ($body in $missing) {
                $seen = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 1500 }
                if (-not $seen.ok) { $still += $body } elseif ((Get-MatchCount $seen) -gt 1) { $dups += $body }
            }
            $missing = $still
        }
        # Back to the newest: a scrolled-up list freezes its display, and every
        # later wait_for on an arriving message would read as a delivery failure.
        Invoke-SoftStep $peer @{ op = 'wheel'; target = 'type:ScrollablePositionedList'; dy = 8000 } | Out-Null
    }
    $dumpName = "$label-$peer"
    Step $peer @{ op = 'dump'; name = $dumpName }
    Invoke-SoftStep $peer @{ op = 'shot'; name = "gap-$runTag-$dumpName" } | Out-Null
    $thread = Get-Thread $peer $dumpName $convo
    Copy-Item (Join-Path $script:FleetOutRoot "$peer\map-$dumpName.json") $evidenceRoot -Force -ErrorAction SilentlyContinue
    $result = [pscustomobject]@{
        peer = $peer; missing = $missing; dups = $dups; count = $thread.count; last = $thread.last
        seconds = $seconds
    }
    $lastText = ($thread.last -join ' | ')
    if ($dups.Count -gt 0) { Add-Note "[$peer] $label drew these rows MORE than once: $($dups -join ' ; ')" }
    if ($missing.Count -gt 0) {
        Say "[$peer] $label MISSING on screen: $($missing -join ' ; ') (provider count $($thread.count), last: $lastText)" 'Red'
    } else {
        Say "[$peer] $label all $($bodies.Count) on screen, first pass ${seconds}s (provider count $($thread.count), last: $lastText)" 'Green'
    }
    return $result
}

# How many widgets a passing wait_for matched ("... (3 polls, 2 matches)").
function Get-MatchCount($answer) {
    if ("$($answer.message)" -match '(\d+) match') { return [int]$Matches[1] }
    return 1
}

# The whole thread newest first, for a check that the history survived: the
# newest rows are the built ones, so the misses left for the wheel are only the
# rows genuinely scrolled out of view.
function Test-WholeThread($peer, $friendName, $convo, $label, $firstWaitSeconds) {
    $newestFirst = @($script:Thread)
    [array]::Reverse($newestFirst)
    return Test-Thread $peer $friendName $convo $newestFirst $label $firstWaitSeconds 2500
}

# X before Y in the provider's tail, which is the order the pane draws.
function Test-Order($result, $x, $y) {
    $ix = [array]::IndexOf([string[]]$result.last, $x)
    $iy = [array]::IndexOf([string[]]$result.last, $y)
    return ($ix -ge 0 -and $iy -ge 0 -and $ix -lt $iy)
}

# --------------------------------------------------------------------------
# The surfaces of the link journey (fleet_device_link.ps1, desktop half)
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

# Never a bare semantics:Close: it matches the window title bar first and that
# tap ends the process.
function Close-Friends($peer) {
    if (-not (Test-FriendsManagerOpen $peer)) { return }
    Step $peer @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
}

function Open-SettingsDevices($peer) {
    Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent'; timeout_ms = 20000 }
    Step $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > text:Devices'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent > text:Link a device'; timeout_ms = 20000 }
}

function Close-Settings($peer) {
    $open = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent'; timeout_ms = 1500 }
    if (-not $open.ok) { return }
    Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
    $gone = Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 3000 }
    if ($gone.ok) { return }
    Step $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 10000 }
}

# The dialog renders the code spaced out and six dots until it is minted, so
# the capture is a regex, retried.
function Get-LinkCode($peer) {
    Step $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > text:Link a device'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_DeviceLinkContent'; timeout_ms = 20000 }
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $answer = Invoke-SoftStep $peer @{
            op = 'capture'; target = 'type:_DeviceLinkContent'; as = 'LINKCODE_RAW'
            regex = '([A-Z2-9](?: [A-Z2-9]){5})'
        }
        if ($answer.ok) {
            $code = ($script:FleetVars['LINKCODE_RAW'] -replace '\s', '')
            if ($code.Length -eq 6) { return $code }
        }
        Start-Sleep -Milliseconds 700
    }
    throw "[$peer] never rendered a 6-character link code"
}

# --------------------------------------------------------------------------
# Boot
# --------------------------------------------------------------------------

if (-not $SkipBuild) {
    Say 'building and staging a,b,c (pass -SkipBuild when you have just built)'
    Invoke-FleetScript @('-Build', '-Peers', 'a,b,c')
}

# b must reach the WELCOME dialog (the only way to the enter-code screen), so
# only a and c onboard.
Start-FreshFleet @('a', 'c')
Say "run tag $runTag"

$failure = $null
$masterA = ''
$masterC = ''
$deviceA = ''
$deviceB = ''
# Every body in the a<->c thread, in send order.
$script:Thread = New-Object System.Collections.ArrayList

try {
    foreach ($peer in @('a', 'c')) { Wait-ForConnected $peer }
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    Step c @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_C' }
    $masterA = $script:FleetVars['PEER_A']
    $masterC = $script:FleetVars['PEER_C']
    if (-not $masterA -or -not $masterC) { throw 'could not read the master identities' }

    # ---- L: friends, history, and the link ---------------------------------
    Say 'L: a and c become friends and DM both ways, then b is linked from a'
    Open-Friends a
    Step a @{ op = 'tap'; target = 'type:HollowChip>text:Add friend'; index = 0 }
    Step a @{ op = 'enter_text'; target = 'hint:Paste an ID, or type a nickname'; value = '${PEER_C}' }
    Step a @{ op = 'wait_for'; target = 'text:${PEER_C}'; timeout_ms = 15000 }
    Step a @{ op = 'tap'; target = 'text:Send request'; index = 0 }
    Open-Friends c
    Step c @{ op = 'tap'; target = 'type:HollowChip>text:Requests'; index = 0 }
    Step c @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 90000 }
    Step c @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }
    Step a @{ op = 'wait_for'; target = 'text:probe-c'; timeout_ms = 90000 }
    Step c @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 90000 }
    Close-Friends a
    Close-Friends c

    Open-Dm a 'probe-c'
    Send-Dm a 'seed a to c ${RUN}'
    Step c @{ op = 'wait_for'; target = 'text:seed a to c ${RUN}'; timeout_ms = 90000 }
    Open-Dm c 'probe-a'
    Send-Dm c 'seed c to a ${RUN}'
    Step a @{ op = 'wait_for'; target = 'text:seed c to a ${RUN}'; timeout_ms = 90000 }

    Open-SettingsDevices a
    $code = Get-LinkCode a
    Say "a is showing link code $code" 'Green'

    Start-EmptyPeer b
    Step b @{ op = 'wait_for'; target = 'text:Create New Identity'; timeout_ms = 90000 }
    Step b @{ op = 'tap'; target = 'text:Link a device'; index = 0 }
    Step b @{ op = 'wait_for'; target = 'text:Link this device'; timeout_ms = 180000 }
    Step b @{ op = 'wait_for'; target = 'hint:ABC123'; timeout_ms = 20000 }
    Wait-ForConnected b
    Step b @{ op = 'enter_text'; target = 'hint:ABC123'; value = $code }
    Step b @{ op = 'wait_for'; target = "text:$code"; timeout_ms = 15000 }
    Step b @{ op = 'tap'; target = 'text:Link'; index = 0 }
    Step b @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 }
    Step a @{ op = 'wait_for'; target = 'text:Send your data?'; timeout_ms = 60000 }
    Step a @{ op = 'tap'; target = 'text:Send data'; index = 0 }
    Step a @{ op = 'wait_for'; target = 'text:Data sent'; timeout_ms = 180000 }
    Step b @{ op = 'wait_for'; target = 'text:Device linked'; timeout_ms = 120000 }

    # b relaunches ITSELF 1.5 s after the done view (Rust waiter), so the
    # mailbox is handed over now, before the replacement reads it from line 0.
    $bProc = Get-PeerProcess b
    $oldPid = if ($bProc) { $bProc.Id } else { 0 }
    Reset-PeerMailbox b
    Step a @{ op = 'tap'; target = 'text:Done'; index = 0 }
    Step a @{ op = 'wait_for'; gone = 'type:_DeviceLinkContent'; timeout_ms = 15000 }
    Close-Settings a
    $deadline = (Get-Date).AddSeconds(120)
    $newPid = 0
    while ((Get-Date) -lt $deadline) {
        $now = Get-PeerProcess b
        if ($now -and $now.Id -ne $oldPid -and (Test-PeerLive b)) { $newPid = $now.Id; break }
        Start-Sleep -Milliseconds 400
    }
    if ($newPid -gt 0) {
        Say "b relaunched itself: pid $oldPid -> $newPid" 'Green'
    } else {
        Add-Note 'b did not come back on its own within 120s, so the script restarted it'
        Stop-Peer b
        Start-PeerProcess b $false
    }
    Wait-ForConnected b
    Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B_AFTER' }
    if ($script:FleetVars['PEER_B_AFTER'] -ne $masterA) {
        throw "b's identity after the link is $($script:FleetVars['PEER_B_AFTER']), a's master is $masterA"
    }
    Step a @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'DEV_A' }
    Step b @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'DEV_B' }
    $deviceA = $script:FleetVars['DEV_A']
    $deviceB = $script:FleetVars['DEV_B']
    Set-LogMarks
    $linked = Test-Thread b 'probe-c' $masterC @($script:Thread) 'L' 60
    Save-GateEvidence 'L'
    if ($linked.missing.Count -gt 0) { throw "b did not inherit the DM history: $($linked.missing -join ' ; ')" }
    Set-Gate 'L   a+c friends with DM history, b linked as a second device' 'PASS' "(device a $deviceA, device b $deviceB)"

    # ---- H1: both siblings online ------------------------------------------
    Say 'H1: both devices online, live fan-out'
    Set-LogMarks
    Open-Dm a 'probe-c'
    Open-Dm b 'probe-c'
    Open-Dm c 'probe-a'
    $h1a = 'h1 a to c ${RUN}'
    Send-Dm a $h1a
    $toC = Invoke-SoftStep c @{ op = 'wait_for'; target = "text:$h1a"; timeout_ms = 60000 }
    $toB = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$h1a"; timeout_ms = 60000 }
    Set-Gate 'H1a both online: a DM reaches c AND sibling b' $(if ($toC.ok -and $toB.ok) { 'PASS' } else { 'FAIL' }) "(c=$($toC.ok) b=$($toB.ok))"
    $h1b = 'h1 c to a ${RUN}'
    Send-Dm c $h1b
    $toA = Invoke-SoftStep a @{ op = 'wait_for'; target = "text:$h1b"; timeout_ms = 60000 }
    $toB2 = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$h1b"; timeout_ms = 60000 }
    Set-Gate 'H1b both online: c reply reaches a AND b' $(if ($toA.ok -and $toB2.ok) { 'PASS' } else { 'FAIL' }) "(a=$($toA.ok) b=$($toB2.ok))"
    Save-GateEvidence 'H1'

    # ---- H2: the issue verbatim --------------------------------------------
    Say 'H2: b offline, a sends X, c replies Y, b returns while a is online'
    Set-LogMarks
    Stop-Peer b
    $x = 'h2 X a to c ${RUN}'
    $y = 'h2 Y c to a ${RUN}'
    Send-Dm a $x
    Step c @{ op = 'wait_for'; target = "text:$x"; timeout_ms = 60000 }
    Send-Dm c $y
    Step a @{ op = 'wait_for'; target = "text:$y"; timeout_ms = 60000 }
    Restart-Peer b 'h2'
    Wait-ForConnected b
    $h2 = Test-Thread b 'probe-c' $masterC @((Expand-FleetVars $x), (Expand-FleetVars $y)) 'H2' $SyncWaitSeconds
    $ordered = Test-Order $h2 (Expand-FleetVars $x) (Expand-FleetVars $y)
    Save-GateEvidence 'H2'
    $h2ok = ($h2.missing.Count -eq 0) -and ($h2.dups.Count -eq 0) -and $ordered -and ($h2.count -eq $script:Thread.Count)
    Set-Gate 'H2  b offline for X+Y, returns with a online: X then Y on b' $(if ($h2ok) { 'PASS' } else { 'FAIL' }) `
        "(missing=$($h2.missing.Count) ordered=$ordered count=$($h2.count)/$($script:Thread.Count))"

    # ---- H3: only the friend can serve it ------------------------------------
    Say 'H3: b offline for X2+Y2, a goes offline too, b returns alone with c'
    Set-LogMarks
    Stop-Peer b
    $x2 = 'h3 X2 a to c ${RUN}'
    $y2 = 'h3 Y2 c to a ${RUN}'
    Open-Dm a 'probe-c'
    Send-Dm a $x2
    Step c @{ op = 'wait_for'; target = "text:$x2"; timeout_ms = 60000 }
    Send-Dm c $y2
    Step a @{ op = 'wait_for'; target = "text:$y2"; timeout_ms = 60000 }
    Stop-Peer a
    Restart-Peer b 'h3'
    Wait-ForConnected b
    $h3 = Test-Thread b 'probe-c' $masterC @((Expand-FleetVars $x2), (Expand-FleetVars $y2)) 'H3a' $SyncWaitSeconds
    $ordered3 = Test-Order $h3 (Expand-FleetVars $x2) (Expand-FleetVars $y2)
    Save-GateEvidence 'H3a'
    $h3ok = ($h3.missing.Count -eq 0) -and ($h3.dups.Count -eq 0) -and $ordered3 -and ($h3.count -eq $script:Thread.Count)
    Set-Gate 'H3a b offline for X2+Y2, returns with a OFFLINE: c serves both' $(if ($h3ok) { 'PASS' } else { 'FAIL' }) `
        "(missing=$($h3.missing.Count) ordered=$ordered3 count=$($h3.count)/$($script:Thread.Count))"

    Restart-Peer a 'h3b'
    Wait-ForConnected a
    $h3b = Test-WholeThread a 'probe-c' $masterC 'H3b' 30
    Save-GateEvidence 'H3b'
    $h3bok = ($h3b.missing.Count -eq 0) -and ($h3b.dups.Count -eq 0) -and ($h3b.count -eq $script:Thread.Count)
    Set-Gate 'H3b a returns after H3 and still holds everything' $(if ($h3bok) { 'PASS' } else { 'FAIL' }) `
        "(missing=$($h3b.missing.Count) count=$($h3b.count)/$($script:Thread.Count))"

    # ---- H4: the reverse direction -----------------------------------------
    Say 'H4: a offline, b sends X3, c replies Y3, a returns'
    Set-LogMarks
    Stop-Peer a
    $x3 = 'h4 X3 b to c ${RUN}'
    $y3 = 'h4 Y3 c to a ${RUN}'
    Open-Dm b 'probe-c'
    Send-Dm b $x3
    Open-Dm c 'probe-a'
    Step c @{ op = 'wait_for'; target = "text:$x3"; timeout_ms = 60000 }
    Send-Dm c $y3
    Step b @{ op = 'wait_for'; target = "text:$y3"; timeout_ms = 60000 }
    Restart-Peer a 'h4'
    Wait-ForConnected a
    $h4 = Test-Thread a 'probe-c' $masterC @((Expand-FleetVars $x3), (Expand-FleetVars $y3)) 'H4' $SyncWaitSeconds
    $ordered4 = Test-Order $h4 (Expand-FleetVars $x3) (Expand-FleetVars $y3)
    Save-GateEvidence 'H4'
    $h4ok = ($h4.missing.Count -eq 0) -and ($h4.dups.Count -eq 0) -and $ordered4 -and ($h4.count -eq $script:Thread.Count)
    Set-Gate 'H4  a offline while b sends X3 and c replies Y3: a gets both' $(if ($h4ok) { 'PASS' } else { 'FAIL' }) `
        "(missing=$($h4.missing.Count) ordered=$ordered4 count=$($h4.count)/$($script:Thread.Count))"

    # ---- H5: restart churn -------------------------------------------------
    Say 'H5: a and b restarted in alternation, twice each'
    Set-LogMarks
    $churn = @()
    foreach ($round in 1..2) {
        foreach ($peer in @('a', 'b')) {
            Stop-Peer $peer
            Start-Sleep -Seconds 3
            Restart-Peer $peer "h5-$round"
            Wait-ForConnected $peer
            # Give the reconnect's key exchange and both backfill passes time to
            # land any duplicate before counting.
            Start-Sleep -Seconds 15
            foreach ($check in @('a', 'b')) {
                $r = Test-WholeThread $check 'probe-c' $masterC "H5r$round$peer" 20
                $churn += $r
                if ($r.count -ne $script:Thread.Count) {
                    Add-Note "H5 round $round after restarting $peer`: $check's thread holds $($r.count) rows, $($script:Thread.Count) were sent"
                }
            }
        }
    }
    $cView = Test-WholeThread c 'probe-a' $masterA 'H5c' 20
    Save-GateEvidence 'H5'
    $bad = @($churn | Where-Object { $_.missing.Count -gt 0 -or $_.dups.Count -gt 0 -or $_.count -ne $script:Thread.Count })
    $cOk = ($cView.missing.Count -eq 0) -and ($cView.dups.Count -eq 0) -and ($cView.count -eq $script:Thread.Count)
    Set-Gate 'H5  restart churn: whole thread on a and b, no duplicates' $(if ($bad.Count -eq 0 -and $cOk) { 'PASS' } else { 'FAIL' }) `
        "($($bad.Count) bad check(s) of $($churn.Count); c holds $($cView.count)/$($script:Thread.Count))"

    Say 'the journey ran to the end' 'Green'
} catch {
    $failure = $_
    $where = Set-FirstUnreachedGateFailed
    Say "FAILED at [$where]: $($_.Exception.Message)" 'Red'
    try { Save-GateEvidence 'abort' } catch { }
}

# --------------------------------------------------------------------------
# The report
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '===== issue #90: multi-device DM gap =====' -ForegroundColor Cyan
foreach ($key in @($script:Gates.Keys)) {
    $status = $script:Gates[$key]
    $colour = 'DarkGray'
    if ($status -eq 'PASS') { $colour = 'Green' } elseif ($status -eq 'FAIL') { $colour = 'Red' }
    $detail = if ($script:GateDetail.Contains($key)) { " $($script:GateDetail[$key])" } else { '' }
    Write-Host ("  {0,-4} {1}{2}" -f $status, $key, $detail) -ForegroundColor $colour
}
Write-Host ''
Write-Host ("  run tag  : {0}   took {1:mm\:ss}" -f $runTag, ((Get-Date) - $startedAt)) -ForegroundColor Gray
Write-Host ("  master a : {0} (devices a={1} b={2})" -f $masterA, $deviceA, $deviceB) -ForegroundColor Gray
Write-Host ("  master c : {0}" -f $masterC) -ForegroundColor Gray
Write-Host ("  thread   : {0} message(s)" -f $script:Thread.Count) -ForegroundColor Gray
Write-Host ("  evidence : {0}" -f $evidenceRoot) -ForegroundColor Gray
foreach ($note in $script:Notes) { Write-Host ("  note     : {0}" -f $note) -ForegroundColor DarkCyan }

$failed = @($script:Gates.Values | Where-Object { $_ -eq 'FAIL' }).Count
if ($failure -or $failed -gt 0) {
    $pids = @('a', 'b', 'c') | ForEach-Object {
        $p = Get-PeerProcess $_
        if ($p) { "$_=$($p.Id)" } else { "$_=down" }
    }
    Say "fleet left up for diagnosis ($($pids -join ' ')); stop it with: powershell -File scripts\fleet.ps1 -Stop" 'Yellow'
    if ($failure) { throw $failure }
    exit 1
}
if ($KeepUp) {
    Say 'fleet left up' 'Green'
} else {
    Invoke-FleetScript @('-Stop')
}
Say 'PASS' 'Green'
