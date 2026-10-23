use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Mutex;

use base64::Engine;
use openmls::prelude::*;
use openmls::framing::errors::{MessageDecryptionError, SecretTreeError};
use openmls::prelude::tls_codec::{Serialize as TlsSerialize, Deserialize as TlsDeserialize};
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::OpenMlsProvider;
use sha2::{Digest, Sha256};

use super::mls_past::PastEpochs;
use super::mls_storage::{parse_past_scope, MlsProvider, MlsSave, LIVE_SCOPE};
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
/// the last 3 epochs (`mls_past`, outside OpenMLS, whose own window made every message
/// O(N)). A deliberate, bounded relaxation of forward secrecy, since any peer would
/// re-serve the same plaintext through channel sync anyway.
const SENDER_RATCHET_TOLERANCE: u32 = 512;
const SENDER_RATCHET_MAX_FORWARD: u32 = 2000;

/// The shared join-config carrying the late-delivery windows. Applied at create, at
/// join, AND to groups loaded from disk, so pre-existing groups upgrade on next start.
fn hollow_join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .max_past_epochs(0)
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

/// A device certificate as `own_certificate` would give it, for tests.
#[cfg(test)]
pub(crate) fn certificate_for_test(device: &NativeKeypair, master: &NativeKeypair) -> String {
    bound_credential_text(device, master)
}

/// A KeyPackage from a hostile test copy, whose private half no test reads back.
#[cfg(test)]
pub(crate) fn throwaway_key_package_for_test(mls: &MlsManager, group_key: &str) -> Vec<u8> {
    mls.generate_key_package_for(group_key, false).expect("kp")
}

