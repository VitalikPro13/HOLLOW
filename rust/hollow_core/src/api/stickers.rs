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

/// A full pack's manifest (120 items, longest names, signed) stays under 64 KB.
const MAX_PACK_MANIFEST_BYTES: u64 = 128 << 10;

/// One blob, the size the asset rail takes a sticker at.
fn pack_blob_cap() -> u64 {
    node::assets::AssetKind::Sticker.recv_cap() as u64
}

/// Everything one pack may unpack to: its manifest and a full pack of stickers.
fn pack_unpack_budget() -> u64 {
    MAX_PACK_MANIFEST_BYTES + MAX_STICKERS_PER_PACK as u64 * pack_blob_cap()
}

/// Entries a pack's index may list: its manifest, a full pack, and a few a zip tool adds.
const MAX_PACK_ENTRIES: u64 = 1 + MAX_STICKERS_PER_PACK as u64 + 7;

/// The pack file itself, read whole before it is opened: its budget plus zip framing.
fn max_pack_file_bytes() -> u64 {
    pack_unpack_budget() + (1 << 20)
}

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
    let manifest = open_pack(&path)?.manifest;
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

/// A pack opened for reading, with what it may still unpack to.
struct OpenPack {
    manifest: PackManifest,
    archive: zip::ZipArchive<std::io::Cursor<Vec<u8>>>,
    budget: crate::zip_budget::UnpackBudget,
}

