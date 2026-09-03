use std::collections::HashMap;
use std::sync::{OnceLock, Mutex};
use std::time::Instant;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, MlsManager, OlmManager};
use super::types::*;

/// Per-sibling cooldown for multi-device DM backfill requests (Step 5.1).
/// Sibling detection fires from TWO independent paths (the swarm.rs inbox-proof
/// AND `ingest_sibling_device_list`), and each re-fires on reconnect — so without
/// a cooldown one sibling-appearance triggers 2-4 full `DmSiblingSyncRequest`s,
/// each making the responder sweep EVERY conversation. This collapses the burst:
/// at most one request per sibling per `SIBLING_BACKFILL_COOLDOWN`. The pull is
/// still incremental (per-convo high-water) + idempotent, so a skipped redundant
/// request loses nothing — the next genuine reconnect past the cooldown re-syncs.
static SIBLING_BACKFILL_LAST: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
const SIBLING_BACKFILL_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(15);

/// Send a `DmSiblingSyncRequest` to a sibling device, throttled per-sibling so the
/// two detection paths + reconnect re-fires collapse into one. Shared by BOTH
/// trigger sites (swarm.rs inbox-proof + `ingest_sibling_device_list`) so the
/// cooldown can't be bypassed. Reads our per-conversation high-water marks from
/// the DB and asks the sibling for anything newer across all conversations.
pub(crate) fn request_sibling_dm_backfill(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
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

    let per_convo_since: Vec<(String, i64)> =
        match crate::storage::MessageStore::open(db_path, db_passphrase) {
            Ok(store) => store.get_dm_peer_ids()
                .into_iter()
                .map(|c| {
                    // Lookback overlap — a high-watermark skips messages
                    // missed while a newer one arrived; the overlap is
                    // mid-deduplicated on receipt.
                    let ts = (store
                        .get_latest_dm_timestamp_any(&c)
                        .unwrap_or(None)
                        .unwrap_or(0)
                        - crate::storage::messages::SYNC_LOOKBACK_MS)
                        .max(0);
                    (c, ts)
                })
                .collect(),
            Err(_) => Vec::new(),
        };
    hollow_log!(
        "[HOLLOW-SYNC] Requesting sibling DM backfill from {sibling_peer_id} ({} known convo(s))",
        per_convo_since.len()
    );
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers,
        sibling_peer_id, HavenMessage::DmSiblingSyncRequest { per_convo_since },
    );
}

// -- Per-message Ed25519 signing helpers (v2 only since 0.8.5) --
//
// The legacy v1 payload — "hollow-msg:{type}:{context}:{sender}:{ts}:{text}" —
// covered ONLY the text. Everything else that rides a message (reply_to,
// file_id, link_preview, order_us, mid) sat OUTSIDE the signature, so anyone
// who could modify a message in flight or serve a sync batch could, on an
// OTHERWISE-VALID message:
//   * re-target a reply (reply_to)          * swap / ADD an attachment (file_id)
//   * rewrite a link preview -> phishing     * reorder messages (order_us)
//   * manipulate the dedup key (mid)
// and the signature still verified. v2 folds these fields into the signed
// payload so the signature covers the whole message structure.
//
// ROLLOUT — COMPLETE. It was staged like the signed-key-exchange root of trust
// (REQUIRE_SIGNED_KEY_EXCHANGE) and the device-list payload versioning:
//   1. (0.8.3) Ship the v2 verifier everywhere, verifying-both.
//   2. (0.8.3) Sign v2 — flipped in the same release, because the public fleet
//      at that point ran <=0.8.1, which never ENFORCED signatures on receive
//      (verify-then-log), so a soak window would have protected nobody.
//   3. (0.8.5) DROP v1 verification — this step. `verify_message_signature_v2`
//      tries the v2 payload and NOTHING else.
//
// Why step 3 matters and is not cosmetic: while the v1 fallback existed,
// finding 2.3 stayed exploitable against any v1-signed row. Re-point a
// file_id, re-parent a reply, swap the link preview, alter order_us — the
// original v1 signature still verified, because it never covered those fields.
// A fallback that accepts a weaker payload is a downgrade oracle: an attacker
// picks the format, not the sender.
//
// CONSEQUENCE, accepted knowingly at a 2-user fleet: nothing signed by <=0.8.2
// verifies any more. Those rows stay in the local DB and still display, they
// just show as unverified and no longer replicate through sync (backfill needs
// a Valid verdict — see REQUIRE_SIGNED_BACKFILL). Nothing about identity, Olm
// sessions, MLS groups, friends or servers is affected.
//
// EDIT / DELETE signatures also ride v2: they bind the SAME full extras as the
// original message, read from the signer's own ROW at edit/delete time (the
// row's reply_to / file_id / order_us / link-preview are immutable under edit,
// so both ends agree). Binding the full row — not just `mid` — is what keeps
// the offline-queue edit rewrite verifying (the queued DirectMessage envelope
// keeps the original structured fields; see `rewrite_pending_dm_edits`) and
// stops a sync responder from attaching a forged `file_id` to an edited row
// whose original signature was overwritten by the edit signature.

/// The retired v1 payload builder. `#[cfg(test)]` ON PURPOSE: it exists ONLY so
/// tests can mint a v1 signature and assert that it is REJECTED. Production
/// code cannot reach it, which is what makes "v1 is gone" a compile-time
/// property rather than a convention someone can quietly undo.
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
/// length-prefixed so no two distinct field-sets can collide (a raw
/// concatenation would let "ab"+"c" hash the same as "a"+"bc"). Folded into the
/// v2 payload so a tamperer cannot rewrite a preview's title / description /
/// image on an otherwise-valid message.
///
/// Archives store this digest alongside the row rather than the preview, and
/// a sync item may carry it alone (see [`backfill_lp_digest`]) — verification
/// only ever needs the digest.
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

    // Rich-card fields (issue #45), folded in so a tamperer can no more
    // rewrite a card's author line or its video target than its title.
    // `video_w/h` and `thumb_w/h` stay OUT: they are layout integers, and
    // lying about them buys nothing but a wrong aspect ratio.
    //
    // Written so an OLD preview hashes to EXACTLY the digest it always did:
    // absent fields contribute no bytes at all, and the presence mask is
    // appended only when at least one IS present. Without that mask,
    // author=Some("x")/video=None would feed the hash the same bytes as
    // author=None/video=Some("x"). Rows already on disk therefore keep
    // verifying with no migration.
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
/// An item can carry the full card (`lp`), a bare digest (`lp_digest`), or
/// both. The full card wins whenever it is present, and that ordering is the
/// security property, not a preference: recomputing the digest from the bytes
/// we are about to STORE means the signature covers exactly those bytes. A
/// responder that swaps in a phishing card — or a relay rewriting a plaintext
/// public-channel batch — produces a digest the author never signed, so
/// `check_backfill_signature` returns `Forged` and the whole item is dropped.
///
/// Trusting the wire's `lp_digest` while storing a different `lp` would be the
/// exact inverse: the item would verify and the attacker's card would land.
///
/// The `lp_digest`-only case is legitimate and stays supported: a responder
/// whose own row arrived digest-only (or a peer older than this field) has the
/// digest but not the bytes. Such an item verifies and stores card-less,
/// which is the behaviour every peer had before previews rode backfill.
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
/// ts/text. Every signer and verifier fills this from the message at hand; all
/// `Option` because older wire payloads omit them. An absent field and an
/// empty-string field are payload-equivalent (both serialize as "").
///
/// `lp_digest` is the hex [`link_preview_digest`] — callers holding a full
/// [`LinkPreviewRef`] compute it; sync/archive carriers pass the stored digest
/// straight through.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct SignedExtras<'a> {
    pub mid: Option<&'a str>,
    pub reply_to: Option<&'a str>,
    pub file_id: Option<&'a str>,
    pub order_us: Option<i64>,
    pub lp_digest: Option<&'a str>,
}

/// Canonical v2 signing payload:
///   hollow-msg2:{type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}
/// Every field before `text` is colon-free (UUIDs / hex hashes / a number / a
/// hex digest), so `text` — the only field that may contain a colon — stays
/// LAST, exactly like v1, and the layout is unambiguous.
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
    format!("hollow-msg2:{msg_type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp}:{text}")
}

/// Sign a message over the canonical v2 payload. Every sign site in the crate
/// goes through here — the name keeps its `_versioned` suffix so the pairing
/// with [`verify_message_signature_v2`] stays obvious at the call sites.
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

/// Verify a message signature against the v2 payload — and ONLY the v2 payload.
///
/// There is deliberately no v1 fallback (dropped in 0.8.5, rollout step 3). A
/// fallback to a weaker payload is a downgrade oracle: the attacker, not the
/// sender, chooses which format is checked, so every structured field the v1
/// grammar omits (mid / reply_to / file_id / order_us / link-preview digest)
/// stays graftable on any v1-signed row. Do NOT reintroduce one.
///
/// Reuses `pk_cache` across a batch. A missing signature returns false.
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
    let v2 = message_signing_payload_v2(msg_type, context, sender_peer_str, ts, extras, text);
    verify_message_signature_cached(sender_peer_str, sig_b64, pk_b64, &v2, pk_cache)
}

// -- Signed profiles (0.8.5) --
//
// Profile attribution used to come from the TRANSPORT: `ProfileUpdate` has no
// sender field, so the handler uses the peer the socket reports. Sound — until
// `ProfileRelay`, which exists so a peer can hand us a cached copy of a THIRD
// party's profile and carries its own `source_peer_id`. That field was
// attacker-chosen and the only gate was an `updated_at` comparison the same
// attacker controls: send `ProfileRelay { source_peer_id: <victim>,
// display_name: "Admin", updated_at: i64::MAX }` and the victim's display name
// and avatar are overwritten in our DB permanently — no genuine update can ever
// beat that timestamp again. It is a plaintext frame, so the relay could do it
// too.
//
// Fix: the profile OWNER signs; relayers forward the signature; receivers
// verify. The signature is stored alongside the profile so it can be forwarded
// on the next hop.
//
// WHAT IS BOUND, and why not everything: exactly the fields `ProfileRelay`
// carries. A relayer rebuilds the frame from its own DB, so binding anything it
// does not forward (banner, showcase board/assets) would make every relayed
// profile fail to verify. Banner and showcase reach us only over the
// transport-attested `ProfileUpdate` / `ProfileRequest` paths, where the sender
// IS the subject. Blobs are bound by CONTENT HASH, not bytes: the announce path
// is deliberately light (hashes only, no blobs — see
// `feedback_profile_light_announce_bandwidth_leak`) while the relay path
// carries real avatar bytes, and a hash verifies identically on both.

/// Canonical payload for a profile signature.
///
/// Every field is length-prefixed into a SHA-256 digest rather than joined with
/// a delimiter: `display_name` / `status` / `about_me` are free text and may
/// contain any character, so a `:`-joined payload would let one field's content
/// impersonate the next field's boundary.
pub(crate) fn profile_signing_payload(
    peer_id: &str,
    updated_at: i64,
    display_name: &str,
    status: &str,
    about_me: &str,
    twitch_username: &str,
    avatar_hash: &str,
) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(updated_at.to_le_bytes());
    for field in [peer_id, display_name, status, about_me, twitch_username, avatar_hash] {
        h.update((field.len() as u64).to_le_bytes());
        h.update(field.as_bytes());
    }
    format!("hollow-profile1:{}", hex::encode(h.finalize()))
}

/// Sign our own profile with the MASTER keypair — profiles are a per-identity
/// artifact, and every receiver keys them on the master (device→master collapse
/// happens before the lookup).
#[allow(clippy::too_many_arguments)]
pub(crate) fn sign_profile(
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    peer_id: &str,
    updated_at: i64,
    display_name: &str,
    status: &str,
    about_me: &str,
    twitch_username: &str,
    avatar_hash: &str,
) -> (Option<String>, Option<String>) {
    let payload = profile_signing_payload(
        peer_id, updated_at, display_name, status, about_me, twitch_username, avatar_hash,
    );
    sign_message(master_keypair, pub_key_b64, &payload)
}

/// `true` = this profile is authentic for `peer_id`. REQUIRED at every ingest
/// path (absent is refused, same rule as backfill): the whole point is that a
/// forwarder cannot assert a third party's profile, and "no signature" is the
/// cheapest way to be a forwarder with nothing to prove.
#[allow(clippy::too_many_arguments)]
pub(crate) fn verify_profile_signature(
    peer_id: &str,
    updated_at: i64,
    display_name: &str,
    status: &str,
    about_me: &str,
    twitch_username: &str,
    avatar_hash: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
) -> bool {
    let payload = profile_signing_payload(
        peer_id, updated_at, display_name, status, about_me, twitch_username, avatar_hash,
    );
    verify_message_signature(peer_id, sig_b64, pk_b64, &payload)
}

// -- The support-credentials field signature (2026-09-03) --
//
// `support_creds` sits OUTSIDE `profile_signing_payload` on purpose: every
// entry inside it already binds the identity with a blind signature, so a
// rewritten entry is worthless and folding the field into the profile payload
// would break the profile signature against every shipped client for nothing.
//
// That covers FORGERY and misses DENIAL. On the plaintext
// `HavenMessage::ProfileUpdate` fallback the field is a JSON string a relay
// can rewrite to `""` in flight; the profile signature still verifies, and
// `sanitize_incoming_support_creds(Some(""))` is the holder's explicit clear.
// Per receiver, cosmetic, and restored by the holder's next genuine announce
// — but a poisoned row is itself a publish source once a sibling reads it.
//
// So the field gets its OWN signature, under the same master key, over
// `(master, updated_at, field)`, and it is REQUIRED: no valid signature, no
// field, and the receiver preserves what it already stored. `Some("")` is
// covered too, because the explicit clear is the one a relay most wants to
// forge.
//
// It was briefly softer than that. An unsigned field applied unless the master
// had been caught signing once before, pinned on `user_profiles`. That pin can
// never be set for a master whose FIRST announce is stripped, so a relay that
// stripped the field and its signature from the first frame onward held that
// master on the unsigned branch forever and could write the field itself. A
// baseline learned from the network is worth nothing against an attacker who
// is present for the baseline, so the rule is now just the signature. Old
// clients ignore the field and are unaffected; a client old enough to send the
// field without a signature has it preserved rather than applied.

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
/// REJECTS, never logs-and-continues: the caller treats `false` as "the field
/// is ABSENT" and preserves whatever is stored. `pk_b64` is the profile's own
/// master public key, which the profile signature has already bound to
/// `master_peer_id`; it is re-derived here anyway so this function is safe to
/// call on its own.
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
    // Bind the key to the master the field claims to come from, exactly as
    // `verify_message_signature` does: a real signature by somebody else is
    // not a signature by this identity.
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
/// SECURITY — every segment earns its place:
/// * `sender_device` — the receiver checks `derive(pk) == sender_device`, so the
///   signature is bound to the peer_id the frame claims to come from. This is
///   the whole point: it links the Curve25519 Olm keys (which the relay hands
///   over) to the Ed25519 identity (which the relay cannot forge).
/// * `recipient_device` — stops a bundle addressed to us being reflected at a
///   third party, and vice versa.
/// * both keys — stops a valid signature being re-paired with substituted keys.
/// * `ts` — freshness; see [`KEY_EXCHANGE_SKEW_SECS`].
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
/// SECURITY: a KeyRequest makes the receiver TEAR DOWN a working Olm session
/// (see the handler in swarm.rs), so an unauthenticated one is a remote
/// session-reset primitive against any peer. Signing it means only the real
/// peer can trigger that teardown.
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
/// Signed with the DEVICE keypair (not the master): the receiver knows us by our
/// device peer_id (that is what the relay reports and what the Olm session is
/// keyed on), so a device signature is self-verifying with no resolver lookup.
/// The master→device authorization is a separate, already-enforced link
/// (`verify_device_list`), and the two compose into the full chain.
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
    /// No signature at all — a client older than the signed-key-exchange
    /// rollout. Tolerated during phase 1, refused once
    /// [`REQUIRE_SIGNED_KEY_EXCHANGE`] flips.
    Unsigned,
    /// Signature present but wrong, stale, or addressed elsewhere. ALWAYS
    /// refused — no legitimate client produces this.
    Invalid,
}

/// Phase 2 switch for the signed-key-exchange rollout.
///
/// `false` (phase 1): we SIGN everything we send and reject any bundle whose
/// signature is present-but-bad, while still accepting unsigned bundles from
/// clients that predate this change. An active attacker can still strip the
/// signature during this window — the log line is the tell.
///
/// `true` (phase 2): unsigned key exchange is refused outright, which fully
/// closes the substitution attack. Flip this one release after phase 1 ships,
/// once clients have had time to auto-update. Flipping early wedges key
/// exchange with every client that has not updated.
///
/// PHASE 2 IS LIVE (set `true` 2026-07-23). Shipping straight to enforcement
/// rather than soaking through a phase-1 release: phase 1 still tolerates
/// unsigned bundles, so the substitution attack stays open during the window,
/// and the fix lives in a PUBLIC repo — publishing "here is the hole" while it
/// is still exploitable is worse than the compatibility cost.
///
/// Compatibility cost, accepted knowingly: a client that has not updated cannot
/// complete NEW Olm key exchange with an updated one. Existing sessions are
/// unaffected (a live session never requests a bundle), so the impact is limited
/// to new contacts and re-keys with stale peers, and it self-heals on update.
pub(crate) const REQUIRE_SIGNED_KEY_EXCHANGE: bool = true;

