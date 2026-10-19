//! The release feeds next to the manifest (`status.json`, `news.json`) and the
//! shape checks run before anything is signed.
//!
//! A feed signature covers [`feed_message`], never the bare bytes: the manifest
//! signature is over the bare manifest, so the prefix keeps a feed signature from
//! ever passing as a manifest signature or as the other feed's. Mirrors
//! `feed_message` in hollow_core/src/api/updater.rs; the KAT in both crates pins it.

use serde_json::Value;

/// The feeds a signature may name.
pub const FEEDS: &[&str] = &["status", "news"];

const FEED_SIG_CONTEXT: &[u8] = b"hollow-feed-sig-v1\0";

/// The highest build number a version entry may carry (the app's `MAX_BUILD`).
pub const MAX_BUILD: u64 = 9999;

/// The app's read caps (`fetch_cap` in updater.rs): a body over its cap is
/// refused unparsed, so nothing over it is ever signed.
pub const STATUS_CAP_BYTES: usize = 64 * 1024;
pub const NEWS_CAP_BYTES: usize = 256 * 1024;
pub const MANIFEST_CAP_BYTES: usize = 1024 * 1024;

/// How far past the signer's clock `issued` may sit; apps keep the highest
/// stamp they saw, so a stamp from the future would hide every later feed.
pub const MAX_ISSUED_AHEAD_SECS: u64 = 3600;

/// Refuses a body the app would refuse for its size (`status`, `news`, `manifest`).
pub fn check_size(what: &str, len: usize) -> Result<(), String> {
    let cap = match what {
        "status" => STATUS_CAP_BYTES,
        "news" => NEWS_CAP_BYTES,
        "manifest" => MANIFEST_CAP_BYTES,
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
        _ => Err(format!("unknown feed {feed:?}")),
    }
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
    let issued = obj
        .get("issued")
        .and_then(Value::as_u64)
        .filter(|n| *n > 0)
        .ok_or("status.json needs `issued` (Unix seconds); feed-sign --stamp writes it")?;
    if issued > now.saturating_add(MAX_ISSUED_AHEAD_SECS) {
        return Err(format!(
            "issued {issued} is more than {MAX_ISSUED_AHEAD_SECS} s past this clock ({now}); apps would hide every later feed"
        ));
    }
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
