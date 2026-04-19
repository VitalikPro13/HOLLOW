// Hollow Share — Phase 7A backend.
//
// Private, encrypted, zero-tracker file sharing built on the existing relay
// rooms + WebRTC data channel pipeline. See the plan at
// ~/.claude/plans/yeah-better-to-have-composed-haven.md for the full design.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

#[allow(unused_imports)]
use crate::hollow_log;
use crate::identity::native_identity::NativeKeypair;
use crate::storage::messages::MessageStore;

use super::types::{HavenMessage, NetworkEvent, ShareEntryRef, ShareManifest};
use super::ws_client::WsCommand;

// ── Constants ────────────────────────────────────────────────────────────

/// Bytes per chunk. Matches the existing 256 KiB framing in ws_stream_transfer.
pub const CHUNK_SIZE: u32 = 262_144;

/// Manifest format version (bump if hash domain or nonce derivation changes).
const MANIFEST_VERSION: u16 = 1;

/// Share link envelope version. Layout: [version:1][root_hash:32][key:32].
const LINK_VERSION: u8 = 1;

/// Prefix for share swarm room IDs on the relay.
const SHARE_ROOM_PREFIX: &str = "share:";

/// URL scheme + path prefix for share links.
const LINK_SCHEME_PREFIX: &str = "hollow://share/";

// ── Link codec ───────────────────────────────────────────────────────────

/// What we extract from a `hollow://share/...` link.
#[derive(Debug, Clone)]
pub struct ShareLinkInfo {
    pub root_hash: [u8; 32],
    pub key: [u8; 32],
}

impl ShareLinkInfo {
    pub fn root_hash_hex(&self) -> String { hex::encode(self.root_hash) }
    pub fn room_id(&self) -> String { format!("{SHARE_ROOM_PREFIX}{}", self.root_hash_hex()) }
}

/// Build a share link from a root hash + key.
pub fn encode_link(root_hash: &[u8; 32], key: &[u8; 32]) -> String {
    let mut buf = Vec::with_capacity(1 + 32 + 32);
    buf.push(LINK_VERSION);
    buf.extend_from_slice(root_hash);
    buf.extend_from_slice(key);
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&buf);
    format!("{LINK_SCHEME_PREFIX}{b64}")
}

/// Parse a share link. Returns the root hash and decryption key, or an error.
pub fn decode_link(link: &str) -> Result<ShareLinkInfo, String> {
    let payload_b64 = link.strip_prefix(LINK_SCHEME_PREFIX)
        .ok_or_else(|| format!("Share link missing scheme '{LINK_SCHEME_PREFIX}'"))?;
    let buf = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64.as_bytes())
        .map_err(|e| format!("Share link not valid base64url: {e}"))?;
    if buf.len() != 1 + 32 + 32 {
        return Err(format!("Share link wrong length: got {}, expected {}", buf.len(), 1 + 32 + 32));
    }
    if buf[0] != LINK_VERSION {
        return Err(format!("Unsupported share link version: {} (expected {LINK_VERSION})", buf[0]));
    }
    let mut root_hash = [0u8; 32];
    root_hash.copy_from_slice(&buf[1..33]);
    let mut key = [0u8; 32];
    key.copy_from_slice(&buf[33..65]);
    Ok(ShareLinkInfo { root_hash, key })
}

// ── Crypto helpers ───────────────────────────────────────────────────────

/// Derive the AES-256-GCM nonce for a chunk: [0;4] || chunk_index_be:8.
/// Index uniqueness guarantees nonce uniqueness for the lifetime of the key.
fn chunk_nonce(chunk_index: u32) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    let idx64: u64 = chunk_index as u64;
    nonce[4..12].copy_from_slice(&idx64.to_be_bytes());
    nonce
}

/// Encrypt one chunk of plaintext with the share's per-link key.
fn encrypt_chunk(key: &[u8; 32], chunk_index: u32, plaintext: &[u8]) -> Result<Vec<u8>, String> {
    use aes_gcm::aead::Aead;
    use aes_gcm::{Aes256Gcm, Key, KeyInit, Nonce};
    let aes_key = Key::<Aes256Gcm>::from(*key);
    let cipher = Aes256Gcm::new(&aes_key);
    let nonce = chunk_nonce(chunk_index);
    let nonce = Nonce::from(nonce);
    cipher.encrypt(&nonce, plaintext)
        .map_err(|e| format!("AES-GCM encrypt chunk failed: {e}"))
}

/// Decrypt one chunk. Returns Err if the auth tag doesn't verify (wrong key
/// or tampered data).
fn decrypt_chunk(key: &[u8; 32], chunk_index: u32, ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    let nonce = chunk_nonce(chunk_index);
    crate::vault::pipeline::aes_decrypt(ciphertext, key, &nonce)
}

// ── Misc helpers ─────────────────────────────────────────────────────────

/// Open a fresh MessageStore for this handler call. Returns None on failure.
/// Held only inside the call (never across `.await`) so the swarm event loop
/// future stays Send.
fn open_message_store(bundle_keypair: &NativeKeypair) -> Option<MessageStore> {
    let data_dir = crate::identity::data_dir().ok()?;
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let proto = bundle_keypair.to_protobuf_encoding().ok()?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    MessageStore::open(&db_path, &passphrase).ok()
}

fn now_unix_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Tiny extension-based MIME guess. Sufficient for share UI hints; receivers
/// don't trust this for security.
fn guess_mime_from_path(path: &str) -> String {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "png"  => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif"  => "image/gif",
        "webp" => "image/webp",
        "mp4"  => "video/mp4",
        "webm" => "video/webm",
        "mkv"  => "video/x-matroska",
        "mov"  => "video/quicktime",
        "mp3"  => "audio/mpeg",
        "ogg"  => "audio/ogg",
        "wav"  => "audio/wav",
        "flac" => "audio/flac",
        "pdf"  => "application/pdf",
        "zip"  => "application/zip",
        "txt" | "log" | "md" => "text/plain",
        "json" => "application/json",
        _      => "application/octet-stream",
    }.to_string()
}

// ── Storage layout ───────────────────────────────────────────────────────

/// `~/.hollow/shares/`.
pub(crate) fn shares_dir() -> Result<PathBuf, String> {
    let data_dir = crate::identity::data_dir()
        .map_err(|e| format!("data_dir: {e}"))?;
    let dir = data_dir.join("shares");
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("create shares dir: {e}"))?;
    Ok(dir)
}

fn partial_path_in(dir: &std::path::Path, root_hash_hex: &str) -> PathBuf {
    dir.join(format!("{root_hash_hex}.partial"))
}

fn final_path_in(dir: &std::path::Path, root_hash_hex: &str, ext: &str) -> PathBuf {
    let name = if ext.is_empty() {
        root_hash_hex.to_string()
    } else {
        format!("{root_hash_hex}.{ext}")
    };
    dir.join(name)
}

fn partial_path(root_hash_hex: &str) -> Result<PathBuf, String> {
    Ok(partial_path_in(&shares_dir()?, root_hash_hex))
}

fn final_path(root_hash_hex: &str, ext: &str) -> Result<PathBuf, String> {
    Ok(final_path_in(&shares_dir()?, root_hash_hex, ext))
}

// ── Bitmap (compact Have representation) ─────────────────────────────────

/// Simple bitmap. Bit i set iff we hold chunk i. Stored MSB-first within each byte.
#[derive(Clone)]
pub struct ChunkBitmap {
    bits: Vec<u8>,
    chunk_count: u32,
}

