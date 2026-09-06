//! Stickers: the personal vault, server sticker packs and the Klipy catalog.
//!
//! Stickers ride the SAME rails as everything else in the asset epic, so this module
//! is mostly plumbing. BYTES are content-addressed WebP in `emote_blobs` at
//! `kind='sticker'`, replicated on demand under `AssetKind::Sticker`, and nothing here
//! ever puts sticker bytes on the wire. METADATA is CRDT state for a server's set and
//! a local SQLCipher table for the vault. MESSAGES carry `[a:s:hash:w:h]`, an ordinary
//! run of message text, so there is no new message-row path and no signing or sync
//! change. The CATALOG is the same two-mode client as GIFs, authoring-time only: a
//! picked sticker becomes a local blob, so message RECEIVERS make zero HTTP requests.
//!
//! Sticker identity is the HASH, not the name: an emote is typed as `:name:` so its
//! name must be unique, while a sticker is picked visually and its name is a label.

use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

use super::gifs::{self, GifPage, MediaKind, StoredGif};
use super::network::{get_node, get_runtime};
use super::storage::get_store;
use crate::crdt::server_state::{MAX_SERVER_STICKERS, MAX_STICKER_LABEL, valid_sticker_label};
use crate::node;

/// Max packs in the personal vault, and stickers in one pack. Generous enough for real
/// multi-part packs while keeping the vault bounded: every row pins a blob against the
/// asset LRU, so this ceiling is a disk commitment.
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

/// The authoring caps Dart enforces in its own UI copy rather than mirroring the
/// numbers: `[per server, per pack, packs, vault total, label chars]`.
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

/// Process a user-picked image into a sticker blob and cache it locally. Re-encoding
/// here IS the sanitization step, the same argument emotes and GIFs make. The caller
/// then registers it via [add_personal_sticker] or [add_server_sticker].
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
    // Caps apply only to genuinely new rows: re-adding an existing (pack, hash) is a
    // metadata edit and must not be refused for a limit it did not push us past.
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

/// Delete a whole pack. The blobs stay cached, because they are content-addressed and
/// a message you already sent still points at them; the asset LRU reclaims them.
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

/// The whole vault, pack-major and oldest-first inside each pack: upload order IS pack
/// order, which is what makes a multi-part pack readable.
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

/// Add (or re-label) a sticker in a server's set, under `MANAGE_EMOTES`. The blob must
/// already be cached locally so this node can serve members' pull requests.
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
// Thin wrappers over the shared two-mode client in `api/gifs.rs`. Every guard there
// applies unchanged: the proxy-origin prefix check, the direct-mode media host
// allowlist, the random per-request customer_id, the blocked-host memory the settings
// card surfaces, and the dedicated HTTP runtime.

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
/// Same fetcher discipline as GIFs: proxy mode ignores `source_url` and builds
/// `{base}f/{id}` itself, while direct mode resolves the variants our own parse
/// registered and falls back to `source_url` only on a registry miss, through the
/// media host allowlist.
#[frb]
pub fn sticker_fetch_and_store(
    id: String,
    source_url: Option<String>,
) -> Result<StoredGif, String> {
    gifs::media_fetch_and_store(MediaKind::Sticker, id, source_url)
}

// ── Pack sharing: the `.hollow-pack` file (issue #36) ─────────────────
//
// A pack is shared as a FILE, never a link, and that is architectural rather than
// stylistic: Hollow has nowhere to host bytes. A server invite works because the link
// carries only an ID and the join happens over the relay into a room the inviter is
// already in; a pack has no room behind it, so a URL would mean serving strangers from
// the author's node or running a CDN, and we refuse both. Dropping the file into a chat
// reuses the encrypted transfer path and adds no discovery at all.
//
// It is also the more private primitive: a live "vault link" would tell the author who
// added them and let them push new bytes later, while a file is a one-time copy. It
// doubles as the vault's only backup story, since `personal_stickers` is local-only.
//
// Container (ZIP): `manifest.json` { format_version, pack, author, created_at,
// items[], sig } plus `blobs/<hash>.webp`.
//
// The author signature is ATTRIBUTION ONLY. It never gates the import, and a missing
// or bad one means "no byline", never "refuse": anyone may author a pack.

const PACK_FORMAT_VERSION: u32 = 1;

