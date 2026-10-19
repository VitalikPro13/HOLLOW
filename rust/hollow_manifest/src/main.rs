//! `hollow-manifest`: hashes, signs and verifies the update manifest.
//!
//! The app verifies `manifest.json.sig` (base64 Ed25519 over the exact bytes
//! of `manifest.json`) against `MANIFEST_SIGNING_PUBKEYS` in
//! `hollow_core/src/api/updater.rs`, then checks every downloaded zip against
//! the `sha256_<platform>` field of its version entry. Everything here mirrors
//! that check byte for byte; `verify` IS that check, run outside the app.
//! `feed-sign` / `feed-verify` do the same for `status.json` and `news.json`
//! under a domain-separated message (see `feeds`).

mod feeds;

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

const USAGE: &str = "\
hollow-manifest <command> [args]

  keygen --out <key-file>
      Mint the signing key (32-byte seed, hex). Prints the public key to
      paste into MANIFEST_SIGNING_PUBKEYS. Refuses to overwrite.

  fill-hashes <manifest.json> [--dir <folder>]
      For every url_windows / url_macos / url_linux / url_linux_targz in every
      version entry, write the matching sha256_windows / sha256_macos /
      sha256_linux / sha256_linux_targz field. url_linux is the Flatpak bundle
      and url_linux_targz the portable Linux tarball, so a Linux release
      carries two hashes. A file is read from --dir by its URL basename when
      present there, otherwise DOWNLOADED from the URL, so the hash is of what
      is served.

  sign <manifest.json> --key <key-file> [--out <manifest.json.sig>]
      Check the manifest (three-part versions, a bounded `build`, a boolean
      `critical`, no repeated version and build, and versions[0] = the full
      `latest` release with every download URL and hash, since apps up to
      0.12.1 and the website read that entry), then write the base64 Ed25519
      signature over its exact bytes.

  verify (<manifest.json> <manifest.json.sig> | --url <manifest-url>) --pubkey <hex>
      Replay the app's check. Exit 0 only when the signature verifies.

  feed-sign <feed.json> --feed status|news --key <key-file> [--out <sig>] [--stamp [--live <url>]]
      Check the feed's shape (status: `issued` no more than an hour ahead
      of this clock, and every notice's id, level, expires and targeting)
      and size, then sign it for that feed name. --stamp first rewrites
      status.json's `issued` to the highest of now, the file's issued + 1
      and the live copy's issued + 1 (--live), so a re-served older copy
      cannot replace it in apps that saw this one.

  feed-verify (<feed.json> <sig> | --url <feed-url>) --feed status|news --pubkey <hex>
      Replay the app's feed check. Exit 0 only when the signature verifies
      for that feed name.
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("keygen") => keygen(&args[1..]),
        Some("fill-hashes") => fill_hashes(&args[1..]),
        Some("sign") => sign(&args[1..]),
        Some("verify") => verify(&args[1..]),
        Some("feed-sign") => feed_sign(&args[1..]),
        Some("feed-verify") => feed_verify(&args[1..]),
        _ => Err(USAGE.to_string()),
    };
    if let Err(e) = result {
        eprintln!("{e}");
        std::process::exit(1);
    }
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn positional(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut skip = false;
    for a in args {
        if skip {
            skip = false;
            continue;
        }
        if a.starts_with("--") {
            skip = true;
            continue;
        }
        out.push(a.clone());
    }
    out
}

fn keygen(args: &[String]) -> Result<(), String> {
    let out = flag(args, "--out").ok_or("keygen needs --out <key-file>")?;
    let path = PathBuf::from(&out);
    if path.exists() {
        return Err(format!("{out} exists; refusing to overwrite a signing key"));
    }
    let mut seed = [0u8; 32];
    getrandom::fill(&mut seed).map_err(|e| format!("randomness unavailable: {e}"))?;
    let key = SigningKey::from_bytes(&seed);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    write_private(&path, &hex::encode(seed))?;
    println!("private key: {}", path.display());
    println!("public key:  {}", hex::encode(key.verifying_key().to_bytes()));
    println!(
        "Paste the public key into MANIFEST_SIGNING_PUBKEYS (updater.rs) and back the \
         private key up: without it no future manifest can be signed, and clients \
         cannot be told to update."
    );
    Ok(())
}

