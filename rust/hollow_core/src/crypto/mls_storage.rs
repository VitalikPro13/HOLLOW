//! The MLS provider's store, saved by rows. OpenMLS keeps every group of every
//! server in one key-value map; a save writes only the rows that changed since the
//! last one, where it used to write the whole map on every sent message (5 MB per
//! send at a 1k server, G1 scale probe fix 5).
//!
//! The map itself stays `openmls_memory_storage`'s, so its keys, values and the
//! pre-0.13 whole-store blob keep their format. Every write is delegated to it and
//! the row keys it touches are noted; tests check after each write that no other row
//! changed, so a key shape that drifts fails every MLS test instead of a save.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use openmls_memory_storage::{MemoryStorage, MemoryStorageError};
use openmls_rust_crypto::RustCrypto;
use openmls_traits::storage::{traits, StorageProvider, CURRENT_VERSION};
use openmls_traits::OpenMlsProvider;
use serde::Serialize;

/// The scope of the live store's rows; a past epoch's rows carry [`past_scope`].
pub(crate) const LIVE_SCOPE: &str = "";

/// The scope of a past epoch's rows. The group key may itself contain ':' (a
/// meeting's `conf:{id}`), the epoch never does.
pub(crate) fn past_scope(group_key: &str, epoch: u64) -> String {
    format!("past:{epoch}:{group_key}")
}

/// The group key and epoch a past scope names.
pub(crate) fn parse_past_scope(scope: &str) -> Option<(String, u64)> {
    let (epoch, group_key) = scope.strip_prefix("past:")?.split_once(':')?;
    Some((group_key.to_string(), epoch.parse().ok()?))
}

/// Stored rows of one store, `(key, value)`.
pub(crate) type Rows = Vec<(Vec<u8>, Vec<u8>)>;

/// Each stored past epoch's rows, by `(group key, epoch)`.
pub(crate) type PastRows = HashMap<(String, u64), Rows>;

/// One save of the MLS store, written by the CryptoStore in one transaction.
#[derive(Debug, Default)]
pub(crate) struct MlsSave {
    /// [`super::MlsManager::taken`] for this save: it holds every change made before it.
    pub take: u64,
    pub signer: Vec<u8>,
    pub credential: Vec<u8>,
    /// Scopes emptied before `rows` are written: a whole-store save, a dropped past epoch.
    pub cleared: Vec<String>,
    /// `(scope, key, value)`; `None` deletes the row.
    pub rows: Vec<(String, Vec<u8>, Option<Vec<u8>>)>,
    /// The rows hold everything: the pre-0.13 whole-store blob goes.
    pub drop_blob: bool,
    /// A whole save: every stored scope not named here is erased (a past epoch dropped
    /// by a save that never landed).
    pub retain_only: Option<Vec<String>>,
}

impl MlsSave {
    /// Bytes of group state this save writes.
    #[cfg(test)]
    pub fn row_bytes(&self) -> usize {
        self.rows.iter().map(|(_, k, v)| k.len() + v.as_ref().map_or(0, Vec::len)).sum()
    }
}

