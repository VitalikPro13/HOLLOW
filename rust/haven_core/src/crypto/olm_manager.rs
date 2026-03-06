use std::collections::HashMap;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use vodozemac::olm::{
    Account, InboundCreationResult, OlmMessage, Session, SessionConfig,
};
use vodozemac::Curve25519PublicKey;

/// Wraps a vodozemac Olm Account and per-peer Sessions.
/// All crypto state lives here — encrypt, decrypt, key exchange.
pub(crate) struct OlmManager {
    account: Account,
    sessions: HashMap<String, Session>,
}

impl OlmManager {
    /// Create a brand-new Olm account (fresh Curve25519 + Ed25519 keys).
    pub fn new() -> Self {
        OlmManager {
            account: Account::new(),
            sessions: HashMap::new(),
        }
    }

    /// Restore from previously pickled account + sessions.
    pub fn from_pickles(
        account_json: &str,
        sessions: Vec<(String, String)>,
    ) -> Result<Self, String> {
        let account_pickle = serde_json::from_str(account_json)
            .map_err(|e| format!("Failed to deserialize account pickle: {e}"))?;
        let account = Account::from_pickle(account_pickle);

        let mut session_map = HashMap::new();
        for (peer_id, session_json) in sessions {
            let session_pickle = serde_json::from_str(&session_json)
                .map_err(|e| format!("Failed to deserialize session pickle for {peer_id}: {e}"))?;
            session_map.insert(peer_id, Session::from_pickle(session_pickle));
        }

        Ok(OlmManager {
            account,
            sessions: session_map,
        })
    }

    /// Our Curve25519 identity key as unpadded base64.
    pub fn identity_key_base64(&self) -> String {
        self.account.curve25519_key().to_base64()
    }

    /// Generate a fresh one-time key and return it as unpadded base64.
    /// Marks the key as published so it won't be returned again.
    pub fn generate_one_time_key(&mut self) -> String {
        self.account.generate_one_time_keys(1);
        let keys = self.account.one_time_keys();
        let otk = keys
            .values()
            .next()
            .expect("Just generated one key, must exist");
        let otk_b64 = otk.to_base64();
        self.account.mark_keys_as_published();
        otk_b64
    }

    /// Generate a batch of one-time keys and return them as unpadded base64.
    /// Marks all as published so they won't be returned again.
    pub fn generate_one_time_keys_batch(&mut self, count: usize) -> Vec<String> {
        self.account.generate_one_time_keys(count);
        let keys = self.account.one_time_keys();
        let otks: Vec<String> = keys.values().map(|k| k.to_base64()).collect();
        self.account.mark_keys_as_published();
        otks
    }

    /// Create an outbound session using the peer's identity key + one-time key.
    pub fn create_outbound_session(
        &mut self,
        peer_id: &str,
        their_identity_key_b64: &str,
        their_otk_b64: &str,
    ) -> Result<(), String> {
        let their_identity_key = Curve25519PublicKey::from_base64(their_identity_key_b64)
            .map_err(|e| format!("Invalid identity key: {e}"))?;
        let their_otk = Curve25519PublicKey::from_base64(their_otk_b64)
            .map_err(|e| format!("Invalid one-time key: {e}"))?;

        let session = self.account.create_outbound_session(
            SessionConfig::version_2(),
            their_identity_key,
            their_otk,
        );
        self.sessions.insert(peer_id.to_string(), session);
        Ok(())
    }

    /// Create an inbound session from a PreKeyMessage. Returns the decrypted plaintext.
    pub fn create_inbound_session(
        &mut self,
        peer_id: &str,
        their_identity_key_b64: &str,
        pre_key_message_bytes: &[u8],
    ) -> Result<Vec<u8>, String> {
        let their_identity_key = Curve25519PublicKey::from_base64(their_identity_key_b64)
            .map_err(|e| format!("Invalid identity key: {e}"))?;

        // Decode the PreKeyMessage from the raw bytes.
        let olm_msg = OlmMessage::from_parts(0, pre_key_message_bytes)
            .map_err(|e| format!("Failed to decode PreKeyMessage: {e}"))?;

        let pre_key_msg = match olm_msg {
            OlmMessage::PreKey(m) => m,
            _ => return Err("Expected PreKeyMessage but got Normal".to_string()),
        };

        let InboundCreationResult { session, plaintext } = self
            .account
            .create_inbound_session(their_identity_key, &pre_key_msg)
            .map_err(|e| format!("Failed to create inbound session: {e}"))?;

        self.sessions.insert(peer_id.to_string(), session);
        Ok(plaintext)
    }

