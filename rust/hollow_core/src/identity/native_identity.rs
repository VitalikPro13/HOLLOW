//! Native Ed25519 identity module — replaces libp2p::identity.
//!
//! Produces identical PeerId strings (`12D3KooW...`) and Ed25519 signatures
//! as libp2p, using ed25519-dalek directly.

use bip39::Mnemonic;
use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};

/// Native Ed25519 keypair, replacing `libp2p::identity::Keypair`.
#[derive(Clone)]
pub(crate) struct NativeKeypair {
    signing_key: SigningKey,
}

impl NativeKeypair {
    /// Derive a keypair from a BIP-39 mnemonic (first 32 bytes of seed).
    pub fn from_mnemonic(mnemonic: &Mnemonic) -> Result<Self, String> {
        let seed = mnemonic.to_seed("");
        let mut secret_bytes = [0u8; 32];
        secret_bytes.copy_from_slice(&seed[..32]);
        Ok(Self {
            signing_key: SigningKey::from_bytes(&secret_bytes),
        })
    }

    /// Construct from raw 32-byte secret key.
    pub fn from_secret_bytes(bytes: &[u8; 32]) -> Self {
        Self {
            signing_key: SigningKey::from_bytes(bytes),
        }
    }

    /// Decode from libp2p's protobuf keypair encoding.
    ///
    /// Format: `[0x08, 0x01, 0x12, 0x40, secret(32), public(32)]` (68 bytes total).
    pub fn from_protobuf_encoding(bytes: &[u8]) -> Result<Self, String> {
        // libp2p Ed25519 protobuf: field 1 (type) = 1, field 2 (data) = 64 bytes
        // Wire: 0x08 0x01 0x12 0x40 [secret_key(32) || public_key(32)]
        if bytes.len() < 68 {
            return Err(format!(
                "Protobuf too short: expected >=68 bytes, got {}",
                bytes.len()
            ));
        }
        if bytes[0] != 0x08 || bytes[1] != 0x01 || bytes[2] != 0x12 || bytes[3] != 0x40 {
            return Err("Invalid protobuf header for Ed25519 keypair".into());
        }
        let mut secret = [0u8; 32];
        secret.copy_from_slice(&bytes[4..36]);
        let keypair = Self {
            signing_key: SigningKey::from_bytes(&secret),
        };
        // Verify the public key matches.
        let expected_pub = &bytes[36..68];
        let actual_pub = keypair.signing_key.verifying_key().to_bytes();
        if actual_pub != expected_pub {
            return Err("Public key mismatch in protobuf encoding".into());
        }
        Ok(keypair)
    }

    /// Encode to libp2p-compatible protobuf format (for backward-compatible storage).
    ///
    /// Returns `Result` for API compatibility with callsites that expect `Result`
    /// (carried over from `libp2p::identity::Keypair::to_protobuf_encoding`).
    /// This never fails in practice.
    pub fn to_protobuf_encoding(&self) -> Result<Vec<u8>, String> {
        let secret = self.signing_key.to_bytes();
        let public = self.signing_key.verifying_key().to_bytes();
        let mut buf = Vec::with_capacity(68);
        buf.extend_from_slice(&[0x08, 0x01, 0x12, 0x40]);
        buf.extend_from_slice(&secret);
        buf.extend_from_slice(&public);
        Ok(buf)
    }

    /// Derive the PeerId string, identical to libp2p's `12D3KooW...` format.
    ///
    /// libp2p uses an **identity** multihash for Ed25519 keys because the protobuf-encoded
    /// public key (36 bytes) is <= 42 bytes (the inline threshold). The identity multihash
    /// simply wraps the raw bytes: `[0x00, length, ...raw_protobuf_pubkey]`.
    ///
    /// For keys > 42 bytes, SHA-256 would be used instead (code 0x12).
    pub fn peer_id(&self) -> String {
        let pubkey_proto = self.public_key_protobuf(); // 36 bytes
        // Identity multihash: code 0x00 + length as unsigned varint + raw bytes
        // 36 = 0x24, fits in one varint byte
        let mut multihash = Vec::with_capacity(2 + pubkey_proto.len());
        multihash.push(0x00); // Identity multihash code
        multihash.push(pubkey_proto.len() as u8); // 36 = 0x24
        multihash.extend_from_slice(&pubkey_proto);
        bs58::encode(&multihash).with_alphabet(bs58::Alphabet::BITCOIN).into_string()
    }

    /// Sign a message with Ed25519. Returns the 64-byte signature.
    pub fn sign(&self, msg: &[u8]) -> Vec<u8> {
        let sig = self.signing_key.sign(msg);
        sig.to_bytes().to_vec()
    }

    /// 36-byte protobuf encoding of the public key.
    /// Format: `[0x08, 0x01, 0x12, 0x20, ...32_byte_pubkey]`
    /// Used for signaling registration and WS auth.
    pub fn public_key_protobuf(&self) -> Vec<u8> {
        let public = self.signing_key.verifying_key().to_bytes();
        let mut buf = Vec::with_capacity(36);
        buf.extend_from_slice(&[0x08, 0x01, 0x12, 0x20]);
        buf.extend_from_slice(&public);
        buf
    }

