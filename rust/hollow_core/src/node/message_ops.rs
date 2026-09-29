use std::collections::{HashMap, HashSet};

use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use crate::crdt::server_state::ServerState;
use super::crypto_handler::{
    link_preview_digest, sign_message, sign_message_versioned,
    verify_message_signature, verify_message_signature_v2, PkCache, SignedExtras,
    peer_is_reachable, send_mls_broadcast_topic, send_encrypted_message,
    send_message_to_peer,
};
use super::types::*;

/// Owned v2-signature extras loaded from an EXISTING message row. Edit and
/// delete signatures bind the same structural fields as the original message, so
/// SIGN sites load them from the signer's row and live VERIFY sites reconstruct
/// them from the receiver's row: both ends agree by construction. A missing row
/// degrades to mid-only extras, which fails unless the signer saw no row either.
pub(crate) struct RowExtras {
    pub text: Option<String>,
    pub reply_to: Option<String>,
    pub file_id: Option<String>,
    pub order_us: Option<i64>,
    pub lp_digest: Option<String>,
    pub album: Option<String>,
}

impl RowExtras {
    pub(crate) fn load_channel(store: &crate::storage::MessageStore, mid: &str) -> Self {
        Self::from_row(store.get_channel_message_sig_row(mid))
    }

    pub(crate) fn load_dm(store: &crate::storage::MessageStore, mid: &str) -> Self {
        Self::from_row(store.get_dm_message_sig_row(mid))
    }

    fn from_row(row: Option<crate::storage::messages::MessageSigRow>) -> Self {
        let Some(r) = row else {
            return Self { text: None, reply_to: None, file_id: None, order_us: None, lp_digest: None, album: None };
        };
        Self {
            lp_digest: r.link_preview.as_ref().map(link_preview_digest),
            text: Some(r.text),
            reply_to: r.reply_to_mid,
            file_id: r.file_id,
            order_us: r.order_us,
            album: r.album_id,
        }
    }

    pub(crate) fn as_signed<'a>(&'a self, mid: &'a str) -> SignedExtras<'a> {
        SignedExtras {
            mid: Some(mid),
            reply_to: self.reply_to.as_deref(),
            file_id: self.file_id.as_deref(),
            order_us: self.order_us,
            lp_digest: self.lp_digest.as_deref(),
            album: self.album.as_deref(),
        }
    }
}

// ── Deletion propagation through sync (0.8.4) ────────────────────────
//
// `hidden_at` on a sync item is honored ONLY with the author's own deletion
// signature riding next to it. REJECT-ABSENT: a bare hidden flag is a
// forge-a-deletion and censorship primitive, so it is DROPPED, and there is
// deliberately no tolerate-absent fallback, because tolerating absence reopens
// the gap via omit-the-sig. The cost is that ancient unsigned deletions no
// longer propagate. Deletes are SELF-ONLY, so the author is derived from the
// RECEIVER'S ROW, never from item fields the responder controls.

/// Outbound half: the `(hidden_at, hidden_sig, hidden_pk)` triple for a sync item
/// built from row `mid`. Prefers the proof's own `deleted_at` over a drifted row
/// `hidden_at`, so the served pair is always the one the author signed. A hidden
/// row with no signed proof is served bare, and receivers drop the flag.
pub(crate) fn deletion_proof_fields(
    store: &crate::storage::MessageStore,
    hidden_at: Option<i64>,
    mid: Option<&str>,
) -> (Option<i64>, Option<String>, Option<String>) {
    let (Some(_), Some(mid)) = (hidden_at, mid) else {
        return (hidden_at, None, None);
    };
    match store.load_deletion_proof(mid) {
        Some((ts, sig, pk)) => (Some(ts), Some(sig), Some(pk)),
        None => (hidden_at, None, None),
    }
}

/// Inbound half (channel): verify and apply one sync-carried deletion. The proof
/// is checked against OUR row (author = row sender resolved to master, extras and
/// text from the row), then stored for onward propagation. Returns true when the
/// row was NEWLY hidden; false = rejected, already hidden, or no such row.
#[allow(clippy::too_many_arguments)]
pub(crate) fn apply_verified_channel_deletion(
    store: &crate::storage::MessageStore,
    sid: &str,
    cid: &str,
    mid: &str,
    hidden_ts: i64,
    hidden_sig: Option<&str>,
    hidden_pk: Option<&str>,
    pk_cache: &mut PkCache,
) -> bool {
    let already_hidden = store.get_channel_message_hidden_at(mid).is_some();
    // Converged (hidden + proof on file): quiet no-op. An already-hidden row
    // MISSING its proof still runs the verify below, so a valid proof is adopted.
    if already_hidden && store.load_deletion_proof(mid).is_some() {
        return false;
    }
    let (Some(sig), Some(pk)) = (hidden_sig, hidden_pk) else {
        if !already_hidden {
            hollow_log!("[HOLLOW-SECURITY] REJECTED synced deletion of {mid} in {sid}/{cid} — hidden_at without a deletion proof");
        }
        return false;
    };
    // Deletes are SELF-ONLY: only the row's AUTHOR can have signed it.
    let Some(sender) = store.get_channel_message_sender(mid) else {
        return false;
    };
    let signer = super::resolver::resolve(&sender);
    let row = RowExtras::load_channel(store, mid);
    let current_text = row.text.clone().unwrap_or_default();
    if !verify_message_signature_v2(
        &signer, Some(sig), Some(pk), "ch-delete", &format!("{sid}:{cid}"),
        hidden_ts, &row.as_signed(mid), &current_text, pk_cache,
    ) {
        if !already_hidden {
            hollow_log!("[HOLLOW-SECURITY] REJECTED synced deletion of {mid} in {sid}/{cid} (signer {signer}) — deletion signature INVALID");
        }
        return false;
    }
    let _ = store.set_channel_message_hidden_verified(mid, hidden_ts, sig, pk);
    !already_hidden
}

/// Inbound half (DM): like [`apply_verified_channel_deletion`], but signer and
/// context come from the ROW's direction. `is_mine` comes from OUR row: taking it
/// from the item's `mine` flag would let a friend "delete" OUR message with THEIR
/// OWN valid signature. Signer = the deleter's master, context = the other party.
#[allow(clippy::too_many_arguments)]
pub(crate) fn apply_verified_dm_deletion(
    store: &crate::storage::MessageStore,
    local_master: &str,
    mid: &str,
    hidden_ts: i64,
    hidden_sig: Option<&str>,
    hidden_pk: Option<&str>,
    pk_cache: &mut PkCache,
) -> bool {
    let already_hidden = store.get_dm_message_hidden_at(mid).is_some();
    if already_hidden && store.load_deletion_proof(mid).is_some() {
        return false;
    }
    let (Some(sig), Some(pk)) = (hidden_sig, hidden_pk) else {
        if !already_hidden {
            hollow_log!("[HOLLOW-SECURITY] REJECTED synced DM deletion of {mid} — hidden_at without a deletion proof");
        }
        return false;
    };
    let Some(is_mine) = store.get_dm_message_is_mine(mid) else {
        return false;
    };
    let row_peer = super::resolver::resolve(
        &store.get_dm_message_peer(mid).unwrap_or_default(),
    );
    let (signer, ctx) = if is_mine {
        // We authored + deleted it; we signed ctx = the conversation peer.
        (local_master.to_string(), row_peer)
    } else {
        // The peer authored + deleted it; they signed ctx = us.
        (row_peer, local_master.to_string())
    };
    let row = RowExtras::load_dm(store, mid);
    let current_text = row.text.clone().unwrap_or_default();
    if !verify_message_signature_v2(
        &signer, Some(sig), Some(pk), "dm-delete", &ctx,
        hidden_ts, &row.as_signed(mid), &current_text, pk_cache,
    ) {
        if !already_hidden {
            hollow_log!("[HOLLOW-SECURITY] REJECTED synced DM deletion of {mid} (signer {signer}) — deletion signature INVALID");
        }
        return false;
    }
    let _ = store.set_dm_message_hidden_verified(mid, hidden_ts, sig, pk);
    !already_hidden
}

/// Guest-preview half: verify a public-channel sync item's CONTENT signature from
/// the item's own fields. `false` = drop the item entirely.
///
/// Public-channel sync is PLAINTEXT, so a responder or the relay can rewrite a
/// batch wholesale. Members already refuse an unverified item at the four
/// backfill sites; without this the guest browser, the one surface strangers see,
/// renders whatever arrived. Same rule as the member path: signer = `resolve(m.s)`,
/// context "{sid}:{cid}", and edited rows verified against their edit signature.
pub(crate) fn guest_item_accepted(
    m: &super::types::SyncMessageItem,
    sid: &str,
    cid: &str,
    pk_cache: &mut PkCache,
) -> bool {
    // Digest from the shipped card, so the card is covered by the same check that
    // covers the text. Without binding the card, a relay could paste a phishing
    // one onto any message a stranger reads.
    let lp_digest = super::crypto_handler::backfill_lp_digest(
        m.lp.as_deref(), m.lp_digest.as_deref(),
    );
    let extras = SignedExtras {
        mid: m.mid.as_deref(),
        reply_to: m.reply_to.as_deref(),
        file_id: m.file_id.as_deref(),
        order_us: m.order_us,
        lp_digest: lp_digest.as_deref(),
        album: m.album.as_deref(),
    };
    let verdict = super::crypto_handler::check_backfill_signature(
        &super::resolver::resolve(&m.s), "ch", &format!("{sid}:{cid}"),
        m.ts, m.edited_at, &extras, &m.t,
        m.sig.as_deref(), m.pk.as_deref(), pk_cache,
    );
    if !verdict.is_acceptable() {
        hollow_log!(
            "[HOLLOW-SECURITY] DROPPED guest public-channel message in {sid}/{cid} claiming sender {} — {} (mid={:?}, ts={})",
            m.s, verdict.reject_reason(), m.mid, m.ts
        );
        return false;
    }
    true
}

/// Guest-preview half: verify a public-channel sync item's hidden flag from the
/// item's own fields (guests hold no rows to check against). Returns the
/// `hidden_at` to honor, or `None` to strip the flag. The pubkey-to-signer binding
/// stops a non-author forging a proof; a replayed REAL deletion is propagation.
pub(crate) fn verified_guest_hidden_at(
    m: &super::types::SyncMessageItem,
    sid: &str,
    cid: &str,
    pk_cache: &mut PkCache,
) -> Option<i64> {
    let hidden_ts = m.hidden_at?;
    let (sig, pk) = (m.hidden_sig.as_deref()?, m.hidden_pk.as_deref()?);
    let signer = super::resolver::resolve(&m.s);
    let lp_digest = super::crypto_handler::backfill_lp_digest(
        m.lp.as_deref(), m.lp_digest.as_deref(),
    );
    let extras = SignedExtras {
        mid: m.mid.as_deref(),
        reply_to: m.reply_to.as_deref(),
        file_id: m.file_id.as_deref(),
        order_us: m.order_us,
        lp_digest: lp_digest.as_deref(),
        album: m.album.as_deref(),
    };
    verify_message_signature_v2(
        &signer, Some(sig), Some(pk), "ch-delete", &format!("{sid}:{cid}"),
        hidden_ts, &extras, &m.t, pk_cache,
    )
    .then_some(hidden_ts)
}

// ── 1. SendMessage (DM) ──────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_send_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    text: String,
    message_id: String,
    reply_to_mid: Option<String>,
    link_preview: Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] SendMessage received for {peer_id_str} mid={message_id}");

    let local_peer = local_peer_str.to_string();
    // Lamport-bumped send stamp (chat_clock.rs), strictly after every message this
    // device has seen, so clock skew cannot sort our reply above the message it
    // answers. The ms `ts` is signed; `order_us` is not, but rides the wire.
    let dm_order_us = crate::chat_clock::next_send_stamp_us();
    let dm_timestamp = dm_order_us / 1000;
    // The v2 signature binds the structured fields exactly as they ride the
    // envelope below, so the receiver reconstructs them from what it persists.
    let lp_digest = link_preview.as_ref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: Some(&message_id),
        reply_to: reply_to_mid.as_deref(),
        file_id: None,
        order_us: Some(dm_order_us),
        lp_digest: lp_digest.as_deref(),
        album: None,
    };
    let (sig, pk) = sign_message_versioned(
        bundle_keypair, pub_key_b64, "dm", &peer_id_str, &local_peer,
        dm_timestamp, &extras, &text,
    );
    let recipient_master = super::resolver::resolve(&peer_id_str);
    let build_dm = |convo: Option<String>| MessageEnvelope::DirectMessage {
        inner: Box::new(DirectMessagePayload {
            text: text.clone(),
            ts: dm_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: Some(message_id.clone()),
            reply_to: reply_to_mid.clone(),
            file_id: None,
            link_preview: link_preview.clone(),
            convo,
            order_us: Some(dm_order_us),
            album: None,
        }),
    };
    let envelope_json = serde_json::to_string(&build_dm(None))
        .unwrap_or_else(|_| text.clone());
    // Sibling self-echo variant carries the recipient master as the conversation
    // key, so our other device files it under the right thread (not under us).
    let sibling_envelope_json = serde_json::to_string(&build_dm(Some(recipient_master.clone())))
        .unwrap_or_else(|_| text.clone());

    // Same Rust-generated timestamp as sent, so DM sync timestamps agree.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.insert(
                &peer_id_str, &text, true, dm_timestamp,
                sig.as_deref(), pk.as_deref(), Some(&message_id),
                reply_to_mid.as_deref(), None, Some(dm_order_us), None,
            );
            if let Some(lp) = &link_preview {
                if let Ok(lp_json) = serde_json::to_string(lp) {
                    let _ = store.update_link_preview(&message_id, &lp_json);
                }
            }
        }
    }

    // ── Multi-device fan-out (Phase 6, Step 3) ──────────────────────────
    // `peer_id_str` is the recipient's MASTER (what the friend list keys on), but
    // Olm sessions, `pending_messages` and room membership are keyed by DEVICE, so
    // encrypting to the bare master would hit no session. An empty device set
    // falls back to the master id, which is the pre-multi-device behaviour.
    //
    // We ALSO fan out to our OWN other online devices, so a DM typed on one device
    // appears live on the sibling; the local insert above already keyed the
    // sending device's UI on the master.
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        Some(&sibling_envelope_json),
    ).await;

    // Hydrate the optimistic Dart entry with sig/pk so the
    // Message Proof dialog shows VERIFIED without a restart.
    let _ = event_tx.send(NetworkEvent::MessageSent {
        to_peer: peer_id_str.clone(),
        message_id: message_id.clone(),
        timestamp: dm_timestamp,
        signature: sig.clone(),
        public_key: pk.clone(),
    }).await;
}

/// Expand a recipient MASTER id into its device set (plus our own siblings for
/// self fan-out) and deliver one already-signed DM envelope to each. A recipient
/// with no ingested device list resolves to an empty set and the master id is used
/// as-is. Used by every DM send path: message, edit, delete, reactions.
///
/// `pending_messages` is keyed per DEVICE, so a queued envelope drains to the
/// right device. The caller owns the local DB write and UI event, both master-keyed.
#[allow(clippy::too_many_arguments)]
async fn fan_out_dm_envelope(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    local_peer_str: &str,
    // THIS device's identity — signs the KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    recipient_master: &str,
    envelope_json: &str,
    // For DirectMessage sends, a variant with `convo` set to `recipient_master`,
    // delivered to OUR OWN siblings so they file the echo under the right
    // conversation. `None` for edit/delete/reaction, which resolve it by mid.
    sibling_envelope_json: Option<&str>,
) {
    // The recipient's devices always get the plain envelope. The target set is the
    // persisted device list UNION the devices CURRENTLY in the DM room that resolve
    // to this master: the live room is authoritative, because a stale or
    // ghost-polluted list would deliver only to a dead id and skip the connected
    // device ("first message lost, peer shows offline").
    let dm_room = dm_room_code(local_peer_str, recipient_master);
    // Self-DM ("Saved messages"): the recipient IS us, so there is no other party
    // and the recipient-branch fallback would queue a dead envelope under the bare
    // master forever. Our own siblings still get their copy below.
    let self_dm = super::resolver::same_identity(local_peer_str, recipient_master);
    let recipient_devices = if self_dm {
        Vec::new()
    } else {
        collect_target_devices(
            ws_room_peers, Some(olm), &dm_room, recipient_master, recipient_master, /*exclude*/ None,
        )
    };
    for device_peer in &recipient_devices {
        send_dm_to_device(
            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
            pending_messages, key_request_in_flight,
            device_keypair, device_peer_id,
            device_peer, envelope_json, &dm_room, /*is_sibling*/ false,
        ).await;
    }

    // Our own siblings get the convo-tagged variant when one is supplied, same
    // live-union logic, excluding THIS device (never echo to ourselves).
    let own_master = super::resolver::resolve(local_peer_str);
    let sibling_json = sibling_envelope_json.unwrap_or(envelope_json);
    // Offline siblings included (#90): backfill alone needs the two devices, or
    // the friend, online at the same time.
    let mut siblings: HashSet<String> = collect_target_devices(
        ws_room_peers, Some(olm), &dm_room, &own_master, "", /*exclude*/ Some(device_peer_id),
    ).into_iter().collect();
    // ALSO union peers in our `inbox:{master}` room. A freshly-linked sibling joins
    // the inbox room immediately but may not have joined this DM room yet when we
    // send our FIRST message, so the DM-room union alone misses it and the echo
    // goes to a stale ghost id from the stored device list.
    let inbox_room = format!("inbox:{own_master}");
    if let Some(peers) = ws_room_peers.get(&inbox_room) {
        for p in peers {
            if p != device_peer_id && super::resolver::resolve(p) == own_master {
                siblings.insert(p.clone());
            }
        }
    }
    siblings.remove(&own_master);
    for sibling in &siblings {
        if recipient_devices.contains(sibling) {
            continue;
        }
        send_dm_to_device(
            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
            pending_messages, key_request_in_flight,
            device_keypair, device_peer_id,
            sibling, sibling_json, &dm_room, /*is_sibling*/ true,
        ).await;
    }
}

