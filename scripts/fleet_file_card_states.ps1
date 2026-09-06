# The honest file-card states, driven across two REAL Hollow instances.
#
#   powershell -File scripts\fleet_file_card_states.ps1                  # fresh keys, builds first
#   powershell -File scripts\fleet_file_card_states.ps1 -SkipBuild       # you just built
#   powershell -File scripts\fleet_file_card_states.ps1 -KeepIdentities  # drive the live fleet
#   powershell -File scripts\fleet_file_card_states.ps1 -KeepUp          # leave the instances up
#   powershell -File scripts\fleet_file_card_states.ps1 -KeepServer      # debugging only
#
# ## What this is
#
# tmp.txt item 1: a file card whose bytes are not on disk shows a Download
# button that can silently do nothing. The card has to SAY why. Four states,
# and this journey drives three of them end to end:
#
#   1  a holder is reachable                  -> Download (today's button)
#   2  nobody who has it is reachable         -> DM:      "<name> is offline.
#                                                          Hollow will fetch it
#                                                          when they return."
#                                                 channel: "Waiting for a peer
#                                                          who has this file"
#   3  a holder answered "I don't have it"    -> "<name> no longer has this file"
#   4  expired by the retention policy        -> "Removed by this server's
#                                                 retention policy"
#
#   G1 a and b become friends and DM both ways. Baseline, and it is what gives
#      every later card a display NAME to print instead of a peer id.
#   G2 state 2 in a DM. b is closed, a attaches a file, a closes. b comes back
#      ALONE and the card names the offline sender. a comes back and the bytes
#      arrive with NO further action on b: the queued ask retried itself.
#   G2b the hover bar mirrors the card. The queued ask can be DROPPED by hand
#      (the bar's Download becomes a stop action) and REBUILT by hand, so what
#      G2 then watches self-heal is a re-queued ask, not the original one.
#   G3 state 3 in a DM. a attaches a second file and its OWN copy is deleted
#      from disk while it is closed, so when it returns it is a holder that no
#      longer holds. b's card has to read "no longer has this file" instead of
#      waiting forever on a peer that is right there.
#   G4 state 2 in a channel. Same round trip in #general, where the wording is
#      the channel one and the candidate pool is the server room.
#   C  cleanup: the owner deletes the server, whatever happened.
#
# ## What it proves that the Rust harness cannot
#
# The harness (`node/test_harness.rs`) proves the ASK WALK converges: candidate
# order, the asked-set rule, the negative answer, the local retention check. It
# runs every node in one process against a mock relay, and three things in this
# journey live outside that process:
#
#   * the real relay. A file posted to an absent peer rides the availability
#     rings, and the card's state is only honest if the header arrived without
#     the bytes. The harness has no ring.
#   * the real widgets. "Waiting for a peer" is a STRING on a card that also
#     has to lose its Download button, keep its caption row, and then clear
#     itself when the bytes land. Nothing in Rust can see any of that.
#   * the real boot-time sweep. G3 deletes a's copy from disk while a is CLOSED,
#     so `reset_stale_files` clears the row's disk path on a's next start. That
#     is a full process restart on an existing data directory, which is exactly
#     what a harness node never does.
#
# Plus the auto-download gate, which lives in DART: with the default threshold
# (169 MB) the chat-open sweep already asks for a 600 KB file, so the honest
# state can be on the card BEFORE anything is tapped. Every download step below
# therefore waits for the Download control OR the caption, taps only the
# control, and asserts the caption either way.
#
# ## Why state 4 is not here
#
# It cannot be driven by a fleet run. The retention sweep ticks every 30
# minutes and the smallest retention window a server can set is measured in
# days, so nothing a two-minute journey does can produce an `expired_at`. It is
# covered where it can be: the harness test
# `expired_answer_is_verified_locally_before_marking_our_row` (a member cannot
# expire someone else's file by lying) and the widget test in
# `test/file_card_states_test.dart` (the caption and the control for a row that
# already carries `expiredAt`).
#
# ## Why a script and not a scenario JSON
#
# The journey is a peer leaving and coming back, four times. A scenario file has
# no op for that. Same shape as fleet_pending_join.ps1, fleet_owner_offline.ps1
# and fleet_channel_file_catchup.ps1, whose Restart-Peer / Stop-Peer / gates /
# evidence / cleanup this copies.
#
# ## The files
#
# Three ~600 KB `.bin` files of random bytes, written by this script. NON-image
# on purpose: an image would take the inline-bytes path, get a thumbnail and a
# placeholder card, and the surface under test is the GENERIC file card. `.bin`
# stages with no dialog and no conversion - `_handleDroppedFile` (chat_pane.dart
# ~883, channel_chat_pane.dart) only prompts above the 34 MB share threshold,
# and `_stagedFileIsImage` is a fixed extension list that `.bin` is not on, so
# the send path skips the WebP conversion entirely and the bytes cross the wire
# unchanged.
#
# A received file is stored as `{file_id}.{ext}` (`file_transfer.rs`
# `final_file_path`), NOT under the name the card shows, so a copy on disk is
# identified by its CONTENT (length, then SHA-256) rather than by its name.
#
# Windows PowerShell 5.1 is what is installed here: no pwsh-only syntax, and
# `pwsh` is not a thing on this machine - run it with `powershell -File`.

