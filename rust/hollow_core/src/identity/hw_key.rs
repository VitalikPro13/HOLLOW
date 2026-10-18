//! The phone's own hardware key that ties an app-lock wrap to this device (AR-24).
//!
//! A PIN typed at the app lock is stretched by Argon2id as before, then run once
//! through a key that never leaves the phone's secure hardware (an Android Keystore
//! HMAC key, StrongBox when the phone has one; a Secure Enclave P-256 key on iOS), and
//! the wrapping key is HKDF over both. A byte copy of the data folder lacks the
//! hardware key, so it cannot test a single guess; every guess must be made on the
//! phone itself. Nothing counts attempts in hardware: the pacing is `attempts`.
//!
//! The platform code only runs the hardware operation; it registers itself at start
//! (`HollowHwKey.kt`, `AppDelegate.swift`) and Rust does all the rest. Desktops, the
//! iOS extension, the push fetch and emulators without secure hardware register
//! nothing and keep the Argon2id-only wrap. The key is bound to neither the lock
//! screen nor a biometric enrollment, so a new fingerprint never strands an identity.

use std::path::Path;
use std::sync::{Arc, RwLock};

/// The file naming this profile's app-lock entries and hardware key. Random, never
/// a path: an iOS container can move between updates, and a key named after the old
/// path would be lost with the identity it opens.
pub(crate) const PROFILE_ID_FILE: &str = "app_lock.id";

/// What unlock answers for a device-bound identity this device's hardware no longer
/// opens. Nothing on disk was touched; the recovery phrase is the way back. Dart
/// matches the leading marker.
pub(crate) const MISSING: &str =
    "hardware_key_missing: the key that opens this identity is not in this device's secure hardware";

/// What a hardware operation that failed on a key still there answers. Nothing was
/// counted or changed: the same try may simply be made again. Dart matches the marker.
pub(crate) const BUSY: &str =
    "hardware_key_busy: this device's secure hardware did not answer this time";

const DOMAIN: &[u8] = b"hollow-applock-hw1";
/// RFC 9380 suite id for P-256, prefixed with our domain.
const P256_DST: &[u8] = b"hollow-applock-hw1-P256_XMD:SHA-256_SSWU_RO_";

/// What the platform's key computes over the stretched secret.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
pub(crate) enum Kind {
    /// HMAC-SHA256 over `DOMAIN || stretched` (Android Keystore).
    Hmac,
    /// ECDH x-coordinate against the RFC 9380 hash of the stretched secret onto
    /// P-256 (Secure Enclave). The point's discrete log is unknown, so the enclave's
    /// public key alone cannot reproduce the answer; a fixed peer key would give one
    /// constant that, read out once, ends the binding.
    EcdhP256,
}

/// Where a freshly made key lives, for the log line that proves it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
pub(crate) enum Level {
    StrongBox,
    TrustedEnvironment,
    SecureEnclave,
}

impl Level {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Level::StrongBox => "strongbox",
            Level::TrustedEnvironment => "tee",
            Level::SecureEnclave => "secure enclave",
        }
    }
}

/// Whether a key is in the keystore, as far as the keystore could say.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
pub(crate) enum Presence {
    Present,
    /// The keystore answered that no such key exists.
    Absent,
    /// The keystore failed to answer: the key may well be there.
    Unknown,
}

/// The platform side. `create` makes a fresh key under `alias` (replacing one) and
/// refuses anything not in secure hardware; `apply` answers `None` when the operation
/// failed, which on a key that exists is a busy keystore, never a lost key.
pub(crate) trait Oracle: Send + Sync {
    fn kind(&self) -> Kind;
    fn create(&self, alias: &str) -> Result<Level, String>;
    fn exists(&self, alias: &str) -> Presence;
    fn apply(&self, alias: &str, input: &[u8]) -> Option<[u8; 32]>;
    fn delete(&self, alias: &str);
    /// Every alias of an app-lock key the keystore holds, `None` when it could not say.
    fn list(&self) -> Option<Vec<String>>;
}

static ORACLE: RwLock<Option<Arc<dyn Oracle>>> = RwLock::new(None);

#[cfg(test)]
thread_local! {
    /// Tests run in parallel: each thread sees only the oracle it installed.
    static TEST_ORACLE: std::cell::RefCell<Option<Arc<dyn Oracle>>> = const { std::cell::RefCell::new(None) };
}

#[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
pub(crate) fn install(oracle: Arc<dyn Oracle>) {
    *ORACLE.write().unwrap_or_else(|e| e.into_inner()) = Some(oracle);
}

#[cfg(test)]
pub(crate) fn install_for_test(oracle: Option<Arc<dyn Oracle>>) {
    TEST_ORACLE.with(|o| *o.borrow_mut() = oracle);
    TEST_REFUSED.with(|r| r.set(false));
    TEST_ONE_PROFILE.with(|r| r.set(false));
}

