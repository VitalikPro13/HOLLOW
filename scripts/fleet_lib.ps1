# Shared by scripts\fleet.ps1 (runs a whole scenario), scripts\fleet_send.ps1
# (sends a command or two by hand) and the hand-written journey scripts
# (fleet_owner_offline.ps1, fleet_friend_*.ps1). They all talk to a live
# instance the same way - append to its inbox.jsonl, wait for the matching id in
# its outbox.jsonl - and keeping one implementation means a fix to the death
# detection, the variable expansion or the fresh-identity boot lands in all of
# them.
#
# Callers set $script:FleetRepo, $script:FleetOutRoot and $script:FleetStageRoot
# before using anything here.
#
# Windows PowerShell 5.1: no pwsh-only syntax. The same files run under pwsh 7
# on the Mac mini, where the backend is the iOS Simulator (see Test-SimBackend).

# pwsh 7.4+ turns a non-zero native exit code into a terminating error while
# $ErrorActionPreference is Stop. Half of simctl's normal answers are non-zero
# ("already booted", "not installed"), so the exit codes are read by hand.
$PSNativeCommandUseErrorActionPreference = $false

# Which machine this is. Windows PowerShell 5.1 has no $IsMacOS, so the variable
# is simply absent there and reads as false.
if ($IsMacOS) { $script:FleetBackend = 'sim' } else { $script:FleetBackend = 'windows' }

# The iOS Simulator backend: one simulator per peer (named hollow-<peer>), the
# probe target installed into each, the data directory and the probe output
# inside the app's own container, which is the only place an iOS app can
# write, reached from the scripts through a symlink per peer under
# build/fleet_out. Configuration goes in as Documents/probe.env, because
# Platform.environment is empty on iOS.
function Test-SimBackend { return $script:FleetBackend -eq 'sim' }

# The shell a child fleet run is started with.
function Get-PowerShellExe { if (Test-SimBackend) { return 'pwsh' } else { return 'powershell' } }

$script:SimUdids = @{}

# Every simulator this tooling created, whatever peers this run happens to use.
function Get-SimFleetUdids {
    $found = @()
    $json = & xcrun simctl list devices -j | ConvertFrom-Json
    foreach ($runtime in $json.devices.PSObject.Properties) {
        foreach ($device in @($runtime.Value)) {
            if ($device.name -like 'hollow-*' -and $device.isAvailable) { $found += $device.udid }
        }
    }
    return $found
}

# The simulator for a peer, created on first use from the newest installed iOS
# runtime. FLEET_SIM_DEVICE picks the device type (default iPhone 17 Pro).
function Get-SimUdid($peer, [switch]$Create) {
    if ($script:SimUdids.ContainsKey($peer)) { return $script:SimUdids[$peer] }
    $name = "hollow-$peer"
    $json = & xcrun simctl list devices -j | ConvertFrom-Json
    foreach ($runtime in $json.devices.PSObject.Properties) {
        foreach ($device in @($runtime.Value)) {
            if ($device.name -eq $name -and $device.isAvailable) {
                $script:SimUdids[$peer] = $device.udid
                return $device.udid
            }
        }
    }
    if (-not $Create) { return $null }
    $runtimes = @((& xcrun simctl list runtimes -j | ConvertFrom-Json).runtimes |
        Where-Object { $_.platform -eq 'iOS' -and $_.isAvailable } |
        Sort-Object { [version]$_.version } -Descending)
    if ($runtimes.Count -eq 0) { throw 'no iOS Simulator runtime is installed (Xcode > Settings > Components)' }
    $type = $env:FLEET_SIM_DEVICE
    if (-not $type) { $type = 'iPhone 17 Pro' }
    $udid = "$(& xcrun simctl create $name $type $runtimes[0].identifier)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $udid) { throw "could not create simulator $name ($type)" }
    Write-Host "[fleet] created simulator $name ($type, $($runtimes[0].name)) $udid" -ForegroundColor Cyan
    $script:SimUdids[$peer] = $udid
    return $udid
}

function Get-SimState($udid) {
    $json = & xcrun simctl list devices -j | ConvertFrom-Json
    foreach ($runtime in $json.devices.PSObject.Properties) {
        foreach ($device in @($runtime.Value)) {
            if ($device.udid -eq $udid) { return $device.state }
        }
    }
    return 'Unknown'
}