#[cfg(unix)]
fn write_private(path: &Path, hex_seed: &str) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("create {}: {e}", path.display()))?;
    std::io::Write::write_all(&mut f, format!("{hex_seed}\n").as_bytes())
        .map_err(|e| format!("write {}: {e}", path.display()))
}

#[cfg(not(unix))]
fn write_private(path: &Path, hex_seed: &str) -> Result<(), String> {
    fs::write(path, format!("{hex_seed}\n")).map_err(|e| format!("write {}: {e}", path.display()))
}

fn load_key(path: &str) -> Result<SigningKey, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("read key {path}: {e}"))?;
    let seed = hex::decode(text.trim()).map_err(|e| format!("key {path} is not hex: {e}"))?;
    let seed: [u8; 32] = seed
        .try_into()
        .map_err(|_| format!("key {path} must be 32 bytes"))?;
    Ok(SigningKey::from_bytes(&seed))
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn fetch(url: &str) -> Result<Vec<u8>, String> {
    if !url.starts_with("https://") {
        return Err(format!("refusing non-https URL {url}"));
    }
    let resp = ureq::get(url)
        .set("Cache-Control", "no-cache")
        .call()
        .map_err(|e| format!("GET {url}: {e}"))?;
    let mut buf = Vec::new();
    resp.into_reader()
        .read_to_end(&mut buf)
        .map_err(|e| format!("read {url}: {e}"))?;
    Ok(buf)
}

fn fill_hashes(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let manifest_path = pos.first().ok_or("fill-hashes needs <manifest.json>")?;
    let dir = flag(args, "--dir").map(PathBuf::from);
    let text =
        fs::read_to_string(manifest_path).map_err(|e| format!("read {manifest_path}: {e}"))?;
    let mut root: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("{manifest_path} is not JSON: {e}"))?;
    let versions = root
        .get_mut("versions")
        .and_then(|v| v.as_array_mut())
        .ok_or("manifest has no versions[]")?;
    let mut written = 0;
    for entry in versions.iter_mut() {
        let obj = entry
            .as_object_mut()
            .ok_or("versions[] entry is not an object")?;
        // "linux" is the Flatpak bundle, "linux_targz" the portable tarball:
        // one Linux release ships both, and each needs its own hash.
        for platform in ["windows", "macos", "linux", "linux_targz"] {
            let Some(url) = obj
                .get(&format!("url_{platform}"))
                .and_then(|u| u.as_str())
            else {
                continue;
            };
            if url.is_empty() {
                continue;
            }
            let url = url.to_string();
            let basename = url.rsplit('/').next().unwrap_or("").to_string();
            let local = dir
                .as_ref()
                .map(|d| d.join(&basename))
                .filter(|p| p.is_file());
            let bytes = match local {
                Some(p) => {
                    eprintln!("hashing {} (local)", p.display());
                    fs::read(&p).map_err(|e| format!("read {}: {e}", p.display()))?
                }
                None => {
                    eprintln!("hashing {url} (download)");
                    fetch(&url)?
                }
            };
            let digest = sha256_hex(&bytes);
            eprintln!("  {basename}: {digest} ({} bytes)", bytes.len());
            obj.insert(
                format!("sha256_{platform}"),
                serde_json::Value::String(digest),
            );
            written += 1;
        }
    }
    let out = serde_json::to_string_pretty(&root).map_err(|e| format!("serialise: {e}"))?;
    fs::write(manifest_path, format!("{out}\n"))
        .map_err(|e| format!("write {manifest_path}: {e}"))?;
    println!("wrote {written} sha256 field(s) to {manifest_path}");
    Ok(())
}

