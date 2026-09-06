//! Support credentials: the proof that an identity bought a piece of shop art
//! (design `reports/ARTIST_SHOP_DESIGN.md` section 5).
//!
//! A credential is a blind signature (RFC 9474, `support_rsa.rs`) over a message
//! binding the buyer's MASTER peer id to an item, so the shop never learns which
//! identity redeemed which code. A viewer verifies it OFFLINE against the root
//! key pinned below, because every entry carries the whole chain:
//!
//! ```text
//! root (pinned here)  signs  issuer (the shop's Ed25519 key)
//! issuer              signs  key    (one RSA-3072 key per listing)
//! key                 signs  sig    (blind, over this profile's master id)
//! ```
//!
//! * [`sanitize_incoming_support_creds`] is the SINGLE receive-side validator:
//!   invalid entries are dropped in silence and the survivors re-serialized, so
//!   the database holds what verified and nothing a sender appended.
//! * The message binds the MASTER peer id, so a credential copied onto another
//!   profile fails there: stealing one is useless.
//! * The field is NOT in `profile_signing_payload`: a credential already binds
//!   the identity, and adding it would break the profile signature against every
//!   shipped client for no gain (the same reasoning as `avatar_frame`).
//! * [`T_TWITCH_OWNER`] rides the profile and is the only source of the purple
//!   chip; [`T_TWITCH_FOLLOW`] is presented at join time and NEVER stored
//!   ([`keep_verified`] caps it at zero, in both directions). Both carry a
//!   `period`, the 90-day window they were minted in, checked against the clock
//!   with one window of grace.

use base64::Engine;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::support_rsa;

// ── Constants ─────────────────────────────────────────────────────────

/// The root public key, pinned. Generated 2026-09-02 by
/// `anonlisten-sites/shop/scripts/support_keys.mjs root`; the secret half
/// lives offline, outside every repository, and signs issuer keys only.
pub const ROOT_PUBLIC_KEY_HEX: &str = "b4fa9abcc8bd5aebfe5a2cb50eff6faba14dc3524463ebadf6b125e780aebc25";

/// Domain tags. Each signature in the chain starts with the name of the thing it
/// is over, so one can never be presented as another.
pub const CRED_DOMAIN: &[u8] = b"hollow-support-cred/v1";
pub const ISSUER_DOMAIN: &[u8] = b"hollow-support-issuer/v1";
pub const KEY_DOMAIN: &[u8] = b"hollow-support-key/v1";
/// The two `item` recipes for the Twitch types. Separate tags so an owner
/// item can never be presented as a follow item.
pub const TWITCH_OWNER_DOMAIN: &[u8] = b"hollow-twitch-owner/v1";
pub const TWITCH_FOLLOW_DOMAIN: &[u8] = b"hollow-twitch-follow/v1";
/// What the MASTER signs over the whole `support_creds` field, so a relay
/// cannot strip a holder's marks in flight. See [`support_creds_sig_message`].
pub const CREDS_SIG_DOMAIN: &[u8] = b"hollow-support-creds-sig/v1";

/// Credential types.
pub const T_ITEM: u8 = 1;
pub const T_SUPPORTER: u8 = 2;
/// A verified Twitch account: the holder proved, through the shop's OAuth
/// verifier, that they hold the account named by `parts`. Source of the chip.
pub const T_TWITCH_OWNER: u8 = 3;
/// A verified Twitch FOLLOW of one channel, at an age bucket and a sub tier.
/// Presented at join time and NEVER on a profile: it names a channel the holder
/// follows, theirs to disclose to that channel's server and to nobody else.
pub const T_TWITCH_FOLLOW: u8 = 4;

/// The inline cap (design 5.5): three item credentials and one supporter
/// credential ride the light announce; anything past that is dropped by the
/// sanitizer, never an error.
pub const MAX_ITEM_CREDS: usize = 3;
pub const MAX_SUPPORTER_CREDS: usize = 1;
/// One verified Twitch account per profile.
pub const MAX_TWITCH_OWNER_CREDS: usize = 1;
/// A follow credential NEVER rides the profile. Zero is the cap, enforced in
/// [`keep_verified`], so a sender that appends one is publishing nothing.
pub const MAX_TWITCH_FOLLOW_CREDS: usize = 0;

/// How long one credential window lasts. `period` counts these since the epoch,
/// and for the two Twitch types it is checked against the clock.
pub const PERIOD_DAYS: u64 = 90;

/// The follow-age buckets, in whole days. A verifier picks the LARGEST bucket
/// that is `<=` the real age, so the claim never names the exact date.
pub const FOLLOW_BUCKETS: [u32; 10] = [0, 1, 3, 7, 14, 30, 60, 90, 180, 365];

/// Twitch's subscription tier strings. `"0"` is "no subscription".
pub const SUB_TIERS: [&str; 4] = ["0", "1000", "2000", "3000"];

/// Most file hashes one credential may vouch for. A bundle of four eight-file
/// packs is the largest set the shop would sell, and this is room past it.
pub const MAX_PARTS: usize = 32;

/// Receive-side backstop on the raw field. Four full entries are about six
/// kilobytes; an oversized field is treated as ABSENT (preserve what we
/// stored), the same rule as the showcase board.
pub const MAX_CREDS_JSON_BYTES: usize = 16 * 1024;

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

// ── The root ──────────────────────────────────────────────────────────

/// The pinned root public key. In test builds a fixed TEST root, so the harness
/// can mint credentials without the offline secret; a production build only ever
/// answers the constant above.
pub fn root_verifying_key() -> VerifyingKey {
    #[cfg(test)]
    {
        test_root_signing_key().verifying_key()
    }
    #[cfg(not(test))]
    {
        pinned_root().expect("ROOT_PUBLIC_KEY_HEX is a valid Ed25519 public key")
    }
}

/// Parse the pinned constant. Its own function so a test can prove the
/// constant is a real key before a release ships with a typo in it.
pub fn pinned_root() -> Result<VerifyingKey, String> {
    let bytes = hex::decode(ROOT_PUBLIC_KEY_HEX).map_err(|e| format!("root key hex: {e}"))?;
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| "root key is not 32 bytes".to_string())?;
    VerifyingKey::from_bytes(&arr).map_err(|e| format!("root key point: {e}"))
}

/// The deterministic root every test build uses. NEVER the real one.
#[cfg(test)]
pub(crate) fn test_root_signing_key() -> SigningKey {
    SigningKey::from_bytes(&[42u8; 32])
}

// ── Messages ──────────────────────────────────────────────────────────

/// The message a credential signs (design 5.3):
///
/// ```text
/// "hollow-support-cred/v1" || t:u8 || len(master):u16 BE || master || item:32 || period:u32 BE
/// ```
///
/// `master` is the buyer's MASTER peer id as UTF-8, never a device id: the
/// profile is master-keyed and the credential syncs to siblings with it.
pub fn credential_message(t: u8, master_peer_id: &str, item: &[u8; 32], period: u32) -> Vec<u8> {
    let master = master_peer_id.as_bytes();
    let mut out = Vec::with_capacity(CRED_DOMAIN.len() + 1 + 2 + master.len() + 32 + 4);
    out.extend_from_slice(CRED_DOMAIN);
    out.push(t);
    out.extend_from_slice(&(master.len().min(u16::MAX as usize) as u16).to_be_bytes());
    out.extend_from_slice(&master[..master.len().min(u16::MAX as usize)]);
    out.extend_from_slice(item);
    out.extend_from_slice(&period.to_be_bytes());
    out
}

