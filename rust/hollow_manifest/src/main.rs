//! `hollow-manifest`: hashes, signs and verifies the update manifest.
//!
//! The app verifies `manifest.json.sig` (base64 Ed25519 over the exact bytes
//! of `manifest.json`) against `MANIFEST_SIGNING_PUBKEYS` in
//! `hollow_core/src/api/updater.rs`, then checks every downloaded zip against
//! the `sha256_<platform>` field of its version entry. Everything here mirrors
//! that check byte for byte; `verify` IS that check, run outside the app.
//! `feed-sign` / `feed-verify` do the same for `status.json`, `news.json` and
//! `relay.json` (the self-hosted relay's installer feed) under a
//! domain-separated message (see `feeds`).

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

  feed-sign <feed.json> --feed status|news|relay --key <key-file> [--out <sig>] [--stamp] [--live <url>]
            [--tarballs <folder>] [--allow-downgrade]
      Check the feed's shape (status: `issued` no more than an hour ahead
      of this clock, and every notice's id, level, expires and targeting;
      relay: version, build, issued, commit and every tarball's URL, hash
      and size) and size, then sign it for that feed name. --stamp (status,
      relay) first rewrites `issued` to the highest of now, the file's
      issued + 1 and the live copy's issued + 1 (--live), so a re-served
      older copy cannot replace it for anyone who saw this one.
      relay: every tarball must sit in --tarballs (default: the feed's
      folder) with the feed's size and sha256, pass the installer's
      checks and carry the setup's own copy; with --live, a version and build below the live feed's is
      refused unless --allow-downgrade.

  feed-verify (<feed.json> <sig> | --url <feed-url>) --feed status|news|relay --pubkey <hex>
      Replay the app's (or the relay installer's) feed check. Exit 0 only
      when the signature verifies for that feed name.

  relay-feed --dir <folder> --version <x.y.z> [--build <n>] [--out <relay.json>]
      Write relay.json (issued 0, for feed-sign --stamp) from the relay
      tarballs in <folder> named hollow-relay-<x.y.z>[-b<n>]-linux-<arch>.tar.gz:
      URL, sha256 and size per machine, and the commit their VERSION names.
      Each tarball must pass the installer's checks and carry the setup's
      own copy under setup/. x86_64 is required.

  relay-check-live <relay.json>
      Download every tarball relay.json names (read up to the installer's
      cap and no further), compare its size and sha256, and open it with
      the installer's checks, so a feed is never published ahead of its
      files.

  relay-floor <relay.json> <release_feed.sh>
      Raise the floors baked into the installer's library (_HF_MIN_ISSUED,
      _HF_MIN_VERSION, _HF_MIN_BUILD) to the signed relay.json just made
      live, so a later checkout never accepts an older feed.
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
        Some("relay-feed") => relay_feed(&args[1..]),
        Some("relay-check-live") => relay_check_live(&args[1..]),
        Some("relay-floor") => relay_floor(&args[1..]),
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

/// Reads at most `cap` bytes; a body that goes on past it is refused, so a
/// host that streams forever cannot fill memory.
fn read_capped(reader: impl Read, cap: u64, what: &str) -> Result<Vec<u8>, String> {
    let mut buf = Vec::new();
    reader.take(cap + 1).read_to_end(&mut buf).map_err(|e| format!("read {what}: {e}"))?;
    if buf.len() as u64 > cap {
        return Err(format!("{what} is larger than {cap} bytes"));
    }
    Ok(buf)
}

fn fetch_capped(url: &str, cap: u64) -> Result<Vec<u8>, String> {
    if !url.starts_with("https://") {
        return Err(format!("refusing non-https URL {url}"));
    }
    let resp = ureq::get(url)
        .set("Cache-Control", "no-cache")
        .call()
        .map_err(|e| format!("GET {url}: {e}"))?;
    read_capped(resp.into_reader(), cap, url)
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
    let feed = flag(args, "--feed").ok_or("needs --feed status|news|relay")?;
    feeds::feed_message(&feed, b"")?;
    Ok(feed)
}

/// The stamp `--stamp` writes: never below what this file or the live copy
/// already carries, since apps that saw either keep it and hide anything older.
fn next_issued(now: u64, file: Option<u64>, live: Option<u64>) -> u64 {
    let past = |n: Option<u64>| n.map_or(0, |n| n.saturating_add(1));
    now.max(past(file)).max(past(live))
}

