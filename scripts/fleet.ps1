# Runs SEVERAL real Hollow instances on this machine and drives all of them
# from one scenario, so peer-to-peer behaviour can be tested by watching it
# happen instead of by a human reproducing it and describing it.
#
#   powershell -File scripts\fleet.ps1 -Build            # build + stage the copies
#   powershell -File scripts\fleet.ps1 -Onboard          # make the fixture identities
#   powershell -File scripts\fleet.ps1 -Onboard -Fresh   # ... from BRAND-NEW keys
#   powershell -File scripts\fleet.ps1 -Onboard -Relay my.relay.example  # ... on a self-hosted relay
#   powershell -File scripts\fleet.ps1 -Live             # boot and leave them up
#   powershell -File scripts\fleet.ps1 -Scenario dm_hello -Attach   # reuse them
#   powershell -File scripts\fleet.ps1 -Stop
#   powershell -File scripts\fleet_send.ps1 -Command '[{"peer":"a","op":"look"}]'
#
# The fast loop is: `-Live` ONCE, then `-Attach` for every scenario run and
# fleet_send.ps1 for everything else. Booting costs ~13s and restores the
# fixtures, which throws away whatever state you were looking at; attaching
# costs nothing and keeps it.
#
# ## Why this is not just ui_probe.ps1 twice
#
# `flutter drive` builds into build\windows, so two concurrent drives race on
# one directory and one of them loses. Instead the probe target is built ONCE
# as a normal exe (`flutter build windows -t integration_test\ui_probe_test.dart`)
# and COPIED per instance. Two copies in two folders coexist because the native
# single-instance forwarder (app_links SendAppLinkToInstance) matches on the
# EXE PATH: different folder, no match, the second one boots normally. Same-
# folder relaunches still forward, so deep links keep working as they do today.
#
# Copying also kills the stale-cargo-DLL trap: FRB resolves its ioDirectory
# relative to the CWD, and only `flutter drive` has a CWD at the repo root.
# A copy launched from its own folder loads its own bundled DLL, like an
# install does.
#
# ## What this must not become
#
# A second multi-node harness. Two real apps plus the real relay is half a
# minute per journey and inherently timing-sensitive; it earns its keep on a
# small number of high-value journeys through the UI seam. Convergence, MLS
# epochs, revocation and anything needing five or more nodes belong in the Rust
# harness (`cargo test --lib test_harness`), where a run is seconds and
# deterministic.
#
# ## SAFETY, and it is not optional
#
# These are REAL identities on the REAL relay writing REAL CRDT ops. A fleet
# peer that joins one of your servers pollutes your data and replicates it to
# your phone. Every scenario creates its own server and deletes it again in
# `cleanup`, which runs even when the run fails.
#
# Windows PowerShell 5.1 is what is installed here, so no pwsh-only syntax.
#
# ## The iOS Simulator backend (pwsh on the Mac mini)
#
# The same script, run with pwsh on macOS, drives iOS Simulators instead of
# exe copies: one simulator per peer named hollow-<peer>, the probe target
# (`flutter build ios --simulator -t integration_test/ui_probe_test.dart`)
# installed into each, and the SAME scenario files, send script and op
# vocabulary. What differs is only where things live: an iOS app can write
# nowhere but its own container, so the data directory and the probe output
# are inside it and build/fleet_out/<peer> is a symlink there; and
# Platform.environment is empty on iOS, so the configuration goes in as
# Documents/probe.env instead of environment variables. Simulator.app must be
# showing the devices (the script opens it): a headless simulator produces no
# frames and the probe's first pump never returns.
#
#   pwsh scripts/fleet.ps1 -Build -Peers a,b     # build once, install into both simulators
#   pwsh scripts/fleet.ps1 -Onboard -Peers a,b   # mobile welcome flow, stamp the fixtures
#   pwsh scripts/fleet.ps1 -Live -Peers a,b
#   pwsh scripts/fleet_send.ps1 -Command '[{"peer":"a","op":"look"}]'
#
# ## The Linux backend (pwsh on a Linux desktop)
#
# Bundle copies under build/fleet/<peer> (`flutter build linux --debug -t
# integration_test/ui_probe_test.dart`), fixtures and run directories under
# ~/hollow_fleet, the same scenario files and send script. Each instance runs
# on its own session bus (dbus-run-session): the runner registers a fixed
# GApplication id for hollow:// links, so on the shared bus a second copy
# would forward its command line to the first and exit. Driven over SSH, the
# graphical session's DISPLAY and XAUTHORITY must be exported first. stderr
# is kept per instance (native-stderr.log): a native death on Linux is
# written there and nowhere else.
#
#   DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority pwsh scripts/fleet.ps1 -Build -Peers a,b
#   pwsh scripts/fleet.ps1 -Onboard -Fresh -Peers a,b
#   pwsh scripts/fleet.ps1 -Live -Peers a,b
#
# ## The Android emulator backend (FLEET_BACKEND=android, pwsh on macOS/Linux)
#
# One emulator per peer (AVD hollow-<peer>, created on first use, serial
# emulator-5554 for a, 5556 for b, ...), the probe APK installed into each, the
# same scenario files and send script. The app's files live inside the
# emulator, so everything crosses through `adb run-as` (fleet_lib.ps1), and
# build/fleet_out/<peer> is a copy refreshed after each run and send. Fixtures
# live in ~/hollow_fleet/fixtures-android, apart from the simulator ones. The
# emulators stay up after -Stop; booting is the slow part.
#
#   FLEET_BACKEND=android pwsh scripts/fleet.ps1 -Build -Peers a,b
#   FLEET_BACKEND=android pwsh scripts/fleet.ps1 -Onboard -Fresh -Peers a,b
#   FLEET_BACKEND=android pwsh scripts/fleet_send.ps1 -Command '[{"peer":"a","op":"look"}]'
#
# ## A mixed phone fleet (FLEET_ANDROID_PEERS, pwsh on macOS)
#
# The named peers run on Android emulators, every other peer in an iOS
# Simulator, so one scenario drives an iPhone and an Android phone together.
# Peer letters stay unique across both: build/fleet_out/<peer> is shared.
#
#   FLEET_ANDROID_PEERS=a,b pwsh scripts/fleet.ps1 -Build -Peers a,b,c,d   # builds the app and the APK
#   FLEET_ANDROID_PEERS=a,b pwsh scripts/fleet.ps1 -Onboard -Fresh -Peers a,b,c,d
#   FLEET_ANDROID_PEERS=a,b pwsh scripts/fleet_send.ps1 -Command '[{"peer":"c","op":"look"}]'

