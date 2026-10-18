//! FCM and APNs wakes sealed to this device (RFC 8291, aes128gcm), so Google and Apple
//! carry one opaque field instead of who wrote to whom (AR-26). The key pair lives in the
//! data root beside the identity, readable without its unlock: a locked or password-
//! protected install must still open a wake to show its neutral banner.

use std::collections::BTreeMap;
use std::path::Path;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use hkdf::Hkdf;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub(crate) const KEY_FILE: &str = "push_seal.key";
pub(crate) const KEY_FILE_TMP: &str = "push_seal.key.tmp";
/// The one data field a sealed wake carries.
pub(crate) const SEALED_FIELD: &str = "sealed";
/// The relay token version that carries a key set beside the native token.
const TOKEN_VERSION: u64 = 2;

const MAGIC: &[u8; 4] = b"HPS1";
const FILE_LEN: usize = 4 + 32 + 32 + 16;
/// FCM and APNs carry at most 4 KB, so anything longer did not come through them.
const MAX_SEALED_B64: usize = 4096;
const SALT_LEN: usize = 16;
const KEYID_LEN: usize = 65;
const HEADER_LEN: usize = SALT_LEN + 4 + 1 + KEYID_LEN;
const TAG_LEN: usize = 16;
/// RFC 8188's smallest record size.
const MIN_RECORD: u32 = 18;
const MAX_PLAINTEXT: usize = 2048;
const MAX_FIELD: usize = 160;
/// Fields a wake may name; anything else is dropped before Dart or the NSE sees it.
const WAKE_FIELDS: [&str; 5] = ["type", "sender", "server", "channel", "mention"];
/// How long a sealed wake is worth acting on: what it points at waits in the relay's
/// offline buffer for 24 h (`OFFLINE_BUFFER_TTL_SECS`, relay-uws/src/state.h).
const WAKE_TTL_SECS: u64 = 86_400;
/// How far the sidecar's clock and this phone's may disagree.
const CLOCK_SKEW_SECS: u64 = 600;
/// A wake counts this far either side of its seal time. Phones whose clock runs behind
/// are real (#107), and only a key holder can seal a block, so a stamp from the future
/// gains nobody anything.
const WINDOW_SECS: u64 = WAKE_TTL_SECS + CLOCK_SKEW_SECS;
/// One empty file per wake opened, named by its seal time and salt, so the app and the
/// iOS extension, two processes, each act on a blob once.
pub(crate) const SEEN_DIR: &str = "push_seen";
/// Enough for a day of wakes; past it the oldest go first and could be replayed.
const SEEN_CAP: usize = 2048;

pub(crate) struct PushKeys {
    secret: SecretKey,
    public: [u8; KEYID_LEN],
    auth: Zeroizing<[u8; 16]>,
    bind: [u8; 32],
}

/// The tag a key file carries for the identity it was made under: a landing that
/// replaces the identity gets a fresh key pair instead of one the relay links to the
/// old device id.
fn bind_tag(bind_id: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"hollow-push-seal1\0");
    h.update(bind_id.as_bytes());
    h.finalize().into()
}

impl PushKeys {
    fn from_parts(secret: SecretKey, auth: [u8; 16], bind: [u8; 32]) -> Self {
        let mut public = [0u8; KEYID_LEN];
        public.copy_from_slice(secret.public_key().to_encoded_point(false).as_bytes());
        Self { secret, public, auth: Zeroizing::new(auth), bind }
    }

    fn generate(bind: [u8; 32]) -> Result<Self, String> {
        let secret = loop {
            let mut raw = Zeroizing::new([0u8; 32]);
            getrandom::fill(raw.as_mut()).map_err(|e| format!("entropy failure: {e}"))?;
            if let Ok(s) = SecretKey::from_slice(raw.as_ref()) {
                break s;
            }
        };
        let mut auth = [0u8; 16];
        getrandom::fill(&mut auth).map_err(|e| format!("entropy failure: {e}"))?;
        Ok(Self::from_parts(secret, auth, bind))
    }

    fn encode(&self) -> Zeroizing<Vec<u8>> {
        let mut out = Zeroizing::new(Vec::with_capacity(FILE_LEN));
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&self.bind);
        out.extend_from_slice(&self.secret.to_bytes());
        out.extend_from_slice(self.auth.as_ref());
        out
    }

    fn decode(raw: &[u8]) -> Option<Self> {
        if raw.len() != FILE_LEN || &raw[..4] != MAGIC {
            return None;
        }
        let bind: [u8; 32] = raw[4..36].try_into().ok()?;
        let secret = SecretKey::from_slice(&raw[36..68]).ok()?;
        let auth: [u8; 16] = raw[68..84].try_into().ok()?;
        Some(Self::from_parts(secret, auth, bind))
    }
}

