use std::fs;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use ed25519_dalek::{Signature, VerifyingKey};
use flutter_rust_bridge::frb;
use futures_util::StreamExt;
use sha2::{Digest, Sha256};

use super::network::get_runtime;
use crate::frb_generated::StreamSink;
use crate::identity::data_dir;

pub(crate) const APP_VERSION: &str = "0.14.3";

/// The quick-patch number on top of [`APP_VERSION`]: 0 for the release itself, 1 for
/// the first same-version patch, shown as `0.12.2+1`. Separate from pubspec's `+N`,
/// which is the Android versionCode / iOS build.
pub(crate) const APP_BUILD: u32 = 0;

/// The highest `build` a manifest entry may carry; it names download and staging paths.
const MAX_BUILD: u32 = 9999;

/// Keys allowed to sign `manifest.json`; the private half never enters the repo.
/// More than one entry only during a key rotation.
const MANIFEST_SIGNING_PUBKEYS: &[&str] = &[
    "b6fcb5b64cd5317b470b31ac08892528b0d5c9e82c6cdaa13654a7c9e7f8b09c",
];

pub struct DownloadProgress {
    pub bytes_downloaded: u64,
    pub total_bytes: u64,
    /// Set on the final item when the download was refused or failed
    /// (checksum mismatch, non-https URL, transport error). The partial file
    /// is already deleted by then; Dart shows the reason and stops.
    pub error: Option<String>,
}

#[frb(sync)]
pub fn get_current_version() -> String {
    APP_VERSION.to_string()
}

#[frb(sync)]
pub fn get_current_build() -> u32 {
    APP_BUILD
}

/// How this Linux copy of Hollow was installed: `"flatpak"` or `"tarball"`, empty
/// elsewhere. Dart branches its update UI on it (a flatpak's `/app` is read-only, so
/// the "can I write to the app dir" probe is meaningless there) and every Linux path
/// below reads the SAME detection.
#[frb(sync)]
pub fn linux_install_kind() -> String {
    install_kind_impl()
}

#[cfg(target_os = "linux")]
fn install_kind_impl() -> String {
    linux_install_kind_inner().to_string()
}

#[cfg(not(target_os = "linux"))]
fn install_kind_impl() -> String {
    String::new()
}

/// Fetches `manifest.json` AND its `manifest.json.sig` sidecar, returning the manifest
/// text only when the signature verifies against [`MANIFEST_SIGNING_PUBKEYS`]. The
/// signature covers the exact bytes, so what Dart gets is byte for byte what was
/// signed.
#[frb]
pub fn fetch_version_manifest(manifest_url: String) -> Result<String, String> {
    let rt = get_runtime();
    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| format!("Failed to build HTTP client: {e}"))?;
        let manifest = fetch_bytes(&client, &manifest_url, MANIFEST_CAP)
            .await
            .map_err(|e| format!("Failed to fetch manifest: {e}"))?;
        let sig = fetch_bytes(&client, &signature_url(&manifest_url), SIG_CAP)
            .await
            .map_err(|e| format!("Failed to fetch manifest signature: {e}"))?;
        verify_manifest_signature(&manifest, &String::from_utf8_lossy(&sig))?;
        manifest_versions_well_formed(&manifest)?;
        String::from_utf8(manifest).map_err(|_| "Update manifest is not UTF-8".to_string())
    })
}

/// Fetches a release feed (`status.json`, `news.json`) AND its `.sig` sidecar,
/// returning the text only when the signature verifies for THIS feed name (see
/// [`feed_message`]). Dart treats any error as "nothing to show".
#[frb]
pub fn fetch_signed_feed(url: String, feed: String) -> Result<String, String> {
    let cap = fetch_cap(&feed).ok_or_else(|| "Unknown release feed".to_string())?;
    let rt = get_runtime();
    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| format!("Failed to build HTTP client: {e}"))?;
        let body = fetch_bytes(&client, &url, cap)
            .await
            .map_err(|e| format!("Failed to fetch feed: {e}"))?;
        let sig = fetch_bytes(&client, &signature_url(&url), SIG_CAP)
            .await
            .map_err(|e| format!("Failed to fetch feed signature: {e}"))?;
        signed_feed_text(&feed, body, &String::from_utf8_lossy(&sig), MANIFEST_SIGNING_PUBKEYS)
    })
}

/// The feed text, only when `sig_text` verifies it for `feed` under a listed key.
fn signed_feed_text(feed: &str, body: Vec<u8>, sig_text: &str, pubkeys_hex: &[&str]) -> Result<String, String> {
    verify_feed_signature_with(feed, &body, sig_text, pubkeys_hex)?;
    String::from_utf8(body).map_err(|_| "Feed is not UTF-8".to_string())
}

/// Read caps, enforced while the body streams so a hostile or broken host cannot
/// make the app hold more; over the cap is an error and nothing is parsed.
/// news.json grows a post at a time (20 KB at 0.12.1), hence its larger cap.
/// `rust/hollow_manifest` refuses to sign anything over them.
const MANIFEST_CAP: usize = 1024 * 1024;
const SIG_CAP: usize = 64 * 1024;

fn fetch_cap(feed: &str) -> Option<usize> {
    match feed {
        "status" => Some(64 * 1024),
        "news" => Some(256 * 1024),
        _ => None,
    }
}

async fn fetch_bytes(client: &reqwest::Client, url: &str, cap: usize) -> Result<Vec<u8>, String> {
    let mut resp = client
        .get(url)
        .header("Cache-Control", "no-cache")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("server returned {}", resp.status()));
    }
    let too_big = || format!("response is over {cap} bytes");
    if resp.content_length().is_some_and(|n| n > cap as u64) {
        return Err(too_big());
    }
    let mut body = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| e.to_string())? {
        if body.len() + chunk.len() > cap {
            return Err(too_big());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// `.../manifest.json?t=123` becomes `.../manifest.json.sig?t=123`: the
/// sidecar sits next to the manifest and rides the same cache-buster.
fn signature_url(manifest_url: &str) -> String {
    match manifest_url.split_once('?') {
        Some((path, query)) => format!("{path}.sig?{query}"),
        None => format!("{manifest_url}.sig"),
    }
}

/// The app's manifest check: base64 Ed25519 over the exact manifest bytes, accepted
/// when ANY listed key verifies it under strict verification, so a malleable or
/// weak-key signature is refused too. Mirrors `verify_bytes` in rust/hollow_manifest.
pub(crate) fn verify_manifest_signature(manifest: &[u8], sig_text: &str) -> Result<(), String> {
    verify_manifest_signature_with(manifest, sig_text, MANIFEST_SIGNING_PUBKEYS)
}

fn verify_manifest_signature_with(
    manifest: &[u8],
    sig_text: &str,
    pubkeys_hex: &[&str],
) -> Result<(), String> {
    if signature_verifies(manifest, sig_text, pubkeys_hex) {
        Ok(())
    } else {
        Err("Update manifest signature does not verify. The download host may have been tampered with; nothing was installed.".to_string())
    }
}

/// True when `sig_text` is a base64 Ed25519 signature over `msg` by ANY listed key,
/// under strict verification so a malleable or weak-key signature is refused too.
fn signature_verifies(msg: &[u8], sig_text: &str, pubkeys_hex: &[&str]) -> bool {
    let Ok(sig) = base64::engine::general_purpose::STANDARD.decode(sig_text.trim()) else {
        return false;
    };
    let Ok(sig) = Signature::from_slice(&sig) else {
        return false;
    };
    pubkeys_hex.iter().any(|hex_key| {
        hex::decode(hex_key)
            .ok()
            .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
            .and_then(|bytes| VerifyingKey::from_bytes(&bytes).ok())
            .is_some_and(|vk| vk.verify_strict(msg, &sig).is_ok())
    })
}

/// The feeds a signature may name.
const FEEDS: &[&str] = &["status", "news"];

const FEED_SIG_CONTEXT: &[u8] = b"hollow-feed-sig-v1\0";

/// What a feed signature covers: a fixed context, the feed's name and the exact
/// bytes. The manifest is signed bare and starts with `{`, so no feed signature
/// can pass as a manifest signature, nor one feed's as the other's. Mirrors
/// `feeds::feed_message` in rust/hollow_manifest (`feed_signature_kat` in both).
fn feed_message(feed: &str, bytes: &[u8]) -> Result<Vec<u8>, String> {
    if !FEEDS.contains(&feed) {
        return Err("Unknown release feed".to_string());
    }
    let mut msg = Vec::with_capacity(FEED_SIG_CONTEXT.len() + feed.len() + 1 + bytes.len());
    msg.extend_from_slice(FEED_SIG_CONTEXT);
    msg.extend_from_slice(feed.as_bytes());
    msg.push(0);
    msg.extend_from_slice(bytes);
    Ok(msg)
}

fn verify_feed_signature_with(
    feed: &str,
    bytes: &[u8],
    sig_text: &str,
    pubkeys_hex: &[&str],
) -> Result<(), String> {
    if signature_verifies(&feed_message(feed, bytes)?, sig_text, pubkeys_hex) {
        Ok(())
    } else {
        Err("Feed signature does not verify".to_string())
    }
}

/// True for a release version as the manifest carries it: three dot-separated
/// decimal parts, `0.12.0`.
///
/// SECURITY (C-DIST-06): a version names the download and the staging folder and
/// is written into the generated update script, so nothing else may reach them.
pub(crate) fn is_release_version(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| (1..=5).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_digit()))
}

/// Refuses a signed manifest whose `latest` or any listed `version` is not
/// [`is_release_version`], or where two readable entries name one release, before
/// Dart can pick one to download. A malformed `build` or `critical` is not refused
/// here: Dart skips that entry alone (`VersionInfo.id`).
fn manifest_versions_well_formed(manifest: &[u8]) -> Result<(), String> {
    let refused = || "Update manifest names a malformed version; nothing was installed.".to_string();
    let doc: serde_json::Value = serde_json::from_slice(manifest).map_err(|_| refused())?;
    let latest = doc.get("latest").and_then(|v| v.as_str());
    let listed = doc.get("versions").and_then(|v| v.as_array()).ok_or_else(refused)?;
    let mut seen = std::collections::HashSet::new();
    for e in listed {
        let version = e.get("version").and_then(|v| v.as_str()).filter(|v| is_release_version(v));
        let Some(version) = version else { return Err(refused()) };
        let Some(build) = readable_build(e) else { continue };
        let parts: Vec<u64> = version.split('.').filter_map(|p| p.parse().ok()).collect();
        if !seen.insert((parts, build)) {
            return Err("Update manifest lists one release twice; nothing was installed.".to_string());
        }
    }
    if latest.is_some_and(is_release_version) { Ok(()) } else { Err(refused()) }
}

/// The entry's build when Dart would offer it: `build` absent or an integer up to
/// [`MAX_BUILD`], `critical` absent or a boolean. Mirrors `VersionInfo.fromJson`.
fn readable_build(e: &serde_json::Value) -> Option<u64> {
    let build = match e.get("build") {
        None => 0,
        Some(b) => b.as_u64().filter(|n| *n <= u64::from(MAX_BUILD))?,
    };
    e.get("critical").is_none_or(serde_json::Value::is_boolean).then_some(build)
}

/// How a release names its files on disk: `0.12.2`, or `0.12.2-b1` for a patch, so a
/// patch never reuses the download or staging path of the version it patches.
fn release_tag(version: &str, build: u32) -> String {
    if build == 0 { version.to_string() } else { format!("{version}-b{build}") }
}

/// How a release is named to a person: `0.12.2`, or `0.12.2+1` for a patch.
fn release_display(version: &str, build: u32) -> String {
    if build == 0 { version.to_string() } else { format!("{version}+{build}") }
}

/// A checksum the manifest hands us must be 64 hex characters before a
/// single byte is downloaded against it.
fn normalise_expected_sha256(expected: &str) -> Result<String, String> {
    let e = expected.trim().to_ascii_lowercase();
    if e.len() != 64 || !e.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("The manifest carries no valid checksum for this download".to_string());
    }
    Ok(e)
}

/// Downloads `url` to `dest_path` and keeps the file ONLY if its SHA-256 matches the
/// value from the signed manifest. Any failure, a mismatch included, deletes the
/// partial file and ends the stream with `DownloadProgress::error` set.
#[frb]
pub fn download_update(
    url: String,
    dest_path: String,
    expected_sha256: String,
    sink: StreamSink<DownloadProgress>,
) -> Result<(), String> {
    let rt = get_runtime();
    rt.spawn(async move {
        if let Err(e) = download_inner(&url, &dest_path, &expected_sha256, &sink).await {
            let _ = tokio::fs::remove_file(&dest_path).await;
            let _ = sink.add(DownloadProgress {
                bytes_downloaded: 0,
                total_bytes: 0,
                error: Some(e.clone()),
            });
            crate::hollow_log!("[updater] Download failed: {e}");
        }
    });
    Ok(())
}

async fn download_inner(
    url: &str,
    dest_path: &str,
    expected_sha256: &str,
    sink: &StreamSink<DownloadProgress>,
) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;

    let expected = normalise_expected_sha256(expected_sha256)?;
    if !url.starts_with("https://") {
        return Err("Update downloads must use https".to_string());
    }
    let resp = reqwest::get(url)
        .await
        .map_err(|e| format!("Request failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("Server returned {}", resp.status()));
    }

    let total_bytes = resp.content_length().unwrap_or(0);
    let mut hasher = Sha256::new();

    let dest = PathBuf::from(dest_path);
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("Failed to create download directory: {e}"))?;
    }

    let mut file = tokio::fs::File::create(&dest)
        .await
        .map_err(|e| format!("Failed to create file: {e}"))?;

    let mut bytes_downloaded: u64 = 0;
    let mut stream = resp.bytes_stream();

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Stream error: {e}"))?;
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("Write error: {e}"))?;
        hasher.update(&chunk);
        bytes_downloaded += chunk.len() as u64;

        if sink
            .add(DownloadProgress {
                bytes_downloaded,
                total_bytes,
                error: None,
            })
            .is_err()
        {
            // Dart dropped the stream (cancel). The caller deletes the partial file.
            return Err("Download cancelled".to_string());
        }
    }
    file.flush().await.map_err(|e| format!("Write error: {e}"))?;
    drop(file);

    let actual = hex::encode(hasher.finalize());
    if actual != expected {
        return Err("Checksum mismatch: the downloaded file is not the one the signed manifest describes. Nothing was installed.".to_string());
    }

    Ok(())
}