/// One sticker in a `.hollow-pack` manifest.
#[derive(serde::Serialize, serde::Deserialize)]
struct PackItem {
    hash: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    animated: bool,
    w: u32,
    h: u32,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct PackManifest {
    format_version: u32,
    pack: String,
    #[serde(default)]
    author: String,
    #[serde(default)]
    author_pubkey_b64: String,
    #[serde(default)]
    created_at: u64,
    items: Vec<PackItem>,
    #[serde(default)]
    sig_b64: String,
}

/// What a `.hollow-pack` says about itself, for the in-chat card and the
/// import confirmation — read WITHOUT touching the vault.
pub struct StickerPackPreview {
    pub pack: String,
    /// Master peer_id of whoever exported it, `""` when unsigned or forged.
    pub author: String,
    /// True only when the signature verifies against `author`. Display only.
    pub author_verified: bool,
    /// Stickers the file claims to carry.
    ///
    /// CLAIMS, not a promise: the count comes from the manifest and every entry still
    /// has to survive import validation. No thumbnail ships with this on purpose, since
    /// previewing would hand un-validated bytes to an image decoder.
    pub count: u32,
}

/// Outcome of an import. Partial by design: hitting a vault cap part-way
/// through must keep what already landed and SAY so, not roll back the lot.
pub struct StickerPackImportResult {
    pub pack: String,
    pub added: u32,
    /// Already in the pack — re-importing is idempotent, not an error.
    pub skipped: u32,
    /// Failed validation or would not fit under the caps.
    pub rejected: u32,
}

/// Canonical bytes the author signs: the pack name, the author, and every item's hash
/// and dims in manifest order, so nothing inside can be reordered, retitled or
/// resized after signing.
fn pack_signing_payload(pack: &str, author: &str, items: &[PackItem]) -> String {
    let mut s = format!("hollow-pack:v{PACK_FORMAT_VERSION}:{pack}:{author}");
    for it in items {
        s.push_str(&format!(":{}:{}:{}", it.hash, it.w, it.h));
    }
    s
}

/// Export one personal pack as a `.hollow-pack` file. Returns its size.
#[frb]
pub fn export_personal_sticker_pack(
    pack: String,
    output_path: String,
) -> Result<u64, String> {
    use std::io::Write;

    let pack = pack.trim().to_string();
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;

    let rows: Vec<_> = ms
        .list_personal_stickers()?
        .into_iter()
        .filter(|r| r.pack == pack)
        .collect();
    if rows.is_empty() {
        return Err("That pack has no stickers".into());
    }

    // Collect bytes first: a row whose blob was evicted cannot be exported, and a pack
    // with a dangling manifest entry is worse than a smaller one.
    let mut blobs: Vec<(String, Vec<u8>)> = Vec::new();
    let mut items: Vec<PackItem> = Vec::new();
    for r in &rows {
        let Some(bytes) = ms.load_emote_blob(&r.hash)? else {
            continue;
        };
        items.push(PackItem {
            hash: r.hash.clone(),
            name: r.name.clone(),
            animated: r.animated,
            w: r.w,
            h: r.h,
        });
        blobs.push((r.hash.clone(), bytes));
    }
    if items.is_empty() {
        return Err("None of that pack's images are still cached".into());
    }

    let id = crate::identity::load_or_create_identity()?;
    let payload = pack_signing_payload(&pack, &id.peer_id, &items);
    let sig = id.keypair.sign(payload.as_bytes());
    let manifest = PackManifest {
        format_version: PACK_FORMAT_VERSION,
        pack: pack.clone(),
        author: id.peer_id.clone(),
        author_pubkey_b64: {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD
                .encode(id.keypair.public_key_protobuf())
        },
        created_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        items,
        sig_b64: {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD.encode(sig)
        },
    };
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)
        .map_err(|e| format!("Failed to serialize pack manifest: {e}"))?;

    let mut zip_buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = zip::ZipWriter::new(&mut zip_buf);
        // WebP is already compressed; Deflate would only burn CPU.
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);

        zip.start_file("manifest.json", options)
            .map_err(|e| format!("Zip error: {e}"))?;
        zip.write_all(&manifest_bytes)
            .map_err(|e| format!("Zip write error: {e}"))?;

        for (hash, bytes) in &blobs {
            zip.start_file(format!("blobs/{hash}.webp"), options)
                .map_err(|e| format!("Zip error: {e}"))?;
            zip.write_all(bytes)
                .map_err(|e| format!("Zip write error: {e}"))?;
        }
        zip.finish().map_err(|e| format!("Zip finish error: {e}"))?;
    }

    let bytes = zip_buf.into_inner();
    let size = bytes.len() as u64;
    std::fs::write(&output_path, &bytes)
        .map_err(|e| format!("Failed to write pack: {e}"))?;
    Ok(size)
}

/// Read a `.hollow-pack` manifest without importing anything.
#[frb]
pub fn preview_sticker_pack(path: String) -> Result<StickerPackPreview, String> {
    let manifest = read_pack_manifest(&path)?;
    let verified = pack_signature_is_valid(&manifest);
    Ok(StickerPackPreview {
        pack: manifest.pack,
        author: if verified {
            manifest.author.clone()
        } else {
            String::new()
        },
        author_verified: verified,
        count: manifest.items.len() as u32,
    })
}

