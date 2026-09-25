# Self-hosting across TWO relays, driven through three real instances: an
# invite carries the relay it was made on, a peer on a different relay is asked
# before it moves, and a peer that agrees switches, restarts and joins.
#
#   powershell -File scripts\fleet_relay_switch.ps1 -RelayHost my.duckdns.org
#   powershell -File scripts\fleet_relay_switch.ps1 -RelayHost ... -Build
#   powershell -File scripts\fleet_relay_switch.ps1 -RelayHost ... -Keep
#   powershell -File scripts\fleet_relay_switch.ps1 -RelayHost ... -NoTurnRelay
#   powershell -File scripts\fleet_relay_switch.ps1 -RelayHost ... -TurnGateOnly  # G5 alone
#
# ## Why a script and not a scenario JSON
#
# Peer c RELAUNCHES ITSELF in the middle: accepting the switch saves the invite
# under `pending_invite_after_switch`, writes the new relay and calls
# relaunchApp(), so a new pid comes up on the same data directory and replays
# the invite. A scenario file has no op for a peer that leaves and comes back,
# the same reason fleet_device_link.ps1 and fleet_pending_join.ps1 are scripts.
#
# The other reason is the fleet itself: a and b live on DIFFERENT relays, and a
# relay is chosen in the welcome dialog before an identity exists, so each side
# takes its own `fleet.ps1 -Onboard -Fresh -Relay ...` call.
#
#   G1  a, on the self-hosted relay, creates a server and its invite names it.
#   G2  b, on the official relay, pastes it, is warned, cancels, and NOTHING
#       about b changes: same relay, same pid, no server.
#   G3  c pastes it, accepts, switches relay, restarts, joins and talks both
#       ways with a.
#   G4  the mirror image: an invite made on the official relay warns c, which
#       now lives on the self-hosted one.
#   G5  a relay with no TURN server says so in Settings > Network, and "Always
#       relay calls" refuses to start a call against it. Only with
#       -NoTurnRelay, because it is a claim about the relay under test.
#
# Windows PowerShell 5.1 is what is installed here, so no pwsh-only syntax.

param(
    # The self-hosted relay a is onboarded onto, and the one c switches to.
    [Parameter(Mandatory = $true)]
    [string]$RelayHost,
    # Leave the instances running after a PASS. A FAILED run always leaves them
    # up, whatever this says.
    [switch]$Keep,
    # Build and stage the probe target first. Pass it after an app change.
    [switch]$Build,
    # Drive whatever identities are already live instead of minting new ones on
    # the two relays. Wrong for a first run: the relay replays buffered traffic
    # for three days, so a reused identity can be served an earlier run's join.
    [switch]$KeepIdentities,
    # Assert G5. The chip and the refusal are claims about the relay under
    # test, so they are only checked when the relay is known to run WITHOUT a
    # TURN server; otherwise the gate reports SKIP and says why.
    [switch]$NoTurnRelay,
    # Run G5 ALONE against the peers already on disk, for the second half of a
    # two-pass session: the relay is restarted without TURN and only that claim
    # is re-checked. Implies -NoTurnRelay, needs a and c to have already moved
    # to the relay under test, and never restores a fixture (that would put c
    # back on the official relay).
    [switch]$TurnGateOnly,
    [int]$BootTimeoutSeconds = 240
)

# `powershell -File` does NOT reject an unknown -Switch: it drops it into $args
# and binds the rest, so a mistyped flag would run a journey nobody asked for
# and report a clean pass for it.
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -RelayHost, -Keep, -Build, -KeepIdentities, -NoTurnRelay, -TurnGateOnly and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in every server name and every message: the relay holds
# undelivered traffic for three days, so a fixed string can be matched by an
# EARLIER run and pass before the send it was waiting for.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runTag = $script:FleetVars.RUN
$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$officialRelay = 'relay.anonlisten.com'
$selfServer = "fleet-relay-$runTag"
$officialServer = "fleet-official-$runTag"
$journeyPeers = if ($TurnGateOnly) { @('a', 'c') } else { @('a', 'b', 'c') }
if ($TurnGateOnly) { $NoTurnRelay = $true }
# A hostname needs no escaping, but the app encodes the value it stamps, so the
# assertion is written against the encoded form rather than against luck.
$relayEncoded = [uri]::EscapeDataString($RelayHost)