impl ChunkBitmap {
    pub fn empty(chunk_count: u32) -> Self {
        let bytes = (chunk_count as usize).div_ceil(8);
        Self { bits: vec![0u8; bytes], chunk_count }
    }

    pub fn from_bytes(bits: Vec<u8>, chunk_count: u32) -> Self {
        let needed = (chunk_count as usize).div_ceil(8);
        let mut bits = bits;
        if bits.len() < needed { bits.resize(needed, 0); } else { bits.truncate(needed); }
        let trailing = chunk_count % 8;
        if trailing > 0 && !bits.is_empty() {
            let mask = !0u8 << (8 - trailing);
            *bits.last_mut().unwrap() &= mask;
        }
        Self { bits, chunk_count }
    }

    pub fn as_bytes(&self) -> &[u8] { &self.bits }

    pub fn has(&self, idx: u32) -> bool {
        if idx >= self.chunk_count { return false; }
        let byte = (idx / 8) as usize;
        let bit  = 7 - (idx % 8) as u8;
        (self.bits[byte] >> bit) & 1 == 1
    }

    pub fn set(&mut self, idx: u32) {
        if idx >= self.chunk_count { return; }
        let byte = (idx / 8) as usize;
        let bit  = 7 - (idx % 8) as u8;
        self.bits[byte] |= 1 << bit;
    }

    pub fn count_set(&self) -> u32 {
        let mut n = 0u32;
        for b in &self.bits { n += b.count_ones(); }
        n.min(self.chunk_count)
    }

    pub fn is_complete(&self) -> bool { self.count_set() >= self.chunk_count }
}

// ── Per-share swarm state ────────────────────────────────────────────────

/// Scheduling constants.
pub const HAVE_REBROADCAST_INTERVAL: Duration = Duration::from_secs(10);
pub const CHUNK_REQUEST_TIMEOUT: Duration = Duration::from_secs(8);
pub const MAX_INFLIGHT_PER_PEER: usize = 4;
/// Speed measurement window: bytes received in the last N seconds.
const SPEED_WINDOW_SECS: f64 = 3.0;
/// Outbound seeding cap. Refill rate in bytes/sec, max burst in bytes.
/// 20 MiB/s with 40 MiB burst. The coexistence pause (200ms after messaging)
/// already protects real-time traffic; the bucket just prevents runaway saturation.
const SEED_REFILL_BPS: u64 = 20 * 1024 * 1024;
const SEED_BURST_BYTES: u64 = 40 * 1024 * 1024;
/// Pause share scheduling for this long after any messaging/voice traffic.
pub const COEXIST_PAUSE: Duration = Duration::from_millis(200);

/// In-memory state for one active share. Persisted projection lives in the
/// `shares` + `share_chunks` SQL tables.
pub struct ShareSwarmState {
    pub root_hash: [u8; 32],
    pub key: [u8; 32],
    pub manifest: Option<ShareManifest>,
    /// Original file extension (so we can rename .partial → .<ext> on completion).
    pub file_ext: String,
    /// Where downloaded files land. None until ShareStart provides it (or auto-rejoin loads it).
    pub save_dir: Option<PathBuf>,
    pub have: ChunkBitmap,
    /// Sparse partial file for downloads, or the final completed file when seeding.
    pub data_file: Option<File>,
    pub seeding: bool,
    pub bytes_uploaded: u64,
    pub bytes_downloaded: u64,
    /// Per-peer Have bitmaps learned from `ShareHave` envelopes. Used by the
    /// scheduler tick to do rarest-first piece selection.
    pub peer_have: HashMap<String, ChunkBitmap>,
    /// Currently outstanding chunk requests: chunk_idx → (peer_id, requested_at).
    /// Timed out after CHUNK_REQUEST_TIMEOUT and re-requested via the scheduler.
    pub inflight: HashMap<u32, (String, Instant)>,
    /// When we last sent our own Have bitmap into the swarm room.
    pub last_have_broadcast: Instant,
    /// Sliding window of (timestamp, bytes) for speed calculation.
    pub speed_samples: Vec<(Instant, usize)>,
    /// Cached speed value (bytes/sec) recomputed each chunk arrival.
    pub speed_bps: u64,
    /// When we sent the manifest request (for timeout detection). None for seeders.
    pub manifest_requested_at: Option<Instant>,
    /// Last time we emitted a ShareSeedingChanged event (throttle to ~2s).
    pub last_seeding_emit: Instant,
}

impl ShareSwarmState {
    pub fn root_hash_hex(&self) -> String { hex::encode(self.root_hash) }
    pub fn room_id(&self) -> String { format!("{SHARE_ROOM_PREFIX}{}", self.root_hash_hex()) }
}

/// Registry of active share swarms keyed by root_hash hex. Owned by the
/// swarm event loop in spawn_node and passed as `&mut` to every handler —
/// matches the pattern used by file_handler / vault_ops / voice_handler.
pub type ShareRegistry = HashMap<String, ShareSwarmState>;

pub fn new_registry() -> ShareRegistry { HashMap::new() }

// ── Manifest helpers ─────────────────────────────────────────────────────

/// Compute the SHA-256 root hash of a manifest by serializing to canonical JSON
/// and hashing the bytes. The JSON form goes on the wire as
/// HavenMessage::ShareManifestResponse.manifest_b64.
pub fn manifest_root_hash(manifest_bytes: &[u8]) -> [u8; 32] {
    let h = Sha256::digest(manifest_bytes);
    let mut out = [0u8; 32];
    out.copy_from_slice(&h);
    out
}

/// Build a manifest from a plaintext file on disk. Encrypts each chunk
/// transiently to compute SHA-256(ciphertext) hashes for the manifest, but
/// does NOT keep the ciphertexts — chunks are encrypted on-the-fly when served.
pub fn build_manifest_from_file(
    source_path: &str,
    key: &[u8; 32],
) -> Result<ShareManifest, String> {
    let meta = std::fs::metadata(source_path)
        .map_err(|e| format!("stat source: {e}"))?;
    let total_size = meta.len();
    if total_size == 0 {
        return Err("Cannot share an empty file".to_string());
    }
    let chunk_count_u64 = total_size.div_ceil(CHUNK_SIZE as u64);
    if chunk_count_u64 > u32::MAX as u64 {
        return Err(format!("File too large: {chunk_count_u64} chunks > u32::MAX"));
    }
    let chunk_count = chunk_count_u64 as u32;

    let file_name = std::path::Path::new(source_path)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "share".to_string());
    let mime = guess_mime_from_path(source_path);

    let mut f = File::open(source_path)
        .map_err(|e| format!("open source: {e}"))?;
    let mut hashes: Vec<[u8; 32]> = Vec::with_capacity(chunk_count as usize);
    let mut buf = vec![0u8; CHUNK_SIZE as usize];

    for idx in 0..chunk_count {
        let want = if idx == chunk_count - 1 {
            (total_size - (idx as u64) * CHUNK_SIZE as u64) as usize
        } else {
            CHUNK_SIZE as usize
        };
        let slice = &mut buf[..want];
        f.read_exact(slice)
            .map_err(|e| format!("read chunk {idx}: {e}"))?;
        let ct = encrypt_chunk(key, idx, slice)?;
        let mut h = [0u8; 32];
        h.copy_from_slice(&Sha256::digest(&ct));
        hashes.push(h);
    }

    Ok(ShareManifest {
        version: MANIFEST_VERSION,
        file_name,
        mime,
        total_size,
        chunk_size: CHUNK_SIZE,
        chunk_count,
        chunk_hashes: hashes,
        created_at: SystemTime::now().duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs()).unwrap_or(0),
        note: None,
    })
}