fn sign(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let manifest_path = pos.first().ok_or("sign needs <manifest.json>")?;
    let key_path = flag(args, "--key").ok_or("sign needs --key <key-file>")?;
    let out = flag(args, "--out").unwrap_or_else(|| format!("{manifest_path}.sig"));
    let bytes = fs::read(manifest_path).map_err(|e| format!("read {manifest_path}: {e}"))?;
    let root = serde_json::from_slice::<serde_json::Value>(&bytes)
        .map_err(|e| format!("{manifest_path} is not JSON, refusing to sign it: {e}"))?;
    feeds::check_size("manifest", bytes.len()).map_err(|e| format!("{manifest_path}: {e}; not signing"))?;
    feeds::check_manifest(&root)
        .map_err(|e| format!("{manifest_path}: {e}; not signing"))?;
    let key = load_key(&key_path)?;
    let sig = key.sign(&bytes);
    fs::write(&out, format!("{}\n", B64.encode(sig.to_bytes())))
        .map_err(|e| format!("write {out}: {e}"))?;
    println!("signed {} bytes of {manifest_path} -> {out}", bytes.len());
    println!("public key: {}", hex::encode(key.verifying_key().to_bytes()));
    Ok(())
}

/// The app's check, byte for byte: base64 signature text, exact manifest bytes.
pub fn verify_bytes(manifest: &[u8], sig_text: &str, pubkey_hex: &str) -> Result<(), String> {
    let pk = hex::decode(pubkey_hex.trim()).map_err(|e| format!("pubkey is not hex: {e}"))?;
    let pk: [u8; 32] = pk
        .try_into()
        .map_err(|_| "pubkey must be 32 bytes".to_string())?;
    let vk = VerifyingKey::from_bytes(&pk).map_err(|e| format!("pubkey invalid: {e}"))?;
    let sig = B64
        .decode(sig_text.trim())
        .map_err(|e| format!("signature is not base64: {e}"))?;
    let sig = Signature::from_slice(&sig).map_err(|e| format!("signature malformed: {e}"))?;
    // verify_strict, exactly like the app, so this tool never says OK to a
    // signature the app would refuse.
    vk.verify_strict(manifest, &sig)
        .map_err(|_| "signature does not verify".to_string())
}

fn verify(args: &[String]) -> Result<(), String> {
    let pubkey = flag(args, "--pubkey").ok_or("verify needs --pubkey <hex>")?;
    let (manifest, sig_text, label) = if let Some(url) = flag(args, "--url") {
        // Same cache buster on both files as the app uses: without it the CDN
        // can pair a fresh manifest with a still-cached old signature.
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let sig_url = format!("{url}.sig?t={t}");
        let manifest_url = format!("{url}?t={t}");
        (
            fetch(&manifest_url)?,
            String::from_utf8_lossy(&fetch(&sig_url)?).into_owned(),
            url,
        )
    } else {
        let pos = positional(args);
        let (m, s) = match (pos.first(), pos.get(1)) {
            (Some(m), Some(s)) => (m.clone(), s.clone()),
            _ => return Err("verify needs <manifest.json> <manifest.json.sig> or --url".into()),
        };
        let manifest = fs::read(&m).map_err(|e| format!("read {m}: {e}"))?;
        let sig = fs::read_to_string(&s).map_err(|e| format!("read {s}: {e}"))?;
        (manifest, sig, m)
    };
    verify_bytes(&manifest, &sig_text, &pubkey)?;
    let root: serde_json::Value =
        serde_json::from_slice(&manifest).map_err(|e| format!("manifest is not JSON: {e}"))?;
    let latest = root.get("latest").and_then(|v| v.as_str()).unwrap_or("?");
    println!(
        "OK: {label} verifies ({} bytes, latest {latest})",
        manifest.len()
    );
    Ok(())
}

/// The app's feed check: the signature covers `feeds::feed_message(feed, bytes)`.
pub fn verify_feed_bytes(feed: &str, bytes: &[u8], sig_text: &str, pubkey_hex: &str) -> Result<(), String> {
    verify_bytes(&feeds::feed_message(feed, bytes)?, sig_text, pubkey_hex)
}

fn feed_name(args: &[String]) -> Result<String, String> {
    let feed = flag(args, "--feed").ok_or("needs --feed status|news")?;
    feeds::feed_message(&feed, b"")?;
    Ok(feed)
}

/// The stamp `--stamp` writes: never below what this file or the live copy
/// already carries, since apps that saw either keep it and hide anything older.
fn next_issued(now: u64, file: Option<u64>, live: Option<u64>) -> u64 {
    let past = |n: Option<u64>| n.map_or(0, |n| n.saturating_add(1));
    now.max(past(file)).max(past(live))
}