function Say($message, $colour = 'Cyan') { Write-Host "[relay-switch] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates. Declared up front so the closing report has a line for every one of
# them, including the ones a failure meant we never reached.
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{}
$script:Gates['G1 a stamped its own relay into the invite it made']        = 'SKIP'
$script:Gates['G2 b was warned, cancelled, and nothing about b changed']   = 'SKIP'
$script:Gates['G3 c switched relay, restarted and joined']                 = 'SKIP'
$script:Gates['G3b c and a talk both ways in the joined server']           = 'SKIP'
$script:Gates['G4 an official-relay invite warns the peer that moved']     = 'SKIP'
$script:Gates['G5a Settings > Network names a relay with no TURN server']  = 'SKIP'
$script:Gates['G5b Always relay calls refuses a call without TURN']        = 'SKIP'
$script:CleanupGate = 'C  cleanup: nothing this run created is left behind'
$script:Gates[$script:CleanupGate] = 'SKIP'
# 'n/a' is a gate this run deliberately does not own, as against 'SKIP', which
# is one it has not reached yet and would be blamed for a failure.
if ($TurnGateOnly) {
    foreach ($key in @($script:Gates.Keys)) {
        if ($key -notlike 'G5*' -and $key -ne $script:CleanupGate) { $script:Gates[$key] = 'n/a' }
    }
}
if (-not $NoTurnRelay) {
    $script:Gates['G5a Settings > Network names a relay with no TURN server'] = 'n/a'
    $script:Gates['G5b Always relay calls refuses a call without TURN'] = 'n/a'
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
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
}

# "Is this on screen right now", asked without printing anything. A soft step
# would report a FAIL line for a correct answer of no, which in a green run
# reads as damage.
function Test-Target($peer, $target, $timeoutMs = 1500) {
    $answer = Send-FleetStep $peer ([pscustomobject]@{
        op = 'wait_for'; target = $target; timeout_ms = $timeoutMs
    }) 120
    return [bool]$answer.ok
}

# Same as Step, but a failure is an ANSWER rather than the end of the run.
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
# "Online" are each printed by one surface and neither is reliably on screen.
function Wait-ForConnected($peer, $timeoutSeconds = 180) {
    Step $peer @{
        op = 'wait_for'; provider = 'connection'; equals = 'connected'
        timeout_ms = $timeoutSeconds * 1000
    }
}

# Which relay this instance is actually pointed at, from the provider rather
# than from the screen: the domain is only rendered in one settings row.
function Get-PeerRelay($peer) {
    $answer = Send-FleetStep $peer ([pscustomobject]@{
        op = 'capture'; from = 'provider'; key = 'relayDomain'; as = 'RELAY_NOW'
    }) 120
    if (-not $answer.ok) { throw "[$peer] could not read relayDomain: $($answer.message)" }
    return "$($script:FleetVars['RELAY_NOW'])"
}

# How many widgets a target matches right now.
function Get-MatchCount($peer, $target) {
    $answer = Send-FleetStep $peer ([pscustomobject]@{
        op = 'capture'; from = 'count'; target = $target; as = 'MATCHCOUNT'
    }) 120
    if (-not $answer.ok) { return 0 }
    return [int]$script:FleetVars['MATCHCOUNT']
}

# Taps a button in the TOPMOST dialog. Two dialogs can be stacked and both may
# carry the same word; routes are pushed in tree order, so the topmost one's
# copy is the last match and the index is not knowable when the step is written.
function Invoke-TopDialogTap($peer, $label) {
    # Not $matches: that name is PowerShell's own regex result variable.
    $hits = Get-MatchCount $peer "dialog > text:$label"
    if ($hits -lt 1) { throw "[$peer] no dialog button '$label' is on screen" }
    Step $peer @{ op = 'tap'; target = "dialog > text:$label"; index = ($hits - 1) }
}

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
    } else {
        $proc | Stop-Process -Force
    }
    # The lock file and the SQLCipher WAL are released on exit; give the handles
    # time to drop before anything else touches that directory.
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed" 'Yellow'
}

# Relaunch ONE peer on its EXISTING data directory. `fleet.ps1 -Live` restores
# every fixture, which would throw away the relay switch this journey is about.
function Restart-Peer($peer) {
    if (Test-SimBackend) { throw 'the relay-switch journey has no simulator branch yet' }
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
    Say "relaunched $peer (pid $($proc.Id)) on its existing data dir"
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { Say "$peer is live" 'Green'; return }
        if ($proc.HasExited) { throw "peer $peer died on launch.`n" + (Get-CrashTail $peer) }
        Start-Sleep -Milliseconds 300
    }
    throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
}