// ── Command handlers (called from swarm.rs) ──────────────────────────────

/// Handle NodeCommand::ShareCreate.
///
/// Reads the source file to build the manifest (hash each chunk's ciphertext),
/// then stores the ORIGINAL file path — no copy. Chunks are encrypted on-the-fly
/// when peers request them.
pub async fn handle_command_share_create(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    source_path: String,
) {
    let mut key = [0u8; 32];
    if let Err(e) = getrandom::fill(&mut key) {
        let _ = event_tx.send(NetworkEvent::ShareFailed {
            root_hash: String::new(),
            error: format!("Failed to generate share key: {e}"),
        }).await;
        return;
    }

    let manifest = match build_manifest_from_file(&source_path, &key) {
        Ok(v) => v,
        Err(e) => {
            let _ = event_tx.send(NetworkEvent::ShareFailed {
                root_hash: String::new(), error: e,
            }).await;
            return;
        }
    };

    let manifest_bytes = match serde_json::to_vec(&manifest) {
        Ok(b) => b,
        Err(e) => {
            let _ = event_tx.send(NetworkEvent::ShareFailed {
                root_hash: String::new(),
                error: format!("Manifest serialize: {e}"),
            }).await;
            return;
        }
    };
    let root_hash = manifest_root_hash(&manifest_bytes);
    let root_hash_hex = hex::encode(root_hash);
    let link = encode_link(&root_hash, &key);

    let file_ext = std::path::Path::new(&source_path)
        .extension()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();

    let manifest_json = match serde_json::to_string(&manifest) {
        Ok(s) => s,
        Err(e) => {
            let _ = event_tx.send(NetworkEvent::ShareFailed {
                root_hash: root_hash_hex.clone(),
                error: format!("Manifest stringify: {e}"),
            }).await;
            return;
        }
    };
    let now = now_unix_secs() as i64;
    if let Some(store) = open_message_store(bundle_keypair) {
        let save_dir_str = std::path::Path::new(&source_path)
            .parent()
            .map(|p| p.to_string_lossy().to_string());
        if let Err(e) = store.upsert_share(
            &root_hash_hex,
            &manifest.file_name,
            &file_ext,
            &manifest.mime,
            manifest.total_size,
            manifest.chunk_size,
            manifest.chunk_count,
            &manifest_json,
            &key,
            &link,
            "completed",
            true,
            Some(&source_path),
            save_dir_str.as_deref(),
            now,
        ) {
            hollow_log!("[SHARE] upsert_share failed: {e}");
        }
        let _ = store.mark_share_complete(&root_hash_hex, &source_path, now);
    }

    let mut have = ChunkBitmap::empty(manifest.chunk_count);
    for i in 0..manifest.chunk_count { have.set(i); }
    let data_file = OpenOptions::new().read(true).open(&source_path).ok();
    let now_inst = Instant::now();
    let state = ShareSwarmState {
        root_hash,
        key,
        manifest: Some(manifest.clone()),
        file_ext,
        save_dir: std::path::Path::new(&source_path).parent().map(PathBuf::from),
        have,
        data_file,
        seeding: true,
        bytes_uploaded: 0,
        bytes_downloaded: 0,
        peer_have: HashMap::new(),
        inflight: HashMap::new(),
        last_have_broadcast: now_inst,
        speed_samples: Vec::new(),
        speed_bps: 0,
        manifest_requested_at: None,
        last_seeding_emit: now_inst,
    };
    let room = state.room_id();
    registry.insert(root_hash_hex.clone(), state);

    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: room });

    let _ = event_tx.send(NetworkEvent::ShareCreated {
        root_hash: root_hash_hex,
        link,
        file_name: manifest.file_name,
        total_size: manifest.total_size,
    }).await;
}

/// Handle NodeCommand::ShareOpenLink.
///
/// Pure probe: decodes the link, joins the swarm room, requests the manifest.
/// Does NOT create a DB entry or start downloading — that happens only when
/// the user presses Download (ShareStart). Creates a minimal registry entry
/// only for manifest timeout tracking.
pub async fn handle_command_share_open_link(
    registry: &mut ShareRegistry,
    _bundle_keypair: &NativeKeypair,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    link: String,
) {
    let info = match decode_link(&link) {
        Ok(i) => i,
        Err(e) => {
            let _ = event_tx.send(NetworkEvent::ShareFailed {
                root_hash: String::new(), error: e,
            }).await;
            return;
        }
    };
    let root_hash_hex = info.root_hash_hex();

    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: info.room_id() });

    if let Ok(payload) = serde_json::to_vec(&HavenMessage::ShareManifestRequest {
        root_hash: root_hash_hex.clone(),
    }) {
        let _ = ws_cmd_tx.send(WsCommand::SendToRoom {
            room_code: info.room_id(),
            data: payload,
        });
    }

    let now_inst = Instant::now();
    if !registry.contains_key(&root_hash_hex) {
        registry.insert(root_hash_hex, ShareSwarmState {
            root_hash: info.root_hash,
            key: info.key,
            manifest: None,
            file_ext: String::new(),
            save_dir: None,
            have: ChunkBitmap::empty(0),
            data_file: None,
            seeding: false,
            bytes_uploaded: 0,
            bytes_downloaded: 0,
            peer_have: HashMap::new(),
            inflight: HashMap::new(),
            last_have_broadcast: now_inst,
            speed_samples: Vec::new(),
            speed_bps: 0,
            manifest_requested_at: Some(now_inst),
            last_seeding_emit: now_inst,
        });
    }
}

/// Handle NodeCommand::ShareList.
pub async fn handle_command_share_list(
    bundle_keypair: &NativeKeypair,
    registry: &mut ShareRegistry,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    let rows = {
        let Some(store) = open_message_store(bundle_keypair) else { return; };
        match store.load_shares() {
            Ok(v) => v,
            Err(e) => {
                hollow_log!("[SHARE] load_shares failed: {e}");
                return;
            }
        }
    };
    // Auto-clean stale/unknown entries from DB + orphaned temp files.
    {
        let store_cleanup = open_message_store(bundle_keypair);
        for s in &rows {
            let is_stale = s.state == "stale";
            let is_orphan_unknown = s.file_name == "(unknown)" && s.state == "downloading"
                && s.chunk_count == 0 && !registry.contains_key(&s.root_hash);
            if is_stale || is_orphan_unknown {
                if let Some(ref store) = store_cleanup {
                    let _ = store.delete_share(&s.root_hash);
                }
                registry.remove(&s.root_hash);
            }
        }
    }
    // Clean orphaned .send_*.tmp files that aren't for any active share.
    if let Ok(dir) = shares_dir() {
        if let Ok(entries_iter) = std::fs::read_dir(&dir) {
            for entry in entries_iter.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with(".send_") && name.ends_with(".tmp") {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
    }
    let entries: Vec<ShareEntryRef> = rows.into_iter()
        .filter(|s| s.state != "stale")
        .map(|s| {
        let (chunks_have, chunks_total) = if let Some(state) = registry.get(&s.root_hash) {
            (state.have.count_set(), state.have.chunk_count)
        } else {
            // Not loaded; estimate from completion state.
            let total = s.chunk_count;
            let have = if s.state == "completed" { total } else { 0 };
            (have, total)
        };
        ShareEntryRef {
            root_hash: s.root_hash,
            file_name: s.file_name,
            total_size: s.total_size,
            chunks_have,
            chunks_total,
            state: s.state,
            seeding: s.seeding,
            disk_path: s.disk_path,
            bytes_uploaded: s.bytes_uploaded,
            share_link: s.share_link,
            created_at: s.created_at,
        }
    }).collect();
    let _ = event_tx.send(NetworkEvent::ShareList { entries }).await;
}

/// Handle NodeCommand::ShareSetSeeding.
pub async fn handle_command_share_set_seeding(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    root_hash: String,
    seeding: bool,
) {
    if let Some(store) = open_message_store(bundle_keypair) {
        let _ = store.set_share_seeding(&root_hash, seeding);
    }
    let room = format!("{SHARE_ROOM_PREFIX}{root_hash}");
    let bytes_uploaded = if let Some(state) = registry.get_mut(&root_hash) {
        state.seeding = seeding;
        if seeding {
            if state.data_file.is_none() {
                let disk_path = open_message_store(bundle_keypair)
                    .and_then(|store| store.load_share(&root_hash).ok().flatten())
                    .and_then(|s| s.disk_path);
                if let Some(path) = disk_path {
                    state.data_file = OpenOptions::new().read(true).open(&path).ok();
                }
            }
            let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: room });
        } else {
            let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: room });
        }
        state.bytes_uploaded
    } else {
        return;
    };
    let _ = event_tx.send(NetworkEvent::ShareSeedingChanged {
        root_hash, seeding, peers: 0, bytes_uploaded,
    }).await;
}