/// `issued` of the copy apps see now: an https URL (cache-busted), or a local
/// file for tests. Missing (404, no file) = none; any other failure refuses, as
/// the stamp could then fall below what apps hold.
fn live_issued(source: &str) -> Result<Option<u64>, String> {
    let bytes = if source.starts_with("https://") {
        let t = feeds::unix_now()?;
        match ureq::get(&format!("{source}?t={t}")).set("Cache-Control", "no-cache").call() {
            Ok(resp) => {
                let mut buf = Vec::new();
                resp.into_reader()
                    .take(feeds::STATUS_CAP_BYTES as u64 + 1)
                    .read_to_end(&mut buf)
                    .map_err(|e| format!("read {source}: {e}"))?;
                buf
            }
            Err(ureq::Error::Status(404, _)) => return Ok(None),
            Err(e) => return Err(format!("GET {source}: {e}; cannot tell what apps hold, not stamping")),
        }
    } else {
        match fs::read(source) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("read {source}: {e}")),
        }
    };
    Ok(serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .and_then(|v| v.get("issued").and_then(serde_json::Value::as_u64)))
}

fn feed_sign(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let path = pos.first().ok_or("feed-sign needs <feed.json>")?.clone();
    let feed = feed_name(args)?;
    let key_path = flag(args, "--key").ok_or("feed-sign needs --key <key-file>")?;
    let out = flag(args, "--out").unwrap_or_else(|| format!("{path}.sig"));
    if args.iter().any(|a| a == "--stamp") {
        if feed != "status" {
            return Err("--stamp applies to the status feed only".into());
        }
        let text = fs::read_to_string(&path).map_err(|e| format!("read {path}: {e}"))?;
        let mut root: serde_json::Value =
            serde_json::from_str(&text).map_err(|e| format!("{path} is not JSON: {e}"))?;
        let now = feeds::unix_now()?;
        let live = match flag(args, "--live") {
            Some(src) => live_issued(&src)?,
            None => None,
        };
        let file = root.get("issued").and_then(serde_json::Value::as_u64);
        let issued = next_issued(now, file, live);
        if issued > now + feeds::MAX_ISSUED_AHEAD_SECS {
            return Err(format!(
                "{path}: the next stamp would be {issued}, over {} s past this clock ({now}); fix the clock or the stamp by hand, not signing",
                feeds::MAX_ISSUED_AHEAD_SECS
            ));
        }
        root.as_object_mut()
            .ok_or("status.json must be a JSON object")?
            .insert("issued".into(), serde_json::Value::from(issued));
        let pretty = serde_json::to_string_pretty(&root).map_err(|e| format!("serialise: {e}"))?;
        fs::write(&path, format!("{pretty}\n")).map_err(|e| format!("write {path}: {e}"))?;
        println!("stamped issued = {issued}");
    }
    let bytes = fs::read(&path).map_err(|e| format!("read {path}: {e}"))?;
    let root: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("{path} is not JSON, refusing to sign it: {e}"))?;
    feeds::check_size(&feed, bytes.len()).map_err(|e| format!("{path}: {e}; not signing"))?;
    for warning in feeds::check_feed(&feed, &root).map_err(|e| format!("{path}: {e}; not signing"))? {
        eprintln!("warning: {warning}");
    }
    let key = load_key(&key_path)?;
    let sig = key.sign(&feeds::feed_message(&feed, &bytes)?);
    fs::write(&out, format!("{}\n", B64.encode(sig.to_bytes()))).map_err(|e| format!("write {out}: {e}"))?;
    println!("signed {} bytes of {path} as the {feed} feed -> {out}", bytes.len());
    println!("public key: {}", hex::encode(key.verifying_key().to_bytes()));
    Ok(())
}

