# Sibling sync in the field: ONE identity on two devices, one device acts while
# the other is online, backgrounded (phones), closed for a minute or closed past
# the relay's live window, and the other must end up showing the same servers,
# friends, profile, blocks and DMs, with nothing it already held "joined" again
# and nothing the actor did undone by the device that came back. Both
# directions run in one go: the holder acts while the linked device is away,
# then the linked device acts while the holder is away.
#
#   powershell -File scripts\fleet_md_sibling.ps1 -Holder android:w -Linked win:s
#   powershell -File scripts\fleet_md_sibling.ps1 -Holder win:s -Linked ios:v -Quick
#
# The pair comes from one fleet_link_matrix.ps1 cell (-KeepUp): the holder is a
# fresh populated identity, the linked device starts empty and links through
# the real UI. -ReuseLink skips that when the pair is still up from a run.
# Peers are <platform>:<letter> as in fleet_remote.ps1. -Friend owns the
# servers the actor joins and leaves and trades DMs; -Other is a stranger the
# actor befriends, removes, blocks and unblocks. Each machine's tree must hold
# a current build (see fleet_link_matrix.ps1).
#
# States: Online, Background (only when the away device is a phone), Closed1m,
# Closed10m (-LongAwaySeconds, skipped by -Quick). Every cell runs the same ops:
# create, join, leave and delete a server, change the profile name, a DM each
# way, and one step of the friend cycle (add, remove + block, unblock + accept,
# remove) with -Other. Each op is judged on the away device's DATABASE and its
# PROVIDERS (the probe's sibling_state op), timed from its return (from the op
# for Online); then the actor is checked to still hold every result, and the
# away device's selected server must be the one it had (a sibling's join never
# moves the screen). Last, a desktop of the pair loses its database and keeps its
# identity (-SkipLostDb skips it): the friend, the DM history and a live DM must
# come back, with no DM refused.
#
# Output: a summary table (direction x state x op, PASS/FAIL, seconds to
# converge, rc = driver reconnects in that cell), summary.json, shots, each peer's evidence and this run's refusal
# lines under build\fleet_out\kept\md_sibling\<run>\. Exit 1 on any FAIL.

param(
    [string]$Holder = 'win:s',
    [string]$Linked = 'win:t',
    [string]$Friend = 'win:u',
    [string]$Other = 'win:v',
    # Skip the cells that keep a device closed past the live window.
    [switch]$Quick,
    [int]$ShortAwaySeconds = 60,
    [int]$LongAwaySeconds = 600,
    [int]$BackgroundSeconds = 45,
    [int]$ConvergeSeconds = 120,
    # The pair (and -Friend) are still up and linked from an earlier run.
    [switch]$ReuseLink,
    # Run only these cells, e.g. 'fwd-Closed1m,rev-Online'.
    [string]$Only = '',
    # Leave every peer running at the end.
    [switch]$KeepUp,
    # Skip the last cell, where a desktop of the pair loses its database.
    [switch]$SkipLostDb,
    [string]$EvidenceRoot = ''
)

if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')

$runTag = $script:FleetVars.RUN
$started = Get-Date
$startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 5

$H = Register-FleetPeer $Holder
$L = Register-FleetPeer $Linked
$F = Register-FleetPeer $Friend
$O = Register-FleetPeer $Other
$all = @($H, $L, $F, $O)

function Get-Platform($peer) { if (Test-RemotePeer $peer) { return (Get-RemotePeer $peer).Platform } return 'win' }
function Test-Mobile($peer) { return (Get-Platform $peer) -in @('android', 'ios') }
function Get-Letter($peer) { if (Test-RemotePeer $peer) { return (Get-RemotePeer $peer).Letter } return $peer }

$letters = @($all | ForEach-Object { Get-Letter $_ })
if (@($letters | Select-Object -Unique).Count -ne $letters.Count) {
    throw "every peer needs its own letter (got $($all -join ', ')): build\fleet_out is per letter on every machine"
}

if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $repoRoot 'build\fleet_out\kept\md_sibling' }
$evidence = Join-Path $EvidenceRoot $runTag
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$script:Rows = New-Object System.Collections.ArrayList
$script:Notes = New-Object System.Collections.ArrayList