# Hand the out directory over to a copy of the app that is about to replace
# this one. The live loop truncates the OUTBOX on start but replays the whole
# INBOX from line 0, so a self-relaunch would re-run every step of the journey
# so far unless the inbox is emptied first; and `live-ready` is a file, so a
# stale one makes a booting peer look alive.
#
# Only ever call this on a peer that is ABOUT TO DIE: the live loop tracks its
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
    $kept = Join-Path $script:FleetOutRoot "kept\relay-$runTag-$peer-$label"
    if (-not (Test-Path $out)) { return }
    New-Item -ItemType Directory -Path $kept -Force | Out-Null
    Get-ChildItem $out -File -Include *.png, *.json, *.md, *.log, results.jsonl -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $kept -Force -ErrorAction SilentlyContinue }
    Say "kept $peer's artifacts in $kept" 'DarkGray'
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

# --------------------------------------------------------------------------
# The surfaces this journey drives
# --------------------------------------------------------------------------

function New-FleetServer($peer, $name) {
    Step $peer @{ op = 'tap'; target = 'semantics:Create a server'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'hint:My Awesome Server'; timeout_ms = 20000 }
    Step $peer @{ op = 'enter_text'; target = 'hint:My Awesome Server'; value = $name }
    Step $peer @{ op = 'tap'; target = 'text:Create'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = "server:$name"; timeout_ms = 60000 }
    Step $peer @{ op = 'open_server'; name = $name }
    Step $peer @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }
}

# The invite as the user copies it: right-click the server, Invite people, read
# the link off the panel.
function Get-ServerInvite($peer, $name, $as) {
    Step $peer @{ op = 'right_click'; target = "server:$name" }
    Step $peer @{ op = 'tap'; target = 'menu > text:Invite people' }
    # The panel's only SelectableText is the link itself; the server id next to
    # it is a plain Text.
    Step $peer @{ op = 'wait_for'; target = 'type:SelectableText'; timeout_ms = 20000 }
    Step $peer @{ op = 'capture'; target = 'type:SelectableText'; as = $as }
    # By its own button, not Escape: the link holds focus and a key press from
    # there has reached nothing before.
    Invoke-SoftStep $peer @{ op = 'tap'; target = 'dialog > semantics:Close'; index = 0 } | Out-Null
    $gone = Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'type:SelectableText'; timeout_ms = 5000 }
    if (-not $gone.ok) {
        Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
        Step $peer @{ op = 'wait_for'; gone = 'type:SelectableText'; timeout_ms = 10000 }
    }
    return "$($script:FleetVars[$as])"
}

# Opens the "+" dialog and submits an invite link. The relay dialog opens over
# it when the link names a relay this peer is not on.
function Invoke-InvitePaste($peer, $invite) {
    Step $peer @{ op = 'tap'; target = 'semantics:Create a server'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'hint:Invite link or server ID'; timeout_ms = 20000 }
    Step $peer @{ op = 'tap'; target = 'hint:Invite link or server ID' }
    Step $peer @{ op = 'enter_text'; target = 'hint:Invite link or server ID'; value = $invite }
    Step $peer @{ op = 'tap'; target = 'text:Join'; index = 0 }
}

function Close-JoinDialog($peer) {
    if (-not (Test-Target $peer 'hint:Invite link or server ID')) { return }
    Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
    Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'hint:Invite link or server ID'; timeout_ms = 5000 } | Out-Null
}

# The composer is TAPPED first: enter_text on an unfocused field reports success
# into nothing. Every send waits for its OWN optimistic row, so a send that
# never happened cannot be mistaken for a delivery failure on the other side.
function Send-Channel($peer, $channel, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = "hint:Message #$channel" }
        Step $peer @{ op = 'enter_text'; target = "hint:Message #$channel"; value = $body }
        Step $peer @{ op = 'key'; value = 'enter' }
        $landed = Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }
        if ($landed.ok) { return }
        Add-Note "$peer's #$channel composer swallowed the send on attempt $attempt"
        Invoke-SoftStep $peer @{ op = 'shot'; name = "relay-$runTag-$peer-swallow-$attempt" } | Out-Null
    }
    throw "[$peer] the #$channel composer never produced a row for '$body' after 3 attempts"
}

# Delete a server through the UI, as its owner. Used by the journey and the
# cleanup, so the two can never disagree about how it is done.
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

function Open-Settings($peer, $category) {
    Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_UserSettingsContent'; timeout_ms = 20000 }
    # SCOPED to the dialog: the Home dashboard has rows of the same name behind
    # it, they come first in tree order, and the unscoped tap lands on a
    # covered one.
    Step $peer @{ op = 'tap'; target = "type:_UserSettingsContent > text:$category"; index = 0 }
}

