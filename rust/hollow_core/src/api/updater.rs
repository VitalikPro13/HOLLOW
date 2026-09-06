use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use ed25519_dalek::{Signature, VerifyingKey};
use flutter_rust_bridge::frb;
use futures_util::StreamExt;
use sha2::{Digest, Sha256};

use super::network::get_runtime;
use crate::frb_generated::StreamSink;
use crate::identity::data_dir;

pub(crate) const APP_VERSION: &str = "0.11.0";

/// Ed25519 public keys (hex) allowed to sign the update manifest. The private
/// half lives with the release engineer, never in the repo: `hollow-manifest
/// sign` (rust/hollow_manifest) writes `manifest.json.sig` next to
/// `manifest.json`, and `fetch_version_manifest` refuses a manifest whose
/// signature does not verify against one of these. That is what makes a
/// rewritten manifest on the download host worthless: the host can serve
/// bytes, it cannot mint a signature. More than one entry only while a key
/// is being rotated.
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

/// How this Linux copy of Hollow was installed: `"flatpak"` or `"tarball"`.
/// Empty on every other platform. Dart branches its update UI on this (a
/// flatpak has a read-only `/app`, so the "can I write to the app dir" probe
/// is meaningless there), and every Linux path below reads the SAME detection.
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

/// Fetches `manifest.json` AND its `manifest.json.sig` sidecar, and returns
/// the manifest text only when the signature verifies against
/// [`MANIFEST_SIGNING_PUBKEYS`]. The signature covers the manifest's exact
/// bytes, so the text handed to Dart is byte for byte what was signed.
#[frb]
pub fn fetch_version_manifest(manifest_url: String) -> Result<String, String> {
    let rt = get_runtime();
    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| format!("Failed to build HTTP client: {e}"))?;
        let manifest = fetch_bytes(&client, &manifest_url)
            .await
            .map_err(|e| format!("Failed to fetch manifest: {e}"))?;
        let sig = fetch_bytes(&client, &signature_url(&manifest_url))
            .await
            .map_err(|e| format!("Failed to fetch manifest signature: {e}"))?;
        verify_manifest_signature(&manifest, &String::from_utf8_lossy(&sig))?;
        String::from_utf8(manifest).map_err(|_| "Update manifest is not UTF-8".to_string())
    })
}

/// Plain fetch for the OTHER release-folder feeds (news.json, status.json):
/// display-only text with no signature sidecar. Nothing downloaded through
/// here is ever executed or installed; the update manifest itself must go
/// through [`fetch_version_manifest`].
#[frb]
pub fn fetch_release_feed(url: String) -> Result<String, String> {
    let rt = get_runtime();
    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| format!("Failed to build HTTP client: {e}"))?;
        let body = fetch_bytes(&client, &url)
            .await
            .map_err(|e| format!("Failed to fetch feed: {e}"))?;
        String::from_utf8(body).map_err(|_| "Feed is not UTF-8".to_string())
    })
}

async fn fetch_bytes(client: &reqwest::Client, url: &str) -> Result<Vec<u8>, String> {
    let resp = client
        .get(url)
        .header("Cache-Control", "no-cache")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("server returned {}", resp.status()));
    }
    resp.bytes().await.map(|b| b.to_vec()).map_err(|e| e.to_string())
}

/// `.../manifest.json?t=123` becomes `.../manifest.json.sig?t=123`: the
/// sidecar sits next to the manifest and rides the same cache-buster.
fn signature_url(manifest_url: &str) -> String {
    match manifest_url.split_once('?') {
        Some((path, query)) => format!("{path}.sig?{query}"),
        None => format!("{manifest_url}.sig"),
    }
}

/// The app's manifest check: base64 Ed25519 signature text over the exact
/// manifest bytes, accepted when ANY listed key verifies it (strict
/// verification, so a malleable or weak-key signature is refused too).
/// Mirrors `verify_bytes` in rust/hollow_manifest.
pub(crate) fn verify_manifest_signature(manifest: &[u8], sig_text: &str) -> Result<(), String> {
    verify_manifest_signature_with(manifest, sig_text, MANIFEST_SIGNING_PUBKEYS)
}