/// Handle NodeCommand::ShareCancel — leaves the room, drops swarm state,
/// deletes the .partial file, removes the DB entry, and notifies the UI.
/// If the share is already seeding (user opened their own link), only dismiss
/// the probe without destroying the active seed.
pub async fn handle_command_share_cancel(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    root_hash: String,
) {
    if let Some(state) = registry.get(&root_hash) {
        if state.seeding {
            let _ = event_tx.send(NetworkEvent::ShareFailed {
                root_hash, error: "Cancelled".to_string(),
            }).await;
            return;
        }
    }
    let room = format!("{SHARE_ROOM_PREFIX}{root_hash}");
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: room });
    if let Some(mut state) = registry.remove(&root_hash) {
        state.data_file = None;
    }
    if let Ok(dir) = shares_dir() {
        let partial = partial_path_in(&dir, &root_hash);
        let _ = std::fs::remove_file(&partial);
    }
    if let Some(store) = open_message_store(bundle_keypair) {
        let _ = store.delete_share(&root_hash);
    }
    let _ = event_tx.send(NetworkEvent::ShareFailed {
        root_hash, error: "Cancelled".to_string(),
    }).await;
}

/// Handle NodeCommand::ShareRemove.
pub async fn handle_command_share_remove(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    root_hash: String,
    delete_file: bool,
) {
    let room = format!("{SHARE_ROOM_PREFIX}{root_hash}");
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: room });
    registry.remove(&root_hash);
    if let Some(store) = open_message_store(bundle_keypair) {
        if delete_file && let Ok(Some(s)) = store.load_share(&root_hash) {
            if let Some(p) = s.disk_path {
                let _ = std::fs::remove_file(&p);
            }
            if let Ok(p) = partial_path(&root_hash) {
                let _ = std::fs::remove_file(&p);
            }
        }
        let _ = store.delete_share(&root_hash);
    }
}

/// Handle NodeCommand::ShareStart — register the swarm state and let the
/// scheduler tick (run from swarm.rs) drive chunk requests.
///
/// `save_dir` overrides the default `~/.hollow/shares/` location for both the
/// in-progress `.partial` and the renamed final file. Empty string falls back
/// to the default. The chosen dir is persisted to the share row so a paused
/// download resumes to the same place after app restart.
pub async fn handle_command_share_start(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    root_hash: String,
    save_dir: String,
) {
    // The probe (ShareOpenLink) already cached the manifest in the registry.
    let Some(state) = registry.get(&root_hash) else {
        let _ = event_tx.send(NetworkEvent::ShareFailed {
            root_hash, error: "Open the share link first".to_string(),
        }).await;
        return;
    };
    let Some(manifest) = state.manifest.clone() else {
        let _ = event_tx.send(NetworkEvent::ShareFailed {
            root_hash, error: "Manifest not yet received".to_string(),
        }).await;
        return;
    };
    let key = state.key;
    let file_ext = state.file_ext.clone();

    // Resolve save_dir.
    let resolved_dir: PathBuf = if !save_dir.trim().is_empty() {
        PathBuf::from(save_dir.trim())
    } else {
        match shares_dir() {
            Ok(d) => d,
            Err(e) => {
                let _ = event_tx.send(NetworkEvent::ShareFailed { root_hash, error: e }).await;
                return;
            }
        }
    };
    if let Err(e) = std::fs::create_dir_all(&resolved_dir) {
        let _ = event_tx.send(NetworkEvent::ShareFailed {
            root_hash, error: format!("create save_dir: {e}"),
        }).await;
        return;
    }

    // Create DB entry now (deferred from open_link).
    let manifest_json = serde_json::to_string(&manifest).unwrap_or_default();
    let now = now_unix_secs() as i64;
    if let Some(store) = open_message_store(bundle_keypair) {
        let _ = store.upsert_share(
            &root_hash,
            &manifest.file_name,
            &file_ext,
            &manifest.mime,
            manifest.total_size,
            manifest.chunk_size,
            manifest.chunk_count,
            &manifest_json,
            &key,
            "",
            "downloading",
            false,
            None,
            Some(&resolved_dir.to_string_lossy()),
            now,
        );
    }

    // Prepare the partial file.
    let p = partial_path_in(&resolved_dir, &root_hash);
    let file = match (|| -> Result<File, String> {
        let f = OpenOptions::new().read(true).write(true).create(true).truncate(false)
            .open(&p).map_err(|e| format!("open partial: {e}"))?;
        f.set_len(manifest.total_size).map_err(|e| format!("set_len: {e}"))?;
        Ok(f)
    })() {
        Ok(f) => f,
        Err(e) => {
            let _ = event_tx.send(NetworkEvent::ShareFailed { root_hash, error: e }).await;
            return;
        }
    };

    // Update the existing registry entry to start downloading.
    let save_dir = Some(resolved_dir);
    if let Some(state) = registry.get_mut(&root_hash) {
        state.data_file = Some(file);
        state.save_dir = save_dir;
        state.have = ChunkBitmap::empty(manifest.chunk_count);
        state.manifest_requested_at = None;
    }
    let room = format!("{SHARE_ROOM_PREFIX}{root_hash}");
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: room });

    broadcast_have(registry, ws_cmd_tx, &root_hash).await;
}

/// Re-broadcast our Have bitmap so peers know what chunks we can serve.
pub async fn broadcast_have(
    registry: &mut ShareRegistry,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    root_hash: &str,
) {
    let Some(state) = registry.get(root_hash) else { return; };
    let bitmap_b64 = base64::engine::general_purpose::STANDARD.encode(state.have.as_bytes());
    let chunk_count = state.have.chunk_count;
    let room = state.room_id();
    if let Ok(payload) = serde_json::to_vec(&HavenMessage::ShareHave {
        root_hash: root_hash.to_string(),
        bitmap_b64,
        chunk_count,
    }) {
        let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: room, data: payload });
    }
}

// ── Auto-rejoin on startup ───────────────────────────────────────────────