/// `openmls_memory_storage` 0.6 key labels. A row key is the label, the JSON of the
/// key, then the two-byte storage version.
pub(crate) mod label {
    pub const KEY_PACKAGE: &[u8] = b"KeyPackage";
    pub const PSK: &[u8] = b"Psk";
    pub const ENCRYPTION_KEY_PAIR: &[u8] = b"EncryptionKeyPair";
    pub const SIGNATURE_KEY_PAIR: &[u8] = b"SignatureKeyPair";
    pub const EPOCH_KEY_PAIRS: &[u8] = b"EpochKeyPairs";
    pub const TREE: &[u8] = b"Tree";
    pub const GROUP_CONTEXT: &[u8] = b"GroupContext";
    pub const INTERIM_TRANSCRIPT_HASH: &[u8] = b"InterimTranscriptHash";
    pub const CONFIRMATION_TAG: &[u8] = b"ConfirmationTag";
    pub const JOIN_CONFIG: &[u8] = b"MlsGroupJoinConfig";
    pub const OWN_LEAF_NODES: &[u8] = b"OwnLeafNodes";
    pub const GROUP_STATE: &[u8] = b"GroupState";
    pub const QUEUED_PROPOSAL: &[u8] = b"QueuedProposal";
    pub const PROPOSAL_QUEUE_REFS: &[u8] = b"ProposalQueueRefs";
    pub const OWN_LEAF_NODE_INDEX: &[u8] = b"OwnLeafNodeIndex";
    pub const EPOCH_SECRETS: &[u8] = b"EpochSecrets";
    pub const RESUMPTION_PSK: &[u8] = b"ResumptionPsk";
    pub const MESSAGE_SECRETS: &[u8] = b"MessageSecrets";
}

fn json<K: Serialize + ?Sized>(key: &K) -> Vec<u8> {
    serde_json::to_vec(key).unwrap_or_default()
}

fn raw_row_key(label: &[u8], key_json: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(label.len() + key_json.len() + 2);
    out.extend_from_slice(label);
    out.extend_from_slice(key_json);
    out.extend_from_slice(&CURRENT_VERSION.to_be_bytes());
    out
}

/// The row key `label` and `key` name.
pub(crate) fn row_key<K: Serialize + ?Sized>(label: &[u8], key: &K) -> Vec<u8> {
    raw_row_key(label, &json(key))
}

/// An OpenMLS store that notes which rows each write touched.
#[derive(Debug, Default)]
pub(crate) struct TrackedStorage {
    inner: MemoryStorage,
    dirty: Mutex<HashSet<Vec<u8>>>,
}

impl TrackedStorage {
    fn track<R>(&self, keys: Vec<Vec<u8>>, op: impl FnOnce(&MemoryStorage) -> R) -> R {
        #[cfg(test)]
        let before = verify::enabled().then(|| self.values().clone());
        let out = op(&self.inner);
        #[cfg(test)]
        if let Some(before) = before {
            verify::only_these_changed(&before, &self.values(), &keys);
        }
        self.dirty.lock().unwrap_or_else(|e| e.into_inner()).extend(keys);
        out
    }

    fn values(&self) -> std::sync::RwLockReadGuard<'_, HashMap<Vec<u8>, Vec<u8>>> {
        self.inner.values.read().unwrap_or_else(|e| e.into_inner())
    }

    fn values_mut(&self) -> std::sync::RwLockWriteGuard<'_, HashMap<Vec<u8>, Vec<u8>>> {
        self.inner.values.write().unwrap_or_else(|e| e.into_inner())
    }

    /// Rows as they are on disk: nothing to save.
    pub fn load_rows(&self, rows: impl IntoIterator<Item = (Vec<u8>, Vec<u8>)>) {
        self.values_mut().extend(rows);
    }

    /// Rows as they are on disk laid over the store: an empty value deletes the row.
    pub fn lay_over(&self, rows: impl IntoIterator<Item = (Vec<u8>, Vec<u8>)>) {
        let mut values = self.values_mut();
        for (k, v) in rows {
            if v.is_empty() {
                values.remove(&k);
            } else {
                values.insert(k, v);
            }
        }
    }

    /// The rows changed since the last take, each with its value now (`None`: gone).
    pub fn take_changes(&self) -> Vec<(Vec<u8>, Option<Vec<u8>>)> {
        let dirty = std::mem::take(&mut *self.dirty.lock().unwrap_or_else(|e| e.into_inner()));
        let values = self.values();
        dirty.into_iter().map(|k| { let v = values.get(&k).cloned(); (k, v) }).collect()
    }

    /// Every row, for a save that replaces what is stored.
    pub fn take_all(&self) -> Rows {
        self.dirty.lock().unwrap_or_else(|e| e.into_inner()).clear();
        self.values().iter().map(|(k, v)| (k.clone(), v.clone())).collect()
    }

    /// The rows present among `keys`.
    pub fn rows(&self, keys: &[Vec<u8>]) -> Rows {
        let values = self.values();
        keys.iter().filter_map(|k| values.get(k).map(|v| (k.clone(), v.clone()))).collect()
    }

    /// The keys that start with `prefix`.
    pub fn keys_with_prefix(&self, prefix: &[u8]) -> Vec<Vec<u8>> {
        self.values().keys().filter(|k| k.starts_with(prefix)).cloned().collect()
    }

    /// Bytes held.
    #[cfg(test)]
    pub fn byte_len(&self) -> usize {
        self.values().iter().map(|(k, v)| k.len() + v.len()).sum()
    }

    /// The pre-0.13 whole-store blob: a count, then length-prefixed key/value pairs.
    #[cfg(test)]
    pub fn to_blob(&self) -> Vec<u8> {
        let values = self.values();
        let mut buf = Vec::new();
        buf.extend_from_slice(&(values.len() as u64).to_be_bytes());
        for (k, v) in values.iter() {
            buf.extend_from_slice(&(k.len() as u64).to_be_bytes());
            buf.extend_from_slice(&(v.len() as u64).to_be_bytes());
            buf.extend_from_slice(k);
            buf.extend_from_slice(v);
        }
        buf
    }
}

