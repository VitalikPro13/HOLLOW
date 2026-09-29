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
const MAX_N: u64 = (1 << 53) - 1;

const LINK_DOMAIN: &str = "hollow-lock1";
const GRANT_DOMAIN: &[u8] = b"hollow-lock-grant1";

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
    }
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
    signed_by(owner_key, &link.payload(server_id), &link.sig).then_some(owner)
}

/// Whether `next` is a successor `prev`'s change key signed.
pub fn extends(server_id: &str, prev: &LockLink, next: &LockLink) -> bool {
    !next.is_base()
        && next.well_formed()
        && prev.n.checked_add(1) == Some(next.n)
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
/// holds afterwards, or `None` when it refuses. First valid extension wins; an
/// owner-signed link past the newest resets a fork; a shorter chain ending in the
/// same lock compacts it.
#[cfg(test)]
pub fn relay_put(server_id: &str, stored: &[LockLink], submitted: &[LockLink]) -> Option<Vec<LockLink>> {
    let first = submitted.first()?;
    if !first.is_base() {
        let tip = stored.last()?;
        let mut prev = tip;
        for link in submitted {
            if !extends(server_id, prev, link) {
                return None;
            }
            prev = link;
        }
        if stored.len() + submitted.len() > MAX_CHAIN {
            return None;
        }
        return Some([stored, submitted].concat());
    }
    let owner = verify_chain(server_id, submitted, None)?;
    let Some(tip) = stored.last() else { return Some(submitted.to_vec()) };
    if stored.first().and_then(|b| base_owner(server_id, b)).as_deref() != Some(owner.as_str()) {
        return None;
    }
    let newest = submitted.last()?;
    if newest.n > tip.n {
        let continues = submitted.iter().any(|l| l.same_lock(tip));
        let reset = submitted.iter().rev().find(|l| l.is_base()).is_some_and(|b| b.n > tip.n);
        return (continues || reset).then(|| submitted.to_vec());
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

/// Sign `link` as the owner, keeping its number and keys.
pub(crate) fn owner_signed(server_id: &str, link: &LockLink, owner: &NativeKeypair, nonce: Option<&str>) -> LockLink {
    let mut base = LockLink {
        owner: Some(key_text(owner)),
        nonce: nonce.filter(|_| crate::crdt::anchor::is_genesis_id(server_id)).map(str::to_string),
        sig: String::new(),
        ..link.clone()
    };
    base.sig = base64::engine::general_purpose::STANDARD.encode(owner.sign(base.payload(server_id).as_bytes()));
    base
}

/// A new lock the owner signs: the first one, or a reset past a fork.
pub(crate) fn mint_base(server_id: &str, n: u64, owner: &NativeKeypair, nonce: Option<&str>) -> Option<NewLock> {
    let mut lock = fresh(n)?;
    lock.link = owner_signed(server_id, &lock.link, owner, nonce);
    Some(lock)
}

/// The lock after `prev`, signed with `prev`'s change key.
pub(crate) fn mint_next(server_id: &str, prev: &LockLink, prev_change: &[u8; 32]) -> Option<NewLock> {
    let signer = NativeKeypair::from_secret_bytes(prev_change);
    if key_text(&signer) != prev.change {
        return None;
    }
    let mut lock = fresh(prev.n.checked_add(1).filter(|n| *n <= MAX_N)?)?;
    lock.link.sig = base64::engine::general_purpose::STANDARD.encode(signer.sign(lock.link.payload(server_id).as_bytes()));
    Some(lock)
}

/// The X25519 public key of a master identity, which every device of it can use.
fn master_x25519(master: &str) -> Option<[u8; 32]> {
    let ed = crate::crypto::safety_number::pubkey_from_peer_id(master)?;
    Some(ed25519_dalek::VerifyingKey::from_bytes(&ed).ok()?.to_montgomery().to_bytes())
}

fn grant_aad(server_id: &str, change: &str, master: &str) -> Vec<u8> {
    [server_id.as_bytes(), b"\0", change.as_bytes(), b"\0", master.as_bytes()].concat()
}

/// A change key sealed to one owner, admin or mod, by master id.
pub(crate) fn seal_grant(server_id: &str, change: &str, master: &str, change_secret: &[u8; 32]) -> Option<String> {
    let sealed = sealed_box::seal(&master_x25519(master)?, GRANT_DOMAIN, &grant_aad(server_id, change, master), change_secret)?;
    Some(format!("{}.{}", sealed.eph, sealed.ct))
}

/// The change key a grant holds for us, when it opens and is the key it names.
pub(crate) fn open_grant(server_id: &str, change: &str, master: &NativeKeypair, grant: &str) -> Option<Zeroizing<[u8; 32]>> {
    let (eph, ct) = grant.split_once('.')?;
    let aad = grant_aad(server_id, change, &master.peer_id());
    let plain = Zeroizing::new(sealed_box::open(&master.x25519_scalar_bytes(), GRANT_DOMAIN, &aad, eph, ct)?);
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

    /// A self-certifying server of `owner`, with its founding nonce.
    fn genesis(owner: &NativeKeypair) -> (String, String) {
        let nonce = "00112233445566778899aabbccddeeff".to_string();
        (crate::crdt::anchor::derive_server_id(&owner.peer_id(), &nonce), nonce)
    }

    fn chain(server: &str, owner: &NativeKeypair, nonce: &str, len: usize) -> (Vec<LockLink>, Vec<NewLock>) {
        let first = mint_base(server, 1, owner, Some(nonce)).unwrap();
        let mut links = vec![first.link.clone()];
        let mut locks = vec![first];
        for _ in 1..len {
            let prev = locks.last().unwrap();
            let next = mint_next(server, &prev.link, &prev.change).unwrap();
            links.push(next.link.clone());
            locks.push(next);
        }
        (links, locks)
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
        let forged = mint_base(&server, 1, &stranger, Some(&nonce)).unwrap();
        assert!(verify_chain(&server, &[forged.link], None).is_none(), "an owner the id does not hash from");
    }

    #[test]
    fn a_link_counts_only_signed_by_the_change_key_before_it() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 2);
        let wrong_key = mint_next(&server, &links[0], &sealed_box::new_secret().unwrap());
        assert!(wrong_key.is_none(), "a key that is not the previous change key signs nothing");

        let mut skipped = mint_next(&server, &links[1], &locks[1].change).unwrap().link;
        skipped.n += 1;
        assert!(verify_chain(&server, &[links[0].clone(), links[1].clone(), skipped], None).is_none(), "a number skipped");

        let mut swapped = links[1].clone();
        swapped.door = links[0].door.clone();
        assert!(verify_chain(&server, &[links[0].clone(), swapped], None).is_none(), "a door swapped after signing");
        assert!(verify_chain(&server, &links[1..], None).is_none(), "no owner-signed start");
    }

    #[test]
    fn a_self_certifying_base_needs_its_nonce_and_another_id_its_pin() {
        let owner = kp(1);
        let (server, _) = genesis(&owner);
        let no_nonce = mint_base(&server, 1, &owner, None).unwrap();
        assert!(base_owner(&server, &no_nonce.link).is_none());

        let legacy = "0123456789abcdef0123456789abcdef";
        let base = mint_base(legacy, 1, &owner, None).unwrap();
        assert_eq!(base_owner(legacy, &base.link), Some(owner.peer_id()));
        let squatter = mint_base(legacy, 1, &kp(4), None).unwrap();
        assert_eq!(verify_chain(legacy, std::slice::from_ref(&squatter.link), None), Some(kp(4).peer_id()), "anyone can sign for a legacy id");
        assert!(verify_chain(legacy, &[squatter.link], Some(&owner.peer_id())).is_none(), "but the invite's pin names the owner");
        assert_ne!(record_key(legacy, &owner.peer_id()), record_key(legacy, &kp(4).peer_id()), "and the relay keeps them apart");
    }

    #[test]
    fn the_relay_takes_the_first_extension_and_refuses_a_fork() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 2);
        let stored = relay_put(&server, &[], &links).expect("a first valid chain");

        let a = mint_next(&server, &links[1], &locks[1].change).unwrap().link;
        let b = mint_next(&server, &links[1], &locks[1].change).unwrap().link;
        let stored = relay_put(&server, &stored, std::slice::from_ref(&a)).expect("the first extension");
        assert!(relay_put(&server, &stored, std::slice::from_ref(&b)).is_none(), "a second extension of the same lock");
        let fork = [links.clone(), vec![b]].concat();
        assert!(relay_put(&server, &stored, &fork).is_none(), "a whole chain ending in the losing extension");
        assert!(relay_put(&server, &[], std::slice::from_ref(&a)).is_none(), "an extension of nothing");
    }

    #[test]
    fn the_owner_resets_a_fork_and_compacts_the_chain() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let (links, locks) = chain(&server, &owner, &nonce, 3);
        let stored = relay_put(&server, &[], &links).unwrap();

        let compact = owner_signed(&server, &links[2], &owner, Some(&nonce));
        let stored = relay_put(&server, &stored, std::slice::from_ref(&compact)).expect("a shorter chain to the same lock");
        assert_eq!(stored, vec![compact.clone()]);
        let longer = relay_put(&server, &stored, &links).expect("republishing the old chain is no change");
        assert_eq!(longer, stored, "never grows back");

        let rogue = mint_next(&server, &compact, &locks[2].change).unwrap();
        let stored = relay_put(&server, &stored, std::slice::from_ref(&rogue.link)).unwrap();
        let too_low = mint_base(&server, rogue.link.n, &owner, Some(&nonce)).unwrap();
        assert!(relay_put(&server, &stored, &[too_low.link]).is_none(), "a reset must pass the newest lock");
        let reset = mint_base(&server, rogue.link.n + 1, &owner, Some(&nonce)).unwrap();
        let stored = relay_put(&server, &stored, std::slice::from_ref(&reset.link)).expect("the owner's reset");
        assert_eq!(stored, vec![reset.link.clone()]);
        let rogue_next = mint_next(&server, &rogue.link, &rogue.change).unwrap();
        let rogue_chain = [vec![compact.clone()], vec![rogue.link.clone()], vec![rogue_next.link.clone()]].concat();
        assert!(relay_put(&server, &stored, &rogue_chain).is_none(), "the old fork cannot come back");
        let rogue_past = mint_next(&server, &rogue_next.link, &rogue_next.change).unwrap();
        let longer_fork = vec![compact, rogue.link, rogue_next.link, rogue_past.link];
        assert!(relay_put(&server, &stored, &longer_fork).is_none(), "not even grown past the reset");

        let impostor = mint_base(&server, 99, &kp(5), Some(&nonce)).unwrap();
        assert!(relay_put(&server, &stored, &[impostor.link]).is_none(), "only the owner resets");
    }

    #[test]
    fn a_grant_opens_only_for_its_master_and_only_as_the_key_it_names() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let lock = mint_base(&server, 1, &owner, Some(&nonce)).unwrap();
        let mod_kp = kp(6);
        let grant = seal_grant(&server, &lock.link.change, &mod_kp.peer_id(), &lock.change).unwrap();
        assert!(grant_shape(&grant), "{grant}");
        let opened = open_grant(&server, &lock.link.change, &mod_kp, &grant).expect("the mod opens it");
        assert_eq!(*opened, *lock.change);
        assert!(open_grant(&server, &lock.link.change, &kp(7), &grant).is_none(), "another member");
        let other = mint_base(&server, 2, &owner, Some(&nonce)).unwrap();
        assert!(open_grant(&server, &other.link.change, &mod_kp, &grant).is_none(), "named for another key");
        let lie = seal_grant(&server, &lock.link.change, &mod_kp.peer_id(), &other.change).unwrap();
        assert!(open_grant(&server, &lock.link.change, &mod_kp, &lie).is_none(), "a secret that is not the named key");
    }

    /// Two links from fixed keys: the vector `relay-uws/test/test_join_lock.cpp` pins
    /// too, so the relay and the client read the same bytes as the same chain.
    fn pinned_chain() -> (String, Vec<LockLink>) {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let base = LockLink {
            n: 1,
            door: sealed_box::key_to_text(&sealed_box::public_of(&[2; 32])),
            change: key_text(&kp(3)),
            sig: String::new(),
            owner: None,
            nonce: None,
        };
        let base = owner_signed(&server, &base, &owner, Some(&nonce));
        let mut next = LockLink {
            n: 2,
            door: sealed_box::key_to_text(&sealed_box::public_of(&[4; 32])),
            change: key_text(&kp(5)),
            sig: String::new(),
            owner: None,
            nonce: None,
        };
        next.sig = base64::engine::general_purpose::STANDARD.encode(kp(3).sign(next.payload(&server).as_bytes()));
        (server, vec![base, next])
    }

    #[test]
    fn a_pinned_chain_verifies_as_the_relay_verifies_it() {
        let (server, links) = pinned_chain();
        assert_eq!(server, PINNED_SERVER);
        assert_eq!(serde_json::to_string(&links).unwrap(), PINNED_CHAIN);
        assert_eq!(verify_chain(&server, &links, None), Some(kp(1).peer_id()));
        assert_eq!(kp(1).peer_id(), PINNED_OWNER);
    }

    const PINNED_SERVER: &str = "8ef8bc89d3891dca86ff72c6783e396351aed5ba";
    const PINNED_OWNER: &str = "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5";
    const PINNED_CHAIN: &str = r#"[{"n":1,"door":"zo060cy2M-x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk","change":"CAESIO1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfR","sig":"hADu+IFDBj9pUpXj92etL6dWrmeZk/4DoQUxpU0wDJ5l7GewH8s+CNNfHfAe9OLcJk7lX+AupdjRLD+UexRACA==","owner":"CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c","nonce":"00112233445566778899aabbccddeeff"},{"n":2,"door":"rAGyIJ6GNU-4UyN7XeD0-rE8f8v0M6YcAZNpYX_s8Qs","change":"CAESIG56HN0psLeP0Tr0xVmP7/TvKpcWbjym8uT7/M2AUFvx","sig":"rMKiInifn0Nl07+eV0lMkYk/XXLQRDF8sDT/aqxZSpqmSFspymgQw4MGZJ7VtVbFXNtJ8sbHTdQDcs+Dv1AJCw=="}]"#;

    #[test]
    fn a_link_is_bounded_before_any_signature_is_read() {
        let owner = kp(1);
        let (server, nonce) = genesis(&owner);
        let lock = mint_base(&server, 1, &owner, Some(&nonce)).unwrap();
        let mut long_door = lock.link.clone();
        long_door.door.push('A');
        assert!(!long_door.well_formed());
        let mut huge = lock.link.clone();
        huge.n = MAX_N + 1;
        assert!(!huge.well_formed());
        let mut nonce_on_next = lock.link.clone();
        nonce_on_next.owner = None;
        assert!(!nonce_on_next.well_formed(), "a nonce belongs to an owner-signed link");
    }
}
