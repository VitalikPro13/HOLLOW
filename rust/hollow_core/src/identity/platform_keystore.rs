//! The OS keystore slots that hold an identity's wrapping key: one slot per profile
//! (named by a hash of its data root), the machine-wide legacy slot builds before
//! per-profile slots wrote, and on Windows a DPAPI blob inside the root.
//!
//! The legacy slot is READ as a fallback and never written: with several profiles on
//! one machine it holds whichever profile wrote it last, so writing or deleting it on
//! behalf of one profile can take another profile's key away (issue #47, the wipe
//! finding of 0.12). It is deleted only once its key is proven to open the identity
//! being forgotten.

use std::path::{Path, PathBuf};

/// Where a key candidate was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Source {
    Profile,
    Legacy,
    Blob,
    /// Another slot of this keystore's naming: the same folder under a path
    /// written differently, or a profile folder that moved on this account.
    Scan,
}

/// The most slots the scan tries: each read of an item another build wrote can
/// prompt on macOS, so a long list must not become a stream of prompts.
const SCAN_LIMIT: usize = 16;

#[cfg(not(test))]
const WIN_BASE: &str = "com.hollow.identity.wrapping_key";
/// Test builds never name a slot a real profile uses.
#[cfg(test)]
const WIN_BASE: &str = "com.hollow.test.identity.wrapping_key";
const MAC_BASE: &str = "wrapping_key";
const BLOB: &str = "identity.dpapi";

/// 16 hex chars of SHA-256 over the data root as a string. Changing this orphans
/// every existing per-profile slot.
fn slot_suffix(root: &Path) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(root.to_string_lossy().as_bytes());
    let out = h.finalize();
    out[..8].iter().map(|b| format!("{b:02x}")).collect()
}

fn base() -> &'static str {
    if cfg!(target_os = "macos") { MAC_BASE } else { WIN_BASE }
}

fn profile_slot(root: &Path) -> String {
    format!("{}.{}", base(), slot_suffix(root))
}

fn legacy_slot() -> String {
    #[cfg(test)]
    if let Some(name) = test_support::legacy_override() {
        return name;
    }
    base().to_string()
}

fn blob_path(root: &Path) -> PathBuf {
    root.join(BLOB)
}

pub(crate) fn is_available() -> bool {
    backend::available()
}

