# Shared by fleet_time_to_healthy.ps1 and fleet_soak.ps1: the pair setup both
# need, the clock offset that lets a device's timestamps be measured from the
# moment the host acted, and the two numbers they report (percentiles, loss).
# Dot-source AFTER fleet_lib.ps1. fleet_metrics_selftest.ps1 checks the pure parts.

# A step that must work, or the run stops with the peer's answer.
function Invoke-FleetStepOrThrow($peer, $step, $timeoutSeconds = 180) {
    $answer = Send-FleetStep $peer ([pscustomobject]$step) $timeoutSeconds
    if (-not $answer.ok) { throw "$peer $($step.op) failed: $($answer.message)" }
    return $answer
}

# Nearest-rank percentile of a list of numbers; $null for an empty list.
function Get-Percentile($values, [double]$percent) {
    $sorted = @($values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $rank = [Math]::Ceiling(($percent / 100.0) * $sorted.Count)
    $index = [Math]::Min([Math]::Max([int]$rank - 1, 0), $sorted.Count - 1)
    return $sorted[$index]
}

# What one side sent that the other never holds. Duplicates on the receiving
# side never hide a gap, and a frame that arrived although its send was reported
# as failed is not a loss.
function Get-StreamLoss($sent, $received) {
    $held = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($seq in @($received)) { if ($null -ne $seq) { [void]$held.Add([int]$seq) } }
    $missing = @()
    foreach ($seq in @($sent)) {
        if ($null -ne $seq -and -not $held.Contains([int]$seq)) { $missing += [int]$seq }
    }
    $sentCount = @($sent | Where-Object { $null -ne $_ }).Count
    return [pscustomobject]@{ sent = $sentCount; lost = $missing.Count; missing = $missing }
}

# Ranges for a report line: 1,2,3,7,9,10 -> "1-3,7,9-10".
function Format-SeqRanges($values) {
    $sorted = @($values | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if ($sorted.Count -eq 0) { return '' }
    $parts = @()
    $start = $sorted[0]
    $prev = $sorted[0]
    for ($i = 1; $i -le $sorted.Count; $i++) {
        if ($i -lt $sorted.Count -and $sorted[$i] -eq $prev + 1) { $prev = $sorted[$i]; continue }
        if ($start -eq $prev) { $parts += "$start" } else { $parts += "$start-$prev" }
        if ($i -lt $sorted.Count) { $start = $sorted[$i]; $prev = $sorted[$i] }
    }
    return ($parts -join ',')
}

# device clock - host clock in ms, from the probe round trip that took the least
# time (its midpoint is the best guess of when the device read its clock).
function Get-ClockOffset($peer, $samples = 5) {
    $best = $null
    for ($i = 0; $i -lt $samples; $i++) {
        $before = Get-EpochMs
        $answer = Invoke-FleetStepOrThrow $peer @{ op = 'clock' } 60
        $after = Get-EpochMs
        $rtt = $after - $before
        if ($null -eq $best -or $rtt -lt $best.rtt) {
            $best = @{ rtt = $rtt; offset = [double]$answer.epoch_ms - (($before + $after) / 2.0) }
        }
    }
    return [pscustomobject]$best
}

# Both peers live, their master ids, and (with -Befriend) a friendship, which
# DMs between them need. Returns @{ x; y; idX; idY }.
function Initialize-FleetPair($x, $y, [switch]$Befriend) {
    $live = @(Get-LivePeers)
    foreach ($peer in @($x, $y)) {
        if ($live -notcontains $peer) { throw "peer $peer is not live. Start it: fleet.ps1 -Live -Peers $x,$y" }
    }
    foreach ($peer in @($x, $y)) {
        Invoke-FleetStepOrThrow $peer @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 120000 } 180 | Out-Null
    }
    $idX = (Invoke-FleetStepOrThrow $x @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'ID_X' }).captured.ID_X
    $idY = (Invoke-FleetStepOrThrow $y @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'ID_Y' }).captured.ID_Y
    if (-not $idX -or -not $idY) { throw 'could not read the two peer ids' }
    if ($Befriend) {
        Write-Host "[metrics] befriending $x and $y" -ForegroundColor Cyan
        Invoke-FleetStepOrThrow $x @{ op = 'friend'; action = 'request'; contact = $idY } | Out-Null
        Invoke-FleetStepOrThrow $y @{ op = 'wait_for'; provider = 'friends'; matches = [regex]::Escape($idX); timeout_ms = 90000 } 120 | Out-Null
        Invoke-FleetStepOrThrow $y @{ op = 'friend'; action = 'accept'; contact = $idX } | Out-Null
    }
    $accepted = '"status":"accepted"'
    Invoke-FleetStepOrThrow $x @{ op = 'wait_for'; provider = 'friends'; matches = ([regex]::Escape("$idY`"") + ',' + [regex]::Escape($accepted)); timeout_ms = 90000 } 120 | Out-Null
    Invoke-FleetStepOrThrow $y @{ op = 'wait_for'; provider = 'friends'; matches = ([regex]::Escape("$idX`"") + ',' + [regex]::Escape($accepted)); timeout_ms = 90000 } 120 | Out-Null
    return @{ x = $x; y = $y; idX = $idX; idY = $idY }
}

function Get-MetricsDir {
    $dir = Join-Path $script:FleetOutRoot 'metrics'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# The away and back ops of one kind of trip.
function Get-CycleOps($kind) {
    switch ($kind) {
        'background' { return @('background', 'foreground') }
        'net' { return @('net_off', 'net_on') }
        'pause' { return @('pause', 'resume') }
    }
    throw "unknown trip kind $kind (background, net, pause)"
}
