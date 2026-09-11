# Offline delivery across a RELAY RESTART, driven over two REAL instances.
#
#   powershell -File scripts\fleet_relay_restart.ps1                # fresh keys, builds first
#   powershell -File scripts\fleet_relay_restart.ps1 -SkipBuild     # you just built
#   powershell -File scripts\fleet_relay_restart.ps1 -KeepIdentities
#   powershell -File scripts\fleet_relay_restart.ps1 -KeepUp
#
# ## Why a script and not a scenario JSON
#
# Two things a scenario file cannot do: an instance goes away and comes back
# (Restart-Peer / Stop-Peer, copied from fleet_channel_file_catchup.ps1), and
# the RELAY itself is restarted over ssh in the middle of the journey.
#
# ## What it proves
#
# The relay's offline buffers (the DM mailbox and the per-channel topic rings)
# are RAM only and used to end with the process: a deploy emptied three days of
# undelivered messages. Since 2026-09-07 the relay hands those buffers to
# systemd's fd store on SIGTERM and takes them back on start, memory to memory,
# never a file. Nothing in the app changed, so this journey is the only place
# the claim is checked end to end:
#
#   G1 a and b are friends, share a server, and talk both ways. Baseline.
#   G2 b is CLOSED. a sends a DM and a channel message into the void, then a
#      closes too. Both messages now exist ONLY in the relay's RAM.
#   G3 the relay is restarted while nobody from this fleet is connected. The
#      relay's own journal must say it handed at least one DM frame and one
#      topic frame over, and restored them.
#   G4 b returns ALONE (the sender is still closed, so peer sync cannot be the
#      source) and sees both messages: the DM in the conversation, the channel
#      message in #general.
#   G5 the destroy signal a parked for the CLOSED throwaway peer d came through
#      the same restart and reaches d the moment it authenticates.
#   G6 a guest socket cannot park one.
#
# a stays closed while b returns on purpose: with a online, b would receive
# both messages from a's own database through peer sync and the relay would be
# proven nothing.
#
# ## The kill-list gate (G5, G6)
#
# The relay parks a destroy signal for a device that is not connected and hands
# it over on that device's next auth, and that registry rides the same restart
# handoff as the buffers. d is a THROWAWAY identity minted for this gate alone,
# never a or b, and the blob it is sent is a dummy string: a client verifies the
# signature against its own master and drops this one, so nothing is ever wiped.
#
# G5 asks for three things that can each fail on their own:
#   - the relay journal counts the entry handed to the fd store, restored, and
#     delivered once d authenticates;
#   - d's own log names the exact issued_at this run deposited, then the
#     permanent rejection that goes with a blob no signature can vouch for;
#   - d is still d. A blob that wiped anyone would be the whole feature broken.
# d is then relaunched a SECOND time and the parked-order line must still appear
# exactly once: an entry the client never acked is re-sent on every auth for a
# year, which is the reason the ack rule exists.
#
# G6 needs a socket that authenticates as a GUEST, which no fleet instance does
# (that is the web viewer), so the journey opens one itself with node: an
# ed25519 key, the peer id libp2p derives from it, and a deposit that must draw
# no `kill_deposited` answer. Without node on the machine it reports WARN.
#
# The relay host is read from BUILD_GUIDE.md's deploy section: ssh as
# ubuntu@141.227.186.209 with the passwordless key this machine already uses
# for deploys. Windows PowerShell 5.1 (no pwsh-only syntax).

param(
    [switch]$KeepIdentities,
    [switch]$KeepUp,
    [switch]$SkipBuild,
    [switch]$KeepServer,
    [string]$RelayHost = 'ubuntu@141.227.186.209',
    # The ssh target above is a machine; this is the name its clients dial.
    [string]$RelayDomain = 'relay.anonlisten.com',
    [int]$BootTimeoutSeconds = 240
)

if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -KeepIdentities, -KeepUp, -SkipBuild, -KeepServer, -RelayHost, -RelayDomain and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# ${RUN} goes in the server name and every message: the relay holds undelivered
# traffic for three days, so a fixed string can be matched by an EARLIER run.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$server = "rrs-$($script:FleetVars.RUN)"
$journeyPeers = @('a', 'b')
# d only ever exists to be the target of a parked destroy signal.
$killPeer = 'd'
$fleetPeers = @('a', 'b', $killPeer)

