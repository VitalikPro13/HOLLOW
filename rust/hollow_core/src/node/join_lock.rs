//! The join lock: which key a joiner seals its request to, and who may move it.
//!
//! Two keys share one number. The door key (X25519) is held by every current member
//! and opens join requests; the change key (Ed25519) is held by the owner, admins
//! and mods, and signs the next lock. The relay keeps the chain as a notice board:
//! it takes a new lock only when the current change key signed it, so a joiner who
//! checks the chain back to the owner and takes the newest lock seals to a door that
//! nobody removed since holds. The relay can withhold the chain, never forge it.
//! Invite links stay static: `key=` remains the invite capability, and every
//! request is sealed to the door and the invite key together.

use base64::Engine;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use super::sealed_box;
use crate::identity::native_identity::NativeKeypair;

/// The most links one chain may hold. Owners compact it to one whenever online.
pub(crate) const MAX_CHAIN: usize = 256;
/// Every lock number stays an exact integer in any JSON reader.
pub(crate) const MAX_N: u64 = (1 << 53) - 1;
/// The furthest an owner-signed link may jump past the relay's newest lock, so no
/// master-key holder can push the number to the ceiling (2^33 resets away).
pub(crate) const RESET_STEP: u64 = 1 << 20;
/// A newest lock above this is frozen: no honest chain gets there, so the relay takes
/// a counted owner device's new start over it.
pub(crate) const FROZEN_FROM: u64 = MAX_N - RESET_STEP;

const LINK_DOMAIN: &str = "hollow-lock1";
const DEV_DOMAIN: &str = "hollow-lock-dev1";
const GRANT_DOMAIN: &[u8] = b"hollow-lock-grant1";

/// The device that made a link: its key (encoded like `change`), the identity it is
/// a device of, and its signature over the link. The relay judges the device against
/// its fold of that identity's rosters; the master key alone proves nothing.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LockDev {
    pub device: String,
    pub master: String,
    pub sig: String,
}

/// One lock in the chain: the door's public half, the change key's public half, and
/// the signature that makes it the successor of the one before, or the owner's.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LockLink {
    pub n: u64,
    /// X25519, URL-safe base64 without padding (43 characters).
    pub door: String,
    /// Ed25519, protobuf-encoded as the relay's auth carries keys, standard base64.
    pub change: String,
    pub sig: String,
    /// On an owner-signed link: the owner's key, encoded like `change`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// On an owner-signed link of a self-certifying id: the founding nonce, which
    /// with the owner's id hashes to the server id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nonce: Option<String>,
    /// The device that made this link (0.14); a 0.13 link has none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dev: Option<LockDev>,
}

impl std::fmt::Debug for LockLink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LockLink(n={}, base={})", self.n, self.is_base())
    }
}

impl LockLink {
    pub fn is_base(&self) -> bool {
        self.owner.is_some()
    }

    /// The same lock: number, door and change key, however it was signed.
    pub fn same_lock(&self, other: &LockLink) -> bool {
        self.n == other.n && self.door == other.door && self.change == other.change
    }

    pub fn door_key(&self) -> Option<[u8; 32]> {
        sealed_box::key_from_text(&self.door)
    }

    fn payload(&self, server_id: &str) -> String {
        let head = format!("{LINK_DOMAIN}\n{server_id}\n{}\n{}\n{}\n", self.n, self.door, self.change);
        match &self.owner {
            Some(owner) => format!("{head}base\n{owner}\n{}", self.nonce.as_deref().unwrap_or("")),
            None => format!("{head}next"),
        }
    }

    fn dev_payload(&self, server_id: &str, master: &str) -> String {
        format!("{DEV_DOMAIN}\n{master}\n{}", self.payload(server_id))
    }

    /// Every field within the one shape the relay stores, before any signature is read.
    fn well_formed(&self) -> bool {
        let std_b64 = |s: &str, len: usize| {
            s.len() == len && base64::engine::general_purpose::STANDARD.decode(s).is_ok()
        };
        self.n <= MAX_N
            && self.door_key().is_some()
            && key_bytes(&self.change).is_some()
            && std_b64(&self.sig, 88)
            && self.owner.as_deref().is_none_or(|o| key_bytes(o).is_some())
            && self.nonce.as_deref().is_none_or(|n| n.len() <= 64 && n.bytes().all(|b| b.is_ascii_hexdigit()))
            && (self.owner.is_some() || self.nonce.is_none())
            && self.dev.as_ref().is_none_or(|d| {
                key_bytes(&d.device).is_some() && peer_id_shape(&d.master) && std_b64(&d.sig, 88)
            })
    }
}

/// A peer id as the relay's `is_peer_id_shape` reads one: 40 to 64 base58 characters.
fn peer_id_shape(id: &str) -> bool {
    (40..=64).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() && !matches!(b, b'0' | b'O' | b'I' | b'l'))
}

/// The device that made `link` and the identity it names, when its proof verifies.
/// An owner-signed link's device must name the owner.
pub fn link_device(server_id: &str, link: &LockLink) -> Option<(String, String)> {
    let dev = link.dev.as_ref()?;
    if !link.well_formed() {
        return None;
    }
    let key = key_bytes(&dev.device)?;
    if let Some(owner) = link.owner.as_deref()
        && NativeKeypair::peer_id_from_pubkey_protobuf(&key_bytes(owner)?)?.as_str() != dev.master
    {
        return None;
    }
    if !signed_by(&dev.device, &link.dev_payload(server_id, &dev.master), &dev.sig) {
        return None;
    }
    Some((dev.master.clone(), NativeKeypair::peer_id_from_pubkey_protobuf(&key)?))
}

/// The device proof on `link`, made by `device` as a device of `master`.
fn device_signed(server_id: &str, mut link: LockLink, master: &str, device: &NativeKeypair) -> LockLink {
    link.dev = None;
    let sig = base64::engine::general_purpose::STANDARD.encode(device.sign(link.dev_payload(server_id, master).as_bytes()));
    link.dev = Some(LockDev { device: key_text(device), master: master.to_string(), sig });
    link
}

/// The protobuf bytes of a key as a link carries it, when it is an Ed25519 key.
fn key_bytes(text: &str) -> Option<Vec<u8>> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(text).ok()?;
    (bytes.len() == 36 && bytes[..4] == [0x08, 0x01, 0x12, 0x20]).then_some(bytes)
}

fn key_text(keypair: &NativeKeypair) -> String {
    base64::engine::general_purpose::STANDARD.encode(keypair.public_key_protobuf())
}

