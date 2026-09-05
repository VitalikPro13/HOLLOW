use std::collections::{HashMap, HashSet};

use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use crate::crdt::server_state::ServerState;
use super::crypto_handler::{
    link_preview_digest, sign_message, sign_message_versioned,
    verify_message_signature, verify_message_signature_v2, PkCache, SignedExtras,
    peer_is_reachable, send_mls_broadcast, send_mls_broadcast_topic, send_encrypted_message,
    send_message_to_peer,
};
use super::types::*;

/// Owned v2-signature extras loaded from an EXISTING message row. Edit and
/// delete signatures bind the same structural fields as the original message
/// (the row's reply_to / file_id / order_us / link preview are immutable under
/// edit), so the SIGN sites load them from the signer's row and the live
/// VERIFY sites reconstruct them from the receiver's row — both ends agree by
/// construction. A missing row degrades to mid-only extras (verification then
/// fails unless the signer also saw no row, which is the correct outcome).
pub(crate) struct RowExtras {
    pub text: Option<String>,
    pub reply_to: Option<String>,
    pub file_id: Option<String>,
    pub order_us: Option<i64>,
    pub lp_digest: Option<String>,
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
            return Self { text: None, reply_to: None, file_id: None, order_us: None, lp_digest: None };
        };
        Self {
            lp_digest: r.link_preview.as_ref().map(link_preview_digest),
            text: Some(r.text),
            reply_to: r.reply_to_mid,
            file_id: r.file_id,
            order_us: r.order_us,
        }
    }

    pub(crate) fn as_signed<'a>(&'a self, mid: &'a str) -> SignedExtras<'a> {
        SignedExtras {
            mid: Some(mid),
            reply_to: self.reply_to.as_deref(),
            file_id: self.file_id.as_deref(),
            order_us: self.order_us,
            lp_digest: self.lp_digest.as_deref(),
        }
    }
}

// ── Deletion propagation through sync (0.8.4) ────────────────────────
//
// `hidden_at` on a sync item is honored ONLY with the author's own deletion
// signature riding next to it (`hidden_sig`/`hidden_pk` — the "ch-delete" /
// "dm-delete" proof created at deletion time and stored in
// `message_deletions`). REJECT-ABSENT: a hidden flag with no valid proof is
// DROPPED, never applied — a bare `hidden_at` in a sync batch is a
// forge-a-deletion / censorship primitive (any sync responder, or a relay
// tampering with a plaintext public-channel batch, could hide arbitrary
// messages on the victim). There is deliberately NO tolerate-absent fallback:
// tolerating absence reopens the gap via omit-the-sig. The accepted cost is
// that pre-signing (ancient, unsigned) deletions no longer propagate through
// sync. Deletes are SELF-ONLY (live handlers reject sender != author), so
// verification is a plain author-signature check — and the author is derived
// from the RECEIVER'S ROW, never from item fields the responder controls.

/// Outbound half: the `(hidden_at, hidden_sig, hidden_pk)` triple for a sync
/// item built from row `mid`. Attaches the stored deletion proof; prefers the
/// proof's own `deleted_at` over a drifted row `hidden_at` so the served
/// (ts, sig) pair is always the one the author signed. A hidden row with no
/// signed proof is served bare (receivers drop the flag).
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

/// Inbound half (channel): verify + apply one sync-carried deletion. The
/// proof is checked against OUR row (author = row sender resolved to master,
/// extras/text from the row — the same reconstruction the live DeleteMessage
/// handler uses), then stored for onward propagation and `hidden_at` set.
/// Returns true when the row was NEWLY hidden (callers emit their deletion
/// event on true); false = rejected, already hidden, or no such row.
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
    // MISSING its proof still runs the verify below so a valid arriving proof
    // is adopted (heals legacy-hidden rows for onward propagation).
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

/// Inbound half (DM): like [`apply_verified_channel_deletion`] but signer and
/// context depend on the ROW's direction. `is_mine` comes from OUR row —
/// deriving it from the item's `mine` flag would let a friend "delete" OUR
/// message with THEIR OWN (valid) signature. "dm-delete" signing convention
/// (`handle_delete_dm_message` + the live receive arm): signer = the
/// deleter's master, context = the OTHER party's master.
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

/// Guest-preview half: verify a public-channel sync item's CONTENT signature
/// from the item's own fields. `false` = drop the item entirely.
///
/// Public-channel sync is PLAINTEXT, so the relay (or any responder) can
/// rewrite a batch wholesale — text, sender, reply target, attachment, the
/// lot. Members already refuse an unverified item at the four backfill sites;
/// the guest browser used to render whatever arrived, which made the public
/// preview — the one surface strangers see — the softest one in the app.
///
/// Same rule as the member path (`check_backfill_signature` under
/// [`REQUIRE_SIGNED_BACKFILL`]): signer = `resolve(m.s)`, type "ch", context
/// "{sid}:{cid}", extras from the item, edited rows verified against their
/// edit signature. Failures are DROPPED rather than flagged, which keeps the
/// FFI struct and the guest UI unchanged.
pub(crate) fn guest_item_accepted(
    m: &super::types::SyncMessageItem,
    sid: &str,
    cid: &str,
    pk_cache: &mut PkCache,
) -> bool {
    // Digest from the shipped card, so the card is covered by the same check
    // that covers the text. This is the whole reason a guest may render a
    // preview at all: the batch is PLAINTEXT, so without binding the card a
    // relay could paste a phishing one onto any message a stranger reads.
    let lp_digest = super::crypto_handler::backfill_lp_digest(
        m.lp.as_deref(), m.lp_digest.as_deref(),
    );
    let extras = SignedExtras {
        mid: m.mid.as_deref(),
        reply_to: m.reply_to.as_deref(),
        file_id: m.file_id.as_deref(),
        order_us: m.order_us,
        lp_digest: lp_digest.as_deref(),
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

/// Guest-preview half: verify a public-channel sync item's hidden flag from
/// the item's own fields (guests hold no rows to check against). Returns the
/// `hidden_at` to honor, or `None` to strip the flag (absent/invalid proof).
/// The pubkey↔signer binding inside the verify stops a non-author forging
/// the proof; a replayed REAL deletion is legitimate propagation.
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

    // Wrap DM in signed envelope.
    let local_peer = local_peer_str.to_string();
    // Lamport-bumped send stamp (chat_clock.rs): strictly after every message
    // this device has seen, so cross-machine clock skew can't sort our reply
    // above the message it answers. The signed ms `ts` and the `order_us`
    // ordering key both derive from the ONE stamp (order_us is NOT signed;
    // it's carried over the wire + persisted for same-ms burst ordering).
    let dm_order_us = crate::chat_clock::next_send_stamp_us();
    let dm_timestamp = dm_order_us / 1000;
    // v2 signature binds the structured fields exactly as they ride the wire
    // envelope below — the receiver reconstructs these extras from the same
    // envelope fields it persists.
    let lp_digest = link_preview.as_ref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: Some(&message_id),
        reply_to: reply_to_mid.as_deref(),
        file_id: None,
        order_us: Some(dm_order_us),
        lp_digest: lp_digest.as_deref(),
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
        }),
    };
    let envelope_json = serde_json::to_string(&build_dm(None))
        .unwrap_or_else(|_| text.clone());
    // Sibling self-echo variant carries the recipient master as the conversation
    // key, so our other device files it under the right thread (not under us).
    let sibling_envelope_json = serde_json::to_string(&build_dm(Some(recipient_master.clone())))
        .unwrap_or_else(|_| text.clone());

    // Persist sent DM locally with the same Rust-generated timestamp.
    // This ensures DM sync timestamps are consistent (no Dart DateTime.now() mismatch).
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.insert(
                &peer_id_str, &text, true, dm_timestamp,
                sig.as_deref(), pk.as_deref(), Some(&message_id),
                reply_to_mid.as_deref(), None, Some(dm_order_us),
            );
            if let Some(lp) = &link_preview {
                if let Ok(lp_json) = serde_json::to_string(lp) {
                    let _ = store.update_link_preview(&message_id, &lp_json);
                }
            }
        }
    }

    // ── Multi-device fan-out (Phase 6, Step 3) ──────────────────────────
    // `peer_id_str` is the recipient's MASTER identity (that's what the friend
    // list / UI keys on). Olm sessions, `pending_messages`, and room membership
    // are all keyed by DEVICE peer_ids, so encrypting to the bare master would
    // hit no session and target a peer nobody authenticates as. Expand the
    // master into its known device peer_ids and run the per-device send for
    // each. Single-device friends (no device list ingested) resolve to an empty
    // device set → fall back to the master id as-is = byte-for-byte old behavior.
    //
    // We ALSO fan out to our OWN other online devices (self fan-out), so a DM
    // typed on one of our devices appears live on the sibling. The local DB
    // insert + `MessageSent` event above already happened keyed on the master,
    // so the SENDING device's UI is correct; this delivers the same envelope to
    // our other devices' Olm inboxes (they persist it on receive, keyed by our
    // master via `convo_peer`).
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