/// Build the set of device peer_ids to fan a DM out to for one master identity.
///
/// LIVENESS-FILTERED: a stored device id is targeted ONLY if it is reachable, so
/// it has an Olm session OR is currently in a room. A device list accumulates dead
/// ghost ids across re-link cycles (union-merge never prunes), and without this
/// filter the fan-out either room-sends to them, firing a spurious push and unread
/// on the receiver, or queues a KeyRequest forever. A genuinely offline REAL
/// device has a persisted session and still passes.
///
/// The set is UNIONed with every peer currently in `dm_room` that resolves to
/// `master`, because the live room is always authoritative. `fallback_self` is
/// returned only when the whole set is empty (single-device recipient); pass "" to
/// skip it, which is what self fan-out needs. `exclude` drops our own device.
fn collect_target_devices(
    ws_room_peers: &HashMap<String, HashSet<String>>,
    // When Some, also include OFFLINE-but-real devices: a device in the resolver's
    // signed-list view that we hold an Olm session with, so a fully-quit phone
    // gets a relay-buffered copy. None = live-only.
    olm: Option<&OlmManager>,
    dm_room: &str,
    master: &str,
    fallback_self: &str,
    exclude: Option<&str>,
) -> Vec<String> {
    // Stored devices CURRENTLY IN A ROOM. Room presence is the unambiguous liveness
    // test that drops dead ghosts: `has_session` is NOT liveness, since a ghost has
    // a stale persisted session, and it only qualifies the OFFLINE set below.
    let mut set: HashSet<String> = super::resolver::devices_for(master)
        .into_iter()
        .filter(|d| super::crypto_handler::ws_room_for_peer(ws_room_peers, d).is_some())
        .collect();
    // Offline-but-real devices (Step 9A) — see `offline_session_devices`.
    if let Some(olm) = olm {
        set.extend(offline_session_devices(olm, ws_room_peers, master));
    }
    // Union: peers physically in the DM room that resolve to this master (always
    // included — live presence trumps the stored list, and is reachable by definition).
    set.extend(room_peers_of_master(ws_room_peers, dm_room, master));
    if let Some(ex) = exclude {
        set.remove(ex);
    }
    // Never target the bare master (no device authenticates as it) — except the
    // single-device fallback below, where master == device id by definition.
    set.remove(master);
    if set.is_empty() && !fallback_self.is_empty() {
        return vec![fallback_self.to_string()];
    }
    set.into_iter().collect()
}

/// Offline-but-real devices of one master: a known device NOT in a room that we DO
/// hold an Olm session with. `devices_for` reflects the signed device list minus
/// revoked tombstones, and intersecting with `has_session` drops never-contacted
/// ghosts. These take `send_dm_to_device`'s session+offline branch, so the relay
/// buffers under the device id and pushes its token, and the quit phone's
/// background fetch decrypts the preview. Also the target predicate for the
/// channel-push offline fan-out.
fn offline_session_devices(
    olm: &OlmManager,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    master: &str,
) -> Vec<String> {
    super::resolver::devices_for(master)
        .into_iter()
        .filter(|d| {
            super::crypto_handler::ws_room_for_peer(ws_room_peers, d).is_none()
                && olm.has_session(d)
        })
        .collect()
}

/// Peers currently present in `room` whose identity resolves to `master`.
fn room_peers_of_master(
    ws_room_peers: &HashMap<String, HashSet<String>>,
    room: &str,
    master: &str,
) -> Vec<String> {
    let Some(peers) = ws_room_peers.get(room) else {
        return Vec::new();
    };
    peers
        .iter()
        .filter(|p| super::resolver::resolve(p) == master)
        .cloned()
        .collect()
}

/// Send one already-signed DM envelope to ONE concrete device peer_id: the
/// per-device half of `handle_send_message`, so the master-to-devices loop runs it
/// once per target. `device_peer` is always a real device id (or the master id for
/// a single-device recipient), never a master no device authenticates as.
///
/// Three branches: session + online encrypts and delivers now; session + offline
/// encrypts to the DM room as a push trigger and queues for reconnect; no session
/// queues and fires a KeyRequest.
#[allow(clippy::too_many_arguments)]
async fn send_dm_to_device(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    // THIS device's identity — signs the KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    device_peer: &str,
    envelope_json: &str,
    dm_room: &str,
    // True when `device_peer` is one of OUR OWN siblings rather than the genuine
    // recipient. Online, a sibling is reached through the inbox room instead of
    // the DM room.
    is_sibling: bool,
) {
    // EXACT-device reachability, not the identity-wide `peer_is_reachable`: in a
    // fan-out device A may be online while sibling B is offline, and the
    // identity-wide check would send B's copy down the online path, where
    // `ws_room_for_peer` finds no room for B and DROPS it with no buffering.
    let device_online = super::crypto_handler::ws_room_for_peer(ws_room_peers, device_peer).is_some();

    if !olm.has_session(device_peer) {
        // No session with this device — queue the signed envelope. Drained when
        // the device reconnects (PeerJoined/RoomMembers/KeyBundle).
        queue_dm_key_request(
            ws_cmd_tx, ws_room_peers, pending_messages, key_request_in_flight,
            device_keypair, device_peer_id, device_peer, envelope_json, device_online,
        );
        return;
    }
    if device_online && !is_sibling {
        send_dm_online_recipient(
            olm, crypto_store, event_tx, ws_cmd_tx, pending_messages,
            device_peer, envelope_json, dm_room,
        ).await;
    } else if is_sibling && device_online {
        // Our OWN sibling, online: siblings meet in inbox:{our_master}, NOT
        // dm_room_code(M,M), so route via the flexible `ws_room_for_peer` lookup.
        // A sibling shares only the inbox room with us, so it is unambiguous.
        send_encrypted_message(
            olm, crypto_store, device_peer, envelope_json,
            event_tx, ws_cmd_tx, ws_room_peers,
        ).await;
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    } else {
        // Offline: the relay buffers the copy and replays it when the device joins
        // the DM room. For a genuine recipient that deposit is also the push
        // trigger; an offline SIBLING's phone lists our devices on the relay's
        // `~dm` no-push filter, so our own message never wakes it.
        send_dm_offline_recipient(olm, crypto_store, ws_cmd_tx, device_peer, envelope_json, dm_room);
        // Also queue for when this device comes back online (push may fail).
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    }
}

/// Genuine recipient device, online: encrypt into the DETERMINISTIC DM room the
/// caller computed, NOT a `ws_room_for_peer` lookup. When the recipient's device
/// is co-present in more than one of our rooms, the first-match lookup can pick a
/// room they have since left, and the relay then buffers the frame against a room
/// they never rejoin: the one-way DM bug, where sends "succeed" but never arrive.
/// Every device of the FRIEND is a member of dm_room.
///
/// Siblings never take this path: they meet in inbox:{our_master} instead.
#[allow(clippy::too_many_arguments)]
async fn send_dm_online_recipient(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    device_peer: &str,
    envelope_json: &str,
    dm_room: &str,
) {
    match encrypt_dm_wire(olm, crypto_store, device_peer, envelope_json, /*log_prekey*/ true) {
        Ok(json) => {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: dm_room.to_string(),
                target_peer: device_peer.to_string(),
                data: json.into_bytes(),
            });
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: device_peer.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
        }
    }
    // ALSO queue for re-delivery on the next session (re)establishment.
    // The relay never ACKs a direct message, and a session we believe is confirmed
    // can be silently dead on the PEER's side, which is acute right after a device
    // link. A DM encrypted on that doomed ratchet is undecryptable and, without
    // this queue, lost forever. The re-key path, PeerJoined and KeyBundle all drain
    // it on a FRESH session, and the receiver dedups by `message_id`. Capped per
    // device, so a long-lived healthy session cannot grow it unbounded.
    const RETRY_QUEUE_CAP: usize = 20;
    let q = pending_messages.entry(device_peer.to_string()).or_default();
    q.push(envelope_json.to_string());
    if q.len() > RETRY_QUEUE_CAP {
        let overflow = q.len() - RETRY_QUEUE_CAP;
        q.drain(0..overflow);
    }
}

/// Session exists but the recipient device is offline: encrypt and send to the DM
/// room anyway, so the relay sees the target is absent and triggers a push. The
/// room is the MASTER-pair room the caller computed and must NOT be recomputed
/// from `device_peer`, which would key the room on a device id.
fn send_dm_offline_recipient(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    device_peer: &str,
    envelope_json: &str,
    dm_room: &str,
) {
    match encrypt_dm_wire(olm, crypto_store, device_peer, envelope_json, /*log_prekey*/ false) {
        Ok(json) => {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: dm_room.to_string(),
                target_peer: device_peer.to_string(),
                data: json.into_bytes(),
            });
            hollow_log!("[HOLLOW-PUSH] Sent encrypted DM to offline {device_peer} via DM room (push trigger)");
        }
        Err(e) => {
            hollow_log!("[HOLLOW-PUSH] Encrypt for offline {device_peer} failed: {e}");
        }
    }
}

/// Encrypt one signed DM envelope to one device's Olm session and wrap it as
/// `HavenMessage::Encrypted` wire JSON. Persists the ratcheted session on
/// success only (encrypt failure leaves the stored session untouched).
fn encrypt_dm_wire(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    device_peer: &str,
    envelope_json: &str,
    log_prekey: bool,
) -> Result<String, String> {
    let (msg_type, ciphertext) = olm
        .encrypt(device_peer, envelope_json.as_bytes())
        .map_err(|e| e.to_string())?;
    super::crypto_handler::persist_olm_session(olm, crypto_store, device_peer);
    if log_prekey && msg_type == 0 {
        hollow_log!("[HOLLOW-CRYPTO] Sending PreKey (type 0) to {device_peer}");
    }
    let haven_msg = super::crypto_handler::encrypted_frame(olm, msg_type, &ciphertext);
    Ok(serde_json::to_string(&haven_msg).unwrap_or_default())
}

/// Queue one signed envelope under a DEVICE id for silent re-delivery on that
/// device's next session (re)establishment / reconnect drain.
fn queue_pending_envelope(
    pending_messages: &mut HashMap<String, Vec<String>>,
    device_peer: &str,
    envelope_json: &str,
) {
    pending_messages
        .entry(device_peer.to_string())
        .or_default()
        .push(envelope_json.to_string());
}

/// No Olm session with this device — queue the signed envelope (drained on
/// PeerJoined/RoomMembers/KeyBundle) and fire a throttled KeyRequest.
#[allow(clippy::too_many_arguments)]
fn queue_dm_key_request(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    // THIS device's identity — signs the KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    device_peer: &str,
    envelope_json: &str,
    device_online: bool,
) {
    queue_pending_envelope(pending_messages, device_peer, envelope_json);

    let req_fresh = key_request_in_flight
        .get(device_peer)
        .is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(10));
    if !req_fresh {
        hollow_log!("[HOLLOW-SWARM] No session for {device_peer}, sending KeyRequest");
        // Only mark in-flight if we actually sent it — exact-device presence
        // gates the send, so don't strand the timestamp on an offline device.
        if device_online {
            send_message_to_peer(
                ws_cmd_tx, ws_room_peers,
                device_peer,
                super::crypto_handler::signed_key_request(
                    device_keypair, device_peer_id, device_peer,
                ),
            );
            key_request_in_flight.insert(device_peer.to_string(), std::time::Instant::now());
        }
    }
}

// ── 2. SendChannelMessage ────────────────────────────────────────────

pub(crate) async fn handle_send_channel_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    text: String,
    message_id: String,
    reply_to_mid: Option<String>,
    link_preview: Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] SendChannelMessage for channel {channel_id} in server {server_id} mid={message_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    // Posting permission + moderation trio gates (mute / media-only / slow mode).
    // Receivers drop violations too — these are the cooperative-client fast-fail path.
    if let Some(message) = channel_send_gate_error(
        server, local_peer_str, &server_id, &channel_id, db_path, db_passphrase,
    ).await {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();

    // Lamport-bumped send stamp — see the DM send / chat_clock.rs.
    let order_us = crate::chat_clock::next_send_stamp_us();
    let timestamp = order_us / 1000;

    // The v2 signature binds the structured fields as they ride BOTH wire forms:
    // the MLS envelope and the public-channel plaintext both carry
    // mid/reply_to/link_preview/order_us.
    let lp_digest = link_preview.as_ref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: Some(&message_id),
        reply_to: reply_to_mid.as_deref(),
        file_id: None,
        order_us: Some(order_us),
        lp_digest: lp_digest.as_deref(),
        album: None,
    };
    let (sig, pk) = sign_message_versioned(
        bundle_keypair, pub_key_b64, "ch", &format!("{}:{}", server_id, channel_id),
        &local_peer, timestamp, &extras, &text,
    );

    // Mention metadata — shared by the notification hint and the offline push
    // fan-out below.
    let (has_everyone, mentioned_names) = channel_mention_meta(&text);

    // Wire bytes as broadcast to the room, re-delivered to OFFLINE members via
    // targeted 0x09 frames. The MLS ciphertext or signed plaintext is decryptable
    // by any member, so one encryption serves both paths. None on the legacy Olm
    // fan-out, where pairwise sessions cannot pre-encrypt without burning ratchets.
    let offline_wire_bytes: Option<Vec<u8>> = if server.is_channel_public(&channel_id) {
        // Public channels: plaintext broadcast (no MLS/Olm). Guests receive it too.
        let msg = HavenMessage::PublicChannelMessage {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            text: text.clone(),
            ts: timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: message_id.clone(),
            reply_to: reply_to_mid.clone(),
            file_id: None,
            link_preview: link_preview.clone(),
            order_us: Some(order_us),
            album: None,
            file_meta: None,
        };
        send_public_channel_msg(ws_cmd_tx, server, &channel_id, &msg)
    } else {
        let envelope = MessageEnvelope::ChannelMessage {
            inner: Box::new(ChannelMessagePayload {
                sid: server_id.clone(),
                cid: channel_id.clone(),
                text: text.clone(),
                ts: timestamp,
                sig: sig.clone(),
                pk: pk.clone(),
                mid: Some(message_id.clone()),
                reply_to: reply_to_mid.clone(),
                file_id: None,
                link_preview: link_preview.clone(),
                order_us: Some(order_us),
                album: None,
            }),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await
    };

    // Replied-to message's author (MASTER id, from our own store) — shared by
    // the room hint and the offline push fan-out so mentions-only receivers can
    // gate on "reply to ME", not "reply to anyone" (#42). One store open.
    let reply_author: Option<String> = reply_to_mid.as_deref().and_then(|mid| {
        crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()
            .and_then(|s| s.get_channel_message_sender(mid))
    });

    // The notification hint reaches every member, subscribed to the channel or not:
    // over MLS to the whole room, plus an Olm copy to the devices that hold no leaf.
    {
        let restricted = server.channel_uses_subgroup(&channel_id);
        let group = restricted.then_some(channel_id.as_str());
        if mls.as_ref().is_some_and(|m| m.has_group(&group.map_or_else(|| server_id.clone(), |c| crate::crypto::subgroup_id(&server_id, c)))) {
            let envelope = MessageEnvelope::ChannelHint {
                sid: server_id.clone(),
                cid: channel_id.clone(),
                mid: message_id.clone(),
                has_everyone,
                mentioned_names: mentioned_names.clone(),
                reply_to_sender: reply_author.clone(),
            };
            if let Err(e) = super::crypto_handler::send_mls_broadcast_in(
                mls.as_mut().unwrap(), ws_cmd_tx, &server_id, group, &envelope, crypto_store,
            ) {
                hollow_log!("[HOLLOW-MLS] Channel hint broadcast failed: {e}");
            }
        }
        let leafless = match group {
            Some(cid) => super::crypto_handler::leafless_member_devices_where(
                mls, &crate::crypto::subgroup_id(&server_id, cid), server, ws_room_peers, local_peer_str,
                |m| server.can_see_channel(m, cid),
            ),
            None => super::crypto_handler::leafless_member_devices(
                mls, &server_id, server, ws_room_peers, local_peer_str,
            ),
        };
        let hint = HavenMessage::ChannelNotificationHint {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            message_id: message_id.clone(),
            has_everyone,
            mentioned_names: mentioned_names.clone(),
            is_reply: reply_to_mid.is_some(),
            reply_to_sender: reply_author.clone(),
        };
        if let Some(json) = super::olm_lane::carried_json(&hint) {
            for dev in &leafless {
                super::olm_lane::carry_json(ws_cmd_tx, dev, None, json.clone(), super::olm_lane::NoSession::Drop);
            }
        }
    }

    // ── Offline-member push fan-out (channel push notifications) ─────────
    queue_offline_channel_push(
        olm, ws_cmd_tx, ws_room_peers, server, local_peer_str,
        &server_id, &channel_id, reply_author.as_deref(),
        has_everyone, &mentioned_names, &offline_wire_bytes,
    );

    // Persist locally with same timestamp as sent.
    persist_sent_channel_message(
        &server_id, &channel_id, &local_peer, &text, timestamp,
        sig.as_deref(), pk.as_deref(), &message_id,
        reply_to_mid.as_deref(), order_us, &link_preview,
        db_path, db_passphrase,
    );

    // Hydrate the optimistic Dart entry with sig/pk so the
    // Message Proof dialog shows VERIFIED without a restart.
    let _ = event_tx.send(NetworkEvent::ChannelMessageSent {
        server_id: server_id.clone(),
        channel_id: channel_id.clone(),
        message_id: message_id.clone(),
        timestamp,
        signature: sig.clone(),
        public_key: pk.clone(),
    }).await;
}

/// Cooperative-client fast-fail gates for a channel send: posting permission plus
/// the moderation trio. Receivers drop violations too. Returns the user-facing
/// error for the FIRST failed gate. Async, because the slow-mode check reads the
/// store on the blocking pool (SQLCipher key derivation must not stall the loop).
async fn channel_send_gate_error(
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    if !server.can_post_in_channel(local_peer_str, channel_id) {
        return Some("You don't have permission to post in this channel".to_string());
    }
    if let Some(message) = muted_send_error(server, local_peer_str) {
        return Some(message);
    }
    if server.is_channel_media_only(channel_id) {
        // Standalone text is rejected; captions ride the file send path.
        return Some("This is a media-only channel. Attach an image, GIF, or video".to_string());
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    slow_mode_wait_error(
        server, local_peer_str, server_id, channel_id,
        now_ms, db_path, db_passphrase,
    ).await
}

/// Send-side mute gate (master-keyed, lazy expiry): `Some(error)` when we are
/// muted on this server. Shared by the new-message, edit and add-reaction paths.
/// Deletes and reaction removals are deliberately NOT gated, because removing your
/// own content is always allowed, and slow mode never applies to them.
fn muted_send_error(server: &ServerState, local_peer_str: &str) -> Option<String> {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if server.is_muted(local_peer_str, now_ms) {
        return Some("You are muted on this server".to_string());
    }
    None
}

/// Slow-mode half of the send gates: an error when our own latest message in the
/// channel is still inside the window. The Mod+ exemption short-circuits BEFORE
/// any store access; the open and query hop onto the blocking pool.
async fn slow_mode_wait_error(
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    now_ms: i64,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    let slow = server.channel_slow_mode(channel_id);
    if slow == 0 || server.bypasses_slow_mode(local_peer_str) {
        return None;
    }
    let last_ts = latest_own_channel_ts_blocking(server_id, channel_id, db_path, db_passphrase).await?;
    let next_allowed = last_ts + (slow as i64) * 1000;
    if now_ms < next_allowed {
        let wait_s = ((next_allowed - now_ms) + 999) / 1000;
        return Some(format!("Slow mode is on. Wait {wait_s}s before sending again"));
    }
    None
}

/// Our own latest message ts in a channel, read on the blocking pool with owned
/// captures: the store is created and dropped inside the closure, because a
/// rusqlite `Connection` is !Sync and must never be held across an await. A
/// store-open failure returns `None`, so the gate allows.
pub(crate) async fn latest_own_channel_ts_blocking(
    server_id: &str,
    channel_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<i64> {
    let sid = server_id.to_string();
    let cid = channel_id.to_string();
    let path = db_path.to_string();
    let pass = db_passphrase.to_string();
    tokio::task::spawn_blocking(move || {
        let store = crate::storage::MessageStore::open(&path, &pass).ok()?;
        store.latest_own_channel_ts(&sid, &cid)
    })
    .await
    .ok()
    .flatten()
}

/// Mention metadata for one outgoing channel message: (`has_everyone`,
/// mentioned @names minus "everyone").
fn channel_mention_meta(text: &str) -> (bool, Vec<String>) {
    let has_at = text.contains('@');
    let has_everyone = has_at && text.contains("@everyone");
    let mut mentioned_names: Vec<String> = Vec::new();
    if has_at {
        for word in text.split_whitespace() {
            if let Some(name) = word.strip_prefix('@') {
                if !name.is_empty() && name != "everyone" {
                    mentioned_names.push(name.to_string());
                }
            }
        }
    }
    (has_everyone, mentioned_names)
}

/// Serialize and broadcast one public-channel `HavenMessage` to the server room
/// (plaintext, still Ed25519-signed; guests receive it too). Returns the wire
/// bytes for the offline 0x09 push fan-out.
///
/// Sent TWICE on purpose, and the second copy is what reaches a member who was
/// away: the room broadcast is for guests, who never subscribe to a channel topic,
/// but the relay only tees a 0x07 TOPIC frame into a channel's catch-up ring. Both
/// copies are the same signed bytes, and every ingest pre-checks
/// `channel_message_exists(mid)`, so a member receiving both stores one row and
/// the second arrival is emitted with `duplicate`.
pub(crate) fn send_public_channel_msg(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server: &ServerState,
    channel_id: &str,
    msg: &HavenMessage,
) -> Option<Vec<u8>> {
    let data = serde_json::to_vec(msg).ok()?;
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server.server_id.clone(),
        data: data.clone(),
    });
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server.server_id.clone(),
        topic: super::ring_auth::topic(server, channel_id),
        data: data.clone(),
    });
    Some(data)
}

