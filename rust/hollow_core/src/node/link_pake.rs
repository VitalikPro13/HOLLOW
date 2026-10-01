//! The device link channel (HOL-SEC-002). The code a device shows has a rendezvous
//! part the relay sees and a secret part it never sees. SPAKE2 turns the secret into
//! keys nobody can test offline, the presenter proves it holds the same key, and
//! everything after rides AES-256-GCM under keys bound to the rendezvous and the
//! direction. A relay that plays one device gets one online guess per code.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use spake2::{Ed25519Group, Identity, Password, Spake2};
use zeroize::Zeroizing;

/// The part of a link code the relay sees: it claims and resolves it.
pub(crate) const RENDEZVOUS_LEN: usize = 6;
/// The part the relay never sees, about 20 bits: worth one online guess.
pub(crate) const SECRET_LEN: usize = 4;
/// Easy to read off a screen: no 0/O, no 1/I/L. Upper case and digits only, as the
/// relay's own check wants for the rendezvous part.
pub(crate) const ALPHABET: &str = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

const NONCE_LEN: usize = 12;

/// The rendezvous and secret parts of a typed code. Case, spaces and dashes do not
/// matter; any other character refuses the code.
pub(crate) fn split_code(code: &str) -> Option<(String, String)> {
    let c: String = code
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    if c.len() != RENDEZVOUS_LEN + SECRET_LEN || !c.chars().all(|ch| ALPHABET.contains(ch)) {
        return None;
    }
    Some((c[..RENDEZVOUS_LEN].to_string(), c[RENDEZVOUS_LEN..].to_string()))
}

/// Whether `part` is a well-formed rendezvous (`len` 6) or secret (`len` 4) part.
pub(crate) fn is_part(part: &str, len: usize) -> bool {
    part.len() == len && part.chars().all(|ch| ALPHABET.contains(ch))
}

/// Which way a sealed link message travels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Direction {
    /// From the device being linked to the one that shows the code.
    ToPresenter,
    /// From the device that shows the code to the one being linked.
    ToJoiner,
}

impl Direction {
    fn label(self) -> &'static str {
        match self {
            Direction::ToPresenter => "to-presenter",
            Direction::ToJoiner => "to-joiner",
        }
    }
}

/// What travels inside the channel.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub(crate) enum LinkInner {
    /// The device being linked: the id it will run as, and what the person sees on
    /// the confirm prompt.
    Hello {
        #[serde(default)]
        device: String,
        #[serde(default)]
        label: String,
        #[serde(default)]
        platform: String,
        #[serde(default)]
        msg_count: u32,
        #[serde(default)]
        friend_count: u32,
        #[serde(default)]
        has_profile: bool,
    },
    /// The snapshot that follows on the stream, and the one-time key it is
    /// encrypted under.
    Offer {
        #[serde(default)]
        link_id: String,
        #[serde(default)]
        key_hex: String,
    },
}

/// The keys one handshake yields: one per direction and one for the confirmation.
pub(crate) struct LinkKeys {
    rendezvous: String,
    to_presenter: Zeroizing<[u8; 32]>,
    to_joiner: Zeroizing<[u8; 32]>,
    confirm: Zeroizing<[u8; 32]>,
}

fn identities(rendezvous: &str) -> (Identity, Identity) {
    (
        Identity::new(format!("hollow-link1:{rendezvous}:joiner").as_bytes()),
        Identity::new(format!("hollow-link1:{rendezvous}:presenter").as_bytes()),
    )
}

fn derive(shared: &[u8], rendezvous: &str) -> LinkKeys {
    let hk = Hkdf::<Sha256>::new(Some(rendezvous.as_bytes()), shared);
    let expand = |info: &[u8]| {
        let mut out = Zeroizing::new([0u8; 32]);
        // 32 bytes is far below HKDF-SHA256's ceiling, so expand cannot fail.
        let _ = hk.expand(info, &mut out[..]);
        out
    };
    LinkKeys {
        rendezvous: rendezvous.to_string(),
        to_presenter: expand(b"hollow-link1-to-presenter"),
        to_joiner: expand(b"hollow-link1-to-joiner"),
        confirm: expand(b"hollow-link1-confirm"),
    }
}

/// The joiner's opening move; its message goes to the presenter.
pub(crate) fn joiner_start(rendezvous: &str, secret: &str) -> (Spake2<Ed25519Group>, Vec<u8>) {
    let (joiner, presenter) = identities(rendezvous);
    Spake2::<Ed25519Group>::start_a(&Password::new(secret.as_bytes()), &joiner, &presenter)
}

