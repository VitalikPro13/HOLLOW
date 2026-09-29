//! Anonymous boxes to an X25519 public key: a fresh ephemeral key agrees with the
//! recipient's, and HKDF-SHA256 over that agreement gives the AES-256-GCM key and
//! nonce. For the join lane, where no Olm session or MLS group exists yet.

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::KeyInit;
use base64::Engine;
use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// One sealed box: the sender's ephemeral public key and the ciphertext, base64.
pub(crate) struct Sealed {
    pub eph: String,
    pub ct: String,
}

/// A fresh X25519 secret.
pub(crate) fn new_secret() -> Option<Zeroizing<[u8; 32]>> {
    let mut secret = Zeroizing::new([0u8; 32]);
    getrandom::fill(secret.as_mut_slice()).ok()?;
    Some(secret)
}

pub(crate) fn public_of(secret: &[u8; 32]) -> [u8; 32] {
    PublicKey::from(&StaticSecret::from(*secret)).to_bytes()
}

/// A public key as invite links and the wire carry it: unpadded URL-safe base64.
pub(crate) fn key_to_text(key: &[u8; 32]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(key)
}

pub(crate) fn key_from_text(text: &str) -> Option<[u8; 32]> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(text).ok()?.try_into().ok()
}

/// `salt` names every public key the agreements used, so a box never opens under
/// another key set that happens to agree on the same values.
fn cipher(shared: &[u8], salt: &[u8], domain: &[u8]) -> Option<(aes_gcm::Aes256Gcm, [u8; 12])> {
    let mut okm = Zeroizing::new([0u8; 44]);
    Hkdf::<Sha256>::new(Some(salt), shared).expand(domain, okm.as_mut_slice()).ok()?;
    let cipher = aes_gcm::Aes256Gcm::new_from_slice(&okm[..32]).ok()?;
    Some((cipher, okm[32..].try_into().ok()?))
}

/// One X25519 agreement, `None` when it is not contributory: a small-order key agrees
/// on the same value with everyone.
fn agree(secret: &[u8; 32], public: &[u8; 32]) -> Option<Zeroizing<[u8; 32]>> {
    let shared = StaticSecret::from(*secret).diffie_hellman(&PublicKey::from(*public));
    shared.was_contributory().then(|| Zeroizing::new(shared.to_bytes()))
}

fn seal_with(eph_secret: &[u8; 32], shared: &[u8], salt: &[u8], domain: &[u8], aad: &[u8], plain: &[u8]) -> Option<Sealed> {
    let (cipher, nonce) = cipher(shared, salt, domain)?;
    let ct = cipher.encrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: plain, aad }).ok()?;
    let engine = base64::engine::general_purpose::STANDARD;
    Some(Sealed { eph: engine.encode(public_of(eph_secret)), ct: engine.encode(ct) })
}

fn decode(eph: &str, ct: &str) -> Option<([u8; 32], Vec<u8>)> {
    let engine = base64::engine::general_purpose::STANDARD;
    Some((engine.decode(eph).ok()?.try_into().ok()?, engine.decode(ct).ok()?))
}

fn open_with(shared: &[u8], salt: &[u8], domain: &[u8], aad: &[u8], ct: &[u8]) -> Option<Vec<u8>> {
    let (cipher, nonce) = cipher(shared, salt, domain)?;
    cipher.decrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: ct, aad }).ok()
}

/// Seal `plain` to `to`. `domain` names what the box is for, and a box opens only
/// under the same domain and `aad`.
pub(crate) fn seal(to: &[u8; 32], domain: &[u8], aad: &[u8], plain: &[u8]) -> Option<Sealed> {
    let eph_secret = new_secret()?;
    let shared = agree(&eph_secret, to)?;
    let salt = [public_of(&eph_secret).as_slice(), to].concat();
    seal_with(&eph_secret, shared.as_slice(), &salt, domain, aad, plain)
}

