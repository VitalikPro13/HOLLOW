use std::collections::HashMap;
use std::sync::{OnceLock, Mutex};
use std::time::Instant;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::types::*;

/// Per-sibling cooldown for multi-device DM backfill requests (Step 5.1).
/// Sibling detection fires from TWO independent paths and re-fires on reconnect,
/// so one appearance would otherwise cost the responder several full sweeps.
static SIBLING_BACKFILL_LAST: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
const SIBLING_BACKFILL_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(15);

#[cfg(test)]
pub(crate) fn reset_sibling_backfill_cooldown() {
    if let Some(map) = SIBLING_BACKFILL_LAST.get() {
        map.lock().unwrap_or_else(|p| p.into_inner()).clear();
    }
}

/// Send a `DmSiblingSyncRequest` to a sibling device, throttled per-sibling so the
/// two detection paths and reconnect re-fires collapse into one request.
pub(crate) fn request_sibling_dm_backfill(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    sibling_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    {
        let map = SIBLING_BACKFILL_LAST.get_or_init(|| Mutex::new(HashMap::new()));
        let mut guard = match map.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(), // poison-safe
        };
        if let Some(last) = guard.get(sibling_peer_id) {
            if last.elapsed() < SIBLING_BACKFILL_COOLDOWN {
                return; // within cooldown — the recent request still covers us
            }
        }
        guard.insert(sibling_peer_id.to_string(), Instant::now());
    }

    let mut per_convo_since: Vec<(String, i64)> = Vec::new();
    let mut gaps: HashMap<String, GapDigest> = HashMap::new();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        for convo in store.get_dm_peer_ids() {
            let (since, gap) = store.dm_sync_anchor(&convo, true);
            if let Some(gap) = gap {
                gaps.insert(convo.clone(), gap);
            }
            per_convo_since.push((convo, since));
        }
    }
    hollow_log!(
        "[HOLLOW-SYNC] Requesting sibling DM backfill from {sibling_peer_id} ({} known convo(s), {} gap digest(s))",
        per_convo_since.len(),
        gaps.len()
    );
    super::olm_lane::carry(
        ws_cmd_tx, sibling_peer_id, None,
        &HavenMessage::DmSiblingSyncRequest { per_convo_since, gaps },
        super::olm_lane::NoSession::Queue,
    );
}

/// Send a sibling every read pointer we hold (#80). Sibling detection has TWO
/// paths (the inbox join-proof and the device-list ingest), so this fires from
/// both, like the DM backfill request. One transient store open on a one-shot
/// handshake path. Returns the marker count.
pub(crate) fn send_read_markers_to_sibling(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    sibling_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> usize {
    let markers: Vec<ReadMarker> = crate::storage::MessageStore::open(db_path, db_passphrase)
        .map(|s| s.read_markers_snapshot())
        .unwrap_or_default()
        .into_iter()
        .map(|(key, message_id, ts)| ReadMarker { key, message_id, ts })
        .collect();
    if markers.is_empty() { return 0; }
    let n = markers.len();
    hollow_log!("[HOLLOW-UNREAD] Sending {n} read marker(s) to sibling {sibling_peer_id}");
    super::olm_lane::carry(
        ws_cmd_tx, sibling_peer_id, None,
        &HavenMessage::ReadMarkers { markers },
        super::olm_lane::NoSession::Queue,
    );
    n
}

/// Our accepted friends as the sibling lane carries them.
pub(crate) fn accepted_friend_entries(db_path: &str, db_passphrase: &str) -> Vec<FriendListEntry> {
    crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|s| s.load_friends(Some("accepted")).ok())
        .unwrap_or_default()
        .into_iter()
        .map(|(peer_id, status, direction, requested_at, _updated)| FriendListEntry {
            peer_id, status, direction, requested_at,
        })
        .collect()
}

/// Send a sibling our friend list: accepted friends and the friendships we ended.
/// Returns how many entries it held.
pub(crate) fn send_friend_list_to_sibling(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    sibling: &str,
    db_path: &str,
    db_passphrase: &str,
) -> usize {
    let friends = accepted_friend_entries(db_path, db_passphrase);
    let removed = crate::storage::MessageStore::open(db_path, db_passphrase)
        .map(|store| super::social::friend_removals(&store))
        .unwrap_or_default();
    let entries = friends.len() + removed.len();
    if entries > 0 {
        hollow_log!(
            "[HOLLOW-MULTIDEV] Sharing {} friends and {} removals with sibling {sibling}",
            friends.len(),
            removed.len()
        );
        super::olm_lane::carry(
            ws_cmd_tx, sibling, None,
            &HavenMessage::FriendListSync { friends, removed },
            super::olm_lane::NoSession::Queue,
        );
    }
    entries
}

/// What a sibling that just proved itself gets, from either detection path (the
/// inbox proof and the device-list ingest): our friends, a pull of theirs, a DM
/// backfill request and our read markers. Every piece is idempotent on arrival.
pub(crate) fn share_state_with_sibling(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    sibling: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    use super::olm_lane::{carry, NoSession};
    send_friend_list_to_sibling(ws_cmd_tx, sibling, db_path, db_passphrase);
    carry(ws_cmd_tx, sibling, None, &HavenMessage::FriendListRequest, NoSession::Queue);
    request_sibling_dm_backfill(ws_cmd_tx, sibling, db_path, db_passphrase);
    send_read_markers_to_sibling(ws_cmd_tx, sibling, db_path, db_passphrase);
}

// -- Per-message Ed25519 signing helpers (v2 only since 0.8.5) --
//
// The retired v1 payload covered the TEXT only, so reply_to, file_id,
// link_preview, order_us and mid sat outside the signature and could be
// rewritten on an otherwise-valid message. v2 folds them in, and there is no
// v1 fallback: accepting a weaker payload lets the attacker pick the format.
// Edit and delete signatures bind the SAME extras, from the signer's own row.

/// The retired v1 payload builder, `#[cfg(test)]` so production code cannot
/// reach it: tests mint a v1 signature only to assert that it is REJECTED.
#[cfg(test)]
pub(crate) fn message_signing_payload(
    msg_type: &str,
    context: &str,
    sender: &str,
    ts: i64,
    text: &str,
) -> String {
    format!("hollow-msg:{msg_type}:{context}:{sender}:{ts}:{text}")
}

/// SHA-256 (hex) of the phishing-relevant link-preview fields, each
/// length-prefixed so no two distinct field sets can collide. Folded into the
/// v2 payload so a tamperer cannot rewrite a preview's title, description or
/// image on an otherwise-valid message. A sync item may carry the digest alone.
pub(crate) fn link_preview_digest(lp: &LinkPreviewRef) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    for field in [&lp.url, &lp.title, &lp.description, &lp.domain, &lp.site_name] {
        h.update((field.len() as u64).to_le_bytes());
        h.update(field.as_bytes());
    }
    // The thumbnail IS the phishing surface — bind its bytes too (present flag
    // first so `None` can't be forged into an empty-string thumbnail).
    match &lp.thumb_webp_b64 {
        Some(t) => {
            h.update([1u8]);
            h.update((t.len() as u64).to_le_bytes());
            h.update(t.as_bytes());
        }
        None => h.update([0u8]),
    }

    // Rich-card fields (issue #45) are bound too; `video_w/h` and `thumb_w/h` stay
    // OUT because lying about a layout integer buys only a wrong aspect ratio.
    // Absent fields contribute no bytes and the presence mask is appended only when
    // at least one IS present, so rows on disk keep the digest they were signed with.
    let empty = crate::node::RichCard::default();
    let r = lp.rich.as_deref().unwrap_or(&empty);
    let rich = [&r.kind, &r.author, &r.video_url];
    let mask = rich
        .iter()
        .enumerate()
        .fold(0u8, |m, (i, f)| if f.is_some() { m | (1 << i) } else { m });
    if mask != 0 {
        for field in rich.into_iter().flatten() {
            h.update((field.len() as u64).to_le_bytes());
            h.update(field.as_bytes());
        }
        h.update([mask]);
    }

    hex::encode(h.finalize())
}

/// The link-preview digest a SYNC ITEM's signature must be checked against.
///
/// The full card wins over a bare `lp_digest`, and that ordering IS the security
/// property: recomputing from the bytes we are about to store means the
/// signature covers exactly those bytes, so a responder that swaps in a phishing
/// card produces a digest the author never signed. A digest-only item is
/// legitimate and stores card-less.
pub(crate) fn backfill_lp_digest(
    lp: Option<&LinkPreviewRef>,
    lp_digest: Option<&str>,
) -> Option<String> {
    match lp {
        Some(lp) => Some(link_preview_digest(lp)),
        None => lp_digest.map(str::to_owned),
    }
}

/// The structured fields a v2 signature binds, alongside type/context/sender/
/// ts/text. All `Option` because older wire payloads omit them; an absent field
/// and an empty-string field are payload-equivalent (both serialize as "").
/// `lp_digest` is the hex [`link_preview_digest`].
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct SignedExtras<'a> {
    pub mid: Option<&'a str>,
    pub reply_to: Option<&'a str>,
    pub file_id: Option<&'a str>,
    pub order_us: Option<i64>,
    pub lp_digest: Option<&'a str>,
    /// Album grouping id; `Some("")` is treated as absent.
    pub album: Option<&'a str>,
}

impl SignedExtras<'_> {
    /// The album id that selects the v3 payload, with empty normalised to none.
    fn album(&self) -> Option<&str> {
        self.album.filter(|a| !a.is_empty())
    }
}

/// True for a hyphenated UUID (8-4-4-4-12 hex digits, either case). The album
/// slot sits before `text` in the v3 payload, so anything else (a colon above
/// all) would make the layout ambiguous.
pub(crate) fn is_album_id_shape(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}

/// Canonical signing payload. v2 without an album, byte-identical to 0.8.5:
///   hollow-msg2:{type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}
/// v3 when the message belongs to an album:
///   hollow-msg3:{type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{album}:{text}
/// Every field before `text` is colon-free, so `text` stays LAST and the layout
/// is unambiguous. The two prefixes differ, so stripping or adding an album
/// can never keep a signature valid.
pub(crate) fn message_signing_payload_v2(
    msg_type: &str,
    context: &str,
    sender: &str,
    ts: i64,
    extras: &SignedExtras,
    text: &str,
) -> String {
    let mid = extras.mid.unwrap_or("");
    let reply_to = extras.reply_to.unwrap_or("");
    let file_id = extras.file_id.unwrap_or("");
    let order_us = extras.order_us.map(|n| n.to_string()).unwrap_or_default();
    let lp = extras.lp_digest.unwrap_or("");
    match extras.album() {
        Some(album) => format!(
            "hollow-msg3:{msg_type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{album}:{text}"
        ),
        None => format!(
            "hollow-msg2:{msg_type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}"
        ),
    }
}

/// Sign a message over the canonical payload (v3 iff the extras carry an album).
/// Every sign site in the crate goes through here.
pub(crate) fn sign_message_versioned(
    keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    msg_type: &str,
    context: &str,
    sender: &str,
    ts: i64,
    extras: &SignedExtras,
    text: &str,
) -> (Option<String>, Option<String>) {
    let payload = message_signing_payload_v2(msg_type, context, sender, ts, extras, text);
    sign_message(keypair, pub_key_b64, &payload)
}

/// Verify a message signature against the canonical payload: v3 when the
/// received extras carry an album, v2 otherwise, never both.
///
/// There is deliberately no v1 fallback: it would be a downgrade oracle, since
/// the attacker rather than the sender picks which payload is checked. A
/// malformed album fails, and so do a body over [`MAX_MESSAGE_BYTES`] and a stamp
/// past [`message_ts_fits`], which makes this the one place every signed receive
/// path enforces both.
/// Reuses `pk_cache` across a batch; a missing signature returns false.
#[allow(clippy::too_many_arguments)]
pub(crate) fn verify_message_signature_v2(
    sender_peer_str: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    msg_type: &str,
    context: &str,
    ts: i64,
    extras: &SignedExtras,
    text: &str,
    pk_cache: &mut PkCache,
) -> bool {
    if extras.album().is_some_and(|a| !is_album_id_shape(a)) {
        return false;
    }
    if !message_body_fits(text) {
        hollow_log!("[HOLLOW-SECURITY] Dropped a {msg_type} message of {} bytes, over the {MAX_MESSAGE_BYTES}-byte limit", text.len());
        return false;
    }
    if !message_ts_fits(ts) {
        hollow_log!("[HOLLOW-SECURITY] Dropped a {msg_type} message dated {ts}, more than {MAX_FUTURE_SKEW_MS} ms past our clock");
        return false;
    }
    let payload = message_signing_payload_v2(msg_type, context, sender_peer_str, ts, extras, text);
    verify_message_signature_cached(sender_peer_str, sig_b64, pk_b64, &payload, pk_cache)
}

// -- Signed profiles (0.8.5, every field since 0.12) --
//
// Attribution used to come from the TRANSPORT, which `ProfileRelay` breaks: it
// carries an attacker-chosen `source_peer_id` gated only by an `updated_at` the
// same attacker picks, so `updated_at: i64::MAX` overwrote a victim's name and
// avatar permanently. The owner signs, relayers forward, receivers verify.
//
// Every field a receiver stores is signed, blobs by CONTENT HASH, so one signature
// covers the light hashes-only announce and the blob-carrying relay alike (N1).

/// Every field of a profile its owner signs, as it rides the wire.
#[derive(Clone, Copy, Default)]
pub(crate) struct ProfileFields<'a> {
    pub display_name: &'a str,
    pub status: &'a str,
    pub about_me: &'a str,
    pub twitch_username: &'a str,
    pub avatar_hash: &'a str,
    pub banner_hash: &'a str,
    pub showcase_board: &'a str,
    pub showcase_assets_hash: &'a str,
    pub avatar_frame: &'a str,
    pub avatar_anim: &'a str,
    pub banner_anim: &'a str,
}

/// Length-prefix every field into one digest: free text may hold any character, so
/// a joined payload would let one field's content impersonate the next boundary.
fn fields_digest(updated_at: i64, fields: &[&str]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(updated_at.to_le_bytes());
    for field in fields {
        h.update((field.len() as u64).to_le_bytes());
        h.update(field.as_bytes());
    }
    hex::encode(h.finalize())
}

/// Canonical payload for a profile signature.
pub(crate) fn profile_signing_payload(peer_id: &str, updated_at: i64, f: &ProfileFields) -> String {
    let digest = fields_digest(updated_at, &[
        peer_id, f.display_name, f.status, f.about_me, f.twitch_username, f.avatar_hash,
        f.banner_hash, f.showcase_board, f.showcase_assets_hash, f.avatar_frame,
        f.avatar_anim, f.banner_anim,
    ]);
    format!("hollow-profile2:{digest}")
}

/// Sign our own profile with the MASTER keypair: profiles are a per-identity
/// artifact and every receiver keys them on the master.
pub(crate) fn sign_profile(
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    peer_id: &str,
    updated_at: i64,
    fields: &ProfileFields,
) -> (Option<String>, Option<String>) {
    let pub_b64 = base64::engine::general_purpose::STANDARD.encode(master_keypair.public_key_protobuf());
    sign_message(master_keypair, &pub_b64, &profile_signing_payload(peer_id, updated_at, fields))
}

/// `true` = this profile is authentic for `peer_id`. REQUIRED at every ingest path
/// (absent is refused): "no signature" is the cheapest way to be a forwarder with
/// nothing to prove.
pub(crate) fn verify_profile_signature(
    peer_id: &str,
    updated_at: i64,
    fields: &ProfileFields,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
) -> bool {
    verify_message_signature(peer_id, sig_b64, pk_b64, &profile_signing_payload(peer_id, updated_at, fields))
}

/// Canonical payload for a profile CARD: the name and avatar anyone we are not
/// close to sees (A28), signed apart from the profile so it verifies without it.
pub(crate) fn card_signing_payload(master: &str, updated_at: i64, display_name: &str, avatar_hash: &str) -> String {
    format!("hollow-card1:{}", fields_digest(updated_at, &[master, display_name, avatar_hash]))
}

// -- The support-credentials field signature (2026-09-03) --
//
// `support_creds` sits OUTSIDE `profile_signing_payload` on purpose: every entry
// already binds the identity with a blind signature, so folding the field in
// would break the profile signature against every shipped client for nothing.
//
// That covers forgery and misses DENIAL: on the plaintext `ProfileUpdate`
// fallback a relay can rewrite the field to `""` and the profile signature still
// verifies. So the field carries its OWN master signature over
// `(master, updated_at, field)`, REQUIRED and covering `Some("")`. A baseline
// learned from the network is worthless against an attacker present for it.

/// Sign OUR `support_creds` field. `None` only when the field is absent,
/// which is what an announce carrying no credentials at all sends.
pub(crate) fn sign_support_creds(
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    master_peer_id: &str,
    updated_at: i64,
    support_creds: Option<&str>,
) -> Option<String> {
    let field = support_creds?;
    let message = super::support_creds::support_creds_sig_message(master_peer_id, updated_at, field);
    let sig = master_keypair.sign(&message);
    Some(base64::engine::general_purpose::STANDARD.encode(&sig))
}

/// `true` = this `support_creds` field really is the one `master_peer_id`
/// published at `updated_at`.
///
/// REJECTS, never logs-and-continues: the caller treats `false` as "the field is
/// ABSENT" and preserves what is stored. `pk_b64` is re-derived here.
pub(crate) fn verify_support_creds_sig(
    master_peer_id: &str,
    updated_at: i64,
    support_creds: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
) -> bool {
    use crate::identity::native_identity::NativeKeypair;

    let (Some(sig), Some(pk)) = (sig_b64, pk_b64) else {
        return false;
    };
    let b64 = base64::engine::general_purpose::STANDARD;
    let (Ok(pk_bytes), Ok(sig_bytes)) = (b64.decode(pk), b64.decode(sig)) else {
        return false;
    };
    // Bind the key to the master the field claims to come from: a real signature
    // by somebody else is not a signature by this identity.
    let Some(derived) = NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) else {
        return false;
    };
    if derived != master_peer_id {
        return false;
    }
    let message = super::support_creds::support_creds_sig_message(master_peer_id, updated_at, support_creds);
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, &message).unwrap_or(false)
}

// -- Authenticated Olm key exchange (root of trust, Fix A/B) --

/// How far a key-exchange timestamp may drift from local time before the frame
/// is treated as a replay. Generous enough for real clock skew, short enough
/// that a captured bundle is useless after a rotation.
pub(crate) const KEY_EXCHANGE_SKEW_SECS: i64 = 300;

/// Canonical payload for signing an Olm `KeyBundle`.
///
/// Format:
/// "hollow-keybundle:{sender_device}:{recipient_device}:{identity_key}:{one_time_key}:{ts}"
///
/// Every segment earns its place: `sender_device` binds the signature to the
/// peer_id the frame claims, linking the relay-supplied Curve25519 keys to the
/// Ed25519 identity the relay cannot forge; `recipient_device` blocks reflection
/// at a third party; both keys block re-pairing with substituted keys.
pub(crate) fn key_bundle_signing_payload(
    sender_device: &str,
    recipient_device: &str,
    identity_key: &str,
    one_time_key: &str,
    ts: i64,
) -> String {
    format!(
        "hollow-keybundle:{sender_device}:{recipient_device}:{identity_key}:{one_time_key}:{ts}"
    )
}

/// Canonical payload for signing an Olm `KeyRequest`.
///
/// Format: "hollow-keyrequest:{sender_device}:{recipient_device}:{ts}"
///
/// SECURITY: a KeyRequest makes the receiver TEAR DOWN a working Olm session, so
/// an unauthenticated one is a remote session-reset primitive against any peer.
pub(crate) fn key_request_signing_payload(
    sender_device: &str,
    recipient_device: &str,
    ts: i64,
) -> String {
    format!("hollow-keyrequest:{sender_device}:{recipient_device}:{ts}")
}

/// Current unix seconds, for key-exchange freshness stamps.
pub(crate) fn key_exchange_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Build a DEVICE-signed `KeyRequest` addressed to `to_device`.
///
/// The DEVICE keypair signs, not the master: the receiver knows us by our device
/// peer_id, so the signature is self-verifying with no resolver lookup, and the
/// master-to-device authorization is the separate `verify_device_list` link.
pub(crate) fn signed_key_request(
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    to_device: &str,
) -> HavenMessage {
    let ts = key_exchange_now();
    let payload = key_request_signing_payload(device_peer_id, to_device, ts);
    let pub_b64 = base64::engine::general_purpose::STANDARD
        .encode(device_keypair.public_key_protobuf());
    let (sig, pk) = sign_message(device_keypair, &pub_b64, &payload);
    HavenMessage::KeyRequest {
        to: Some(to_device.to_string()),
        ts: Some(ts),
        sig,
        pk,
    }
}

/// Build a DEVICE-signed `KeyBundle` addressed to `to_device`.
/// See [`signed_key_request`] for why the DEVICE key signs.
pub(crate) fn signed_key_bundle(
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    to_device: &str,
    identity_key: String,
    one_time_key: String,
) -> HavenMessage {
    let ts = key_exchange_now();
    let payload = key_bundle_signing_payload(
        device_peer_id, to_device, &identity_key, &one_time_key, ts,
    );
    let pub_b64 = base64::engine::general_purpose::STANDARD
        .encode(device_keypair.public_key_protobuf());
    let (sig, pk) = sign_message(device_keypair, &pub_b64, &payload);
    HavenMessage::KeyBundle {
        identity_key,
        one_time_key,
        to: Some(to_device.to_string()),
        ts: Some(ts),
        sig,
        pk,
    }
}

/// Outcome of checking an inbound key-exchange frame's authentication.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KeyExchangeAuth {
    /// Signature present and fully valid.
    Verified,
    /// No signature at all, from a client older than the rollout. Refused now that
    /// [`REQUIRE_SIGNED_KEY_EXCHANGE`] is set.
    Unsigned,
    /// Signature present but wrong, stale, or addressed elsewhere. ALWAYS
    /// refused — no legitimate client produces this.
    Invalid,
}

/// Phase 2 of the signed-key-exchange rollout, LIVE since 2026-07-23: unsigned
/// key exchange is refused outright, closing the key-substitution attack.
///
/// Shipped straight to enforcement rather than soaking a tolerant phase: the fix
/// lives in a PUBLIC repo, and publishing the hole while it is still exploitable
/// is worse than the cost, which is that an un-updated client cannot complete
/// NEW key exchange (live sessions unaffected, self-heals on update).
pub(crate) const REQUIRE_SIGNED_KEY_EXCHANGE: bool = true;

/// Verify the authentication on an inbound key-exchange frame.
///
/// `expected_recipient` is our OWN device peer_id. `payload` must be rebuilt by
/// the caller from the frame's own fields so a tampered field cannot verify.
pub(crate) fn verify_key_exchange(
    sender_device: &str,
    expected_recipient: &str,
    to: Option<&str>,
    ts: Option<i64>,
    sig: Option<&str>,
    pk: Option<&str>,
    payload: &str,
) -> KeyExchangeAuth {
    if sig.is_none() && pk.is_none() {
        return KeyExchangeAuth::Unsigned;
    }

    // Addressed to us? Blocks reflecting a bundle at a third party.
    match to {
        Some(t) if t == expected_recipient => {}
        _ => return KeyExchangeAuth::Invalid,
    }

    // Fresh? Blocks replaying a captured bundle after a key rotation.
    match ts {
        Some(t) if (key_exchange_now() - t).abs() <= KEY_EXCHANGE_SKEW_SECS => {}
        _ => return KeyExchangeAuth::Invalid,
    }

    // Signed by the device it claims to come from: `verify_message_signature`
    // re-derives the peer_id from `pk` and refuses a mismatch.
    if !verify_message_signature(sender_device, sig, pk, payload) {
        return KeyExchangeAuth::Invalid;
    }

    KeyExchangeAuth::Verified
}

/// True when an inbound key-exchange frame from `sender_device` must be refused
/// because that device is not in the signed device list of the master it maps to.
///
/// A signature alone proves only that SOME device produced the bundle: without
/// this, a hostile relay could mint a keypair, sign with it and establish a
/// session in the victim's name. An unknown device resolves to itself and is
/// allowed through: first contact, where `sender_device` IS the out-of-band
/// master. Rests on [`device_list_binds_sender`] for a set attackers cannot write.
pub(crate) fn key_exchange_device_unauthorized(sender_device: &str) -> bool {
    // A revoked device resolves to itself once forgotten, and a master id always
    // does: either would read as first contact.
    if super::resolver::is_revoked(sender_device) || super::resolver::is_bare_master(sender_device) {
        return true;
    }
    let master = super::resolver::resolve(sender_device);
    if master == sender_device {
        // Unknown device, or a single-device peer: nothing to cross-check.
        return false;
    }
    // Known master → the device MUST appear in its verified list.
    !super::resolver::devices_for(&master)
        .iter()
        .any(|d| d == sender_device)
}

