//! Asset kinds for the content-addressed blob rail; the transport is `node/emotes.rs`.
//!
//! Kinds differ only in their size cap and request bounds. The kind is LOCAL
//! bookkeeping recorded when WE request a hash, never carried on the wire, so a
//! sender can never talk us into a bigger cap than the kind we asked for allows.

/// What a content-addressed blob is used as. Determines the size cap
/// enforced on receipt and the per-request hash bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum AssetKind {
    Emote,
    Banner,
    Sticker,
    Gif,
    /// Animated server icon (`settings["server_avatar_anim"]` hash); the still
    /// icon stays base64 in `server_avatar` for old clients and the guest thumb.
    Avatar,
    /// Avatar frame (#54): the profile carries only the hash, the bytes ride the
    /// rail, because a profile push reaches everyone who syncs with you while the
    /// rail is pulled on demand and LRU-evicted.
    Frame,
    /// A person's animated avatar or banner; one kind for both because they share
    /// a replication profile, hence a budget, and no bound here tells them apart.
    /// The still companion stays base64 in the pushed profile.
    Profile,
}

impl AssetKind {
    /// The `emote_blobs.kind` column value.
    pub(crate) fn db_kind(self) -> &'static str {
        match self {
            AssetKind::Emote => "emote",
            AssetKind::Banner => "banner",
            AssetKind::Sticker => "sticker",
            AssetKind::Gif => "gif",
            AssetKind::Avatar => "avatar",
            AssetKind::Frame => "frame",
            AssetKind::Profile => "profile",
        }
    }

    pub(crate) fn from_db_kind(s: &str) -> Option<Self> {
        match s {
            "emote" => Some(AssetKind::Emote),
            "banner" => Some(AssetKind::Banner),
            "sticker" => Some(AssetKind::Sticker),
            "gif" => Some(AssetKind::Gif),
            "avatar" => Some(AssetKind::Avatar),
            "frame" => Some(AssetKind::Frame),
            "profile" => Some(AssetKind::Profile),
            _ => None,
        }
    }

    /// Hard cap on one blob of this kind accepted from the wire. The cap comes
    /// from the kind WE recorded when requesting the hash, never from anything the
    /// sender supplies, else a peer could push at the largest cap by mislabeling.
    ///
    /// Banner uses its animated ceiling; the tighter still limit is authoring-side.
    pub(crate) fn recv_cap(self) -> usize {
        match self {
            AssetKind::Emote => 262_144,      // 256 KB (animated ceiling)
            AssetKind::Banner => 1_048_576,   // 1 MB animated / 256 KB still
            AssetKind::Sticker => 524_288,    // 512 KB
            AssetKind::Gif => 2_097_152,      // 2 MB
            AssetKind::Avatar => 524_288,     // 512 KB (128px animated icon)
            // == `image_convert::MAX_FRAME_ANIMATED_BYTES`, pinned by a test, and
            // below the profile rail: a frame decorates every avatar you have seen.
            AssetKind::Frame => 1024 * 1024,  // 1 MB (256 KB still)
            // == `image_convert::MAX_PROFILE_ANIM_BYTES`, pinned by a test: the wire
            // cap IS the authoring limit, so the two cannot drift apart.
            AssetKind::Profile => 2 * 1024 * 1024, // 2 MB
        }
    }

    /// Max hashes per outbound request of this kind: `hashes x recv_cap` stays
    /// within [`MAX_BUNDLE_REPLY_BYTES`] for every kind.
    pub(crate) fn max_request_hashes(self) -> usize {
        match self {
            AssetKind::Emote => 20,
            AssetKind::Banner => 2,
            AssetKind::Sticker => 8,
            AssetKind::Gif => 4,
            AssetKind::Avatar => 4,
            AssetKind::Frame => 4,
            AssetKind::Profile => 4,
        }
    }
}

/// Responder-side budget for one `EmoteAssets` reply bundle (raw bytes, before
/// base64). `emotes::handle_emote_request` admits a bundle landing EXACTLY here:
/// a 4-hash Profile request is 8 MB on the nose, so an off-by-one would drop the
/// fourth asset of every full profile-media pull.
pub(crate) const MAX_BUNDLE_REPLY_BYTES: usize = 8 * 1024 * 1024;

/// 400x133 still thumbnail of a server's banner for the public-browse wire path.
/// Opens a fresh store handle, so guest-browse paths only, never a hot loop.
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