fn verify_manifest_signature_with(
    manifest: &[u8],
    sig_text: &str,
    pubkeys_hex: &[&str],
) -> Result<(), String> {
    let sig = base64::engine::general_purpose::STANDARD
        .decode(sig_text.trim())
        .map_err(|_| "Update manifest signature is not base64".to_string())?;
    let sig = Signature::from_slice(&sig)
        .map_err(|_| "Update manifest signature is malformed".to_string())?;
    let verified = pubkeys_hex.iter().any(|hex_key| {
        hex::decode(hex_key)
            .ok()
            .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
            .and_then(|bytes| VerifyingKey::from_bytes(&bytes).ok())
            .is_some_and(|vk| vk.verify_strict(manifest, &sig).is_ok())
    });
    if verified {
        Ok(())
    } else {
        Err("Update manifest signature does not verify. The download host may have been tampered with; nothing was installed.".to_string())
    }
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

/// Downloads `url` to `dest_path` and keeps the file ONLY if its SHA-256 is
/// `expected_sha256` (the value from the signed manifest). Any failure,
/// including a checksum mismatch or a cancelled stream, deletes the partial
/// file and ends the stream with `DownloadProgress::error` set.
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
            let _ = fs::remove_file(&dest_path);
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
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create download directory: {e}"))?;
    }

    let mut file = fs::File::create(&dest)
        .map_err(|e| format!("Failed to create file: {e}"))?;

    let mut bytes_downloaded: u64 = 0;
    let mut stream = resp.bytes_stream();

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Stream error: {e}"))?;
        file.write_all(&chunk)
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
    file.flush().map_err(|e| format!("Write error: {e}"))?;
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
}

#[frb]
pub fn apply_update(
    zip_path: String,
    app_dir: String,
    version: String,
) -> Result<String, String> {
    let data = data_dir()?;
    apply_update_impl(&data, &zip_path, &app_dir, &version)
}

/// Linux: the download is either the portable tarball or a `.flatpak` bundle,
/// and the install kind decides which. Both end with a script path the caller
/// hands to [`launch_update_script`].
#[cfg(target_os = "linux")]
fn apply_update_impl(
    data: &Path,
    archive_path: &str,
    app_dir: &str,
    version: &str,
) -> Result<String, String> {
    match linux_install_kind_inner() {
        "flatpak" => apply_update_flatpak(data, archive_path, version),
        _ => apply_update_tarball(data, archive_path, app_dir, version, std::process::id()),
    }
}

#[cfg(not(target_os = "linux"))]
fn apply_update_impl(
    data: &Path,
    zip_path: &str,
    app_dir: &str,
    version: &str,
) -> Result<String, String> {
    let staging_dir = data.join("updates").join(format!("staging-{version}"));

    if staging_dir.exists() {
        fs::remove_dir_all(&staging_dir)
            .map_err(|e| format!("Failed to clean staging dir: {e}"))?;
    }
    fs::create_dir_all(&staging_dir)
        .map_err(|e| format!("Failed to create staging dir: {e}"))?;

    // macOS: extract with `ditto`, which natively preserves the `.app` bundle's
    // executable permissions, symlinks (frameworks!), and code signature. The
    // Rust `zip` crate drops all of those, which would corrupt the bundle.
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
        return write_macos_update_script(data, staging_str, zip_path, app_dir, version);
    }

    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    {
        let _ = (zip_path, app_dir, version);
        return Err("Auto-update is not supported on this platform yet".into());
    }

    #[cfg(target_os = "windows")]
    {
    extract_zip_to(zip_path, &staging_dir)?;

    let staging_str = staging_dir
        .to_str()
        .ok_or("Staging dir path is not valid UTF-8")?;

    let bat_path = data.join("updates").join("update.bat");
    let zip_path_str = zip_path.replace('/', "\\");
    let bat_content = format!(
        "@echo off\r\n\
         title Hollow Update\r\n\
         echo.\r\n\
         echo   ========================================\r\n\
         echo     Hollow Update - v{version}\r\n\
         echo   ========================================\r\n\
         echo.\r\n\
         echo   Waiting for Hollow to close...\r\n\
         :wait\r\n\
         tasklist /FI \"IMAGENAME eq hollow.exe\" 2>NUL | find /I \"hollow.exe\" >NUL\r\n\
         if %ERRORLEVEL% == 0 (\r\n\
             timeout /t 1 /nobreak >NUL\r\n\
             goto wait\r\n\
         )\r\n\
         echo   Copying files...\r\n\
         xcopy /E /Y /Q \"{staging_str}\\*\" \"{app_dir}\\\" >NUL\r\n\
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
         start \"\" \"{app_dir}\\hollow.exe\"\r\n\
         exit\r\n"
    );

    fs::write(&bat_path, bat_content)
        .map_err(|e| format!("Failed to write update script: {e}"))?;

    bat_path
        .to_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "Bat path is not valid UTF-8".to_string())
    }
}