/// Who a device certificate (a bound credential's text) says it is, when its
/// master's signature holds. It proves the binding, never who sent it: pair it with
/// a frame sealed by that device.
pub(crate) fn certified_device(cert: &str) -> Option<LeafIdentity> {
    classify_by_certificate(cert.as_bytes()).bound().cloned()
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

/// Leaf-node `application_id` of every KeyPackage minted for a group: this prefix, a
/// 16-byte tag of the group key, the mint time in ms. Path updates carry it over, so a
/// leaf always tells when the KeyPackage that seated it was minted.
const MINT_STAMP: &[u8; 4] = b"hkp1";

fn group_tag(group_key: &str) -> [u8; 16] {
    let digest = Sha256::digest(format!("hollow-kp-group:{group_key}").as_bytes());
    let mut tag = [0u8; 16];
    tag.copy_from_slice(&digest[..16]);
    tag
}

/// Strictly increasing within a process, so two mints in one millisecond still order.
fn next_mint_ms() -> u64 {
    static LAST: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let prev = LAST
        .fetch_update(std::sync::atomic::Ordering::SeqCst, std::sync::atomic::Ordering::SeqCst, |last| {
            Some(now.max(last + 1))
        })
        .unwrap_or(0);
    now.max(prev + 1)
}

fn mint_stamp(group_key: &str) -> Extensions<LeafNode> {
    let mut id = MINT_STAMP.to_vec();
    id.extend_from_slice(&group_tag(group_key));
    id.extend_from_slice(&next_mint_ms().to_be_bytes());
    Extensions::single(Extension::ApplicationId(ApplicationIdExtension::new(&id)))
        .expect("application_id is a leaf-node extension")
}

/// A new leaf's extensions: the mint stamp and an empty tally refreshed today.
fn stamped_leaf_extensions(group_key: &str) -> Extensions<LeafNode> {
    let tally = super::mls_tally::Tally { refreshed_day: super::mls_tally::today(), epochs: Vec::new(), carried: Vec::new() };
    super::mls_tally::with_tally(&mint_stamp(group_key), &tally)
}

/// The group tag and mint time a leaf's stamp names, if it carries one.
fn read_stamp(leaf: &LeafNode) -> Option<([u8; 16], u64)> {
    let id = leaf.extensions().application_id()?.as_slice();
    let rest = id.strip_prefix(MINT_STAMP.as_slice())?;
    let (tag, ms) = (rest.get(..16)?, rest.get(16..)?);
    Some((tag.try_into().ok()?, u64::from_be_bytes(ms.try_into().ok()?)))
}

/// When a leaf's KeyPackage was minted for `group_key`; `None` for another group or none.
fn minted_for(leaf: &LeafNode, group_key: &str) -> Option<u64> {
    read_stamp(leaf).filter(|(tag, _)| *tag == group_tag(group_key)).map(|(_, ms)| ms)
}

/// Whether we still hold the private half of the KeyPackage `hash_ref` names.
fn key_package_held(provider: &MlsProvider, hash_ref: &KeyPackageRef) -> bool {
    use openmls_traits::storage::StorageProvider;
    provider
        .storage()
        .key_package::<KeyPackageRef, KeyPackageBundle>(hash_ref)
        .is_ok_and(|kp| kp.is_some())
}

/// Whether a load of `server_ids` reads the rows of `scope`: the live store, and the
/// past epochs of those groups only.
fn scope_wanted(scope: &str, server_ids: &[String]) -> bool {
    scope == LIVE_SCOPE || parse_past_scope(scope).is_some_and(|(group, _)| server_ids.contains(&group))
}

/// Open an application message in `group`, and say who sent it.
fn open_application(
    group: &mut MlsGroup,
    provider: &MlsProvider,
    leaf_cache: &LeafCache,
    protocol_msg: ProtocolMessage,
) -> Result<Decrypted, DecryptFail> {
    let processed = match group.process_message(provider, protocol_msg) {
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
        Some(key) => classify_cached(leaf_cache, &credential, &key),
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

/// Who a held commit is from, one slot each: the committer's master, or its raw id.
fn committer_key(facts: &CommitFacts) -> Option<String> {
    facts.committer.as_ref().map(|c| c.bound().map_or(c.id(), |b| b.master.as_str()).to_string())
}

fn note_eviction(evictions: &mut HashMap<String, bool>, group_key: &str, facts: &CommitFacts) {
    if facts.removes_us {
        evictions.insert(group_key.to_string(), facts.readds_us_with_held_key == Some(true));
    }
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
    /// By device, when an added leaf's KeyPackage was minted for THIS group.
    pub add_minted: HashMap<String, u64>,
    /// By device, when a removed leaf's KeyPackage was minted, where it says.
    pub remove_minted: HashMap<String, u64>,
    /// Any proposal besides the committer's own Add and Remove.
    pub other_proposals: bool,
    pub removes_us: bool,
    /// The commit re-adds this device: whether we still hold that KeyPackage's private
    /// half, without which its Welcome can never be opened.
    pub readds_us_with_held_key: Option<bool>,
    /// The group epoch the commit was built at, and the tree before it (AR-27).
    pub epoch: u64,
    pub tree: Vec<super::mls_tally::LeafRecord>,
    /// The tally of the committer's new leaf: `None` without an update path,
    /// `Some(None)` for a leaf that carries none.
    pub path_tally: Option<Option<super::mls_tally::Tally>>,
    /// The commit carries no proposal at all.
    pub no_proposals: bool,
    /// Leaves the commit writes (adds, the committer's path leaf) that do not declare
    /// the tally capability: the standing ratchet's input.
    pub undeclared: Vec<LeafView>,
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

/// Held commits per group. One per committer, so a member's commit never pushes out
/// another member's, whose bytes could never be processed again.
const HELD_COMMITS_CAP: usize = 8;

/// What is left of a commit held past [`HELD_MAX_AGE`] or dropped at
/// [`HELD_COMMITS_CAP`]: its key is spent, so no catch-up can bring it again, and only
/// a repair of our leaf moves us past it.
struct LapsedCommit {
    facts: CommitFacts,
    epoch: u64,
    since: std::time::Instant,
}

/// How long a lapsed commit is judged again for the repair it may still call for.
const LAPSED_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(600);

/// KeyPackages we minted for a group and may still be Welcomed with, by hash reference
/// and mint time. A parked join's is not listed: its Welcome can come days later.
type MintedKeyPackages = Mutex<HashMap<String, Vec<(KeyPackageRef, std::time::Instant)>>>;

/// Per group, the other members' bound leaves at the epoch whose authenticator keys it.
type SeatCache = Mutex<HashMap<String, (Vec<u8>, std::sync::Arc<Vec<LeafIdentity>>)>>;

/// Once a newer KeyPackage for the group goes out, an older one is dropped after this.
const KEY_PACKAGE_SUPERSEDED: std::time::Duration = std::time::Duration::from_secs(120);

/// A KeyPackage no Welcome used within this is dropped (its ask has long timed out).
pub(crate) const KEY_PACKAGE_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(600);

/// Kept staged for the same reason: staging a Welcome consumes our KeyPackage.
struct HeldWelcome {
    staged: StagedWelcome,
    facts: WelcomeFacts,
    since: std::time::Instant,
    /// The KeyPackages it names, put back while it waits: spent only if it installs.
    spent: Vec<KeyPackageRef>,
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

/// Our place in a group. A Welcome held for our view to catch up is a seat on its
/// way: asking for another leaf then mints the KeyPackage of a second repair.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Seat {
    Held,
    WelcomeWaits,
    Missing,
}

/// Why a commit did not process.
#[derive(Debug)]
pub(crate) enum CommitError {
    /// Its key at our epoch is already spent: we processed this commit before and
    /// never merged it, so it can never process again.
    Spent,
    Other(String),
}

impl std::fmt::Display for CommitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CommitError::Spent => write!(f, "processed before and never merged, its key is spent"),
            CommitError::Other(e) => write!(f, "{e}"),
        }
    }
}

impl From<CommitError> for String {
    fn from(e: CommitError) -> Self {
        e.to_string()
    }
}

impl From<String> for CommitError {
    fn from(e: String) -> Self {
        CommitError::Other(e)
    }
}

/// One commit that removes and adds leaves, from [`MlsManager::commit_membership`].
pub(crate) struct MembershipCommit {
    pub commit: Vec<u8>,
    pub welcome: Option<Vec<u8>>,
    pub added: Vec<String>,
    pub removed: Vec<String>,
}

/// Saves taken in this process, by any manager: a save's number orders it after every
/// frame encrypted before it, even across a manager replaced mid-run.
static TAKES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Wraps OpenMLS for Hollow's channel group encryption: one MLS group per server,
/// while DMs stay on Olm.
pub(crate) struct MlsManager {
    provider: MlsProvider,
    /// Each group's last epochs, for frames that arrive after a merge.
    past: PastEpochs,
    /// The next save writes every row: the store came from a pre-0.13 blob, or a save failed.
    whole_save_due: std::sync::atomic::AtomicBool,
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
    /// RAM-only ring of `(epoch, epoch_auth_digest)` for the epochs this copy of the
    /// group passed through, as deep as `commit_cache`: a probe from an older epoch
    /// whose digest differs from ours there comes from a fork, not from behind.
    epoch_digests: HashMap<String, VecDeque<(u64, String)>>,
    held_commits: HashMap<String, Vec<HeldCommit>>,
    lapsed_commits: HashMap<String, Vec<LapsedCommit>>,
    held_welcomes: HashMap<String, HeldWelcome>,
    /// A meeting's only committer, by master: the host that admitted us, or ourselves
    /// when we host it. RAM-only, like meetings.
    pinned_committers: HashMap<String, String>,
    /// Per group, the master we last answered with a KeyPackage and when. Outlives the
    /// group on purpose: the repair that evicts us arrives before its Welcome.
    answered_key_requests: HashMap<String, (String, std::time::Instant)>,
    /// Per group we hold no copy of, our own devices that asked us for a leaf in it and
    /// when: each ask says that device holds no copy either. RAM-only.
    sibling_asks: HashMap<String, HashMap<String, std::time::Instant>>,
    /// Subgroups we founded on a KeyPackage, for the batch tick to fill. RAM-only.
    founded_subgroups: Vec<String>,
    /// Per group, whether the commit that evicted us re-added this device with a
    /// KeyPackage we hold, so its Welcome can be opened.
    evictions: HashMap<String, bool>,
    minted: MintedKeyPackages,
    /// Per group, the self-update we staged and handed to the committer, with the epoch
    /// it was built at: its broadcast, byte for byte, is what merges it. RAM-only.
    own_staged: HashMap<String, (u64, Vec<u8>)>,
    seat_cache: SeatCache,
    leaf_cache: LeafCache,
    /// Leafless walks and silent responders (RAM-only).
    pub(crate) lead: crate::node::standing::LeadBook,
}

/// Commits kept per group for catch-up replay. A desktop, the device that answers
/// catch-ups, keeps about a day of self-update cadence plus churn, so a phone asleep
/// overnight catches up instead of costing a repair; a phone serves little and keeps
/// few. Deeper staleness falls back to a repair.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
const COMMIT_CACHE_CAP: usize = 64;
#[cfg(any(target_os = "android", target_os = "ios"))]
const COMMIT_CACHE_CAP: usize = 8;

/// Bytes of base64 commit frames kept per group, whatever their count: a commit in a
/// blank tree of thousands of leaves weighs hundreds of KB.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
const COMMIT_CACHE_BYTES: usize = 16 * 1024 * 1024;
#[cfg(any(target_os = "android", target_os = "ios"))]
const COMMIT_CACHE_BYTES: usize = 2 * 1024 * 1024;

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
        provider: MlsProvider,
        signer: SignatureKeyPair,
        credential_with_key: CredentialWithKey,
        groups: HashMap<String, MlsGroup>,
    ) -> Self {
        MlsManager {
            provider,
            past: PastEpochs::default(),
            whole_save_due: std::sync::atomic::AtomicBool::new(false),
            signer,
            credential_with_key,
            legacy: None,
            groups,
            commit_cache: HashMap::new(),
            epoch_digests: HashMap::new(),
            held_commits: HashMap::new(),
            lapsed_commits: HashMap::new(),
            held_welcomes: HashMap::new(),
            pinned_committers: HashMap::new(),
            answered_key_requests: HashMap::new(),
            sibling_asks: HashMap::new(),
            founded_subgroups: Vec::new(),
            evictions: HashMap::new(),
            minted: Mutex::new(HashMap::new()),
            own_staged: HashMap::new(),
            seat_cache: Mutex::new(HashMap::new()),
            leaf_cache: Mutex::new(HashMap::new()),
            lead: Default::default(),
        }
    }

    /// A fresh MLS identity for this device: the device key signs, and the leaf
    /// credential carries the master's certificate for the device.
    pub fn new(device: &NativeKeypair, master: &NativeKeypair) -> Result<Self, String> {
        let (signer, credential_with_key) = device_identity(device, master);
        Ok(Self::with_identity(
            MlsProvider::default(),
            signer,
            credential_with_key,
            HashMap::new(),
        ))
    }

    /// Restore MlsManager from persisted state: serde JSON blobs for the signer and
    /// credential, and the pre-0.13 whole-store blob for `storage_blob`. A node then
    /// calls [`Self::adopt_device_identity`]; the fetch paths only decrypt.
    #[cfg(test)]
    pub fn from_persisted(
        signer_bytes: &[u8],
        credential_bytes: &[u8],
        storage_blob: Option<&[u8]>,
        server_ids: &[String],
    ) -> Result<Self, String> {
        Self::from_stored(signer_bytes, credential_bytes, storage_blob, Vec::new(), Vec::new(), server_ids)
    }

    /// [`Self::from_persisted`] from the stored rows, `(scope, key, value)`, or from a
    /// pre-0.13 blob when one is there (the rows are then ignored); the first save then
    /// writes every row and drops the blob. Only `server_ids` are loaded as groups; `unread` names the
    /// stored scopes whose rows were left on disk.
    pub fn from_stored(
        signer_bytes: &[u8],
        credential_bytes: &[u8],
        storage_blob: Option<&[u8]>,
        rows: Vec<(String, Vec<u8>, Vec<u8>)>,
        unread: Vec<String>,
        server_ids: &[String],
    ) -> Result<Self, String> {
        let provider = MlsProvider::default();
        // A blob means the last save was a pre-0.13 build's (after a downgrade, written
        // later than any row): the rows are stale, and its first save replaces them.
        let rows = match storage_blob {
            Some(blob) => {
                provider.storage().load_rows(super::mls_storage::rows_from_blob(blob)?);
                Vec::new()
            }
            None => rows,
        };
        let mut past_rows = super::mls_storage::PastRows::new();
        let mut live_rows = Vec::new();
        for (scope, k, v) in rows {
            if scope == LIVE_SCOPE {
                live_rows.push((k, v));
            } else if let Some(past) = parse_past_scope(&scope) {
                past_rows.entry(past).or_default().push((k, v));
            }
        }
        provider.storage().load_rows(live_rows);

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

        let epochs: HashMap<String, u64> = groups.iter().map(|(k, g)| (k.clone(), g.epoch().as_u64())).collect();
        let mut mgr = Self::with_identity(provider, signer, credential_with_key, groups);
        mgr.past.restore(past_rows, &epochs);
        if storage_blob.is_none() {
            mgr.past.note_dormant(unread.iter().filter_map(|scope| parse_past_scope(scope)));
        }
        mgr.whole_save_due.store(storage_blob.is_some(), std::sync::atomic::Ordering::Relaxed);
        Ok(mgr)
    }

    /// The MLS identity and groups `store` holds, `None` when it holds no identity.
    pub fn load_from(store: &crate::storage::MessageStore, server_ids: &[String]) -> Result<Option<Self>, String> {
        let Some((signer, credential, blob)) = store.load_mls_identity()? else { return Ok(None) };
        let (rows, unread) = store.load_mls_rows_in(|scope| scope_wanted(scope, server_ids))?;
        Self::from_stored(&signer, &credential, blob.as_deref(), rows, unread, server_ids).map(Some)
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

    /// This device's certificate (its bound credential's text), `None` while the
    /// credential is still a legacy unbound one.
    pub fn own_certificate(&self) -> Option<String> {
        let raw = self.credential_with_key.credential.serialized_content();
        classify_leaf(raw, self.signer.public()).bound()?;
        Some(String::from_utf8_lossy(raw).into_owned())
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

    /// TEST-ONLY: the live store as a pre-0.13 whole-store blob.
    #[cfg(test)]
    pub fn serialize_storage(&self) -> Result<Vec<u8>, String> {
        Ok(self.provider.storage().to_blob())
    }

    /// What changed since the last save, every row instead when a whole save is due.
    /// The rows taken are the caller's to write: a save that fails must be followed by
    /// [`Self::take_whole_save`].
    pub fn take_save(&self) -> Result<MlsSave, String> {
        let whole = self.whole_save_due.swap(false, std::sync::atomic::Ordering::Relaxed);
        self.take(whole).inspect_err(|_| self.whole_save_due.store(whole, std::sync::atomic::Ordering::Relaxed))
    }

    /// Every row of every store this manager holds, replacing what is stored for them.
    pub fn take_whole_save(&self) -> Result<MlsSave, String> {
        self.take(true).inspect_err(|_| self.whole_save_due.store(true, std::sync::atomic::Ordering::Relaxed))
    }

    /// The number of the newest save taken, whether or not it could be built.
    pub fn taken(&self) -> u64 {
        TAKES.load(std::sync::atomic::Ordering::Relaxed)
    }

    fn take(&self, whole: bool) -> Result<MlsSave, String> {
        let take = TAKES.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
        let mut save = MlsSave {
            take,
            signer: self.signer_bytes()?,
            credential: self.credential_bytes()?,
            drop_blob: whole,
            ..Default::default()
        };
        let live = LIVE_SCOPE.to_string();
        if whole {
            save.retain_only = Some(std::iter::once(live.clone()).chain(self.past.scopes()).collect());
            save.cleared.push(live.clone());
            let rows = self.provider.storage().take_all();
            save.rows.extend(rows.into_iter().map(|(k, v)| (live.clone(), k, Some(v))));
        } else {
            let rows = self.provider.storage().take_changes();
            save.rows.extend(rows.into_iter().map(|(k, v)| (live.clone(), k, v)));
        }
        self.past.take_into(&mut save, whole);
        Ok(save)
    }

    /// TEST-ONLY: what keeping `group_key`'s current epoch as a past one costs: the
    /// seconds to copy and pack it, and the packed bytes.
    #[cfg(test)]
    pub fn past_capture_cost(&self, group_key: &str) -> (f64, usize) {
        let t = std::time::Instant::now();
        let capture = PastEpochs::capture(&self.provider, &self.groups[group_key]);
        (t.elapsed().as_secs_f64(), capture.map_or(0, |c| c.packed_len()))
    }

    /// The epochs of `group_key` a late frame can still open in, oldest first.
    #[cfg(test)]
    pub fn past_epochs(&self, group_key: &str) -> Vec<u64> {
        self.past.epochs(group_key)
    }

    /// Generate a KeyPackage bound to no group: a meeting's knock, which is never a
    /// repair.
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

    /// Generate a KeyPackage stamped for `group_key` and its mint time, which is what
    /// lets it repair our leaf there. Unless `parked` (a join's, Welcomed days later),
    /// older ones for the group are dropped once superseded for a while.
    pub fn generate_key_package_for(&self, group_key: &str, parked: bool) -> Result<Vec<u8>, String> {
        let bundle = KeyPackage::builder()
            .leaf_node_capabilities(self.leaf_capabilities())
            .leaf_node_extensions(self.new_leaf_extensions(group_key))
            .build(CIPHERSUITE, &self.provider, &self.signer, self.credential_with_key.clone())
            .map_err(|e| format!("Failed to build KeyPackage: {e:?}"))?;
        let kp = bundle.key_package();
        if !parked {
            let hash_ref = kp.hash_ref(self.provider.crypto()).map_err(|e| format!("Failed to hash KeyPackage: {e:?}"))?;
            if let Ok(mut minted) = self.minted.lock() {
                let ours = minted.entry(group_key.to_string()).or_default();
                ours.retain(|(old, at)| at.elapsed() < KEY_PACKAGE_SUPERSEDED || !self.drop_key_package(old));
                ours.push((hash_ref, std::time::Instant::now()));
            }
        }
        TlsSerialize::tls_serialize_detached(kp).map_err(|e| format!("Failed to serialize KeyPackage: {e:?}"))
    }

    /// The capabilities our new leaves list: the tally, unless a test made this device
    /// mint 0.12.2-shaped leaves.
    fn leaf_capabilities(&self) -> Capabilities {
        if self.old_shaped() { Capabilities::default() } else { super::mls_tally::tally_capabilities() }
    }

    fn new_leaf_extensions(&self, group_key: &str) -> Extensions<LeafNode> {
        if self.old_shaped() { mint_stamp(group_key) } else { stamped_leaf_extensions(group_key) }
    }

    /// Whether a test made this device mint leaves without the tally (a 0.12.2 leaf).
    fn old_shaped(&self) -> bool {
        #[cfg(test)]
        {
            crate::node::standing::knobs::on(crate::node::standing::knobs::Knob::OldLeaf, &self.credential_identity())
        }
        #[cfg(not(test))]
        {
            false
        }
    }

    /// Delete the private half of a KeyPackage we minted; whether it is gone.
    fn drop_key_package(&self, hash_ref: &KeyPackageRef) -> bool {
        use openmls_traits::storage::StorageProvider;
        self.provider.storage().delete_key_package(hash_ref).is_ok()
    }

    /// Drop every listed KeyPackage minted at least `max_age` ago that no Welcome used.
    /// Returns how many, so the caller persists only when something went.
    pub fn discard_stale_key_packages(&self, max_age: std::time::Duration) -> usize {
        let Ok(mut minted) = self.minted.lock() else { return 0 };
        let mut dropped = 0;
        for ours in minted.values_mut() {
            ours.retain(|(hash_ref, at)| {
                let stale = at.elapsed() >= max_age && self.drop_key_package(hash_ref);
                dropped += usize::from(stale);
                !stale
            });
        }
        minted.retain(|_, ours| !ours.is_empty());
        dropped
    }

    /// When a serialised KeyPackage was minted for `group_key`; `None` when it names
    /// another group or none, or does not validate.
    pub fn key_package_minted_for(&self, kp_bytes: &[u8], group_key: &str) -> Option<u64> {
        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(kp_bytes).ok()?;
        let kp = kp_in.validate(self.provider.crypto(), ProtocolVersion::Mls10).ok()?;
        minted_for(kp.leaf_node(), group_key)
    }

    /// Whether this exact KeyPackage already seated its leaf in `group_key` (a leaf with
    /// its encryption key sits in the tree), so committing it again would only cost a
    /// remove and re-add.
    pub fn key_package_seated(&self, group_key: &str, kp_bytes: &[u8]) -> bool {
        let Some(group) = self.groups.get(group_key) else { return false };
        let Some(kp) = TlsDeserialize::tls_deserialize_exact(kp_bytes)
            .ok()
            .and_then(|kp_in: KeyPackageIn| kp_in.validate(self.provider.crypto(), ProtocolVersion::Mls10).ok())
        else {
            return false;
        };
        let key = kp.leaf_node().encryption_key();
        group.members().any(|m| group.public_group().leaf(m.index).is_some_and(|l| l.encryption_key() == key))
    }

    /// Whether a serialised KeyPackage's leaf declares the tally capability.
    pub fn key_package_declares(&self, kp_bytes: &[u8]) -> bool {
        TlsDeserialize::tls_deserialize_exact(kp_bytes)
            .ok()
            .and_then(|kp_in: KeyPackageIn| kp_in.validate(self.provider.crypto(), ProtocolVersion::Mls10).ok())
            .is_some_and(|kp| super::mls_tally::declares(kp.leaf_node()))
    }

    /// By device, when each bound leaf's KeyPackage was minted, where its leaf says.
    pub fn leaf_minted(&self, group_key: &str) -> HashMap<String, u64> {
        let Some(group) = self.groups.get(group_key) else { return HashMap::new() };
        group
            .members()
            .filter_map(|m| {
                let device = member_view(&self.leaf_cache, &m).bound()?.device.clone();
                let (_, ms) = read_stamp(group.public_group().leaf(m.index)?)?;
                Some((device, ms))
            })
            .collect()
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
            .max_past_epochs(0)
            .sender_ratchet_configuration(SenderRatchetConfiguration::new(
                SENDER_RATCHET_TOLERANCE,
                SENDER_RATCHET_MAX_FORWARD,
            ))
            .capabilities(self.leaf_capabilities())
            .with_leaf_node_extensions(self.new_leaf_extensions(server_id))
            .map_err(|e| format!("Failed to stamp our leaf: {e:?}"))?
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
        self.sibling_asks.remove(server_id);
        self.epoch_digests.remove(server_id);
        self.note_epoch(server_id);
        Ok(())
    }

    /// One commit that removes the leaves named in `removals` and adds `adds`, each
    /// `(device_id, KeyPackage)`. A device may be removed and re-added in the same
    /// commit, which is how a leaf is repaired. Our own leaf is never removed, and an
    /// add is skipped unless its KeyPackage is valid, bound and names that device.
    /// Caller merges with `merge_pending_commit` after broadcasting.
    #[cfg(test)]
    pub fn commit_membership(
        &mut self,
        group_key: &str,
        removals: &[String],
        adds: &[(String, Vec<u8>)],
    ) -> Result<MembershipCommit, String> {
        self.commit_membership_as(group_key, removals, adds, false)
    }

    /// [`Self::commit_membership`]; `rate_exempt` when no receiver judges our tally (we
    /// are the server's anchored owner, or the group is a meeting), so a history we
    /// cannot restate never stops the commit.
    pub fn commit_membership_as(
        &mut self,
        group_key: &str,
        removals: &[String],
        adds: &[(String, Vec<u8>)],
        rate_exempt: bool,
    ) -> Result<MembershipCommit, String> {
        let tree = self.leaf_records(group_key);
        let old_shaped = self.old_shaped();
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
        let mut added_ids: Vec<LeafIdentity> = Vec::new();
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
            if let Some(identity) = leaf.bound() {
                added_ids.push(identity.clone());
            }
            key_packages.push(kp);
            added.push(device_id.clone());
        }

        if remove_indices.is_empty() && key_packages.is_empty() {
            return Err("No valid membership change to commit".to_string());
        }

        // The tally our new leaf must state (AR-27), on every commit that carries a path
        // or counts against anyone.
        let removed_views: Vec<LeafView> = group
            .members()
            .filter(|m| remove_indices.contains(&m.index))
            .map(|m| member_view(&self.leaf_cache, &m))
            .collect();
        let epoch = group.epoch().as_u64();
        let mut params = None;
        if !old_shaped
            && let Some(me) = tree.iter().find(|r| r.index == own_index.u32()).and_then(|r| r.identity.clone())
        {
            let input = super::mls_rate::RateInput {
                epoch, leaves: &tree, committer: &me, adds: &added_ids, removes: &removed_views, no_proposals: false,
            };
            let charges = super::mls_rate::charges(&input);
            if !remove_indices.is_empty() || charges.any() {
                // Where receivers judge our tally, one we cannot derive is one they refuse:
                // committing it would leave us alone at the next epoch.
                let tally = match super::mls_rate::expected_tally(&input, &charges, super::mls_tally::today()) {
                    Ok(tally) => Some(tally),
                    Err(_) if rate_exempt => Some(super::mls_rate::fresh_tally(&input, &charges, super::mls_tally::today())),
                    Err(why) if super::mls_rate::others_all_capable(&tree, &me.master) => {
                        hollow_log!("[HOLLOW-MLS] Not committing in {group_key}: {why}");
                        return Err(format!("no honest tally for this commit: {why}"));
                    }
                    Err(_) => None,
                };
                params = tally.and_then(|tally| {
                    let extensions = group.own_leaf_node().map(|leaf| super::mls_tally::with_tally(leaf.extensions(), &tally))?;
                    Some(LeafNodeParameters::builder()
                        .with_capabilities(super::mls_tally::tally_capabilities())
                        .with_extensions(extensions)
                        .build())
                });
            }
        }
        let builder = group.commit_builder();
        let builder = match params {
            Some(params) => builder.force_self_update(true).leaf_node_parameters(params),
            None => builder,
        };
        let bundle = builder
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

    /// Seat `adds` in one commit, giving back the seat of any device among them that
    /// holds a leaf. OpenMLS judges a batch whole, so a KeyPackage that passes alone
    /// but fails the batch (capabilities, a reused key) is left out and the rest are
    /// seated: one stranger's package never blocks every other knock.
    pub(crate) fn commit_admissions(
        &mut self,
        group_key: &str,
        adds: &[(String, Vec<u8>)],
        rate_exempt: bool,
    ) -> Result<MembershipCommit, String> {
        let seated = self.group_members(group_key);
        let stale = |adds: &[(String, Vec<u8>)]| -> Vec<String> {
            seated.iter().filter(|d| adds.iter().any(|(p, _)| p == *d)).cloned().collect()
        };
        let whole = self.commit_membership_as(group_key, &stale(adds), adds, rate_exempt);
        if whole.is_ok() || adds.len() < 2 {
            return whole;
        }
        let mut fit: Vec<(String, Vec<u8>)> = Vec::new();
        for add in adds {
            let mut trial = fit.clone();
            trial.push(add.clone());
            if self.commit_membership_as(group_key, &stale(&trial), &trial, rate_exempt).is_ok() {
                self.clear_pending_commit(group_key);
                fit = trial;
            } else {
                hollow_log!("[HOLLOW-SECURITY] Left {}'s KeyPackage out of {group_key}'s admissions: the batch refuses it", add.0);
            }
        }
        if fit.is_empty() {
            return whole;
        }
        self.commit_membership_as(group_key, &stale(&fit), &fit, rate_exempt)
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
        let done = self.commit_membership_as(server_id, &[], &[(device, key_package_bytes.to_vec())], false)?;
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

    /// Every leaf of the group as the tally rules read it.
    pub(crate) fn leaf_records(&self, group_key: &str) -> Vec<super::mls_tally::LeafRecord> {
        let Some(group) = self.groups.get(group_key) else { return Vec::new() };
        let today = super::mls_tally::today();
        group
            .members()
            .filter_map(|m| {
                let leaf = group.public_group().leaf(m.index)?;
                let tally = super::mls_tally::leaf_tally(leaf);
                let minted_day = read_stamp(leaf).map(|(_, ms)| (ms / 86_400_000) as u32);
                let fresh_day = tally.as_ref().map(|t| t.refreshed_day).or(minted_day).unwrap_or(0).min(today);
                Some(super::mls_tally::LeafRecord {
                    index: m.index.u32(),
                    identity: member_view(&self.leaf_cache, &m).bound().cloned(),
                    declares: leaf.capabilities().extensions().contains(&super::mls_tally::tally_extension_type()),
                    tally,
                    commit_written: super::mls_tally::written_by_commit(leaf),
                    fresh_day,
                })
            })
            .collect()
    }

    /// Masters of the group the tree shows unfit to act for it ([`super::mls_rate::unfit`]).
    pub(crate) fn unfit_masters(&self, group_key: &str, as_committer: bool, is_owner: impl Fn(&str) -> bool) -> HashSet<String> {
        let Ok(epoch) = self.epoch(group_key) else { return HashSet::new() };
        super::mls_rate::unfit_masters(&self.leaf_records(group_key), epoch, as_committer, is_owner)
    }

    /// Devices whose leaf change in a planned commit must wait, where receivers judge
    /// our tally: each repaired master's past the carried bound or with a history no
    /// tally can restate, and (unless we are `is_owner`, exempt from the cap) our own
    /// master's at its cap and each repaired master's that is. Empty when nothing must
    /// wait.
    pub(crate) fn over_cap_devices(
        &self,
        group_key: &str,
        removals: &[String],
        adds: &[(String, Vec<u8>)],
        is_owner: impl Fn(&str) -> bool,
    ) -> Vec<String> {
        let Some(group) = self.groups.get(group_key) else { return Vec::new() };
        let tree = self.leaf_records(group_key);
        let own_index = group.own_leaf_index().u32();
        let Some(me) = tree.iter().find(|r| r.index == own_index).and_then(|r| r.identity.clone()) else { return Vec::new() };
        if !super::mls_rate::others_all_capable(&tree, &me.master) {
            return Vec::new();
        }
        let add_ids: Vec<LeafIdentity> = adds
            .iter()
            .filter_map(|(_, kp)| Self::key_package_identity(kp).ok().and_then(|l| l.bound().cloned()))
            .collect();
        let removes: Vec<LeafView> = group
            .members()
            .map(|m| member_view(&self.leaf_cache, &m))
            .filter(|v| removals.iter().any(|r| r == v.id()))
            .collect();
        let epoch = group.epoch().as_u64();
        let input = super::mls_rate::RateInput { epoch, leaves: &tree, committer: &me, adds: &add_ids, removes: &removes, no_proposals: false };
        let charges = super::mls_rate::charges(&input);
        let history = |m: &str| super::mls_tally::master_tally(&tree, m, epoch);
        let mut blocked_masters: Vec<String> = super::mls_rate::carried_overflow(&input, &charges);
        blocked_masters.extend(
            charges.repaired.iter().filter(|n| history(n) == super::mls_tally::MasterTally::Unreadable).cloned(),
        );
        if !is_owner(&me.master) {
            let capped = |m: &str| super::mls_tally::capped(&history(m), epoch);
            blocked_masters.extend(charges.repaired.iter().filter(|n| capped(n)).cloned());
            if charges.committer && capped(&me.master) {
                blocked_masters.push(me.master.clone());
            }
        }
        let master_of_device = |d: &str| {
            add_ids.iter().find(|a| a.device == d).map(|a| a.master.clone())
                .or_else(|| removes.iter().filter_map(LeafView::bound).find(|r| r.device == d).map(|r| r.master.clone()))
        };
        removals
            .iter()
            .chain(adds.iter().map(|(d, _)| d))
            .filter(|d| master_of_device(d).is_some_and(|m| blocked_masters.contains(&m)))
            .cloned()
            .collect()
    }

    /// Stage a path-only commit of our own leaf: a fresh encryption key under the same
    /// credential, the tally set to `tally`. Left pending, not merged: the committer
    /// we hand it to decides whether it takes the epoch, and its broadcast of these
    /// bytes is what merges it here (`OwnPendingCommit`).
    pub(crate) fn stage_self_update(&mut self, group_key: &str, tally: &super::mls_tally::Tally) -> Result<Vec<u8>, String> {
        if self.old_shaped() {
            return Err("a 0.12.2-shaped leaf takes no turns".to_string());
        }
        let group = self.groups.get_mut(group_key).ok_or_else(|| format!("No MLS group for {group_key}"))?;
        if !own_leaf_bound(group, self.signer.public(), &self.leaf_cache) {
            return Err(format!("our leaf in {group_key} is not bound"));
        }
        if group.pending_commit().is_some() {
            return Err(format!("a commit of ours for {group_key} is already pending"));
        }
        let extensions = group
            .own_leaf_node()
            .map(|leaf| super::mls_tally::with_tally(leaf.extensions(), tally))
            .ok_or("no own leaf")?;
        let params = LeafNodeParameters::builder()
            .with_capabilities(super::mls_tally::tally_capabilities())
            .with_extensions(extensions)
            .build();
        let bundle = group
            .commit_builder()
            .consume_proposal_store(false)
            .force_self_update(true)
            .leaf_node_parameters(params)
            .load_psks(self.provider.storage())
            .map_err(|e| format!("Failed to load PSKs: {e:?}"))?
            .build(self.provider.rand(), self.provider.crypto(), &self.signer, |_| true)
            .map_err(|e| format!("Failed to build self-update: {e:?}"))?
            .stage_commit(&self.provider)
            .map_err(|e| format!("Failed to stage self-update: {e:?}"))?;
        let bytes = TlsSerialize::tls_serialize_detached(bundle.commit())
            .map_err(|e| format!("Failed to serialize self-update: {e:?}"))?;
        let epoch = group.epoch().as_u64();
        self.own_staged.insert(group_key.to_string(), (epoch, bytes.clone()));
        Ok(bytes)
    }

    /// Merge our own staged self-update right away: we are the committer and have
    /// broadcast it ourselves.
    pub(crate) fn merge_own_self_update(&mut self, group_key: &str) -> Result<(), String> {
        self.own_staged.remove(group_key);
        self.merge_pending_commit(group_key)
    }

    /// Drop a commit of ours that never took its epoch; whether one was pending.
    pub(crate) fn clear_pending_commit(&mut self, group_key: &str) -> bool {
        self.own_staged.remove(group_key);
        let Some(group) = self.groups.get_mut(group_key) else { return false };
        if group.pending_commit().is_none() {
            return false;
        }
        group.clear_pending_commit(self.provider.storage()).is_ok()
    }

    /// Groups holding a commit of ours that is staged and not merged.
    pub(crate) fn groups_with_pending_commit(&self) -> Vec<String> {
        self.groups.iter().filter(|(_, g)| g.pending_commit().is_some()).map(|(k, _)| k.clone()).collect()
    }

    /// Merge the pending commit after add/remove.
    /// Must be called by the committer after broadcasting the commit.
    pub fn merge_pending_commit(&mut self, server_id: &str) -> Result<(), String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;
        let before = PastEpochs::capture(&self.provider, group);

        group
            .merge_pending_commit(&self.provider)
            .map_err(|e| format!("Failed to merge pending commit: {e:?}"))?;

        hollow_log!("[HOLLOW-MLS] Merged pending commit for server {server_id}, epoch: {:?}", group.epoch());
        self.past.keep(server_id, before, group.epoch().as_u64());
        self.note_epoch(server_id);
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
    #[cfg(test)]
    pub fn remove_identity_leaves(
        &mut self,
        server_id: &str,
        credential_ids: &[&str],
    ) -> Result<Vec<u8>, String> {
        self.remove_identity_leaves_as(server_id, credential_ids, false)
    }

    /// [`Self::remove_identity_leaves`], `rate_exempt` as in [`Self::commit_membership_as`].
    pub fn remove_identity_leaves_as(
        &mut self,
        server_id: &str,
        credential_ids: &[&str],
        rate_exempt: bool,
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
        let done = self.commit_membership_as(server_id, &matching, &[], rate_exempt)?;
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
        // The bound leaf declares the tally and states our master's history unchanged:
        // a rebind is judged by no rate rule, so it must not move it either way.
        let tree = self.leaf_records(group_key);
        let epoch = self.epoch(group_key)?;
        let master = classify_leaf(self.credential_with_key.credential.serialized_content(), self.signer.public())
            .bound()
            .map(|b| b.master.clone())
            .ok_or("our credential is not bound")?;
        let epochs = match super::mls_tally::master_tally(&tree, &master, epoch) {
            super::mls_tally::MasterTally::List(list) => list,
            super::mls_tally::MasterTally::Unreadable => Vec::new(),
        };
        let tally = super::mls_tally::Tally { refreshed_day: super::mls_tally::today(), epochs, carried: Vec::new() }.checked()?;
        let params = LeafNodeParameters::builder()
            .with_capabilities(self.leaf_capabilities())
            .with_extensions(if self.old_shaped() { mint_stamp(group_key) } else { super::mls_tally::with_tally(&mint_stamp(group_key), &tally) })
            .build();
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
                params,
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
        self.past.drop_group(group_key);
        self.commit_cache.remove(group_key);
        self.epoch_digests.remove(group_key);
        self.held_commits.remove(group_key);
        self.lapsed_commits.remove(group_key);
        // We are seated; a held Welcome must not replace this group later.
        self.held_welcomes.remove(group_key);
        let group = staged
            .into_group(&self.provider)
            .map_err(|e| format!("Failed to create group from Welcome: {e:?}"))?;
        hollow_log!("[HOLLOW-MLS] Joined MLS group for server {group_key}, epoch: {:?}", group.epoch());
        self.groups.insert(group_key.to_string(), group);
        self.sibling_asks.remove(group_key);
        self.note_epoch(group_key);
        Ok(())
    }

    /// Our KeyPackage bundles a Welcome names, as they are stored now.
    fn bundles_named(&self, welcome_bytes: &[u8]) -> Vec<(KeyPackageRef, KeyPackageBundle)> {
        use openmls_traits::storage::StorageProvider;
        let Ok(msg_in) = <MlsMessageIn as TlsDeserialize>::tls_deserialize_exact(welcome_bytes) else {
            return Vec::new();
        };
        let MlsMessageBodyIn::Welcome(welcome) = msg_in.extract() else { return Vec::new() };
        welcome
            .secrets()
            .iter()
            .filter_map(|secrets| {
                let hash_ref = secrets.new_member();
                let bundle = self.provider.storage().key_package(&hash_ref).ok()??;
                Some((hash_ref, bundle))
            })
            .collect()
    }

    /// Whether a Welcome names a KeyPackage of ours that we still hold.
    pub fn names_our_key_package(&self, welcome_bytes: &[u8]) -> bool {
        !self.bundles_named(welcome_bytes).is_empty()
    }

    fn restore_key_packages(&self, bundles: &[(KeyPackageRef, KeyPackageBundle)]) {
        use openmls_traits::storage::StorageProvider;
        for (hash_ref, bundle) in bundles {
            if let Err(e) = self.provider.storage().write_key_package(hash_ref, bundle) {
                hollow_log!("[HOLLOW-MLS] Could not put back a KeyPackage a Welcome named: {e:?}");
            }
        }
    }

    fn forget_key_packages(&self, refs: &[KeyPackageRef]) {
        use openmls_traits::storage::StorageProvider;
        for hash_ref in refs {
            let _ = self.provider.storage().delete_key_package(hash_ref);
        }
    }

    /// Stage a Welcome, let `judge` rule on what it would install, and only then
    /// install it, replacing any group we hold under that key. A held Welcome waits
    /// for [`Self::retry_held_welcome`]. Staging deletes the KeyPackage the Welcome
    /// names before anything is checked, so it is put back unless the Welcome
    /// installs: whoever saw it on the wire cannot spend it (C-MLS-05).
    pub fn join_from_welcome_judged(
        &mut self,
        group_key: &str,
        welcome_bytes: &[u8],
        judge: impl FnOnce(&WelcomeFacts) -> Verdict,
    ) -> Result<Verdict, String> {
        let named = self.bundles_named(welcome_bytes);
        let verdict = self.stage_welcome(group_key, welcome_bytes, judge);
        if !matches!(verdict, Ok(Verdict::Accept)) {
            self.restore_key_packages(&named);
        }
        if matches!(verdict, Ok(Verdict::Hold(_)))
            && let Some(held) = self.held_welcomes.get_mut(group_key)
        {
            held.spent = named.into_iter().map(|(hash_ref, _)| hash_ref).collect();
        }
        verdict
    }

    fn stage_welcome(
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
        // A leaf nobody repairs keeps its KeyPackage's ~84-day lifetime for good, and
        // seats are judged by the roster and the CRDT: an age check would lock everyone
        // out of a long-lived group.
        let staged = StagedWelcome::build_from_welcome(&self.provider, &hollow_join_config(), welcome)
            .map_err(|e| format!("Failed to process Welcome: {e:?}"))?
            .skip_lifetime_validation()
            .replace_old_group()
            .build()
            .map_err(|e| format!("Failed to stage Welcome: {e:?}"))?;
        let facts = self.welcome_facts(group_key, &staged);
        let verdict = judge(&facts);
        match &verdict {
            Verdict::Accept => self.install_welcome(group_key, staged)?,
            Verdict::Hold(_) => {
                // A Welcome replacing a held one keeps its wait: a refreshed Welcome
                // never holds a seat open past the bound.
                let since = self.held_welcomes.get(group_key).map_or_else(std::time::Instant::now, |h| h.since);
                self.held_welcomes.insert(group_key.to_string(), HeldWelcome { staged, facts, since, spent: Vec::new() });
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
                let spent = std::mem::take(&mut held.spent);
                if let Err(e) = self.install_welcome(group_key, held.staged) {
                    return Some(Err(e));
                }
                self.forget_key_packages(&spent);
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

        // A frame from an epoch we merged past opens against that epoch as it stood;
        // one older than the window fails as stale, as it did inside OpenMLS.
        let epoch = protocol_msg.epoch().as_u64();
        if matches!(protocol_msg, ProtocolMessage::PrivateMessage(_))
            && protocol_msg.group_id() == group.group_id()
            && epoch < group.epoch().as_u64()
        {
            let leaf_cache = &self.leaf_cache;
            return self
                .past
                .open(server_id, epoch, |group, provider| {
                    let opened = open_application(group, provider, leaf_cache, protocol_msg);
                    if opened.is_err() {
                        let _ = group.clear_pending_proposals(provider.storage());
                    }
                    opened
                })
                .unwrap_or_else(|| Err(DecryptFail::Stale(format!("epoch {epoch} is past the late-delivery window"))));
        }
        open_application(group, &self.provider, &self.leaf_cache, protocol_msg)
    }

    /// Process a commit, let `judge` rule on what it would change, and only then
    /// merge it. A held commit waits for [`Self::retry_held_commit`].
    pub fn process_commit_judged(
        &mut self,
        server_id: &str,
        commit_bytes: &[u8],
        judge: impl FnOnce(&CommitFacts) -> Verdict,
    ) -> Result<Verdict, CommitError> {
        self.process_commit_judged_then(server_id, commit_bytes, judge, || {})
    }

    /// [`Self::process_commit_judged`], running `before_merge` once an accepted commit
    /// is staged and before it merges: a committer relaying a member's self-update
    /// broadcasts it there, so it never sits alone at the new epoch.
    pub fn process_commit_judged_then(
        &mut self,
        server_id: &str,
        commit_bytes: &[u8],
        judge: impl FnOnce(&CommitFacts) -> Verdict,
        before_merge: impl FnOnce(),
    ) -> Result<Verdict, CommitError> {
        let tree = self.leaf_records(server_id);
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        // Our own self-update, broadcast by the committer we handed it to. Its author
        // cannot decrypt a private commit, so it is known by its exact bytes.
        let epoch_now = group.epoch().as_u64();
        if self.own_staged.get(server_id).is_some_and(|(e, bytes)| *e == epoch_now && bytes == commit_bytes) {
            self.own_staged.remove(server_id);
            if group.pending_commit().is_none() {
                return Err(CommitError::Other("our relayed self-update is no longer pending".into()));
            }
            let before = PastEpochs::capture(&self.provider, group);
            group
                .merge_pending_commit(&self.provider)
                .map_err(|e| format!("Failed to merge our relayed self-update: {e:?}"))?;
            hollow_log!("[HOLLOW-MLS] Our self-update for {server_id} was relayed, new epoch: {:?}", group.epoch());
            self.past.keep(server_id, before, group.epoch().as_u64());
            self.note_epoch(server_id);
            return Ok(Verdict::Accept);
        }

        let msg_in: MlsMessageIn = TlsDeserialize::tls_deserialize_exact(commit_bytes)
            .map_err(|e| format!("Failed to deserialize commit: {e:?}"))?;

        let protocol_msg = msg_in
            .try_into_protocol_message()
            .map_err(|e| format!("Commit is not a protocol message: {e:?}"))?;

        let processed = match group.process_message(&self.provider, protocol_msg) {
            Ok(processed) => processed,
            Err(ProcessMessageError::ValidationError(ValidationError::UnableToDecrypt(
                MessageDecryptionError::SecretTreeError(SecretTreeError::SecretReuseError),
            ))) => return Err(CommitError::Spent),
            Err(e) => return Err(CommitError::Other(format!("Failed to process commit: {e:?}"))),
        };

        let committer = match processed.sender() {
            Sender::Member(index) => group.member_at(*index).map(|m| member_view(&self.leaf_cache, &m)),
            _ => None,
        };
        let staged = match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged) => *staged,
            _ => return Err(CommitError::Other("Expected a commit message".to_string())),
        };

        let own_index = group.own_leaf_index();
        let mut facts = CommitFacts {
            committer,
            path_leaf: staged.update_path_leaf_node().map(|l| leaf_node_view(&self.leaf_cache, l)),
            other_proposals: staged.queued_proposals().any(|p| {
                !matches!(p.proposal().proposal_type(), ProposalType::Add | ProposalType::Remove)
            }),
            removes_us: staged.self_removed(),
            epoch: group.epoch().as_u64(),
            tree,
            path_tally: staged.update_path_leaf_node().map(super::mls_tally::leaf_tally),
            no_proposals: staged.queued_proposals().next().is_none(),
            ..Default::default()
        };
        for proposal in staged.add_proposals() {
            let kp = proposal.add_proposal().key_package();
            let view = leaf_node_view(&self.leaf_cache, kp.leaf_node());
            if let (Some(leaf), Some(ms)) = (view.bound(), minted_for(kp.leaf_node(), server_id)) {
                facts.add_minted.insert(leaf.device.clone(), ms);
            }
            if kp.leaf_node().signature_key().as_slice() == self.signer.public() {
                let held = kp.hash_ref(self.provider.crypto()).is_ok_and(|r| key_package_held(&self.provider, &r));
                facts.readds_us_with_held_key = Some(held || facts.readds_us_with_held_key == Some(true));
            }
            if !super::mls_tally::declares(kp.leaf_node()) {
                facts.undeclared.push(view.clone());
            }
            facts.adds.push(view);
        }
        if let Some(path) = staged.update_path_leaf_node().filter(|l| !super::mls_tally::declares(l)) {
            facts.undeclared.push(leaf_node_view(&self.leaf_cache, path));
        }
        for proposal in staged.remove_proposals() {
            let index = proposal.remove_proposal().removed();
            facts.removes_us |= index == own_index;
            if let Some(member) = group.member_at(index) {
                let view = member_view(&self.leaf_cache, &member);
                if let (Some(leaf), Some((_, ms))) = (view.bound(), group.public_group().leaf(index).and_then(read_stamp)) {
                    facts.remove_minted.insert(leaf.device.clone(), ms);
                }
                facts.removes.push(view);
            }
        }

        let verdict = judge(&facts);
        match &verdict {
            Verdict::Accept => {
                let before = PastEpochs::capture(&self.provider, group);
                before_merge();
                group
                    .merge_staged_commit(&self.provider, staged)
                    .map_err(|e| format!("Failed to merge staged commit: {e:?}"))?;
                hollow_log!("[HOLLOW-MLS] Processed commit for server {server_id}, new epoch: {:?}", group.epoch());
                self.past.keep(server_id, before, group.epoch().as_u64());
                note_eviction(&mut self.evictions, server_id, &facts);
            }
            Verdict::Hold(_) => {
                let epoch = group.epoch().as_u64();
                let from = committer_key(&facts);
                let held = self.held_commits.entry(server_id.to_string()).or_default();
                held.retain(|h| committer_key(&h.facts) != from);
                if held.len() < HELD_COMMITS_CAP {
                    held.push(HeldCommit { staged, facts, epoch, since: std::time::Instant::now() });
                } else {
                    // Its key is spent all the same, so it is dropped as one held past its bound.
                    self.note_lapsed(server_id, facts, epoch);
                    return Ok(Verdict::Refuse(format!("{HELD_COMMITS_CAP} committers already wait, dropped unmerged")));
                }
            }
            Verdict::Refuse(_) => {}
        }
        if matches!(verdict, Verdict::Accept) {
            self.note_epoch(server_id);
        }
        Ok(verdict)
    }

    /// Keep what is left of a commit dropped unmerged after processing spent its key.
    fn note_lapsed(&mut self, group_key: &str, facts: CommitFacts, epoch: u64) {
        let lapsed = self.lapsed_commits.entry(group_key.to_string()).or_default();
        let from = committer_key(&facts);
        lapsed.retain(|l| committer_key(&l.facts) != from);
        if lapsed.len() < HELD_COMMITS_CAP {
            lapsed.push(LapsedCommit { facts, epoch, since: std::time::Instant::now() });
        }
    }

    /// Whether a commit for the group waits for a retry and may still merge.
    pub fn holds_commit(&self, group_key: &str) -> bool {
        self.held_commits.get(group_key).is_some_and(|held| !held.is_empty())
    }

    /// Whether a Welcome into the group is held for our view, whether or not we still
    /// hold the stale group it would replace: the repair it carries is on its way.
    pub fn welcome_waits(&self, group_key: &str) -> bool {
        self.held_welcomes.contains_key(group_key)
    }

    /// Whether we hold the group, wait on a held Welcome into it, or neither.
    pub fn seat(&self, group_key: &str) -> Seat {
        if self.groups.contains_key(group_key) {
            Seat::Held
        } else if self.held_welcomes.contains_key(group_key) {
            Seat::WelcomeWaits
        } else {
            Seat::Missing
        }
    }

    /// Re-judge the commits held for a group. `None` when nothing is held. The first
    /// that passes merges and overtakes the rest; one past [`HELD_MAX_AGE`] or behind
    /// our epoch is refused.
    pub fn retry_held_commit(
        &mut self,
        group_key: &str,
        mut judge: impl FnMut(&CommitFacts) -> Verdict,
    ) -> Option<Result<Verdict, String>> {
        let held = self.held_commits.remove(group_key)?;
        let Some(group) = self.groups.get_mut(group_key) else {
            return Some(Ok(Verdict::Refuse("group gone".to_string())));
        };
        let (mut kept, mut lapsing, mut ruling) = (Vec::new(), Vec::new(), None);
        for commit in held {
            if matches!(ruling, Some(Verdict::Accept)) || group.epoch().as_u64() != commit.epoch {
                ruling.get_or_insert(Verdict::Refuse("overtaken by another commit".to_string()));
                continue;
            }
            if commit.since.elapsed() >= HELD_MAX_AGE {
                ruling.get_or_insert(Verdict::Refuse("held too long".to_string()));
                lapsing.push((commit.facts, commit.epoch));
                continue;
            }
            match judge(&commit.facts) {
                Verdict::Accept => {
                    let before = PastEpochs::capture(&self.provider, group);
                    if let Err(e) = group.merge_staged_commit(&self.provider, commit.staged) {
                        return Some(Err(format!("Failed to merge held commit: {e:?}")));
                    }
                    self.past.keep(group_key, before, group.epoch().as_u64());
                    note_eviction(&mut self.evictions, group_key, &commit.facts);
                    ruling = Some(Verdict::Accept);
                }
                Verdict::Hold(why) => {
                    kept.push(commit);
                    if !matches!(ruling, Some(Verdict::Hold(_))) {
                        ruling = Some(Verdict::Hold(why));
                    }
                }
                refused @ Verdict::Refuse(_) => {
                    ruling.get_or_insert(refused);
                }
            }
        }
        for (facts, epoch) in lapsing {
            self.note_lapsed(group_key, facts, epoch);
        }
        if matches!(ruling, Some(Verdict::Accept)) {
            self.note_epoch(group_key);
        } else if !kept.is_empty() {
            self.held_commits.insert(group_key.to_string(), kept);
        }
        ruling.map(Ok)
    }

    /// Whether a commit we held past its bound would pass `judge` now, while we still
    /// sit at the epoch it left: then the group moved on without us and only a repair
    /// brings us back. Lapsed commits our epoch passed, past [`LAPSED_MAX_AGE`] or now
    /// refused are forgotten; [`Self::clear_lapsed`] ends the rest once a repair is asked.
    pub fn lapsed_commit_passes(&mut self, group_key: &str, mut judge: impl FnMut(&CommitFacts) -> Verdict) -> bool {
        let Some(lapsed) = self.lapsed_commits.remove(group_key) else { return false };
        let Ok(epoch) = self.epoch(group_key) else { return false };
        let mut passes = false;
        let kept: Vec<LapsedCommit> = lapsed
            .into_iter()
            .filter(|l| l.epoch == epoch && l.since.elapsed() < LAPSED_MAX_AGE)
            .filter(|l| match judge(&l.facts) {
                Verdict::Accept => {
                    passes = true;
                    true
                }
                Verdict::Hold(_) => true,
                Verdict::Refuse(_) => false,
            })
            .collect();
        if !kept.is_empty() {
            self.lapsed_commits.insert(group_key.to_string(), kept);
        }
        passes
    }

    /// Forget the lapsed commits of a group once a repair of our leaf is asked for.
    pub fn clear_lapsed(&mut self, group_key: &str) {
        self.lapsed_commits.remove(group_key);
    }

    /// Ages every held and lapsed commit by `by`, as if it had waited that long.
    #[cfg(test)]
    pub fn age_held_commits(&mut self, by: std::time::Duration) {
        let age = |since: &mut std::time::Instant| *since = since.checked_sub(by).unwrap_or(*since);
        self.held_commits.values_mut().flatten().for_each(|c| age(&mut c.since));
        self.lapsed_commits.values_mut().flatten().for_each(|l| age(&mut l.since));
    }

    /// Group keys holding a commit, those holding a lapsed one, and those holding a Welcome.
    #[cfg(test)]
    pub fn held_and_lapsed(&self) -> (Vec<String>, Vec<String>, Vec<String>) {
        (
            self.held_commits.keys().cloned().collect(),
            self.lapsed_commits.keys().cloned().collect(),
            self.held_welcomes.keys().cloned().collect(),
        )
    }

    /// Whether the Welcome that should follow the commit that evicted us from
    /// `group_key` can be opened: it re-adds this device with a KeyPackage we hold.
    pub fn take_eviction_welcome(&mut self, group_key: &str) -> bool {
        self.evictions.remove(group_key).unwrap_or(true)
    }

    /// Group keys with a held or lapsed commit or a held Welcome awaiting a retry.
    pub fn held_group_keys(&self) -> Vec<String> {
        let mut keys: Vec<String> = self
            .held_commits
            .keys()
            .chain(self.lapsed_commits.keys())
            .chain(self.held_welcomes.keys())
            .cloned()
            .collect();
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

    /// [`Self::epoch_auth_digest`] as this copy of the group had it at `epoch`, when
    /// it is the current epoch or a recent one we passed through.
    pub fn epoch_auth_digest_at(&self, group_key: &str, epoch: u64) -> Option<String> {
        if self.epoch(group_key).ok()? == epoch {
            return self.epoch_auth_digest(group_key);
        }
        self.epoch_digests
            .get(group_key)?
            .iter()
            .find(|(e, _)| *e == epoch)
            .map(|(_, digest)| digest.clone())
    }

    fn note_epoch(&mut self, group_key: &str) {
        let (Ok(epoch), Some(digest)) = (self.epoch(group_key), self.epoch_auth_digest(group_key)) else { return };
        if self.own_staged.get(group_key).is_some_and(|(e, _)| *e < epoch) {
            self.own_staged.remove(group_key);
        }
        let ring = self.epoch_digests.entry(group_key.to_string()).or_default();
        ring.retain(|(e, _)| *e < epoch);
        ring.push_back((epoch, digest));
        while ring.len() > COMMIT_CACHE_CAP + 1 {
            ring.pop_front();
        }
    }

    /// Remove MLS group for a server (on server delete/leave).
    pub fn remove_group(&mut self, server_id: &str) {
        if let Some(mut group) = self.groups.remove(server_id) {
            // Delete from OpenMLS provider storage so join_from_welcome doesn't hit GroupAlreadyExists.
            let _ = group.delete(self.provider.storage());
        }
        self.past.drop_group(server_id);
        // Cached commits belong to the dropped incarnation: a fresh Welcome lands us past
        // them, and serving them would produce partial catch-ups that end behind the group.
        self.commit_cache.remove(server_id);
        self.epoch_digests.remove(server_id);
        self.held_commits.remove(server_id);
        self.lapsed_commits.remove(server_id);
        self.held_welcomes.remove(server_id);
        self.pinned_committers.remove(server_id);
        if let Ok(mut cache) = self.seat_cache.lock() {
            cache.remove(server_id);
        }
    }

    /// Delete a stored group we did not load: its epoch secrets must not outlive our
    /// place in it (C-MLS-06).
    fn erase_stored_group(&self, group_id: &GroupId) {
        if let Ok(Some(mut group)) = MlsGroup::load(self.provider.storage(), group_id) {
            let _ = group.delete(self.provider.storage());
        }
    }

    /// The id of every group the provider store holds, loaded or not.
    fn stored_group_ids(&self) -> Vec<GroupId> {
        let context = super::mls_storage::label::GROUP_CONTEXT;
        self.provider
            .storage()
            .keys_with_prefix(context)
            .iter()
            .filter_map(|key| {
                let id = key.strip_prefix(context)?;
                serde_json::from_slice(id.get(..id.len().checked_sub(2)?)?).ok()
            })
            .collect()
    }

    /// Erase every stored group this manager did not load, except those of
    /// `keep_servers` (servers whose state could not be read this run). Meetings never
    /// outlive the process and a server we hold is always loaded, so what is left is a
    /// meeting's or a subgroup's whose channel lost its restriction. Returns their keys.
    pub fn forget_unloaded_groups(&mut self, keep_servers: &[String]) -> Vec<String> {
        let mut forgotten = Vec::new();
        for group_id in self.stored_group_ids() {
            let key = String::from_utf8_lossy(group_id.as_slice()).into_owned();
            if self.groups.contains_key(&key) || keep_servers.contains(&split_group_key(&key).0) {
                continue;
            }
            self.erase_stored_group(&group_id);
            self.past.drop_group(&key);
            forgotten.push(key);
        }
        let groups = &self.groups;
        forgotten.extend(
            self.past.drop_dormant_unless(|key| groups.contains_key(key) || keep_servers.contains(&split_group_key(key).0)),
        );
        forgotten
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

    /// Record that our own `device` asked us for a leaf in a group we hold no copy of.
    /// The caller has checked it is a device of ours, which bounds the map.
    pub fn note_sibling_ask(&mut self, group_key: &str, device: &str) {
        if self.groups.contains_key(group_key) {
            return;
        }
        self.sibling_asks
            .entry(group_key.to_string())
            .or_default()
            .insert(device.to_string(), std::time::Instant::now());
    }

    pub fn note_founded_subgroup(&mut self, group_key: &str) {
        if !self.founded_subgroups.iter().any(|g| g == group_key) {
            self.founded_subgroups.push(group_key.to_string());
        }
    }

    pub fn take_founded_subgroups(&mut self) -> Vec<String> {
        std::mem::take(&mut self.founded_subgroups)
    }

    /// Our devices that asked us for a leaf in `group_key` within `window`, since we
    /// last held a copy of it.
    pub fn sibling_asks(&self, group_key: &str, window: std::time::Duration) -> Vec<String> {
        self.sibling_asks
            .get(group_key)
            .map(|asks| asks.iter().filter(|(_, at)| at.elapsed() < window).map(|(d, _)| d.clone()).collect())
            .unwrap_or_default()
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
        while ring.len() > COMMIT_CACHE_CAP
            || (ring.len() > 1 && ring.iter().map(|(_, c)| c.len()).sum::<usize>() > COMMIT_CACHE_BYTES)
        {
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

    /// The other members' bound leaves: what a send under the group reaches. Cached
    /// per epoch, since every send asks.
    pub fn other_bound_leaves(&self, group_key: &str) -> std::sync::Arc<Vec<LeafIdentity>> {
        let Some(group) = self.groups.get(group_key) else { return Default::default() };
        let epoch = group.epoch_authenticator().as_slice().to_vec();
        if let Some((at, leaves)) = self.seat_cache.lock().ok().and_then(|c| c.get(group_key).cloned())
            && at == epoch
        {
            return leaves;
        }
        let own = group.own_leaf_index();
        let leaves: std::sync::Arc<Vec<LeafIdentity>> = std::sync::Arc::new(
            group
                .members()
                .filter(|m| m.index != own)
                .filter_map(|m| member_view(&self.leaf_cache, &m).bound().cloned())
                .collect(),
        );
        if let Ok(mut cache) = self.seat_cache.lock() {
            cache.insert(group_key.to_string(), (epoch, leaves.clone()));
        }
        leaves
    }
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
        Self::with_identity(MlsProvider::default(), signer, credential_with_key, HashMap::new())
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

    /// Whether the private half of a KeyPackage we minted is still stored.
    pub(crate) fn holds_key_package_for_test(&self, kp_bytes: &[u8]) -> bool {
        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(kp_bytes).unwrap();
        let kp = kp_in.validate(self.provider.crypto(), ProtocolVersion::Mls10).unwrap();
        key_package_held(&self.provider, &kp.hash_ref(self.provider.crypto()).unwrap())
    }

    /// A KeyPackage of this manager's own leaf that expires `secs` from now.
    pub(crate) fn key_package_expiring_in(&self, secs: u64) -> Vec<u8> {
        let kp = KeyPackage::builder()
            .key_package_lifetime(Lifetime::new(secs))
            .build(CIPHERSUITE, &self.provider, &self.signer, self.credential_with_key.clone())
            .unwrap();
        TlsSerialize::tls_serialize_detached(kp.key_package()).unwrap()
    }

    /// Commit a plain self-update (a new leaf key under the same identity) and merge
    /// it locally: an honest-looking commit that stages a fork when only some members
    /// see it.
    pub(crate) fn self_update_commit(&mut self, group_key: &str) -> Vec<u8> {
        let records = self.leaf_records(group_key);
        let group = &self.groups[group_key];
        let (epoch, own) = (group.epoch().as_u64(), group.own_leaf_index().u32());
        let me = records.iter().find(|r| r.index == own).and_then(|r| r.identity.clone()).unwrap();
        let input = super::mls_rate::RateInput { epoch, leaves: &records, committer: &me, adds: &[], removes: &[], no_proposals: true };
        let charges = super::mls_rate::charges(&input);
        let tally = super::mls_rate::expected_tally(&input, &charges, super::mls_tally::today()).unwrap_or_default();
        let commit = self.stage_self_update(group_key, &tally).unwrap();
        self.merge_own_self_update(group_key).unwrap();
        commit
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
        let last = super::COMMIT_CACHE_CAP as u64 + 12;
        for e in 2..=last {
            mgr.cache_commit("g", e, format!("c{e}"));
        }
        assert!(mgr.cached_commits_after("g", 0, last).is_none(), "old entries evicted");
        let tail_start = last - super::COMMIT_CACHE_CAP as u64;
        let tail = mgr.cached_commits_after("g", tail_start, last).expect("newest entries kept");
        assert_eq!(tail.len(), super::COMMIT_CACHE_CAP);
        // remove_group drops the ring.
        mgr.remove_group("g");
        assert!(mgr.cached_commits_after("g", tail_start, last).is_none());
    }

    #[test]
    fn the_commit_cache_keeps_to_its_byte_budget_but_always_the_newest_commit() {
        let (mut mgr, _) = bound(1, 3);
        let big = "x".repeat(super::COMMIT_CACHE_BYTES / 3 + 1);
        for e in 1..=4u64 {
            mgr.cache_commit("g", e, big.clone());
        }
        assert!(mgr.cached_commits_after("g", 1, 4).is_none(), "three such commits exceed the budget");
        assert_eq!(mgr.cached_commits_after("g", 2, 4).map(|c| c.len()), Some(2));
        let huge = "y".repeat(super::COMMIT_CACHE_BYTES + 1);
        mgr.cache_commit("g", 5, huge);
        assert_eq!(mgr.cached_commits_after("g", 4, 5).map(|c| c.len()), Some(1), "one commit over the budget is still kept");
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

    /// A sibling's ask for a leaf counts only while we hold no copy of the group:
    /// joining or founding it forgets the ask, and one heard while we hold it is dropped.
    #[test]
    fn sibling_asks_count_only_while_we_hold_no_copy() {
        let window = std::time::Duration::from_secs(60);
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut ours, _) = bound(3, 4);
        ours.note_sibling_ask("s", "d5");
        assert_eq!(ours.sibling_asks("s", window), vec!["d5".to_string()]);
        let (_, welcome) = owner.add_member("s", &ours.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        ours.join_from_welcome("s", &welcome).unwrap();
        ours.note_sibling_ask("s", "d6");
        ours.remove_group("s");
        assert!(ours.sibling_asks("s", window).is_empty(), "the join forgot d5, and d6 came while we held it");
        ours.note_sibling_ask("s", "d7");
        ours.create_group("s").unwrap();
        ours.remove_group("s");
        assert!(ours.sibling_asks("s", window).is_empty(), "founding the group forgot d7");
        ours.note_sibling_ask("t", "d8");
        assert!(ours.sibling_asks("t", std::time::Duration::ZERO).is_empty(), "an ask lapses with its window");
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

    /// C-MLS-05: staging a Welcome looks up and deletes the KeyPackage it names before
    /// anything is checked. One we refuse, one that fails after that lookup, or one we
    /// hold spends nothing: the Welcome we wait for still opens.
    #[test]
    fn a_welcome_that_is_not_installed_spends_no_key_package() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut joiner, _) = bound(3, 4);
        let kp = joiner.generate_key_package().unwrap();
        let (_, welcome) = owner.add_member("s", &kp).unwrap();
        owner.merge_pending_commit("s").unwrap();

        let (mut bystander, _) = bound(7, 8);
        bystander.create_group("s").unwrap();
        let (_, junk) = bystander.add_member("s", &kp).unwrap();
        let mut torn = junk.clone();
        *torn.last_mut().unwrap() ^= 1;

        let refused = joiner.join_from_welcome_judged("s", &junk, |_| Verdict::Refuse("not the host".into()));
        assert_eq!(refused.unwrap(), Verdict::Refuse("not the host".into()));
        assert!(joiner.join_from_welcome_judged("s", &torn, |_| Verdict::Accept).is_err(), "a torn Welcome");
        let held = joiner.join_from_welcome_judged("s", &junk, |_| Verdict::Hold("lag".into()));
        assert_eq!(held.unwrap(), Verdict::Hold("lag".into()));

        joiner.join_from_welcome("s", &welcome).expect("the Welcome we waited for still opens");
        assert!(!joiner.names_our_key_package(&welcome), "the Welcome that installed spent it");
        assert!(joiner.retry_held_welcome("s", |_| Verdict::Accept).is_none(), "the installed group ends the held one");
        let ct = owner.encrypt("s", b"in").unwrap();
        assert_eq!(joiner.decrypt("s", &ct).unwrap().0, b"in".to_vec());

        // A held Welcome that installs later spends the KeyPackage it named.
        let (mut other, _) = bound(9, 10);
        other.create_group("t").unwrap();
        let (_, held_welcome) = other.add_member("t", &joiner.generate_key_package().unwrap()).unwrap();
        joiner.join_from_welcome_judged("t", &held_welcome, |_| Verdict::Hold("lag".into())).unwrap();
        assert!(joiner.names_our_key_package(&held_welcome), "put back while it waits");
        assert_eq!(joiner.retry_held_welcome("t", |_| Verdict::Accept).unwrap().unwrap(), Verdict::Accept);
        assert!(!joiner.names_our_key_package(&held_welcome), "spent once it installed");
    }

    /// Whether any key of the store names group `group_key`.
    fn stored_mentions(mgr: &MlsManager, group_key: &str) -> bool {
        let needle = serde_json::to_vec(&GroupId::from_slice(group_key.as_bytes())).unwrap();
        mgr.provider.storage().keys_with_prefix(b"").iter().any(|k| k.windows(needle.len()).any(|w| w == needle.as_slice()))
    }

    /// C-MLS-06: a restore forgets every stored group nothing loaded (a meeting's, a
    /// subgroup whose channel lost its restriction) and keeps the loaded ones working, and
    /// those of a server whose state could not be read. A dropped group leaves no entry.
    #[test]
    fn a_restore_forgets_the_groups_nothing_loads() {
        let (mut owner, _) = bound(1, 2);
        let (mut member, _) = bound(3, 4);
        let (_, welcome) = {
            owner.create_group("srv").unwrap();
            let done = owner.add_member("srv", &member.generate_key_package().unwrap()).unwrap();
            owner.merge_pending_commit("srv").unwrap();
            done
        };
        member.join_from_welcome("srv", &welcome).unwrap();
        for group in ["srv#chan", "srv#gone", "conf:meeting", "unread", "unread#chan"] {
            owner.create_group(group).unwrap();
        }
        owner.remove_group("srv#gone");
        assert!(!stored_mentions(&owner, "srv#gone"), "a removed group leaves no entry");
        owner.create_group("srv#gone").unwrap();

        let loaded = ["srv".to_string(), "srv#chan".to_string()];
        let restore = |blob: &[u8], groups: &[String]| {
            let mut mgr = MlsManager::from_persisted(
                &owner.signer_bytes().unwrap(), &owner.credential_bytes().unwrap(), Some(blob), groups,
            ).unwrap();
            mgr.adopt_device_identity(&keypair(2), &keypair(1));
            mgr
        };
        let mut restored = restore(&owner.serialize_storage().unwrap(), &loaded);
        let mut forgotten = restored.forget_unloaded_groups(&["unread".to_string()]);
        forgotten.sort();
        assert_eq!(forgotten, vec!["conf:meeting".to_string(), "srv#gone".to_string()]);
        for gone in ["conf:meeting", "srv#gone"] {
            assert!(!stored_mentions(&restored, gone), "{gone} left an entry");
        }

        let everything: Vec<String> = ["srv", "srv#chan", "srv#gone", "conf:meeting", "unread", "unread#chan"]
            .iter().map(|g| g.to_string()).collect();
        let again = restore(&restored.serialize_storage().unwrap(), &everything);
        for kept in ["srv", "srv#chan", "unread", "unread#chan"] {
            assert!(again.has_group(kept), "{kept} was lost");
        }
        assert!(!again.has_group("conf:meeting") && !again.has_group("srv#gone"));
        let ct = restored.encrypt("srv", b"still here").unwrap();
        assert_eq!(member.decrypt("srv", &ct).unwrap().0, b"still here".to_vec());
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

    /// A commit held past its bound is dropped unmerged and its key stays spent, so it
    /// never merges later; what is left of it asks for a repair only once it would pass,
    /// only while we sit at its epoch, and is forgotten when refused.
    #[test]
    fn a_commit_held_past_its_bound_lapses_unmerged_and_calls_for_a_repair_once_it_passes() {
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
        member.process_commit_judged("s", &commit, |_| Verdict::Hold("lag".into())).unwrap();
        member.age_held_commits(HELD_MAX_AGE);
        assert_eq!(member.retry_held_commit("s", |_| Verdict::Accept).unwrap().unwrap(),
            Verdict::Refuse("held too long".into()), "a commit past its bound merged");
        assert_eq!(member.epoch("s").unwrap(), before);
        assert_eq!(member.held_and_lapsed(), (Vec::new(), vec!["s".to_string()], Vec::new()));
        assert!(member.held_group_keys().contains(&"s".to_string()), "the batch tick no longer judges it");

        assert!(!member.lapsed_commit_passes("s", |_| Verdict::Hold("lag".into())));
        assert!(member.lapsed_commit_passes("s", |_| Verdict::Accept));
        assert!(member.lapsed_commit_passes("s", |_| Verdict::Accept), "kept until a repair is asked");
        member.clear_lapsed("s");
        assert!(!member.lapsed_commit_passes("s", |_| Verdict::Accept));
        assert!(member.process_commit_judged("s", &commit, |_| Verdict::Accept).is_err(), "its key is spent");

    }

    /// A lapsed commit is forgotten once it is refused, and once another commit at its
    /// epoch moved us on.
    #[test]
    fn a_lapsed_commit_is_forgotten_when_refused_or_passed_by_our_epoch() {
        let lapse = |member: &mut MlsManager, commit: &[u8]| {
            member.process_commit_judged("s", commit, |_| Verdict::Hold("lag".into())).unwrap();
            member.age_held_commits(HELD_MAX_AGE);
            member.retry_held_commit("s", |_| Verdict::Accept);
        };
        let trio = || {
            let (mut owner, _) = bound(1, 2);
            owner.create_group("s").unwrap();
            let (mut member, member_id) = bound(3, 4);
            let (mut other, other_id) = bound(5, 6);
            let kps = [
                (member_id, member.generate_key_package().unwrap()),
                (other_id, other.generate_key_package().unwrap()),
            ];
            let (_, welcome, _) = owner.add_members_batch("s", &kps).unwrap();
            owner.merge_pending_commit("s").unwrap();
            member.join_from_welcome("s", &welcome).unwrap();
            other.join_from_welcome("s", &welcome).unwrap();
            (owner, member, other)
        };

        let (mut owner, mut member, _) = trio();
        let (held, _) = owner.add_member("s", &bound(7, 8).0.generate_key_package().unwrap()).unwrap();
        lapse(&mut member, &held);
        assert!(!member.lapsed_commit_passes("s", |_| Verdict::Refuse("revoked".into())));
        assert!(!member.lapsed_commit_passes("s", |_| Verdict::Accept), "a refused lapsed commit came back");

        let (mut owner, mut member, mut other) = trio();
        let (held, _) = owner.add_member("s", &bound(9, 10).0.generate_key_package().unwrap()).unwrap();
        let (rival, _) = other.add_member("s", &bound(11, 12).0.generate_key_package().unwrap()).unwrap();
        lapse(&mut member, &held);
        assert_eq!(member.process_commit_judged("s", &rival, |_| Verdict::Accept).unwrap(), Verdict::Accept);
        assert!(!member.lapsed_commit_passes("s", |_| Verdict::Accept), "a lapsed commit outlived its epoch");
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
        assert_eq!(
            seen.path_tally.as_ref().and_then(|t| t.as_ref()).map(|t| (t.epochs.clone(), t.carried.len())),
            Some((Vec::new(), 0)),
            "the rebound leaf declares the tally and states its history unchanged",
        );
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

    /// A member's commit that holds never pushes out another member's held commit,
    /// whose bytes could never be processed again.
    #[test]
    fn a_held_commit_survives_another_committers_held_commit() {
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

        let (x, _) = bound(7, 8);
        let (genuine, _) = owner.add_member("s", &x.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        let (y, _) = bound(9, 10);
        let (rogue, _) = b.add_member("s", &y.generate_key_package().unwrap()).unwrap();
        b.merge_pending_commit("s").unwrap();
        let lag = |_: &CommitFacts| Verdict::Hold("lag".into());
        assert_eq!(a.process_commit_judged("s", &genuine, lag).unwrap(), Verdict::Hold("lag".into()));
        assert_eq!(a.process_commit_judged("s", &rogue, lag).unwrap(), Verdict::Hold("lag".into()));

        let owner_master = keypair(1).peer_id();
        let only_the_owner = |f: &CommitFacts| match f.committer.as_ref().and_then(LeafView::bound) {
            Some(c) if c.master == owner_master => Verdict::Accept,
            _ => Verdict::Hold("lag".into()),
        };
        assert_eq!(a.retry_held_commit("s", only_the_owner).unwrap().unwrap(), Verdict::Accept);
        assert!(a.retry_held_commit("s", |_| Verdict::Accept).is_none(), "the overtaken commit goes");
        let ct = owner.encrypt("s", b"one group").unwrap();
        assert_eq!(a.decrypt("s", &ct).unwrap().0, b"one group".to_vec());
    }

    /// A commit that evicts us says whether the Welcome after it can be opened: only
    /// when it re-adds this device with a KeyPackage we still hold.
    #[test]
    fn an_eviction_says_whether_its_welcome_can_be_opened() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut member, member_dev) = bound(3, 4);
        let (_, w) = owner.add_member("s", &member.generate_key_package_for("s", false).unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.join_from_welcome("s", &w).unwrap();

        let held = member.generate_key_package_for("s", false).unwrap();
        let repair = owner.commit_membership("s", std::slice::from_ref(&member_dev), &[(member_dev.clone(), held)]).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.process_commit("s", &repair.commit).unwrap();
        assert!(member.take_eviction_welcome("s"), "a repair with our KeyPackage brings a Welcome we can open");
        member.remove_group("s");
        member.join_from_welcome("s", &repair.welcome.unwrap()).unwrap();

        let spent = member.generate_key_package_for("s", false).unwrap();
        member.discard_key_package(&spent).unwrap();
        let replay = owner.commit_membership("s", std::slice::from_ref(&member_dev), &[(member_dev.clone(), spent)]).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.process_commit("s", &replay.commit).unwrap();
        assert!(!member.take_eviction_welcome("s"), "a re-add with a KeyPackage we no longer hold brings nothing to open");
    }

    /// C-MLS-08: a KeyPackage no Welcome used is dropped once a newer one for its group
    /// has been out a while, or once its ask has long timed out; a parked join's stays.
    #[test]
    fn unused_key_packages_are_dropped_when_stale() {
        let (mgr, _) = bound(1, 2);
        let asked = mgr.generate_key_package_for("s", false).unwrap();
        let parked = mgr.generate_key_package_for("s", true).unwrap();
        assert!(mgr.holds_key_package_for_test(&asked) && mgr.holds_key_package_for_test(&parked));
        assert_eq!(mgr.discard_stale_key_packages(std::time::Duration::from_secs(600)), 0, "nothing is stale yet");
        assert_eq!(mgr.discard_stale_key_packages(std::time::Duration::ZERO), 1);
        assert!(!mgr.holds_key_package_for_test(&asked), "the unused KeyPackage's private half is gone");
        assert!(mgr.holds_key_package_for_test(&parked), "a parked join's KeyPackage waits for its Welcome");
    }

    /// R-MLS-21: seats are judged by the roster and the CRDT, never by a leaf's age, so
    /// a member whose leaf outlived its KeyPackage's lifetime keeps the group joinable.
    #[test]
    fn a_welcome_still_installs_after_an_old_members_leaf_lifetime_ends() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (old, _) = bound(3, 4);
        owner.add_member("s", &old.key_package_expiring_in(3)).unwrap();
        owner.merge_pending_commit("s").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(3200));

        let (mut late, _) = bound(5, 6);
        let (_, welcome) = owner.add_member("s", &late.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        late.join_from_welcome("s", &welcome).expect("a Welcome must install beside an expired leaf");
        let ct = owner.encrypt("s", b"still joinable").unwrap();
        assert_eq!(late.decrypt("s", &ct).unwrap().0, b"still joinable".to_vec());
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

// md-mls-2
#[cfg(test)]
mod md_mls_2 {
    use super::test_keys::bound;
    use super::*;

    /// A commit processed before and never merged says its key is spent, unlike a frame
    /// that fails for any other reason; one dropped at the held cap is reported refused,
    /// never held, and leaves what a repair needs.
    #[test]
    fn a_commit_processed_before_says_its_key_is_spent_and_one_dropped_at_the_cap_is_refused() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut member, member_id) = bound(3, 4);
        let mut committers: Vec<(MlsManager, String)> =
            (0..HELD_COMMITS_CAP as u8 + 1).map(|i| bound(40 + 2 * i, 41 + 2 * i)).collect();
        let mut kps = vec![(member_id, member.generate_key_package().unwrap())];
        for (c, id) in committers.iter_mut() {
            kps.push((id.clone(), c.generate_key_package().unwrap()));
        }
        let (_, welcome, _) = owner.add_members_batch("s", &kps).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.join_from_welcome("s", &welcome).unwrap();
        for (c, _) in committers.iter_mut() {
            c.join_from_welcome("s", &welcome).unwrap();
        }

        let mut verdicts = Vec::new();
        let mut first = Vec::new();
        for (i, (c, _)) in committers.iter_mut().enumerate() {
            let kp = bound(120 + 2 * i as u8, 121 + 2 * i as u8).0.generate_key_package().unwrap();
            let (commit, _) = c.add_member("s", &kp).unwrap();
            verdicts.push(member.process_commit_judged("s", &commit, |_| Verdict::Hold("lag".into())).unwrap());
            if i == 0 {
                first = commit;
            }
        }
        assert!(verdicts[..HELD_COMMITS_CAP].iter().all(|v| matches!(v, Verdict::Hold(_))));
        assert!(matches!(&verdicts[HELD_COMMITS_CAP], Verdict::Refuse(_)), "dropped at the cap, yet reported held");
        assert!(member.holds_commit("s"));
        assert_eq!(member.lapsed_commits.get("s").map(Vec::len), Some(1), "the commit dropped at the cap left nothing");

        assert!(matches!(member.process_commit_judged("s", &first, |_| Verdict::Accept), Err(CommitError::Spent)));
        let mut torn = first.clone();
        torn.truncate(torn.len() / 2);
        assert!(matches!(member.process_commit_judged("s", &torn, |_| Verdict::Accept), Err(CommitError::Other(_))));
    }

    /// A Welcome held for our view is a seat on its way, so nothing asks for another
    /// leaf meanwhile; it keeps our KeyPackage until it installs or is refused.
    #[test]
    fn a_held_welcome_is_a_seat_on_its_way_and_keeps_our_key_package() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut member, _) = bound(3, 4);
        assert_eq!(member.seat("s"), Seat::Missing);
        let (_, welcome) = owner.add_member("s", &member.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();

        assert_eq!(member.join_from_welcome_judged("s", &welcome, |_| Verdict::Hold("roster".into())).unwrap(),
            Verdict::Hold("roster".into()));
        assert_eq!(member.seat("s"), Seat::WelcomeWaits, "a held Welcome left us asking for another leaf");
        assert!(member.names_our_key_package(&welcome), "holding the Welcome spent our KeyPackage");
        assert_eq!(member.retry_held_welcome("s", |_| Verdict::Accept), Some(Ok(Verdict::Accept)));
        assert_eq!(member.seat("s"), Seat::Held);
    }

    /// A Welcome that replaces a held one keeps the first one's wait, so a stream of
    /// refreshed Welcomes cannot hold a seat open past the bound.
    #[test]
    fn a_held_welcome_replaced_by_another_keeps_its_bound() {
        let (mut member, _) = bound(3, 4);
        let mut welcome_from = |tags: (u8, u8)| {
            let (mut owner, _) = bound(tags.0, tags.1);
            owner.create_group("s").unwrap();
            let (_, welcome) = owner.add_member("s", &member.generate_key_package().unwrap()).unwrap();
            welcome
        };
        let (first, second) = (welcome_from((1, 2)), welcome_from((5, 6)));
        let hold = |_: &WelcomeFacts| Verdict::Hold("roster".into());
        assert!(matches!(member.join_from_welcome_judged("s", &first, hold).unwrap(), Verdict::Hold(_)));
        let held = member.held_welcomes.get_mut("s").unwrap();
        held.since = held.since.checked_sub(HELD_MAX_AGE).unwrap();
        assert!(matches!(member.join_from_welcome_judged("s", &second, hold).unwrap(), Verdict::Hold(_)));
        assert!(member.welcome_waits("s"));
        assert_eq!(member.retry_held_welcome("s", |_| Verdict::Accept), Some(Ok(Verdict::Refuse("held too long".into()))),
            "a refreshed Welcome kept the seat waiting past the bound");
        assert!(!member.welcome_waits("s"));
    }
}

// md-review-mls
#[cfg(test)]
mod md_review_mls {
    use super::test_keys::bound;
    use super::*;

    /// A commit held while the cap is full is processed (its key spent) and then dropped
    /// with no lapsed record, so nothing ever calls for the repair it needs: the F1 fork.
    #[test]
    fn a_commit_dropped_at_the_held_cap_still_leaves_a_lapsed_record() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut member, member_id) = bound(3, 4);
        let mut committers: Vec<(MlsManager, String)> = (0..HELD_COMMITS_CAP as u8 + 1).map(|i| bound(20 + 2 * i, 21 + 2 * i)).collect();
        let mut kps = vec![(member_id, member.generate_key_package().unwrap())];
        for (c, id) in committers.iter_mut() {
            kps.push((id.clone(), c.generate_key_package().unwrap()));
        }
        let (_, welcome, _) = owner.add_members_batch("s", &kps).unwrap();
        owner.merge_pending_commit("s").unwrap();
        member.join_from_welcome("s", &welcome).unwrap();
        for (c, _) in committers.iter_mut() {
            c.join_from_welcome("s", &welcome).unwrap();
        }

        let mut last = Vec::new();
        for (i, (c, _)) in committers.iter_mut().enumerate() {
            let (commit, _) = c.add_member("s", &bound(100 + 2 * i as u8, 101 + 2 * i as u8).0.generate_key_package().unwrap()).unwrap();
            member.process_commit_judged("s", &commit, |_| Verdict::Hold("lag".into())).unwrap();
            last = commit;
        }
        assert_eq!(member.held_commits["s"].len(), HELD_COMMITS_CAP);
        assert!(member.process_commit_judged("s", &last, |_| Verdict::Accept).is_err(), "its key is spent");
        member.age_held_commits(HELD_MAX_AGE);
        member.retry_held_commit("s", |_| Verdict::Accept);
        let ninth = Some(super::test_keys::keypair(20 + 2 * HELD_COMMITS_CAP as u8).peer_id());
        let lapsed: Vec<Option<String>> =
            member.lapsed_commits.get("s").into_iter().flatten().map(|l| committer_key(&l.facts)).collect();
        assert!(lapsed.contains(&ninth), "the commit dropped at the cap left nothing to call for its repair: {lapsed:?}");
    }
}

/// G1 scale fixes 4 and 5: late frames open in kept past epochs, saves write rows.
#[cfg(test)]
mod g13_past_epochs_and_row_saves {
    use super::test_keys::bound;
    use super::*;

    /// An owner and a member seated in `group`.
    fn pair(group: &str) -> (MlsManager, MlsManager) {
        let (mut owner, _) = bound(1, 2);
        owner.create_group(group).unwrap();
        let (mut member, member_dev) = bound(3, 4);
        let kp = member.generate_key_package().unwrap();
        let (_, welcome, _) = owner.add_members_batch(group, &[(member_dev, kp)]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        member.join_from_welcome(group, &welcome).unwrap();
        (owner, member)
    }

    /// The owner adds one more device and merges; the member does not see it yet.
    fn owner_moves_on(owner: &mut MlsManager, group: &str, tag: u8) -> Vec<u8> {
        let (extra, dev) = bound(tag, tag + 1);
        let (commit, _, _) = owner.add_members_batch(group, &[(dev, extra.generate_key_package().unwrap())]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        commit
    }

    fn opens(mgr: &mut MlsManager, group: &str, ct: &[u8]) -> Option<Vec<u8>> {
        match mgr.decrypt_fresh(group, ct) {
            Ok(Decrypted::Fresh { plaintext, .. }) => Some(plaintext),
            _ => None,
        }
    }

    /// Fix 4: OpenMLS keeps no past epoch inside the live group, yet a frame sent
    /// at an epoch we merged past still opens, up to three epochs back, and once only.
    #[test]
    fn a_frame_from_a_merged_epoch_still_opens_up_to_three_epochs_back() {
        for group in ["srv-late", "srv-late#chan", "conf:late"] {
            let (mut owner, mut member) = pair(group);
            let mut late = Vec::new();
            for round in 0..4u8 {
                late.push(member.encrypt(group, format!("late {round}").as_bytes()).unwrap());
                let commit = owner_moves_on(&mut owner, group, 10 + 2 * round);
                member.process_commit(group, &commit).unwrap();
            }
            assert_eq!(owner.past_epochs(group).len(), MAX_PAST_EPOCHS_FOR_TEST, "{group}");
            assert!(opens(&mut owner, group, &late[0]).is_none(), "{group}: four epochs back is past the window");
            for (round, ct) in late.iter().enumerate().skip(1) {
                assert_eq!(opens(&mut owner, group, ct), Some(format!("late {round}").into_bytes()), "{group}");
                assert!(matches!(owner.decrypt_fresh(group, ct), Ok(Decrypted::Replay)), "{group}: a late frame opens once");
            }
            let live = member.encrypt(group, b"now").unwrap();
            assert_eq!(opens(&mut owner, group, &live), Some(b"now".to_vec()), "{group}");
            let gid = GroupId::from_slice(group.as_bytes());
            let key = super::super::mls_storage::row_key(super::super::mls_storage::label::MESSAGE_SECRETS, &gid);
            for (mgr, who) in [(&owner, "the creator"), (&member, "a joiner")] {
                let secrets = mgr.provider.storage().rows(std::slice::from_ref(&key));
                let stored: serde_json::Value = serde_json::from_slice(&secrets[0].1).unwrap();
                assert_eq!(stored["past_epoch_trees"], serde_json::json!([]), "{group}: {who}'s live group carries past epochs again");
            }
        }
    }

    const MAX_PAST_EPOCHS_FOR_TEST: usize = super::super::mls_past::MAX_PAST_EPOCHS;

    /// Fix 4 across a restart: the kept past epochs are stored and load back.
    #[test]
    fn a_late_frame_still_opens_after_a_restart() {
        let group = "srv-restart";
        let (mut owner, mut member) = pair(group);
        let mut disk = Disk::default();
        disk.land(owner.take_save().unwrap());
        let late = member.encrypt(group, b"sent before the commit").unwrap();
        let commit = owner_moves_on(&mut owner, group, 30);
        member.process_commit(group, &commit).unwrap();
        disk.land(owner.take_save().unwrap());
        let mut restored = disk.load(&[group]);
        assert_eq!(restored.past_epochs(group), owner.past_epochs(group));
        assert_eq!(opens(&mut restored, group, &late), Some(b"sent before the commit".to_vec()));
        // What the late frame consumed is saved too: the reloaded copy never opens it again.
        disk.land(restored.take_save().unwrap());
        let mut again = disk.load(&[group]);
        assert!(matches!(again.decrypt_fresh(group, &late), Ok(Decrypted::Replay)));
        let whole = again.take_whole_save().unwrap();
        let mut fresh = Disk::default();
        fresh.land(whole);
        assert!(matches!(fresh.load(&[group]).decrypt_fresh(group, &late), Ok(Decrypted::Replay)), "a whole save lost an override");
    }

    /// The `mls_storage` table as the saves landed on it, in memory.
    #[derive(Default)]
    struct Disk {
        table: std::collections::BTreeMap<(String, Vec<u8>), Vec<u8>>,
        identity: (Vec<u8>, Vec<u8>),
    }

    impl Disk {
        fn land(&mut self, save: MlsSave) {
            if let Some(keep) = &save.retain_only {
                self.table.retain(|(s, _), _| keep.contains(s));
            }
            for scope in &save.cleared {
                self.table.retain(|(s, _), _| s != scope);
            }
            for (s, k, v) in save.rows {
                match v {
                    Some(v) => self.table.insert((s, k), v),
                    None => self.table.remove(&(s, k)),
                };
            }
            self.identity = (save.signer, save.credential);
        }

        fn load(&self, groups: &[&str]) -> MlsManager {
            let rows = self.table.iter().map(|((s, k), v)| (s.clone(), k.clone(), v.clone())).collect();
            let keys: Vec<String> = groups.iter().map(|g| g.to_string()).collect();
            MlsManager::from_stored(&self.identity.0, &self.identity.1, None, rows, Vec::new(), &keys).unwrap()
        }
    }

    /// Fix 5: a send saves the one row its ratchet moved, not the store.
    #[test]
    fn a_send_saves_only_the_row_it_changed() {
        let group = "srv-rows";
        let (mut owner, _member) = pair(group);
        owner.create_group("srv-other").unwrap();
        let _ = owner.take_save().unwrap();
        owner.encrypt(group, &[b'x'; 512]).unwrap();
        let save = owner.take_save().unwrap();
        let gid = GroupId::from_slice(group.as_bytes());
        let secrets = super::super::mls_storage::row_key(super::super::mls_storage::label::MESSAGE_SECRETS, &gid);
        let keys: Vec<&Vec<u8>> = save.rows.iter().map(|(_, k, _)| k).collect();
        assert_eq!(keys, vec![&secrets], "a send saved more than its group's message secrets");
        assert!(save.cleared.is_empty() && !save.drop_blob);
        assert!(save.row_bytes() * 4 < owner.provider.storage().byte_len(), "the save is most of the store");
        assert!(owner.take_save().unwrap().rows.is_empty(), "nothing changed since");
    }

    /// The past store keeps none of the epoch secrets it never uses: its exporter is
    /// not that epoch's, and it holds no key that opens a commit.
    #[test]
    fn a_past_epoch_keeps_no_secret_it_does_not_need() {
        let group = "srv-scrub";
        let (mut owner, _member) = pair(group);
        let epoch = owner.epoch(group).unwrap();
        let exporter = owner.export_secret(group, "sframe", b"ctx", 32).unwrap();
        owner_moves_on(&mut owner, group, 40);
        let past_exporter = owner
            .past
            .open(group, epoch, |g, provider| g.export_secret(provider.crypto(), "sframe", b"ctx", 32).unwrap())
            .expect("the past epoch loads");
        assert_ne!(past_exporter, exporter, "the past store still derives that epoch's exporter");
        let save = owner.take_whole_save().unwrap();
        let scope = super::super::mls_storage::past_scope(group, epoch);
        let labels = [super::super::mls_storage::label::EPOCH_KEY_PAIRS, super::super::mls_storage::label::ENCRYPTION_KEY_PAIR];
        let packed = save.rows.iter().find(|(s, k, _)| *s == scope && k.starts_with(b"\0")).expect("the packed past epoch");
        let rows = super::super::mls_past::unpack(packed.2.as_ref().unwrap()).unwrap();
        assert!(!rows.is_empty());
        assert!(!rows.iter().any(|(k, _)| labels.iter().any(|l| k.starts_with(l))), "a past store holds a private key");
    }

    /// A pre-0.13 blob loads, and its first save writes every row and drops the blob.
    #[test]
    fn a_blob_store_loads_and_its_first_save_writes_every_row() {
        let group = "srv-blob";
        let (owner, _member) = pair(group);
        let blob = owner.serialize_storage().unwrap();
        let restored = MlsManager::from_persisted(
            &owner.signer_bytes().unwrap(),
            &owner.credential_bytes().unwrap(),
            Some(&blob),
            &[group.to_string()],
        )
        .unwrap();
        let first = restored.take_save().unwrap();
        assert!(first.drop_blob && first.cleared.contains(&String::new()));
        assert_eq!(first.rows.len(), restored.provider.storage().take_all().len());
        assert!(!restored.take_save().unwrap().drop_blob, "only the first save replaces the store");
    }

    /// A 0.12.2 database (the whole store in `mls_identity.storage_data`, no
    /// `mls_storage` table) opens, its groups (server, subgroup, meeting) all work, and
    /// the first save moves it to rows and empties the blob.
    #[test]
    fn a_0_12_2_database_moves_to_rows_and_every_group_still_works() {
        let groups = ["srv-old", "srv-old#locked", "conf:old"];
        let (mut owner, _) = bound(1, 2);
        let (mut member, member_dev) = bound(3, 4);
        for group in groups {
            owner.create_group(group).unwrap();
            let kp = member.generate_key_package().unwrap();
            let (_, welcome, _) = owner.add_members_batch(group, &[(member_dev.clone(), kp)]).unwrap();
            owner.merge_pending_commit(group).unwrap();
            member.join_from_welcome(group, &welcome).unwrap();
        }
        let tmp = crate::test_tmp::tempdir().unwrap();
        let key = "ab".repeat(32);
        let old = tmp.path().join("old.db").to_string_lossy().into_owned();
        {
            let store = crate::storage::MessageStore::open(&old, &key).unwrap();
            store
                .save_mls_identity(&owner.signer_bytes().unwrap(), &owner.credential_bytes().unwrap(), &owner.serialize_storage().unwrap())
                .unwrap();
            store.drop_mls_rows_table_for_test();
        }
        let copy = tmp.path().join("copy.db").to_string_lossy().into_owned();
        std::fs::copy(&old, &copy).unwrap();
        let keys: Vec<String> = groups.iter().map(|g| g.to_string()).collect();
        let store = crate::storage::MessageStore::open(&copy, &key).unwrap();
        let mut loaded = MlsManager::load_from(&store, &keys).unwrap().expect("the 0.12.2 identity loads");
        let save = loaded.take_save().unwrap();
        assert!(save.drop_blob, "the first save after the upgrade must replace the blob");
        store.save_mls_state(&save).unwrap();
        assert_eq!(store.load_mls_identity().unwrap().unwrap().2, None, "the blob outlived the move to rows");
        for group in groups {
            let ct = loaded.encrypt(group, group.as_bytes()).unwrap();
            assert_eq!(opens(&mut member, group, &ct), Some(group.as_bytes().to_vec()), "{group}");
        }
        store.save_mls_state(&loaded.take_save().unwrap()).unwrap();
        let mut again = MlsManager::load_from(&store, &keys).unwrap().unwrap();
        for group in groups {
            let back = member.encrypt(group, b"back").unwrap();
            assert_eq!(opens(&mut again, group, &back), Some(b"back".to_vec()), "{group} after a reload from rows");
            let ct = again.encrypt(group, b"next").unwrap();
            assert_eq!(opens(&mut member, group, &ct), Some(b"next".to_vec()), "{group}: the reload reused a sent generation");
        }
    }

    /// A push fetch loads one server: it reads only that server's past epochs, its
    /// saves (whole ones too) leave the other servers' alone, and a node that forgets
    /// a group it no longer loads erases that group's past epochs with it.
    #[test]
    fn a_partial_load_leaves_other_groups_past_epochs_alone() {
        let (mut owner, _) = bound(1, 2);
        for (group, tag) in [("srv-a", 50u8), ("srv-b", 60u8)] {
            owner.create_group(group).unwrap();
            owner_moves_on(&mut owner, group, tag);
        }
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let store = crate::storage::MessageStore::open(&path, &"ab".repeat(32)).unwrap();
        store.save_mls_state(&owner.take_whole_save().unwrap()).unwrap();
        let b_rows = |store: &crate::storage::MessageStore| {
            store.load_mls_rows().unwrap().iter().filter(|(scope, _, _)| scope.ends_with(":srv-b")).count()
        };
        let stored_b = b_rows(&store);
        assert!(stored_b > 0);

        let fetch = MlsManager::load_from(&store, &["srv-a".to_string()]).unwrap().unwrap();
        assert!(!fetch.past_epochs("srv-a").is_empty());
        assert!(fetch.past_epochs("srv-b").is_empty(), "a fetch read another server's past epochs");
        store.save_mls_state(&fetch.take_whole_save().unwrap()).unwrap();
        assert_eq!(b_rows(&store), stored_b, "a fetch's save touched another server's past epochs");

        // A past epoch dropped by a save that never landed: the whole save after it erases it.
        let mut node = MlsManager::load_from(&store, &["srv-a".to_string(), "srv-b".to_string()]).unwrap().unwrap();
        node.remove_group("srv-a");
        let _lost = node.take_save().unwrap();
        store.save_mls_state(&node.take_whole_save().unwrap()).unwrap();
        let a_left = store.load_mls_rows().unwrap().iter().filter(|(s, _, _)| s.ends_with(":srv-a")).count();
        assert_eq!(a_left, 0, "a dropped past epoch outlived the whole save after a lost one");
        assert_eq!(b_rows(&store), stored_b);
        store.save_mls_state(&owner.take_whole_save().unwrap()).unwrap();

        assert!(scope_wanted("", &["srv-a".to_string()]) && scope_wanted("past:3:srv-a", &["srv-a".to_string()]));
        assert!(!scope_wanted("past:3:srv-b", &["srv-a".to_string()]), "a fetch reads another server's past epochs");
        // A past epoch whose group is stored nowhere else goes too.
        let stray = super::super::mls_storage::past_scope("srv-stray", 4);
        let (signer, credential) = (owner.signer_bytes().unwrap(), owner.credential_bytes().unwrap());
        let rows = vec![(stray.clone(), b"\0packed".to_vec(), Some(b"x".to_vec()))];
        store.save_mls_state(&MlsSave { signer, credential, rows, ..Default::default() }).unwrap();
        let mut node = MlsManager::load_from(&store, &["srv-a".to_string()]).unwrap().unwrap();
        let forgotten = node.forget_unloaded_groups(&[]);
        assert!(forgotten.contains(&"srv-b".to_string()) && forgotten.contains(&"srv-stray".to_string()), "{forgotten:?}");
        store.save_mls_state(&node.take_save().unwrap()).unwrap();
        assert_eq!(b_rows(&store), 0, "a forgotten group's past epochs outlived it");
        assert!(!store.load_mls_rows().unwrap().iter().any(|(s, _, _)| *s == stray), "a stray past epoch outlived its forget");
    }

    /// A group's past epochs go with it: removed, or replaced by a Welcome.
    #[test]
    fn a_group_that_goes_takes_its_past_epochs_along() {
        let group = "srv-gone";
        let (mut owner, mut member) = pair(group);
        let commit = owner_moves_on(&mut owner, group, 70);
        member.process_commit(group, &commit).unwrap();
        assert!(!member.past_epochs(group).is_empty());
        let _ = member.take_save().unwrap();
        let (mut owner2, _) = bound(9, 10);
        owner2.create_group(group).unwrap();
        let kp = member.generate_key_package().unwrap();
        let id = MlsManager::key_package_identity(&kp).unwrap().id().to_string();
        let (_, welcome, _) = owner2.add_members_batch(group, &[(id, kp)]).unwrap();
        owner2.merge_pending_commit(group).unwrap();
        member.join_from_welcome(group, &welcome).unwrap();
        assert!(member.past_epochs(group).is_empty(), "a Welcome kept the replaced group's past epochs");
        let cleared = |save: MlsSave| save.cleared.iter().any(|s| s.ends_with(&format!(":{group}")));
        assert!(cleared(member.take_save().unwrap()), "the stored past epoch outlived the replaced group");

        let commit = owner_moves_on(&mut owner2, group, 72);
        member.process_commit(group, &commit).unwrap();
        assert!(!member.past_epochs(group).is_empty());
        let _ = member.take_save().unwrap();
        member.remove_group(group);
        assert!(member.past_epochs(group).is_empty());
        assert!(cleared(member.take_save().unwrap()), "the stored past epoch outlived its removed group");
    }
}

/// g13-s2 fix round: what a past copy holds, row by row, on every path that keeps one.
#[cfg(test)]
mod g13_past_copy_contents {
    use super::super::mls_storage::{label, past_scope, row_key, Rows};
    use super::test_keys::bound;
    use super::*;
    use std::collections::HashSet;

    fn pair(group: &str) -> (MlsManager, MlsManager) {
        let (mut owner, _) = bound(1, 2);
        owner.create_group(group).unwrap();
        let (mut member, member_dev) = bound(3, 4);
        let kp = member.generate_key_package().unwrap();
        let (_, welcome, _) = owner.add_members_batch(group, &[(member_dev, kp)]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        member.join_from_welcome(group, &welcome).unwrap();
        (owner, member)
    }

    fn kp_of(tag: u8) -> (String, Vec<u8>) {
        let (extra, dev) = bound(tag, tag + 1);
        (dev, extra.generate_key_package().unwrap())
    }

    /// Every byte string of 16 or more bytes under a JSON row.
    fn byte_strings(row: &[u8]) -> HashSet<Vec<u8>> {
        fn walk(v: &serde_json::Value, out: &mut HashSet<Vec<u8>>) {
            match v {
                serde_json::Value::Array(items) if items.len() >= 16 && items.iter().all(|i| i.is_u64()) => {
                    out.insert(items.iter().map(|i| i.as_u64().unwrap() as u8).collect());
                }
                serde_json::Value::Array(items) => items.iter().for_each(|i| walk(i, out)),
                serde_json::Value::Object(m) => m.values().for_each(|i| walk(i, out)),
                _ => {}
            }
        }
        let mut out = HashSet::new();
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(row) {
            walk(&v, &mut out);
        }
        out.retain(|b| b.iter().any(|x| *x != 0));
        out
    }

    /// The secrets in `mgr`'s live store a past copy must never hold: the epoch secrets
    /// (but the authenticator), the message secrets and every private key.
    fn live_secrets(mgr: &MlsManager, group: &str) -> HashSet<Vec<u8>> {
        let gid = GroupId::from_slice(group.as_bytes());
        let storage = mgr.provider.storage();
        let mut out = HashSet::new();
        for (_, row) in storage.rows(&[row_key(label::EPOCH_SECRETS, &gid)]) {
            let mut v: serde_json::Value = serde_json::from_slice(&row).unwrap();
            v.as_object_mut().unwrap().remove("epoch_authenticator");
            out.extend(byte_strings(&serde_json::to_vec(&v).unwrap()));
        }
        for (_, row) in storage.rows(&[row_key(label::MESSAGE_SECRETS, &gid)]) {
            out.extend(byte_strings(&row));
        }
        for prefix in [label::EPOCH_KEY_PAIRS, label::ENCRYPTION_KEY_PAIR] {
            for (_, row) in storage.rows(&storage.keys_with_prefix(prefix)) {
                out.extend(private_halves(&row));
            }
        }
        assert!(!out.is_empty());
        out
    }

    /// The byte strings under every `private*` field of a key-pair row.
    fn private_halves(row: &[u8]) -> HashSet<Vec<u8>> {
        fn walk(v: &serde_json::Value, out: &mut HashSet<Vec<u8>>) {
            match v {
                serde_json::Value::Object(m) => {
                    for (k, x) in m {
                        if k.starts_with("private") {
                            out.extend(byte_strings(&serde_json::to_vec(x).unwrap()));
                        } else {
                            walk(x, out);
                        }
                    }
                }
                serde_json::Value::Array(items) => items.iter().for_each(|i| walk(i, out)),
                _ => {}
            }
        }
        let mut out = HashSet::new();
        walk(&serde_json::from_slice(row).unwrap(), &mut out);
        out
    }

    /// The rows of `mgr`'s past copy of `epoch`: the packed ones, then the plain ones.
    fn copy_rows(mgr: &MlsManager, group: &str, epoch: u64) -> (Rows, Rows) {
        let save = mgr.take_whole_save().unwrap();
        let scope = past_scope(group, epoch);
        let mine: Vec<_> = save.rows.into_iter().filter(|(s, _, _)| *s == scope).map(|(_, k, v)| (k, v.unwrap())).collect();
        let (packed, plain): (Rows, Rows) = mine.into_iter().partition(|(k, _)| k.starts_with(b"\0"));
        (super::super::mls_past::unpack(&packed.first().expect("a packed copy").1).unwrap(), plain)
    }

    fn check(mgr: &MlsManager, group: &str, epoch: u64, forbidden: &HashSet<Vec<u8>>, who: &str) {
        let gid = GroupId::from_slice(group.as_bytes());
        let (packed, plain) = copy_rows(mgr, group, epoch);
        let allowed: Vec<Vec<u8>> = [
            label::TREE, label::GROUP_CONTEXT, label::INTERIM_TRANSCRIPT_HASH, label::CONFIRMATION_TAG,
            label::JOIN_CONFIG, label::OWN_LEAF_NODES, label::GROUP_STATE, label::OWN_LEAF_NODE_INDEX,
            label::EPOCH_SECRETS, label::RESUMPTION_PSK,
        ]
        .iter()
        .map(|l| row_key(l, &gid))
        .collect();
        for (k, _) in &packed {
            assert!(allowed.contains(k), "{who}: the packed copy holds a row it never needs: {}", String::from_utf8_lossy(k));
        }
        assert_eq!(plain.iter().map(|(k, _)| k.clone()).collect::<Vec<_>>(), vec![row_key(label::MESSAGE_SECRETS, &gid)], "{who}: only the message secrets stay out of the packed copy");
        let state = packed.iter().find(|(k, _)| *k == row_key(label::GROUP_STATE, &gid)).unwrap();
        assert_eq!(state.1, serde_json::to_vec(&MlsGroupState::Operational).unwrap(), "{who}: the copy keeps a staged commit");
        for (k, row) in packed.iter().chain(plain.iter()) {
            let leaked: Vec<_> = byte_strings(row).intersection(forbidden).cloned().collect();
            assert!(leaked.is_empty(), "{who}: {} holds {} secret(s) of a later epoch or a private key", String::from_utf8_lossy(k), leaked.len());
        }
    }

    /// The committer's, a receiver's and a receiver with its own commit pending (glare):
    /// none of their copies holds a secret it does not need to open a frame of that
    /// epoch, and none holds a later epoch's secret or a private key.
    #[test]
    fn every_past_copy_holds_only_what_opening_a_frame_needs() {
        let group = "srv-contents";
        let (mut owner, mut member) = pair(group);
        let e = owner.epoch(group).unwrap();
        let mut forbidden_owner = HashSet::new();
        let mut before = live_secrets(&owner, group);
        let secrets_e = row_key(label::MESSAGE_SECRETS, &GroupId::from_slice(group.as_bytes()));
        let msg_e = owner.provider.storage().rows(&[secrets_e.clone()]).into_iter().flat_map(|(_, r)| byte_strings(&r)).collect::<HashSet<_>>();
        before.retain(|b| !msg_e.contains(b));
        let (commit, _, _) = owner.add_members_batch(group, &[kp_of(20)]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        forbidden_owner.extend(before);
        forbidden_owner.extend(live_secrets(&owner, group));
        check(&owner, group, e, &forbidden_owner, "the committer");

        // Glare: the member's own commit is pending when the owner's lands.
        let _pending = member.add_members_batch(group, &[kp_of(30)]).unwrap();
        member.process_commit(group, &commit).unwrap();
        let forbidden_member = live_secrets(&member, group);
        check(&member, group, e, &forbidden_member, "a receiver with its own commit pending");

        let (commit, _, _) = owner.add_members_batch(group, &[kp_of(40)]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        member.process_commit(group, &commit).unwrap();
        check(&member, group, e + 1, &live_secrets(&member, group), "a receiver");
    }

    /// An unpacked past epoch leaves RAM once idle, and nothing it learned is lost.
    #[test]
    fn an_idle_unpacked_past_epoch_is_let_go() {
        let group = "srv-idle";
        let (mut owner, mut member) = pair(group);
        let (one, two) = (member.encrypt(group, b"one").unwrap(), member.encrypt(group, b"two").unwrap());
        let (commit, _, _) = owner.add_members_batch(group, &[kp_of(50)]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        member.process_commit(group, &commit).unwrap();
        assert!(matches!(owner.decrypt_fresh(group, &one), Ok(Decrypted::Fresh { .. })));
        let _ = owner.take_save().unwrap();
        assert_eq!(owner.past.open_count(), 1);
        owner.past.age_open(std::time::Duration::from_secs(601));
        let _ = owner.take_save().unwrap();
        assert_eq!(owner.past.open_count(), 0, "an idle past epoch stayed unpacked");
        assert!(matches!(owner.decrypt_fresh(group, &two), Ok(Decrypted::Fresh { .. })));
        assert!(matches!(owner.decrypt_fresh(group, &one), Ok(Decrypted::Replay)), "the reopened copy forgot a consumed key");
    }

    fn opens(mgr: &mut MlsManager, group: &str, ct: &[u8]) -> bool {
        matches!(mgr.decrypt_fresh(group, ct), Ok(Decrypted::Fresh { .. }))
    }

    /// g13-s3 merge points: a member's self-update relayed by the committer (merged in
    /// the judged Accept branch) and its echo merging the member's own staged commit
    /// both keep the epoch they leave, so a frame sent at it still opens on each side,
    /// and the member's mid-merge copy keeps no staged commit.
    #[test]
    fn a_relayed_self_update_keeps_the_epoch_it_leaves_on_both_ends() {
        let group = "srv-turn";
        let (mut owner, mut member) = pair(group);
        let e = owner.epoch(group).unwrap();
        let from_member = member.encrypt(group, b"member at e").unwrap();
        let from_owner = owner.encrypt(group, b"owner at e").unwrap();
        let tally = super::super::mls_tally::Tally { refreshed_day: super::super::mls_tally::today(), epochs: vec![e], carried: vec![] };
        let commit = member.stage_self_update(group, &tally).unwrap();

        let mut relayed = false;
        let verdict = owner.process_commit_judged_then(group, &commit, |_| Verdict::Accept, || relayed = true).unwrap();
        assert!(relayed && verdict == Verdict::Accept);
        assert_eq!(owner.epoch(group).unwrap(), e + 1);
        assert_eq!(owner.past_epochs(group).last(), Some(&e), "the relayed merge kept no past epoch");
        assert!(opens(&mut owner, group, &from_member), "a frame from the epoch the relayed commit left no longer opens");

        assert_eq!(member.process_commit_judged(group, &commit, |_| Verdict::Refuse("not asked".into())).unwrap(), Verdict::Accept);
        assert_eq!(member.epoch(group).unwrap(), e + 1);
        assert_eq!(member.past_epochs(group), vec![e], "our own relayed self-update kept no past epoch");
        assert!(opens(&mut member, group, &from_owner), "a frame from the epoch our self-update left no longer opens");
        check(&member, group, e, &live_secrets(&member, group), "a member merging its own relayed self-update");
    }

    /// g13-s3 merge point: the committer refreshing its own leaf keeps the epoch it leaves.
    #[test]
    fn the_committers_own_self_update_keeps_the_epoch_it_leaves() {
        let group = "srv-own-turn";
        let (mut owner, mut member) = pair(group);
        let e = owner.epoch(group).unwrap();
        let from_member = member.encrypt(group, b"member at e").unwrap();
        let commit = owner.self_update_commit(group);
        assert_eq!(owner.past_epochs(group).last(), Some(&e));
        assert!(opens(&mut owner, group, &from_member));
        check(&owner, group, e, &live_secrets(&owner, group), "a committer merging its own self-update");
        member.process_commit(group, &commit).unwrap();
        assert_eq!(member.epoch_auth_digest(group), owner.epoch_auth_digest(group));
    }
}

#[cfg(test)]
/// Hostile review proofs (g13-s2 fix round).
mod g13_review_proofs {
    use super::test_keys::bound;
    use super::*;

    fn pair(group: &str) -> (MlsManager, MlsManager) {
        let (mut owner, _) = bound(1, 2);
        owner.create_group(group).unwrap();
        let (mut member, member_dev) = bound(3, 4);
        let kp = member.generate_key_package().unwrap();
        let (_, welcome, _) = owner.add_members_batch(group, &[(member_dev, kp)]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        member.join_from_welcome(group, &welcome).unwrap();
        (owner, member)
    }

    fn owner_moves_on(owner: &mut MlsManager, group: &str, tag: u8) -> Vec<u8> {
        let (extra, dev) = bound(tag, tag + 1);
        let (commit, _, _) = owner.add_members_batch(group, &[(dev, extra.generate_key_package().unwrap())]).unwrap();
        owner.merge_pending_commit(group).unwrap();
        commit
    }

    fn find<'a>(v: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
        match v {
            serde_json::Value::Object(m) => m.get(key).or_else(|| m.values().find_map(|x| find(x, key))),
            serde_json::Value::Array(a) => a.iter().find_map(|x| find(x, key)),
            _ => None,
        }
    }

    /// A committer's past copy of epoch E must not carry epoch E+1's secrets: while the
    /// live group is at E+1 or later, the copy must not hold E+1's exporter (SFrame key)
    /// nor E+1's un-ratcheted message secrets.
    #[test]
    fn a_committers_past_copy_holds_no_next_epoch_secret() {
        let group = "srv-review";
        let (mut owner, mut member) = pair(group);
        let e = owner.epoch(group).unwrap();
        let commit = owner_moves_on(&mut owner, group, 20); // owner now at e+1
        member.process_commit(group, &commit).unwrap();
        let gid = GroupId::from_slice(group.as_bytes());
        let live_secrets = owner.provider.storage().rows(&[super::super::mls_storage::row_key(super::super::mls_storage::label::EPOCH_SECRETS, &gid)]);
        let live: serde_json::Value = serde_json::from_slice(&live_secrets[0].1).unwrap();
        owner_moves_on(&mut owner, group, 30);
        owner_moves_on(&mut owner, group, 40); // owner now at e+3, the e copy still held
        assert!(owner.past_epochs(group).contains(&e));

        let pending = owner.past.open(group, e, |g, _| g.pending_commit().is_some()).unwrap();
        let save = owner.take_whole_save().unwrap();
        let scope = super::super::mls_storage::past_scope(group, e);
        let packed = save.rows.iter().find(|(s, k, _)| *s == scope && k.starts_with(b"\0")).unwrap();
        let rows = super::super::mls_past::unpack(packed.2.as_ref().unwrap()).unwrap();
        let state_key = super::super::mls_storage::row_key(super::super::mls_storage::label::GROUP_STATE, &gid);
        let state: serde_json::Value = serde_json::from_slice(&rows.iter().find(|(k, _)| *k == state_key).unwrap().1).unwrap();
        let staged_exporter = find(&state, "group_epoch_secrets").and_then(|s| s.get("exporter_secret")).cloned();
        let has_keypairs = find(&state, "new_keypairs").is_some();
        let has_msg = find(&state, "message_secrets").is_some();
        let _ = (has_keypairs, has_msg);
        assert!(!pending, "the past copy of epoch {e} still holds our staged commit to epoch {}", e + 1);
        assert_ne!(staged_exporter.as_ref(), live.get("exporter_secret"), "the past copy on disk holds epoch e+1's exporter secret");
    }

    /// Upgrade to 0.13, downgrade to 0.12.2 (which writes the blob and never reads the
    /// rows), upgrade again: the newer blob must win over the stale rows.
    #[test]
    fn a_blob_written_after_a_downgrade_wins_over_stale_rows() {
        let group = "srv-downgrade";
        let (mut owner, mut member) = pair(group);
        // A second group with past epochs, which the second upgrade's load does not name.
        owner.create_group("srv-unnamed").unwrap();
        owner_moves_on(&mut owner, "srv-unnamed", 60);
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("d.db").to_string_lossy().into_owned();
        let store = crate::storage::MessageStore::open(&path, &"ab".repeat(32)).unwrap();
        store.save_mls_state(&owner.take_whole_save().unwrap()).unwrap(); // 0.13 run
        for i in 0..3u8 {
            let ct = owner.encrypt(group, &[i]).unwrap();
            assert!(matches!(member.decrypt_fresh(group, &ct), Ok(Decrypted::Fresh { .. })));
        }
        // 0.12.2 run after a downgrade: the whole store in the blob, rows untouched.
        store.save_mls_identity(&owner.signer_bytes().unwrap(), &owner.credential_bytes().unwrap(), &owner.serialize_storage().unwrap()).unwrap();
        let mut again = MlsManager::load_from(&store, &[group.to_string()]).unwrap().unwrap();
        let ct = again.encrypt(group, b"after the second upgrade").unwrap();
        assert!(
            matches!(member.decrypt_fresh(group, &ct), Ok(Decrypted::Fresh { .. })),
            "the stale 0.13 rows overrode the newer blob: the send ratchet went back"
        );
        store.save_mls_state(&again.take_save().unwrap()).unwrap();
        let stale = store.load_mls_rows().unwrap().into_iter().filter(|(s, _, _)| s.ends_with(":srv-unnamed")).count();
        assert_eq!(stale, 0, "the first save after the blob kept stale past epochs of a group it did not load");
    }
}

#[cfg(test)]
/// g13-s3 review 2, M1: admissions to an open meeting batch every due knock into one
/// commit, which OpenMLS judges whole.
mod g13_s3_admissions {
    use super::test_keys::bound;
    use super::*;

    /// A KeyPackage that passes alone (signature, binding) but that no group admits:
    /// its leaf does not list the Basic credential it carries.
    fn poisoned(tag: u8) -> (String, Vec<u8>) {
        let (m, dev) = bound(tag, tag + 1);
        let caps = Capabilities::builder()
            .credentials(vec![CredentialType::X509])
            .extensions(vec![super::super::mls_tally::tally_extension_type()])
            .build();
        let bundle = KeyPackage::builder()
            .leaf_node_capabilities(caps)
            .build(CIPHERSUITE, &m.provider, &m.signer, m.credential_with_key.clone())
            .unwrap();
        (dev, TlsSerialize::tls_serialize_detached(bundle.key_package()).unwrap())
    }

    #[test]
    fn one_poisoned_knock_never_blocks_the_others() {
        let group = "conf:poison";
        let (mut host, _) = bound(1, 2);
        host.create_group(group).unwrap();
        let mut guests: Vec<(MlsManager, String)> = [10u8, 12, 14].into_iter().map(|t| bound(t, t + 1)).collect();
        let honest: Vec<(String, Vec<u8>)> = guests.iter().map(|(m, d)| (d.clone(), m.generate_key_package().unwrap())).collect();
        let bad = poisoned(20);
        let knocks = vec![honest[0].clone(), bad.clone(), honest[1].clone(), honest[2].clone()];
        assert!(host.commit_membership_as(group, &[], &knocks, true).is_err(), "the batch with the poisoned package fails whole");
        assert!(host.groups_with_pending_commit().is_empty());

        let epoch = host.epoch(group).unwrap();
        let done = host.commit_admissions(group, &knocks, true).expect("the honest knocks are seated");
        let mut want: Vec<String> = honest.iter().map(|(d, _)| d.clone()).collect();
        let mut got = done.added.clone();
        want.sort();
        got.sort();
        assert_eq!(got, want);
        host.merge_pending_commit(group).unwrap();
        assert_eq!(host.epoch(group).unwrap(), epoch + 1, "one commit seats them all");
        assert!(!host.group_members(group).contains(&bad.0));
        let welcome = done.welcome.unwrap();
        for (guest, _) in guests.iter_mut() {
            guest.join_from_welcome(group, &welcome).unwrap();
            assert_eq!(guest.epoch_auth_digest(group), host.epoch_auth_digest(group));
        }
    }
}

#[cfg(test)]
mod standing_tests {
    use super::test_keys::bound;

    /// Unit 13: the exact package that seated a device reads as seated (the KeyPackage
    /// arm drops it); a fresh one of the same device is a repair.
    #[test]
    fn a_key_package_that_already_seats_its_device_reads_seated() {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (joiner, jdev) = bound(3, 4);
        let kp = joiner.generate_key_package_for("s", false).unwrap();
        assert!(!owner.key_package_seated("s", &kp));
        owner.commit_membership("s", &[], &[(jdev, kp.clone())]).unwrap();
        owner.merge_pending_commit("s").unwrap();
        assert!(owner.key_package_seated("s", &kp));
        let fresh = joiner.generate_key_package_for("s", false).unwrap();
        assert!(!owner.key_package_seated("s", &fresh), "a fresh package of the same device is a repair");
        assert!(!owner.key_package_seated("other", &kp), "no group, nothing seated");
    }

    /// The test knob makes a device mint 0.12.2-shaped leaves; normally every leaf declares.
    #[test]
    fn key_packages_declare_the_tally_unless_the_old_leaf_knob_is_set() {
        use crate::node::standing::knobs::{set, Knob};
        let (owner, _) = bound(5, 6);
        let (old, old_dev) = bound(7, 8);
        assert!(owner.key_package_declares(&old.generate_key_package_for("s", false).unwrap()));
        set(Knob::OldLeaf, &old_dev, true);
        let kp = old.generate_key_package_for("s", false);
        set(Knob::OldLeaf, &old_dev, false);
        assert!(!owner.key_package_declares(&kp.unwrap()));
    }
}
