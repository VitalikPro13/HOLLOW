use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;

/// A single CRDT operation — the unit of replication.
///
/// Each op is self-contained: server_id, author, timestamp, and payload.
/// Ops are idempotent (safe to apply multiple times) and commutative
/// (order doesn't matter for final state).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrdtOp {
    pub server_id: String,
    pub hlc: HlcTimestamp,
    pub author: String,
    pub payload: CrdtPayload,
}

/// The payload of a CRDT operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum CrdtPayload {
    // Server-level
    ServerCreated {
        name: String,
        owner_peer_id: String,
    },
    ServerRenamed {
        new_name: String,
    },
    ServerSettingChanged {
        key: String,
        value: String,
    },
    /// Server deletion tombstone. Owner-authored only (validated at ingest). Marks
    /// the ServerState `deleted` and drains membership, but the op survives in the
    /// op_log so reconnecting members reconcile the deletion via normal grow-only
    /// sync. `deleted_at` is informational (ordering uses `op.hlc`).
    ServerDeleted {
        deleted_at: i64,
    },

    // Channel operations
    ChannelAdded {
        channel_id: String,
        name: String,
        category: Option<String>,
        #[serde(default)]
        channel_type: String,
    },
    ChannelRemoved {
        channel_id: String,
    },
    ChannelRenamed {
        channel_id: String,
        new_name: String,
    },

    // Member operations
    MemberAdded {
        peer_id: String,
        display_name: String,
    },
    MemberRemoved {
        peer_id: String,
    },

    // Role operations
    RoleChanged {
        peer_id: String,
        role: MemberRole,
        priority: u8,
    },

    // Nickname operations
    NicknameChanged {
        peer_id: String,
        nickname: String,
    },

    // Twitch username (set on Twitch-verified join)
    TwitchUsernameChanged {
        peer_id: String,
        twitch_username: String,
    },

    // Channel layout (ordering/categories)
    ChannelLayoutUpdated {
        layout_json: String,
    },

    // Pin operations
    MessagePinned {
        channel_id: String,
        message_id: String,
    },
    MessageUnpinned {
        channel_id: String,
        message_id: String,
    },

    // Storage pledge (Phase 4)
    StoragePledgeChanged {
        peer_id: String,
        pledge_bytes: u64,
    },

    // Role permissions customization (Phase 6.75)
    RolePermissionsChanged {
        role: String,
        permissions: u32,
    },

    // Labels — cosmetic roles (Phase 6.75)
    LabelCreated {
        label_id: String,
        name: String,
        color: String,
    },
    LabelDeleted {
        label_id: String,
    },
    LabelUpdated {
        label_id: String,
        name: String,
        color: String,
    },
    LabelAssigned {
        label_id: String,
        peer_id: String,
    },
    LabelUnassigned {
        label_id: String,
        peer_id: String,
    },

    // Channel access control (Phase 6.75)
    ChannelVisibilityChanged {
        channel_id: String,
        visibility: String,
    },
    ChannelPostingChanged {
        channel_id: String,
        posting: String,
    },
    ChannelPublicChanged {
        channel_id: String,
        is_public: bool,
    },

    // Ban system (Phase 6.75)
    MemberBanned {
        peer_id: String,
    },
    MemberUnbanned {
        peer_id: String,
    },

    // Moderation trio (mute / slow mode / media-only)
    /// Server-wide mute (read-only member). `expires_at` = epoch ms;
    /// `u64::MAX` = permanent.
    MemberMuted {
        peer_id: String,
        expires_at: u64,
    },
    MemberUnmuted {
        peer_id: String,
    },
    /// Per-channel slow mode: min seconds between posts per member (0 = off).
    ChannelSlowModeChanged {
        channel_id: String,
        seconds: u32,
    },
    /// Per-channel media-only: only image/video/GIF attachments allowed.
    ChannelMediaOnlyChanged {
        channel_id: String,
        media_only: bool,
    },

    // Custom emotes (server emote set)
    /// Add (or replace, same name) a custom emote. `hash` is the SHA-256 hex
    /// of the processed WebP bytes — the CRDT carries METADATA ONLY; bytes
    /// replicate on demand via EmoteRequest/EmoteResponse (content-addressed,
    /// receiver-verified). Mirrors the showcase asset playbook.
    EmojiAdded {
        name: String,
        hash: String,
        animated: bool,
    },
    EmojiRemoved {
        name: String,
    },
}

