//! The recovery key: a second Ed25519 key derived from the recovery phrase, the root
//! of authority over an identity's devices (design ID-1). It exists only while the
//! phrase is typed; nothing writes it to disk.
//!
//! The master key is `seed[0..32]` and this one hashes all 64 bytes, so holding the
//! master (every device does) reveals nothing about it: `seed[32..64]` is the other
//! half of one HMAC-SHA512 output that the first half does not determine.

use bip39::Mnemonic;
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use super::native_identity::NativeKeypair;

const SALT: &[u8] = b"hollow-recovery";
const INFO: &[u8] = b"hollow-recovery-key1";

/// The recovery key of the identity a BIP-39 seed belongs to.
pub(crate) fn recovery_keypair_from_seed(seed: &[u8; 64]) -> NativeKeypair {
    let hk = Hkdf::<Sha256>::new(Some(SALT), seed);
    let mut secret = Zeroizing::new([0u8; 32]);
    // 32 bytes is far below HKDF-SHA256's 8160-byte ceiling, so expand cannot fail.
    let _ = hk.expand(INFO, &mut secret[..]);
    NativeKeypair::from_secret_bytes(&secret)
}

/// The master and recovery keys a typed phrase yields.
pub(crate) fn keys_from_phrase(phrase: &str) -> Result<(NativeKeypair, NativeKeypair), String> {
    let mnemonic: Mnemonic = phrase
        .trim()
        .parse()
        .map_err(|_| "That isn't a valid recovery phrase. Check each word.".to_string())?;
    let seed = Zeroizing::new(mnemonic.to_seed(""));
    let master = NativeKeypair::from_mnemonic(&mnemonic)?;
    Ok((master, recovery_keypair_from_seed(&seed)))
}

/// The recovery key for `phrase`, refused unless the phrase belongs to `master_peer_id`:
/// a phrase from another identity must never sign for this one.
pub(crate) fn recovery_key_for(master_peer_id: &str, phrase: &str) -> Result<(NativeKeypair, NativeKeypair), String> {
    let (master, recovery) = keys_from_phrase(phrase)?;
    if master.peer_id() != master_peer_id {
        return Err("That recovery phrase belongs to a different identity.".into());
    }
    Ok((master, recovery))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABOUT: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    /// Pinned: every identity's recovery key hangs on this derivation, so a change
    /// here orphans every published recovery key.
    #[test]
    fn recovery_key_known_answer() {
        let (master, recovery) = keys_from_phrase(ABOUT).unwrap();
        assert_eq!(master.peer_id(), "12D3KooWP7CwQswqLKZbwvYd9wrEynnL9F2aKVP1X9huNASBTuqj");
        assert_eq!(
            hex::encode(recovery.public_key_bytes()),
            RECOVERY_PUB_ABOUT,
            "recovery key derivation changed",
        );
    }

    /// Computed independently (Python `cryptography`: PBKDF2-HMAC-SHA512 seed, HKDF-SHA256,
    /// Ed25519), not read back from this code.
    const RECOVERY_PUB_ABOUT: &str =
        "2369a482fc1374d4ac88bb00a97fae581142cbe540ee50a522e23b6b507b967f";

    #[test]
    fn the_recovery_key_is_not_the_master_key() {
        let (master, recovery) = keys_from_phrase(ABOUT).unwrap();
        assert_ne!(master.secret_key_bytes(), recovery.secret_key_bytes());
        assert_ne!(master.public_key_bytes(), recovery.public_key_bytes());
    }

    #[test]
    fn a_phrase_from_another_identity_is_refused() {
        let other = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
        let (master, _) = keys_from_phrase(ABOUT).unwrap();
        assert!(recovery_key_for(&master.peer_id(), other).is_err());
        assert!(recovery_key_for(&master.peer_id(), ABOUT).is_ok());
        assert!(recovery_key_for(&master.peer_id(), "not a phrase").is_err());
    }
}
