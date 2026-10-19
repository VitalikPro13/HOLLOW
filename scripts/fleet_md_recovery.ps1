# A device whose database will not open with its identity, repaired and then
# linked again, across REAL instances (tmp8 item 1).
#
#   powershell -File scripts\fleet_md_recovery.ps1 -Build      # build and stage p,q,r first
#   powershell -File scripts\fleet_md_recovery.ps1             # build\fleet\p,q,r are current
#   powershell -File scripts\fleet_md_recovery.ps1 -KeepUp     # leave the windows open
#
# Every instance runs with APPDATA, USERPROFILE and HOME pointed into a scratch
# folder: profiles.json anchors at %APPDATA%\hollow, and a relink lists its old
# data there. The real registry is hashed before and after and must not change.
#
#   p  the populated device: friend of r, DMs both ways, owns a server r is in
#   q  links to p, so it is p's sibling; then its database is swapped for r's
#   r  the friend
#
# Gates
#   G1 p and r are friends, DM both ways, server traffic both ways
#   G2 q links to p and comes back with the server and the DMs
#   G3 q, holding r's database, starts on "Hollow can't open your data on this device"
#   G4 Repair this device: q comes back on its identity, the unreadable file kept
#      byte for byte in unreadable-<day>
#   G5 q gets the server, the friend, the DM history and its name back from p
#   G6 live traffic reaches the repaired q
#   G7 broken again, Link this device again: q relaunches into Welcome with the
#      old-data line naming the folder (q runs on HOLLOW_DATA_DIR, an override,
#      so no profile lists it), its root holds no identity
#   G8 the old data sits beside q's root marked with where it came from, and no
#      profiles.json lists it (an override session never writes the list)
#   G9 q links to p again and comes back with the server
#   G10 q runs on the old data (repaired), and erasing q's root profile from
#      Settings erases the root but never the old data it is running
#   G0 the real %APPDATA%\hollow\profiles.json is untouched
#
# Windows only: profiles and the relaunch waiter are desktop features.

param(
    [switch]$Build,
    [switch]$KeepUp,
    [int]$BootTimeoutSeconds = 240
)
if ($args.Count -gt 0) {
    throw "unrecognised argument(s): $($args -join ' '). This script takes -Build, -KeepUp and -BootTimeoutSeconds."
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
$runRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'hollow_fleet\run'
$server = "fleet-recover-$runTag"
$qData = Join-Path $runRoot 'q'
$rData = Join-Path $runRoot 'r'
$scratch = Join-Path $repoRoot '.team\md-recovery-sandbox'
$appData = Join-Path $scratch 'appdata'
$home2 = Join-Path $scratch 'home'
$registry = Join-Path $appData 'hollow\profiles.json'
$evidence = Join-Path $repoRoot ".team\fleet-$runTag"
# The REAL registry, found the way Windows finds it rather than through the
# environment this script is about to change.
$realRegistry = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'hollow\profiles.json'

function Say($message, $colour = 'Cyan') { Write-Host "[md-recovery] $message" -ForegroundColor $colour }

$script:Gates = [ordered]@{
    'G1 p and r are friends, DMs and server traffic both ways'          = 'SKIP'
    'G2 q links to p and holds the server and the DMs'                  = 'SKIP'
    'G3 a foreign database shows the can''t-open-your-data screen'      = 'SKIP'
    'G4 Repair keeps the identity and the unreadable file, byte for byte' = 'SKIP'
    'G5 the server, friend, DM history and name come back from p'      = 'SKIP'
    'G6 live traffic reaches the repaired q'                            = 'SKIP'
    'G7 Link again relaunches into Welcome with the old-data line'      = 'SKIP'
    'G8 the old data is kept beside q, marked, and listed nowhere'      = 'SKIP'
    'G9 q links to p again and holds the server'                        = 'SKIP'
    'G10 erasing the root keeps the old data that is running'           = 'SKIP'
    'G0 the real profiles.json is untouched'                            = 'SKIP'
}
$script:Notes = New-Object System.Collections.ArrayList
function Set-Gate($name, $status) {
    if (-not $script:Gates.Contains($name)) { throw "unknown gate '$name'" }
    $script:Gates[$name] = $status
}
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
    if (Get-PeerProcess $peer) { throw "peer $peer did not stop" }
}

