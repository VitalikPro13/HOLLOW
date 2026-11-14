# Self-test for the production relay guard (fleet_relay_guard.ps1): every way a fleet
# or probe peer has reached, or could reach, the official relay is refused, and a test
# relay still passes. No relay, no build and no device: fleet.ps1 runs from a copy of
# scripts/ in a temp folder with its own HOME/TEMP, so it can reach no real fleet.
#
#   pwsh scripts/fleet_relay_guard_selftest.ps1                 # macOS, Linux
#   powershell -File scripts\fleet_relay_guard_selftest.ps1     # Windows
#
# The app side has its own test: flutter test test/probe_relay_guard_test.dart; the
# proxy's: python tools/zombie_proxy/test_zombie_proxy.py ProductionGuard.
# Windows PowerShell 5.1: no pwsh-only syntax.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:FleetRepo = $repoRoot
$script:FleetStageRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet'
$script:FleetOutRoot = Join-Path (Join-Path $repoRoot 'build') 'fleet_out'
foreach ($name in 'FLEET_RELAY', 'FLEET_RELAY_CONNECT', 'UI_PROBE_ALLOW_PRODUCTION', 'UI_PROBE_EXPECT_RELAY') {
    [Environment]::SetEnvironmentVariable($name, $null)
}
. (Join-Path $PSScriptRoot 'fleet_relay_guard.ps1')

$script:Passed = 0
$script:Failed = @()
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:Passed++; Write-Host "PASS $name" -ForegroundColor Green }
    else { $script:Failed += $name; Write-Host "FAIL $name $detail" -ForegroundColor Red }
}
function Throws([scriptblock]$block) {
    try { & $block | Out-Null; return '' } catch { return "$($_.Exception.Message)" }
}

# --- names -----------------------------------------------------------------
foreach ($t in @('relay.anonlisten.com', 'RELAY.ANONLISTEN.COM.', 'wss://relay.anonlisten.com/ws', 'relay.anonlisten.com:443',
        'anonlisten.com', 'canary.relay.anonlisten.com', '*.anonlisten.com', '141.227.186.209', '[2001:41d0:ab01::4:0:d]:443',
        '::ffff:141.227.186.209', 'user@relay.anonlisten.com', '')) {
    Check "name '$t' is production" ([bool](Get-FleetProdNameReason $t))
}
foreach ($t in @('hollowtest.duckdns.org', 'hollowtest.duckdns.org:8443', 'anonlisten.com.evil.example', 'notanonlisten.com', '192.168.18.2')) {
    Check "name '$t' passes" (-not (Get-FleetProdNameReason $t))
}

# --- the relay a launch would boot with ------------------------------------
Check 'onboarding with no relay is refused' ([bool](Get-FleetLaunchRelayVerdict '' '' $true))
Check 'onboarding onto the official relay is refused' ([bool](Get-FleetLaunchRelayVerdict '' 'relay.anonlisten.com' $true))
Check 'onboarding onto a test relay passes' (-not (Get-FleetLaunchRelayVerdict '' '127.0.0.1:9' $true))
Check 'a fixture stamped with the official relay is refused' ([bool](Get-FleetLaunchRelayVerdict 'relay.anonlisten.com' '' $false))
Check "a fixture stamped with another relay than the run's is refused" ([bool](Get-FleetLaunchRelayVerdict '127.0.0.1:9' '127.0.0.2:9' $false))
Check "a fixture stamped with the run's relay passes" (-not (Get-FleetLaunchRelayVerdict '127.0.0.1:9' '127.0.0.1:9' $false))
Check 'an unstamped fixture is left to the probe' (-not (Get-FleetLaunchRelayVerdict '' '' $false))
Check 'an unstamped fixture on an official -Relay is refused' ([bool](Get-FleetLaunchRelayVerdict '' 'relay.anonlisten.com' $false))
Check 'a fixture moved to another test relay of the run passes' (-not (Get-FleetLaunchRelayVerdict '127.0.0.2:9' '127.0.0.1:9' $false @('127.0.0.2:9')))
$env:FLEET_RELAY_ALSO = 'B.example:8443, a.example,'
Check 'the probe is told every relay of the run, boot relay first' ((Get-FleetProbeExpect 'c.example') -eq 'c.example,b.example:8443,a.example')
$env:FLEET_RELAY_ALSO = 'a.example,relay.anonlisten.com'
Check 'FLEET_RELAY_ALSO naming the official relay is refused' ([bool](Throws { Get-FleetAlsoRelays }))
$env:FLEET_RELAY_ALSO = $null