#[cfg(test)]
pub(crate) fn one_profile_for_test(one: bool) {
    TEST_ONE_PROFILE.with(|r| r.set(one));
}

#[cfg(test)]
thread_local! {
    static TEST_ONE_PROFILE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// An install that holds a single profile, so every app-lock key it keeps is that
/// profile's or a gone one's. A computer can hold several profiles.
fn one_profile() -> bool {
    #[cfg(test)]
    return TEST_ONE_PROFILE.with(std::cell::Cell::get);
    #[cfg(not(test))]
    cfg!(any(target_os = "android", target_os = "ios"))
}

fn oracle() -> Option<Arc<dyn Oracle>> {
    #[cfg(test)]
    return TEST_ORACLE.with(|o| o.borrow().clone());
    #[cfg(not(test))]
    ORACLE.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Set once the platform refused to make a key (an emulator's software keystore, a
/// simulator): this process stops asking, and the app lock keeps the Argon2id wrap.
static REFUSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn refused() -> bool {
    #[cfg(test)]
    return TEST_REFUSED.with(std::cell::Cell::get);
    #[cfg(not(test))]
    REFUSED.load(std::sync::atomic::Ordering::Relaxed)
}

fn mark_refused() {
    #[cfg(test)]
    TEST_REFUSED.with(|r| r.set(true));
    REFUSED.store(true, std::sync::atomic::Ordering::Relaxed);
}

#[cfg(test)]
thread_local! {
    static TEST_REFUSED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// This device can bind an app lock at all.
pub(crate) fn available() -> bool {
    oracle().is_some() && !refused()
}

/// The profile's id, `None` while it has none. `create` writes one on first need.
pub(crate) fn profile_id(root: &Path, create: bool) -> Option<String> {
    let path = root.join(PROFILE_ID_FILE);
    if let Ok(text) = std::fs::read_to_string(&path) {
        let id = text.trim();
        if id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Some(id.to_ascii_lowercase());
        }
    }
    if !create {
        return None;
    }
    let mut raw = [0u8; 8];
    getrandom::fill(&mut raw).ok()?;
    let id = hex::encode(raw);
    let staged = root.join(format!("{PROFILE_ID_FILE}.tmp"));
    std::fs::write(&staged, &id).ok()?;
    std::fs::rename(&staged, &path).ok()?;
    Some(id)
}

const ALIAS_PREFIX: &str = "hollow_applock_hw.";

fn alias_of(id: &str) -> String {
    format!("{ALIAS_PREFIX}{id}")
}

/// The profile id an alias names, only for an alias of exactly our shape.
fn id_of_alias(alias: &str) -> Option<&str> {
    let id = alias.strip_prefix(ALIAS_PREFIX)?;
    (id.len() == 16 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))).then_some(id)
}

/// Most keys one sweep deletes; more wait for the next.
const SWEEP_MAX: usize = 16;

/// The id in `dir`, `Ok(None)` when it has none, `Err` when one is there but cannot
/// be read as an id.
fn id_in(dir: &Path) -> Result<Option<String>, ()> {
    match std::fs::read_to_string(dir.join(PROFILE_ID_FILE)) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(()),
        Ok(text) => {
            let id = text.trim();
            (id.len() == 16 && id.bytes().all(|b| b.is_ascii_hexdigit())).then(|| Some(id.to_ascii_lowercase())).ok_or(())
        }
    }
}

/// Deletes the app-lock keys of profiles gone from this phone: a wipe run where no
/// oracle is registered (the push fetch, the iOS extension) cannot delete its own.
/// Kept are the live profile's key and that of every `<root>-old-*` folder beside it;
/// with no readable live id, a kept folder that cannot be read, or a keystore that
/// cannot list, nothing goes. The list comes first: a key is made after its id is
/// written, so every key listed has an id to read by then. Returns how many went.
pub(crate) fn sweep_orphans(root: &Path) -> usize {
    let Some(oracle) = oracle().filter(|_| one_profile()) else { return 0 };
    let Some(held) = oracle.list() else { return 0 };
    let Ok(Some(live)) = id_in(root) else { return 0 };
    let Some(kept) = crate::api::recovery::kept_named(root) else { return 0 };
    let mut keep = vec![live];
    for dir in &kept {
        match id_in(dir) {
            Ok(id) => keep.extend(id),
            Err(()) => return 0,
        }
    }
    let gone: Vec<&String> = held
        .iter()
        .filter(|alias| id_of_alias(alias).is_some_and(|id| !keep.iter().any(|k| k == id)))
        .take(SWEEP_MAX)
        .collect();
    for alias in &gone {
        oracle.delete(alias);
    }
    crate::hollow_log!("[HOLLOW-ID] App lock keys: {} held, {} of gone profiles removed", held.len(), gone.len());
    gone.len()
}

/// The hardware key of one profile, ready to use.
pub(crate) struct Bound {
    oracle: Arc<dyn Oracle>,
    alias: String,
}