/// Verify the authentication on an inbound key-exchange frame.
///
/// `sender_device` is the peer_id the transport reports as the sender;
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

    // Signed by the device it claims to come from? `verify_message_signature`
    // re-derives the peer_id from `pk` and refuses a mismatch, so this binds the
    // signature to `sender_device` itself.
    if !verify_message_signature(sender_device, sig, pk, payload) {
        return KeyExchangeAuth::Invalid;
    }

    KeyExchangeAuth::Verified
}

/// True when an inbound key-exchange frame from `sender_device` must be refused
/// because that device is not in the signed device list of the master it maps
/// to.
///
/// SECURITY: a signature alone proves only that SOME device produced the
/// bundle. Without this, a hostile relay could mint a fresh keypair, sign a
/// bundle with it, report the frame as coming from that new device id, and
/// establish a session in the victim's name. Binding to the master's
/// master-SIGNED device list is what makes the identity claim mean something.
///
/// A device we have never heard of resolves to itself and is allowed through:
/// that is the single-device / first-contact case, where `sender_device` IS the
/// master peer_id the user obtained out of band, so the signature check above
/// already proves authenticity end to end.
///
/// INVARIANT this rests on: every id in `devices_for(master)` got there from a
/// list the master SIGNED and that NAMED the device delivering it
/// ([`device_list_binds_sender`], enforced in [`ingest_device_list`]). While a
/// delivering device could fold itself in, this check read a set the attacker
/// could write to and so authorised the attacker's own session.
pub(crate) fn key_exchange_device_unauthorized(sender_device: &str) -> bool {
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

// -- Carried Olm key exchange (async friending) --

/// How long a bundle CARRIED inside a friend request stays usable.
///
/// Deliberately NOT [`KEY_EXCHANGE_SKEW_SECS`]: that 300s rule guards a LIVE
/// bundle, which is a round trip between two co-present devices and has no
/// business surviving a rotation. A carried bundle has the opposite job. It sits
/// in the relay's mailbox until the recipient next boots, which for the whole
/// point of async friending may be days later, so a clock-tight rule would make
/// the feature impossible. What stops a replay here is that the one-time key is
/// single-use: the second use of the same bundle builds nothing.
///
/// The two rules stay in SEPARATE functions on purpose. Loosening the live path
/// to serve this one would have widened the live replay window for every peer.
pub(crate) const MAX_CARRIED_BUNDLE_AGE_SECS: i64 = 7 * 24 * 3600;

/// Canonical payload for signing a [`CarriedBundle`].
///
/// Format:
/// "hollow-carried-keybundle:{sender_device}:{recipient_master}:{identity_key}:{one_time_key}:{ts}"
///
/// The PREFIX differs from [`key_bundle_signing_payload`] and the third segment
/// names a MASTER rather than a device, so a carried bundle can never verify as a
/// live one (or the reverse) even if an attacker reflects the bytes: the two
/// domains produce different signed messages for the same key material.
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
/// REJECTS (returns false); never logs-and-continues. Gate order mirrors the live
/// path (`verify_key_exchange` + `key_exchange_device_unauthorized`):
/// 1. the signature verifies under `device_pk_b64` over the CARRIED payload, and
///    the key derives to the device the payload names (so a valid signature can
///    never be re-paired with substituted Olm keys);
/// 2. the sender's own device list is master-signed and genuinely lists that
///    device, un-revoked (a signature alone proves only that SOME device signed);
/// 3. the bundle is addressed to OUR master (blocks reflecting a bundle at a
///    third party);
/// 4. freshness, by the CARRIED rule: at most `MAX_CARRIED_BUNDLE_AGE_SECS` old,
///    and never from further than `KEY_EXCHANGE_SKEW_SECS` in the future.
pub(crate) fn verify_carried_bundle(
    our_master: &str,
    sender_device_list: &SignedDeviceList,
    b: &CarriedBundle,
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

    // 2. That device must speak for the master the list claims.
    if !verify_device_list(sender_device_list) {
        return false;
    }
    if sender_device_list.revoked.iter().any(|r| r == &sender_device) {
        return false;
    }
    if !sender_device_list.devices.iter().any(|d| d == &sender_device) {
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
/// Both `devices` and `revoked` MUST be sorted before calling so the payload is
/// deterministic. The trailing `:{revoked_csv}` segment is present even when
/// `revoked` is empty (Step 7) — one signature thus covers adds AND removes under
/// one version. NOTE: this means a pre-Step-7 4-segment signature will not verify
/// under this code; safe because lists are verified ONLY at receive time and stored
/// lists keep their incoming sig (never re-verified), so both ends ship together.
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

/// Build a master-signed [`SignedDeviceList`] for the given device peer_ids and
/// revoked tombstones. `master` is the master keypair (the cross-device identity).
/// Both `devices` and `revoked` are sorted/deduped internally so the signed payload
/// is canonical. Any id present in `revoked` is removed from `devices` (a revoked id
/// can never coexist as an active device).
pub(crate) fn build_signed_device_list(
    master: &crate::identity::native_identity::NativeKeypair,
    version: u64,
    mut devices: Vec<String>,
    mut revoked: Vec<String>,
) -> SignedDeviceList {
    use base64::engine::general_purpose::STANDARD as B64;
    revoked.sort();
    revoked.dedup();
    // A revoked id is never an active device.
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

/// Verify a received [`SignedDeviceList`]: the master pubkey must derive to the
/// claimed `master_peer_id`, and the signature must validate over the canonical
/// payload. Does NOT enforce version monotonicity — that is the DB layer's job
/// (it has the previously-seen version). Returns true iff cryptographically sound.
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
    // Devices AND revoked must be sorted as signed; verify over the canonical
    // payload using sorted copies so an attacker can't reorder/strip either array
    // post-signing.
    let mut devices = list.devices.clone();
    devices.sort();
    let mut revoked = list.revoked.clone();
    revoked.sort();
    let payload =
        device_list_signing_payload(&list.master_peer_id, list.version, &devices, &revoked);
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// `true` = this master-signed list actually speaks for the device that
/// DELIVERED it.
///
/// SECURITY (CRYPTO-1): [`verify_device_list`] proves a list was signed by the
/// master it names and says NOTHING about who handed it over. Signed lists ride
/// every profile announce in the clear, so anyone who has seen one can replay it
/// from their own socket. Without this check the receiver binds the DELIVERING
/// device to that master, and from then on the victim's DM fan-out reaches the
/// attacker, `key_exchange_device_unauthorized` waves its Olm session through on
/// the same poisoned set, and CRDT role checks resolve through it too.
///
/// The rule: the delivering device is named in the signed `devices`, or IS the
/// master itself (the legacy keystone that published `devices = [master]`), and
/// is not tombstoned. The `ServerJoinRequest` and `FriendReject` arms already
/// gate their carried lists this way at the call site; this is the same
/// predicate, in the one place every ingest path goes through.
pub(crate) fn device_list_binds_sender(list: &SignedDeviceList, sender_peer_id: &str) -> bool {
    if list.revoked.iter().any(|r| r == sender_peer_id) {
        return false;
    }
    sender_peer_id == list.master_peer_id
        || list.devices.iter().any(|d| d == sender_peer_id)
}

// --- Sibling proof handshake (anti-mis-link) -------------------------------------
//
// A peer joining our own `inbox:{master}` room used to be trusted DIRECTLY as our
// sibling device. But the friend-request protocol makes the REQUESTER join the
// TARGET's inbox to deliver the request (social.rs), so a STRANGER lands in our
// inbox and was mis-merged as our device (resolver poisoning + device-list merge +
// friend-list leak + auto snapshot/link). The fix: before any merge we challenge an
// unproven inbox peer to sign a fresh nonce with the SHARED MASTER key. Only a
// genuine sibling holds it; a stranger holds only its own master key and fails the
// pubkey→our-master binding. Mirrors the device-list sign/verify template above.

/// Canonical signing payload for the sibling proof. Binds the proof to OUR master
/// peer_id, the CHALLENGED device id, and a fresh nonce so a captured response can't
/// be replayed against a different master/device/nonce.
pub(crate) fn sibling_proof_payload(
    master_peer_id: &str,
    device_peer_id: &str,
    nonce: &str,
) -> String {
    format!("hollow-sibling:{master_peer_id}:{device_peer_id}:{nonce}")
}

/// Sign a sibling proof with the (shared) master key. `device_peer_id` is OUR OWN
/// device id (the responder's). Returns `(sig_b64, master_pubkey_b64)` to put in a
/// [`HavenMessage::SiblingProveResponse`].
pub(crate) fn build_sibling_proof(
    master: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    nonce: &str,
) -> (String, String) {
    use base64::engine::general_purpose::STANDARD as B64;
    let payload = sibling_proof_payload(&master.peer_id(), device_peer_id, nonce);
    let sig = master.sign(payload.as_bytes());
    (B64.encode(sig), B64.encode(master.public_key_protobuf()))
}

/// Verify a sibling proof. `claimed_master_peer_id` is OUR OWN master peer_id (the
/// challenger): the response's pubkey must derive to it (proving the responder holds
/// OUR master key), and the signature must validate over the canonical payload built
/// from our master + the device id WE challenged (`challenged_device_peer_id`, taken
/// from the routing layer — never a value the responder self-reports) + the nonce.
pub(crate) fn verify_sibling_proof(
    claimed_master_peer_id: &str,
    challenged_device_peer_id: &str,
    nonce: &str,
    sig_b64: &str,
    master_pubkey_b64: &str,
) -> bool {
    use base64::engine::general_purpose::STANDARD as B64;
    use crate::identity::native_identity::NativeKeypair;

    let Ok(pk_bytes) = B64.decode(master_pubkey_b64) else {
        return false;
    };
    // Bind pubkey → OUR claimed master peer_id (a stranger's own-key pubkey derives
    // to a different peer_id and is rejected here).
    match NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) {
        Some(derived) if derived == claimed_master_peer_id => {}
        _ => return false,
    }
    let Ok(sig_bytes) = B64.decode(sig_b64) else {
        return false;
    };
    let payload =
        sibling_proof_payload(claimed_master_peer_id, challenged_device_peer_id, nonce);
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// Build OUR OWN master-signed device list to attach to outbound profile syncs.
///
/// Reads the current device set + version persisted under our master peer_id and
/// re-signs it with the master key. On a brand-new/single-device install the set
/// is just `[device_peer_id]`; QR-linking (Step 4) adds devices and bumps the
/// version. If we have never persisted a self list yet, this seeds version 1 with
/// the single local device and persists it so future reads are monotonic.
///
/// Returns `None` only if the DB is unavailable — callers send the profile
/// without a device list in that case (back-compat, no crash).
pub(crate) fn build_local_device_list(
    master: &crate::identity::native_identity::NativeKeypair,
    device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<SignedDeviceList> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let master_peer_id = master.peer_id();

    // Load whatever we've persisted for ourselves (devices + revoked + version).
    // Absent = first run → seed version 1 with just this device, no revocations.
    let (devices, revoked, version) = match store.load_device_list(&master_peer_id) {
        Ok(Some(list)) => {
            // Ensure THIS device is in the set (migration/first-publish safety) and
            // never tombstoned (we can't revoke the device we're running on).
            let mut revoked = list.revoked.clone();
            revoked.retain(|r| r != device_peer_id);
            let mut devs = list.devices.clone();
            let self_added = !devs.iter().any(|d| d == device_peer_id);
            if self_added {
                devs.push(device_peer_id.to_string());
            }
            // Strip a stale MASTER-as-device entry. A legacy keystone install (where
            // `device_peer_id == master`) wrote `devices = [master]`; once a DISTINCT
            // device key exists (a re-import / rotation, so `device != master`), the
            // bare master is NOT a transport device — no socket ever authenticates as
            // it, so a friend who only learns `[master]` can never map our real device
            // → master and our DMs/presence/friend-row key wrong. Drop it so we publish
            // only real device ids. NEVER strip when device == master (a genuine sole
            // keystone that legitimately is its own device + owns its MLS leaf).
            let master_stripped = device_peer_id != master_peer_id
                && devs.iter().any(|d| d == &master_peer_id);
            if master_stripped {
                devs.retain(|d| d != &master_peer_id);
            }
            // Membership changed → bump version so peers accept the update.
            if self_added || master_stripped || revoked.len() != list.revoked.len() {
                (devs, revoked, list.version.saturating_add(1))
            } else {
                (devs, revoked, list.version.max(1))
            }
        }
        _ => (vec![device_peer_id.to_string()], Vec::new(), 1),
    };

    let signed = build_signed_device_list(master, version, devices, revoked);

    // Persist our own list so device_list_version() stays monotonic across
    // restarts and the resolver warms our own devices on next boot.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    if let Ok(json) = serde_json::to_string(&signed) {
        let _ = store.save_device_list(
            &signed.master_peer_id, &json, signed.version, &signed.devices, now,
        );
    }
    // Keep the resolver in sync with our own devices immediately.
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);

    Some(signed)
}

/// Revoke one of OUR OWN devices (Step 7). Mutates our master-signed device list:
/// removes `target_device` from `devices`, adds it to `revoked` (tombstone), bumps
/// the version, re-signs with the master key, persists, prunes the resolver. Returns
/// the freshly re-signed list (`None` on a guard failure or DB error).
///
/// Guards: refuses to revoke the device we're running on (`local_device_peer_id`),
/// and refuses an id that does not currently belong to us (not in our `devices` and
/// not already a resolver-known device of our master). Idempotent for an id already
/// revoked (returns the current signed list unchanged in `revoked`).
pub(crate) fn revoke_own_device(
    master: &crate::identity::native_identity::NativeKeypair,
    local_device_peer_id: &str,
    target_device: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<SignedDeviceList> {
    if target_device == local_device_peer_id {
        hollow_log!("[HOLLOW-REVOKE] Refused to revoke the device we are running on");
        return None;
    }
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let master_peer_id = master.peer_id();
    let (mut devices, mut revoked, version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&master_peer_id) {
            Ok(Some(list)) => (list.devices.clone(), list.revoked.clone(), list.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    // Ensure THIS device stays present (never tombstoned).
    if !devices.iter().any(|d| d == local_device_peer_id) {
        devices.push(local_device_peer_id.to_string());
    }
    // The target must be one of OUR devices (in the active set, or a resolver-known
    // device of our master — covers a live device id not yet folded into the list).
    let belongs = devices.iter().any(|d| d == target_device)
        || super::resolver::resolve(target_device) == master_peer_id;
    if !belongs {
        hollow_log!("[HOLLOW-REVOKE] Refused to revoke {target_device}: not one of our devices");
        return None;
    }
    if revoked.iter().any(|r| r == target_device) && !devices.iter().any(|d| d == target_device) {
        // Already revoked and not active — nothing to change. Re-sign current state
        // so the caller still has a list to re-announce (idempotent).
        let signed = build_signed_device_list(master, version.max(1), devices, revoked);
        super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
        return Some(signed);
    }
    devices.retain(|d| d != target_device);
    if !revoked.iter().any(|r| r == target_device) {
        revoked.push(target_device.to_string());
    }
    let next_version = version.saturating_add(1).max(1);
    let signed = build_signed_device_list(master, next_version, devices, revoked);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let json = serde_json::to_string(&signed).ok()?;
    if let Err(e) = store.save_device_list(
        &signed.master_peer_id, &json, signed.version, &signed.devices, now,
    ) {
        hollow_log!("[HOLLOW-REVOKE] Failed to persist revocation: {e}");
        return None;
    }
    // Drop the revoked device from the in-memory resolver, then re-seed our survivors.
    super::resolver::forget(target_device);
    // Phantom-chat guard on the revoker too: drop any lingering DMs/typing from the
    // device we just revoked until it self-nukes / disconnects.
    super::resolver::mark_revoked(std::slice::from_ref(&target_device.to_string()));
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
    hollow_log!(
        "[HOLLOW-REVOKE] Revoked own device {target_device} → list now {} devices, {} revoked (v{})",
        signed.devices.len(), signed.revoked.len(), signed.version
    );
    Some(signed)
}

/// Tombstone EVERY one of our devices EXCEPT the one we're running on — a single
/// version bump that revokes all siblings at once. This is the real, propagating
/// teardown behind the "Reset Device List" button: unlike a blunt local wipe (which
/// the grow-only merge simply regrows on the next profile exchange), every sibling
/// becomes a permanent `revoked` tombstone in our master-signed list, so friends
/// converge and can never un-revoke them, and each revoked sibling self-nukes on
/// receiving the v+1 list. Returns the re-signed list + the ids that were tombstoned
/// this call (so the caller can push the list to each for `SelfRevoked`). `None` on
/// a DB error or when there's nothing to revoke (already sole device).
pub(crate) fn revoke_all_other_devices(
    master: &crate::identity::native_identity::NativeKeypair,
    local_device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<(SignedDeviceList, Vec<String>)> {
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let master_peer_id = master.peer_id();
    let (mut devices, mut revoked, version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&master_peer_id) {
            Ok(Some(list)) => (list.devices.clone(), list.revoked.clone(), list.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    // Fold in any resolver-known device ids of ours that haven't made it into the
    // persisted list yet (live siblings, ghosts from re-link cycles) so they ALL get
    // tombstoned — not just the ones already written down.
    for d in super::resolver::devices_for(&master_peer_id) {
        if d != local_device_peer_id && !devices.contains(&d) && !revoked.contains(&d) {
            devices.push(d);
        }
    }
    // Everything that isn't this device becomes a tombstone.
    let to_revoke: Vec<String> = devices
        .iter()
        .filter(|d| d.as_str() != local_device_peer_id)
        .cloned()
        .collect();
    if to_revoke.is_empty() {
        hollow_log!("[HOLLOW-REVOKE] Reset device list: already the sole device, nothing to revoke");
        return None;
    }
    for d in &to_revoke {
        if !revoked.iter().any(|r| r == d) {
            revoked.push(d.clone());
        }
    }
    // Sole surviving device = us.
    let devices = vec![local_device_peer_id.to_string()];
    let next_version = version.saturating_add(1).max(1);
    let signed = build_signed_device_list(master, next_version, devices, revoked);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let json = serde_json::to_string(&signed).ok()?;
    if let Err(e) = store.save_device_list(
        &signed.master_peer_id, &json, signed.version, &signed.devices, now,
    ) {
        hollow_log!("[HOLLOW-REVOKE] Reset device list: failed to persist: {e}");
        return None;
    }
    // Prune every revoked id from the in-memory resolver + guard against phantom
    // chats from any that are still momentarily alive, then re-seed our survivor.
    for d in &to_revoke {
        super::resolver::forget(d);
    }
    super::resolver::mark_revoked(&to_revoke);
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
    hollow_log!(
        "[HOLLOW-REVOKE] Reset device list: revoked {} sibling(s) → sole device (v{})",
        to_revoke.len(), signed.version
    );
    Some((signed, to_revoke))
}

/// Union a single sibling device id into OUR OWN master-signed device list.
///
/// Used by the inbox-proof path: a peer joining our own `inbox:{master}` room is,
/// by definition, our own device — but a freshly-imported sibling has no profile
/// and never sends a ProfileUpdate carrying a device list, so the normal
/// `ingest_sibling_device_list` merge never fires for it and our list would stay
/// at one device forever. This adds the proven sibling id directly: union, re-sign
/// with a bumped version, persist, seed the resolver. Returns `true` if the id was
/// new (so the caller re-announces our profile to friends).
pub(crate) fn merge_sibling_device_id(
    master: &crate::identity::native_identity::NativeKeypair,
    local_device_peer_id: &str,
    sibling_device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return false;
    };
    let master_peer_id = master.peer_id();
    let (mut devices, revoked, version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&master_peer_id) {
            Ok(Some(list)) => (list.devices.clone(), list.revoked.clone(), list.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    if !devices.iter().any(|d| d == local_device_peer_id) {
        devices.push(local_device_peer_id.to_string());
    }
    // A revoked sibling id must never be re-admitted by the inbox proof — this is
    // the same-peer-id resurrection guard. A reinstalled phone comes back with a
    // FRESH random device id and so is not blocked here.
    if revoked.iter().any(|r| r == sibling_device_peer_id) {
        super::resolver::seed_self(&master_peer_id, &devices);
        return false;
    }
    if devices.iter().any(|d| d == sibling_device_peer_id) {
        // Already known — keep the resolver warm, but nothing to re-announce.
        super::resolver::seed_self(&master_peer_id, &devices);
        return false;
    }
    devices.push(sibling_device_peer_id.to_string());
    let next_version = version.saturating_add(1).max(1);
    let signed = build_signed_device_list(master, next_version, devices, revoked);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    if let Ok(json) = serde_json::to_string(&signed) {
        let _ = store.save_device_list(
            &signed.master_peer_id, &json, signed.version, &signed.devices, now,
        );
    }
    super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
    hollow_log!(
        "[HOLLOW-DEVICES] Merged inbox sibling {sibling_device_peer_id} → own device set now {} (v{})",
        signed.devices.len(), signed.version
    );
    true
}

/// Outcome of ingesting a device list. The swarm call site consumes this to drive
/// crypto enforcement (Step 7) and self-re-announce.
/// - `our_devices_grew`: a sibling merge added one of OUR OWN device ids (caller
///   re-announces our profile so friends converge — the historical `bool` return).
/// - `newly_revoked`: device ids that became tombstoned THIS ingest. The caller
///   (which holds `&mut olm`/`&mut mls`) drops the Olm session to each and, if it
///   is the MLS coordinator for a shared server, enqueues the single leaf for
///   removal. Empty on every pre-Step-7 / single-device path.
#[derive(Default)]
pub(crate) struct IngestOutcome {
    pub our_devices_grew: bool,
    pub newly_revoked: Vec<String>,
}

/// Ingest a device list received on a peer's profile sync.
///
/// Verifies the signature, unions devices (replay-safe — see body), applies
/// revocation tombstones (Step 7, max-version-wins), and on a change persists it +
/// updates the resolver + emits `DeviceListUpdated`. A `None` list (old client, or
/// a self-profile we sent) is a no-op. A list for our OWN master goes to the
/// sibling-merge path (we are the authority for our own list, a friend can't
/// rewrite it — but a sibling can union into it).
pub(crate) async fn ingest_device_list(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master_peer_id: &str,
    local_device_peer_id: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    sender_peer_id: &str,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    list: Option<SignedDeviceList>,
    db_path: &str,
    db_passphrase: &str,
) -> IngestOutcome {
    let Some(list) = list else { return IngestOutcome::default() };
    if list.master_peer_id.is_empty() || list.devices.is_empty() {
        return IngestOutcome::default();
    }
    // Multi-device: a list for OUR OWN master came from one of our other devices
    // (a sibling, same imported mnemonic → same master key, so it is validly
    // signed). We must NOT blindly replace our list, but we MUST learn about the
    // sibling's device id — otherwise the resolver never maps sibling→master,
    // `same_identity` stays false, and neither sibling sync nor a friend's
    // device-collapse can work. Merge (union) the sibling's devices into ours,
    // re-sign with a bumped version, persist, update the resolver, re-publish so
    // friends converge on the full set, and (if the sibling is new) hand it our
    // friend list so it can join their DM rooms.
    if list.master_peer_id == local_master_peer_id {
        let (grew, newly_revoked) = ingest_sibling_device_list(
            event_tx, local_master_peer_id, local_device_peer_id, master_keypair,
            sender_peer_id, ws_cmd_tx, ws_room_peers, list, db_path, db_passphrase,
        ).await;
        return IngestOutcome { our_devices_grew: grew, newly_revoked };
    }
    if !verify_device_list(&list) {
        hollow_log!(
            "[HOLLOW-DEVICES] Rejected device list for {}: bad signature",
            list.master_peer_id
        );
        return IngestOutcome::default();
    }
    // SECURITY (CRYPTO-1): the signature says who WROTE the list, never who
    // delivered it, and a signed list is public the moment it is announced. The
    // delivering device has to be named in it (or be the legacy master-as-device)
    // or the whole list is dropped: a replay from an unlisted socket used to bind
    // that socket to the victim's master, which hands the attacker the victim's
    // DM fan-out, Olm authorisation and role checks in one move.
    if !device_list_binds_sender(&list, sender_peer_id) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED device list for {}: delivering device {sender_peer_id} is not in the signed list",
            list.master_peer_id
        );
        return IngestOutcome::default();
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return IngestOutcome::default();
    };
    // Load what we already hold for this master (devices + revoked + version).
    let (prev_devices, prev_revoked, prev_version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(&list.master_peer_id) {
            Ok(Some(cur)) => (cur.devices.clone(), cur.revoked.clone(), cur.version),
            _ => (Vec::new(), Vec::new(), 0),
        };
    // TOMBSTONES — max-version-wins (Step 7). A higher-version list is the latest
    // master word and may both add AND un-revoke; a replay (version <= prev) keeps
    // our prev revoked set, so it can never shrink the tombstones (can't un-revoke).
    let new_revoked: Vec<String> = if list.version > prev_version {
        let mut r = list.revoked.clone();
        r.sort();
        r.dedup();
        r
    } else {
        prev_revoked.clone()
    };
    let is_revoked = |id: &str| new_revoked.iter().any(|r| r == id);
    // SELF-NUKE (Step 7): if THIS device appears in the revoked set, the identity has
    // cut us off. Tear ourselves down (Dart wipes the data dir + relaunches to a clean
    // Welcome). Defensive here — a friend's list is for a different master so this
    // normally never matches; the real path is the sibling merge below.
    if is_revoked(local_device_peer_id) {
        hollow_log!("[HOLLOW-REVOKE] This device was revoked (friend list) — self-nuking");
        let _ = event_tx.send(NetworkEvent::SelfRevoked).await;
        return IngestOutcome::default();
    }
    // Guard the DM/typing receive path against a just-revoked-but-still-alive device
    // (phantom-chat guard): mark every revoked id of this master so inbound messages
    // from it are dropped until it self-nukes / disconnects.
    if !new_revoked.is_empty() {
        super::resolver::mark_revoked(&new_revoked);
    }
    // Ids that became tombstoned THIS ingest (drive Olm/MLS enforcement at the caller).
    let newly_revoked: Vec<String> = new_revoked
        .iter()
        .filter(|r| !prev_revoked.iter().any(|p| &p == r))
        .cloned()
        .collect();
    // Register the SENDER device → master link. Safe now, and only now: the
    // binding check above proved the master's own signature NAMES this device, so
    // this records a fact the master asserted rather than one the delivery
    // asserted. SKIP if the sender is revoked against our MERGED tombstones — a
    // device we already know is cut off must not re-register itself by delivering
    // a list from before its revocation (that list is too old to name it revoked).
    if sender_peer_id != list.master_peer_id && !is_revoked(sender_peer_id) {
        super::resolver::update(sender_peer_id, &list.master_peer_id);
    }

    // UNION-merge MINUS tombstones, do NOT reject-on-stale. Two devices of one
    // identity each start their list at version 1, so a naive `version <= current`
    // guard makes the SECOND device's list look like a replay and drops it — the
    // friend then only ever learns ONE device (the "offline when the other device
    // is up" bug). Adding device ids is safe; REMOVAL is the signed `revoked` set.
    // So: union(prev, incoming) − new_revoked, keeping the highest version seen.
    let mut merged: Vec<String> = prev_devices.iter().filter(|d| !is_revoked(d)).cloned().collect();
    let mut known: std::collections::HashSet<String> = merged.iter().cloned().collect();
    let mut added = 0u32;
    for d in &list.devices {
        if !is_revoked(d) && !known.contains(d) {
            merged.push(d.clone());
            known.insert(d.clone());
            added += 1;
        }
    }
    // NOTHING is folded in beyond the signed set. The delivering device used to be
    // pushed in here on the theory that delivery proves membership; it proves only
    // that somebody had a copy of the frame. The signed `devices` array is the
    // master's whole word on who its devices are.
    // A revocation removed one or more of our previously-known devices.
    let removed_any = prev_devices.iter().any(|d| is_revoked(d));
    let revoked_changed = new_revoked.len() != prev_revoked.len();
    let nothing_new = added == 0 && !removed_any && !revoked_changed
        && list.version <= prev_version;
    if nothing_new {
        // Truly redundant on the RUST side (same/older list, no new devices) — skip
        // the DB write, but STILL re-warm the resolver AND emit DeviceListUpdated.
        // The event is the load-bearing part: Dart's `deviceLinkProvider` warms
        // ONCE at startup (event_provider) by pulling `get_device_links()`, which
        // RACES the Rust resolver warm-up (`warm_from_links` from `device_links`).
        // If Dart wins that race it caches an empty/partial map and, because a
        // redundant re-ingest used to return here WITHOUT an event, it never
        // refreshed again — so a friend whose device id ≠ master (rotated keystone,
        // e.g. AL = device BVoC / master JJU9) showed OFFLINE until a manual Device
        // List reset forced a fresh (version-bumping) ingest. A peer re-sends its
        // (unchanged v1) list on every room join, so emitting here makes Dart
        // re-pull the now-warm map within seconds of every reconnect — the
        // self-heal that removes the need to ever reset. Cheap + idempotent.
        super::resolver::update_many(
            &list.master_peer_id,
            merged.iter().map(|s| s.as_str()),
        );
        // Re-key any friend row stranded under one of this master's DEVICE ids (a
        // friend added by temporary nickname lands under the device id). Even on the
        // redundant-ingest path, do this — the friend row may have been created AFTER
        // a prior ingest warmed the resolver but BEFORE this re-key existed. Include
        // the SENDER device explicitly: a stale legacy device list can advertise only
        // the master-as-device while the friend actually transmits from a distinct
        // device id (the nickname/WS-auth id), so the sender is the id the friend row
        // is keyed under — and it may NOT appear in `merged`.
        for dev in merged.iter().map(|s| s.as_str()).chain(std::iter::once(sender_peer_id)) {
            if let Ok(true) = store.migrate_friend_to_master(dev, &list.master_peer_id) {
                hollow_log!(
                    "[HOLLOW-FRIENDS] Re-keyed friend {dev} → master {}", list.master_peer_id
                );
            }
        }
        let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
            master_peer_id: list.master_peer_id.clone(),
        }).await;
        return IngestOutcome::default();
    }

    // Persist the union-minus-tombstones. We are NOT this master (self lists go
    // through the sibling path), so we cannot re-sign — store under the higher
    // version with the INCOMING signature/pubkey AND the resolved `new_revoked`
    // set. Verification on re-broadcast is sender-side; observers trust the
    // per-device profile sig path.
    let version = prev_version.max(list.version).max(1);
    let stored = SignedDeviceList {
        master_pubkey_b64: list.master_pubkey_b64.clone(),
        master_peer_id: list.master_peer_id.clone(),
        devices: merged.clone(),
        revoked: new_revoked.clone(),
        version,
        sig_b64: list.sig_b64.clone(),
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let json = match serde_json::to_string(&stored) {
        Ok(j) => j,
        Err(_) => return IngestOutcome::default(),
    };
    // save_device_list rebuilds the device_links reverse index from `devices`, so a
    // revoked id (now absent from `merged`) is dropped from device_links for free.
    if let Err(e) = store.save_device_list(
        &stored.master_peer_id, &json, stored.version, &stored.devices, now,
    ) {
        hollow_log!("[HOLLOW-DEVICES] Failed to save device list: {e}");
        return IngestOutcome::default();
    }
    // Prune the in-memory resolver for revoked ids (the map is insert-only; without
    // this a revoked device keeps resolving to its master until restart), then warm
    // the surviving devices so attribution/self-checks pick them up at once.
    if !new_revoked.is_empty() {
        super::resolver::forget_many(&new_revoked);
    }
    super::resolver::update_many(
        &stored.master_peer_id,
        stored.devices.iter().map(|s| s.as_str()),
    );
    // Re-key any friend row stranded under one of this master's DEVICE ids → the
    // master (a friend added by temporary nickname keys under the device id; the
    // friend system is the one place that stores the raw id). Include the SENDER
    // device explicitly — a stale legacy device list may advertise only the
    // master-as-device while the friend transmits from a distinct device id, so the
    // sender (the id the friend row is keyed under) may NOT be in `stored.devices`.
    // Idempotent.
    for dev in stored.devices.iter().map(|s| s.as_str()).chain(std::iter::once(sender_peer_id)) {
        if let Ok(true) = store.migrate_friend_to_master(dev, &stored.master_peer_id) {
            hollow_log!(
                "[HOLLOW-FRIENDS] Re-keyed friend {dev} → master {}", stored.master_peer_id
            );
        }
    }
    hollow_log!(
        "[HOLLOW-DEVICES] Ingested device list for {} (v{}, {} devices, {} revoked, +{} new)",
        stored.master_peer_id, stored.version, stored.devices.len(),
        stored.revoked.len(), added
    );
    // SECURITY (Issue 1-C): a device joining someone else's identity is the one
    // device-list change that carries an attack signal — it is the shape of
    // "someone linked a device to an account they compromised". Warn visibly.
    // First contact (`prev_devices` empty) establishes a baseline instead; the
    // helper enforces that, and dedups so a reconnect can't re-raise it.
    super::security_alerts::note_new_devices(
        event_tx, db_path, db_passphrase, local_master_peer_id,
        &stored.master_peer_id, &prev_devices, &stored.devices,
    ).await;
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
        master_peer_id: stored.master_peer_id,
    }).await;
    // A FRIEND's device set changed — no self re-broadcast needed (that's for our
    // OWN sibling merges, handled on the self path above). Surface any freshly
    // revoked ids so the caller drops Olm sessions + removes MLS leaves.
    IngestOutcome { our_devices_grew: false, newly_revoked }
}

/// Merge a sibling device's list (for our OWN master) into ours.
///
/// The sibling holds the same master key (imported mnemonic), so its list is
/// validly signed by our master. We take the UNION of device ids — never a
/// removal (removal = revocation, Step 7) — re-sign with a bumped version,
/// persist, update the resolver, and re-publish to friends so they converge on
/// the full device set (fixes the v1-vs-v1 collision where a friend only ever
/// learned ONE of two devices). When the merge reveals a brand-new sibling
/// device, we also hand it our accepted-friend list so it can join their DM
/// rooms (presence on-ramp, Step 2.5).
/// Returns `(our_devices_grew_or_revoked, newly_revoked)`. The first is `true` if
/// OUR OWN list changed (device added OR a tombstone applied) so callers re-broadcast
/// our profile to friends; the second is device ids freshly tombstoned this merge so
/// the caller drops their Olm sessions + removes MLS leaves.
#[allow(clippy::too_many_arguments)]
async fn ingest_sibling_device_list(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master_peer_id: &str,
    local_device_peer_id: &str,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    sender_peer_id: &str,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    list: SignedDeviceList,
    db_path: &str,
    db_passphrase: &str,
) -> (bool, Vec<String>) {
    // The list claims our master — verify it's actually signed by our master key
    // (a forgery would fail; only a real sibling holding the mnemonic can sign).
    if !verify_device_list(&list) {
        hollow_log!(
            "[HOLLOW-DEVICES] Rejected sibling device list from {sender_peer_id}: bad signature"
        );
        return (false, Vec::new());
    }
    // SECURITY (CRYPTO-1): the same binding rule, and it bites hardest here. OUR
    // OWN signed list is the one a stranger is most likely to be holding — we
    // announce it to every friend — and replaying it back at us lands in this
    // function, which hands the sender our accepted-friend list, asks it for its
    // friends and asks it to backfill our DMs. `build_local_device_list` always
    // names the publishing device, so a genuine sibling always passes.
    if !device_list_binds_sender(&list, sender_peer_id) {
        hollow_log!(
            "[HOLLOW-SECURITY] REJECTED device list for {}: delivering device {sender_peer_id} is not in the signed list",
            list.master_peer_id
        );
        return (false, Vec::new());
    }
    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else {
        return (false, Vec::new());
    };

    // Our currently-known device set (+ revoked + version) for our master.
    let (mut devices, our_revoked, our_version): (Vec<String>, Vec<String>, u64) =
        match store.load_device_list(local_master_peer_id) {
            Ok(Some(cur)) => (cur.devices.clone(), cur.revoked.clone(), cur.version),
            _ => (vec![local_device_peer_id.to_string()], Vec::new(), 0),
        };
    // Always include ourselves.
    if !devices.iter().any(|d| d == local_device_peer_id) {
        devices.push(local_device_peer_id.to_string());
    }

    // TOMBSTONES — max-version-wins (Step 7). A sibling's higher-version list is the
    // latest master word (it holds the same master key, all our devices are equal):
    // adopt its revoked set; otherwise keep ours (replay can't un-revoke). We never
    // revoke the device we're running on.
    // SELF-NUKE (Step 7): a sibling (same master key, equal authority) revoked THIS
    // device — our own id is in a HIGHER-version signed revoked set. The identity has
    // cut us off; tear ourselves down (Dart wipes the data dir + relaunches to a clean
    // Welcome). Check the INCOMING revoked set BEFORE we strip self below — we never
    // tombstone ourselves in our OWN published list, but we DO obey a sibling's order.
    if list.version > our_version && list.revoked.iter().any(|r| r == local_device_peer_id) {
        hollow_log!("[HOLLOW-REVOKE] This device was revoked by a sibling (v{} > v{}) — self-nuking", list.version, our_version);
        let _ = event_tx.send(NetworkEvent::SelfRevoked).await;
        return (false, Vec::new());
    }

    let mut merged_revoked: Vec<String> = if list.version > our_version {
        list.revoked.clone()
    } else {
        our_revoked.clone()
    };
    merged_revoked.retain(|r| r != local_device_peer_id);
    merged_revoked.sort();
    merged_revoked.dedup();
    // Phantom-chat guard: mark revoked ids so inbound DMs/typing from a still-alive
    // revoked sibling are dropped until it self-nukes / disconnects.
    if !merged_revoked.is_empty() {
        super::resolver::mark_revoked(&merged_revoked);
    }
    let is_revoked = |id: &str| merged_revoked.iter().any(|r| r == id);
    let newly_revoked: Vec<String> = merged_revoked
        .iter()
        .filter(|r| !our_revoked.iter().any(|p| &p == r))
        .cloned()
        .collect();

    // Union in the sibling's devices, MINUS tombstones; also drop any of our own
    // previously-known devices that are now revoked.
    devices.retain(|d| !is_revoked(d));
    let before: std::collections::HashSet<String> = devices.iter().cloned().collect();
    for d in &list.devices {
        if !is_revoked(d) && !before.contains(d) {
            devices.push(d.clone());
        }
    }

    // Prune the resolver for revoked ids, then learn the surviving union NOW (cheap,
    // keeps same_identity correct after a restart even when nothing changed).
    if !merged_revoked.is_empty() {
        super::resolver::forget_many(&merged_revoked);
    }
    super::resolver::update_many(
        local_master_peer_id,
        devices.iter().map(|s| s.as_str()),
    );

    let removed_any = our_revoked.len() != merged_revoked.len();
    let changed = devices.len() != before.len() || removed_any;
    if changed {
        // Re-sign the merged set with a version strictly greater than both ours
        // and the sibling's, so every observer (and the sibling) accepts it.
        let next_version = our_version.max(list.version).saturating_add(1);
        let signed = build_signed_device_list(
            master_keypair, next_version, devices, merged_revoked.clone(),
        );
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        if let Ok(json) = serde_json::to_string(&signed) {
            let _ = store.save_device_list(
                &signed.master_peer_id, &json, signed.version, &signed.devices, now,
            );
        }
        super::resolver::seed_self(&signed.master_peer_id, &signed.devices);
        hollow_log!(
            "[HOLLOW-MULTIDEV] Merged sibling {sender_peer_id} → device set now {} ({} revoked, v{})",
            signed.devices.len(), signed.revoked.len(), signed.version
        );

        // The merged list is now persisted. We RETURN `changed=true` so the caller
        // (the ProfileUpdate handler, which HAS profile context) re-broadcasts our
        // profile to all current room peers — friends converge on the full device
        // set WHILE we're online, instead of only when our substitute device later
        // joins their DM room (racy, and too late if our original device quits).
        let _ = event_tx.send(NetworkEvent::DeviceListUpdated {
            master_peer_id: signed.master_peer_id,
        }).await;
    }

    // Hand our friend list to the sibling that JUST contacted us (the live
    // `sender_peer_id`), not to whichever ids look "new" in the merged list.
    // Gating on list-diff was fragile: across repeated wipe+reimport tests the
    // stored list accumulates dead device ids, so a reconnecting sibling can
    // already be "known" → no send → the fresh device never gets the friends.
    // The connected sender is the device that actually needs them right now, and
    // the receiver is idempotent (skips friends it already has), so an
    // occasional redundant send is harmless. Skip if the sender is OUR own device
    // id (shouldn't happen — self lists don't reach here) OR if it is revoked (a
    // revoked sibling must not be handed our friend list / pulled from).
    if sender_peer_id != local_device_peer_id && !is_revoked(sender_peer_id) {
        if let Ok(friends) = store.load_friends(Some("accepted")) {
            if !friends.is_empty() {
                let entries: Vec<FriendListEntry> = friends
                    .into_iter()
                    .map(|(pid, status, direction, requested_at, _u)| FriendListEntry {
                        peer_id: pid, status, direction, requested_at,
                    })
                    .collect();
                hollow_log!(
                    "[HOLLOW-MULTIDEV] Sharing {} friends with sibling {sender_peer_id}",
                    entries.len()
                );
                send_message_to_peer(
                    ws_cmd_tx, ws_room_peers,
                    sender_peer_id, HavenMessage::FriendListSync { friends: entries.clone() },
                );
            }
        }
        // Also PULL: ask the sibling for ITS friends. Covers the case where WE
        // are the fresh/empty device and the sibling's push didn't reach us (join
        // timing). Responder replies with FriendListSync. Idempotent + cheap.
        hollow_log!("[HOLLOW-MULTIDEV] Requesting friend list from sibling {sender_peer_id}");
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            sender_peer_id, HavenMessage::FriendListRequest,
        );

        // Multi-device backfill (Step 5): also ask this live sibling for our missed
        // DM history. CRITICAL — sibling detection has TWO paths: the swarm.rs
        // `inbox:{master}` join-proof AND this device-list-ingest (fired by a
        // ProfileUpdate carrying a device list). A sibling may be detected via
        // EITHER, so the DM-backfill request must fire from BOTH or it silently
        // never runs (e.g. when the device list arrives before/without an inbox
        // join). `request_sibling_dm_backfill` throttles per-sibling so the two
        // paths + reconnect re-fires collapse into one request (Step 5.1).
        request_sibling_dm_backfill(
            ws_cmd_tx, ws_room_peers, sender_peer_id, db_path, db_passphrase,
        );
    }

    (changed, newly_revoked)
}

/// Maximum stored length, in BYTES, of a received message body.
pub(crate) const MAX_MESSAGE_BYTES: usize = 4000;

/// Clip a sender-controlled message body to `MAX_MESSAGE_BYTES` on a UTF-8
/// character boundary.
///
/// SECURITY: the naive `text[..4000]` form PANICS when byte 4000 lands inside a
/// multi-byte character (3999 ASCII bytes + one `é` is enough), and the body
/// arrives from a remote peer — a modified client could abort the swarm event
/// loop at will. Walk back to a boundary instead.
pub(crate) fn clip_text(text: String) -> String {
    if text.len() <= MAX_MESSAGE_BYTES {
        return text;
    }
    let mut end = MAX_MESSAGE_BYTES;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_string()
}

/// Sign a message payload with the local keypair.
/// Returns (signature_base64, public_key_base64).
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

    // Bind the public key to the claimed sender: the PeerId derived from this
    // key MUST be the sender the payload names. One canonical derivation
    // (`peer_id_from_pubkey_protobuf`) — the hand-rolled copy that used to live
    // here checked a weaker protobuf header than the verifier itself.
    let Some(derived_pid) = NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes) else {
        return false;
    };
    if derived_pid != sender_peer_str {
        return false;
    }

    // Verify the signature.
    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig) else {
        return false;
    };
    NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, payload.as_bytes())
        .unwrap_or(false)
}