/// Broadcast one non-public channel envelope to the server. MLS path: encrypt once
/// into a single WS topic broadcast; restricted channels encrypt under their own
/// per-channel subgroup. Olm per-device fan-out is the fallback on MLS failure and
/// the pre-bootstrap path. Returns the MLS wire bytes for the offline 0x09 fan-out
/// when the MLS broadcast succeeded. `bootstrap_subgroup` also kicks off subgroup
/// bootstrap on the no-group path, because a client that only edits or reacts must
/// still escape the Olm fallback. Shared driver for send, edit, delete and both
/// reaction ops.
#[allow(clippy::too_many_arguments)]
async fn broadcast_channel_envelope(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    envelope: &MessageEnvelope,
    mls_fail_log: &str,
    bootstrap_subgroup: bool,
) -> Option<Vec<u8>> {
    let use_subgroup = server.channel_uses_subgroup(channel_id);
    let group_key = if use_subgroup {
        crate::crypto::subgroup_id(server_id, channel_id)
    } else {
        server_id.to_string()
    };
    let use_mls = mls.as_ref().is_some_and(|m| m.has_group(&group_key));
    if use_mls {
        let ring = super::ring_auth::topic(server, channel_id);
        match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, server_id, channel_id, &ring, use_subgroup, envelope, crypto_store) {
            Ok(wire_bytes) => return Some(wire_bytes),
            Err(e) => {
                hollow_log!("[HOLLOW-MLS] {mls_fail_log}: {e}");
                let envelope_json = serde_json::to_string(envelope).unwrap_or_default();
                olm_fanout_channel_envelope(
                    olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
                    server, local_peer_str, channel_id, use_subgroup, &envelope_json,
                ).await;
            }
        }
        return None;
    }
    // Subgroup not bootstrapped (or a legacy server with no MLS group): Olm fan-out
    // to qualifying members, and for a restricted channel send our KeyPackage to
    // the subgroup coordinator so future messages can use it.
    if bootstrap_subgroup && use_subgroup {
        if let Some(mls_mgr) = mls.as_mut() {
            super::crypto_handler::request_subgroup_bootstrap(
                mls_mgr, crypto_store, ws_cmd_tx, ws_room_peers, server,
                server_id, channel_id, local_peer_str,
            );
        }
    }
    let envelope_json = serde_json::to_string(envelope).unwrap_or_default();
    olm_fanout_channel_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        server, local_peer_str, channel_id, use_subgroup, &envelope_json,
    ).await;
    None
}

/// Olm fan-out of one channel envelope JSON to every qualifying server member.
/// Olm is per-device: encrypt to EACH online device of the member. Subgroup
/// channels only fan to members who can see the channel.
#[allow(clippy::too_many_arguments)]
async fn olm_fanout_channel_envelope(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &ServerState,
    local_peer_str: &str,
    channel_id: &str,
    use_subgroup: bool,
    envelope_json: &str,
) {
    for member_peer_str in server.members.keys() {
        if super::resolver::same_identity(member_peer_str, local_peer_str) { continue; }
        // Subgroup: only fan to members who qualify for the channel.
        if use_subgroup && !server.can_see_channel(member_peer_str, channel_id) { continue; }
        for dev in crate::node::crypto_handler::online_devices_for(ws_room_peers, member_peer_str) {
            send_encrypted_message(
                olm, crypto_store,
                &dev, envelope_json,
                event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
        }
    }
}

/// Offline-member push fan-out. Room and topic broadcasts only reach ONLINE peers,
/// so each offline member gets one targeted 0x09 frame: the same wire bytes the
/// room received, plus the channel and a per-target mention flag the relay filters
/// against that member's registered prefs. The relay never learns server
/// membership, because the SENDER picks the targets from its CRDT. Sync, and may
/// open the `MessageStore` for the reply-author lookup.
#[allow(clippy::too_many_arguments)]
fn queue_offline_channel_push(
    olm: &OlmManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &ServerState,
    local_peer_str: &str,
    server_id: &str,
    channel_id: &str,
    reply_author: Option<&str>,
    has_everyone: bool,
    mentioned_names: &[String],
    offline_wire_bytes: &Option<Vec<u8>>,
) {
    // `server.members` is MASTER-keyed (Step 6). Pick masters who are NOT
    // reachable by ANY of their devices, and who aren't us.
    let offline_members: Vec<&String> = server.members.keys()
        .filter(|p| {
            !super::resolver::same_identity(p, local_peer_str)
                && !peer_is_reachable(ws_room_peers, p)
                // Restricted channel (Option B): only members who can see the
                // channel get the ciphertext + push (others can't decrypt it).
                && server.can_see_channel(p, channel_id)
        })
        .collect();
    if offline_members.is_empty() {
        return;
    }
    hollow_log!(
        "[HOLLOW-PUSH] Channel push fan-out: {} offline member(s) for {}/{}",
        offline_members.len(), server_id, channel_id
    );
    for member in offline_members {
        let mentioned = member_is_mentioned(
            server, member, has_everyone, reply_author, mentioned_names,
        );
        // Expand the offline MASTER member into its real DEVICE ids: the relay
        // keys the push token and offline buffer by DEVICE, so targeting the bare
        // master buffers under an id no device authenticates as. The predicate
        // mirrors `offline_session_devices`. A single-device member falls back to
        // the master id, which IS that member's device id.
        let mut targets = offline_session_devices(olm, ws_room_peers, member);
        if targets.is_empty() {
            targets.push(member.clone());
        }
        for target in targets {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendChannelDirect {
                room_code: server_id.to_string(),
                target_peer: target,
                channel_id: channel_id.to_string(),
                mention: mentioned,
                data: offline_wire_bytes.clone().unwrap_or_default(),
            });
        }
    }
}

/// The receiver's own reading of whether a channel post mentions `member`, with
/// the rule the sender uses for its push flag. A woken device judges by this,
/// never by the flag.
pub(crate) fn post_mentions_member(
    server: &ServerState,
    member: &str,
    text: &str,
    reply_author: Option<&str>,
) -> bool {
    let (has_everyone, mentioned_names) = channel_mention_meta(text);
    member_is_mentioned(server, member, has_everyone, reply_author, &mentioned_names)
}

/// Mention flag per MEMBER (master) for the channel push: @everyone, a reply to
/// their message, or their display name / nickname mentioned.
fn member_is_mentioned(
    server: &ServerState,
    member: &str,
    has_everyone: bool,
    reply_author: Option<&str>,
    mentioned_names: &[String],
) -> bool {
    has_everyone
        || reply_author == Some(member)
        || (!mentioned_names.is_empty() && {
            let display = server.members.get(member)
                .map(|m| m.display_name.as_str())
                .unwrap_or("");
            let nick = server.nicknames.get(member).map(|n| n.read().as_str());
            mentioned_names.iter().any(|n| {
                (!display.is_empty() && n.eq_ignore_ascii_case(display))
                    || nick.is_some_and(|nk| n.eq_ignore_ascii_case(nk))
            })
        })
}

/// Persist our own outgoing channel message locally with the same signed
/// timestamp we sent (no Dart DateTime.now() mismatch). Sync — owns the store.
#[allow(clippy::too_many_arguments)]
fn persist_sent_channel_message(
    server_id: &str,
    channel_id: &str,
    local_peer: &str,
    text: &str,
    timestamp: i64,
    sig: Option<&str>,
    pk: Option<&str>,
    message_id: &str,
    reply_to_mid: Option<&str>,
    order_us: i64,
    link_preview: &Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let _ = store.insert_channel_message(
        server_id, channel_id, local_peer, text, true, timestamp,
        sig, pk, Some(message_id),
        reply_to_mid, None, Some(order_us), None,
    );
    if let Some(lp) = link_preview {
        if let Ok(lp_json) = serde_json::to_string(lp) {
            let _ = store.update_channel_link_preview(message_id, &lp_json);
        }
    }
}

// ── 3. EditChannelMessage ────────────────────────────────────────────

pub(crate) async fn handle_edit_channel_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    new_text: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] EditChannelMessage {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    // Moderation gate: mute blocks edits exactly like the new-message send gate,
    // and receivers drop a muted member's edits too. Deletes stay allowed, and
    // slow mode / media-only do not apply to edits.
    if let Some(message) = muted_send_error(server, local_peer_str) {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();
    let edit_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the edit over the EDIT timestamp and new text, binding the row's
    // structural fields so receivers verify against the same extras their own row
    // carries. Updated in the same open, which preserves the old text.
    let mut sig = None;
    let mut pk = None;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let row = RowExtras::load_channel(&store, &message_id);
            (sig, pk) = sign_message_versioned(
                bundle_keypair, pub_key_b64, "ch",
                &format!("{}:{}", server_id, channel_id),
                &local_peer, edit_timestamp, &row.as_signed(&message_id), &new_text,
            );
            let _ = store.edit_channel_message(
                &message_id, &new_text, edit_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelEdit {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), text: new_text.clone(),
            ts: edit_timestamp, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, server, &channel_id, &msg);
    } else {
        let envelope = MessageEnvelope::EditMessage {
            mid: message_id.clone(),
            text: new_text.clone(),
            ts: edit_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Edit encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
        server_id,
        channel_id,
        message_id,
        new_text,
        edited_at: edit_timestamp,
        signature: sig,
        public_key: pk,
    }).await;
}

// ── 4. EditDmMessage ─────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_edit_dm_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    new_text: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] EditDmMessage {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();
    let edit_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the edit over the EDIT timestamp and new text, binding the full row
    // rather than just the mid: that is what keeps `rewrite_pending_dm_edits`
    // verifying, since the queued envelope keeps the original
    // mid/reply_to/order_us/link_preview the receiver verifies against.
    let mut sig = None;
    let mut pk = None;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let row = RowExtras::load_dm(&store, &message_id);
            (sig, pk) = sign_message_versioned(
                bundle_keypair, pub_key_b64, "dm", &peer_id_str,
                &local_peer, edit_timestamp, &row.as_signed(&message_id), &new_text,
            );
            let _ = store.edit_dm_message(
                &message_id, &new_text, edit_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Update any queued pending message so a later drain sends the edited text.
    // The original was queued PER DEVICE, under device ids rather than the master,
    // so scan every queue.
    rewrite_pending_dm_edits(pending_messages, &message_id, &new_text, edit_timestamp, &sig, &pk);

    let envelope = MessageEnvelope::EditMessage {
        mid: message_id.clone(),
        text: new_text.clone(),
        ts: edit_timestamp,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Deliver the edit to every device of the recipient and our own siblings. A
    // device with no session yet gets the edited conversation via backfill.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    // Include sig/pk so the in-memory message matches the canonical payload. The
    // DM thread key is the peer's MASTER id (no-op single-device).
    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        new_text,
        edited_at: edit_timestamp,
        signature: sig,
        public_key: pk,
    }).await;
}

/// Rewrite every queued copy of an edited DM across ALL per-device pending queues,
/// so a later drain sends the edited text rather than the stale original.
fn rewrite_pending_dm_edits(
    pending_messages: &mut HashMap<String, Vec<String>>,
    message_id: &str,
    new_text: &str,
    edit_timestamp: i64,
    sig: &Option<String>,
    pk: &Option<String>,
) {
    for queued in pending_messages.values_mut() {
        for entry in queued.iter_mut() {
            rewrite_pending_entry_if_edited(entry, message_id, new_text, edit_timestamp, sig, pk);
        }
    }
}

/// Replace ONE queued envelope's text in place when it is the DirectMessage
/// being edited. Preserves the original `order_us` (ordering unchanged on edit).
fn rewrite_pending_entry_if_edited(
    entry: &mut String,
    message_id: &str,
    new_text: &str,
    edit_timestamp: i64,
    sig: &Option<String>,
    pk: &Option<String>,
) {
    let Ok(env) = serde_json::from_str::<MessageEnvelope>(entry) else {
        return;
    };
    let MessageEnvelope::DirectMessage { inner } = env else {
        return;
    };
    if inner.mid.as_deref() != Some(message_id) {
        return;
    }
    let updated = MessageEnvelope::DirectMessage {
        inner: Box::new(DirectMessagePayload {
            text: new_text.to_string(),
            ts: edit_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: inner.mid.clone(),
            reply_to: inner.reply_to.clone(),
            file_id: inner.file_id.clone(),
            link_preview: inner.link_preview.clone(),
            convo: inner.convo.clone(),
            order_us: inner.order_us, // preserve original ordering on edit
            album: inner.album.clone(),
        }),
    };
    if let Ok(json) = serde_json::to_string(&updated) {
        *entry = json;
        hollow_log!("[HOLLOW-SWARM] Updated pending message {message_id} with edited text");
    }
}

// ── 4b. AttachChannelLinkPreview / AttachDmLinkPreview (issue #45) ───
//
// A card that arrives AFTER its message was sent: the compose box fetches OG
// metadata while the user types, and sending before it landed used to bin it.
//
// Emphatically NOT an edit: the text is untouched, `edited_at` stays null and no
// "(edited)" badge appears. What it shares with an edit is the signature
// obligation, because the v2 payload binds `lp_digest`, so every attach re-signs
// the WHOLE payload with the new digest and ships that signature with the card.

/// The re-signature for an attach, plus the row facts the caller needs to
/// broadcast it. `None` = the row is missing, so there is nothing to attach.
struct AttachSig {
    /// The timestamp the signature binds: the row's `edited_at` when it has one,
    /// else its original `timestamp`. Must match what every verifier reconstructs,
    /// or the row goes unverified the moment a card lands on it.
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
}

/// Re-sign message `mid` for a preview change. `msg_type`/`context` are the same
/// discriminators the original send used, and `row` is the CURRENT row, so the
/// only thing that moves is the link-preview digest.
#[allow(clippy::too_many_arguments)]
fn sign_attached_preview(
    row: &crate::storage::messages::MessageSigRow,
    preview: Option<&LinkPreviewRef>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    msg_type: &str,
    context: &str,
    signer: &str,
    mid: &str,
) -> AttachSig {
    let lp_digest = preview.map(link_preview_digest);
    let extras = SignedExtras {
        mid: Some(mid),
        reply_to: row.reply_to_mid.as_deref(),
        file_id: row.file_id.as_deref(),
        order_us: row.order_us,
        lp_digest: lp_digest.as_deref(),
        album: row.album_id.as_deref(),
    };
    let ts = row.edited_at.unwrap_or(row.timestamp);
    let (sig, pk) = sign_message_versioned(
        bundle_keypair, pub_key_b64, msg_type, context, signer, ts, &extras, &row.text,
    );
    AttachSig { ts, sig, pk }
}

/// Serialize a preview for the `link_preview_json` column. `None` clears it.
fn preview_column(preview: Option<&LinkPreviewRef>) -> Option<String> {
    preview.and_then(|lp| serde_json::to_string(lp).ok())
}

