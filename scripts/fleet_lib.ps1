# Shared by scripts\fleet.ps1 (runs a whole scenario), scripts\fleet_send.ps1
# (sends a command or two by hand) and the hand-written journey scripts
# (fleet_owner_offline.ps1, fleet_friend_*.ps1). They all talk to a live
# instance the same way - append to its inbox.jsonl, wait for the matching id in
# its outbox.jsonl - and keeping one implementation means a fix to the death
# detection, the variable expansion or the fresh-identity boot lands in all of
# them.
#
# Callers set $script:FleetRepo, $script:FleetOutRoot and $script:FleetStageRoot
# before using anything here.
#
# Windows PowerShell 5.1: no pwsh-only syntax. The same files run under pwsh 7
# on the Mac mini, where the backend is the iOS Simulator (see Test-SimBackend),
# and under pwsh 7 on a Linux desktop, where bundle copies are driven the way
# Windows drives exe copies (see Test-LinuxBackend).

# pwsh 7.4+ turns a non-zero native exit code into a terminating error while
# $ErrorActionPreference is Stop. Half of simctl's normal answers are non-zero
# ("already booted", "not installed"), so the exit codes are read by hand.
$PSNativeCommandUseErrorActionPreference = $false

# Which machine this is. Windows PowerShell 5.1 has no $IsMacOS or $IsLinux, so
# both are simply absent there and read as false.
if ($IsMacOS) { $script:FleetBackend = 'sim' }
elseif ($IsLinux) { $script:FleetBackend = 'linux' }
else { $script:FleetBackend = 'windows' }

# FLEET_BACKEND=android drives Android emulators instead (Test-AndroidBackend),
# for every script that loads this file, fleet_send.ps1 included.
if ($env:FLEET_BACKEND) {
    if ($env:FLEET_BACKEND -ne 'android') { throw "unknown FLEET_BACKEND '$($env:FLEET_BACKEND)' (known: android)" }
    if (-not ($IsMacOS -or $IsLinux)) { throw 'the Android fleet backend runs under pwsh on macOS or Linux' }
    $script:FleetBackend = 'android'
}

# The iOS Simulator backend: one simulator per peer (named hollow-<peer>), the
# probe target installed into each, the data directory and the probe output
# inside the app's own container, which is the only place an iOS app can
# write, reached from the scripts through a symlink per peer under
# build/fleet_out. Configuration goes in as Documents/probe.env, because
# Platform.environment is empty on iOS.
function Test-SimBackend { return $script:FleetBackend -eq 'sim' }

# The Linux backend: a bundle copy per peer under build/fleet, each launched on
# its OWN session bus (dbus-run-session). The runner registers one fixed
# GApplication id for deep links, so on a shared bus the second instance would
# hand its command line to the first and exit before drawing a frame.
function Test-LinuxBackend { return $script:FleetBackend -eq 'linux' }
function Test-WindowsBackend { return $script:FleetBackend -eq 'windows' }

# Fixtures and run directories on Linux live under $HOME like on the Mac: a
# reboot empties /tmp and would take the fixture identities with it.
function Get-LinuxFleetHome { return (Join-Path $HOME 'hollow_fleet') }

# Where `fleet.ps1 -Onboard` keeps each peer's fixture identity. Android peers
# get their own root: peer a on an emulator and peer a in a simulator are two
# different identities on the same Mac.
function Get-FixtureRoot {
    if (Test-WindowsBackend) { return Join-Path $env:TEMP 'hollow_fleet\fixtures' }
    if (Test-AndroidBackend) { return Join-Path (Get-LinuxFleetHome) 'fixtures-android' }
    return Join-Path (Get-LinuxFleetHome) 'fixtures'
}

# The recovery phrase `fleet.ps1 -Onboard` saw for a peer's fixture identity.
function Get-FixturePhrase($peer) {
    $file = Join-Path (Get-FixtureRoot) "$peer.phrase"
    if (-not (Test-Path $file)) { throw "no phrase kept for '$peer': onboard it again with fleet.ps1 -Onboard -Fresh" }
    return [System.IO.File]::ReadAllText($file).Trim()
}

# The shell a child fleet run is started with.
function Get-PowerShellExe { if (Test-WindowsBackend) { return 'powershell' } else { return 'pwsh' } }