/// The rows of a pre-0.13 whole-store blob.
pub(crate) fn rows_from_blob(blob: &[u8]) -> Result<Rows, String> {
    fn take<'a>(rest: &mut &'a [u8], n: usize) -> Result<&'a [u8], String> {
        if rest.len() < n {
            return Err("MLS storage blob ends early".to_string());
        }
        let (head, tail) = rest.split_at(n);
        *rest = tail;
        Ok(head)
    }
    fn len(rest: &mut &[u8]) -> Result<usize, String> {
        let bytes: [u8; 8] = take(rest, 8)?.try_into().map_err(|_| "bad length".to_string())?;
        usize::try_from(u64::from_be_bytes(bytes)).map_err(|_| "MLS storage blob length overflows".to_string())
    }
    let mut rest = blob;
    let count = len(&mut rest)?;
    let mut rows = Vec::with_capacity(count.min(1 << 16));
    for _ in 0..count {
        let (k_len, v_len) = (len(&mut rest)?, len(&mut rest)?);
        let k = take(&mut rest, k_len)?.to_vec();
        let v = take(&mut rest, v_len)?.to_vec();
        rows.push((k, v));
    }
    Ok(rows)
}

/// OpenMLS's crypto with a [`TrackedStorage`].
#[derive(Debug, Default)]
pub(crate) struct MlsProvider {
    crypto: RustCrypto,
    storage: TrackedStorage,
}

impl OpenMlsProvider for MlsProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = TrackedStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

type Res<T> = Result<T, MemoryStorageError>;

impl StorageProvider<CURRENT_VERSION> for TrackedStorage {
    type Error = MemoryStorageError;

