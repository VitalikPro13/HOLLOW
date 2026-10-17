# Peers on OTHER machines in one journey: the Mac lead drives exe copies on the
# Windows PC, a Windows driver an Android emulator or iOS Simulator on the Mac
# mini or a macOS desktop copy there, either one a headless Linux copy on the
# build VM, exactly as each drives its own copies. Dot-sourced by fleet_lib.ps1.
#
# A remote peer is named `<platform>:<letter>` (windows:a, android:a, ios:b,
# macos:c, linux:d); a bare letter, or a platform this machine's backend runs, is
# a peer of this machine. Send-FleetStep routes a remote name to an AGENT: one
# detached server per machine and backend (fleet_remote_agent.ps1 -Serve), which
# runs the same fleet_lib code there, reached through one ssh connection
# (scripts/fleet_agent_attach.sh, fleet_agent_attach.ps1 on the PC); on the mini
# itself a mini agent is the same server reached without ssh. The server outlives the
# connection: a dropped one is re-opened with backoff and the request in flight sent
# again under the same key, which the server answers from its record when it already
# ran it, so a tap or a send never repeats. Values a step captures come back and
# expand into later steps on any machine, which is how a link code shown on a phone
# is typed on a desktop.
#
# Every per-peer action a journey needs beyond steps (start empty, restart on
# its data, reset the mailbox around a self-relaunch, read a stash file, copy
# evidence off) is ONE command vocabulary, Invoke-FleetPeerCommand, run locally
# for a local peer and by the agent for a remote one.
#
# The remote tree has this worktree's folder name: D:\dev\wt\<name> on the PC
# (FLEET_PC_TREE), ~/wt/<name> on the mini and the VM (FLEET_MINI_TREE,
# FLEET_VM_TREE, FLEET_REMOTE_TREE for all three); ship it first with
# scripts/pc_sync.sh, scripts/mini_sync.sh or scripts/vm_sync.sh. Hosts:
# FLEET_PC_SSH (default pc, the LAN alias; pc-ts is Tailscale), FLEET_MINI_SSH
# (default jabun@100.80.56.79, its Tailscale address: the LAN lease moves; checked
# against the mini's own host key) and
# FLEET_VM_SSH (default hollowvm).

