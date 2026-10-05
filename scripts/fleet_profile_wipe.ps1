# A wipe on a desktop with two profiles takes only its own profile, its own
# recordings and nothing else (session 35 decisions A and B), driven across
# REAL instances.
#
#   powershell -File scripts\fleet_profile_wipe.ps1             # fresh e,f,g; build first
#   powershell -File scripts\fleet_profile_wipe.ps1 -SkipBuild  # build\fleet\a is current
#
# The two profiles never touch the real ones: the instance under test runs with
# APPDATA and USERPROFILE pointed into a scratch folder, so profiles.json and
# `Videos\Hollow Recordings` both live there. Rust accepts a recording by its
# folder's NAME, so the scratch folder is a real recordings folder to it.
#
#   profile A   a copy of g's onboarded fixture, never launched; it owns a
#               recording of its own (listed in A's recordings.list)
#   profile B   e, live, pinned active in profiles.json
#   f           a friend e calls, so e can record the call
#
# Gates
#   G1 e records a call: the file lands in the scratch folder and B's
#      recordings.list names it
#   G2 e destroys this device: the process exits and the waiter relaunches it
#      to Welcome on an empty profile
#   G3 the recordings folder keeps A's recording and a stranger's file and loses
#      only e's recording
#   G4 profiles.json keeps A and its entry, drops B, and the pin moves to A
#   G5 B's root holds no key material and no recordings.list; no debug log
#      beside the exe survives into the relaunched Welcome
#
# Windows only: the recorder and profiles are desktop features, and the journey
# reaches into the staged exe's folder.

param(
    [switch]$SkipBuild,
    [switch]$KeepUp,
    [int]$BootTimeoutSeconds = 240
)
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -SkipBuild, -KeepUp and -BootTimeoutSeconds."
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path $repoRoot 'build\fleet'
$script:FleetOutRoot = Join-Path $repoRoot 'build\fleet_out'
$script:FleetVars = @{ RUN = (Get-Date -Format 'HHmmss') }
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')
if (-not (Test-WindowsBackend)) { throw 'this journey runs on the Windows backend only' }

$runTag = $script:FleetVars.RUN
$runRoot = Join-Path $env:TEMP 'hollow_fleet\run'
$fixtureRoot = Join-Path $env:TEMP 'hollow_fleet\fixtures'
$scratch = 'D:\dev\tmp\s36-profiles'
$appData = Join-Path $scratch 'appdata'
$home2 = Join-Path $scratch 'home'
$recordings = Join-Path $home2 'Videos\Hollow Recordings'
$profileA = Join-Path $scratch 'profiles\A'
$profileB = Join-Path $runRoot 'e'
$registry = Join-Path $appData 'hollow\profiles.json'

function Say($message, $colour = 'Cyan') { Write-Host "[profile-wipe] $message" -ForegroundColor $colour }

$script:Gates = [ordered]@{
    'G1 e records a call into the scratch folder and lists it' = 'SKIP'
    'G2 e destroys this device and relaunches to Welcome'      = 'SKIP'
    'G3 only e''s recording leaves the shared folder'          = 'SKIP'
    'G4 profiles.json drops B, keeps A, pins A'                = 'SKIP'
    'G5 no keys, no recordings.list, no old debug log'         = 'SKIP'
}
$script:Notes = New-Object System.Collections.ArrayList
function Set-Gate($name, $status) { $script:Gates[$name] = $status }
function Add-Note($text) { [void]$script:Notes.Add($text); Say "note: $text" 'DarkCyan' }

function Step($peer, $step) {
    $obj = [pscustomobject]$step
    $what = @($step.target, $step.gone, $step.name, $step.value) | Where-Object { $_ } | Select-Object -First 1
    Write-Host ("  [{0}] {1} {2}" -f $peer, $step.op, $what) -ForegroundColor DarkGray
    $answer = Send-FleetStep $peer $obj 240
    Write-FleetAnswer $peer $answer '     '
    if (-not $answer.ok) { throw "[$peer] $($step.op) $what FAILED: $($answer.message)" }
}

