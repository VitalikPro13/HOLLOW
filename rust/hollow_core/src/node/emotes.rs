//! Custom emote byte replication: content-addressed pull protocol.
//!
//! CRDT entries and message tokens carry only `(name, hash)`. The bytes live in
//! the SQLCipher `emote_blobs` table and replicate on demand: a client that must
//! render an unknown hash asks ONE source (never a broadcast sweep), a holder
//! answers `EmoteAssets` and names in `missing` whatever it does not hold, and
//! the receiver re-verifies sha256(bytes) == hash and the size and container
//! caps before caching.
//!
//! An unanswered ask outlives the socket: [`PendingAsk`] resumes at every event
//! that could have produced a holder, because a message replayed from the
//! relay's offline ring renders its token before anybody is reachable.
//!
//! Receivers NEVER fetch emote bytes over HTTP; FFZ and uploads exist only at
//! authoring time on the sender's side (the link-preview privacy rule).

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

pub(crate) use super::assets::AssetKind;
use super::assets::MAX_BUNDLE_REPLY_BYTES;
use super::crypto_handler::{online_devices_for, send_message_to_peer, ws_room_for_peer};
use super::types::{HavenMessage, NetworkEvent};
use crate::hollow_log;

/// Responder-side bound on hashes answered from one request (the largest
/// per-kind request bound; requesters bound tighter). Per-blob receipt caps live
/// in `AssetKind::recv_cap`.
const MAX_REQUEST_HASHES: usize = 20;

/// Ceiling on outstanding pulls. Overflow evicts the oldest ask, so a burst
/// of unrenderable tokens can never grow this without bound.
const MAX_PENDING_ASKS: usize = 512;

/// Distinct holders asked for one hash per connection. After the last miss
/// the hash waits for the next reconnect or a new peer, nothing more.
const MAX_ASK_CANDIDATES: usize = 4;

/// Hashes one sweep may act on. Bounds the burst a single reconnect produces and
/// the work the sweep does ON THE EVENT LOOP: picking a holder walks the room
/// tables, and a full table would otherwise be walked hundreds of times.
const MAX_ASKS_PER_SWEEP: usize = 8;

/// How long an ask sits unanswered before the retry sweep rotates it to the
/// next holder. Shortened under `cfg(test)` so the harness can observe
/// rotation without twenty-second waits (same trick as the grant sweep).
pub(crate) const ASSET_RETRY_SECS: u64 = if cfg!(test) { 1 } else { 20 };

/// One outstanding pull for a content hash, kept ACROSS reconnects.
///
/// A per-connection "asked once" set never re-asks a hash whose holder was
/// offline when the token first rendered. Only `asked` is cleared on disconnect,
/// because a new socket means a fresh set of candidates.
pub(crate) struct PendingAsk {
    /// The kind WE recorded — `handle_emote_assets` sizes the receipt cap
    /// from this and never from anything the sender says.
    pub(crate) kind: AssetKind,
    /// Server room to pull from, when the token was seen in a channel.
    pub(crate) server_id: Option<String>,
    /// Sender MASTER to pull from, when the token was seen in a DM.
    pub(crate) peer_hint: Option<String>,
    /// DEVICE peer_ids already asked on THIS connection.
    pub(crate) asked: HashSet<String>,
    pub(crate) first_asked_at: Instant,
    pub(crate) last_asked_at: Instant,
}

/// Every holder we could still ask for this blob, best first and otherwise in
/// ascending peer-id order so the walk is reproducible. Each entry carries the
/// room the send has to go out through.
fn ask_candidates(
    ask: &PendingAsk,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    local_peer_str: &str,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    // DM context: the hinted MASTER's live DEVICES (sends target a device).
    if let Some(hint) = ask.peer_hint.as_deref() {
        let mut devices = online_devices_for(ws_room_peers, hint);
        devices.sort();
        for dev in devices {
            if let Some(room) = ws_room_for_peer(ws_room_peers, &dev) {
                out.push((dev, room));
            }
        }
    }
    // Server context: members of the server room, its own deterministic room.
    if let Some(peers) = ask.server_id.as_deref().and_then(|sid| ws_room_peers.get(sid)) {
        let sid = ask.server_id.clone().unwrap_or_default();
        let mut members: Vec<String> = peers.iter().cloned().collect();
        members.sort();
        for m in members {
            out.push((m, sid.clone()));
        }
    }
    let mut seen: HashSet<String> = HashSet::new();
    out.retain(|(dev, _)| {
        dev != local_peer_str && !ask.asked.contains(dev) && seen.insert(dev.clone())
    });
    out
}

