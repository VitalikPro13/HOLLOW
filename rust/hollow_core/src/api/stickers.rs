//! Stickers — the personal vault, server sticker packs, and the KLIPY
//! sticker catalog.
//!
//! Stickers ride the SAME rails everything else in the asset epic does, so
//! this module is mostly plumbing:
//!
//!   * BYTES: content-addressed WebP in `emote_blobs` at `kind='sticker'`,
//!     replicated on demand by `node/emotes.rs` under
//!     `AssetKind::Sticker` (512 KB receipt cap, 8 hashes per request).
//!     Nothing here ever puts sticker bytes on the wire.
//!   * METADATA: a server's set is CRDT state (`ServerState.stickers`, keyed
//!     by hash, `MANAGE_EMOTES`); the personal vault is a local SQLCipher
//!     table (`personal_stickers`) grouped into free-form packs.
//!   * MESSAGES: the composer writes `[a:s:hash:w:h]`, which is an ordinary
//!     run of message text — no new message-row path, no signing/order_us/
//!     sync change. That is the whole reason this phase is cheap.
//!   * CATALOG: KLIPY sticker search is the same two-mode client as GIFs
//!     (`api/gifs.rs`, [MediaKind::Sticker]) — proxy by default, the user's
//!     own key optional. Authoring-time only: the moment a sticker is picked
//!     it becomes a local blob and replicates P2P, so message RECEIVERS make
//!     zero HTTP requests, ever.
//!
//! Sticker identity is the HASH, not the name. An emote is typed as `:name:`
//! so its name has to be unique; a sticker is only ever picked visually, so
//! its name is a label and two stickers may share one.

use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

use super::gifs::{self, GifPage, MediaKind, StoredGif};
use super::network::{get_node, get_runtime};
use super::storage::get_store;
use crate::crdt::server_state::{MAX_SERVER_STICKERS, MAX_STICKER_LABEL, valid_sticker_label};
use crate::node;

/// Max packs in the personal vault, and stickers in one pack. Generous
/// enough for real multi-part packs (a 5x5 mosaic is 25 pieces) while
/// keeping the whole vault bounded — every row pins a blob against the asset
/// cache LRU, so this ceiling is a disk commitment.
const MAX_PERSONAL_PACKS: usize = 50;
const MAX_STICKERS_PER_PACK: usize = 120;
const MAX_PERSONAL_STICKERS: u32 = 600;

/// A processed sticker cached locally, ready to register in a pack or send.
/// `w`/`h` feed the `[a:s:hash:w:h]` token.
pub struct ProcessedSticker {
    pub hash: String,
    pub animated: bool,
    pub w: u32,
    pub h: u32,
}

/// One sticker of the user's personal vault.
pub struct PersonalSticker {
    /// Free-form group name; `""` is the default (ungrouped) pack.
    pub pack: String,
    pub hash: String,
    pub name: String,
    pub animated: bool,
    pub w: u32,
    pub h: u32,
    /// `"upload"` | `"klipy:<id>"` — provenance only, never fetched at
    /// display time.
    pub source: String,
}

/// One sticker of a server's CRDT-replicated set.
pub struct ServerSticker {
    pub hash: String,
    pub name: String,
    pub pack: String,
    pub animated: bool,
    pub w: u32,
    pub h: u32,
}

/// Wire token for a sticker, as inserted into message text.
#[frb(sync)]
pub fn sticker_token(hash: String, w: u32, h: u32) -> String {
    format!("[a:s:{hash}:{w}:{h}]")
}

/// The authoring caps Dart should enforce in its own UI copy, rather than
/// mirroring the numbers (same rule as `default_role_permissions`):
/// `[per server, per pack, packs, vault total, label chars]`.
#[frb(sync)]
pub fn sticker_limits() -> Vec<u32> {
    vec![
        MAX_SERVER_STICKERS as u32,
        MAX_STICKERS_PER_PACK as u32,
        MAX_PERSONAL_PACKS as u32,
        MAX_PERSONAL_STICKERS,
        MAX_STICKER_LABEL as u32,
    ]
}

// ── Local processing ──────────────────────────────────────────────────

/// Process a user-picked image (PNG/JPG/WebP/GIF, still or animated) into a
/// sticker blob and cache it locally. Re-encoding here IS the sanitization
/// step — the same argument emotes and GIFs make. Caller then registers it
/// via [add_personal_sticker] or [add_server_sticker].
#[frb]
pub fn process_and_store_sticker(raw_bytes: Vec<u8>) -> Result<ProcessedSticker, String> {
    let (bytes, w, h, animated) =
        crate::node::image_convert::process_sticker_for_send(&raw_bytes)?;
    let hash = hex::encode(Sha256::digest(&bytes));
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.save_asset_blob(&hash, &bytes, animated, "sticker")?;
    Ok(ProcessedSticker { hash, animated, w, h })
}

