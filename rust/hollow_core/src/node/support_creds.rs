//! Support credentials: the proof that an identity bought a piece of shop art
//! (design `reports/ARTIST_SHOP_DESIGN.md` section 5, redeem 12.6, duplicates
//! 13.23).
//!
//! A credential is a blind signature (RFC 9474, `support_rsa.rs`) over a
//! message that binds the buyer's MASTER peer id to an item. The shop signs it
//! blind, so it never learns which identity redeemed which code; the buyer
//! unblinds it, keeps it, and it rides their profile as the `support_creds`
//! field. A viewer verifies it OFFLINE with nothing but the root public key
//! pinned below, because every entry carries the whole chain:
//!
//! ```text
//! root (pinned here)  signs  issuer (the shop's Ed25519 key)
//! issuer              signs  key    (one RSA-3072 key per listing)
//! key                 signs  sig    (blind, over this profile's master id)
//! ```
//!
//! The `item` of an entry is one number for the whole listing: SHA-256 over
//! the listing's file hashes sorted ascending, and the entry carries that
//! list as `parts`. A viewer recomputes `item` from `parts` and lights the
//! mark next to whichever of those hashes the profile is wearing. That is how
//! ONE credential vouches for every file of a bundle, and how the cap below
//! stays meaningful.
//!
//! ## Where the rules are enforced
//!
//! * [`sanitize_incoming_support_creds`] is the SINGLE receive-side validator:
//!   every profile ingest path hands it the raw field and stores what it
//!   returns. Invalid entries are dropped in silence, never an error, and the
//!   surviving list is re-serialized so the database holds exactly what
//!   verified and nothing a sender appended.
//! * The message binds the MASTER peer id, so a credential copied off one
//!   profile onto another fails verification there: stealing one is useless.
//! * The field is NOT part of `profile_signing_payload`: a credential already
//!   binds the identity itself, and adding it to the signed payload would
//!   break the profile signature against every shipped client for no gain
//!   (the same reasoning as `avatar_frame`).
//!
//! Supporter credentials (`t == 2`, the monthly subscription of design 5.4)
//! are phase 3. The type and period ride the message and the entry already so
//! nothing here changes when they land; a viewer lights nothing for them yet.

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

/// Domain tags. Three different things are signed in the chain, and each
/// signature starts with the name of the thing it is over so one can never
/// be presented as another.
pub const CRED_DOMAIN: &[u8] = b"hollow-support-cred/v1";
pub const ISSUER_DOMAIN: &[u8] = b"hollow-support-issuer/v1";
pub const KEY_DOMAIN: &[u8] = b"hollow-support-key/v1";

/// Credential types.
pub const T_ITEM: u8 = 1;
pub const T_SUPPORTER: u8 = 2;

/// The inline cap (design 5.5): three item credentials and one supporter
/// credential ride the light announce; anything past that is dropped by the
/// sanitizer, never an error. More than this moves to the asset rail in a
/// later version.
pub const MAX_ITEM_CREDS: usize = 3;
pub const MAX_SUPPORTER_CREDS: usize = 1;

/// Most file hashes one credential may vouch for. A pack carries at most
/// eight files; a bundle of four such packs is the largest set the shop
/// would ever sell, and this is room past it.
pub const MAX_PARTS: usize = 32;

/// Receive-side backstop on the raw field. Four full entries are about six
/// kilobytes; an oversized field is treated as ABSENT (preserve what we
/// stored), the same rule as the showcase board.
pub const MAX_CREDS_JSON_BYTES: usize = 16 * 1024;

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

// ── The root ──────────────────────────────────────────────────────────

/// The pinned root public key.
///
/// In test builds this is a fixed TEST root ([`test_root_signing_key`]), so
/// the harness can mint credentials without the offline secret; a
/// production build only ever answers the constant above.
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

// ── The entry ─────────────────────────────────────────────────────────

/// One credential as it rides the profile's `support_creds` JSON array.
/// Self-contained: a viewer verifies it with the pinned root and nothing
/// else. About 1.4 KB.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CredentialEntry {
    /// [`T_ITEM`] or [`T_SUPPORTER`].
    #[serde(default)]
    pub t: u8,
    /// 64-hex [`item_hash`] of `parts` (zeros for a supporter credential).
    #[serde(default)]
    pub item: String,
    /// Months since 2026-01 for a supporter credential; 0 for an item.
    #[serde(default)]
    pub period: u32,
    /// The listing's file hashes, sorted ascending, 64-hex each.
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
    /// The HOLDER's choice (design 5.6): show this credential's mark next to
    /// their name on chat rows and member lists. Off by default; the profile
    /// card mark is always on. Not signed: it is a display preference, and
    /// a rewritten flag changes where a mark is drawn, not whether it is
    /// real.
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
/// listing's RSA key. Every failure is a refusal with a reason.
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
    // 1. The shape of the claim.
    if t != T_ITEM && t != T_SUPPORTER {
        return Err("unknown credential type".into());
    }
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
        _ => {
            if !parts.is_empty() || item != [0u8; 32] {
                return Err("a supporter credential names no parts".into());
            }
            Vec::new()
        }
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

/// Verify one entry for the profile of `master_peer_id`, walking the whole
/// chain from `root`. Every failure is a refusal with a reason; nothing is
/// logged and nothing is partially accepted.
pub fn verify_entry(
    entry: &CredentialEntry,
    master_peer_id: &str,
    root: &VerifyingKey,
) -> Result<VerifiedCredential, String> {
    let chain = verify_chain(
        entry.t, &entry.item, &entry.parts, entry.period, &entry.key, &entry.key_sig,
        &entry.issuer, &entry.issuer_sig, root,
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

/// Keep the entries that verify for `master_peer_id`, in order, deduplicated
/// by item (the first wins) and capped ([`MAX_ITEM_CREDS`] items plus
/// [`MAX_SUPPORTER_CREDS`] supporter). The one filter every writer of the
/// field goes through.
pub fn keep_verified(
    entries: Vec<CredentialEntry>,
    master_peer_id: &str,
    root: &VerifyingKey,
) -> Vec<CredentialEntry> {
    let mut kept: Vec<CredentialEntry> = Vec::new();
    let mut seen_items: Vec<String> = Vec::new();
    let mut items = 0usize;
    let mut supporters = 0usize;
    for entry in entries {
        let Ok(verified) = verify_entry(&entry, master_peer_id, root) else { continue };
        if seen_items.contains(&entry.item) {
            continue;
        }
        match verified.t {
            T_ITEM => {
                if items >= MAX_ITEM_CREDS {
                    continue;
                }
                items += 1;
            }
            _ => {
                if supporters >= MAX_SUPPORTER_CREDS {
                    continue;
                }
                supporters += 1;
            }
        }
        seen_items.push(entry.item.clone());
        kept.push(entry);
    }
    kept
}

/// Receive-side gate for the `support_creds` profile field: the ONE
/// validator (wiki `security_write_gates.md`).
///
/// * `None`      -> `None`: an old client, preserve what we stored.
/// * `Some("")`  -> `Some("")`: an explicit clear.
/// * oversized or not a JSON array -> `None`: treated as absent.
/// * otherwise   -> the verified, deduplicated, capped entries re-serialized,
///   which may be `Some("")` when nothing survived: the sender claimed
///   credentials and none of them are real for this identity.
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
    /// `hollowpack` binary (the same crate, cross-compiled for the host),
    /// finalize and verify here. Skips with a note when the binary is not
    /// built; it never fakes a pass.
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
