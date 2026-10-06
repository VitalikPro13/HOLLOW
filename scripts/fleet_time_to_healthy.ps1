# Time to healthy: how long a fleet peer takes to work again after a trip away
# (RESUMABLE_SESSIONS_PLAN.md section 6). The host sends the first peer away
# (background, net_off or pause), waits, brings it back, and the probe's `health`
# op times two things from the moment the host acted: the connection reading
# `connected`, and a DM round trip through the second peer, which answers on its
# own (`autoreply`). Repeated, with p50 and p95, against the plan's targets
# (Connected within 1.5 s at p50 and 3 s at p95 on a good network).
#
#   powershell -File scripts\fleet_time_to_healthy.ps1 -Peers e,f -Trip background -Repeats 10
#   FLEET_ANDROID_PEERS=e pwsh scripts/fleet_time_to_healthy.ps1 -Peers e,f -Trip net -Repeats 10
#
# Both peers must be up (fleet.ps1 -Live -Peers e,f) and friends; -Befriend makes
# fresh ones friends first (fleet.ps1 -Onboard -Fresh -Peers e,f). The report
# lands in build/fleet_out/metrics/ as JSON and Markdown.
#
# `connected` alone can be a state from before the trip that nothing has
# corrected yet; each sample says whether the probe saw any other state first
# (`flapped`), and the round trip is the number that cannot lie.