# --------------------------------------------------------------------------
# The Android emulator backend
# --------------------------------------------------------------------------

# One emulator per peer (AVD hollow-<peer>, console port fixed by the peer's
# letter so its adb serial never changes), the probe APK installed into each.
# An Android app's files live INSIDE the emulator, so no out directory can be a
# host path: the inbox and outbox are written and read through `run-as`, and
# build/fleet_out/<peer> is a copy that Sync-PeerOut refreshes. The data
# directory is the app's own app_flutter/hollow.
function Test-AndroidBackend { return $script:FleetBackend -eq 'android' }

$script:AndroidPackage = 'com.anonlisten.hollow'
# getApplicationDocumentsDirectory, relative to the app data directory `run-as`
# starts in, and absolute for the probe.env the app itself reads.
$script:AndroidDocs = 'app_flutter'
$script:AndroidDocsAbs = "/data/user/0/$($script:AndroidPackage)/app_flutter"

function Get-AndroidSdk {
    $candidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT,
        (Join-Path $HOME 'Library/Android/sdk'), (Join-Path $HOME 'Android/Sdk'))
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'platform-tools'))) { return $candidate }
    }
    throw 'no Android SDK found: install it with Android Studio or set ANDROID_HOME'
}

function Get-AndroidTool($relative) { return Join-Path (Get-AndroidSdk) $relative }

# a = emulator-5554, b = emulator-5556, ...: the console port is the serial.
function Get-AndroidSerial($peer) {
    if ($peer -notmatch '^[a-z]$') { throw "Android fleet peers are single letters a-z (got '$peer')" }
    return 'emulator-' + (5554 + 2 * ([int][char]$peer - [int][char]'a'))
}

function Invoke-Adb($peer) {
    & (Get-AndroidTool 'platform-tools/adb') -s (Get-AndroidSerial $peer) @args
}

# One command inside the app's sandbox, its stdout returned. adb joins its
# arguments WITHOUT quoting, so the remote command travels as one pre-quoted
# string; split up, a redirect would run as the shell user, outside the
# sandbox, and fail. Commands passed here must not contain a single quote.
function Invoke-AppShell($peer, $command) {
    Invoke-Adb $peer 'exec-out' "run-as $($script:AndroidPackage) sh -c '$command'"
}