function Say($message, $colour = 'Cyan') { Write-Host "[relay-restart] $message" -ForegroundColor $colour }

# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------
$script:Gates = [ordered]@{
    'G1 a and b are friends, share rrs-RUN #general, talk both ways' = 'SKIP'
    'G2 b closed: a sends a DM and a channel message, then closes'   = 'SKIP'
    'G3 relay restarted with nobody connected; journal shows handoff' = 'SKIP'
    'G4 b returns ALONE and sees both messages'                       = 'SKIP'
    'G5 the parked kill signal survives the restart and reaches d'    = 'SKIP'
    'G6 a guest socket cannot park a kill signal'                     = 'SKIP'
    'C  cleanup: no fleet server left on the relay'                   = 'SKIP'
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

# `text:Online` is deliberately NOT in the list: the member panel prints that
# word as a section divider, so it would pass for an offline peer.
function Wait-ForConnected($peer, $timeoutSeconds = 120) {
    $hit = Wait-ForAnyTarget $peer @('tooltip:Online', 'text:Connected') $timeoutSeconds
    if (-not $hit) {
        throw "peer $peer never reported a settled connection within ${timeoutSeconds}s"
    }
    return $hit
}

# Relaunch ONE peer on its EXISTING data dir (fixture NOT restored), so the
# friendship and the server survive the round trip.
function Restart-Peer($peer) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Join-Path $runRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    $kept = Join-Path $script:FleetOutRoot "kept\$peer"
    if (Test-Path $out) {
        New-Item -ItemType Directory -Path $kept -Force | Out-Null
        Get-ChildItem $out -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'rrs-*' } |
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
    $deadline = (Get-Date).AddSeconds(30)
    while (Get-PeerProcess $peer) {
        if ((Get-Date) -ge $deadline) { throw "peer $peer did not stop within 30s" }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 1500
    Say "$peer is closed - OFFLINE" 'Yellow'
}

# --------------------------------------------------------------------------
# The relay
# --------------------------------------------------------------------------

function Invoke-Relay($remote) {
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=20 $RelayHost $remote 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $RelayHost failed ($LASTEXITCODE): $out" }
    return @($out)
}

function Restart-Relay {
    Say 'restarting the relay over ssh'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Relay 'sudo -n systemctl restart hollow-relay' | Out-Null
    $sw.Stop()
    Say ("relay restarted in {0:n1}s" -f $sw.Elapsed.TotalSeconds) 'Green'
    return $sw.Elapsed.TotalSeconds
}

# The relay logs COUNTS only; this reads the handoff and restore lines of the
# most recent restart. Fixed-string grep: a regex with escaped brackets loses
# its backslashes between PowerShell and the remote shell and then matches
# almost every line.
function Get-RelaySnapshotLines {
    return Invoke-Relay 'sudo -n journalctl -u hollow-relay --no-pager -o cat --since "-3min" | grep -F "[snapshot]" | tail -2'
}

function Get-RelayClock {
    $out = Invoke-Relay 'date +%s'
    return ((@($out) | Select-Object -Last 1)).Trim()
}

# Counts only, and the relay prints no peer id on this line: it says a parked
# signal went out, never to whom.
#
# The pattern is ONE word because a quoted multi-word one loses its quotes on
# the way through ssh and the remote shell reads the rest of it as filenames.
function Get-RelayKillDeliveriesSince($epoch) {
    $remote = 'sudo -n journalctl -u hollow-relay --no-pager -o cat --since "@' + $epoch +
              '" | grep -F kill_signal | wc -l'
    $text = ((@(Invoke-Relay $remote) | Select-Object -Last 1)).Trim()
    $n = 0
    if ([int]::TryParse($text, [ref]$n)) { return $n }
    return 0
}

# A GUEST socket, which no fleet instance can be: the web viewer is the only
# guest client there is. node has ed25519 and a WebSocket client, so the journey
# writes the client it needs and throws it away again.
#
# `control` is the same socket WITHOUT the guest flag, depositing for a target
# that is not a peer id: the relay answers stored=0 and keeps nothing, which is
# what tells "the guest was refused" apart from "nobody was listening".
function Invoke-GuestKillDeposit($mode) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $null }
    $path = Join-Path $env:TEMP "fleet_guest_deposit_$($script:FleetVars.RUN).js"
    $js = @'