/// The plaintext of a box sealed to the public half of `secret`, if it opens.
pub(crate) fn open(secret: &[u8; 32], domain: &[u8], aad: &[u8], eph: &str, ct: &str) -> Option<Vec<u8>> {
    let (eph, ct) = decode(eph, ct)?;
    let shared = agree(secret, &eph)?;
    let salt = [eph.as_slice(), &public_of(secret)].concat();
    open_with(shared.as_slice(), &salt, domain, aad, &ct)
}

/// Seal `plain` to two keys at once: opening it takes both secrets.
pub(crate) fn seal_to_both(a: &[u8; 32], b: &[u8; 32], domain: &[u8], aad: &[u8], plain: &[u8]) -> Option<Sealed> {
    let eph_secret = new_secret()?;
    let shared = Zeroizing::new([agree(&eph_secret, a)?.as_slice(), agree(&eph_secret, b)?.as_slice()].concat());
    let salt = [public_of(&eph_secret).as_slice(), a, b].concat();
    seal_with(&eph_secret, &shared, &salt, domain, aad, plain)
}

/// The plaintext of a [`seal_to_both`] box, opened with both secrets.
pub(crate) fn open_with_both(a: &[u8; 32], b: &[u8; 32], domain: &[u8], aad: &[u8], eph: &str, ct: &str) -> Option<Vec<u8>> {
    let (eph, ct) = decode(eph, ct)?;
    let shared = Zeroizing::new([agree(a, &eph)?.as_slice(), agree(b, &eph)?.as_slice()].concat());
    let salt = [eph.as_slice(), &public_of(a), &public_of(b)].concat();
    open_with(&shared, &salt, domain, aad, &ct)
}

/// Seal `plain` to `to` from the holder of `ours`: the box opens only for `to`, and
/// only against our public half, so it also proves we hold `ours`.
pub(crate) fn seal_from(to: &[u8; 32], ours: &[u8; 32], domain: &[u8], aad: &[u8], plain: &[u8]) -> Option<Sealed> {
    let eph_secret = new_secret()?;
    let shared = Zeroizing::new([agree(&eph_secret, to)?.as_slice(), agree(ours, to)?.as_slice()].concat());
    let salt = [public_of(&eph_secret).as_slice(), to, &public_of(ours)].concat();
    seal_with(&eph_secret, &shared, &salt, domain, aad, plain)
}

