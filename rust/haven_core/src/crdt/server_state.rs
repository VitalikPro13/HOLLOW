use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::admin_lww::AdminLwwReg;
use super::hlc::Hlc;
use super::operations::{CrdtOp, CrdtPayload, MemberRole, Permission};

/// Metadata for a channel within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ChannelInfo {
    pub channel_id: String,
    pub name: String,
    pub category: Option<String>,
}

/// Metadata for a member within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MemberInfo {
    pub peer_id: String,
    pub display_name: String,
}

/// The full CRDT state of a Haven server.
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
    pub settings: HashMap<String, AdminLwwReg<String>>,
    pub op_log: Vec<CrdtOp>,
    #[serde(skip)]
    pub hlc: Option<Hlc>,
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
            settings: HashMap::new(),
            op_log: Vec::new(),
            hlc: Some(hlc),
        }
    }

    /// Restore from persistence (HLC set separately via `set_hlc`).
    pub fn set_hlc(&mut self, hlc: Hlc) {
        self.hlc = Some(hlc);
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

        // Check for duplicate (same author + same HLC = same op)
        if self.op_log.iter().any(|existing| {
            existing.author == op.author
                && existing.hlc == op.hlc
        }) {
            return Ok(()); // Already applied — idempotent
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
            } => {
                self.channels.entry(channel_id.clone()).or_insert_with(|| {
                    ChannelInfo {
                        channel_id: channel_id.clone(),
                        name: name.clone(),
                        category: category.clone(),
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
        }

        // Append to op log (sorted insert by HLC for deterministic ordering)
        let insert_pos = self
            .op_log
            .binary_search_by(|existing| existing.hlc.cmp(&op.hlc))
            .unwrap_or_else(|pos| pos);
        self.op_log.insert(insert_pos, op.clone());

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

    /// Look up author's priority from their role in this server.
    fn author_priority(&self, author: &str) -> u8 {
        self.roles
            .get(author)
            .map(|reg| reg.read().priority())
            .unwrap_or(0)
    }

    /// Get the effective permissions bitmask for a peer.
    /// Owner gets ALL permissions regardless.
    pub fn get_permissions(&self, peer_id: &str) -> u32 {
        let role = self.get_role(peer_id);
        if role == MemberRole::Owner {
            return Permission::ALL;
        }
        role.default_permissions()
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
}
