//! Safety numbers — out-of-band identity verification (Issue 1-D).
//!
//! A safety number is a 60-digit value that two people compare over an
//! authenticated channel (in person, a video call, an existing trusted app). If
//! both sides read the same number, they are talking to each other and not to a
//! machine in the middle.
//!
//! ## Why Hollow's is better than Signal's
//!
//! Signal must derive its number from a server-supplied identity key, so the
//! number CHURNS every time a contact reinstalls — which trains users to click
//! through the warning. Hollow's `peer_id` IS the Ed25519 public key (identity
//! multihash, inlined, not hashed), so the number is a pure function of the two
//! MASTER peer_ids:
//!
//!   - Stable across reinstalls and across adding/removing devices.
//!   - Changes ONLY when the master identity changes — i.e. it is genuinely a
//!     different person. That is the correct semantic.
//!   - Nothing extra to store, sync, or keep in step.
//!
//! Because of that stability, verification is NOT reset by a reinstall. The
//! separate device-set alert ([`crate::node::security_alerts`]) covers "a new
//! device appeared", which is the signal that actually carries information once
//! key exchange is authenticated. The two are complementary, not redundant.
//!
//! ## Derivation
//!
//! Per identity, following Signal's numeric-fingerprint construction:
//!
//! ```text
//! h = SHA-512( VERSION || CONTEXT || pubkey )
//! repeat ITERATIONS times:  h = SHA-512( h || pubkey )
//! digits = 6 chunks of 5 bytes from h[..30], each read big-endian and
//!          reduced mod 100000 → "%05d"
//! ```
//!
//! The iteration count is a deliberate slowdown: finding a key whose displayed
//! digits collide with a target costs ITERATIONS hashes per attempt.
//!
//! The full number sorts the two 30-digit halves and concatenates, so both ends
//! compute the identical string without agreeing on an order.

use sha2::{Digest, Sha512};

/// Domain separation. Bump `VERSION` if the construction ever changes — a
/// number produced under a different version must never compare equal.
const VERSION: [u8; 2] = [0x00, 0x01];
const CONTEXT: &[u8] = b"hollow-safety-number";

/// Hash iterations per identity. Matches Signal's cost parameter.
const ITERATIONS: u32 = 5200;

/// Digits contributed by each identity. Two halves → a 60-digit number.
const DIGITS_PER_IDENTITY: usize = 30;

/// Extract the raw 32-byte Ed25519 public key from a `12D3KooW…` peer_id.
///
/// Hollow peer_ids are libp2p identity multihashes with the protobuf public key
/// inlined verbatim:
///
/// ```text
/// base58btc( [0x00, 0x24] || [0x08, 0x01, 0x12, 0x20] || pubkey[32] )
///             ^ id mh, len   ^ protobuf: Ed25519, 32-byte field
/// ```
///
/// So this is a decode, not a lookup — no network, no DB, no trust assumption.
/// Returns `None` for anything that is not a well-formed Ed25519 peer_id
/// (truncated, RSA/secp256k1, or a SHA-256 multihash from a key too large to
/// inline).
pub(crate) fn pubkey_from_peer_id(peer_id: &str) -> Option<[u8; 32]> {
    let decoded = bs58::decode(peer_id)
        .with_alphabet(bs58::Alphabet::BITCOIN)
        .into_vec()
        .ok()?;
    // [0x00 identity-multihash, 0x24 length=36, ...36-byte protobuf pubkey]
    if decoded.len() != 38 || decoded[0] != 0x00 || decoded[1] != 0x24 {
        return None;
    }
    let proto = &decoded[2..];
    if proto[0] != 0x08 || proto[1] != 0x01 || proto[2] != 0x12 || proto[3] != 0x20 {
        return None;
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&proto[4..36]);
    Some(key)
}

/// The 30-digit half contributed by one identity's public key.
fn fingerprint_digits(pubkey: &[u8; 32]) -> String {
    let mut hasher = Sha512::new();
    hasher.update(VERSION);
    hasher.update(CONTEXT);
    hasher.update(pubkey);
    let mut hash = hasher.finalize();

    for _ in 0..ITERATIONS {
        let mut hasher = Sha512::new();
        hasher.update(hash.as_slice());
        hasher.update(pubkey);
        hash = hasher.finalize();
    }

    // 6 chunks × 5 bytes = 30 bytes → 6 × 5 digits = 30 digits.
    let mut out = String::with_capacity(DIGITS_PER_IDENTITY);
    for chunk in hash[..30].chunks_exact(5) {
        // 5 bytes big-endian into the low 40 bits of a u64 — no overflow.
        let mut v: u64 = 0;
        for b in chunk {
            v = (v << 8) | u64::from(*b);
        }
        out.push_str(&format!("{:05}", v % 100_000));
    }
    out
}