/// Runs keystore calls that must never put a prompt on screen and wait for an
/// answer: a wipe (a duress code is typed at a prompt, and a stalled wipe shows it
/// did something), the scan of other slots, and every write (a session with no
/// keychain, such as one started over ssh, must fail quietly, never ask). On macOS
/// an item another build wrote asks the person before it opens; here the call fails
/// instead. The switch is process-wide, so it is held only around these calls.
fn without_prompts<T>(f: impl FnOnce() -> T) -> T {
    #[cfg(target_os = "macos")]
    let _quiet = security_framework::os::macos::keychain::SecKeychain::disable_user_interaction().ok();
    #[cfg(test)]
    let _quiet_test = test_support::Quiet::enter();
    f()
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

    /// Every generic credential whose target starts with `prefix`.
    pub(crate) fn cred_list(prefix: &str) -> Vec<String> {
        use windows_sys::Win32::Security::Credentials::CredEnumerateW;
        let filter = to_wide(&format!("{prefix}*"));
        let mut count: u32 = 0;
        let mut creds: *mut *mut CREDENTIALW = ptr::null_mut();
        let ok = unsafe { CredEnumerateW(filter.as_ptr(), 0, &mut count, &mut creds) };
        if ok == 0 || creds.is_null() {
            return Vec::new();
        }
        let mut names = Vec::new();
        unsafe {
            for i in 0..count as usize {
                let cred = &**creds.add(i);
                if cred.TargetName.is_null() {
                    continue;
                }
                let mut len = 0usize;
                while *cred.TargetName.add(len) != 0 {
                    len += 1;
                }
                let wide = std::slice::from_raw_parts(cred.TargetName, len);
                names.push(String::from_utf16_lossy(wide));
            }
            CredFree(creds as *mut _);
        }
        names
    }

    /// Not found is fine.
    pub(crate) fn cred_delete(target_name: &str) -> Result<(), String> {
        let target = to_wide(target_name);
        unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) };
        Ok(())
    }

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

    #[cfg(not(test))]
    const SERVICE: &str = "com.hollow.identity";
    #[cfg(test)]
    const SERVICE: &str = "com.hollow.test.identity";

    pub(crate) fn store(account: &str, key: &[u8]) -> Result<(), String> {
        // A fresh item takes this build as its trusted application.
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
            Ok(results) => match results.into_iter().next() {
                Some(SearchResult::Data(data)) => Ok(Some(data)),
                _ => Ok(None),
            },
            Err(e) if e.code() == -25300 => Ok(None), // errSecItemNotFound
            Err(e) => Err(format!("macOS Keychain retrieve failed: {e}")),
        }
    }

    /// Every account of this service whose name starts with `prefix`. Attributes
    /// only, which never prompt; the data is read per account afterwards.
    pub(crate) fn list(prefix: &str) -> Vec<String> {
        let mut search = ItemSearchOptions::new();
        search
            .class(ItemClass::generic_password())
            .service(SERVICE)
            .limit(Limit::All)
            .load_attributes(true);
        let Ok(results) = search.search() else { return Vec::new() };
        results
            .iter()
            .filter_map(|r| r.simplify_dict()?.get("acct").cloned())
            .filter(|a| a.starts_with(prefix))
            .collect()
    }

    pub(crate) fn delete(account: &str) -> Result<(), String> {
        match delete_generic_password(SERVICE, account) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == -25300 => Ok(()),
            Err(e) => Err(format!("macOS Keychain delete failed: {e}")),
        }
    }
}

/// The platform store, by slot name.
mod real {
    pub(super) fn available() -> bool {
        cfg!(any(windows, target_os = "macos"))
    }

    pub(super) fn has_blob() -> bool {
        cfg!(windows)
    }

    pub(super) fn write(name: &str, key: &[u8]) -> Result<(), String> {
        #[cfg(windows)]
        return super::win::cred_store(name, key);
        #[cfg(target_os = "macos")]
        return super::mac::store(name, key);
        #[cfg(not(any(windows, target_os = "macos")))]
        {
            let _ = (name, key);
            Err("OS keychain not available on this platform".into())
        }
    }

    pub(super) fn read(name: &str) -> Result<Option<Vec<u8>>, String> {
        #[cfg(windows)]
        return super::win::cred_retrieve(name);
        #[cfg(target_os = "macos")]
        return super::mac::retrieve(name);
        #[cfg(not(any(windows, target_os = "macos")))]
        {
            let _ = name;
            Ok(None)
        }
    }

    pub(super) fn list(prefix: &str) -> Vec<String> {
        #[cfg(windows)]
        return super::win::cred_list(prefix);
        #[cfg(target_os = "macos")]
        return super::mac::list(prefix);
        #[cfg(not(any(windows, target_os = "macos")))]
        {
            let _ = prefix;
            Vec::new()
        }
    }

    pub(super) fn delete(name: &str) -> Result<(), String> {
        #[cfg(windows)]
        return super::win::cred_delete(name);
        #[cfg(target_os = "macos")]
        return super::mac::delete(name);
        #[cfg(not(any(windows, target_os = "macos")))]
        {
            let _ = name;
            Ok(())
        }
    }

    pub(super) fn protect(data: &[u8]) -> Result<Vec<u8>, String> {
        #[cfg(windows)]
        return super::win::dpapi_protect(data);
        #[cfg(not(windows))]
        {
            let _ = data;
            Err("No blob protection on this platform".into())
        }
    }

    pub(super) fn unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
        #[cfg(windows)]
        return super::win::dpapi_unprotect(data);
        #[cfg(not(windows))]
        {
            let _ = data;
            Err("No blob protection on this platform".into())
        }
    }
}

