use std::collections::HashMap;

use openmls::prelude::*;
use openmls::prelude::tls_codec::{Serialize as TlsSerialize, Deserialize as TlsDeserialize};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;

use crate::hollow_log;

/// The ciphersuite used by Hollow MLS groups.
/// X25519 DH, AES-128-GCM encryption, SHA-256 hash, Ed25519 signatures.
const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Group-key for a per-channel MLS subgroup ("Option B"). A restricted channel
/// (visibility != Everyone, non-public) is encrypted under its own MLS group
/// keyed by this string instead of the server-wide group keyed by bare
/// `server_id`. The `#` separator never appears in a `server_id`
/// (`12D3KooW...` peer id) nor a `channel_id` (`{server_prefix}-{hex4}`), so it
/// round-trips unambiguously and never collides with a server group key.
pub(crate) fn subgroup_id(server_id: &str, channel_id: &str) -> String {
    format!("{server_id}#{channel_id}")
}

/// Inverse of [`subgroup_id`]. Splits an MLS group key into
/// `(server_id, Option<channel_id>)`. A bare server group key has no `#` and
/// yields `(server_id, None)`; a subgroup key `"{server}#{channel}"` yields
/// `(server, Some(channel))`. Used by the batch timer and bootstrap handlers to
/// recover the server room / CRDT state and the wire `channel_id` from a group
/// key uniformly across server groups and channel subgroups.
pub(crate) fn split_group_key(group_key: &str) -> (String, Option<String>) {
    match group_key.split_once('#') {
        Some((server, channel)) => (server.to_string(), Some(channel.to_string())),
        None => (group_key.to_string(), None),
    }
}

/// Wraps OpenMLS for Hollow.s channel group encryption.
/// One MLS group per server. DMs stay on Olm.
pub(crate) struct MlsManager {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential_with_key: CredentialWithKey,
    /// server_id → MlsGroup
    groups: HashMap<String, MlsGroup>,
}

impl MlsManager {
    /// Create a new MlsManager with a fresh MLS identity.
    ///
    /// `identity_id` becomes the leaf credential. Multi-device (Step 6): this is
    /// THIS device's transport peer_id (`device_peer_id`), NOT the master — so
    /// each of a human's devices holds a distinct leaf credential and can be a
    /// separate MLS group member. (Pre-Step-6 this was seeded with the master;
    /// existing groups keep those master credentials via `from_persisted`.)
    pub fn new(identity_id: &str) -> Result<Self, String> {
        let peer_id = identity_id;
        let provider = OpenMlsRustCrypto::default();

        // Generate MLS signing keypair (Ed25519).
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(|e| format!("Failed to generate MLS signer: {e:?}"))?;

        // Store the signer in the provider so OpenMLS can find it.
        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store MLS signer: {e:?}"))?;

        // Create credential: BasicCredential with identity = peer_id bytes.
        let credential = BasicCredential::new(peer_id.as_bytes().to_vec());
        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.to_public_vec().into(),
        };