param(
    # A file in scripts\probe_scenarios\fleet (without .json).
    [string]$Scenario = '',
    # An explicit path to a scenario file, anywhere.
    [string]$ScenarioFile = '',
    # Which instances to boot. The scenario's own peer list wins over this.
    [string]$Peers = '',
    # Build the probe target and re-stage the per-instance copies.
    [switch]$Build,
    # Drive the welcome flow on each instance and stamp the result as the
    # fixture data directory. Run this when the fixtures need rebuilding.
    [switch]$Onboard,
    # With -Onboard: throw the OLD fixture away first, so the peers come back
    # with brand-new keys (new mnemonic, new master id, and therefore an EMPTY
    # relay mailbox). The friend journeys need that: the relay buffers a friend
    # request against inbox:{master} for three days, so a stable identity keeps
    # replaying earlier runs' requests into later ones. Meaningless on its own.
    [switch]$Fresh,
    # With -Onboard: point every peer of this run at a self-hosted relay by
    # typing it into the welcome dialog's Advanced field. A relay is chosen
    # before an identity exists and is stamped into the fixture with it, so
    # this is the only moment a fleet peer can be pointed anywhere else. Peers
    # that need DIFFERENT relays take one -Onboard call each.
    [string]$Relay = '',
    # Boot the fleet and leave it listening, for driving by hand.
    [switch]$Live,
    # Use the instances that are ALREADY running instead of booting: no reboot,
    # no fixture restore, and whatever state you were looking at survives.
    [switch]$Attach,
    # Stop the fleet and exit.
    [switch]$Stop,
    # Leave the instances running when the scenario finishes.
    [switch]$Keep,
    # Keep whatever the last run left in the data directories instead of
    # restoring the fixtures. Useful for continuing an investigation.
    [switch]$ReuseData,
    # Arrange the windows side by side so a human can watch.
    [bool]$Tile = $true,
    [int]$IdleMinutes = 40,
    [int]$BootTimeoutSeconds = 240,
    [int]$StepTimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet'
$script:FleetOutRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet_out'
# `${RUN}` is unique per run, and scenarios should put it in every message they
# send. The relay's availability cache holds undelivered traffic for three days
# and the fixture identities are STABLE across runs, so a message from an
# earlier run can be delivered into a later one: a `wait_for` on a fixed string
# would then pass before the send it was supposed to be waiting for. A run tag
# in the text makes that impossible.
# `${REPO}` is the repo root with forward slashes, for fixture paths in scenarios.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss'); REPO = ($repoRoot.Replace('\', '/')) }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$stageRoot   = $script:FleetStageRoot
$outRoot     = $script:FleetOutRoot
# A phone peer has no run directory: its data lives inside its simulator
# container or emulator (Get-PeerDataDir, Reset-PeerData).
$runRoot = $null
if (Test-LinuxBackend) { $runRoot = Join-Path (Get-LinuxFleetHome) 'run' }
elseif (Test-WindowsBackend) { $runRoot = Join-Path $env:TEMP 'hollow_fleet\run' }

# What -Build leaves for a peer to be staged from.
function Get-BuildOutput($peer) {
    if (Test-SimBackend $peer) { return Join-Path (Join-Path (Join-Path $repoRoot 'build') 'ios') (Join-Path 'iphonesimulator' 'Runner.app') }
    if (Test-AndroidBackend $peer) { return Join-Path $repoRoot 'build/app/outputs/flutter-apk/app-debug.apk' }
    if (Test-LinuxBackend) { return Join-Path $repoRoot 'build/linux/x64/debug/bundle' }
    return Join-Path $repoRoot 'build\windows\x64\runner\Debug'
}

# Fixtures hold real Ed25519 keys, so they live outside the repo where no
# `git add -A` can reach them.

function Write-Step($message, $colour = 'Cyan') {
    Write-Host "[fleet] $message" -ForegroundColor $colour
}

# Only ever kills instances launched from build\fleet. Vitalik's real Hollow
# may well be open while a fleet run happens - it has a different exe path and
# a different data directory, so it does not conflict with anything here, and
# killing it would be a rude surprise in the middle of a conversation.
function Stop-Fleet {
    $sim = Test-SimBackend
    $android = (Test-AndroidBackend) -or (Test-MixedFleet)
    if ($sim -or $android) {
        $stopped = 0
        if ($sim) {
            foreach ($udid in Get-SimFleetUdids) {
                if (Get-SimAppPid $udid) {
                    & xcrun simctl terminate $udid com.anonlisten.hollow 2>&1 | Out-Null
                    $stopped++
                }
            }
        }
        if ($android) {
            foreach ($peer in Get-AndroidFleetPeers) {
                if (Get-AndroidAppPid $peer) {
                    Invoke-Adb $peer 'shell' "am force-stop $($script:AndroidPackage)" 2>&1 | Out-Null
                    $stopped++
                }
            }
        }
        if ($stopped -gt 0) {
            Write-Step "stopping $stopped fleet instance(s)" 'Yellow'
            if ($sim) { Start-Sleep -Milliseconds 1200 }
        }
        return
    }
    $running = Get-Process -Name 'hollow' -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -and $_.Path.StartsWith($stageRoot, 'OrdinalIgnoreCase') }
            catch { $false }
        }
    if ($running) {
        Write-Step "stopping $(@($running).Count) fleet instance(s)" 'Yellow'
        $running | Stop-Process -Force
        # Waited out, not a flat sleep: a killed instance can take seconds to go,
        # and until it has, messages.db is open and a data-dir reset throws.
        $deadline = (Get-Date).AddSeconds(30)
        foreach ($proc in @($running)) {
            $left = [int]($deadline - (Get-Date)).TotalMilliseconds
            if ($left -gt 0) { try { [void]$proc.WaitForExit($left) } catch { } }
        }
        # The lock file and the SQLCipher WAL are released on exit; give the
        # handles time to drop before anything copies the directory.
        Start-Sleep -Milliseconds 1200
    }
}