# Boots the device if it is not up and makes sure Simulator.app is showing it.
# The window is not decoration: a probe launched against a headless boot sat in
# its first pump forever (2026-09-05), because no frames are produced for a
# device nothing is displaying.
function Start-SimDevice($udid) {
    if ((Get-SimState $udid) -ne 'Booted') {
        & xcrun simctl boot $udid 2>&1 | Out-Null
        & xcrun simctl bootstatus $udid -b 2>&1 | Out-Null
    }
    & open -a Simulator 2>&1 | Out-Null
}

function Get-SimContainer($udid) {
    $path = "$(& xcrun simctl get_app_container $udid com.anonlisten.hollow data 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $path) {
        throw "the probe is not installed in simulator $udid. Run with -Build first."
    }
    return $path
}

function Get-SimDataDir($udid) {
    return Join-Path (Join-Path (Get-SimContainer $udid) 'Documents') 'hollow'
}

# The pid of the app inside a simulator, or $null when it is not running.
function Get-SimAppPid($udid) {
    $lines = & xcrun simctl spawn $udid launchctl list 2>$null
    foreach ($line in @($lines)) {
        if ("$line" -match '^\s*(\d+)\s+\S+\s+UIKitApplication:com\.anonlisten\.hollow') {
            return [int]$Matches[1]
        }
    }
    return $null
}

# Mirrors one directory into another, deletions included, skipping the lock
# file. robocopy on Windows, rsync on the Mac.
function Copy-Mirror($source, $destination) {
    if (Test-SimBackend) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        & rsync -a --delete --exclude 'hollow.lock' "$source/" "$destination/"
        if ($LASTEXITCODE -ne 0) { throw "rsync $source -> $destination failed with $LASTEXITCODE" }
        return
    }
    robocopy $source $destination /MIR /MT:8 /XF 'hollow.lock' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "mirroring $source -> $destination failed with $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}

# Values captured by a `capture` step, expanded into later steps as ${NAME}.
# This is what carries an invite link from the instance that generated it to the
# one that has to paste it.
if (-not $script:FleetVars) { $script:FleetVars = @{} }
$script:FleetConsumed = @{}

function Expand-FleetVars($value) {
    if ($value -is [string]) {
        return [regex]::Replace($value, '\$\{(\w+)\}', {
            param($m)
            $name = $m.Groups[1].Value
            if ($script:FleetVars.ContainsKey($name)) { return $script:FleetVars[$name] }
            # Unknown names are left alone: the RUNNER also substitutes, from its
            # own captures and from UI_PROBE_PEER, so ${PEER} has to survive
            # this pass intact.
            return $m.Value
        })
    }
    return $value
}

# A fleet instance is identified by where its exe lives, so nothing here can
# ever match a real Hollow the user happens to have open.
function Get-PeerProcess($peer) {
    if (Test-SimBackend) {
        $udid = Get-SimUdid $peer
        if (-not $udid) { return $null }
        $running = Get-SimAppPid $udid
        if (-not $running) { return $null }
        return [pscustomobject]@{ Id = $running; Udid = $udid }
    }
    $prefix = Join-Path $script:FleetStageRoot $peer
    return Get-Process -Name 'hollow' -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -and $_.Path.StartsWith($prefix, 'OrdinalIgnoreCase') }
            catch { $false }
        } | Select-Object -First 1
}

