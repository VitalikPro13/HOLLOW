//! Recovery Pool coordinator module (Evidence Recovery).
//!
//! Manages cooperative shard gathering for ex-members of dead servers.
//! Tracks pool membership, shard inventories, transfer plans, and
//! reconstruction status.

use std::collections::{HashMap, HashSet};

use base64::Engine;
use serde::{Deserialize, Serialize};

use super::types::{HavenMessage, Lane};

/// A member's local shard inventory.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberInventory {
    /// content_ids of vault manifests this member has.
    pub manifest_ids: Vec<String>,
    /// Map of content_id → list of shard_indices held locally.
    pub shards: HashMap<String, Vec<u16>>,
}

impl MemberInventory {
    pub fn empty() -> Self {
        Self {
            manifest_ids: Vec::new(),
            shards: HashMap::new(),
        }
    }
}

/// A single transfer assignment in the recovery plan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferAssignment {
    pub content_id: String,
    pub shard_index: u16,
    pub source_peer: String,
    pub dest_peer: String,
}

/// Pool-wide status for the dashboard.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PoolStatus {
    pub total_files: u32,
    pub reconstructable: u32,
    pub partial: u32,
    pub no_shards: u32,
    pub progress_pct: f32,
}

/// Manifest metadata for a vault file, used for shard transfer registration.
#[derive(Debug, Clone)]
pub struct ManifestMeta {
    pub k: u16,
    pub m: u16,
    pub total_data_size: u64,
    pub storage_tier: String,
    pub file_name: String,
}

/// State of an active recovery pool.
pub struct RecoveryPoolState {
    pub server_id: String,
    token: String,
    room: String,
    pub is_initiator: bool,
    /// Our DEVICE id. Every member is keyed by the device that seals its frames, ours
    /// too, so all members elect the same coordinator and read a plan's ids alike.
    pub local_device: String,
    /// All members in the pool: device id → their inventory.
    pub members: HashMap<String, MemberInventory>,
    /// Union of all manifest content_ids known to any member.
    pub all_manifest_ids: HashSet<String>,
    /// Per content_id: k value needed for reconstruction.
    pub file_k_values: HashMap<String, u16>,
    /// Per content_id: full manifest metadata (k, m, size, tier, name).
    pub manifest_meta: HashMap<String, ManifestMeta>,
    /// Shards received during this pool session (content_id, shard_index).
    pub received_shards: HashSet<(String, u16)>,
    /// Files that have been fully reconstructed.
    pub reconstructed: HashSet<String>,
}

impl RecoveryPoolState {
    pub fn new(
        server_id: String,
        token: String,
        is_initiator: bool,
        local_device: String,
        local_inventory: MemberInventory,
    ) -> Self {
        let mut all_manifest_ids = HashSet::new();
        for id in &local_inventory.manifest_ids {
            all_manifest_ids.insert(id.clone());
        }

        let mut members = HashMap::new();
        members.insert(local_device.clone(), local_inventory);

        Self {
            room: pool_room(&server_id, &token),
            server_id,
            token,
            is_initiator,
            local_device,
            members,
            all_manifest_ids,
            file_k_values: HashMap::new(),
            manifest_meta: HashMap::new(),
            received_shards: HashSet::new(),
            reconstructed: HashSet::new(),
        }
    }

    /// Add a member with its inventory, or refresh one we hold. Whether it is new.
    pub fn add_member(&mut self, peer_id: String, inventory: MemberInventory) -> bool {
        for id in &inventory.manifest_ids {
            self.all_manifest_ids.insert(id.clone());
        }
        self.members.insert(peer_id, inventory).is_none()
    }

    /// Remove a member from the pool.
    pub fn remove_member(&mut self, peer_id: &str) {
        self.members.remove(peer_id);
    }

    /// Record that a shard was received.
    pub fn mark_shard_received(&mut self, content_id: &str, shard_index: u16) {
        self.received_shards
            .insert((content_id.to_string(), shard_index));
    }

