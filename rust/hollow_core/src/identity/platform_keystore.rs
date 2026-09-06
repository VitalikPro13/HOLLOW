use std::path::PathBuf;

fn dpapi_blob_path() -> Result<PathBuf, String> {
    Ok(super::keys::data_dir()?.join("identity.dpapi"))
}

/// Per-profile slot suffix: 16 hex chars of SHA-256 over the data dir path.
///
/// One machine-global keychain slot CANNOT serve two profiles: enabling protection in
/// profile B overwrote A's wrapping key, and A's next launch retrieved the FOREIGN key
/// and funnelled the user into mnemonic recovery, which rotates the device key and
/// discards the MLS identity and groups. Each profile gets its own suffixed slot; the
/// legacy unsuffixed slot and the Windows DPAPI blob stay as retrieve fallbacks, and
/// the unlock path self-heals the slots with whichever candidate actually decrypts.
fn profile_slot_suffix() -> Option<String> {
    use sha2::{Digest, Sha256};
    let dir = super::keys::data_dir().ok()?;
    let mut h = Sha256::new();
    h.update(dir.to_string_lossy().as_bytes());
    let out = h.finalize();
    Some(out[..8].iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(windows)]
fn windows_targets() -> Vec<String> {
    const BASE: &str = "com.hollow.identity.wrapping_key";
    let mut targets = Vec::new();
    if let Some(sfx) = profile_slot_suffix() {
        targets.push(format!("{BASE}.{sfx}"));
    }
    targets.push(BASE.to_string());
    targets
}

#[cfg(target_os = "macos")]
fn mac_accounts() -> Vec<String> {
    const BASE: &str = "wrapping_key";
    let mut accounts = Vec::new();
    if let Some(sfx) = profile_slot_suffix() {
        accounts.push(format!("{BASE}.{sfx}"));
    }
    accounts.push(BASE.to_string());
    accounts
}

pub(crate) fn is_available() -> bool {
    cfg!(any(windows, target_os = "macos"))
}

#[cfg(windows)]
mod win {
    use std::ptr;

    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE,
        CRED_TYPE_GENERIC,
    };
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB,
    };

    fn to_wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    // ── Primary: Windows Credential Manager ──

    pub(crate) fn cred_store(target_name: &str, key: &[u8]) -> Result<(), String> {
        let target = to_wide(target_name);
        let user = to_wide("hollow");

        let cred = CREDENTIALW {
            Flags: 0,
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_ptr() as *mut _,
            Comment: ptr::null_mut(),
            LastWritten: windows_sys::Win32::Foundation::FILETIME {
                dwLowDateTime: 0,
                dwHighDateTime: 0,
            },
            CredentialBlobSize: key.len() as u32,
            CredentialBlob: key.as_ptr() as *mut _,
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            AttributeCount: 0,
            Attributes: ptr::null_mut(),
            TargetAlias: ptr::null_mut(),
            UserName: user.as_ptr() as *mut _,
        };

        let ok = unsafe { CredWriteW(&cred, 0) };
        if ok == 0 {
            return Err("CredWriteW failed: could not store key in Credential Manager".into());
        }
        Ok(())
    }

    pub(crate) fn cred_retrieve(target_name: &str) -> Result<Option<Vec<u8>>, String> {
        let target = to_wide(target_name);
        let mut pcred: *mut CREDENTIALW = ptr::null_mut();

        let ok = unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut pcred) };
        if ok == 0 {
            return Ok(None);
        }

        let result = unsafe {
            let cred = &*pcred;
            if cred.CredentialBlobSize == 0 || cred.CredentialBlob.is_null() {
                CredFree(pcred as *mut _);
                return Ok(None);
            }
            let blob =
                std::slice::from_raw_parts(cred.CredentialBlob, cred.CredentialBlobSize as usize)
                    .to_vec();
            CredFree(pcred as *mut _);
            blob
        };

        Ok(Some(result))
    }

    pub(crate) fn cred_delete(target_name: &str) -> Result<(), String> {
        let target = to_wide(target_name);
        let ok = unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) };
        if ok == 0 {
            // Not found is fine
        }
        Ok(())
    }

    // ── Fallback: DPAPI blob on disk ──

    pub(crate) fn dpapi_protect(data: &[u8]) -> Result<Vec<u8>, String> {
        let input = CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: ptr::null_mut(),
        };

        let ok = unsafe {
            CryptProtectData(
                &input,
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                0,
                &mut output,
            )
        };

        if ok == 0 {
            return Err("DPAPI CryptProtectData failed".into());
        }

        let result =
            unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
        unsafe {
            LocalFree(output.pbData as *mut _);
        }
        Ok(result)
    }

    pub(crate) fn dpapi_unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
        let input = CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: ptr::null_mut(),
        };

        let ok = unsafe {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                0,
                &mut output,
            )
        };

        if ok == 0 {
            return Err("DPAPI blob decryption failed".into());
        }

        let result =
            unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
        unsafe {
            LocalFree(output.pbData as *mut _);
        }
        Ok(result)
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use security_framework::item::{ItemClass, ItemSearchOptions, Limit, SearchResult};
    use security_framework::passwords::{delete_generic_password, set_generic_password};

    const SERVICE: &str = "com.hollow.identity";

    pub(crate) fn store(account: &str, key: &[u8]) -> Result<(), String> {
        let _ = delete_generic_password(SERVICE, account);
        set_generic_password(SERVICE, account, key)
            .map_err(|e| format!("macOS Keychain store failed: {e}"))
    }

    pub(crate) fn retrieve(account: &str) -> Result<Option<Vec<u8>>, String> {
        let mut search = ItemSearchOptions::new();
        search
            .class(ItemClass::generic_password())
            .service(SERVICE)
            .account(account)
            .limit(Limit::Max(1))
            .load_data(true);

        match search.search() {
            Ok(results) => {
                // With `.load_data(true)`, a matching item is returned as
                // `SearchResult::Data`. Other variants mean no usable payload.
                match results.into_iter().next() {
                    Some(SearchResult::Data(data)) => Ok(Some(data)),
                    _ => Ok(None),
                }
            }
            Err(e) if e.code() == -25300 => Ok(None), // errSecItemNotFound
            Err(e) => Err(format!("macOS Keychain retrieve failed: {e}")),
        }
    }

    pub(crate) fn delete(account: &str) -> Result<(), String> {
        match delete_generic_password(SERVICE, account) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == -25300 => Ok(()), // not found is fine
            Err(e) => Err(format!("macOS Keychain delete failed: {e}")),
        }
    }
}