# Writes text to a file inside the sandbox. Base64 keeps quotes and newlines
# out of the remote command line.
function Set-AppFile($peer, $relative, $text, [switch]$Append) {
    $b64 = [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
    $op = if ($Append) { '>>' } else { '>' }
    Invoke-AppShell $peer "echo $b64 | base64 -d $op $relative" | Out-Null
}

# A host pipeline through sh, for the tar streams PowerShell would re-encode.
function Invoke-HostPipe($commandLine) {
    & /bin/sh -c $commandLine
    if ($LASTEXITCODE -ne 0) { throw "failed ($LASTEXITCODE): $commandLine" }
}

# Copies a host directory's contents into a directory inside the sandbox,
# replacing what was there. The lock file never travels (see Copy-Mirror).
function Push-AppDir($peer, $hostDir, $relative) {
    Invoke-AppShell $peer "rm -rf $relative && mkdir -p $relative" | Out-Null
    $adb = Get-AndroidTool 'platform-tools/adb'
    $serial = Get-AndroidSerial $peer
    Invoke-HostPipe ("tar --exclude '*hollow.lock' -cf - -C '{0}' . | '{1}' -s {2} exec-in 'run-as {3} tar -xf - -C {4}'" -f
        $hostDir, $adb, $serial, $script:AndroidPackage, $relative)
}

# The reverse: a directory inside the sandbox mirrored into a host directory.
function Pull-AppDir($peer, $relative, $hostDir) {
    if (Test-Path $hostDir) { & rm -rf $hostDir }
    New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
    $adb = Get-AndroidTool 'platform-tools/adb'
    $serial = Get-AndroidSerial $peer
    Invoke-HostPipe ("'{0}' -s {1} exec-out 'run-as {2} tar -cf - -C {3} .' | tar --exclude '*hollow.lock' -xf - -C '{4}'" -f
        $adb, $serial, $script:AndroidPackage, $relative, $hostDir)
}

function Test-AndroidDeviceUp($peer) {
    return ("$(Invoke-Adb $peer 'get-state' 2>$null)".Trim() -eq 'device')
}

# A JDK for avdmanager when the shell has none: Flutter's own (flutter config
# --jdk-dir), else the one inside Android Studio.
function Get-AndroidJavaHome {
    if ($env:JAVA_HOME) { return $env:JAVA_HOME }
    $line = @(& flutter config --list 2>$null) | Where-Object { "$_" -match 'jdk-dir:\s*(\S.*)$' } | Select-Object -First 1
    if ($line -and "$line" -match 'jdk-dir:\s*(\S.*)$') { return $Matches[1].Trim('"', ' ') }
    $studio = '/Applications/Android Studio.app/Contents/jbr/Contents/Home'
    if (Test-Path $studio) { return $studio }
    throw 'no JDK for avdmanager: set JAVA_HOME'
}

# Creates the peer's AVD from the newest installed Google system image for
# this host's CPU. FLEET_ANDROID_IMAGE ("system-images;android-37.0;...")
# picks one, FLEET_ANDROID_DEVICE the hardware profile (default pixel_9).
function New-AndroidAvd($peer) {
    $image = $env:FLEET_ANDROID_IMAGE
    if (-not $image) {
        $abi = if ("$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" -eq 'Arm64') { 'arm64-v8a' } else { 'x86_64' }
        $root = Join-Path (Get-AndroidSdk) 'system-images'
        $found = @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $api = $_.Name
                Get-ChildItem $_.FullName -Directory | Where-Object { $_.Name -like 'google_apis*' -and (Test-Path (Join-Path $_.FullName $abi)) } |
                    ForEach-Object { [pscustomobject]@{ Api = $api; Tag = $_.Name; Rank = [double]($api -replace '[^0-9.]', '') } }
            } | Sort-Object Rank -Descending)
        if ($found.Count -eq 0) { throw "no Google $abi system image installed (Android Studio > Device Manager, or set FLEET_ANDROID_IMAGE)" }
        $image = "system-images;$($found[0].Api);$($found[0].Tag);$abi"
    }
    $device = $env:FLEET_ANDROID_DEVICE
    if (-not $device) { $device = 'pixel_9' }
    $savedJava = $env:JAVA_HOME
    $env:JAVA_HOME = Get-AndroidJavaHome
    try {
        'no' | & (Get-AndroidTool 'cmdline-tools/latest/bin/avdmanager') create avd -n "hollow-$peer" -k $image -d $device 2>&1 | Out-Null
    } finally { $env:JAVA_HOME = $savedJava }
    $config = Join-Path (Join-Path $HOME '.android/avd') "hollow-$peer.avd/config.ini"
    if (-not (Test-Path $config)) { throw "avdmanager did not create hollow-$peer ($image)" }
    # avdmanager's defaults differ from Android Studio's in ways that matter
    # here: a <temp> data partition loses the installed app and its data on
    # every boot, and without a GPU the probe crawls.
    $lines = @(Get-Content $config | Where-Object { $_ -notmatch '^disk\.dataPartition\.path=' }) | ForEach-Object {
        $_ -replace '^hw\.gpu\.enabled=.*', 'hw.gpu.enabled=yes' -replace '^hw\.keyboard=.*', 'hw.keyboard=yes' -replace '^hw\.ramSize=.*', 'hw.ramSize=3072'
    }
    [System.IO.File]::WriteAllText($config, (($lines -join "`n") + "`n"))
    Write-Host "[fleet] created emulator hollow-$peer ($image, $device)" -ForegroundColor Cyan
}

