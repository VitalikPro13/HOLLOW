use std::path::PathBuf;

fn dpapi_blob_path() -> Result<PathBuf, String> {
    Ok(super::keys::data_dir()?.join("identity.dpapi"))
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

    const CRED_TARGET: &str = "com.hollow.identity.wrapping_key";

    fn to_wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    // ── Primary: Windows Credential Manager ──

    pub(crate) fn cred_store(key: &[u8]) -> Result<(), String> {
        let target = to_wide(CRED_TARGET);
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
            return Err("CredWriteW failed — could not store key in Credential Manager".into());
        }
        Ok(())
    }

    pub(crate) fn cred_retrieve() -> Result<Option<Vec<u8>>, String> {
        let target = to_wide(CRED_TARGET);
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

    pub(crate) fn cred_delete() -> Result<(), String> {
        let target = to_wide(CRED_TARGET);
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
    const ACCOUNT: &str = "wrapping_key";

    pub(crate) fn store(key: &[u8]) -> Result<(), String> {
        let _ = delete_generic_password(SERVICE, ACCOUNT);
        set_generic_password(SERVICE, ACCOUNT, key)
            .map_err(|e| format!("macOS Keychain store failed: {e}"))
    }

    pub(crate) fn retrieve() -> Result<Option<Vec<u8>>, String> {
        let mut search = ItemSearchOptions::new();
        search
            .class(ItemClass::generic_password())
            .service(SERVICE)
            .account(ACCOUNT)
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

    pub(crate) fn delete() -> Result<(), String> {
        match delete_generic_password(SERVICE, ACCOUNT) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == -25300 => Ok(()), // not found is fine
            Err(e) => Err(format!("macOS Keychain delete failed: {e}")),
        }
    }
}

pub(crate) fn store_key(key: &[u8]) -> Result<(), String> {
    #[cfg(windows)]
    {
        // Primary: Credential Manager
        win::cred_store(key)?;
        // Fallback: DPAPI blob on disk
        if let Ok(blob) = win::dpapi_protect(key) {
            let path = dpapi_blob_path()?;
            let _ = std::fs::write(&path, &blob);
        }
        Ok(())
    }
    #[cfg(target_os = "macos")]
    {
        mac::store(key)
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        let _ = key;
        Err("OS keychain not available on this platform".into())
    }
}

pub(crate) fn retrieve_key() -> Result<Option<Vec<u8>>, String> {
    #[cfg(windows)]
    {
        // Primary: Credential Manager
        if let Ok(Some(key)) = win::cred_retrieve() {
            return Ok(Some(key));
        }
        // Fallback: DPAPI blob on disk
        let path = dpapi_blob_path()?;
        if path.exists() {
            if let Ok(blob) = std::fs::read(&path) {
                if let Ok(plaintext) = win::dpapi_unprotect(&blob) {
                    // Migrate: re-store in Credential Manager for next time
                    let _ = win::cred_store(&plaintext);
                    return Ok(Some(plaintext));
                }
            }
        }
        Ok(None)
    }
    #[cfg(target_os = "macos")]
    {
        mac::retrieve()
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        Ok(None)
    }
}

#[allow(dead_code)]
pub(crate) fn delete_key() -> Result<(), String> {
    #[cfg(windows)]
    {
        let _ = win::cred_delete();
        let path = dpapi_blob_path()?;
        if path.exists() {
            let _ = std::fs::remove_file(&path);
        }
        Ok(())
    }
    #[cfg(target_os = "macos")]
    {
        mac::delete()
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

    /// Both round-trip tests below store/delete the SAME named Windows
    /// credential — run in parallel they race (one deletes while the other
    /// asserts; a real intermittent CI failure). Serialize them.
    #[cfg(windows)]
    fn cred_test_lock() -> std::sync::MutexGuard<'static, ()> {
        static CRED_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        CRED_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(windows)]
    #[test]
    fn credential_manager_round_trip() {
        let _lock = cred_test_lock();
        let secret = b"hollow-test-cred-mgr-32bytes!!!!";
        win::cred_store(secret).unwrap();
        let retrieved = win::cred_retrieve().unwrap();
        assert_eq!(retrieved, Some(secret.to_vec()));
        win::cred_delete().unwrap();
        let after_delete = win::cred_retrieve().unwrap();
        assert_eq!(after_delete, None);
    }

    #[cfg(windows)]
    #[test]
    fn dual_store_retrieve() {
        let _lock = cred_test_lock();
        let secret = vec![0x42u8; 32];
        store_key(&secret).unwrap();
        let retrieved = retrieve_key().unwrap();
        assert_eq!(retrieved, Some(secret));
        delete_key().unwrap();
        let after_delete = retrieve_key().unwrap();
        assert_eq!(after_delete, None);
    }
}
