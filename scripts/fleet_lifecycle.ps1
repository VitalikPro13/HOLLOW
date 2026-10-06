# Lifecycle ops for fleet peers: send one away and bring it back the way life
# does, so the resumable relay session work (RESUMABLE_SESSIONS_PLAN.md section 6)
# is tested by script rather than by hand. Dot-sourced by fleet_lib.ps1, so every
# scenario, fleet_send.ps1 batch and journey script can use them as steps:
#
#   {"peer":"e","op":"background"}   {"peer":"e","op":"foreground"}
#   {"peer":"e","op":"pause"}        {"peer":"e","op":"resume"}
#   {"peer":"e","op":"net_off"}      {"peer":"e","op":"net_on","mode":"thaw"|"drop"}
#
# They run HERE, on the host, and never reach the probe: an app that is away
# cannot answer a step. Never send a probe step to a peer that is away; bring it
# back first (the `health` probe op is the one meant to be sent right after).
#
# Each op acts on that peer's own app, process or emulator, never on a host:
# cutting the Windows box's, the mini's or the VM's network, or sleeping one,
# would take every other agent and SSH session down with it.
#
# | op         | Windows exe                 | iOS Simulator             | Android emulator              | Linux bundle      |
# |------------|-----------------------------|---------------------------|-------------------------------|-------------------|
# | background | minimize, never activating, | Settings in its simulator | HOME key                      | not supported     |
# |            | probe lifecycle inactive    |                           |                               |                   |
# | foreground | restore, never activating,  | simctl launch, same pid   | am start, the battery prompt  | not supported     |
# |            | probe lifecycle resumed     |                           | dismissed if it is on top     |                   |
# | pause      | NtSuspendProcess (its pid)  | kill -STOP (its host pid) | run-as kill -STOP             | kill -STOP        |
# | resume     | NtResumeProcess             | kill -CONT                | run-as kill -CONT             | kill -CONT        |
# | net_off    | zombie proxy: freeze route  | zombie proxy: freeze      | svc wifi + svc data disable   | zombie proxy      |
# | net_on     | zombie proxy: thaw or drop  | zombie proxy: thaw / drop | svc wifi + svc data enable    | zombie proxy      |
#
# Windows never activates a fleet window: an activation hands the person at this
# machine's keyboard to the probe (wiki fleet_probe, "The probe never takes the
# foreground"). Without focus changes the engine reports no lifecycle edge for a
# minimize or a restore (measured: a minimized probe stays `resumed` and keeps
# drawing), so the probe delivers the edge a person's focus would have made:
# `inactive` on background, `resumed` on foreground. A restored window goes to the
# bottom of the z-order, covering nobody's work.
#
# The iOS Simulator and the desktops share their host's network stack, so no cut
# can be scoped to one app there: their relay connection has to run through the
# zombie proxy (tools/zombie_proxy), started by `fleet.ps1 -NetProxy`, one route
# per peer, and net_off freezes that route (a silent dead path: no FIN, no RST).
# The app reaches the proxy only through a connect override the client does not
# have yet (see Start-FleetProxy); until it does, net_off refuses with the reason
# instead of silently cutting nothing.

$script:FleetHostOps = @('background', 'foreground', 'pause', 'resume', 'net_off', 'net_on')
# What each peer was last sent to, for reports and for Restore-FleetPeer.
$script:FleetPeerAway = @{}

function Test-FleetHostOp($op) { return $script:FleetHostOps -contains "$op" }

