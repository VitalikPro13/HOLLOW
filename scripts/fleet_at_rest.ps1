# At-rest file encryption (issue 78), driven across three REAL Hollow instances.
#
#   powershell -File scripts\fleet_at_rest.ps1 -Seed        # phase S, on the OLD build
#   powershell -File scripts\fleet_at_rest.ps1 -Upgrade     # phase U, on the NEW build
#   powershell -File scripts\fleet_at_rest.ps1 -AbortSeed   # give the seed up, delete its server
#
# ## What this is
#
# Encryption at rest only means something if the files that were ALREADY on
# disk get protected too, and if everything the app does with a file still
# works once they are. One journey cannot prove that from one build, because
# the interesting state is a data directory written by the OLD code and read by
# the NEW one. So it is two runs:
#
#   phase S (seed)    on the build that still writes PLAINTEXT. a and b become
#                     friends, a creates a server and b joins, a sends a PNG, a
#                     600 KB .bin and a 3 s MP4 in the DM and again in #general,
#                     b receives all six. Both data directories are then copied
#                     to build\fleet_out\at_rest_seed with every file's SHA-256,
#                     and the run PROVES the marker is readable in b's files.
#                     That proof is the honesty half: without it phase U would
#                     be asserting that ciphertext is ciphertext.
#   phase U (upgrade) on the build that encrypts. The seed is restored as the
#                     live data directory and the gates below run against it.
#
# ## Gates (phase U)
#
#   G1 migration    every content file under a's and b's files/ (and
#                   vault_cache/) starts with HFE1 within 60 s, the marker is
#                   absent from every byte under the data root except the logs,
#                   and the Storage Manager says Protected.
#   G2 render       b opens the DM: the migrated image renders, the .bin card
#                   still shows its name and size, and the video bubble reports
#                   an initialised controller with a duration (probe op
#                   `video_state`).
#   G3 fresh receive a sends a NEW png/bin/mp4; b's copies start with HFE1 from
#                   the first observation and the marker never reaches b's disk.
#   G4 serve        c launches fresh, joins the server, opens #general and is
#                   served the seed PNG from an ENCRYPTED copy; c's own copy is
#                   HFE1 too.
#   G5 export       probe op `export_attachment` (Unit D's exportAttachmentTo)
#                   writes the plaintext back out: the SHA-256 equals the seed's
#                   and the marker IS in the export.
#   C  cleanup      a deletes the server, whatever happened.
#
# ## The fixtures, and why the MP4 is made the way it is
#
# The marker is `HOLLOW-PLAIN-<run>`, and it rides three files:
#   * a PNG with a tEXt chunk. It is the file that has to RENDER after the
#     migration. The marker does NOT survive the send: Rust converts every
#     PNG/JPEG to WebP before it leaves (`image_convert::should_convert_to_webp`),
#     so the receiver's copy is a re-encode. That is why the plaintext proof
#     rests on the other two.
#   * a 600 KB .bin of the repeated marker. `.bin` is not on the staged-image
#     extension list, so its bytes cross the wire untouched.
#   * a 3 s MP4 carrying the marker as its `comment` metadata. Not an image, so
#     it crosses untouched as well.
# The bundled ffmpeg (`build\fleet\a\ffmpeg.exe`, the same binary as
# `vendor\ffmpeg`) is a MINIMAL build: `-encoders` offers libwebp, aac, libopus
# and pcm_s16le and nothing else, there are no filters at all, so it cannot
# synthesise a video. It CAN decode h264/hevc/vp8/vp9 and mux mp4, which is what
# the app needs of it. So the clip is generated with whatever full ffmpeg the
# machine has and then DECODE-VERIFIED with the bundled one; the run prints both
# binaries and the encoder it used.
#
# ## Rules this journey lives by (each cost a run somewhere else)
#
# Message literals are SINGLE quoted so `${RUN}` survives to Expand-FleetVars.
# Every send waits for its own optimistic row. The composer is tapped before
# enter_text. Instances are never launched with -RedirectStandardOutput. A
# relaunch wipes the peer's probe output, so screenshots are copied to kept\
# first. The fleet talks only to servers it creates AND deletes.
#
# Windows PowerShell 5.1: no pwsh-only syntax, and `pwsh` is not installed here.

param(
    # Phase S: seed a plaintext data directory with the OLD build.
    [switch]$Seed,
    # Phase U: restore the seed onto the NEW build and run the gates.
    [switch]$Upgrade,
    # Give a seed up: bring a back and delete the server it created.
    [switch]$AbortSeed,
    # Skip the build+stage step (phase U builds by default, phase S never does).
    [switch]$SkipBuild,
    # Leave the instances running after a PASS. A FAILED run always leaves them
    # up, whatever this says.
    [switch]$KeepUp,
    # Drive the identities that are already live instead of minting new ones.
    [switch]$KeepIdentities,
    # Leave the server behind. Debugging only: these are real identities on the
    # real relay.
    [switch]$KeepServer,
    # Where the three fixtures are written. Outside the repo by default.
    [string]$FixtureDir = '',
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag runs a journey nobody asked for and
# reports a clean pass for it.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -Seed, -Upgrade, -AbortSeed, -SkipBuild, -KeepUp, -KeepIdentities, -KeepServer, -FixtureDir and -BootTimeoutSeconds."
}

$modes = @($Seed, $Upgrade, $AbortSeed) | Where-Object { $_ }
if ($modes.Count -ne 1) {
    throw 'pick exactly one of -Seed, -Upgrade and -AbortSeed.'
}
# Phase U's identities come out of the seed, so this would silently do nothing
# there while the caller believed it had chosen something.
if ($KeepIdentities -and -not $Seed) {
    throw '-KeepIdentities only means something with -Seed.'
}
# Phase S never builds: it runs on the build that is already staged, which is
# the whole point of seeding before the new code lands.
if ($SkipBuild -and $Seed) {
    throw '-SkipBuild only means something with -Upgrade. Phase S never builds.'
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$fixtureRoot = Join-Path $env:TEMP 'hollow_fleet\fixtures'
$seedRoot = Join-Path $script:FleetOutRoot 'at_rest_seed'
$seedManifestPath = Join-Path $seedRoot 'manifest.json'
$exportRoot = Join-Path $script:FleetOutRoot 'at_rest_export'
if (-not $FixtureDir) { $FixtureDir = Join-Path $script:FleetStageRoot 'at_rest_fixtures' }

$journeyPeers = @('a', 'b')

function Say($message, $colour = 'Cyan') { Write-Host "[at-rest] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{}
$script:Notes = New-Object System.Collections.ArrayList

function Set-GateList($names) {
    $script:Gates = [ordered]@{}
    foreach ($name in $names) { $script:Gates[$name] = 'SKIP' }
}

function Set-Gate($name, $status) {
    if (-not $script:Gates.Contains($name)) { throw "unknown gate '$name'" }
    $script:Gates[$name] = $status
}

function Add-Note($text) {
    [void]$script:Notes.Add($text)
    Say "note: $text" 'DarkCyan'
}

# 'SKIP' means "never reached"; 'SKIPPED' is a decision the journey took and is
# left alone here, so a deliberate skip can never be reported as the failure.
function Set-FirstUnreachedGateFailed {
    foreach ($key in @($script:Gates.Keys)) {
        if ($script:Gates[$key] -eq 'SKIP') { $script:Gates[$key] = 'FAIL'; return $key }
    }
    return $null
}

# The seed can only pay for ONE late-joiner gate: G4's server is deleted at
# cleanup, and the run that deletes it records that here so a later -Upgrade on
# the same seed skips G4 honestly instead of failing on a server that is gone.
function Set-SeedServerGone($why) {
    if (-not (Test-Path $seedManifestPath)) { return }
    try {
        $stored = Get-Content $seedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stored | Add-Member -NotePropertyName serverDeletedAt -NotePropertyValue (Get-Date -Format o) -Force
        $stored | Add-Member -NotePropertyName serverDeletedBy -NotePropertyValue $why -Force
        $stored | ConvertTo-Json -Depth 8 | Set-Content -Path $seedManifestPath -Encoding UTF8
        Say "recorded in the seed manifest: the server is gone ($why)" 'DarkCyan'
    } catch {
        Add-Note "could not record the deleted server in the seed manifest: $($_.Exception.Message)"
    }
}

function Write-GateReport($title) {
    Write-Host ''
    Say $title 'White'
    foreach ($key in $script:Gates.Keys) {
        $status = $script:Gates[$key]
        $colour = 'DarkGray'
        if ($status -eq 'PASS') { $colour = 'Green' }
        if ($status -eq 'FAIL') { $colour = 'Red' }
        if ($status -eq 'WARN') { $colour = 'Yellow' }
        if ($status -eq 'SKIPPED') { $colour = 'DarkCyan' }
        Write-Host ("  {0,-7} {1}" -f $status, $key) -ForegroundColor $colour
    }
    if ($script:Notes.Count -gt 0) {
        Write-Host ''
        Say 'notes' 'White'
        foreach ($note in $script:Notes) { Write-Host "  - $note" -ForegroundColor Gray }
    }
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
    $hit = Wait-ForAnyTarget $peer @('semantics:Online', 'tooltip:Online', 'text:Connected') $timeoutSeconds
    if (-not $hit) {
        throw "peer $peer never reported a settled connection within ${timeoutSeconds}s (no user-bar 'Online' tooltip, no Home 'Connected')"
    }
    return $hit
}

function Start-PeerProcess($peer) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Join-Path $runRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    # A relaunch wipes the probe's output directory, and this journey relaunches
    # several times, so the earlier legs' evidence is kept first.
    $kept = Join-Path $script:FleetOutRoot "kept\$peer"
    if (Test-Path $out) {
        New-Item -ItemType Directory -Path $kept -Force | Out-Null
        Get-ChildItem $out -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'atrest-*' -or $_.Name -like 'map-*' } |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $kept $_.Name) -Force -ErrorAction SilentlyContinue }
        Remove-Item $out -Recurse -Force
    }
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
    # Start-Process into inherit-handles mode and every instance then holds a
    # duplicate of this script's stdout pipe, so the script never returns.
    $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') -WorkingDirectory $dest -PassThru
    Say "launched $peer (pid $($proc.Id)) on $data"

    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { Say "$peer is live" 'Green'; return }
        if (-not (Get-PeerProcess $peer)) { throw "peer $peer died on launch.`n" + (Get-CrashTail $peer) }
        Start-Sleep -Milliseconds 300
    }
    throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
}