# --- the opt-in --------------------------------------------------------------
Check 'a production verdict throws' ([bool](Throws { Assert-FleetGuardVerdict 'x' 'why' }))
$script:FleetAllowProduction = $true
Check '-AllowProduction lifts it' (-not (Throws { Assert-FleetGuardVerdict 'x' 'why' }))
$script:FleetAllowProduction = $null
$env:UI_PROBE_ALLOW_PRODUCTION = '1'
. (Join-Path $PSScriptRoot 'fleet_relay_guard.ps1')
Check 'UI_PROBE_ALLOW_PRODUCTION=1 when a script loads lifts it' (-not (Throws { Assert-FleetGuardVerdict 'x' 'why' }))
$env:UI_PROBE_ALLOW_PRODUCTION = $null
$script:FleetAllowProduction = $null
. (Join-Path $PSScriptRoot 'fleet_relay_guard.ps1')
$env:UI_PROBE_ALLOW_PRODUCTION = '1'
Check 'an opt-in set in the env after a script loaded lifts nothing' ([bool](Throws { Assert-FleetGuardVerdict 'x' 'why' }))
$env:UI_PROBE_ALLOW_PRODUCTION = $null
$null = Throws { Invoke-FleetWithEnv @{ UI_PROBE_ALLOW_PRODUCTION = '1' } { throw 'a launch that fails' } }
Check 'an env set for one launch is gone after it throws' (-not [Environment]::GetEnvironmentVariable('UI_PROBE_ALLOW_PRODUCTION'))
$probeText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ui_probe.ps1'))
Check 'ui_probe.ps1 sets the opt-in only for its flutter drive' ($probeText -notmatch '\$env:UI_PROBE_ALLOW_PRODUCTION\s*=' -and $probeText -match 'Invoke-FleetWithEnv @\{ UI_PROBE_ALLOW_PRODUCTION')

# --- what a remote machine is told ------------------------------------------
$fwd = @(Add-FleetRelayArgs @('-Live', '-NetProxy', '-Peers', 'q') '127.0.0.1:9')
Check 'remote runs get the relay' (($fwd -join ' ') -match '-Relay 127\.0\.0\.1:9')
Check 'remote runs get no opt-in by default' ($fwd -notcontains '-AllowProduction')
$script:FleetAllowProduction = $true
Check 'remote runs carry the opt-in' (@(Add-FleetRelayArgs @('-Live') '') -contains '-AllowProduction')
$script:FleetAllowProduction = $false
Check 'a remote -Stop takes no relay' (@(Add-FleetRelayArgs @('-Stop') '127.0.0.1:9') -notcontains '-Relay')
$env:FLEET_RELAY = '127.0.0.1:9'
Check 'FLEET_RELAY is the run relay' ((Get-FleetExpectedRelay '') -eq '127.0.0.1:9')
$env:FLEET_RELAY = $null

# --- the first connect line ---------------------------------------------------
$lines = @(
    '[1760054400] [HOLLOW-WS] Connecting to wss://relay.anonlisten.com/ws... at 12:00:01 order 1',
    '[1760054400] [HOLLOW-WS] Connecting to wss://hollowtest.duckdns.org/ws... at 12:00:01 order 2',
    '[1760054400] [HOLLOW-WS] Connecting to wss://141.227.186.209:443/ws...',
    '[1760054400] [HOLLOW-WS] Connected')
$hits = @(Get-FleetProdConnectLines $lines)
Check 'connect lines naming the official relay are found' ($hits.Count -eq 2 -and $hits[0] -match 'relay\.anonlisten' -and $hits[1] -match '141\.227')

# --- the probe's marker -------------------------------------------------------
$mark = ConvertFrom-FleetRelayGuardMarker '{"guard":"on","verdict":"refused","where":"node start","reason":"x"}'
Check "the probe's refusal marker reads" ($mark.verdict -eq 'refused' -and $mark.where -eq 'node start')
Check 'a torn marker reads as none' ($null -eq (ConvertFrom-FleetRelayGuardMarker '{"guard":'))