/// The key pair this root holds: `Ok(None)` when it holds none, `Err` when the file is
/// there but unreadable (a wake sealed for it can no longer be opened).
fn load(root: &Path) -> Result<Option<PushKeys>, ()> {
    match std::fs::read(root.join(KEY_FILE)) {
        Ok(raw) => PushKeys::decode(&Zeroizing::new(raw)).map(Some).ok_or(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(()),
    }
}

fn store(root: &Path, keys: &PushKeys) -> Result<(), String> {
    use std::io::Write;
    let staged = root.join(KEY_FILE_TMP);
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(&staged).map_err(|e| format!("push key: {e}"))?;
    f.write_all(&keys.encode()).and_then(|()| f.sync_all()).map_err(|e| format!("push key: {e}"))?;
    drop(f);
    std::fs::rename(&staged, root.join(KEY_FILE)).map_err(|e| format!("push key: {e}"))
}

/// A root a wipe emptied or is emptying: nothing may write a key into it.
fn wiped(root: &Path) -> bool {
    crate::api::wipe::destroyed_in_this_process(root)
        || std::fs::symlink_metadata(root.join(crate::api::wipe::MARKER)).is_ok()
        || !root.join("identity.key").exists()
}

/// Why a root holds no key set to register.
pub(crate) enum KeyError {
    /// The identity is gone: register nothing at all.
    Wiped,
    Failed(String),
}

fn load_or_create(root: &Path, bind_id: &str) -> Result<PushKeys, KeyError> {
    // The destroy zeroes keys under this lock, so a store after it sees the wipe.
    let _held = crate::identity::encryption::key_file_lock();
    if wiped(root) {
        return Err(KeyError::Wiped);
    }
    let bind = bind_tag(bind_id);
    if let Ok(Some(keys)) = load(root)
        && keys.bind == bind
    {
        return Ok(keys);
    }
    let keys = PushKeys::generate(bind).map_err(KeyError::Failed)?;
    if let Err(e) = store(root, &keys) {
        // Plain wakes stay readable only while no key file is left.
        let _ = std::fs::remove_file(root.join(KEY_FILE));
        return Err(KeyError::Failed(e));
    }
    Ok(keys)
}

/// The token the relay stores for a native FCM/APNs registration: the native token
/// plus this device's Web Push key set, as the sidecar parses it.
pub(crate) fn keyed_token(root: &Path, native: &str, bind_id: &str) -> Result<String, KeyError> {
    let keys = load_or_create(root, bind_id)?;
    Ok(serde_json::json!({
        "v": TOKEN_VERSION,
        "fcm": native,
        "p256dh": URL_SAFE_NO_PAD.encode(keys.public),
        "auth": URL_SAFE_NO_PAD.encode(keys.auth.as_ref()),
    })
    .to_string())
}

/// What `register_push_token` hands the relay: FCM and APNs tokens carry the key set;
/// UnifiedPush tokens carry their own. Without a key file nothing is sealed and plain
/// wakes stay readable, so a failure falls back to the plain token. A wiped root
/// registers nothing.
pub(crate) fn token_for_relay(root: &Path, platform: &str, token: String, bind_id: &str) -> Result<String, String> {
    const WIPED: &str = "This install was wiped";
    if platform != "android" && platform != "ios" {
        return if wiped(root) { Err(WIPED.to_owned()) } else { Ok(token) };
    }
    match keyed_token(root, &token, bind_id) {
        Ok(keyed) => Ok(keyed),
        Err(KeyError::Wiped) => Err(WIPED.to_owned()),
        Err(KeyError::Failed(e)) => {
            hollow_log!("[HOLLOW-PUSH] Push wakes stay unsealed: {e}");
            Ok(token)
        }
    }
}

/// Opens one RFC 8291 aes128gcm body (a single record) addressed to `keys`.
fn open_body(keys: &PushKeys, body: &[u8]) -> Result<Zeroizing<Vec<u8>>, &'static str> {
    if body.len() < HEADER_LEN + TAG_LEN + 1 {
        return Err("short");
    }
    let salt = &body[..SALT_LEN];
    let rs = u32::from_be_bytes(body[SALT_LEN..SALT_LEN + 4].try_into().map_err(|_| "header")?);
    if usize::from(body[SALT_LEN + 4]) != KEYID_LEN {
        return Err("keyid length");
    }
    let as_bytes = &body[SALT_LEN + 5..HEADER_LEN];
    let record = &body[HEADER_LEN..];
    if rs < MIN_RECORD || record.len() > rs as usize {
        return Err("record size");
    }
    if as_bytes[0] != 0x04 {
        return Err("keyid form");
    }
    let as_public = PublicKey::from_sec1_bytes(as_bytes).map_err(|_| "keyid point")?;

    let shared = p256::ecdh::diffie_hellman(keys.secret.to_nonzero_scalar(), as_public.as_affine());
    let mut key_info = Vec::with_capacity(14 + 2 * KEYID_LEN);
    key_info.extend_from_slice(b"WebPush: info\0");
    key_info.extend_from_slice(&keys.public);
    key_info.extend_from_slice(as_bytes);
    let mut ikm = Zeroizing::new([0u8; 32]);
    Hkdf::<sha2::Sha256>::new(Some(keys.auth.as_ref()), shared.raw_secret_bytes().as_slice())
        .expand(&key_info, ikm.as_mut())
        .map_err(|_| "ikm")?;
    let content = Hkdf::<sha2::Sha256>::new(Some(salt), ikm.as_ref());
    let mut cek = Zeroizing::new([0u8; 16]);
    let mut nonce = [0u8; 12];
    content.expand(b"Content-Encoding: aes128gcm\0", cek.as_mut()).map_err(|_| "cek")?;
    content.expand(b"Content-Encoding: nonce\0", &mut nonce).map_err(|_| "nonce")?;

    let cipher = Aes128Gcm::new_from_slice(cek.as_ref()).map_err(|_| "cek")?;
    let mut plain = Zeroizing::new(cipher.decrypt(Nonce::from_slice(&nonce), record).map_err(|_| "tag")?);
    // RFC 8188 padding: zeros after a delimiter, which is 2 in the last record.
    let end = plain.iter().rposition(|&b| b != 0).ok_or("padding")?;
    if plain[end] != 0x02 {
        return Err("delimiter");
    }
    plain.truncate(end);
    if plain.len() > MAX_PLAINTEXT {
        return Err("long");
    }
    Ok(plain)
}