/// Called once from spawn_node after the registry is created. Walks the
/// `shares` table for rows with `state='completed' AND seeding=1` and
/// rebuilds in-memory state for each, then sends `JoinRoom` so we start
/// serving chunks immediately. Without this, restarting the app would
/// silently kill all seeding.
pub fn auto_rejoin_seeders(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
) {
    let Some(store) = open_message_store(bundle_keypair) else { return; };
    let rows = match store.load_shares() {
        Ok(v) => v,
        Err(e) => { hollow_log!("[SHARE] auto_rejoin: load_shares failed: {e}"); return; }
    };
    let mut joined = 0usize;
    for stored in rows {
        if stored.state != "completed" || !stored.seeding { continue; }
        let manifest: ShareManifest = match serde_json::from_str(&stored.manifest_json) {
            Ok(m) => m,
            Err(_) => continue,
        };
        let Some(disk_path) = stored.disk_path.as_ref() else { continue; };
        let data_file = match OpenOptions::new().read(true).open(disk_path) {
            Ok(f) => f,
            Err(_) => {
                hollow_log!("[SHARE] auto_rejoin: file missing for {} — marking stale", stored.root_hash);
                let _ = store.set_share_seeding(&stored.root_hash, false);
                let _ = store.set_share_state(&stored.root_hash, "stale");
                continue;
            }
        };
        if stored.encryption_key.len() != 32 { continue; }
        let mut key = [0u8; 32];
        key.copy_from_slice(&stored.encryption_key);
        let mut root = [0u8; 32];
        match hex::decode(&stored.root_hash) {
            Ok(b) if b.len() == 32 => root.copy_from_slice(&b),
            _ => continue,
        }

        // Full Have bitmap (we have everything — we're a completed seed).
        let mut have = ChunkBitmap::empty(manifest.chunk_count);
        for i in 0..manifest.chunk_count { have.set(i); }

        let now_inst = Instant::now();
        let state = ShareSwarmState {
            root_hash: root,
            key,
            manifest: Some(manifest),
            file_ext: stored.file_ext,
            save_dir: stored.save_dir.map(PathBuf::from),
            have,
            data_file: Some(data_file),
            seeding: true,
            bytes_uploaded: stored.bytes_uploaded,
            bytes_downloaded: 0,
            peer_have: HashMap::new(),
            inflight: HashMap::new(),
            last_have_broadcast: now_inst.checked_sub(HAVE_REBROADCAST_INTERVAL).unwrap_or(now_inst),
            speed_samples: Vec::new(),
            speed_bps: 0,
            manifest_requested_at: None,
            last_seeding_emit: now_inst,
        };
        let room = state.room_id();
        registry.insert(stored.root_hash.clone(), state);
        let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: room });
        joined += 1;
    }
    if joined > 0 {
        hollow_log!("[SHARE] auto-rejoined {joined} seeding share(s)");
    }
}

// ── Outbound seed bandwidth bucket ───────────────────────────────────────

/// Process-wide token bucket for share seeding bytes. Single instance owned by
/// the swarm event loop; passed by `&mut` into chunk-request handling and the
/// scheduler tick. Refills SEED_REFILL_BPS bytes/sec, capped at SEED_BURST_BYTES.
pub struct SeedBudget {
    tokens: f64,
    last_refill: Instant,
}

impl Default for SeedBudget {
    fn default() -> Self { Self::new() }
}

impl SeedBudget {
    pub fn new() -> Self {
        Self { tokens: SEED_BURST_BYTES as f64, last_refill: Instant::now() }
    }
    fn refill(&mut self) {
        let now = Instant::now();
        let dt = now.duration_since(self.last_refill).as_secs_f64();
        self.tokens = (self.tokens + dt * SEED_REFILL_BPS as f64).min(SEED_BURST_BYTES as f64);
        self.last_refill = now;
    }
    /// Consume `bytes` if available. Returns true on success, false if the
    /// caller should defer (no partial consumption).
    pub fn try_consume(&mut self, bytes: u64) -> bool {
        self.refill();
        if (bytes as f64) <= self.tokens {
            self.tokens -= bytes as f64;
            true
        } else {
            false
        }
    }
}

// ── Scheduler tick ───────────────────────────────────────────────────────

/// Driven once per second from the swarm main loop. Three jobs:
///
///   1. Re-broadcast our Have bitmap into each share room every 10s so peers
///      learn about chunks we acquire after the initial join.
///   2. Time out in-flight chunk requests older than CHUNK_REQUEST_TIMEOUT —
///      forget them so the rarest-first picker can re-issue against another peer.
///   3. For each downloading share, pick rarest chunks not yet in `have` and
///      not in-flight, and send `ShareChunkRequest` to peers that hold them.
///      Caps in-flight per peer at MAX_INFLIGHT_PER_PEER.
///
/// `messaging_active` is set true if voice/message traffic happened in the
/// last COEXIST_PAUSE window — when true, we skip new chunk requests this
/// tick (Have rebroadcast and timeout still run).
pub async fn tick(
    registry: &mut ShareRegistry,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    messaging_active: bool,
    webrtc_peers: &std::collections::HashSet<String>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    bundle_keypair: &NativeKeypair,
) {
    let now = Instant::now();
    let root_hashes: Vec<String> = registry.keys().cloned().collect();

    // 0. Manifest request timeout + seeding progress + stale cleanup.
    let mut to_remove: Vec<String> = Vec::new();
    for rh in &root_hashes {
        let Some(state) = registry.get_mut(rh) else { continue; };

        // Manifest timeout: if no manifest after 10s, emit failure.
        if state.manifest.is_none() {
            if let Some(req_at) = state.manifest_requested_at {
                if now.duration_since(req_at) >= Duration::from_secs(10) {
                    let _ = event_tx.send(NetworkEvent::ShareFailed {
                        root_hash: rh.clone(),
                        error: "No seeders found".to_string(),
                    }).await;
                    to_remove.push(rh.clone());
                }
            }
            continue;
        }

        // Stale file check: if seeding but source file is gone, mark stale.
        if state.seeding && state.data_file.is_none() {
            state.seeding = false;
            if let Some(store) = open_message_store(bundle_keypair) {
                let _ = store.set_share_seeding(rh, false);
                let _ = store.set_share_state(rh, "stale");
            }
            let _ = event_tx.send(NetworkEvent::ShareSeedingChanged {
                root_hash: rh.clone(),
                seeding: false,
                peers: 0,
                bytes_uploaded: state.bytes_uploaded,
            }).await;
            continue;
        }

        // Periodic seeding progress emit (~every 2s).
        if state.seeding && now.duration_since(state.last_seeding_emit) >= Duration::from_secs(2) {
            state.last_seeding_emit = now;
            let peers = state.peer_have.len().min(u8::MAX as usize) as u8;
            let _ = event_tx.send(NetworkEvent::ShareSeedingChanged {
                root_hash: rh.clone(),
                seeding: true,
                peers,
                bytes_uploaded: state.bytes_uploaded,
            }).await;
        }
    }
    for rh in &to_remove {
        registry.remove(rh);
    }

    for root_hash in root_hashes {
        if to_remove.contains(&root_hash) { continue; }
        // 1. Have rebroadcast.
        let do_rebroadcast = registry.get(&root_hash)
            .map(|s| now.duration_since(s.last_have_broadcast) >= HAVE_REBROADCAST_INTERVAL)
            .unwrap_or(false);
        if do_rebroadcast {
            broadcast_have(registry, ws_cmd_tx, &root_hash).await;
            if let Some(state) = registry.get_mut(&root_hash) {
                state.last_have_broadcast = now;
            }
        }

        // 2. Timeout in-flight requests.
        if let Some(state) = registry.get_mut(&root_hash) {
            state.inflight.retain(|_, (_, requested_at)| {
                now.duration_since(*requested_at) < CHUNK_REQUEST_TIMEOUT
            });
        }

        // 3. Schedule new chunk requests (skip if messaging is busy or share is
        // a pure seed with nothing to fetch, or download hasn't started yet).
        if messaging_active { continue; }
        let Some(state) = registry.get(&root_hash) else { continue; };
        if state.have.is_complete() { continue; }
        let Some(ref manifest) = state.manifest else { continue; };
        if state.data_file.is_none() { continue; }
        if state.peer_have.is_empty() { continue; }

        // Request WebRTC connections for peers we know about but aren't connected to.
        for peer_id in state.peer_have.keys() {
            if !webrtc_peers.contains(peer_id.as_str()) {
                let _ = event_tx.send(NetworkEvent::ShareNeedWebRtc {
                    peer_id: peer_id.clone(),
                }).await;
            }
        }

        // Build (chunk_idx → Vec<peer_id_who_has_it>) for chunks we need.
        // Sort by Vec.len() ascending = rarest first.
        let chunk_count = manifest.chunk_count;
        let mut needed: Vec<(u32, Vec<String>)> = Vec::with_capacity(chunk_count as usize);
        for idx in 0..chunk_count {
            if state.have.has(idx) { continue; }
            if state.inflight.contains_key(&idx) { continue; }
            let mut owners: Vec<String> = state.peer_have.iter()
                .filter_map(|(p, bm)| {
                    if bm.has(idx) && webrtc_peers.contains(p.as_str()) { Some(p.clone()) } else { None }
                })
                .collect();
            if !owners.is_empty() {
                // Stable peer order so the same chunk goes to the same peer when
                // re-requested in the same tick (no thundering-herd duplicates).
                owners.sort();
                needed.push((idx, owners));
            }
        }
        needed.sort_by_key(|(_, owners)| owners.len());

        // Pick chunks until each peer is at MAX_INFLIGHT_PER_PEER.
        let room = state.room_id();
        let mut assignments: HashMap<String, Vec<u32>> = HashMap::new();
        let mut per_peer_inflight: HashMap<String, usize> = HashMap::new();
        for (peer_id, _ts) in state.inflight.values() {
            *per_peer_inflight.entry(peer_id.clone()).or_default() += 1;
        }

        for (idx, owners) in needed {
            // Pick the owner with the smallest current backlog.
            let pick = owners.into_iter().min_by_key(|p| {
                *per_peer_inflight.get(p).unwrap_or(&0)
            });
            let Some(peer_id) = pick else { continue; };
            let backlog = per_peer_inflight.entry(peer_id.clone()).or_insert(0);
            if *backlog >= MAX_INFLIGHT_PER_PEER { continue; }
            *backlog += 1;
            assignments.entry(peer_id).or_default().push(idx);
        }

        // Mark in-flight + send the requests.
        if let Some(state_mut) = registry.get_mut(&root_hash) {
            for (peer_id, indices) in &assignments {
                for idx in indices {
                    state_mut.inflight.insert(*idx, (peer_id.clone(), now));
                }
            }
        }
        for (peer_id, indices) in assignments {
            if let Ok(payload) = serde_json::to_vec(&HavenMessage::ShareChunkRequest {
                root_hash: root_hash.clone(),
                indices,
            }) {
                let _ = ws_cmd_tx.send(WsCommand::SendDirect {
                    room_code: room.clone(),
                    target_peer: peer_id,
                    data: payload,
                });
            }
        }
    }
}