# Boots the peer's emulator unless it is up, creating its AVD on first use.
# Emulators are left running by Stop-Fleet: a cold boot is the slow part, and
# `adb -s emulator-5554 emu kill` ends one by hand.
function Start-AndroidDevice($peer) {
    $serial = Get-AndroidSerial $peer
    $log = Join-Path (Get-LinuxFleetHome) "emulator-$peer.log"
    if (-not (Test-AndroidDeviceUp $peer)) {
        $emulator = Get-AndroidTool 'emulator/emulator'
        if (@(& $emulator -list-avds 2>$null) -notcontains "hollow-$peer") { New-AndroidAvd $peer }
        New-Item -ItemType Directory -Path (Get-LinuxFleetHome) -Force | Out-Null
        $port = $serial.Substring('emulator-'.Length)
        # -gpu host is not optional: started from SSH, the emulator otherwise
        # settles on software rendering (lavapipe) and everything crawls.
        Invoke-HostPipe ("nohup '{0}' -avd hollow-{1} -port {2} -gpu host -no-boot-anim -no-snapshot-save >'{3}' 2>&1 </dev/null &" -f
            $emulator, $peer, $port, $log)
        Write-Host "[fleet] booting emulator hollow-$peer ($serial)" -ForegroundColor Cyan
    }
    $deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $deadline) {
        if ("$(Invoke-Adb $peer 'shell' 'getprop sys.boot_completed' 2>$null)".Trim() -eq '1') { return }
        Start-Sleep -Seconds 2
    }
    throw "emulator hollow-$peer ($serial) did not finish booting in 240s. Its log: $log"
}

# The peers whose emulators are up, found by AVD name so an emulator Android
# Studio started for something else is never touched.
function Get-AndroidFleetPeers {
    $found = @()
    foreach ($line in @(& (Get-AndroidTool 'platform-tools/adb') devices 2>$null)) {
        if ("$line" -notmatch '^emulator-(\d+)\s+device') { continue }
        $index = ([int]$Matches[1] - 5554) / 2
        if ($index -lt 0 -or $index -gt 25 -or $index -ne [Math]::Floor($index)) { continue }
        $peer = [string][char]([int][char]'a' + $index)
        $name = "$(@(Invoke-Adb $peer 'emu' 'avd' 'name' 2>$null) | Select-Object -First 1)".Trim()
        if ($name -eq "hollow-$peer") { $found += $peer }
    }
    return $found
}

function Get-AndroidAppPid($peer) {
    $found = "$(Invoke-Adb $peer 'shell' "pidof $($script:AndroidPackage)" 2>$null)".Trim()
    if ($found -match '^(\d+)') { return [int]$Matches[1] }
    return $null
}

# Refreshes build/fleet_out/<peer> from the probe output inside the emulator,
# so screenshots, results and logs are where every other backend leaves them.
# A no-op on the other backends, whose out directories are the real thing.
function Sync-PeerOut($peer) {
    if (-not (Test-AndroidBackend)) { return }
    if (-not (Test-AndroidDeviceUp $peer)) { return }
    Pull-AppDir $peer "$($script:AndroidDocs)/probe_out" (Join-Path $script:FleetOutRoot $peer)
}

$script:SimUdids = @{}

# Every simulator this tooling created, whatever peers this run happens to use.
function Get-SimFleetUdids {
    $found = @()
    $json = & xcrun simctl list devices -j | ConvertFrom-Json
    foreach ($runtime in $json.devices.PSObject.Properties) {
        foreach ($device in @($runtime.Value)) {
            if ($device.name -like 'hollow-*' -and $device.isAvailable) { $found += $device.udid }
        }
    }
    return $found
}

# The simulator for a peer, created on first use from the newest installed iOS
# runtime. FLEET_SIM_DEVICE picks the device type (default iPhone 17 Pro).
function Get-SimUdid($peer, [switch]$Create) {
    if ($script:SimUdids.ContainsKey($peer)) { return $script:SimUdids[$peer] }
    $name = "hollow-$peer"
    $json = & xcrun simctl list devices -j | ConvertFrom-Json
    foreach ($runtime in $json.devices.PSObject.Properties) {
        foreach ($device in @($runtime.Value)) {
            if ($device.name -eq $name -and $device.isAvailable) {
                $script:SimUdids[$peer] = $device.udid
                return $device.udid
            }
        }
    }
    if (-not $Create) { return $null }
    $runtimes = @((& xcrun simctl list runtimes -j | ConvertFrom-Json).runtimes |
        Where-Object { $_.platform -eq 'iOS' -and $_.isAvailable } |
        Sort-Object { [version]$_.version } -Descending)
    if ($runtimes.Count -eq 0) { throw 'no iOS Simulator runtime is installed (Xcode > Settings > Components)' }
    $type = $env:FLEET_SIM_DEVICE
    if (-not $type) { $type = 'iPhone 17 Pro' }
    $udid = "$(& xcrun simctl create $name $type $runtimes[0].identifier)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $udid) { throw "could not create simulator $name ($type)" }
    Write-Host "[fleet] created simulator $name ($type, $($runtimes[0].name)) $udid" -ForegroundColor Cyan
    $script:SimUdids[$peer] = $udid
    return $udid
}

