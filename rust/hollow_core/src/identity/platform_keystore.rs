//! The OS keystore slots that hold an identity's wrapping key: one slot per profile
//! (named by a hash of its data root), the machine-wide legacy slot builds before
//! per-profile slots wrote, and on Windows a DPAPI blob inside the root.
//!
//! The legacy slot is READ as a fallback and never written: with several profiles on
//! one machine it holds whichever profile wrote it last, so writing or deleting it on
//! behalf of one profile can take another profile's key away (issue #47, the wipe
//! finding of 0.12). It is deleted only once its key is proven to open the identity
//! being forgotten.
//!
//! macOS (HOL-SEC-187): keys live only in the data-protection keychain, in the keys
//! app group (the app-ID group where a Mac refuses it), this device only. Builds
//! before 0.14 wrote the file-based login keychain under a requirement every build
//! the team ever signed meets, so an old build with a planted library could read
//! them. `settle_move` copies those items across, reads each copy back, deletes
//! exactly the item it read, then reads the name again to see it gone. macOS lets only
//! the app that made a login item delete it, so the item may stay: the identity then
//! moves onto a new key (`keychain_rekey`) and the old one opens nothing. Nothing
//! writes the file-based keychain any more, and no macOS keychain call runs before
//! the app's bundle self-check passed.

use std::path::{Path, PathBuf};

/// Where a key candidate was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Source {
    Profile,
    /// A conflict copy of this profile's slot (`<slot>.m.<hash>`), left by the move.
    Copy,
    /// The new key of a re-key not finished yet (`<slot>.rekey`).
    Rekey,
    Legacy,
    /// A file-based keychain item the move has not taken yet (macOS).
    Unmoved,
    Blob,
    /// Another slot of this keystore's naming: the same folder under a path
    /// written differently, or a profile folder that moved on this account.
    Scan,
}

impl Source {
    /// Whether finding a key here took a read of the file-based keychain that may
    /// ask the person (`key_that_opens` reads it after every protected source).
    pub(crate) fn came_after_the_login_keychain(self) -> bool {
        matches!(self, Source::Unmoved | Source::Blob | Source::Scan)
    }
}

/// The keystore an item sits in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Store {
    /// Windows Credential Manager.
    Flat,
    /// The macOS file-based (login) keychain: read, listed and deleted, never written.
    Legacy,
    /// The macOS data-protection keychain, the keys app group.
    Keys,
    /// The macOS data-protection keychain, the app-ID group (lost at a team change).
    AppId,
}

/// Why a keystore call failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Failure {
    /// `errSecMissingEntitlement`: this build may not use that group.
    Refused,
    /// The item would ask the person, and prompts are off.
    WouldAsk,
    /// The bundle self-check has not passed in this process.
    Unchecked,
    /// `errSecInvalidOwnerEdit`: only the app that made the item may delete it.
    NotOwner,
    Other(i32),
}

/// A value and the item it was read from.
type Found = Option<(Vec<u8>, Item)>;

/// The item a read found, so a delete takes that item and never one another process
/// wrote under the same name since.
#[cfg_attr(not(any(test, target_os = "macos")), allow(dead_code))]
pub(crate) enum Item {
    /// A data-protection keychain persistent reference: a row id a rewrite never reuses.
    Persistent(Vec<u8>),
    /// A file-based keychain item. Its persistent references resolve by service and
    /// account, so a delete by one takes whatever item holds the name by then.
    #[cfg(target_os = "macos")]
    Object(core_foundation::base::CFType),
    /// The fake file-based keychain's item.
    #[cfg(test)]
    FakeObject(Vec<u8>),
}

/// What a delete of one item answered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) enum Deleted {
    /// The keychain removed an item.
    Took,
    /// The keychain found nothing to remove. In the file-based keychain that is also
    /// the answer when another process rewrote the item, even while a read here still
    /// misses the new one.
    NotFound,
}

/// What an add found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Added {
    New,
    /// The name was taken already (a concurrent writer): never overwritten.
    Present,
}

/// Whether a new key may be written, and where (store rule 4). `Unknown` is any
/// answer that is not a definite yes or no: it offers nothing, writes nothing,
/// deletes nothing, and is never kept for the process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Writable {
    Yes(Store),
    No,
    Unknown,
}

/// The most slots the scan tries: each read of an item another build wrote can
/// prompt on macOS, so a long list must not become a stream of prompts.
const SCAN_LIMIT: usize = 16;

/// The most items one start moves, so items planted under our names cannot make a
/// start slow; the running profile's slot and the machine slot always go first.
const MOVE_LIMIT: usize = 32;

#[cfg(not(test))]
const WIN_BASE: &str = "com.hollow.identity.wrapping_key";
/// Test builds never name a slot a real profile uses.
#[cfg(test)]
const WIN_BASE: &str = "com.hollow.test.identity.wrapping_key";
const MAC_BASE: &str = "wrapping_key";
const BLOB: &str = "identity.dpapi";
/// The account the writability probe adds and deletes again.
const PROBE: &str = "probe";
/// Conflict copies: `<slot>.m.<16 hex of SHA-256(value)>`, owned by `<slot>`'s root.
const COPY_MARK: &str = ".m.";
/// A re-key's new key until it replaces the profile slot: `<slot>.rekey`. No slot or
/// copy name ends so, so neither mover nor a heal's copy drop ever takes it.
const REKEY_MARK: &str = ".rekey";

/// 16 hex chars of SHA-256 over the data root as a string. Changing this orphans
/// every existing per-profile slot.
fn slot_suffix(root: &Path) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(root.to_string_lossy().as_bytes());
    let out = h.finalize();
    out[..8].iter().map(|b| format!("{b:02x}")).collect()
}

fn mac_layout() -> bool {
    #[cfg(test)]
    if let Some(mac) = test_support::layout() {
        return mac;
    }
    cfg!(target_os = "macos")
}

/// Whether keys here can sit in a login keychain item an older build wrote (macOS).
pub(crate) fn has_login_keychain() -> bool {
    mac_layout()
}

fn base() -> &'static str {
    #[cfg(test)]
    if let Some(base) = test_support::base_override() {
        return base;
    }
    if mac_layout() { MAC_BASE } else { WIN_BASE }
}

fn profile_slot(root: &Path) -> String {
    format!("{}.{}", base(), slot_suffix(root))
}

fn rekey_slot(root: &Path) -> String {
    format!("{}{REKEY_MARK}", profile_slot(root))
}

fn legacy_slot() -> String {
    #[cfg(test)]
    if let Some(name) = test_support::legacy_override() {
        return name;
    }
    base().to_string()
}

fn copy_name(name: &str, value: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(value);
    format!("{name}{COPY_MARK}{}", hex::encode(&hash[..8]))
}

fn is_hex16(s: &str) -> bool {
    s.len() == 16 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A slot name some Hollow build wrote: the machine slot or a profile slot.
fn slot_name(name: &str) -> bool {
    name == base() || name.strip_prefix(base()).and_then(|r| r.strip_prefix('.')).is_some_and(is_hex16)
}

/// A slot name or one conflict copy of one.
fn our_name(name: &str) -> bool {
    slot_name(name)
        || name.rsplit_once(COPY_MARK).is_some_and(|(slot, hash)| slot_name(slot) && is_hex16(hash))
}

fn blob_path(root: &Path) -> PathBuf {
    root.join(BLOB)
}

/// Where new keys go and where reads look first, in order.
fn protected_stores() -> &'static [Store] {
    if mac_layout() { &[Store::Keys, Store::AppId] } else { &[Store::Flat] }
}

/// Every store a key of ours can sit in, the file-based keychain included.
fn every_store() -> &'static [Store] {
    if mac_layout() { &[Store::Keys, Store::AppId, Store::Legacy] } else { &[Store::Flat] }
}

/// Runs keystore calls that must never put a prompt on screen and wait for an
/// answer: a wipe (a duress code is typed at a prompt, and a stalled wipe shows it
/// did something), the scan of other slots, the move and every write (a session with
/// no keychain, such as one started over ssh, must fail quietly, never ask). On macOS
/// an item another build wrote asks the person before it opens; here the call fails
/// instead. The switch is process-wide, so it is held only around these calls, and
/// counted: a nested call must not turn prompts back on when it returns.
pub(crate) fn without_prompts<T>(f: impl FnOnce() -> T) -> T {
    #[cfg(target_os = "macos")]
    let _quiet = mac_quiet::Hold::enter();
    #[cfg(test)]
    let _quiet_test = test_support::Quiet::enter();
    f()
}

#[cfg(target_os = "macos")]
mod mac_quiet {
    use security_framework::os::macos::keychain::{KeychainUserInteractionLock, SecKeychain};
    use std::sync::Mutex;

    /// How many callers want prompts off, and the switch the first of them took.
    static HELD: Mutex<(usize, Option<KeychainUserInteractionLock>)> = Mutex::new((0, None));

    pub(super) struct Hold;

    impl Hold {
        pub(super) fn enter() -> Self {
            let mut held = HELD.lock().unwrap_or_else(|e| e.into_inner());
            if held.0 == 0 {
                held.1 = SecKeychain::disable_user_interaction().ok();
            }
            held.0 += 1;
            Hold
        }
    }

    impl Drop for Hold {
        fn drop(&mut self) {
            let mut held = HELD.lock().unwrap_or_else(|e| e.into_inner());
            held.0 = held.0.saturating_sub(1);
            if held.0 == 0 {
                held.1 = None;
            }
        }
    }
}

pub(crate) mod bundle {
    //! The switch the macOS app's main executable sets once every image it loaded
    //! matched the list sealed into its signature (`macos/Runner/BundleSeal.swift`).
    //! Until then the macOS keychain answers nothing: a host whose Swift never ran
    //! (a swapped core) or found a stranger reads and writes no key.

    use std::sync::OnceLock;

    pub(crate) struct Groups {
        pub(crate) keys: String,
        pub(crate) app_id: String,
    }

