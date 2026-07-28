//! Generalized asset kinds for the content-addressed blob rail.
//!
//! The emote byte-replication system (`node/emotes.rs`) is the transport:
//! `EmoteRequest` / `EmoteAssets` move (hash → bytes) pairs verified by
//! content addressing. Everything that rides it — emotes, server banners,
//! stickers, GIFs — differs ONLY in its size cap and request bounds, which
//! live here. The kind is a LOCAL bookkeeping fact (recorded when WE request
//! a hash, stored in the `kind` column of `emote_blobs`); it never rides the
//! wire, so a sender can never talk us into a bigger cap than the kind we
//! asked for allows.

/// What a content-addressed blob is used as. Determines the size cap
/// enforced on receipt and the per-request hash bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum AssetKind {
    Emote,
    Banner,
    Sticker,
    Gif,
}

impl AssetKind {
    /// The `emote_blobs.kind` column value.
    pub(crate) fn db_kind(self) -> &'static str {
        match self {
            AssetKind::Emote => "emote",
            AssetKind::Banner => "banner",
            AssetKind::Sticker => "sticker",
            AssetKind::Gif => "gif",
        }
    }

    pub(crate) fn from_db_kind(s: &str) -> Option<Self> {
        match s {
            "emote" => Some(AssetKind::Emote),
            "banner" => Some(AssetKind::Banner),
            "sticker" => Some(AssetKind::Sticker),
            "gif" => Some(AssetKind::Gif),
            _ => None,
        }
    }

    /// Hard cap on a single blob of this kind accepted from the wire. The
    /// cap comes from the kind WE recorded when requesting the hash — never
    /// from anything the sender supplies (else every peer could push blobs
    /// at the largest cap by mislabeling them).
    ///
    /// Banner uses its animated ceiling here; the tighter still-banner limit
    /// is an authoring-side rule (`process_server_banner_image`).
    pub(crate) fn recv_cap(self) -> usize {
        match self {
            AssetKind::Emote => 262_144,      // 256 KB (animated ceiling)
            AssetKind::Banner => 1_048_576,   // 1 MB animated / 256 KB still
            AssetKind::Sticker => 524_288,    // 512 KB
            AssetKind::Gif => 2_097_152,      // 2 MB
        }
    }

    /// Max hashes per outbound request of this kind, so one reply bundle
    /// stays bounded (hashes × recv_cap ≤ ~8 MB for every kind).
    pub(crate) fn max_request_hashes(self) -> usize {
        match self {
            AssetKind::Emote => 20,
            AssetKind::Banner => 2,
            AssetKind::Sticker => 8,
            AssetKind::Gif => 4,
        }
    }
}

/// Responder-side budget for one `EmoteAssets` reply bundle (raw bytes,
/// before base64). Bounds the reply even when a request names many hashes
/// of blobs we happen to hold at larger kinds' sizes.
pub(crate) const MAX_BUNDLE_REPLY_BYTES: usize = 8 * 1024 * 1024;

/// 400x133 still thumbnail of a server's banner for the public-browse wire
/// path, if the server has a banner AND we hold its blob. Opens a fresh
/// store handle — call only on the rare guest-browse paths, never in a hot
/// loop (same trade the guest sync responder already makes).
pub(crate) fn public_banner_thumb(
    state: &crate::crdt::server_state::ServerState,
    db_path: &str,
    db_passphrase: &str,
) -> Option<Vec<u8>> {
    let hash = state.settings.get("server_banner").map(|reg| reg.read().clone())?;
    if !crate::crdt::valid_emote_hash(&hash) {
        return None;
    }
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let bytes = store.load_emote_blob(&hash).ok().flatten()?;
    super::image_convert::process_server_banner_thumb(&bytes).ok()
}