/// Decoded-public-key cache for ONE sync batch: `pk_b64 → (pk_bytes, peer_id
/// DERIVED from those bytes)`.
///
/// SECURITY — the derived peer_id is cached *alongside* the bytes on purpose.
/// The first version cached the bytes only and checked `derive(pk) == sender`
/// on the cache-MISS path, so within a batch a key was bound to whichever
/// sender was seen FIRST:
///
/// ```text
///   item 1:  s = A, pk = A  → derive(pk) == A, cached
///   item 2:  s = B, pk = A  → CACHE HIT, binding check skipped,
///                             A's real signature verified against a payload naming B
/// ```
///
/// A really did sign those bytes, so the Ed25519 check passed and the forgery
/// displayed as VERIFIED in the Message Proof dialog — any server member could
/// attribute arbitrary text to any other member. Reported by itsfolf, 2026-07.
/// Keep the comparison on the HIT path (see `verify_message_signature_cached`).
pub(crate) type PkCache = HashMap<String, (Vec<u8>, String)>;

/// Batch-optimized [`verify_message_signature`]: caches the base64 decode and
/// the PeerId derivation across calls (the expensive per-key work), never the
/// pk→sender *decision*.
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

    // Populate on miss. Only the decode + derivation are cached.
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
/// It used to be `false` in spirit: `Absent` was tolerated everywhere so that
/// history predating per-message signing (e2cc8ab, 2026-03-09) would not be
/// stranded. That tolerance was a message-INJECTION primitive with exactly the
/// shape of the `hidden_at` hole closed in 0.8.4 — a hostile sync responder
/// only had to OMIT the signature, and on the channel path the item carries its
/// own claimed sender (`msg.s`), so an unsigned injection could impersonate any
/// member. Rows landed in the DB and in archive exports; the "unsigned"
/// indicator in the UI is a display detail, not a gate.
///
/// The only thing the tolerance ever bought was avoiding stranded history and
/// diverged peers across a deployed fleet. That cost is not worth an open
/// injection path, so it is gone: pre-signing rows stay where they are and
/// still display, they simply no longer replicate through sync.
pub(crate) const REQUIRE_SIGNED_BACKFILL: bool = true;