/// The 60-digit safety number for a pair of MASTER peer_ids.
///
/// SYMMETRIC: `safety_number(a, b) == safety_number(b, a)`. Both ends display
/// the identical string, so "do these match?" is the whole comparison — there is
/// no "yours / theirs" ordering for users to get wrong.
///
/// CALLERS MUST PASS MASTERS. A device peer_id would produce a number that
/// changes when the contact links or drops a device, which is exactly the
/// churn this design exists to avoid. The FFI layer resolves device → master
/// before calling in, so this stays a pure function.
///
/// Returns `Err` if either id is not a well-formed Ed25519 peer_id, rather than
/// inventing a number for an unparseable input — a safety number that does not
/// correspond to a real key would assert safety that is not there.
pub(crate) fn safety_number(peer_a: &str, peer_b: &str) -> Result<String, String> {
    let key_a = pubkey_from_peer_id(peer_a)
        .ok_or_else(|| format!("Not a valid Ed25519 peer_id: {peer_a}"))?;
    let key_b = pubkey_from_peer_id(peer_b)
        .ok_or_else(|| format!("Not a valid Ed25519 peer_id: {peer_b}"))?;

    let a = fingerprint_digits(&key_a);
    let b = fingerprint_digits(&key_b);
    // Sort the halves so the result is order-independent. Equal length, digits
    // only — lexicographic and numeric order agree.
    Ok(if a <= b { format!("{a}{b}") } else { format!("{b}{a}") })
}

/// Strip everything that is not a digit.
///
/// Used on BOTH sides of a comparison so a number pasted with the display's
/// spaces, a newline, or a stray non-breaking space still matches. Comparing
/// raw strings would show "mismatch" for two identical numbers formatted
/// differently — a false alarm on a security screen is not acceptable.
pub(crate) fn normalize_safety_number(input: &str) -> String {
    input.chars().filter(char::is_ascii_digit).collect()
}

