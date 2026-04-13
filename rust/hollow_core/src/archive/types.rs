use serde::{Deserialize, Serialize};

/// Current archive format version.
pub(crate) const ARCHIVE_FORMAT_VERSION: u32 = 1;

/// What to export.
pub(crate) enum ArchiveTarget {
    Dm {
        peer_id: String,
    },
    Channel {
        server_id: String,
        channel_id: String,
        channel_name: Option<String>,
    },
    Server {
        server_id: String,
        server_name: String,
        channels: Vec<(String, String)>, // (channel_id, channel_name)
    },
}

/// Channel info entry for multi-channel (server) archives.
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ArchiveChannelInfo {
    pub channel_id: String,
    pub channel_name: String,
    pub message_count: u32,
}

/// File attachment inclusion mode.
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum FileMode {
    Full,
    ImagesOnly,
    Placeholder,
}

impl FileMode {
    pub fn from_str(s: &str) -> Self {
        match s {
            "full" => FileMode::Full,
            "images_only" => FileMode::ImagesOnly,
            _ => FileMode::Placeholder,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            FileMode::Full => "full",
            FileMode::ImagesOnly => "images_only",
            FileMode::Placeholder => "placeholder",
        }
    }
}

// ── Zip-level structures ────────────────────────────────────────

/// Top-level archive metadata (`manifest.json`).
#[derive(Serialize, Deserialize)]
pub(crate) struct ArchiveManifest {
    pub format_version: u32,
    pub archive_type: String, // "dm", "channel", or "server"
    pub exporter_peer_id: String,
    pub export_timestamp: i64, // millis since epoch
    pub message_count: u32,
    pub file_mode: String, // "full" / "images_only" / "placeholder"
    // DM-specific
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peer_id: Option<String>,
    // Channel-specific
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_name: Option<String>,
    // Server-specific (multi-channel)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_name: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub channels: Vec<ArchiveChannelInfo>,
    /// All unique sender peer_ids in the conversation.
    pub participants: Vec<String>,
}

/// A single message (`messages/{message_id}.json`).
#[derive(Serialize, Deserialize)]
pub(crate) struct ArchiveMessage {
    pub message_id: String,
    pub sender_id: String,
    pub text: String,
    pub timestamp: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hidden_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_to_mid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    /// Channel ID — populated only in server (multi-channel) archives.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<ArchiveReaction>,
}

/// A reaction attached to a message (inline in `ArchiveMessage`).
#[derive(Serialize, Deserialize)]
pub(crate) struct ArchiveReaction {
    pub emoji: String,
    pub peer_id: String,
    pub added_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
}

/// An edit history entry (`edits/{message_id}.json` — array per message).
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ArchiveEdit {
    pub message_id: String,
    pub old_text: String,
    pub new_text: String,
    pub edited_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prev_signature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prev_public_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prev_timestamp: Option<i64>,
}

/// Deletion evidence (`deletions/{message_id}.json`).
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ArchiveDeletion {
    pub message_id: String,
    pub deleted_text: String,
    pub deleted_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
}

/// Reaction removal evidence (`reaction_removals/{message_id}.json` — array per message).
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ArchiveReactionRemoval {
    pub message_id: String,
    pub emoji: String,
    pub peer_id: String,
    pub removed_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
}

/// File metadata (`files/{file_id}.meta.json`).
#[derive(Serialize, Deserialize)]
pub(crate) struct ArchiveFileMetadata {
    pub file_id: String,
    pub file_name: String,
    pub file_ext: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub is_image: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    /// SHA-256 hex of the file bytes (only present when file is included).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    /// Whether actual file bytes are included in this archive.
    pub included: bool,
}

/// Public key entry (`pubkeys.json` — array).
#[derive(Serialize, Deserialize)]
pub(crate) struct ArchivePubKey {
    pub peer_id: String,
    pub public_key_b64: String,
}

/// Archive-level signature (`archive_signature.json`).
#[derive(Serialize, Deserialize)]
pub(crate) struct ArchiveSignature {
    pub exporter_peer_id: String,
    pub signature_b64: String,
    pub public_key_b64: String,
    /// SHA-256 hex of the canonical archive content.
    pub content_hash_hex: String,
}

// ── Loader result types ─────────────────────────────────────────

/// Per-message verification result.
pub(crate) struct MessageVerification {
    pub message_id: String,
    pub has_signature: bool,
    pub signature_valid: bool,
}

/// Full result of loading an archive.
pub(crate) struct LoadedArchive {
    pub manifest: ArchiveManifest,
    pub messages: Vec<ArchiveMessage>,
    pub edits: Vec<ArchiveEdit>,
    pub deletions: Vec<ArchiveDeletion>,
    pub reaction_removals: Vec<ArchiveReactionRemoval>,
    pub pubkeys: Vec<ArchivePubKey>,
    pub file_metadata: Vec<ArchiveFileMetadata>,
    /// Path to temp directory containing extracted file bytes (if any).
    pub files_dir: Option<String>,
    pub archive_signature_valid: bool,
    pub per_message_results: Vec<MessageVerification>,
}

/// Quick-verify summary result.
pub(crate) struct VerifyResult {
    pub archive_type: String,
    pub exporter_peer_id: String,
    pub export_timestamp: i64,
    pub message_count: u32,
    pub archive_signature_valid: bool,
    pub messages_with_valid_sig: u32,
    pub messages_with_invalid_sig: u32,
    pub messages_without_sig: u32,
    pub participant_ids: Vec<String>,
    // DM
    pub peer_id: Option<String>,
    // Channel
    pub server_id: Option<String>,
    pub channel_id: Option<String>,
    pub channel_name: Option<String>,
    // Server (multi-channel)
    pub server_name: Option<String>,
    pub channels: Vec<ArchiveChannelInfo>,
}
