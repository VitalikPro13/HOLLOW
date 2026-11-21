# A server lives on its owner's relay (#151, HOL-SEC-211), proven through real
# instances on two test relays, driven from the Mac (pwsh):
#
#   pwsh -NoProfile -File scripts/fleet_home_relay.ps1 -Phase setup
#   pwsh -NoProfile -File scripts/fleet_home_relay.ps1 -Phase h1   (then h2 ... h5, phone, legacy, upgrade)
#
# Peers: windows:a owner, windows:b member, android:a phone member (c), windows:d a
# stranger on relay Y; windows:e / windows:f a legacy owner and member (H6), built from
# main for the legacy phase (FLEET_PC_TREE = the base tree) and upgraded after.
# Relay X = hollowtest.duckdns.org, relay Y = hollowtest.duckdns.org:8443 (a second
# relay on the test VM, no access keys). State between phases: .team/fleet/state.json.
param(
    [ValidateSet('setup', 'h1', 'phone', 'phone2', 'h2', 'h3', 'h4', 'h5', 'legacy', 'legacychat', 'upgrade', 'look', 'grep', 'phoneinvite', 'phonerestart', 'p4', 'settingsshot', 'cleanup')]
    [string]$Phase = 'setup',
    [string]$RelayX = 'hollowtest.duckdns.org',
    [string]$RelayY = 'hollowtest.duckdns.org:8443',
    [string]$BaseTree = 'D:\dev\wt\sec-0142-base',
    [string]$LookPeer = '',
    [string]$Pattern = '',
    [switch]$Onboard,
    # With -Onboard: build and stage the Windows probe target first (up to 90 min).
    [switch]$Build
)
if ($args.Count -gt 0) { throw "unrecognised argument(s): $($args -join ' ')" }

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
$env:FLEET_BACKEND = 'macos'
$env:FLEET_RELAY = $RelayX
$env:FLEET_RELAY_ALSO = "$RelayX,$RelayY"
if ($Phase -like 'legacy*') { $env:FLEET_PC_TREE = $BaseTree } else { Remove-Item Env:FLEET_PC_TREE -ErrorAction SilentlyContinue }
$script:FleetRepo = $repo
$script:FleetStageRoot = Join-Path $repo 'build/fleet'
$script:FleetOutRoot = Join-Path $repo 'build/fleet_out'
$runTag = Get-Date -Format 'HHmmss'
$script:FleetVars = @{ RUN = $runTag }
. (Join-Path $repo 'scripts/fleet_lib.ps1')

$A = Register-FleetPeer 'windows:a'
$B = Register-FleetPeer 'windows:b'
$C = Register-FleetPeer 'android:a'
$D = Register-FleetPeer 'windows:d'
$E = Register-FleetPeer 'windows:e'
$F = Register-FleetPeer 'windows:f'
$team = Join-Path $repo '.team/fleet'
$stateFile = Join-Path $team 'state.json'
$evidence = Join-Path $team "run-$runTag-$Phase"
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
Start-Transcript -Path (Join-Path $evidence 'driver.log') | Out-Null
$adb = Join-Path $HOME 'Library/Android/sdk/platform-tools/adb'