/// Outcome of checking the signature on a BACKFILLED (sync) message item.
///
/// `Absent` and `Forged` are both refused under [`REQUIRE_SIGNED_BACKFILL`],
/// but they stay DISTINCT variants on purpose: the log line is the only way to
/// tell "an old peer served pre-signing history" from "someone is injecting
/// messages at us". Collapsing them into one `bool` would throw that away.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BackfillSig {
    /// No signature material at all — pre-signing history, or an injection
    /// attempt that simply omitted the signature. Refused; see
    /// [`REQUIRE_SIGNED_BACKFILL`].
    Absent,
    /// Signature present and it verifies against the claimed sender.
    Valid,
    /// Signature present and it does NOT verify. REJECT the item — a wrong
    /// signature is not legacy data, it is tampering.
    Forged,
}

impl BackfillSig {
    /// The ONE gate every backfill/fetch call site reads. Keeping it a method
    /// (rather than each site testing variants) means the enforcement rule is
    /// greppable and can only be changed in one place.
    pub(crate) fn is_acceptable(self) -> bool {
        match self {
            BackfillSig::Valid => true,
            BackfillSig::Forged => false,
            BackfillSig::Absent => !REQUIRE_SIGNED_BACKFILL,
        }
    }

    /// Short reason for the rejection log, so support can tell an old peer
    /// from an attack at a glance.
    pub(crate) fn reject_reason(self) -> &'static str {
        match self {
            BackfillSig::Absent => "NO signature (pre-signing history, or stripped in transit)",
            BackfillSig::Forged => "signature present but INVALID",
            BackfillSig::Valid => "accepted",
        }
    }
}

/// Apply the backfill signature rule to one sync item.
///
/// Callers MUST gate on [`BackfillSig::is_acceptable`], never on
/// `== BackfillSig::Forged`. As of 0.8.5 backfill matches live ingest:
///
/// ```text
///   backfill REJECTS an ABSENT signature          (injection primitive)
///   backfill REJECTS a PRESENT-but-INVALID one    (tampering)
///   backfill ACCEPTS only Valid
/// ```
///
/// The history behind that: this used to tolerate `Absent` so pre-signing rows
/// (before e2cc8ab, 2026-03-09) kept replicating. Tolerating absence meant an
/// attacker could inject arbitrary messages — attributed to anyone on the
/// channel path — by omitting the signature, which is the same shape as the
/// `hidden_at` hole closed in 0.8.4. See [`REQUIRE_SIGNED_BACKFILL`].
///
/// `edited_at` selects the timestamp the signature was really made over — an
/// edit is re-signed over the EDIT timestamp and the NEW text
/// (`message_ops::handle_edit_*`), the same rule
/// `archive::loader::verify_one_message` uses. Verifying an edited row against
/// its original `ts` fails every one of them, which is why edits used to skip
/// verification entirely — and why setting `edited_at` was a way around it.
///
/// v2 (0.8.3): verifies-both — the v2 payload (structured `extras` covered)
/// first, the legacy text-only v1 payload as fallback. `extras` are the item's
/// structural fields; edit signatures bind the SAME full extras (the row's
/// structure is immutable under edit), so the edited branch differs only in
/// the timestamp used.
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