# --- fleet.ps1 itself, from a sandbox -----------------------------------------
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-guard-selftest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$sandScripts = Join-Path $sandbox 'scripts'
New-Item -ItemType Directory -Path $sandScripts -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $sandScripts
Copy-Item -Path (Join-Path $PSScriptRoot 'probe_scenarios') -Destination $sandScripts -Recurse
$sandTools = Join-Path (Join-Path $sandbox 'tools') 'zombie_proxy'
New-Item -ItemType Directory -Path $sandTools -Force | Out-Null
Copy-Item -Path (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'zombie_proxy') 'zombie_proxy.py') -Destination $sandTools
$sandHome = Join-Path $sandbox 'home'
New-Item -ItemType Directory -Path $sandHome -Force | Out-Null
$windows = -not ($IsMacOS -or $IsLinux)
# ssh and node that only write down that they ran, first on the sandbox's PATH; ssh -G
# answers as the real one does (the host part of its last argument), dialling nothing.
$sandBin = Join-Path $sandbox 'bin'
$callLog = Join-Path $sandbox 'calls.log'
New-Item -ItemType Directory -Path $sandBin -Force | Out-Null
foreach ($tool in 'ssh', 'node') {
    if ($windows) {
        $cmd = "@echo off`r`necho $tool %*>>`"$callLog`"`r`n"
        if ($tool -eq 'ssh') { $cmd += "if not `"%~1`"==`"-G`" exit /b 1`r`nfor %%a in (%*) do set last=%%~a`r`nset last=%last:*@=%`r`necho hostname %last%`r`nexit /b 0`r`n" }
        [System.IO.File]::WriteAllText((Join-Path $sandBin "$tool.cmd"), $cmd + "exit /b 1`r`n")
    } else {
        $fake = Join-Path $sandBin $tool
        $sh = "#!/bin/sh`necho `"$tool `$*`" >> '$callLog'`n"
        if ($tool -eq 'ssh') { $sh += "if [ `"`$1`" = -G ]; then for a; do last=`$a; done; echo `"hostname `${last#*@}`"; exit 0; fi`n" }
        [System.IO.File]::WriteAllText($fake, $sh + "exit 1`n")
        & chmod +x $fake
    }
}
# A staged peer z whose launch fails after fleet.ps1 has set the guard env for it.
$sandStage = Join-Path (Join-Path (Join-Path $sandbox 'build') 'fleet') 'z'
if ($IsMacOS) {
    $macOsDir = Join-Path (Join-Path (Join-Path $sandStage 'Hollow.app') 'Contents') 'MacOS'
    New-Item -ItemType Directory -Path $macOsDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $macOsDir 'Hollow'), "#!/bin/sh`nexit 0`n")
    [System.IO.File]::WriteAllText((Join-Path (Split-Path $macOsDir) 'Info.plist'),
        '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>LSUIElement</key><true/></dict></plist>')
} else {
    New-Item -ItemType Directory -Path $sandStage -Force | Out-Null
    $exeName = if ($IsLinux) { 'hollow' } else { 'hollow.exe' }
    [System.IO.File]::WriteAllText((Join-Path $sandStage $exeName), '')
}
function Get-SandCalls { if (Test-Path $callLog) { return @(Get-Content $callLog) } return @() }
$shell = if ($windows) { 'powershell' } else { 'pwsh' }
$fixtures = if ($windows) { Join-Path $sandHome 'hollow_fleet\fixtures' }
            elseif ($IsMacOS) { Join-Path (Join-Path $sandHome 'hollow_fleet') 'fixtures-macos' }
            else { Join-Path (Join-Path $sandHome 'hollow_fleet') 'fixtures' }