/// Ask the next unasked holder for each of `hashes`, ONE holder per hash (a
/// sweep across every member is the bandwidth leak the profile rail already
/// learned about). Hashes headed for the same holder ride ONE request.
fn dispatch_asks(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending: &mut HashMap<String, PendingAsk>,
    hashes: &[String],
    prefer: Option<&str>,
    local_peer_str: &str,
) {
    let now = Instant::now();
    let mut groups: HashMap<(String, String, AssetKind), Vec<String>> = HashMap::new();
    for h in hashes {
        let Some(ask) = pending.get(h) else { continue };
        if ask.asked.len() >= MAX_ASK_CANDIDATES {
            continue;
        }
        let candidates = ask_candidates(ask, ws_room_peers, local_peer_str);
        let picked = prefer
            .and_then(|p| candidates.iter().find(|(dev, _)| dev == p))
            .or_else(|| candidates.first());
        let Some((target, room)) = picked.cloned() else { continue };
        groups.entry((target, room, ask.kind)).or_default().push(h.clone());
    }
    for ((target, room, kind), mut group) in groups {
        group.sort();
        for chunk in group.chunks(kind.max_request_hashes()) {
            let msg = HavenMessage::EmoteRequest { hashes: chunk.to_vec() };
            let Ok(json) = serde_json::to_string(&msg) else { continue };
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: room.clone(),
                target_peer: target.clone(),
                data: json.into_bytes(),
            });
            for h in chunk {
                if let Some(ask) = pending.get_mut(h) {
                    ask.asked.insert(target.clone());
                    ask.last_asked_at = now;
                }
            }
        }
    }
}

/// The hashes a sweep will actually act on: longest-unanswered first, capped
/// at [`MAX_ASKS_PER_SWEEP`], so a large backlog drains over several sweeps
/// instead of in one burst.
fn sweep_order(pending: &HashMap<String, PendingAsk>, mut hashes: Vec<String>) -> Vec<String> {
    hashes.sort_by_key(|h| pending.get(h).map(|a| a.last_asked_at));
    hashes.truncate(MAX_ASKS_PER_SWEEP);
    hashes
}

/// Drop the oldest asks once the table is full.
fn evict_overflow(pending: &mut HashMap<String, PendingAsk>) {
    while pending.len() > MAX_PENDING_ASKS {
        let Some(oldest) = pending
            .iter()
            .min_by_key(|(_, a)| a.first_asked_at)
            .map(|(h, _)| h.clone())
        else {
            return;
        };
        pending.remove(&oldest);
    }
}

/// A holder appeared in a room (`WsEvent::PeerJoined`): ask it for anything
/// still pending that it could plausibly hold, at most one new ask per hash.
pub(crate) fn retry_asks_for_peer(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending: &mut HashMap<String, PendingAsk>,
    room: &str,
    peer_id: &str,
    local_peer_str: &str,
) {
    if pending.is_empty() || peer_id == local_peer_str {
        return;
    }
    let joiner_master = super::resolver::resolve(peer_id);
    let hashes: Vec<String> = pending
        .iter()
        .filter(|(_, a)| a.asked.len() < MAX_ASK_CANDIDATES && !a.asked.contains(peer_id))
        .filter(|(_, a)| {
            a.server_id.as_deref() == Some(room)
                || a.peer_hint
                    .as_deref()
                    .is_some_and(|h| super::resolver::resolve(h) == joiner_master)
        })
        .map(|(h, _)| h.clone())
        .collect();
    if hashes.is_empty() {
        return;
    }
    let hashes = sweep_order(pending, hashes);
    dispatch_asks(ws_cmd_tx, ws_room_peers, pending, &hashes, Some(peer_id), local_peer_str);
}

/// The relay's authoritative membership snapshot for a room landed. This closes
/// the boot-ordering race: the offline-ring replay arrives BEFORE the roster, so
/// the first ask goes nowhere and only this sweep has anyone to ask. Call it
/// AFTER `ws_room_peers` has been updated with the snapshot.
pub(crate) fn retry_asks_in_room(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending: &mut HashMap<String, PendingAsk>,
    room: &str,
    local_peer_str: &str,
) {
    if pending.is_empty() {
        return;
    }
    let hashes: Vec<String> = pending
        .iter()
        .filter(|(_, a)| a.asked.len() < MAX_ASK_CANDIDATES)
        .filter(|(_, a)| a.server_id.as_deref() == Some(room) || a.peer_hint.is_some())
        .map(|(h, _)| h.clone())
        .collect();
    if hashes.is_empty() {
        return;
    }
    let hashes = sweep_order(pending, hashes);
    dispatch_asks(ws_cmd_tx, ws_room_peers, pending, &hashes, None, local_peer_str);
}