/// Check if a peer is reachable via WS relay.
///
/// Multi-device (Phase 6): the relay reports DEVICE peer_ids in rooms, but the
/// caller often asks about a MASTER id (server members, friends). A master is
/// reachable if ANY of its devices is currently in a room. The fast path (exact
/// membership) covers the common single-device case with no resolver cost; the
/// slow path only runs when the exact id isn't present, and resolves room peers
/// to compare identities. `resolve()` returns the input unchanged for unknown
/// peers, so single-device behavior is unaffected.
pub(crate) fn peer_is_reachable(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> bool {
    // Fast path: the exact id is in some room.
    if ws_room_peers.values().any(|peers| peers.contains(peer_str)) {
        return true;
    }
    // Slow path: is any connected device of the SAME identity present? The input
    // may be a DEVICE id (resolve maps it to its master) or a bare MASTER id
    // (resolve returns it UNCHANGED — masters are only VALUES in the link map,
    // never keys except the self-seed). Either way, compare room peers against
    // the resolved target. There must be NO `resolve(peer) == peer → false`
    // early-return here: it would fire for every master id, making a friend or
    // server member with online devices permanently "unreachable" — which
    // silently disabled the owner-preferred coordinator election, MLS recovery
    // targeting, subgroup self-bootstrap, and offline-push classification for
    // every modern (device != master) identity. A genuinely offline
    // single-device peer still returns false: no room peer resolves to it.
    let target_master = super::resolver::resolve(peer_str);
    ws_room_peers.values().any(|peers| {
        peers.iter().any(|p| super::resolver::resolve(p) == target_master)
    })
}

/// The single concrete DEVICE id to address when a caller holds a (possibly
/// master) peer id and needs ONE socket-addressable target. The exact id wins
/// when it is itself in a room (single-device / legacy keystone); otherwise the
/// deterministic lowest online device of the identity. `None` when nothing is
/// online. Pairs with `peer_is_reachable`: reachable ⇒ this returns `Some`.
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

/// Multi-device: the set of LIVE device peer_ids (currently in some WS room) that
/// belong to the same identity as `peer_str`. `peer_str` may be a master id (the
/// friend-list/UI key — no socket authenticates as it) or a device id; either way
/// this returns the concrete online devices to actually send to.
///
/// Used by every TARGETED P2P-signaling send that the UI addresses by master id
/// (call signaling, WebRTC offer/answer/ICE, file requests). Without it those
/// sends hit the bare master, which no socket authenticates as, and are silently
/// dropped — the whole class of "calls/files don't reach a multi-device peer" bug.
///
/// Single-device parity: if `peer_str` is itself online (the exact id is in a
/// room) it's returned as-is, so a pre-multi-device peer (device == master) is
/// handled identically to before. If NOTHING is online for the identity the vec
/// is empty and the caller can fall back to the raw id (offline send / queue).
pub(crate) fn online_devices_for(
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    peer_str: &str,
) -> Vec<String> {
    let master = super::resolver::resolve(peer_str);
    let mut set: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut master_is_socket = false;
    for peers in ws_room_peers.values() {
        for p in peers {
            // Match the exact id OR any device that resolves to the same master.
            if p == peer_str || super::resolver::resolve(p) == master {
                if *p == master {
                    // Room membership is socket-authenticated, so the master
                    // id appearing IN a room means a socket really does
                    // authenticate as it — a LEGACY single-device identity
                    // (device == master, pre-multi-device install).
                    master_is_socket = true;
                }
                set.insert(p.clone());
            }
        }
    }
    // Never include a bare master no socket authenticates as (sends to it are
    // silently dropped) — but KEEP it when it IS a live socket (legacy
    // device==master), else those identities get an empty vec and callers
    // without a raw-id fallback silently skip them (channel file replication
    // never streamed bytes to legacy members).
    if !master_is_socket {
        set.remove(&master);
    }
    set.into_iter().collect()
}

/// Collapse a list of online MLS leaf credential ids (device ids, post-Step-6;
/// or master ids for legacy leaves) into the SORTED, deduped set of distinct
/// MASTER identities that are online. `local_peer` (the master) is always
/// treated as online. A member is online if it (or any sibling device) is
/// reachable. Used by the coordinator elections so a human with N leaves counts
/// ONCE and the election is stable per-identity rather than per-device.
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
    // `local_peer` is the master and always counts as online (it may not appear
    // in `mls_members` if our own leaf is device-credentialed — group_members
    // returns the device id, which resolves back to us, but be explicit).
    masters.push(local_peer.to_string());
    masters.sort();
    masters.dedup();
    masters
}

/// Deterministic MLS coordinator: lowest MASTER identity among online MLS group
/// members (multi-device: device leaves collapse to their master, so one human
/// = one candidate). Returns the elected master id.
/// Security: only MLS group members participate — non-members can't become coordinator.
/// Testable without MlsManager dependency.
pub(crate) fn elect_coordinator(
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    let masters = online_master_identities(mls_members, local_peer, ws_room_peers);
    masters.into_iter().next()
}

/// Server-group MLS coordinator with OWNER PREFERENCE. The owner always holds the
/// server group and is the natural single authority, so when the owner is online,
/// holds a leaf, and isn't the excluded sender, the owner is the sole committer for
/// server-group adds. This keeps server-group epochs LINEAR and owner-authoritative
/// — a non-owner committer can add a member and then fail to fan the Commit out to
/// some other leaf (e.g. the owner), which then diverges permanently with no retry.
/// (Distinct-identity 3+ member deadlock.) Falls back to the deterministic
/// lowest-master election when the owner is offline / not a leaf / is the sender.
pub(crate) fn elect_server_coordinator(
    server: &crate::crdt::server_state::ServerState,
    mls_members: &[String],
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    // The owner master id (members are master-keyed).
    let owner = server.members.keys().find(|m| {
        server.roles.get(*m)
            .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
            .unwrap_or(false)
    });
    if let Some(owner) = owner {
        let owner_online = owner.as_str() == local_peer || peer_is_reachable(ws_room_peers, owner);
        // The owner must be a candidate of THIS election: it holds a leaf AND isn't
        // the excluded sender (the caller pre-filters the sender's identity out of
        // `mls_members`, so an owner that sent the KP won't appear here).
        let owner_is_candidate = mls_members.iter().any(|p| super::resolver::same_identity(p, owner));
        if owner_online && owner_is_candidate {
            return Some(owner.clone());
        }
    }
    // Owner unavailable — deterministic lowest-master fallback.
    elect_coordinator(mls_members, local_peer, ws_room_peers)
}

/// Where a member sends its server-group bootstrap/recovery KeyPackage. The OWNER
/// always holds the server group, so it's the always-valid recovery target — when
/// online (and not us) we target the owner; otherwise fall back to the lowest
/// online master among CRDT members (excluding us). This pairs with
/// `elect_server_coordinator` so the owner is both the committer and the recovery
/// target, closing the 3+-distinct-member recovery deadlock.
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