/// Tolerant sync-batch parse: each op deserializes INDIVIDUALLY, so a batch
/// containing a NEWER client's payload variant skips just that op instead of
/// poisoning the whole Vec (which permanently wedged older clients' server
/// sync whenever any member used a feature they didn't know yet).
pub fn parse_ops_tolerant(json: &str) -> Vec<CrdtOp> {
    match serde_json::from_str::<Vec<serde_json::Value>>(json) {
        Ok(vals) => vals
            .into_iter()
            .filter_map(|v| serde_json::from_value::<CrdtOp>(v).ok())
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Member roles with hierarchical priority.
/// Owner > Admin > Moderator > Member.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MemberRole {
    Owner,
    Admin,
    Moderator,
    Member,
}

impl MemberRole {
    /// Numeric priority for CRDT conflict resolution.
    /// Higher = more authority. Used by AdminLwwReg to resolve conflicts.
    pub fn priority(&self) -> u8 {
        match self {
            Self::Owner => 3,
            Self::Admin => 2,
            Self::Moderator => 1,
            Self::Member => 0,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Moderator => "moderator",
            Self::Member => "member",
        }
    }

    /// Parse a role from a string. Returns Member if unrecognized.
    pub fn from_str(s: &str) -> Self {
        match s {
            "owner" => Self::Owner,
            "admin" => Self::Admin,
            "moderator" => Self::Moderator,
            _ => Self::Member,
        }
    }

    /// Default permissions bitmask for this role.
    pub fn default_permissions(&self) -> u32 {
        match self {
            Self::Owner => Permission::ALL,
            Self::Admin => Permission::MANAGE_CHANNELS
                | Permission::MANAGE_ROLES
                | Permission::KICK_MEMBERS
                | Permission::SEND_MESSAGES
                | Permission::READ_MESSAGES
                | Permission::MANAGE_EMOTES,
            Self::Moderator => Permission::KICK_MEMBERS
                | Permission::SEND_MESSAGES
                | Permission::READ_MESSAGES,
            Self::Member => Permission::SEND_MESSAGES | Permission::READ_MESSAGES,
        }
    }

    /// Whether this role outranks another.
    pub fn outranks(&self, other: &Self) -> bool {
        self.priority() > other.priority()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn role_priority_order() {
        assert_eq!(MemberRole::Owner.priority(), 3);
        assert_eq!(MemberRole::Admin.priority(), 2);
        assert_eq!(MemberRole::Moderator.priority(), 1);
        assert_eq!(MemberRole::Member.priority(), 0);
    }

    #[test]
    fn role_as_str_round_trip() {
        for role in [MemberRole::Owner, MemberRole::Admin, MemberRole::Moderator, MemberRole::Member] {
            let s = role.as_str();
            let parsed = MemberRole::from_str(s);
            assert_eq!(parsed, role);
        }
    }

    #[test]
    fn from_str_unknown_defaults_to_member() {
        assert_eq!(MemberRole::from_str("superadmin"), MemberRole::Member);
        assert_eq!(MemberRole::from_str(""), MemberRole::Member);
        assert_eq!(MemberRole::from_str("Owner"), MemberRole::Member); // case-sensitive
    }

    #[test]
    fn outranks_full_hierarchy() {
        assert!(MemberRole::Owner.outranks(&MemberRole::Admin));
        assert!(MemberRole::Owner.outranks(&MemberRole::Moderator));
        assert!(MemberRole::Owner.outranks(&MemberRole::Member));
        assert!(MemberRole::Admin.outranks(&MemberRole::Moderator));
        assert!(MemberRole::Admin.outranks(&MemberRole::Member));
        assert!(MemberRole::Moderator.outranks(&MemberRole::Member));

        // No role outranks itself
        assert!(!MemberRole::Owner.outranks(&MemberRole::Owner));
        assert!(!MemberRole::Member.outranks(&MemberRole::Member));

        // Lower can't outrank higher
        assert!(!MemberRole::Member.outranks(&MemberRole::Moderator));
        assert!(!MemberRole::Moderator.outranks(&MemberRole::Admin));
        assert!(!MemberRole::Admin.outranks(&MemberRole::Owner));
    }

    #[test]
    fn default_permissions_owner_has_all() {
        assert_eq!(MemberRole::Owner.default_permissions(), Permission::ALL);
    }

    #[test]
    fn default_permissions_member_read_send_only() {
        let perms = MemberRole::Member.default_permissions();
        assert_ne!(perms & Permission::SEND_MESSAGES, 0);
        assert_ne!(perms & Permission::READ_MESSAGES, 0);
        assert_eq!(perms & Permission::MANAGE_SERVER, 0);
        assert_eq!(perms & Permission::MANAGE_CHANNELS, 0);
        assert_eq!(perms & Permission::MANAGE_ROLES, 0);
        assert_eq!(perms & Permission::KICK_MEMBERS, 0);
    }

    #[test]
    fn default_permissions_escalation_by_rank() {
        let member = MemberRole::Member.default_permissions();
        let moderator = MemberRole::Moderator.default_permissions();
        let admin = MemberRole::Admin.default_permissions();
        let owner = MemberRole::Owner.default_permissions();

        // Each higher rank has at least the permissions of lower ranks
        assert_eq!(member & moderator, member);
        assert_eq!(moderator & admin, moderator);
        assert_eq!(admin & owner, admin);
    }

    #[test]
    fn permission_bits_are_distinct() {
        let bits = [
            Permission::MANAGE_SERVER,
            Permission::MANAGE_CHANNELS,
            Permission::MANAGE_ROLES,
            Permission::KICK_MEMBERS,
            Permission::SEND_MESSAGES,
            Permission::READ_MESSAGES,
        ];
        for (i, a) in bits.iter().enumerate() {
            for (j, b) in bits.iter().enumerate() {
                if i != j {
                    assert_eq!(a & b, 0, "bits {i} and {j} overlap");
                }
            }
        }
    }

    #[test]
    fn permission_all_includes_every_bit() {
        assert_ne!(Permission::ALL & Permission::MANAGE_SERVER, 0);
        assert_ne!(Permission::ALL & Permission::MANAGE_CHANNELS, 0);
        assert_ne!(Permission::ALL & Permission::MANAGE_ROLES, 0);
        assert_ne!(Permission::ALL & Permission::KICK_MEMBERS, 0);
        assert_ne!(Permission::ALL & Permission::SEND_MESSAGES, 0);
        assert_ne!(Permission::ALL & Permission::READ_MESSAGES, 0);
    }

    #[test]
    fn crdt_op_serde_round_trip() {
        let op = CrdtOp {
            server_id: "srv-1".into(),
            hlc: super::super::hlc::HlcTimestamp { physical_ms: 1000, counter: 0, actor: "peer_a".into() },
            author: "peer_a".into(),
            payload: CrdtPayload::LabelCreated {
                label_id: "lbl-1".into(),
                name: "VIP".into(),
                color: "#ff0000".into(),
            },
        };
        let json = serde_json::to_string(&op).unwrap();
        let deserialized: CrdtOp = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.server_id, "srv-1");
        assert_eq!(deserialized.author, "peer_a");
        match &deserialized.payload {
            CrdtPayload::LabelCreated { label_id, name, color } => {
                assert_eq!(label_id, "lbl-1");
                assert_eq!(name, "VIP");
                assert_eq!(color, "#ff0000");
            }
            _ => panic!("Wrong payload variant after deserialization"),
        }
    }
}

/// Permission bitmask constants.
pub struct Permission;

impl Permission {
    pub const MANAGE_SERVER: u32 = 1 << 0;
    pub const MANAGE_CHANNELS: u32 = 1 << 1;
    pub const MANAGE_ROLES: u32 = 1 << 2;
    pub const KICK_MEMBERS: u32 = 1 << 4;
    pub const SEND_MESSAGES: u32 = 1 << 5;
    pub const READ_MESSAGES: u32 = 1 << 6;
    /// Add/remove custom server emotes. Admin+ by default.
    pub const MANAGE_EMOTES: u32 = 1 << 7;

    /// Owner gets all permissions.
    pub const ALL: u32 = Self::MANAGE_SERVER
        | Self::MANAGE_CHANNELS
        | Self::MANAGE_ROLES
        | Self::KICK_MEMBERS
        | Self::SEND_MESSAGES
        | Self::READ_MESSAGES
        | Self::MANAGE_EMOTES;
}