param(
    # Drive the identities that are already live instead of minting new ones.
    # Faster, and wrong for a first run: the relay replays buffered traffic for
    # three days, so a reused identity can be served an EARLIER run's message.
    [switch]$KeepIdentities,
    # Leave the instances running after a PASS. A FAILED run always leaves them
    # up, whatever this says.
    [switch]$KeepUp,
    # Skip the build+stage step.
    [switch]$SkipBuild,
    # Leave the server behind. For debugging only: the fleet talks to servers it
    # creates AND deletes, because these are real identities on the real relay.
    [switch]$KeepServer,
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag runs a journey nobody asked for and
# reports a clean pass for it.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepIdentities, -KeepUp, -SkipBuild, -KeepServer and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in the server name, every message and every file name: the relay
# holds undelivered traffic for three days, so a fixed string can be matched by
# an EARLIER run and pass before the send it was waiting for.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runTag = $script:FleetVars.RUN
$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$server = "fcs-$runTag"
$journeyPeers = @('a', 'b')

# Non-image, distinct sizes so a log line naming a size names the file too.
$nameOne = "file-$runTag-1.bin"
$nameTwo = "file-$runTag-2.bin"
$nameThree = "file-$runTag-3.bin"
$fileOne = Join-Path $script:FleetStageRoot $nameOne
$fileTwo = Join-Path $script:FleetStageRoot $nameTwo
$fileThree = Join-Path $script:FleetStageRoot $nameThree

# THE CONTRACT. These are the exact strings the cards must show; they are waited
# on verbatim, never as substrings. `probe-a` is the fixture display name that
# `-Onboard` stamps, and the DM wording prints the MASTER's display name.
$dmOfflineCaption = 'probe-a is offline. Hollow will fetch it when they return.'
$dmGoneCaption = 'probe-a no longer has this file'
$chanWaitCaption = 'Waiting for a peer who has this file'

function Say($message, $colour = 'Cyan') { Write-Host "[file-card-states] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{
    'G1 a and b are friends and DM both ways'                     = 'SKIP'
    'G2 DM state 2: the offline sender is named, bytes follow'    = 'SKIP'
    'G2b DM state 2: stop waiting returns the card to Download, asking again re-queues' = 'SKIP'
    'G3 DM state 3: the sender says it no longer has the file'    = 'SKIP'
    'G4 channel state 2: waiting for a peer, then bytes follow'   = 'SKIP'
    'C  cleanup: no fleet server left on the relay'               = 'SKIP'
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
    $what = @($step.target, $step.gone, $step.name, $step.value, $step.path) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

function Invoke-SoftStep($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value, $step.path) | Where-Object { $_ } | Select-Object -First 1
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

function Restart-Peer($peer) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Join-Path $runRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    # A relaunch wipes the probe's output directory, and this journey relaunches
    # five times - so without this the only screenshots that survive a run are
    # the last leg's, and the gates that FAILED are usually the earlier ones.
    $kept = Join-Path $script:FleetOutRoot "kept\$peer"
    if (Test-Path $out) {
        New-Item -ItemType Directory -Path $kept -Force | Out-Null
        Get-ChildItem $out -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'fcs-*' -or $_.Name -like 'map-*' } |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $kept $_.Name) -Force -ErrorAction SilentlyContinue }
        Remove-Item $out -Recurse -Force
    }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
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
    # POLLED, not a flat sleep: a Flutter instance mid-frame with a SQLCipher
    # WAL checkpoint in flight can take several seconds to actually go, and a
    # fixed 1500ms failed a whole run on that alone in another journey.
    $deadline = (Get-Date).AddSeconds(30)
    while (Get-PeerProcess $peer) {
        if ((Get-Date) -ge $deadline) { throw "peer $peer did not stop within 30s" }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 1500
    Say "$peer is closed - OFFLINE" 'Yellow'
}