/// The copy apps and installers see now: an https URL (cache-busted), or a
/// local file for tests. Missing (404, no file) = none; any other failure
/// refuses, as the stamp could then fall below what they hold.
fn live_feed(feed: &str, source: &str) -> Result<Option<Vec<u8>>, String> {
    let cap = match feed {
        "relay" => feeds::RELAY_CAP_BYTES,
        _ => feeds::STATUS_CAP_BYTES,
    };
    let bytes = if source.starts_with("https://") {
        let t = feeds::unix_now()?;
        match ureq::get(&format!("{source}?t={t}")).set("Cache-Control", "no-cache").call() {
            Ok(resp) => {
                let mut buf = Vec::new();
                resp.into_reader()
                    .take(cap as u64 + 1)
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
    Ok(Some(bytes))
}

/// relay: each tarball the feed names, found by its file name in `dir`, is the
/// one the feed describes and passes the installer's checks.
fn check_relay_tarballs(root: &serde_json::Value, dir: &Path) -> Result<(), String> {
    let version = root["version"].as_str().unwrap_or_default();
    let build = root["build"].as_u64().unwrap_or_default();
    let commit = root["commit"].as_str().unwrap_or_default();
    let artifacts = root["artifacts"].as_object().ok_or("relay.json has no artifacts")?;
    for (arch, a) in artifacts {
        let url = a["url"].as_str().unwrap_or_default();
        let name = url.rsplit('/').next().unwrap_or_default();
        let path = dir.join(name);
        let bytes = fs::read(&path).map_err(|e| {
            format!("{}: {e}; feed-sign opens every tarball before signing (--tarballs <folder>)", path.display())
        })?;
        if bytes.len() as u64 != a["size"].as_u64().unwrap_or_default() || sha256_hex(&bytes) != a["sha256"].as_str().unwrap_or_default() {
            return Err(format!("{}: its size or sha256 differs from relay.json; rerun relay-feed", path.display()));
        }
        let got = release_tarball(&bytes, arch, version, build).map_err(|e| format!("{name}: {e}"))?;
        if got != commit {
            return Err(format!("{name}: VERSION names commit {got}, relay.json {commit}"));
        }
    }
    Ok(())
}

/// A tarball this signer releases: one installers accept, carrying the setup's
/// own copy so `sudo hollow-relay-setup` updates the setup with the programs.
/// Installers still take an older tarball without it; nothing new ships one.
fn release_tarball(bytes: &[u8], arch: &str, version: &str, build: u64) -> Result<String, String> {
    let t = feeds::check_relay_tarball(bytes, arch, version, build)?;
    if t.setup_files == 0 {
        return Err("carries no copy of the setup under setup/; build it with scripts/build_relay_binaries.sh".into());
    }
    Ok(t.commit)
}

fn feed_sign(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let path = pos.first().ok_or("feed-sign needs <feed.json>")?.clone();
    let feed = feed_name(args)?;
    let key_path = flag(args, "--key").ok_or("feed-sign needs --key <key-file>")?;
    let out = flag(args, "--out").unwrap_or_else(|| format!("{path}.sig"));
    let live = match flag(args, "--live") {
        Some(src) => live_feed(&feed, &src)?,
        None => None,
    };
    let live_root = live.as_deref().and_then(|b| serde_json::from_slice::<serde_json::Value>(b).ok());
    if feed == "relay" && let Some(bytes) = &live {
        let live_root = live_root.as_ref().ok_or("the live relay.json is not JSON; cannot tell what installers hold, not signing")?;
        let text = fs::read(&path).map_err(|e| format!("read {path}: {e}"))?;
        let root: serde_json::Value = serde_json::from_slice(&text).map_err(|e| format!("{path} is not JSON: {e}"))?;
        feeds::check_relay_not_older(&root, live_root, args.iter().any(|a| a == "--allow-downgrade"))
            .map_err(|e| format!("{path}: {e}; not signing ({} live bytes)", bytes.len()))?;
    }
    if args.iter().any(|a| a == "--stamp") {
        if feed != "status" && feed != "relay" {
            return Err("--stamp applies to the status and relay feeds only".into());
        }
        let text = fs::read_to_string(&path).map_err(|e| format!("read {path}: {e}"))?;
        let mut root: serde_json::Value =
            serde_json::from_str(&text).map_err(|e| format!("{path} is not JSON: {e}"))?;
        let now = feeds::unix_now()?;
        let live = live_root.as_ref().and_then(|v| v.get("issued").and_then(serde_json::Value::as_u64));
        let file = root.get("issued").and_then(serde_json::Value::as_u64);
        let issued = next_issued(now, file, live);
        if issued > now + feeds::MAX_ISSUED_AHEAD_SECS {
            return Err(format!(
                "{path}: the next stamp would be {issued}, over {} s past this clock ({now}); fix the clock or the stamp by hand, not signing",
                feeds::MAX_ISSUED_AHEAD_SECS
            ));
        }
        root.as_object_mut()
            .ok_or_else(|| format!("{path} must be a JSON object"))?
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
    if feed == "relay" {
        let dir = flag(args, "--tarballs").map_or_else(
            || Path::new(&path).parent().map_or_else(|| PathBuf::from("."), Path::to_path_buf),
            PathBuf::from,
        );
        check_relay_tarballs(&root, &dir).map_err(|e| format!("{e}; not signing"))?;
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
        "relay" => format!(
            "relay {} build {} (commit {}), issued {}, {}",
            root.get("version").and_then(|v| v.as_str()).unwrap_or("?"),
            root.get("build").and_then(|v| v.as_u64()).unwrap_or(0),
            root.get("commit").and_then(|v| v.as_str()).unwrap_or("?"),
            root.get("issued").and_then(|v| v.as_u64()).unwrap_or(0),
            root.get("artifacts")
                .and_then(|v| v.as_object())
                .map(|a| a.keys().cloned().collect::<Vec<_>>().join(", "))
                .unwrap_or_default()
        ),
        _ => format!("{} post(s)", root.as_array().map_or(0, Vec::len)),
    };
    println!("OK: {label} verifies as the {feed} feed ({} bytes, {detail})", bytes.len());
    Ok(())
}

fn relay_feed(args: &[String]) -> Result<(), String> {
    let dir = PathBuf::from(flag(args, "--dir").ok_or("relay-feed needs --dir <folder>")?);
    let version = flag(args, "--version").ok_or("relay-feed needs --version <x.y.z>")?;
    if !feeds::is_release_version(&version) {
        return Err(format!("--version {version:?} must be three numeric parts"));
    }
    let build = match flag(args, "--build") {
        None => 0,
        Some(b) => b
            .parse::<u64>()
            .ok()
            .filter(|n| *n <= feeds::MAX_BUILD)
            .ok_or_else(|| format!("--build {b:?} must be an integer from 0 to {}", feeds::MAX_BUILD))?,
    };
    let out = flag(args, "--out").map_or_else(|| dir.join("relay.json"), PathBuf::from);
    let mut artifacts = serde_json::Map::new();
    let mut commit: Option<String> = None;
    for arch in feeds::RELAY_ARCHES {
        let name = feeds::relay_tarball_name(&version, build, arch);
        let path = dir.join(&name);
        if !path.is_file() {
            eprintln!("no {name} in {}: {arch} left out", dir.display());
            continue;
        }
        let bytes = fs::read(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
        let got = release_tarball(&bytes, arch, &version, build)
            .map_err(|e| format!("{name}: {e}; not writing {}", out.display()))?;
        if commit.as_ref().is_some_and(|c| *c != got) {
            return Err(format!("{name} names commit {got}, another tarball {}; build every machine from one commit", commit.unwrap_or_default()));
        }
        commit = Some(got);
        let digest = sha256_hex(&bytes);
        eprintln!("  {name}: {digest} ({} bytes)", bytes.len());
        artifacts.insert(
            (*arch).to_string(),
            serde_json::json!({
                "url": format!("{}{name}", feeds::RELAY_RELEASE_BASE),
                "sha256": digest,
                "size": bytes.len(),
            }),
        );
    }
    if !artifacts.contains_key("linux-x86_64") {
        return Err(format!("no x86_64 tarball in {}; not writing {}", dir.display(), out.display()));
    }
    let root = serde_json::json!({
        "feed": "relay",
        "version": version,
        "build": build,
        "issued": 0,
        "commit": commit.unwrap_or_default(),
        "artifacts": artifacts,
    });
    let text = serde_json::to_string_pretty(&root).map_err(|e| format!("serialise: {e}"))?;
    fs::write(&out, format!("{text}\n")).map_err(|e| format!("write {}: {e}", out.display()))?;
    println!("wrote {} ({} machine(s)); sign it with feed-sign --feed relay --stamp", out.display(), artifacts.len());
    Ok(())
}

fn relay_check_live(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let path = pos.first().ok_or("relay-check-live needs <relay.json>")?;
    let root: serde_json::Value = serde_json::from_slice(&fs::read(path).map_err(|e| format!("read {path}: {e}"))?)
        .map_err(|e| format!("{path} is not JSON: {e}"))?;
    let artifacts = root
        .get("artifacts")
        .and_then(|a| a.as_object())
        .ok_or_else(|| format!("{path} has no artifacts"))?;
    for (arch, a) in artifacts {
        let url = a.get("url").and_then(|u| u.as_str()).ok_or_else(|| format!("{arch}: no url"))?;
        let bytes = fetch_capped(url, feeds::MAX_RELAY_TARBALL_BYTES)?;
        live_tarball_ok(&root, arch, &bytes)?;
        println!("OK: {arch} {url} ({} bytes)", bytes.len());
    }
    Ok(())
}

/// The bytes a URL serves are the tarball relay.json describes for `arch`,
/// and one an installer takes.
fn live_tarball_ok(root: &serde_json::Value, arch: &str, bytes: &[u8]) -> Result<(), String> {
    let a = &root["artifacts"][arch];
    let url = a["url"].as_str().unwrap_or_default();
    let want_hash = a["sha256"].as_str().unwrap_or_default();
    let want_size = a["size"].as_u64().unwrap_or_default();
    let got = sha256_hex(bytes);
    if bytes.len() as u64 != want_size || got != want_hash {
        return Err(format!(
            "{arch}: {url} serves {} bytes, sha256 {got}; relay.json says {want_size} bytes, {want_hash}. Upload the tarball before the feed",
            bytes.len()
        ));
    }
    let version = root["version"].as_str().unwrap_or_default();
    let build = root["build"].as_u64().unwrap_or_default();
    let commit = release_tarball(bytes, arch, version, build).map_err(|e| format!("{arch}: {url}: {e}"))?;
    if commit != root["commit"].as_str().unwrap_or_default() {
        return Err(format!("{arch}: {url} names commit {commit}, relay.json {}", root["commit"]));
    }
    Ok(())
}

/// The library's floor lines, rewritten in place; each must appear exactly once.
fn relay_floor(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let (feed, lib) = match (pos.first(), pos.get(1)) {
        (Some(f), Some(l)) => (f, l),
        _ => return Err("relay-floor needs <relay.json> <release_feed.sh>".into()),
    };
    let root: serde_json::Value = serde_json::from_slice(&fs::read(feed).map_err(|e| format!("read {feed}: {e}"))?)
        .map_err(|e| format!("{feed} is not JSON: {e}"))?;
    let issued = root["issued"].as_u64().filter(|n| *n > 0).ok_or_else(|| format!("{feed} has no issued"))?;
    let version = root["version"].as_str().filter(|v| feeds::is_release_version(v)).ok_or_else(|| format!("{feed} has no version"))?;
    let build = root["build"].as_u64().filter(|b| *b <= feeds::MAX_BUILD).ok_or_else(|| format!("{feed} has no build"))?;
    let text = fs::read_to_string(lib).map_err(|e| format!("read {lib}: {e}"))?;
    let mut out = String::with_capacity(text.len());
    let mut done = [false; 3];
    for line in text.split_inclusive('\n') {
        let (i, value) = if line.starts_with("_HF_MIN_ISSUED=") {
            (0, issued.to_string())
        } else if line.starts_with("_HF_MIN_VERSION=") {
            (1, version.to_string())
        } else if line.starts_with("_HF_MIN_BUILD=") {
            (2, build.to_string())
        } else {
            out.push_str(line);
            continue;
        };
        if done[i] {
            return Err(format!("{lib} sets a floor twice; fix it by hand"));
        }
        done[i] = true;
        let name = line.split('=').next().unwrap_or_default();
        out.push_str(&format!("{name}={value}\n"));
    }
    if done != [true; 3] {
        return Err(format!("{lib} lacks _HF_MIN_ISSUED, _HF_MIN_VERSION or _HF_MIN_BUILD"));
    }
    fs::write(lib, out).map_err(|e| format!("write {lib}: {e}"))?;
    println!("{lib}: floors now issued {issued}, version {version} build {build}; commit it with {feed}");
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

    /// Pins the relay feed's signed message; relay-uws/test/release_feed holds the
    /// same vector, so the installer's openssl check and this signer cannot drift.
    #[test]
    fn relay_feed_signature_kat() {
        let key = SigningKey::from_bytes(&[9u8; 32]);
        let sig = B64.encode(key.sign(&feeds::feed_message("relay", RELAY_KAT_BODY).unwrap()).to_bytes());
        assert_eq!(sig, RELAY_KAT_SIG);
        assert_eq!(hex::encode(key.verifying_key().to_bytes()), RELAY_KAT_PUBKEY);
        assert!(verify_feed_bytes("relay", RELAY_KAT_BODY, RELAY_KAT_SIG, RELAY_KAT_PUBKEY).is_ok());
    }

    const RELAY_KAT_BODY: &[u8] = br#"{"feed":"relay","issued":1}"#;
    const RELAY_KAT_PUBKEY: &str = "fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618";
    const RELAY_KAT_SIG: &str = "cGsGP+rCzQDH24xftW/HWjMdNr5odVcpCUfNCv6WxngahE4jfW74Ltcw0MZvEqAQ41dWumAY57A2/D+d6bibDQ==";

    /// A status, news or manifest signature over relay.json's exact bytes must
    /// never pass as the relay feed, nor the other way round.
    #[test]
    fn no_other_signature_passes_as_the_relay_feed() {
        let key = SigningKey::from_bytes(&[7u8; 32]);
        let pk = hex::encode(key.verifying_key().to_bytes());
        let body = br#"{"feed":"relay","version":"0.12.2"}"#;
        let as_relay = B64.encode(key.sign(&feeds::feed_message("relay", body).unwrap()).to_bytes());
        assert!(verify_feed_bytes("relay", body, &as_relay, &pk).is_ok());
        for other in ["status", "news"] {
            let sig = B64.encode(key.sign(&feeds::feed_message(other, body).unwrap()).to_bytes());
            assert!(verify_feed_bytes("relay", body, &sig, &pk).is_err(), "{other} passed as relay");
            assert!(verify_feed_bytes(other, body, &as_relay, &pk).is_err(), "relay passed as {other}");
        }
        assert!(verify_feed_bytes("relay", body, &B64.encode(key.sign(body).to_bytes()), &pk).is_err());
        assert!(verify_bytes(body, &as_relay, &pk).is_err());
    }

    pub(crate) const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";

    /// One tar member: raw name bytes, type, body and link target.
    pub(crate) struct Member {
        pub name: Vec<u8>,
        pub kind: tar::EntryType,
        pub body: Vec<u8>,
        pub link: Option<&'static str>,
        pub mode: u32,
    }

    pub(crate) fn file(name: &str, body: Vec<u8>) -> Member {
        Member { name: name.as_bytes().to_vec(), kind: tar::EntryType::Regular, body, link: None, mode: 0o755 }
    }

    /// A file of the setup's copy, 0644 like the build packs it.
    pub(crate) fn setup_file(name: &str) -> Member {
        Member { mode: 0o644, ..file(name, format!("# {name}\n").into_bytes()) }
    }

    pub(crate) const SETUP: [&str; 11] = [
        "setup/deploy/coturn-port-lock.conf", "setup/deploy/hollow-turn-port-lock-refresh.service",
        "setup/deploy/hollow-turn-port-lock-refresh.timer", "setup/deploy/hollow-turn-port-lock.service",
        "setup/deploy/lib/common.sh", "setup/deploy/lib/release_feed.sh", "setup/deploy/turn-port-lock.sh", "setup/install.sh",
        "setup/push-sidecar/index.js", "setup/push-sidecar/package-lock.json", "setup/push-sidecar/package.json",
    ];

    /// A gzip tar written header by header, so names like `./VERSION` stay as given.
    pub(crate) fn tar_gz(members: Vec<Member>) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        for m in members {
            let mut h = tar::Header::new_ustar();
            h.as_ustar_mut().unwrap().name[..m.name.len()].copy_from_slice(&m.name);
            h.set_entry_type(m.kind);
            h.set_mode(m.mode);
            h.set_size(m.body.len() as u64);
            if let Some(l) = m.link {
                h.set_link_name(l).unwrap();
            }
            h.set_cksum();
            builder.append(&h, m.body.as_slice()).unwrap();
        }
        let raw = builder.into_inner().unwrap();
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        std::io::Write::write_all(&mut gz, &raw).unwrap();
        gz.finish().unwrap()
    }

    pub(crate) fn elf(arch: &str) -> Vec<u8> {
        let machine = if arch == "linux-aarch64" { 0xb7 } else { 0x3e };
        let mut b = vec![0x7f, b'E', b'L', b'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, machine, 0];
        b.extend_from_slice(&[0x55; 64]);
        b
    }

    pub(crate) fn good_members(arch: &str, version: &str, build: u64) -> Vec<Member> {
        vec![
            file("VERSION", feeds::relay_version_marker(version, build, COMMIT).into_bytes()),
            file("hollow-forwarder", elf(arch)),
            file("hollow-relay", elf(arch)),
        ]
        .into_iter()
        .chain(SETUP.iter().map(|n| match *n {
            "setup/install.sh" | "setup/deploy/turn-port-lock.sh" => Member { mode: 0o755, ..setup_file(n) },
            _ => setup_file(n),
        }))
        .collect()
    }

    pub(crate) fn good_tarball(arch: &str, version: &str, build: u64) -> Vec<u8> {
        tar_gz(good_members(arch, version, build))
    }

    fn write_tarball(dir: &Path, name: &str, bytes: &[u8]) {
        fs::write(dir.join(name), bytes).unwrap();
    }

    fn relay_feed_args(dir: &Path, extra: &[&str]) -> Vec<String> {
        let mut a: Vec<String> = vec!["--dir".into(), dir.to_str().unwrap().into(), "--version".into(), "0.12.2".into()];
        a.extend(extra.iter().map(|s| s.to_string()));
        a
    }

    fn sign_relay(dir: &Path, extra: &[&str]) -> Result<(), String> {
        let key = dir.join("key");
        if !key.exists() {
            keygen(&["--out".into(), key.to_str().unwrap().into()]).unwrap();
        }
        let mut args: Vec<String> = vec![
            dir.join("relay.json").to_str().unwrap().into(), "--feed".into(), "relay".into(),
            "--key".into(), key.to_str().unwrap().into(),
        ];
        args.extend(extra.iter().map(|s| s.to_string()));
        feed_sign(&args)
    }

    /// relay-feed hashes the tarballs it finds, and the stamped result is a feed
    /// the signer accepts and verifies as the relay feed.
    #[test]
    fn relay_feed_writes_what_the_tarballs_hash_to_and_signs() {
        let dir = scratch("relayfeed");
        let x86 = good_tarball("linux-x86_64", "0.12.2", 1);
        let arm = good_tarball("linux-aarch64", "0.12.2", 1);
        write_tarball(&dir, "hollow-relay-0.12.2-b1-linux-x86_64.tar.gz", &x86);
        write_tarball(&dir, "hollow-relay-0.12.2-b1-linux-aarch64.tar.gz", &arm);
        relay_feed(&relay_feed_args(&dir, &["--build", "1"])).unwrap();
        let path = dir.join("relay.json");
        let feed: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let unstamped = sign_relay(&dir, &[]);
        let signed = sign_relay(&dir, &["--stamp"]);
        let stamped: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let pk = hex::encode(load_key(dir.join("key").to_str().unwrap()).unwrap().verifying_key().to_bytes());
        let verified = verify_feed_bytes("relay", &fs::read(&path).unwrap(),
            &fs::read_to_string(dir.join("relay.json.sig")).unwrap(), &pk);
        let _ = fs::remove_dir_all(&dir);
        let entry = &feed["artifacts"]["linux-x86_64"];
        assert_eq!(entry["sha256"], sha256_hex(&x86));
        assert_eq!(entry["size"], x86.len());
        assert_eq!(entry["url"], "https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-b1-linux-x86_64.tar.gz");
        assert_eq!(feed["artifacts"]["linux-aarch64"]["size"], arm.len());
        assert_eq!(feed["build"], 1);
        assert_eq!(feed["commit"], COMMIT);
        assert!(unstamped.is_err(), "a feed with issued 0 was signed");
        signed.unwrap();
        assert!(stamped["issued"].as_u64().unwrap() >= unix_now() - 60);
        verified.unwrap();
    }

    #[test]
    fn relay_feed_refuses_without_an_x86_64_tarball() {
        let dir = scratch("relaynox86");
        write_tarball(&dir, "hollow-relay-0.12.2-linux-aarch64.tar.gz", &good_tarball("linux-aarch64", "0.12.2", 0));
        write_tarball(&dir, "hollow-relay-0.12.1-linux-x86_64.tar.gz", &good_tarball("linux-x86_64", "0.12.1", 0));
        let r = relay_feed(&relay_feed_args(&dir, &[]));
        let written = dir.join("relay.json").exists();
        let bad_build = relay_feed(&relay_feed_args(&dir, &["--build", "10000"]));
        let _ = fs::remove_dir_all(&dir);
        assert!(r.as_ref().is_err_and(|e| e.contains("no x86_64 tarball")), "{r:?}");
        assert!(!written, "relay.json written without the required machine");
        assert!(bad_build.is_err());
    }

    /// Installers keep the highest `issued` they accepted, so the relay stamp
    /// moves past the live copy exactly like the status stamp.
    #[test]
    fn relay_stamp_moves_past_the_live_copy() {
        let dir = scratch("relaylive");
        write_tarball(&dir, "hollow-relay-0.12.2-linux-x86_64.tar.gz", &good_tarball("linux-x86_64", "0.12.2", 0));
        relay_feed(&relay_feed_args(&dir, &[])).unwrap();
        let live_at = unix_now() + 900;
        let live = dir.join("live.json");
        fs::write(&live, format!(r#"{{"feed":"relay","version":"0.12.2","build":0,"issued": {live_at}}}"#)).unwrap();
        let r = sign_relay(&dir, &["--stamp", "--live", live.to_str().unwrap()]);
        let after: serde_json::Value = serde_json::from_slice(&fs::read(dir.join("relay.json")).unwrap()).unwrap();
        let _ = fs::remove_dir_all(&dir);
        r.unwrap();
        assert!(after["issued"].as_u64().unwrap() > live_at, "relay stamp stayed at or below the live copy");
    }

    /// Every tarball an installer's release_feed.sh would refuse, each with one fault.
    fn bad_tarballs() -> Vec<(&'static str, Vec<u8>)> {
        let a = "linux-x86_64";
        let with = |f: &dyn Fn(&mut Vec<Member>)| {
            let mut m = good_members(a, "0.12.2", 0);
            f(&mut m);
            tar_gz(m)
        };
        vec![
            ("./ members", with(&|m| m.iter_mut().for_each(|x| { x.name.splice(0..0, *b"./"); }))),
            ("VERSION of another release", with(&|m| m[0].body = b"version=0.12.1\nbuild=7\n".to_vec())),
            ("VERSION of another build", with(&|m| m[0].body = feeds::relay_version_marker("0.12.2", 7, COMMIT).into_bytes())),
            ("VERSION without a commit", with(&|m| m[0].body = b"version=0.12.2\nbuild=0\n".to_vec())),
            ("VERSION with a short commit", with(&|m| m[0].body = b"version=0.12.2\nbuild=0\ncommit=abc\n".to_vec())),
            ("VERSION with an extra line", with(&|m| m[0].body.extend_from_slice(b"x\n"))),
            ("an aarch64 relay", with(&|m| m[2].body = elf("linux-aarch64"))),
            ("an aarch64 forwarder", with(&|m| m[1].body = elf("linux-aarch64"))),
            ("a relay that is not ELF", with(&|m| m[2].body = b"#!/bin/sh\necho hi\n".to_vec())),
            ("a 32-bit relay", with(&|m| m[2].body[4] = 1)),
            ("an extra member", with(&|m| m.push(file("evil", b"x".to_vec())))),
            ("a missing member", with(&|m| { m.remove(1); })),
            ("a duplicate member", with(&|m| m.push(file("hollow-relay", elf(a))))),
            ("a nested member", with(&|m| m[0].name = b"sub/VERSION".to_vec())),
            ("a parent path", with(&|m| m[0].name = b"../VERSION".to_vec())),
            ("a symlink", with(&|m| { m[2] = Member { name: b"hollow-relay".to_vec(), kind: tar::EntryType::Symlink, body: vec![], link: Some("/etc/passwd"), mode: 0o777 }; })),
            ("a hard link", with(&|m| { m[0] = Member { name: b"VERSION".to_vec(), kind: tar::EntryType::Link, body: vec![], link: Some("hollow-forwarder"), mode: 0o644 }; })),
            ("a folder", with(&|m| { m[2] = Member { name: b"hollow-relay/".to_vec(), kind: tar::EntryType::Directory, body: vec![], link: None, mode: 0o755 }; })),
            // The setup's copy, mirrored from relay-uws/test/release_feed (SETUP_REFUSED).
            ("a setup link", with(&|m| m.push(Member { name: b"setup/deploy/lib/x.sh".to_vec(), kind: tar::EntryType::Symlink, body: vec![], link: Some("/etc/passwd"), mode: 0o777 }))),
            ("a setup hard link", with(&|m| m.push(Member { name: b"setup/deploy/lib/x.sh".to_vec(), kind: tar::EntryType::Link, body: vec![], link: Some("hollow-relay"), mode: 0o644 }))),
            ("a setup device", with(&|m| m.push(Member { kind: tar::EntryType::Char, ..setup_file("setup/deploy/lib/x.sh") }))),
            ("a setup fifo", with(&|m| m.push(Member { kind: tar::EntryType::Fifo, ..setup_file("setup/deploy/lib/x.sh") }))),
            ("a setup folder entry", with(&|m| m.push(Member { name: b"setup/deploy/".to_vec(), kind: tar::EntryType::Directory, body: vec![], link: None, mode: 0o755 }))),
            ("a setup parent path", with(&|m| m.push(setup_file("setup/deploy/../../evil.sh")))),
            ("a setup dot-dot part", with(&|m| m.push(setup_file("setup/deploy/../evil.sh")))),
            ("an absolute path", with(&|m| m.push(setup_file("/etc/cron.d/evil")))),
            ("another setup root", with(&|m| m.push(setup_file("setup/bin/evil.sh")))),
            ("a file at the setup root", with(&|m| m.push(setup_file("setup/evil.sh")))),
            ("a hidden setup file", with(&|m| m.push(setup_file("setup/deploy/.evil.sh")))),
            ("a setup name read as an option", with(&|m| m.push(setup_file("setup/deploy/-evil.sh")))),
            ("a space in a setup name", with(&|m| m.push(setup_file("setup/deploy/a b.sh")))),
            ("a newline in a setup name", with(&|m| m.push(setup_file("setup/deploy/a\nb.sh")))),
            ("a wildcard in a setup name", with(&|m| m.push(setup_file("setup/deploy/*.sh")))),
            ("a setup file six parts deep", with(&|m| m.push(setup_file("setup/deploy/a/b/c/d/e/f.sh")))),
            ("a setup name part of 65", with(&|m| m.push(setup_file(&format!("setup/deploy/{}", "a".repeat(65)))))),
            ("a setup file 0777", with(&|m| m.push(Member { mode: 0o777, ..setup_file("setup/deploy/m.sh") }))),
            ("a setuid setup file", with(&|m| m.push(Member { mode: 0o4755, ..setup_file("setup/deploy/m.sh") }))),
            ("a setup file 0600", with(&|m| m.push(Member { mode: 0o600, ..setup_file("setup/deploy/m.sh") }))),
            ("a setup file over 1 MiB", with(&|m| m.push(Member { body: vec![b'#'; feeds::SETUP_MAX_FILE_BYTES as usize + 1], ..setup_file("setup/deploy/big.sh") }))),
            ("a setup copy over 8 MiB", with(&|m| (0..8).for_each(|i| m.push(Member { body: vec![b'#'; feeds::SETUP_MAX_FILE_BYTES as usize], ..setup_file(&format!("setup/deploy/big{i}.sh")) })))),
            ("a setup copy of 513 files", with(&|m| (0..(513 - SETUP.len())).for_each(|i| m.push(setup_file(&format!("setup/deploy/f{i}.sh")))))),
            ("a setup file twice", with(&|m| m.push(setup_file("setup/install.sh")))),
            ("a setup copy without install.sh", with(&|m| { m.retain(|x| x.name != b"setup/install.sh"); })),
            ("a setup copy without the feed check", with(&|m| { m.retain(|x| x.name != b"setup/deploy/lib/release_feed.sh"); })),
            ("not gzip", b"x86 tarball".to_vec()),
            // Each of these passes every other check, so only one rule refuses it.
            ("./ binaries", with(&|m| { m[1].name.splice(0..0, *b"./"); m[2].name.splice(0..0, *b"./"); })),
            ("one binary twice, the other missing", with(&|m| m[1] = file("hollow-relay", elf(a)))),
            ("a contiguous-file entry", with(&|m| m[2].kind = tar::EntryType::Continuous)),
        ]
    }

    /// relay-feed opens every tarball: one an installer refuses never gets a feed.
    #[test]
    fn relay_feed_refuses_every_tarball_an_installer_refuses() {
        for (fault, bytes) in bad_tarballs() {
            let dir = scratch("relaybad1");
            write_tarball(&dir, "hollow-relay-0.12.2-linux-x86_64.tar.gz", &bytes);
            let r = relay_feed(&relay_feed_args(&dir, &[]));
            let written = dir.join("relay.json").exists();
            let _ = fs::remove_dir_all(&dir);
            assert!(r.is_err() && !written, "relay-feed accepted a tarball with {fault}");
        }
    }

    /// feed-sign opens every tarball too, so a hand-written relay.json naming a
    /// bad one is never signed.
    #[test]
    fn feed_sign_refuses_every_tarball_an_installer_refuses() {
        for (fault, bytes) in bad_tarballs() {
            let dir = scratch("relaybad2");
            let name = "hollow-relay-0.12.2-linux-x86_64.tar.gz";
            write_tarball(&dir, name, &bytes);
            let feed = serde_json::json!({
                "feed": "relay", "version": "0.12.2", "build": 0, "issued": unix_now(), "commit": COMMIT,
                "artifacts": {"linux-x86_64": {"url": format!("{}{name}", feeds::RELAY_RELEASE_BASE),
                    "sha256": sha256_hex(&bytes), "size": bytes.len()}}
            });
            fs::write(dir.join("relay.json"), feed.to_string()).unwrap();
            let r = sign_relay(&dir, &[]);
            let signed = dir.join("relay.json.sig").exists();
            let _ = fs::remove_dir_all(&dir);
            assert!(r.is_err() && !signed, "feed-sign signed a tarball with {fault}");
        }
    }

    #[test]
    fn feed_sign_refuses_a_tarball_that_is_missing_or_changed() {
        let dir = scratch("relaychanged");
        let name = "hollow-relay-0.12.2-linux-x86_64.tar.gz";
        write_tarball(&dir, name, &good_tarball("linux-x86_64", "0.12.2", 0));
        relay_feed(&relay_feed_args(&dir, &[])).unwrap();
        let control = sign_relay(&dir, &["--stamp"]);
        let mut rebuilt = good_members("linux-x86_64", "0.12.2", 0);
        rebuilt[2].body.push(0);
        write_tarball(&dir, name, &tar_gz(rebuilt));
        let changed = sign_relay(&dir, &["--stamp"]);
        let elsewhere = scratch("relaychanged-other");
        let moved = sign_relay(&dir, &["--stamp", "--tarballs", elsewhere.to_str().unwrap()]);
        fs::remove_file(dir.join(name)).unwrap();
        let missing = sign_relay(&dir, &["--stamp"]);
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&elsewhere);
        control.unwrap();
        assert!(changed.is_err(), "a tarball rebuilt after relay-feed was signed");
        assert!(moved.is_err(), "--tarballs pointing at an empty folder signed");
        assert!(missing.is_err(), "a feed was signed without its tarball");
    }

    #[test]
    fn feed_sign_refuses_a_tarball_from_another_commit() {
        let dir = scratch("relayothercommit");
        let name = "hollow-relay-0.12.2-linux-x86_64.tar.gz";
        let mut m = good_members("linux-x86_64", "0.12.2", 0);
        m[0].body = feeds::relay_version_marker("0.12.2", 0, &"f".repeat(40)).into_bytes();
        let bytes = tar_gz(m);
        write_tarball(&dir, name, &bytes);
        let feed = serde_json::json!({
            "feed": "relay", "version": "0.12.2", "build": 0, "issued": unix_now(), "commit": COMMIT,
            "artifacts": {"linux-x86_64": {"url": format!("{}{name}", feeds::RELAY_RELEASE_BASE),
                "sha256": sha256_hex(&bytes), "size": bytes.len()}}
        });
        fs::write(dir.join("relay.json"), feed.to_string()).unwrap();
        let r = sign_relay(&dir, &[]);
        let _ = fs::remove_dir_all(&dir);
        assert!(r.is_err_and(|e| e.contains("names commit")));
    }

    #[test]
    fn relay_feed_refuses_tarballs_from_two_commits() {
        let dir = scratch("relaycommits");
        let mut arm = good_members("linux-aarch64", "0.12.2", 0);
        arm[0].body = feeds::relay_version_marker("0.12.2", 0, &"f".repeat(40)).into_bytes();
        write_tarball(&dir, "hollow-relay-0.12.2-linux-x86_64.tar.gz", &good_tarball("linux-x86_64", "0.12.2", 0));
        write_tarball(&dir, "hollow-relay-0.12.2-linux-aarch64.tar.gz", &tar_gz(arm));
        let r = relay_feed(&relay_feed_args(&dir, &[]));
        let _ = fs::remove_dir_all(&dir);
        assert!(r.is_err_and(|e| e.contains("one commit")));
    }

    #[test]
    fn relay_floor_rewrites_exactly_the_three_lines() {
        let dir = scratch("relayfloor");
        let lib = dir.join("release_feed.sh");
        let feed = dir.join("relay.json");
        fs::write(&feed, r#"{"feed":"relay","version":"0.12.3","build":2,"issued":1800000000}"#).unwrap();
        let body = "a\n_HF_MIN_ISSUED=1\n_HF_MIN_VERSION=0.12.2\n_HF_MIN_BUILD=0\n  _HF_MIN_BUILD=9 kept\nb\n";
        fs::write(&lib, body).unwrap();
        let args = |f: &Path| vec![f.to_str().unwrap().to_string(), lib.to_str().unwrap().to_string()];
        relay_floor(&args(&feed)).unwrap();
        let after = fs::read_to_string(&lib).unwrap();
        fs::write(&lib, "_HF_MIN_ISSUED=1\n_HF_MIN_VERSION=0.12.2\n").unwrap();
        let missing = relay_floor(&args(&feed));
        fs::write(&lib, "_HF_MIN_ISSUED=1\n_HF_MIN_ISSUED=2\n_HF_MIN_VERSION=0.12.2\n_HF_MIN_BUILD=0\n").unwrap();
        let twice = relay_floor(&args(&feed));
        fs::write(&lib, body).unwrap();
        fs::write(&feed, r#"{"feed":"relay","version":"0.12","build":2,"issued":1800000000}"#).unwrap();
        let bad_feed = relay_floor(&args(&feed));
        let untouched = fs::read_to_string(&lib).unwrap();
        let _ = fs::remove_dir_all(&dir);
        assert_eq!(after, "a\n_HF_MIN_ISSUED=1800000000\n_HF_MIN_VERSION=0.12.3\n_HF_MIN_BUILD=2\n  _HF_MIN_BUILD=9 kept\nb\n");
        assert!(missing.is_err() && twice.is_err() && bad_feed.is_err());
        assert_eq!(untouched, body, "a refused run wrote the library");
    }

    /// The installer's real library takes the rewrite: three lines change, nothing else.
    #[test]
    fn relay_floor_applies_to_the_installer_library() {
        const LIB: &str = include_str!("../../../relay-uws/deploy/lib/release_feed.sh");
        let dir = scratch("relayfloorlib");
        let lib = dir.join("release_feed.sh");
        let feed = dir.join("relay.json");
        fs::write(&lib, LIB).unwrap();
        fs::write(&feed, r#"{"feed":"relay","version":"7.8.9","build":4,"issued":1900000000}"#).unwrap();
        let r = relay_floor(&[feed.to_str().unwrap().into(), lib.to_str().unwrap().into()]);
        let after = fs::read_to_string(&lib).unwrap();
        let _ = fs::remove_dir_all(&dir);
        r.unwrap();
        let changed: Vec<_> = LIB.lines().zip(after.lines()).filter(|(a, b)| a != b).map(|(_, b)| b).collect();
        assert_eq!(changed, ["_HF_MIN_ISSUED=1900000000", "_HF_MIN_VERSION=7.8.9", "_HF_MIN_BUILD=4"]);
        assert_eq!(LIB.lines().count(), after.lines().count());
    }

    /// Installers refuse an older release than they run, so the signer will not
    /// publish one over the live feed unless asked by name.
    #[test]
    fn relay_sign_refuses_a_release_older_than_the_live_one() {
        let cases: &[(&str, u64, &str, &[&str], bool)] = &[
            (r#"{"feed":"relay","version":"0.12.5","build":3}"#, 0, "older version", &[], false),
            (r#"{"feed":"relay","version":"0.12.5","build":3}"#, 0, "older version, asked", &["--allow-downgrade"], true),
            (r#"{"feed":"relay","version":"0.12.2","build":2}"#, 1, "older build", &[], false),
            (r#"{"feed":"relay","version":"0.12.2","build":1}"#, 1, "the same release", &[], true),
            (r#"{"feed":"relay","version":"0.12.2","build":0}"#, 1, "a newer build", &[], true),
            (r#"{"feed":"relay","version":"0.9.10","build":9}"#, 0, "a newer version", &[], true),
            (r#"{"feed":"relay","issued":5}"#, 0, "a live copy without a version", &[], false),
            ("<html>gateway error</html>", 0, "a live copy that is not JSON", &[], false),
        ];
        for (live_body, build, what, extra, ok) in cases {
            let dir = scratch("relaydowngrade");
            let tag = if *build > 0 { format!("-b{build}") } else { String::new() };
            write_tarball(&dir, &format!("hollow-relay-0.12.2{tag}-linux-x86_64.tar.gz"), &good_tarball("linux-x86_64", "0.12.2", *build));
            relay_feed(&relay_feed_args(&dir, &["--build", &build.to_string()])).unwrap();
            let live = dir.join("live.json");
            fs::write(&live, live_body).unwrap();
            let mut args = vec!["--stamp", "--live", live.to_str().unwrap()];
            args.extend_from_slice(extra);
            let r = sign_relay(&dir, &args);
            let signed = dir.join("relay.json.sig").exists();
            let _ = fs::remove_dir_all(&dir);
            assert_eq!(r.is_ok() && signed, *ok, "{what}: {r:?}");
        }
        let dir = scratch("relaynolive");
        write_tarball(&dir, "hollow-relay-0.12.2-linux-x86_64.tar.gz", &good_tarball("linux-x86_64", "0.12.2", 0));
        relay_feed(&relay_feed_args(&dir, &[])).unwrap();
        let first = sign_relay(&dir, &["--stamp", "--live", dir.join("none.json").to_str().unwrap()]);
        let _ = fs::remove_dir_all(&dir);
        first.expect("the first relay feed (no live copy) is signed");
    }

    #[test]
    fn next_issued_is_the_highest_of_now_file_and_live() {
        assert_eq!(next_issued(100, None, None), 100);
        assert_eq!(next_issued(100, Some(50), Some(60)), 100);
        assert_eq!(next_issued(100, Some(150), None), 151);
        assert_eq!(next_issued(100, Some(150), Some(200)), 201);
        assert_eq!(next_issued(100, None, Some(100)), 101);
    }

    /// Installers take a release from before the setup rode along (they keep
    /// their copy), but nothing this signer releases leaves it out.
    #[test]
    fn a_tarball_without_the_setup_installs_but_is_never_released() {
        let old = tar_gz(good_members("linux-x86_64", "0.12.2", 0).into_iter().take(3).collect());
        let t = feeds::check_relay_tarball(&old, "linux-x86_64", "0.12.2", 0).expect("installers take it");
        assert_eq!(t.setup_files, 0);
        let good = feeds::check_relay_tarball(&good_tarball("linux-x86_64", "0.12.2", 0), "linux-x86_64", "0.12.2", 0).unwrap();
        assert_eq!(good.setup_files, SETUP.len());
        let dir = scratch("relaynosetup1");
        write_tarball(&dir, "hollow-relay-0.12.2-linux-x86_64.tar.gz", &old);
        let r = relay_feed(&relay_feed_args(&dir, &[]));
        let written = dir.join("relay.json").exists();
        let _ = fs::remove_dir_all(&dir);
        assert!(r.as_ref().is_err_and(|e| e.contains("no copy of the setup")) && !written, "{r:?}");
        let dir = scratch("relaynosetup2");
        let name = "hollow-relay-0.12.2-linux-x86_64.tar.gz";
        write_tarball(&dir, name, &old);
        let feed = serde_json::json!({
            "feed": "relay", "version": "0.12.2", "build": 0, "issued": unix_now(), "commit": COMMIT,
            "artifacts": {"linux-x86_64": {"url": format!("{}{name}", feeds::RELAY_RELEASE_BASE),
                "sha256": sha256_hex(&old), "size": old.len()}}
        });
        fs::write(dir.join("relay.json"), feed.to_string()).unwrap();
        let r = sign_relay(&dir, &[]);
        let signed = dir.join("relay.json.sig").exists();
        let _ = fs::remove_dir_all(&dir);
        assert!(r.is_err() && !signed, "feed-sign signed a tarball without the setup");
    }

    /// A setup whose install.sh sources a library it lacks stops before its
    /// own menu on every box that takes it, so neither command releases it.
    #[test]
    fn relay_feed_refuses_a_setup_missing_a_sourced_lib() {
        let name = "hollow-relay-0.12.2-linux-x86_64.tar.gz";
        let with_install = |body: &str| {
            let mut m = good_members("linux-x86_64", "0.12.2", 0);
            for x in m.iter_mut().filter(|x| x.name == b"setup/install.sh") {
                x.body = body.as_bytes().to_vec();
            }
            tar_gz(m)
        };
        let sources = |lib: &str| format!("#!/bin/bash\n. \"$DEPLOY/lib/common.sh\"\n. \"$DEPLOY/lib/{lib}\"\n");
        let good = with_install(&sources("release_feed.sh"));
        let bad = with_install(&sources("ui.sh"));
        let dir = scratch("relaynolib1");
        write_tarball(&dir, name, &good);
        let control = relay_feed(&relay_feed_args(&dir, &[]));
        fs::remove_file(dir.join("relay.json")).ok();
        write_tarball(&dir, name, &bad);
        let r = relay_feed(&relay_feed_args(&dir, &[]));
        let written = dir.join("relay.json").exists();
        let _ = fs::remove_dir_all(&dir);
        control.expect("every sourced library is there");
        assert!(r.as_ref().is_err_and(|e| e.contains("misses setup/deploy/lib/ui.sh")) && !written, "{r:?}");
        let dir = scratch("relaynolib2");
        write_tarball(&dir, name, &bad);
        let feed = serde_json::json!({
            "feed": "relay", "version": "0.12.2", "build": 0, "issued": unix_now(), "commit": COMMIT,
            "artifacts": {"linux-x86_64": {"url": format!("{}{name}", feeds::RELAY_RELEASE_BASE),
                "sha256": sha256_hex(&bad), "size": bad.len()}}
        });
        fs::write(dir.join("relay.json"), feed.to_string()).unwrap();
        let r = sign_relay(&dir, &[]);
        let signed = dir.join("relay.json.sig").exists();
        let _ = fs::remove_dir_all(&dir);
        assert!(r.is_err() && !signed, "feed-sign signed a setup missing a sourced library");
    }

    /// The setup's bounds themselves pass, so each refusal above is its rule.
    #[test]
    fn a_setup_copy_at_its_bounds_is_accepted() {
        let a = "linux-x86_64";
        let with = |f: &dyn Fn(&mut Vec<Member>)| {
            let mut m = good_members(a, "0.12.2", 0);
            f(&mut m);
            feeds::check_relay_tarball(&tar_gz(m), a, "0.12.2", 0)
        };
        with(&|m| m.push(setup_file("setup/deploy/a/b/c/d/f.sh"))).unwrap();
        with(&|m| m.push(setup_file(&format!("setup/deploy/{}", "a".repeat(64))))).unwrap();
        with(&|m| m.push(Member { body: vec![b'#'; feeds::SETUP_MAX_FILE_BYTES as usize], ..setup_file("setup/deploy/big.sh") })).unwrap();
        with(&|m| (0..(512 - SETUP.len())).for_each(|i| m.push(setup_file(&format!("setup/deploy/f{i}.sh"))))).unwrap();
        with(&|m| m.push(setup_file("setup/push-sidecar/_x-1.Y"))).unwrap();
    }

    #[test]
    fn setup_paths_follow_the_installers_rule() {
        for ok in ["setup/install.sh", "setup/deploy/x", "setup/deploy/lib/release_feed.sh", "setup/push-sidecar/index.js",
            "setup/deploy/a/b/c/d/e", "setup/deploy/_a", "setup/deploy/9.x-y_z"] {
            assert!(feeds::is_setup_path(ok), "{ok}");
        }
        for bad in ["install.sh", "setup", "setup/", "setup/deploy", "setup/deploy/", "setup/install.sh/x", "setup/x.sh",
            "setup/deploy//x", "setup/deploy/a/b/c/d/e/f", "setup/deploy/.x", "setup/deploy/-x", "setup/deploy/..",
            "setup/deploy/../x", "./setup/install.sh", "/setup/install.sh", "setup/deploy/a b", "setup/deploy/\u{e9}",
            "setup/Deploy/x", "setup/deploy/x/"] {
            assert!(!feeds::is_setup_path(bad), "{bad}");
        }
    }

    #[test]
    fn a_live_download_is_read_only_up_to_the_cap() {
        assert_eq!(read_capped(&b"abc"[..], 3, "t").unwrap(), b"abc");
        assert!(read_capped(&b"abcd"[..], 3, "t").is_err());
        // An endless body stops one byte past the cap.
        assert!(read_capped(std::io::repeat(0), 1024, "t").is_err());
    }

    /// relay-check-live opens what the host serves like an installer would.
    #[test]
    fn relay_check_live_opens_the_served_tarball() {
        let good = good_tarball("linux-x86_64", "0.12.2", 0);
        let feed_for = |bytes: &[u8], commit: &str| serde_json::json!({
            "feed": "relay", "version": "0.12.2", "build": 0, "issued": 1, "commit": commit,
            "artifacts": {"linux-x86_64": {"url": "https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz",
                "sha256": sha256_hex(bytes), "size": bytes.len()}}
        });
        live_tarball_ok(&feed_for(&good, COMMIT), "linux-x86_64", &good).unwrap();
        assert!(live_tarball_ok(&feed_for(&good, COMMIT), "linux-x86_64", &good[1..]).is_err(), "other bytes");
        assert!(live_tarball_ok(&feed_for(&good, &"f".repeat(40)), "linux-x86_64", &good).is_err(), "other commit");
        let old = tar_gz(good_members("linux-x86_64", "0.12.2", 0).into_iter().take(3).collect());
        assert!(live_tarball_ok(&feed_for(&old, COMMIT), "linux-x86_64", &old).is_err(), "no setup");
        let mut bad = good_members("linux-x86_64", "0.12.2", 0);
        bad.push(setup_file("setup/bin/evil.sh"));
        let bad = tar_gz(bad);
        assert!(live_tarball_ok(&feed_for(&bad, COMMIT), "linux-x86_64", &bad).is_err(), "a bad setup member");
    }
}