// ── Envelope handlers (called from swarm.rs when HavenMessage arrives) ───

pub async fn handle_envelope_share_manifest_request(
    registry: &mut ShareRegistry,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    sender_peer_id: &str,
    root_hash: String,
) {
    let Some(state) = registry.get(&root_hash) else { return; };
    let Some(ref manifest) = state.manifest else { return; };
    let Ok(bytes) = serde_json::to_vec(manifest) else { return; };
    let manifest_b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let room = state.room_id();
    if let Ok(payload) = serde_json::to_vec(&HavenMessage::ShareManifestResponse {
        root_hash, manifest_b64,
    }) {
        let _ = ws_cmd_tx.send(WsCommand::SendDirect {
            room_code: room,
            target_peer: sender_peer_id.to_string(),
            data: payload,
        });
    }
}

pub async fn handle_envelope_share_manifest_response(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    root_hash: String,
    manifest_b64: String,
) {
    let bytes = match base64::engine::general_purpose::STANDARD.decode(&manifest_b64) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[SHARE] manifest b64 decode: {e}");
            return;
        }
    };
    let computed = manifest_root_hash(&bytes);
    let claimed = match hex::decode(&root_hash) {
        Ok(v) if v.len() == 32 => { let mut a=[0u8;32]; a.copy_from_slice(&v); a }
        _ => { hollow_log!("[SHARE] manifest_resp root_hash bad hex"); return; }
    };
    if computed != claimed {
        hollow_log!("[SHARE] REJECTED manifest from peer: hash mismatch ({} vs {})",
            hex::encode(computed), hex::encode(claimed));
        return;
    }
    let manifest: ShareManifest = match serde_json::from_slice(&bytes) {
        Ok(m) => m,
        Err(e) => { hollow_log!("[SHARE] manifest parse: {e}"); return; }
    };
    if manifest.chunk_hashes.len() as u32 != manifest.chunk_count {
        hollow_log!("[SHARE] manifest chunk_count vs hash list mismatch");
        return;
    }

    let file_ext = manifest.file_name
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_string())
        .unwrap_or_default();

    // Cache manifest in-memory for the probe. DB write deferred to ShareStart.
    if let Some(state) = registry.get_mut(&root_hash) {
        state.manifest = Some(manifest.clone());
        state.file_ext = file_ext;
        state.have = ChunkBitmap::empty(manifest.chunk_count);
        state.manifest_requested_at = None;
    }

    let _ = event_tx.send(NetworkEvent::ShareManifestReady {
        root_hash,
        file_name: manifest.file_name,
        total_size: manifest.total_size,
        chunk_count: manifest.chunk_count,
    }).await;
}

pub async fn handle_envelope_share_have(
    registry: &mut ShareRegistry,
    sender_peer_id: &str,
    root_hash: String,
    bitmap_b64: String,
    chunk_count: u32,
) {
    let Some(state) = registry.get_mut(&root_hash) else { return; };
    // Sanity: ignore Have messages for the wrong manifest dimensions.
    if let Some(ref m) = state.manifest
        && m.chunk_count != chunk_count
    {
        return;
    }
    let bytes = match base64::engine::general_purpose::STANDARD.decode(&bitmap_b64) {
        Ok(b) => b,
        Err(_) => return,
    };
    let bitmap = ChunkBitmap::from_bytes(bytes, chunk_count);
    state.peer_have.insert(sender_peer_id.to_string(), bitmap);
}

/// Reset any in-flight requests a peer owed us (so the scheduler retries them
/// when the peer reconnects). Keeps peer_have intact — the bitmap is still
/// valid and lets the tick resume immediately after WebRTC re-establishes.
pub fn forget_peer(registry: &mut ShareRegistry, peer_id: &str) {
    for state in registry.values_mut() {
        state.inflight.retain(|_, (p, _)| p != peer_id);
    }
}

