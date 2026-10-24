<#
.SYNOPSIS
    Sign, upload and verify the release feeds (status.json, news.json, relay.json).

.DESCRIPTION
    Apps from 0.12.2 on show a feed only when its .sig sidecar verifies against
    the key baked into rust/hollow_core/src/api/updater.rs for THAT feed's
    name; an unsigned or edited-after-signing feed shows nothing. Apps up to
    0.12.1 read the files as before and never look at the sidecar.

    status.json and relay.json get `issued` rewritten before signing (--stamp):
    the highest of now, the file's issued + 1 and the LIVE copy's issued + 1,
    since apps and relay installers drop any copy stamped earlier than one they
    already accepted. A stamp over an hour past this clock is refused. Each
    feed is shape and size checked first (hollow-manifest feed-sign).

    relay.json (scripts/build_relay_binaries.sh) is read by self-hosters'
    installers (relay-uws/deploy/lib/release_feed.sh). Its tarballs must sit next
    to it (feed-sign opens each one) and already be live with the hashes it
    names; that is checked before the upload. A version and build below the
    live feed's needs -AllowDowngrade. Once the live pair verifies, the pair is
    copied to legal\relay.json(.sig) and the floors in release_feed.sh are
    raised to it: commit all three.

    Reads MANIFEST_SIGNING_KEY (+ optional RELEASE_SSH, RELEASE_DIR) from
    scripts\release.local.env. Bash twin: scripts/sign_feeds.sh.

.EXAMPLE
    & .\scripts\sign_feeds.ps1 -News legal\news.json
    & .\scripts\sign_feeds.ps1 -Status C:\path\status.json -SkipUpload
    & .\scripts\sign_feeds.ps1 -Relay build\relay-binaries\relay.json
#>
[CmdletBinding()]
param(
    [string]$Status = '',
    [string]$News = '',
    [string]$Relay = '',
    [switch]$AllowDowngrade,
    [switch]$SkipUpload
)

$ErrorActionPreference = 'Stop'
if (-not $Status -and -not $News -and -not $Relay) { throw "Nothing to sign: pass -Status, -News and/or -Relay" }
$repo = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $repo 'rust\hollow_manifest'
$tool = Join-Path $toolDir $(if ($env:OS -eq 'Windows_NT') { 'target\release\hollow-manifest.exe' } else { 'target/release/hollow-manifest' })
$baseUrl = 'https://anonlisten.com/hollow/releases'

$envFile = Join-Path $PSScriptRoot 'release.local.env'
if (-not (Test-Path $envFile)) { throw "scripts\release.local.env not found (copy release.local.env.example)" }
$cfg = @{}
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    $i = $line.IndexOf('=')
    if ($i -gt 0) { $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim().Trim('"') }
}
$keyPath = $cfg['MANIFEST_SIGNING_KEY']
if (-not $keyPath) { throw "MANIFEST_SIGNING_KEY missing in release.local.env" }
if (-not (Test-Path $keyPath)) { throw "Signing key not found: $keyPath" }
$sshTarget = if ($cfg['RELEASE_SSH']) { $cfg['RELEASE_SSH'] } else { 'hostinger' }
$remoteDir = if ($cfg['RELEASE_DIR']) { $cfg['RELEASE_DIR'] } else { '~/domains/anonlisten.com/public_html/hollow/releases' }

# The keys the APP trusts, from the MANIFEST_SIGNING_PUBKEYS list only.
$updaterRs = Get-Content (Join-Path $repo 'rust\hollow_core\src\api\updater.rs') -Raw
$block = [regex]::Match($updaterRs, 'const MANIFEST_SIGNING_PUBKEYS[^=]*=\s*&\[[^\]]*\]').Value
$pubkeys = [regex]::Matches($block, '"([0-9a-f]{64})"') | ForEach-Object { $_.Groups[1].Value }
if (-not $pubkeys) { throw "No MANIFEST_SIGNING_PUBKEYS entry found in updater.rs" }

Push-Location $toolDir
try { cargo build --release | Out-Null } finally { Pop-Location }
if (-not (Test-Path $tool)) { throw "hollow-manifest did not build" }

function Record-Relay([string]$file) {
    $legal = Join-Path $repo 'legal\relay.json'
    if ((Resolve-Path $file).Path -ne $legal) {
        Copy-Item $file $legal -Force
        Copy-Item "$file.sig" "$legal.sig" -Force
    }
    & $tool relay-floor $legal (Join-Path $repo 'relay-uws\deploy\lib\release_feed.sh')
    if ($LASTEXITCODE -ne 0) { throw "[relay] could not raise the floors in release_feed.sh; set them to legal\relay.json by hand" }
}

function Sign-Feed([string]$feed, [string]$file) {
    if (-not (Test-Path $file)) { throw "$file not found" }
    Write-Host "[$feed] signing $file" -ForegroundColor Cyan
    $signArgs = @('feed-sign', $file, '--feed', $feed, '--key', $keyPath, '--out', "$file.sig")
    if ($feed -eq 'status' -or $feed -eq 'relay') { $signArgs += @('--stamp', '--live', "$baseUrl/$feed.json") }
    if ($feed -eq 'relay' -and $AllowDowngrade) { $signArgs += '--allow-downgrade' }
    & $tool @signArgs
    if ($LASTEXITCODE -ne 0) { throw "feed-sign failed for $file" }
    $ok = $false
    foreach ($pk in $pubkeys) {
        & $tool feed-verify $file "$file.sig" --feed $feed --pubkey $pk | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    }
    if (-not $ok) { throw "$file.sig does not verify against any key in updater.rs: key and MANIFEST_SIGNING_PUBKEYS have drifted" }
    if ($SkipUpload) { Write-Host "[$feed] local pair verifies; upload skipped" -ForegroundColor Yellow; return }
    if ($feed -eq 'relay') {
        & $tool relay-check-live $file
        if ($LASTEXITCODE -ne 0) { throw "[relay] upload the tarballs relay.json names before the feed" }
    }
    # Signature first: a reader between the two copies sees a pair that fails
    # and shows nothing until its next poll.
    & scp -q "$file.sig" "${sshTarget}:$remoteDir/$feed.json.sig"
    if ($LASTEXITCODE -ne 0) { throw "scp of $feed.json.sig failed" }
    & scp -q $file "${sshTarget}:$remoteDir/$feed.json"
    if ($LASTEXITCODE -ne 0) { throw "scp of $feed.json failed" }
    foreach ($pk in $pubkeys) {
        & $tool feed-verify --url "$baseUrl/$feed.json" --feed $feed --pubkey $pk
        if ($LASTEXITCODE -eq 0) {
            if ($feed -eq 'relay') { Record-Relay $file }
            return
        }
    }
    throw "[$feed] the LIVE pair does not verify (a CDN copy can lag up to 10 minutes; recheck with feed-verify --url before touching anything)"
}

if ($News) { Sign-Feed 'news' $News }
if ($Status) { Sign-Feed 'status' $Status }
if ($Relay) { Sign-Feed 'relay' $Relay }
Write-Host "Done. Commit legal\news.json + legal\news.json.sig when news changed; legal\relay.json, legal\relay.json.sig and relay-uws\deploy\lib\release_feed.sh when the relay changed." -ForegroundColor Green
