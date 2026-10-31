# The device-linking gate: every priority-A pair of the linking matrix under every
# condition, one cell after another, with ONE summary and a non-zero exit on any
# FAIL. A release runs `-Quick` (clean + background, ~30 min); a big multi-device
# change runs the full gate (~2.5-3 h).
#
#   powershell -File scripts\fleet_link_gate.ps1 -Quick
#   powershell -File scripts\fleet_link_gate.ps1 -Build
#   powershell -File scripts\fleet_link_gate.ps1 -Pairs 'android:a>win:b' -Conditions clean,held_db
#
# Pairs are `<presenter>><receiver>`. Peers use letters a and b on every machine,
# the friend win:c and a third device win:d. -Build rebuilds the Windows fleet
# here, ships this worktree to the mini (`scripts/mini_sync.sh <MiniName>`) and
# builds the Android and iOS apps there first.

param(
    [switch]$Quick,
    [switch]$Build,
    [string[]]$Pairs = @('android:a>win:b', 'win:a>android:b', 'ios:a>win:b', 'win:a>ios:b'),
    [string[]]$Conditions = @(),
    [string]$Friend = 'win:c',
    [string]$Third = 'win:d',
    [string]$MiniName = '',
    # The driver's own setting (FLEET_MINI_SSH) when set: the LAN address moves.
    [string]$MiniHost = $(if ($env:FLEET_MINI_SSH) { $env:FLEET_MINI_SSH } else { 'jabun@100.80.56.79' })
)

if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }
# Continue: a child's stderr (ssh, gradle) must never end the gate; failures throw explicitly.
$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
if (-not $MiniName) { $MiniName = Split-Path -Leaf $repoRoot }
$miniSsh = @('-o', 'HostKeyAlias=192.168.18.39', '-o', 'ConnectTimeout=20', '-o', 'BatchMode=yes', $MiniHost)
# Every child (the driver's agents, mini_sync) reaches the same host.
$env:FLEET_MINI_SSH = $MiniHost
$env:MINI_HOST = $MiniHost
# Git's bash: PowerShell has none on its PATH, and WSL's would not see D:.
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw 'Git bash not found' }

