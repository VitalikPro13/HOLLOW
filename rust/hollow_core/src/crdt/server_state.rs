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

/// A cosmetic label (tag) that can be assigned to members.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct LabelInfo {
    pub label_id: String,
    pub name: String,
    pub color: String,
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
    #[serde(default)]
    pub labels: HashMap<String, LabelInfo>,
    #[serde(default)]
    pub label_assignments: HashMap<String, Vec<String>>,
    #[serde(default, skip_serializing)]
    pub op_log: Vec<CrdtOp>,
    #[serde(skip)]
    pub hlc: Option<Hlc>,
    #[serde(skip)]
    op_log_dedup: HashSet<(String, HlcTimestamp)>,
}

impl ServerState {
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
            labels: HashMap::new(),
            label_assignments: HashMap::new(),
            op_log: Vec::new(),
            hlc: Some(hlc),
            op_log_dedup: HashSet::new(),
        }
    }

    /// Restore from persistence (HLC set separately via `set_hlc`).
    pub fn set_hlc(&mut self, hlc: Hlc) {
        self.hlc = Some(hlc);
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

            CrdtPayload::RoleChanged {
                peer_id,
                role,
                priority,
            } => {
                // Use the author's priority (from the op payload) so that higher-ranked
                // authors can demote lower-ranked members. The priority in the payload
                // is the author's role priority, not the target role's.
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
            }

            CrdtPayload::LabelCreated { label_id, name, color } => {
                self.labels.entry(label_id.clone()).or_insert_with(|| {
                    LabelInfo {
                        label_id: label_id.clone(),
                        name: name.clone(),
                        color: color.clone(),
                    }
                });
            }

            CrdtPayload::LabelDeleted { label_id } => {
                self.labels.remove(label_id);
                for assignments in self.label_assignments.values_mut() {
                    assignments.retain(|id| id != label_id);
                }
            }

            CrdtPayload::LabelUpdated { label_id, name, color } => {
                if let Some(label) = self.labels.get_mut(label_id) {
                    label.name = name.clone();
                    label.color = color.clone();
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

        // Prune unbanned members to prevent unbounded growth.
        self.banned_members.retain(|_, reg| *reg.read());

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
        self.roles
            .get(peer_id)
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

    /// Whether the server is private (invite-only). Defaults to public.
    /// Stored in `settings["is_private"]` as "true"/"false".
    pub fn is_private(&self) -> bool {
        self.settings
            .get("is_private")
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

    /// Look up author's priority from their role in this server.
    fn author_priority(&self, author: &str) -> u8 {
        self.roles
            .get(author)
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
        self.banned_members
            .get(peer_id)
            .map(|reg| *reg.read())
            .unwrap_or(false)
    }

    /// Check if `actor` can ban `target`. Same hierarchy as kick.
    pub fn can_ban(&self, actor: &str, target: &str) -> bool {
        self.can_kick(actor, target)
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

    /// Check if a peer can see a channel.
    pub fn can_see_channel(&self, peer_id: &str, channel_id: &str) -> bool {
        let role = self.get_role(peer_id);
        if role == MemberRole::Owner { return true; }
        if let Some(ch) = self.channels.get(channel_id) {
            match ch.visibility {
                ChannelVisibility::Everyone => true,
                ChannelVisibility::ModeratorPlus => role.priority() >= MemberRole::Moderator.priority(),
                ChannelVisibility::AdminPlus => role.priority() >= MemberRole::Admin.priority(),
            }
        } else {
            false
        }
    }

    pub fn is_channel_public(&self, channel_id: &str) -> bool {
        self.channels.get(channel_id).map_or(false, |ch| ch.is_public)
    }

    /// Check if a peer can post in a channel.
    pub fn can_post_in_channel(&self, peer_id: &str, channel_id: &str) -> bool {
        let role = self.get_role(peer_id);
        if role == MemberRole::Owner { return true; }
        if let Some(ch) = self.channels.get(channel_id) {
            match ch.posting {
                ChannelPosting::Everyone => self.has_permission(peer_id, Permission::SEND_MESSAGES),
                ChannelPosting::ModeratorPlus => role.priority() >= MemberRole::Moderator.priority(),
                ChannelPosting::AdminPlus => role.priority() >= MemberRole::Admin.priority(),
            }
        } else {
            false
        }
    }
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
        // The demotion must succeed because the author (Owner, priority 3) outranks
        // the existing entry.
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
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.labels.len(), 1);
        assert_eq!(state.labels["lbl-1"].name, "VIP");

        let op = state.create_op(CrdtPayload::LabelUpdated {
            label_id: "lbl-1".into(),
            name: "MVP".into(),
            color: "#00ff00".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.labels["lbl-1"].name, "MVP");
        assert_eq!(state.labels["lbl-1"].color, "#00ff00");

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
