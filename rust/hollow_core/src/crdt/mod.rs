pub(crate) mod admin_lww;
pub(crate) mod hlc;
pub(crate) mod operations;
pub(crate) mod server_state;
pub(crate) mod sync;

use std::sync::OnceLock;

/// Device→master resolver hook (multi-device, Phase 6).
///
/// `ServerState` is keyed by MASTER identity, but membership/role/permission/ban
/// lookups are frequently called with a DEVICE peer_id (the transport sender).
/// To avoid a hard `crdt → node::resolver` dependency (and to keep `crdt` unit
/// tests pure), the node installs its resolver here ONCE at startup via
/// [`set_identity_resolver`]; the `ServerState` accessors call [`resolve_identity`]
/// to collapse any device id to its master before the keyed lookup.
///
/// Default (and in unit tests): identity-passthrough — single-device behavior is
/// byte-for-byte unchanged.
type ResolverFn = fn(&str) -> String;

static IDENTITY_RESOLVER: OnceLock<ResolverFn> = OnceLock::new();

/// Install the device→master resolver. Idempotent-safe: only the first call wins
/// (matches the process-global resolver's lifetime). Call once at node startup.
pub(crate) fn set_identity_resolver(f: ResolverFn) {
    let _ = IDENTITY_RESOLVER.set(f);
}

/// Resolve a peer_id to its master identity via the installed hook, or return it
/// unchanged if no resolver is installed (tests / pre-startup).
pub(crate) fn resolve_identity(peer_id: &str) -> String {
    match IDENTITY_RESOLVER.get() {
        Some(f) => f(peer_id),
        None => peer_id.to_string(),
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