        Ok(MlsManager {
            provider,
            signer,
            credential_with_key,
            groups: HashMap::new(),
        })
    }

    /// Restore MlsManager from persisted state.
    /// `signer_bytes` and `credential_bytes` are serde JSON blobs.
    /// `storage_blob` is the serialized MemoryStorage HashMap (if any).
    pub fn from_persisted(
        signer_bytes: &[u8],
        credential_bytes: &[u8],
        storage_blob: Option<&[u8]>,
        server_ids: &[String],
    ) -> Result<Self, String> {
        let provider = OpenMlsRustCrypto::default();

        // Restore the storage state from blob.
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

        // Restore signer and credential from serde JSON.
        let signer: SignatureKeyPair = serde_json::from_slice(signer_bytes)
            .map_err(|e| format!("Failed to deserialize MLS signer: {e}"))?;
        let credential_with_key: CredentialWithKey = serde_json::from_slice(credential_bytes)
            .map_err(|e| format!("Failed to deserialize MLS credential: {e}"))?;

        // Store signer in the provider so OpenMLS can find it.
        signer
            .store(provider.storage())
            .map_err(|e| format!("Failed to store restored MLS signer: {e:?}"))?;

        // Load MLS groups from the storage provider.
        let mut groups = HashMap::new();
        for server_id in server_ids {
            let group_id = GroupId::from_slice(server_id.as_bytes());
            match MlsGroup::load(provider.storage(), &group_id) {
                Ok(Some(group)) => {
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

        Ok(MlsManager {
            provider,
            signer,
            credential_with_key,
            groups,
        })
    }

    /// The identity string baked into this manager's leaf credential (the id
    /// passed to `new()`). Multi-device: a device's MLS leaf is credentialed by
    /// its own `device_peer_id`; a legacy/single-device install's is the master.
    /// Used at startup to detect a leaf credential inherited from ANOTHER device
    /// (e.g. a linked sibling that imported the source device's DB) — that must be
    /// regenerated, or two devices share one MLS signature key
    /// (`DuplicateSignatureKey` on add, `CannotDecryptOwnMessage` on receive).
    pub fn credential_identity(&self) -> String {
        String::from_utf8_lossy(
            self.credential_with_key.credential.serialized_content()
        ).to_string()
    }

    /// Serialize the MLS signer for DB persistence (serde binary).
    pub fn signer_bytes(&self) -> Result<Vec<u8>, String> {
        serde_json::to_vec(&self.signer)
            .map_err(|e| format!("Failed to serialize MLS signer: {e}"))
    }

    /// Serialize the credential for DB persistence.
    pub fn credential_bytes(&self) -> Result<Vec<u8>, String> {
        serde_json::to_vec(&self.credential_with_key)
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

    /// Create a new MLS group for a server (called by server owner).
    pub fn create_group(&mut self, server_id: &str) -> Result<(), String> {
        let group_id = GroupId::from_slice(server_id.as_bytes());
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
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

    /// Add a member to the MLS group. Returns (serialized_commit, serialized_welcome).
    /// Caller must call `merge_pending_commit()` after broadcasting the commit.
    pub fn add_member(
        &mut self,
        server_id: &str,
        key_package_bytes: &[u8],
    ) -> Result<(Vec<u8>, Vec<u8>), String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(key_package_bytes)
            .map_err(|e| format!("Failed to deserialize KeyPackage: {e:?}"))?;

        let kp = kp_in
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|e| format!("KeyPackage validation failed: {e:?}"))?;

        let (commit_out, welcome, _group_info) = group
            .add_members(&self.provider, &self.signer, &[kp])
            .map_err(|e| format!("Failed to add member: {e:?}"))?;

        let commit_bytes = TlsSerialize::tls_serialize_detached(&commit_out)
            .map_err(|e| format!("Failed to serialize commit: {e:?}"))?;

        let welcome_bytes = TlsSerialize::tls_serialize_detached(&welcome)
            .map_err(|e| format!("Failed to serialize welcome: {e:?}"))?;

        hollow_log!("[HOLLOW-MLS] add_member commit generated for server {server_id}");
        Ok((commit_bytes, welcome_bytes))
    }

    /// Add multiple members to the MLS group in a single commit (single epoch advance).
    /// Returns (commit_bytes, welcome_bytes, list of added peer_ids).
    pub fn add_members_batch(
        &mut self,
        server_id: &str,
        key_packages: &[(String, Vec<u8>)],
    ) -> Result<(Vec<u8>, Vec<u8>, Vec<String>), String> {
        let existing_members = self.group_members(server_id);
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        let mut validated_kps = Vec::new();
        let mut added_peers = Vec::new();

        for (peer_id, kp_bytes) in key_packages {
            if existing_members.contains(peer_id) {
                hollow_log!("[HOLLOW-MLS] Skipping {peer_id} — already in MLS group");
                continue;
            }
            match TlsDeserialize::tls_deserialize_exact(kp_bytes) {
                Ok(kp_in) => {
                    let kp_in: KeyPackageIn = kp_in;
                    match kp_in.validate(self.provider.crypto(), ProtocolVersion::Mls10) {
                        Ok(kp) => {
                            validated_kps.push(kp);
                            added_peers.push(peer_id.clone());
                        }
                        Err(e) => {
                            hollow_log!("[HOLLOW-MLS] KeyPackage validation failed for {peer_id}: {e:?}");
                        }
                    }
                }
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Failed to deserialize KeyPackage from {peer_id}: {e:?}");
                }
            }
        }

        if validated_kps.is_empty() {
            return Err("No valid new members to add".to_string());
        }

        let (commit_out, welcome, _group_info) = group
            .add_members(&self.provider, &self.signer, &validated_kps)
            .map_err(|e| format!("Failed to batch add members: {e:?}"))?;

        let commit_bytes = TlsSerialize::tls_serialize_detached(&commit_out)
            .map_err(|e| format!("Failed to serialize commit: {e:?}"))?;
        let welcome_bytes = TlsSerialize::tls_serialize_detached(&welcome)
            .map_err(|e| format!("Failed to serialize welcome: {e:?}"))?;

        hollow_log!("[HOLLOW-MLS] Batch-added {} members to server {server_id}", added_peers.len());
        Ok((commit_bytes, welcome_bytes, added_peers))
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

    /// Remove a member from the MLS group. Returns serialized commit.
    /// Caller must call `merge_pending_commit()` after broadcasting.
    ///
    /// Multi-device (Step 6): a human can hold MULTIPLE leaves (one per device,
    /// each credentialed by its own device peer_id), plus possibly a legacy
    /// master-credentialed leaf. To remove that human entirely, the CALLER must
    /// expand `peer_id` into the full set of credential ids
    /// (`{master} ∪ devices_for(master)`) and use
    /// [`remove_identity_leaves`]. This single-id helper removes only the ONE leaf
    /// whose credential equals `peer_id` and is kept for callers that genuinely
    /// target one specific leaf (e.g. removing a single stale device).
    pub fn remove_member(
        &mut self,
        server_id: &str,
        peer_id: &str,
    ) -> Result<Vec<u8>, String> {
        self.remove_identity_leaves(server_id, &[peer_id])
    }

    /// Remove multiple members from the MLS group in a single commit.
    /// Returns serialized commit. Caller must call `merge_pending_commit()` after broadcasting.
    pub fn remove_members_batch(
        &mut self,
        server_id: &str,
        peer_ids: &[&str],
    ) -> Result<Vec<u8>, String> {
        self.remove_identity_leaves(server_id, peer_ids)
    }

    /// Remove EVERY leaf whose credential matches any of `credential_ids`, in a
    /// single commit. This is the canonical multi-device removal primitive: the
    /// caller passes the full set of credential ids belonging to the identity
    /// (or identities) to remove — typically `{master} ∪ devices_for(master)` —
    /// and all matching leaves are dropped at once (one epoch advance).
    ///
    /// Credentials are matched by exact bytes; with per-device credentials each
    /// id matches at most one leaf, and a legacy master-credentialed leaf is
    /// matched when the master id is included. Ids with no matching leaf are
    /// skipped (idempotent — a re-issued kick is harmless). Returns an error only
    /// if the id set is empty or NO leaf matched any id.
    pub fn remove_identity_leaves(
        &mut self,
        server_id: &str,
        credential_ids: &[&str],
    ) -> Result<Vec<u8>, String> {
        if credential_ids.is_empty() {
            return Err("No credential ids to remove".to_string());
        }
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        let wanted: std::collections::HashSet<&[u8]> =
            credential_ids.iter().map(|id| id.as_bytes()).collect();

        let mut leaf_indices = Vec::new();
        for member in group.members() {
            if wanted.contains(member.credential.serialized_content()) {
                leaf_indices.push(member.index);
            }
        }
        if leaf_indices.is_empty() {
            return Err(format!(
                "No matching leaves for {} credential id(s) in server {server_id}",
                credential_ids.len()
            ));
        }

        let (commit_out, _welcome, _group_info) = group
            .remove_members(&self.provider, &self.signer, &leaf_indices)
            .map_err(|e| format!("Failed to remove members: {e:?}"))?;

        let commit_bytes = TlsSerialize::tls_serialize_detached(&commit_out)
            .map_err(|e| format!("Failed to serialize remove commit: {e:?}"))?;

        hollow_log!(
            "[HOLLOW-MLS] removed {} leaf/leaves ({} credential id(s)) in server {server_id}",
            leaf_indices.len(), credential_ids.len()
        );
        Ok(commit_bytes)
    }

    /// Join a group from a Welcome message (called by the joiner).
    pub fn join_from_welcome(
        &mut self,
        server_id: &str,
        welcome_bytes: &[u8],
    ) -> Result<(), String> {
        let msg_in: MlsMessageIn = TlsDeserialize::tls_deserialize_exact(welcome_bytes)
            .map_err(|e| format!("Failed to deserialize Welcome message: {e:?}"))?;

        let welcome = match msg_in.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("Message is not a Welcome".to_string()),
        };

        let config = MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .build();

        let group = StagedWelcome::new_from_welcome(
            &self.provider,
            &config,
            welcome,
            None, // no ratchet tree provided separately
        )
        .map_err(|e| format!("Failed to process Welcome: {e:?}"))?
        .into_group(&self.provider)
        .map_err(|e| format!("Failed to create group from Welcome: {e:?}"))?;

        hollow_log!("[HOLLOW-MLS] Joined MLS group for server {server_id}, epoch: {:?}", group.epoch());
        self.groups.insert(server_id.to_string(), group);
        Ok(())
    }

    /// Encrypt a message for all group members. Returns the MLS ciphertext bytes.
    pub fn encrypt(
        &mut self,
        server_id: &str,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        let msg_out = group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(|e| format!("MLS encrypt failed: {e:?}"))?;

        TlsSerialize::tls_serialize_detached(&msg_out)
            .map_err(|e| format!("Failed to serialize MLS message: {e:?}"))
    }

    /// Decrypt an MLS message. Returns (plaintext, sender_peer_id).
    pub fn decrypt(
        &mut self,
        server_id: &str,
        ciphertext: &[u8],
    ) -> Result<(Vec<u8>, String), String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        let msg_in: MlsMessageIn = TlsDeserialize::tls_deserialize_exact(ciphertext)
            .map_err(|e| format!("Failed to deserialize MLS message: {e:?}"))?;

        let protocol_msg = msg_in
            .try_into_protocol_message()
            .map_err(|e| format!("Not a protocol message: {e:?}"))?;

        let processed = group
            .process_message(&self.provider, protocol_msg)
            .map_err(|e| format!("MLS process_message failed: {e:?}"))?;

        // Extract sender identity from the credential.
        let sender_credential = processed.credential();
        let sender_peer_id = String::from_utf8_lossy(
            sender_credential.serialized_content()
        ).to_string();

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => {
                Ok((app_msg.into_bytes(), sender_peer_id))
            }
            ProcessedMessageContent::ProposalMessage(_) => {
                Err("Received proposal instead of application message".to_string())
            }
            ProcessedMessageContent::StagedCommitMessage(_) => {
                Err("Received commit instead of application message".to_string())
            }
            _ => {
                Err("Unexpected MLS message content type".to_string())
            }
        }
    }

    /// Process an incoming Commit message (membership change from owner).
    pub fn process_commit(
        &mut self,
        server_id: &str,
        commit_bytes: &[u8],
    ) -> Result<(), String> {
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

        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                group
                    .merge_staged_commit(&self.provider, *staged_commit)
                    .map_err(|e| format!("Failed to merge staged commit: {e:?}"))?;
                hollow_log!("[HOLLOW-MLS] Processed commit for server {server_id}, new epoch: {:?}", group.epoch());
                Ok(())
            }
            _ => Err("Expected a commit message".to_string()),
        }
    }

    /// Check if an MLS group exists for a server.
    pub fn has_group(&self, server_id: &str) -> bool {
        self.groups.contains_key(server_id)
    }

    /// All server_ids we currently hold an MLS group for (Step 7 revocation sweeps
    /// every shared server to remove a revoked device's leaf where we coordinate).
    pub fn group_ids(&self) -> Vec<String> {
        self.groups.keys().cloned().collect()
    }

    /// Get the number of members in the MLS group.
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

    /// Remove MLS group for a server (on server delete/leave).
    pub fn remove_group(&mut self, server_id: &str) {
        if let Some(mut group) = self.groups.remove(server_id) {
            // Delete from OpenMLS provider storage so join_from_welcome doesn't hit GroupAlreadyExists.
            let _ = group.delete(self.provider.storage());
        }
    }

    /// Get the list of peer IDs in the MLS group (from their credentials).
    pub fn group_members(&self, server_id: &str) -> Vec<String> {
        self.groups
            .get(server_id)
            .map(|g| {
                g.members()
                    .map(|m| {
                        String::from_utf8_lossy(m.credential.serialized_content()).to_string()
                    })
                    .collect()
            })
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
mod tests {
    use super::*;

    #[test]
    fn test_create_group_and_has_group() {
        let mut mgr = MlsManager::new("12D3KooWTestPeerId1").unwrap();
        assert!(!mgr.has_group("server1"));
        mgr.create_group("server1").unwrap();
        assert!(mgr.has_group("server1"));
        assert_eq!(mgr.member_count("server1"), 1);
    }

    #[test]
    fn test_two_members_encrypt_decrypt() {
        // Alice creates a group.
        let mut alice = MlsManager::new("12D3KooWAlice").unwrap();
        alice.create_group("server1").unwrap();

        // Bob generates a KeyPackage.
        let bob = MlsManager::new("12D3KooWBob").unwrap();
        let bob_kp = bob.generate_key_package().unwrap();

        // Alice adds Bob.
        let (commit_bytes, welcome_bytes) = alice.add_member("server1", &bob_kp).unwrap();
        alice.merge_pending_commit("server1").unwrap();
        assert_eq!(alice.member_count("server1"), 2);

        // Bob joins from Welcome.
        let mut bob = bob; // make mutable
        bob.join_from_welcome("server1", &welcome_bytes).unwrap();
        assert_eq!(bob.member_count("server1"), 2);

        // Alice encrypts a message.
        let plaintext = b"Hello from Alice!";
        let ciphertext = alice.encrypt("server1", plaintext).unwrap();
        assert_ne!(ciphertext, plaintext.to_vec());

        // Bob decrypts.
        let (decrypted, sender) = bob.decrypt("server1", &ciphertext).unwrap();
        assert_eq!(decrypted, plaintext.to_vec());
        assert_eq!(sender, "12D3KooWAlice");

        // Bob encrypts, Alice decrypts.
        let bob_msg = b"Hello from Bob!";
        let bob_ct = bob.encrypt("server1", bob_msg).unwrap();
        let (decrypted2, sender2) = alice.decrypt("server1", &bob_ct).unwrap();
        assert_eq!(decrypted2, bob_msg.to_vec());
        assert_eq!(sender2, "12D3KooWBob");
    }

    #[test]
    fn test_remove_member_forward_secrecy() {
        // Alice (owner), Bob, Charlie.
        let mut alice = MlsManager::new("12D3KooWAlice").unwrap();
        alice.create_group("server1").unwrap();

        let bob = MlsManager::new("12D3KooWBob").unwrap();
        let bob_kp = bob.generate_key_package().unwrap();
        let (_, welcome_bob) = alice.add_member("server1", &bob_kp).unwrap();
        alice.merge_pending_commit("server1").unwrap();
        let mut bob = bob;
        bob.join_from_welcome("server1", &welcome_bob).unwrap();

        let charlie = MlsManager::new("12D3KooWCharlie").unwrap();
        let charlie_kp = charlie.generate_key_package().unwrap();
        let (commit_charlie, welcome_charlie) = alice.add_member("server1", &charlie_kp).unwrap();
        alice.merge_pending_commit("server1").unwrap();
        // Bob processes the commit so he knows about Charlie.
        bob.process_commit("server1", &commit_charlie).unwrap();
        let mut charlie = charlie;
        charlie.join_from_welcome("server1", &welcome_charlie).unwrap();

        assert_eq!(alice.member_count("server1"), 3);

        // Alice removes Bob.
        let remove_commit = alice.remove_member("server1", "12D3KooWBob").unwrap();
        alice.merge_pending_commit("server1").unwrap();
        // Charlie processes the remove commit.
        charlie.process_commit("server1", &remove_commit).unwrap();

        assert_eq!(alice.member_count("server1"), 2);

        // Alice sends a message post-removal.
        let post_removal_msg = b"Secret after Bob left";
        let ct = alice.encrypt("server1", post_removal_msg).unwrap();

        // Charlie can decrypt.
        let (decrypted, _) = charlie.decrypt("server1", &ct).unwrap();
        assert_eq!(decrypted, post_removal_msg.to_vec());

        // Bob cannot decrypt (his group state is stale — epoch mismatch).
        let result = bob.decrypt("server1", &ct);
        assert!(result.is_err(), "Bob should not be able to decrypt after removal");
    }

    #[test]
    fn test_credential_identity_reports_seed() {
        // The credential identity must equal the id passed to new() — this is what
        // startup uses to detect a sibling that inherited another device's MLS
        // identity (credential != our device id → must regenerate to avoid a
        // duplicate signature key across two leaves).
        let mgr = MlsManager::new("12D3KooWMyDeviceId").unwrap();
        assert_eq!(mgr.credential_identity(), "12D3KooWMyDeviceId");
    }

    #[test]
    fn test_distinct_devices_have_distinct_signature_keys() {
        // Two independently-created managers (distinct device ids) must have
        // DISTINCT MLS signature keys, so both can be added as separate leaves.
        // (A linked sibling that imported the source's signer would FAIL this —
        // hence the startup regeneration.)
        let a = MlsManager::new("12D3KooWDeviceA").unwrap();
        let b = MlsManager::new("12D3KooWDeviceB").unwrap();
        assert_ne!(a.signer_bytes().unwrap(), b.signer_bytes().unwrap(),
            "distinct devices must mint distinct MLS signature keys");
    }

    #[test]
    fn test_remove_identity_leaves_multiple() {
        // Step 6: one human holds TWO leaves (two device credentials). A single
        // remove_identity_leaves call passing both device ids must drop BOTH in
        // one commit, and survivors keep decrypting.
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();

        // Survivor.
        let survivor = MlsManager::new("12D3KooWSurvivor").unwrap();
        let (_, w_surv) = owner.add_member("server1", &survivor.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        let mut survivor = survivor;
        survivor.join_from_welcome("server1", &w_surv).unwrap();

        // "Human X" device A.
        let dev_a = MlsManager::new("12D3KooWHumanXDeviceA").unwrap();
        let (c_a, _) = owner.add_member("server1", &dev_a.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        survivor.process_commit("server1", &c_a).unwrap();

        // "Human X" device B (distinct credential — the multi-device case).
        let dev_b = MlsManager::new("12D3KooWHumanXDeviceB").unwrap();
        let (c_b, _) = owner.add_member("server1", &dev_b.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        survivor.process_commit("server1", &c_b).unwrap();

        assert_eq!(owner.member_count("server1"), 4); // owner + survivor + A + B

        // Remove BOTH of Human X's leaves in one commit (caller expanded the set).
        let commit = owner.remove_identity_leaves(
            "server1",
            &["12D3KooWHumanXDeviceA", "12D3KooWHumanXDeviceB"],
        ).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        survivor.process_commit("server1", &commit).unwrap();

        assert_eq!(owner.member_count("server1"), 2); // owner + survivor

        // Survivor still decrypts post-removal.
        let ct = owner.encrypt("server1", b"after X removed").unwrap();
        let (dec, _) = survivor.decrypt("server1", &ct).unwrap();
        assert_eq!(dec, b"after X removed".to_vec());
    }

    #[test]
    fn test_remove_identity_leaves_skips_unknown_ids() {
        // Removing by a set that includes ids with no matching leaf removes the
        // matching one and silently skips the rest (idempotent kicks).
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();
        let bob = MlsManager::new("12D3KooWBob").unwrap();
        let (_, _) = owner.add_member("server1", &bob.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        assert_eq!(owner.member_count("server1"), 2);

        // Pass Bob's master id + a never-present device id of his (no leaf).
        owner.remove_identity_leaves(
            "server1",
            &["12D3KooWBob", "12D3KooWBobGhostDevice"],
        ).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        assert_eq!(owner.member_count("server1"), 1);

        // Removing a fully-unknown set errors (no leaf matched).
        assert!(owner.remove_identity_leaves("server1", &["12D3KooWNobody"]).is_err());
    }

    #[test]
    fn test_storage_serialization_roundtrip() {
        // Create a group and verify state survives serialization.
        let mut alice = MlsManager::new("12D3KooWAlice").unwrap();
        alice.create_group("server1").unwrap();

        let bob = MlsManager::new("12D3KooWBob").unwrap();
        let bob_kp = bob.generate_key_package().unwrap();
        let (_, welcome) = alice.add_member("server1", &bob_kp).unwrap();
        alice.merge_pending_commit("server1").unwrap();

        // Serialize Alice's state.
        let signer_bytes = alice.signer_bytes().unwrap();
        let credential_bytes = alice.credential_bytes().unwrap();
        let storage_blob = alice.serialize_storage().unwrap();

        // Restore from serialized state.
        let mut alice2 = MlsManager::from_persisted(
            &signer_bytes,
            &credential_bytes,
            Some(&storage_blob),
            &["server1".to_string()],
        ).unwrap();

        assert!(alice2.has_group("server1"));
        assert_eq!(alice2.member_count("server1"), 2);

        // Restored Alice can still encrypt.
        let mut bob = bob;
        bob.join_from_welcome("server1", &welcome).unwrap();
        let ct = alice2.encrypt("server1", b"After restore").unwrap();
        let (decrypted, sender) = bob.decrypt("server1", &ct).unwrap();
        assert_eq!(decrypted, b"After restore".to_vec());
        assert_eq!(sender, "12D3KooWAlice");
    }

    #[test]
    fn test_credential_maps_to_peer_id() {
        let mut alice = MlsManager::new("12D3KooWAlice").unwrap();
        alice.create_group("server1").unwrap();

        let members = alice.group_members("server1");
        assert_eq!(members.len(), 1);
        assert_eq!(members[0], "12D3KooWAlice");
    }

    #[test]
    fn test_generate_key_package() {
        let mgr = MlsManager::new("12D3KooWTestPeer").unwrap();
        let kp = mgr.generate_key_package().unwrap();
        assert!(!kp.is_empty());
        // Verify it can be deserialized back.
        let kp_in: KeyPackageIn = TlsDeserialize::tls_deserialize_exact(&kp).unwrap();
        assert!(kp_in.validate(mgr.provider.crypto(), ProtocolVersion::Mls10).is_ok());
    }

    #[test]
    fn test_batch_add_six_members() {
        // Owner creates group, 6 peers generate KeyPackages.
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();

        let peer_ids: Vec<String> = (1..=6).map(|i| format!("12D3KooWPeer{i}")).collect();
        let peers: Vec<MlsManager> = peer_ids.iter()
            .map(|id| MlsManager::new(id).unwrap())
            .collect();
        let key_packages: Vec<(String, Vec<u8>)> = peers.iter().zip(&peer_ids)
            .map(|(p, id)| (id.clone(), p.generate_key_package().unwrap()))
            .collect();

        // Batch add all 6 at once — single epoch advance.
        let (commit_bytes, welcome_bytes, added) = owner
            .add_members_batch("server1", &key_packages)
            .unwrap();
        owner.merge_pending_commit("server1").unwrap();

        assert_eq!(added.len(), 6);
        assert_eq!(owner.member_count("server1"), 7); // owner + 6

        // All peers join from the same Welcome.
        let mut joined_peers: Vec<MlsManager> = peers.into_iter().map(|mut p| {
            p.join_from_welcome("server1", &welcome_bytes).unwrap();
            p
        }).collect();

        // Verify all peers see 7 members.
        for p in &joined_peers {
            assert_eq!(p.member_count("server1"), 7);
        }

        // Owner encrypts, all peers can decrypt.
        let msg = b"Hello from owner to all 6 peers!";
        let ct = owner.encrypt("server1", msg).unwrap();
        for p in &mut joined_peers {
            let (decrypted, sender) = p.decrypt("server1", &ct).unwrap();
            assert_eq!(decrypted, msg.to_vec());
            assert_eq!(sender, "12D3KooWOwner");
        }
    }

    #[test]
    fn test_batch_add_skips_duplicates() {
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();

        // Add Bob normally first.
        let bob = MlsManager::new("12D3KooWBob").unwrap();
        let bob_kp = bob.generate_key_package().unwrap();
        let (_, _) = owner.add_member("server1", &bob_kp).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        assert_eq!(owner.member_count("server1"), 2);

        // Try batch-adding Bob again + a new peer Charlie.
        let charlie = MlsManager::new("12D3KooWCharlie").unwrap();
        let charlie_kp = charlie.generate_key_package().unwrap();
        let bob2 = MlsManager::new("12D3KooWBob").unwrap();
        let bob2_kp = bob2.generate_key_package().unwrap();

        let batch = vec![
            ("12D3KooWBob".to_string(), bob2_kp),       // duplicate — should be skipped
            ("12D3KooWCharlie".to_string(), charlie_kp), // new — should be added
        ];

        let (_, _, added) = owner.add_members_batch("server1", &batch).unwrap();
        owner.merge_pending_commit("server1").unwrap();

        // Only Charlie should be added, Bob skipped.
        assert_eq!(added.len(), 1);
        assert_eq!(added[0], "12D3KooWCharlie");
        assert_eq!(owner.member_count("server1"), 3); // owner + bob + charlie
    }

    #[test]
    fn test_batch_add_empty_returns_error() {
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();

        let result = owner.add_members_batch("server1", &[]);
        assert!(result.is_err());
    }

    #[test]
    fn test_batch_add_single_member() {
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();

        let bob = MlsManager::new("12D3KooWBob").unwrap();
        let bob_kp = bob.generate_key_package().unwrap();

        let batch = vec![("12D3KooWBob".to_string(), bob_kp)];
        let (_, welcome_bytes, added) = owner.add_members_batch("server1", &batch).unwrap();
        owner.merge_pending_commit("server1").unwrap();

        assert_eq!(added.len(), 1);
        assert_eq!(owner.member_count("server1"), 2);

        let mut bob = bob;
        bob.join_from_welcome("server1", &welcome_bytes).unwrap();
        assert_eq!(bob.member_count("server1"), 2);
    }

    #[test]
    fn test_six_members_all_communicate() {
        // Setup: owner + 6 peers, batch-added.
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();

        let peer_ids: Vec<String> = (1..=6).map(|i| format!("12D3KooWPeer{i}")).collect();
        let peers: Vec<MlsManager> = peer_ids.iter()
            .map(|id| MlsManager::new(id).unwrap())
            .collect();
        let key_packages: Vec<(String, Vec<u8>)> = peers.iter().zip(&peer_ids)
            .map(|(p, id)| (id.clone(), p.generate_key_package().unwrap()))
            .collect();

        let (_, welcome_bytes, _) = owner.add_members_batch("server1", &key_packages).unwrap();
        owner.merge_pending_commit("server1").unwrap();

        let mut all_peers: Vec<MlsManager> = peers.into_iter().map(|mut p| {
            p.join_from_welcome("server1", &welcome_bytes).unwrap();
            p
        }).collect();

        // Each peer sends a message, all others (including owner) decrypt it.
        for sender_idx in 0..all_peers.len() {
            let msg = format!("Message from peer {}", sender_idx + 1);
            let ct = all_peers[sender_idx].encrypt("server1", msg.as_bytes()).unwrap();

            // Owner decrypts.
            let (dec, sender) = owner.decrypt("server1", &ct).unwrap();
            assert_eq!(dec, msg.as_bytes());
            assert_eq!(sender, peer_ids[sender_idx]);

            // All other peers decrypt.
            for recv_idx in 0..all_peers.len() {
                if recv_idx == sender_idx { continue; }
                let (dec, sender) = all_peers[recv_idx].decrypt("server1", &ct).unwrap();
                assert_eq!(dec, msg.as_bytes());
                assert_eq!(sender, peer_ids[sender_idx]);
            }
        }

        // Owner sends, all peers decrypt.
        let owner_msg = b"Owner broadcast";
        let owner_ct = owner.encrypt("server1", owner_msg).unwrap();
        for p in &mut all_peers {
            let (dec, sender) = p.decrypt("server1", &owner_ct).unwrap();
            assert_eq!(dec, owner_msg.to_vec());
            assert_eq!(sender, "12D3KooWOwner");
        }
    }

    #[test]
    fn test_export_sframe_secret() {
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        let mut peer = MlsManager::new("12D3KooWPeer1").unwrap();

        owner.create_group("server1").unwrap();

        // Add peer to group.
        let kp = peer.generate_key_package().unwrap();
        let (commit, welcome) = owner.add_member("server1", &kp).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        peer.join_from_welcome("server1", &welcome).unwrap();

        // Both export the same SFrame key.
        let owner_key = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        let peer_key = peer.export_secret("server1", "sframe", b"", 32).unwrap();

        assert_eq!(owner_key.len(), 32);
        assert_eq!(peer_key.len(), 32);
        assert_eq!(owner_key, peer_key, "Both members should derive the same SFrame key");

        // Epoch should be consistent.
        let owner_epoch = owner.epoch("server1").unwrap();
        let peer_epoch = peer.epoch("server1").unwrap();
        assert_eq!(owner_epoch, peer_epoch);
        assert!(owner_epoch > 0);
    }

    #[test]
    fn test_two_same_human_leaves_share_sframe_key() {
        // Step 6: a human's TWO devices each hold a leaf (distinct device-id
        // credentials) in the same group. At the same epoch both leaves MUST
        // export the same SFrame key as every other member — MLS derives the
        // epoch secret from group state, not per-leaf identity.
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        owner.create_group("server1").unwrap();

        // Human X device A.
        let mut dev_a = MlsManager::new("12D3KooWHumanXDeviceA").unwrap();
        let (c_a, w_a) = owner.add_member("server1", &dev_a.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        dev_a.join_from_welcome("server1", &w_a).unwrap();
        let _ = c_a;

        // Human X device B (distinct credential, same human).
        let mut dev_b = MlsManager::new("12D3KooWHumanXDeviceB").unwrap();
        let (c_b, w_b) = owner.add_member("server1", &dev_b.generate_key_package().unwrap()).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        dev_a.process_commit("server1", &c_b).unwrap();
        dev_b.join_from_welcome("server1", &w_b).unwrap();

        // All three at the same epoch derive the identical SFrame key.
        let k_owner = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        let k_a = dev_a.export_secret("server1", "sframe", b"", 32).unwrap();
        let k_b = dev_b.export_secret("server1", "sframe", b"", 32).unwrap();
        assert_eq!(k_owner, k_a);
        assert_eq!(k_owner, k_b, "both of one human's leaves must derive the same SFrame key");
        assert_eq!(owner.epoch("server1").unwrap(), dev_b.epoch("server1").unwrap());

        // And both devices can decrypt an owner broadcast (two leaves, one human).
        let ct = owner.encrypt("server1", b"hello both devices").unwrap();
        assert_eq!(dev_a.decrypt("server1", &ct).unwrap().0, b"hello both devices".to_vec());
        // dev_b decrypts a SECOND copy (each leaf decrypts independently).
        let ct2 = owner.encrypt("server1", b"hello both devices").unwrap();
        assert_eq!(dev_b.decrypt("server1", &ct2).unwrap().0, b"hello both devices".to_vec());
    }

    #[test]
    fn test_sframe_key_rotates_on_membership_change() {
        let mut owner = MlsManager::new("12D3KooWOwner").unwrap();
        let mut peer1 = MlsManager::new("12D3KooWPeer1").unwrap();
        let mut peer2 = MlsManager::new("12D3KooWPeer2").unwrap();

        owner.create_group("server1").unwrap();

        // Add peer1.
        let kp1 = peer1.generate_key_package().unwrap();
        let (_, welcome1) = owner.add_member("server1", &kp1).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        peer1.join_from_welcome("server1", &welcome1).unwrap();

        let key_epoch1 = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        let epoch1 = owner.epoch("server1").unwrap();

        // Add peer2 — epoch changes, key should rotate.
        let kp2 = peer2.generate_key_package().unwrap();
        let (commit2, welcome2) = owner.add_member("server1", &kp2).unwrap();
        owner.merge_pending_commit("server1").unwrap();
        peer1.process_commit("server1", &commit2).unwrap();
        peer2.join_from_welcome("server1", &welcome2).unwrap();

        let key_epoch2 = owner.export_secret("server1", "sframe", b"", 32).unwrap();
        let epoch2 = owner.epoch("server1").unwrap();

        assert_ne!(key_epoch1, key_epoch2, "SFrame key must change when membership changes");
        assert!(epoch2 > epoch1, "Epoch must increase");

        // All three members should have the same new key.
        let peer1_key = peer1.export_secret("server1", "sframe", b"", 32).unwrap();
        let peer2_key = peer2.export_secret("server1", "sframe", b"", 32).unwrap();
        assert_eq!(key_epoch2, peer1_key);
        assert_eq!(key_epoch2, peer2_key);
    }

    /// Fix 1 (keystone regen): an OLD owned group (keystone owner + sibling + friend).
    /// The keystone REGENERATES a fresh device-credentialed leaf; the SIBLING re-adds it
    /// to the SAME group (one epoch advance — Welcome to the keystone, Commit to the
    /// friend). The friend must then DECRYPT a message from the regenerated keystone,
    /// and the group must NOT fork (sibling still decrypts at the same epoch).
    #[test]
    fn keystone_regen_rejoins_owned_group_via_sibling_no_fork() {
        // OLD owned server: keystone "M" (master-credentialed legacy leaf is just
        // credential id "M" here), sibling "MdevB", friend "F".
        let mut keystone_old = MlsManager::new("M").unwrap();
        keystone_old.create_group("oldsrv").unwrap();

        let mut sibling = MlsManager::new("MdevB").unwrap();
        let (_c1, w1) = keystone_old.add_member("oldsrv", &sibling.generate_key_package().unwrap()).unwrap();
        keystone_old.merge_pending_commit("oldsrv").unwrap();
        sibling.join_from_welcome("oldsrv", &w1).unwrap();

        let mut friend = MlsManager::new("F").unwrap();
        let (c2, w2) = keystone_old.add_member("oldsrv", &friend.generate_key_package().unwrap()).unwrap();
        keystone_old.merge_pending_commit("oldsrv").unwrap();
        sibling.process_commit("oldsrv", &c2).unwrap();
        friend.join_from_welcome("oldsrv", &w2).unwrap();

        // Keystone REGENERATES: a fresh manager with the SAME credential id "M" but a
        // brand-new signature key + no groups (what startup does on `stale_keystone`).
        let mut keystone_new = MlsManager::new("M").unwrap();
        assert!(!keystone_new.has_group("oldsrv"), "regenerated keystone has no group yet");

        // The OLD keystone leaf (credential "M") is STILL in the group, colliding with
        // the new one's credential id. Production handles this in the batch processor:
        // Phase 1 REMOVES the stale "M" leaf (commit 1), Phase 2 ADDS the new "M" leaf
        // (commit 2). Model both, with the friend applying each commit.
        // Phase 1: sibling removes the stale "M" leaf.
        let c_rm = sibling.remove_member("oldsrv", "M").unwrap();
        sibling.merge_pending_commit("oldsrv").unwrap();
        friend.process_commit("oldsrv", &c_rm).unwrap();

        // Phase 2: sibling adds the keystone's NEW leaf (now "M" is free).
        let kp = keystone_new.generate_key_package().unwrap();
        let (c3, w3, added) = sibling.add_members_batch("oldsrv", &[("M".into(), kp)]).unwrap();
        sibling.merge_pending_commit("oldsrv").unwrap();
        assert_eq!(added, vec!["M".to_string()], "sibling added the keystone's new leaf");
        // Friend applies the same commit (no fork — same group, advanced one epoch).
        friend.process_commit("oldsrv", &c3).unwrap();
        keystone_new.join_from_welcome("oldsrv", &w3).unwrap();

        // THE ASSERT: friend decrypts a channel message from the REGENERATED keystone.
        let ct = keystone_new.encrypt("oldsrv", b"hello from regenerated keystone").unwrap();
        let (pt, sender) = friend.decrypt("oldsrv", &ct).unwrap();
        assert_eq!(pt, b"hello from regenerated keystone".to_vec());
        assert_eq!(sender, "M", "decrypted message attributed to the keystone leaf id");

        // No fork: the sibling also decrypts at the same epoch.
        let ct2 = keystone_new.encrypt("oldsrv", b"again").unwrap();
        assert_eq!(sibling.decrypt("oldsrv", &ct2).unwrap().0, b"again".to_vec());

        // And the friend's SFrame key matches the keystone's (same epoch, no fork).
        assert_eq!(
            friend.export_secret("oldsrv", "sframe", b"", 32).unwrap(),
            keystone_new.export_secret("oldsrv", "sframe", b"", 32).unwrap(),
            "friend + regenerated keystone share the same epoch SFrame key (no fork)"
        );
    }
}