function Say($message, $colour = 'Cyan') { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $message" -ForegroundColor $colour }
function Add-Note($text) { [void]$script:Notes.Add($text); Say "note: $text" 'DarkCyan' }

# rc = drop-proof driver reconnects (fleet_remote.ps1) since the current cell began.
$script:CellRc0 = 0
function Add-Row($dir, $state, $op, $verdict, $seconds, $note = '', $rc = $null) {
    if ($null -eq $rc) { $rc = [int]$script:FleetAgentReconnects - [int]$script:CellRc0 }
    [void]$script:Rows.Add([pscustomobject]@{ dir = $dir; state = $state; op = $op; verdict = $verdict; seconds = $seconds; rc = $rc; note = $note })
    $colour = if ($verdict -eq 'PASS') { 'Green' } elseif ($verdict -eq 'FAIL') { 'Red' } else { 'DarkGray' }
    Say ("  {0,-4} {1}-{2} {3} {4}s {5}" -f $verdict, $dir, $state, $op, $seconds, $note) $colour
}

# --------------------------------------------------------------------------
# Talking to peers, wherever they are
# --------------------------------------------------------------------------

function Step($peer, $step, $timeoutSeconds = 240) {
    $what = @($step.name, $step.target, $step.contact, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer ([pscustomobject]$step) $timeoutSeconds
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
    return $answer
}

function Soft($peer, $step, $timeoutSeconds = 240) {
    try { return (Send-FleetStep $peer ([pscustomobject]$step) $timeoutSeconds) }
    catch { return [pscustomobject]@{ ok = $false; message = "$($_.Exception.Message)" } }
}

function Get-SibState($peer, $fields = @{}) {
    $step = @{ op = 'sibling_state' }
    foreach ($key in $fields.Keys) { $step[$key] = $fields[$key] }
    return (Step $peer $step 120).state
}

# A check holds on the database and, unless it is database-only, on the providers.
function Test-Check($check, $state) {
    if (-not (& $check.test $state.db)) { return $false }
    if ($check.dbOnly) { return $true }
    return [bool](& $check.test $state.ui)
}

function Get-SecondsSince($t) {
    return ([math]::Round(((Get-Date) - $t).TotalSeconds, 1)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
}

function Wait-Connected($peer, $timeoutSeconds = 180) {
    Step $peer @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = $timeoutSeconds * 1000 } ($timeoutSeconds + 60) | Out-Null
}

# Polls $peer until $test holds on its database AND its providers.
function Wait-Both($peer, [scriptblock]$test, $timeoutSeconds, $label) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        $s = Get-SibState $peer
        if ((& $test $s.db) -and (& $test $s.ui)) { return $true }
        if ((Get-Date) -ge $deadline) { Add-Note "$peer never reached '$label' within ${timeoutSeconds}s"; return $false }
        Start-Sleep -Seconds 2
    }
}

function Test-Server($view, $name) { return @($view.servers) -contains $name }
function Get-FriendStatus($view, $id) {
    $row = @($view.friends) | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($row) { return "$($row.status)" } return ''
}
function Test-Blocked($view, $id) { return @($view.blocked) -contains $id }

function Shot($peer, $name) { Soft $peer @{ op = 'shot'; name = "mdsib-$runTag-$name" } 60 | Out-Null }

function Get-LogLines($peer, $pattern) { return @((Invoke-PeerCommand $peer 'log_grep' @{ pattern = $pattern }).lines) }

# Lines logged at or after $epoch (a Windows peer's log outlives runs).
function Get-LogLinesSince($peer, $pattern, $epoch) {
    return @(Get-LogLines $peer $pattern | Where-Object { -not ("$_" -match '^\[(\d{9,})\]') -or [int64]$Matches[1] -ge $epoch })
}

function Get-PeerStatus($peer) { return (Invoke-PeerCommand $peer 'status') }
function Stop-Peer($peer) { Invoke-PeerFleet @($peer) @('-Stop') }
function Start-PeerOnData($peer) { Invoke-PeerFleet @($peer) @('-Live', '-ReuseData', '-KeepOthers') }