/// What the root signs: the issuer's public key under its domain tag.
pub fn issuer_message(issuer_pk: &[u8; 32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(ISSUER_DOMAIN.len() + 32);
    out.extend_from_slice(ISSUER_DOMAIN);
    out.extend_from_slice(issuer_pk);
    out
}

/// What the issuer signs for one listing: type, item, period and the RSA
/// public key (PKCS#1 DER) under the key domain tag.
pub fn key_message(t: u8, item: &[u8; 32], period: u32, key_der: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(KEY_DOMAIN.len() + 1 + 32 + 4 + key_der.len());
    out.extend_from_slice(KEY_DOMAIN);
    out.push(t);
    out.extend_from_slice(item);
    out.extend_from_slice(&period.to_be_bytes());
    out.extend_from_slice(key_der);
    out
}

/// Is `s` a lowercase 64-hex SHA-256?
fn is_hex64(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The item hash of a listing: SHA-256 over its file hashes sorted ascending
/// and concatenated as raw 32-byte values. Returns the hash and the sorted,
/// deduplicated list it was computed over, which is what an entry carries.
pub fn item_hash(parts: &[String]) -> Result<([u8; 32], Vec<String>), String> {
    let mut sorted: Vec<String> = parts.iter().map(|p| p.to_ascii_lowercase()).collect();
    sorted.sort();
    sorted.dedup();
    if sorted.is_empty() {
        return Err("an item needs at least one file hash".into());
    }
    if sorted.len() > MAX_PARTS {
        return Err(format!("an item carries at most {MAX_PARTS} file hashes"));
    }
    let mut h = Sha256::new();
    for part in &sorted {
        if !is_hex64(part) {
            return Err("a file hash is 64 hex characters".into());
        }
        h.update(hex::decode(part).map_err(|e| e.to_string())?);
    }
    Ok((h.finalize().into(), sorted))
}

/// Is `s` a Twitch numeric id? Decimal digits, 1 to 20 of them.
pub fn valid_twitch_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 20 && s.bytes().all(|b| b.is_ascii_digit())
}

/// Is `s` a Twitch login in the canonical form a credential carries?
/// `[a-z0-9_]{4,25}`, already lowercased: an entry has exactly one spelling,
/// so `Streamer` and `streamer` can never sit on a profile as two marks.
pub fn valid_twitch_login(s: &str) -> bool {
    (4..=25).contains(&s.len())
        && s.bytes().all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'_'))
}

/// The `item` of a verified-account credential:
///
/// ```text
/// SHA-256("hollow-twitch-owner/v1" || 0x00 || user_id || 0x00 || login)
/// ```
///
/// `parts = [twitch_user_id, login_lowercase]`: the id keeps the credential
/// meaningful across a rename, the login is what the chip draws. Returns the
/// hash and the canonical parts an entry must carry.
pub fn twitch_owner_item(parts: &[String]) -> Result<([u8; 32], Vec<String>), String> {
    if parts.len() != 2 {
        return Err("a Twitch account credential names an id and a login".into());
    }
    let (user_id, login) = (parts[0].as_str(), parts[1].as_str());
    if !valid_twitch_id(user_id) {
        return Err("a Twitch user id is decimal digits".into());
    }
    if !valid_twitch_login(login) {
        return Err("a Twitch login is 4 to 25 lowercase letters, digits or underscores".into());
    }
    let mut h = Sha256::new();
    h.update(TWITCH_OWNER_DOMAIN);
    h.update([0u8]);
    h.update(user_id.as_bytes());
    h.update([0u8]);
    h.update(login.as_bytes());
    Ok((h.finalize().into(), vec![user_id.to_string(), login.to_string()]))
}

/// The `item` of a follow credential:
///
/// ```text
/// SHA-256("hollow-twitch-follow/v1" || 0x00 || broadcaster || 0x00 || bucket || 0x00 || tier)
/// ```
///
/// `parts = [broadcaster_id, age_bucket_days, tier]`, all decimal ASCII. The
/// bucket is one of [`FOLLOW_BUCKETS`] and the tier one of [`SUB_TIERS`], so the
/// whole claim comes off a fixed grid: nothing in it identifies the follower.
pub fn twitch_follow_item(parts: &[String]) -> Result<([u8; 32], Vec<String>), String> {
    if parts.len() != 3 {
        return Err("a Twitch follow credential names a channel, a bucket and a tier".into());
    }
    let (broadcaster, bucket, tier) = (parts[0].as_str(), parts[1].as_str(), parts[2].as_str());
    if !valid_twitch_id(broadcaster) {
        return Err("a Twitch broadcaster id is decimal digits".into());
    }
    if !FOLLOW_BUCKETS.iter().any(|b| b.to_string() == bucket) {
        return Err("that is not one of the follow-age buckets".into());
    }
    if !SUB_TIERS.contains(&tier) {
        return Err("that is not a Twitch subscription tier".into());
    }
    let mut h = Sha256::new();
    h.update(TWITCH_FOLLOW_DOMAIN);
    h.update([0u8]);
    h.update(broadcaster.as_bytes());
    h.update([0u8]);
    h.update(bucket.as_bytes());
    h.update([0u8]);
    h.update(tier.as_bytes());
    Ok((
        h.finalize().into(),
        vec![broadcaster.to_string(), bucket.to_string(), tier.to_string()],
    ))
}

/// The largest [`FOLLOW_BUCKETS`] entry that is `<=` `days`. The SHOP runs this
/// against a real follow date; the app carries it so the rule has one written
/// form.
#[allow(dead_code)]
pub fn bucket_for_days(days: u32) -> u32 {
    *FOLLOW_BUCKETS.iter().rev().find(|b| **b <= days).unwrap_or(&0)
}

/// The credential window `unix_secs` falls in: `floor(secs / 86400 / 90)`.
pub fn period_of(unix_secs: u64) -> u32 {
    (unix_secs / 86_400 / PERIOD_DAYS) as u32
}

/// The window we are in right now.
pub fn now_period() -> u32 {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    period_of(secs)
}

/// Is `period` acceptable to a verifier standing in `now`? The current window or
/// the one before it, so a credential does not die at midnight. Zero is never in
/// the window, which is what makes `period` REQUIRED for the Twitch types.
pub fn period_in_window(period: u32, now: u32) -> bool {
    period != 0 && (period == now || period + 1 == now)
}

/// What the MASTER signs over the whole `support_creds` field:
///
/// ```text
/// "hollow-support-creds-sig/v1" || len(peer):u16 BE || master || updated_at:i64 BE || field
/// ```
///
/// Not about forgery, since the entries already bind the identity: about DENIAL.
/// On the plaintext `ProfileUpdate` fallback a relay can rewrite the field to
/// `""` in flight and the profile signature still verifies, so every receiver
/// would read it as the holder's explicit clear. Binding `updated_at` stops that
/// rewrite being replayed out of an older genuine announce.
pub fn support_creds_sig_message(
    master_peer_id: &str,
    updated_at: i64,
    support_creds: &str,
) -> Vec<u8> {
    let master = master_peer_id.as_bytes();
    let capped = master.len().min(u16::MAX as usize);
    let mut out =
        Vec::with_capacity(CREDS_SIG_DOMAIN.len() + 2 + capped + 8 + support_creds.len());
    out.extend_from_slice(CREDS_SIG_DOMAIN);
    out.extend_from_slice(&(capped as u16).to_be_bytes());
    out.extend_from_slice(&master[..capped]);
    out.extend_from_slice(&updated_at.to_be_bytes());
    out.extend_from_slice(support_creds.as_bytes());
    out
}