/// The conversation a change names, and the principal its signature proves.
pub(crate) enum RowScope<'a> {
    /// `signer` = the change's verified author.
    Channel { sid: &'a str, cid: &'a str, signer: &'a str },
    /// `convo` = the conversation master; `is_mine` = OUR direction for the change,
    /// which already picked the signer it verified against.
    Dm { convo: &'a str, is_mine: bool },
}

/// Whether a verified change, synced or live, may land on the row its `mid`
/// names. A signature proves who wrote the CHANGE, never that the row it lands on
/// is theirs, so an existing row changes only when it sits in the change's channel
/// or conversation and its author is the change's signer. `true` when there is no
/// row.
///
/// A channel row's author is its sender collapsed to the master, or the key its
/// stored signature names: a row wedged under an unresolvable device id still
/// carries its author's key, which is what lets the sender repair converge it.
pub(crate) fn change_may_touch_row(
    store: &crate::storage::MessageStore,
    scope: &RowScope<'_>,
    mid: Option<&str>,
) -> bool {
    let Some(mid) = mid else { return true };
    let allowed = match *scope {
        RowScope::Channel { sid, cid, signer } => {
            let Some(row) = store.get_channel_message_owner(mid) else { return true };
            row.server_id == sid
                && row.channel_id == cid
                && (super::resolver::same_identity(&row.sender_id, signer)
                    || row.public_key.as_deref().and_then(peer_id_of_public_key).as_deref()
                        == Some(super::resolver::resolve(signer).as_str()))
        }
        RowScope::Dm { convo, is_mine } => {
            let Some(row_is_mine) = store.get_dm_message_is_mine(mid) else { return true };
            let row_convo = store.get_dm_message_peer(mid).unwrap_or_default();
            row_is_mine == is_mine && super::resolver::resolve(&row_convo) == convo
        }
    };
    if !allowed {
        hollow_log!("[HOLLOW-SECURITY] REJECTED change to {mid}: the row belongs to another author or conversation");
    }
    allowed
}

/// Who must have signed a LIVE change to an existing DM row, under which context,
/// and the conversation the row is filed under.
pub(crate) struct LiveDmChange {
    pub signer: String,
    pub ctx: String,
    pub convo: String,
}

/// The [`LiveDmChange`] for DM row `mid` arriving from device `sender`. `None` =
/// no such row, or not the sender's to change: a friend changes only its own
/// messages in its conversation with us, and our own sibling only ours.
pub(crate) fn live_dm_change(
    store: &crate::storage::MessageStore,
    mid: &str,
    sender: &str,
    local_master: &str,
) -> Option<LiveDmChange> {
    let convo = super::resolver::resolve(&store.get_dm_message_peer(mid)?);
    let from_sibling = super::resolver::same_identity(sender, local_master);
    // A blocked identity's edits, cards and deletions are dropped like its messages.
    if !from_sibling && super::blocklist::is_blocked(sender) {
        return None;
    }
    let named = if from_sibling { convo.clone() } else { super::resolver::resolve(sender) };
    if !change_may_touch_row(store, &RowScope::Dm { convo: &named, is_mine: from_sibling }, Some(mid)) {
        return None;
    }
    Some(if from_sibling {
        LiveDmChange { signer: local_master.to_string(), ctx: convo.clone(), convo }
    } else {
        LiveDmChange { signer: convo.clone(), ctx: local_master.to_string(), convo }
    })
}

/// Whether a LIVE channel reaction may attach to `mid`: only to a row we hold in
/// the channel it names. A reaction that outruns its row is dropped; sync carries
/// it with the row.
pub(crate) fn channel_reaction_target_ok(
    store: &crate::storage::MessageStore,
    mid: &str,
    sid: &str,
    cid: &str,
) -> bool {
    let ok = store
        .get_channel_message_owner(mid)
        .is_some_and(|row| row.server_id == sid && row.channel_id == cid);
    if !ok {
        hollow_log!("[HOLLOW-SECURITY] REJECTED reaction on {mid}: no such row in {sid}/{cid}");
    }
    ok
}

/// Whether a LIVE DM reaction from `reactor` may attach to `mid`: only to a row of
/// the reactor's conversation with us, in either direction, or to any DM row when
/// the reactor is our own sibling.
pub(crate) fn dm_reaction_target_ok(
    store: &crate::storage::MessageStore,
    mid: &str,
    reactor: &str,
    local_master: &str,
) -> bool {
    let ok = store.get_dm_message_peer(mid).is_some_and(|peer| {
        super::resolver::same_identity(reactor, local_master)
            || (super::resolver::same_identity(&peer, reactor) && !super::blocklist::is_blocked(reactor))
    });
    if !ok {
        hollow_log!("[HOLLOW-SECURITY] REJECTED DM reaction on {mid} from {reactor}: not a row of that conversation");
    }
    ok
}

fn peer_id_of_public_key(pk_b64: &str) -> Option<String> {
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::STANDARD.decode(pk_b64).ok()?;
    crate::identity::native_identity::NativeKeypair::peer_id_from_pubkey_protobuf(&bytes)
}

/// Land the card riding a VERIFIED sync item on its row.
///
/// Backfill used to carry only `lp_digest`, so a peer offline when a card was
/// attached received a message whose signature bound a preview it had no copy of,
/// and re-serving that row computed `lp_digest = None`, which every downstream
/// peer then rejected as forged.
///
/// Card and signature are written TOGETHER because the pair is inseparable: a card
/// grafted on without the signature covering it is exactly the row that used to
/// break. Guarded on the item's text matching the row's, since that signature only
/// speaks for the text it was made over. Returns true when the card landed.
pub(crate) fn apply_synced_link_preview(
    store: &crate::storage::MessageStore,
    is_channel: bool,
    mid: &str,
    item_text: &str,
    lp: &LinkPreviewRef,
    sig: Option<&str>,
    pk: Option<&str>,
) -> bool {
    let row = if is_channel {
        store.get_channel_message_sig_row(mid)
    } else {
        store.get_dm_message_sig_row(mid)
    };
    let Some(row) = row else { return false };
    if row.text != item_text {
        return false;
    }
    // Already exactly this card (the common case on every re-sync) — skip the
    // write and the event rather than repaint for nothing.
    if row.link_preview.as_ref() == Some(lp) {
        return false;
    }
    let Some(lp_json) = preview_column(Some(lp)) else { return false };
    let applied = if is_channel {
        store.update_channel_link_preview_and_sig(mid, Some(&lp_json), sig, pk, None)
    } else {
        store.update_link_preview_and_sig(mid, Some(&lp_json), sig, pk, None)
    };
    matches!(applied, Ok(true))
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_attach_channel_link_preview(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    preview: Option<Box<LinkPreviewRef>>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] AttachChannelLinkPreview {message_id} in {server_id}/{channel_id}");

    let Some(server) = server_states.get(&server_id) else {
        let _ = event_tx.send(NetworkEvent::Error {
            message: format!("Unknown server {server_id}"),
        }).await;
        return;
    };

    // Muted members can't author content through this path either — same gate
    // the edit handler applies, for the same reason.
    if let Some(message) = muted_send_error(server, local_peer_str) {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let lp = preview.as_deref();
    let lp_json = preview_column(lp);
    let ctx = format!("{server_id}:{channel_id}");

    let mut attached: Option<AttachSig> = None;
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        // Local-author op: we may only re-sign our OWN row. Remote ingest has its
        // own check; this stops a UI bug minting a signature over somebody else's.
        let sender = store.get_channel_message_sender(&message_id);
        let author_is_us = sender
            .as_deref()
            .map(|s| super::resolver::same_identity(s, local_peer_str))
            .unwrap_or(false);
        if !author_is_us {
            hollow_log!("[HOLLOW-LP] Refusing to attach preview to {message_id} — not ours (sender {sender:?})");
            return;
        }
        let Some(row) = store.get_channel_message_sig_row(&message_id) else {
            return;
        };
        let signed = sign_attached_preview(
            &row, lp, bundle_keypair, pub_key_b64, "ch", &ctx,
            &super::resolver::resolve(local_peer_str), &message_id,
        );
        let _ = store.update_channel_link_preview_and_sig(
            &message_id, lp_json.as_deref(),
            signed.sig.as_deref(), signed.pk.as_deref(), Some(super::frame_auth::now_ms()),
        );
        attached = Some(signed);
    }
    let Some(signed) = attached else { return };

    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicLinkPreviewSet {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            mid: message_id.clone(),
            lp: preview.clone(),
            ts: signed.ts,
            sig: signed.sig.clone(),
            pk: signed.pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, server, &channel_id, &msg);
    } else {
        let envelope = MessageEnvelope::LinkPreviewSet {
            mid: message_id.clone(),
            lp: preview.clone(),
            ts: signed.ts,
            sig: signed.sig.clone(),
            pk: signed.pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Link preview attach encrypt failed, falling back to Olm",
            /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelLinkPreviewUpdated {
        server_id,
        channel_id,
        message_id,
        preview: preview.map(|b| *b),
    }).await;
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_attach_dm_link_preview(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    preview: Option<Box<LinkPreviewRef>>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] AttachDmLinkPreview {message_id} for {peer_id_str}");

    let lp = preview.as_deref();
    let lp_json = preview_column(lp);

    let mut attached: Option<AttachSig> = None;
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        // Local-author op — the row has to be one WE sent.
        if store.get_dm_message_is_mine(&message_id) != Some(true) {
            hollow_log!("[HOLLOW-LP] Refusing to attach preview to DM {message_id} — not ours");
            return;
        }
        let Some(row) = store.get_dm_message_sig_row(&message_id) else {
            return;
        };
        let signed = sign_attached_preview(
            &row, lp, bundle_keypair, pub_key_b64, "dm", &peer_id_str,
            &super::resolver::resolve(local_peer_str), &message_id,
        );
        let _ = store.update_link_preview_and_sig(
            &message_id, lp_json.as_deref(),
            signed.sig.as_deref(), signed.pk.as_deref(), Some(super::frame_auth::now_ms()),
        );
        attached = Some(signed);
    }
    let Some(signed) = attached else { return };

    // The recipient may still be offline with the ORIGINAL message queued. Rewrite
    // that envelope in place rather than letting a bare `lp_set` chase a message
    // they have not received: on reconnect they get ONE message with its card.
    rewrite_pending_dm_preview(
        pending_messages, &message_id, lp, &signed.sig, &signed.pk,
    );

    let envelope = MessageEnvelope::LinkPreviewSet {
        mid: message_id.clone(),
        lp: preview.clone(),
        ts: signed.ts,
        sig: signed.sig.clone(),
        pk: signed.pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Fans to the recipient's devices AND our own siblings, so the card lands
    // on the copy sitting on our phone too.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // siblings resolve the convo by mid on receive, same as edits
    ).await;

    let _ = event_tx.send(NetworkEvent::DmLinkPreviewUpdated {
        peer_id: recipient_master,
        message_id,
        preview: preview.map(|b| *b),
    }).await;
}

/// Rewrite every queued copy of a DM whose preview just landed, across ALL
/// per-device pending queues. Mirrors [`rewrite_pending_dm_edits`]: the queued
/// message keeps its text and gains the card plus the signature covering it.
fn rewrite_pending_dm_preview(
    pending_messages: &mut HashMap<String, Vec<String>>,
    message_id: &str,
    preview: Option<&LinkPreviewRef>,
    sig: &Option<String>,
    pk: &Option<String>,
) {
    for queued in pending_messages.values_mut() {
        for entry in queued.iter_mut() {
            let Ok(MessageEnvelope::DirectMessage { inner }) =
                serde_json::from_str::<MessageEnvelope>(entry)
            else {
                continue;
            };
            if inner.mid.as_deref() != Some(message_id) {
                continue;
            }
            let updated = MessageEnvelope::DirectMessage {
                inner: Box::new(DirectMessagePayload {
                    link_preview: preview.cloned(),
                    sig: sig.clone(),
                    pk: pk.clone(),
                    ..*inner
                }),
            };
            if let Ok(json) = serde_json::to_string(&updated) {
                *entry = json;
                hollow_log!("[HOLLOW-LP] Updated pending DM {message_id} with its late preview");
            }
        }
    }
}

// ── 5. DeleteChannelMessage ──────────────────────────────────────────

pub(crate) async fn handle_delete_channel_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] DeleteChannelMessage {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    let local_peer = local_peer_str.to_string();
    let delete_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the deletion with the text at deletion time, under the "ch-delete" type
    // so a delete signature cannot be replayed as a send signature; v2 also binds
    // the row's structural fields, since a v1 delete signature was replayable onto
    // any same-text message in the channel. Text from DB, so the archive verifies.
    let mut sig = None;
    let mut pk = None;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let row = RowExtras::load_channel(&store, &message_id);
            let current_text = row.text.clone().unwrap_or_default();
            (sig, pk) = sign_message_versioned(
                bundle_keypair, pub_key_b64, "ch-delete",
                &format!("{}:{}", server_id, channel_id),
                &local_peer, delete_timestamp, &row.as_signed(&message_id), &current_text,
            );
            // Hide in local DB (preserves text in message_deletions table).
            let _ = store.hide_channel_message(
                &message_id, delete_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelDelete {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), ts: delete_timestamp,
            sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, server, &channel_id, &msg);
    } else {
        let envelope = MessageEnvelope::DeleteMessage {
            mid: message_id.clone(),
            ts: delete_timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Delete encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
        server_id,
        channel_id,
        message_id,
        deleted_at: delete_timestamp,
    }).await;
}

// ── 6. DeleteDmMessage ───────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_delete_dm_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] DeleteDmMessage {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();
    let delete_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the deletion with the text at deletion time. "dm-delete" is distinct
    // from "dm" to prevent replay; v2 also binds the row's structural fields.
    let mut sig = None;
    let mut pk = None;
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let row = RowExtras::load_dm(&store, &message_id);
            let current_text = row.text.clone().unwrap_or_default();
            (sig, pk) = sign_message_versioned(
                bundle_keypair, pub_key_b64, "dm-delete", &peer_id_str,
                &local_peer, delete_timestamp, &row.as_signed(&message_id), &current_text,
            );
            let _ = store.hide_dm_message(
                &message_id, delete_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    let envelope = MessageEnvelope::DeleteMessage {
        mid: message_id.clone(),
        ts: delete_timestamp,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Multi-device fan-out (Step 3): deliver the deletion to every device of the
    // recipient + our own siblings (offline devices get it buffered/queued).
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    // The DM thread key is the peer's MASTER id (no-op single-device).
    let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        deleted_at: delete_timestamp,
    }).await;
}

// ── 7. AddChannelReaction ────────────────────────────────────────────

pub(crate) async fn handle_add_channel_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] AddChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    // Moderation gate: mute blocks adding reactions, like the new-message send
    // gate. Removals stay allowed, and slow mode does not apply to reactions.
    if let Some(message) = muted_send_error(server, local_peer_str) {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();
    let (reaction_ts, sig, pk) = {
        let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok();
        let reaction_ts = reaction_stamp(store.as_ref(), &message_id, &emoji, &local_peer);
        let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
        let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);
        if let Some(store) = store {
            let _ = store.add_reaction(
                &message_id, &emoji, &local_peer, reaction_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
        (reaction_ts, sig, pk)
    };

    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelAddReaction {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), emoji: emoji.clone(),
            ts: reaction_ts, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, server, &channel_id, &msg);
    } else {
        let envelope = MessageEnvelope::AddReaction {
            mid: message_id.clone(),
            emoji: emoji.clone(),
            ts: reaction_ts,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Reaction encrypt failed, falling back to Olm", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
        server_id,
        channel_id,
        message_id,
        emoji,
        reactor: local_peer,
        added_at: reaction_ts,
    }).await;
}

// ── 8. AddDmReaction ─────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_add_dm_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] AddDmReaction {emoji} on {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();

    // Multi-device: attribute our own reaction to our MASTER id so it lands under
    // the same identity on our other devices (no-op single-device).
    let reactor_master = super::resolver::resolve(&local_peer);

    let (reaction_ts, sig, pk) = {
        let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok();
        let reaction_ts = reaction_stamp(store.as_ref(), &message_id, &emoji, &reactor_master);
        let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
        let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);
        if let Some(store) = store {
            let _ = store.add_reaction(
                &message_id, &emoji, &reactor_master, reaction_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
        (reaction_ts, sig, pk)
    };

    let envelope = MessageEnvelope::AddReaction {
        mid: message_id.clone(),
        emoji: emoji.clone(),
        ts: reaction_ts,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Multi-device fan-out (Step 3): every device of the recipient + our siblings.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    let _ = event_tx.send(NetworkEvent::DmReactionAdded {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        emoji,
        reactor: reactor_master,
        added_at: reaction_ts,
    }).await;
}

/// The signed time of our own reaction change: reactions and removals are ordered
/// by it, so it outranks the row even when a sibling with a faster clock made it.
fn reaction_stamp(store: Option<&crate::storage::MessageStore>, mid: &str, emoji: &str, reactor: &str) -> i64 {
    store.map_or_else(super::frame_auth::now_ms, |s| s.next_reaction_stamp(mid, emoji, reactor))
}

// ── 9. RemoveChannelReaction ─────────────────────────────────────────

pub(crate) async fn handle_remove_channel_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] RemoveChannelReaction {emoji} on {message_id} in {server_id}/{channel_id}");

    let server = match server_states.get(&server_id) {
        Some(s) => s,
        None => {
            let _ = event_tx.send(NetworkEvent::Error {
                message: format!("Unknown server {server_id}"),
            }).await;
            return;
        }
    };

    let local_peer = local_peer_str.to_string();
    let (remove_ts, sig, pk) = {
        let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok();
        let remove_ts = reaction_stamp(store.as_ref(), &message_id, &emoji, &local_peer);
        let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
        let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);
        if let Some(store) = store {
            let _ = store.remove_reaction(
                &message_id, &emoji, &local_peer, remove_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
        (remove_ts, sig, pk)
    };

    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelRemoveReaction {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), emoji: emoji.clone(),
            ts: remove_ts, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, server, &channel_id, &msg);
    } else {
        let envelope = MessageEnvelope::RemoveReaction {
            mid: message_id.clone(),
            emoji: emoji.clone(),
            ts: remove_ts,
            sig: sig.clone(),
            pk: pk.clone(),
            sid: Some(server_id.clone()),
            cid: Some(channel_id.clone()),
        };
        broadcast_channel_envelope(
            olm, crypto_store, mls, event_tx, ws_cmd_tx, ws_room_peers,
            server, local_peer_str, &server_id, &channel_id, &envelope,
            "Remove reaction encrypt failed, Olm fallback", /*bootstrap_subgroup*/ true,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
        server_id,
        channel_id,
        message_id,
        emoji,
        reactor: local_peer,
        removed_at: remove_ts,
    }).await;
}

// ── 10. RemoveDmReaction ─────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_remove_dm_reaction(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut HashMap<String, std::time::Instant>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    // THIS device's keypair — signs the Olm KeyRequest (Fix B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    peer_id_str: String,
    message_id: String,
    emoji: String,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-SWARM] RemoveDmReaction {emoji} on {message_id} for {peer_id_str}");

    let local_peer = local_peer_str.to_string();

    // Multi-device: our own reaction is keyed by our MASTER id (see AddDmReaction).
    let reactor_master = super::resolver::resolve(&local_peer);

    let (remove_ts, sig, pk) = {
        let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok();
        let remove_ts = reaction_stamp(store.as_ref(), &message_id, &emoji, &reactor_master);
        let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
        let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);
        if let Some(store) = store {
            let _ = store.remove_reaction(
                &message_id, &emoji, &reactor_master, remove_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
        (remove_ts, sig, pk)
    };

    let envelope = MessageEnvelope::RemoveReaction {
        mid: message_id.clone(),
        emoji: emoji.clone(),
        ts: remove_ts,
        sig: sig.clone(),
        pk: pk.clone(),
        sid: None,
        cid: None,
    };
    let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

    // Multi-device fan-out (Step 3): every device of the recipient + our siblings.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    let _ = event_tx.send(NetworkEvent::DmReactionRemoved {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        emoji,
        reactor: reactor_master,
        removed_at: remove_ts,
    }).await;
}

