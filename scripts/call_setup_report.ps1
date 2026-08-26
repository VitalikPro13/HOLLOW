<#
.SYNOPSIS
  Summarise [CALL-SETUP] timelines from hollow_debug.log.

.DESCRIPTION
  Answers one question: is ICE gathering actually on the critical path of a
  call, or does it hide behind the SDP round trip?

  The decisive column is Exposed. It is how much CANDIDATE gathering ran past
  the moment the peer's SDP arrived, so it is the upper bound on what
  pre-gathering could ever save. Zero means the usable candidate set was in
  hand before the answer, and pre-gathering would buy nothing.

  Measured against the last candidate, NOT against ICE gathering `complete`.
  Gathering completion also waits on transports nothing will use, and
  connectivity checks never wait for it, so GatherDone is shown for reference
  and deliberately drives no verdict.

  Caller-only for that column: the callee has no comparable wait after its
  local description, so all of its gathering is on the critical path.

.PARAMETER Path
  hollow_debug.log to read. Defaults to the Debug then Release runner folder
  (on Windows the log sits next to the exe).

.PARAMETER Detail
  Print every mark of every call, not just the summary table.

.EXAMPLE
  pwsh scripts\call_setup_report.ps1
  pwsh scripts\call_setup_report.ps1 -Path C:\path\to\hollow_debug.log -Detail
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Detail
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Resolve-LogPath {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "No log at $Explicit" }
        return (Resolve-Path $Explicit).Path
    }
    $candidates = @(
        (Join-Path $repo 'build\windows\x64\runner\Debug\hollow_debug.log'),
        (Join-Path $repo 'build\windows\x64\runner\Release\hollow_debug.log')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    throw "No hollow_debug.log found. Looked in:`n  $($candidates -join "`n  ")`nPass -Path explicitly."
}

function Get-Ms {
    param([string]$Text, [string]$Key)
    # "gather-exposed=81ms" -> 81 ; "machine=n/a" -> $null
    $m = [regex]::Match($Text, [regex]::Escape($Key) + '=(\d+)ms')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Format-Ms {
    param($Value)
    if ($null -eq $Value) { return 'n/a' }
    return "$Value" + 'ms'
}

function Get-Median {
    param([int[]]$Values)
    # NOT `-not $Values`: a one-element array unrolls to its scalar, so @(0)
    # is falsy and a median of exactly 0ms came back blank.
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $mid = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$mid] }
    return [int](($sorted[$mid - 1] + $sorted[$mid]) / 2)
}

$logPath = Resolve-LogPath -Explicit $Path
Write-Host "Reading $logPath" -ForegroundColor DarkGray

$lines = Get-Content -LiteralPath $logPath | Where-Object { $_ -match '\[CALL-SETUP\]' }
if (-not $lines) {
    Write-Host "No [CALL-SETUP] lines. Place a call, hang up, then re-run." -ForegroundColor Yellow
    return
}

# Two lines per call: a summary and a marks line, joined on dir+call id.
$calls = @{}
$order = New-Object System.Collections.ArrayList

foreach ($line in $lines) {
    $m = [regex]::Match($line, '\[CALL-SETUP\]\s+(out|in)\s+call=(\S+)\s+(.*)$')
    if (-not $m.Success) { continue }
    $dir = $m.Groups[1].Value
    $id = $m.Groups[2].Value
    $rest = $m.Groups[3].Value
    $key = "$dir/$id"

    if (-not $calls.ContainsKey($key)) {
        $calls[$key] = [ordered]@{
            Dir = $dir; Id = $id; Reason = ''; Human = $null
            Machine = $null; CandsReady = $null; Exposed = $null
            GatherDone = $null; Marks = ''
        }
        [void]$order.Add($key)
    }
    $c = $calls[$key]

    if ($rest -match '^marks:\s*(.*)$') {
        $c.Marks = $Matches[1]
        continue
    }
    $reason = ($rest -split '\s+')[0]
    $c.Reason = $reason
    $c.Human = Get-Ms $rest 'human'
    $c.Machine = Get-Ms $rest 'machine'
    $c.CandsReady = Get-Ms $rest 'cands-ready'
    $c.Exposed = Get-Ms $rest 'gather-exposed'
    $c.GatherDone = Get-Ms $rest 'gather-done'
}

$rows = foreach ($k in $order) {
    $c = $calls[$k]
    [pscustomobject]@{
        Dir        = $c.Dir
        Call       = $c.Id.Substring(0, [Math]::Min(8, $c.Id.Length))
        Outcome    = $c.Reason
        Human      = Format-Ms $c.Human
        Machine    = Format-Ms $c.Machine
        CandsReady = Format-Ms $c.CandsReady
        Exposed    = Format-Ms $c.Exposed
        GatherDone = Format-Ms $c.GatherDone
        PeerCands  = $(if ($c.Marks -match 'remote-cand=') { 'yes' } else { 'NONE' })
        Dropped    = $(if ($c.Marks -match 'cand-dropped=') { 'YES' } else { '' })
    }
}

