use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Mutex;

use base64::Engine;
use openmls::prelude::*;
use openmls::framing::errors::{MessageDecryptionError, SecretTreeError};
use openmls::prelude::tls_codec::{Serialize as TlsSerialize, Deserialize as TlsDeserialize};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;
use sha2::{Digest, Sha256};

use crate::hollow_log;
use crate::identity::native_identity::NativeKeypair;

/// The ciphersuite used by Hollow MLS groups.
/// X25519 DH, AES-128-GCM encryption, SHA-256 hash, Ed25519 signatures.
const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Late-delivery windows. The relay's per-channel rings replay OLD ciphertext, after
/// the receiver may have processed newer traffic or crossed an epoch bump, and the
/// OpenMLS defaults made such frames PERMANENTLY undecryptable. A bounded window is
/// kept instead: 512 skipped message keys per sender ratchet and receive secrets for
/// the last 3 epochs. A deliberate, bounded relaxation of forward secrecy, since any
/// peer would re-serve the same plaintext through channel sync anyway.
const SENDER_RATCHET_TOLERANCE: u32 = 512;
const SENDER_RATCHET_MAX_FORWARD: u32 = 2000;
const MAX_PAST_EPOCHS: usize = 3;

/// The shared join-config carrying the late-delivery windows. Applied at create, at
/// join, AND to groups loaded from disk, so pre-existing groups upgrade on next start.
fn hollow_join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .max_past_epochs(MAX_PAST_EPOCHS)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(
            SENDER_RATCHET_TOLERANCE,
            SENDER_RATCHET_MAX_FORWARD,
        ))
        .build()
}

/// Group-key for a per-channel MLS subgroup: a restricted channel is encrypted under
/// its own group keyed by this string instead of the server-wide one. The `#`
/// separator never appears in a `server_id` or a `channel_id`, so it round-trips
/// unambiguously and never collides with a server group key.
pub(crate) fn subgroup_id(server_id: &str, channel_id: &str) -> String {
    format!("{server_id}#{channel_id}")
}

/// Inverse of [`subgroup_id`]: a bare server key yields `(server_id, None)`, a
/// subgroup key `"{server}#{channel}"` yields `(server, Some(channel))`. Used by the
/// batch timer and bootstrap handlers to recover the room, CRDT state and wire
/// channel_id uniformly.
pub(crate) fn split_group_key(group_key: &str) -> (String, Option<String>) {
    match group_key.split_once('#') {
        Some((server, channel)) => (server.to_string(), Some(channel.to_string())),
        None => (group_key.to_string(), None),
    }
}

/// Prefix of a bound leaf credential, `hl1:{device}:{master}:{master_signature}`.
const BOUND_CREDENTIAL_PREFIX: &str = "hl1:";

/// Who a bound leaf is: the device whose Ed25519 key is the leaf's signature key,
/// and the master that certified that device.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct LeafIdentity {
    pub device: String,
    pub master: String,
}

/// A leaf as a receiver judges it. `Unbound` carries the raw credential text: every
/// leaf minted before 0.12, and any leaf whose certificate does not hold.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum LeafView {
    Bound(LeafIdentity),
    Unbound(String),
}

impl LeafView {
    /// The id the node routes by: the device of a bound leaf, else the raw credential.
    pub fn id(&self) -> &str {
        match self {
            LeafView::Bound(identity) => &identity.device,
            LeafView::Unbound(raw) => raw,
        }
    }

    pub fn bound(&self) -> Option<&LeafIdentity> {
        match self {
            LeafView::Bound(identity) => Some(identity),
            LeafView::Unbound(_) => None,
        }
    }
}

fn leaf_certificate_payload(master: &str, device: &str) -> String {
    format!("hollow-mls-leaf:{master}:{device}")
}

fn bound_credential_text(device: &NativeKeypair, master: &NativeKeypair) -> String {
    let (device_id, master_id) = (device.peer_id(), master.peer_id());
    let sig = master.sign(leaf_certificate_payload(&master_id, &device_id).as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(sig);
    format!("{BOUND_CREDENTIAL_PREFIX}{device_id}:{master_id}:{sig_b64}")
}

/// Judge a leaf from its credential and signature key alone: bound when the
/// signature key is the device key its id encodes and the master signed that
/// device. A peer id IS its public key, so this needs no lookup.
pub(crate) fn classify_leaf(credential: &[u8], signature_key: &[u8]) -> LeafView {
    let raw = String::from_utf8_lossy(credential).to_string();
    match verify_bound_leaf(&raw, signature_key) {
        Some(identity) => LeafView::Bound(identity),
        None => LeafView::Unbound(raw),
    }
}

fn verify_bound_leaf(raw: &str, signature_key: &[u8]) -> Option<LeafIdentity> {
    use crate::crypto::safety_number::pubkey_from_peer_id;
    let mut parts = raw.strip_prefix(BOUND_CREDENTIAL_PREFIX)?.split(':');
    let (device, master, sig_b64) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    if pubkey_from_peer_id(device)?.as_slice() != signature_key {
        return None;
    }
    let master_key = ed25519_dalek::VerifyingKey::from_bytes(&pubkey_from_peer_id(master)?).ok()?;
    let sig: [u8; 64] = base64::engine::general_purpose::STANDARD
        .decode(sig_b64)
        .ok()?
        .try_into()
        .ok()?;
    master_key
        .verify_strict(
            leaf_certificate_payload(master, device).as_bytes(),
            &ed25519_dalek::Signature::from_bytes(&sig),
        )
        .ok()?;
    Some(LeafIdentity { device: device.to_string(), master: master.to_string() })
}

/// A leaf judged by its certificate, with the key taken from the device id it names.
/// Only for a sender whose leaf is no longer in the current tree: every leaf that
/// entered a tree we hold had its real key checked at that moment.
fn classify_by_certificate(credential: &[u8]) -> LeafView {
    let raw = String::from_utf8_lossy(credential);
    let device_key = raw
        .strip_prefix(BOUND_CREDENTIAL_PREFIX)
        .and_then(|rest| rest.split(':').next())
        .and_then(crate::crypto::safety_number::pubkey_from_peer_id);
    match device_key {
        Some(key) => classify_leaf(credential, &key),
        None => LeafView::Unbound(raw.to_string()),
    }
}

type LeafCache = Mutex<HashMap<(Vec<u8>, Vec<u8>), LeafView>>;
const LEAF_CACHE_CAP: usize = 4096;

fn classify_cached(cache: &LeafCache, credential: &[u8], signature_key: &[u8]) -> LeafView {
    let key = (credential.to_vec(), signature_key.to_vec());
    if let Some(view) = cache.lock().ok().and_then(|map| map.get(&key).cloned()) {
        return view;
    }
    let view = classify_leaf(credential, signature_key);
    if let Ok(mut map) = cache.lock() {
        if map.len() >= LEAF_CACHE_CAP {
            map.clear();
        }
        map.insert(key, view.clone());
    }
    view
}

fn leaf_node_view(cache: &LeafCache, leaf: &LeafNode) -> LeafView {
    classify_cached(cache, leaf.credential().serialized_content(), leaf.signature_key().as_slice())
}

fn member_view(cache: &LeafCache, member: &Member) -> LeafView {
    classify_cached(cache, member.credential.serialized_content(), &member.signature_key)
}

fn own_leaf_bound(group: &MlsGroup, signer_public: &[u8], cache: &LeafCache) -> bool {
    group.own_leaf_node().is_some_and(|leaf| {
        leaf.signature_key().as_slice() == signer_public
            && leaf_node_view(cache, leaf).bound().is_some()
    })
}

/// What a received commit would do, read from the staged commit before any merge.
#[derive(Clone, Debug, Default)]
pub(crate) struct CommitFacts {
    /// `None` when the sender is not a member leaf (an external or new-member commit).
    pub committer: Option<LeafView>,
    /// The committer's replacement leaf, when the commit carries an update path.
    pub path_leaf: Option<LeafView>,
    pub adds: Vec<LeafView>,
    pub removes: Vec<LeafView>,
    /// Any proposal besides the committer's own Add and Remove.
    pub other_proposals: bool,
    pub removes_us: bool,
}

/// What a received Welcome would install, read before it replaces anything.
#[derive(Clone, Debug)]
pub(crate) struct WelcomeFacts {
    pub group_id_matches: bool,
    pub sender: LeafView,
    pub leaves: Vec<LeafView>,
    /// Our own new leaf is bound and is this device.
    pub own_leaf_is_ours: bool,
    /// Accepting it would replace a group we hold.
    pub replaces: bool,
}

/// A receiver's ruling on a commit or Welcome. `Hold` keeps it for a retry, for rules
/// our CRDT view may simply not have caught up with yet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    Accept,
    Hold(String),
    Refuse(String),
}

/// How long a held commit or Welcome waits for our state to catch up.
pub(crate) const HELD_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(60);

/// Kept as the staged object: commits travel encrypted, so processing one spends its
/// key and the same bytes never process twice.
struct HeldCommit {
    staged: StagedCommit,
    facts: CommitFacts,
    epoch: u64,
    since: std::time::Instant,
}

/// Kept staged for the same reason: staging a Welcome consumes our KeyPackage.
struct HeldWelcome {
    staged: StagedWelcome,
    facts: WelcomeFacts,
    since: std::time::Instant,
}

/// A decrypted application message, or why there is nothing to act on.
pub(crate) enum Decrypted {
    Fresh { plaintext: Vec<u8>, sender: LeafIdentity },
    /// A generation already consumed: a replay, not a sign of a stale group.
    Replay,
    /// Sent by a leaf that proves no identity; its content is ignored.
    UnboundSender(String),
}

/// Why a frame did not decrypt. `Garbage` says nothing about our group state and is
/// ignored; `Stale` may mean we are behind, which only ever earns an epoch probe.
#[derive(Debug)]
pub(crate) enum DecryptFail {
    Garbage(String),
    Stale(String),
}

impl std::fmt::Display for DecryptFail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecryptFail::Garbage(e) => write!(f, "garbage frame: {e}"),
            DecryptFail::Stale(e) => write!(f, "{e}"),
        }
    }
}

/// One commit that removes and adds leaves, from [`MlsManager::commit_membership`].
pub(crate) struct MembershipCommit {
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub added: Vec<String>,
    pub removed: Vec<String>,
}

/// Wraps OpenMLS for Hollow's channel group encryption: one MLS group per server,
/// while DMs stay on Olm.
pub(crate) struct MlsManager {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential_with_key: CredentialWithKey,
    /// The pre-0.12 identity (a random key and a bare id), kept only to rebind our
    /// own leaf in groups formed before leaves were bound. Persisted in place of the
    /// device identity until no group needs it.
    legacy: Option<(SignatureKeyPair, CredentialWithKey)>,
    /// server_id → MlsGroup
    groups: HashMap<String, MlsGroup>,
    /// RAM-only ring of recent commit frames per group, `(post_merge_epoch, base64)`,
    /// ascending and capped. Serves `MlsCommitCatchup` to members that missed the
    /// unbuffered room broadcast. Deliberately NOT persisted: after a restart the
    /// responder simply cannot bridge and falls back to a repair.
    commit_cache: HashMap<String, VecDeque<(u64, String)>>,
    held_commits: HashMap<String, HeldCommit>,
    held_welcomes: HashMap<String, HeldWelcome>,
    /// A meeting's only committer, by master: the host that admitted us, or ourselves
    /// when we host it. RAM-only, like meetings.
    pinned_committers: HashMap<String, String>,
    /// Per group, the master we last answered with a KeyPackage and when. Outlives the
    /// group on purpose: the repair that evicts us arrives before its Welcome.
    answered_key_requests: HashMap<String, (String, std::time::Instant)>,
    leaf_cache: LeafCache,
}