# --------------------------------------------------------------------------
# The friend cycle with -Other: one step per cell, in order
# --------------------------------------------------------------------------

# Each step: what the actor (and -Other) do, and what the away device must end
# up showing; $script:Phase moves on after each cell.
$script:Phase = 0
function Invoke-FriendStep($actor, $tag) {
    switch ($script:Phase % 4) {
        0 {
            # -Other's removal crossing the actor's new request would wipe it (a removal
            # inside the clock-skew window clears the row), so remove only when -Other
            # still lists us, and let the removal land before asking.
            if (Get-FriendStatus (Get-SibState $O).db $script:MH) {
                Soft $O @{ op = 'friend'; action = 'remove'; contact = $script:MH } 60 | Out-Null
                Wait-Both $actor { param($v) (Get-FriendStatus $v $script:MO) -eq '' } 60 'the removal by -Other reached the actor' | Out-Null
                Start-Sleep -Seconds 3
            }
            Step $actor @{ op = 'friend'; action = 'request'; contact = $script:MO } | Out-Null
            Wait-Both $O { param($v) (Get-FriendStatus $v $script:MH) -eq 'pending' } 90 'the request reached -Other' | Out-Null
            Step $O @{ op = 'friend'; action = 'accept'; contact = $script:MH } | Out-Null
            return @(@{ op = 'add_friend'; test = { param($v) (Get-FriendStatus $v $script:MO) -eq 'accepted' } })
        }
        1 {
            Step $actor @{ op = 'friend'; action = 'remove'; contact = $script:MO } | Out-Null
            Step $actor @{ op = 'friend'; action = 'block'; contact = $script:MO } | Out-Null
            return @(
                @{ op = 'remove_friend'; test = { param($v) (Get-FriendStatus $v $script:MO) -ne 'accepted' } },
                @{ op = 'block'; test = { param($v) Test-Blocked $v $script:MO } })
        }
        2 {
            Step $actor @{ op = 'friend'; action = 'unblock'; contact = $script:MO } | Out-Null
            Soft $O @{ op = 'friend'; action = 'remove'; contact = $script:MH } 60 | Out-Null
            Step $O @{ op = 'friend'; action = 'request'; contact = $script:MH } | Out-Null
            Wait-Both $actor { param($v) (Get-FriendStatus $v $script:MO) -eq 'pending' } 90 'the request from -Other reached the actor' | Out-Null
            Step $actor @{ op = 'friend'; action = 'accept'; contact = $script:MO } | Out-Null
            return @(
                @{ op = 'unblock'; test = { param($v) -not (Test-Blocked $v $script:MO) } },
                @{ op = 'accept_friend'; test = { param($v) (Get-FriendStatus $v $script:MO) -eq 'accepted' } })
        }
        3 {
            Step $actor @{ op = 'friend'; action = 'remove'; contact = $script:MO } | Out-Null
            return @(@{ op = 'remove_friend'; test = { param($v) (Get-FriendStatus $v $script:MO) -ne 'accepted' } })
        }
    }
}

# --------------------------------------------------------------------------
# One cell: $actor acts while $away is in $state
# --------------------------------------------------------------------------

$script:FriendServers = New-Object System.Collections.ArrayList
$script:DmTexts = New-Object System.Collections.ArrayList
$script:OwnServers = New-Object System.Collections.ArrayList
$script:CellIndex = 0

