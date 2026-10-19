# A server made on one device while its sibling device is closed reaches that
# sibling when it comes back, whether the first device is still online or not.
#
#   powershell -File scripts\fleet_t1_sibling_server.ps1              # builds first
#   powershell -File scripts\fleet_t1_sibling_server.ps1 -SkipBuild   # you just built g,h,i
#   powershell -File scripts\fleet_t1_sibling_server.ps1 -KeepUp      # leave the windows open
#
# g and h are TWO devices of one identity (h is linked from g the way
# fleet_device_link.ps1 does it), i is another member of each server.
#
#   L   g and i onboarded, h linked as g's second device.
#   S1  h closed; g makes s1, i joins it; h comes back while g is ONLINE and
#       must list s1.
#   S2  h closed; g makes s2, i joins it, then g closes; h comes back more than
#       five minutes later while g is OFFLINE and must list s2 (the announce the
#       relay held for it) and read i's post in #general (its MLS leaf came from
#       i, not from g).
#   F   g comes back while h is online: both already hold both servers, so
#       neither may log ServerJoined or show a "Joined" toast for them.
#   C   g deletes both servers.
#
# Windows only. Peers g, h and i, so it can run beside fleets on other letters.
# Windows PowerShell 5.1, so no pwsh-only syntax.

param(
    [switch]$KeepUp,
    [switch]$SkipBuild,
    [int]$ArriveSeconds = 120,
    [int]$AwaySeconds = 330,
    [int]$BootTimeoutSeconds = 240
)

if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepUp, -SkipBuild, -ArriveSeconds, -AwaySeconds and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

if (-not (Test-WindowsBackend)) { throw 'fleet_t1_sibling_server.ps1 drives the Windows backend only' }

$Peers3 = @('g', 'h', 'i')
$runTag = $script:FleetVars.RUN
$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$evidenceRoot = Join-Path $script:FleetOutRoot "kept\t1_sibling_$runTag"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$startedAt = Get-Date
$s1 = "sib1-$runTag"
$s2 = "sib2-$runTag"

function Say($message, $colour = 'Cyan') { Write-Host "[t1-sibling] $message" -ForegroundColor $colour }

$script:Gates = [ordered]@{}
$script:Gates['L   g+i onboarded, h linked as a second device of g']               = 'SKIP'
$script:Gates['S1  made while h closed, h back with g ONLINE: h lists it']          = 'SKIP'
$script:Gates['S2a made while h closed, h back with g OFFLINE: h lists it']         = 'SKIP'
$script:Gates['S2b ... and h reads i''s post in #general']                          = 'SKIP'
$script:Gates['F   g back with h online: no "Joined" for a server either holds']    = 'SKIP'
$script:Gates['C   cleanup: g deleted both servers']                                = 'SKIP'
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

function Step($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 240
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
}

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
    # By the process object (its pid), never by image name.
    $proc | Stop-Process -Force
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - OFFLINE" 'Yellow'
}

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
    # No output redirection: it flips Start-Process into inherit-handles mode.
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

# Only on a peer that is about to die: the live loop replays the inbox from line
# 0 on boot, and truncating it under a running instance wedges it.
function Reset-PeerMailbox($peer) {
    $out = Join-Path $script:FleetOutRoot $peer
    [System.IO.File]::WriteAllText((Join-Path $out 'inbox.jsonl'), '',
        (New-Object System.Text.UTF8Encoding($false)))
    $marker = Join-Path $out 'live-ready'
    if (Test-Path $marker) { Remove-Item $marker -Force }
    $script:FleetConsumed[$peer] = 0
}

# A freshly linked device asks once for a lock of its own (AR-34).
function Skip-LockPrompt($peer) {
    $prompt = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'text:Set a lock on this device'; timeout_ms = 15000 }
    if ($prompt.ok) {
        Step $peer @{ op = 'tap'; target = 'text:Not now'; index = 0 }
        Step $peer @{ op = 'wait_for'; gone = 'text:Set a lock on this device'; timeout_ms = 10000 }
        Say "$peer was asked to set a lock: Not now"
    }
}

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
    foreach ($peer in $Peers3) { $script:LogMarks[$peer] = (Read-PeerLog $peer).Count }
}