/// Commits kept per group for catch-up replay. Deeper staleness than this is
/// rare (it needs that many missed broadcasts) and falls back to a repair.
const COMMIT_CACHE_CAP: usize = 8;

fn device_identity(
    device: &NativeKeypair,
    master: &NativeKeypair,
) -> (SignatureKeyPair, CredentialWithKey) {
    let secret = zeroize::Zeroizing::new(device.secret_key_bytes());
    let signer = SignatureKeyPair::from_raw(
        CIPHERSUITE.signature_algorithm(),
        secret.to_vec(),
        device.public_key_bytes().to_vec(),
    );
    let credential = BasicCredential::new(bound_credential_text(device, master).into_bytes());
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: signer.to_public_vec().into(),
    };
    (signer, credential_with_key)
}

impl MlsManager {
    fn with_identity(
        provider: OpenMlsRustCrypto,
        signer: SignatureKeyPair,
        credential_with_key: CredentialWithKey,
        groups: HashMap<String, MlsGroup>,
    ) -> Self {
        MlsManager {
            provider,
            signer,
            credential_with_key,
            legacy: None,
            groups,
            commit_cache: HashMap::new(),
            held_commits: HashMap::new(),
            held_welcomes: HashMap::new(),
            pinned_committers: HashMap::new(),
            answered_key_requests: HashMap::new(),
            leaf_cache: Mutex::new(HashMap::new()),
        }
    }

    /// A fresh MLS identity for this device: the device key signs, and the leaf
    /// credential carries the master's certificate for the device.
    pub fn new(device: &NativeKeypair, master: &NativeKeypair) -> Result<Self, String> {
        let (signer, credential_with_key) = device_identity(device, master);
        Ok(Self::with_identity(
            OpenMlsRustCrypto::default(),
            signer,
            credential_with_key,
            HashMap::new(),
        ))
    }

    /// Restore MlsManager from persisted state: serde JSON blobs for the signer and
    /// credential, and the serialized MemoryStorage map for `storage_blob`. A node
    /// then calls [`Self::adopt_device_identity`]; the fetch paths only decrypt.
    pub fn from_persisted(
        signer_bytes: &[u8],
        credential_bytes: &[u8],
        storage_blob: Option<&[u8]>,
        server_ids: &[String],
    ) -> Result<Self, String> {
        let provider = OpenMlsRustCrypto::default();

        if let Some(blob) = storage_blob {
            let mut cursor = std::io::Cursor::new(blob);
            let count = read_u64(&mut cursor)?;
            let mut values = provider.storage().values.write()
                .map_err(|e| format!("Lock poisoned: {e}"))?;
            for _ in 0..count {
                let k_len = read_u64(&mut cursor)?;
                let v_len = read_u64(&mut cursor)?;
                let k = read_bytes(&mut cursor, k_len as usize)?;
                let v = read_bytes(&mut cursor, v_len as usize)?;
                values.insert(k, v);
            }
            drop(values);
        }

        let signer: SignatureKeyPair = serde_json::from_slice(signer_bytes)
            .map_err(|e| format!("Failed to deserialize MLS signer: {e}"))?;
        let credential_with_key: CredentialWithKey = serde_json::from_slice(credential_bytes)
            .map_err(|e| format!("Failed to deserialize MLS credential: {e}"))?;

        let mut groups = HashMap::new();
        for server_id in server_ids {
            let group_id = GroupId::from_slice(server_id.as_bytes());
            match MlsGroup::load(provider.storage(), &group_id) {
                Ok(Some(mut group)) => {
                    // Upgrade pre-existing groups to the late-delivery config; idempotent, and
                    // without it only NEW groups would tolerate relay ring replay.
                    if let Err(e) = group.set_configuration(provider.storage(), &hollow_join_config()) {
                        hollow_log!("[HOLLOW-MLS] set_configuration failed for {server_id}: {e:?}");
                    }
                    hollow_log!("[HOLLOW-MLS] Loaded MLS group for server {server_id}");
                    groups.insert(server_id.clone(), group);
                }
                Ok(None) => {
                    // No MLS group for this server yet (pre-MLS server).
                }
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Failed to load MLS group for {server_id}: {e:?}");
                }
            }
        }