# --------------------------------------------------------------------------
# The disk behind the card
# --------------------------------------------------------------------------

function Get-PeerFilesDir($peer) {
    return (Join-Path (Join-Path $runRoot $peer) 'files')
}

# Files land as `{file_id}.{ext}` (file_transfer.rs `final_file_path`), so the
# name on disk is NOT the name on the card and a stem match would find nothing.
# Identity is the CONTENT: length first (cheap), then SHA-256 (exact). That also
# rules out the sender's `.stream_send_*.tmp` ciphertext copies, which are the
# right size and the wrong bytes.
function Find-PeerFile($peer, $sourcePath) {
    $dir = Get-PeerFilesDir $peer
    if (-not (Test-Path $dir)) { return $null }
    if (-not (Test-Path $sourcePath)) { throw "the source file $sourcePath is gone, so nothing can be matched against it" }
    $want = Get-Item $sourcePath
    $wantHash = (Get-FileHash -Path $sourcePath -Algorithm SHA256).Hash
    foreach ($candidate in @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($candidate.Length -ne $want.Length) { continue }
        try { $hash = (Get-FileHash -Path $candidate.FullName -Algorithm SHA256).Hash } catch { continue }
        if ($hash -eq $wantHash) { return $candidate }
    }
    return $null
}

function Wait-ForPeerFile($peer, $sourcePath, $label, $timeoutSeconds) {
    Write-Host ("  [{0}] waiting for {1} on disk (up to {2}s)" -f $peer, $label, $timeoutSeconds) -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $hit = Find-PeerFile $peer $sourcePath
        if ($hit) {
            Write-Host "     ok   $($hit.FullName) ($($hit.Length) bytes)" -ForegroundColor DarkGray
            return $hit
        }
        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Seconds 3
    }
}

# One `channel_rows` reading of the open channel, as an array of lines. Channel
# only: the op reads selectedServerProvider / selectedChannelProvider, and there
# is no DM equivalent - which is why the DM gates read the disk instead.
function Get-ChannelRows($peer) {
    $answer = Send-FleetStep $peer ([pscustomobject]@{ op = 'channel_rows'; limit = 30 }) 180
    if (-not $answer.ok) { throw "[$peer] channel_rows FAILED: $($answer.message)" }
    return @($answer.message -split "`n")
}

function Write-ChannelRows($peer, $label) {
    $lines = Get-ChannelRows $peer
    Write-Host "  [$peer] $label" -ForegroundColor DarkCyan
    foreach ($line in $lines) { Write-Host "     $line" -ForegroundColor Gray }
    return $lines
}

function Get-PeerLogLines($peer, $pattern) {
    $path = Join-Path $script:FleetStageRoot "$peer\hollow_debug.log"
    if (-not (Test-Path $path)) { return @() }
    try {
        return @(Get-Content $path -ErrorAction Stop | Where-Object { $_ -like "*$pattern*" })
    } catch {
        Add-Note "could not read $peer's hollow_debug.log ($($_.Exception.Message))"
        return @()
    }
}

# Everything worth reading when a gate fails, from BOTH instances. The asker's
# log is where the walk either rotated or gave up; the holder's is where the
# negative answer either went out or did not.
function Write-Evidence($label) {
    Say "evidence for $label" 'Yellow'
    foreach ($peer in $journeyPeers) {
        foreach ($pattern in @(
            '[HOLLOW-FILE]',
            'file_unavail',
            'FileAvailability',
            'Requesting file',
            'No online device',
            '[HOLLOW-TOPIC] Catch-up request',
            '[HOLLOW-TOPIC] Registering relay catch-up',
            '[HOLLOW-TOPIC] Subscribe room=',
            '[HOLLOW-TOPIC] Broadcast room=',
            '[HOLLOW-TOPIC] RECV MlsChannelMessage',
            '[HOLLOW-TOPIC] DECRYPT ok',
            '[HOLLOW-FILE] MLS FileHeader',
            '[HOLLOW-FILE] FileHeader received',
            '[HOLLOW-MLS] Decrypt failed',
            '[HOLLOW-MLS] Received MlsChannelMessage for unknown group',
            'SecretTree',
            'WrongEpoch',
            $script:FleetVars.RUN)) {
            $hits = @(Get-PeerLogLines $peer $pattern)
            if ($hits.Count -eq 0) { continue }
            Write-Host "  --- $peer :: $pattern ($($hits.Count)) ---" -ForegroundColor DarkYellow
            foreach ($line in ($hits | Select-Object -Last 12)) { Write-Host "     $line" -ForegroundColor DarkGray }
        }
    }
}