/// Canonical payload binding a device to its Olm Curve25519 identity key.
///
/// Format: "hollow-olm-identity:{sender_device}:{identity_key}"
///
/// The signed `KeyBundle` covers the RESPONDER's keys only; a PreKey names the
/// INITIATOR's key, and the receiver builds its inbound session on it. No recipient
/// or timestamp: it is a standing fact about the device, and a replayed copy is
/// useless without the key's private half.
pub(crate) fn olm_identity_signing_payload(sender_device: &str, identity_key: &str) -> String {
    format!("hollow-olm-identity:{sender_device}:{identity_key}")
}

/// Sign this device's Olm identity key into `olm`, which then attaches the proof to
/// every PreKey it builds through [`encrypted_frame`].
pub(crate) fn bind_olm_identity(
    olm: &mut OlmManager,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
) {
    let payload = olm_identity_signing_payload(&device_keypair.peer_id(), &olm.identity_key_base64());
    let pub_b64 = base64::engine::general_purpose::STANDARD.encode(device_keypair.public_key_protobuf());
    if let (Some(sig), Some(pk)) = sign_message(device_keypair, &pub_b64, &payload) {
        olm.set_identity_proof(sig, pk);
    }
}

/// Whether a PreKey's `identity_key` provably belongs to `sender_device`: signed by
/// that device, and that device in its master's signed list. Absent is a refusal.
/// Must pass BEFORE any session is created or torn down for the frame.
pub(crate) fn verify_olm_identity(
    sender_device: &str,
    identity_key: &str,
    sig: Option<&str>,
    pk: Option<&str>,
) -> bool {
    let payload = olm_identity_signing_payload(sender_device, identity_key);
    verify_message_signature(sender_device, sig, pk, &payload)
        && !key_exchange_device_unauthorized(sender_device)
}

/// The wire frame for one Olm ciphertext. A PreKey carries our identity key and
/// its device proof; a normal message carries neither.
pub(crate) fn encrypted_frame(olm: &OlmManager, message_type: usize, ciphertext: &[u8]) -> HavenMessage {
    let (identity_key, identity_sig, identity_pk) = if message_type == 0 {
        let proof = olm.identity_proof().cloned();
        if proof.is_none() {
            hollow_log!("[HOLLOW-SECURITY] PreKey built with no identity proof; the receiver will refuse it");
        }
        let (sig, pk) = proof.unzip();
        (Some(olm.identity_key_base64()), sig, pk)
    } else {
        (None, None, None)
    };
    HavenMessage::Encrypted {
        message_type,
        body: OlmManager::encode_base64(ciphertext),
        identity_key,
        identity_sig,
        identity_pk,
    }
}

// -- Carried Olm key exchange (async friending) --

/// How long a bundle CARRIED inside a friend request stays usable.
///
/// Deliberately NOT [`KEY_EXCHANGE_SKEW_SECS`]: a carried bundle sits in the
/// relay's mailbox until the recipient next boots, which may be days. Replay is
/// stopped instead by the one-time key being single-use, and the two rules stay
/// in SEPARATE functions so loosening this one never widens the live window.
pub(crate) const MAX_CARRIED_BUNDLE_AGE_SECS: i64 = 7 * 24 * 3600;

/// Canonical payload for signing a [`CarriedBundle`].
///
/// Format:
/// "hollow-carried-keybundle:{sender_device}:{recipient_master}:{identity_key}:{one_time_key}:{ts}"
///
/// The PREFIX differs from [`key_bundle_signing_payload`] and segment three
/// names a MASTER, so a carried bundle can never verify as a live one (or the
/// reverse) even if an attacker reflects the bytes.
pub(crate) fn carried_bundle_signing_payload(
    sender_device: &str,
    recipient_master: &str,
    identity_key: &str,
    one_time_key: &str,
    ts: i64,
) -> String {
    format!(
        "hollow-carried-keybundle:{sender_device}:{recipient_master}:{identity_key}:{one_time_key}:{ts}"
    )
}

/// Build a DEVICE-signed [`CarriedBundle`] addressed to a recipient MASTER.
/// Mirrors [`signed_key_bundle`], but for the carried domain.
pub(crate) fn signed_carried_bundle(
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    to_master: &str,
    identity_key: String,
    one_time_key: String,
) -> CarriedBundle {
    let ts = key_exchange_now();
    let payload = carried_bundle_signing_payload(
        device_peer_id, to_master, &identity_key, &one_time_key, ts,
    );
    let pub_b64 = base64::engine::general_purpose::STANDARD
        .encode(device_keypair.public_key_protobuf());
    let sig = device_keypair.sign(payload.as_bytes());
    CarriedBundle {
        identity_key,
        one_time_key,
        to_master: to_master.to_string(),
        ts,
        sig_b64: base64::engine::general_purpose::STANDARD.encode(sig),
        device_pk_b64: pub_b64,
    }
}

/// The sender DEVICE peer_id a [`CarriedBundle`] claims, derived from its own
/// public key. `None` when the key does not decode to a peer_id at all.
pub(crate) fn carried_bundle_sender_device(b: &CarriedBundle) -> Option<String> {
    use base64::engine::general_purpose::STANDARD as B64;
    use crate::identity::native_identity::NativeKeypair;
    let pk_bytes = B64.decode(&b.device_pk_b64).ok()?;
    NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes)
}

/// Verify a [`CarriedBundle`] that arrived inside a friend request.
///
/// REJECTS (returns false), never logs-and-continues. Gate order mirrors the live
/// path: the signature verifies under a key that derives to the device the
/// payload names; that device is a member of the sender's roster; it is
/// addressed to OUR master; and it is fresh.
pub(crate) fn verify_carried_bundle(
    our_master: &str,
    sender_roster: &crate::identity::roster::Roster,
    b: &CarriedBundle,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    // 1. Signature, bound to the device its own public key derives to.
    let Some(sender_device) = carried_bundle_sender_device(b) else {
        return false;
    };
    let payload = carried_bundle_signing_payload(
        &sender_device, &b.to_master, &b.identity_key, &b.one_time_key, b.ts,
    );
    if !verify_message_signature(
        &sender_device,
        Some(b.sig_b64.as_str()),
        Some(b.device_pk_b64.as_str()),
        &payload,
    ) {
        return false;
    }

    // 2. That device must be a member of the roster it came with, judged against the
    // roster we already hold for that master.
    if !super::roster_book::carried_member(sender_roster, &sender_device, db_path, db_passphrase) {
        return false;
    }

    // 3. Addressed to US (our MASTER, not a device).
    if b.to_master != our_master {
        return false;
    }

    // 4. Freshness — the CARRIED rule, not the live one.
    let now = key_exchange_now();
    if now - b.ts > MAX_CARRIED_BUNDLE_AGE_SECS {
        return false;
    }
    if b.ts - now > KEY_EXCHANGE_SKEW_SECS {
        return false;
    }

    true
}

// -- Multi-device signed device list (Phase 6) --

/// Canonical payload for signing a device list.
/// Format:
/// "hollow-devices:{master_peer_id}:{version}:{sorted_device_csv}:{sorted_revoked_csv}".
/// Both arrays MUST be sorted before calling so the payload is deterministic.
/// The trailing revoked segment is present even when empty, so one signature
/// covers adds AND removes under one version; a pre-Step-7 4-segment signature
/// will not verify here, which is safe because lists are verified on receipt.
/// Kept for the 0.11 lists the upgrade reads and the relay's pinned vector.
#[cfg(test)]
pub(crate) fn device_list_signing_payload(
    master_peer_id: &str,
    version: u64,
    devices: &[String],
    revoked: &[String],
) -> String {
    format!(
        "hollow-devices:{master_peer_id}:{version}:{}:{}",
        devices.join(","),
        revoked.join(",")
    )
}

/// Build a master-signed [`SignedDeviceList`]. Both arrays are sorted and deduped
/// internally so the signed payload is canonical, and any id in `revoked` is
/// removed from `devices`: a revoked id can never coexist as an active device.
#[cfg(test)]
pub(crate) fn build_signed_device_list(
    master: &crate::identity::native_identity::NativeKeypair,
    version: u64,
    mut devices: Vec<String>,
    mut revoked: Vec<String>,
) -> SignedDeviceList {
    use base64::engine::general_purpose::STANDARD as B64;
    revoked.sort();
    revoked.dedup();
    devices.retain(|d| !revoked.iter().any(|r| r == d));
    devices.sort();
    devices.dedup();
    let master_peer_id = master.peer_id();
    let payload = device_list_signing_payload(&master_peer_id, version, &devices, &revoked);
    let sig = master.sign(payload.as_bytes());
    SignedDeviceList {
        master_pubkey_b64: B64.encode(master.public_key_protobuf()),
        master_peer_id,
        devices,
        revoked,
        version,
        sig_b64: B64.encode(sig),
    }
}

/// Verify a [`SignedDeviceList`]: the master pubkey must derive to the claimed
/// `master_peer_id`, and the signature must validate over the canonical payload.
/// Only the relay reads one now (the inbox proof); this is its check for the mock.
#[cfg(test)]
pub(crate) fn verify_device_list(list: &SignedDeviceList) -> bool {
    use base64::engine::general_purpose::STANDARD as B64;
    use crate::identity::native_identity::NativeKeypair;

    let Ok(pk_bytes) = B64.decode(&list.master_pubkey_b64) else {
        return false;
    };
    // Bind pubkey → claimed master peer_id.
    match NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) {
        Some(derived) if derived == list.master_peer_id => {}
        _ => return false,
    }
    let Ok(sig_bytes) = B64.decode(&list.sig_b64) else {
        return false;
    };
    // Verify over sorted copies so an attacker cannot reorder or strip either
    // array after signing.
    let mut devices = list.devices.clone();
    devices.sort();
    let mut revoked = list.revoked.clone();
    revoked.sort();
    let payload =
        device_list_signing_payload(&list.master_peer_id, list.version, &devices, &revoked);
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

// -- Destruction orders (Part 2, scope (c); design ID-1) --

/// Canonical payload every signature on a [`DestroyIdentity`] covers.
/// "hollow-destroy2:{master}:{issued_at_ms}:{sorted csv targets}:{notify_friends}".
/// `targets` MUST be sorted before calling so the payload is deterministic.
pub(crate) fn destroy_identity_signing_payload(
    master_peer_id: &str,
    issued_at_ms: i64,
    targets: &[String],
    notify_friends: bool,
) -> String {
    format!(
        "hollow-destroy2:{master_peer_id}:{issued_at_ms}:{}:{notify_friends}",
        targets.join(",")
    )
}

/// The phrase's permission for `device` to order its identity destroyed.
pub(crate) fn destroy_delegation_payload(master_peer_id: &str, r_pub: &str, device: &str, at_ms: i64) -> String {
    format!("hollow-id1-destroy-delegate:{master_peer_id}:{r_pub}:{device}:{at_ms}")
}

/// A destruction order signed by the master and, when the phrase was typed, by the
/// recovery key. `targets` is sorted and deduped here; empty = every device.
pub(crate) fn build_destroy_identity(
    master: &crate::identity::native_identity::NativeKeypair,
    recovery: Option<&crate::identity::native_identity::NativeKeypair>,
    issued_at_ms: i64,
    mut targets: Vec<String>,
    notify_friends: bool,
) -> DestroyIdentity {
    use base64::engine::general_purpose::STANDARD as B64;
    targets.sort();
    targets.dedup();
    let master_peer_id = master.peer_id();
    let payload =
        destroy_identity_signing_payload(&master_peer_id, issued_at_ms, &targets, notify_friends);
    let (r_pub, sig_r) = match recovery {
        Some(r) => (crate::identity::roster::r_pub_of(r), B64.encode(r.sign(payload.as_bytes()))),
        None => (String::new(), String::new()),
    };
    DestroyIdentity {
        master_pubkey_b64: B64.encode(master.public_key_protobuf()),
        master_peer_id,
        issued_at_ms,
        targets,
        notify_friends,
        sig_b64: B64.encode(master.sign(payload.as_bytes())),
        r_pub,
        sig_r,
        delegation: None,
    }
}

/// The phrase's permission for `device`, without the order signature.
pub(crate) fn sign_destroy_delegation(
    master: &crate::identity::native_identity::NativeKeypair,
    recovery: &crate::identity::native_identity::NativeKeypair,
    device: &str,
    at_ms: i64,
) -> DestroyDelegation {
    use base64::engine::general_purpose::STANDARD as B64;
    let r_pub = crate::identity::roster::r_pub_of(recovery);
    let payload = destroy_delegation_payload(&master.peer_id(), &r_pub, device, at_ms);
    DestroyDelegation {
        device: device.to_string(),
        at_ms,
        r_pub,
        sig_r: B64.encode(recovery.sign(payload.as_bytes())),
        device_sig: String::new(),
    }
}

/// An order this device signs under the phrase's permission for it.
pub(crate) fn build_delegated_destroy(
    master: &crate::identity::native_identity::NativeKeypair,
    device: &crate::identity::native_identity::NativeKeypair,
    mut delegation: DestroyDelegation,
    issued_at_ms: i64,
    notify_friends: bool,
) -> DestroyIdentity {
    use base64::engine::general_purpose::STANDARD as B64;
    let mut order = build_destroy_identity(master, None, issued_at_ms, Vec::new(), notify_friends);
    let payload = destroy_identity_signing_payload(
        &order.master_peer_id, order.issued_at_ms, &order.targets, order.notify_friends,
    );
    delegation.device_sig = B64.encode(device.sign(payload.as_bytes()));
    order.delegation = Some(delegation);
    order
}

/// Whether the master signed this order: it names the identity. Authority is
/// [`destroy_order_authorised`]'s question.
pub(crate) fn verify_destroy_identity(order: &DestroyIdentity) -> bool {
    use base64::engine::general_purpose::STANDARD as B64;
    use crate::identity::native_identity::NativeKeypair;

    let Ok(pk_bytes) = B64.decode(&order.master_pubkey_b64) else {
        return false;
    };
    match NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) {
        Some(derived) if derived == order.master_peer_id => {}
        _ => return false,
    }
    let Ok(sig_bytes) = B64.decode(&order.sig_b64) else {
        return false;
    };
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, destroy_payload_of(order).as_bytes())
        .unwrap_or(false)
}

fn destroy_payload_of(order: &DestroyIdentity) -> String {
    // Sorted copy, so an attacker cannot reorder the targets after signing.
    let mut targets = order.targets.clone();
    targets.sort();
    destroy_identity_signing_payload(
        &order.master_peer_id, order.issued_at_ms, &targets, order.notify_friends,
    )
}

fn verify_raw(pubkey: &[u8; 32], payload: &str, sig_b64: &str) -> bool {
    use base64::engine::general_purpose::STANDARD as B64;
    let Ok(sig) = B64.decode(sig_b64) else { return false };
    let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else { return false };
    let Ok(vk) = ed25519_dalek::VerifyingKey::from_bytes(pubkey) else { return false };
    vk.verify_strict(payload.as_bytes(), &ed25519_dalek::Signature::from_bytes(&sig)).is_ok()
}

fn r_key(r_pub: &str) -> Option<[u8; 32]> {
    use base64::engine::general_purpose::STANDARD as B64;
    <[u8; 32]>::try_from(B64.decode(r_pub).ok()?.as_slice()).ok()
}

/// Whether an order the master signed is backed by the identity's authority: the
/// phrase itself under `pinned_r`, or a member device holding the phrase's
/// permission. An identity with no recovery key yet (`pinned_r` empty) has only the
/// master, whose signature [`verify_destroy_identity`] already checked.
pub(crate) fn destroy_order_authorised(
    order: &DestroyIdentity,
    pinned_r: &str,
    members: &crate::identity::roster::RosterState,
) -> bool {
    if pinned_r.is_empty() {
        return true;
    }
    let Some(rk) = r_key(pinned_r) else { return false };
    let payload = destroy_payload_of(order);
    if order.r_pub == pinned_r && verify_raw(&rk, &payload, &order.sig_r) {
        return true;
    }
    let Some(d) = order.delegation.as_ref() else { return false };
    let Some(dk) = crate::crypto::safety_number::pubkey_from_peer_id(&d.device) else {
        return false;
    };
    d.r_pub == pinned_r
        && members.is_member(&d.device)
        && verify_raw(
            &rk,
            &destroy_delegation_payload(&order.master_peer_id, &d.r_pub, &d.device, d.at_ms),
            &d.sig_r,
        )
        && verify_raw(&dk, &payload, &d.device_sig)
}

/// Protocol ceiling, in BYTES, of one message body (post, edit, caption, meeting
/// line). The composer caps CHARACTERS (4,000); this bounds what those expand to,
/// emote tokens and combining marks included. Dart's `kMaxMessageBytes` is the
/// same number.
pub(crate) const MAX_MESSAGE_BYTES: usize = 64 * 1024;

/// True when a message body fits [`MAX_MESSAGE_BYTES`]. A longer one is DROPPED
/// whole on every path, never clipped: a clipped row no longer matches its
/// signature, so it would fail on every device we serve it to.
pub(crate) fn message_body_fits(text: &str) -> bool {
    text.len() <= MAX_MESSAGE_BYTES
}

/// How far past our clock a message may be dated. Relay auth already holds every
/// connected client to 60 s, so only a forged stamp gets near it.
pub(crate) const MAX_FUTURE_SKEW_MS: i64 = 10 * 60 * 1000;

/// True when `ts` is not dated past our clock by more than [`MAX_FUTURE_SKEW_MS`].
/// A future-dated message sorts below every later one until its time comes, and
/// spacing future stamps was a way round slow mode.
pub(crate) fn message_ts_fits(ts: i64) -> bool {
    ts <= super::types::now_ms().saturating_add(MAX_FUTURE_SKEW_MS)
}

/// The longest prefix of `s` that is at most `max` bytes and ends on a character
/// boundary. The ONE way to cut a remote string: a byte slice through a multi-byte
/// character panics, and on the event loop that panic takes the node down.
pub(crate) fn clip_bytes(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Sign a message payload with the local keypair, returning `(sig_b64, pk_b64)`.
pub(crate) fn sign_message(
    keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    payload: &str,
) -> (Option<String>, Option<String>) {
    let sig = keypair.sign(payload.as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&sig);
    (Some(sig_b64), Some(pub_key_b64.to_string()))
}

/// Verify an Ed25519 signature on a message.
/// Checks: public key decodes, PeerId matches sender, signature is valid.
pub(crate) fn verify_message_signature(
    sender_peer_str: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    payload: &str,
) -> bool {
    use crate::identity::native_identity::NativeKeypair;

    let (sig, pk) = match (sig_b64, pk_b64) {
        (Some(s), Some(p)) => (s, p),
        _ => return false,
    };

    let Ok(pk_bytes) = base64::engine::general_purpose::STANDARD.decode(pk) else {
        return false;
    };

    // Bind the public key to the claimed sender. ONE canonical derivation: the
    // hand-rolled copy that used to live here checked a weaker protobuf header.
    let Some(derived_pid) = NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) else {
        return false;
    };
    if derived_pid != sender_peer_str {
        return false;
    }

    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig) else {
        return false;
    };
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// Decoded-public-key cache for ONE sync batch: `pk_b64 → (pk_bytes, peer_id
/// DERIVED from those bytes)`.
///
/// SECURITY: the derived peer_id is cached ALONGSIDE the bytes on purpose. An
/// earlier version cached only the bytes and re-checked the binding on the
/// cache-MISS path, so item 2 could claim sender B while shipping A's key and
/// A's real signature. Keep the comparison on the HIT path.
pub(crate) type PkCache = HashMap<String, (Vec<u8>, String)>;

/// Batch-optimized [`verify_message_signature`]: caches the base64 decode and
/// the PeerId derivation, never the pk-to-sender decision.
pub(crate) fn verify_message_signature_cached(
    sender_peer_str: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    payload: &str,
    pk_cache: &mut PkCache,
) -> bool {
    use crate::identity::native_identity::NativeKeypair;

    let (sig, pk) = match (sig_b64, pk_b64) {
        (Some(s), Some(p)) => (s, p),
        _ => return false,
    };

    if !pk_cache.contains_key(pk) {
        let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(pk) else {
            return false;
        };
        let Some(derived_pid) = NativeKeypair::peer_id_from_pubkey_protobuf(&bytes) else {
            return false;
        };
        pk_cache.insert(pk.to_string(), (bytes, derived_pid));
    }
    let Some((pk_bytes, derived_pid)) = pk_cache.get(pk) else {
        return false;
    };

    // SECURITY: the pk→claimed-sender binding is re-checked on EVERY call, hit
    // or miss. See [`PkCache`] for what skipping it on a hit made possible.
    if derived_pid != sender_peer_str {
        return false;
    }

    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig) else {
        return false;
    };
    NativeKeypair::verify_peer_signature(pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// Backfill enforcement switch (0.8.5). `true` = a sync/fetch item is stored
/// ONLY when its signature is present AND verifies; `Valid` is the only
/// acceptable verdict.
///
/// Tolerating `Absent`, so history predating per-message signing kept
/// replicating, was a message-INJECTION primitive: a hostile responder only had
/// to OMIT the signature, and the channel item names its own sender, so the
/// injection could impersonate any member. Pre-signing rows still display.
pub(crate) const REQUIRE_SIGNED_BACKFILL: bool = true;

/// Outcome of checking the signature on a BACKFILLED (sync) message item.
///
/// `Absent` and `Forged` are both refused, but stay DISTINCT variants: the log
/// line is the only way to tell "an old peer served pre-signing history" from
/// "someone is injecting messages at us".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BackfillSig {
    /// No signature material at all: pre-signing history, or an injection that
    /// omitted the signature. Refused; see [`REQUIRE_SIGNED_BACKFILL`].
    Absent,
    /// Signature present and it verifies against the claimed sender.
    Valid,
    /// Signature present and it does NOT verify. REJECT the item — a wrong
    /// signature is not legacy data, it is tampering.
    Forged,
    /// The body is over [`MAX_MESSAGE_BYTES`]. Refused whatever it carries.
    Oversized,
    /// Dated past [`message_ts_fits`]. Refused whatever it carries.
    FutureDated,
}

impl BackfillSig {
    /// The ONE gate every backfill/fetch call site reads, so the enforcement rule
    /// is greppable and can only change in one place.
    pub(crate) fn is_acceptable(self) -> bool {
        match self {
            BackfillSig::Valid => true,
            BackfillSig::Forged | BackfillSig::Oversized | BackfillSig::FutureDated => false,
            BackfillSig::Absent => !REQUIRE_SIGNED_BACKFILL,
        }
    }

    /// Short reason for the rejection log, so support can tell an old peer
    /// from an attack at a glance.
    pub(crate) fn reject_reason(self) -> &'static str {
        match self {
            BackfillSig::Absent => "NO signature (pre-signing history, or stripped in transit)",
            BackfillSig::Forged => "signature present but INVALID",
            BackfillSig::Oversized => "body over the message size limit",
            BackfillSig::FutureDated => "dated more than 10 minutes past our clock",
            BackfillSig::Valid => "accepted",
        }
    }
}

/// Apply the backfill signature rule to one sync item.
///
/// Callers MUST gate on [`BackfillSig::is_acceptable`], never on
/// `== BackfillSig::Forged`: only `Valid` is stored, and an ABSENT signature (an
/// injection primitive) is refused as firmly as a PRESENT-but-invalid one.
///
/// `edited_at` selects the timestamp the signature was really made over: an edit
/// is re-signed over the EDIT timestamp and the NEW text, so verifying an edited
/// row against its original `ts` fails every one of them. That is why edits used
/// to skip verification, and why setting `edited_at` was a way around it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn check_backfill_signature(
    signer: &str,
    msg_type: &str,
    context: &str,
    ts: i64,
    edited_at: Option<i64>,
    extras: &SignedExtras,
    text: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    pk_cache: &mut PkCache,
) -> BackfillSig {
    if !message_body_fits(text) {
        return BackfillSig::Oversized;
    }
    if !message_ts_fits(ts) || edited_at.is_some_and(|e| !message_ts_fits(e)) {
        return BackfillSig::FutureDated;
    }
    if sig_b64.is_none() && pk_b64.is_none() {
        return BackfillSig::Absent;
    }
    let signed_ts = edited_at.unwrap_or(ts);
    if verify_message_signature_v2(
        signer, sig_b64, pk_b64, msg_type, context, signed_ts, extras, text, pk_cache,
    ) {
        BackfillSig::Valid
    } else {
        BackfillSig::Forged
    }
}