/// Open a pack and read its manifest, each under its own bound: the chat card does this
/// for every pack it shows, before anyone asks to import it.
fn open_pack(path: &str) -> Result<OpenPack, String> {
    let path = std::path::Path::new(path);
    if crate::node::at_rest::plaintext_len(path)? > max_pack_file_bytes() {
        return Err("That sticker pack is too large to open".into());
    }
    let zip_bytes = crate::node::at_rest::read_all(path)?;
    if let Some(reason) = crate::zip_budget::index_refused(&zip_bytes, MAX_PACK_ENTRIES) {
        return Err(format!("Not a valid pack file: {reason}"));
    }
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes))
        .map_err(|e| format!("Not a valid pack file: {e}"))?;
    let mut budget = crate::zip_budget::UnpackBudget::new(pack_unpack_budget());
    let raw = {
        let entry = archive
            .by_name("manifest.json")
            .map_err(|_| "Pack is missing its manifest".to_string())?;
        budget
            .read(entry, MAX_PACK_MANIFEST_BYTES)
            .map_err(|_| "The pack manifest is too large to be real".to_string())?
    };
    let manifest: PackManifest = serde_json::from_slice(&raw)
        .map_err(|e| format!("Failed to parse pack manifest: {e}"))?;
    if manifest.format_version > PACK_FORMAT_VERSION {
        return Err("That pack was made by a newer version of Hollow".into());
    }
    Ok(OpenPack { manifest, archive, budget })
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
/// as rejected rather than failing whole. Every blob is unpacked under the sticker cap
/// and one budget for the whole pack, so its bytes, not its headers, bound the work.
#[frb]
pub fn import_sticker_pack(
    path: String,
    into_pack: String,
) -> Result<StickerPackImportResult, String> {
    let OpenPack { manifest, mut archive, mut budget } = open_pack(&path)?;
    let target = {
        let requested = into_pack.trim();
        let name = if requested.is_empty() {
            manifest.pack.trim()
        } else {
            requested
        };
        clean_label(name)?
    };

    let mut added = 0u32;
    let mut skipped = 0u32;
    let mut rejected = 0u32;

    for (i, item) in manifest.items.iter().enumerate() {
        if !crate::crdt::valid_emote_hash(&item.hash) {
            rejected += 1;
            continue;
        }
        // The hash names the entry, so an attacker-supplied path is never joined.
        let read = match archive.by_name(&format!("blobs/{}.webp", item.hash)) {
            Ok(entry) => budget.read(entry, pack_blob_cap()),
            Err(_) => Err(crate::zip_budget::Unpack::Unreadable(String::new())),
        };
        let bytes = match read {
            Ok(bytes) if !bytes.is_empty() => bytes,
            // Partial by design: what landed stays, the rest is reported.
            Err(crate::zip_budget::Unpack::OverBudget) => {
                rejected += (manifest.items.len() - i) as u32;
                break;
            }
            _ => {
                rejected += 1;
                continue;
            }
        };
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

    // t14-zipbomb: how much a received pack may unpack to (HOL-SEC-205)

    use std::io::Write;

    /// A pack zip of `manifest.json` plus `blobs`, every entry deflated so a run of one
    /// byte costs almost nothing on the wire.
    fn pack_zip(manifest: &[u8], blobs: &[(String, Vec<u8>)]) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        let opts = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        z.start_file("manifest.json", opts).unwrap();
        z.write_all(manifest).unwrap();
        for (name, bytes) in blobs {
            z.start_file(name.as_str(), opts).unwrap();
            z.write_all(bytes).unwrap();
        }
        z.finish().unwrap();
        out.into_inner()
    }

    fn manifest_naming(hashes: &[&str]) -> Vec<u8> {
        let items: Vec<PackItem> = hashes
            .iter()
            .map(|h| PackItem { hash: h.to_string(), name: String::new(), animated: false, w: 64, h: 64 })
            .collect();
        serde_json::to_vec(&PackManifest {
            format_version: PACK_FORMAT_VERSION,
            pack: "budget".into(),
            author: String::new(),
            author_pubkey_b64: String::new(),
            created_at: 0,
            items,
            sig_b64: String::new(),
        })
        .unwrap()
    }

    fn blob_entry(bytes: Vec<u8>) -> (String, String, Vec<u8>) {
        let hash = hex::encode(Sha256::digest(&bytes));
        (hash.clone(), format!("blobs/{hash}.webp"), bytes)
    }

    fn real_sticker() -> Vec<u8> {
        let mut img = image::RgbaImage::from_pixel(96, 64, image::Rgba([0, 0, 0, 0]));
        for y in 0..64 {
            for x in 48..96 {
                img.put_pixel(x, y, image::Rgba([40, 200, 90, 255]));
            }
        }
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        crate::node::image_convert::process_sticker_for_send(&png).unwrap().0
    }

    fn write_pack(dir: &std::path::Path, bytes: &[u8]) -> String {
        let path = dir.join("p.hollow-pack");
        std::fs::write(&path, bytes).unwrap();
        path.to_string_lossy().into_owned()
    }

    /// An in-memory store, the one the import writes its rows to.
    fn pack_store() -> std::sync::MutexGuard<'static, ()> {
        let lock = crate::api::storage::store_test_lock();
        crate::api::storage::set_test_store(
            crate::storage::MessageStore::open(":memory:", &"cd".repeat(32)).unwrap(),
        );
        lock
    }

    #[test]
    fn a_pack_whose_manifest_unpacks_past_its_cap_is_refused() {
        let _s = pack_store();
        let work = crate::test_tmp::tempdir().unwrap();
        // Inside the pack's whole budget, so only the manifest's own cap refuses it.
        let mut manifest = manifest_naming(&[]);
        manifest.extend(std::iter::repeat_n(b' ', 32 << 20));
        let bytes = pack_zip(&manifest, &[]);
        assert!(bytes.len() < 128 << 10, "the fixture is small on the wire: {}", bytes.len());
        let path = write_pack(work.path(), &bytes);
        // The chat card previews every received pack before anyone taps Add.
        assert!(preview_sticker_pack(path.clone()).is_err(), "a 32 MiB manifest was read whole");
        assert!(import_sticker_pack(path, String::new()).is_err());
    }

    #[test]
    fn a_manifest_at_its_cap_still_previews() {
        let work = crate::test_tmp::tempdir().unwrap();
        let mut manifest = manifest_naming(&[]);
        manifest.resize(MAX_PACK_MANIFEST_BYTES as usize, b' ');
        let path = write_pack(work.path(), &pack_zip(&manifest, &[]));
        assert_eq!(preview_sticker_pack(path).unwrap().pack, "budget");
    }

    #[test]
    fn a_pack_file_past_its_size_is_refused_before_it_is_read() {
        let work = crate::test_tmp::tempdir().unwrap();
        let path = work.path().join("big.hollow-pack");
        std::fs::File::create(&path).unwrap().set_len(max_pack_file_bytes() + 1).unwrap();
        let err = preview_sticker_pack(path.to_string_lossy().into_owned()).err().expect("refused");
        assert!(err.contains("too large"), "{err}");
    }

    #[test]
    fn a_blob_that_inflates_past_the_sticker_cap_costs_only_the_cap() {
        let _s = pack_store();
        let work = crate::test_tmp::tempdir().unwrap();
        let (bomb_hash, bomb_name, bomb) = blob_entry(vec![0u8; 64 << 20]);
        let (real_hash, real_name, real) = blob_entry(real_sticker());
        let manifest = manifest_naming(&[&bomb_hash, &real_hash]);
        let path = write_pack(work.path(), &pack_zip(&manifest, &[(bomb_name, bomb), (real_name, real)]));
        let got = import_sticker_pack(path, String::new()).unwrap();
        assert_eq!((got.added, got.rejected), (1, 1), "the bomb is refused alone and the real sticker after it lands");
    }

    #[test]
    fn a_pack_stops_unpacking_once_its_budget_is_spent() {
        let _s = pack_store();
        let work = crate::test_tmp::tempdir().unwrap();
        // At the per-sticker cap exactly, so every read of it passes that check.
        let (junk_hash, junk_name, junk) = blob_entry(vec![0u8; pack_blob_cap() as usize]);
        let (real_hash, real_name, real) = blob_entry(real_sticker());
        let mut names = vec![junk_hash.as_str(); MAX_STICKERS_PER_PACK + 2];
        names.push(&real_hash);
        let manifest = manifest_naming(&names);
        let path = write_pack(work.path(), &pack_zip(&manifest, &[(junk_name, junk), (real_name, real)]));
        let got = import_sticker_pack(path, String::new()).unwrap();
        assert_eq!(got.added, 0, "an entry read past the pack's budget landed");
        assert_eq!(got.rejected as usize, names.len());
    }

    #[test]
    fn a_real_pack_still_imports() {
        let _s = pack_store();
        let work = crate::test_tmp::tempdir().unwrap();
        let (real_hash, real_name, real) = blob_entry(real_sticker());
        let manifest = manifest_naming(&[&real_hash]);
        let path = write_pack(work.path(), &pack_zip(&manifest, &[(real_name, real)]));
        assert_eq!(preview_sticker_pack(path.clone()).unwrap().count, 1);
        let got = import_sticker_pack(path, String::new()).unwrap();
        assert_eq!((got.added, got.rejected), (1, 0));
    }

    /// A real one-sticker pack for a fleet run: `HOLLOW_FIXTURE_OUT=<path> cargo test --lib
    /// -- --ignored write_a_real_pack_for_the_fleet`.
    #[test]
    #[ignore = "writes a fleet fixture"]
    fn write_a_real_pack_for_the_fleet() {
        let out = std::env::var("HOLLOW_FIXTURE_OUT").expect("HOLLOW_FIXTURE_OUT");
        let (hash, name, bytes) = blob_entry(real_sticker());
        let mut manifest: PackManifest = serde_json::from_slice(&manifest_naming(&[&hash])).unwrap();
        manifest.pack = "Fleet leaves".into();
        std::fs::write(out, pack_zip(&serde_json::to_vec(&manifest).unwrap(), &[(name, bytes)])).unwrap();
    }

    #[test]
    fn the_pack_caps_match_what_a_pack_may_hold() {
        assert_eq!(pack_blob_cap(), node::assets::AssetKind::Sticker.recv_cap() as u64);
        assert!(pack_unpack_budget() >= MAX_PACK_MANIFEST_BYTES + MAX_STICKERS_PER_PACK as u64 * pack_blob_cap());
        assert!(max_pack_file_bytes() > pack_unpack_budget());
        // The largest manifest an export writes fits under its cap with room to spare.
        let kp = NativeKeypair::from_secret_bytes(&[7u8; 32]);
        let longest = "\u{1F600}".repeat(MAX_STICKER_LABEL);
        let items = (0..MAX_STICKERS_PER_PACK)
            .map(|i| PackItem { hash: hex::encode([i as u8; 32]), name: longest.clone(), animated: true, w: 4096, h: 4096 })
            .collect();
        let full = serde_json::to_vec_pretty(&signed_manifest(&kp, &longest, items)).unwrap();
        assert!((full.len() as u64) * 2 < MAX_PACK_MANIFEST_BYTES, "{} bytes", full.len());
    }

    // t14-zipbomb review round: the zip index is bounded too

    /// A `.hollow-pack` whose index lists `n` entries, all one real, readable manifest.
    fn pack_with_entries(n: usize) -> Vec<u8> {
        crate::zip_budget::zip_listing(n, "manifest.json", br#"{"format_version":1,"pack":"index","items":[]}"#)
    }

    #[test]
    fn a_pack_whose_index_lists_more_entries_than_a_pack_holds_is_refused() {
        let work = crate::test_tmp::tempdir().unwrap();
        let fits = write_pack(work.path(), &pack_with_entries(MAX_PACK_ENTRIES as usize));
        assert_eq!(preview_sticker_pack(fits).unwrap().pack, "index");
        let path = work.path().join("over.hollow-pack");
        std::fs::write(&path, pack_with_entries(MAX_PACK_ENTRIES as usize + 1)).unwrap();
        assert!(preview_sticker_pack(path.to_string_lossy().into_owned()).is_err(), "an index one past a full pack was read");
    }

    /// This process's peak resident memory; 0 where `getrusage` does not exist.
    #[cfg(not(unix))]
    fn peak_rss_mib() -> u64 {
        0
    }

    #[cfg(unix)]
    fn peak_rss_mib() -> u64 {
        // SAFETY: getrusage only writes the struct it is given.
        let mut u: libc::rusage = unsafe { std::mem::zeroed() };
        unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) };
        let raw = u.ru_maxrss as u64;
        if cfg!(target_os = "macos") { raw >> 20 } else { raw >> 10 }
    }

    /// A pack holds a manifest and at most 120 stickers, yet the card opens (and indexes)
    /// any zip under the file cap: a 61 MiB pack listing 1.25 million entries costs every
    /// viewer about 8 times its size, unasked, once per pack card in view.
    #[test]
    fn review_t14_a_pack_listing_far_more_entries_than_a_pack_holds_is_refused() {
        let work = crate::test_tmp::tempdir().unwrap();
        let bytes = pack_with_entries(1_250_000);
        let file_cap = (128u64 << 10) + 120 * 524_288 + (1 << 20);
        assert!((bytes.len() as u64) < file_cap, "the fixture is under the pack file cap: {}", bytes.len());
        let path = work.path().join("index.hollow-pack");
        std::fs::write(&path, &bytes).unwrap();
        drop(bytes);
        let before = peak_rss_mib();
        let got = preview_sticker_pack(path.to_string_lossy().into_owned());
        let after = peak_rss_mib();
        assert!(
            got.is_err(),
            "a pack listing 1.25M zip entries was opened and previewed (peak RSS {before} -> {after} MiB)"
        );
        // The peak is process-wide, so it is this test's alone only when nextest gives
        // each test its own process; under a shared `cargo test` process another test
        // could raise it.
        if std::env::var("NEXTEST_EXECUTION_MODE").as_deref() == Ok("process-per-test") {
            assert!(after.saturating_sub(before) < 96, "previewing the refused pack raised peak RSS {before} -> {after} MiB");
        }
    }
}