# --------------------------------------------------------------------------
# Three files the journey carries no fixture for
# --------------------------------------------------------------------------

function New-RandomFile($path, $sizeBytes) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bytes = New-Object byte[] $sizeBytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Say "wrote $path ($sizeBytes bytes)"
}

# --------------------------------------------------------------------------
# Sending, opening, and asking a card for its bytes
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

# Attach a file to the OPEN composer, caption it and send. The composer is
# tapped first: enter_text on an unfocused field reports success into nothing,
# which is worst right after a reconnect, when the pane is being rebuilt.
function Send-DmFile($peer, $path, $caption) {
    Step $peer @{ op = 'wait_for'; target = 'hint:Type a message...'; timeout_ms = 30000 }
    Step $peer @{ op = 'attach_file'; path = $path }
    Step $peer @{ op = 'tap'; target = 'hint:Type a message...' }
    Step $peer @{ op = 'enter_text'; target = 'hint:Type a message...'; value = $caption }
    Step $peer @{ op = 'key'; value = 'enter' }
    # Every send waits for its OWN optimistic row before anything else runs.
    Step $peer @{ op = 'wait_for'; target = "text:$caption"; timeout_ms = 60000 }
}

function Send-ChannelFile($peer, $path, $caption) {
    # The composer has to be ON SCREEN: `attach_file` reaches the pane's own
    # drop handler, and a settings page left open has no pane at all.
    Step $peer @{ op = 'wait_for'; target = 'hint:Message #general'; timeout_ms = 30000 }
    Step $peer @{ op = 'attach_file'; path = $path }
    Step $peer @{ op = 'tap'; target = 'hint:Message #general' }
    Step $peer @{ op = 'enter_text'; target = 'hint:Message #general'; value = $caption }
    Step $peer @{ op = 'key'; value = 'enter' }
    Step $peer @{ op = 'wait_for'; target = "text:$caption"; timeout_ms = 60000 }
}

# Ask the card for its bytes, the way a user does - and only when there is
# something to tap. With the default auto-download threshold (169 MB) the
# chat-open sweep already asked for a 600 KB file, so state 2 or 3 can be on the
# card before this runs, and state 2 and 3 carry NO control by design. So: wait
# for the Download control OR the caption, tap only the control. Returns the
# target that matched, or $null when neither ever showed.
function Invoke-CardDownload($peer, $fileName, $caption, $timeoutSeconds = 90) {
    $control = "semantics:Download $fileName"
    $hit = Wait-ForAnyTarget $peer @($control, "text:$caption") $timeoutSeconds
    if (-not $hit) { return $null }
    if ($hit -eq $control) {
        # A HollowPressable with a semanticLabel matches semantics:X twice
        # (the Semantics widget and the pressable), so the tap is indexed.
        Invoke-SoftStep $peer @{ op = 'tap'; target = $control; index = 0 } | Out-Null
    } else {
        Add-Note "$peer showed the caption for $fileName before anything was tapped (the auto-download sweep asked first)"
    }
    return $hit
}

# --------------------------------------------------------------------------
# Boot
# --------------------------------------------------------------------------