function Stop-Peer($peer) {
    $proc = Get-PeerProcess $peer
    if (-not $proc) { throw "peer $peer is not running, so it cannot be stopped" }
    $proc | Stop-Process -Force
    # POLLED, not a flat sleep: a Flutter instance mid-frame with a SQLCipher
    # WAL checkpoint in flight can take several seconds to actually go.
    $deadline = (Get-Date).AddSeconds(30)
    while (Get-PeerProcess $peer) {
        if ((Get-Date) -ge $deadline) { throw "peer $peer did not stop within 30s" }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 1500
    Say "$peer is closed" 'Yellow'
}

# --------------------------------------------------------------------------
# The disk behind the cards
# --------------------------------------------------------------------------

function Get-PeerDataDir($peer) { return (Join-Path $runRoot $peer) }
function Get-PeerFilesDir($peer) { return (Join-Path (Get-PeerDataDir $peer) 'files') }

# Byte search, not a text read: the marker is ASCII inside binary files, and
# latin-1 maps every byte to exactly one char, so IndexOf over that string is an
# exact byte search and costs a fraction of a per-byte loop.
function Test-BytesContain($path, $marker) {
    try { $bytes = [System.IO.File]::ReadAllBytes($path) } catch { return $false }
    if ($bytes.Length -lt $marker.Length) { return $false }
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    return ($text.IndexOf($marker, [System.StringComparison]::Ordinal) -ge 0)
}

function Get-FileMagic($path, $count = 4) {
    try {
        $stream = [System.IO.File]::OpenRead($path)
        try {
            $buffer = New-Object byte[] $count
            $read = $stream.Read($buffer, 0, $count)
            if ($read -le 0) { return '' }
            return [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        } finally { $stream.Dispose() }
    } catch { return '' }
}

function Test-Hfe1($path) { return ((Get-FileMagic $path 4) -eq 'HFE1') }

# Every file under a data root, with what the gates ask about it. Used for the
# seed manifest and for the migration gate, which is why it records the magic
# and the marker rather than just the hash.
function Get-DataRootScan($root, $marker) {
    $entries = @()
    if (-not (Test-Path $root)) { return $entries }
    $full = (Resolve-Path $root).Path
    foreach ($file in @(Get-ChildItem $full -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $hash = ''
        try { $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash } catch { }
        $relative = $file.FullName.Substring($full.Length).TrimStart('\')
        $entries += [pscustomobject]@{
            rel = $relative
            size = $file.Length
            sha256 = $hash
            magic = (Get-FileMagic $file.FullName 4)
            hasMarker = (Test-BytesContain $file.FullName $marker)
        }
    }
    return $entries
}

function Find-PeerFileByHash($peer, $sourcePath) {
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

# A copy identified by the marker instead of by the hash, which is what a
# receiver's file looks like once the sender has re-encoded it (images) or once
# it is encrypted (every file, after phase U).
function Find-PeerFileByMarker($peer, $marker) {
    $dir = Get-PeerFilesDir $peer
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { Test-BytesContain $_.FullName $marker })
}

function Wait-ForPeerFileByHash($peer, $sourcePath, $label, $timeoutSeconds) {
    Write-Host ("  [{0}] waiting for {1} on disk (up to {2}s)" -f $peer, $label, $timeoutSeconds) -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $hit = Find-PeerFileByHash $peer $sourcePath
        if ($hit) {
            Write-Host "     ok   $($hit.FullName) ($($hit.Length) bytes)" -ForegroundColor DarkGray
            return $hit
        }
        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Seconds 3
    }
}

function Get-PeerFileCount($peer) {
    $dir = Get-PeerFilesDir $peer
    if (-not (Test-Path $dir)) { return 0 }
    return @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue).Count
}

# The received copy of a file whose bytes cannot be matched any more, because
# encryption is the thing under test. The stored name keeps the sent extension,
# so that is what identifies it.
function Wait-ForPeerFileByExtension($peer, $extension, $timeoutSeconds) {
    Write-Host ("  [{0}] waiting for a stored {1} (up to {2}s)" -f $peer, $extension, $timeoutSeconds) -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $hit = @(Get-StoredContentFiles $peer | Where-Object { $_.Extension -eq $extension }) | Select-Object -First 1
        if ($hit) {
            Write-Host "     ok   $($hit.FullName) ($($hit.Length) bytes, magic '$(Get-FileMagic $hit.FullName 4)')" -ForegroundColor DarkGray
            return $hit
        }
        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Seconds 2
    }
}

# The one line the audio bubble logs about where it got its source, which is the
# difference between the loopback server working and the app quietly handing a
# player the decrypted bytes instead.
function Get-AudioSourceLine($peer) {
    $path = Join-Path (Join-Path $script:FleetOutRoot $peer) 'stdout.log'
    if (-not (Test-Path $path)) { return $null }
    try {
        return @(Get-Content $path -ErrorAction Stop |
            Where-Object { $_ -like '*at_rest audio source=*' } |
            Select-Object -Last 1)[0]
    } catch { return $null }
}

function Wait-ForPeerFileCount($peer, $want, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $count = Get-PeerFileCount $peer
        if ($count -ge $want) { return $count }
        if ((Get-Date) -ge $deadline) { return $count }
        Start-Sleep -Seconds 3
    }
}

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

function Write-Evidence($label, $peers) {
    Say "evidence for $label" 'Yellow'
    foreach ($peer in $peers) {
        foreach ($pattern in @(
            '[HOLLOW-AT-REST]',
            'at_rest',
            'file key missing',
            '[HOLLOW-FILE]',
            'FileHeader received',
            'Requesting file',
            $script:FleetVars.RUN)) {
            $hits = @(Get-PeerLogLines $peer $pattern)
            if ($hits.Count -eq 0) { continue }
            Write-Host "  --- $peer :: $pattern ($($hits.Count)) ---" -ForegroundColor DarkYellow
            foreach ($line in ($hits | Select-Object -Last 12)) { Write-Host "     $line" -ForegroundColor DarkGray }
        }
    }
}

# --------------------------------------------------------------------------
# The three fixtures
# --------------------------------------------------------------------------

function Get-FleetFfmpeg { return (Join-Path $script:FleetStageRoot 'a\ffmpeg.exe') }

# The encoders an ffmpeg has, by kind ('V' or 'A'). The bundled build is a
# minimal one and the app ships it, so what IT can do is the only thing that
# matters at runtime; this is printed rather than assumed, because "ffmpeg is on
# the machine" has never been the same statement as "the app's ffmpeg can do
# this".
function Get-FfmpegEncoders($exe, $kind) {
    if (-not (Test-Path $exe)) { return @() }
    $lines = @(& $exe -hide_banner -encoders 2>&1)
    $found = @()
    foreach ($line in $lines) {
        # The legend line (" V..... = Video") has the same shape as an entry.
        if ("$line" -match "^\s*$kind\S{5}\s+(\S+)" -and $Matches[1] -ne '=') { $found += $Matches[1] }
    }
    return $found
}

function Test-FfmpegHasFilter($exe, $filter) {
    $lines = @(& $exe -hide_banner -filters 2>&1)
    foreach ($line in $lines) { if ("$line" -match "\b$filter\b") { return $true } }
    return $false
}

