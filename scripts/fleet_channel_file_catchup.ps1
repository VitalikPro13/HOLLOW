# A channel IMAGE posted while a member is away, across two REAL instances.
#
#   powershell -File scripts\fleet_channel_file_catchup.ps1                # fresh keys, builds first
#   powershell -File scripts\fleet_channel_file_catchup.ps1 -SkipBuild     # you just built
#   powershell -File scripts\fleet_channel_file_catchup.ps1 -KeepIdentities
#   powershell -File scripts\fleet_channel_file_catchup.ps1 -KeepUp
#
# ## Why a script and not a scenario JSON
#
# The whole journey is a member going away and coming back, and a scenario file
# has no op for that. Same shape as fleet_pending_join.ps1 and
# fleet_owner_offline.ps1, whose Restart-Peer / Stop-Peer this copies: a relaunch
# on the EXISTING data directory, because a fixture restore would throw away the
# very server and the very channel history the journey is about.
#
# ## What it proves, that the Rust harness cannot
#
# The harness proves the ops converge with every node in one process and a mock
# relay. This drives the real app against the real relay, which is where the open
# bug lives (HOLLOW_PLAN, the `[~]` availability-cache entry): channel TEXT comes
# back after catch-up, a channel IMAGE renders nothing.
#
#   G1 a and b are in one server and one channel, talking both ways. Baseline.
#   G2 b is CLOSED and a posts an image with a caption. a sees its own card.
#   G3 b comes back with the SENDER STILL UP. The caption row and the file card
#      have to be there, and then the bytes have to arrive on their own (an image
#      under the auto-download gate) or on open.
#   G4 b is closed, a posts a second image and closes too, and b comes back to a
#      relay with nobody behind it. Caption row and a metadata card with no bytes
#      is the correct answer here; the bytes land when a returns.
#
# G3 and G4 both read the DATABASE through the `channel_rows` probe op as well as
# the screen, because "nothing rendered" and "nothing arrived" look identical in
# a screenshot and need completely different fixes.
#
# Windows PowerShell 5.1 is what is installed here, so no pwsh-only syntax, and
# `pwsh` is not a thing on this machine: run it with `powershell -File`.

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

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$server = "cfc-$($script:FleetVars.RUN)"
$journeyPeers = @('a', 'b')
$imgOne = Join-Path $script:FleetStageRoot "img-$($script:FleetVars.RUN)-1.png"
$imgTwo = Join-Path $script:FleetStageRoot "img-$($script:FleetVars.RUN)-2.png"
$imgThree = Join-Path $script:FleetStageRoot "img-$($script:FleetVars.RUN)-3.png"
# The sender converts a PNG to WebP, so a card is matched on the STEM.
$stemOne = "img-$($script:FleetVars.RUN)-1"
$stemTwo = "img-$($script:FleetVars.RUN)-2"
$stemThree = "img-$($script:FleetVars.RUN)-3"

