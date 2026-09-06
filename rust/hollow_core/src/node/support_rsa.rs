//! The RSA half of a support credential, pinned to ONE variant of RFC 9474:
//! RSABSSA-SHA384-PSS-Deterministic over RSA-3072. The app compiles this file and
//! the shop's `hollowpack` binary `#[path]`-includes it, because a second
//! definition of the variant anywhere else would be a second protocol. Keys
//! travel as PKCS#1 DER; the only dependency is the RFC 9474 crate.

// The issuing half (keygen, secret keys, blind_sign) belongs to the CLI; the app
// compiles it, because this is one file, and never calls it.
#![allow(dead_code)]

use blind_rsa_signatures::{
    BlindSignature, BlindingResult, DefaultRng, Deterministic, KeyPair, PublicKey, SecretKey,
    Sha384, Signature, PSS,
};

/// The RFC 9474 variant of every support credential.
pub type SupportPublicKey = PublicKey<Sha384, PSS, Deterministic>;
pub type SupportSecretKey = SecretKey<Sha384, PSS, Deterministic>;
pub type SupportKeyPair = KeyPair<Sha384, PSS, Deterministic>;

/// Modulus size of an issuing key. 3072 bits: 384-byte signatures, which is
/// what bounds a credential entry at about 1.4 KB.
pub const MODULUS_BITS: usize = 3072;
/// A blinded message, a blind signature and a signature are all exactly the
/// modulus in bytes.
pub const MODULUS_BYTES: usize = MODULUS_BITS / 8;

/// A fresh issuing key pair, as (secret PKCS#1 DER, public PKCS#1 DER).
pub fn generate_issuing_key() -> Result<(Vec<u8>, Vec<u8>), String> {
    let kp = SupportKeyPair::generate(&mut DefaultRng, MODULUS_BITS)
        .map_err(|e| format!("RSA key generation failed: {e}"))?;
    let sk = kp.sk.to_der().map_err(|e| format!("secret key encoding failed: {e}"))?;
    let pk = kp.pk.to_der().map_err(|e| format!("public key encoding failed: {e}"))?;
    Ok((sk, pk))
}

/// Parse an issuing PUBLIC key. Refuses anything but 3072-bit RSA with a
/// standard exponent: a credential under a 2048-bit key is not one this
/// protocol issued.
pub fn public_key_from_der(der: &[u8]) -> Result<SupportPublicKey, String> {
    let pk = SupportPublicKey::from_der(der).map_err(|e| format!("bad issuing key: {e}"))?;
    // The modulus's top bit is set, so its big-endian length IS the key size.
    if pk.components().n().len() != MODULUS_BYTES {
        return Err("bad issuing key: not RSA-3072".into());
    }
    Ok(pk)
}

/// Parse an issuing SECRET key (the shop's side).
pub fn secret_key_from_der(der: &[u8]) -> Result<SupportSecretKey, String> {
    let sk = SupportSecretKey::from_der(der).map_err(|e| format!("bad issuing secret key: {e}"))?;
    if sk.components().n().len() != MODULUS_BYTES {
        return Err("bad issuing secret key: not RSA-3072".into());
    }
    Ok(sk)
}

/// Blind `message` under `pk`. Returns the blinded message to send and the
/// secret blinding state to finalize with; the state never leaves the client.
pub fn blind(pk: &SupportPublicKey, message: &[u8]) -> Result<(Vec<u8>, BlindingResult), String> {
    let result = pk
        .blind(&mut DefaultRng, message)
        .map_err(|e| format!("blinding failed: {e}"))?;
    Ok((result.blind_message.0.clone(), result))
}

/// The shop's side: sign a blinded message with the listing's secret key.
/// The signer never sees the message and cannot pick which identity it is
/// vouching for; that is the whole privacy property.
pub fn blind_sign(sk: &SupportSecretKey, blinded: &[u8]) -> Result<Vec<u8>, String> {
    if blinded.len() != MODULUS_BYTES {
        return Err("the blinded message has the wrong length".into());
    }
    let sig = sk
        .blind_sign(blinded)
        .map_err(|e| format!("blind signing failed: {e}"))?;
    Ok(sig.0)
}

/// Unblind and verify: the credential's signature, or why it is not one.
pub fn finalize(
    pk: &SupportPublicKey,
    blinding: &BlindingResult,
    blind_sig: &[u8],
    message: &[u8],
) -> Result<Vec<u8>, String> {
    if blind_sig.len() != MODULUS_BYTES {
        return Err("the blind signature has the wrong length".into());
    }
    let sig = pk
        .finalize(&BlindSignature(blind_sig.to_vec()), blinding, message)
        .map_err(|e| format!("the shop's signature did not verify: {e}"))?;
    Ok(sig.0)
}

/// Verify a finished signature over `message` under `pk`.
pub fn verify(pk: &SupportPublicKey, signature: &[u8], message: &[u8]) -> bool {
    signature.len() == MODULUS_BYTES
        && pk.verify(&Signature(signature.to_vec()), None, message).is_ok()
}
