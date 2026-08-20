# Drives the real app on Windows against a COPY of a real data directory and
# leaves screenshots, navigation maps and step results behind (issue #61 test
# tooling).
#
# The point: check a UI change by looking at it, instead of asking a human to
# reproduce it and describe what they saw. Widget tests mock FFI, so the seam
# where most of the recent bugs lived  -  optimistic writes, reload races, a
# disposed provider ref  -  is invisible to them. Here the DB and CRDT are real.
#
#   powershell -File scripts\ui_probe.ps1                      # boot, shot, map
#   powershell -File scripts\ui_probe.ps1 -Scenario channel_menu
#   powershell -File scripts\ui_probe.ps1 -ScenarioFile my.json -ReuseData
#   powershell -File scripts\ui_probe.ps1 -Steps '[{"op":"dump","name":"x"}]'
#   powershell -File scripts\ui_probe.ps1 -Live                # command loop
#
# Scenarios are DATA, read at runtime (see scripts\probe_scenarios\*.json), so
# a new one never means a rebuild. The op vocabulary and the target grammar are
# documented in integration_test\probe\probe_runner.dart and probe_targets.dart.
#
# In -Live mode the app stays open and executes commands appended to
# build\ui_probe\inbox.jsonl, answering into outbox.jsonl. Send one with
# scripts\ui_probe_send.ps1. Windows PowerShell 5.1 is what is installed on
# this machine, so both scripts stay 5.1-compatible: no pwsh-only syntax.
#
# Artifacts, all under build\ui_probe:
#   *.png            screenshots
#   map-*.md/.json   what is on screen + the provider state behind it
#   results.jsonl    one line per step
#   fail-*.png       automatic, on any failed step
#
# SAFETY: never points the app at the live data directory. It mirrors it to a
# scratch copy first, because the probe clicks real buttons and writes real
# CRDT ops. Re-copy with -Fresh after the live data changes.

param(
    # A file in scripts\probe_scenarios (without .json), or 'boot' for the
    # built-in boot-and-map run.
    [string]$Scenario = 'boot',
    # An explicit path to a scenario file, anywhere.
    [string]$ScenarioFile = '',
    # An inline JSON array of steps.
    [string]$Steps = '',
    # Stay open and take commands from build\ui_probe\inbox.jsonl.
    [switch]$Live,
    # How long the live loop waits for a command before giving up.
    [int]$IdleMinutes = 20,
    [string]$Server = 'test3',
    [string]$SourceData = "$env:APPDATA\Hollow",
    [string]$ProbeData = "$env:TEMP\hollow_ui_probe_data",
    # Re-mirror the data copy even if it already exists.
    [switch]$Fresh,
    # Skip the mirror entirely and reuse whatever the copy already holds.
    [switch]$ReuseData
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# -- 0. Resolve the scenario ---
$resolvedScenario = ''
if ($ScenarioFile) {
    if (-not (Test-Path $ScenarioFile)) { throw "scenario file not found: $ScenarioFile" }
    $resolvedScenario = (Resolve-Path $ScenarioFile).Path
} elseif ($Scenario -and $Scenario -ne 'boot') {
    $candidate = Join-Path $repoRoot "scripts\probe_scenarios\$Scenario.json"
    if (-not (Test-Path $candidate)) {
        $known = (Get-ChildItem (Join-Path $repoRoot 'scripts\probe_scenarios') -Filter *.json |
                  ForEach-Object { $_.BaseName }) -join ', '
        throw "unknown scenario '$Scenario'. Known: $known (or pass -ScenarioFile)"
    }
    $resolvedScenario = (Resolve-Path $candidate).Path
}

$env:UI_PROBE_SCENARIO_FILE = $resolvedScenario
$env:UI_PROBE_STEPS = $Steps
$env:UI_PROBE_SERVER = $Server
$env:SERVER = $Server
$env:UI_PROBE_MODE = if ($Live) { 'live' } else { 'script' }
$env:UI_PROBE_IDLE_MINUTES = "$IdleMinutes"

$what = 'boot + map'
if ($Live) { $what = 'live' }
elseif ($resolvedScenario) { $what = $resolvedScenario }
elseif ($Steps) { $what = 'inline steps' }
Write-Host "[ui-probe] $what (server=$Server)" -ForegroundColor Cyan

# -- 1. A running instance holds the lock file and the DB ---
$running = Get-Process -Name 'hollow' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "[ui-probe] stopping $($running.Count) running hollow.exe" -ForegroundColor Yellow
    $running | Stop-Process -Force
    # The lock file is released on exit; give the handle time to drop.
    Start-Sleep -Milliseconds 800
}

