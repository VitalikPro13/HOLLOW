//! The `name_color` profile field (#140): the colour, or the 2-3 colour gradient, a
//! person picks for their own name.
//!
//! The field sits OUTSIDE `hollow-profile2` (folding it in would break the profile
//! signature against every shipped client) and carries its OWN master signature over
//! (master, the profile's `updated_at`, that profile's own signature, value), REQUIRED
//! at every ingest, `""` included: a relay or forwarder can neither rewrite nor strip
//! it, nor move it onto another profile, and a refused field PRESERVES what we stored.
//! [`gated`] is the one ingest gate and [`stored_form`] decides what a signed value is
//! kept as.
//!
//! Grammar, version 1: `1:` then one to three stops of six LOWERCASE hex digits, comma
//! separated (`1:ff8800`, `1:ff8800,00aaff,7755ff`). Anything else the owner signed
//! (a later version, any shape, any size) is kept as `""`, the hashed colour: the owner
//! has moved on from the colour we hold. Motion, when it comes, belongs in a field of
//! its own, with this one kept as its static fallback.

use base64::Engine;

use crate::identity::native_identity::NativeKeypair;

/// Stops a version 1 gradient may hold.
pub(crate) const MAX_STOPS: usize = 3;

/// Domain of the field signature, distinct from every other profile signature.
const SIG_DOMAIN: &str = "hollow-name-color1";

/// Largest signed value kept verbatim so a `ProfileRelay` can carry it on. A version 1
/// field is at most 23 bytes; this leaves room for a later format, and anything longer
/// is stored (as its [`stored_form`]) but never relayed.
pub(crate) const RELAY_MAX: usize = 256;

/// The stops of a version 1 field, or `None` when `s` is not one in its single
/// canonical spelling.
pub(crate) fn parse_v1(s: &str) -> Option<Vec<[u8; 3]>> {
    let body = s.strip_prefix("1:")?;
    let mut stops = Vec::with_capacity(MAX_STOPS);
    for part in body.split(',') {
        if stops.len() == MAX_STOPS {
            return None;
        }
        stops.push(parse_stop(part)?);
    }
    Some(stops)
}

fn parse_stop(part: &str) -> Option<[u8; 3]> {
    let b = part.as_bytes();
    if b.len() != 6 || !b.iter().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f')) {
        return None;
    }
    let byte = |i: usize| u8::from_str_radix(&part[i..i + 2], 16).ok();
    Some([byte(0)?, byte(2)?, byte(4)?])
}

/// The canonical version 1 field for `stops`, or `None` for an empty or oversized list.
/// Dart builds our own field; this pins the same spelling from the Rust side.
#[cfg(test)]
pub(crate) fn encode_v1(stops: &[[u8; 3]]) -> Option<String> {
    if stops.is_empty() || stops.len() > MAX_STOPS {
        return None;
    }
    let parts: Vec<String> = stops.iter().map(hex::encode).collect();
    Some(format!("1:{}", parts.join(",")))
}

/// What a field its owner SIGNED is stored as: a version 1 value exactly, anything
/// else `""`. Only these two shapes are ever stored, so nothing else is capped.
pub(crate) fn stored_form(raw: &str) -> String {
    if parse_v1(raw).is_some() { raw.to_string() } else { String::new() }
}

/// Whether our own UI may publish `value`: a clear or a canonical version 1 field.
pub(crate) fn valid_own(value: &str) -> bool {
    value.is_empty() || parse_v1(value).is_some()
}

/// The bytes the field signature covers: length-prefixed, so one segment can never
/// impersonate the next boundary. `profile_sig` is the `hollow-profile2` signature of
/// the profile the colour rides with, so a colour belongs to exactly one profile.
pub(crate) fn sig_payload(master: &str, updated_at: i64, profile_sig: &str, value: &str) -> Vec<u8> {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(updated_at.to_le_bytes());
    for part in [master, profile_sig, value] {
        h.update((part.len() as u64).to_le_bytes());
        h.update(part.as_bytes());
    }
    format!("{SIG_DOMAIN}:{}", hex::encode(h.finalize())).into_bytes()
}

