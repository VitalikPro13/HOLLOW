# The production relay guard, shared by fleet.ps1, fleet_lib.ps1, fleet_lifecycle.ps1
# (the proxy), fleet_remote.ps1 (agents) and ui_probe.ps1: a fleet or probe peer never
# reaches the official relay (anything under anonlisten.com, or its addresses) unless
# the run opted in with -AllowProduction or UI_PROBE_ALLOW_PRODUCTION=1.
#
# Layers, each refusing on its own: these checks before a launch (the relay a fixture
# carries, -Relay, the proxy's upstream and the certificate that route presents), the
# zombie proxy's own upstream check, the probe's guard inside the app (relay setting,
# node start, Dart HTTP to the relay; integration_test/probe/probe_relay_guard.dart),
# and after boot the provider's relay and the app log's "[HOLLOW-WS] Connecting to".
# The self-test is scripts/fleet_relay_guard_selftest.ps1.
#
# Windows PowerShell 5.1: no pwsh-only syntax.

$script:FleetProdSuffix = 'anonlisten.com'
$script:FleetProdRelayNames = @('relay.anonlisten.com', 'anonlisten.com')
# The official relay's own addresses, for a route that names a bare address or a
# name that resolves there. Live resolution of the names above adds to these.
$script:FleetProdRelayAddrs = @('141.227.186.209', '2001:41d0:ab01::4:0:d')
# What the probe's relay setting holds when the data directory names no relay (which
# in the real app means the official one); it never resolves.
$script:FleetUnstampedRelay = 'no-relay-stamped.invalid'
# The relay a fixture was onboarded onto, one line in the data directory.
$script:FleetRelayStampFile = 'fleet_relay'
# What the probe writes into its out directory: the guard is on, and its verdicts.
$script:FleetRelayGuardMarker = 'relay_guard.json'
# What arms the node's own guard (debug builds, node/fleet_relay_guard.rs) in a data dir,
# for its relay dials and push fetches, the ones no probe sees.
$script:FleetDialGuardFile = 'relay_guard'
# Other test relays a peer may move to during the run (FLEET_RELAY_ALSO, comma list), as
# a relay-switch journey does: each is judged like -Relay and the probe accepts them too.
$script:FleetAlsoRelayEnv = 'FLEET_RELAY_ALSO'
# The opt-in is read ONCE, when a script loads this file: an env var another script in
# the same PowerShell process set and left behind must not lift a later run's guard.
if ($null -eq $script:FleetAllowProduction) { $script:FleetAllowProduction = ("$env:UI_PROBE_ALLOW_PRODUCTION" -eq '1') }

# host:port of a relay setting, lowercased, without scheme, user, path or trailing dot.
function ConvertTo-FleetRelayHostPort([string]$text) {
    $s = "$text".Trim().ToLowerInvariant()
    $at = $s.IndexOf('://')
    if ($at -ge 0) { $s = $s.Substring($at + 3) }
    $slash = $s.IndexOfAny([char[]]@('/', '?', '#'))
    if ($slash -ge 0) { $s = $s.Substring(0, $slash) }
    $user = $s.LastIndexOf('@')
    if ($user -ge 0) { $s = $s.Substring($user + 1) }
    if ($s.StartsWith('[')) { return $s }
    if (([regex]::Matches($s, ':')).Count -eq 1) {
        $parts = $s.Split(':')
        return $parts[0].TrimEnd('.') + ':' + $parts[1]
    }
    return $s.TrimEnd('.')
}

# Just the host of a relay setting or route (an IPv6 literal without brackets).
function ConvertTo-FleetRelayHost([string]$text) {
    $s = ConvertTo-FleetRelayHostPort $text
    if ($s.StartsWith('[')) {
        $end = $s.IndexOf(']')
        if ($end -gt 0) { return $s.Substring(1, $end - 1) }
        return $s.Trim('[')
    }
    if (([regex]::Matches($s, ':')).Count -eq 1) { return $s.Split(':')[0] }
    return $s
}

