<#
Runs every fleet journey and scenario in turn and prints one gate table.

    powershell -File scripts\fleet_all.ps1                     # build once, then everything
    powershell -File scripts\fleet_all.ps1 -SkipBuild -Only friend_dm,fleet_pending_join
    powershell -File scripts\fleet_all.ps1 -SkipBuild -From fleet_pending_join

Each item gets its own log under build\fleet_out\all\<name>.log. After each one, the
part of every peer's hollow_debug.log stamped since the item began is kept as
<name>-<peer>.log (the app truncates that file in place at launch once it passes
10 MB, so without the copy only the last item's lines survive a full run), and it
is searched for the lines a security gate writes when it refuses something; those
land in <name>-refusals.txt, because a gate that refuses honest traffic is a
regression as real as a failed step.

fleet_relay_restart restarts the PRODUCTION relay, fleet_relay_switch needs a
self-hosted one and fleet_at_rest seeds from an older build, so they stay out
unless named in -Only.

The scenario fixtures are onboarded fresh first (-KeepFixtures skips it): a stable
identity carries an earlier run's mailbox and roster into the next one.
#>
param(
    [string[]]$Only = @(),
    [string]$From = '',
    [switch]$SkipBuild,
    [switch]$KeepFixtures
)
if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# Scenarios run on the fixtures (args: extra fleet.ps1 switches; keepUp: the next
# item attaches to this one's fleet); journeys mint their own identities.
$items = @(
    @{ name = 'friend_dm';                  kind = 'scenario'; peers = 'a,b' },
    @{ name = 'server_invite_message';      kind = 'scenario'; peers = 'a,b' },
    @{ name = 'unread_line';                kind = 'scenario'; peers = 'a,b' },
    @{ name = 'album_dm';                   kind = 'scenario'; peers = 'a,b' },
    @{ name = 'voice_channel';              kind = 'scenario'; peers = 'a,b' },
    @{ name = 'moderation';                 kind = 'scenario'; peers = 'a,b,c' },
    @{ name = 'chat_redesign';              kind = 'scenario'; peers = 'a,b' },
    @{ name = 'avatar_frame';               kind = 'scenario'; peers = 'a,b' },
    @{ name = 'member_panel_pass';          kind = 'scenario'; peers = 'a,b' },
    @{ name = 'server_settings_after';      kind = 'scenario'; peers = 'a,b' },
    @{ name = 'calls_after';                kind = 'scenario'; peers = 'a,b'; args = '-Keep'; keepUp = $true },
    @{ name = 'calls_after_vc';             kind = 'scenario'; peers = 'a,b'; args = '-Attach' },
    @{ name = 'places_after';               kind = 'scenario'; peers = 'a,b' },
    @{ name = 'regress_channels';           kind = 'scenario'; peers = 'a,b,c' },
    @{ name = 'regress_social';             kind = 'scenario'; peers = 'a,b,c'; fresh = $true },
    @{ name = 'regress_media';              kind = 'scenario'; peers = 'a,b'; fresh = $true; args = '-StepTimeoutSeconds 300' },
    @{ name = 'regress_voice3';             kind = 'scenario'; peers = 'a,b,c' },
    @{ name = 'fleet_friend_readd';         kind = 'script' },
    @{ name = 'fleet_friend_decline';       kind = 'script' },
    @{ name = 'fleet_friend_offline';       kind = 'script' },
    @{ name = 'fleet_owner_offline';        kind = 'script'; boot = 'a,b,c' },
    @{ name = 'fleet_pending_join';         kind = 'script' },
    @{ name = 'fleet_file_card_states';     kind = 'script' },
    @{ name = 'fleet_channel_file_catchup'; kind = 'script' },
    @{ name = 'fleet_asset_offline';        kind = 'script' },
    @{ name = 'fleet_at_rest';              kind = 'script'; optIn = $true },
    @{ name = 'fleet_multidevice_dm_gap';   kind = 'script' },
    @{ name = 'fleet_device_link';          kind = 'script' },
    @{ name = 'fleet_destroy';              kind = 'script' },
    @{ name = 'fleet_relay_restart';        kind = 'script'; optIn = $true },
    @{ name = 'fleet_relay_switch';         kind = 'script'; optIn = $true }
)
if ($Only.Count -gt 0) {
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $unknown = @($Only | Where-Object { $n = $_; -not ($items | Where-Object { $_.name -eq $n }) })
    if ($unknown.Count -gt 0) { throw "unknown item(s): $($unknown -join ', ')" }
    $items = @($items | Where-Object { $Only -contains $_.name })
} else {
    $items = @($items | Where-Object { -not $_.optIn })
}
if ($From) {
    $at = [array]::IndexOf(@($items | ForEach-Object { $_.name }), $From)
    if ($at -lt 0) { throw "unknown -From item: $From" }
    $items = @($items[$at..($items.Count - 1)])
}

$allOut = Join-Path $repo 'build\fleet_out\all'
New-Item -ItemType Directory -Path $allOut -Force | Out-Null
$stageRoot = Join-Path $repo 'build\fleet'

if (-not $SkipBuild) {
    Write-Host '[all] building once for every item' -ForegroundColor Cyan
    # d is fleet_destroy's third device; a stale copy would run an older app.
    cmd /c "powershell -NoProfile -File scripts\fleet.ps1 -Build -Peers a,b,c,d > `"$allOut\build.log`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "build failed, see $allOut\build.log" }
}
if (-not $KeepFixtures -and @($items | Where-Object { $_.kind -eq 'scenario' }).Count -gt 0) {
    Write-Host '[all] onboarding fresh fixtures a,b,c' -ForegroundColor Cyan
    cmd /c "powershell -NoProfile -File scripts\fleet.ps1 -Onboard -Fresh -Peers a,b,c > `"$allOut\onboard.log`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "onboarding failed, see $allOut\onboard.log" }
}

# The words a refusing gate logs. Each hit on an honest journey is either explained
# or a bug.
$refusal = '\[HOLLOW-SECURITY\]|REJECTED|Dropped|Refused|Ignored'

# The lines of one hollow_debug.log written at or after $since (unix seconds).
# Every line the app writes starts "[secs] "; an unstamped continuation line
# belongs to the stamp above it.
function Get-LogLinesSince($path, $since) {
    $kept = New-Object System.Collections.Generic.List[string]
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $stamp = [int64]0
        $parsed = [int64]0
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.StartsWith('[')) {
                $close = $line.IndexOf(']')
                if ($close -gt 1 -and [int64]::TryParse($line.Substring(1, $close - 1), [ref]$parsed)) { $stamp = $parsed }
            }
            if ($stamp -ge $since) { $kept.Add($line) }
        }
    } finally { $stream.Dispose() }
    return ,$kept.ToArray()
}