fn field_ok(value: &str) -> bool {
    (1..=MAX_FIELD).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-:.#".contains(&b))
}

/// The wake inside a sealed block, shape-checked field by field.
fn parse_sealed_wake(plain: &[u8]) -> Option<SealedWake> {
    let serde_json::Value::Object(obj) = serde_json::from_slice(plain).ok()? else {
        return None;
    };
    let mut out = BTreeMap::new();
    let kind = obj.get("type")?.as_str()?;
    if kind != "wake" && kind != "channel_wake" {
        return None;
    }
    out.insert("type".to_owned(), kind.to_owned());
    for key in ["sender", "server", "channel"] {
        match obj.get(key) {
            None => {}
            Some(serde_json::Value::String(s)) if field_ok(s) => {
                out.insert(key.to_owned(), s.clone());
            }
            Some(_) => return None,
        }
    }
    if kind == "channel_wake" && !out.contains_key("server") {
        return None;
    }
    match obj.get("mention") {
        None => {}
        Some(serde_json::Value::String(m)) if m == "0" || m == "1" => {
            out.insert("mention".to_owned(), m.clone());
        }
        Some(_) => return None,
    }
    Some(SealedWake { fields: out, ts: obj.get("ts")?.as_u64()? })
}

/// A wake as the sidecar sealed it, with its seal time (sidecar clock, seconds).
struct SealedWake {
    fields: BTreeMap<String, String>,
    ts: u64,
}

/// Who opens a wake. The app and the iOS extension each act on an APNs push once, so
/// each keeps its own record; a tap only picks the chat to open, at any later time.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Reader {
    App,
    Extension,
    Tap,
}