# An ffmpeg that can SYNTHESISE a fixture: it needs the lavfi source filter and
# one of the wanted encoders. The bundled build is tried first and never wins
# (it has no filters at all), which is the point of trying it.
function Select-FixtureFfmpeg($kind, $filter, $wanted) {
    foreach ($binary in @((Get-FleetFfmpeg), 'ffmpeg', 'C:\ffmpeg\bin\ffmpeg.exe')) {
        $exe = $binary
        if ($binary -eq 'ffmpeg') {
            $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue
            if (-not $onPath) { continue }
            $exe = $onPath.Source
        } elseif (-not (Test-Path $exe)) { continue }
        if (-not (Test-FfmpegHasFilter $exe $filter)) { continue }
        $encoders = Get-FfmpegEncoders $exe $kind
        foreach ($candidate in $wanted) {
            if ($encoders -contains $candidate) {
                return [pscustomobject]@{ exe = $exe; encoder = $candidate }
            }
        }
    }
    return $null
}

function New-MarkerPng($path, $marker) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap 480, 320
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(24, 28, 40))
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 220, 180))
        $graphics.FillEllipse($brush, 40, 40, 240, 240)
        $brush.Dispose()
        $font = New-Object System.Drawing.Font 'Consolas', 18
        $text = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $graphics.DrawString($marker, $font, $text, 20, 280)
        $font.Dispose()
        $text.Dispose()
    } finally {
        $graphics.Dispose()
    }
    $memory = New-Object System.IO.MemoryStream
    $bitmap.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $png = $memory.ToArray()
    $memory.Dispose()

    # A tEXt chunk carrying the marker, spliced in after IHDR. System.Drawing
    # cannot write one, and the point of the chunk is that the marker sits in
    # the PNG's own bytes rather than only in the pixels.
    $keyword = [System.Text.Encoding]::ASCII.GetBytes('Comment')
    $value = [System.Text.Encoding]::ASCII.GetBytes($marker)
    $payload = New-Object byte[] ($keyword.Length + 1 + $value.Length)
    [Array]::Copy($keyword, 0, $payload, 0, $keyword.Length)
    $payload[$keyword.Length] = 0
    [Array]::Copy($value, 0, $payload, $keyword.Length + 1, $value.Length)
    $type = [System.Text.Encoding]::ASCII.GetBytes('tEXt')
    $crcInput = New-Object byte[] ($type.Length + $payload.Length)
    [Array]::Copy($type, 0, $crcInput, 0, $type.Length)
    [Array]::Copy($payload, 0, $crcInput, $type.Length, $payload.Length)
    $crc = Get-Crc32 $crcInput
    $chunk = New-Object System.Collections.Generic.List[byte]
    $chunk.AddRange([byte[]](Get-BigEndianBytes $payload.Length))
    $chunk.AddRange($type)
    $chunk.AddRange($payload)
    $chunk.AddRange([byte[]](Get-BigEndianBytes $crc))

    # 8 byte signature + 25 byte IHDR chunk.
    $insertAt = 8 + 25
    $out = New-Object System.Collections.Generic.List[byte]
    $out.AddRange([byte[]]($png[0..($insertAt - 1)]))
    $out.AddRange([byte[]]$chunk)
    $out.AddRange([byte[]]($png[$insertAt..($png.Length - 1)]))
    [System.IO.File]::WriteAllBytes($path, $out.ToArray())
    Say "wrote $path ($((Get-Item $path).Length) bytes, tEXt=$marker)"
}

function Get-BigEndianBytes([uint32]$value) {
    return @([byte](($value -shr 24) -band 0xFF), [byte](($value -shr 16) -band 0xFF),
             [byte](($value -shr 8) -band 0xFF), [byte]($value -band 0xFF))
}

# All of it in Int64 with an explicit mask: Windows PowerShell parses
# 0xFFFFFFFF as Int32 -1, so the obvious uint32 spelling of a CRC does not even
# cast.
function Get-Crc32($bytes) {
    if (-not $script:Crc32Table) {
        $table = New-Object 'int64[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            [int64]$c = $i
            for ($k = 0; $k -lt 8; $k++) {
                if (($c -band 1) -ne 0) { $c = (3988292384 -bxor ($c -shr 1)) -band 4294967295 }
                else { $c = ($c -shr 1) -band 4294967295 }
            }
            $table[$i] = $c
        }
        $script:Crc32Table = $table
    }
    [int64]$crc = 4294967295
    foreach ($byte in $bytes) {
        $index = [int](($crc -bxor [int64]$byte) -band 255)
        $crc = ($script:Crc32Table[$index] -bxor ($crc -shr 8)) -band 4294967295
    }
    return [uint32](($crc -bxor 4294967295) -band 4294967295)
}

function New-MarkerBin($path, $marker, $sizeBytes) {
    $unit = [System.Text.Encoding]::ASCII.GetBytes("$marker`n")
    $bytes = New-Object byte[] $sizeBytes
    for ($i = 0; $i -lt $sizeBytes; $i += $unit.Length) {
        $take = [Math]::Min($unit.Length, $sizeBytes - $i)
        [Array]::Copy($unit, 0, $bytes, $i, $take)
    }
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Say "wrote $path ($sizeBytes bytes of the repeated marker)"
}

# A 3 s clip whose `comment` metadata is the marker. The bundled ffmpeg cannot
# encode video (see the header), so the clip is made with a full ffmpeg and then
# DECODE-VERIFIED with the bundled one, which is the half that matters: the app
# decodes with what it ships.
function New-MarkerMp4($path, $marker) {
    $fleetFfmpeg = Get-FleetFfmpeg
    Say "bundled ffmpeg video encoders: $((Get-FfmpegEncoders $fleetFfmpeg 'V') -join ', ')"
    $maker = Select-FixtureFfmpeg 'V' 'testsrc' @('libx264', 'h264', 'mpeg4', 'libvpx-vp9')
    if (-not $maker) {
        throw 'no ffmpeg on this machine can synthesise video, so the MP4 fixture cannot be made.'
    }
    Say "making the clip with $($maker.exe) ($($maker.encoder))"
    $arguments = @(
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=15:duration=3',
        '-c:v', $maker.encoder, '-pix_fmt', 'yuv420p',
        '-metadata', "comment=$marker",
        '-movflags', '+faststart', $path
    )
    & $maker.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $path)) {
        throw "ffmpeg could not write $path (exit $LASTEXITCODE)"
    }
    # The marker has to be in the FILE, not only in the command line: a muxer
    # that dropped the tag would take the plaintext proof with it.
    if (-not (Test-BytesContain $path $marker)) {
        throw "the clip was written but does not carry $marker in its bytes"
    }
    # And the app's own ffmpeg has to be able to read it, which is what the
    # thumbnail pipeline will ask of it.
    # `-f image2` because the bundled build has no webp MUXER, only the encoder.
    $probeOut = "$path.verify.webp"
    & $fleetFfmpeg -hide_banner -loglevel error -y -i $path -frames:v 1 -c:v libwebp -f image2 $probeOut | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $probeOut)) {
        throw "the bundled ffmpeg cannot decode $path, so the app could not either"
    }
    Remove-Item $probeOut -Force -ErrorAction SilentlyContinue
    Say "wrote $path ($((Get-Item $path).Length) bytes, decode-verified with the bundled ffmpeg)"
    return [pscustomobject]@{ encoder = $maker.encoder; maker = $maker.exe }
}

# A 3 s voice note: a sine tone in Opus, with the marker as its Vorbis comment.
# Same shape as the clip and for the same reason - the bundled build has the
# libopus ENCODER and the ogg muxer but no filters, so it cannot synthesise the
# tone; it can decode Opus, and that is what the app does with it.
function New-MarkerOgg($path, $marker) {
    $fleetFfmpeg = Get-FleetFfmpeg
    Say "bundled ffmpeg audio encoders: $((Get-FfmpegEncoders $fleetFfmpeg 'A') -join ', ')"
    $maker = Select-FixtureFfmpeg 'A' 'sine' @('libopus', 'opus')
    if (-not $maker) {
        throw 'no ffmpeg on this machine can synthesise audio, so the OGG fixture cannot be made.'
    }
    Say "making the voice note with $($maker.exe) ($($maker.encoder))"
    $arguments = @(
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=3',
        '-c:a', $maker.encoder, '-b:a', '32k',
        '-metadata', "comment=$marker", $path
    )
    & $maker.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $path)) {
        throw "ffmpeg could not write $path (exit $LASTEXITCODE)"
    }
    if (-not (Test-BytesContain $path $marker)) {
        throw "the voice note was written but does not carry $marker in its bytes"
    }
    $probeOut = "$path.verify.wav"
    & $fleetFfmpeg -hide_banner -loglevel error -y -i $path -c:a pcm_s16le -f wav $probeOut | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $probeOut)) {
        throw "the bundled ffmpeg cannot decode $path, so the app could not either"
    }
    Remove-Item $probeOut -Force -ErrorAction SilentlyContinue
    Say "wrote $path ($((Get-Item $path).Length) bytes, decode-verified with the bundled ffmpeg)"
    return [pscustomobject]@{ encoder = $maker.encoder; maker = $maker.exe }
}

# --------------------------------------------------------------------------
# Sending
# --------------------------------------------------------------------------