/// Retry sweep: rotate any ask that has gone quiet to its next holder. Old
/// clients answer a total miss with silence, so this is what covers them.
///
/// Opens the store at most ONCE, and only when something is actually stale.
pub(crate) fn retry_stale_asks(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending: &mut HashMap<String, PendingAsk>,
    local_peer_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if pending.is_empty() {
        return;
    }
    let now = Instant::now();
    let stale: Vec<String> = pending
        .iter()
        .filter(|(_, a)| {
            a.asked.len() < MAX_ASK_CANDIDATES
                && now.duration_since(a.last_asked_at) >= Duration::from_secs(ASSET_RETRY_SECS)
        })
        .map(|(h, _)| h.clone())
        .collect();
    if stale.is_empty() {
        return;
    }
    let stale = sweep_order(pending, stale);
    let mut ready: Vec<String> = Vec::new();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        for h in stale {
            // The bytes may have landed by another route (a pack import, a
            // second conversation) — retire the ask instead of re-asking.
            if store.has_emote_blob(&h).unwrap_or(false) {
                pending.remove(&h);
                continue;
            }
            ready.push(h);
        }
    }
    if ready.is_empty() {
        return;
    }
    dispatch_asks(ws_cmd_tx, ws_room_peers, pending, &ready, None, local_peer_str);
}

/// A new socket means a fresh set of candidates: keep every pending ask, drop
/// only the record of who was asked over the connection that just died.
pub(crate) fn reset_asked_on_disconnect(pending: &mut HashMap<String, PendingAsk>) {
    // Let the next sweep act immediately rather than waiting out a staleness
    // window measured against the dead socket.
    let stale_now = Instant::now()
        .checked_sub(Duration::from_secs(ASSET_RETRY_SECS))
        .unwrap_or_else(Instant::now);
    for ask in pending.values_mut() {
        ask.asked.clear();
        ask.last_asked_at = stale_now;
    }
}

/// Wire grammar for a custom-emote token: `[e:name:hash]`, `name` 2-24 chars of
/// `[a-z0-9_]` and `hash` full SHA-256 hex. Inline in message text AND as a
/// reaction "emoji". Old clients render the raw token as text.
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

/// Wire grammar for a generalized asset token: `[a:kind:hash:w:h]`, `kind` `s`
/// (sticker) or `g` (GIF), `w`/`h` the pixel dimensions (1..=4096) so receivers
/// reserve the exact box before the bytes arrive. Emotes keep `[e:name:hash]`.
/// Dual-defined with Dart (`emote_image.dart::assetTokenRegex`), keep in sync.
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

/// Replace every `[e:name:hash]` token with `:name:` and every asset token with
/// `[GIF]` / `[Sticker]`, for notification surfaces that render plain text only
/// (iOS NSE push bodies). Malformed near-tokens pass through untouched.
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
        // "[e:" / "[a:" and "]" are ASCII, so these offsets are char boundaries.
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