# Launches a peer on $dataDir with this script's (sandboxed) environment.
function Start-PeerProcess($peer, $dataDir) {
    $dest = Join-Path $script:FleetStageRoot $peer
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $script:FleetConsumed[$peer] = 0
    $env:HOLLOW_DATA_DIR = $dataDir
    $env:UI_PROBE_OUT = $out
    $env:UI_PROBE_MODE = 'live'
    $env:UI_PROBE_PEER = $peer
    $env:UI_PROBE_IDLE_MINUTES = '40'
    $env:UI_PROBE_SCENARIO_FILE = ''
    $env:UI_PROBE_STEPS = ''
    Wait-FleetLaunchSlot $peer
    $proc = Start-Process -FilePath (Join-Path $dest 'hollow.exe') -WorkingDirectory $dest -PassThru
    Say "launched $peer (pid $($proc.Id)) on $dataDir"
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PeerLive $peer) { return $proc.Id }
        if ($proc.HasExited) { throw "peer $peer died on launch.`n" + (Get-CrashTail $peer) }
        Start-Sleep -Milliseconds 300
    }
    throw "peer $peer never came live.`n" + (Get-CrashTail $peer)
}

# Only ever on a peer about to die: the live loop keeps its read position in memory.
function Reset-PeerMailbox($peer) {
    $out = Join-Path $script:FleetOutRoot $peer
    [System.IO.File]::WriteAllText((Join-Path $out 'inbox.jsonl'), '', (New-Object System.Text.UTF8Encoding($false)))
    $marker = Join-Path $out 'live-ready'
    if (Test-Path $marker) { Remove-Item $marker -Force }
    $script:FleetConsumed[$peer] = 0
}

function Save-Evidence($peer, $label) {
    $out = Join-Path $script:FleetOutRoot $peer
    $kept = Join-Path $evidence "$peer-$label"
    if (-not (Test-Path $out)) { return }
    New-Item -ItemType Directory -Path $kept -Force | Out-Null
    Get-ChildItem $out -File -Include *.png, *.json, *.md, *.log -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $kept -Force -ErrorAction SilentlyContinue }
}