/// Expand a recipient MASTER id into its device set (plus our own sibling
/// devices for self fan-out) and deliver one already-signed DM envelope to each
/// (Phase 6 multi-device, Step 3). Single-device recipients (no device list
/// ingested) resolve to an empty device set → the master id is used as-is, which
/// is byte-for-byte the pre-multi-device behavior. Used by every DM send path:
/// new message, edit, delete, reaction add/remove.
///
/// NOTE: `pending_messages` is keyed per DEVICE, so a queued envelope is drained
/// to the right device when ITS session establishes (PeerJoined/RoomMembers/
/// KeyBundle). The caller is responsible for the local DB write + UI event, both
/// of which stay keyed on the MASTER.
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
    // For DirectMessage sends, a variant of the envelope with `convo` set to
    // `recipient_master` — delivered to OUR OWN sibling devices so they file the
    // echo under the right conversation (not under ourselves). `None` for
    // edit/delete/reaction (siblings resolve the convo from the message row by
    // mid on receive), so siblings get the plain `envelope_json`.
    sibling_envelope_json: Option<&str>,
) {
    // Recipient's devices (genuine other party) always get the plain envelope.
    // Target set = the persisted device list UNION the devices CURRENTLY in the
    // DM room that resolve to this master. The live room is authoritative: a
    // device that's online right now must be reached even if the stored device
    // list is stale/polluted (ghost ids from old wipe+reimport tests) or simply
    // doesn't yet contain this freshly-rotated device id. Without the live union
    // the fan-out would deliver only to a dead ghost id and skip the connected
    // device — the exact "first message lost, peer shows offline" symptom.
    let dm_room = dm_room_code(local_peer_str, recipient_master);
    // Self-DM ("Saved messages"): the recipient IS us — there is no other party
    // to deliver to, and the recipient-branch fallback below would queue a dead
    // envelope under the bare master id forever. Our own siblings (next block)
    // still get their copy.
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

    // Our own sibling devices (self fan-out) get the convo-tagged variant when one
    // is supplied; otherwise the plain envelope. Same live-union logic, excluding
    // THIS device (never echo to ourselves).
    let own_master = super::resolver::resolve(local_peer_str);
    let sibling_json = sibling_envelope_json.unwrap_or(envelope_json);
    // Siblings: live-only (None for olm) — an offline own-sibling is reached via
    // pending_messages queue + Step 5 backfill, NOT via the offline-buffer/push
    // path (we never want to PUSH our own phone for our OWN outgoing message).
    let mut siblings: HashSet<String> = collect_target_devices(
        ws_room_peers, None, &dm_room, &own_master, "", /*exclude*/ Some(device_peer_id),
    ).into_iter().collect();
    // ALSO union peers in our `inbox:{master}` room. A freshly-linked sibling joins
    // the inbox room IMMEDIATELY (it's the sibling rendezvous) but may not have
    // joined this specific DM-with-friend room yet when we send our FIRST message —
    // so the DM-room union alone misses it and the echo goes to a stale ghost id
    // from the stored device list. The inbox union catches the live sibling right
    // away (fixes "VM's first DM to AL never mirrors to Pixel").
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
/// LIVENESS-FILTERED (Step 7 ghost fix): a stored device id from
/// `resolver::devices_for` is targeted ONLY if it is reachable — it has an Olm
/// session OR is currently in a room. A device list accumulates dead "ghost" ids
/// across re-link cycles (union-merge never prunes); without this filter the
/// fan-out addresses every ghost → no session → `send_dm_to_device` either
/// room-sends ("Sent encrypted DM to offline <ghost>", firing a spurious push +
/// unread on the receiver) or queues a KeyRequest forever. A ghost has been seen
/// by NO device, so it has neither a session nor room presence → it's dropped.
/// A genuinely-offline REAL device (seen before → has a persisted session) still
/// passes and gets the normal offline-buffer treatment.
///
/// The set is then UNIONed with every peer currently in `dm_room` that resolves to
/// `master` (the live room is always authoritative — a freshly-rotated device id
/// not yet in the stored list is still reached). `fallback_self` is returned only
/// if the whole set is empty and non-empty itself (single-device recipient → send
/// to the master id as-is, pre-multi-device behavior); pass "" to skip the fallback
/// (self fan-out, where "no live siblings" must mean send to nobody). `exclude`
/// drops one id (our own device).
fn collect_target_devices(
    ws_room_peers: &HashMap<String, HashSet<String>>,
    // When Some, also include OFFLINE-but-real devices (Step 9A push): a device
    // that is in the resolver's signed-list view AND we hold an Olm session with
    // → it gets the offline-buffer/push treatment so a fully-quit phone wakes.
    // None = live-only (self fan-out to our own siblings: never push our own phone).
    olm: Option<&OlmManager>,
    dm_room: &str,
    master: &str,
    fallback_self: &str,
    exclude: Option<&str>,
) -> Vec<String> {
    // Online devices: stored devices CURRENTLY IN A ROOM (reachable right now).
    // Room-presence is the unambiguous liveness test that drops dead ghosts (a
    // ghost has a STALE persisted Olm session, so `has_session` alone is NOT a
    // liveness test — it's only used below to qualify the OFFLINE set).
    let mut set: HashSet<String> = super::resolver::devices_for(master)
        .into_iter()
        .filter(|d| super::crypto_handler::ws_room_for_peer(ws_room_peers, d).is_some())
        .collect();
    // Offline-but-real devices (Step 9A) — see `offline_session_devices`. Self
    // fan-out passes None to skip this (never push our own phone).
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

/// Offline-but-real devices of one master (Step 9A push): a known device of
/// this master that is NOT in a room but we DO hold an Olm session with. The
/// resolver's `devices_for` reflects the signed device list MINUS revoked
/// tombstones (Step 7 `forget`s a revoked device), so it's the authoritative
/// "real devices" set; intersecting with `has_session` drops never-contacted
/// ghosts (a real offline phone we've messaged has a session; a ghost we never
/// established one with does not). These hit `send_dm_to_device`'s
/// session+offline branch → relay buffers under the device id + pushes its
/// token → the quit phone's background fetch (which now auths as that device)
/// decrypts the preview. Without this a fully-quit phone was never targeted at
/// all → no push (the Step 9A break). Also the target predicate for the
/// channel-push offline fan-out (same "real offline device" definition).
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

/// Send one already-signed DM envelope to ONE concrete device peer_id (Phase 6
/// multi-device fan-out). This is the per-device half of `handle_send_message`,
/// split out so the master→devices loop can run it once per target. `device_peer`
/// is always a real device id (or the master id itself for a single-device
/// recipient), never a master that no device authenticates as.
///
/// Three branches, identical in shape to the pre-fan-out code, just keyed by the
/// device id:
///   - session + online → encrypt and deliver now,
///   - session + offline → encrypt to the DM room (push trigger) + queue for
///     reconnect,
///   - no session → queue + KeyRequest (drained on session establishment).
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
    // True when `device_peer` is one of OUR OWN sibling devices (self-echo fan-out),
    // not the genuine recipient. A sibling mirror is NEVER notification-worthy, so
    // when the sibling is offline we must NOT do the "encrypt to DM room (push
    // trigger)" room-send (the relay would fire an FCM push and the sibling would
    // buzz for OUR OWN outgoing message). We still queue it for silent delivery on
    // the sibling's next reconnect (+ Step 5 backfill closes any residual gap).
    is_sibling: bool,
) {
    // EXACT-device reachability, not the identity-wide `peer_is_reachable`: in a
    // fan-out, device A may be online while sibling device B is offline. The
    // identity-wide check would report B "reachable" (because A is), send B's
    // copy down the online path, and `send_encrypted_message`'s own
    // `ws_room_for_peer` (exact membership) would then find no room for B and
    // DROP it with no offline buffering. Checking exact membership here routes an
    // offline-but-sibling-online device into the offline-buffer branch correctly.
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
        // Our OWN sibling device, online — send the self-echo NOW. Siblings meet
        // in inbox:{our_master}, NOT dm_room_code(M,M), so route via the flexible
        // ws_room_for_peer lookup (which finds the inbox room), NOT the DM room.
        // The multi-room one-way risk doesn't apply here: a sibling shares only
        // the inbox room with us, so the lookup is unambiguous.
        send_encrypted_message(
            olm, crypto_store, device_peer, envelope_json,
            event_tx, ws_cmd_tx, ws_room_peers,
        ).await;
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    } else if is_sibling {
        // Session exists but our OWN sibling device is offline. Do NOT room-send
        // (that would trigger a push — Pixel buzzing for VM's own message). Just
        // queue for silent delivery when the sibling reconnects; Step 5 backfill
        // also closes the gap on next inbox-join.
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    } else {
        send_dm_offline_recipient(olm, crypto_store, ws_cmd_tx, device_peer, envelope_json, dm_room);
        // Also queue for when this device comes back online (push may fail).
        queue_pending_envelope(pending_messages, device_peer, envelope_json);
    }
}