if (-not $SkipBuild) {
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
Say "run tag $runTag, server $server"

New-RandomFile $fileOne 614400
New-RandomFile $fileTwo 614401
New-RandomFile $fileThree 614402

$failure = $null
$serverCreated = $false

try {
    Wait-ForConnected a | Out-Null
    Wait-ForConnected b | Out-Null
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

    # ---- G1: friends, and a DM each way ------------------------------------
    # The steps of probe_scenarios/fleet/friend_dm.json. The Friends dialog is
    # closed by its OWN control and the dialog is waited out, never by Escape:
    # by then focus has left the dialog, the key reaches nothing, and the
    # barrier covers the DM tab. And the Close is SCOPED - a bare
    # semantics:Close matches the window title bar first, and that tap ends the
    # process.
    Say '1/5 a and b become friends and DM both ways'
    Step b @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step b @{ op = 'tap'; target = 'text:Add Friend'; index = 0 }
    Step b @{ op = 'enter_text'; target = 'hint:Peer ID or nickname...'; value = '${PEER_A}' }
    Step b @{ op = 'wait_for'; target = 'text:${PEER_A}'; timeout_ms = 15000 }
    Step b @{ op = 'tap'; target = 'text:Send Request'; index = 0 }

    # The Accept button only exists on the INCOMING tab. Waiting for it from the
    # Friends tab is a 30-second timeout that reads exactly like a delivery
    # failure and is not one.
    Step a @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step a @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
    Step a @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 60000 }
    Step a @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }

    Step a @{ op = 'wait_for'; target = 'text:probe-b'; timeout_ms = 60000 }
    Step b @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 60000 }

    Step a @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step a @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
    Open-Dm a 'probe-b'
    Step a @{ op = 'tap'; target = 'hint:Type a message...' }
    Step a @{ op = 'enter_text'; target = 'hint:Type a message...'; value = 'dm from a ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:dm from a ${RUN}'; timeout_ms = 30000 }
    Step b @{ op = 'wait_for'; target = 'text:dm from a ${RUN}'; timeout_ms = 60000 }

    Step b @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step b @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
    Open-Dm b 'probe-a'
    Step b @{ op = 'tap'; target = 'hint:Type a message...' }
    Step b @{ op = 'enter_text'; target = 'hint:Type a message...'; value = 'dm from b ${RUN}' }
    Step b @{ op = 'key'; value = 'enter' }
    Step b @{ op = 'wait_for'; target = 'text:dm from b ${RUN}'; timeout_ms = 30000 }
    Step a @{ op = 'wait_for'; target = 'text:dm from b ${RUN}'; timeout_ms = 60000 }
    Set-Gate 'G1 a and b are friends and DM both ways' 'PASS'

    # ---- G2: state 2 in a DM ------------------------------------------------
    Say '2/5 b closes, a attaches file one, a closes, b comes back alone'
    Stop-Peer b
    # The relay learns b is gone from the room membership diff, and a computes
    # its fan-out targets from that. Sending into a stale view proves nothing.
    Start-Sleep -Seconds 5

    Send-DmFile a $fileOne 'file one ${RUN}'
    Step a @{ op = 'shot'; name = "fcs-$runTag-a-sent-one" }
    # POLLED, not checked once: the optimistic row is written by Dart before
    # Rust has read the file, so the sender's own copy lands a moment later.
    $aCopyOne = Wait-ForPeerFile a $fileOne "a's own copy of file one" 60
    if (-not $aCopyOne) { throw "a sent file one but kept no copy of it in $(Get-PeerFilesDir a)" }
    Say "a holds file one at $($aCopyOne.Name)"

    Stop-Peer a
    Start-Sleep -Seconds 3

    Restart-Peer b
    Wait-ForConnected b | Out-Null
    Open-Dm b 'probe-a'
    Step b @{ op = 'wait_for'; target = 'text:file one ${RUN}'; timeout_ms = 180000 }

    $hitOne = Invoke-CardDownload b $nameOne $dmOfflineCaption 90
    if (-not $hitOne) {
        Step b @{ op = 'shot'; name = "fcs-$runTag-b-one-no-card" }
        Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
        Add-Note "G2: neither a Download control nor the offline caption ever appeared for $nameOne"
    }
    $offlineCard = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$dmOfflineCaption"; timeout_ms = 90000 }
    Step b @{ op = 'shot'; name = "fcs-$runTag-b-state2-dm" }
    Step b @{ op = 'dump'; name = 'fcs-state2-dm' }
    Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
    if (-not $offlineCard.ok) {
        Set-Gate 'G2 DM state 2: the offline sender is named, bytes follow' 'FAIL'
        Add-Note "G2: the card never read `"$dmOfflineCaption`""
        Write-Evidence 'G2'
        throw 'G2 failed: the DM card did not name the offline sender'
    }

    # ---- G2b: drop the queued ask by hand, then rebuild it ------------------
    # The hover bar mirrors the card: while the ask is queued its Download
    # becomes a stop action. `hover` PARKS the mouse and deliberately leaves it
    # there (probe_runner `_hover`), and `tap` sends its own touch-like pointer,
    # so the bar survives the wait, the screenshot and the tap. It hides 60ms
    # after BOTH it and the row lose the mouse, which is why the pointer is
    # parked somewhere harmless before the card's own button is tapped: the bar
    # is an overlay and can otherwise sit over it.
    Say '    G2b: stop the queued ask from the hover bar, then ask again'
    $g2b = 'G2b DM state 2: stop waiting returns the card to Download, asking again re-queues'
    # index 0 on both hovers: `hover` resolves the target and then takes its
    # CENTRE, and getCenter throws outright when a target matched twice - which
    # a `text:` target does often enough (a run log has "text:probe-b ... 2
    # matches"). An index makes the pointer land somewhere definite.
    Step b @{ op = 'hover'; target = "text:$nameOne"; index = 0 }
    $stopControl = Invoke-SoftStep b @{ op = 'wait_for'; target = 'semantics:Stop waiting for this file'; timeout_ms = 30000 }
    Step b @{ op = 'shot'; name = "fcs-$runTag-b-hover-stop" }
    if (-not $stopControl.ok) {
        Set-Gate $g2b 'FAIL'
        Add-Note "G2b: the hover bar never offered 'Stop waiting for this file' for $nameOne"
        Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
        Write-Evidence 'G2b'
        throw 'G2b failed: no stop action on the hover bar'
    }
    Step b @{ op = 'tap'; target = 'semantics:Stop waiting for this file'; index = 0 }
    $stopped = Invoke-SoftStep b @{ op = 'wait_for'; gone = "text:$dmOfflineCaption"; timeout_ms = 30000 }
    Step b @{ op = 'hover'; target = 'hint:Type a message...'; index = 0 }
    $backToDownload = Invoke-SoftStep b @{ op = 'wait_for'; target = "semantics:Download $nameOne"; timeout_ms = 30000 }

    # Ask again by hand. The card has to re-queue and say so, and it is THIS
    # ask that the rest of G2 watches heal when a comes back.
    if ($backToDownload.ok) {
        Step b @{ op = 'tap'; target = "semantics:Download $nameOne"; index = 0 }
    }
    $requeued = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$dmOfflineCaption"; timeout_ms = 60000 }
    Step b @{ op = 'shot'; name = "fcs-$runTag-b-requeued" }
    if ($stopped.ok -and $backToDownload.ok -and $requeued.ok) {
        Set-Gate $g2b 'PASS'
    } else {
        Set-Gate $g2b 'FAIL'
        Add-Note "G2b: captionCleared=$($stopped.ok) downloadBack=$($backToDownload.ok) reQueued=$($requeued.ok)"
        Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
        Write-Evidence 'G2b'
        throw 'G2b failed: see the evidence above'
    }

    # a comes back, and the RE-QUEUED ask has to retry itself: no tap on b.
    Say '    a returns - the queued ask has to fetch the bytes with no tap on b'
    Restart-Peer a
    Wait-ForConnected a | Out-Null
    $bytesOne = Wait-ForPeerFile b $fileOne 'file one' 120
    $captionGoneOne = Invoke-SoftStep b @{ op = 'wait_for'; gone = "text:$dmOfflineCaption"; timeout_ms = 60000 }
    Step b @{ op = 'shot'; name = "fcs-$runTag-b-one-arrived" }
    if ($bytesOne -and $captionGoneOne.ok) {
        Set-Gate 'G2 DM state 2: the offline sender is named, bytes follow' 'PASS'
    } else {
        Set-Gate 'G2 DM state 2: the offline sender is named, bytes follow' 'FAIL'
        Add-Note "G2: bytes=$([bool]$bytesOne) captionCleared=$($captionGoneOne.ok)"
        Write-Evidence 'G2'
        throw 'G2 failed: the queued ask did not self-heal when the sender came back'
    }

    # ---- G3: state 3 in a DM ------------------------------------------------
    Say '3/5 a attaches file two, then loses its own copy while it is closed'
    Stop-Peer b
    Start-Sleep -Seconds 5
    Open-Dm a 'probe-b'
    Send-DmFile a $fileTwo 'file two ${RUN}'
    Step a @{ op = 'shot'; name = "fcs-$runTag-a-sent-two" }
    # "Nothing to delete" would make this gate pass for the wrong reason: a
    # holder that never held is not the case under test. So the copy is waited
    # for while a is still up, and found again once a is closed and the file
    # handle is certainly gone.
    if (-not (Wait-ForPeerFile a $fileTwo "a's own copy of file two" 60)) {
        throw "a sent file two but never wrote its own copy, so state 3 cannot be produced"
    }
    Stop-Peer a
    Start-Sleep -Seconds 3

    $aCopyTwo = Find-PeerFile a $fileTwo
    if (-not $aCopyTwo) { throw "a has no copy of file two to delete, so state 3 cannot be produced" }
    Say "deleting a's own copy of file two ($($aCopyTwo.FullName))" 'Yellow'
    Remove-Item $aCopyTwo.FullName -Force
    if (Find-PeerFile a $fileTwo) { throw "a's copy of file two is still on disk after the delete" }

    # a's boot-time reset_stale_files clears the row's disk path, so a comes
    # back as a peer that is online and does NOT have the bytes.
    Restart-Peer a
    Wait-ForConnected a | Out-Null
    Restart-Peer b
    Wait-ForConnected b | Out-Null
    Open-Dm b 'probe-a'
    Step b @{ op = 'wait_for'; target = 'text:file two ${RUN}'; timeout_ms = 180000 }

    # The chat-open sweep asks on its own when auto-download allows it, so the
    # negative answer can land before any tap. Give it a window, then ask by
    # hand and give it another.
    $goneCard = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$dmGoneCaption"; timeout_ms = 60000 }
    if (-not $goneCard.ok) {
        Say '    no answer from the open sweep - asking the card by hand'
        $hitTwo = Invoke-CardDownload b $nameTwo $dmGoneCaption 60
        if (-not $hitTwo) { Add-Note "G3: no Download control for $nameTwo to tap either" }
        $goneCard = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$dmGoneCaption"; timeout_ms = 60000 }
    }
    # The second round trip must not have cost the first one its bytes.
    $stillOne = Find-PeerFile b $fileOne
    Step b @{ op = 'shot'; name = "fcs-$runTag-b-state3-dm" }
    Step b @{ op = 'dump'; name = 'fcs-state3-dm' }
    Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
    if ($goneCard.ok -and $stillOne) {
        Set-Gate 'G3 DM state 3: the sender says it no longer has the file' 'PASS'
    } else {
        Set-Gate 'G3 DM state 3: the sender says it no longer has the file' 'FAIL'
        Add-Note "G3: caption=$($goneCard.ok) fileOneStillOnDisk=$([bool]$stillOne)"
        Write-Evidence 'G3'
        throw 'G3 failed: see the evidence above'
    }

    # ---- G4: state 2 in a channel -------------------------------------------
    Say '4/5 a creates a server, b joins, then the same round trip in #general'
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
    Step a @{ op = 'capture'; target = 'type:SelectableText'; as = 'INVITE' }
    Step a @{ op = 'key'; value = 'escape' }

    Step b @{ op = 'tap'; target = 'semantics:Create a server' }
    Step b @{ op = 'enter_text'; target = 'hint:Invite link or server ID'; value = '${INVITE}' }
    Step b @{ op = 'tap'; target = 'text:Join'; index = 0 }
    Step b @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 120000 }
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'open_channel'; name = 'general' }
    Step a @{ op = 'open_channel'; name = 'general' }

    # A message each way first: it is the cheapest proof that the MLS group
    # actually formed, so a missing file later is a file problem.
    Step a @{ op = 'tap'; target = 'hint:Message #general' }
    Step a @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'hello from a ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 30000 }
    Step b @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 120000 }

    Stop-Peer b
    Start-Sleep -Seconds 5
    Send-ChannelFile a $fileThree 'file three ${RUN}'
    Step a @{ op = 'shot'; name = "fcs-$runTag-a-sent-three" }
    Write-ChannelRows a 'a after posting file three' | Out-Null
    # a is the only holder there will be, so if its own copy never landed the
    # gate would fail three minutes later for the wrong reason.
    if (-not (Wait-ForPeerFile a $fileThree "a's own copy of file three" 60)) {
        throw "a posted file three but kept no copy of it, so nothing can serve b later"
    }
    Stop-Peer a
    Start-Sleep -Seconds 3

    Restart-Peer b
    Wait-ForConnected b | Out-Null
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'open_channel'; name = 'general' }
    Step b @{ op = 'wait_for'; target = 'text:file three ${RUN}'; timeout_ms = 180000 }

    $hitThree = Invoke-CardDownload b $nameThree $chanWaitCaption 90
    if (-not $hitThree) {
        Step b @{ op = 'shot'; name = "fcs-$runTag-b-three-no-card" }
        Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
        Add-Note "G4: neither a Download control nor the waiting caption ever appeared for $nameThree"
    }
    $waitCard = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$chanWaitCaption"; timeout_ms = 90000 }
    Step b @{ op = 'shot'; name = "fcs-$runTag-b-state2-channel" }
    Step b @{ op = 'dump'; name = 'fcs-state2-channel' }
    Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
    Write-ChannelRows b 'b after returning alone to the channel' | Out-Null
    if (-not $waitCard.ok) {
        Set-Gate 'G4 channel state 2: waiting for a peer, then bytes follow' 'FAIL'
        Add-Note "G4: the card never read `"$chanWaitCaption`""
        Write-Evidence 'G4'
        throw 'G4 failed: the channel card did not say it was waiting for a peer'
    }

    Say '5/5 a returns - the channel ask has to fetch the bytes with no tap on b'
    Restart-Peer a
    Wait-ForConnected a | Out-Null
    Step a @{ op = 'open_server'; name = $server }
    Step a @{ op = 'open_channel'; name = 'general' }
    $bytesThree = Wait-ForPeerFile b $fileThree 'file three' 180
    $captionGoneThree = Invoke-SoftStep b @{ op = 'wait_for'; gone = "text:$chanWaitCaption"; timeout_ms = 60000 }
    Step b @{ op = 'shot'; name = "fcs-$runTag-b-three-arrived" }
    Write-ChannelRows b 'b after the sender came back' | Out-Null
    if ($bytesThree -and $captionGoneThree.ok) {
        Set-Gate 'G4 channel state 2: waiting for a peer, then bytes follow' 'PASS'
    } else {
        Set-Gate 'G4 channel state 2: waiting for a peer, then bytes follow' 'FAIL'
        Add-Note "G4: bytes=$([bool]$bytesThree) captionCleared=$($captionGoneThree.ok)"
        Write-Evidence 'G4'
        throw 'G4 failed: the channel ask did not self-heal when the holder came back'
    }
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
    $unreached = Set-FirstUnreachedGateFailed
    if ($unreached) { Say "first gate without a verdict: $unreached" 'Red' }
}

