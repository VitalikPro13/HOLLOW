# Sends one command (or a batch) to a running `ui_probe.ps1 -Live` session and
# waits for its answer.
#
#   powershell -File scripts\ui_probe_send.ps1 -Command '{"op":"dump","name":"now"}'
#   powershell -File scripts\ui_probe_send.ps1 -Command '[{"op":"tap","target":"text:Delete"}]'
#   powershell -File scripts\ui_probe_send.ps1 -Command '{"op":"quit"}'
#
# The live loop reads build\ui_probe\inbox.jsonl and answers into outbox.jsonl.
# Every command gets an id so the answer can be matched to it, which is what
# makes waiting reliable when several are in flight.
#
# The op vocabulary and target grammar live in integration_test\probe\.

param(
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$TimeoutSeconds = 120,
    [string]$Out = 'build\ui_probe',
    # Append and return immediately.
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$outDir = Join-Path $repoRoot $Out
$inbox = Join-Path $outDir 'inbox.jsonl'
$outbox = Join-Path $outDir 'outbox.jsonl'
$ready = Join-Path $outDir 'live-ready'

# The app writes live-ready once the loop is listening. Sending before that is
# harmless (the file is read from the start) but waiting gives a clear error
# instead of a silent hang when no session is running.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while (-not (Test-Path $ready)) {
    if ((Get-Date) -gt $deadline) {
        throw "no live probe session: $ready never appeared. Start one with: powershell -File scripts\ui_probe.ps1 -Live"
    }
    Start-Sleep -Milliseconds 500
}

$parsed = $Command | ConvertFrom-Json
$commands = @()
if ($parsed -is [System.Array]) { $commands = $parsed } else { $commands = @($parsed) }

$ids = @()
foreach ($cmd in $commands) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $cmd | Add-Member -NotePropertyName 'id' -NotePropertyValue $id -Force
    $ids += $id
    $line = $cmd | ConvertTo-Json -Depth 10 -Compress
    # Not Add-Content: Windows PowerShell writes a UTF-8 BOM into a new or
    # empty file, and a BOM in front of the first line breaks the JSON parse on
    # the Dart side. Append raw UTF-8 with an explicit newline instead.
    [System.IO.File]::AppendAllText(
        $inbox, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[send] $line" -ForegroundColor DarkGray
}

if ($NoWait) { exit 0 }

$want = $ids[-1]
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$seen = @{}
$failed = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path $outbox) {
        foreach ($line in (Get-Content $outbox)) {
            if (-not $line.Trim()) { continue }
            try { $answer = $line | ConvertFrom-Json } catch { continue }
            if (-not $answer.id) { continue }
            if ($seen.ContainsKey($answer.id)) { continue }
            if ($ids -notcontains $answer.id) { continue }
            $seen[$answer.id] = $true
            $mark = if ($answer.ok) { 'ok  ' } else { 'FAIL' }
            $colour = if ($answer.ok) { 'Green' } else { 'Red' }
            if (-not $answer.ok) { $failed = $true }
            Write-Host ("[{0}] {1} {2}" -f $mark, $answer.op, $answer.message) -ForegroundColor $colour
            if ($answer.overlays) {
                $rows = $answer.overlays.menuRows
                if ($rows) { Write-Host ("       menu: " + ($rows -join ' | ')) -ForegroundColor DarkCyan }
                elseif ($answer.overlays.dialog) { Write-Host "       a dialog is open" -ForegroundColor DarkCyan }
            }
            if ($answer.shot) { Write-Host ("       shot: " + $answer.shot) -ForegroundColor DarkCyan }
            if ($answer.id -eq $want) {
                if ($failed) { exit 1 } else { exit 0 }
            }
        }
    }
    Start-Sleep -Milliseconds 300
}

throw "timed out after ${TimeoutSeconds}s waiting for command $want. Is the live session still up?"
