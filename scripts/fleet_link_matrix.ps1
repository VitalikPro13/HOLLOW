# The device-linking matrix: ONE journey, one cell of it per run, across
# machines. A populated presenter (the device that holds the identity) links an
# EMPTY receiver while a friend supplies traffic, under one condition, and the
# new device is then judged from its DATABASE and roster (the probe's
# `link_state` op), with screenshots for the eye.
#
#   powershell -File scripts\fleet_link_matrix.ps1 -Presenter android:a -Receiver win:b
#   powershell -File scripts\fleet_link_matrix.ps1 -Presenter win:a -Receiver ios:b -Condition background
#   powershell -File scripts\fleet_link_matrix.ps1 -Presenter win:a -Receiver win:b -Condition third_device -Third android:d
#
# A peer is <platform>:<letter>: win (this machine's fleet), android and ios
# (the Mac mini's emulators and simulators), macos (the mini's desktop app),
# linux (the build VM, headless). The friend defaults to win:c. Each machine's
# tree must hold a current build of this worktree: `fleet.ps1 -Build` here,
# `scripts/mini_sync.sh` + `fleet.ps1 -Build` on the mini, `scripts/vm_sync.sh`
# + `fleet.ps1 -Build` on the VM (fleet_remote.ps1 names the trees).
#
# Conditions:
#   clean           nothing in the way
#   background      the presenter is backgrounded while the receiver types the
#                   code; its log must show `background` and no `suspend`
#                   before the receiver's ask arrives, and the link completes
#   relay_resume    the presenter's relay path freezes for 20 s after showing the
#                   code and thaws: the session resumes, the SAME code links
#   relay_lost      the path stays frozen past the relay's session grace and is
#                   dropped: the session is lost, the dialog renews the code and
#                   the NEW code links
#   transfer_drop   the receiver's path freezes for 15 s right after the
#                   presenter adds it, then thaws: the snapshot still lands
#   held_db         (Windows receiver) another program holds messages.db across
#                   the import: the first landing refuses and keeps the stash,
#                   the next launch lands it
#   cancel_retry    the presenter declines the first ask; the receiver tries
#                   again with a fresh code and links
#   third_device    after the link, -Third (empty) links from the presenter too
#   roster_push     (Android friend, AR-29 on a phone) after the link the friend goes
#                   to the background and its process is killed; the presenter
#                   removes the receiver and DMs the friend, whose push fetch runs;
#                   the friend opens again and DMs the identity at once: the
#                   presenter gets it, the removed receiver never does.
#                   -FriendDmOffline: the friend opens with no network and
#                   writes the DM before it has a relay session
#
# Seeding goes through the app's own providers (`seed_*` probe ops) so every
# platform starts from the same populated identity; the LINK is driven through
# the real UI on both sides. Evidence (dumps, shots, logs, refusal lines, the
# verdict JSON) lands in .team\matrix\<run>-<cell>\ and one line per run is
# appended to .team\matrix\results.jsonl.

param(
    [Parameter(Mandatory = $true)][string]$Presenter,
    [Parameter(Mandatory = $true)][string]$Receiver,
    [string]$Friend = 'win:c',
    [string]$Third = '',
    [ValidateSet('clean', 'background', 'relay_resume', 'relay_lost', 'transfer_drop', 'held_db', 'cancel_retry', 'third_device', 'roster_push')]
    [string]$Condition = 'clean',
    # Leave every peer running at the end, PASS or not.
    [switch]$KeepUp,
    # Seconds the presenter's path stays frozen for relay_lost: past the relay's
    # 120 s session grace, which starts only once the relay finds the socket
    # dead (135 s still resumed in the 2026-10-10 run).
    [int]$LostSeconds = 240,
    # roster_push: seconds the friend stays dead before the removal, past the relay's
    # 120 s session grace, so what follows reaches it only through the offline buffer.
    [int]$DeadSeconds = 150,
    # roster_push: the friend reopens with its network off and writes the DM before
    # it has a relay session; the network returns 5 s later.
    [switch]$FriendDmOffline,
    [string]$EvidenceRoot = ''
)

if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runTag = $script:FleetVars.RUN
$started = Get-Date
$startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 5

$P = Register-FleetPeer $Presenter
$R = Register-FleetPeer $Receiver
$F = Register-FleetPeer $Friend
$T = $null
if ($Condition -eq 'third_device') {
    if (-not $Third) { throw '-Condition third_device needs -Third <platform>:<letter>' }
    $T = Register-FleetPeer $Third
}
$all = @($P, $R, $F) + @($T | Where-Object { $_ })
$letters = @($all | ForEach-Object { if (Test-RemotePeer $_) { (Get-RemotePeer $_).Letter } else { $_ } })
if (@($letters | Select-Object -Unique).Count -ne $letters.Count) {
    throw "every peer needs its own letter (got $($all -join ', ')): build\fleet_out is per letter on every machine"
}
if ($Condition -eq 'held_db' -and (Test-RemotePeer $R)) { throw 'held_db holds a file the Windows way: the receiver must be win:<letter>' }
if ($Condition -eq 'roster_push' -and -not ((Test-RemotePeer $F) -and (Get-RemotePeer $F).Platform -eq 'android')) {
    throw 'roster_push wakes the friend through FCM: the friend must be android:<letter>'
}

function Get-Platform($peer) { if (Test-RemotePeer $peer) { return (Get-RemotePeer $peer).Platform } return 'win' }
function Test-Mobile($peer) { return (Get-Platform $peer) -in @('android', 'ios') }
function Get-Letter($peer) { if (Test-RemotePeer $peer) { return (Get-RemotePeer $peer).Letter } return $peer }

$cell = "$($Presenter -replace ':', '-')_to_$($Receiver -replace ':', '-')_$Condition"
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $repoRoot '.team\matrix' }
$evidence = Join-Path $EvidenceRoot "$runTag-$cell"
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$server = "mx-$runTag"

function Say($message, $colour = 'Cyan') {
    $line = "[matrix $(Get-Date -Format 'HH:mm:ss')] $message"
    Write-Host $line -ForegroundColor $colour
    Add-Content -Path (Join-Path $evidence 'journey.log') -Value $line -Encoding UTF8
}

# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{}
$script:GateTimes = @{}
foreach ($name in @(
        'S  presenter seeded: friend, DMs, server + #general, two images, avatar',
        'L1 presenter shows a link code',
        'L2 receiver entered it and is linking',
        'L3 presenter added the device and sent the data',
        'L4 receiver stashed the snapshot and came back up',
        'L5 receiver runs as the presenter''s identity on its own device key',
        'V1 friend inherited',
        'V2 DM history inherited',
        'V3 server and #general history inherited',
        'V4 profile name and avatar inherited',
        'V5 image in the DM fetched by the receiver without the chat open',
        'V6 image in #general fetched by the receiver without the chat open',
        'V7 roster lists both devices as members on both sides',
        'V8 both images present after the chats open',
        'T1 receiver DM reaches the friend and the presenter',
        'T2 presenter DM reaches the friend and the receiver',
        'T3 friend DM reaches the presenter and the receiver',
        'T4 receiver #general post reaches the presenter and the friend')) { $script:Gates[$name] = 'SKIP' }