/// The presenter's answer to `joiner_msg`: the keys, its own message, and the
/// confirmation that it derived them from the same secret.
pub(crate) fn presenter_answer(
    rendezvous: &str,
    secret: &str,
    joiner_msg: &[u8],
) -> Result<(LinkKeys, Vec<u8>, Vec<u8>), String> {
    let (joiner, presenter) = identities(rendezvous);
    let (spake, msg) = Spake2::<Ed25519Group>::start_b(&Password::new(secret.as_bytes()), &joiner, &presenter);
    let shared = Zeroizing::new(spake.finish(joiner_msg).map_err(|_| "a malformed link handshake".to_string())?);
    let keys = derive(&shared, rendezvous);
    let confirm = keys.confirmation(joiner_msg, &msg);
    Ok((keys, msg, confirm))
}

/// The joiner's keys, once the presenter's confirmation checks out. A mismatch means
/// the code was typed wrong or somebody else answered.
pub(crate) fn joiner_finish(
    spake: Spake2<Ed25519Group>,
    rendezvous: &str,
    joiner_msg: &[u8],
    presenter_msg: &[u8],
    confirm: &[u8],
) -> Result<LinkKeys, String> {
    let shared = Zeroizing::new(spake.finish(presenter_msg).map_err(|_| "a malformed link handshake".to_string())?);
    let keys = derive(&shared, rendezvous);
    keys.mac(joiner_msg, presenter_msg)
        .verify_slice(confirm)
        .map_err(|_| "The code didn't match.".to_string())?;
    Ok(keys)
}

impl LinkKeys {
    fn mac(&self, joiner_msg: &[u8], presenter_msg: &[u8]) -> Hmac<Sha256> {
        let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(&self.confirm[..]).expect("HMAC takes any key length");
        // Both messages have the group's fixed length, so plain concatenation is
        // unambiguous.
        mac.update(joiner_msg);
        mac.update(presenter_msg);
        mac
    }

    fn confirmation(&self, joiner_msg: &[u8], presenter_msg: &[u8]) -> Vec<u8> {
        self.mac(joiner_msg, presenter_msg).finalize().into_bytes().to_vec()
    }

    fn cipher(&self, dir: Direction) -> (Aes256Gcm, String) {
        let key = match dir {
            Direction::ToPresenter => &self.to_presenter,
            Direction::ToJoiner => &self.to_joiner,
        };
        let cipher = Aes256Gcm::new_from_slice(&key[..]).expect("a 32-byte key");
        (cipher, format!("hollow-link1:{}:{}", self.rendezvous, dir.label()))
    }