impl Bound {
    /// One hardware operation over a stretched secret. `None` = the key failed.
    pub(crate) fn apply(&self, stretched: &[u8; 32]) -> Option<[u8; 32]> {
        #[cfg(test)]
        HW_COUNT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let input = hw_input(self.oracle.kind(), stretched)?;
        self.oracle.apply(&self.alias, &input)
    }
}

/// The profile's existing key, `Ok(None)` with no oracle, no id or a key the keystore
/// says is gone, [`BUSY`] when the keystore could not say.
pub(crate) fn existing(root: &Path) -> Result<Option<Bound>, String> {
    let Some(oracle) = oracle() else { return Ok(None) };
    let Some(id) = profile_id(root, false) else { return Ok(None) };
    let alias = alias_of(&id);
    match oracle.exists(&alias) {
        Presence::Present => Ok(Some(Bound { oracle, alias })),
        Presence::Absent => Ok(None),
        Presence::Unknown => Err(BUSY.into()),
    }
}

/// The profile's key, made now when it has none. `fresh` replaces an existing one:
/// only where nothing on disk still needs it (a new lock with a new duress slot).
/// Without `fresh` a key is made only where the keystore says none exists.
/// `Ok(None)` where the device has no secure hardware for it.
pub(crate) fn ensure(root: &Path, fresh: bool) -> Result<Option<Bound>, String> {
    let Some(oracle) = oracle().filter(|_| !refused()) else { return Ok(None) };
    let id = profile_id(root, true).ok_or("Could not name this profile's hardware key")?;
    let alias = alias_of(&id);
    let make = match (fresh, oracle.exists(&alias)) {
        (true, _) => true,
        (false, Presence::Present) => false,
        (false, Presence::Absent) => true,
        (false, Presence::Unknown) => return Err(BUSY.into()),
    };
    if make {
        if fresh {
            oracle.delete(&alias);
        }
        match oracle.create(&alias) {
            Ok(level) => crate::hollow_log!("[HOLLOW-ID] The app lock is tied to this device's hardware ({})", level.name()),
            Err(e) => {
                crate::hollow_log!("[HOLLOW-ID] The app lock keeps its Argon2id wrap: {e}");
                mark_refused();
                return Ok(None);
            }
        }
    }
    Ok(Some(Bound { oracle, alias }))
}

/// Deletes the profile's key. Part of a wipe, so it says nothing.
pub(crate) fn forget(root: &Path) {
    if let (Some(oracle), Some(id)) = (oracle(), profile_id(root, false)) {
        oracle.delete(&alias_of(&id));
    }
}

fn hw_input(kind: Kind, stretched: &[u8; 32]) -> Option<Vec<u8>> {
    match kind {
        Kind::Hmac => Some([DOMAIN, stretched.as_slice()].concat()),
        Kind::EcdhP256 => {
            use p256::elliptic_curve::hash2curve::{ExpandMsgXmd, GroupDigest};
            use p256::elliptic_curve::sec1::ToEncodedPoint;
            let point = p256::NistP256::hash_from_bytes::<ExpandMsgXmd<sha2::Sha256>>(
                &[stretched.as_slice()],
                &[P256_DST],
            )
            .ok()?;
            Some(point.to_affine().to_encoded_point(false).as_bytes().to_vec())
        }
    }
}

/// The wrapping key of a device-bound slot: HKDF-SHA256 over the stretched secret
/// and the hardware's answer, salted by the slot's own salt.
pub(crate) fn combine(stretched: &[u8; 32], hw: &[u8; 32], salt: &[u8; 16]) -> [u8; 32] {
    let mut ikm = zeroize::Zeroizing::new([0u8; 64]);
    ikm[..32].copy_from_slice(stretched);
    ikm[32..].copy_from_slice(hw);
    let hk = hkdf::Hkdf::<sha2::Sha256>::new(Some(salt), &ikm[..]);
    let mut out = [0u8; 32];
    hk.expand(DOMAIN, &mut out).expect("32 bytes is a valid HKDF length");
    out
}

#[cfg(target_os = "android")]
mod android {
    //! `com.anonlisten.hollow.HollowHwKey` (the app module) registers itself from
    //! `MainActivity` and answers these static calls; it catches every exception.

    use super::*;
    use jni::objects::{GlobalRef, JByteArray, JClass, JObject, JObjectArray, JString, JValue};
    use jni::{JNIEnv, JavaVM};

    struct Keystore {
        vm: JavaVM,
        class: GlobalRef,
    }

    impl Keystore {
        fn call<T>(&self, f: impl FnOnce(&mut JNIEnv, &JClass) -> jni::errors::Result<T>) -> Option<T> {
            let mut env = self.vm.attach_current_thread().ok()?;
            let class: &JClass = self.class.as_obj().into();
            let out = env.with_local_frame(8, |env| f(env, class));
            if env.exception_check().unwrap_or(false) {
                let _ = env.exception_clear();
                return None;
            }
            out.ok()
        }
    }

