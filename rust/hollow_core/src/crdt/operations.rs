use base64::Engine as _;
use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;
use crate::identity::native_identity::NativeKeypair;

/// The author's proof that it really wrote this op.
///
/// `sig` is the base64 Ed25519 signature over [`CrdtOp::signing_payload`] and `pk` the
/// base64 protobuf public key it verifies against, whose derived peer_id must equal
/// the op's `author`. Boxed because a `CrdtOp` rides async frames with a tight stack.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrdtAuth {
    pub sig: String,
    pub pk: String,
}

/// Why an op was refused at ingest. Log text only; never shown to a user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpReject {
    /// No `auth` block at all (an unsigned op, or one stripped in transit).
    MissingSignature,
    /// The signing key does not derive the claimed `author` peer_id.
    AuthorMismatch,
    /// The signature does not verify over the op's signing payload.
    BadSignature,
    /// The op's HLC sits further ahead of our wall clock than the drift bound.
    FutureHlc,
    /// The op is for a different server than the state it was handed to.
    WrongServer,
    /// The author lacks the permission this payload requires (`op_allowed`).
    NotAllowed,
}

impl std::fmt::Display for OpReject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::MissingSignature => "no author signature",
            Self::AuthorMismatch => "signing key does not match the author",
            Self::BadSignature => "signature does not verify",
            Self::FutureHlc => "timestamp too far ahead of the wall clock",
            Self::WrongServer => "op belongs to another server",
            Self::NotAllowed => "author lacks permission for this operation",
        };
        f.write_str(s)
    }
}

/// A single CRDT operation — the unit of replication.
///
/// Each op is self-contained and both idempotent and commutative.
///
/// SECURITY: `author` is a claim until `auth` proves it. Every remote ingest path runs
/// `ServerState::admit_remote_op`, which rejects an op with no `auth`, an `auth` whose
/// key derives a different peer_id, or a signature that does not verify. There is no
/// tolerance branch: an `if auth.is_some()` gate would be the bypass.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrdtOp {
    pub server_id: String,
    pub hlc: HlcTimestamp,
    pub author: String,
    pub payload: CrdtPayload,
    /// Author proof. `Option` for wire tolerance only: an op arriving without it parses
    /// and is then rejected with `MissingSignature`, where a parse failure would be
    /// indistinguishable from the unknown payload variants the tolerant parse skips.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<Box<CrdtAuth>>,
}

impl CrdtOp {
    /// Canonical signing payload:
    ///   `hollow-crdt1:{server_id}:{physical_ms}:{counter}:{actor}:{author}:{payload_json}`
    ///
    /// Every field before the payload is colon-free, so the free-form JSON stays LAST and
    /// the layout is unambiguous, the same rule as `hollow-msg2`. Deterministic because
    /// no `CrdtPayload` variant carries a map or a set.
    pub fn signing_payload(&self) -> String {
        let payload_json = serde_json::to_string(&self.payload).unwrap_or_default();
        format!(
            "hollow-crdt1:{}:{}:{}:{}:{}:{}",
            self.server_id,
            self.hlc.physical_ms,
            self.hlc.counter,
            self.hlc.actor,
            self.author,
            payload_json,
        )
    }

    /// Sign this op with the MASTER keypair: `author` and the state's maps are
    /// master-keyed, so a device key would never derive the author id.
    pub fn sign(&mut self, keypair: &NativeKeypair, pk_b64: &str) {
        let sig = keypair.sign(self.signing_payload().as_bytes());
        self.auth = Some(Box::new(CrdtAuth {
            sig: base64::engine::general_purpose::STANDARD.encode(sig),
            pk: pk_b64.to_string(),
        }));
    }