/// Sign OUR field for the announce stamped `updated_at` whose profile signature is
/// `profile_sig`. `None` for an absent field or an unsigned profile (which no receiver
/// stores anyway).
pub(crate) fn sign(
    master_keypair: &NativeKeypair,
    master: &str,
    updated_at: i64,
    profile_sig: Option<&str>,
    value: Option<&str>,
) -> Option<String> {
    let (value, profile_sig) = (value?, profile_sig?);
    let sig = master_keypair.sign(&sig_payload(master, updated_at, profile_sig, value));
    Some(base64::engine::general_purpose::STANDARD.encode(sig))
}

/// `true` = `value` is the field `master` itself signed for the profile stamped
/// `updated_at` and signed `profile_sig`. `pk_b64` must derive `master`: a real
/// signature by someone else is not this identity's.
pub(crate) fn verify(
    master: &str,
    updated_at: i64,
    profile_sig: &str,
    value: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
) -> bool {
    let (Some(sig), Some(pk)) = (sig_b64, pk_b64) else {
        return false;
    };
    let b64 = base64::engine::general_purpose::STANDARD;
    let (Ok(pk), Ok(sig)) = (b64.decode(pk), b64.decode(sig)) else {
        return false;
    };
    if NativeKeypair::peer_id_from_pubkey_protobuf(&pk).as_deref() != Some(master) {
        return false;
    }
    NativeKeypair::verify_peer_signature(&pk, &sig, &sig_payload(master, updated_at, profile_sig, value)).unwrap_or(false)
}

/// Masters already complained about once, so a reconnect storm is one log line.
fn complaints() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static SEEN: std::sync::OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> =
        std::sync::OnceLock::new();
    SEEN.get_or_init(|| std::sync::Mutex::new(std::collections::HashSet::new()))
}

fn refuse<T>(master: &str, why: &str) -> Option<T> {
    if let Ok(mut seen) = complaints().lock()
        && seen.insert(master.to_string())
    {
        hollow_log!("[HOLLOW-SECURITY] REFUSED the name colour field of {master}: {why}; keeping what we stored");
    }
    None
}

/// A received field that passed [`gated`].
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Gated {
    /// What this build stores and shows ([`stored_form`]).
    pub shown: String,
    /// The exact value the signature covers, kept so a `ProfileRelay` can carry it on;
    /// `None` past [`RELAY_MAX`].
    pub signed: Option<String>,
}