function Get-SimState($udid) {
    $json = & xcrun simctl list devices -j | ConvertFrom-Json
    foreach ($runtime in $json.devices.PSObject.Properties) {
        foreach ($device in @($runtime.Value)) {
            if ($device.udid -eq $udid) { return $device.state }
        }
    }
    return 'Unknown'
}

# Boots the device if it is not up and makes sure Simulator.app is showing it.
# The window is not decoration: a probe launched against a headless boot sat in
# its first pump forever (2026-09-05), because no frames are produced for a
# device nothing is displaying.
function Start-SimDevice($udid) {
    if ((Get-SimState $udid) -ne 'Booted') {
        & xcrun simctl boot $udid 2>&1 | Out-Null
        & xcrun simctl bootstatus $udid -b 2>&1 | Out-Null
    }
    # A booted device nothing shows renders one frame and then none. Xcode 27
    # replaced Simulator.app with DeviceHub, which shows a device through its
    # URL; a device shown once keeps rendering after the view moves on.
    & open "devices://device/open?id=$udid" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & open -a Simulator --args -CurrentDeviceUDID $udid 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "could not show simulator ${udid}: neither DeviceHub nor Simulator.app opened it"
        }
    }
}

function Get-SimContainer($udid) {
    $path = "$(& xcrun simctl get_app_container $udid com.anonlisten.hollow data 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $path) {
        throw "the probe is not installed in simulator $udid. Run with -Build first."
    }
    return $path
}

function Get-SimDataDir($udid) {
    return Join-Path (Join-Path (Get-SimContainer $udid) 'Documents') 'hollow'
}

# The pid of the app inside a simulator, or $null when it is not running.
function Get-SimAppPid($udid) {
    $lines = & xcrun simctl spawn $udid launchctl list 2>$null
    foreach ($line in @($lines)) {
        if ("$line" -match '^\s*(\d+)\s+\S+\s+UIKitApplication:com\.anonlisten\.hollow') {
            return [int]$Matches[1]
        }
    }
    return $null
}

# Mirrors one directory into another, deletions included, skipping the lock
# file. robocopy on Windows, rsync everywhere else.
function Copy-Mirror($source, $destination) {
    if (-not (Test-WindowsBackend)) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        & rsync -a --delete --exclude 'hollow.lock' "$source/" "$destination/"
        if ($LASTEXITCODE -ne 0) { throw "rsync $source -> $destination failed with $LASTEXITCODE" }
        return
    }
    robocopy $source $destination /MIR /MT:8 /XF 'hollow.lock' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "mirroring $source -> $destination failed with $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}

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
    # A list of strings (attach_file's `paths`) expands item by item.
    if ($value -is [array]) {
        return ,@($value | ForEach-Object { Expand-FleetVars $_ })
    }
    return $value
}

# The welcome dialog's Advanced relay field, as steps.
#
# The relay a peer talks to is chosen ONCE, before its identity exists, and it
# is stamped into the fixture with everything else; there is no other moment a
# fleet peer can be pointed at a self-hosted relay. Shared so fleet.ps1's
# -Relay and the journey scripts fill the same field the same way.
# An empty domain means the official relay and produces no steps at all.
function Get-RelayWelcomeSteps($relayDomain) {
    if (-not $relayDomain) { return @() }
    return @(
        @{ op = 'tap'; target = 'semantics:Change the relay'; index = 0 },
        @{ op = 'wait_for'; target = 'hint:relay.anonlisten.com'; timeout_ms = 10000 },
        @{ op = 'enter_text'; target = 'hint:relay.anonlisten.com'; value = $relayDomain },
        @{ op = 'wait_for'; target = "text:$relayDomain"; timeout_ms = 10000 }
    )
}