pub(crate) fn store_key(key: &[u8]) -> Result<(), String> {
    #[cfg(windows)]
    {
        // The per-profile slot is authoritative; the legacy machine-global slot is kept
        // written for older builds and the DPAPI blob is the on-disk fallback.
        let targets = windows_targets();
        let (primary, rest) = targets.split_first().expect("targets never empty");
        win::cred_store(primary, key)?;
        for t in rest {
            let _ = win::cred_store(t, key);
        }
        if let Ok(blob) = win::dpapi_protect(key) {
            let path = dpapi_blob_path()?;
            let _ = std::fs::write(&path, &blob);
        }
        Ok(())
    }
    #[cfg(target_os = "macos")]
    {
        let accounts = mac_accounts();
        let (primary, rest) = accounts.split_first().expect("accounts never empty");
        mac::store(primary, key)?;
        for a in rest {
            let _ = mac::store(a, key);
        }
        Ok(())
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        let _ = key;
        Err("OS keychain not available on this platform".into())
    }
}

/// Every stored key candidate, most-authoritative first. The caller MUST verify a
/// candidate actually decrypts before trusting it: with several profiles on one
/// machine the legacy slot routinely holds a DIFFERENT profile's key.
pub(crate) fn retrieve_key_candidates() -> Result<Vec<Vec<u8>>, String> {
    #[allow(unused_mut)]
    let mut candidates: Vec<Vec<u8>> = Vec::new();
    #[cfg(windows)]
    {
        for t in windows_targets() {
            if let Ok(Some(key)) = win::cred_retrieve(&t) {
                if !candidates.contains(&key) {
                    candidates.push(key);
                }
            }
        }
        if let Ok(path) = dpapi_blob_path() {
            if path.exists() {
                if let Ok(blob) = std::fs::read(&path) {
                    if let Ok(plaintext) = win::dpapi_unprotect(&blob) {
                        if !candidates.contains(&plaintext) {
                            candidates.push(plaintext);
                        }
                    }
                }
            }
        }
    }
    #[cfg(target_os = "macos")]
    {
        for a in mac_accounts() {
            if let Ok(Some(key)) = mac::retrieve(&a) {
                if !candidates.contains(&key) {
                    candidates.push(key);
                }
            }
        }
    }
    Ok(candidates)
}

/// First (most-authoritative) candidate only. Production unlock goes through
/// `retrieve_key_candidates` + decrypt verification instead — see
/// `api::identity::keychain_key_that_decrypts`.
#[allow(dead_code)]
pub(crate) fn retrieve_key() -> Result<Option<Vec<u8>>, String> {
    Ok(retrieve_key_candidates()?.into_iter().next())
}