/// Elect the coordinator for a per-channel MLS subgroup (Option B). Unlike the
/// server group — whose membership the elector reads from `mls.group_members` —
/// a subgroup may not exist yet on any node, so candidates are the CRDT members
/// who QUALIFY for the channel (`can_see_channel`) and are online. Lowest online
/// qualifying master wins, mirroring `elect_coordinator`. Returns the elected
/// master id, or None if nobody (incl. us) qualifies online.
pub(crate) fn elect_subgroup_coordinator(
    server: &crate::crdt::server_state::ServerState,
    channel_id: &str,
    local_peer: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) -> Option<String> {
    // Prefer the OWNER (always qualifies — Owner sees every channel) when online: a
    // globally-agreed single coordinator that needs no per-node leaf knowledge, so
    // two nodes can't each elect themselves and fork the subgroup. Lowest-qualifying
    // master only when the owner is offline.
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
/// be added to (or bootstrap) the subgroup. No-op when WE are the coordinator
/// (the membership reconciler creates+populates the group on our side) or when
/// nobody qualifying is online. The KeyPackage is tagged with `channel_id` so
/// the coordinator adds us to the SUBGROUP, not the server group.
pub(crate) fn request_subgroup_bootstrap(
    mls: &mut MlsManager,
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
    let kp_bytes = match mls.generate_key_package() {
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

/// Send our KeyPackage to the server OWNER so we can be (re-)added to the
/// SERVER-WIDE MLS group. The server-group twin of [`request_subgroup_bootstrap`]:
/// used when we find ourselves without the group mid-flow (VC join with no
/// group, SFrame heal escalation). No-op when WE are the owner or the owner is
/// offline — falls back to the lowest reachable admin-ish member being useless
/// here: only a group HOLDER can add us, and the owner is the authority.
/// Returns true when a KeyPackage actually went out (caller may arm cooldowns).
pub(crate) fn request_server_group_bootstrap(
    mls: &mut MlsManager,
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
    let kp_bytes = match mls.generate_key_package() {
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

/// Reconcile per-channel MLS subgroup membership against the CRDT after a
/// lifecycle event (role change, visibility change, channel create/delete,
/// kick/ban/leave). Runs the desired-vs-actual diff for every restricted channel
/// (or just `only_channel` when given) and drives the existing batch queues:
///
///   * REMOVALS (we do these directly — we already hold the leaf credentials):
///     any current subgroup leaf whose MASTER is no longer a server member OR no
///     longer qualifies for the channel is queued into `pending_mls_removals`
///     (`{master} ∪ devices_for(master)` so all of a human's leaves drop at once).
///   * ADDITIONS (pull-based — we lack the new member's KeyPackage): any online
///     qualifying member with no leaf is sent an `MlsKeyPackageRequest{channel_id}`;
///     it replies with a KeyPackage tagged for the subgroup, which the
///     MlsKeyPackage handler queues into `pending_mls_key_packages`.
///
/// Only the subgroup coordinator acts (idempotent under races — see the
/// deterministic election). A channel that stops being restricted is torn down
/// by the visibility handler via `remove_group`, not here.
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
        // Elect a STABLE, demotion-safe coordinator: the lowest online master who
        // (a) still QUALIFIES for the channel AND (b) already holds a subgroup leaf.
        // This excludes a just-demoted member (no longer qualifies → can't be the
        // remover, and it never removes its own leaf) AND a just-promoted member
        // (doesn't hold the group yet → can't add others without their KeyPackage).
        // If nobody holds the group yet (first restriction), fall back to the lowest
        // qualifying online master to bootstrap creation.
        // Prefer the OWNER as the single subgroup coordinator when online. The owner
        // ALWAYS qualifies (Owner sees every channel) and is a globally-agreed choice
        // from the CRDT — no node needs to know who locally holds a subgroup leaf.
        // This avoids SPLIT-BRAIN: the per-node leaf-holder heuristic below disagrees
        // across nodes (each only knows its OWN MLS leaves), so two qualifying masters
        // could each elect themselves and create divergent groups with the same id.
        // Fall back to the leaf-holder/lowest-qualifying election only when the owner
        // is offline.
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
                // Owner offline: lowest online master who still QUALIFIES AND already
                // holds a subgroup leaf (demotion-safe); else lowest qualifying master.
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

        // REMOVALS: existing leaves whose master is gone or no longer qualifies.
        for leaf in mls.group_members(&group_key) {
            if super::resolver::same_identity(&leaf, local_peer) { continue; } // never self
            let leaf_master = super::resolver::resolve(&leaf);
            let still_ok = server.is_member(&leaf_master) && server.can_see_channel(&leaf_master, &cid);
            if !still_ok {
                hollow_log!("[HOLLOW-MLS] reconcile: queue remove {leaf} from {group_key} (master no longer qualifies)");
                pending_mls_removals.entry(group_key.clone()).or_default().push(leaf);
            }
        }

        // ADDITIONS: online qualifying members with no leaf yet → request their KP.
        // (We can't add without their KeyPackage; pull it.) Dedup against members
        // we've already queued a KeyPackage for this round.
        let current_leaf_masters: std::collections::HashSet<String> = mls.group_members(&group_key)
            .iter().map(|l| super::resolver::resolve(l)).collect();
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
/// per-channel MLS subgroups (Option B), one commit per subgroup, broadcasting
/// each commit to the subgroup's remaining qualifying members + our own siblings.
/// Used by kick/ban/leave so a removed human loses access to restricted channels,
/// not just the server-wide group. Mirrors the server-group removal in the
/// kick handler. No-op for subgroups we don't hold or where the target has no leaf.
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
        // Only the leaves that actually exist in this subgroup.
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

/// MLS-encrypt an envelope and broadcast to the server room via WS relay.
/// One encrypt → one WS send → relay fans out to all room members.
/// Returns Ok(()) on success, Err(reason) on failure (caller can fall back).
pub(crate) fn send_mls_broadcast(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    let json = serde_json::to_string(envelope).map_err(|e| format!("serialize: {e}"))?;
    let ciphertext = mls.encrypt(server_id, json.as_bytes()).map_err(|e| format!("encrypt: {e}"))?;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&ciphertext);
    // MLS rule: persist on encrypt — SEND-side ratchet state must never be
    // debounced. A receive ratchet that regresses (app killed before a
    // deferred flush) can ratchet FORWARD again, but a regressed send ratchet
    // re-uses generations receivers already consumed → every live message
    // fails with SecretTreeError(TooDistantInThePast) on the other side.
    // (Tried a 2s debounce here 2026-07; it wedged live channel messages
    // from mobile senders exactly this way. Do not retry.)
    persist_mls_state(mls, crypto_store);
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

/// MLS-encrypt an envelope and broadcast to subscribed peers only (topic = channel_id).
/// Peers not subscribed to this topic won't receive the message in real-time
/// but will sync it when they navigate to the channel.
///
/// Returns the serialized `HavenMessage::MlsChannelMessage` wire bytes on
/// success so callers can re-deliver the SAME group ciphertext to offline
/// members (relay offline buffer via 0x09 frames) — MLS application messages
/// are decryptable by every member, so one encryption serves both paths.
///
/// `use_subgroup`: when true, the channel is restricted (Option B) and the
/// message is encrypted under the per-channel MLS subgroup
/// (`subgroup_id(server_id, topic)`) and stamped with `channel_id = Some(topic)`
/// so the receiver decrypts under the same subgroup. When false the message uses
/// the server-wide group (`channel_id = None`, byte-for-byte legacy behavior).
/// The relay routing `topic` is always the channel id regardless.
pub(crate) fn send_mls_broadcast_topic(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    topic: &str,
    use_subgroup: bool,
    envelope: &MessageEnvelope,
    crypto_store: &CryptoStore,
) -> Result<Vec<u8>, String> {
    let group_key = if use_subgroup {
        crate::crypto::subgroup_id(server_id, topic)
    } else {
        server_id.to_string()
    };
    let channel_id = if use_subgroup { Some(topic.to_string()) } else { None };
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
    hollow_log!("[HOLLOW-TOPIC] Broadcast room={server_id} topic={topic} group={group_key} ({} bytes)", data.len());
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoomTopic {
        room_code: server_id.to_string(),
        topic: topic.to_string(),
        data: data.clone(),
    });
    Ok(data)
}

/// MLS-encrypt a targeted envelope and broadcast to the server room.
/// All members decrypt (keeping ratchets in sync) but only `target_peer` processes it.
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
    // Clone envelope and inject target — callers construct without target, we add it here.
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
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);

            if msg_type == 0 {
                hollow_log!("[HOLLOW-CRYPTO] Sending PreKey (type 0) to {peer_id_str}");
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

            if let Some(room) = ws_room_for_peer(ws_room_peers, peer_id_str) {
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
/// `ws_room_for_peer` first-match lookup — the encrypted twin of
/// [`send_message_to_peer_in_room`].
///
/// A recipient device co-present in several of our rooms makes the first-match
/// lookup a coin toss, and picking a room they have since left buffers the frame
/// against a room they never rejoin (silent one-way loss). DM-scoped traffic
/// therefore routes by the deterministic `dm_room_code`, which every device of
/// both identities is a member of.
pub(crate) async fn send_encrypted_message_in_room(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    room_code: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
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

/// Like `send_encrypted_message`, but routes through `SendDirectImage` (0x08)
/// so the relay buffers it under the per-peer IMAGE cap when the recipient is
/// offline. Used to deliver a small image's Olm-encrypted FileHeader (with the
/// bytes inlined) to an offline peer, so the FCM fetch node can render it.
///
/// CRITICAL: the caller passes the explicit `dm_room` (from `dm_room_code`),
/// NOT a `ws_room_for_peer` lookup. An OFFLINE peer is not a member of any room
/// in `ws_room_peers`, so a lookup returns None and the message is dropped —
/// which is exactly the deterministic DM-room code the relay needs to buffer it
/// (mirrors the offline text-DM path in message_ops.rs).
pub(crate) async fn send_encrypted_image_to_peer(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    peer_id_str: &str,
    dm_room: String,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            persist_olm_session(olm, crypto_store, peer_id_str);
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

/// Send an Olm-encrypted TEXT DM directly to an explicit DM room (0x04), without
/// the `ws_room_for_peer` reachability check that `send_encrypted_message` does.
/// Used for the CAPTION of an offline image DM: the recipient is in no known
/// room, so the normal send drops it — but the relay still buffers a 0x04 frame
/// addressed to the deterministic DM room (under the TEXT cap, independent of the
/// image cap). The caption shares its `message_id` with the inlined-image
/// FileHeader, so the fetch node merges them (preferring the real caption over
/// the "[file:...]" sentinel). Mirrors [`send_encrypted_image_to_peer`] but emits
/// SendDirect (0x04) instead of SendDirectImage (0x08).
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
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        let json = serde_json::to_string(&msg).unwrap_or_default();
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
            room_code: room,
            target_peer: peer_str.to_string(),
            data: json.into_bytes(),
        });
    } else {
        // Peer unreachable — the message is dropped (upper layers own their
        // retry/queue semantics), but NEVER silently: this branch is exactly
        // where "call/message to a stale-presence peer vanished with no
        // trace" episodes die, and without this line the logs contain zero
        // evidence (2026-07-20 investigation). Externally-tagged serde:
        // the variant name is the JSON object's single key.
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

/// Like `send_message_to_peer` but routes into an EXPLICIT room (the
/// deterministic `dm_room_code`), not a `ws_room_for_peer` first-match lookup.
/// Use for DM-scoped sends (typing, etc.) where the recipient device may be
/// co-present in several of our rooms and the first-match could pick one the
/// recipient has since left → the frame is buffered against a room they never
/// rejoin and lost. Every device of the recipient is a member of the DM room.
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
/// Large-server scaling Tier 1 (`reports/LARGE_SERVER_SCALING_2026.md`): commit
/// bytes are byte-identical for every recipient, so the historical per-device
/// `SendDirect` loop was O(N) coordinator upload per membership change — the
/// relay fans a single room broadcast out instead. Over-delivery is harmless:
/// receivers that don't hold the group ignore it (`has_group`), receivers
/// already at/past the commit's epoch skip it (wire `epoch` guard — including
/// fresh joiners whose Welcome lands them at the post-commit epoch), and a
/// kicked/removed identity that errors into re-bootstrap is refused by the
/// MlsKeyPackage non-member check. Our own siblings are in the room and now
/// get the commit for free (the relay excludes only this device's socket).
pub(crate) fn broadcast_mls_commit(
    mls: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    server_id: &str,
    channel_id: Option<String>,
    commit_b64: String,
    epoch: Option<u64>,
) {
    // Feed the catch-up ring FIRST: a 0x03 broadcast is unrecoverable for any
    // member not in the room at this instant (or dropped by relay
    // backpressure) — the cache is what lets us replay it to them later
    // instead of repairing with more commits (join-order SFrame race fix).
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
    /// merged-then-evicted with the recovery already fired.
    Applied,
    /// Skipped: we're already at/past the frame's epoch.
    Skipped,
    /// We don't hold this group — nothing to do.
    NoGroup,
    /// Processing failed; the drop-group + re-bootstrap recovery may have run.
    Failed,
}

/// Apply one MlsCommit frame — the shared body of the `HavenMessage::MlsCommit`
/// broadcast arm and the `MlsCommitCatchup` replay loop, so both paths get
/// identical validation and recovery BY CONSTRUCTION: epoch guard, OpenMLS
/// processing, eviction check, SFrame re-export + `MlsEpochChanged`, and the
/// commit-fail drop-group + re-bootstrap.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_mls_commit_frame(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    mls_bootstrap_requested: &mut HashMap<String, std::time::Instant>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer_str: &str,
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
    // Tier 1 epoch guard: commits arrive as a room broadcast, so they
    // also reach fresh joiners (already at the post-commit epoch via
    // their Welcome) and duplicate deliveries. Skip instead of erroring
    // into the costly drop-group + re-bootstrap path below.
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

    match mls_mgr.process_commit(&group_key, &commit_bytes) {
        Ok(()) => {
            persist_mls_state(mls_mgr, crypto_store);
            hollow_log!("[HOLLOW-MLS] Processed commit for {group_key}");

            // Feed the catch-up ring: whoever missed this broadcast can be
            // served the exact frame later (join-order SFrame race fix).
            let cached_epoch = wire_epoch.or_else(|| mls_mgr.epoch(&group_key).ok());
            if let Some(cached_epoch) = cached_epoch {
                mls_mgr.cache_commit(&group_key, cached_epoch, commit_b64.to_string());
            }

            // EVICTION CHECK: a commit that removed OUR OWN leaf merges
            // cleanly but leaves the group INACTIVE — export/encrypt fail
            // forever while has_group stays true, silently wedging SFrame
            // (issue #27's stuck state). If we're still a CRDT member
            // (heal-driven remove+re-add, not a kick/ban), drop the dead
            // group and re-bootstrap; the Welcome re-keys us.
            if !mls_mgr.is_active(&group_key) {
                hollow_log!("[HOLLOW-MLS] Commit EVICTED us from {group_key} — dropping inactive group");
                mls_mgr.remove_group(&group_key);
                persist_mls_state(mls_mgr, crypto_store);
                let still_member = server_states.get(server_id).is_some_and(|s| {
                    s.members.keys().any(|m| super::resolver::same_identity(m, local_peer_str))
                });
                let cooldown_ok = mls_bootstrap_requested.get(&group_key)
                    .is_none_or(|t| t.elapsed() >= super::swarm::MLS_BOOTSTRAP_TIMEOUT);
                let Some(state) = server_states.get(server_id) else {
                    return CommitApplyOutcome::Applied;
                };
                if still_member && cooldown_ok {
                    let requested = match channel_id {
                        Some(cid) => {
                            request_subgroup_bootstrap(
                                mls_mgr, ws_cmd_tx, ws_room_peers,
                                state, server_id, cid, local_peer_str,
                            );
                            true
                        }
                        None => request_server_group_bootstrap(
                            mls_mgr, ws_cmd_tx, ws_room_peers,
                            state, server_id, local_peer_str,
                        ),
                    };
                    if requested {
                        mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
                    }
                }
                return CommitApplyOutcome::Applied;
            }

            // Emit epoch change for SFrame key rotation. For a subgroup
            // (restricted voice channel), route it to that channel's cryptor.
            if let Ok(sframe_key) = mls_mgr.export_secret(&group_key, "sframe", b"", 32) {
                let epoch = mls_mgr.epoch(&group_key).unwrap_or(0);
                let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                    server_id: server_id.to_string(), epoch, sframe_key,
                    channel_id: channel_id.clone(),
                }).await;
            }
            CommitApplyOutcome::Applied
        }
        Err(e) => {
            hollow_log!("[HOLLOW-MLS] Failed to process commit for {group_key}: {e}");

            // Commit processing failed — MLS group state is stale.
            // Drop group and request re-bootstrap. Server group: from owner.
            // Subgroup: from the subgroup coordinator (qualifying members).
            if mls_bootstrap_requested.get(&group_key).is_none_or(|t| t.elapsed() >= super::swarm::MLS_BOOTSTRAP_TIMEOUT) {
                hollow_log!("[HOLLOW-MLS] Dropping stale MLS group and requesting re-bootstrap for {group_key}");
                mls_mgr.remove_group(&group_key);
                persist_mls_state(mls_mgr, crypto_store);

                if let Some(state) = server_states.get(server_id) {
                    let local_peer = local_peer_str.to_string();
                    // Pick the re-bootstrap target.
                    let target: Option<String> = match channel_id {
                        Some(cid) => elect_subgroup_coordinator(
                            state, cid, &local_peer, ws_room_peers,
                        ).filter(|c| c != &local_peer),
                        None => state.members_list().into_iter()
                            .find(|m| m.peer_id != local_peer
                                && state.roles.get(&m.peer_id)
                                    .map(|r| *r.read() == crate::crdt::operations::MemberRole::Owner)
                                    .unwrap_or(false))
                            .map(|m| m.peer_id.clone()),
                    };
                    if let Some(target) = target
                        && let Ok(kp_bytes) = mls_mgr.generate_key_package()
                    {
                        let kp_b64 = base64::engine::general_purpose::STANDARD.encode(&kp_bytes);
                        let data = serde_json::to_vec(&HavenMessage::MlsKeyPackage {
                            server_id: server_id.to_string(),
                            key_package: kp_b64,
                            channel_id: channel_id.clone(),
                        }).unwrap_or_default();
                        let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &target, data);
                        if sent > 0 {
                            mls_bootstrap_requested.insert(group_key.clone(), std::time::Instant::now());
                            hollow_log!("[HOLLOW-MLS] Sent re-bootstrap KeyPackage to {target} ({sent} device(s)) for {group_key}");
                        }
                    }
                }
            }
            CommitApplyOutcome::Failed
        }
    }
}

/// Per-(group, peer) cooldown for epoch-hint service and self-probes — bounds
/// hint-triggered work against floods and request loops.
pub(crate) const EPOCH_HINT_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(10);

/// The authority for an MLS group key: the subgroup coordinator for a
/// restricted channel; for the server-wide group the OWNER when online-or-us
/// (owner-preferred single-committer model), else the lowest online master —
/// so epoch catch-up still has a live responder in an owner-less room. May
/// return US (callers same_identity-check for the am-I-authority decision).
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

/// Who answers an epoch catch-up for a group, given that `behind` is the peer
/// that needs one.
///
/// Normally that is [`group_authority`], but the authority CANNOT SERVE ITSELF,
/// and for the server group the authority is the owner — so an owner that went
/// offline across an epoch advance it did not author came back stale into a
/// deadlock: `group_authority` named the owner again the moment it was
/// reachable, so the owner's own probe bailed ("our epoch defines the group")
/// and the member that actually held the newer epoch refused to serve ("not the
/// authority"). Both sides deferred to the owner and the owner was the stale
/// one. Measured 2026-08-27: the returning owner dropped 3 channel messages
/// before the decrypt-fail ladder rescued it, and in a VOICE-only channel no
/// ciphertext ever flows to fail a decrypt, so there was no ladder at all.
///
/// Excluding the peer that is behind fixes it symmetrically: the asker (in
/// [`send_epoch_probe`], passing itself) and the answerer (in
/// [`handle_epoch_hint`], passing the requester) run the SAME election and land
/// on the same single responder, so there is still exactly one — no room-wide
/// echo. Owner-preference stays where it belongs: on the COMMITTER, which is
/// what keeps server-group epochs linear (`feedback_owner_coordinator_mls_recovery`).
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
    // The authority IS the peer that is behind. Deterministic fallback: the
    // lowest online master among the rest (subgroup: among the members that
    // qualify for the channel, since a non-qualifying member never holds it).
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

/// React to a peer's MLS epoch hint (`SyncRequest.mls_epoch` / `MlsEpochProbe`)
/// — the detector for present-but-stale groups, which are otherwise invisible:
/// commits ride an unbuffered 0x03 broadcast, all other recovery triggers key
/// on `has_group`/leaf-missing, and in a voice-only channel no MLS ciphertext
/// ever flows to fail a decrypt (join-order SFrame race, black screens until
/// the escalated heal).
///
///  * theirs < ours and WE are the group authority → serve `MlsCommitCatchup`
///    from the commit cache (non-churning: no new commits, no epoch bump), or
///    fall back to the existing remove+re-add repair when the cache can't
///    bridge the gap.
///  * theirs > ours → WE may be stale: probe the authority ourselves. Cheap
///    and non-destructive BY DESIGN — an unauthenticated plaintext hint must
///    never make us drop a group (that would be a remote group-reset
///    primitive); the worst a spoofed-high hint achieves is one throttled
///    probe, answered only if we are genuinely behind.
///  * equal / no group / conference / requester not a member → no-op.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_epoch_hint(
    mls_mgr: &mut MlsManager,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    pending_mls_removals: &mut HashMap<String, Vec<String>>,
    epoch_hint_cooldown: &mut HashMap<String, std::time::Instant>,
    server_id: &str,
    channel_id: Option<&str>,
    their_epoch: u64,
    from_peer: &str,
    local_peer_str: &str,
    // True when this arrived as an `MlsEpochProbe` — a request ADDRESSED to us,
    // so we answer it ourselves and skip the responder election. The election
    // exists to stop a room-wide echo when many members incidentally hint a
    // reconnecting peer via `SyncRequest`; running it on a direct probe instead
    // re-opens the deadlock from the other side, because the asker picks its
    // target from ITS view of the membership and we would re-elect from ours.
    // A returning owner's CRDT is a delta behind by definition, so those two
    // views disagree exactly when the heal matters most.
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
        // …but their hint may still be the only evidence that WE are behind, and
        // acting on it costs one throttled probe to a peer we ALREADY trust — we
        // never reply to the unknown sender. This is the reconnect race: a member
        // admitted while we were offline hints us before our CRDT delta lands, and
        // dropping it here discarded the only heal trigger, with nothing to re-send it.
        if their_epoch > own_epoch {
            send_epoch_probe(
                mls_mgr, ws_cmd_tx, ws_room_peers, state,
                server_id, channel_id, local_peer_str, epoch_hint_cooldown,
            );
        }
        return;
    }

    if their_epoch < own_epoch {
        // ONE responder, no room-wide echo — but the responder is elected with the
        // peer that is behind excluded, so a stale AUTHORITY still gets an answer.
        // A direct probe skips the election: it was addressed to us.
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

        match mls_mgr.cached_commits_after(&group_key, their_epoch, own_epoch) {
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
                // Cache can't bridge — fall back to the existing repair: queue
                // a remove of their leaves and pull a fresh KeyPackage; the
                // batch timer re-adds them via Welcome at the current epoch
                // (mirrors the heal ladder's authority arm).
                hollow_log!(
                    "[HOLLOW-MLS] Epoch hint from {from_peer} for {group_key} (theirs {their_epoch} < ours {own_epoch}) — cache can't bridge, queueing remove+re-add"
                );
                let leaves = mls_mgr.group_members(&group_key);
                for leaf in &leaves {
                    if super::resolver::same_identity(leaf, &from_master) {
                        pending_mls_removals.entry(group_key.clone()).or_default().push(leaf.clone());
                    }
                }
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
    // WE are the peer that would be behind, so we are excluded from the election:
    // "we are the authority" says who COMMITS, never who holds the newest epoch,
    // and treating it as the latter is what left a returning owner with nobody to
    // ask. See `epoch_catchup_responder`.
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
    }).unwrap_or_default();
    let sent = send_raw_to_identity(ws_cmd_tx, ws_room_peers, &authority, data);
    if sent > 0 {
        hollow_log!("[HOLLOW-MLS] Sent epoch probe (epoch {own_epoch}) to authority {authority} for {group_key}");
    }
}