function Wait-NewProcess($peer, $oldPid, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $now = Get-PeerProcess $peer
        if ($now -and $now.Id -ne $oldPid -and (Test-PeerLive $peer)) { Wait-FleetLaunchSlot $peer -NoWait; return [int]$now.Id }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

# Taps a control that ends the process, then hands the mailbox to its successor.
# The wait is short: the successor boots in about 10 s and reads the inbox from its
# start, so the reset must come before it does, or it replays every step.
function Invoke-FinalTap($peer, $target) {
    try {
        Send-FleetStep $peer ([pscustomobject]@{ op = 'tap'; target = $target; index = 0 }) 3 | Out-Null
    } catch {
        Say "$peer did not answer the last tap (normal: it is going)" 'DarkGray'
    } finally {
        Reset-PeerMailbox $peer
    }
}

function Get-DumpJson($peer, $name) {
    $path = Join-Path $script:FleetOutRoot "$peer\map-$name.json"
    if (-not (Test-Path $path)) { throw "no dump for $peer at $path" }
    return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-DumpBodies($peer, $name, $key) {
    $map = (Get-DumpJson $peer $name).providers.$key
    if (-not $map) { return @() }
    $bodies = @()
    foreach ($property in $map.PSObject.Properties) {
        foreach ($body in @($property.Value.last)) { if ($body) { $bodies += "$body" } }
    }
    return $bodies
}

function Open-Friends($peer) {
    Step $peer @{ op = 'tap'; target = 'semantics:Add friend'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_FriendsManager'; timeout_ms = 15000 }
}

function Close-Friends($peer) {
    Step $peer @{ op = 'tap'; target = 'type:_FriendsManager > semantics:Close'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:_FriendsManager'; timeout_ms = 10000 }
}

$script:DmComposer = @{}
function Open-Dm($peer, $friendName) {
    $chip = "type:_FriendChip > semantics:$friendName"
    Step $peer @{ op = 'wait_for'; target = $chip; timeout_ms = 90000 }
    Step $peer @{ op = 'tap'; target = $chip }
    Step $peer @{ op = 'wait'; ms = 1500 }
    $script:DmComposer[$peer] = "hint:Message $friendName"
    Step $peer @{ op = 'wait_for'; target = $script:DmComposer[$peer]; timeout_ms = 30000 }
}

function Send-Text($peer, $composer, $body) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Step $peer @{ op = 'tap'; target = $composer }
        Step $peer @{ op = 'enter_text'; target = $composer; value = $body }
        Step $peer @{ op = 'key'; value = 'enter' }
        if ((Invoke-SoftStep $peer @{ op = 'wait_for'; target = "text:$body"; timeout_ms = 20000 }).ok) { return }
        Add-Note "$peer's composer swallowed '$body' on attempt $attempt"
    }
    throw "[$peer] the composer never produced a row for '$body'"
}

function Open-SettingsDevices($peer) {
    Step $peer @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 20000 }
    Step $peer @{ op = 'tap'; target = 'type:SettingsPlace > text:Devices'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:SettingsPlace > text:Link a device'; timeout_ms = 20000 }
}

function Close-Settings($peer) {
    $open = Invoke-SoftStep $peer @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 1500 }
    if (-not $open.ok) { return }
    Invoke-SoftStep $peer @{ op = 'key'; value = 'escape' } | Out-Null
    if ((Invoke-SoftStep $peer @{ op = 'wait_for'; gone = 'type:SettingsPlace'; timeout_ms = 3000 }).ok) { return }
    Step $peer @{ op = 'tap'; target = 'semantics:Close settings'; index = 0 }
    Step $peer @{ op = 'wait_for'; gone = 'type:SettingsPlace'; timeout_ms = 10000 }
}

function Get-LinkCode($peer) {
    Step $peer @{ op = 'tap'; target = 'type:SettingsPlace > text:Link a device'; index = 0 }
    Step $peer @{ op = 'wait_for'; target = 'type:_DeviceLinkContent'; timeout_ms = 20000 }
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $answer = Invoke-SoftStep $peer @{
            op = 'capture'; target = 'type:_DeviceLinkContent'; as = 'LINKCODE_RAW'
            regex = '([A-Z2-9](?: [A-Z2-9]){5} - [A-Z2-9](?: [A-Z2-9]){3})'
        }
        if ($answer.ok) {
            $code = ($script:FleetVars['LINKCODE_RAW'] -replace '[\s-]', '')
            if ($code.Length -eq 10) { return $code }
        }
        Start-Sleep -Milliseconds 700
    }
    throw "[$peer] never rendered a 10-character link code"
}

# q walks Welcome > Link a device and enters p's code; p confirms; q relaunches
# itself to import the snapshot. Returns once q is live again on p's identity.
function Invoke-Link($label) {
    Open-SettingsDevices p
    $code = Get-LinkCode p
    Step q @{ op = 'wait_for'; target = 'text:Agree and continue'; timeout_ms = 90000 }
    Step q @{ op = 'tap'; target = 'text:Agree and continue'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'text:Create an identity'; timeout_ms = 20000 }
    Step q @{ op = 'tap'; target = 'text:Link a device'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'hint:ABC123'; timeout_ms = 180000 }
    Wait-ForConnected q
    Step q @{ op = 'enter_text'; target = 'hint:ABC123'; value = $code }
    Step q @{ op = 'wait_for'; target = "text:$code"; timeout_ms = 15000 }
    Step q @{ op = 'tap'; target = 'text:Link'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'text:Linking this device'; timeout_ms = 45000 }
    Step p @{ op = 'wait_for'; target = 'text:Add this device?'; timeout_ms = 60000 }
    Step p @{ op = 'tap'; target = 'text:Add device'; index = 0 }
    Step p @{ op = 'wait_for'; target = 'text:Data sent'; timeout_ms = 180000 }
    Step q @{ op = 'wait_for'; target = 'text:Linked'; timeout_ms = 120000 }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-$label-linked" }
    $old = (Get-PeerProcess q).Id
    Save-Evidence q "$label-pre-relaunch"
    Reset-PeerMailbox q
    Step p @{ op = 'tap'; target = 'text:Done'; index = 0 }
    Step p @{ op = 'wait_for'; gone = 'type:_DeviceLinkContent'; timeout_ms = 15000 }
    Close-Settings p
    $new = Wait-NewProcess q $old 120
    if ($new -eq 0) { throw "q did not relaunch itself after the $label link" }
    Wait-ForConnected q
    if (-not (Close-LockOffer q)) { Add-Note "q's first start after the $label link offered no lock" }
    Step q @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_Q' }
    if ($script:FleetVars['PEER_Q'] -ne $script:FleetVars['PEER_P']) {
        throw "q's identity after the $label link is $($script:FleetVars['PEER_Q']), p's is $($script:FleetVars['PEER_P'])"
    }
}