if ($Stop) {
    Stop-Fleet
    Write-Step 'fleet stopped'
    exit 0
}

# -Fresh is about which identity onboarding mints, so on its own it would
# silently do nothing while the caller believed it had new keys.
if ($Fresh -and -not $Onboard) {
    throw '-Fresh only means something with -Onboard. Use: -Onboard -Fresh -Peers a,b'
}

# Same reason: the welcome dialog only exists while there is no identity yet,
# so -Relay without -Onboard would silently leave every peer where it was.
if ($Relay -and -not $Onboard) {
    throw '-Relay only means something with -Onboard. Use: -Onboard -Fresh -Peers a -Relay my.relay.example'
}

# --------------------------------------------------------------------------
# Scenario
# --------------------------------------------------------------------------

$scenarioSteps = @()
$scenarioCleanup = @()
$scenarioPeers = @()

if ($ScenarioFile -or $Scenario) {
    if ($ScenarioFile) {
        if (-not (Test-Path $ScenarioFile)) { throw "scenario file not found: $ScenarioFile" }
        $path = (Resolve-Path $ScenarioFile).Path
    } else {
        $dir = Join-Path (Join-Path (Join-Path $repoRoot 'scripts') 'probe_scenarios') 'fleet'
        $path = Join-Path $dir "$Scenario.json"
        if (-not (Test-Path $path)) {
            $known = ''
            if (Test-Path $dir) {
                $known = (Get-ChildItem $dir -Filter *.json | ForEach-Object { $_.BaseName }) -join ', '
            }
            throw "unknown fleet scenario '$Scenario'. Known: $known"
        }
    }
    $parsed = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        $scenarioSteps = $parsed
    } else {
        $scenarioSteps = @($parsed.steps)
        if ($parsed.cleanup) { $scenarioCleanup = @($parsed.cleanup) }
        if ($parsed.peers) { $scenarioPeers = @($parsed.peers) }
    }
    Write-Step "scenario $path ($($scenarioSteps.Count) steps, $($scenarioCleanup.Count) cleanup)"
}

# Peers: what is already up when attaching, else the scenario's own list, else
# -Peers, else what the steps mention, else a and b.
$peerList = @()
if ($Attach) {
    $peerList = Get-LivePeers
    if ($peerList.Count -eq 0) {
        throw "-Attach found no running instances. Start some with: powershell -File scripts\fleet.ps1 -Live"
    }
} elseif ($Peers) {
    $peerList = $Peers -split '[,\s]+' | Where-Object { $_ }
} elseif ($scenarioPeers.Count -gt 0) {
    $peerList = $scenarioPeers
} elseif ($scenarioSteps.Count -gt 0) {
    $peerList = $scenarioSteps | ForEach-Object { $_.peer } |
        Where-Object { $_ -and $_ -ne 'all' } | Select-Object -Unique
}
if ($peerList.Count -eq 0) { $peerList = @('a', 'b') }
$peerList = @($peerList | Sort-Object)
$attachNote = ''
if ($Attach) { $attachNote = ' (attached)' }
Write-Step "peers: $($peerList -join ', ')$attachNote"

# --------------------------------------------------------------------------
# Build and stage
# --------------------------------------------------------------------------