fn read_pack_manifest(path: &str) -> Result<PackManifest, String> {
    use std::io::Read;

    let zip_bytes =
        std::fs::read(path).map_err(|e| format!("Failed to read pack: {e}"))?;
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&zip_bytes))
        .map_err(|e| format!("Not a valid pack file: {e}"))?;
    let mut raw = String::new();
    archive
        .by_name("manifest.json")
        .map_err(|_| "Pack is missing its manifest".to_string())?
        .read_to_string(&mut raw)
        .map_err(|e| format!("Failed to read pack manifest: {e}"))?;
    let manifest: PackManifest = serde_json::from_str(&raw)
        .map_err(|e| format!("Failed to parse pack manifest: {e}"))?;
    if manifest.format_version > PACK_FORMAT_VERSION {
        return Err("That pack was made by a newer version of Hollow".into());
    }
    Ok(manifest)
}

/// Attribution check. False for anything unsigned, malformed or mismatched —
/// and false NEVER blocks an import, it only withholds the byline.
fn pack_signature_is_valid(manifest: &PackManifest) -> bool {
    use base64::Engine;
    use crate::identity::native_identity::NativeKeypair;
    let b64 = base64::engine::general_purpose::STANDARD;

    if manifest.author.is_empty() || manifest.sig_b64.is_empty() {
        return false;
    }
    let (Ok(pk), Ok(sig)) = (
        b64.decode(&manifest.author_pubkey_b64),
        b64.decode(&manifest.sig_b64),
    ) else {
        return false;
    };
    // Bind pubkey to claimed author, as the device-list check does: otherwise anyone
    // could sign with their own key and claim any name.
    match NativeKeypair::peer_id_from_pubkey_protobuf(&pk) {
        Some(derived) if derived == manifest.author => {}
        _ => return false,
    }
    let payload = pack_signing_payload(&manifest.pack, &manifest.author, &manifest.items);
    NativeKeypair::verify_peer_signature(&pk, &sig, payload.as_bytes()).unwrap_or(false)
}

