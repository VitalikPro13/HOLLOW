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

fn cipher(shared: &[u8; 32], eph: &[u8; 32], to: &[u8; 32], domain: &[u8]) -> Option<(aes_gcm::Aes256Gcm, [u8; 12])> {
    let salt = [eph.as_slice(), to.as_slice()].concat();
    let mut okm = Zeroizing::new([0u8; 44]);
    Hkdf::<Sha256>::new(Some(&salt), shared).expand(domain, okm.as_mut_slice()).ok()?;
    let cipher = aes_gcm::Aes256Gcm::new_from_slice(&okm[..32]).ok()?;
    Some((cipher, okm[32..].try_into().ok()?))
}

/// Seal `plain` to `to`. `domain` names what the box is for, and a box opens only
/// under the same domain and `aad`.
pub(crate) fn seal(to: &[u8; 32], domain: &[u8], aad: &[u8], plain: &[u8]) -> Option<Sealed> {
    let eph_secret = StaticSecret::from(*new_secret()?);
    let eph = PublicKey::from(&eph_secret).to_bytes();
    let shared = eph_secret.diffie_hellman(&PublicKey::from(*to));
    // A small-order recipient agrees on the same value with everyone.
    if !shared.was_contributory() {
        return None;
    }
    let (cipher, nonce) = cipher(shared.as_bytes(), &eph, to, domain)?;
    let ct = cipher.encrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: plain, aad }).ok()?;
    let engine = base64::engine::general_purpose::STANDARD;
    Some(Sealed { eph: engine.encode(eph), ct: engine.encode(ct) })
}

/// The plaintext of a box sealed to the public half of `secret`, if it opens.
pub(crate) fn open(secret: &[u8; 32], domain: &[u8], aad: &[u8], eph: &str, ct: &str) -> Option<Vec<u8>> {
    let engine = base64::engine::general_purpose::STANDARD;
    let eph: [u8; 32] = engine.decode(eph).ok()?.try_into().ok()?;
    let ct = engine.decode(ct).ok()?;
    let ours = StaticSecret::from(*secret);
    let to = PublicKey::from(&ours).to_bytes();
    let shared = ours.diffie_hellman(&PublicKey::from(eph));
    if !shared.was_contributory() {
        return None;
    }
    let (cipher, nonce) = cipher(shared.as_bytes(), &eph, &to, domain)?;
    cipher.decrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &ct, aad }).ok()
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
    fn a_key_survives_its_text_form() {
        let key = public_of(&new_secret().unwrap());
        let text = key_to_text(&key);
        assert_eq!(text.len(), 43);
        assert_eq!(key_from_text(&text), Some(key));
        assert_eq!(key_from_text(&text[..42]), None);
        assert_eq!(key_from_text("not a key at all, not a key at all, not a key"), None);
    }
}