$script:FleetRemotePeers = @{}
$script:FleetAgents = @{}
# Names this driver process to the agents: a server another driver left behind is
# replaced, and request keys never meet an earlier driver's answers.
$script:FleetAgentSession = -join (1..12 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
$script:FleetAgentNext = 0
$script:FleetAgentReconnects = 0
$script:FleetAgentReconnectLog = New-Object System.Collections.ArrayList
# How long a lost agent connection is retried before the request fails.
$script:FleetAgentRetrySeconds = 180

# --------------------------------------------------------------------------
# Per-peer commands, on whichever machine the peer lives
# --------------------------------------------------------------------------

# Where a non-Android peer's data directory is on this machine.
function Get-FleetPeerDataDir($peer) {
    if (Test-SimBackend $peer) { return Get-SimDataDir (Get-SimUdid $peer) }
    if (Test-LinuxBackend) { return Join-Path (Join-Path (Get-LinuxFleetHome) 'run') $peer }
    if (Test-MacBackend) { return Join-Path (Get-MacRunRoot) $peer }
    return Join-Path (Join-Path $env:TEMP 'hollow_fleet\run') $peer
}

# The size of a file in the peer's data directory, -1 when there is none.
function Get-PeerDataFileSize($peer, $name) {
    if ($name -notmatch '^[A-Za-z0-9_.\-]+$') { throw "not a plain file name: $name" }
    if (Test-AndroidBackend $peer) {
        $size = "$(Invoke-AppShell $peer "stat -c %s $($script:AndroidDocs)/hollow/$name 2>/dev/null || echo -1")".Trim()
        if ($size -notmatch '^-?\d+$') { return -1 }
        return [int64]$size
    }
    $path = Join-Path (Get-FleetPeerDataDir $peer) $name
    if (Test-Path -LiteralPath $path) { return (Get-Item -LiteralPath $path).Length }
    return -1
}

# Hands a peer's out directory to the copy of the app that replaces it. The
# probe replays the whole INBOX from line 0 on boot and `live-ready` is a file,
# so a self-relaunch would re-run every earlier step and a stale marker makes a
# dead peer look alive. Only for a peer that is about to die: a running probe
# keeps its read position in memory, and an emptied inbox wedges it.
function Clear-PeerMailbox($peer) {
    if (Test-AndroidBackend $peer) {
        Invoke-AppShell $peer "true > $($script:AndroidDocs)/probe_out/inbox.jsonl; rm -f $($script:AndroidDocs)/probe_out/live-ready" | Out-Null
    } else {
        $out = Join-Path $script:FleetOutRoot $peer
        [System.IO.File]::WriteAllText((Join-Path $out 'inbox.jsonl'), '', (New-Object System.Text.UTF8Encoding($false)))
        $marker = Join-Path $out 'live-ready'
        if (Test-Path $marker) { Remove-Item $marker -Force }
    }
    $script:FleetConsumed[$peer] = 0
}

# Copies a peer's out directory (shots, dumps, logs) and its app log into
# $dest/<peer>, symlinks followed; on a phone after pulling it off the device.
function Save-PeerEvidence($peer, $dest) {
    if ("$dest".StartsWith('~/')) { $dest = Join-Path $HOME $dest.Substring(2) }
    Sync-PeerOut $peer
    $target = Join-Path $dest $peer
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $out = Join-Path $script:FleetOutRoot $peer
    if (Test-WindowsBackend) {
        robocopy $out $target /E /NFL /NDL /NJH /NJS /NP /XF inbox.jsonl | Out-Null
        $global:LASTEXITCODE = 0
    } elseif (Test-Path $out) {
        & cp -RL "$out/." $target
    }
    $log = $null
    if (Test-AndroidBackend $peer) {
        $text = @(Invoke-AppShell $peer "cat $($script:AndroidDocs)/hollow/hollow_debug.log 2>/dev/null")
        [System.IO.File]::WriteAllLines((Join-Path $target 'hollow_debug.log'), [string[]]$text)
    } elseif (Test-WindowsBackend) {
        $log = Join-Path (Join-Path $script:FleetStageRoot $peer) 'hollow_debug.log'
    } else {
        $log = Join-Path (Get-FleetPeerDataDir $peer) 'hollow_debug.log'
    }
    if ($log -and (Test-Path $log)) { Copy-Item $log (Join-Path $target 'hollow_debug.log') -Force }
    if ($script:FleetAgentLog -and (Test-Path $script:FleetAgentLog)) {
        Copy-Item $script:FleetAgentLog (Join-Path $target (Split-Path -Leaf $script:FleetAgentLog)) -Force
    }
    return $target
}

# The peer's own log lines that contain $pattern (a plain substring).
function Get-PeerLogMatches($peer, $pattern) {
    if (Test-AndroidBackend $peer) {
        $lines = @(Invoke-AppShell $peer "cat $($script:AndroidDocs)/hollow/hollow_debug.log 2>/dev/null")
    } else {
        $log = if (Test-WindowsBackend) { Join-Path (Join-Path $script:FleetStageRoot $peer) 'hollow_debug.log' }
               else { Join-Path (Get-FleetPeerDataDir $peer) 'hollow_debug.log' }
        if (-not (Test-Path $log)) { return @() }
        $lines = @(Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    return @($lines | Where-Object { "$_".Contains($pattern) })
}

# One per-peer command; the same vocabulary for a local peer and for an agent.
#   step        peer, step, timeout     a probe step or a host op; the answer
#   fleet       args                    fleet.ps1 as a child (its -Peers restart from line 0)
#   mailbox     peer                    Clear-PeerMailbox
#   status      peer                    { pid, live }
#   data_file   peer, name              the file's size in the data dir, -1 when absent
#   crash_tail  peer                    the logs' last lines
#   evidence    peer, dest              Save-PeerEvidence
#   sync_out    peer                    pull a phone's out dir to the host
#   log_grep    peer, pattern           the app log's lines containing pattern
#   proxy       peers                   start this machine's zombie proxy with a route per peer
#   proxy_stop                          stop it
function Invoke-FleetPeerCommand($request) {
    $peer = "$($request.peer)"
    switch ("$($request.cmd)") {
        'ping' { return @{ backend = $script:FleetBackend; host = [System.Net.Dns]::GetHostName() } }
        'step' {
            $timeout = 180
            if ($request.timeout) { $timeout = [int]$request.timeout }
            return (Send-FleetStep $peer $request.step $timeout)
        }
        'fleet' {
            $fleetArgs = @($request.args | ForEach-Object { "$_" })
            Invoke-FleetScript $fleetArgs
            $at = [array]::IndexOf($fleetArgs, '-Peers')
            if ($at -ge 0 -and $at + 1 -lt $fleetArgs.Count) {
                foreach ($p in ($fleetArgs[$at + 1] -split '[,\s]+' | Where-Object { $_ })) { $script:FleetConsumed[$p] = 0 }
            }
            return @{ done = $true }
        }
        'mailbox' { Clear-PeerMailbox $peer; return @{ done = $true } }
        'status' {
            $proc = Get-PeerProcess $peer
            $procId = 0
            if ($proc) { $procId = [int]$proc.Id }
            return @{ pid = $procId; live = [bool](Test-PeerLive $peer) }
        }
        'data_file' { return @{ size = (Get-PeerDataFileSize $peer "$($request.name)") } }
        'crash_tail' { return @{ text = (Get-CrashTail $peer) } }
        'evidence' { return @{ path = (Save-PeerEvidence $peer "$($request.dest)") } }
        'sync_out' { Sync-PeerOut $peer; return @{ done = $true } }
        'log_grep' { return @{ lines = @(Get-PeerLogMatches $peer "$($request.pattern)") } }
        'proxy' { Start-FleetProxy @($request.peers | ForEach-Object { "$_" }); return @{ done = $true } }
        'proxy_stop' { Stop-FleetProxy; return @{ done = $true } }
        default { throw "unknown fleet peer command '$($request.cmd)'" }
    }
}

# --------------------------------------------------------------------------
# Naming peers across machines
# --------------------------------------------------------------------------

# Whether this machine's own backend runs `platform` for `letter`.
function Test-LocalPlatform($platform, $letter) {
    switch ($platform) {
        'windows' { return (Test-WindowsBackend) }
        'macos' { return (Test-MacBackend) }
        'ios' { return (Test-SimBackend $letter) }
        'android' { return (Test-AndroidBackend $letter) }
        'linux' { return (Test-LinuxBackend) }
    }
    return $false
}

# 'android:a' -> the agent that owns it and its letter there; 'a', or a platform
# this machine's backend runs ('windows:a' on a Windows driver), -> a peer of this machine.
function Register-FleetPeer($spec) {
    if ($spec -notmatch '^(?:(win|windows|android|ios|macos|linux):)?([a-z])$') {
        throw "a peer is <platform>:<letter> with platform windows, android, ios, macos or linux (got '$spec')"
    }
    $platform = if ($Matches[1]) { $Matches[1] -replace '^win$', 'windows' } else { '' }
    $letter = $Matches[2]
    if (-not $platform -or (Test-LocalPlatform $platform $letter)) { return $letter }
    $agent = switch ($platform) { 'windows' { 'pc-win' } 'android' { 'mini-phone' } 'ios' { 'mini-phone' } 'macos' { 'mini-macos' } 'linux' { 'vm-linux' } }
    $key = "${platform}:$letter"
    $script:FleetRemotePeers[$key] = [pscustomobject]@{ Key = $key; Platform = $platform; Letter = $letter; Agent = $agent }
    return $key
}

function Test-RemotePeer($peer) { return $script:FleetRemotePeers.ContainsKey("$peer") }

function Get-RemotePeer($peer) { return $script:FleetRemotePeers["$peer"] }

# A mini agent on the mini itself (the Mac lead) runs without ssh, in this very tree.
function Test-LocalAgent($agent) { return [bool]($IsMacOS -and $agent -like 'mini-*') }

# FLEET_PC_TREE / FLEET_VM_TREE / FLEET_MINI_TREE name one machine's tree, FLEET_REMOTE_TREE all.
function Get-FleetRemoteTree($agent = '') {
    if (Test-LocalAgent $agent) { return $script:FleetRepo }
    if ($agent -eq 'pc-win') {
        if ($env:FLEET_PC_TREE) { return $env:FLEET_PC_TREE }
        if ($env:FLEET_REMOTE_TREE) { return $env:FLEET_REMOTE_TREE }
        return 'D:\dev\wt\' + (Split-Path -Leaf $script:FleetRepo)
    }
    if ($agent -eq 'vm-linux' -and $env:FLEET_VM_TREE) { return $env:FLEET_VM_TREE }
    if ($agent -like 'mini-*' -and $env:FLEET_MINI_TREE) { return $env:FLEET_MINI_TREE }
    if ($env:FLEET_REMOTE_TREE) { return $env:FLEET_REMOTE_TREE }
    return '~/wt/' + (Split-Path -Leaf $script:FleetRepo)
}

# The ssh arguments and remote shell line of one agent connection. Keepalives notice
# a dead path in about 15 s; the server itself never reads the connection.
function Get-FleetAgentLaunch($agent) {
    $tree = Get-FleetRemoteTree $agent
    $prefix = ''
    $sshArgs = @('-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3', '-o', 'ConnectTimeout=15')
    switch ($agent) {
        'mini-phone' {
            $android = @($script:FleetRemotePeers.Values | Where-Object { $_.Platform -eq 'android' } | ForEach-Object { $_.Letter })
            $ios = @($script:FleetRemotePeers.Values | Where-Object { $_.Platform -eq 'ios' } | ForEach-Object { $_.Letter })
            if ($android.Count -gt 0 -and $ios.Count -gt 0) { $prefix = "FLEET_ANDROID_PEERS=$($android -join ',') " }
            elseif ($android.Count -gt 0) { $prefix = 'FLEET_BACKEND=android ' }
            $sshArgs += @('-o', 'HostKeyAlias=192.168.18.39')
            $target = if ($env:FLEET_MINI_SSH) { $env:FLEET_MINI_SSH } else { 'jabun@100.80.56.79' }
        }
        'mini-macos' {
            $prefix = 'FLEET_BACKEND=macos '
            $sshArgs += @('-o', 'HostKeyAlias=192.168.18.39')
            $target = if ($env:FLEET_MINI_SSH) { $env:FLEET_MINI_SSH } else { 'jabun@100.80.56.79' }
        }
        'vm-linux' {
            $prefix = 'FLEET_LINUX_HEADLESS=1 PATH=$HOME/.local/bin:$HOME/Documents/flutter/bin:$HOME/.cargo/bin:$PATH '
            $target = if ($env:FLEET_VM_SSH) { $env:FLEET_VM_SSH } else { 'hollowvm' }
        }
        'pc-win' {
            # The PC's login shell is PowerShell: the attach runs in it, in-process.
            $target = if ($env:FLEET_PC_SSH) { $env:FLEET_PC_SSH } else { 'pc' }
            $set = ''
            if ($env:FLEET_LAUNCH_BUDGET) { $set = "`$env:FLEET_LAUNCH_BUDGET='$($env:FLEET_LAUNCH_BUDGET)'; " }
            $line = "Set-Location '$tree'; New-Item -ItemType Directory -Force .team | Out-Null; ${set}& .\scripts\fleet_agent_attach.ps1 $agent $($script:FleetAgentSession) 2>> .team\agent-$agent.err"
            return [pscustomobject]@{ Ssh = $sshArgs + @($target); Line = $line; Target = $target; Local = $false }
        }
        default { throw "unknown agent $agent" }
    }
    if ($env:FLEET_LAUNCH_BUDGET) { $prefix += "FLEET_LAUNCH_BUDGET=$($env:FLEET_LAUNCH_BUDGET) " }
    $line = "cd $tree && mkdir -p .team && ${prefix}bash scripts/fleet_agent_attach.sh $agent $($script:FleetAgentSession) 2>>.team/agent-$agent.err"
    if (Test-LocalAgent $agent) { $target = 'localhost' }
    return [pscustomobject]@{ Ssh = $sshArgs + @($target); Line = $line; Target = $target; Local = (Test-LocalAgent $agent) }
}

# --------------------------------------------------------------------------
# Agents
# --------------------------------------------------------------------------

function Start-FleetAgent($agent) {
    if ($script:FleetAgents.ContainsKey($agent)) {
        $known = $script:FleetAgents[$agent]
        if (-not $known.Process.HasExited) { return $known }
        $script:FleetAgents.Remove($agent)
        $note = "$((Get-Date).ToString('HH:mm:ss')) $agent had dropped between requests (ssh exit $($known.Process.ExitCode))"
        $script:FleetAgentReconnects++
        [void]$script:FleetAgentReconnectLog.Add($note)
        Write-Host "[fleet] RECONNECT $note" -ForegroundColor Yellow
    }
    $launch = Get-FleetAgentLaunch $agent
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($launch.Local) {
        $psi.FileName = '/bin/bash'
        $psi.ArgumentList.Add('-c')
        $psi.ArgumentList.Add($launch.Line)
        # The agent's backend is its own prefix, never this driver's.
        foreach ($name in 'FLEET_BACKEND', 'FLEET_ANDROID_PEERS') { [void]$psi.Environment.Remove($name) }
    } else {
        $psi.FileName = 'ssh'
        $quoted = @($launch.Ssh | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } })
        $psi.Arguments = (($quoted -join ' ') + ' "' + $launch.Line + '"')
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.NewLine = "`n"
    $process.StandardInput.AutoFlush = $true
    $state = [pscustomobject]@{ Name = $agent; Process = $process; Pending = $null; Target = $launch.Target }
    $script:FleetAgents[$agent] = $state
    Write-Host "[fleet] agent $agent on $($launch.Target) connecting ($(if ($launch.Local) { "local" } else { "ssh" }) pid $($process.Id))" -ForegroundColor Cyan
    $hello = Read-FleetAgentLine $state 150
    if (-not $hello.ok) { throw "agent $agent did not start: $($hello.error)" }
    Write-Host "[fleet] agent $agent ready ($($hello.result.backend) on $($hello.result.host))" -ForegroundColor Cyan
    return $state
}

# Thrown for a lost connection, which Invoke-FleetAgent retries; any other failure is final.
$script:FleetAgentLinkError = 'agent connection lost'

# The next protocol line from an agent; anything else it prints is its log.
function Read-FleetAgentLine($state, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ($true) {
        if (-not $state.Pending) { $state.Pending = $state.Process.StandardOutput.ReadLineAsync() }
        $left = [int]($deadline - (Get-Date)).TotalMilliseconds
        if ($left -le 0) { throw "agent $($state.Name) did not answer within ${timeoutSeconds}s" }
        if (-not $state.Pending.Wait([Math]::Min($left, 1000))) { continue }
        $line = $state.Pending.Result
        $state.Pending = $null
        if ($null -eq $line) { throw "$($script:FleetAgentLinkError): $($state.Name) on $($state.Target) (ssh exit $(if ($state.Process.WaitForExit(2000)) { $state.Process.ExitCode } else { '?' }); .team/agent-$($state.Name).err in the remote tree)" }
        if ($line.StartsWith('@@FLEET@@ ')) { return ($line.Substring(10) | ConvertFrom-Json) }
        if ($line.Trim()) { Write-Host "    [$($state.Name)] $line" -ForegroundColor DarkGray }
    }
}

function Close-FleetAgentConnection($agent) {
    $state = $script:FleetAgents[$agent]
    $script:FleetAgents.Remove($agent)
    if ($state -and -not $state.Process.HasExited) { try { $state.Process.Kill() } catch { } }
}

# Non-ASCII goes as \u escapes: the pipe to ssh is not guaranteed UTF-8 on 5.1.
function ConvertTo-AsciiJson($value) {
    $json = $value | ConvertTo-Json -Depth 20 -Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function New-FleetAgentRequest($agent, $request) {
    $script:FleetAgentNext++
    $key = "$($script:FleetAgentSession)-$($script:FleetAgentNext)"
    $request['id'] = $key
    return [pscustomobject]@{ Agent = $agent; Key = $key; Cmd = "$($request.cmd)"; Line = "$key " + (ConvertTo-AsciiJson $request); Process = $null }
}

# Writes the request now and leaves its answer to Complete-FleetAgentRequest, so a
# remote build runs while this machine builds; a lost link is Complete's to retry.
function Send-FleetAgentRequest($pending) {
    try {
        $state = Start-FleetAgent $pending.Agent
        $state.Process.StandardInput.WriteLine($pending.Line)
        $pending.Process = $state.Process
    } catch { $pending.Process = $null }
    return $pending
}

function Complete-FleetAgentRequest($pending, $timeoutSeconds = 240) {
    $agent = $pending.Agent
    $key = $pending.Key
    $lostAt = $null
    $attempt = 0
    while ($true) {
        try {
            $state = Start-FleetAgent $agent
            if ($pending.Process -ne $state.Process) {
                $state.Process.StandardInput.WriteLine($pending.Line)
                $pending.Process = $state.Process
            }
            do { $answer = Read-FleetAgentLine $state ($timeoutSeconds + 30) } while ("$($answer.id)" -ne $key)
            break
        } catch {
            $why = "$($_.Exception.Message)"
            $pending.Process = $null
            # A write into a dead connection fails as an IO error, not as our marker.
            $lost = $why.StartsWith($script:FleetAgentLinkError) -or ($_.Exception -is [System.IO.IOException]) -or
                ($_.Exception.InnerException -is [System.IO.IOException])
            if (-not $lost) { Close-FleetAgentConnection $agent; throw }
            Close-FleetAgentConnection $agent
            if (-not $lostAt) { $lostAt = Get-Date }
            $waited = [int]((Get-Date) - $lostAt).TotalSeconds
            if ($waited -ge $script:FleetAgentRetrySeconds) { throw "[$agent] $($pending.Cmd): no connection for ${waited}s ($why)" }
            $attempt++
            $pause = [Math]::Min(30, [Math]::Pow(2, $attempt))
            $note = "$((Get-Date).ToString('HH:mm:ss')) $agent lost during $($pending.Cmd) $key ($why); retry $attempt in ${pause}s"
            $script:FleetAgentReconnects++
            [void]$script:FleetAgentReconnectLog.Add($note)
            Write-Host "[fleet] RECONNECT $note" -ForegroundColor Yellow
            Start-Sleep -Seconds $pause
        }
    }
    if ($lostAt) { Write-Host "[fleet] agent $agent back after $([int]((Get-Date) - $lostAt).TotalSeconds)s; $key answered once" -ForegroundColor Yellow }
    if (-not $answer.ok) { throw "[$agent] $($pending.Cmd) failed: $($answer.error)" }
    return $answer.result
}

function Invoke-FleetAgent($agent, $request, $timeoutSeconds = 240) {
    return (Complete-FleetAgentRequest (New-FleetAgentRequest $agent $request) $timeoutSeconds)
}

# A per-peer command on whichever machine the peer is.
function Invoke-PeerCommand($peer, $cmd, $fields = @{}, $timeoutSeconds = 240) {
    $request = @{ cmd = $cmd }
    foreach ($key in $fields.Keys) { $request[$key] = $fields[$key] }
    if (Test-RemotePeer $peer) {
        $remote = Get-RemotePeer $peer
        $request['peer'] = $remote.Letter
        return (Invoke-FleetAgent $remote.Agent $request $timeoutSeconds)
    }
    $request['peer'] = $peer
    return (Invoke-FleetPeerCommand ([pscustomobject]$request))
}

# fleet.ps1 for one or more peers on THEIR machine, e.g. Invoke-PeerFleet @('ios:b') @('-Live', '-Empty').
function Invoke-PeerFleet($peers, $fleetArgs, $timeoutSeconds = 900) {
    $groups = @{}
    foreach ($peer in @($peers)) {
        $where = 'local'
        $letter = $peer
        if (Test-RemotePeer $peer) { $where = (Get-RemotePeer $peer).Agent; $letter = (Get-RemotePeer $peer).Letter }
        if (-not $groups.ContainsKey($where)) { $groups[$where] = @() }
        $groups[$where] += $letter
    }
    foreach ($where in $groups.Keys) {
        $all = @($fleetArgs) + @('-Peers', ($groups[$where] -join ','))
        if ($where -eq 'local') {
            Invoke-FleetPeerCommand ([pscustomobject]@{ cmd = 'fleet'; args = $all }) | Out-Null
        } else {
            Invoke-FleetAgent $where @{ cmd = 'fleet'; args = $all } $timeoutSeconds | Out-Null
        }
    }
}

# Sends a step to a remote peer; called by Send-FleetStep. Values are expanded
# HERE, so a value captured on one machine reaches a step on another.
function Send-RemoteFleetStep($peer, $step, $timeoutSeconds) {
    $payload = @{}
    foreach ($property in $step.PSObject.Properties) {
        if ($property.Name -eq 'peer') { continue }
        $payload[$property.Name] = Expand-FleetVars $property.Value
    }
    $answer = Invoke-PeerCommand $peer 'step' @{ step = $payload; timeout = $timeoutSeconds } ($timeoutSeconds + 30)
    if ($answer.captured) {
        foreach ($property in $answer.captured.PSObject.Properties) {
            $script:FleetVars[$property.Name] = $property.Value
        }
    }
    return $answer
}

# Ends each agent's server too: a later driver starts from a fresh one.
function Stop-FleetAgents {
    foreach ($state in @($script:FleetAgents.Values)) {
        $script:FleetAgentNext++
        try { $state.Process.StandardInput.WriteLine("$($script:FleetAgentSession)-$($script:FleetAgentNext) quit") } catch { }
        try { $state.Process.StandardInput.Close() } catch { }
        if (-not $state.Process.WaitForExit(5000)) {
            try { $state.Process.Kill() } catch { }
        }
    }
    $script:FleetAgents = @{}
}