/// The plaintext of a [`seal_from`] box: sealed to the public half of `secret` by
/// the holder of the secret behind `from`.
pub(crate) fn open_from(secret: &[u8; 32], from: &[u8; 32], domain: &[u8], aad: &[u8], eph: &str, ct: &str) -> Option<Vec<u8>> {
    let (eph, ct) = decode(eph, ct)?;
    let shared = Zeroizing::new([agree(secret, &eph)?.as_slice(), agree(secret, from)?.as_slice()].concat());
    let salt = [eph.as_slice(), &public_of(secret), from].concat();
    open_with(&shared, &salt, domain, aad, &ct)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOMAIN: &[u8] = b"test-box1";

    #[test]
    fn a_box_opens_for_its_recipient_only() {
        let (recipient, stranger) = (new_secret().unwrap(), new_secret().unwrap());
        let sealed = seal(&public_of(&recipient), DOMAIN, b"aad", b"hello").unwrap();
        assert_eq!(open(&recipient, DOMAIN, b"aad", &sealed.eph, &sealed.ct).as_deref(), Some(&b"hello"[..]));
        assert!(open(&stranger, DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none());
    }

    #[test]
    fn a_box_is_bound_to_its_domain_and_aad() {
        let recipient = new_secret().unwrap();
        let sealed = seal(&public_of(&recipient), DOMAIN, b"aad", b"hello").unwrap();
        assert!(open(&recipient, b"other-box1", b"aad", &sealed.eph, &sealed.ct).is_none());
        assert!(open(&recipient, DOMAIN, b"other aad", &sealed.eph, &sealed.ct).is_none());
    }

    #[test]
    fn a_changed_box_does_not_open() {
        let recipient = new_secret().unwrap();
        let sealed = seal(&public_of(&recipient), DOMAIN, b"aad", b"hello").unwrap();
        let engine = base64::engine::general_purpose::STANDARD;
        let mut ct = engine.decode(&sealed.ct).unwrap();
        ct[0] ^= 1;
        assert!(open(&recipient, DOMAIN, b"aad", &sealed.eph, &engine.encode(&ct)).is_none());
        let other_eph = engine.encode(public_of(&new_secret().unwrap()));
        assert!(open(&recipient, DOMAIN, b"aad", &other_eph, &sealed.ct).is_none());
    }

    #[test]
    fn every_box_is_fresh() {
        let to = public_of(&new_secret().unwrap());
        let (a, b) = (seal(&to, DOMAIN, b"", b"same").unwrap(), seal(&to, DOMAIN, b"", b"same").unwrap());
        assert_ne!((a.eph, a.ct), (b.eph, b.ct));
    }

    #[test]
    fn a_small_order_key_gets_no_box_and_opens_none() {
        // The identity point: every agreement with it is zero.
        let mut weak = [0u8; 32];
        weak[0] = 1;
        assert!(seal(&weak, DOMAIN, b"", b"x").is_none());
        let engine = base64::engine::general_purpose::STANDARD;
        let sealed = seal(&public_of(&new_secret().unwrap()), DOMAIN, b"", b"x").unwrap();
        assert!(open(&new_secret().unwrap(), DOMAIN, b"", &engine.encode(weak), &sealed.ct).is_none());
    }

    #[test]
    fn a_box_to_both_keys_needs_both_secrets() {
        let (a, b, other) = (new_secret().unwrap(), new_secret().unwrap(), new_secret().unwrap());
        let sealed = seal_to_both(&public_of(&a), &public_of(&b), DOMAIN, b"aad", b"hi").unwrap();
        assert_eq!(open_with_both(&a, &b, DOMAIN, b"aad", &sealed.eph, &sealed.ct).as_deref(), Some(&b"hi"[..]));
        assert!(open_with_both(&a, &other, DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none(), "the second key is missing");
        assert!(open_with_both(&other, &b, DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none(), "the first key is missing");
        assert!(open_with_both(&b, &a, DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none(), "the keys in the other order");
        assert!(open(&a, DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none(), "one key alone");
    }

    #[test]
    fn a_box_from_a_key_opens_only_against_that_key() {
        let (to, ours, other) = (new_secret().unwrap(), new_secret().unwrap(), new_secret().unwrap());
        let sealed = seal_from(&public_of(&to), &ours, DOMAIN, b"aad", b"hi").unwrap();
        assert_eq!(open_from(&to, &public_of(&ours), DOMAIN, b"aad", &sealed.eph, &sealed.ct).as_deref(), Some(&b"hi"[..]));
        assert!(open_from(&to, &public_of(&other), DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none(), "claimed from another key");
        assert!(open_from(&other, &public_of(&ours), DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none(), "another recipient");
        assert!(open(&to, DOMAIN, b"aad", &sealed.eph, &sealed.ct).is_none(), "a plain box is not this box");
        let forged = seal_from(&public_of(&to), &other, DOMAIN, b"aad", b"hi").unwrap();
        assert!(open_from(&to, &public_of(&ours), DOMAIN, b"aad", &forged.eph, &forged.ct).is_none(), "sealed without our key");
    }

    #[test]
    fn a_key_survives_its_text_form() {
        let key = public_of(&new_secret().unwrap());
        let text = key_to_text(&key);
        assert_eq!(text.len(), 43);
        assert_eq!(key_from_text(&text), Some(key));
        assert_eq!(key_from_text(&text[..42]), None);
        assert_eq!(key_from_text("not a key at all, not a key at all, not a key"), None);
    }
}