#[cfg(test)]
mod integrity_tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn signature_url_keeps_the_cache_buster() {
        assert_eq!(
            signature_url("https://h/x/manifest.json?t=5"),
            "https://h/x/manifest.json.sig?t=5"
        );
        assert_eq!(signature_url("https://h/x/manifest.json"), "https://h/x/manifest.json.sig");
    }

    #[test]
    fn manifest_signature_accepts_only_a_listed_key_over_exact_bytes() {
        let key = SigningKey::from_bytes(&[3u8; 32]);
        let listed = hex::encode(key.verifying_key().to_bytes());
        let manifest = br#"{"latest":"0.10.2","versions":[]}"#;
        let sig = b64(&key.sign(manifest).to_bytes());

        assert!(verify_manifest_signature_with(manifest, &sig, &[&listed]).is_ok());
        // A rotation list: the good key may sit anywhere in it.
        let other = hex::encode(SigningKey::from_bytes(&[4u8; 32]).verifying_key().to_bytes());
        assert!(verify_manifest_signature_with(manifest, &sig, &[&other, &listed]).is_ok());
        // Not listed: refused.
        assert!(verify_manifest_signature_with(manifest, &sig, &[&other]).is_err());
        // One flipped byte in the manifest: refused.
        let mut tampered = manifest.to_vec();
        tampered[12] ^= 1;
        assert!(verify_manifest_signature_with(&tampered, &sig, &[&listed]).is_err());
        // Garbage signatures never panic.
        assert!(verify_manifest_signature_with(manifest, "not base64!", &[&listed]).is_err());
        assert!(verify_manifest_signature_with(manifest, &b64(&[0u8; 10]), &[&listed]).is_err());
        assert!(verify_manifest_signature_with(manifest, "", &[&listed]).is_err());
    }

    #[test]
    fn the_baked_in_keys_are_well_formed() {
        for k in MANIFEST_SIGNING_PUBKEYS {
            let bytes = hex::decode(k).expect("hex");
            let bytes: [u8; 32] = bytes.try_into().expect("32 bytes");
            VerifyingKey::from_bytes(&bytes).expect("valid Ed25519 point");
        }
    }

    #[test]
    fn expected_checksum_must_be_64_hex() {
        assert_eq!(
            normalise_expected_sha256(&format!(" {} ", "AB".repeat(32))).unwrap(),
            "ab".repeat(32)
        );
        assert!(normalise_expected_sha256("").is_err());
        assert!(normalise_expected_sha256(&"a".repeat(63)).is_err());
        assert!(normalise_expected_sha256(&"g".repeat(64)).is_err());
    }

    /// Pins the feed signature scheme; rust/hollow_manifest's `feed_signature_kat`
    /// holds the same vector.
    #[test]
    fn feed_signature_kat() {
        let key = SigningKey::from_bytes(&[9u8; 32]);
        let listed = hex::encode(key.verifying_key().to_bytes());
        let body = br#"{"issued":1,"notices":[]}"#;
        let sig = "09MlGHO/bj7y1tDOrqfnwAHWmrTD14eEQGLMvL+XQCDpy3n3uf2J90wVOtu8nwzPYjLvx2doj3Fo/Rkq5QK1CA==";
        assert_eq!(b64(&key.sign(&feed_message("status", body).unwrap()).to_bytes()), sig);
        assert!(verify_feed_signature_with("status", body, sig, &[&listed]).is_ok());
    }

    /// One key signs the manifest and both feeds, so each signature must be
    /// worthless as any of the other two.
    #[test]
    fn a_feed_signature_never_passes_as_the_manifest_or_the_other_feed() {
        let key = SigningKey::from_bytes(&[3u8; 32]);
        let listed = hex::encode(key.verifying_key().to_bytes());
        let body = br#"{"latest":"0.12.2","versions":[]}"#;
        let as_status = b64(&key.sign(&feed_message("status", body).unwrap()).to_bytes());
        let as_news = b64(&key.sign(&feed_message("news", body).unwrap()).to_bytes());
        let as_manifest = b64(&key.sign(body).to_bytes());

        assert!(verify_feed_signature_with("status", body, &as_status, &[&listed]).is_ok());
        assert!(verify_feed_signature_with("news", body, &as_news, &[&listed]).is_ok());
        assert!(verify_manifest_signature_with(body, &as_manifest, &[&listed]).is_ok());

        assert!(verify_manifest_signature_with(body, &as_status, &[&listed]).is_err());
        assert!(verify_manifest_signature_with(body, &as_news, &[&listed]).is_err());
        assert!(verify_feed_signature_with("news", body, &as_status, &[&listed]).is_err());
        assert!(verify_feed_signature_with("status", body, &as_news, &[&listed]).is_err());
        assert!(verify_feed_signature_with("status", body, &as_manifest, &[&listed]).is_err());
        assert!(verify_feed_signature_with("news", body, &as_manifest, &[&listed]).is_err());
    }

    #[test]
    fn a_feed_signature_needs_a_listed_key_and_the_exact_bytes() {
        let key = SigningKey::from_bytes(&[3u8; 32]);
        let listed = hex::encode(key.verifying_key().to_bytes());
        let other = hex::encode(SigningKey::from_bytes(&[4u8; 32]).verifying_key().to_bytes());
        let body = br#"{"issued":5,"notices":[]}"#;
        let sig = b64(&key.sign(&feed_message("status", body).unwrap()).to_bytes());
        assert!(verify_feed_signature_with("status", body, &sig, &[&other, &listed]).is_ok());
        assert!(verify_feed_signature_with("status", body, &sig, &[&other]).is_err());
        let mut tampered = body.to_vec();
        tampered[10] ^= 1;
        assert!(verify_feed_signature_with("status", &tampered, &sig, &[&listed]).is_err());
        for garbage in ["", "not base64!", &b64(&[0u8; 10])] {
            assert!(verify_feed_signature_with("status", body, garbage, &[&listed]).is_err());
        }
        assert_eq!(signed_feed_text("status", body.to_vec(), &sig, &[&listed]).unwrap(), r#"{"issued":5,"notices":[]}"#);
        assert!(signed_feed_text("status", tampered.clone(), &sig, &[&listed]).is_err());
        assert!(signed_feed_text("news", body.to_vec(), &sig, &[&listed]).is_err());
        // An unlisted feed name refuses before anything is fetched or verified.
        assert!(verify_feed_signature_with("manifest", body, &sig, &[&listed]).is_err());
        assert!(fetch_signed_feed("https://invalid.invalid/x.json".into(), "manifest".into())
            .is_err_and(|e| e == "Unknown release feed"));
    }

    /// A malformed `build` or `critical` drops only its own entry (Dart skips it),
    /// so these fields never become wire limits like the three-part version.
    #[test]
    fn a_malformed_build_or_critical_skips_only_its_entry() {
        for ok in [
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":1}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2","build":0,"critical":false}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2","build":9999,"critical":true}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":10000}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":-1}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":1.5}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":"1"}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":null}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":{"n":1}}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":1,"critical":"yes"}]}"#,
        ] {
            assert!(manifest_versions_well_formed(ok.as_bytes()).is_ok(), "{ok} refused");
        }
        for bad in [
            r#"{"latest":"0.12.2+1","versions":[{"version":"0.12.2"}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2+1"}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2-b1","build":1}]}"#,
        ] {
            assert!(manifest_versions_well_formed(bad.as_bytes()).is_err(), "{bad} accepted");
        }
    }

    /// Two readable entries naming one release make the pick depend on order.
    #[test]
    fn a_manifest_repeating_a_version_and_build_is_refused() {
        for bad in [
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":1},{"version":"0.12.2","build":1}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":0}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.02"}]}"#,
        ] {
            assert!(manifest_versions_well_formed(bad.as_bytes()).is_err(), "{bad} accepted");
        }
        // An entry Dart skips names nothing, so it repeats nothing.
        for ok in [
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":"0"}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","critical":"no"}]}"#,
            r#"{"latest":"0.12.2","versions":[{"version":"0.12.2"},{"version":"0.12.2","build":1},{"version":"0.12.1"}]}"#,
        ] {
            assert!(manifest_versions_well_formed(ok.as_bytes()).is_ok(), "{ok} refused");
        }
    }

    /// Serves `body` once on a loopback port; `chunked` leaves out Content-Length
    /// so only the read itself can enforce the cap.
    fn serve_once(body: Vec<u8>, chunked: bool) -> String {
        use std::io::{Read as _, Write as _};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            let Ok((mut sock, _)) = listener.accept() else { return };
            let mut req = [0u8; 4096];
            let _ = sock.read(&mut req);
            let _ = if chunked {
                let mut out = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".to_vec();
                for part in body.chunks(16 * 1024) {
                    out.extend_from_slice(format!("{:x}\r\n", part.len()).as_bytes());
                    out.extend_from_slice(part);
                    out.extend_from_slice(b"\r\n");
                }
                out.extend_from_slice(b"0\r\n\r\n");
                sock.write_all(&out)
            } else {
                let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                sock.write_all(head.as_bytes()).and_then(|()| sock.write_all(&body))
            };
        });
        format!("http://{addr}/feed.json")
    }

    /// Answers two requests on one loopback port: `sig` for a path ending in
    /// `.sig`, `body` otherwise. `announce` sends that Content-Length instead and
    /// keeps the socket open after the short write, as a host lying about size would.
    fn serve_pair(body: Vec<u8>, sig: Vec<u8>, announce: Option<usize>) -> String {
        use std::io::{Read as _, Write as _};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            for _ in 0..2 {
                let Ok((mut sock, _)) = listener.accept() else { return };
                let mut req = [0u8; 4096];
                let n = sock.read(&mut req).unwrap_or(0);
                let line = String::from_utf8_lossy(&req[..n]).lines().next().unwrap_or("").to_string();
                let part = if line.contains(".sig") { &sig } else { &body };
                let len = announce.unwrap_or(part.len());
                let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n");
                let _ = sock.write_all(head.as_bytes()).and_then(|()| sock.write_all(part));
                if announce.is_some() {
                    std::thread::sleep(std::time::Duration::from_secs(2));
                }
            }
        });
        format!("http://{addr}/feed.json")
    }

    /// The caps are wired into both public fetches, for the body and the sidecar.
    #[test]
    fn the_public_fetches_apply_their_caps() {
        let status = fetch_cap("status").unwrap();
        let e = fetch_signed_feed(serve_pair(vec![b' '; status + 1], b"x".to_vec(), None), "status".into());
        assert!(e.as_ref().is_err_and(|e| e.starts_with("Failed to fetch feed: response is over")), "{e:?}");
        let e = fetch_signed_feed(serve_pair(b"{}".to_vec(), vec![b'A'; SIG_CAP + 1], None), "news".into());
        assert!(e.as_ref().is_err_and(|e| e.starts_with("Failed to fetch feed signature: response is over")), "{e:?}");
        let e = fetch_version_manifest(serve_pair(vec![b' '; MANIFEST_CAP + 1], b"x".to_vec(), None));
        assert!(e.as_ref().is_err_and(|e| e.starts_with("Failed to fetch manifest: response is over")), "{e:?}");
        let e = fetch_version_manifest(serve_pair(b"{}".to_vec(), vec![b'A'; SIG_CAP + 1], None));
        assert!(e.as_ref().is_err_and(|e| e.starts_with("Failed to fetch manifest signature: response is over")), "{e:?}");
    }

    /// A body announced over the cap is refused before any of it is read.
    #[test]
    fn a_body_announced_over_the_cap_is_refused_unread() {
        let cap = fetch_cap("status").unwrap();
        let e = fetch_capped(&serve_pair(b"{".to_vec(), Vec::new(), Some(cap + 1)), cap);
        assert!(e.as_ref().is_err_and(|e| e.contains("over")), "{e:?}");
    }

    fn fetch_capped(url: &str, cap: usize) -> Result<Vec<u8>, String> {
        get_runtime().block_on(async {
            let client = reqwest::Client::builder().no_proxy().build().expect("client");
            fetch_bytes(&client, url, cap).await
        })
    }

    #[test]
    fn a_feed_body_over_the_cap_is_refused() {
        let cap = fetch_cap("status").unwrap();
        for chunked in [false, true] {
            let at_cap = fetch_capped(&serve_once(vec![b'x'; cap], chunked), cap);
            assert_eq!(at_cap.map(|b| b.len()), Ok(cap), "chunked={chunked}");
            let over = fetch_capped(&serve_once(vec![b'x'; cap + 1], chunked), cap);
            assert!(over.is_err(), "a body one byte over the cap was read (chunked={chunked})");
        }
        assert!(fetch_cap("news").unwrap() >= 4 * 64 * 1024, "news.json is 20 KB and grows a post at a time");
        assert!(fetch_cap("manifest").is_none(), "the manifest has its own cap");
    }

    #[test]
    fn a_manifest_body_over_the_cap_is_refused() {
        for chunked in [false, true] {
            let over = fetch_capped(&serve_once(vec![b' '; MANIFEST_CAP + 1], chunked), MANIFEST_CAP);
            assert!(over.is_err(), "a manifest over its cap was read (chunked={chunked})");
        }
        let sig = fetch_capped(&serve_once(vec![b'A'; SIG_CAP + 1], true), SIG_CAP);
        assert!(sig.is_err(), "a signature over its cap was read");
    }

    #[test]
    fn a_patch_never_reuses_the_paths_of_the_release_it_patches() {
        assert_eq!(release_tag("0.12.2", 0), "0.12.2");
        assert_eq!(release_tag("0.12.2", 1), "0.12.2-b1");
        assert_eq!(release_display("0.12.2", 0), "0.12.2");
        assert_eq!(release_display("0.12.2", 1), "0.12.2+1");
        assert_ne!(release_tag("0.12.2", 1), release_tag("0.12.2", 0));
        assert_ne!(release_tag("0.12.2", 1), release_tag("0.12.21", 0));
    }

    fn zip_with_one_file(dir: &Path) -> PathBuf {
        use std::io::Write;
        let zip_path = dir.join("update.zip");
        let file = fs::File::create(&zip_path).expect("create zip");
        let mut writer = zip::ZipWriter::new(file);
        writer.start_file("hollow.exe", zip::write::SimpleFileOptions::default()).expect("entry");
        writer.write_all(b"exe").expect("write");
        writer.finish().expect("finish");
        zip_path
    }

    #[test]
    fn a_patch_stages_under_its_own_tag() {
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let zip = zip_with_one_file(tmp.path());
        let app = tmp.path().join("app");
        fs::create_dir_all(&app).expect("app dir");
        // The platform's later steps may refuse this fake archive; the staging name is
        // chosen before them.
        let _ = apply_update_at(tmp.path(), zip.to_str().unwrap(), app.to_str().unwrap(), "0.12.2", 1, &[]);
        assert!(tmp.path().join("updates").join("staging-0.12.2-b1").exists());
        assert!(!tmp.path().join("updates").join("staging-0.12.2").exists());
    }

    #[test]
    fn a_build_above_the_bound_stages_nothing() {
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let zip = zip_with_one_file(tmp.path());
        let app = tmp.path().join("app");
        fs::create_dir_all(&app).expect("app dir");
        let r = apply_update_at(tmp.path(), zip.to_str().unwrap(), app.to_str().unwrap(), "0.12.2", MAX_BUILD + 1, &[]);
        assert!(r.is_err(), "an out-of-range build was applied: {r:?}");
        assert!(!tmp.path().join("updates").exists(), "an out-of-range build staged files");
    }
}

#[frb]
pub fn apply_update(
    zip_path: String,
    app_dir: String,
    version: String,
    build: u32,
) -> Result<String, String> {
    let data = data_dir()?;
    apply_update_at(&data, &zip_path, &app_dir, &version, build, &relaunch_args()?)
}

/// Why an update refused: the relaunch would have dropped one of the app's arguments.
const UNCARRIED_ARGUMENT: &str = "Hollow was started with an argument the update cannot carry over, so nothing was installed. Start Hollow without it and try again.";

/// This process's argv without argv[0], for the post-update relaunch: dropping
/// `--portable` brings the app back on a DIFFERENT profile than the user ran.
fn relaunch_args() -> Result<Vec<String>, String> {
    carried_args(std::env::args_os().skip(1))
}

/// An argument that is not Unicode cannot be written into the script, so it
/// refuses rather than relaunching without it. A `hollow:` link the app was
/// started with is dropped: it was handled at that start, and a relaunch would
/// open it again (an invite, a share, a recovery link).
fn carried_args(args: impl IntoIterator<Item = std::ffi::OsString>) -> Result<Vec<String>, String> {
    let mut kept = Vec::new();
    for a in args {
        let a = a.into_string().map_err(|_| UNCARRIED_ARGUMENT.to_string())?;
        if !is_deep_link(&a) {
            kept.push(a);
        }
    }
    Ok(kept)
}

/// The scheme the OS hands a cold start (`hollow.exe "hollow://..."`, `%u` on Linux).
fn is_deep_link(arg: &str) -> bool {
    arg.get(..7).is_some_and(|scheme| scheme.eq_ignore_ascii_case("hollow:"))
}

/// A release as the apply paths name it: `tag` in file and folder names, `display`
/// in what a person or the log reads.
struct ReleaseName {
    tag: String,
    display: String,
}

/// Every platform's apply, behind the version check: nothing is extracted,
/// staged or scripted for a version that is not [`is_release_version`] or a
/// build above [`MAX_BUILD`].
fn apply_update_at(
    data: &Path,
    archive_path: &str,
    app_dir: &str,
    version: &str,
    build: u32,
    relaunch_args: &[String],
) -> Result<String, String> {
    if !is_release_version(version) || build > MAX_BUILD {
        return Err("Update version is malformed; nothing was installed.".to_string());
    }
    let rel = ReleaseName { tag: release_tag(version, build), display: release_display(version, build) };
    apply_update_impl(data, archive_path, app_dir, &rel, relaunch_args)
}

/// Linux: the download is either the portable tarball or a `.flatpak` bundle,
/// and the install kind decides which. Both end with a script path the caller
/// hands to [`launch_update_script`].
#[cfg(target_os = "linux")]
fn apply_update_impl(
    data: &Path,
    archive_path: &str,
    app_dir: &str,
    rel: &ReleaseName,
    _relaunch_args: &[String],
) -> Result<String, String> {
    match linux_install_kind_inner() {
        "flatpak" => apply_update_flatpak(data, archive_path, &rel.display),
        _ => apply_update_tarball(data, archive_path, app_dir, rel, std::process::id()),
    }
}