/// The ONE ingest gate for a received `name_color` (wiki `security_write_gates.md`).
/// `profile_sig` and `profile_pk` are the signature and key the profile itself
/// verified under.
///
/// Returns what to store, `None` = PRESERVE. Absent in, absent out; no valid master
/// signature over exactly this value, stamp and profile: refused, which preserves and
/// never clears. The caller writes it only onto the row holding that very profile
/// (`MessageStore::set_name_color`), so an older or a sibling profile never lands it.
pub(crate) fn gated(
    master: &str,
    updated_at: i64,
    profile_sig: &str,
    raw: Option<&str>,
    sig_b64: Option<&str>,
    profile_pk: Option<&str>,
) -> Option<Gated> {
    let raw = raw?;
    if !verify(master, updated_at, profile_sig, raw, sig_b64, profile_pk) {
        return refuse(master, "no valid signature over it");
    }
    Some(Gated { shown: stored_form(raw), signed: (raw.len() <= RELAY_MAX).then(|| raw.to_string()) })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(seed: u8) -> (NativeKeypair, String, String) {
        let kp = NativeKeypair::from_secret_bytes(&[seed; 32]);
        let id = kp.peer_id();
        let pk = base64::engine::general_purpose::STANDARD.encode(kp.public_key_protobuf());
        (kp, id, pk)
    }

    #[test]
    fn name_color_v1_grammar_is_strict_and_canonical() {
        assert_eq!(parse_v1("1:ff8800"), Some(vec![[0xff, 0x88, 0x00]]));
        assert_eq!(
            parse_v1("1:ff8800,00aaff,7755ff"),
            Some(vec![[0xff, 0x88, 0x00], [0x00, 0xaa, 0xff], [0x77, 0x55, 0xff]]),
        );
        for bad in [
            "", "1:", "1:,", "1:ff8800,", "1:,ff8800", "1:FF8800", "1:ff880", "1:ff88000",
            "1:gg8800", "1: ff8800", "1:ff8800 ", "1:ff8800,00aaff,7755ff,000000", "01:ff8800",
            "ff8800", "#ff8800", "1;ff8800", "1:ff8800;00aaff", "1:+f8800", "1:ff8800\n",
            "1:ff8800,,00aaff", "1:ｆｆ8800",
        ] {
            assert_eq!(parse_v1(bad), None, "{bad:?} must not parse");
        }
        assert_eq!(encode_v1(&[[0xff, 0x88, 0x00], [0, 0xaa, 0xff]]).as_deref(), Some("1:ff8800,00aaff"));
        assert_eq!(encode_v1(&[]), None);
        assert_eq!(encode_v1(&[[0, 0, 0]; 4]), None);
        let round = encode_v1(&[[1, 2, 3], [4, 5, 6], [7, 8, 9]]).unwrap();
        assert_eq!(parse_v1(&round), Some(vec![[1, 2, 3], [4, 5, 6], [7, 8, 9]]));
    }

    #[test]
    fn name_color_signed_values_are_stored_as_v1_or_a_clear() {
        assert_eq!(stored_form(""), "", "an empty field is a clear");
        assert_eq!(stored_form("1:ff8800,00aaff"), "1:ff8800,00aaff");
        // Anything else its owner signed is the owner's newer look (or a mistake): the
        // hashed colour, never the stale one we held and never stored as received.
        let long = format!("2:{}", "ab".repeat(400));
        for other in [
            "2:anything", "17:a,b,c", "999:x", "2:wave 1.5s ff2200,00aaff", "2:", "0:ff8800", "x:ff8800",
            "1:FF8800", "1:ff8800,", "garbage", "2:\u{7f}", "2:é", "1:ff8800,00aaff,7755ff,000000", &long,
        ] {
            assert_eq!(stored_form(other), "", "{other:?}");
        }
        assert!(valid_own("") && valid_own("1:000000") && !valid_own("2:x") && !valid_own("1:FFFFFF"));
    }

    /// Two profile signatures at one stamp, as two of the owner's devices could mint.
    const PS: &str = "cHJvZmlsZS1h";
    const PS2: &str = "cHJvZmlsZS1i";

    #[test]
    fn name_color_signature_binds_master_stamp_profile_and_value() {
        let (kp, id, pk) = keys(0x41);
        let sig = sign(&kp, &id, 1_000, Some(PS), Some("1:ff8800")).unwrap();
        assert!(verify(&id, 1_000, PS, "1:ff8800", Some(&sig), Some(&pk)));
        assert!(!verify(&id, 1_001, PS, "1:ff8800", Some(&sig), Some(&pk)), "another stamp");
        assert!(!verify(&id, 1_000, PS2, "1:ff8800", Some(&sig), Some(&pk)), "another profile at the same stamp");
        assert!(!verify(&id, 1_000, "", "1:ff8800", Some(&sig), Some(&pk)), "no profile");
        assert!(!verify(&id, 1_000, PS, "1:ff8801", Some(&sig), Some(&pk)), "another value");
        assert!(!verify(&id, 1_000, PS, "", Some(&sig), Some(&pk)), "a strip to a clear");
        assert!(!verify(&id, 1_000, PS, "1:ff8800", None, Some(&pk)), "no signature");
        assert!(!verify(&id, 1_000, PS, "1:ff8800", Some(&sig), None), "no key");
        assert!(!verify(&id, 1_000, PS, "1:ff8800", Some("%%"), Some(&pk)), "not base64");
        // A real signature by somebody else, over this master's field.
        let (other, _, other_pk) = keys(0x42);
        let forged =
            base64::engine::general_purpose::STANDARD.encode(other.sign(&sig_payload(&id, 1_000, PS, "1:ff8800")));
        assert!(!verify(&id, 1_000, PS, "1:ff8800", Some(&forged), Some(&other_pk)), "a key that is not the master's");
        assert!(!verify(&id, 1_000, PS, "1:ff8800", Some(&forged), Some(&pk)), "the master's key, another's signature");
        // Segments are length-prefixed: moving bytes between profile and value breaks it.
        assert_ne!(sig_payload(&id, 1, "ab", "c"), sig_payload(&id, 1, "a", "bc"));
        // Domain separation: the support-credential signature never stands in.
        assert_ne!(sig_payload(&id, 1_000, PS, "x"), crate::node::support_creds::support_creds_sig_message(&id, 1_000, "x"));
        assert!(sign(&kp, &id, 1, Some(PS), None).is_none());
        assert!(sign(&kp, &id, 1, None, Some("1:ff8800")).is_none(), "an unsigned profile carries no colour");
    }

    #[test]
    fn name_color_signature_payload_is_pinned() {
        // Pinned: a change here strands every stored and in-flight signature.
        let payload =
            String::from_utf8(sig_payload("12D3KooWTest", 1_700_000_000_000, "cHJvZmlsZQ==", "1:ff8800,00aaff")).unwrap();
        assert_eq!(payload, "hollow-name-color1:241fc7937c90a0d2744c6379b5ef4e9d44d78132c75c54436cb10dd577c38e30");
    }

    #[test]
    fn name_color_gate_refuses_unsigned_and_forged_and_clears_on_any_signed_other() {
        let (kp, id, pk) = keys(0x43);
        let signed = |v: &str, at: i64| sign(&kp, &id, at, Some(PS), Some(v));
        let kept = |shown: &str, signed: Option<&str>| {
            Some(Gated { shown: shown.to_string(), signed: signed.map(str::to_string) })
        };
        assert_eq!(gated(&id, 5, PS, None, None, Some(&pk)), None, "absent stays absent");
        assert_eq!(
            gated(&id, 5, PS, Some("1:ff8800"), signed("1:ff8800", 5).as_deref(), Some(&pk)),
            kept("1:ff8800", Some("1:ff8800")),
        );
        assert_eq!(gated(&id, 5, PS, Some(""), signed("", 5).as_deref(), Some(&pk)), kept("", Some("")), "a signed clear");
        assert_eq!(gated(&id, 5, PS, Some(""), None, Some(&pk)), None, "an unsigned clear is a strip");
        assert_eq!(gated(&id, 5, PS, Some("1:ff8800"), None, Some(&pk)), None, "unsigned");
        assert_eq!(gated(&id, 5, PS, Some("1:00ff00"), signed("1:ff8800", 5).as_deref(), Some(&pk)), None, "rewritten");
        assert_eq!(gated(&id, 6, PS, Some("1:ff8800"), signed("1:ff8800", 5).as_deref(), Some(&pk)), None, "re-stamped");
        assert_eq!(
            gated(&id, 5, PS2, Some("1:ff8800"), signed("1:ff8800", 5).as_deref(), Some(&pk)),
            None,
            "moved onto the other profile of its stamp",
        );
        // Signed but not version 1: the owner's own word, shown as a clear and kept
        // verbatim for relaying while it is small.
        assert_eq!(
            gated(&id, 5, PS, Some("1:FF8800"), signed("1:FF8800", 5).as_deref(), Some(&pk)),
            kept("", Some("1:FF8800")),
            "signed but malformed",
        );
        let edge = format!("2:{}", "a".repeat(RELAY_MAX - 2));
        assert_eq!(gated(&id, 5, PS, Some(&edge), signed(&edge, 5).as_deref(), Some(&pk)), kept("", Some(&edge)), "at the cap");
        let big = format!("2:{}", "a".repeat(RELAY_MAX - 1));
        assert_eq!(gated(&id, 5, PS, Some(&big), signed(&big, 5).as_deref(), Some(&pk)), kept("", None), "past the cap");
        assert_eq!(gated(&id, 5, PS, Some(&big), None, Some(&pk)), None, "unsigned and large");
        assert_eq!(
            gated(&id, 5, PS, Some("3:sparkle"), signed("3:sparkle", 5).as_deref(), Some(&pk)),
            kept("", Some("3:sparkle")),
        );
    }
}