/// Handle `MessageEnvelope::ChannelMessage` (MLS-decrypted path).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_channel_message(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_state: Option<&ServerState>,
    slow_mode_clock: &mut SlowModeClock,
    local_peer: &str,
    sender_peer_id: String,
    sid: String,
    cid: String,
    text: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    mid: Option<String>,
    reply_to: Option<String>,
    file_id: Option<String>,
    link_preview: Option<LinkPreviewRef>,
    order_us: Option<i64>,
    album: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    // SECURITY: conference chat NEVER rides the channel pipeline, it has its own
    // RAM-only path. A modified client sending a ChannelMessage envelope under a
    // conf group would PERSIST it, so drop it here regardless of signature.
    if super::conference::is_conference_sid(&sid) {
        hollow_log!("[HOLLOW-SECURITY] Dropped ChannelMessage envelope for conference sid {sid}");
        return;
    }

    // SECURITY: a missing OR invalid signature is rejected, mirroring the direct
    // twin in swarm.rs. Covers MLS-decrypted private channels and plaintext PUBLIC
    // channels, where this is the only authorship binding there is. The v2 extras
    // come from the same wire fields persisted below.
    let lp_digest = link_preview.as_ref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: mid.as_deref(),
        reply_to: reply_to.as_deref(),
        file_id: file_id.as_deref(),
        order_us,
        lp_digest: lp_digest.as_deref(),
        album: album.as_deref(),
    };
    if channel_sig_rejected(
        &sender_peer_id, &sid, &cid, ts, &text, sig.as_deref(), pk.as_deref(), &extras,
    ) {
        return;
    }

    // Multi-device: a message from ANY of our own devices is ours.
    let is_mine = super::resolver::same_identity(&sender_peer_id, local_peer);

    // Moderation trio (receive-side): drop LIVE messages that violate the
    // channel's rules — see `live_channel_moderation_drop`.
    if let Some(state) = server_state {
        if live_channel_moderation_drop(
            state, slow_mode_clock, &sender_peer_id, &sid, &cid, mid.as_deref(),
            file_id.is_some(), ts, db_path, db_passphrase,
        ).await {
            return;
        }
    }

    let Some((is_new, reply_author)) = persist_incoming_channel_message(
        &sid, &cid, &sender_peer_id, &text, is_mine, ts,
        sig.as_deref(), pk.as_deref(), mid.as_deref(),
        reply_to.as_deref(), file_id.as_deref(), order_us, album.as_deref(),
        &link_preview, db_path, db_passphrase,
    ) else {
        // Store-open failure — the message is silently gone otherwise; log
        // channel + sender context (never content) so the drop is diagnosable.
        hollow_log!(
            "[HOLLOW-SWARM] DROPPED incoming channel message in {sid}/{cid} from {sender_peer_id} (mid={mid:?}) — MessageStore::open failed"
        );
        return;
    };
    // ALWAYS emit: a ChannelSyncBatch racing this live message inserts the row
    // first without emitting, and suppressing the live event too left an open pane
    // stale until re-entry. Dart dedups by mid and skips unread on `duplicate`.
    let reply_to_own = reply_author
        .is_some_and(|a| super::resolver::same_identity(&a, local_peer));
    let _ = event_tx.send(NetworkEvent::ChannelMessageReceived {
        server_id: sid,
        channel_id: cid,
        from_peer: sender_peer_id,
        text,
        timestamp: ts,
        message_id: mid.unwrap_or_default(),
        reply_to_mid: reply_to.unwrap_or_default(),
        link_preview,
        signature: sig,
        public_key: pk,
        album_id: album.map(Box::new),
        reply_to_own,
        duplicate: !is_new,
        is_own: is_mine,
    }).await;
}

/// SECURITY: true = drop this LIVE channel message.
///
/// A signature is REQUIRED, not merely checked when present: an
/// `if sig.is_none() { return false }` early-out IS the bypass, because stripping
/// `sig`/`pk` then skips verification entirely.
///
/// This matters most for PUBLIC channels, which carry no MLS layer, so the
/// signature is the ONLY thing binding content and authorship to an identity; on
/// MLS channels it is defence in depth behind group membership. Sync backfill
/// applies the same rule (`REQUIRE_SIGNED_BACKFILL`); the live-enforce /
/// backfill-tolerate split survives ONLY for the moderation trio, because a mute
/// may legitimately postdate the history being synced.
#[allow(clippy::too_many_arguments)]
fn channel_sig_rejected(
    sender_peer_id: &str,
    sid: &str,
    cid: &str,
    ts: i64,
    text: &str,
    sig: Option<&str>,
    pk: Option<&str>,
    extras: &SignedExtras,
) -> bool {
    // v2 only (0.8.5) — the wire's structured fields are covered.
    if !verify_message_signature_v2(
        sender_peer_id, sig, pk, "ch", &format!("{}:{}", sid, cid),
        ts, extras, text, &mut PkCache::new(),
    ) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED ChannelMessage (MLS) from {sender_peer_id} — signature verification FAILED"
        );
        return true;
    }
    false
}

/// Why a LIVE post by `sender` (a MASTER) into `cid` must be dropped, judged by OUR
/// state, or `None`: the sender must be a current member who can see and post in
/// that channel, not muted, with a file where the channel is media-only. Every
/// transport asks, so a modified client cannot pick the one that skips a rule. Sync
/// backfill never does: history may predate a role, mute or channel change.
pub(crate) fn live_channel_post_refusal(
    state: &ServerState,
    sender: &str,
    cid: &str,
    has_file: bool,
    now_ms: u64,
) -> Option<&'static str> {
    if !state.is_member(sender) {
        Some("not a member")
    } else if !state.can_see_channel(sender, cid) {
        Some("cannot see the channel")
    } else if !state.can_post_in_channel_at(sender, cid, now_ms) {
        Some("may not post in the channel")
    } else if state.is_muted(sender, now_ms) {
        Some("muted")
    } else if state.is_channel_media_only(cid) && !has_file {
        Some("text in a media-only channel")
    } else {
        None
    }
}

/// When each sender's last FRESH post in a slow-mode channel reached us, by our
/// own clock, keyed (server, channel, sender master), with its message id so a
/// second copy of the same post is not a violation. A post dated inside the
/// window is fresh; an older one is a replay (relay ring, reconnect) and is judged
/// by its signed `ts` against stored history instead.
#[derive(Default)]
pub(crate) struct SlowModeClock(HashMap<(String, String, String), (std::time::Instant, Option<String>)>);

/// The slow-mode window in ms that `sender` is held to in `cid`, if any.
pub(crate) fn slow_mode_window_ms(state: &ServerState, sender: &str, cid: &str) -> Option<i64> {
    let slow = state.channel_slow_mode(cid);
    (slow > 0 && !state.bypasses_slow_mode(sender)).then_some(slow as i64 * 1000)
}

/// Receive-side gate for one LIVE channel message: true = drop. Async: the
/// slow-mode check reads the store off-loop.
#[allow(clippy::too_many_arguments)]
async fn live_channel_moderation_drop(
    state: &ServerState,
    slow_mode_clock: &mut SlowModeClock,
    sender_peer_id: &str,
    sid: &str,
    cid: &str,
    mid: Option<&str>,
    has_file: bool,
    ts: i64,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if let Some(reason) = live_channel_post_refusal(state, sender_peer_id, cid, has_file, now_ms) {
        hollow_log!("[HOLLOW-MOD] DROPPED channel message from {sender_peer_id} in {sid}/{cid}: {reason}");
        return true;
    }
    if let Some(window_ms) = slow_mode_window_ms(state, sender_peer_id, cid) {
        let key = (sid.to_string(), cid.to_string(), sender_peer_id.to_string());
        let fresh = ts >= now_ms as i64 - window_ms;
        let window = std::time::Duration::from_millis(window_ms as u64);
        if fresh && slow_mode_clock.0.get(&key).is_some_and(|(at, last_mid)| {
            at.elapsed() < window && (mid.is_none() || last_mid.as_deref() != mid)
        }) {
            hollow_log!("[HOLLOW-MOD] DROPPED slow-mode violation from {sender_peer_id} in {cid} (by our clock)");
            return true;
        }
        // Open and query on the blocking pool with owned captures: the store lives
        // entirely inside the closure. Open failure = allow, as before.
        let (sid_o, cid_o) = (sid.to_string(), cid.to_string());
        let sender = sender_peer_id.to_string();
        let (path, pass) = (db_path.to_string(), db_passphrase.to_string());
        let violation = tokio::task::spawn_blocking(move || {
            crate::storage::MessageStore::open(&path, &pass)
                .map(|store| store.channel_sender_has_msg_in_range(&sid_o, &cid_o, &sender, ts - window_ms, ts))
                .unwrap_or(false)
        }).await.unwrap_or(false);
        if violation {
            hollow_log!("[HOLLOW-MOD] DROPPED slow-mode violation from {sender_peer_id} in {cid}");
            return true;
        }
        if fresh {
            slow_mode_clock.0.insert(key, (std::time::Instant::now(), mid.map(str::to_owned)));
        }
    }
    false
}

/// Whether a live channel signal from `sender` (a MASTER), typing or an unread
/// hint, is taken in: the sender may post in `cid` and we may see it, so nobody
/// outside the channel fakes activity there and nobody is told about a channel
/// they cannot open.
pub(crate) fn channel_signal_accepted(
    state: &ServerState,
    sender: &str,
    local_master: &str,
    cid: &str,
    now_ms: u64,
) -> bool {
    live_channel_post_refusal(state, sender, cid, true, now_ms).is_none()
        && state.can_see_channel(local_master, cid)
}

/// Whether a PLAINTEXT public-channel frame for `sid`/`cid` may be taken in at all.
/// A member takes one only for a channel that is public in its own state (the frame
/// is unencrypted, so anyone in the room can send one); a node with no state for the
/// server only while it is viewing that server as a guest.
pub(crate) fn public_frame_accepted(
    state: Option<&ServerState>,
    viewing_as_guest: bool,
    sid: &str,
    cid: &str,
) -> bool {
    let ok = match state {
        Some(state) => state.is_channel_public(cid),
        None => viewing_as_guest,
    };
    if !ok {
        hollow_log!("[HOLLOW-SECURITY] REJECTED public-channel frame for {sid}/{cid}: not a public channel here");
    }
    ok
}

/// LIVE-ingest mute gate shared by the edit and add-reaction envelope handlers:
/// true = drop, because the sender is muted (master-keyed, lazy expiry, every
/// call site resolving the sender to its MASTER first). Deletes and reaction
/// removals stay allowed, and sync backfill never routes through these handlers.
pub(crate) fn live_muted_ingest_drop(server_state: Option<&ServerState>, sender: &str, action: &str) -> bool {
    let Some(state) = server_state else { return false; };
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if state.is_muted(sender, now_ms) {
        hollow_log!("[HOLLOW-MOD] DROPPED {action} from muted member {sender}");
        return true;
    }
    false
}

/// Persist one incoming channel message with message-id dedup. The content UNIQUE
/// index is legacy-only, so identical-text spam in the same millisecond persists
/// as distinct messages. `None` when the store could not be opened, and the caller
/// then emits nothing. Sync, and owns the store.
#[allow(clippy::too_many_arguments)]
fn persist_incoming_channel_message(
    sid: &str,
    cid: &str,
    sender_peer_id: &str,
    text: &str,
    is_mine: bool,
    ts: i64,
    sig: Option<&str>,
    pk: Option<&str>,
    mid: Option<&str>,
    reply_to: Option<&str>,
    file_id: Option<&str>,
    order_us: Option<i64>,
    album: Option<&str>,
    link_preview: &Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<(bool, Option<String>)> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    // Replied-to message's author (MASTER id), so the event's `reply_to_own` lets
    // mentions-only gate on "reply to ME" (#42). Same store open; absent = None.
    let reply_author = reply_to.and_then(|m| store.get_channel_message_sender(m));
    let already = mid
        .map(|m| store.channel_message_exists(m))
        .unwrap_or(false);
    let is_new = if already {
        false
    } else {
        store.insert_channel_message(
            sid, cid, sender_peer_id, text, is_mine, ts,
            sig, pk, mid, reply_to, file_id, order_us, album,
        ).map(|r| r > 0).unwrap_or(false)
    };
    if is_new {
        if let (Some(lp), Some(message_id)) = (link_preview.as_ref(), mid) {
            if let Ok(lp_json) = serde_json::to_string(lp) {
                let _ = store.update_channel_link_preview(message_id, &lp_json);
            }
        }
    }
    Some((is_new, reply_author))
}

/// Handle a LIVE channel `MessageEnvelope::EditMessage` from any transport;
/// `peer_str` is the editor's MASTER.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_edit_message(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_state: Option<&ServerState>,
    peer_str: &str,
    mid: String,
    new_text: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    // Moderation (LIVE ingest only): drop edits from muted members, so a modified
    // client cannot author content through the edit path while muted.
    if live_muted_ingest_drop(server_state, peer_str, "edit") {
        return;
    }
    // The row must sit where the edit says, or the mute gate above read a server
    // the sender picked.
    let (Some(s), Some(c)) = (sid.as_deref(), cid.as_deref()) else { return };
    let mut edit_applied = false;
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let sender = store.get_channel_message_sender(&mid);
        let scope = RowScope::Channel { sid: s, cid: c, signer: peer_str };
        if sender.is_some() && change_may_touch_row(&store, &scope, Some(&mid)) {
            // SECURITY: a LIVE edit must carry a signature that verifies. The
            // row-ownership check above trusts the transport-reported sender,
            // which on plaintext PUBLIC channels is relay-controlled. The extras
            // come from OUR row, matching what the editor's signature bound.
            let ctx = format!("{s}:{c}");
            let row = RowExtras::load_channel(&store, &mid);
            if !verify_message_signature_v2(
                peer_str, sig.as_deref(), pk.as_deref(), "ch", &ctx,
                ts, &row.as_signed(&mid), &new_text, &mut PkCache::new(),
            ) {
                hollow_log!("[HOLLOW-SECURITY] REJECTED channel edit of {mid} from {peer_str} — signature verification FAILED");
                return;
            }
            let _ = store.edit_channel_message(
                &mid, &new_text, ts,
                sig.as_deref(), pk.as_deref(),
            );
            edit_applied = true;
        }
        // sender == None → message not synced yet; sync batch will bring the edited version.
    }
    if edit_applied {
        if let (Some(s_id), Some(c_id)) = (sid, cid) {
            let _ = event_tx.send(NetworkEvent::ChannelMessageEdited {
                server_id: s_id,
                channel_id: c_id,
                message_id: mid,
                new_text,
                edited_at: ts,
                signature: sig,
                public_key: pk,
            }).await;
        }
    }
}

/// Handle `MessageEnvelope::LinkPreviewSet` / `HavenMessage::PublicLinkPreviewSet`
/// (issue #45). One handler for all three ingest paths, because the rule is the
/// same everywhere: the card only lands if the AUTHOR signed it.
///
/// `peer_str` is the transport sender (a DEVICE id on the DM path); `sid` present
/// = channel message, absent = DM. The card lands only on the sender's own row in
/// the place the envelope names, and only if `sealed_at` (when its frame was sealed)
/// is later than the card it replaces. Applying the same card twice is a quiet
/// no-op, so a duplicated frame or a re-broadcast costs nothing.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_link_preview_set(
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_state: Option<&ServerState>,
    peer_str: &str,
    local_master: &str,
    mid: String,
    lp: Option<Box<LinkPreviewRef>>,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    sealed_at: i64,
    db_path: &str,
    db_passphrase: &str,
) {
    // Moderation (LIVE ingest): a muted member can't author card content
    // either, mirroring the edit gate.
    if live_muted_ingest_drop(server_state, &super::resolver::resolve(peer_str), "link preview") {
        return;
    }

    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let is_channel = sid.is_some();

    // Who must have signed this, and under what context. Both are derived
    // from OUR row, never from fields the sender controls.
    let (signer, ctx, convo_peer) = if let (Some(s), Some(c)) = (sid.as_deref(), cid.as_deref()) {
        if !store.channel_message_exists(&mid) {
            // Row not synced yet — the sync batch will bring the card with it.
            return;
        }
        let author = super::resolver::resolve(peer_str);
        if !change_may_touch_row(&store, &RowScope::Channel { sid: s, cid: c, signer: &author }, Some(&mid)) {
            return;
        }
        (author, format!("{s}:{c}"), String::new())
    } else if is_channel {
        return;
    } else {
        let Some(change) = live_dm_change(&store, &mid, peer_str, local_master) else { return };
        (change.signer, change.ctx, change.convo)
    };

    let Some(row) = (if is_channel {
        store.get_channel_message_sig_row(&mid)
    } else {
        store.get_dm_message_sig_row(&mid)
    }) else {
        return;
    };

    // SECURITY: the signature must verify over the row we hold with the NEW digest
    // folded in. That is what stops a relay pasting a card of its choosing onto a
    // plaintext public-channel message, and it REJECTS; there is no accept path.
    let lp_digest = lp.as_deref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: Some(&mid),
        reply_to: row.reply_to_mid.as_deref(),
        file_id: row.file_id.as_deref(),
        order_us: row.order_us,
        lp_digest: lp_digest.as_deref(),
        album: row.album_id.as_deref(),
    };
    let msg_type = if is_channel { "ch" } else { "dm" };
    if !verify_message_signature_v2(
        &signer, sig.as_deref(), pk.as_deref(), msg_type, &ctx,
        ts, &extras, &row.text, &mut PkCache::new(),
    ) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED link preview for {mid} from {peer_str} (signer {signer}) — signature verification FAILED");
        return;
    }

    let lp_json = preview_column(lp.as_deref());
    let applied = if is_channel {
        store.update_channel_link_preview_and_sig(
            &mid, lp_json.as_deref(), sig.as_deref(), pk.as_deref(), Some(sealed_at),
        )
    } else {
        store.update_link_preview_and_sig(
            &mid, lp_json.as_deref(), sig.as_deref(), pk.as_deref(), Some(sealed_at),
        )
    };
    if !matches!(applied, Ok(true)) {
        return;
    }

    let preview = lp.map(|b| *b);
    if let (Some(server_id), Some(channel_id)) = (sid, cid) {
        let _ = event_tx.send(NetworkEvent::ChannelLinkPreviewUpdated {
            server_id, channel_id, message_id: mid, preview,
        }).await;
    } else {
        let _ = event_tx.send(NetworkEvent::DmLinkPreviewUpdated {
            peer_id: convo_peer, message_id: mid, preview,
        }).await;
    }
}

/// Handle a LIVE channel `MessageEnvelope::DeleteMessage` from any transport;
/// `sender_peer_id` is the deleter's MASTER.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_delete_message(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    sender_peer_id: &str,
    mid: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let (Some(s), Some(c)) = (sid.as_deref(), cid.as_deref()) else { return };
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let scope = RowScope::Channel { sid: s, cid: c, signer: sender_peer_id };
        if !store.channel_message_exists(&mid) || !change_may_touch_row(&store, &scope, Some(&mid)) {
            return;
        }
        // SECURITY: a LIVE delete must carry a signature that verifies. On
        // plaintext PUBLIC channels the transport-reported sender is
        // relay-controlled, and an unauthenticated delete is a censorship
        // primitive. A receiver whose text lags rejects and converges via sync.
        let ctx = format!("{s}:{c}");
        let row = RowExtras::load_channel(&store, &mid);
        let current_text = row.text.clone().unwrap_or_default();
        if !verify_message_signature_v2(
            sender_peer_id, sig.as_deref(), pk.as_deref(), "ch-delete", &ctx,
            ts, &row.as_signed(&mid), &current_text, &mut PkCache::new(),
        ) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED channel delete of {mid} from {sender_peer_id} — signature verification FAILED");
            return;
        }
        let _ = store.hide_channel_message(
            &mid, ts,
            sig.as_deref(), pk.as_deref(),
        );
    }
    if let (Some(s_id), Some(c_id)) = (sid, cid) {
        let _ = event_tx.send(NetworkEvent::ChannelMessageDeleted {
            server_id: s_id,
            channel_id: c_id,
            message_id: mid,
            deleted_at: ts,
        }).await;
    }
}