function Invoke-SandFleet([string[]]$fleetArgs, [hashtable]$extraEnv = @{}, [string]$script = 'fleet.ps1', [string]$command = '') {
    $saved = @{}
    $set = @{ HOME = $sandHome; TEMP = $sandHome; TMP = $sandHome; FLEET_RELAY = $null; FLEET_RELAY_CONNECT = $null; UI_PROBE_ALLOW_PRODUCTION = $null
        FLEET_RELAY_SSH = $null; FLEET_RELAY_SSH_OPTS = $null; FLEET_RELAY_ALSO = $null; PATH = ($sandBin + [System.IO.Path]::PathSeparator + $env:PATH) }
    if ($IsMacOS) { $set['FLEET_BACKEND'] = 'macos' } else { $set['FLEET_BACKEND'] = $null }
    foreach ($k in $extraEnv.Keys) { $set[$k] = $extraEnv[$k] }
    foreach ($k in $set.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
    Remove-Item $callLog -ErrorAction SilentlyContinue
    try {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $sandScripts $script)) + $fleetArgs + @('-BootTimeoutSeconds', '5')
        if ($command) { $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) }
        # Windows PowerShell 5.1 turns a child's stderr into a terminating error under Stop.
        $ErrorActionPreference = 'Continue'
        $text = (& $shell @all 2>&1 | ForEach-Object { "$_" }) -join "`n"
        # pwsh 7 colours and wraps an error across "| " lines: read it as one line of text.
        $text = [regex]::Replace([regex]::Replace($text, '\x1b\[[0-9;]*m', ''), '[ \t]*\n[ \t]*\|[ \t]*', ' ')
        return [pscustomobject]@{ code = $LASTEXITCODE; text = $text }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}
function Check-Refused([string]$name, $run) {
    Check $name ($run.code -ne 0 -and $run.text -match 'PRODUCTION RELAY GUARD' -and $run.text -notmatch 'no build output|launched [a-z] ') ($run.text -split "`n" | Select-Object -Last 4 | Out-String)
}
function Check-Allowed([string]$name, $run) {
    Check $name ($run.code -eq 0 -and $run.text -match 'relay guard: this run may start') ($run.text -split "`n" | Select-Object -Last 4 | Out-String)
}
function Set-SandFixture([string]$peer, [string]$stamp) {
    $dir = Join-Path $fixtures $peer
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if ($stamp) { Set-FleetRelayStamp $dir $stamp }
}