function Invoke-Build {
    # A mixed fleet builds only what its peers run on.
    $sim = @($peerList | Where-Object { Test-SimBackend $_ }).Count -gt 0
    $android = @($peerList | Where-Object { Test-AndroidBackend $_ }).Count -gt 0
    if ($sim) {
        Write-Step 'building the probe target for the iOS Simulator'
        & flutter build ios --simulator --debug -t integration_test/ui_probe_test.dart
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed with $LASTEXITCODE" }
    }
    if ($android) {
        # Only the emulators' own ABI: every extra one is another Rust build.
        $platform = if ("$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" -eq 'Arm64') { 'android-arm64' } else { 'android-x64' }
        Write-Step "building the probe target as an APK ($platform)"
        & flutter build apk --debug --target-platform $platform -t integration_test/ui_probe_test.dart
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed with $LASTEXITCODE" }
    }
    if ($sim -or $android) { return }
    if (Test-LinuxBackend) {
        Write-Step 'building the probe target as a Linux bundle'
        & flutter build linux --debug -t integration_test/ui_probe_test.dart
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed with $LASTEXITCODE" }
        return
    }
    Write-Step 'building the probe target as a standalone exe'
    & flutter build windows --debug -t integration_test/ui_probe_test.dart
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed with $LASTEXITCODE" }
}

# Whether a peer has a copy of the probe to launch: an exe folder here, an
# installed app in its simulator there.
function Test-PeerStaged($peer) {
    if (Test-SimBackend $peer) {
        $udid = Get-SimUdid $peer
        if (-not $udid) { return $false }
        Start-SimDevice $udid
        $null = & xcrun simctl get_app_container $udid com.anonlisten.hollow 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    if (Test-AndroidBackend $peer) {
        Start-AndroidDevice $peer
        return ("$(Invoke-Adb $peer 'shell' "pm path $($script:AndroidPackage)" 2>$null)" -match 'package:')
    }
    $exe = if (Test-LinuxBackend) { 'hollow' } else { 'hollow.exe' }
    return (Test-Path (Join-Path (Join-Path $stageRoot $peer) $exe))
}

function Stage-Peer($peer) {
    $buildOutput = Get-BuildOutput $peer
    if (-not (Test-Path $buildOutput)) {
        throw "no build output at $buildOutput. Run with -Build first."
    }
    if (Test-SimBackend $peer) {
        $udid = Get-SimUdid $peer -Create
        Start-SimDevice $udid
        Write-Step "installing into simulator hollow-$peer"
        & xcrun simctl install $udid $buildOutput 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "simctl install for $peer failed with $LASTEXITCODE" }
        return
    }
    if (Test-AndroidBackend $peer) {
        Start-AndroidDevice $peer
        Write-Step "installing into emulator hollow-$peer"
        # -r keeps the app's data, -g grants every runtime permission up front
        # so no system prompt (notifications, microphone) ever covers the app.
        $installed = "$(Invoke-Adb $peer 'install' '-r' '-t' '-g' $buildOutput 2>&1)"
        if ($LASTEXITCODE -ne 0 -or $installed -notmatch 'Success') { throw "adb install for $peer failed: $installed" }
        return
    }
    $dest = Join-Path $stageRoot $peer
    Write-Step "staging $peer"
    if (Test-LinuxBackend) {
        Copy-Mirror $buildOutput $dest
        return
    }
    # /MIR so a rebuild's deletions propagate, and it only copies what actually
    # changed - a restage after an incremental build is under a second. The
    # debug symbols and import libraries are ~25 MB per copy and nothing loads
    # them at runtime.
    robocopy $buildOutput $dest /MIR /MT:16 /XF *.pdb *.lib *.exp /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy for $peer failed with $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}

if ($Build) {
    Stop-Fleet
    Invoke-Build
    foreach ($peer in $peerList) { Stage-Peer $peer }
}

if (-not $Attach) {
    foreach ($peer in $peerList) {
        if (-not (Test-PeerStaged $peer)) {
            Write-Step "$peer is not staged yet" 'Yellow'
            Stage-Peer $peer
        }
    }
}

# --------------------------------------------------------------------------
# Data directories
# --------------------------------------------------------------------------

# Where a peer's app keeps its identity and database while it runs.
function Get-PeerDataDir($peer) {
    if (Test-SimBackend $peer) { return Get-SimDataDir (Get-SimUdid $peer) }
    return Join-Path $runRoot $peer
}

function Reset-PeerData($peer) {
    $fixture = Join-Path (Get-FixtureRoot $peer) $peer
    if (Test-AndroidBackend $peer) {
        $data = "$($script:AndroidDocs)/hollow"
        if ($Onboard -and $Fresh -and (Test-Path $fixture)) {
            Remove-Item $fixture -Recurse -Force
            Remove-Item "$fixture.phrase" -Force -ErrorAction SilentlyContinue
            Write-Step "$peer discarded its old fixture identity" 'Yellow'
        }
        if ($ReuseData -and -not $Onboard) {
            Write-Step "$peer reusing its last data directory"
        } elseif ($Onboard -or -not (Test-Path $fixture)) {
            Invoke-AppShell $peer "rm -rf $data && mkdir -p $data" | Out-Null
            if ($Onboard) { Write-Step "$peer starting from an empty data directory" }
            else { Write-Step "$peer has no fixture identity yet - it will onboard from scratch. Run -Onboard to stamp one." 'Yellow' }
        } else {
            Push-AppDir $peer $fixture $data
        }
        return
    }
    $run = Get-PeerDataDir $peer
    if ($Onboard) {
        # Onboarding walks the WELCOME flow, which only exists when there is no
        # identity yet. Restoring a fixture here would leave the app in the
        # shell and every onboarding step would fail looking for a screen that
        # is already behind it. So -Onboard ALREADY mints new keys every time:
        # empty data dir, welcome flow, new mnemonic, new master id.
        #
        # -Fresh drops the old fixture as well. Belt and braces (Save-Fixture
        # mirrors, so the stamp would replace it anyway), and it is what makes
        # "this run wanted a new identity" greppable rather than implied.
        if ($Fresh -and (Test-Path $fixture)) {
            Remove-Item $fixture -Recurse -Force
            Remove-Item "$fixture.phrase" -Force -ErrorAction SilentlyContinue
            Write-Step "$peer discarded its old fixture identity" 'Yellow'
        }
        if (Test-Path $run) { Remove-Item $run -Recurse -Force }
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        Write-Step "$peer starting from an empty data directory"
        return
    }
    if ($ReuseData -and (Test-Path $run)) {
        Write-Step "$peer reusing its last data directory"
        return
    }
    if (Test-Path $run) { Remove-Item $run -Recurse -Force }
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    if (Test-Path $fixture) {
        Copy-Mirror $fixture $run
    } else {
        Write-Step "$peer has no fixture identity yet - it will onboard from scratch. Run -Onboard to stamp one." 'Yellow'
    }
}