#[cfg(not(target_os = "linux"))]
fn apply_update_impl(
    data: &Path,
    zip_path: &str,
    app_dir: &str,
    rel: &ReleaseName,
    relaunch_args: &[String],
) -> Result<String, String> {
    let staging_dir = data.join("updates").join(format!("staging-{}", rel.tag));
    let version = &rel.display;

    if staging_dir.exists() {
        fs::remove_dir_all(&staging_dir)
            .map_err(|e| format!("Failed to clean staging dir: {e}"))?;
    }
    fs::create_dir_all(&staging_dir)
        .map_err(|e| format!("Failed to create staging dir: {e}"))?;

    // macOS: `ditto` preserves the `.app` bundle's executable permissions, symlinks and
    // code signature, all of which the Rust `zip` crate drops.
    #[cfg(target_os = "macos")]
    {
        let staging_str = staging_dir
            .to_str()
            .ok_or("Staging dir path is not valid UTF-8")?;
        let status = std::process::Command::new("/usr/bin/ditto")
            .args(["-x", "-k", zip_path, staging_str])
            .status()
            .map_err(|e| format!("Failed to run ditto: {e}"))?;
        if !status.success() {
            return Err(format!("ditto extraction failed (exit {status})"));
        }
        return write_macos_update_script(data, staging_str, zip_path, app_dir, version, relaunch_args);
    }

    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    {
        let _ = (zip_path, app_dir, version, relaunch_args);
        return Err("Auto-update is not supported on this platform yet".into());
    }

    #[cfg(target_os = "windows")]
    {
    let staging_str = bat_quoted_path(
        staging_dir
            .to_str()
            .ok_or("Staging dir path is not valid UTF-8")?,
    )?;
    let zip_path_str = bat_quoted_path(&zip_path.replace('/', "\\"))?;
    let app_dir = bat_quoted_path(app_dir)?;
    // Refused before anything is extracted: an argument the script cannot carry
    // must never relaunch the app without it.
    let relaunch = bat_relaunch_line(&format!("{app_dir}\\hollow.exe"), relaunch_args)?;

    extract_zip_to(zip_path, &staging_dir)?;

    let bat_path = data.join("updates").join("update.bat");
    let bat_content = update_bat_script(
        version,
        &staging_str,
        &zip_path_str,
        &app_dir,
        "hollow.exe",
        std::process::id(),
        &relaunch,
    );

    fs::write(&bat_path, bat_content)
        .map_err(|e| format!("Failed to write update script: {e}"))?;

    bat_path
        .to_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "Bat path is not valid UTF-8".to_string())
    }
}

/// What a copy still failing after its retries leaves on screen, before the key press
/// that tries again (`echo` lines: no characters cmd reads; the path rides quoted).
#[cfg(any(target_os = "windows", test))]
const COPY_FAILED_1: &str = "The update could not copy its files, so Hollow has not restarted yet.";
#[cfg(any(target_os = "windows", test))]
const COPY_FAILED_2: &str = "The new version is waiting in";
#[cfg(any(target_os = "windows", test))]
const COPY_FAILED_3: &str = "Close anything that uses the Hollow folder, then press any key to try again.";

/// How often a failed copy is tried again on its own, two seconds apart, before it asks.
#[cfg(any(target_os = "windows", test))]
const COPY_TRIES: u32 = 5;

/// `update.bat`: waits until process `wait_pid` (named `wait_image`, so a reused pid
/// is not waited on) is gone, copies the staged files over `app_dir`, cleans up and
/// runs `relaunch`. A copy that fails relaunches nothing (a half-copied app could
/// start on mismatched parts): it is tried again a few times, then again on each key
/// press, from the staged files it keeps. Every path argument is already
/// [`bat_quoted_path`] output. The script is UTF-8, so the code page switches before
/// the first line that may hold a non-ASCII path, and delayed expansion is off
/// whatever the registry says, so a `!` in a path or argument stays literal. The
/// retry delay is `ping`, not `timeout`, which fails at once without console input.
#[cfg(any(target_os = "windows", test))]
fn update_bat_script(
    version: &str,
    staging_str: &str,
    zip_path_str: &str,
    app_dir: &str,
    wait_image: &str,
    wait_pid: u32,
    relaunch: &str,
) -> String {
    format!(
        "@echo off\r\n\
         setlocal DisableDelayedExpansion\r\n\
         chcp 65001 >NUL\r\n\
         title Hollow Update\r\n\
         echo.\r\n\
         echo   ========================================\r\n\
         echo     Hollow Update - v{version}\r\n\
         echo   ========================================\r\n\
         echo.\r\n\
         echo   Waiting for Hollow to close...\r\n\
         :wait\r\n\
         tasklist /FI \"PID eq {wait_pid}\" /FI \"IMAGENAME eq {wait_image}\" 2>NUL | find /I \"{wait_image}\" >NUL\r\n\
         if %ERRORLEVEL% == 0 (\r\n\
             timeout /t 1 /nobreak >NUL\r\n\
             goto wait\r\n\
         )\r\n\
         echo   Copying files...\r\n\
         set HOLLOW_COPY_TRIES=0\r\n\
         :copy\r\n\
         xcopy /E /Y /Q \"{staging_str}\\*\" \"{app_dir}\\\" >NUL\r\n\
         if not errorlevel 1 goto copied\r\n\
         set /a HOLLOW_COPY_TRIES+=1\r\n\
         if %HOLLOW_COPY_TRIES% GEQ {COPY_TRIES} goto copyfailed\r\n\
         ping -n 3 127.0.0.1 >NUL\r\n\
         goto copy\r\n\
         :copyfailed\r\n\
         echo.\r\n\
         echo   {COPY_FAILED_1}\r\n\
         echo   {COPY_FAILED_2} \"{staging_str}\".\r\n\
         echo   {COPY_FAILED_3}\r\n\
         echo.\r\n\
         pause >NUL\r\n\
         echo   Copying files...\r\n\
         set HOLLOW_COPY_TRIES=0\r\n\
         goto copy\r\n\
         :copied\r\n\
         echo.\r\n\
         echo   Cleaning up...\r\n\
         rd /S /Q \"{staging_str}\" >NUL 2>&1\r\n\
         del /Q \"{zip_path_str}\" >NUL 2>&1\r\n\
         echo.\r\n\
         echo   Successfully updated to v{version}!\r\n\
         echo.\r\n\
         echo   Launching Hollow in:\r\n\
         echo.\r\n\
         echo     5...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     4...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     3...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     2...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo     1...\r\n\
         timeout /t 1 /nobreak >NUL\r\n\
         echo.\r\n\
         {relaunch}\r\n\
         exit\r\n"
    )
}

/// The `start` line that relaunches `exe_quoted` (already [`bat_quoted_path`]
/// output) with `args`, each through [`bat_quoted_arg`]; one it cannot carry
/// refuses the whole update.
#[cfg(any(target_os = "windows", test))]
fn bat_relaunch_line(exe_quoted: &str, args: &[String]) -> Result<String, String> {
    let mut line = format!("start \"\" \"{exe_quoted}\"");
    for arg in args {
        line.push(' ');
        line.push_str(&bat_quoted_arg(arg)?);
    }
    Ok(line)
}

/// One argument as cmd hands it to `start` and the app's CommandLineToArgvW
/// splits it back: inside the quotes cmd reads `& | < > ^ ( )` literally, `%` is
/// doubled against expansion, and a trailing backslash run is doubled so it
/// does not escape the closing quote. A quote or a control character would end
/// the argument or the line, so it refuses.
#[cfg(any(target_os = "windows", test))]
fn bat_quoted_arg(arg: &str) -> Result<String, String> {
    if arg.chars().any(|c| c == '"' || c.is_control()) {
        return Err(UNCARRIED_ARGUMENT.to_string());
    }
    let body = arg.replace('%', "%%");
    let trailing = body.len() - body.trim_end_matches('\\').len();
    Ok(format!("\"{body}{}\"", "\\".repeat(trailing)))
}

/// Builds the `.app`-swap shell script used on macOS.
///
/// The zip holds a single `*.app` bundle and `app_dir` is where the running one lives.
/// The script waits for this process to exit, replaces the bundle via `ditto` (which
/// preserves structure and signature), clears the quarantine attribute, then
/// relaunches with `open`, carrying `relaunch_args` and the data-root override.
#[cfg(target_os = "macos")]
fn write_macos_update_script(
    data: &std::path::Path,
    staging_str: &str,
    zip_path: &str,
    app_dir: &str,
    version: &str,
    relaunch_args: &[String],
) -> Result<String, String> {
    // Locate the single .app bundle inside the staging dir.
    let staging = PathBuf::from(staging_str);
    let mut bundle_name: Option<String> = None;
    for entry in fs::read_dir(&staging)
        .map_err(|e| format!("Failed to read staging dir: {e}"))?
    {
        let entry = entry.map_err(|e| format!("Failed to read staging entry: {e}"))?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.ends_with(".app") {
            bundle_name = Some(name);
            break;
        }
    }
    let bundle_name = bundle_name
        .ok_or("Update archive did not contain a .app bundle")?;

    let staged_app = staging.join(&bundle_name);
    let staged_app_str = staged_app
        .to_str()
        .ok_or("Staged app path is not valid UTF-8")?;
    // Install path: keep the bundle's own name, placed back in app_dir.
    let installed_app = format!("{app_dir}/{bundle_name}");
    // The swap deletes the old bundle whole; a data root inside it would go with it.
    // A portable copy keeps `hollow_data` beside the bundle, never in it.
    if let (Ok(d), Ok(a)) = (fs::canonicalize(data), fs::canonicalize(&installed_app))
        && d.starts_with(&a)
    {
        return Err(DATA_INSIDE_APP.to_string());
    }

    let sh_path = data.join("updates").join("update.sh");
    let log_path = data.join("updates").join("update.log");
    let log_str = log_path.to_str().ok_or("Log path is not valid UTF-8")?;

    let relaunch = macos_relaunch_line(
        &installed_app,
        relaunch_args,
        std::env::var("HOLLOW_DATA_DIR").ok().filter(|v| !v.is_empty()).as_deref(),
    );
    let log_q = sh_quote(log_str);
    let installed_q = sh_quote(&installed_app);
    let staged_q = sh_quote(staged_app_str);
    let staging_q = sh_quote(staging_str);
    let zip_q = sh_quote(zip_path);
    // `pgrep -f` matches the installed bundle's binaries, so it waits for *this* app.
    let pgrep_q = sh_quote(&format!("{installed_app}/Contents/MacOS/"));
    let version_q = sh_quote(&format!("Hollow update -> v{version}"));
    let sh_content = format!(
        "#!/bin/sh\n\
         set -e\n\
         LOG={log_q}\n\
         echo {version_q} > \"$LOG\"\n\
         echo \"Waiting for Hollow to close...\" >> \"$LOG\"\n\
         while pgrep -f {pgrep_q} >/dev/null 2>&1; do\n\
         \tsleep 1\n\
         done\n\
         sleep 1\n\
         echo \"Replacing bundle...\" >> \"$LOG\"\n\
         rm -rf {installed_q} >> \"$LOG\" 2>&1 || true\n\
         /usr/bin/ditto {staged_q} {installed_q} >> \"$LOG\" 2>&1\n\
         echo \"Clearing quarantine...\" >> \"$LOG\"\n\
         /usr/bin/xattr -dr com.apple.quarantine {installed_q} >> \"$LOG\" 2>&1 || true\n\
         echo \"Cleaning up...\" >> \"$LOG\"\n\
         rm -rf {staging_q} >> \"$LOG\" 2>&1 || true\n\
         rm -f {zip_q} >> \"$LOG\" 2>&1 || true\n\
         echo \"Relaunching...\" >> \"$LOG\"\n\
         {relaunch} >> \"$LOG\" 2>&1\n\
         exit 0\n"
    );

    fs::write(&sh_path, &sh_content)
        .map_err(|e| format!("Failed to write update script: {e}"))?;

    // Owner-only: Dart runs it as the same user via `/bin/sh`, so nothing
    // else needs to read or execute it (Sonar S2612).
    use std::os::unix::fs::PermissionsExt;
    let mut perms = fs::metadata(&sh_path)
        .map_err(|e| format!("Failed to stat update script: {e}"))?
        .permissions();
    perms.set_mode(0o700);
    fs::set_permissions(&sh_path, perms)
        .map_err(|e| format!("Failed to chmod update script: {e}"))?;

    sh_path
        .to_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "Script path is not valid UTF-8".to_string())
}

/// `open -n` of the installed bundle. LaunchServices starts the app with its
/// OWN environment and argv, so the original arguments ride `--args` and a
/// `HOLLOW_DATA_DIR` override rides `--env`: either one lost brings the app
/// back on a different data root.
#[cfg(any(target_os = "macos", test))]
fn macos_relaunch_line(installed_app: &str, args: &[String], data_dir_env: Option<&str>) -> String {
    let mut line = String::from("/usr/bin/open -n");
    if let Some(dir) = data_dir_env {
        line.push_str(" --env ");
        line.push_str(&sh_quote(&format!("HOLLOW_DATA_DIR={dir}")));
    }
    line.push(' ');
    line.push_str(&sh_quote(installed_app));
    if !args.is_empty() {
        line.push_str(" --args");
        for arg in args {
            line.push(' ');
            line.push_str(&sh_quote(arg));
        }
    }
    line
}

// ── Linux updates ───────────────────────────────────────────────────────────
//
// Two install kinds, one detection. The portable tarball owns its own directory, so
// an update is a rename swap by a detached script once this process is gone. A
// flatpak cannot touch its own deployment at all: the install runs on the HOST
// through `flatpak-spawn`, and so does the relaunch, because the sandbox's PID
// namespace dies with the app and would take any in-sandbox waiter with it.

/// `/.flatpak-info` exists only inside a Flatpak sandbox. This is the ONE
/// source of truth for the install kind; `apply_update`,
/// `launch_update_script` and `spawn_relaunch_waiter` all read it.
#[cfg(target_os = "linux")]
fn linux_install_kind_inner() -> &'static str {
    if Path::new("/.flatpak-info").exists() {
        "flatpak"
    } else {
        "tarball"
    }
}

/// A path as it may sit between the double quotes `update.bat` puts around it: `%`
/// doubled so cmd does not expand it, refused if it carries a quote or a control
/// character, which would end the argument or the line.
#[cfg(any(target_os = "windows", test))]
fn bat_quoted_path(path: &str) -> Result<String, String> {
    if path.chars().any(|c| c == '"' || c.is_control()) {
        return Err("An update path holds a character the update script cannot carry".to_string());
    }
    Ok(path.replace('%', "%%"))
}

/// POSIX single-quoting: wrap in `'…'`, write an embedded `'` as `'\''`. Every
/// path and argv element baked into a generated script goes through this, so a
/// space or a quote in a data directory cannot split a command.
#[cfg(any(not(windows), test))]
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// This process's argv (without argv[0]), single-quoted for a shell script. A relaunch
/// that drops `--portable` or `--data-dir` comes back up on a DIFFERENT profile than
/// the user was running, so every generated relaunch forwards the original arguments.
#[cfg(target_os = "linux")]
fn current_args_quoted() -> Result<String, String> {
    Ok(relaunch_args()?.iter().map(|a| sh_quote(a)).collect::<Vec<_>>().join(" "))
}

#[cfg(target_os = "linux")]
fn last_non_empty_line(text: &str) -> Option<String> {
    text.lines()
        .rev()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(|l| l.to_string())
}

/// Writes a generated script and makes it owner-only executable. Nothing else
/// needs to read or run it (Sonar S2612).
#[cfg(target_os = "linux")]
fn write_shell_script(path: &Path, body: &str) -> Result<String, String> {
    use std::os::unix::fs::PermissionsExt;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create updates dir: {e}"))?;
    }
    fs::write(path, body).map_err(|e| format!("Failed to write update script: {e}"))?;
    let mut perms = fs::metadata(path)
        .map_err(|e| format!("Failed to stat update script: {e}"))?
        .permissions();
    perms.set_mode(0o700);
    fs::set_permissions(path, perms)
        .map_err(|e| format!("Failed to chmod update script: {e}"))?;
    path.to_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "Script path is not valid UTF-8".to_string())
}

// ── Tarball install ─────────────────────────────────────────────────────────