try {
    Check-Refused 'fleet.ps1 -Onboard with no relay is refused' (Invoke-SandFleet @('-Onboard', '-Peers', 'z', '-GuardOnly'))
    Check-Refused 'fleet.ps1 -Onboard -Relay <official> is refused' (Invoke-SandFleet @('-Onboard', '-Relay', 'relay.anonlisten.com', '-Peers', 'z', '-GuardOnly'))
    Check-Refused 'fleet.ps1 -Onboard -Relay <official address> is refused' (Invoke-SandFleet @('-Onboard', '-Relay', '141.227.186.209', '-Peers', 'z', '-GuardOnly'))
    Check-Refused 'a real -Onboard run (no -GuardOnly) is refused before it stops or launches anything' (Invoke-SandFleet @('-Onboard', '-Relay', 'relay.anonlisten.com', '-Peers', 'z'))
    Check-Refused 'FLEET_RELAY=<official> is refused' (Invoke-SandFleet @('-Onboard', '-Peers', 'z', '-GuardOnly') @{ FLEET_RELAY = 'relay.anonlisten.com' })
    Check-Allowed 'fleet.ps1 -Onboard -Relay <test relay> may start' (Invoke-SandFleet @('-Onboard', '-Relay', '127.0.0.1:9', '-Peers', 'z', '-GuardOnly'))
    Check-Allowed 'FLEET_RELAY=<test relay> onboards' (Invoke-SandFleet @('-Onboard', '-Peers', 'z', '-GuardOnly') @{ FLEET_RELAY = '127.0.0.1:9' })
    $loud = Invoke-SandFleet @('-Onboard', '-Relay', 'relay.anonlisten.com', '-Peers', 'z', '-GuardOnly', '-AllowProduction')
    Check 'fleet.ps1 -AllowProduction lets it through, loudly' ($loud.code -eq 0 -and $loud.text -match 'PRODUCTION RELAY ALLOWED') ($loud.text | Out-String)

    Set-SandFixture 'z' 'relay.anonlisten.com'
    Check-Refused '-Live onto a fixture stamped with the official relay is refused' (Invoke-SandFleet @('-Live', '-Peers', 'z', '-GuardOnly'))
    Set-SandFixture 'z' '127.0.0.1:9'
    Check-Refused "-Live onto a fixture of another relay than -Relay is refused" (Invoke-SandFleet @('-Live', '-Relay', '127.0.0.2:9', '-Peers', 'z', '-GuardOnly'))
    Check-Allowed '-Live onto a fixture of the test relay may start' (Invoke-SandFleet @('-Live', '-Relay', '127.0.0.1:9', '-Peers', 'z', '-GuardOnly'))
    Set-SandFixture 'z' ''
    $unstamped = Invoke-SandFleet @('-Live', '-Peers', 'z', '-GuardOnly')
    Check 'an unstamped fixture boots for the probe to judge, and says so' ($unstamped.code -eq 0 -and $unstamped.text -match 'judges its relay at node start') ($unstamped.text | Out-String)
    $noRelay = Invoke-SandFleet @('-Live', '-NetProxy', '-Peers', 'z', '-GuardOnly')
    Check-Refused '-NetProxy with no relay known is refused (the 11-14 VM leak)' $noRelay
    Check '... for having no relay, not a default' ($noRelay.text -match 'no relay to route') ($noRelay.text | Out-String)
    Set-SandFixture 'z' '127.0.0.1:9'
    Check-Refused '-NetProxy whose FLEET_RELAY_CONNECT is the official relay is refused' (Invoke-SandFleet @('-Live', '-NetProxy', '-Peers', 'z', '-GuardOnly') @{ FLEET_RELAY_CONNECT = '141.227.186.209:443' })
    Check-Allowed '-NetProxy to the stamped test relay may start' (Invoke-SandFleet @('-Live', '-NetProxy', '-Peers', 'z', '-GuardOnly'))

    # fleet_relay_restart.ps1 used to restart the production relay and log guest sockets into it by default.
    $restart = Invoke-SandFleet @('-SkipBuild') @{} 'fleet_relay_restart.ps1'
    Check-Refused 'fleet_relay_restart.ps1 with no relay is refused' $restart
    Check '... before any ssh or node call' ((Get-SandCalls).Count -eq 0) ((Get-SandCalls) -join '; ')
    $restart = Invoke-SandFleet @('-SkipBuild', '-RelayDomain', 'relay.anonlisten.com') @{ FLEET_RELAY_SSH = 'hollowsrv' } 'fleet_relay_restart.ps1'
    Check-Refused 'fleet_relay_restart.ps1 -RelayDomain <official> is refused' $restart
    Check '... before any ssh or node call ' ((Get-SandCalls).Count -eq 0) ((Get-SandCalls) -join '; ')
    $restart = Invoke-SandFleet @('-SkipBuild') @{ FLEET_RELAY = '127.0.0.1:9' } 'fleet_relay_restart.ps1'
    Check-Refused 'fleet_relay_restart.ps1 with no relay box to ssh to is refused' $restart
    $restart = Invoke-SandFleet @('-SkipBuild', '-RelayHost', 'ubuntu@141.227.186.209') @{ FLEET_RELAY = '127.0.0.1:9' } 'fleet_relay_restart.ps1'
    Check-Refused "fleet_relay_restart.ps1 -RelayHost <the official box> is refused" $restart
    Check '... as the official relay' ($restart.text -match "is the official relay \(141\.227\.186\.209\)") ($restart.text -split "`n" | Select-Object -Last 6 | Out-String)
    Check '... having run no remote ssh and no node' (@(Get-SandCalls | Where-Object { $_ -notmatch '^ssh -G ' }).Count -eq 0) ((Get-SandCalls) -join '; ')

    # One process, as an interactive shell is: a launch that throws after Start-Peer set the
    # opt-in for its child must leave nothing behind for the next run.
    $fleetPath = (Join-Path $sandScripts 'fleet.ps1').Replace("'", "''")
    $oneShell = "`$ErrorActionPreference='Continue'; try { & '$fleetPath' -Live -Relay 127.0.0.1:9 -AllowProduction -Peers z -BootTimeoutSeconds 5 } catch { Write-Host ('LAUNCH-FAILED: ' + `$_) }; " +
        "Write-Host ('ALLOW-LEFT=[' + `$env:UI_PROBE_ALLOW_PRODUCTION + ']'); & '$fleetPath' -Onboard -Peers z -GuardOnly"
    Set-SandFixture 'z' ''
    $shell1 = Invoke-SandFleet @() @{ FLEET_MAC_DIRECT = $null; SSH_CONNECTION = $null } '' $oneShell
    Check '... the launch failed after the env was set' ($shell1.text -match 'LAUNCH-FAILED: .*(ssh|valid application|launching z)') ($shell1.text -split "`n" | Select-String 'z|launch' | Out-String)
    Check 'a failed -AllowProduction launch leaves no opt-in in the shell' ($shell1.text -match 'ALLOW-LEFT=\[\]') ($shell1.text -split "`n" | Select-String 'ALLOW-LEFT|launch' | Out-String)
    Check '... so the next run in that shell is refused' ($shell1.code -ne 0 -and ($shell1.text -split 'ALLOW-LEFT')[-1] -match 'PRODUCTION RELAY GUARD') ($shell1.text -split "`n" | Select-Object -Last 4 | Out-String)
} finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# --- the welcome steps the journeys share --------------------------------------
. (Join-Path $PSScriptRoot 'fleet_lib.ps1')
Check 'welcome steps with no relay are refused' ([bool](Throws { Get-RelayWelcomeSteps '' }))
Check 'welcome steps onto the official relay are refused' ([bool](Throws { Get-RelayWelcomeSteps 'relay.anonlisten.com' }))
Check 'welcome steps onto a test relay are typed' (@(Get-RelayWelcomeSteps '127.0.0.1:9').Count -eq 4)