$all = @('clean', 'background', 'relay_resume', 'relay_lost', 'transfer_drop', 'held_db', 'cancel_retry', 'third_device')
if (-not $Conditions -or $Conditions.Count -eq 0) {
    $Conditions = if ($Quick) { @('clean', 'background') } else { $all }
}
$Conditions = @($Conditions | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($c in $Conditions) { if ($c -notin $all) { throw "unknown condition $c" } }
# `powershell -File` hands an array over as separate words, so a caller passes 'a>b,c>d'.
$Pairs = @($Pairs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($p in $Pairs) { if ($p -notmatch '^([a-z]+:)?[a-z]>([a-z]+:)?[a-z]$') { throw "pair $p is not [platform:]letter>[platform:]letter" } }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$gateRoot = Join-Path $repoRoot ".team\matrix\gate-$stamp"
New-Item -ItemType Directory -Path $gateRoot -Force | Out-Null
$started = Get-Date

function Say($text, $colour = 'Cyan') {
    $line = "[gate $((Get-Date).ToString('HH:mm:ss'))] $text"
    Write-Host $line -ForegroundColor $colour
    Add-Content -Path (Join-Path $gateRoot 'gate.log') -Value $line -Encoding UTF8
}

function Invoke-Mini($command) {
    # Out-Host: anything ssh prints would otherwise join the return value.
    & ssh @miniSsh "zsh -lc '$command'" | Out-Host
    return $LASTEXITCODE
}

# The mini keeps no emulator or simulator of ours up once the gate is done.
function Stop-MiniDevices {
    $script = ((Join-Path $PSScriptRoot 'mini_devices_down.sh') -replace '\\', '/')
    & $bash -c "ssh $($miniSsh -join ' ') 'bash -s -- hollow-a hollow-b' < '$script'" | Out-Null
}

$platforms = @($Pairs | ForEach-Object { $_ -split '>' } | ForEach-Object { ($_ -split ':')[0] } | Select-Object -Unique)
if ($Build) {
    Say 'building the Windows fleet'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fleet.ps1') -Build -Peers 'a,b,c,d'
    if ($LASTEXITCODE -ne 0) { throw 'the Windows build failed' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fleet.ps1') -Stop -Peers 'a,b,c,d'
    if ($platforms -contains 'android' -or $platforms -contains 'ios' -or $platforms -contains 'macos') {
        Say "shipping this tree to the mini as ~/wt/$MiniName"
        & $bash (Join-Path $PSScriptRoot 'mini_sync.sh') $MiniName ($repoRoot -replace '\\', '/')
        if ($LASTEXITCODE -ne 0) { throw 'mini_sync failed' }
        if ($platforms -contains 'android') {
            Say 'building the Android app on the mini'
            if ((Invoke-Mini "cd ~/wt/$MiniName && FLEET_BACKEND=android pwsh scripts/fleet.ps1 -Build -Peers a,b && pwsh scripts/fleet.ps1 -Stop -Peers a,b") -ne 0) { throw 'the Android build failed' }
        }
        if ($platforms -contains 'ios') {
            Say 'building the iOS app on the mini'
            if ((Invoke-Mini "cd ~/wt/$MiniName && pwsh scripts/fleet.ps1 -Build -Peers a,b && pwsh scripts/fleet.ps1 -Stop -Peers a,b") -ne 0) { throw 'the iOS build failed' }
        }
        if ($platforms -contains 'macos') {
            Say 'building the macOS app on the mini'
            if ((Invoke-Mini "cd ~/wt/$MiniName && FLEET_BACKEND=macos pwsh scripts/fleet.ps1 -Build -Peers a,b && FLEET_BACKEND=macos pwsh scripts/fleet.ps1 -Stop -Peers a,b") -ne 0) { throw 'the macOS build failed' }
        }
        Stop-MiniDevices
    }
}

$cells = New-Object System.Collections.ArrayList
foreach ($pair in $Pairs) {
    $presenter, $receiver = $pair -split '>'
    foreach ($condition in $Conditions) {
        # held_db holds the file the Windows way.
        if ($condition -eq 'held_db' -and -not ($receiver -like 'win:*' -or $receiver -notmatch ':')) { continue }
        [void]$cells.Add([pscustomobject]@{ Presenter = $presenter; Receiver = $receiver; Condition = $condition })
    }
}
Say "$($cells.Count) cell(s): $($Pairs -join ', ') x $($Conditions -join ', ')"

$results = New-Object System.Collections.ArrayList
$matrix = Join-Path $PSScriptRoot 'fleet_link_matrix.ps1'
foreach ($cell in $cells) {
    $name = "$($cell.Presenter) -> $($cell.Receiver) $($cell.Condition)"
    Say "cell $($results.Count + 1)/$($cells.Count): $name"
    $cellArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $matrix,
        '-Presenter', $cell.Presenter, '-Receiver', $cell.Receiver, '-Friend', $Friend,
        '-Condition', $cell.Condition, '-EvidenceRoot', $gateRoot)
    if ($cell.Condition -eq 'third_device') { $cellArgs += @('-Third', $Third) }
    $cellStart = Get-Date
    $log = Join-Path $gateRoot ("cell-{0:d2}.log" -f ($results.Count + 1))
    & powershell @cellArgs *> $log
    $code = $LASTEXITCODE
    $seconds = [int]((Get-Date) - $cellStart).TotalSeconds
    # The matrix appends one line per run; the newest line for this cell is its verdict.
    $verdict = $null
    $jsonl = Join-Path $gateRoot 'results.jsonl'
    if (Test-Path $jsonl) {
        $cellKey = "$($cell.Presenter -replace ':', '-')_to_$($cell.Receiver -replace ':', '-')_$($cell.Condition)"
        $verdict = @(Get-Content $jsonl | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.cell -eq $cellKey -and [int]$_.run -ge 0 }) | Select-Object -Last 1
    }
    $failed = @()
    if ($verdict) {
        foreach ($p in $verdict.gates.PSObject.Properties) { if ($p.Value -eq 'FAIL') { $failed += ($p.Name -split ' ')[0] } }
    }
    $status = if ($code -eq 0 -and $verdict -and $verdict.verdict -eq 'PASS') { 'PASS' } else { 'FAIL' }
    $row = [pscustomobject]@{
        Pair = "$($cell.Presenter) -> $($cell.Receiver)"; Condition = $cell.Condition; Verdict = $status
        Seconds = $seconds; Failed = ($failed -join ' ')
        Reconnects = $(if ($verdict -and $null -ne $verdict.reconnects) { [int]$verdict.reconnects } else { 0 })
        Error = $(if ($verdict) { "$($verdict.error)" } else { "no verdict (exit $code), see $log" })
        Evidence = $(if ($verdict) { "$($verdict.evidence)" } else { $log })
    }
    [void]$results.Add($row)
    $reconnected = if ($row.Reconnects) { " ($($row.Reconnects) agent reconnect(s))" } else { '' }
    Say "$status in ${seconds}s $name$reconnected $($row.Failed) $($row.Error)" $(if ($status -eq 'PASS') { 'Green' } else { 'Red' })
    # A failed cell leaves its peers up for a look; the next cell needs them down.
    foreach ($peer in @($cell.Presenter, $cell.Receiver, $Friend, $Third)) {
        if ($peer -notmatch ':' -or $peer -like 'win:*') {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fleet.ps1') -Stop -Peers ($peer -replace '^win:', '') *> $null
        }
    }
}

if (@($cells | Where-Object { $_.Presenter -notlike 'win:*' -or $_.Receiver -notlike 'win:*' }).Count) { Stop-MiniDevices }

$wall = [int]((Get-Date) - $started).TotalSeconds
$failedCells = @($results | Where-Object { $_.Verdict -ne 'PASS' }).Count
$md = New-Object System.Collections.ArrayList
[void]$md.Add("# Link gate $stamp")
[void]$md.Add('')
[void]$md.Add("$(if ($Quick) { 'Quick' } elseif ($PSBoundParameters.ContainsKey('Pairs') -or $PSBoundParameters.ContainsKey('Conditions')) { 'Partial' } else { 'Full' }) gate, $($results.Count) cell(s), $failedCells failed, wall ${wall}s.")
[void]$md.Add('')
[void]$md.Add('| pair | condition | verdict | seconds | agent reconnects | failed gates | evidence |')
[void]$md.Add('|---|---|---|---|---|---|---|')
foreach ($r in $results) {
    $why = if ($r.Failed) { $r.Failed } elseif ($r.Verdict -ne 'PASS') { $r.Error } else { '' }
    [void]$md.Add("| $($r.Pair) | $($r.Condition) | $($r.Verdict) | $($r.Seconds) | $($r.Reconnects) | $why | $($r.Evidence) |")
}
$md | Set-Content (Join-Path $gateRoot 'summary.md') -Encoding UTF8
Write-Host ''
$results | Format-Table Pair, Condition, Verdict, Seconds, Reconnects, Failed -AutoSize | Out-String | Write-Host
Say "summary: $(Join-Path $gateRoot 'summary.md') ($failedCells failed, wall ${wall}s)" $(if ($failedCells) { 'Red' } else { 'Green' })
if ($failedCells -gt 0) { exit 1 }
exit 0
