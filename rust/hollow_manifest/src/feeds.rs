//! The release feeds next to the manifest (`status.json`, `news.json`, and
//! `relay.json` for self-hosters' installers) and the shape checks run before
//! anything is signed.
//!
//! A feed signature covers [`feed_message`], never the bare bytes: the manifest
//! signature is over the bare manifest, so the prefix keeps a feed signature from
//! ever passing as a manifest signature or as the other feed's. Mirrors
//! `feed_message` in hollow_core/src/api/updater.rs; the KAT in both crates pins it.

use serde_json::Value;

/// The feeds a signature may name.
pub const FEEDS: &[&str] = &["status", "news", "relay"];

const FEED_SIG_CONTEXT: &[u8] = b"hollow-feed-sig-v1\0";

/// The highest build number a version entry may carry (the app's `MAX_BUILD`).
pub const MAX_BUILD: u64 = 9999;

/// The app's read caps (`fetch_cap` in updater.rs): a body over its cap is
/// refused unparsed, so nothing over it is ever signed.
pub const STATUS_CAP_BYTES: usize = 64 * 1024;
pub const NEWS_CAP_BYTES: usize = 256 * 1024;
pub const MANIFEST_CAP_BYTES: usize = 1024 * 1024;
/// `relay-uws/deploy/lib/release_feed.sh` reads relay.json and each tarball
/// under these caps (`_HF_FEED_CAP`, `_HF_TARBALL_CAP`).
pub const RELAY_CAP_BYTES: usize = 16 * 1024;
pub const MAX_RELAY_TARBALL_BYTES: u64 = 256 * 1024 * 1024;

/// Where every relay tarball is served; the installer refuses any other URL.
pub const RELAY_RELEASE_BASE: &str = "https://anonlisten.com/hollow/releases/";
/// The machines a relay tarball is built for; x86_64 is in every feed.
pub const RELAY_ARCHES: &[&str] = &["linux-x86_64", "linux-aarch64"];
const RELAY_REQUIRED_ARCH: &str = "linux-x86_64";

/// How far past the signer's clock `issued` may sit; apps keep the highest
/// stamp they saw, so a stamp from the future would hide every later feed.
pub const MAX_ISSUED_AHEAD_SECS: u64 = 3600;

/// Refuses a body the app would refuse for its size (`status`, `news`, `manifest`).
pub fn check_size(what: &str, len: usize) -> Result<(), String> {
    let cap = match what {
        "status" => STATUS_CAP_BYTES,
        "news" => NEWS_CAP_BYTES,
        "manifest" => MANIFEST_CAP_BYTES,
        "relay" => RELAY_CAP_BYTES,
        _ => return Err(format!("unknown file kind {what:?}")),
    };
    if len > cap {
        return Err(format!("{len} bytes is over the app's {cap}-byte cap for {what}; apps would show nothing"));
    }
    Ok(())
}

/// What every full release entry carries, as manifests have since 0.10: apps up
/// to 0.12.1 install from the first entry whose version is `latest`, and the
/// website links versions[0].
const RELEASE_URLS: &[&str] = &[
    "url_windows",
    "url_windows_setup",
    "url_macos",
    "url_macos_dmg",
    "url_linux",
    "url_linux_targz",
    "url_android",
];
const RELEASE_HASHES: &[&str] = &["sha256_windows", "sha256_macos", "sha256_linux", "sha256_linux_targz"];

const LEVELS: &[&str] = &["operational", "info", "maintenance", "warning", "critical"];
const RELAYS: &[&str] = &["official", "self_hosted", "all"];
const PLATFORMS: &[&str] = &["windows", "linux", "macos", "android", "ios"];

pub fn feed_message(feed: &str, bytes: &[u8]) -> Result<Vec<u8>, String> {
    if !FEEDS.contains(&feed) {
        return Err(format!("unknown feed {feed:?}; expected one of {FEEDS:?}"));
    }
    let mut msg = Vec::with_capacity(FEED_SIG_CONTEXT.len() + feed.len() + 1 + bytes.len());
    msg.extend_from_slice(FEED_SIG_CONTEXT);
    msg.extend_from_slice(feed.as_bytes());
    msg.push(0);
    msg.extend_from_slice(bytes);
    Ok(msg)
}

/// Three dot-separated decimal parts of 1 to 5 digits (the app's `is_release_version`).
pub fn is_release_version(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| (1..=5).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_digit()))
}

/// `0.12.2` or `0.12.2+1`, as a notice's `below` / `from` names a build.
fn is_release_id(v: &str) -> bool {
    match v.split_once('+') {
        None => is_release_version(v),
        Some((ver, build)) => {
            is_release_version(ver)
                && (1..=4).contains(&build.len())
                && build.bytes().all(|b| b.is_ascii_digit())
        }
    }
}

/// The app's manifest check (`manifest_versions_well_formed`), run before signing
/// so a manifest the app would refuse whole is never signed.
pub fn check_manifest(root: &Value) -> Result<(), String> {
    let latest = root.get("latest").and_then(Value::as_str).unwrap_or("");
    if !is_release_version(latest) {
        return Err(format!("latest {latest:?} must be three numeric parts (0.12.2); a build rides `build`"));
    }
    let versions = root
        .get("versions")
        .and_then(Value::as_array)
        .ok_or("manifest has no versions[]")?;
    let mut seen = std::collections::HashSet::new();
    for (i, entry) in versions.iter().enumerate() {
        let v = entry.get("version").and_then(Value::as_str).unwrap_or("");
        if !is_release_version(v) {
            return Err(format!("versions[{i}].version {v:?} must be three numeric parts"));
        }
        let build = match entry.get("build") {
            None => 0,
            Some(b) => b
                .as_u64()
                .filter(|n| *n <= MAX_BUILD)
                .ok_or_else(|| format!("versions[{i}].build must be an integer from 0 to {MAX_BUILD}, got {b}"))?,
        };
        if let Some(c) = entry.get("critical")
            && !c.is_boolean()
        {
            return Err(format!("versions[{i}].critical must be true or false, got {c}"));
        }
        let parts: Vec<u64> = v.split('.').filter_map(|p| p.parse().ok()).collect();
        if !seen.insert((parts, build)) {
            return Err(format!("versions[{i}] repeats {v} build {build}; which one an app picks would depend on order"));
        }
    }
    check_full_release_first(latest, versions)
}