function Open-Dm($peer, $friendName) {
    Step $peer @{ op = 'wait_for'; target = "semantics:$friendName"; timeout_ms = 60000 }
    Step $peer @{ op = 'tap'; target = "semantics:$friendName" }
    Step $peer @{ op = 'wait'; ms = 1500 }
    Step $peer @{ op = 'wait_for'; target = 'hint:Type a message...'; timeout_ms = 30000 }
}

# Attach, caption and send into the OPEN composer. The composer is tapped
# first: enter_text on an unfocused field reports success into nothing, which is
# worst right after a reconnect, when the pane is being rebuilt.
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
    Step $peer @{ op = 'wait_for'; target = 'hint:Message #general'; timeout_ms = 30000 }
    Step $peer @{ op = 'attach_file'; path = $path }
    Step $peer @{ op = 'tap'; target = 'hint:Message #general' }
    Step $peer @{ op = 'enter_text'; target = 'hint:Message #general'; value = $caption }
    Step $peer @{ op = 'key'; value = 'enter' }
    Step $peer @{ op = 'wait_for'; target = "text:$caption"; timeout_ms = 60000 }
}

function Invoke-FriendHandshake {
    # The steps of probe_scenarios/fleet/friend_dm.json. The Friends manager is
    # closed by its OWN control, scoped to the manager: a bare semantics:Close
    # is the window title bar's button and that tap ends the process.
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
    Step b @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step b @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
}

function Remove-FleetServer($serverName) {
    Step a @{ op = 'wait_for'; target = "server:$serverName"; timeout_ms = 60000 }
    Step a @{ op = 'right_click'; target = "server:$serverName" }
    Step a @{ op = 'tap'; target = 'menu > text:Server settings' }
    Step a @{ op = 'reveal'; target = 'text:Delete server'; index = 0 }
    Step a @{ op = 'tap'; target = 'text:Delete server'; index = 0 }
    # index 1: index 0 is the dialog's TITLE, and tapping a title silently does
    # nothing and PASSES.
    Step a @{ op = 'tap'; target = 'dialog > text:Delete server'; index = 0 }
    Step a @{ op = 'wait_for'; gone = "server:$serverName"; timeout_ms = 60000 }
}

# --------------------------------------------------------------------------
# Phase S: seed a plaintext data directory
# --------------------------------------------------------------------------

function Invoke-SeedPhase {
    Set-GateList @(
        'S1 a and b are friends and DM both ways',
        'S2 three files land in the DM and reach b',
        'S3 b joins a server and the same three files land in #general',
        'S4 the seed is on disk with a manifest',
        'S5 the marker is READABLE in b''s files (the seed is plaintext)'
    )

    $runTag = $script:FleetVars.RUN
    $marker = "HOLLOW-PLAIN-$runTag"
    $server = "atrest-$runTag"
    $script:FleetVars['SERVER'] = $server
    $script:FleetVars['MARKER'] = $marker

    New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null
    $pngPath = Join-Path $FixtureDir "plain-$runTag.png"
    $binPath = Join-Path $FixtureDir "plain-$runTag.bin"
    $mp4Path = Join-Path $FixtureDir "plain-$runTag.mp4"
    New-MarkerPng $pngPath $marker
    New-MarkerBin $binPath $marker 614400
    $clip = New-MarkerMp4 $mp4Path $marker

    if ($KeepIdentities) {
        Say 'keeping the identities that are already live' 'Yellow'
        if ((Get-LivePeers).Count -eq 0) {
            Invoke-FleetScript @('-Live', '-Peers', 'a,b')
            foreach ($peer in $journeyPeers) { $script:FleetConsumed[$peer] = 0 }
        }
    } else {
        # c is onboarded FIRST and left closed: -Onboard stops the fleet when it
        # is done stamping, so doing it after a and b are live would take them
        # down with it.
        Say 'minting a fresh identity for c and leaving it closed'
        Invoke-FleetScript @('-Stop')
        Invoke-FleetScript @('-Onboard', '-Fresh', '-Peers', 'c')
        Start-FreshFleet $journeyPeers
    }

    $live = Get-LivePeers
    foreach ($peer in $journeyPeers) {
        if ($live -notcontains $peer) {
            throw "peer '$peer' is not running (live: $($live -join ', '))"
        }
    }
    Say "run tag $runTag, marker $marker, server $server"

    $failure = $null
    $serverCreated = $false
    try {
        Wait-ForConnected a | Out-Null
        Wait-ForConnected b | Out-Null
        Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
        Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

        Say '1/5 a and b become friends and DM both ways'
        Invoke-FriendHandshake
        Open-Dm a 'probe-b'
        Step a @{ op = 'tap'; target = 'hint:Type a message...' }
        Step a @{ op = 'enter_text'; target = 'hint:Type a message...'; value = 'dm from a ${RUN}' }
        Step a @{ op = 'key'; value = 'enter' }
        Step a @{ op = 'wait_for'; target = 'text:dm from a ${RUN}'; timeout_ms = 30000 }
        Step b @{ op = 'wait_for'; target = 'text:dm from a ${RUN}'; timeout_ms = 60000 }
        Open-Dm b 'probe-a'
        Step b @{ op = 'tap'; target = 'hint:Type a message...' }
        Step b @{ op = 'enter_text'; target = 'hint:Type a message...'; value = 'dm from b ${RUN}' }
        Step b @{ op = 'key'; value = 'enter' }
        Step b @{ op = 'wait_for'; target = 'text:dm from b ${RUN}'; timeout_ms = 30000 }
        Step a @{ op = 'wait_for'; target = 'text:dm from b ${RUN}'; timeout_ms = 60000 }
        Set-Gate 'S1 a and b are friends and DM both ways' 'PASS'

        Say '2/5 a sends the PNG, the .bin and the MP4 in the DM'
        Send-DmFile a $pngPath 'seed png ${RUN}'
        Send-DmFile a $binPath 'seed bin ${RUN}'
        Send-DmFile a $mp4Path 'seed mp4 ${RUN}'
        Step a @{ op = 'shot'; name = "atrest-$runTag-a-dm-sent" }
        foreach ($caption in @('seed png ${RUN}', 'seed bin ${RUN}', 'seed mp4 ${RUN}')) {
            Step b @{ op = 'wait_for'; target = "text:$caption"; timeout_ms = 180000 }
        }
        # The bytes, not just the cards: the .bin and the MP4 cross the wire
        # unchanged, so a content match is exact for both.
        $bBin = Wait-ForPeerFileByHash b $binPath 'the DM .bin' 180
        $bMp4 = Wait-ForPeerFileByHash b $mp4Path 'the DM MP4' 180
        Step b @{ op = 'shot'; name = "atrest-$runTag-b-dm-received" }
        Invoke-SoftStep b @{ op = 'dump'; name = 'atrest-seed-dm' } | Out-Null
        if (-not $bBin -or -not $bMp4) {
            Set-Gate 'S2 three files land in the DM and reach b' 'FAIL'
            throw "b never received the DM bytes (bin=$([bool]$bBin) mp4=$([bool]$bMp4))"
        }
        Set-Gate 'S2 three files land in the DM and reach b' 'PASS'

        Say '3/5 a creates a server, b joins, and the same three files land in #general'
        Step a @{ op = 'tap'; target = 'semantics:Create a server' }
        Step a @{ op = 'enter_text'; target = 'hint:My Awesome Server'; value = $server }
        Step a @{ op = 'tap'; target = 'text:Create'; index = 0 }
        Step a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }
        $serverCreated = $true
        Step a @{ op = 'open_server'; name = $server }
        Step a @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }
        Step a @{ op = 'capture'; from = 'provider'; key = 'selectedServer'; as = 'SERVER_ID' }

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

        # A message each way first: the cheapest proof that the MLS group formed,
        # so a missing file later is a file problem.
        Step a @{ op = 'tap'; target = 'hint:Message #general' }
        Step a @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'hello from a ${RUN}' }
        Step a @{ op = 'key'; value = 'enter' }
        Step a @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 30000 }
        Step b @{ op = 'wait_for'; target = 'text:hello from a ${RUN}'; timeout_ms = 120000 }

        Send-ChannelFile a $pngPath 'chan png ${RUN}'
        Send-ChannelFile a $binPath 'chan bin ${RUN}'
        Send-ChannelFile a $mp4Path 'chan mp4 ${RUN}'
        Step a @{ op = 'shot'; name = "atrest-$runTag-a-chan-sent" }
        foreach ($caption in @('chan png ${RUN}', 'chan bin ${RUN}', 'chan mp4 ${RUN}')) {
            Step b @{ op = 'wait_for'; target = "text:$caption"; timeout_ms = 240000 }
        }
        # Six files: three in the DM and three in the channel. The image is
        # re-encoded to WebP on the way out, so its copy cannot be matched by
        # hash; the count is what says all six landed.
        $count = Wait-ForPeerFileCount b 6 240
        Step b @{ op = 'shot'; name = "atrest-$runTag-b-chan-received" }
        $rowsB = Write-ChannelRows b 'b after the channel sends'
        $rowsA = Write-ChannelRows a 'a after the channel sends'
        Invoke-SoftStep b @{ op = 'dump'; name = 'atrest-seed-channel' } | Out-Null
        if ($count -lt 6) {
            Set-Gate 'S3 b joins a server and the same three files land in #general' 'FAIL'
            throw "b holds $count files on disk, expected at least 6"
        }
        Set-Gate 'S3 b joins a server and the same three files land in #general' 'PASS'

        # ---- the seed itself -------------------------------------------------
        Say '4/5 closing a and b and copying both data directories'
        Stop-Peer b
        Stop-Peer a
        Start-Sleep -Seconds 2

        if (Test-Path $seedRoot) { Remove-Item $seedRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $seedRoot -Force | Out-Null
        foreach ($peer in $journeyPeers) {
            Copy-Mirror (Get-PeerDataDir $peer) (Join-Path $seedRoot $peer)
        }
        # c never ran, but its fixture is the identity phase U needs for the
        # late joiner, and a stray -Onboard from another journey would take it.
        $cFixture = Join-Path $fixtureRoot 'c'
        if (Test-Path $cFixture) { Copy-Mirror $cFixture (Join-Path $seedRoot 'c_fixture') }
        New-Item -ItemType Directory -Path (Join-Path $seedRoot 'fixtures') -Force | Out-Null
        Copy-Item (Join-Path $FixtureDir '*') (Join-Path $seedRoot 'fixtures') -Force
        Set-Content -Path (Join-Path $seedRoot 'b-channel-rows.txt') -Value $rowsB -Encoding UTF8
        Set-Content -Path (Join-Path $seedRoot 'a-channel-rows.txt') -Value $rowsA -Encoding UTF8
        # Phase U's build wipes every probe output directory, and the seed's
        # screenshots are the only picture of what the plaintext run looked like.
        $shots = Join-Path $seedRoot 'shots'
        New-Item -ItemType Directory -Path $shots -Force | Out-Null
        foreach ($peer in $journeyPeers) {
            Get-ChildItem (Join-Path $script:FleetOutRoot $peer) -File -Filter 'atrest-*' -ErrorAction SilentlyContinue |
                ForEach-Object { Copy-Item $_.FullName (Join-Path $shots $_.Name) -Force -ErrorAction SilentlyContinue }
        }

        $scanA = Get-DataRootScan (Join-Path $seedRoot 'a') $marker
        $scanB = Get-DataRootScan (Join-Path $seedRoot 'b') $marker
        $markerFilesB = @($scanB | Where-Object { $_.hasMarker })
        $manifest = [ordered]@{
            run = $runTag
            createdAt = (Get-Date -Format o)
            marker = $marker
            server = $server
            serverId = $script:FleetVars['SERVER_ID']
            invite = $script:FleetVars['INVITE']
            peerA = $script:FleetVars['PEER_A']
            peerB = $script:FleetVars['PEER_B']
            fixtures = [ordered]@{
                png = @{ path = $pngPath; sha256 = (Get-FileHash $pngPath -Algorithm SHA256).Hash; size = (Get-Item $pngPath).Length }
                bin = @{ path = $binPath; sha256 = (Get-FileHash $binPath -Algorithm SHA256).Hash; size = (Get-Item $binPath).Length }
                mp4 = @{ path = $mp4Path; sha256 = (Get-FileHash $mp4Path -Algorithm SHA256).Hash; size = (Get-Item $mp4Path).Length; encoder = $clip.encoder; madeWith = $clip.maker }
            }
            a = @{ files = $scanA }
            b = @{ files = $scanB }
            markerFoundInB = @($markerFilesB | ForEach-Object { $_.rel })
            # Video posters land in files/ beside the clip they belong to. They
            # are stored content like any other file, so the migration has to
            # take them and the gates have to count them; they are listed here
            # because their number is the one thing phase U cannot derive from
            # what it sent.
            thumbnailsInB = @($scanB | Where-Object { $_.rel -like 'files\*.thumb.webp' } | ForEach-Object { $_.rel })
            thumbnailsInA = @($scanA | Where-Object { $_.rel -like 'files\*.thumb.webp' } | ForEach-Object { $_.rel })
        }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $seedManifestPath -Encoding UTF8
        Say "seed written to $seedRoot" 'Green'
        Set-Gate 'S4 the seed is on disk with a manifest' 'PASS'

        # ---- the honesty half -------------------------------------------------
        Say '5/5 proving the seed is plaintext'
        $binHit = @($markerFilesB | Where-Object { $_.rel -like 'files\*' })
        foreach ($entry in $markerFilesB) {
            Write-Host "     marker in b: $($entry.rel) ($($entry.size) bytes, magic '$($entry.magic)')" -ForegroundColor Gray
        }
        if ($binHit.Count -lt 2) {
            Set-Gate 'S5 the marker is READABLE in b''s files (the seed is plaintext)' 'FAIL'
            Add-Note "only $($binHit.Count) of b's stored files carry the marker, expected at least 2 (the .bin and the MP4, in the DM and again in the channel)"
            throw 'S5 failed: the seed cannot be shown to be plaintext'
        }
        $encrypted = @($scanB | Where-Object { $_.magic -eq 'HFE1' })
        if ($encrypted.Count -gt 0) {
            Add-Note "$($encrypted.Count) of b's files already start with HFE1, so this build is NOT the plaintext one"
            Set-Gate 'S5 the marker is READABLE in b''s files (the seed is plaintext)' 'FAIL'
            throw 'S5 failed: the seed build already encrypts'
        }
        Set-Gate 'S5 the marker is READABLE in b''s files (the seed is plaintext)' 'PASS'
        Say "marker readable in $($binHit.Count) of b's stored files" 'Green'
    } catch {
        $failure = $_
        Say "FAILED: $($_.Exception.Message)" 'Red'
        $unreached = Set-FirstUnreachedGateFailed
        if ($unreached) { Say "first gate without a verdict: $unreached" 'Red' }
        if ($serverCreated) {
            Add-Note "the server $server still exists. Run: powershell -File scripts\fleet_at_rest.ps1 -AbortSeed"
        }
    }

    Write-GateReport "phase S gates for run $runTag"
    Say "server $server (kept ON PURPOSE: phase U joins it with c and deletes it there)" 'Yellow'
    Say "seed: $seedRoot" 'DarkCyan'
    if ($failure) { throw $failure }
    Say 'PASS' 'Green'
}

