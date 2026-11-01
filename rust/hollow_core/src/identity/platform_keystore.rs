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
//! them. `settle_move` copies those items across, reads each copy back, then deletes
//! exactly the item it read. Nothing writes the file-based keychain any more, and no
//! macOS keychain call runs before the app's bundle self-check passed.

use std::path::{Path, PathBuf};

/// Where a key candidate was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Source {
    Profile,
    /// A conflict copy of this profile's slot (`<slot>.m.<hash>`), left by the move.
    Copy,
    Legacy,
    /// A file-based keychain item the move has not taken yet (macOS).
    Unmoved,
    Blob,
    /// Another slot of this keystore's naming: the same folder under a path
    /// written differently, or a profile folder that moved on this account.
    Scan,
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
    Other(i32),
}

/// A value and the persistent reference of the item it was read from.
type Found = Option<(Vec<u8>, Vec<u8>)>;

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

fn base() -> &'static str {
    if mac_layout() { MAC_BASE } else { WIN_BASE }
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
/// instead. The switch is process-wide, so it is held only around these calls.
fn without_prompts<T>(f: impl FnOnce() -> T) -> T {
    #[cfg(target_os = "macos")]
    let _quiet = security_framework::os::macos::keychain::SecKeychain::disable_user_interaction().ok();
    #[cfg(test)]
    let _quiet_test = test_support::Quiet::enter();
    f()
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

fn delete_ref(store: Store, item: &[u8]) -> Result<(), Failure> {
    gate(store)?;
    backend::delete_ref(store, item)
}

fn ref_present(store: Store, item: &[u8]) -> Result<bool, Failure> {
    gate(store)?;
    backend::ref_present(store, item)
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
    //! reached only to read, list and delete.

    use core_foundation::array::CFArray;
    use core_foundation::base::{CFType, CFTypeRef, OSStatus, TCFType};
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
        static kSecMatchLimit: CFStringRef;
        static kSecMatchLimitOne: CFStringRef;
        static kSecMatchLimitAll: CFStringRef;
        fn SecItemAdd(attributes: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
        fn SecItemCopyMatching(query: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
        fn SecItemUpdate(query: CFDictionaryRef, update: CFDictionaryRef) -> OSStatus;
        fn SecItemDelete(query: CFDictionaryRef) -> OSStatus;
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
                Store::Legacy => {}
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

    fn by_ref(store: Store, item: &[u8]) -> Result<Query, Failure> {
        let mut q = Query::new();
        // SAFETY: reading Security framework constants.
        unsafe {
            q.set(k(kSecClass), k(kSecClassGenericPassword).into_CFType());
            q.set(k(kSecValuePersistentRef), CFData::from_buffer(item).into_CFType());
            match store {
                Store::Legacy => {}
                Store::Keys | Store::AppId => {
                    super::bundle::groups().ok_or(Failure::Unchecked)?;
                    q.set(k(kSecUseDataProtectionKeychain), CFBoolean::true_value().into_CFType());
                }
                Store::Flat => return Err(Failure::Other(-4)),
            }
        }
        Ok(q)
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

    pub(super) fn read_ref(store: Store, account: &str) -> Result<super::Found, Failure> {
        let mut q = query(store, Some(account))?;
        // SAFETY: reading Security framework constants.
        let (data_key, ref_key) = unsafe {
            q.set(k(kSecReturnData), CFBoolean::true_value().into_CFType());
            q.set(k(kSecReturnPersistentRef), CFBoolean::true_value().into_CFType());
            q.set(k(kSecMatchLimit), k(kSecMatchLimitOne).into_CFType());
            (k(kSecValueData), k(kSecValuePersistentRef))
        };
        let Some(found) = copy_matching(&q)? else { return Ok(None) };
        let Some(dict) = found.downcast::<CFDictionary>() else { return Err(Failure::Other(-1)) };
        // SAFETY: SecItemCopyMatching answers a dictionary of CFString keys.
        let dict: CFDictionary<CFString, CFType> = unsafe { CFDictionary::wrap_under_get_rule(dict.as_concrete_TypeRef()) };
        match (data_of(dict.find(&data_key)), data_of(dict.find(&ref_key))) {
            (Some(value), Some(item)) => Ok(Some((value, item))),
            _ => Err(Failure::Other(-1)),
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

    /// Deletes exactly the item a read returned: a rewrite since made a new item,
    /// which this misses.
    pub(super) fn delete_ref(store: Store, item: &[u8]) -> Result<(), Failure> {
        let q = by_ref(store, item)?;
        // SAFETY: a valid dictionary.
        match unsafe { SecItemDelete(q.as_concrete_TypeRef() as CFDictionaryRef) } {
            0 | NOT_FOUND => Ok(()),
            other => Err(failure(other)),
        }
    }

    pub(super) fn ref_present(store: Store, item: &[u8]) -> Result<bool, Failure> {
        let mut q = by_ref(store, item)?;
        // SAFETY: reading Security framework constants.
        unsafe {
            q.set(k(kSecReturnAttributes), CFBoolean::true_value().into_CFType());
            q.set(k(kSecMatchLimit), k(kSecMatchLimitOne).into_CFType());
        }
        Ok(copy_matching(&q)?.is_some())
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

    pub(super) fn delete_ref(store: Store, item: &[u8]) -> Result<(), Failure> {
        #[cfg(target_os = "macos")]
        return super::mac::delete_ref(store, item);
        #[cfg(not(target_os = "macos"))]
        Err(Failure::Other(-4))
    }

    pub(super) fn ref_present(store: Store, item: &[u8]) -> Result<bool, Failure> {
        #[cfg(target_os = "macos")]
        return super::mac::ref_present(store, item);
        #[cfg(not(target_os = "macos"))]
        Err(Failure::Other(-4))
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
    use super::test_support::{self as t, fault, mode, Fault, Mode};
    use super::{Added, Failure, Store};

    pub(super) fn flat_available() -> bool {
        match mode() {
            Mode::Fake => true,
            Mode::Real => super::real::flat_available(),
        }
    }

    pub(super) fn has_blob() -> bool {
        match mode() {
            Mode::Fake => true,
            Mode::Real => super::real::has_blob(),
        }
    }

    pub(super) fn read(store: Store, name: &str) -> Result<Option<Vec<u8>>, Failure> {
        Ok(read_ref(store, name)?.map(|(value, _)| value))
    }

    pub(super) fn read_ref(store: Store, name: &str) -> Result<super::Found, Failure> {
        t::note_read(store, name);
        let found = match mode() {
            Mode::Fake => {
                t::refusal(store, true)?;
                t::fake_item(store, name)
            }
            Mode::Real => super::real::read(store, name)?.map(|v| (v, Vec::new())),
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
        match mode() {
            Mode::Fake => {
                if t::fake_item(store, name).is_some() {
                    return Ok(Added::Present);
                }
                t::fake_insert(store, name, key.to_vec());
                note_write(store, name);
                Ok(Added::New)
            }
            Mode::Real => {
                t::note_real_write(store, name);
                super::real::add(store, name, key)
            }
        }
    }

    pub(super) fn put(store: Store, name: &str, key: &[u8]) -> Result<(), Failure> {
        write_fault(store, name)?;
        match mode() {
            Mode::Fake => {
                t::fake_update_or_insert(store, name, key.to_vec());
                note_write(store, name);
                Ok(())
            }
            Mode::Real => {
                t::note_real_write(store, name);
                super::real::put(store, name, key)
            }
        }
    }

    pub(super) fn list(store: Store, prefix: &str) -> Vec<String> {
        match mode() {
            Mode::Fake if t::refusal(store, false).is_err() => Vec::new(),
            Mode::Fake => t::fake_names(store, prefix),
            Mode::Real => super::real::list(store, prefix),
        }
    }

    pub(super) fn delete(store: Store, name: &str) -> Result<(), Failure> {
        match mode() {
            Mode::Fake => {
                t::refusal(store, false)?;
                t::fake_remove(store, name);
                Ok(())
            }
            Mode::Real => super::real::delete(store, name),
        }
    }

    pub(super) fn delete_ref(store: Store, item: &[u8]) -> Result<(), Failure> {
        if fault(Fault::DeleteRefFails) {
            return Err(Failure::Other(-1));
        }
        match mode() {
            Mode::Fake => {
                t::refusal(store, false)?;
                if !fault(Fault::DeleteRefLeaves) {
                    t::fake_remove_ref(store, item);
                }
                Ok(())
            }
            Mode::Real => super::real::delete_ref(store, item),
        }
    }

    pub(super) fn ref_present(store: Store, item: &[u8]) -> Result<bool, Failure> {
        match mode() {
            Mode::Fake => Ok(t::fake_ref_present(store, item)),
            Mode::Real => super::real::ref_present(store, item),
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
    for source in [Source::Profile, Source::Legacy, Source::Unmoved, Source::Blob] {
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
pub(crate) fn key_that_opens(root: &Path, identity: &[u8]) -> Option<(Source, [u8; 32])> {
    let opens = |bytes: Vec<u8>| {
        let key = <[u8; 32]>::try_from(bytes.as_slice()).ok()?;
        super::encryption::decrypt_identity(identity, &key).is_ok().then_some(key)
    };
    let own = |source| read_source(root, source).into_iter().find_map(&opens).map(|key| (source, key));
    if let Some(found) = own(Source::Profile) {
        return Some(found);
    }
    let copies = copies_of(root);
    if let Some(found) = copies.iter().find_map(|(s, n)| opens(read(*s, n).ok()??).map(|key| (Source::Copy, key))) {
        return Some(found);
    }
    let known = [Source::Legacy, Source::Unmoved, Source::Blob].into_iter().find_map(own);
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
    without_prompts(|| {
        for store in every_store() {
            let _ = delete(*store, &own);
            for name in list(*store, &copies) {
                let _ = delete(*store, &name);
            }
        }
        for (store, name) in machine {
            let _ = delete(*store, name);
        }
    });
}

/// One point of a move, for the tests' hook; a hook answering false is a process
/// that died there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Read,
    Copied,
    ReadBack,
    Deleted,
}

fn step(at: Step, name: &str) -> bool {
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
    /// Copied but the source stays (a copy that did not read back, a refused delete).
    pub(crate) kept: usize,
    /// Never touched: a read that would prompt or failed, a value not a key.
    pub(crate) skipped: usize,
}

enum Outcome {
    Moved,
    Kept,
    Skipped,
    Died,
}

/// macOS, once per start before any unlock: every Hollow key in the file-based
/// keychain moves into the protected keychain, and where the keys group works,
/// every key still in the app-ID group moves into it. Each item is copied, the copy
/// read back byte for byte, and only then is exactly the item that was read
/// deleted, so no store is ever without the key and a key another process wrote
/// meanwhile stays. Runs only where the keystore answered a definite yes.
pub(crate) fn settle_move(root: &Path) -> Moved {
    let mut done = Moved::default();
    if !mac_layout() {
        return done;
    }
    let Writable::Yes(target) = protected_writable() else { return done };
    let first = [profile_slot(root), legacy_slot()];
    without_prompts(|| {
        if move_store(Store::Legacy, target, &first, slot_name, &mut done) && target == Store::Keys {
            move_store(Store::AppId, Store::Keys, &first, our_name, &mut done);
        }
    });
    done
}

/// False when the process "died" in a test hook.
fn move_store(from: Store, to: Store, first: &[String], ours: fn(&str) -> bool, done: &mut Moved) -> bool {
    let mut names: Vec<String> = list(from, base()).into_iter().filter(|n| ours(n)).collect();
    names.sort();
    names.dedup();
    names.sort_by_key(|n| !first.iter().any(|f| f == n));
    for name in names.into_iter().take(MOVE_LIMIT) {
        match move_one(from, to, &name) {
            Outcome::Moved => done.moved += 1,
            Outcome::Kept => done.kept += 1,
            Outcome::Skipped => done.skipped += 1,
            Outcome::Died => return false,
        }
    }
    true
}

fn move_one(from: Store, to: Store, name: &str) -> Outcome {
    let Ok(Some((value, item))) = read_ref(from, name) else { return Outcome::Skipped };
    let value = zeroize::Zeroizing::new(value);
    if value.len() != 32 {
        return Outcome::Skipped;
    }
    if !step(Step::Read, name) {
        return Outcome::Died;
    }
    let Some(target) = place_copy(to, name, &value) else { return Outcome::Kept };
    if !step(Step::Copied, name) {
        return Outcome::Died;
    }
    if !matches!(read(to, &target), Ok(Some(back)) if same(&back, &value)) {
        crate::hollow_log!("[HOLLOW-ID] A moved keychain item did not read back; the old one stays");
        return Outcome::Kept;
    }
    if !step(Step::ReadBack, name) {
        return Outcome::Died;
    }
    if delete_ref(from, &item).is_err() {
        return Outcome::Kept;
    }
    if !step(Step::Deleted, name) {
        return Outcome::Died;
    }
    // A delete that answered yes (or "not found") but left the item moved nothing.
    if !matches!(ref_present(from, &item), Ok(false)) {
        crate::hollow_log!("[HOLLOW-ID] A moved keychain item is still listed where it was; the next start retries");
        return Outcome::Kept;
    }
    Outcome::Moved
}

/// Puts `value` under `name` in `to`, or under its conflict copy when `name` holds
/// another key there; never overwrites a key. `None` when neither can be had.
fn place_copy(to: Store, name: &str, value: &[u8]) -> Option<String> {
    for target in [name.to_string(), copy_name(name, value)] {
        let held = match read(to, &target) {
            Ok(None) => match add(to, &target, value) {
                Ok(Added::New) => return Some(target),
                Ok(Added::Present) => read(to, &target).ok()??,
                Err(_) => return None,
            },
            Ok(Some(held)) => held,
            Err(_) => return None,
        };
        if same(&held, value) {
            return Some(target);
        }
    }
    None
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
        DeleteRefFails,
        /// A delete by reference answers success but the item stays.
        DeleteRefLeaves,
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

    pub(crate) fn note_read(store: Store, name: &str) {
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

    /// What the fake store answers before touching `store`.
    pub(crate) fn refusal(store: Store, reading: bool) -> Result<(), Failure> {
        match store {
            Store::Keys if fault(Fault::KeysRefused) => Err(Failure::Refused),
            Store::AppId if fault(Fault::AppIdRefused) => Err(Failure::Refused),
            Store::Legacy if reading && fault(Fault::LegacyAsks) => Err(Failure::WouldAsk),
            _ => Ok(()),
        }
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

    pub(crate) fn fake_remove_ref(store: Store, item: &[u8]) {
        FAKE.with(|m| m.borrow_mut().retain(|(s, _), (_, id)| !(*s == store && id.to_le_bytes() == item)));
    }

    pub(crate) fn fake_ref_present(store: Store, item: &[u8]) -> bool {
        FAKE.with(|m| m.borrow().iter().any(|((s, _), (_, id))| *s == store && id.to_le_bytes() == item))
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