function Invoke-SoftStep($peer, $step) {
    $obj = [pscustomobject]$step
    $answer = Send-FleetStep $peer $obj 240
    Write-FleetAnswer $peer $answer '     '
    return $answer
}

function Wait-ForConnected($peer) {
    Step $peer @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 150000 }
}

function Stop-Peer($peer) {
    $proc = Get-PeerProcess $peer
    if (-not $proc) { return }
    $proc | Stop-Process -Force
    Start-Sleep -Milliseconds 1500
}

# e runs with the scratch APPDATA and USERPROFILE; everything else is the
# fleet's usual launch. Child processes (the relaunch waiter) inherit both.
function Start-PeerProcess($peer, $dataDir, [hashtable]$extraEnv) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $script:FleetConsumed[$peer] = 0
    $saved = @{}
    $vars = @{
        HOLLOW_DATA_DIR = $dataDir; UI_PROBE_OUT = $out; UI_PROBE_MODE = 'live'; UI_PROBE_PEER = $peer
        UI_PROBE_IDLE_MINUTES = '40'; UI_PROBE_SCENARIO_FILE = ''; UI_PROBE_STEPS = ''
    }
    if ($extraEnv) { foreach ($k in $extraEnv.Keys) { $vars[$k] = $extraEnv[$k] } }
    foreach ($k in $vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process')
    }
    try {
        $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') -WorkingDirectory $dest -PassThru
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
    Say "launched $peer (pid $($proc.Id)) on $dataDir"
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { return $proc.Id }
        if ($proc.HasExited) { throw "peer $peer died on launch.`n" + (Get-CrashTail $peer) }
        Start-Sleep -Milliseconds 300
    }
    throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
}

function Reset-PeerMailbox($peer) {
    $out = Join-Path $script:FleetOutRoot $peer
    [System.IO.File]::WriteAllText((Join-Path $out 'inbox.jsonl'), '', (New-Object System.Text.UTF8Encoding($false)))
    $marker = Join-Path $out 'live-ready'
    if (Test-Path $marker) { Remove-Item $marker -Force }
    $script:FleetConsumed[$peer] = 0
}

function Get-Inventory($root) {
    if (-not (Test-Path $root)) { return @('(missing)') }
    $items = @(Get-ChildItem $root -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) { "$($_.Name)/" } else { "$($_.Name) ($($_.Length) bytes)" }
    })
    if ($items.Count -eq 0) { return @('(empty)') }
    return $items
}

# --------------------------------------------------------------------------
# Stage, onboard and lay out the two profiles
# --------------------------------------------------------------------------
if (-not $SkipBuild) { Invoke-FleetScript @('-Build', '-Peers', 'a') }
foreach ($peer in @('e', 'f', 'g')) {
    $dest = Join-Path $script:FleetStageRoot $peer
    & robocopy (Join-Path $script:FleetStageRoot 'a') $dest /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    $log = Join-Path $dest 'hollow_debug.log'
    if (Test-Path $log) { Remove-Item $log -Force }
}
Invoke-FleetScript @('-Onboard', '-Fresh', '-Peers', 'e,f,g')

if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
New-Item -ItemType Directory -Force -Path $recordings, (Split-Path $registry), $profileA | Out-Null
& robocopy (Join-Path $fixtureRoot 'g') $profileA /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
$aRecording = Join-Path $recordings 'Hollow_2026-01-01_10-00-00.mp4'
$stranger = Join-Path $recordings 'my notes.txt'
[System.IO.File]::WriteAllBytes($aRecording, [byte[]](1..200 | ForEach-Object { 7 }))
[System.IO.File]::WriteAllText($stranger, 'not Hollow''s')
[System.IO.File]::WriteAllText((Join-Path $profileA 'recordings.list'), $aRecording)