/// versions[0] is the full release `latest` names: no build, every download and
/// its hash. Apps up to 0.12.1 take the first `latest` entry and ignore
/// `build`, so a patch entry there would hand every platform it lacks nothing.
fn check_full_release_first(latest: &str, versions: &[Value]) -> Result<(), String> {
    let first = versions
        .first()
        .ok_or("versions[] is empty; versions[0] must be the full release `latest` names")?;
    if first.get("version").and_then(Value::as_str) != Some(latest) {
        return Err(format!("versions[0] must be {latest} (the `latest` release), newest first"));
    }
    if first.get("build").and_then(Value::as_u64).unwrap_or(0) != 0 {
        return Err("versions[0] must be the full release, without `build`; list patch entries after it".into());
    }
    for key in RELEASE_URLS {
        if !first.get(*key).and_then(Value::as_str).is_some_and(|u| u.starts_with("https://")) {
            return Err(format!("versions[0] ({latest}) needs {key} as an https URL, like every full release"));
        }
    }
    for key in RELEASE_HASHES {
        let ok = first
            .get(*key)
            .and_then(Value::as_str)
            .is_some_and(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()));
        if !ok {
            return Err(format!("versions[0] ({latest}) needs {key}; run fill-hashes first"));
        }
    }
    Ok(())
}

/// Seconds since the Unix epoch for `YYYY-MM-DDTHH:MM:SSZ`, the one form a feed
/// timestamp is written in.
pub fn parse_utc(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() != 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' || b[19] != b'Z' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let part = &s[r];
        part.bytes().all(|c| c.is_ascii_digit()).then(|| part.parse().ok())?
    };
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, sec) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 59 {
        return None;
    }
    // Days from civil (Howard Hinnant), valid for the proleptic Gregorian calendar.
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days * 86_400 + h * 3600 + mi * 60 + sec).ok()
}

/// Shape check for a feed before it is signed. Strict where the app is quiet: a
/// notice the app would skip (bad level, targeting typo, no `expires`) is refused
/// here, so a typo never ships as a notice nobody sees.
pub fn check_feed(feed: &str, root: &Value) -> Result<Vec<String>, String> {
    match feed {
        "status" => check_status(root, unix_now()?),
        "news" => check_news(root),
        "relay" => check_relay(root, unix_now()?),
        _ => Err(format!("unknown feed {feed:?}")),
    }
}

/// The tarball an installer downloads for one machine; the installer derives
/// the same name and refuses a feed whose URL differs.
pub fn relay_tarball_name(version: &str, build: u64, arch: &str) -> String {
    let patch = if build > 0 { format!("-b{build}") } else { String::new() };
    format!("hollow-relay-{version}{patch}-{arch}.tar.gz")
}

/// `issued` as every stamped feed carries it: Unix seconds, and never so far
/// ahead that installers and apps keeping the highest stamp would hide later feeds.
fn check_issued(obj: &serde_json::Map<String, Value>, file: &str, now: u64) -> Result<u64, String> {
    let issued = obj
        .get("issued")
        .and_then(Value::as_u64)
        .filter(|n| *n > 0)
        .ok_or_else(|| format!("{file} needs `issued` (Unix seconds); feed-sign --stamp writes it"))?;
    if issued > now.saturating_add(MAX_ISSUED_AHEAD_SECS) {
        return Err(format!(
            "issued {issued} is more than {MAX_ISSUED_AHEAD_SECS} s past this clock ({now}); every later feed would be refused"
        ));
    }
    Ok(issued)
}