    impl Oracle for Keystore {
        fn kind(&self) -> Kind {
            Kind::Hmac
        }

        fn create(&self, alias: &str) -> Result<Level, String> {
            let level = self.call(|env, class| {
                let a = env.new_string(alias)?;
                env.call_static_method(class, "create", "(Ljava/lang/String;)I", &[JValue::Object(&a)])?.i()
            });
            match level {
                Some(2) => Ok(Level::StrongBox),
                Some(1) => Ok(Level::TrustedEnvironment),
                _ => Err("This device has no secure hardware to hold the app lock's key".into()),
            }
        }

        fn exists(&self, alias: &str) -> Presence {
            let answer = self.call(|env, class| {
                let a = env.new_string(alias)?;
                env.call_static_method(class, "exists", "(Ljava/lang/String;)I", &[JValue::Object(&a)])?.i()
            });
            match answer {
                Some(1) => Presence::Present,
                Some(0) => Presence::Absent,
                _ => Presence::Unknown,
            }
        }

        fn apply(&self, alias: &str, input: &[u8]) -> Option<[u8; 32]> {
            let out = self.call(|env, class| {
                let a = env.new_string(alias)?;
                let data = env.byte_array_from_slice(input)?;
                let obj: JObject = env
                    .call_static_method(class, "apply", "(Ljava/lang/String;[B)[B", &[JValue::Object(&a), JValue::Object(&data)])?
                    .l()?;
                if obj.is_null() {
                    return Ok(None);
                }
                env.convert_byte_array(JByteArray::from(obj)).map(Some)
            })??;
            out.try_into().ok()
        }

        fn delete(&self, alias: &str) {
            let _ = self.call(|env, class| {
                let a = env.new_string(alias)?;
                env.call_static_method(class, "delete", "(Ljava/lang/String;)V", &[JValue::Object(&a)]).map(|_| ())
            });
        }

        fn list(&self) -> Option<Vec<String>> {
            self.call(|env, class| {
                let prefix = env.new_string(ALIAS_PREFIX)?;
                let obj = env
                    .call_static_method(class, "list", "(Ljava/lang/String;)[Ljava/lang/String;", &[JValue::Object(&prefix)])?
                    .l()?;
                if obj.is_null() {
                    return Ok(None);
                }
                let array = JObjectArray::from(obj);
                let mut aliases = Vec::new();
                for i in 0..env.get_array_length(&array)? {
                    let item = env.get_object_array_element(&array, i)?;
                    let text: String = env.get_string(&JString::from(item))?.into();
                    aliases.push(text);
                }
                Ok(Some(aliases))
            })?
        }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_anonlisten_hollow_HollowHwKey_nativeRegister(env: JNIEnv, class: JClass) {
        let (Ok(vm), Ok(class)) = (env.get_java_vm(), env.new_global_ref(&class)) else { return };
        install(Arc::new(Keystore { vm, class }));
    }
}

#[cfg(target_os = "ios")]
mod ios {
    //! `AppDelegate.swift` registers five C functions over the Secure Enclave at
    //! launch. The extension never does, so it never binds anything.

    use super::*;
    use std::ffi::{c_char, CString};

    type CreateFn = unsafe extern "C" fn(*const c_char) -> i32;
    type ExistsFn = unsafe extern "C" fn(*const c_char) -> i32;
    type ApplyFn = unsafe extern "C" fn(*const c_char, *const u8, usize, *mut u8) -> i32;
    type DeleteFn = unsafe extern "C" fn(*const c_char);
    /// Writes the held aliases, newline-separated and NUL-terminated, into the buffer
    /// of the given size; answers the bytes written before the NUL, or -1.
    type ListFn = unsafe extern "C" fn(*mut c_char, usize) -> i32;

    /// Room for far more keys than one phone's profiles ever leave.
    const LIST_BUFFER: usize = 4096;

    struct Enclave {
        create: CreateFn,
        exists: ExistsFn,
        apply: ApplyFn,
        delete: DeleteFn,
        list: ListFn,
    }

    fn c(alias: &str) -> Option<CString> {
        CString::new(alias).ok()
    }

    impl Oracle for Enclave {
        fn kind(&self) -> Kind {
            Kind::EcdhP256
        }

        fn create(&self, alias: &str) -> Result<Level, String> {
            let a = c(alias).ok_or("bad alias")?;
            // SAFETY: a NUL-terminated string that outlives the call.
            match unsafe { (self.create)(a.as_ptr()) } {
                1 => Ok(Level::SecureEnclave),
                _ => Err("This device has no Secure Enclave to hold the app lock's key".into()),
            }
        }

        fn exists(&self, alias: &str) -> Presence {
            let Some(a) = c(alias) else { return Presence::Unknown };
            // SAFETY: as above.
            match unsafe { (self.exists)(a.as_ptr()) } {
                1 => Presence::Present,
                0 => Presence::Absent,
                _ => Presence::Unknown,
            }
        }