# e's data root starts as its fixture; f boots through the fleet as usual.
Invoke-FleetScript @('-Stop')
if (Test-Path $profileB) { Remove-Item $profileB -Recurse -Force }
& robocopy (Join-Path $fixtureRoot 'e') $profileB /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
$json = [ordered]@{
    version = 1; active = $profileB
    profiles = @(@{ name = 'Profile A'; path = $profileA }, @{ name = 'Profile B'; path = $profileB })
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($registry, $json, (New-Object System.Text.UTF8Encoding($false)))
Say "profiles.json before:`n$json" 'DarkGray'

$failure = $null
try {
    $fData = Join-Path $runRoot 'f'
    if (Test-Path $fData) { Remove-Item $fData -Recurse -Force }
    & robocopy (Join-Path $fixtureRoot 'f') $fData /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    Start-PeerProcess 'f' $fData $null | Out-Null
    $ePid = Start-PeerProcess 'e' $profileB @{ APPDATA = $appData; USERPROFILE = $home2 }
    Wait-ForConnected 'e'
    Wait-ForConnected 'f'
    Step f @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_F' }

    Say '1/3 e and f become friends; e calls f and records it'
    Step e @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step e @{ op = 'wait_for'; target = 'type:_FriendsManager'; timeout_ms = 15000 }
    Step e @{ op = 'tap'; target = 'type:_FriendsManager > type:_TabBar > semantics:Add friend'; index = 0 }
    Step e @{ op = 'enter_text'; target = 'hint:Paste an ID, or type a nickname'; value = '${PEER_F}' }
    Step e @{ op = 'wait_for'; target = 'type:_FriendsManager > text:${PEER_F}'; timeout_ms = 5000 }
    Step e @{ op = 'tap'; target = 'type:_FriendsManager > text:Send request'; index = 0 }
    Step f @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step f @{ op = 'wait_for'; target = 'type:_FriendsManager'; timeout_ms = 15000 }
    Step f @{ op = 'tap'; target = 'type:_FriendsManager > type:_TabBar > semantics:Requests'; index = 0 }
    Step f @{ op = 'wait_for'; target = 'type:_FriendsManager > semantics:Accept friend request'; timeout_ms = 90000 }
    Step f @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Accept friend request'; index = 0 }
    Step f @{ op = 'tap'; target = 'type:_FriendsManager > type:_TabBar > semantics:Friends'; index = 0 }
    Step f @{ op = 'wait_for'; target = 'type:_FriendsManager > text:probe-e'; timeout_ms = 90000 }
    Step f @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step e @{ op = 'tap'; target = 'type:_FriendsManager > type:_TabBar > semantics:Friends'; index = 0 }
    Step e @{ op = 'wait_for'; target = 'type:_FriendsManager > text:probe-f'; timeout_ms = 90000 }
    Step e @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step e @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
    Step e @{ op = 'tap'; target = 'type:_FriendChip > semantics:probe-f'; index = 0 }
    Step e @{ op = 'wait_for'; target = 'semantics:Start voice call'; timeout_ms = 20000 }
    Step e @{ op = 'tap'; target = 'semantics:Start voice call'; index = 0 }
    Step f @{ op = 'wait_for'; target = 'text:Accept'; timeout_ms = 45000 }
    Step f @{ op = 'tap'; target = 'text:Accept'; index = 0 }
    Step e @{ op = 'wait_for'; provider = 'callStatus'; equals = 'active'; timeout_ms = 45000 }
    # A DM call shows a compact row in the chat; the recorder lives on the stage.
    Step e @{ op = 'tap'; target = 'semantics:Open the call'; index = 0 }
    Step e @{ op = 'wait_for'; target = 'semantics:Call controls'; timeout_ms = 15000 }
    Step e @{ op = 'tap'; target = 'semantics:Call controls > semantics:More'; index = 0 }
    Step e @{ op = 'wait_for'; target = 'menu > text:Record the call'; timeout_ms = 10000 }
    Step e @{ op = 'tap'; target = 'menu > text:Record the call'; index = 0 }
    Step e @{ op = 'wait'; ms = 7000 }
    Step e @{ op = 'shot'; name = 'pw-01-recording' }
    Step e @{ op = 'tap'; target = 'semantics:Call controls > semantics:More'; index = 0 }
    Step e @{ op = 'wait_for'; target = 'menu > text:Stop recording'; timeout_ms = 10000 }
    Step e @{ op = 'tap'; target = 'menu > text:Stop recording'; index = 0 }
    # The "Recording saved" toast sits over the call bar's hang-up while it shows.
    Step e @{ op = 'wait_for'; target = 'contains:Recording saved'; timeout_ms = 15000 }
    Step e @{ op = 'wait_for'; gone = 'contains:Recording saved'; timeout_ms = 30000 }
    Step e @{ op = 'tap'; target = 'semantics:Leave the call'; index = 0 }
    Step e @{ op = 'wait_for'; provider = 'callStatus'; equals = 'idle'; timeout_ms = 30000 }

    $mine = @(Get-ChildItem $recordings -Filter 'Hollow_*.mp4' | Where-Object { $_.FullName -ne $aRecording })
    $listB = Join-Path $profileB 'recordings.list'
    $listed = if (Test-Path $listB) { [System.IO.File]::ReadAllText($listB) } else { '' }
    Say ("recordings folder: " + ((Get-Inventory $recordings) -join ', ')) 'DarkGray'
    Say "B's recordings.list: $listed" 'DarkGray'
    if ($mine.Count -eq 1 -and $mine[0].Length -gt 0 -and $listed.Contains($mine[0].FullName)) {
        Set-Gate 'G1 e records a call into the scratch folder and lists it' 'PASS'
    } else {
        Set-Gate 'G1 e records a call into the scratch folder and lists it' 'FAIL'
        throw "expected one recording of e's, listed in B: found $($mine.Count)"
    }
    $eRecording = $mine[0].FullName

    Say '2/3 e destroys this device'
    Step e @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
    Step e @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 20000 }
    Step e @{ op = 'tap'; target = 'type:SettingsPlace > text:Security'; index = 0 }
    $opened = $false
    for ($i = 0; $i -lt 14 -and -not $opened; $i++) {
        $tap = Invoke-SoftStep e @{ op = 'tap'; target = 'type:SettingsPlace > text:Destroy device'; index = 0 }
        if ($tap.ok) {
            $opened = (Invoke-SoftStep e @{ op = 'wait_for'; target = 'dialog > text:Destroy your data'; timeout_ms = 10000 }).ok
        }
        if (-not $opened) { Invoke-SoftStep e @{ op = 'scroll'; target = 'type:SettingsPlace'; dy = -400 } | Out-Null }
    }
    if (-not $opened) { throw 'e could not open the Destroy device dialog' }
    Step e @{ op = 'tap'; target = 'dialog > hint:DESTROY' }
    Step e @{ op = 'enter_text'; target = 'dialog > hint:DESTROY'; value = 'DESTROY' }
    Step e @{ op = 'shot'; name = 'pw-02-confirm' }
    # The mailbox empties AFTER the last command: the live loop keeps its read
    # position in memory, so an earlier reset hides the tap from it.
    try {
        Send-FleetStep e ([pscustomobject]@{ op = 'tap'; target = 'dialog > text:Destroy'; index = 0 }) 20 | Out-Null
    } catch {
        Say "e did not answer the Destroy tap (normal: it is gone)" 'DarkGray'
    } finally {
        Reset-PeerMailbox e
    }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and (Get-Process -Id $ePid -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }
    if (Get-Process -Id $ePid -ErrorAction SilentlyContinue) { throw "e's process was still alive 60 s after the confirm" }
    $newPid = 0
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $now = Get-PeerProcess e
        if ($now -and $now.Id -ne $ePid -and (Test-PeerLive e)) { $newPid = [int]$now.Id; break }
        Start-Sleep -Milliseconds 400
    }
    if ($newPid -eq 0) { throw 'the waiter never brought e back' }
    Step e @{ op = 'wait_for'; target = 'text:Create an identity'; timeout_ms = 90000 }
    Step e @{ op = 'shot'; name = 'pw-03-welcome' }
    Set-Gate 'G2 e destroys this device and relaunches to Welcome' 'PASS'

    Say '3/3 what the wipe left'
    $left = @(Get-ChildItem $recordings -Force | ForEach-Object { $_.FullName })
    Say ("recordings folder after: " + ((Get-Inventory $recordings) -join ', ')) 'DarkGray'
    $g3 = (Test-Path $aRecording) -and (Test-Path $stranger) -and -not (Test-Path $eRecording)
    Set-Gate 'G3 only e''s recording leaves the shared folder' ($(if ($g3) { 'PASS' } else { 'FAIL' }))

    $after = [System.IO.File]::ReadAllText($registry)
    Say "profiles.json after:`n$after" 'DarkGray'
    $reg = $after | ConvertFrom-Json
    $paths = @($reg.profiles | ForEach-Object { $_.path.ToLower().TrimEnd('\') })
    $g4 = ($paths -contains $profileA.ToLower()) -and -not ($paths -contains $profileB.ToLower()) -and
        ("$($reg.active)".ToLower().TrimEnd('\') -eq $profileA.ToLower())
    Set-Gate 'G4 profiles.json drops B, keeps A, pins A' ($(if ($g4) { 'PASS' } else { 'FAIL' }))

    $bInv = @(Get-Inventory $profileB)
    Say ("B root after: " + ($bInv -join ', ')) 'DarkGray'
    $keys = @('identity.key', 'identity.device', 'identity.duress', 'identity.dpapi', 'recordings.list', 'messages.db') |
        Where-Object { Test-Path (Join-Path $profileB $_) }
    $log = Join-Path (Join-Path $script:FleetStageRoot 'e') 'hollow_debug.log'
    $oldLog = $false
    if (Test-Path $log) {
        $text = [System.IO.File]::ReadAllText($log)
        $oldLog = $text.Contains('[HOLLOW-DESTROY]') -or $text.Contains($script:FleetVars['PEER_F'])
        Say "a debug log beside e's exe: $((Get-Item $log).Length) bytes, old lines: $oldLog" 'DarkGray'
    }
    $aInv = @(Get-Inventory $profileA)
    Say ("A root after (must be untouched): " + ($aInv -join ', ')) 'DarkGray'
    $aKept = (Test-Path (Join-Path $profileA 'identity.key')) -and (Test-Path (Join-Path $profileA 'recordings.list'))
    $g5 = ($keys.Count -eq 0) -and -not $oldLog -and $aKept
    if ($keys.Count -gt 0) { Add-Note "B still holds: $($keys -join ', ')" }
    if (-not $aKept) { Add-Note 'profile A lost its identity or its recordings.list' }
    Set-Gate 'G5 no keys, no recordings.list, no old debug log' ($(if ($g5) { 'PASS' } else { 'FAIL' }))
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
    foreach ($key in @($script:Gates.Keys)) { if ($script:Gates[$key] -eq 'SKIP') { $script:Gates[$key] = 'FAIL'; break } }
} finally {
    Write-Host ''
    foreach ($key in $script:Gates.Keys) {
        $c = switch ($script:Gates[$key]) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
        Write-Host ("  {0,-4} {1}" -f $script:Gates[$key], $key) -ForegroundColor $c
    }
    foreach ($n in $script:Notes) { Write-Host "  note: $n" -ForegroundColor DarkCyan }
    if (-not $KeepUp -and -not $failure) { foreach ($p in @('e', 'f')) { Stop-Peer $p } }
}
$failed = @($script:Gates.Values | Where-Object { $_ -ne 'PASS' }).Count
if ($failed -gt 0) { exit 1 }