    /// Encrypt a plaintext message for a peer. Returns (message_type, ciphertext_bytes).
    /// message_type: 0 = PreKey, 1 = Normal.
    pub fn encrypt(&mut self, peer_id: &str, plaintext: &[u8]) -> Result<(usize, Vec<u8>), String> {
        let session = self
            .sessions
            .get_mut(peer_id)
            .ok_or_else(|| format!("No session for peer {peer_id}"))?;
        let olm_msg = session.encrypt(plaintext);
        let (msg_type, ciphertext) = olm_msg.to_parts();
        Ok((msg_type, ciphertext))
    }

    /// Decrypt a message from a peer. Returns the plaintext bytes.
    pub fn decrypt(
        &mut self,
        peer_id: &str,
        message_type: usize,
        ciphertext_bytes: &[u8],
    ) -> Result<Vec<u8>, String> {
        let session = self
            .sessions
            .get_mut(peer_id)
            .ok_or_else(|| format!("No session for peer {peer_id}"))?;
        let olm_msg = OlmMessage::from_parts(message_type, ciphertext_bytes)
            .map_err(|e| format!("Failed to decode OlmMessage: {e}"))?;
        session
            .decrypt(&olm_msg)
            .map_err(|e| format!("Decryption failed: {e}"))
    }

    /// Try to decrypt a PreKey message using an existing session.
    /// This handles the race where we already established a session from a previous
    /// PreKey, and a second PreKey arrives (e.g. sync batch + regular message overlap).
    /// Returns Ok(plaintext) if the existing session can handle it, Err otherwise.
    pub fn try_decrypt_prekey_with_existing(
        &mut self,
        peer_id: &str,
        ciphertext_bytes: &[u8],
    ) -> Result<Vec<u8>, String> {
        let session = self
            .sessions
            .get_mut(peer_id)
            .ok_or_else(|| format!("No session for peer {peer_id}"))?;
        let olm_msg = OlmMessage::from_parts(0, ciphertext_bytes)
            .map_err(|e| format!("Failed to decode PreKey OlmMessage: {e}"))?;
        session
            .decrypt(&olm_msg)
            .map_err(|e| format!("PreKey decrypt with existing session failed: {e}"))
    }