    fn write_mls_join_config<G: traits::GroupId<CURRENT_VERSION>, C: traits::MlsGroupJoinConfig<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        config: &C,
    ) -> Res<()> {
        self.track(vec![row_key(label::JOIN_CONFIG, group_id)], |s| s.write_mls_join_config(group_id, config))
    }

    fn append_own_leaf_node<G: traits::GroupId<CURRENT_VERSION>, L: traits::LeafNode<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        leaf_node: &L,
    ) -> Res<()> {
        self.track(vec![row_key(label::OWN_LEAF_NODES, group_id)], |s| s.append_own_leaf_node(group_id, leaf_node))
    }

    fn queue_proposal<
        G: traits::GroupId<CURRENT_VERSION>,
        R: traits::ProposalRef<CURRENT_VERSION>,
        Q: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &G,
        proposal_ref: &R,
        proposal: &Q,
    ) -> Res<()> {
        let keys = vec![
            row_key(label::QUEUED_PROPOSAL, &(group_id, proposal_ref)),
            row_key(label::PROPOSAL_QUEUE_REFS, group_id),
        ];
        self.track(keys, |s| s.queue_proposal(group_id, proposal_ref, proposal))
    }

    fn write_tree<G: traits::GroupId<CURRENT_VERSION>, T: traits::TreeSync<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        tree: &T,
    ) -> Res<()> {
        self.track(vec![row_key(label::TREE, group_id)], |s| s.write_tree(group_id, tree))
    }

    fn write_interim_transcript_hash<
        G: traits::GroupId<CURRENT_VERSION>,
        H: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &G,
        hash: &H,
    ) -> Res<()> {
        self.track(vec![row_key(label::INTERIM_TRANSCRIPT_HASH, group_id)], |s| {
            s.write_interim_transcript_hash(group_id, hash)
        })
    }

    fn write_context<G: traits::GroupId<CURRENT_VERSION>, C: traits::GroupContext<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        group_context: &C,
    ) -> Res<()> {
        self.track(vec![row_key(label::GROUP_CONTEXT, group_id)], |s| s.write_context(group_id, group_context))
    }

    fn write_confirmation_tag<G: traits::GroupId<CURRENT_VERSION>, C: traits::ConfirmationTag<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        confirmation_tag: &C,
    ) -> Res<()> {
        self.track(vec![row_key(label::CONFIRMATION_TAG, group_id)], |s| {
            s.write_confirmation_tag(group_id, confirmation_tag)
        })
    }

    fn write_group_state<S: traits::GroupState<CURRENT_VERSION>, G: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        group_state: &S,
    ) -> Res<()> {
        self.track(vec![row_key(label::GROUP_STATE, group_id)], |s| s.write_group_state(group_id, group_state))
    }

    fn write_message_secrets<G: traits::GroupId<CURRENT_VERSION>, M: traits::MessageSecrets<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        message_secrets: &M,
    ) -> Res<()> {
        self.track(vec![row_key(label::MESSAGE_SECRETS, group_id)], |s| {
            s.write_message_secrets(group_id, message_secrets)
        })
    }

    fn write_resumption_psk_store<G: traits::GroupId<CURRENT_VERSION>, R: traits::ResumptionPskStore<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        store: &R,
    ) -> Res<()> {
        self.track(vec![row_key(label::RESUMPTION_PSK, group_id)], |s| s.write_resumption_psk_store(group_id, store))
    }

    fn write_own_leaf_index<G: traits::GroupId<CURRENT_VERSION>, L: traits::LeafNodeIndex<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        own_leaf_index: &L,
    ) -> Res<()> {
        self.track(vec![row_key(label::OWN_LEAF_NODE_INDEX, group_id)], |s| {
            s.write_own_leaf_index(group_id, own_leaf_index)
        })
    }

    fn write_group_epoch_secrets<G: traits::GroupId<CURRENT_VERSION>, E: traits::GroupEpochSecrets<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        secrets: &E,
    ) -> Res<()> {
        self.track(vec![row_key(label::EPOCH_SECRETS, group_id)], |s| s.write_group_epoch_secrets(group_id, secrets))
    }

    fn write_signature_key_pair<
        P: traits::SignaturePublicKey<CURRENT_VERSION>,
        K: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &P,
        signature_key_pair: &K,
    ) -> Res<()> {
        self.track(vec![row_key(label::SIGNATURE_KEY_PAIR, public_key)], |s| {
            s.write_signature_key_pair(public_key, signature_key_pair)
        })
    }

    fn write_encryption_key_pair<E: traits::EncryptionKey<CURRENT_VERSION>, K: traits::HpkeKeyPair<CURRENT_VERSION>>(
        &self,
        public_key: &E,
        key_pair: &K,
    ) -> Res<()> {
        self.track(vec![row_key(label::ENCRYPTION_KEY_PAIR, public_key)], |s| {
            s.write_encryption_key_pair(public_key, key_pair)
        })
    }

    fn write_encryption_epoch_key_pairs<
        G: traits::GroupId<CURRENT_VERSION>,
        E: traits::EpochKey<CURRENT_VERSION>,
        K: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &G,
        epoch: &E,
        leaf_index: u32,
        key_pairs: &[K],
    ) -> Res<()> {
        self.track(vec![epoch_key_pairs_key(group_id, epoch, leaf_index)], |s| {
            s.write_encryption_epoch_key_pairs(group_id, epoch, leaf_index, key_pairs)
        })
    }

    fn write_key_package<R: traits::HashReference<CURRENT_VERSION>, K: traits::KeyPackage<CURRENT_VERSION>>(
        &self,
        hash_ref: &R,
        key_package: &K,
    ) -> Res<()> {
        self.track(vec![row_key(label::KEY_PACKAGE, hash_ref)], |s| s.write_key_package(hash_ref, key_package))
    }

    fn write_psk<P: traits::PskId<CURRENT_VERSION>, B: traits::PskBundle<CURRENT_VERSION>>(
        &self,
        psk_id: &P,
        psk: &B,
    ) -> Res<()> {
        self.track(vec![row_key(label::PSK, psk_id)], |s| s.write_psk(psk_id, psk))
    }

    fn mls_group_join_config<G: traits::GroupId<CURRENT_VERSION>, C: traits::MlsGroupJoinConfig<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<C>> {
        self.inner.mls_group_join_config(group_id)
    }

    fn own_leaf_nodes<G: traits::GroupId<CURRENT_VERSION>, L: traits::LeafNode<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Vec<L>> {
        self.inner.own_leaf_nodes(group_id)
    }

    fn queued_proposal_refs<G: traits::GroupId<CURRENT_VERSION>, R: traits::ProposalRef<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Vec<R>> {
        self.inner.queued_proposal_refs(group_id)
    }

    fn queued_proposals<
        G: traits::GroupId<CURRENT_VERSION>,
        R: traits::ProposalRef<CURRENT_VERSION>,
        Q: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &G,
    ) -> Res<Vec<(R, Q)>> {
        self.inner.queued_proposals(group_id)
    }

    fn tree<G: traits::GroupId<CURRENT_VERSION>, T: traits::TreeSync<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<T>> {
        self.inner.tree(group_id)
    }

    fn group_context<G: traits::GroupId<CURRENT_VERSION>, C: traits::GroupContext<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<C>> {
        self.inner.group_context(group_id)
    }

    fn interim_transcript_hash<
        G: traits::GroupId<CURRENT_VERSION>,
        H: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &G,
    ) -> Res<Option<H>> {
        self.inner.interim_transcript_hash(group_id)
    }

    fn confirmation_tag<G: traits::GroupId<CURRENT_VERSION>, C: traits::ConfirmationTag<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<C>> {
        self.inner.confirmation_tag(group_id)
    }

    fn group_state<S: traits::GroupState<CURRENT_VERSION>, G: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<S>> {
        self.inner.group_state(group_id)
    }

    fn message_secrets<G: traits::GroupId<CURRENT_VERSION>, M: traits::MessageSecrets<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<M>> {
        self.inner.message_secrets(group_id)
    }

    fn resumption_psk_store<G: traits::GroupId<CURRENT_VERSION>, R: traits::ResumptionPskStore<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<R>> {
        self.inner.resumption_psk_store(group_id)
    }

    fn own_leaf_index<G: traits::GroupId<CURRENT_VERSION>, L: traits::LeafNodeIndex<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<L>> {
        self.inner.own_leaf_index(group_id)
    }

    fn group_epoch_secrets<G: traits::GroupId<CURRENT_VERSION>, E: traits::GroupEpochSecrets<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<Option<E>> {
        self.inner.group_epoch_secrets(group_id)
    }

    fn signature_key_pair<
        P: traits::SignaturePublicKey<CURRENT_VERSION>,
        K: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &P,
    ) -> Res<Option<K>> {
        self.inner.signature_key_pair(public_key)
    }

    fn encryption_key_pair<K: traits::HpkeKeyPair<CURRENT_VERSION>, E: traits::EncryptionKey<CURRENT_VERSION>>(
        &self,
        public_key: &E,
    ) -> Res<Option<K>> {
        self.inner.encryption_key_pair(public_key)
    }

    fn encryption_epoch_key_pairs<
        G: traits::GroupId<CURRENT_VERSION>,
        E: traits::EpochKey<CURRENT_VERSION>,
        K: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &G,
        epoch: &E,
        leaf_index: u32,
    ) -> Res<Vec<K>> {
        self.inner.encryption_epoch_key_pairs(group_id, epoch, leaf_index)
    }

    fn key_package<R: traits::HashReference<CURRENT_VERSION>, K: traits::KeyPackage<CURRENT_VERSION>>(
        &self,
        hash_ref: &R,
    ) -> Res<Option<K>> {
        self.inner.key_package(hash_ref)
    }

    fn psk<B: traits::PskBundle<CURRENT_VERSION>, P: traits::PskId<CURRENT_VERSION>>(&self, psk_id: &P) -> Res<Option<B>> {
        self.inner.psk(psk_id)
    }

    fn remove_proposal<G: traits::GroupId<CURRENT_VERSION>, R: traits::ProposalRef<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        proposal_ref: &R,
    ) -> Res<()> {
        let keys = vec![
            row_key(label::PROPOSAL_QUEUE_REFS, group_id),
            row_key(label::QUEUED_PROPOSAL, &(group_id, proposal_ref)),
        ];
        self.track(keys, |s| s.remove_proposal(group_id, proposal_ref))
    }

    fn delete_own_leaf_nodes<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::OWN_LEAF_NODES, group_id)], |s| s.delete_own_leaf_nodes(group_id))
    }

    fn delete_group_config<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::JOIN_CONFIG, group_id)], |s| s.delete_group_config(group_id))
    }

    fn delete_tree<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::TREE, group_id)], |s| s.delete_tree(group_id))
    }

    fn delete_confirmation_tag<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::CONFIRMATION_TAG, group_id)], |s| s.delete_confirmation_tag(group_id))
    }

    fn delete_group_state<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::GROUP_STATE, group_id)], |s| s.delete_group_state(group_id))
    }

    fn delete_context<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::GROUP_CONTEXT, group_id)], |s| s.delete_context(group_id))
    }

    fn delete_interim_transcript_hash<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::INTERIM_TRANSCRIPT_HASH, group_id)], |s| {
            s.delete_interim_transcript_hash(group_id)
        })
    }

    fn delete_message_secrets<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::MESSAGE_SECRETS, group_id)], |s| s.delete_message_secrets(group_id))
    }

    fn delete_all_resumption_psk_secrets<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::RESUMPTION_PSK, group_id)], |s| {
            s.delete_all_resumption_psk_secrets(group_id)
        })
    }

    fn delete_own_leaf_index<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::OWN_LEAF_NODE_INDEX, group_id)], |s| s.delete_own_leaf_index(group_id))
    }

    fn delete_group_epoch_secrets<G: traits::GroupId<CURRENT_VERSION>>(&self, group_id: &G) -> Res<()> {
        self.track(vec![row_key(label::EPOCH_SECRETS, group_id)], |s| s.delete_group_epoch_secrets(group_id))
    }

    fn clear_proposal_queue<G: traits::GroupId<CURRENT_VERSION>, R: traits::ProposalRef<CURRENT_VERSION>>(
        &self,
        group_id: &G,
    ) -> Res<()> {
        // The memory store removes these proposals under keys without label or version
        // (so it removes nothing); both shapes are noted, an unchanged row saves as is.
        let refs: Vec<R> = self.inner.queued_proposal_refs(group_id)?;
        let mut keys = vec![row_key(label::PROPOSAL_QUEUE_REFS, group_id)];
        for proposal_ref in &refs {
            keys.push(row_key(label::QUEUED_PROPOSAL, &(group_id, proposal_ref)));
            keys.push(json(&(group_id, proposal_ref)));
        }
        self.track(keys, |s| s.clear_proposal_queue::<G, R>(group_id))
    }

    fn delete_signature_key_pair<P: traits::SignaturePublicKey<CURRENT_VERSION>>(&self, public_key: &P) -> Res<()> {
        self.track(vec![row_key(label::SIGNATURE_KEY_PAIR, public_key)], |s| s.delete_signature_key_pair(public_key))
    }

    fn delete_encryption_key_pair<E: traits::EncryptionKey<CURRENT_VERSION>>(&self, public_key: &E) -> Res<()> {
        self.track(vec![row_key(label::ENCRYPTION_KEY_PAIR, public_key)], |s| s.delete_encryption_key_pair(public_key))
    }

    fn delete_encryption_epoch_key_pairs<G: traits::GroupId<CURRENT_VERSION>, E: traits::EpochKey<CURRENT_VERSION>>(
        &self,
        group_id: &G,
        epoch: &E,
        leaf_index: u32,
    ) -> Res<()> {
        self.track(vec![epoch_key_pairs_key(group_id, epoch, leaf_index)], |s| {
            s.delete_encryption_epoch_key_pairs(group_id, epoch, leaf_index)
        })
    }

    fn delete_key_package<R: traits::HashReference<CURRENT_VERSION>>(&self, hash_ref: &R) -> Res<()> {
        self.track(vec![row_key(label::KEY_PACKAGE, hash_ref)], |s| s.delete_key_package(hash_ref))
    }

    fn delete_psk<P: traits::PskId<CURRENT_VERSION>>(&self, psk_id: &P) -> Res<()> {
        self.track(vec![row_key(label::PSK, psk_id)], |s| s.delete_psk(psk_id))
    }
}

