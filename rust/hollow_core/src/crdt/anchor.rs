//! Self-certifying server ids: the founding owner is provable from the id alone.
//!
//! A server founded on 0.12 or later has an id derived from its founder's master
//! peer id and a random nonce the founding op carries, so a joiner needs to trust no
//! answering member to learn who owns it. Older ids are 32 random hex characters;
//! the 40-character length is what tells the two apart, so an answerer cannot
//! downgrade a new server by leaving the founding op out.

use sha2::{Digest, Sha256};

/// Hex length of a self-certifying id (160 bits of SHA-256).
const GENESIS_ID_LEN: usize = 40;

/// Hex length of a server id minted before 0.12.
const LEGACY_ID_LEN: usize = 32;

/// The id a founder with this nonce must use.
pub(crate) fn derive_server_id(owner_peer_id: &str, nonce: &str) -> String {
    let digest = Sha256::digest(format!("hollow-server1:{owner_peer_id}:{nonce}").as_bytes());
    hex::encode(digest)[..GENESIS_ID_LEN].to_string()
}

/// Whether `server_id` has the self-certifying shape, which obliges its founding op
/// to hash to it.
pub(crate) fn is_genesis_id(server_id: &str) -> bool {
    server_id.len() == GENESIS_ID_LEN && lowercase_hex(server_id)
}

fn lowercase_hex(s: &str) -> bool {
    s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Whether `server_id` has the shape of any server's id, self-certifying or legacy
/// (the relay's `is_server_id_shape`): `S#chan` would alias a channel's MLS subgroup
/// and `conf:` a meeting, so nothing else names a server's room, state or group.
pub(crate) fn valid_server_id(server_id: &str) -> bool {
    is_genesis_id(server_id) || (server_id.len() == LEGACY_ID_LEN && lowercase_hex(server_id))
}

/// A fresh founding nonce (16 random bytes, hex).
pub(crate) fn new_nonce() -> String {
    let mut buf = [0u8; 16];
    getrandom::fill(&mut buf).expect("system RNG unavailable, cannot found a server");
    hex::encode(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derived_ids_have_the_genesis_shape_and_bind_owner_and_nonce() {
        let id = derive_server_id("owner", "n1");
        assert!(is_genesis_id(&id));
        assert_ne!(id, derive_server_id("other", "n1"), "the owner is bound");
        assert_ne!(id, derive_server_id("owner", "n2"), "the nonce is bound");
        assert!(!is_genesis_id(&"a".repeat(32)), "legacy ids are 32 hex characters");
        assert!(!is_genesis_id(&"A".repeat(40)), "only lowercase hex");
    }

    #[test]
    fn a_server_id_is_32_or_40_lowercase_hex() {
        assert!(valid_server_id(&"5e1f".repeat(8)), "a legacy id");
        assert!(valid_server_id(&derive_server_id("owner", "n1")), "a self-certifying id");
        let hex = "ab".repeat(20);
        for id in [
            "AB".repeat(16), "AB".repeat(20), "ab".repeat(18), hex[..31].to_string(),
            format!("{}#x", &hex[..32]), format!("{hex}#x"), format!("conf:{hex}"),
            format!("inbox:{}", &hex[..32]), "s1".to_string(), String::new(),
        ] {
            assert!(!valid_server_id(&id), "{id:?} is no server id");
        }
    }
}