# Stops q and puts r's database in place of its own: a file that is there and
# does not open with q's identity.
function Set-ForeignDatabase {
    Stop-Peer q
    foreach ($n in @('messages.db-wal', 'messages.db-shm')) {
        $f = Join-Path $qData $n
        if (Test-Path $f) { Remove-Item $f -Force }
    }
    Copy-Item (Join-Path $rData 'messages.db') (Join-Path $qData 'messages.db') -Force
    $script:ForeignHash = (Get-FileHash (Join-Path $qData 'messages.db') -Algorithm SHA256).Hash
    Say "q now holds r's database ($script:ForeignHash)" 'DarkGray'
}

function Show-TroubleScreen($label) {
    Start-PeerProcess q $qData | Out-Null
    Step q @{ op = 'wait_for'; target = "text:Hollow can't open your data on this device"; timeout_ms = 90000 }
    Step q @{ op = 'expect_text'; value = 'Repair this device' }
    Step q @{ op = 'expect_text'; value = 'Link this device again' }
    Step q @{ op = 'expect_text'; value = 'Copy diagnostics' }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-$label-screen" }
}

# --------------------------------------------------------------------------
# Build, sandbox, onboard
# --------------------------------------------------------------------------
$realBefore = if (Test-Path $realRegistry) { (Get-FileHash $realRegistry -Algorithm SHA256).Hash } else { '(none)' }
if ($Build) { Invoke-FleetScript @('-Build', '-Peers', 'p,q,r') }

if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Split-Path $registry), $home2, $evidence | Out-Null
# From here every process this script starts, fleet.ps1 and each instance,
# inherits the sandbox.
$env:APPDATA = $appData
$env:USERPROFILE = $home2
$env:HOME = $home2
# Windows PowerShell under a moved profile writes its module cache into the working folder.
$env:PSModuleAnalysisCachePath = Join-Path $scratch 'ModuleAnalysisCache'

Start-FreshFleet @('p', 'r')
Invoke-FleetScript @('-Stop', '-Peers', 'q')
Get-ChildItem $runRoot -Directory -Filter 'q-old-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
if (Test-Path $qData) { Remove-Item $qData -Recurse -Force }