# --- a journey's own launch ---------------------------------------------------------
$jRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-guard-journey-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$savedOutRoot = $script:FleetOutRoot
try {
    $script:FleetOutRoot = Join-Path $jRoot 'out'
    $empty = Join-Path $jRoot 'empty'
    Check 'a journey peer onboarding with no relay is refused' ([bool](Throws { Get-FleetJourneyLaunchPlan 'z' $empty }))
    $env:FLEET_RELAY = '127.0.0.1:9'
    $plan = Get-FleetJourneyLaunchPlan 'z' $empty
    Check "a journey peer onboarding on the run's relay is stamped with it" ($plan.fresh -and (Get-FleetRelayStamp $empty) -eq '127.0.0.1:9' -and $plan.env.UI_PROBE_EXPECT_RELAY -eq '127.0.0.1:9')
    Check "... and its node's dial guard is armed" (Test-Path (Join-Path $empty $script:FleetDialGuardFile))
    $prodData = Join-Path $jRoot 'prod'
    Set-FleetRelayStamp $prodData 'relay.anonlisten.com'
    [System.IO.File]::WriteAllText((Join-Path $prodData 'messages.db'), 'x')
    Check 'a journey relaunch on data stamped with the official relay is refused' ([bool](Throws { Get-FleetJourneyLaunchPlan 'z' $prodData }))
    $env:FLEET_RELAY = $null
    $script:FleetAllowProduction = $true
    $null = Get-FleetJourneyLaunchPlan 'z' $empty
    Check 'an opted-in launch disarms the dial guard' (-not (Test-Path (Join-Path $empty $script:FleetDialGuardFile)))
    $script:FleetAllowProduction = $false

    $markerDir = Join-Path $script:FleetOutRoot 'z'
    New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    $markerFile = Join-Path $markerDir $script:FleetRelayGuardMarker
    $script:FleetJourneyLogOffsets = @{ z = 0 }
    $script:TestLog = @('[1] [HOLLOW-WS] Connecting to wss://127.0.0.1:9/ws...')
    function Get-PeerAppLogSince($peer, $offset) { return $script:TestLog }
    Check 'a journey peer whose build has no relay guard voids the run' ([bool](Throws { Assert-FleetJourneyRelayLogs }))
    [System.IO.File]::WriteAllText($markerFile, '{"guard":"on","verdict":"armed"}')
    Check 'a guarded journey peer on a test relay passes' (-not (Throws { Assert-FleetJourneyRelayLogs }))
    [System.IO.File]::WriteAllText($markerFile, '{"guard":"on","verdict":"refused","where":"node start","reason":"x"}')
    Check 'a journey peer that refused its relay voids the run' ((Throws { Assert-FleetJourneyRelayLogs }) -match 'refused the relay at node start')
    [System.IO.File]::WriteAllText($markerFile, '{"guard":"on","verdict":"passed"}')
    $script:TestLog += '[2] [HOLLOW-WS] Connecting to wss://relay.anonlisten.com/ws...'
    Check 'a journey peer that dialled the official relay voids the run' ((Throws { Assert-FleetJourneyRelayLogs }) -match 'RUN VOID')
    Check "... and the journey's verdict says so" ("$(Add-FleetJourneyRelayVoid $null)" -match 'RUN VOID')
    $script:FleetJourneyLogOffsets = @{}
} finally {
    $script:FleetOutRoot = $savedOutRoot
    $env:FLEET_RELAY = $null
    $script:FleetAllowProduction = $false
    Remove-Item $jRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- what every script must do -------------------------------------------------
$guardFiles = @('fleet_relay_guard.ps1', 'fleet_relay_guard_selftest.ps1')
$scripts = @(Get-ChildItem (Join-Path $PSScriptRoot '*.ps1') | Where-Object { $guardFiles -notcontains $_.Name })
function Get-CodeLines($file) {
    return @([System.IO.File]::ReadAllLines($file.FullName) | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -notmatch '^\s*#' })
}
$unguarded = @()
$selfLaunch = @()
$bareWelcome = @()
foreach ($file in $scripts) {
    $code = Get-CodeLines $file
    $text = $code -join "`n"
    if ($text -match 'relay\.anonlisten\.com|141\.227\.186\.209|2001:41d0:ab01' -and $text -notmatch 'Assert-FleetNotProduction|Assert-FleetGuardVerdict') { $unguarded += $file.Name }
    # A journey's own launch skips every check above; fleet.ps1 is the launcher, and the
    # lifecycle foreground op resumes an app whose probe.env fleet.ps1 wrote.
    if ($file.Name -notin @('fleet.ps1', 'fleet_lib.ps1')) {
        foreach ($line in $code) {
            if ($line -match "Start-Process\b.*(hollow\.exe|launcher)" -or ($line -match 'simctl\s+launch' -and $line -match 'com\.anonlisten\.hollow' -and $file.Name -ne 'fleet_lifecycle.ps1')) {
                $selfLaunch += "$($file.Name): $($line.Trim())"
            }
        }
    }
    if ($file.Name -ne 'fleet.ps1') {
        for ($i = 0; $i -lt $code.Count; $i++) {
            if ($code[$i] -notmatch "op = 'wait_for'; target = 'text:Create an identity'") { continue }
            $near = ($code[[Math]::Max(0, $i - 4)..[Math]::Min($code.Count - 1, $i + 2)]) -join "`n"
            if ($near -notmatch 'Get-RelayWelcomeSteps') { $bareWelcome += "$($file.Name): $($code[$i].Trim())" }
        }
    }
}
Check 'every script naming the official relay calls the guard' ($unguarded.Count -eq 0) ($unguarded -join ', ')
Check 'no journey launches a peer outside Start-FleetJourneyPeer' ($selfLaunch.Count -eq 0) ($selfLaunch -join ' | ')
Check 'every welcome walk types the relay through Get-RelayWelcomeSteps' ($bareWelcome.Count -eq 0) ($bareWelcome -join ' | ')
$journeys = @($scripts | Where-Object { (Get-CodeLines $_) -match 'Start-FleetJourneyPeer' -and $_.Name -ne 'fleet_lib.ps1' })
$noScan = @($journeys | Where-Object { -not ((Get-CodeLines $_) -match 'Assert-FleetJourneyRelayLogs|Add-FleetJourneyRelayVoid|Get-FleetJourneyRelayVoid') } | ForEach-Object { $_.Name })
Check "every journey judges its peers' relay logs before its verdict ($($journeys.Count) journeys)" ($journeys.Count -ge 16 -and $noScan.Count -eq 0) ($noScan -join ', ')