function Say($m, $c = 'Cyan') { Write-Host ("[{0}] [home] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor $c }
$script:Results = [ordered]@{}
function Gate($name, $ok, $detail = '') {
    $script:Results[$name] = if ($ok) { "PASS $detail" } else { "FAIL $detail" }
    Say ("{0} {1} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail) $(if ($ok) { 'Green' } else { 'Red' })
}

function Load-State {
    if (Test-Path $stateFile) { return (Get-Content -Raw $stateFile | ConvertFrom-Json -AsHashtable) }
    return @{}
}
function Save-State($s) { $s | ConvertTo-Json -Depth 6 | Set-Content -Path $stateFile -Encoding utf8 }
$S = Load-State

function Step($peer, [hashtable]$h, $timeout = 180) {
    $ans = Send-FleetStep $peer ([pscustomobject]$h) $timeout
    Write-FleetAnswer $peer $ans
    if (-not $ans.ok -and -not $h.soft) { throw "step failed on ${peer}: $($h.op) $($h.target) :: $($ans.message)" }
    return $ans
}
function Try-Step($peer, [hashtable]$h, $timeout = 60) {
    $h.soft = $true
    try { return (Step $peer $h $timeout) } catch { Say "soft step threw on ${peer}: $($_.Exception.Message)" 'Yellow'; return $null }
}
function Has($peer, $target, $ms = 3000) {
    $r = Try-Step $peer @{ op = 'wait_for'; target = $target; timeout_ms = $ms } ([int]($ms / 1000) + 30)
    return [bool]($r -and $r.ok)
}
function Shot($peer, $name) {
    Try-Step $peer @{ op = 'shot'; name = "hr-$name" } | Out-Null
    Try-Step $peer @{ op = 'dump'; name = "hr-$name" } | Out-Null
    if ($peer -eq $C) {
        # A phone's out dir is emptied by its next launch: copy each shot off at once.
        try { Invoke-PeerCommand $C 'sync_out' | Out-Null } catch { }
        $dest = Join-Path $team 'shots/phone'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Get-ChildItem (Join-Path $repo 'build/fleet_out/a') -Filter "hr-$name*" -ErrorAction SilentlyContinue | Copy-Item -Destination $dest -Force
    }
}
function Wait-Connected($peer, $ms = 120000) {
    Step $peer @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = $ms } ([int]($ms / 1000) + 30) | Out-Null
}
function Get-Provider($peer, $key) {
    $as = 'CAP_' + ($key.ToUpper())
    Step $peer @{ op = 'capture'; from = 'provider'; key = $key; as = $as } | Out-Null
    return "$($script:FleetVars[$as])"
}
function Get-State($peer, $server = '', $tag = '') {
    $h = @{ op = 'link_state' }
    if ($server) { $h.server = $server; $h.tag = $tag }
    return (Step $peer $h 90).state
}
function Wait-ChannelTexts($peer, $server, $texts, $seconds = 120) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $have = @()
    while ((Get-Date) -lt $deadline) {
        $st = Get-State $peer $server $runTag
        $have = @($st.channel.texts)
        $missing = @($texts | Where-Object { $have -notcontains $_ })
        if ($missing.Count -eq 0) { return $true }
        Start-Sleep -Seconds 4
    }
    Say "$peer is missing: $(@($texts | Where-Object { $have -notcontains $_ }) -join ' | ')" 'Red'
    return $false
}
function Wait-Server($peer, $server, $seconds = 180) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $st = Get-State $peer
        if (@($st.servers) -contains $server) { return $true }
        Start-Sleep -Seconds 4
    }
    return $false
}
function Unix-Now { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
# App log lines naming `pattern`, written at or after `since` (unix seconds).
function Get-LogSince($peer, $pattern, $since) {
    $r = Invoke-PeerCommand $peer 'log_grep' @{ pattern = $pattern }
    if ($null -ne $r.result) { $r = $r.result }
    return @($r.lines | Where-Object { $_ -match '^\[(\d+)\]' -and [int64]$Matches[1] -ge ($since - 5) })
}
function Get-Status($peer) {
    $r = Invoke-PeerCommand $peer 'status'
    if ($null -ne $r.result) { $r = $r.result }
    return $r
}
function Invite-From($invite) {
    if ("$invite" -match 'server=([0-9a-fA-F]+)') { return $Matches[1].ToLower() }
    throw "no server id in '$invite'"
}
function Relay-Of($invite) {
    if ("$invite" -match '[#&?]relay=([^&]+)') { return [uri]::UnescapeDataString($Matches[1]) }
    return ''
}

# The invite as the Invite people dialog shows it, once it carries the join key.
function Get-UiInvite($peer, $name, $as, $seconds = 90) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ($true) {
        Try-Step $peer @{ op = 'key'; value = 'escape' } | Out-Null
        Step $peer @{ op = 'wait_for'; target = "server:$name"; timeout_ms = 60000 } | Out-Null
        Step $peer @{ op = 'right_click'; target = "server:$name" } | Out-Null
        Step $peer @{ op = 'tap'; target = 'menu > text:Invite people' } | Out-Null
        Step $peer @{ op = 'wait_for'; target = 'type:HollowCopyField'; timeout_ms = 20000 } | Out-Null
        Step $peer @{ op = 'capture'; target = 'type:HollowCopyField'; as = $as } | Out-Null
        $inv = "$($script:FleetVars[$as])"
        if ($inv -match 'key=' -or (Get-Date) -gt $deadline) { break }
        Try-Step $peer @{ op = 'tap'; target = 'dialog > semantics:Close'; index = 0 } | Out-Null
        Start-Sleep -Seconds 5
    }
    return $inv
}
function Close-Invite($peer) {
    Try-Step $peer @{ op = 'tap'; target = 'dialog > semantics:Close'; index = 0 } | Out-Null
    Try-Step $peer @{ op = 'key'; value = 'escape' } | Out-Null
}