const crypto = require('crypto');
const host = process.argv[2];
const control = process.argv[3] === 'control';
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function base58(buf) {
  let zeros = 0;
  while (zeros < buf.length && buf[zeros] === 0) zeros++;
  const size = ((buf.length - zeros) * 138) / 100 + 1 | 0;
  const b58 = new Uint8Array(size);
  for (let i = zeros; i < buf.length; i++) {
    let carry = buf[i];
    for (let j = size; j-- > 0;) {
      carry += 256 * b58[j];
      b58[j] = carry % 58;
      carry = (carry / 58) | 0;
    }
  }
  let it = 0;
  while (it < size && b58[it] === 0) it++;
  let out = '1'.repeat(zeros);
  for (; it < size; it++) out += B58[b58[it]];
  return out;
}

function say(line) { process.stdout.write(line + '\n'); }

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const spki = publicKey.export({ type: 'spki', format: 'der' });
const raw = spki.subarray(spki.length - 32);
const proto = Buffer.concat([Buffer.from([0x08, 0x01, 0x12, 0x20]), raw]);
const peerId = base58(Buffer.concat([Buffer.from([0x00, 0x24]), proto]));
const timestamp = Math.floor(Date.now() / 1000);
const signature = crypto
  .sign(null, Buffer.from(`hollow-ws-auth:${peerId}:${timestamp}`), privateKey)
  .toString('base64');

let verdict = null;
const finish = (line) => {
  if (verdict) return;
  verdict = line;
  say(line);
  try { ws.close(); } catch (_) {}
  process.exit(0);
};

const ws = new WebSocket(`wss://${host}/ws`);
const overall = setTimeout(() => finish('ERROR no answer within 20s'), 20000);
if (overall.unref) overall.unref();

ws.addEventListener('error', (e) => finish(`ERROR socket ${e.message || 'failed'}`));
ws.addEventListener('close', () => { if (!verdict) finish('ERROR socket closed before a verdict'); });

ws.addEventListener('open', () => {
  ws.send(JSON.stringify({
    type: 'auth', peer_id: peerId, public_key: proto.toString('base64'),
    timestamp, signature, guest: !control,
  }));
});

ws.addEventListener('message', (ev) => {
  let msg;
  try { msg = JSON.parse(typeof ev.data === 'string' ? ev.data : ''); } catch (_) { return; }
  if (msg.type === 'auth_failed') return finish(`ERROR auth_failed ${msg.error || ''}`);
  if (msg.type === 'auth_ok') {
    say(`${control ? 'control' : 'guest'} ${peerId}`);
    ws.send(JSON.stringify({
      type: 'kill_deposit', targets: [control ? 'not-a-peer-id' : peerId],
      issued_at_ms: Date.now(), blob: 'fleet-guest-refusal-probe',
    }));
    setTimeout(() => finish(control ? 'ERROR the control drew no answer' : 'REFUSED'), 4000);
    return;
  }
  if (msg.type === 'kill_deposited') return finish(`ACCEPTED stored=${msg.stored}`);
});
'@
    try {
        Set-Content -Path $path -Value $js -Encoding UTF8
        $lines = @(& $node.Source $path $RelayDomain $mode)
        foreach ($line in $lines) { Write-Host "     [$mode] $line" -ForegroundColor Gray }
        return (@($lines | Where-Object { $_ }) | Select-Object -Last 1)
    } catch {
        Add-Note "the guest socket could not run ($($_.Exception.Message))"
        return $null
    } finally {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
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

# `-like "*[HOLLOW-X]*"` reads the brackets as a character class and matches
# every line, so anything a GATE depends on is matched with .Contains instead.
function Get-PeerLogContains($peer, $needle) {
    $path = Join-Path $script:FleetStageRoot "$peer\hollow_debug.log"
    if (-not (Test-Path $path)) { return @() }
    try {
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

# The log outlives the run, so a line an EARLIER run wrote would satisfy a bare
# search: the same trap ${RUN} closes for messages. Everything that follows this
# run's own anchor line is this run's.
function Wait-ForPeerLogAfter($peer, $anchor, $needles, $timeoutSeconds = 30) {
    $path = Join-Path $script:FleetStageRoot "$peer\hollow_debug.log"
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $lines = @()
        if (Test-Path $path) {
            try { $lines = @(Get-Content $path -Encoding UTF8 -ErrorAction Stop) } catch { }
        }
        $at = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains($anchor)) { $at = $i }
        }
        $hits = @()
        if ($at -ge 0) {
            for ($i = $at + 1; $i -lt $lines.Count; $i++) {
                foreach ($needle in $needles) {
                    if ($lines[$i].Contains($needle)) { $hits += $lines[$i]; break }
                }
            }
        }
        if ($hits.Count -gt 0) { return $hits }
        if ((Get-Date) -ge $deadline) { return @() }
        Start-Sleep -Milliseconds 500
    }
}

