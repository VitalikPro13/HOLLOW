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
}

/// Member roles with hierarchical priority.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MemberRole {
    Owner,
    Admin,
    Member,
}

impl MemberRole {
    /// Numeric priority for CRDT conflict resolution.
    pub fn priority(&self) -> u8 {
        match self {
            Self::Owner => 2,
            Self::Admin => 1,
            Self::Member => 0,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Member => "member",
        }
    }
}