fn signed_by(key: &str, payload: &str, sig: &str) -> bool {
    let (Some(key), Ok(sig)) = (key_bytes(key), base64::engine::general_purpose::STANDARD.decode(sig)) else {
        return false;
    };
    NativeKeypair::verify_peer_signature(&key, &sig, payload.as_bytes()).unwrap_or(false)
}

/// The owner an owner-signed link speaks for: its key derives the id, a
/// self-certifying server id hashes from that id and the nonce, and the key signed it.
pub fn base_owner(server_id: &str, link: &LockLink) -> Option<String> {
    let owner_key = link.owner.as_deref()?;
    if !link.well_formed() {
        return None;
    }
    let owner = NativeKeypair::peer_id_from_pubkey_protobuf(&key_bytes(owner_key)?)?;
    if crate::crdt::anchor::is_genesis_id(server_id)
        && crate::crdt::anchor::derive_server_id(&owner, link.nonce.as_deref()?) != server_id
    {
        return None;
    }
    // A device proof that does not verify makes the link a forgery, never a 0.13 one.
    if link.dev.is_some() && link_device(server_id, link).is_none() {
        return None;
    }
    signed_by(owner_key, &link.payload(server_id), &link.sig).then_some(owner)
}

/// Whether `next` is a successor `prev`'s change key signed.
pub fn extends(server_id: &str, prev: &LockLink, next: &LockLink) -> bool {
    !next.is_base()
        && next.well_formed()
        && prev.n.checked_add(1) == Some(next.n)
        && (next.dev.is_none() || link_device(server_id, next).is_some())
        && signed_by(&prev.change, &next.payload(server_id), &next.sig)
}

/// The owner a whole chain speaks for: an owner-signed first link, each later one a
/// successor or a newer owner-signed link. `expected_owner` pins it (an invite's
/// `owner=` on a server whose id does not name its owner).
pub fn verify_chain(server_id: &str, links: &[LockLink], expected_owner: Option<&str>) -> Option<String> {
    if links.is_empty() || links.len() > MAX_CHAIN {
        return None;
    }
    let owner = base_owner(server_id, &links[0])?;
    if expected_owner.is_some_and(|pin| pin != owner) {
        return None;
    }
    for pair in links.windows(2) {
        let next_ok = if pair[1].is_base() {
            pair[1].n > pair[0].n && base_owner(server_id, &pair[1]).as_deref() == Some(owner.as_str())
        } else {
            extends(server_id, &pair[0], &pair[1])
        };
        if !next_ok {
            return None;
        }
    }
    Some(owner)
}

/// The relay's key for a server's chain. A self-certifying id admits one owner; any
/// other id is kept per owner, so nobody can claim another owner's server first.
#[cfg(test)]
pub fn record_key(server_id: &str, owner: &str) -> String {
    if crate::crdt::anchor::is_genesis_id(server_id) {
        server_id.to_string()
    } else {
        format!("{server_id}|{owner}")
    }
}

/// The relay's rule for a submitted chain against the one it holds: the chain it
/// holds afterwards, or `None` when it refuses. `counted` is the relay's fold of an
/// identity's rosters: whether it counts a device of that master.
///
/// - The first valid extension of the newest lock wins. A link made by a device the
///   fold counts may also extend an older held lock when every link after that one
///   is DEAD (its proof names a device the fold no longer counts) and of the forker's
///   identity, unless the forker is the owner, so a removed device that kept a change
///   key to itself cannot darken the room, and an ex-mod's older key moves nothing. A
///   link without a proof is never dead.
/// - An owner-signed link the relay does not hold must be made by an owner device
///   the fold counts, and may reset a fork by at most `RESET_STEP` past the newest.
/// - A link after one with a device proof, and any link with one, is taken new only
///   from a counted device; 0.13 links without proofs extend 0.13 links.
/// - A shorter chain ending in the same lock compacts it. A frozen newest lock (past
///   `FROZEN_FROM`) is no lock: a counted owner device starts over.
#[cfg(test)]
pub fn relay_put(
    server_id: &str,
    stored: &[LockLink],
    submitted: &[LockLink],
    counted: &dyn Fn(&str, &str) -> bool,
) -> Option<Vec<LockLink>> {
    let made_counted = |l: &LockLink| link_device(server_id, l).is_some_and(|(m, d)| counted(&m, &d));
    let first = submitted.first()?;
    if !first.is_base() {
        let tip = stored.last()?;
        let at = if extends(server_id, tip, first) {
            stored.len() - 1
        } else {
            let at = stored.iter().rposition(|l| extends(server_id, l, first))?;
            let (forker, _) = link_device(server_id, first).filter(|(m, d)| counted(m, d))?;
            let owner = base_owner(server_id, &stored[0]);
            for link in &stored[at + 1..] {
                link_device(server_id, link)
                    .filter(|(m, d)| !counted(m, d) && (owner.as_deref() == Some(forker.as_str()) || *m == forker))?;
            }
            at
        };
        let mut prev = &stored[at];
        for link in submitted {
            if !extends(server_id, prev, link) || ((prev.dev.is_some() || link.dev.is_some()) && !made_counted(link)) {
                return None;
            }
            prev = link;
        }
        if at + 1 + submitted.len() > MAX_CHAIN {
            return None;
        }
        return Some([&stored[..=at], submitted].concat());
    }
    let owner = verify_chain(server_id, submitted, None)?;
    let stored = if stored.last().is_some_and(|t| t.n > FROZEN_FROM) { &[] } else { stored };
    let held_n = stored.last().map_or(0, |t| t.n);
    for pair in std::iter::once((None, first)).chain(submitted.windows(2).map(|w| (Some(&w[0]), &w[1]))) {
        let (prev, link) = pair;
        let new_base = link.is_base() && !stored.contains(link);
        let new_next = !link.is_base()
            && link.n > held_n
            && (link.dev.is_some() || prev.is_some_and(|p| p.dev.is_some()));
        if (new_base || new_next) && !made_counted(link) {
            return None;
        }
    }
    let Some(tip) = stored.last() else { return Some(submitted.to_vec()) };
    if stored.first().and_then(|b| base_owner(server_id, b)).as_deref() != Some(owner.as_str()) {
        return None;
    }
    let newest = submitted.last()?;
    if newest.n > tip.n {
        let continues = submitted.iter().any(|l| l.same_lock(tip));
        let reset = submitted.iter().rev().find(|l| l.is_base()).is_some_and(|b| b.n > tip.n);
        let within = newest.n - tip.n <= RESET_STEP;
        return ((continues || reset) && within).then(|| submitted.to_vec());
    }
    if newest.same_lock(tip) {
        return Some(if submitted.len() < stored.len() { submitted.to_vec() } else { stored.to_vec() });
    }
    None
}

