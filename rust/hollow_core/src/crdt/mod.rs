pub(crate) mod admin_lww;
pub(crate) mod hlc;
pub(crate) mod operations;
pub(crate) mod server_state;
pub(crate) mod sync;

use std::sync::OnceLock;

/// Device→master resolver hook: `ServerState` is keyed by MASTER identity while
/// lookups arrive with DEVICE peer_ids, and a hook keeps `crdt` free of a
/// `node::resolver` dependency. Default is passthrough, so unit tests stay pure.
type ResolverFn = fn(&str) -> String;

static IDENTITY_RESOLVER: OnceLock<ResolverFn> = OnceLock::new();

/// Install the device→master resolver at node startup; only the first call wins.
pub(crate) fn set_identity_resolver(f: ResolverFn) {
    let _ = IDENTITY_RESOLVER.set(f);
}

/// Resolve a peer_id to its master identity, unchanged if no resolver is installed.
pub(crate) fn resolve_identity(peer_id: &str) -> String {
    match IDENTITY_RESOLVER.get() {
        Some(f) => f(peer_id),
        None => peer_id.to_string(),
    }
}

/// Deterministic keys for the CRDT unit tests: a signature binds an op to an
/// author whose peer_id is DERIVED from the key, so a made-up author string
/// like "alice" can never survive `admit_remote_op`.
#[cfg(test)]
pub(crate) mod testkeys {
    use crate::identity::native_identity::NativeKeypair;
    use base64::Engine as _;

    /// `(keypair, peer_id, pk_b64)` for a small tag. Same tag = same identity.
    pub(crate) fn keys(tag: u8) -> (NativeKeypair, String, String) {
        let kp = NativeKeypair::from_secret_bytes(&[tag.wrapping_add(1); 32]);
        let pk = base64::engine::general_purpose::STANDARD.encode(kp.public_key_protobuf());
        let id = kp.peer_id();
        (kp, id, pk)
    }

    /// A server owned by `tag`, wired with HLC and signer so it can author signed ops.
    pub(crate) fn owned_state(
        server_id: &str,
        name: &str,
        tag: u8,
    ) -> (super::server_state::ServerState, String) {
        let (kp, id, pk) = keys(tag);
        let mut state =
            super::server_state::ServerState::new(server_id.into(), name.into(), id.clone());
        state.set_signer(kp, pk);
        (state, id)
    }
}

/// Custom emote name rules: 2-24 chars of `[a-z0-9_]` (lowercase enforced at
/// authoring; validated again at every ingest so a hostile client can't
/// smuggle markup/whitespace into message tokens through the emote registry).
pub(crate) fn valid_emote_name(name: &str) -> bool {
    (2..=24).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

/// Emote hashes are full SHA-256 hex (content addressing IS the integrity
/// check — receivers verify bytes against this before caching).
pub(crate) fn valid_emote_hash(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