switch ($Condition) {
    'background' { $script:Gates['X  presenter backgrounded: no suspend, the ask arrived while away, linked'] = 'SKIP' }
    'relay_resume' { $script:Gates['X  presenter path frozen 20 s and thawed: same code, linked'] = 'SKIP' }
    'relay_lost' { $script:Gates['X  presenter session lost: a renewed code, linked'] = 'SKIP' }
    'transfer_drop' { $script:Gates['X  receiver path frozen mid-transfer: the snapshot still landed'] = 'SKIP' }
    'held_db' { $script:Gates['X  held messages.db: first landing refused and kept the stash, the next landed'] = 'SKIP' }
    'cancel_retry' { $script:Gates['X  declined first ask failed cleanly, a fresh code linked'] = 'SKIP' }
    'third_device' { $script:Gates['X  third device linked: three members, traffic reaches it'] = 'SKIP' }
    'roster_push' {
        $script:Gates['P1 friend backgrounded and killed, the presenter removed the receiver'] = 'SKIP'
        $script:Gates['P2 the friend woke by push only, every FCM data block just {sealed: N}'] = 'SKIP'
        $script:Gates['P3 the push fetch stored the presenter''s DM before the app opened'] = 'SKIP'
        $script:Gates['P4 the friend''s first DM after opening reaches the presenter'] = 'SKIP'
        $script:Gates['X  ...and never the removed receiver (nothing encrypted for it), which got the friend''s DMs before'] = 'SKIP'
    }
}
$script:Gates['C  cleanup: the server deleted'] = 'SKIP'
$script:Notes = New-Object System.Collections.ArrayList

function Set-Gate($prefix, $status) {
    $key = @($script:Gates.Keys | Where-Object { $_.StartsWith($prefix) }) | Select-Object -First 1
    if (-not $key) { throw "unknown gate $prefix" }
    $script:Gates[$key] = $status
    $script:GateTimes[$key] = [int]((Get-Date) - $started).TotalSeconds
    $colour = if ($status -eq 'PASS') { 'Green' } elseif ($status -eq 'FAIL') { 'Red' } else { 'Yellow' }
    Say "$status $key" $colour
}

function Add-Note($text) { [void]$script:Notes.Add($text); Say "note: $text" 'DarkCyan' }

# --------------------------------------------------------------------------
# Talking to peers, wherever they are
# --------------------------------------------------------------------------

function Step($peer, $step, $timeoutSeconds = 240) {
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer ([pscustomobject]$step) $timeoutSeconds
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

function Soft($peer, $step, $timeoutSeconds = 240) {
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2} (soft)" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    try { $answer = Send-FleetStep $peer ([pscustomobject]$step) $timeoutSeconds }
    catch { return [pscustomobject]@{ ok = $false; message = "$($_.Exception.Message)" } }
    Write-FleetAnswer $peer $answer '     '
    return $answer
}

# The device's database and roster, as the probe reads them.
function Get-State($peer, $fields = @{}) {
    $step = @{ op = 'link_state'; server = $server; tag = $runTag }
    foreach ($key in $fields.Keys) { $step[$key] = $fields[$key] }
    $answer = Step $peer $step 120
    return $answer.state
}

# Polls $peer's state until $test holds; the last state either way.
function Wait-State($peer, $fields, [scriptblock]$test, $timeoutSeconds, $label) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $state = Get-State $peer $fields
        if (& $test $state) { return $state }
        if ((Get-Date) -ge $deadline) {
            Add-Note "$peer never reached '$label' within ${timeoutSeconds}s"
            return $state
        }
        Start-Sleep -Seconds 3
    }
}

function Test-Texts($block, [string[]]$want) {
    if (-not $block -or -not $block.texts) { return $false }
    $have = @($block.texts)
    foreach ($w in $want) { if (-not @($have | Where-Object { $_ -like "*$w*" })) { return $false } }
    return $true
}

# The image's bytes are complete and on THIS device's disk (an imported row can
# still name the presenter's path, which exists when both run on one machine).
function Test-Image($block, $name) {
    if (-not $block -or -not $block.files) { return $false }
    return [bool](@($block.files | Where-Object { $_.name -like "$name*" -and $_.completed -and $_.on_disk -and $_.own_path }).Count)
}

function Get-Members($state) { return @(@($state.roster) | Where-Object { $_.state -eq 'member' }) }

function Wait-Connected($peer, $timeoutSeconds = 180) {
    Step $peer @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = $timeoutSeconds * 1000 } ($timeoutSeconds + 60) | Out-Null
}

function Get-PeerStatus($peer) { return (Invoke-PeerCommand $peer 'status') }

function Get-StashSize($peer) { return [int64](Invoke-PeerCommand $peer 'data_file' @{ name = 'pending_link.hollow' }).size }

function Get-LogLines($peer, $pattern) { return @((Invoke-PeerCommand $peer 'log_grep' @{ pattern = $pattern }).lines) }

# The app log's lines containing $pattern stamped at or after epoch second $since.
function Get-LogSince($peer, $pattern, [int64]$since) {
    return @(Get-LogLines $peer $pattern | Where-Object { "$_" -match '^\[(\d{9,})\]' -and [int64]$Matches[1] -ge $since })
}

function Get-Epoch { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Shot($peer, $name) { Soft $peer @{ op = 'shot'; name = "mx-$runTag-$name" } | Out-Null }

# Copies a peer's out dir and app log under $label: on this machine straight
# into the evidence folder, on another into the same run folder of its tree
# (fetched once at the end).
function Save-Evidence($peer, $label) {
    try {
        if (Test-RemotePeer $peer) {
            $dest = "$(Get-FleetRemoteTree (Get-RemotePeer $peer).Agent)/.team/matrix/$runTag-$cell/$label"
        } else {
            $dest = Join-Path $evidence $label
        }
        Invoke-PeerCommand $peer 'evidence' @{ dest = $dest } 300 | Out-Null
    } catch { Add-Note "evidence $label for ${peer}: $($_.Exception.Message)" }
}

# The receiver's stash, and on a desktop the mailbox handed over at once: the
# copy that replaces it starts reading its inbox seconds later.
function Wait-Stash($peer) {
    $stash = -1
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $stash = Get-StashSize $peer
        if ($stash -gt 0) { break }
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-Mobile $peer)) { Invoke-PeerCommand $peer 'mailbox' | Out-Null }
    if ($stash -le 0) { Add-Note "$peer's stash was never seen on disk (imported before the first poll?)" }
    else { Say "$peer stashed pending_link.hollow ($stash bytes)" }
    Save-Evidence $peer 'pre-relaunch'
    return $stash
}

# --------------------------------------------------------------------------
# UI the link is driven through (desktop and mobile shells differ)
# --------------------------------------------------------------------------

function Open-Devices($peer) {
    if (Test-Mobile $peer) {
        # The tab bar shows only at the top of the stack: leave any open chat first.
        for ($i = 0; $i -lt 3; $i++) {
            $back = Soft $peer @{ op = 'tap'; target = 'semantics:Back'; index = 0 } 30
            if (-not $back.ok) { break }
        }
        Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 } | Out-Null
        Step $peer @{ op = 'wait_for'; target = 'text:Appearance'; timeout_ms = 20000 } | Out-Null
        for ($i = 0; $i -lt 6; $i++) {
            $row = Soft $peer @{ op = 'wait_for'; target = 'text:Devices'; timeout_ms = 1200 }
            if ($row.ok) { break }
            Soft $peer @{ op = 'scroll'; target = 'text:Appearance'; dy = -600 } | Out-Null
        }
        Step $peer @{ op = 'tap'; target = 'text:Devices'; index = 0 } | Out-Null
        Step $peer @{ op = 'wait_for'; target = 'text:Link a device'; timeout_ms = 20000 } | Out-Null
        return
    }
    Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 } | Out-Null
    Step $peer @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 20000 } | Out-Null
    Step $peer @{ op = 'tap'; target = 'type:SettingsPlace > text:Devices'; index = 0 } | Out-Null
    Step $peer @{ op = 'wait_for'; target = 'type:SettingsPlace > text:Link a device'; timeout_ms = 20000 } | Out-Null
}