fn feed_verify(args: &[String]) -> Result<(), String> {
    let feed = feed_name(args)?;
    let pubkey = flag(args, "--pubkey").ok_or("feed-verify needs --pubkey <hex>")?;
    let (bytes, sig_text, label) = if let Some(url) = flag(args, "--url") {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        (
            fetch(&format!("{url}?t={t}"))?,
            String::from_utf8_lossy(&fetch(&format!("{url}.sig?t={t}"))?).into_owned(),
            url,
        )
    } else {
        let pos = positional(args);
        let (f, s) = match (pos.first(), pos.get(1)) {
            (Some(f), Some(s)) => (f.clone(), s.clone()),
            _ => return Err("feed-verify needs <feed.json> <sig> or --url".into()),
        };
        let bytes = fs::read(&f).map_err(|e| format!("read {f}: {e}"))?;
        let sig = fs::read_to_string(&s).map_err(|e| format!("read {s}: {e}"))?;
        (bytes, sig, f)
    };
    verify_feed_bytes(&feed, &bytes, &sig_text, &pubkey)?;
    let root: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("{label} is not JSON: {e}"))?;
    let detail = match feed.as_str() {
        "status" => format!(
            "issued {}, {} notice(s)",
            root.get("issued").and_then(|v| v.as_u64()).unwrap_or(0),
            root.get("notices").and_then(|v| v.as_array()).map_or(0, Vec::len)
        ),
        _ => format!("{} post(s)", root.as_array().map_or(0, Vec::len)),
    };
    println!("OK: {label} verifies as the {feed} feed ({} bytes, {detail})", bytes.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pins the feed signature scheme; hollow_core's `feed_signature_kat` holds the
    /// same vector, so the app and this tool cannot drift apart.
    #[test]
    fn feed_signature_kat() {
        let key = SigningKey::from_bytes(&[9u8; 32]);
        let body = br#"{"issued":1,"notices":[]}"#;
        let sig = B64.encode(key.sign(&feeds::feed_message("status", body).unwrap()).to_bytes());
        assert_eq!(sig, FEED_KAT_SIG);
        let pk = hex::encode(key.verifying_key().to_bytes());
        assert!(verify_feed_bytes("status", body, FEED_KAT_SIG, &pk).is_ok());
    }

    const FEED_KAT_SIG: &str = "09MlGHO/bj7y1tDOrqfnwAHWmrTD14eEQGLMvL+XQCDpy3n3uf2J90wVOtu8nwzPYjLvx2doj3Fo/Rkq5QK1CA==";

    #[test]
    fn a_feed_signature_never_passes_as_the_manifest_or_the_other_feed() {
        let key = SigningKey::from_bytes(&[7u8; 32]);
        let pk = hex::encode(key.verifying_key().to_bytes());
        let body = br#"{"latest":"1.0.0","versions":[]}"#;
        let as_status = B64.encode(key.sign(&feeds::feed_message("status", body).unwrap()).to_bytes());
        let as_manifest = B64.encode(key.sign(body).to_bytes());
        assert!(verify_feed_bytes("status", body, &as_status, &pk).is_ok());
        assert!(verify_feed_bytes("news", body, &as_status, &pk).is_err());
        assert!(verify_bytes(body, &as_status, &pk).is_err());
        assert!(verify_feed_bytes("status", body, &as_manifest, &pk).is_err());
        assert!(verify_feed_bytes("news", body, &as_manifest, &pk).is_err());
    }

    #[test]
    fn sign_then_verify_roundtrip_and_tamper() {
        let key = SigningKey::from_bytes(&[7u8; 32]);
        let pk = hex::encode(key.verifying_key().to_bytes());
        let manifest = br#"{"latest":"1.0.0","versions":[]}"#;
        let sig = B64.encode(key.sign(manifest).to_bytes());
        assert!(verify_bytes(manifest, &sig, &pk).is_ok());
        let mut tampered = manifest.to_vec();
        tampered[10] ^= 1;
        assert!(verify_bytes(&tampered, &sig, &pk).is_err());
        let other = hex::encode(
            SigningKey::from_bytes(&[8u8; 32])
                .verifying_key()
                .to_bytes(),
        );
        assert!(verify_bytes(manifest, &sig, &other).is_err());
    }

    fn unix_now() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
    }

    fn scratch(name: &str) -> PathBuf {
        let base = std::env::var_os("HOLLOW_TEST_TMP").map_or_else(std::env::temp_dir, PathBuf::from);
        let dir = base.join(format!("hollow-manifest-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sign_status(dir: &Path, body: &str, extra: &[&str]) -> Result<u64, String> {
        let key = dir.join("key");
        if !key.exists() {
            keygen(&["--out".into(), key.to_str().unwrap().into()]).unwrap();
        }
        let path = dir.join("status.json");
        fs::write(&path, body).unwrap();
        let mut args: Vec<String> = vec![
            path.to_str().unwrap().into(), "--feed".into(), "status".into(),
            "--key".into(), key.to_str().unwrap().into(),
        ];
        args.extend(extra.iter().map(|s| s.to_string()));
        feed_sign(&args)?;
        let after: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        Ok(after["issued"].as_u64().unwrap())
    }

    /// --stamp must never move `issued` backwards: apps that saw the higher
    /// stamp would hide the new feed while the script reports the live pair OK.
    #[test]
    fn review_stamp_never_lowers_issued() {
        let dir = scratch("stamp");
        let ahead = unix_now() + 600;
        let issued = sign_status(&dir, &format!(r#"{{"issued": {ahead}, "notices": []}}"#), &["--stamp"]);
        let _ = fs::remove_dir_all(&dir);
        assert!(issued.unwrap() > ahead, "--stamp did not move past the file's issued {ahead}");
    }

    /// The live copy is what apps saw last; the next stamp moves past it even
    /// when the local file is older.
    #[test]
    fn stamp_moves_past_the_live_copy() {
        let dir = scratch("live");
        let live_at = unix_now() + 900;
        let live = dir.join("live.json");
        fs::write(&live, format!(r#"{{"issued": {live_at}, "notices": []}}"#)).unwrap();
        let issued = sign_status(
            &dir,
            r#"{"issued": 5, "notices": []}"#,
            &["--stamp", "--live", live.to_str().unwrap()],
        );
        let absent = sign_status(
            &dir,
            r#"{"issued": 5, "notices": []}"#,
            &["--stamp", "--live", dir.join("missing.json").to_str().unwrap()],
        );
        let _ = fs::remove_dir_all(&dir);
        assert!(issued.unwrap() > live_at, "stamp stayed at or below the live copy");
        let absent = absent.unwrap();
        assert!(absent >= unix_now() - 60 && absent < live_at, "no live copy: stamp is now, got {absent}");
    }

    /// A stamp that would have to sit past the window is refused, never lowered.
    #[test]
    fn stamp_refuses_rather_than_lowering_a_future_stamp() {
        let dir = scratch("future");
        let far = unix_now() + 10 * 86_400;
        let r = sign_status(&dir, &format!(r#"{{"issued": {far}, "notices": []}}"#), &["--stamp"]);
        let kept: serde_json::Value = serde_json::from_slice(&fs::read(dir.join("status.json")).unwrap()).unwrap();
        let signed = dir.join("status.json.sig").exists();
        let _ = fs::remove_dir_all(&dir);
        assert!(r.is_err(), "a stamp ten days ahead was signed");
        assert_eq!(kept["issued"].as_u64(), Some(far), "the file's stamp was rewritten");
        assert!(!signed, "a signature was written");
    }

    /// The app drops a status feed over its cap unread, so the signer never signs one.
    #[test]
    fn feed_sign_refuses_a_status_file_over_the_app_cap() {
        let dir = scratch("cap");
        let body = format!(r#"{{"issued": {}, "notices": []}}{}"#, unix_now(), " ".repeat(feeds::STATUS_CAP_BYTES));
        let r = sign_status(&dir, &body, &[]);
        let signed = dir.join("status.json.sig").exists();
        let _ = fs::remove_dir_all(&dir);
        assert!(r.is_err(), "a status file over the cap was signed");
        assert!(!signed, "a signature was written");
    }

    #[test]
    fn next_issued_is_the_highest_of_now_file_and_live() {
        assert_eq!(next_issued(100, None, None), 100);
        assert_eq!(next_issued(100, Some(50), Some(60)), 100);
        assert_eq!(next_issued(100, Some(150), None), 151);
        assert_eq!(next_issued(100, Some(150), Some(200)), 201);
        assert_eq!(next_issued(100, None, Some(100)), 101);
    }
}