/// How long a lock a joiner read stays good for sealing a new ask to. Answers never
/// ride on it: each waits for a read asked after it arrived.
pub(crate) const LOCK_FRESH: std::time::Duration = std::time::Duration::from_secs(20);

/// The chain a joiner verified from the relay, and when.
#[derive(Clone, Debug)]
pub(crate) struct VerifiedLock {
    pub links: Vec<LockLink>,
    pub checked_at: std::time::Instant,
}

impl VerifiedLock {
    pub fn newest(&self) -> Option<&LockLink> {
        self.links.last()
    }

    pub fn fresh(&self) -> bool {
        self.checked_at.elapsed() < LOCK_FRESH
    }
}

/// A lock just made: the link, and the two secrets behind it.
pub(crate) struct NewLock {
    pub link: LockLink,
    pub door: Zeroizing<[u8; 32]>,
    pub change: Zeroizing<[u8; 32]>,
}

/// New secrets and their link, not signed yet.
fn fresh(n: u64) -> Option<NewLock> {
    let door = sealed_box::new_secret()?;
    let change = sealed_box::new_secret()?;
    let link = LockLink {
        n,
        door: sealed_box::key_to_text(&sealed_box::public_of(&door)),
        change: key_text(&NativeKeypair::from_secret_bytes(&change)),
        sig: String::new(),
        owner: None,
        nonce: None,
        dev: None,
    };
    #[cfg(test)]
    TEST_DOORS.lock().unwrap_or_else(|p| p.into_inner()).insert(link.door.clone(), *door);
    Some(NewLock { link, door, change })
}

/// Every door this process made, by public half: what the harness plays a member or
/// a removed member with.
#[cfg(test)]
static TEST_DOORS: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, [u8; 32]>>> =
    std::sync::LazyLock::new(Default::default);

#[cfg(test)]
pub(crate) fn test_door_secret(door: &str) -> Option<[u8; 32]> {
    TEST_DOORS.lock().unwrap_or_else(|p| p.into_inner()).get(door).copied()
}

#[cfg(test)]
pub(crate) fn test_door_secrets() -> Vec<Zeroizing<[u8; 32]>> {
    TEST_DOORS.lock().unwrap_or_else(|p| p.into_inner()).values().map(|d| Zeroizing::new(*d)).collect()
}

/// Sign `link` as the owner, keeping its number and keys, with the proof of the
/// owner device that signs it.
pub(crate) fn owner_signed(
    server_id: &str,
    link: &LockLink,
    owner: &NativeKeypair,
    nonce: Option<&str>,
    device: &NativeKeypair,
) -> LockLink {
    let mut base = LockLink {
        owner: Some(key_text(owner)),
        nonce: nonce.filter(|_| crate::crdt::anchor::is_genesis_id(server_id)).map(str::to_string),
        sig: String::new(),
        dev: None,
        ..link.clone()
    };
    base.sig = base64::engine::general_purpose::STANDARD.encode(owner.sign(base.payload(server_id).as_bytes()));
    device_signed(server_id, base, &owner.peer_id(), device)
}

/// A 0.13 owner base, with no device proof: what an old client makes. Tests only.
#[cfg(test)]
pub(crate) fn mint_base(server_id: &str, n: u64, owner: &NativeKeypair, nonce: Option<&str>) -> Option<NewLock> {
    let mut lock = mint_owner_base(server_id, n, owner, nonce, owner)?;
    lock.link.dev = None;
    Some(lock)
}

/// A 0.13 successor, with no device proof. Tests only.
#[cfg(test)]
pub(crate) fn mint_next(server_id: &str, prev: &LockLink, prev_change: &[u8; 32]) -> Option<NewLock> {
    let signer = NativeKeypair::from_secret_bytes(prev_change);
    let mut lock = mint_successor(server_id, prev, prev_change, &signer.peer_id(), &signer)?;
    lock.link.dev = None;
    Some(lock)
}

/// A new lock the owner signs: the first one, or a reset past a fork.
pub(crate) fn mint_owner_base(
    server_id: &str,
    n: u64,
    owner: &NativeKeypair,
    nonce: Option<&str>,
    device: &NativeKeypair,
) -> Option<NewLock> {
    let mut lock = fresh(n)?;
    lock.link = owner_signed(server_id, &lock.link, owner, nonce, device);
    Some(lock)
}

/// The lock after `prev`, signed with `prev`'s change key, made by `device` of `master`.
pub(crate) fn mint_successor(
    server_id: &str,
    prev: &LockLink,
    prev_change: &[u8; 32],
    master: &str,
    device: &NativeKeypair,
) -> Option<NewLock> {
    let signer = NativeKeypair::from_secret_bytes(prev_change);
    if key_text(&signer) != prev.change {
        return None;
    }
    let mut lock = fresh(prev.n.checked_add(1).filter(|n| *n <= MAX_N)?)?;
    lock.link.sig = base64::engine::general_purpose::STANDARD.encode(signer.sign(lock.link.payload(server_id).as_bytes()));
    lock.link = device_signed(server_id, lock.link, master, device);
    Some(lock)
}

/// The X25519 public key of a peer id: a master's, which every device of it can use,
/// or one device's own.
pub(crate) fn peer_x25519(peer_id: &str) -> Option<[u8; 32]> {
    let ed = crate::crypto::safety_number::pubkey_from_peer_id(peer_id)?;
    Some(ed25519_dalek::VerifyingKey::from_bytes(&ed).ok()?.to_montgomery().to_bytes())
}

/// Most devices of one owner, admin or mod a change key is sealed to.
pub(crate) const GRANT_DEVICES: usize = 8;

/// What a device's grant is filed under: its identity, which the fold judges the rank
/// of, and the device, the only one that opens it.
pub(crate) fn grant_key(master: &str, device: &str) -> String {
    format!("{master}/{device}")
}

/// The identity a grant is filed under: a device grant's master, or the master a 0.13
/// grant names. The fold's rule reads it (REQUESTS R1).
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn grant_holder(key: &str) -> &str {
    key.split_once('/').map_or(key, |(master, _)| master)
}

/// The device a grant is filed for, `None` for a 0.13 grant sealed to a master.
pub(crate) fn grant_device(key: &str) -> Option<&str> {
    key.split_once('/').map(|(_, device)| device)
}

fn grant_aad(server_id: &str, change: &str, key: &str) -> Vec<u8> {
    [server_id.as_bytes(), b"\0", change.as_bytes(), b"\0", key.as_bytes()].concat()
}