$failure = $null
$serverCreated = $false
try {
    Wait-ForConnected p
    Wait-ForConnected r
    Step p @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_P' }
    Step r @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_R' }

    Say '1 p and r become friends, DM both ways and share a server'
    Open-Friends p
    Step p @{ op = 'tap'; target = 'type:_FriendsManager > type:_TabBar > semantics:Add friend'; index = 0 }
    Step p @{ op = 'enter_text'; target = 'hint:Paste an ID, or type a nickname'; value = '${PEER_R}' }
    Step p @{ op = 'wait_for'; target = 'text:${PEER_R}'; timeout_ms = 15000 }
    Step p @{ op = 'tap'; target = 'text:Send request'; index = 0 }
    Open-Friends r
    Step r @{ op = 'tap'; target = 'type:_FriendsManager > type:_TabBar > semantics:Requests'; index = 0 }
    Step r @{ op = 'wait_for'; target = 'semantics:Accept friend request'; timeout_ms = 90000 }
    Step r @{ op = 'tap'; target = 'semantics:Accept friend request'; index = 0 }
    Step p @{ op = 'wait_for'; target = 'text:probe-r'; timeout_ms = 90000 }
    Step r @{ op = 'wait_for'; target = 'text:probe-p'; timeout_ms = 90000 }
    Close-Friends p
    Close-Friends r
    Open-Dm p 'probe-r'
    Send-Text p $script:DmComposer['p'] 'dm p to r ${RUN}'
    Step r @{ op = 'wait_for'; target = 'text:dm p to r ${RUN}'; timeout_ms = 90000 }
    Open-Dm r 'probe-p'
    Send-Text r $script:DmComposer['r'] 'dm r to p ${RUN}'
    Step p @{ op = 'wait_for'; target = 'text:dm r to p ${RUN}'; timeout_ms = 90000 }

    Step p @{ op = 'tap'; target = 'semantics:Create a server' }
    Step p @{ op = 'enter_text'; target = 'hint:My Awesome Server'; value = $server }
    Step p @{ op = 'tap'; target = 'text:Create'; index = 0 }
    Step p @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 30000 }
    $serverCreated = $true
    Step p @{ op = 'open_server'; name = $server }
    Step p @{ op = 'wait_for'; target = 'channel:general'; timeout_ms = 30000 }
    Step p @{ op = 'right_click'; target = "server:$server" }
    Step p @{ op = 'tap'; target = 'menu > text:Invite people' }
    Step p @{ op = 'wait_for'; target = 'type:HollowCopyField'; timeout_ms = 20000 }
    Step p @{ op = 'capture'; target = 'type:HollowCopyField'; as = 'INVITE' }
    Step p @{ op = 'key'; value = 'escape' }
    Step r @{ op = 'tap'; target = 'semantics:Create a server' }
    Step r @{ op = 'enter_text'; target = 'hint:Invite link'; value = '${INVITE}' }
    Step r @{ op = 'tap'; target = 'text:Join'; index = 0 }
    Step r @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 120000 }
    Step r @{ op = 'open_server'; name = $server }
    Step r @{ op = 'open_channel'; name = 'general' }
    Step p @{ op = 'open_channel'; name = 'general' }
    Send-Text p 'hint:Message #general' 'ch p before ${RUN}'
    Step r @{ op = 'wait_for'; target = 'text:ch p before ${RUN}'; timeout_ms = 90000 }
    Send-Text r 'hint:Message #general' 'ch r before ${RUN}'
    Step p @{ op = 'wait_for'; target = 'text:ch r before ${RUN}'; timeout_ms = 90000 }
    Set-Gate 'G1 p and r are friends, DMs and server traffic both ways' 'PASS'

    Say '2 q boots empty and links to p'
    Start-PeerProcess q $qData | Out-Null
    Invoke-Link 'first'
    Step q @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 120000 }
    Open-Dm q 'probe-r'
    Step q @{ op = 'wait_for'; target = 'text:dm r to p ${RUN}'; timeout_ms = 90000 }
    Step q @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'Q_DEVICE' }
    Set-Gate 'G2 q links to p and holds the server and the DMs' 'PASS'

    Say '3 q gets r''s database and starts'
    Set-ForeignDatabase
    Show-TroubleScreen 'repair'
    Set-Gate 'G3 a foreign database shows the can''t-open-your-data screen' 'PASS'

    Say '4 Repair this device'
    $keyBefore = (Get-FileHash (Join-Path $qData 'identity.key') -Algorithm SHA256).Hash
    Step q @{ op = 'tap'; target = 'text:Repair this device'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'dialog > text:Repair this device?'; timeout_ms = 15000 }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-repair-dialog" }
    Step q @{ op = 'tap'; target = 'dialog > text:Repair'; index = 0 }
    Step q @{ op = 'wait_for'; gone = 'dialog > text:Repair this device?'; timeout_ms = 60000 }
    Invoke-SoftStep q @{ op = 'wait_for'; target = 'contains:This device is repaired'; timeout_ms = 15000 } | Out-Null
    Step q @{ op = 'shot'; name = "rec-$runTag-q-repaired-toast" }
    Wait-ForConnected q
    Step q @{ op = 'capture'; from = 'provider'; key = 'peerId'; as = 'PEER_Q2' }
    Step q @{ op = 'capture'; from = 'provider'; key = 'devicePeerId'; as = 'Q_DEVICE2' }
    $aside = @(Get-ChildItem $qData -Directory -Filter 'unreadable-*')
    $keptDb = if ($aside.Count -eq 1) { Join-Path $aside[0].FullName 'messages.db' } else { '' }
    $keptHash = if ($keptDb -and (Test-Path $keptDb)) { (Get-FileHash $keptDb -Algorithm SHA256).Hash } else { '' }
    $keyAfter = (Get-FileHash (Join-Path $qData 'identity.key') -Algorithm SHA256).Hash
    Say "aside: $($aside.Name -join ', '); kept db hash $keptHash" 'DarkGray'
    $g4 = ($script:FleetVars['PEER_Q2'] -eq $script:FleetVars['PEER_P']) -and
        ($script:FleetVars['Q_DEVICE2'] -eq $script:FleetVars['Q_DEVICE']) -and
        ($keptHash -eq $script:ForeignHash) -and ($keyAfter -eq $keyBefore)
    if (-not $g4) { throw "after the repair: identity $($script:FleetVars['PEER_Q2']), device $($script:FleetVars['Q_DEVICE2']) (was $($script:FleetVars['Q_DEVICE'])), kept $keptHash, key same $($keyAfter -eq $keyBefore)" }
    Set-Gate 'G4 Repair keeps the identity and the unreadable file, byte for byte' 'PASS'

    Say '5 q gets its data back from p'
    Step q @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 180000 }
    Step q @{ op = 'open_server'; name = $server }
    Step q @{ op = 'open_channel'; name = 'general' }
    $history = Invoke-SoftStep q @{ op = 'wait_for'; target = 'text:ch r before ${RUN}'; timeout_ms = 120000 }
    if (-not $history.ok) { Add-Note 'the #general history before the repair did not come back within 120 s' }
    Open-Dm q 'probe-r'
    Step q @{ op = 'wait_for'; target = 'text:dm r to p ${RUN}'; timeout_ms = 120000 }
    Step q @{ op = 'wait_for'; target = 'text:dm p to r ${RUN}'; timeout_ms = 60000 }
    $named = Invoke-SoftStep q @{ op = 'wait_for'; target = 'text:probe-p'; timeout_ms = 60000 }
    if (-not $named.ok) { Add-Note 'q did not show its own name probe-p after the repair' }
    Step q @{ op = 'dump'; name = 'repaired' }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-repaired" }
    $friends = @((Get-DumpJson q 'repaired').providers.friends)
    $rowR = @($friends | Where-Object { $_ -and $_.peerId -eq $script:FleetVars['PEER_R'] }) | Select-Object -First 1
    if (-not $rowR -or $rowR.status -ne 'accepted') { throw "q has no accepted friend row for r after the repair" }
    Set-Gate 'G5 the server, friend, DM history and name come back from p' ($(if ($history.ok -and $named.ok) { 'PASS' } else { 'WARN' }))

    Say '6 live traffic reaches the repaired q'
    Open-Dm r 'probe-p'
    Send-Text r $script:DmComposer['r'] 'dm r after repair ${RUN}'
    $dm = Invoke-SoftStep q @{ op = 'wait_for'; target = 'text:dm r after repair ${RUN}'; timeout_ms = 90000 }
    Step r @{ op = 'open_server'; name = $server }
    Step r @{ op = 'open_channel'; name = 'general' }
    Step q @{ op = 'open_server'; name = $server }
    Step q @{ op = 'open_channel'; name = 'general' }
    Send-Text r 'hint:Message #general' 'ch r after repair ${RUN}'
    $ch = Invoke-SoftStep q @{ op = 'wait_for'; target = 'text:ch r after repair ${RUN}'; timeout_ms = 90000 }
    Send-Text q 'hint:Message #general' 'ch q after repair ${RUN}'
    $back = Invoke-SoftStep r @{ op = 'wait_for'; target = 'text:ch q after repair ${RUN}'; timeout_ms = 90000 }
    if (-not $dm.ok) { Add-Note 'r''s DM after the repair did not reach q' }
    if (-not $ch.ok) { Add-Note 'r''s #general post after the repair did not reach q' }
    if (-not $back.ok) { Add-Note 'q''s #general post after the repair did not reach r' }
    Set-Gate 'G6 live traffic reaches the repaired q' ($(if ($dm.ok -and $ch.ok -and $back.ok) { 'PASS' } else { 'FAIL' }))
    Save-Evidence q 'repaired'

    Say '7 q breaks again and links again'
    Set-ForeignDatabase
    Show-TroubleScreen 'relink'
    Step q @{ op = 'tap'; target = 'text:Link this device again'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'dialog > text:Link this device again?'; timeout_ms = 15000 }
    Step q @{ op = 'wait_for'; target = 'dialog > contains:new folder next to'; timeout_ms = 5000 }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-relink-dialog" }
    Save-Evidence q 'relink-dialog'
    $old = (Get-PeerProcess q).Id
    Invoke-FinalTap q 'dialog > text:Link again'
    $new = Wait-NewProcess q $old 120
    if ($new -eq 0) { throw 'q did not relaunch after Link again' }
    Step q @{ op = 'wait_for'; target = 'contains:Your old data is in '; timeout_ms = 90000 }
    $keptNow = @(Get-ChildItem $runRoot -Directory -Filter 'q-old-*')
    if ($keptNow.Count -ne 1) { throw "expected one kept folder after Link again, found $($keptNow.Count)" }
    Step q @{ op = 'wait_for'; target = "contains:$($keptNow[0].FullName)"; timeout_ms = 5000 }
    Step q @{ op = 'expect_text'; value = 'Agree and continue' }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-welcome" }
    $rootLeft = @(Get-ChildItem $qData -Force | ForEach-Object { $_.Name })
    Say "q root after the relink: $($rootLeft -join ', ')" 'DarkGray'
    if ($rootLeft -contains 'identity.key' -or $rootLeft -contains 'messages.db') { throw 'q''s root still holds an identity or a database after Link again' }
    Set-Gate 'G7 Link again relaunches into Welcome with the old-data line' 'PASS'

    $kept = @(Get-ChildItem $runRoot -Directory -Filter 'q-old-*')
    $origin = if ($kept.Count -eq 1) { Get-Content (Join-Path $kept[0].FullName 'relink_origin.json') -Raw | ConvertFrom-Json } else { $null }
    $reg = if (Test-Path $registry) { Get-Content $registry -Raw | ConvertFrom-Json } else { $null }
    $listed = @($reg.profiles | Where-Object { $_ -and $kept.Count -eq 1 -and $_.path.TrimEnd('\').ToLower() -eq $kept[0].FullName.ToLower() })
    Say "kept: $($kept.Name -join ', '); origin $($origin.root); listed as '$($listed.name)'" 'DarkGray'
    $g8 = ($kept.Count -eq 1) -and $origin -and ($origin.root.TrimEnd('\').ToLower() -eq $qData.ToLower()) -and
        (Test-Path (Join-Path $kept[0].FullName 'identity.key')) -and
        ((Get-FileHash (Join-Path $kept[0].FullName 'messages.db') -Algorithm SHA256).Hash -eq $script:ForeignHash) -and
        ($listed.Count -eq 0)
    Set-Gate 'G8 the old data is kept beside q, marked, and listed nowhere' ($(if ($g8) { 'PASS' } else { 'FAIL' }))

    Say '9 q links to p again'
    Invoke-Link 'second'
    Step q @{ op = 'wait_for'; target = "server:$server"; timeout_ms = 120000 }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-relinked" }
    Open-SettingsDevices p
    $three = Invoke-SoftStep p @{ op = 'wait_for'; target = 'type:_DeviceRow'; count = 3; timeout_ms = 60000 }
    Step p @{ op = 'shot'; name = "rec-$runTag-p-devices" }
    if (-not $three.ok) { Add-Note 'p did not list three devices (p, the old q, the new q)' }
    Close-Settings p
    Set-Gate 'G9 q links to p again and holds the server' 'PASS'

    Say '10 q runs on its old data and erases its root profile'
    Stop-Peer q
    $oldData = $kept[0].FullName
    $oldKey = (Get-FileHash (Join-Path $oldData 'identity.key') -Algorithm SHA256).Hash
    # The root as a listed profile, so Settings offers to erase it.
    $listJson = @{ profiles = @(@{ name = 'q root'; path = $qData }) } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($registry, $listJson, (New-Object System.Text.UTF8Encoding($false)))
    Start-PeerProcess q $oldData | Out-Null
    Step q @{ op = 'wait_for'; target = "text:Hollow can't open your data on this device"; timeout_ms = 90000 }
    Step q @{ op = 'tap'; target = 'text:Repair this device'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'dialog > text:Repair this device?'; timeout_ms = 15000 }
    Step q @{ op = 'tap'; target = 'dialog > text:Repair'; index = 0 }
    Step q @{ op = 'wait_for'; gone = 'dialog > text:Repair this device?'; timeout_ms = 60000 }
    Wait-ForConnected q
    # The sibling's server share selects the server when it lands and closes any
    # open Settings with it; let it land first (it may not come at all).
    Invoke-SoftStep q @{ op = 'wait_for'; target = 'text:Message #general'; timeout_ms = 45000 } | Out-Null
    Step q @{ op = 'wait'; ms = 3000 }
    Step q @{ op = 'tap'; target = 'semantics:Settings'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'type:SettingsPlace'; timeout_ms = 20000 }
    Step q @{ op = 'tap'; target = 'type:SettingsPlace > text:Files & storage'; index = 0 }
    Step q @{ op = 'reveal'; target = 'semantics:More for q root'; index = 0 }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-profiles" }
    Step q @{ op = 'tap'; target = 'semantics:More for q root'; index = 0 }
    Step q @{ op = 'tap'; target = 'menu > text:Erase'; index = 0 }
    Step q @{ op = 'wait_for'; target = 'dialog > text:Erase profile'; timeout_ms = 15000 }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-erase-dialog" }
    Step q @{ op = 'tap'; target = 'dialog > text:Erase profile'; index = 1 }
    Step q @{ op = 'wait_for'; gone = 'dialog > text:Erase profile'; timeout_ms = 60000 }
    Start-Sleep -Seconds 3
    $rootKeyLeft = Test-Path (Join-Path $qData 'identity.key')
    $oldKeyNow = if (Test-Path (Join-Path $oldData 'identity.key')) { (Get-FileHash (Join-Path $oldData 'identity.key') -Algorithm SHA256).Hash } else { '' }
    $alive = [bool](Get-PeerProcess q)
    $stillUp = if ($alive) { (Invoke-SoftStep q @{ op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 30000 }).ok } else { $false }
    Step q @{ op = 'shot'; name = "rec-$runTag-q-after-erase" }
    Say "root key left $rootKeyLeft; old data key same $($oldKeyNow -eq $oldKey); q alive $alive, connected $stillUp" 'DarkGray'
    $g10 = (-not $rootKeyLeft) -and ($oldKeyNow -eq $oldKey) -and (Test-Path (Join-Path $oldData 'relink_origin.json')) -and $alive -and $stillUp
    Set-Gate 'G10 erasing the root keeps the old data that is running' ($(if ($g10) { 'PASS' } else { 'FAIL' }))
} catch {
    $failure = $_
    Say "FAILED: $($_.Exception.Message)" 'Red'
    foreach ($key in @($script:Gates.Keys)) { if ($script:Gates[$key] -eq 'SKIP') { $script:Gates[$key] = 'FAIL'; break } }
} finally {
    foreach ($peer in @('p', 'q', 'r')) { Save-Evidence $peer 'end' }
    if ($serverCreated -and -not $failure) {
        try {
            Step p @{ op = 'right_click'; target = "server:$server" }
            Step p @{ op = 'tap'; target = 'menu > text:Server settings' }
            Step p @{ op = 'reveal'; target = 'text:Delete server'; index = 0 }
            Step p @{ op = 'tap'; target = 'text:Delete server'; index = 0 }
            Step p @{ op = 'tap'; target = 'dialog > text:Delete server'; index = 0 }
            Step p @{ op = 'wait_for'; gone = "server:$server"; timeout_ms = 60000 }
        } catch { Add-Note "cleanup could not delete ${server}: $($_.Exception.Message)" }
    }
    if (-not $KeepUp -and -not $failure) {
        foreach ($p in @('p', 'q', 'r')) { Stop-Peer $p }
        Get-ChildItem $runRoot -Directory -Filter 'q-old-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    }
    $realAfter = if (Test-Path $realRegistry) { (Get-FileHash $realRegistry -Algorithm SHA256).Hash } else { '(none)' }
    Set-Gate 'G0 the real profiles.json is untouched' ($(if ($realAfter -eq $realBefore) { 'PASS' } else { 'FAIL' }))
    Write-Host ''
    foreach ($key in $script:Gates.Keys) {
        $c = switch ($script:Gates[$key]) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
        Write-Host ("  {0,-4} {1}" -f $script:Gates[$key], $key) -ForegroundColor $c
    }
    foreach ($n in $script:Notes) { Write-Host "  note: $n" -ForegroundColor DarkCyan }
    Write-Host "  evidence: $evidence"
}
$failed = @($script:Gates.Values | Where-Object { $_ -eq 'FAIL' }).Count
if ($failed -gt 0) { exit 1 }