# A desktop peer taps whatever relaunches it; we hand its mailbox over and wait for the new pid.
function Wait-Relaunch($peer, $before, [scriptblock]$tap) {
    try { & $tap } catch { Say "relaunch tap did not answer (expected): $($_.Exception.Message)" 'Yellow' }
    finally { Invoke-PeerCommand $peer 'mailbox' | Out-Null }
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $s = Get-Status $peer
        if ([int]$s.pid -gt 0 -and [int]$s.pid -ne $before -and $s.live) { Say "$peer relaunched: $before -> $($s.pid)" 'Green'; return }
        Start-Sleep -Milliseconds 700
    }
    Say "$peer did not come back in 120 s: stop + live -ReuseData" 'Yellow'
    Invoke-PeerFleet @($peer) @('-Stop')
    Invoke-PeerFleet @($peer) @('-Live', '-ReuseData', '-KeepOthers')
}

# A phone's switch closes the app; the fleet starts it again on its data.
function Wait-PhoneBack($peer, [scriptblock]$tap) {
    try { & $tap } catch { Say "phone switch tap did not answer (expected): $($_.Exception.Message)" 'Yellow' }
    Start-Sleep -Seconds 4
    Invoke-PeerFleet @($peer) @('-Live', '-ReuseData', '-KeepOthers')
}

# Settings > Network > Change > Add a relay, up to the Switch button. Returns whether the
# owner note was on screen.
function Open-RelayPicker($peer, $target, $label, [switch]$Phone) {
    Try-Step $peer @{ op = 'key'; value = 'escape' } | Out-Null
    Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 } | Out-Null
    if (-not $Phone) { Step $peer @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 20000 } | Out-Null }
    $net = if ($Phone) { 'text:Network' } else { 'type:SettingsPlace > text:Network' }
    Step $peer @{ op = 'reveal'; target = $net; index = 0; soft = $true } | Out-Null
    Step $peer @{ op = 'tap'; target = $net; index = 0 } | Out-Null
    Step $peer @{ op = 'wait_for'; target = 'text:Change'; timeout_ms = 10000 } | Out-Null
    Step $peer @{ op = 'tap'; target = 'text:Change'; index = 0 } | Out-Null
    Step $peer @{ op = 'wait_for'; target = 'text:Add a relay'; timeout_ms = 10000 } | Out-Null
    if (Has $peer "text:$target" 1500) {
        # Added on an earlier switch: choose it from the list.
        Step $peer @{ op = 'tap'; target = "text:$target"; index = 0 } | Out-Null
    } else {
        Step $peer @{ op = 'tap'; target = 'text:Add a relay'; index = 0 } | Out-Null
        Step $peer @{ op = 'wait_for'; target = 'hint:relay.example.com'; timeout_ms = 10000 } | Out-Null
        Step $peer @{ op = 'enter_text'; target = 'hint:relay.example.com'; value = $target } | Out-Null
        Step $peer @{ op = 'tap'; target = 'text:Add'; index = 0 } | Out-Null
    }
    $switch = if ($Phone) { 'text:Switch and close' } else { 'text:Switch and restart' }
    if ($Phone) {
        for ($i = 0; $i -lt 4 -and -not (Has $peer $switch 1500); $i++) {
            Try-Step $peer @{ op = 'scroll'; target = 'type:Scrollable'; index = 0; dy = -300 } | Out-Null
        }
    }
    Step $peer @{ op = 'wait_for'; target = $switch; timeout_ms = 10000 } | Out-Null
    Step $peer @{ op = 'reveal'; target = $switch; index = 0; soft = $true } | Out-Null
    Step $peer @{ op = 'wait'; ms = 800 } | Out-Null
    Shot $peer "$label-settings"
    $note = Try-Step $peer @{ op = 'expect_text'; value = 'Servers you own stay on' } 30
    return [bool]($note -and $note.ok)
}

function Switch-Desktop($peer, $target, $label) {
    $note = Open-RelayPicker $peer $target $label
    $before = [int](Get-Status $peer).pid
    Wait-Relaunch $peer $before { Step $peer @{ op = 'tap'; target = 'text:Switch and restart'; index = 0; frames = 5 } 30 | Out-Null }
    Wait-Connected $peer
    $now = Get-Provider $peer 'relayDomain'
    if ($now -ne $target) { throw "$peer is on '$now', expected '$target'" }
    Say "$peer is on $now" 'Green'
    return $note
}

function Open-General($peer, $server) {
    Try-Step $peer @{ op = 'key'; value = 'escape' } | Out-Null
    Try-Step $peer @{ op = 'tap'; target = 'semantics:Close settings'; index = 0 } | Out-Null
    Step $peer @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 60000 } | Out-Null
    Step $peer @{ op = 'open_server'; name = $server } | Out-Null
    Step $peer @{ op = 'open_channel'; name = 'general' } | Out-Null
    Step $peer @{ op = 'wait'; ms = 1500 } | Out-Null
}


