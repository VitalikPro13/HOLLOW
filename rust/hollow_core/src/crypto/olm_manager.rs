use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};
use vodozemac::olm::{
    Account, AccountPickle, DecryptionError, InboundCreationResult, OlmMessage, Session, SessionConfig,
    SessionCreationError,
};
use vodozemac::Curve25519PublicKey;

/// Wraps a vodozemac Olm Account and per-peer Sessions: all crypto state lives here.
pub(crate) struct OlmManager {
    account: Account,
    /// The session each peer's messages are encrypted with.
    sessions: HashMap<String, Session>,
    /// Sessions a peer may still be sending on, newest first, used only to decrypt.
    /// Two devices keying each other at once, or a re-key crossing a message, leave
    /// traffic in flight on the session that lost; dropping it would lose that traffic.
    /// In memory only: a restart falls back to a re-key.
    retired: HashMap<String, VecDeque<Session>>,
    /// When we built the current outbound session, and whether a KeyRequest has
    /// already been answered by re-sending on it.
    outbound_at: HashMap<String, (Instant, bool)>,
    session_last_used: HashMap<String, Instant>,
    /// `(sig_b64, pk_b64)`: our DEVICE's signature over our identity key, attached to
    /// every PreKey we send. Set once by the owner of the device key.
    identity_proof: Option<(String, String)>,
    /// Digests of the ciphertexts each peer's session last decrypted. A spent message
    /// key fails to decrypt again, and that failure tears the session down, so a relay
    /// replaying a genuine frame must be recognised before it is ever tried.
    decrypted: HashMap<String, std::collections::VecDeque<[u8; 16]>>,
    /// Who holds each key [`Self::key_for_requester`] handed out, oldest first. Saved
    /// with the account: a restart that forgot it would orphan every key in it.
    key_slots: VecDeque<KeySlot>,
    /// Per sending device, the newest seal time of a frame we decrypted from it. Saved,
    /// unlike [`Self::decrypted`], so a restart still knows a replay for one.
    read_marks: HashMap<String, i64>,
    /// How far each peer's session has come, saved with its pickle. Kept when the
    /// session goes, so whatever replaces it is stored past every older copy.
    versions: HashMap<String, SessionVersion>,
    /// The store's answer to which sessions another process saved further, taken at
    /// the first change after it arrives.
    awaiting_newer: Option<tokio::sync::oneshot::Receiver<super::store::Newer>>,
}

/// How far a peer's stored session has come, compared `sends` first (AR-30).
///
/// Only the node that encrypts moves `sends` (an encrypt, a new outbound session, a
/// removal); any process that decrypts moves `reads`. A copy from a process that only
/// decrypts (the push fetch, the iOS extension) therefore never outranks a state that
/// sent, and storing max-wins never puts back a sending chain a frame already used.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct SessionVersion {
    pub sends: u64,
    pub reads: u64,
}

impl SessionVersion {
    /// From the two stored columns; a negative column (never written) counts as zero.
    pub(crate) fn from_stored(sends: i64, reads: i64) -> Self {
        Self { sends: sends.max(0) as u64, reads: reads.max(0) as u64 }
    }

    /// The two columns as stored.
    pub(crate) fn stored(self) -> (i64, i64) {
        (self.sends.min(i64::MAX as u64) as i64, self.reads.min(i64::MAX as u64) as i64)
    }
}

/// A peer's session as the store holds it.
#[derive(Clone, Debug)]
pub(crate) struct StoredSession {
    pub peer_id: String,
    pub pickle: String,
    pub version: SessionVersion,
}

/// A requesting device and the one-time key it was handed.
#[derive(Clone, Serialize, Deserialize)]
struct KeySlot {
    requester: String,
    key: String,
}

/// The account row: vodozemac's pickle plus the slot table, which an older build
/// reading the row ignores. The pickle stays a JSON map here because its integer map
/// keys do not survive serde's flatten buffer.
#[derive(Serialize, Deserialize)]
struct StoredAccount {
    #[serde(flatten)]
    account: serde_json::Map<String, serde_json::Value>,
    #[serde(default, skip_serializing_if = "VecDeque::is_empty")]
    key_slots: VecDeque<KeySlot>,
}

/// Ciphertexts remembered per peer; more than the frames a session sees between two
/// deliveries of the same one from a relay's buffer.
const DECRYPTED_REMEMBERED: usize = 512;

/// Retired sessions kept per peer. Glare puts two sessions in play; the rest is room
/// for a re-key that crosses it.
const RETIRED_KEPT: usize = 4;

/// Requesters holding a key from [`OlmManager::key_for_requester`]; far below the
/// 5000 keys vodozemac keeps before it drops the oldest, a carried one included.
const KEY_SLOTS_KEPT: usize = 256;

/// What decrypting one message did to a peer's sessions.
#[derive(Debug)]
pub(crate) struct Opened {
    pub plaintext: Vec<u8>,
    /// A session was built from this PreKey.
    pub created: bool,
    /// The session we encrypt with changed.
    pub switched: bool,
}

/// Why a message did not decrypt.
#[derive(Debug)]
pub(crate) enum OlmFail {
    /// Behind our ratchet: a session we hold spent its message key, or the one-time
    /// key its PreKey names is gone.
    Stale(String),
    /// No session we hold reads it. A replay ends here too once the session has let
    /// the frame's chain go, so this never says the frame is new.
    Unreadable(String),
}

impl std::fmt::Display for OlmFail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OlmFail::Stale(e) => write!(f, "stale, {e}"),
            OlmFail::Unreadable(e) => write!(f, "{e}"),
        }
    }
}

fn spent(e: &DecryptionError) -> bool {
    matches!(e, DecryptionError::MissingMessageKey(_))
}

fn fail(stale: bool, why: String) -> OlmFail {
    if stale { OlmFail::Stale(why) } else { OlmFail::Unreadable(why) }
}

/// Whether `key` has small order, so a key agreement with it is the same for every
/// secret. vodozemac does not check (its 3DH reads no `was_contributory`), so session
/// setup does: one agreement with a fixed scalar comes out all zero exactly then.
fn small_order(key: &Curve25519PublicKey) -> bool {
    let probe = x25519_dalek::StaticSecret::from([0x5a; 32]);
    !probe.diffie_hellman(&x25519_dalek::PublicKey::from(key.to_bytes())).was_contributory()
}

fn ciphertext_digest(ciphertext: &[u8]) -> [u8; 16] {
    use sha2::{Digest, Sha256};
    let full = Sha256::digest(ciphertext);
    let mut d = [0u8; 16];
    d.copy_from_slice(&full[..16]);
    d
}

impl OlmManager {
    /// Create a brand-new Olm account (fresh Curve25519 + Ed25519 keys).
    pub fn new() -> Self {
        OlmManager {
            account: Account::new(),
            sessions: HashMap::new(),
            retired: HashMap::new(),
            outbound_at: HashMap::new(),
            session_last_used: HashMap::new(),
            identity_proof: None,
            decrypted: HashMap::new(),
            key_slots: VecDeque::new(),
            read_marks: HashMap::new(),
            versions: HashMap::new(),
            awaiting_newer: None,
        }
    }

    /// The saved account with its sessions, their versions and read marks, `None`
    /// before the first account. A mark that fails to load only costs a replay its
    /// quiet drop.
    pub fn load(store: &crate::storage::MessageStore) -> Result<Option<Self>, String> {
        let Some(account_json) = store.load_olm_account()? else {
            return Ok(None);
        };
        let rows = store.load_olm_sessions_versioned()?;
        let versions: Vec<(String, SessionVersion)> = rows
            .iter()
            .map(|(peer, _, sends, reads)| (peer.clone(), SessionVersion::from_stored(*sends, *reads)))
            .collect();
        let mut olm = Self::from_pickles(
            &account_json,
            rows.into_iter().map(|(peer, pickle, _, _)| (peer, pickle)).collect(),
        )?;
        olm.versions.extend(versions);
        for (peer, sends, reads) in store.load_olm_session_floors()? {
            let floor = SessionVersion::from_stored(sends, reads);
            let held = olm.versions.entry(peer).or_default();
            *held = (*held).max(floor);
        }
        match store.load_olm_read_marks() {
            Ok(marks) => olm.read_marks = marks.into_iter().collect(),
            Err(e) => hollow_log!("[HOLLOW-CRYPTO] Olm read marks not loaded: {e}"),
        }
        Ok(Some(olm))
    }