#[allow(clippy::too_many_arguments)]
pub async fn handle_envelope_share_chunk_request(
    registry: &mut ShareRegistry,
    seed_budget: &mut SeedBudget,
    bundle_keypair: &NativeKeypair,
    _ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    webrtc_peers: &std::collections::HashSet<String>,
    sender_peer_id: &str,
    root_hash: String,
    indices: Vec<u32>,
) {
    let prefer_webrtc = webrtc_peers.contains(sender_peer_id);
    let Some(state) = registry.get_mut(&root_hash) else { return; };
    if !state.seeding && state.have.count_set() == 0 { return; }
    let chunk_size = state.manifest.as_ref().map(|m| m.chunk_size).unwrap_or(CHUNK_SIZE);
    let total_size = state.manifest.as_ref().map(|m| m.total_size).unwrap_or(0);
    let chunk_count = state.manifest.as_ref().map(|m| m.chunk_count).unwrap_or(0);
    let mut bytes_served = 0u64;
    let Some(file) = state.data_file.as_mut() else { return; };
    for idx in indices {
        if idx >= chunk_count { continue; }
        if !state.have.has(idx) { continue; }
        // Bandwidth cap: defer this chunk to a later request if we don't have
        // tokens. The peer will retry via the scheduler timeout path.
        let want_pre = if idx == chunk_count - 1 {
            (total_size - idx as u64 * chunk_size as u64) as usize
        } else {
            chunk_size as usize
        };
        if !seed_budget.try_consume((want_pre + 16) as u64) {
            break;
        }
        let offset = idx as u64 * chunk_size as u64;
        let want = if idx == chunk_count - 1 {
            (total_size - offset) as usize
        } else {
            chunk_size as usize
        };
        // Read plaintext from original file, encrypt on-the-fly.
        let mut pt_buf = vec![0u8; want];
        if file.seek(SeekFrom::Start(offset)).is_err() { continue; }
        if file.read_exact(&mut pt_buf).is_err() { continue; }
        let buf = match encrypt_chunk(&state.key, idx, &pt_buf) {
            Ok(ct) => ct,
            Err(_) => continue,
        };
        let ct_len = buf.len();

        if !prefer_webrtc {
            hollow_log!("[SHARE] skip chunk for relay-only peer {sender_peer_id}");
            continue;
        }

        let short_root = &root_hash[..32];
        let transfer_id = format!("{short_root}:{idx}");
        let temp_path = match shares_dir() {
            Ok(d) => d.join(format!(".send_{short_root}_{idx}.tmp")),
            Err(_) => continue,
        };
        if std::fs::write(&temp_path, &buf).is_err() { continue; }
        let _ = event_tx.send(NetworkEvent::WebRtcSendFile {
            peer_id: sender_peer_id.to_string(),
            transfer_id,
            file_path: temp_path.to_string_lossy().to_string(),
            total_size: ct_len as u64,
            kind: "share_chunk".to_string(),
            shard_index: 0,
            chunk_index: idx,
        }).await;
        bytes_served += ct_len as u64;
    }
    state.bytes_uploaded += bytes_served;
    if bytes_served > 0
        && let Some(store) = open_message_store(bundle_keypair)
    {
        let _ = store.add_share_bytes_uploaded(&root_hash, bytes_served);
    }
}

async fn finalize_completed_download(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    root_hash: &str,
    file_ext: &str,
    save_dir: Option<&PathBuf>,
) {
    let dir = match save_dir {
        Some(d) => d.clone(),
        None => match shares_dir() { Ok(d) => d, Err(_) => return },
    };
    let partial = partial_path_in(&dir, root_hash);
    let final_p = final_path_in(&dir, root_hash, file_ext);
    if let Some(s) = registry.get_mut(root_hash) { s.data_file = None; }
    if let Err(e) = std::fs::rename(&partial, &final_p) {
        hollow_log!("[SHARE] rename .partial -> final failed: {e}");
        return;
    }
    if let Some(store) = open_message_store(bundle_keypair) {
        let _ = store.mark_share_complete(root_hash, &final_p.to_string_lossy(), now_unix_secs() as i64);
        let _ = store.set_share_seeding(root_hash, true);
    }
    if let Some(s) = registry.get_mut(root_hash) {
        s.data_file = OpenOptions::new().read(true).open(&final_p).ok();
        s.seeding = true;
    }
    let _ = event_tx.send(NetworkEvent::ShareCompleted {
        root_hash: root_hash.to_string(),
        disk_path: final_p.to_string_lossy().to_string(),
    }).await;
}

pub async fn handle_envelope_share_chunk_response(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    root_hash: String,
    index: u32,
    data_b64: String,
) {
    hollow_log!("[SHARE] WARN: unexpected relay-routed ShareChunkResponse");
    let ct = match base64::engine::general_purpose::STANDARD.decode(&data_b64) {
        Ok(b) => b,
        Err(e) => { hollow_log!("[SHARE] chunk b64 decode: {e}"); return; }
    };
    let Some(state) = registry.get_mut(&root_hash) else { return; };
    let Some(ref manifest) = state.manifest else { return; };
    if index >= manifest.chunk_count { return; }

    // Verify ciphertext SHA-256 matches the manifest claim.
    let h = Sha256::digest(&ct);
    let expected = manifest.chunk_hashes[index as usize];
    if h.as_slice() != expected.as_slice() {
        hollow_log!("[SHARE] chunk {index} hash mismatch — rejecting");
        return;
    }

    // Decrypt with the link key.
    let pt = match decrypt_chunk(&state.key, index, &ct) {
        Ok(p) => p,
        Err(e) => {
            hollow_log!("[SHARE] chunk {index} decrypt failed: {e}");
            // A persistent decrypt failure means the link key is wrong.
            let _ = event_tx.send(NetworkEvent::ShareFailed {
                root_hash, error: "decryption failed".to_string(),
            }).await;
            return;
        }
    };

    // Write to the partial file at the plaintext offset.
    let offset = index as u64 * manifest.chunk_size as u64;
    if let Some(file) = state.data_file.as_mut() {
        if file.seek(SeekFrom::Start(offset)).is_err() { return; }
        if file.write_all(&pt).is_err() { return; }
    }
    state.have.set(index);
    state.bytes_downloaded += pt.len() as u64;
    state.inflight.remove(&index);

    let now_inst = Instant::now();
    state.speed_samples.push((now_inst, pt.len()));
    let cutoff = now_inst - Duration::from_secs_f64(SPEED_WINDOW_SECS);
    state.speed_samples.retain(|(t, _)| *t >= cutoff);
    let window_bytes: usize = state.speed_samples.iter().map(|(_, b)| b).sum();
    let window_dt = state.speed_samples.first()
        .map(|(t, _)| now_inst.duration_since(*t).as_secs_f64())
        .unwrap_or(SPEED_WINDOW_SECS);
    state.speed_bps = if window_dt > 0.01 {
        (window_bytes as f64 / window_dt).round() as u64
    } else {
        0
    };

    let chunks_have = state.have.count_set();
    let chunks_total = state.have.chunk_count;
    let complete = state.have.is_complete();
    let bytes_per_sec = state.speed_bps;
    let peers = state.peer_have.len().min(u8::MAX as usize) as u8;
    let file_ext = state.file_ext.clone();
    let save_dir = state.save_dir.clone();
    let bitmap_snapshot = state.have.as_bytes().to_vec();

    // Persist the bitmap snapshot (cheap; small blob).
    if let Some(store) = open_message_store(bundle_keypair) {
        let _ = store.save_chunk_bitmap(&root_hash, &bitmap_snapshot, now_unix_secs() as i64);
    }

    let _ = event_tx.send(NetworkEvent::ShareProgress {
        root_hash: root_hash.clone(),
        chunks_have, chunks_total,
        peers, bytes_per_sec,
    }).await;

    if complete {
        finalize_completed_download(
            registry, bundle_keypair, event_tx,
            &root_hash, &file_ext, save_dir.as_ref(),
        ).await;
    }
}