# --- the proxy ---------------------------------------------------------------
Check 'a proxy with no relay is refused for having none, never given a default' ((Throws { Resolve-FleetProxyUpstream '' }) -match 'no relay to route to')
Check 'a proxy to the official relay is refused' ([bool](Throws { Resolve-FleetProxyUpstream 'relay.anonlisten.com' }))
$env:FLEET_RELAY_CONNECT = '127.0.0.1:9'
Check 'a proxy for the official relay is refused even when its route is a test listener' ((Throws { Resolve-FleetProxyUpstream 'relay.anonlisten.com' }) -match 'zombie proxy relay')
$env:FLEET_RELAY_CONNECT = $null
$env:FLEET_RELAY_CONNECT = '[2001:41d0:ab01::4:0:d]:443'
Check "a proxy whose upstream is the official relay's address is refused" ([bool](Throws { Resolve-FleetProxyUpstream '127.0.0.1:9' }))
$env:FLEET_RELAY_CONNECT = $null
Check 'a proxy to a test relay is allowed' ((Resolve-FleetProxyUpstream '127.0.0.1:9').upstream -eq '127.0.0.1:9')
$python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
$proxyOut = & {
    $ErrorActionPreference = 'Continue'
    & $python (Join-Path (Join-Path (Join-Path $repoRoot 'tools') 'zombie_proxy') 'zombie_proxy.py') serve --control 127.0.0.1:0 --route 'z=127.0.0.1:0=relay.anonlisten.com:443' 2>&1
}
Check 'zombie_proxy.py refuses an official route by itself' ($LASTEXITCODE -eq 3 -and "$proxyOut" -match 'PRODUCTION RELAY GUARD') "$proxyOut"

