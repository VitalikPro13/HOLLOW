use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use super::admin_lww::AdminLwwReg;
use super::hlc::{Hlc, HlcTimestamp};
use super::operations::{CrdtOp, CrdtPayload, MemberRole, Permission};

/// Type of channel within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChannelType {
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "voice")]
    Voice,
}

impl Default for ChannelType {
    fn default() -> Self {
        Self::Text
    }
}

/// An item in the channel layout — category header, channel reference, or separator.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ChannelLayoutItem {
    #[serde(rename = "category")]
    Category { name: String },
    #[serde(rename = "channel")]
    Channel { channel_id: String },
    #[serde(rename = "separator")]
    Separator,
}

/// A label (tag) that can be assigned to members. Cosmetic by default;
/// `access: true` makes it a security boundary: it can gate channels
/// (`ChannelInfo::visibility_labels`/`posting_labels`) and is therefore
/// never self-assignable — only MANAGE_ROLES holders assign it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct LabelInfo {
    pub label_id: String,
    pub name: String,
    pub color: String,
    #[serde(default)]
    pub access: bool,
}

/// A custom server emote. METADATA ONLY — the image bytes are content-
/// addressed by `hash` (SHA-256 hex of the processed WebP) and replicate
/// on demand via EmoteRequest/EmoteResponse, never through the CRDT.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EmoteInfo {
    pub name: String,
    pub hash: String,
    #[serde(default)]
    pub animated: bool,
}

/// Hard cap on custom emotes per server (enforced at authoring AND apply so
/// replicas converge on the same refusal).
pub const MAX_SERVER_EMOTES: usize = 50;

/// A sticker of a server's set. METADATA ONLY, same as [EmoteInfo] — the
/// bytes are content-addressed by `hash` and replicate on demand over the
/// asset rail at `AssetKind::Sticker`.
///
/// `w`/`h` are carried so the picker (and the `[a:s:hash:w:h]` token the
/// composer writes) can reserve the exact cell before any bytes land.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StickerInfo {
    pub hash: String,
    #[serde(default)]
    pub name: String,
    /// Group label inside the server's set (`""` = the default pack).
    #[serde(default)]
    pub pack: String,
    #[serde(default)]
    pub animated: bool,
    #[serde(default)]
    pub w: u32,
    #[serde(default)]
    pub h: u32,
}

/// Hard cap on stickers per server (authoring AND apply, like emotes).
/// Deliberately the same number as emotes even though the blobs are ~20x
/// bigger: a member opening the sticker picker pulls the bytes of whatever
/// scrolls into view, so the ceiling is a bandwidth decision as much as a
/// storage one.
pub const MAX_SERVER_STICKERS: usize = 50;

/// Max characters in a sticker's label or pack name. Stickers are picked
/// visually and never typed, so unlike emote names these are free-form —
/// bounded, and rejected outright if they carry control characters.
pub const MAX_STICKER_LABEL: usize = 32;

/// Grammar for a sticker label / pack name: short, no control characters.
/// Empty is legal (an unnamed sticker in the default pack).
pub fn valid_sticker_label(s: &str) -> bool {
    s.chars().count() <= MAX_STICKER_LABEL && !s.chars().any(|c| c.is_control())
}

/// Who can see a channel.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChannelVisibility {
    #[serde(rename = "everyone")]
    Everyone,
    #[serde(rename = "moderator")]
    ModeratorPlus,
    #[serde(rename = "admin")]
    AdminPlus,
}

impl Default for ChannelVisibility {
    fn default() -> Self {
        Self::Everyone
    }
}

/// Who can post in a channel.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChannelPosting {
    #[serde(rename = "everyone")]
    Everyone,
    #[serde(rename = "moderator")]
    ModeratorPlus,
    #[serde(rename = "admin")]
    AdminPlus,
}

impl Default for ChannelPosting {
    fn default() -> Self {
        Self::Everyone
    }
}

/// Metadata for a channel within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ChannelInfo {
    pub channel_id: String,
    pub name: String,
    pub category: Option<String>,
    #[serde(default)]
    pub channel_type: ChannelType,
    #[serde(default)]
    pub visibility: ChannelVisibility,
    #[serde(default)]
    pub posting: ChannelPosting,
    #[serde(default)]
    pub is_public: bool,
    /// Slow mode: minimum seconds between messages per member (0 = off).
    /// Moderator+ are exempt.
    #[serde(default)]
    pub slow_mode: u32,
    /// Media-only: only image/video/GIF attachments (with optional captions)
    /// may be posted; standalone text and other file types are rejected.
    #[serde(default)]
    pub media_only: bool,
    /// Label gate for visibility (issue #32). Non-empty REPLACES the tier
    /// ladder: holders of ANY listed label (plus Admin+/Owner) see the
    /// channel. Always authored alongside a `visibility: AdminPlus` stamp so
    /// clients that predate this field fail closed.
    #[serde(default)]
    pub visibility_labels: Vec<String>,
    /// Label gate for posting; same semantics as `visibility_labels`.
    #[serde(default)]
    pub posting_labels: Vec<String>,
}

/// Metadata for a member within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MemberInfo {
    pub peer_id: String,
    pub display_name: String,
}

/// The full CRDT state of a Hollow server.
///
/// Uses operation-based CRDTs: all mutations go through `apply_op()`,
/// which is commutative and idempotent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerState {
    pub server_id: String,
    pub name: AdminLwwReg<String>,
    pub channels: HashMap<String, ChannelInfo>,
    pub members: HashMap<String, MemberInfo>,
    pub roles: HashMap<String, AdminLwwReg<MemberRole>>,
    #[serde(default)]
    pub nicknames: HashMap<String, AdminLwwReg<String>>,
    #[serde(default)]
    pub twitch_usernames: HashMap<String, AdminLwwReg<String>>,
    #[serde(default)]
    pub pinned_messages: HashMap<String, Vec<String>>,
    #[serde(default)]
    pub channel_layout: Vec<ChannelLayoutItem>,
    #[serde(default)]
    pub storage_pledges: HashMap<String, AdminLwwReg<u64>>,
    pub settings: HashMap<String, AdminLwwReg<String>>,
    #[serde(default)]
    pub role_permissions: HashMap<String, AdminLwwReg<u32>>,
    #[serde(default)]
    pub banned_members: HashMap<String, AdminLwwReg<bool>>,
    /// Muted members (server-wide read-only): master peer_id -> mute expiry in
    /// epoch ms. `u64::MAX` = permanent, `0` = unmuted (pruned on unmute).
    #[serde(default)]
    pub muted_members: HashMap<String, AdminLwwReg<u64>>,
    /// Temporary channel access grants: channel_id -> master peer_id -> expiry
    /// epoch ms. `u64::MAX` = until revoked, `0` = revoked (pruned only in the
    /// ChannelGrantRevoked arm). Modeled exactly on `muted_members`: LWW per
    /// entry, lazy expiry at read time, no background pruning.
    #[serde(default)]
    pub channel_grants: HashMap<String, HashMap<String, AdminLwwReg<u64>>>,
    #[serde(default)]
    pub labels: HashMap<String, LabelInfo>,
    #[serde(default)]
    pub label_assignments: HashMap<String, Vec<String>>,
    /// Custom emote set, keyed by emote name. `#[serde(default)]` so every
    /// pre-existing persisted ServerState loads with an empty set.
    #[serde(default)]
    pub emotes: HashMap<String, EmoteInfo>,
    /// Sticker set, keyed by content HASH (a sticker is picked, never typed,
    /// so its name is not an identity). `#[serde(default)]` so every
    /// pre-existing persisted ServerState loads with an empty set.
    #[serde(default)]
    pub stickers: HashMap<String, StickerInfo>,
    /// Tombstone latch (Step "server sync hardening"): set true by a `ServerDeleted`
    /// op. The state shell + op_log are RETAINED (not removed) so this node keeps
    /// serving the deletion op to reconnecting peers via normal grow-only sync.
    /// Monotonic delete-wins (there is no un-delete op). UI hides tombstoned servers.
    /// `#[serde(default)]` so every pre-existing persisted ServerState loads as false.
    #[serde(default)]
    pub deleted: bool,
    #[serde(default, skip_serializing)]
    pub op_log: Vec<CrdtOp>,
    #[serde(skip)]
    pub hlc: Option<Hlc>,
    #[serde(skip)]
    op_log_dedup: HashSet<(String, HlcTimestamp)>,
}

impl ServerState {
    /// A serialization-only clone: everything the persisted JSON contains,
    /// with the heavy in-memory-only fields (`op_log`, dedup set, hlc) left
    /// empty. `op_log` is `skip_serializing` and `hlc`/`op_log_dedup` are
    /// `skip`, so JSON produced from this snapshot is identical to
    /// serializing `self` — but cloning skips up to 1000 op-log entries.
    /// Used by CrdtStore::save_state_snapshot to move the JSON serialization
    /// off the event loop (a burst of N ops then serializes ONCE per drain).
    /// Exhaustive destructuring on purpose: adding a ServerState field breaks
    /// this method at compile time, forcing a decision on whether it persists
    /// (guards the "field silently missing from saved state" trap).
    pub fn lean_snapshot(&self) -> ServerState {
        let ServerState {
            server_id, name, channels, members, roles, nicknames,
            twitch_usernames, pinned_messages, channel_layout, storage_pledges,
            settings, role_permissions, banned_members, muted_members,
            channel_grants, labels, label_assignments, emotes, stickers, deleted,
            op_log: _, hlc: _, op_log_dedup: _,
        } = self;
        ServerState {
            server_id: server_id.clone(),
            name: name.clone(),
            channels: channels.clone(),
            members: members.clone(),
            roles: roles.clone(),
            nicknames: nicknames.clone(),
            twitch_usernames: twitch_usernames.clone(),
            pinned_messages: pinned_messages.clone(),
            channel_layout: channel_layout.clone(),
            storage_pledges: storage_pledges.clone(),
            settings: settings.clone(),
            role_permissions: role_permissions.clone(),
            banned_members: banned_members.clone(),
            muted_members: muted_members.clone(),
            channel_grants: channel_grants.clone(),
            labels: labels.clone(),
            label_assignments: label_assignments.clone(),
            emotes: emotes.clone(),
            stickers: stickers.clone(),
            deleted: *deleted,
            op_log: Vec::new(),
            hlc: None,
            op_log_dedup: HashSet::new(),
        }
    }

    /// Create a new server. The creator becomes the Owner.
    pub fn new(server_id: String, name: String, creator_peer_id: String) -> Self {
        let mut hlc = Hlc::new(creator_peer_id.clone());
        let ts = hlc.now();

        let mut channels = HashMap::new();
        // Every server starts with a #general channel
        let general_id = format!("{}-general", &server_id[..8.min(server_id.len())]);
        channels.insert(
            general_id.clone(),
            ChannelInfo {
                channel_id: general_id,
                name: "general".to_string(),
                category: None,
                channel_type: ChannelType::Text,
                visibility: ChannelVisibility::Everyone,
                posting: ChannelPosting::Everyone,
                is_public: false,
                slow_mode: 0,
                media_only: false,
                visibility_labels: Vec::new(),
                posting_labels: Vec::new(),
            },
        );

        let mut members = HashMap::new();
        members.insert(
            creator_peer_id.clone(),
            MemberInfo {
                peer_id: creator_peer_id.clone(),
                display_name: short_name(&creator_peer_id),
            },
        );

        let mut roles = HashMap::new();
        roles.insert(
            creator_peer_id.clone(),
            AdminLwwReg::new(MemberRole::Owner, ts.clone(), MemberRole::Owner.priority()),
        );

        Self {
            server_id,
            name: AdminLwwReg::new(name, ts, MemberRole::Owner.priority()),
            channels,
            members,
            roles,
            nicknames: HashMap::new(),
            twitch_usernames: HashMap::new(),
            pinned_messages: HashMap::new(),
            channel_layout: Vec::new(),
            storage_pledges: HashMap::new(),
            settings: HashMap::new(),
            role_permissions: HashMap::new(),
            banned_members: HashMap::new(),
            muted_members: HashMap::new(),
            channel_grants: HashMap::new(),
            labels: HashMap::new(),
            label_assignments: HashMap::new(),
            emotes: HashMap::new(),
            stickers: HashMap::new(),
            deleted: false,
            op_log: Vec::new(),
            hlc: Some(hlc),
            op_log_dedup: HashSet::new(),
        }
    }

    /// Restore from persistence (HLC set separately via `set_hlc`).
    pub fn set_hlc(&mut self, hlc: Hlc) {
        self.hlc = Some(hlc);
    }