        fn apply(&self, alias: &str, input: &[u8]) -> Option<[u8; 32]> {
            let a = c(alias)?;
            let mut out = [0u8; 32];
            // SAFETY: `input` is valid for its length and `out` holds the 32 bytes the
            // callee writes.
            let ok = unsafe { (self.apply)(a.as_ptr(), input.as_ptr(), input.len(), out.as_mut_ptr()) };
            (ok == 1).then_some(out)
        }

        fn delete(&self, alias: &str) {
            if let Some(a) = c(alias) {
                // SAFETY: as above.
                unsafe { (self.delete)(a.as_ptr()) }
            }
        }

        fn list(&self) -> Option<Vec<String>> {
            let mut buf = vec![0u8; LIST_BUFFER];
            // SAFETY: the callee writes at most `LIST_BUFFER` bytes into `buf`.
            let n = unsafe { (self.list)(buf.as_mut_ptr().cast(), buf.len()) };
            let n = usize::try_from(n).ok().filter(|n| *n < buf.len())?;
            let text = std::str::from_utf8(&buf[..n]).ok()?;
            Some(text.split('\n').filter(|a| !a.is_empty()).map(str::to_string).collect())
        }
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn hollow_hw_key_register(
        create: CreateFn,
        exists: ExistsFn,
        apply: ApplyFn,
        delete: DeleteFn,
        list: ListFn,
    ) {
        install(Arc::new(Enclave { create, exists, apply, delete, list }));
    }
}

/// Hardware operations run since the counter was last read; the duress design needs
/// the same count whichever slot opens.
#[cfg(test)]
static HW_COUNT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

#[cfg(test)]
pub(crate) fn take_hw_count() -> u32 {
    HW_COUNT.swap(0, std::sync::atomic::Ordering::SeqCst)
}

#[cfg(test)]
pub(crate) mod stub {
    //! Software stand-ins for the platform keys: the same maths, the key in RAM.

    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    pub(crate) struct Stub {
        pub kind: Kind,
        keys: Mutex<HashMap<String, [u8; 32]>>,
        /// A keystore that only has software keys to offer, as on an emulator.
        pub software_only: bool,
        /// The `apply` call numbered this (1-based, from `fail_apply_number`) fails
        /// on a key that is there (busy); 0 for none.
        busy_apply_at: std::sync::atomic::AtomicU32,
        applies: std::sync::atomic::AtomicU32,
        /// The next this many `exists` calls cannot say.
        unknown_exists: std::sync::atomic::AtomicU32,
        list_fails: std::sync::atomic::AtomicBool,
    }

    impl Stub {
        pub(crate) fn new(kind: Kind) -> Arc<Self> {
            Arc::new(Self {
                kind,
                keys: Mutex::new(HashMap::new()),
                software_only: false,
                busy_apply_at: 0.into(),
                applies: 0.into(),
                unknown_exists: 0.into(),
                list_fails: false.into(),
            })
        }

        pub(crate) fn software_only() -> Arc<Self> {
            Arc::new(Self {
                kind: Kind::Hmac,
                keys: Mutex::new(HashMap::new()),
                software_only: true,
                busy_apply_at: 0.into(),
                applies: 0.into(),
                unknown_exists: 0.into(),
                list_fails: false.into(),
            })
        }

        /// The `n`th `apply` from now fails as a busy keystore does.
        pub(crate) fn fail_apply_number(&self, n: u32) {
            use std::sync::atomic::Ordering;
            self.applies.store(0, Ordering::SeqCst);
            self.busy_apply_at.store(n, Ordering::SeqCst);
        }

        pub(crate) fn fail_applies(&self, n: u32) {
            assert!(n <= 1, "one busy answer at a time");
            self.fail_apply_number(n);
        }

        /// The next `n` `exists` calls cannot say.
        pub(crate) fn fail_exists(&self, n: u32) {
            self.unknown_exists.store(n, std::sync::atomic::Ordering::SeqCst);
        }

        /// Every `list` from now fails to say.
        pub(crate) fn fail_list(&self) {
            self.list_fails.store(true, std::sync::atomic::Ordering::SeqCst);
        }

        /// The raw key under each alias, to tell a kept key from a replaced one.
        pub(crate) fn snapshot(&self) -> Vec<(String, [u8; 32])> {
            let mut v: Vec<_> = self.keys.lock().unwrap().iter().map(|(a, k)| (a.clone(), *k)).collect();
            v.sort();
            v
        }

        /// Swaps the stored key: what a key the platform invalidated looks like.
        pub(crate) fn replace_all_keys(&self) {
            let aliases: Vec<String> = self.keys.lock().unwrap().keys().cloned().collect();
            for alias in aliases {
                let _ = self.create(&alias);
            }
        }

        pub(crate) fn key_count(&self) -> usize {
            self.keys.lock().unwrap().len()
        }
    }

