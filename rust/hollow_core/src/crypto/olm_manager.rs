use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use vodozemac::olm::{
    Account, InboundCreationResult, OlmMessage, Session, SessionConfig,
};
use vodozemac::Curve25519PublicKey;

/// Wraps a vodozemac Olm Account and per-peer Sessions: all crypto state lives here.
pub(crate) struct OlmManager {
    account: Account,
    sessions: HashMap<String, Session>,
    /// Peers whose session came from `create_outbound_session`. An outbound-only session
    /// produces PreKey (type 0) for ALL messages until an inbound session replaces it.
    outbound_only: HashSet<String>,
    session_last_used: HashMap<String, Instant>,
}

impl OlmManager {
    /// Create a brand-new Olm account (fresh Curve25519 + Ed25519 keys).
    pub fn new() -> Self {
        OlmManager {
            account: Account::new(),
            sessions: HashMap::new(),
            outbound_only: HashSet::new(),
            session_last_used: HashMap::new(),
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

        let now = Instant::now();
        let session_last_used: HashMap<String, Instant> = session_map.keys()
            .map(|k| (k.clone(), now))
            .collect();

        Ok(OlmManager {
            account,
            sessions: session_map,
            // Restored sessions are conservatively assumed outbound; the first PreKey from
            // the peer replaces them.
            outbound_only: HashSet::new(),
            session_last_used,
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
        self.outbound_only.insert(peer_id.to_string());
        self.session_last_used.insert(peer_id.to_string(), Instant::now());
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
        self.outbound_only.remove(peer_id); // Now inbound-derived — produces Normal
        self.session_last_used.insert(peer_id.to_string(), Instant::now());
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
        self.session_last_used.insert(peer_id.to_string(), Instant::now());
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
        let plaintext = session
            .decrypt(&olm_msg)
            .map_err(|e| format!("Decryption failed: {e}"))?;
        // A successful decrypt proves the peer replied to our PreKey, so an outbound-only
        // session is now confirmed bidirectional.
        self.outbound_only.remove(peer_id);
        self.session_last_used.insert(peer_id.to_string(), Instant::now());
        Ok(plaintext)
    }

    /// Try to decrypt a PreKey message on an existing session, for the race where a
    /// second PreKey arrives after one already established the session. `Err` when the
    /// existing session cannot handle it.
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

    /// Check if we have any session object for a peer (may be unconfirmed
    /// outbound-only, i.e. the peer may not yet hold the matching half).
    pub fn has_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id)
    }

    /// Whether we have a session CONFIRMED bidirectional: inbound-derived, or outbound
    /// that the peer acknowledged. Only such a session is proven decryptable by the peer,
    /// so an outbound-only one is pending and must not be reported to the UI.
    pub fn has_confirmed_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id) && !self.outbound_only.contains(peer_id)
    }

    /// Whether we have an outbound-only (unconfirmed) session: we sent a PreKey and the
    /// peer has not replied. Decides whether a repeated KeyRequest should re-handshake.
    pub fn has_unconfirmed_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id) && self.outbound_only.contains(peer_id)
    }

    /// TEST-ONLY: enumerate the peer DEVICE ids we hold any Olm session for, so
    /// the multi-node harness can snapshot session status across all peers.
    #[cfg(test)]
    pub fn session_peer_ids(&self) -> Vec<String> {
        self.sessions.keys().cloned().collect()
    }

    /// Remove an existing session (e.g., to replace it).
    pub fn remove_session(&mut self, peer_id: &str) {
        self.sessions.remove(peer_id);
        self.outbound_only.remove(peer_id);
        self.session_last_used.remove(peer_id);
    }

    /// Remove sessions unused within the TTL, returning the pruned peer ids so the caller
    /// can clear related bookkeeping: a stale in-flight flag would block the next
    /// handshake after the session is gone.
    pub fn prune_stale_sessions(&mut self, ttl: Duration) -> Vec<String> {
        let stale: Vec<String> = self.session_last_used.iter()
            .filter(|(_, last)| last.elapsed() > ttl)
            .map(|(id, _)| id.clone())
            .collect();
        for peer_id in &stale {
            self.sessions.remove(peer_id);
            self.outbound_only.remove(peer_id);
            self.session_last_used.remove(peer_id);
        }
        stale
    }

    /// Mark a session bidirectional, on a SessionAck confirming the peer created an
    /// inbound session and our ratchet advanced.
    pub fn mark_session_bidirectional(&mut self, peer_id: &str) {
        self.outbound_only.remove(peer_id);
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

    // When the iOS app is force-killed the Notification Service Extension must show the
    // decrypted TEXT without advancing the canonical Olm ratchet, so it FORKS the session
    // from the pickle, decrypts on the copy and discards it. These tests pin the two
    // load-bearing assumptions: a fork decrypts without mutating the original, and the
    // original can still decrypt that same message afterwards.

    /// Build an ESTABLISHED, mid-stream bidirectional Alice-Bob pair, the realistic case
    /// rather than first contact. Bob is the "phone" whose session the NSE forks.
    fn established_pair() -> (OlmManager, OlmManager) {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();

        let (_t, ct) = alice.encrypt("bob", b"handshake").unwrap();
        let alice_id = alice.identity_key_base64();
        bob.create_inbound_session("alice", &alice_id, &ct).unwrap();

        let (t2, ct2) = bob.encrypt("alice", b"ack").unwrap();
        alice.decrypt("bob", t2, &ct2).unwrap();

        let (t3, ct3) = alice.encrypt("bob", b"round-1").unwrap();
        bob.decrypt("alice", t3, &ct3).unwrap();
        let (t4, ct4) = bob.encrypt("alice", b"round-2").unwrap();
        alice.decrypt("bob", t4, &ct4).unwrap();

        (alice, bob)
    }

    #[test]
    fn spike_nse_fork_decrypt_does_not_consume_canonical() {
        let (mut alice, bob) = established_pair();

        // Bob's canonical pickle, what the phone's DB holds when the app is force-killed.
        // The NSE and the app both start from THIS exact byte string.
        let canonical_pickle = bob.session_pickle_json("alice").unwrap().unwrap();
        let account_pickle = bob.account_pickle_json().unwrap();

        // Alice (the friend) sends the message that triggers the push.
        let (mt, ct) = alice.encrypt("bob", b"secret push body").unwrap();

        // NSE path: the fork is a fresh OlmManager from the SAME pickles, so decrypting
        // mutates only this throwaway.
        let nse_plain = {
            let mut nse_fork = OlmManager::from_pickles(
                &account_pickle,
                vec![("alice".to_string(), canonical_pickle.clone())],
            )
            .unwrap();
            nse_fork.decrypt("alice", mt, &ct).unwrap()
            // nse_fork dropped here — never written back to disk.
        };
        assert_eq!(nse_plain, b"secret push body", "Q1: NSE fork decrypts");

        // App path: the ORIGINAL canonical pickle, untouched by the NSE, decrypting the
        // SAME ciphertext when the relay replays the buffered message.
        let mut app = OlmManager::from_pickles(
            &account_pickle,
            vec![("alice".to_string(), canonical_pickle.clone())],
        )
        .unwrap();
        let app_plain = app.decrypt("alice", mt, &ct).unwrap();
        assert_eq!(
            app_plain, b"secret push body",
            "Q2: canonical session still decrypts the same message after the NSE forked"
        );

        // The app's advanced session keeps working for the NEXT message, so the fork did
        // not poison forward decryption.
        let (mt2, ct2) = alice.encrypt("bob", b"follow-up").unwrap();
        let app_plain2 = app.decrypt("alice", mt2, &ct2).unwrap();
        assert_eq!(app_plain2, b"follow-up", "Q2b: ratchet advances normally after");
    }

    #[test]
    fn spike_nse_fork_first_contact_prekey() {
        // First contact: the NSE must decrypt the PreKey on a fork WITHOUT consuming the
        // account's one-time key in a way that stops the app establishing the session.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();
        let (_mt, ct) = alice.encrypt("bob", b"first hello").unwrap();
        let alice_id = alice.identity_key_base64();

        let account_pickle = bob.account_pickle_json().unwrap();

        // NSE fork: a throwaway account, inbound session created on it, then discarded.
        let nse_plain = {
            let mut nse_fork =
                OlmManager::from_pickles(&account_pickle, vec![]).unwrap();
            nse_fork
                .create_inbound_session("alice", &alice_id, &ct)
                .unwrap()
        };
        assert_eq!(nse_plain, b"first hello", "Q1: NSE decrypts first-contact PreKey on fork");

        // The app establishes for real from the SAME account pickle, whose OTK is still
        // unconsumed because the NSE worked on a copy.
        let mut app = OlmManager::from_pickles(&account_pickle, vec![]).unwrap();
        let app_plain = app
            .create_inbound_session("alice", &alice_id, &ct)
            .unwrap();
        assert_eq!(
            app_plain, b"first hello",
            "Q2: app still establishes the same first-contact session after NSE forked"
        );
    }

    #[test]
    fn test_alice_bob_session() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();

        let (msg_type, ciphertext) = alice.encrypt("bob", b"Hello Bob!").unwrap();
        assert_eq!(msg_type, 0, "First message should be PreKey type");

        let alice_identity = alice.identity_key_base64();
        let plaintext = bob
            .create_inbound_session("alice", &alice_identity, &ciphertext)
            .unwrap();
        assert_eq!(plaintext, b"Hello Bob!");

        let (msg_type2, ciphertext2) = bob.encrypt("alice", b"Hi Alice!").unwrap();
        assert_eq!(msg_type2, 1, "Reply should be Normal type");

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

        let account_json = alice.account_pickle_json().unwrap();
        let session_json = alice.session_pickle_json("bob").unwrap().unwrap();

        let mut alice2 = OlmManager::from_pickles(
            &account_json,
            vec![("bob".to_string(), session_json)],
        )
        .unwrap();

        assert_eq!(
            alice.identity_key_base64(),
            alice2.identity_key_base64()
        );

        let (msg_type, ciphertext) = alice2.encrypt("bob", b"After restore").unwrap();
        assert_eq!(msg_type, 0); // Still PreKey since Bob hasn't responded

        let alice_identity = alice2.identity_key_base64();
        let plaintext = bob
            .create_inbound_session("alice", &alice_identity, &ciphertext)
            .unwrap();
        assert_eq!(plaintext, b"After restore");
    }

    #[test]
    fn test_multiple_prekeys_from_same_session() {
        // vodozemac produces PreKey (type 0) for ALL messages on an outbound session until
        // the peer responds, and the second PreKey must still decrypt on the inbound one.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();

        // Both are PreKey (type 0), which is vodozemac's behaviour.
        let (msg_type1, ct1) = alice.encrypt("bob", b"Message 1").unwrap();
        assert_eq!(msg_type1, 0, "First message should be PreKey");
        let (msg_type2, ct2) = alice.encrypt("bob", b"Message 2").unwrap();
        assert_eq!(msg_type2, 0, "Second message is also PreKey until peer responds");

        let alice_id = alice.identity_key_base64();
        let pt1 = bob.create_inbound_session("alice", &alice_id, &ct1).unwrap();
        assert_eq!(pt1, b"Message 1");

        let pt2 = bob.try_decrypt_prekey_with_existing("alice", &ct2).unwrap();
        assert_eq!(pt2, b"Message 2");
    }

    #[test]
    fn test_dual_prekey_creates_incompatible_sessions() {
        // Two peers creating outbound sessions simultaneously end up with incompatible
        // sessions after processing each other's PreKeys, which is why the swarm re-keys.
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

        bob.remove_session("alice");
        let pt_a = bob.create_inbound_session("alice", &alice_id, &act).unwrap();
        assert_eq!(pt_a, b"Hello from Alice");

        alice.remove_session("bob");
        let pt_b = alice.create_inbound_session("bob", &bob_id, &bct).unwrap();
        assert_eq!(pt_b, b"Hello from Bob");

        // The sessions are incompatible, which the swarm handles by re-keying.
        let (_rt, rct) = bob.encrypt("alice", b"Reply from Bob").unwrap();
        let result = alice.decrypt("bob", 1, &rct);
        assert!(result.is_err(), "Dual-PreKey sessions should be incompatible");
    }

    #[test]
    fn test_inbound_session_produces_normal_messages() {
        // An inbound-derived session produces Normal (type 1) messages, so file chunks are
        // never sent as PreKey.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let alice_id = alice.identity_key_base64();
        let bob_id = bob.identity_key_base64();
        let alice_otk = alice.generate_one_time_key();

        bob.create_outbound_session("alice", &alice_id, &alice_otk).unwrap();
        let (msg_type, ct) = bob.encrypt("alice", b"Hello Alice").unwrap();
        assert_eq!(msg_type, 0, "Outbound session produces PreKey");

        let pt = alice.create_inbound_session("bob", &bob_id, &ct).unwrap();
        assert_eq!(pt, b"Hello Alice");
        assert!(alice.has_session("bob"));
        for i in 0..100 {
            let (mt, _) = alice.encrypt("bob", format!("Chunk {i}").as_bytes()).unwrap();
            assert_eq!(mt, 1, "Inbound-derived session should always produce Normal (type 1)");
        }
    }

    #[test]
    fn test_confirmed_vs_unconfirmed_session_state() {
        // An outbound session is UNCONFIRMED until the peer replies: has_session is true
        // while has_confirmed_session is false until a decrypt or a SessionAck.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice.create_outbound_session("bob", &bob_id, &bob_otk).unwrap();
        assert!(alice.has_session("bob"));
        assert!(alice.has_unconfirmed_session("bob"));
        assert!(!alice.has_confirmed_session("bob"), "outbound-only must NOT be confirmed");

        let (_mt, ct) = alice.encrypt("bob", b"Hello").unwrap();
        let alice_id = alice.identity_key_base64();
        bob.create_inbound_session("alice", &alice_id, &ct).unwrap();
        assert!(bob.has_confirmed_session("alice"), "inbound-derived session is confirmed");
        assert!(!bob.has_unconfirmed_session("alice"));

        let (mt2, ct2) = bob.encrypt("alice", b"Reply").unwrap();
        alice.decrypt("bob", mt2, &ct2).unwrap();
        assert!(alice.has_confirmed_session("bob"), "decrypting a reply confirms the session");
        assert!(!alice.has_unconfirmed_session("bob"));
    }

    #[test]
    fn test_mark_bidirectional_confirms_session() {
        // mark_session_bidirectional confirms an outbound session without a decrypt.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice.create_outbound_session("bob", &bob_id, &bob_otk).unwrap();
        assert!(alice.has_unconfirmed_session("bob"));
        alice.mark_session_bidirectional("bob");
        assert!(alice.has_confirmed_session("bob"));
        assert!(!alice.has_unconfirmed_session("bob"));
    }

    #[test]
    fn test_prune_returns_pruned_peer_ids() {
        // The pruned peer ids come back so the caller can clear related bookkeeping.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice.create_outbound_session("bob", &bob_id, &bob_otk).unwrap();

        let pruned = alice.prune_stale_sessions(Duration::from_secs(0));
        assert_eq!(pruned, vec!["bob".to_string()]);
        assert!(!alice.has_session("bob"));
    }

    #[test]
    fn test_outbound_session_upgrades_after_receiving_reply() {
        // The full handshake is what fixes the PreKey race for file transfer: once Alice
        // decrypts Bob's Normal reply, her next encrypt is Normal too.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice.create_outbound_session("bob", &bob_id, &bob_otk).unwrap();

        let (mt1, ct1) = alice.encrypt("bob", b"Hello").unwrap();
        assert_eq!(mt1, 0, "First message is PreKey");

        let alice_id = alice.identity_key_base64();
        let pt1 = bob.create_inbound_session("alice", &alice_id, &ct1).unwrap();
        assert_eq!(pt1, b"Hello");

        let (mt2, ct2) = bob.encrypt("alice", b"Reply").unwrap();
        assert_eq!(mt2, 1, "Bob's reply is Normal (inbound-derived session)");

        let pt2 = alice.decrypt("bob", mt2, &ct2).unwrap();
        assert_eq!(pt2, b"Reply");

        for i in 0..100 {
            let (mt, _) = alice.encrypt("bob", format!("Chunk {i}").as_bytes()).unwrap();
            assert_eq!(mt, 1, "After receiving reply, outbound session produces Normal");
        }
    }
}