// ── The entry ─────────────────────────────────────────────────────────

/// One credential as it rides the profile's `support_creds` JSON array.
/// Self-contained: a viewer verifies it with the pinned root alone. About 1.4 KB.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CredentialEntry {
    /// [`T_ITEM`], [`T_SUPPORTER`], [`T_TWITCH_OWNER`] or
    /// [`T_TWITCH_FOLLOW`].
    #[serde(default)]
    pub t: u8,
    /// 64-hex hash of `parts` under this type's recipe ([`item_hash`],
    /// [`twitch_owner_item`], [`twitch_follow_item`]); zeros for a supporter
    /// credential.
    #[serde(default)]
    pub item: String,
    /// Months since 2026-01 for a supporter credential; the 90-day window
    /// ([`now_period`]) for the two Twitch types, where it is checked against
    /// the clock; 0 for an item.
    #[serde(default)]
    pub period: u32,
    /// What `item` is over: the listing's file hashes for an item credential,
    /// `[user_id, login]` for a Twitch account, `[broadcaster_id, bucket,
    /// tier]` for a follow.
    #[serde(default)]
    pub parts: Vec<String>,
    /// The listing's RSA issuing public key, PKCS#1 DER, base64.
    #[serde(default)]
    pub key: String,
    /// Issuer signature over [`key_message`], base64.
    #[serde(default)]
    pub key_sig: String,
    /// The shop's issuer public key, 32 bytes, base64.
    #[serde(default)]
    pub issuer: String,
    /// Root signature over [`issuer_message`], base64.
    #[serde(default)]
    pub issuer_sig: String,
    /// The blind signature, unblinded, over [`credential_message`] for this
    /// profile's master peer id. Base64, 384 bytes.
    #[serde(default)]
    pub sig: String,
    /// The HOLDER's choice: show this mark next to their name on chat rows and
    /// member lists. Not signed, because a rewritten flag changes where a mark is
    /// drawn, not whether it is real. Ignored for the two Twitch types.
    #[serde(default)]
    pub badge: bool,
}

/// A credential that verified against a specific master peer id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedCredential {
    pub t: u8,
    pub item: [u8; 32],
    pub period: u32,
    pub parts: Vec<String>,
    pub badge: bool,
}

fn b64_decode(field: &str, s: &str, max: usize) -> Result<Vec<u8>, String> {
    if s.len() > max {
        return Err(format!("{field} is too long"));
    }
    B64.decode(s).map_err(|e| format!("{field} is not base64: {e}"))
}

fn bytes32(field: &str, v: &[u8]) -> Result<[u8; 32], String> {
    v.try_into().map_err(|_| format!("{field} is not 32 bytes"))
}

fn ed_sig(field: &str, v: &[u8]) -> Result<Signature, String> {
    let arr: [u8; 64] = v.try_into().map_err(|_| format!("{field} is not 64 bytes"))?;
    Ok(Signature::from_bytes(&arr))
}

/// The chain above a credential's own signature, verified: root -> issuer ->
/// key, and the claim's shape. What the redeem path checks BEFORE it spends a
/// code, and the first three steps of [`verify_entry`].
pub struct VerifiedChain {
    pub item: [u8; 32],
    /// Sorted, deduplicated, exactly what the entry must carry.
    pub parts: Vec<String>,
    /// The issuing public key, PKCS#1 DER, parsed and sized.
    pub key_der: Vec<u8>,
}

/// Verify the claim's shape and the two Ed25519 links from `root` down to the
/// listing's RSA key. Every failure is a refusal with a reason; the clock comes
/// from [`now_period`].
#[allow(clippy::too_many_arguments)]
pub fn verify_chain(
    t: u8,
    item_hex: &str,
    parts: &[String],
    period: u32,
    key_b64: &str,
    key_sig_b64: &str,
    issuer_b64: &str,
    issuer_sig_b64: &str,
    root: &VerifyingKey,
) -> Result<VerifiedChain, String> {
    verify_chain_at(
        t, item_hex, parts, period, key_b64, key_sig_b64, issuer_b64, issuer_sig_b64, root,
        now_period(),
    )
}

/// [`verify_chain`] against an explicit window.
#[allow(clippy::too_many_arguments)]
pub fn verify_chain_at(
    t: u8,
    item_hex: &str,
    parts: &[String],
    period: u32,
    key_b64: &str,
    key_sig_b64: &str,
    issuer_b64: &str,
    issuer_sig_b64: &str,
    root: &VerifyingKey,
    now_period: u32,
) -> Result<VerifiedChain, String> {
    // 1. The shape of the claim.
    if !is_hex64(item_hex) {
        return Err("item is not a 64-hex hash".into());
    }
    let item: [u8; 32] = bytes32("item", &hex::decode(item_hex).map_err(|e| e.to_string())?)?;
    let parts = match t {
        T_ITEM => {
            if period != 0 {
                return Err("an item credential has no period".into());
            }
            let (computed, sorted) = item_hash(parts)?;
            if computed != item || sorted != parts {
                return Err("item does not match its parts".into());
            }
            sorted
        }
        T_SUPPORTER => {
            if !parts.is_empty() || item != [0u8; 32] {
                return Err("a supporter credential names no parts".into());
            }
            Vec::new()
        }
        // The Twitch types are facts about a moment, so a credential minted two
        // windows ago is refused here rather than rendered as if still true.
        T_TWITCH_OWNER | T_TWITCH_FOLLOW => {
            if !period_in_window(period, now_period) {
                return Err("the credential is outside its window".into());
            }
            let (computed, canonical) = if t == T_TWITCH_OWNER {
                twitch_owner_item(parts)?
            } else {
                twitch_follow_item(parts)?
            };
            if computed != item || canonical != parts {
                return Err("item does not match its parts".into());
            }
            canonical
        }
        _ => return Err("unknown credential type".into()),
    };

    // 2. root -> issuer.
    let issuer_pk = bytes32("issuer", &b64_decode("issuer", issuer_b64, 64)?)?;
    let issuer_vk = VerifyingKey::from_bytes(&issuer_pk).map_err(|e| format!("issuer key: {e}"))?;
    let issuer_sig = ed_sig("issuer_sig", &b64_decode("issuer_sig", issuer_sig_b64, 128)?)?;
    root.verify_strict(&issuer_message(&issuer_pk), &issuer_sig)
        .map_err(|_| "the issuer key is not signed by the root".to_string())?;

    // 3. issuer -> key.
    let key_der = b64_decode("key", key_b64, 1024)?;
    let key_sig = ed_sig("key_sig", &b64_decode("key_sig", key_sig_b64, 128)?)?;
    issuer_vk
        .verify_strict(&key_message(t, &item, period, &key_der), &key_sig)
        .map_err(|_| "the issuing key is not signed by the issuer".to_string())?;
    support_rsa::public_key_from_der(&key_der)?;

    Ok(VerifiedChain { item, parts, key_der })
}