/// A change key sealed to one device of an owner, admin or mod: its grant key and grant.
pub(crate) fn seal_grant(server_id: &str, change: &str, master: &str, device: &str, change_secret: &[u8; 32]) -> Option<(String, String)> {
    let key = grant_key(master, device);
    Some((key.clone(), seal_to(server_id, change, &key, device, change_secret)?))
}

/// The 0.13 grant, sealed to the master: only while the fold refuses device keys.
pub(crate) fn seal_master_grant(server_id: &str, change: &str, master: &str, change_secret: &[u8; 32]) -> Option<String> {
    seal_to(server_id, change, master, master, change_secret)
}

fn seal_to(server_id: &str, change: &str, key: &str, recipient: &str, change_secret: &[u8; 32]) -> Option<String> {
    let sealed = sealed_box::seal(&peer_x25519(recipient)?, GRANT_DOMAIN, &grant_aad(server_id, change, key), change_secret)?;
    Some(format!("{}.{}", sealed.eph, sealed.ct))
}

/// The change key a grant filed under `key` holds for `opener` (the device it names,
/// or the master of a 0.13 grant), when it opens and is the key it names.
pub(crate) fn open_grant(server_id: &str, change: &str, key: &str, opener: &NativeKeypair, grant: &str) -> Option<Zeroizing<[u8; 32]>> {
    if grant_device(key).unwrap_or(key) != opener.peer_id() {
        return None;
    }
    let (eph, ct) = grant.split_once('.')?;
    let plain = Zeroizing::new(sealed_box::open(&opener.x25519_scalar_bytes(), GRANT_DOMAIN, &grant_aad(server_id, change, key), eph, ct)?);
    let secret = Zeroizing::new(<[u8; 32]>::try_from(plain.as_slice()).ok()?);
    (key_text(&NativeKeypair::from_secret_bytes(&secret)) == change).then_some(secret)
}