// ── Personal vault ────────────────────────────────────────────────────

fn clean_label(raw: &str) -> Result<String, String> {
    let s = raw.trim().to_string();
    if !valid_sticker_label(&s) {
        return Err(format!("Names are up to {MAX_STICKER_LABEL} characters"));
    }
    Ok(s)
}

#[frb]
pub fn add_personal_sticker(
    pack: String,
    hash: String,
    name: String,
    animated: bool,
    w: u32,
    h: u32,
    source: String,
) -> Result<(), String> {
    let pack = clean_label(&pack)?;
    let name = clean_label(&name)?;
    if !crate::crdt::valid_emote_hash(&hash) {
        return Err("Invalid sticker hash".into());
    }
    if !(1..=4096).contains(&w) || !(1..=4096).contains(&h) {
        return Err("Invalid sticker dimensions".into());
    }
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    if !ms.has_emote_blob(&hash)? {
        return Err("Sticker image is not cached locally".into());
    }
    // Caps checked against the CURRENT vault, and only for genuinely new
    // rows — re-adding an existing (pack, hash) is a metadata edit and must
    // never be refused for being over a limit it did not push us past.
    let existing = ms.list_personal_stickers()?;
    let is_new = !existing
        .iter()
        .any(|r| r.pack == pack && r.hash == hash);
    if is_new {
        if ms.personal_sticker_count()? >= MAX_PERSONAL_STICKERS {
            return Err(format!(
                "Sticker vault is full ({MAX_PERSONAL_STICKERS} stickers)"
            ));
        }
        if existing.iter().filter(|r| r.pack == pack).count() >= MAX_STICKERS_PER_PACK {
            return Err(format!(
                "That pack is full ({MAX_STICKERS_PER_PACK} stickers)"
            ));
        }
        let packs: std::collections::HashSet<&String> =
            existing.iter().map(|r| &r.pack).collect();
        if !packs.contains(&pack) && packs.len() >= MAX_PERSONAL_PACKS {
            return Err(format!("Pack limit reached ({MAX_PERSONAL_PACKS})"));
        }
    }
    ms.add_personal_sticker(&crate::storage::PersonalStickerRow {
        pack,
        hash,
        name,
        animated,
        w,
        h,
        source,
        added_at: 0, // stamped by the store
    })
}

#[frb]
pub fn remove_personal_sticker(pack: String, hash: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.remove_personal_sticker(pack.trim(), &hash)
}

/// Delete a whole pack. The blobs stay cached — they are content-addressed
/// and a message you already sent still points at them; the asset LRU
/// reclaims them once nothing references them.
#[frb]
pub fn remove_personal_sticker_pack(pack: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.remove_personal_sticker_pack(pack.trim())
}

/// Rename a pack. Renaming onto an existing pack MERGES into it (rows there
/// with the same hash win) rather than failing.
#[frb]
pub fn rename_personal_sticker_pack(from: String, to: String) -> Result<(), String> {
    let to = clean_label(&to)?;
    let from = from.trim().to_string();
    if from == to {
        return Ok(());
    }
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.rename_personal_sticker_pack(&from, &to)
}

/// The whole vault, pack-major and oldest-first inside each pack — upload
/// order IS pack order, which is what makes a multi-part pack readable.
#[frb]
pub fn list_personal_stickers() -> Result<Vec<PersonalSticker>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms
        .list_personal_stickers()?
        .into_iter()
        .map(|r| PersonalSticker {
            pack: r.pack,
            hash: r.hash,
            name: r.name,
            animated: r.animated,
            w: r.w,
            h: r.h,
            source: r.source,
        })
        .collect())
}

// ── Server sticker packs (CRDT) ───────────────────────────────────────

/// A server's sticker set (replicated metadata; bytes pulled separately by
/// hash over the asset rail).
#[frb]
pub fn get_server_stickers(server_id: String) -> Result<Vec<ServerSticker>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let state_json = ms.load_server_state(&server_id)?.ok_or("Server not found")?;
    let state = serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
        .map_err(|e| format!("Failed to parse server state: {e}"))?;
    Ok(state
        .stickers_list()
        .into_iter()
        .map(|s| ServerSticker {
            hash: s.hash.clone(),
            name: s.name.clone(),
            pack: s.pack.clone(),
            animated: s.animated,
            w: s.w,
            h: s.h,
        })
        .collect())
}

