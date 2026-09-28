//! DM room names only the two parties can compute (claim C-24, I4).
//!
//! A name hashed from the two public master ids let anyone who knew both find the
//! room, read its roster and see whenever either person came online. The name is now
//! keyed by an X25519 agreement between the two MASTER keys, which every device of
//! both identities holds and nobody else does.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, RwLock};

use hmac::{Hmac, Mac};
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::identity::native_identity::NativeKeypair;

const ROOM_DOMAIN: &[u8] = b"hollow-dm-room1";

/// The master keys this process speaks for, by master peer id. Several in the test
/// harness, where every node shares one process.
static LOCAL_MASTERS: LazyLock<RwLock<HashMap<String, Zeroizing<[u8; 32]>>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

/// Derived names, by sorted pair: presence events ask for the same pair many times.
static ROOMS: LazyLock<Mutex<HashMap<(String, String), String>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
const ROOM_CACHE_CAP: usize = 4096;

/// Make `master` a local identity whose DM rooms this process can name. Called
/// wherever the master key is loaded to talk to the relay.
pub(crate) fn register(master: &NativeKeypair) {
    LOCAL_MASTERS
        .write()
        .unwrap_or_else(|p| p.into_inner())
        .insert(master.peer_id(), master.x25519_scalar_bytes());
}

/// The relay room for the DM between two MASTER ids. The same on both sides and on
/// every device of either, and it needs the key of one of them.
///
/// Callers pass masters, never devices: per-peer resolver state can diverge, so a
/// device-keyed name would differ between the two ends.
pub(crate) fn dm_room_code(peer_a: &str, peer_b: &str) -> String {
    let pair = if peer_a <= peer_b {
        (peer_a.to_string(), peer_b.to_string())
    } else {
        (peer_b.to_string(), peer_a.to_string())
    };
    if let Some(room) = ROOMS.lock().unwrap_or_else(|p| p.into_inner()).get(&pair) {
        return room.clone();
    }
    let derived = {
        let masters = LOCAL_MASTERS.read().unwrap_or_else(|p| p.into_inner());
        match (masters.get(&pair.0), masters.get(&pair.1)) {
            (Some(scalar), _) => derive(scalar, &pair.1, &pair),
            (None, Some(scalar)) => derive(scalar, &pair.0, &pair),
            (None, None) => None,
        }
    };
    let Some(room) = derived else {
        // Never a name anyone else could compute: a DM that cannot route beats one
        // whose room a stranger can find.
        hollow_log!("[HOLLOW-SECURITY] No DM room for {} / {}: not a local identity or not an Ed25519 id", pair.0, pair.1);
        return unroutable(&pair);
    };
    let mut rooms = ROOMS.lock().unwrap_or_else(|p| p.into_inner());
    if rooms.len() >= ROOM_CACHE_CAP {
        rooms.clear();
    }
    rooms.insert(pair, room.clone());
    room
}

/// A secret only the two MASTER identities can compute, one per `domain`. `None`
/// when `local_master` is not an identity this process holds the key of.
pub(crate) fn pair_key(local_master: &str, other_master: &str, domain: &[u8]) -> Option<Zeroizing<[u8; 32]>> {
    let pair = if local_master <= other_master {
        (local_master.to_string(), other_master.to_string())
    } else {
        (other_master.to_string(), local_master.to_string())
    };
    let masters = LOCAL_MASTERS.read().unwrap_or_else(|p| p.into_inner());
    agreement(masters.get(local_master)?, other_master, &pair, domain)
}

/// `hex(HMAC-SHA256(X25519(ours, theirs), domain | lo | hi))[..16 bytes]`, or `None`
/// for an id that carries no usable key.
fn derive(our_scalar: &[u8; 32], their_id: &str, pair: &(String, String)) -> Option<String> {
    agreement(our_scalar, their_id, pair, ROOM_DOMAIN).map(|key| hex::encode(&key[..16]))
}