    /// Mark a file as reconstructed.
    pub fn mark_reconstructed(&mut self, content_id: &str) {
        self.reconstructed.insert(content_id.to_string());
    }

    /// Compute pool-wide status.
    pub fn compute_status(&self) -> PoolStatus {
        let total_files = self.all_manifest_ids.len() as u32;
        let reconstructable = self.reconstructed.len() as u32;

        // Count files with at least one shard in the pool but not yet reconstructed.
        let mut partial = 0u32;
        let mut no_shards = 0u32;
        for cid in &self.all_manifest_ids {
            if self.reconstructed.contains(cid) {
                continue;
            }
            let has_any = self.members.values().any(|inv| {
                inv.shards.get(cid).map_or(false, |v| !v.is_empty())
            });
            if has_any {
                partial += 1;
            } else {
                no_shards += 1;
            }
        }

        let progress_pct = if total_files > 0 {
            reconstructable as f32 / total_files as f32
        } else {
            0.0
        };

        PoolStatus {
            total_files,
            reconstructable,
            partial,
            no_shards,
            progress_pct,
        }
    }

    /// Compute the transfer plan: which shards should be sent from which peer
    /// to which other peer. Prioritizes files closest to k completion.
    pub fn compute_transfer_plan(&self) -> Vec<TransferAssignment> {
        let mut assignments = Vec::new();

        // For each content_id, figure out which shards exist in the pool
        // and which peers need them.
        for cid in &self.all_manifest_ids {
            if self.reconstructed.contains(cid) {
                continue;
            }

            // Collect: who has which shard indices.
            let mut shard_holders: HashMap<u16, Vec<String>> = HashMap::new();
            let mut all_peer_shards: HashMap<String, HashSet<u16>> = HashMap::new();

            for (peer_id, inv) in &self.members {
                if let Some(indices) = inv.shards.get(cid) {
                    let set = all_peer_shards
                        .entry(peer_id.clone())
                        .or_default();
                    for &idx in indices {
                        shard_holders
                            .entry(idx)
                            .or_default()
                            .push(peer_id.clone());
                        set.insert(idx);
                    }
                }
            }

            // For each shard, find peers that DON'T have it and assign a transfer
            // from someone who does.
            for (&shard_index, holders) in &shard_holders {
                if holders.is_empty() {
                    continue;
                }
                let source = &holders[0]; // Pick first holder as source.
                for (peer_id, their_shards) in &all_peer_shards {
                    if peer_id == source {
                        continue;
                    }
                    if their_shards.contains(&shard_index) {
                        continue; // Already has it.
                    }
                    assignments.push(TransferAssignment {
                        content_id: cid.clone(),
                        shard_index,
                        source_peer: source.clone(),
                        dest_peer: peer_id.clone(),
                    });
                }
                // Also send to peers that have zero shards for this content.
                for peer_id in self.members.keys() {
                    if all_peer_shards.contains_key(peer_id) {
                        continue; // Already handled above.
                    }
                    assignments.push(TransferAssignment {
                        content_id: cid.clone(),
                        shard_index,
                        source_peer: source.clone(),
                        dest_peer: peer_id.clone(),
                    });
                }
            }
        }

        assignments
    }

    /// Get the room code for this pool.
    pub fn room_code(&self) -> String {
        self.room.clone()
    }

    /// `msg` from our device `sender`, as the pool's lane carries it.
    pub(crate) fn seal(&self, sender: &str, msg: &HavenMessage) -> Option<Vec<u8>> {
        seal_control(&self.server_id, &self.token, sender, msg)
    }

