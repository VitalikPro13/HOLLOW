//! Custom emotes — import/processing, personal set, server sets, and the
//! FrankerFaceZ browse tab.
//!
//! PRIVACY MODEL (mirrors `showcase.rs`): FFZ is a catalog touched ONLY at
//! authoring time, ONLY through OUR website's write-through cache endpoint
//! (the website holds the single upstream identity; users never contact
//! FFZ or its CDN). The moment an emote is picked it is re-processed into a
//! content-addressed Hollow WebP blob and replicates purely P2P — viewers
//! never make an HTTP request for any emote, ever. `ffz_import_emote`
//! refuses any URL that is not on our own CDN, so it can never be abused
//! as a generic fetcher.

use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

use super::network::{get_node, get_runtime};
use super::storage::get_store;
use crate::node;

/// Base URL of the Hollow website's cached FFZ endpoint.
const FFZ_ENDPOINT: &str = "https://hollow.anonlisten.com/ffz/search.php";
/// FFZ emote images must come from here and nowhere else.
const FFZ_IMAGE_BASE: &str = "https://hollow.anonlisten.com/ffz/emotes/";
/// Endpoint response-schema version (keep in sync with SEARCH_VER in ffz/search.php).
const FFZ_SCHEMA_VER: &str = "1";

/// A processed, locally cached emote blob (content-addressed).
pub struct ProcessedEmote {
    pub hash: String,
    pub animated: bool,
}

/// One entry of the user's personal (global) emote set.
pub struct PersonalEmote {
    pub name: String,
    pub hash: String,
    pub animated: bool,
    /// "upload" | "ffz:<id>" — provenance only, never fetched at display time.
    pub source: String,
}

/// One custom emote of a server's emote set (CRDT-replicated metadata).
pub struct ServerEmote {
    pub name: String,
    pub hash: String,
    pub animated: bool,
}

/// One FFZ search/browse row (authoring-time only). `image_url` points at
/// OUR CDN cache, never at FFZ.
pub struct FfzEmote {
    pub id: i64,
    pub name: String,
    pub owner: String,
    pub animated: bool,
    pub image_url: String,
    pub usage_count: i64,
}

fn normalize_name(name: &str) -> String {
    name.trim().to_lowercase()
}

/// Wire token for an emote, as inserted into message text / reactions.
#[frb(sync)]
pub fn emote_token(name: String, hash: String) -> String {
    format!("[e:{}:{}]", normalize_name(&name), hash)
}

// ── Local processing + blob cache ─────────────────────────────────────

/// Process a user-picked image (PNG/JPG/WebP/GIF) into an emote blob and
/// cache it locally. Caller then registers it via [add_personal_emote] or
/// [add_server_emote].
#[frb]
pub fn process_and_store_emote(raw_bytes: Vec<u8>) -> Result<ProcessedEmote, String> {
    let (bytes, animated) = crate::node::image_convert::process_emote_image(&raw_bytes)?;
    let hash = hex::encode(Sha256::digest(&bytes));
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.save_emote_blob(&hash, &bytes, animated)?;
    Ok(ProcessedEmote { hash, animated })
}

/// Cached emote bytes for a hash (None = not cached yet; caller should
/// trigger [request_emotes] and re-read on `EmoteAssetsReceived`).
#[frb]
pub fn get_emote_bytes(hash: String) -> Result<Option<Vec<u8>>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_emote_blob(&hash)
}

/// Pull emote bytes we don't have from the network: `server_id` asks one
/// online member of that server's room, `peer_hint` asks a DM sender's
/// devices. Fire-and-forget; results arrive as `EmoteAssetsReceived`.
#[frb]
pub fn request_emotes(
    hashes: Vec<String>,
    server_id: Option<String>,
    peer_hint: Option<String>,
) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::RequestEmotes { hashes, server_id, peer_hint }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

// ── Personal (global) emote set ───────────────────────────────────────

#[frb]
pub fn add_personal_emote(
    name: String,
    hash: String,
    animated: bool,
    source: String,
) -> Result<(), String> {
    let name = normalize_name(&name);
    if !crate::crdt::valid_emote_name(&name) {
        return Err("Emote names are 2-24 characters: a-z, 0-9, _".into());
    }
    if !crate::crdt::valid_emote_hash(&hash) {
        return Err("Invalid emote hash".into());
    }
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.add_personal_emote(&name, &hash, animated, &source)
}

#[frb]
pub fn remove_personal_emote(name: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.remove_personal_emote(&normalize_name(&name))
}

#[frb]
pub fn list_personal_emotes() -> Result<Vec<PersonalEmote>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms
        .list_personal_emotes()?
        .into_iter()
        .map(|(name, hash, animated, source)| PersonalEmote { name, hash, animated, source })
        .collect())
}

// ── Server emote sets (CRDT) ──────────────────────────────────────────

/// The custom emote set of a server (replicated metadata; bytes pulled
/// separately by hash).
#[frb]
pub fn get_server_emotes(server_id: String) -> Result<Vec<ServerEmote>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let state_json = ms
        .load_server_state(&server_id)?
        .ok_or("Server not found")?;
    let state = serde_json::from_str::<crate::crdt::server_state::ServerState>(&state_json)
        .map_err(|e| format!("Failed to parse server state: {e}"))?;
    Ok(state
        .emotes_list()
        .into_iter()
        .map(|e| ServerEmote {
            name: e.name.clone(),
            hash: e.hash.clone(),
            animated: e.animated,
        })
        .collect())
}