function Say($message, $colour = 'Cyan') { Write-Host "[chan-file-catchup] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{
    'G1 a and b share cfc-RUN #general and talk both ways'      = 'SKIP'
    'G2 b is closed and a posts an image it can see itself'     = 'SKIP'
    'G3 b returns with the sender UP: caption, card, then bytes' = 'SKIP'
    'G4 b returns with the sender GONE: caption and a dry card'  = 'SKIP'
    'G5 a returns and the second image finally gets its bytes'   = 'SKIP'
    'G6 a PUBLIC channel image survives the same round trip'     = 'SKIP'
    'C  cleanup: no fleet server left on the relay'              = 'SKIP'
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
    # three times - so without this the only screenshots that survive a run are
    # the last leg's, and the gates that FAILED are usually the earlier ones.
    # Keep the named shots and dumps somewhere the wipe does not reach.
    $kept = Join-Path $script:FleetOutRoot "kept\$peer"
    if (Test-Path $out) {
        New-Item -ItemType Directory -Path $kept -Force | Out-Null
        Get-ChildItem $out -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'cfc-*' -or $_.Name -like 'map-*' } |
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
    # WAL checkpoint in flight can take several seconds to actually go, and the
    # other journeys' fixed 1500ms failed a whole run on that alone. Wait for
    # the process to be GONE, then let the file handles drop.
    $deadline = (Get-Date).AddSeconds(30)
    while (Get-PeerProcess $peer) {
        if ((Get-Date) -ge $deadline) { throw "peer $peer did not stop within 30s" }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 1500
    Say "$peer is closed - OFFLINE" 'Yellow'
}

# --------------------------------------------------------------------------
# The database behind the screen
# --------------------------------------------------------------------------

# One `channel_rows` reading of the open channel, as an array of lines.
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

# Polls the DB until a files row for $stem exists (and, when asked, until it has
# bytes on disk). Returns the matching line, or $null when the clock runs out.
function Wait-ForFileRow($peer, $stem, $timeoutSeconds, $requireBytes = $false) {
    $what = 'a files row'
    if ($requireBytes) { $what = 'bytes on disk' }
    Write-Host ("  [{0}] waiting for {1} for {2} (up to {3}s)" -f $peer, $what, $stem, $timeoutSeconds) -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $last = $null
    while ($true) {
        foreach ($line in (Get-ChannelRows $peer)) {
            if ($line -notlike "*file *name=$stem*") { continue }
            $last = $line
            if (-not $requireBytes) { return $line }
            if ($line -notlike '*completed=-*') { return $line }
        }
        if ((Get-Date) -ge $deadline) {
            if ($last) { Add-Note "last row seen for ${stem}: $last" }
            return $null
        }
        Start-Sleep -Seconds 3
    }
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

# Everything worth reading when a gate fails, from BOTH instances. The receiver's
# log is where the ring replay either shows up or does not.
function Write-Evidence($label) {
    Say "evidence for $label" 'Yellow'
    foreach ($peer in $journeyPeers) {
        foreach ($pattern in @(
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
# A tiny PNG, made here so the journey carries no binary fixture
# --------------------------------------------------------------------------
Add-Type -AssemblyName System.Drawing

function New-ProbeImage($path, $seedColour) {
    $bmp = New-Object System.Drawing.Bitmap 64, 64
    try {
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gfx.Clear($seedColour)
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 4
            try {
                $gfx.DrawLine($pen, 4, 4, 60, 60)
                $gfx.DrawLine($pen, 60, 4, 4, 60)
            } finally { $pen.Dispose() }
        } finally { $gfx.Dispose() }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bmp.Dispose() }
    Say "wrote $path ($((Get-Item $path).Length) bytes)"
}

# Attach a file to the OPEN composer, caption it and send. The composer is
# tapped first: enter_text on an unfocused field types into nothing.
function Send-ChannelImage($peer, $path, $caption) {
    # The composer has to be ON SCREEN: `attach_file` reaches the pane's own
    # drop handler, and a settings page left open has no pane at all.
    Step $peer @{ op = 'wait_for'; target = 'hint:Message #general'; timeout_ms = 30000 }
    Step $peer @{ op = 'attach_file'; path = $path }
    Step $peer @{ op = 'tap'; target = 'hint:Message #general' }
    Step $peer @{ op = 'enter_text'; target = 'hint:Message #general'; value = $caption }
    Step $peer @{ op = 'key'; value = 'enter' }
    # Every send waits for its OWN optimistic row before anything else runs.
    Step $peer @{ op = 'wait_for'; target = "text:$caption"; timeout_ms = 60000 }
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
Say "run tag $($script:FleetVars.RUN), server $server"

New-ProbeImage $imgOne ([System.Drawing.Color]::FromArgb(255, 220, 90, 60))
New-ProbeImage $imgTwo ([System.Drawing.Color]::FromArgb(255, 60, 120, 220))
New-ProbeImage $imgThree ([System.Drawing.Color]::FromArgb(255, 90, 200, 110))

$failure = $null
$serverCreated = $false

try {
    Wait-ForConnected a | Out-Null
    Wait-ForConnected b | Out-Null
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

    # ---- G1: one server, one channel, a message each way -------------------
    Say '1/6 a creates the server, b joins, both talk in #general'
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

    Step a @{ op = 'tap'; target = 'hint:Message #general' }
    Step a @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'hello from a ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 30000 }
    Step b @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 120000 }

    Step b @{ op = 'tap'; target = 'hint:Message #general' }
    Step b @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'hello from b ${RUN}' }
    Step b @{ op = 'key'; value = 'enter' }
    Step b @{ op = 'wait_for'; target = 'text:hello from b ${RUN}'; timeout_ms = 30000 }
    Step a @{ op = 'wait_for'; target = 'text:hello from b ${RUN}'; timeout_ms = 120000 }
    Set-Gate 'G1 a and b share cfc-RUN #general and talk both ways' 'PASS'

    # ---- G2: b closes, a posts an image ------------------------------------
    Say '2/6 closing b, then a posts an image with a caption'
    Stop-Peer b
    # The relay learns b is gone from the room membership diff, and a computes
    # its fan-out targets from that. Sending into a stale view is the classic
    # way to prove nothing at all.
    Start-Sleep -Seconds 5

    Send-ChannelImage a $imgOne 'shot one ${RUN}'
    Step a @{ op = 'shot'; name = "cfc-$($script:FleetVars.RUN)-a-sent-one" }
    $aRows = Write-ChannelRows a 'a after posting image one'
    if (-not (@($aRows | Where-Object { $_ -like "*file *name=$stemOne*" }).Count)) {
        throw "a posted image one but has no files row for $stemOne of its own"
    }
    Set-Gate 'G2 b is closed and a posts an image it can see itself' 'PASS'

    # ---- G3: b returns with the sender still up ----------------------------
    Say '3/6 b returns with a STILL UP - the caption, the card, then the bytes'
    Restart-Peer b
    Wait-ForConnected b | Out-Null
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'open_channel'; name = 'general' }

    $captionOne = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:shot one ${RUN}'; timeout_ms = 120000 }
    $rowOne = Wait-ForFileRow b $stemOne 120
    $bytesOne = $null
    if ($rowOne) { $bytesOne = Wait-ForFileRow b $stemOne 120 $true }
    Step b @{ op = 'shot'; name = "cfc-$($script:FleetVars.RUN)-b-return-sender-up" }
    Step b @{ op = 'dump'; name = "cfc-return-sender-up" }
    Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
    Write-ChannelRows b 'b after returning with the sender up' | Out-Null

    if ($captionOne.ok -and $rowOne -and $bytesOne) {
        Set-Gate 'G3 b returns with the sender UP: caption, card, then bytes' 'PASS'
    } else {
        Set-Gate 'G3 b returns with the sender UP: caption, card, then bytes' 'FAIL'
        Add-Note "G3: caption=$($captionOne.ok) filesRow=$([bool]$rowOne) bytes=$([bool]$bytesOne)"
        Write-Evidence 'G3'
        throw 'G3 failed: see the evidence above'
    }

    # ---- G4: b returns to a relay with nobody behind it --------------------
    Say '4/6 b closes, a posts a second image and closes too'
    Stop-Peer b
    Start-Sleep -Seconds 5
    Send-ChannelImage a $imgTwo 'shot two ${RUN}'
    Step a @{ op = 'shot'; name = "cfc-$($script:FleetVars.RUN)-a-sent-two" }
    Stop-Peer a
    Start-Sleep -Seconds 3

    Say '5/6 b returns ALONE - a caption row and a card with no bytes is correct here'
    Restart-Peer b
    Wait-ForConnected b | Out-Null
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'open_channel'; name = 'general' }

    $captionTwo = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:shot two ${RUN}'; timeout_ms = 120000 }
    $rowTwo = Wait-ForFileRow b $stemTwo 120
    Step b @{ op = 'shot'; name = "cfc-$($script:FleetVars.RUN)-b-return-sender-gone" }
    Step b @{ op = 'dump'; name = 'cfc-return-sender-gone' }
    Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
    Write-ChannelRows b 'b after returning alone' | Out-Null

    if ($captionTwo.ok -and $rowTwo) {
        Set-Gate 'G4 b returns with the sender GONE: caption and a dry card' 'PASS'
    } else {
        Set-Gate 'G4 b returns with the sender GONE: caption and a dry card' 'FAIL'
        Add-Note "G4: caption=$($captionTwo.ok) filesRow=$([bool]$rowTwo)"
        Write-Evidence 'G4'
        throw 'G4 failed: see the evidence above'
    }

    # ---- G5: the sender returns and the bytes follow -----------------------
    Say '6/6 a returns - the bytes for image two have to arrive'
    Restart-Peer a
    Wait-ForConnected a | Out-Null
    Step a @{ op = 'open_server'; name = $server }
    Step a @{ op = 'open_channel'; name = 'general' }
    # The viewport sweep is what pulls the bytes, and it runs on channel open
    # and on scroll. b is already sitting in #general, so a scroll is the
    # user action that asks again now that a holder is finally online - and
    # that pull is the thing the plan entry says is missing ("no syncing of
    # file bytes from the other online peer when he's online").
    Invoke-SoftStep b @{ op = 'scroll'; target = 'text:shot two ${RUN}'; dy = 120 } | Out-Null
    Invoke-SoftStep b @{ op = 'scroll'; target = 'text:shot two ${RUN}'; dy = -120 } | Out-Null
    $bytesTwo = Wait-ForFileRow b $stemTwo 180 $true
    Step b @{ op = 'shot'; name = "cfc-$($script:FleetVars.RUN)-b-bytes-after-sender-back" }
    Write-ChannelRows b 'b after the sender came back' | Out-Null
    if ($bytesTwo) {
        Set-Gate 'G5 a returns and the second image finally gets its bytes' 'PASS'
    } else {
        Set-Gate 'G5 a returns and the second image finally gets its bytes' 'FAIL'
        Write-Evidence 'G5'
        throw 'G5 failed: the bytes never arrived with the sender back online'
    }

    # ---- G6: the same round trip on a PUBLIC channel -----------------------
    # A public channel's caption is a plaintext PublicChannelMessage sent as a
    # 0x03 room broadcast, which the relay never tees into a topic ring, while
    # its FileHeader still rides the 0x07 topic. So the returning member can
    # receive the file metadata with no message row to hang it on.
    Say '7/8 making #general public, then the same offline image round trip'
    Step a @{ op = 'right_click'; target = "server:$server" }
    Step a @{ op = 'tap'; target = 'menu > text:Server settings' }
    Step a @{ op = 'tap'; target = 'text:Channels'; index = 0 }
    Step a @{ op = 'wait_for'; target = 'semantics:Make channel public, currently private'; timeout_ms = 30000 }
    Step a @{ op = 'tap'; target = 'semantics:Make channel public, currently private' }
    Step a @{ op = 'wait_for'; target = 'semantics:Make channel private, currently public'; timeout_ms = 30000 }
    # Server settings is a full page, not a dialog: one escape leaves the tab
    # and the pane is only back once the server and channel are re-opened.
    Step a @{ op = 'key'; value = 'escape' }
    Invoke-SoftStep a @{ op = 'key'; value = 'escape' } | Out-Null
    Step a @{ op = 'open_server'; name = $server }
    Step a @{ op = 'open_channel'; name = 'general' }
    Step a @{ op = 'wait_for'; target = 'hint:Message #general'; timeout_ms = 30000 }
    # b has to KNOW the channel is public before it goes away, or it is simply
    # a private-channel run with extra steps.
    Step b @{ op = 'open_channel'; name = 'general' }
    Start-Sleep -Seconds 8

    Stop-Peer b
    Start-Sleep -Seconds 5
    Send-ChannelImage a $imgThree 'shot three ${RUN}'
    Step a @{ op = 'shot'; name = "cfc-$($script:FleetVars.RUN)-a-sent-three" }
    Stop-Peer a
    Start-Sleep -Seconds 3

    Say '8/8 b returns alone to the PUBLIC channel'
    Restart-Peer b
    Wait-ForConnected b | Out-Null
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'open_channel'; name = 'general' }

    $captionThree = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:shot three ${RUN}'; timeout_ms = 120000 }
    $rowThree = Wait-ForFileRow b $stemThree 120
    Step b @{ op = 'shot'; name = "cfc-$($script:FleetVars.RUN)-b-public-return" }
    Step b @{ op = 'dump'; name = 'cfc-public-return' }
    Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
    Write-ChannelRows b 'b after returning alone to the public channel' | Out-Null

    if ($captionThree.ok -and $rowThree) {
        Set-Gate 'G6 a PUBLIC channel image survives the same round trip' 'PASS'
    } else {
        Set-Gate 'G6 a PUBLIC channel image survives the same round trip' 'FAIL'
        Add-Note "G6: caption=$($captionThree.ok) filesRow=$([bool]$rowThree)"
        Write-Evidence 'G6'
        throw 'G6 failed: see the evidence above'
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
}

foreach ($path in @($imgOne, $imgTwo, $imgThree)) {
    if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
Write-Host ''
Say "gates for run $($script:FleetVars.RUN), server $server" 'White'
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
