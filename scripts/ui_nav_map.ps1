# Regenerates reports\reference\UI_NAVIGATION_MAP.md by walking the app and writing down
# what it finds.
#
#   powershell -File scripts\ui_nav_map.ps1
#   powershell -File scripts\ui_nav_map.ps1 -Attach      # reuse a fleet left up with -Live
#   powershell -File scripts\ui_nav_map.ps1 -SkipRun     # restitch the last run
#
# Runs the fleet `nav_map` scenario on the throwaway peer `a` (one dump per main
# screen), then stitches the per-screen digests into one document. Never the
# single-peer probe: its default mirrors Vitalik's real identity.
#
# NEVER hand-edit the report: it is generated, and a hand-written navigation
# note goes stale the first time a label changes. Change the scenario or the
# dump, then run this again.

param(
    [switch]$Attach,
    # Stitch whatever maps build\fleet_out\a already holds, without driving the
    # app. For iterating on the document itself.
    [switch]$SkipRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
$mapDir = Join-Path $repoRoot 'build\fleet_out\a'

$probeExit = 0
if (-not $SkipRun) {
    Get-ChildItem $mapDir -Filter 'map-*.md' -ErrorAction SilentlyContinue | Remove-Item
    # A HASHTABLE splat, not an array: an array splat passes its elements
    # positionally, so the switches land on the wrong parameters.
    $fleetArgs = @{ Scenario = 'nav_map'; Peers = 'a' }
    if ($Attach) { $fleetArgs['Attach'] = $true }
    & (Join-Path $PSScriptRoot 'fleet.ps1') @fleetArgs
    $probeExit = $LASTEXITCODE
}

$maps = Get-ChildItem $mapDir -Filter 'map-*.md' | Sort-Object Name
if (-not $maps) { throw "no maps in $mapDir; run without -SkipRun" }

$out = Join-Path $repoRoot 'reports\reference\UI_NAVIGATION_MAP.md'
New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null

$stamp = (Get-Date).ToString('yyyy-MM-dd')
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# UI navigation map')
$lines.Add('')
$lines.Add("Generated $stamp by ``scripts\ui_nav_map.ps1`` from the running app.")
$lines.Add('Do not hand-edit; regenerate it.')
$lines.Add('')
$lines.Add('Every row carries the target string the UI probe accepts, so a')
$lines.Add('scenario can be written from this document without guessing how a')
$lines.Add('widget is addressed. The grammar is in')
$lines.Add('``integration_test\probe\probe_targets.dart``.')
$lines.Add('')
$lines.Add('## Screens')
$lines.Add('')
foreach ($map in $maps) {
    $screen = $map.BaseName -replace '^map-', ''
    # The section heading below is "## UI map: <screen>", and that is what the
    # anchor has to be built from, not the file name.
    $lines.Add("- [$screen](#ui-map-$screen)")
}
$lines.Add('')

foreach ($map in $maps) {
    $lines.Add('---')
    $lines.Add('')
    # Demote every heading one level so each screen nests under this document.
    foreach ($line in (Get-Content $map.FullName)) {
        if ($line -match '^#') { $lines.Add('#' + $line) } else { $lines.Add($line) }
    }
    $lines.Add('')
}

# Not Set-Content -Encoding utf8: Windows PowerShell puts a BOM in front of the
# first line, which then shows up as a stray glyph above the title.
[System.IO.File]::WriteAllLines(
    $out, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[ui-nav-map] wrote $out ($($maps.Count) screens)" -ForegroundColor Green
exit $probeExit
