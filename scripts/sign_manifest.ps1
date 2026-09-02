<#
.SYNOPSIS
    Hash, sign, upload and verify the update manifest (the last release step).

.DESCRIPTION
    The app only installs an update when (a) manifest.json.sig verifies against
    the Ed25519 key baked into rust/hollow_core/src/api/updater.rs and (b) the
    downloaded zip hashes to the sha256_<platform> field of its entry. This
    script produces both from the files ALREADY UPLOADED to the release folder,
    so the hashes describe exactly what clients will download:

      1. hollow-manifest fill-hashes legal/manifest.json   (downloads each url_*)
      2. hollow-manifest sign        legal/manifest.json   -> legal/manifest.json.sig
      3. scp manifest.json + manifest.json.sig to the release host
      4. hollow-manifest verify --url <live manifest>       (the app's check)

    Run it AFTER every zip/dmg/flatpak/apk is in place and legal/manifest.json
    has its new versions[] entry. The private key path comes from
    scripts\release.local.env (MANIFEST_SIGNING_KEY); the key never enters the
    repo. Both manifest.json and manifest.json.sig ARE committed (legal/), so
    the repo carries what the host serves.

.PARAMETER SkipUpload
    Hash + sign + verify locally only (no scp).

.PARAMETER LocalDir
    Folder holding the release artifacts (e.g. installer\Output). Files found
    there by name are hashed locally instead of downloaded; anything missing is
    still downloaded from its URL.
#>
[CmdletBinding()]
param(
    [switch]$SkipUpload,
    [string]$LocalDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repo 'legal\manifest.json'
$sig = "$manifest.sig"
$toolDir = Join-Path $repo 'rust\hollow_manifest'
$tool = Join-Path $toolDir 'target\release\hollow-manifest.exe'
$manifestUrl = 'https://anonlisten.com/hollow/releases/manifest.json'

# --- release.local.env: MANIFEST_SIGNING_KEY (+ optional RELEASE_SSH / RELEASE_DIR) ---
$envFile = Join-Path $PSScriptRoot 'release.local.env'
if (-not (Test-Path $envFile)) { throw "scripts\release.local.env not found (copy release.local.env.example)" }
$cfg = @{}
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    $i = $line.IndexOf('=')
    if ($i -gt 0) { $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
}
$keyPath = $cfg['MANIFEST_SIGNING_KEY']
if (-not $keyPath) { throw "MANIFEST_SIGNING_KEY missing in release.local.env" }
if (-not (Test-Path $keyPath)) { throw "Signing key not found: $keyPath" }
$sshTarget = if ($cfg['RELEASE_SSH']) { $cfg['RELEASE_SSH'] } else { 'hostinger' }
$remoteDir = if ($cfg['RELEASE_DIR']) { $cfg['RELEASE_DIR'] } else { '~/domains/anonlisten.com/public_html/hollow/releases' }

# --- The public key the app trusts, read from updater.rs so the two cannot drift ---
$updaterRs = Get-Content (Join-Path $repo 'rust\hollow_core\src\api\updater.rs') -Raw
$pubkeys = [regex]::Matches($updaterRs, '"([0-9a-f]{64})"') | ForEach-Object { $_.Groups[1].Value }
if (-not $pubkeys) { throw "No MANIFEST_SIGNING_PUBKEYS entry found in updater.rs" }

# --- Build the tool (fast; own tiny crate) ---
Push-Location $toolDir
try { cargo build --release | Out-Null } finally { Pop-Location }
if (-not (Test-Path $tool)) { throw "hollow-manifest did not build" }

Write-Host "[1/4] Hashing every url_* in $manifest" -ForegroundColor Cyan
$hashArgs = @('fill-hashes', $manifest)
if ($LocalDir) { $hashArgs += @('--dir', $LocalDir) }
& $tool @hashArgs
if ($LASTEXITCODE -ne 0) { throw "fill-hashes failed" }

Write-Host "[2/4] Signing" -ForegroundColor Cyan
& $tool sign $manifest --key $keyPath --out $sig
if ($LASTEXITCODE -ne 0) { throw "sign failed" }

# The signature must verify against a key the APP carries, not just the key we hold.
$ok = $false
foreach ($pk in $pubkeys) {
    & $tool verify $manifest $sig --pubkey $pk | Out-Null
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
}
if (-not $ok) { throw "manifest.json.sig does not verify against any key in updater.rs: the signing key and MANIFEST_SIGNING_PUBKEYS have drifted" }

if ($SkipUpload) {
    Write-Host "[3/4] Upload skipped (-SkipUpload)" -ForegroundColor Yellow
    Write-Host "[4/4] Local pair verifies. Upload legal\manifest.json + manifest.json.sig to $remoteDir when ready." -ForegroundColor Green
    exit 0
}

Write-Host "[3/4] Uploading manifest.json + manifest.json.sig to ${sshTarget}:$remoteDir" -ForegroundColor Cyan
# Signature first, then manifest: a client that reads mid-upload sees a
# signature that fails against the old manifest and simply retries later.
& scp -q $sig "${sshTarget}:$remoteDir/manifest.json.sig"
if ($LASTEXITCODE -ne 0) { throw "scp of manifest.json.sig failed" }
& scp -q $manifest "${sshTarget}:$remoteDir/manifest.json"
if ($LASTEXITCODE -ne 0) { throw "scp of manifest.json failed" }

Write-Host "[4/4] Verifying the LIVE pair the way the app does" -ForegroundColor Cyan
$live = $false
foreach ($pk in $pubkeys) {
    & $tool verify --url $manifestUrl --pubkey $pk
    if ($LASTEXITCODE -eq 0) { $live = $true; break }
}
if (-not $live) { throw "The live manifest does not verify. Clients will refuse to update until this is fixed." }
Write-Host "Done. Commit legal/manifest.json and legal/manifest.json.sig." -ForegroundColor Green