/// Add/replace a custom server emote (MANAGE_EMOTES, Admin+ by default).
/// The blob must already be cached locally (via [process_and_store_emote]
/// or [ffz_import_emote]) so this node can serve members' pull requests.
#[frb]
pub fn add_server_emote(
    server_id: String,
    name: String,
    hash: String,
    animated: bool,
) -> Result<(), String> {
    let name = normalize_name(&name);
    if !crate::crdt::valid_emote_name(&name) {
        return Err("Emote names are 2-24 characters: a-z, 0-9, _".into());
    }
    if !crate::crdt::valid_emote_hash(&hash) {
        return Err("Invalid emote hash".into());
    }
    {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        if !ms.has_emote_blob(&hash)? {
            return Err("Emote image is not cached locally".into());
        }
    }
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::AddServerEmote { server_id, name, hash, animated }))
        .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

#[frb]
pub fn remove_server_emote(server_id: String, name: String) -> Result<(), String> {
    let node = get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Node is not running")?.cmd_tx.clone();
    drop(guard);
    let rt = get_runtime();
    rt.block_on(cmd_tx.send(node::NodeCommand::RemoveServerEmote {
        server_id,
        name: normalize_name(&name),
    }))
    .map_err(|e| format!("Failed to send command: {e}"))?;
    Ok(())
}

// ── FrankerFaceZ browse (authoring-time, via OUR website only) ────────

fn parse_ffz_rows(items: &[serde_json::Value]) -> Vec<FfzEmote> {
    items
        .iter()
        .filter_map(|v| {
            Some(FfzEmote {
                id: v.get("id")?.as_i64()?,
                name: v.get("name")?.as_str()?.to_string(),
                owner: v
                    .get("owner")
                    .and_then(|o| o.as_str())
                    .unwrap_or_default()
                    .to_string(),
                animated: v.get("animated").and_then(|a| a.as_bool()).unwrap_or(false),
                image_url: v
                    .get("url")
                    .and_then(|u| u.as_str())
                    .filter(|u| u.starts_with(FFZ_IMAGE_BASE))?
                    .to_string(),
                usage_count: v.get("usage").and_then(|u| u.as_i64()).unwrap_or(0),
            })
        })
        .collect()
}

fn ffz_query(params: Vec<(&'static str, String)>) -> Result<Vec<FfzEmote>, String> {
    let rt = get_runtime();
    rt.block_on(async move {
        let client = reqwest::Client::new();
        let resp = client
            .post(FFZ_ENDPOINT)
            .form(&params)
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("Emote search failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("Emote search failed: HTTP {}", resp.status()));
        }
        let items: Vec<serde_json::Value> = resp
            .json()
            .await
            .map_err(|e| format!("Emote search returned invalid JSON: {e}"))?;
        Ok(parse_ffz_rows(&items))
    })
}

/// Search FFZ emotes via the website's write-through cache. Authoring only.
#[frb]
pub fn ffz_search(query: String) -> Result<Vec<FfzEmote>, String> {
    let q = query.trim().to_string();
    if q.is_empty() {
        return Ok(vec![]);
    }
    ffz_query(vec![("q", q), ("v", FFZ_SCHEMA_VER.to_string())])
}

/// The FFZ global emote sets (cached server-side; effectively static).
#[frb]
pub fn ffz_global() -> Result<Vec<FfzEmote>, String> {
    ffz_query(vec![("global", "1".to_string()), ("v", FFZ_SCHEMA_VER.to_string())])
}

/// Download an FFZ emote image FROM OUR CDN (authoring-time only), process
/// it into a Hollow emote blob, and cache it. The allowlist is the privacy
/// boundary — this can never be abused as a generic fetcher.
#[frb]
pub fn ffz_import_emote(image_url: String) -> Result<ProcessedEmote, String> {
    if !image_url.starts_with(FFZ_IMAGE_BASE) {
        return Err("Emote URL is not on the Hollow CDN".into());
    }
    let rt = get_runtime();
    let raw = rt.block_on(async move {
        let client = reqwest::Client::new();
        let resp = client
            .get(&image_url)
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("Emote download failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("Emote download failed: HTTP {}", resp.status()));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| format!("Emote download failed: {e}"))?;
        if bytes.len() > 2_000_000 {
            return Err("Emote download too large".into());
        }
        Ok(bytes.to_vec())
    })?;
    process_and_store_emote(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emote_token_shape() {
        let h = "a".repeat(64);
        assert_eq!(emote_token("Pog".into(), h.clone()), format!("[e:pog:{h}]"));
    }

    #[test]
    fn ffz_rows_drop_non_cdn_urls() {
        let items: Vec<serde_json::Value> = serde_json::from_str(&format!(
            r#"[
                {{"id":1,"name":"Pog","owner":"x","animated":false,"url":"{FFZ_IMAGE_BASE}1.png","usage":5}},
                {{"id":2,"name":"Evil","owner":"y","animated":false,"url":"https://evil.example/2.png","usage":9}}
            ]"#
        ))
        .unwrap();
        let rows = parse_ffz_rows(&items);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, 1);
    }
}