# --------------------------------------------------------------------------
# Abort: give a seed up and take its server with it
# --------------------------------------------------------------------------

function Invoke-AbortSeed {
    if (-not (Test-Path $seedManifestPath)) {
        throw "no seed manifest at $seedManifestPath, so there is nothing to abort."
    }
    $manifest = Get-Content $seedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $server = $manifest.server
    if ($manifest.serverDeletedAt) {
        Say "nothing to abort: $server was already deleted at $($manifest.serverDeletedAt)" 'Yellow'
        return
    }
    Say "aborting the seed for run $($manifest.run): deleting server $server" 'Yellow'
    # a's OWN data directory is the only thing that can delete a's server, and
    # the seed copy is that directory.
    Stop-Fleet-IfRunning
    Restore-SeedInto 'a'
    Start-PeerProcess 'a'
    Wait-ForConnected a | Out-Null
    Remove-FleetServer $server
    Set-SeedServerGone 'an abort'
    Say 'server deleted' 'Green'
    if (-not $KeepUp) { Invoke-FleetScript @('-Stop') }
}

function Stop-Fleet-IfRunning {
    $live = @(Get-LivePeers)
    if ($live.Count -gt 0) { Invoke-FleetScript @('-Stop') }
}

function Restore-SeedInto($peer) {
    $source = Join-Path $seedRoot $peer
    if (-not (Test-Path $source)) { throw "no seed for peer '$peer' at $source" }
    if (Get-PeerProcess $peer) { throw "peer $peer is still running; the seed cannot be restored under it" }
    Copy-Mirror $source (Get-PeerDataDir $peer)
    Say "restored the seed data directory for $peer"
}

# --------------------------------------------------------------------------
# Phase U: the gates
# --------------------------------------------------------------------------

# Files the migration deliberately leaves alone: in-flight transfer temps (they
# are already ciphertext on the wire) and anything that is not stored content.
function Test-MigrationCandidate($relativePath) {
    $name = Split-Path -Leaf $relativePath
    if ($name.StartsWith('.')) { return $false }
    return $true
}