/// `HMAC-SHA256(X25519(ours, theirs), domain | lo | hi)`.
fn agreement(our_scalar: &[u8; 32], their_id: &str, pair: &(String, String), domain: &[u8]) -> Option<Zeroizing<[u8; 32]>> {
    let their_pk = crate::crypto::safety_number::pubkey_from_peer_id(their_id)?;
    let their_point = ed25519_dalek::VerifyingKey::from_bytes(&their_pk).ok()?.to_montgomery();
    let shared = Zeroizing::new(their_point.mul_clamped(*our_scalar).to_bytes());
    // A small-order key agrees on zero with everyone: that secret would be public.
    if shared.iter().fold(0u8, |acc, b| acc | b) == 0 {
        return None;
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(shared.as_slice()).ok()?;
    mac.update(domain);
    for id in [&pair.0, &pair.1] {
        mac.update(&[0]);
        mac.update(id.as_bytes());
    }
    Some(Zeroizing::new(mac.finalize().into_bytes().into()))
}

/// A room name keyed by this process's own random secret: stable for the pair within
/// the process, never shared with anyone.
fn unroutable(pair: &(String, String)) -> String {
    static SECRET: LazyLock<[u8; 32]> = LazyLock::new(|| {
        let mut s = [0u8; 32];
        let _ = getrandom::fill(&mut s);
        s
    });
    let mut mac = Hmac::<Sha256>::new_from_slice(SECRET.as_slice()).expect("HMAC takes any key");
    mac.update(pair.0.as_bytes());
    mac.update(&[0]);
    mac.update(pair.1.as_bytes());
    hex::encode(&mac.finalize().into_bytes()[..16])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keypair(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn sorted(a: &str, b: &str) -> (String, String) {
        if a <= b { (a.into(), b.into()) } else { (b.into(), a.into()) }
    }

    fn from_side(ours: &NativeKeypair, theirs: &str) -> Option<String> {
        derive(&ours.x25519_scalar_bytes(), theirs, &sorted(&ours.peer_id(), theirs))
    }

    /// The room a hash of the two public ids used to give, which anyone could compute.
    fn public_name(a: &str, b: &str) -> String {
        use sha2::Digest;
        let (lo, hi) = sorted(a, b);
        hex::encode(&Sha256::digest(format!("dm-{lo}-{hi}").as_bytes())[..16])
    }

    #[test]
    fn both_ends_derive_the_same_room() {
        let (a, b) = (keypair(1), keypair(2));
        let from_a = from_side(&a, &b.peer_id()).expect("a derives");
        let from_b = from_side(&b, &a.peer_id()).expect("b derives");
        assert_eq!(from_a, from_b);
        assert_eq!(from_a.len(), 32, "the relay's room shape is unchanged");
    }

    #[test]
    fn the_room_is_not_computable_from_the_public_ids() {
        let (a, b, c) = (keypair(3), keypair(4), keypair(5));
        let room = from_side(&a, &b.peer_id()).unwrap();
        assert_ne!(room, public_name(&a.peer_id(), &b.peer_id()));
        assert_ne!(room, from_side(&c, &b.peer_id()).unwrap(), "a third key finds another room");
        assert_ne!(room, from_side(&a, &c.peer_id()).unwrap());
    }

    #[test]
    fn saved_messages_get_a_room_of_their_own() {
        let a = keypair(6);
        let own = from_side(&a, &a.peer_id()).expect("self-DM derives");
        assert_ne!(own, public_name(&a.peer_id(), &a.peer_id()));
    }

    #[test]
    fn a_small_order_key_names_no_room() {
        // The Ed25519 identity point: every agreement with it is zero.
        let mut identity_point = [0u8; 32];
        identity_point[0] = 1;
        let mut proto = vec![0x00, 0x24, 0x08, 0x01, 0x12, 0x20];
        proto.extend_from_slice(&identity_point);
        let weak_id = bs58::encode(&proto).with_alphabet(bs58::Alphabet::BITCOIN).into_string();
        assert_eq!(from_side(&keypair(7), &weak_id), None);
    }

    #[test]
    fn a_registered_side_answers_for_either_argument_order() {
        let (a, b) = (keypair(8), keypair(9));
        register(&a);
        let room = dm_room_code(&a.peer_id(), &b.peer_id());
        assert_eq!(room, dm_room_code(&b.peer_id(), &a.peer_id()));
        assert_eq!(Some(room), from_side(&b, &a.peer_id()), "the unregistered side agrees");
    }

    #[test]
    fn a_pair_key_agrees_across_the_pair_and_differs_by_domain() {
        let (a, b, c) = (keypair(12), keypair(13), keypair(14));
        register(&a);
        register(&b);
        let ab = pair_key(&a.peer_id(), &b.peer_id(), b"test-domain").expect("a holds its key");
        let ba = pair_key(&b.peer_id(), &a.peer_id(), b"test-domain").expect("b holds its key");
        assert_eq!(*ab, *ba);
        assert_ne!(*ab, *pair_key(&a.peer_id(), &b.peer_id(), b"other-domain").unwrap());
        assert_ne!(*ab, *pair_key(&a.peer_id(), &c.peer_id(), b"test-domain").unwrap());
        assert!(pair_key(&c.peer_id(), &a.peer_id(), b"test-domain").is_none(), "no key, no secret");
    }

    #[test]
    fn with_no_local_key_the_room_is_nobody_elses() {
        let (a, b) = (keypair(10), keypair(11));
        let room = dm_room_code(&a.peer_id(), &b.peer_id());
        assert_ne!(Some(room.clone()), from_side(&a, &b.peer_id()));
        assert_ne!(room, public_name(&a.peer_id(), &b.peer_id()));
    }
}