/// Genuine recipient device, online — encrypt and send into the DETERMINISTIC
/// DM room (the master-pair `dm_room_code` the caller computed), NOT a
/// `ws_room_for_peer` lookup. When the recipient's device is co-present in more
/// than one of our rooms (its DM room PLUS an inbox/server room during
/// friend-handshake churn), the first-match lookup inside
/// send_encrypted_message can pick a room the recipient has since left → the
/// relay buffers the frame against a room they never rejoin and it's silently
/// lost (the one-way DM bug: sends "succeed" but never arrive). The offline
/// path (`send_dm_offline_recipient`) already routes by dm_room for this exact
/// reason; the online path must too. Every device of the FRIEND is a member of
/// dm_room. NOTE: siblings never take this path — they meet in
/// inbox:{our_master}, NOT dm_room_code(M,M), so dm_room is wrong for them;
/// the sibling self-echo path keeps the flexible lookup.
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
    // The relay never ACKs a direct message, and a session we believe is
    // confirmed bidirectional can be silently dead on the PEER's side —
    // the classic "KeyRequest while we hold a session — peer lost theirs"
    // desync, which is acute right after a device link (the freshly-linked
    // sibling and its source churn their ratchet during the snapshot
    // handshake). A DM encrypted on that doomed ratchet is undecryptable and,
    // without this queue, lost forever (it was the "first sibling DM never
    // mirrors, every later one does" bug). The re-key/decrypt-fail path
    // (swarm.rs), PeerJoined, and KeyBundle all `.remove()`-drain this queue
    // on a FRESH session, re-delivering the envelope; the receiver dedups by
    // `message_id`, so the redundant copy on a healthy session is harmless.
    // Cap per-device so a long-lived healthy session (no reconnect to drain
    // it) can't grow the queue unbounded.
    const RETRY_QUEUE_CAP: usize = 20;
    let q = pending_messages.entry(device_peer.to_string()).or_default();
    q.push(envelope_json.to_string());
    if q.len() > RETRY_QUEUE_CAP {
        let overflow = q.len() - RETRY_QUEUE_CAP;
        q.drain(0..overflow);
    }
}