# A fleet instance is identified by where its exe lives, so nothing here can
# ever match a real Hollow the user happens to have open.
function Get-PeerProcess($peer) {
    if (Test-SimBackend) {
        $udid = Get-SimUdid $peer
        if (-not $udid) { return $null }
        $running = Get-SimAppPid $udid
        if (-not $running) { return $null }
        return [pscustomobject]@{ Id = $running; Udid = $udid }
    }
    if (Test-AndroidBackend) {
        if ($peer -notmatch '^[a-z]$' -or -not (Test-AndroidDeviceUp $peer)) { return $null }
        $running = Get-AndroidAppPid $peer
        if (-not $running) { return $null }
        return [pscustomobject]@{ Id = $running; Serial = (Get-AndroidSerial $peer) }
    }
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
    $outDir = Join-Path $script:FleetOutRoot $peer
    $sources = @(
        @{ name = 'errors.log'; path = (Join-Path $outDir 'errors.log') },
        @{ name = 'stdout'; path = (Join-Path $outDir 'stdout.log') }
    )
    if (Test-SimBackend) {
        $udid = Get-SimUdid $peer
        if ($udid) {
            try {
                $sources += @{ name = 'hollow_debug'; path = (Join-Path (Get-SimDataDir $udid) 'hollow_debug.log') }
            } catch { }
            # The simulator's own log keeps the app's last words when it died
            # before writing anything of its own.
            $simLog = @(& xcrun simctl spawn $udid log show --last 3m --style compact --predicate 'process == "Runner"' 2>$null |
                Where-Object { "$_" -match 'flutter:' } | Select-Object -Last 20)
            if ($simLog.Count -gt 0) {
                $lines += "--- simulator log ---"
                $lines += $simLog
            }
        }
    } elseif (Test-AndroidBackend) {
        # The probe's own logs only reach the host by a sync; the app log and
        # logcat are read where they are.
        try { Sync-PeerOut $peer } catch { }
        $appLog = @(Invoke-AppShell $peer "tail -n 20 $($script:AndroidDocs)/hollow/hollow_debug.log 2>/dev/null") |
            Where-Object { "$_".Trim() }
        if ($appLog.Count -gt 0) {
            $lines += '--- hollow_debug ---'
            $lines += $appLog
        }
        $logcat = @(Invoke-Adb $peer 'logcat' '-d' '-t' '400' '-s' 'flutter:*' 'AndroidRuntime:E' 2>$null |
            Where-Object { "$_" -notmatch '^-+ beginning of' } | Select-Object -Last 20)
        if ($logcat.Count -gt 0) {
            $lines += '--- logcat ---'
            $lines += $logcat
        }
    } elseif (Test-LinuxBackend) {
        # The app logs into its data directory on Linux, and a native death
        # says its last words on stderr, which Start-Peer keeps per instance.
        $sources += @{ name = 'hollow_debug'; path = (Join-Path (Join-Path (Join-Path (Get-LinuxFleetHome) 'run') $peer) 'hollow_debug.log') }
        $sources += @{ name = 'native-stderr'; path = (Join-Path $outDir 'native-stderr.log') }
    } else {
        $sources += @{ name = 'hollow_debug'; path = (Join-Path (Join-Path $script:FleetStageRoot $peer) 'hollow_debug.log') }
    }
    foreach ($item in $sources) {
        if (-not (Test-Path $item.path)) { continue }
        $tail = @(Get-Content $item.path -Tail 20 -ErrorAction SilentlyContinue) |
            Where-Object { $_.Trim() }
        if ($tail.Count -eq 0) { continue }
        $lines += "--- $($item.name) ---"
        $lines += $tail
    }
    if ($lines.Count -eq 0) { return "Nothing in the logs. Look in $(Join-Path $script:FleetOutRoot $peer)." }
    return ($lines -join "`n")
}

function Test-PeerLive($peer) {
    if (Test-AndroidBackend) {
        if ($peer -notmatch '^[a-z]$' -or -not (Test-AndroidDeviceUp $peer)) { return $false }
        $marker = "$(Invoke-AppShell $peer "test -e $($script:AndroidDocs)/probe_out/live-ready && echo yes" 2>$null)"
        return ($marker.Trim() -eq 'yes')
    }
    return (Test-Path (Join-Path (Join-Path $script:FleetOutRoot $peer) 'live-ready'))
}