# What a dead instance left behind. errors.log is the probe's FlutterError
# handler, stdout.log is its debugPrint mirror (both written from inside the
# app, because redirecting the process's real stdout would leak this script's
# pipe handle into every instance), and hollow_debug.log is the app's own log
# next to the exe. All three are worth a look and none is reliably the one.
function Get-CrashTail($peer) {
    $lines = @()
    $outDir = Join-Path $script:FleetOutRoot $peer
    $sources = @(
        @{ name = 'errors.log'; path = (Join-Path $outDir 'errors.log') },
        @{ name = 'stdout'; path = (Join-Path $outDir 'stdout.log') }
    )
    if (Test-SimBackend) {
        $udid = Get-SimUdid $peer
        if ($udid) {
            try {
                $sources += @{ name = 'hollow_debug'; path = (Join-Path (Get-SimDataDir $udid) 'hollow_debug.log') }
            } catch { }
            # The simulator's own log keeps the app's last words when it died
            # before writing anything of its own.
            $simLog = @(& xcrun simctl spawn $udid log show --last 3m --style compact --predicate 'process == "Runner"' 2>$null |
                Where-Object { "$_" -match 'flutter:' } | Select-Object -Last 20)
            if ($simLog.Count -gt 0) {
                $lines += "--- simulator log ---"
                $lines += $simLog
            }
        }
    } else {
        $sources += @{ name = 'hollow_debug'; path = (Join-Path (Join-Path $script:FleetStageRoot $peer) 'hollow_debug.log') }
    }
    foreach ($item in $sources) {
        if (-not (Test-Path $item.path)) { continue }
        $tail = @(Get-Content $item.path -Tail 20 -ErrorAction SilentlyContinue) |
            Where-Object { $_.Trim() }
        if ($tail.Count -eq 0) { continue }
        $lines += "--- $($item.name) ---"
        $lines += $tail
    }
    if ($lines.Count -eq 0) { return "Nothing in the logs. Look in $(Join-Path $script:FleetOutRoot $peer)." }
    return ($lines -join "`n")
}

function Test-PeerLive($peer) {
    return (Test-Path (Join-Path (Join-Path $script:FleetOutRoot $peer) 'live-ready'))
}

# Which instances are up right now, by looking at what is running rather than
# at what this invocation happened to launch. That is what lets a second script
# attach to a fleet a first one left behind.
function Get-LivePeers {
    $root = $script:FleetOutRoot
    if (-not (Test-Path $root)) { return @() }
    # Not -Directory: on the simulator backend each entry is a symlink into an
    # app container, and a symlink only counts as a directory once followed.
    return @(Get-ChildItem $root -Force |
        Where-Object { Test-Path -LiteralPath $_.FullName -PathType Container } |
        ForEach-Object { $_.Name } |
        Where-Object { (Test-PeerLive $_) -and (Get-PeerProcess $_) })
}

# Sends one step and waits for its answer. Sequential on purpose: a batch that
# mixes peers only means anything if each step lands before the next one is
# sent, and "A sends, THEN B looks" is most of what a fleet scenario is.
function Send-FleetStep($peer, $step, $timeoutSeconds = 180) {
    $out = Join-Path $script:FleetOutRoot $peer
    $inbox = Join-Path $out 'inbox.jsonl'
    $outbox = Join-Path $out 'outbox.jsonl'
    if (-not (Test-Path $out)) {
        throw "peer '$peer' has no output directory ($out). Is it part of this fleet?"
    }

    $payload = @{}
    foreach ($property in $step.PSObject.Properties) {
        if ($property.Name -eq 'peer') { continue }
        $payload[$property.Name] = Expand-FleetVars $property.Value
    }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $payload['id'] = $id
    $line = ($payload | ConvertTo-Json -Depth 12 -Compress)
    # Not Add-Content: 5.1 writes a UTF-8 BOM into a new or empty file, and a
    # BOM in front of the first line breaks the JSON parse on the Dart side.
    [System.IO.File]::AppendAllText($inbox, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))

    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $outbox) {
            # @() because Get-Content returns a bare string for a one-line file,
            # and indexing a string gives a Char.
            $lines = @(Get-Content $outbox -Encoding UTF8)
            $from = $script:FleetConsumed[$peer]
            if (-not $from) { $from = 0 }
            for ($i = $from; $i -lt $lines.Count; $i++) {
                $raw = $lines[$i]
                if (-not $raw.Trim()) { continue }
                try { $answer = $raw | ConvertFrom-Json } catch { continue }
                if ($answer.id -ne $id) { continue }
                $script:FleetConsumed[$peer] = $i + 1
                if ($answer.captured) {
                    foreach ($property in $answer.captured.PSObject.Properties) {
                        $script:FleetVars[$property.Name] = $property.Value
                    }
                }
                return $answer
            }
        }
        # An instance that died never answers, and waiting out the full timeout
        # hides the reason behind three minutes of nothing. An unhandled app
        # exception ends the test body, which ends the process, so this is the
        # normal way a real bug turns up here.
        if (-not (Get-PeerProcess $peer)) {
            throw "peer $peer is no longer running.`n" + (Get-CrashTail $peer)
        }
        Start-Sleep -Milliseconds 200
    }
    throw "peer $peer never answered $($step.op) within ${timeoutSeconds}s. Its window is still up; look in $out."
}