/// Session exists but the recipient device is offline — encrypt and send to the
/// DM room anyway. The relay sees the target isn't in the room and triggers a
/// push notification. The DM room is the MASTER-pair room (computed once by the
/// caller from the recipient's master) — every device of the recipient is a
/// member of it. `dm_room_code` is pure now, so we must NOT recompute it from
/// `device_peer` here (that would key the room on the device id, not the
/// identity).
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
    let identity_key = if msg_type == 0 {
        Some(olm.identity_key_base64())
    } else {
        None
    };
    let haven_msg = HavenMessage::Encrypted {
        message_type: msg_type,
        body: OlmManager::encode_base64(&ciphertext),
        identity_key,
    };
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

    // Sign the message before encryption. The v2 signature binds the
    // structured fields as they ride BOTH wire forms below (the MLS envelope
    // and the public-channel plaintext both carry mid/reply_to/link_preview/
    // order_us — PublicChannelMessage gained order_us in 0.8.3 for this).
    let lp_digest = link_preview.as_ref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: Some(&message_id),
        reply_to: reply_to_mid.as_deref(),
        file_id: None,
        order_us: Some(order_us),
        lp_digest: lp_digest.as_deref(),
    };
    let (sig, pk) = sign_message_versioned(
        bundle_keypair, pub_key_b64, "ch", &format!("{}:{}", server_id, channel_id),
        &local_peer, timestamp, &extras, &text,
    );

    // Mention metadata — shared by the notification hint and the offline push
    // fan-out below.
    let (has_everyone, mentioned_names) = channel_mention_meta(&text);

    // Wire bytes of the message as broadcast to the room — re-delivered to
    // OFFLINE members via targeted 0x09 frames (relay offline buffer). The MLS
    // group ciphertext / signed public plaintext is decryptable by any member,
    // so one encryption serves both paths. None on the legacy Olm fan-out path
    // (pairwise sessions can't pre-encrypt for offline peers without burning
    // ratchet slots) — those members still get a content-free wake push.
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
            file_meta: None,
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &channel_id, &msg)
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

    // Broadcast notification hint via SendToRoom (reaches all room members, even unsubscribed).
    {
        let hint = HavenMessage::ChannelNotificationHint {
            server_id: server_id.clone(),
            channel_id: channel_id.clone(),
            message_id: message_id.clone(),
            has_everyone,
            mentioned_names: mentioned_names.clone(),
            is_reply: reply_to_mid.is_some(),
            reply_to_sender: reply_author.clone(),
        };
        if let Ok(hint_bytes) = serde_json::to_vec(&hint) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
                room_code: server_id.clone(),
                data: hint_bytes,
            });
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

/// Cooperative-client fast-fail gates for a channel send: posting permission +
/// the moderation trio (mute / media-only / slow mode). Receivers drop
/// violations too. Returns the user-facing error for the FIRST failed gate,
/// `None` when the send may proceed. Async — the slow-mode check reads the
/// `MessageStore` on the blocking pool (SQLCipher key derivation is expensive
/// and must not stall the event loop).
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

/// Send-side mute gate (master-keyed, lazy expiry — the same lookup the
/// new-message gate uses): `Some(error)` when we are muted on this server.
/// Shared by the new-message, edit, and add-reaction send paths. Deletes and
/// reaction removals are deliberately NOT gated — removing your own content
/// is always allowed — and slow mode / media-only never apply to
/// edits/deletes/reactions.
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

/// Slow-mode half of the send gates: error when our own latest message in the
/// channel is still inside the slow-mode window. The Mod+ exemption
/// short-circuits BEFORE any store access; the open+query hops onto the
/// blocking pool.
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

/// Our own latest message ts in a channel, read on the blocking pool with
/// owned captures — the store is created and dropped entirely inside the
/// closure (rusqlite `Connection` is !Sync, never held across an .await).
/// Store-open failure = `None` (gate allows — mirrors the original inline
/// behavior). Shared with the channel file send gate (file_handler).
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

/// Serialize + broadcast one public-channel `HavenMessage` to the server room
/// (plaintext — no MLS/Olm; guests receive it too, still Ed25519-signed).
/// Returns the wire bytes for the offline 0x09 push fan-out.
/// `pub(crate)` — file_handler's public-channel file send uses it too.
///
/// Sent TWICE, on purpose, and the second copy is what reaches a member who
/// was away. The room broadcast is for guests: they sit in the room, never
/// subscribe to a channel topic, and cannot decrypt anything. But the relay
/// only tees a 0x07 TOPIC frame into a channel's catch-up ring, so a public
/// channel used to put nothing at all in the ring, while a file's `FileHeader`
/// rode the topic either way. The returning member got file metadata with no
/// message row to hang it on, and the channel list builds its rows from
/// `channel_messages` — so the post rendered as nothing.
///
/// Both copies are the same signed bytes, so a member receiving both stores
/// one row: every ingest pre-checks `channel_message_exists(mid)` and the
/// second arrival is emitted with `duplicate`.
pub(crate) fn send_public_channel_msg(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    channel_id: &str,
    msg: &HavenMessage,
) -> Option<Vec<u8>> {
    let data = serde_json::to_vec(msg).ok()?;
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data: data.clone(),
    });
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server_id.to_string(),
        topic: channel_id.to_string(),
        data: data.clone(),
    });
    Some(data)
}