        Ok(Self::with_identity(provider, signer, credential_with_key, groups))
    }

    /// Make this device's key our signer and our credential the bound one. A restored
    /// signer that is a different key becomes the legacy signer, kept only to rebind
    /// our leaf in place in groups formed before leaves were bound.
    pub fn adopt_device_identity(&mut self, device: &NativeKeypair, master: &NativeKeypair) {
        let (signer, credential_with_key) = device_identity(device, master);
        if self.signer.public() == signer.public() {
            self.credential_with_key = credential_with_key;
            return;
        }
        let old_signer = std::mem::replace(&mut self.signer, signer);
        let old_credential = std::mem::replace(&mut self.credential_with_key, credential_with_key);
        self.legacy = Some((old_signer, old_credential));
    }

    /// The id baked into this manager's own credential: the device for a bound one,
    /// the raw id for a legacy one. Startup reads it on the RESTORED identity to spot
    /// one inherited from another device (a sibling that imported the source DB).
    pub fn credential_identity(&self) -> String {
        classify_leaf(
            self.credential_with_key.credential.serialized_content(),
            self.signer.public(),
        )
        .id()
        .to_string()
    }

    /// The signer to persist: the legacy one while a group still needs it, so a
    /// restart can finish the rebind; the device key otherwise.
    pub fn signer_bytes(&self) -> Result<Vec<u8>, String> {
        let signer = self.legacy.as_ref().map_or(&self.signer, |(s, _)| s);
        serde_json::to_vec(signer)
            .map_err(|e| format!("Failed to serialize MLS signer: {e}"))
    }

    /// The credential persisted alongside [`Self::signer_bytes`].
    pub fn credential_bytes(&self) -> Result<Vec<u8>, String> {
        let credential = self.legacy.as_ref().map_or(&self.credential_with_key, |(_, c)| c);
        serde_json::to_vec(credential)
            .map_err(|e| format!("Failed to serialize MLS credential: {e}"))
    }

    /// Serialize the provider's MemoryStorage to a blob for DB persistence.
    pub fn serialize_storage(&self) -> Result<Vec<u8>, String> {
        let values = self.provider.storage().values.read()
            .map_err(|e| format!("Lock poisoned: {e}"))?;
        let mut buf = Vec::new();
        let count = values.len() as u64;
        buf.extend_from_slice(&count.to_be_bytes());
        for (k, v) in values.iter() {
            buf.extend_from_slice(&(k.len() as u64).to_be_bytes());
            buf.extend_from_slice(&(v.len() as u64).to_be_bytes());
            buf.extend_from_slice(k);
            buf.extend_from_slice(v);
        }
        Ok(buf)
    }

    /// Generate a KeyPackage for distribution to the server owner.
    pub fn generate_key_package(&self) -> Result<Vec<u8>, String> {
        let kp = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential_with_key.clone(),
            )
            .map_err(|e| format!("Failed to build KeyPackage: {e:?}"))?;

        TlsSerialize::tls_serialize_detached(kp.key_package())
            .map_err(|e| format!("Failed to serialize KeyPackage: {e:?}"))
    }

    /// Drop a KeyPackage we minted but will never be Welcomed for.
    ///
    /// `KeyPackage::builder().build()` writes the whole bundle, public package plus both
    /// private halves, into the provider store, and `join_from_welcome` normally consumes
    /// it. A mint that never becomes a Welcome would otherwise leave that private
    /// material in the persisted blob for the life of the install. One delete is the whole
    /// delete, which is why OpenMLS's own Welcome path calls exactly this. The caller
    /// persists afterwards.
    pub fn discard_key_package(&self, kp_bytes: &[u8]) -> Result<(), String> {
        use openmls_traits::storage::StorageProvider;
        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(kp_bytes)
            .map_err(|e| format!("Failed to deserialize KeyPackage: {e:?}"))?;
        let kp = kp_in
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|e| format!("KeyPackage validation failed: {e:?}"))?;
        let hash_ref = kp
            .hash_ref(self.provider.crypto())
            .map_err(|e| format!("Failed to hash KeyPackage: {e:?}"))?;
        self.provider
            .storage()
            .delete_key_package(&hash_ref)
            .map_err(|e| format!("Failed to delete KeyPackage: {e:?}"))
    }

    /// The leaf a serialised KeyPackage asks to be added as. A CLAIM until the package
    /// is validated, so the caller must also require it to be bound and to name the
    /// device the frame came from; [`Self::commit_membership`] validates it in full.
    pub fn key_package_identity(kp_bytes: &[u8]) -> Result<LeafView, String> {
        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(kp_bytes)
            .map_err(|e| format!("Failed to deserialize KeyPackage: {e:?}"))?;
        let claimed = kp_in.unverified_credential();
        Ok(classify_leaf(
            claimed.credential.serialized_content(),
            claimed.signature_key.as_slice(),
        ))
    }

    /// Create a new MLS group for a server (called by server owner).
    pub fn create_group(&mut self, server_id: &str) -> Result<(), String> {
        let group_id = GroupId::from_slice(server_id.as_bytes());
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .max_past_epochs(MAX_PAST_EPOCHS)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                SENDER_RATCHET_TOLERANCE,
                SENDER_RATCHET_MAX_FORWARD,
            ))
            .build();

        let group = MlsGroup::new_with_group_id(
            &self.provider,
            &self.signer,
            &config,
            group_id,
            self.credential_with_key.clone(),
        )
        .map_err(|e| format!("Failed to create MLS group: {e:?}"))?;

        hollow_log!("[HOLLOW-MLS] Created MLS group for server {server_id}");
        self.groups.insert(server_id.to_string(), group);
        Ok(())
    }

    /// One commit that removes the leaves named in `removals` and adds `adds`, each
    /// `(device_id, KeyPackage)`. A device may be removed and re-added in the same
    /// commit, which is how a leaf is repaired. Our own leaf is never removed, and an
    /// add is skipped unless its KeyPackage is valid, bound and names that device.
    /// Caller merges with `merge_pending_commit` after broadcasting.
    pub fn commit_membership(
        &mut self,
        group_key: &str,
        removals: &[String],
        adds: &[(String, Vec<u8>)],
    ) -> Result<MembershipCommit, String> {
        let group = self.groups.get_mut(group_key)
            .ok_or_else(|| format!("No MLS group for server {group_key}"))?;
        if !own_leaf_bound(group, self.signer.public(), &self.leaf_cache) {
            return Err(format!("our leaf in {group_key} is not bound yet"));
        }
        let own_index = group.own_leaf_index();
        let leaves: Vec<(LeafNodeIndex, String)> = group
            .members()
            .map(|m| (m.index, member_view(&self.leaf_cache, &m).id().to_string()))
            .collect();

        let mut remove_indices = Vec::new();
        let mut removed = Vec::new();
        for id in removals {
            for (index, leaf_id) in &leaves {
                if leaf_id == id && *index != own_index && !remove_indices.contains(index) {
                    remove_indices.push(*index);
                    removed.push(id.clone());
                }
            }
        }
        let staying: HashSet<&str> = leaves
            .iter()
            .filter(|(index, _)| !remove_indices.contains(index))
            .map(|(_, id)| id.as_str())
            .collect();

        let mut key_packages = Vec::new();
        let mut added: Vec<String> = Vec::new();
        for (device_id, kp_bytes) in adds {
            if staying.contains(device_id.as_str()) || added.contains(device_id) {
                hollow_log!("[HOLLOW-MLS] Skipping {device_id}: already has a leaf in {group_key}");
                continue;
            }
            let kp_in: KeyPackageIn = match TlsDeserialize::tls_deserialize_exact(kp_bytes) {
                Ok(kp_in) => kp_in,
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Failed to deserialize KeyPackage from {device_id}: {e:?}");
                    continue;
                }
            };
            let kp = match kp_in.validate(self.provider.crypto(), ProtocolVersion::Mls10) {
                Ok(kp) => kp,
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] KeyPackage validation failed for {device_id}: {e:?}");
                    continue;
                }
            };
            let leaf = leaf_node_view(&self.leaf_cache, kp.leaf_node());
            if leaf.bound().map(|b| b.device.as_str()) != Some(device_id.as_str()) {
                hollow_log!("[HOLLOW-SECURITY] Skipping KeyPackage queued for {device_id}: its leaf is {leaf:?}");
                continue;
            }
            key_packages.push(kp);
            added.push(device_id.clone());
        }

        if remove_indices.is_empty() && key_packages.is_empty() {
            return Err("No valid membership change to commit".to_string());
        }

        let bundle = group
            .commit_builder()
            .propose_removals(remove_indices)
            .propose_adds(key_packages)
            .load_psks(self.provider.storage())
            .map_err(|e| format!("Failed to load PSKs: {e:?}"))?
            .build(self.provider.rand(), self.provider.crypto(), &self.signer, |_| true)
            .map_err(|e| format!("Failed to build membership commit: {e:?}"))?
            .stage_commit(&self.provider)
            .map_err(|e| format!("Failed to stage membership commit: {e:?}"))?;

        let commit = TlsSerialize::tls_serialize_detached(bundle.commit())
            .map_err(|e| format!("Failed to serialize commit: {e:?}"))?;
        let welcome = bundle
            .to_welcome_msg()
            .map(|w| TlsSerialize::tls_serialize_detached(&w))
            .transpose()
            .map_err(|e| format!("Failed to serialize welcome: {e:?}"))?;

        hollow_log!(
            "[HOLLOW-MLS] Membership commit for {group_key}: removed {removed:?}, added {added:?}"
        );
        Ok(MembershipCommit { commit, welcome, added, removed })
    }

    /// Add one member. Returns `(commit, welcome)`; the caller merges after broadcasting.
    pub fn add_member(
        &mut self,
        server_id: &str,
        key_package_bytes: &[u8],
    ) -> Result<(Vec<u8>, Vec<u8>), String> {
        let device = Self::key_package_identity(key_package_bytes)?
            .bound()
            .map(|b| b.device.clone())
            .ok_or("KeyPackage leaf is not bound")?;
        let done = self.commit_membership(server_id, &[], &[(device, key_package_bytes.to_vec())])?;
        let welcome = done.welcome.ok_or("add produced no Welcome")?;
        Ok((done.commit, welcome))
    }

    /// Add several members in one commit. Returns `(commit, welcome, added_ids)`.
    #[cfg(test)]
    #[allow(clippy::type_complexity)]
    pub fn add_members_batch(
        &mut self,
        server_id: &str,
        key_packages: &[(String, Vec<u8>)],
    ) -> Result<(Vec<u8>, Vec<u8>, Vec<String>), String> {
        let done = self.commit_membership(server_id, &[], key_packages)?;
        let welcome = done.welcome.ok_or("No valid new members to add")?;
        Ok((done.commit, welcome, done.added))
    }

    /// Merge the pending commit after add/remove.
    /// Must be called by the committer after broadcasting the commit.
    pub fn merge_pending_commit(&mut self, server_id: &str) -> Result<(), String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        group
            .merge_pending_commit(&self.provider)
            .map_err(|e| format!("Failed to merge pending commit: {e:?}"))?;

        hollow_log!("[HOLLOW-MLS] Merged pending commit for server {server_id}, epoch: {:?}", group.epoch());
        Ok(())
    }

    /// Remove the ONE leaf whose id is `peer_id`, for callers that target a single device.
    #[cfg(test)]
    pub fn remove_member(
        &mut self,
        server_id: &str,
        peer_id: &str,
    ) -> Result<Vec<u8>, String> {
        self.remove_identity_leaves(server_id, &[peer_id])
    }

    /// Remove EVERY leaf whose id is in `ids`, or whose proven master is, in a single
    /// commit: the multi-device removal primitive, typically given `{master} +
    /// devices_for(master)`. A bound leaf matches by its certified master even when
    /// our device lists do not know that device. Ids with no leaf are skipped, so a
    /// re-issued kick is harmless; an error only if nothing matched.
    pub fn remove_identity_leaves(
        &mut self,
        server_id: &str,
        credential_ids: &[&str],
    ) -> Result<Vec<u8>, String> {
        if credential_ids.is_empty() {
            return Err("No credential ids to remove".to_string());
        }
        let wanted: HashSet<&str> = credential_ids.iter().copied().collect();
        let matching: Vec<String> = self
            .group_leaves(server_id)
            .into_iter()
            .filter(|leaf| {
                wanted.contains(leaf.id())
                    || leaf.bound().is_some_and(|b| wanted.contains(b.master.as_str()))
            })
            .map(|leaf| leaf.id().to_string())
            .collect();
        if matching.is_empty() {
            return Err(format!(
                "No matching leaves for {} credential id(s) in server {server_id}",
                credential_ids.len()
            ));
        }
        let done = self.commit_membership(server_id, &matching, &[])?;
        if done.removed.is_empty() {
            return Err(format!("Nothing removable for {matching:?} in {server_id}"));
        }
        Ok(done.commit)
    }

    /// Groups whose own leaf still predates binding (active groups only).
    pub fn unbound_own_groups(&self) -> Vec<String> {
        self.groups
            .iter()
            .filter(|(_, g)| g.is_active() && !own_leaf_bound(g, self.signer.public(), &self.leaf_cache))
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// Whether our own leaf in the group is bound, so we may encrypt and commit there.
    #[cfg(test)]
    pub fn own_leaf_bound(&self, group_key: &str) -> bool {
        self.groups
            .get(group_key)
            .is_some_and(|g| own_leaf_bound(g, self.signer.public(), &self.leaf_cache))
    }

    /// Whether our unbound leaf in the group is the legacy one we can rebind in place.
    pub fn can_rebind_in_place(&self, group_key: &str) -> bool {
        let Some((legacy, _)) = self.legacy.as_ref() else { return false };
        self.groups
            .get(group_key)
            .and_then(|g| g.own_leaf_node())
            .is_some_and(|leaf| leaf.signature_key().as_slice() == legacy.public())
    }

    /// Rebind our own legacy leaf in place: one commit replacing its key with the
    /// device key and its credential with the bound one, signed by the legacy key.
    /// Only the group authority does this (anyone else asks it for a repair), so
    /// commits stay linear. The caller broadcasts, then merges.
    pub fn rebind_own_leaf(&mut self, group_key: &str) -> Result<Vec<u8>, String> {
        let (legacy_signer, _) = self.legacy.as_ref().ok_or("no legacy signer to rebind with")?;
        let group = self.groups.get_mut(group_key)
            .ok_or_else(|| format!("No MLS group for server {group_key}"))?;
        let own_key = group.own_leaf_node().map(|l| l.signature_key().as_slice().to_vec());
        if own_key.as_deref() != Some(legacy_signer.public()) {
            return Err(format!("our leaf in {group_key} is not the legacy leaf"));
        }
        let bundle = group
            .self_update_with_new_signer(
                &self.provider,
                legacy_signer,
                NewSignerBundle {
                    signer: &self.signer,
                    credential_with_key: self.credential_with_key.clone(),
                },
                LeafNodeParameters::default(),
            )
            .map_err(|e| format!("Failed to rebind our leaf: {e:?}"))?;
        TlsSerialize::tls_serialize_detached(bundle.commit())
            .map_err(|e| format!("Failed to serialize rebind commit: {e:?}"))
    }

    /// Forget the legacy signer once no group's own leaf uses it. Returns whether it
    /// was dropped, so the caller persists.
    pub fn drop_unused_legacy(&mut self) -> bool {
        let Some((legacy, _)) = self.legacy.as_ref() else { return false };
        let in_use = self.groups.values().any(|g| {
            g.own_leaf_node()
                .is_some_and(|l| l.signature_key().as_slice() == legacy.public())
        });
        if in_use {
            return false;
        }
        self.legacy = None;
        true
    }

    fn welcome_facts(&self, group_key: &str, staged: &StagedWelcome) -> WelcomeFacts {
        let sender = staged
            .welcome_sender()
            .map(|leaf| leaf_node_view(&self.leaf_cache, leaf))
            .unwrap_or_else(|_| LeafView::Unbound(String::new()));
        let own_leaf_is_ours = staged.own_leaf_node().is_some_and(|leaf| {
            leaf.signature_key().as_slice() == self.signer.public()
                && leaf_node_view(&self.leaf_cache, leaf).bound().is_some()
        });
        WelcomeFacts {
            group_id_matches: staged.group_context().group_id().as_slice() == group_key.as_bytes(),
            sender,
            leaves: staged.members().map(|m| member_view(&self.leaf_cache, &m)).collect(),
            own_leaf_is_ours,
            replaces: self.groups.contains_key(group_key),
        }
    }

    fn install_welcome(&mut self, group_key: &str, staged: StagedWelcome) -> Result<(), String> {
        if let Some(mut old) = self.groups.remove(group_key) {
            let _ = old.delete(self.provider.storage());
        }
        self.commit_cache.remove(group_key);
        self.held_commits.remove(group_key);
        let group = staged
            .into_group(&self.provider)
            .map_err(|e| format!("Failed to create group from Welcome: {e:?}"))?;
        hollow_log!("[HOLLOW-MLS] Joined MLS group for server {group_key}, epoch: {:?}", group.epoch());
        self.groups.insert(group_key.to_string(), group);
        Ok(())
    }

    /// Stage a Welcome, let `judge` rule on what it would install, and only then
    /// install it, replacing any group we hold under that key. A held Welcome waits
    /// for [`Self::retry_held_welcome`].
    pub fn join_from_welcome_judged(
        &mut self,
        group_key: &str,
        welcome_bytes: &[u8],
        judge: impl FnOnce(&WelcomeFacts) -> Verdict,
    ) -> Result<Verdict, String> {
        let msg_in: MlsMessageIn = TlsDeserialize::tls_deserialize_exact(welcome_bytes)
            .map_err(|e| format!("Failed to deserialize Welcome message: {e:?}"))?;
        let welcome = match msg_in.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("Message is not a Welcome".to_string()),
        };
        let staged = StagedWelcome::build_from_welcome(&self.provider, &hollow_join_config(), welcome)
            .map_err(|e| format!("Failed to process Welcome: {e:?}"))?
            .replace_old_group()
            .build()
            .map_err(|e| format!("Failed to stage Welcome: {e:?}"))?;
        let facts = self.welcome_facts(group_key, &staged);
        let verdict = judge(&facts);
        match &verdict {
            Verdict::Accept => self.install_welcome(group_key, staged)?,
            Verdict::Hold(_) => {
                self.held_welcomes.insert(
                    group_key.to_string(),
                    HeldWelcome { staged, facts, since: std::time::Instant::now() },
                );
            }
            Verdict::Refuse(_) => {}
        }
        Ok(verdict)
    }

    /// Re-judge a held Welcome. `None` when nothing is held; one past
    /// [`HELD_MAX_AGE`] is refused.
    pub fn retry_held_welcome(
        &mut self,
        group_key: &str,
        judge: impl FnOnce(&WelcomeFacts) -> Verdict,
    ) -> Option<Result<Verdict, String>> {
        let mut held = self.held_welcomes.remove(group_key)?;
        if held.since.elapsed() >= HELD_MAX_AGE {
            return Some(Ok(Verdict::Refuse("held too long".to_string())));
        }
        held.facts.replaces = self.groups.contains_key(group_key);
        let verdict = judge(&held.facts);
        match &verdict {
            Verdict::Accept => {
                if let Err(e) = self.install_welcome(group_key, held.staged) {
                    return Some(Err(e));
                }
            }
            Verdict::Hold(_) => {
                self.held_welcomes.insert(group_key.to_string(), held);
            }
            Verdict::Refuse(_) => {}
        }
        Some(Ok(verdict))
    }

    /// Encrypt a message for all group members. Returns the MLS ciphertext bytes.
    /// Refused while our own leaf is unbound: receivers ignore such a leaf, so the
    /// caller falls back as for a member without a group.
    pub fn encrypt(
        &mut self,
        server_id: &str,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;
        if !own_leaf_bound(group, self.signer.public(), &self.leaf_cache) {
            return Err(format!("our leaf in {server_id} is not bound yet"));
        }

        let msg_out = group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(|e| format!("MLS encrypt failed: {e:?}"))?;

        TlsSerialize::tls_serialize_detached(&msg_out)
            .map_err(|e| format!("Failed to serialize MLS message: {e:?}"))
    }

    /// Decrypt an application message from a bound leaf. Returns (plaintext, sender).
    pub fn decrypt(
        &mut self,
        server_id: &str,
        ciphertext: &[u8],
    ) -> Result<(Vec<u8>, LeafIdentity), String> {
        match self.decrypt_fresh(server_id, ciphertext).map_err(|e| e.to_string())? {
            Decrypted::Fresh { plaintext, sender } => Ok((plaintext, sender)),
            Decrypted::Replay => Err("MLS message generation already consumed".to_string()),
            Decrypted::UnboundSender(raw) => Err(format!("sender leaf {raw} is not bound")),
        }
    }

    /// Decrypt an application message and say who sent it, telling a replay and an
    /// unbound sender apart from a failure, and garbage apart from a frame that may
    /// mean we are behind.
    pub fn decrypt_fresh(
        &mut self,
        server_id: &str,
        ciphertext: &[u8],
    ) -> Result<Decrypted, DecryptFail> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| DecryptFail::Garbage(format!("No MLS group for server {server_id}")))?;

        let msg_in: MlsMessageIn = TlsDeserialize::tls_deserialize_exact(ciphertext)
            .map_err(|e| DecryptFail::Garbage(format!("Failed to deserialize MLS message: {e:?}")))?;

        let protocol_msg = msg_in
            .try_into_protocol_message()
            .map_err(|e| DecryptFail::Garbage(format!("Not a protocol message: {e:?}")))?;

        let processed = match group.process_message(&self.provider, protocol_msg) {
            Ok(processed) => processed,
            Err(ProcessMessageError::ValidationError(ValidationError::UnableToDecrypt(
                MessageDecryptionError::SecretTreeError(SecretTreeError::SecretReuseError),
            ))) => return Ok(Decrypted::Replay),
            Err(ProcessMessageError::ValidationError(ValidationError::WrongGroupId)) => {
                return Err(DecryptFail::Garbage("names another group".to_string()));
            }
            Err(e) => return Err(DecryptFail::Stale(format!("MLS process_message failed: {e:?}"))),
        };

        let credential = processed.credential().serialized_content().to_vec();
        let current_key = match processed.sender() {
            Sender::Member(index) => group
                .member_at(*index)
                .filter(|m| m.credential.serialized_content() == credential.as_slice())
                .map(|m| m.signature_key),
            _ => return Err(DecryptFail::Garbage("not sent by a member".to_string())),
        };
        let sender = match current_key {
            Some(key) => classify_cached(&self.leaf_cache, &credential, &key),
            None => classify_by_certificate(&credential),
        };

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => match sender {
                LeafView::Bound(sender) => Ok(Decrypted::Fresh { plaintext: app_msg.into_bytes(), sender }),
                LeafView::Unbound(raw) => Ok(Decrypted::UnboundSender(raw)),
            },
            _ => Err(DecryptFail::Garbage("not an application message".to_string())),
        }
    }

    /// Process a commit, let `judge` rule on what it would change, and only then
    /// merge it. A held commit waits for [`Self::retry_held_commit`].
    pub fn process_commit_judged(
        &mut self,
        server_id: &str,
        commit_bytes: &[u8],
        judge: impl FnOnce(&CommitFacts) -> Verdict,
    ) -> Result<Verdict, String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        let msg_in: MlsMessageIn = TlsDeserialize::tls_deserialize_exact(commit_bytes)
            .map_err(|e| format!("Failed to deserialize commit: {e:?}"))?;

        let protocol_msg = msg_in
            .try_into_protocol_message()
            .map_err(|e| format!("Commit is not a protocol message: {e:?}"))?;

        let processed = group
            .process_message(&self.provider, protocol_msg)
            .map_err(|e| format!("Failed to process commit: {e:?}"))?;

        let committer = match processed.sender() {
            Sender::Member(index) => group.member_at(*index).map(|m| member_view(&self.leaf_cache, &m)),
            _ => None,
        };
        let staged = match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged) => *staged,
            _ => return Err("Expected a commit message".to_string()),
        };

        let own_index = group.own_leaf_index();
        let mut facts = CommitFacts {
            committer,
            path_leaf: staged.update_path_leaf_node().map(|l| leaf_node_view(&self.leaf_cache, l)),
            adds: staged
                .add_proposals()
                .map(|p| leaf_node_view(&self.leaf_cache, p.add_proposal().key_package().leaf_node()))
                .collect(),
            removes: Vec::new(),
            other_proposals: staged.queued_proposals().any(|p| {
                !matches!(p.proposal().proposal_type(), ProposalType::Add | ProposalType::Remove)
            }),
            removes_us: staged.self_removed(),
        };
        for proposal in staged.remove_proposals() {
            let index = proposal.remove_proposal().removed();
            facts.removes_us |= index == own_index;
            if let Some(member) = group.member_at(index) {
                facts.removes.push(member_view(&self.leaf_cache, &member));
            }
        }

        let verdict = judge(&facts);
        match &verdict {
            Verdict::Accept => {
                group
                    .merge_staged_commit(&self.provider, staged)
                    .map_err(|e| format!("Failed to merge staged commit: {e:?}"))?;
                hollow_log!("[HOLLOW-MLS] Processed commit for server {server_id}, new epoch: {:?}", group.epoch());
            }
            Verdict::Hold(_) => {
                let epoch = group.epoch().as_u64();
                self.held_commits.insert(
                    server_id.to_string(),
                    HeldCommit { staged, facts, epoch, since: std::time::Instant::now() },
                );
            }
            Verdict::Refuse(_) => {}
        }
        Ok(verdict)
    }

    /// Re-judge a held commit. `None` when nothing is held; one past
    /// [`HELD_MAX_AGE`], or overtaken by another commit, is refused.
    pub fn retry_held_commit(
        &mut self,
        group_key: &str,
        judge: impl FnOnce(&CommitFacts) -> Verdict,
    ) -> Option<Result<Verdict, String>> {
        let held = self.held_commits.remove(group_key)?;
        let Some(group) = self.groups.get_mut(group_key) else {
            return Some(Ok(Verdict::Refuse("group gone".to_string())));
        };
        if group.epoch().as_u64() != held.epoch {
            return Some(Ok(Verdict::Refuse("overtaken by another commit".to_string())));
        }
        if held.since.elapsed() >= HELD_MAX_AGE {
            return Some(Ok(Verdict::Refuse("held too long".to_string())));
        }
        let verdict = judge(&held.facts);
        match &verdict {
            Verdict::Accept => {
                if let Err(e) = group.merge_staged_commit(&self.provider, held.staged) {
                    return Some(Err(format!("Failed to merge held commit: {e:?}")));
                }
            }
            Verdict::Hold(_) => {
                self.held_commits.insert(group_key.to_string(), held);
            }
            Verdict::Refuse(_) => {}
        }
        Some(Ok(verdict))
    }

    /// Group keys with a held commit or Welcome awaiting a retry.
    pub fn held_group_keys(&self) -> Vec<String> {
        let mut keys: Vec<String> = self.held_commits.keys().chain(self.held_welcomes.keys()).cloned().collect();
        keys.sort();
        keys.dedup();
        keys
    }

    /// Check if an MLS group exists for a server.
    pub fn has_group(&self, server_id: &str) -> bool {
        self.groups.contains_key(server_id)
    }

    /// Whether a held group is still ACTIVE. A commit that removes our own leaf merges
    /// cleanly but leaves the group inactive: `has_group` stays true while export and
    /// encrypt fail forever, so callers use this to drop and re-bootstrap instead of
    /// wedging.
    pub fn is_active(&self, server_id: &str) -> bool {
        self.groups.get(server_id).map(|g| g.is_active()).unwrap_or(false)
    }

    /// All server_ids we hold an MLS group for, so revocation can sweep every shared
    /// server for a revoked device's leaf where we coordinate.
    pub fn group_ids(&self) -> Vec<String> {
        self.groups.keys().cloned().collect()
    }

    /// Get the number of members in the MLS group.
    #[cfg(test)]
    pub fn member_count(&self, server_id: &str) -> usize {
        self.groups
            .get(server_id)
            .map(|g| g.members().count())
            .unwrap_or(0)
    }

    /// Export an epoch secret for SFrame key derivation.
    /// Label should be "sframe" for media encryption keys.
    pub fn export_secret(
        &self,
        server_id: &str,
        label: &str,
        context: &[u8],
        key_length: usize,
    ) -> Result<Vec<u8>, String> {
        let group = self.groups.get(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;
        group
            .export_secret(self.provider.crypto(), label, context, key_length)
            .map_err(|e| format!("Failed to export secret: {e:?}"))
    }

    /// Get the current epoch number for a server's MLS group.
    pub fn epoch(&self, server_id: &str) -> Result<u64, String> {
        let group = self.groups.get(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;
        Ok(group.epoch().as_u64())
    }

    /// A short digest of the group's epoch authenticator. Two members at one epoch
    /// with different digests hold forks of the group; the digest reveals nothing of
    /// the epoch secrets.
    pub fn epoch_auth_digest(&self, group_key: &str) -> Option<String> {
        let group = self.groups.get(group_key)?;
        let mut hasher = Sha256::new();
        hasher.update(b"hollow-epoch-auth:");
        hasher.update(group.epoch_authenticator().as_slice());
        Some(hex::encode(&hasher.finalize()[..16]))
    }

    /// Remove MLS group for a server (on server delete/leave).
    pub fn remove_group(&mut self, server_id: &str) {
        if let Some(mut group) = self.groups.remove(server_id) {
            // Delete from OpenMLS provider storage so join_from_welcome doesn't hit GroupAlreadyExists.
            let _ = group.delete(self.provider.storage());
        }
        // Cached commits belong to the dropped incarnation: a fresh Welcome lands us past
        // them, and serving them would produce partial catch-ups that end behind the group.
        self.commit_cache.remove(server_id);
        self.held_commits.remove(server_id);
        self.held_welcomes.remove(server_id);
        self.pinned_committers.remove(server_id);
    }

    /// Pin the only master whose commits a meeting group accepts.
    pub fn pin_committer(&mut self, group_key: &str, master: &str) {
        self.pinned_committers.insert(group_key.to_string(), master.to_string());
    }

    pub fn pinned_committer(&self, group_key: &str) -> Option<&str> {
        self.pinned_committers.get(group_key).map(String::as_str)
    }

    /// Record that we answered `requester_master`'s KeyPackage request for a group.
    pub fn note_key_request_answered(&mut self, group_key: &str, requester_master: &str) {
        self.answered_key_requests
            .insert(group_key.to_string(), (requester_master.to_string(), std::time::Instant::now()));
    }

    /// Whom we last answered with a KeyPackage for this group, and when.
    pub fn key_request_answered(&self, group_key: &str) -> Option<(String, std::time::Instant)> {
        self.answered_key_requests.get(group_key).cloned()
    }

    /// Record a commit frame (authored or applied) for catch-up replay.
    /// Idempotent per epoch; keeps the ring ascending and capped.
    pub fn cache_commit(&mut self, group_key: &str, epoch: u64, commit_b64: String) {
        let ring = self.commit_cache.entry(group_key.to_string()).or_default();
        if ring.iter().any(|(e, _)| *e == epoch) {
            return;
        }
        ring.push_back((epoch, commit_b64));
        ring.make_contiguous().sort_by_key(|(e, _)| *e);
        while ring.len() > COMMIT_CACHE_CAP {
            ring.pop_front();
        }
    }

    /// Commit frames bridging `(after_epoch, up_to]`, ascending. `Some` ONLY when the
    /// cache holds EVERY epoch in that range, because a partial replay would leave the
    /// receiver stale while looking served; `None` means the caller falls back to a
    /// repair.
    pub fn cached_commits_after(
        &self,
        group_key: &str,
        after_epoch: u64,
        up_to: u64,
    ) -> Option<Vec<(u64, String)>> {
        if up_to <= after_epoch {
            return None;
        }
        let ring = self.commit_cache.get(group_key)?;
        let entries: Vec<(u64, String)> = ring
            .iter()
            .filter(|(e, _)| *e > after_epoch && *e <= up_to)
            .cloned()
            .collect();
        let expected = (up_to - after_epoch) as usize;
        if entries.len() != expected {
            return None;
        }
        Some(entries)
    }

    /// The id of every leaf in the group: its device when bound, else its raw credential.
    pub fn group_members(&self, server_id: &str) -> Vec<String> {
        self.group_leaves(server_id)
            .into_iter()
            .map(|leaf| leaf.id().to_string())
            .collect()
    }

    /// Every leaf of the group as a receiver judges it.
    pub fn group_leaves(&self, server_id: &str) -> Vec<LeafView> {
        self.groups
            .get(server_id)
            .map(|g| g.members().map(|m| member_view(&self.leaf_cache, &m)).collect())
            .unwrap_or_default()
    }
}

/// Read a u64 from a byte reader (big-endian).
fn read_u64(cursor: &mut std::io::Cursor<&[u8]>) -> Result<u64, String> {
    use std::io::Read;
    let mut buf = [0u8; 8];
    cursor.read_exact(&mut buf).map_err(|e| format!("Read error: {e}"))?;
    Ok(u64::from_be_bytes(buf))
}

/// Read `len` bytes from a reader.
fn read_bytes(cursor: &mut std::io::Cursor<&[u8]>, len: usize) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut buf = vec![0u8; len];
    cursor.read_exact(&mut buf).map_err(|e| format!("Read error: {e}"))?;
    Ok(buf)
}