/// Unpacks the release tarball and writes the swap script.
///
/// `tar`, never the `zip` crate: the Linux bundle carries executables and
/// symlinked library names, and the crate silently drops both.
///
/// `pid` is a parameter rather than `std::process::id()` so the mechanics can be
/// tested against a real child.
#[cfg(target_os = "linux")]
fn apply_update_tarball(
    data: &Path,
    archive_path: &str,
    app_dir: &str,
    rel: &ReleaseName,
    pid: u32,
) -> Result<String, String> {
    use std::os::unix::fs::PermissionsExt;

    let updates = data.join("updates");
    fs::create_dir_all(&updates).map_err(|e| format!("Failed to create updates dir: {e}"))?;
    let app_dir = app_dir.trim_end_matches('/');
    let places = tarball_places(&updates, Path::new(app_dir), &rel.tag)?;
    let staging = places.staging;
    if staging.exists() {
        fs::remove_dir_all(&staging).map_err(|e| format!("Failed to clean staging dir: {e}"))?;
    }
    fs::create_dir_all(&staging).map_err(|e| format!("Failed to create staging dir: {e}"))?;
    let staging_str = staging
        .to_str()
        .ok_or("Staging dir path is not valid UTF-8")?;

    crate::hollow_log!(
        "[updater] Extracting {} into {}",
        crate::log::redact_path(archive_path),
        crate::log::redact_path(staging_str)
    );
    let out = std::process::Command::new("tar")
        .args(["xzf", archive_path, "-C", staging_str])
        .output()
        .map_err(|e| {
            format!("The update archive could not be extracted because tar could not be started: {e}")
        })?;
    if !out.status.success() {
        let detail = last_non_empty_line(&String::from_utf8_lossy(&out.stderr))
            .unwrap_or_else(|| "no details were reported".to_string());
        return Err(format!(
            "The update archive could not be extracted: {detail}. Nothing was installed."
        ));
    }

    // The release tarball packs `bundle/hollow`, a repack from inside the folder has
    // `hollow` at the top, and anything else is not a Hollow build.
    let bundle = if staging.join("bundle").join("hollow").is_file() {
        staging.join("bundle")
    } else if staging.join("hollow").is_file() {
        staging.clone()
    } else {
        return Err(
            "The downloaded archive does not look like a Hollow Linux build. Nothing was installed."
                .to_string(),
        );
    };
    // A build that brought a data folder or a marker would take the person's place in
    // the swap (#155): it never installs one.
    for name in BUNDLE_PROFILE_NAMES {
        let path = bundle.join(name);
        if path.symlink_metadata().is_ok() {
            let gone = if path.is_dir() && !path.is_symlink() { fs::remove_dir_all(&path) } else { fs::remove_file(&path) };
            gone.map_err(|e| format!("The update could not be prepared: {e}. Nothing was installed."))?;
        }
    }

    let exe = bundle.join("hollow");
    let mode = fs::metadata(&exe)
        .map_err(|e| format!("The new Hollow binary could not be read: {e}"))?
        .permissions()
        .mode();
    if mode & 0o111 == 0 {
        return Err(
            "The new Hollow binary is not executable, so nothing was installed.".to_string(),
        );
    }

    let bundle_str = bundle.to_str().ok_or("Staged bundle path is not valid UTF-8")?;
    let log_str = places.log.to_str().ok_or("Log path is not valid UTF-8")?;
    let script_path = updates.join("update.sh");

    crate::hollow_log!(
        "[updater] Staged {} for {}, waiting on pid {pid} in {}",
        crate::log::redact_path(bundle_str),
        crate::log::redact_path(app_dir),
        crate::log::redact_path(&script_path)
    );
    let body = tarball_update_script(
        log_str,
        app_dir,
        bundle_str,
        staging_str,
        archive_path,
        &rel.display,
        pid,
        &current_args_quoted()?,
    );
    write_shell_script(&script_path, &body)
}

/// Where a tarball update stages the new build and keeps its log.
#[cfg(target_os = "linux")]
struct TarballPlaces {
    staging: PathBuf,
    log: PathBuf,
}

/// The swap moves the whole app folder aside, so nothing the script needs may sit in
/// it: a data root inside it (a portable copy's `hollow_data`) stages beside the app
/// folder instead. A data root elsewhere inside the app folder would be deleted with
/// the old build, so that update refuses.
#[cfg(target_os = "linux")]
fn tarball_places(updates: &Path, app: &Path, tag: &str) -> Result<TarballPlaces, String> {
    let real = |p: &Path| {
        fs::canonicalize(p).map_err(|e| format!("The update could not read {}: {e}. Nothing was installed.", p.display()))
    };
    let app_real = real(app)?;
    let updates_real = real(updates)?;
    if !updates_real.starts_with(&app_real) {
        return Ok(TarballPlaces { staging: updates.join(format!("staging-{tag}")), log: updates.join("update.log") });
    }
    let portable = app_real.join(BUNDLE_PROFILE_NAMES[0]);
    if !updates_real.starts_with(&portable) {
        return Err(DATA_INSIDE_APP.to_string());
    }
    let name = app
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("The app folder has no name the update can use. Nothing was installed.")?;
    Ok(TarballPlaces {
        staging: app.with_file_name(format!("{name}.update-{tag}")),
        log: app.with_file_name(format!("{name}.update.log")),
    })
}

/// Why an update refused: the data root sits inside the folder an update replaces.
#[cfg(any(target_os = "linux", target_os = "macos"))]
const DATA_INSIDE_APP: &str = "Hollow keeps its data inside the app folder that an update replaces, so nothing was installed. Move the data folder out of the app folder and try again.";

/// The swap script itself.
///
/// The person's data folder and markers in the app folder (`BUNDLE_PROFILE_NAMES`)
/// move from the old build to the new one before it starts and back on a rollback,
/// and a folder still holding one is never deleted: the script stops instead.
///
/// The relaunch uses `nohup`, not `setsid`: `setsid` FORKS when the calling shell is
/// already a process group leader, which this one is, so `$!` would be a helper that
/// exits immediately and the liveness check would roll back a good update. `nohup`
/// execs in place. The script already runs in its own session, so nothing can SIGHUP
/// the child when it exits.
#[cfg(target_os = "linux")]
#[allow(clippy::too_many_arguments)]
fn tarball_update_script(
    log: &str,
    app_dir: &str,
    bundle: &str,
    staging: &str,
    archive: &str,
    version: &str,
    pid: u32,
    args_quoted: &str,
) -> String {
    format!(
        "#!/bin/sh\n\
         LOG={log_q}\n\
         APP={app_q}\n\
         OLD=\"$APP.old\"\n\
         NEW={new_q}\n\
         STAGING={staging_q}\n\
         ARCHIVE={archive_q}\n\
         KEEP='{keep}'\n\
         note() {{ echo \"$1\" >> \"$LOG\" 2>/dev/null; }}\n\
         has() {{ [ -e \"$1\" ] || [ -L \"$1\" ]; }}\n\
         holds_data() {{ for k in $KEEP; do if has \"$1/$k\"; then return 0; fi; done; return 1; }}\n\
         restore() {{\n\
         for k in $KEEP; do\n\
         if has \"$APP/$k\" && ! has \"$OLD/$k\"; then mv \"$APP/$k\" \"$OLD/$k\" >> \"$LOG\" 2>&1; fi\n\
         done\n\
         if holds_data \"$APP\"; then\n\
         note \"could not move the data back, so the new build stays in place with it and the previous one stays in $OLD\"\n\
         return 1\n\
         fi\n\
         rm -rf \"$APP\" >> \"$LOG\" 2>&1\n\
         mv \"$OLD\" \"$APP\" >> \"$LOG\" 2>&1\n\
         }}\n\
         echo \"Hollow update to v{version}\" > \"$LOG\"\n\
         note \"waiting for pid {pid} to exit\"\n\
         while kill -0 {pid} 2>/dev/null; do sleep 0.3; done\n\
         sleep 0.5\n\
         if has \"$OLD\"; then\n\
         if holds_data \"$OLD\"; then\n\
         note \"an earlier update left data in $OLD, nothing was changed\"\n\
         exit 1\n\
         fi\n\
         rm -rf \"$OLD\" >> \"$LOG\" 2>&1\n\
         fi\n\
         if holds_data \"$NEW\"; then\n\
         note \"the new build carries a data folder or marker, nothing was changed\"\n\
         exit 1\n\
         fi\n\
         note \"swapping the bundle\"\n\
         if ! mv \"$APP\" \"$OLD\" >> \"$LOG\" 2>&1; then\n\
         note \"could not move the current build aside, nothing was changed\"\n\
         exit 1\n\
         fi\n\
         if ! mv \"$NEW\" \"$APP\" >> \"$LOG\" 2>&1; then\n\
         note \"could not move the new build into place, restoring the previous version\"\n\
         mv \"$OLD\" \"$APP\" >> \"$LOG\" 2>&1\n\
         exit 1\n\
         fi\n\
         for k in $KEEP; do\n\
         if has \"$OLD/$k\" && ! mv \"$OLD/$k\" \"$APP/$k\" >> \"$LOG\" 2>&1; then\n\
         note \"could not move $k into the new build, restoring the previous version\"\n\
         if restore; then nohup \"$APP/hollow\" {args_quoted} >/dev/null 2>&1 & fi\n\
         exit 1\n\
         fi\n\
         done\n\
         note \"starting the new build\"\n\
         nohup \"$APP/hollow\" {args_quoted} >/dev/null 2>&1 &\n\
         NEWPID=$!\n\
         sleep 8\n\
         if ! kill -0 \"$NEWPID\" 2>/dev/null; then\n\
         note \"new build exited early, restoring previous version\"\n\
         if restore; then nohup \"$APP/hollow\" {args_quoted} >/dev/null 2>&1 & fi\n\
         exit 1\n\
         fi\n\
         if holds_data \"$OLD\"; then\n\
         note \"kept $OLD, it still holds a data folder or marker\"\n\
         else\n\
         rm -rf \"$OLD\" >> \"$LOG\" 2>&1\n\
         fi\n\
         rm -rf \"$STAGING\" >> \"$LOG\" 2>&1\n\
         rm -f \"$ARCHIVE\" >> \"$LOG\" 2>&1\n\
         note \"updated to v{version}\"\n\
         exit 0\n",
        log_q = sh_quote(log),
        app_q = sh_quote(app_dir),
        new_q = sh_quote(bundle),
        staging_q = sh_quote(staging),
        archive_q = sh_quote(archive),
        keep = BUNDLE_PROFILE_NAMES.join(" "),
    )
}

// ── Flatpak install ─────────────────────────────────────────────────────────

#[cfg(target_os = "linux")]
const FLATPAK_APP_ID: &str = "com.anonlisten.Hollow";

#[cfg(target_os = "linux")]
const FLATPAK_TERMINAL_FALLBACK: &str =
    "You can update from a terminal with: flatpak update com.anonlisten.Hollow";

#[cfg(target_os = "linux")]
fn flatpak_host_denied_message() -> String {
    format!(
        "Hollow is not allowed to talk to the host, so it could not install the update itself. \
         {FLATPAK_TERMINAL_FALLBACK}"
    )
}

/// The two ways `flatpak-spawn` reports that the sandbox has no
/// `org.freedesktop.Flatpak` access. Both mean the same thing to the user.
#[cfg(target_os = "linux")]
fn looks_like_host_denied(text: &str) -> bool {
    text.contains("Portal call failed")
        || text.contains("only works when the Flatpak is allowed to talk to org.freedesktop.Flatpak")
}

#[cfg(target_os = "linux")]
#[derive(Debug, Clone, PartialEq, Eq)]
struct FlatpakInfo {
    app_path: String,
    instance_id: String,
}

#[cfg(target_os = "linux")]
impl FlatpakInfo {
    /// A system install deploys under `/var/lib/flatpak`, anything else is per-user.
    /// Installing into the wrong scope fails, so the scope is read off the running
    /// deployment rather than guessed.
    fn scope(&self) -> &'static str {
        if self.app_path.starts_with("/var/lib/flatpak") {
            "--system"
        } else {
            "--user"
        }
    }
}

/// Pure parser for `/.flatpak-info`. Only the `[Instance]` section counts: `app-path`
/// decides the install scope, and `instance-id` is what `flatpak ps` prints, which is
/// how the host-side relaunch knows the old instance is gone.
#[cfg(target_os = "linux")]
fn parse_flatpak_info(text: &str) -> Result<FlatpakInfo, String> {
    let mut section = String::new();
    let mut app_path: Option<String> = None;
    let mut instance_id: Option<String> = None;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].to_string();
            continue;
        }
        if section != "Instance" {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "app-path" => app_path = Some(value.trim().to_string()),
            "instance-id" => instance_id = Some(value.trim().to_string()),
            _ => {}
        }
    }
    match (app_path, instance_id) {
        (Some(a), Some(i)) if !a.is_empty() && !i.is_empty() => Ok(FlatpakInfo {
            app_path: a,
            instance_id: i,
        }),
        _ => Err("Hollow could not read its Flatpak instance details.".to_string()),
    }
}

/// Installs the downloaded `.flatpak` bundle ON THE HOST and returns the path
/// of the relaunch script.
///
/// The running deployment stays where it is while this runs, which is why the app can
/// keep working and restart into the new build. The install is synchronous and can
/// take a minute.
#[cfg(target_os = "linux")]
fn apply_update_flatpak(
    data: &Path,
    bundle_path: &str,
    version: &str,
) -> Result<String, String> {
    let info_text = fs::read_to_string("/.flatpak-info")
        .map_err(|e| {
            crate::hollow_log!("[updater] Could not read /.flatpak-info: {e}");
            format!("Hollow could not read its Flatpak instance details. {FLATPAK_TERMINAL_FALLBACK}")
        })?;
    let info = parse_flatpak_info(&info_text)
        .map_err(|e| format!("{e} {FLATPAK_TERMINAL_FALLBACK}"))?;
    let scope = info.scope();

    crate::hollow_log!("[updater] Installing {} on the host with {scope} (v{version})", crate::log::redact_path(bundle_path));
    let spawned = std::process::Command::new("flatpak-spawn")
        .args([
            "--host",
            "flatpak",
            "install",
            "-y",
            "--noninteractive",
            scope,
            bundle_path,
        ])
        .output();
    let out = match spawned {
        Ok(out) => out,
        Err(e) => {
            crate::hollow_log!("[updater] flatpak-spawn could not be started: {e}");
            return Err(flatpak_host_denied_message());
        }
    };
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    crate::hollow_log!(
        "[updater] flatpak install exit {:?}; stdout: {stdout}; stderr: {stderr}",
        out.status.code()
    );
    // Installing a bundle whose commit is ALREADY deployed fails with "already
    // installed", which is the state we wanted: a retry after an install that worked
    // but whose relaunch did not must still relaunch.
    let already_there =
        stderr.contains("already installed") || stdout.contains("already installed");
    if !out.status.success() && !already_there {
        if looks_like_host_denied(&stderr) || looks_like_host_denied(&stdout) {
            return Err(flatpak_host_denied_message());
        }
        let detail = last_non_empty_line(&stderr)
            .or_else(|| last_non_empty_line(&stdout))
            .unwrap_or_else(|| "no details were reported".to_string());
        return Err(format!(
            "Hollow could not install the update through Flatpak: {detail}. \
             {FLATPAK_TERMINAL_FALLBACK}"
        ));
    }

    // The script deletes the downloaded bundle: this process cannot, it is about to exit.
    let script_path = data.join("updates").join("relaunch.sh");
    let body = format!(
        "#!/bin/sh\n\
         rm -f {bundle}\n\
         {recipe}",
        bundle = sh_quote(bundle_path),
        recipe = flatpak_relaunch_recipe(&info.instance_id, &current_args_quoted()?),
    );
    write_shell_script(&script_path, &body)
}

/// The ONE host-side relaunch recipe, shared by the post-install relaunch and
/// by the self-restart waiter (profile switch, relay apply, device link,
/// revocation self-nuke).
///
/// It waits for our instance id to leave `flatpak ps` rather than for a pid, since a
/// sandbox pid means nothing on the host. The session bus address is restored because
/// a command started through `flatpak-spawn --host` inherits the sandbox environment
/// and `flatpak run` needs a bus to reach the session; the export is conditional so a
/// machine without that socket still gets a launch attempt.
#[cfg(target_os = "linux")]
fn flatpak_relaunch_recipe(instance_id: &str, args_quoted: &str) -> String {
    format!(
        "while flatpak ps --columns=instance 2>/dev/null | grep -qx {id}; do sleep 0.3; done\n\
         sleep 0.5\n\
         BUS=\"${{XDG_RUNTIME_DIR:-/run/user/$(id -u)}}/bus\"\n\
         if [ -S \"$BUS\" ]; then\n\
         DBUS_SESSION_BUS_ADDRESS=\"unix:path=$BUS\"\n\
         export DBUS_SESSION_BUS_ADDRESS\n\
         fi\n\
         exec flatpak run {FLATPAK_APP_ID} {args_quoted}\n",
        id = sh_quote(instance_id),
    )
}

// ── Starting the generated script ───────────────────────────────────────────

/// Starts the script [`apply_update`] returned so that it OUTLIVES this
/// process. Linux only; Dart calls this and then exits.
#[frb]
pub fn launch_update_script(script_path: String) -> Result<(), String> {
    launch_update_script_impl(&script_path)
}

#[cfg(target_os = "linux")]
fn launch_update_script_impl(script_path: &str) -> Result<(), String> {
    crate::hollow_log!("[updater] Starting update script {}", crate::log::redact_path(script_path));
    match linux_install_kind_inner() {
        "flatpak" => launch_host_shell_script(script_path),
        _ => launch_detached_shell_script(script_path),
    }
}

#[cfg(not(target_os = "linux"))]
fn launch_update_script_impl(_script_path: &str) -> Result<(), String> {
    Err("Not used on this platform".to_string())
}