$script:EvidencePatterns = @(
    'Announced server', 'Re-announced', 'announced server', 'running join flow', 'Server join completed',
    'Joined MLS group', 'ServerJoinRequest', 'is not one of this identity', 'SiblingServerAnnounce',
    'KeyPackage', 'Membership commit', 'REJECTED', 'Dropped'
)
$script:HeadlinePatterns = @(
    'Announced server', 'Re-announced', 'announced server', 'Server join completed', 'Joined MLS group group'
)

function Save-GateEvidence($gate) {
    $headline = @()
    foreach ($peer in $Peers3) {
        $all = Read-PeerLog $peer
        $from = [int]$script:LogMarks[$peer]
        if ($all.Count -lt $from) { $from = 0 }
        $slice = @()
        if ($all.Count -gt $from) { $slice = @($all[$from..($all.Count - 1)]) }
        $hits = @($slice | Where-Object {
            $line = $_
            @($script:EvidencePatterns | Where-Object { $line.Contains($_) }).Count -gt 0
        })
        $file = Join-Path $evidenceRoot "$gate-$peer.log"
        [System.IO.File]::WriteAllLines($file, [string[]]$hits, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($hit in $hits) {
            if (@($script:HeadlinePatterns | Where-Object { $hit.Contains($_) }).Count -gt 0) {
                $headline += "[$peer] $hit"
            }
        }
    }
    foreach ($h in $headline | Select-Object -First 40) { Write-Host "    $h" -ForegroundColor DarkGray }
    Set-LogMarks
}

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

function Save-Dump($peer, $label) {
    $name = "$label-$peer"
    Step $peer @{ op = 'dump'; name = $name }
    Copy-Item (Join-Path $script:FleetOutRoot "$peer\map-$name.json") $evidenceRoot -Force -ErrorAction SilentlyContinue
    return $name
}

function Save-Shot($peer, $label) {
    $name = "t1sib-$runTag-$label-$peer"
    $shot = Invoke-SoftStep $peer @{ op = 'shot'; name = $name }
    Get-ChildItem (Join-Path $script:FleetOutRoot $peer) -Filter "$name*.png" -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $evidenceRoot -Force -ErrorAction SilentlyContinue }
}

# g makes the server, opens it and copies its invite into ${INVITE}.
function New-ServerWithInvite($peer, $name) {
    Step $peer @{ op = 'tap'; target = 'semantics:Create a server' }
    Step $peer @{ op = 'enter_text'; target = 'hint:My Awesome Server'; value = $name }
    Step $peer @{ op = 'tap'; target = 'text:Create'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = "server:$name"; timeout_ms = 30000 }
    Step $peer @{ op = 'open_server'; name = $name }
    Step $peer @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }
    Step $peer @{ op = 'right_click'; target = "server:$name" }
    Step $peer @{ op = 'tap'; target = 'menu > text:Invite people' }
    Step $peer @{ op = 'wait_for'; target = 'type:HollowCopyField'; timeout_ms = 20000 }
    Step $peer @{ op = 'capture'; target = 'type:HollowCopyField'; as = 'INVITE' }
    Step $peer @{ op = 'key'; value = 'escape' }
}

function Join-ByInvite($peer, $name) {
    Step $peer @{ op = 'tap'; target = 'semantics:Create a server' }
    Step $peer @{ op = 'enter_text'; target = 'hint:Invite link'; value = '${INVITE}' }
    Step $peer @{ op = 'tap'; target = 'text:Join'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = "server:$name"; timeout_ms = 90000 }
}

function Send-Channel($peer, $channel, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = "hint:Message #$channel" }
        Step $peer @{ op = 'enter_text'; target = "hint:Message #$channel"; value = $body }
        Step $peer @{ op = 'key'; value = 'enter' }
        $landed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }
        if ($landed.ok) { return }
        Add-Note "$peer's #$channel composer swallowed the send on attempt $attempt"
    }
    throw "[$peer] the #$channel composer never produced a row for '$body' after 3 attempts"
}