#[cfg(not(test))]
use real as backend;

/// Test builds run against an in-memory store per thread unless a test asks for the
/// real one, so a test can never reach a real slot by accident and runs the same on
/// a CI runner with no keychain at all.
#[cfg(test)]
mod backend {
    use super::test_support::{fault, mode, Fault, Mode};

    pub(super) fn available() -> bool {
        match mode() {
            Mode::Fake => true,
            Mode::Real => super::real::available(),
        }
    }

    pub(super) fn has_blob() -> bool {
        match mode() {
            Mode::Fake => true,
            Mode::Real => super::real::has_blob(),
        }
    }

    pub(super) fn write(name: &str, key: &[u8]) -> Result<(), String> {
        if fault(Fault::StoreFails) {
            return Err("injected: the keystore refused the write".into());
        }
        match mode() {
            Mode::Fake => {
                super::test_support::fake_put(name, Some(key.to_vec()));
                super::test_support::count_write();
                super::test_support::note_write_quiet();
                Ok(())
            }
            Mode::Real => {
                super::test_support::note_real_write(name);
                super::real::write(name, key)
            }
        }
    }

    pub(super) fn read(name: &str) -> Result<Option<Vec<u8>>, String> {
        super::test_support::note_read(name);
        let value = match mode() {
            Mode::Fake => super::test_support::fake_get(name),
            Mode::Real => super::real::read(name)?,
        };
        let after_a_write = super::test_support::wrote_since_injected();
        if value.is_some() && after_a_write && fault(Fault::ReadBackMissing) {
            return Ok(None);
        }
        if value.is_some() && after_a_write && fault(Fault::ReadBackWrong) {
            return Ok(Some(vec![0x5a; 32]));
        }
        Ok(value)
    }

    pub(super) fn list(prefix: &str) -> Vec<String> {
        match mode() {
            Mode::Fake => super::test_support::fake_names(prefix),
            Mode::Real => super::real::list(prefix),
        }
    }

    pub(super) fn delete(name: &str) -> Result<(), String> {
        match mode() {
            Mode::Fake => {
                super::test_support::fake_put(name, None);
                Ok(())
            }
            Mode::Real => super::real::delete(name),
        }
    }

    const FAKE_TAG: &[u8] = b"FAKEBLOB";

    pub(super) fn protect(data: &[u8]) -> Result<Vec<u8>, String> {
        match mode() {
            Mode::Fake => Ok([FAKE_TAG, data].concat()),
            Mode::Real => super::real::protect(data),
        }
    }

    pub(super) fn unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
        match mode() {
            Mode::Fake if fault(Fault::BlobWrong) => Ok(vec![0x6b; 32]),
            Mode::Fake => data
                .strip_prefix(FAKE_TAG)
                .map(<[u8]>::to_vec)
                .ok_or_else(|| "fake blob does not open".to_string()),
            Mode::Real => super::real::unprotect(data),
        }
    }
}

/// Writes `bytes` beside `path` and renames it over, so a crash leaves the old file
/// or the new one, never half of either.
fn replace_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("dpapi.tmp");
    std::fs::write(&tmp, bytes).map_err(|e| format!("Failed to write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("Failed to replace {}: {e}", path.display())
    })
}

/// The per-profile slot is required; the Windows DPAPI blob is a fallback beside it.
pub(crate) fn store_key_at(root: &Path, key: &[u8]) -> Result<(), String> {
    if !backend::available() {
        return Err("OS keychain not available on this platform".into());
    }
    without_prompts(|| backend::write(&profile_slot(root), key))?;
    if backend::has_blob()
        && let Ok(blob) = backend::protect(key)
    {
        let _ = replace_file(&blob_path(root), &blob);
    }
    Ok(())
}