/// Tarball: a detached `/bin/sh` in its own session, so the script survives
/// this process and never inherits a controlling terminal.
#[cfg(target_os = "linux")]
fn launch_detached_shell_script(script_path: &str) -> Result<(), String> {
    use std::process::Stdio;
    let spawned = std::process::Command::new("setsid")
        .arg("/bin/sh")
        .arg(script_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    match spawned {
        Ok(_) => Ok(()),
        Err(e) => {
            // util-linux is everywhere, but a bare container might not have it.
            crate::hollow_log!("[updater] setsid unavailable ({e}), starting the script directly");
            std::process::Command::new("/bin/sh")
                .arg(script_path)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map(|_| ())
                .map_err(|e| format!("The update could not be started: {e}"))
        }
    }
}

/// Flatpak: the script has to run on the HOST, because everything inside the sandbox
/// dies with the app. Waiting for `flatpak-spawn` to return is what guarantees the
/// host has forked the script before the caller exits.
#[cfg(target_os = "linux")]
fn launch_host_shell_script(script_path: &str) -> Result<(), String> {
    let command = format!("setsid nohup sh {} >/dev/null 2>&1 &", sh_quote(script_path));
    let spawned = std::process::Command::new("flatpak-spawn")
        .args(["--host", "sh", "-c", &command])
        .output();
    let out = match spawned {
        Ok(out) => out,
        Err(e) => {
            crate::hollow_log!("[updater] flatpak-spawn could not be started: {e}");
            return Err(flatpak_host_denied_message());
        }
    };
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        crate::hollow_log!(
            "[updater] Host script launch failed ({:?}): {stderr}",
            out.status.code()
        );
        if looks_like_host_denied(&stderr) {
            return Err(flatpak_host_denied_message());
        }
        let detail =
            last_non_empty_line(&stderr).unwrap_or_else(|| "no details were reported".to_string());
        return Err(format!(
            "Hollow could not start its relaunch helper on the host: {detail}."
        ));
    }
    Ok(())
}

/// Extracts an update zip into `staging_dir`, flattening a single common
/// top-level directory (e.g. "Release/") when present.
///
/// Entry names are normalized `\` to `/` first: Compress-Archive writes
/// backslash-separated names and marks directory entries with a TRAILING backslash,
/// and treating those as files made `File::create` fail on every empty dir.
#[allow(dead_code)] // only reachable on Windows outside of tests
pub(crate) fn extract_zip_to(zip_path: &str, staging_dir: &std::path::Path) -> Result<(), String> {
    let zip_file = fs::File::open(zip_path)
        .map_err(|e| format!("Failed to open zip: {e}"))?;
    let mut archive = zip::ZipArchive::new(zip_file)
        .map_err(|e| format!("Failed to read zip archive: {e}"))?;

    let prefix = detect_common_prefix(&mut archive);

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read zip entry {i}: {e}"))?;

        let raw_name = entry
            .name()
            .map_err(|e| format!("Failed to read zip entry {i} name: {e}"))?
            .replace('\\', "/");
        let name = if let Some(ref p) = prefix {
            raw_name.strip_prefix(p.as_str()).unwrap_or(&raw_name).to_string()
        } else {
            raw_name
        };

        if name.is_empty() {
            continue;
        }
        // An absolute, drive or `..` name would make the join below leave the staging dir.
        let inside = std::path::Path::new(&name)
            .components()
            .all(|c| matches!(c, std::path::Component::Normal(_) | std::path::Component::CurDir));
        if entry.enclosed_name().is_none() || !inside {
            return Err(format!("Unsafe zip entry path: {name}"));
        }
        if never_installed(&name) {
            crate::hollow_log!("[updater] Skipped a data entry the update must not install: {}", crate::log::redact_path(&name));
            continue;
        }

        if name.ends_with('/') {
            let dir_path = staging_dir.join(&name);
            fs::create_dir_all(&dir_path)
                .map_err(|e| format!("Failed to create dir {name}: {e}"))?;
        } else {
            let file_path = staging_dir.join(&name);
            if let Some(parent) = file_path.parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| format!("Failed to create parent for {name}: {e}"))?;
            }
            let mut outfile = fs::File::create(&file_path)
                .map_err(|e| format!("Failed to create file {name}: {e}"))?;
            std::io::copy(&mut entry, &mut outfile)
                .map_err(|e| format!("Failed to extract {name}: {e}"))?;
        }
    }
    Ok(())
}

/// What lives in the app folder but belongs to the person: the portable data folder
/// and the markers that select it. An update neither brings nor deletes them.
const BUNDLE_PROFILE_NAMES: [&str; 4] = ["hollow_data", "portable", "portable.txt", "portable.txt.txt"];

/// A portable data folder or a portable marker in an update archive: installing it
/// would switch the app to another data root on its next start, over a database
/// the archive brought (#155; 0.12.1 to 0.14.1 shipped one).
fn never_installed(name: &str) -> bool {
    let mut parts = name.split('/').filter(|p| !p.is_empty() && *p != ".");
    let Some(first) = parts.next() else { return false };
    let first = first.to_ascii_lowercase();
    if first == BUNDLE_PROFILE_NAMES[0] {
        return true;
    }
    parts.next().is_none() && BUNDLE_PROFILE_NAMES[1..].contains(&first.as_str())
}

fn detect_common_prefix(archive: &mut zip::ZipArchive<fs::File>) -> Option<String> {
    let mut common: Option<String> = None;
    for i in 0..archive.len() {
        let name = archive.by_index_raw(i).ok()?.name().ok()?.replace('\\', "/");
        let first_part = match name.find('/') {
            Some(idx) => &name[..=idx],
            None => return None,
        };
        match &common {
            None => common = Some(first_part.to_string()),
            Some(c) if c != first_part => return None,
            _ => {}
        }
    }
    common
}

#[cfg(test)]
mod extract_zip_tests {
    use std::io::Write;

    fn zip_of(path: &std::path::Path, entries: &[(&str, &[u8])]) {
        let mut w = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
        for (name, data) in entries {
            if name.ends_with('/') {
                w.add_directory(name.trim_end_matches('/'), zip::write::SimpleFileOptions::default()).unwrap();
            } else {
                w.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
                w.write_all(data).unwrap();
            }
        }
        w.finish().unwrap();
    }

    /// #155: 0.12.1 to 0.14.1 shipped `hollow_data/messages.db`, and installing it
    /// switched every updated copy to portable mode over a stranger's database.
    #[test]
    fn an_update_never_carries_a_data_folder() {
        for prefix in ["", "Release/"] {
            let tmp = crate::test_tmp::tempdir().expect("tmp");
            let zip = tmp.path().join("u.zip");
            let names = [
                "hollow.exe", "data/app.so", "hollow_data/", "hollow_data/messages.db", "hollow_data/hollow.lock",
                "Hollow_Data/identity.key", "portable.txt", "portable", "portable.txt.txt", "PORTABLE.TXT",
                "data/flutter_assets/portable.txt",
            ];
            let entries: Vec<(String, &[u8])> = names.iter().map(|n| (format!("{prefix}{n}"), b"x".as_slice())).collect();
            let refs: Vec<(&str, &[u8])> = entries.iter().map(|(n, d)| (n.as_str(), *d)).collect();
            zip_of(&zip, &refs);
            let staging = tmp.path().join("staging");
            std::fs::create_dir_all(&staging).unwrap();
            super::extract_zip_to(zip.to_str().unwrap(), &staging).expect("a legitimate update still installs");
            assert!(staging.join("hollow.exe").exists() && staging.join("data/app.so").exists(), "{prefix:?}");
            assert!(staging.join("data/flutter_assets/portable.txt").exists(), "only a marker beside the exe counts");
            let top: Vec<String> = std::fs::read_dir(&staging)
                .unwrap()
                .map(|e| e.unwrap().file_name().to_string_lossy().to_lowercase())
                .collect();
            for gone in ["hollow_data", "portable.txt", "portable", "portable.txt.txt"] {
                assert!(!top.contains(&gone.to_string()), "{prefix:?} installed {gone}: {top:?}");
            }
        }
    }

