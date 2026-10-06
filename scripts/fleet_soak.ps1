# The resumable-sessions soak (RESUMABLE_SESSIONS_PLAN.md section 6): two fleet
# peers keep a counted DM stream running both ways while one of them at a time
# is sent away at random (background, a network cut, a process pause) and,
# when a canary relay is given, that relay is restarted now and then. At the end
# every message either side handed to its node must be in the other side's
# database: the loss counter must read zero.
#
#   powershell -File scripts\fleet_soak.ps1 -Peers e,f -Minutes 60
#   FLEET_ANDROID_PEERS=e pwsh scripts/fleet_soak.ps1 -Peers e,f -Minutes 60 \
#       -CanaryRelay canary.example.org -RelayRestart 'ssh box sudo systemctl restart hollow-relay-canary'
#
# Peers must be up (fleet.ps1 -Live -Peers e,f) and friends (-Befriend makes
# fresh ones friends). A relay restart runs ONLY with -CanaryRelay naming the
# relay every peer is on, and never against relay.anonlisten.com. Trips whose op
# a peer's backend cannot do (a network cut without the proxy route) are left
# out of the draw for that peer and named in the report. The report lands in
# build/fleet_out/metrics/ as JSON and Markdown; the exit code is 1 on any loss.

param(
    [string]$Peers = 'e,f',
    [double]$Minutes = 60,
    [int]$EveryMs = 3000,
    [string]$Trips = 'background,net,pause',
    [double]$MinAwaySeconds = 2,
    [double]$MaxAwaySeconds = 45,
    [double]$MinGapSeconds = 3,
    [double]$MaxGapSeconds = 25,
    [string]$CanaryRelay = '',
    [string]$RelayRestart = '',
    [double]$RestartEveryMinutes = 15,
    [int]$SettleSeconds = 180,
    [int]$Seed = 0,
    [switch]$Befriend
)
if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet'
$script:FleetOutRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet_out'
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')
. (Join-Path $PSScriptRoot 'fleet_metrics.ps1')

$pair = @($Peers -split '[,\s]+' | Where-Object { $_ })
if ($pair.Count -ne 2) { throw "-Peers takes two letters (got '$Peers')" }
$x = $pair[0]
$y = $pair[1]
$kinds = @($Trips -split '[,\s]+' | Where-Object { $_ })
foreach ($kind in $kinds) { [void](Get-CycleOps $kind) }
if ($RelayRestart) {
    if (-not $CanaryRelay) { throw '-RelayRestart needs -CanaryRelay: the soak restarts a canary, never a relay it has not been told about' }
    if ($CanaryRelay -match '(^|\.)relay\.anonlisten\.com$') { throw 'the soak never restarts the production relay' }
}
$random = if ($Seed) { New-Object System.Random $Seed } else { New-Object System.Random }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tag = "s$stamp"

$setup = Initialize-FleetPair $x $y -Befriend:$Befriend
$ids = @{ $x = $setup.idX; $y = $setup.idY }
if ($CanaryRelay) {
    foreach ($peer in @($x, $y)) {
        $relay = (Invoke-FleetStepOrThrow $peer @{ op = 'capture'; from = 'provider'; key = 'relayDomain'; as = 'RELAY' }).captured.RELAY
        if ($relay -ne $CanaryRelay) { throw "peer $peer is on $relay, not the canary ${CanaryRelay}. Onboard it with fleet.ps1 -Onboard -Fresh -Relay $CanaryRelay" }
    }
}

# Which trips each peer can take: a network cut off Android needs the proxy
# route to carry that peer's relay connection.
$canTake = @{}
foreach ($peer in @($x, $y)) {
    $canTake[$peer] = @()
    foreach ($kind in $kinds) {
        if ($kind -eq 'net' -and -not (Test-AndroidBackend $peer)) {
            $routed = $false
            if (Test-FleetProxyUp) {
                $routed = @((Invoke-FleetProxy 'list').connections | Where-Object { $_.route -eq $peer }).Count -gt 0
            }
            if (-not $routed) { continue }
        }
        if ($kind -eq 'background' -and (Test-LinuxBackend)) { continue }
        $canTake[$peer] += $kind
    }
}