/// Builds the `.app`-swap shell script used on macOS.
///
/// The downloaded zip is expected to contain a single `*.app` bundle (e.g.
/// `Hollow.app`). `app_dir` is the directory that currently holds the running
/// bundle (e.g. `/Applications`). The script waits for the running process to
/// exit, replaces the old bundle with the staged one via `ditto` (which
/// preserves bundle structure and any signature), clears the quarantine
/// attribute, then relaunches with `open`.
#[cfg(target_os = "macos")]
fn write_macos_update_script(
    data: &std::path::Path,
    staging_str: &str,
    zip_path: &str,
    app_dir: &str,
    version: &str,
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

    let sh_path = data.join("updates").join("update.sh");
    let log_path = data.join("updates").join("update.log");
    let log_str = log_path.to_str().ok_or("Log path is not valid UTF-8")?;

    // Note: `pgrep -f` on the installed bundle path waits for *this* app to die.
    let sh_content = format!(
        "#!/bin/sh\n\
         set -e\n\
         LOG=\"{log_str}\"\n\
         echo \"Hollow update -> v{version}\" > \"$LOG\"\n\
         echo \"Waiting for Hollow to close...\" >> \"$LOG\"\n\
         # Wait until no process is running from the installed bundle.\n\
         while pgrep -f \"{installed_app}/Contents/MacOS/\" >/dev/null 2>&1; do\n\
         \tsleep 1\n\
         done\n\
         sleep 1\n\
         echo \"Replacing bundle...\" >> \"$LOG\"\n\
         rm -rf \"{installed_app}\" >> \"$LOG\" 2>&1 || true\n\
         /usr/bin/ditto \"{staged_app_str}\" \"{installed_app}\" >> \"$LOG\" 2>&1\n\
         echo \"Clearing quarantine...\" >> \"$LOG\"\n\
         /usr/bin/xattr -dr com.apple.quarantine \"{installed_app}\" >> \"$LOG\" 2>&1 || true\n\
         echo \"Cleaning up...\" >> \"$LOG\"\n\
         rm -rf \"{staging_str}\" >> \"$LOG\" 2>&1 || true\n\
         rm -f \"{zip_path}\" >> \"$LOG\" 2>&1 || true\n\
         echo \"Relaunching...\" >> \"$LOG\"\n\
         /usr/bin/open -n \"{installed_app}\" >> \"$LOG\" 2>&1\n\
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

// ── Linux updates ───────────────────────────────────────────────────────────
//
// Two install kinds, one detection. The portable tarball owns its own
// directory, so an update is a rename swap performed by a detached script once
// this process is gone. A flatpak cannot touch its own deployment at all: the
// install has to run on the HOST through `flatpak-spawn`, and the relaunch has
// to run there too, because the sandbox's PID namespace dies with the app and
// would take any in-sandbox waiter with it.

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

/// POSIX single-quoting: wrap in `'…'`, write an embedded `'` as `'\''`. Every
/// path and argv element baked into a generated script goes through this, so a
/// space or a quote in a data directory cannot split a command.
#[cfg(not(windows))]
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// This process's argv (without argv[0]), single-quoted for a shell script.
/// A relaunch that drops `--portable` or `--data-dir` comes back up on a
/// DIFFERENT profile than the one the user was running (issue #47), so every
/// generated relaunch forwards the original arguments byte for byte.
#[cfg(target_os = "linux")]
fn current_args_quoted() -> String {
    std::env::args()
        .skip(1)
        .map(|a| sh_quote(&a))
        .collect::<Vec<_>>()
        .join(" ")
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
/// `pid` is the process the script waits for. It is a parameter rather than
/// `std::process::id()` so the mechanics can be tested against a real child.
#[cfg(target_os = "linux")]
fn apply_update_tarball(
    data: &Path,
    archive_path: &str,
    app_dir: &str,
    version: &str,
    pid: u32,
) -> Result<String, String> {
    use std::os::unix::fs::PermissionsExt;

    let updates = data.join("updates");
    fs::create_dir_all(&updates).map_err(|e| format!("Failed to create updates dir: {e}"))?;
    let staging = updates.join(format!("staging-{version}"));
    if staging.exists() {
        fs::remove_dir_all(&staging).map_err(|e| format!("Failed to clean staging dir: {e}"))?;
    }
    fs::create_dir_all(&staging).map_err(|e| format!("Failed to create staging dir: {e}"))?;
    let staging_str = staging
        .to_str()
        .ok_or("Staging dir path is not valid UTF-8")?;

    crate::hollow_log!("[updater] Extracting {archive_path} into {staging_str}");
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

    // The release tarball packs `bundle/hollow`; a tarball someone repacked
    // from inside the folder has `hollow` at the top. Anything else is not a
    // Hollow build and must not be swapped in.
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
    let log_path = updates.join("update.log");
    let log_str = log_path.to_str().ok_or("Log path is not valid UTF-8")?;
    let script_path = updates.join("update.sh");

    crate::hollow_log!(
        "[updater] Staged {bundle_str} for {app_dir}, waiting on pid {pid} in {}",
        script_path.display()
    );
    let body = tarball_update_script(
        log_str,
        app_dir,
        bundle_str,
        staging_str,
        archive_path,
        version,
        pid,
        &current_args_quoted(),
    );
    write_shell_script(&script_path, &body)
}

/// The swap script itself.
///
/// The relaunch uses `nohup`, not `setsid`: `setsid` FORKS when the calling
/// shell is already a process group leader (which this script's shell is, it
/// was started under `setsid`), so `$!` would be the pid of a helper that
/// exits immediately and the liveness check below would roll back a perfectly
/// good update. `nohup` execs in place, so `$!` really is the new Hollow. The
/// script already runs in its own session with no controlling terminal, so
/// nothing can SIGHUP the child when the script exits.
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
         echo \"Hollow update to v{version}\" > \"$LOG\"\n\
         echo \"waiting for pid {pid} to exit\" >> \"$LOG\"\n\
         while kill -0 {pid} 2>/dev/null; do sleep 0.3; done\n\
         sleep 0.5\n\
         echo \"swapping the bundle\" >> \"$LOG\"\n\
         rm -rf \"$OLD\" >> \"$LOG\" 2>&1\n\
         if ! mv \"$APP\" \"$OLD\" >> \"$LOG\" 2>&1; then\n\
         echo \"could not move the current build aside, nothing was changed\" >> \"$LOG\"\n\
         exit 1\n\
         fi\n\
         if ! mv \"$NEW\" \"$APP\" >> \"$LOG\" 2>&1; then\n\
         echo \"could not move the new build into place, restoring the previous version\" >> \"$LOG\"\n\
         mv \"$OLD\" \"$APP\" >> \"$LOG\" 2>&1\n\
         exit 1\n\
         fi\n\
         echo \"starting the new build\" >> \"$LOG\"\n\
         nohup \"$APP/hollow\" {args_quoted} >/dev/null 2>&1 &\n\
         NEWPID=$!\n\
         sleep 8\n\
         if ! kill -0 \"$NEWPID\" 2>/dev/null; then\n\
         echo \"new build exited early, restoring previous version\" >> \"$LOG\"\n\
         rm -rf \"$APP\" >> \"$LOG\" 2>&1\n\
         mv \"$OLD\" \"$APP\" >> \"$LOG\" 2>&1\n\
         nohup \"$APP/hollow\" {args_quoted} >/dev/null 2>&1 &\n\
         exit 1\n\
         fi\n\
         rm -rf \"$OLD\" >> \"$LOG\" 2>&1\n\
         rm -rf \"$STAGING\" >> \"$LOG\" 2>&1\n\
         rm -f \"$ARCHIVE\" >> \"$LOG\" 2>&1\n\
         echo \"updated to v{version}\" >> \"$LOG\"\n\
         exit 0\n",
        log_q = sh_quote(log),
        app_q = sh_quote(app_dir),
        new_q = sh_quote(bundle),
        staging_q = sh_quote(staging),
        archive_q = sh_quote(archive),
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
    /// A system install deploys under `/var/lib/flatpak`; anything else is a
    /// per-user install. Installing into the wrong scope fails, so the scope is
    /// read off the running deployment rather than guessed.
    fn scope(&self) -> &'static str {
        if self.app_path.starts_with("/var/lib/flatpak") {
            "--system"
        } else {
            "--user"
        }
    }
}

/// Pure parser for `/.flatpak-info`, an INI file. Only the `[Instance]`
/// section counts: `app-path` decides the install scope, and `instance-id` is
/// what `flatpak ps` prints, which is how the host-side relaunch knows the old
/// instance is really gone.
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
/// The running deployment stays exactly where it is while this runs, which is
/// why the app can keep working and then restart into the new build. The
/// install is synchronous and can take a minute; the caller shows progress.
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

    crate::hollow_log!("[updater] Installing {bundle_path} on the host with {scope} (v{version})");
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
    // Installing a bundle whose commit is ALREADY deployed fails with
    // "already installed" (verified on the VM: `--or-update` does not apply to
    // bundles, it fails the same way). That is the state we wanted, so it is a
    // success as far as the user is concerned: a retry after an install that
    // worked but whose relaunch did not must still relaunch.
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

    // The bundle is deployed now, so the downloaded file is dead weight. The
    // script deletes it: this process cannot, it is about to exit.
    let script_path = data.join("updates").join("relaunch.sh");
    let body = format!(
        "#!/bin/sh\n\
         rm -f {bundle}\n\
         {recipe}",
        bundle = sh_quote(bundle_path),
        recipe = flatpak_relaunch_recipe(&info.instance_id, &current_args_quoted()),
    );
    write_shell_script(&script_path, &body)
}