/// Handle a LIVE DM `MessageEnvelope::EditMessage` (Olm; MLS carries no DMs).
/// `sender` is the transport DEVICE, a friend's or our own sibling's.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_dm_edit(
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender: &str,
    local_master: &str,
    mid: String,
    new_text: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
    let Some(change) = live_dm_change(&store, &mid, sender, local_master) else {
        hollow_log!("[HOLLOW-EDIT] Rejected: {sender} may not edit DM {mid}");
        return;
    };
    let row = RowExtras::load_dm(&store, &mid);
    if !verify_message_signature_v2(
        &change.signer, sig.as_deref(), pk.as_deref(), "dm", &change.ctx,
        ts, &row.as_signed(&mid), &new_text, &mut PkCache::new(),
    ) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED DM edit of {mid} from {sender} (signer {}) — signature verification FAILED", change.signer);
        return;
    }
    let _ = store.edit_dm_message(&mid, &new_text, ts, sig.as_deref(), pk.as_deref());
    // Carries sig/pk so the receiver's Proof dialog verifies the edit's signature,
    // not the original's.
    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
        peer_id: change.convo,
        message_id: mid,
        new_text,
        edited_at: ts,
        signature: sig,
        public_key: pk,
    }).await;
}

/// Handle a LIVE DM `MessageEnvelope::DeleteMessage` (Olm; MLS carries no DMs).
/// `sender` is the transport DEVICE, a friend's or our own sibling's.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_dm_delete(
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender: &str,
    local_master: &str,
    mid: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
    let Some(change) = live_dm_change(&store, &mid, sender, local_master) else {
        hollow_log!("[HOLLOW-SECURITY] REJECTED DeleteMessage (DM) from {sender}: may not delete {mid}");
        return;
    };
    // SECURITY: an unauthenticated delete is a censorship primitive; "dm-delete"
    // signs the row's CURRENT text and structural fields.
    let row = RowExtras::load_dm(&store, &mid);
    let current_text = row.text.clone().unwrap_or_default();
    if !verify_message_signature_v2(
        &change.signer, sig.as_deref(), pk.as_deref(), "dm-delete", &change.ctx,
        ts, &row.as_signed(&mid), &current_text, &mut PkCache::new(),
    ) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED DM delete of {mid} from {sender} (signer {}) — signature verification FAILED", change.signer);
        return;
    }
    let _ = store.hide_dm_message(&mid, ts, sig.as_deref(), pk.as_deref());
    let _ = event_tx.send(NetworkEvent::DmMessageDeleted {
        peer_id: change.convo,
        message_id: mid,
        deleted_at: ts,
    }).await;
}

/// Handle a LIVE channel `MessageEnvelope::AddReaction` from any transport;
/// `peer_str` is the reactor's MASTER. A DM-shaped reaction (no `sid`) is dropped:
/// DM reactions ride Olm only.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_add_reaction(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    server_state: Option<&ServerState>,
    peer_str: &str,
    mid: String,
    emoji: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    // Choke-point validation for EVERY inbound add path: a short Unicode emoji or
    // a well-formed custom emote token, nothing else reaches the DB.
    if !super::emotes::valid_reaction_emoji(&emoji) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED reaction from {peer_str} — invalid emoji string ({} bytes)", emoji.len());
        return;
    }
    let (Some(s_id), Some(c_id)) = (sid, cid) else { return };
    if server_state.is_some_and(|s| !s.is_member(peer_str)) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED reaction from {peer_str}: not a member of {s_id}");
        return;
    }
    // Moderation (LIVE ingest only): drop reactions from muted members,
    // mirroring the new-message ingest gate; reaction REMOVALS stay allowed.
    if live_muted_ingest_drop(server_state, peer_str, "reaction") {
        return;
    }
    // SECURITY: a LIVE reaction must carry a signature that verifies. On plaintext
    // PUBLIC channels the reactor is relay-controlled, so an unsigned reaction is
    // attributable to anyone. The payload has its own grammar, so no v2 is needed.
    if reaction_sig_rejected(peer_str, "reaction", &mid, &emoji, ts, sig.as_deref(), pk.as_deref()) {
        return;
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
    if !channel_reaction_target_ok(&store, &mid, &s_id, &c_id) {
        return;
    }
    let _ = store.add_reaction(
        &mid, &emoji, peer_str, ts,
        sig.as_deref(), pk.as_deref(),
    );
    let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
        server_id: s_id,
        channel_id: c_id,
        message_id: mid,
        emoji,
        reactor: peer_str.to_string(),
        added_at: ts,
    }).await;
}

/// SECURITY: `true` = this SYNCED reaction may be stored. Reactions riding a sync
/// batch used to be inserted unverified: the item-level backfill check covers the
/// MESSAGE, not the reaction rows hanging off it, and each names its own reactor,
/// so a responder (or the relay, on a plaintext public channel) could attribute
/// any reaction to any member. Same grammar and signer rule as the live path,
/// `reaction:{mid}:{emoji}:{ts}` signed by the reactor's MASTER; sync items only
/// carry ADDITIONS. Absent is refused alongside invalid.
pub(crate) fn sync_reaction_accepted(mid: &str, r: &super::types::SyncReactionItem) -> bool {
    let reactor = super::resolver::resolve(&r.p);
    let payload = format!("reaction:{}:{}:{}", mid, r.e, r.ts);
    if verify_message_signature(&reactor, r.sig.as_deref(), r.pk.as_deref(), &payload) {
        return true;
    }
    hollow_log!(
        "[HOLLOW-SECURITY] REJECTED synced reaction {} on {mid} claiming reactor {reactor} — {}",
        r.e,
        if r.sig.is_none() && r.pk.is_none() { "NO signature" } else { "signature INVALID" }
    );
    false
}

/// SECURITY: true = drop this LIVE reaction add or remove, signature missing or
/// invalid. Reactions sign `{kind}:{mid}:{emoji}:{ts}`, which already binds the
/// message id, so a valid signature cannot be replayed onto another message or
/// emoji. Sync-batch reactions go through [`sync_reaction_accepted`] instead.
pub(crate) fn reaction_sig_rejected(
    reactor: &str,
    kind: &str,
    mid: &str,
    emoji: &str,
    ts: i64,
    sig: Option<&str>,
    pk: Option<&str>,
) -> bool {
    let payload = format!("{kind}:{mid}:{emoji}:{ts}");
    if !verify_message_signature(reactor, sig, pk, &payload) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED {kind} on {mid} claiming reactor {reactor} — signature verification FAILED"
        );
        return true;
    }
    false
}

