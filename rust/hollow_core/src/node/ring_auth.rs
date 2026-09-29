//! Who may change a server's catch-up rings on the relay: whoever holds the change
//! key of the server's newest join lock (`join_lock`), which is its owner, admins
//! and mods. Anyone in the server's room could before, so a stranger with the id
//! could stretch retention to a week or stop the rings every late joiner and parked
//! join depends on. The relay's side is relay-uws/src/ring_auth.h; the payload is
//! pinned in both.
//!
//! A legacy (32-hex) id names no owner, so anyone may file a lock under one in its
//! own name. Its ring topics therefore carry the owner (`ring_topic`), and the relay
//! lets a control touch only the topics of the owner it is signed for.

use base64::Engine;

use super::join_lock::LockLink;
use crate::identity::native_identity::NativeKeypair;

/// The signature a `set_topic_buffer` carries, and the lock record it names.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct RingAuth {
    /// The server's owner: keys a legacy id's lock record on the relay.
    pub owner: String,
    pub ts_ms: i64,
    pub sig: String,
}

/// The relay topic a server channel's frames ride: the channel id, and for a legacy
/// id the owner in front, so rings filed under the id in someone else's name never
/// meet the real ones.
pub(crate) fn ring_topic(server_id: &str, owner: Option<&str>, channel: &str) -> String {
    match owner {
        Some(owner) if !crate::crdt::anchor::is_genesis_id(server_id) => format!("{owner}.{channel}"),
        _ => channel.to_string(),
    }
}

/// `ring_topic` for a server we hold.
pub(crate) fn topic(state: &crate::crdt::server_state::ServerState, channel: &str) -> String {
    ring_topic(&state.server_id, state.anchor_owner().as_deref(), channel)
}

/// The exact bytes a ring control signs.
pub(crate) fn payload(room: &str, owner: &str, ts_ms: i64, retention_secs: i64, clear: bool, channels: &[String]) -> String {
    let mut p = format!(
        "hollow-ring1\n{room}\n{owner}\n{ts_ms}\n{retention_secs}\n{}",
        if clear { "clear" } else { "keep" }
    );
    for c in channels {
        p.push('\n');
        p.push_str(c);
    }
    p
}

/// A control signed with the change key of `link`, when `change_secret` is that key.
pub(crate) fn sign(
    room: &str,
    owner: &str,
    retention_secs: i64,
    clear: bool,
    channels: &[String],
    link: &LockLink,
    change_secret: &[u8; 32],
) -> Option<RingAuth> {
    let signer = NativeKeypair::from_secret_bytes(change_secret);
    if base64::engine::general_purpose::STANDARD.encode(signer.public_key_protobuf()) != link.change {
        return None;
    }
    let ts_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default();
    let bytes = payload(room, owner, ts_ms, retention_secs, clear, channels);
    Some(RingAuth {
        owner: owner.to_string(),
        ts_ms,
        sig: base64::engine::general_purpose::STANDARD.encode(signer.sign(bytes.as_bytes())),
    })
}