function Get-EpochMs { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function New-HostAnswer($op, $ok, $message, $started, $extra = @{}) {
    $answer = [ordered]@{
        op = $op
        ok = [bool]$ok
        message = "$message"
        ms = [int]((Get-Date) - $started).TotalMilliseconds
        host = $true
        epoch_ms = (Get-EpochMs)
    }
    foreach ($key in $extra.Keys) { $answer[$key] = $extra[$key] }
    return [pscustomobject]$answer
}

function Initialize-FleetWin32 {
    if ('HollowFleet.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace HollowFleet {
    public static class Native {
        [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr process);
        [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr process);
        [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
        delegate bool EnumProc(IntPtr window, IntPtr param);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr param);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);

        // The Flutter runner's top-level window of a process, shown or not: the
        // probe never runs main(), so a fleet window may never have been shown,
        // and Process.MainWindowHandle only finds visible ones.
        public static IntPtr FlutterWindowOf(int pid) {
            IntPtr found = IntPtr.Zero;
            EnumWindows((window, param) => {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner != (uint)pid) return true;
                var name = new StringBuilder(64);
                GetClassName(window, name, 64);
                if (name.ToString() != "FLUTTER_RUNNER_WIN32_WINDOW") return true;
                found = window;
                return false;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@ | Out-Null
}

# Polls a condition for up to $seconds; true when it held.
function Wait-Condition([scriptblock]$condition, [double]$seconds = 5, [int]$stepMs = 100) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds $stepMs
    }
    return [bool](& $condition)
}

function Get-PeerWindow($peer, $proc) {
    $handle = [HollowFleet.Native]::FlutterWindowOf($proc.Id)
    if ($handle -eq [IntPtr]::Zero) { throw "peer $peer (pid $($proc.Id)) has no Flutter window" }
    return $handle
}

# --------------------------------------------------------------------------
# Per backend
# --------------------------------------------------------------------------

function Invoke-WindowsLifecycle($peer, $proc, $op) {
    Initialize-FleetWin32
    switch ($op) {
        'pause' {
            $p = [System.Diagnostics.Process]::GetProcessById($proc.Id)
            $status = [HollowFleet.Native]::NtSuspendProcess($p.Handle)
            if ($status -ne 0) { throw ('NtSuspendProcess failed: 0x{0:X8}' -f $status) }
            return "suspended pid $($proc.Id)"
        }
        'resume' {
            $p = [System.Diagnostics.Process]::GetProcessById($proc.Id)
            $status = [HollowFleet.Native]::NtResumeProcess($p.Handle)
            if ($status -ne 0) { throw ('NtResumeProcess failed: 0x{0:X8}' -f $status) }
            return "resumed pid $($proc.Id)"
        }
        'background' {
            $window = Get-PeerWindow $peer $proc
            # SW_SHOWMINNOACTIVE: minimized, and whatever was active stays active.
            [void][HollowFleet.Native]::ShowWindowAsync($window, 7)
            if (-not (Wait-Condition { [HollowFleet.Native]::IsIconic($window) } 5)) {
                throw 'the window did not minimize'
            }
            $answer = Send-FleetStep $peer ([pscustomobject]@{ op = 'lifecycle'; state = 'inactive' }) 60
            if (-not $answer.ok) { throw "minimized, but the probe refused inactive: $($answer.message)" }
            return "minimized without activating; $($answer.message)"
        }
        'foreground' {
            $window = Get-PeerWindow $peer $proc
            # SW_SHOWNOACTIVATE: restored, never given the keyboard; then to the
            # bottom of the z-order, so it covers nobody's work either.
            [void][HollowFleet.Native]::ShowWindowAsync($window, 4)
            if (-not (Wait-Condition { -not [HollowFleet.Native]::IsIconic($window) } 5)) {
                throw 'the window did not restore'
            }
            # HWND_BOTTOM, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
            [void][HollowFleet.Native]::SetWindowPos($window, [IntPtr]1, 0, 0, 0, 0, 0x13)
            $answer = Send-FleetStep $peer ([pscustomobject]@{ op = 'lifecycle'; state = 'resumed' }) 60
            if (-not $answer.ok) { throw "restored, but the probe refused resumed: $($answer.message)" }
            return "restored without activating; $($answer.message)"
        }
    }
    throw "no $op on Windows"
}

function Invoke-SimLifecycle($peer, $proc, $op) {
    $udid = $proc.Udid
    switch ($op) {
        'pause' {
            & kill -STOP $proc.Id
            if ($LASTEXITCODE -ne 0) { throw "kill -STOP $($proc.Id) failed" }
            return "stopped pid $($proc.Id)"
        }
        'resume' {
            & kill -CONT $proc.Id
            if ($LASTEXITCODE -ne 0) { throw "kill -CONT $($proc.Id) failed" }
            return "continued pid $($proc.Id)"
        }
        'background' {
            $out = "$(& xcrun simctl launch $udid com.apple.Preferences 2>&1)"
            if ($LASTEXITCODE -ne 0) { throw "simctl launch Settings failed: $out" }
            return 'Settings is in front; Hollow is in the background'
        }
        'foreground' {
            $out = "$(& xcrun simctl launch $udid com.anonlisten.hollow 2>&1)"
            if ($LASTEXITCODE -ne 0) { throw "simctl launch failed: $out" }
            $now = 0
            if ($out -match ':\s*(\d+)\s*$') { $now = [int]$Matches[1] }
            # A new pid is a relaunch: its live loop replays the inbox from the
            # first line, which re-runs every step this run already sent.
            if ($now -and $now -ne $proc.Id) { throw "Hollow was relaunched (pid $($proc.Id) -> $now), not resumed" }
            return "Hollow is in front again (pid $($proc.Id))"
        }
    }
    throw "no $op on the iOS Simulator"
}

function Get-AndroidTop($peer) {
    return "$(Invoke-Adb $peer 'shell' 'dumpsys activity activities | grep -m1 topResumedActivity' 2>$null)".Trim()
}

function Invoke-AndroidLifecycle($peer, $proc, $op) {
    $package = $script:AndroidPackage
    switch ($op) {
        'pause' {
            Invoke-AppShell $peer "kill -STOP $($proc.Id)" | Out-Null
            return "stopped pid $($proc.Id)"
        }
        'resume' {
            Invoke-AppShell $peer "kill -CONT $($proc.Id)" | Out-Null
            return "continued pid $($proc.Id)"
        }
        'background' {
            Invoke-Adb $peer 'shell' 'input keyevent KEYCODE_HOME' | Out-Null
            if (-not (Wait-Condition { (Get-AndroidTop $peer) -notmatch [regex]::Escape("$package/") } 5 200)) {
                throw 'Hollow is still on top after HOME'
            }
            return 'HOME: Hollow is in the background'
        }
        'foreground' {
            $out = "$(Invoke-Adb $peer 'shell' "am start -n $package/.MainActivity" 2>&1)"
            if ($out -match 'Error') { throw "am start failed: $out" }
            # The app's own battery-exemption prompt comes back on top of a
            # returning task, and the probe draws nothing behind it.
            $front = @{ dismissed = $false }
            $ok = Wait-Condition {
                $top = Get-AndroidTop $peer
                if ($top -match [regex]::Escape("$package/")) { return $true }
                if (-not $front.dismissed -and $top -match 'settings|BatteryOptimization') {
                    Invoke-Adb $peer 'shell' 'input keyevent KEYCODE_BACK' | Out-Null
                    $front.dismissed = $true
                }
                return $false
            } 10 250
            if (-not $ok) { throw "Hollow did not come to the front (top: $(Get-AndroidTop $peer))" }
            $now = Get-AndroidAppPid $peer
            if ($now -and $now -ne $proc.Id) { throw "Hollow was relaunched (pid $($proc.Id) -> $now), not resumed" }
            $note = ''
            if ($front.dismissed) { $note = ' (dismissed the battery prompt on top)' }
            return "Hollow is in front again (pid $($proc.Id))$note"
        }
        'net_off' {
            Invoke-Adb $peer 'shell' 'svc wifi disable; svc data disable' | Out-Null
            return 'emulator Wi-Fi and mobile data off'
        }
        'net_on' {
            Invoke-Adb $peer 'shell' 'svc wifi enable; svc data enable' | Out-Null
            return 'emulator Wi-Fi and mobile data on'
        }
    }
    throw "no $op on Android"
}

function Invoke-LinuxLifecycle($peer, $proc, $op) {
    switch ($op) {
        'pause' {
            & kill -STOP $proc.Id
            if ($LASTEXITCODE -ne 0) { throw "kill -STOP $($proc.Id) failed" }
            return "stopped pid $($proc.Id)"
        }
        'resume' {
            & kill -CONT $proc.Id
            if ($LASTEXITCODE -ne 0) { throw "kill -CONT $($proc.Id) failed" }
            return "continued pid $($proc.Id)"
        }
    }
    throw "$op is not supported on the Linux backend: no window control that leaves the person at the laptop alone has been built"
}

# --------------------------------------------------------------------------
# The zombie proxy, for backends whose network cannot be cut per app
# --------------------------------------------------------------------------

# Ports: FLEET_PROXY_BASE (default 18500) + the peer's letter index, control at
# base + 49. One proxy per machine and repo; its pid and ports in _proxy.json.
function Get-FleetProxyBase {
    if ($env:FLEET_PROXY_BASE) { return [int]$env:FLEET_PROXY_BASE }
    return 18500
}
function Get-FleetProxyPort($peer) { return (Get-FleetProxyBase) + ([int][char]$peer - [int][char]'a') }
function Get-FleetProxyControlPort { return (Get-FleetProxyBase) + 49 }
function Get-FleetProxyFile { return Join-Path $script:FleetOutRoot '_proxy.json' }

function Get-PythonExe {
    foreach ($name in @('python3', 'python')) {
        $found = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.Source }
    }
    throw 'no python3 on PATH: the zombie proxy needs one'
}

# One control command; the parsed JSON answer.
function Invoke-FleetProxy($line) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', (Get-FleetProxyControlPort))
        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$line`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        return ($reader.ReadLine() | ConvertFrom-Json)
    } finally {
        $client.Close()
    }
}

function Test-FleetProxyUp {
    try { return [bool](Invoke-FleetProxy 'stats').ok } catch { return $false }
}

# Starts the proxy with a route per peer to the relay, unless it is up. The app
# reaches it only once the client honours a connect override: `relay_connect` in
# the peer's data directory, one `host:port` line, read by debug builds only and
# dialled instead of the relay's address while TLS and the auth domain stay the
# relay's. No client honours it yet (a wave 1 request); Set-PeerRelayConnect
# writes it so a peer is ready the day one does.
function Start-FleetProxy($peers, $relayHost = 'relay.anonlisten.com') {
    if (Test-FleetProxyUp) { return }
    $proxy = Join-Path (Join-Path (Join-Path $script:FleetRepo 'tools') 'zombie_proxy') 'zombie_proxy.py'
    $ready = Join-Path $script:FleetOutRoot '_proxy_ready.json'
    New-Item -ItemType Directory -Path $script:FleetOutRoot -Force | Out-Null
    Remove-Item $ready -ErrorAction SilentlyContinue
    $arguments = @($proxy, 'serve', '--control', "127.0.0.1:$(Get-FleetProxyControlPort)", '--ready-file', $ready,
        '--log', (Join-Path $script:FleetOutRoot '_proxy.log'))
    foreach ($peer in @($peers)) {
        $arguments += @('--route', "$peer=127.0.0.1:$(Get-FleetProxyPort $peer)=${relayHost}:443")
    }
    $start = @{ FilePath = (Get-PythonExe); ArgumentList = $arguments; PassThru = $true }
    if (Test-WindowsBackend) { $start['WindowStyle'] = 'Hidden' }
    $process = Start-Process @start
    if (-not (Wait-Condition { Test-Path $ready } 15 200)) { throw 'the zombie proxy never became ready' }
    [System.IO.File]::WriteAllText((Get-FleetProxyFile),
        (@{ pid = $process.Id; relay = $relayHost; peers = @($peers) } | ConvertTo-Json -Compress))
    Write-Host "[fleet] zombie proxy up (pid $($process.Id)), routes $(@($peers) -join ',') -> ${relayHost}:443" -ForegroundColor Cyan
}

function Stop-FleetProxy {
    $file = Get-FleetProxyFile
    if (-not (Test-Path $file)) { return }
    $info = Get-Content $file -Raw | ConvertFrom-Json
    try { Invoke-FleetProxy 'quit' | Out-Null } catch { }
    $gone = Wait-Condition { -not (Get-Process -Id $info.pid -ErrorAction SilentlyContinue) } 5 200
    if (-not $gone) { Stop-Process -Id $info.pid -Force -ErrorAction SilentlyContinue }
    Remove-Item $file -ErrorAction SilentlyContinue
}

function Set-PeerRelayConnect($peer, $dataDir) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dataDir 'relay_connect'), "127.0.0.1:$(Get-FleetProxyPort $peer)`n")
}