function Close-Settings($peer) {
    if (-not (Test-Target $peer 'type:_UserSettingsContent')) { return }
    Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
    $gone = Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 3000 }
    if ($gone.ok) { return }
    # Never a bare semantics:Close: it matches the window title bar first, and
    # that tap ends the process.
    Step $peer @{ op = 'tap'; target = 'type:_UserSettingsContent > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_UserSettingsContent'; timeout_ms = 10000 }
}

# The remove control is an icon button on the friend row, addressed by its
# purpose label; there is no context menu and no confirmation. Returns whether
# the friendship is actually gone, because a cleanup that cannot tell is a
# cleanup that leaks.
function Remove-Friendship($peer, $friendName) {
    Close-Settings $peer
    Open-Friends $peer
    Invoke-SoftStep $peer @{ op = 'tap'; target = 'type:HollowChip>text:Friends'; index = 0 } | Out-Null
    if (-not (Test-Target $peer 'semantics:Remove friend' 10000)) {
        Add-Note "$peer's Friends tab shows no Remove friend control for $friendName"
        Close-Friends $peer
        return $false
    }
    Step $peer @{ op = 'tap'; target = 'semantics:Remove friend'; index = 0 }
    # The sidebar's friends bar prints this too, so it is the same signal
    # whichever surface happens to be showing.
    $gone = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'text:No friends yet'; timeout_ms = 30000 }
    Close-Friends $peer
    return [bool]$gone.ok
}

function Open-Friends($peer) {
    Step $peer @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_FriendsManager'; timeout_ms = 15000 }
}

function Close-Friends($peer) {
    if (-not (Test-Target $peer 'type:_FriendsManager')) { return }
    Step $peer @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
}

# --------------------------------------------------------------------------
# Pre-flight. A relay that is up on its own box but unreachable or untrusted
# from HERE fails the first gate as "a never reached Connected", which reads
# like an app bug and is not one. Two seconds spent here saves a whole run.
# --------------------------------------------------------------------------

function Test-RelayReachable($domain) {
    Say "pre-flight: $domain"
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($domain)
    } catch {
        throw "$domain does not resolve from this machine: $($_.Exception.Message)"
    }
    Say ("  resolves to " + (($addresses | ForEach-Object { $_.IPAddressToString }) -join ', ')) 'Gray'

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($domain, 443, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(10000)) { throw 'timed out after 10s' }
        $client.EndConnect($connect)
        # Default validation: an untrusted or expired chain has to fail here
        # rather than inside the app, where it reads as a connection problem.
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
        $ssl.AuthenticateAsClient($domain)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        Say ("  TLS ok: subject $($cert.Subject), issuer $($cert.Issuer), expires $($cert.NotAfter.ToString('yyyy-MM-dd'))") 'Green'
        $ssl.Dispose()
    } catch {
        throw "TLS to ${domain}:443 failed from this machine: $($_.Exception.Message)"
    } finally {
        $client.Close()
    }
}

Test-RelayReachable $RelayHost

# --------------------------------------------------------------------------
# Boot. a lives on the self-hosted relay, b and c on the official one, so each
# side takes its own onboarding call: the relay is typed into the welcome
# dialog and stamped into the fixture along with the keys.
# --------------------------------------------------------------------------

if ($Build) {
    Say "building and staging $($journeyPeers -join ',')"
    Invoke-FleetScript @('-Build', '-Peers', ($journeyPeers -join ','))
}

if ($TurnGateOnly) {
    # The peers keep their EXISTING data directories, which is where c's move
    # to the relay under test lives; a fixture restore would undo it.
    #
    # They are RELAUNCHED even when they are already up, and that is the whole
    # of this branch. `/relay-status` is fetched exactly once per launch
    # (hollow_shell `_bootstrap`), so a peer that was running before the relay
    # changed mode still holds the answer it got then, and the chip is
    # correctly hidden for a stale turn:true. Only a fresh process asks again.
    Say 'G5 alone: relaunching on the data directories the last run left behind' 'Yellow'
    foreach ($peer in $journeyPeers) {
        if (Get-PeerProcess $peer) { Stop-Peer $peer }
        Restart-Peer $peer
    }
} elseif ($KeepIdentities) {
    Say 'driving the identities that are already live (their relay rings are not empty)' 'Yellow'
    foreach ($peer in $journeyPeers) {
        if (-not (Get-PeerProcess $peer)) { throw "-KeepIdentities needs $peer already running" }
        $script:FleetConsumed[$peer] = 0
    }
} else {
    Say "minting fresh identities: a on $RelayHost, b and c on $officialRelay"
    Invoke-FleetScript @('-Stop')
    Invoke-FleetScript @('-Onboard', '-Fresh', '-Peers', 'a', '-Relay', $RelayHost)
    Invoke-FleetScript @('-Onboard', '-Fresh', '-Peers', 'b,c')
    Invoke-FleetScript @('-Live', '-Peers', ($journeyPeers -join ','))
    foreach ($peer in $journeyPeers) { $script:FleetConsumed[$peer] = 0 }
}