function Save-Fixture($peer) {
    $fixture = Join-Path (Get-FixtureRoot $peer) $peer
    # The WAL has to be folded in before a copy, and the app does that on exit,
    # so this only ever runs after the instances are stopped.
    if (Test-AndroidBackend $peer) {
        Pull-AppDir $peer "$($script:AndroidDocs)/hollow" $fixture
    } else {
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        Copy-Mirror (Get-PeerDataDir $peer) $fixture
    }
    # A throwaway identity's phrase, next to the fixture and never inside a data
    # directory, read back with Get-FixturePhrase.
    if ($script:phrases[$peer]) {
        [System.IO.File]::WriteAllText("$fixture.phrase", $script:phrases[$peer])
    }
    Write-Step "stamped the $peer fixture -> $fixture" 'Green'
}

# --------------------------------------------------------------------------
# Launch
# --------------------------------------------------------------------------

$script:processes = @{}
$script:onboardOk = $false
$script:phrases = @{}

function Start-Peer($peer) {
    $out = Join-Path $outRoot $peer
    if (Test-SimBackend $peer) {
        $udid = Get-SimUdid $peer
        Start-SimDevice $udid
        $documents = Join-Path (Get-SimContainer $udid) 'Documents'
        $data = Join-Path $documents 'hollow'
        $probeOut = Join-Path $documents 'probe_out'
        New-Item -ItemType Directory -Path $data -Force | Out-Null
        if (Test-Path $probeOut) { Remove-Item $probeOut -Recurse -Force }
        New-Item -ItemType Directory -Path $probeOut -Force | Out-Null
        # build/fleet_out/<peer> points into the container, so every reader of
        # an out directory keeps its usual path. rm, not Remove-Item: a symlink
        # to a directory must go as a link, never as the directory behind it.
        New-Item -ItemType Directory -Path $outRoot -Force | Out-Null
        & rm -rf $out
        & ln -sfn $probeOut $out
        # The configuration the probe reads in place of the environment.
        $config = @(
            "UI_PROBE_OUT=$probeOut",
            'UI_PROBE_MODE=live',
            "UI_PROBE_PEER=$peer",
            "UI_PROBE_IDLE_MINUTES=$IdleMinutes",
            "HOLLOW_DATA_DIR=$data"
        )
        [System.IO.File]::WriteAllText((Join-Path $documents 'probe.env'),
            (($config -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $launched = "$(& xcrun simctl launch --terminate-running-process $udid com.anonlisten.hollow 2>&1)"
        if ($LASTEXITCODE -ne 0) { throw "simctl launch for $peer failed: $launched" }
        $launchedPid = 0
        if ($launched -match ':\s*(\d+)\s*$') { $launchedPid = [int]$Matches[1] }
        $script:processes[$peer] = [pscustomobject]@{ Id = $launchedPid; Udid = $udid }
        Write-Step "launched $peer (pid $launchedPid, simulator hollow-$peer) data=$data"
        return
    }
    if (Test-AndroidBackend $peer) {
        Start-AndroidDevice $peer
        Invoke-Adb $peer 'shell' "am force-stop $($script:AndroidPackage)" 2>&1 | Out-Null
        $docs = $script:AndroidDocs
        Invoke-AppShell $peer "rm -rf $docs/probe_out && mkdir -p $docs/probe_out $docs/hollow" | Out-Null
        # A real directory here, where the simulator backend leaves a symlink:
        # rm, so a link goes as a link and never takes its target with it.
        New-Item -ItemType Directory -Path $outRoot -Force | Out-Null
        & rm -rf $out
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        $config = @(
            "UI_PROBE_OUT=$($script:AndroidDocsAbs)/probe_out",
            'UI_PROBE_MODE=live',
            "UI_PROBE_PEER=$peer",
            "UI_PROBE_IDLE_MINUTES=$IdleMinutes",
            "HOLLOW_DATA_DIR=$($script:AndroidDocsAbs)/hollow"
        )
        Set-AppFile $peer "$docs/probe.env" (($config -join "`n") + "`n")
        # A start right after a force-stop can be "delivered to top" of the
        # activity still being torn down, and then no process starts at all
        # (2026-10-06). -S stops the app as part of the start, the task is
        # cleared, and the start is repeated once if no process appears.
        $launchedPid = $null
        $launched = ''
        foreach ($attempt in 1..2) {
            $launched = "$(Invoke-Adb $peer 'shell' "am start -S -W --activity-clear-task -n $($script:AndroidPackage)/.MainActivity" 2>&1)"
            if ($launched -match 'Error') { throw "launching $peer failed: $launched" }
            $deadline = (Get-Date).AddSeconds(10)
            while (-not $launchedPid -and (Get-Date) -lt $deadline) {
                $launchedPid = Get-AndroidAppPid $peer
                if (-not $launchedPid) { Start-Sleep -Milliseconds 300 }
            }
            if ($launchedPid) { break }
        }
        if (-not $launchedPid) { throw "launching $peer started no process: $launched" }
        $script:processes[$peer] = [pscustomobject]@{ Id = $launchedPid; Serial = (Get-AndroidSerial $peer) }
        Write-Step "launched $peer (pid $launchedPid, emulator hollow-$peer $(Get-AndroidSerial $peer))"
        return
    }
    $dest = Join-Path $stageRoot $peer
    $data = Join-Path $runRoot $peer
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null

    # Start-Process has no -Environment on 5.1, so the child inherits ours.
    # Set them immediately before each launch, one peer at a time.
    $env:HOLLOW_DATA_DIR = $data
    $env:UI_PROBE_OUT = $out
    $env:UI_PROBE_MODE = 'live'
    $env:UI_PROBE_PEER = $peer
    $env:UI_PROBE_IDLE_MINUTES = "$IdleMinutes"
    $env:UI_PROBE_SCENARIO_FILE = ''
    $env:UI_PROBE_STEPS = ''

    if (Test-LinuxBackend) {
        if (-not $env:DISPLAY) {
            throw 'DISPLAY is not set. Export the graphical session DISPLAY and XAUTHORITY before launching the fleet (for example DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority).'
        }
        # Own session bus per instance (Test-LinuxBackend). stdout and stderr
        # go to FILES through a launcher script, never through a pipe held by
        # this process: a native death says its last words on stderr, and a
        # pipe whose reader has exited turns every later Rust log line into
        # EPIPE (which was a panic per line until lib.rs stopped using
        # eprintln!, 2026-09-09).
        # The launcher wraps dbus-run-session, not the other way round: the bus
        # daemon inherits stdio too, and a pipe it keeps open holds every
        # caller of this script until the fleet stops.
        $launcher = Join-Path $out 'launch.sh'
        $lines = @(
            '#!/bin/sh',
            ('exec dbus-run-session -- "{0}" >"{1}" 2>"{2}" </dev/null' -f (Join-Path $dest 'hollow'),
                (Join-Path $out 'native-stdout.log'), (Join-Path $out 'native-stderr.log'))
        )
        [System.IO.File]::WriteAllText($launcher, (($lines -join "`n") + "`n"))
        & chmod +x $launcher
        $proc = Start-Process -FilePath $launcher -WorkingDirectory $dest -PassThru
        $script:processes[$peer] = $proc
        Write-Step "launched $peer (pid $($proc.Id), own session bus) data=$data"
        return
    }

    # NO -RedirectStandardOutput/-RedirectStandardError here, however much
    # they look like the right way to capture a dead instance's last words.
    # They flip Start-Process into inherit-handles mode, so every launched
    # instance keeps a duplicate of THIS script's stdout pipe and
    # `fleet.ps1 -Live | anything` never returns even though the script
    # finished. Measured: 1s launching plain, 45s (the timeout) with
    # redirection. The probe writes its own stdout.log and errors.log from
    # inside instead, which is the same information without the handle.
    $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') `
        -WorkingDirectory $dest -PassThru
    $script:processes[$peer] = $proc
    Write-Step "launched $peer (pid $($proc.Id)) data=$data"
}

function Wait-Ready($peers) {
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    $ready = @{}
    while ((Get-Date) -lt $deadline -and $ready.Count -lt $peers.Count) {
        foreach ($peer in $peers) {
            if ($ready.ContainsKey($peer)) { continue }
            if (Test-PeerLive $peer) {
                $ready[$peer] = $true
                Write-Step "$peer is live" 'Green'
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $missing = $peers | Where-Object { -not $ready.ContainsKey($_) }
    if ($missing) {
        $detail = ($missing | ForEach-Object { "--- $_ ---`n" + (Get-CrashTail $_) }) -join "`n"
        throw "these instances never reached live-ready: $($missing -join ', ').`n$detail"
    }
}

# Windows land on top of each other otherwise, and the whole point is that a
# human can glance at the fleet and see what it is doing. Never narrower than
# 960 logical pixels: below 600 the app switches to the mobile shell, and a
# desktop scenario driving the mobile shell fails for a reason that looks like
# a bug.
function Set-FleetWindows($peers) {
    if (-not $Tile) { return }
    # Simulator.app lays its device windows out itself; on Linux the window
    # manager does, and the probe's screenshots are taken inside the app.
    if (-not (Test-WindowsBackend)) { return }
    if (-not ('HollowWin32.Native' -as [type])) {
        Add-Type -Namespace HollowWin32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool repaint);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
'@ | Out-Null
    }
    $screenW = [HollowWin32.Native]::GetSystemMetrics(0)
    $screenH = [HollowWin32.Native]::GetSystemMetrics(1)
    $columns = [Math]::Max(1, [Math]::Min($peers.Count, [Math]::Floor($screenW / 960)))
    $rows = [Math]::Ceiling($peers.Count / $columns)
    $width = [Math]::Max(960, [Math]::Floor($screenW / $columns))
    $height = [Math]::Max(600, [Math]::Floor($screenH / $rows) - 40)

    for ($i = 0; $i -lt $peers.Count; $i++) {
        $proc = $script:processes[$peers[$i]]
        if (-not $proc) { $proc = Get-PeerProcess $peers[$i] }
        if (-not $proc) { continue }
        try { $proc.Refresh() } catch { continue }
        $handle = $proc.MainWindowHandle
        if ($handle -eq [IntPtr]::Zero) { continue }
        $x = ($i % $columns) * $width
        $y = [Math]::Floor($i / $columns) * ($height + 20)
        [HollowWin32.Native]::MoveWindow($handle, $x, $y, $width, $height, $true) | Out-Null
    }
}

# --------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------

function Invoke-Steps($steps, $label, $alwaysSoft = $false) {
    $failures = 0
    $index = 0
    foreach ($step in $steps) {
        $index++
        $peer = $step.peer
        if (-not $peer) { $peer = $peerList[0] }
        $targets = if ($peer -eq 'all') { $peerList } else { @($peer) }
        foreach ($target in $targets) {
            if ($peerList -notcontains $target) {
                throw "step $index names peer '$target', which is not in the fleet ($($peerList -join ', '))"
            }
            $description = "$($step.op) $($step.target)$($step.name)"
            Write-Host ("  {0,-3} {1,-4} {2}" -f $index, $target, $description) -ForegroundColor Gray
            $answer = Send-FleetStep $target $step $StepTimeoutSeconds
            Write-FleetAnswer $target $answer
            if (-not $answer.ok) {
                $failures++
                if (-not $alwaysSoft -and -not $step.soft) {
                    Write-Step "$label stopped at step $index" 'Red'
                    return $failures
                }
            }
        }
    }
    return $failures
}

# --------------------------------------------------------------------------
# Onboarding
# --------------------------------------------------------------------------

# Fresh identities have to walk the welcome flow, and doing that on every run
# doubles the runtime and puts the flakiest UI in the app in front of every
# test. Walk it ONCE and keep the data directory as a fixture.
# The mobile shell's version of the same walk. Three things differ, each of
# which cost a run to find (2026-09-05): there is no `Connected` text anywhere,
# so the node coming up is read from the connection provider; the profile row
# in Settings is labelled by its subtitle, not "Profile"; and the Save sits in
# the Profile page's top bar, above the software keyboard. Back is a button,
# not Escape.
# The phrase is shown once and three of its words are typed back (design
# ID-1: Hollow keeps no copy). It is captured on the way, and kept beside the
# fixture, because a journey that recovers or joins with the phrase needs it.
$phraseCheckSteps = @(
    @{ op = 'capture'; from = 'phrase'; as = 'PHRASE' },
    @{ op = 'tap'; target = "text:I've written it down"; index = 0; frames = 40 },
    @{ op = 'wait_for'; target = 'text:Check your copy'; timeout_ms = 10000 },
    @{ op = 'answer_phrase'; value = '${PHRASE}' },
    @{ op = 'tap'; target = 'dialog > text:Check'; index = 0; frames = 40 },
    @{ op = 'wait_for'; gone = 'text:Check your copy'; timeout_ms = 30000 }
)

$onboardStepsMobile = @(
    @{ op = 'wait_for'; target = 'text:Create an identity'; timeout_ms = 60000 },
    @{ op = 'tap'; target = 'text:Create an identity'; frames = 60 },
    @{ op = 'wait_for'; target = 'text:Your recovery phrase'; timeout_ms = 60000 }
) + $phraseCheckSteps + @(
    @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 120000 },
    @{ op = 'tap'; target = 'semantics:Settings'; index = 0; frames = 40 },
    @{ op = 'wait_for'; target = 'text:Name, status, avatar and banner'; timeout_ms = 20000 },
    @{ op = 'tap'; target = 'text:Name, status, avatar and banner'; index = 0; frames = 40 },
    @{ op = 'wait_for'; target = 'hint:Enter a display name'; timeout_ms = 20000 },
    @{ op = 'enter_text'; target = 'hint:Enter a display name'; value = 'probe-${PEER}' },
    @{ op = 'wait_for'; target = 'text:Save'; timeout_ms = 10000 },
    @{ op = 'tap'; target = 'text:Save'; index = 0; frames = 40 },
    @{ op = 'wait'; ms = 2500 },
    @{ op = 'tap'; target = 'semantics:Back'; index = 0; frames = 40; soft = $true },
    @{ op = 'wait_for'; target = 'text:probe-${PEER}'; timeout_ms = 20000 },
    @{ op = 'tap'; target = 'semantics:Chats'; index = 0; frames = 30 },
    @{ op = 'dump'; name = 'onboarded' }
)

$onboardSteps = @(
    @{ op = 'wait_for'; target = 'text:Create an identity'; timeout_ms = 60000 },
    @{ op = 'tap'; target = 'text:Create an identity'; frames = 60 },
    # The recovery-phrase dialog is the app confirming the identity exists.
    @{ op = 'wait_for'; target = 'text:Your recovery phrase'; timeout_ms = 60000 }
) + $phraseCheckSteps + @(
    # Proof the node came up, not just the widget tree.
    @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 120000 },
    # A display name, because without one every peer, every friend row, every
    # member panel entry and every DM tab reads '12D3KooW...' and nothing in a
    # scenario can address any of them. `${PEER}` is substituted by the runner
    # from UI_PROBE_PEER, so this one list serves every instance.
    @{ op = 'tap'; target = 'semantics:Settings'; index = 0 },
    @{ op = 'wait_for'; target = 'text:Profile'; timeout_ms = 20000 },
    @{ op = 'tap'; target = 'text:Profile'; index = 0 },
    @{ op = 'wait_for'; target = 'hint:Enter a display name'; timeout_ms = 20000 },
    @{ op = 'enter_text'; target = 'hint:Enter a display name'; value = 'probe-${PEER}' },
    @{ op = 'wait_for'; target = 'text:You have unsaved profile changes'; timeout_ms = 10000 },
    @{ op = 'tap'; target = 'text:Save'; index = 0 },
    @{ op = 'wait'; ms = 2500 },
    @{ op = 'key'; value = 'escape' },
    @{ op = 'wait_for'; target = 'text:probe-${PEER}'; timeout_ms = 20000 },
    @{ op = 'dump'; name = 'onboarded' }
)
if ((Test-SimBackend) -or (Test-AndroidBackend)) { $onboardSteps = $onboardStepsMobile }

# The relay is chosen BEFORE the identity is created, in the welcome dialog's
# own Advanced field, and the choice is stamped into the fixture with the keys.
if ($Relay) {
    $onboardSteps = @($onboardSteps[0]) + (Get-RelayWelcomeSteps $Relay) +
        @($onboardSteps[1..($onboardSteps.Count - 1)])
    Write-Step "onboarding onto relay $Relay" 'Yellow'
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

if (-not $Attach) {
    Stop-Fleet
    foreach ($peer in $peerList) { Reset-PeerData $peer }
    foreach ($peer in $peerList) { Start-Peer $peer }
}

$exitCode = 0
$scenarioFailed = $false
try {
    if ($Attach) {
        Write-Step 'attached: no reboot, no fixture restore'
    } else {
        Wait-Ready $peerList
        Start-Sleep -Milliseconds 500
        Set-FleetWindows $peerList
    }

    if ($Onboard) {
        Write-Step 'onboarding the fixture identities'
        foreach ($peer in $peerList) {
            Write-Step "onboarding $peer"
            $steps = $onboardSteps | ForEach-Object { [pscustomobject]($_ + @{ peer = $peer }) }
            $failures = Invoke-Steps $steps "onboarding $peer"
            if ($failures -gt 0) { throw "onboarding $peer failed" }
            $script:phrases[$peer] = $script:FleetVars['PHRASE']
        }
        $script:onboardOk = $true
    }

    if ($scenarioSteps.Count -gt 0) {
        Write-Step 'running the scenario'
        # Runtime is the number that decides whether the next rung is worth
        # building, so it gets printed rather than guessed at.
        $started = Get-Date
        $failures = Invoke-Steps $scenarioSteps 'scenario'
        Write-Step ("scenario took {0:mm\:ss}" -f ((Get-Date) - $started))
        if ($scenarioCleanup.Count -gt 0) {
            # Cleanup runs whatever happened, and never stops on its own
            # failures: leaving a fleet server alive on the relay is worse than
            # a noisy log.
            Write-Step 'cleanup'
            Invoke-Steps $scenarioCleanup 'cleanup' $true | Out-Null
        }
        if ($failures -gt 0) {
            Write-Step "$failures step(s) failed" 'Red'
            $exitCode = 1
            $scenarioFailed = $true
        } else {
            Write-Step 'scenario passed' 'Green'
        }
    }
} finally {
    if ($Onboard) {
        # The fixture is the data directory AFTER a clean exit, so the WAL is
        # folded in and the lock file is gone. A half-onboarded directory is
        # worse than none: it looks like a fixture and fails every later run.
        Stop-Fleet
        if ($script:onboardOk) {
            foreach ($peer in $peerList) { Save-Fixture $peer }
        } else {
            Write-Step 'onboarding did not finish, so no fixture was stamped' 'Yellow'
            $exitCode = 1
        }
    } elseif ($Attach -or $Live -or $Keep -or $scenarioFailed) {
        # -Attach never stops the fleet: this invocation did not start it, and
        # killing the instances you attached to defeats the whole point of
        # attaching. A failed run is kept for the same reason - the screen
        # still shows what went wrong, and -Attach picks up from there without
        # replaying the twenty steps that worked.
        if ($scenarioFailed) { Write-Step 'left running so you can look at it' 'Yellow' }
        Write-Step "instances up (idle timeout ${IdleMinutes}m). Drive them with:" 'Cyan'
        if (-not (Test-WindowsBackend)) {
            Write-Host '  pwsh scripts/fleet_send.ps1 -Command ''[{"peer":"a","op":"look"}]'''
            Write-Host '  pwsh scripts/fleet.ps1 -Scenario <name> -Attach'
            Write-Host '  pwsh scripts/fleet.ps1 -Stop'
        } else {
            Write-Host '  powershell -File scripts\fleet_send.ps1 -Command ''[{"peer":"a","op":"look"}]'''
            Write-Host '  powershell -File scripts\fleet.ps1 -Scenario <name> -Attach'
            Write-Host '  powershell -File scripts\fleet.ps1 -Stop'
        }
    } else {
        Stop-Fleet
    }
    foreach ($peer in $peerList) {
        try { Sync-PeerOut $peer } catch { Write-Step "could not copy $peer's output off its emulator: $_" 'Yellow' }
    }
}

Write-Step "artifacts: $(Join-Path $outRoot '<peer>') (results.jsonl, map-*.md, *.png, errors.log)"
exit $exitCode