#[allow(dead_code)]
pub(crate) fn delete_key() -> Result<(), String> {
    #[cfg(windows)]
    {
        for t in windows_targets() {
            let _ = win::cred_delete(&t);
        }
        let path = dpapi_blob_path()?;
        if path.exists() {
            let _ = std::fs::remove_file(&path);
        }
        Ok(())
    }
    #[cfg(target_os = "macos")]
    {
        for a in mac_accounts() {
            let _ = mac::delete(&a);
        }
        Ok(())
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_available_matches_platform() {
        let available = is_available();
        if cfg!(any(windows, target_os = "macos")) {
            assert!(available);
        } else {
            assert!(!available);
        }
    }

    #[cfg(windows)]
    #[test]
    fn dpapi_round_trip() {
        let secret = b"hollow-test-wrapping-key-32bytes!";
        let protected = win::dpapi_protect(secret).unwrap();
        assert_ne!(protected, secret.to_vec());
        let recovered = win::dpapi_unprotect(&protected).unwrap();
        assert_eq!(recovered, secret.to_vec());
    }

    #[cfg(windows)]
    #[test]
    fn dpapi_protect_produces_different_bytes() {
        let secret = b"hollow-test-wrapping-key-32bytes!";
        let protected = win::dpapi_protect(secret).unwrap();
        assert_ne!(protected, secret.to_vec());
        assert!(protected.len() > secret.len());
    }

    #[cfg(windows)]
    #[test]
    fn dpapi_empty_input_round_trips() {
        let secret = b"";
        let protected = win::dpapi_protect(secret).unwrap();
        let recovered = win::dpapi_unprotect(&protected).unwrap();
        assert_eq!(recovered, secret.to_vec());
    }

    #[cfg(windows)]
    #[test]
    fn dpapi_large_input_round_trips() {
        let secret = vec![0xAB; 4096];
        let protected = win::dpapi_protect(&secret).unwrap();
        let recovered = win::dpapi_unprotect(&protected).unwrap();
        assert_eq!(recovered, secret);
    }

    /// Both round-trip tests store and delete the SAME named Windows credential, so in
    /// parallel they race: serialize them.
    #[cfg(windows)]
    fn cred_test_lock() -> std::sync::MutexGuard<'static, ()> {
        static CRED_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        CRED_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(windows)]
    #[test]
    fn credential_manager_round_trip() {
        let _lock = cred_test_lock();
        // Dedicated test slot — never the real wrapping-key targets.
        const TARGET: &str = "com.hollow.identity.test_slot";
        let secret = b"hollow-test-cred-mgr-32bytes!!!!";
        win::cred_store(TARGET, secret).unwrap();
        let retrieved = win::cred_retrieve(TARGET).unwrap();
        assert_eq!(retrieved, Some(secret.to_vec()));
        win::cred_delete(TARGET).unwrap();
        let after_delete = win::cred_retrieve(TARGET).unwrap();
        assert_eq!(after_delete, None);
    }

    /// Snapshot of the REAL wrapping-key slots + DPAPI blob, restored on
    /// drop. The store/retrieve tests exercise the real slot names and used
    /// to nuke a keychain-protected dev profile's key on every `cargo test`.
    #[cfg(windows)]
    struct SlotGuard {
        slots: Vec<(String, Option<Vec<u8>>)>,
        blob: Option<Vec<u8>>,
    }

    #[cfg(windows)]
    impl SlotGuard {
        fn capture() -> Self {
            let slots = windows_targets()
                .into_iter()
                .map(|t| {
                    let v = win::cred_retrieve(&t).unwrap_or(None);
                    (t, v)
                })
                .collect();
            let blob = dpapi_blob_path().ok().and_then(|p| std::fs::read(p).ok());
            Self { slots, blob }
        }
    }

    #[cfg(windows)]
    impl Drop for SlotGuard {
        fn drop(&mut self) {
            for (t, v) in &self.slots {
                match v {
                    Some(v) => { let _ = win::cred_store(t, v); }
                    None => { let _ = win::cred_delete(t); }
                }
            }
            if let Ok(p) = dpapi_blob_path() {
                match &self.blob {
                    Some(b) => { let _ = std::fs::write(p, b); }
                    None => { let _ = std::fs::remove_file(p); }
                }
            }
        }
    }

    #[cfg(windows)]
    #[test]
    fn dual_store_retrieve() {
        let _lock = cred_test_lock();
        let _guard = SlotGuard::capture();
        let secret = vec![0x42u8; 32];
        store_key(&secret).unwrap();
        let retrieved = retrieve_key().unwrap();
        assert_eq!(retrieved, Some(secret));
        delete_key().unwrap();
        let after_delete = retrieve_key().unwrap();
        assert_eq!(after_delete, None);
    }

    /// Two profiles on one machine: the per-profile slot must outrank the
    /// legacy machine-global slot in the candidate order (issue #47 → #27).
    #[cfg(windows)]
    #[test]
    fn per_profile_slot_outranks_legacy() {
        let _lock = cred_test_lock();
        let _guard = SlotGuard::capture();
        let targets = windows_targets();
        assert!(targets.len() >= 2, "profile suffix must resolve");
        let key_profile = vec![0xA1u8; 32];
        let key_legacy = vec![0xB2u8; 32];
        win::cred_store(&targets[0], &key_profile).unwrap();
        win::cred_store(&targets[1], &key_legacy).unwrap();
        let cands = retrieve_key_candidates().unwrap();
        assert_eq!(cands.first(), Some(&key_profile),
            "per-profile slot must be the first candidate");
        assert!(cands.contains(&key_legacy),
            "legacy slot must remain a fallback candidate");
        delete_key().unwrap();
    }
}