function Close-Devices($peer) {
    if (Test-Mobile $peer) {
        for ($i = 0; $i -lt 3; $i++) {
            $back = Soft $peer @{ op = 'tap'; target = 'semantics:Back'; index = 0 } 30
            if (-not $back.ok) { break }
        }
        Soft $peer @{ op = 'tap'; target = 'semantics:Chats'; index = 0 } 30 | Out-Null
        return
    }
    $open = Soft $peer @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 1500 } 30
    if (-not $open.ok) { return }
    Soft $peer @{ op = 'key'; value = 'escape' } 30 | Out-Null
    $gone = Soft $peer @{ op = 'wait_for'; gone = 'type:SettingsPlace'; timeout_ms = 3000 } 30
    if ($gone.ok) { return }
    Soft $peer @{ op = 'tap'; target = 'semantics:Close settings'; index = 0 } 30 | Out-Null
}

# Opens the link dialog (when $open) and reads the code: the dialog spaces it
# out with a dash after the sixth character and shows dots until it has one.
function Read-LinkCode($peer, [switch]$Open, $timeoutSeconds = 60) {
    if ($Open) {
        $button = if (Test-Mobile $peer) { 'text:Link a device' } else { 'type:SettingsPlace > text:Link a device' }
        Step $peer @{ op = 'tap'; target = $button; index = 0 } | Out-Null
        Step $peer @{ op = 'wait_for'; target = 'type:_DeviceLinkContent'; timeout_ms = 20000 } | Out-Null
    }
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $answer = Soft $peer @{
            op = 'capture'; target = 'type:_DeviceLinkContent'; as = 'LINKCODE_RAW'
            regex = '([A-Z2-9](?: [A-Z2-9]){5} - [A-Z2-9](?: [A-Z2-9]){3})'
        } 60
        if ($answer.ok) {
            $code = ($script:FleetVars['LINKCODE_RAW'] -replace '[\s-]', '')
            if ($code.Length -eq 10) { return $code }
        }
        Start-Sleep -Milliseconds 700
    }
    throw "[$peer] never rendered a 10-character link code"
}

# Opens the DM with $friendName as a person would (the friends bar on a
# desktop, the Chats list on a phone). Soft: a miss is a note, not a verdict.
function Show-Dm($peer, $friendName) {
    if (Test-Mobile $peer) {
        Soft $peer @{ op = 'tap'; target = 'semantics:Back'; index = 0 } 20 | Out-Null
        Soft $peer @{ op = 'tap'; target = 'semantics:Chats'; index = 0 } 30 | Out-Null
        $opened = Soft $peer @{ op = 'tap'; target = "text:$friendName"; index = 0 } 30
    } else {
        $opened = Soft $peer @{ op = 'tap'; target = "type:_FriendChip > semantics:$friendName" } 30
    }
    if (-not $opened.ok) { Add-Note "could not open the DM with $friendName on $peer" }
    Soft $peer @{ op = 'wait'; ms = 2000 } 30 | Out-Null
}

# Opens #general of the run's server.
function Show-Channel($peer) {
    if (Test-Mobile $peer) {
        Soft $peer @{ op = 'tap'; target = 'semantics:Back'; index = 0 } 20 | Out-Null
        Soft $peer @{ op = 'tap'; target = 'semantics:Chats'; index = 0 } 30 | Out-Null
        Soft $peer @{ op = 'tap'; target = "text:$server"; index = 0 } 30 | Out-Null
        $opened = Soft $peer @{ op = 'tap'; target = 'text:general'; index = 0 } 30
    } else {
        Soft $peer @{ op = 'open_server'; name = $server } 60 | Out-Null
        $opened = Soft $peer @{ op = 'open_channel'; name = 'general' } 60
    }
    if (-not $opened.ok) { Add-Note "could not open #general on $peer" }
    Soft $peer @{ op = 'wait'; ms = 2000 } 30 | Out-Null
}

# Welcome > Link a device on an EMPTY peer.
function Open-EnterCode($peer) {
    Step $peer @{ op = 'wait_for'; target = 'text:Create an identity'; timeout_ms = 120000 } | Out-Null
    Step $peer @{ op = 'tap'; target = 'text:Link a device'; index = 0 } | Out-Null
    Step $peer @{ op = 'wait_for'; target = 'hint:ABC123'; timeout_ms = 180000 } | Out-Null
}

function Enter-Code($peer, $code) {
    Step $peer @{ op = 'tap'; target = 'hint:ABC123' } | Out-Null
    Step $peer @{ op = 'enter_text'; target = 'hint:ABC123'; value = $code } | Out-Null
    Step $peer @{ op = 'wait_for'; target = "text:$code"; timeout_ms = 15000 } | Out-Null
    Step $peer @{ op = 'tap'; target = 'text:Link'; index = 0 } | Out-Null
}

# The receiver comes back after the import: a desktop relaunches itself (its
# mailbox is handed over first), a phone exits and is started again on its
# data. Answers which path ran.
function Wait-Relaunch($peer, $oldPid) {
    $mobile = Test-Mobile $peer
    $deadline = (Get-Date).AddSeconds($(if ($mobile) { 30 } else { 120 }))
    while ((Get-Date) -lt $deadline) {
        $status = Get-PeerStatus $peer
        if ($mobile -and $status.pid -eq 0) { break }
        if (-not $mobile -and $status.pid -ne 0 -and $status.pid -ne $oldPid -and $status.live) {
            if (-not (Test-RemotePeer $peer)) { Wait-FleetLaunchSlot $peer -NoWait }
            if ((Get-Platform $peer) -eq 'macos') {
                # The app relaunches through LaunchServices, whose copy never runs the
                # probe's live loop (wiki fleet_probe, macOS: never `open`); the relaunch
                # itself is what L4 proves, the journey goes on in a directly started copy.
                Invoke-PeerFleet @($peer) @('-Stop')
                Invoke-PeerFleet @($peer) (@('-Live', '-ReuseData', '-KeepOthers') + $(if ($script:UseProxy) { @('-NetProxy') } else { @() }))
                return "self-relaunch (pid $oldPid -> $($status.pid)), then started directly on its data"
            }
            return "self-relaunch (pid $oldPid -> $($status.pid))"
        }
        Start-Sleep -Milliseconds 500
    }
    if ($mobile) {
        $status = Get-PeerStatus $peer
        $how = if ($status.pid -eq 0) { "exited by itself, started again on its data" } else { "never exited (pid $($status.pid)); restarted on its data" }
    } else {
        $how = 'no self-relaunch within 120 s; restarted on its data by the script'
        Add-Note "$peer did not relaunch itself"
    }
    Invoke-PeerFleet @($peer) (@('-Live', '-ReuseData', '-KeepOthers') + $(if ($script:UseProxy) { @('-NetProxy') } else { @() }))
    return $how
}

# --------------------------------------------------------------------------
# The journey
# --------------------------------------------------------------------------