fn check_relay(root: &Value, now: u64) -> Result<Vec<String>, String> {
    let obj = root.as_object().ok_or("relay.json must be a JSON object")?;
    if obj.get("feed").and_then(Value::as_str) != Some("relay") {
        return Err("relay.json needs \"feed\": \"relay\"".into());
    }
    let version = obj.get("version").and_then(Value::as_str).unwrap_or("");
    if !is_release_version(version) {
        return Err(format!("version {version:?} must be three numeric parts, HOLLOW_RELAY_VERSION in relay-uws/src/version.h"));
    }
    let build = obj
        .get("build")
        .and_then(Value::as_u64)
        .filter(|n| *n <= MAX_BUILD)
        .ok_or_else(|| format!("build must be an integer from 0 to {MAX_BUILD}"))?;
    check_issued(obj, "relay.json", now)?;
    let commit = obj.get("commit").and_then(Value::as_str).unwrap_or("");
    if !is_commit(commit) {
        return Err(format!("commit {commit:?} must be the 40 or 64 lowercase hex digits of the built commit"));
    }
    let artifacts = obj
        .get("artifacts")
        .and_then(Value::as_object)
        .ok_or("relay.json needs `artifacts` (an object keyed by machine)")?;
    if !artifacts.contains_key(RELAY_REQUIRED_ARCH) {
        return Err(format!("artifacts needs {RELAY_REQUIRED_ARCH}"));
    }
    let mut warnings = Vec::new();
    for arch in RELAY_ARCHES {
        if !artifacts.contains_key(*arch) {
            warnings.push(format!("no {arch} tarball: those machines can only build from source"));
        }
    }
    for (arch, a) in artifacts {
        let at = |what: &str| format!("artifacts.{arch}: {what}");
        if !RELAY_ARCHES.contains(&arch.as_str()) {
            return Err(at(&format!("unknown machine, expected one of {RELAY_ARCHES:?}")));
        }
        let want = format!("{RELAY_RELEASE_BASE}{}", relay_tarball_name(version, build, arch));
        if a.get("url").and_then(Value::as_str) != Some(want.as_str()) {
            return Err(at(&format!("url must be {want}")));
        }
        let hash_ok = a
            .get("sha256")
            .and_then(Value::as_str)
            .is_some_and(|h| h.len() == 64 && h.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')));
        if !hash_ok {
            return Err(at("sha256 must be 64 lowercase hex digits; run relay-feed on the built tarballs"));
        }
        if !a
            .get("size")
            .and_then(Value::as_u64)
            .is_some_and(|n| (1..=MAX_RELAY_TARBALL_BYTES).contains(&n))
        {
            return Err(at(&format!("size must be an integer from 1 to {MAX_RELAY_TARBALL_BYTES}")));
        }
    }
    Ok(warnings)
}

/// The three regular files at a relay tarball's root.
pub const RELAY_TARBALL_FILES: [&str; 3] = ["VERSION", "hollow-forwarder", "hollow-relay"];
/// A bound on what one tarball may unpack to, so a bad file cannot fill the disk.
const MAX_RELAY_UNPACKED_BYTES: u64 = 1024 * 1024 * 1024;
/// The setup's own copy rides under `setup/` with the programs. These are
/// release_feed.sh's `_HF_SETUP_*`: installers already out refuse a tarball
/// outside them, so widening one strands every box that has not updated.
pub const SETUP_MAX_FILES: usize = 512;
pub const SETUP_MAX_FILE_BYTES: u64 = 1024 * 1024;
pub const SETUP_MAX_BYTES: u64 = 8 * 1024 * 1024;
/// What the next update reads from the copy it installs, besides every library
/// install.sh sources ([`sourced_libs`]): the push sender installs only from
/// its lockfile, and TURN never runs without its port lock.
pub const SETUP_NEEDS: [&str; 9] = [
    "setup/deploy/coturn-port-lock.conf",
    "setup/deploy/hollow-turn-port-lock-refresh.service",
    "setup/deploy/hollow-turn-port-lock-refresh.timer",
    "setup/deploy/hollow-turn-port-lock.service",
    "setup/deploy/lib/release_feed.sh",
    "setup/deploy/turn-port-lock.sh",
    "setup/install.sh",
    "setup/push-sidecar/package-lock.json",
    "setup/push-sidecar/package.json",
];
/// Every member's mtime is below this (2242): `tar -tv` writes a date for it,
/// so the installer's listing reads every member the same way.
pub const MAX_MEMBER_MTIME: u64 = 1 << 33;

/// The libraries install.sh sources, as `setup/deploy/lib/<name>`: each line
/// that is exactly `. "$DEPLOY/lib/<name>.sh"` (`_hf_sourced_libs`). A copy
/// missing one stops the setup before its menu, update included.
pub fn sourced_libs(install_sh: &str) -> Vec<String> {
    install_sh
        .split('\n')
        .filter_map(|l| l.strip_prefix(". \"$DEPLOY/lib/")?.strip_suffix(".sh\""))
        .filter(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
        .map(|n| format!("setup/deploy/lib/{n}.sh"))
        .collect()
}

/// The last gzip member of `bytes`, once every member before it unpacks to
/// nothing and nothing but members follows: `gzip -d` reads all of them as
/// one stream, so a second member with content, or bytes after the stream,
/// would show installers files this check never read (`_hf_gzip_ok`).
fn single_gzip_member(bytes: &[u8]) -> Result<&[u8], String> {
    use std::io::Read;
    let (mut rest, mut budget) = (bytes, MAX_RELAY_UNPACKED_BYTES);
    loop {
        let start = rest;
        let mut member = flate2::bufread::GzDecoder::new(rest);
        let n = std::io::copy(&mut (&mut member).take(budget + 1), &mut std::io::sink())
            .map_err(|e| format!("not a gzip stream, or bytes after it: {e}"))?;
        budget = budget.checked_sub(n).ok_or("the tarball unpacks to more than 1 GiB")?;
        rest = member.into_inner();
        if rest.is_empty() {
            return Ok(start);
        }
        if !rest.starts_with(&[0x1f, 0x8b]) {
            return Err("the gzip stream has bytes after it that are not gzip; installers refuse it".into());
        }
        if n > 0 {
            return Err("a second gzip member follows one with content; installers would read both as one tarball".into());
        }
    }
}

/// An entry's mtime, from its pax record when it has one, as `tar -tv` shows it.
fn member_mtime<R: std::io::Read>(entry: &mut tar::Entry<'_, R>, name: &str) -> Result<u64, String> {
    let mut pax_mtime = None;
    if let Some(pax) = entry.pax_extensions().map_err(|e| format!("{name}: {e}"))? {
        for ext in pax {
            let ext = ext.map_err(|e| format!("{name}: {e}"))?;
            let key = ext.key_bytes();
            if key.starts_with(b"GNU.sparse") {
                return Err(format!("{name} is a sparse file; installers take plain files only"));
            }
            if key == b"mtime" {
                let v = ext.value().map_err(|_| format!("{name}: a pax mtime that is not text"))?;
                let (secs, frac) = v.split_once('.').unwrap_or((v, "0"));
                let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
                if !digits(secs) || !digits(frac) {
                    return Err(format!("{name} has the pax mtime {v:?}"));
                }
                pax_mtime = Some(secs.parse::<u64>().unwrap_or(u64::MAX));
            }
        }
    }
    match pax_mtime {
        Some(t) => Ok(t),
        None => entry.header().mtime().map_err(|e| format!("{name}: {e}")),
    }
}

/// `_hf_setup_name_ok`: `setup/install.sh`, or a file one to five parts below
/// `setup/deploy/` or `setup/push-sidecar/`, each part 1 to 64 of
/// `[A-Za-z0-9._-]` starting with a letter, digit or underscore.
pub fn is_setup_path(name: &str) -> bool {
    let Some(rest) = name.strip_prefix("setup/") else { return false };
    if rest == "install.sh" {
        return true;
    }
    let mut parts = rest.split('/');
    if !matches!(parts.next(), Some("deploy" | "push-sidecar")) {
        return false;
    }
    let parts: Vec<&str> = parts.collect();
    (1..=5).contains(&parts.len()) && parts.iter().all(|p| is_setup_part(p))
}

fn is_setup_part(p: &str) -> bool {
    let b = p.as_bytes();
    (1..=64).contains(&b.len())
        && (b[0].is_ascii_alphanumeric() || b[0] == b'_')
        && b.iter().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}

/// What [`check_relay_tarball`] found in a tarball installers accept.
#[derive(Debug)]
pub struct RelayTarball {
    pub commit: String,
    /// Files of the setup's copy under `setup/`; 0 for a release from before it rode along.
    pub setup_files: usize,
}

/// A git object name: 40 (SHA-1) or 64 (SHA-256) lowercase hex digits.
pub fn is_commit(s: &str) -> bool {
    (s.len() == 40 || s.len() == 64) && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The VERSION marker a relay tarball carries; release_feed.sh compares it byte for byte.
pub fn relay_version_marker(version: &str, build: u64, commit: &str) -> String {
    format!("version={version}\nbuild={build}\ncommit={commit}\n")
}

/// The ELF header bytes release_feed.sh `_hf_elf_ok` accepts for `arch`:
/// 64-bit little endian, an executable or PIE, for that machine.
fn elf_for(head: &[u8], arch: &str) -> bool {
    let machine: [u8; 2] = match arch {
        "linux-x86_64" => [0x3e, 0x00],
        "linux-aarch64" => [0xb7, 0x00],
        _ => return false,
    };
    head.len() >= 20
        && head[..6] == [0x7f, b'E', b'L', b'F', 2, 1]
        && matches!(head[16], 2 | 3)
        && head[17] == 0
        && head[18..20] == machine
}

/// The installer's checks on one relay tarball (`_hf_fetch_in` in
/// release_feed.sh), so a tarball every installer would refuse is never
/// signed: the three regular files at the root, both binaries built for
/// `arch`, VERSION naming this version, build and a commit, and any setup
/// files plain, 0644 or 0755, within the setup bounds and with
/// [`SETUP_NEEDS`] and every library install.sh sources. One gzip member,
/// pax sizes and mtimes as tar reads them: the signed set is exactly the
/// set installers take.
pub fn check_relay_tarball(bytes: &[u8], arch: &str, version: &str, build: u64) -> Result<RelayTarball, String> {
    use std::io::Read;
    let gz = single_gzip_member(bytes)?;
    let mut archive = tar::Archive::new(flate2::bufread::GzDecoder::new(gz));
    let mut seen: Vec<String> = Vec::new();
    let mut commit = None;
    let mut install_sh = None;
    let mut budget = MAX_RELAY_UNPACKED_BYTES;
    let (mut setup_files, mut setup_bytes) = (0usize, 0u64);
    for entry in archive.entries().map_err(|e| format!("not a gzip tar: {e}"))? {
        let mut entry = entry.map_err(|e| format!("not a readable tar: {e}"))?;
        let name = String::from_utf8_lossy(&entry.path_bytes()).into_owned();
        if entry.header().entry_type() != tar::EntryType::Regular {
            return Err(format!("{name:?} is not a regular file; installers take regular files only"));
        }
        if seen.contains(&name) {
            return Err(format!("{name:?} appears twice"));
        }
        if member_mtime(&mut entry, &name)? >= MAX_MEMBER_MTIME {
            return Err(format!("{name} has an mtime past 2242, which installers cannot list"));
        }
        // The pax size when there is one, as tar reads it.
        let size = entry.size();
        budget = budget.checked_sub(size).ok_or("the tarball unpacks to more than 1 GiB")?;
        if !RELAY_TARBALL_FILES.contains(&name.as_str()) {
            if !is_setup_path(&name) {
                return Err(format!("{name:?} is neither one of {RELAY_TARBALL_FILES:?} at the root nor a file of the setup's copy under setup/install.sh, setup/deploy/ or setup/push-sidecar/"));
            }
            let mode = entry.header().mode().map_err(|e| format!("{name}: {e}"))? & 0o7777;
            if mode != 0o644 && mode != 0o755 {
                return Err(format!("{name} has mode {mode:o}; setup files are 644 or 755"));
            }
            if size > SETUP_MAX_FILE_BYTES {
                return Err(format!("{name} is {size} bytes, over the {SETUP_MAX_FILE_BYTES} a setup file may have"));
            }
            if name == "setup/install.sh" {
                let mut body = Vec::new();
                (&mut entry).take(size).read_to_end(&mut body).map_err(|e| format!("read {name}: {e}"))?;
                install_sh = Some(String::from_utf8_lossy(&body).into_owned());
            }
            setup_files += 1;
            setup_bytes += size;
            seen.push(name);
            continue;
        }
        let mut body = Vec::new();
        (&mut entry).take(size).read_to_end(&mut body).map_err(|e| format!("read {name}: {e}"))?;
        if name == "VERSION" {
            let text = String::from_utf8(body).map_err(|_| "VERSION is not text".to_string())?;
            let c = text.lines().nth(2).and_then(|l| l.strip_prefix("commit=")).unwrap_or("");
            if !is_commit(c) || text != relay_version_marker(version, build, c) {
                return Err(format!("VERSION reads {text:?}, not version {version} build {build} with a commit"));
            }
            commit = Some(c.to_string());
        } else if !elf_for(&body, arch) {
            return Err(format!("{name} is not a 64-bit ELF executable for {arch}"));
        }
        seen.push(name);
    }
    let missing: Vec<&str> = RELAY_TARBALL_FILES.iter().copied().filter(|f| !seen.iter().any(|s| s == f)).collect();
    if !missing.is_empty() {
        return Err(format!("misses {missing:?}; installers need {RELAY_TARBALL_FILES:?} at the root"));
    }
    if setup_files > SETUP_MAX_FILES || setup_bytes > SETUP_MAX_BYTES {
        return Err(format!("the setup's copy has {setup_files} files and {setup_bytes} bytes; installers take at most {SETUP_MAX_FILES} files and {SETUP_MAX_BYTES} bytes"));
    }
    if setup_files > 0 {
        let sourced = sourced_libs(install_sh.as_deref().unwrap_or(""));
        let needs = SETUP_NEEDS.iter().map(|n| n.to_string()).chain(sourced);
        if let Some(need) = needs.into_iter().find(|n| !seen.contains(n)) {
            return Err(format!("the setup's copy misses {need}"));
        }
    }
    Ok(RelayTarball { commit: commit.ok_or("no VERSION")?, setup_files })
}

/// (version parts, build) of a relay feed, when both are well formed.
fn relay_release(root: &Value) -> Option<(Vec<u64>, u64)> {
    let v = root.get("version").and_then(Value::as_str).filter(|v| is_release_version(v))?;
    let build = root.get("build").and_then(Value::as_u64).filter(|b| *b <= MAX_BUILD)?;
    Some((v.split('.').filter_map(|p| p.parse().ok()).collect(), build))
}

/// Installers refuse a release older than the one they run unless the operator
/// asks for a downgrade by name, so publishing one needs `--allow-downgrade`.
pub fn check_relay_not_older(feed: &Value, live: &Value, allow_downgrade: bool) -> Result<(), String> {
    let new = relay_release(feed).ok_or("relay.json has no valid version and build")?;
    let Some(old) = relay_release(live) else {
        if allow_downgrade {
            return Ok(());
        }
        return Err("the live relay.json has no readable version and build, so this cannot be checked against it; pass --allow-downgrade to sign anyway".into());
    };
    if new < old && !allow_downgrade {
        return Err(format!(
            "this is version {} build {}, older than the live {} build {}; installers that took the live one refuse it. Publish the fix as a higher build instead, or pass --allow-downgrade",
            feed["version"].as_str().unwrap_or("?"),
            new.1,
            live["version"].as_str().unwrap_or("?"),
            old.1
        ));
    }
    Ok(())
}

fn check_news(root: &Value) -> Result<Vec<String>, String> {
    let posts = root.as_array().ok_or("news.json must be a JSON array of posts")?;
    for (i, p) in posts.iter().enumerate() {
        if p.get("id").and_then(Value::as_str).is_none_or(str::is_empty) {
            return Err(format!("news[{i}] has no id"));
        }
    }
    Ok(Vec::new())
}

pub fn unix_now() -> Result<u64, String> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|e| format!("clock: {e}"))
}

fn check_status(root: &Value, now: u64) -> Result<Vec<String>, String> {
    let obj = root.as_object().ok_or("status.json must be a JSON object")?;
    let issued = check_issued(obj, "status.json", now)?;
    let notices = obj
        .get("notices")
        .and_then(Value::as_array)
        .ok_or("status.json needs `notices` (an array, empty when there is nothing to say)")?;
    let mut warnings = Vec::new();
    let mut ids = std::collections::HashSet::new();
    for (i, n) in notices.iter().enumerate() {
        let at = |what: &str| format!("notices[{i}]: {what}");
        let id = n.get("id").and_then(Value::as_str).unwrap_or("");
        if id.is_empty() {
            return Err(at("needs an id"));
        }
        if !ids.insert(id.to_string()) {
            return Err(at(&format!("id {id:?} is used twice")));
        }
        let level = n.get("level").and_then(Value::as_str).unwrap_or("");
        if !LEVELS.contains(&level) {
            return Err(at(&format!("level {level:?} is not one of {LEVELS:?}")));
        }
        let has_text = ["title", "message"]
            .iter()
            .any(|k| n.get(*k).and_then(Value::as_str).is_some_and(|t| !t.trim().is_empty()));
        if !has_text {
            return Err(at("needs a title or a message"));
        }
        let expires_raw = n.get("expires").and_then(Value::as_str).unwrap_or("");
        let expires = parse_utc(expires_raw)
            .ok_or_else(|| at(&format!("expires {expires_raw:?} must be YYYY-MM-DDTHH:MM:SSZ")))?;
        if expires <= issued {
            warnings.push(at(&format!("expires {expires_raw} is not after issued; it will never show")));
        }
        if let Some(r) = n.get("relay") {
            let r = r.as_str().unwrap_or("");
            if !RELAYS.contains(&r) {
                return Err(at(&format!("relay {r:?} is not one of {RELAYS:?}")));
            }
        }
        if let Some(p) = n.get("platforms") {
            let list = p.as_array().ok_or_else(|| at("platforms must be an array"))?;
            if list.is_empty() {
                return Err(at("platforms is empty; leave it out to mean every platform"));
            }
            for name in list {
                let name = name.as_str().unwrap_or("");
                if !PLATFORMS.contains(&name) {
                    return Err(at(&format!("platform {name:?} is not one of {PLATFORMS:?}")));
                }
            }
        }
        for key in ["below", "from"] {
            if let Some(v) = n.get(key) {
                let v = v.as_str().unwrap_or("");
                if !is_release_id(v) {
                    return Err(at(&format!("{key} {v:?} must be 0.12.2 or 0.12.2+1")));
                }
            }
        }
        if let Some(d) = n.get("dismissible")
            && !d.is_boolean()
        {
            return Err(at("dismissible must be true or false"));
        }
    }
    Ok(warnings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn feed_message_is_prefixed_and_names_the_feed() {
        let m = feed_message("status", b"{}").unwrap();
        assert_eq!(m, b"hollow-feed-sig-v1\0status\0{}".to_vec());
        assert_ne!(m, feed_message("news", b"{}").unwrap());
        assert!(feed_message("manifest", b"{}").is_err());
    }

    #[test]
    fn utc_parse_matches_known_instants() {
        assert_eq!(parse_utc("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_utc("2026-10-19T12:00:00Z"), Some(1_792_411_200));
        assert_eq!(parse_utc("2000-02-29T23:59:59Z"), Some(951_868_799));
        for bad in ["2026-10-19", "2026-10-19T12:00:00", "2026-13-01T00:00:00Z", "2026-10-19T12:00Z", "x"] {
            assert_eq!(parse_utc(bad), None, "{bad}");
        }
    }

    #[test]
    fn manifest_check_keeps_three_parts_and_bounds_the_build() {
        let ok = json!({"latest":"0.12.2","versions":[full_release("0.12.2"),{"version":"0.12.2","build":1,"critical":true}]});
        assert!(check_manifest(&ok).is_ok(), "{:?}", check_manifest(&ok));
        let with = |entry: Value| json!({"latest":"0.12.2","versions":[full_release("0.12.2"), entry]});
        for bad in [
            json!({"latest":"0.12.2+1","versions":[full_release("0.12.2")]}),
            with(json!({"version":"0.12.2+1"})),
            with(json!({"version":"0.12.2","build":-1})),
            with(json!({"version":"0.12.2","build":10000})),
            with(json!({"version":"0.12.2","build":"1"})),
            with(json!({"version":"0.12.2","build":1.5})),
            with(json!({"version":"0.12.2","build":2,"critical":"yes"})),
        ] {
            assert!(check_manifest(&bad).is_err(), "{bad}");
        }
    }

    fn notice() -> Value {
        json!({"id":"a","level":"warning","title":"T","expires":"2030-01-01T00:00:00Z"})
    }

    #[test]
    fn status_check_refuses_what_the_app_would_skip() {
        let ok = json!({"issued": 1_790_000_000u64, "notices": [notice()]});
        assert!(check_feed("status", &ok).is_ok());
        assert!(check_feed("status", &json!({"notices": []})).is_err(), "no issued");
        assert!(check_feed("status", &json!({"issued": 1})).is_err(), "no notices");
        for (key, val) in [
            ("expires", json!("2030-01-01")),
            ("level", json!("loud")),
            ("relay", json!("selfhosted")),
            ("platforms", json!(["win"])),
            ("platforms", json!([])),
            ("below", json!("0.12")),
            ("from", json!("0.12.2+x")),
            ("dismissible", json!("no")),
            ("id", json!("")),
        ] {
            let mut n = notice();
            n[key] = val.clone();
            let feed = json!({"issued": 1u64, "notices": [n]});
            assert!(check_feed("status", &feed).is_err(), "{key}={val}");
        }
        let twice = json!({"issued": 1u64, "notices": [notice(), notice()]});
        assert!(check_feed("status", &twice).is_err());
    }

    fn unix_now() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
    }

    /// A full release entry as every manifest since 0.10 carries it.
    fn full_release(v: &str) -> Value {
        let mut e = json!({"version": v});
        for k in [
            "url_windows", "url_windows_setup", "url_macos", "url_macos_dmg",
            "url_linux", "url_linux_targz", "url_android",
        ] {
            e[k] = json!(format!("https://h/{v}/{k}"));
        }
        for k in ["sha256_windows", "sha256_macos", "sha256_linux", "sha256_linux_targz"] {
            e[k] = json!("a".repeat(64));
        }
        e
    }

    /// Old apps and the website read the FIRST entry whose version is `latest`;
    /// a patch ahead of the full release strands every platform it lacks.
    #[test]
    fn review_sign_refuses_a_patch_entry_ahead_of_the_full_release() {
        let patch = json!({"version":"0.12.2","build":1,"url_windows":"https://h/w1.zip"});
        let ahead = json!({"latest":"0.12.2","versions":[patch.clone(), full_release("0.12.2")]});
        assert!(check_manifest(&ahead).is_err(), "a build entry sits where 0.12.1 and the website look first");
        let behind = json!({"latest":"0.12.2","versions":[full_release("0.12.2"), patch]});
        assert!(check_manifest(&behind).is_ok(), "{:?}", check_manifest(&behind));
    }

    #[test]
    fn the_first_entry_is_latest_and_carries_every_download() {
        let ok = json!({"latest":"0.12.2","versions":[full_release("0.12.2"), full_release("0.12.1")]});
        assert!(check_manifest(&ok).is_ok(), "{:?}", check_manifest(&ok));
        let older_first = json!({"latest":"0.12.2","versions":[full_release("0.12.1"), full_release("0.12.2")]});
        assert!(check_manifest(&older_first).is_err(), "versions[0] is not latest");
        assert!(check_manifest(&json!({"latest":"0.12.2","versions":[]})).is_err(), "no entries");
        let mut zero = full_release("0.12.2");
        zero["build"] = json!(0);
        assert!(check_manifest(&json!({"latest":"0.12.2","versions":[zero]})).is_ok(), "build 0 is the release");
        let mut patched = full_release("0.12.2");
        patched["build"] = json!(1);
        assert!(check_manifest(&json!({"latest":"0.12.2","versions":[patched]})).is_err(), "versions[0] carries a build");
        for key in [
            "url_windows", "url_windows_setup", "url_macos", "url_macos_dmg", "url_linux",
            "url_linux_targz", "url_android", "sha256_windows", "sha256_macos", "sha256_linux",
            "sha256_linux_targz",
        ] {
            let mut missing = full_release("0.12.2");
            missing.as_object_mut().unwrap().remove(key);
            assert!(check_manifest(&json!({"latest":"0.12.2","versions":[missing]})).is_err(), "no {key}");
            let mut empty = full_release("0.12.2");
            empty[key] = json!("");
            assert!(check_manifest(&json!({"latest":"0.12.2","versions":[empty]})).is_err(), "empty {key}");
        }
        let mut http = full_release("0.12.2");
        http["url_windows"] = json!("http://h/w.zip");
        assert!(check_manifest(&json!({"latest":"0.12.2","versions":[http]})).is_err(), "plain http");
    }

    /// Two entries with one (version, build) make the pick depend on sort order.
    #[test]
    fn review_sign_refuses_a_duplicate_version_and_build() {
        let b1 = json!({"version":"0.12.2","build":1,"url_windows":"https://h/b.zip"});
        let m = json!({"latest":"0.12.2","versions":[full_release("0.12.2"), b1.clone(), b1.clone()]});
        assert!(check_manifest(&m).is_err(), "duplicate 0.12.2+1 accepted");
        let mut zero = full_release("0.12.2");
        zero["build"] = json!(0);
        let m = json!({"latest":"0.12.2","versions":[full_release("0.12.2"), zero]});
        assert!(check_manifest(&m).is_err(), "0.12.2 and 0.12.2+0 are one release");
        let m = json!({"latest":"0.12.2","versions":[full_release("0.12.2"), full_release("0.12.02")]});
        assert!(check_manifest(&m).is_err(), "0.12.02 is 0.12.2");
        let m = json!({"latest":"0.12.2","versions":[full_release("0.12.2"), b1, full_release("0.12.1")]});
        assert!(check_manifest(&m).is_ok(), "{:?}", check_manifest(&m));
    }

    /// Every app keeps the highest `issued`; a stamp from the future would
    /// silence every later feed.
    #[test]
    fn review_feed_sign_refuses_an_issued_from_the_future() {
        let f = json!({"issued": unix_now() + 10 * 365 * 86_400, "notices": []});
        assert!(check_feed("status", &f).is_err(), "a stamp ten years ahead was accepted");
        let ms = json!({"issued": unix_now() * 1000, "notices": []});
        assert!(check_feed("status", &ms).is_err(), "a millisecond stamp was accepted");
        let near = json!({"issued": unix_now() + 600, "notices": []});
        assert!(check_feed("status", &near).is_ok(), "a clock a few minutes fast is fine");
        let over = json!({"issued": unix_now() + MAX_ISSUED_AHEAD_SECS + 60, "notices": []});
        assert!(check_feed("status", &over).is_err(), "past the window");
    }

    fn relay_feed(now: u64) -> Value {
        json!({
            "feed": "relay", "version": "0.12.2", "build": 0, "issued": now,
            "commit": "0123456789abcdef0123456789abcdef01234567",
            "artifacts": {
                "linux-x86_64": {
                    "url": "https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz",
                    "sha256": "a".repeat(64), "size": 1234
                },
                "linux-aarch64": {
                    "url": "https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-aarch64.tar.gz",
                    "sha256": "b".repeat(64), "size": 5678
                }
            }
        })
    }

    #[test]
    fn relay_feed_message_is_its_own_name() {
        let m = feed_message("relay", b"{}").unwrap();
        assert_eq!(m, b"hollow-feed-sig-v1\0relay\0{}".to_vec());
        assert_ne!(m, feed_message("status", b"{}").unwrap());
    }

    #[test]
    fn relay_tarball_names_carry_the_build_only_when_patched() {
        assert_eq!(relay_tarball_name("0.12.2", 0, "linux-x86_64"), "hollow-relay-0.12.2-linux-x86_64.tar.gz");
        assert_eq!(relay_tarball_name("0.12.2", 3, "linux-aarch64"), "hollow-relay-0.12.2-b3-linux-aarch64.tar.gz");
    }

    /// Installers act on this feed as root, so the signer refuses every feed
    /// shape the installer's library refuses (the tarballs are checked by
    /// `check_relay_tarball`, the box's own marks and clock only on the box).
    #[test]
    fn relay_check_refuses_what_an_installer_would_refuse() {
        let now = unix_now();
        assert!(check_feed("relay", &relay_feed(now)).is_ok(), "{:?}", check_feed("relay", &relay_feed(now)));
        let mut only_x86 = relay_feed(now);
        only_x86["artifacts"].as_object_mut().unwrap().remove("linux-aarch64");
        let warned = check_feed("relay", &only_x86).expect("x86_64 alone is a valid feed");
        assert!(!warned.is_empty(), "a feed without aarch64 should warn");
        let mut patched = relay_feed(now);
        patched["build"] = json!(2);
        patched["artifacts"]["linux-x86_64"]["url"] =
            json!("https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-b2-linux-x86_64.tar.gz");
        patched["artifacts"]["linux-aarch64"]["url"] =
            json!("https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-b2-linux-aarch64.tar.gz");
        assert!(check_feed("relay", &patched).is_ok(), "{:?}", check_feed("relay", &patched));

        let x86 = "/artifacts/linux-x86_64";
        let cases: Vec<(&str, Value)> = vec![
            ("/feed", json!("status")),
            ("/feed", json!(null)),
            ("/version", json!("0.12")),
            ("/version", json!("0.12.2+1")),
            ("/build", json!(-1)),
            ("/build", json!(10000)),
            ("/build", json!("0")),
            ("/build", json!(1.5)),
            ("/issued", json!(0)),
            ("/issued", json!(now + MAX_ISSUED_AHEAD_SECS + 60)),
            ("/issued", json!(now * 1000)),
            ("/issued", json!("1")),
            ("/commit", json!("0123456789abcdef0123456789abcdef0123456")),
            ("/commit", json!("0123456789ABCDEF0123456789ABCDEF01234567")),
            ("/commit", json!(5)),
            ("/commit", json!(null)),
            ("/artifacts", json!({})),
            ("/artifacts", json!([])),
        ];
        for (ptr, val) in cases {
            let mut f = relay_feed(now);
            *f.pointer_mut(ptr).unwrap() = val.clone();
            assert!(check_feed("relay", &f).is_err(), "{ptr}={val}");
        }
        for (field, val) in [
            ("url", json!("http://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz")),
            ("url", json!("https://evil.example/hollow/releases/hollow-relay-0.12.2-linux-x86_64.tar.gz")),
            ("url", json!("https://anonlisten.com/hollow/releases/hollow-relay-0.12.1-linux-x86_64.tar.gz")),
            ("url", json!("https://anonlisten.com/hollow/releases/hollow-relay-0.12.2-linux-aarch64.tar.gz")),
            ("url", json!("https://anonlisten.com/hollow/releases/../hollow-relay-0.12.2-linux-x86_64.tar.gz")),
            ("sha256", json!("A".repeat(64))),
            ("sha256", json!("a".repeat(63))),
            ("sha256", json!(1)),
            ("size", json!(0)),
            ("size", json!(MAX_RELAY_TARBALL_BYTES + 1)),
            ("size", json!("1234")),
        ] {
            let mut f = relay_feed(now);
            f.pointer_mut(x86).unwrap()[field] = val.clone();
            assert!(check_feed("relay", &f).is_err(), "{field}={val}");
        }
        let mut no_x86 = relay_feed(now);
        no_x86["artifacts"].as_object_mut().unwrap().remove("linux-x86_64");
        assert!(check_feed("relay", &no_x86).is_err(), "x86_64 is required");
        let mut extra = relay_feed(now);
        extra["artifacts"]["linux-riscv64"] = extra["artifacts"]["linux-x86_64"].clone();
        assert!(check_feed("relay", &extra).is_err(), "unknown arch");
        assert!(check_feed("relay", &json!([])).is_err(), "not an object");

        // Each with URLs that match it, so only the rule under test refuses.
        for (version, build) in [("0.12", 0u64), ("0.12.2.1", 0), ("0.12.2", 10000)] {
            let mut f = relay_feed(now);
            f["version"] = json!(version);
            f["build"] = json!(build);
            for arch in RELAY_ARCHES {
                f["artifacts"][*arch]["url"] =
                    json!(format!("{RELAY_RELEASE_BASE}{}", relay_tarball_name(version, build, arch)));
            }
            assert!(check_feed("relay", &f).is_err(), "version {version} build {build}");
        }
        let mut riscv = relay_feed(now);
        riscv["artifacts"]["linux-riscv64"] = json!({
            "url": format!("{RELAY_RELEASE_BASE}{}", relay_tarball_name("0.12.2", 0, "linux-riscv64")),
            "sha256": "c".repeat(64), "size": 1
        });
        assert!(check_feed("relay", &riscv).is_err(), "unknown arch with a matching url");
    }

    /// relay-uws/test/release_feed/corpus: crafted tarballs the installer
    /// library's suite reads too, each with the verdict both sides must give.
    const CORPUS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../relay-uws/test/release_feed/corpus/");

    fn corpus_cases() -> Vec<(String, bool)> {
        let text = std::fs::read_to_string(format!("{CORPUS}cases.txt")).expect("the shared corpus");
        text.lines()
            .filter(|l| !l.starts_with('#') && !l.is_empty())
            .map(|l| {
                let mut w = l.split(' ');
                let name = w.next().unwrap().to_string();
                (name, w.next() == Some("accept"))
            })
            .collect()
    }

    fn corpus(name: &str) -> Result<RelayTarball, String> {
        let bytes = std::fs::read(format!("{CORPUS}{name}.tar.gz")).expect(name);
        check_relay_tarball(&bytes, "linux-x86_64", "0.12.2", 0)
    }

    #[test]
    fn the_signer_gives_every_shared_corpus_case_the_installers_verdict() {
        let cases = corpus_cases();
        assert!(cases.len() >= 20, "the corpus lost cases");
        for (name, accept) in cases {
            let got = corpus(&name);
            assert_eq!(got.is_ok(), accept, "{name}: {got:?}");
        }
    }

    #[test]
    fn check_relay_tarball_refuses_a_pax_size_over_the_setup_cap() {
        corpus("pax_size_honoured").expect("a pax size within the cap");
        let e = corpus("pax_size_over_cap").unwrap_err();
        assert!(e.contains("over the 1048576"), "{e}");
    }

    #[test]
    fn check_relay_tarball_refuses_trailing_bytes_after_gzip() {
        corpus("control").expect("the control");
        for case in ["trailing_bytes", "trailing_zeros"] {
            let e = corpus(case).unwrap_err();
            assert!(e.contains("bytes after it"), "{case}: {e}");
        }
    }

    #[test]
    fn check_relay_tarball_refuses_a_second_gzip_member() {
        corpus("empty_first_member").expect("an empty member before the tarball is the same stream");
        for case in ["second_member_link", "second_member_file", "empty_last_member"] {
            let e = corpus(case).unwrap_err();
            assert!(e.contains("second gzip member"), "{case}: {e}");
        }
    }

    #[test]
    fn check_relay_tarball_refuses_an_mtime_tar_cannot_list() {
        for case in ["mtime_last_ok", "mtime_base256", "pax_mtime_fraction"] {
            corpus(case).unwrap_or_else(|e| panic!("{case}: {e}"));
        }
        for case in ["mtime_unlistable", "mtime_first_over", "pax_mtime_over"] {
            let e = corpus(case).unwrap_err();
            assert!(e.contains("past 2242"), "{case}: {e}");
        }
        for case in ["pax_mtime_negative", "pax_mtime_bad_fraction"] {
            let e = corpus(case).unwrap_err();
            assert!(e.contains("pax mtime"), "{case}: {e}");
        }
    }

    #[test]
    fn the_setup_needs_every_library_install_sh_sources() {
        let e = corpus("missing_sourced_lib").unwrap_err();
        assert!(e.contains("misses setup/deploy/lib/ui.sh"), "{e}");
        corpus("unsourced_lib_missing_ok").expect("a library nothing sources");
        for (case, need) in [("missing_lockfile", "package-lock.json"), ("missing_package_json", "package.json")] {
            let e = corpus(case).unwrap_err();
            assert!(e.contains(&format!("misses setup/push-sidecar/{need}")), "{case}: {e}");
        }
        let e = corpus("missing_port_lock").unwrap_err();
        assert!(e.contains("misses setup/deploy/turn-port-lock.sh"), "{e}");
        let install = "#!/bin/bash\n. \"$DEPLOY/lib/common.sh\"\n  . \"$DEPLOY/lib/indented.sh\"\n. \"$DEPLOY/lib/a-b.sh\"\n\
            . \"$DEPLOY/lib/crlf.sh\"\r\n# . \"$DEPLOY/lib/commented.sh\"\n. \"$DEPLOY/lib/ui.sh\"";
        assert_eq!(sourced_libs(install), ["setup/deploy/lib/common.sh", "setup/deploy/lib/ui.sh"]);
    }

    /// A sparse member's bytes on the wire are not the file tar writes, so
    /// the signer refuses one rather than check other bytes than land.
    #[test]
    fn check_relay_tarball_refuses_a_sparse_member() {
        let raw = std::fs::read(format!("{CORPUS}control.tar.gz")).unwrap();
        let mut inner = Vec::new();
        std::io::Read::read_to_end(&mut flate2::read::GzDecoder::new(raw.as_slice()), &mut inner).unwrap();
        let end = inner.len() - 1024;
        let mut b = tar::Builder::new(Vec::new());
        b.append_pax_extensions([("GNU.sparse.major", b"1".as_slice()), ("GNU.sparse.minor", b"0".as_slice())]).unwrap();
        let mut h = tar::Header::new_ustar();
        h.set_path("setup/deploy/s.sh").unwrap();
        h.set_size(4);
        h.set_mode(0o644);
        h.set_mtime(1_761_134_400);
        h.set_cksum();
        b.append(&h, &b"# s\n"[..]).unwrap();
        let mut tarball = inner[..end].to_vec();
        tarball.extend(b.into_inner().unwrap());
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        std::io::Write::write_all(&mut gz, &tarball).unwrap();
        let bytes = gz.finish().unwrap();
        let e = check_relay_tarball(&bytes, "linux-x86_64", "0.12.2", 0).unwrap_err();
        assert!(e.contains("sparse"), "{e}");
    }

    /// The repository's own install.sh: every library it sources is one the
    /// rule finds, so a release never ships without one.
    #[test]
    fn the_rule_finds_every_library_the_real_install_sh_sources() {
        const INSTALL: &str = include_str!("../../../relay-uws/install.sh");
        let found = sourced_libs(INSTALL);
        let sourced = INSTALL.lines().filter(|l| l.trim_start().starts_with(". ")).count();
        assert!(found.len() >= 11, "{found:?}");
        assert_eq!(found.len(), sourced, "a source line the rule does not read");
        assert!(found.iter().any(|f| f == "setup/deploy/lib/common.sh"));
    }

    #[test]
    fn a_relay_feed_over_the_installer_cap_is_never_signed() {
        assert!(check_size("relay", RELAY_CAP_BYTES + 1).is_err());
        assert!(check_size("relay", RELAY_CAP_BYTES).is_ok());
    }

    /// The app refuses a feed over its cap without parsing it, so one is never signed.
    #[test]
    fn a_feed_over_the_app_cap_is_never_signed() {
        assert!(check_size("status", STATUS_CAP_BYTES + 1).is_err());
        assert!(check_size("status", STATUS_CAP_BYTES).is_ok());
        assert!(check_size("news", NEWS_CAP_BYTES + 1).is_err());
        assert!(check_size("news", NEWS_CAP_BYTES).is_ok());
        assert!(check_size("manifest", MANIFEST_CAP_BYTES + 1).is_err());
        assert!(check_size("manifest", MANIFEST_CAP_BYTES).is_ok());
    }
}