// ── WebRTC binary chunk completion (called from swarm.rs WebRtcTransferComplete dispatch) ──

/// Receiver-side handler when a chunk arrives via WebRTC binary frames.
/// Mirrors the verify+decrypt+write+progress+complete logic of
/// handle_envelope_share_chunk_response, but reads the ciphertext from the
/// temp file Dart wrote (not from a base64 envelope).
///
/// `transfer_id` is the wire id from the sender — format `"{short_root}:{idx}"`
/// where short_root is the first 32 hex chars of the root_hash. We resolve to
/// the full root_hash by matching against active shares in the registry
/// (collisions vanishingly unlikely with 128 bits).
pub async fn handle_webrtc_share_chunk_complete(
    registry: &mut ShareRegistry,
    bundle_keypair: &NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    transfer_id: String,
    chunk_index: u32,
    temp_path: String,
) {
    // Resolve short_root → full root_hash via registry lookup.
    let short_root = transfer_id.split(':').next().unwrap_or("");
    let root_hash = match registry.keys().find(|rh| rh.starts_with(short_root)).cloned() {
        Some(rh) => rh,
        None => {
            hollow_log!("[SHARE-WEBRTC] no active share matches short_root {short_root}");
            let _ = std::fs::remove_file(&temp_path);
            return;
        }
    };

    // Read + delete the staged ciphertext.
    let ct = match std::fs::read(&temp_path) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[SHARE-WEBRTC] read temp failed: {e}");
            return;
        }
    };
    let _ = std::fs::remove_file(&temp_path);

    let Some(state) = registry.get_mut(&root_hash) else { return; };
    let Some(ref manifest) = state.manifest else { return; };
    if chunk_index >= manifest.chunk_count { return; }

    // Verify SHA-256(ciphertext) matches the manifest claim.
    let h = Sha256::digest(&ct);
    let expected = manifest.chunk_hashes[chunk_index as usize];
    if h.as_slice() != expected.as_slice() {
        hollow_log!("[SHARE-WEBRTC] chunk {chunk_index} hash mismatch — rejecting");
        return;
    }

    // Decrypt with the link key.
    let pt = match decrypt_chunk(&state.key, chunk_index, &ct) {
        Ok(p) => p,
        Err(e) => {
            hollow_log!("[SHARE-WEBRTC] chunk {chunk_index} decrypt failed: {e}");
            let _ = event_tx.send(NetworkEvent::ShareFailed {
                root_hash, error: "decryption failed".to_string(),
            }).await;
            return;
        }
    };

    // Write to the partial file at the plaintext offset.
    let offset = chunk_index as u64 * manifest.chunk_size as u64;
    if let Some(file) = state.data_file.as_mut() {
        if file.seek(SeekFrom::Start(offset)).is_err() { return; }
        if file.write_all(&pt).is_err() { return; }
    }
    state.have.set(chunk_index);
    state.bytes_downloaded += pt.len() as u64;
    state.inflight.remove(&chunk_index);

    let now_inst = Instant::now();
    state.speed_samples.push((now_inst, pt.len()));
    let cutoff = now_inst - Duration::from_secs_f64(SPEED_WINDOW_SECS);
    state.speed_samples.retain(|(t, _)| *t >= cutoff);
    let window_bytes: usize = state.speed_samples.iter().map(|(_, b)| b).sum();
    let window_dt = state.speed_samples.first()
        .map(|(t, _)| now_inst.duration_since(*t).as_secs_f64())
        .unwrap_or(SPEED_WINDOW_SECS);
    state.speed_bps = if window_dt > 0.01 {
        (window_bytes as f64 / window_dt).round() as u64
    } else {
        0
    };

    let chunks_have = state.have.count_set();
    let chunks_total = state.have.chunk_count;
    let complete = state.have.is_complete();
    let bytes_per_sec = state.speed_bps;
    let peers = state.peer_have.len().min(u8::MAX as usize) as u8;
    let file_ext = state.file_ext.clone();
    let save_dir = state.save_dir.clone();
    let bitmap_snapshot = state.have.as_bytes().to_vec();

    if let Some(store) = open_message_store(bundle_keypair) {
        let _ = store.save_chunk_bitmap(&root_hash, &bitmap_snapshot, now_unix_secs() as i64);
    }

    let _ = event_tx.send(NetworkEvent::ShareProgress {
        root_hash: root_hash.clone(),
        chunks_have, chunks_total,
        peers, bytes_per_sec,
    }).await;

    if complete {
        finalize_completed_download(
            registry, bundle_keypair, event_tx,
            &root_hash, &file_ext, save_dir.as_ref(),
        ).await;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_round_trip() {
        let root = [7u8; 32];
        let key = [9u8; 32];
        let link = encode_link(&root, &key);
        assert!(link.starts_with(LINK_SCHEME_PREFIX));
        let info = decode_link(&link).expect("decode");
        assert_eq!(info.root_hash, root);
        assert_eq!(info.key, key);
    }

    #[test]
    fn link_rejects_short_payload() {
        let bad = format!("{LINK_SCHEME_PREFIX}AAAA");
        assert!(decode_link(&bad).is_err());
    }

    #[test]
    fn link_rejects_wrong_scheme() {
        assert!(decode_link("hollow://oops/abcd").is_err());
    }

    #[test]
    fn link_rejects_bad_version() {
        let mut buf = vec![99u8]; // bad version
        buf.extend_from_slice(&[0u8; 32]);
        buf.extend_from_slice(&[0u8; 32]);
        let s = format!("{LINK_SCHEME_PREFIX}{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&buf));
        assert!(decode_link(&s).is_err());
    }

    #[test]
    fn chunk_nonce_is_unique_per_index() {
        assert_ne!(chunk_nonce(0), chunk_nonce(1));
        assert_ne!(chunk_nonce(1), chunk_nonce(u32::MAX));
        // First 4 bytes are always zero.
        assert_eq!(&chunk_nonce(42)[..4], &[0u8; 4]);
    }

    #[test]
    fn chunk_encrypt_decrypt_round_trip() {
        let key = [1u8; 32];
        let pt = b"hello hollow share!";
        let ct = encrypt_chunk(&key, 5, pt).unwrap();
        let back = decrypt_chunk(&key, 5, &ct).unwrap();
        assert_eq!(back, pt);
    }

    #[test]
    fn wrong_index_fails_decrypt() {
        let key = [1u8; 32];
        let ct = encrypt_chunk(&key, 5, b"x").unwrap();
        assert!(decrypt_chunk(&key, 6, &ct).is_err());
    }

    #[test]
    fn bitmap_set_and_count() {
        let mut bm = ChunkBitmap::empty(20);
        assert_eq!(bm.count_set(), 0);
        bm.set(0); bm.set(7); bm.set(8); bm.set(19);
        assert!(bm.has(0));
        assert!(bm.has(7));
        assert!(bm.has(8));
        assert!(bm.has(19));
        assert!(!bm.has(1));
        assert_eq!(bm.count_set(), 4);
    }

    #[test]
    fn bitmap_trailing_bits_masked() {
        let bm = ChunkBitmap::from_bytes(vec![0xFF, 0xFF], 10);
        assert_eq!(bm.count_set(), 10);
        assert!(bm.is_complete());
        let bm2 = ChunkBitmap::from_bytes(vec![0xFE, 0xFF], 10);
        assert_eq!(bm2.count_set(), 9);
        assert!(!bm2.is_complete());
    }
}