    /// Check if we have an established session with a peer.
    pub fn has_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id)
    }

    /// Remove an existing session (e.g., to replace it).
    pub fn remove_session(&mut self, peer_id: &str) {
        self.sessions.remove(peer_id);
    }

    /// Serialize the Account for DB storage.
    pub fn account_pickle_json(&self) -> Result<String, String> {
        let pickle = self.account.pickle();
        serde_json::to_string(&pickle)
            .map_err(|e| format!("Failed to serialize account pickle: {e}"))
    }

    /// Serialize a specific Session for DB storage.
    pub fn session_pickle_json(&self, peer_id: &str) -> Result<Option<String>, String> {
        match self.sessions.get(peer_id) {
            Some(session) => {
                let pickle = session.pickle();
                let json = serde_json::to_string(&pickle)
                    .map_err(|e| format!("Failed to serialize session pickle: {e}"))?;
                Ok(Some(json))
            }
            None => Ok(None),
        }
    }

    /// Encode bytes as standard base64.
    pub fn encode_base64(data: &[u8]) -> String {
        BASE64.encode(data)
    }

    /// Decode standard base64 to bytes.
    pub fn decode_base64(data: &str) -> Result<Vec<u8>, String> {
        BASE64
            .decode(data)
            .map_err(|e| format!("Base64 decode failed: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_alice_bob_session() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        // Bob generates a one-time key and shares his identity key.
        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        // Alice creates an outbound session to Bob.
        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();

        // Alice encrypts a message (first message → PreKeyMessage, type 0).
        let (msg_type, ciphertext) = alice.encrypt("bob", b"Hello Bob!").unwrap();
        assert_eq!(msg_type, 0, "First message should be PreKey type");

        // Bob creates an inbound session from Alice's PreKeyMessage.
        let alice_identity = alice.identity_key_base64();
        let plaintext = bob
            .create_inbound_session("alice", &alice_identity, &ciphertext)
            .unwrap();
        assert_eq!(plaintext, b"Hello Bob!");

        // Bob can now encrypt a reply (should be Normal type 1).
        let (msg_type2, ciphertext2) = bob.encrypt("alice", b"Hi Alice!").unwrap();
        assert_eq!(msg_type2, 1, "Reply should be Normal type");

        // Alice decrypts Bob's reply (session keyed by "bob" on Alice's side).
        let plaintext2 = alice.decrypt("bob", msg_type2, &ciphertext2).unwrap();
        assert_eq!(plaintext2, b"Hi Alice!");
    }

    #[test]
    fn test_pickle_round_trip() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();

        // Pickle and restore Alice.
        let account_json = alice.account_pickle_json().unwrap();
        let session_json = alice.session_pickle_json("bob").unwrap().unwrap();

        let mut alice2 = OlmManager::from_pickles(
            &account_json,
            vec![("bob".to_string(), session_json)],
        )
        .unwrap();

        // Alice2 should have the same identity key.
        assert_eq!(
            alice.identity_key_base64(),
            alice2.identity_key_base64()
        );

        // Alice2 should still be able to encrypt for Bob.
        let (msg_type, ciphertext) = alice2.encrypt("bob", b"After restore").unwrap();
        assert_eq!(msg_type, 0); // Still PreKey since Bob hasn't responded

        // Bob can receive it.
        let alice_identity = alice2.identity_key_base64();
        let plaintext = bob
            .create_inbound_session("alice", &alice_identity, &ciphertext)
            .unwrap();
        assert_eq!(plaintext, b"After restore");
    }

    #[test]
    fn test_multiple_prekeys_from_same_session() {
        // vodozemac produces PreKey (type 0) for ALL messages on an outbound
        // session until the peer responds. Verify this behavior and that
        // the second PreKey can be decrypted with the existing inbound session.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();

        // Alice encrypts two messages back-to-back.
        // Both are PreKey (type 0) — this is vodozemac's behavior.
        let (msg_type1, ct1) = alice.encrypt("bob", b"Message 1").unwrap();
        assert_eq!(msg_type1, 0, "First message should be PreKey");
        let (msg_type2, ct2) = alice.encrypt("bob", b"Message 2").unwrap();
        assert_eq!(msg_type2, 0, "Second message is also PreKey until peer responds");

        // Bob receives and processes PreKey #1 — creates inbound session.
        let alice_id = alice.identity_key_base64();
        let pt1 = bob.create_inbound_session("alice", &alice_id, &ct1).unwrap();
        assert_eq!(pt1, b"Message 1");

        // Bob now has a session. PreKey #2 from the same outbound session
        // should be decryptable with try_decrypt_prekey_with_existing.
        let pt2 = bob.try_decrypt_prekey_with_existing("alice", &ct2).unwrap();
        assert_eq!(pt2, b"Message 2");
    }

    #[test]
    fn test_dual_prekey_creates_incompatible_sessions() {
        // When both peers create outbound sessions simultaneously, they end up
        // with incompatible sessions after processing each other's PreKeys.
        // This test verifies the sessions are incompatible (which is why the
        // swarm code needs to handle this with re-keying).
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let alice_id = alice.identity_key_base64();
        let bob_id = bob.identity_key_base64();
        let alice_otk = alice.generate_one_time_key();
        let bob_otk = bob.generate_one_time_key();

        alice.create_outbound_session("bob", &bob_id, &bob_otk).unwrap();
        bob.create_outbound_session("alice", &alice_id, &alice_otk).unwrap();

        let (at, act) = alice.encrypt("bob", b"Hello from Alice").unwrap();
        let (bt, bct) = bob.encrypt("alice", b"Hello from Bob").unwrap();
        assert_eq!(at, 0);
        assert_eq!(bt, 0);

        // Bob processes Alice's PreKey — replaces his outbound session.
        bob.remove_session("alice");
        let pt_a = bob.create_inbound_session("alice", &alice_id, &act).unwrap();
        assert_eq!(pt_a, b"Hello from Alice");

        // Alice processes Bob's PreKey — replaces her outbound session.
        alice.remove_session("bob");
        let pt_b = alice.create_inbound_session("bob", &bob_id, &bct).unwrap();
        assert_eq!(pt_b, b"Hello from Bob");

        // Sessions are now incompatible — Bob's reply will fail to decrypt on Alice's side.
        // This is expected and the swarm code handles it via re-keying (KeyRequest).
        let (_rt, rct) = bob.encrypt("alice", b"Reply from Bob").unwrap();
        let result = alice.decrypt("bob", 1, &rct);
        assert!(result.is_err(), "Dual-PreKey sessions should be incompatible");
    }
}
