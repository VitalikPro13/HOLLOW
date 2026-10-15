//! Stream overlay (#97): our look and the two toggles (identity-wide, they ride the
//! signed `stream_overlay` field), and the people this device shows (local to this
//! device and profile). Look images live in their own table, read through
//! [`overlay_image_bytes`].

use flutter_rust_bridge::frb;

use super::network::{get_node, get_runtime};
use super::storage::get_store;
use crate::node;

/// One processed look image, kept with the overlay images. It stays while a saved
/// look or local pick names it; an unsaved draft is collected after an hour.
pub struct OverlayImageFfi {
    pub hash: String,
    pub width: u32,
    pub height: u32,
    pub animated: bool,
}

pub struct OverlaySettingsFfi {
    /// "Let others show me on their stream overlay".
    pub allow: bool,
    /// "Share my overlay images".
    pub share: bool,
    /// Our own look, canonical (the default look when none was saved).
    pub own_look_json: String,
}

pub struct OverlayPersonFfi {
    pub master: String,
    /// Stable from 1; OBS links use it.
    pub slot: i64,
    /// "off" | "show" | "share", from their signed field.
    pub field: String,
    /// The look they shared with us, when we hold one.
    pub their_look_json: Option<String>,
    /// Our own picks for them.
    pub local_look_json: Option<String>,
    /// What to draw them with: their look with our picks laid over it.
    pub effective_look_json: String,
}

fn with_store<T>(f: impl FnOnce(&crate::storage::MessageStore) -> Result<T, String>) -> Result<T, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    f(ms)
}

fn local_master() -> Result<String, String> {
    super::network::get_local_peer_id().ok_or_else(|| "Node is not running".to_string())
}

/// Tell the node to look again at whom to ask. A node that is not running reads the
/// store when it starts.
fn refresh_node() {
    let node = get_node();
    let Ok(guard) = node.lock() else { return };
    let Some(cmd_tx) = guard.as_ref().map(|n| n.cmd_tx.clone()) else { return };
    drop(guard);
    let _ = get_runtime().block_on(cmd_tx.send(node::NodeCommand::OverlayRefresh));
}

/// Send a command that replies, and wait for the reply.
fn ask_node<T>(make: impl FnOnce(tokio::sync::oneshot::Sender<Result<T, String>>) -> node::NodeCommand) -> Result<T, String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let (tx, rx) = tokio::sync::oneshot::channel();
    get_runtime().block_on(async move {
        cmd_tx.send(make(tx)).await.map_err(|e| format!("Failed to send command: {e}"))?;
        rx.await.map_err(|_| "The node stopped before answering".to_string())?
    })
}

/// Process a picked image (PNG, JPEG, GIF, WebP, APNG) into a look image and store it.
#[frb]
pub fn overlay_process_image(path: String) -> Result<OverlayImageFfi, String> {
    let len = std::fs::metadata(&path).map_err(|e| format!("Could not read that file: {e}"))?.len();
    if len > 16 * 1024 * 1024 {
        return Err("That image file is too big to convert (16MB max)".into());
    }
    let raw = std::fs::read(&path).map_err(|e| format!("Could not read that file: {e}"))?;
    let (webp, width, height, animated) = node::image_convert::process_overlay_image(&raw)?;
    let hash = with_store(|ms| {
        node::overlay::sweep_images(ms, node::frame_auth::now_ms());
        node::overlay::store_own_image(ms, &webp, animated)
    })?;
    Ok(OverlayImageFfi { hash, width, height, animated })
}

/// The bytes of one stream overlay image (WebP), for previews. Overlay images only:
/// never an emote, sticker or other rail blob.
#[frb]
pub fn overlay_image_bytes(hash: String) -> Option<Vec<u8>> {
    if !crate::crdt::valid_emote_hash(&hash) {
        return None;
    }
    with_store(|ms| ms.load_overlay_blob(&hash)).ok().flatten()
}