function Invoke-ProxyNet($peer, $op, $step) {
    if (-not (Test-FleetProxyUp)) {
        throw "net ops on this backend run through the zombie proxy, and none is up: start the fleet with -NetProxy"
    }
    $mine = @((Invoke-FleetProxy 'list').connections | Where-Object { $_.route -eq $peer })
    if ($op -eq 'net_off') {
        if ($mine.Count -eq 0) {
            throw ("no relay connection of $peer runs through the proxy (route $peer, port $(Get-FleetProxyPort $peer)). " +
                'The app dials the proxy only once its client honours the relay_connect override; until then ' +
                'net_off and net_on cut a peer only on the Android emulator backend.')
        }
        $answer = Invoke-FleetProxy "freeze route:$peer"
        if (-not $answer.ok) { throw "the proxy refused the freeze: $($answer.error)" }
        return "froze $($mine.Count) relay connection(s) of $peer; new ones are held"
    }
    $mode = 'thaw'
    if ($step.mode) { $mode = "$($step.mode)" }
    if ($mode -notin @('thaw', 'drop')) { throw "net_on mode is thaw or drop, not $mode" }
    $answer = Invoke-FleetProxy "$mode route:$peer"
    if (-not $answer.ok) { throw "the proxy refused $mode`: $($answer.error)" }
    return "$mode`: $(@($answer.connections).Count) relay connection(s) of $peer"
}

# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------

function Invoke-FleetHostOp($peer, $step) {
    $op = "$($step.op)"
    $started = Get-Date
    $proc = Get-PeerProcess $peer
    if (-not $proc) { return (New-HostAnswer $op $false "peer $peer is not running" $started) }
    try {
        if (($op -eq 'net_off' -or $op -eq 'net_on') -and -not (Test-AndroidBackend $peer)) {
            $message = Invoke-ProxyNet $peer $op $step
        } elseif (Test-AndroidBackend $peer) {
            $message = Invoke-AndroidLifecycle $peer $proc $op
        } elseif (Test-SimBackend $peer) {
            $message = Invoke-SimLifecycle $peer $proc $op
        } elseif (Test-LinuxBackend) {
            $message = Invoke-LinuxLifecycle $peer $proc $op
        } else {
            $message = Invoke-WindowsLifecycle $peer $proc $op
        }
    } catch {
        return (New-HostAnswer $op $false "$($_.Exception.Message)" $started)
    }
    $away = $script:FleetPeerAway[$peer]
    if (-not $away) { $away = @{}; $script:FleetPeerAway[$peer] = $away }
    switch ($op) {
        'background' { $away['background'] = $true }
        'foreground' { $away.Remove('background') }
        'pause' { $away['paused'] = $true }
        'resume' { $away.Remove('paused') }
        'net_off' { $away['net_off'] = $true }
        'net_on' { $away.Remove('net_off') }
    }
    return (New-HostAnswer $op $true $message $started)
}

# Brings a peer fully back whatever this process thinks it did: continued, in
# front, network on. Every step is harmless on a peer that was never away.
function Restore-FleetPeer($peer) {
    $notes = @()
    foreach ($op in @('resume', 'net_on', 'foreground')) {
        if ($op -eq 'net_on' -and -not (Test-AndroidBackend $peer)) {
            if (-not (Test-FleetProxyUp)) { continue }
        }
        if ($op -eq 'foreground' -and (Test-LinuxBackend)) { continue }
        $answer = Invoke-FleetHostOp $peer ([pscustomobject]@{ op = $op })
        if (-not $answer.ok) { $notes += "$op`: $($answer.message)" }
    }
    $script:FleetPeerAway.Remove($peer)
    return $notes
}