$events = @()
$restarts = @()
$failure = $null
$streams = @{ $x = "$tag-$x"; $y = "$tag-$y" }
$started = Get-Date
$deadline = $started.AddMinutes($Minutes)
$nextRestart = $started.AddMinutes($RestartEveryMinutes)

Write-Host "[soak] $x <-> $y for $Minutes min, a message every $EveryMs ms each way, trips: $x [$($canTake[$x] -join ',')], $y [$($canTake[$y] -join ',')]" -ForegroundColor Cyan
Invoke-FleetStepOrThrow $x @{ op = 'stream_start'; contact = $ids[$y]; tag = $streams[$x]; every_ms = $EveryMs } | Out-Null
Invoke-FleetStepOrThrow $y @{ op = 'stream_start'; contact = $ids[$x]; tag = $streams[$y]; every_ms = $EveryMs } | Out-Null

try {
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds ([int](($MinGapSeconds + $random.NextDouble() * ($MaxGapSeconds - $MinGapSeconds)) * 1000))
        if ((Get-Date) -ge $deadline) { break }

        if ($RelayRestart -and (Get-Date) -ge $nextRestart) {
            $at = Get-Date
            Write-Host "[soak] restarting the canary relay $CanaryRelay" -ForegroundColor Yellow
            $output = & ([scriptblock]::Create($RelayRestart)) 2>&1 | Out-String
            $restarts += [pscustomobject]@{ at = $at.ToString('o'); ok = ($LASTEXITCODE -eq 0); output = $output.Trim() }
            $nextRestart = (Get-Date).AddMinutes($RestartEveryMinutes)
            continue
        }

        $candidates = @(@($x, $y) | Where-Object { $canTake[$_].Count -gt 0 })
        if ($candidates.Count -eq 0) { continue }
        $peer = $candidates[$random.Next($candidates.Count)]
        $kind = $canTake[$peer][$random.Next($canTake[$peer].Count)]
        $ops = Get-CycleOps $kind
        $awayFor = $MinAwaySeconds + $random.NextDouble() * ($MaxAwaySeconds - $MinAwaySeconds)
        $trip = [ordered]@{ at = (Get-Date).ToString('o'); peer = $peer; trip = $kind; away_s = [Math]::Round($awayFor, 1); ok = $true; note = '' }

        $answer = Send-FleetStep $peer ([pscustomobject]@{ op = $ops[0] }) 60
        if (-not $answer.ok) { $trip.ok = $false; $trip.note = "$($ops[0]): $($answer.message)" }
        Start-Sleep -Milliseconds ([int]($awayFor * 1000))
        $backStep = @{ op = $ops[1] }
        if ($ops[1] -eq 'net_on' -and $random.Next(2) -eq 1) { $backStep['mode'] = 'drop' }
        $answer = Send-FleetStep $peer ([pscustomobject]$backStep) 120
        if (-not $answer.ok) { $trip.ok = $false; $trip.note += " $($ops[1]): $($answer.message)" }
        $events += [pscustomobject]$trip
        Write-Host ("[soak] {0} {1,-10} {2,5:N1}s {3}" -f $peer, $kind, $awayFor, $(if ($trip.ok) { 'ok' } else { "FAIL $($trip.note)" })) -ForegroundColor Gray
        if (-not $trip.ok) {
            # A peer that did not come back would turn every later trip into noise.
            foreach ($note in (Restore-FleetPeer $peer)) { Write-Host "[soak] restore $peer`: $note" -ForegroundColor Yellow }
        }
    }
} catch {
    $failure = "$($_.Exception.Message)"
    Write-Host "[soak] stopped early: $failure" -ForegroundColor Red
} finally {
    foreach ($peer in @($x, $y)) {
        foreach ($note in (Restore-FleetPeer $peer)) { Write-Host "[soak] restore $peer`: $note" -ForegroundColor Yellow }
    }
}