    impl Oracle for Stub {
        fn kind(&self) -> Kind {
            self.kind
        }

        fn create(&self, alias: &str) -> Result<Level, String> {
            if self.software_only {
                return Err("no secure hardware".into());
            }
            let mut k = [0u8; 32];
            // Every 32 bytes are an HMAC key; a P-256 scalar must also be in range.
            loop {
                getrandom::fill(&mut k).unwrap();
                if self.kind == Kind::Hmac || p256::SecretKey::from_bytes(&k.into()).is_ok() {
                    break;
                }
            }
            self.keys.lock().unwrap().insert(alias.to_string(), k);
            Ok(Level::StrongBox)
        }

        fn exists(&self, alias: &str) -> Presence {
            use std::sync::atomic::Ordering;
            if self.unknown_exists.load(Ordering::SeqCst) > 0 {
                self.unknown_exists.fetch_sub(1, Ordering::SeqCst);
                return Presence::Unknown;
            }
            if self.keys.lock().unwrap().contains_key(alias) { Presence::Present } else { Presence::Absent }
        }

        fn apply(&self, alias: &str, input: &[u8]) -> Option<[u8; 32]> {
            use std::sync::atomic::Ordering;
            let n = self.applies.fetch_add(1, Ordering::SeqCst) + 1;
            if n == self.busy_apply_at.load(Ordering::SeqCst) {
                self.busy_apply_at.store(0, Ordering::SeqCst);
                return None;
            }
            let key = *self.keys.lock().unwrap().get(alias)?;
            match self.kind {
                Kind::Hmac => {
                    use hmac::{Hmac, Mac};
                    let mut mac = <Hmac<sha2::Sha256> as Mac>::new_from_slice(&key).ok()?;
                    mac.update(input);
                    Some(mac.finalize().into_bytes().into())
                }
                Kind::EcdhP256 => {
                    let secret = p256::SecretKey::from_bytes(&key.into()).ok()?;
                    let peer = p256::PublicKey::from_sec1_bytes(input).ok()?;
                    let shared = p256::ecdh::diffie_hellman(secret.to_nonzero_scalar(), peer.as_affine());
                    Some((*shared.raw_secret_bytes()).into())
                }
            }
        }

        fn delete(&self, alias: &str) {
            self.keys.lock().unwrap().remove(alias);
        }

        fn list(&self) -> Option<Vec<String>> {
            if self.list_fails.load(std::sync::atomic::Ordering::SeqCst) {
                return None;
            }
            let mut v: Vec<String> =
                self.keys.lock().unwrap().keys().filter(|a| a.starts_with(ALIAS_PREFIX)).cloned().collect();
            v.sort();
            Some(v)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SALT: [u8; 16] = [7; 16];

    fn bound(kind: Kind) -> (crate::test_tmp::TestDir, Arc<stub::Stub>, Bound) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = stub::Stub::new(kind);
        install_for_test(Some(s.clone()));
        let b = ensure(tmp.path(), true).unwrap().unwrap();
        (tmp, s, b)
    }

    // b5-device-bound

    #[test]
    fn b5_same_secret_and_same_key_give_the_same_wrap() {
        for kind in [Kind::Hmac, Kind::EcdhP256] {
            let (_tmp, _s, b) = bound(kind);
            let a = [0x11; 32];
            let one = combine(&a, &b.apply(&a).unwrap(), &SALT);
            let two = combine(&a, &b.apply(&a).unwrap(), &SALT);
            assert_eq!(one, two, "{kind:?}: the hardware step must be deterministic");
            let other = combine(&[0x12; 32], &b.apply(&[0x12; 32]).unwrap(), &SALT);
            assert_ne!(one, other, "{kind:?}: another secret must give another wrap");
        }
        install_for_test(None);
    }

    #[test]
    fn b5_another_hardware_key_gives_another_wrap() {
        for kind in [Kind::Hmac, Kind::EcdhP256] {
            let (tmp, s, b) = bound(kind);
            let a = [0x33; 32];
            let before = combine(&a, &b.apply(&a).unwrap(), &SALT);
            s.replace_all_keys();
            let after = combine(&a, &b.apply(&a).unwrap(), &SALT);
            assert_ne!(before, after, "{kind:?}: the wrap must depend on the hardware key");
            let fresh = ensure(tmp.path(), true).unwrap().unwrap();
            assert_ne!(before, combine(&a, &fresh.apply(&a).unwrap(), &SALT));
        }
        install_for_test(None);
    }

    #[test]
    fn b5_the_wrap_needs_both_halves() {
        let a = [0x44; 32];
        let h = [0x55; 32];
        let k = combine(&a, &h, &SALT);
        assert_ne!(k, a, "the stretched secret alone is not the wrap");
        assert_ne!(k, combine(&a, &[0x56; 32], &SALT));
        assert_ne!(k, combine(&[0x45; 32], &h, &SALT));
    }