/// Broadcast one non-public channel envelope to the server. MLS path: encrypt
/// once → single WS topic broadcast to the room; restricted channels (Option B)
/// encrypt under their per-channel subgroup instead of the server-wide group.
/// Olm per-device fan-out is the fallback (MLS encrypt failure) and the
/// pre-bootstrap path (no group yet). Returns the MLS wire bytes for the
/// offline 0x09 push fan-out when the MLS broadcast succeeded, `None`
/// otherwise. `bootstrap_subgroup` additionally kicks off subgroup bootstrap on
/// the no-group path (ALL content sends — a client that only edits/reacts must
/// still escape the Olm fallback; `request_subgroup_bootstrap` is cheap and
/// no-ops when we're the coordinator or nobody qualifying is online).
/// Shared driver for send/edit/delete/add-reaction/remove-reaction.
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
        match send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, server_id, channel_id, use_subgroup, envelope, crypto_store) {
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
    // Subgroup not yet bootstrapped (or legacy server with no MLS group):
    // Olm fan-out to qualifying members, and (for a restricted channel) kick
    // off subgroup bootstrap by sending our KeyPackage to the subgroup
    // coordinator so future messages can use the subgroup.
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

/// Offline-member push fan-out (channel push notifications). Room/topic
/// broadcasts only reach ONLINE peers; offline members get the message later
/// via channel sync. To make their phones light up NOW, hand the relay one
/// targeted 0x09 frame per offline member: the same wire bytes the room just
/// received (buffered + replayed to that member's background fetch node) plus
/// push metadata (channel + per-target mention flag) the relay filters against
/// the member's registered push prefs. The relay never learns server
/// membership — the SENDER picks the targets from its CRDT. Sync — may open
/// the `MessageStore` (reply-author lookup).
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
        // Expand the offline MASTER member into its real DEVICE ids — the
        // relay keys the push token + offline buffer by DEVICE id (Step 9A).
        // Targeting the bare master buffers under an id no device authenticates
        // as → no push reaches any device. Real-device predicate mirrors the
        // DM fan-out (`offline_session_devices`): a known device of this master,
        // offline (not in a room), that we hold an Olm session with (drops
        // never-contacted ghosts). A single-device member (no device links) →
        // fall back to the master id, which IS that member's device id =
        // pre-multi-device behavior.
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
        reply_to_mid, None, Some(order_us),
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

    // Moderation gate: mute blocks edits (authoring content) exactly like the
    // new-message send gate; receivers drop a muted member's edits too.
    // Deletes stay allowed — removing your own content is never blocked —
    // and slow mode / media-only don't apply to edits.
    if let Some(message) = muted_send_error(server, local_peer_str) {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();
    let edit_timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    // Sign the edit over the EDIT timestamp + new text, binding the row's
    // structural fields (v2) so receivers verify against the same extras
    // their own row carries. Update local DB in the same open (preserves old
    // text in message_edits table).
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

    // Broadcast edit to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelEdit {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), text: new_text.clone(),
            ts: edit_timestamp, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &channel_id, &msg);
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

    // Sign the edit over the EDIT timestamp + new text, binding the row's
    // structural fields (v2) — see the channel-edit twin above. Binding the
    // full row (not just mid) is what keeps `rewrite_pending_dm_edits`
    // verifying: the queued DirectMessage envelope keeps the original
    // mid/reply_to/order_us/link_preview, and the receiver verifies THIS edit
    // signature against exactly those wire fields.
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

    // Update any queued pending message (pre-edit text → edited text) so a later
    // PeerJoined drain sends the edited text, not the stale original. Multi-device:
    // the original message was queued PER DEVICE (under device ids, not the master),
    // so scan every queue rather than only the master's.
    rewrite_pending_dm_edits(pending_messages, &message_id, &new_text, edit_timestamp, &sig, &pk);

    // Send edit to the DM peer.
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

    // Multi-device fan-out (Step 3): deliver the edit to every device of the
    // recipient + our own siblings. A device with no session yet gets the whole
    // edited conversation via Step 5 backfill.
    let recipient_master = super::resolver::resolve(&peer_id_str);
    fan_out_dm_envelope(
        olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
        pending_messages, key_request_in_flight,
        local_peer_str, device_keypair, device_peer_id, &recipient_master, &envelope_json,
        None, // edit/delete/reaction: sibling resolves convo by mid on receive
    ).await;

    // Emit event so Dart updates UI — include sig/pk so the
    // in-memory message's fields match the canonical payload.
    // Multi-device: the DM thread key is the peer's MASTER id (no-op single-device).
    let _ = event_tx.send(NetworkEvent::DmMessageEdited {
        peer_id: super::resolver::resolve(&peer_id_str),
        message_id,
        new_text,
        edited_at: edit_timestamp,
        signature: sig,
        public_key: pk,
    }).await;
}

/// Rewrite every queued copy of an edited DM (pre-edit text → edited text)
/// across ALL per-device pending queues, so a later PeerJoined drain sends the
/// edited text, not the stale original.
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
        }),
    };
    if let Ok(json) = serde_json::to_string(&updated) {
        *entry = json;
        hollow_log!("[HOLLOW-SWARM] Updated pending message {message_id} with edited text");
    }
}

// ── 4b. AttachChannelLinkPreview / AttachDmLinkPreview (issue #45) ───
//
// A card that arrives AFTER its message was sent. The compose box fetches OG
// metadata in the background while the user types; sending before it lands
// used to bin the result, which is why a fast sender never got cards. These
// handlers land it on the row instead.
//
// This is emphatically NOT an edit. The text is untouched, `edited_at` stays
// null, and no "(edited)" badge appears. What it does share with an edit is
// the signature obligation: the v2 payload binds `lp_digest`, so changing a
// row's preview without re-signing would break `verify_message_proof_v2` and
// stop the row replicating through signed sync backfill. Every attach
// therefore re-signs the WHOLE message payload — same text, same ts, same
// reply_to/file_id/order_us — with the new digest, and ships that signature
// alongside the card.

/// The re-signature for an attach, plus the row facts the caller needs to
/// broadcast it. `None` = the row is missing, so there is nothing to attach.
struct AttachSig {
    /// The timestamp the signature binds: the row's `edited_at` when it has
    /// one, else its original `timestamp`. Must match what every verifier
    /// reconstructs (see `verify_message_proof_v2`), or the row goes
    /// unverified the moment a card lands on it.
    ts: i64,
    sig: Option<String>,
    pk: Option<String>,
}

/// Re-sign message `mid` for a preview change. `msg_type`/`context` are the
/// same discriminators the original send used ("ch" + "sid:cid", or "dm" +
/// peer id), and `row` is the CURRENT row, so the only thing that moves is
/// the link-preview digest.
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