    /// Restore from previously pickled account + sessions.
    pub fn from_pickles(
        account_json: &str,
        sessions: Vec<(String, String)>,
    ) -> Result<Self, String> {
        let stored: StoredAccount = serde_json::from_str(account_json)
            .map_err(|e| format!("Failed to deserialize account pickle: {e}"))?;
        let account_pickle: AccountPickle = serde_json::from_value(serde_json::Value::Object(stored.account))
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
            retired: HashMap::new(),
            // A restored unanswered outbound session has no known age, so it counts as
            // stale: the next KeyRequest or KeyBundle replaces it.
            outbound_at: HashMap::new(),
            session_last_used,
            identity_proof: None,
            decrypted: HashMap::new(),
            key_slots: stored.key_slots,
            read_marks: HashMap::new(),
            versions: HashMap::new(),
            awaiting_newer: None,
        })
    }

    /// Whether `peer`'s session already decrypted this exact ciphertext.
    pub(crate) fn already_decrypted(&self, peer: &str, ciphertext: &[u8]) -> bool {
        let digest = ciphertext_digest(ciphertext);
        self.decrypted.get(peer).is_some_and(|seen| seen.contains(&digest))
    }

    /// Remember a ciphertext `peer`'s session decrypted, so a repeat is dropped unread.
    pub(crate) fn note_decrypted(&mut self, peer: &str, ciphertext: &[u8]) {
        let seen = self.decrypted.entry(peer.to_string()).or_default();
        if seen.len() >= DECRYPTED_REMEMBERED {
            seen.pop_front();
        }
        seen.push_back(ciphertext_digest(ciphertext));
    }

    /// Whether we already decrypted a frame from `peer` sealed at or after `sealed_ms`.
    /// Such a frame failing says nothing about the session we hold now: it is a replay,
    /// or rode a chain or session since let go.
    pub(crate) fn read_past(&self, peer: &str, sealed_ms: i64) -> bool {
        self.read_marks.get(peer).is_some_and(|&mark| sealed_ms <= mark)
    }

    /// Note that a frame from `peer` sealed at `sealed_ms` decrypted; true when that
    /// moved its mark, which then needs saving.
    pub(crate) fn note_read(&mut self, peer: &str, sealed_ms: i64) -> bool {
        match self.read_marks.get_mut(peer) {
            Some(mark) if *mark >= sealed_ms => false,
            Some(mark) => {
                *mark = sealed_ms;
                true
            }
            None => {
                self.read_marks.insert(peer.to_string(), sealed_ms);
                true
            }
        }
    }

    /// Our Curve25519 identity key as unpadded base64.
    pub fn identity_key_base64(&self) -> String {
        self.account.curve25519_key().to_base64()
    }

    pub fn set_identity_proof(&mut self, sig_b64: String, pk_b64: String) {
        self.identity_proof = Some((sig_b64, pk_b64));
    }

    /// The proof for [`Self::identity_key_base64`], `None` until it is set.
    pub fn identity_proof(&self) -> Option<&(String, String)> {
        self.identity_proof.as_ref()
    }

    /// Generate a fresh one-time key and return it as unpadded base64.
    /// Marks the key as published so it won't be returned again.
    pub fn generate_one_time_key(&mut self) -> String {
        // A key dropped for room answers no one, so no slot may keep re-sending it.
        for gone in self.account.generate_one_time_keys(1).removed {
            let gone = gone.to_base64();
            self.key_slots.retain(|s| s.key != gone);
        }
        let keys = self.account.one_time_keys();
        let otk = keys
            .values()
            .next()
            .expect("Just generated one key, must exist");
        let otk_b64 = otk.to_base64();
        self.account.mark_keys_as_published();
        otk_b64
    }

    /// The one-time key that answers a `KeyRequest` from `requester`, and whether it
    /// was minted now (the account changed and needs saving).
    ///
    /// A repeat gets the same key: its private half dies with the first session built
    /// on it. A full table drops its oldest slot's key, never a key minted elsewhere.
    pub(crate) fn key_for_requester(&mut self, requester: &str) -> (String, bool) {
        if let Some(slot) = self.key_slots.iter().find(|s| s.requester == requester) {
            return (slot.key.clone(), false);
        }
        if self.key_slots.len() >= KEY_SLOTS_KEPT
            && let Some(oldest) = self.key_slots.pop_front()
        {
            self.drop_one_time_key(&oldest.key);
        }
        let key = self.generate_one_time_key();
        self.key_slots.push_back(KeySlot { requester: requester.to_string(), key: key.clone() });
        (key, true)
    }

    /// A PreKey from `requester` built a session on our key `spent`: the slot holding
    /// it ends, and so does the requester's own, whose unused key goes with it.
    fn release_key_slots(&mut self, requester: &str, spent: &str) {
        let (done, kept): (VecDeque<KeySlot>, VecDeque<KeySlot>) = std::mem::take(&mut self.key_slots)
            .into_iter()
            .partition(|s| s.requester == requester || s.key == spent);
        self.key_slots = kept;
        for slot in done.iter().filter(|s| s.key != spent) {
            self.drop_one_time_key(&slot.key);
        }
    }

    fn drop_one_time_key(&mut self, key_b64: &str) {
        if let Ok(key) = Curve25519PublicKey::from_base64(key_b64) {
            self.account.remove_one_time_key(key);
        }
    }

    /// TEST-ONLY: how many one-time keys the account holds a private half for.
    #[cfg(test)]
    pub(crate) fn stored_one_time_key_count(&self) -> usize {
        self.account.stored_one_time_key_count()
    }

    /// TEST-ONLY: the message key an Olm ciphertext was encrypted under, as its
    /// ratchet key and chain index. Two ciphertexts naming the same pair reused it.
    #[cfg(test)]
    pub(crate) fn message_key_of(message_type: usize, ciphertext: &[u8]) -> Option<(String, u64)> {
        let message = match OlmMessage::from_parts(message_type, ciphertext).ok()? {
            OlmMessage::Normal(m) => m,
            OlmMessage::PreKey(m) => m.message().clone(),
        };
        Some((message.ratchet_key().to_base64(), message.chain_index()))
    }

    /// Create an outbound session using the peer's identity key + one-time key,
    /// retiring any session we held with the peer.
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
        if small_order(&their_identity_key) || small_order(&their_otk) {
            return Err("Refused a small-order key".to_string());
        }
        self.take_newer_if_answered();

        let session = self.account.create_outbound_session(
            SessionConfig::version_2(),
            their_identity_key,
            their_otk,
        );
        self.install(peer_id, session);
        self.outbound_at.insert(peer_id.to_string(), (Instant::now(), false));
        self.stepped(peer_id, true);
        Ok(())
    }

    /// Decrypt a PreKey message: on the session it names if we hold it, else on a new
    /// session built from it.
    ///
    /// A new session replaces ours, except when ours is an unanswered outbound one and
    /// `local_device` is the lower id: both devices keyed each other at once, and both
    /// keep the lower device's session. This is the ONE glare rule; the KeyBundle arm
    /// never defers. The new session is retired instead, so what the peer sent on it
    /// still reads.
    pub(crate) fn open_prekey(
        &mut self,
        peer_id: &str,
        their_identity_key_b64: &str,
        pre_key_message_bytes: &[u8],
        local_device: &str,
    ) -> Result<Opened, OlmFail> {
        self.take_newer_if_answered();
        let opened = self.open_prekey_inner(peer_id, their_identity_key_b64, pre_key_message_bytes, local_device)?;
        self.stepped(peer_id, false);
        Ok(opened)
    }

    fn open_prekey_inner(
        &mut self,
        peer_id: &str,
        their_identity_key_b64: &str,
        pre_key_message_bytes: &[u8],
        local_device: &str,
    ) -> Result<Opened, OlmFail> {
        let message = match OlmMessage::from_parts(0, pre_key_message_bytes)
            .map_err(|e| OlmFail::Unreadable(format!("Failed to decode PreKeyMessage: {e}")))?
        {
            OlmMessage::PreKey(m) => m,
            OlmMessage::Normal(_) => return Err(OlmFail::Unreadable("Expected PreKeyMessage but got Normal".to_string())),
        };
        // We only ever start v2 sessions; the 8-byte MAC of v1 is someone else's choice.
        if message.message().mac_truncated() {
            return Err(OlmFail::Unreadable("PreKey asks for a truncated MAC".to_string()));
        }
        let session_id = message.session_id();

        if let Some(session) = self.sessions.get_mut(peer_id).filter(|s| s.session_id() == session_id) {
            let plaintext = session
                .decrypt(&OlmMessage::PreKey(message))
                .map_err(|e| fail(spent(&e), format!("PreKey decrypt on its session failed: {e}")))?;
            self.touch(peer_id);
            return Ok(Opened { plaintext, created: false, switched: false });
        }

        let retired_at = self
            .retired
            .get(peer_id)
            .and_then(|kept| kept.iter().position(|s| s.session_id() == session_id));
        if let Some(i) = retired_at {
            let kept = self.retired.get_mut(peer_id).expect("position came from this entry");
            let plaintext = kept[i]
                .decrypt(&OlmMessage::PreKey(message))
                .map_err(|e| fail(spent(&e), format!("PreKey decrypt on its retired session failed: {e}")))?;
            // With nothing to encrypt on, the session the peer is writing on is the one.
            let switched = !self.sessions.contains_key(peer_id);
            if switched {
                let session = kept.remove(i).expect("position came from this entry");
                self.install(peer_id, session);
            } else {
                self.touch(peer_id);
            }
            return Ok(Opened { plaintext, created: false, switched });
        }

        // A key handed to one requester opens only that requester's session, so whoever
        // else read the bundle (the relay) cannot spend it under a device of its own.
        let spends = message.one_time_key().to_base64();
        if self.key_slots.iter().any(|s| s.key == spends && s.requester != peer_id) {
            return Err(OlmFail::Unreadable("PreKey spends a one-time key handed to another device".to_string()));
        }
        let their_identity_key = Curve25519PublicKey::from_base64(their_identity_key_b64)
            .map_err(|e| OlmFail::Unreadable(format!("Invalid identity key: {e}")))?;
        if small_order(&their_identity_key) || small_order(&message.base_key()) {
            return Err(OlmFail::Unreadable("PreKey carries a small-order key".to_string()));
        }
        let InboundCreationResult { session, plaintext } = self
            .account
            .create_inbound_session(their_identity_key, &message)
            .map_err(|e| {
                let stale = matches!(e, SessionCreationError::MissingOneTimeKey(_));
                fail(stale, format!("Failed to create inbound session: {e}"))
            })?;
        self.release_key_slots(peer_id, &spends);

        if self.has_unconfirmed_session(peer_id) && local_device < peer_id {
            self.push_retired(peer_id, session);
            self.touch(peer_id);
            return Ok(Opened { plaintext, created: true, switched: false });
        }
        self.install(peer_id, session);
        Ok(Opened { plaintext, created: true, switched: true })
    }

    /// Encrypt a plaintext message for a peer. Returns (message_type, ciphertext_bytes).
    /// message_type: 0 = PreKey, 1 = Normal.
    pub fn encrypt(&mut self, peer_id: &str, plaintext: &[u8]) -> Result<(usize, Vec<u8>), String> {
        self.take_newer_if_answered();
        let session = self
            .sessions
            .get_mut(peer_id)
            .ok_or_else(|| format!("No session for peer {peer_id}"))?;
        let olm_msg = session.encrypt(plaintext);
        let (msg_type, ciphertext) = olm_msg.to_parts();
        self.session_last_used.insert(peer_id.to_string(), Instant::now());
        self.stepped(peer_id, true);
        Ok((msg_type, ciphertext))
    }

    /// Decrypt a message from a peer on our session, else on a retired one. A retired
    /// session that reads it is the one the peer is using, so we encrypt on it again.
    pub fn decrypt(
        &mut self,
        peer_id: &str,
        message_type: usize,
        ciphertext_bytes: &[u8],
    ) -> Result<Opened, OlmFail> {
        self.take_newer_if_answered();
        let opened = self.decrypt_inner(peer_id, message_type, ciphertext_bytes)?;
        self.stepped(peer_id, false);
        Ok(opened)
    }

    fn decrypt_inner(
        &mut self,
        peer_id: &str,
        message_type: usize,
        ciphertext_bytes: &[u8],
    ) -> Result<Opened, OlmFail> {
        let olm_msg = OlmMessage::from_parts(message_type, ciphertext_bytes)
            .map_err(|e| OlmFail::Unreadable(format!("Failed to decode OlmMessage: {e}")))?;
        let mut stale = false;
        let failure = match self.sessions.get_mut(peer_id).map(|s| s.decrypt(&olm_msg)) {
            Some(Ok(plaintext)) => {
                self.touch(peer_id);
                return Ok(Opened { plaintext, created: false, switched: false });
            }
            Some(Err(e)) => {
                stale = spent(&e);
                format!("Decryption failed: {e}")
            }
            None => format!("No session for peer {peer_id}"),
        };
        // A failed decrypt leaves a vodozemac session untouched, so trying each is safe.
        let found = self.retired.get_mut(peer_id).and_then(|kept| {
            kept.iter_mut().enumerate().find_map(|(i, s)| match s.decrypt(&olm_msg) {
                Ok(plaintext) => Some((i, plaintext)),
                Err(e) => {
                    stale |= spent(&e);
                    None
                }
            })
        });
        let Some((i, plaintext)) = found else {
            return Err(fail(stale, failure));
        };
        let session = self
            .retired
            .get_mut(peer_id)
            .and_then(|kept| kept.remove(i))
            .expect("index came from this entry");
        self.install(peer_id, session);
        Ok(Opened { plaintext, created: false, switched: true })
    }

    /// Check if we have any session object for a peer (may be unconfirmed
    /// outbound-only, i.e. the peer may not yet hold the matching half).
    pub fn has_session(&self, peer_id: &str) -> bool {
        self.sessions.contains_key(peer_id)
    }

    /// Whether we have a session CONFIRMED bidirectional: one that has decrypted a
    /// message from the peer, which is only true once the peer holds the other half.
    pub fn has_confirmed_session(&self, peer_id: &str) -> bool {
        self.sessions.get(peer_id).is_some_and(Session::has_received_message)
    }

    /// Whether we have an outbound-only (unconfirmed) session: we sent a PreKey and the
    /// peer has not replied. Decides whether a repeated KeyRequest should re-handshake.
    pub fn has_unconfirmed_session(&self, peer_id: &str) -> bool {
        self.sessions.get(peer_id).is_some_and(|s| !s.has_received_message())
    }

    /// Whether our unanswered outbound session with the peer was built within `window`.
    pub fn has_fresh_outbound(&self, peer_id: &str, window: Duration) -> bool {
        self.has_unconfirmed_session(peer_id)
            && self.outbound_at.get(peer_id).is_some_and(|(built, _)| built.elapsed() < window)
    }

    /// True once per fresh unanswered outbound session. A KeyRequest then most likely
    /// crossed our PreKey, and sending on this session again answers it without
    /// starting a second session; a further one means the PreKey is not landing.
    pub fn claim_prekey_resend(&mut self, peer_id: &str, window: Duration) -> bool {
        if !self.has_fresh_outbound(peer_id, window) {
            return false;
        }
        match self.outbound_at.get_mut(peer_id) {
            Some((_, resent)) if !*resent => {
                *resent = true;
                true
            }
            _ => false,
        }
    }

    /// TEST-ONLY: enumerate the peer DEVICE ids we hold any Olm session for, so
    /// the multi-node harness can snapshot session status across all peers.
    #[cfg(test)]
    pub fn session_peer_ids(&self) -> Vec<String> {
        self.sessions.keys().cloned().collect()
    }

    /// TEST-ONLY: the id of the session we encrypt with for a peer.
    #[cfg(test)]
    pub fn session_id(&self, peer_id: &str) -> Option<String> {
        self.sessions.get(peer_id).map(Session::session_id)
    }

    /// Stop encrypting on the peer's session, keeping it to decrypt what the peer
    /// already sent on it.
    pub fn retire_session(&mut self, peer_id: &str) {
        if let Some(session) = self.sessions.remove(peer_id) {
            self.push_retired(peer_id, session);
        }
        self.outbound_at.remove(peer_id);
    }

    /// Forget every session with a peer, retired ones included.
    pub fn remove_session(&mut self, peer_id: &str) {
        self.sessions.remove(peer_id);
        self.retired.remove(peer_id);
        self.outbound_at.remove(peer_id);
        self.session_last_used.remove(peer_id);
        self.stepped(peer_id, true);
    }

    /// Note one change to `peer_id`'s session; `sent` for a change only the node that
    /// encrypts makes (see [`SessionVersion`]).
    fn stepped(&mut self, peer_id: &str, sent: bool) {
        let version = self.versions.entry(peer_id.to_string()).or_default();
        if sent {
            version.sends += 1;
        } else {
            version.reads += 1;
        }
    }

    /// How far `peer_id`'s session has come in this process.
    pub(crate) fn session_version(&self, peer_id: &str) -> SessionVersion {
        self.versions.get(peer_id).copied().unwrap_or_default()
    }

    /// Every version this process holds, for asking the store what came further.
    pub(crate) fn session_versions(&self) -> HashMap<String, SessionVersion> {
        self.versions.clone()
    }

    /// The pickle of the session we encrypt with for `peer_id`, with its version.
    pub(crate) fn session_save(&self, peer_id: &str) -> Result<Option<(String, SessionVersion)>, String> {
        Ok(self.session_pickle_json(peer_id)?.map(|pickle| (pickle, self.session_version(peer_id))))
    }

    /// Take a stored copy of `peer_id`'s session that came further than ours, as the
    /// push fetch leaves one while this process sits suspended. The copy we held is
    /// retired when it is another session, so what the peer sent on it still reads.
    /// True when the copy was taken.
    pub(crate) fn take_newer(&mut self, stored: &StoredSession) -> Result<bool, String> {
        if stored.version <= self.session_version(&stored.peer_id) {
            return Ok(false);
        }
        let pickle = serde_json::from_str(&stored.pickle)
            .map_err(|e| format!("Failed to deserialize session pickle for {}: {e}", stored.peer_id))?;
        let session = Session::from_pickle(pickle);
        let same = self
            .sessions
            .get(&stored.peer_id)
            .is_some_and(|held| held.session_id() == session.session_id());
        if same {
            self.sessions.insert(stored.peer_id.clone(), session);
            self.touch(&stored.peer_id);
        } else {
            self.install(&stored.peer_id, session);
        }
        self.versions.insert(stored.peer_id.clone(), stored.version);
        Ok(true)
    }

    /// Raise our read marks to what another process saved.
    fn merge_read_marks(&mut self, marks: impl IntoIterator<Item = (String, i64)>) {
        for (peer, sealed_ms) in marks {
            self.note_read(&peer, sealed_ms);
        }
    }

    /// Take the store's answer to which sessions came further than ours at the first
    /// change after it arrives, instead of holding the caller until it does.
    pub(crate) fn expect_newer(&mut self, answer: tokio::sync::oneshot::Receiver<super::store::Newer>) {
        self.awaiting_newer = Some(answer);
    }

    /// Never inlined: a session restored from its pickle is large, and the change entry
    /// points sit inside the swarm's deepest stack frames.
    #[inline(never)]
    fn take_newer_if_answered(&mut self) {
        let Some(answer) = self.awaiting_newer.as_mut() else { return };
        let newer = match answer.try_recv() {
            Ok(newer) => newer,
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => return,
            Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                self.awaiting_newer = None;
                return;
            }
        };
        self.awaiting_newer = None;
        for stored in &newer.sessions {
            match self.take_newer(stored) {
                Ok(true) => hollow_log!(
                    "[HOLLOW-CRYPTO] Took the Olm session with {} another process saved further ({:?})",
                    stored.peer_id, stored.version
                ),
                Ok(false) => {}
                Err(e) => hollow_log!("[HOLLOW-CRYPTO] Stored Olm session with {} not taken: {e}", stored.peer_id),
            }
        }
        self.merge_read_marks(newer.read_marks);
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
            self.remove_session(peer_id);
        }
        stale
    }

    /// Make `session` the one we encrypt with, retiring the current one.
    fn install(&mut self, peer_id: &str, session: Session) {
        if let Some(previous) = self.sessions.insert(peer_id.to_string(), session) {
            self.push_retired(peer_id, previous);
        }
        self.outbound_at.remove(peer_id);
        self.touch(peer_id);
    }

    fn push_retired(&mut self, peer_id: &str, session: Session) {
        let kept = self.retired.entry(peer_id.to_string()).or_default();
        kept.push_front(session);
        kept.truncate(RETIRED_KEPT);
    }

    fn touch(&mut self, peer_id: &str) {
        self.session_last_used.insert(peer_id.to_string(), Instant::now());
    }

    /// Serialize the Account, with who holds which requested key, for DB storage.
    pub fn account_pickle_json(&self) -> Result<String, String> {
        self.stored_account_json(self.key_slots.clone())
    }

    /// The account without who holds which requested key, for a host that keeps no
    /// record of its peers (the media forwarder). A restart then forgets the slots,
    /// which orphans only keys vodozemac drops in time.
    pub(crate) fn identity_pickle_json(&self) -> Result<String, String> {
        self.stored_account_json(VecDeque::new())
    }

    fn stored_account_json(&self, key_slots: VecDeque<KeySlot>) -> Result<String, String> {
        let account = match serde_json::to_value(self.account.pickle()) {
            Ok(serde_json::Value::Object(map)) => map,
            Ok(_) => return Err("Failed to serialize account pickle: not a map".to_string()),
            Err(e) => return Err(format!("Failed to serialize account pickle: {e}")),
        };
        serde_json::to_string(&StoredAccount { account, key_slots })
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

    // Device ids as the tiebreak compares them: "alice" sorts below "bob".
    const ALICE: &str = "alice";
    const BOB: &str = "bob";

    fn open(receiver: &mut OlmManager, from: &str, sender: &OlmManager, msg: Wire, local: &str) -> Opened {
        match msg.0 {
            0 => receiver.open_prekey(from, &sender.identity_key_base64(), &msg.1, local).unwrap(),
            t => receiver.decrypt(from, t, &msg.1).unwrap(),
        }
    }

    /// A message as `encrypt` returns it: (type, ciphertext).
    type Wire = (usize, Vec<u8>);

    /// Alice and Bob each build an outbound session from the other's bundle and
    /// encrypt a message on it before either PreKey lands: the glare the swarm sees
    /// when two devices key each other at once.
    fn glared_pair() -> (OlmManager, OlmManager, Wire, Wire) {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let alice_otk = alice.generate_one_time_key();
        let bob_otk = bob.generate_one_time_key();
        alice.create_outbound_session(BOB, &bob.identity_key_base64(), &bob_otk).unwrap();
        bob.create_outbound_session(ALICE, &alice.identity_key_base64(), &alice_otk).unwrap();
        let from_alice = alice.encrypt(BOB, b"from alice").unwrap();
        let from_bob = bob.encrypt(ALICE, b"from bob").unwrap();
        assert_eq!((from_alice.0, from_bob.0), (0, 0));
        (alice, bob, from_alice, from_bob)
    }

    /// Build an ESTABLISHED, mid-stream bidirectional Alice-Bob pair, the realistic case
    /// rather than first contact. Bob is the "phone" whose session the NSE forks.
    fn established_pair() -> (OlmManager, OlmManager) {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice
            .create_outbound_session(BOB, &bob_identity, &bob_otk)
            .unwrap();

        let handshake = alice.encrypt(BOB, b"handshake").unwrap();
        open(&mut bob, ALICE, &alice, handshake, BOB);

        let ack = bob.encrypt(ALICE, b"ack").unwrap();
        open(&mut alice, BOB, &bob, ack, ALICE);

        let r1 = alice.encrypt(BOB, b"round-1").unwrap();
        open(&mut bob, ALICE, &alice, r1, BOB);
        let r2 = bob.encrypt(ALICE, b"round-2").unwrap();
        open(&mut alice, BOB, &bob, r2, ALICE);

        (alice, bob)
    }

    // When the iOS app is force-killed the Notification Service Extension must show the
    // decrypted TEXT without advancing the canonical Olm ratchet, so it FORKS the session
    // from the pickle, decrypts on the copy and discards it. These tests pin the two
    // load-bearing assumptions: a fork decrypts without mutating the original, and the
    // original can still decrypt that same message afterwards.

    #[test]
    fn spike_nse_fork_decrypt_does_not_consume_canonical() {
        let (mut alice, bob) = established_pair();

        // Bob's canonical pickle, what the phone's DB holds when the app is force-killed.
        // The NSE and the app both start from THIS exact byte string.
        let canonical_pickle = bob.session_pickle_json(ALICE).unwrap().unwrap();
        let account_pickle = bob.account_pickle_json().unwrap();

        // Alice (the friend) sends the message that triggers the push.
        let (mt, ct) = alice.encrypt(BOB, b"secret push body").unwrap();

        // NSE path: the fork is a fresh OlmManager from the SAME pickles, so decrypting
        // mutates only this throwaway.
        let nse_plain = {
            let mut nse_fork = OlmManager::from_pickles(
                &account_pickle,
                vec![(ALICE.to_string(), canonical_pickle.clone())],
            )
            .unwrap();
            nse_fork.decrypt(ALICE, mt, &ct).unwrap().plaintext
            // nse_fork dropped here — never written back to disk.
        };
        assert_eq!(nse_plain, b"secret push body", "Q1: NSE fork decrypts");

        // App path: the ORIGINAL canonical pickle, untouched by the NSE, decrypting the
        // SAME ciphertext when the relay replays the buffered message.
        let mut app = OlmManager::from_pickles(
            &account_pickle,
            vec![(ALICE.to_string(), canonical_pickle.clone())],
        )
        .unwrap();
        let app_plain = app.decrypt(ALICE, mt, &ct).unwrap().plaintext;
        assert_eq!(
            app_plain, b"secret push body",
            "Q2: canonical session still decrypts the same message after the NSE forked"
        );

        // The app's advanced session keeps working for the NEXT message, so the fork did
        // not poison forward decryption.
        let (mt2, ct2) = alice.encrypt(BOB, b"follow-up").unwrap();
        let app_plain2 = app.decrypt(ALICE, mt2, &ct2).unwrap().plaintext;
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
            .create_outbound_session(BOB, &bob_identity, &bob_otk)
            .unwrap();
        let (_mt, ct) = alice.encrypt(BOB, b"first hello").unwrap();
        let alice_id = alice.identity_key_base64();

        let account_pickle = bob.account_pickle_json().unwrap();

        // NSE fork: a throwaway account, inbound session created on it, then discarded.
        let nse_plain = {
            let mut nse_fork =
                OlmManager::from_pickles(&account_pickle, vec![]).unwrap();
            nse_fork.open_prekey(ALICE, &alice_id, &ct, BOB).unwrap().plaintext
        };
        assert_eq!(nse_plain, b"first hello", "Q1: NSE decrypts first-contact PreKey on fork");

        // The app establishes for real from the SAME account pickle, whose OTK is still
        // unconsumed because the NSE worked on a copy.
        let mut app = OlmManager::from_pickles(&account_pickle, vec![]).unwrap();
        let app_plain = app.open_prekey(ALICE, &alice_id, &ct, BOB).unwrap().plaintext;
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
            .create_outbound_session(BOB, &bob_identity, &bob_otk)
            .unwrap();

        let (msg_type, ciphertext) = alice.encrypt(BOB, b"Hello Bob!").unwrap();
        assert_eq!(msg_type, 0, "First message should be PreKey type");

        let alice_identity = alice.identity_key_base64();
        let opened = bob.open_prekey(ALICE, &alice_identity, &ciphertext, BOB).unwrap();
        assert_eq!(opened.plaintext, b"Hello Bob!");
        assert!(opened.created && opened.switched, "first contact builds the session we use");

        let (msg_type2, ciphertext2) = bob.encrypt(ALICE, b"Hi Alice!").unwrap();
        assert_eq!(msg_type2, 1, "Reply should be Normal type");

        let plaintext2 = alice.decrypt(BOB, msg_type2, &ciphertext2).unwrap().plaintext;
        assert_eq!(plaintext2, b"Hi Alice!");
    }

    #[test]
    fn test_pickle_round_trip() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice
            .create_outbound_session(BOB, &bob_identity, &bob_otk)
            .unwrap();

        let account_json = alice.account_pickle_json().unwrap();
        let session_json = alice.session_pickle_json(BOB).unwrap().unwrap();

        let mut alice2 = OlmManager::from_pickles(
            &account_json,
            vec![(BOB.to_string(), session_json)],
        )
        .unwrap();

        assert_eq!(
            alice.identity_key_base64(),
            alice2.identity_key_base64()
        );
        // The pickle keeps whether the session was ever answered.
        assert!(alice2.has_unconfirmed_session(BOB));
        assert!(!alice2.has_fresh_outbound(BOB, Duration::from_secs(60)), "a restored session has no known age");

        let (msg_type, ciphertext) = alice2.encrypt(BOB, b"After restore").unwrap();
        assert_eq!(msg_type, 0); // Still PreKey since Bob hasn't responded

        let alice_identity = alice2.identity_key_base64();
        let plaintext = bob.open_prekey(ALICE, &alice_identity, &ciphertext, BOB).unwrap().plaintext;
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
            .create_outbound_session(BOB, &bob_identity, &bob_otk)
            .unwrap();

        // Both are PreKey (type 0), which is vodozemac's behaviour.
        let (msg_type1, ct1) = alice.encrypt(BOB, b"Message 1").unwrap();
        assert_eq!(msg_type1, 0, "First message should be PreKey");
        let (msg_type2, ct2) = alice.encrypt(BOB, b"Message 2").unwrap();
        assert_eq!(msg_type2, 0, "Second message is also PreKey until peer responds");

        let alice_id = alice.identity_key_base64();
        let first = bob.open_prekey(ALICE, &alice_id, &ct1, BOB).unwrap();
        assert_eq!(first.plaintext, b"Message 1");

        let second = bob.open_prekey(ALICE, &alice_id, &ct2, BOB).unwrap();
        assert_eq!(second.plaintext, b"Message 2");
        assert!(!second.created && !second.switched, "the second PreKey names the session we hold");
    }

    #[test]
    fn glare_settles_on_the_lower_device_session() {
        let (mut alice, mut bob, from_alice, from_bob) = glared_pair();
        // Still on his own session: Alice's PreKey has not reached him yet.
        let bob_late = bob.encrypt(ALICE, b"late from bob").unwrap();

        // Alice is the lower id: she keeps her outbound session and reads Bob's PreKey
        // on the one it builds, which she retires.
        let at_alice = open(&mut alice, BOB, &bob, from_bob, ALICE);
        assert_eq!(at_alice.plaintext, b"from bob");
        assert!(at_alice.created && !at_alice.switched);
        // Bob is the higher id: Alice's session replaces his.
        let at_bob = open(&mut bob, ALICE, &alice, from_alice, BOB);
        assert_eq!(at_bob.plaintext, b"from alice");
        assert!(at_bob.created && at_bob.switched);

        assert_eq!(alice.session_id(BOB), bob.session_id(ALICE), "both sides encrypt on ONE session");

        let late = open(&mut alice, BOB, &bob, bob_late, ALICE);
        assert_eq!(late.plaintext, b"late from bob");
        assert!(!late.switched, "an in-flight PreKey on the losing session never moves us");

        // Traffic both ways, no re-key: this is what failed with MAC errors before.
        let reply = bob.encrypt(ALICE, b"reply").unwrap();
        assert_eq!(reply.0, 1);
        assert_eq!(open(&mut alice, BOB, &bob, reply, ALICE).plaintext, b"reply");
        assert!(alice.has_confirmed_session(BOB) && bob.has_confirmed_session(ALICE));
        for i in 0..5 {
            let a = alice.encrypt(BOB, format!("a{i}").as_bytes()).unwrap();
            let b = bob.encrypt(ALICE, format!("b{i}").as_bytes()).unwrap();
            assert_eq!(open(&mut bob, ALICE, &alice, a, BOB).plaintext, format!("a{i}").as_bytes());
            assert_eq!(open(&mut alice, BOB, &bob, b, ALICE).plaintext, format!("b{i}").as_bytes());
        }
        assert_eq!(alice.session_id(BOB), bob.session_id(ALICE));
    }

    #[test]
    fn crossed_sessions_lose_nothing_and_converge() {
        // The crossing the old code produced: each side ends up ENCRYPTING on the session
        // built from the other's PreKey, because Alice had dropped her outbound (a
        // KeyRequest crossed it) before Bob's PreKey landed.
        let (mut alice, mut bob, from_alice, from_bob) = glared_pair();
        alice.retire_session(BOB);
        open(&mut alice, BOB, &bob, from_bob, ALICE);
        open(&mut bob, ALICE, &alice, from_alice, BOB);
        assert_ne!(alice.session_id(BOB), bob.session_id(ALICE), "precondition: crossed");

        // Both write at once: each message rides the session the other side retired.
        let a1 = alice.encrypt(BOB, b"a1").unwrap();
        let b1 = bob.encrypt(ALICE, b"b1").unwrap();
        assert_eq!(open(&mut bob, ALICE, &alice, a1, BOB).plaintext, b"a1");
        assert_eq!(open(&mut alice, BOB, &bob, b1, ALICE).plaintext, b"b1");

        // One side writing then the other settles them on one session.
        let a2 = alice.encrypt(BOB, b"a2").unwrap();
        assert_eq!(open(&mut bob, ALICE, &alice, a2, BOB).plaintext, b"a2");
        let b2 = bob.encrypt(ALICE, b"b2").unwrap();
        assert_eq!(open(&mut alice, BOB, &bob, b2, ALICE).plaintext, b"b2");
        assert_eq!(alice.session_id(BOB), bob.session_id(ALICE));
    }

    #[test]
    fn retired_session_reads_in_flight_and_takes_over_when_none_is_left() {
        let (mut alice, mut bob) = established_pair();
        let in_flight = bob.encrypt(ALICE, b"sent before the re-key").unwrap();

        // Bob's KeyRequest made Alice retire the session; his message was already out.
        alice.retire_session(BOB);
        assert!(!alice.has_session(BOB));
        let opened = open(&mut alice, BOB, &bob, in_flight, ALICE);
        assert_eq!(opened.plaintext, b"sent before the re-key");
        assert!(opened.switched, "the peer still writes on it, so it is ours again");
        assert!(alice.has_confirmed_session(BOB));
        let back = alice.encrypt(BOB, b"back").unwrap();
        assert_eq!(open(&mut bob, ALICE, &alice, back, BOB).plaintext, b"back");
    }

    #[test]
    fn a_new_prekey_replaces_a_confirmed_session() {
        // The peer building a fresh session means it no longer holds ours.
        let (mut alice, mut bob) = established_pair();
        bob.remove_session(ALICE);
        let otk = alice.generate_one_time_key();
        bob.create_outbound_session(ALICE, &alice.identity_key_base64(), &otk).unwrap();
        let fresh = bob.encrypt(ALICE, b"fresh").unwrap();
        let opened = open(&mut alice, BOB, &bob, fresh, ALICE);
        assert!(opened.created && opened.switched);
        assert_eq!(alice.session_id(BOB), bob.session_id(ALICE));
    }

    #[test]
    fn prekey_resend_is_claimed_once_per_fresh_outbound() {
        let (mut alice, _bob, _, _) = glared_pair();
        let window = Duration::from_secs(10);
        assert!(alice.claim_prekey_resend(BOB, window));
        assert!(!alice.claim_prekey_resend(BOB, window), "a second KeyRequest re-keys instead");
        assert!(!alice.claim_prekey_resend(BOB, Duration::ZERO));

        let (mut alice, _bob, _, _) = glared_pair();
        assert!(!alice.claim_prekey_resend(BOB, Duration::ZERO), "a stale outbound is replaced");
        let (alice, _) = established_pair();
        assert!(!alice.has_fresh_outbound(BOB, window), "an answered session is never resent on");
    }

    #[test]
    fn remove_session_forgets_retired_sessions_too() {
        // Revocation: nothing a revoked device sent may decrypt afterwards.
        let (mut alice, mut bob) = established_pair();
        let in_flight = bob.encrypt(ALICE, b"from a revoked device").unwrap();
        alice.retire_session(BOB);
        alice.remove_session(BOB);
        assert!(alice.decrypt(BOB, in_flight.0, &in_flight.1).is_err());
    }

    #[test]
    fn retired_sessions_are_bounded() {
        let (mut alice, _bob) = established_pair();
        for _ in 0..RETIRED_KEPT + 3 {
            let mut peer = OlmManager::new();
            let otk = peer.generate_one_time_key();
            alice.create_outbound_session(BOB, &peer.identity_key_base64(), &otk).unwrap();
        }
        assert_eq!(alice.retired.get(BOB).map(VecDeque::len), Some(RETIRED_KEPT));
    }

    // AR-19: which frames a session already read decides whether a failure is news.
    // The error tells a spent key from the rest, but cannot alone spot a replay.

    #[test]
    fn a_spent_message_key_is_stale_on_our_session_or_a_retired_one() {
        let (mut alice, mut bob) = established_pair();
        let once = bob.encrypt(ALICE, b"once").unwrap();
        open(&mut alice, BOB, &bob, once.clone(), ALICE);
        let again = alice.decrypt(BOB, once.0, &once.1);
        assert!(matches!(again, Err(OlmFail::Stale(_))), "on the session that read it: {again:?}");
        alice.retire_session(BOB);
        let again = alice.decrypt(BOB, once.0, &once.1);
        assert!(matches!(again, Err(OlmFail::Stale(_))), "on a retired session: {again:?}");
    }

    #[test]
    fn a_replayed_prekey_is_stale_with_or_without_its_session() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let otk = bob.generate_one_time_key();
        alice.create_outbound_session(BOB, &bob.identity_key_base64(), &otk).unwrap();
        let hello = alice.encrypt(BOB, b"hello").unwrap();
        let alice_key = alice.identity_key_base64();
        bob.open_prekey(ALICE, &alice_key, &hello.1, BOB).unwrap();

        let again = bob.open_prekey(ALICE, &alice_key, &hello.1, BOB);
        assert!(matches!(again, Err(OlmFail::Stale(_))), "its session spent the key: {again:?}");
        bob.retire_session(ALICE);
        let again = bob.open_prekey(ALICE, &alice_key, &hello.1, BOB);
        assert!(matches!(again, Err(OlmFail::Stale(_))), "its retired session spent the key: {again:?}");
        bob.remove_session(ALICE);
        let again = bob.open_prekey(ALICE, &alice_key, &hello.1, BOB);
        assert!(matches!(again, Err(OlmFail::Stale(_))), "its one-time key is gone: {again:?}");
    }

    #[test]
    fn a_replay_from_a_chain_the_session_let_go_is_unreadable_not_stale() {
        // Why the seal time decides and not the error: a relay holding a frame long
        // enough no longer gets a spent key back for it.
        let (mut alice, mut bob) = established_pair();
        let first = bob.encrypt(ALICE, b"first").unwrap();
        open(&mut alice, BOB, &bob, first.clone(), ALICE);
        for i in 0..6 {
            let a = alice.encrypt(BOB, format!("a{i}").as_bytes()).unwrap();
            open(&mut bob, ALICE, &alice, a, BOB);
            let b = bob.encrypt(ALICE, format!("b{i}").as_bytes()).unwrap();
            open(&mut alice, BOB, &bob, b, ALICE);
        }
        let again = alice.decrypt(BOB, first.0, &first.1);
        assert!(matches!(again, Err(OlmFail::Unreadable(_))), "{again:?}");
        assert!(matches!(alice.decrypt(ALICE, first.0, &first.1), Err(OlmFail::Unreadable(_))), "no session at all");
    }

    #[test]
    fn a_read_mark_covers_what_was_sealed_up_to_it_and_never_moves_back() {
        let mut olm = OlmManager::new();
        assert!(!olm.read_past(BOB, 0), "nothing read yet");
        assert!(olm.note_read(BOB, 1_000));
        assert!(!olm.note_read(BOB, 900), "an older frame leaves the mark");
        assert!(!olm.note_read(BOB, 1_000), "the same frame again moves nothing");
        assert!(olm.read_past(BOB, 1_000), "the newest frame read is covered");
        assert!(olm.read_past(BOB, 900));
        assert!(!olm.read_past(BOB, 1_001), "a newer frame is news");
        assert!(!olm.read_past(ALICE, 900), "one device's mark covers no other");
    }

    #[test]
    fn read_marks_survive_a_restart_and_never_move_back() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("olm.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
        assert!(OlmManager::load(&store).unwrap().is_none(), "no account yet");
        store.save_olm_account(&OlmManager::new().account_pickle_json().unwrap()).unwrap();
        store.save_olm_read_mark(BOB, 2_000).unwrap();
        store.save_olm_read_mark(BOB, 1_000).unwrap();
        let olm = OlmManager::load(&store).unwrap().expect("the account");
        assert!(olm.read_past(BOB, 2_000), "a restart forgot the mark, or a later, older write moved it back");
        assert!(!olm.read_past(BOB, 2_001));
    }

    #[test]
    fn every_process_that_reads_olm_frames_boots_with_its_read_marks() {
        let fn_body = |file: &str, start: &str| {
            let text = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(file))
                .unwrap()
                .replace("\r\n", "\n");
            let at = text.find(start).unwrap_or_else(|| panic!("{start} not in {file}"));
            text[at..].split("\n}\n").next().unwrap().to_string()
        };
        for (file, start) in [
            ("src/api/network.rs", "pub fn start_node("),
            ("src/api/network.rs", "pub fn start_fetch_node("),
            ("src/push_enrich.rs", "fn fetch_and_decrypt("),
        ] {
            assert!(fn_body(file, start).contains("OlmManager::load("), "{start} boots Olm without its read marks");
        }
    }

    // Section 2 item 9a (A-DM-01): a KeyRequest from a device we never met mints a
    // key, so minting is bounded per requester and in total.

    /// Bob opens Alice's first message on a session she built from `bob_key`.
    fn opens_on(bob: &mut OlmManager, bob_key: &str) -> Result<Opened, String> {
        let mut alice = OlmManager::new();
        alice.create_outbound_session(BOB, &bob.identity_key_base64(), bob_key)?;
        let hello = alice.encrypt(BOB, b"hello").unwrap();
        bob.open_prekey(ALICE, &alice.identity_key_base64(), &hello.1, BOB).map_err(|e| e.to_string())
    }

    #[test]
    fn a_key_request_flood_never_spends_a_carried_key() {
        let mut bob = OlmManager::new();
        // What Bob's friend request carries, minted before any request arrives.
        let carried = bob.generate_one_time_key();
        for i in 0..5_100 {
            bob.key_for_requester(&format!("stranger-{i}"));
        }
        let opened = opens_on(&mut bob, &carried);
        assert!(opened.is_ok(), "a KeyRequest flood spent the carried key: {:?}", opened.err());
        assert!(bob.stored_one_time_key_count() <= KEY_SLOTS_KEPT + 1, "the flood kept {} keys", bob.stored_one_time_key_count());
    }

    #[test]
    fn one_requester_holds_one_key_across_repeats() {
        let mut bob = OlmManager::new();
        let (first, minted) = bob.key_for_requester(ALICE);
        assert!(minted);
        for _ in 0..10 {
            assert_eq!(bob.key_for_requester(ALICE), (first.clone(), false), "a repeat must re-send the requester's key");
        }
        assert_eq!(bob.stored_one_time_key_count(), 1);

        opens_on(&mut bob, &first).expect("the requester's key opens its session");
        let (next, minted) = bob.key_for_requester(ALICE);
        assert!(minted && next != first, "a spent key frees its requester's slot");
        assert_eq!(bob.stored_one_time_key_count(), 1);
    }

    /// C-OLM-03: a key handed to one requester opens only that requester's session, so
    /// whoever else read the bundle (the relay) cannot spend it from a device of its own.
    #[test]
    fn a_requesters_key_opens_only_that_requesters_session() {
        let mut bob = OlmManager::new();
        let (key, _) = bob.key_for_requester(ALICE);
        let mut relay = OlmManager::new();
        relay.create_outbound_session(BOB, &bob.identity_key_base64(), &key).unwrap();
        let forged = relay.encrypt(BOB, b"hello").unwrap();
        assert!(
            bob.open_prekey("relay-device", &relay.identity_key_base64(), &forged.1, BOB).is_err(),
            "another device spent the key handed to Alice",
        );
        opens_on(&mut bob, &key).expect("Alice's own PreKey still opens on her key");
    }

    #[test]
    fn a_requester_that_keys_us_another_way_keeps_no_key_of_ours() {
        let mut bob = OlmManager::new();
        let carried = bob.generate_one_time_key();
        bob.key_for_requester(ALICE);
        opens_on(&mut bob, &carried).expect("the carried key opens");
        assert_eq!(bob.stored_one_time_key_count(), 0, "the requester's unused key outlived its session");
    }

    #[test]
    fn a_slot_never_re_sends_a_key_the_account_dropped() {
        let mut bob = OlmManager::new();
        let (first, _) = bob.key_for_requester(ALICE);
        // Enough keys minted elsewhere that vodozemac drops the oldest, the slot's.
        for _ in 0..5_000 {
            bob.generate_one_time_key();
        }
        let (next, minted) = bob.key_for_requester(ALICE);
        assert!(minted && next != first, "a slot re-sent a key the account no longer holds");
        opens_on(&mut bob, &next).expect("the requester's new key opens");
    }

    #[test]
    fn key_request_slots_survive_a_restart() {
        let mut bob = OlmManager::new();
        let (key, _) = bob.key_for_requester(ALICE);
        let mut bob = OlmManager::from_pickles(&bob.account_pickle_json().unwrap(), vec![]).unwrap();
        assert_eq!(bob.key_for_requester(ALICE), (key, false), "a restart forgot who holds which key");

        for round in 0..3 {
            for i in 0..KEY_SLOTS_KEPT {
                bob.key_for_requester(&format!("stranger-{round}-{i}"));
            }
            bob = OlmManager::from_pickles(&bob.account_pickle_json().unwrap(), vec![]).unwrap();
        }
        assert!(
            bob.stored_one_time_key_count() <= KEY_SLOTS_KEPT,
            "restarts orphaned keys: {} held",
            bob.stored_one_time_key_count()
        );
    }

    #[test]
    fn the_account_row_reads_across_versions() {
        let mut bob = OlmManager::new();
        bob.key_for_requester(ALICE);
        let row = bob.account_pickle_json().unwrap();
        serde_json::from_str::<AccountPickle>(&row).expect("an older build reads the row, slot table ignored");

        let legacy = serde_json::to_string(&bob.account.pickle()).unwrap();
        let restored = OlmManager::from_pickles(&legacy, vec![]).expect("a row an older build wrote");
        assert!(restored.key_slots.is_empty());
        assert_eq!(restored.identity_key_base64(), bob.identity_key_base64());
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

        bob.create_outbound_session(ALICE, &alice_id, &alice_otk).unwrap();
        let (msg_type, ct) = bob.encrypt(ALICE, b"Hello Alice").unwrap();
        assert_eq!(msg_type, 0, "Outbound session produces PreKey");

        let pt = alice.open_prekey(BOB, &bob_id, &ct, ALICE).unwrap().plaintext;
        assert_eq!(pt, b"Hello Alice");
        assert!(alice.has_session(BOB));
        for i in 0..100 {
            let (mt, _) = alice.encrypt(BOB, format!("Chunk {i}").as_bytes()).unwrap();
            assert_eq!(mt, 1, "Inbound-derived session should always produce Normal (type 1)");
        }
    }

    #[test]
    fn test_confirmed_vs_unconfirmed_session_state() {
        // An outbound session is UNCONFIRMED until the peer replies: has_session is true
        // while has_confirmed_session is false until a decrypt.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice.create_outbound_session(BOB, &bob_id, &bob_otk).unwrap();
        assert!(alice.has_session(BOB));
        assert!(alice.has_unconfirmed_session(BOB));
        assert!(!alice.has_confirmed_session(BOB), "outbound-only must NOT be confirmed");

        let (_mt, ct) = alice.encrypt(BOB, b"Hello").unwrap();
        let alice_id = alice.identity_key_base64();
        bob.open_prekey(ALICE, &alice_id, &ct, BOB).unwrap();
        assert!(bob.has_confirmed_session(ALICE), "inbound-derived session is confirmed");
        assert!(!bob.has_unconfirmed_session(ALICE));

        let (mt2, ct2) = bob.encrypt(ALICE, b"Reply").unwrap();
        alice.decrypt(BOB, mt2, &ct2).unwrap();
        assert!(alice.has_confirmed_session(BOB), "decrypting a reply confirms the session");
        assert!(!alice.has_unconfirmed_session(BOB));
    }

    #[test]
    fn test_prune_returns_pruned_peer_ids() {
        // The pruned peer ids come back so the caller can clear related bookkeeping.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice.create_outbound_session(BOB, &bob_id, &bob_otk).unwrap();
        alice.retire_session(BOB);

        let pruned = alice.prune_stale_sessions(Duration::from_secs(0));
        assert_eq!(pruned, vec![BOB.to_string()]);
        assert!(!alice.has_session(BOB));
        assert!(!alice.retired.contains_key(BOB), "pruning a peer drops its retired sessions");
    }

    #[test]
    fn test_outbound_session_upgrades_after_receiving_reply() {
        // The full handshake is what fixes the PreKey race for file transfer: once Alice
        // decrypts Bob's Normal reply, her next encrypt is Normal too.
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();

        let bob_id = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();

        alice.create_outbound_session(BOB, &bob_id, &bob_otk).unwrap();

        let (mt1, ct1) = alice.encrypt(BOB, b"Hello").unwrap();
        assert_eq!(mt1, 0, "First message is PreKey");

        let alice_id = alice.identity_key_base64();
        let pt1 = bob.open_prekey(ALICE, &alice_id, &ct1, BOB).unwrap().plaintext;
        assert_eq!(pt1, b"Hello");

        let (mt2, ct2) = bob.encrypt(ALICE, b"Reply").unwrap();
        assert_eq!(mt2, 1, "Bob's reply is Normal (inbound-derived session)");

        let pt2 = alice.decrypt(BOB, mt2, &ct2).unwrap().plaintext;
        assert_eq!(pt2, b"Reply");

        for i in 0..100 {
            let (mt, _) = alice.encrypt(BOB, format!("Chunk {i}").as_bytes()).unwrap();
            assert_eq!(mt, 1, "After receiving reply, outbound session produces Normal");
        }
    }

    /// Curve25519 points of small order (libsodium's list): any key agreement with one
    /// is the same for everybody.
    const ZERO_POINT: [u8; 32] = [0; 32];
    const ORDER_8_POINT: [u8; 32] = [
        0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a,
        0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00,
    ];

    /// HOL-SEC-161. Hollow only starts v2 sessions, so a PreKey asking for the 8-byte
    /// MAC of v1 comes from someone else's client and opens nothing.
    #[test]
    fn a_prekey_with_a_truncated_mac_never_opens_a_session() {
        let alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let bob_identity = Curve25519PublicKey::from_base64(&bob.identity_key_base64()).unwrap();
        let bob_otk = Curve25519PublicKey::from_base64(&bob.generate_one_time_key()).unwrap();
        let mut v1 = alice.account.create_outbound_session(SessionConfig::version_1(), bob_identity, bob_otk);
        let (kind, bytes) = v1.encrypt(b"short tag").to_parts();
        assert_eq!(kind, 0);

        let opened = bob.open_prekey(ALICE, &alice.identity_key_base64(), &bytes, BOB);
        assert!(opened.is_err(), "a v1 PreKey opened a session");
        assert!(!bob.has_session(ALICE));
    }

    /// HOL-SEC-161. A small-order key would make our share of the 3DH a constant
    /// anyone can compute, so no session is ever built on one.
    #[test]
    fn a_small_order_key_never_starts_a_session() {
        assert!(small_order(&Curve25519PublicKey::from_bytes(ZERO_POINT)));
        assert!(small_order(&Curve25519PublicKey::from_bytes(ORDER_8_POINT)));
        let honest = OlmManager::new();
        assert!(!small_order(&Curve25519PublicKey::from_base64(&honest.identity_key_base64()).unwrap()));

        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let bob_identity = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        assert!(alice.create_outbound_session(BOB, &BASE64.encode(ZERO_POINT), &bob_otk).is_err());
        assert!(alice.create_outbound_session(BOB, &bob_identity, &BASE64.encode(ORDER_8_POINT)).is_err());
        assert!(!alice.has_session(BOB));
        alice.create_outbound_session(BOB, &bob_identity, &bob_otk).unwrap();

        // Inbound: a PreKey whose identity key is small order, named as the sender's.
        let (_, mut bytes) = alice.encrypt(BOB, b"hello").unwrap();
        let real = Curve25519PublicKey::from_base64(&alice.identity_key_base64()).unwrap().to_bytes();
        let at = bytes.windows(32).position(|w| w == real).expect("the PreKey carries the identity key");
        bytes[at..at + 32].copy_from_slice(&ORDER_8_POINT);
        let refused = bob.open_prekey(ALICE, &BASE64.encode(ORDER_8_POINT), &bytes, BOB).expect_err("opened");
        assert!(refused.to_string().contains("small-order"), "refused for another reason: {refused}");
    }

    // AR-30: the version saved with each session decides which copy the store keeps.

    fn v(sends: u64, reads: u64) -> SessionVersion {
        SessionVersion { sends, reads }
    }

    #[test]
    fn every_session_change_moves_its_version_sends_only_for_the_sender() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let otk = bob.generate_one_time_key();
        alice.create_outbound_session(BOB, &bob.identity_key_base64(), &otk).unwrap();
        assert_eq!(alice.session_version(BOB), v(1, 0), "a new outbound session is the sender's step");
        let hello = alice.encrypt(BOB, b"hello").unwrap();
        assert_eq!(alice.session_version(BOB), v(2, 0), "an encrypt");
        open(&mut bob, ALICE, &alice, hello, BOB);
        assert_eq!(bob.session_version(ALICE), v(0, 1), "a PreKey that built the session");
        let reply = bob.encrypt(ALICE, b"reply").unwrap();
        open(&mut alice, BOB, &bob, reply.clone(), ALICE);
        assert_eq!(alice.session_version(BOB), v(2, 1), "a decrypt");
        assert!(alice.decrypt(BOB, reply.0, &reply.1).is_err());
        assert_eq!(alice.session_version(BOB), v(2, 1), "a failed decrypt changes nothing");
        alice.retire_session(BOB);
        assert_eq!(alice.session_version(BOB), v(2, 1), "retiring stores nothing new");
        alice.remove_session(BOB);
        assert_eq!(alice.session_version(BOB), v(3, 1), "a removal outranks every copy stored before it");
        assert!(v(1, 0) > v(0, 99), "sends first");
    }

    #[test]
    fn a_restart_carries_each_version_and_the_floor_a_removal_left() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("olm.db").to_string_lossy().into_owned();
        let store = crate::storage::MessageStore::open(&path, &"ab".repeat(32)).unwrap();
        let (mut alice, _bob) = established_pair();
        alice.encrypt(BOB, b"one more").unwrap();
        store.save_olm_account(&alice.account_pickle_json().unwrap()).unwrap();
        let (pickle, version) = alice.session_save(BOB).unwrap().unwrap();
        let (sends, reads) = version.stored();
        assert!(store.save_olm_session(BOB, &pickle, sends, reads).unwrap());
        store.save_olm_session("gone", &pickle, 5, 5).unwrap();
        store.delete_olm_session("gone").unwrap();

        let back = OlmManager::load(&store).unwrap().unwrap();
        assert_eq!(back.session_version(BOB), version);
        assert_eq!(back.session_version("gone"), v(6, 0), "the floor of a removed session");
        assert!(!back.has_session("gone"));
    }

    /// The iOS extension decrypts on its own copy and saves it while the app sits
    /// suspended; the app takes that copy only when it came further than its own.
    #[test]
    fn a_suspended_process_takes_only_a_copy_that_came_further() {
        let (mut alice, mut app) = established_pair();
        let base = app.session_save(ALICE).unwrap().unwrap();
        let mut nse = OlmManager::from_pickles(&app.account_pickle_json().unwrap(), vec![(ALICE.into(), base.0.clone())]).unwrap();
        nse.versions.insert(ALICE.into(), base.1);

        let pushed = alice.encrypt(BOB, b"read by the extension").unwrap();
        open(&mut nse, ALICE, &alice, pushed, BOB);
        let (pickle, version) = nse.session_save(ALICE).unwrap().unwrap();
        let stored = StoredSession { peer_id: ALICE.into(), pickle, version };
        assert!(app.take_newer(&stored).unwrap());
        assert_eq!(app.session_version(ALICE), version);
        assert!(!app.take_newer(&stored).unwrap(), "the same copy again");
        let behind = StoredSession { peer_id: ALICE.into(), pickle: base.0, version: base.1 };
        assert!(!app.take_newer(&behind).unwrap(), "an older copy");

        let next = alice.encrypt(BOB, b"next").unwrap();
        assert_eq!(open(&mut app, ALICE, &alice, next, BOB).plaintext, b"next");
        let back = app.encrypt(ALICE, b"back").unwrap();
        assert_eq!(open(&mut alice, BOB, &app, back, ALICE).plaintext, b"back");
    }

    /// The store's answer is taken at the first change after it arrives, so a reconnect
    /// never waits on the disk; an answer that comes after a send finds the send ranked
    /// higher and changes nothing.
    #[test]
    fn the_stores_answer_is_taken_at_the_next_change_unless_a_send_came_first() {
        let fork = || {
            let (mut alice, app) = established_pair();
            let base = app.session_save(ALICE).unwrap().unwrap();
            let mut nse = OlmManager::from_pickles(&app.account_pickle_json().unwrap(), vec![(ALICE.into(), base.0)]).unwrap();
            nse.versions.insert(ALICE.into(), base.1);
            let pushed = alice.encrypt(BOB, b"read by the extension").unwrap();
            open(&mut nse, ALICE, &alice, pushed, BOB);
            let (pickle, version) = nse.session_save(ALICE).unwrap().unwrap();
            (alice, app, StoredSession { peer_id: ALICE.into(), pickle, version })
        };
        let answer = |stored: StoredSession| {
            let (tx, rx) = tokio::sync::oneshot::channel();
            tx.send(super::super::store::Newer { sessions: vec![stored], read_marks: vec![(ALICE.into(), 4_242)] }).unwrap();
            rx
        };

        let (mut alice, mut app, stored) = fork();
        app.expect_newer(answer(stored.clone()));
        let sent = app.encrypt(ALICE, b"after the return").unwrap();
        assert_eq!(app.session_version(ALICE), SessionVersion { sends: stored.version.sends + 1, ..stored.version });
        assert!(app.read_past(ALICE, 4_242), "the extension's read marks came along");
        assert_eq!(open(&mut alice, BOB, &app, sent, ALICE).plaintext, b"after the return");

        let (_alice, mut app, stored) = fork();
        app.encrypt(ALICE, b"sent before the answer").unwrap();
        let ours = app.session_version(ALICE);
        app.expect_newer(answer(stored));
        app.encrypt(ALICE, b"next").unwrap();
        assert_eq!(app.session_version(ALICE), SessionVersion { sends: ours.sends + 1, ..ours }, "a send outranks the copy");
    }

    /// Why `sends` comes first: a copy that only read still holds the sending chain as
    /// it stood, so a process restarted on it would encrypt the next message under the
    /// key a frame already used. The send outranks that copy, so the store keeps it.
    #[test]
    fn a_copy_that_only_read_ranks_below_a_send_it_would_reuse() {
        let (mut alice, mut app) = established_pair();
        let a1 = alice.encrypt(BOB, b"a1").unwrap();
        open(&mut app, ALICE, &alice, a1, BOB);
        let b1 = app.encrypt(ALICE, b"b1").unwrap();
        let base = app.session_save(ALICE).unwrap().unwrap();
        let mut nse = OlmManager::from_pickles(&app.account_pickle_json().unwrap(), vec![(ALICE.into(), base.0)]).unwrap();
        nse.versions.insert(ALICE.into(), base.1);
        // Written before Alice read b1, so on a chain the copy already knows.
        for i in 0..2 {
            let m = alice.encrypt(BOB, format!("pushed {i}").as_bytes()).unwrap();
            open(&mut nse, ALICE, &alice, m, BOB);
        }
        let sent = app.encrypt(ALICE, b"b2").unwrap();
        let copy_version = nse.session_version(ALICE);
        assert!(app.session_version(ALICE) > copy_version, "the copy that only read outranked the send");
        let from_copy = nse.encrypt(ALICE, b"what a restart on the copy would send").unwrap();
        assert_eq!(
            OlmManager::message_key_of(sent.0, &sent.1),
            OlmManager::message_key_of(from_copy.0, &from_copy.1),
            "precondition: the copy would reuse the key of the send",
        );
        assert_eq!(open(&mut alice, BOB, &app, b1, ALICE).plaintext, b"b1");
        assert_eq!(open(&mut alice, BOB, &app, sent, ALICE).plaintext, b"b2");
    }
}