/// Persist MLS state (signer + credential + storage) via the CryptoStore actor.
pub(crate) fn persist_mls_state(mls: &MlsManager, crypto_store: &crate::crypto::CryptoStore) {
    let signer = match mls.signer_bytes() {
        Ok(s) => s,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize signer: {e}"); return; }
    };
    let cred = match mls.credential_bytes() {
        Ok(c) => c,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize credential: {e}"); return; }
    };
    let storage = match mls.serialize_storage() {
        Ok(s) => s,
        Err(e) => { hollow_log!("[HOLLOW-MLS] Failed to serialize storage: {e}"); return; }
    };
    crypto_store.save_mls_identity(signer, cred, storage);
}

/// Mint a KeyPackage AND persist the MLS state that holds its private half.
///
/// [`MlsManager::generate_key_package`] writes the private init and leaf keys to
/// in-RAM storage only, so a restart before some UNRELATED persist drops the
/// private half while the public KeyPackage is already on the wire: every
/// Welcome built from it then fails forever with `NoMatchingKeyPackage`, and a
/// parked join makes that window days long by design.
///
/// The ONLY call site of `generate_key_package` in `node/`, guarded by a source
/// scan in `key_package_mints_persist_mls_state`.
pub(crate) fn mint_key_package(
    mls: &MlsManager,
    crypto_store: &crate::crypto::CryptoStore,
) -> Result<Vec<u8>, String> {
    let kp_bytes = mls.generate_key_package()?;
    persist_mls_state(mls, crypto_store);
    Ok(kp_bytes)
}

/// Check if a peer is reachable via WS relay.
///
/// The relay reports DEVICE peer_ids, but callers often ask about a MASTER id,
/// so a master counts as reachable when ANY of its devices is in a room. The
/// exact-membership fast path keeps single-device callers free of resolver cost.
pub(crate) fn peer_is_reachable(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> bool {
    if ws_room_peers.values().any(|peers| peers.contains(peer_str)) {
        return true;
    }
    // Slow path. There must be NO `resolve(peer) == peer -> false` early return
    // here: it fires for every bare MASTER id and would make a friend or member
    // with online devices permanently "unreachable", silently disabling coordinator
    // election, MLS recovery targeting, subgroup bootstrap and push classification.
    let target_master = super::resolver::resolve(peer_str);
    ws_room_peers.values().any(|peers| {
        peers.iter().any(|p| super::resolver::resolve(p) == target_master)
    })
}

/// The single concrete DEVICE id to address when a caller holds a (possibly
/// master) peer id and needs ONE socket-addressable target. The exact id wins
/// when it is itself in a room; otherwise the deterministic lowest online device
/// of the identity. `None` when nothing is online: reachable implies `Some`.
pub(crate) fn preferred_online_device(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Option<String> {
    if ws_room_peers.values().any(|peers| peers.contains(peer_str)) {
        return Some(peer_str.to_string());
    }
    let mut devices = online_devices_for(ws_room_peers, peer_str);
    devices.sort();
    devices.into_iter().next()
}

/// The LIVE device peer_ids (currently in some WS room) belonging to the same
/// identity as `peer_str`, which may be a master id (the friend-list/UI key, no
/// socket authenticates as it) or a device id.
///
/// Used by every TARGETED send the UI addresses by master id (call signaling,
/// WebRTC offer/answer/ICE, file requests): without it those sends hit the bare
/// master and are silently dropped. An empty vec means nothing is online.
pub(crate) fn online_devices_for(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Vec<String> {
    let master = super::resolver::resolve(peer_str);
    let mut set: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut master_is_socket = false;
    for peers in ws_room_peers.values() {
        for p in peers {
            if p == peer_str || super::resolver::resolve(p) == master {
                if *p == master {
                    // Room membership is socket-authenticated, so a master id appearing IN a
                    // room is a LEGACY single-device identity (device == master).
                    master_is_socket = true;
                }
                set.insert(p.clone());
            }
        }
    }
    // Never include a bare master no socket authenticates as (those sends are
    // silently dropped), but KEEP it when it IS a live socket: otherwise legacy
    // identities get an empty vec and callers without a raw-id fallback skip them.
    if !master_is_socket {
        set.remove(&master);
    }
    set.into_iter().collect()
}

/// Online member DEVICES that cannot read an MLS frame for `group_key` because
/// they hold no leaf in OUR copy of the group. Excludes our own identity.
///
/// This is the COMPLEMENT rule for encrypted content and ephemeral signals.
/// "Send the fallback only when OUR OWN encrypt failed" measures the wrong end
/// of the wire: a member can be reachable and still leaf-less (a parked join
/// completes its CRDT half BEFORE the leaf forms) or sit at a skewed epoch.
pub(crate) fn leafless_member_devices(
    mls: &Option<MlsManager>,
    group_key: &str,
    state: &crate::crdt::server_state::ServerState,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer: &str,
) -> Vec<String> {
    leafless_member_devices_where(mls, group_key, state, ws_room_peers, local_peer, |_| true)
}

/// [`leafless_member_devices`] with an extra per-MASTER predicate, so a caller
/// working on a per-channel SUBGROUP can drop members who do not qualify for the
/// channel at all: a non-qualifier must never receive the content.
pub(crate) fn leafless_member_devices_where(
    mls: &Option<MlsManager>,
    group_key: &str,
    state: &crate::crdt::server_state::ServerState,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer: &str,
    member_allowed: impl Fn(&str) -> bool,
) -> Vec<String> {
    // Computed ONCE, not per device: `group_members` walks every leaf.
    let (holds_group, leaves) = match mls.as_ref() {
        Some(m) if m.has_group(group_key) => {
            let set: std::collections::HashSet<String> =
                m.group_members(group_key).into_iter().collect();
            (true, set)
        }
        // No MLS at all, or we do not hold this group: nobody can read our
        // (non-existent) frame, so every online member device is leaf-less.
        _ => (false, std::collections::HashSet::new()),
    };

    let mut out: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for member in state.members.keys() {
        if super::resolver::same_identity(member, local_peer) { continue; }
        if !member_allowed(member) { continue; }
        for dev in online_devices_for(ws_room_peers, member) {
            if holds_group && leaves.contains(&dev) { continue; }
            if seen.insert(dev.clone()) {
                out.push(dev);
            }
        }
    }
    out
}

/// Whether `requester_peer_id` may READ `channel_id`'s stored content in
/// `state`: its message history, its file headers (which carry the file's AES
/// key) and its bytes.
///
/// The per-channel MLS subgroup only protects LIVE traffic, and backfill was the
/// bypass: a plain Member could read an Admin-only channel's whole history and
/// download its files. Every serving path asks this first.
///
/// MEMBERSHIP IS THE FIRST RUNG. `can_see_channel` alone is not a gate: an
/// unknown peer's role resolves to plain `Member`, so a stranger in the server's
/// WS room would pass the ladder for every `Everyone` channel. PUBLIC channels
/// are the one exception, which is what public means.
pub(crate) fn channel_readable_by(
    state: &crate::crdt::server_state::ServerState,
    requester_peer_id: &str,
    channel_id: &str,
) -> bool {
    let master = super::resolver::resolve(requester_peer_id);
    (state.is_member(&master) || state.is_channel_public(channel_id))
        && state.can_see_channel(&master, channel_id)
}

/// Whether `sender` may BACKFILL `channel_id` to us: a current member who can
/// read it. Stricter than [`channel_readable_by`], which also lets guests read a
/// public channel: a guest may read history, never write it into ours.
pub(crate) fn channel_backfill_allowed_from(
    state: Option<&crate::crdt::server_state::ServerState>,
    sender_peer_id: &str,
    channel_id: &str,
) -> bool {
    let master = super::resolver::resolve(sender_peer_id);
    let allowed = state.is_some_and(|s| s.is_member(&master) && s.can_see_channel(&master, channel_id));
    if !allowed {
        hollow_log!("[HOLLOW-SECURITY] REJECTED channel backfill for {channel_id} from {sender_peer_id}: not a member who can read it");
    }
    allowed
}

/// Whether `peer` may be asked to sync what we hold of a server, one channel of it or
/// its op log: a device of a current member who can read that channel. Our request
/// names what we hold, and a frame that fails to decrypt can come from anyone in the room.
pub(crate) fn sync_partner(
    state: Option<&crate::crdt::server_state::ServerState>,
    peer: &str,
    channel: Option<&str>,
) -> bool {
    let master = super::resolver::resolve(peer);
    !super::resolver::is_revoked(peer)
        && state.is_some_and(|s| s.is_member(&master) && channel.is_none_or(|c| s.can_see_channel(&master, c)))
}

/// Whom the sync requests an MLS commit or Welcome triggers go to, with the master its
/// channel reads are judged by: the leaf that made it when its certified master is a
/// current member whose roster does not refuse it (a joiner cannot place co-members'
/// devices yet), else the device that delivered it when that is a [`sync_partner`].
/// Anyone can re-seal a member's commit or Welcome, and the requests name what we hold.
pub(crate) fn mls_sync_partner<'a>(
    state: Option<&crate::crdt::server_state::ServerState>,
    leaf: Option<&'a crate::crypto::LeafIdentity>,
    frame_sender: Option<&'a str>,
) -> Option<(&'a str, String)> {
    let state = state?;
    if let Some(leaf) = leaf.filter(|l| state.is_member(&l.master) && !super::mls_authority::refused(l)) {
        return Some((leaf.device.as_str(), leaf.master.clone()));
    }
    frame_sender
        .filter(|d| sync_partner(Some(state), d, None))
        .map(|d| (d, super::resolver::resolve(d)))
}

/// E4: backfill never brings in a post whose author (master) was not a member when
/// it was written, going by the membership record. A legacy-anchored server has no
/// record to prove it by yet and is not judged.
pub(crate) fn backfill_author_allowed(
    state: Option<&crate::crdt::server_state::ServerState>,
    author: &str,
    ts_ms: i64,
) -> bool {
    let Some(state) = state else { return false };
    if state.anchor() == crate::crdt::server_state::Anchor::Legacy {
        return true;
    }
    let master = super::resolver::resolve(author);
    let allowed = state.was_member_at(&master, ts_ms.max(0) as u64);
    if !allowed {
        hollow_log!("[HOLLOW-SECURITY] REJECTED backfilled post in {} by {master}: not a member when it was written", state.server_id);
    }
    allowed
}

/// E4 over one backfilled page: a post stays only if its author was a member when
/// it was written, and a reaction riding it only if its reactor was one at its own time.
pub(crate) fn backfill_filter(
    state: Option<&crate::crdt::server_state::ServerState>,
    messages: &mut Vec<SyncMessageItem>,
) {
    messages.retain(|m| backfill_author_allowed(state, &m.s, m.ts));
    for m in messages.iter_mut() {
        m.reactions.retain(|r| backfill_author_allowed(state, &r.p, r.ts));
    }
}

/// Collapse online MLS leaf credential ids (device ids, or master ids for legacy
/// leaves) into the sorted, deduped set of distinct MASTER identities that are
/// online; `local_peer` always counts. Coordinator elections use it so a human
/// with N leaves counts ONCE and the election is stable per identity.
fn online_master_identities(
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Vec<String> {
    let mut masters: Vec<String> = mls_members
        .iter()
        .filter(|p| p.as_str() == local_peer || peer_is_reachable(ws_room_peers, p))
        .map(|p| super::resolver::resolve(p))
        .collect();
    // `local_peer` is the master and always counts as online: it may not appear in
    // `mls_members` when our own leaf is device-credentialed.
    masters.push(local_peer.to_string());
    masters.sort();
    masters.dedup();
    masters
}

/// Deterministic MLS coordinator: the lowest MASTER identity among online MLS
/// group members, so one human is one candidate. Only group members participate,
/// so a non-member can never become coordinator.
pub(crate) fn elect_coordinator(
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let masters = online_master_identities(mls_members, local_peer, ws_room_peers);
    masters.into_iter().next()
}

/// Server-group MLS coordinator with OWNER PREFERENCE: when the owner is online,
/// holds a leaf and is not the excluded sender, it is the sole committer for
/// server-group adds. This keeps epochs LINEAR: a non-owner committer can add a
/// member and then fail to fan the Commit to another leaf, which then diverges
/// permanently with no retry. Falls back to [`elect_coordinator`].
pub(crate) fn elect_server_coordinator(
    server: &crate::crdt::server_state::ServerState,
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    if let Some(owner) = owner {
        let owner_online = owner.as_str() == local_peer || peer_is_reachable(ws_room_peers, owner);
        // The owner must be a candidate of THIS election: it holds a leaf and is not
        // the excluded sender.
        let owner_is_candidate = mls_members.iter().any(|p| super::resolver::same_identity(p, owner));
        if owner_online && owner_is_candidate {
            return Some(owner.clone());
        }
    }
    elect_coordinator(mls_members, local_peer, ws_room_peers)
}

/// Where a member sends its server-group bootstrap/recovery KeyPackage: the
/// OWNER when online (it always holds the group), else the lowest online master
/// among CRDT members. Pairs with [`elect_server_coordinator`] so the owner is
/// both committer and recovery target, closing the 3+-member recovery deadlock.
pub(crate) fn server_bootstrap_target(
    server: &crate::crdt::server_state::ServerState,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    if let Some(owner) = owner {
        if owner.as_str() != local_peer && peer_is_reachable(ws_room_peers, owner) {
            return Some(owner.clone());
        }
    }
    let members: Vec<String> = server.members.keys().cloned().collect();
    elect_coordinator(&members, local_peer, ws_room_peers).filter(|c| c != local_peer)
}

pub(crate) fn is_mls_coordinator(
    mls: &MlsManager,
    server_id: &str,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    if !mls.has_group(server_id) {
        return false;
    }
    let members = mls.group_members(server_id);
    elect_coordinator(&members, local_peer, ws_room_peers).as_deref() == Some(local_peer)
}

/// Vault coordinator: 2nd-lowest online MASTER identity (distributes work away
/// from the MLS coordinator). Falls back to lowest if only one identity is online.
pub(crate) fn elect_vault_coordinator(
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let masters = online_master_identities(mls_members, local_peer, ws_room_peers);
    if masters.is_empty() {
        return None;
    }
    if masters.len() >= 2 {
        Some(masters[1].clone())
    } else {
        Some(masters[0].clone())
    }
}

pub(crate) fn is_vault_coordinator(
    mls: &MlsManager,
    server_id: &str,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    if !mls.has_group(server_id) {
        return false;
    }
    let members = mls.group_members(server_id);
    elect_vault_coordinator(&members, local_peer, ws_room_peers).as_deref() == Some(local_peer)
}

/// Elect the coordinator for a per-channel MLS subgroup. A subgroup may not
/// exist yet on any node, so candidates come from the CRDT: the members who
/// QUALIFY for the channel and are online, lowest master wins. `None` when
/// nobody (including us) qualifies online.
pub(crate) fn elect_subgroup_coordinator(
    server: &crate::crdt::server_state::ServerState,
    channel_id: &str,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    // Prefer the OWNER when online: it always qualifies and is a globally agreed
    // choice from the CRDT, so two nodes cannot each elect themselves and fork the
    // subgroup under one id.
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    if let Some(owner) = owner {
        if owner.as_str() == local_peer || peer_is_reachable(ws_room_peers, owner) {
            return Some(owner.clone());
        }
    }
    let mut masters: Vec<String> = server.members.keys()
        .filter(|m| server.can_see_channel(m, channel_id))
        .filter(|m| m.as_str() == local_peer || peer_is_reachable(ws_room_peers, m))
        .cloned()
        .collect();
    masters.sort();
    masters.dedup();
    masters.into_iter().next()
}

/// Send our KeyPackage to a restricted channel's subgroup coordinator so we can
/// be added to (or bootstrap) the subgroup. No-op when WE are the coordinator or
/// nobody qualifying is online. The `channel_id` tag is what makes the
/// coordinator add us to the SUBGROUP rather than the server group.
#[allow(clippy::too_many_arguments)]
pub(crate) fn request_subgroup_bootstrap(
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    channel_id: &str,
    local_peer: &str,
) {
    let coordinator = match elect_subgroup_coordinator(server, channel_id, local_peer, ws_room_peers) {
        Some(c) if c != local_peer => c,
        _ => return, // we're the coordinator (reconciler handles it) or nobody online
    };
    let kp_bytes = match mint_key_package(mls, crypto_store) {
        Ok(kp) => kp,
        Err(e) => { hollow_log!("[HOLLOW-MLS] subgroup KP gen failed: {e}"); return; }
    };
    let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
    let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
        server_id: server_id.to_string(),
        key_package: kp_b64,
        channel_id: Some(channel_id.to_string()),
    }).unwrap_or_default();
    let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &coordinator, data);
    if sent > 0 {
        hollow_log!("[HOLLOW-MLS] Sent subgroup KeyPackage to coordinator {coordinator} for {server_id}#{channel_id} ({sent} device(s))");
    }
}

/// Send our KeyPackage to the server OWNER so we can be re-added to the
/// SERVER-WIDE MLS group. No-op when WE are the owner or the owner is offline:
/// only a group HOLDER can add us and the owner is the authority, so there is no
/// useful fallback. Returns true when a KeyPackage actually went out.
pub(crate) fn request_server_group_bootstrap(
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    local_peer: &str,
) -> bool {
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    let Some(owner) = owner else { return false };
    if super::resolver::same_identity(owner, local_peer) { return false; }
    if !peer_is_reachable(ws_room_peers, owner) { return false; }
    let kp_bytes = match mint_key_package(mls, crypto_store) {
        Ok(kp) => kp,
        Err(e) => { hollow_log!("[HOLLOW-MLS] server-group KP gen failed: {e}"); return false; }
    };
    let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
    let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
        server_id: server_id.to_string(),
        key_package: kp_b64,
        channel_id: None,
    }).unwrap_or_default();
    let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, owner, data);
    if sent > 0 {
        hollow_log!("[HOLLOW-MLS] Sent server-group KeyPackage to owner {owner} for {server_id} ({sent} device(s))");
    }
    sent > 0
}

/// Ask for a leaf in a server group we hold no copy of: the owner when online, our
/// own siblings when the owner is our identity (they re-add a sibling), else the
/// lowest online member. True when a KeyPackage reached a device.
#[allow(clippy::too_many_arguments)]
pub(crate) fn request_server_leaf(
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    local_master: &str,
    local_device: &str,
) -> bool {
    let owner_is_us = server.members.keys().any(|m| {
        super::resolver::same_identity(m, local_master)
            && server.roles.get(m).is_some_and(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
    });
    let targets: Vec<String> = if owner_is_us {
        online_devices_for(ws_room_peers, local_master).into_iter().filter(|d| d != local_device).collect()
    } else {
        server_bootstrap_target(server, local_master, ws_room_peers)
            .filter(|t| !super::resolver::same_identity(t, local_master))
            .map(|t| online_devices_for(ws_room_peers, &t))
            .unwrap_or_default()
    };
    if targets.is_empty() {
        return false;
    }
    let kp_bytes = match mint_key_package(mls, crypto_store) {
        Ok(kp) => kp,
        Err(e) => { hollow_log!("[HOLLOW-MLS] server-group KP gen failed: {e}"); return false; }
    };
    let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
        server_id: server_id.to_string(),
        key_package: base64::engine::general_purpose::STANDARD.encode(&kp_bytes),
        channel_id: None,
    }).unwrap_or_default();
    let mut sent = 0;
    for dev in &targets {
        if let Some(room) = ws_room_for_peer(ws_room_peers, dev) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: room,
                target_peer: dev.clone(),
                data: data.clone(),
            });
            sent += 1;
        }
    }
    if sent > 0 {
        hollow_log!("[HOLLOW-MLS] Asked {targets:?} for a leaf in {server_id}");
    }
    sent > 0
}

/// Reconcile per-channel MLS subgroup membership against the CRDT after a
/// lifecycle event (role or visibility change, channel create/delete, kick, ban,
/// leave), for every restricted channel or just `only_channel`.
///
/// REMOVALS run directly (we hold the leaf credentials) and drop all of a
/// human's leaves at once. ADDITIONS are pull-based, because we lack the new
/// member's KeyPackage. Only the subgroup coordinator acts, idempotently under
/// races; a channel that stops being restricted is torn down elsewhere.
#[allow(clippy::too_many_arguments)]
pub(crate) fn reconcile_subgroups_for_server(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_mls_key_packages: &mut HashMap<String, Vec<(String, Vec<u8>)>>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    local_peer: &str,
    only_channel: Option<&str>,
) {
    let channels: Vec<String> = match only_channel {
        Some(cid) if server.channel_uses_subgroup(cid) => vec![cid.to_string()],
        Some(_) => return, // not (or no longer) a restricted channel
        None => server.subgroup_channel_ids(),
    };

    for cid in channels {
        let group_key = crate::crypto::subgroup_id(server_id, &cid);
        // Prefer the OWNER as the single subgroup coordinator when online: it ALWAYS
        // qualifies and is agreed from the CRDT, whereas the leaf-holder heuristic
        // below disagrees across nodes, so two masters could fork the group under one
        // id. Owner offline: the lowest online master who qualifies AND holds a leaf.
        let coord = {
            let owner = server.members.keys().find(|m| {
                server.roles.get(*m)
                    .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                    .unwrap_or(false)
            });
            let owner_online = owner.is_some_and(|o| {
                o.as_str() == local_peer || peer_is_reachable(ws_room_peers, o)
            });
            if owner_online {
                owner.cloned()
            } else {
                let leaf_masters: std::collections::HashSet<String> = mls.group_members(&group_key)
                    .iter().map(|l| super::resolver::resolve(l)).collect();
                let mut holders: Vec<String> = server.members.keys()
                    .filter(|mm| server.can_see_channel(mm, &cid))
                    .filter(|mm| mm.as_str() == local_peer || peer_is_reachable(ws_room_peers, mm))
                    .filter(|mm| leaf_masters.contains(*mm))
                    .cloned()
                    .collect();
                holders.sort();
                holders.into_iter().next()
                    .or_else(|| elect_subgroup_coordinator(server, &cid, local_peer, ws_room_peers))
            }
        };
        if coord.as_deref() != Some(local_peer) { continue; }

        // The coordinator must hold the group to commit. Create it lazily (we are
        // its founding member). If we ourselves don't qualify we can't be coord.
        if !server.can_see_channel(local_peer, &cid) { continue; }
        if !mls.has_group(&group_key) {
            if let Err(e) = mls.create_group(&group_key) {
                hollow_log!("[HOLLOW-MLS] reconcile: failed to create subgroup {group_key}: {e}");
                continue;
            }
            hollow_log!("[HOLLOW-MLS] reconcile: created subgroup {group_key}");
        }

        // REMOVALS: leaves whose certified master is gone or no longer qualifies, and
        // leaves that prove no identity at all.
        let leaves = mls.group_leaves(&group_key);
        let rules = super::mls_authority::GroupRules::Server { state: server, channel: Some(&cid) };
        for leaf in super::mls_authority::stale_leaves(&leaves, local_peer, &rules) {
            hollow_log!("[HOLLOW-MLS] reconcile: queue remove {leaf} from {group_key} (no longer qualifies)");
            pending_mls_removals.entry(group_key.clone()).or_default().push(leaf);
        }

        // ADDITIONS: online qualifying members with no bound leaf yet. We cannot add
        // without their KeyPackage, so pull it; dedup against this round's queue.
        let current_leaf_masters: std::collections::HashSet<String> = leaves
            .iter()
            .filter_map(|l| l.bound().map(|b| b.master.clone()))
            .collect();
        let already_queued: std::collections::HashSet<String> = pending_mls_key_packages
            .get(&group_key)
            .map(|v| v.iter().map(|(p, _)| super::resolver::resolve(p)).collect())
            .unwrap_or_default();
        for member in server.members.keys() {
            if super::resolver::same_identity(member, local_peer) { continue; }
            if !server.can_see_channel(member, &cid) { continue; }
            if current_leaf_masters.contains(member) { continue; }
            if already_queued.contains(member) { continue; }
            if !peer_is_reachable(ws_room_peers, member) { continue; } // offline → pulls itself later
            let data = serde_json::to_vec(&HavenMessage::MlsKeyPackageRequest {
                server_id: server_id.to_string(),
                channel_id: Some(cid.clone()),
            }).unwrap_or_default();
            let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, member, data);
            if sent > 0 {
                hollow_log!("[HOLLOW-MLS] reconcile: requested KeyPackage from {member} for {group_key} ({sent} device(s))");
            }
        }
    }
}