# Stop sending, then give everything in flight (queues, syncs, catch-ups) until
# the settle window ends or nothing is missing any more.
foreach ($peer in @($x, $y)) {
    $answer = Send-FleetStep $peer ([pscustomobject]@{ op = 'stream_stop'; tag = $streams[$peer] }) 60
    if (-not $answer.ok) { Write-Host "[soak] $peer stream_stop: $($answer.message)" -ForegroundColor Yellow }
}
$settleUntil = (Get-Date).AddSeconds($SettleSeconds)
$loss = $null
while ($true) {
    $statsX = Invoke-FleetStepOrThrow $x @{ op = 'stream_stats'; contact = $ids[$y]; tag = $streams[$x] } 120
    $statsY = Invoke-FleetStepOrThrow $y @{ op = 'stream_stats'; contact = $ids[$x]; tag = $streams[$y] } 120
    $heldByY = Invoke-FleetStepOrThrow $y @{ op = 'stream_stats'; contact = $ids[$x]; tag = $streams[$x] } 120
    $heldByX = Invoke-FleetStepOrThrow $x @{ op = 'stream_stats'; contact = $ids[$y]; tag = $streams[$y] } 120
    $loss = [ordered]@{
        "$x->$y" = Get-StreamLoss $statsX.sent $heldByY.received
        "$y->$x" = Get-StreamLoss $statsY.sent $heldByX.received
    }
    $lost = 0
    foreach ($key in $loss.Keys) { $lost += $loss[$key].lost }
    if ($lost -eq 0 -or (Get-Date) -ge $settleUntil) { break }
    Write-Host "[soak] still missing $lost, waiting for catch-up" -ForegroundColor Gray
    Start-Sleep -Seconds 10
}
$lost = 0
foreach ($key in $loss.Keys) { $lost += $loss[$key].lost }

$summary = [ordered]@{
    peers = "$x,$y"
    minutes = $Minutes
    ran_minutes = [Math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    every_ms = $EveryMs
    trips = $events.Count
    trip_failures = @($events | Where-Object { -not $_.ok }).Count
    relay_restarts = $restarts.Count
    canary = $CanaryRelay
    can_take = $canTake
    lost = $lost
    loss = $loss
    received_dupes = @{ $y = $heldByY.received_dupes; $x = $heldByX.received_dupes }
    failure = $failure
    events = $events
    restarts = $restarts
}
$dir = Get-MetricsDir
$base = Join-Path $dir "soak-$x$y-$stamp"
[System.IO.File]::WriteAllText("$base.json", ($summary | ConvertTo-Json -Depth 6))
$lines = @(
    "# Soak $x <-> $y, $($summary.ran_minutes) min",
    '',
    "A message every $EveryMs ms each way; $($events.Count) trips away ($($summary.trip_failures) failed); $($restarts.Count) relay restarts.",
    '',
    '| direction | sent | lost | missing |',
    '|---|---|---|---|'
)
foreach ($key in $loss.Keys) {
    $lines += "| $key | $($loss[$key].sent) | $($loss[$key].lost) | $(Format-SeqRanges $loss[$key].missing) |"
}
$lines += ''
$lines += "**Loss counter: $lost.** Duplicates held: $($heldByY.received_dupes) on $y, $($heldByX.received_dupes) on $x."
if ($failure) { $lines += ''; $lines += "Stopped early: $failure" }
$lines += ''
$lines += '| at | peer | trip | away s | ok | note |'
$lines += '|---|---|---|---|---|---|'
foreach ($e in $events) { $lines += "| $($e.at) | $($e.peer) | $($e.trip) | $($e.away_s) | $($e.ok) | $($e.note) |" }
[System.IO.File]::WriteAllText("$base.md", (($lines -join "`n") + "`n"))
Write-Host "[soak] loss counter $lost after $($events.Count) trips. Report: $base.md" -ForegroundColor $(if ($lost -eq 0 -and -not $failure) { 'Green' } else { 'Red' })
if ($lost -ne 0 -or $failure) { exit 1 }
exit 0