# Which instances are up right now, by looking at what is running rather than
# at what this invocation happened to launch. That is what lets a second script
# attach to a fleet a first one left behind.
function Get-LivePeers {
    $root = $script:FleetOutRoot
    if (-not (Test-Path $root)) { return @() }
    # Not -Directory: on the simulator backend each entry is a symlink into an
    # app container, and a symlink only counts as a directory once followed.
    return @(Get-ChildItem $root -Force |
        Where-Object { Test-Path -LiteralPath $_.FullName -PathType Container } |
        ForEach-Object { $_.Name } |
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
    $android = Test-AndroidBackend
    if ($android) {
        Set-AppFile $peer "$($script:AndroidDocs)/probe_out/inbox.jsonl" ($line + "`n") -Append
    } else {
        # Not Add-Content: 5.1 writes a UTF-8 BOM into a new or empty file, and a
        # BOM in front of the first line breaks the JSON parse on the Dart side.
        [System.IO.File]::AppendAllText($inbox, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }

    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $lines = $null
        if ($android) {
            $lines = @(Invoke-AppShell $peer "cat $($script:AndroidDocs)/probe_out/outbox.jsonl 2>/dev/null")
        } elseif (Test-Path $outbox) {
            # @() because Get-Content returns a bare string for a one-line file,
            # and indexing a string gives a Char.
            $lines = @(Get-Content $outbox -Encoding UTF8)
        }
        if ($null -ne $lines) {
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

# --------------------------------------------------------------------------
# Fresh identities for a journey that cannot share a mailbox with its own past
# --------------------------------------------------------------------------

# One fleet.ps1 invocation, as a child process. Not dot-sourced and not `&`-ed
# in: fleet.ps1 owns a param block, a $script: scope and an exit code, and a
# child keeps all three out of the caller's. Its instances are launched by
# Start-Process with no redirection, which means ShellExecute, which means they
# inherit no handle of ours - so capturing this output cannot wedge the way
# trap 2 wedges a redirected launch.
function Invoke-FleetScript($fleetArgs) {
    $fleet = Join-Path (Join-Path $script:FleetRepo 'scripts') 'fleet.ps1'
    if (-not (Test-Path $fleet)) { throw "fleet.ps1 not found at $fleet" }
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fleet) + $fleetArgs
    & (Get-PowerShellExe) @all | ForEach-Object { Write-Host "    | $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        throw "fleet.ps1 $($fleetArgs -join ' ') failed with $LASTEXITCODE"
    }
}

# Stop whatever is up, mint BRAND-NEW identities for these peers, and boot them.
#
# Why the friend journeys default to this: the relay buffers a friend request
# against inbox:{master} and replays it, TTL-only, for three days. The fixture
# identities are stable across runs, so a journey run on a reused identity is
# reading its own past - a wait_for satisfied by yesterday's request, a "fresh"
# peer that is saturated with them. New keys mean an empty mailbox, and that is
# the only clean start there is. Onboarding two peers costs about a minute.
function Start-FreshFleet($peers) {
    $peerList = @($peers)
    $peerArg = ($peerList -join ',')
    Write-Host "[fleet] minting fresh identities for: $peerArg" -ForegroundColor Cyan
    Invoke-FleetScript @('-Stop')
    Invoke-FleetScript @('-Onboard', '-Fresh', '-Peers', $peerArg)
    Invoke-FleetScript @('-Live', '-Peers', $peerArg)

    # The out directories were recreated by the boot, so nothing this process
    # read before is still there to skip past.
    foreach ($peer in $peerList) { $script:FleetConsumed[$peer] = 0 }

    # Print the identity each peer came back with. It is the proof that this run
    # is not talking to the last one's mailbox, and it costs one step per peer.
    foreach ($peer in $peerList) {
        # The connection PROVIDER, not the word: the mobile shell's home tab
        # never prints "Connected", and the desktop one only off the chat.
        $ready = Send-FleetStep $peer ([pscustomobject]@{
            op = 'wait_for'; provider = 'connection'; equals = 'connected'; timeout_ms = 120000
        }) 180
        if (-not $ready.ok) { throw "$peer onboarded but never reached Connected: $($ready.message)" }
        $name = 'FRESH_' + $peer.ToUpper()
        $answer = Send-FleetStep $peer ([pscustomobject]@{
            op = 'capture'; from = 'provider'; key = 'peerId'; as = $name
        }) 120
        if (-not $answer.ok) { throw "could not read $peer's fresh identity: $($answer.message)" }
        Write-Host "[fleet] $peer fresh identity: $($script:FleetVars[$name])" -ForegroundColor Green
    }
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