/// Add (or re-label) a sticker in a server's set — `MANAGE_EMOTES`, the same
/// permission as emotes. The blob must already be cached locally so this
/// node can serve members' pull requests.
#[frb]
pub fn add_server_sticker(
    server_id: String,
    hash: String,
    name: String,
    pack: String,
    animated: bool,
    w: u32,
    h: u32,
) -> Result<(), String> {
    let name = clean_label(&name)?;
    let pack = clean_label(&pack)?;
    if !crate::crdt::valid_emote_hash(&hash) {
        return Err("Invalid sticker hash".into());
    }
    if !(1..=4096).contains(&w) || !(1..=4096).contains(&h) {
        return Err("Invalid sticker dimensions".into());
    }
    {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        if !ms.has_emote_blob(&hash)? {
            return Err("Sticker image is not cached locally".into());
        }
    }
    send_command(node::NodeCommand::AddServerSticker {
        server_id,
        hash,
        name,
        pack,
        animated,
        w,
        h,
    })
}

#[frb]
pub fn remove_server_sticker(server_id: String, hash: String) -> Result<(), String> {
    send_command(node::NodeCommand::RemoveServerSticker { server_id, hash })
}

fn send_command(cmd: node::NodeCommand) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    get_runtime()
        .block_on(cmd_tx.send(cmd))
        .map_err(|e| format!("Failed to send command: {e}"))
}

// ── KLIPY sticker catalog (authoring-time only) ───────────────────────
//
// Thin wrappers over the shared two-mode client in `api/gifs.rs`. Every
// guard there applies unchanged: the proxy-origin prefix check, the
// direct-mode media host allowlist, the random per-request customer_id, the
// blocked-host memory the settings card surfaces, and the dedicated HTTP
// runtime (`get_http_runtime` — never the node runtime, whose blocking pool
// SQLCipher bursts saturate).

/// Search KLIPY stickers. `rating` is one of `gif_ratings()`.
#[frb]
pub fn sticker_search(query: String, page: u32, rating: String) -> Result<GifPage, String> {
    gifs::media_search(MediaKind::Sticker, query, page, rating)
}

/// Trending KLIPY stickers — the catalog tab's default view.
#[frb]
pub fn sticker_trending(page: u32, rating: String) -> Result<GifPage, String> {
    gifs::media_page(
        MediaKind::Sticker,
        None,
        page,
        &gifs::normalized_rating_for(&rating),
    )
}

/// Sticker category names, if the provider offers any.
#[frb]
pub fn sticker_categories() -> Result<Vec<String>, String> {
    gifs::media_categories(MediaKind::Sticker)
}

/// Download a picked KLIPY sticker, re-encode it into the ≤512px/≤512 KB
/// send format, and cache it as a `kind='sticker'` asset blob. Feed
/// hash/w/h into [sticker_token].
///
/// Same fetcher discipline as GIFs: proxy mode ignores `source_url` and
/// builds `{base}f/{id}` itself; direct mode resolves the variants our own
/// parse registered, falling back to `source_url` only on a registry miss
/// and only through the media host allowlist.
#[frb]
pub fn sticker_fetch_and_store(
    id: String,
    source_url: Option<String>,
) -> Result<StoredGif, String> {
    gifs::media_fetch_and_store(MediaKind::Sticker, id, source_url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sticker_token_shape() {
        let h = "b".repeat(64);
        assert_eq!(
            sticker_token(h.clone(), 512, 480),
            format!("[a:s:{h}:512:480]")
        );
        // Round-trips through the Rust wire parser (which Dart mirrors).
        let token = sticker_token(h.clone(), 512, 480);
        let parsed = crate::node::emotes::parse_asset_token(&token);
        assert_eq!(
            parsed,
            Some((node::assets::AssetKind::Sticker, h.as_str(), 512, 480))
        );
    }

    #[test]
    fn labels_are_bounded_and_trimmed() {
        assert_eq!(clean_label("  autumn pack  ").unwrap(), "autumn pack");
        assert_eq!(clean_label("").unwrap(), "");
        assert!(clean_label(&"x".repeat(MAX_STICKER_LABEL)).is_ok());
        assert!(clean_label(&"x".repeat(MAX_STICKER_LABEL + 1)).is_err());
        // Control characters would break single-line rendering everywhere.
        assert!(clean_label("two\nlines").is_err());
    }

    #[test]
    fn limits_are_reported_in_a_stable_order() {
        let l = sticker_limits();
        assert_eq!(l.len(), 5);
        assert_eq!(l[0], MAX_SERVER_STICKERS as u32);
        assert_eq!(l[4], MAX_STICKER_LABEL as u32);
    }
}