/// Verify one entry for the profile of `master_peer_id`, walking the whole chain
/// from `root`. Every failure is a refusal; nothing is partially accepted.
pub fn verify_entry(
    entry: &CredentialEntry,
    master_peer_id: &str,
    root: &VerifyingKey,
) -> Result<VerifiedCredential, String> {
    verify_entry_at(entry, master_peer_id, root, now_period())
}

/// [`verify_entry`] against an explicit window.
pub fn verify_entry_at(
    entry: &CredentialEntry,
    master_peer_id: &str,
    root: &VerifyingKey,
    now_period: u32,
) -> Result<VerifiedCredential, String> {
    let chain = verify_chain_at(
        entry.t, &entry.item, &entry.parts, entry.period, &entry.key, &entry.key_sig,
        &entry.issuer, &entry.issuer_sig, root, now_period,
    )?;
    let pk = support_rsa::public_key_from_der(&chain.key_der)?;

    // 4. key -> sig, over THIS profile's master id.
    let sig = b64_decode("sig", &entry.sig, 1024)?;
    let message = credential_message(entry.t, master_peer_id, &chain.item, entry.period);
    if !support_rsa::verify(&pk, &sig, &message) {
        return Err("the credential does not verify for this profile".into());
    }

    Ok(VerifiedCredential {
        t: entry.t,
        item: chain.item,
        period: entry.period,
        parts: chain.parts,
        badge: entry.badge,
    })
}

/// Parse a stored `support_creds` field tolerantly, WITHOUT verifying: for
/// listing our own credentials and for renderers reading a row the sanitizer
/// already wrote. Anything that is not an array of entries is empty.
#[allow(dead_code)] // the issuing side and the tests
pub fn parse_stored(json: &str) -> Vec<CredentialEntry> {
    if json.is_empty() || json.len() > MAX_CREDS_JSON_BYTES {
        return Vec::new();
    }
    let Ok(values) = serde_json::from_str::<Vec<serde_json::Value>>(json) else {
        return Vec::new();
    };
    values
        .into_iter()
        .filter_map(|v| serde_json::from_value::<CredentialEntry>(v).ok())
        .collect()
}

/// Serialize entries as the field carries them.
pub fn encode_entries(entries: &[CredentialEntry]) -> String {
    if entries.is_empty() {
        return String::new();
    }
    serde_json::to_string(entries).unwrap_or_default()
}

/// Keep the entries that verify for `master_peer_id`, in order, deduplicated by
/// item (the first wins) and capped. The one filter every writer of the field
/// goes through.
pub fn keep_verified(
    entries: Vec<CredentialEntry>,
    master_peer_id: &str,
    root: &VerifyingKey,
) -> Vec<CredentialEntry> {
    keep_verified_at(entries, master_peer_id, root, now_period())
}

/// [`keep_verified`] against an explicit window.
pub fn keep_verified_at(
    entries: Vec<CredentialEntry>,
    master_peer_id: &str,
    root: &VerifyingKey,
    now_period: u32,
) -> Vec<CredentialEntry> {
    let mut kept: Vec<CredentialEntry> = Vec::new();
    let mut seen_items: Vec<String> = Vec::new();
    let mut items = 0usize;
    let mut supporters = 0usize;
    let mut twitch_owners = 0usize;
    let mut twitch_follows = 0usize;
    for entry in entries {
        let Ok(verified) = verify_entry_at(&entry, master_peer_id, root, now_period) else {
            continue;
        };
        if seen_items.contains(&entry.item) {
            continue;
        }
        // Every type carries its own cap, and the follow cap is ZERO: a follow
        // credential names a channel somebody watches, theirs to hand to that
        // channel's server at join time and to nobody else.
        let (count, cap) = match verified.t {
            T_ITEM => (&mut items, MAX_ITEM_CREDS),
            T_SUPPORTER => (&mut supporters, MAX_SUPPORTER_CREDS),
            T_TWITCH_OWNER => (&mut twitch_owners, MAX_TWITCH_OWNER_CREDS),
            _ => (&mut twitch_follows, MAX_TWITCH_FOLLOW_CREDS),
        };
        if *count >= cap {
            continue;
        }
        *count += 1;
        seen_items.push(entry.item.clone());
        kept.push(entry);
    }
    kept
}

/// Receive-side gate for the `support_creds` profile field: the ONE validator
/// (wiki `security_write_gates.md`).
///
/// * `None`      -> `None`: an old client, preserve what we stored.
/// * `Some("")`  -> `Some("")`: an explicit clear.
/// * oversized or not a JSON array -> `None`: treated as absent.
/// * otherwise   -> the verified, deduplicated, capped entries re-serialized,
///   which may be `Some("")` when nothing survived.
///
/// `master_peer_id` is the RESOLVED master the profile is stored under; the
/// signature binds it, so a device id here would refuse every real entry.
pub fn sanitize_incoming_support_creds(raw: Option<&str>, master_peer_id: &str) -> Option<String> {
    let raw = raw?;
    if raw.is_empty() {
        return Some(String::new());
    }
    if raw.len() > MAX_CREDS_JSON_BYTES {
        return None;
    }
    let values = serde_json::from_str::<Vec<serde_json::Value>>(raw).ok()?;
    let entries: Vec<CredentialEntry> = values
        .into_iter()
        .filter_map(|v| serde_json::from_value::<CredentialEntry>(v).ok())
        .collect();
    let kept = keep_verified(entries, master_peer_id, &root_verifying_key());
    Some(encode_entries(&kept))
}

// ── The client side of a redemption ───────────────────────────────────

/// The blinded request the client sends, plus the secret it finishes with.
pub struct BlindRequest {
    /// What goes to the shop.
    pub blinded: Vec<u8>,
    /// The message the signature will be over. Kept so `finish` can verify.
    pub message: Vec<u8>,
    state: blind_rsa_signatures::BlindingResult,
}

/// Blind the credential message for `master_peer_id` under the listing's
/// issuing key. Nothing about the identity leaves this function in the
/// clear: `blinded` is what the shop sees.
pub fn blind_request(
    key_der: &[u8],
    t: u8,
    master_peer_id: &str,
    item: &[u8; 32],
    period: u32,
) -> Result<BlindRequest, String> {
    let pk = support_rsa::public_key_from_der(key_der)?;
    let message = credential_message(t, master_peer_id, item, period);
    let (blinded, state) = support_rsa::blind(&pk, &message)?;
    Ok(BlindRequest { blinded, message, state })
}

/// Unblind the shop's answer and verify it. The signature that comes back
/// is the credential's `sig`.
pub fn finish_request(key_der: &[u8], request: &BlindRequest, blind_sig: &[u8]) -> Result<Vec<u8>, String> {
    let pk = support_rsa::public_key_from_der(key_der)?;
    support_rsa::finalize(&pk, &request.state, blind_sig, &request.message)
}

// ── The issuing side (the shop, through the CLI, and the tests) ───────

/// Root over issuer.
#[allow(dead_code)] // the issuing side and the tests
pub fn sign_issuer(root: &SigningKey, issuer_pk: &[u8; 32]) -> [u8; 64] {
    root.sign(&issuer_message(issuer_pk)).to_bytes()
}