/// Import a `.hollow-pack` into the personal vault under [into_pack] (empty =
/// the name the file carries).
///
/// Every byte here is attacker-controlled, so nothing in the manifest is trusted: the
/// blob is keyed by the hash we COMPUTE and an entry whose bytes do not hash to their
/// claimed name is rejected, `w`/`h` are re-derived from the decoded image because
/// they go straight into the wire token, entry paths are never joined, and the vault
/// caps are enforced per row so a huge pack fills to the limit and reports the rest
/// as rejected rather than failing whole.
#[frb]
pub fn import_sticker_pack(
    path: String,
    into_pack: String,
) -> Result<StickerPackImportResult, String> {
    use std::io::Read;

    let manifest = read_pack_manifest(&path)?;
    let target = {
        let requested = into_pack.trim();
        let name = if requested.is_empty() {
            manifest.pack.trim()
        } else {
            requested
        };
        clean_label(name)?
    };

    let zip_bytes =
        std::fs::read(&path).map_err(|e| format!("Failed to read pack: {e}"))?;
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&zip_bytes))
        .map_err(|e| format!("Not a valid pack file: {e}"))?;

    let mut added = 0u32;
    let mut skipped = 0u32;
    let mut rejected = 0u32;

    for item in &manifest.items {
        if !crate::crdt::valid_emote_hash(&item.hash) {
            rejected += 1;
            continue;
        }
        // The hash names the entry, so an attacker-supplied path is never joined.
        let mut bytes = Vec::new();
        let read_ok = archive
            .by_name(&format!("blobs/{}.webp", item.hash))
            .map(|mut f| f.read_to_end(&mut bytes))
            .is_ok();
        if !read_ok || bytes.is_empty() {
            rejected += 1;
            continue;
        }
        // Content-address check: the bytes ARE the identity.
        let actual = hex::encode(Sha256::digest(&bytes));
        if actual != item.hash {
            rejected += 1;
            continue;
        }
        let Ok((w, h, animated)) =
            crate::node::image_convert::validate_sticker_blob(&bytes)
        else {
            rejected += 1;
            continue;
        };
        // A label is cosmetic, so a bad one falls back to unnamed rather than rejecting.
        let name = clean_label(&item.name).unwrap_or_default();

        {
            let store = get_store();
            let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
            let ms = guard.as_ref().ok_or("Message store is not open")?;
            if ms
                .list_personal_stickers()?
                .iter()
                .any(|r| r.pack == target && r.hash == actual)
            {
                skipped += 1;
                continue;
            }
            ms.save_asset_blob(&actual, &bytes, animated, "sticker")?;
        }

        // The ordinary add path, so caps, blob presence and label rules are enforced once.
        match add_personal_sticker(
            target.clone(),
            actual,
            name,
            animated,
            w,
            h,
            "pack".to_string(),
        ) {
            Ok(()) => added += 1,
            Err(_) => rejected += 1,
        }
    }

    Ok(StickerPackImportResult {
        pack: target,
        added,
        skipped,
        rejected,
    })
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

    // ── `.hollow-pack` (issue #36) ────────────────────────────────────

    use crate::identity::native_identity::NativeKeypair;

    fn item(hash_seed: u8, w: u32, h: u32) -> PackItem {
        PackItem {
            hash: hex::encode([hash_seed; 32]),
            name: "piece".into(),
            animated: false,
            w,
            h,
        }
    }

    fn signed_manifest(kp: &NativeKeypair, pack: &str, items: Vec<PackItem>) -> PackManifest {
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD;
        let author = kp.peer_id();
        let sig = kp.sign(pack_signing_payload(pack, &author, &items).as_bytes());
        PackManifest {
            format_version: PACK_FORMAT_VERSION,
            pack: pack.into(),
            author,
            author_pubkey_b64: b64.encode(kp.public_key_protobuf()),
            created_at: 0,
            items,
            sig_b64: b64.encode(sig),
        }
    }

    #[test]
    fn signing_payload_binds_every_item_and_its_dims() {
        let a = pack_signing_payload("p", "author", &[item(1, 512, 512)]);
        // Reordering, resizing or renaming the pack must all change it —
        // otherwise the signature covers nothing that matters.
        assert_ne!(
            a,
            pack_signing_payload("p", "author", &[item(1, 512, 256)])
        );
        assert_ne!(
            a,
            pack_signing_payload("p", "author", &[item(2, 512, 512)])
        );
        assert_ne!(a, pack_signing_payload("q", "author", &[item(1, 512, 512)]));
        assert_ne!(a, pack_signing_payload("p", "other", &[item(1, 512, 512)]));
        assert_ne!(
            pack_signing_payload("p", "a", &[item(1, 8, 8), item(2, 8, 8)]),
            pack_signing_payload("p", "a", &[item(2, 8, 8), item(1, 8, 8)]),
            "item ORDER is signed"
        );
    }

    #[test]
    fn a_genuine_signature_verifies() {
        let kp = NativeKeypair::from_secret_bytes(&[7u8; 32]);
        let m = signed_manifest(&kp, "autumn", vec![item(1, 512, 512)]);
        assert!(pack_signature_is_valid(&m));
    }

    #[test]
    fn tampering_after_signing_loses_the_byline() {
        let kp = NativeKeypair::from_secret_bytes(&[7u8; 32]);

        // Swapping in a different sticker.
        let mut m = signed_manifest(&kp, "autumn", vec![item(1, 512, 512)]);
        m.items[0].hash = hex::encode([9u8; 32]);
        assert!(!pack_signature_is_valid(&m));

        // Lying about the dims that build the wire token.
        let mut m = signed_manifest(&kp, "autumn", vec![item(1, 512, 512)]);
        m.items[0].w = 4096;
        assert!(!pack_signature_is_valid(&m));

        // Renaming the pack.
        let mut m = signed_manifest(&kp, "autumn", vec![item(1, 512, 512)]);
        m.pack = "winter".into();
        assert!(!pack_signature_is_valid(&m));
    }

    #[test]
    fn a_forged_author_cannot_borrow_someone_elses_name() {
        // Sign with our own key, then claim to be somebody else: the pubkey-to-peer_id
        // binding is what stops this.
        let mine = NativeKeypair::from_secret_bytes(&[7u8; 32]);
        let theirs = NativeKeypair::from_secret_bytes(&[8u8; 32]);
        let mut m = signed_manifest(&mine, "autumn", vec![item(1, 512, 512)]);
        m.author = theirs.peer_id();
        assert!(!pack_signature_is_valid(&m));
    }

    #[test]
    fn unsigned_packs_are_simply_unattributed() {
        // Not an error — anyone may author a pack, and there is no authority
        // that could say otherwise. It just gets no byline.
        let m = PackManifest {
            format_version: PACK_FORMAT_VERSION,
            pack: "autumn".into(),
            author: String::new(),
            author_pubkey_b64: String::new(),
            created_at: 0,
            items: vec![item(1, 512, 512)],
            sig_b64: String::new(),
        };
        assert!(!pack_signature_is_valid(&m));
    }
}