function Open-PhoneGeneral($name) {
    Try-Step $C @{ op = 'tap'; target = 'semantics:Back'; index = 0 } | Out-Null
    Step $C @{ op = 'tap'; target = 'semantics:Chats'; index = 0 } | Out-Null
    Step $C @{ op = 'wait_for'; target = "text:$name"; timeout_ms = 30000 } | Out-Null
    Step $C @{ op = 'tap'; target = "text:$name"; index = 0 } | Out-Null
    Step $C @{ op = 'wait'; ms = 1500 } | Out-Null
    $g = Try-Step $C @{ op = 'tap'; target = 'text:general'; index = 0 }
    if (-not ($g -and $g.ok)) { Step $C @{ op = 'look' } | Out-Null }
    Step $C @{ op = 'wait'; ms = 2000 } | Out-Null
}
function Phone-Notice {
    $name = $S.server
    Open-PhoneGeneral $name

    $seen = Has $C 'text:This server lives on another relay.' 20000
    Shot $C 'phone-notice'
    & $adb -s emulator-5554 shell settings put system font_scale 2.0
    Step $C @{ op = 'wait'; ms = 2500 } | Out-Null
    Shot $C 'phone-notice-x2'
    & $adb -s emulator-5554 shell settings put system font_scale 1.0
    Step $C @{ op = 'wait'; ms = 1500 } | Out-Null
    $noComposer = -not (Has $C 'field' 1500)
    Gate 'P2 phone shows the notice in place of the composer' ($seen -and $noComposer) "notice=$seen composerGone=$noComposer"
    Step $C @{ op = 'tap'; target = 'text:Switch relay'; index = 0 } | Out-Null
    Step $C @{ op = 'wait_for'; target = 'dialog > text:This server lives on another relay'; timeout_ms = 10000 } | Out-Null
    Shot $C 'phone-switch-dialog'
    Wait-PhoneBack $C { Step $C @{ op = 'tap'; target = 'dialog > text:Switch and close app'; index = 0; frames = 5 } 30 | Out-Null }
    Wait-Connected $C
    $now = Get-Provider $C 'relayDomain'
    Gate 'P3 phone back on X through the notice' ($now -eq $RelayX) $now
    $t = "phone back on X $runTag"
    Step $C @{ op = 'seed_channel'; server = $name; text = $t } | Out-Null
    Gate 'P4 phone posts reach the owner again' (Wait-ChannelTexts $A $name @($t)) ''
}