/// Remove every leaf of `target_master`'s identity from ALL of a server's
/// per-channel MLS subgroups, one commit per subgroup. Used by kick/ban/leave so
/// a removed human loses access to restricted channels, not just the server-wide
/// group. No-op for subgroups we do not hold or where the target has no leaf.
pub(crate) async fn remove_identity_from_subgroups(
    mls: &mut MlsManager,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    crypto_store: &CryptoStore,
    server: &crate::crdt::server_state::ServerState,
    server_id: &str,
    target_master: &str,
) {
    // credential ids of the removed human = {master} ∪ all known devices.
    let id_set: Vec<String> = {
        let mut v = super::resolver::devices_for(target_master);
        v.push(target_master.to_string());
        v
    };
    for cid in server.subgroup_channel_ids() {
        let group_key = crate::crypto::subgroup_id(server_id, &cid);
        if !mls.has_group(&group_key) { continue; }
        let present: Vec<&str> = {
            let leaves = mls.group_members(&group_key);
            id_set.iter()
                .filter(|c| leaves.iter().any(|l| l == *c))
                .map(|s| s.as_str())
                .collect()
        };
        if present.is_empty() { continue; }

        match mls.remove_identity_leaves(&group_key, &present) {
            Ok(commit_bytes) => {
                if let Err(e) = mls.merge_pending_commit(&group_key) {
                    hollow_log!("[HOLLOW-MLS] subgroup remove merge failed for {group_key}: {e}");
                    continue;
                }
                persist_mls_state(mls, crypto_store);
                if let Ok(sframe_key) = mls.export_secret(&group_key, "sframe", b"", 32) {
                    let epoch = mls.epoch(&group_key).unwrap_or(0);
                    let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                        server_id: server_id.to_string(), epoch, sframe_key,
                        channel_id: Some(cid.clone()),
                    }).await;
                }
                let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit_bytes);
                // Tier 1: single room broadcast (covers qualifying members AND our
                // siblings); non-qualifiers ignore it via has_group on receive.
                let commit_epoch = mls.epoch(&group_key).ok();
                broadcast_mls_commit(
                    mls, ws_cmd_tx, server_id, Some(cid.clone()), commit_b64,
                    commit_epoch,
                );
                hollow_log!("[HOLLOW-MLS] Removed {target_master}'s leaves from subgroup {group_key}");
            }
            Err(e) => hollow_log!("[HOLLOW-MLS] subgroup remove failed for {group_key}: {e}"),
        }
    }
}

/// Find a WS room containing the given peer.
pub(crate) fn ws_room_for_peer(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Option<String> {
    for (room, peers) in ws_room_peers {
        if peers.contains(peer_str) {
            return Some(room.clone());
        }
    }
    None
}

/// Where a frame for `peer_str` goes: a room that shows it to us, else the room a peer
/// the relay hides from us last spoke from (a guest reading public channels). Never
/// a sign that the peer is online: only sends use it.
pub(crate) fn send_room_for_peer(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Option<String> {
    ws_room_for_peer(ws_room_peers, peer_str).or_else(|| super::door_room::heard_room(peer_str))
}

/// MLS-encrypt an envelope and broadcast to the server room via WS relay: one
/// encrypt, one send, the relay fans out. `Err(reason)` lets the caller fall back.
pub(crate) fn send_mls_broadcast(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    send_mls_broadcast_in(mls, ws_cmd_tx, server_id, None, envelope, crypto_store)
}

/// [`send_mls_broadcast`] under `channel`'s subgroup when `Some`: still one frame to
/// the whole room, which only the subgroup's members can read.
pub(crate) fn send_mls_broadcast_in(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    channel: Option<&str>,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    let group_key = match channel {
        Some(cid) => crate::crypto::subgroup_id(server_id, cid),
        None => server_id.to_string(),
    };
    let json = serde_json::to_string(envelope).map_err(|e| format!("serialize: {e}"))?;
    let ciphertext = mls.encrypt(&group_key, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    // MLS rule: persist on encrypt. A regressed SEND ratchet re-uses generations
    // receivers already consumed, so every live message then fails with
    // SecretTreeError(TooDistantInThePast) on the other side. A 2s debounce here
    // wedged live channel messages from mobile senders exactly that way; do not
    // retry it.
    persist_mls_state(mls, crypto_store);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
        channel_id: channel.map(str::to_string),
    };
    let data = serde_json::to_vec(&msg).map_err(|e| format!("serialize msg: {e}"))?;
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data,
    });
    Ok(())
}

/// Whether an envelope decrypted under `server_id`'s group may be acted on;
/// `group_channel` is the subgroup's channel, `None` for the server-wide group, and
/// `restricted` says whether a channel uses a subgroup in our state. Decryption
/// proves only that a member of THAT group sent it, so the envelope must name that
/// server, a subgroup carries only its own channel, and a restricted channel's
/// message content arrives only through its subgroup. DM-shaped envelopes never
/// ride a group.
pub(crate) fn mls_envelope_fits_group(
    envelope: &MessageEnvelope,
    server_id: &str,
    group_channel: Option<&str>,
    restricted: impl Fn(&str) -> bool,
) -> bool {
    match envelope.place() {
        EnvelopePlace::Anywhere => true,
        EnvelopePlace::Direct => false,
        EnvelopePlace::Server { sid, cid } => {
            sid == server_id
                && match (group_channel, cid) {
                    (Some(group_cid), cid) => cid == Some(group_cid),
                    (None, Some(cid)) => !(envelope.is_channel_content() && restricted(cid)),
                    (None, None) => true,
                }
        }
    }
}

/// MLS-encrypt an envelope and broadcast to peers subscribed to `topic`; others
/// pick it up when they sync the channel.
///
/// Returns the serialized wire bytes so callers can re-deliver the SAME
/// ciphertext to offline members over 0x09: an MLS application message is
/// decryptable by every member, so one encryption serves both paths.
///
/// `use_subgroup` encrypts under the per-channel subgroup and stamps
/// `channel_id` so the receiver decrypts under the same one. `ring` is the relay
/// topic (`ring_auth::topic`).
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_mls_broadcast_topic(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    channel: &str,
    ring: &str,
    use_subgroup: bool,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<Vec<u8>, String> {
    let group_key = if use_subgroup {
        crate::crypto::subgroup_id(server_id, channel)
    } else {
        server_id.to_string()
    };
    let channel_id = if use_subgroup { Some(channel.to_string()) } else { None };
    let json = serde_json::to_string(envelope).map_err(|e| format!("serialize: {e}"))?;
    let ciphertext = mls.encrypt(&group_key, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    // MLS rule: persist on encrypt — send-side ratchet state must never be
    // debounced (see send_mls_broadcast for the full why).
    persist_mls_state(mls, crypto_store);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
        channel_id,
    };
    let data = serde_json::to_vec(&msg).map_err(|e| format!("serialize msg: {e}"))?;
    hollow_log!("[HOLLOW-TOPIC] Broadcast room={server_id} topic={ring} group={group_key} ({} bytes)", data.len());
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server_id.to_string(),
        topic: ring.to_string(),
        data: data.clone(),
    });
    Ok(data)
}

/// MLS-encrypt a targeted envelope and broadcast to the server room.
/// All members decrypt (keeping ratchets in sync) but only `target_peer` acts.
/// Retained for backward compatibility — new code uses Olm+SendDirect instead.
#[allow(dead_code)]
pub(crate) fn send_mls_to_peer(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    target_peer: &str,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    let mut json_value = serde_json::to_value(envelope).map_err(|e| format!("serialize: {e}"))?;
    if let Some(obj) = json_value.as_object_mut() {
        obj.insert("target".to_string(), serde_json::Value::String(target_peer.to_string()));
    }
    let json = serde_json::to_string(&json_value).map_err(|e| format!("re-serialize: {e}"))?;
    let ciphertext = mls.encrypt(server_id, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    let msg = HavenMessage::MlsChannelMessage {
        server_id: server_id.to_string(),
        body: body_b64,
        channel_id: None,
    };
    let data = serde_json::to_vec(&msg).map_err(|e| format!("serialize msg: {e}"))?;
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data,
    });
    Ok(())
}

/// Encrypt and send a message to a peer via WS relay.
/// Returns `true` on success, `false` if encryption failed.
pub(crate) async fn send_encrypted_message(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> bool {
    match super::olm_lane::encrypt_in_turn(olm, peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);

            if msg_type == 0 {
                hollow_log!("[HOLLOW-CRYPTO] Sending PreKey (type 0) to {peer_id_str}");
            }

            let haven_msg = encrypted_frame(olm, msg_type, &ciphertext);

            if let Some(room) = send_room_for_peer(ws_room_peers, peer_id_str) {
                let json = serde_json::to_string(&haven_msg).unwrap_or_default();
                let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                    room_code: room,
                    target_peer: peer_id_str.to_string(),
                    data: json.into_bytes(),
                });
                true
            } else {
                hollow_log!("[HOLLOW-CRYPTO] Encrypted message for {peer_id_str} but peer unreachable — not delivered");
                false
            }
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Like [`send_encrypted_message`], but sends into an EXPLICIT room instead of a
/// `ws_room_for_peer` first-match lookup.
///
/// A recipient co-present in several of our rooms makes the first match a coin
/// toss, and a room they have since left buffers the frame against one they
/// never rejoin. DM traffic routes by the deterministic `dm_room_code`.
pub(crate) async fn send_encrypted_message_in_room(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    room_code: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match super::olm_lane::encrypt_in_turn(olm, peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let haven_msg = encrypted_frame(olm, msg_type, &ciphertext);
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: room_code.to_string(),
                target_peer: peer_id_str.to_string(),
                data: json.into_bytes(),
            });
            true
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Like [`send_encrypted_message`], but routes through `SendDirectImage` (0x08)
/// so the relay buffers it under the per-peer IMAGE cap when the recipient is
/// offline, letting the FCM fetch node render a small inlined image.
///
/// CRITICAL: the caller passes the explicit `dm_room`, NOT a `ws_room_for_peer`
/// lookup. An OFFLINE peer is in no known room, so a lookup returns None and the
/// message is dropped; the deterministic DM room is what the relay buffers on.
pub(crate) async fn send_encrypted_image_to_peer(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    dm_room: String,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match super::olm_lane::encrypt_in_turn(olm, peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
            let haven_msg = encrypted_frame(olm, msg_type, &ciphertext);
            let json = serde_json::to_string(&haven_msg).unwrap_or_default();
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirectImage {
                room_code: dm_room,
                target_peer: peer_id_str.to_string(),
                data: json.into_bytes(),
            });
            true
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Send an Olm-encrypted TEXT DM to an explicit DM room (0x04), skipping the
/// reachability check [`send_encrypted_message`] does.
///
/// Used for the CAPTION of an offline image DM: the recipient is in no known
/// room, but the relay still buffers a 0x04 frame under the TEXT cap. The
/// caption shares its `message_id` with the inlined-image FileHeader so the
/// fetch node merges them.
pub(crate) async fn send_encrypted_text_to_peer(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    dm_room: String,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    send_encrypted_message_in_room(
        olm, crypto_store, peer_id_str, &dm_room, text, event_tx, ws_cmd_tx,
    )
    .await
}

/// Persist both account and session state to DB (fire-and-forget).
/// Use for session creation/destruction events where account state changes.
pub(crate) fn persist_crypto_state(olm: &OlmManager, crypto_store: &CryptoStore, peer_id: &str) {
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }
    if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {
        crypto_store.save_session(peer_id.to_string(), session_json);
    }
}

/// Persist only the session ratchet state (skip account pickle).
/// Use for per-message encrypt/decrypt where only the ratchet advances.
pub(crate) fn persist_olm_session(olm: &OlmManager, crypto_store: &CryptoStore, peer_id: &str) {
    if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {
        crypto_store.save_session(peer_id.to_string(), session_json);
    }
}

/// Send a HavenMessage to a specific peer via the WS relay.
/// Silently drops the message if the peer is not reachable.
pub(crate) fn send_message_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
    msg: HavenMessage,
) {
    if let Some(room) = send_room_for_peer(ws_room_peers, peer_str) {
        let json = serde_json::to_string(&msg).unwrap_or_default();
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
            room_code: room,
            target_peer: peer_str.to_string(),
            data: json.into_bytes(),
        });
    } else {
        // Peer unreachable: the message is dropped (upper layers own retry), but NEVER
        // silently. This branch is where "call or message to a stale-presence peer
        // vanished with no trace" dies, and without this line the logs hold zero
        // evidence. Externally-tagged serde: the variant name is the object's one key.
        let kind = serde_json::to_value(&msg)
            .ok()
            .and_then(|v| match v {
                serde_json::Value::Object(o) => o.keys().next().cloned(),
                serde_json::Value::String(s) => Some(s),
                _ => None,
            })
            .unwrap_or_else(|| "?".into());
        hollow_log!("[HOLLOW-SEND] DROPPED {kind} to {peer_str} — not in any WS room");
    }
}

/// Like [`send_message_to_peer`] but routes into an EXPLICIT room (the
/// deterministic `dm_room_code`), not a first-match lookup: a recipient device
/// co-present in several rooms could otherwise have the frame buffered against
/// one it never rejoins. Every device of the recipient is in the DM room.
pub(crate) fn send_message_to_peer_in_room(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    room_code: &str,
    peer_str: &str,
    msg: HavenMessage,
) {
    let json = serde_json::to_string(&msg).unwrap_or_default();
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
        room_code: room_code.to_string(),
        target_peer: peer_str.to_string(),
        data: json.into_bytes(),
    });
}

/// Send pre-serialized bytes to a specific peer via the WS relay.
/// Use in broadcast loops to serialize once and send the same bytes to each peer.
pub(crate) fn send_raw_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
    data: Vec<u8>,
) {
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
            room_code: room,
            target_peer: peer_str.to_string(),
            data,
        });
    }
}

/// Broadcast an MLS Commit to the ENTIRE server WS room in ONE 0x03 frame.
///
/// Commit bytes are byte-identical for every recipient, so the per-device
/// `SendDirect` loop was O(N) coordinator upload per membership change.
/// Over-delivery is harmless: receivers without the group ignore it, receivers
/// already at the commit's epoch skip it, and a removed identity is refused by
/// the MlsKeyPackage non-member check.
pub(crate) fn broadcast_mls_commit(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    channel_id: Option<String>,
    commit_b64: String,
    epoch: Option<u64>,
) {
    // Feed the catch-up ring FIRST: a 0x03 broadcast is unrecoverable for any
    // member not in the room at this instant, and the cache is what lets us replay
    // it later instead of repairing with more commits.
    if let Some(epoch) = epoch {
        let group_key = match &channel_id {
            Some(cid) => crate::crypto::subgroup_id(server_id, cid),
            None => server_id.to_string(),
        };
        mls.cache_commit(&group_key, epoch, commit_b64.clone());
    }
    let data = serde_json::to_vec(&HavenMessage::MlsCommit {
        server_id: server_id.to_string(),
        commit: commit_b64,
        channel_id,
        epoch,
    })
    .unwrap_or_default();
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
        room_code: server_id.to_string(),
        data,
    });
}

/// Outcome of applying one MlsCommit frame (broadcast or catch-up replay).
pub(crate) enum CommitApplyOutcome {
    /// Processed and merged (epoch advanced, `MlsEpochChanged` emitted) — or
    /// merged-then-evicted with no recovery owed (a kick or a ban).
    Applied,
    /// Processed and merged, and the commit removed OUR OWN leaf while we are
    /// still a member: a repair whose Welcome is on its way. The group is dropped
    /// and the throttle stamped, and the caller holds the Welcome grace.
    Evicted,
    /// Skipped: we're already at/past the frame's epoch.
    Skipped,
    /// We don't hold this group — nothing to do.
    NoGroup,
    /// Kept for a retry: our CRDT view may be behind the committer's.
    Held,
    /// Breaks a rule outright; discarded.
    Refused,
    /// Did not process. The group stays as it was and an epoch probe asks whether
    /// we are behind: anyone can send a frame that fails.
    Failed,
}

/// How long an evicted device waits for the repair's Welcome before asking for a
/// leaf itself. The removal can reach it a moment before the Welcome that puts it
/// back, and asking then mints a KeyPackage the next tick turns into another
/// repair. Two batch intervals plus slack.
pub(crate) const MLS_WELCOME_GRACE: std::time::Duration = std::time::Duration::from_secs(6);

/// Apply one MlsCommit frame. Shared by the `MlsCommit` broadcast arm and the
/// `MlsCommitCatchup` replay loop so both get identical validation and recovery
/// BY CONSTRUCTION. `frame_sender` is the device the relay says sent the frame.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_mls_commit_frame(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    epoch_hint_cooldown: &mut HashMap<String, std::time::Instant>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer_str: &str,
    frame_sender: &str,
    server_id: &str,
    commit_b64: &str,
    channel_id: &Option<String>,
    wire_epoch: Option<u64>,
) -> CommitApplyOutcome {
    let group_key = match channel_id {
        Some(cid) => crate::crypto::subgroup_id(server_id, cid),
        None => server_id.to_string(),
    };

    // We may receive a Commit for a subgroup we're not part of (we don't
    // qualify for the channel) — ignore it rather than self-drop.
    if !mls_mgr.has_group(&group_key) {
        hollow_log!("[HOLLOW-MLS] Ignoring Commit for group we don't hold: {group_key}");
        return CommitApplyOutcome::NoGroup;
    }
    // Epoch guard: commits arrive as a room broadcast, so they also reach fresh
    // joiners already at the post-commit epoch and duplicate deliveries.
    let already_applied = wire_epoch
        .is_some_and(|we| mls_mgr.epoch(&group_key).is_ok_and(|own| own >= we));
    if already_applied {
        let we = wire_epoch.unwrap_or(0);
        hollow_log!("[HOLLOW-MLS] Skipping commit for {group_key} at epoch {we} — already at/past it");
        return CommitApplyOutcome::Skipped;
    }
    let commit_bytes = match base64::engine::general_purpose::STANDARD.decode(commit_b64) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[HOLLOW-MLS] Base64 decode Commit failed: {e}");
            return CommitApplyOutcome::Failed;
        }
    };

    let meeting_host = mls_mgr.pinned_committer(&group_key).map(str::to_string);
    let mut committer = None;
    let judged = mls_mgr.process_commit_judged(&group_key, &commit_bytes, |facts| {
        committer = facts.committer.as_ref().and_then(crate::crypto::LeafView::bound).cloned();
        super::mls_authority::judge_commit(
            server_states, server_id, channel_id.as_deref(), meeting_host.as_deref(), facts,
        )
    });
    match judged {
        Ok(crate::crypto::Verdict::Accept) => {
            // Feed the catch-up ring: whoever missed this broadcast can be
            // served the exact frame later (join-order SFrame race fix).
            let cached_epoch = wire_epoch.or_else(|| mls_mgr.epoch(&group_key).ok());
            if let Some(cached_epoch) = cached_epoch {
                mls_mgr.cache_commit(&group_key, cached_epoch, commit_b64.to_string());
            }
            after_commit_merged(
                mls_mgr, crypto_store, server_states, mls_bootstrap_requested, event_tx,
                local_peer_str, server_id, &group_key, channel_id,
            ).await
        }
        Ok(crate::crypto::Verdict::Hold(reason)) => {
            // Processing spent the commit's key, so persist the ratchet as for any receive.
            persist_mls_state(mls_mgr, crypto_store);
            hollow_log!("[HOLLOW-MLS] Holding commit for {group_key} from {frame_sender}: {reason}");
            // The committer's view is ahead of ours: pull its ops so the batch tick's
            // retry can pass.
            let state = server_states.get(server_id);
            if let (Some(state), Some((partner, _))) = (state, mls_sync_partner(state, committer.as_ref(), Some(frame_sender)))
                && let Ok(sv) = serde_json::to_string(&crate::crdt::sync::StateVector::from_server_state(state))
            {
                // No epoch hint, we already hold its commit.
                super::olm_lane::carry(
                    ws_cmd_tx, partner, None,
                    &HavenMessage::SyncRequest {
                        server_id: server_id.to_string(),
                        state_vector_json: sv,
                        mls_epoch: None,
                    },
                    super::olm_lane::NoSession::Queue,
                );
            }
            CommitApplyOutcome::Held
        }
        Ok(crate::crypto::Verdict::Refuse(reason)) => {
            persist_mls_state(mls_mgr, crypto_store);
            hollow_log!("[HOLLOW-SECURITY] REFUSED commit for {group_key} from {frame_sender}: {reason}");
            CommitApplyOutcome::Refused
        }
        Err(e) => {
            hollow_log!("[HOLLOW-MLS] Failed to process commit for {group_key} from {frame_sender}: {e}");
            if let Some(state) = server_states.get(server_id) {
                send_epoch_probe(
                    mls_mgr, ws_cmd_tx, ws_room_peers, state, server_id,
                    channel_id.as_deref(), local_peer_str, epoch_hint_cooldown,
                );
            }
            CommitApplyOutcome::Failed
        }
    }
}

/// Everything owed after a received commit merged: persist, and either handle our
/// own eviction or emit the new epoch's SFrame key.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn after_commit_merged(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer_str: &str,
    server_id: &str,
    group_key: &str,
    channel_id: &Option<String>,
) -> CommitApplyOutcome {
    persist_mls_state(mls_mgr, crypto_store);
    hollow_log!("[HOLLOW-MLS] Processed commit for {group_key}");

    // EVICTION CHECK: a commit that removed OUR OWN leaf merges cleanly but leaves
    // the group INACTIVE, so export and encrypt fail forever while has_group stays
    // true, silently wedging SFrame. Still a CRDT member means a repair, so drop the
    // dead group and let the Welcome re-key us.
    if !mls_mgr.is_active(group_key) {
        hollow_log!("[HOLLOW-MLS] Commit EVICTED us from {group_key} — dropping inactive group");
        mls_mgr.remove_group(group_key);
        persist_mls_state(mls_mgr, crypto_store);
        let still_member = server_states.get(server_id).is_some_and(|s| {
            s.members.keys().any(|m| super::resolver::same_identity(m, local_peer_str))
        });
        if !still_member {
            // A kick or a ban. There is no Welcome coming and we are not
            // entitled to one; the dropped group is the whole response.
            return CommitApplyOutcome::Applied;
        }
        // A repair. Its Welcome is on its way, so asking for a leaf here answers a
        // question already being answered and restarts the loop. Stamp the throttle
        // WITHOUT sending, which alone silences the opportunistic sends.
        mls_bootstrap_requested.insert(group_key.to_string(), std::time::Instant::now());
        hollow_log!(
            "[HOLLOW-MLS] Commit evicted us from {group_key}; holding {}s for a Welcome before re-bootstrapping",
            MLS_WELCOME_GRACE.as_secs(),
        );
        return CommitApplyOutcome::Evicted;
    }

    // Emit epoch change for SFrame key rotation. For a subgroup
    // (restricted voice channel), route it to that channel's cryptor.
    if let Ok(sframe_key) = mls_mgr.export_secret(group_key, "sframe", b"", 32) {
        let epoch = mls_mgr.epoch(group_key).unwrap_or(0);
        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
            server_id: server_id.to_string(), epoch, sframe_key,
            channel_id: channel_id.clone(),
        }).await;
    }
    CommitApplyOutcome::Applied
}