$failure = $null
$selfServerCreated = $false
$officialServerCreated = $false
$friendsMade = $false
$relaunchPath = 'not reached'
$relayA = ''
$relayB = ''
$relayC = ''
$invite = ''
$invite2 = ''

try {
    foreach ($peer in $journeyPeers) { Wait-ForConnected $peer }
    $relayA = Get-PeerRelay a
    $relayC = Get-PeerRelay c
    if (-not $TurnGateOnly) { $relayB = Get-PeerRelay b }
    Say "relays: a=$relayA  b=$relayB  c=$relayC"
    if ($relayA -ne $RelayHost) {
        throw "a onboarded onto '$relayA', not '$RelayHost': the welcome dialog's Advanced field did not take"
    }
    if ($TurnGateOnly) {
        if ($relayC -ne $RelayHost) {
            throw "-TurnGateOnly needs c already moved to $RelayHost, and c is on '$relayC'. Run the full journey first."
        }
    } elseif ($relayB -ne $officialRelay -or $relayC -ne $officialRelay) {
        throw "b and c must start on $officialRelay (b=$relayB, c=$relayC)"
    }

    # G5 alone drives the peers a full run left behind, so the four gates
    # that produced that state are not re-run.
    if (-not $TurnGateOnly) {
        # ---- G1: the invite carries the relay it was made on -------------------
        Say "1/5 a creates $selfServer and its invite has to name $RelayHost"
        New-FleetServer a $selfServer
        $selfServerCreated = $true
        $invite = Get-ServerInvite a $selfServer 'INVITE'
        Say "invite: $invite" 'Gray'
        if ($invite -notmatch [regex]::Escape("relay=$relayEncoded")) {
            Step a @{ op = 'shot'; name = "relay-$runTag-a-invite" }
            throw "a's invite does not carry relay=$relayEncoded : $invite"
        }
        Set-Gate 'G1 a stamped its own relay into the invite it made' 'PASS'
        Say "PASS G1: the invite names relay=$relayEncoded" 'Green'

        # ---- G2: b is warned and Cancel changes nothing ------------------------
        Say '2/5 b pastes it, is warned, and cancels'
        $bProc = Get-PeerProcess b
        $bPidBefore = $bProc.Id
        Invoke-InvitePaste b $invite
        Step b @{ op = 'wait_for'; target = 'dialog > text:This server lives on another relay'; timeout_ms = 30000 }
        Step b @{ op = 'dump'; name = "relay-$runTag-b-warned" }
        Step b @{ op = 'shot'; name = "relay-$runTag-b-warned" }
        # The body is one Text.rich, so the host is only reachable as a SUBSTRING
        # of rich text, which is what expect_text falls back to; a `text:` target
        # would want the whole body string and match nothing.
        Step b @{ op = 'expect_text'; value = $RelayHost }
        Step b @{ op = 'wait_for'; target = 'dialog > text:Switch and restart'; timeout_ms = 5000 }
        Invoke-TopDialogTap b 'Cancel'
        Step b @{ op = 'wait_for'; gone = 'dialog > text:This server lives on another relay'; timeout_ms = 15000 }
        Close-JoinDialog b

        $relayBAfter = Get-PeerRelay b
        $bProcAfter = Get-PeerProcess b
        $bPidAfter = 0
        if ($bProcAfter) { $bPidAfter = $bProcAfter.Id }
        # A server that must NOT arrive cannot be polled for, so this is the one
        # fixed wait in the journey: ten seconds is far longer than a join takes
        # when a and b are both online.
        Step b @{ op = 'wait'; ms = 10000 }
        Step b @{ op = 'dump'; name = "relay-$runTag-b-after-cancel" }
        $bServers = @(Get-DumpServerNames b "relay-$runTag-b-after-cancel")
        $leaked = @($bServers | Where-Object { $_ -like 'fleet-relay-*' })
        Say "b: relay=$relayBAfter pid=$bPidBefore->$bPidAfter servers=[$($bServers -join ', ')]" 'Gray'
        if ($relayBAfter -ne $officialRelay) { throw "b's relay changed to '$relayBAfter' after Cancel" }
        if ($bPidAfter -ne $bPidBefore) { throw "b restarted after Cancel (pid $bPidBefore -> $bPidAfter)" }
        if ($leaked.Count -gt 0) { throw "b joined $($leaked -join ', ') after Cancel" }
        Set-Gate 'G2 b was warned, cancelled, and nothing about b changed' 'PASS'
        Say 'PASS G2: warned, cancelled, unchanged' 'Green'

        # ---- G3: c accepts, switches, restarts and joins -----------------------
        Say "3/5 c pastes it and accepts the switch to $RelayHost"
        $cProc = Get-PeerProcess c
        $cPidBefore = $cProc.Id
        Invoke-InvitePaste c $invite
        Step c @{ op = 'wait_for'; target = 'dialog > text:This server lives on another relay'; timeout_ms = 30000 }
        Step c @{ op = 'shot'; name = "relay-$runTag-c-warned" }
        Step c @{ op = 'expect_text'; value = $RelayHost }
        Backup-PeerArtifacts c 'pre-switch'

        # The tap is the LAST thing this copy of c is told: it saves the invite,
        # writes the new relay and calls relaunchApp(), and the replacement replays
        # the inbox from line 0 unless the mailbox is handed over first.
        try {
            Step c @{ op = 'tap'; target = 'dialog > text:Switch and restart'; index = 0; frames = 5 }
        } catch {
            Add-Note "c's Switch and restart tap did not answer (it may have exited first): $($_.Exception.Message)"
        } finally {
            Reset-PeerMailbox c
        }

        $deadline = (Get-Date).AddSeconds(120)
        $cPidAfter = 0
        while ((Get-Date) -lt $deadline) {
            $now = Get-PeerProcess c
            if ($now -and $now.Id -ne $cPidBefore -and (Test-PeerLive c)) { $cPidAfter = $now.Id; break }
            Start-Sleep -Milliseconds 400
        }
        if ($cPidAfter -gt 0) {
            $relaunchPath = "self-relaunch through the Rust waiter (pid $cPidBefore -> $cPidAfter)"
            Say "c relaunched itself: pid $cPidBefore -> $cPidAfter" 'Green'
        } else {
            $relaunchPath = 'fallback: Stop-Peer + Restart-Peer by the script'
            Add-Note 'c did not come back on its own within 120s, so the script restarted it'
            Stop-Peer c
            Restart-Peer c
        }

        Wait-ForConnected c
        $relayCAfter = Get-PeerRelay c
        Say "c is now on $relayCAfter" 'Gray'
        if ($relayCAfter -ne $RelayHost) {
            Step c @{ op = 'dump'; name = "relay-$runTag-c-after-switch" }
            throw "c came back on '$relayCAfter', not '$RelayHost'"
        }

        # The saved invite is replayed as a deep link, which asks before joining.
        $confirmed = Invoke-SoftStep c @{ op = 'wait_for'; target = 'dialog > text:Join'; timeout_ms = 90000 }
        if ($confirmed.ok) {
            Step c @{ op = 'shot'; name = "relay-$runTag-c-confirm" }
            Step c @{ op = 'tap'; target = 'dialog > text:Join'; index = 0 }
        } else {
            Invoke-SoftStep c @{ op = 'shot'; name = "relay-$runTag-c-no-confirm" } | Out-Null
            Invoke-SoftStep c @{ op = 'dump'; name = "relay-$runTag-c-no-confirm" } | Out-Null
            throw 'c came back on the new relay but never showed the deep-link confirm dialog for the saved invite'
        }
        Step c @{ op = 'wait_for'; target = "server:$selfServer"; timeout_ms = 180000 }
        Set-Gate 'G3 c switched relay, restarted and joined' 'PASS'
        Say "PASS G3: c is on $RelayHost and holds $selfServer" 'Green'

        # ---- G3b: they can talk ------------------------------------------------
        Say '3b/5 c and a talk in the joined server'
        Step c @{ op = 'open_server'; name = $selfServer }
        Step c @{ op = 'open_channel'; name = 'general' }
        Step a @{ op = 'open_server'; name = $selfServer }
        Step a @{ op = 'open_channel'; name = 'general' }
        Step a @{ op = 'wait_for'; target = 'text:probe-c'; timeout_ms = 120000 }
        Send-Channel c 'general' "hello from c $runTag"
        Step a @{ op = 'wait_for'; target = "text:hello from c $runTag"; timeout_ms = 120000 }
        Send-Channel a 'general' "hello back from a $runTag"
        Step c @{ op = 'wait_for'; target = "text:hello back from a $runTag"; timeout_ms = 120000 }
        Step c @{ op = 'shot'; name = "relay-$runTag-c-joined" }
        Set-Gate 'G3b c and a talk both ways in the joined server' 'PASS'
        Say 'PASS G3b: both directions landed' 'Green'

        # ---- G4: the mirror image ----------------------------------------------
        Say "4/5 b makes an invite on $officialRelay and c has to be warned about it"
        New-FleetServer b $officialServer
        $officialServerCreated = $true
        $invite2 = Get-ServerInvite b $officialServer 'INVITE2'
        Say "invite2: $invite2" 'Gray'
        if ($invite2 -notmatch [regex]::Escape("relay=$officialRelay")) {
            Step b @{ op = 'shot'; name = "relay-$runTag-b-invite" }
            throw "b's invite does not carry relay=$officialRelay : $invite2"
        }
        Invoke-InvitePaste c $invite2
        Step c @{ op = 'wait_for'; target = 'dialog > text:This server lives on another relay'; timeout_ms = 30000 }
        Step c @{ op = 'shot'; name = "relay-$runTag-c-warned-official" }
        Step c @{ op = 'expect_text'; value = $officialRelay }
        Invoke-TopDialogTap c 'Cancel'
        Step c @{ op = 'wait_for'; gone = 'dialog > text:This server lives on another relay'; timeout_ms = 15000 }
        Close-JoinDialog c
        $relayCStill = Get-PeerRelay c
        if ($relayCStill -ne $RelayHost) { throw "c's relay changed to '$relayCStill' after Cancel" }
        Set-Gate 'G4 an official-relay invite warns the peer that moved' 'PASS'
        Say "PASS G4: c was warned about $officialRelay and stayed on $RelayHost" 'Green'
    }

    # ---- G5: no TURN server -------------------------------------------------
    if (-not $NoTurnRelay) {
        Add-Note "G5 not run: it asserts that $RelayHost reports turn:false, which this run was not told. Re-run with -NoTurnRelay against a relay without TURN."
    } else {
        Say '5/5 the relay has no TURN server, and Always relay calls refuses'
        Open-Settings c 'Network'
        Step c @{ op = 'wait_for'; target = 'text:No TURN server'; timeout_ms = 60000 }
        Step c @{ op = 'shot'; name = "relay-$runTag-c-no-turn-chip" }
        Set-Gate 'G5a Settings > Network names a relay with no TURN server' 'PASS'
        Say 'PASS G5a: the chip is on the active relay row' 'Green'

        # The toggle carries no purpose label of its own (its name is the row's
        # text), so it is reached through the widget that owns it.
        Step c @{ op = 'tap'; target = 'type:_UserSettingsContent > text:Security'; index = 0 }
        Step c @{ op = 'wait_for'; target = 'text:Always relay calls'; timeout_ms = 20000 }
        Step c @{ op = 'tap'; target = 'type:AlwaysRelayCallsToggle > type:HollowToggle'; index = 0 }
        Step c @{ op = 'wait'; ms = 1000 }
        Close-Settings c

        # A -TurnGateOnly rerun drives peers that may already be friends, and
        # re-requesting an existing friend is a different journey.
        $already = Test-Target c 'tooltip:probe-a' 3000
        if ($already) {
            Say 'a and c are already friends' 'Gray'
        } else {
            Say 'a and c become friends so there is someone to call'
            Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
            Open-Friends c
            Step c @{ op = 'tap'; target = 'text:Add friend'; index = 0 }
            Step c @{ op = 'enter_text'; target = 'hint:Paste an ID, or type a nickname'; value = "$($script:FleetVars['PEER_A'])" }
            Step c @{ op = 'tap'; target = 'text:Send request'; index = 0 }
            Open-Friends a
            # The Accept button only exists on the INCOMING tab.
            Step a @{ op = 'tap'; target = 'type:HollowChip>text:Requests'; index = 0 }
            Step a @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 90000 }
            Step a @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }
            Step a @{ op = 'wait_for'; target = 'text:probe-c'; timeout_ms = 60000 }
            Step c @{ op = 'wait_for'; target = 'text:probe-a'; timeout_ms = 60000 }
            $friendsMade = $true
            Close-Friends a
            Close-Friends c
        }

        Step c @{ op = 'tap'; target = 'tooltip:probe-a' }
        Step c @{ op = 'wait_for'; target = 'hint:Type a message...'; timeout_ms = 30000 }
        Step c @{ op = 'tap'; target = 'semantics:Start voice call'; index = 0 }
        Step c @{ op = 'wait_for'; target = 'dialog > text:This relay can''t carry your call'; timeout_ms = 30000 }
        Step c @{ op = 'shot'; name = "relay-$runTag-c-turn-refusal" }
        # The refusal has one way out and the wording is the app's, so the
        # dismiss is tried by name and falls back to Escape.
        $dismissed = $false
        foreach ($label in @('Close', 'Got it', 'OK')) {
            $count = Get-MatchCount c "dialog > text:$label"
            if ($count -gt 0) {
                Invoke-TopDialogTap c $label
                $dismissed = $true
                break
            }
        }
        if (-not $dismissed) { Invoke-SoftStep c @{ op = 'key'; value = 'escape' } | Out-Null }
        Invoke-SoftStep c @{ op = 'wait_for'; gone = 'dialog > text:This relay can''t carry your call'; timeout_ms = 15000 } | Out-Null
        Set-Gate 'G5b Always relay calls refuses a call without TURN' 'PASS'
        Say 'PASS G5b: the call was refused, not attempted' 'Green'

        Open-Settings c 'Security'
        Step c @{ op = 'wait_for'; target = 'text:Always relay calls'; timeout_ms = 20000 }
        Step c @{ op = 'tap'; target = 'type:AlwaysRelayCallsToggle > type:HollowToggle'; index = 0 }
        Step c @{ op = 'wait'; ms = 1000 }
        Close-Settings c
    }

    Say 'the journey ran to the end' 'Green'
} catch {
    $failure = $_
    $where = Set-FirstUnreachedGateFailed
    Say "FAILED at [$where]: $($_.Exception.Message)" 'Red'
    # Every peer's tail, not just the dead ones: a failure here is as often a
    # peer that is up and wrong as a peer that died.
    foreach ($peer in $journeyPeers) {
        $state = 'up'
        if (-not (Get-PeerProcess $peer)) { $state = 'GONE' }
        Say "--- $peer ($state) ---" 'Red'
        Write-Host (Get-CrashTail $peer) -ForegroundColor DarkRed
    }
}