    /// The pool message inside a `RecoverySealed` that `sender` put into `room`. `None`
    /// unless it came through this pool's room, the token opens it for that sender and
    /// what it holds is pool traffic.
    pub(crate) fn open_control(&self, room: &str, sender: &str, nonce: &str, ct: &str) -> Option<HavenMessage> {
        use aes_gcm::aead::{Aead, Payload};
        if room != self.room {
            return None;
        }
        let engine = base64::engine::general_purpose::STANDARD;
        let nonce: [u8; 12] = engine.decode(nonce).ok()?.try_into().ok()?;
        let ct = engine.decode(ct).ok()?;
        let aad = control_aad(room, sender);
        let plain = control_cipher(&self.server_id, &self.token)?
            .decrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &ct, aad: &aad })
            .ok()?;
        let msg: HavenMessage = serde_json::from_slice(&plain).ok()?;
        (msg.lane() == Lane::Recovery).then_some(msg)
    }

    /// Get the member count.
    pub fn member_count(&self) -> usize {
        self.members.len()
    }

    /// Get list of member peer IDs.
    pub fn member_ids(&self) -> Vec<String> {
        self.members.keys().cloned().collect()
    }

    /// Our own inventory, as the pool holds it.
    pub fn own_inventory(&self) -> Option<&MemberInventory> {
        self.members.get(&self.local_device)
    }

    /// The member that plans the pool's transfers: the lowest device id.
    pub fn coordinator(&self) -> Option<&str> {
        self.members.keys().min().map(String::as_str)
    }

    /// Whether we are the coordinator.
    pub fn is_coordinator(&self) -> bool {
        self.coordinator() == Some(self.local_device.as_str())
    }

    /// Populate manifest metadata from the local ContentStore.
    /// Fills `manifest_meta` and `file_k_values` for all erasure-coded files.
    pub fn populate_from_content_store(
        &mut self,
        cs: &crate::vault::content_store::ContentStore,
    ) {
        let manifests = cs.list_manifests(&self.server_id).unwrap_or_default();
        for manifest in manifests {
            if manifest.k == 0 && manifest.m == 0 {
                continue; // Skip full-replication files.
            }
            self.file_k_values
                .insert(manifest.content_id.clone(), manifest.k);
            self.manifest_meta.insert(
                manifest.content_id.clone(),
                ManifestMeta {
                    k: manifest.k,
                    m: manifest.m,
                    total_data_size: manifest.original_size,
                    storage_tier: manifest.storage_tier.clone(),
                    file_name: manifest.file_name.clone(),
                },
            );
        }
    }
}

/// Build a MemberInventory from the local ContentStore.
pub fn build_local_inventory(
    cs: &crate::vault::content_store::ContentStore,
    server_id: &str,
) -> MemberInventory {
    let manifests = cs.list_manifests(server_id).unwrap_or_default();
    let manifest_ids: Vec<String> = manifests
        .iter()
        .filter(|m| m.k > 0 || m.m > 0)
        .map(|m| m.content_id.clone())
        .collect();

    let all_shards = cs.list_shards(server_id).unwrap_or_default();
    let mut shards: HashMap<String, Vec<u16>> = HashMap::new();
    for shard in all_shards {
        shards
            .entry(shard.content_id.clone())
            .or_default()
            .push(shard.shard_index);
    }

    MemberInventory {
        manifest_ids,
        shards,
    }
}

// ── The pool lane ────────────────────────────────────────────────────────
//
// A pool's authority is its invite token (the server is dead, so no member list or
// group speaks for it). The relay sees only a hash of the token as the room name, and
// every frame is sealed under a key derived from it, so a frame that opens proves its
// sender holds the invite (claim C-24 for what pool members hold).

const ROOM_DOMAIN: &[u8] = b"hollow-recovery-room1";
const CONTROL_DOMAIN: &[u8] = b"hollow-recovery-ctl1";

fn framed(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for part in parts {
        out.extend_from_slice(&(part.len() as u32).to_be_bytes());
        out.extend_from_slice(part);
    }
    out
}

/// The relay room of the pool for `server_id` opened under `token`.
pub(crate) fn pool_room(server_id: &str, token: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(framed(&[ROOM_DOMAIN, server_id.as_bytes(), token.as_bytes()]));
    format!("recovery:{}", hex::encode(&digest[..16]))
}