function Write-Evidence($label) {
    Say "evidence for $label" 'Yellow'
    foreach ($peer in $journeyPeers) {
        foreach ($pattern in @(
            '[HOLLOW-TOPIC] Catch-up request',
            '[HOLLOW-TOPIC] Registering relay catch-up',
            '[HOLLOW-TOPIC] RECV MlsChannelMessage',
            '[HOLLOW-TOPIC] DECRYPT ok',
            '[HOLLOW-MLS] Decrypt failed',
            'offline',
            $script:FleetVars.RUN)) {
            $hits = @(Get-PeerLogLines $peer $pattern)
            if ($hits.Count -eq 0) { continue }
            Write-Host "  [$peer] $pattern ($($hits.Count))" -ForegroundColor DarkYellow
            $hits | Select-Object -Last 8 | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
        }
    }
    try {
        Write-Host "  [relay] journal" -ForegroundColor DarkYellow
        Get-RelaySnapshotLines | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
    } catch {
        Write-Host "     (journal unavailable: $($_.Exception.Message))" -ForegroundColor Gray
    }
}

# --------------------------------------------------------------------------
# Boot
# --------------------------------------------------------------------------

if (-not $SkipBuild) {
    Say 'building and staging a,b,d (pass -SkipBuild when you have just built)'
    Invoke-FleetScript @('-Build', '-Peers', ($fleetPeers -join ','))
}

if ($KeepIdentities) {
    Say 'keeping the identities that are already live (their relay mailboxes are not empty)' 'Yellow'
    if ((Get-LivePeers).Count -eq 0) {
        Say 'nothing is live (a build stops the fleet) - booting the existing fixtures'
        Invoke-FleetScript @('-Live', '-Peers', ($fleetPeers -join ','))
        foreach ($peer in $fleetPeers) { $script:FleetConsumed[$peer] = 0 }
    }
} else {
    Start-FreshFleet $fleetPeers
}

$live = Get-LivePeers
foreach ($peer in $fleetPeers) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running. Start the fleet with: powershell -File scripts\fleet.ps1 -Live -Peers a,b,d (live: $($live -join ', '))"
    }
}
Say "run tag $($script:FleetVars.RUN), server $server"

$failure = $null
$serverCreated = $false
$killTarget = $null
$killDeposited = $false
$killIssuedAtMs = 0
$killHanded = 0
$killRestored = 0