/// A grant's text within the shape one sealed 32-byte key takes.
pub(crate) fn grant_shape(grant: &str) -> bool {
    grant.len() <= 160 && grant.split_once('.').is_some_and(|(eph, ct)| eph.len() == 44 && ct.len() == 64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kp(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    /// The owner's device in these tests, and a mod's.
    fn owner_dev() -> NativeKeypair {
        kp(11)
    }

    fn mod_dev() -> NativeKeypair {
        kp(16)
    }

    /// A self-certifying server of `owner`, with its founding nonce.
    fn genesis(owner: &NativeKeypair) -> (String, String) {
        let nonce = "00112233445566778899aabbccddeeff".to_string();
        (crate::crdt::anchor::derive_server_id(&owner.peer_id(), &nonce), nonce)
    }

    /// The relay's fold counting exactly these (master, device) pairs.
    type Counted = Box<dyn Fn(&str, &str) -> bool>;

    fn counting(pairs: &[(&NativeKeypair, &NativeKeypair)]) -> Counted {
        let pairs: Vec<(String, String)> = pairs.iter().map(|(m, d)| (m.peer_id(), d.peer_id())).collect();
        Box::new(move |m: &str, d: &str| pairs.iter().any(|(pm, pd)| pm == m && pd == d))
    }

    fn owner_counted(owner: &NativeKeypair) -> Counted {
        counting(&[(owner, &owner_dev()), (&kp(6), &mod_dev())])
    }

    fn chain(server: &str, owner: &NativeKeypair, nonce: &str, len: usize) -> (Vec<LockLink>, Vec<NewLock>) {
        let first = mint_owner_base(server, 1, owner, Some(nonce), &owner_dev()).unwrap();
        let mut links = vec![first.link.clone()];
        let mut locks = vec![first];
        for _ in 1..len {
            let prev = locks.last().unwrap();
            let next = mint_successor(server, &prev.link, &prev.change, &owner.peer_id(), &owner_dev()).unwrap();
            links.push(next.link.clone());
            locks.push(next);
        }
        (links, locks)
    }

    /// A link as a 0.13 client makes it: no device proof.
    fn bare(mut link: LockLink) -> LockLink {
        link.dev = None;
        link
    }

    #[test]
    fn a_chain_verifies_back_to_the_owner_its_id_names() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, _) = chain(&server, &owner, &nonce, 3);
        assert_eq!(verify_chain(&server, &links, None), Some(owner.peer_id()));
        assert_eq!(verify_chain(&server, &links, Some(&owner.peer_id())), Some(owner.peer_id()));
        assert!(verify_chain(&server, &links, Some(&kp(2).peer_id())).is_none(), "a pin naming someone else");

        let (other_server, _) = genesis(&kp(9));
        assert!(verify_chain(&other_server, &links, None).is_none(), "signed for another server");

        let stranger = kp(3);
        let forged = mint_owner_base(&server, 1, &stranger, Some(&nonce), &owner_dev()).unwrap();
        assert!(verify_chain(&server, &[forged.link], None).is_none(), "an owner the id does not hash from");
    }

    #[test]
    fn a_link_counts_only_signed_by_the_change_key_before_it() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 2);
        let wrong_key = mint_successor(&server, &links[0], &sealed_box::new_secret().unwrap(), &owner.peer_id(), &owner_dev());
        assert!(wrong_key.is_none(), "a key that is not the previous change key signs nothing");

        let mut skipped = mint_successor(&server, &links[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap().link;
        skipped.n += 1;
        assert!(verify_chain(&server, &[links[0].clone(), links[1].clone(), skipped], None).is_none(), "a number skipped");

        let mut swapped = links[1].clone();
        swapped.door = links[0].door.clone();
        assert!(verify_chain(&server, &[links[0].clone(), swapped], None).is_none(), "a door swapped after signing");
        assert!(verify_chain(&server, &links[1..], None).is_none(), "no owner-signed start");
    }

    #[test]
    fn a_broken_device_proof_makes_the_link_a_forgery() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, _) = chain(&server, &owner, &nonce, 2);
        assert_eq!(link_device(&server, &links[0]), Some((owner.peer_id(), owner_dev().peer_id())));
        assert_eq!(link_device(&server, &links[1]), Some((owner.peer_id(), owner_dev().peer_id())));

        let mut lied = links[0].clone();
        lied.dev.as_mut().unwrap().master = kp(6).peer_id();
        assert!(link_device(&server, &lied).is_none(), "an owner-signed link's device names the owner");
        assert!(base_owner(&server, &lied).is_none());
        let mut torn = links[1].clone();
        torn.dev.as_mut().unwrap().device = key_text(&kp(7));
        assert!(link_device(&server, &torn).is_none(), "a proof under another key");
        assert!(verify_chain(&server, &[links[0].clone(), torn], None).is_none(), "is a forgery, never a 0.13 link");
        assert_eq!(verify_chain(&server, &[bare(links[0].clone()), bare(links[1].clone())], None), Some(owner.peer_id()), "no proof at all is a 0.13 chain");
    }

    #[test]
    fn a_self_certifying_base_needs_its_nonce_and_another_id_its_pin() {
        let owner = kp(1);
        let (server, _) = genesis(&owner);
        let no_nonce = mint_owner_base(&server, 1, &owner, None, &owner_dev()).unwrap();
        assert!(base_owner(&server, &no_nonce.link).is_none());

        let legacy = "0123456789abcdef0123456789abcdef";
        let base = mint_owner_base(legacy, 1, &owner, None, &owner_dev()).unwrap();
        assert_eq!(base_owner(legacy, &base.link), Some(owner.peer_id()));
        let squatter = mint_owner_base(legacy, 1, &kp(4), None, &owner_dev()).unwrap();
        assert_eq!(verify_chain(legacy, std::slice::from_ref(&squatter.link), None), Some(kp(4).peer_id()), "anyone can sign for a legacy id");
        assert!(verify_chain(legacy, &[squatter.link], Some(&owner.peer_id())).is_none(), "but the invite's pin names the owner");
        assert_ne!(record_key(legacy, &owner.peer_id()), record_key(legacy, &kp(4).peer_id()), "and the relay keeps them apart");
    }

    #[test]
    fn the_relay_takes_the_first_extension_and_refuses_a_fork() {
        let owner = kp(1);
        let counted = owner_counted(&owner);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 2);
        let stored = relay_put(&server, &[], &links, &counted).expect("a first valid chain");

        let a = mint_successor(&server, &links[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap().link;
        let b = mint_successor(&server, &links[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap().link;
        let stored = relay_put(&server, &stored, std::slice::from_ref(&a), &counted).expect("the first extension");
        assert!(relay_put(&server, &stored, std::slice::from_ref(&b), &counted).is_none(), "a second extension of the same lock");
        let fork = [links.clone(), vec![b]].concat();
        assert!(relay_put(&server, &stored, &fork, &counted).is_none(), "a whole chain ending in the losing extension");
        assert!(relay_put(&server, &[], std::slice::from_ref(&a), &counted).is_none(), "an extension of nothing");
    }

    #[test]
    fn the_owner_resets_a_fork_and_compacts_the_chain() {
        let owner = kp(1);
        let counted = owner_counted(&owner);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 3);
        let stored = relay_put(&server, &[], &links, &counted).unwrap();

        let compact = owner_signed(&server, &links[2], &owner, Some(&nonce), &owner_dev());
        let stored = relay_put(&server, &stored, std::slice::from_ref(&compact), &counted).expect("a shorter chain to the same lock");
        assert_eq!(stored, vec![compact.clone()]);
        let longer = relay_put(&server, &stored, &links, &counted).expect("republishing the old chain is no change");
        assert_eq!(longer, stored, "never grows back");

        let rogue = mint_successor(&server, &compact, &locks[2].change, &kp(6).peer_id(), &mod_dev()).unwrap();
        let stored = relay_put(&server, &stored, std::slice::from_ref(&rogue.link), &counted).unwrap();
        let too_low = mint_owner_base(&server, rogue.link.n, &owner, Some(&nonce), &owner_dev()).unwrap();
        assert!(relay_put(&server, &stored, &[too_low.link], &counted).is_none(), "a reset must pass the newest lock");
        let reset = mint_owner_base(&server, rogue.link.n + 1, &owner, Some(&nonce), &owner_dev()).unwrap();
        let stored = relay_put(&server, &stored, std::slice::from_ref(&reset.link), &counted).expect("the owner's reset");
        assert_eq!(stored, vec![reset.link.clone()]);
        let rogue_next = mint_successor(&server, &rogue.link, &rogue.change, &kp(6).peer_id(), &mod_dev()).unwrap();
        let rogue_chain = [vec![compact.clone()], vec![rogue.link.clone()], vec![rogue_next.link.clone()]].concat();
        assert!(relay_put(&server, &stored, &rogue_chain, &counted).is_none(), "the old fork cannot come back");
        let rogue_past = mint_successor(&server, &rogue_next.link, &rogue_next.change, &kp(6).peer_id(), &mod_dev()).unwrap();
        let longer_fork = vec![compact, rogue.link, rogue_next.link, rogue_past.link];
        assert!(relay_put(&server, &stored, &longer_fork, &counted).is_none(), "not even grown past the reset");

        let impostor = mint_owner_base(&server, 99, &kp(5), Some(&nonce), &owner_dev()).unwrap();
        assert!(relay_put(&server, &stored, &[impostor.link], &counted).is_none(), "only the owner resets");
    }

    #[test]
    fn an_owner_base_needs_a_counted_device() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, _) = chain(&server, &owner, &nonce, 1);
        let counted = owner_counted(&owner);
        let nobody = counting(&[]);
        assert!(relay_put(&server, &[], &links, &counted).is_some(), "a counted owner device's first lock");
        assert!(relay_put(&server, &[], &links, &nobody).is_none(), "no roster held, or one that does not count it");
        assert!(relay_put(&server, &[], &[bare(links[0].clone())], &counted).is_none(), "the master key alone");
        let by_mod = mint_owner_base(&server, 1, &owner, Some(&nonce), &mod_dev()).unwrap();
        assert!(relay_put(&server, &[], &[by_mod.link], &counted).is_none(), "a device of another identity");
        let lied = device_signed(&server, links[0].clone(), &kp(6).peer_id(), &mod_dev());
        assert!(link_device(&server, &lied).is_none() && base_owner(&server, &lied).is_none(), "an owner base's device names the owner");

        let (two, _) = chain(&server, &owner, &nonce, 2);
        let stored = relay_put(&server, &[], &two, &counted).unwrap();
        let reset = mint_owner_base(&server, 3, &owner, Some(&nonce), &owner_dev()).unwrap();
        let removed = counting(&[(&kp(6), &mod_dev())]);
        assert!(relay_put(&server, &stored, std::slice::from_ref(&reset.link), &removed).is_none(), "an owner device removed since");
        let compact = owner_signed(&server, &stored[1], &owner, Some(&nonce), &owner_dev());
        assert!(relay_put(&server, &stored, &[compact], &removed).is_none(), "nor its re-signing of the newest lock");
        assert_eq!(relay_put(&server, &stored, &stored, &removed), Some(stored.clone()), "a chain the relay holds is no new base");
    }

    #[test]
    fn a_reset_jump_past_the_step_is_refused() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let counted = owner_counted(&owner);
        let (links, _) = chain(&server, &owner, &nonce, 2);
        let stored = relay_put(&server, &[], &links, &counted).unwrap();
        let far = mint_owner_base(&server, 2 + RESET_STEP + 1, &owner, Some(&nonce), &owner_dev()).unwrap();
        assert!(relay_put(&server, &stored, &[far.link], &counted).is_none(), "one past the step");
        let ceiling = mint_owner_base(&server, MAX_N, &owner, Some(&nonce), &owner_dev()).unwrap();
        assert!(relay_put(&server, &stored, &[ceiling.link], &counted).is_none(), "the ceiling");
        let edge = mint_owner_base(&server, 2 + RESET_STEP, &owner, Some(&nonce), &owner_dev()).unwrap();
        let stored = relay_put(&server, &stored, std::slice::from_ref(&edge.link), &counted).expect("the step itself");
        let next = mint_successor(&server, &edge.link, &edge.change, &owner.peer_id(), &owner_dev()).unwrap();
        assert!(relay_put(&server, &stored, &[next.link], &counted).is_some(), "and the lock moves on from there");
    }

    /// The review's probe, as the relay now judges it: a master-key holder whose device
    /// the fold no longer counts freezes nothing, and the honest owner keeps moving it.
    #[test]
    fn probe3_a_master_key_holder_freezes_the_relay_lock_at_max_n() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let counted = owner_counted(&owner);
        let (stored, locks) = chain(&server, &owner, &nonce, 2);
        let stored = relay_put(&server, &[], &stored, &counted).unwrap();
        let thief = kp(13);
        for frozen in [
            bare(mint_owner_base(&server, MAX_N, &owner, Some(&nonce), &thief).unwrap().link),
            mint_owner_base(&server, MAX_N, &owner, Some(&nonce), &thief).unwrap().link,
            mint_owner_base(&server, 3, &owner, Some(&nonce), &thief).unwrap().link,
        ] {
            assert!(relay_put(&server, &stored, &[frozen], &counted).is_none(), "the thief's reset is refused");
        }
        let next = mint_successor(&server, &stored[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap();
        assert!(relay_put(&server, &stored, &[next.link], &counted).is_some(), "the honest owner still moves it");
    }

    #[test]
    fn a_frozen_lock_gives_way_to_a_counted_owner_device() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let counted = owner_counted(&owner);
        // What a 0.13 relay could be left holding: a master-key holder's reset at the ceiling.
        let frozen = vec![bare(mint_owner_base(&server, MAX_N, &owner, Some(&nonce), &kp(13)).unwrap().link)];
        let start = mint_owner_base(&server, 1, &owner, Some(&nonce), &owner_dev()).unwrap();
        assert!(relay_put(&server, &frozen, &[bare(start.link.clone())], &counted).is_none(), "not for the master key alone");
        assert!(relay_put(&server, &frozen, std::slice::from_ref(&start.link), &counting(&[])).is_none(), "nor an uncounted device");
        let stored = relay_put(&server, &frozen, std::slice::from_ref(&start.link), &counted).expect("a counted owner device starts over");
        assert_eq!(stored, vec![start.link.clone()]);
        let next = mint_successor(&server, &start.link, &start.change, &owner.peer_id(), &owner_dev()).unwrap();
        assert!(relay_put(&server, &stored, &[next.link], &counted).is_some());
        let below = vec![bare(mint_owner_base(&server, FROZEN_FROM, &owner, Some(&nonce), &kp(13)).unwrap().link)];
        assert!(relay_put(&server, &below, std::slice::from_ref(&start.link), &counted).is_none(), "a lock below the line is not frozen");
    }

    #[test]
    fn a_removed_device_cannot_extend_a_lock_it_holds_the_key_of() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 2);
        let both = owner_counted(&owner);
        let stored = relay_put(&server, &[], &links, &both).unwrap();
        let by_mod = mint_successor(&server, &links[1], &locks[1].change, &kp(6).peer_id(), &mod_dev()).unwrap().link;
        let mod_removed = counting(&[(&owner, &owner_dev())]);
        assert!(relay_put(&server, &stored, std::slice::from_ref(&by_mod), &mod_removed).is_none(), "made by a device the fold no longer counts");
        assert!(relay_put(&server, &stored, &[bare(by_mod.clone())], &mod_removed).is_none(), "or by no device, after a link that names one");
        assert!(relay_put(&server, &stored, std::slice::from_ref(&by_mod), &both).is_some(), "the same link while it counts");

        // A 0.13 chain still moves the 0.13 way.
        let old: Vec<LockLink> = links.iter().cloned().map(bare).collect();
        assert!(relay_put(&server, &[], &old, &both).is_none(), "a 0.13 base is no base on this relay");
        let next = bare(mint_successor(&server, &old[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap().link);
        assert!(relay_put(&server, &old, std::slice::from_ref(&next), &counting(&[])).is_some(), "but a 0.13 link extends a 0.13 one");
    }

    #[test]
    fn a_dead_tip_gives_way_to_a_counted_device_holding_the_lock_before() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 2);
        let both = owner_counted(&owner);
        let stored = relay_put(&server, &[], &links, &both).unwrap();
        // The stolen mod device moves the lock twice while it counts, keeping each change key to itself.
        let dark = mint_successor(&server, &links[1], &locks[1].change, &kp(6).peer_id(), &mod_dev()).unwrap();
        let darker = mint_successor(&server, &dark.link, &dark.change, &kp(6).peer_id(), &mod_dev()).unwrap();
        let stored = relay_put(&server, &stored, &[dark.link.clone(), darker.link.clone()], &both).unwrap();
        let fork = mint_successor(&server, &links[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap().link;
        assert!(relay_put(&server, &stored, std::slice::from_ref(&fork), &both).is_none(), "a live tip is never forked");

        let removed = counting(&[(&owner, &owner_dev())]);
        assert!(relay_put(&server, &stored, &[bare(fork.clone())], &removed).is_none(), "a fork made by no device");
        let stranger = mint_successor(&server, &links[1], &locks[1].change, &kp(8).peer_id(), &kp(18)).unwrap().link;
        assert!(relay_put(&server, &stored, &[stranger], &removed).is_none(), "a fork made by an uncounted device");
        let after = relay_put(&server, &stored, std::slice::from_ref(&fork), &removed).expect("once the fold drops the thief");
        assert_eq!(after, vec![links[0].clone(), links[1].clone(), fork.clone()]);
        let again = mint_successor(&server, &dark.link, &dark.change, &kp(6).peer_id(), &mod_dev()).unwrap().link;
        assert!(relay_put(&server, &after, &[again], &removed).is_none(), "and the thief's branch is gone");

        // A link without a proof is never dead, so nothing replaces one.
        let old: Vec<LockLink> = [links.clone(), vec![dark.link.clone()]].concat().into_iter().map(bare).collect();
        let fork_old = mint_successor(&server, &old[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap().link;
        assert!(relay_put(&server, &old, &[bare(fork_old.clone())], &both).is_none(), "a 0.13 link replaces nothing");
        assert!(relay_put(&server, &old, std::slice::from_ref(&fork_old), &removed).is_none(), "nor does a counted device's");

        // Laundered through an honest member's republish, the thief's link stays its own.
        let republished = relay_put(&server, &[], &[links.clone(), vec![dark.link.clone()]].concat(), &both).unwrap();
        let fork2 = mint_successor(&server, &links[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap().link;
        assert!(relay_put(&server, &republished, &[fork2], &removed).is_some());
    }

    /// Only the owner, or the identity whose removed device made every link it replaces,
    /// forks past a dead link: an older change key alone (an ex-mod's) moves nothing.
    #[test]
    fn a_dead_link_gives_way_only_to_the_owner_or_its_own_identity() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (mod_master, ex, ex_dev, sibling) = (kp(6), kp(8), kp(18), kp(17));
        let (links, locks) = chain(&server, &owner, &nonce, 2);
        let all = counting(&[(&owner, &owner_dev()), (&ex, &ex_dev), (&mod_master, &mod_dev())]);
        let fork_by = |m: &NativeKeypair, d: &NativeKeypair| {
            mint_successor(&server, &links[1], &locks[1].change, &m.peer_id(), d).unwrap().link
        };

        // A 0.13 chain held at the 0.14 deploy: E held L2's change key and was kicked at L3.
        let kick = mint_successor(&server, &links[1], &locks[1].change, &owner.peer_id(), &owner_dev()).unwrap();
        let old: Vec<LockLink> = [links.clone(), vec![kick.link.clone()]].concat().into_iter().map(bare).collect();
        assert!(relay_put(&server, &old, &[fork_by(&ex, &ex_dev)], &all).is_none(), "an ex-mod's counted device does not fork past a 0.13 kick link");
        assert!(relay_put(&server, &old, &[fork_by(&owner, &owner_dev())], &all).is_none(), "nor does the owner's: a 0.13 link is never dead");
        let honest = mint_successor(&server, &kick.link, &kick.change, &mod_master.peer_id(), &mod_dev()).unwrap().link;
        assert!(relay_put(&server, &old, &[honest], &all).is_some(), "an honest mod still moves the lock");

        // A 0.14 chain: mod device md demoted E at L3 and was later removed honestly.
        let stored = relay_put(&server, &[], &links, &all).unwrap();
        let demotion = mint_successor(&server, &links[1], &locks[1].change, &mod_master.peer_id(), &mod_dev()).unwrap();
        let stored = relay_put(&server, &stored, std::slice::from_ref(&demotion.link), &all).unwrap();
        let md_removed = counting(&[(&owner, &owner_dev()), (&ex, &ex_dev), (&mod_master, &sibling)]);
        assert!(relay_put(&server, &stored, &[fork_by(&ex, &ex_dev)], &md_removed).is_none(), "another identity's counted device does not fork past it");
        assert!(relay_put(&server, &stored, &[fork_by(&mod_master, &sibling)], &md_removed).is_some(), "the removed device's sibling does");
        assert!(relay_put(&server, &stored, &[fork_by(&owner, &owner_dev())], &md_removed).is_some(), "and so does the owner's device");

        // Two dead links of two identities after the fork point.
        let by_ex = mint_successor(&server, &demotion.link, &demotion.change, &ex.peer_id(), &ex_dev).unwrap().link;
        let mixed = relay_put(&server, &stored, &[by_ex], &all).unwrap();
        let both_removed = counting(&[(&owner, &owner_dev()), (&mod_master, &sibling)]);
        assert!(relay_put(&server, &mixed, &[fork_by(&mod_master, &sibling)], &both_removed).is_none(), "a sibling replaces no dead link of another identity");
        assert!(relay_put(&server, &mixed, &[fork_by(&owner, &owner_dev())], &both_removed).is_some(), "the owner replaces them all");
    }

    #[test]
    fn grants_open_only_for_a_counted_device() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let lock = mint_owner_base(&server, 1, &owner, Some(&nonce), &owner_dev()).unwrap();
        let mod_master = kp(6);
        let (key, grant) = seal_grant(&server, &lock.link.change, &mod_master.peer_id(), &mod_dev().peer_id(), &lock.change).unwrap();
        assert_eq!(key, grant_key(&mod_master.peer_id(), &mod_dev().peer_id()));
        assert_eq!(grant_holder(&key), mod_master.peer_id());
        assert!(grant_shape(&grant), "{grant}");
        let opened = open_grant(&server, &lock.link.change, &key, &mod_dev(), &grant).expect("the device opens it");
        assert_eq!(*opened, *lock.change);
        assert!(open_grant(&server, &lock.link.change, &key, &mod_master, &grant).is_none(), "the master key opens no device's grant");
        assert!(open_grant(&server, &lock.link.change, &key, &kp(17), &grant).is_none(), "nor a sibling device");
        let as_sibling = grant_key(&mod_master.peer_id(), &kp(17).peer_id());
        assert!(open_grant(&server, &lock.link.change, &as_sibling, &kp(17), &grant).is_none(), "refiled for another device");
        let other = mint_owner_base(&server, 2, &owner, Some(&nonce), &owner_dev()).unwrap();
        assert!(open_grant(&server, &other.link.change, &key, &mod_dev(), &grant).is_none(), "named for another key");
        let (_, lie) = seal_grant(&server, &lock.link.change, &mod_master.peer_id(), &mod_dev().peer_id(), &other.change).unwrap();
        assert!(open_grant(&server, &lock.link.change, &key, &mod_dev(), &lie).is_none(), "a secret that is not the named key");

        let old = seal_master_grant(&server, &lock.link.change, &mod_master.peer_id(), &lock.change).unwrap();
        assert!(open_grant(&server, &lock.link.change, &mod_master.peer_id(), &mod_master, &old).is_some(), "a 0.13 grant opens with the master");
        assert!(open_grant(&server, &lock.link.change, &mod_master.peer_id(), &mod_dev(), &old).is_none());
    }

    /// Two links from fixed keys: the vector `relay-uws/test/test_join_lock.cpp` pins
    /// too, so the relay and the client read the same bytes as the same chain.
    fn pinned_chain(with_devices: bool) -> (String, Vec<LockLink>) {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let base = LockLink {
            n: 1,
            door: sealed_box::key_to_text(&sealed_box::public_of(&[2; 32])),
            change: key_text(&kp(3)),
            sig: String::new(),
            owner: None,
            nonce: None,
            dev: None,
        };
        let mut base = owner_signed(&server, &base, &owner, Some(&nonce), &owner_dev());
        let mut next = LockLink {
            n: 2,
            door: sealed_box::key_to_text(&sealed_box::public_of(&[4; 32])),
            change: key_text(&kp(5)),
            sig: String::new(),
            owner: None,
            nonce: None,
            dev: None,
        };
        next.sig = base64::engine::general_purpose::STANDARD.encode(kp(3).sign(next.payload(&server).as_bytes()));
        if with_devices {
            next = device_signed(&server, next, &kp(6).peer_id(), &mod_dev());
        } else {
            base.dev = None;
        }
        (server, vec![base, next])
    }

    #[test]
    fn a_pinned_chain_verifies_as_the_relay_verifies_it() {
        let (server, links) = pinned_chain(false);
        assert_eq!(server, PINNED_SERVER);
        assert_eq!(serde_json::to_string(&links).unwrap(), PINNED_CHAIN);
        assert_eq!(verify_chain(&server, &links, None), Some(kp(1).peer_id()));
        assert_eq!(kp(1).peer_id(), PINNED_OWNER);
    }

    #[test]
    fn a_pinned_device_chain_verifies_as_the_relay_verifies_it() {
        let (server, links) = pinned_chain(true);
        assert_eq!(serde_json::to_string(&links).unwrap(), PINNED_DEVICE_CHAIN);
        assert_eq!(verify_chain(&server, &links, None), Some(kp(1).peer_id()));
        assert_eq!(link_device(&server, &links[0]), Some((PINNED_OWNER.to_string(), PINNED_OWNER_DEVICE.to_string())));
        assert_eq!(link_device(&server, &links[1]), Some((PINNED_MOD.to_string(), PINNED_MOD_DEVICE.to_string())));
        let counted = owner_counted(&kp(1));
        assert_eq!(relay_put(&server, &[], &links, &counted), Some(links.clone()));
    }

    const PINNED_SERVER: &str = "8ef8bc89d3891dca86ff72c6783e396351aed5ba";
    const PINNED_OWNER: &str = "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5";
    const PINNED_CHAIN: &str = r#"[{"n":1,"door":"zo060cy2M-x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk","change":"CAESIO1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfR","sig":"hADu+IFDBj9pUpXj92etL6dWrmeZk/4DoQUxpU0wDJ5l7GewH8s+CNNfHfAe9OLcJk7lX+AupdjRLD+UexRACA==","owner":"CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c","nonce":"00112233445566778899aabbccddeeff"},{"n":2,"door":"rAGyIJ6GNU-4UyN7XeD0-rE8f8v0M6YcAZNpYX_s8Qs","change":"CAESIG56HN0psLeP0Tr0xVmP7/TvKpcWbjym8uT7/M2AUFvx","sig":"rMKiInifn0Nl07+eV0lMkYk/XXLQRDF8sDT/aqxZSpqmSFspymgQw4MGZJ7VtVbFXNtJ8sbHTdQDcs+Dv1AJCw=="}]"#;
    const PINNED_OWNER_DEVICE: &str = "12D3KooWGjSE7eCu5f1Pa8pGxscmoEcdQ5BRMGqbyMvL2dhrPCS5";
    const PINNED_MOD: &str = "12D3KooWK98A5qKRAA9qZccvoJLvcLu68PCFZLNfdd81iQLvHj6W";
    const PINNED_MOD_DEVICE: &str = "12D3KooWG3t2M63pjiZP7UHsWruK1tQomm9kMsTm4FS3YMTfE6ao";
    const PINNED_DEVICE_CHAIN: &str = r#"[{"n":1,"door":"zo060cy2M-x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk","change":"CAESIO1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfR","sig":"hADu+IFDBj9pUpXj92etL6dWrmeZk/4DoQUxpU0wDJ5l7GewH8s+CNNfHfAe9OLcJk7lX+AupdjRLD+UexRACA==","owner":"CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c","nonce":"00112233445566778899aabbccddeeff","dev":{"device":"CAESIGa+fjMsekUzMr2dCn99sFX1xe8aBq2mbZizn7aBDEc6","master":"12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5","sig":"QSgrTGbw/mbhrOLAw6cM2q06vNldJ9PP2XnvbQ0ra3dF0jzcWD5A1eEpTgBfjtyeWMS8UnLQQK+dfOi5Ru1aAg=="}},{"n":2,"door":"rAGyIJ6GNU-4UyN7XeD0-rE8f8v0M6YcAZNpYX_s8Qs","change":"CAESIG56HN0psLeP0Tr0xVmP7/TvKpcWbjym8uT7/M2AUFvx","sig":"rMKiInifn0Nl07+eV0lMkYk/XXLQRDF8sDT/aqxZSpqmSFspymgQw4MGZJ7VtVbFXNtJ8sbHTdQDcs+Dv1AJCw==","dev":{"device":"CAESIFycbfJhycuEBHV3aq782US0BTKPqyj5s6le9ASQ096E","master":"12D3KooWK98A5qKRAA9qZccvoJLvcLu68PCFZLNfdd81iQLvHj6W","sig":"gi+p/7czh9a7nQyDkdFpcPc6681Jm5RQo9oyVuCpSoLTbP+V81Av9sjC7mqZjfatPW9/ci3xCryPdRnIG5FuAw=="}}]"#;

    #[test]
    fn a_link_is_bounded_before_any_signature_is_read() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let lock = mint_owner_base(&server, 1, &owner, Some(&nonce), &owner_dev()).unwrap();
        let mut long_door = lock.link.clone();
        long_door.door.push('A');
        assert!(!long_door.well_formed());
        let mut huge = lock.link.clone();
        huge.n = MAX_N + 1;
        assert!(!huge.well_formed());
        let mut nonce_on_next = lock.link.clone();
        nonce_on_next.owner = None;
        assert!(!nonce_on_next.well_formed(), "a nonce belongs to an owner-signed link");
        let mut long_master = lock.link.clone();
        long_master.dev.as_mut().unwrap().master.push('A');
        long_master.dev.as_mut().unwrap().master.push_str(&"z".repeat(20));
        assert!(!long_master.well_formed(), "a device proof's master is a peer id");
        let mut odd_master = lock.link.clone();
        odd_master.dev.as_mut().unwrap().master.replace_range(..1, "0");
        assert!(!odd_master.well_formed(), "in base58");
        let mut short_sig = lock.link.clone();
        short_sig.dev.as_mut().unwrap().sig.pop();
        assert!(!short_sig.well_formed());
    }
}
