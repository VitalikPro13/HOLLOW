# Shared by scripts\fleet.ps1 (runs a whole scenario) and scripts\fleet_send.ps1
# (sends a command or two by hand). Both talk to a live instance the same way -
# append to its inbox.jsonl, wait for the matching id in its outbox.jsonl - and
# keeping one implementation means a fix to the death detection or the variable
# expansion lands in both.
#
# Callers set $script:FleetRepo, $script:FleetOutRoot and $script:FleetStageRoot
# before using anything here.
#
# Windows PowerShell 5.1: no pwsh-only syntax.

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
    $sources = @(
        @{ name = 'errors.log'; path = (Join-Path $script:FleetOutRoot "$peer\errors.log") },
        @{ name = 'stdout'; path = (Join-Path $script:FleetOutRoot "$peer\stdout.log") },
        @{ name = 'hollow_debug'; path = (Join-Path $script:FleetStageRoot "$peer\hollow_debug.log") }
    )
    foreach ($item in $sources) {
        if (-not (Test-Path $item.path)) { continue }
        $tail = @(Get-Content $item.path -Tail 20 -ErrorAction SilentlyContinue) |
            Where-Object { $_.Trim() }
        if ($tail.Count -eq 0) { continue }
        $lines += "--- $($item.name) ---"
        $lines += $tail
    }
    if ($lines.Count -eq 0) { return "Nothing in the logs. Look in $script:FleetOutRoot\$peer." }
    return ($lines -join "`n")
}

function Test-PeerLive($peer) {
    return (Test-Path (Join-Path $script:FleetOutRoot "$peer\live-ready"))
}

# Which instances are up right now, by looking at what is running rather than
# at what this invocation happened to launch. That is what lets a second script
# attach to a fleet a first one left behind.
function Get-LivePeers {
    $root = $script:FleetOutRoot
    if (-not (Test-Path $root)) { return @() }
    return @(Get-ChildItem $root -Directory | ForEach-Object { $_.Name } |
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