function Invoke-Cell($dir, $state, $actor, $away) {
    $script:CellIndex++
    $script:CellRc0 = [int]$script:FleetAgentReconnects
    $k = $script:CellIndex
    $tag = "$runTag$k"
    $cell = "$dir-$state"
    $names = @{ create = "mdC-$tag"; join = "mdJ-$tag"; leave = "mdLv-$tag"; delete = "mdDl-$tag" }
    $profileName = "md $dir $state $tag"
    $dmOut = "md out $tag"; $dmIn = "md in $tag"
    Say "cell $cell (#$k): $actor acts, $away is $state"

    # ---- preconditions, both devices up ----------------------------------
    Step $F @{ op = 'seed_server'; name = $names.leave; as = "INV_LV$k" } | Out-Null
    [void]$script:FriendServers.Add($names.leave)
    Step $actor @{ op = 'seed_join'; invite = ('${INV_LV' + $k + '}') } | Out-Null
    Step $actor @{ op = 'seed_server'; name = $names.delete; as = "INV_DL$k" } | Out-Null
    Step $F @{ op = 'seed_server'; name = $names.join; as = "INV_J$k" } | Out-Null
    [void]$script:FriendServers.Add($names.join)
    $pre = { param($v) (Test-Server $v $names.leave) -and (Test-Server $v $names.delete) }
    $ready = (Wait-Both $actor $pre 120 "$cell precondition on the actor") -and (Wait-Both $away $pre 120 "$cell precondition on the away device")
    if (-not $ready) {
        Add-Row $dir $state 'precondition' 'FAIL' '' 'servers made before the trip never reached both devices'
        Shot $away "$cell-precondition"
        return
    }
    $heldMap = @((Get-SibState $away).db.server_ids.PSObject.Properties)
    $heldBefore = @($heldMap | ForEach-Object { "$($_.Value)" })

    # ---- away ---------------------------------------------------------------
    $awaySeconds = 0
    # Before it leaves: Android freezes a backgrounded app, which then answers no step.
    if ($state -in @('Online', 'Background')) { Step $away @{ op = 'select_server'; name = $script:HomeName } | Out-Null }
    switch ($state) {
        'Background' { Step $away @{ op = 'background' } | Out-Null; $awaySeconds = $BackgroundSeconds }
        'Closed1m' { Stop-Peer $away; $awaySeconds = $ShortAwaySeconds }
        'Closed10m' { Stop-Peer $away; $awaySeconds = $LongAwaySeconds }
    }
    $wentAway = Get-Date

    # ---- the actor's ops ------------------------------------------------------
    $opsAt = Get-Date
    Step $actor @{ op = 'seed_server'; name = $names.create; as = "INV_C$k" } | Out-Null
    [void]$script:OwnServers.Add($names.create)
    Step $actor @{ op = 'seed_join'; invite = ('${INV_J' + $k + '}') } | Out-Null
    Step $actor @{ op = 'server_leave'; name = $names.leave } | Out-Null
    Step $actor @{ op = 'seed_delete_server'; name = $names.delete } | Out-Null
    Step $actor @{ op = 'profile'; name = $profileName } | Out-Null
    Step $actor @{ op = 'friend'; action = 'dm'; contact = $script:MF; text = $dmOut } | Out-Null
    Step $F @{ op = 'friend'; action = 'dm'; contact = $script:MH; text = $dmIn } | Out-Null
    [void]$script:DmTexts.Add($dmOut); [void]$script:DmTexts.Add($dmIn)
    $checks = @(
        @{ op = 'create'; test = { param($v) Test-Server $v $names.create } },
        @{ op = 'join'; test = { param($v) Test-Server $v $names.join } },
        @{ op = 'leave'; test = { param($v) -not (Test-Server $v $names.leave) } },
        @{ op = 'delete'; test = { param($v) -not (Test-Server $v $names.delete) } },
        @{ op = 'profile'; test = { param($v) "$($v.name)" -eq $profileName } },
        @{ op = 'dm_both_ways'; dbOnly = $true; test = { param($v) ($v.PSObject.Properties.Name -contains 'dm_missing') -and @($v.dm_missing).Count -eq 0 } }
    ) + @(Invoke-FriendStep $actor $tag)
    $script:Phase++
    $dmFields = @{ contact = $script:MF; texts = @($dmOut, $dmIn) }
    $actorOk = $false
    $actorDeadline = (Get-Date).AddSeconds(120)
    while ($true) {
        $mine = Get-SibState $actor $dmFields
        if (@($checks | Where-Object { -not (Test-Check $_ $mine) }).Count -eq 0) { $actorOk = $true; break }
        if ((Get-Date) -ge $actorDeadline) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $actorOk) { Add-Note "${cell}: the actor itself never showed every result (see shots)"; Shot $actor "$cell-actor" }

    # ---- back -----------------------------------------------------------------
    if ($awaySeconds -gt 0) {
        $left = $awaySeconds - [int]((Get-Date) - $wentAway).TotalSeconds
        if ($left -gt 0) { Say "  $away stays away ${left}s more"; Start-Sleep -Seconds $left }
    }
    $backEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
    $returning = Get-Date
    switch ($state) {
        'Background' { Step $away @{ op = 'foreground' } | Out-Null }
        'Closed1m' { Start-PeerOnData $away }
        'Closed10m' { Start-PeerOnData $away }
    }
    if ($state -ne 'Online') { Wait-Connected $away 240 }
    if ($state -like 'Closed*') { Step $away @{ op = 'select_server'; name = $script:HomeName } | Out-Null }
    # Seconds count from the op (Online) or from the moment the device starts coming back.
    $from = if ($state -eq 'Online') { $opsAt } else { $returning }

    # ---- converge -------------------------------------------------------------
    $doneAt = @{}
    $deadline = (Get-Date).AddSeconds($ConvergeSeconds)
    $last = $null
    while ($true) {
        $last = Get-SibState $away $dmFields
        foreach ($c in $checks) {
            if ($doneAt.ContainsKey($c.op)) { continue }
            if (Test-Check $c $last) { $doneAt[$c.op] = Get-SecondsSince $from }
        }
        if ($doneAt.Count -eq $checks.Count -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 2
    }
    $last | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence "$cell-away.json") -Encoding UTF8
    foreach ($c in $checks) {
        if ($doneAt.ContainsKey($c.op)) { Add-Row $dir $state $c.op 'PASS' $doneAt[$c.op] }
        else {
            $dbOk = & $c.test $last.db
            $why = if ($dbOk) { 'in the database, never on screen' } else { 'never arrived' }
            Add-Row $dir $state $c.op 'FAIL' '' $why
        }
    }
    Shot $away "$cell-back"

    # Gate F: nothing the away device held before the trip is "joined" again.
    $rejoined = @(Get-LogLinesSince $away 'Server join completed:' $backEpoch | Where-Object {
        $line = "$_"; @($heldBefore | Where-Object { $line.Contains($_) }).Count -gt 0 })
    Add-Row $dir $state 'no_rejoin_of_held' $(if ($rejoined.Count -eq 0) { 'PASS' } else { 'FAIL' }) '' $(if ($rejoined.Count) { $rejoined[0] } else { '' })
    # What the person sees: no "Joined X" toast for a server held before the trip.
    # The toast line names its server by id only (never the name).
    $toasts = @(Get-LogLinesSince $away '[HOLLOW-TOAST] joined ' $backEpoch)
    $stray = @($toasts | Where-Object { $line = "$_"; @($heldBefore | Where-Object { $line.Contains("joined $_") }).Count -gt 0 })
    Add-Row $dir $state 'no_joined_toast_for_held' $(if ($stray.Count -eq 0) { 'PASS' } else { 'FAIL' }) '' $(if ($stray.Count) { $stray[0] } else { "$($toasts.Count) Joined toast(s) for new servers" })

    # A server a sibling joined or made lists quietly; the screen stays where it was.
    $selected = "$((Get-SibState $away).ui.selected)"
    Add-Row $dir $state 'selection_kept' $(if ($selected -eq $script:HomeName) { 'PASS' } else { 'FAIL' }) '' $(if ($selected -ne $script:HomeName) { "selected '$selected'" } else { '' })

    # The device that came back undid nothing the actor did.
    Start-Sleep -Seconds 10
    $mine = Get-SibState $actor $dmFields
    $undone = @($checks | Where-Object { -not (Test-Check $_ $mine) } | ForEach-Object { $_.op })
    Add-Row $dir $state 'actor_kept_all' $(if ($undone.Count -eq 0) { 'PASS' } else { 'FAIL' }) '' $(if ($undone.Count) { "undone: $($undone -join ', ')" } else { '' })
}