    /// Multi-device (Step 6): fold any per-member entry that is keyed by a DEVICE
    /// id into its MASTER identity, so one human appears once. `resolve` maps a
    /// peer_id to its master (identity-passthrough for unknowns — single-device
    /// is a no-op). This is a LOCAL cleanup (emits no CRDT op): legacy servers
    /// recorded joiners under their device id before membership was canonicalized
    /// to master; this drains those without a re-key. Future ops are already
    /// master-keyed at the source. Returns true if anything was re-keyed.
    ///
    /// Conflict resolution: LWW registers fold via `AdminLwwReg::merge` (pure
    /// HLC — the latest write survives). Plain entries keep the existing
    /// master entry if present, else adopt the device entry's value under the
    /// master key.
    pub fn canonicalize_members(&mut self, resolve: impl Fn(&str) -> String) -> bool {
        let mut changed = false;

        // Helper: re-key an AdminLwwReg map device→master, merging on collision.
        fn fold_lww<V: Clone>(
            map: &mut HashMap<String, AdminLwwReg<V>>,
            resolve: &impl Fn(&str) -> String,
        ) -> bool {
            let mut changed = false;
            let keys: Vec<String> = map.keys().cloned().collect();
            for k in keys {
                let master = resolve(&k);
                if master == k {
                    continue; // already canonical (or unknown → self)
                }
                if let Some(dev_reg) = map.remove(&k) {
                    match map.get_mut(&master) {
                        Some(existing) => existing.merge(&dev_reg),
                        None => {
                            map.insert(master, dev_reg);
                        }
                    }
                    changed = true;
                }
            }
            changed
        }

        // members: keep existing master entry; else adopt device entry under master.
        {
            let keys: Vec<String> = self.members.keys().cloned().collect();
            for k in keys {
                let master = resolve(&k);
                if master == k {
                    continue;
                }
                if let Some(mut info) = self.members.remove(&k) {
                    info.peer_id = master.clone();
                    self.members.entry(master).or_insert(info);
                    changed = true;
                }
            }
        }

        changed |= fold_lww(&mut self.roles, &resolve);
        changed |= fold_lww(&mut self.nicknames, &resolve);
        changed |= fold_lww(&mut self.twitch_usernames, &resolve);
        changed |= fold_lww(&mut self.storage_pledges, &resolve);
        changed |= fold_lww(&mut self.banned_members, &resolve);
        changed |= fold_lww(&mut self.muted_members, &resolve);
        // channel_grants: per-channel inner maps are master-keyed like mutes.
        for regs in self.channel_grants.values_mut() {
            changed |= fold_lww(regs, &resolve);
        }

        // label_assignments: Vec<label_id> per member — union under master.
        {
            let keys: Vec<String> = self.label_assignments.keys().cloned().collect();
            for k in keys {
                let master = resolve(&k);
                if master == k {
                    continue;
                }
                if let Some(labels) = self.label_assignments.remove(&k) {
                    let entry = self.label_assignments.entry(master).or_default();
                    for l in labels {
                        if !entry.contains(&l) {
                            entry.push(l);
                        }
                    }
                    changed = true;
                }
            }
        }

        changed
    }

    /// Restore op_log from DB-persisted ops (called at startup when op_log
    /// is no longer serialized in the state JSON).
    pub fn restore_op_log(&mut self, ops: Vec<CrdtOp>) {
        self.op_log = ops;
        self.op_log_dedup.clear();
        for op in &self.op_log {
            self.op_log_dedup.insert((op.author.clone(), op.hlc.clone()));
        }
    }

    /// Generate a new CrdtOp with our HLC, but do NOT apply it yet.
    /// Caller should apply via `apply_op()` after broadcasting.
    pub fn create_op(&mut self, payload: CrdtPayload) -> CrdtOp {
        let hlc = self
            .hlc
            .as_mut()
            .expect("HLC must be set before creating ops");
        let ts = hlc.now();
        CrdtOp {
            server_id: self.server_id.clone(),
            hlc: ts,
            author: hlc.actor().to_string(),
            payload,
        }
    }

    /// Apply a CRDT operation. Idempotent — safe to apply duplicates.
    pub fn apply_op(&mut self, op: &CrdtOp) -> Result<(), String> {
        if op.server_id != self.server_id {
            return Err(format!(
                "Op server_id {} doesn't match {}",
                op.server_id, self.server_id
            ));
        }

        // Lazy-init dedup set from op_log (after deserialization, skip field is empty).
        if self.op_log_dedup.is_empty() && !self.op_log.is_empty() {
            for existing in &self.op_log {
                self.op_log_dedup.insert((existing.author.clone(), existing.hlc.clone()));
            }
        }

        // O(1) duplicate check (same author + same HLC = same op)
        let dedup_key = (op.author.clone(), op.hlc.clone());
        if self.op_log_dedup.contains(&dedup_key) {
            return Ok(());
        }

        // Witness the remote timestamp to keep our HLC in sync
        if let Some(hlc) = &mut self.hlc {
            hlc.witness(&op.hlc);
        }

        match &op.payload {
            CrdtPayload::ServerCreated { name, owner_peer_id } => {
                self.name = AdminLwwReg::new(
                    name.clone(),
                    op.hlc.clone(),
                    MemberRole::Owner.priority(),
                );
                self.members.insert(
                    owner_peer_id.clone(),
                    MemberInfo {
                        peer_id: owner_peer_id.clone(),
                        display_name: short_name(owner_peer_id),
                    },
                );
                self.roles.insert(
                    owner_peer_id.clone(),
                    AdminLwwReg::new(
                        MemberRole::Owner,
                        op.hlc.clone(),
                        MemberRole::Owner.priority(),
                    ),
                );
            }

            CrdtPayload::ServerRenamed { new_name } => {
                let priority = self.author_priority(&op.author);
                let remote = AdminLwwReg::new(new_name.clone(), op.hlc.clone(), priority);
                self.name.merge(&remote);
            }

            CrdtPayload::ServerSettingChanged { key, value } => {
                let priority = self.author_priority(&op.author);
                let entry = self
                    .settings
                    .entry(key.clone())
                    .or_insert_with(|| {
                        AdminLwwReg::new(value.clone(), op.hlc.clone(), priority)
                    });
                let remote = AdminLwwReg::new(value.clone(), op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::ServerDeleted { .. } => {
                // Tombstone: latch `deleted` and drain membership/roles/etc. so the
                // server can no longer be acted upon, but KEEP `server_id` + `op_log`
                // (handled by the apply_op tail) so this node keeps serving the
                // deletion op to reconnecting peers. Idempotent via op_log_dedup.
                // Owner-authorship is validated at the INGEST sites (CrdtOpBroadcast
                // + sync-merge), not here — the CRDT layer has no transport context.
                self.deleted = true;
                self.members.clear();
                self.roles.clear();
                self.channels.clear();
                self.nicknames.clear();
                self.twitch_usernames.clear();
                self.storage_pledges.clear();
                self.label_assignments.clear();
            }

            CrdtPayload::ChannelAdded {
                channel_id,
                name,
                category,
                channel_type,
            } => {
                let ct = match channel_type.as_str() {
                    "voice" => ChannelType::Voice,
                    _ => ChannelType::Text,
                };
                self.channels.entry(channel_id.clone()).or_insert_with(|| {
                    ChannelInfo {
                        channel_id: channel_id.clone(),
                        name: name.clone(),
                        category: category.clone(),
                        channel_type: ct,
                        visibility: ChannelVisibility::Everyone,
                        posting: ChannelPosting::Everyone,
                        is_public: false,
                        slow_mode: 0,
                        media_only: false,
                        visibility_labels: Vec::new(),
                        posting_labels: Vec::new(),
                    }
                });
            }

            CrdtPayload::ChannelRemoved { channel_id } => {
                self.channels.remove(channel_id);
            }

            CrdtPayload::ChannelRenamed {
                channel_id,
                new_name,
            } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.name = new_name.clone();
                }
            }

            CrdtPayload::MemberAdded {
                peer_id,
                display_name,
            } => {
                self.members.entry(peer_id.clone()).or_insert_with(|| {
                    MemberInfo {
                        peer_id: peer_id.clone(),
                        display_name: display_name.clone(),
                    }
                });
                self.roles.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(
                        MemberRole::Member,
                        op.hlc.clone(),
                        MemberRole::Member.priority(),
                    )
                });
            }

            CrdtPayload::MemberRemoved { peer_id } => {
                self.members.remove(peer_id);
                self.roles.remove(peer_id);
                self.nicknames.remove(peer_id);
                self.twitch_usernames.remove(peer_id);
                self.storage_pledges.remove(peer_id);
            }