/// Handle a LIVE channel `MessageEnvelope::RemoveReaction` from any transport;
/// `peer_str` is the reactor's MASTER, and only its own reaction goes.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_remove_reaction(
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    peer_str: &str,
    mid: String,
    emoji: String,
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let (Some(s_id), Some(c_id)) = (sid, cid) else { return };
    // SECURITY: same rule as the add path — see `reaction_sig_rejected`.
    if reaction_sig_rejected(peer_str, "unreaction", &mid, &emoji, ts, sig.as_deref(), pk.as_deref()) {
        return;
    }
    let removed = crate::storage::MessageStore::open(db_path, db_passphrase)
        .is_ok_and(|store| store.remove_reaction(&mid, &emoji, peer_str, ts, sig.as_deref(), pk.as_deref()) == Ok(true));
    if !removed {
        return;
    }
    let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
        server_id: s_id,
        channel_id: c_id,
        message_id: mid,
        emoji,
        reactor: peer_str.to_string(),
        removed_at: ts,
    }).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;

    // ── Deletion propagation through sync (0.8.4) — REJECT-ABSENT ──────
    //
    // Unit twins of the multi-node harness deletion tests: the apply helpers
    // against a real store, mirroring crypto_handler's v2 tamper tests.

    fn mem_store() -> crate::storage::MessageStore {
        crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("open store")
    }

    fn kp(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn pk_b64(k: &NativeKeypair) -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(k.public_key_protobuf())
    }

    /// Sign a channel deletion exactly like `handle_delete_channel_message`:
    /// "ch-delete" over the row's structural extras + current text.
    #[allow(clippy::too_many_arguments)]
    fn sign_channel_delete(
        store: &crate::storage::MessageStore,
        signer_kp: &NativeKeypair,
        signer_pk_b64: &str,
        sender: &str,
        sid: &str,
        cid: &str,
        mid: &str,
        ts: i64,
    ) -> (Option<String>, Option<String>) {
        let row = RowExtras::load_channel(store, mid);
        let text = row.text.clone().unwrap_or_default();
        sign_message_versioned(
            signer_kp, signer_pk_b64, "ch-delete", &format!("{sid}:{cid}"),
            sender, ts, &row.as_signed(mid), &text,
        )
    }

    /// REJECT-ABSENT at the apply site: absent proof → dropped; a non-author
    /// proof → dropped (pk↔author binding); tampered ts → dropped; the
    /// author's real proof → hidden AND the proof stored for onward serving.
    #[test]
    fn synced_channel_deletion_requires_author_proof() {
        let _g = crate::node::resolver::test_lock();
        let store = mem_store();
        let author = kp(231);
        let author_id = author.peer_id();
        let author_pk = pk_b64(&author);
        let (sid, cid, mid) = ("srv-1", "chan-1", "mid-del-1");
        store.insert_channel_message(
            sid, cid, &author_id, "to be deleted", false, 1_000,
            None, None, Some(mid), None, None, Some(1_000_000),
            None,
        ).unwrap();
        let mut cache = PkCache::new();

        // Absent proof (legacy responder or omit-the-sig attack) → dropped.
        assert!(!apply_verified_channel_deletion(
            &store, sid, cid, mid, 2_000, None, None, &mut cache,
        ));
        assert_eq!(store.get_channel_message_hidden_at(mid), None, "absent proof must not hide");

        // Forged proof: a NON-AUTHOR signs the correct payload with their own
        // key — the pk↔author binding rejects it (the censorship attack).
        let evil = kp(232);
        let evil_pk = pk_b64(&evil);
        let (esig, epk) = sign_channel_delete(&store, &evil, &evil_pk, &author_id, sid, cid, mid, 2_000);
        assert!(!apply_verified_channel_deletion(
            &store, sid, cid, mid, 2_000, esig.as_deref(), epk.as_deref(), &mut cache,
        ));
        assert_eq!(store.get_channel_message_hidden_at(mid), None, "a non-author proof must not hide");

        // The author's real proof — but served with a shifted timestamp → dropped.
        let (sig, pk) = sign_channel_delete(&store, &author, &author_pk, &author_id, sid, cid, mid, 2_000);
        assert!(!apply_verified_channel_deletion(
            &store, sid, cid, mid, 2_001, sig.as_deref(), pk.as_deref(), &mut cache,
        ));

        // The real proof with its real timestamp → newly hidden + proof stored.
        assert!(apply_verified_channel_deletion(
            &store, sid, cid, mid, 2_000, sig.as_deref(), pk.as_deref(), &mut cache,
        ));
        assert_eq!(store.get_channel_message_hidden_at(mid), Some(2_000));
        let (pts, psig, ppk) = store.load_deletion_proof(mid)
            .expect("proof stored so THIS node can re-serve the deletion");
        assert_eq!(pts, 2_000);
        assert_eq!(Some(psig.as_str()), sig.as_deref());
        assert_eq!(Some(ppk.as_str()), pk.as_deref());

        // Sync overlap re-apply: converged → quiet no-op (no fresh event).
        assert!(!apply_verified_channel_deletion(
            &store, sid, cid, mid, 2_000, sig.as_deref(), pk.as_deref(), &mut cache,
        ));
    }

    /// DM deletions bind to the ROW's direction: the signer derives from OUR
    /// is_mine, so a friend cannot censor OUR message with their own valid key.
    #[test]
    fn synced_dm_deletion_binds_author_direction() {
        let _g = crate::node::resolver::test_lock();
        let store = mem_store();
        let us = kp(233);
        let them = kp(234);
        let (us_id, them_id) = (us.peer_id(), them.peer_id());
        let (us_pk, them_pk) = (pk_b64(&us), pk_b64(&them));
        let mut cache = PkCache::new();

        // THEIR message (our is_mine=false): their proof (ctx = us) hides it.
        store.insert(&them_id, "their message", false, 1_000, None, None, Some("dm-1"), None, None, None, None).unwrap();
        let row = RowExtras::load_dm(&store, "dm-1");
        let (sig, pk) = sign_message_versioned(
            &them, &them_pk, "dm-delete", &us_id, &them_id, 2_000,
            &row.as_signed("dm-1"), &row.text.clone().unwrap_or_default(),
        );
        assert!(apply_verified_dm_deletion(
            &store, &us_id, "dm-1", 2_000, sig.as_deref(), pk.as_deref(), &mut cache,
        ));
        assert_eq!(store.get_dm_message_hidden_at("dm-1"), Some(2_000));

        // OUR message (is_mine=true): the friend signs a "deletion" of it with
        // their own key, and the row says WE authored it, so it must be rejected.
        store.insert(&them_id, "our message", true, 3_000, None, None, Some("dm-2"), None, None, None, None).unwrap();
        let row2 = RowExtras::load_dm(&store, "dm-2");
        let text2 = row2.text.clone().unwrap_or_default();
        let (esig, epk) = sign_message_versioned(
            &them, &them_pk, "dm-delete", &us_id, &them_id, 4_000,
            &row2.as_signed("dm-2"), &text2,
        );
        assert!(!apply_verified_dm_deletion(
            &store, &us_id, "dm-2", 4_000, esig.as_deref(), epk.as_deref(), &mut cache,
        ));
        assert_eq!(store.get_dm_message_hidden_at("dm-2"), None, "a friend must not delete OUR message");

        // Our own proof (signer = us, ctx = the convo peer) does hide it.
        let (sig2, pk2) = sign_message_versioned(
            &us, &us_pk, "dm-delete", &them_id, &us_id, 4_000,
            &row2.as_signed("dm-2"), &text2,
        );
        assert!(apply_verified_dm_deletion(
            &store, &us_id, "dm-2", 4_000, sig2.as_deref(), pk2.as_deref(), &mut cache,
        ));
        assert_eq!(store.get_dm_message_hidden_at("dm-2"), Some(4_000));
    }

    /// Outbound builder: a signed deletion is served as (proof ts, sig, pk);
    /// a legacy bare-hidden row is served with NO proof (receivers drop it);
    /// a visible row is untouched.
    #[test]
    fn deletion_proof_fields_serves_only_signed_proofs() {
        let store = mem_store();
        store.insert_channel_message("s", "c", "peer-a", "signed del", false, 1_000, None, None, Some("m-signed"), None, None, None, None).unwrap();
        store.insert_channel_message("s", "c", "peer-a", "legacy del", false, 1_100, None, None, Some("m-legacy"), None, None, None, None).unwrap();
        store.hide_channel_message("m-signed", 2_000, Some("SIG"), Some("PK")).unwrap();
        store.set_channel_message_hidden("m-legacy", 2_100).unwrap();

        assert_eq!(
            deletion_proof_fields(&store, Some(2_000), Some("m-signed")),
            (Some(2_000), Some("SIG".to_string()), Some("PK".to_string())),
        );
        assert_eq!(
            deletion_proof_fields(&store, Some(2_100), Some("m-legacy")),
            (Some(2_100), None, None),
        );
        assert_eq!(deletion_proof_fields(&store, None, Some("m-signed")), (None, None, None));
    }

    /// Guest preview: the hidden flag verifies from the item's own fields;
    /// a tampered or missing proof strips it (REJECT-ABSENT).
    #[test]
    fn guest_hidden_flag_requires_valid_item_proof() {
        let _g = crate::node::resolver::test_lock();
        let author = kp(235);
        let author_id = author.peer_id();
        let author_pk = pk_b64(&author);
        let (sid, cid) = ("srv-g", "chan-g");
        let extras = SignedExtras {
            mid: Some("g-1"), reply_to: None, file_id: None,
            order_us: Some(42), lp_digest: None,
            album: None,
        };
        let (sig, pk) = sign_message_versioned(
            &author, &author_pk, "ch-delete", &format!("{sid}:{cid}"),
            &author_id, 5_000, &extras, "guest text",
        );
        let mut item = crate::node::types::SyncMessageItem {
            s: author_id.clone(),
            t: "guest text".to_string(),
            ts: 4_000,
            sig: None,
            pk: None,
            mid: Some("g-1".to_string()),
            edited_at: None,
            reply_to: None,
            file_id: None,
            file_meta: None,
            hidden_at: Some(5_000),
            hidden_sig: sig.clone(),
            hidden_pk: pk.clone(),
            order_us: Some(42),
            lp_digest: None,
            lp: None,
            reactions: Vec::new(),
            album: None,
        };
        let mut cache = PkCache::new();
        assert_eq!(verified_guest_hidden_at(&item, sid, cid, &mut cache), Some(5_000));

        // Tampered text (a relay rewriting the plaintext batch) → stripped.
        item.t = "not what the author deleted".to_string();
        assert_eq!(verified_guest_hidden_at(&item, sid, cid, &mut cache), None);
        item.t = "guest text".to_string();

        // No proof at all → stripped (REJECT-ABSENT).
        item.hidden_sig = None;
        item.hidden_pk = None;
        assert_eq!(verified_guest_hidden_at(&item, sid, cid, &mut cache), None);
    }

    // ── 0.8.5: sync-batch reactions + guest content signatures ────────────

    /// Build a bare channel sync item (no reactions, no hidden flag) whose
    /// content signature is produced by `signer` over the v2 payload.
    fn signed_channel_item(
        signer: &NativeKeypair,
        claimed_sender: &str,
        sid: &str,
        cid: &str,
        mid: &str,
        ts: i64,
        text: &str,
    ) -> crate::node::types::SyncMessageItem {
        let extras = SignedExtras {
            mid: Some(mid), reply_to: None, file_id: None,
            order_us: Some(ts * 1000), lp_digest: None,
            album: None,
        };
        let (sig, pk) = sign_message_versioned(
            signer, &pk_b64(signer), "ch", &format!("{sid}:{cid}"),
            claimed_sender, ts, &extras, text,
        );
        crate::node::types::SyncMessageItem {
            s: claimed_sender.to_string(),
            t: text.to_string(),
            ts,
            sig,
            pk,
            mid: Some(mid.to_string()),
            edited_at: None,
            reply_to: None,
            file_id: None,
            file_meta: None,
            hidden_at: None,
            hidden_sig: None,
            hidden_pk: None,
            order_us: Some(ts * 1000),
            lp_digest: None,
            lp: None,
            reactions: Vec::new(),
            album: None,
        }
    }

    fn reaction_item(
        signer: Option<&NativeKeypair>,
        reactor: &str,
        mid: &str,
        emoji: &str,
        ts: i64,
    ) -> crate::node::types::SyncReactionItem {
        let (sig, pk) = match signer {
            Some(k) => sign_message(k, &pk_b64(k), &format!("reaction:{mid}:{emoji}:{ts}")),
            None => (None, None),
        };
        crate::node::types::SyncReactionItem {
            e: emoji.to_string(), p: reactor.to_string(), ts, sig, pk,
        }
    }

    /// Issue #45 follow-up: a card riding a sync batch is covered by the SAME
    /// signature that covers the text, because the digest is recomputed from the
    /// shipped preview rather than trusted from the wire's `lp_digest`.
    ///
    /// That ordering is the security property: backfill carries thumbnail bytes a
    /// peer will render, so a swap that kept the author's digest would phish.
    #[test]
    fn synced_link_preview_is_covered_by_the_item_signature() {
        let _g = crate::node::resolver::test_lock();
        let author = kp(242);
        let author_id = author.peer_id();
        let (sid, cid) = ("srv-lp", "chan-lp");
        let (mid, text, ts) = ("lp-item-1", "look https://example.com/x", 7_000i64);

        let card = LinkPreviewRef {
            url: "https://example.com/x".to_string(),
            title: "Real Title".to_string(),
            description: "real body".to_string(),
            domain: "example.com".to_string(),
            site_name: "Example".to_string(),
            thumb_webp_b64: Some("UkVBTA".to_string()),
            thumb_w: Some(800),
            thumb_h: Some(450),
            rich: None,
        };
        let digest = link_preview_digest(&card);
        let extras = SignedExtras {
            mid: Some(mid), reply_to: None, file_id: None,
            order_us: Some(ts * 1000), lp_digest: Some(&digest),
            album: None,
        };
        let (sig, pk) = sign_message_versioned(
            &author, &pk_b64(&author), "ch", &format!("{sid}:{cid}"),
            &author_id, ts, &extras, text,
        );

        // The responder ships card + digest together, as every packer does.
        let item = crate::node::types::SyncMessageItem {
            s: author_id.clone(),
            t: text.to_string(),
            ts,
            sig,
            pk,
            mid: Some(mid.to_string()),
            edited_at: None,
            reply_to: None,
            file_id: None,
            file_meta: None,
            hidden_at: None,
            hidden_sig: None,
            hidden_pk: None,
            order_us: Some(ts * 1000),
            lp_digest: Some(digest.clone()),
            lp: Some(Box::new(card.clone())),
            reactions: Vec::new(),
            album: None,
        };

        let verdict = |it: &crate::node::types::SyncMessageItem| {
            let d = crate::node::crypto_handler::backfill_lp_digest(
                it.lp.as_deref(), it.lp_digest.as_deref(),
            );
            let extras = SignedExtras {
                mid: it.mid.as_deref(), reply_to: it.reply_to.as_deref(),
                file_id: it.file_id.as_deref(), order_us: it.order_us,
                lp_digest: d.as_deref(),
                album: None,
            };
            crate::node::crypto_handler::check_backfill_signature(
                &it.s, "ch", &format!("{sid}:{cid}"),
                it.ts, it.edited_at, &extras, &it.t,
                it.sig.as_deref(), it.pk.as_deref(), &mut PkCache::new(),
            )
        };

        assert_eq!(
            verdict(&item),
            crate::node::crypto_handler::BackfillSig::Valid,
            "an intact card must verify — this is what carries previews to a peer \
             that was offline",
        );

        // A responder swaps the card and updates `lp_digest` to match, the best a
        // tamperer can do; recomputing means the author's signature misses it.
        let mut phish = item.clone();
        let evil = LinkPreviewRef {
            title: "Free crypto, click here".to_string(),
            thumb_webp_b64: Some("RVZJTA".to_string()),
            ..card.clone()
        };
        phish.lp_digest = Some(link_preview_digest(&evil));
        phish.lp = Some(Box::new(evil));
        assert_eq!(
            verdict(&phish),
            crate::node::crypto_handler::BackfillSig::Forged,
            "a swapped card must REJECT the whole item, not land as a preview",
        );

        // Keeping the author's digest while shipping someone else's card is the
        // same attack from the other side, and must fail the same way.
        let mut grafted = item.clone();
        grafted.lp = Some(Box::new(LinkPreviewRef {
            title: "Also not the real title".to_string(),
            ..card.clone()
        }));
        assert_eq!(
            verdict(&grafted),
            crate::node::crypto_handler::BackfillSig::Forged,
            "the wire's lp_digest must not be able to vouch for a different card",
        );

        // Digest-only, no card: a responder whose row arrived before previews rode
        // backfill. Still verifies, stores card-less, which is the behaviour every
        // peer had before this change, and the reason `lp_digest` stays on the wire.
        let mut legacy = item.clone();
        legacy.lp = None;
        assert_eq!(
            verdict(&legacy),
            crate::node::crypto_handler::BackfillSig::Valid,
            "a digest-only item from an older responder must still verify",
        );
    }

    /// Reactions riding a sync batch carry their OWN reactor id, so the
    /// item-level backfill verdict does not cover them. Each one must verify
    /// against `reaction:{mid}:{emoji}:{ts}` signed by that reactor.
    #[test]
    fn synced_reaction_requires_its_own_signature() {
        let _g = crate::node::resolver::test_lock();
        let alice = kp(240);
        let mallory = kp(241);
        let (alice_id, mallory_id) = (alice.peer_id(), mallory.peer_id());
        let mid = "r-mid-1";

        // Alice's genuine reaction.
        assert!(sync_reaction_accepted(
            mid, &reaction_item(Some(&alice), &alice_id, mid, "👍", 900),
        ));

        // Unsigned — the shape that used to be inserted verbatim.
        assert!(
            !sync_reaction_accepted(mid, &reaction_item(None, &alice_id, mid, "👍", 900)),
            "an unsigned synced reaction must not be stored",
        );

        // Mallory signs, but the item claims Alice reacted: the pk->claimed
        // reactor binding inside the verify rejects it.
        let mut impersonation = reaction_item(Some(&mallory), &mallory_id, mid, "💀", 901);
        impersonation.p = alice_id.clone();
        assert!(
            !sync_reaction_accepted(mid, &impersonation),
            "a reaction must not be attributable to someone who did not sign it",
        );

        // A real signature replayed onto a DIFFERENT message: the payload binds
        // the mid, so it cannot be moved.
        let real = reaction_item(Some(&alice), &alice_id, mid, "👍", 900);
        assert!(
            !sync_reaction_accepted("some-other-mid", &real),
            "a reaction signature must not replay onto another message",
        );

        // Emoji and timestamp are bound too.
        let mut swapped = reaction_item(Some(&alice), &alice_id, mid, "👍", 900);
        swapped.e = "🤡".to_string();
        assert!(!sync_reaction_accepted(mid, &swapped));
        let mut restamped = reaction_item(Some(&alice), &alice_id, mid, "👍", 900);
        restamped.ts = 5_000;
        assert!(!sync_reaction_accepted(mid, &restamped));
    }

    /// Guest public-channel preview: content signatures are verified from the
    /// item's own fields, because public-channel sync is PLAINTEXT and the
    /// relay can rewrite the batch. Failures drop the whole item.
    #[test]
    fn guest_item_requires_valid_content_signature() {
        let _g = crate::node::resolver::test_lock();
        let author = kp(242);
        let mallory = kp(243);
        let author_id = author.peer_id();
        let (sid, cid) = ("srv-gp", "chan-gp");
        let mut cache = PkCache::new();

        let good = signed_channel_item(&author, &author_id, sid, cid, "gp-1", 1_000, "hello");
        assert!(guest_item_accepted(&good, sid, cid, &mut cache));

        // Relay rewrites the text on an otherwise-valid item.
        let mut tampered = signed_channel_item(&author, &author_id, sid, cid, "gp-1", 1_000, "hello");
        tampered.t = "visit evil.example".to_string();
        assert!(
            !guest_item_accepted(&tampered, sid, cid, &mut cache),
            "rewritten text must drop the item",
        );

        // Relay grafts an attachment onto it — v2 binds file_id.
        let mut grafted = signed_channel_item(&author, &author_id, sid, cid, "gp-1", 1_000, "hello");
        grafted.file_id = Some("evil-file".to_string());
        assert!(!guest_item_accepted(&grafted, sid, cid, &mut cache));

        // Wholly fabricated, unsigned — the pre-0.8.5 guest browser rendered it.
        let mut unsigned = signed_channel_item(&author, &author_id, sid, cid, "gp-2", 1_100, "fake");
        unsigned.sig = None;
        unsigned.pk = None;
        assert!(
            !guest_item_accepted(&unsigned, sid, cid, &mut cache),
            "an unsigned guest item must be dropped",
        );

        // Mallory signs a message claiming to be from the author.
        let impersonated =
            signed_channel_item(&mallory, &author_id, sid, cid, "gp-3", 1_200, "not mine");
        assert!(
            !guest_item_accepted(&impersonated, sid, cid, &mut cache),
            "a message must not be attributable to someone who did not sign it",
        );

        // Wrong channel context: a real message from another channel cannot be
        // replayed into this one.
        assert!(!guest_item_accepted(&good, sid, "other-chan", &mut cache));
    }

    // ── Sync items never rewrite a row they do not own (HOL-SEC-004) ──────

    /// A channel sync item signed by `k` as its own author.
    fn own_channel_item(
        k: &NativeKeypair, sid: &str, cid: &str, mid: &str, text: &str, ts: i64,
        edited_at: Option<i64>, file_id: Option<&str>, lp: Option<&LinkPreviewRef>,
    ) -> crate::node::types::SyncMessageItem {
        let digest = lp.map(link_preview_digest);
        let extras = SignedExtras {
            mid: Some(mid), reply_to: None, file_id,
            order_us: Some(ts * 1000), lp_digest: digest.as_deref(), album: None,
        };
        let (sig, pk) = sign_message_versioned(
            k, &pk_b64(k), "ch", &format!("{sid}:{cid}"), &k.peer_id(),
            edited_at.unwrap_or(ts), &extras, text,
        );
        crate::node::types::SyncMessageItem {
            s: k.peer_id(), t: text.to_string(), ts, sig, pk,
            mid: Some(mid.to_string()), edited_at, reply_to: None,
            file_id: file_id.map(str::to_string), file_meta: None,
            hidden_at: None, hidden_sig: None, hidden_pk: None,
            order_us: Some(ts * 1000), lp_digest: digest, lp: lp.map(|c| Box::new(c.clone())),
            reactions: Vec::new(), album: None,
        }
    }

    fn file_meta_for(fid: &str, sender: &str, name: &str) -> crate::node::types::SyncFileMetaItem {
        crate::node::types::SyncFileMetaItem {
            fid: fid.to_string(), name: name.to_string(), ext: "pdf".to_string(),
            mime: "application/pdf".to_string(), size: 10, img: false, w: None, h: None,
            mid: None, ts: 1_000, sender: sender.to_string(), vthumb: None, thumb: None, sha256: None,
        }
    }

    #[test]
    fn authz_synced_channel_item_cannot_rewrite_another_authors_row() {
        let _g = crate::node::resolver::test_lock();
        let store = mem_store();
        let (bob, mallory, alice) = (kp(101), kp(102), kp(103));
        let (sid, cid, mid, text) = ("srv-b1", "chan-b1", "bob-msg-1", "meet at noon");
        let ingest = |item: &crate::node::types::SyncMessageItem| {
            crate::node::sync_handler::ingest_synced_channel_item(
                &store, sid, cid, item, &alice.peer_id(), &mut PkCache::new(),
            )
        };

        let bobs = own_channel_item(&bob, sid, cid, mid, text, 1_000, None, Some("bob-file"), None);
        let mut with_card = bobs.clone();
        with_card.file_meta = Some(file_meta_for("bob-file", &bob.peer_id(), "photo.pdf"));
        assert_eq!(ingest(&with_card).0, 1, "Bob's own item inserts his row");

        // Re-attribution, with a self-signed deletion riding the same item.
        let mut claim = own_channel_item(&mallory, sid, cid, mid, text, 1_000, None, None, None);
        let (hsig, hpk) = sign_channel_delete(
            &store, &mallory, &pk_b64(&mallory), &mallory.peer_id(), sid, cid, mid, 2_000,
        );
        (claim.hidden_at, claim.hidden_sig, claim.hidden_pk) = (Some(2_000), hsig, hpk);
        ingest(&claim);
        assert_eq!(store.get_channel_message_sender(mid).as_deref(), Some(bob.peer_id().as_str()));
        assert_eq!(store.get_channel_message_hidden_at(mid), None);

        // Text rewrite under Bob's name, and a card grafted onto his text.
        ingest(&own_channel_item(&mallory, sid, cid, mid, "send money", 1_000, Some(3_000), None, None));
        let card = LinkPreviewRef {
            url: "https://evil.example/".to_string(), title: "Login".to_string(),
            description: String::new(), domain: "evil.example".to_string(),
            site_name: String::new(), thumb_webp_b64: None, thumb_w: None, thumb_h: None, rich: None,
        };
        ingest(&own_channel_item(&mallory, sid, cid, mid, text, 1_000, Some(3_000), None, Some(&card)));
        let row = store.get_channel_message_sig_row(mid).expect("row");
        assert_eq!(row.text, text);
        assert_eq!(row.link_preview, None);

        // Mallory's own message relabelling Bob's file card.
        let mut relabel = own_channel_item(&mallory, sid, cid, "mal-1", "hi", 1_500, None, Some("bob-file"), None);
        relabel.file_meta = Some(file_meta_for("bob-file", &bob.peer_id(), "invoice.pdf"));
        ingest(&relabel);
        let mut smuggled = own_channel_item(&mallory, sid, cid, "mal-2", "hi", 1_600, None, None, None);
        smuggled.file_meta = Some(file_meta_for("bob-file", &bob.peer_id(), "invoice.pdf"));
        ingest(&smuggled);
        assert_eq!(store.get_file_metadata("bob-file").unwrap().unwrap().file_name, "photo.pdf");

        // Bob's own edit signed for ANOTHER channel does not land on this row.
        let elsewhere = own_channel_item(&bob, sid, "chan-other", mid, "moved", 1_000, Some(4_000), None, None);
        crate::node::sync_handler::ingest_synced_channel_item(
            &store, sid, "chan-other", &elsewhere, &alice.peer_id(), &mut PkCache::new(),
        );
        assert_eq!(store.get_channel_message_sig_row(mid).unwrap().text, text);

        // The author's own edit still applies.
        ingest(&own_channel_item(&bob, sid, cid, mid, "meet at one", 1_000, Some(5_000), None, None));
        assert_eq!(store.get_channel_message_sig_row(mid).unwrap().text, "meet at one");
    }

    /// The wedged-row heal still converges: a row stored under an unresolvable
    /// device id keeps its author's key, and the author's verified copy repairs it.
    #[test]
    fn synced_channel_item_still_repairs_a_row_wedged_under_a_device_id() {
        let _g = crate::node::resolver::test_lock();
        let store = mem_store();
        let (bob, ghost) = (kp(111), kp(112));
        let (sid, cid, mid) = ("srv-w", "chan-w", "wedged-1");
        let item = own_channel_item(&bob, sid, cid, mid, "hello", 1_000, None, None, None);
        store.insert_channel_message(
            sid, cid, &ghost.peer_id(), "hello", false, 1_000,
            item.sig.as_deref(), item.pk.as_deref(), Some(mid), None, None, Some(1_000_000), None,
        ).unwrap();
        crate::node::sync_handler::ingest_synced_channel_item(
            &store, sid, cid, &item, &kp(113).peer_id(), &mut PkCache::new(),
        );
        assert_eq!(store.get_channel_message_sender(mid).as_deref(), Some(bob.peer_id().as_str()));
    }

    #[test]
    fn authz_synced_dm_item_touches_only_its_own_conversation_and_direction() {
        let _g = crate::node::resolver::test_lock();
        let store = mem_store();
        let (bob, mallory) = (kp(121).peer_id(), kp(122).peer_id());
        store.insert(&bob, "from bob", false, 1_000, None, None, Some("dm-b"), None, None, None, None).unwrap();
        store.insert(&bob, "to bob", true, 1_100, None, None, Some("dm-a"), None, None, None, None).unwrap();
        let may = |convo: &str, is_mine: bool, mid: &str| change_may_touch_row(
            &store, &RowScope::Dm { convo, is_mine }, Some(mid),
        );
        assert!(!may(&mallory, false, "dm-b"), "another conversation's row");
        assert!(!may(&bob, true, "dm-b"), "Bob's row claimed as ours");
        assert!(!may(&bob, false, "dm-a"), "our row claimed as Bob's");
        assert!(may(&bob, false, "dm-b"));
        assert!(may(&bob, true, "dm-a"));
        assert!(may(&mallory, false, "not-stored-yet"));
    }
    // ── Live row changes (B3..B8, the live half of HOL-SEC-004) ──────────
    //
    // The live handlers open the DB by path, so these run on a temp file.

    fn file_db() -> (tempfile::TempDir, String, String) {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("live.db").to_string_lossy().into_owned();
        (tmp, path, "ab".repeat(32))
    }

    fn open(path: &str, pass: &str) -> crate::storage::MessageStore {
        crate::storage::MessageStore::open(path, pass).expect("open store")
    }

    fn evil_card() -> LinkPreviewRef {
        LinkPreviewRef {
            url: "https://evil.example/".to_string(), title: "Login".to_string(),
            description: String::new(), domain: "evil.example".to_string(),
            site_name: String::new(), thumb_webp_b64: None, thumb_w: None, thumb_h: None, rich: None,
        }
    }

    /// Sign `msg_type` over the stored row's extras as `k`, the way a sender does.
    #[allow(clippy::too_many_arguments)]
    fn row_sig(
        path: &str, pass: &str, is_channel: bool, k: &NativeKeypair,
        msg_type: &str, ctx: &str, mid: &str, ts: i64, text: &str,
    ) -> (Option<String>, Option<String>) {
        let store = open(path, pass);
        let row = if is_channel { RowExtras::load_channel(&store, mid) } else { RowExtras::load_dm(&store, mid) };
        sign_message_versioned(k, &pk_b64(k), msg_type, ctx, &k.peer_id(), ts, &row.as_signed(mid), text)
    }

    /// A card attach signed by `k` over the stored row, as `sign_attached_preview` does.
    fn card_sig(
        path: &str, pass: &str, is_channel: bool, k: &NativeKeypair, ctx: &str, mid: &str,
    ) -> AttachSig {
        let store = open(path, pass);
        let row = if is_channel { store.get_channel_message_sig_row(mid) } else { store.get_dm_message_sig_row(mid) };
        let msg_type = if is_channel { "ch" } else { "dm" };
        sign_attached_preview(&row.unwrap(), Some(&evil_card()), k, &pk_b64(k), msg_type, ctx, &k.peer_id(), mid)
    }

    #[allow(clippy::too_many_arguments)]
    async fn live_dm_edit(path: &str, pass: &str, k: &NativeKeypair, local: &str, ctx: &str, mid: &str, text: &str) {
        let (sig, pk) = row_sig(path, pass, false, k, "dm", ctx, mid, 5_000, text);
        let (tx, _rx) = mpsc::channel(16);
        handle_envelope_dm_edit(&tx, &k.peer_id(), local, mid.into(), text.into(), 5_000, sig, pk, path, pass).await;
    }

    async fn live_dm_delete(path: &str, pass: &str, k: &NativeKeypair, local: &str, ctx: &str, mid: &str) {
        let current = open(path, pass).get_dm_message_sig_row(mid).unwrap().text;
        let (sig, pk) = row_sig(path, pass, false, k, "dm-delete", ctx, mid, 6_000, &current);
        let (tx, _rx) = mpsc::channel(16);
        handle_envelope_dm_delete(&tx, &k.peer_id(), local, mid.into(), 6_000, sig, pk, path, pass).await;
    }

    #[allow(clippy::too_many_arguments)]
    async fn live_card(
        path: &str, pass: &str, k: &NativeKeypair, local: &str, ctx: &str, mid: &str,
        place: Option<(&str, &str)>,
    ) {
        let att = card_sig(path, pass, place.is_some(), k, ctx, mid);
        let (tx, _rx) = mpsc::channel(16);
        handle_envelope_link_preview_set(
            &tx, None, &k.peer_id(), local, mid.into(), Some(Box::new(evil_card())),
            att.ts, att.sig, att.pk,
            place.map(|p| p.0.to_string()), place.map(|p| p.1.to_string()),
            crate::node::frame_auth::now_ms(), path, pass,
        ).await;
    }

    /// B3, B5, B7: a live DM edit, deletion or card lands only on the sender's own
    /// row in its conversation with us, and our sibling's only on our own row. Each
    /// refused change is validly signed by the device that sends it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn authz_live_dm_change_touches_only_the_senders_own_rows() {
        let _g = crate::node::resolver::test_lock();
        let (_tmp, path, pass) = file_db();
        let (alice, bob, mallory) = (kp(131), kp(132), kp(133));
        let (a, b) = (alice.peer_id(), bob.peer_id());
        {
            let store = open(&path, &pass);
            store.insert(&b, "from bob", false, 1_000, None, None, Some("b1"), None, None, Some(1_000_000), None).unwrap();
            store.insert(&b, "to bob", true, 1_100, None, None, Some("a1"), None, None, Some(1_100_000), None).unwrap();
        }
        let row = |mid: &str| open(&path, &pass).get_dm_message_sig_row(mid).unwrap();

        live_dm_edit(&path, &pass, &mallory, &a, &a, "b1", "send money").await;
        live_dm_edit(&path, &pass, &bob, &a, &a, "a1", "words in our mouth").await;
        live_dm_edit(&path, &pass, &alice, &a, &b, "b1", "sibling rewrites bob").await;
        assert_eq!(row("b1").text, "from bob");
        assert_eq!(row("a1").text, "to bob");

        live_dm_delete(&path, &pass, &mallory, &a, &a, "b1").await;
        live_dm_delete(&path, &pass, &bob, &a, &a, "a1").await;
        assert_eq!(open(&path, &pass).get_dm_message_hidden_at("b1"), None);
        assert_eq!(open(&path, &pass).get_dm_message_hidden_at("a1"), None);

        live_card(&path, &pass, &mallory, &a, &a, "b1", None).await;
        assert_eq!(row("b1").link_preview, None);

        // The row's own author, and our sibling on our own row, still go through.
        live_card(&path, &pass, &bob, &a, &a, "b1", None).await;
        assert_eq!(row("b1").link_preview, Some(evil_card()));
        live_dm_edit(&path, &pass, &bob, &a, &a, "b1", "from bob, edited").await;
        live_dm_edit(&path, &pass, &alice, &a, &b, "a1", "to bob, edited").await;
        assert_eq!(row("b1").text, "from bob, edited");
        assert_eq!(row("a1").text, "to bob, edited");
        live_dm_delete(&path, &pass, &bob, &a, &a, "b1").await;
        assert!(open(&path, &pass).get_dm_message_hidden_at("b1").is_some());
    }

    /// B6: a DM reaction attaches only to a row of the reactor's conversation with
    /// us (either direction), or anywhere in our DMs for our own sibling; never to a
    /// channel message or a missing row.
    #[test]
    fn authz_dm_reaction_lands_only_in_the_reactors_conversation() {
        let _g = crate::node::resolver::test_lock();
        let store = mem_store();
        let (a, b, m) = (kp(141).peer_id(), kp(142).peer_id(), kp(143).peer_id());
        store.insert(&b, "from bob", false, 1_000, None, None, Some("b1"), None, None, None, None).unwrap();
        store.insert(&b, "to bob", true, 1_100, None, None, Some("a1"), None, None, None, None).unwrap();
        store.insert_channel_message("srv", "chan", &b, "hi", false, 1_200, None, None, Some("c1"), None, None, None, None).unwrap();
        assert!(!dm_reaction_target_ok(&store, "b1", &m, &a), "another conversation's row");
        assert!(!dm_reaction_target_ok(&store, "c1", &b, &a), "a channel message");
        assert!(!dm_reaction_target_ok(&store, "gone", &b, &a), "no row");
        assert!(dm_reaction_target_ok(&store, "b1", &b, &a));
        assert!(dm_reaction_target_ok(&store, "a1", &b, &a));
        assert!(dm_reaction_target_ok(&store, "b1", &a, &a), "our sibling");
    }

    /// HOL-SEC-036 (L3). A block dropped new DMs, but a blocked friend's edits,
    /// cards, deletions and reactions on the rows already in our DMs still landed.
    #[test]
    fn authz_a_blocked_friend_changes_nothing_in_our_dms() {
        let _g = crate::node::resolver::test_lock();
        crate::node::blocklist::clear_for_test();
        let store = mem_store();
        let (a, b) = (kp(144).peer_id(), kp(145).peer_id());
        store.insert(&b, "from bob", false, 1_000, None, None, Some("b1"), None, None, None, None).unwrap();
        store.insert(&b, "to bob", true, 1_100, None, None, Some("a1"), None, None, None, None).unwrap();
        assert!(live_dm_change(&store, "b1", &b, &a).is_some());
        assert!(dm_reaction_target_ok(&store, "b1", &b, &a));

        crate::node::blocklist::block(&b);
        assert!(
            live_dm_change(&store, "b1", &b, &a).is_none(),
            "HOL-SEC-036: a blocked friend edited, carded or deleted a row in our DMs",
        );
        assert!(
            !dm_reaction_target_ok(&store, "b1", &b, &a),
            "HOL-SEC-036: a blocked friend reacted in our DMs",
        );
        assert!(live_dm_change(&store, "a1", &a, &a).is_some(), "our own sibling is never blocked");
        crate::node::blocklist::clear_for_test();
    }

    /// A live channel edit, deletion, card or reaction must name the channel its
    /// row sits in. Naming another one passed with the author's own signature for
    /// that context, and left the mute gate reading a server the sender picked.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn authz_live_channel_change_must_name_the_rows_own_channel() {
        let _g = crate::node::resolver::test_lock();
        let (_tmp, path, pass) = file_db();
        let (alice, bob, mallory) = (kp(151), kp(152), kp(153));
        let (a, b, m) = (alice.peer_id(), bob.peer_id(), mallory.peer_id());
        let (sid, cid) = ("srv-a", "chan-a");
        open(&path, &pass).insert_channel_message(
            sid, cid, &b, "hello", false, 1_000, None, None, Some("c1"), None, None, Some(1_000_000), None,
        ).unwrap();
        let text = || open(&path, &pass).get_channel_message_sig_row("c1").unwrap().text;
        let (tx, _rx) = mpsc::channel(64);
        let named = |place: Option<(&str, &str)>| {
            (place.map(|p| p.0.to_string()), place.map(|p| p.1.to_string()))
        };

        for place in [Some(("srv-b", "chan-b")), Some((sid, "chan-b")), None] {
            let ctx = place.map(|(s, c)| format!("{s}:{c}")).unwrap_or_else(|| ":".to_string());
            let (sig, pk) = row_sig(&path, &pass, true, &bob, "ch", &ctx, "c1", 5_000, "moved");
            let (s, c) = named(place);
            handle_envelope_edit_message(&tx, &bob, None, &b, "c1".into(), "moved".into(), 5_000, sig, pk, s, c, &path, &pass).await;
        }
        assert_eq!(text(), "hello");

        let (sig, pk) = row_sig(&path, &pass, true, &bob, "ch-delete", "srv-b:chan-b", "c1", 6_000, "hello");
        let (s, c) = named(Some(("srv-b", "chan-b")));
        handle_envelope_delete_message(&tx, &bob, &b, "c1".into(), 6_000, sig, pk, s, c, &path, &pass).await;
        assert_eq!(open(&path, &pass).get_channel_message_hidden_at("c1"), None);

        live_card(&path, &pass, &bob, &a, "srv-b:chan-b", "c1", Some(("srv-b", "chan-b"))).await;
        assert_eq!(open(&path, &pass).get_channel_message_sig_row("c1").unwrap().link_preview, None);

        for (place, emoji) in [(Some(("srv-b", "chan-b")), "elsewhere"), (None, "as a DM"), (Some((sid, cid)), "here")] {
            let (sig, pk) = sign_message(&mallory, &pk_b64(&mallory), &format!("reaction:c1:{emoji}:7000"));
            let (s, c) = named(place);
            handle_envelope_add_reaction(&tx, &mallory, None, &m, "c1".into(), emoji.into(), 7_000, sig, pk, s, c, &path, &pass).await;
        }
        let reactions = open(&path, &pass).load_reactions_for_messages(&["c1".to_string()]).unwrap();
        assert_eq!(reactions.get("c1"), Some(&vec![("here".to_string(), m.clone(), 7_000)]));

        let (sig, pk) = row_sig(&path, &pass, true, &bob, "ch", &format!("{sid}:{cid}"), "c1", 5_000, "hello again");
        let (s, c) = named(Some((sid, cid)));
        handle_envelope_edit_message(&tx, &bob, None, &b, "c1".into(), "hello again".into(), 5_000, sig, pk, s, c, &path, &pass).await;
        assert_eq!(text(), "hello again");
    }

    /// C1, C4, C5 at handler level: the Olm, MLS and public arms all run this ingest
    /// with our state, so a validly signed post from a stranger, or into a channel the
    /// member may not post in, is never stored.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn authz_live_channel_post_is_judged_by_our_state() {
        let _g = crate::node::resolver::test_lock();
        let (_tmp, path, pass) = file_db();
        let (mut state, _owner) = crate::crdt::testkeys::owned_state("srv-c", "C", 171);
        let (member, stranger, us) = (kp(181), kp(182), kp(183));
        for id in [member.peer_id(), us.peer_id()] {
            let op = state.create_op(crate::crdt::operations::CrdtPayload::MemberAdded {
                peer_id: id, display_name: "m".into(),
                follow: None,
            });
            state.apply_op(&op).unwrap();
        }
        for (cid, posting) in [("general", "everyone"), ("news", "admin")] {
            let op = state.create_op(crate::crdt::operations::CrdtPayload::ChannelAdded {
                channel_id: cid.into(), name: cid.into(), category: None, channel_type: "text".into(),
            });
            state.apply_op(&op).unwrap();
            let op = state.create_op(crate::crdt::operations::CrdtPayload::ChannelPostingChanged {
                channel_id: cid.into(), posting: posting.into(),
            });
            state.apply_op(&op).unwrap();
        }
        let (tx, _rx) = mpsc::channel(16);
        let local = us.peer_id();
        for (k, cid, mid) in [
            (&stranger, "general", "from-stranger"),
            (&member, "news", "into-admin-only"),
            (&member, "general", "fine"),
        ] {
            let extras = SignedExtras {
                mid: Some(mid), reply_to: None, file_id: None, order_us: Some(1_000_000),
                lp_digest: None, album: None,
            };
            let (sig, pk) = sign_message_versioned(
                k, &pk_b64(k), "ch", &format!("srv-c:{cid}"), &k.peer_id(), 1_000, &extras, "hello",
            );
            handle_envelope_channel_message(
                &tx, k, Some(&state), &mut SlowModeClock::default(), &local, k.peer_id(), "srv-c".into(), cid.into(),
                "hello".into(), 1_000, sig, pk, Some(mid.into()), None, None, None, Some(1_000_000), None,
                &path, &pass,
            ).await;
        }
        let store = open(&path, &pass);
        assert!(!store.channel_message_exists("from-stranger"));
        assert!(!store.channel_message_exists("into-admin-only"));
        assert!(store.channel_message_exists("fine"));
    }

    /// C7: slow mode judges a fresh post by our own clock, so spacing future stamps
    /// no longer gets a burst through, while a post replayed from the relay ring
    /// long after it was written still lands, and so does a second copy of one.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn slow_mode_judges_fresh_posts_by_our_clock() {
        let _g = crate::node::resolver::test_lock();
        let (_tmp, path, pass) = file_db();
        let (mut state, _owner) = crate::crdt::testkeys::owned_state("srv-f", "F", 211);
        let (bob, us) = (kp(214), kp(215));
        let (b, a) = (bob.peer_id(), us.peer_id());
        for op in [
            crate::crdt::operations::CrdtPayload::MemberAdded { peer_id: b.clone(), display_name: "b".into(), follow: None, },
            crate::crdt::operations::CrdtPayload::MemberAdded { peer_id: a.clone(), display_name: "a".into(), follow: None, },
            crate::crdt::operations::CrdtPayload::ChannelAdded {
                channel_id: "general".into(), name: "general".into(), category: None, channel_type: "text".into(),
            },
            crate::crdt::operations::CrdtPayload::ChannelSlowModeChanged { channel_id: "general".into(), seconds: 60 },
        ] {
            let op = state.create_op(op);
            state.apply_op(&op).unwrap();
        }
        let (tx, _rx) = mpsc::channel(16);
        let mut clock = SlowModeClock::default();
        let now = crate::node::types::now_ms();
        for (mid, ts) in [("first", now), ("spaced", now + 61_000), ("first", now), ("replayed", now - 600_000)] {
            let extras = SignedExtras { mid: Some(mid), order_us: Some(ts * 1000), ..SignedExtras::default() };
            let (sig, pk) = sign_message_versioned(&bob, &pk_b64(&bob), "ch", "srv-f:general", &b, ts, &extras, mid);
            handle_envelope_channel_message(
                &tx, &us, Some(&state), &mut clock, &a, b.clone(), "srv-f".into(), "general".into(),
                mid.into(), ts, sig, pk, Some(mid.into()), None, None, None, Some(ts * 1000), None,
                &path, &pass,
            ).await;
        }
        let store = open(&path, &pass);
        assert!(store.channel_message_exists("first"));
        assert!(!store.channel_message_exists("spaced"), "a second fresh post inside the window, by our clock");
        assert!(store.channel_message_exists("replayed"), "an old post replayed later is judged by its own stamp");
    }

    /// C11: a body over the size limit is dropped whole on the live post, live edit
    /// and sync paths, never clipped. A full composer of Cyrillic (8,000 bytes) is
    /// stored exactly as sent; the old 4,000-byte clamp cut it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn oversized_message_is_dropped_whole_on_every_path() {
        use crate::node::crypto_handler::MAX_MESSAGE_BYTES;
        let _g = crate::node::resolver::test_lock();
        let (_tmp, path, pass) = file_db();
        let (mut state, _owner) = crate::crdt::testkeys::owned_state("srv-d", "D", 191);
        let (bob, us) = (kp(194), kp(195));
        let (b, a) = (bob.peer_id(), us.peer_id());
        for op in [
            crate::crdt::operations::CrdtPayload::MemberAdded { peer_id: b.clone(), display_name: "b".into(), follow: None, },
            crate::crdt::operations::CrdtPayload::MemberAdded { peer_id: a.clone(), display_name: "a".into(), follow: None, },
            crate::crdt::operations::CrdtPayload::ChannelAdded {
                channel_id: "general".into(), name: "general".into(), category: None, channel_type: "text".into(),
            },
        ] {
            let op = state.create_op(op);
            state.apply_op(&op).unwrap();
        }
        let (tx, _rx) = mpsc::channel(16);
        let long = "я".repeat(4_000);
        let over = "x".repeat(MAX_MESSAGE_BYTES + 1);
        let channel_text = |mid: &str| open(&path, &pass).get_channel_message_sig_row(mid).map(|r| r.text);

        for (mid, text) in [("fits", &long), ("too-big", &over)] {
            let extras = SignedExtras { mid: Some(mid), order_us: Some(1_000_000), ..SignedExtras::default() };
            let (sig, pk) = sign_message_versioned(&bob, &pk_b64(&bob), "ch", "srv-d:general", &b, 1_000, &extras, text);
            handle_envelope_channel_message(
                &tx, &us, Some(&state), &mut SlowModeClock::default(), &a, b.clone(), "srv-d".into(), "general".into(),
                text.clone(), 1_000, sig, pk, Some(mid.into()), None, None, None, Some(1_000_000), None,
                &path, &pass,
            ).await;
        }
        assert_eq!(channel_text("fits").as_ref(), Some(&long));
        assert_eq!(channel_text("too-big"), None);

        let (sig, pk) = row_sig(&path, &pass, true, &bob, "ch", "srv-d:general", "fits", 5_000, &over);
        handle_envelope_edit_message(
            &tx, &us, Some(&state), &b, "fits".into(), over.clone(), 5_000, sig, pk,
            Some("srv-d".into()), Some("general".into()), &path, &pass,
        ).await;
        assert_eq!(channel_text("fits").as_ref(), Some(&long), "an oversized edit leaves the row alone");

        open(&path, &pass).insert(&b, "from bob", false, 1_000, None, None, Some("b1"), None, None, Some(1_000_000), None).unwrap();
        live_dm_edit(&path, &pass, &bob, &a, &a, "b1", &over).await;
        assert_eq!(open(&path, &pass).get_dm_message_sig_row("b1").unwrap().text, "from bob");

        let mut cache = PkCache::new();
        let store = open(&path, &pass);
        for (mid, text, stored) in [("synced-big", &over, 0), ("synced-long", &long, 1)] {
            let item = own_channel_item(&bob, "srv-d", "general", mid, text, 2_000, None, None, None);
            let (inserted, _) = super::super::sync_handler::ingest_synced_channel_item(
                &store, "srv-d", "general", &item, &a, &mut cache,
            );
            assert_eq!(inserted, stored, "{mid}");
        }
        assert_eq!(channel_text("synced-long").as_ref(), Some(&long));
        assert_eq!(channel_text("synced-big"), None);
    }
}

