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
    /// Animated server icon (`settings["server_avatar_anim"]` hash). The
    /// still icon stays base64 inside `server_avatar` for old clients and
    /// the public-sync thumb; only the animated variant rides the rail.
    Avatar,
    /// Avatar frame (issue #54): the decoration painted IN FRONT of a
    /// person's avatar. `UserProfile.avatar_frame` carries only the hash —
    /// the bytes ride the rail, never `ProfileUpdate`, because a profile
    /// update is PUSHED to everyone who syncs with you while the rail is
    /// PULLED on demand and LRU-evicted. Decoration must be the first thing
    /// evicted, never something that inflates every profile push.
    Frame,
    /// A person's ANIMATED avatar or banner. Both share one kind on purpose:
    /// they share a replication profile (one of each per person you have ever
    /// met), so they share a budget, and nothing here needs to tell them
    /// apart — the cap, the request bound and storage accounting are all
    /// blind to which of the two a blob is.
    ///
    /// The STILL companion stays base64 inside the pushed profile (old
    /// clients and the guest thumb read it); only the animated variant rides
    /// the pulled rail, the same split `server_avatar_anim` already makes for
    /// server icons.
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
            AssetKind::Avatar => 524_288,     // 512 KB (128px animated icon)
            // == `image_convert::MAX_FRAME_ANIMATED_BYTES`, by the same rule
            // Profile follows below, and pinned by the same shape of test.
            // Still below the profile rail's 2 MB on purpose: a frame is
            // decoration on every avatar you have ever seen.
            AssetKind::Frame => 1024 * 1024,  // 1 MB (256 KB still)
            // == `image_convert::MAX_PROFILE_ANIM_BYTES`, and that equality is
            // a rule, not a coincidence: the wire cap IS the authoring limit,
            // so the two can never drift into "we encode what nobody will
            // accept". A test pins it.
            AssetKind::Profile => 2 * 1024 * 1024, // 2 MB
        }
    }

    /// Max hashes per outbound request of this kind, so one reply bundle stays
    /// bounded: `hashes × recv_cap` is at most [`MAX_BUNDLE_REPLY_BYTES`] for
    /// every kind, and exactly that for Gif and Profile (4 × 2 MB = 8 MB).
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

/// Responder-side budget for one `EmoteAssets` reply bundle (raw bytes,
/// before base64). Bounds the reply even when a request names many hashes
/// of blobs we happen to hold at larger kinds' sizes.
///
/// The comparison in `emotes::handle_emote_request` admits a bundle that lands
/// EXACTLY here, which matters: a 4-hash Profile request is 4 × 2 MB = 8 MB on
/// the nose, so an off-by-one there would silently drop the fourth asset of
/// every full profile-media pull. The inbound guard's base64 headroom
/// (`* 4 / 3 + 4096`) covers that bundle's JSON envelope too.
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