    static GROUPS: OnceLock<Groups> = OnceLock::new();

    /// The only keys group a macOS build may name.
    pub(crate) const KEYS_GROUP: &str = "group.com.anonlisten.hollow.keys";
    const APP_ID_SUFFIX: &str = ".com.anonlisten.hollow";

    /// `<10-character team id>.com.anonlisten.hollow`.
    pub(crate) fn app_id_group_ok(group: &str) -> bool {
        group.strip_suffix(APP_ID_SUFFIX).is_some_and(|team| {
            team.len() == 10 && team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        })
    }

    pub(crate) fn checked() -> bool {
        #[cfg(test)]
        return !super::test_support::unchecked();
        #[cfg(not(test))]
        GROUPS.get().is_some()
    }

    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(crate) fn groups() -> Option<&'static Groups> {
        GROUPS.get()
    }

    /// Sets the switch once, for exactly our groups; anything else leaves it off.
    pub(crate) fn mark_checked(keys: &str, app_id: &str) -> bool {
        if keys != KEYS_GROUP || !app_id_group_ok(app_id) {
            return false;
        }
        GROUPS.set(Groups { keys: keys.to_string(), app_id: app_id.to_string() }).is_ok()
            || GROUPS.get().is_some_and(|g| g.app_id == app_id)
    }

    /// Called by `BundleSeal.swift` after the start check passed, with the groups
    /// its own validated entitlements name. 1 = set, 0 = refused.
    ///
    /// # Safety
    /// Both pointers are NUL-terminated strings that outlive the call, or null.
    #[cfg(target_os = "macos")]
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn hollow_bundle_checked(
        keys: *const std::ffi::c_char,
        app_id: *const std::ffi::c_char,
    ) -> i32 {
        if keys.is_null() || app_id.is_null() {
            return 0;
        }
        // SAFETY: the caller passes NUL-terminated strings that outlive the call.
        let (keys, app_id) = unsafe { (std::ffi::CStr::from_ptr(keys), std::ffi::CStr::from_ptr(app_id)) };
        let (Ok(keys), Ok(app_id)) = (keys.to_str(), app_id.to_str()) else { return 0 };
        i32::from(mark_checked(keys, app_id))
    }
}

/// Every keystore call passes here first: no macOS keychain before the self-check.
fn gate(store: Store) -> Result<(), Failure> {
    if store == Store::Flat || bundle::checked() { Ok(()) } else { Err(Failure::Unchecked) }
}

fn read(store: Store, name: &str) -> Result<Option<Vec<u8>>, Failure> {
    gate(store)?;
    backend::read(store, name)
}

fn read_ref(store: Store, name: &str) -> Result<Found, Failure> {
    gate(store)?;
    backend::read_ref(store, name)
}

fn add(store: Store, name: &str, value: &[u8]) -> Result<Added, Failure> {
    gate(store)?;
    if store == Store::Legacy {
        return Err(Failure::Other(-4));
    }
    backend::add(store, name, value)
}

fn put(store: Store, name: &str, value: &[u8]) -> Result<(), Failure> {
    gate(store)?;
    if store == Store::Legacy {
        return Err(Failure::Other(-4));
    }
    backend::put(store, name, value)
}

fn list(store: Store, prefix: &str) -> Vec<String> {
    if gate(store).is_err() {
        return Vec::new();
    }
    backend::list(store, prefix)
}

fn delete(store: Store, name: &str) -> Result<(), Failure> {
    gate(store)?;
    backend::delete(store, name)
}

/// Deletes exactly `item` (read under `name`).
fn delete_item(store: Store, name: &str, item: &Item) -> Result<Deleted, Failure> {
    gate(store)?;
    backend::delete_item(store, name, item)
}

fn same(a: &[u8], b: &[u8]) -> bool {
    use subtle::ConstantTimeEq;
    a.len() == b.len() && bool::from(a.ct_eq(b))
}

#[cfg(not(test))]
static WRITABLE: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

fn cached_writable() -> Option<Writable> {
    #[cfg(test)]
    let code = test_support::writable_cache();
    #[cfg(not(test))]
    let code = WRITABLE.load(std::sync::atomic::Ordering::Relaxed);
    match code {
        1 => Some(Writable::Yes(Store::Keys)),
        2 => Some(Writable::Yes(Store::AppId)),
        3 => Some(Writable::No),
        _ => None,
    }
}

fn keep_writable(w: Writable) {
    let code = match w {
        Writable::Yes(Store::Keys) => 1,
        Writable::Yes(Store::AppId) => 2,
        Writable::No => 3,
        _ => return,
    };
    #[cfg(test)]
    test_support::set_writable_cache(code);
    #[cfg(not(test))]
    WRITABLE.store(code, std::sync::atomic::Ordering::Relaxed);
}

/// Where a new key may go. macOS asks the keychain itself: a sentinel added to the
/// keys group, else the app-ID group; `errSecMissingEntitlement` on both is a no
/// (an ad-hoc build, a broken profile), anything else is unknown and asked again.
pub(crate) fn protected_writable() -> Writable {
    if !mac_layout() {
        return if backend::flat_available() { Writable::Yes(Store::Flat) } else { Writable::No };
    }
    if !bundle::checked() {
        return Writable::No;
    }
    if let Some(known) = cached_writable() {
        return known;
    }
    let answer = without_prompts(probe);
    keep_writable(answer);
    answer
}

fn probe() -> Writable {
    #[cfg(test)]
    test_support::count_probe();
    for store in [Store::Keys, Store::AppId] {
        match add(store, PROBE, &[1]) {
            Ok(_) => {
                let _ = delete(store, PROBE);
                return Writable::Yes(store);
            }
            Err(Failure::Refused) => continue,
            Err(_) => return Writable::Unknown,
        }
    }
    Writable::No
}