# A desktop of the pair loses its database and keeps its identity (a repair, a
# reinstall): its sibling gives the friend back, and every row the friend signs,
# synced or live, lands; none is refused as from a device of nobody's.
function Invoke-LostDb($peer) {
    $script:CellRc0 = [int]$script:FleetAgentReconnects
    Say "cell lostdb: $peer loses its database and keeps its identity"
    $texts = @($script:DmTexts)
    Stop-Peer $peer
    $dir = Join-Path $env:TEMP "hollow_fleet\run\$(Get-Letter $peer)"
    $dbs = @(Get-ChildItem -LiteralPath $dir -Filter 'messages.db*' -ErrorAction SilentlyContinue)
    if ($dbs.Count -eq 0) { Add-Row 'lostdb' 'restart' 'database_removed' 'FAIL' '' "no messages.db in $dir"; return }
    $dbs | Remove-Item -Force
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
    $back = Get-Date
    Start-PeerOnData $peer
    Wait-Connected $peer 240
    $friendBack = Wait-Both $peer { param($v) (Get-FriendStatus $v $script:MF) -eq 'accepted' } $ConvergeSeconds 'the friend back after a lost database'
    Add-Row 'lostdb' 'restart' 'friend_back' $(if ($friendBack) { 'PASS' } else { 'FAIL' }) $(if ($friendBack) { Get-SecondsSince $back } else { '' })
    $missing = @($texts)
    $deadline = (Get-Date).AddSeconds($ConvergeSeconds)
    while ($true) {
        $missing = @((Get-SibState $peer @{ contact = $script:MF; texts = $texts }).db.dm_missing)
        if ($missing.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 2
    }
    Add-Row 'lostdb' 'restart' 'dm_history' $(if ($missing.Count -eq 0) { 'PASS' } else { 'FAIL' }) $(if ($missing.Count -eq 0) { Get-SecondsSince $back } else { '' }) $(if ($missing.Count) { "missing $($missing.Count) of $($texts.Count): $($missing[0])" } else { "$($texts.Count) rows" })
    $live = "md lostdb $runTag"
    $sent = Get-Date
    Step $F @{ op = 'friend'; action = 'dm'; contact = $script:MH; text = $live } | Out-Null
    $got = $false
    $deadline = (Get-Date).AddSeconds($ConvergeSeconds)
    while (-not $got -and (Get-Date) -lt $deadline) {
        $got = @((Get-SibState $peer @{ contact = $script:MF; texts = @($live) }).db.dm_missing).Count -eq 0
        if (-not $got) { Start-Sleep -Seconds 2 }
    }
    Add-Row 'lostdb' 'restart' 'dm_live' $(if ($got) { 'PASS' } else { 'FAIL' }) $(if ($got) { Get-SecondsSince $sent } else { '' })
    # Case-sensitive and whole-word: a peer id (base58) holds "dm" often enough to
    # flag any refusal that names one.
    $rejected = @(Get-LogLinesSince $peer 'REJECTED' $epoch | Where-Object { "$_" -cmatch '\bDM\b' })
    Add-Row 'lostdb' 'restart' 'no_dm_refused' $(if ($rejected.Count -eq 0) { 'PASS' } else { 'FAIL' }) '' $(if ($rejected.Count) { "$($rejected.Count) refused, first: $($rejected[0])" } else { '' })
    Shot $peer 'lostdb-back'
}

# --------------------------------------------------------------------------
# The journey
# --------------------------------------------------------------------------

$failure = $null
Say "run ${runTag}: holder $H, linked $L, friend $F, other $O, evidence $evidence"
try {
    if (-not $ReuseLink) {
        Say 'linking: one fleet_link_matrix.ps1 cell, peers kept up'
        $linkRoot = Join-Path $evidence 'link'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fleet_link_matrix.ps1') `
            -Presenter $Holder -Receiver $Linked -Friend $Friend -KeepUp -EvidenceRoot $linkRoot
        $verdictFile = Get-ChildItem $linkRoot -Recurse -Filter 'verdict.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $verdictFile) { throw 'the link cell wrote no verdict' }
        $linkVerdict = Get-Content $verdictFile.FullName -Raw | ConvertFrom-Json
        $needed = @($linkVerdict.gates.PSObject.Properties | Where-Object { $_.Name -match '^(L\d|V1|V2|V3|V4|V7)' })
        $bad = @($needed | Where-Object { "$($_.Value)" -ne 'PASS' } | ForEach-Object { $_.Name })
        Add-Row 'link' $(if (Test-Mobile $H) { 'phone-holds' } else { 'desktop-holds' }) "$Holder -> $Linked" $(if ($bad.Count -eq 0 -and $needed.Count -gt 0) { 'PASS' } else { 'FAIL' }) $linkVerdict.link_seconds $(if ($bad.Count) { "gates: $($bad -join '; ')" } else { '' }) ([int]$linkVerdict.reconnects)
        # A failed gate stays a FAIL above; the cells still run while the pair is one
        # identity whose roster lists both devices.
        $usable = @($needed | Where-Object { $_.Name -match '^(L[1-4]|V7)' })
        if ($needed.Count -eq 0 -or @($usable | Where-Object { "$($_.Value)" -ne 'PASS' }).Count -gt 0) {
            throw "the link did not give a working pair ($($verdictFile.FullName))"
        }
    } else {
        foreach ($peer in @($H, $L, $F)) { Start-PeerOnData $peer }
    }
    foreach ($peer in @($H, $L, $F)) { Wait-Connected $peer }

    Say 'minting a fresh identity for -Other'
    Invoke-PeerFleet @($O) @('-Onboard', '-Fresh', '-KeepOthers')
    Invoke-PeerFleet @($O) @('-Live', '-KeepOthers')
    Wait-Connected $O
    $sH = Get-SibState $H; $sL = Get-SibState $L
    $script:MH = "$($sH.master)"; $script:MF = "$((Get-SibState $F).master)"; $script:MO = "$((Get-SibState $O).master)"
    if (-not $script:MH -or "$($sL.master)" -ne $script:MH) { throw "the pair is not one identity: holder $($sH.master), linked $($sL.master)" }
    if ((Get-FriendStatus $sH.db $script:MF) -ne 'accepted') { throw 'the holder is not friends with -Friend (the link cell seeds that)' }
    Say "identity $($script:MH), friend $($script:MF), other $($script:MO)"

    # One server both devices keep all run: the away device selects it, and a
    # sibling's join or create must never move that selection.
    $script:HomeName = "mdHome-$runTag"
    Step $H @{ op = 'seed_server'; name = $script:HomeName } | Out-Null
    [void]$script:OwnServers.Add($script:HomeName)
    $homeHeld = { param($v) Test-Server $v $script:HomeName }
    if (-not ((Wait-Both $H $homeHeld 120 'home server') -and (Wait-Both $L $homeHeld 120 'home server'))) { throw 'the home server never reached both devices' }
    $states = @('Online')
    $plan = @()
    foreach ($dir in @('fwd', 'rev')) {
        $actor = if ($dir -eq 'fwd') { $H } else { $L }
        $away = if ($dir -eq 'fwd') { $L } else { $H }
        $cellStates = @('Online')
        if (Test-Mobile $away) { $cellStates += 'Background' }
        $cellStates += 'Closed1m'
        if (-not $Quick) { $cellStates += 'Closed10m' }
        foreach ($st in $cellStates) { $plan += , @($dir, $st, $actor, $away) }
    }
    $wanted = @($Only -split '[,\s]+' | Where-Object { $_ })
    foreach ($p in $plan) {
        if ($wanted.Count -and -not ($wanted -contains "$($p[0])-$($p[1])")) { continue }
        try { Invoke-Cell $p[0] $p[1] $p[2] $p[3] }
        catch {
            Add-Row $p[0] $p[1] 'cell' 'FAIL' '' "$($_.Exception.Message)"
            foreach ($peer in @($p[2], $p[3])) { Shot $peer "$($p[0])-$($p[1])-$(Get-Letter $peer)-at-failure" }
            # A device left closed by a failed cell comes back for the next one.
            try { if (-not (Get-PeerStatus $p[3]).live) { Start-PeerOnData $p[3]; Wait-Connected $p[3] 240 } } catch { }
        }
    }
    $lostPeer = @($L, $H) | Where-Object { (Get-Platform $_) -eq 'win' } | Select-Object -First 1
    if ($SkipLostDb -or -not $lostPeer) { Say 'the lost-database cell is skipped' }
    else {
        try { Invoke-LostDb $lostPeer }
        catch { Add-Row 'lostdb' 'restart' 'cell' 'FAIL' '' "$($_.Exception.Message)"; Shot $lostPeer 'lostdb-at-failure' }
    }
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
    foreach ($peer in $all) { try { Shot $peer "$(Get-Letter $peer)-at-failure" } catch { } }
}


# --------------------------------------------------------------------------
# Cleanup, evidence, summary
# --------------------------------------------------------------------------
foreach ($name in @($script:OwnServers)) {
    $gone = $false
    foreach ($peer in @($H, $L)) { if ((Soft $peer @{ op = 'seed_delete_server'; name = $name } 60).ok) { $gone = $true; break } }
    if (-not $gone) { Add-Note "cleanup: $name was not deleted" }
}
foreach ($name in @($script:FriendServers)) {
    if (-not (Soft $F @{ op = 'seed_delete_server'; name = $name } 60).ok) { Add-Note "cleanup: $name was not deleted" }
}

# A peer on another machine keeps its evidence in that machine's tree.
foreach ($peer in $all) {
    $dest = if (Test-RemotePeer $peer) { "$(Get-FleetRemoteTree (Get-RemotePeer $peer).Agent)/.team/md_sibling/$runTag/$(Get-Letter $peer)" } else { Join-Path $evidence (Get-Letter $peer) }
    try {
        Invoke-PeerCommand $peer 'evidence' @{ dest = $dest } 300 | Out-Null
        if (Test-RemotePeer $peer) { Add-Note "evidence of $peer is on its machine at $dest" }
    } catch { Add-Note "evidence of ${peer}: $($_.Exception.Message)" }
}
$refusals = New-Object System.Collections.ArrayList
foreach ($peer in $all) {
    foreach ($pattern in @('[HOLLOW-SECURITY]', 'REJECT', 'Refused', 'refused', 'DROPPED', 'BLOCKED', 'Dropped')) {
        try { foreach ($line in (Get-LogLinesSince $peer $pattern $startEpoch)) { [void]$refusals.Add("$peer $line") } } catch { }
    }
}
@($refusals | Select-Object -Unique) | Set-Content (Join-Path $evidence 'refusals.txt') -Encoding UTF8

$failed = @($script:Rows | Where-Object { $_.verdict -eq 'FAIL' }).Count
$verdict = if ($failure -or $failed -gt 0 -or $script:Rows.Count -eq 0) { 'FAIL' } else { 'PASS' }
$duration = [int]((Get-Date) - $started).TotalSeconds
Write-Host ''
Write-Host "===== sibling sync: $Holder holds, $Linked linked =====" -ForegroundColor Cyan
$script:Rows | Format-Table dir, state, op, verdict, seconds, rc, note -AutoSize | Out-String -Width 220 | Write-Host
foreach ($r in @($script:FleetAgentReconnectLog)) { if ($r) { [void]$script:Notes.Add("agent reconnect: $r") } }
foreach ($note in $script:Notes) { Write-Host "  note: $note" -ForegroundColor DarkCyan }
$passed = @($script:Rows | Where-Object { $_.verdict -eq 'PASS' }).Count
Write-Host "  $verdict ($passed passed, $failed failed) in ${duration}s, evidence $evidence" -ForegroundColor $(if ($verdict -eq 'PASS') { 'Green' } else { 'Red' })

[ordered]@{
    run = $runTag; holder = $Holder; linked = $Linked; friend = $Friend; other = $Other; quick = [bool]$Quick
    verdict = $verdict; seconds = $duration; reconnects = [int]$script:FleetAgentReconnects; rows = @($script:Rows); notes = @($script:Notes)
    error = $(if ($failure) { "$($failure.Exception.Message)" } else { '' })
} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $evidence 'summary.json') -Encoding UTF8

if (-not $KeepUp) { foreach ($peer in $all) { try { Invoke-PeerFleet @($peer) @('-Stop') } catch { } } }
Stop-FleetAgents
if ($verdict -ne 'PASS') { exit 1 }
exit 0
