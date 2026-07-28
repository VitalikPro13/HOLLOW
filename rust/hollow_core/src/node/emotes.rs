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

pub(crate) use super::assets::AssetKind;
use super::assets::MAX_BUNDLE_REPLY_BYTES;
use super::crypto_handler::{send_message_to_peer, send_raw_to_identity};
use super::types::{HavenMessage, NetworkEvent};
use crate::hollow_log;

/// Responder-side bound on hashes answered from one request (the largest
/// per-kind request bound; requesters bound tighter via
/// `AssetKind::max_request_hashes`). Per-blob receipt caps live in
/// `AssetKind::recv_cap`.
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

/// Wire grammar for a generalized asset token: `[a:kind:hash:w:h]` where
/// `kind` is `s` (sticker) or `g` (GIF), `hash` is full SHA-256 hex, and
/// `w`/`h` are the pixel dimensions (1..=4096) so receivers can reserve the
/// exact box before the bytes arrive (no reflow). Emotes keep `[e:name:hash]`
/// unchanged. Old clients render the raw token as text — same graceful
/// degradation emotes shipped with. Dual-defined with Dart
/// (`emote_image.dart::assetTokenRegex`) — keep in sync.
pub(crate) fn parse_asset_token(s: &str) -> Option<(AssetKind, &str, u32, u32)> {
    let inner = s.strip_prefix("[a:")?.strip_suffix(']')?;
    let mut parts = inner.splitn(4, ':');
    let kind = match parts.next()? {
        "s" => AssetKind::Sticker,
        "g" => AssetKind::Gif,
        _ => return None,
    };
    let hash = parts.next()?;
    let w: u32 = parts.next()?.parse().ok()?;
    let h: u32 = parts.next()?.parse().ok()?;
    (crate::crdt::valid_emote_hash(hash)
        && (1..=4096).contains(&w)
        && (1..=4096).contains(&h))
        .then_some((kind, hash, w, h))
}