try {
    Wait-ForConnected a | Out-Null
    Wait-ForConnected b | Out-Null
    Step a @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_A' }
    Step b @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

    # d is the kill-list fixture. The relay keys the list by the DEVICE id its
    # socket authenticates as, not the master id the rest of the app shows.
    Step $killPeer @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_D' }
    $deviceAnswer = Invoke-SoftStep $killPeer @{
        op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'DEVICE_D'
    }
    if ($deviceAnswer.ok) {
        $killTarget = $script:FleetVars['DEVICE_D']
    } else {
        Add-Note "the probe has no devicePeerId provider key yet, so G5 cannot name a target ($($deviceAnswer.message))"
    }
    # Closed for the whole journey: a parked signal is only parked while its
    # target is away.
    Stop-Peer $killPeer

    # --- G1: friends, a server, both directions. ---------------------------
    Say '1/6 friends + server baseline'
    Step b @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step b @{ op = 'tap'; target = 'text:Add Friend'; index = 0 }
    Step b @{ op = 'enter_text'; target = 'hint:Peer ID or nickname...'; value = '${PEER_A}' }
    Step b @{ op = 'wait_for'; target = 'text:${PEER_A}'; timeout_ms = 15000 }
    Step b @{ op = 'tap'; target = 'text:Send Request'; index = 0 }
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

    Step a @{ op = 'tap'; target = 'tooltip:probe-b' }
    Step a @{ op = 'wait'; ms = 1500 }
    Step a @{ op = 'enter_text'; target = 'field'; value = 'dm baseline ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step b @{ op = 'wait_for'; target = 'text:dm baseline ${RUN}'; timeout_ms = 60000 }

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
    Step a @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'channel baseline a ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step b @{ op = 'wait_for'; target = 'text:channel baseline a ${RUN}'; timeout_ms = 120000 }
    Step b @{ op = 'tap'; target = 'hint:Message #general' }
    Step b @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'channel baseline b ${RUN}' }
    Step b @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:channel baseline b ${RUN}'; timeout_ms = 120000 }
    Set-Gate 'G1 a and b are friends, share rrs-RUN #general, talk both ways' 'PASS'

    # --- G2: b away; a sends into the void; a leaves too. -------------------
    Say '2/6 b closes; a sends a DM and a channel message, then closes'
    # Let b's leave settle at the relay so the DM is buffered, not delivered
    # to a ghost socket, and the channel message reaches the ring.
    Stop-Peer b
    Start-Sleep -Seconds 5
    Step a @{ op = 'tap'; target = 'hint:Message #general' }
    Step a @{ op = 'enter_text'; target = 'hint:Message #general'; value = 'channel while away ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:channel while away ${RUN}'; timeout_ms = 30000 }
    Step a @{ op = 'tap'; target = 'tooltip:probe-b' }
    Step a @{ op = 'wait'; ms = 1500 }
    Step a @{ op = 'enter_text'; target = 'field'; value = 'dm while away ${RUN}' }
    Step a @{ op = 'key'; value = 'enter' }
    Step a @{ op = 'wait_for'; target = 'text:dm while away ${RUN}'; timeout_ms = 30000 }

    # Park a destroy signal for the closed throwaway. The blob is a dummy, so a
    # client that verifies it against its own master drops it.
    if ($killTarget) {
        # Stamped here rather than by the probe: the exact value comes back in
        # d's own log line, so no earlier delivery can be read as this one.
        $killIssuedAtMs = [int64][System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $deposit = Invoke-SoftStep a @{
            op = 'kill_deposit'; target = $killTarget
            value = "fleet-dummy-$($script:FleetVars.RUN)"
            issued_at_ms = $killIssuedAtMs
        }
        if ($deposit.ok) {
            $killDeposited = $true
            Add-Note 'a parked a dummy destroy signal for d'
        } else {
            Add-Note "kill_deposit is not a probe op yet ($($deposit.message))"
        }
    }

    # Let a's WS layer FLUSH both frames to the relay before it is killed; a
    # deposit has no client-visible ack, so this is a wait or a coin flip.
    Step a @{ op = 'wait'; ms = 6000 }
    Step a @{ op = 'shot'; name = "rrs-$($script:FleetVars.RUN)-a-sent-while-b-away" }
    Stop-Peer a
    Start-Sleep -Seconds 4
    Set-Gate 'G2 b closed: a sends a DM and a channel message, then closes' 'PASS'

    # --- G3: the relay restarts with nobody from this fleet connected. ------
    Say '3/6 relay restart with both instances closed'
    $seconds = Restart-Relay
    Start-Sleep -Seconds 3
    $lines = @(Get-RelaySnapshotLines)
    foreach ($line in $lines) { Write-Host "     $line" -ForegroundColor Gray }
    $handed = $lines | Where-Object { $_ -like '*handed to the fd store*' } | Select-Object -Last 1
    $restored = $lines | Where-Object { $_ -like '*restored*' } | Select-Object -Last 1
    $dmFrames = 0
    $topicFrames = 0
    if ($handed -and $handed -match '(\d+) DM frames in \d+ queues, (\d+) topic frames') {
        $dmFrames = [int]$Matches[1]
        $topicFrames = [int]$Matches[2]
    }
    # The handoff line counts kill entries too; G5 is where they are judged.
    if ($handed -and $handed -match '(\d+) kill entries') { $killHanded = [int]$Matches[1] }
    if ($restored -and $restored -match '(\d+) kill entries;') { $killRestored = [int]$Matches[1] }
    Add-Note ("relay restart took {0:n1}s; handoff carried {1} DM frame(s), {2} topic frame(s) and {3} kill entr(ies)" -f $seconds, $dmFrames, $topicFrames, $killHanded)
    if ($handed -and $restored -and $dmFrames -ge 1 -and $topicFrames -ge 1 -and $seconds -lt 20) {
        Set-Gate 'G3 relay restarted with nobody connected; journal shows handoff' 'PASS'
    } else {
        Set-Gate 'G3 relay restarted with nobody connected; journal shows handoff' 'FAIL'
        Add-Note "G3: handed=$([bool]$handed) restored=$([bool]$restored) dm=$dmFrames topic=$topicFrames seconds=$seconds"
        throw 'G3 failed: the relay did not report a handoff with both kinds of frame'
    }

    # --- G4: b returns alone. -----------------------------------------------
    Say '4/6 b returns ALONE (a still closed)'
    Restart-Peer b
    Wait-ForConnected b | Out-Null
    Step b @{ op = 'tap'; target = 'tooltip:probe-a' }
    $dm = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:dm while away ${RUN}'; timeout_ms = 120000 }
    Step b @{ op = 'shot'; name = "rrs-$($script:FleetVars.RUN)-b-dm-after-relay-restart" }
    Step b @{ op = 'open_server'; name = $server }
    Step b @{ op = 'open_channel'; name = 'general' }
    $chan = Invoke-SoftStep b @{ op = 'wait_for'; target = 'text:channel while away ${RUN}'; timeout_ms = 120000 }
    Step b @{ op = 'shot'; name = "rrs-$($script:FleetVars.RUN)-b-channel-after-relay-restart" }
    Step b @{ op = 'dump'; name = 'rrs-b-return-alone' }
    if ($dm.ok -and $chan.ok) {
        Set-Gate 'G4 b returns ALONE and sees both messages' 'PASS'
    } else {
        Set-Gate 'G4 b returns ALONE and sees both messages' 'FAIL'
        Add-Note "G4: dm=$($dm.ok) channel=$($chan.ok)"
        Write-Evidence 'G4'
        throw 'G4 failed: see the evidence above'
    }

    # --- G5: d returns and is handed the parked signal. ---------------------
    Say '5/6 d returns and is handed the parked destroy signal'
    $since = Get-RelayClock
    Restart-Peer $killPeer
    $ready = Send-FleetStep $killPeer ([pscustomobject]@{
        op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 120000
    }) 180
    if (-not $ready.ok) { throw "d never reached Connected after the restart: $($ready.message)" }
    # The signal rides out with auth_ok, so it is already sent by the time the
    # connection settles; the pause is for journald, not for the relay.
    Start-Sleep -Seconds 3
    $delivered = 0
    try {
        $delivered = Get-RelayKillDeliveriesSince $since
    } catch {
        Add-Note "the relay journal could not be read ($($_.Exception.Message))"
    }

    # A dummy blob must never cost anyone their data: d is still d.
    Step $killPeer @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_D_AFTER' }
    $identityHeld = ($script:FleetVars['PEER_D_AFTER'] -eq $script:FleetVars['PEER_D'])
    if (-not $identityHeld) {
        Set-Gate 'G5 the parked kill signal survives the restart and reaches d' 'FAIL'
        throw 'G5 failed: d lost its identity to a dummy blob, which no signature can have authorised'
    }

    # Only d can say the order arrived, was judged and was refused, and the
    # issued_at in its log is this run's own.
    $parked = "Relay parked order issued_at=$killIssuedAtMs"
    $parkedHits = @()
    $refusedHits = @()
    if ($killDeposited) {
        $parkedHits = @(Wait-ForPeerLog $killPeer $parked 45)
        # Either wording is a PERMANENT rejection, and which one depends only on
        # how far into the blob the client got.
        if ($parkedHits.Count -gt 0) {
            $refusedHits = @(Wait-ForPeerLogAfter $killPeer $parked @(
                'Kill signal blob is not a destruction order, acked and dropped',
                'Refused a destruction order:') 20)
        }
        foreach ($line in @($parkedHits + $refusedHits)) {
            Write-Host "     [d] $line" -ForegroundColor Gray
        }
    }

    if (-not $killDeposited) {
        Set-Gate 'G5 the parked kill signal survives the restart and reaches d' 'WARN'
        Add-Note 'G5 is coded but cannot run: the deposit needs the kill_deposit probe op and the devicePeerId provider key'
    } elseif ($killHanded -ge 1 -and $killRestored -ge 1 -and
              $parkedHits.Count -ge 1 -and $refusedHits.Count -ge 1) {
        Set-Gate 'G5 the parked kill signal survives the restart and reaches d' 'PASS'
        Add-Note ("kill list: {0} handed over, {1} restored; d logged this run's order and refused it" -f $killHanded, $killRestored)
        # The relay's counter only corroborates what d already proved, and the
        # box keeps barely a couple of minutes of journal.
        if ($delivered -ge 1) {
            Add-Note "the relay journal counted $delivered kill_signal delivery since d's return"
        } else {
            Add-Note "the relay journal showed no delivery line, which is its retention, not the delivery: d's own log carries this run's issued_at"
        }
    } else {
        Set-Gate 'G5 the parked kill signal survives the restart and reaches d' 'FAIL'
        Add-Note "G5: handed=$killHanded restored=$killRestored delivered=$delivered parked=$($parkedHits.Count) refused=$($refusedHits.Count)"
        @(Get-PeerLogContains $killPeer '[HOLLOW-DESTROY]') |
            Select-Object -Last 20 |
            ForEach-Object { Write-Host "     [d] $_" -ForegroundColor Gray }
        Write-Evidence 'G5'
        throw 'G5 failed: the parked signal did not survive the restart or did not reach d'
    }

    # The ack rule: a refused entry is gone, so a second auth draws nothing.
    # Without it any junk deposit rides along for a year.
    if ($killDeposited) {
        Stop-Peer $killPeer
        Restart-Peer $killPeer
        $again = Send-FleetStep $killPeer ([pscustomobject]@{
            op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 120000
        }) 180
        if (-not $again.ok) { throw "d never reached Connected on its second return: $($again.message)" }
        Start-Sleep -Seconds 5
        $parkedTwice = @(Get-PeerLogContains $killPeer $parked)
        Step $killPeer @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_D_FINAL' }
        if ($script:FleetVars['PEER_D_FINAL'] -ne $script:FleetVars['PEER_D']) {
            Set-Gate 'G5 the parked kill signal survives the restart and reaches d' 'FAIL'
            throw 'G5 failed: d lost its identity on the second return'
        }
        if ($parkedTwice.Count -eq 1) {
            Add-Note "ack rule: d's ack removed the entry, so its second auth was handed nothing"
        } else {
            Set-Gate 'G5 the parked kill signal survives the restart and reaches d' 'FAIL'
            Add-Note "G5 ack rule: the order was handed to d $($parkedTwice.Count) times, so the ack never reached the relay"
            throw 'G5 failed: the refused entry was re-sent on the next auth'
        }
    }

    # --- G6: a guest cannot park one. ---------------------------------------
    Say '6/6 a guest socket cannot park a destroy signal'
    # handle_kill_deposit refuses a guest before it reads a field and answers
    # nothing at all, so the check is "no kill_deposited reply".
    $guestVerdict = Invoke-GuestKillDeposit 'guest'
    $controlVerdict = Invoke-GuestKillDeposit 'control'
    if (-not $guestVerdict -or -not $controlVerdict) {
        Set-Gate 'G6 a guest socket cannot park a kill signal' 'WARN'
        Add-Note 'G6 needs node on PATH for a guest socket; nothing in the fleet can authenticate as one'
    } elseif ($guestVerdict -eq 'REFUSED' -and $controlVerdict -like 'ACCEPTED*') {
        Set-Gate 'G6 a guest socket cannot park a kill signal' 'PASS'
        Add-Note "guest deposit refused in silence; the same socket without the guest flag was answered ($controlVerdict), so the handler was listening"
    } elseif ($guestVerdict -like 'ACCEPTED*') {
        Set-Gate 'G6 a guest socket cannot park a kill signal' 'FAIL'
        Add-Note "G6: a GUEST parked a kill signal ($guestVerdict)"
        throw 'G6 failed: the relay accepted a deposit from a guest socket'
    } else {
        Set-Gate 'G6 a guest socket cannot park a kill signal' 'WARN'
        Add-Note "G6 could not reach a verdict (guest: $guestVerdict, control: $controlVerdict)"
    }
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
    $unreached = Set-FirstUnreachedGateFailed
    if ($unreached) { Say "first gate without a verdict: $unreached" 'Red' }
}

# --------------------------------------------------------------------------
# Cleanup. Runs whatever happened: these are real identities on the real relay.
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
Say "d = $($script:FleetVars.PEER_D) (throwaway, kill-list target only)" 'DarkCyan'

if ($failure) { throw $failure }
if (-not $KeepUp) {
    Say 'stopping the fleet'
    Invoke-FleetScript @('-Stop')
}
Say 'PASS' 'Green'