impl Reader {
    fn tag(self) -> Option<char> {
        match self {
            Reader::App => Some('a'),
            Reader::Extension => Some('n'),
            Reader::Tap => None,
        }
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn fresh(ts: u64, now: u64) -> bool {
    ts <= now.saturating_add(WINDOW_SECS) && now <= ts.saturating_add(WINDOW_SECS)
}

/// The seal time a record's name starts with.
fn seen_ts(name: &str) -> Option<u64> {
    name.split_once('-').and_then(|(ts, _)| ts.parse().ok())
}

/// True the first time `reader` opens the blob with this salt and seal time. The
/// record is one file made with `create_new`, so two processes racing on one blob
/// cannot both win, and it outlives a restart.
fn first_open(root: &Path, reader: Reader, salt: &[u8], ts: u64, now: u64) -> bool {
    let Some(tag) = reader.tag() else { return true };
    let dir = root.join(SEEN_DIR);
    let _ = std::fs::create_dir(&dir);
    if !std::fs::symlink_metadata(&dir).is_ok_and(|m| m.is_dir()) {
        return false;
    }
    let name = format!("{ts:011}-{}.{tag}", hex::encode(salt));
    if std::fs::OpenOptions::new().write(true).create_new(true).open(dir.join(name)).is_err() {
        return false;
    }
    prune_seen(&dir, now);
    true
}

/// Drops records a wake that old could no longer pass, then the oldest past the cap.
fn prune_seen(dir: &Path, now: u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut live = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        match seen_ts(&name) {
            Some(ts) if now <= ts.saturating_add(WINDOW_SECS) => live.push(name),
            _ => {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    if live.len() > SEEN_CAP {
        live.sort_unstable();
        for name in &live[..live.len() - SEEN_CAP] {
            let _ = std::fs::remove_file(dir.join(name));
        }
    }
}

/// The wake a push carried, or `None` to drop it. Once this root holds a key pair only
/// a block sealed to it counts, so a plain or tampered wake (from Google, Apple or
/// anyone who can reach the token) is never read, and a sealed one only while fresh
/// and only once per reader, so a captured blob cannot be delivered again.
pub(crate) fn open_wake(root: &Path, fields: &BTreeMap<String, String>, reader: Reader) -> Option<BTreeMap<String, String>> {
    open_wake_at(root, fields, reader, now_secs())
}

fn open_wake_at(
    root: &Path,
    fields: &BTreeMap<String, String>,
    reader: Reader,
    now: u64,
) -> Option<BTreeMap<String, String>> {
    match load(root) {
        Err(()) => None,
        Ok(None) => {
            if fields.contains_key(SEALED_FIELD) {
                return None;
            }
            Some(
                fields
                    .iter()
                    .filter(|(k, _)| WAKE_FIELDS.contains(&k.as_str()))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect(),
            )
        }
        Ok(Some(keys)) => {
            let sealed = fields.get(SEALED_FIELD)?;
            if sealed.len() > MAX_SEALED_B64 {
                return None;
            }
            let body = Zeroizing::new(URL_SAFE_NO_PAD.decode(sealed.trim_end_matches('=')).ok()?);
            let plain = open_body(&keys, &body).ok()?;
            let wake = parse_sealed_wake(&plain)?;
            if reader != Reader::Tap && !(fresh(wake.ts, now) && first_open(root, reader, &body[..SALT_LEN], wake.ts, now)) {
                return None;
            }
            Some(wake.fields)
        }
    }
}

/// The sealed wakes the sidecar's own test wrote (`push-sidecar/test/sealed_wake.test.js`).
#[cfg(test)]
pub(crate) fn fixture_for_test() -> serde_json::Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../push-sidecar/test/sealed_wake_vectors.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("sidecar fixture")).unwrap()
}

/// A data root holding the fixture's receiver keys.
#[cfg(test)]
pub(crate) fn fixture_root_for_test() -> crate::test_tmp::TestDir {
    let v = fixture_for_test();
    let key = |name: &str| URL_SAFE_NO_PAD.decode(v[name].as_str().unwrap()).unwrap();
    let dir = crate::test_tmp::tempdir().unwrap();
    let secret = SecretKey::from_slice(&key("ua_private")).unwrap();
    let auth: [u8; 16] = key("auth").try_into().unwrap();
    store(dir.path(), &PushKeys::from_parts(secret, auth, bind_tag("fixture"))).unwrap();
    dir
}

/// RFC 8291 sealing as the sidecar does it, with the record (delimiter and padding
/// included) and record size chosen by the test.
#[cfg(test)]
pub(crate) fn seal_for_test(keys: &PushKeys, record: &[u8], rs: u32) -> Vec<u8> {
    let eph = SecretKey::from_slice(&[7u8; 32]).unwrap();
    let as_public = eph.public_key().to_encoded_point(false);
    let ua = PublicKey::from_sec1_bytes(&keys.public).unwrap();
    let shared = p256::ecdh::diffie_hellman(eph.to_nonzero_scalar(), ua.as_affine());
    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(&keys.public);
    key_info.extend_from_slice(as_public.as_bytes());
    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(keys.auth.as_ref()), shared.raw_secret_bytes().as_slice())
        .expand(&key_info, &mut ikm)
        .unwrap();
    let mut salt = [0u8; SALT_LEN];
    getrandom::fill(&mut salt).unwrap();
    let content = Hkdf::<Sha256>::new(Some(&salt), &ikm);
    let (mut cek, mut nonce) = ([0u8; 16], [0u8; 12]);
    content.expand(b"Content-Encoding: aes128gcm\0", &mut cek).unwrap();
    content.expand(b"Content-Encoding: nonce\0", &mut nonce).unwrap();
    let ct = Aes128Gcm::new_from_slice(&cek).unwrap().encrypt(Nonce::from_slice(&nonce), record).unwrap();
    let mut body = salt.to_vec();
    body.extend_from_slice(&rs.to_be_bytes());
    body.push(KEYID_LEN as u8);
    body.extend_from_slice(as_public.as_bytes());
    body.extend_from_slice(&ct);
    body
}


/// A fresh sidecar-style blob for `json`, sealed to the fixture's receiver keys.
#[cfg(test)]
pub(crate) fn seal_to_fixture_for_test(json: &str) -> String {
    let v = fixture_for_test();
    let key = |name: &str| URL_SAFE_NO_PAD.decode(v[name].as_str().unwrap()).unwrap();
    let keys = PushKeys::from_parts(
        SecretKey::from_slice(&key("ua_private")).unwrap(),
        key("auth").try_into().unwrap(),
        [0; 32],
    );
    let mut record = json.as_bytes().to_vec();
    record.push(2);
    URL_SAFE_NO_PAD.encode(seal_for_test(&keys, &record, 4096))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b64(s: &str) -> Vec<u8> {
        URL_SAFE_NO_PAD.decode(s).unwrap()
    }

    /// RFC 8291 section 5: the receiver's keys and the example message.
    fn rfc_keys() -> PushKeys {
        let secret = SecretKey::from_slice(&b64("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")).unwrap();
        let auth: [u8; 16] = b64("BTBZMqHH6r4Tts7J_aSIgg").try_into().unwrap();
        PushKeys::from_parts(secret, auth, [0; 32])
    }

    const RFC_BODY: &str = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml\
        mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT\
        pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";

    #[test]
    fn push_seal_opens_rfc8291_example() {
        let keys = rfc_keys();
        assert_eq!(
            URL_SAFE_NO_PAD.encode(keys.public),
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        );
        let plain = open_body(&keys, &b64(RFC_BODY)).expect("RFC 8291 example opens");
        assert_eq!(plain.as_slice(), b"When I grow up, I want to be a watermelon");
    }

    #[test]
    fn push_seal_refuses_a_flipped_tag_or_body_bit() {
        let keys = rfc_keys();
        let body = b64(RFC_BODY);
        for at in [HEADER_LEN, body.len() - 1, 3] {
            let mut bad = body.clone();
            bad[at] ^= 0x01;
            assert!(open_body(&keys, &bad).is_err(), "flip at {at}");
        }
    }

    #[test]
    fn push_seal_refuses_bad_headers() {
        let keys = rfc_keys();
        let body = b64(RFC_BODY);
        // A record size smaller than the record means a second record.
        let mut small_rs = body.clone();
        small_rs[16..20].copy_from_slice(&40u32.to_be_bytes());
        assert_eq!(open_body(&keys, &small_rs).err(), Some("record size"));
        let mut idlen = body.clone();
        idlen[20] = 64;
        assert_eq!(open_body(&keys, &idlen).err(), Some("keyid length"));
        assert_eq!(open_body(&keys, &body[..HEADER_LEN + TAG_LEN]).err(), Some("short"));
    }

    fn fixture() -> serde_json::Value {
        fixture_for_test()
    }

    /// When the sidecar's test sealed the fixture, by its own clock.
    fn sealed_at(v: &serde_json::Value) -> u64 {
        v["sealed_at"].as_u64().unwrap()
    }

    fn fixture_root(_: &serde_json::Value) -> crate::test_tmp::TestDir {
        fixture_root_for_test()
    }

    fn fields(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    }

    /// The sidecar's own output (`push-sidecar/test/sealed_wake.test.js` writes it).
    #[test]
    fn push_seal_opens_the_sidecars_dm_and_channel_wakes() {
        let v = fixture();
        let root = fixture_root(&v);
        for case in v["cases"].as_array().unwrap() {
            let data: BTreeMap<String, String> = serde_json::from_value(case["data"].clone()).unwrap();
            assert_eq!(data.keys().collect::<Vec<_>>(), vec![SEALED_FIELD], "only the blob rides FCM");
            let want: BTreeMap<String, String> = serde_json::from_value(case["wake"].clone()).unwrap();
            assert_eq!(open_wake_at(root.path(), &data, Reader::App, sealed_at(&v)), Some(want));
        }
    }

    #[test]
    fn push_seal_drops_an_unsealed_wake_once_keys_exist() {
        let v = fixture();
        let root = fixture_root(&v);
        let plain = fields(&[("type", "wake"), ("sender", "12D3KooWAbc")]);
        assert_eq!(open_wake(root.path(), &plain, Reader::App), None);
        // Plain fields riding beside a valid blob are never read.
        let mut both: BTreeMap<String, String> =
            serde_json::from_value(v["cases"][0]["data"].clone()).unwrap();
        both.insert("sender".into(), "someone-else".into());
        let opened = open_wake_at(root.path(), &both, Reader::App, sealed_at(&v)).unwrap();
        assert_ne!(opened.get("sender").map(String::as_str), Some("someone-else"));
    }

    #[test]
    fn push_seal_drops_a_tampered_or_oversized_blob() {
        let v = fixture();
        let root = fixture_root(&v);
        let sealed = v["cases"][0]["data"][SEALED_FIELD].as_str().unwrap().to_owned();
        let mut raw = b64(&sealed);
        let last = raw.len() - 1;
        raw[last] ^= 0x80;
        let tampered = fields(&[(SEALED_FIELD, &URL_SAFE_NO_PAD.encode(&raw))]);
        assert_eq!(open_wake(root.path(), &tampered, Reader::App), None);
        let huge = "A".repeat(MAX_SEALED_B64 + 1);
        assert_eq!(open_wake(root.path(), &fields(&[(SEALED_FIELD, &huge)]), Reader::App), None);
        assert_eq!(open_wake(root.path(), &fields(&[(SEALED_FIELD, "not base64!")]), Reader::App), None);
    }

    #[test]
    fn push_seal_without_keys_reads_plain_wakes_only() {
        let root = crate::test_tmp::tempdir().unwrap();
        let plain = fields(&[("type", "channel_wake"), ("sender", "d1"), ("server", "s1"), ("extra", "x")]);
        let opened = open_wake(root.path(), &plain, Reader::App).unwrap();
        assert_eq!(opened, fields(&[("type", "channel_wake"), ("sender", "d1"), ("server", "s1")]));
        let v = fixture();
        let data: BTreeMap<String, String> = serde_json::from_value(v["cases"][0]["data"].clone()).unwrap();
        assert_eq!(open_wake_at(root.path(), &data, Reader::App, sealed_at(&v)), None, "a blob with no key to open it");
    }

    #[test]
    fn push_seal_a_broken_key_file_drops_every_wake() {
        let root = crate::test_tmp::tempdir().unwrap();
        std::fs::write(root.path().join(KEY_FILE), [0u8; FILE_LEN]).unwrap();
        assert_eq!(open_wake(root.path(), &fields(&[("type", "wake")]), Reader::App), None);
    }

    const WAKE: &[u8] = br#"{"type":"wake","sender":"d1"}"#;

    fn keyed_root() -> (crate::test_tmp::TestDir, PushKeys) {
        let dir = crate::test_tmp::tempdir().unwrap();
        store(dir.path(), &rfc_keys()).unwrap();
        (dir, rfc_keys())
    }

    fn sealed(keys: &PushKeys, json: &str) -> BTreeMap<String, String> {
        let record = [json.as_bytes(), &[2]].concat();
        fields(&[(SEALED_FIELD, &URL_SAFE_NO_PAD.encode(seal_for_test(keys, &record, 4096)))])
    }

    #[test]
    fn push_seal_refuses_a_stale_wake() {
        let (root, keys) = keyed_root();
        let now = now_secs();
        let at = |ts: u64| sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{ts}}}"#));
        assert_eq!(open_wake(root.path(), &at(now - WINDOW_SECS - 60), Reader::App), None, "older than the relay keeps it");
        assert_eq!(open_wake(root.path(), &at(now + WINDOW_SECS + 60), Reader::App), None, "further ahead than a day");
        assert!(open_wake(root.path(), &at(now + WAKE_TTL_SECS), Reader::App).is_some(), "a phone a day behind still counts");
        assert_eq!(open_wake(root.path(), &sealed(&keys, r#"{"type":"wake","sender":"d1"}"#), Reader::App), None, "no time at all");
        assert_eq!(open_wake(root.path(), &sealed(&keys, r#"{"type":"wake","sender":"d1","ts":"1"}"#), Reader::App), None);
        assert!(open_wake(root.path(), &at(now - WAKE_TTL_SECS + 60), Reader::App).is_some(), "a day-old wake still counts");
    }

    #[test]
    fn push_seal_refuses_a_replayed_wake() {
        let (root, keys) = keyed_root();
        let wake = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{}}}"#, now_secs()));
        assert!(open_wake(root.path(), &wake, Reader::App).is_some());
        assert_eq!(open_wake(root.path(), &wake, Reader::App), None, "the same blob again");
        // What a restart, or another process on the same root, finds on disk.
        let copy = crate::test_tmp::tempdir().unwrap();
        for name in [KEY_FILE, SEEN_DIR] {
            let from = root.path().join(name);
            if from.is_dir() {
                std::fs::create_dir(copy.path().join(name)).unwrap();
                for e in std::fs::read_dir(&from).unwrap().flatten() {
                    std::fs::copy(e.path(), copy.path().join(name).join(e.file_name())).unwrap();
                }
            } else {
                std::fs::copy(&from, copy.path().join(name)).unwrap();
            }
        }
        assert_eq!(open_wake(copy.path(), &wake, Reader::App), None, "the record survives a reload");
    }

    #[test]
    fn push_seal_padding_ends_in_the_last_record_delimiter() {
        let keys = rfc_keys();
        let record = |tail: &[u8]| [WAKE, tail].concat();
        let ok = open_body(&keys, &seal_for_test(&keys, &record(&[2, 0, 0, 0]), 4096)).unwrap();
        assert_eq!(ok.as_slice(), WAKE);
        assert_eq!(open_body(&keys, &seal_for_test(&keys, &record(&[1, 0, 0]), 4096)).err(), Some("delimiter"));
        assert_eq!(open_body(&keys, &seal_for_test(&keys, &[0u8; 8], 4096)).err(), Some("padding"));
    }

    #[test]
    fn push_seal_size_bound_holds_for_a_blob_that_would_open() {
        let dir = crate::test_tmp::tempdir().unwrap();
        let keys = rfc_keys();
        store(dir.path(), &keys).unwrap();
        // Zero padding keeps the wake under the plaintext bound while the blob grows.
        let wake = format!(r#"{{"type":"wake","sender":"d1","ts":{}}}"#, now_secs());
        let mut record = [wake.as_bytes(), &[2]].concat();
        record.resize(3100, 0);
        let body = seal_for_test(&keys, &record, 4096);
        let plain = open_body(&keys, &body).unwrap();
        assert!(parse_sealed_wake(&plain).is_some_and(|w| fresh(w.ts, now_secs())), "only the size bound refuses it");
        let b64 = URL_SAFE_NO_PAD.encode(&body);
        assert!(b64.len() > MAX_SEALED_B64);
        assert_eq!(open_wake(dir.path(), &fields(&[(SEALED_FIELD, &b64)]), Reader::App), None);
        let small = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{}}}"#, now_secs()));
        assert_eq!(open_wake(dir.path(), &small, Reader::App), Some(fields(&[("type", "wake"), ("sender", "d1")])));
    }

    #[test]
    fn push_seal_inner_wake_is_shape_checked() {
        let ok = br#"{"type":"channel_wake","sender":"d1","server":"s1","channel":"c1","mention":"1","ts":1760788800}  "#;
        let wake = parse_sealed_wake(ok).unwrap();
        assert_eq!(wake.ts, 1_760_788_800);
        assert_eq!(wake.fields.len(), 5);
        for bad in [
            &br#"{"type":"call","sender":"d1","ts":1}"#[..],
            br#"{"type":"channel_wake","sender":"d1","ts":1}"#,
            br#"{"type":"wake","sender":"d 1","ts":1}"#,
            br#"{"type":"wake","sender":7,"ts":1}"#,
            br#"{"type":"wake","mention":"yes","ts":1}"#,
            br#"{"type":"wake","sender":"d1"}"#,
            br#"{"type":"wake","ts":-1}"#,
            br#"{"type":"wake","ts":1.5}"#,
            br#"{"type":"wake","ts":"1760788800"}"#,
            br#"["wake"]"#,
        ] {
            assert!(parse_sealed_wake(bad).is_none(), "{}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn push_seal_token_keeps_its_key_and_rekeys_for_a_new_identity() {
        let root = crate::test_tmp::tempdir().unwrap();
        std::fs::write(root.path().join("identity.key"), b"identity").unwrap();
        let t1: serde_json::Value = serde_json::from_str(&keyed_token(root.path(), "fcm-abc", "dev1").ok().unwrap()).unwrap();
        assert_eq!(t1["v"], 2);
        assert_eq!(t1["fcm"], "fcm-abc");
        assert_eq!(b64(t1["p256dh"].as_str().unwrap()).len(), KEYID_LEN);
        assert_eq!(b64(t1["auth"].as_str().unwrap()).len(), 16);
        let t2: serde_json::Value = serde_json::from_str(&keyed_token(root.path(), "fcm-xyz", "dev1").ok().unwrap()).unwrap();
        assert_eq!(t1["p256dh"], t2["p256dh"], "one key pair per install");
        let t3: serde_json::Value = serde_json::from_str(&keyed_token(root.path(), "fcm-xyz", "dev2").ok().unwrap()).unwrap();
        assert_ne!(t1["p256dh"], t3["p256dh"]);
        assert_ne!(t1["auth"], t3["auth"]);
        assert_eq!(token_for_relay(root.path(), "unifiedpush", "{\"v\":1}".into(), "dev2"), Ok("{\"v\":1}".into()));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(root.path().join(KEY_FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o077, 0, "owner only");
        }
    }

    /// On iOS one push reaches the extension and the app's handler: each acts on it
    /// once. A tap only routes, so an old banner still opens its chat.
    #[test]
    fn push_seal_each_reader_opens_a_blob_once_and_a_tap_routes_at_any_age() {
        let (root, keys) = keyed_root();
        let now = now_secs();
        let wake = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{now}}}"#));
        assert!(open_wake(root.path(), &wake, Reader::Extension).is_some());
        assert!(open_wake(root.path(), &wake, Reader::App).is_some());
        assert_eq!(open_wake(root.path(), &wake, Reader::Extension), None);
        assert_eq!(open_wake(root.path(), &wake, Reader::App), None);
        assert!(open_wake(root.path(), &wake, Reader::Tap).is_some());
        let old = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{}}}"#, now - 3 * WAKE_TTL_SECS));
        assert!(open_wake(root.path(), &old, Reader::Tap).is_some());
        assert_eq!(open_wake(root.path(), &old, Reader::App), None);
        let records = std::fs::read_dir(root.path().join(SEEN_DIR)).unwrap().count();
        assert_eq!(records, 2, "a tap records nothing");
    }