/// Outbound `NodeCommand::RequestEmotes`: pull bytes for hashes we do not have.
/// Each new hash becomes a [`PendingAsk`] that OUTLIVES the socket. The entry
/// records the kind WE are requesting the hash as, which is what sizes the
/// receipt cap; the sender never gets a say in it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_request_emotes(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending: &mut HashMap<String, PendingAsk>,
    hashes: Vec<String>,
    kind: AssetKind,
    server_id: Option<String>,
    peer_hint: Option<String>,
    local_peer_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let mut fresh: Vec<String> = Vec::new();
    let mut re_aimed: Vec<String> = Vec::new();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        for h in hashes.into_iter().take(kind.max_request_hashes()) {
            if !crate::crdt::valid_emote_hash(&h) {
                continue;
            }
            if let Some(ask) = pending.get_mut(&h) {
                // Already outstanding. Take any context this ask did not have
                // (the same GIF seen in a DM and a channel widens the pool of
                // holders), but never reset who has already been asked.
                if ask.server_id.is_none() {
                    ask.server_id = server_id.clone();
                }
                if ask.peer_hint.is_none() {
                    ask.peer_hint = peer_hint.clone();
                }
                // The same hash asked for as a DIFFERENT kind is a new decision
                // of OURS, not a retry of the old one: the cap that refused the
                // last answer was ours, so every holder is a candidate again.
                if ask.kind != kind {
                    ask.kind = kind;
                    ask.asked.clear();
                    re_aimed.push(h);
                }
                continue;
            }
            if store.has_emote_blob(&h).unwrap_or(false) {
                continue;
            }
            fresh.push(h);
        }
    }
    if fresh.is_empty() && re_aimed.is_empty() {
        return;
    }
    let now = Instant::now();
    for h in &fresh {
        pending.insert(
            h.clone(),
            PendingAsk {
                kind,
                server_id: server_id.clone(),
                peer_hint: peer_hint.clone(),
                asked: HashSet::new(),
                first_asked_at: now,
                last_asked_at: now,
            },
        );
    }
    evict_overflow(pending);
    let mut ask_now = fresh;
    ask_now.append(&mut re_aimed);
    dispatch_asks(ws_cmd_tx, ws_room_peers, pending, &ask_now, None, local_peer_str);
}

/// Inbound `EmoteRequest`: answer with whatever subset of the hashes we hold.
/// Content addressing makes every copy equally trustworthy.
///
/// A hash we do NOT hold is named in `missing` rather than passed over in
/// silence, so the asker rotates to another holder instead of waiting out its
/// sweep. An empty bundle is therefore a legitimate reply.
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
    let mut missing: Vec<String> = Vec::new();
    let mut reply_bytes = 0usize;
    let mut asked_anything = false;
    for h in hashes.into_iter().take(MAX_REQUEST_HASHES) {
        if !crate::crdt::valid_emote_hash(&h) {
            continue;
        }
        asked_anything = true;
        match store.load_emote_blob(&h) {
            Ok(Some(bytes)) => {
                // Budget the reply: with GIF-sized blobs cached, 20 hashes could
                // balloon one bundle to ~40 MB. Naming the overflow as missing
                // sends the asker somewhere that can actually serve it.
                if reply_bytes + bytes.len() > MAX_BUNDLE_REPLY_BYTES {
                    missing.push(h);
                    continue;
                }
                reply_bytes += bytes.len();
                assets.push((h, bytes));
            }
            _ => missing.push(h),
        }
    }
    if !asked_anything {
        return;
    }
    let bundle = crate::api::showcase::encode_asset_bundle(&assets);
    let Ok(bundle_json) = String::from_utf8(bundle) else { return };
    send_message_to_peer(
        ws_cmd_tx,
        ws_room_peers,
        peer_str,
        HavenMessage::EmoteAssets { bundle_json, missing },
    );
}