/// Issuer over a listing's key.
#[allow(dead_code)] // the issuing side and the tests
pub fn sign_key(issuer: &SigningKey, t: u8, item: &[u8; 32], period: u32, key_der: &[u8]) -> [u8; 64] {
    issuer.sign(&key_message(t, item, period, key_der)).to_bytes()
}

#[cfg(test)]
pub(crate) mod testing {
    //! Minting real credentials under the TEST root, for the harness and the
    //! unit tests here. The shop does the same three steps with its own keys.

    use super::*;

    /// An issuer signed by the test root.
    pub(crate) struct TestIssuer {
        pub sk: SigningKey,
        pub pk: [u8; 32],
        pub root_sig: [u8; 64],
    }

    pub(crate) fn test_issuer() -> TestIssuer {
        let sk = SigningKey::from_bytes(&[7u8; 32]);
        let pk = sk.verifying_key().to_bytes();
        let root_sig = sign_issuer(&test_root_signing_key(), &pk);
        TestIssuer { sk, pk, root_sig }
    }

    /// A listing's issuing key, signed by the issuer for `parts`.
    pub(crate) struct TestListingKey {
        pub sk_der: Vec<u8>,
        pub pk_der: Vec<u8>,
        pub item: [u8; 32],
        pub parts: Vec<String>,
        pub key_sig: [u8; 64],
    }

    pub(crate) fn test_listing_key(issuer: &TestIssuer, parts: &[String]) -> TestListingKey {
        let (sk_der, pk_der) = support_rsa::generate_issuing_key().expect("keygen");
        let (item, parts) = item_hash(parts).expect("parts");
        let key_sig = sign_key(&issuer.sk, T_ITEM, &item, 0, &pk_der);
        TestListingKey { sk_der, pk_der, item, parts, key_sig }
    }

    /// The whole redemption, in process: blind, sign, finish, assemble.
    pub(crate) fn mint(issuer: &TestIssuer, key: &TestListingKey, master_peer_id: &str) -> CredentialEntry {
        let request = blind_request(&key.pk_der, T_ITEM, master_peer_id, &key.item, 0).expect("blind");
        let sk = support_rsa::secret_key_from_der(&key.sk_der).expect("sk");
        let blind_sig = support_rsa::blind_sign(&sk, &request.blinded).expect("sign");
        let sig = finish_request(&key.pk_der, &request, &blind_sig).expect("finish");
        CredentialEntry {
            t: T_ITEM,
            item: hex::encode(key.item),
            period: 0,
            parts: key.parts.clone(),
            key: B64.encode(&key.pk_der),
            key_sig: B64.encode(key.key_sig),
            issuer: B64.encode(issuer.pk),
            issuer_sig: B64.encode(issuer.root_sig),
            sig: B64.encode(sig),
            badge: false,
        }
    }

    /// One valid entry for `master_peer_id` over `parts`, from scratch.
    pub(crate) fn mint_for(master_peer_id: &str, parts: &[String]) -> CredentialEntry {
        let issuer = test_issuer();
        let key = test_listing_key(&issuer, parts);
        mint(&issuer, &key, master_peer_id)
    }

    /// One RSA issuing key for any `(t, item, period)`, signed by the test
    /// issuer. The shop makes exactly this at the first request for a key.
    pub(crate) struct TestTypedKey {
        pub issuer: TestIssuer,
        pub sk_der: Vec<u8>,
        pub pk_der: Vec<u8>,
        pub key_sig: [u8; 64],
    }

    pub(crate) fn test_typed_key(t: u8, item: &[u8; 32], period: u32) -> TestTypedKey {
        let issuer = test_issuer();
        let (sk_der, pk_der) = support_rsa::generate_issuing_key().expect("keygen");
        let key_sig = sign_key(&issuer.sk, t, item, period, &pk_der);
        TestTypedKey { issuer, sk_der, pk_der, key_sig }
    }

    /// The shop's half of a round: blind-sign what the client sent.
    pub(crate) fn blind_sign_with(key: &TestTypedKey, blinded: &[u8]) -> Vec<u8> {
        let sk = support_rsa::secret_key_from_der(&key.sk_der).expect("sk");
        support_rsa::blind_sign(&sk, blinded).expect("sign")
    }

    /// The whole issuing round for any type, in process: one RSA key per
    /// `(t, item, period)`, signed by the issuer, then blind, sign, finish.
    /// The shop does exactly this with its own keys and its own verifier.
    pub(crate) fn mint_typed(
        master_peer_id: &str,
        t: u8,
        item: [u8; 32],
        parts: Vec<String>,
        period: u32,
    ) -> CredentialEntry {
        let key = test_typed_key(t, &item, period);
        let request =
            blind_request(&key.pk_der, t, master_peer_id, &item, period).expect("blind");
        let blind_sig = blind_sign_with(&key, &request.blinded);
        let sig = finish_request(&key.pk_der, &request, &blind_sig).expect("finish");
        CredentialEntry {
            t,
            item: hex::encode(item),
            period,
            parts,
            key: B64.encode(&key.pk_der),
            key_sig: B64.encode(key.key_sig),
            issuer: B64.encode(key.issuer.pk),
            issuer_sig: B64.encode(key.issuer.root_sig),
            sig: B64.encode(sig),
            badge: false,
        }
    }

    /// A verified-account credential for `master_peer_id`.
    pub(crate) fn mint_owner_for(
        master_peer_id: &str,
        user_id: &str,
        login: &str,
        period: u32,
    ) -> CredentialEntry {
        let parts = vec![user_id.to_string(), login.to_string()];
        let (item, canonical) = twitch_owner_item(&parts).expect("owner parts");
        mint_typed(master_peer_id, T_TWITCH_OWNER, item, canonical, period)
    }