/// Replace every well-formed `[e:name:hash]` token with `:name:` and every
/// `[a:kind:hash:w:h]` asset token with `[GIF]` / `[Sticker]` — for
/// notification surfaces that can only render plain text (iOS NSE push
/// bodies). Malformed near-tokens pass through untouched.
pub(crate) fn emote_tokens_to_shortcodes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let e = rest.find("[e:");
        let a = rest.find("[a:");
        let (start, is_emote) = match (e, a) {
            (Some(e), Some(a)) if e <= a => (e, true),
            (Some(e), None) => (e, true),
            (_, Some(a)) => (a, false),
            (None, None) => break,
        };
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        // "[e:" / "[a:" and "]" are ASCII, so these byte offsets are char
        // boundaries.
        if let Some(end) = tail.find(']') {
            if is_emote {
                if let Some((name, _)) = parse_emote_token(&tail[..=end]) {
                    out.push(':');
                    out.push_str(name);
                    out.push(':');
                    rest = &tail[end + 1..];
                    continue;
                }
            } else if let Some((kind, ..)) = parse_asset_token(&tail[..=end]) {
                out.push_str(match kind {
                    AssetKind::Gif => "[GIF]",
                    _ => "[Sticker]",
                });
                rest = &tail[end + 1..];
                continue;
            }
        }
        out.push_str(&tail[..3]);
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
/// have. `requested` is the per-connection throttle map (cleared on WS
/// disconnect) so a hash is asked for at most once per connection — and it
/// records the kind WE are requesting each hash as, which is what
/// `handle_emote_assets` sizes the receipt cap from. The sender never gets
/// a say in the cap.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_request_emotes(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    requested: &mut HashMap<String, AssetKind>,
    hashes: Vec<String>,
    kind: AssetKind,
    server_id: Option<String>,
    peer_hint: Option<String>,
    local_peer_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let mut missing: Vec<String> = Vec::new();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        for h in hashes.into_iter().take(kind.max_request_hashes()) {
            if !crate::crdt::valid_emote_hash(&h) || requested.contains_key(&h) {
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
        requested.insert(h.clone(), kind);
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
    let mut reply_bytes = 0usize;
    for h in hashes.into_iter().take(MAX_REQUEST_HASHES) {
        if !crate::crdt::valid_emote_hash(&h) {
            continue;
        }
        if let Ok(Some(bytes)) = store.load_emote_blob(&h) {
            // Budget the reply: with GIF-sized blobs cached, 20 hashes could
            // otherwise balloon a single bundle to ~40 MB.
            if reply_bytes + bytes.len() > MAX_BUNDLE_REPLY_BYTES {
                continue;
            }
            reply_bytes += bytes.len();
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

/// Inbound `EmoteAssets`: only blobs we actually REQUESTED are accepted —
/// the recorded kind sizes the cap (a sender can neither stuff our cache
/// unsolicited nor push a GIF-sized blob at an emote-sized ask). Then verify
/// (hash match via the bundle codec, WebP container), cache, notify the UI.
pub(crate) async fn handle_emote_assets(
    event_tx: &mpsc::Sender<NetworkEvent>,
    requested: &mut HashMap<String, AssetKind>,
    bundle_json: String,
    db_path: &str,
    db_passphrase: &str,
) {
    if bundle_json.len() > MAX_BUNDLE_REPLY_BYTES * 4 / 3 + 4096 {
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
        // Unsolicited hash — drop silently, and DON'T touch the request map.
        let Some(kind) = requested.get(&hash).copied() else {
            continue;
        };
        if bytes.is_empty() || bytes.len() > kind.recv_cap() || !is_webp(&bytes) {
            // A requested hash answered with invalid bytes: clear the
            // request slot so a later ask can retry from another holder.
            requested.remove(&hash);
            continue;
        }
        let animated = webp_is_animated(&bytes);
        if store
            .save_asset_blob(&hash, &bytes, animated, kind.db_kind())
            .is_ok()
        {
            requested.remove(&hash);
            stored.push(hash);
        }
    }
    if stored.is_empty() {
        return;
    }
    hollow_log!("[HOLLOW-EMOTE] Cached {} asset blob(s) from peer", stored.len());
    let _ = event_tx
        .send(NetworkEvent::EmoteAssetsReceived { hashes: stored })
        .await;
}

#[cfg(test)]
mod tests {
    use super::{emote_tokens_to_shortcodes, parse_asset_token, AssetKind};

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

    #[test]
    fn asset_tokens_become_labels() {
        let hash = "b".repeat(64);
        assert_eq!(
            emote_tokens_to_shortcodes(&format!("look [a:g:{hash}:480:270]")),
            "look [GIF]"
        );
        assert_eq!(
            emote_tokens_to_shortcodes(&format!("[a:s:{hash}:512:512] hi")),
            "[Sticker] hi"
        );
        // Mixed emote + asset tokens in one message, either order.
        assert_eq!(
            emote_tokens_to_shortcodes(&format!("[a:g:{hash}:10:10][e:ok:{hash}]")),
            "[GIF]:ok:"
        );
        assert_eq!(
            emote_tokens_to_shortcodes(&format!("[e:ok:{hash}][a:s:{hash}:10:10]")),
            ":ok:[Sticker]"
        );
        // Malformed asset near-tokens pass through untouched.
        assert_eq!(emote_tokens_to_shortcodes("[a:g:bad]"), "[a:g:bad]");
        assert_eq!(emote_tokens_to_shortcodes("[a:x"), "[a:x");
    }

    #[test]
    fn asset_token_grammar() {
        let hash = "c".repeat(64);
        let tok = format!("[a:g:{hash}:480:270]");
        let (kind, h, w, hgt) = parse_asset_token(&tok).expect("valid gif token");
        assert_eq!(kind, AssetKind::Gif);
        assert_eq!(h, hash);
        assert_eq!((w, hgt), (480, 270));
        assert_eq!(
            parse_asset_token(&format!("[a:s:{hash}:512:512]")).map(|t| t.0),
            Some(AssetKind::Sticker)
        );
        // Rejected: unknown kind, bad hash, zero/oversized dims, extra parts.
        assert!(parse_asset_token(&format!("[a:x:{hash}:10:10]")).is_none());
        assert!(parse_asset_token("[a:g:nothex:10:10]").is_none());
        assert!(parse_asset_token(&format!("[a:g:{hash}:0:10]")).is_none());
        assert!(parse_asset_token(&format!("[a:g:{hash}:10:5000]")).is_none());
        assert!(parse_asset_token(&format!("[a:g:{hash}:10:10:9]")).is_none());
    }
}