$verdict = 'NOT REACHED'
try {
    switch ($Phase) {
        'grep' {
            foreach ($p in ($LookPeer -split ',')) {
                $peer = if ($p -eq 'c') { $C } else { "windows:$p" }
                $r = Invoke-PeerCommand $peer 'log_grep' @{ pattern = $Pattern }
                if ($null -ne $r.result) { $r = $r.result }
                Write-Host "=== $peer ($(@($r.lines).Count) lines)"
                @($r.lines) | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
            }
        }
        'phoneinvite' {
            Try-Step $C @{ op = 'tap'; target = 'semantics:Back'; index = 0 } | Out-Null
            Step $C @{ op = 'tap'; target = 'semantics:Chats'; index = 0 } | Out-Null
            Step $C @{ op = 'long_press'; target = "text:$($S.server)"; index = 0 } | Out-Null
            Step $C @{ op = 'wait'; ms = 1000 } | Out-Null
            Step $C @{ op = 'tap'; target = 'text:Invite people'; index = 0 } | Out-Null
            Step $C @{ op = 'wait_for'; target = 'type:HollowCopyField'; timeout_ms = 20000 } | Out-Null
            Step $C @{ op = 'capture'; target = 'type:HollowCopyField'; as = 'INVITE_C' } | Out-Null
            Shot $C 'phone-invite'
            Try-Step $C @{ op = 'tap'; target = 'dialog > semantics:Close'; index = 0 } | Out-Null
            Say "phone invite: $($script:FleetVars['INVITE_C'])"
        }
        'phonerestart' {
            Invoke-PeerFleet @($C) @('-Live', '-ReuseData', '-KeepOthers')
            Wait-Connected $C
            Say "phone on $(Get-Provider $C 'relayDomain')"
            Step $C @{ op = 'wait'; ms = 8000 } | Out-Null
        }
        'p4' {
            Invoke-PeerFleet @($A, $B) @('-Live', '-ReuseData', '-KeepOthers')
            Wait-Connected $A; Wait-Connected $B
            $name = $S.server
            $t = "phone on X again $runTag"; $ta = "owner to phone $runTag"
            Step $C @{ op = 'seed_channel'; server = $name; text = $t } | Out-Null
            Step $A @{ op = 'seed_channel'; server = $name; text = $ta } | Out-Null
            Gate 'P4 phone and owner talk both ways after the phone is back on X' ((Wait-ChannelTexts $A $name @($t)) -and (Wait-ChannelTexts $C $name @($ta)) -and (Wait-ChannelTexts $B $name @($t, $ta))) ''
        }
        'settingsshot' {
            Try-Step $A @{ op = 'key'; value = 'escape' } | Out-Null
            Step $A @{ op = 'tap'; target = 'semantics:Settings'; index = 0 } | Out-Null
            Step $A @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 20000 } | Out-Null
            Step $A @{ op = 'tap'; target = 'type:SettingsPlace > text:Network'; index = 0 } | Out-Null
            Step $A @{ op = 'tap'; target = 'text:Change'; index = 0 } | Out-Null
            Step $A @{ op = 'tap'; target = "text:$RelayY"; index = 0 } | Out-Null
            Step $A @{ op = 'wait'; ms = 800 } | Out-Null
            $r = Try-Step $A @{ op = 'expect_text'; value = 'Servers you own stay on' }
            $note = [bool]($r -and $r.ok)
            Shot $A 'owner-settings-warning'
            Gate 'S1 owner settings warning shown' $note ''
            Try-Step $A @{ op = 'key'; value = 'escape' } | Out-Null
            Try-Step $A @{ op = 'tap'; target = 'semantics:Close settings'; index = 0 } | Out-Null
            Say "a still on $(Get-Provider $A 'relayDomain')"
        }
        'cleanup' {
            Invoke-PeerFleet @($A, $B, $D, $E, $F) @('-Stop')
            Invoke-PeerFleet @($C) @('-Stop')
        }
        'look' {
            if ($LookPeer -eq 'c') { $LookPeer = $C }
            Step $LookPeer @{ op = 'look' } | Out-Null
            Shot $LookPeer "look-$runTag"
        }
        'setup' {
            if ($Onboard) {
                Say "onboarding a, b on $RelayX and d on $RelayY"
                if ($Build) { Invoke-PeerFleet @($A, $B) @('-Build', '-Onboard', '-Fresh') 5400 } else { Invoke-PeerFleet @($A, $B) @('-Onboard', '-Fresh') }
                Invoke-PeerFleet @($D) @('-Onboard', '-Fresh', '-Relay', $RelayY)
            }
            Invoke-PeerFleet @($A, $B, $D) @('-Live')
            Invoke-PeerFleet @($C) @('-Live')
            foreach ($p in @($A, $B, $C, $D)) { Wait-Connected $p }
            $S.ids = @{}
            foreach ($p in @($A, $B, $C, $D)) {
                $S.ids[$p] = Get-Provider $p 'peerId'
                Say "$p = $($S.ids[$p]) on $(Get-Provider $p 'relayDomain')"
            }
            Save-State $S
            $verdict = 'setup done'
        }
        'h1' {
            $name = "home-$runTag"
            Step $A @{ op = 'seed_server'; name = $name; as = 'INVITE_SEED' } 120 | Out-Null
            $invite = Get-UiInvite $A $name 'INVITE_A'
            Shot $A 'h1-a-invite'
            Close-Invite $A
            $S.server = $name; $S.invite_a = $invite; $S.sid = Invite-From $invite
            Save-State $S
            Gate 'H1a the owner invite names X' ((Relay-Of $invite) -eq $RelayX) $invite
            # A voice room, for the refusal in H2.
            Open-General $A $name
            Step $A @{ op = 'tap'; target = 'semantics:Create channel'; index = 0 } | Out-Null
            Step $A @{ op = 'wait_for'; target = 'dialog > text:Voice'; timeout_ms = 10000 } | Out-Null
            Step $A @{ op = 'tap'; target = 'dialog > text:Voice'; index = 0 } | Out-Null
            Step $A @{ op = 'enter_text'; target = 'dialog > type:EditableText'; value = "room-$runTag" } | Out-Null
            Step $A @{ op = 'tap'; target = 'dialog > text:Create'; index = 0 } | Out-Null
            Step $A @{ op = 'wait_for'; gone = 'dialog'; timeout_ms = 15000 } | Out-Null
            $S.voice = "room-$runTag"; Save-State $S
            Step $B @{ op = 'seed_join'; invite = $invite } 60 | Out-Null
            Step $C @{ op = 'seed_join'; invite = $invite } 60 | Out-Null
            $bIn = Wait-Server $B $name 180
            $cIn = Wait-Server $C $name 180
            Gate 'H1b b and the phone joined on X' ($bIn -and $cIn) "b=$bIn phone=$cIn"
            $ta = "h1 a to all $runTag"; $tb = "h1 b to all $runTag"; $tc = "h1 phone to all $runTag"
            Step $A @{ op = 'seed_channel'; server = $name; text = $ta } | Out-Null
            Step $B @{ op = 'seed_channel'; server = $name; text = $tb } | Out-Null
            Step $C @{ op = 'seed_channel'; server = $name; text = $tc } | Out-Null
            $okA = Wait-ChannelTexts $A $name @($tb, $tc)
            $okB = Wait-ChannelTexts $B $name @($ta, $tc)
            $okC = Wait-ChannelTexts $C $name @($ta, $tb)
            Gate 'H1c messages flow a, b, phone on X' ($okA -and $okB -and $okC) "a=$okA b=$okB phone=$okC"
            Open-General $B $name
            Shot $B 'h1-b-general'
        }
        'phone' {
            $name = $S.server
            Say 'the phone moves to Y'
            Invoke-PeerFleet @($C) @('-Live', '-ReuseData', '-KeepOthers')
            Wait-Connected $C
            $null = Open-RelayPicker $C $RelayY 'phone-to-y' -Phone
            Wait-PhoneBack $C { Step $C @{ op = 'tap'; target = 'text:Switch and close'; index = 0; frames = 5 } 30 | Out-Null }
            Wait-Connected $C
            $now = Get-Provider $C 'relayDomain'
            Gate 'P1 phone on Y' ($now -eq $RelayY) $now
            Step $C @{ op = 'wait'; ms = 5000 } | Out-Null
            Phone-Notice
        }
        'phone2' { Phone-Notice }
        'h2' {
            $name = $S.server; $sid = $S.sid
            $note = Switch-Desktop $B $RelayY 'h2-b'
            $since = Unix-Now
            Gate 'H2a no owner note for a member' (-not $note) "noteShown=$note"
            Open-General $B $name
            $seen = Has $B 'text:This server lives on another relay.' 20000
            $composer = Has $B "hint:Message #general" 1500
            Shot $B 'h2-b-notice'
            Gate 'H2b member on Y sees the notice, no composer' ($seen -and -not $composer) "notice=$seen composer=$composer"
            Step $B @{ op = 'open_channel'; name = $S.voice } | Out-Null
            $toast = Has $B 'text:This server lives on another relay. Switch relays to join its voice rooms.' 8000
            Shot $B 'h2-b-voice-toast'
            $inVc = Has $B 'semantics:Leave voice' 1000
            Gate 'H2c voice join refused with the toast' ($toast -and -not $inVc) "toast=$toast inVoice=$inVc"
            Step $B @{ op = 'wait'; ms = 20000 } | Out-Null
            $lines = Get-LogSince $B $sid $since
            $lines | Set-Content (Join-Path $evidence 'b_log_sid_after_switch.txt')
            $bad = @($lines | Where-Object { $_ -notmatch 'lives on .* not this relay: sending nothing' -and $_ -match '(?i)join lock|Peer joined|commit|Welcome|KeyPackage|JoinRoom|Sent .*to room|sync' })
            Gate 'H2d nothing for the server leaves on Y (b log)' ($bad.Count -eq 0) "lines=$($lines.Count) suspicious=$($bad.Count)"
            $S.b_on_y_since = $since; Save-State $S
        }
        'h3' {
            $name = $S.server
            $inv = Get-UiInvite $B $name 'INVITE_B'
            Shot $B 'h3-b-invite'
            Close-Invite $B
            $S.invite_b = $inv; Save-State $S
            Gate 'H3 an invite made on Y names the home X' ((Relay-Of $inv) -eq $RelayX -and (Invite-From $inv) -eq $S.sid) $inv
        }
        'h4' {
            $name = $S.server; $since = Unix-Now
            # The home-stamped invite: the switch offer names X; d cancels.
            Step $D @{ op = 'tap'; target = 'semantics:Create a server'; index = 0 } | Out-Null
            Step $D @{ op = 'wait_for'; target = 'hint:Invite link'; timeout_ms = 20000 } | Out-Null
            Step $D @{ op = 'tap'; target = 'hint:Invite link' } | Out-Null
            Step $D @{ op = 'enter_text'; target = 'hint:Invite link'; value = $S.invite_b } | Out-Null
            Step $D @{ op = 'tap'; target = 'text:Join'; index = 0 } | Out-Null
            $offer = Has $D 'dialog > text:This server lives on another relay' 30000
            $namesX = Try-Step $D @{ op = 'expect_text'; value = $RelayX }
            Shot $D 'h4-d-offer'
            Gate 'H4a d on Y is offered a switch to X' ($offer -and $namesX -and $namesX.ok) ''
            Step $D @{ op = 'tap'; target = 'dialog > text:Cancel'; index = 0 } | Out-Null
            Try-Step $D @{ op = 'key'; value = 'escape' } | Out-Null
            # A hand-made Y-stamped invite: no offer, a join ask on Y that nobody may answer.
            $enc = [uri]::EscapeDataString($RelayY)
            $yInvite = ($S.invite_b -replace '([#&?]relay=)[^&]+', "`${1}$enc")
            if ($yInvite -eq $S.invite_b) { throw "could not restamp $($S.invite_b)" }
            Say "Y invite: $yInvite"
            $S.invite_y = $yInvite; Save-State $S
            Step $D @{ op = 'seed_join'; invite = $yInvite } 60 | Out-Null
            Step $D @{ op = 'wait'; ms = 90000 } 120 | Out-Null
            $st = Get-State $D
            $member = @($st.servers) -contains $name
            Shot $D 'h4-d-after-join'
            $lines = Get-LogSince $D $S.sid $since
            $lines | Set-Content (Join-Path $evidence 'd_log_sid.txt')
            Gate 'H4b d asked on Y and is no member' (-not $member) "servers=$(@($st.servers) -join ',') loglines=$($lines.Count)"
        }
        'h5' {
            $name = $S.server
            $note = Switch-Desktop $A $RelayY 'h5-a'
            Gate 'H5a the owner is warned before switching' $note ''
            Open-General $A $name
            $owned = Has $A 'text:Your server lives on another relay. Switch back to use it.' 20000
            Shot $A 'h5-a-owner-notice'
            Gate 'H5b the owner sees its own wording on Y' $owned ''
            Step $A @{ op = 'tap'; target = 'text:Switch relay'; index = 0 } | Out-Null
            Step $A @{ op = 'wait_for'; target = 'dialog > text:This server lives on another relay'; timeout_ms = 10000 } | Out-Null
            Shot $A 'h5-a-switch-dialog'
            $before = [int](Get-Status $A).pid
            Wait-Relaunch $A $before { Step $A @{ op = 'tap'; target = 'dialog > text:Switch and restart'; index = 0; frames = 5 } 30 | Out-Null }
            Wait-Connected $A
            $aNow = Get-Provider $A 'relayDomain'
            # b goes home through its notice's button.
            Open-General $B $name
            Step $B @{ op = 'tap'; target = 'text:Switch relay'; index = 0 } | Out-Null
            Step $B @{ op = 'wait_for'; target = 'dialog > text:This server lives on another relay'; timeout_ms = 10000 } | Out-Null
            Shot $B 'h5-b-switch-dialog'
            $before = [int](Get-Status $B).pid
            Wait-Relaunch $B $before { Step $B @{ op = 'tap'; target = 'dialog > text:Switch and restart'; index = 0; frames = 5 } 30 | Out-Null }
            Wait-Connected $B
            $bNow = Get-Provider $B 'relayDomain'
            Gate 'H5c a and b back on X' ($aNow -eq $RelayX -and $bNow -eq $RelayX) "a=$aNow b=$bNow"
            $ta = "h5 a back $runTag"; $tb = "h5 b back $runTag"; $tc = "h5 phone $runTag"
            Step $A @{ op = 'seed_channel'; server = $name; text = $ta } | Out-Null
            Step $B @{ op = 'seed_channel'; server = $name; text = $tb } | Out-Null
            Step $C @{ op = 'seed_channel'; server = $name; text = $tc } | Out-Null
            $okA = Wait-ChannelTexts $A $name @($tb, $tc)
            $okB = Wait-ChannelTexts $B $name @($ta, $tc)
            $okC = Wait-ChannelTexts $C $name @($ta, $tb)
            Gate 'H5d chat restored both ways (a, b, phone)' ($okA -and $okB -and $okC) "a=$okA b=$okB phone=$okC"
            Open-General $A $name
            $composer = Has $A "hint:Message #general" 10000
            Shot $A 'h5-a-restored'
            Gate 'H5e the owner composer is back' $composer ''
            $dId = $S.ids[$D]
            $aLines = @((Invoke-PeerCommand $A 'log_grep' @{ pattern = $dId }).lines)
            $aLines | Set-Content (Join-Path $evidence 'a_log_d_id.txt')
            $st = Get-State $D
            Gate 'H5f the stranger never became a member' (-not (@($st.servers) -contains $name)) "a log lines naming d: $($aLines.Count)"
        }
        'legacy' {
            Say "legacy owner e and member f on the base build ($BaseTree)"
            if ($Onboard) { if ($Build) { Invoke-PeerFleet @($E, $F) @('-Build', '-Onboard', '-Fresh') 5400 } else { Invoke-PeerFleet @($E, $F) @('-Onboard', '-Fresh') } }
            Invoke-PeerFleet @($E, $F) @('-Live')
            Wait-Connected $E; Wait-Connected $F
            $S.ids = if ($S.ids) { $S.ids } else { @{} }
            $S.ids[$E] = Get-Provider $E 'peerId'; $S.ids[$F] = Get-Provider $F 'peerId'
            $name = "legacy-$runTag"
            Step $E @{ op = 'seed_server'; name = $name; as = 'INVITE_SEED' } 120 | Out-Null
            $inv = Get-UiInvite $E $name 'INVITE_E'
            Close-Invite $E
            $S.legacy = $name; $S.legacy_invite = $inv; $S.legacy_sid = Invite-From $inv; Save-State $S
            Step $F @{ op = 'seed_join'; invite = $inv } 60 | Out-Null
            $in = Wait-Server $F $name 180
            $t1 = "legacy e $runTag"; $t2 = "legacy f $runTag"
            Step $E @{ op = 'seed_channel'; server = $name; text = $t1 } | Out-Null
            Step $F @{ op = 'seed_channel'; server = $name; text = $t2 } | Out-Null
            $ok = (Wait-ChannelTexts $E $name @($t2)) -and (Wait-ChannelTexts $F $name @($t1))
            Gate 'H6a legacy server made and joined on the old build' ($in -and $ok) "invite=$inv"
            if ($ok) { Invoke-PeerFleet @($E, $F) @('-Stop') }
        }
        'legacychat' {
            $name = $S.legacy
            Invoke-PeerFleet @($E, $F) @('-Live', '-ReuseData')
            Wait-Connected $E; Wait-Connected $F
            Step $E @{ op = 'wait'; ms = 15000 } | Out-Null
            $t1 = "legacy e again $runTag"; $t2 = "legacy f again $runTag"
            Step $E @{ op = 'seed_channel'; server = $name; text = $t1 } | Out-Null
            Step $F @{ op = 'seed_channel'; server = $name; text = $t2 } | Out-Null
            $ok = (Wait-ChannelTexts $E $name @($t2)) -and (Wait-ChannelTexts $F $name @($t1))
            Gate 'H6a2 legacy chat both ways on the old build' $ok ''
            $st = Get-State $F $name ''
            Say ("f holds: " + (@($st.channel.texts) -join ' | '))
            if ($ok) { Invoke-PeerFleet @($E, $F) @('-Stop') }
        }
        'upgrade' {
            $name = $S.legacy; $sid = $S.legacy_sid
            $since = Unix-Now
            Invoke-PeerFleet @($E, $F) @('-Live', '-ReuseData')
            Wait-Connected $E; Wait-Connected $F
            $stamped = @()
            $deadline = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $deadline -and $stamped.Count -eq 0) {
                $stamped = @(Get-LogSince $E "$sid lives on" $since)
                if ($stamped.Count -eq 0) { Start-Sleep -Seconds 5 }
            }
            Gate 'H6b the owner names the home on its first new start' ($stamped.Count -gt 0) ($stamped -join ' / ')
            $invE = Get-UiInvite $E $name 'INVITE_E2'
            Close-Invite $E
            Gate 'H6b2 the owner invite names X' ((Relay-Of $invE) -eq $RelayX) $invE
            $note = Switch-Desktop $F $RelayY 'h6-f'
            Open-General $F $name
            $seen = Has $F 'text:This server lives on another relay.' 20000
            Shot $F 'h6-f-notice'
            Gate 'H6c a legacy member on Y gets the notice' $seen ''
            $inv = Get-UiInvite $F $name 'INVITE_F'
            Shot $F 'h6-f-invite'
            Close-Invite $F
            Gate 'H6d an invite made on Y names the stamped home X' ((Relay-Of $inv) -eq $RelayX) $inv
        }
    }
    if ($verdict -eq 'NOT REACHED') { $verdict = 'phase done' }
} catch {
    $verdict = "ERROR: $($_.Exception.Message)"
    Say $verdict 'Red'
} finally {
    try { Invoke-PeerCommand $C 'sync_out' | Out-Null } catch { }
    Stop-FleetAgents
    Say "RESULTS [$Phase]" 'Magenta'
    foreach ($k in $script:Results.Keys) { Say "  $k :: $($script:Results[$k])" 'Magenta' }
    Say "VERDICT [$Phase] $verdict" 'Magenta'
    Stop-Transcript | Out-Null
}
