//! Custom emote byte replication — content-addressed pull protocol.
//!
//! CRDT entries and message tokens carry only `(name, hash)`. The bytes live
//! in the SQLCipher `emote_blobs` table and replicate on demand:
//!
//!   1. a client that must render an unknown hash sends `EmoteRequest`
//!      to ONE source (the DM sender's devices, or one online member of the
//!      server room) — never a broadcast sweep;
//!   2. anyone holding the bytes answers `EmoteAssets` (the showcase bundle
//!      codec: JSON map hash → base64);
//!   3. the receiver re-verifies sha256(bytes) == hash, enforces size and
//!      WebP-container caps, caches into `emote_blobs`, and emits
//!      `EmoteAssetsReceived` so pending tokens re-render.
//!
//! Receivers NEVER fetch emote bytes over HTTP — FFZ/uploads exist only at
//! authoring time on the sender's side (same privacy rule as link previews).

use std::collections::{HashMap, HashSet};

use tokio::sync::mpsc;

use super::crypto_handler::{send_message_to_peer, send_raw_to_identity};
use super::types::{HavenMessage, NetworkEvent};
use crate::hollow_log;

/// Hard cap on a single emote blob accepted from the wire (animated ceiling;
/// stills are re-encoded far smaller at authoring).
pub(crate) const MAX_EMOTE_BYTES: usize = 262_144;
/// Max hashes per EmoteRequest (a message can only reference so many emotes;
/// bounds the reply bundle at ~5 MB worst case).
const MAX_REQUEST_HASHES: usize = 20;

/// Wire grammar for a custom-emote token: `[e:name:hash]` where `name` is
/// 2-24 chars of `[a-z0-9_]` and `hash` is full SHA-256 hex. Used inline in
/// message text AND as a reaction "emoji" string. Old clients render the
/// raw token as text (graceful degradation).
pub(crate) fn parse_emote_token(s: &str) -> Option<(&str, &str)> {
    let inner = s.strip_prefix("[e:")?.strip_suffix(']')?;
    let (name, hash) = inner.split_once(':')?;
    (crate::crdt::valid_emote_name(name) && crate::crdt::valid_emote_hash(hash))
        .then_some((name, hash))
}

/// A reaction "emoji" is either a short Unicode emoji (legacy ≤10-byte rule)
/// or a well-formed custom-emote token — nothing else.
pub(crate) fn valid_reaction_emoji(s: &str) -> bool {
    (!s.is_empty() && s.len() <= 10) || parse_emote_token(s).is_some()
}

/// Replace every well-formed `[e:name:hash]` token with `:name:` — for
/// notification surfaces that can only render plain text (iOS NSE push
/// bodies). Malformed near-tokens pass through untouched.
pub(crate) fn emote_tokens_to_shortcodes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("[e:") {
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        // "[e:" and "]" are ASCII, so these byte offsets are char boundaries.
        if let Some(end) = tail.find(']') {
            if let Some((name, _)) = parse_emote_token(&tail[..=end]) {
                out.push(':');
                out.push_str(name);
                out.push(':');
                rest = &tail[end + 1..];
                continue;
            }
        }
        out.push_str("[e:");
        rest = &tail[3..];
    }
    out.push_str(rest);
    out
}

fn is_webp(bytes: &[u8]) -> bool {
    bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP"
}

/// Whether a WebP container carries the VP8X animation flag.
pub(crate) fn webp_is_animated(bytes: &[u8]) -> bool {
    bytes.len() > 20 && &bytes[12..16] == b"VP8X" && (bytes[20] & 0x02) != 0
}

