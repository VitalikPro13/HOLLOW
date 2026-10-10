<#
Runs every fleet journey and scenario and prints one gate table.

    powershell -File scripts\fleet_all.ps1                     # build once, then everything, 3 at once
    powershell -File scripts\fleet_all.ps1 -SkipBuild -Only friend_dm,fleet_pending_join
    powershell -File scripts\fleet_all.ps1 -SkipBuild -From fleet_pending_join
    powershell -File scripts\fleet_all.ps1 -SkipBuild -MaxParallel 1   # the serial run
    powershell -File scripts\fleet_all.ps1 -DryRun                     # print the schedule, run nothing

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

-MaxParallel (default 3, up to 9) runs independent items at once. Each running
item owns a LANE, its own copy of every per-peer place (FLEET_LANE in
fleet_lib.ps1), so every item keeps its own peer letters: lane 0 is the usual
build\fleet layout, the others are mirrored from it and get fixtures of their own.
Items marked alone (voice, calls, media: timing-sensitive) run on lane 0 with
nothing else up, after the rest. Every item after the first starts only while the
CPU load is under -CpuLimit and -MinFreeGB of memory is free.
#>
param(
    [string[]]$Only = @(),
    [string]$From = '',
    [switch]$SkipBuild,
    [switch]$KeepFixtures,
    # How many items may run at once. 1 is the serial run. More than 3 gains
    # little: the relay's 10 new sockets a minute per address, not the CPU, caps
    # the lanes (session 43: 5 lanes saved 6 min for 76 launch waits).
    [ValidateRange(1, 9)][int]$MaxParallel = 3,
    # Print the schedule and stop: nothing is built, staged, booted or stopped.
    [switch]$DryRun,
    [ValidateRange(10, 100)][int]$CpuLimit = 80,
    [double]$MinFreeGB = 4,
    # An item still running after this long is killed and counted as failed.
    [int]$ItemTimeoutMinutes = 60
)
if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
if ($env:FLEET_LANE) { throw 'run fleet_all.ps1 without FLEET_LANE set: it gives each item its lane itself' }

$script:FleetRepo = $repo
$script:FleetStageRoot = Join-Path $repo 'build\fleet'
$script:FleetOutRoot = Join-Path $repo 'build\fleet_out'
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