$rows | Format-Table -AutoSize

if ($Detail) {
    Write-Host 'Marks (each value is the delta from the previous mark):' -ForegroundColor Cyan
    foreach ($k in $order) {
        $c = $calls[$k]
        Write-Host ("  {0} {1}" -f $c.Dir, $c.Id) -ForegroundColor DarkGray
        Write-Host ("    {0}" -f $c.Marks)
    }
    Write-Host ''
}

# -- The verdict --------------------------------------------------------------

# @() around each: a lone [ordered] hashtable answers .Count with its KEY
# count (8), not 1 — that is how "Connected calls: 8 (of 2 traced)" happened.
$connected = @($order | ForEach-Object { $calls[$_] } | Where-Object { $_.Reason -eq 'connected' })
$machines = @($connected | Where-Object { $null -ne $_.Machine } | ForEach-Object { $_.Machine })
$outgoing = @($connected | Where-Object { $_.Dir -eq 'out' -and $null -ne $_.Exposed })
$exposeds = @($outgoing | ForEach-Object { $_.Exposed })


Write-Host ("Connected calls: {0} (of {1} traced)" -f $connected.Count, $order.Count)
if ($machines.Count -gt 0) {
    Write-Host ("  Machine time  median {0}ms   worst {1}ms" -f (Get-Median $machines), ($machines | Measure-Object -Maximum).Maximum)
}

# Candidate delivery, which decides whether a failure was ICE or signalling.
# Only meaningful on a build that emits remote-cand / cand-dropped; an older
# log simply has no such marks and is silently skipped.
$traced = @($order | ForEach-Object { $calls[$_] } | Where-Object { $_.Marks })
$knowsPeerCands = @($traced | Where-Object { $_.Marks -match '(remote-cand|cand-dropped)=' })
$dropped = @($traced | Where-Object { $_.Marks -match 'cand-dropped=' })
if ($dropped.Count -gt 0) {
    Write-Host ''
    Write-Host ("  WARNING: {0} call(s) DISCARDED queued peer candidates (cand-dropped)." -f $dropped.Count) -ForegroundColor Red
    Write-Host '           The peer trickled before we had a peer connection to hold them.' -ForegroundColor Red
}
if ($knowsPeerCands.Count -gt 0) {
    $noPeerCands = @($traced | Where-Object { $_.Marks -notmatch 'remote-cand=' })
    if ($noPeerCands.Count -gt 0) {
        Write-Host ("  NOTE: {0} call(s) never saw a single candidate FROM the peer." -f $noPeerCands.Count) -ForegroundColor Yellow
        Write-Host '        Such a call can only connect on peer-reflexive discovery.' -ForegroundColor Yellow
    }
}

if ($exposeds.Count -eq 0) {
    Write-Host '  No caller-side gather-exposed samples yet (place a call FROM this machine).' -ForegroundColor Yellow
    return
}

$medianExposed = Get-Median $exposeds
$worstExposed = ($exposeds | Measure-Object -Maximum).Maximum
$zeroCount = @($exposeds | Where-Object { $_ -eq 0 }).Count

Write-Host ''
Write-Host 'Candidate gathering on the critical path (caller side):' -ForegroundColor Cyan
Write-Host ("  exposed  median {0}ms   worst {1}ms   zero on {2}/{3} calls" -f $medianExposed, $worstExposed, $zeroCount, $exposeds.Count)

$share = ''
if ($machines.Count -gt 0) {
    $medMachine = Get-Median $machines
    if ($medMachine -gt 0) {
        $share = " ({0:N0}% of median machine time)" -f (100.0 * $medianExposed / $medMachine)
    }
}

if ($worstExposed -eq 0) {
    Write-Host '  VERDICT: every candidate was in hand before the answer arrived.' -ForegroundColor Green
    Write-Host '           Pre-gathering would save nothing. Leave it alone.' -ForegroundColor Green
} elseif ($medianExposed -lt 100) {
    Write-Host ("  VERDICT: gathering costs a median {0}ms{1}." -f $medianExposed, $share) -ForegroundColor Green
    Write-Host '           That is the ceiling on pre-gathering. Almost certainly not worth it.' -ForegroundColor Green
} else {
    Write-Host ("  VERDICT: gathering costs a median {0}ms{1} on the critical path." -f $medianExposed, $share) -ForegroundColor Yellow
    Write-Host '           Worth a look. Check the marks for WHICH candidate is late' -ForegroundColor Yellow
    Write-Host '           (cand-relay last means TURN allocation is the tail).' -ForegroundColor Yellow
}