/// Land the card riding a VERIFIED sync item on its row.
///
/// Backfill used to carry only `lp_digest`, so a peer that was offline when a
/// card was attached received a message whose signature bound a preview it had
/// no copy of. It rendered a bare link — and re-serving that row computed
/// `lp_digest = None` from its own empty column, which every downstream peer
/// then rejected as forged. Previews ride the batch now; this is where they
/// land.
///
/// Card and signature are written TOGETHER because the pair is inseparable:
/// the v2 payload binds `lp_digest`, so a card grafted on without the
/// signature covering it produces exactly the row that used to break — one
/// that fails its own Message Proof and replicates to nobody. The signature
/// written is the item's own, the one `check_backfill_signature` just verified
/// over this exact card.
///
/// Guarded on the item's text matching the row's, because that signature only
/// speaks for the text it was made over. If our row has been edited since (or
/// this item is a stale copy), the batch's edit branch owns the row and must
/// not have its newer signature overwritten by an older one.
///
/// Returns true when the card actually landed, so the caller can emit
/// `*LinkPreviewUpdated` and repaint an open pane.
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
        store.update_channel_link_preview_and_sig(mid, Some(&lp_json), sig, pk)
    } else {
        store.update_link_preview_and_sig(mid, Some(&lp_json), sig, pk)
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
        // Local-author op: we may only re-sign our OWN row. Remote ingest has
        // its own check; this one stops a UI bug from minting a signature over
        // somebody else's message with our key.
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
            signed.sig.as_deref(), signed.pk.as_deref(),
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
        send_public_channel_msg(ws_cmd_tx, &server_id, &channel_id, &msg);
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
            signed.sig.as_deref(), signed.pk.as_deref(),
        );
        attached = Some(signed);
    }
    let Some(signed) = attached else { return };

    // The recipient may still be offline with the ORIGINAL message sitting in
    // their queue. Rewrite that queued envelope in place rather than letting a
    // bare `lp_set` chase a message they haven't received: on reconnect they
    // get ONE message that already carries its card.
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
/// `DirectMessage` keeps its original text/mid/order_us and gains the card
/// plus the signature that now covers it.
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

    // Sign the deletion with the text at deletion time. Uses "ch-delete" msg
    // type so a delete signature cannot be confused with or replayed as a
    // send signature; v2 additionally binds the row's structural fields (mid
    // included — a v1 delete signature was replayable onto any same-text
    // message in the same channel). Text from DB so the archive viewer can
    // verify the delete against the same state the exporter saw.
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

    // Broadcast deletion to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelDelete {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), ts: delete_timestamp,
            sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &channel_id, &msg);
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

    // Sign the deletion with the text at deletion time. "dm-delete" msg type —
    // distinct from "dm" to prevent replay; v2 additionally binds the row's
    // structural fields (see the channel-delete twin above).
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
            // Hide in local DB.
            let _ = store.hide_dm_message(
                &message_id, delete_timestamp,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Send deletion to the DM peer.
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

    // Emit event so Dart updates UI.
    // Multi-device: the DM thread key is the peer's MASTER id (no-op single-device).
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

    // Moderation gate: mute blocks adding reactions (authoring content)
    // exactly like the new-message send gate; receivers drop them too.
    // Removing a reaction stays allowed — removing your own content is never
    // blocked — and slow mode / media-only don't apply to reactions.
    if let Some(message) = muted_send_error(server, local_peer_str) {
        let _ = event_tx.send(NetworkEvent::Error { message }).await;
        return;
    }

    let local_peer = local_peer_str.to_string();
    let reaction_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Save to local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.add_reaction(
                &message_id, &emoji, &local_peer, reaction_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Broadcast to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelAddReaction {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), emoji: emoji.clone(),
            ts: reaction_ts, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &channel_id, &msg);
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
    let reaction_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("reaction:{}:{}:{}", message_id, emoji, reaction_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Multi-device: attribute our own reaction to our MASTER id so it lands under
    // the same identity on our other devices (no-op single-device).
    let reactor_master = super::resolver::resolve(&local_peer);

    // Save to local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.add_reaction(
                &message_id, &emoji, &reactor_master, reaction_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Send to DM peer.
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
    let remove_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Remove from local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_reaction(
                &message_id, &emoji, &local_peer, remove_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Broadcast to all server members.
    if server.is_channel_public(&channel_id) {
        let msg = HavenMessage::PublicChannelRemoveReaction {
            server_id: server_id.clone(), channel_id: channel_id.clone(),
            mid: message_id.clone(), emoji: emoji.clone(),
            ts: remove_ts, sig: sig.clone(), pk: pk.clone(),
        };
        send_public_channel_msg(ws_cmd_tx, &server_id, &channel_id, &msg);
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
    let remove_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let signing_payload = format!("unreaction:{}:{}:{}", message_id, emoji, remove_ts);
    let (sig, pk) = sign_message(bundle_keypair, pub_key_b64, &signing_payload);

    // Multi-device: our own reaction is keyed by our MASTER id (see AddDmReaction).
    let reactor_master = super::resolver::resolve(&local_peer);

    // Remove from local DB.
    {
        if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
            let _ = store.remove_reaction(
                &message_id, &emoji, &reactor_master, remove_ts,
                sig.as_deref(), pk.as_deref(),
            );
        }
    }

    // Send to DM peer.
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
    db_path: &str,
    db_passphrase: &str,
) {
    // SECURITY: conference chat NEVER rides the channel pipeline — it has its
    // own RAM-only HavenMessage::ConferenceChat path. A modified client
    // sending a ChannelMessage envelope under a conf group would otherwise
    // PERSIST into channel_messages (violating the live-only invariant), so
    // drop it here regardless of signature.
    if super::conference::is_conference_sid(&sid) {
        hollow_log!("[HOLLOW-SECURITY] Dropped ChannelMessage envelope for conference sid {sid}");
        return;
    }

    // SECURITY: a missing OR invalid signature is rejected — mirrors the direct
    // (non-MLS) twin in swarm.rs. Covers both callers: MLS-decrypted private
    // channels and plaintext PUBLIC channels, where this is the only authorship
    // binding there is. The v2 extras come from the same wire fields persisted
    // below, so what verifies is exactly what gets stored.
    let lp_digest = link_preview.as_ref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: mid.as_deref(),
        reply_to: reply_to.as_deref(),
        file_id: file_id.as_deref(),
        order_us,
        lp_digest: lp_digest.as_deref(),
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
            state, &sender_peer_id, &sid, &cid, file_id.is_some(), ts, db_path, db_passphrase,
        ).await {
            return;
        }
    }

    let Some((is_new, reply_author)) = persist_incoming_channel_message(
        &sid, &cid, &sender_peer_id, &text, is_mine, ts,
        sig.as_deref(), pk.as_deref(), mid.as_deref(),
        reply_to.as_deref(), file_id.as_deref(), order_us,
        &link_preview, db_path, db_passphrase,
    ) else {
        // Store-open failure — the message is silently gone otherwise; log
        // channel + sender context (never content) so the drop is diagnosable.
        hollow_log!(
            "[HOLLOW-SWARM] DROPPED incoming channel message in {sid}/{cid} from {sender_peer_id} (mid={mid:?}) — MessageStore::open failed"
        );
        return;
    };
    // ALWAYS emit — a ChannelSyncBatch racing this live message inserts
    // the row first without emitting; suppressing the live event too left
    // the open pane stale until re-entry. Dart dedups by message_id and
    // skips unread/notifications when `duplicate`.
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
        reply_to_own,
        duplicate: !is_new,
    }).await;
}

/// SECURITY: true = drop this LIVE channel message.
///
/// A signature is REQUIRED, not merely checked when present. The old
/// `if sig.is_none() { return false }` early-out was itself the bypass: strip
/// `sig`/`pk` and verification was skipped entirely.
///
/// This matters most for PUBLIC channels, which carry no MLS layer — there the
/// signature is the ONLY thing binding content and authorship to an Ed25519
/// identity, so without it a message's attribution rests entirely on the
/// relay-reported sender id. On MLS channels it is defence in depth behind group
/// membership.
///
/// Sync backfill applies the SAME rule as of 0.8.5 (`REQUIRE_SIGNED_BACKFILL`):
/// it used to tolerate an unsigned row so pre-signing history (e2cc8ab,
/// 2026-03-09) kept replicating, but tolerating absence was an injection path,
/// so `BackfillSig::is_acceptable()` now refuses it there too. The
/// live-enforce / backfill-tolerate split survives ONLY for the moderation trio
/// (a mute may legitimately postdate the history being synced).
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