/// Rebind our own leaf wherever it still predates bound leaves. As the group
/// authority we rebind in place, one commit cached for catch-up; otherwise we hand
/// the authority a fresh KeyPackage and its repair replaces our leaf. Throttled per
/// group by the bootstrap stamp, which also makes the repair's Welcome asked-for.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn rebind_unbound_leaves(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    local_peer_str: &str,
) {
    for group_key in mls_mgr.unbound_own_groups() {
        if mls_bootstrap_requested
            .get(&group_key)
            .is_some_and(|t| t.elapsed() < super::swarm::MLS_BOOTSTRAP_TIMEOUT)
        {
            continue;
        }
        let (server_id, channel_id) = crate::crypto::split_group_key(&group_key);
        let Some(state) = server_states.get(&server_id) else { continue };
        let authority = group_authority(state, channel_id.as_deref(), local_peer_str, ws_room_peers);
        let we_are_authority =
            authority.as_deref().is_some_and(|a| super::resolver::same_identity(a, local_peer_str));

        if we_are_authority && mls_mgr.can_rebind_in_place(&group_key) {
            let commit = match mls_mgr.rebind_own_leaf(&group_key) {
                Ok(commit) => commit,
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Rebinding our leaf in {group_key} failed: {e}");
                    continue;
                }
            };
            if let Err(e) = mls_mgr.merge_pending_commit(&group_key) {
                hollow_log!("[HOLLOW-MLS] Merging our rebind in {group_key} failed: {e}");
                continue;
            }
            mls_mgr.drop_unused_legacy();
            persist_mls_state(mls_mgr, crypto_store);
            if let Ok(sframe_key) = mls_mgr.export_secret(&group_key, "sframe", b"", 32) {
                let epoch = mls_mgr.epoch(&group_key).unwrap_or(0);
                let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                    server_id: server_id.clone(), epoch, sframe_key,
                    channel_id: channel_id.clone(),
                }).await;
            }
            let epoch = mls_mgr.epoch(&group_key).ok();
            let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit);
            broadcast_mls_commit(mls_mgr, ws_cmd_tx, &server_id, channel_id.clone(), commit_b64, epoch);
            hollow_log!("[HOLLOW-MLS] Rebound our leaf in {group_key} in place");
            continue;
        }

        let target = if we_are_authority {
            epoch_catchup_responder(state, channel_id.as_deref(), local_peer_str, ws_room_peers, local_peer_str)
        } else {
            authority
        };
        let Some(target) = target else { continue };
        let Ok(kp_bytes) = mint_key_package(mls_mgr, crypto_store) else { continue };
        let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
            server_id: server_id.clone(),
            key_package: base64::engine::general_purpose::STANDARD.encode(&kp_bytes),
            channel_id: channel_id.clone(),
        })
        .unwrap_or_default();
        if send_raw_to_identity(ws_cmd_tx, ws_room_peers, &target, data) > 0 {
            mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
            hollow_log!("[HOLLOW-MLS] Asked {target} to repair our unbound leaf in {group_key}");
        }
    }
}

/// Per-(group, peer) cooldown for epoch-hint service and self-probes — bounds
/// hint-triggered work against floods and request loops.
pub(crate) const EPOCH_HINT_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(10);

/// The authority for an MLS group key: the subgroup coordinator for a restricted
/// channel; for the server-wide group the OWNER when online-or-us, else the
/// lowest online master so epoch catch-up still has a live responder. May return
/// US, so callers same_identity-check for the am-I-authority decision.
fn group_authority(
    state: &crate::crdt::server_state::ServerState,
    channel_id: Option<&str>,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    match channel_id {
        Some(cid) => elect_subgroup_coordinator(state, cid, local_peer, ws_room_peers),
        None => {
            let owner = state.members.keys().find(|m| {
                state.roles.get(*m)
                    .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                    .unwrap_or(false)
            });
            if let Some(owner) = owner
                && (owner.as_str() == local_peer || peer_is_reachable(ws_room_peers, owner))
            {
                return Some(owner.clone());
            }
            let members: Vec<String> = state.members.keys().cloned().collect();
            elect_coordinator(&members, local_peer, ws_room_peers)
        }
    }
}

/// Whether `requester` may repair our leaf in a group we hold: the owner, the member
/// our own election names to answer our catch-up, or the subgroup's coordinator. A
/// KeyPackage handed to anyone else could Welcome us into a group of their making.
pub(crate) fn may_repair_our_leaf(
    state: &crate::crdt::server_state::ServerState,
    channel_id: Option<&str>,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    requester: &str,
) -> bool {
    let is_owner = state.roles.get(requester)
        .is_some_and(|r| *r.read() == crate::crdt::operations::MemberRole::Owner);
    let named = |elected: Option<String>| elected.is_some_and(|e| super::resolver::same_identity(&e, requester));
    is_owner
        || named(epoch_catchup_responder(state, channel_id, local_peer, ws_room_peers, local_peer))
        || channel_id.is_some_and(|cid| named(elect_subgroup_coordinator(state, cid, local_peer, ws_room_peers)))
}

/// Who answers an epoch catch-up for a group, given that `behind` is the peer
/// that needs one.
///
/// Normally [`group_authority`], but the authority CANNOT SERVE ITSELF, and for
/// the server group the authority is the owner: an owner that came back stale
/// deadlocked, its own probe bailing ("our epoch defines the group") while the
/// member holding the newer epoch refused to serve ("not the authority").
///
/// Excluding the peer that is behind fixes it symmetrically: asker and answerer
/// run the SAME election and land on one responder. Owner preference stays on
/// the COMMITTER (`feedback_owner_coordinator_mls_recovery`).
fn epoch_catchup_responder(
    state: &crate::crdt::server_state::ServerState,
    channel_id: Option<&str>,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    behind: &str,
) -> Option<String> {
    let authority = group_authority(state, channel_id, local_peer, ws_room_peers);
    if let Some(a) = &authority
        && !super::resolver::same_identity(a, behind)
    {
        return authority;
    }
    // The authority IS the peer that is behind. Deterministic fallback: the lowest
    // online master among the rest (subgroup: among those who qualify).
    let candidates: Vec<String> = state
        .members
        .keys()
        .filter(|m| !super::resolver::same_identity(m, behind))
        .filter(|m| match channel_id {
            Some(cid) => state.can_see_channel(m, cid),
            None => true,
        })
        .cloned()
        .collect();
    // `elect_coordinator` always counts US as a candidate, so filter again:
    // when WE are the one behind the answer must never be ourselves.
    elect_coordinator(&candidates, local_peer, ws_room_peers)
        .filter(|c| !super::resolver::same_identity(c, behind))
}

/// React to a peer's MLS epoch hint (`SyncRequest.mls_epoch` / `MlsEpochProbe`),
/// the detector for present-but-stale groups. They are otherwise invisible:
/// commits ride an unbuffered 0x03 broadcast, every other recovery trigger keys
/// on `has_group` or a missing leaf, and a voice-only channel has no ciphertext
/// to fail a decrypt.
///
///  * theirs < ours and WE are the responder: serve `MlsCommitCatchup` from the
///    commit cache, falling back to a repair when it cannot bridge.
///  * equal, but their epoch digest differs from ours: they hold a fork, repair.
///  * theirs > ours: probe the authority ourselves. Non-destructive BY DESIGN,
///    because an unauthenticated plaintext hint must never make us drop a group.
///  * otherwise, or no group / conference / non-member: no-op.
///
/// A repair only asks the member for a fresh KeyPackage; the removal of its old
/// leaf rides the same commit as the re-add, which receivers require.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_epoch_hint(
    mls_mgr: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    epoch_hint_cooldown: &mut HashMap<String, std::time::Instant>,
    server_id: &str,
    channel_id: Option<&str>,
    their_epoch: u64,
    their_epoch_auth: Option<&str>,
    from_peer: &str,
    local_peer_str: &str,
    // True when this arrived as an `MlsEpochProbe` addressed to us, so we answer it
    // ourselves. Re-electing on a direct probe re-opens the deadlock from the other
    // side: the asker picks from ITS view, and a returning owner's CRDT is behind.
    direct_probe: bool,
) {
    // Conferences re-emit only (heal rule): admission is Welcome-based, and a
    // conf group must never be dragged through hint-driven repair.
    if super::conference::is_conference_sid(server_id) {
        return;
    }
    let group_key = match channel_id {
        Some(cid) => crate::crypto::subgroup_id(server_id, cid),
        None => server_id.to_string(),
    };
    let Some(state) = server_states.get(server_id) else { return };
    if !mls_mgr.has_group(&group_key) {
        return; // group-less recovery is owned by the existing bootstrap paths
    }
    let Ok(own_epoch) = mls_mgr.epoch(&group_key) else { return };

    // Membership gate: only members of this server get epoch SERVICE.
    if !state.members.keys().any(|m| super::resolver::same_identity(m, from_peer)) {
        hollow_log!("[HOLLOW-MLS] No epoch service for non-member {from_peer} for {group_key}");
        // ...but their hint may be the only evidence that WE are behind, and acting on
        // it costs one throttled probe to a peer we ALREADY trust. This is the
        // reconnect race: dropping it discarded the only heal trigger.
        if their_epoch > own_epoch {
            send_epoch_probe(
                mls_mgr, ws_cmd_tx, ws_room_peers, state,
                server_id, channel_id, local_peer_str, epoch_hint_cooldown,
            );
        }
        return;
    }

    let forked = their_epoch == own_epoch
        && their_epoch_auth.is_some_and(|theirs| mls_mgr.epoch_auth_digest(&group_key).as_deref() != Some(theirs));
    if their_epoch < own_epoch || forked {
        // ONE responder, no room-wide echo, elected with the peer that is behind
        // excluded so a stale AUTHORITY still gets an answer. A direct probe skips it.
        let responder = epoch_catchup_responder(state, channel_id, local_peer_str, ws_room_peers, from_peer);
        if !direct_probe
            && !responder.as_deref().is_some_and(|r| super::resolver::same_identity(r, local_peer_str))
        {
            return;
        }
        let from_master = super::resolver::resolve(from_peer);
        let cd_key = format!("{group_key}|{from_master}");
        if epoch_hint_cooldown.get(&cd_key).is_some_and(|t| t.elapsed() < EPOCH_HINT_COOLDOWN) {
            return;
        }
        epoch_hint_cooldown.insert(cd_key, std::time::Instant::now());

        let catchup = if forked { None } else { mls_mgr.cached_commits_after(&group_key, their_epoch, own_epoch) };
        match catchup {
            Some(commits) => {
                hollow_log!(
                    "[HOLLOW-MLS] Serving commit catch-up to {from_peer} for {group_key}: {} commit(s), epochs {}..={}",
                    commits.len(), their_epoch + 1, own_epoch
                );
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers, from_peer,
                    HavenMessage::MlsCommitCatchup {
                        server_id: server_id.to_string(),
                        channel_id: channel_id.map(|c| c.to_string()),
                        commits,
                    },
                );
            }
            None => {
                // A fork, or the cache cannot bridge: repair them. Their fresh
                // KeyPackage replaces their leaf in one commit and its Welcome
                // carries them to our epoch.
                hollow_log!(
                    "[HOLLOW-MLS] Epoch hint from {from_peer} for {group_key} (theirs {their_epoch}, ours {own_epoch}, forked {forked}) — requesting a KeyPackage to repair"
                );
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers, from_peer,
                    HavenMessage::MlsKeyPackageRequest {
                        server_id: server_id.to_string(),
                        channel_id: channel_id.map(|c| c.to_string()),
                    },
                );
            }
        }
    } else if their_epoch > own_epoch {
        send_epoch_probe(
            mls_mgr, ws_cmd_tx, ws_room_peers, state,
            server_id, channel_id, local_peer_str, epoch_hint_cooldown,
        );
    }
}

/// Probe the group authority with our current epoch ("am I behind?").
/// Fired at VC join, from SFrame heal step 2, and when a peer's hint says the
/// group moved past us. No-op when we ARE the authority, the authority is
/// unreachable, it's a conference, or the per-group cooldown is active.
#[allow(clippy::too_many_arguments)]
pub(crate) fn send_epoch_probe(
    mls_mgr: &MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    state: &crate::crdt::server_state::ServerState,
    server_id: &str,
    channel_id: Option<&str>,
    local_peer_str: &str,
    epoch_hint_cooldown: &mut HashMap<String, std::time::Instant>,
) {
    if super::conference::is_conference_sid(server_id) {
        return;
    }
    let group_key = match channel_id {
        Some(cid) => crate::crypto::subgroup_id(server_id, cid),
        None => server_id.to_string(),
    };
    let Ok(own_epoch) = mls_mgr.epoch(&group_key) else { return };
    // WE would be the peer that is behind, so we are excluded from the election:
    // "we are the authority" says who COMMITS, never who holds the newest epoch,
    // and treating it as the latter left a returning owner with nobody to ask.
    let Some(authority) =
        epoch_catchup_responder(state, channel_id, local_peer_str, ws_room_peers, local_peer_str)
    else {
        return; // no other online member — nobody to ask
    };
    let cd_key = format!("{group_key}|probe");
    if epoch_hint_cooldown.get(&cd_key).is_some_and(|t| t.elapsed() < EPOCH_HINT_COOLDOWN) {
        return;
    }
    epoch_hint_cooldown.insert(cd_key, std::time::Instant::now());
    let data = serde_json::to_vec(&HavenMessage::MlsEpochProbe {
        server_id: server_id.to_string(),
        channel_id: channel_id.map(|c| c.to_string()),
        epoch: own_epoch,
        epoch_auth: mls_mgr.epoch_auth_digest(&group_key),
    }).unwrap_or_default();
    let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &authority, data);
    if sent > 0 {
        hollow_log!("[HOLLOW-MLS] Sent epoch probe (epoch {own_epoch}) to authority {authority} for {group_key}");
    }
}