/// The relay's rule (`ring_auth::authorized`): fresh within ten minutes, every
/// channel newline-free and inside its owner's topics, signed by the change key of
/// the newest link it holds.
#[cfg(test)]
pub(crate) fn relay_accepts(
    room: &str,
    auth: &RingAuth,
    retention_secs: i64,
    clear: bool,
    channels: &[String],
    chain: &[LockLink],
    now_ms: i64,
) -> bool {
    const MAX_SKEW_MS: i64 = 10 * 60 * 1000;
    let Some(tip) = chain.last() else { return false };
    if auth.ts_ms <= 0 || (now_ms - auth.ts_ms).abs() > MAX_SKEW_MS {
        return false;
    }
    let shaped = |c: &String| {
        !c.is_empty() && c.len() <= 128 && c.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_~.".contains(&b))
    };
    if !channels.iter().all(shaped) {
        return false;
    }
    let prefix = ring_topic(room, Some(&auth.owner), "");
    if !channels.iter().all(|c| c.len() > prefix.len() && c.starts_with(&prefix)) {
        return false;
    }
    let (Ok(key), Ok(sig)) = (
        base64::engine::general_purpose::STANDARD.decode(&tip.change),
        base64::engine::general_purpose::STANDARD.decode(&auth.sig),
    ) else {
        return false;
    };
    let bytes = payload(room, &auth.owner, auth.ts_ms, retention_secs, clear, channels);
    NativeKeypair::verify_peer_signature(&key, &sig, bytes.as_bytes()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pinned against relay-uws/test/test_ring_auth.cpp.
    #[test]
    fn ring_control_payload_matches_the_relays_pinned_vector() {
        let channels = vec!["3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b".to_string(), "~join".to_string()];
        assert_eq!(
            payload("0123456789abcdef0123456789abcdef01234567", "", 1790000000000, 86400, false, &channels),
            "hollow-ring1\n0123456789abcdef0123456789abcdef01234567\n\n1790000000000\n86400\nkeep\n\
             3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b\n~join"
        );
    }

    #[test]
    fn only_the_newest_locks_change_key_signs_ring_control() {
        let server = "0123456789abcdef0123456789abcdef01234567";
        let owner = NativeKeypair::from_secret_bytes(&[7; 32]);
        let first = super::super::join_lock::mint_base(server, 1, &owner, Some("00")).unwrap();
        let second = super::super::join_lock::mint_next(server, &first.link, &first.change).unwrap();
        let chain = vec![first.link.clone(), second.link.clone()];
        let channels = vec!["general".to_string(), "~join".to_string()];

        let auth = sign(server, "", 3600, false, &channels, &second.link, &second.change).unwrap();
        let now = auth.ts_ms;
        assert!(relay_accepts(server, &auth, 3600, false, &channels, &chain, now));
        assert!(!relay_accepts(server, &auth, 7 * 86400, false, &channels, &chain, now), "retention is signed");
        assert!(!relay_accepts(server, &auth, 3600, true, &channels, &chain, now), "clear is signed");
        assert!(!relay_accepts(server, &auth, 3600, false, &channels[..1], &chain, now), "channels are signed");
        assert!(!relay_accepts(server, &auth, 3600, false, &channels, &chain[..1], now), "an older lock's key does not match");
        assert!(!relay_accepts(server, &auth, 3600, false, &channels, &chain, now + 11 * 60 * 1000), "stale");

        let stale_key = sign(server, "", 3600, false, &channels, &first.link, &first.change).unwrap();
        assert!(!relay_accepts(server, &stale_key, 3600, false, &channels, &chain, now), "a moved lock's key no longer counts");
        assert!(sign(server, "", 3600, false, &channels, &second.link, &first.change).is_none(), "a key that is not the link's");
    }

    /// Pinned against relay-uws/test/test_ring_auth.cpp (`topic_prefix`).
    #[test]
    fn a_legacy_servers_topics_carry_its_owner() {
        let genesis = "0123456789abcdef0123456789abcdef01234567";
        let legacy = "0123456789abcdef0123456789abcdef";
        assert_eq!(ring_topic(genesis, Some("12D3KooWOwner"), "general"), "general");
        assert_eq!(ring_topic(legacy, Some("12D3KooWOwner"), "general"), "12D3KooWOwner.general");
        assert_eq!(ring_topic(legacy, None, "~join"), "~join", "no owner known, no prefix");
    }

    #[test]
    fn a_legacy_control_reaches_only_its_owners_topics() {
        let server = "0123456789abcdef0123456789abcdef";
        let owner = NativeKeypair::from_secret_bytes(&[8; 32]);
        let owner_id = owner.peer_id();
        let lock = super::super::join_lock::mint_base(server, 1, &owner, None).unwrap();
        let chain = vec![lock.link.clone()];
        let own = vec![ring_topic(server, Some(&owner_id), "general")];
        let auth = sign(server, &owner_id, 3600, false, &own, &lock.link, &lock.change).unwrap();
        assert!(relay_accepts(server, &auth, 3600, false, &own, &chain, auth.ts_ms));

        let plain = vec!["general".to_string()];
        let auth = sign(server, &owner_id, 3600, false, &plain, &lock.link, &lock.change).unwrap();
        assert!(!relay_accepts(server, &auth, 3600, false, &plain, &chain, auth.ts_ms), "a plain channel id");

        let other = vec![ring_topic(server, Some("12D3KooWSomeoneElse"), "general")];
        let auth = sign(server, &owner_id, 3600, false, &other, &lock.link, &lock.change).unwrap();
        assert!(!relay_accepts(server, &auth, 3600, false, &other, &chain, auth.ts_ms), "another owner's topic");
    }
}