/// Receive-side moderation trio for one LIVE channel message: true = drop
/// (mute / media-only / slow-mode violation), so a modified client can't bypass
/// what receivers refuse to store. Sync backfill intentionally skips these
/// gates — history may legitimately predate a mute / slow-mode / media-only
/// change, and dropping it there would diverge stored history. Async — the
/// slow-mode window check reads the `MessageStore` on the blocking pool.
#[allow(clippy::too_many_arguments)]
async fn live_channel_moderation_drop(
    state: &ServerState,
    sender_peer_id: &str,
    sid: &str,
    cid: &str,
    has_file: bool,
    ts: i64,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if state.is_muted(sender_peer_id, now_ms) {
        hollow_log!("[HOLLOW-MOD] DROPPED channel message from muted member {sender_peer_id} in {sid}");
        return true;
    }
    if state.is_channel_media_only(cid) && !has_file {
        hollow_log!("[HOLLOW-MOD] DROPPED text-only message from {sender_peer_id} in media-only channel {cid}");
        return true;
    }
    let slow = state.channel_slow_mode(cid);
    if slow > 0 && !state.bypasses_slow_mode(sender_peer_id) {
        // Open+query on the blocking pool with owned captures (SQLCipher key
        // derivation is expensive; the store lives entirely inside the
        // closure — Connection is !Sync). Open failure = allow, as before.
        let window_start = ts - (slow as i64) * 1000;
        let (sid_o, cid_o) = (sid.to_string(), cid.to_string());
        let sender = sender_peer_id.to_string();
        let (path, pass) = (db_path.to_string(), db_passphrase.to_string());
        let violation = tokio::task::spawn_blocking(move || {
            crate::storage::MessageStore::open(&path, &pass)
                .map(|store| store.channel_sender_has_msg_in_range(&sid_o, &cid_o, &sender, window_start, ts))
                .unwrap_or(false)
        }).await.unwrap_or(false);
        if violation {
            hollow_log!("[HOLLOW-MOD] DROPPED slow-mode violation from {sender_peer_id} in {cid} (window {slow}s)");
            return true;
        }
    }
    false
}

/// LIVE-ingest mute gate shared by the edit and add-reaction envelope
/// handlers: true = drop (the sender is muted — master-keyed, lazy expiry;
/// every call site resolves the sender to its MASTER first). Mirrors the mute
/// half of `live_channel_moderation_drop`. Deletes and reaction removals stay
/// allowed — removing your own content is never blocked — and sync backfill
/// never routes through these handlers, so history predating a mute survives.
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

/// Persist one incoming channel message with message-id dedup (replays); the
/// content UNIQUE index is legacy-only (WHERE message_id IS NULL) so
/// identical-text spam in the same millisecond persists as distinct messages.
/// Returns `Some(is_new)`, or `None` when the store could not be opened (the
/// caller then emits nothing, matching the pre-split behavior). Sync — owns
/// the store.
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
    link_preview: &Option<LinkPreviewRef>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<(bool, Option<String>)> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    // Replied-to message's author (MASTER id) — the caller turns this into the
    // event's `reply_to_own` so mentions-only gates on "reply to ME" (#42).
    // Same store open as the insert; absent parent row = None.
    let reply_author = reply_to.and_then(|m| store.get_channel_message_sender(m));
    let already = mid
        .map(|m| store.channel_message_exists(m))
        .unwrap_or(false);
    let is_new = if already {
        false
    } else {
        store.insert_channel_message(
            sid, cid, sender_peer_id, text, is_mine, ts,
            sig, pk, mid, reply_to, file_id, order_us,
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

/// Handle `MessageEnvelope::EditMessage` (MLS-decrypted path).
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
    // Moderation (LIVE ingest only): drop edits from muted members, mirroring
    // the new-message ingest gate — a modified client can't author content
    // through the edit path while muted.
    if live_muted_ingest_drop(server_state, peer_str, "edit") {
        return;
    }
    let mut edit_applied = false;
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let sender = store.get_channel_message_sender(&mid);
        if sender.as_deref() == Some(peer_str) {
            // SECURITY: a LIVE edit must carry a signature that verifies —
            // the row-ownership check above trusts the transport-reported
            // sender, which on plaintext PUBLIC channels is relay-controlled.
            // The extras come from OUR row (immutable under edit), matching
            // what the editor's row-loaded signature bound.
            let ctx = format!(
                "{}:{}", sid.as_deref().unwrap_or_default(), cid.as_deref().unwrap_or_default(),
            );
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
        } else if sender.is_some() {
            hollow_log!("[HOLLOW-EDIT] MLS rejected: {peer_str} tried to edit message {mid} owned by {sender:?}");
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
/// (issue #45). One handler for all three ingest paths — Olm-direct DM/channel,
/// MLS-decrypted channel, and plaintext public channel — because the rule is the
/// same everywhere: the card only lands if the AUTHOR signed it.
///
/// `peer_str` is the transport sender (a DEVICE id on the DM path). `sid`
/// present = channel message, absent = DM.
///
/// Applying the same card twice is a quiet no-op, so a duplicated frame or a
/// re-broadcast costs nothing.
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
    db_path: &str,
    db_passphrase: &str,
) {
    // Moderation (LIVE ingest): a muted member can't author card content
    // either, mirroring the edit gate.
    if live_muted_ingest_drop(server_state, peer_str, "link preview") {
        return;
    }

    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return;
    };
    let is_channel = sid.is_some();

    // Who must have signed this, and under what context. Both are derived
    // from OUR row, never from fields the sender controls.
    let (signer, ctx, convo_peer) = if is_channel {
        let Some(sender) = store.get_channel_message_sender(&mid) else {
            // Row not synced yet — the sync batch will bring the card with it.
            return;
        };
        let sender_master = super::resolver::resolve(&sender);
        if !super::resolver::same_identity(&sender_master, peer_str) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED link preview for {mid} from {peer_str} — not the author ({sender_master})");
            return;
        }
        let ctx = format!(
            "{}:{}", sid.as_deref().unwrap_or_default(), cid.as_deref().unwrap_or_default(),
        );
        (sender_master, ctx, String::new())
    } else {
        // DM. Normally the attacher is the other party (the row is not ours).
        // The exception is our OWN sibling echoing our own attach back at us,
        // which is legitimate precisely because it resolves to our master.
        let is_mine = store.get_dm_message_is_mine(&mid);
        let is_sibling = super::resolver::same_identity(peer_str, local_master);
        if !(is_mine == Some(false) || (is_mine == Some(true) && is_sibling)) {
            hollow_log!("[HOLLOW-LP] Rejected: {peer_str} tried to set a preview on DM {mid} (is_mine={is_mine:?})");
            return;
        }
        let convo = if is_sibling {
            store.get_dm_message_peer(&mid).unwrap_or_default()
        } else {
            super::resolver::resolve(peer_str)
        };
        // A sibling echo was signed by US with the row's conversation peer as
        // recipient; a friend's attach was signed by them with US as recipient.
        if is_sibling {
            (local_master.to_string(), convo.clone(), convo)
        } else {
            (super::resolver::resolve(peer_str), local_master.to_string(), convo)
        }
    };

    let Some(row) = (if is_channel {
        store.get_channel_message_sig_row(&mid)
    } else {
        store.get_dm_message_sig_row(&mid)
    }) else {
        return;
    };

    // SECURITY: the signature must verify over the row we hold, with the NEW
    // digest folded in. This is what stops a relay pasting a card of its
    // choosing onto a plaintext public-channel message, and it REJECTS —
    // there is deliberately no log-and-accept path.
    let lp_digest = lp.as_deref().map(link_preview_digest);
    let extras = SignedExtras {
        mid: Some(&mid),
        reply_to: row.reply_to_mid.as_deref(),
        file_id: row.file_id.as_deref(),
        order_us: row.order_us,
        lp_digest: lp_digest.as_deref(),
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
            &mid, lp_json.as_deref(), sig.as_deref(), pk.as_deref(),
        )
    } else {
        store.update_link_preview_and_sig(
            &mid, lp_json.as_deref(), sig.as_deref(), pk.as_deref(),
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

/// Handle `MessageEnvelope::DeleteMessage` (MLS-decrypted path).
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
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let sender = store.get_channel_message_sender(&mid);
        if sender.as_deref() != Some(sender_peer_id) {
            hollow_log!("[HOLLOW-SECURITY] REJECTED MLS DeleteMessage from {sender_peer_id} — not the sender of {mid}");
            return;
        }
        // SECURITY: a LIVE delete must carry a signature that verifies — on
        // plaintext PUBLIC channels the transport-reported sender is
        // relay-controlled, and an unauthenticated delete is a censorship
        // primitive. The deleter signed over OUR row's current text + extras
        // ("ch-delete" payload); a receiver whose text lags (missed edit)
        // rejects here and converges via sync's hidden_at instead.
        let ctx = format!(
            "{}:{}", sid.as_deref().unwrap_or_default(), cid.as_deref().unwrap_or_default(),
        );
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

/// Handle `MessageEnvelope::AddReaction` (MLS-decrypted path).
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
    // Choke-point validation for EVERY inbound add path (MLS envelope, Olm
    // fallback, public channel): short Unicode emoji or a well-formed custom
    // emote token — nothing else reaches the DB.
    if !super::emotes::valid_reaction_emoji(&emoji) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED reaction from {peer_str} — invalid emoji string ({} bytes)", emoji.len());
        return;
    }
    // Moderation (LIVE ingest only): drop reactions from muted members,
    // mirroring the new-message ingest gate; reaction REMOVALS stay allowed.
    if live_muted_ingest_drop(server_state, peer_str, "reaction") {
        return;
    }
    // SECURITY: a LIVE reaction must carry a signature that verifies — on
    // plaintext PUBLIC channels the transport-reported reactor is
    // relay-controlled, so an unsigned reaction is attributable to anyone.
    // The reaction payload has its own grammar (binds mid+emoji+ts already);
    // no v2 needed.
    if reaction_sig_rejected(peer_str, "reaction", &mid, &emoji, ts, sig.as_deref(), pk.as_deref()) {
        return;
    }
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.add_reaction(
            &mid, &emoji, peer_str, ts,
            sig.as_deref(), pk.as_deref(),
        );
    }
    if let (Some(s_id), Some(c_id)) = (sid, cid) {
        let _ = event_tx.send(NetworkEvent::ChannelReactionAdded {
            server_id: s_id,
            channel_id: c_id,
            message_id: mid,
            emoji,
            reactor: peer_str.to_string(),
            added_at: ts,
        }).await;
    }
}