fn control_cipher(server_id: &str, token: &str) -> Option<aes_gcm::Aes256Gcm> {
    use hmac::{Hmac, Mac};
    let mut mac = <Hmac<sha2::Sha256> as Mac>::new_from_slice(token.as_bytes()).ok()?;
    mac.update(&framed(&[CONTROL_DOMAIN, server_id.as_bytes()]));
    let key = zeroize::Zeroizing::new(mac.finalize().into_bytes());
    <aes_gcm::Aes256Gcm as aes_gcm::KeyInit>::new_from_slice(key.as_slice()).ok()
}

/// A sealed frame opens only in the pool's room and only as the device that sealed it.
fn control_aad(room: &str, sender: &str) -> Vec<u8> {
    framed(&[CONTROL_DOMAIN, room.as_bytes(), sender.as_bytes()])
}

/// The wire bytes of a pool message from device `sender`, sealed under the pool's token.
pub(crate) fn seal_control(server_id: &str, token: &str, sender: &str, msg: &HavenMessage) -> Option<Vec<u8>> {
    debug_assert_eq!(msg.lane(), Lane::Recovery, "only pool traffic rides the pool lane");
    seal_in(server_id, token, &pool_room(server_id, token), sender, msg)
}

fn seal_in(server_id: &str, token: &str, room: &str, sender: &str, msg: &HavenMessage) -> Option<Vec<u8>> {
    use aes_gcm::aead::{Aead, Payload};
    let plain = serde_json::to_vec(msg).ok()?;
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).ok()?;
    let aad = control_aad(room, sender);
    let ct = control_cipher(server_id, token)?
        .encrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &plain, aad: &aad })
        .ok()?;
    let engine = base64::engine::general_purpose::STANDARD;
    serde_json::to_vec(&HavenMessage::RecoverySealed { nonce: engine.encode(nonce), ct: engine.encode(ct) }).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parts(sealed: &[u8]) -> (String, String) {
        match serde_json::from_slice::<HavenMessage>(sealed).expect("sealed frame parses") {
            HavenMessage::RecoverySealed { nonce, ct } => (nonce, ct),
            other => panic!("expected recovery_sealed, got {}", other.wire_kind()),
        }
    }

    /// A24: a pool frame opens only under the pool's token, in its room, for the
    /// device that sealed it, and only as pool traffic.
    #[test]
    fn a_pool_frame_opens_only_under_its_token_in_its_room_for_its_sender() {
        let pool = RecoveryPoolState::new("sid".into(), "tok".into(), true, "me".into(), MemberInventory::empty());
        let room = pool.room_code();
        assert!(!room.contains("tok") && room != pool_room("sid", "tok2") && room != pool_room("sid2", "tok"));

        let stop = HavenMessage::RecoveryStop;
        let (n, c) = parts(&seal_control("sid", "tok", "dev", &stop).unwrap());
        assert!(matches!(pool.open_control(&room, "dev", &n, &c), Some(HavenMessage::RecoveryStop)));
        assert!(pool.open_control(&room, "other", &n, &c).is_none(), "it speaks only for its sealer");

        let (n, c) = parts(&seal_control("sid", "tok2", "dev", &stop).unwrap());
        assert!(pool.open_control(&room, "dev", &n, &c).is_none(), "another token opens nothing");
        // The relay knows the room, never the token.
        let (n, c) = parts(&seal_in("sid", "tok2", &room, "dev", &stop).unwrap());
        assert!(pool.open_control(&room, "dev", &n, &c).is_none(), "the room name alone seals nothing");
        let (n, c) = parts(&seal_in("sid2", "tok", &room, "dev", &stop).unwrap());
        assert!(pool.open_control(&room, "dev", &n, &c).is_none(), "the key is the pool's server's");

        let (n, c) = parts(&seal_in("sid", "tok", "recovery:elsewhere", "dev", &stop).unwrap());
        assert!(pool.open_control("recovery:elsewhere", "dev", &n, &c).is_none(), "only in the pool's own room");

        let (n, c) = parts(&seal_in("sid", "tok", &room, "dev", &HavenMessage::FriendListRequest).unwrap());
        assert!(pool.open_control(&room, "dev", &n, &c).is_none(), "only pool traffic opens");
    }
}