function ConvertTo-FleetPlainAddress([System.Net.IPAddress]$ip) {
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    return $ip.ToString()
}

function Test-FleetProdAddress([System.Net.IPAddress]$ip, $known = $null) {
    if ($null -eq $known) { $known = $script:FleetProdRelayAddrs }
    $plain = ConvertTo-FleetPlainAddress $ip
    foreach ($entry in @($known)) {
        $other = $null
        if ([System.Net.IPAddress]::TryParse("$entry", [ref]$other) -and (ConvertTo-FleetPlainAddress $other) -eq $plain) { return $true }
    }
    return $false
}

# Why a relay setting, route or certificate name is the official relay, judged by its
# text alone (no DNS); '' when it is not.
function Get-FleetProdNameReason([string]$text) {
    $name = ConvertTo-FleetRelayHost $text
    if (-not $name) { return 'names no relay, which means the official one' }
    $suffix = $script:FleetProdSuffix
    $bare = $name.TrimStart('*').TrimStart('.')
    if ($bare -eq $suffix -or $bare.EndsWith(".$suffix")) { return "$name is under $suffix, the official relay" }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$ip) -and (Test-FleetProdAddress $ip)) { return "$name is the official relay's address" }
    return ''
}

function Get-FleetAddresses([string]$name) {
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$ip)) { return @($ip) }
    try { return @([System.Net.Dns]::GetHostAddresses($name)) } catch { return @() }
}

# The official relay's addresses: the pinned ones and what its names resolve to now.
function Get-FleetProdAddresses {
    if ($null -eq $script:FleetProdAddrCache) {
        $all = @($script:FleetProdRelayAddrs)
        foreach ($name in $script:FleetProdRelayNames) { $all += @(Get-FleetAddresses $name | ForEach-Object { ConvertTo-FleetPlainAddress $_ }) }
        $script:FleetProdAddrCache = @($all | Select-Object -Unique)
    }
    return $script:FleetProdAddrCache
}

# Get-FleetProdNameReason, then where the name resolves. A name that does not resolve
# passes: nothing can dial it.
function Get-FleetProdReason([string]$text) {
    $why = Get-FleetProdNameReason $text
    if ($why) { return $why }
    $name = ConvertTo-FleetRelayHost $text
    if ($name -eq $script:FleetUnstampedRelay) { return '' }
    $prod = Get-FleetProdAddresses
    foreach ($ip in @(Get-FleetAddresses $name)) {
        if (Test-FleetProdAddress $ip $prod) { return "$name resolves to the official relay ($(ConvertTo-FleetPlainAddress $ip))" }
    }
    return ''
}

function Test-FleetProductionAllowed {
    return [bool]$script:FleetAllowProduction
}