/// Inbound `EmoteAssets`: only blobs we actually REQUESTED are accepted, and the
/// recorded kind sizes the cap, so a sender can neither stuff our cache
/// unsolicited nor push a GIF-sized blob at an emote-sized ask. Then verify hash
/// and container, cache, notify the UI.
///
/// A `missing` list rotates the ask onward, but only from a device this ask
/// really did ask: otherwise any room member could make us fan requests around.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_emote_assets(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending: &mut HashMap<String, PendingAsk>,
    peer_str: &str,
    bundle_json: String,
    missing: Vec<String>,
    local_peer_str: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let rotate: Vec<String> = missing
        .into_iter()
        .take(MAX_REQUEST_HASHES)
        .filter(|h| pending.get(h).is_some_and(|a| a.asked.contains(peer_str)))
        .collect();
    if !rotate.is_empty() {
        dispatch_asks(ws_cmd_tx, ws_room_peers, pending, &rotate, None, local_peer_str);
    }
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
    let mut refused: Vec<String> = Vec::new();
    for (hash, bytes) in assets {
        // Unsolicited hash — drop silently, and DON'T touch the pending table.
        let Some(kind) = pending.get(&hash).map(|a| a.kind) else {
            continue;
        };
        // SECURITY (SHOP-2, same class): the byte cap says nothing about the
        // DECODED size, and every later reader of this blob decodes it. A blob
        // that DECLARES a canvas over the ceiling is refused before the cache. An
        // unreadable header is left to the existing rule (container magic plus
        // content hash), because a decoder rejects it outright anyway.
        let canvas_ok = crate::node::image_convert::webp_header_dimensions(&bytes)
            .is_none_or(|(w, h)| {
                w <= crate::node::image_convert::MAX_DECODE_DIM
                    && h <= crate::node::image_convert::MAX_DECODE_DIM
            });
        if bytes.is_empty() || bytes.len() > kind.recv_cap() || !is_webp(&bytes) || !canvas_ok {
            // Bytes we refuse are a MISS, not the end of the hunt: deleting the
            // ask would let one holder answering with garbage end the search for
            // that hash for good. Only when the answer came from a device this
            // ask really did ask, so an unasked peer cannot steer our walk.
            if pending.get(&hash).is_some_and(|a| a.asked.contains(peer_str)) {
                refused.push(hash);
            }
            continue;
        }
        let animated = webp_is_animated(&bytes);
        if store
            .save_asset_blob(&hash, &bytes, animated, kind.db_kind())
            .is_ok()
        {
            pending.remove(&hash);
            stored.push(hash);
        }
    }
    // Rotation for the refusals, after the loop so one bundle costs one pass
    // over the candidates however many hashes it carried.
    if !refused.is_empty() {
        dispatch_asks(ws_cmd_tx, ws_room_peers, pending, &refused, None, local_peer_str);
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
    use super::{
        emote_tokens_to_shortcodes, is_webp, parse_asset_token, AssetKind,
        MAX_BUNDLE_REPLY_BYTES,
    };

    /// The worst legal reply this rail can be asked to build: four hashes at the
    /// Profile receipt cap is EXACTLY the bundle budget. Both halves of that
    /// arithmetic are easy to get off by one, and the symptom is silent: the
    /// fourth asset of a full profile-media pull would simply never arrive.
    #[test]
    fn a_profile_bundle_at_the_budget_packs_and_survives_the_inbound_guard() {
        use sha2::{Digest, Sha256};

        let cap = AssetKind::Profile.recv_cap();
        let hashes = AssetKind::Profile.max_request_hashes();
        assert_eq!(
            hashes * cap,
            MAX_BUNDLE_REPLY_BYTES,
            "a full Profile request has to land exactly on the bundle budget"
        );

        // Real WebP magic on incompressible bodies: the responder's own
        // container gate accepts these, and base64 cannot shrink them.
        let assets: Vec<(String, Vec<u8>)> = (0..hashes)
            .map(|i| {
                let mut bytes = b"RIFF____WEBPVP8 ".to_vec();
                bytes.resize(cap, 0);
                let mut seed = 0x9E3779B9u32 ^ (i as u32 + 1);
                for b in bytes[16..].iter_mut() {
                    seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                    *b = (seed >> 24) as u8;
                }
                assert!(is_webp(&bytes));
                (hex::encode(Sha256::digest(&bytes)), bytes)
            })
            .collect();

        // The responder's packing comparison, verbatim. The fourth asset lands ON
        // the budget, and `>` rather than `>=` is what admits it.
        let mut reply_bytes = 0usize;
        let mut packed: Vec<(String, Vec<u8>)> = Vec::new();
        for (hash, bytes) in &assets {
            if reply_bytes + bytes.len() > MAX_BUNDLE_REPLY_BYTES {
                continue;
            }
            reply_bytes += bytes.len();
            packed.push((hash.clone(), bytes.clone()));
        }
        assert_eq!(packed.len(), hashes, "every asset of a full request must pack");
        assert_eq!(reply_bytes, MAX_BUNDLE_REPLY_BYTES);

        // ...and the inbound guard's base64 headroom has to tolerate the
        // bundle we just built, JSON envelope and all.
        let bundle_json =
            String::from_utf8(crate::api::showcase::encode_asset_bundle(&packed))
                .expect("the bundle codec emits text");
        assert!(
            bundle_json.len() <= MAX_BUNDLE_REPLY_BYTES * 4 / 3 + 4096,
            "the inbound guard would drop our own worst legal bundle: {} bytes",
            bundle_json.len()
        );

        let decoded = crate::api::showcase::decode_asset_bundle(bundle_json.as_bytes());
        assert_eq!(decoded.len(), hashes, "all four have to come back out");
        for (hash, bytes) in &decoded {
            assert_eq!(bytes.len(), cap);
            assert!(bytes.len() <= AssetKind::Profile.recv_cap());
            assert_eq!(&hex::encode(Sha256::digest(bytes)), hash);
        }
    }

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
