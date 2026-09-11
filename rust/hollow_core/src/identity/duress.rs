//! A second secret typed at the SAME prompt as the real one, which never unlocks
//! and always destroys. `identity.duress` shares `identity.key`'s HKEYV1 layout with
//! its OWN salt and EXISTS whenever password protection does (random bytes under a
//! random key when unset), so disk and timing look identical either way. The scope
//! rides the slot because `unlock_identity` runs BEFORE the database opens.

use std::path::PathBuf;

use super::encryption;

/// Tells a real duress code from a lucky decrypt of random bytes.
const TAG: &[u8; 8] = b"HDURESS1";
const MARKER_LEN: usize = 32;
/// FIXED, so the dummy slot and a configured one are the same size.
const PLAINTEXT_LEN: usize = 8 + MARKER_LEN + 2;

pub(crate) const SCOPE_DEVICE: &str = "device";
pub(crate) const SCOPE_DEVICE_REVOKE: &str = "device_revoke";
pub(crate) const SCOPE_IDENTITY: &str = "identity";

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct DuressConfig {
    pub scope: String,
    pub notify_friends: bool,
}

pub(crate) fn slot_path() -> Result<PathBuf, String> {
    Ok(super::data_dir()?.join("identity.duress"))
}

/// `Err` outside the three scopes: a typo must not become a local-only wipe.
pub(crate) fn scope_byte(scope: &str) -> Result<u8, String> {
    match scope {
        SCOPE_DEVICE => Ok(0),
        SCOPE_DEVICE_REVOKE => Ok(1),
        SCOPE_IDENTITY => Ok(2),
        _ => Err("Unknown duress scope".into()),
    }
}

fn scope_name(byte: u8) -> &'static str {
    match byte {
        1 => SCOPE_DEVICE_REVOKE,
        2 => SCOPE_IDENTITY,
        _ => SCOPE_DEVICE,
    }
}

fn random(buf: &mut [u8]) -> Result<(), String> {
    getrandom::fill(buf).map_err(|e| format!("RNG error: {e}"))
}

fn write_slot(plaintext: &[u8], key: &[u8; 32], salt: &[u8; 16]) -> Result<(), String> {
    let blob = encryption::encrypt_identity(plaintext, key, salt, true, false)?;
    std::fs::write(slot_path()?, &blob)
        .map_err(|e| format!("Failed to write the duress slot: {e}"))
}

pub(crate) fn set_code(code: &str, scope: &str, notify_friends: bool) -> Result<(), String> {
    let scope = scope_byte(scope)?;
    let mut plaintext = [0u8; PLAINTEXT_LEN];
    plaintext[..8].copy_from_slice(TAG);
    random(&mut plaintext[8..8 + MARKER_LEN])?;
    plaintext[8 + MARKER_LEN] = scope;
    plaintext[9 + MARKER_LEN] = u8::from(notify_friends);

    let mut salt = [0u8; 16];
    random(&mut salt)?;
    let key = encryption::derive_wrapping_key_from_password(code, &salt)?;
    write_slot(&plaintext, &key, &salt)
}

/// A slot nothing can ever open. Same size, same layout, random key.
pub(crate) fn set_dummy() -> Result<(), String> {
    let mut plaintext = [0u8; PLAINTEXT_LEN];
    random(&mut plaintext)?;
    let mut salt = [0u8; 16];
    random(&mut salt)?;
    let mut key = [0u8; 32];
    random(&mut key)?;
    let out = write_slot(&plaintext, &key, &salt);
    key.fill(0);
    out
}

pub(crate) fn remove() -> Result<(), String> {
    let path = slot_path()?;
    if path.exists() {
        std::fs::remove_file(&path)
            .map_err(|e| format!("Failed to remove the duress slot: {e}"))?;
    }
    Ok(())
}

/// ALWAYS derives exactly once, slot present or not, opening or not: the cost of
/// this call is what hides a duress code from a stopwatch.
pub(crate) fn probe(code: &str) -> Option<DuressConfig> {
    let blob = slot_path().ok().and_then(|p| std::fs::read(p).ok());
    let salt = match blob.as_deref().map(encryption::detect_format) {
        Some(Ok(encryption::IdentityFormat::Encrypted { salt, .. })) => salt,
        // No slot, or an unreadable one: derive against a throwaway salt anyway.
        _ => [0u8; 16],
    };
    let key = encryption::derive_wrapping_key_from_password(code, &salt).ok()?;
    let plaintext = encryption::decrypt_blob(blob.as_deref()?, &key).ok()?;
    if plaintext.len() != PLAINTEXT_LEN || plaintext[..8] != *TAG {
        return None;
    }
    Some(DuressConfig {
        scope: scope_name(plaintext[8 + MARKER_LEN]).to_string(),
        notify_friends: plaintext[9 + MARKER_LEN] == 1,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `HOLLOW_DATA_DIR` is shared with the at-rest tests.
    fn guard() -> std::sync::MutexGuard<'static, ()> {
        crate::node::resolver::test_lock()
    }

    fn temp_root() -> tempfile::TempDir {
        let tmp = tempfile::tempdir().expect("tempdir");
        // SAFETY: serialized by `guard()`.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        tmp
    }

    #[test]
    fn duress_slot_opens_only_for_its_code_and_carries_the_scope() {
        let _g = guard();
        let _tmp = temp_root();
        set_code("burn it", SCOPE_IDENTITY, true).unwrap();
        let cfg = probe("burn it").expect("the duress code must open its own slot");
        assert_eq!(cfg.scope, SCOPE_IDENTITY);
        assert!(cfg.notify_friends);
        assert!(probe("something else").is_none());
    }

    #[test]
    fn duress_slot_dummy_when_unset_is_indistinguishable_in_size() {
        let _g = guard();
        let _tmp = temp_root();
        set_dummy().unwrap();
        let dummy_len = std::fs::metadata(slot_path().unwrap()).unwrap().len();
        assert!(probe("anything").is_none());

        set_code("burn it", SCOPE_DEVICE, false).unwrap();
        let real_len = std::fs::metadata(slot_path().unwrap()).unwrap().len();
        assert_eq!(dummy_len, real_len, "the two slots must be byte-identical in size");
    }

    #[test]
    fn an_unknown_scope_is_refused() {
        assert!(scope_byte("everything").is_err());
    }
}