# --- the certificate a route presents ----------------------------------------------
$openssl = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $openssl) {
    Write-Host 'SKIP certificate checks: no openssl on this machine to mint a throwaway certificate' -ForegroundColor Yellow
} else {
    $certDir = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-guard-tls-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    $server = Join-Path $certDir 'serve.py'
    [System.IO.File]::WriteAllText($server, @'
import socket, ssl, sys
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
s = socket.socket()
s.bind(('127.0.0.1', 0))
s.listen(8)
with open(sys.argv[3], 'w') as f:
    f.write(str(s.getsockname()[1]))
while True:
    conn, _ = s.accept()
    try:
        ctx.wrap_socket(conn, server_side=True).close()
    except Exception:
        conn.close()
'@)
    try {
        foreach ($case in @(@{ cn = 'relay.anonlisten.com'; prod = $true }, @{ cn = 'hollowtest.duckdns.org'; prod = $false })) {
            $cert = Join-Path $certDir "$($case.cn).pem"
            $key = Join-Path $certDir "$($case.cn).key"
            # A config file of its own: some openssl builds (Strawberry Perl's) ship none.
            $cfg = Join-Path $certDir "$($case.cn).cnf"
            [System.IO.File]::WriteAllText($cfg, "[req]`ndistinguished_name = dn`nprompt = no`n[dn]`nCN = $($case.cn)`n")
            $said = & {
                $ErrorActionPreference = 'Continue'
                & openssl req -x509 -newkey rsa:2048 -nodes -keyout $key -out $cert -days 1 -config $cfg 2>&1
            }
            if (-not (Test-Path $cert)) {
                Write-Host "SKIP certificate checks: openssl could not mint a throwaway certificate ($("$said".Trim()))" -ForegroundColor Yellow
                break
            }
            $portFile = Join-Path $certDir "$($case.cn).port"
            $start = @{ FilePath = (Get-Command $python).Source; ArgumentList = @($server, $cert, $key, $portFile); PassThru = $true }
            if ($windows) { $start['WindowStyle'] = 'Hidden' }
            $proc = Start-Process @start
            try {
                $deadline = (Get-Date).AddSeconds(10)
                while (-not (Test-Path $portFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
                Start-Sleep -Milliseconds 200
                if (-not (Test-Path $portFile)) { Check "a TLS test server came up ($($case.cn))" $false 'serve.py wrote no port'; continue }
                $port = [int]([System.IO.File]::ReadAllText($portFile))
                $seen = Get-FleetTlsNames '127.0.0.1' $port 'hollowtest.duckdns.org'
                Check "the certificate at a route is read ($($case.cn))" ($seen.ok -and @($seen.names) -contains $case.cn) ($seen | ConvertTo-Json -Compress)
                $why = Throws { Assert-FleetTlsNotProduction 'route' "127.0.0.1:$port" 'hollowtest.duckdns.org' }
                if ($case.prod) { Check 'a route answering with the official certificate is refused (the 11-14 leak)' ([bool]$why) }
                else { Check "a route answering with the test relay's certificate passes" (-not $why) $why }
            } finally {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        Remove-Item $certDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:Failed.Count -gt 0) {
    Write-Host "relay guard self-test: $($script:Passed) passed, $($script:Failed.Count) FAILED: $($script:Failed -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host "relay guard self-test: all $($script:Passed) checks passed" -ForegroundColor Green
exit 0