function Remove-Server($peer, $name) {
    Step $peer @{ op = 'wait_for'; target = "server:$name"; timeout_ms = 60000 }
    Step $peer @{ op = 'right_click'; target = "server:$name" }
    Step $peer @{ op = 'tap'; target = 'menu > text:Server settings' }
    Step $peer @{ op = 'reveal'; target = 'text:Delete server'; index = 0 }
    Step $peer @{ op = 'tap'; target = 'text:Delete server'; index = 0 }
    Step $peer @{ op = 'tap'; target = 'dialog > text:Delete server'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = "server:$name"; timeout_ms = 60000 }
}

function Open-SettingsDevices($peer) {
    Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 20000 }
    Step $peer @{ op = 'tap'; target = 'type:SettingsPlace > text:Devices'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:SettingsPlace > text:Link a device'; timeout_ms = 20000 }
}

function Close-Settings($peer) {
    $open = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 1500 }
    if (-not $open.ok) { return }
    Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
    $gone = Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'type:SettingsPlace'; timeout_ms = 3000 }
    if ($gone.ok) { return }
    Step $peer @{ op = 'tap'; target = 'semantics:Close settings'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:SettingsPlace'; timeout_ms = 10000 }
}

function Get-LinkCode($peer) {
    Step $peer @{ op = 'tap'; target = 'type:SettingsPlace > text:Link a device'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_DeviceLinkContent'; timeout_ms = 20000 }
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $answer = Invoke-SoftStep $peer @{
            op = 'capture'; target = 'type:_DeviceLinkContent'; as = 'LINKCODE_RAW'
            regex = '([A-Z2-9](?: [A-Z2-9]){5} - [A-Z2-9](?: [A-Z2-9]){3})'
        }
        if ($answer.ok) {
            $code = ($script:FleetVars['LINKCODE_RAW'] -replace '[\s-]', '')
            if ($code.Length -eq 10) { return $code }
        }
        Start-Sleep -Milliseconds 700
    }
    throw "[$peer] never rendered a 10-character link code"
}

# h back on its existing data, then the server must arrive on its strip.
function Test-ServerArrives($label, $name) {
    Restart-Peer h $label
    Skip-LockPrompt h
    Wait-ForConnected h
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $seen = Invoke-SoftStep h @{ op = 'wait_for'; target = "server:$name"; timeout_ms = $ArriveSeconds * 1000 }
    $seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
    Save-Shot h $label
    $dump = Save-Dump h $label
    $listed = (Get-DumpServerNames h $dump) -contains $name
    return [pscustomobject]@{ ok = ($seen.ok -and $listed); seen = $seen.ok; listed = $listed; seconds = $seconds }
}

if (-not $SkipBuild) {
    Say 'building and staging g,h,i (pass -SkipBuild when you have just built)'
    Invoke-FleetScript @('-Build', '-Peers', 'g,h,i')
}

# h must reach the WELCOME dialog to link, so only g and i onboard.
Start-FreshFleet @('g', 'i')
Say "run tag $runTag"

$failure = $null
$madeS1 = $false
$madeS2 = $false
$deviceG = ''
$deviceH = ''
$masterG = ''