/// A channel's new-post hint, from either lane: surfaced only for a post the sender
/// may make in a channel we may see, and never for our own identity's post.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn deliver_channel_hint(
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &HashMap<String, ServerState>,
    local_peer_str: &str,
    sender_device: &str,
    server_id: String,
    channel_id: String,
    message_id: String,
    has_everyone: bool,
    mentioned_names: Vec<String>,
    reply_to_sender: Option<String>,
) {
    // Our own siblings get the hint too, and a hint for our own post counted it
    // unread on every other device (#80).
    if super::resolver::same_identity(sender_device, local_peer_str) {
        return;
    }
    let signal_ok = server_states.get(&server_id).is_some_and(|state| {
        channel_signal_accepted(
            state, &super::resolver::resolve(sender_device), local_peer_str, &channel_id,
            crate::crdt::hlc::wall_clock_ms(),
        )
    });
    if !signal_ok {
        return;
    }
    // Reply-to-ME only: a bare "is a reply" fired the mentions-only level on every
    // reply to anyone (#42).
    let is_reply_to_own = reply_to_sender
        .as_deref()
        .is_some_and(|s| super::resolver::same_identity(s, local_peer_str));
    let _ = event_tx.send(NetworkEvent::ChannelNotificationHint {
        server_id, channel_id, from_peer: sender_device.to_string(),
        message_id, has_everyone, mentioned_names, is_reply_to_own,
    }).await;
}