# -- 2. Mirror the data dir so the probe can never touch the real one ---
if (-not $ReuseData) {
    if ((Test-Path $ProbeData) -and -not $Fresh) {
        Write-Host "[ui-probe] reusing data copy at $ProbeData (-Fresh to re-mirror)"
    } else {
        if (-not (Test-Path $SourceData)) {
            throw "source data dir not found: $SourceData"
        }
        Write-Host "[ui-probe] mirroring $SourceData -> $ProbeData"
        # robocopy: /MIR mirrors, /NFL /NDL /NJH /NJS keep the log quiet.
        # A stale lock must not come along, or the app refuses to start.
        robocopy $SourceData $ProbeData /MIR /XF 'hollow.lock' /NFL /NDL /NJH /NJS /NP | Out-Null
        # robocopy exit codes below 8 are success (0 = no change, 1 = copied).
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed with $LASTEXITCODE" }
        $LASTEXITCODE = 0
    }
    Remove-Item "$ProbeData\hollow.lock" -ErrorAction SilentlyContinue
}

$env:HOLLOW_DATA_DIR = $ProbeData
Write-Host "[ui-probe] HOLLOW_DATA_DIR=$env:HOLLOW_DATA_DIR"

# -- 3. Hide the stale cargo artifact FRB would otherwise load ---
# frb_generated.dart sets ioDirectory 'rust/hollow_core/target/release/', which
# FRB resolves relative to the CURRENT WORKING DIRECTORY. A normal app launch
# has its CWD elsewhere, so that path misses and the bundled DLL next to the
# exe wins - but flutter drive runs with CWD at the repo root, so it picks up
# whatever `cargo build --release` last left there. That artifact is usually
# months old, and the app then dies on an FRB content-hash mismatch before the
# first frame. Move it aside for the run so the freshly built DLL is used.
$staleDll = Join-Path $repoRoot 'rust\hollow_core\target\release\hollow_core.dll'
$hiddenDll = "$staleDll.probe-hidden"
$didHide = $false
if (Test-Path $staleDll) {
    Move-Item -Force $staleDll $hiddenDll
    $didHide = $true
    Write-Host "[ui-probe] moved the stale cargo dll aside for this run"
}

# -- 4. Drive it ---
$shots = Join-Path $repoRoot 'build\ui_probe'
# Clear BEFORE either process starts: a stale PNG from a previous run looks
# like a result. The app writes into this directory itself, and flutter drive
# starts the app before the driver, so cleanup cannot live in the driver.
#
# The last run is kept one folder over rather than deleted. Comparing a map to
# the one before it is the whole diagnosis for a layout bug, and the folder is
# named for what it holds, so it cannot be mistaken for the current run.
$prev = Join-Path $repoRoot 'build\ui_probe_prev'
if (Test-Path $shots) {
    if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
    Move-Item $shots $prev
}
New-Item -ItemType Directory -Path $shots -Force | Out-Null
Write-Host "[ui-probe] running flutter drive (this builds first, so give it a few minutes)" -ForegroundColor Cyan
if ($Live) {
    Write-Host "[ui-probe] once LIVE appears, send commands with:" -ForegroundColor Cyan
    Write-Host '           powershell -File scripts\ui_probe_send.ps1 -Command ''{"op":"dump","name":"now"}'''
}

try {
    & flutter drive `
        --driver=test_driver/integration_test.dart `
        --target=integration_test/ui_probe_test.dart `
        -d windows

    $driveExit = $LASTEXITCODE
} finally {
    if ($didHide -and (Test-Path $hiddenDll)) {
        Move-Item -Force $hiddenDll $staleDll
        Write-Host "[ui-probe] restored the cargo dll"
    }
}

# -- 5. Report ---
$results = Join-Path $shots 'results.jsonl'
if (Test-Path $results) {
    Write-Host "`n[ui-probe] steps:" -ForegroundColor Green
    Get-Content $results | ForEach-Object {
        $step = $_ | ConvertFrom-Json
        $mark = if ($step.ok) { 'ok  ' } else { 'FAIL' }
        $colour = if ($step.ok) { 'Gray' } else { 'Red' }
        $first = ($step.message -split "`n")[0]
        Write-Host ("  {0} {1,-2} {2,-16} {3}" -f $mark, $step.i, $step.op, $first) -ForegroundColor $colour
    }
}

if (Test-Path $shots) {
    $pngs = Get-ChildItem $shots -Filter *.png
    $maps = Get-ChildItem $shots -Filter map-*.md
    Write-Host "`n[ui-probe] artifacts in $shots" -ForegroundColor Green
    $pngs | ForEach-Object { Write-Host ("  {0}  ({1:N0} KB)" -f $_.Name, ($_.Length / 1KB)) }
    $maps | ForEach-Object { Write-Host ("  {0}" -f $_.Name) }
} else {
    Write-Host "`n[ui-probe] no artifacts were written" -ForegroundColor Yellow
}

if ($driveExit -ne 0) {
    Write-Host "[ui-probe] flutter drive exited $driveExit  -  the artifacts above still show how far it got" -ForegroundColor Yellow
}
exit $driveExit