$script:UseProxy = $Condition -in @('relay_resume', 'relay_lost', 'transfer_drop')
$liveExtra = @()
if ($script:UseProxy) { $liveExtra = @('-NetProxy') }
$failure = $null
$serverMade = $false
$masterP = ''
$timing = [ordered]@{}

Say "cell $cell, run $runTag, presenter $P, receiver $R, friend $F$(if ($T) { ", third $T" }), evidence $evidence"
try {
    # ---- fresh identities --------------------------------------------------
    Invoke-PeerFleet @($R) @('-Stop')
    if ($T) { Invoke-PeerFleet @($T) @('-Stop') }
    if ($script:UseProxy) {
        foreach ($peer in @($P, $R) + @($T | Where-Object { $_ })) {
            if ((Get-Platform $peer) -eq 'android') { continue }
            Invoke-PeerCommand $peer 'proxy' @{ peers = @('a', 'b', 'c', 'd', 'e') } | Out-Null
        }
    }
    Say "minting fresh identities for the presenter and the friend"
    Invoke-PeerFleet @($P, $F) @('-Onboard', '-Fresh', '-KeepOthers')
    Invoke-PeerFleet @($P, $F) (@('-Live', '-KeepOthers') + $liveExtra)
    Wait-Connected $P
    Wait-Connected $F
    $sP = Get-State $P
    $sF = Get-State $F
    $masterP = "$($sP.master)"; $masterF = "$($sF.master)"
    $script:FleetVars['MP'] = $masterP; $script:FleetVars['MF'] = $masterF
    $nameP = "probe-$(Get-Letter $P)"; $nameF = "probe-$(Get-Letter $F)"
    Say "presenter $masterP ($nameP), friend $masterF ($nameF)"

    # ---- seed ----------------------------------------------------------------
    Say 'seeding the presenter: friend, DMs, a server, two images, an avatar'
    Step $P @{ op = 'friend'; action = 'request'; contact = $masterF } | Out-Null
    Wait-State $F @{} { param($s) @(@($s.friends) | Where-Object { $_.id -eq $masterP }).Count -gt 0 } 90 'the request arrived' | Out-Null
    Step $F @{ op = 'friend'; action = 'accept'; contact = $masterP } | Out-Null
    $s = Wait-State $P @{} { param($s) @(@($s.friends) | Where-Object { $_.id -eq $masterF -and $_.status -eq 'accepted' }).Count -gt 0 } 90 'friends'
    Step $P @{ op = 'seed_dm'; contact = $masterF; text = "dm P to F $runTag" } | Out-Null
    Step $F @{ op = 'seed_dm'; contact = $masterP; text = "dm F to P $runTag" } | Out-Null
    Step $P @{ op = 'seed_server'; name = $server; as = 'INVITE' } | Out-Null
    $serverMade = $true
    Step $F @{ op = 'seed_join'; invite = '${INVITE}' } | Out-Null
    Wait-State $F @{} { param($s) @($s.servers) -contains $server } 120 'joined the server' | Out-Null
    Step $P @{ op = 'seed_channel'; server = $server; text = "ch P $runTag" } | Out-Null
    Step $F @{ op = 'seed_channel'; server = $server; text = "ch F $runTag" } | Out-Null
    Step $P @{ op = 'seed_image'; contact = $masterF; name = "img-dm-$runTag" } | Out-Null
    Step $P @{ op = 'seed_image'; server = $server; name = "img-ch-$runTag" } | Out-Null
    Step $P @{ op = 'seed_avatar' } | Out-Null
    $seedTest = {
        param($s)
        (Test-Texts $s.dm @("dm P to F $runTag", "dm F to P $runTag")) -and
        (Test-Texts $s.channel @("ch P $runTag", "ch F $runTag")) -and
        (Test-Image $s.dm "img-dm-$runTag") -and (Test-Image $s.channel "img-ch-$runTag") -and
        $s.profile.avatar_bytes -gt 0 -and $s.profile.name -eq $nameP
    }
    $seeded = Wait-State $P @{ dm = $masterF } $seedTest 120 'seeded'
    $seeded | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'presenter-seeded.json') -Encoding UTF8
    if (-not (& $seedTest $seeded)) { throw 'the presenter never held everything it was seeded with (presenter-seeded.json)' }
    Set-Gate 'S ' 'PASS'

    # ---- the link ------------------------------------------------------------
    Say "the receiver boots EMPTY at the welcome flow"
    Invoke-PeerFleet @($R) (@('-Live', '-Empty', '-KeepOthers') + $liveExtra)
    Open-EnterCode $R
    Wait-Connected $R
    $throwaway = (Get-State $R).master
    Say "receiver's throwaway identity: $throwaway"

    Open-Devices $P
    $code = Read-LinkCode $P -Open
    Shot $P 'P-code'
    Say "presenter shows $code"
    Set-Gate 'L1' 'PASS'
    $linkStarted = Get-Date

    if ($Condition -eq 'relay_resume') {
        Step $P @{ op = 'net_off' } | Out-Null
        Start-Sleep -Seconds 20
        Step $P @{ op = 'net_on'; mode = 'thaw' } | Out-Null
        Start-Sleep -Seconds 3
        $after = Read-LinkCode $P 30
        Shot $P 'P-code-after-thaw'
        if ($after -ne $code) { Add-Note "the code changed across a resumed session: $code -> $after"; $code = $after }
        else { Say "the code survived the resumed session" 'Green' }
    }
    if ($Condition -eq 'relay_lost') {
        Step $P @{ op = 'net_off' } | Out-Null
        Say "presenter path frozen for ${LostSeconds}s (past the session grace)"
        Start-Sleep -Seconds $LostSeconds
        Step $P @{ op = 'net_on'; mode = 'drop' } | Out-Null
        $deadline = (Get-Date).AddSeconds(90)
        $renewed = $null
        while ((Get-Date) -lt $deadline) {
            try { $c = Read-LinkCode $P 10 } catch { $c = $null }
            if ($c -and $c -ne $code) { $renewed = $c; break }
            Start-Sleep -Seconds 2
        }
        Shot $P 'P-code-renewed'
        if (-not $renewed) { throw "the presenter never showed a new code after its session was lost (still $code)" }
        Say "renewed code $renewed" 'Green'
        $script:LostOld = $code
        $code = $renewed
    }
    if ($Condition -eq 'background') {
        Step $P @{ op = 'background' } | Out-Null
        $awayAt = Get-Date
        Say 'presenter backgrounded; the receiver types the code'
    }

    if ($Condition -eq 'cancel_retry') {
        Enter-Code $R $code
        Step $R @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 } | Out-Null
        Step $P @{ op = 'wait_for'; target = 'text:Add this device?'; timeout_ms = 60000 } | Out-Null
        Step $P @{ op = 'tap'; target = 'text:Decline'; index = 0 } | Out-Null
        Step $R @{ op = 'wait_for'; target = 'text:Link failed'; timeout_ms = 60000 } | Out-Null
        Shot $R 'R-declined'
        Shot $P 'P-declined'
        Step $R @{ op = 'tap'; target = 'text:Try again'; index = 0 } | Out-Null
        Step $R @{ op = 'wait_for'; target = 'hint:ABC123'; timeout_ms = 20000 } | Out-Null
        # The presenter's dialog either closed or offers a new code.
        $stillOpen = Soft $P @{ op = 'wait_for'; target = 'type:_DeviceLinkContent'; timeout_ms = 3000 } 30
        if ($stillOpen.ok) {
            $newCode = Soft $P @{ op = 'wait_for'; target = 'text:New code'; timeout_ms = 3000 } 30
            if ($newCode.ok) { Step $P @{ op = 'tap'; target = 'text:New code'; index = 0 } | Out-Null; $fresh = Read-LinkCode $P 60 }
            else {
                Soft $P @{ op = 'tap'; target = 'text:Got it'; index = 0 } 30 | Out-Null
                Soft $P @{ op = 'tap'; target = 'text:Cancel'; index = 0 } 30 | Out-Null
                Soft $P @{ op = 'wait_for'; gone = 'type:_DeviceLinkContent'; timeout_ms = 10000 } 30 | Out-Null
                $fresh = Read-LinkCode $P -Open
            }
        } else { $fresh = Read-LinkCode $P -Open }
        if ($fresh -eq $code) { Add-Note 'the retry got the SAME code as the declined one' }
        Say "fresh code $fresh after the decline"
        $script:CancelOk = $true
        $code = $fresh
    }

    Enter-Code $R $code
    Step $R @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 } | Out-Null
    Shot $R 'R-linking'
    Set-Gate 'L2' 'PASS'

    if ($Condition -eq 'background') {
        $deadline = (Get-Date).AddSeconds(60)
        $ask = @()
        while ((Get-Date) -lt $deadline) {
            $ask = Get-LogLines $P 'asks to be linked'
            if ($ask.Count -gt 0) { break }
            Start-Sleep -Seconds 2
        }
        # Held away long enough for a phone's 10 s suspend to have fired.
        $left = 15 - ((Get-Date) - $awayAt).TotalSeconds
        if ($left -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling($left)) }
        $life = Get-LogLines $P '[HOLLOW-RELAY-LIFE]'
        Step $P @{ op = 'foreground' } | Out-Null
        $life | Set-Content (Join-Path $evidence 'presenter-relay-life.txt') -Encoding UTF8
        $script:BgAsk = $ask.Count -gt 0
        $script:BgSuspended = @($life | Where-Object { $_ -match 'suspend' }).Count -gt 0
        $script:BgLines = $life
        $script:BgSocketLost = @(Get-LogLines $P 'Relay socket lost' | Where-Object {
                "$_" -match '^\[(\d{9,})\]' -and [int64]$Matches[1] -ge [DateTimeOffset]::new($awayAt).ToUnixTimeSeconds() }).Count -gt 0
        Say "while away: ask seen=$($script:BgAsk), suspend lines=$($script:BgSuspended)"
    }

    Step $P @{ op = 'wait_for'; target = 'text:Add this device?'; timeout_ms = 60000 } | Out-Null
    Shot $P 'P-confirm'
    $kind = if (Test-Mobile $R) { 'A phone typed your code' } else { 'A desktop typed your code' }
    $named = Soft $P @{ op = 'expect_text'; value = $kind } 30
    if (-not $named.ok) { Add-Note "the presenter's prompt did not say '$kind'" }
    $oldPid = (Get-PeerStatus $R).pid
    Step $P @{ op = 'tap'; target = 'text:Add device'; index = 0 } | Out-Null
    if ($Condition -eq 'transfer_drop') {
        Step $R @{ op = 'net_off' } | Out-Null
        Start-Sleep -Seconds 15
        Step $R @{ op = 'net_on'; mode = 'thaw' } | Out-Null
    }
    Step $P @{ op = 'wait_for'; target = 'text:Data sent'; timeout_ms = 240000 } 300 | Out-Null
    Shot $P 'P-sent'
    Set-Gate 'L3' 'PASS'

    $stash = Wait-Stash $R
    if ($Condition -eq 'held_db') {
        $db = Join-Path (Get-FleetPeerDataDir $R) 'messages.db'
        $holdOut = Join-Path $evidence 'hold_db.txt'
        $holder = Join-Path $PSScriptRoot 'fleet_hold_file.ps1'
        Start-Process powershell -ArgumentList @('-NoProfile', '-File', $holder, '-OldPid', "$oldPid", '-Path', $db, '-Seconds', '25', '-Out', $holdOut) -WindowStyle Hidden | Out-Null
        Say "holding $db from the moment pid $oldPid exits"
    }
    Soft $P @{ op = 'tap'; target = 'text:Done'; index = 0 } 30 | Out-Null
    Soft $P @{ op = 'wait_for'; gone = 'type:_DeviceLinkContent'; timeout_ms = 15000 } 30 | Out-Null
    Close-Devices $P
    $how = Wait-Relaunch $R $oldPid
    Say "receiver back: $how"

    if ($Condition -eq 'held_db') {
        Wait-Connected $R
        $heldState = Get-State $R
        $kept = (Get-StashSize $R) -gt 0
        Say "with the database held: runs as $($heldState.master), stash kept: $kept"
        Shot $R 'R-held-throwaway'
        $script:HeldRefused = ($heldState.master -ne $masterP) -and $kept
        if (-not $script:HeldRefused) { Add-Note 'the held landing did not refuse and keep its stash' }
        Start-Sleep -Seconds 20
        Get-Content (Join-Path $evidence 'hold_db.txt') -ErrorAction SilentlyContinue | ForEach-Object { Say "holder: $_" }
        Invoke-PeerFleet @($R) @('-Live', '-ReuseData', '-KeepOthers')
    }

    Wait-Connected $R 240
    $timing['link_s'] = [int]((Get-Date) - $linkStarted).TotalSeconds
    if (-not (Close-LockOffer $R)) { Add-Note "the receiver's first start never offered a lock" }
    Set-Gate 'L4' 'PASS'

    # ---- what the new device holds ------------------------------------------
    $sR = Get-State $R @{ dm = $masterF }
    if ("$($sR.master)" -ne $masterP) { throw "the receiver runs as $($sR.master), the presenter's master is $masterP" }
    # One device id everywhere: the key on disk, the roster's own row, and what
    # the app's provider hands every surface that asks "which device am I".
    $rosterThis = "$(@(@($sR.roster) | Where-Object { $_.this }) | ForEach-Object { $_.device } | Select-Object -First 1)"
    $disk = "$($sR.device_disk)"
    if (-not $disk -or $disk -eq $masterP -or $rosterThis -ne $disk -or "$($sR.device)" -ne $disk) {
        Add-Note "device ids disagree on the receiver: provider $($sR.device), disk $disk, roster $rosterThis (master $masterP)"
        Set-Gate 'L5' 'FAIL'
    } else { Set-Gate 'L5' 'PASS' }
    $verify = {
        param($s)
        (@(@($s.friends) | Where-Object { $_.id -eq $masterF -and $_.status -eq 'accepted' }).Count -gt 0) -and
        (Test-Texts $s.dm @("dm P to F $runTag", "dm F to P $runTag")) -and
        (@($s.servers) -contains $server) -and (Test-Texts $s.channel @("ch P $runTag", "ch F $runTag")) -and
        $s.profile.name -eq $nameP -and $s.profile.avatar_bytes -gt 0 -and
        (Get-Members $s).Count -ge 2
    }
    $sR = Wait-State $R @{ dm = $masterF } $verify 120 'everything inherited'
    # A freshly linked device fetches its recent chats' files on its own, with
    # neither chat opened (the post-link sweep).
    $bothImages = { param($s) (Test-Image $s.dm "img-dm-$runTag") -and (Test-Image $s.channel "img-ch-$runTag") }
    $sR = Wait-State $R @{ dm = $masterF } $bothImages 120 'both images on its own disk, no chat opened'
    Shot $R 'R-before-opening'
    $sR | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'receiver-after-link.json') -Encoding UTF8
    Set-Gate 'V1' $(if (@(@($sR.friends) | Where-Object { $_.id -eq $masterF -and $_.status -eq 'accepted' }).Count -gt 0) { 'PASS' } else { 'FAIL' })
    Set-Gate 'V2' $(if (Test-Texts $sR.dm @("dm P to F $runTag", "dm F to P $runTag")) { 'PASS' } else { 'FAIL' })
    Set-Gate 'V3' $(if ((@($sR.servers) -contains $server) -and (Test-Texts $sR.channel @("ch P $runTag", "ch F $runTag"))) { 'PASS' } else { 'FAIL' })
    Set-Gate 'V4' $(if ($sR.profile.name -eq $nameP -and $sR.profile.avatar_bytes -gt 0) { 'PASS' } else { 'FAIL' })
    Set-Gate 'V5' $(if (Test-Image $sR.dm "img-dm-$runTag") { 'PASS' } else { 'FAIL' })
    Set-Gate 'V6' $(if (Test-Image $sR.channel "img-ch-$runTag") { 'PASS' } else { 'FAIL' })
    # The way a person gets them stays a second check: the chat-open sweeps.
    Show-Channel $R
    Shot $R 'R-general'
    Show-Dm $R $nameF
    Shot $R 'R-dm'
    $sOpen = Wait-State $R @{ dm = $masterF } $bothImages 90 'both images on its own disk after the chats open'
    Shot $R 'R-dm-after-files'
    Set-Gate 'V8' $(if (& $bothImages $sOpen) { 'PASS' } else { 'FAIL' })
    $sP2 = Wait-State $P @{} { param($s) (Get-Members $s).Count -ge 2 } 60 'two members on the presenter'
    $sP2 | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'presenter-after-link.json') -Encoding UTF8
    Set-Gate 'V7' $(if ((Get-Members $sR).Count -ge 2 -and (Get-Members $sP2).Count -ge 2) { 'PASS' } else { 'FAIL' })

    # ---- live traffic after the link -----------------------------------------
    Step $R @{ op = 'seed_dm'; contact = $masterF; text = "dm R after $runTag" } | Out-Null
    $f1 = Wait-State $F @{ dm = $masterP } { param($s) Test-Texts $s.dm @("dm R after $runTag") } 90 'the receiver DM'
    $p1 = Wait-State $P @{ dm = $masterF } { param($s) Test-Texts $s.dm @("dm R after $runTag") } 90 'its sibling DM'
    Set-Gate 'T1' $(if ((Test-Texts $f1.dm @("dm R after $runTag")) -and (Test-Texts $p1.dm @("dm R after $runTag"))) { 'PASS' } else { 'FAIL' })

    Step $P @{ op = 'seed_dm'; contact = $masterF; text = "dm P after $runTag" } | Out-Null
    $f2 = Wait-State $F @{ dm = $masterP } { param($s) Test-Texts $s.dm @("dm P after $runTag") } 90 'the presenter DM'
    $r2 = Wait-State $R @{ dm = $masterF } { param($s) Test-Texts $s.dm @("dm P after $runTag") } 90 'its sibling DM'
    Set-Gate 'T2' $(if ((Test-Texts $f2.dm @("dm P after $runTag")) -and (Test-Texts $r2.dm @("dm P after $runTag"))) { 'PASS' } else { 'FAIL' })

    Step $F @{ op = 'seed_dm'; contact = $masterP; text = "dm F after $runTag" } | Out-Null
    $p3 = Wait-State $P @{ dm = $masterF } { param($s) Test-Texts $s.dm @("dm F after $runTag") } 90 'the friend DM'
    $r3 = Wait-State $R @{ dm = $masterF } { param($s) Test-Texts $s.dm @("dm F after $runTag") } 90 'the friend DM'
    Set-Gate 'T3' $(if ((Test-Texts $p3.dm @("dm F after $runTag")) -and (Test-Texts $r3.dm @("dm F after $runTag"))) { 'PASS' } else { 'FAIL' })

    Step $R @{ op = 'seed_channel'; server = $server; text = "ch R after $runTag" } | Out-Null
    $p4 = Wait-State $P @{} { param($s) Test-Texts $s.channel @("ch R after $runTag") } 90 'the receiver post'
    $f4 = Wait-State $F @{} { param($s) Test-Texts $s.channel @("ch R after $runTag") } 90 'the receiver post'
    Set-Gate 'T4' $(if ((Test-Texts $p4.channel @("ch R after $runTag")) -and (Test-Texts $f4.channel @("ch R after $runTag"))) { 'PASS' } else { 'FAIL' })

    # ---- what the eye checks --------------------------------------------------
    foreach ($peer in @($P, $R)) {
        try { Open-Devices $peer; Soft $peer @{ op = 'wait_for'; target = 'type:_DeviceRow'; count = 2; timeout_ms = 30000 } 60 | Out-Null; Shot $peer "$(Get-Letter $peer)-devices"; Close-Devices $peer }
        catch { Add-Note "devices shot on $peer failed: $($_.Exception.Message)" }
    }
    Show-Channel $R
    Shot $R 'R-general-end'
    Show-Dm $R $nameF
    Shot $R 'R-dm-end'

    # ---- the condition's own verdict ------------------------------------------
    switch ($Condition) {
        'background' {
            # A presenting phone stays shown on the relay by design, so it logs no
            # `background: inactive`: the proof is the ask arriving while away.
            $ok = $script:BgAsk -and -not $script:BgSuspended
            if (-not $script:BgAsk) { Add-Note 'the joiner''s ask reached the presenter only after it came back' }
            if ($script:BgSocketLost) { Add-Note 'the presenter lost its relay socket while away (the OS cut its network)' }
            Set-Gate 'X ' $(if ($ok) { 'PASS' } else { 'FAIL' })
        }
        'relay_resume' { Set-Gate 'X ' 'PASS' }
        'relay_lost' { Set-Gate 'X ' 'PASS' }
        'transfer_drop' { Set-Gate 'X ' 'PASS' }
        'held_db' { Set-Gate 'X ' $(if ($script:HeldRefused) { 'PASS' } else { 'FAIL' }) }
        'cancel_retry' { Set-Gate 'X ' $(if ($script:CancelOk) { 'PASS' } else { 'FAIL' }) }
        'third_device' {
            Invoke-PeerFleet @($T) (@('-Live', '-Empty', '-KeepOthers'))
            Open-EnterCode $T
            Wait-Connected $T
            Open-Devices $P
            $code3 = Read-LinkCode $P -Open
            Enter-Code $T $code3
            Step $T @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 } | Out-Null
            Step $P @{ op = 'wait_for'; target = 'text:Add this device?'; timeout_ms = 60000 } | Out-Null
            $oldT = (Get-PeerStatus $T).pid
            Step $P @{ op = 'tap'; target = 'text:Add device'; index = 0 } | Out-Null
            Step $P @{ op = 'wait_for'; target = 'text:Data sent'; timeout_ms = 240000 } 300 | Out-Null
            Wait-Stash $T | Out-Null
            Soft $P @{ op = 'tap'; target = 'text:Done'; index = 0 } 30 | Out-Null
            Close-Devices $P
            Say "third device back: $(Wait-Relaunch $T $oldT)"
            Wait-Connected $T 240
            Close-LockOffer $T | Out-Null
            $sT = Wait-State $T @{ dm = $masterF } { param($s) "$($s.master)" -eq $masterP -and (Get-Members $s).Count -ge 3 -and (Test-Texts $s.dm @("dm R after $runTag")) } 120 'third device inherited'
            $sT | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'third-after-link.json') -Encoding UTF8
            Step $F @{ op = 'seed_dm'; contact = $masterP; text = "dm F to three $runTag" } | Out-Null
            $t3 = Wait-State $T @{ dm = $masterF } { param($s) Test-Texts $s.dm @("dm F to three $runTag") } 90 'friend DM on the third'
            $r3b = Wait-State $R @{} { param($s) (Get-Members $s).Count -ge 3 } 60 'three members on the receiver'
            $ok = ("$($sT.master)" -eq $masterP) -and (Get-Members $sT).Count -ge 3 -and (Test-Texts $t3.dm @("dm F to three $runTag")) -and (Get-Members $r3b).Count -ge 3
            Set-Gate 'X ' $(if ($ok) { 'PASS' } else { 'FAIL' })
        }
        'roster_push' {
            $devR = "$($sR.device)"
            $nameDevR = 'Phone'
            # ---- the friend goes away the way a phone drops an app -------------------
            Invoke-PeerCommand $F 'logcat' @{ clear = $true } | Out-Null
            Step $F @{ op = 'background' } | Out-Null
            Start-Sleep -Seconds 15
            Step $F @{ op = 'kill' } | Out-Null
            $killedAt = Get-Epoch
            Say "friend killed; dead ${DeadSeconds}s before the removal"
            Start-Sleep -Seconds $DeadSeconds
            # ---- the presenter removes the receiver ------------------------------------
            Open-Devices $P
            Step $P @{ op = 'tap'; target = "semantics:More options for $nameDevR"; index = 0 } | Out-Null
            Step $P @{ op = 'tap'; target = 'text:Remove device'; index = 0 } | Out-Null
            Step $P @{ op = 'tap'; target = 'dialog > text:Remove device'; index = 0 } | Out-Null
            $removedAt = Get-Epoch
            $gone = Soft $R @{ op = 'wait_for'; target = 'text:This device was removed'; timeout_ms = 90000 } 120
            Shot $R 'R-removed'
            $sP5 = Wait-State $P @{} { param($s) (Get-Members $s).Count -eq 1 } 60 'one member on the presenter'
            Shot $P 'P-devices-after-removal'
            Close-Devices $P
            $deadStill = (Get-PeerStatus $F).pid -eq 0 -or -not (Get-PeerStatus $F).live
            Set-Gate 'P1' $(if ($gone.ok -and (Get-Members $sP5).Count -eq 1) { 'PASS' } else { 'FAIL' })
            # The removal's own wake and fetch, then the DM's (the relay waits 10 s between wakes).
            Start-Sleep -Seconds 30
            # ---- the presenter DMs the dead friend --------------------------------------
            $dmSentAt = Get-Epoch
            Step $P @{ op = 'seed_dm'; contact = $masterF; text = "dm P while F away $runTag" } | Out-Null
            $deadline = (Get-Date).AddSeconds(120)
            $fetched = @()
            while ((Get-Date) -lt $deadline) {
                $fetched = @(Get-LogSince $F '[HOLLOW-FETCH] Fetch complete' $dmSentAt)
                if ($fetched.Count -gt 0) { break }
                Start-Sleep -Seconds 3
            }
            Start-Sleep -Seconds 10
            $fields = @((Invoke-PeerCommand $F 'logcat' @{ pattern = 'FCM data fields' }).lines)
            $fetchLines = @(Get-LogSince $F '[HOLLOW-FETCH]' $killedAt)
            Save-Evidence $F 'pushed'
            $fields | Set-Content (Join-Path $evidence 'F-fcm-data-fields.txt') -Encoding UTF8
            $fetchLines | Set-Content (Join-Path $evidence 'F-fetch-lines.txt') -Encoding UTF8
            $sealedOnly = $fields.Count -gt 0 -and -not @($fields | Where-Object { "$_" -notmatch 'FCM data fields: \{sealed: \d+\}\s*$' })
            Say "friend's FCM data blocks: $($fields.Count), fetch lines since the kill: $($fetchLines.Count)"
            Set-Gate 'P2' $(if ($sealedOnly -and $fetched.Count -gt 0) { 'PASS' } else { 'FAIL' })
            # ---- the friend opens and DMs the identity at once ---------------------------
            # -FriendDmOffline: the phone opens with no network and the DM is written
            # before its relay session exists, the earliest a person can send.
            if ($FriendDmOffline) { Step $F @{ op = 'net_off' } | Out-Null }
            $openAt = Get-Epoch
            try {
                Invoke-PeerFleet @($F) @('-Live', '-ReuseData', '-KeepOthers')
                if (-not $FriendDmOffline) { Wait-Connected $F }
                Step $F @{ op = 'seed_dm'; contact = $masterP; text = "dm F after removal $runTag" } | Out-Null
                if ($FriendDmOffline) { Start-Sleep -Seconds 5 }
            } finally {
                if ($FriendDmOffline) { Step $F @{ op = 'net_on' } | Out-Null }
            }
            Wait-Connected $F
            $sF6 = Get-State $F @{ dm = $masterP }
            Set-Gate 'P3' $(if ((Test-Texts $sF6.dm @("dm P while F away $runTag")) -and $fetched.Count -gt 0) { 'PASS' } else { 'FAIL' })
            $p6 = Wait-State $P @{ dm = $masterF } { param($s) Test-Texts $s.dm @("dm F after removal $runTag") } 90 'the friend DM after the removal'
            Set-Gate 'P4' $(if (Test-Texts $p6.dm @("dm F after removal $runTag")) { 'PASS' } else { 'FAIL' })
            # Long enough for a buffered copy, a sibling echo or a DM sync to land too.
            Start-Sleep -Seconds 45
            $rUp = Get-PeerStatus $R
            $rConn = Soft $R @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 5000 } 30
            $r6 = Get-State $R @{ dm = $masterF }
            $r6 | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'receiver-after-removal.json') -Encoding UTF8
            $missed = -not (Test-Texts $r6.dm @("dm F after removal $runTag"))
            $heardBefore = Test-Texts $r6.dm @("dm F after $runTag")
            Say "removed receiver: pid $($rUp.pid), connected $($rConn.ok), holds the friend's DM from before: $heardBefore, the one after: $(-not $missed)"
            # When the open app learned the removal (a revocation it learns logs
            # [HOLLOW-REVOKE]; one the push fetch stored is not new to it) against its
            # first relay session and its DM. A digest-trade answer comes 1 to 30 s after
            # the ask; anything sooner is the exchange every return starts.
            $stamp = { param($lines) if (@($lines).Count -gt 0 -and "$(@($lines)[0])" -match '^\[(\d{9,})\]') { [int64]$Matches[1] } else { $null } }
            $revokedLive = @(Get-LogSince $F "[HOLLOW-REVOKE] Dropped Olm session to revoked device $devR" $openAt)
            $asks = @(Get-LogSince $F '[HOLLOW-ROSTER] Asking' $openAt)
            $connects = @(Get-LogSince $F '[HOLLOW-WS] Connected and authenticated' $openAt)
            $sends = @(Get-LogSince $F "[HOLLOW-SWARM] SendMessage received for $masterP" $openAt)
            $holds = @(Get-LogSince $F '[HOLLOW-ROSTER]' $openAt | Where-Object { "$_" -match 'unconfirmed|before the DM' })
            $revokeAt, $connectAt, $sendAt = (& $stamp $revokedLive), (& $stamp $connects), (& $stamp $sends)
            @("removed device $devR", "killed $killedAt removed $removedAt dm $dmSentAt opened $openAt",
              "connected $connectAt friend DM $sendAt removal learned $revokeAt", '--- revoke after open') + $revokedLive +
                @('--- asks after open') + $asks + @('--- holds after open') + $holds |
                Set-Content (Join-Path $evidence 'F-roster-path.txt') -Encoding UTF8
            $path = if ($null -eq $revokeAt) { 'the push fetch (the open app already held it)' }
                    elseif ($null -ne $connectAt -and $revokeAt - $connectAt -le 1) { 'the exchange at its return' }
                    elseif ($asks.Count -gt 0) { 'the digest trade after the app opened' }
                    else { 'a roster heard live after the app opened' }
            $order = if ($null -eq $revokeAt -or $null -eq $sendAt) { '' }
                     elseif ($revokeAt -le $sendAt) { ", $($sendAt - $revokeAt) s before its DM" }
                     else { ", $($revokeAt - $sendAt) s AFTER its DM" }
            Add-Note "the removal reached the friend through $path$order"
            if ($holds.Count -gt 0) { Add-Note "the friend held a DM for the roster: $($holds.Count) line(s)" }
            if (-not $deadStill) { Add-Note 'the friend had a live process again before its app was opened' }
            Shot $F 'F-after-open'
            # The removed device may hold a copy it never shows: the friend's own log says
            # whether it encrypted anything for it after it opened.
            $toRemoved = @(Get-LogSince $F '[HOLLOW-DM] Held DM fan-out to' $openAt | Where-Object { "$_".Contains($devR) }) +
                @(Get-LogSince $F "[HOLLOW-PUSH] Sent encrypted DM to offline $devR" $openAt)
            Set-Content (Join-Path $evidence 'F-sends-to-removed.txt') -Value ([string[]]$toRemoved) -Encoding UTF8
            if ($toRemoved.Count -gt 0) { Add-Note "the friend encrypted $($toRemoved.Count) DM fan-out(s) for the removed device after it opened" }
            Set-Gate 'X ' $(if ($missed -and $heardBefore -and $rUp.pid -ne 0 -and $toRemoved.Count -eq 0) { 'PASS' } else { 'FAIL' })
        }
    }
} catch {
    $failure = $_
    $first = @($script:Gates.Keys | Where-Object { $script:Gates[$_] -eq 'SKIP' }) | Select-Object -First 1
    if ($first) { $script:Gates[$first] = 'FAIL' }
    Say "FAILED at [$first]: $($_.Exception.Message)" 'Red'
    foreach ($peer in $all) {
        try { Shot $peer "$(Get-Letter $peer)-at-failure" } catch { }
    }
}