/// Send pre-serialized bytes to EVERY online device of an identity, returning
/// how many it reached.
///
/// Server members are keyed by MASTER, but no socket authenticates as the bare
/// master, so `send_raw_to_peer(master)` is silently dropped. A `member_id` that
/// is itself a live device id is reached directly.
pub(crate) fn send_raw_to_identity(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    member_id: &str,
    data: Vec<u8>,
) -> usize {
    let mut devices = online_devices_for(ws_room_peers, member_id);
    // online_devices_for excludes the bare master; if member_id is itself a live
    // device (no link known) include it directly.
    if devices.is_empty() && ws_room_for_peer(ws_room_peers, member_id).is_some() {
        devices.push(member_id.to_string());
    }
    let mut sent = 0;
    for dev in &devices {
        if let Some(room) = ws_room_for_peer(ws_room_peers, dev) {
            let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
                room_code: room,
                target_peer: dev.clone(),
                data: data.clone(),
            });
            sent += 1;
        }
    }
    sent
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    fn make_room_peers(rooms: &[(&str, &[&str])]) -> HashMap<String, HashSet<String>> {
        rooms.iter().map(|(room, peers)| {
            (room.to_string(), peers.iter().map(|p| p.to_string()).collect())
        }).collect()
    }

    #[test]
    fn coordinator_election_lowest_wins() {
        let members = vec!["peer_c".into(), "peer_a".into(), "peer_b".into()];
        let rooms = make_room_peers(&[("srv1", &["peer_a", "peer_b", "peer_c"])]);
        assert_eq!(elect_coordinator(&members, "peer_a", &rooms).as_deref(), Some("peer_a"));
        assert_eq!(elect_coordinator(&members, "peer_b", &rooms).as_deref(), Some("peer_a"));
        assert_eq!(elect_coordinator(&members, "peer_c", &rooms).as_deref(), Some("peer_a"));
    }

    #[test]
    fn coordinator_election_single_member() {
        let members = vec!["peer_x".into()];
        let rooms = HashMap::new(); // no room peers, but local peer is always "online"
        assert_eq!(elect_coordinator(&members, "peer_x", &rooms).as_deref(), Some("peer_x"));
    }

    #[test]
    fn coordinator_election_offline_skipped() {
        let members = vec!["peer_a".into(), "peer_b".into(), "peer_c".into()];
        let rooms = make_room_peers(&[("srv1", &["peer_b", "peer_c"])]);
        assert_eq!(elect_coordinator(&members, "peer_b", &rooms).as_deref(), Some("peer_b"));
        assert_eq!(elect_coordinator(&members, "peer_c", &rooms).as_deref(), Some("peer_b"));
        assert_eq!(elect_coordinator(&members, "peer_a", &rooms).as_deref(), Some("peer_a"));
    }

    #[test]
    fn coordinator_election_empty_members() {
        let members: Vec<String> = vec![];
        let rooms = HashMap::new();
        assert_eq!(elect_coordinator(&members, "peer_x", &rooms).as_deref(), Some("peer_x"));
    }

    #[test]
    fn coordinator_election_collapses_devices_to_master() {
        // Multi-device: master M1 has two online device leaves, M2 has one, and the
        // MLS group lists DEVICE ids. The election must count M1 once.
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();
        super::super::resolver::update("dev_m1_a", "master1");
        super::super::resolver::update("dev_m1_b", "master1");
        super::super::resolver::update("dev_m2", "master2");

        let members = vec!["dev_m1_a".into(), "dev_m1_b".into(), "dev_m2".into()];
        let rooms = make_room_peers(&[("srv1", &["dev_m1_a", "dev_m1_b", "dev_m2"])]);

        assert_eq!(elect_coordinator(&members, "master1", &rooms).as_deref(), Some("master1"));
        assert_eq!(elect_coordinator(&members, "master2", &rooms).as_deref(), Some("master1"));

        assert_eq!(elect_vault_coordinator(&members, "master1", &rooms).as_deref(), Some("master2"));

        super::super::resolver::clear_all();
    }

    #[test]
    fn master_with_online_device_is_reachable() {
        // Regression for the early-return bug: `resolve(master) == master` always, so
        // an early "resolve == self -> false" made every bare MASTER id unreachable
        // even with its device online, silently disabling coordinator election, MLS
        // recovery targeting and push classification. Hold the shared resolver lock.
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::update("pir_dev_a", "pir_master_a");
        let rooms = make_room_peers(&[("srvP", &["pir_dev_a"])]);

        assert!(peer_is_reachable(&rooms, "pir_master_a"));
        assert!(peer_is_reachable(&rooms, "pir_dev_a"));
        super::super::resolver::update("pir_dev_b", "pir_master_b");
        assert!(!peer_is_reachable(&rooms, "pir_master_b"));
        assert!(!peer_is_reachable(&rooms, "pir_stranger"));
    }

    #[test]
    fn preferred_online_device_picks_socket_addressable_id() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::update("pod_dev_1", "pod_master");
        super::super::resolver::update("pod_dev_2", "pod_master");
        let rooms = make_room_peers(&[("srvQ", &["pod_dev_2", "pod_dev_1"])]);

        assert_eq!(
            preferred_online_device(&rooms, "pod_master").as_deref(),
            Some("pod_dev_1")
        );
        assert_eq!(
            preferred_online_device(&rooms, "pod_dev_2").as_deref(),
            Some("pod_dev_2")
        );
        assert_eq!(preferred_online_device(&rooms, "pod_ghost_master"), None);
    }

    fn test_master() -> crate::identity::native_identity::NativeKeypair {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let m: bip39::Mnemonic = phrase.parse().unwrap();
        crate::identity::native_identity::NativeKeypair::from_mnemonic(&m).unwrap()
    }

    // ── Authenticated Olm key exchange (root of trust, Fix A/B) ──────────
    //
    // These are the regression tests for the reported relay MITM: a hostile
    // relay substituting its own Curve25519 keys into the Olm handshake.

    fn kp(seed: u8) -> crate::identity::native_identity::NativeKeypair {
        crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    /// Unpack a `KeyBundle` into the tuple the verifier takes.
    fn unpack_bundle(
        m: &HavenMessage,
    ) -> (&str, &str, Option<&str>, Option<i64>, Option<&str>, Option<&str>) {
        match m {
            HavenMessage::KeyBundle { identity_key, one_time_key, to, ts, sig, pk } => (
                identity_key, one_time_key, to.as_deref(), *ts, sig.as_deref(), pk.as_deref(),
            ),
            _ => panic!("expected KeyBundle"),
        }
    }

    #[test]
    fn signed_key_bundle_verifies_for_intended_recipient() {
        let sender = kp(1);
        let (sender_id, recipient_id) = (sender.peer_id(), kp(2).peer_id());

        let msg = signed_key_bundle(
            &sender, &sender_id, &recipient_id, "IDKEY".into(), "OTKEY".into(),
        );
        let (ik, otk, to, ts, sig, pk) = unpack_bundle(&msg);
        let payload = key_bundle_signing_payload(
            &sender_id, &recipient_id, ik, otk, ts.unwrap(),
        );

        assert_eq!(
            verify_key_exchange(&sender_id, &recipient_id, to, ts, sig, pk, &payload),
            KeyExchangeAuth::Verified,
        );
    }

    /// THE REPORTED ATTACK. A hostile relay swaps the Curve25519 keys for its
    /// own so it can decrypt, re-encrypt, and forward. It cannot re-sign,
    /// because it does not hold the sender's Ed25519 device key.
    #[test]
    fn substituted_olm_keys_are_rejected() {
        let sender = kp(1);
        let (sender_id, recipient_id) = (sender.peer_id(), kp(2).peer_id());

        let msg = signed_key_bundle(
            &sender, &sender_id, &recipient_id, "REAL_IDKEY".into(), "REAL_OTKEY".into(),
        );
        let (_, _, to, ts, sig, pk) = unpack_bundle(&msg);

        let tampered = key_bundle_signing_payload(
            &sender_id, &recipient_id, "ATTACKER_IDKEY", "ATTACKER_OTKEY", ts.unwrap(),
        );
        assert_eq!(
            verify_key_exchange(&sender_id, &recipient_id, to, ts, sig, pk, &tampered),
            KeyExchangeAuth::Invalid,
            "substituted Olm keys must not verify",
        );
    }

    /// A relay re-signing with its OWN key must fail: the verifier re-derives the
    /// peer_id from `pk`, so it cannot both sign validly and claim the victim's id.
    #[test]
    fn bundle_signed_by_impostor_is_rejected() {
        let attacker = kp(9);
        let (victim_id, recipient_id) = (kp(1).peer_id(), kp(2).peer_id());

        let msg = signed_key_bundle(
            &attacker, &victim_id, &recipient_id, "ATTACKER_IDKEY".into(), "ATTACKER_OTKEY".into(),
        );
        let (ik, otk, to, ts, sig, pk) = unpack_bundle(&msg);
        let payload = key_bundle_signing_payload(&victim_id, &recipient_id, ik, otk, ts.unwrap());

        assert_eq!(
            verify_key_exchange(&victim_id, &recipient_id, to, ts, sig, pk, &payload),
            KeyExchangeAuth::Invalid,
            "a bundle signed by anyone but the claimed sender must be refused",
        );
    }

    /// A bundle addressed to someone else must not be accepted by us.
    #[test]
    fn bundle_reflected_at_third_party_is_rejected() {
        let sender = kp(1);
        let sender_id = sender.peer_id();
        let (intended, us) = (kp(2).peer_id(), kp(3).peer_id());

        let msg = signed_key_bundle(&sender, &sender_id, &intended, "IK".into(), "OTK".into());
        let (ik, otk, to, ts, sig, pk) = unpack_bundle(&msg);
        let payload = key_bundle_signing_payload(&sender_id, &intended, ik, otk, ts.unwrap());

        assert_eq!(
            verify_key_exchange(&sender_id, &us, to, ts, sig, pk, &payload),
            KeyExchangeAuth::Invalid,
            "a bundle addressed to another device must be refused",
        );
    }

    /// A bundle captured earlier must not be replayable after a rotation.
    #[test]
    fn stale_bundle_is_rejected() {
        let sender = kp(1);
        let (sender_id, recipient_id) = (sender.peer_id(), kp(2).peer_id());
        let stale_ts = key_exchange_now() - (KEY_EXCHANGE_SKEW_SECS + 60);

        let payload = key_bundle_signing_payload(
            &sender_id, &recipient_id, "IK", "OTK", stale_ts,
        );
        let pub_b64 = base64::engine::general_purpose::STANDARD
            .encode(sender.public_key_protobuf());
        let (sig, pk) = sign_message(&sender, &pub_b64, &payload);

        assert_eq!(
            verify_key_exchange(
                &sender_id, &recipient_id, Some(&recipient_id), Some(stale_ts),
                sig.as_deref(), pk.as_deref(), &payload,
            ),
            KeyExchangeAuth::Invalid,
            "an expired bundle must be refused even though its signature is valid",
        );
    }

    /// A pre-rollout client sends no signature at all. Distinguished from
    /// Invalid so phase 1 can tolerate it while phase 2 refuses it.
    #[test]
    fn unsigned_bundle_is_reported_as_unsigned() {
        let recipient_id = kp(2).peer_id();
        assert_eq!(
            verify_key_exchange(&kp(1).peer_id(), &recipient_id, None, None, None, None, "x"),
            KeyExchangeAuth::Unsigned,
        );
    }

    /// A bare `{"type":"key_request"}` from a pre-rollout client must still
    /// deserialize, or phase 1 would break key exchange with every old client.
    #[test]
    fn legacy_unsigned_key_frames_still_deserialize() {
        match serde_json::from_str::<HavenMessage>(r#"{"type":"key_request"}"#).unwrap() {
            HavenMessage::KeyRequest { to, ts, sig, pk } => {
                assert!(to.is_none() && ts.is_none() && sig.is_none() && pk.is_none());
            }
            other => panic!("expected KeyRequest, got {other:?}"),
        }
        let legacy = r#"{"type":"key_bundle","identity_key":"a","one_time_key":"b"}"#;
        match serde_json::from_str::<HavenMessage>(legacy).unwrap() {
            HavenMessage::KeyBundle { identity_key, one_time_key, sig, .. } => {
                assert_eq!((identity_key.as_str(), one_time_key.as_str()), ("a", "b"));
                assert!(sig.is_none());
            }
            other => panic!("expected KeyBundle, got {other:?}"),
        }
    }

    /// The signed form must remain readable by a pre-rollout client, which
    /// deserializes into a variant that has no `sig`/`pk` fields.
    #[test]
    fn signed_key_request_is_forward_compatible() {
        let sender = kp(1);
        let msg = signed_key_request(&sender, &sender.peer_id(), &kp(2).peer_id());
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"key_request""#));
        assert!(json.contains(r#""sig":"#) && json.contains(r#""to":"#));
    }

    /// A signature alone proves only that SOME device sent the bundle. A device
    /// that maps to a known master must appear in that master's SIGNED list, or
    /// a relay could mint a keypair and speak in the victim's name.
    #[test]
    fn key_exchange_rejects_device_outside_signed_list() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();

        let master_id = kp(1).peer_id();
        let real_device = kp(2).peer_id();
        let rogue_device = kp(9).peer_id();

        super::super::resolver::update(&real_device, &master_id);

        assert!(!key_exchange_device_unauthorized(&real_device),
            "a device in the master's list must be allowed");
        assert!(!key_exchange_device_unauthorized(&rogue_device),
            "an entirely unknown device resolves to itself (single-device / first \
             contact) and is gated by the signature alone");

        super::super::resolver::update(&rogue_device, &master_id);
        super::super::resolver::forget(&rogue_device);
        super::super::resolver::update(&real_device, &master_id);
        assert!(!key_exchange_device_unauthorized(&real_device));

        super::super::resolver::clear_all();
    }

    #[test]
    fn device_list_sign_verify_roundtrip() {
        let master = test_master();
        let list = build_signed_device_list(
            &master,
            1,
            vec!["12D3KooWdevA".into(), "12D3KooWdevB".into()],
            vec![],
        );
        assert_eq!(list.master_peer_id, master.peer_id());
        assert!(verify_device_list(&list));
    }

    #[test]
    fn device_list_devices_are_sorted_and_deduped() {
        let master = test_master();
        let list = build_signed_device_list(
            &master,
            3,
            vec!["zzz".into(), "aaa".into(), "aaa".into(), "mmm".into()],
            vec![],
        );
        assert_eq!(list.devices, vec!["aaa", "mmm", "zzz"]);
        assert!(verify_device_list(&list));
    }

    #[test]
    fn device_list_tampered_devices_fail() {
        let master = test_master();
        let mut list = build_signed_device_list(&master, 1, vec!["aaa".into()], vec![]);
        // Inject a device the master never signed.
        list.devices.push("evil".into());
        assert!(!verify_device_list(&list), "tampered device list must not verify");
    }

    #[test]
    fn device_list_wrong_master_peer_id_fails() {
        let master = test_master();
        let mut list = build_signed_device_list(&master, 1, vec!["aaa".into()], vec![]);
        // Claim a different identity than the pubkey derives to.
        list.master_peer_id = "12D3KooWnotme".into();
        assert!(!verify_device_list(&list));
    }

    #[test]
    fn device_list_bumped_version_changes_signature() {
        let master = test_master();
        let v1 = build_signed_device_list(&master, 1, vec!["aaa".into()], vec![]);
        let v2 = build_signed_device_list(&master, 2, vec!["aaa".into()], vec![]);
        assert_ne!(v1.sig_b64, v2.sig_b64, "version is part of the signed payload");
        assert!(verify_device_list(&v1));
        assert!(verify_device_list(&v2));
    }

    // ---- Step 7: revocation tombstones ----

    #[test]
    fn revoked_device_removed_from_devices_and_signed() {
        let master = test_master();
        let list = build_signed_device_list(
            &master, 2,
            vec!["aaa".into(), "bbb".into()],
            vec!["bbb".into()],
        );
        assert_eq!(list.devices, vec!["aaa"], "revoked id stripped from active devices");
        assert_eq!(list.revoked, vec!["bbb"]);
        assert!(verify_device_list(&list), "signature covers devices+revoked");
    }

    #[test]
    fn revoked_set_is_sorted_and_signature_covers_it() {
        let master = test_master();
        let list = build_signed_device_list(
            &master, 5,
            vec!["aaa".into()],
            vec!["zzz".into(), "ccc".into(), "ccc".into()],
        );
        assert_eq!(list.revoked, vec!["ccc", "zzz"], "revoked sorted + deduped");
        assert!(verify_device_list(&list));
    }

    #[test]
    fn tampered_revoked_set_fails_verify() {
        let master = test_master();
        let mut list = build_signed_device_list(
            &master, 2, vec!["aaa".into()], vec!["bbb".into()],
        );
        // Attacker strips the tombstone post-signing to try to un-revoke bbb.
        list.revoked.clear();
        assert!(!verify_device_list(&list), "stripping the revoked array must fail verify");
    }

    #[test]
    fn revocation_changes_signature_vs_plain_list() {
        let master = test_master();
        let plain = build_signed_device_list(&master, 2, vec!["aaa".into()], vec![]);
        let revoking = build_signed_device_list(&master, 2, vec!["aaa".into()], vec!["bbb".into()]);
        assert_ne!(plain.sig_b64, revoking.sig_b64, "revoked set is part of the signed payload");
        assert!(verify_device_list(&plain));
        assert!(verify_device_list(&revoking));
    }

    // ── Backfill signature rule + public-key cache binding ────────────────
    //
    // Both reported by itsfolf (2026-07). Neither was visible to the tests that
    // existed: they fed ONE sender per batch, so the cache was never consulted for
    // a second sender, and never a batch whose signature was wrong.

    /// base64 of a keypair's public key protobuf — what rides `pk` on the wire.
    fn pk_b64(k: &crate::identity::native_identity::NativeKeypair) -> String {
        base64::engine::general_purpose::STANDARD.encode(k.public_key_protobuf())
    }

    /// THE REPORTED ATTACK (public-key cache poisoning). Two items in ONE batch:
    /// item 1 primes the cache with A's key, item 2 claims sender B while shipping
    /// A's key over bytes A genuinely signed. The pk-to-sender binding is the only
    /// thing that stops it, and the cache-HIT path used to skip it, so the forgery
    /// verified and showed as authentic in the Message Proof dialog.
    #[test]
    fn cached_verify_rechecks_pk_binding_on_cache_hit() {
        let a = kp(11);
        let (a_id, b_id) = (a.peer_id(), kp(12).peer_id());
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let p1 = message_signing_payload("ch", "srv:chan", &a_id, 1_000, "hello");
        let (sig1, pk1) = sign_message(&a, &a_pk, &p1);
        assert!(verify_message_signature_cached(
            &a_id, sig1.as_deref(), pk1.as_deref(), &p1, &mut cache,
        ));

        let p2 = message_signing_payload("ch", "srv:chan", &b_id, 2_000, "B never wrote this");
        let (sig2, _) = sign_message(&a, &a_pk, &p2);
        assert!(
            !verify_message_signature_cached(&b_id, sig2.as_deref(), pk1.as_deref(), &p2, &mut cache),
            "a cache HIT must still bind the public key to the CLAIMED sender",
        );

        let p3 = message_signing_payload("ch", "srv:chan", &a_id, 3_000, "still me");
        let (sig3, _) = sign_message(&a, &a_pk, &p3);
        assert!(verify_message_signature_cached(
            &a_id, sig3.as_deref(), pk1.as_deref(), &p3, &mut cache,
        ));
    }

    /// The same attack through the entry point the four sync sites call.
    #[test]
    fn backfill_rejects_signature_replayed_onto_another_sender() {
        let a = kp(13);
        let (a_id, b_id) = (a.peer_id(), kp(14).peer_id());
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let p1 = message_signing_payload_v2(
            "ch", "srv:chan", &a_id, 1_000, &SignedExtras::default(), "first",
        );
        let (sig1, pk1) = sign_message(&a, &a_pk, &p1);
        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", 1_000, None, &SignedExtras::default(), "first",
                sig1.as_deref(), pk1.as_deref(), &mut cache,
            ),
            BackfillSig::Valid,
        );

        let p2 = message_signing_payload_v2(
            "ch", "srv:chan", &b_id, 2_000, &SignedExtras::default(), "attributed to B",
        );
        let (sig2, _) = sign_message(&a, &a_pk, &p2);
        assert_eq!(
            check_backfill_signature(
                &b_id, "ch", "srv:chan", 2_000, None, &SignedExtras::default(), "attributed to B",
                sig2.as_deref(), pk1.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
            "A's key must not authenticate a message claiming to come from B",
        );
    }

    /// An item with NO signature is refused (0.8.5). Omitting the signature was the
    /// cheapest injection there was: the channel item names its own sender, so an
    /// unsigned row could impersonate any member and still land in the DB.
    ///
    /// The verdict stays `Absent` rather than collapsing into `Forged`, so the log
    /// tells an old peer serving legacy history from an active injection.
    #[test]
    fn backfill_rejects_unsigned_item() {
        let mut cache = PkCache::new();
        let verdict = check_backfill_signature(
            "12D3KooWlegacy", "ch", "srv:chan", 1, None, &SignedExtras::default(), "old message",
            None, None, &mut cache,
        );
        assert_eq!(verdict, BackfillSig::Absent);
        assert!(!verdict.is_acceptable(), "an unsigned backfill item must not be stored");
        assert!(!BackfillSig::Forged.is_acceptable());
        assert!(BackfillSig::Valid.is_acceptable());
    }

    /// ...but a signature that is PRESENT and does not verify is tampering, not
    /// legacy data. This is the case all four sync sites used to log and then
    /// store anyway.
    #[test]
    fn backfill_rejects_tampered_text() {
        let a = kp(15);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let payload = message_signing_payload_v2(
            "dm", "recipient", &a_id, 500, &SignedExtras::default(), "send 5",
        );
        let (sig, pk) = sign_message(&a, &a_pk, &payload);

        assert_eq!(
            check_backfill_signature(
                &a_id, "dm", "recipient", 500, None, &SignedExtras::default(), "send 5000",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
        );
        assert_eq!(
            check_backfill_signature(
                &a_id, "dm", "recipient", 500, None, &SignedExtras::default(), "send 5",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Valid,
        );
    }

    // ── v2 signing payload (Issue 2.3) ───────────────────────────────────
    //
    // The whole point of v2 is that the signature covers the structured fields, not
    // just the text. These lock the canonical format and that v1 is refused.

    fn lp(title: &str) -> LinkPreviewRef {
        LinkPreviewRef {
            url: "https://example.com".into(),
            title: title.into(),
            description: "desc".into(),
            domain: "example.com".into(),
            site_name: "Example".into(),
            thumb_webp_b64: Some("AAAA".into()),
            thumb_w: Some(10),
            thumb_h: Some(10),
            rich: None,
        }
    }

    /// `lp()` with the given rich-card mutation applied.
    fn lp_rich(f: impl FnOnce(&mut crate::node::RichCard)) -> LinkPreviewRef {
        let mut rich = crate::node::RichCard::default();
        f(&mut rich);
        LinkPreviewRef { rich: rich.into_opt(), ..lp("t") }
    }

    /// A v2 signature verifies, and each structured field is
    /// actually covered — flipping any one of them breaks verification.
    #[test]
    fn v2_signature_covers_structured_fields() {
        let a = kp(21);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let preview_digest = link_preview_digest(&lp("Real Title"));
        let extras = SignedExtras {
            mid: Some("mid-1"),
            reply_to: Some("parent-1"),
            file_id: Some("file-1"),
            order_us: Some(42),
            lp_digest: Some(&preview_digest),
            album: None,
        };
        let payload = message_signing_payload_v2("dm", "recipient", &a_id, 1_000, &extras, "hi");
        let (sig, pk) = sign_message(&a, &a_pk, &payload);

        assert!(verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &extras, "hi", &mut cache,
        ));

        let tampered_reply = SignedExtras { reply_to: Some("parent-EVIL"), ..extras };
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &tampered_reply, "hi", &mut cache,
        ), "reply_to must be covered");

        let tampered_file = SignedExtras { file_id: Some("file-EVIL"), ..extras };
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &tampered_file, "hi", &mut cache,
        ), "file_id must be covered");

        let tampered_order = SignedExtras { order_us: Some(9_999), ..extras };
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &tampered_order, "hi", &mut cache,
        ), "order_us must be covered");

        let evil_digest = link_preview_digest(&lp("Phishing Title"));
        let tampered_lp = SignedExtras { lp_digest: Some(&evil_digest), ..extras };
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &tampered_lp, "hi", &mut cache,
        ), "link_preview digest must be covered");

        let tampered_mid = SignedExtras { mid: Some("mid-EVIL"), ..extras };
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &tampered_mid, "hi", &mut cache,
        ), "mid must be covered");

        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &extras, "bye", &mut cache,
        ), "text must be covered");
    }

    const ALBUM: &str = "3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f";

    fn album_extras(album: Option<&str>) -> SignedExtras<'_> {
        SignedExtras {
            mid: Some("mid-a1"),
            file_id: Some("file-a1"),
            order_us: Some(1_000_001),
            album,
            ..Default::default()
        }
    }

    #[test]
    fn album_id_shape_accepts_only_hyphenated_uuids() {
        assert!(is_album_id_shape(ALBUM));
        assert!(is_album_id_shape(&ALBUM.to_uppercase()));
        assert!(!is_album_id_shape(""));
        assert!(!is_album_id_shape(&ALBUM.replace('-', "")));
        assert!(!is_album_id_shape(&format!("{ALBUM}0")));
        assert!(!is_album_id_shape("3f2a9c1e:7b4d-4e8a-9c2f-1a2b3c4d5e6f"));
        assert!(!is_album_id_shape("3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6g"));
        assert!(!is_album_id_shape("3f2a9c1e7-b4d-4e8a-9c2f-1a2b3c4d5e6f"));
    }

    /// Non-album traffic must keep the exact 0.8.5 bytes, or every stored
    /// signature in the world stops verifying.
    #[test]
    fn no_album_payload_is_byte_identical_v2() {
        let extras = SignedExtras {
            mid: Some("m"), reply_to: Some("r"), file_id: Some("f"),
            order_us: Some(7), lp_digest: Some("d"), album: None,
        };
        let expected = "hollow-msg2:dm:ctx:snd:5:m:r:f:7:d:a:b";
        assert_eq!(message_signing_payload_v2("dm", "ctx", "snd", 5, &extras, "a:b"), expected);
        let empty = SignedExtras { album: Some(""), ..extras };
        assert_eq!(
            message_signing_payload_v2("dm", "ctx", "snd", 5, &empty, "a:b"), expected,
            "an empty album is no album",
        );
        let v3 = SignedExtras { album: Some(ALBUM), ..extras };
        assert_eq!(
            message_signing_payload_v2("dm", "ctx", "snd", 5, &v3, "a:b"),
            format!("hollow-msg3:dm:ctx:snd:5:m:r:f:7:d:{ALBUM}:a:b"),
        );
    }

    #[test]
    fn album_v3_signature_round_trips_and_resists_downgrade() {
        let a = kp(24);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let v3 = album_extras(Some(ALBUM));
        let (sig, pk) = sign_message_versioned(&a, &a_pk, "ch", "srv:chan", &a_id, 9, &v3, "[file:file-a1]");
        assert!(verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "ch", "srv:chan", 9, &v3, "[file:file-a1]", &mut cache,
        ), "v3 round trip");

        let stripped = album_extras(None);
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "ch", "srv:chan", 9, &stripped, "[file:file-a1]", &mut cache,
        ), "stripping the album from a v3 signature must reject");

        let other = "00000000-0000-4000-8000-000000000000";
        let regrouped = album_extras(Some(other));
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "ch", "srv:chan", 9, &regrouped, "[file:file-a1]", &mut cache,
        ), "moving an item into another album must reject");

        let (sig2, pk2) = sign_message_versioned(&a, &a_pk, "ch", "srv:chan", &a_id, 9, &stripped, "[file:file-a1]");
        assert!(!verify_message_signature_v2(
            &a_id, sig2.as_deref(), pk2.as_deref(), "ch", "srv:chan", 9, &v3, "[file:file-a1]", &mut cache,
        ), "adding an album to a v2 signature must reject");
    }

    /// A colon in the album slot would let two layouts produce one byte string,
    /// so a malformed album fails even under a signature over those exact bytes.
    #[test]
    fn malformed_album_is_rejected_even_when_signed() {
        let a = kp(25);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();
        for bad in ["a:b", "short", "3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f-extra"] {
            let extras = album_extras(Some(bad));
            let (sig, pk) = sign_message_versioned(&a, &a_pk, "dm", "rcpt", &a_id, 3, &extras, "x");
            assert!(!verify_message_signature_v2(
                &a_id, sig.as_deref(), pk.as_deref(), "dm", "rcpt", 3, &extras, "x", &mut cache,
            ), "malformed album {bad:?} must reject");
        }
    }

    /// Old peers parse album-bearing payloads (unknown fields are ignored) and
    /// album-less traffic serializes exactly as before.
    #[test]
    fn album_wire_field_is_tolerant_both_ways() {
        use crate::node::types::{ChannelMessagePayload, DirectMessagePayload, SyncMessageItem};
        let old = r#"{"sid":"s","cid":"c","text":"t","ts":1,"mid":"m","order_us":5}"#;
        let parsed: ChannelMessagePayload = serde_json::from_str(old).expect("old shape parses");
        assert!(parsed.album.is_none());
        let reserialized = serde_json::to_string(&parsed).unwrap();
        assert!(!reserialized.contains("album"), "no album means no album key on the wire");

        #[derive(serde::Deserialize)]
        struct PreAlbumDm {
            text: String,
            #[serde(default)]
            order_us: Option<i64>,
        }
        let new_dm = DirectMessagePayload {
            text: "t".into(), ts: 1, sig: None, pk: None, mid: Some("m".into()),
            reply_to: None, file_id: None, link_preview: None, convo: None,
            order_us: Some(5), album: Some(ALBUM.into()),
        };
        let json = serde_json::to_string(&new_dm).unwrap();
        let old_view: PreAlbumDm = serde_json::from_str(&json).expect("an old struct ignores album");
        assert_eq!((old_view.text.as_str(), old_view.order_us), ("t", Some(5)));
        let back: DirectMessagePayload = serde_json::from_str(&json).unwrap();
        assert_eq!(back.album.as_deref(), Some(ALBUM));

        let item: SyncMessageItem =
            serde_json::from_str(r#"{"s":"x","t":"t","ts":1}"#).expect("old sync item parses");
        assert!(item.album.is_none());
    }

    /// The transition window is CLOSED (0.8.5): a legacy v1 signature is
    /// refused even though it is genuine, because the payload it covers leaves
    /// the structured fields unbound.
    #[test]
    fn v1_signature_is_rejected() {
        let a = kp(22);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        // A GENUINE v1 signature by the real sender, refused anyway: the payload it
        // covers leaves mid/reply_to/file_id/order_us/preview free to be rewritten.
        let v1 = message_signing_payload("ch", "srv:chan", &a_id, 1_000, "legacy");
        let (sig, pk) = sign_message(&a, &a_pk, &v1);

        let extras = SignedExtras { mid: Some("m"), file_id: Some("f"), ..Default::default() };
        assert!(
            !verify_message_signature_v2(
                &a_id, sig.as_deref(), pk.as_deref(), "ch", "srv:chan", 1_000, &extras, "legacy", &mut cache,
            ),
            "v1 verification was dropped in 0.8.5 — a v1 signature must not verify",
        );

        // ...and it stays rejected with NO extras supplied, i.e. there is no
        // "looks like a v1 message" shape that reopens the fallback.
        assert!(
            !verify_message_signature_v2(
                &a_id, sig.as_deref(), pk.as_deref(), "ch", "srv:chan", 1_000,
                &SignedExtras::default(), "legacy", &mut cache,
            ),
            "an empty-extras v2 payload must not collapse onto the v1 grammar",
        );
    }

    /// `sign_message_versioned` signs v2 unconditionally, and a v1-only
    /// verifier must fail that signature — the wire-breaking edge the rollout
    /// note documents.
    #[test]
    fn versioned_signer_produces_v2_only() {
        let a = kp(23);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let preview_digest = link_preview_digest(&lp("t"));
        let extras = SignedExtras {
            mid: Some("mid"), reply_to: None, file_id: Some("fid"),
            order_us: Some(7), lp_digest: Some(&preview_digest),
            album: None,
        };
        let (sig, pk) = sign_message_versioned(
            &a, &a_pk, "dm", "recipient", &a_id, 500, &extras, "payload",
        );

        assert!(verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 500, &extras, "payload", &mut cache,
        ));

        let v1 = message_signing_payload("dm", "recipient", &a_id, 500, "payload");
        let (v1_sig, _) = sign_message(&a, &a_pk, &v1);
        assert_ne!(sig, v1_sig, "signing must produce a v2 signature");
        assert!(
            !verify_message_signature(&a_id, sig.as_deref(), pk.as_deref(), &v1),
            "a v2 signature must not verify against the v1 payload",
        );
    }

    // ── Signed profiles (every field since 0.12) ─────────────────────────

    fn sample_fields<'a>(avatar: &'a str, banner: &'a str, assets: &'a str) -> ProfileFields<'a> {
        ProfileFields {
            display_name: "Vitalik",
            status: "online",
            about_me: "about",
            twitch_username: "twitchname",
            avatar_hash: avatar,
            banner_hash: banner,
            showcase_board: "{\"blocks\":[]}",
            showcase_assets_hash: assets,
            avatar_frame: "b:120",
            avatar_anim: "",
            banner_anim: "",
        }
    }

    /// `ProfileRelay` asserts a THIRD party's profile with a `source_peer_id` and an
    /// `updated_at` the sender picks, so the subject's signature must bind the
    /// subject, the timestamp and every field a receiver stores (N1).
    #[test]
    fn profile_signature_binds_subject_and_every_field() {
        let victim = kp(30);
        let attacker = kp(31);
        let (victim_id, attacker_id) = (victim.peer_id(), attacker.peer_id());
        let (a, b, c) = ("a".repeat(64), "b".repeat(64), "c".repeat(64));
        let fields = sample_fields(&a, &b, &c);
        let (sig, pk) = sign_profile(&victim, &victim_id, 1_000, &fields);
        let ok = |peer: &str, ts: i64, f: &ProfileFields| verify_profile_signature(peer, ts, f, sig.as_deref(), pk.as_deref());
        assert!(ok(&victim_id, 1_000, &fields));

        let other = "d".repeat(64);
        let tampered: [ProfileFields; 11] = [
            ProfileFields { display_name: "Admin", ..fields },
            ProfileFields { status: "compromised", ..fields },
            ProfileFields { about_me: "other", ..fields },
            ProfileFields { twitch_username: "someoneelse", ..fields },
            ProfileFields { avatar_hash: &other, ..fields },
            ProfileFields { banner_hash: &other, ..fields },
            ProfileFields { showcase_board: "", ..fields },
            ProfileFields { showcase_assets_hash: &other, ..fields },
            ProfileFields { avatar_frame: "b:121", ..fields },
            ProfileFields { avatar_anim: &other, ..fields },
            ProfileFields { banner_anim: &other, ..fields },
        ];
        for (i, f) in tampered.iter().enumerate() {
            assert!(!ok(&victim_id, 1_000, f), "field {i} must be bound by the signature");
        }
        assert!(!ok(&victim_id, i64::MAX, &fields));
        assert!(!ok(&attacker_id, 1_000, &fields), "bound to the subject");

        // The attacker signs a profile claiming to be the victim's.
        let (bad_sig, bad_pk) = sign_profile(&attacker, &victim_id, i64::MAX, &fields);
        assert!(
            !verify_profile_signature(&victim_id, i64::MAX, &fields, bad_sig.as_deref(), bad_pk.as_deref()),
            "a profile must not be attributable to someone who did not sign it",
        );
        assert!(!verify_profile_signature(&victim_id, 1_000, &fields, None, None));
    }

    /// Profile fields are free text, so the payload length-prefixes each one: two
    /// splits that concatenate identically must not share a payload.
    #[test]
    fn profile_payload_is_collision_resistant() {
        let base = ProfileFields::default();
        let p1 = profile_signing_payload("peer", 1, &ProfileFields { display_name: "ab", status: "c", ..base });
        let p2 = profile_signing_payload("peer", 1, &ProfileFields { display_name: "a", status: "bc", ..base });
        assert_ne!(p1, p2);
        let named = ProfileFields { display_name: "n", ..base };
        assert_ne!(profile_signing_payload("peer", 1, &named), profile_signing_payload("peer", 2, &named));
    }

    /// A card is signed on its own, so a card signature never passes for a profile
    /// and the reverse.
    #[test]
    fn card_and_profile_signatures_do_not_stand_in_for_each_other() {
        let owner = kp(33);
        let id = owner.peer_id();
        let hash = "e".repeat(64);
        let fields = ProfileFields { display_name: "owner", avatar_hash: &hash, ..ProfileFields::default() };
        assert_ne!(
            card_signing_payload(&id, 5, "owner", &hash),
            profile_signing_payload(&id, 5, &fields),
        );
        let (sig, pk) = sign_message(&owner, &pk_b64(&owner), &card_signing_payload(&id, 5, "owner", &hash));
        assert!(!verify_profile_signature(&id, 5, &fields, sig.as_deref(), pk.as_deref()));
        assert_ne!(card_signing_payload(&id, 5, "ab", "c"), card_signing_payload(&id, 5, "a", "bc"));
    }

    /// The link-preview digest is length-prefixed, so a field-boundary shift
    /// that keeps the raw concatenation identical still changes the hash.
    #[test]
    fn link_preview_digest_is_collision_resistant() {
        let mut a = lp("");
        a.url = "ab".into();
        a.title = "c".into();
        let mut b = lp("");
        b.url = "a".into();
        b.title = "bc".into();
        assert_ne!(link_preview_digest(&a), link_preview_digest(&b));
    }

    /// The rich-card fields (issue #45) were added so that adding them changes
    /// NOTHING for a preview that does not use them: every row already on disk keeps
    /// the digest it was signed with. The literal is the digest of
    /// `lp("Pinned Title")` as produced before `kind`/`author`/`video_url` existed,
    /// so folding a future field in unconditionally fails here.
    #[test]
    fn rich_fields_absent_preserves_legacy_digest() {
        let plain = lp("Pinned Title");
        assert!(plain.rich.is_none());

        // Recompute the pre-#45 digest by hand: the five strings, then the
        // thumbnail present-flag. Nothing else.
        use sha2::{Digest, Sha256};
        let mut h = Sha256::new();
        for field in [
            &plain.url, &plain.title, &plain.description, &plain.domain, &plain.site_name,
        ] {
            h.update((field.len() as u64).to_le_bytes());
            h.update(field.as_bytes());
        }
        match &plain.thumb_webp_b64 {
            Some(t) => {
                h.update([1u8]);
                h.update((t.len() as u64).to_le_bytes());
                h.update(t.as_bytes());
            }
            None => h.update([0u8]),
        }
        assert_eq!(link_preview_digest(&plain), hex::encode(h.finalize()));
    }

    /// Each rich field is bound: flipping one changes the digest, so a relay
    /// cannot repaint a public-channel card's author line or point its play
    /// button somewhere else while the signature still verifies.
    #[test]
    fn rich_fields_are_bound_by_the_digest() {
        let baseline = link_preview_digest(&lp("t"));

        let variants = [
            lp_rich(|r| r.kind = Some("large".into())),
            lp_rich(|r| r.author = Some("@someone".into())),
            lp_rich(|r| r.video_url = Some("https://video.example/v.mp4".into())),
        ];
        for variant in &variants {
            assert_ne!(baseline, link_preview_digest(variant));
        }

        // The presence mask is what stops one field's value being replayed as
        // another's: same bytes hashed, different slots.
        assert_ne!(
            link_preview_digest(&lp_rich(|r| r.author = Some("x".into()))),
            link_preview_digest(&lp_rich(|r| r.video_url = Some("x".into()))),
        );

        // Layout integers stay OUT — lying about them buys a wrong aspect
        // ratio and nothing more.
        let mut resized = lp_rich(|r| {
            r.video_w = Some(1920);
            r.video_h = Some(1080);
        });
        resized.thumb_w = Some(4);
        assert_eq!(baseline, link_preview_digest(&resized));
    }

    /// An edit is re-signed over the EDIT timestamp and the NEW text
    /// (`message_ops::handle_edit_*`), so that is what backfill verifies against.
    /// Skipping edited rows made `edited_at` a way to skip verification.
    #[test]
    fn backfill_verifies_edit_against_edit_signature() {
        let a = kp(16);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let (orig_ts, edit_ts) = (1_000i64, 2_000i64);
        let edit_payload = message_signing_payload_v2(
            "ch", "srv:chan", &a_id, edit_ts, &SignedExtras::default(), "edited text",
        );
        let (sig, pk) = sign_message(&a, &a_pk, &edit_payload);

        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", orig_ts, Some(edit_ts), &SignedExtras::default(), "edited text",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Valid,
        );
        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", orig_ts, Some(edit_ts), &SignedExtras::default(), "text the author never wrote",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
            "claiming to be an edit must not dodge verification",
        );
    }

    /// v2 EDIT signatures bind the row's full structural fields at the EDIT
    /// timestamp, so backfill verifies an edited item end to end and a responder
    /// cannot replay the edit signature onto another mid or graft a forged file_id
    /// onto the edited row.
    #[test]
    fn backfill_verifies_v2_edit_and_rejects_extras_tamper() {
        let a = kp(24);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let (orig_ts, edit_ts) = (1_000i64, 2_000i64);
        let extras = SignedExtras {
            mid: Some("mid-edit"), reply_to: Some("parent-1"),
            file_id: None, order_us: Some(1_000_042), lp_digest: None,
            album: None,
        };
        let edit_payload = message_signing_payload_v2("ch", "srv:chan", &a_id, edit_ts, &extras, "edited text");
        let (sig, pk) = sign_message(&a, &a_pk, &edit_payload);

        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", orig_ts, Some(edit_ts), &extras, "edited text",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Valid,
        );
        let other_mid = SignedExtras { mid: Some("mid-OTHER"), ..extras };
        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", orig_ts, Some(edit_ts), &other_mid, "edited text",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
            "an edit signature must be bound to its message id",
        );
        let grafted_file = SignedExtras { file_id: Some("file-EVIL"), ..extras };
        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", orig_ts, Some(edit_ts), &grafted_file, "edited text",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
            "an edited row's structural fields must stay covered",
        );
    }

    /// End-to-end shape of the send path: `sign_message_versioned` must verify at a
    /// backfill site that reconstructs the same extras from a sync item, and any
    /// structural tamper on the item must be rejected.
    #[test]
    fn versioned_send_roundtrips_through_backfill() {
        let a = kp(25);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let extras = SignedExtras {
            mid: Some("mid-rt"), reply_to: None, file_id: Some("file-rt"),
            order_us: Some(777), lp_digest: None,
            album: None,
        };
        let (sig, pk) = sign_message_versioned(
            &a, &a_pk, "ch", "srv:chan", &a_id, 3_000, &extras, "round trip",
        );
        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", 3_000, None, &extras, "round trip",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Valid,
        );
        let reordered = SignedExtras { order_us: Some(778), ..extras };
        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", 3_000, None, &reordered, "round trip",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
            "order_us tamper on a synced item must be rejected",
        );
    }

    // -- Async friending: carried bundle + the shared SignedDeviceList KAT -----

    /// Cross-agent KAT. The relay's C++ ownership check has to rebuild EXACTLY
    /// these bytes to verify an `inbox_proof`, so the vector is pinned here and
    /// mirrored there. Run with `--nocapture` to print the whole vector.
    #[test]
    fn signed_device_list_kat_vector() {
        let master = kp(0x7a);
        let device_a = kp(0x1b).peer_id();
        let device_b = kp(0x2c).peer_id();

        let mut devices = vec![device_a.clone(), device_b.clone()];
        devices.sort();
        let revoked = vec![kp(0x3d).peer_id()];
        let list = build_signed_device_list(&master, 3, devices.clone(), revoked.clone());

        let payload = device_list_signing_payload(
            &list.master_peer_id, list.version, &list.devices, &list.revoked,
        );

        println!("--- SignedDeviceList KAT (master seed = 0x7a repeated 32x) ---");
        println!("master_peer_id     = {}", list.master_peer_id);
        println!("master_pubkey_b64  = {}", list.master_pubkey_b64);
        println!("devices            = {:?}", list.devices);
        println!("revoked            = {:?}", list.revoked);
        println!("version            = {}", list.version);
        println!("signed_payload     = {payload}");
        println!("sig_b64            = {}", list.sig_b64);
        println!("json               = {}", serde_json::to_string(&list).unwrap());
        println!("--- end KAT ---");

        assert!(verify_device_list(&list), "the KAT vector must verify");

        assert_eq!(
            payload,
            format!(
                "hollow-devices:{}:3:{}:{}",
                list.master_peer_id,
                list.devices.join(","),
                list.revoked.join(","),
            ),
        );

        // A reordered devices array must NOT change the verdict (both sides sort
        // before rebuilding), while a MEMBERSHIP change must break it.
        let mut reordered = list.clone();
        reordered.devices.reverse();
        assert!(verify_device_list(&reordered), "sorting is part of the payload rule");
        let mut tampered = list.clone();
        tampered.devices.push(kp(0x4e).peer_id());
        assert!(!verify_device_list(&tampered), "an added device must break the signature");
        let mut unrevoked = list.clone();
        unrevoked.revoked.clear();
        assert!(!verify_device_list(&unrevoked), "stripping a tombstone must break the signature");
    }

    /// The new `FriendRequest` fields must be invisible to a peer that has never
    /// heard of them, a bare `FriendAccept` must stay byte-identical, and an old
    /// peer must ignore the stamp a new one adds. Getting this wrong does not fail
    /// loudly: an old client simply stops being able to accept anyone.
    #[test]
    fn friend_request_wire_stays_backward_compatible() {
        let bare = HavenMessage::FriendRequest {
            requested_at: 1234,
            carried_bundle: None,
            device_list: None,
            sealed_card: None,
        };
        let json = serde_json::to_string(&bare).unwrap();
        assert_eq!(json, r#"{"type":"friend_request","requested_at":1234}"#);

        let old_wire = r#"{"type":"friend_request","requested_at":99}"#;
        match serde_json::from_str::<HavenMessage>(old_wire).unwrap() {
            HavenMessage::FriendRequest { requested_at, carried_bundle, device_list, sealed_card } => {
                assert_eq!(requested_at, 99);
                assert!(carried_bundle.is_none(), "no bundle means fall back to lazy key exchange");
                assert!(device_list.is_none());
                assert!(sealed_card.is_none(), "old wire carries no card");
            }
            other => panic!("expected FriendRequest, got {other:?}"),
        }

        // A bare FriendAccept keeps the old wire shape both ways, and the stamp a
        // new client adds is ignored by the unit variant old clients still parse.
        assert_eq!(
            serde_json::to_string(&HavenMessage::FriendAccept { requested_at: None, device_list: None }).unwrap(),
            r#"{"type":"friend_accept"}"#,
        );
        assert!(matches!(
            serde_json::from_str::<HavenMessage>(r#"{"type":"friend_accept"}"#).unwrap(),
            HavenMessage::FriendAccept { requested_at: None, device_list: None },
        ));
        assert_eq!(
            serde_json::to_string(&HavenMessage::FriendAccept { requested_at: Some(7), device_list: None }).unwrap(),
            r#"{"type":"friend_accept","requested_at":7}"#,
        );
        #[derive(serde::Deserialize)]
        #[serde(tag = "type")]
        enum LegacyWire {
            #[serde(rename = "friend_accept")]
            FriendAccept,
        }
        assert!(matches!(
            serde_json::from_str::<LegacyWire>(r#"{"type":"friend_accept","requested_at":7}"#).unwrap(),
            LegacyWire::FriendAccept,
        ));

        let device = kp(0x1b);
        let bundle = signed_carried_bundle(
            &device, &device.peer_id(), "master-x", "ik".into(), "otk".into(),
        );
        let list = crate::identity::roster::Roster::legacy_for_test(&kp(0x7a), &[&device]);
        let full = HavenMessage::FriendRequest {
            requested_at: 7,
            carried_bundle: Some(bundle.clone()),
            device_list: Some(list),
            sealed_card: None,
        };
        let wire = serde_json::to_string(&full).unwrap();
        match serde_json::from_str::<HavenMessage>(&wire).unwrap() {
            HavenMessage::FriendRequest { carried_bundle: Some(b), device_list: Some(_), .. } => {
                assert_eq!(b.one_time_key, bundle.one_time_key);
                assert_eq!(b.sig_b64, bundle.sig_b64);
            }
            other => panic!("expected a bundled FriendRequest, got {other:?}"),
        }
    }

    /// `FriendReject` grew a `requested_at` so a stale or replayed decline can never
    /// delete a NEWER request or an accepted friendship. The enum is INTERNALLY
    /// tagged, which makes that safe both ways: an old client's bare frame parses as
    /// `requested_at = 0` and a new frame's unknown keys are drained. Getting this
    /// wrong is silent: declines simply stop crossing a version boundary.
    #[test]
    fn friend_reject_wire_is_backward_compatible() {
        // NEW -> wire: the stamp always rides, and a reject with no carried list is
        // byte-for-byte the pre-list frame. The exact string matters to old clients.
        assert_eq!(
            serde_json::to_string(&HavenMessage::FriendReject {
                requested_at: 5,
                device_list: None,
            }).unwrap(),
            r#"{"type":"friend_reject","requested_at":5}"#,
        );

        // OLD wire -> NEW code: absent fields mean 0 and no list, i.e. the
        // "decline whatever is pending" sentinel plus resolver-only attribution.
        match serde_json::from_str::<HavenMessage>(r#"{"type":"friend_reject"}"#).unwrap() {
            HavenMessage::FriendReject { requested_at, device_list } => {
                assert_eq!(requested_at, 0);
                assert!(device_list.is_none(), "old wire carries no device list");
            }
            other => panic!("expected FriendReject, got {other:?}"),
        }

        // A reject WITH a roster round-trips it intact: this is the attribution the
        // requester needs when it has never been online with the decliner.
        let master = kp(0x5c);
        let device_kp = kp(0x5d);
        let device = device_kp.peer_id();
        let list = crate::identity::roster::Roster::legacy_for_test(&master, &[&device_kp]);
        let carried = HavenMessage::FriendReject {
            requested_at: 42,
            device_list: Some(list.clone()),
        };
        let wire = serde_json::to_string(&carried).unwrap();
        match serde_json::from_str::<HavenMessage>(&wire).unwrap() {
            HavenMessage::FriendReject { requested_at, device_list: Some(got) } => {
                assert_eq!(requested_at, 42);
                assert_eq!(got, list);
                assert!(
                    got.verified(super::super::types::now_ms()).fold(|_| None, super::super::types::now_ms()).is_member(&device),
                    "the roster must survive the wire verifiable",
                );
            }
            other => panic!("expected a listed FriendReject, got {other:?}"),
        }

        // NEW wire -> OLD code. An old client models this as a UNIT variant, and
        // serde's internally-tagged unit visitor drains unknown map entries including
        // a nested object. Mirror that client here rather than trusting the claim.
        #[derive(serde::Deserialize)]
        #[serde(tag = "type")]
        enum OldWire {
            #[serde(rename = "friend_reject")]
            FriendReject,
        }
        for frame in [
            serde_json::to_string(&HavenMessage::FriendReject {
                requested_at: 1_700_000_000_000,
                device_list: None,
            }).unwrap(),
            wire,
        ] {
            assert!(
                matches!(
                    serde_json::from_str::<OldWire>(&frame).unwrap(),
                    OldWire::FriendReject,
                ),
                "an old client must still parse the new reject: {frame}",
            );
        }
    }

    /// `ServerJoinRequest` grew three fields for parked joins and `join_resolved` is
    /// a new variant; both directions must keep working across the version boundary,
    /// and getting it wrong is SILENT (joins simply stop crossing).
    ///
    /// Pinned here rather than in `types.rs`, which has no test harness, next to the
    /// same pin for `friend_reject_wire_is_backward_compatible`.
    #[test]
    fn server_join_wire_is_backward_compatible() {
        // OLD wire -> NEW code. A pre-2026-08-29 client sends only the three
        // original keys; the new fields must default to "legacy, live, no list".
        let old_wire = r#"{"type":"join_request","server_id":"abc","nsfw_confirmed":true}"#;
        match serde_json::from_str::<HavenMessage>(old_wire).unwrap() {
            HavenMessage::ServerJoinRequest {
                server_id, twitch_proof_json, nsfw_confirmed,
                requested_at, device_list, parked, key_package, reply_key, card, avatar_b64, ask,
            } => {
                assert_eq!(server_id, "abc");
                assert!(card.is_none() && avatar_b64.is_empty(), "old wire carries no card");
                assert!(ask.is_none(), "old wire carries no ask, so no member admits it");
                assert!(twitch_proof_json.is_none());
                assert!(nsfw_confirmed);
                assert_eq!(requested_at, 0, "no nonce = a legacy client");
                assert!(device_list.is_none(), "old wire carries no device list");
                assert!(!parked, "old wire is always a live request");
                assert!(key_package.is_none(), "old wire carries no KeyPackage");
                assert!(reply_key.is_empty(), "old wire carries no reply key, so no join box admits it");
            }
            other => panic!("expected ServerJoinRequest, got {other:?}"),
        }

        // NEW -> wire. The nonce and the flag always ride; an absent device list
        // serializes to nothing, so a listless request is byte-for-byte the old frame.
        assert_eq!(
            serde_json::to_string(&HavenMessage::ServerJoinRequest {
                server_id: "abc".to_string(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
                requested_at: 7,
                device_list: None,
                parked: true,
                key_package: None,
                reply_key: "rk".to_string(),
                card: None,
                avatar_b64: String::new(),
                ask: None,
            })
            .unwrap(),
            r#"{"type":"join_request","server_id":"abc","nsfw_confirmed":false,"requested_at":7,"parked":true,"reply_key":"rk"}"#,
        );

        // The PARKED copy carries the joiner's KeyPackage, which is what lets the
        // admitting member seat the leaf in the same batch as the membership. Skipped
        // when absent, so a live request is still byte-for-byte the old frame.
        let with_kp = serde_json::to_string(&HavenMessage::ServerJoinRequest {
            server_id: "abc".to_string(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
            requested_at: 9,
            device_list: None,
            parked: true,
            key_package: Some("a2V5cGFja2FnZQ".to_string()),
            reply_key: "rk".to_string(),
            card: None,
            avatar_b64: String::new(),
            ask: None,
        })
        .unwrap();
        assert_eq!(
            with_kp,
            r#"{"type":"join_request","server_id":"abc","nsfw_confirmed":false,"requested_at":9,"parked":true,"key_package":"a2V5cGFja2FnZQ","reply_key":"rk"}"#,
        );
        match serde_json::from_str::<HavenMessage>(&with_kp).unwrap() {
            HavenMessage::ServerJoinRequest { key_package: Some(kp), parked, .. } => {
                assert!(parked);
                assert_eq!(kp, "a2V5cGFja2FnZQ", "the carried package survives the wire");
            }
            other => panic!("expected a KeyPackage-carrying ServerJoinRequest, got {other:?}"),
        }

        // A request WITH a list round-trips it verifiable: this is the
        // attribution a member serving it from the ring depends on.
        let master = kp(0x7a);
        let device_kp = kp(0x7b);
        let device = device_kp.peer_id();
        let list = crate::identity::roster::Roster::legacy_for_test(&master, &[&device_kp]);
        let wire = serde_json::to_string(&HavenMessage::ServerJoinRequest {
            server_id: "abc".to_string(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
            requested_at: 42,
            device_list: Some(list.clone()),
            parked: true,
            key_package: None,
            reply_key: "rk".to_string(),
            card: None,
            avatar_b64: String::new(),
            ask: None,
        })
        .unwrap();
        match serde_json::from_str::<HavenMessage>(&wire).unwrap() {
            HavenMessage::ServerJoinRequest {
                requested_at, device_list: Some(got), parked, ..
            } => {
                assert_eq!(requested_at, 42);
                assert!(parked);
                assert_eq!(got, list);
                assert!(
                    got.verified(super::super::types::now_ms()).fold(|_| None, super::super::types::now_ms()).is_member(&device),
                    "the roster must survive the wire verifiable",
                );
            }
            other => panic!("expected a listed ServerJoinRequest, got {other:?}"),
        }

        // NEW wire -> OLD code. A pre-parked-joins client models the variant with only
        // the three original fields, and serde's struct visitor drains the unknown
        // keys, including the nested device-list object.
        #[derive(serde::Deserialize)]
        #[serde(tag = "type")]
        enum OldWire {
            #[serde(rename = "join_request")]
            ServerJoinRequest {
                server_id: String,
                #[serde(default)]
                twitch_proof_json: Option<String>,
                #[serde(default)]
                nsfw_confirmed: bool,
            },
        }
        match serde_json::from_str::<OldWire>(&wire).unwrap() {
            OldWire::ServerJoinRequest { server_id, nsfw_confirmed, .. } => {
                assert_eq!(server_id, "abc");
                assert!(!nsfw_confirmed);
            }
        }

        // `ServerJoinRejected` grew the same nonce, for a sharper reason: the refusal
        // is BUFFERED by the relay now, so a stale copy replays into the user's next
        // request. Old wire = 0 = "refuse whatever is pending".
        match serde_json::from_str::<HavenMessage>(
            r#"{"type":"join_rejected","server_id":"abc","reason":"banned"}"#,
        )
        .unwrap()
        {
            HavenMessage::ServerJoinRejected { server_id, reason, requested_at } => {
                assert_eq!(server_id, "abc");
                assert_eq!(reason, "banned");
                assert_eq!(requested_at, 0, "no nonce = refuse whatever is pending");
            }
            other => panic!("expected ServerJoinRejected, got {other:?}"),
        }
        assert_eq!(
            serde_json::to_string(&HavenMessage::ServerJoinRejected {
                server_id: "abc".to_string(),
                reason: "banned".to_string(),
                requested_at: 9,
            })
            .unwrap(),
            r#"{"type":"join_rejected","server_id":"abc","reason":"banned","requested_at":9}"#,
        );

        // `join_resolved` round-trips. An old client cannot parse it at all,
        // which is deliberate and harmless: it fails ONE frame and logs.
        let resolved = HavenMessage::ServerJoinResolved {
            server_id: "abc".to_string(),
            joiner_master: master.peer_id(),
            requested_at: 42,
            admitted: true,
            reason: String::new(),
            op_json: Some("{\"x\":1}".to_string()),
        };
        let rwire = serde_json::to_string(&resolved).unwrap();
        match serde_json::from_str::<HavenMessage>(&rwire).unwrap() {
            HavenMessage::ServerJoinResolved {
                server_id, joiner_master, requested_at, admitted, reason, op_json,
            } => {
                assert_eq!(server_id, "abc");
                assert_eq!(joiner_master, master.peer_id());
                assert_eq!(requested_at, 42);
                assert!(admitted);
                assert!(reason.is_empty());
                assert_eq!(op_json.as_deref(), Some("{\"x\":1}"));
            }
            other => panic!("expected ServerJoinResolved, got {other:?}"),
        }
        let refused = serde_json::to_string(&HavenMessage::ServerJoinResolved {
            server_id: "abc".to_string(),
            joiner_master: master.peer_id(),
            requested_at: 42,
            admitted: false,
            reason: "banned".to_string(),
            op_json: None,
        })
        .unwrap();
        assert!(!refused.contains("op_json"), "an absent op is absent, got {refused}");
        assert!(refused.contains(r#""reason":"banned""#));
    }

    /// The carried payload is pure signature math (no clock), so it pins exactly.
    #[test]
    fn carried_bundle_signing_payload_kat() {
        let device = kp(0x1b);
        let device_id = device.peer_id();
        let recipient_master = kp(0x7a).peer_id();
        let ts = 1_700_000_000i64;
        let payload = carried_bundle_signing_payload(
            &device_id, &recipient_master, "IDENTITYKEY", "ONETIMEKEY", ts,
        );
        println!("--- CarriedBundle payload KAT ---");
        println!("sender_device      = {device_id}");
        println!("recipient_master   = {recipient_master}");
        println!("signed_payload     = {payload}");
        println!(
            "sig_b64            = {}",
            base64::engine::general_purpose::STANDARD.encode(device.sign(payload.as_bytes())),
        );
        println!("--- end KAT ---");

        assert_eq!(
            payload,
            format!("hollow-carried-keybundle:{device_id}:{recipient_master}:IDENTITYKEY:ONETIMEKEY:{ts}"),
        );
        // DOMAIN SEPARATION: the live payload for the same material must differ,
        // so a carried bundle can never be reflected as a live one.
        let live = key_bundle_signing_payload(
            &device_id, &recipient_master, "IDENTITYKEY", "ONETIMEKEY", ts,
        );
        assert_ne!(payload, live);
        assert!(payload.starts_with("hollow-carried-keybundle:"));
        assert!(live.starts_with("hollow-keybundle:"));
    }

    /// A valid carried bundle verifies; every tamper is REJECTED (never logged
    /// and continued). One assert per gate, in the order the function checks them.
    #[test]
    fn verify_carried_bundle_accepts_valid_and_rejects_tampered() {
        let sender_master = kp(0x51);
        let sender_device = kp(0x52);
        let sender_device_id = sender_device.peer_id();
        let our_master = kp(0x53).peer_id();

        let list = crate::identity::roster::Roster::legacy_for_test(&sender_master, &[&sender_device]);
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("carried.db").to_str().unwrap().to_string();
        let pass = "cd".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let good = signed_carried_bundle(
            &sender_device, &sender_device_id, &our_master,
            "aWRlbnRpdHk".to_string(), "b25ldGltZQ".to_string(),
        );
        assert!(verify_carried_bundle(&our_master, &list, &good, &db, &pass), "a freshly built bundle must verify");
        assert_eq!(
            carried_bundle_sender_device(&good).as_deref(),
            Some(sender_device_id.as_str()),
        );

        // 1. Signature gates: swapped keys, cleared signature, moved timestamp.
        let mut swapped = good.clone();
        swapped.one_time_key = "b3RoZXI".to_string();
        assert!(!verify_carried_bundle(&our_master, &list, &swapped, &db, &pass), "substituted one-time key");
        let mut swapped_ik = good.clone();
        swapped_ik.identity_key = "b3RoZXI".to_string();
        assert!(!verify_carried_bundle(&our_master, &list, &swapped_ik, &db, &pass), "substituted identity key");
        let mut unsigned = good.clone();
        unsigned.sig_b64 = String::new();
        assert!(!verify_carried_bundle(&our_master, &list, &unsigned, &db, &pass), "a missing signature is a REJECT, never a bypass");
        let mut ts_moved = good.clone();
        ts_moved.ts += 1;
        assert!(!verify_carried_bundle(&our_master, &list, &ts_moved, &db, &pass), "ts is signed");

        // 2. The signing device must be a member of the sender's roster.
        let stranger = kp(0x54);
        let stranger_id = stranger.peer_id();
        let stranger_bundle = signed_carried_bundle(
            &stranger, &stranger_id, &our_master,
            "aWRlbnRpdHk".to_string(), "b25ldGltZQ".to_string(),
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &stranger_bundle, &db, &pass),
            "a device outside the roster must be refused even with a valid signature",
        );
        let mut revoked_list = list.clone();
        revoked_list.add_removal(crate::identity::roster::sign_removal(
            &sender_device, &sender_master.peer_id(), crate::identity::roster::LEGACY_BASE,
            &sender_device_id, &[],
        ));
        assert!(
            !verify_carried_bundle(&our_master, &revoked_list, &good, &db, &pass),
            "a REVOKED device must be refused",
        );
        let mut forged_list = list.clone();
        forged_list.consents[0].sig = forged_list.legacy[0].sig_m.clone();
        assert!(
            !verify_carried_bundle(&our_master, &forged_list, &good, &db, &pass),
            "a device whose consent does not verify is no member",
        );

        // 3. Addressed to US.
        let elsewhere = signed_carried_bundle(
            &sender_device, &sender_device_id, &kp(0x55).peer_id(),
            "aWRlbnRpdHk".to_string(), "b25ldGltZQ".to_string(),
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &elsewhere, &db, &pass),
            "a bundle addressed at a third party must not verify here",
        );

        // 4. Freshness, by the CARRIED rule.
        let sign_at = |ts: i64| {
            let payload = carried_bundle_signing_payload(
                &sender_device_id, &our_master, "aWRlbnRpdHk", "b25ldGltZQ", ts,
            );
            CarriedBundle {
                identity_key: "aWRlbnRpdHk".to_string(),
                one_time_key: "b25ldGltZQ".to_string(),
                to_master: our_master.clone(),
                ts,
                sig_b64: base64::engine::general_purpose::STANDARD
                    .encode(sender_device.sign(payload.as_bytes())),
                device_pk_b64: base64::engine::general_purpose::STANDARD
                    .encode(sender_device.public_key_protobuf()),
            }
        };
        let now = key_exchange_now();
        assert!(
            verify_carried_bundle(&our_master, &list, &sign_at(now - 3 * 24 * 3600), &db, &pass),
            "three days old is well inside the carried window",
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &sign_at(now - MAX_CARRIED_BUNDLE_AGE_SECS - 60), &db, &pass),
            "past the carried window is a REJECT",
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &sign_at(now + KEY_EXCHANGE_SKEW_SECS + 60), &db, &pass),
            "a bundle from the future is a REJECT",
        );

        // 5. Judged against the roster we hold for the sender: once we know its real
        //    recovery key, a carried roster under a forged one admits nobody.
        use crate::identity::roster::Roster;
        let at = super::super::roster_book::now_ms() - 60_000;
        let real = Roster::genesis(&sender_master, &kp(0x56), &sender_device, at);
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        super::super::roster_book::merge_for_test(&store, &real, &our_master, &kp(0x59).peer_id());
        drop(store);
        let thief = kp(0x57);
        let forged = Roster::genesis(&sender_master, &kp(0x58), &thief, at + 1);
        let thief_bundle = signed_carried_bundle(
            &thief, &thief.peer_id(), &our_master,
            "aWRlbnRpdHk".to_string(), "b25ldGltZQ".to_string(),
        );
        assert!(
            !verify_carried_bundle(&our_master, &forged, &thief_bundle, &db, &pass),
            "a carried roster under a forged recovery key admits its thief",
        );
        assert!(verify_carried_bundle(&our_master, &real, &good, &db, &pass), "the real roster still admits its device");
    }

    /// Every KeyPackage mint in `node/` goes through [`mint_key_package`], so every
    /// mint persists the private half it just created.
    ///
    /// A SOURCE scan rather than a type-system guard, because `generate_key_package`
    /// must stay reachable for the crypto module's own tests and because a new call
    /// site is a SILENT regression: the KeyPackage works until a restart, then every
    /// Welcome built from it fails forever with `NoMatchingKeyPackage`.
    #[test]
    fn key_package_mints_persist_mls_state() {
        // Built from pieces so this test's own source text is not a hit.
        let needle = concat!("generate_key", "_package(");
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src")
            .join("node");
        let mut hits: Vec<String> = Vec::new();
        let mut files = 0usize;
        for entry in std::fs::read_dir(&dir).expect("read src/node") {
            let path = entry.expect("dir entry").path();
            if path.extension().and_then(|e| e.to_str()) != Some("rs") {
                continue;
            }
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            let src = std::fs::read_to_string(&path).expect("read node source");
            files += 1;
            let mut current = "<file scope>".to_string();
            for line in src.lines() {
                let trimmed = line.trim_start();
                if let Some(rest) = trimmed
                    .strip_prefix("pub(crate) async fn ")
                    .or_else(|| trimmed.strip_prefix("pub(crate) fn "))
                    .or_else(|| trimmed.strip_prefix("pub async fn "))
                    .or_else(|| trimmed.strip_prefix("pub fn "))
                    .or_else(|| trimmed.strip_prefix("async fn "))
                    .or_else(|| trimmed.strip_prefix("fn "))
                    && let Some(n) = rest.split('(').next()
                {
                    current = n.to_string();
                }
                if trimmed.starts_with("//") {
                    continue;
                }
                if line.contains(needle) {
                    hits.push(format!("{name}::{current} -> {}", trimmed));
                }
            }
        }
        assert!(
            files >= 20,
            "the scan found only {files} node source files, so the path must have moved",
        );
        assert_eq!(
            hits.len(),
            1,
            "every KeyPackage mint in node/ must go through crypto_handler::mint_key_package,              which persists the freshly written private half before the public half can              reach anybody. Found: {hits:#?}",
        );
        assert!(
            hits[0].starts_with("crypto_handler.rs::mint_key_package "),
            "the one permitted call is the one inside the wrapper, got {hits:#?}",
        );
    }

    /// E13: over Olm a CRDT op arrives only as a carried `CrdtOpBroadcast`, which
    /// runs the one ingest every op takes; the group envelopes are ignored there
    /// instead of running a second, weaker ingest.
    #[test]
    fn authz_olm_carries_no_crdt_ingest() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/swarm.rs");
        let swarm = std::fs::read_to_string(path).expect("read swarm.rs").replace("\r\n", "\n");
        let end = swarm.find("Received MLS-only envelope via Olm").expect("the Olm ignore arm");
        let start = swarm[..end].rfind("=> {").expect("an arm before the ignore arm");
        let ignored = &swarm[swarm[..start].rfind("}\n").expect("the arm before it")..end];
        for kind in ["CrdtOp", "ChannelHint", "Typing"] {
            let pattern = format!("Ok(MessageEnvelope::{kind} {{");
            assert_eq!(swarm.matches(&pattern).count(), 1, "swarm.rs: an Olm {kind} arm is back");
            assert!(ignored.contains(&format!("{pattern} .. }})")), "swarm.rs: Olm {kind} is not ignored");
        }
    }

    /// The channel ingest gates are only as good as their callers: a unit test on a
    /// rule cannot see a receive path that stopped asking. Every MLS receiver binds
    /// the envelope to its group before acting, every plaintext public arm asks
    /// `public_frame_accepted`, the Olm fallback runs the shared ingest, and the push
    /// path applies the live post gate.
    #[test]
    fn channel_ingest_gates_stay_wired() {
        let node = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("node");
        let read = |f: &str| std::fs::read_to_string(node.join(f)).expect("read node source");
        let (swarm, fetch) = (read("swarm.rs"), read("fetch.rs"));
        let between = |src: &str, from: &str, to: &str| -> String {
            let start = src.find(from).unwrap_or_else(|| panic!("missing {from}"));
            let end = src[start..].find(to).unwrap_or_else(|| panic!("missing {to} after {from}"));
            src[start..start + end].to_string()
        };
        for (name, src) in [("swarm.rs", &swarm), ("fetch.rs", &fetch)] {
            let arm = between(src, "HavenMessage::MlsChannelMessage {", "match envelope {");
            assert!(arm.contains("mls_envelope_fits_group("), "{name}: MLS envelope not bound to its group");
        }
        for kind in [
            "PublicChannelMessage", "PublicChannelEdit", "PublicLinkPreviewSet",
            "PublicChannelDelete", "PublicChannelAddReaction", "PublicChannelRemoveReaction",
        ] {
            let arm = between(&swarm, &format!("        HavenMessage::{kind} {{"), "=> {");
            let body = between(&swarm, &arm, "message_ops::handle_envelope_");
            assert!(body.contains("public_frame_accepted("), "swarm.rs: {kind} skips the public check");
        }
        for arm in ["HavenMessage::ChannelNotificationHint { server_id", "MessageEnvelope::ChannelHint { sid"] {
            assert!(between(&swarm, arm, ").await;").contains("message_ops::deliver_channel_hint("), "swarm.rs: {arm} skips the shared hint gate");
        }
        let ops = read("message_ops.rs");
        assert!(between(&ops, "pub(crate) async fn deliver_channel_hint(", "NetworkEvent::ChannelNotificationHint {").contains("channel_signal_accepted("), "message_ops.rs: the hint skips the signal gate");
        for (arm, until) in [
            ("HavenMessage::TypingIndicator {", "NetworkEvent::TypingStarted {"),
            ("MessageEnvelope::Typing { sid, cid } => {", "handle_envelope_typing("),
        ] {
            assert!(between(&swarm, arm, until).contains("channel_signal_accepted("), "swarm.rs: {arm} skips the signal gate");
        }
        let voice = read("voice_handler.rs");
        for (name, src, arm) in [
            ("swarm.rs", &swarm, "HavenMessage::VoiceChannelJoin { server_id, channel_id } => {"),
            ("voice_handler.rs", &voice, "pub(crate) async fn handle_envelope_voice_channel_join("),
        ] {
            assert!(between(src, arm, "voice_channel_participants.entry(").contains("voice_join_refusal("), "{name}: a voice join skips the seat gate");
        }
        assert!(
            between(&swarm, "HavenMessage::VoiceChannelJoin { server_id, channel_id } => {", "voice_channel_participants.entry(")
                .contains("conference::seated("),
            "swarm.rs: a meeting voice join skips the roster's seat rule",
        );
        let olm = between(&swarm, "Ok(MessageEnvelope::ChannelMessage { inner }) => {", "Ok(MessageEnvelope::ChannelSyncBatch");
        assert!(olm.contains("message_ops::handle_envelope_channel_message("), "swarm.rs: the Olm arm has its own ingest again");
        let public = between(&fetch, "HavenMessage::PublicChannelMessage {", "insert_channel_row(");
        assert!(public.contains("public_frame_accepted(") && public.contains("fetch_post_refused("));
        let mls = between(&fetch, "MessageEnvelope::ChannelMessage { inner } => {", "insert_channel_row(");
        assert!(mls.contains("fetch_post_refused("), "fetch.rs: MLS posts skip the live post gate");
        // ID-1: a leaf the master certified but its roster does not admit is nobody.
        assert!(mls.contains("resolver::disowns("), "fetch.rs: MLS posts from a disowned leaf are kept");
        let live = between(&swarm, "mls_envelope_fits_group(", "match envelope {");
        assert!(live.contains("resolver::disowns("), "swarm.rs: MLS envelopes from a disowned leaf are read");
        // Section 2 items 5 and 6: an edit, card or reaction asks the change ladder,
        // a post asks it first, and both batch arms filter authors and reactors.
        for handler in ["edit_message(", "link_preview_set(", "add_reaction("] {
            let body = between(&ops, &format!("pub(crate) async fn handle_envelope_{handler}"), "MessageStore::open(");
            assert!(body.contains("live_change_dropped("), "message_ops.rs: {handler} skips the live change gate");
        }
        assert!(between(&ops, "fn live_change_dropped(", "\n}").contains("live_channel_change_refusal("));
        assert!(between(&ops, "pub(crate) fn live_channel_post_refusal(", "\n}").contains("live_channel_change_refusal("));
        for (arm, until) in [
            ("Ok(MessageEnvelope::ChannelSyncBatch {", "ingest_synced_channel_item("),
            (" MessageEnvelope::ChannelSyncBatch {", "handle_envelope_channel_sync_batch("),
        ] {
            let body = between(&swarm, arm, until);
            assert!(body.contains("channel_backfill_allowed_from("), "swarm.rs: {arm} takes backfill from anyone");
            assert!(body.contains("backfill_filter("), "swarm.rs: {arm} skips the author and reactor filter");
        }
        for (arm, until) in [
            ("Ok(MessageEnvelope::DmSyncBatch {", "Ok(MessageEnvelope::DmSiblingSyncBatch {"),
            ("Ok(MessageEnvelope::DmSiblingSyncBatch {", "Ok(MessageEnvelope::EditMessage {"),
        ] {
            assert!(between(&swarm, arm, until).contains("store_synced_dm_reactions("), "swarm.rs: {arm} stores reactions unjudged");
        }
    }

    /// HOL-SEC-089: the channel sync requests a Welcome triggers name our marks for each
    /// channel, so each goes only to a partner who can read that channel. No harness
    /// shape makes a Welcome's only partner a member who cannot.
    #[test]
    fn welcome_channel_syncs_stay_gated() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("node").join("swarm.rs");
        let swarm = std::fs::read_to_string(path).expect("read swarm.rs").replace("\r\n", "\n");
        let start = swarm.find("async fn after_welcome_joined(").expect("after_welcome_joined");
        let body = &swarm[start..start + swarm[start..].find("\n}\n").expect("its end")];
        assert!(
            body.contains("state.can_see_channel(&peer_master, c)"),
            "swarm.rs: a Welcome's channel syncs go to a partner who cannot read the channel",
        );
    }

    /// D1, D7, D10: a KeyPackage is seated only when its leaf is bound to the device
    /// that sent it, on the live, parked-join and meeting paths. The binding is the
    /// device key itself, so not even the relay can name another sender.
    #[test]
    fn authz_key_package_must_name_its_sending_device() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/swarm.rs");
        let swarm = std::fs::read_to_string(path).expect("read swarm.rs");
        let arm = |from: &str, to: &str| {
            let start = swarm.find(from).unwrap_or_else(|| panic!("missing {from}"));
            let end = swarm[start..].find(to).unwrap_or_else(|| panic!("missing {to}"));
            swarm[start..start + end].to_string()
        };
        let live = arm("HavenMessage::MlsKeyPackage { server_id, key_package, channel_id: kp_channel_id } => {", "pending_mls_key_packages");
        assert!(live.contains("key_package_identity(") && live.contains("id.device == peer_str"), "live KeyPackage arm");
        // D8: the committer's planner applies the same rule, so only this scan sees the
        // arm stop asking it.
        assert!(live.contains("rules.membership(&sender_leaf.master"), "live KeyPackage arm queues a non-member's or a banned identity's leaf");
        let parked = arm("if parked && let Some(kp_b64) = key_package.as_ref() {", "pending_mls_key_packages");
        assert!(parked.contains("key_package_identity(") && parked.contains("id.device != peer_str"), "parked-join KeyPackage");
        let conf = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/conference.rs"))
            .expect("read conference.rs");
        let knock = &conf[conf.find("if super::blocklist::is_blocked(sender_peer)").expect("knock handler")..];
        let knock = &knock[..knock.find("host_state.pending.insert(").expect("waiting room")];
        assert!(knock.contains("seat_of(&key_package_b64, sender_peer)"), "meeting knock");
        let seat = &conf[conf.find("fn seat_of(").expect("seat_of")..];
        let seat = &seat[..seat.find("\n}").expect("its end")];
        assert!(seat.contains("key_package_identity(") && seat.contains("id.device == device"), "meeting knock's seat");
    }

    /// L4: the live node shows a DM only after its signature verified. A decrypted
    /// payload that was not an envelope used to reach the UI as an unsigned,
    /// unblocked "legacy" DM.
    #[test]
    fn a_dm_reaches_the_ui_only_after_its_signature_verifies() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/swarm.rs");
        let swarm = std::fs::read_to_string(path).expect("read swarm.rs");
        let emits: Vec<usize> = swarm.match_indices("NetworkEvent::MessageReceived {").map(|(i, _)| i).collect();
        assert_eq!(emits.len(), 1, "swarm.rs shows a DM from one place, the verified arm");
        let head = &swarm[..emits[0]];
        let arm = head.rfind("Ok(MessageEnvelope::DirectMessage { inner }) => {").expect("DM arm");
        let verify = head.rfind("verify_message_signature_v2(").expect("DM verification");
        assert!(verify > arm, "the DM arm verifies before it emits");
    }

    /// C2: MLS proves only that a member of THIS group sent an envelope, so it must
    /// name this group's server, a subgroup carries only its own channel, a
    /// restricted channel's content comes only through its subgroup, and DMs never
    /// ride a group. Presence and typing for a restricted channel still ride the
    /// server-wide group by design.
    #[test]
    fn authz_mls_envelope_must_fit_the_group_that_decrypted_it() {
        let restricted = |cid: &str| cid == "staff";
        let fits = |env: &MessageEnvelope, sid: &str, group_cid: Option<&str>| {
            mls_envelope_fits_group(env, sid, group_cid, restricted)
        };
        let post = |sid: &str, cid: &str| MessageEnvelope::ChannelMessage {
            inner: Box::new(ChannelMessagePayload {
                sid: sid.into(), cid: cid.into(), text: "hi".into(), ts: 1, sig: None, pk: None,
                mid: Some("m".into()), reply_to: None, file_id: None, link_preview: None,
                order_us: Some(1_000), album: None,
            }),
        };

        assert!(!fits(&post("other-server", "general"), "srv", None), "another server's channel");
        assert!(!fits(&post("srv", "staff"), "srv", None), "restricted content outside its subgroup");
        assert!(fits(&post("srv", "staff"), "srv", Some("staff")));
        assert!(!fits(&post("srv", "general"), "srv", Some("staff")), "a subgroup carries only its channel");
        assert!(fits(&post("srv", "general"), "srv", None));

        let op = MessageEnvelope::CrdtOp { sid: "srv".into(), op_json: "{}".into() };
        assert!(!fits(&op, "conf:meeting", None), "a conference group naming a real server");
        assert!(fits(&op, "srv", None));
        assert!(!fits(&op, "srv", Some("staff")), "server-wide traffic in a subgroup");

        let join = |sid: &str| MessageEnvelope::VoiceChannelJoin { sid: sid.into(), cid: "main".into() };
        assert!(!fits(&join("conf:meeting"), "srv", None), "a meeting joined through a server group");
        let typing = MessageEnvelope::Typing { sid: "srv".into(), cid: "staff".into() };
        assert!(fits(&typing, "srv", None), "typing rides the server group by design");

        let dm_edit = MessageEnvelope::EditMessage {
            mid: "m".into(), text: "x".into(), ts: 1, sig: None, pk: None, sid: None, cid: None,
        };
        assert!(!fits(&dm_edit, "srv", None));
        assert!(!fits(&MessageEnvelope::SessionAck, "srv", None));
    }

    /// C7: a message dated more than ten minutes past our clock never verifies, so
    /// nobody can pin a post below everything that follows it.
    #[test]
    fn message_dated_past_our_clock_never_verifies() {
        let a = kp(32);
        let (a_id, a_pk) = (a.peer_id(), pk_b64(&a));
        let extras = SignedExtras { mid: Some("m"), ..SignedExtras::default() };
        let now = super::super::types::now_ms();
        let check = |ts: i64, edited_at: Option<i64>| {
            let signed = edited_at.unwrap_or(ts);
            let (sig, pk) = sign_message_versioned(&a, &a_pk, "ch", "s:c", &a_id, signed, &extras, "hi");
            let live = verify_message_signature_v2(
                &a_id, sig.as_deref(), pk.as_deref(), "ch", "s:c", signed, &extras, "hi", &mut PkCache::new(),
            );
            let synced = check_backfill_signature(
                &a_id, "ch", "s:c", ts, edited_at, &extras, "hi", sig.as_deref(), pk.as_deref(), &mut PkCache::new(),
            );
            (live, synced)
        };
        assert_eq!(check(now + 60_000, None), (true, BackfillSig::Valid));
        assert_eq!(check(now + MAX_FUTURE_SKEW_MS + 60_000, None), (false, BackfillSig::FutureDated));
        assert_eq!(
            check(now + MAX_FUTURE_SKEW_MS + 60_000, Some(now)).1,
            BackfillSig::FutureDated,
            "an honest-looking edit stamp does not carry a future-dated row",
        );
        assert!(!BackfillSig::FutureDated.is_acceptable());
    }

    /// C11: a body over the protocol limit never verifies, live or backfilled, so
    /// every receive path drops it whole. A full composer of Cyrillic (8,000 bytes)
    /// used to be clipped at 4,000 bytes and then failed its own signature.
    #[test]
    fn message_over_the_size_limit_never_verifies() {
        let a = kp(31);
        let (a_id, a_pk) = (a.peer_id(), pk_b64(&a));
        let extras = SignedExtras { mid: Some("m"), ..SignedExtras::default() };
        let check = |text: &str| {
            let (sig, pk) = sign_message_versioned(&a, &a_pk, "dm", "them", &a_id, 1_000, &extras, text);
            let live = verify_message_signature_v2(
                &a_id, sig.as_deref(), pk.as_deref(), "dm", "them", 1_000, &extras, text, &mut PkCache::new(),
            );
            let synced = check_backfill_signature(
                &a_id, "dm", "them", 1_000, None, &extras, text, sig.as_deref(), pk.as_deref(), &mut PkCache::new(),
            );
            (live, synced)
        };

        assert_eq!(check(&"я".repeat(4_000)), (true, BackfillSig::Valid));
        assert_eq!(check(&"é".repeat(MAX_MESSAGE_BYTES / 2)), (true, BackfillSig::Valid));
        let over = format!("{}!", "é".repeat(MAX_MESSAGE_BYTES / 2));
        assert_eq!(check(&over), (false, BackfillSig::Oversized));
        assert!(!BackfillSig::Oversized.is_acceptable());
        assert_eq!(
            check_backfill_signature(&a_id, "dm", "them", 1_000, None, &extras, &over, None, None, &mut PkCache::new()),
            BackfillSig::Oversized,
            "an unsigned oversized item is refused for its size",
        );
    }
}