/// Whether keychain protection may be offered or newly written here.
pub(crate) fn may_offer() -> bool {
    matches!(protected_writable(), Writable::Yes(_))
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
#[cfg_attr(test, allow(dead_code))]
mod mac {
    //! SecItem calls by store. The protected stores always carry
    //! `kSecUseDataProtectionKeychain` and the group; the file-based keychain is
    //! reached only to read, list and delete, with the flag set false so a query for
    //! it never answers with (or deletes) a protected item.

    use core_foundation::array::CFArray;
    use core_foundation::base::{CFType, CFTypeID, CFTypeRef, OSStatus, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef, CFMutableDictionary};
    use core_foundation::string::{CFString, CFStringRef};

    use super::{Added, Failure, Store};

    #[cfg(not(test))]
    const SERVICE: &str = "com.hollow.identity";
    #[cfg(test)]
    const SERVICE: &str = "com.hollow.test.identity";

    const NOT_FOUND: OSStatus = -25300;
    const DUPLICATE: OSStatus = -25299;
    const INTERACTION_NOT_ALLOWED: OSStatus = -25308;
    const INVALID_OWNER_EDIT: OSStatus = -25244;
    const MISSING_ENTITLEMENT: OSStatus = -34018;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecClass: CFStringRef;
        static kSecClassGenericPassword: CFStringRef;
        static kSecAttrService: CFStringRef;
        static kSecAttrAccount: CFStringRef;
        static kSecAttrAccessGroup: CFStringRef;
        static kSecAttrAccessible: CFStringRef;
        static kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: CFStringRef;
        static kSecAttrSynchronizable: CFStringRef;
        static kSecUseDataProtectionKeychain: CFStringRef;
        static kSecValueData: CFStringRef;
        static kSecValuePersistentRef: CFStringRef;
        static kSecReturnData: CFStringRef;
        static kSecReturnAttributes: CFStringRef;
        static kSecReturnPersistentRef: CFStringRef;
        static kSecReturnRef: CFStringRef;
        static kSecValueRef: CFStringRef;
        static kSecMatchLimit: CFStringRef;
        static kSecMatchLimitOne: CFStringRef;
        static kSecMatchLimitAll: CFStringRef;
        fn SecItemAdd(attributes: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
        fn SecItemCopyMatching(query: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
        fn SecItemUpdate(query: CFDictionaryRef, update: CFDictionaryRef) -> OSStatus;
        fn SecItemDelete(query: CFDictionaryRef) -> OSStatus;
        fn SecKeychainItemGetTypeID() -> CFTypeID;
    }

    type Query = CFMutableDictionary<CFString, CFType>;

    fn k(constant: CFStringRef) -> CFString {
        // SAFETY: a Security framework constant, valid for the life of the process.
        unsafe { CFString::wrap_under_get_rule(constant) }
    }

    fn failure(status: OSStatus) -> Failure {
        match status {
            MISSING_ENTITLEMENT => Failure::Refused,
            INTERACTION_NOT_ALLOWED => Failure::WouldAsk,
            INVALID_OWNER_EDIT => Failure::NotOwner,
            other => Failure::Other(other),
        }
    }

    /// The item class and the store's keychain; `account` narrows it to one name.
    fn query(store: Store, account: Option<&str>) -> Result<Query, Failure> {
        let mut q = Query::new();
        // SAFETY: reading Security framework constants.
        unsafe {
            q.set(k(kSecClass), k(kSecClassGenericPassword).into_CFType());
            q.set(k(kSecAttrService), CFString::new(SERVICE).into_CFType());
            if let Some(account) = account {
                q.set(k(kSecAttrAccount), CFString::new(account).into_CFType());
            }
            match store {
                Store::Legacy => {
                    q.set(k(kSecUseDataProtectionKeychain), CFBoolean::false_value().into_CFType());
                }
                Store::Keys | Store::AppId => {
                    let groups = super::bundle::groups().ok_or(Failure::Unchecked)?;
                    let group = if store == Store::Keys { &groups.keys } else { &groups.app_id };
                    q.set(k(kSecUseDataProtectionKeychain), CFBoolean::true_value().into_CFType());
                    q.set(k(kSecAttrAccessGroup), CFString::new(group).into_CFType());
                }
                Store::Flat => return Err(Failure::Other(-4)),
            }
        }
        Ok(q)
    }

    /// What a file-based query sets `kSecUseDataProtectionKeychain` to.
    #[cfg(test)]
    pub(super) fn file_query_flag() -> Option<bool> {
        let q = query(Store::Legacy, None).ok()?;
        // SAFETY: reading a Security framework constant.
        let flag = unsafe { k(kSecUseDataProtectionKeychain) };
        q.find(&flag)?.downcast::<CFBoolean>().map(bool::from)
    }

    /// A protected item by its persistent reference, naming its group, service and
    /// account too; only a signed build shows the protected keychain matches them all.
    fn by_ref(store: Store, account: &str, item: &[u8]) -> Result<Query, Failure> {
        if !matches!(store, Store::Keys | Store::AppId) {
            return Err(Failure::Other(-4));
        }
        let mut q = query(store, Some(account))?;
        // SAFETY: reading a Security framework constant.
        unsafe { q.set(k(kSecValuePersistentRef), CFData::from_buffer(item).into_CFType()) };
        Ok(q)
    }

    /// The attributes a delete of `item` under `account` names, for the tests.
    #[cfg(test)]
    pub(super) fn delete_query_names(store: Store, account: &str, item: &super::Item) -> Option<Vec<String>> {
        let q = delete_query(store, account, item).ok()?;
        let (keys, _) = q.get_keys_and_values();
        // SAFETY: every key of a query is a CFString this module set.
        let mut names: Vec<String> =
            keys.into_iter().map(|key| unsafe { CFString::wrap_under_get_rule(key as CFStringRef) }.to_string()).collect();
        names.sort();
        Some(names)
    }

    fn copy_matching(q: &Query) -> Result<Option<CFType>, Failure> {
        let mut out: CFTypeRef = std::ptr::null();
        // SAFETY: a valid dictionary and an out pointer the call fills on success.
        let status = unsafe { SecItemCopyMatching(q.as_concrete_TypeRef() as CFDictionaryRef, &mut out) };
        match status {
            0 if !out.is_null() => {
                // SAFETY: a +1 reference the call returned.
                Ok(Some(unsafe { CFType::wrap_under_create_rule(out) }))
            }
            0 | NOT_FOUND => Ok(None),
            other => Err(failure(other)),
        }
    }

    fn data_of(value: Option<core_foundation::base::ItemRef<'_, CFType>>) -> Option<Vec<u8>> {
        value?.downcast::<CFData>().map(|d| d.bytes().to_vec())
    }

    pub(super) fn read(store: Store, account: &str) -> Result<Option<Vec<u8>>, Failure> {
        let mut q = query(store, Some(account))?;
        // SAFETY: reading Security framework constants.
        unsafe {
            q.set(k(kSecReturnData), CFBoolean::true_value().into_CFType());
            q.set(k(kSecMatchLimit), k(kSecMatchLimitOne).into_CFType());
        }
        Ok(copy_matching(&q)?.and_then(|v| v.downcast::<CFData>()).map(|d| d.bytes().to_vec()))
    }

    /// The value and its item: the item object in the file-based keychain, a
    /// persistent reference in the protected stores.
    pub(super) fn read_ref(store: Store, account: &str) -> Result<super::Found, Failure> {
        let file_based = store == Store::Legacy;
        let mut q = query(store, Some(account))?;
        // SAFETY: reading Security framework constants.
        let (data_key, ref_key) = unsafe {
            q.set(k(kSecReturnData), CFBoolean::true_value().into_CFType());
            let (ask, answer) = if file_based {
                (kSecReturnRef, kSecValueRef)
            } else {
                (kSecReturnPersistentRef, kSecValuePersistentRef)
            };
            q.set(k(ask), CFBoolean::true_value().into_CFType());
            q.set(k(kSecMatchLimit), k(kSecMatchLimitOne).into_CFType());
            (k(kSecValueData), k(answer))
        };
        let Some(found) = copy_matching(&q)? else { return Ok(None) };
        let Some(dict) = found.downcast::<CFDictionary>() else { return Err(Failure::Other(-1)) };
        // SAFETY: SecItemCopyMatching answers a dictionary of CFString keys.
        let dict: CFDictionary<CFString, CFType> = unsafe { CFDictionary::wrap_under_get_rule(dict.as_concrete_TypeRef()) };
        let Some(value) = data_of(dict.find(&data_key)) else { return Err(Failure::Other(-1)) };
        let item = if file_based {
            // SAFETY: a type-id lookup with no arguments.
            let keychain_item = unsafe { SecKeychainItemGetTypeID() };
            dict.find(&ref_key).filter(|r| r.type_of() == keychain_item).map(|r| super::Item::Object((*r).clone()))
        } else {
            data_of(dict.find(&ref_key)).map(super::Item::Persistent)
        };
        match item {
            Some(item) => Ok(Some((value, item))),
            None => Err(Failure::Other(-2)),
        }
    }

    fn protected_attributes(q: &mut Query, value: &[u8]) {
        // SAFETY: reading Security framework constants.
        unsafe {
            q.set(k(kSecValueData), CFData::from_buffer(value).into_CFType());
            q.set(k(kSecAttrAccessible), k(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).into_CFType());
            q.set(k(kSecAttrSynchronizable), CFBoolean::false_value().into_CFType());
        }
    }

    pub(super) fn add(store: Store, account: &str, value: &[u8]) -> Result<Added, Failure> {
        if !matches!(store, Store::Keys | Store::AppId) {
            return Err(Failure::Other(-4));
        }
        let mut q = query(store, Some(account))?;
        protected_attributes(&mut q, value);
        // SAFETY: a valid dictionary; no result is asked for.
        match unsafe { SecItemAdd(q.as_concrete_TypeRef() as CFDictionaryRef, std::ptr::null_mut()) } {
            0 => Ok(Added::New),
            DUPLICATE => Ok(Added::Present),
            other => Err(failure(other)),
        }
    }

    /// Updates the item in place, else adds it: never a delete first.
    pub(super) fn put(store: Store, account: &str, value: &[u8]) -> Result<(), Failure> {
        if !matches!(store, Store::Keys | Store::AppId) {
            return Err(Failure::Other(-4));
        }
        for _ in 0..2 {
            let q = query(store, Some(account))?;
            let mut change = Query::new();
            // SAFETY: reading a Security framework constant.
            unsafe { change.set(k(kSecValueData), CFData::from_buffer(value).into_CFType()) };
            // SAFETY: two valid dictionaries.
            let status = unsafe {
                SecItemUpdate(q.as_concrete_TypeRef() as CFDictionaryRef, change.as_concrete_TypeRef() as CFDictionaryRef)
            };
            match status {
                0 => return Ok(()),
                NOT_FOUND => {}
                other => return Err(failure(other)),
            }
            // A concurrent writer may add it first: then the next round updates it.
            match add(store, account, value)? {
                Added::New => return Ok(()),
                Added::Present => continue,
            }
        }
        Err(Failure::Other(DUPLICATE))
    }

    pub(super) fn list(store: Store, prefix: &str) -> Vec<String> {
        let Ok(mut q) = query(store, None) else { return Vec::new() };
        // SAFETY: reading Security framework constants.
        let account_key = unsafe {
            q.set(k(kSecReturnAttributes), CFBoolean::true_value().into_CFType());
            q.set(k(kSecMatchLimit), k(kSecMatchLimitAll).into_CFType());
            k(kSecAttrAccount)
        };
        let Ok(Some(found)) = copy_matching(&q) else { return Vec::new() };
        let Some(items) = found.downcast::<CFArray>() else { return Vec::new() };
        // SAFETY: a list answer is an array of attribute dictionaries.
        let items: CFArray<CFDictionary<CFString, CFType>> = unsafe { CFArray::wrap_under_get_rule(items.as_concrete_TypeRef()) };
        items
            .iter()
            .filter_map(|item| item.find(&account_key)?.downcast::<CFString>().map(|s| s.to_string()))
            .filter(|a| a.starts_with(prefix))
            .collect()
    }

    pub(super) fn delete(store: Store, account: &str) -> Result<(), Failure> {
        let q = query(store, Some(account))?;
        // SAFETY: a valid dictionary.
        match unsafe { SecItemDelete(q.as_concrete_TypeRef() as CFDictionaryRef) } {
            0 | NOT_FOUND => Ok(()),
            other => Err(failure(other)),
        }
    }

    /// The item object in the file-based keychain (which then ignores the service and
    /// account beside it, so the object alone picks the item), the persistent
    /// reference inside its group, service and account in the protected stores.
    fn delete_query(store: Store, account: &str, item: &super::Item) -> Result<Query, Failure> {
        match (store, item) {
            (Store::Legacy, super::Item::Object(found)) => {
                let mut q = query(store, Some(account))?;
                // SAFETY: reading a Security framework constant.
                unsafe { q.set(k(kSecValueRef), found.clone()) };
                Ok(q)
            }
            (Store::Keys | Store::AppId, super::Item::Persistent(found)) => by_ref(store, account, found),
            _ => Err(Failure::Other(-4)),
        }
    }

    /// Deletes exactly the item a read returned. A rewrite since (a new item, or the
    /// same one updated by another process) answers "not found" and stays.
    pub(super) fn delete_item(store: Store, account: &str, item: &super::Item) -> Result<super::Deleted, Failure> {
        let q = delete_query(store, account, item)?;
        // SAFETY: a valid dictionary.
        match unsafe { SecItemDelete(q.as_concrete_TypeRef() as CFDictionaryRef) } {
            0 => Ok(super::Deleted::Took),
            NOT_FOUND => Ok(super::Deleted::NotFound),
            other => Err(failure(other)),
        }
    }
}

/// The platform store, by store and slot name.
#[cfg_attr(not(any(windows, target_os = "macos")), allow(unused_variables))]
#[cfg_attr(test, allow(dead_code))]
mod real {
    use super::{Added, Failure, Store};

    #[cfg(windows)]
    fn flat(store: Store) -> Result<(), Failure> {
        if store == Store::Flat { Ok(()) } else { Err(Failure::Other(-4)) }
    }

    #[cfg(windows)]
    fn windows_failure(e: String) -> Failure {
        let _ = e;
        Failure::Other(-1)
    }

    pub(super) fn flat_available() -> bool {
        cfg!(windows)
    }

    pub(super) fn has_blob() -> bool {
        cfg!(windows)
    }

    pub(super) fn read(store: Store, name: &str) -> Result<Option<Vec<u8>>, Failure> {
        #[cfg(windows)]
        return flat(store).and_then(|()| super::win::cred_retrieve(name).map_err(windows_failure));
        #[cfg(target_os = "macos")]
        return super::mac::read(store, name);
        #[cfg(not(any(windows, target_os = "macos")))]
        Ok(None)
    }

    pub(super) fn read_ref(store: Store, name: &str) -> Result<super::Found, Failure> {
        #[cfg(target_os = "macos")]
        return super::mac::read_ref(store, name);
        #[cfg(not(target_os = "macos"))]
        Err(Failure::Other(-4))
    }

    pub(super) fn add(store: Store, name: &str, key: &[u8]) -> Result<Added, Failure> {
        #[cfg(target_os = "macos")]
        return super::mac::add(store, name, key);
        #[cfg(not(target_os = "macos"))]
        Err(Failure::Other(-4))
    }

    pub(super) fn put(store: Store, name: &str, key: &[u8]) -> Result<(), Failure> {
        #[cfg(windows)]
        return flat(store).and_then(|()| super::win::cred_store(name, key).map_err(windows_failure));
        #[cfg(target_os = "macos")]
        return super::mac::put(store, name, key);
        #[cfg(not(any(windows, target_os = "macos")))]
        Err(Failure::Other(-4))
    }

    pub(super) fn list(store: Store, prefix: &str) -> Vec<String> {
        #[cfg(windows)]
        return if store == Store::Flat { super::win::cred_list(prefix) } else { Vec::new() };
        #[cfg(target_os = "macos")]
        return super::mac::list(store, prefix);
        #[cfg(not(any(windows, target_os = "macos")))]
        Vec::new()
    }

    pub(super) fn delete(store: Store, name: &str) -> Result<(), Failure> {
        #[cfg(windows)]
        return flat(store).and_then(|()| super::win::cred_delete(name).map_err(windows_failure));
        #[cfg(target_os = "macos")]
        return super::mac::delete(store, name);
        #[cfg(not(any(windows, target_os = "macos")))]
        Ok(())
    }

    pub(super) fn delete_item(store: Store, name: &str, item: &super::Item) -> Result<super::Deleted, Failure> {
        #[cfg(target_os = "macos")]
        return super::mac::delete_item(store, name, item);
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (store, name, item);
            Err(Failure::Other(-4))
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
    use super::test_support::{self as t, fault, Backend, Fault};
    use super::{Added, Deleted, Failure, Item, Store};

    pub(super) fn flat_available() -> bool {
        match t::mode_for(None) {
            Backend::Fake => true,
            Backend::Real => super::real::flat_available(),
        }
    }

    pub(super) fn has_blob() -> bool {
        match t::mode_for(None) {
            Backend::Fake => true,
            Backend::Real => super::real::has_blob(),
        }
    }

    pub(super) fn read(store: Store, name: &str) -> Result<Option<Vec<u8>>, Failure> {
        Ok(found(store, name, false)?.map(|(value, _)| value))
    }

    pub(super) fn read_ref(store: Store, name: &str) -> Result<super::Found, Failure> {
        found(store, name, true)
    }

    fn found(store: Store, name: &str, with_item: bool) -> Result<super::Found, Failure> {
        t::note_read(store, name);
        let found = match t::mode_for(Some(store)) {
            Backend::Fake => {
                t::refusal(store, true)?;
                if store == Store::Legacy && t::stale_after_a_miss() {
                    return Ok(None);
                }
                t::fake_item(store, name).map(|(value, id)| (value, t::fake_handle(store, id)))
            }
            Backend::Real if with_item => super::real::read_ref(store, name)?,
            Backend::Real => super::real::read(store, name)?.map(|v| (v, Item::Persistent(Vec::new()))),
        };
        let after_a_write = t::wrote_since_injected();
        Ok(found.map(|(value, item)| {
            if after_a_write && fault(Fault::ReadBackWrong) {
                return (vec![0x5a; 32], item);
            }
            (value, item)
        })
        .filter(|_| !(after_a_write && fault(Fault::ReadBackMissing))))
    }

    fn write_fault(store: Store, name: &str) -> Result<(), Failure> {
        if name == super::PROBE && fault(Fault::ProbeUnknown) {
            return Err(Failure::Other(-50));
        }
        if name != super::PROBE && fault(Fault::StoreFails) {
            return Err(Failure::Other(-1));
        }
        t::refusal(store, false)
    }

    fn note_write(store: Store, name: &str) {
        if name != super::PROBE {
            t::count_write(store);
            t::note_write_quiet();
        }
    }

    pub(super) fn add(store: Store, name: &str, key: &[u8]) -> Result<Added, Failure> {
        write_fault(store, name)?;
        match t::mode_for(Some(store)) {
            Backend::Fake => {
                if t::fake_item(store, name).is_some() {
                    return Ok(Added::Present);
                }
                t::fake_insert(store, name, key.to_vec());
                note_write(store, name);
                Ok(Added::New)
            }
            Backend::Real => {
                t::note_real_write(store, name);
                super::real::add(store, name, key)
            }
        }
    }

    pub(super) fn put(store: Store, name: &str, key: &[u8]) -> Result<(), Failure> {
        write_fault(store, name)?;
        match t::mode_for(Some(store)) {
            Backend::Fake => {
                t::fake_update_or_insert(store, name, key.to_vec());
                note_write(store, name);
                Ok(())
            }
            Backend::Real => {
                t::note_real_write(store, name);
                super::real::put(store, name, key)
            }
        }
    }

    pub(super) fn list(store: Store, prefix: &str) -> Vec<String> {
        match t::mode_for(Some(store)) {
            Backend::Fake if t::refusal(store, false).is_err() => Vec::new(),
            Backend::Fake => t::fake_names(store, prefix),
            Backend::Real => super::real::list(store, prefix),
        }
    }

    pub(super) fn delete(store: Store, name: &str) -> Result<(), Failure> {
        match t::mode_for(Some(store)) {
            Backend::Fake => {
                t::refusal(store, false)?;
                t::fake_remove(store, name);
                Ok(())
            }
            Backend::Real => super::real::delete(store, name),
        }
    }

    pub(super) fn delete_item(store: Store, name: &str, item: &Item) -> Result<Deleted, Failure> {
        t::count_item_delete();
        if fault(Fault::DeleteRefFails) {
            return Err(Failure::Other(-1));
        }
        match t::mode_for(Some(store)) {
            Backend::Fake => {
                t::refusal(store, false)?;
                let id = match item {
                    Item::Persistent(_) if store == Store::Legacy && fault(Fault::LegacyRefsMiss) => return Ok(Deleted::NotFound),
                    Item::Persistent(id) | Item::FakeObject(id) => id,
                    #[cfg(target_os = "macos")]
                    Item::Object(_) => return Err(Failure::Other(-4)),
                };
                if store == Store::Legacy && fault(Fault::LegacyNotOwner) {
                    return Err(Failure::NotOwner);
                }
                if store == Store::Legacy && fault(Fault::LegacyStaleAfterMiss) {
                    t::miss_and_go_stale();
                    return Ok(Deleted::NotFound);
                }
                if fault(Fault::DeleteRefLeaves) {
                    return Ok(Deleted::Took);
                }
                Ok(if t::fake_remove_ref(store, id) { Deleted::Took } else { Deleted::NotFound })
            }
            Backend::Real => super::real::delete_item(store, name, item),
        }
    }

    const FAKE_TAG: &[u8] = b"FAKEBLOB";

    pub(super) fn protect(data: &[u8]) -> Result<Vec<u8>, String> {
        match t::mode_for(None) {
            Backend::Fake => Ok([FAKE_TAG, data].concat()),
            Backend::Real => super::real::protect(data),
        }
    }

    pub(super) fn unprotect(data: &[u8]) -> Result<Vec<u8>, String> {
        match t::mode_for(None) {
            Backend::Fake if fault(Fault::BlobWrong) => Ok(vec![0x6b; 32]),
            Backend::Fake => data
                .strip_prefix(FAKE_TAG)
                .map(<[u8]>::to_vec)
                .ok_or_else(|| "fake blob does not open".to_string()),
            Backend::Real => super::real::unprotect(data),
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
/// macOS writes only the protected keychain, in place, never a delete first.
pub(crate) fn store_key_at(root: &Path, key: &[u8]) -> Result<(), String> {
    let Writable::Yes(store) = protected_writable() else {
        return Err("OS keychain not available on this platform".into());
    };
    without_prompts(|| put(store, &profile_slot(root), key))
        .map_err(|f| format!("The OS keychain did not keep the key ({f:?})"))?;
    if backend::has_blob()
        && let Ok(blob) = backend::protect(key)
    {
        let _ = replace_file(&blob_path(root), &blob);
    }
    Ok(())
}

/// The first value `name` holds in `stores`, in order; failures read as nothing.
fn first_of(stores: &[Store], name: &str) -> Option<Vec<u8>> {
    stores.iter().find_map(|s| read(*s, name).ok().flatten())
}

/// Every value `name` holds in `stores`, in order; failures read as nothing.
fn every_of(stores: &[Store], name: &str) -> Vec<Vec<u8>> {
    stores.iter().filter_map(|s| read(*s, name).ok().flatten()).collect()
}

/// This root's conflict copies in the protected stores.
fn copies_of(root: &Path) -> Vec<(Store, String)> {
    let prefix = format!("{}{COPY_MARK}", profile_slot(root));
    protected_stores()
        .iter()
        .flat_map(|s| list(*s, &prefix).into_iter().map(move |n| (*s, n)))
        .collect()
}

/// Every stored candidate for `root`, most authoritative first. A caller MUST check
/// that a candidate opens the identity before trusting it: the legacy slot routinely
/// holds another profile's key.
#[cfg(test)]
pub(crate) fn candidates_at(root: &Path) -> Vec<(Source, Vec<u8>)> {
    let mut out: Vec<(Source, Vec<u8>)> = Vec::new();
    let mut push = |source, key: Option<Vec<u8>>| {
        if let Some(key) = key
            && !out.iter().any(|(_, k)| *k == key)
        {
            out.push((source, key));
        }
    };
    for source in [Source::Profile, Source::Rekey, Source::Legacy, Source::Unmoved, Source::Blob] {
        for key in read_source(root, source) {
            push(source, Some(key));
        }
    }
    for (store, name) in copies_of(root) {
        push(Source::Copy, read(store, &name).ok().flatten());
    }
    out
}

/// What `source` holds for `root`, most authoritative first.
fn read_source(root: &Path, source: Source) -> Vec<Vec<u8>> {
    match source {
        // Every group, not the first answer: a stale key in the keys group must not
        // hide the one in the app-ID group that opens the file.
        Source::Profile => every_of(protected_stores(), &profile_slot(root)),
        Source::Rekey => every_of(protected_stores(), &rekey_slot(root)),
        Source::Legacy => every_of(protected_stores(), &legacy_slot()),
        Source::Unmoved if mac_layout() => [profile_slot(root), legacy_slot()]
            .iter()
            .filter_map(|name| read(Store::Legacy, name).ok().flatten())
            .collect(),
        Source::Blob => read_blob_key_at(root).into_iter().collect(),
        Source::Unmoved | Source::Copy | Source::Scan => Vec::new(),
    }
}

/// The first stored key, most authoritative first, that opens `identity`. Stops at
/// the first that does, so the shared legacy slot is read only when this profile's
/// own slot and copies fail (on macOS a read of an item another build wrote can
/// prompt).
pub(crate) fn key_that_opens(root: &Path, identity: &[u8]) -> Option<(Source, zeroize::Zeroizing<[u8; 32]>)> {
    let opens = |bytes: Vec<u8>| {
        let bytes = zeroize::Zeroizing::new(bytes);
        let key = zeroize::Zeroizing::new(<[u8; 32]>::try_from(bytes.as_slice()).ok()?);
        super::encryption::decrypt_identity(identity, &key).is_ok().then_some(key)
    };
    let own = |source| read_source(root, source).into_iter().find_map(&opens).map(|key| (source, key));
    // A re-key cut short leaves the files on the key it staged.
    if let Some(found) = own(Source::Profile).or_else(|| own(Source::Rekey)) {
        return Some(found);
    }
    let copies = copies_of(root);
    if let Some(found) = copies.iter().find_map(|(s, n)| opens(read(*s, n).ok()??).map(|key| (Source::Copy, key))) {
        return Some(found);
    }
    // One login item at a time: each read there may ask the person.
    let unmoved = || {
        mac_layout()
            .then(|| [profile_slot(root), legacy_slot()])
            .into_iter()
            .flatten()
            .find_map(|name| opens(read(Store::Legacy, &name).ok()??))
            .map(|key| (Source::Unmoved, key))
    };
    let known = own(Source::Legacy).or_else(unmoved).or_else(|| own(Source::Blob));
    if known.is_some() {
        return known;
    }
    let tried = profile_slot(root);
    without_prompts(|| {
        every_store()
            .iter()
            .flat_map(|s| list(*s, &format!("{}.", base())).into_iter().map(move |n| (*s, n)))
            .filter(|(_, name)| *name != tried && !copies.iter().any(|(_, c)| c == name))
            .take(SCAN_LIMIT)
            .find_map(|(s, name)| opens(read(s, &name).ok()??).map(|key| (Source::Scan, key)))
    })
}

/// Deletes this root's conflict copies once its key is proven where it belongs.
pub(crate) fn drop_copies(root: &Path) {
    without_prompts(|| {
        for (store, name) in copies_of(root) {
            let _ = delete(store, &name);
        }
    });
}

/// A new read of this profile's own slot, for checking a write landed.
pub(crate) fn read_profile_key_at(root: &Path) -> Result<Option<Vec<u8>>, String> {
    let name = profile_slot(root);
    let mut failed = None;
    for store in protected_stores() {
        match read(*store, &name) {
            Ok(Some(key)) => return Ok(Some(key)),
            Ok(None) | Err(Failure::Refused) => {}
            Err(f) => failed = Some(f),
        }
    }
    match failed {
        Some(f) => Err(format!("The OS keychain did not answer ({f:?})")),
        None => Ok(None),
    }
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
        profile: first_of(protected_stores(), &profile_slot(root)),
        blob_file: std::fs::read(blob_path(root)).ok(),
    }
}

pub(crate) fn restore_snapshot(root: &Path, snap: &Snapshot) {
    let slot = profile_slot(root);
    without_prompts(|| match (&snap.profile, protected_writable()) {
        (Some(key), Writable::Yes(store)) => {
            let _ = put(store, &slot, key);
        }
        (Some(_), _) => {}
        (None, _) => {
            for store in protected_stores() {
                let _ = delete(*store, &slot);
            }
        }
    });
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

/// The machine-slot items (in every store, its conflict copies too) whose key opens
/// `identity` (an HKEYV1 file). Only a keychain identity's key was ever kept there; a
/// wipe of any other reads nothing (a read can prompt on macOS, and a duress wipe
/// must show nothing).
fn machine_items_opening(identity: &[u8]) -> Vec<(Store, String)> {
    let keychain = matches!(
        super::encryption::detect_format(identity),
        Ok(super::encryption::IdentityFormat::Encrypted { flags, .. })
            if super::encryption::flags_has_os_keychain(flags)
    );
    if !keychain {
        return Vec::new();
    }
    let machine = legacy_slot();
    let copies = format!("{machine}{COPY_MARK}");
    without_prompts(|| {
        every_store()
            .iter()
            .flat_map(|s| {
                let mut names = vec![machine.clone()];
                if *s != Store::Legacy {
                    names.extend(list(*s, &copies));
                }
                names.into_iter().map(move |n| (*s, n))
            })
            .filter(|(s, name)| {
                let Ok(Some(key)) = read(*s, name) else { return false };
                let Ok(key) = <[u8; 32]>::try_from(key.as_slice()) else { return false };
                super::encryption::decrypt_identity(identity, &key).is_ok()
            })
            .collect()
    })
}

/// Forgets the key a profile's identity was kept under: its own slot, its conflict
/// copies and its blob always, in every keychain, and the machine slot's items only
/// where each is proven to be this identity's. `identity_before` is the identity file
/// as it was BEFORE the change, read before anything was zeroed or rewritten; `None`
/// (nothing to prove it with) keeps the machine slot.
pub(crate) fn forget_key_at(root: &Path, identity_before: Option<&[u8]>) {
    let machine = identity_before.map(machine_items_opening).unwrap_or_default();
    forget_items(root, &machine);
}

/// [`forget_key_at`] with the legacy proof already taken.
pub(crate) fn forget_key_proven(root: &Path, legacy_is_ours: bool) {
    let machine: Vec<(Store, String)> = if legacy_is_ours {
        every_store().iter().map(|s| (*s, legacy_slot())).collect()
    } else {
        Vec::new()
    };
    forget_items(root, &machine);
}

fn forget_items(root: &Path, machine: &[(Store, String)]) {
    let _ = std::fs::remove_file(blob_path(root));
    let own = profile_slot(root);
    let copies = format!("{own}{COPY_MARK}");
    let staged = rekey_slot(root);
    without_prompts(|| {
        for store in every_store() {
            let _ = delete(*store, &own);
            let _ = delete(*store, &staged);
            for name in list(*store, &copies) {
                let _ = delete(*store, &name);
            }
        }
        for (store, name) in machine {
            let _ = delete(*store, name);
        }
    });
}

/// One point of a move or a re-key, for the tests' hook; a hook answering false is a
/// process that died there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Read,
    Copied,
    ReadBack,
    Deleted,
    /// The re-key's new key is stored and read back.
    RekeyStaged,
    /// `identity.key` is on the new key.
    RekeyKeyFile,
    /// `identity.device` is on the new key.
    RekeyDeviceFile,
    /// The pair a phrase restore set aside is on the new key.
    RekeyLockedFiles,
    /// The profile slot holds the new key.
    RekeyPromoted,
    /// The staged name is gone.
    RekeyUnstaged,
}

pub(crate) fn step(at: Step, name: &str) -> bool {
    #[cfg(test)]
    return test_support::run_hook(at, name);
    #[cfg(not(test))]
    {
        let _ = (at, name);
        true
    }
}

/// What one start's move did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Moved {
    pub(crate) moved: usize,
    /// Copied but the source stays (a copy that did not read back, a failed delete).
    pub(crate) kept: usize,
    /// Never touched: a read that would prompt or failed, a value not a key.
    pub(crate) skipped: usize,
    /// Copied, and the login keychain refused the delete: only the app that made
    /// the item may delete it. The re-key makes such an item's key open nothing.
    pub(crate) held: usize,
    /// Left as it is: the protected name holds another key, or the copy was already
    /// there and the key opens nothing of ours.
    pub(crate) left: usize,
    /// Protected copies written this start.
    pub(crate) wrote: usize,
}

impl Moved {
    /// Whether this start changed or learned anything worth one log line. A start
    /// that only met items it already copied says nothing.
    pub(crate) fn news(&self) -> bool {
        self.moved + self.kept + self.skipped + self.wrote > 0
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Outcome {
    Moved,
    Kept,
    Skipped,
    Held,
    Left,
    Died,
}

/// [`settle_move_judged`] that treats every key as ours, for the tests.
#[cfg(test)]
pub(crate) fn settle_move(root: &Path) -> Moved {
    settle_move_judged(root, &|_| true)
}

/// macOS, once per start before any unlock: every Hollow key in the file-based
/// keychain moves into the protected keychain, and where the keys group works,
/// every key still in the app-ID group moves into it. Each item is copied, the copy
/// read back byte for byte, and only then is exactly the item that was read
/// deleted, so no store is ever without the key and a key another process wrote
/// meanwhile stays. An item counts as moved only once a new read of its name finds
/// nothing. A login item whose protected copy a past start made is deleted again
/// only while `ours` says its key still opens one of this profile's files: macOS
/// refuses every later try at an item only its maker may delete. Runs only where
/// the keystore answered a definite yes.
pub(crate) fn settle_move_judged(root: &Path, ours: &dyn Fn(&[u8]) -> bool) -> Moved {
    let mut done = Moved::default();
    if !mac_layout() {
        return done;
    }
    let Writable::Yes(target) = protected_writable() else { return done };
    let first = [profile_slot(root), legacy_slot()];
    without_prompts(|| {
        if move_store(Store::Legacy, target, &first, slot_name, ours, &mut done) && target == Store::Keys {
            move_store(Store::AppId, Store::Keys, &first, our_name, ours, &mut done);
        }
    });
    done
}

/// False when the process "died" in a test hook.
fn move_store(
    from: Store,
    to: Store,
    first: &[String],
    name_ok: fn(&str) -> bool,
    ours: &dyn Fn(&[u8]) -> bool,
    done: &mut Moved,
) -> bool {
    let mut names: Vec<String> = list(from, base()).into_iter().filter(|n| name_ok(n)).collect();
    names.sort();
    names.dedup();
    names.sort_by_key(|n| !first.iter().any(|f| f == n));
    for name in names.into_iter().take(MOVE_LIMIT) {
        match move_one(from, to, &name, ours, done) {
            Outcome::Moved => done.moved += 1,
            Outcome::Kept => done.kept += 1,
            Outcome::Skipped => done.skipped += 1,
            Outcome::Held => done.held += 1,
            Outcome::Left => done.left += 1,
            Outcome::Died => return false,
        }
    }
    true
}

fn move_one(from: Store, to: Store, name: &str, ours: &dyn Fn(&[u8]) -> bool, done: &mut Moved) -> Outcome {
    let (value, item) = match read_ref(from, name) {
        Ok(Some(found)) => found,
        Ok(None) => {
            crate::hollow_log!("[HOLLOW-ID] Keychain move: a listed item was gone by its read; it is left alone");
            return Outcome::Skipped;
        }
        Err(f) => {
            crate::hollow_log!("[HOLLOW-ID] Keychain move: an item did not read ({f:?}); it is left alone");
            return Outcome::Skipped;
        }
    };
    let value = zeroize::Zeroizing::new(value);
    if value.len() != 32 {
        crate::hollow_log!("[HOLLOW-ID] Keychain move: an item under our name is not a 32-byte key; it is left alone");
        return Outcome::Skipped;
    }
    if !step(Step::Read, name) {
        return Outcome::Died;
    }
    let from_login = from == Store::Legacy;
    let placed = match place_copy(to, name, &value, !from_login) {
        Ok(placed) => placed,
        Err(why) => {
            crate::hollow_log!("[HOLLOW-ID] Keychain move: no protected copy could be made ({why}); the old item stays");
            return Outcome::Kept;
        }
    };
    let (target, fresh) = match placed {
        Placed::New(target) => {
            done.wrote += 1;
            (target, true)
        }
        Placed::Had(target) => (target, false),
        // Never deleted, so no copy is needed: the profile it belongs to re-keys
        // off it at its own next start.
        Placed::Differs => return Outcome::Left,
    };
    if !step(Step::Copied, name) {
        return Outcome::Died;
    }
    if !matches!(read(to, &target).map(|v| v.map(zeroize::Zeroizing::new)), Ok(Some(back)) if same(&back, &value)) {
        crate::hollow_log!("[HOLLOW-ID] A moved keychain item did not read back; the old one stays");
        return Outcome::Kept;
    }
    if !step(Step::ReadBack, name) {
        return Outcome::Died;
    }
    if from_login && !fresh && !ours(&value) {
        return Outcome::Left;
    }
    take_source(from, name, &value, &item, fresh)
}

/// Deletes exactly the item the move read. Moved only when the delete removed an
/// item AND a new read of the name finds nothing: a delete and a check that share one
/// lookup agree on "gone" when that lookup misses the item, and after another
/// process's rewrite this process's read can miss the new key while it stands. An
/// item only its maker may delete is held; `say` logs it the first time.
fn take_source(from: Store, name: &str, value: &[u8], item: &Item, say: bool) -> Outcome {
    let took = match delete_item(from, name, item) {
        Ok(took) => took,
        Err(Failure::NotOwner) => {
            if say {
                crate::hollow_log!("[HOLLOW-ID] Keychain move: the old login item stays (only the app that made it may delete it)");
            }
            return Outcome::Held;
        }
        Err(f) => {
            crate::hollow_log!("[HOLLOW-ID] Keychain move: the old item was not deleted ({f:?}); it stays for the next start");
            return Outcome::Kept;
        }
    };
    if !step(Step::Deleted, name) {
        return Outcome::Died;
    }
    if took == Deleted::NotFound {
        crate::hollow_log!("[HOLLOW-ID] Keychain move: the delete found no item (another process rewrote or took it); what is there stays for the next start");
        return Outcome::Kept;
    }
    match read(from, name).map(|v| v.map(zeroize::Zeroizing::new)) {
        Ok(None) => Outcome::Moved,
        Ok(Some(left)) if same(&left, value) => {
            crate::hollow_log!("[HOLLOW-ID] Keychain move: the old item is still there after its delete; it stays for the next start");
            Outcome::Kept
        }
        // Another process wrote a new key under the name since: it stays, for the next start to move.
        Ok(Some(_)) => Outcome::Kept,
        Err(f) => {
            crate::hollow_log!("[HOLLOW-ID] Keychain move: the old item did not read after its delete ({f:?}); it stays for the next start");
            Outcome::Kept
        }
    }
}

/// Where a copy went.
#[derive(Debug, PartialEq, Eq)]
enum Placed {
    /// Written now, under this name.
    New(String),
    /// A past start (or another mover) put the same key there.
    Had(String),
    /// The name holds another key and no conflict copy was asked for.
    Differs,
}

/// Puts `value` under `name` in `to`, or, with `conflict_copy`, under its conflict
/// copy when `name` holds another key there; never overwrites a key. The error says
/// which call failed and how, without the value.
fn place_copy(to: Store, name: &str, value: &[u8], conflict_copy: bool) -> Result<Placed, String> {
    let targets = if conflict_copy { vec![name.to_string(), copy_name(name, value)] } else { vec![name.to_string()] };
    for target in targets {
        let held = match read(to, &target).map(|v| v.map(zeroize::Zeroizing::new)) {
            Ok(None) => match add(to, &target, value) {
                Ok(Added::New) => return Ok(Placed::New(target)),
                Ok(Added::Present) => match read(to, &target) {
                    Ok(Some(held)) => zeroize::Zeroizing::new(held),
                    Ok(None) => return Err("add found the name taken, a read found nothing".into()),
                    Err(f) => return Err(format!("read after a taken add {f:?}")),
                },
                Err(f) => return Err(format!("add {f:?}")),
            },
            Ok(Some(held)) => held,
            Err(f) => return Err(format!("read {f:?}")),
        };
        if same(&held, value) {
            return Ok(Placed::Had(target));
        }
    }
    if conflict_copy { Err("the slot and its copy hold other keys".into()) } else { Ok(Placed::Differs) }
}

// -- The re-key's keystore side (macOS, `keychain_rekey`) --

/// The login keychain names a re-key of `root` reads: this root's own slot and the
/// machine slot first (as the move takes them), so items planted under our naming
/// that sort earlier never push ours past the limit.
fn login_names(root: &Path) -> Vec<String> {
    let first = [profile_slot(root), legacy_slot()];
    let mut rest: Vec<String> =
        list(Store::Legacy, base()).into_iter().filter(|n| slot_name(n) && !first.contains(n)).collect();
    rest.sort();
    rest.dedup();
    first.into_iter().chain(rest).take(MOVE_LIMIT).collect()
}

/// A stored value as a key, wiped when dropped either way.
fn as_key(value: Vec<u8>) -> Option<zeroize::Zeroizing<[u8; 32]>> {
    let value = zeroize::Zeroizing::new(value);
    <[u8; 32]>::try_from(value.as_slice()).ok().map(zeroize::Zeroizing::new)
}

/// Every 32-byte key a quiet read finds under our slot names in the file-based
/// keychain, at most [`MOVE_LIMIT`], `root`'s own slot and the machine slot first.
/// An item that would ask is left out: it asks an old build too.
pub(crate) fn login_keys(root: &Path) -> Vec<zeroize::Zeroizing<[u8; 32]>> {
    if !mac_layout() {
        return Vec::new();
    }
    without_prompts(|| login_names(root).iter().filter_map(|n| read(Store::Legacy, n).ok().flatten()).filter_map(as_key).collect())
}

/// The new key a re-key staged for `root`. Of one per protected group, the one
/// `opens` accepts (it opens a file of `root`'s), else the first.
pub(crate) fn staged_key(root: &Path, opens: &dyn Fn(&[u8]) -> bool) -> Option<zeroize::Zeroizing<[u8; 32]>> {
    let name = rekey_slot(root);
    let staged: Vec<_> =
        without_prompts(|| protected_stores().iter().filter_map(|s| read(*s, &name).ok().flatten()).filter_map(as_key).collect());
    let pick = staged.iter().position(|k| opens(&k[..])).unwrap_or(0);
    staged.into_iter().nth(pick)
}

/// Stores `key` as `root`'s staged key and answers what a NEW read finds there: the
/// key itself, or the one another mover staged first (never overwritten).
pub(crate) fn stage_key(root: &Path, key: &[u8; 32]) -> Result<zeroize::Zeroizing<[u8; 32]>, String> {
    let Writable::Yes(store) = protected_writable() else {
        return Err("the protected keychain takes no key now".into());
    };
    let name = rekey_slot(root);
    without_prompts(|| add(store, &name, key)).map_err(|f| format!("stage {f:?}"))?;
    match without_prompts(|| read(store, &name)) {
        Ok(Some(back)) => as_key(back).ok_or_else(|| "the staged key is not 32 bytes".to_string()),
        Ok(None) => Err("the staged key did not read back".into()),
        Err(f) => Err(format!("staged read {f:?}")),
    }
}

/// Deletes `root`'s staged key from each protected store whose value `keep` refuses:
/// a value a file still needs is never deleted, and a store that did not answer
/// keeps what it holds.
pub(crate) fn unstage(root: &Path, keep: &dyn Fn(&[u8]) -> bool) {
    let name = rekey_slot(root);
    without_prompts(|| {
        for store in protected_stores() {
            if let Ok(Some(value)) = read(*store, &name)
                && !keep(&zeroize::Zeroizing::new(value))
            {
                let _ = delete(*store, &name);
            }
        }
    });
}

/// After a re-key promoted the key every file opens with (`needed` says which keys a
/// file of `root`'s still needs): `root`'s profile slot in a group holding a key no
/// file needs, its conflict copies, a protected machine-slot copy of an `old` key
/// (one proven to have opened these files) that no file needs and no login item
/// mirrors (a mirrored one would only be copied back by the next start), and one
/// quiet try at every login item holding an `old` key. Answers how many such login
/// items stay.
pub(crate) fn retire(root: &Path, old: &[zeroize::Zeroizing<[u8; 32]>], needed: &dyn Fn(&[u8]) -> bool) -> usize {
    let slot = profile_slot(root);
    let machine = legacy_slot();
    let held = |store: Store, name: &str| read(store, name).ok().flatten().map(zeroize::Zeroizing::new);
    without_prompts(|| {
        for store in protected_stores() {
            if held(*store, &slot).is_some_and(|v| !needed(&v)) {
                let _ = delete(*store, &slot);
            }
        }
        let mirrored = held(Store::Legacy, &machine);
        for store in protected_stores() {
            let Some(value) = held(*store, &machine) else { continue };
            let proven = old.iter().any(|k| same(&value, &k[..]));
            if proven && !needed(&value) && !mirrored.as_ref().is_some_and(|m| same(m, &value)) {
                let _ = delete(*store, &machine);
            }
        }
    });
    drop_copies(root);
    delete_login_holding(root, old).1
}

/// One quiet try at deleting every login item holding one of `old`; answers how many
/// went and how many stay (only their maker may delete them, or the delete failed).
pub(crate) fn delete_login_holding(root: &Path, old: &[zeroize::Zeroizing<[u8; 32]>]) -> (usize, usize) {
    if !mac_layout() || old.is_empty() {
        return (0, 0);
    }
    without_prompts(|| {
        let (mut gone, mut stay) = (0, 0);
        for name in login_names(root) {
            let Ok(Some((value, item))) = read_ref(Store::Legacy, &name) else { continue };
            let value = zeroize::Zeroizing::new(value);
            if !old.iter().any(|k| same(&value, &k[..])) {
                continue;
            }
            match take_source(Store::Legacy, &name, &value, &item, false) {
                Outcome::Moved => gone += 1,
                _ => stay += 1,
            }
        }
        (gone, stay)
    })
}

#[cfg(test)]
pub(crate) mod test_support {
    //! The per-thread fake stores, the switch to the real one, injected faults and
    //! the move's hook.

    use std::cell::{Cell, RefCell};
    use std::collections::HashMap;

    use super::{Failure, Step, Store};

    #[derive(Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Mode {
        Fake,
        Real,
        /// The real file-based keychain beside fake protected stores: what an
        /// unsigned test binary can prove of the move and the re-key on this Mac.
        #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
        LoginReal,
    }

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    pub(crate) enum Fault {
        StoreFails,
        ReadBackMissing,
        ReadBackWrong,
        BlobWrong,
        /// The keys group answers `errSecMissingEntitlement`.
        KeysRefused,
        /// The app-ID group answers `errSecMissingEntitlement`.
        AppIdRefused,
        /// The probe gets an answer that is neither yes nor no.
        ProbeUnknown,
        /// Reads of the file-based keychain would ask the person.
        LegacyAsks,
        /// Reads of the file-based keychain ask the person, who allows each one: a
        /// read with prompts off fails, one with prompts on answers.
        LegacyAsksPerson,
        DeleteRefFails,
        /// A delete by reference answers success but the item stays.
        DeleteRefLeaves,
        /// A persistent reference finds nothing in the file-based keychain: a delete
        /// by one answers "not found" and the item stays.
        LegacyRefsMiss,
        /// Another process rewrote the file-based item: the delete answers "not
        /// found", the item stays, and this process's reads miss it from then on.
        LegacyStaleAfterMiss,
        /// The login keychain lets only the item's maker delete it
        /// (`errSecInvalidOwnerEdit`, field report 2026-11-14).
        LegacyNotOwner,
    }

    type Hook = Box<dyn FnMut(Step, &str) -> bool>;
    type Items = HashMap<(Store, String), (Vec<u8>, u64)>;

    thread_local! {
        static MODE: Cell<Mode> = const { Cell::new(Mode::Fake) };
        static LAYOUT: Cell<Option<bool>> = const { Cell::new(None) };
        static UNCHECKED: Cell<bool> = const { Cell::new(false) };
        static FAKE: RefCell<Items> = RefCell::new(HashMap::new());
        static NEXT_ID: Cell<u64> = const { Cell::new(1) };
        static FAULTS: RefCell<Vec<Fault>> = const { RefCell::new(Vec::new()) };
        static LEGACY: RefCell<Option<String>> = const { RefCell::new(None) };
        static REAL_WRITES: RefCell<Vec<(Store, String)>> = const { RefCell::new(Vec::new()) };
        static WRITES: Cell<u32> = const { Cell::new(0) };
        static LEGACY_WRITES: Cell<u32> = const { Cell::new(0) };
        static ARMED: Cell<bool> = const { Cell::new(false) };
        static READS: RefCell<Vec<(Store, String)>> = const { RefCell::new(Vec::new()) };
        static QUIET: Cell<u32> = const { Cell::new(0) };
        static LOUD_WRITES: Cell<u32> = const { Cell::new(0) };
        static WRITABLE: Cell<u8> = const { Cell::new(0) };
        static PROBES: Cell<u32> = const { Cell::new(0) };
        static HOOK: RefCell<Option<Hook>> = const { RefCell::new(None) };
        static STALE: Cell<bool> = const { Cell::new(false) };
        static BASE: Cell<Option<&'static str>> = const { Cell::new(None) };
        static ITEM_DELETES: Cell<u32> = const { Cell::new(0) };
        static LOUD_LEGACY_READS: Cell<u32> = const { Cell::new(0) };
    }

    pub(crate) fn count_item_delete() {
        ITEM_DELETES.with(|d| d.set(d.get() + 1));
    }

    /// Deletes of one item (by its object or reference) on this thread since the last call.
    pub(crate) fn take_item_deletes() -> u32 {
        ITEM_DELETES.with(|d| d.replace(0))
    }

    /// Slot names on this thread start with `base` instead (the real login-keychain
    /// tests, so a move there never meets another test's items).
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(crate) fn set_base(base: Option<&'static str>) {
        BASE.with(|b| b.set(base));
    }

    pub(crate) fn base_override() -> Option<&'static str> {
        BASE.with(Cell::get)
    }

    pub(crate) fn rekey_slot_name(root: &std::path::Path) -> String {
        super::rekey_slot(root)
    }

    /// Runs the code under the macOS layout (`true`) or the flat one, whatever the
    /// host; `None` = the host's own. Clears the writability answer kept so far.
    pub(crate) fn use_mac_layout(mac: Option<bool>) {
        LAYOUT.with(|l| l.set(mac));
        WRITABLE.with(|w| w.set(0));
    }

    pub(crate) fn layout() -> Option<bool> {
        LAYOUT.with(Cell::get)
    }

    /// The bundle self-check has not passed (`true`) on this thread.
    pub(crate) fn set_unchecked(unchecked: bool) {
        UNCHECKED.with(|u| u.set(unchecked));
    }

    pub(crate) fn unchecked() -> bool {
        UNCHECKED.with(Cell::get)
    }

    pub(crate) fn writable_cache() -> u8 {
        WRITABLE.with(Cell::get)
    }

    pub(crate) fn set_writable_cache(code: u8) {
        WRITABLE.with(|w| w.set(code));
    }

    pub(crate) fn count_probe() {
        PROBES.with(|p| p.set(p.get() + 1));
    }

    /// Probes run on this thread since the last call.
    pub(crate) fn take_probes() -> u32 {
        PROBES.with(|p| p.replace(0))
    }

    /// Runs `hook` at every step of every move on this thread until cleared.
    pub(crate) fn set_hook(hook: impl FnMut(Step, &str) -> bool + 'static) {
        HOOK.with(|h| *h.borrow_mut() = Some(Box::new(hook)));
    }

    pub(crate) fn clear_hook() {
        HOOK.with(|h| *h.borrow_mut() = None);
    }

    /// The hook is taken out while it runs, so it may start a move of its own.
    pub(crate) fn run_hook(at: Step, name: &str) -> bool {
        let Some(mut hook) = HOOK.with(|h| h.borrow_mut().take()) else { return true };
        let go_on = hook(at, name);
        HOOK.with(|h| {
            let mut slot = h.borrow_mut();
            if slot.is_none() {
                *slot = Some(hook);
            }
        });
        go_on
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

    /// Reads of the file-based keychain on this thread, since the last call, that
    /// were allowed to ask the person.
    pub(crate) fn take_loud_legacy_reads() -> u32 {
        LOUD_LEGACY_READS.with(|w| w.replace(0))
    }

    pub(crate) fn note_read(store: Store, name: &str) {
        if store == Store::Legacy && QUIET.with(Cell::get) == 0 {
            LOUD_LEGACY_READS.with(|w| w.set(w.get() + 1));
        }
        READS.with(|r| r.borrow_mut().push((store, name.to_string())));
    }

    /// True when the legacy slot was read on this thread since the last call.
    pub(crate) fn legacy_was_read() -> bool {
        let legacy = super::legacy_slot();
        READS.with(|r| std::mem::take(&mut *r.borrow_mut())).iter().any(|(_, n)| *n == legacy)
    }

    /// Every keystore read on this thread since the last call.
    pub(crate) fn take_reads() -> Vec<(Store, String)> {
        READS.with(|r| std::mem::take(&mut *r.borrow_mut()))
    }

    pub(crate) fn count_write(store: Store) {
        WRITES.with(|w| w.set(w.get() + 1));
        if store == Store::Legacy {
            LEGACY_WRITES.with(|w| w.set(w.get() + 1));
        }
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

    /// Writes into the file-based keychain since the last call: always 0 (rule 1).
    pub(crate) fn take_legacy_writes() -> u32 {
        LEGACY_WRITES.with(|w| w.replace(0))
    }

    /// Every real slot a test writes is deleted when its [`RealKeystore`] drops.
    pub(crate) fn note_real_write(store: Store, name: &str) {
        REAL_WRITES.with(|w| {
            let mut w = w.borrow_mut();
            if !w.iter().any(|(s, n)| *s == store && n == name) {
                w.push((store, name.to_string()));
            }
        });
    }

    pub(crate) fn mode() -> Mode {
        MODE.with(Cell::get)
    }

    /// The backend `store` takes: the login-only mode is real only for the
    /// file-based keychain; `None` (the blob) is fake there.
    pub(crate) fn mode_for(store: Option<Store>) -> Backend {
        match (mode(), store) {
            (Mode::Real, _) | (Mode::LoginReal, Some(Store::Legacy)) => Backend::Real,
            _ => Backend::Fake,
        }
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Backend {
        Fake,
        Real,
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
        STALE.with(|s| s.set(false));
    }

    pub(crate) fn miss_and_go_stale() {
        STALE.with(|s| s.set(true));
    }

    /// Reads of the file-based keychain miss its items (`Fault::LegacyStaleAfterMiss`).
    pub(crate) fn stale_after_a_miss() -> bool {
        STALE.with(Cell::get) && fault(Fault::LegacyStaleAfterMiss)
    }

    /// What the fake store answers before touching `store`.
    pub(crate) fn refusal(store: Store, reading: bool) -> Result<(), Failure> {
        match store {
            Store::Keys if fault(Fault::KeysRefused) => Err(Failure::Refused),
            Store::AppId if fault(Fault::AppIdRefused) => Err(Failure::Refused),
            Store::Legacy if reading && fault(Fault::LegacyAsks) => Err(Failure::WouldAsk),
            Store::Legacy if reading && fault(Fault::LegacyAsksPerson) && QUIET.with(Cell::get) > 0 => {
                Err(Failure::WouldAsk)
            }
            _ => Ok(()),
        }
    }

    /// Empties every fake store on this thread.
    pub(crate) fn reset_fakes() {
        FAKE.with(|m| m.borrow_mut().clear());
    }

    pub(crate) fn fake_item(store: Store, name: &str) -> Option<(Vec<u8>, Vec<u8>)> {
        FAKE.with(|m| m.borrow().get(&(store, name.to_string())).map(|(v, id)| (v.clone(), id.to_le_bytes().to_vec())))
    }

    /// A new item: a new reference.
    pub(crate) fn fake_insert(store: Store, name: &str, value: Vec<u8>) {
        let id = NEXT_ID.with(|n| n.replace(n.get() + 1));
        FAKE.with(|m| m.borrow_mut().insert((store, name.to_string()), (value, id)));
    }

    /// An update keeps the item, so its reference stays.
    pub(crate) fn fake_update_or_insert(store: Store, name: &str, value: Vec<u8>) {
        let updated = FAKE.with(|m| match m.borrow_mut().get_mut(&(store, name.to_string())) {
            Some(item) => {
                item.0 = value.clone();
                true
            }
            None => false,
        });
        if !updated {
            fake_insert(store, name, value);
        }
    }

    pub(crate) fn fake_remove(store: Store, name: &str) {
        FAKE.with(|m| m.borrow_mut().remove(&(store, name.to_string())));
    }

    /// True when an item went.
    pub(crate) fn fake_remove_ref(store: Store, item: &[u8]) -> bool {
        FAKE.with(|m| {
            let mut m = m.borrow_mut();
            let before = m.len();
            m.retain(|(s, _), (_, id)| !(*s == store && id.to_le_bytes() == item));
            m.len() < before
        })
    }

    /// What a fake read hands back to delete with: an item object in the
    /// file-based keychain, a persistent reference in the protected stores.
    pub(crate) fn fake_handle(store: Store, id: Vec<u8>) -> super::Item {
        if store == Store::Legacy { super::Item::FakeObject(id) } else { super::Item::Persistent(id) }
    }

    pub(crate) fn fake_names(store: Store, prefix: &str) -> Vec<String> {
        FAKE.with(|m| {
            m.borrow().keys().filter(|(s, n)| *s == store && n.starts_with(prefix)).map(|(_, n)| n.clone()).collect()
        })
    }

    /// What an old build does to the file-based keychain: delete, then add a new
    /// item. Not counted as a write of ours.
    pub(crate) fn old_build_writes(name: &str, value: &[u8]) {
        fake_remove(Store::Legacy, name);
        fake_insert(Store::Legacy, name, value.to_vec());
    }

    /// Puts an item straight into a fake store, as another process would.
    pub(crate) fn plant(store: Store, name: &str, value: &[u8]) {
        fake_update_or_insert(store, name, value.to_vec());
    }

    pub(crate) fn held(store: Store, name: &str) -> Option<Vec<u8>> {
        fake_item(store, name).map(|(v, _)| v)
    }

    pub(crate) fn names_in(store: Store) -> Vec<String> {
        let mut names = fake_names(store, "");
        names.sort();
        names
    }

    pub(crate) fn profile_slot_name(root: &std::path::Path) -> String {
        super::profile_slot(root)
    }

    pub(crate) fn machine_slot_name() -> String {
        super::legacy_slot()
    }

    pub(crate) fn legacy_override() -> Option<String> {
        LEGACY.with(|l| l.borrow().clone())
    }

    fn machine_store() -> Store {
        if super::mac_layout() { Store::Legacy } else { Store::Flat }
    }

    /// The legacy slot's current key, whichever store holds it.
    pub(crate) fn legacy_value() -> Option<Vec<u8>> {
        super::every_store().iter().find_map(|s| super::backend::read(*s, &super::legacy_slot()).ok().flatten())
    }

    /// An older build's machine-wide slot: the file-based keychain on macOS.
    pub(crate) fn set_legacy(key: &[u8]) {
        match (mode(), machine_store()) {
            (Mode::Fake, Store::Legacy) => old_build_writes(&super::legacy_slot(), key),
            (_, store) => super::backend::put(store, &super::legacy_slot(), key).expect("legacy slot write"),
        }
    }

    pub(crate) fn profile_value(root: &std::path::Path) -> Option<Vec<u8>> {
        super::protected_stores().iter().find_map(|s| super::backend::read(*s, &super::profile_slot(root)).ok().flatten())
    }

    pub(crate) fn set_profile(root: &std::path::Path, key: &[u8]) {
        let store = super::protected_stores()[0];
        super::backend::put(store, &super::profile_slot(root), key).expect("profile slot write");
    }

    pub(crate) fn delete_profile(root: &std::path::Path) {
        for store in super::protected_stores() {
            let _ = super::backend::delete(*store, &super::profile_slot(root));
        }
    }

    /// The machine's real keystore for this thread, in the test namespace and with a
    /// legacy slot of its own; every slot written through it is deleted on drop.
    /// `None` where there is no keystore a test binary may use: macOS keeps keys only
    /// in the data-protection keychain, which an unsigned test binary is refused (the
    /// signed release run covers it).
    pub(crate) struct RealKeystore {
        _private: (),
    }

    impl RealKeystore {
        /// The macOS file-based keychain, in the test namespace, for the move's
        /// file-keychain half: the protected stores refuse an unsigned test binary.
        #[cfg(target_os = "macos")]
        pub(crate) fn enter_file_keychain() -> Self {
            MODE.with(|m| m.set(Mode::Real));
            Self { _private: () }
        }

        /// The real file-based keychain in the test namespace, the protected stores
        /// fake: the move and the re-key whole, on this Mac.
        #[cfg(target_os = "macos")]
        pub(crate) fn enter_login_only() -> Self {
            MODE.with(|m| m.set(Mode::LoginReal));
            Self { _private: () }
        }

        pub(crate) fn enter() -> Option<Self> {
            if !super::real::flat_available() || super::mac_layout() {
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
            for (store, name) in REAL_WRITES.with(|w| std::mem::take(&mut *w.borrow_mut())) {
                let _ = super::real::delete(store, &name);
            }
            LEGACY.with(|l| *l.borrow_mut() = None);
            MODE.with(|m| m.set(Mode::Fake));
        }
    }
}

#[cfg(test)]
mod tests;