/// Constant-time equality for two safety numbers, after normalization.
///
/// Not strictly required (the number is public to both parties), but this is a
/// crypto comparison and the project rule is that comparisons of key-derived
/// material are constant-time. Length is compared first and leaks only the
/// length, which the format already fixes at 60.
pub(crate) fn safety_numbers_match(a: &str, b: &str) -> bool {
    let a = normalize_safety_number(a);
    let b = normalize_safety_number(b);
    if a.len() != b.len() || a.len() != DIGITS_PER_IDENTITY * 2 {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;

    /// Two peer_ids from fixed secrets, so every assertion below is reproducible.
    fn fixture_peers() -> (String, String) {
        let a = NativeKeypair::from_secret_bytes(&[1u8; 32]).peer_id();
        let b = NativeKeypair::from_secret_bytes(&[2u8; 32]).peer_id();
        (a, b)
    }

    #[test]
    fn pubkey_round_trips_through_peer_id() {
        let kp = NativeKeypair::from_secret_bytes(&[7u8; 32]);
        let extracted = pubkey_from_peer_id(&kp.peer_id()).expect("valid peer_id");
        assert_eq!(
            extracted,
            kp.public_key_bytes(),
            "peer_id must decode back to the exact public key it inlines"
        );
    }

    #[test]
    fn malformed_peer_ids_are_rejected() {
        assert!(pubkey_from_peer_id("").is_none());
        assert!(pubkey_from_peer_id("not-base58-!@#").is_none());
        assert!(pubkey_from_peer_id("12D3KooWtruncated").is_none());
        // Valid base58 but the wrong length/prefix.
        assert!(pubkey_from_peer_id("QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG").is_none());
        // A real id with one character swapped must not silently decode.
        let (a, _) = fixture_peers();
        let mut broken = a.clone();
        broken.push('x');
        assert!(pubkey_from_peer_id(&broken).is_none());
    }

    /// KNOWN-ANSWER TEST. Pins the wire format of the derivation.
    ///
    /// If this fails, the construction changed and every previously-verified
    /// contact would silently re-derive to a different number — users would be
    /// told their contacts changed identity when nothing happened. Change the
    /// value here ONLY together with a `VERSION` bump and a migration plan.
    #[test]
    fn safety_number_known_answer() {
        let (a, b) = fixture_peers();
        // Sanity-check the inputs the answer was computed from.
        assert_eq!(a, "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5");
        assert_eq!(b, "12D3KooWJWoaqZhDaoEFshF7Rh1bpY9ohihFhzcW6d69Lr2NASuq");

        let number = safety_number(&a, &b).expect("valid pair");
        assert_eq!(number.len(), 60, "must be exactly 60 digits");
        assert!(number.chars().all(|c| c.is_ascii_digit()), "digits only");
        assert_eq!(
            number,
            "287916789479496721289575569209540769810906760998551722587740"
        );
    }

    #[test]
    fn safety_number_is_symmetric() {
        let (a, b) = fixture_peers();
        assert_eq!(
            safety_number(&a, &b).unwrap(),
            safety_number(&b, &a).unwrap(),
            "both ends must display the identical number"
        );
    }

    #[test]
    fn safety_number_differs_per_pair() {
        let (a, b) = fixture_peers();
        let c = NativeKeypair::from_secret_bytes(&[3u8; 32]).peer_id();
        let ab = safety_number(&a, &b).unwrap();
        let ac = safety_number(&a, &c).unwrap();
        let bc = safety_number(&b, &c).unwrap();
        assert_ne!(ab, ac);
        assert_ne!(ab, bc);
        assert_ne!(ac, bc);
    }

    #[test]
    fn safety_number_is_deterministic() {
        let (a, b) = fixture_peers();
        assert_eq!(safety_number(&a, &b).unwrap(), safety_number(&a, &b).unwrap());
    }

    /// A pair with ITSELF is legal (Saved messages / your own identity) and must
    /// not panic or produce a short string.
    #[test]
    fn self_pair_is_well_formed() {
        let (a, _) = fixture_peers();
        let n = safety_number(&a, &a).unwrap();
        assert_eq!(n.len(), 60);
        // Both halves are the same fingerprint.
        assert_eq!(&n[..30], &n[30..]);
    }

    #[test]
    fn invalid_input_errors_rather_than_inventing_a_number() {
        let (a, _) = fixture_peers();
        assert!(safety_number(&a, "garbage").is_err());
        assert!(safety_number("garbage", &a).is_err());
        assert!(safety_number("", "").is_err());
    }

    #[test]
    fn normalization_ignores_display_formatting() {
        let (a, b) = fixture_peers();
        let n = safety_number(&a, &b).unwrap();
        // The grouped form users actually read out and paste back.
        let grouped = n
            .as_bytes()
            .chunks(5)
            .map(|c| String::from_utf8_lossy(c).to_string())
            .collect::<Vec<_>>()
            .join(" ");
        assert!(safety_numbers_match(&n, &grouped));
        assert!(safety_numbers_match(&n, &format!("  {grouped}\n")));
        assert!(safety_numbers_match(&grouped, &grouped));
    }

    #[test]
    fn mismatch_is_detected() {
        let (a, b) = fixture_peers();
        let c = NativeKeypair::from_secret_bytes(&[9u8; 32]).peer_id();
        let ab = safety_number(&a, &b).unwrap();
        let ac = safety_number(&a, &c).unwrap();
        assert!(!safety_numbers_match(&ab, &ac));

        // A single digit off must NOT match.
        let mut tweaked = ab.clone();
        let last = tweaked.pop().unwrap();
        tweaked.push(if last == '0' { '1' } else { '0' });
        assert!(!safety_numbers_match(&ab, &tweaked));
    }

    #[test]
    fn wrong_length_never_matches() {
        let (a, b) = fixture_peers();
        let n = safety_number(&a, &b).unwrap();
        assert!(!safety_numbers_match(&n, ""), "empty input must not match");
        assert!(!safety_numbers_match(&n, &n[..59]), "truncated must not match");
        assert!(!safety_numbers_match("", ""), "two empties are not a match");
        assert!(
            !safety_numbers_match(&n, &format!("{n}0")),
            "over-long must not match"
        );
    }
}