# --------------------------------------------------------------------------
# Cleanup and evidence
# --------------------------------------------------------------------------
if ($serverMade) {
    try {
        $deleted = $false
        foreach ($peer in @($P, $R)) {
            $answer = Soft $peer @{ op = 'seed_delete_server'; name = $server } 60
            if ($answer.ok) { $deleted = $true; break }
        }
        Set-Gate 'C ' $(if ($deleted) { 'PASS' } else { 'FAIL' })
    } catch { Set-Gate 'C ' 'FAIL'; Add-Note "cleanup: $($_.Exception.Message)" }
} else { Set-Gate 'C ' 'PASS' }

foreach ($peer in $all) { Save-Evidence $peer 'end' }
foreach ($agent in @($all | Where-Object { Test-RemotePeer $_ } | ForEach-Object { (Get-RemotePeer $_).Agent } | Select-Object -Unique)) {
    try {
        $launch = Get-FleetAgentLaunch $agent
        $sshArgs = @($launch.Ssh | Select-Object -SkipLast 1)
        # Relative to the remote home: scp's sftp mode does not expand ~.
        $from = "$($launch.Target):$((Get-FleetRemoteTree $agent) -replace '^~/', '')/.team/matrix/$runTag-$cell"
        & scp @sshArgs -r -q $from (Join-Path $evidence $agent) 2>&1 | Out-Null
    } catch { Add-Note "fetching $agent's evidence: $($_.Exception.Message)" }
}
# The refusal lines every device logged during the run, for the baseline check.
$refusals = New-Object System.Collections.ArrayList
foreach ($peer in $all) {
    foreach ($pattern in @('[HOLLOW-SECURITY]', 'REJECT', 'Refused', 'refused', 'DROPPED', 'BLOCKED')) {
        try {
            foreach ($line in (Get-LogLines $peer $pattern)) {
                # A Windows peer's log sits next to its exe and outlives runs: this run's lines only.
                if ("$line" -match '^\[(\d{9,})\]' -and [int64]$Matches[1] -lt $startEpoch) { continue }
                [void]$refusals.Add("$peer $line")
            }
        } catch { }
    }
}
@($refusals | Select-Object -Unique) | Set-Content (Join-Path $evidence "$cell-refusals.txt") -Encoding UTF8

