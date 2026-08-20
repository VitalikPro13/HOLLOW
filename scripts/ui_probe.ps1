# Drives the real app on Windows against a COPY of a real data directory and
# leaves screenshots behind (issue #61 test tooling).
#
# The point: check a UI change by looking at it, instead of asking a human to
# reproduce it and describe what they saw. Widget tests mock FFI, so the seam
# where most of the recent bugs lived  -  optimistic writes, reload races, a
# disposed provider ref  -  is invisible to them. Here the DB and CRDT are real.
#
#   pwsh scripts\ui_probe.ps1                          # just boot and screenshot
#   pwsh scripts\ui_probe.ps1 -Scenario channel_menu
#   pwsh scripts\ui_probe.ps1 -Scenario create_category -Server test3
#
# Screenshots land in build\ui_probe\*.png.
#
# SAFETY: never points the app at the live data directory. It mirrors it to a
# scratch copy first, because the probe clicks real buttons and writes real
# CRDT ops. Re-copy with -Fresh after the live data changes.

param(
    [string]$Scenario = 'boot',
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

Write-Host "[ui-probe] scenario=$Scenario server=$Server" -ForegroundColor Cyan

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
if (Test-Path $shots) { Remove-Item $shots -Recurse -Force }
New-Item -ItemType Directory -Path $shots -Force | Out-Null
Write-Host "[ui-probe] running flutter drive (this builds first, so give it a few minutes)" -ForegroundColor Cyan

try {
    & flutter drive `
        --driver=test_driver/integration_test.dart `
        --target=integration_test/ui_probe_test.dart `
        -d windows `
        --dart-define=SCENARIO=$Scenario `
        --dart-define=SERVER=$Server

    $driveExit = $LASTEXITCODE
} finally {
    if ($didHide -and (Test-Path $hiddenDll)) {
        Move-Item -Force $hiddenDll $staleDll
        Write-Host "[ui-probe] restored the cargo dll"
    }
}

# -- 5. Report ---
if (Test-Path $shots) {
    Write-Host "`n[ui-probe] screenshots:" -ForegroundColor Green
    Get-ChildItem $shots -Filter *.png | ForEach-Object {
        Write-Host ("  {0}  ({1:N0} KB)" -f $_.FullName, ($_.Length / 1KB))
    }
} else {
    Write-Host "`n[ui-probe] no screenshots were written" -ForegroundColor Yellow
}

if ($driveExit -ne 0) {
    Write-Host "[ui-probe] flutter drive exited $driveExit  -  the screenshots above still show how far it got" -ForegroundColor Yellow
}
exit $driveExit
