use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

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
    /// Tracks peers whose session was created via `create_outbound_session`
    /// (from DHT prekey or KeyBundle). Outbound-only sessions produce PreKey
    /// (type 0) for ALL messages until replaced by an inbound session.
    /// Cleared when `create_inbound_session` replaces the session.
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
            // Restored sessions: conservatively assume they could be outbound.
            // On first PreKey received from peer, the session will be replaced.
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
        // A successful decrypt proves the peer replied to our PreKey, so an
        // outbound-only session is now confirmed bidirectional. (SessionAck is the
        // usual confirmation, but any decryptable reply counts.)
        self.outbound_only.remove(peer_id);
        self.session_last_used.insert(peer_id.to_string(), Instant::now());
        Ok(plaintext)
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

    /// Check if we have any session object for a peer (may be unconfirmed
    /// outbound-only, i.e. the peer may not yet hold the matching half).
    pub fn has_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id)
    }

    /// Check if we have a session that is CONFIRMED bidirectional — either
    /// inbound-derived, or outbound that the peer has acknowledged (SessionAck /
    /// a decrypted reply cleared it from `outbound_only`). Only such a session is
    /// proven decryptable by the peer; an outbound-only session is "pending" and
    /// must not be reported to the UI as established.
    pub fn has_confirmed_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id) && !self.outbound_only.contains(peer_id)
    }

    /// Check if we have an outbound-only (unconfirmed) session — we sent a PreKey
    /// but the peer has not yet confirmed by replying. Used to decide whether a
    /// repeated KeyRequest from the peer should tear down and re-handshake.
    pub fn has_unconfirmed_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id) && self.outbound_only.contains(peer_id)
    }

    /// Remove an existing session (e.g., to replace it).
    pub fn remove_session(&mut self, peer_id: &str) {
        self.sessions.remove(peer_id);
        self.outbound_only.remove(peer_id);
        self.session_last_used.remove(peer_id);
    }

    /// Remove sessions not used within the given TTL. Returns the pruned peer IDs
    /// so the caller can clear any related per-peer bookkeeping (e.g. in-flight
    /// key-request timestamps) — otherwise a stale flag could block the next
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

    /// Mark a session as bidirectional (no longer outbound-only).
    /// Called when we receive a SessionAck from the peer, confirming they
    /// created an inbound session and our ratchet has advanced.
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

    // ── iOS disposable-NSE spike (Q1 + Q2) ────────────────────────────────
    // Design under test: when the iOS app is force-killed, the Notification
    // Service Extension must show the decrypted message TEXT, but it must NOT
    // advance the canonical Olm ratchet the app relies on. Plan: the NSE FORKS
    // the session (deserialize a COPY of the pickled session), decrypts on the
    // fork to get the banner text, and DISCARDS the fork — never writing it
    // back. Later, the app re-syncs from the relay/peer and decrypts the SAME
    // message on its untouched canonical session, advancing the ratchet
    // normally, as if the push never happened.
    //
    // This spike proves the two load-bearing assumptions WITHOUT a Mac:
    //   Q1: a Session can be forked from a pickle and decrypted on the copy
    //       without mutating the original (fork = serde round-trip of the pickle).
    //   Q2: after the fork decrypts message N, the ORIGINAL (un-advanced)
    //       session can still decrypt that exact same message N.
    // If Q2 holds, the disposable-NSE design is sound and worth building.

    /// Build an ESTABLISHED, mid-stream bidirectional Alice↔Bob pair so the
    /// ratchet is already advanced (the realistic case — not first contact).
    /// Returns (alice, bob) where bob is the "phone" whose session the NSE forks.
    fn established_pair() -> (OlmManager, OlmManager) {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();

        // Alice → Bob (PreKey) establishes Bob's inbound session.
        let (_t, ct) = alice.encrypt("bob", b"handshake").unwrap();
        let alice_id = alice.identity_key_base64();
        bob.create_inbound_session("alice", &alice_id, &ct).unwrap();

        // Bob → Alice reply confirms Alice's session (now bidirectional).
        let (t2, ct2) = bob.encrypt("alice", b"ack").unwrap();
        alice.decrypt("bob", t2, &ct2).unwrap();

        // Exchange a couple more rounds so the ratchet is genuinely mid-stream.
        let (t3, ct3) = alice.encrypt("bob", b"round-1").unwrap();
        bob.decrypt("alice", t3, &ct3).unwrap();
        let (t4, ct4) = bob.encrypt("alice", b"round-2").unwrap();
        alice.decrypt("bob", t4, &ct4).unwrap();

        (alice, bob)
    }

    #[test]
    fn spike_nse_fork_decrypt_does_not_consume_canonical() {
        let (mut alice, bob) = established_pair();

        // Snapshot Bob's canonical session pickle — this is what's in the DB on
        // the phone when the app is force-killed. The NSE and the app both start
        // from THIS exact byte string.
        let canonical_pickle = bob.session_pickle_json("alice").unwrap().unwrap();
        let account_pickle = bob.account_pickle_json().unwrap();

        // Alice (the friend) sends the message that triggers the push.
        let (mt, ct) = alice.encrypt("bob", b"secret push body").unwrap();

        // ── NSE path: FORK the session, decrypt on the copy, DISCARD it. ──
        // The fork is a fresh OlmManager built from the SAME pickle strings; it
        // owns an independent Session. Decrypting mutates only this throwaway.
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

        // ── App path: load the ORIGINAL canonical pickle (untouched by the NSE)
        // and decrypt the SAME ciphertext. This is what happens when the user
        // opens the app and the relay replays the buffered message. ──
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

        // And the app's now-advanced session keeps working for the NEXT message —
        // proving the fork didn't poison forward decryption.
        let (mt2, ct2) = alice.encrypt("bob", b"follow-up").unwrap();
        let app_plain2 = app.decrypt("alice", mt2, &ct2).unwrap();
        assert_eq!(app_plain2, b"follow-up", "Q2b: ratchet advances normally after");
    }

    #[test]
    fn spike_nse_fork_first_contact_prekey() {
        // The hardest case: a brand-new session (PreKey / first contact). The NSE
        // must decrypt the PreKey on a fork WITHOUT consuming the account's
        // one-time key in a way that stops the app from establishing the session.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice
            .create_outbound_session("bob", &bob_identity, &bob_otk)
            .unwrap();
        let (_mt, ct) = alice.encrypt("bob", b"first hello").unwrap();
        let alice_id = alice.identity_key_base64();

        // Bob's pre-push state: an ACCOUNT with the unused OTK, NO session yet.
        let account_pickle = bob.account_pickle_json().unwrap();

        // ── NSE fork: build a throwaway account, create the inbound session on
        // it, decrypt. Discarded afterward. ──
        let nse_plain = {
            let mut nse_fork =
                OlmManager::from_pickles(&account_pickle, vec![]).unwrap();
            nse_fork
                .create_inbound_session("alice", &alice_id, &ct)
                .unwrap()
        };
        assert_eq!(nse_plain, b"first hello", "Q1: NSE decrypts first-contact PreKey on fork");

        // ── App: from the SAME original account pickle (OTK still unconsumed on
        // it, since the NSE worked on a copy), establish the session for real. ──
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

    #[test]
    fn test_inbound_session_produces_normal_messages() {
        // Verifies the behavior that the PreKey race fix preserves:
        // An inbound-derived session produces Normal (type 1) messages,
        // so file chunks won't be sent as PreKey.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let alice_id = alice.identity_key_base64();
        let bob_id = bob.identity_key_base64();
        let alice_otk = alice.generate_one_time_key();

        // Bob creates outbound session and sends PreKey to Alice.
        bob.create_outbound_session("alice", &alice_id, &alice_otk).unwrap();
        let (msg_type, ct) = bob.encrypt("alice", b"Hello Alice").unwrap();
        assert_eq!(msg_type, 0, "Outbound session produces PreKey");

        // Alice receives Bob's PreKey → creates inbound session.
        let pt = alice.create_inbound_session("bob", &bob_id, &ct).unwrap();
        assert_eq!(pt, b"Hello Alice");
        // Alice now has an inbound-derived session. All encrypts produce Normal (type 1).
        assert!(alice.has_session("bob"));
        for i in 0..100 {
            let (mt, _) = alice.encrypt("bob", format!("Chunk {i}").as_bytes()).unwrap();
            assert_eq!(mt, 1, "Inbound-derived session should always produce Normal (type 1)");
        }
    }

    #[test]
    fn test_confirmed_vs_unconfirmed_session_state() {
        // An outbound session is UNCONFIRMED until the peer replies. has_session is
        // true but has_confirmed_session is false. After decrypting any reply (or a
        // SessionAck via mark_session_bidirectional) it becomes confirmed.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        // Alice creates outbound session → unconfirmed.
        alice.create_outbound_session("bob", &bob_id, &bob_otk).unwrap();
        assert!(alice.has_session("bob"));
        assert!(alice.has_unconfirmed_session("bob"));
        assert!(!alice.has_confirmed_session("bob"), "outbound-only must NOT be confirmed");

        // Alice sends PreKey; Bob builds inbound (immediately confirmed on Bob's side).
        let (_mt, ct) = alice.encrypt("bob", b"Hello").unwrap();
        let alice_id = alice.identity_key_base64();
        bob.create_inbound_session("alice", &alice_id, &ct).unwrap();
        assert!(bob.has_confirmed_session("alice"), "inbound-derived session is confirmed");
        assert!(!bob.has_unconfirmed_session("alice"));

        // Bob replies; Alice decrypts → Alice's session becomes confirmed.
        let (mt2, ct2) = bob.encrypt("alice", b"Reply").unwrap();
        alice.decrypt("bob", mt2, &ct2).unwrap();
        assert!(alice.has_confirmed_session("bob"), "decrypting a reply confirms the session");
        assert!(!alice.has_unconfirmed_session("bob"));
    }

    #[test]
    fn test_mark_bidirectional_confirms_session() {
        // SessionAck path: mark_session_bidirectional flips an unconfirmed outbound
        // session to confirmed without needing a decrypt.
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
        // prune_stale_sessions returns the pruned peer IDs so the caller can clear
        // related bookkeeping. With a zero TTL, an existing session is pruned.
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
        // The full handshake: A creates outbound → sends PreKey → B creates inbound
        // → B replies Normal → A decrypts Normal → A's next encrypt is Normal.
        // This is the mechanism that fixes the PreKey race for file transfer.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        // Alice creates outbound session.
        alice.create_outbound_session("bob", &bob_id, &bob_otk).unwrap();

        // Alice sends PreKey.
        let (mt1, ct1) = alice.encrypt("bob", b"Hello").unwrap();
        assert_eq!(mt1, 0, "First message is PreKey");

        // Bob creates inbound session.
        let alice_id = alice.identity_key_base64();
        let pt1 = bob.create_inbound_session("alice", &alice_id, &ct1).unwrap();
        assert_eq!(pt1, b"Hello");

        // Bob replies with Normal message.
        let (mt2, ct2) = bob.encrypt("alice", b"Reply").unwrap();
        assert_eq!(mt2, 1, "Bob's reply is Normal (inbound-derived session)");

        // Alice decrypts Bob's Normal reply — this advances Alice's ratchet.
        let pt2 = alice.decrypt("bob", mt2, &ct2).unwrap();
        assert_eq!(pt2, b"Reply");

        // NOW: Alice's subsequent encrypts should be Normal (type 1).
        for i in 0..100 {
            let (mt, _) = alice.encrypt("bob", format!("Chunk {i}").as_bytes()).unwrap();
            assert_eq!(mt, 1, "After receiving reply, outbound session produces Normal");
        }
    }
}