# Runs $body with these environment variables set (a child launched inside inherits
# them) and puts back what was there however $body ends.
function Invoke-FleetWithEnv([hashtable]$vars, [scriptblock]$body) {
    $saved = @{}
    foreach ($k in @($vars.Keys)) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $vars[$k])
    }
    try { & $body } finally {
        foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

function Write-FleetProductionBanner([string]$what) {
    Write-Host ''
    Write-Host "[fleet] !!! PRODUCTION RELAY ALLOWED: $what" -ForegroundColor Red
    Write-Host '[fleet] !!! -AllowProduction (or UI_PROBE_ALLOW_PRODUCTION=1) lets these peers reach the OFFICIAL relay with throwaway identities.' -ForegroundColor Red
    Write-Host ''
}

function New-FleetGuardError([string]$what, [string]$why) {
    return "PRODUCTION RELAY GUARD refused: $what ($why). Fleet and probe peers never reach the official relay: " +
        'onboard and run them on the test relay (-Relay hollowtest.duckdns.org, or FLEET_RELAY=hollowtest.duckdns.org). ' +
        'A run that truly needs the official relay says -AllowProduction.'
}

# Throws unless the run allows production; $why = '' passes.
function Assert-FleetGuardVerdict([string]$what, [string]$why) {
    if (-not $why) { return }
    if (Test-FleetProductionAllowed) { Write-FleetProductionBanner "$what ($why)"; return }
    throw (New-FleetGuardError $what $why)
}

function Assert-FleetNotProduction([string]$what, [string]$value, [switch]$NoResolve) {
    $why = if ($NoResolve) { Get-FleetProdNameReason $value } else { Get-FleetProdReason $value }
    Assert-FleetGuardVerdict "$what $value" $why
}

# The relay this run names: -Relay, else FLEET_RELAY; '' when neither.
function Get-FleetExpectedRelay([string]$explicit) {
    $value = if ($explicit) { $explicit } else { "$env:FLEET_RELAY" }
    return (ConvertTo-FleetRelayHostPort $value)
}

# FLEET_RELAY_ALSO as host:port entries, each refused when it is the official relay.
function Get-FleetAlsoRelays {
    $all = @()
    foreach ($entry in @("$([Environment]::GetEnvironmentVariable($script:FleetAlsoRelayEnv))" -split ',')) {
        $hp = ConvertTo-FleetRelayHostPort $entry
        if (-not $hp) { continue }
        Assert-FleetNotProduction "$($script:FleetAlsoRelayEnv) entry" $hp
        if ($all -notcontains $hp) { $all += $hp }
    }
    return $all
}

# UI_PROBE_EXPECT_RELAY for a peer: the relay it boots on, then the ones it may move to.
function Get-FleetProbeExpect([string]$relay) {
    $set = @()
    foreach ($r in @(@(ConvertTo-FleetRelayHostPort $relay) + @(Get-FleetAlsoRelays))) {
        if ($r -and $set -notcontains $r) { $set += $r }
    }
    return ($set -join ',')
}

# The names a TLS route presents (subject CN and every SAN entry), or why it could not
# be read. The certificate is only read, never trusted.
function Get-FleetTlsNames([string]$connectHost, [int]$port, [string]$sni, [int]$timeoutMs = 5000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($connectHost, $port)
        if (-not $task.Wait($timeoutMs) -or -not $client.Connected) { return [pscustomobject]@{ ok = $false; names = @(); error = "no connection to ${connectHost}:$port" } }
        $client.ReceiveTimeout = $timeoutMs
        $client.SendTimeout = $timeoutMs
        # A compiled callback: pwsh may run a scriptblock one on a thread with no runspace.
        if (-not ('HollowFleetGuard.AcceptAny' -as [type])) {
            Add-Type -TypeDefinition @'
namespace HollowFleetGuard {
    public static class AcceptAny {
        static bool Check(object s, System.Security.Cryptography.X509Certificates.X509Certificate c,
            System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; }
        public static System.Net.Security.RemoteCertificateValidationCallback Callback { get { return Check; } }
    }
}
'@
        }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, [HollowFleetGuard.AcceptAny]::Callback)
        try {
            $ssl.AuthenticateAsClient($sni)
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
            $names = @()
            if ($cert.Subject -match 'CN=([^,]+)') { $names += $Matches[1].Trim() }
            foreach ($ext in $cert.Extensions) {
                if ($ext.Oid.Value -ne '2.5.29.17') { continue }
                foreach ($part in ($ext.Format($false) -split '[,\r\n]+')) {
                    $entry = ($part.Trim() -replace '^(DNS Name|DNS|IP Address|IP)\s*[:=]\s*', '').Trim()
                    if ($entry) { $names += $entry }
                }
            }
            return [pscustomobject]@{ ok = $true; names = @($names | Select-Object -Unique); error = '' }
        } finally { $ssl.Dispose() }
    } catch {
        return [pscustomobject]@{ ok = $false; names = @(); error = "$($_.Exception.Message)" }
    } finally { $client.Close() }
}

function Get-FleetCertProdReason($names) {
    foreach ($name in @($names)) {
        $why = Get-FleetProdNameReason "$name"
        if ($why -and "$name".Trim()) { return "the certificate there names $name" }
    }
    return ''
}