$results = @()
foreach ($item in $items) {
    $log = Join-Path $allOut "$($item.name).log"
    $started = Get-Date
    Write-Host ("[all] {0} ..." -f $item.name) -ForegroundColor Cyan
    if ($item.kind -eq 'scenario') {
        $cmd = "powershell -NoProfile -File scripts\fleet.ps1 -Scenario $($item.name) -Peers $($item.peers) $($item.args)"
    } else {
        $script = Join-Path 'scripts' "$($item.name).ps1"
        $params = (Get-Command (Join-Path $repo $script)).Parameters
        $extra = if ($params.ContainsKey('SkipBuild')) { ' -SkipBuild' } else { '' }
        $cmd = "powershell -NoProfile -File $script$extra"
    }
    if ($item.fresh) {
        # The relay replays an earlier item's friend requests to a restored fixture
        # for three days, so a journey that starts from no contacts gets new identities.
        cmd /c "powershell -NoProfile -File scripts\fleet.ps1 -Onboard -Fresh -Peers $($item.peers) > `"$allOut\$($item.name)-onboard.log`" 2>&1"
    }
    if ($item.boot) {
        # A journey that drives an already-live fleet instead of booting its own.
        cmd /c "powershell -NoProfile -File scripts\fleet.ps1 -Live -Peers $($item.boot) > `"$allOut\$($item.name)-boot.log`" 2>&1"
    }
    cmd /c "$cmd > `"$log`" 2>&1"
    $code = $LASTEXITCODE
    $text = [System.IO.File]::ReadAllText($log)
    $gates = @([regex]::Matches($text, '(?m)^\s{2}(PASS|FAIL|WARN|SKIP|n/a)\s+(.+)$') |
        ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value.Trim())" })
    $failedGates = @($gates | Where-Object { $_ -like 'FAIL *' })
    $status = if ($code -eq 0 -and $failedGates.Count -eq 0) { 'PASS' } else { 'FAIL' }

    # The log sits beside each staged exe and outlives runs, so only lines stamped
    # after this item started count; they are kept per peer before the next item
    # launches anything into the same file.
    $hits = @()
    $since = [DateTimeOffset]::new($started).ToUnixTimeSeconds()
    foreach ($peerDir in Get-ChildItem $stageRoot -Directory) {
        $debugLog = Join-Path $peerDir.FullName 'hollow_debug.log'
        if (-not (Test-Path $debugLog) -or (Get-Item $debugLog).LastWriteTime -lt $started) { continue }
        try { $lines = Get-LogLinesSince $debugLog $since } catch {
            Write-Host "[all] could not read $debugLog : $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }
        if ($lines.Count -eq 0) { continue }
        [System.IO.File]::WriteAllLines((Join-Path $allOut "$($item.name)-$($peerDir.Name).log"), [string[]]$lines)
        $hits += @($lines | Where-Object { $_ -match $refusal } | ForEach-Object { "$($peerDir.Name): $_" })
    }
    [System.IO.File]::WriteAllLines((Join-Path $allOut "$($item.name)-refusals.txt"), [string[]]$hits)

    # The next launch empties build\fleet_out\<peer>, so the item's named shots are
    # kept here (the per-step live-*.png frames are not).
    foreach ($outDir in Get-ChildItem (Join-Path $repo 'build\fleet_out') -Directory | Where-Object { $_.Name -match '^[a-d]$' }) {
        $shots = @(Get-ChildItem $outDir.FullName -Filter '*.png' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $started -and $_.Name -notlike 'live-*' -and $_.Name -ne '00-boot.png' })
        if ($shots.Count -eq 0) { continue }
        $keep = Join-Path $allOut "$($item.name)-shots\$($outDir.Name)"
        New-Item -ItemType Directory -Path $keep -Force | Out-Null
        $shots | Copy-Item -Destination $keep -Force
    }

    $results += [pscustomobject]@{
        Name = $item.name; Status = $status; Exit = $code
        Minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
        Gates = $gates.Count; Failed = $failedGates; Refusals = $hits.Count
    }
    $colour = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("[all] {0} {1} ({2} gates, {3} refusal lines, {4} min)" -f $status, $item.name,
        $gates.Count, $hits.Count, $results[-1].Minutes) -ForegroundColor $colour
    # A failed journey leaves its fleet up for diagnosis; the next one needs it down.
    if (-not $item.keepUp) {
        cmd /c "powershell -NoProfile -File scripts\fleet.ps1 -Stop > nul 2>&1"
    }
}

$lines = @('| item | result | gates | refusal lines | minutes |', '|---|---|---|---|---|')
foreach ($r in $results) {
    $lines += "| $($r.Name) | $($r.Status) | $($r.Gates) | $($r.Refusals) | $($r.Minutes) |"
    foreach ($f in $r.Failed) { $lines += "|  | $f |  |  |  |" }
}
[System.IO.File]::WriteAllLines((Join-Path $allOut 'summary.md'), [string[]]$lines)
Write-Host ''
$lines | ForEach-Object { Write-Host $_ }
if (@($results | Where-Object { $_.Status -ne 'PASS' }).Count -gt 0) { exit 1 }