try {
    foreach ($peer in @('g', 'i')) { Wait-ForConnected $peer }
    Step g @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_G' }
    $masterG = $script:FleetVars['PEER_G']

    # ---- L: link h from g ---------------------------------------------------
    Say 'L: h is linked as the second device of g'
    Open-SettingsDevices g
    $code = Get-LinkCode g
    Say "g is showing link code $code" 'Green'
    Start-EmptyPeer h
    Step h @{ op = 'wait_for'; target = 'text:Agree and continue'; timeout_ms = 90000 }
    Step h @{ op = 'tap'; target = 'text:Agree and continue'; index = 0 }
    Step h @{ op = 'wait_for'; target = 'text:Create an identity'; timeout_ms = 20000 }
    Step h @{ op = 'tap'; target = 'text:Link a device'; index = 0 }
    Step h @{ op = 'wait_for'; target = 'hint:ABC123'; timeout_ms = 180000 }
    Wait-ForConnected h
    Step h @{ op = 'enter_text'; target = 'hint:ABC123'; value = $code }
    Step h @{ op = 'wait_for'; target = "text:$code"; timeout_ms = 15000 }
    Step h @{ op = 'tap'; target = 'text:Link'; index = 0 }
    Step h @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 }
    Step g @{ op = 'wait_for'; target = 'text:Add this device?'; timeout_ms = 60000 }
    Step g @{ op = 'tap'; target = 'text:Add device'; index = 0 }
    Step g @{ op = 'wait_for'; target = 'text:Data sent'; timeout_ms = 180000 }
    Step h @{ op = 'wait_for'; target = 'text:Linked'; timeout_ms = 120000 }
    $hProc = Get-PeerProcess h
    $oldPid = if ($hProc) { $hProc.Id } else { 0 }
    Reset-PeerMailbox h
    Step g @{ op = 'tap'; target = 'text:Done'; index = 0 }
    Step g @{ op = 'wait_for'; gone = 'type:_DeviceLinkContent'; timeout_ms = 15000 }
    Close-Settings g
    $deadline = (Get-Date).AddSeconds(120)
    $newPid = 0
    while ((Get-Date) -lt $deadline) {
        $now = Get-PeerProcess h
        if ($now -and $now.Id -ne $oldPid -and (Test-PeerLive h)) { $newPid = $now.Id; break }
        Start-Sleep -Milliseconds 400
    }
    if ($newPid -eq 0) {
        Add-Note 'h did not come back on its own within 120s, so the script restarted it'
        Stop-Peer h
        Start-PeerProcess h $false
    }
    Skip-LockPrompt h
    Wait-ForConnected h
    Step h @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_H' }
    if ($script:FleetVars['PEER_H'] -ne $masterG) {
        throw "h's identity after the link is $($script:FleetVars['PEER_H']), g's master is $masterG"
    }
    Step g @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'DEV_G' }
    Step h @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'DEV_H' }
    $deviceG = $script:FleetVars['DEV_G']
    $deviceH = $script:FleetVars['DEV_H']
    Set-Gate 'L   g+i onboarded, h linked as a second device of g' 'PASS' "(device g $deviceG, device h $deviceH)"
    Set-LogMarks

    # ---- S1: g stays online -------------------------------------------------
    Say "S1: h closed, g makes $s1, i joins, h returns while g is ONLINE"
    Stop-Peer h
    New-ServerWithInvite g $s1
    $madeS1 = $true
    Join-ByInvite i $s1
    Start-Sleep -Seconds 3
    $r1 = Test-ServerArrives 's1' $s1
    Save-GateEvidence 'S1'
    Set-Gate 'S1  made while h closed, h back with g ONLINE: h lists it' $(if ($r1.ok) { 'PASS' } else { 'FAIL' }) `
        "(strip=$($r1.seen) provider=$($r1.listed) after $($r1.seconds)s)"

    # ---- S2: g offline when h returns ---------------------------------------
    Say "S2: h closed, g makes $s2, i joins, g closes, h returns while g is OFFLINE"
    Stop-Peer h
    New-ServerWithInvite g $s2
    $madeS2 = $true
    Join-ByInvite i $s2
    Start-Sleep -Seconds 3
    Stop-Peer g
    # Past the 300 s window in which a live-only signal still counts.
    Say "h stays away $AwaySeconds s more with g offline"
    Start-Sleep -Seconds $AwaySeconds
    $r2 = Test-ServerArrives 's2' $s2
    Set-Gate 'S2a made while h closed, h back with g OFFLINE: h lists it' $(if ($r2.ok) { 'PASS' } else { 'FAIL' }) `
        "(strip=$($r2.seen) provider=$($r2.listed) after $($r2.seconds)s)"
    if ($r2.ok) {
        $post = "s2 hello from i $runTag"
        Step h @{ op = 'open_server'; name = $s2 }
        Step h @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 60000 }
        Step i @{ op = 'open_server'; name = $s2 }
        Step i @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }
        Send-Channel i 'general' $post
        $read = Invoke-SoftStep h @{ op = 'wait_for'; target = "text:$post"; timeout_ms = $ArriveSeconds * 1000 }
        Save-Shot h 's2-read'
        Set-Gate 'S2b ... and h reads i''s post in #general' $(if ($read.ok) { 'PASS' } else { 'FAIL' })
    }
    Save-GateEvidence 'S2'

    Say 'the journey ran to the end' 'Green'
} catch {
    $failure = $_
    $where = Set-FirstUnreachedGateFailed
    Say "FAILED at [$where]: $($_.Exception.Message)" 'Red'
    try { Save-GateEvidence 'abort' } catch { }
}