/// The ONE host-side relaunch recipe, shared by the post-install relaunch and
/// by the self-restart waiter (profile switch, relay apply, device link,
/// revocation self-nuke).
///
/// It waits for our instance id to leave `flatpak ps` rather than for a pid:
/// the sandbox pid means nothing on the host. The session bus address is
/// restored because a command started through `flatpak-spawn --host` inherits
/// the sandbox environment, and `flatpak run` needs a session bus to reach the
/// user's session; the export is conditional so a machine without that socket
/// still gets a launch attempt instead of a broken address.
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
    crate::hollow_log!("[updater] Starting update script {script_path}");
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

/// Flatpak: the script has to run on the HOST, because everything inside the
/// sandbox dies with the app. This waits for `flatpak-spawn` to return, which
/// is what guarantees the host has already forked the script by the time the
/// caller exits.
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
/// Entry names are normalized `\` → `/` first: PowerShell's Compress-Archive
/// (which builds the release zips) writes backslash-separated names and marks
/// directory entries with a TRAILING backslash — treating those as files made
/// `File::create` fail with os error 267/123 on every empty dir (issue #52).
#[allow(dead_code)] // only reachable on Windows outside of tests
fn extract_zip_to(zip_path: &str, staging_dir: &std::path::Path) -> Result<(), String> {
    let zip_file = fs::File::open(zip_path)
        .map_err(|e| format!("Failed to open zip: {e}"))?;
    let mut archive = zip::ZipArchive::new(zip_file)
        .map_err(|e| format!("Failed to read zip archive: {e}"))?;

    let prefix = detect_common_prefix(&mut archive);

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read zip entry {i}: {e}"))?;

        let raw_name = entry.name().replace('\\', "/");
        let name = if let Some(ref p) = prefix {
            raw_name.strip_prefix(p.as_str()).unwrap_or(&raw_name).to_string()
        } else {
            raw_name
        };

        if name.is_empty() {
            continue;
        }
        if name.split('/').any(|part| part == "..") {
            return Err(format!("Unsafe zip entry path: {name}"));
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

fn detect_common_prefix(archive: &mut zip::ZipArchive<fs::File>) -> Option<String> {
    let mut common: Option<String> = None;
    for i in 0..archive.len() {
        let name = match archive.by_index_raw(i) {
            Ok(entry) => entry.name().replace('\\', "/"),
            Err(_) => return None,
        };
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

    /// Minimal single-entry STORED zip with an arbitrary (unsanitized) entry
    /// name. ZipWriter refuses to write traversal names, so the hostile
    /// fixture must be built by hand. CRC stays 0 — rejection happens on the
    /// NAME before any data is read.
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
        // The zip crate sanitizes traversal names on read ("..\x" → "x"), and
        // our own guard rejects any ".." that slips through — either way the
        // entry must NOT materialize outside the staging dir.
        let _ = super::extract_zip_to(zip_path.to_str().unwrap(), &staging);
        assert!(
            !tmp.join("outside.txt").exists(),
            "traversal entry escaped the staging dir"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }
}

// ── Self-restart waiter (issue #47 profile switch, relay apply, device link,
// revocation self-nuke) ─────────────────────────────────────────────────────
//
// Dart cannot restart the app by spawning a fresh copy before exiting: on
// Windows the runner's SendAppLinkToInstance() runs pre-Flutter in the child,
// finds the still-alive old window (same exe path), forwards, and the child
// exits. So a detached waiter must idle until THIS process is gone, then
// start the exe. The waiter can't be spawned from Dart either — its detached
// mode kills powershell instantly (no console, no CREATE_NO_WINDOW), and a
// detached cmd batch wedges its tasklist|find pipeline in a half-alive
// console. Rust CAN pass CREATE_NO_WINDOW, so the spawn lives here.

/// Spawn a detached, windowless waiter that idles until this process exits,
/// then relaunches the app. Call right before a self-restart `exit(0)`.
#[frb]
pub fn spawn_relaunch_waiter() -> Result<(), String> {
    // Inside a flatpak the sandbox PID namespace dies with the app and takes
    // any in-sandbox waiter with it, so the wait and the relaunch both belong
    // on the host, through the same recipe the update path uses.
    #[cfg(target_os = "linux")]
    {
        if linux_install_kind_inner() == "flatpak" {
            return spawn_flatpak_relaunch_waiter();
        }
    }
    let exe = std::env::current_exe()
        .map_err(|e| format!("current_exe failed: {e}"))?;
    let exe = exe
        .to_str()
        .ok_or("Executable path is not valid UTF-8")?
        .to_string();
    spawn_waiter(std::process::id(), &relaunch_snippet(&exe))
}

/// The platform snippet the waiter runs once the watched pid is gone.
///
/// The original argv is forwarded: a relaunch that drops `--portable` (or any
/// other data-root flag) comes back up on a DIFFERENT profile than the one
/// the user was running — alternating identities between the relaunch and
/// the next manual launch (issue #47 fallout).
fn relaunch_snippet(exe: &str) -> String {
    let args: Vec<String> = std::env::args().skip(1).collect();
    #[cfg(windows)]
    {
        // PowerShell single-quoted literals; ' escapes by doubling.
        let exe_q = exe.replace('\'', "''");
        if args.is_empty() {
            format!("Start-Process -FilePath '{exe_q}'")
        } else {
            let list = args
                .iter()
                .map(|a| format!("'{}'", a.replace('\'', "''")))
                .collect::<Vec<_>>()
                .join(",");
            format!("Start-Process -FilePath '{exe_q}' -ArgumentList {list}")
        }
    }
    #[cfg(not(windows))]
    {
        let arg_str = args
            .iter()
            .map(|a| sh_quote(a))
            .collect::<Vec<_>>()
            .join(" ");
        #[cfg(target_os = "macos")]
        {
            // Relaunch the bundle via LaunchServices when running from a .app.
            match exe.find(".app/") {
                Some(idx) => {
                    let bundle = &exe[..idx + 4];
                    if args.is_empty() {
                        format!("/usr/bin/open \"{bundle}\"")
                    } else {
                        format!("/usr/bin/open \"{bundle}\" --args {arg_str}")
                    }
                }
                None if args.is_empty() => format!("exec \"{exe}\""),
                None => format!("exec \"{exe}\" {arg_str}"),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            if args.is_empty() {
                format!("exec \"{exe}\"")
            } else {
                format!("exec \"{exe}\" {arg_str}")
            }
        }
    }
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
        flatpak_relaunch_recipe(&info.instance_id, &current_args_quoted())
    );
    let path = write_shell_script(&script_path, &body)?;
    crate::hollow_log!("[updater] Flatpak self-restart through the host script {path}");
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
    /// End-to-end mechanics: waiter watches a short-lived pid, outlives it,
    /// and runs the launch snippet. Guards the CREATE_NO_WINDOW PowerShell
    /// spawn — the Dart-side detached spawn silently killed powershell, so
    /// this MUST stay an empirical test, not a code-review assumption.
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

    /// The real `/.flatpak-info` of the installed 0.x flatpak, read out of a
    /// live sandbox on the Linux VM. Trimmed of the long `[Environment]` tail
    /// only; every section this parser walks past is intact.
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

    /// End-to-end mechanics of the tarball swap, modelled on the Windows
    /// `waiter_fires_after_watched_pid_exits`: a real child to outwait, a real
    /// tarball, the real generated script, started through the real
    /// `launch_update_script`.
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
            "9.9.9",
            watched,
        )
        .expect("generate the update script");
        launch_update_script(script).expect("start the update script");

        // Our own child, started three lines up. Reaped so the pid is really
        // gone: `kill -0` succeeds on a zombie and the script would wait forever.
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
            "9.9.9",
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
}