param(
    [string]$Peers = 'e,f',
    [string]$Trip = 'background',
    [int]$Repeats = 5,
    [double]$AwaySeconds = 5,
    [int]$TimeoutSeconds = 120,
    [string]$NetOnMode = 'thaw',
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
if ($pair.Count -ne 2) { throw "-Peers takes two letters: the one sent away, then the one that answers (got '$Peers')" }
$x = $pair[0]
$y = $pair[1]
$ops = Get-CycleOps $Trip
$away = $ops[0]
$back = $ops[1]
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$setup = Initialize-FleetPair $x $y -Befriend:$Befriend
Invoke-FleetStepOrThrow $y @{ op = 'autoreply'; contact = $setup.idX } | Out-Null
# A Simulator and a desktop peer read this machine's own clock; an emulator keeps its own.
$clock = [pscustomobject]@{ offset = 0.0; rtt = 0 }
if (Test-AndroidBackend $x) { $clock = Get-ClockOffset $x }
Write-Host ("[tth] {0} clock offset {1:N0} ms (probe round trip {2} ms)" -f $x, $clock.offset, $clock.rtt) -ForegroundColor Cyan

# A round trip with nobody away: what the same measurement costs on a healthy pair.
$baseline = Invoke-FleetStepOrThrow $x @{ op = 'health'; rt_peer = $setup.idY; timeout_ms = 60000 } 120
Write-Host "[tth] baseline: $($baseline.message)" -ForegroundColor Cyan

$samples = @()
try {
    for ($i = 1; $i -le $Repeats; $i++) {
        $awayAnswer = Send-FleetStep $x ([pscustomobject]@{ op = $away }) 60
        if (-not $awayAnswer.ok) { throw "$away failed: $($awayAnswer.message)" }
        Start-Sleep -Milliseconds ([int]($AwaySeconds * 1000))
        $actedAt = Get-EpochMs
        $backStep = @{ op = $back }
        if ($back -eq 'net_on') { $backStep['mode'] = $NetOnMode }
        $backAnswer = Send-FleetStep $x ([pscustomobject]$backStep) 120
        if (-not $backAnswer.ok) { throw "$back failed: $($backAnswer.message)" }
        $health = Send-FleetStep $x ([pscustomobject]@{ op = 'health'; rt_peer = $setup.idY; timeout_ms = $TimeoutSeconds * 1000 }) ($TimeoutSeconds + 60)
        $sample = [ordered]@{
            i = $i
            ok = [bool]$health.ok
            back_op_ms = $backAnswer.ms
            connected_ms = $null
            rt_ms = $null
            flapped = $false
            states = @($health.states)
            message = $health.message
        }
        if ($null -ne $health.connected_epoch_ms) {
            $sample.connected_ms = [int]([double]$health.connected_epoch_ms - $clock.offset - $actedAt)
            $sample.flapped = -not [bool]$health.first_poll_connected
        }
        if ($null -ne $health.rt_epoch_ms) {
            $sample.rt_ms = [int]([double]$health.rt_epoch_ms - $clock.offset - $actedAt)
        }
        $samples += [pscustomobject]$sample
        Write-Host ("[tth] {0,2}/{1} {2,-5} connected {3,7} ms  round trip {4,7} ms  states {5}" -f $i, $Repeats,
            $(if ($health.ok) { 'ok' } else { 'FAIL' }), $sample.connected_ms, $sample.rt_ms, (@($health.states) -join '>')) -ForegroundColor Gray
        Start-Sleep -Seconds 2
    }
} finally {
    $notes = Restore-FleetPeer $x
    foreach ($note in $notes) { Write-Host "[tth] restore $x`: $note" -ForegroundColor Yellow }
}

$connected = @($samples | Where-Object { $null -ne $_.connected_ms } | ForEach-Object { $_.connected_ms })
$roundTrips = @($samples | Where-Object { $null -ne $_.rt_ms } | ForEach-Object { $_.rt_ms })
$summary = [ordered]@{
    trip = $Trip
    peer = $x
    answerer = $y
    backend = $(if (Test-AndroidBackend $x) { 'android' } elseif (Test-SimBackend $x) { 'ios-simulator' } elseif (Test-LinuxBackend) { 'linux' } else { 'windows' })
    repeats = $Repeats
    away_s = $AwaySeconds
    clock_offset_ms = [int]$clock.offset
    baseline_rt_ms = $baseline.rt_ms
    connected_p50_ms = Get-Percentile $connected 50
    connected_p95_ms = Get-Percentile $connected 95
    rt_p50_ms = Get-Percentile $roundTrips 50
    rt_p95_ms = Get-Percentile $roundTrips 95
    failures = @($samples | Where-Object { -not $_.ok }).Count
    flapped = @($samples | Where-Object { $_.flapped }).Count
    target_connected_p50_ms = 1500
    target_connected_p95_ms = 3000
    samples = $samples
}
$meets = ($summary.failures -eq 0) -and ($null -ne $summary.connected_p50_ms) -and
    ($summary.connected_p50_ms -le 1500) -and ($summary.connected_p95_ms -le 3000)
$summary['meets_target'] = $meets

$dir = Get-MetricsDir
$base = Join-Path $dir "tth-$Trip-$x-$stamp"
[System.IO.File]::WriteAllText("$base.json", ($summary | ConvertTo-Json -Depth 6))
$lines = @(
    "# Time to healthy: $Trip, peer $x ($($summary.backend)), answered by $y",
    '',
    "$Repeats trips of $AwaySeconds s; clock offset $($summary.clock_offset_ms) ms; baseline round trip $($summary.baseline_rt_ms) ms.",
    '',
    '| | p50 | p95 | target |',
    '|---|---|---|---|',
    "| back to connected (ms) | $($summary.connected_p50_ms) | $($summary.connected_p95_ms) | 1500 / 3000 |",
    "| back to a DM round trip (ms) | $($summary.rt_p50_ms) | $($summary.rt_p95_ms) | |",
    '',
    "Failures: $($summary.failures). Samples where connected was not the first state seen: $($summary.flapped). Meets the target: $meets.",
    '',
    '| # | ok | connected ms | round trip ms | back op ms | states |',
    '|---|---|---|---|---|---|'
)
foreach ($s in $samples) {
    $lines += "| $($s.i) | $($s.ok) | $($s.connected_ms) | $($s.rt_ms) | $($s.back_op_ms) | $(@($s.states) -join ' > ') |"
}
[System.IO.File]::WriteAllText("$base.md", (($lines -join "`n") + "`n"))
Write-Host ("[tth] {0} on {1}: connected p50 {2} / p95 {3} ms, round trip p50 {4} / p95 {5} ms, {6} failure(s). Report: {7}.md" -f
    $Trip, $x, $summary.connected_p50_ms, $summary.connected_p95_ms, $summary.rt_p50_ms, $summary.rt_p95_ms, $summary.failures, $base) -ForegroundColor Green
if (-not $meets) { exit 1 }
exit 0
