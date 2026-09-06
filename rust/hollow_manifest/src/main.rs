//! `hollow-manifest`: hashes, signs and verifies the update manifest.
//!
//! The app verifies `manifest.json.sig` (base64 Ed25519 over the exact bytes
//! of `manifest.json`) against `MANIFEST_SIGNING_PUBKEYS` in
//! `hollow_core/src/api/updater.rs`, then checks every downloaded zip against
//! the `sha256_<platform>` field of its version entry. Everything here mirrors
//! that check byte for byte; `verify` IS that check, run outside the app.

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
      Write the base64 Ed25519 signature over the manifest's exact bytes.

  verify (<manifest.json> <manifest.json.sig> | --url <manifest-url>) --pubkey <hex>
      Replay the app's check. Exit 0 only when the signature verifies.
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("keygen") => keygen(&args[1..]),
        Some("fill-hashes") => fill_hashes(&args[1..]),
        Some("sign") => sign(&args[1..]),
        Some("verify") => verify(&args[1..]),
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
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .map_err(|e| format!("{manifest_path} is not JSON, refusing to sign it: {e}"))?;
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
        let sig_url = format!("{url}.sig");
        (
            fetch(&url)?,
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