    /// Bind this op to its claimed `author`: the key must derive that peer_id AND the
    /// signature must verify over the signing payload. REJECTS, never logs and continues.
    pub fn verify_author(&self) -> Result<(), OpReject> {
        let auth = self.auth.as_ref().ok_or(OpReject::MissingSignature)?;
        let b64 = base64::engine::general_purpose::STANDARD;
        let pk_bytes = b64.decode(&auth.pk).map_err(|_| OpReject::AuthorMismatch)?;
        let derived = NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes)
            .ok_or(OpReject::AuthorMismatch)?;
        if derived != self.author {
            return Err(OpReject::AuthorMismatch);
        }
        let sig_bytes = b64.decode(&auth.sig).map_err(|_| OpReject::BadSignature)?;
        match NativeKeypair::verify_peer_signature(
            &pk_bytes,
            &sig_bytes,
            self.signing_payload().as_bytes(),
        ) {
            Ok(true) => Ok(()),
            _ => Err(OpReject::BadSignature),
        }
    }
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
    /// Server deletion tombstone, owner-authored only (validated at ingest). Marks the
    /// state `deleted` and drains membership, but survives in the op_log so reconnecting
    /// members reconcile through ordinary grow-only sync.
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

    // Labels — cosmetic roles (Phase 6.75); `access` labels additionally gate
    // channels (issue #32) and are never self-assignable.
    LabelCreated {
        label_id: String,
        name: String,
        color: String,
        #[serde(default)]
        access: bool,
    },
    LabelDeleted {
        label_id: String,
    },
    /// `access: None` = preserve the stored flag — a client that predates the
    /// field must not silently strip access-status off a label (that would
    /// re-open self-assignment on a security boundary).
    LabelUpdated {
        label_id: String,
        name: String,
        color: String,
        #[serde(default)]
        access: Option<bool>,
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
    /// Label-gated visibility (issue #32): non-empty means only holders of a listed
    /// label (plus Admin+/Owner) see the channel, empty is back to the tier ladder.
    /// Authored paired with an admin visibility stamp so older clients still hide it.
    ChannelVisibilityLabelsChanged {
        channel_id: String,
        labels: Vec<String>,
    },
    /// Label-gated posting; same semantics as the visibility twin.
    ChannelPostingLabelsChanged {
        channel_id: String,
        labels: Vec<String>,
    },
    /// Time-boxed per-member channel access (visibility + posting).
    /// `expires_at` = epoch ms; `u64::MAX` = until revoked. LWW per
    /// (channel, member), mirroring MemberMuted.
    ChannelGrantSet {
        channel_id: String,
        peer_id: String,
        expires_at: u64,
    },
    ChannelGrantRevoked {
        channel_id: String,
        peer_id: String,
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
    /// Add (or replace, same name) a custom emote. The CRDT carries METADATA ONLY:
    /// `hash` addresses the processed WebP and the bytes replicate on demand,
    /// content-addressed and receiver-verified.
    EmojiAdded {
        name: String,
        hash: String,
        animated: bool,
    },
    EmojiRemoved {
        name: String,
    },

    // Sticker packs (server sticker set)
    /// Add (or replace, same hash) a sticker in the server's set, METADATA ONLY like
    /// emotes.
    ///
    /// Keyed by HASH, not name: a sticker is picked visually, so its name is a label two
    /// stickers may share. `pack` groups them in the picker and `w`/`h` let it reserve
    /// the right cell before any bytes arrive.
    StickerAdded {
        hash: String,
        name: String,
        pack: String,
        animated: bool,
        w: u32,
        h: u32,
    },
    StickerRemoved {
        hash: String,
    },
}

/// Tolerant sync-batch parse: each op deserializes INDIVIDUALLY, so a batch carrying a
/// NEWER client's payload variant skips just that op instead of poisoning the whole
/// Vec, which permanently wedged older clients' server sync.
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
    /// Numeric role rank, higher = more authority. Used for outranking checks and
    /// carried on RoleChanged as wire-compat metadata the merge no longer consults.
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
            Self::Admin => Permission::MANAGE_SERVER
                | Permission::MANAGE_CHANNELS
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
                access: true,
            },
            auth: None,
        };
        let json = serde_json::to_string(&op).unwrap();
        let deserialized: CrdtOp = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.server_id, "srv-1");
        assert_eq!(deserialized.author, "peer_a");
        match &deserialized.payload {
            CrdtPayload::LabelCreated { label_id, name, color, access } => {
                assert_eq!(label_id, "lbl-1");
                assert_eq!(name, "VIP");
                assert_eq!(color, "#ff0000");
                assert!(access);
            }
            _ => panic!("Wrong payload variant after deserialization"),
        }
    }

    fn signed_op(tag: u8, payload: CrdtPayload) -> CrdtOp {
        let (kp, id, pk) = crate::crdt::testkeys::keys(tag);
        let mut op = CrdtOp {
            server_id: "srv-1".into(),
            hlc: HlcTimestamp { physical_ms: 1000, counter: 0, actor: id.clone() },
            author: id,
            payload,
            auth: None,
        };
        op.sign(&kp, &pk);
        op
    }

    #[test]
    fn signed_op_verifies_and_survives_the_wire() {
        let op = signed_op(1, CrdtPayload::ServerRenamed { new_name: "Fine".into() });
        assert!(op.verify_author().is_ok());
        let json = serde_json::to_string(&op).unwrap();
        let back: CrdtOp = serde_json::from_str(&json).unwrap();
        assert!(back.verify_author().is_ok(), "the signature must survive a serde round trip");
    }

    /// Every field in the signing payload is covered: changing any one of
    /// them invalidates the signature.
    #[test]
    fn signature_covers_every_field_of_the_op() {
        let base = signed_op(1, CrdtPayload::ServerRenamed { new_name: "Fine".into() });

        let mut renamed = base.clone();
        renamed.payload = CrdtPayload::ServerRenamed { new_name: "PWNED".into() };
        assert_eq!(renamed.verify_author(), Err(OpReject::BadSignature));

        let mut moved = base.clone();
        moved.server_id = "srv-2".into();
        assert_eq!(moved.verify_author(), Err(OpReject::BadSignature));

        let mut future = base.clone();
        future.hlc.physical_ms = u64::MAX;
        assert_eq!(future.verify_author(), Err(OpReject::BadSignature));

        let mut counted = base.clone();
        counted.hlc.counter += 1;
        assert_eq!(counted.verify_author(), Err(OpReject::BadSignature));

        let mut reactored = base.clone();
        reactored.hlc.actor = "someone-else".into();
        assert_eq!(reactored.verify_author(), Err(OpReject::BadSignature));

        // A different author string no longer matches the key at all.
        let mut reauthored = base.clone();
        reauthored.author = "someone-else".into();
        assert_eq!(reauthored.verify_author(), Err(OpReject::AuthorMismatch));
    }

    /// Swapping in another peer's key does not launder the op: the key must
    /// derive the author, and the signature must be over THIS payload.
    #[test]
    fn a_foreign_key_cannot_stand_in_for_the_author() {
        let mine = signed_op(1, CrdtPayload::ServerRenamed { new_name: "Fine".into() });
        let (_, _, other_pk) = crate::crdt::testkeys::keys(2);
        let mut swapped = mine.clone();
        swapped.auth = Some(Box::new(CrdtAuth {
            sig: mine.auth.as_ref().unwrap().sig.clone(),
            pk: other_pk,
        }));
        assert_eq!(swapped.verify_author(), Err(OpReject::AuthorMismatch));
    }

    #[test]
    fn unsigned_op_is_missing_signature() {
        let op = CrdtOp {
            server_id: "srv-1".into(),
            hlc: HlcTimestamp { physical_ms: 1000, counter: 0, actor: "a".into() },
            author: "a".into(),
            payload: CrdtPayload::ServerRenamed { new_name: "x".into() },
            auth: None,
        };
        assert_eq!(op.verify_author(), Err(OpReject::MissingSignature));
        // …and an op serialized before signatures existed parses into exactly
        // that shape, rather than failing the tolerant batch parse.
        let legacy = r#"[{"server_id":"srv-1","hlc":{"physical_ms":1,"counter":0,"actor":"a"},"author":"a","payload":{"ServerRenamed":{"new_name":"x"}}}]"#;
        let ops = parse_ops_tolerant(legacy);
        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].verify_author(), Err(OpReject::MissingSignature));
    }

    /// Old-client wire compat: label ops WITHOUT the `access` field parse
    /// with the safe defaults (Created → false, Updated → None = preserve).
    #[test]
    fn label_ops_missing_access_field_default() {
        let created: CrdtPayload = serde_json::from_str(
            r##"{"LabelCreated":{"label_id":"l1","name":"VIP","color":"#fff"}}"##,
        ).unwrap();
        match created {
            CrdtPayload::LabelCreated { access, .. } => assert!(!access),
            _ => panic!("wrong variant"),
        }
        let updated: CrdtPayload = serde_json::from_str(
            r##"{"LabelUpdated":{"label_id":"l1","name":"VIP","color":"#fff"}}"##,
        ).unwrap();
        match updated {
            CrdtPayload::LabelUpdated { access, .. } => assert_eq!(access, None),
            _ => panic!("wrong variant"),
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
