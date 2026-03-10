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

    // Channel operations
    ChannelAdded {
        channel_id: String,
        name: String,
        category: Option<String>,
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
                | Permission::MANAGE_INVITES
                | Permission::KICK_MEMBERS
                | Permission::SEND_MESSAGES
                | Permission::READ_MESSAGES,
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

/// Permission bitmask constants.
pub struct Permission;

impl Permission {
    pub const MANAGE_SERVER: u32 = 1 << 0;
    pub const MANAGE_CHANNELS: u32 = 1 << 1;
    pub const MANAGE_ROLES: u32 = 1 << 2;
    pub const MANAGE_INVITES: u32 = 1 << 3;
    pub const KICK_MEMBERS: u32 = 1 << 4;
    pub const SEND_MESSAGES: u32 = 1 << 5;
    pub const READ_MESSAGES: u32 = 1 << 6;

    /// Owner gets all permissions.
    pub const ALL: u32 = Self::MANAGE_SERVER
        | Self::MANAGE_CHANNELS
        | Self::MANAGE_ROLES
        | Self::MANAGE_INVITES
        | Self::KICK_MEMBERS
        | Self::SEND_MESSAGES
        | Self::READ_MESSAGES;
}