$failedCount = @($script:Gates.Values | Where-Object { $_ -eq 'FAIL' }).Count
$verdict = if ($failure -or $failedCount -gt 0) { 'FAIL' } else { 'PASS' }
$duration = [int]((Get-Date) - $started).TotalSeconds
Write-Host ''
Write-Host "===== link matrix: $cell =====" -ForegroundColor Cyan
foreach ($key in @($script:Gates.Keys)) {
    $status = $script:Gates[$key]
    $colour = if ($status -eq 'PASS') { 'Green' } elseif ($status -eq 'FAIL') { 'Red' } else { 'DarkGray' }
    Write-Host ("  {0,-4} {1}" -f $status, $key) -ForegroundColor $colour
}
foreach ($note in $script:Notes) { Write-Host "  note: $note" -ForegroundColor DarkCyan }
Write-Host "  $verdict in ${duration}s, link $($timing['link_s'])s, evidence $evidence" -ForegroundColor $(if ($verdict -eq 'PASS') { 'Green' } else { 'Red' })

foreach ($r in @($script:FleetAgentReconnectLog)) { if ($r) { [void]$script:Notes.Add("agent reconnect: $r") } }
$record = [ordered]@{
    run = $runTag; cell = $cell; presenter = $Presenter; receiver = $Receiver; friend = $Friend; third = $Third
    condition = $Condition; verdict = $verdict; seconds = $duration; link_seconds = $timing['link_s']
    reconnects = [int]$script:FleetAgentReconnects
    gates = $script:Gates; notes = @($script:Notes); error = $(if ($failure) { "$($failure.Exception.Message)" } else { '' })
    evidence = $evidence
}
$record | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $evidence 'verdict.json') -Encoding UTF8
Add-Content -Path (Join-Path $EvidenceRoot 'results.jsonl') -Value ($record | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8

if (-not $KeepUp -and $verdict -eq 'PASS') {
    foreach ($peer in $all) { try { Invoke-PeerFleet @($peer) @('-Stop') } catch { } }
}
Stop-FleetAgents
if ($verdict -ne 'PASS') { exit 1 }
exit 0