/// SECURITY: `true` = this SYNCED reaction may be stored. Reactions riding a
/// sync batch used to be inserted unverified — the item-level backfill check
/// covers the MESSAGE, not the reaction rows hanging off it, and each reaction
/// names its own reactor (`r.p`). So a sync responder (or, on a plaintext
/// public channel, the relay) could attribute any reaction to any member.
///
/// Same grammar and signer rule as the live path (`reaction_sig_rejected`):
/// `reaction:{mid}:{emoji}:{ts}` signed by the reactor's MASTER. Sync items
/// only ever carry ADDITIONS, so there is no `unreaction:` case here.
///
/// Absent is refused alongside invalid — see [`REQUIRE_SIGNED_BACKFILL`].
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

/// SECURITY: true = drop this LIVE reaction add/remove — signature missing or
/// invalid. Reactions sign their own canonical payload
/// (`{kind}:{mid}:{emoji}:{ts}`, kind = "reaction" | "unreaction"), which
/// already binds the message id, so a valid signature cannot be replayed onto
/// another message or emoji. Reactions arriving in a SYNC batch go through
/// [`sync_reaction_accepted`] instead — same rule, item-local signer.
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

/// Handle `MessageEnvelope::RemoveReaction` (MLS-decrypted path).
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
    // SECURITY: same rule as the add path — see `reaction_sig_rejected`.
    if reaction_sig_rejected(peer_str, "unreaction", &mid, &emoji, ts, sig.as_deref(), pk.as_deref()) {
        return;
    }
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.remove_reaction(
            &mid, &emoji, peer_str, ts,
            sig.as_deref(), pk.as_deref(),
        );
    }
    if let (Some(s_id), Some(c_id)) = (sid, cid) {
        let _ = event_tx.send(NetworkEvent::ChannelReactionRemoved {
            server_id: s_id,
            channel_id: c_id,
            message_id: mid,
            emoji,
            reactor: peer_str.to_string(),
            removed_at: ts,
        }).await;
    }
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
    /// is_mine, so a friend cannot censor OUR OWN message by signing a
    /// "deletion" of it with their (valid) key and a flipped mine flag.
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
        store.insert(&them_id, "their message", false, 1_000, None, None, Some("dm-1"), None, None, None).unwrap();
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
        // their own key. The row says WE authored it, so their proof must be
        // rejected — deletes are self-only.
        store.insert(&them_id, "our message", true, 3_000, None, None, Some("dm-2"), None, None, None).unwrap();
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
        store.insert_channel_message("s", "c", "peer-a", "signed del", false, 1_000, None, None, Some("m-signed"), None, None, None).unwrap();
        store.insert_channel_message("s", "c", "peer-a", "legacy del", false, 1_100, None, None, Some("m-legacy"), None, None, None).unwrap();
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

    /// Issue #45 follow-up — a card riding a sync batch is covered by the SAME
    /// signature that covers the text, because the digest is recomputed from
    /// the shipped preview rather than trusted from the wire's `lp_digest`.
    ///
    /// That ordering is the security property. Backfill now carries thumbnail
    /// bytes a peer will render, so a responder (or, on the plaintext
    /// public-channel path, the relay) that could swap the card while keeping
    /// the author's `lp_digest` would have a phishing primitive: same message,
    /// same signature, attacker's image and title. Recomputing means any swap
    /// produces a digest the author never signed.
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
        };

        let verdict = |it: &crate::node::types::SyncMessageItem| {
            let d = crate::node::crypto_handler::backfill_lp_digest(
                it.lp.as_deref(), it.lp_digest.as_deref(),
            );
            let extras = SignedExtras {
                mid: it.mid.as_deref(), reply_to: it.reply_to.as_deref(),
                file_id: it.file_id.as_deref(), order_us: it.order_us,
                lp_digest: d.as_deref(),
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

        // A responder swaps the card and updates `lp_digest` to match, which is
        // the best a tamperer can do. Recomputing from `lp` means the digest we
        // check is the swapped one, and the author's signature does not cover it.
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

        // Digest-only, no card: a responder whose own row arrived before
        // previews rode backfill. Still verifies, stores card-less — the
        // behaviour every peer had before this change, and the reason
        // `lp_digest` stays on the wire.
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
}