    /// The enclave's input is a hash onto the curve, so the answer is not the same
    /// point for every secret (a fixed peer key would make it a readable constant).
    #[test]
    fn b5_the_enclave_input_follows_the_secret() {
        let p1 = hw_input(Kind::EcdhP256, &[1; 32]).unwrap();
        let p2 = hw_input(Kind::EcdhP256, &[2; 32]).unwrap();
        assert_eq!(p1.len(), 65);
        assert_eq!(p1[0], 0x04, "uncompressed SEC1, what SecKeyCreateWithData takes");
        assert_ne!(p1, p2);
    }

    #[test]
    fn b5_a_profile_id_is_stable_and_never_made_by_a_read() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        assert_eq!(profile_id(tmp.path(), false), None);
        assert!(!tmp.path().join(PROFILE_ID_FILE).exists(), "a read must not create the id");
        let id = profile_id(tmp.path(), true).unwrap();
        assert_eq!(id.len(), 16);
        assert_eq!(profile_id(tmp.path(), false), Some(id.clone()));
        assert_eq!(profile_id(tmp.path(), true), Some(id));
    }

    /// An emulator's keystore offers only software keys: nothing is bound, and the
    /// process stops asking.
    #[test]
    fn b5_a_device_without_secure_hardware_keeps_the_old_wrap() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        install_for_test(Some(stub::Stub::software_only()));
        assert!(available());
        assert!(ensure(tmp.path(), true).unwrap().is_none());
        assert!(!available(), "a refusal is remembered");
        install_for_test(None);
    }

    /// A keystore that cannot say whether the key is there is busy, never a reason
    /// to make a new key (that would strand every slot wrapped with the old one).
    #[test]
    fn a_keystore_that_cannot_say_never_gets_a_new_key() {
        let (tmp, s, _b) = bound(Kind::Hmac);
        let keys = s.snapshot();
        s.fail_exists(1);
        assert_eq!(ensure(tmp.path(), false).err().as_deref(), Some(BUSY));
        s.fail_exists(1);
        assert_eq!(existing(tmp.path()).err().as_deref(), Some(BUSY));
        assert!(ensure(tmp.path(), false).unwrap().is_some());
        assert_eq!(s.snapshot(), keys, "the key was replaced");
        install_for_test(None);
    }

    #[test]
    fn b5_no_oracle_means_no_binding() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        install_for_test(None);
        assert!(!available());
        assert!(ensure(tmp.path(), true).unwrap().is_none());
        assert!(existing(tmp.path()).unwrap().is_none());
    }

    // f-applock-followups

    const ORPHAN_A: &str = "hollow_applock_hw.aaaaaaaaaaaaaaaa";
    const ORPHAN_B: &str = "hollow_applock_hw.bbbbbbbbbbbbbbbb";