    /// Get the raw 32-byte public key.
    pub fn public_key_bytes(&self) -> [u8; 32] {
        self.signing_key.verifying_key().to_bytes()
    }

    /// Get the raw 32-byte secret key.
    pub fn secret_key_bytes(&self) -> [u8; 32] {
        self.signing_key.to_bytes()
    }

    /// Verify a signature from a peer, given their protobuf-encoded public key.
    ///
    /// `pubkey_protobuf` is the 36-byte `[0x08, 0x01, 0x12, 0x20, ...pubkey]` format.
    pub fn verify_peer_signature(
        pubkey_protobuf: &[u8],
        signature: &[u8],
        payload: &[u8],
    ) -> Result<bool, String> {
        if pubkey_protobuf.len() < 36 {
            return Err("Public key protobuf too short".into());
        }
        if pubkey_protobuf[0] != 0x08
            || pubkey_protobuf[1] != 0x01
            || pubkey_protobuf[2] != 0x12
            || pubkey_protobuf[3] != 0x20
        {
            return Err("Invalid protobuf header for Ed25519 public key".into());
        }
        let pub_bytes: [u8; 32] = pubkey_protobuf[4..36]
            .try_into()
            .map_err(|_| "Invalid pubkey length")?;
        let verifying_key =
            VerifyingKey::from_bytes(&pub_bytes).map_err(|e| format!("Invalid pubkey: {e}"))?;
        let sig_bytes: [u8; 64] = signature
            .try_into()
            .map_err(|_| "Signature must be 64 bytes")?;
        let sig = ed25519_dalek::Signature::from_bytes(&sig_bytes);
        Ok(verifying_key.verify(payload, &sig).is_ok())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Known-good PeerId for "abandon...about" mnemonic (verified against libp2p 0.56).
    const KNOWN_PEER_ID: &str = "12D3KooWP7CwQswqLKZbwvYd9wrEynnL9F2aKVP1X9huNASBTuqj";

    /// Test PeerId derivation against a known-good value (originally verified against libp2p).
    #[test]
    fn peer_id_known_good() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mnemonic: Mnemonic = phrase.parse().unwrap();
        let native = NativeKeypair::from_mnemonic(&mnemonic).unwrap();
        assert_eq!(native.peer_id(), KNOWN_PEER_ID);
    }

    /// Test protobuf round-trip: encode -> decode -> same key.
    #[test]
    fn protobuf_round_trip() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mnemonic: Mnemonic = phrase.parse().unwrap();
        let kp = NativeKeypair::from_mnemonic(&mnemonic).unwrap();

        let encoded = kp.to_protobuf_encoding().unwrap();
        assert_eq!(encoded.len(), 68);
        assert_eq!(&encoded[..4], &[0x08, 0x01, 0x12, 0x40]);

        let decoded = NativeKeypair::from_protobuf_encoding(&encoded).unwrap();
        assert_eq!(kp.secret_key_bytes(), decoded.secret_key_bytes());
        assert_eq!(kp.public_key_bytes(), decoded.public_key_bytes());
        assert_eq!(kp.peer_id(), decoded.peer_id());
    }

    /// Test that protobuf-encoded keypair files can be loaded (backward compat).
    #[test]
    fn load_protobuf_keypair() {
        let phrase = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
        let mnemonic: Mnemonic = phrase.parse().unwrap();
        let kp = NativeKeypair::from_mnemonic(&mnemonic).unwrap();

        // Encode and decode — simulates loading an existing identity.key file.
        let bytes = kp.to_protobuf_encoding().unwrap();
        let loaded = NativeKeypair::from_protobuf_encoding(&bytes).unwrap();
        assert_eq!(kp.peer_id(), loaded.peer_id());
        assert_eq!(kp.secret_key_bytes(), loaded.secret_key_bytes());
    }

    /// Test signature creation and verification.
    #[test]
    fn signature_sign_and_verify() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mnemonic: Mnemonic = phrase.parse().unwrap();
        let kp = NativeKeypair::from_mnemonic(&mnemonic).unwrap();

        let msg = b"hollow-ws-auth:12D3KooWtest:1234567890";
        let sig = kp.sign(msg);
        assert_eq!(sig.len(), 64);

        let pubkey_proto = kp.public_key_protobuf();
        let valid = NativeKeypair::verify_peer_signature(&pubkey_proto, &sig, msg).unwrap();
        assert!(valid, "Signature should verify");

        // Tampered message should fail.
        let invalid =
            NativeKeypair::verify_peer_signature(&pubkey_proto, &sig, b"tampered").unwrap();
        assert!(!invalid, "Tampered message should not verify");
    }

    /// Test public_key_protobuf format is correct (36 bytes: header + 32-byte pubkey).
    #[test]
    fn public_key_protobuf_format() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mnemonic: Mnemonic = phrase.parse().unwrap();
        let native = NativeKeypair::from_mnemonic(&mnemonic).unwrap();
        let proto = native.public_key_protobuf();
        assert_eq!(proto.len(), 36);
        assert_eq!(&proto[..4], &[0x08, 0x01, 0x12, 0x20]);
        assert_eq!(&proto[4..], native.public_key_bytes());
    }
}