    /// `inner`, sealed for `dir`: a fresh nonce followed by the ciphertext.
    pub(crate) fn seal(&self, dir: Direction, inner: &LinkInner) -> Result<Vec<u8>, String> {
        let plaintext = Zeroizing::new(serde_json::to_vec(inner).map_err(|e| format!("link message: {e}"))?);
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::fill(&mut nonce).map_err(|e| format!("RNG failed: {e}"))?;
        let (cipher, aad) = self.cipher(dir);
        let ct = cipher
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: &plaintext, aad: aad.as_bytes() })
            .map_err(|_| "Could not seal the link message.".to_string())?;
        let mut out = nonce.to_vec();
        out.extend_from_slice(&ct);
        Ok(out)
    }

    /// Open a message sealed for `dir`. Anything else, including one sealed for the
    /// other direction or another code, refuses.
    pub(crate) fn open(&self, dir: Direction, sealed: &[u8]) -> Result<LinkInner, String> {
        if sealed.len() < NONCE_LEN {
            return Err("a truncated link message".into());
        }
        let (nonce, ct) = sealed.split_at(NONCE_LEN);
        let (cipher, aad) = self.cipher(dir);
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(Nonce::from_slice(nonce), Payload { msg: ct, aad: aad.as_bytes() })
                .map_err(|_| "The code didn't match.".to_string())?,
        );
        serde_json::from_slice(&plaintext).map_err(|_| "a malformed link message".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hello() -> LinkInner {
        LinkInner::Hello {
            device: "12D3KooWnew".into(),
            label: "Laptop".into(),
            platform: "linux".into(),
            msg_count: 0,
            friend_count: 0,
            has_profile: false,
        }
    }

    fn handshake(joiner_secret: &str, presenter_secret: &str) -> Result<(LinkKeys, LinkKeys), String> {
        let (spake, msg_a) = joiner_start("ABCDEF", joiner_secret);
        let (p_keys, msg_b, confirm) = presenter_answer("ABCDEF", presenter_secret, &msg_a)?;
        let n_keys = joiner_finish(spake, "ABCDEF", &msg_a, &msg_b, &confirm)?;
        Ok((n_keys, p_keys))
    }

    #[test]
    fn codes_split_into_rendezvous_and_secret() {
        assert_eq!(split_code("abcdef-ghjk"), Some(("ABCDEF".into(), "GHJK".into())));
        assert_eq!(split_code(" ABC DEF GHJK "), Some(("ABCDEF".into(), "GHJK".into())));
        assert_eq!(split_code("ABCDEF"), None, "the secret part is required");
        assert_eq!(split_code("ABCDEFGHJ0"), None, "0 is not in the alphabet");
        assert_eq!(split_code("ABCDEFGHJKM"), None);
        assert!(is_part("ABCDEF", RENDEZVOUS_LEN) && !is_part("ABCDE", RENDEZVOUS_LEN));
    }

    #[test]
    fn the_same_secret_opens_the_channel_both_ways() {
        let (n, p) = handshake("GHJK", "GHJK").expect("the right code");
        let sealed = n.seal(Direction::ToPresenter, &hello()).unwrap();
        assert_eq!(p.open(Direction::ToPresenter, &sealed).unwrap(), hello());
        let offer = LinkInner::Offer { link_id: "link_x".into(), key_hex: "ab".repeat(32) };
        let back = p.seal(Direction::ToJoiner, &offer).unwrap();
        assert_eq!(n.open(Direction::ToJoiner, &back).unwrap(), offer);
    }

    /// A wrong secret is caught by the confirmation on the joiner's side, so the
    /// joiner never sends a Hello sealed under a key the other side could test.
    #[test]
    fn a_wrong_secret_fails_the_confirmation() {
        let err = handshake("GHJK", "GHJM").err().expect("a wrong code must fail");
        assert_eq!(err, "The code didn't match.");
    }

    #[test]
    fn a_sealed_message_opens_only_in_its_direction_and_code() {
        let (n, p) = handshake("GHJK", "GHJK").unwrap();
        let sealed = n.seal(Direction::ToPresenter, &hello()).unwrap();
        assert!(p.open(Direction::ToJoiner, &sealed).is_err(), "the other direction's key");
        assert!(n.open(Direction::ToPresenter, &sealed).is_ok(), "both sides hold both keys");

        let (spake, msg_a) = joiner_start("ZZZZZZ", "GHJK");
        let (other, msg_b, confirm) = presenter_answer("ZZZZZZ", "GHJK", &msg_a).unwrap();
        joiner_finish(spake, "ZZZZZZ", &msg_a, &msg_b, &confirm).unwrap();
        assert!(other.open(Direction::ToPresenter, &sealed).is_err(), "another rendezvous");

        let mut tampered = sealed.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(p.open(Direction::ToPresenter, &tampered).is_err());
        assert!(p.open(Direction::ToPresenter, &sealed[..5]).is_err());
    }

    /// The rendezvous is bound into the handshake: the same secret under another
    /// rendezvous yields keys that do not confirm.
    #[test]
    fn the_rendezvous_is_bound_into_the_keys() {
        let (spake, msg_a) = joiner_start("ABCDEF", "GHJK");
        let (_, msg_b, confirm) = presenter_answer("QWERTY", "GHJK", &msg_a).unwrap();
        assert!(joiner_finish(spake, "ABCDEF", &msg_a, &msg_b, &confirm).is_err());
    }

    /// Each binding holds on its own, not only behind another one: the two
    /// directions have their own keys, the rendezvous is in every AAD, and it is
    /// in the handshake itself, not only in the key derivation after it.
    #[test]
    fn every_layer_binds_on_its_own() {
        let (n, _) = handshake("GHJK", "GHJK").unwrap();
        let offer = LinkInner::Offer { link_id: "link_x".into(), key_hex: "cd".repeat(32) };
        let to_joiner = n.seal(Direction::ToJoiner, &offer).unwrap();
        let presenter_key_only = LinkKeys {
            rendezvous: n.rendezvous.clone(),
            to_presenter: n.to_presenter.clone(),
            to_joiner: n.to_presenter.clone(),
            confirm: n.confirm.clone(),
        };
        assert!(
            presenter_key_only.open(Direction::ToJoiner, &to_joiner).is_err(),
            "one key for both directions",
        );

        let sealed = n.seal(Direction::ToPresenter, &hello()).unwrap();
        let relabelled = LinkKeys {
            rendezvous: "ZZZZZZ".into(),
            to_presenter: n.to_presenter.clone(),
            to_joiner: n.to_joiner.clone(),
            confirm: n.confirm.clone(),
        };
        assert!(relabelled.open(Direction::ToPresenter, &sealed).is_err(), "the AAD leaves out the rendezvous");

        let (joiner, opening) = joiner_start("ABCDEF", "GHJK");
        let (j, p) = identities("QWERTY");
        let (presenter, answer) = Spake2::<Ed25519Group>::start_b(&Password::new(b"GHJK"), &j, &p);
        assert_ne!(
            joiner.finish(&answer).unwrap(),
            presenter.finish(&opening).unwrap(),
            "the handshake leaves out the rendezvous",
        );
    }

    #[test]
    fn a_malformed_handshake_message_refuses() {
        assert!(presenter_answer("ABCDEF", "GHJK", b"short").is_err());
        let (_, msg_a) = joiner_start("ABCDEF", "GHJK");
        assert!(presenter_answer("ABCDEF", "GHJK", &msg_a[1..]).is_err());
    }
}