    /// Builds a zip the way Compress-Archive does — backslash separators,
    /// zero-byte directory entries with a trailing backslash — and asserts
    /// extraction survives it (issue #52 regression).
    #[test]
    fn extracts_compress_archive_style_backslash_entries() {
        let tmp = std::env::temp_dir().join(format!(
            "hollow_updater_zip_test_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("create tmp dir");

        let zip_path = tmp.join("update.zip");
        {
            let file = std::fs::File::create(&zip_path).expect("create zip");
            let mut writer = zip::ZipWriter::new(file);
            let opts = zip::write::SimpleFileOptions::default();
            // Empty-directory entry exactly as Compress-Archive emits it.
            writer
                .start_file("data\\flutter_assets\\packages\\", opts)
                .expect("dir entry");
            writer
                .start_file("hollow.exe", opts)
                .expect("exe entry");
            writer.write_all(b"exe-bytes").expect("write exe");
            writer
                .start_file("data\\flutter_assets\\kernel_blob.bin", opts)
                .expect("nested entry");
            writer.write_all(b"blob").expect("write blob");
            writer.finish().expect("finish zip");
        }

        let staging = tmp.join("staging");
        std::fs::create_dir_all(&staging).expect("create staging");
        super::extract_zip_to(zip_path.to_str().unwrap(), &staging)
            .expect("extraction must tolerate backslash entries");

        assert!(staging.join("hollow.exe").is_file());
        assert!(staging
            .join("data")
            .join("flutter_assets")
            .join("kernel_blob.bin")
            .is_file());
        assert!(staging
            .join("data")
            .join("flutter_assets")
            .join("packages")
            .is_dir());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// Minimal single-entry STORED zip with an unsanitized entry name. ZipWriter refuses
    /// to write traversal names, so the hostile fixture is built by hand; the CRC stays
    /// 0 because rejection happens on the NAME before any data is read.
    fn raw_zip_single_entry(name: &[u8], data: &[u8]) -> Vec<u8> {
        let name_len = (name.len() as u16).to_le_bytes();
        let size = (data.len() as u32).to_le_bytes();
        let mut out = Vec::new();
        // Local file header.
        out.extend_from_slice(b"PK\x03\x04");
        out.extend_from_slice(&[20, 0, 0, 0, 0, 0, 0, 0, 0, 0]); // ver/flags/method/time/date
        out.extend_from_slice(&[0, 0, 0, 0]); // crc32
        out.extend_from_slice(&size); // compressed
        out.extend_from_slice(&size); // uncompressed
        out.extend_from_slice(&name_len);
        out.extend_from_slice(&[0, 0]); // extra len
        out.extend_from_slice(name);
        out.extend_from_slice(data);
        // Central directory.
        let cd_offset = (out.len() as u32).to_le_bytes();
        let cd_start = out.len();
        out.extend_from_slice(b"PK\x01\x02");
        out.extend_from_slice(&[20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0]); // made-by/needed/flags/method/time/date
        out.extend_from_slice(&[0, 0, 0, 0]); // crc32
        out.extend_from_slice(&size);
        out.extend_from_slice(&size);
        out.extend_from_slice(&name_len);
        out.extend_from_slice(&[0, 0]); // extra len
        out.extend_from_slice(&[0, 0]); // comment len
        out.extend_from_slice(&[0, 0]); // disk start
        out.extend_from_slice(&[0, 0]); // internal attrs
        out.extend_from_slice(&[0, 0, 0, 0]); // external attrs
        out.extend_from_slice(&[0, 0, 0, 0]); // local header offset
        out.extend_from_slice(name);
        let cd_size = ((out.len() - cd_start) as u32).to_le_bytes();
        // End of central directory.
        out.extend_from_slice(b"PK\x05\x06");
        out.extend_from_slice(&[0, 0, 0, 0, 1, 0, 1, 0]); // disks, entry counts
        out.extend_from_slice(&cd_size);
        out.extend_from_slice(&cd_offset);
        out.extend_from_slice(&[0, 0]); // comment len
        out
    }

    /// A hostile entry trying to escape the staging dir must abort extraction.
    #[test]
    fn rejects_path_traversal_entries() {
        let tmp = std::env::temp_dir().join(format!(
            "hollow_updater_slip_test_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("create tmp dir");

        let zip_path = tmp.join("evil.zip");
        // Empty data so the stored CRC of 0 is valid if extraction proceeds.
        std::fs::write(&zip_path, raw_zip_single_entry(b"..\\outside.txt", b""))
            .expect("write raw zip");

        let staging = tmp.join("staging");
        std::fs::create_dir_all(&staging).expect("create staging");
        // The zip crate sanitizes traversal names on read and our own guard rejects any
        // ".." that slips through, so the entry must NOT materialize outside staging.
        let _ = super::extract_zip_to(zip_path.to_str().unwrap(), &staging);
        assert!(
            !tmp.join("outside.txt").exists(),
            "traversal entry escaped the staging dir"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// C-DIST-06: a manifest version that is not digits and dots stages nothing.
    #[test]
    fn a_malformed_version_stages_nothing() {
        let tmp = std::env::temp_dir().join(format!("hollow_updater_ver_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("create tmp dir");
        let zip_path = tmp.join("update.zip");
        {
            let file = std::fs::File::create(&zip_path).expect("create zip");
            let mut writer = zip::ZipWriter::new(file);
            writer.start_file("hollow.exe", zip::write::SimpleFileOptions::default()).expect("entry");
            writer.write_all(b"exe").expect("write");
            writer.finish().expect("finish");
        }
        let app = tmp.join("app");
        std::fs::create_dir_all(&app).expect("app dir");
        let r = super::apply_update_at(&tmp, zip_path.to_str().unwrap(), app.to_str().unwrap(), "0.12.0 & calc", 0, &[]);
        let staged = tmp.join("updates").exists();
        let _ = std::fs::remove_dir_all(&tmp);
        assert!(r.is_err(), "a malformed version was applied: {r:?}");
        assert!(!staged, "a malformed version staged files");
    }

    #[test]
    fn release_versions_are_three_decimal_parts() {
        for ok in ["0.12.0", "0.11.1", "10.0.0", "1.22.333"] {
            assert!(super::is_release_version(ok), "{ok} refused");
        }
        for bad in [
            "", "0.12", "0.12.0.1", "0.12.0-beta", "v0.12.0", "0.12.x", "0..1", ".1.2", "0.12.0 ",
            "0.12.0\" & calc & \"", "..\\..\\x", "0.1.2/../3", "0.1.123456", "０.1.2",
        ] {
            assert!(!super::is_release_version(bad), "{bad:?} accepted");
        }
    }

    /// The signed manifest is refused whole when any version in it is malformed,
    /// before Dart can offer it for download.
    #[test]
    fn a_manifest_with_a_malformed_version_is_refused() {
        let shipped = include_str!("../../../../legal/manifest.json");
        assert!(super::manifest_versions_well_formed(shipped.as_bytes()).is_ok());
        for bad in [
            r#"{"latest":"0.12.0 & calc","versions":[{"version":"0.12.0"}]}"#,
            r#"{"latest":"0.12.0","versions":[{"version":"0.12.0"},{"version":"..\\..\\evil"}]}"#,
            r#"{"latest":"0.12.0","versions":[{"notes":"no version"}]}"#,
            r#"{"versions":[{"version":"0.12.0"}]}"#,
            r#"{"latest":"0.12.0"}"#,
            "not json",
        ] {
            assert!(super::manifest_versions_well_formed(bad.as_bytes()).is_err(), "{bad} accepted");
        }
    }

    #[test]
    fn bat_paths_keep_percent_literal_and_refuse_quotes() {
        assert_eq!(
            super::bat_quoted_path(r"C:\Users\a%PATH%b\Hollow").unwrap(),
            r"C:\Users\a%%PATH%%b\Hollow"
        );
        for bad in ["C:\\a\"&calc&\"", "C:\\a\r\ncalc", "C:\\a\tb"] {
            assert!(super::bat_quoted_path(bad).is_err(), "{bad:?} accepted");
        }
    }

    /// An absolute entry name aborts extraction: `Path::join` would drop the staging
    /// dir and write wherever the name points.
    #[test]
    fn rejects_absolute_entries() {
        let tmp = std::env::temp_dir().join(format!("hollow_updater_abs_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("create tmp dir");
        let outside = tmp.join("outside.txt");
        let zip_path = tmp.join("evil.zip");
        {
            let mut writer = zip::ZipWriter::new(std::fs::File::create(&zip_path).expect("create zip"));
            let opts = zip::write::SimpleFileOptions::default();
            writer.start_file("hollow.exe", opts).expect("exe entry");
            writer.write_all(b"exe-bytes").expect("write exe");
            writer.start_file(outside.to_str().unwrap(), opts).expect("absolute entry");
            writer.write_all(b"planted").expect("write planted");
            writer.finish().expect("finish zip");
        }
        let staging = tmp.join("staging");
        std::fs::create_dir_all(&staging).expect("create staging");
        let result = super::extract_zip_to(zip_path.to_str().unwrap(), &staging);
        let escaped = outside.exists();
        let _ = std::fs::remove_dir_all(&tmp);
        assert!(!escaped, "an absolute entry escaped the staging dir");
        assert!(result.is_err(), "an absolute entry was extracted somewhere");
    }
}

// ── Self-restart waiter (issue #47 profile switch, relay apply, device link,
// revocation self-nuke) ─────────────────────────────────────────────────────
//
// Dart cannot restart the app by spawning a fresh copy before exiting: on Windows the
// runner's SendAppLinkToInstance() runs pre-Flutter in the child, finds the still-alive
// old window, forwards and exits. So a detached waiter idles until THIS process is
// gone, then starts the exe. It cannot be spawned from Dart either, whose detached
// mode kills powershell instantly and wedges a detached cmd batch; Rust can pass
// CREATE_NO_WINDOW, so the spawn lives here.

/// Spawn a detached, windowless waiter that idles until this process exits,
/// then relaunches the app. Call right before a self-restart `exit(0)`.
#[frb]
pub fn spawn_relaunch_waiter() -> Result<(), String> {
    // Inside a flatpak the sandbox PID namespace dies with the app, so the wait and the
    // relaunch both belong on the host, through the update path's recipe.
    #[cfg(target_os = "linux")]
    {
        if linux_install_kind_inner() == "flatpak" {
            return spawn_flatpak_relaunch_waiter();
        }
    }
    spawn_waiter(std::process::id(), &self_restart_snippet()?)
}

/// What the waiter runs for THIS process: its exe, its own arguments, and the
/// data-root override where the relaunch would not inherit it.
fn self_restart_snippet() -> Result<String, String> {
    self_restart_snippet_for(std::env::args_os().skip(1))
}

fn self_restart_snippet_for(args: impl IntoIterator<Item = std::ffi::OsString>) -> Result<String, String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("current_exe failed: {e}"))?;
    let exe = exe
        .to_str()
        .ok_or("Executable path is not valid UTF-8")?
        .to_string();
    let data_dir_env = std::env::var("HOLLOW_DATA_DIR").ok().filter(|v| !v.is_empty());
    Ok(relaunch_snippet(&exe, &carried_args(args)?, data_dir_env.as_deref()))
}

/// The platform snippet the waiter runs once the watched pid is gone.
///
/// The original argv is forwarded: a relaunch that drops `--portable` or any other
/// data-root flag comes back up on a DIFFERENT profile than the user was running.
/// Windows and Linux children inherit `HOLLOW_DATA_DIR`; `open` does not.
fn relaunch_snippet(exe: &str, args: &[String], data_dir_env: Option<&str>) -> String {
    #[cfg(windows)]
    {
        let _ = data_dir_env;
        powershell_relaunch(exe, args)
    }
    #[cfg(target_os = "macos")]
    {
        // Relaunch the bundle via LaunchServices when running from a .app.
        match exe.find(".app/") {
            Some(idx) => macos_relaunch_line(&exe[..idx + 4], args, data_dir_env),
            None => exec_line(exe, args),
        }
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        let _ = data_dir_env;
        exec_line(exe, args)
    }
}

#[cfg(not(windows))]
fn exec_line(exe: &str, args: &[String]) -> String {
    let mut line = format!("exec {}", sh_quote(exe));
    for arg in args {
        line.push(' ');
        line.push_str(&sh_quote(arg));
    }
    line
}

/// `Start-Process` with ONE argument string: given a list, Windows PowerShell joins
/// it with spaces and quotes nothing, so an argument holding a space came back as two.
#[cfg(any(windows, test))]
fn powershell_relaunch(exe: &str, args: &[String]) -> String {
    let mut line = format!("Start-Process -FilePath {}", ps_quote(exe));
    if !args.is_empty() {
        let command_line = args.iter().map(|a| argv_quote(a)).collect::<Vec<_>>().join(" ");
        line.push_str(" -ArgumentList ");
        line.push_str(&ps_quote(&command_line));
    }
    line
}

/// A PowerShell single-quoted literal. PowerShell also ends such a literal at the
/// typographic single quotes, so those are doubled as well.
#[cfg(any(windows, test))]
fn ps_quote(s: &str) -> String {
    let mut out = String::from("'");
    for c in s.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
        out.push(c);
    }
    out.push('\'');
    out
}

/// One argument quoted so CommandLineToArgvW returns it unchanged: backslashes are
/// literal except before a quote, where they and the quote are escaped.
#[cfg(any(windows, test))]
fn argv_quote(arg: &str) -> String {
    let mut out = String::from("\"");
    let mut backslashes = 0usize;
    for c in arg.chars() {
        match c {
            '\\' => backslashes += 1,
            '"' => {
                out.push_str(&"\\".repeat(backslashes * 2 + 1));
                out.push('"');
                backslashes = 0;
            }
            _ => {
                out.push_str(&"\\".repeat(backslashes));
                out.push(c);
                backslashes = 0;
            }
        }
    }
    out.push_str(&"\\".repeat(backslashes * 2));
    out.push('"');
    out
}

#[cfg(windows)]
fn spawn_waiter(pid: u32, launch: &str) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    use std::process::Stdio;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    std::process::Command::new("powershell")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &format!(
                "while (Get-Process -Id {pid} -ErrorAction SilentlyContinue) \
                 {{ Start-Sleep -Milliseconds 250 }}; {launch}"
            ),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ()) // child handle drop does NOT kill the process
        .map_err(|e| format!("Failed to spawn relaunch waiter: {e}"))
}

/// Self-restart inside a flatpak: write the shared relaunch recipe and hand it
/// to the host, exactly like the post-install relaunch does.
#[cfg(target_os = "linux")]
fn spawn_flatpak_relaunch_waiter() -> Result<(), String> {
    let info_text = fs::read_to_string("/.flatpak-info").map_err(|e| {
        crate::hollow_log!("[updater] Could not read /.flatpak-info: {e}");
        "Hollow could not read its Flatpak instance details, so it could not restart itself. Please start it again yourself.".to_string()
    })?;
    let info = parse_flatpak_info(&info_text)
        .map_err(|e| format!("{e} Hollow could not restart itself. Please start it again yourself."))?;
    let data = data_dir()?;
    let script_path = data.join("updates").join("relaunch.sh");
    let body = format!(
        "#!/bin/sh\n{}",
        flatpak_relaunch_recipe(&info.instance_id, &current_args_quoted()?)
    );
    let path = write_shell_script(&script_path, &body)?;
    crate::hollow_log!("[updater] Flatpak self-restart through the host script {}", crate::log::redact_path(&path));
    launch_host_shell_script(&path)
}

#[cfg(not(windows))]
fn spawn_waiter(pid: u32, launch: &str) -> Result<(), String> {
    use std::process::Stdio;
    std::process::Command::new("/bin/sh")
        .args([
            "-c",
            &format!("while kill -0 {pid} 2>/dev/null; do sleep 0.3; done; {launch}"),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Failed to spawn relaunch waiter: {e}"))
}

#[cfg(all(test, windows))]
mod relaunch_waiter_tests {
    /// End-to-end mechanics: the waiter watches a short-lived pid, outlives it and runs
    /// the launch snippet. This MUST stay an empirical test of the CREATE_NO_WINDOW
    /// spawn, because the Dart-side detached spawn silently killed powershell.
    #[test]
    fn waiter_fires_after_watched_pid_exits() {
        use std::os::windows::process::CommandExt;
        let marker = std::env::temp_dir()
            .join(format!("hollow_waiter_test_{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&marker);

        // A child that exits immediately = the "old Hollow" to outwait.
        let mut child = std::process::Command::new("cmd")
            .args(["/c", "exit"])
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .spawn()
            .expect("spawn short-lived child");
        let watched = child.id();

        super::spawn_waiter(
            watched,
            &format!(
                "Set-Content -Path '{}' -Value ok",
                marker.display()
            ),
        )
        .expect("spawn waiter");

        let _ = child.wait();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::time::Instant::now() < deadline {
            if marker.exists() {
                let _ = std::fs::remove_file(&marker);
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
        panic!("relaunch waiter never ran its launch snippet");
    }
}

#[cfg(all(test, target_os = "linux"))]
mod linux_updater_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;

    /// The real `/.flatpak-info` of an installed flatpak, read out of a live sandbox and
    /// trimmed only of the long `[Environment]` tail.
    const REAL_FLATPAK_INFO: &str = r#"[Application]
name=com.anonlisten.Hollow
runtime=runtime/org.freedesktop.Platform/x86_64/24.08

[Instance]
instance-id=1167527928
instance-path=/home/jabun/.var/app/com.anonlisten.Hollow
app-path=/home/jabun/.local/share/flatpak/app/com.anonlisten.Hollow/x86_64/master/7401fe3f51778ad1c164a18e2205abc88827600ed6733a2054ba1a8ae7025fd2/files
app-commit=7401fe3f51778ad1c164a18e2205abc88827600ed6733a2054ba1a8ae7025fd2
runtime-path=/home/jabun/.local/share/flatpak/runtime/org.freedesktop.Platform/x86_64/24.08/4ba2d4a7248a77f6510ffab405a729232105958d8347854ab8be74ec67229192/files
branch=master
arch=x86_64
flatpak-version=1.14.6
system-bus-proxy=true

[Context]
shared=network;ipc;
sockets=x11;wayland;pulseaudio;session-bus;
devices=dri;all;
filesystems=xdg-download;home;

[Session Bus Policy]
com.anonlisten.Hollow=own
org.freedesktop.portal.Desktop=talk
"#;

    fn unique_tmp(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let p = std::env::temp_dir().join(format!(
            "hollow_updater_{tag}_{}_{nanos}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).expect("create tmp dir");
        p
    }

    fn write_exec(path: &Path, body: &str) {
        fs::write(path, body).expect("write fake binary");
        let mut perms = fs::metadata(path).expect("stat").permissions();
        perms.set_mode(0o700);
        fs::set_permissions(path, perms).expect("chmod");
    }

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap_or_default()
    }

    fn poll_until(secs: u64, mut ready: impl FnMut() -> bool) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
        while std::time::Instant::now() < deadline {
            if ready() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
        ready()
    }

    /// Only ever called on pids this test itself started (through the script
    /// it generated).
    fn kill_recorded_pids(pid_file: &Path) {
        for line in read(pid_file).lines() {
            let line = line.trim();
            if line.parse::<u32>().is_ok() {
                let _ = Command::new("kill").args(["-9", line]).status();
            }
        }
    }

    /// A fake Hollow: leaves a marker, records its own pid, then sits still.
    /// `exec sleep` keeps the recorded pid valid, so the test can kill exactly
    /// what it started.
    fn fake_app(marker: &Path, pid_file: &Path, alive: bool) -> String {
        let tail = if alive { "exec sleep 60\n" } else { "exit 1\n" };
        format!(
            "#!/bin/sh\necho ran >> {marker}\necho $$ >> {pids}\n{tail}",
            marker = sh_quote(&marker.display().to_string()),
            pids = sh_quote(&pid_file.display().to_string()),
        )
    }

    #[test]
    fn flatpak_info_parse_picks_scope_and_instance() {
        let info = parse_flatpak_info(REAL_FLATPAK_INFO).expect("real /.flatpak-info parses");
        assert_eq!(info.instance_id, "1167527928");
        assert_eq!(info.scope(), "--user");

        let system = REAL_FLATPAK_INFO.replace(
            "app-path=/home/jabun/.local/share/flatpak/app",
            "app-path=/var/lib/flatpak/app",
        );
        let info = parse_flatpak_info(&system).expect("system install parses");
        assert_eq!(info.scope(), "--system");
        assert_eq!(info.instance_id, "1167527928");

        // The keys only count inside [Instance].
        assert!(
            parse_flatpak_info(
                "[Application]\napp-path=/var/lib/flatpak/app/x\ninstance-id=7\n"
            )
            .is_err()
        );
        assert!(parse_flatpak_info("[Instance]\ninstance-id=7\n").is_err());
        assert!(parse_flatpak_info("[Instance]\napp-path=/x\n").is_err());
        assert!(parse_flatpak_info("").is_err());
    }

    #[test]
    fn flatpak_relaunch_script_waits_on_instance_id() {
        let recipe = flatpak_relaunch_recipe("1167527928", "'--portable' '--data-dir=/tmp/a b'");
        assert!(
            recipe.contains("while flatpak ps --columns=instance 2>/dev/null | grep -qx '1167527928'; do sleep 0.3; done"),
            "recipe does not wait on the instance id:\n{recipe}"
        );
        assert!(recipe.contains("BUS=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus\""));
        assert!(
            recipe.contains("if [ -S \"$BUS\" ]"),
            "the DBUS export is not conditional on the socket existing:\n{recipe}"
        );
        assert!(recipe.contains("DBUS_SESSION_BUS_ADDRESS=\"unix:path=$BUS\""));
        assert!(recipe.contains("export DBUS_SESSION_BUS_ADDRESS"));
        assert!(
            recipe.contains(
                "exec flatpak run com.anonlisten.Hollow '--portable' '--data-dir=/tmp/a b'"
            ),
            "the original argv is not forwarded:\n{recipe}"
        );
        // A quote in an argument must not break the script out of its quoting.
        let quoted = flatpak_relaunch_recipe("id'; touch /tmp/pwned; '", "'a'\\''b'");
        let status = Command::new("sh")
            .args(["-n", "-c", &quoted])
            .status()
            .expect("run sh -n");
        assert!(status.success(), "generated recipe is not valid sh:\n{quoted}");
    }

    /// End-to-end mechanics of the tarball swap: a real child to outwait, a real tarball,
    /// the real generated script, started through the real `launch_update_script`.
    #[test]
    fn tarball_update_script_swaps_bundle_and_relaunches() {
        let tmp = unique_tmp("swap");
        let old_marker = tmp.join("old-ran");
        let new_marker = tmp.join("new-ran");
        let old_pids = tmp.join("old.pid");
        let new_pids = tmp.join("new.pid");

        let app = tmp.join("app");
        fs::create_dir_all(&app).expect("create app dir");
        let old_body = fake_app(&old_marker, &old_pids, true);
        write_exec(&app.join("hollow"), &old_body);

        // Packed the way the release tarball is: bundle/hollow.
        let src = tmp.join("src");
        fs::create_dir_all(src.join("bundle")).expect("create bundle dir");
        let new_body = fake_app(&new_marker, &new_pids, true);
        write_exec(&src.join("bundle").join("hollow"), &new_body);
        let archive = tmp.join("update.tar.gz");
        let tar = Command::new("tar")
            .args([
                "czf",
                archive.to_str().unwrap(),
                "-C",
                src.to_str().unwrap(),
                "bundle",
            ])
            .status()
            .expect("run tar");
        assert!(tar.success(), "could not build the fixture tarball");

        let data = tmp.join("data");
        let mut child = Command::new(app.join("hollow"))
            .spawn()
            .expect("start the fake running Hollow");
        let watched = child.id();

        let script = apply_update_tarball(
            &data,
            archive.to_str().unwrap(),
            app.to_str().unwrap(),
            &ReleaseName { tag: "9.9.9".into(), display: "9.9.9".into() },
            watched,
        )
        .expect("generate the update script");
        launch_update_script(script).expect("start the update script");

        // Reaped so the pid is really gone: `kill -0` succeeds on a zombie and the script
        // would wait forever.
        let _ = child.kill();
        let _ = child.wait();

        let app_exe = app.join("hollow");
        let old_dir = tmp.join("app.old");
        let done = poll_until(25, || {
            read(&app_exe) == new_body && new_marker.exists() && !old_dir.exists()
        });

        let log = read(&data.join("updates").join("update.log"));
        kill_recorded_pids(&new_pids);
        kill_recorded_pids(&old_pids);

        assert!(
            done,
            "the bundle swap did not complete.\nlog:\n{log}\napp/hollow now:\n{}\napp.old exists: {}",
            read(&app_exe),
            old_dir.exists()
        );
        assert!(
            !archive.exists(),
            "the downloaded archive was not cleaned up.\nlog:\n{log}"
        );
        assert!(
            !data.join("updates").join("staging-9.9.9").exists(),
            "the staging dir was not cleaned up.\nlog:\n{log}"
        );
        let _ = fs::remove_dir_all(&tmp);
    }

    /// The rollback: a new build that dies inside the 8 second window must put
    /// the previous bundle back and start it again.
    #[test]
    fn tarball_update_rolls_back_when_new_build_dies() {
        let tmp = unique_tmp("rollback");
        let old_marker = tmp.join("old-ran");
        let new_marker = tmp.join("new-ran");
        let old_pids = tmp.join("old.pid");
        let new_pids = tmp.join("new.pid");

        let app = tmp.join("app");
        fs::create_dir_all(&app).expect("create app dir");
        let old_body = fake_app(&old_marker, &old_pids, true);
        write_exec(&app.join("hollow"), &old_body);

        let src = tmp.join("src");
        fs::create_dir_all(src.join("bundle")).expect("create bundle dir");
        // Runs, records itself, then dies immediately: the broken update.
        let new_body = fake_app(&new_marker, &new_pids, false);
        write_exec(&src.join("bundle").join("hollow"), &new_body);
        let archive = tmp.join("update.tar.gz");
        let tar = Command::new("tar")
            .args([
                "czf",
                archive.to_str().unwrap(),
                "-C",
                src.to_str().unwrap(),
                "bundle",
            ])
            .status()
            .expect("run tar");
        assert!(tar.success(), "could not build the fixture tarball");

        let data = tmp.join("data");
        let mut child = Command::new(app.join("hollow"))
            .spawn()
            .expect("start the fake running Hollow");
        let watched = child.id();

        let script = apply_update_tarball(
            &data,
            archive.to_str().unwrap(),
            app.to_str().unwrap(),
            &ReleaseName { tag: "9.9.9".into(), display: "9.9.9".into() },
            watched,
        )
        .expect("generate the update script");
        launch_update_script(script).expect("start the update script");

        let _ = child.kill();
        let _ = child.wait();

        let app_exe = app.join("hollow");
        let old_dir = tmp.join("app.old");
        let done = poll_until(35, || {
            read(&app_exe) == old_body
                && new_marker.exists()
                && read(&old_pids).lines().filter(|l| !l.trim().is_empty()).count() >= 2
                && !old_dir.exists()
        });

        let log = read(&data.join("updates").join("update.log"));
        kill_recorded_pids(&old_pids);
        kill_recorded_pids(&new_pids);

        assert!(
            done,
            "the update did not roll back.\nlog:\n{log}\napp/hollow now:\n{}\nold pids:\n{}\nnew ran: {}",
            read(&app_exe),
            read(&old_pids),
            new_marker.exists()
        );
        let _ = fs::remove_dir_all(&tmp);
    }

    /// A portable copy: its data folder and marker live in the bundle folder the swap
    /// moves aside, and the update's own files would have moved with them.
    struct PortableCopy {
        tmp: PathBuf,
        app: PathBuf,
        archive: PathBuf,
        new_body: String,
        new_marker: PathBuf,
        old_pids: PathBuf,
        new_pids: PathBuf,
    }

    fn portable_copy(tag: &str, new_lives: bool) -> PortableCopy {
        let tmp = unique_tmp(tag);
        let old_pids = tmp.join("old.pid");
        let new_pids = tmp.join("new.pid");
        let new_marker = tmp.join("new-ran");
        let app = tmp.join("Hollow");
        fs::create_dir_all(app.join("hollow_data")).expect("create the data folder");
        write_exec(&app.join("hollow"), &fake_app(&tmp.join("old-ran"), &old_pids, true));
        fs::write(app.join("hollow_data").join("identity.key"), b"the person's key").unwrap();
        fs::write(app.join("hollow_data").join("messages.db"), b"the person's messages").unwrap();
        fs::write(app.join("portable.txt"), b"").unwrap();

        // The new build notes whether the data was in place when it started, and
        // carries a stray data folder of its own, as 0.12.1 to 0.14.1 did on Windows.
        let src = tmp.join("src");
        fs::create_dir_all(src.join("bundle").join("hollow_data")).unwrap();
        fs::write(src.join("bundle").join("hollow_data").join("messages.db"), b"stray").unwrap();
        let tail = if new_lives { "exec sleep 60\n" } else { "exit 1\n" };
        let new_body = format!(
            "#!/bin/sh\nif [ -f \"$(dirname \"$0\")/hollow_data/identity.key\" ]; then echo data >> {m}; else echo nodata >> {m}; fi\necho $$ >> {p}\n{tail}",
            m = sh_quote(&new_marker.display().to_string()),
            p = sh_quote(&new_pids.display().to_string()),
        );
        write_exec(&src.join("bundle").join("hollow"), &new_body);
        // Downloaded where the app puts it: into the data root, inside the bundle folder.
        fs::create_dir_all(app.join("hollow_data").join("updates")).unwrap();
        let archive = app.join("hollow_data").join("updates").join("hollow-9.9.9-linux.tar.gz");
        let tar = Command::new("tar")
            .args(["czf", archive.to_str().unwrap(), "-C", src.to_str().unwrap(), "bundle"])
            .status()
            .expect("run tar");
        assert!(tar.success(), "could not build the fixture tarball");
        PortableCopy { tmp, app, archive, new_body, new_marker, old_pids, new_pids }
    }

    fn run_portable_update(c: &PortableCopy) {
        let mut child = Command::new(c.app.join("hollow")).spawn().expect("start the fake running Hollow");
        let script = apply_update_tarball(
            &c.app.join("hollow_data"),
            c.archive.to_str().unwrap(),
            c.app.to_str().unwrap(),
            &ReleaseName { tag: "9.9.9".into(), display: "9.9.9".into() },
            child.id(),
        )
        .expect("generate the update script");
        launch_update_script(script).expect("start the update script");
        let _ = child.kill();
        let _ = child.wait();
    }

    fn assert_data_kept(c: &PortableCopy, log: &str) {
        let data = c.app.join("hollow_data");
        assert_eq!(fs::read(data.join("identity.key")).ok().as_deref(), Some(&b"the person's key"[..]), "the identity is gone.\nlog:\n{log}");
        assert_eq!(fs::read(data.join("messages.db")).ok().as_deref(), Some(&b"the person's messages"[..]), "the database is gone or replaced.\nlog:\n{log}");
        assert!(c.app.join("portable.txt").exists(), "the portable marker is gone.\nlog:\n{log}");
    }

    /// #155 review: the swap moved the bundle folder aside and deleted it with the
    /// portable data folder and marker inside.
    #[test]
    fn a_tarball_update_keeps_the_portable_data_folder() {
        let c = portable_copy("portable", true);
        run_portable_update(&c);
        let old_dir = c.tmp.join("Hollow.old");
        let done = poll_until(25, || {
            read(&c.app.join("hollow")) == c.new_body && c.new_marker.exists() && !old_dir.exists()
        });
        let log = read(&c.tmp.join("Hollow.update.log"));
        kill_recorded_pids(&c.new_pids);
        kill_recorded_pids(&c.old_pids);
        assert!(done, "the bundle swap did not complete.\nlog:\n{log}");
        assert_eq!(read(&c.new_marker).trim(), "data", "the new build started without the data.\nlog:\n{log}");
        assert_data_kept(&c, &log);
        assert!(log.contains("updated to v9.9.9"), "log:\n{log}");
        assert!(!c.tmp.join("Hollow.update-9.9.9").exists(), "the staging folder was not cleaned up");
        assert!(!c.archive.exists(), "the archive was not cleaned up");
        let _ = fs::remove_dir_all(&c.tmp);
    }

    /// A new build that dies early hands the data back to the previous build.
    #[test]
    fn a_tarball_rollback_keeps_the_portable_data_folder() {
        let c = portable_copy("portable_rollback", false);
        run_portable_update(&c);
        let old_dir = c.tmp.join("Hollow.old");
        let done = poll_until(35, || {
            c.new_marker.exists()
                && read(&c.old_pids).lines().filter(|l| !l.trim().is_empty()).count() >= 2
                && !old_dir.exists()
        });
        let log = read(&c.tmp.join("Hollow.update.log"));
        kill_recorded_pids(&c.old_pids);
        kill_recorded_pids(&c.new_pids);
        assert!(done, "the update did not roll back.\nlog:\n{log}");
        assert_ne!(read(&c.app.join("hollow")), c.new_body, "the broken build stayed.\nlog:\n{log}");
        assert_data_kept(&c, &log);
        let _ = fs::remove_dir_all(&c.tmp);
    }

    /// An earlier update that stopped with data still in `<app>.old` keeps it: the
    /// next update changes nothing rather than clearing that folder.
    #[test]
    fn a_tarball_update_never_clears_an_old_build_holding_data() {
        let c = portable_copy("portable_leftover", true);
        let left = c.tmp.join("Hollow.old").join("hollow_data");
        fs::create_dir_all(&left).unwrap();
        fs::write(left.join("identity.key"), b"an earlier identity").unwrap();
        run_portable_update(&c);
        let log_path = c.tmp.join("Hollow.update.log");
        let stopped = poll_until(20, || read(&log_path).contains("nothing was changed"));
        let log = read(&log_path);
        kill_recorded_pids(&c.new_pids);
        kill_recorded_pids(&c.old_pids);
        assert!(stopped, "the update went on.\nlog:\n{log}");
        assert_eq!(fs::read(left.join("identity.key")).ok().as_deref(), Some(&b"an earlier identity"[..]), "log:\n{log}");
        assert_data_kept(&c, &log);
        assert_ne!(read(&c.app.join("hollow")), c.new_body, "log:\n{log}");
        let _ = fs::remove_dir_all(&c.tmp);
    }

    /// A data root inside the app folder but not its `hollow_data` would go with the
    /// old build, so that update installs nothing.
    #[test]
    fn a_tarball_update_refuses_a_data_root_it_would_delete() {
        let c = portable_copy("portable_refuse", true);
        let data = c.app.join("lib").join("my data");
        fs::create_dir_all(&data).unwrap();
        let r = apply_update_tarball(
            &data,
            c.archive.to_str().unwrap(),
            c.app.to_str().unwrap(),
            &ReleaseName { tag: "9.9.9".into(), display: "9.9.9".into() },
            1,
        );
        assert_eq!(r, Err(DATA_INSIDE_APP.to_string()));
        assert!(!data.join("updates").join("update.sh").exists(), "a script was written");
        let _ = fs::remove_dir_all(&c.tmp);
    }
}

#[cfg(test)]
mod relaunch_args_tests {
    use super::{bat_quoted_arg, bat_relaunch_line, macos_relaunch_line, update_bat_script};

    fn strings(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    /// Inside the quotes cmd reads its metacharacters literally; only `%` needs
    /// doubling, and only a TRAILING backslash run doubles for CommandLineToArgvW.
    #[test]
    fn bat_args_are_quoted_for_cmd_and_the_app() {
        let cases: &[(&str, &str)] = &[
            ("--portable", r#""--portable""#),
            ("with space", r#""with space""#),
            ("%PATH%", r#""%%PATH%%""#),
            ("50%", r#""50%%""#),
            ("a&b|c<d>e^f(g)!h!", r#""a&b|c<d>e^f(g)!h!""#),
            (r"C:\a\b", r#""C:\a\b""#),
            (r"C:\dir\", r#""C:\dir\\""#),
            (r"C:\dir\\", r#""C:\dir\\\\""#),
            ("", r#""""#),
            ("ünï Віталій 测试 🎮", "\"ünï Віталій 测试 🎮\""),
        ];
        for (arg, want) in cases {
            assert_eq!(bat_quoted_arg(arg).as_deref(), Ok(*want), "{arg:?}");
        }
    }

    /// A quote ends cmd's quoted run (everything after it is live) and a control
    /// character ends the line, so neither is ever written.
    #[test]
    fn bat_args_with_a_quote_or_control_character_refuse() {
        for bad in ["a\"b", "\"", "a\" & calc & \"", "a\r\ncalc", "a\nb", "a\tb", "a\0b", "a\u{1b}b"] {
            assert!(bat_quoted_arg(bad).is_err(), "{bad:?} accepted");
        }
    }

    #[test]
    fn one_argument_the_script_cannot_carry_refuses_the_relaunch() {
        let r = bat_relaunch_line(r"C:\App\hollow.exe", &strings(&["--portable", "x\"y"]));
        assert!(r.is_err(), "relaunch written without an argument: {r:?}");
    }

    #[test]
    fn the_update_script_relaunches_with_the_original_arguments() {
        let line = bat_relaunch_line(r"C:\App\hollow.exe", &strings(&["--portable", "x y", "%TEMP%"])).unwrap();
        assert_eq!(line, r#"start "" "C:\App\hollow.exe" "--portable" "x y" "%%TEMP%%""#);
        let bat = update_bat_script("0.14.2", r"C:\D\staging", r"C:\D\u.zip", r"C:\App", "hollow.exe", 4242, &line);
        let lines: Vec<&str> = bat.split("\r\n").collect();
        assert!(lines.contains(&line.as_str()), "relaunch line missing:\n{bat}");
        assert_eq!(lines.iter().filter(|l| l.starts_with("start ")).count(), 1, "{bat}");
        let pos = |needle: &str| lines.iter().position(|l| l.starts_with(needle)).unwrap();
        // Both settings must be in force before the first line carrying a path.
        assert!(pos("setlocal DisableDelayedExpansion") < pos("xcopy"));
        assert!(pos("chcp 65001") < pos("xcopy"));
        assert!(pos("xcopy") < pos("start "));
        // It waits for the process that wrote it, by pid.
        assert!(lines[pos("tasklist")].contains("/FI \"PID eq 4242\""), "{bat}");
        // Only a copy that succeeded reaches the relaunch; a failed one loops back to it.
        assert_eq!(lines[pos("xcopy") + 1], "if not errorlevel 1 goto copied", "{bat}");
        assert!(pos(":copy") < pos("xcopy") && pos(":copied") < pos("start "), "{bat}");
        assert_eq!(lines[..pos(":copied")].iter().filter(|l| l.starts_with("start ")).count(), 0);
        let failed = &lines[pos(":copyfailed")..pos(":copied")];
        assert_eq!(failed.last(), Some(&"goto copy"), "{bat}");
        assert!(failed.iter().any(|l| l.contains(r#"waiting in "C:\D\staging"."#)), "the message must name the staged files:\n{bat}");
    }

    /// The self-restart hands Start-Process ONE command line: as a list, Windows
    /// PowerShell joins it unquoted and an argument holding a space splits.
    #[test]
    fn the_self_restart_keeps_an_argument_with_a_space() {
        let args = strings(&["--portable", "C:\\My Data\\", "a\"b", "it's", ""]);
        let line = super::powershell_relaunch(r"C:\Pro'gram\hollow.exe", &args);
        assert_eq!(
            line,
            r#"Start-Process -FilePath 'C:\Pro''gram\hollow.exe' -ArgumentList '"--portable" "C:\My Data\\" "a\"b" "it''s" ""'"#
        );
        assert_eq!(super::powershell_relaunch(r"C:\h.exe", &[]), r"Start-Process -FilePath 'C:\h.exe'");
        assert_eq!(super::ps_quote("a\u{2019}b"), "'a\u{2019}\u{2019}b'");
    }

    /// The self-restart carries this process's own arguments, each quoted for the
    /// platform's launcher.
    #[test]
    fn the_self_restart_takes_this_processs_own_arguments() {
        let own: Vec<String> = std::env::args().skip(1).collect();
        assert!(!own.is_empty(), "the test runner passes arguments, so this proves something");
        let snippet = super::self_restart_snippet().unwrap();
        for arg in &own {
            #[cfg(windows)]
            let quoted = super::argv_quote(arg).replace('\'', "''");
            #[cfg(not(windows))]
            let quoted = super::sh_quote(arg);
            assert!(snippet.contains(&quoted), "{arg:?} missing from {snippet}");
        }
    }

    /// LaunchServices starts a bundle with its own environment, so the override
    /// must ride `open --env`.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_macos_self_restart_keeps_the_data_root_override() {
        let snippet = super::relaunch_snippet("/Apps/Hollow.app/Contents/MacOS/Hollow", &strings(&["--portable"]), Some("/d/x y"));
        assert_eq!(snippet, "/usr/bin/open -n --env 'HOLLOW_DATA_DIR=/d/x y' '/Apps/Hollow.app' --args '--portable'");
    }

    #[test]
    fn argv_quoting_round_trips_through_the_windows_rules() {
        let cases: &[(&str, &str)] = &[
            ("plain", r#""plain""#),
            ("a b", r#""a b""#),
            (r"C:\x\", r#""C:\x\\""#),
            (r#"a"b"#, r#""a\"b""#),
            (r#"a\"b"#, r#""a\\\"b""#),
            (r"a\b", r#""a\b""#),
            ("", r#""""#),
        ];
        for (arg, want) in cases {
            assert_eq!(super::argv_quote(arg), *want, "{arg:?}");
        }
    }

    #[test]
    fn the_relaunch_takes_this_processs_own_arguments() {
        let own: Vec<String> = std::env::args().skip(1).collect();
        assert!(!own.is_empty(), "the test runner passes arguments, so this proves something");
        assert_eq!(super::relaunch_args().unwrap(), own);
    }

    #[test]
    fn an_argument_that_is_not_unicode_refuses() {
        #[cfg(windows)]
        let bad = {
            use std::os::windows::ffi::OsStringExt;
            std::ffi::OsString::from_wide(&[0x61, 0xD800, 0x62])
        };
        #[cfg(unix)]
        let bad = {
            use std::os::unix::ffi::OsStringExt;
            std::ffi::OsString::from_vec(vec![b'a', 0xff, b'b'])
        };
        let r = super::carried_args(vec!["--portable".into(), bad]);
        assert!(r.is_err(), "a non-Unicode argument was dropped or mangled: {r:?}");
        assert_eq!(super::carried_args(vec!["--portable".into()]).unwrap(), vec!["--portable".to_string()]);
    }

    /// #155 review: a copy started by a `hollow:` link opened it again after every
    /// update and self-restart.
    #[test]
    fn the_relaunch_does_not_replay_a_deep_link() {
        let argv = |v: &[&str]| v.iter().map(std::ffi::OsString::from).collect::<Vec<_>>();
        let launched = argv(&["hollow://invite/abc#key=x", "--portable", "HOLLOW:share/1", "Hollow://x"]);
        assert_eq!(super::carried_args(launched.clone()).unwrap(), strings(&["--portable"]));
        assert_eq!(super::carried_args(argv(&["hollow:"])).unwrap(), Vec::<String>::new());
        // Only the scheme counts: a path or value that merely mentions it stays.
        let kept = strings(&["--data-dir=/x/hollow://y", "hollowx", "hollow", ""]);
        assert_eq!(super::carried_args(argv(&["--data-dir=/x/hollow://y", "hollowx", "hollow", ""])).unwrap(), kept);
        let snippet = super::self_restart_snippet_for(launched).unwrap();
        assert!(!snippet.to_ascii_lowercase().contains("hollow:"), "the self-restart replays the link: {snippet}");
        assert!(snippet.contains("--portable"), "{snippet}");
    }

    #[test]
    fn a_plain_launch_keeps_the_plain_line() {
        assert_eq!(bat_relaunch_line(r"C:\App\hollow.exe", &[]).unwrap(), r#"start "" "C:\App\hollow.exe""#);
    }

    #[test]
    fn the_macos_relaunch_carries_arguments_and_the_data_root_override() {
        let args = strings(&["--portable", "it's here"]);
        assert_eq!(
            macos_relaunch_line("/Applications/Hollow.app", &args, None),
            r#"/usr/bin/open -n '/Applications/Hollow.app' --args '--portable' 'it'\''s here'"#
        );
        assert_eq!(
            macos_relaunch_line("/Applications/Hollow.app", &[], Some("/tmp/a b")),
            "/usr/bin/open -n --env 'HOLLOW_DATA_DIR=/tmp/a b' '/Applications/Hollow.app'"
        );
    }

    /// What `sh` hands `open`: every argument back exactly, nothing expanded.
    #[cfg(unix)]
    #[test]
    fn the_macos_relaunch_line_parses_back_to_the_same_argv() {
        let args = strings(&["--portable", "a b", "$HOME", "`id`", "x'y", "\"q\"", "ünï", "", "a;b&c|d"]);
        let line = macos_relaunch_line("/Apps/My $X.app", &args, Some("/d/$Y"));
        let probe = line.replacen("/usr/bin/open", "printf '%s\\0'", 1);
        let out = std::process::Command::new("/bin/sh").args(["-c", &probe]).output().expect("sh");
        let got: Vec<String> = String::from_utf8(out.stdout)
            .unwrap()
            .split_terminator('\0')
            .map(str::to_string)
            .collect();
        let mut want = strings(&["-n", "--env", "HOLLOW_DATA_DIR=/d/$Y", "/Apps/My $X.app", "--args"]);
        want.extend(args);
        assert_eq!(got, want);
    }
}

/// End to end on a real cmd: the generated `update.bat`, with delayed expansion
/// forced on and the console's own code page, installs into a path full of cmd
/// metacharacters and relaunches with every argument intact. The "app" is
/// powershell reporting the argv its CommandLineToArgvW-style parse produced.
#[cfg(all(test, windows))]
mod update_bat_tests {
    use super::{bat_quoted_path, bat_relaunch_line, update_bat_script};
    use std::fs;
    use std::time::{Duration, Instant};

    fn weird_args() -> Vec<String> {
        [
            "--portable", "with space", "%PATH%", "!USERNAME!", "a&b|c<d>e^f", "(paren)", r"C:\trail\",
            "ünï Віталій 测试", "",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }

    struct Run {
        status: std::process::ExitStatus,
        out: std::path::PathBuf,
        console: std::path::PathBuf,
        app: std::path::PathBuf,
        staging: std::path::PathBuf,
        zip: std::path::PathBuf,
    }

    const DUMPER: &str = "$t = $env:HOLLOW_ARGV_OUT + '.tmp'\r\n\
         [IO.File]::WriteAllText($t, ([Environment]::GetCommandLineArgs() -join \"`n\"), (New-Object Text.UTF8Encoding $false))\r\n\
         Move-Item -LiteralPath $t -Destination $env:HOLLOW_ARGV_OUT\r\n";

    fn ps_args(dumper: &std::path::Path, extra: &[String]) -> Vec<String> {
        let mut args: Vec<String> = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", dumper.to_str().unwrap()]
            .iter()
            .map(|s| s.to_string())
            .collect();
        args.extend_from_slice(extra);
        args
    }

    /// Writes the real update.bat under `root` (a path full of cmd metacharacters),
    /// whose "app" is powershell reporting its argv, and starts it the way cmd would
    /// with delayed expansion forced on. `before` runs once the folders exist and
    /// returns what must stay alive until the script ends (a lock, a process).
    fn start_bat<T>(
        tmp: &std::path::Path,
        wait: (&str, u32),
        extra: &[String],
        before: impl FnOnce(&std::path::Path) -> T,
    ) -> (std::process::Child, Run, T) {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
        let root = tmp.join("a&b %PATH% !x! ^c (d) Віталій");
        let staging = root.join("staging");
        let app = root.join("app");
        fs::create_dir_all(&staging).unwrap();
        fs::create_dir_all(&app).unwrap();
        fs::write(staging.join("marker.txt"), b"new build").unwrap();
        fs::write(app.join("marker.txt"), b"old build").unwrap();
        let zip = root.join("u.zip");
        fs::write(&zip, b"zip").unwrap();
        let dumper = root.join("dump argv.ps1");
        fs::write(&dumper, DUMPER).unwrap();
        let held = before(&app);
        let out = tmp.join("argv.txt");
        let ps = std::path::PathBuf::from(std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into()))
            .join(r"System32\WindowsPowerShell\v1.0\powershell.exe");
        let relaunch = bat_relaunch_line(&bat_quoted_path(ps.to_str().unwrap()).unwrap(), &ps_args(&dumper, extra)).unwrap();
        let q = |p: &std::path::Path| bat_quoted_path(p.to_str().unwrap()).unwrap();
        let bat = update_bat_script("9.9.9", &q(&staging), &q(&zip), &q(&app), wait.0, wait.1, &relaunch);
        let bat_path = tmp.join("update.bat");
        fs::write(&bat_path, bat).unwrap();
        let console = tmp.join("console.txt");
        let child = std::process::Command::new("cmd")
            .args(["/V:ON", "/C"])
            .arg(&bat_path)
            .env("HOLLOW_ARGV_OUT", &out)
            .creation_flags(CREATE_NEW_CONSOLE)
            // A pipe nobody writes to: `pause` waits on it until a test "presses a key".
            .stdin(std::process::Stdio::piped())
            .stdout(fs::File::create(&console).unwrap())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("run update.bat");
        let run = Run { status: std::process::ExitStatus::default(), out, console, app, staging, zip };
        (child, run, held)
    }

    fn finish(mut child: std::process::Child, mut run: Run) -> Run {
        run.status = child.wait().unwrap();
        run
    }

    fn wait_for(path: &std::path::Path, secs: u64) -> bool {
        let start = Instant::now();
        while !path.exists() && start.elapsed() < Duration::from_secs(secs) {
            std::thread::sleep(Duration::from_millis(200));
        }
        path.exists()
    }

    fn console(run: &Run) -> String {
        String::from_utf8_lossy(&fs::read(&run.console).unwrap_or_default()).into_owned()
    }

    #[test]
    fn update_bat_relaunches_with_every_argument_intact() {
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let (child, run, ()) = start_bat(tmp.path(), ("hollow-test-absent.exe", 1), &weird_args(), |_| ());
        // Its exit code is the last command's (a `timeout` with no console input
        // fails), so only what the script did counts.
        let run = finish(child, run);
        assert!(wait_for(&run.out, 60), "the relaunched app never ran; console:\n{}", console(&run));
        let dumped = fs::read_to_string(&run.out).unwrap();
        let got: Vec<&str> = dumped.split('\n').collect();
        let want = weird_args();
        assert_eq!(&got[6..], &want.iter().map(String::as_str).collect::<Vec<_>>()[..], "{got:?}");
        assert_eq!(fs::read(run.app.join("marker.txt")).unwrap(), b"new build", "xcopy did not install");
        assert!(!run.staging.exists(), "staging was not cleaned up");
        assert!(!run.zip.exists(), "the zip was not deleted");
    }

    fn ping(seconds: u32) -> std::process::Child {
        std::process::Command::new("ping")
            .args(["-n", &seconds.to_string(), "127.0.0.1"])
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap()
    }

    /// The script waits for the app that wrote it, and only for it: another copy of
    /// the same program (a second install, a fleet peer) never holds the update.
    /// Whether `tasklist` can see processes here: over ssh it answers "Access
    /// denied", the script's wait then ends at once, and this test proves nothing.
    /// It is run in a desktop session for that reason (b155 proof, round 2).
    fn tasklist_sees_processes() -> bool {
        let me = std::process::id().to_string();
        std::process::Command::new("tasklist")
            .args(["/FI", &format!("PID eq {me}")])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains(&me))
            .unwrap_or(false)
    }

    #[test]
    fn update_bat_waits_for_its_own_process_only() {
        if !tasklist_sees_processes() {
            return;
        }
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let mut other = ping(90);
        let mut own = ping(6);
        let (child, run, ()) = start_bat(tmp.path(), ("PING.EXE", own.id()), &[], |_| ());
        while own.try_wait().unwrap().is_none() {
            assert!(!run.out.exists(), "relaunched while its own process still ran");
            std::thread::sleep(Duration::from_millis(100));
        }
        let ok = wait_for(&run.out, 45);
        let other_alive = other.try_wait().unwrap().is_none();
        let _ = other.kill();
        let run = finish(child, run);
        assert!(ok, "never relaunched after its own process ended; console:\n{}", console(&run));
        assert!(other_alive, "the relaunch waited for another process of the same name");
    }

    /// Ends a script a test gave up on, by its pid (its `pause` would wait forever).
    /// Disarmed (`None`) before the child is reaped, so a reused pid is never hit.
    struct KillOnDrop(Option<u32>);

    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            if let Some(pid) = self.0 {
                let _ = std::process::Command::new("taskkill")
                    .args(["/F", "/T", "/PID", &pid.to_string()])
                    .output();
            }
        }
    }

    fn hold_marker(app: &std::path::Path) -> fs::File {
        use std::os::windows::fs::OpenOptionsExt;
        fs::OpenOptions::new().read(true).share_mode(0).open(app.join("marker.txt")).unwrap()
    }

    fn wait_until(secs: u64, mut ready: impl FnMut() -> bool) -> bool {
        let start = Instant::now();
        while !ready() && start.elapsed() < Duration::from_secs(secs) {
            std::thread::sleep(Duration::from_millis(200));
        }
        ready()
    }

    /// #155 review: a file in use for a moment (a scan, a closing helper) failed the
    /// whole update. The copy is tried again on its own, with no key pressed.
    #[test]
    fn a_copy_blocked_for_a_moment_retries_and_finishes() {
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let (child, run, lock) = start_bat(tmp.path(), ("hollow-test-absent.exe", 1), &[], hold_marker);
        let mut kill = KillOnDrop(Some(child.id()));
        // Held from before the first copy for longer than five tries without a pause
        // take, and well inside the five tries two seconds apart.
        let copying = wait_until(60, || console(&run).contains("Copying files"));
        std::thread::sleep(Duration::from_secs(4));
        drop(lock);
        assert!(copying, "the script never reached the copy; console:\n{}", console(&run));
        let relaunched = wait_for(&run.out, 60);
        let text = console(&run);
        assert!(relaunched, "a copy blocked for a moment never finished; console:\n{text}");
        assert!(!text.contains(super::COPY_FAILED_1), "it asked before trying again:\n{text}");
        kill.0 = None;
        let run = finish(child, run);
        assert_eq!(fs::read(run.app.join("marker.txt")).unwrap(), b"new build", "xcopy did not install");
        assert!(!run.staging.exists() && !run.zip.exists(), "the update was not cleaned up");
    }

    /// A copy still failing after its retries starts nothing (a half-copied app could
    /// start on mismatched parts), keeps its files, names where they are and tries
    /// again on a key press.
    #[test]
    fn a_copy_still_blocked_asks_and_tries_again_on_a_key() {
        use std::io::Write;
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let (mut child, run, lock) = start_bat(tmp.path(), ("hollow-test-absent.exe", 1), &[], hold_marker);
        let mut kill = KillOnDrop(Some(child.id()));
        let asked = wait_until(60, || console(&run).contains(super::COPY_FAILED_3));
        let text = console(&run);
        assert!(asked, "a blocked copy never asked; console:\n{text}");
        assert!(text.contains(super::COPY_FAILED_1) && text.contains(super::COPY_FAILED_2), "console:\n{text}");
        assert!(!run.out.exists(), "a half-copied app was started; console:\n{text}");
        assert!(run.zip.exists() && run.staging.exists(), "a failed update threw its files away");
        drop(lock);
        child.stdin.as_mut().unwrap().write_all(b"\r\n").unwrap();
        let relaunched = wait_for(&run.out, 60);
        let text = console(&run);
        assert!(relaunched, "a key press did not try again; console:\n{text}");
        kill.0 = None;
        let run = finish(child, run);
        assert_eq!(fs::read(run.app.join("marker.txt")).unwrap(), b"new build", "xcopy did not install");
    }

    /// The real apply refuses before it writes a script that would drop the argument.
    #[test]
    fn apply_refuses_an_argument_the_script_cannot_carry() {
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let zip = tmp.path().join("update.zip");
        {
            use std::io::Write;
            let mut w = zip::ZipWriter::new(fs::File::create(&zip).unwrap());
            w.start_file("hollow.exe", zip::write::SimpleFileOptions::default()).unwrap();
            w.write_all(b"exe").unwrap();
            w.finish().unwrap();
        }
        let app = tmp.path().join("app");
        fs::create_dir_all(&app).unwrap();
        let bad = vec!["--portable".to_string(), "x\" & calc & \"".to_string()];
        let r = super::apply_update_at(tmp.path(), zip.to_str().unwrap(), app.to_str().unwrap(), "0.14.2", 0, &bad);
        assert!(r.is_err(), "an uncarriable argument was accepted: {r:?}");
        assert!(!tmp.path().join("updates").join("update.bat").exists(), "a script was written");
        let staged = tmp.path().join("updates").join("staging-0.14.2").join("hollow.exe");
        assert!(!staged.exists(), "the update was extracted");
        let ok = super::apply_update_at(tmp.path(), zip.to_str().unwrap(), app.to_str().unwrap(), "0.14.2", 0, &bad[..1]);
        let bat = fs::read_to_string(ok.expect("a carriable argument was refused")).unwrap();
        assert!(bat.contains(r#"\hollow.exe" "--portable""#), "{bat}");
        assert!(bat.contains(&format!("/FI \"PID eq {}\"", std::process::id())), "it must wait for the app that wrote it:\n{bat}");
    }
}

#[cfg(all(test, target_os = "macos"))]
mod macos_update_script_tests {
    use std::fs;

    #[test]
    fn the_macos_update_script_relaunches_with_the_original_arguments() {
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let staging = tmp.path().join("updates").join("staging-x");
        fs::create_dir_all(staging.join("Hollow.app").join("Contents")).unwrap();
        let args = vec!["--portable".to_string(), "a 'b'".to_string()];
        let path = super::write_macos_update_script(
            tmp.path(),
            staging.to_str().unwrap(),
            "/tmp/u $x.zip",
            "/Apps/It's here",
            "0.14.2",
            &args,
        )
        .unwrap();
        let script = fs::read_to_string(&path).unwrap();
        assert!(
            script.contains(r#"/usr/bin/open -n '/Apps/It'\''s here/Hollow.app' --args '--portable' 'a '\''b'\'''"#),
            "{script}"
        );
        let syntax = std::process::Command::new("/bin/sh").args(["-n", &path]).status().unwrap();
        assert!(syntax.success(), "the script does not parse:\n{script}");
    }

    /// The swap deletes the old bundle whole, so a data root inside it refuses the
    /// update; the portable folder beside the bundle is outside what it touches.
    #[test]
    fn the_macos_update_never_replaces_a_bundle_holding_the_data() {
        let tmp = crate::test_tmp::tempdir().expect("tmp");
        let apps = tmp.path().join("Apps");
        let installed = apps.join("Hollow.app");
        fs::create_dir_all(installed.join("Contents")).unwrap();
        let inside = installed.join("Contents").join("data");
        let staging = inside.join("updates").join("staging-x");
        fs::create_dir_all(staging.join("Hollow.app").join("Contents")).unwrap();
        let r = super::write_macos_update_script(
            &inside, staging.to_str().unwrap(), "/tmp/u.zip", apps.to_str().unwrap(), "0.14.2", &[],
        );
        assert_eq!(r, Err(super::DATA_INSIDE_APP.to_string()));
        assert!(!inside.join("updates").join("update.sh").exists(), "a script was written");

        let beside = apps.join("hollow_data");
        let staging = beside.join("updates").join("staging-x");
        fs::create_dir_all(staging.join("Hollow.app").join("Contents")).unwrap();
        let path = super::write_macos_update_script(
            &beside, staging.to_str().unwrap(), "/tmp/u.zip", apps.to_str().unwrap(), "0.14.2", &[],
        )
        .expect("the portable folder beside the bundle refused the update");
        let script = fs::read_to_string(path).unwrap();
        let removes: Vec<&str> = script.lines().filter(|l| l.starts_with("rm ")).collect();
        assert!(removes.iter().all(|l| !l.contains("hollow_data'") && !l.contains("Apps' ")), "{script}");
    }
}