/// Every stored candidate for `root`, most authoritative first. A caller MUST check
/// that a candidate opens the identity before trusting it: the legacy slot routinely
/// holds another profile's key.
#[cfg(test)]
pub(crate) fn candidates_at(root: &Path) -> Vec<(Source, Vec<u8>)> {
    let mut out: Vec<(Source, Vec<u8>)> = Vec::new();
    for source in [Source::Profile, Source::Legacy, Source::Blob] {
        if let Some(key) = read_source(root, source)
            && !out.iter().any(|(_, k)| *k == key)
        {
            out.push((source, key));
        }
    }
    out
}

fn read_source(root: &Path, source: Source) -> Option<Vec<u8>> {
    match source {
        Source::Profile => backend::read(&profile_slot(root)).ok().flatten(),
        Source::Legacy => backend::read(&legacy_slot()).ok().flatten(),
        Source::Blob => read_blob_key_at(root),
        Source::Scan => None,
    }
}

/// The first stored key, most authoritative first, that opens `identity`. Stops at
/// the first that does, so the shared legacy slot is read only when this profile's
/// own slot fails (on macOS a read of an item another build wrote can prompt).
pub(crate) fn key_that_opens(root: &Path, identity: &[u8]) -> Option<(Source, [u8; 32])> {
    let opens = |bytes: Vec<u8>| {
        let key = <[u8; 32]>::try_from(bytes.as_slice()).ok()?;
        super::encryption::decrypt_identity(identity, &key).is_ok().then_some(key)
    };
    let known = [Source::Profile, Source::Legacy, Source::Blob].into_iter().find_map(|source| {
        opens(read_source(root, source)?).map(|key| (source, key))
    });
    if known.is_some() {
        return known;
    }
    let own = profile_slot(root);
    without_prompts(|| {
        backend::list(&format!("{}.", base()))
            .into_iter()
            .filter(|name| *name != own)
            .take(SCAN_LIMIT)
            .find_map(|name| opens(backend::read(&name).ok()??).map(|key| (Source::Scan, key)))
    })
}

/// A new read of this profile's own slot, for checking a write landed.
pub(crate) fn read_profile_key_at(root: &Path) -> Result<Option<Vec<u8>>, String> {
    backend::read(&profile_slot(root))
}

pub(crate) fn read_blob_key_at(root: &Path) -> Option<Vec<u8>> {
    if !backend::has_blob() {
        return None;
    }
    let blob = std::fs::read(blob_path(root)).ok()?;
    backend::unprotect(&blob).ok()
}

/// What a profile's own slot and blob held, to put back after a failed switch.
pub(crate) struct Snapshot {
    profile: Option<Vec<u8>>,
    blob_file: Option<Vec<u8>>,
}

pub(crate) fn snapshot_at(root: &Path) -> Snapshot {
    Snapshot {
        profile: backend::read(&profile_slot(root)).ok().flatten(),
        blob_file: std::fs::read(blob_path(root)).ok(),
    }
}