#[frb]
pub fn overlay_get_settings() -> Result<OverlaySettingsFfi, String> {
    let me = local_master()?;
    with_store(|ms| {
        let (allow, share) = node::overlay::own_flags(ms, &me);
        let own_look_json = match node::overlay::own_look(ms) {
            Some(look) => look,
            None => node::overlay_look::normalize("{}")?,
        };
        Ok(OverlaySettingsFfi { allow, share, own_look_json })
    })
}

/// Set the two toggles; `allow` off forces `share` off. Re-signs our field and
/// announces it.
#[frb]
pub fn overlay_set_flags(allow: bool, share: bool) -> Result<(), String> {
    ask_node(|reply| node::NodeCommand::OverlaySetFlags { allow, share, reply })
}

/// Save our own look. Returns it canonical, with a newer stamp; re-signs our field
/// and announces it, so our other devices (and, while we share, everyone who added
/// us) pull it.
#[frb]
pub fn overlay_set_own_look(look_json: String) -> Result<String, String> {
    ask_node(|reply| node::NodeCommand::OverlaySetOwnLook { look_json, reply })
}

#[frb]
pub fn overlay_people() -> Result<Vec<OverlayPersonFfi>, String> {
    with_store(|ms| {
        Ok(node::overlay::people(ms)
            .into_iter()
            .map(|p| OverlayPersonFfi {
                master: p.master,
                slot: p.slot,
                field: p.field,
                their_look_json: p.their_look,
                local_look_json: p.local_look,
                effective_look_json: p.effective_look,
            })
            .collect())
    })
}

/// Add a person (by MASTER id) to our overlay; returns their slot. Refused for
/// ourselves, a blocked identity, or anyone whose field says `off`. When their field
/// says `share`, their look is asked for.
#[frb]
pub fn overlay_add_person(master: String) -> Result<i64, String> {
    let me = local_master()?;
    let master = node::resolver::resolve(&master);
    let now = node::frame_auth::now_ms();
    let slot = with_store(|ms| node::overlay::add_person(ms, &me, &master, now))?;
    refresh_node();
    Ok(slot)
}

/// Take a person off our overlay, with their look and our picks for them.
#[frb]
pub fn overlay_remove_person(master: String) -> Result<bool, String> {
    let master = node::resolver::resolve(&master);
    let removed = with_store(|ms| node::overlay::remove_person(ms, &master))?;
    refresh_node();
    Ok(removed)
}

/// Our own picks for a person (a local look: an empty state or an absent effect key
/// is "not overridden"); `None` clears them.
#[frb]
pub fn overlay_set_local_look(master: String, look_json: Option<String>) -> Result<(), String> {
    let master = node::resolver::resolve(&master);
    with_store(|ms| node::overlay::set_local_look(ms, &master, look_json.as_deref()))
}

/// What a person's signed field says: "off" | "show" | "share" (absent = "show").
#[frb(sync)]
pub fn overlay_field_of(master: String) -> String {
    let master = node::resolver::resolve(&master);
    with_store(|ms| Ok(node::overlay::field_of(ms, &master).kind().to_string())).unwrap_or_else(|_| "show".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Dart previews read overlay images only: a rail blob under the same name is
    /// never handed out, nor anything for a name that is not a hash.
    #[test]
    fn overlay_image_bytes_reads_the_overlay_table_only() {
        let _st = super::super::storage::store_test_lock();
        let ms = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let (rail, look) = ("a".repeat(64), "b".repeat(64));
        ms.save_asset_blob(&rail, b"sticker", false, "sticker").unwrap();
        ms.save_overlay_blob(&look, b"look", false).unwrap();
        super::super::storage::set_test_store(ms);
        let (r, l, bad) = (overlay_image_bytes(rail), overlay_image_bytes(look), overlay_image_bytes("../x".into()));
        super::super::storage::set_test_store(crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap());
        assert_eq!(l.as_deref(), Some(&b"look"[..]), "CONTROL: an overlay image");
        assert_eq!(r, None, "a sticker was handed out as an overlay image");
        assert_eq!(bad, None);
    }
}