# --------------------------------------------------------------------------
# Cleanup. Runs whatever happened: the fleet talks only to servers it creates
# AND deletes, because these are real identities on real relays, and the same
# goes for a friendship a gate had to make.
# --------------------------------------------------------------------------
$cleanupOk = $true

if ($friendsMade) {
    Say 'cleanup: removing the friendship'
    try {
        if (Remove-Friendship a 'probe-c') {
            Say 'the a/c friendship is gone' 'Green'
        } else {
            $cleanupOk = $false
            Say 'cleanup FAILED: the a/c friendship is still there' 'Red'
        }
    } catch {
        $cleanupOk = $false
        Add-Note "could not remove the a/c friendship: $($_.Exception.Message)"
    }
}

function Remove-CreatedServer($owner, $name) {
    Say "cleanup: $owner deletes $name"
    try {
        if (-not (Get-PeerProcess $owner)) { Restart-Peer $owner; Wait-ForConnected $owner }
        Close-Settings $owner
        Close-Friends $owner
        Remove-Server $owner $name
        foreach ($peer in $journeyPeers) {
            if ($peer -eq $owner) { continue }
            if (Get-PeerProcess $peer) {
                Invoke-SoftStep $peer @{ op = 'wait_for'; gone = "server:$name"; timeout_ms = 120000 } | Out-Null
            }
        }
        return $true
    } catch {
        Say "cleanup FAILED (the server may still exist as $name): $($_.Exception.Message)" 'Red'
        return $false
    }
}