pub(crate) fn restore_snapshot(root: &Path, snap: &Snapshot) {
    let slot = profile_slot(root);
    let _ = match &snap.profile {
        Some(key) => backend::write(&slot, key),
        None => backend::delete(&slot),
    };
    let path = blob_path(root);
    match &snap.blob_file {
        Some(bytes) => {
            let _ = replace_file(&path, bytes);
        }
        None => {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// True when the legacy slot's key opens `identity` (an HKEYV1 file).
pub(crate) fn legacy_key_opens(identity: &[u8]) -> bool {
    // Only a keychain identity's key was ever kept there; a wipe of any other reads
    // nothing (a read can prompt on macOS, and a duress wipe must show nothing).
    let keychain = matches!(
        super::encryption::detect_format(identity),
        Ok(super::encryption::IdentityFormat::Encrypted { flags, .. })
            if super::encryption::flags_has_os_keychain(flags)
    );
    if !keychain {
        return false;
    }
    let Ok(Some(key)) = without_prompts(|| backend::read(&legacy_slot())) else { return false };
    let Ok(key) = <[u8; 32]>::try_from(key.as_slice()) else { return false };
    super::encryption::decrypt_identity(identity, &key).is_ok()
}

/// Forgets the key a profile's identity was kept under: its own slot and blob always,
/// the legacy slot only when it is proven to be this identity's. `identity_before`
/// is the identity file as it was BEFORE the change, read before anything was zeroed
/// or rewritten; `None` (nothing to prove it with) keeps the legacy slot.
pub(crate) fn forget_key_at(root: &Path, identity_before: Option<&[u8]>) {
    forget_key_proven(root, identity_before.is_some_and(legacy_key_opens));
}

/// [`forget_key_at`] with the legacy proof already taken.
pub(crate) fn forget_key_proven(root: &Path, legacy_is_ours: bool) {
    let _ = std::fs::remove_file(blob_path(root));
    without_prompts(|| {
        let _ = backend::delete(&profile_slot(root));
        if legacy_is_ours {
            let _ = backend::delete(&legacy_slot());
        }
    });
}

#[cfg(test)]
pub(crate) mod test_support {
    //! The per-thread fake store, the switch to the real one, and injected faults.

    use std::cell::{Cell, RefCell};
    use std::collections::HashMap;

    #[derive(Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Mode {
        Fake,
        Real,
    }

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    pub(crate) enum Fault {
        StoreFails,
        ReadBackMissing,
        ReadBackWrong,
        BlobWrong,
    }

    thread_local! {
        static MODE: Cell<Mode> = const { Cell::new(Mode::Fake) };
        static FAKE: RefCell<HashMap<String, Vec<u8>>> = RefCell::new(HashMap::new());
        static FAULTS: RefCell<Vec<Fault>> = const { RefCell::new(Vec::new()) };
        static LEGACY: RefCell<Option<String>> = const { RefCell::new(None) };
        static REAL_WRITES: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
        static WRITES: Cell<u32> = const { Cell::new(0) };
        static ARMED: Cell<bool> = const { Cell::new(false) };
        static READS: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
        static QUIET: Cell<u32> = const { Cell::new(0) };
        static LOUD_WRITES: Cell<u32> = const { Cell::new(0) };
    }

    /// Marks this thread as inside `without_prompts` while held.
    pub(crate) struct Quiet;

    impl Quiet {
        pub(crate) fn enter() -> Self {
            QUIET.with(|q| q.set(q.get() + 1));
            Quiet
        }
    }

    impl Drop for Quiet {
        fn drop(&mut self) {
            QUIET.with(|q| q.set(q.get() - 1));
        }
    }

    pub(crate) fn note_write_quiet() {
        if QUIET.with(Cell::get) == 0 {
            LOUD_WRITES.with(|w| w.set(w.get() + 1));
        }
    }

    /// Writes on this thread, since the last call, that were allowed to ask the person.
    pub(crate) fn take_loud_writes() -> u32 {
        LOUD_WRITES.with(|w| w.replace(0))
    }

    pub(crate) fn note_read(name: &str) {
        READS.with(|r| r.borrow_mut().push(name.to_string()));
    }

    /// True when the legacy slot was read on this thread since the last call.
    pub(crate) fn legacy_was_read() -> bool {
        let legacy = super::legacy_slot();
        READS.with(|r| std::mem::take(&mut *r.borrow_mut())).contains(&legacy)
    }

    pub(crate) fn count_write() {
        WRITES.with(|w| w.set(w.get() + 1));
        ARMED.with(|a| a.set(true));
    }

    /// Read faults strike only reads that follow a write, the way a store that did
    /// not keep what it was given looks.
    pub(crate) fn wrote_since_injected() -> bool {
        ARMED.with(Cell::get)
    }

    /// Fake-store writes on this thread since the last call.
    pub(crate) fn take_writes() -> u32 {
        WRITES.with(|w| w.replace(0))
    }

    /// Every real slot a test writes is deleted when its [`RealKeystore`] drops.
    pub(crate) fn note_real_write(name: &str) {
        REAL_WRITES.with(|w| {
            let mut w = w.borrow_mut();
            if !w.iter().any(|n| n == name) {
                w.push(name.to_string());
            }
        });
    }

    pub(crate) fn mode() -> Mode {
        MODE.with(Cell::get)
    }

    pub(crate) fn fault(f: Fault) -> bool {
        FAULTS.with(|v| v.borrow().contains(&f))
    }

    pub(crate) fn inject(f: Fault) {
        FAULTS.with(|v| v.borrow_mut().push(f));
        ARMED.with(|a| a.set(false));
    }

    pub(crate) fn clear_faults() {
        FAULTS.with(|v| v.borrow_mut().clear());
    }

    pub(crate) fn fake_get(name: &str) -> Option<Vec<u8>> {
        FAKE.with(|m| m.borrow().get(name).cloned())
    }

    pub(crate) fn fake_put(name: &str, value: Option<Vec<u8>>) {
        FAKE.with(|m| {
            let mut m = m.borrow_mut();
            match value {
                Some(v) => m.insert(name.to_string(), v),
                None => m.remove(name),
            }
        });
    }

    pub(crate) fn fake_names(prefix: &str) -> Vec<String> {
        FAKE.with(|m| m.borrow().keys().filter(|k| k.starts_with(prefix)).cloned().collect())
    }

    pub(crate) fn legacy_override() -> Option<String> {
        LEGACY.with(|l| l.borrow().clone())
    }

    /// The legacy slot's current key, whichever store is in use.
    pub(crate) fn legacy_value() -> Option<Vec<u8>> {
        super::backend::read(&super::legacy_slot()).ok().flatten()
    }

    pub(crate) fn set_legacy(key: &[u8]) {
        super::backend::write(&super::legacy_slot(), key).expect("legacy slot write");
    }

    pub(crate) fn profile_value(root: &std::path::Path) -> Option<Vec<u8>> {
        super::backend::read(&super::profile_slot(root)).ok().flatten()
    }

    pub(crate) fn set_profile(root: &std::path::Path, key: &[u8]) {
        super::backend::write(&super::profile_slot(root), key).expect("profile slot write");
    }

    pub(crate) fn delete_profile(root: &std::path::Path) {
        let _ = super::backend::delete(&super::profile_slot(root));
    }

    /// The machine's real keystore for this thread, in the test namespace and with a
    /// legacy slot of its own; every slot written through it is deleted on drop.
    /// `None` where there is no keystore.
    pub(crate) struct RealKeystore {
        _private: (),
    }

    impl RealKeystore {
        pub(crate) fn enter() -> Option<Self> {
            if !super::real::available() {
                return None;
            }
            let mut tag = [0u8; 8];
            getrandom::fill(&mut tag).ok()?;
            let legacy = format!(
                "{}.legacy.{}",
                super::base(),
                tag.iter().map(|b| format!("{b:02x}")).collect::<String>()
            );
            MODE.with(|m| m.set(Mode::Real));
            LEGACY.with(|l| *l.borrow_mut() = Some(legacy));
            Some(Self { _private: () })
        }
    }

    impl Drop for RealKeystore {
        fn drop(&mut self) {
            for name in REAL_WRITES.with(|w| std::mem::take(&mut *w.borrow_mut())) {
                let _ = super::real::delete(&name);
            }
            LEGACY.with(|l| *l.borrow_mut() = None);
            MODE.with(|m| m.set(Mode::Fake));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;

    #[test]
    fn test_builds_never_name_a_real_slot() {
        assert!(WIN_BASE.contains(".test."), "a test build names the real Windows slot");
        let root = Path::new("/somewhere/hollow");
        assert!(!profile_slot(root).starts_with("com.hollow.identity."));
        assert!(!legacy_slot().starts_with("com.hollow.identity"));
    }

    /// A store runs with prompts off: a session with no keychain (ssh) fails it
    /// quietly instead of raising a dialog on someone's screen.
    #[test]
    fn a_keychain_store_never_asks_the_person() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let _ = take_loud_writes();
        store_key_at(tmp.path(), &[0x5c; 32]).unwrap();
        assert_eq!(read_profile_key_at(tmp.path()).unwrap(), Some(vec![0x5c; 32]));
        assert_eq!(take_loud_writes(), 0, "a keychain write was allowed to ask");
    }

    /// The suffix names every existing per-profile slot, so it never changes.
    #[test]
    fn slot_suffix_is_pinned() {
        assert_eq!(slot_suffix(Path::new("/tmp/a")), "d9b741ea3d4d24a6");
        assert_ne!(slot_suffix(Path::new("/tmp/a")), slot_suffix(Path::new("/tmp/b")));
    }

    #[test]
    fn a_profile_slot_outranks_the_legacy_slot_and_the_blob() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        set_legacy(&[0xB2; 32]);
        store_key_at(tmp.path(), &[0xA1; 32]).unwrap();
        let cands = candidates_at(tmp.path());
        assert_eq!(cands.first(), Some(&(Source::Profile, vec![0xA1; 32])));
        assert!(cands.contains(&(Source::Legacy, vec![0xB2; 32])));
        assert_eq!(read_blob_key_at(tmp.path()), Some(vec![0xA1; 32]));
    }

    /// Storing a key for one profile leaves the machine-wide legacy slot alone.
    #[test]
    fn storing_never_writes_the_legacy_slot() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        set_legacy(&[0x33; 32]);
        store_key_at(tmp.path(), &[0x44; 32]).unwrap();
        assert_eq!(legacy_value(), Some(vec![0x33; 32]));
    }

    #[test]
    fn a_snapshot_puts_back_what_was_there() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let empty = snapshot_at(tmp.path());
        store_key_at(tmp.path(), &[0x11; 32]).unwrap();
        restore_snapshot(tmp.path(), &empty);
        assert_eq!(profile_value(tmp.path()), None);
        assert!(!tmp.path().join(BLOB).exists());

        store_key_at(tmp.path(), &[0x22; 32]).unwrap();
        let held = snapshot_at(tmp.path());
        store_key_at(tmp.path(), &[0x33; 32]).unwrap();
        restore_snapshot(tmp.path(), &held);
        assert_eq!(profile_value(tmp.path()), Some(vec![0x22; 32]));
        assert_eq!(read_blob_key_at(tmp.path()), Some(vec![0x22; 32]));
    }

    #[cfg(windows)]
    #[test]
    fn dpapi_round_trip() {
        let secret = b"hollow-test-wrapping-key-32bytes!";
        let protected = win::dpapi_protect(secret).unwrap();
        assert_ne!(protected, secret.to_vec());
        assert!(protected.len() > secret.len());
        assert_eq!(win::dpapi_unprotect(&protected).unwrap(), secret.to_vec());
        let empty = win::dpapi_protect(b"").unwrap();
        assert_eq!(win::dpapi_unprotect(&empty).unwrap(), Vec::<u8>::new());
    }

    /// The real store, in the test namespace: a write reads back through a new call,
    /// and a delete is gone. Skipped where there is no keystore.
    #[test]
    fn the_real_keystore_round_trips_in_the_test_namespace() {
        let Some(_real) = RealKeystore::enter() else { return };
        let tmp = crate::test_tmp::tempdir().unwrap();
        let key = vec![0x42u8; 32];
        store_key_at(tmp.path(), &key).unwrap();
        assert_eq!(read_profile_key_at(tmp.path()).unwrap(), Some(key.clone()));
        if cfg!(windows) {
            assert_eq!(read_blob_key_at(tmp.path()), Some(key.clone()));
        }
        forget_key_at(tmp.path(), None);
        assert_eq!(read_profile_key_at(tmp.path()).unwrap(), None);
        assert_eq!(read_blob_key_at(tmp.path()), None);
    }
}