# Every stored content file under a data root, which is what the migration gate
# counts: files/ and vault_cache/ and nothing else.
function Get-StoredContentFiles($peer) {
    $root = Get-PeerDataDir $peer
    $found = @()
    foreach ($sub in @('files', 'vault_cache')) {
        $dir = Join-Path $root $sub
        if (-not (Test-Path $dir)) { continue }
        foreach ($file in @(Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if (-not (Test-MigrationCandidate $file.Name)) { continue }
            $found += $file
        }
    }
    return $found
}

# Where the marker is still readable under a data root. The logs are allowed to
# name a file; nothing else may carry its contents.
#
# In-flight transfer temps are reported (Get-MarkerTemps) rather than failed on:
# a `.stream_shard_*.tmp` is vault shard ciphertext that stays raw by design, so
# a hit there is a fact worth printing and not a verdict.
function Get-MarkerLeaks($peer, $marker) {
    $root = Get-PeerDataDir $peer
    $leaks = @()
    foreach ($entry in (Get-DataRootScan $root $marker)) {
        if (-not $entry.hasMarker) { continue }
        if ($entry.rel -like '*hollow_debug.log' -or $entry.rel -like '*hollow_crash.log') { continue }
        if (-not (Test-MigrationCandidate (Split-Path -Leaf $entry.rel))) { continue }
        $leaks += $entry
    }
    return $leaks
}

function Get-MarkerTemps($peer, $marker) {
    $root = Get-PeerDataDir $peer
    $temps = @()
    foreach ($entry in (Get-DataRootScan $root $marker)) {
        if (-not $entry.hasMarker) { continue }
        if (Test-MigrationCandidate (Split-Path -Leaf $entry.rel)) { continue }
        $temps += $entry
    }
    return $temps
}

function Invoke-UpgradePhase {
    Set-GateList @(
        'G1 migration: every stored file is HFE1 and the marker is gone',
        'G2 render after migration: image, file card and video all work',
        'G3 fresh receive: new files are HFE1 and the marker never lands',
        'G6 voice note: the audio card plays from the protected copy',
        'G4 serve after migration: c is served the seed PNG and stores it HFE1',
        'G5 export: the plaintext comes back out byte for byte',
        'C  cleanup: no fleet server left on the relay'
    )

    if (-not (Test-Path $seedManifestPath)) {
        throw "no seed at $seedManifestPath. Run phase S first: powershell -File scripts\fleet_at_rest.ps1 -Seed"
    }
    $manifest = Get-Content $seedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $seedMarker = $manifest.marker
    $server = $manifest.server
    $script:FleetVars['INVITE'] = $manifest.invite
    $runTag = $script:FleetVars.RUN
    # A SECOND marker for the files this phase sends: the seed's marker proves
    # the migration, this one proves a fresh receive never touches the disk in
    # the clear.
    $freshMarker = "HOLLOW-FRESH-$runTag"
    Say "seed run $($manifest.run), marker $seedMarker, server $server"
    Say "this run $runTag, fresh marker $freshMarker"

    $seedPng = Join-Path $seedRoot "fixtures\plain-$($manifest.run).png"
    $seedBinName = Split-Path -Leaf $manifest.fixtures.bin.path
    $seedMp4Name = Split-Path -Leaf $manifest.fixtures.mp4.path
    $seedPngName = Split-Path -Leaf $manifest.fixtures.png.path
    # The receiver's image copy is a WebP re-encode on disk, but the file ROW
    # keeps the name that was sent, so that is what the card shows and what the
    # export op has to be asked for.
    $seedImageCardName = $seedPngName

    New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null
    $freshPng = Join-Path $FixtureDir "fresh-$runTag.png"
    $freshBin = Join-Path $FixtureDir "fresh-$runTag.bin"
    $freshMp4 = Join-Path $FixtureDir "fresh-$runTag.mp4"
    $freshOgg = Join-Path $FixtureDir "fresh-$runTag.ogg"
    $freshOggName = Split-Path -Leaf $freshOgg
    New-MarkerPng $freshPng $freshMarker
    New-MarkerBin $freshBin $freshMarker 614400
    New-MarkerMp4 $freshMp4 $freshMarker | Out-Null
    $voiceClip = New-MarkerOgg $freshOgg $freshMarker

    if (-not $SkipBuild) {
        Say 'building and staging a,b,c'
        # NEVER wrapped in 2>&1 | Tee-Object: under PS 5.1 flutter's CMake
        # deprecation warning becomes a terminating NativeCommandError and the
        # build dies after the DLL and before the staging. -Build also boots the
        # peers from their fixtures, which is why the fleet is stopped again
        # before the seed is restored over them.
        Invoke-FleetScript @('-Build', '-Peers', 'a,b,c')
    }
    Invoke-FleetScript @('-Stop')

    Say 'restoring the seed data directories (no fixture reset)'
    Restore-SeedInto 'a'
    Restore-SeedInto 'b'
    $cSeedFixture = Join-Path $seedRoot 'c_fixture'
    if (Test-Path $cSeedFixture) {
        Copy-Mirror $cSeedFixture (Get-PeerDataDir 'c')
    } else {
        $cFixture = Join-Path $fixtureRoot 'c'
        if (-not (Test-Path $cFixture)) { throw "c has no identity to launch with (looked in $cSeedFixture and $cFixture)" }
        Copy-Mirror $cFixture (Get-PeerDataDir 'c')
    }

    $failure = $null
    $serverDeleted = $false
    try {
        # ---- G1: the migration ------------------------------------------------
        Say '1/6 launching a and b on the seeded directories and watching the sweep'
        Start-PeerProcess 'a'
        Start-PeerProcess 'b'
        # The clock starts once both are up: the sweep cannot run before the
        # node does, and a boot is a third of the budget.
        $startedAt = Get-Date
        $deadline = $startedAt.AddSeconds(60)
        $pending = $null
        while ($true) {
            $pending = @()
            foreach ($peer in $journeyPeers) {
                $files = Get-StoredContentFiles $peer
                if ($files.Count -eq 0) { $pending += "$peer has no stored files at all" ; continue }
                foreach ($file in $files) {
                    if (-not (Test-Hfe1 $file.FullName)) { $pending += "$peer :: $($file.Name)" }
                }
            }
            if ($pending.Count -eq 0) { break }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 2
        }
        $tookMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
        foreach ($peer in $journeyPeers) {
            $files = Get-StoredContentFiles $peer
            $thumbs = @($files | Where-Object { $_.Name -like '*.thumb.webp' })
            $seeded = if ($peer -eq 'b') { @($manifest.thumbnailsInB).Count } else { @($manifest.thumbnailsInA).Count }
            Say "$peer holds $($files.Count) stored files, $($thumbs.Count) of them video posters (the seed had $seeded)" 'DarkCyan'
        }
        $leaks = @()
        foreach ($peer in $journeyPeers) {
            foreach ($leak in (Get-MarkerLeaks $peer $seedMarker)) {
                $leaks += "$peer :: $($leak.rel)"
            }
            foreach ($temp in (Get-MarkerTemps $peer $seedMarker)) {
                Add-Note "in-flight temp still carries the marker (raw by design, not a verdict): $peer :: $($temp.rel)"
            }
        }

        Wait-ForConnected a | Out-Null
        Wait-ForConnected b | Out-Null
        # The Storage Manager's own word for it. Reported next to the disk
        # evidence rather than instead of it: the files are the fact, the line
        # is what a user is told about them.
        Step b @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
        Step b @{ op = 'tap'; target = 'text:Files & Storage'; index = 0 }
        $protected = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:Protected'; timeout_ms = 60000 }
        Step b @{ op = 'shot'; name = "atrest-$runTag-b-storage" }
        Step b @{ op = 'key'; value = 'escape' }
        $settingsGone = Invoke-SoftStep b @{ op = 'wait_for'; gone = 'text:Files & Storage'; timeout_ms = 10000 }
        if (-not $settingsGone.ok) {
            # Escape reaches nothing once focus has left the dialog, and the
            # barrier then covers everything the next gate wants to tap. The
            # scope matters: a bare semantics:Close is the window title bar's
            # button, and that tap ends the process.
            Invoke-SoftStep b @{ op = 'tap'; target = 'type:_UserSettingsContent > semantics:Close'; index = 0 } | Out-Null
            Step b @{ op = 'wait_for'; gone = 'text:Files & Storage'; timeout_ms = 15000 }
        }

        if ($pending.Count -gt 0 -or $leaks.Count -gt 0) {
            Set-Gate 'G1 migration: every stored file is HFE1 and the marker is gone' 'FAIL'
            foreach ($item in ($pending | Select-Object -First 10)) { Add-Note "not encrypted: $item" }
            foreach ($item in ($leaks | Select-Object -First 10)) { Add-Note "marker still readable: $item" }
            Write-Evidence 'G1' $journeyPeers
            throw "G1 failed: $($pending.Count) file(s) not encrypted, $($leaks.Count) marker leak(s)"
        }
        if (-not $protected.ok) {
            Set-Gate 'G1 migration: every stored file is HFE1 and the marker is gone' 'WARN'
            Add-Note 'every stored file is HFE1 and the marker is gone, but the Storage Manager never said "Protected"'
        } else {
            Set-Gate 'G1 migration: every stored file is HFE1 and the marker is gone' 'PASS'
        }
        Say "migration settled in ${tookMs}ms" 'Green'

        # ---- G2: the migrated files still render -------------------------------
        Say '2/6 b opens the DM: image, file card and video'
        Open-Dm b 'probe-a'
        Step b @{ op = 'wait_for'; target = "text:seed png $($manifest.run)"; timeout_ms = 60000 }
        $image = Invoke-SoftStep b @{ op = 'wait_for'; target = 'type:AttachmentImage'; timeout_ms = 60000 }
        Step b @{ op = 'shot'; name = "atrest-$runTag-b-dm-after-migration" }
        $card = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$seedBinName"; timeout_ms = 30000 }
        $size = Invoke-SoftStep b @{ op = 'wait_for'; target = 'contains:600'; timeout_ms = 15000 }

        # The video needs a tap: the player only exists while the bubble plays,
        # and until then the bubble is a poster.
        $play = Invoke-SoftStep b @{ op = 'tap'; target = "semantics:Play $seedMp4Name"; index = 0 }
        $video = Invoke-SoftStep b @{ op = 'video_state'; timeout_ms = 45000 }
        Step b @{ op = 'shot'; name = "atrest-$runTag-b-video-after-migration" }
        $videoOk = $false
        if ($video.ok -and $video.message -match 'initialized=True' -and $video.message -match 'durationMs=(\d+)') {
            $videoOk = ([int]$Matches[1] -gt 0)
        }
        Invoke-SoftStep b @{ op = 'dump'; name = 'atrest-after-migration' } | Out-Null
        if ($image.ok -and $card.ok -and $videoOk) {
            Set-Gate 'G2 render after migration: image, file card and video all work' 'PASS'
        } else {
            Set-Gate 'G2 render after migration: image, file card and video all work' 'FAIL'
            Add-Note "G2: image=$($image.ok) card=$($card.ok) size=$($size.ok) play=$($play.ok) video=$videoOk ($($video.message))"
            Write-Evidence 'G2' $journeyPeers
            throw 'G2 failed: a migrated attachment did not come back'
        }

        # ---- G3: a fresh receive is never plaintext ----------------------------
        Say '3/6 a sends three NEW files: they must be HFE1 from the first look'
        $before = @(Get-StoredContentFiles b | ForEach-Object { $_.FullName })
        Open-Dm a 'probe-b'
        Send-DmFile a $freshPng 'fresh png ${RUN}'
        Send-DmFile a $freshBin 'fresh bin ${RUN}'
        Send-DmFile a $freshMp4 'fresh mp4 ${RUN}'
        Step a @{ op = 'shot'; name = "atrest-$runTag-a-fresh-sent" }

        # Polled from the moment the cards appear: a file that is written in the
        # clear and encrypted a second later would pass a check that only looked
        # at the end.
        $plaintextSeen = @()
        $freshSeen = @{}
        $freshDeadline = (Get-Date).AddSeconds(180)
        while ((Get-Date) -lt $freshDeadline) {
            foreach ($file in (Get-StoredContentFiles b)) {
                if ($before -contains $file.FullName) { continue }
                if (-not (Test-Hfe1 $file.FullName)) {
                    $plaintextSeen += $file.FullName
                } else {
                    $freshSeen[$file.FullName] = $true
                }
            }
            if ($freshSeen.Count -ge 3) { break }
            Start-Sleep -Milliseconds 400
        }
        foreach ($caption in @("fresh png $runTag", "fresh bin $runTag", "fresh mp4 $runTag")) {
            Invoke-SoftStep b @{ op = 'wait_for'; target = "text:$caption"; timeout_ms = 120000 } | Out-Null
        }
        $freshLeaks = Get-MarkerLeaks b $freshMarker
        foreach ($temp in (Get-MarkerTemps b $freshMarker)) {
            Add-Note "in-flight temp still carries the marker (raw by design, not a verdict): b :: $($temp.rel)"
        }
        $freshImage = Invoke-SoftStep b @{ op = 'wait_for'; target = 'type:AttachmentImage'; timeout_ms = 60000 }
        Step b @{ op = 'shot'; name = "atrest-$runTag-b-fresh-received" }
        # The poll stops at three, and a video thumbnail is written after the
        # clip it belongs to, so the whole directory is read once more at the end.
        $stillPlain = @(Get-StoredContentFiles b | Where-Object { -not (Test-Hfe1 $_.FullName) })
        $freshThumbs = @(Get-StoredContentFiles b | Where-Object { $_.Name -like '*.thumb.webp' })
        Say "b took on $($freshSeen.Count) new files, $($plaintextSeen.Count) of them seen in the clear; $($freshThumbs.Count) video posters on disk, all counted" 'DarkCyan'
        if ($freshSeen.Count -ge 3 -and $plaintextSeen.Count -eq 0 -and $stillPlain.Count -eq 0 -and $freshLeaks.Count -eq 0 -and $freshImage.ok) {
            Set-Gate 'G3 fresh receive: new files are HFE1 and the marker never lands' 'PASS'
        } else {
            Set-Gate 'G3 fresh receive: new files are HFE1 and the marker never lands' 'FAIL'
            Add-Note "G3: new=$($freshSeen.Count) plaintextSightings=$($plaintextSeen.Count) stillPlain=$($stillPlain.Count) leaks=$($freshLeaks.Count) image=$($freshImage.ok)"
            foreach ($item in ($plaintextSeen | Select-Object -First 5)) { Add-Note "seen in the clear: $item" }
            foreach ($item in ($freshLeaks | Select-Object -First 5)) { Add-Note "marker leak: $($item.rel)" }
            Write-Evidence 'G3' $journeyPeers
            throw 'G3 failed: a freshly received file was not protected'
        }

        # ---- G6: a voice note plays off the protected copy ----------------------
        # A player cannot open ciphertext, so this is the loopback server's gate:
        # the bubble asks for a URL, and only falls back to handing the decrypted
        # bytes over when a platform backend refuses one. Which of the two
        # happened is the interesting part, so the line the bubble logs is
        # printed whatever the verdict.
        Say '4/6 a sends a voice note and b plays it'
        Send-DmFile a $freshOgg 'fresh ogg ${RUN}'
        Step a @{ op = 'shot'; name = "atrest-$runTag-a-voice-sent" }
        Step b @{ op = 'wait_for'; target = "text:fresh ogg $runTag"; timeout_ms = 180000 }
        Step b @{ op = 'wait_for'; target = "text:$freshOggName"; timeout_ms = 60000 }
        $voiceFile = Wait-ForPeerFileByExtension b '.ogg' 120
        $voiceEncrypted = ($voiceFile -and (Test-Hfe1 $voiceFile.FullName))
        # The duration probe and the transcode take a moment, and the control
        # reads "Preparing" while they do, so the tap waits for the play label
        # itself rather than for the card.
        $playTarget = "semantics:Play $freshOggName"
        Invoke-SoftStep b @{ op = 'wait_for'; target = $playTarget; timeout_ms = 60000 } | Out-Null
        $playTap = Invoke-SoftStep b @{ op = 'tap'; target = $playTarget; index = 0 }
        $audio = Invoke-SoftStep b @{ op = 'audio_state'; timeout_ms = 60000 }
        Step b @{ op = 'shot'; name = "atrest-$runTag-b-voice-playing" }

        $audioSource = Get-AudioSourceLine b
        if ($audioSource) {
            Say "b's audio bubble reports: $audioSource" 'DarkCyan'
            Add-Note "G6 audio source: $audioSource"
        } else {
            Add-Note 'G6: b never logged an "at_rest audio source=" line, so which path it took is unknown'
        }
        # audio_cache is written fresh by the transcode rather than swept, so it
        # is reported next to the gate rather than inside it.
        $audioCache = Join-Path (Get-PeerDataDir 'b') 'audio_cache'
        if (Test-Path $audioCache) {
            $cached = @(Get-ChildItem $audioCache -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { Test-MigrationCandidate $_.Name })
            $cachedPlain = @($cached | Where-Object { -not (Test-Hfe1 $_.FullName) })
            Add-Note "G6 audio_cache: $($cached.Count) file(s), $($cachedPlain.Count) of them not HFE1"
        }
        $voiceLeaks = Get-MarkerLeaks b $freshMarker
        if ($audio.ok -and $voiceEncrypted -and $voiceLeaks.Count -eq 0) {
            Set-Gate 'G6 voice note: the audio card plays from the protected copy' 'PASS'
        } else {
            Set-Gate 'G6 voice note: the audio card plays from the protected copy' 'FAIL'
            Add-Note "G6: play=$($playTap.ok) audio=$($audio.message) encrypted=$voiceEncrypted leaks=$($voiceLeaks.Count)"
            foreach ($item in ($voiceLeaks | Select-Object -First 5)) { Add-Note "marker leak: $($item.rel)" }
            Write-Evidence 'G6' $journeyPeers
            throw 'G6 failed: the voice note did not play from its protected copy'
        }

        # ---- G4: serving an encrypted copy to a late joiner ---------------------
        # One seed pays for one of these. The run that deletes the server at
        # cleanup stamps the manifest, and a later run on the same seed says so
        # rather than driving a join at a server nobody can admit it to. The
        # restored copies still make G1 real either way: they are the plaintext
        # seed, whatever became of the server.
        if ($manifest.serverDeletedAt) {
            Say "5/6 skipping the late joiner: seed server no longer exists (deleted $($manifest.serverDeletedAt))" 'Yellow'
            Set-Gate 'G4 serve after migration: c is served the seed PNG and stores it HFE1' 'SKIPPED'
            Add-Note "G4 skipped: seed server no longer exists (deleted at $($manifest.serverDeletedAt) by $($manifest.serverDeletedBy)). Re-seed to drive it again."
        } else {
            Say '5/6 c joins the server and asks for the seed PNG'
            Start-PeerProcess 'c'
            Wait-ForConnected c | Out-Null
            Step c @{ op = 'tap'; target = 'semantics:Create a server' }
            Step c @{ op = 'enter_text'; target = 'hint:Invite link or server ID'; value = '${INVITE}' }
            Step c @{ op = 'tap'; target = 'text:Join'; index = 0 }
            Step c @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 180000 }
            Step c @{ op = 'open_server'; name = $server }
            Step c @{ op = 'open_channel'; name = 'general' }
            Step a @{ op = 'open_server'; name = $server }
            Step a @{ op = 'open_channel'; name = 'general' }
            Step c @{ op = 'wait_for'; target = "text:chan png $($manifest.run)"; timeout_ms = 240000 }
            $cImage = Invoke-SoftStep c @{ op = 'wait_for'; target = 'type:AttachmentImage'; timeout_ms = 180000 }
            Step c @{ op = 'shot'; name = "atrest-$runTag-c-served" }
            Write-ChannelRows c 'c after the catch-up' | Out-Null

            $cFiles = @()
            $cDeadline = (Get-Date).AddSeconds(180)
            while ((Get-Date) -lt $cDeadline) {
                $cFiles = @(Get-StoredContentFiles c)
                if ($cFiles.Count -gt 0) { break }
                Start-Sleep -Seconds 3
            }
            $cPlain = @($cFiles | Where-Object { -not (Test-Hfe1 $_.FullName) })
            $cLeaks = Get-MarkerLeaks c $seedMarker
            if ($cFiles.Count -gt 0 -and $cPlain.Count -eq 0 -and $cLeaks.Count -eq 0 -and $cImage.ok) {
                Set-Gate 'G4 serve after migration: c is served the seed PNG and stores it HFE1' 'PASS'
            } else {
                Set-Gate 'G4 serve after migration: c is served the seed PNG and stores it HFE1' 'FAIL'
                Add-Note "G4: files=$($cFiles.Count) plaintext=$($cPlain.Count) leaks=$($cLeaks.Count) image=$($cImage.ok)"
                Write-Evidence 'G4' @('a', 'b', 'c')
                throw 'G4 failed: the served copy did not arrive protected'
            }
        }

        # ---- G5: the export is the plaintext again ------------------------------
        Say '6/6 b exports the seed image and the seed clip'
        if (Test-Path $exportRoot) { Remove-Item $exportRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null
        # The channel copies are the ones a fresh reader would have asked for, so
        # they are exported first; the DM holds its own copies of the same three
        # fixtures, and the manifest knows both, so a seed whose server is gone
        # still gets a real export gate.
        # Asked for, never assumed from the manifest: a seed restored from before
        # the delete brings its server back, and a seed whose run already deleted
        # it does not.
        $onChannel = $false
        $opened = Invoke-SoftStep b @{ op = 'open_server'; name = $server }
        if ($opened.ok) {
            Invoke-SoftStep b @{ op = 'open_channel'; name = 'general' } | Out-Null
            $onChannel = (Invoke-SoftStep b @{ op = 'wait_for'; target = "text:chan png $($manifest.run)"; timeout_ms = 30000 }).ok
        }
        if (-not $onChannel) {
            Add-Note 'G5 exported the DM copies: the seed server is not on b any more'
            Open-Dm b 'probe-a'
            # The seed messages are the OLDEST in this DM and the gates above
            # have just added four newer ones, so the seed cards are not mounted
            # and nothing can be exported from them until the list goes back.
            Invoke-SoftStep b @{ op = 'tap'; target = 'semantics:Jump to the oldest message'; index = 0 } | Out-Null
            $atSeed = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:seed png $($manifest.run)"; timeout_ms = 30000 }
            $scrolls = 0
            while (-not $atSeed.ok -and $scrolls -lt 10) {
                Invoke-SoftStep b @{ op = 'scroll'; target = 'type:ListView'; index = 0; dy = 400 } | Out-Null
                $atSeed = Invoke-SoftStep b @{ op = 'wait_for'; target = "text:seed png $($manifest.run)"; timeout_ms = 3000 }
                $scrolls++
            }
            if (-not $atSeed.ok) {
                Step b @{ op = 'shot'; name = "atrest-$runTag-b-no-seed-rows" }
                Invoke-SoftStep b @{ op = 'look'; max = 60 } | Out-Null
                Set-Gate 'G5 export: the plaintext comes back out byte for byte' 'FAIL'
                Add-Note 'G5: the seed rows never came back into view in the DM'
                throw 'G5 failed: nothing to export from'
            }
        }

        $exports = @(
            @{ file = $seedImageCardName; dest = (Join-Path $exportRoot $seedImageCardName); marker = $false },
            @{ file = $seedMp4Name; dest = (Join-Path $exportRoot $seedMp4Name); marker = $true },
            @{ file = $seedBinName; dest = (Join-Path $exportRoot $seedBinName); marker = $true }
        )
        $exportProblems = @()
        foreach ($export in $exports) {
            $answer = Invoke-SoftStep b @{ op = 'export_attachment'; file = $export.file; dest = $export.dest }
            if (-not $answer.ok) { $exportProblems += "$($export.file): $($answer.message)"; continue }
            if ("$($answer.message)" -notmatch 'from (.+?) to ') {
                $exportProblems += "$($export.file): the export did not say where it read from"
                continue
            }
            $source = Split-Path -Leaf $Matches[1]
            $seedEntry = @($manifest.b.files | Where-Object { $_.rel -like "*$source" }) | Select-Object -First 1
            $wroteHash = (Get-FileHash $export.dest -Algorithm SHA256).Hash
            if (-not $seedEntry) {
                $exportProblems += "$($export.file): $source is not in the seed manifest"
            } elseif ($seedEntry.sha256 -ne $wroteHash) {
                $exportProblems += "$($export.file): exported $wroteHash, the seed held $($seedEntry.sha256)"
            }
            if ($export.marker -and -not (Test-BytesContain $export.dest $seedMarker)) {
                $exportProblems += "$($export.file): the export does not carry $seedMarker"
            }
            Say "exported $($export.file) -> $($export.dest) ($((Get-Item $export.dest).Length) bytes)" 'DarkCyan'
        }
        if ($exportProblems.Count -eq 0) {
            Set-Gate 'G5 export: the plaintext comes back out byte for byte' 'PASS'
        } else {
            Set-Gate 'G5 export: the plaintext comes back out byte for byte' 'FAIL'
            foreach ($problem in $exportProblems) { Add-Note "G5: $problem" }
            throw 'G5 failed: see the notes above'
        }
    } catch {
        $failure = $_
        Say "FAILED: $($_.Exception.Message)" 'Red'
        $unreached = Set-FirstUnreachedGateFailed
        if ($unreached) { Say "first gate without a verdict: $unreached" 'Red' }
    }

    # Cleanup runs whatever happened: a fleet server left on the relay is worse
    # than a noisy log, because these are real identities.
    if (-not $KeepServer) {
        Say 'cleanup: deleting the server as its owner'
        try {
            if (-not (Get-PeerProcess 'a')) { Start-PeerProcess 'a'; Wait-ForConnected a | Out-Null }
            # An earlier upgrade run on this seed may already have deleted it.
            # Asked for rather than assumed: a restored seed predates the delete,
            # so the strip is the only thing that knows what a holds NOW.
            $present = Invoke-SoftStep a @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 20000 }
            if (-not $present.ok) {
                Set-Gate 'C  cleanup: no fleet server left on the relay' 'SKIPPED'
                Add-Note 'cleanup had nothing to do: the seed server is not in the owner''s strip'
                Set-SeedServerGone 'it was already gone at cleanup'
                Say 'cleanup: nothing to delete' 'Yellow'
            } else {
                Remove-FleetServer $server
                Set-Gate 'C  cleanup: no fleet server left on the relay' 'PASS'
                $serverDeleted = $true
                Set-SeedServerGone "the upgrade run $runTag"
                Say 'cleanup done' 'Green'
            }
        } catch {
            Set-Gate 'C  cleanup: no fleet server left on the relay' 'FAIL'
            Say "cleanup failed (the server may still exist): $($_.Exception.Message)" 'Red'
        }
    } else {
        Set-Gate 'C  cleanup: no fleet server left on the relay' 'WARN'
        Add-Note '-KeepServer was passed, so a fleet server is still on the relay'
    }

    Write-GateReport "phase U gates for run $runTag (seed $($manifest.run))"
    Say "exports: $exportRoot" 'DarkCyan'
    if ($failure) { throw $failure }
    if (-not $KeepUp) {
        Say 'stopping the fleet'
        Invoke-FleetScript @('-Stop')
    }
    Say 'PASS' 'Green'
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

if ($Seed) { Invoke-SeedPhase }
elseif ($AbortSeed) { Invoke-AbortSeed }
else { Invoke-UpgradePhase }