    /// A follow credential for `master_peer_id`.
    pub(crate) fn mint_follow_for(
        master_peer_id: &str,
        broadcaster_id: &str,
        bucket: u32,
        tier: &str,
        period: u32,
    ) -> CredentialEntry {
        let parts = vec![
            broadcaster_id.to_string(),
            bucket.to_string(),
            tier.to_string(),
        ];
        let (item, canonical) = twitch_follow_item(&parts).expect("follow parts");
        mint_typed(master_peer_id, T_TWITCH_FOLLOW, item, canonical, period)
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;

    fn h(byte: u8) -> String {
        hex::encode([byte; 32])
    }

    #[test]
    fn credential_message_bytes_are_pinned() {
        // "hollow-support-cred/v1" || 01 || 0004 || "peer" || 0x11 * 32 || 00000000
        let msg = credential_message(T_ITEM, "peer", &[0x11u8; 32], 0);
        let expected = concat!(
            "686f6c6c6f772d737570706f72742d637265642f7631",
            "01",
            "0004",
            "70656572",
            "1111111111111111111111111111111111111111111111111111111111111111",
            "00000000"
        );
        assert_eq!(hex::encode(&msg), expected);
        // A supporter message carries its period big-endian.
        let msg = credential_message(T_SUPPORTER, "ab", &[0u8; 32], 7);
        assert!(msg.ends_with(&[0, 0, 0, 7]));
        assert_eq!(msg[CRED_DOMAIN.len()], T_SUPPORTER);
        assert_eq!(&msg[CRED_DOMAIN.len() + 1..CRED_DOMAIN.len() + 3], &[0, 2]);
    }

    #[test]
    fn issuer_and_key_messages_are_domain_separated() {
        let issuer = issuer_message(&[9u8; 32]);
        assert!(issuer.starts_with(ISSUER_DOMAIN));
        assert_eq!(issuer.len(), ISSUER_DOMAIN.len() + 32);
        let key = key_message(T_ITEM, &[1u8; 32], 5, b"der");
        assert!(key.starts_with(KEY_DOMAIN));
        assert_eq!(key[KEY_DOMAIN.len()], T_ITEM);
        assert_eq!(&key[KEY_DOMAIN.len() + 33..KEY_DOMAIN.len() + 37], &[0, 0, 0, 5]);
        assert!(key.ends_with(b"der"));
    }

    #[test]
    fn item_hash_sorts_dedups_and_refuses_bad_parts() {
        let (a, sorted_a) = item_hash(&[h(0xbb), h(0xaa)]).unwrap();
        let (b, sorted_b) = item_hash(&[h(0xaa), h(0xbb), h(0xaa)]).unwrap();
        assert_eq!(a, b, "order and duplicates must not change the item");
        assert_eq!(sorted_a, vec![h(0xaa), h(0xbb)]);
        assert_eq!(sorted_a, sorted_b);
        let (c, _) = item_hash(&[h(0xaa)]).unwrap();
        assert_ne!(a, c);
        // Uppercase is normalised, not refused.
        let (d, _) = item_hash(&[h(0xaa).to_ascii_uppercase()]).unwrap();
        assert_eq!(c, d);
        assert!(item_hash(&[]).is_err());
        assert!(item_hash(&["zz".repeat(32)]).is_err());
        assert!(item_hash(&[String::from("abc")]).is_err());
        let many: Vec<String> = (0..=MAX_PARTS as u8).map(h).collect();
        assert!(item_hash(&many).is_err());
    }

    #[test]
    fn a_minted_credential_verifies_for_its_master_only() {
        let issuer = test_issuer();
        let key = test_listing_key(&issuer, &[h(0x11), h(0x22)]);
        let entry = mint(&issuer, &key, "master-A");
        let root = root_verifying_key();
        let ok = verify_entry(&entry, "master-A", &root).expect("verifies for its own master");
        assert_eq!(ok.parts, vec![h(0x11), h(0x22)]);
        assert_eq!(ok.item, key.item);
        assert_eq!(ok.t, T_ITEM);
        // Transplanted onto another profile it is worthless.
        let err = verify_entry(&entry, "master-B", &root).unwrap_err();
        assert!(err.contains("does not verify for this profile"), "{err}");
        // Under a different root the chain breaks at the first link.
        let other_root = SigningKey::from_bytes(&[1u8; 32]).verifying_key();
        let err = verify_entry(&entry, "master-A", &other_root).unwrap_err();
        assert!(err.contains("issuer key is not signed by the root"), "{err}");
    }

    #[test]
    fn two_redemptions_of_one_item_are_two_signatures_for_one_claim() {
        // PSS salts every signature, so the bytes differ; the sanitizer keeps
        // one per item regardless (13.23: "x2" is not a thing).
        let issuer = test_issuer();
        let key = test_listing_key(&issuer, &[h(0x11)]);
        let a = mint(&issuer, &key, "m");
        let b = mint(&issuer, &key, "m");
        assert_eq!(a.item, b.item);
        let root = root_verifying_key();
        assert!(verify_entry(&a, "m", &root).is_ok());
        assert!(verify_entry(&b, "m", &root).is_ok());
        let kept = keep_verified(vec![a.clone(), b], "m", &root);
        assert_eq!(kept, vec![a]);
    }

    #[test]
    fn every_link_of_the_chain_is_checked() {
        let issuer = test_issuer();
        let key = test_listing_key(&issuer, &[h(0x33)]);
        let good = mint(&issuer, &key, "m");
        let root = root_verifying_key();

        // Bad issuer signature.
        let mut e = good.clone();
        e.issuer_sig = B64.encode([0u8; 64]);
        assert!(verify_entry(&e, "m", &root).unwrap_err().contains("issuer key"));

        // An issuer the root never signed, even with a consistent key_sig.
        let rogue = SigningKey::from_bytes(&[99u8; 32]);
        let mut e = good.clone();
        e.issuer = B64.encode(rogue.verifying_key().to_bytes());
        e.key_sig = B64.encode(sign_key(&rogue, T_ITEM, &key.item, 0, &key.pk_der));
        assert!(verify_entry(&e, "m", &root).unwrap_err().contains("issuer key is not signed"));

        // Bad key signature: the issuer never vouched for this RSA key.
        let mut e = good.clone();
        e.key_sig = B64.encode([1u8; 64]);
        assert!(verify_entry(&e, "m", &root).unwrap_err().contains("issuing key is not signed"));

        // The key_sig binds the item: relabelling the parts breaks it.
        let mut e = good.clone();
        let (other_item, other_parts) = item_hash(&[h(0x44)]).unwrap();
        e.item = hex::encode(other_item);
        e.parts = other_parts;
        assert!(verify_entry(&e, "m", &root).unwrap_err().contains("issuing key is not signed"));

        // Parts that do not hash to the item.
        let mut e = good.clone();
        e.parts = vec![h(0x33), h(0x34)];
        assert!(verify_entry(&e, "m", &root).unwrap_err().contains("does not match its parts"));
        let mut e = good.clone();
        e.parts = vec![h(0x34), h(0x33)];
        assert!(verify_entry(&e, "m", &root).is_err(), "parts must be sorted");

        // A wrong blind signature.
        let mut e = good.clone();
        let mut sig = B64.decode(&good.sig).unwrap();
        sig[10] ^= 0x40;
        e.sig = B64.encode(sig);
        assert!(verify_entry(&e, "m", &root).unwrap_err().contains("does not verify"));

        // Malformed fields refuse rather than panic.
        let mut e = good.clone();
        e.item = "nothex".into();
        assert!(verify_entry(&e, "m", &root).is_err());
        let mut e = good.clone();
        e.key = "!!!".into();
        assert!(verify_entry(&e, "m", &root).is_err());
        let mut e = good.clone();
        e.t = 9;
        assert!(verify_entry(&e, "m", &root).is_err());
        let mut e = good.clone();
        e.period = 3;
        assert!(verify_entry(&e, "m", &root).is_err(), "an item has no period");
    }

    #[test]
    fn sanitizer_preserves_clears_drops_dedups_and_caps() {
        assert_eq!(sanitize_incoming_support_creds(None, "m"), None);
        assert_eq!(sanitize_incoming_support_creds(Some(""), "m"), Some(String::new()));
        assert_eq!(sanitize_incoming_support_creds(Some("not json"), "m"), None);
        assert_eq!(sanitize_incoming_support_creds(Some("{}"), "m"), None, "not an array");
        let big = format!("[{}]", "1,".repeat(MAX_CREDS_JSON_BYTES));
        assert_eq!(sanitize_incoming_support_creds(Some(&big), "m"), None, "oversized is absent");

        // Nothing real in the array: stored as an explicit empty set.
        assert_eq!(sanitize_incoming_support_creds(Some("[1, \"x\", {\"t\":1}]"), "m"), Some(String::new()));

        let issuer = test_issuer();
        let keys: Vec<TestListingKey> = (0x50u8..0x55)
            .map(|b| test_listing_key(&issuer, &[h(b)]))
            .collect();
        let mut entries: Vec<CredentialEntry> = keys.iter().map(|k| mint(&issuer, k, "m")).collect();
        // A transplant from another profile, and a junk value, in the middle.
        entries.insert(1, mint(&issuer, &keys[0], "somebody-else"));
        let mut json = serde_json::to_value(&entries).unwrap();
        json.as_array_mut().unwrap().insert(2, serde_json::json!({"t": 1, "item": "x"}));
        let raw = json.to_string();

        let out = sanitize_incoming_support_creds(Some(&raw), "m").expect("a value");
        let kept = parse_stored(&out);
        assert_eq!(kept.len(), MAX_ITEM_CREDS, "capped at three items");
        let items: Vec<&str> = kept.iter().map(|e| e.item.as_str()).collect();
        assert_eq!(
            items,
            vec![entries[0].item.as_str(), entries[2].item.as_str(), entries[3].item.as_str()],
            "the transplant and the junk are gone, order is preserved, the first three real ones stay"
        );
        // What is stored verifies again, entry by entry, and carries nothing
        // the sender appended.
        let root = root_verifying_key();
        for e in &kept {
            verify_entry(e, "m", &root).expect("stored entries verify");
        }
        assert!(!out.contains("somebody-else"));

        // The badge flag survives as the holder set it.
        let mut flagged = mint(&issuer, &keys[0], "m");
        flagged.badge = true;
        let out = sanitize_incoming_support_creds(Some(&encode_entries(&[flagged])), "m").unwrap();
        assert!(parse_stored(&out)[0].badge);
    }

    /// Interop with the shop's side: blind here, sign through the BUILT
    /// `hollowpack` binary, finalize and verify here. Skips with a note when
    /// the binary is not built; it never fakes a pass.
    #[test]
    fn blind_sign_through_the_hollowpack_binary_round_trips() {
        use std::io::Write;
        use std::process::{Command, Stdio};

        let exe = if cfg!(windows) { "hollowpack.exe" } else { "hollowpack" };
        let bin = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../hollow_art/target/release")
            .join(exe);
        if !bin.exists() {
            eprintln!("skipping: build rust/hollow_art in release first ({})", bin.display());
            return;
        }

        // keygen, as the shop runs it at approval.
        let out = Command::new(&bin).arg("keygen").output().expect("run keygen");
        assert!(out.status.success(), "keygen failed: {}", String::from_utf8_lossy(&out.stderr));
        let made: serde_json::Value = serde_json::from_slice(&out.stdout).expect("keygen json");
        let secret_b64 = made["secret_b64"].as_str().expect("secret_b64").to_string();
        let public_der = B64.decode(made["public_b64"].as_str().expect("public_b64")).unwrap();
        assert_eq!(made["bits"].as_u64(), Some(3072));

        // The issuer signs that key for an item, as approval does in Node.
        let issuer = test_issuer();
        let (item, parts) = item_hash(&[h(0x77)]).unwrap();
        let key_sig = sign_key(&issuer.sk, T_ITEM, &item, 0, &public_der);

        // The client blinds.
        let request = blind_request(&public_der, T_ITEM, "master-X", &item, 0).expect("blind");

        // The shop signs, secret on stdin, blinded on the command line.
        let mut child = Command::new(&bin)
            .arg("blind-sign")
            .arg("--blinded")
            .arg(B64.encode(&request.blinded))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("run blind-sign");
        child
            .stdin
            .take()
            .unwrap()
            .write_all(format!("{secret_b64}\n").as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "blind-sign failed: {}", String::from_utf8_lossy(&out.stderr));
        let signed: serde_json::Value = serde_json::from_slice(&out.stdout).expect("blind-sign json");
        let blind_sig = B64.decode(signed["blind_sig_b64"].as_str().expect("blind_sig_b64")).unwrap();

        // The client finishes, and the entry verifies like any other.
        let sig = finish_request(&public_der, &request, &blind_sig).expect("finalize");
        let entry = CredentialEntry {
            t: T_ITEM,
            item: hex::encode(item),
            period: 0,
            parts,
            key: B64.encode(&public_der),
            key_sig: B64.encode(key_sig),
            issuer: B64.encode(issuer.pk),
            issuer_sig: B64.encode(issuer.root_sig),
            sig: B64.encode(sig),
            badge: false,
        };
        verify_entry(&entry, "master-X", &root_verifying_key()).expect("the binary's signature verifies");
        assert!(verify_entry(&entry, "master-Y", &root_verifying_key()).is_err());
    }

    #[test]
    fn pinned_root_constant_is_a_real_key() {
        let key = pinned_root().expect("the pinned root must parse");
        assert_eq!(hex::encode(key.to_bytes()), ROOT_PUBLIC_KEY_HEX);
        assert_ne!(
            key.to_bytes(),
            test_root_signing_key().verifying_key().to_bytes(),
            "the shipped root is never the test root"
        );
    }


    // -- The two Twitch types ------------------------------------------

    /// The `item` recipes, against the contract's known-answer tests. If one of
    /// these literals moves, every credential the shop has ever signed stops
    /// verifying.
    #[test]
    fn twitch_item_recipes_match_the_contract_kats() {
        let (owner, parts) = twitch_owner_item(&[
            "12345".to_string(),
            "somestreamer".to_string(),
        ])
        .expect("owner item");
        assert_eq!(
            hex::encode(owner),
            "be924c37092c5b6014256f49f62220f379f7aec5390b587ecc41b8c55d55ab1b",
        );
        assert_eq!(parts, vec!["12345".to_string(), "somestreamer".to_string()]);

        let (follow, parts) = twitch_follow_item(&[
            "67890".to_string(),
            "30".to_string(),
            "0".to_string(),
        ])
        .expect("follow item");
        assert_eq!(
            hex::encode(follow),
            "a36cd1c6f03bf61bd6d2c522860aeeb037fb9862038713ffb711b1380fca5e2a",
        );
        assert_eq!(parts, vec!["67890".to_string(), "30".to_string(), "0".to_string()]);

        let (follow, _) = twitch_follow_item(&[
            "67890".to_string(),
            "365".to_string(),
            "2000".to_string(),
        ])
        .expect("follow item");
        assert_eq!(
            hex::encode(follow),
            "fd9d50532a17342be7e94d6ad75736be284f2200ebcd6c36b86a27ea9a89476b",
        );

        // And the window arithmetic the same message carries.
        assert_eq!(period_of(1_786_000_000), 229);
    }

    #[test]
    fn twitch_parts_shape_is_enforced() {
        // Logins: too short, too long, uppercase, a dash, a dot.
        for bad in ["abc", &"a".repeat(26), "SomeStreamer", "some-streamer", "some.one"] {
            assert!(
                twitch_owner_item(&["12345".to_string(), bad.to_string()]).is_err(),
                "login {bad} must be refused",
            );
        }
        assert!(twitch_owner_item(&["12345".to_string(), "good_name".to_string()]).is_ok());

        // Ids: empty, a letter, too long.
        for bad in ["", "12a45", &"1".repeat(21)] {
            assert!(
                twitch_owner_item(&[bad.to_string(), "somestreamer".to_string()]).is_err(),
                "id {bad} must be refused",
            );
        }

        // Arity.
        assert!(twitch_owner_item(&["12345".to_string()]).is_err());
        assert!(twitch_follow_item(&["67890".to_string(), "30".to_string()]).is_err());

        // Buckets off the grid, including a non-canonical spelling of one on it.
        for bad in ["31", "2", "400", "030", "-1", ""] {
            assert!(
                twitch_follow_item(&["67890".to_string(), bad.to_string(), "0".to_string()])
                    .is_err(),
                "bucket {bad} must be refused",
            );
        }
        // Tiers off the grid.
        for bad in ["4000", "1", "", "prime"] {
            assert!(
                twitch_follow_item(&["67890".to_string(), "30".to_string(), bad.to_string()])
                    .is_err(),
                "tier {bad} must be refused",
            );
        }

        // The buckets themselves, and the rounding rule: the LARGEST bucket
        // at or below the real age.
        assert_eq!(bucket_for_days(0), 0);
        assert_eq!(bucket_for_days(2), 1);
        assert_eq!(bucket_for_days(13), 7);
        assert_eq!(bucket_for_days(14), 14);
        assert_eq!(bucket_for_days(364), 180);
        assert_eq!(bucket_for_days(100_000), 365);
    }

    #[test]
    fn owner_entry_verifies_in_window_and_fails_after_grace() {
        let root = root_verifying_key();
        let now = 229u32;
        let entry = mint_owner_for("master-A", "12345", "somestreamer", now);

        let ok = verify_entry_at(&entry, "master-A", &root, now).expect("this window verifies");
        assert_eq!(ok.t, T_TWITCH_OWNER);
        assert_eq!(ok.parts, vec!["12345".to_string(), "somestreamer".to_string()]);
        assert_eq!(ok.period, now);

        // One window of grace: minted last window, read this window.
        verify_entry_at(&entry, "master-A", &root, now + 1).expect("the grace window verifies");

        // Two windows on, it is gone.
        let err = verify_entry_at(&entry, "master-A", &root, now + 2).unwrap_err();
        assert!(err.contains("outside its window"), "{err}");
        // And a window that has not happened yet is not a credential either.
        let err = verify_entry_at(&entry, "master-A", &root, now - 1).unwrap_err();
        assert!(err.contains("outside its window"), "{err}");

        // Period zero is refused outright, whatever the clock says.
        let zero = mint_owner_for("master-A", "12345", "somestreamer", 0);
        assert!(verify_entry_at(&zero, "master-A", &root, 0).is_err());

        // Still bound to ONE master, like every other type.
        assert!(verify_entry_at(&entry, "master-B", &root, now).is_err());

        // The signature binds the type: relabelled as an item it breaks at the
        // key signature, which is what the issuer vouched for.
        let mut relabelled = entry.clone();
        relabelled.t = T_ITEM;
        assert!(verify_entry_at(&relabelled, "master-A", &root, now).is_err());

        // And it binds the parts: another login under the same key is not it.
        let mut renamed = entry.clone();
        renamed.parts = vec!["12345".to_string(), "otherstreamer".to_string()];
        let err = verify_entry_at(&renamed, "master-A", &root, now).unwrap_err();
        assert!(err.contains("does not match its parts"), "{err}");
    }

    #[test]
    fn follow_entry_never_rides_the_profile() {
        let root = root_verifying_key();
        let now = 229u32;
        let owner = mint_owner_for("m", "12345", "somestreamer", now);
        let follow = mint_follow_for("m", "67890", 30, "0", now);
        let second_owner = mint_owner_for("m", "54321", "another_one", now);

        // Both are real credentials, on their own terms.
        verify_entry_at(&owner, "m", &root, now).expect("the owner entry verifies");
        let checked = verify_entry_at(&follow, "m", &root, now).expect("the follow entry verifies");
        assert_eq!(checked.t, T_TWITCH_FOLLOW);
        assert_eq!(
            checked.parts,
            vec!["67890".to_string(), "30".to_string(), "0".to_string()],
        );

        // On the profile field, only the account survives: the follow is
        // capped at zero and the second account at one.
        let kept = keep_verified_at(
            vec![follow.clone(), owner.clone(), second_owner.clone()],
            "m",
            &root,
            now,
        );
        assert_eq!(kept, vec![owner.clone()], "one account, no follows");

        // The same through the receive-side door, which is what a hostile
        // sender actually reaches.
        let raw = encode_entries(&[follow.clone(), owner.clone(), second_owner]);
        let out = sanitize_incoming_support_creds(Some(&raw), "m").expect("a value");
        let stored = parse_stored(&out);
        assert_eq!(stored.len(), 1, "{out}");
        assert_eq!(stored[0].t, T_TWITCH_OWNER);
        assert!(!out.contains("67890"), "no channel a follower watches is stored: {out}");

        // A field that is nothing but follow credentials stores as the empty
        // set, exactly like a field of junk.
        let only_follows = encode_entries(&[follow]);
        assert_eq!(
            sanitize_incoming_support_creds(Some(&only_follows), "m"),
            Some(String::new()),
        );
    }

    #[test]
    fn an_item_credential_and_a_twitch_one_share_a_profile() {
        let now = now_period();
        let bought = mint_for("m", &[h(0x11)]);
        let account = mint_owner_for("m", "12345", "somestreamer", now);
        let raw = encode_entries(&[bought.clone(), account.clone()]);
        let out = sanitize_incoming_support_creds(Some(&raw), "m").expect("a value");
        let kept = parse_stored(&out);
        assert_eq!(kept.len(), 2, "the caps are per type: {out}");
        assert_eq!(kept[0].item, bought.item);
        assert_eq!(kept[1].item, account.item);
    }

    #[test]
    fn the_creds_field_signature_message_is_pinned() {
        // "hollow-support-creds-sig/v1" || 0004 || "peer" || 8-byte updated_at || field
        let msg = support_creds_sig_message("peer", 1, "[]");
        let expected = concat!(
            "686f6c6c6f772d737570706f72742d63726564732d7369672f7631",
            "0004",
            "70656572",
            "0000000000000001",
            "5b5d",
        );
        assert_eq!(hex::encode(&msg), expected);
        // Every part of it is bound: the id, the timestamp and the field.
        assert_ne!(
            support_creds_sig_message("peer", 1, "[]"),
            support_creds_sig_message("peex", 1, "[]"),
        );
        assert_ne!(
            support_creds_sig_message("peer", 1, "[]"),
            support_creds_sig_message("peer", 2, "[]"),
        );
        assert_ne!(
            support_creds_sig_message("peer", 1, "[]"),
            support_creds_sig_message("peer", 1, ""),
        );
        // A length-prefixed id, so a boundary shift cannot be hidden in it.
        assert_ne!(
            support_creds_sig_message("ab", 0, "c"),
            support_creds_sig_message("a", 0, "bc"),
        );
    }

    #[test]
    fn encode_and_parse_round_trip() {
        assert_eq!(encode_entries(&[]), "");
        assert!(parse_stored("").is_empty());
        assert!(parse_stored("[").is_empty());
        let e = mint_for("m", &[h(0x61)]);
        let json = encode_entries(&[e.clone()]);
        assert_eq!(parse_stored(&json), vec![e]);
        assert!(json.len() < 1800, "one entry is about 1.4 KB, got {}", json.len());
    }
}