/// Outbound `NodeCommand::RequestEmotes`: pull bytes for hashes we don't
/// have. `requested` is the per-connection throttle set (cleared on WS
/// disconnect) so a hash is asked for at most once per connection.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_request_emotes(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    requested: &mut HashSet<String>,
    hashes: Vec<String>,
    server_id: Option<String>,
    peer_hint: Option<String>,
    local_peer_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let mut missing: Vec<String> = Vec::new();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        for h in hashes.into_iter().take(MAX_REQUEST_HASHES) {
            if !crate::crdt::valid_emote_hash(&h) || requested.contains(&h) {
                continue;
            }
            if store.has_emote_blob(&h).unwrap_or(false) {
                continue;
            }
            missing.push(h);
        }
    }
    if missing.is_empty() {
        return;
    }
    for h in &missing {
        requested.insert(h.clone());
    }
    let msg = HavenMessage::EmoteRequest { hashes: missing };
    let Ok(json) = serde_json::to_string(&msg) else { return };

    // DM context: ask the sender's devices (master resolved to live devices).
    if let Some(hint) = peer_hint {
        if send_raw_to_identity(ws_cmd_tx, ws_room_peers, &hint, json.clone().into_bytes()) > 0 {
            return;
        }
    }
    // Server context: ask ONE online member of the server room (never a
    // broadcast — the profile-sweep bandwidth rule).
    if let Some(sid) = server_id {
        if let Some(peers) = ws_room_peers.get(&sid) {
            if let Some(target) = peers.iter().find(|p| *p != local_peer_str) {
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                    room_code: sid.clone(),
                    target_peer: target.clone(),
                    data: json.into_bytes(),
                });
            }
        }
    }
}

/// Inbound `EmoteRequest`: answer with whatever subset of the hashes we have
/// cached locally. Anyone who has the bytes can serve them — content
/// addressing makes every copy equally trustworthy.
pub(crate) fn handle_emote_request(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    peer_str: &str,
    hashes: Vec<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let mut assets: Vec<(String, Vec<u8>)> = Vec::new();
    for h in hashes.into_iter().take(MAX_REQUEST_HASHES) {
        if !crate::crdt::valid_emote_hash(&h) {
            continue;
        }
        if let Ok(Some(bytes)) = store.load_emote_blob(&h) {
            assets.push((h, bytes));
        }
    }
    if assets.is_empty() {
        return;
    }
    let bundle = crate::api::showcase::encode_asset_bundle(&assets);
    let Ok(bundle_json) = String::from_utf8(bundle) else { return };
    send_message_to_peer(
        ws_cmd_tx,
        ws_room_peers,
        peer_str,
        HavenMessage::EmoteAssets { bundle_json },
    );
}

/// Inbound `EmoteAssets`: verify (hash match via the bundle codec, size cap,
/// WebP container), cache, and notify the UI.
pub(crate) async fn handle_emote_assets(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_json: String,
    db_path: &str,
    db_passphrase: &str,
) {
    if bundle_json.len() > MAX_REQUEST_HASHES * (MAX_EMOTE_BYTES * 4 / 3 + 128) {
        return; // oversized bundle — drop wholesale
    }
    let assets = crate::api::showcase::decode_asset_bundle(bundle_json.as_bytes());
    if assets.is_empty() {
        return;
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let mut stored: Vec<String> = Vec::new();
    for (hash, bytes) in assets {
        if bytes.is_empty() || bytes.len() > MAX_EMOTE_BYTES || !is_webp(&bytes) {
            continue;
        }
        let animated = webp_is_animated(&bytes);
        if store.save_emote_blob(&hash, &bytes, animated).is_ok() {
            stored.push(hash);
        }
    }
    if stored.is_empty() {
        return;
    }
    hollow_log!("[HOLLOW-EMOTE] Cached {} emote blob(s) from peer", stored.len());
    let _ = event_tx
        .send(NetworkEvent::EmoteAssetsReceived { hashes: stored })
        .await;
}

#[cfg(test)]
mod tests {
    use super::emote_tokens_to_shortcodes;

    #[test]
    fn emote_tokens_become_shortcodes() {
        let hash = "a".repeat(64);
        assert_eq!(
            emote_tokens_to_shortcodes(&format!("hi [e:ayaya:{hash}] there")),
            "hi :ayaya: there"
        );
        // Multiple tokens, including back-to-back.
        assert_eq!(
            emote_tokens_to_shortcodes(&format!("[e:a1:{hash}][e:b_2:{hash}]")),
            ":a1::b_2:"
        );
        // Malformed near-tokens pass through untouched.
        assert_eq!(emote_tokens_to_shortcodes("[e:bad"), "[e:bad");
        assert_eq!(emote_tokens_to_shortcodes("[e:x:nothex]"), "[e:x:nothex]");
        // Plain text untouched.
        assert_eq!(emote_tokens_to_shortcodes("no emotes"), "no emotes");
    }
}