/// The memory store keys epoch key pairs by the three JSON values run together.
fn epoch_key_pairs_key<G: Serialize, E: Serialize>(group_id: &G, epoch: &E, leaf_index: u32) -> Vec<u8> {
    let mut key = json(group_id);
    key.extend_from_slice(&json(epoch));
    key.extend_from_slice(&json(&leaf_index));
    raw_row_key(label::EPOCH_KEY_PAIRS, &key)
}

/// TEST-ONLY: every write is checked to change no row but the ones it noted.
#[cfg(test)]
pub(crate) mod verify {
    use std::cell::Cell;
    use std::collections::HashMap;

    thread_local! {
        static ON: Cell<bool> = const { Cell::new(true) };
    }

    pub(crate) fn enabled() -> bool {
        ON.with(Cell::get)
    }

    /// Off for this thread: the scale probes, whose stores are too large to copy per write.
    pub(crate) fn set(on: bool) {
        ON.with(|c| c.set(on));
    }

    pub(super) fn only_these_changed(
        before: &HashMap<Vec<u8>, Vec<u8>>,
        after: &HashMap<Vec<u8>, Vec<u8>>,
        noted: &[Vec<u8>],
    ) {
        let changed = before
            .iter()
            .filter(|(k, v)| after.get(*k) != Some(*v))
            .map(|(k, _)| k)
            .chain(after.keys().filter(|k| !before.contains_key(*k)));
        for key in changed {
            assert!(
                noted.contains(key),
                "an MLS store write changed a row it did not note: {}",
                String::from_utf8_lossy(key)
            );
        }
    }
}
