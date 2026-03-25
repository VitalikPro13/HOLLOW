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
    /// Create a new MlsManager with a fresh MLS identity derived from peer_id.
    pub fn new(peer_id: &str) -> Result<Self, String> {
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
    pub fn remove_member(
        &mut self,
        server_id: &str,
        peer_id: &str,
    ) -> Result<Vec<u8>, String> {
        let group = self.groups.get_mut(server_id)
            .ok_or_else(|| format!("No MLS group for server {server_id}"))?;

        // Find the member's leaf index by matching credential identity.
        let leaf_index = group
            .members()
            .find(|member| {
                let identity = member.credential.serialized_content();
                identity == peer_id.as_bytes()
            })
            .map(|member| member.index)
            .ok_or_else(|| format!("Peer {peer_id} not found in MLS group for {server_id}"))?;

        let (commit_out, _welcome, _group_info) = group
            .remove_members(&self.provider, &self.signer, &[leaf_index])
            .map_err(|e| format!("Failed to remove member: {e:?}"))?;

        let commit_bytes = TlsSerialize::tls_serialize_detached(&commit_out)
            .map_err(|e| format!("Failed to serialize remove commit: {e:?}"))?;

        hollow_log!("[HOLLOW-MLS] remove_member commit for {peer_id} in server {server_id}");
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

    /// Get the number of members in the MLS group.
    pub fn member_count(&self, server_id: &str) -> usize {
        self.groups
            .get(server_id)
            .map(|g| g.members().count())
            .unwrap_or(0)
    }

    /// Remove MLS group for a server (on server delete/leave).
    pub fn remove_group(&mut self, server_id: &str) {
        self.groups.remove(server_id);
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
}