    /// The record stays bounded: what the window refuses anyway goes, then the oldest.
    #[test]
    fn push_seal_seen_records_are_bounded_oldest_first() {
        let (root, keys) = keyed_root();
        let now = now_secs();
        let dir = root.path().join(SEEN_DIR);
        std::fs::create_dir(&dir).unwrap();
        let stale = now - WINDOW_SECS - 1;
        std::fs::write(dir.join(format!("{stale:011}-00.a")), b"").unwrap();
        std::fs::write(dir.join("junk"), b"").unwrap();
        let first = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{now}}}"#));
        assert!(open_wake(root.path(), &first, Reader::App).is_some());
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1, "what the window refuses anyway goes at once");
        std::fs::write(dir.join(format!("{stale:011}-00.a")), b"").unwrap();
        std::fs::write(dir.join("junk"), b"").unwrap();
        for i in 0..SEEN_CAP as u64 {
            std::fs::write(dir.join(format!("{:011}-{i:032x}.a", now - 1000 + i % 500)), b"").unwrap();
        }
        let oldest = format!("{:011}-{:032x}.a", now - 1000, 0);
        let wake = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{now}}}"#));
        assert!(open_wake(root.path(), &wake, Reader::App).is_some());
        let names: Vec<String> =
            std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(names.len(), SEEN_CAP);
        assert!(!names.iter().any(|n| n.starts_with(&format!("{stale:011}")) || n == "junk"));
        assert!(!names.contains(&oldest), "the oldest record went first");
        assert!(names.iter().any(|n| n.starts_with(&format!("{now:011}-"))), "the new record stays");
    }

    /// A root that cannot hold the record refuses the wake rather than act on it twice.
    #[test]
    fn push_seal_a_wake_it_cannot_record_is_dropped() {
        let (root, keys) = keyed_root();
        std::fs::write(root.path().join(SEEN_DIR), b"not a folder").unwrap();
        let wake = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{}}}"#, now_secs()));
        assert_eq!(open_wake(root.path(), &wake, Reader::App), None);
        // Nor does a record go through a link out of the root.
        #[cfg(unix)]
        {
            let (root, keys) = keyed_root();
            let elsewhere = crate::test_tmp::tempdir().unwrap();
            std::os::unix::fs::symlink(elsewhere.path(), root.path().join(SEEN_DIR)).unwrap();
            let wake = sealed(&keys, &format!(r#"{{"type":"wake","sender":"d1","ts":{}}}"#, now_secs()));
            assert_eq!(open_wake(root.path(), &wake, Reader::App), None);
            assert_eq!(std::fs::read_dir(elsewhere.path()).unwrap().count(), 0);
        }
    }

    /// No key is minted where the identity is gone or a wipe is pending, and nothing
    /// is registered there at all.
    #[test]
    fn push_seal_a_wiped_root_registers_nothing() {
        let root = crate::test_tmp::tempdir().unwrap();
        assert!(token_for_relay(root.path(), "android", "t".into(), "dev1").is_err(), "no identity");
        assert!(token_for_relay(root.path(), "unifiedpush", "{}".into(), "dev1").is_err(), "nor a UnifiedPush token");
        std::fs::write(root.path().join("identity.key"), b"identity").unwrap();
        std::fs::write(root.path().join(crate::api::wipe::MARKER), b"destroy").unwrap();
        assert!(token_for_relay(root.path(), "ios", "t".into(), "dev1").is_err(), "a wipe is pending");
        assert!(!root.path().join(KEY_FILE).exists());
        std::fs::remove_file(root.path().join(crate::api::wipe::MARKER)).unwrap();
        assert!(token_for_relay(root.path(), "ios", "t".into(), "dev1").unwrap().starts_with('{'));
        // Dart relaunches after a destroy; until then the root stays refused.
        let other = crate::test_tmp::tempdir().unwrap();
        std::fs::write(other.path().join("identity.key"), b"identity").unwrap();
        crate::api::wipe::mark_destroyed_for_test(other.path());
        assert!(token_for_relay(other.path(), "android", "t".into(), "dev1").is_err(), "destroyed in this process");
        assert!(!other.path().join(KEY_FILE).exists());
    }
}
