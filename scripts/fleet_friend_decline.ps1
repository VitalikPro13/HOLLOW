# Async-friend DECLINE stays sticky, across two REAL Hollow instances.
#
#   powershell -File scripts\fleet.ps1 -Live -Peers a,b
#   powershell -File scripts\fleet_friend_decline.ps1
#
# Companion to fleet_friend_offline.ps1. a is the REQUESTER, b the DECLINER.
#
# What it proves (the regression for the sticky-decline fix): the relay inbox
# mailbox is TTL-only, so a declined request would otherwise re-deliver on b's
# next reboot and resurface in Incoming for up to three days. With decline
# writing a `declined` tombstone, the re-delivery is ignored: after b declines
# and reboots, Incoming stays empty and no friend is created.
#
# Windows PowerShell 5.1 (no pwsh-only syntax).

param(
    # The decliner. Defaults to b, but the fixed fleet identities accumulate
    # relay-buffered requests across runs, so a truly clean signal wants a peer
    # with no friend-request history (e.g. c).
    [string]$Decliner = 'b',
    [int]$BootTimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'

function Say($message, $colour = 'Cyan') { Write-Host "[friend-decline] $message" -ForegroundColor $colour }

function Step($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 180
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

# Relaunch ONE peer on its EXISTING data dir (fixture NOT restored). Mirrors
# fleet_owner_offline.ps1 / fleet_friend_offline.ps1.
function Restart-Peer($peer) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $data = Join-Path $runRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $script:FleetConsumed[$peer] = 0

    $env:HOLLOW_DATA_DIR = $data
    $env:UI_PROBE_OUT = $out
    $env:UI_PROBE_MODE = 'live'
    $env:UI_PROBE_PEER = $peer
    $env:UI_PROBE_IDLE_MINUTES = '40'
    $env:UI_PROBE_SCENARIO_FILE = ''
    $env:UI_PROBE_STEPS = ''
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
    Start-Sleep -Milliseconds 1500
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
    Say "$peer is closed - OFFLINE" 'Yellow'
}

$live = Get-LivePeers
foreach ($peer in @('a', $Decliner)) {
    if ($live -notcontains $peer) {
        throw "peer '$peer' is not running. Start the fleet with: powershell -File scripts\fleet.ps1 -Live -Peers a,$Decliner (live: $($live -join ', '))"
    }
}

# --- 0. capture b's master id (a addresses the request to it). ---------------
Step a @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step $Decliner @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step $Decliner @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_B' }

# --- 1. b offline; a sends -> deposited in b's mailbox. ----------------------
Stop-Peer $Decliner
Step a @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step a @{ op = 'tap'; target = 'text:Add Friend'; index = 0 }
Step a @{ op = 'enter_text'; target = 'hint:Peer ID or nickname...'; value = '${PEER_B}' }
Step a @{ op = 'tap'; target = 'text:Send Request'; index = 0 }
# Let a's WS layer actually FLUSH the deposit frame to the relay before we kill
# it — the deposit log prints when the frame is QUEUED, not sent, and a hard
# kill in the gap loses it (the fresh decliner has no prior buffer to mask it).
Step a @{ op = 'wait'; ms = 5000 }
Say "a sent the request to an offline b (deposited in the relay mailbox)"

# --- 2. a offline; b opens ALONE, collects from the mailbox, DECLINES. -------
Stop-Peer a
Restart-Peer $Decliner
Step $Decliner @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step $Decliner @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
Step $Decliner @{ op = 'wait_for'; target = 'semantics:Reject friend request'; timeout_ms = 60000 }
Step $Decliner @{ op = 'tap'; target = 'semantics:Reject friend request'; index = 0 }
Say "b declined the request delivered from the mailbox"

# --- 3. THE REGRESSION: b reboots; the TTL-only mailbox replays the request.
#        The declined tombstone must swallow it - no resurrection. -----------
Stop-Peer $Decliner
Restart-Peer $Decliner
Step $Decliner @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 }
Step $Decliner @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
Step $Decliner @{ op = 'tap'; target = 'text:Incoming'; index = 0 }
Step $Decliner @{ op = 'wait_for'; target = 'text:No incoming requests'; timeout_ms = 15000 }
Say "PASS gate 1: b's Incoming is empty after re-delivery - the decline stuck"
# And no friendship was created.
Step $Decliner @{ op = 'tap'; target = 'text:Friends'; index = 0 }
Step $Decliner @{ op = 'wait_for'; target = 'text:No friends yet'; timeout_ms = 15000 }
Say "PASS gate 2: b has no friend - a declined request never became a friendship"

Step $Decliner @{ op = 'dump'; name = 'friend_decline_converged' }
Say "DONE - decline stays sticky across mailbox re-delivery" 'Green'
