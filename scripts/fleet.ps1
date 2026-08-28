# Runs SEVERAL real Hollow instances on this machine and drives all of them
# from one scenario, so peer-to-peer behaviour can be tested by watching it
# happen instead of by a human reproducing it and describing it.
#
#   powershell -File scripts\fleet.ps1 -Build            # build + stage the copies
#   powershell -File scripts\fleet.ps1 -Onboard          # make the fixture identities
#   powershell -File scripts\fleet.ps1 -Onboard -Fresh   # ... from BRAND-NEW keys
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
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
# `${RUN}` is unique per run, and scenarios should put it in every message they
# send. The relay's availability cache holds undelivered traffic for three days
# and the fixture identities are STABLE across runs, so a message from an
# earlier run can be delivered into a later one: a `wait_for` on a fixed string
# would then pass before the send it was supposed to be waiting for. A run tag
# in the text makes that impossible.
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$stageRoot   = $script:FleetStageRoot
$outRoot     = $script:FleetOutRoot
$fixtureRoot = Join-Path $env:TEMP 'hollow_fleet\fixtures'
$runRoot     = Join-Path $env:TEMP 'hollow_fleet\run'
$buildOutput = Join-Path $repoRoot 'build\windows\x64\runner\Debug'

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
    $running = Get-Process -Name 'hollow' -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -and $_.Path.StartsWith($stageRoot, 'OrdinalIgnoreCase') }
            catch { $false }
        }
    if ($running) {
        Write-Step "stopping $(@($running).Count) fleet instance(s)" 'Yellow'
        $running | Stop-Process -Force
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
        $path = Join-Path $repoRoot "scripts\probe_scenarios\fleet\$Scenario.json"
        if (-not (Test-Path $path)) {
            $dir = Join-Path $repoRoot 'scripts\probe_scenarios\fleet'
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
    Write-Step 'building the probe target as a standalone exe'
    & flutter build windows --debug -t integration_test/ui_probe_test.dart
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed with $LASTEXITCODE" }
}

function Stage-Peer($peer) {
    if (-not (Test-Path $buildOutput)) {
        throw "no build output at $buildOutput. Run with -Build first."
    }
    $dest = Join-Path $stageRoot $peer
    Write-Step "staging $peer"
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
        $exe = Join-Path $stageRoot "$peer\hollow.exe"
        if (-not (Test-Path $exe)) {
            Write-Step "$peer is not staged yet" 'Yellow'
            Stage-Peer $peer
        }
    }
}

# --------------------------------------------------------------------------
# Data directories
# --------------------------------------------------------------------------

function Reset-PeerData($peer) {
    $fixture = Join-Path $fixtureRoot $peer
    $run = Join-Path $runRoot $peer
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
        robocopy $fixture $run /MIR /MT:8 /XF 'hollow.lock' /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "restoring the $peer fixture failed with $LASTEXITCODE" }
        $global:LASTEXITCODE = 0
    } else {
        Write-Step "$peer has no fixture identity yet - it will onboard from scratch. Run -Onboard to stamp one." 'Yellow'
    }
}

function Save-Fixture($peer) {
    $fixture = Join-Path $fixtureRoot $peer
    $run = Join-Path $runRoot $peer
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    # The WAL has to be folded in before a copy, and the app does that on exit,
    # so this only ever runs after the instances are stopped.
    robocopy $run $fixture /MIR /MT:8 /XF 'hollow.lock' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "stamping the $peer fixture failed with $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
    Write-Step "stamped the $peer fixture -> $fixture" 'Green'
}

# --------------------------------------------------------------------------
# Launch
# --------------------------------------------------------------------------

$script:processes = @{}
$script:onboardOk = $false

function Start-Peer($peer) {
    $dest = Join-Path $stageRoot $peer
    $data = Join-Path $runRoot $peer
    $out = Join-Path $outRoot $peer
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
$onboardSteps = @(
    @{ op = 'wait_for'; target = 'text:Create New Identity'; timeout_ms = 60000 },
    @{ op = 'tap'; target = 'text:Create New Identity'; frames = 60 },
    # The recovery-phrase dialog is the app confirming the identity exists.
    @{ op = 'wait_for'; target = 'text:Your Recovery Phrase'; timeout_ms = 60000 },
    @{ op = 'tap'; target = "text:I've saved it"; frames = 40 },
    @{ op = 'wait_for'; gone = 'text:Your Recovery Phrase'; timeout_ms = 30000 },
    # Proof the node came up, not just the widget tree.
    @{ op = 'wait_for'; target = 'text:Connected'; timeout_ms = 120000 },
    # A display name, because without one every peer, every friend row, every
    # member panel entry and every DM tab reads '12D3KooW...' and nothing in a
    # scenario can address any of them. `${PEER}` is substituted by the runner
    # from UI_PROBE_PEER, so this one list serves every instance.
    @{ op = 'tap'; target = 'semantics:Settings'; index = 0 },
    @{ op = 'wait_for'; target = 'text:Profile'; timeout_ms = 20000 },
    @{ op = 'tap'; target = 'text:Profile'; index = 0 },
    @{ op = 'wait_for'; target = 'hint:Enter a display name'; timeout_ms = 20000 },
    @{ op = 'enter_text'; target = 'hint:Enter a display name'; value = 'probe-${PEER}' },
    @{ op = 'tap'; target = 'text:Save profile'; index = 0 },
    @{ op = 'wait'; ms = 2500 },
    @{ op = 'key'; value = 'escape' },
    @{ op = 'wait_for'; target = 'text:probe-${PEER}'; timeout_ms = 20000 },
    @{ op = 'dump'; name = 'onboarded' }
)

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
        Write-Host '  powershell -File scripts\fleet_send.ps1 -Command ''[{"peer":"a","op":"look"}]'''
        Write-Host '  powershell -File scripts\fleet.ps1 -Scenario <name> -Attach'
        Write-Host '  powershell -File scripts\fleet.ps1 -Stop'
    } else {
        Stop-Fleet
    }
}

Write-Step "artifacts: $outRoot\<peer>\ (results.jsonl, map-*.md, *.png, errors.log)"
exit $exitCode