#[cfg(test)]
impl MlsManager {
    /// A pre-0.12 identity: a random key and a bare id, as every install had before
    /// leaves were bound.
    pub(crate) fn new_legacy(identity_id: &str) -> Self {
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
        let credential_with_key = CredentialWithKey {
            credential: BasicCredential::new(identity_id.as_bytes().to_vec()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Self::with_identity(OpenMlsRustCrypto::default(), signer, credential_with_key, HashMap::new())
    }

    /// A KeyPackage whose leaf claims `credential_text` under this manager's OWN key.
    pub(crate) fn key_package_claiming(&self, credential_text: &str) -> Vec<u8> {
        let credential_with_key = CredentialWithKey {
            credential: BasicCredential::new(credential_text.as_bytes().to_vec()).into(),
            signature_key: self.signer.to_public_vec().into(),
        };
        let kp = KeyPackage::builder()
            .build(CIPHERSUITE, &self.provider, &self.signer, credential_with_key)
            .unwrap();
        TlsSerialize::tls_serialize_detached(kp.key_package()).unwrap()
    }

    /// Commit a plain self-update (a new leaf key under the same identity) and merge
    /// it locally: an honest-looking commit that stages a fork when only some members
    /// see it.
    pub(crate) fn self_update_commit(&mut self, group_key: &str) -> Vec<u8> {
        let group = self.groups.get_mut(group_key).unwrap();
        let bundle = group.self_update(&self.provider, &self.signer, LeafNodeParameters::default()).unwrap();
        group.merge_pending_commit(&self.provider).unwrap();
        TlsSerialize::tls_serialize_detached(bundle.commit()).unwrap()
    }

    /// This manager's own credential text.
    pub(crate) fn own_credential_text(&self) -> String {
        String::from_utf8_lossy(self.credential_with_key.credential.serialized_content()).to_string()
    }

    /// Apply a commit with no rule in the way, for tests about MLS mechanics.
    pub(crate) fn process_commit(&mut self, group_key: &str, commit: &[u8]) -> Result<(), String> {
        match self.process_commit_judged(group_key, commit, |_| Verdict::Accept)? {
            Verdict::Accept => Ok(()),
            other => Err(format!("{other:?}")),
        }
    }

    /// Join from a Welcome with no rule in the way, for tests about MLS mechanics.
    pub(crate) fn join_from_welcome(&mut self, group_key: &str, welcome: &[u8]) -> Result<(), String> {
        match self.join_from_welcome_judged(group_key, welcome, |_| Verdict::Accept)? {
            Verdict::Accept => Ok(()),
            other => Err(format!("{other:?}")),
        }
    }
}

/// Deterministic keys and bound managers for MLS tests.
#[cfg(test)]
pub(crate) mod test_keys {
    use super::*;

    pub(crate) fn keypair(tag: u8) -> NativeKeypair {
        let mut secret = [0u8; 32];
        for (i, slot) in secret.iter_mut().enumerate() {
            *slot = tag.wrapping_add(i as u8).wrapping_mul(37).wrapping_add(11);
        }
        NativeKeypair::from_secret_bytes(&secret)
    }

    /// A bound manager for device `device_tag` of master `master_tag`, and its device id.
    pub(crate) fn bound(master_tag: u8, device_tag: u8) -> (MlsManager, String) {
        let device = keypair(device_tag);
        let master = keypair(master_tag);
        (MlsManager::new(&device, &master).unwrap(), device.peer_id())
    }
}

#[cfg(test)]
mod commit_cache_tests {
    use super::test_keys::bound;

    #[test]
    fn cache_bridges_only_contiguous_ranges() {
        let (mut mgr, _) = bound(1, 2);
        mgr.cache_commit("g", 5, "c5".into());
        mgr.cache_commit("g", 6, "c6".into());
        mgr.cache_commit("g", 8, "c8".into()); // gap at 7

        // Contiguous (4, 6] bridges.
        let bridged = mgr.cached_commits_after("g", 4, 6).expect("bridge 5..=6");
        assert_eq!(bridged, vec![(5, "c5".to_string()), (6, "c6".to_string())]);
        // (4, 8] crosses the missing epoch 7 and must refuse: a partial replay would leave
        // the receiver stale while looking served.
        assert!(mgr.cached_commits_after("g", 4, 8).is_none());
        // (6, 8] also needs 7 — refuse.
        assert!(mgr.cached_commits_after("g", 6, 8).is_none());
        // Nothing to bridge / inverted range — refuse.
        assert!(mgr.cached_commits_after("g", 6, 6).is_none());
        assert!(mgr.cached_commits_after("g", 9, 8).is_none());
        // Unknown group — refuse.
        assert!(mgr.cached_commits_after("nope", 4, 6).is_none());
    }

    #[test]
    fn cache_caps_dedups_and_clears_with_group() {
        let (mut mgr, _) = bound(1, 3);
        // Duplicate epoch is idempotent (first frame wins).
        mgr.cache_commit("g", 1, "first".into());
        mgr.cache_commit("g", 1, "second".into());
        assert_eq!(
            mgr.cached_commits_after("g", 0, 1),
            Some(vec![(1, "first".to_string())])
        );
        // Cap: only the newest COMMIT_CACHE_CAP entries survive.
        for e in 2..=20u64 {
            mgr.cache_commit("g", e, format!("c{e}"));
        }
        assert!(mgr.cached_commits_after("g", 0, 20).is_none(), "old entries evicted");
        let tail_start = 20 - super::COMMIT_CACHE_CAP as u64;
        let tail = mgr.cached_commits_after("g", tail_start, 20).expect("newest entries kept");
        assert_eq!(tail.len(), super::COMMIT_CACHE_CAP);
        // remove_group drops the ring.
        mgr.remove_group("g");
        assert!(mgr.cached_commits_after("g", tail_start, 20).is_none());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::test_keys::{bound, keypair};

    fn sender_of(mgr: &mut MlsManager, group: &str, ct: &[u8]) -> (Vec<u8>, LeafIdentity) {
        mgr.decrypt(group, ct).unwrap()
    }

    #[test]
    fn test_create_group_and_has_group() {
        let (mut mgr, _) = bound(1, 2);
        assert!(!mgr.has_group("server1"));
        mgr.create_group("server1").unwrap();
        assert!(mgr.has_group("server1"));
        assert_eq!(mgr.member_count("server1"), 1);
        assert!(mgr.own_leaf_bound("server1"));
    }

    #[test]
    fn test_two_members_encrypt_decrypt() {
        let (mut alice, alice_dev) = bound(1, 2);
        alice.create_group("server1").unwrap();

        let (mut bob, bob_dev) = bound(3, 4);
        let bob_kp = bob.generate_key_package().unwrap();

        let (_commit, welcome_bytes) = alice.add_member("server1", &bob_kp).unwrap();
        alice.merge_pending_commit("server1").unwrap();
        assert_eq!(alice.member_count("server1"), 2);

        bob.join_from_welcome("server1", &welcome_bytes).unwrap();
        assert_eq!(bob.member_count("server1"), 2);

        let plaintext = b"Hello from Alice!";
        let ciphertext = alice.encrypt("server1", plaintext).unwrap();
        assert_ne!(ciphertext, plaintext.to_vec());

        let (decrypted, sender) = sender_of(&mut bob, "server1", &ciphertext);
        assert_eq!(decrypted, plaintext.to_vec());
        assert_eq!(sender.device, alice_dev);
        assert_eq!(sender.master, keypair(1).peer_id());

        assert!(matches!(bob.decrypt_fresh("server1", &ciphertext), Ok(Decrypted::Replay)));
        let next = alice.encrypt("server1", b"fresh after replay").unwrap();
        assert!(matches!(
            bob.decrypt_fresh("server1", &next),
            Ok(Decrypted::Fresh { plaintext, .. }) if plaintext == b"fresh after replay"
        ));
        assert!(matches!(
            bob.decrypt_fresh("server1", b"invalid ciphertext"),
            Err(DecryptFail::Garbage(_))
        ));

        let bob_ct = bob.encrypt("server1", b"Hello from Bob!").unwrap();
        let (decrypted2, sender2) = sender_of(&mut alice, "server1", &bob_ct);
        assert_eq!(decrypted2, b"Hello from Bob!".to_vec());
        assert_eq!(sender2.device, bob_dev);
    }

    #[test]
    fn test_remove_member_forward_secrecy() {
        let (mut alice, _) = bound(1, 2);
        alice.create_group("server1").unwrap();

        let (mut bob, bob_dev) = bound(3, 4);
        let (_, welcome_bob) = alice.add_member("server1", &bob.generate_key_package().unwrap()).unwrap();
        alice.merge_pending_commit("server1").unwrap();
        bob.join_from_welcome("server1", &welcome_bob).unwrap();

        let (mut charlie, _) = bound(5, 6);
        let (commit_charlie, welcome_charlie) =
            alice.add_member("server1", &charlie.generate_key_package().unwrap()).unwrap();
        alice.merge_pending_commit("server1").unwrap();
        bob.process_commit("server1", &commit_charlie).unwrap();
        charlie.join_from_welcome("server1", &welcome_charlie).unwrap();
        assert_eq!(alice.member_count("server1"), 3);

        let remove_commit = alice.remove_member("server1", &bob_dev).unwrap();
        alice.merge_pending_commit("server1").unwrap();
        charlie.process_commit("server1", &remove_commit).unwrap();
        assert_eq!(alice.member_count("server1"), 2);

        let ct = alice.encrypt("server1", b"Secret after Bob left").unwrap();
        assert_eq!(charlie.decrypt("server1", &ct).unwrap().0, b"Secret after Bob left".to_vec());
        assert!(bob.decrypt("server1", &ct).is_err(), "Bob must not decrypt after removal");
    }

    /// Startup compares this with the device to spot an identity inherited from another
    /// device. A bound credential reports its device, a legacy one its raw id.
    #[test]
    fn credential_identity_reports_the_device_or_the_legacy_id() {
        let (mgr, device) = bound(1, 2);
        assert_eq!(mgr.credential_identity(), device);
        assert_eq!(MlsManager::new_legacy("12D3KooWMyDeviceId").credential_identity(), "12D3KooWMyDeviceId");
    }

    /// The claim a receiver compares with the sending device before seating a leaf.
    #[test]
    fn key_package_identity_reads_the_leaf_credential() {
        let (mgr, device) = bound(1, 2);
        let kp = mgr.generate_key_package().unwrap();
        assert_eq!(
            MlsManager::key_package_identity(&kp).unwrap(),
            LeafView::Bound(LeafIdentity { device, master: keypair(1).peer_id() })
        );
        let legacy = MlsManager::new_legacy("12D3KooWMyDeviceId").generate_key_package().unwrap();
        assert_eq!(
            MlsManager::key_package_identity(&legacy).unwrap(),
            LeafView::Unbound("12D3KooWMyDeviceId".to_string())
        );
        assert!(MlsManager::key_package_identity(b"not a key package").is_err());
    }

    /// A leaf is bound only by its own device key AND its master's certificate for that
    /// device: a copied certificate, a certificate from another master and a bare id
    /// all read as unbound.
    #[test]
    fn a_leaf_is_bound_only_by_its_device_key_and_its_masters_certificate() {
        let (victim, victim_dev) = bound(1, 2);
        let victim_cred = victim.own_credential_text();
        let victim_key = keypair(2).public_key_bytes();
        assert_eq!(
            classify_leaf(victim_cred.as_bytes(), &victim_key),
            LeafView::Bound(LeafIdentity { device: victim_dev.clone(), master: keypair(1).peer_id() })
        );

        // The victim's credential over somebody else's key.
        assert!(classify_leaf(victim_cred.as_bytes(), &keypair(9).public_key_bytes()).bound().is_none());

        // A certificate for the victim's device signed by a master that is not the one named.
        let forger = keypair(7);
        let forged_sig = base64::engine::general_purpose::STANDARD
            .encode(forger.sign(leaf_certificate_payload(&keypair(1).peer_id(), &victim_dev).as_bytes()));
        let forged = format!("hl1:{victim_dev}:{}:{forged_sig}", keypair(1).peer_id());
        assert!(classify_leaf(forged.as_bytes(), &victim_key).bound().is_none());

        // Legacy and garbage.
        assert!(classify_leaf(victim_dev.as_bytes(), &victim_key).bound().is_none());
        assert!(classify_leaf(b"hl1:::", &victim_key).bound().is_none());
        assert!(classify_leaf(format!("{victim_cred}:extra").as_bytes(), &victim_key).bound().is_none());
    }

    /// A member can mint a KeyPackage claiming another device's certificate, but only
    /// under its own key, so it reads as unbound and is never added.
    #[test]
    fn a_copied_certificate_never_becomes_a_leaf() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (victim, victim_dev) = bound(3, 4);
        let (attacker, _) = bound(5, 6);

        let stolen = attacker.key_package_claiming(&victim.own_credential_text());
        assert!(MlsManager::key_package_identity(&stolen).unwrap().bound().is_none());
        assert!(owner.commit_membership("s", &[], &[(victim_dev.clone(), stolen)]).is_err());
        assert_eq!(owner.member_count("s"), 1);
    }

    #[test]
    fn one_device_always_signs_with_one_key() {
        let (a, _) = bound(1, 2);
        let (b, _) = bound(1, 3);
        let (a_again, _) = bound(1, 2);
        assert_ne!(a.signer_bytes().unwrap(), b.signer_bytes().unwrap(),
            "distinct devices must mint distinct MLS signature keys");
        assert_eq!(a.signer_bytes().unwrap(), a_again.signer_bytes().unwrap(),
            "the MLS key IS the device key");
    }

    #[test]
    fn test_remove_identity_leaves_multiple() {
        // One human holding TWO leaves: removing that human by its MASTER id alone drops
        // both, even with no device list naming the devices, and survivors keep decrypting.
        let (mut owner, _) = bound(1, 2);
        owner.create_group("server1").unwrap();

        let (mut survivor, _) = bound(3, 4);
        let (_, w_surv) = owner.add_member("server1", &survivor.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        survivor.join_from_welcome("server1", &w_surv).unwrap();

        let (dev_a, _) = bound(5, 6);
        let (c_a, _) = owner.add_member("server1", &dev_a.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        survivor.process_commit("server1", &c_a).unwrap();

        let (dev_b, _) = bound(5, 7);
        let (c_b, _) = owner.add_member("server1", &dev_b.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        survivor.process_commit("server1", &c_b).unwrap();
        assert_eq!(owner.member_count("server1"), 4);

        let commit = owner.remove_identity_leaves("server1", &[&keypair(5).peer_id()]).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        survivor.process_commit("server1", &commit).unwrap();
        assert_eq!(owner.member_count("server1"), 2);

        let ct = owner.encrypt("server1", b"after X removed").unwrap();
        assert_eq!(survivor.decrypt("server1", &ct).unwrap().0, b"after X removed".to_vec());
    }

    #[test]
    fn test_remove_identity_leaves_skips_unknown_ids() {
        // A set including ids with no matching leaf removes the matching one and skips the
        // rest, so kicks stay idempotent.
        let (mut owner, owner_dev) = bound(1, 2);
        owner.create_group("server1").unwrap();
        let (bob, bob_dev) = bound(3, 4);
        owner.add_member("server1", &bob.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        assert_eq!(owner.member_count("server1"), 2);

        owner.remove_identity_leaves("server1", &[&bob_dev, "12D3KooWBobGhostDevice"]).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        assert_eq!(owner.member_count("server1"), 1);

        assert!(owner.remove_identity_leaves("server1", &["12D3KooWNobody"]).is_err());
        // Our own leaf is never removed.
        assert!(owner.remove_identity_leaves("server1", &[&owner_dev]).is_err());
    }

    #[test]
    fn test_storage_serialization_roundtrip() {
        let (mut alice, alice_dev) = bound(1, 2);
        alice.create_group("server1").unwrap();

        let (mut bob, _) = bound(3, 4);
        let (_, welcome) = alice.add_member("server1", &bob.generate_key_package().unwrap()).unwrap();
        alice.merge_pending_commit("server1").unwrap();

        let signer_bytes = alice.signer_bytes().unwrap();
        let credential_bytes = alice.credential_bytes().unwrap();
        let storage_blob = alice.serialize_storage().unwrap();

        let mut alice2 = MlsManager::from_persisted(
            &signer_bytes,
            &credential_bytes,
            Some(&storage_blob),
            &["server1".to_string()],
        ).unwrap();
        alice2.adopt_device_identity(&keypair(2), &keypair(1));
        assert!(!alice2.drop_unused_legacy(), "the persisted signer IS the device key");

        assert!(alice2.has_group("server1"));
        assert_eq!(alice2.member_count("server1"), 2);

        bob.join_from_welcome("server1", &welcome).unwrap();
        let ct = alice2.encrypt("server1", b"After restore").unwrap();
        let (decrypted, sender) = bob.decrypt("server1", &ct).unwrap();
        assert_eq!(decrypted, b"After restore".to_vec());
        assert_eq!(sender.device, alice_dev);
    }

    #[test]
    fn test_credential_maps_to_peer_id() {
        let (mut alice, alice_dev) = bound(1, 2);
        alice.create_group("server1").unwrap();
        assert_eq!(alice.group_members("server1"), vec![alice_dev]);
    }

    #[test]
    fn test_generate_key_package() {
        let (mgr, _) = bound(1, 2);
        let kp = mgr.generate_key_package().unwrap();
        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(&kp).unwrap();
        assert!(kp_in.validate(mgr.provider.crypto(), ProtocolVersion::Mls10).is_ok());
    }

    type Peers = (Vec<MlsManager>, Vec<String>, Vec<(String, Vec<u8>)>);

    fn six_peers() -> Peers {
        let (peers, ids): (Vec<MlsManager>, Vec<String>) = (1..=6u8).map(|i| bound(10 + i, 20 + i)).unzip();
        let kps = peers.iter().zip(&ids)
            .map(|(p, id)| (id.clone(), p.generate_key_package().unwrap()))
            .collect();
        (peers, ids, kps)
    }

    #[test]
    fn test_batch_add_six_members() {
        let (mut owner, owner_dev) = bound(1, 2);
        owner.create_group("server1").unwrap();
        let (peers, _, key_packages) = six_peers();

        let (_commit, welcome_bytes, added) = owner.add_members_batch("server1", &key_packages).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        assert_eq!(added.len(), 6);
        assert_eq!(owner.member_count("server1"), 7);

        let mut joined: Vec<MlsManager> = peers.into_iter().map(|mut p| {
            p.join_from_welcome("server1", &welcome_bytes).unwrap();
            p
        }).collect();

        let ct = owner.encrypt("server1", b"Hello from owner to all 6 peers!").unwrap();
        for p in &mut joined {
            assert_eq!(p.member_count("server1"), 7);
            let (decrypted, sender) = p.decrypt("server1", &ct).unwrap();
            assert_eq!(decrypted, b"Hello from owner to all 6 peers!".to_vec());
            assert_eq!(sender.device, owner_dev);
        }
    }

    #[test]
    fn test_batch_add_skips_duplicates() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("server1").unwrap();

        let (bob, bob_dev) = bound(3, 4);
        owner.add_member("server1", &bob.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();

        let (charlie, charlie_dev) = bound(5, 6);
        let batch = vec![
            (bob_dev, bob.generate_key_package().unwrap()),  // already a leaf: skipped
            (charlie_dev.clone(), charlie.generate_key_package().unwrap()),
        ];
        let (_, _, added) = owner.add_members_batch("server1", &batch).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        assert_eq!(added, vec![charlie_dev]);
        assert_eq!(owner.member_count("server1"), 3);
    }

    #[test]
    fn test_batch_add_empty_returns_error() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("server1").unwrap();
        assert!(owner.add_members_batch("server1", &[]).is_err());
    }

    #[test]
    fn test_six_members_all_communicate() {
        let (mut owner, owner_dev) = bound(1, 2);
        owner.create_group("server1").unwrap();
        let (peers, ids, key_packages) = six_peers();
        let (_, welcome_bytes, _) = owner.add_members_batch("server1", &key_packages).unwrap();
        owner.merge_pending_commit("server1").unwrap();

        let mut all: Vec<MlsManager> = peers.into_iter().map(|mut p| {
            p.join_from_welcome("server1", &welcome_bytes).unwrap();
            p
        }).collect();

        for sender_idx in 0..all.len() {
            let msg = format!("Message from peer {}", sender_idx + 1);
            let ct = all[sender_idx].encrypt("server1", msg.as_bytes()).unwrap();
            let (dec, sender) = owner.decrypt("server1", &ct).unwrap();
            assert_eq!(dec, msg.as_bytes());
            assert_eq!(sender.device, ids[sender_idx]);
            for recv_idx in 0..all.len() {
                if recv_idx == sender_idx { continue; }
                let (dec, sender) = all[recv_idx].decrypt("server1", &ct).unwrap();
                assert_eq!(dec, msg.as_bytes());
                assert_eq!(sender.device, ids[sender_idx]);
            }
        }

        let owner_ct = owner.encrypt("server1", b"Owner broadcast").unwrap();
        for p in &mut all {
            let (dec, sender) = p.decrypt("server1", &owner_ct).unwrap();
            assert_eq!(dec, b"Owner broadcast".to_vec());
            assert_eq!(sender.device, owner_dev);
        }
    }

    #[test]
    fn test_export_sframe_secret() {
        let (mut owner, _) = bound(1, 2);
        let (mut peer, _) = bound(3, 4);
        owner.create_group("server1").unwrap();
        let (_, welcome) = owner.add_member("server1", &peer.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        peer.join_from_welcome("server1", &welcome).unwrap();

        let owner_key = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        let peer_key = peer.export_secret("server1", "sframe", b"", 32).unwrap();
        assert_eq!(owner_key.len(), 32);
        assert_eq!(owner_key, peer_key, "Both members should derive the same SFrame key");
        assert_eq!(owner.epoch("server1").unwrap(), peer.epoch("server1").unwrap());
        assert!(owner.epoch("server1").unwrap() > 0);
    }

    #[test]
    fn test_two_same_human_leaves_share_sframe_key() {
        // A human's TWO devices each hold a leaf in the same group, and at the same epoch
        // both MUST export the same SFrame key as every other member.
        let (mut owner, _) = bound(1, 2);
        owner.create_group("server1").unwrap();

        let (mut dev_a, _) = bound(5, 6);
        let (_, w_a) = owner.add_member("server1", &dev_a.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        dev_a.join_from_welcome("server1", &w_a).unwrap();

        let (mut dev_b, _) = bound(5, 7);
        let (c_b, w_b) = owner.add_member("server1", &dev_b.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        dev_a.process_commit("server1", &c_b).unwrap();
        dev_b.join_from_welcome("server1", &w_b).unwrap();

        let k_owner = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        assert_eq!(k_owner, dev_a.export_secret("server1", "sframe", b"", 32).unwrap());
        assert_eq!(k_owner, dev_b.export_secret("server1", "sframe", b"", 32).unwrap());

        let ct = owner.encrypt("server1", b"hello both devices").unwrap();
        assert_eq!(dev_a.decrypt("server1", &ct).unwrap().0, b"hello both devices".to_vec());
        let ct2 = owner.encrypt("server1", b"hello both devices").unwrap();
        assert_eq!(dev_b.decrypt("server1", &ct2).unwrap().0, b"hello both devices".to_vec());
    }

    #[test]
    fn test_sframe_key_rotates_on_membership_change() {
        let (mut owner, _) = bound(1, 2);
        let (mut peer1, _) = bound(3, 4);
        let (mut peer2, _) = bound(5, 6);
        owner.create_group("server1").unwrap();

        let (_, welcome1) = owner.add_member("server1", &peer1.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        peer1.join_from_welcome("server1", &welcome1).unwrap();
        let key_epoch1 = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        let epoch1 = owner.epoch("server1").unwrap();

        let (commit2, welcome2) = owner.add_member("server1", &peer2.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        peer1.process_commit("server1", &commit2).unwrap();
        peer2.join_from_welcome("server1", &welcome2).unwrap();

        let key_epoch2 = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        assert_ne!(key_epoch1, key_epoch2, "SFrame key must change when membership changes");
        assert!(owner.epoch("server1").unwrap() > epoch1);
        assert_eq!(key_epoch2, peer1.export_secret("server1", "sframe", b"", 32).unwrap());
        assert_eq!(key_epoch2, peer2.export_secret("server1", "sframe", b"", 32).unwrap());
    }

    /// A leaf is repaired in ONE commit that removes the device's old leaf and adds its
    /// fresh KeyPackage under the same device key, and bystanders see exactly that.
    #[test]
    fn one_commit_repairs_a_leaf() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut member, member_dev) = bound(3, 4);
        let (mut bystander, _) = bound(5, 6);
        let adds = vec![
            (member_dev.clone(), member.generate_key_package().unwrap()),
            (keypair(6).peer_id(), bystander.generate_key_package().unwrap()),
        ];
        let (_, welcome, _) = owner.add_members_batch("s", &adds).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.join_from_welcome("s", &welcome).unwrap();
        bystander.join_from_welcome("s", &welcome).unwrap();
        let epoch_before = owner.epoch("s").unwrap();

        // The member lost its group state; the same device asks again.
        let (mut member_again, _) = bound(3, 4);
        let kp = member_again.generate_key_package().unwrap();
        let repair = owner
            .commit_membership("s", std::slice::from_ref(&member_dev), &[(member_dev.clone(), kp)])
            .unwrap();
        assert_eq!(repair.removed, vec![member_dev.clone()]);
        assert_eq!(repair.added, vec![member_dev.clone()]);
        owner.merge_pending_commit("s").unwrap();
        assert_eq!(owner.epoch("s").unwrap(), epoch_before + 1, "a repair costs one epoch");

        let mut seen = CommitFacts::default();
        bystander
            .process_commit_judged("s", &repair.commit, |f| { seen = f.clone(); Verdict::Accept })
            .unwrap();
        let member_leaf = LeafView::Bound(LeafIdentity { device: member_dev.clone(), master: keypair(3).peer_id() });
        assert_eq!(seen.removes, vec![member_leaf.clone()]);
        assert_eq!(seen.adds, vec![member_leaf]);
        assert!(!seen.other_proposals);

        member_again.join_from_welcome("s", &repair.welcome.unwrap()).unwrap();
        let ct = member_again.encrypt("s", b"back").unwrap();
        assert_eq!(bystander.decrypt("s", &ct).unwrap().1.device, member_dev);
        // The old incarnation is out.
        let ct2 = owner.encrypt("s", b"after repair").unwrap();
        assert!(member.decrypt("s", &ct2).is_err());
    }

    /// A Welcome is judged while staged: refused, it replaces nothing and the group we
    /// hold keeps working.
    #[test]
    fn a_refused_welcome_replaces_nothing() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut member, _) = bound(3, 4);
        let (_, welcome) = owner.add_member("s", &member.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.join_from_welcome("s", &welcome).unwrap();

        // Someone else builds a group under the same id with the member's KeyPackage.
        let (mut intruder, intruder_dev) = bound(7, 8);
        intruder.create_group("s").unwrap();
        let (_, rogue) = intruder.add_member("s", &member.generate_key_package().unwrap()).unwrap();

        let mut facts = None;
        let verdict = member
            .join_from_welcome_judged("s", &rogue, |f| { facts = Some(f.clone()); Verdict::Refuse("unasked".into()) })
            .unwrap();
        assert_eq!(verdict, Verdict::Refuse("unasked".into()));
        let facts = facts.unwrap();
        assert!(facts.replaces && facts.group_id_matches && facts.own_leaf_is_ours);
        assert_eq!(facts.sender.id(), intruder_dev);

        let ct = owner.encrypt("s", b"still ours").unwrap();
        assert_eq!(member.decrypt("s", &ct).unwrap().0, b"still ours".to_vec());
    }

    /// A held commit merges on a retry once the rules allow it, and goes with its group.
    #[test]
    fn a_held_commit_merges_on_retry_and_dies_with_its_group() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut member, _) = bound(3, 4);
        let (_, welcome) = owner.add_member("s", &member.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.join_from_welcome("s", &welcome).unwrap();

        let (joiner, _) = bound(5, 6);
        let (commit, _) = owner.add_member("s", &joiner.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        let before = member.epoch("s").unwrap();
        assert_eq!(member.process_commit_judged("s", &commit, |_| Verdict::Hold("lag".into())).unwrap(),
            Verdict::Hold("lag".into()));
        assert_eq!(member.epoch("s").unwrap(), before, "held, not merged");
        assert_eq!(member.held_group_keys(), vec!["s".to_string()]);
        assert_eq!(member.retry_held_commit("s", |_| Verdict::Accept).unwrap().unwrap(), Verdict::Accept);
        assert_eq!(member.epoch("s").unwrap(), before + 1);
        assert!(member.retry_held_commit("s", |_| Verdict::Accept).is_none());

        // Held, then the group is dropped.
        let (late, _) = bound(7, 8);
        let (c2, _) = owner.add_member("s", &late.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.process_commit_judged("s", &c2, |_| Verdict::Hold("lag".into())).unwrap();
        member.remove_group("s");
        assert!(member.retry_held_commit("s", |_| Verdict::Accept).is_none());
    }

    /// While our own leaf is unbound we neither encrypt nor commit in the group.
    #[test]
    fn an_unbound_own_leaf_neither_encrypts_nor_commits() {
        let mut legacy = MlsManager::new_legacy("12D3KooWLegacyOwner");
        legacy.create_group("s").unwrap();
        assert!(!legacy.own_leaf_bound("s"));
        assert_eq!(legacy.unbound_own_groups(), vec!["s".to_string()]);
        assert!(legacy.encrypt("s", b"x").is_err());
        let (peer, _) = bound(3, 4);
        assert!(legacy.add_member("s", &peer.generate_key_package().unwrap()).is_err());
    }

    /// Groups formed before 0.12 switch without re-forming: the authority rebinds its own
    /// leaf in place, every other member is repaired in one commit, nobody forks, and
    /// each ends up attributed to its real device.
    #[test]
    fn a_legacy_group_rebinds_in_place_without_forking() {
        let owner_master = keypair(1);
        let owner_device = keypair(2);
        let mut owner = MlsManager::new_legacy(&owner_master.peer_id());
        owner.create_group("s").unwrap();
        let mut friend = MlsManager::new_legacy("12D3KooWLegacyFriend");
        let mut sibling = MlsManager::new_legacy("12D3KooWLegacySibling");
        let adds = vec![
            ("12D3KooWLegacyFriend".to_string(), friend.generate_key_package().unwrap()),
            ("12D3KooWLegacySibling".to_string(), sibling.generate_key_package().unwrap()),
        ];
        // Legacy groups were formed before any rule: seat the leaves directly.
        let group = owner.groups.get_mut("s").unwrap();
        let kps: Vec<KeyPackage> = adds.iter().map(|(_, b)| {
            let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(b).unwrap();
            kp_in.validate(owner.provider.crypto(), ProtocolVersion::Mls10).unwrap()
        }).collect();
        let (_, welcome, _) = group.add_members(&owner.provider, &owner.signer, &kps).unwrap();
        owner.merge_pending_commit("s").unwrap();
        let welcome = TlsSerialize::tls_serialize_detached(&welcome).unwrap();
        friend.join_from_welcome("s", &welcome).unwrap();
        sibling.join_from_welcome("s", &welcome).unwrap();

        // 0.12: the owner adopts its device key and rebinds in place.
        owner.adopt_device_identity(&owner_device, &owner_master);
        assert!(owner.can_rebind_in_place("s"));
        let rebind = owner.rebind_own_leaf("s").unwrap();
        owner.merge_pending_commit("s").unwrap();
        assert!(owner.own_leaf_bound("s"));
        assert!(owner.drop_unused_legacy());

        let mut seen = CommitFacts::default();
        friend.process_commit_judged("s", &rebind, |f| { seen = f.clone(); Verdict::Accept }).unwrap();
        assert_eq!(seen.committer, Some(LeafView::Unbound(owner_master.peer_id())));
        assert_eq!(
            seen.path_leaf,
            Some(LeafView::Bound(LeafIdentity { device: owner_device.peer_id(), master: owner_master.peer_id() }))
        );
        assert!(seen.adds.is_empty() && seen.removes.is_empty() && !seen.other_proposals);
        sibling.process_commit("s", &rebind).unwrap();

        // The friend adopts its own device key: it may not speak until repaired.
        let (friend_master, friend_device) = (keypair(3), keypair(4));
        friend.adopt_device_identity(&friend_device, &friend_master);
        assert!(friend.encrypt("s", b"too early").is_err());
        let kp = friend.generate_key_package().unwrap();
        let repair = owner
            .commit_membership("s", &["12D3KooWLegacyFriend".to_string()], &[(friend_device.peer_id(), kp)])
            .unwrap();
        owner.merge_pending_commit("s").unwrap();
        sibling.process_commit("s", &repair.commit).unwrap();
        friend.join_from_welcome("s", &repair.welcome.unwrap()).unwrap();
        assert!(friend.own_leaf_bound("s"));
        assert!(friend.drop_unused_legacy());

        let ct = friend.encrypt("s", b"bound now").unwrap();
        let (pt, sender) = sibling.decrypt("s", &ct).unwrap();
        assert_eq!(pt, b"bound now".to_vec());
        assert_eq!(sender, LeafIdentity { device: friend_device.peer_id(), master: friend_master.peer_id() });
        assert_eq!(owner.decrypt("s", &friend.encrypt("s", b"again").unwrap()).unwrap().1.device, friend_device.peer_id());

        // The sibling is still unbound: its messages decrypt but prove nobody.
        let unbound_ct = sibling.encrypt("s", b"legacy");
        assert!(unbound_ct.is_err(), "a legacy manager never adopted a device key, its leaf is unbound");
        assert_eq!(
            friend.export_secret("s", "sframe", b"", 32).unwrap(),
            owner.export_secret("s", "sframe", b"", 32).unwrap(),
            "no fork"
        );
    }

    /// Two members that merged different commits at one epoch hold forks: their epoch
    /// numbers agree and their authenticator digests do not.
    #[test]
    fn the_epoch_digest_tells_forks_apart() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut a, _) = bound(3, 4);
        let (mut b, _) = bound(5, 6);
        let (_, w, _) = owner.add_members_batch("s", &[
            (keypair(4).peer_id(), a.generate_key_package().unwrap()),
            (keypair(6).peer_id(), b.generate_key_package().unwrap()),
        ]).unwrap();
        owner.merge_pending_commit("s").unwrap();
        a.join_from_welcome("s", &w).unwrap();
        b.join_from_welcome("s", &w).unwrap();
        assert_eq!(a.epoch_auth_digest("s"), owner.epoch_auth_digest("s"));

        // A and B each commit at the same epoch and merge their own.
        let (x, _) = bound(7, 8);
        let (y, _) = bound(9, 10);
        a.add_member("s", &x.generate_key_package().unwrap()).unwrap();
        a.merge_pending_commit("s").unwrap();
        b.add_member("s", &y.generate_key_package().unwrap()).unwrap();
        b.merge_pending_commit("s").unwrap();
        assert_eq!(a.epoch("s").unwrap(), b.epoch("s").unwrap());
        assert_ne!(a.epoch_auth_digest("s"), b.epoch_auth_digest("s"));
    }
}

/// Persistence-format guard for the OpenMLS upgrade.
///
/// `serialize_storage()`/`from_persisted()` hand-roll a length-prefixed dump of the
/// `MemoryStorage` map into the `mls_identity` blob, and nothing in the type system
/// pins that map's encoding, so an upstream change would make every persisted group
/// silently unreadable with no compile error. The fixtures were minted while the
/// crate was on openmls 0.8.1 and are reloaded on every run, so a future bump that
/// changes the blob format fails here instead of in the field.
#[cfg(test)]
mod persisted_storage_fixture {
    use super::*;
    use std::path::PathBuf;

    const FIXTURE_SERVER: &str = "12D3KooWFixtureServer";
    const FIXTURE_LABEL: &str = "sframe";
    const FIXTURE_CONTEXT: &[u8] = b"hollow-fixture-context";
    const FIXTURE_KEY_LEN: usize = 32;

    fn fixture_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("src")
            .join("crypto")
            .join("fixtures")
            .join("mls_persisted_0_8_1")
    }

    /// Mints the fixtures. Ignored by default because it OVERWRITES the committed blobs,
    /// which must stay exactly as openmls 0.8.1 wrote them. Run it only when deliberately
    /// re-baselining against a new persisted format.
    #[test]
    #[ignore = "overwrites the committed 0.8.1 fixtures; run only to re-baseline"]
    fn generate_mls_0_8_1_fixtures() {
        let mut alice = MlsManager::new_legacy("12D3KooWFixtureAlice");
        alice.create_group(FIXTURE_SERVER).unwrap();

        // Two members, so the persisted blob carries a real ratchet tree, an epoch bump and
        // another leaf's key material.
        let bob = MlsManager::new_legacy("12D3KooWFixtureBob");
        let bob_kp = bob.generate_key_package().unwrap();
        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(&bob_kp).unwrap();
        let kp = kp_in.validate(alice.provider.crypto(), ProtocolVersion::Mls10).unwrap();
        let group = alice.groups.get_mut(FIXTURE_SERVER).unwrap();
        group.add_members(&alice.provider, &alice.signer, &[kp]).unwrap();
        alice.merge_pending_commit(FIXTURE_SERVER).unwrap();

        let dir = fixture_dir();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("signer.bin"), alice.signer_bytes().unwrap()).unwrap();
        std::fs::write(dir.join("credential.bin"), alice.credential_bytes().unwrap()).unwrap();
        std::fs::write(dir.join("storage.bin"), alice.serialize_storage().unwrap()).unwrap();

        let secret = alice
            .export_secret(FIXTURE_SERVER, FIXTURE_LABEL, FIXTURE_CONTEXT, FIXTURE_KEY_LEN)
            .unwrap();
        let meta = serde_json::json!({
            "openmls": "0.8.1",
            "openmls_memory_storage": "0.5.0",
            "server_id": FIXTURE_SERVER,
            "credential_identity": alice.credential_identity(),
            "epoch": alice.epoch(FIXTURE_SERVER).unwrap(),
            "member_count": alice.member_count(FIXTURE_SERVER),
            "members": alice.group_members(FIXTURE_SERVER),
            "export_label": FIXTURE_LABEL,
            "export_context": String::from_utf8_lossy(FIXTURE_CONTEXT),
            "export_key_len": FIXTURE_KEY_LEN,
            "export_secret_hex": hex::encode(&secret),
        });
        std::fs::write(
            dir.join("meta.json"),
            serde_json::to_vec_pretty(&meta).unwrap(),
        )
        .unwrap();
    }

    /// THE upgrade guard: an `mls_identity` blob written by openmls 0.8.1 must
    /// still load, keep its group id and epoch, and derive the SAME SFrame
    /// secret. A silent format change breaks this and nothing else. It is also a
    /// real pre-0.12 identity, so it must rebind in place to become usable.
    #[test]
    fn persisted_0_8_1_storage_still_loads() {
        let dir = fixture_dir();
        let signer = std::fs::read(dir.join("signer.bin")).expect("0.8.1 signer fixture");
        let credential =
            std::fs::read(dir.join("credential.bin")).expect("0.8.1 credential fixture");
        let storage = std::fs::read(dir.join("storage.bin")).expect("0.8.1 storage fixture");
        let meta: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("meta.json")).expect("0.8.1 meta"))
                .expect("meta.json parses");

        let server_id = meta["server_id"].as_str().unwrap().to_string();
        let mut restored = MlsManager::from_persisted(
            &signer,
            &credential,
            Some(&storage),
            std::slice::from_ref(&server_id),
        )
        .expect("0.8.1 persisted MLS state must still load");

        assert!(
            restored.has_group(&server_id),
            "persisted MLS group vanished after load"
        );
        assert!(
            restored.is_active(&server_id),
            "persisted MLS group loaded inactive"
        );
        assert_eq!(
            restored.credential_identity(),
            meta["credential_identity"].as_str().unwrap(),
            "leaf credential identity changed across the persistence format"
        );
        assert_eq!(
            restored.epoch(&server_id).unwrap(),
            meta["epoch"].as_u64().unwrap(),
            "persisted epoch changed across the persistence format"
        );
        assert_eq!(
            restored.member_count(&server_id),
            meta["member_count"].as_u64().unwrap() as usize,
            "persisted member count changed across the persistence format"
        );
        let mut got_members = restored.group_members(&server_id);
        let mut want_members: Vec<String> = meta["members"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        got_members.sort();
        want_members.sort();
        assert_eq!(got_members, want_members, "persisted member list changed");

        // The load is only genuine if the epoch secrets survived: same label, same context,
        // same bytes, which is what SFrame media keys ride on.
        let secret = restored
            .export_secret(
                &server_id,
                meta["export_label"].as_str().unwrap(),
                meta["export_context"].as_str().unwrap().as_bytes(),
                meta["export_key_len"].as_u64().unwrap() as usize,
            )
            .expect("restored group must still export secrets");
        assert_eq!(
            hex::encode(&secret),
            meta["export_secret_hex"].as_str().unwrap(),
            "SFrame export secret changed after reloading 0.8.1 state"
        );

        // A pre-0.12 leaf is unbound, so the group only becomes usable once rebound.
        assert!(restored.encrypt(&server_id, b"too early").is_err());
        let (device, master) = (super::test_keys::keypair(2), super::test_keys::keypair(1));
        restored.adopt_device_identity(&device, &master);
        assert!(restored.can_rebind_in_place(&server_id));
        restored.rebind_own_leaf(&server_id).expect("legacy leaf rebinds in place");
        restored.merge_pending_commit(&server_id).unwrap();
        assert!(restored.drop_unused_legacy());
        let ct = restored
            .encrypt(&server_id, b"after the upgrade")
            .expect("rebound group must encrypt");
        assert!(!ct.is_empty());
    }
}