/// Send pre-serialized bytes to EVERY online device of an identity.
///
/// Multi-device (Step 6): server members are keyed by MASTER, but no socket
/// authenticates as the bare master — a `send_raw_to_peer(master)` is silently
/// dropped (the master is in no room). This fans the same bytes out to each
/// online device of `member_id`'s identity. If `member_id` is itself a live
/// device id (single-device, or a non-collapsed id) it is reached directly.
/// No-op if the identity has no online device. Returns the number of devices
/// the bytes were dispatched to.
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
        // peer_a is lowest → coordinator
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
        // peer_a is offline (not in any room), peer_b is lowest online
        let rooms = make_room_peers(&[("srv1", &["peer_b", "peer_c"])]);
        assert_eq!(elect_coordinator(&members, "peer_b", &rooms).as_deref(), Some("peer_b"));
        assert_eq!(elect_coordinator(&members, "peer_c", &rooms).as_deref(), Some("peer_b"));
        // peer_a calls elect but is not in rooms — however local_peer is always included
        assert_eq!(elect_coordinator(&members, "peer_a", &rooms).as_deref(), Some("peer_a"));
    }

    #[test]
    fn coordinator_election_empty_members() {
        let members: Vec<String> = vec![];
        let rooms = HashMap::new();
        // local_peer is always counted as online → it wins alone (never None when
        // local_peer is present; None only if local_peer were filtered, which it
        // can't be). With an empty member list, local wins.
        assert_eq!(elect_coordinator(&members, "peer_x", &rooms).as_deref(), Some("peer_x"));
    }

    #[test]
    fn coordinator_election_collapses_devices_to_master() {
        // Multi-device: master M1 has two online device leaves (D1a, D1b); master
        // M2 has one (D2). The MLS group lists DEVICE ids. Election must collapse
        // to masters and pick the lowest MASTER — counting M1 once, not twice.
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();
        super::super::resolver::update("dev_m1_a", "master1");
        super::super::resolver::update("dev_m1_b", "master1");
        super::super::resolver::update("dev_m2", "master2");

        let members = vec!["dev_m1_a".into(), "dev_m1_b".into(), "dev_m2".into()];
        let rooms = make_room_peers(&[("srv1", &["dev_m1_a", "dev_m1_b", "dev_m2"])]);

        // master1 < master2 → master1 is coordinator regardless of which device queries.
        assert_eq!(elect_coordinator(&members, "master1", &rooms).as_deref(), Some("master1"));
        assert_eq!(elect_coordinator(&members, "master2", &rooms).as_deref(), Some("master1"));

        // Vault coordinator = 2nd master (master2), NOT a 2nd device of master1.
        assert_eq!(elect_vault_coordinator(&members, "master1", &rooms).as_deref(), Some("master2"));

        super::super::resolver::clear_all();
    }

    #[test]
    fn master_with_online_device_is_reachable() {
        // THE regression test for the early-return bug: `resolve(master) ==
        // master` always (masters are only VALUES in the link map), so an
        // early "resolve == self → false" made every bare MASTER id
        // unreachable even with its device online — silently disabling the
        // owner-preferred election, MLS recovery targeting, subgroup
        // self-bootstrap and offline-push classification for every modern
        // (device != master) identity. The resolver map is process-global —
        // hold the shared test lock so a parallel test's clear_all can't wipe
        // the links mid-assert.
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::update("pir_dev_a", "pir_master_a");
        let rooms = make_room_peers(&[("srvP", &["pir_dev_a"])]);

        // The bare master IS reachable through its online device...
        assert!(peer_is_reachable(&rooms, "pir_master_a"));
        // ...and the device id itself stays reachable (exact fast path).
        assert!(peer_is_reachable(&rooms, "pir_dev_a"));
        // A master whose devices are all offline is NOT reachable.
        super::super::resolver::update("pir_dev_b", "pir_master_b");
        assert!(!peer_is_reachable(&rooms, "pir_master_b"));
        // An unknown single-device peer not in any room is NOT reachable.
        assert!(!peer_is_reachable(&rooms, "pir_stranger"));
    }

    #[test]
    fn preferred_online_device_picks_socket_addressable_id() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::update("pod_dev_1", "pod_master");
        super::super::resolver::update("pod_dev_2", "pod_master");
        let rooms = make_room_peers(&[("srvQ", &["pod_dev_2", "pod_dev_1"])]);

        // Master input → deterministic lowest online device.
        assert_eq!(
            preferred_online_device(&rooms, "pod_master").as_deref(),
            Some("pod_dev_1")
        );
        // Exact id in a room wins as-is (single-device / legacy keystone).
        assert_eq!(
            preferred_online_device(&rooms, "pod_dev_2").as_deref(),
            Some("pod_dev_2")
        );
        // Nothing online → None (reachable ⇒ Some invariant holds inversely).
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

        // Relay substitutes its own keys; signature is left untouched.
        let tampered = key_bundle_signing_payload(
            &sender_id, &recipient_id, "ATTACKER_IDKEY", "ATTACKER_OTKEY", ts.unwrap(),
        );
        assert_eq!(
            verify_key_exchange(&sender_id, &recipient_id, to, ts, sig, pk, &tampered),
            KeyExchangeAuth::Invalid,
            "substituted Olm keys must not verify",
        );
    }

    /// A relay re-signing with its OWN key must fail: `verify_message_signature`
    /// re-derives the peer_id from `pk` and refuses a mismatch, so the attacker
    /// cannot both sign validly and claim the victim's peer_id.
    #[test]
    fn bundle_signed_by_impostor_is_rejected() {
        let attacker = kp(9);
        let (victim_id, recipient_id) = (kp(1).peer_id(), kp(2).peer_id());

        // Attacker signs a well-formed bundle but claims to be the victim.
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
        // Old clients ignore unknown keys; the tag still routes correctly.
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

        // Rogue device claiming the master's identity without being in its list.
        super::super::resolver::update(&rogue_device, &master_id);
        super::super::resolver::forget(&rogue_device);
        super::super::resolver::update(&real_device, &master_id);
        assert!(!key_exchange_device_unauthorized(&real_device));

        super::super::resolver::clear_all();
    }

    /// A legacy keystone wrote `devices = [master]`. Once a DISTINCT device key
    /// exists (device != master), `build_local_device_list` must STRIP the
    /// master-as-device entry and publish only the real device id — otherwise a
    /// friend who only learns `[master]` can never map our real device → master
    /// (broke nickname-added friend keying). A genuine sole keystone (device ==
    /// master) keeps its single entry untouched (it owns its MLS leaf).
    #[test]
    fn local_device_list_strips_master_as_device() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();
        let master = test_master();
        let master_id = master.peer_id();
        let device_id = "12D3KooWrealDeviceXYZ".to_string();

        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("m.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();

        // Seed a STALE legacy keystone list: devices = [master], v1.
        {
            let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
            let stale = build_signed_device_list(&master, 1, vec![master_id.clone()], vec![]);
            let json = serde_json::to_string(&stale).unwrap();
            store.save_device_list(&master_id, &json, 1, &stale.devices, 0).unwrap();
        }

        // Publish from the REAL distinct device → master must be stripped, device added.
        let signed = build_local_device_list(&master, &device_id, &db, &pass).unwrap();
        assert!(
            !signed.devices.contains(&master_id),
            "master-as-device must be stripped, got {:?}", signed.devices
        );
        assert!(
            signed.devices.contains(&device_id),
            "the real device id must be published, got {:?}", signed.devices
        );
        assert!(signed.version >= 2, "membership changed → version bumped");
        assert!(verify_device_list(&signed), "re-signed list must verify");

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
    fn sibling_proof_sign_verify_roundtrip() {
        let master = test_master();
        let our_master = master.peer_id();
        let challenged_device = "12D3KooWsiblingDevice";
        let nonce = "deadbeefcafef00d";

        // The genuine sibling holds the SAME master key, signs with its own device id.
        let (sig, pk) = build_sibling_proof(&master, challenged_device, nonce);
        assert!(
            verify_sibling_proof(&our_master, challenged_device, nonce, &sig, &pk),
            "a valid master-signed proof must verify"
        );

        // A stranger signs with a DIFFERENT master key → pubkey binds to the wrong
        // master peer_id → rejected.
        let stranger = {
            let phrase = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
            let m: bip39::Mnemonic = phrase.parse().unwrap();
            crate::identity::native_identity::NativeKeypair::from_mnemonic(&m).unwrap()
        };
        let (bad_sig, bad_pk) = build_sibling_proof(&stranger, challenged_device, nonce);
        assert!(
            !verify_sibling_proof(&our_master, challenged_device, nonce, &bad_sig, &bad_pk),
            "a stranger's signature must NOT verify against our master"
        );

        // A tampered nonce / device id breaks the signature.
        assert!(
            !verify_sibling_proof(&our_master, challenged_device, "wrongnonce", &sig, &pk),
            "wrong nonce must not verify"
        );
        assert!(
            !verify_sibling_proof(&our_master, "12D3KooWotherDevice", nonce, &sig, &pk),
            "wrong challenged device must not verify"
        );
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
        // Build with b also present in devices — it must be stripped because it's revoked.
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
    // Both reported by itsfolf (2026-07, second report). Neither was visible to
    // the tests that existed: they fed ONE sender per batch (so the cache was
    // never consulted for a second sender) and never a batch whose signature
    // was wrong (so "stored anyway" never showed up).

    /// base64 of a keypair's public key protobuf — what rides `pk` on the wire.
    fn pk_b64(k: &crate::identity::native_identity::NativeKeypair) -> String {
        base64::engine::general_purpose::STANDARD.encode(k.public_key_protobuf())
    }

    /// THE REPORTED ATTACK (public key cache poisoning). Two items in ONE sync
    /// batch: item 1 is A's real message and primes the cache; item 2 claims
    /// sender B but ships A's key. A genuinely signed item 2's bytes, so the
    /// Ed25519 check passes — the pk→sender binding is the only thing that
    /// stops it, and the cache-HIT path skipped that check. These forgeries
    /// VERIFIED: the Message Proof dialog would have shown text the claimed
    /// author never wrote as authentic.
    #[test]
    fn cached_verify_rechecks_pk_binding_on_cache_hit() {
        let a = kp(11);
        let (a_id, b_id) = (a.peer_id(), kp(12).peer_id());
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        // Item 1 — legitimate, primes the cache with A's key.
        let p1 = message_signing_payload("ch", "srv:chan", &a_id, 1_000, "hello");
        let (sig1, pk1) = sign_message(&a, &a_pk, &p1);
        assert!(verify_message_signature_cached(
            &a_id, sig1.as_deref(), pk1.as_deref(), &p1, &mut cache,
        ));

        // Item 2 — A signs a payload naming B, and ships A's key.
        let p2 = message_signing_payload("ch", "srv:chan", &b_id, 2_000, "B never wrote this");
        let (sig2, _) = sign_message(&a, &a_pk, &p2);
        assert!(
            !verify_message_signature_cached(&b_id, sig2.as_deref(), pk1.as_deref(), &p2, &mut cache),
            "a cache HIT must still bind the public key to the CLAIMED sender",
        );

        // ...and the cache still does its job for the key's real owner.
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

    /// An item with NO signature is refused (0.8.5). Omitting the signature was
    /// the cheapest injection there was: the channel item names its own sender,
    /// so an unsigned row could impersonate any member and still land in the DB
    /// and in archive exports.
    ///
    /// The verdict stays `Absent` rather than collapsing into `Forged` — the
    /// two are distinguished in the log so support can tell an old peer serving
    /// pre-signing history from someone actively injecting.
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

        // Same signature, text altered by whoever served the batch.
        assert_eq!(
            check_backfill_signature(
                &a_id, "dm", "recipient", 500, None, &SignedExtras::default(), "send 5000",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
        );
        // Untouched still verifies.
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
    // The whole point of v2 is that the signature covers the structured fields,
    // not just the text. These lock the canonical format and, since 0.8.5,
    // that v1 is refused rather than accepted as a fallback.

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
        };
        let payload = message_signing_payload_v2("dm", "recipient", &a_id, 1_000, &extras, "hi");
        let (sig, pk) = sign_message(&a, &a_pk, &payload);

        // The v2 signature verifies.
        assert!(verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &extras, "hi", &mut cache,
        ));

        // Each field is load-bearing — tamper with one, verification fails.
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

        // Text is still covered too.
        assert!(!verify_message_signature_v2(
            &a_id, sig.as_deref(), pk.as_deref(), "dm", "recipient", 1_000, &extras, "bye", &mut cache,
        ), "text must be covered");
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

        // Signed the OLD way — text only, no structured fields. This is a
        // GENUINE signature by the real sender; it is refused anyway, because
        // the payload it covers leaves mid/reply_to/file_id/order_us/preview
        // free to be rewritten by whoever serves the message.
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

    // ── Signed profiles (0.8.5) ───────────────────────────────────────────

    /// The hole this closes: `ProfileRelay` lets a peer assert a THIRD party's
    /// profile (it carries its own `source_peer_id`), in plaintext, with an
    /// `updated_at` the sender also picks. Only the subject's signature makes
    /// the claim credible — so a signature must be bound to the subject, to
    /// every field, and to the timestamp.
    #[test]
    fn profile_signature_binds_subject_and_every_field() {
        let victim = kp(30);
        let attacker = kp(31);
        let (victim_id, attacker_id) = (victim.peer_id(), attacker.peer_id());
        let victim_pk = pk_b64(&victim);
        let attacker_pk = pk_b64(&attacker);

        let base = || ("Vitalik", "online", "about", "twitchname", "a".repeat(64));
        let (name, status, about, twitch, avatar_hash) = base();
        let (sig, pk) = sign_profile(
            &victim, &victim_pk, &victim_id, 1_000, name, status, about, twitch, &avatar_hash,
        );
        let ok = |peer: &str, ts: i64, n: &str, s: &str, a: &str, t: &str, ah: &str| {
            verify_profile_signature(peer, ts, n, s, a, t, ah, sig.as_deref(), pk.as_deref())
        };
        assert!(ok(&victim_id, 1_000, name, status, about, twitch, &avatar_hash));

        // Every signed field is actually covered.
        assert!(!ok(&victim_id, 1_000, "Admin", status, about, twitch, &avatar_hash));
        assert!(!ok(&victim_id, 1_000, name, "compromised", about, twitch, &avatar_hash));
        assert!(!ok(&victim_id, 1_000, name, status, "other", twitch, &avatar_hash));
        assert!(!ok(&victim_id, 1_000, name, status, about, "someoneelse", &avatar_hash));
        assert!(!ok(&victim_id, 1_000, name, status, about, twitch, &"b".repeat(64)));
        // The far-future `updated_at` that made the original attack permanent.
        assert!(!ok(&victim_id, i64::MAX, name, status, about, twitch, &avatar_hash));
        // Bound to the SUBJECT: the victim's own profile cannot be re-labelled
        // as someone else's, and vice versa.
        assert!(!ok(&attacker_id, 1_000, name, status, about, twitch, &avatar_hash));

        // The actual attack: the attacker signs a profile that claims to be the
        // victim's. The pk→peer_id binding inside the verify rejects it.
        let (bad_sig, bad_pk) = sign_profile(
            &attacker, &attacker_pk, &victim_id, i64::MAX, "Admin", status, about, twitch, &avatar_hash,
        );
        assert!(
            !verify_profile_signature(
                &victim_id, i64::MAX, "Admin", status, about, twitch, &avatar_hash,
                bad_sig.as_deref(), bad_pk.as_deref(),
            ),
            "a profile must not be attributable to someone who did not sign it",
        );

        // Unsigned is refused — omitting the signature was the cheapest way in.
        assert!(!ok_absent(&victim_id, 1_000, name, status, about, twitch, &avatar_hash));
    }

    fn ok_absent(
        peer: &str, ts: i64, n: &str, s: &str, a: &str, t: &str, ah: &str,
    ) -> bool {
        verify_profile_signature(peer, ts, n, s, a, t, ah, None, None)
    }

    /// A relay can rewrite the body of a PLAINTEXT `ProfileUpdate` in flight,
    /// which is why the signature is REQUIRED on that path and not merely
    /// "tolerated because the sender is the subject". Tampering with any field
    /// after signing must fail even though the transport-reported sender is
    /// still genuinely the subject.
    #[test]
    fn relay_tampering_with_an_own_profile_update_fails() {
        let alice = kp(32);
        let alice_id = alice.peer_id();
        let alice_pk = pk_b64(&alice);
        let hash = "c".repeat(64);

        let (sig, pk) = sign_profile(
            &alice, &alice_pk, &alice_id, 7_000, "alice", "online", "hi", "", &hash,
        );
        assert!(verify_profile_signature(
            &alice_id, 7_000, "alice", "online", "hi", "", &hash,
            sig.as_deref(), pk.as_deref(),
        ));
        // Relay renames her in transit; sender id and everything else untouched.
        assert!(
            !verify_profile_signature(
                &alice_id, 7_000, "Hollow Support", "online", "hi", "", &hash,
                sig.as_deref(), pk.as_deref(),
            ),
            "a relay-rewritten display name must not verify",
        );
        // ...and swaps the avatar the announce advertises.
        assert!(!verify_profile_signature(
            &alice_id, 7_000, "alice", "online", "hi", "", &"d".repeat(64),
            sig.as_deref(), pk.as_deref(),
        ));
    }

    /// Profile fields are free text, so the payload length-prefixes each one:
    /// two different field splits that concatenate identically must NOT produce
    /// the same signature (otherwise a display name could impersonate the next
    /// field's boundary).
    #[test]
    fn profile_payload_is_collision_resistant() {
        let p1 = profile_signing_payload("peer", 1, "ab", "c", "", "", "");
        let p2 = profile_signing_payload("peer", 1, "a", "bc", "", "", "");
        assert_ne!(p1, p2);
        // And the timestamp is inside the digest, not appended after it.
        assert_ne!(
            profile_signing_payload("peer", 1, "n", "", "", "", ""),
            profile_signing_payload("peer", 2, "n", "", "", "", ""),
        );
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
    /// NOTHING for a preview that doesn't use them. Every row already on disk
    /// keeps the digest it was signed with, so no message stops verifying
    /// because the struct grew.
    ///
    /// The literal is the digest of `lp("Pinned Title")` as produced before
    /// `kind`/`author`/`video_url` existed. If a future field is folded in
    /// unconditionally, this test is what fails.
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
    /// (`message_ops::handle_edit_*`), so that is what backfill verifies
    /// against — the same rule `archive::loader` uses. Skipping edited rows
    /// (the old behavior) made `edited_at` a way to skip verification.
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

    /// v2 EDIT signatures bind the row's full structural fields (same extras
    /// the original bound) at the EDIT timestamp — so backfill verifies an
    /// edited item end-to-end, and a sync responder cannot re-attach the edit
    /// signature to a different mid or graft a forged file_id onto the edited
    /// row (whose original signature the edit overwrote).
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
        };
        // The edit sign sites (`handle_edit_*`) sign v2 over edit_ts + new text
        // + the row's extras.
        let edit_payload = message_signing_payload_v2("ch", "srv:chan", &a_id, edit_ts, &extras, "edited text");
        let (sig, pk) = sign_message(&a, &a_pk, &edit_payload);

        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", orig_ts, Some(edit_ts), &extras, "edited text",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Valid,
        );
        // Replay the edit signature onto a different message id → rejected.
        let other_mid = SignedExtras { mid: Some("mid-OTHER"), ..extras };
        assert_eq!(
            check_backfill_signature(
                &a_id, "ch", "srv:chan", orig_ts, Some(edit_ts), &other_mid, "edited text",
                sig.as_deref(), pk.as_deref(), &mut cache,
            ),
            BackfillSig::Forged,
            "an edit signature must be bound to its message id",
        );
        // Graft a file_id onto the edited item → rejected.
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

    /// End-to-end shape of the 0.8.3 send path: `sign_message_versioned` (flag
    /// ON → v2) must verify at a backfill site that reconstructs the same
    /// extras from a sync item, and any structural tamper on the item must be
    /// rejected.
    #[test]
    fn versioned_send_roundtrips_through_backfill() {
        let a = kp(25);
        let a_id = a.peer_id();
        let a_pk = pk_b64(&a);
        let mut cache = PkCache::new();

        let extras = SignedExtras {
            mid: Some("mid-rt"), reply_to: None, file_id: Some("file-rt"),
            order_us: Some(777), lp_digest: None,
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
        // FIXED seeds - the whole point is reproducibility across languages.
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

        // The exact bytes the C++ side must rebuild.
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

    /// The two new `FriendRequest` fields must be invisible to a peer that has
    /// never heard of them, and `FriendAccept` must stay byte-identical. Getting
    /// this wrong does not fail loudly: an old client simply stops being able to
    /// accept anyone.
    #[test]
    fn friend_request_wire_stays_backward_compatible() {
        // A request with no bundle serializes exactly as it always did.
        let bare = HavenMessage::FriendRequest {
            requested_at: 1234,
            carried_bundle: None,
            device_list: None,
            carried_profile: None,
        };
        let json = serde_json::to_string(&bare).unwrap();
        assert_eq!(json, r#"{"type":"friend_request","requested_at":1234}"#);

        // And an OLD peer's request still parses here, with the new fields absent.
        let old_wire = r#"{"type":"friend_request","requested_at":99}"#;
        match serde_json::from_str::<HavenMessage>(old_wire).unwrap() {
            HavenMessage::FriendRequest { requested_at, carried_bundle, device_list, carried_profile } => {
                assert_eq!(requested_at, 99);
                assert!(carried_bundle.is_none(), "no bundle means fall back to lazy key exchange");
                assert!(device_list.is_none());
                assert!(carried_profile.is_none(), "old wire carries no profile");
            }
            other => panic!("expected FriendRequest, got {other:?}"),
        }

        // FriendAccept stays a UNIT variant. Turning it into a struct would change
        // the wire shape and an old client's bare accept would stop parsing.
        assert_eq!(
            serde_json::to_string(&HavenMessage::FriendAccept).unwrap(),
            r#"{"type":"friend_accept"}"#,
        );
        assert!(matches!(
            serde_json::from_str::<HavenMessage>(r#"{"type":"friend_accept"}"#).unwrap(),
            HavenMessage::FriendAccept,
        ));

        // A NEW request round-trips its bundle intact.
        let device = kp(0x1b);
        let bundle = signed_carried_bundle(
            &device, &device.peer_id(), "master-x", "ik".into(), "otk".into(),
        );
        let list = build_signed_device_list(&kp(0x7a), 1, vec![device.peer_id()], Vec::new());
        let full = HavenMessage::FriendRequest {
            requested_at: 7,
            carried_bundle: Some(bundle.clone()),
            device_list: Some(list),
            carried_profile: None,
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

    /// `FriendReject` grew a `requested_at` so a stale or replayed decline can
    /// never delete a NEWER request or an accepted friendship. The enum is
    /// INTERNALLY tagged, which is what makes that safe in both directions: an
    /// old client's bare `{"type":"friend_reject"}` parses here as
    /// `requested_at = 0` ("decline whatever is pending"), and an old client
    /// parsing our new frame drains the unknown key instead of failing. Getting
    /// this wrong is silent: declines simply stop crossing a version boundary.
    #[test]
    fn friend_reject_wire_is_backward_compatible() {
        // NEW -> wire: the stamp always rides (no skip_serializing_if), and a
        // reject with no carried list is byte-for-byte what it was before the list
        // existed. The exact string matters: an old client parses this shape.
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

        // A reject WITH a list round-trips it intact: this is the attribution the
        // requester needs when it has never been online with the decliner.
        let master = kp(0x5c);
        let device = kp(0x5d).peer_id();
        let list = build_signed_device_list(&master, 3, vec![device.clone()], Vec::new());
        let carried = HavenMessage::FriendReject {
            requested_at: 42,
            device_list: Some(list.clone()),
        };
        let wire = serde_json::to_string(&carried).unwrap();
        match serde_json::from_str::<HavenMessage>(&wire).unwrap() {
            HavenMessage::FriendReject { requested_at, device_list: Some(got) } => {
                assert_eq!(requested_at, 42);
                assert_eq!(got.master_peer_id, master.peer_id());
                assert_eq!(got.devices, vec![device.clone()]);
                assert_eq!(got.sig_b64, list.sig_b64);
                assert!(verify_device_list(&got), "the list must survive the wire verifiable");
            }
            other => panic!("expected a listed FriendReject, got {other:?}"),
        }

        // NEW wire -> OLD code, both shapes. A pre-2026-08-29 client models this as
        // a UNIT variant; serde's internally-tagged unit visitor drains unknown map
        // entries, INCLUDING a nested object, so neither the stamp nor the carried
        // list can make an old client drop the decline. Mirror that client here
        // rather than trusting the claim.
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

    /// `ServerJoinRequest` grew three fields for parked joins (a nonce, a
    /// carried device list, a parked flag) and `join_resolved` is a brand-new
    /// variant. Both directions have to keep working across the version
    /// boundary, and getting it wrong is SILENT: joins would simply stop
    /// crossing between clients.
    ///
    /// Pinned here rather than in `types.rs` because that module has no test
    /// harness and this is the same pin, with the same helpers, as
    /// `friend_reject_wire_is_backward_compatible` directly above.
    #[test]
    fn server_join_wire_is_backward_compatible() {
        // OLD wire -> NEW code. A pre-2026-08-29 client sends only the three
        // original keys; the new fields must default to "legacy, live, no list".
        let old_wire = r#"{"type":"join_request","server_id":"abc","nsfw_confirmed":true}"#;
        match serde_json::from_str::<HavenMessage>(old_wire).unwrap() {
            HavenMessage::ServerJoinRequest {
                server_id, twitch_proof_json, nsfw_confirmed,
                requested_at, device_list, parked,
            } => {
                assert_eq!(server_id, "abc");
                assert!(twitch_proof_json.is_none());
                assert!(nsfw_confirmed);
                assert_eq!(requested_at, 0, "no nonce = a legacy client");
                assert!(device_list.is_none(), "old wire carries no device list");
                assert!(!parked, "old wire is always a live request");
            }
            other => panic!("expected ServerJoinRequest, got {other:?}"),
        }

        // NEW -> wire. The nonce and the flag always ride (no
        // skip_serializing_if); an absent device list serializes to nothing, so
        // a request with no list is byte-for-byte what it was before.
        assert_eq!(
            serde_json::to_string(&HavenMessage::ServerJoinRequest {
                server_id: "abc".to_string(),
                twitch_proof_json: None,
                nsfw_confirmed: false,
                requested_at: 7,
                device_list: None,
                parked: true,
            })
            .unwrap(),
            r#"{"type":"join_request","server_id":"abc","nsfw_confirmed":false,"requested_at":7,"parked":true}"#,
        );

        // A request WITH a list round-trips it verifiable: this is the
        // attribution a member serving it from the ring depends on.
        let master = kp(0x7a);
        let device = kp(0x7b).peer_id();
        let list = build_signed_device_list(&master, 4, vec![device.clone()], Vec::new());
        let wire = serde_json::to_string(&HavenMessage::ServerJoinRequest {
            server_id: "abc".to_string(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
            requested_at: 42,
            device_list: Some(list.clone()),
            parked: true,
        })
        .unwrap();
        match serde_json::from_str::<HavenMessage>(&wire).unwrap() {
            HavenMessage::ServerJoinRequest {
                requested_at, device_list: Some(got), parked, ..
            } => {
                assert_eq!(requested_at, 42);
                assert!(parked);
                assert_eq!(got.master_peer_id, master.peer_id());
                assert_eq!(got.devices, vec![device.clone()]);
                assert!(verify_device_list(&got), "the list must survive the wire verifiable");
            }
            other => panic!("expected a listed ServerJoinRequest, got {other:?}"),
        }

        // NEW wire -> OLD code. A pre-parked-joins client models the variant
        // with only the three original fields; serde's internally-tagged struct
        // visitor drains the unknown keys, INCLUDING the nested device-list
        // object, so a new request still reaches an old member.
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

        // `ServerJoinRejected` grew the same nonce, and for a sharper reason:
        // the refusal is BUFFERED by the relay now, so a stale copy replays
        // straight into the user's next request. Old wire = 0 = "refuse
        // whatever is pending", which is all the old presence-gated send could
        // ever have meant.
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
        // A refusal carries no op, and the Option is skipped on the wire.
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

    /// Run `ingest_device_list` the way the ProfileUpdate handler does, against a
    /// throwaway DB this call owns, and hand back the device set it persisted for
    /// the list's master. The local identity is deliberately a DIFFERENT master, so
    /// the friend path is exercised rather than the sibling merge.
    async fn ingest_list_from(list: &SignedDeviceList, sender_peer_id: &str) -> Vec<String> {
        let local_master = kp(0x01);
        let local_master_id = local_master.peer_id();
        let local_device = kp(0x02).peer_id();

        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("ingest.db").to_str().unwrap().to_string();
        let pass = "cd".repeat(32);
        crate::storage::MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();

        let (event_tx, _event_rx) = mpsc::channel::<NetworkEvent>(64);
        let (ws_cmd_tx, _ws_cmd_rx) =
            tokio::sync::mpsc::unbounded_channel::<super::super::ws_client::WsCommand>();
        let rooms: HashMap<String, std::collections::HashSet<String>> = HashMap::new();

        ingest_device_list(
            &event_tx, &local_master_id, &local_device, &local_master,
            sender_peer_id, &ws_cmd_tx, &rooms, Some(list.clone()), &db, &pass,
        )
        .await;

        crate::storage::MessageStore::open(&db, &pass)
            .unwrap()
            .load_device_list(&list.master_peer_id)
            .ok()
            .flatten()
            .map(|l| l.devices)
            .unwrap_or_default()
    }

    /// CRYPTO-1. A master-signed device list is public the moment it is announced,
    /// so holding a genuine one proves nothing about who is holding it. Replaying
    /// the victim's own list from an unlisted socket must persist nothing and bind
    /// nothing: the moment `sender -> victim_master` lands in the resolver, the
    /// victim's DM fan-out reaches the attacker and its Olm key exchange is waved
    /// through on the same set.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn ingest_rejects_list_delivered_by_an_unlisted_device() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();

        let victim_master = kp(0x40);
        let victim_master_id = victim_master.peer_id();
        let victim_device = kp(0x41).peer_id();
        let attacker_device = kp(0x42).peer_id();

        let list = build_signed_device_list(
            &victim_master, 3, vec![victim_device.clone()], Vec::new(),
        );
        // Untouched and genuinely signed. Only the socket it arrives on is wrong.
        assert!(verify_device_list(&list), "the replayed list is the victim's real one");

        let stored = ingest_list_from(&list, &attacker_device).await;
        assert!(
            stored.is_empty(),
            "a replay from an unlisted device must persist nothing, got {stored:?}",
        );
        assert_ne!(
            super::super::resolver::resolve(&attacker_device),
            victim_master_id,
            "and it must never bind the delivering device to the victim's master",
        );

        // A device that IS in the list but has been tombstoned is the same answer:
        // a revoked device cannot re-admit itself by delivering a list.
        let revoking = build_signed_device_list(
            &victim_master, 4, vec![victim_device.clone()], vec![attacker_device.clone()],
        );
        let stored = ingest_list_from(&revoking, &attacker_device).await;
        assert!(
            stored.is_empty(),
            "a revoked delivering device is refused too, got {stored:?}",
        );

        super::super::resolver::clear_all();
    }

    /// The other half: the honest case still works. A device the master SIGNED for
    /// is persisted and mapped, which is what presence collapse and DM fan-out read.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn ingest_accepts_list_delivered_by_a_listed_device() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();

        let master = kp(0x43);
        let master_id = master.peer_id();
        let device_a = kp(0x44).peer_id();
        let device_b = kp(0x45).peer_id();

        let list = build_signed_device_list(
            &master, 2, vec![device_a.clone(), device_b.clone()], Vec::new(),
        );
        let stored = ingest_list_from(&list, &device_b).await;
        assert!(
            stored.contains(&device_a) && stored.contains(&device_b),
            "both signed devices must be persisted, got {stored:?}",
        );
        assert_eq!(
            super::super::resolver::resolve(&device_b), master_id,
            "the delivering device maps to the master that named it",
        );

        super::super::resolver::clear_all();
    }

    /// A legacy keystone published `devices = [master]` and transmits AS the
    /// master, so the master peer id itself is an accepted deliverer. Both shapes
    /// are covered: the classic one, and a list that names only a separate device
    /// while the master hands it over.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn ingest_accepts_legacy_master_as_delivering_device() {
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::clear_all();

        let master = kp(0x46);
        let master_id = master.peer_id();

        let keystone = build_signed_device_list(
            &master, 1, vec![master_id.clone()], Vec::new(),
        );
        let stored = ingest_list_from(&keystone, &master_id).await;
        assert!(
            stored.contains(&master_id),
            "the keystone shape (devices = [master], sent by the master) must ingest, got {stored:?}",
        );

        let device = kp(0x47).peer_id();
        let rotated = build_signed_device_list(&master, 2, vec![device.clone()], Vec::new());
        let stored = ingest_list_from(&rotated, &master_id).await;
        assert!(
            stored.contains(&device),
            "the master may deliver a list that names only its devices, got {stored:?}",
        );

        super::super::resolver::clear_all();
    }

    /// The membership half of the reject's attribution gate, pinned next to the
    /// signature math it rides on. `verify_device_list` proves a list was signed by
    /// the master it names; it says NOTHING about which device delivered it, so the
    /// FriendReject arm additionally requires the relay-authenticated sender to be
    /// listed and un-revoked. Both halves are needed: a valid list captured off the
    /// wire would otherwise let any device speak for that identity.
    #[test]
    fn carried_list_binds_the_sending_device() {
        let master = kp(0x6a);
        let mine = kp(0x6b).peer_id();
        let stranger = kp(0x6c).peer_id();
        let revoked_dev = kp(0x6d).peer_id();
        let list = build_signed_device_list(
            &master, 2, vec![mine.clone()], vec![revoked_dev.clone()],
        );

        assert!(verify_device_list(&list), "baseline: the list itself verifies");
        assert!(list.devices.iter().any(|d| *d == mine), "the listed device is bound");
        assert!(
            !list.devices.iter().any(|d| *d == stranger),
            "a device that is not in the list must not pass the sender check",
        );
        assert!(
            list.revoked.iter().any(|r| *r == revoked_dev),
            "a revoked device must not pass the sender check either",
        );

        // The same three statements through the shared predicate every ingest
        // path now runs, so the call sites and the ingest cannot drift apart.
        assert!(device_list_binds_sender(&list, &mine));
        assert!(!device_list_binds_sender(&list, &stranger));
        assert!(!device_list_binds_sender(&list, &revoked_dev));
        assert!(
            device_list_binds_sender(&list, &master.peer_id()),
            "the legacy master-as-device deliverer is the one addition",
        );

        // And a list signed by a DIFFERENT master cannot be re-labelled: the
        // pubkey -> peer_id binding inside verify_device_list is what stops a
        // captured list being replayed under someone else's identity.
        let mut stolen = list.clone();
        stolen.master_peer_id = kp(0x6e).peer_id();
        assert!(!verify_device_list(&stolen), "master binding must reject a relabelled list");
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

        let list = build_signed_device_list(
            &sender_master, 1, vec![sender_device_id.clone()], Vec::new(),
        );
        let good = signed_carried_bundle(
            &sender_device, &sender_device_id, &our_master,
            "aWRlbnRpdHk".to_string(), "b25ldGltZQ".to_string(),
        );
        assert!(verify_carried_bundle(&our_master, &list, &good), "a freshly built bundle must verify");
        assert_eq!(
            carried_bundle_sender_device(&good).as_deref(),
            Some(sender_device_id.as_str()),
        );

        // 1. Signature gates: swapped keys, cleared signature, moved timestamp.
        let mut swapped = good.clone();
        swapped.one_time_key = "b3RoZXI".to_string();
        assert!(!verify_carried_bundle(&our_master, &list, &swapped), "substituted one-time key");
        let mut swapped_ik = good.clone();
        swapped_ik.identity_key = "b3RoZXI".to_string();
        assert!(!verify_carried_bundle(&our_master, &list, &swapped_ik), "substituted identity key");
        let mut unsigned = good.clone();
        unsigned.sig_b64 = String::new();
        assert!(!verify_carried_bundle(&our_master, &list, &unsigned), "a missing signature is a REJECT, never a bypass");
        let mut ts_moved = good.clone();
        ts_moved.ts += 1;
        assert!(!verify_carried_bundle(&our_master, &list, &ts_moved), "ts is signed");

        // 2. The signing device must be in the sender's master-signed list.
        let stranger = kp(0x54);
        let stranger_id = stranger.peer_id();
        let stranger_bundle = signed_carried_bundle(
            &stranger, &stranger_id, &our_master,
            "aWRlbnRpdHk".to_string(), "b25ldGltZQ".to_string(),
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &stranger_bundle),
            "a device outside the signed list must be refused even with a valid signature",
        );
        let revoked_list = build_signed_device_list(
            &sender_master, 2, vec![sender_device_id.clone()], vec![sender_device_id.clone()],
        );
        assert!(
            !verify_carried_bundle(&our_master, &revoked_list, &good),
            "a REVOKED device must be refused",
        );
        let mut forged_list = list.clone();
        forged_list.version = 99;
        assert!(
            !verify_carried_bundle(&our_master, &forged_list, &good),
            "a device list whose own signature does not verify must be refused",
        );

        // 3. Addressed to US.
        let elsewhere = signed_carried_bundle(
            &sender_device, &sender_device_id, &kp(0x55).peer_id(),
            "aWRlbnRpdHk".to_string(), "b25ldGltZQ".to_string(),
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &elsewhere),
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
            verify_carried_bundle(&our_master, &list, &sign_at(now - 3 * 24 * 3600)),
            "three days old is well inside the carried window",
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &sign_at(now - MAX_CARRIED_BUNDLE_AGE_SECS - 60)),
            "past the carried window is a REJECT",
        );
        assert!(
            !verify_carried_bundle(&our_master, &list, &sign_at(now + KEY_EXCHANGE_SKEW_SECS + 60)),
            "a bundle from the future is a REJECT",
        );
    }
}