            CrdtPayload::ChannelVisibilityChanged { channel_id, visibility } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.visibility = match visibility.as_str() {
                        "moderator" => ChannelVisibility::ModeratorPlus,
                        "admin" => ChannelVisibility::AdminPlus,
                        _ => ChannelVisibility::Everyone,
                    };
                }
            }

            CrdtPayload::ChannelPostingChanged { channel_id, posting } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.posting = match posting.as_str() {
                        "moderator" => ChannelPosting::ModeratorPlus,
                        "admin" => ChannelPosting::AdminPlus,
                        _ => ChannelPosting::Everyone,
                    };
                }
            }

            CrdtPayload::ChannelPublicChanged { channel_id, is_public } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.is_public = *is_public;
                }
            }

            CrdtPayload::ChannelSlowModeChanged { channel_id, seconds } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.slow_mode = *seconds;
                }
            }

            CrdtPayload::ChannelMediaOnlyChanged { channel_id, media_only } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.media_only = *media_only;
                }
            }

            CrdtPayload::ChannelVisibilityLabelsChanged { channel_id, labels } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.visibility_labels = labels.clone();
                }
            }

            CrdtPayload::ChannelPostingLabelsChanged { channel_id, labels } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.posting_labels = labels.clone();
                }
            }

            CrdtPayload::ChannelGrantSet { channel_id, peer_id, expires_at } => {
                let priority = self.author_priority(&op.author);
                let per_chan = self.channel_grants.entry(channel_id.clone()).or_default();
                let entry = per_chan.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*expires_at, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*expires_at, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::ChannelGrantRevoked { channel_id, peer_id } => {
                let priority = self.author_priority(&op.author);
                let per_chan = self.channel_grants.entry(channel_id.clone()).or_default();
                let entry = per_chan.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(0u64, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(0u64, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Prune (mirrors MemberUnmuted): only this arm can flip a
                // register to 0, so the sweep lives only here. A newer grant
                // wins the merge above and survives the retain.
                per_chan.retain(|_, reg| *reg.read() != 0);
                if per_chan.is_empty() {
                    self.channel_grants.remove(channel_id);
                }
            }

            CrdtPayload::RoleChanged {
                peer_id,
                role,
                priority,
            } => {
                // The payload's `priority` (the author's role priority) is
                // inert wire-compat metadata: merge is pure HLC LWW, so a
                // demotion lands because the demotion op is HLC-later, and
                // authority is enforced by can_change_role at author + ingest.
                // Old clients still merge priority-first, so keep sending it.
                let entry = self.roles.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(role.clone(), op.hlc.clone(), *priority)
                });
                let remote = AdminLwwReg::new(role.clone(), op.hlc.clone(), *priority);
                entry.merge(&remote);
            }

            CrdtPayload::NicknameChanged { peer_id, nickname } => {
                // Any member can set their own nickname. Use author's priority
                // so admins can also change others' nicknames.
                let priority = self.author_priority(&op.author);
                let entry = self.nicknames.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(nickname.clone(), op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(nickname.clone(), op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::TwitchUsernameChanged { peer_id, twitch_username } => {
                let priority = self.author_priority(&op.author);
                let entry = self.twitch_usernames.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(twitch_username.clone(), op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(twitch_username.clone(), op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::ChannelLayoutUpdated { layout_json } => {
                if let Ok(layout) = serde_json::from_str::<Vec<ChannelLayoutItem>>(layout_json) {
                    self.channel_layout = layout;
                }
            }

            CrdtPayload::MessagePinned { channel_id, message_id } => {
                let pins = self.pinned_messages.entry(channel_id.clone()).or_default();
                if !pins.contains(message_id) {
                    pins.push(message_id.clone());
                }
            }

            CrdtPayload::MessageUnpinned { channel_id, message_id } => {
                if let Some(pins) = self.pinned_messages.get_mut(channel_id) {
                    pins.retain(|id| id != message_id);
                    if pins.is_empty() {
                        self.pinned_messages.remove(channel_id);
                    }
                }
            }

            CrdtPayload::StoragePledgeChanged { peer_id, pledge_bytes } => {
                let priority = self.author_priority(&op.author);
                let entry = self.storage_pledges.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*pledge_bytes, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*pledge_bytes, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::RolePermissionsChanged { role, permissions } => {
                let priority = self.author_priority(&op.author);
                let entry = self.role_permissions.entry(role.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*permissions, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*permissions, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::MemberBanned { peer_id } => {
                let priority = self.author_priority(&op.author);
                let entry = self.banned_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(true, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(true, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Also remove from server (ban = kick + prevent rejoin)
                self.members.remove(peer_id);
                self.roles.remove(peer_id);
                self.nicknames.remove(peer_id);
                self.twitch_usernames.remove(peer_id);
                self.storage_pledges.remove(peer_id);
            }

            CrdtPayload::MemberUnbanned { peer_id } => {
                let priority = self.author_priority(&op.author);
                let entry = self.banned_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(false, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(false, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Prune unbanned members to prevent unbounded growth. Only this
                // arm can flip a register to false, so the sweep lives here
                // instead of running on every op. LWW-aware: a newer ban wins
                // the merge above and survives the retain.
                self.banned_members.retain(|_, reg| *reg.read());
            }

            CrdtPayload::MemberMuted { peer_id, expires_at } => {
                let priority = self.author_priority(&op.author);
                let entry = self.muted_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*expires_at, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*expires_at, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::MemberUnmuted { peer_id } => {
                let priority = self.author_priority(&op.author);
                let entry = self.muted_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(0u64, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(0u64, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Prune unmuted entries to prevent unbounded growth. Mirrors the
                // MemberUnbanned sweep: only this arm can flip a register to 0,
                // and a newer mute wins the merge above and survives the retain.
                self.muted_members.retain(|_, reg| *reg.read() != 0);
            }

            CrdtPayload::LabelCreated { label_id, name, color, access } => {
                self.labels.entry(label_id.clone()).or_insert_with(|| {
                    LabelInfo {
                        label_id: label_id.clone(),
                        name: name.clone(),
                        color: color.clone(),
                        access: *access,
                    }
                });
            }

            CrdtPayload::LabelDeleted { label_id } => {
                self.labels.remove(label_id);
                for assignments in self.label_assignments.values_mut() {
                    assignments.retain(|id| id != label_id);
                }
            }

            CrdtPayload::LabelUpdated { label_id, name, color, access } => {
                if let Some(label) = self.labels.get_mut(label_id) {
                    label.name = name.clone();
                    label.color = color.clone();
                    // None = the author predates the flag — PRESERVE it. An
                    // old client recoloring an access label must not silently
                    // demote it to cosmetic (that re-opens self-assignment).
                    if let Some(a) = access {
                        label.access = *a;
                    }
                }
            }

            CrdtPayload::LabelAssigned { label_id, peer_id } => {
                let assignments = self.label_assignments.entry(peer_id.clone()).or_default();
                if !assignments.contains(label_id) {
                    assignments.push(label_id.clone());
                }
            }

            CrdtPayload::LabelUnassigned { label_id, peer_id } => {
                if let Some(assignments) = self.label_assignments.get_mut(peer_id) {
                    assignments.retain(|id| id != label_id);
                    if assignments.is_empty() {
                        self.label_assignments.remove(peer_id);
                    }
                }
            }

            CrdtPayload::EmojiAdded { name, hash, animated } => {
                // Replace-on-same-name (re-adding a name swaps the image);
                // refuse NEW names past the cap so replicas converge on the
                // same refusal regardless of op arrival order relative to
                // other adds already in the log.
                let is_new = !self.emotes.contains_key(name);
                if !is_new || self.emotes.len() < MAX_SERVER_EMOTES {
                    self.emotes.insert(
                        name.clone(),
                        EmoteInfo {
                            name: name.clone(),
                            hash: hash.clone(),
                            animated: *animated,
                        },
                    );
                }
            }

            CrdtPayload::EmojiRemoved { name } => {
                self.emotes.remove(name);
            }

            CrdtPayload::StickerAdded { hash, name, pack, animated, w, h } => {
                // Same convergence rule as emotes: replacing an existing
                // entry always applies, a NEW one only under the cap, so
                // replicas refuse identically regardless of arrival order.
                let is_new = !self.stickers.contains_key(hash);
                if !is_new || self.stickers.len() < MAX_SERVER_STICKERS {
                    self.stickers.insert(
                        hash.clone(),
                        StickerInfo {
                            hash: hash.clone(),
                            name: name.clone(),
                            pack: pack.clone(),
                            animated: *animated,
                            w: *w,
                            h: *h,
                        },
                    );
                }
            }

            CrdtPayload::StickerRemoved { hash } => {
                self.stickers.remove(hash);
            }
        }

        // Append to op log (sorted insert by HLC for deterministic ordering)
        let insert_pos = self
            .op_log
            .binary_search_by(|existing| existing.hlc.cmp(&op.hlc))
            .unwrap_or_else(|pos| pos);
        self.op_log.insert(insert_pos, op.clone());
        self.op_log_dedup.insert(dedup_key);

        // SECURITY: Compact op log to prevent unbounded growth.
        // Keep last 1000 ops — older ops are already applied to state.
        const MAX_OP_LOG: usize = 1000;
        if self.op_log.len() > MAX_OP_LOG {
            let drain_count = self.op_log.len() - MAX_OP_LOG;
            self.op_log.drain(..drain_count);
            // Rebuild dedup set after compaction.
            self.op_log_dedup.clear();
            for existing in &self.op_log {
                self.op_log_dedup.insert((existing.author.clone(), existing.hlc.clone()));
            }
        }

        Ok(())
    }

    /// List all channels, sorted by name.
    pub fn channels_list(&self) -> Vec<&ChannelInfo> {
        let mut list: Vec<_> = self.channels.values().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    /// List all members, sorted by display name.
    pub fn members_list(&self) -> Vec<&MemberInfo> {
        let mut list: Vec<_> = self.members.values().collect();
        list.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        list
    }

    /// Get a member's role.
    pub fn get_role(&self, peer_id: &str) -> MemberRole {
        // Multi-device: collapse a device id to its master before the keyed lookup
        // (roles are master-keyed). Identity-passthrough for unknowns / single-device.
        let key = super::resolve_identity(peer_id);
        self.roles
            .get(&key)
            .map(|reg| reg.read().clone())
            .unwrap_or(MemberRole::Member)
    }

    /// Get the server name.
    pub fn name(&self) -> &str {
        self.name.read()
    }

    /// Get a member's server nickname (empty string = no nickname set).
    pub fn get_nickname(&self, peer_id: &str) -> String {
        self.nicknames
            .get(peer_id)
            .map(|reg| reg.read().clone())
            .unwrap_or_default()
    }

    pub fn get_twitch_username(&self, peer_id: &str) -> String {
        self.twitch_usernames
            .get(peer_id)
            .map(|reg| reg.read().clone())
            .unwrap_or_default()
    }

    /// Get pinned message IDs for a channel.
    pub fn get_pinned_messages(&self, channel_id: &str) -> Vec<String> {
        self.pinned_messages
            .get(channel_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Get a member's storage pledge in bytes. Returns 0 if not set.
    pub fn get_storage_pledge(&self, peer_id: &str) -> u64 {
        self.storage_pledges
            .get(peer_id)
            .map(|reg| *reg.read())
            .unwrap_or(0)
    }

    /// Get the total storage pledged by all members (bytes).
    pub fn total_pledged_bytes(&self) -> u64 {
        self.storage_pledges.values().map(|reg| *reg.read()).sum()
    }

    /// Get the minimum pledge setting (MB). Returns 512 if not configured.
    pub fn min_pledge_mb(&self) -> u64 {
        self.settings
            .get("min_pledge_mb")
            .and_then(|reg| reg.read().parse::<u64>().ok())
            .unwrap_or(512)
    }

    /// Relay offline catch-up retention in seconds. DEFAULT ON at 3 days when
    /// the setting is absent (2026-07-04: users won't find the toggle and will
    /// assume offline delivery is broken); an explicit "0" = owner turned it
    /// OFF. Stored in `settings["relay_catchup_secs"]` (Owner/Admin-gated like
    /// every server setting). When >0, member clients register the server's
    /// text channels with the relay's per-channel ring buffer and request
    /// catch-up on connect + channel open — the relay stays an availability
    /// helper (same E2EE signed bytes, receiver verifies + dedups), never a
    /// source of truth.
    pub fn relay_catchup_secs(&self) -> i64 {
        self.settings
            .get("relay_catchup_secs")
            .and_then(|reg| reg.read().parse::<i64>().ok())
            .unwrap_or(3 * 86400)
            .max(0)
    }

    /// Whether the server is private (invite-only). Defaults to public.
    /// Stored in `settings["is_private"]` as "true"/"false".
    pub fn is_private(&self) -> bool {
        self.settings
            .get("is_private")
            .map(|reg| reg.read() == "true")
            .unwrap_or(false)
    }

    /// Whether the server is flagged NSFW (adult/sensitive content). Defaults to
    /// false. Stored in `settings["is_nsfw"]` as "true"/"false". Used to gate
    /// joining with a "proceed at your own risk" consent prompt.
    pub fn is_nsfw(&self) -> bool {
        self.settings
            .get("is_nsfw")
            .map(|reg| reg.read() == "true")
            .unwrap_or(false)
    }

    /// Owner-configured max member count. `None` = unlimited (default).
    /// Stored in `settings["max_members"]`; 0 or unparseable = unlimited.
    pub fn max_members(&self) -> Option<u32> {
        self.settings
            .get("max_members")
            .and_then(|reg| reg.read().parse::<u32>().ok())
            .filter(|&n| n > 0)
    }

    /// Look up author's priority from their role in this server. Resolves a
    /// DEVICE-id author to its master first (roles are master-keyed) so LWW
    /// priority works for replayed legacy device-authored ops. Unknown authors
    /// stay at 0 (deliberately BELOW plain members — do not route via `get_role`,
    /// which defaults unknowns to `Member`).
    fn author_priority(&self, author: &str) -> u8 {
        let key = super::resolve_identity(author);
        self.roles
            .get(&key)
            .map(|reg| reg.read().priority())
            .unwrap_or(0)
    }

    /// Get the effective permissions bitmask for a peer.
    /// Owner gets ALL permissions regardless.
    /// Checks custom role_permissions first, falls back to defaults.
    pub fn get_permissions(&self, peer_id: &str) -> u32 {
        let role = self.get_role(peer_id);
        if role == MemberRole::Owner {
            return Permission::ALL;
        }
        if let Some(reg) = self.role_permissions.get(role.as_str()) {
            return *reg.read();
        }
        role.default_permissions()
    }

    /// Get the permissions bitmask for a role (custom or default).
    pub fn get_role_permissions(&self, role: &str) -> u32 {
        if role == "owner" {
            return Permission::ALL;
        }
        if let Some(reg) = self.role_permissions.get(role) {
            return *reg.read();
        }
        MemberRole::from_str(role).default_permissions()
    }

    /// Check if a peer has a specific permission.
    pub fn has_permission(&self, peer_id: &str, permission: u32) -> bool {
        self.get_permissions(peer_id) & permission != 0
    }

    /// Check if `actor` can change `target`'s role to `new_role`.
    /// Rules: Owner can do anything. Others can only change roles below
    /// their own rank, and can only assign roles below their own rank.
    pub fn can_change_role(&self, actor: &str, target: &str, new_role: &MemberRole) -> bool {
        let actor_role = self.get_role(actor);
        if actor_role == MemberRole::Owner {
            return true;
        }
        if !self.has_permission(actor, Permission::MANAGE_ROLES) {
            return false;
        }
        let target_role = self.get_role(target);
        // Can't change someone of equal or higher rank
        if !actor_role.outranks(&target_role) {
            return false;
        }
        // Can't assign a role equal to or higher than your own
        if !actor_role.outranks(new_role) {
            return false;
        }
        // Can't set someone to Owner via role change
        if *new_role == MemberRole::Owner {
            return false;
        }
        true
    }

    /// Check if `actor` can kick `target`.
    pub fn can_kick(&self, actor: &str, target: &str) -> bool {
        let actor_role = self.get_role(actor);
        if actor_role == MemberRole::Owner {
            return true;
        }
        if !self.has_permission(actor, Permission::KICK_MEMBERS) {
            return false;
        }
        let target_role = self.get_role(target);
        actor_role.outranks(&target_role)
    }

    /// Check if a peer is currently banned.
    pub fn is_banned(&self, peer_id: &str) -> bool {
        // Multi-device: bans are master-keyed; collapse a device id first.
        let key = super::resolve_identity(peer_id);
        self.banned_members
            .get(&key)
            .map(|reg| *reg.read())
            .unwrap_or(false)
    }

    /// Whether this server has been tombstoned (a `ServerDeleted` op applied). The
    /// UI must hide tombstoned servers; the node still retains the shell to serve
    /// the deletion op to reconnecting peers.
    pub fn is_deleted(&self) -> bool {
        self.deleted
    }

    /// Multi-device-safe membership check: is `peer_id` (device OR master) a member?
    /// Collapses to master before the keyed lookup. Use this instead of
    /// `members.contains_key(...)` anywhere the arg may be a device id.
    pub fn is_member(&self, peer_id: &str) -> bool {
        let key = super::resolve_identity(peer_id);
        self.members.contains_key(&key)
    }

    /// Check if `actor` can ban `target`. Same hierarchy as kick.
    pub fn can_ban(&self, actor: &str, target: &str) -> bool {
        self.can_kick(actor, target)
    }

    /// The ingest permission matrix: may `op.author` apply this op to this
    /// server? Shared by BOTH remote-op ingest paths (plaintext
    /// `CrdtOpBroadcast` in swarm.rs and the MLS `CrdtOp` envelope in
    /// sync_handler.rs) so the matrices can never drift apart again.
    ///
    /// Validates the AUTHOR (the op's original creator), never the transport
    /// sender — ops are legitimately relayed by other peers during join/sync
    /// fan-out. Override-aware (`get_permissions`, honoring
    /// `RolePermissionsChanged`), NOT `default_permissions()`: local send
    /// handlers gate on `has_permission`, so ingest must apply the SAME matrix
    /// — otherwise an override-granted permission authors ops the whole
    /// network rejects (the actor's devices fork), and an override-REVOKED
    /// permission still passes ingest (unenforced remotely).
    pub fn op_allowed(&self, op: &CrdtOp) -> bool {
        let sender_role = self.get_role(&op.author);
        let sender_perms = self.get_permissions(&op.author);
        match &op.payload {
            CrdtPayload::ChannelAdded { .. }
            | CrdtPayload::ChannelRemoved { .. }
            | CrdtPayload::ChannelRenamed { .. }
            | CrdtPayload::ChannelLayoutUpdated { .. } => {
                (sender_perms & Permission::MANAGE_CHANNELS) != 0
            }
            CrdtPayload::RoleChanged { peer_id, role, .. } => {
                self.can_change_role(&op.author, peer_id, role)
            }
            // Permission-based (override-aware), NOT role-based — the local
            // send handlers gate on MANAGE_SERVER, so ingest must match or an
            // override-granted author forks from the network (see doc above).
            // Admin holds MANAGE_SERVER by default.
            CrdtPayload::ServerRenamed { .. }
            | CrdtPayload::ServerSettingChanged { .. } => {
                (sender_perms & Permission::MANAGE_SERVER) != 0
            }
            // Self-removal (voluntary leave) is always allowed; kicking
            // someone ELSE needs moderator+ and outranking.
            CrdtPayload::MemberRemoved { peer_id } => {
                let target_role = self.get_role(peer_id);
                peer_id == &op.author
                    || ((sender_perms & Permission::KICK_MEMBERS) != 0
                        && sender_role.outranks(&target_role))
            }
            CrdtPayload::MemberAdded { .. } => {
                // is_member (resolver-aware), not raw contains_key: a legacy op
                // authored under a DEVICE id must still validate.
                self.is_member(&op.author)
            }
            CrdtPayload::NicknameChanged { peer_id, .. }
            | CrdtPayload::TwitchUsernameChanged { peer_id, .. }
            | CrdtPayload::StoragePledgeChanged { peer_id, .. } => {
                peer_id == &op.author || sender_role == MemberRole::Owner || sender_role == MemberRole::Admin
            }
            CrdtPayload::MessagePinned { .. }
            | CrdtPayload::MessageUnpinned { .. } => {
                (sender_perms & Permission::MANAGE_CHANNELS) != 0
            }
            CrdtPayload::RolePermissionsChanged { role, .. } => {
                let target = MemberRole::from_str(role);
                (sender_perms & Permission::MANAGE_ROLES) != 0
                    && sender_role.outranks(&target)
            }
            CrdtPayload::MemberBanned { peer_id } => {
                let target_role = self.get_role(peer_id);
                (sender_perms & Permission::KICK_MEMBERS) != 0
                    && sender_role.outranks(&target_role)
            }
            CrdtPayload::MemberUnbanned { .. } => {
                (sender_perms & Permission::KICK_MEMBERS) != 0
            }
            CrdtPayload::MemberMuted { peer_id, .. } => {
                let target_role = self.get_role(peer_id);
                (sender_perms & Permission::KICK_MEMBERS) != 0
                    && sender_role.outranks(&target_role)
            }
            CrdtPayload::MemberUnmuted { .. } => {
                (sender_perms & Permission::KICK_MEMBERS) != 0
            }
            CrdtPayload::ChannelVisibilityChanged { .. }
            | CrdtPayload::ChannelPostingChanged { .. }
            | CrdtPayload::ChannelPublicChanged { .. }
            | CrdtPayload::ChannelSlowModeChanged { .. }
            | CrdtPayload::ChannelMediaOnlyChanged { .. }
            | CrdtPayload::ChannelVisibilityLabelsChanged { .. }
            | CrdtPayload::ChannelPostingLabelsChanged { .. }
            | CrdtPayload::ChannelGrantSet { .. }
            | CrdtPayload::ChannelGrantRevoked { .. } => {
                (sender_perms & Permission::MANAGE_CHANNELS) != 0
            }
            CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelDeleted { .. }
            | CrdtPayload::LabelUpdated { .. } => {
                (sender_perms & Permission::MANAGE_ROLES) != 0
            }
            CrdtPayload::LabelAssigned { label_id, peer_id }
            | CrdtPayload::LabelUnassigned { label_id, peer_id } => {
                // Self-toggle only for existing COSMETIC labels; access
                // labels and unknown label ids require MANAGE_ROLES. Same
                // rule as the authoring gate via can_self_toggle_label —
                // ingest weaker than send is a fork generator.
                self.can_self_toggle_label(&op.author, peer_id, label_id)
                    || (sender_perms & Permission::MANAGE_ROLES) != 0
            }
            CrdtPayload::EmojiAdded { name, hash, .. } => {
                (sender_perms & Permission::MANAGE_EMOTES) != 0
                    && super::valid_emote_name(name)
                    && super::valid_emote_hash(hash)
            }
            CrdtPayload::EmojiRemoved { .. } => {
                (sender_perms & Permission::MANAGE_EMOTES) != 0
            }
            // Stickers reuse MANAGE_EMOTES rather than adding a permission
            // bit — same authoring surface, same audience.
            CrdtPayload::StickerAdded { hash, name, pack, w, h, .. } => {
                (sender_perms & Permission::MANAGE_EMOTES) != 0
                    && super::valid_emote_hash(hash)
                    && valid_sticker_label(name)
                    && valid_sticker_label(pack)
                    // Dimensions ride the `[a:s:hash:w:h]` token, whose
                    // grammar tops out at 4 digits — a row we could not
                    // render a token for has no business replicating.
                    && (1..=4096).contains(w)
                    && (1..=4096).contains(h)
            }
            CrdtPayload::StickerRemoved { .. } => {
                (sender_perms & Permission::MANAGE_EMOTES) != 0
            }
            // Only the Owner can delete a server (tombstone).
            CrdtPayload::ServerDeleted { .. } => sender_role == MemberRole::Owner,
            CrdtPayload::ServerCreated { .. } => true,
        }
    }

    /// Check if a peer is muted at `now_ms` (epoch ms). Expired mutes read as
    /// unmuted; `u64::MAX` = permanent.
    pub fn is_muted(&self, peer_id: &str, now_ms: u64) -> bool {
        // Multi-device: mutes are master-keyed; collapse a device id first.
        let key = super::resolve_identity(peer_id);
        self.muted_members
            .get(&key)
            .map(|reg| *reg.read() > now_ms)
            .unwrap_or(false)
    }

    /// Check if `actor` can mute `target`. Same hierarchy as kick/ban.
    pub fn can_mute(&self, actor: &str, target: &str) -> bool {
        self.can_kick(actor, target)
    }

    /// List active mutes at `now_ms` as (master peer_id, expiry ms) pairs.
    /// Expired entries are skipped (they linger in the map until unmute).
    pub fn muted_list(&self, now_ms: u64) -> Vec<(String, u64)> {
        self.muted_members
            .iter()
            .filter(|(_, reg)| *reg.read() > now_ms)
            .map(|(pid, reg)| (pid.clone(), *reg.read()))
            .collect()
    }

    /// List all currently banned peer IDs.
    pub fn banned_list(&self) -> Vec<String> {
        self.banned_members
            .iter()
            .filter(|(_, reg)| *reg.read())
            .map(|(pid, _)| pid.clone())
            .collect()
    }

    /// Get all label definitions, sorted by name for stable ordering.
    pub fn labels_list(&self) -> Vec<&LabelInfo> {
        let mut list: Vec<_> = self.labels.values().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    /// Get all custom emotes, sorted by name for stable ordering.
    pub fn emotes_list(&self) -> Vec<&EmoteInfo> {
        let mut list: Vec<_> = self.emotes.values().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    /// Get all stickers, pack-major then by name, then by hash so the order
    /// is total and identical on every replica (two stickers can share a
    /// name, so name alone would not be a stable sort key).
    pub fn stickers_list(&self) -> Vec<&StickerInfo> {
        let mut list: Vec<_> = self.stickers.values().collect();
        list.sort_by(|a, b| {
            a.pack
                .cmp(&b.pack)
                .then_with(|| a.name.cmp(&b.name))
                .then_with(|| a.hash.cmp(&b.hash))
        });
        list
    }

    /// Get the labels assigned to a member.
    pub fn get_member_labels(&self, peer_id: &str) -> Vec<&LabelInfo> {
        self.label_assignments
            .get(peer_id)
            .map(|ids| {
                ids.iter()
                    .filter_map(|id| self.labels.get(id))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Unexpired temporary grant for (channel, member)? Grants are
    /// master-keyed; collapse a device id first (like `is_muted`).
    pub fn has_channel_grant(&self, peer_id: &str, channel_id: &str, now_ms: u64) -> bool {
        let key = super::resolve_identity(peer_id);
        self.channel_grants
            .get(channel_id)
            .and_then(|m| m.get(&key))
            .map(|reg| *reg.read() > now_ms)
            .unwrap_or(false)
    }

    /// Active grants for a channel at `now_ms` as (master peer_id, expiry ms)
    /// pairs. Expired entries are skipped (they linger until revoke,
    /// mirroring `muted_list`).
    pub fn channel_grants_list(&self, channel_id: &str, now_ms: u64) -> Vec<(String, u64)> {
        self.channel_grants
            .get(channel_id)
            .map(|m| {
                m.iter()
                    .filter(|(_, reg)| *reg.read() > now_ms)
                    .map(|(pid, reg)| (pid.clone(), *reg.read()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Does the member (already master-collapsed) hold ANY of the listed
    /// label ids? Raw `label_assignments` lookup — callers must resolve
    /// device→master first (`get_member_labels` does not, so don't reuse it
    /// in predicates). `LabelDeleted` strips assignments, so a deleted label
    /// can never satisfy a gate (fail-closed).
    fn holds_any_label(&self, master: &str, wanted: &[String]) -> bool {
        self.label_assignments
            .get(master)
            .is_some_and(|held| wanted.iter().any(|w| held.contains(w)))
    }

    /// Shared self-toggle rule for LabelAssigned/Unassigned — used by BOTH
    /// the authoring gate (handle_label_op) and `op_allowed`, so the two can
    /// never drift. Self-toggle is allowed only for an EXISTING label that is
    /// NOT access-bearing; unknown label ids are refused (fail-closed — an
    /// assignment racing ahead of its LabelCreated cannot be classified, and
    /// letting it through would let anyone pre-claim a future access label).
    pub fn can_self_toggle_label(&self, actor: &str, target_peer: &str, label_id: &str) -> bool {
        super::resolve_identity(actor) == super::resolve_identity(target_peer)
            && self.labels.get(label_id).is_some_and(|l| !l.access)
    }

    /// Check if a peer can see a channel (at the current wall clock).
    pub fn can_see_channel(&self, peer_id: &str, channel_id: &str) -> bool {
        self.can_see_channel_at(peer_id, channel_id, epoch_ms_now())
    }

    /// Visibility predicate at an explicit `now_ms` (tests control time).
    /// Owner always sees. An unexpired grant sees. A non-empty label gate
    /// REPLACES the tier ladder: Admin+ implicit, else any listed label.
    pub fn can_see_channel_at(&self, peer_id: &str, channel_id: &str, now_ms: u64) -> bool {
        let master = super::resolve_identity(peer_id);
        let role = self.get_role(&master);
        if role == MemberRole::Owner { return true; }
        let Some(ch) = self.channels.get(channel_id) else { return false; };
        if self.has_channel_grant(&master, channel_id, now_ms) { return true; }
        if !ch.visibility_labels.is_empty() {
            return role.priority() >= MemberRole::Admin.priority()
                || self.holds_any_label(&master, &ch.visibility_labels);
        }
        match ch.visibility {
            ChannelVisibility::Everyone => true,
            ChannelVisibility::ModeratorPlus => role.priority() >= MemberRole::Moderator.priority(),
            ChannelVisibility::AdminPlus => role.priority() >= MemberRole::Admin.priority(),
        }
    }

    pub fn is_channel_public(&self, channel_id: &str) -> bool {
        self.channels.get(channel_id).map_or(false, |ch| ch.is_public)
    }

    /// Check if a peer can post in a channel (at the current wall clock).
    pub fn can_post_in_channel(&self, peer_id: &str, channel_id: &str) -> bool {
        self.can_post_in_channel_at(peer_id, channel_id, epoch_ms_now())
    }

    /// Posting predicate at an explicit `now_ms`. Same shape as visibility;
    /// the Everyone tier keeps the SEND_MESSAGES permission check, and a
    /// grant confers posting too (mute stays a SEPARATE check at the send
    /// and ingest sites — never folded in here).
    pub fn can_post_in_channel_at(&self, peer_id: &str, channel_id: &str, now_ms: u64) -> bool {
        let master = super::resolve_identity(peer_id);
        let role = self.get_role(&master);
        if role == MemberRole::Owner { return true; }
        let Some(ch) = self.channels.get(channel_id) else { return false; };
        if self.has_channel_grant(&master, channel_id, now_ms) { return true; }
        if !ch.posting_labels.is_empty() {
            return role.priority() >= MemberRole::Admin.priority()
                || self.holds_any_label(&master, &ch.posting_labels);
        }
        match ch.posting {
            ChannelPosting::Everyone => self.has_permission(&master, Permission::SEND_MESSAGES),
            ChannelPosting::ModeratorPlus => role.priority() >= MemberRole::Moderator.priority(),
            ChannelPosting::AdminPlus => role.priority() >= MemberRole::Admin.priority(),
        }
    }

    /// Slow-mode interval for a channel in seconds (0 = off).
    pub fn channel_slow_mode(&self, channel_id: &str) -> u32 {
        self.channels.get(channel_id).map_or(0, |ch| ch.slow_mode)
    }

    /// Whether a channel only accepts image/video/GIF attachments.
    pub fn is_channel_media_only(&self, channel_id: &str) -> bool {
        self.channels.get(channel_id).map_or(false, |ch| ch.media_only)
    }

    /// Moderator+ (and Owner) bypass slow mode, matching the Discord behavior.
    pub fn bypasses_slow_mode(&self, peer_id: &str) -> bool {
        self.get_role(peer_id).priority() >= MemberRole::Moderator.priority()
    }

    /// Whether a channel is cryptographically isolated in its own MLS subgroup
    /// (per-channel MLS subgroups / "Option B"). True iff the channel has a
    /// restricted visibility tier AND is not a plaintext public channel. Such a
    /// channel is encrypted under `subgroup_id(server_id, channel_id)` instead of
    /// the server-wide MLS group, so only members whose role satisfies the tier
    /// hold the key. `Everyone` channels and public channels do NOT use a subgroup.
    pub fn channel_uses_subgroup(&self, channel_id: &str) -> bool {
        self.channels.get(channel_id).is_some_and(|ch| {
            !ch.is_public
                && (ch.visibility != ChannelVisibility::Everyone
                    || !ch.visibility_labels.is_empty())
        })
    }

    /// All channel ids that currently use a dedicated MLS subgroup (restricted +
    /// non-public). Used to enumerate subgroup ids for MLS persistence reload and
    /// to reconcile membership on role/visibility changes.
    pub fn subgroup_channel_ids(&self) -> Vec<String> {
        self.channels
            .values()
            .filter(|ch| {
                !ch.is_public
                    && (ch.visibility != ChannelVisibility::Everyone
                        || !ch.visibility_labels.is_empty())
            })
            .map(|ch| ch.channel_id.clone())
            .collect()
    }
}

/// Current wall clock in epoch ms (the time base for mute + grant expiry).
fn epoch_ms_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Truncate a peer ID to a short display name.
fn short_name(peer_id: &str) -> String {
    if peer_id.len() > 12 {
        format!("{}...", &peer_id[..12])
    } else {
        peer_id.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build an op authored by `author` (create_op stamps the local actor;
    /// ingest validation only reads `op.author`, so overriding it simulates a
    /// remote peer's op).
    fn op_by(state: &mut ServerState, author: &str, payload: CrdtPayload) -> CrdtOp {
        let mut op = state.create_op(payload);
        op.author = author.to_string();
        op
    }

    /// The shared ingest permission matrix (`op_allowed`) — one allowed and
    /// one denied probe per payload arm, driven as a pure function. This is
    /// the regression guard for BOTH remote-op ingest paths (plaintext
    /// CrdtOpBroadcast in swarm.rs and the MLS CrdtOp envelope in
    /// sync_handler.rs), which call this exact method.
    #[test]
    fn op_allowed_ingest_matrix() {
        let mut s = ServerState::new("s1".into(), "S".into(), "owner".into());
        for id in ["admin", "moder", "alice", "bob"] {
            let op = s.create_op(CrdtPayload::MemberAdded {
                peer_id: id.into(),
                display_name: id.into(),
            });
            let _ = s.apply_op(&op);
        }
        for (id, role) in [("admin", MemberRole::Admin), ("moder", MemberRole::Moderator)] {
            let op = s.create_op(CrdtPayload::RoleChanged {
                peer_id: id.into(),
                role,
                priority: 3,
            });
            let _ = s.apply_op(&op);
        }
        // Labels for the assign/unassign rows: one cosmetic, one access-bearing
        // (self-toggle is only legal for EXISTING cosmetic labels).
        for (lid, access) in [("l1", false), ("lacc", true)] {
            let op = s.create_op(CrdtPayload::LabelCreated {
                label_id: lid.into(),
                name: lid.into(),
                color: "#fff".into(),
                access,
            });
            let _ = s.apply_op(&op);
        }

        let ch = |cid: &str| CrdtPayload::ChannelRenamed {
            channel_id: cid.into(),
            new_name: "n".into(),
        };
        let cases: Vec<(&str, CrdtPayload, bool)> = vec![
            // Channel management (MANAGE_CHANNELS): admin yes, moderator/member no.
            ("admin", ch("c1"), true),
            ("moder", ch("c1"), false),
            ("alice", CrdtPayload::ChannelLayoutUpdated { layout_json: "[]".into() }, false),
            // RoleChanged goes through can_change_role (tier-gated).
            ("owner", CrdtPayload::RoleChanged { peer_id: "alice".into(), role: MemberRole::Moderator, priority: 3 }, true),
            ("alice", CrdtPayload::RoleChanged { peer_id: "bob".into(), role: MemberRole::Admin, priority: 0 }, false),
            // Server rename/settings: Owner or Admin only.
            ("admin", CrdtPayload::ServerRenamed { new_name: "X".into() }, true),
            ("moder", CrdtPayload::ServerSettingChanged { key: "k".into(), value: "v".into() }, false),
            // MemberRemoved: voluntary self-leave always; kicks need KICK_MEMBERS + outrank.
            ("alice", CrdtPayload::MemberRemoved { peer_id: "alice".into() }, true),
            ("alice", CrdtPayload::MemberRemoved { peer_id: "bob".into() }, false),
            ("moder", CrdtPayload::MemberRemoved { peer_id: "bob".into() }, true),
            ("moder", CrdtPayload::MemberRemoved { peer_id: "admin".into() }, false),
            // MemberAdded: any current member (invite), stranger no.
            ("alice", CrdtPayload::MemberAdded { peer_id: "carol".into(), display_name: "c".into() }, true),
            ("stranger", CrdtPayload::MemberAdded { peer_id: "dave".into(), display_name: "d".into() }, false),
            // Nickname / Twitch / pledge: self or Owner/Admin.
            ("alice", CrdtPayload::NicknameChanged { peer_id: "alice".into(), nickname: "a".into() }, true),
            ("alice", CrdtPayload::NicknameChanged { peer_id: "bob".into(), nickname: "x".into() }, false),
            ("alice", CrdtPayload::TwitchUsernameChanged { peer_id: "alice".into(), twitch_username: "tv".into() }, true),
            ("alice", CrdtPayload::TwitchUsernameChanged { peer_id: "bob".into(), twitch_username: "tv".into() }, false),
            ("admin", CrdtPayload::StoragePledgeChanged { peer_id: "bob".into(), pledge_bytes: 1 }, true),
            ("alice", CrdtPayload::StoragePledgeChanged { peer_id: "bob".into(), pledge_bytes: 1 }, false),
            // Pins need MANAGE_CHANNELS (moderator lacks it).
            ("admin", CrdtPayload::MessagePinned { channel_id: "c".into(), message_id: "m".into() }, true),
            ("moder", CrdtPayload::MessageUnpinned { channel_id: "c".into(), message_id: "m".into() }, false),
            // Role-permission edits: MANAGE_ROLES + must OUTRANK the target role.
            ("admin", CrdtPayload::RolePermissionsChanged { role: "moderator".into(), permissions: 0 }, true),
            ("admin", CrdtPayload::RolePermissionsChanged { role: "admin".into(), permissions: 0 }, false),
            ("moder", CrdtPayload::RolePermissionsChanged { role: "member".into(), permissions: 0 }, false),
            // Ban / unban / mute / unmute: KICK_MEMBERS (+outrank for targeted ones).
            ("moder", CrdtPayload::MemberBanned { peer_id: "bob".into() }, true),
            ("moder", CrdtPayload::MemberBanned { peer_id: "admin".into() }, false),
            ("alice", CrdtPayload::MemberBanned { peer_id: "bob".into() }, false),
            ("moder", CrdtPayload::MemberUnbanned { peer_id: "bob".into() }, true),
            ("alice", CrdtPayload::MemberUnbanned { peer_id: "bob".into() }, false),
            ("moder", CrdtPayload::MemberMuted { peer_id: "bob".into(), expires_at: u64::MAX }, true),
            ("alice", CrdtPayload::MemberMuted { peer_id: "bob".into(), expires_at: u64::MAX }, false),
            ("moder", CrdtPayload::MemberUnmuted { peer_id: "bob".into() }, true),
            // Channel access / moderation settings: MANAGE_CHANNELS.
            ("admin", CrdtPayload::ChannelVisibilityChanged { channel_id: "c".into(), visibility: "everyone".into() }, true),
            ("alice", CrdtPayload::ChannelPostingChanged { channel_id: "c".into(), posting: "everyone".into() }, false),
            ("admin", CrdtPayload::ChannelPublicChanged { channel_id: "c".into(), is_public: true }, true),
            ("alice", CrdtPayload::ChannelSlowModeChanged { channel_id: "c".into(), seconds: 5 }, false),
            ("admin", CrdtPayload::ChannelMediaOnlyChanged { channel_id: "c".into(), media_only: true }, true),
            // Labels: create/delete/update need MANAGE_ROLES; assign is
            // self-or-MANAGE_ROLES — but self ONLY for existing cosmetic
            // labels (access labels gate channels; self-assign would be
            // privilege escalation, and unknown ids fail closed).
            ("admin", CrdtPayload::LabelCreated { label_id: "l9".into(), name: "L".into(), color: "#fff".into(), access: false }, true),
            ("alice", CrdtPayload::LabelUpdated { label_id: "l1".into(), name: "L".into(), color: "#fff".into(), access: None }, false),
            ("alice", CrdtPayload::LabelDeleted { label_id: "l1".into() }, false),
            ("alice", CrdtPayload::LabelAssigned { label_id: "l1".into(), peer_id: "alice".into() }, true),
            ("alice", CrdtPayload::LabelAssigned { label_id: "l1".into(), peer_id: "bob".into() }, false),
            ("alice", CrdtPayload::LabelAssigned { label_id: "lacc".into(), peer_id: "alice".into() }, false),
            ("alice", CrdtPayload::LabelUnassigned { label_id: "lacc".into(), peer_id: "alice".into() }, false),
            ("alice", CrdtPayload::LabelAssigned { label_id: "ghost".into(), peer_id: "alice".into() }, false),
            ("admin", CrdtPayload::LabelAssigned { label_id: "lacc".into(), peer_id: "bob".into() }, true),
            ("admin", CrdtPayload::LabelUnassigned { label_id: "l1".into(), peer_id: "bob".into() }, true),
            // Label gates + grants: MANAGE_CHANNELS.
            ("admin", CrdtPayload::ChannelVisibilityLabelsChanged { channel_id: "c".into(), labels: vec!["lacc".into()] }, true),
            ("alice", CrdtPayload::ChannelVisibilityLabelsChanged { channel_id: "c".into(), labels: vec!["lacc".into()] }, false),
            ("admin", CrdtPayload::ChannelPostingLabelsChanged { channel_id: "c".into(), labels: vec![] }, true),
            ("moder", CrdtPayload::ChannelPostingLabelsChanged { channel_id: "c".into(), labels: vec![] }, false),
            ("admin", CrdtPayload::ChannelGrantSet { channel_id: "c".into(), peer_id: "bob".into(), expires_at: u64::MAX }, true),
            ("alice", CrdtPayload::ChannelGrantSet { channel_id: "c".into(), peer_id: "bob".into(), expires_at: u64::MAX }, false),
            ("admin", CrdtPayload::ChannelGrantRevoked { channel_id: "c".into(), peer_id: "bob".into() }, true),
            ("moder", CrdtPayload::ChannelGrantRevoked { channel_id: "c".into(), peer_id: "bob".into() }, false),
            // Emotes: MANAGE_EMOTES + grammar validation at ingest.
            ("admin", CrdtPayload::EmojiAdded { name: "pog".into(), hash: "a".repeat(64), animated: false }, true),
            ("admin", CrdtPayload::EmojiAdded { name: "Bad Name".into(), hash: "a".repeat(64), animated: false }, false),
            ("admin", CrdtPayload::EmojiAdded { name: "pog".into(), hash: "zz".into(), animated: false }, false),
            ("alice", CrdtPayload::EmojiAdded { name: "pog".into(), hash: "a".repeat(64), animated: false }, false),
            ("admin", CrdtPayload::EmojiRemoved { name: "pog".into() }, true),
            ("alice", CrdtPayload::EmojiRemoved { name: "pog".into() }, false),
            // Tombstone: Owner only. ServerCreated: always.
            ("owner", CrdtPayload::ServerDeleted { deleted_at: 1 }, true),
            ("admin", CrdtPayload::ServerDeleted { deleted_at: 1 }, false),
            ("stranger", CrdtPayload::ServerCreated { name: "S".into(), owner_peer_id: "stranger".into() }, true),
        ];
        for (author, payload, expect) in cases {
            let op = op_by(&mut s, author, payload);
            assert_eq!(
                s.op_allowed(&op),
                expect,
                "author={author} payload={:?}",
                op.payload
            );
        }

        // Override-awareness: granting MANAGE_CHANNELS to Member via
        // RolePermissionsChanged must open channel ops at ingest too
        // (get_permissions, not default_permissions).
        let grant = s.create_op(CrdtPayload::RolePermissionsChanged {
            role: "member".into(),
            permissions: MemberRole::Member.default_permissions() | Permission::MANAGE_CHANNELS,
        });
        let _ = s.apply_op(&grant);
        let op = op_by(&mut s, "alice", CrdtPayload::ChannelRenamed {
            channel_id: "c1".into(),
            new_name: "renamed".into(),
        });
        assert!(s.op_allowed(&op), "override-granted MANAGE_CHANNELS must pass ingest");
    }

    #[test]
    fn canonicalize_folds_device_keyed_member_to_master() {
        // Owner is master-keyed; a joiner was recorded under a DEVICE id (legacy).
        let mut state = ServerState::new("s1".into(), "S".into(), "owner_master".into());

        // Simulate a legacy joiner added under a device id with a Member role.
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "joiner_device".into(),
            display_name: "joiner".into(),
        });
        let _ = state.apply_op(&op);
        assert!(state.members.contains_key("joiner_device"));
        assert_eq!(state.members.len(), 2);

        // Resolver: joiner_device → joiner_master; everything else maps to self.
        let resolve = |id: &str| -> String {
            if id == "joiner_device" { "joiner_master".to_string() } else { id.to_string() }
        };
        let changed = state.canonicalize_members(resolve);
        assert!(changed);

        // Device key gone, master key present, owner untouched.
        assert!(!state.members.contains_key("joiner_device"));
        assert!(state.members.contains_key("joiner_master"));
        assert!(state.members.contains_key("owner_master"));
        assert_eq!(state.members.len(), 2);
        assert_eq!(state.get_role("joiner_master"), MemberRole::Member);
        assert_eq!(state.get_role("owner_master"), MemberRole::Owner);

        // Idempotent: a second pass changes nothing.
        assert!(!state.canonicalize_members(|id| id.to_string()));
    }

    #[test]
    fn canonicalize_single_device_is_noop() {
        // Identity resolver (single-device) → no change at all.
        let mut state = ServerState::new("s1".into(), "S".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "bob".into(),
            display_name: "bob".into(),
        });
        let _ = state.apply_op(&op);
        assert!(!state.canonicalize_members(|id| id.to_string()));
        assert!(state.members.contains_key("bob"));
        assert!(state.members.contains_key("owner"));
    }

    #[test]
    fn canonicalize_merges_roles_keeping_latest() {
        // A human's device leaf holds Admin (written later) while the master
        // entry is Member — folding is pure HLC LWW, so the latest write
        // (Admin) survives.
        let mut state = ServerState::new("s1".into(), "S".into(), "owner".into());

        // master entry as Member.
        let op1 = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "x_master".into(),
            display_name: "x".into(),
        });
        let _ = state.apply_op(&op1);

        // device entry, then promote it to Admin.
        let op2 = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "x_device".into(),
            display_name: "x".into(),
        });
        let _ = state.apply_op(&op2);
        let op3 = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "x_device".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        let _ = state.apply_op(&op3);

        let resolve = |id: &str| -> String {
            if id == "x_device" { "x_master".to_string() } else { id.to_string() }
        };
        assert!(state.canonicalize_members(resolve));
        assert!(!state.members.contains_key("x_device"));
        assert_eq!(state.get_role("x_master"), MemberRole::Admin);
    }

    #[test]
    fn accessors_resolve_device_to_master_via_hook() {
        // The chokepoint: ServerState accessors must collapse a DEVICE id to its
        // master before the keyed lookup, via the installed resolver hook.
        // Drive it through the real process-global node::resolver (under the
        // shared test lock — parallel tests clear/mutate the same map).
        let _lock = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        crate::node::resolver::update("dev_owner", "owner_master");
        crate::node::resolver::update("dev_bob", "bob_master");
        crate::crdt::set_identity_resolver(crate::node::resolver::resolve);

        let mut state = ServerState::new("s1".into(), "S".into(), "owner_master".into());
        // Add Bob (master-keyed) + promote him to Admin, and ban a third identity.
        let add = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "bob_master".into(), display_name: "bob".into(),
        });
        let _ = state.apply_op(&add);
        let role = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "bob_master".into(), role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        let _ = state.apply_op(&role);

        // Lookups by DEVICE id resolve to the master entry.
        assert!(state.is_member("dev_bob"), "device id should resolve to member master");
        assert_eq!(state.get_role("dev_bob"), MemberRole::Admin, "role via device id");
        assert!(state.has_permission("dev_owner", Permission::MANAGE_SERVER), "owner perms via device id");
        // Unknown device (no link) resolves to itself → not a member.
        assert!(!state.is_member("dev_stranger"));

        crate::node::resolver::clear_all();
    }

    #[test]
    fn create_server_has_general_channel_and_owner() {
        let state = ServerState::new(
            "server1".into(),
            "My Server".into(),
            "peer_creator".into(),
        );
        assert_eq!(state.name(), "My Server");
        assert_eq!(state.members.len(), 1);
        assert_eq!(state.channels.len(), 1);
        assert_eq!(state.get_role("peer_creator"), MemberRole::Owner);

        let channels = state.channels_list();
        assert_eq!(channels[0].name, "general");
    }

    #[test]
    fn add_channel_and_member() {
        let mut state = ServerState::new(
            "server1".into(),
            "Test".into(),
            "peer_a".into(),
        );

        let op1 = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-dev".into(),
            name: "dev".into(),
            category: Some("Engineering".into()),
            channel_type: "text".into(),
        });
        state.apply_op(&op1).unwrap();

        let op2 = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "Bob".into(),
        });
        state.apply_op(&op2).unwrap();

        assert_eq!(state.channels.len(), 2); // general + dev
        assert_eq!(state.members.len(), 2); // creator + Bob
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);
    }

    #[test]
    fn duplicate_ops_are_idempotent() {
        let mut state = ServerState::new(
            "server1".into(),
            "Test".into(),
            "peer_a".into(),
        );

        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-1".into(),
            name: "channel-1".into(),
            category: None,
            channel_type: "text".into(),
        });

        state.apply_op(&op).unwrap();
        state.apply_op(&op).unwrap(); // Duplicate
        state.apply_op(&op).unwrap(); // Triple

        assert_eq!(state.channels.len(), 2); // general + channel-1
        assert_eq!(state.op_log.len(), 1); // Only one op stored
    }

    #[test]
    fn concurrent_ops_converge() {
        // Simulate two peers making concurrent changes
        let mut state_a = ServerState::new(
            "server1".into(),
            "Test".into(),
            "peer_a".into(),
        );
        let mut state_b = state_a.clone();
        state_b.set_hlc(Hlc::new("peer_b".into()));

        // A adds member
        let op_a = state_a.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "Bob".into(),
        });

        // B adds channel (concurrently, doesn't know about op_a yet)
        let op_b = state_b.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-random".into(),
            name: "random".into(),
            category: None,
            channel_type: "text".into(),
        });

        // Both apply both ops (in different order)
        state_a.apply_op(&op_a).unwrap();
        state_a.apply_op(&op_b).unwrap();

        state_b.apply_op(&op_b).unwrap();
        state_b.apply_op(&op_a).unwrap();

        // Both converge to the same state
        assert_eq!(state_a.channels.len(), state_b.channels.len());
        assert_eq!(state_a.members.len(), state_b.members.len());
    }

    /// Seed a server whose "admin_peer" holds the Admin role, plus an
    /// owner-authored `twitch_verification_enabled=true` op that is NOT yet
    /// applied (tests choose when/where to apply it).
    fn owner_state_with_admin_and_setting() -> (ServerState, CrdtOp) {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let add = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "admin_peer".into(),
            display_name: "A".into(),
        });
        state.apply_op(&add).unwrap();
        let promote = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "admin_peer".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&promote).unwrap();
        let owner_set = state.create_op(CrdtPayload::ServerSettingChanged {
            key: "twitch_verification_enabled".into(),
            value: "true".into(),
        });
        (state, owner_set)
    }

    /// Give a cloned replica its own HLC that has witnessed `seen`, so its
    /// next op is strictly HLC-later (deterministic even when every op in the
    /// test lands in the same millisecond).
    fn rekey_replica(state: &mut ServerState, actor: &str, seen: &HlcTimestamp) {
        let mut hlc = Hlc::new(actor.into());
        hlc.witness(seen);
        state.set_hlc(hlc);
    }

    #[test]
    fn admin_setting_overwrite_lands_after_owner_write() {
        // The live 2026-07-16 bug: the Owner enables a server setting, an
        // Admin holding MANAGE_SERVER flips it OFF, and the flip silently
        // lost the priority-first merge on every replica (including the
        // admin's own) — the toggle "reverted". Pure HLC LWW must land it.
        let (mut owner_state, owner_set) = owner_state_with_admin_and_setting();
        owner_state.apply_op(&owner_set).unwrap();

        let mut admin_state = owner_state.clone();
        rekey_replica(&mut admin_state, "admin_peer", &owner_set.hlc);
        let admin_op = admin_state.create_op(CrdtPayload::ServerSettingChanged {
            key: "twitch_verification_enabled".into(),
            value: "false".into(),
        });

        // Authority: stock Admin now holds MANAGE_SERVER by default, so every
        // ingest accepts the op.
        assert!(owner_state.op_allowed(&admin_op));

        admin_state.apply_op(&admin_op).unwrap();
        assert_eq!(
            admin_state.settings.get("twitch_verification_enabled").unwrap().read(),
            "false",
            "the admin's own replica must reflect the admin's write"
        );

        owner_state.apply_op(&admin_op).unwrap();
        assert_eq!(
            owner_state.settings.get("twitch_verification_enabled").unwrap().read(),
            "false",
            "the owner's replica must accept the admin's later write"
        );
    }

    #[test]
    fn setting_overwrite_converges_regardless_of_apply_order() {
        let (base, owner_set) = owner_state_with_admin_and_setting();

        let mut admin_replica = base.clone();
        rekey_replica(&mut admin_replica, "admin_peer", &owner_set.hlc);
        let admin_op = admin_replica.create_op(CrdtPayload::ServerSettingChanged {
            key: "twitch_verification_enabled".into(),
            value: "false".into(),
        });

        // Neither op is applied in `base` — replay the pair in both orders
        // on fresh clones.
        let mut forward = base.clone();
        forward.apply_op(&owner_set).unwrap();
        forward.apply_op(&admin_op).unwrap();

        let mut reverse = base.clone();
        reverse.apply_op(&admin_op).unwrap();
        reverse.apply_op(&owner_set).unwrap();

        let f = forward.settings.get("twitch_verification_enabled").unwrap().read();
        let r = reverse.settings.get("twitch_verification_enabled").unwrap().read();
        assert_eq!(f, r, "apply order must not change the converged value");
        assert_eq!(f, "false", "the HLC-later (admin) write wins in both orders");
    }

    #[test]
    fn owner_has_all_permissions() {
        let state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        assert!(state.has_permission("owner", Permission::MANAGE_SERVER));
        assert!(state.has_permission("owner", Permission::MANAGE_CHANNELS));
        assert!(state.has_permission("owner", Permission::MANAGE_ROLES));
        assert!(state.has_permission("owner", Permission::KICK_MEMBERS));
    }

    #[test]
    fn member_has_limited_permissions() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
        });
        state.apply_op(&op).unwrap();

        assert!(!state.has_permission("member", Permission::MANAGE_SERVER));
        assert!(!state.has_permission("member", Permission::MANAGE_CHANNELS));
        assert!(!state.has_permission("member", Permission::MANAGE_ROLES));
        assert!(!state.has_permission("member", Permission::KICK_MEMBERS));
        assert!(state.has_permission("member", Permission::SEND_MESSAGES));
        assert!(state.has_permission("member", Permission::READ_MESSAGES));
    }

    #[test]
    fn role_change_permissions() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "admin".into(),
            display_name: "A".into(),
        });
        state.apply_op(&op).unwrap();
        // Owner (priority 3) promotes admin — uses author's priority
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "admin".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(), // Author is owner
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
        });
        state.apply_op(&op).unwrap();

        // Owner can change anyone
        assert!(state.can_change_role("owner", "admin", &MemberRole::Member));
        assert!(state.can_change_role("owner", "member", &MemberRole::Admin));

        // Admin can change member to moderator
        assert!(state.can_change_role("admin", "member", &MemberRole::Moderator));
        // Admin cannot promote to admin (same rank)
        assert!(!state.can_change_role("admin", "member", &MemberRole::Admin));
        // Admin cannot change owner
        assert!(!state.can_change_role("admin", "owner", &MemberRole::Member));
        // Member cannot change anyone
        assert!(!state.can_change_role("member", "admin", &MemberRole::Member));
    }

    #[test]
    fn kick_permissions() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "mod".into(),
            display_name: "Mod".into(),
        });
        state.apply_op(&op).unwrap();
        // Owner (priority 3) promotes moderator — uses author's priority
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "mod".into(),
            role: MemberRole::Moderator,
            priority: MemberRole::Owner.priority(), // Author is owner
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
        });
        state.apply_op(&op).unwrap();

        // Owner can kick anyone
        assert!(state.can_kick("owner", "mod"));
        assert!(state.can_kick("owner", "member"));

        // Moderator can kick members (lower rank)
        assert!(state.can_kick("mod", "member"));
        // Moderator cannot kick owner (higher rank)
        assert!(!state.can_kick("mod", "owner"));
        // Member cannot kick anyone
        assert!(!state.can_kick("member", "mod"));
    }

    #[test]
    fn role_demotion_works() {
        // Regression test: Owner promotes member→admin, then demotes admin→member.
        // The demotion must succeed because the demotion op is HLC-later than
        // the promotion (merge is pure LWW; authority lives in can_change_role).
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);

        // Promote to Admin (author=owner, priority=3)
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Admin);

        // Demote back to Member (author=owner, priority=3)
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Member,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);

        // Promote to Moderator, then demote to Member again
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Moderator,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Moderator);

        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Member,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);
    }

    #[test]
    fn moderator_role_hierarchy() {
        assert!(MemberRole::Owner.outranks(&MemberRole::Admin));
        assert!(MemberRole::Admin.outranks(&MemberRole::Moderator));
        assert!(MemberRole::Moderator.outranks(&MemberRole::Member));
        assert!(!MemberRole::Member.outranks(&MemberRole::Moderator));
        assert!(!MemberRole::Moderator.outranks(&MemberRole::Admin));
    }

    #[test]
    fn storage_pledge_set_and_read() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.get_storage_pledge("owner"), 0);
        assert_eq!(state.total_pledged_bytes(), 0);

        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "owner".into(),
            pledge_bytes: 512 * 1024 * 1024,
        });
        state.apply_op(&op).unwrap();

        assert_eq!(state.get_storage_pledge("owner"), 512 * 1024 * 1024);
        assert_eq!(state.total_pledged_bytes(), 512 * 1024 * 1024);
    }

    #[test]
    fn storage_pledge_removed_with_member() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "peer_b".into(),
            pledge_bytes: 1024 * 1024 * 1024,
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_storage_pledge("peer_b"), 1024 * 1024 * 1024);

        let op = state.create_op(CrdtPayload::MemberRemoved {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_storage_pledge("peer_b"), 0);
        assert_eq!(state.total_pledged_bytes(), 0);
    }

    #[test]
    fn storage_pledge_serde_default() {
        // Simulate old JSON without storage_pledges field
        let json = r#"{
            "server_id": "s1",
            "name": {"value": "Test", "priority": 3, "hlc": {"physical_ms": 1000, "counter": 0, "actor": "owner"}},
            "channels": {},
            "members": {},
            "roles": {},
            "settings": {},
            "op_log": []
        }"#;
        let state: ServerState = serde_json::from_str(json).unwrap();
        assert!(state.storage_pledges.is_empty());
        assert_eq!(state.get_storage_pledge("anyone"), 0);
        assert_eq!(state.total_pledged_bytes(), 0);
    }

    // --- Labels ---

    #[test]
    fn label_lifecycle_create_update_delete() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());

        let op = state.create_op(CrdtPayload::LabelCreated {
            label_id: "lbl-1".into(),
            name: "VIP".into(),
            color: "#ff0000".into(),
            access: true,
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.labels.len(), 1);
        assert_eq!(state.labels["lbl-1"].name, "VIP");
        assert!(state.labels["lbl-1"].access);

        // access: None (an old client's update) preserves the stored flag.
        let op = state.create_op(CrdtPayload::LabelUpdated {
            label_id: "lbl-1".into(),
            name: "MVP".into(),
            color: "#00ff00".into(),
            access: None,
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.labels["lbl-1"].name, "MVP");
        assert_eq!(state.labels["lbl-1"].color, "#00ff00");
        assert!(state.labels["lbl-1"].access, "access: None must PRESERVE the flag");

        // access: Some(false) explicitly demotes to cosmetic.
        let op = state.create_op(CrdtPayload::LabelUpdated {
            label_id: "lbl-1".into(),
            name: "MVP".into(),
            color: "#00ff00".into(),
            access: Some(false),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.labels["lbl-1"].access);

        let op = state.create_op(CrdtPayload::LabelDeleted {
            label_id: "lbl-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.labels.is_empty());
    }

    #[test]
    fn label_assignment_and_unassignment() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());

        let op = state.create_op(CrdtPayload::LabelCreated {
            label_id: "lbl-1".into(),
            name: "VIP".into(),
            color: "#ff0000".into(),
            access: false,
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::LabelAssigned {
            label_id: "lbl-1".into(),
            peer_id: "owner".into(),
        });
        state.apply_op(&op).unwrap();
        let labels = state.get_member_labels("owner");
        assert_eq!(labels.len(), 1);
        assert_eq!(labels[0].name, "VIP");

        // Duplicate assignment is idempotent
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_member_labels("owner").len(), 1);

        let op = state.create_op(CrdtPayload::LabelUnassigned {
            label_id: "lbl-1".into(),
            peer_id: "owner".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.get_member_labels("owner").is_empty());
        // label_assignments entry cleaned up
        assert!(!state.label_assignments.contains_key("owner"));
    }

    #[test]
    fn label_delete_cleans_up_assignments() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());

        let op = state.create_op(CrdtPayload::LabelCreated {
            label_id: "lbl-1".into(),
            name: "VIP".into(),
            color: "#ff0000".into(),
            access: false,
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::LabelAssigned {
            label_id: "lbl-1".into(),
            peer_id: "owner".into(),
        });
        state.apply_op(&op).unwrap();

        // Delete the label — assignment should be pruned
        let op = state.create_op(CrdtPayload::LabelDeleted {
            label_id: "lbl-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.get_member_labels("owner").is_empty());
    }

    // --- Label-gated channel access + temporary grants (issue #32) ---

    /// owner + admin + mod + member + vipper (a plain member holding the
    /// access label "vip"), one text channel "ch".
    fn label_gate_fixture() -> ServerState {
        let mut s = ServerState::new("s1".into(), "Test".into(), "owner".into());
        for (id, role) in [
            ("admin", Some(MemberRole::Admin)),
            ("mod", Some(MemberRole::Moderator)),
            ("member", None),
            ("vipper", None),
        ] {
            let op = s.create_op(CrdtPayload::MemberAdded {
                peer_id: id.into(),
                display_name: id.into(),
            });
            s.apply_op(&op).unwrap();
            if let Some(r) = role {
                let op = s.create_op(CrdtPayload::RoleChanged {
                    peer_id: id.into(),
                    role: r,
                    priority: MemberRole::Owner.priority(),
                });
                s.apply_op(&op).unwrap();
            }
        }
        let op = s.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch".into(),
            name: "ch".into(),
            category: None,
            channel_type: "text".into(),
        });
        s.apply_op(&op).unwrap();
        let op = s.create_op(CrdtPayload::LabelCreated {
            label_id: "vip".into(),
            name: "VIP".into(),
            color: "#fff".into(),
            access: true,
        });
        s.apply_op(&op).unwrap();
        let op = s.create_op(CrdtPayload::LabelAssigned {
            label_id: "vip".into(),
            peer_id: "vipper".into(),
        });
        s.apply_op(&op).unwrap();
        s
    }

    #[test]
    fn label_gate_replaces_visibility_tier() {
        let mut s = label_gate_fixture();
        // Gate on VIP while the tier stays Everyone — the gate must REPLACE
        // the ladder, not AND with it.
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        let now = 1_000u64;
        assert!(!s.can_see_channel_at("member", "ch", now));
        assert!(
            !s.can_see_channel_at("mod", "ch", now),
            "moderators have NO implicit access to label-gated channels"
        );
        assert!(s.can_see_channel_at("admin", "ch", now), "Admin+ implicit");
        assert!(s.can_see_channel_at("owner", "ch", now));
        assert!(s.can_see_channel_at("vipper", "ch", now), "label holder sees");
        // A label-gated channel is cryptographically isolated.
        assert!(s.channel_uses_subgroup("ch"));
        assert!(s.subgroup_channel_ids().contains(&"ch".to_string()));
        // Clearing the gate reverts to the tier ladder.
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec![],
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_see_channel_at("member", "ch", now));
        assert!(!s.channel_uses_subgroup("ch"));
    }

    #[test]
    fn label_gate_posting() {
        let mut s = label_gate_fixture();
        let op = s.create_op(CrdtPayload::ChannelPostingLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        let now = 1_000u64;
        assert!(!s.can_post_in_channel_at("member", "ch", now));
        assert!(!s.can_post_in_channel_at("mod", "ch", now));
        assert!(s.can_post_in_channel_at("admin", "ch", now));
        assert!(s.can_post_in_channel_at("vipper", "ch", now));
        // Posting gate does not affect visibility or subgrouping.
        assert!(s.can_see_channel_at("member", "ch", now));
        assert!(!s.channel_uses_subgroup("ch"));
        // Ungated Everyone posting still requires the SEND_MESSAGES bit.
        let op = s.create_op(CrdtPayload::ChannelPostingLabelsChanged {
            channel_id: "ch".into(),
            labels: vec![],
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_post_in_channel_at("member", "ch", now));
        let op = s.create_op(CrdtPayload::RolePermissionsChanged {
            role: "member".into(),
            permissions: 0,
        });
        s.apply_op(&op).unwrap();
        assert!(!s.can_post_in_channel_at("member", "ch", now));
    }

    #[test]
    fn label_deleted_while_gating_fails_closed() {
        let mut s = label_gate_fixture();
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_see_channel_at("vipper", "ch", 1_000));
        // Deleting the label strips assignments → the dangling gate id can
        // never match again: LOCKOUT (fail-closed), not fail-open.
        let op = s.create_op(CrdtPayload::LabelDeleted { label_id: "vip".into() });
        s.apply_op(&op).unwrap();
        assert!(!s.can_see_channel_at("vipper", "ch", 1_000));
        assert!(s.can_see_channel_at("admin", "ch", 1_000));
        assert!(
            s.channels["ch"].visibility_labels.contains(&"vip".to_string()),
            "dangling gate id stays until an admin rewrites the list"
        );
        assert!(s.channel_uses_subgroup("ch"));
    }

    #[test]
    fn channel_grant_lifecycle() {
        let mut s = label_gate_fixture();
        // Restrict the channel to Admin+ so only the grant can admit "member".
        let op = s.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: "ch".into(),
            visibility: "admin".into(),
        });
        s.apply_op(&op).unwrap();
        assert!(!s.can_see_channel_at("member", "ch", 1_000));

        // Timed grant: visible (and postable) before expiry, denied after —
        // with NO revoke op (lazy expiry, mirroring mutes).
        let op = s.create_op(CrdtPayload::ChannelGrantSet {
            channel_id: "ch".into(),
            peer_id: "member".into(),
            expires_at: 5_000,
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_see_channel_at("member", "ch", 4_999));
        assert!(s.can_post_in_channel_at("member", "ch", 4_999));
        assert!(s.has_channel_grant("member", "ch", 4_999));
        assert!(!s.can_see_channel_at("member", "ch", 5_000));
        assert!(!s.has_channel_grant("member", "ch", 5_000));
        // Expired rows linger but the list reader filters them.
        assert!(s.channel_grants_list("ch", 5_000).is_empty());
        assert_eq!(s.channel_grants_list("ch", 4_999).len(), 1);

        // A newer grant wins LWW regardless of apply order.
        let mut b = s.clone();
        let set_short = s.create_op(CrdtPayload::ChannelGrantSet {
            channel_id: "ch".into(),
            peer_id: "member".into(),
            expires_at: 6_000,
        });
        let set_long = s.create_op(CrdtPayload::ChannelGrantSet {
            channel_id: "ch".into(),
            peer_id: "member".into(),
            expires_at: u64::MAX,
        });
        s.apply_op(&set_short).unwrap();
        s.apply_op(&set_long).unwrap();
        b.apply_op(&set_long).unwrap();
        b.apply_op(&set_short).unwrap();
        assert!(s.can_see_channel_at("member", "ch", u64::MAX - 1), "permanent grant");
        assert!(b.can_see_channel_at("member", "ch", u64::MAX - 1), "same result in reverse order");

        // Revoke prunes the row (and the empty per-channel map).
        let op = s.create_op(CrdtPayload::ChannelGrantRevoked {
            channel_id: "ch".into(),
            peer_id: "member".into(),
        });
        s.apply_op(&op).unwrap();
        assert!(!s.can_see_channel_at("member", "ch", 1_000));
        assert!(!s.channel_grants.contains_key("ch"));
    }

    // --- Bans ---

    #[test]
    fn ban_removes_member_and_associated_data() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "bad_peer".into(),
            display_name: "Bad".into(),
        });
        state.apply_op(&op).unwrap();

        // Give them a nickname and storage pledge first
        let op = state.create_op(CrdtPayload::NicknameChanged {
            peer_id: "bad_peer".into(),
            nickname: "Trouble".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "bad_peer".into(),
            pledge_bytes: 1024,
        });
        state.apply_op(&op).unwrap();

        // Ban them
        let op = state.create_op(CrdtPayload::MemberBanned {
            peer_id: "bad_peer".into(),
        });
        state.apply_op(&op).unwrap();

        assert!(state.is_banned("bad_peer"));
        assert!(!state.members.contains_key("bad_peer"));
        assert!(!state.roles.contains_key("bad_peer"));
        assert!(!state.nicknames.contains_key("bad_peer"));
        assert!(!state.storage_pledges.contains_key("bad_peer"));
        assert!(state.banned_list().contains(&"bad_peer".to_string()));
    }

    #[test]
    fn unban_allows_rejoin() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberBanned {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.is_banned("peer_b"));

        let op = state.create_op(CrdtPayload::MemberUnbanned {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.is_banned("peer_b"));
        // Unbanned members are pruned from banned_members map
        assert!(state.banned_list().is_empty());
    }

    #[test]
    fn is_banned_defaults_false() {
        let state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        assert!(!state.is_banned("nonexistent"));
    }

    // --- Channel visibility / posting ---

    #[test]
    fn channel_visibility_restricts_access() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-secret".into(),
            name: "secret".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();

        // Add a regular member and a moderator
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "mod".into(),
            display_name: "Mod".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "mod".into(),
            role: MemberRole::Moderator,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();

        // Everyone can see it by default
        assert!(state.can_see_channel("member", "ch-secret"));

        // Restrict to moderator+
        let op = state.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: "ch-secret".into(),
            visibility: "moderator".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.can_see_channel("member", "ch-secret"));
        assert!(state.can_see_channel("mod", "ch-secret"));
        assert!(state.can_see_channel("owner", "ch-secret"));

        // Restrict to admin+
        let op = state.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: "ch-secret".into(),
            visibility: "admin".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.can_see_channel("member", "ch-secret"));
        assert!(!state.can_see_channel("mod", "ch-secret"));
        assert!(state.can_see_channel("owner", "ch-secret")); // owner always sees
    }

    #[test]
    fn channel_posting_restricts_sending() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-announce".into(),
            name: "announcements".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
        });
        state.apply_op(&op).unwrap();

        // Everyone can post by default
        assert!(state.can_post_in_channel("member", "ch-announce"));

        // Restrict to admin+
        let op = state.create_op(CrdtPayload::ChannelPostingChanged {
            channel_id: "ch-announce".into(),
            posting: "admin".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.can_post_in_channel("member", "ch-announce"));
        assert!(state.can_post_in_channel("owner", "ch-announce"));
    }

    #[test]
    fn channel_public_flag() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let general_id = state.channels.keys().next().unwrap().clone();

        assert!(!state.is_channel_public(&general_id));

        let op = state.create_op(CrdtPayload::ChannelPublicChanged {
            channel_id: general_id.clone(),
            is_public: true,
        });
        state.apply_op(&op).unwrap();
        assert!(state.is_channel_public(&general_id));

        let op = state.create_op(CrdtPayload::ChannelPublicChanged {
            channel_id: general_id.clone(),
            is_public: false,
        });
        state.apply_op(&op).unwrap();
        assert!(!state.is_channel_public(&general_id));
    }

    #[test]
    fn can_see_nonexistent_channel_returns_false() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
        });
        state.apply_op(&op).unwrap();
        // Non-owner gets false for a channel that doesn't exist
        assert!(!state.can_see_channel("member", "does-not-exist"));
    }

    // --- Nicknames ---

    #[test]
    fn nickname_set_and_read() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.get_nickname("owner"), "");

        let op = state.create_op(CrdtPayload::NicknameChanged {
            peer_id: "owner".into(),
            nickname: "Boss".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_nickname("owner"), "Boss");
    }

    // --- Twitch usernames ---

    #[test]
    fn twitch_username_set_and_read() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.get_twitch_username("owner"), "");

        let op = state.create_op(CrdtPayload::TwitchUsernameChanged {
            peer_id: "owner".into(),
            twitch_username: "cool_streamer".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_twitch_username("owner"), "cool_streamer");
    }

    // --- Pins ---

    #[test]
    fn pin_and_unpin_messages() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let ch_id = state.channels.keys().next().unwrap().clone();

        assert!(state.get_pinned_messages(&ch_id).is_empty());

        let op = state.create_op(CrdtPayload::MessagePinned {
            channel_id: ch_id.clone(),
            message_id: "msg-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id), vec!["msg-1"]);

        // Duplicate pin is idempotent
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id).len(), 1);

        let op = state.create_op(CrdtPayload::MessagePinned {
            channel_id: ch_id.clone(),
            message_id: "msg-2".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id).len(), 2);

        let op = state.create_op(CrdtPayload::MessageUnpinned {
            channel_id: ch_id.clone(),
            message_id: "msg-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id), vec!["msg-2"]);

        // Unpin last message cleans up the map entry
        let op = state.create_op(CrdtPayload::MessageUnpinned {
            channel_id: ch_id.clone(),
            message_id: "msg-2".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.pinned_messages.contains_key(&ch_id));
    }

    // --- Channel layout ---

    #[test]
    fn channel_layout_update() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        assert!(state.channel_layout.is_empty());

        let layout = vec![
            ChannelLayoutItem::Category { name: "General".into() },
            ChannelLayoutItem::Channel { channel_id: "ch-1".into() },
            ChannelLayoutItem::Separator,
            ChannelLayoutItem::Channel { channel_id: "ch-2".into() },
        ];
        let layout_json = serde_json::to_string(&layout).unwrap();

        let op = state.create_op(CrdtPayload::ChannelLayoutUpdated { layout_json });
        state.apply_op(&op).unwrap();
        assert_eq!(state.channel_layout.len(), 4);
        assert_eq!(
            state.channel_layout[0],
            ChannelLayoutItem::Category { name: "General".into() }
        );
        assert_eq!(state.channel_layout[2], ChannelLayoutItem::Separator);
    }

    #[test]
    fn channel_layout_invalid_json_ignored() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelLayoutUpdated {
            layout_json: "not valid json".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.channel_layout.is_empty());
    }

    // --- Custom role permissions ---

    #[test]
    fn custom_role_permissions_override_defaults() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
        });
        state.apply_op(&op).unwrap();

        // Default: member can't manage channels
        assert!(!state.has_permission("member", Permission::MANAGE_CHANNELS));

        // Grant MANAGE_CHANNELS to the Member role
        let custom = Permission::SEND_MESSAGES | Permission::READ_MESSAGES | Permission::MANAGE_CHANNELS;
        let op = state.create_op(CrdtPayload::RolePermissionsChanged {
            role: "member".into(),
            permissions: custom,
        });
        state.apply_op(&op).unwrap();

        assert!(state.has_permission("member", Permission::MANAGE_CHANNELS));
        assert_eq!(state.get_role_permissions("member"), custom);
        // Owner role still returns ALL regardless of customization
        assert_eq!(state.get_role_permissions("owner"), Permission::ALL);
    }

    // --- Server settings ---

    #[test]
    fn server_setting_and_min_pledge() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());

        // Default min_pledge_mb is 512
        assert_eq!(state.min_pledge_mb(), 512);

        let op = state.create_op(CrdtPayload::ServerSettingChanged {
            key: "min_pledge_mb".into(),
            value: "1024".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.min_pledge_mb(), 1024);
    }

    // --- Server rename ---

    #[test]
    fn server_rename() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.name(), "Test");

        let op = state.create_op(CrdtPayload::ServerRenamed {
            new_name: "Renamed Server".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.name(), "Renamed Server");
    }

    // --- Channel rename and remove ---

    #[test]
    fn channel_rename_and_remove() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-dev".into(),
            name: "dev".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::ChannelRenamed {
            channel_id: "ch-dev".into(),
            new_name: "development".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.channels["ch-dev"].name, "development");

        let op = state.create_op(CrdtPayload::ChannelRemoved {
            channel_id: "ch-dev".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.channels.contains_key("ch-dev"));
    }

    // --- Voice channel type ---

    #[test]
    fn voice_channel_type() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-vc".into(),
            name: "Voice".into(),
            category: None,
            channel_type: "voice".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.channels["ch-vc"].channel_type, ChannelType::Voice);
    }

    // --- Member removal cleans up associated data ---

    #[test]
    fn member_removal_cleans_up_all_state() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::NicknameChanged {
            peer_id: "peer_b".into(),
            nickname: "Bee".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::TwitchUsernameChanged {
            peer_id: "peer_b".into(),
            twitch_username: "bee_tv".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "peer_b".into(),
            pledge_bytes: 1024,
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberRemoved {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();

        assert!(!state.members.contains_key("peer_b"));
        assert!(!state.roles.contains_key("peer_b"));
        assert!(!state.nicknames.contains_key("peer_b"));
        assert!(!state.twitch_usernames.contains_key("peer_b"));
        assert!(!state.storage_pledges.contains_key("peer_b"));
    }

    // --- Op log compaction ---

    #[test]
    fn op_log_compacts_at_limit() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());

        // Apply 1010 ops (well past the 1000-op limit)
        for i in 0..1010 {
            let op = state.create_op(CrdtPayload::ServerSettingChanged {
                key: format!("key_{i}"),
                value: format!("val_{i}"),
            });
            state.apply_op(&op).unwrap();
        }

        // Op log should be capped at 1000
        assert!(state.op_log.len() <= 1000);

        // State should still be correct — settings from early ops are still applied
        assert_eq!(*state.settings["key_0"].read(), "val_0");
        assert_eq!(*state.settings["key_1009"].read(), "val_1009");
    }

    #[test]
    fn op_log_dedup_survives_compaction() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());

        // Fill past compaction threshold
        for i in 0..1005 {
            let op = state.create_op(CrdtPayload::ServerSettingChanged {
                key: format!("k{i}"),
                value: format!("v{i}"),
            });
            state.apply_op(&op).unwrap();
        }

        // Create a fresh op and replay it — should be accepted then deduped
        let op = state.create_op(CrdtPayload::ServerRenamed {
            new_name: "Compacted".into(),
        });
        state.apply_op(&op).unwrap();
        let before = state.op_log.len();
        state.apply_op(&op).unwrap(); // duplicate
        assert_eq!(state.op_log.len(), before);
    }

    // --- Serde backward compat ---

    #[test]
    fn serde_missing_fields_use_defaults() {
        // Simulates loading state JSON from an older version that doesn't have
        // newer fields (labels, banned_members, etc.)
        let json = r#"{
            "server_id": "s1",
            "name": {"value": "Old Server", "priority": 3, "hlc": {"physical_ms": 1000, "counter": 0, "actor": "owner"}},
            "channels": {},
            "members": {},
            "roles": {},
            "settings": {},
            "op_log": []
        }"#;
        let state: ServerState = serde_json::from_str(json).unwrap();
        assert!(state.labels.is_empty());
        assert!(state.label_assignments.is_empty());
        assert!(state.banned_members.is_empty());
        assert!(state.role_permissions.is_empty());
        assert!(state.nicknames.is_empty());
        assert!(state.twitch_usernames.is_empty());
        assert!(state.pinned_messages.is_empty());
        assert!(state.channel_layout.is_empty());
        assert!(state.channel_grants.is_empty());

        // A channel and a label serialized by a pre-issue-#32 build parse
        // with the safe defaults (no gates, cosmetic).
        let ch: ChannelInfo = serde_json::from_str(
            r#"{"channel_id":"c1","name":"general","category":null}"#,
        ).unwrap();
        assert!(ch.visibility_labels.is_empty());
        assert!(ch.posting_labels.is_empty());
        let label: LabelInfo = serde_json::from_str(
            r##"{"label_id":"l1","name":"VIP","color":"#fff"}"##,
        ).unwrap();
        assert!(!label.access);
    }

    // --- Wrong server_id rejected ---

    #[test]
    fn op_for_wrong_server_rejected() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        let mut other = ServerState::new("s2".into(), "Other".into(), "owner".into());
        let op = other.create_op(CrdtPayload::ServerRenamed {
            new_name: "Hacked".into(),
        });
        assert!(state.apply_op(&op).is_err());
    }

    // --- labels_list sort ---

    #[test]
    fn labels_list_sorted_by_name() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "owner".into());
        for (id, name) in [("lbl-z", "Zebra"), ("lbl-a", "Alpha"), ("lbl-m", "Middle")] {
            let op = state.create_op(CrdtPayload::LabelCreated {
                label_id: id.into(),
                name: name.into(),
                color: "#000".into(),
                access: false,
            });
            state.apply_op(&op).unwrap();
        }
        let names: Vec<_> = state.labels_list().iter().map(|l| l.name.as_str()).collect();
        assert_eq!(names, vec!["Alpha", "Middle", "Zebra"]);
    }

    // --- ServerCreated op ---

    #[test]
    fn server_created_op_sets_owner() {
        let mut state = ServerState::new("s1".into(), "Placeholder".into(), "temp".into());
        let op = CrdtOp {
            server_id: "s1".into(),
            hlc: HlcTimestamp { physical_ms: 1, counter: 0, actor: "new_owner".into() },
            author: "new_owner".into(),
            payload: CrdtPayload::ServerCreated {
                name: "Real Name".into(),
                owner_peer_id: "new_owner".into(),
            },
        };
        state.apply_op(&op).unwrap();
        assert_eq!(state.name(), "Real Name");
        assert_eq!(state.get_role("new_owner"), MemberRole::Owner);
        assert!(state.members.contains_key("new_owner"));
    }
}