if ($selfServerCreated) {
    if (-not (Remove-CreatedServer a $selfServer)) { $cleanupOk = $false }
}
if ($officialServerCreated) {
    if (-not (Remove-CreatedServer b $officialServer)) { $cleanupOk = $false }
}
if ($cleanupOk) { Set-Gate $script:CleanupGate 'PASS' } else { Set-Gate $script:CleanupGate 'FAIL' }

# --------------------------------------------------------------------------
# The report
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '===== relay switch: two relays, one invite =====' -ForegroundColor Cyan
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
Write-Host ("  relays   : a={0}  b={1}  c={2} (at boot)" -f $relayA, $relayB, $relayC) -ForegroundColor Gray
Write-Host ("  servers  : {0} (a), {1} (b)" -f $selfServer, $officialServer) -ForegroundColor Gray
Write-Host ("  invite   : {0}" -f $invite) -ForegroundColor Gray
if ($invite2) { Write-Host ("  invite2  : {0}" -f $invite2) -ForegroundColor Gray }
Write-Host ("  relaunch : {0}" -f $relaunchPath) -ForegroundColor Gray
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
if ($Keep -or $failed -gt 0) {
    Say "fleet left up ($failed gate(s) failed)" $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
} else {
    Invoke-FleetScript @('-Stop')
}
if ($failed -gt 0) { exit 1 }
Say 'PASS' 'Green'