# --------------------------------------------------------------------------
# Cleanup. Runs whatever happened: leaving a fleet server alive is worse than a
# noisy log, because these are real identities on the real relay.
# --------------------------------------------------------------------------
if ($serverCreated -and -not $KeepServer) {
    Say 'cleanup: deleting the server as its owner'
    try {
        if (-not (Get-PeerProcess 'a')) { Restart-Peer a; Wait-ForConnected a | Out-Null }
        Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 60000 }
        Step a @{ op = 'right_click'; target = "server:$server" }
        Step a @{ op = 'tap'; target = 'menu > text:Server settings' }
        Step a @{ op = 'tap'; target = 'text:Danger'; index = 0 }
        Step a @{ op = 'tap'; target = 'text:Delete server'; index = 0 }
        # index 1: index 0 is the dialog's TITLE, and tapping a title silently
        # does nothing and PASSES.
        Step a @{ op = 'tap'; target = 'dialog > text:Delete server'; index = 1 }
        Step a @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 60000 }
        Set-Gate 'C  cleanup: no fleet server left on the relay' 'PASS'
        Say 'cleanup done' 'Green'
    } catch {
        Set-Gate 'C  cleanup: no fleet server left on the relay' 'FAIL'
        Say "cleanup failed (the server may still exist): $($_.Exception.Message)" 'Red'
    }
} elseif ($KeepServer) {
    Set-Gate 'C  cleanup: no fleet server left on the relay' 'WARN'
    Add-Note '-KeepServer was passed, so a fleet server is still on the relay'
} else {
    Set-Gate 'C  cleanup: no fleet server left on the relay' 'WARN'
    Add-Note 'no server was ever created, so there was nothing to delete'
}

foreach ($path in @($fileOne, $fileTwo, $fileThree)) {
    if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
Write-Host ''
Say "gates for run $runTag, server $server" 'White'
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
Say "a = $($script:FleetVars.PEER_A)" 'DarkCyan'
Say "b = $($script:FleetVars.PEER_B)" 'DarkCyan'

if ($failure) { throw $failure }
if (-not $KeepUp) {
    Say 'stopping the fleet'
    Invoke-FleetScript @('-Stop')
}
Say 'PASS' 'Green'