# ---- C: cleanup, whatever happened -------------------------------------------
try {
    if ($madeS1 -or $madeS2) {
        $gWasAway = -not (Get-PeerProcess g)
        Set-LogMarks
        if ($gWasAway) { Restart-Peer g 'cleanup' }
        Wait-ForConnected g
        # g coming back makes both devices run the sibling convergence. Each already
        # holds the servers: a "Joined" toast (and its server switch) on either is the bug.
        if ($gWasAway -and (Get-PeerProcess h) -and -not $failure) {
            $toast = Invoke-SoftStep g @{ op = 'wait_for'; target = 'contains:Joined sib'; timeout_ms = 30000 }
            $joined = @{}
            foreach ($peer in @('g', 'h')) {
                $all = Read-PeerLog $peer
                $from = [int]$script:LogMarks[$peer]
                if ($all.Count -lt $from) { $from = 0 }
                $slice = @()
                if ($all.Count -gt $from) { $slice = @($all[$from..($all.Count - 1)]) }
                $joined[$peer] = @($slice | Where-Object { $_.Contains('[HOLLOW] Server joined:') }).Count
                $quiet = @($slice | Where-Object { $_.Contains('[HOLLOW] Server created:') }).Count
                Add-Note "after g came back, $peer logged $($joined[$peer]) ServerJoined and $quiet quiet list refresh(es)"
            }
            Save-GateEvidence 'F'
            $clean = (-not $toast.ok) -and $joined['g'] -eq 0 -and $joined['h'] -eq 0
            Set-Gate 'F   g back with h online: no "Joined" for a server either holds' $(if ($clean) { 'PASS' } else { 'FAIL' }) `
                "(toast on g=$($toast.ok) ServerJoined g=$($joined['g']) h=$($joined['h']))"
        }
        if ($madeS1) { Remove-Server g $s1 }
        if ($madeS2) { Remove-Server g $s2 }
    }
    Set-Gate 'C   cleanup: g deleted both servers' 'PASS'
} catch {
    Set-Gate 'C   cleanup: g deleted both servers' 'FAIL' "($($_.Exception.Message))"
}

Write-Host ''
Write-Host '===== t1-sibling: a server reaches the sibling that was away =====' -ForegroundColor Cyan
foreach ($key in @($script:Gates.Keys)) {
    $status = $script:Gates[$key]
    $colour = 'DarkGray'
    if ($status -eq 'PASS') { $colour = 'Green' } elseif ($status -eq 'FAIL') { $colour = 'Red' }
    $detail = if ($script:GateDetail.Contains($key)) { " $($script:GateDetail[$key])" } else { '' }
    Write-Host ("  {0,-4} {1}{2}" -f $status, $key, $detail) -ForegroundColor $colour
}
Write-Host ''
Write-Host ("  run tag  : {0}   took {1:mm\:ss}" -f $runTag, ((Get-Date) - $startedAt)) -ForegroundColor Gray
Write-Host ("  master g : {0} (devices g={1} h={2})" -f $masterG, $deviceG, $deviceH) -ForegroundColor Gray
Write-Host ("  evidence : {0}" -f $evidenceRoot) -ForegroundColor Gray
foreach ($note in $script:Notes) { Write-Host ("  note     : {0}" -f $note) -ForegroundColor DarkCyan }

$failed = @($script:Gates.Values | Where-Object { $_ -eq 'FAIL' }).Count
if ($failure -or $failed -gt 0) {
    $pids = $Peers3 | ForEach-Object {
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