# The route a peer dials (host:port) must not present the official relay's certificate
# for the relay it names. A route that does not answer passes with a note: a peer
# cannot reach anything through it either.
function Assert-FleetTlsNotProduction([string]$what, [string]$route, [string]$relay) {
    $hp = ConvertTo-FleetRelayHostPort $route
    $connectHost = ConvertTo-FleetRelayHost $hp
    $port = 443
    if ($hp -match ':(\d+)$') { $port = [int]$Matches[1] }
    $sni = ConvertTo-FleetRelayHost $relay
    if (-not $sni) { $sni = $connectHost }
    $seen = Get-FleetTlsNames $connectHost $port $sni
    if (-not $seen.ok) {
        Write-Host "[fleet] relay guard: could not read the certificate at ${connectHost}:$port for $sni ($($seen.error)); the app's own checks judge it" -ForegroundColor Yellow
        return
    }
    Assert-FleetGuardVerdict "$what ${connectHost}:$port for $sni" (Get-FleetCertProdReason $seen.names)
}

# The relay URLs of every "[HOLLOW-WS] Connecting to" line that names the official relay.
function Get-FleetProdConnectLines($lines) {
    $hits = @()
    foreach ($line in @($lines)) {
        $m = [regex]::Match("$line", '\[HOLLOW-WS\] Connecting to (\S+?)(\.\.\.|\s|$)')
        if (-not $m.Success) { continue }
        if (Get-FleetProdNameReason $m.Groups[1].Value) { $hits += "$line" }
    }
    return $hits
}

# The relay a data directory carries (fleet_relay), '' when it has none.
function Get-FleetRelayStamp([string]$dataDir) {
    if (-not $dataDir) { return '' }
    $file = Join-Path $dataDir $script:FleetRelayStampFile
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    return (ConvertTo-FleetRelayHostPort ([System.IO.File]::ReadAllText($file)))
}

function Set-FleetRelayStamp([string]$dataDir, [string]$relay) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dataDir $script:FleetRelayStampFile), "$relay`n")
}

# Arms the node's guard in a data dir, or takes it away for an opted-in run.
function Set-FleetDialGuard([string]$dataDir) {
    $file = Join-Path $dataDir $script:FleetDialGuardFile
    if (Test-FleetProductionAllowed) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; return }
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    [System.IO.File]::WriteAllText($file, "on`n")
}

# The probe's marker (relay_guard.json) as an object, $null when absent or unreadable.
function ConvertFrom-FleetRelayGuardMarker([string]$text) {
    if (-not "$text".Trim()) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# Why a peer may not boot with this data directory, '' when it may: what it carries,
# what the run expects, and whether it is about to onboard.
function Get-FleetLaunchRelayVerdict([string]$stamp, [string]$expected, [bool]$onboard, $also = @()) {
    if ($onboard) {
        if (-not $expected) { return 'onboarding with no -Relay makes an identity on the official relay' }
        return (Get-FleetProdReason $expected)
    }
    if ($stamp) {
        $why = Get-FleetProdReason $stamp
        if ($why) { return "its data directory carries $stamp`: $why" }
        if ($expected -and $stamp -ne $expected -and @($also) -notcontains $stamp) { return "its data directory carries $stamp, not this run's relay $expected" }
        return ''
    }
    if ($expected) { return (Get-FleetProdReason $expected) }
    return ''
}

# fleet.ps1 arguments for another machine's run, with this run's relay and opt-in:
# a remote machine judges with what the driver knows, never with its own defaults.
function Add-FleetRelayArgs($fleetArgs, [string]$relay) {
    $all = @($fleetArgs)
    if ($relay -and $all -notcontains '-Relay' -and $all -notcontains '-Stop') { $all += @('-Relay', $relay) }
    $also = "$([Environment]::GetEnvironmentVariable($script:FleetAlsoRelayEnv))"
    if ($also -and $all -notcontains '-RelayAlso' -and $all -notcontains '-Stop') { $all += @('-RelayAlso', $also) }
    if ((Test-FleetProductionAllowed) -and $all -notcontains '-AllowProduction') { $all += '-AllowProduction' }
    return $all
}