    /// A phone's root with its live key, plus the keys a wipe without an oracle left.
    fn phone_with_orphans() -> (crate::test_tmp::TestDir, std::path::PathBuf, Arc<stub::Stub>, String) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("hollow");
        std::fs::create_dir_all(&root).unwrap();
        let s = stub::Stub::new(Kind::Hmac);
        install_for_test(Some(s.clone()));
        one_profile_for_test(true);
        ensure(&root, true).unwrap().unwrap();
        let live = alias_of(&profile_id(&root, false).unwrap());
        for alias in [ORPHAN_A, ORPHAN_B, "someone_else.key", "hollow_applock_hw.not-an-id"] {
            s.create(alias).unwrap();
        }
        (tmp, root, s, live)
    }

    fn aliases(s: &stub::Stub) -> Vec<String> {
        s.snapshot().into_iter().map(|(a, _)| a).collect()
    }

    #[test]
    fn a_sweep_takes_only_gone_profiles_keys() {
        let (_tmp, root, s, live) = phone_with_orphans();
        assert_eq!(sweep_orphans(&root), 2);
        let left = aliases(&s);
        assert!(left.contains(&live), "the live profile's key was swept");
        assert!(!left.contains(&ORPHAN_A.to_string()) && !left.contains(&ORPHAN_B.to_string()), "an orphan stayed: {left:?}");
        assert!(left.contains(&"someone_else.key".to_string()), "a key Hollow never named was swept");
        assert!(left.contains(&"hollow_applock_hw.not-an-id".to_string()), "a key of no profile id's shape was swept");
        install_for_test(None);
    }

    /// Old data a relink kept aside still opens with its own key, so its key stays.
    #[test]
    fn a_sweep_keeps_the_key_of_old_data_kept_aside() {
        let (tmp, root, s, _live) = phone_with_orphans();
        let kept = tmp.path().join("hollow-old-2026-10-18");
        std::fs::create_dir_all(&kept).unwrap();
        std::fs::write(kept.join("app_lock.id"), "aaaaaaaaaaaaaaaa").unwrap();
        let origin = serde_json::json!({ "root": root.to_string_lossy() }).to_string();
        std::fs::write(kept.join("relink_origin.json"), origin).unwrap();
        sweep_orphans(&root);
        let left = aliases(&s);
        assert!(left.contains(&ORPHAN_A.to_string()), "the kept data's key was swept");
        assert!(!left.contains(&ORPHAN_B.to_string()));
        install_for_test(None);
    }

    /// A computer holds several profiles; a key no root here names may be another's.
    #[test]
    fn a_computer_never_sweeps_hardware_keys() {
        let (_tmp, root, s, _live) = phone_with_orphans();
        one_profile_for_test(false);
        let before = s.snapshot();
        assert_eq!(sweep_orphans(&root), 0);
        assert_eq!(s.snapshot(), before);
        install_for_test(None);
    }

    /// Without a readable id nothing can tell the live key from an orphan, and a
    /// keystore that could not list says nothing either.
    #[test]
    fn a_sweep_that_cannot_tell_deletes_nothing() {
        let (_tmp, root, s, _live) = phone_with_orphans();
        let before = s.snapshot();
        std::fs::write(root.join(PROFILE_ID_FILE), "garbled").unwrap();
        assert_eq!(sweep_orphans(&root), 0);
        assert_eq!(s.snapshot(), before, "a root with no readable id lost keys");
        std::fs::remove_file(root.join(PROFILE_ID_FILE)).unwrap();
        assert_eq!(sweep_orphans(&root), 0);
        assert_eq!(s.snapshot(), before, "a root with no id lost keys");
        install_for_test(None);
    }

    #[test]
    fn a_keystore_that_cannot_list_loses_nothing() {
        let (_tmp, root, s, _live) = phone_with_orphans();
        let before = s.snapshot();
        s.fail_list();
        assert_eq!(sweep_orphans(&root), 0);
        assert_eq!(s.snapshot(), before);
        install_for_test(None);
    }

    #[test]
    fn a_sweep_is_bounded() {
        let (_tmp, root, s, live) = phone_with_orphans();
        for i in 0..(SWEEP_MAX + 5) {
            s.create(&format!("hollow_applock_hw.{i:016x}")).unwrap();
        }
        assert_eq!(sweep_orphans(&root), SWEEP_MAX);
        assert!(sweep_orphans(&root) > 0, "the next sweep takes the rest");
        assert!(aliases(&s).contains(&live));
        install_for_test(None);
    }

    /// The kept folder's origin mark names the root by its absolute path; the root's
    /// path moving (the case `app_lock.id` exists for) must not make the sweep take the
    /// kept folder's key.
    #[test]
    fn a_sweep_keeps_the_kept_folders_key_after_the_root_path_moved() {
        let (tmp, root, s, _live) = phone_with_orphans();
        let kept = tmp.path().join("hollow-old-2026-10-18");
        std::fs::create_dir_all(&kept).unwrap();
        std::fs::write(kept.join("app_lock.id"), "aaaaaaaaaaaaaaaa").unwrap();
        let old_root = tmp.path().join("OLD-CONTAINER").join("hollow");
        let origin = serde_json::json!({ "root": old_root.to_string_lossy() }).to_string();
        std::fs::write(kept.join("relink_origin.json"), origin).unwrap();
        sweep_orphans(&root);
        assert!(aliases(&s).contains(&ORPHAN_A.to_string()), "the kept data's key was swept once the root's path moved");
        install_for_test(None);
    }

    /// A kept folder whose id cannot be read is no proof its key is spare: the live
    /// root's unreadable id stops the sweep, and a kept folder's does too.
    #[test]
    fn a_kept_folder_with_an_unreadable_id_keeps_its_key() {
        let (tmp, root, s, _live) = phone_with_orphans();
        let kept = tmp.path().join("hollow-old-2026-10-18");
        std::fs::create_dir_all(&kept).unwrap();
        std::fs::write(kept.join("app_lock.id"), "aaaaaaaaaaaaaaa?").unwrap();
        let origin = serde_json::json!({ "root": root.to_string_lossy() }).to_string();
        std::fs::write(kept.join("relink_origin.json"), origin).unwrap();
        let before = aliases(&s);
        sweep_orphans(&root);
        assert_eq!(aliases(&s), before, "a sweep that could not read a kept folder's id still deleted keys");
        install_for_test(None);
    }

    /// A kept folder whose origin mark cannot be read stops the sweep the same way.
    #[test]
    fn a_kept_folder_with_an_unreadable_mark_stops_the_sweep() {
        let (tmp, root, s, _live) = phone_with_orphans();
        let kept = tmp.path().join("hollow-old-2026-10-18");
        std::fs::create_dir_all(kept.join("relink_origin.json")).unwrap();
        std::fs::write(kept.join("app_lock.id"), "aaaaaaaaaaaaaaaa").unwrap();
        let before = aliases(&s);
        sweep_orphans(&root);
        assert_eq!(aliases(&s), before, "a sweep that could not read a kept folder's mark still deleted keys");
        install_for_test(None);
    }
}
