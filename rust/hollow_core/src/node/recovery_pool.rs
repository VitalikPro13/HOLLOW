//! Recovery Pool coordinator module (Evidence Recovery).
//!
//! Manages cooperative shard gathering for ex-members of dead servers.
//! Tracks pool membership, shard inventories, transfer plans, and
//! reconstruction status.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

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
    pub token: String,
    pub is_initiator: bool,
    pub local_peer_id: String,
    /// All members in the pool: peer_id → their inventory.
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
        local_peer_id: String,
        local_inventory: MemberInventory,
    ) -> Self {
        let mut all_manifest_ids = HashSet::new();
        for id in &local_inventory.manifest_ids {
            all_manifest_ids.insert(id.clone());
        }

        let mut members = HashMap::new();
        members.insert(local_peer_id.clone(), local_inventory);

        Self {
            server_id,
            token,
            is_initiator,
            local_peer_id,
            members,
            all_manifest_ids,
            file_k_values: HashMap::new(),
            manifest_meta: HashMap::new(),
            received_shards: HashSet::new(),
            reconstructed: HashSet::new(),
        }
    }

    /// Add a new member to the pool with their inventory.
    pub fn add_member(&mut self, peer_id: String, inventory: MemberInventory) {
        for id in &inventory.manifest_ids {
            self.all_manifest_ids.insert(id.clone());
        }
        self.members.insert(peer_id, inventory);
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
        format!("recovery:{}:{}", self.server_id, self.token)
    }

    /// Get the member count.
    pub fn member_count(&self) -> usize {
        self.members.len()
    }

    /// Get list of member peer IDs.
    pub fn member_ids(&self) -> Vec<String> {
        self.members.keys().cloned().collect()
    }

    /// Whether this peer is the coordinator (lowest peer_id among all members).
    pub fn is_coordinator(&self) -> bool {
        self.members.keys().min().map_or(false, |min| min == &self.local_peer_id)
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