# Scenarios run on the fixtures (args: extra fleet.ps1 switches; keepUp: the next
# item attaches to this one's fleet, so the two run as one unit on one lane);
# journeys mint their own identities. min = the item's minutes in the serial
# run of session 43, the order a parallel run starts them in. alone =
# timing-sensitive.
$items = @(
    @{ name = 'friend_dm';                  kind = 'scenario'; peers = 'a,b'; min = 0.7 },
    @{ name = 'server_invite_message';      kind = 'scenario'; peers = 'a,b'; min = 0.9 },
    @{ name = 'unread_line';                kind = 'scenario'; peers = 'a,b'; min = 1.9 },
    @{ name = 'album_dm';                   kind = 'scenario'; peers = 'a,b'; min = 1.6 },
    @{ name = 'voice_channel';              kind = 'scenario'; peers = 'a,b'; min = 1.6; alone = $true },
    @{ name = 'moderation';                 kind = 'scenario'; peers = 'a,b,c'; min = 2.5 },
    @{ name = 'chat_redesign';              kind = 'scenario'; peers = 'a,b'; min = 2.8 },
    @{ name = 'avatar_frame';               kind = 'scenario'; peers = 'a,b'; min = 1.2 },
    @{ name = 'member_panel_pass';          kind = 'scenario'; peers = 'a,b'; min = 1.9 },
    @{ name = 'server_settings_after';      kind = 'scenario'; peers = 'a,b'; min = 2.5 },
    @{ name = 'calls_after';                kind = 'scenario'; peers = 'a,b'; min = 2.6; alone = $true; args = '-Keep'; keepUp = $true },
    @{ name = 'calls_after_vc';             kind = 'scenario'; peers = 'a,b'; min = 2.9; alone = $true; args = '-Attach' },
    @{ name = 'places_after';               kind = 'scenario'; peers = 'a,b'; min = 3.8 },
    @{ name = 'regress_channels';           kind = 'scenario'; peers = 'a,b,c'; min = 3.0 },
    @{ name = 'regress_social';             kind = 'scenario'; peers = 'a,b,c'; min = 4.4; fresh = $true },
    @{ name = 'regress_media';              kind = 'scenario'; peers = 'a,b'; min = 3.9; alone = $true; fresh = $true; args = '-StepTimeoutSeconds 300' },
    @{ name = 'regress_voice3';             kind = 'scenario'; peers = 'a,b,c'; min = 3.1; alone = $true },
    @{ name = 'fleet_friend_readd';         kind = 'script'; peers = 'a,b'; min = 2.8 },
    @{ name = 'fleet_friend_decline';       kind = 'script'; peers = 'a,b'; min = 2.5 },
    @{ name = 'fleet_friend_offline';       kind = 'script'; peers = 'a,b'; min = 2.1 },
    @{ name = 'fleet_owner_offline';        kind = 'script'; peers = 'a,b,c'; min = 1.7; boot = 'a,b,c' },
    @{ name = 'fleet_pending_join';         kind = 'script'; peers = 'a,b'; min = 2.9 },
    @{ name = 'fleet_file_card_states';     kind = 'script'; peers = 'a,b'; min = 4.8 },
    @{ name = 'fleet_channel_file_catchup'; kind = 'script'; peers = 'a,b'; min = 4.3 },
    @{ name = 'fleet_asset_offline';        kind = 'script'; peers = 'a,b'; min = 3.2 },
    @{ name = 'fleet_at_rest';              kind = 'script'; peers = 'a,b'; min = 5.0; optIn = $true },
    @{ name = 'fleet_multidevice_dm_gap';   kind = 'script'; peers = 'a,b,c'; min = 8.9 },
    @{ name = 'fleet_device_link';          kind = 'script'; peers = 'a,b,c'; min = 7.8 },
    @{ name = 'fleet_destroy';              kind = 'script'; peers = 'a,b,c,d'; min = 7.8 },
    @{ name = 'fleet_relay_restart';        kind = 'script'; peers = 'a,b'; min = 5.0; optIn = $true; alone = $true },
    @{ name = 'fleet_relay_switch';         kind = 'script'; peers = 'a,b,c'; min = 4.0; optIn = $true; alone = $true }
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

# A keepUp item and the one that attaches to it share a fleet, so they are one unit.
$units = @()
for ($i = 0; $i -lt $items.Count; $i++) {
    $members = @($items[$i])
    while ($items[$i].keepUp -and $i + 1 -lt $items.Count) { $i++; $members += $items[$i] }
    $minutes = 0.0
    foreach ($member in $members) { $minutes += [double]$member.min }
    $units += [pscustomobject]@{
        Items = $members
        Name = ($members | ForEach-Object { $_.name }) -join ' + '
        Alone = @($members | Where-Object { $_.alone }).Count -gt 0
        Min = $minutes
    }
}
# No more lanes than units that can run side by side: a short -Only run stays on lane 0.
$sideBySide = @($units | Where-Object { -not $_.Alone }).Count
if ($MaxParallel -gt [math]::Max(1, $sideBySide)) { $MaxParallel = [math]::Max(1, $sideBySide) }
# Serial keeps the listed order. Parallel starts the longest units first, so the
# lanes finish close together, and the alone units after them, in listed order.
if ($MaxParallel -gt 1) {
    $units = @(@($units | Where-Object { -not $_.Alone } | Sort-Object -Property Min -Descending) +
        @($units | Where-Object { $_.Alone }))
}

$allOut = Join-Path $repo 'build\fleet_out\all'
$runDir = Join-Path $allOut 'run'
$laneIds = @(0..($MaxParallel - 1))
# Every letter -Build stages (d is fleet_destroy's third device), and so every
# letter a lane needs.
$stagePeers = @('a', 'b', 'c', 'd')
$needFixtures = (-not $KeepFixtures) -and @($items | Where-Object { $_.kind -eq 'scenario' }).Count -gt 0

if ($DryRun) {
    $mode = if ($MaxParallel -eq 1) { 'serial' } else { "parallel, $MaxParallel lanes" }
    Write-Host "[all] dry run: $($items.Count) items in $($units.Count) units, $mode" -ForegroundColor Cyan
    foreach ($n in $laneIds) {
        $layout = Get-FleetLaneLayout $n
        Write-Host ("[all] lane {0}: stage {1}  out {2}  temp {3}" -f $n, $layout.Stage, $layout.Out, $layout.Temp)
    }
    if ($MaxParallel -gt 1) {
        $peerDir = Join-Path $script:FleetStageRoot 'a'
        $perPeer = if (Test-Path $peerDir) { [math]::Round(((Get-ChildItem $peerDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1GB, 2) } else { 0.37 }
        Write-Host ("[all] lanes 1-{0} are mirrored from lane 0 ({1} x {2} GB = {3} GB of disk per lane)" -f
            ($MaxParallel - 1), $stagePeers.Count, $perPeer, [math]::Round($stagePeers.Count * $perPeer, 1))
    }
    if ($needFixtures) { Write-Host "[all] onboarding fresh a,b,c in every lane at once (about 2 min)" }
    # The expected schedule from the items' serial minutes, guard and slowdown ignored.
    $free = @{}
    foreach ($n in $laneIds) { $free[$n] = 0.0 }
    $rows = @()
    foreach ($unit in $units) {
        if ($unit.Alone) {
            $start = ($free.Values | Measure-Object -Maximum).Maximum
            foreach ($n in $laneIds) { $free[$n] = $start + $unit.Min }
            $lane = 0
        } else {
            $lane = ($laneIds | Sort-Object { $free[$_] }, { $_ } | Select-Object -First 1)
            $start = $free[$lane]
            $free[$lane] = $start + $unit.Min
        }
        $rows += [pscustomobject]@{ Start = $start; Lane = $lane; Unit = $unit }
    }
    Write-Host ''
    Write-Host '  start  lane  min   unit'
    foreach ($row in $rows) {
        $tag = if ($row.Unit.Alone) { '  ALONE' } else { '' }
        $peers = ($row.Unit.Items | ForEach-Object { $_.peers } | Select-Object -Unique) -join ' '
        Write-Host ('  {0,5:N1}  {1,4}  {2,4:N1}  {3} [{4}]{5}' -f $row.Start, $row.Lane, $row.Unit.Min, $row.Unit.Name, $peers, $tag)
    }
    $end = ($free.Values | Measure-Object -Maximum).Maximum
    $sum = ($units | Measure-Object -Property Min -Sum).Sum
    Write-Host ''
    Write-Host ("[all] expected item time {0:N1} min (serial sum {1:N1} min), plus build and onboarding" -f $end, $sum) -ForegroundColor Cyan
    exit 0
}

New-Item -ItemType Directory -Path $runDir -Force | Out-Null

# Generated fixture files the selected scenarios attach, made here when missing
# (a fresh worktree has none of them).
$fixtureSets = @(
    @{ maker = 'make_regress_fixtures.py'; dir = 'build\regress_fixtures'; needs = @{
        places_after = @('synth-session-stems.zip')
        regress_media = @('regress_clip.mp4', 'regress_gate_6mb.bin', 'regress_big_40mb.bin', 'Voice message.ogg') } },
    @{ maker = 'make_album_fixtures.py'; dir = 'build\album_fixtures'; needs = @{
        album_dm = @('red.png', 'blue.png', 'yellow.png', 'green_noise.gif') } }
)
foreach ($set in $fixtureSets) {
    $fixtureDir = Join-Path $repo $set.dir
    $wanted = @($items | ForEach-Object { $set.needs[$_.name] } | Where-Object { $_ })
    $absent = @($wanted | Where-Object { -not (Test-Path (Join-Path $fixtureDir $_)) })
    if ($absent.Count -eq 0) { continue }
    $makerLog = Join-Path $allOut "$([IO.Path]::GetFileNameWithoutExtension($set.maker)).log"
    Write-Host "[all] writing fixtures with $($set.maker) ($($absent -join ', ') missing)" -ForegroundColor Cyan
    cmd /c "python scripts\$($set.maker) > `"$makerLog`" 2>&1"
    $absent = @($wanted | Where-Object { -not (Test-Path (Join-Path $fixtureDir $_)) })
    if ($absent.Count -gt 0) { throw "still missing in $fixtureDir after $($set.maker): $($absent -join ', ') (see $makerLog)" }
}

# One background job on one lane: a .cmd carries the lane in its environment, and
# cmd sends each command's output to a file the way the serial loop always did.
# Hidden, and never with Start-Process redirection (fleet_probe trap 2).
function Start-LaneJob($lane, $name, [string[]]$commands) {
    $file = Join-Path $runDir "$name.cmd"
    $set = if ($lane -eq 0) { 'set FLEET_LANE=' } else { "set FLEET_LANE=$lane" }
    $body = @('@echo off', $set, "cd /d `"$repo`"") + $commands + @('exit /b %ERRORLEVEL%')
    [System.IO.File]::WriteAllLines($file, [string[]]$body, (New-Object System.Text.UTF8Encoding($false)))
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', "`"$file`"") -WorkingDirectory $repo -WindowStyle Hidden -PassThru
    # ExitCode reads back only on a process whose handle was taken while it ran.
    $null = $proc.Handle
    return $proc
}

# Stops one lane's instances and nothing else's.
function Stop-Lane($lane) {
    $set = if ($lane -eq 0) { 'set FLEET_LANE=' } else { "set FLEET_LANE=$lane" }
    cmd /c "$set& powershell -NoProfile -File scripts\fleet.ps1 -Stop > nul 2>&1"
}

# A job and every process it started, by PID (never by image name).
function Stop-ProcessTree($rootId) {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
    $doomed = @($rootId)
    for ($k = 0; $k -lt $doomed.Count; $k++) {
        $doomed += @($all | Where-Object { $_.ParentProcessId -eq $doomed[$k] } | ForEach-Object { $_.ProcessId })
    }
    foreach ($id in $doomed) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

function Get-CpuLoad {
    return [int](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
}

# Room for one more item: the CPU load averaged over three samples, and free memory.
function Get-Headroom {
    $samples = @()
    foreach ($k in 1..3) {
        $samples += Get-CpuLoad
        if ($k -lt 3) { Start-Sleep -Milliseconds 700 }
    }
    $freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    return [pscustomobject]@{ Cpu = [int](($samples | Measure-Object -Average).Average); FreeGB = [math]::Round($freeGB, 1) }
}

$scriptStarted = Get-Date
$buildMin = 0.0
$stageMin = 0.0
$onboardMin = 0.0
if (-not $SkipBuild) {
    Write-Host '[all] building once for every item' -ForegroundColor Cyan
    cmd /c "powershell -NoProfile -File scripts\fleet.ps1 -Build -Peers $($stagePeers -join ',') > `"$allOut\build.log`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "build failed, see $allOut\build.log" }
    $buildMin = [math]::Round(((Get-Date) - $scriptStarted).TotalMinutes, 1)
}
$phaseStarted = Get-Date

# Lanes 1 and 2 are copies of lane 0's staged peers, so whatever staging put
# there runs in every lane; the copies are proven by hash, never assumed.
if ($MaxParallel -gt 1) {
    foreach ($n in @($laneIds | Where-Object { $_ -gt 0 })) {
        $layout = Get-FleetLaneLayout $n
        Stop-Lane $n
        foreach ($peer in $stagePeers) {
            $src = Join-Path $script:FleetStageRoot $peer
            $dst = Join-Path $layout.Stage $peer
            if (-not (Test-Path (Join-Path $src 'hollow.exe'))) { throw "lane 0 has no staged $peer ($src): build first" }
            robocopy $src $dst /MIR /MT:16 /XF 'hollow_debug.log*' /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "staging lane $n peer $peer failed with robocopy $LASTEXITCODE" }
            $global:LASTEXITCODE = 0
            foreach ($rel in @('hollow_core.dll', 'data\flutter_assets\kernel_blob.bin')) {
                $want = (Get-FileHash (Join-Path $src $rel) -Algorithm SHA256).Hash
                $got = (Get-FileHash (Join-Path $dst $rel) -Algorithm SHA256).Hash
                if ($want -ne $got) { throw "lane $n peer $peer has a different $rel than lane 0" }
            }
        }
        $size = (Get-ChildItem $layout.Stage -Recurse -File | Measure-Object Length -Sum).Sum
        Write-Host ("[all] lane {0} staged from lane 0 and hash-checked ({1:N1} GB at {2})" -f $n, ($size / 1GB), $layout.Stage) -ForegroundColor Cyan
    }
}
$stageMin = [math]::Round(((Get-Date) - $phaseStarted).TotalMinutes, 1)
$phaseStarted = Get-Date

if ($needFixtures) {
    Write-Host "[all] onboarding fresh fixtures a,b,c in lane(s) $($laneIds -join ',')" -ForegroundColor Cyan
    $jobs = @{}
    foreach ($n in $laneIds) {
        $name = if ($n -eq 0) { 'onboard' } else { "onboard-lane$n" }
        $jobs[$n] = @{ Name = $name; Proc = (Start-LaneJob $n $name @(
            "powershell -NoProfile -File scripts\fleet.ps1 -Onboard -Fresh -Peers a,b,c > `"$allOut\$name.log`" 2>&1")) }
    }
    foreach ($n in $laneIds) {
        $jobs[$n].Proc.WaitForExit()
        if ($jobs[$n].Proc.ExitCode -ne 0) { throw "onboarding failed, see $allOut\$($jobs[$n].Name).log" }
    }
    $onboardMin = [math]::Round(((Get-Date) - $phaseStarted).TotalMinutes, 1)
} elseif ($KeepFixtures) {
    foreach ($n in @($laneIds | Where-Object { $_ -gt 0 })) {
        $fixtures = Join-Path (Get-FleetLaneLayout $n).Temp 'hollow_fleet\fixtures'
        foreach ($peer in @('a', 'b', 'c')) {
            if (-not (Test-Path (Join-Path $fixtures $peer))) { throw "-KeepFixtures, but lane $n has no fixture for $peer in $fixtures" }
        }
    }
}

# The words a refusing gate logs. Each hit on an honest journey is either explained
# or a bug.
$refusal = '\[HOLLOW-SECURITY\]|REJECTED|Dropped|Refused|Ignored'
# The relay turning a socket away (its new-connection budget, its per-address cap).
$relayRefusal = 'refused by the relay'

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

function Start-Item($lane) {
    $item = $lane.Unit.Items[$lane.Index]
    $log = Join-Path $allOut "$($item.name).log"
    if ($item.kind -eq 'scenario') {
        $cmd = "powershell -NoProfile -File scripts\fleet.ps1 -Scenario $($item.name) -Peers $($item.peers) $($item.args)"
    } else {
        $script = Join-Path 'scripts' "$($item.name).ps1"
        $params = (Get-Command (Join-Path $repo $script)).Parameters
        $extra = if ($params.ContainsKey('SkipBuild')) { ' -SkipBuild' } else { '' }
        $cmd = "powershell -NoProfile -File $script$extra"
    }
    $commands = @()
    if ($item.fresh) {
        # The relay replays an earlier item's friend requests to a restored fixture
        # for three days, so a journey that starts from no contacts gets new identities.
        $commands += "powershell -NoProfile -File scripts\fleet.ps1 -Onboard -Fresh -Peers $($item.peers) > `"$allOut\$($item.name)-onboard.log`" 2>&1"
    }
    if ($item.boot) {
        # A journey that drives an already-live fleet instead of booting its own.
        $commands += "powershell -NoProfile -File scripts\fleet.ps1 -Live -Peers $($item.boot) > `"$allOut\$($item.name)-boot.log`" 2>&1"
    }
    $commands += "$cmd > `"$log`" 2>&1"
    $lane.Item = $item
    $lane.Log = $log
    $lane.Cpu = Get-CpuLoad
    $lane.Started = Get-Date
    $lane.Proc = Start-LaneJob $lane.Id $item.name $commands
    Write-Host ("[all] {0} ... (lane {1}, cpu {2}%)" -f $item.name, $lane.Id, $lane.Cpu) -ForegroundColor Cyan
}

function Complete-Item($lane) {
    $item = $lane.Item
    $started = $lane.Started
    $layout = Get-FleetLaneLayout $lane.Id
    $code = $lane.Proc.ExitCode
    if ($lane.TimedOut) { $code = 124 }
    $text = if (Test-Path $lane.Log) { [System.IO.File]::ReadAllText($lane.Log) } else { '' }
    $gates = @([regex]::Matches($text, '(?m)^\s{2}(PASS|FAIL|WARN|SKIP|n/a)\s+(.+)$') |
        ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value.Trim())" })
    $failedGates = @($gates | Where-Object { $_ -like 'FAIL *' })
    if ($lane.TimedOut) { $failedGates += "FAIL killed after $ItemTimeoutMinutes min" }
    $status = if ($code -eq 0 -and $failedGates.Count -eq 0) { 'PASS' } else { 'FAIL' }

    # The log sits beside each staged exe and outlives runs, so only lines stamped
    # after this item started count; they are kept per peer before the lane's next
    # item launches anything into the same file. Only this lane's peers are read.
    $hits = @()
    $relayHits = 0
    $since = [DateTimeOffset]::new($started).ToUnixTimeSeconds()
    foreach ($peerDir in @(Get-ChildItem $layout.Stage -Directory -ErrorAction SilentlyContinue)) {
        $debugLog = Join-Path $peerDir.FullName 'hollow_debug.log'
        if (-not (Test-Path $debugLog) -or (Get-Item $debugLog).LastWriteTime -lt $started) { continue }
        try { $lines = Get-LogLinesSince $debugLog $since } catch {
            Write-Host "[all] could not read $debugLog : $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }
        if ($lines.Count -eq 0) { continue }
        [System.IO.File]::WriteAllLines((Join-Path $allOut "$($item.name)-$($peerDir.Name).log"), [string[]]$lines)
        $hits += @($lines | Where-Object { $_ -match $refusal } | ForEach-Object { "$($peerDir.Name): $_" })
        $relayHits += @($lines | Where-Object { $_.Contains($relayRefusal) }).Count
    }
    [System.IO.File]::WriteAllLines((Join-Path $allOut "$($item.name)-refusals.txt"), [string[]]$hits)

    # The next launch empties the lane's fleet_out\<peer>, so the item's named shots
    # are kept here (the per-step live-*.png frames are not).
    foreach ($outDir in @(Get-ChildItem $layout.Out -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[a-z]$' })) {
        $shots = @(Get-ChildItem $outDir.FullName -Filter '*.png' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $started -and $_.Name -notlike 'live-*' -and $_.Name -ne '00-boot.png' })
        if ($shots.Count -eq 0) { continue }
        $keep = Join-Path $allOut "$($item.name)-shots\$($outDir.Name)"
        New-Item -ItemType Directory -Path $keep -Force | Out-Null
        $shots | Copy-Item -Destination $keep -Force
    }

    $result = [pscustomobject]@{
        Name = $item.name; Status = $status; Exit = $code
        Minutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
        Gates = $gates.Count; Failed = $failedGates; Refusals = $hits.Count; RelayRefused = $relayHits
        Lane = $lane.Id; Cpu = $lane.Cpu; Started = $started
    }
    $colour = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ("[all] {0} {1} ({2} gates, {3} refusal lines, {4} min) lane {5}" -f $status, $item.name,
        $gates.Count, $hits.Count, $result.Minutes, $lane.Id) -ForegroundColor $colour
    return $result
}

$lanes = @(foreach ($n in $laneIds) {
    @{ Id = $n; Unit = $null; Index = 0; Item = $null; Log = $null; Proc = $null; Started = $null; Cpu = 0; TimedOut = $false }
})
$queue = New-Object System.Collections.ArrayList
foreach ($unit in $units) { [void]$queue.Add($unit) }
$results = @()
$runStarted = Get-Date
$nextLook = Get-Date
$heldFor = ''
# Guard holds for the summary: episodes (a held unit) and the time they cost.
$holdEpisodes = 0
$holdSince = $null
$heldSeconds = 0.0

while ($queue.Count -gt 0 -or @($lanes | Where-Object { $_.Unit }).Count -gt 0) {
    foreach ($lane in $lanes) {
        if (-not $lane.Unit) { continue }
        if (-not $lane.Proc.HasExited) {
            if (((Get-Date) - $lane.Started).TotalMinutes -lt $ItemTimeoutMinutes) { continue }
            Write-Host "[all] $($lane.Item.name) is still running after $ItemTimeoutMinutes min: killing it" -ForegroundColor Red
            Stop-ProcessTree $lane.Proc.Id
            $lane.TimedOut = $true
        }
        $results += Complete-Item $lane
        $lane.TimedOut = $false
        $lane.Index++
        if ($lane.Index -lt $lane.Unit.Items.Count) { Start-Item $lane; continue }
        # A failed journey leaves its fleet up for diagnosis; the lane's next unit
        # needs it down.
        Stop-Lane $lane.Id
        $lane.Unit = $null
    }

    if ($queue.Count -gt 0) {
        $next = $queue[0]
        $busy = @($lanes | Where-Object { $_.Unit })
        $free = @($lanes | Where-Object { -not $_.Unit })
        $go = $null
        if (@($busy | Where-Object { $_.Unit.Alone }).Count -gt 0) {
            # An alone unit keeps the machine to itself until it ends.
        } elseif ($next.Alone) {
            if ($busy.Count -eq 0) { $go = $lanes[0] }
        } elseif ($free.Count -gt 0) {
            if ($busy.Count -eq 0) {
                $go = $free[0]
            } elseif ((Get-Date) -ge $nextLook) {
                $room = Get-Headroom
                if ($room.Cpu -lt $CpuLimit -and $room.FreeGB -ge $MinFreeGB) {
                    $go = $free[0]
                } else {
                    $why = "cpu $($room.Cpu)% (limit $CpuLimit), $($room.FreeGB) GB free (need $MinFreeGB)"
                    if (-not $holdSince) { $holdSince = Get-Date; $holdEpisodes++ }
                    if ($heldFor -ne $next.Name) { Write-Host "[all] holding $($next.Name): $why" -ForegroundColor Yellow }
                    $heldFor = $next.Name
                    $nextLook = (Get-Date).AddSeconds(15)
                }
            }
        }
        if ($go) {
            if ($holdSince) { $heldSeconds += ((Get-Date) - $holdSince).TotalSeconds; $holdSince = $null }
            $queue.RemoveAt(0)
            $go.Unit = $next
            $go.Index = 0
            Start-Item $go
        }
    }
    Start-Sleep -Seconds 2
}

$wall = [math]::Round(((Get-Date) - $runStarted).TotalMinutes, 1)
$itemSum = [math]::Round(($results | Measure-Object -Property Minutes -Sum).Sum, 1)
$mode = if ($MaxParallel -eq 1) { 'serial' } else { "parallel, $MaxParallel lanes" }
$lines = @(
    "fleet_all $mode, $($results.Count) items, $wall min of wall time for $itemSum min of items",
    "total $([math]::Round(((Get-Date) - $scriptStarted).TotalMinutes, 1)) min = build $buildMin + lane staging $stageMin + onboarding $onboardMin + items $wall",
    "guard held a lane back $holdEpisodes time(s), $([math]::Round($heldSeconds / 60, 1)) min in all",
    '',
    '| item | result | gates | refusal lines | relay refused | minutes | lane | cpu % at start |',
    '|---|---|---|---|---|---|---|---|'
)
foreach ($r in $results) {
    $lines += "| $($r.Name) | $($r.Status) | $($r.Gates) | $($r.Refusals) | $($r.RelayRefused) | $($r.Minutes) | $($r.Lane) | $($r.Cpu) |"
    foreach ($f in $r.Failed) { $lines += "|  | $f |  |  |  |  |  |  |" }
}
[System.IO.File]::WriteAllLines((Join-Path $allOut 'summary.md'), [string[]]$lines)
Write-Host ''
$lines | ForEach-Object { Write-Host $_ }
if (@($results | Where-Object { $_.Status -ne 'PASS' }).Count -gt 0) { exit 1 }