# --------------------------------------------------------------------------
# Fresh identities for a journey that cannot share a mailbox with its own past
# --------------------------------------------------------------------------

# One fleet.ps1 invocation, as a child process. Not dot-sourced and not `&`-ed
# in: fleet.ps1 owns a param block, a $script: scope and an exit code, and a
# child keeps all three out of the caller's. Its instances are launched by
# Start-Process with no redirection, which means ShellExecute, which means they
# inherit no handle of ours - so capturing this output cannot wedge the way
# trap 2 wedges a redirected launch.
function Invoke-FleetScript($fleetArgs) {
    $fleet = Join-Path (Join-Path $script:FleetRepo 'scripts') 'fleet.ps1'
    if (-not (Test-Path $fleet)) { throw "fleet.ps1 not found at $fleet" }
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fleet) + $fleetArgs
    & (Get-PowerShellExe) @all | ForEach-Object { Write-Host "    | $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        throw "fleet.ps1 $($fleetArgs -join ' ') failed with $LASTEXITCODE"
    }
}

# Stop whatever is up, mint BRAND-NEW identities for these peers, and boot them.
#
# Why the friend journeys default to this: the relay buffers a friend request
# against inbox:{master} and replays it, TTL-only, for three days. The fixture
# identities are stable across runs, so a journey run on a reused identity is
# reading its own past - a wait_for satisfied by yesterday's request, a "fresh"
# peer that is saturated with them. New keys mean an empty mailbox, and that is
# the only clean start there is. Onboarding two peers costs about a minute.
function Start-FreshFleet($peers) {
    $peerList = @($peers)
    $peerArg = ($peerList -join ',')
    Write-Host "[fleet] minting fresh identities for: $peerArg" -ForegroundColor Cyan
    Invoke-FleetScript @('-Stop')
    Invoke-FleetScript @('-Onboard', '-Fresh', '-Peers', $peerArg)
    Invoke-FleetScript @('-Live', '-Peers', $peerArg)

    # The out directories were recreated by the boot, so nothing this process
    # read before is still there to skip past.
    foreach ($peer in $peerList) { $script:FleetConsumed[$peer] = 0 }

    # Print the identity each peer came back with. It is the proof that this run
    # is not talking to the last one's mailbox, and it costs one step per peer.
    foreach ($peer in $peerList) {
        $ready = Send-FleetStep $peer ([pscustomobject]@{
            op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000
        }) 180
        if (-not $ready.ok) { throw "$peer onboarded but never reached Connected: $($ready.message)" }
        $name = 'FRESH_' + $peer.ToUpper()
        $answer = Send-FleetStep $peer ([pscustomobject]@{
            op = 'capture'; from = 'provider'; key = 'peerId'; as = $name
        }) 120
        if (-not $answer.ok) { throw "could not read $peer's fresh identity: $($answer.message)" }
        Write-Host "[fleet] $peer fresh identity: $($script:FleetVars[$name])" -ForegroundColor Green
    }
}

function Write-FleetAnswer($peer, $answer, $indent = '       ') {
    $mark = if ($answer.ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($answer.ok) { 'DarkGray' } else { 'Red' }
    $parts = $answer.message -split "`n"
    Write-Host ("$indent$mark $($parts[0])") -ForegroundColor $colour
    # `look` and every failure put the useful part on the following lines.
    if ($parts.Count -gt 1) {
        $rest = if ($answer.ok) { $parts[1..($parts.Count - 1)] }
                else { $parts[1..([Math]::Min($parts.Count - 1, 8))] }
        Write-Host (($rest | ForEach-Object { "$indent$_" }) -join "`n") -ForegroundColor $(if ($answer.ok) { 'Gray' } else { 'DarkRed' })
    }
    if ($answer.overlays -and $answer.overlays.menuRows) {
        Write-Host ("${indent}menu: " + ($answer.overlays.menuRows -join ' | ')) -ForegroundColor DarkCyan
    }
    if ($answer.captured) {
        foreach ($property in $answer.captured.PSObject.Properties) {
            Write-Host ("$indent$($property.Name) = $($property.Value)") -ForegroundColor DarkCyan
        }
    }
}
