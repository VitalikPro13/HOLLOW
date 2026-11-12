//! At-rest encryption for content files under the data root (issue 78).
//!
//! Format `HFE1`: a 32-byte header followed by AES-256-GCM chunks. The per-file
//! key lives in the `file_keys` table of messages.db, so it inherits whatever
//! identity protection the user chose and deleting the row is a cryptographic
//! erase. Threat model: the disk after the app is closed, uninstalled, stolen or
//! browsed. Never a live unlocked session.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock, RwLock};
use std::time::{Duration, SystemTime};

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, Key, KeyInit, Nonce};
use zeroize::Zeroizing;

use crate::storage::MessageStore;

const MAGIC: [u8; 4] = *b"HFE1";
const VERSION: u8 = 1;
pub const HEADER_LEN: u64 = 32;
const TAG_LEN: u64 = 16;

/// Whole-file writes use 1 MiB; chunked writers pass their transport's chunk size
/// so an out-of-order chunk maps 1:1 onto one ciphertext chunk.
pub const DEFAULT_CHUNK_SIZE: u32 = 1024 * 1024;

const MIN_CHUNK_SIZE: u32 = 4096;

// ── key ring ────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct FileKey {
    key: Zeroizing<[u8; 32]>,
    nonce: [u8; 8],
}

#[derive(Clone)]
struct StoreRef {
    db_path: String,
    passphrase: String,
}

#[derive(Default)]
struct Ring {
    keys: HashMap<[u8; 16], FileKey>,
    /// Newest first: index 0 takes new rows, every entry takes deletes.
    stores: Vec<StoreRef>,
}

fn ring() -> &'static RwLock<Ring> {
    static RING: OnceLock<RwLock<Ring>> = OnceLock::new();
    RING.get_or_init(|| RwLock::new(Ring::default()))
}

/// Load the key ring from `db_path` and make it the target for new rows.
/// Idempotent per database path.
pub fn init(db_path: &str, passphrase: &str) -> Result<(), String> {
    {
        let guard = ring().read().map_err(|e| format!("Key ring lock poisoned: {e}"))?;
        if guard.stores.iter().any(|s| s.db_path == db_path) {
            return Ok(());
        }
    }
    let store = MessageStore::lease(db_path, passphrase)?;
    let rows = store.load_file_keys()?;
    drop(store);

    let mut guard = ring().write().map_err(|e| format!("Key ring lock poisoned: {e}"))?;
    for (uid, key, nonce) in rows {
        guard.keys.insert(uid, FileKey { key: Zeroizing::new(key), nonce });
    }
    guard.stores.retain(|s| s.db_path != db_path);
    guard.stores.insert(0, StoreRef {
        db_path: db_path.to_string(),
        passphrase: passphrase.to_string(),
    });
    Ok(())
}

/// Register the ring lazily for FFI entry points that can run before the node
/// starts. A locked or absent identity fails here rather than silently writing
/// plaintext.
fn ensure_ready() -> Result<(), String> {
    {
        let guard = ring().read().map_err(|e| format!("Key ring lock poisoned: {e}"))?;
        if !guard.stores.is_empty() {
            return Ok(());
        }
    }
    let id = crate::identity::load_existing_identity()?
        .ok_or("No identity is loaded, so file keys are unavailable")?;
    let proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    let db_path = crate::identity::data_dir()?
        .join("messages.db")
        .to_string_lossy()
        .to_string();
    init(&db_path, &passphrase)
}

fn ring_key(uid: &[u8; 16]) -> Option<FileKey> {
    ring().read().ok().and_then(|g| g.keys.get(uid).cloned())
}

fn lookup_key(uid: &[u8; 16]) -> Option<FileKey> {
    if let Some(fk) = ring_key(uid) {
        return Some(fk);
    }
    // An unloaded ring looks exactly like a missing key: an FFI read can run before
    // the node starts, and an import drops the ring with the database it came from.
    // A genuine miss costs one query.
    ensure_ready().ok()?;
    ring_key(uid).or_else(|| load_one_key(uid))
}

/// A row written after our ring loaded, by another process sharing the database (the
/// iOS push extension, a push fetch). The ring's write lock spans the query, so a
/// `forget_key` racing it cannot leave the key cached after its row is gone.
fn load_one_key(uid: &[u8; 16]) -> Option<FileKey> {
    let mut guard = ring().write().ok()?;
    if let Some(fk) = guard.keys.get(uid) {
        return Some(fk.clone());
    }
    let stores = guard.stores.clone();
    let (key, nonce) = stores.iter().find_map(|s| MessageStore::lease(&s.db_path, &s.passphrase).ok()?.load_file_key(uid).ok().flatten())?;
    let fk = FileKey { key: Zeroizing::new(key), nonce };
    guard.keys.insert(*uid, fk.clone());
    Some(fk)
}

fn mint_key() -> Result<([u8; 16], FileKey), String> {
    let mut uid = [0u8; 16];
    getrandom::fill(&mut uid).map_err(|e| format!("RNG failed: {e}"))?;
    let mut key = Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut key[..]).map_err(|e| format!("RNG failed: {e}"))?;
    let mut nonce = [0u8; 8];
    getrandom::fill(&mut nonce).map_err(|e| format!("RNG failed: {e}"))?;
    Ok((uid, FileKey { key, nonce }))
}

fn write_target() -> Result<StoreRef, String> {
    ensure_ready()?;
    let guard = ring().read().map_err(|e| format!("Key ring lock poisoned: {e}"))?;
    guard.stores.first().cloned().ok_or_else(|| "File key store is not ready".to_string())
}

/// Persist the row BEFORE any ciphertext exists, so a crash can only ever leave
/// an orphan row, never an unreadable file.
fn persist_key(uid: &[u8; 16], fk: &FileKey) -> Result<(), String> {
    let target = write_target()?;
    let store = MessageStore::lease(&target.db_path, &target.passphrase)?;
    store.insert_file_key(uid, &fk.key, &fk.nonce)?;
    let mut guard = ring().write().map_err(|e| format!("Key ring lock poisoned: {e}"))?;
    guard.keys.insert(*uid, fk.clone());
    Ok(())
}

fn forget_key(uid: &[u8; 16]) {
    let stores = ring().read().ok().map(|g| g.stores.clone()).unwrap_or_default();
    for s in &stores {
        if let Ok(store) = MessageStore::lease(&s.db_path, &s.passphrase) {
            let _ = store.delete_file_key(uid);
        }
    }
    if let Ok(mut guard) = ring().write() {
        guard.keys.remove(uid);
    }
}

// ── format ──────────────────────────────────────────────────────────────────

struct Header {
    chunk_size: u32,
    uid: [u8; 16],
}

fn parse_header(buf: &[u8; 32]) -> Option<Header> {
    if buf[..4] != MAGIC || buf[4] != VERSION {
        return None;
    }
    let chunk_size = u32::from_le_bytes([buf[5], buf[6], buf[7], buf[8]]);
    if chunk_size == 0 {
        return None;
    }
    let mut uid = [0u8; 16];
    uid.copy_from_slice(&buf[10..26]);
    Some(Header { chunk_size, uid })
}

fn build_header(chunk_size: u32, uid: &[u8; 16]) -> [u8; 32] {
    let mut buf = [0u8; 32];
    buf[..4].copy_from_slice(&MAGIC);
    buf[4] = VERSION;
    buf[5..9].copy_from_slice(&chunk_size.to_le_bytes());
    buf[10..26].copy_from_slice(uid);
    buf
}

/// Read the header, or `None` when the file is legacy plaintext.
fn read_header(path: &Path) -> Result<Option<(Header, u64)>, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("Failed to stat file: {e}"))?;
    let len = meta.len();
    if len < HEADER_LEN {
        return Ok(None);
    }
    let mut f = File::open(path).map_err(|e| format!("Failed to open file: {e}"))?;
    let mut buf = [0u8; 32];
    f.read_exact(&mut buf).map_err(|e| format!("Failed to read header: {e}"))?;
    Ok(parse_header(&buf).map(|h| (h, len)))
}

fn chunk_count_from_len(file_len: u64, chunk_size: u32) -> u32 {
    let body = file_len.saturating_sub(HEADER_LEN);
    body.div_ceil(chunk_size as u64 + TAG_LEN) as u32
}

fn plain_len_from(file_len: u64, chunk_size: u32) -> u64 {
    let body = file_len.saturating_sub(HEADER_LEN);
    let n = chunk_count_from_len(file_len, chunk_size) as u64;
    body.saturating_sub(n * TAG_LEN)
}

fn cipher_len_for(total_len: u64, chunk_size: u32) -> u64 {
    let n = total_len.div_ceil(chunk_size as u64);
    HEADER_LEN + total_len + n * TAG_LEN
}

fn chunk_nonce(file_nonce: &[u8; 8], index: u32) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[..8].copy_from_slice(file_nonce);
    n[8..].copy_from_slice(&index.to_le_bytes());
    n
}

fn chunk_aad(uid: &[u8; 16], index: u32, last: bool) -> [u8; 21] {
    let mut aad = [0u8; 21];
    aad[..16].copy_from_slice(uid);
    aad[16..20].copy_from_slice(&index.to_le_bytes());
    aad[20] = u8::from(last);
    aad
}

fn seal(fk: &FileKey, uid: &[u8; 16], index: u32, last: bool, pt: &[u8]) -> Result<Vec<u8>, String> {
    let cipher = Aes256Gcm::new(&Key::<Aes256Gcm>::from(*fk.key));
    let aad = chunk_aad(uid, index, last);
    cipher
        .encrypt(&Nonce::from(chunk_nonce(&fk.nonce, index)), Payload { msg: pt, aad: &aad })
        .map_err(|e| format!("Failed to encrypt file chunk: {e}"))
}

fn open_chunk(fk: &FileKey, uid: &[u8; 16], index: u32, last: bool, ct: &[u8]) -> Result<Vec<u8>, String> {
    let cipher = Aes256Gcm::new(&Key::<Aes256Gcm>::from(*fk.key));
    let aad = chunk_aad(uid, index, last);
    cipher
        .decrypt(&Nonce::from(chunk_nonce(&fk.nonce, index)), Payload { msg: ct, aad: &aad })
        .map_err(|_| "File chunk failed authentication".to_string())
}

// ── reading ─────────────────────────────────────────────────────────────────

/// True when `path` carries the at-rest header.
pub fn is_encrypted(path: &Path) -> bool {
    matches!(read_header(path), Ok(Some(_)))
}

/// Plaintext byte length. A legacy plaintext file reports its file length.
pub fn plaintext_len(path: &Path) -> Result<u64, String> {
    match read_header(path)? {
        Some((h, len)) => Ok(plain_len_from(len, h.chunk_size)),
        None => std::fs::metadata(path)
            .map(|m| m.len())
            .map_err(|e| format!("Failed to stat file: {e}")),
    }
}

/// A file opened for reading, judged by the header in the handle it is read from.
enum Opened {
    Plain(File),
    Sealed { file: File, header: Header, len: u64, key: FileKey },
}

/// Open `path` with the key its header names. A writer can swap a newer file in and
/// retire the old key between our open and the lookup; the path then names the newer
/// file, which we read instead.
fn open_for_read(path: &Path) -> Result<Opened, String> {
    open_for_read_with(path, &lookup_key)
}

fn open_for_read_with(path: &Path, lookup: &dyn Fn(&[u8; 16]) -> Option<FileKey>) -> Result<Opened, String> {
    for _ in 0..3 {
        let mut file = File::open(path).map_err(|e| format!("Failed to open file: {e}"))?;
        let len = file.metadata().map_err(|e| format!("Failed to stat file: {e}"))?.len();
        let mut buf = [0u8; HEADER_LEN as usize];
        let header = if len < HEADER_LEN {
            None
        } else {
            file.read_exact(&mut buf).map_err(|e| format!("Failed to read header: {e}"))?;
            parse_header(&buf)
        };
        let Some(header) = header else {
            file.rewind().map_err(|e| format!("Failed to seek: {e}"))?;
            return Ok(Opened::Plain(file));
        };
        if let Some(key) = lookup(&header.uid) {
            return Ok(Opened::Sealed { file, header, len, key });
        }
        let swapped = read_header(path).ok().flatten().is_some_and(|(now, _)| now.uid != header.uid);
        if !swapped {
            break;
        }
    }
    Err("File key missing".to_string())
}

/// Decrypt a whole file. A file with no header is legacy plaintext and passes
/// through; a header whose key row is gone is an error, never a passthrough.
pub fn read_all(path: &Path) -> Result<Vec<u8>, String> {
    read_opened(open_for_read(path)?)
}

fn read_opened(opened: Opened) -> Result<Vec<u8>, String> {
    let (mut f, h, len, fk) = match opened {
        Opened::Plain(mut f) => {
            let mut out = Vec::new();
            f.read_to_end(&mut out).map_err(|e| format!("Failed to read file: {e}"))?;
            return Ok(out);
        }
        Opened::Sealed { file, header, len, key } => (file, header, len, key),
    };
    let n = chunk_count_from_len(len, h.chunk_size);
    f.seek(SeekFrom::Start(HEADER_LEN)).map_err(|e| format!("Failed to seek: {e}"))?;

    let mut out = Vec::with_capacity(plain_len_from(len, h.chunk_size) as usize);
    let mut buf = vec![0u8; h.chunk_size as usize + TAG_LEN as usize];
    let mut remaining = len - HEADER_LEN;
    for idx in 0..n {
        let take = remaining.min(h.chunk_size as u64 + TAG_LEN) as usize;
        f.read_exact(&mut buf[..take]).map_err(|e| format!("Failed to read chunk: {e}"))?;
        out.extend_from_slice(&open_chunk(&fk, &h.uid, idx, idx + 1 == n, &buf[..take])?);
        remaining -= take as u64;
    }
    Ok(out)
}

/// Decrypt only the chunks `offset..offset+len` touches.
pub fn read_range(path: &Path, offset: u64, len: usize) -> Result<Vec<u8>, String> {
    let (mut f, h, file_len, fk) = match open_for_read(path)? {
        Opened::Plain(mut f) => {
            f.seek(SeekFrom::Start(offset)).map_err(|e| format!("Failed to seek: {e}"))?;
            let mut out = vec![0u8; len];
            let mut filled = 0usize;
            while filled < len {
                match f.read(&mut out[filled..]) {
                    Ok(0) => break,
                    Ok(n) => filled += n,
                    Err(e) => return Err(format!("Failed to read file: {e}")),
                }
            }
            out.truncate(filled);
            return Ok(out);
        }
        Opened::Sealed { file, header, len, key } => (file, header, len, key),
    };
    let total = plain_len_from(file_len, h.chunk_size);
    if offset >= total || len == 0 {
        return Ok(Vec::new());
    }
    let end = (offset + len as u64).min(total);
    let n = chunk_count_from_len(file_len, h.chunk_size);
    let cs = h.chunk_size as u64;
    let first = (offset / cs) as u32;
    let last = ((end - 1) / cs) as u32;

    let mut out = Vec::with_capacity((end - offset) as usize);
    for idx in first..=last {
        let at = HEADER_LEN + idx as u64 * (cs + TAG_LEN);
        let take = (file_len - at).min(cs + TAG_LEN) as usize;
        f.seek(SeekFrom::Start(at)).map_err(|e| format!("Failed to seek: {e}"))?;
        let mut buf = vec![0u8; take];
        f.read_exact(&mut buf).map_err(|e| format!("Failed to read chunk: {e}"))?;
        let pt = open_chunk(&fk, &h.uid, idx, idx + 1 == n, &buf)?;
        let base = idx as u64 * cs;
        let lo = offset.saturating_sub(base).min(pt.len() as u64) as usize;
        let hi = (end - base).min(pt.len() as u64) as usize;
        out.extend_from_slice(&pt[lo..hi]);
    }
    Ok(out)
}

/// Decrypt `src` into `dest`, streaming a chunk at a time. Returns bytes written.
pub fn export_to(src: &Path, dest: &Path) -> Result<u64, String> {
    if let Some(parent) = dest.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let (mut inf, h, len, fk) = match open_for_read(src)? {
        Opened::Plain(mut f) => {
            let mut out = File::create(dest).map_err(|e| format!("Failed to create file: {e}"))?;
            return std::io::copy(&mut f, &mut out).map_err(|e| format!("Failed to copy file: {e}"));
        }
        Opened::Sealed { file, header, len, key } => (file, header, len, key),
    };
    let n = chunk_count_from_len(len, h.chunk_size);
    inf.seek(SeekFrom::Start(HEADER_LEN)).map_err(|e| format!("Failed to seek: {e}"))?;
    let mut out = File::create(dest).map_err(|e| format!("Failed to create file: {e}"))?;

    let mut buf = vec![0u8; h.chunk_size as usize + TAG_LEN as usize];
    let mut remaining = len - HEADER_LEN;
    let mut written = 0u64;
    for idx in 0..n {
        let take = remaining.min(h.chunk_size as u64 + TAG_LEN) as usize;
        inf.read_exact(&mut buf[..take]).map_err(|e| format!("Failed to read chunk: {e}"))?;
        let pt = open_chunk(&fk, &h.uid, idx, idx + 1 == n, &buf[..take])?;
        out.write_all(&pt).map_err(|e| format!("Failed to write file: {e}"))?;
        written += pt.len() as u64;
        remaining -= take as u64;
    }
    out.flush().map_err(|e| format!("Failed to flush file: {e}"))?;
    Ok(written)
}

// ── writing ─────────────────────────────────────────────────────────────────

/// The temp of one write, named by its key: two writers of one path never share a
/// half-written temp.
fn tmp_sibling(path: &Path, uid: &[u8; 16]) -> PathBuf {
    first_touch();
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    path.with_file_name(format!("{name}.{}.hfe.tmp", hex::encode(&uid[..8])))
}

/// `{target}.{16 lowercase hex}.hfe.tmp`, split into the target's name and the key tag.
fn temp_parts(name: &str) -> Option<(&str, &str)> {
    let (target, tag) = name.strip_suffix(".hfe.tmp")?.rsplit_once('.')?;
    let hex = tag.len() == 16 && tag.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    (hex && !target.is_empty()).then_some((target, tag))
}

/// When this process first touched the at-rest layer: every temp it writes is newer,
/// so the boot sweep never takes a live writer's temp.
fn first_touch() -> SystemTime {
    static AT: OnceLock<SystemTime> = OnceLock::new();
    *AT.get_or_init(SystemTime::now)
}

/// Coarse filesystems stamp modification times to a second or two.
const MTIME_SLACK: Duration = Duration::from_secs(3);

fn older_than(path: &Path, cutoff: SystemTime) -> bool {
    std::fs::metadata(path).and_then(|m| m.modified()).is_ok_and(|t| t + MTIME_SLACK < cutoff)
}

/// Held while a file's bytes are swapped, truncated, moved or unlinked, so the key that
/// change retires is always the key of the file it replaced. Per process: the iOS push
/// extension writes under a lock of its own.
fn swap_lock() -> MutexGuard<'static, ()> {
    static SWAP: Mutex<()> = Mutex::new(());
    SWAP.lock().unwrap_or_else(|p| p.into_inner())
}

/// A temp a write of an earlier run left (modified before `cutoff`), removed with the
/// key row its header names when its name tags that key, the temp's own.
fn remove_orphan_temp(path: &Path, cutoff: SystemTime) {
    if !older_than(path, cutoff) {
        return;
    }
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tag = temp_parts(&name).map(|(_, tag)| tag);
    let uid = read_header(path).ok().flatten().map(|(h, _)| h.uid).filter(|u| tag.is_some_and(|t| t == hex::encode(&u[..8])));
    if std::fs::remove_file(path).is_ok()
        && let Some(uid) = uid
    {
        forget_key(&uid);
    }
}

/// Temps a write of `target` that died mid-way left beside it, in either naming.
fn remove_orphan_temps(target: &Path, cutoff: SystemTime) {
    let (Some(dir), Some(name)) = (target.parent(), target.file_name()) else { return };
    let name = name.to_string_lossy();
    let legacy = format!("{name}.hfe.tmp");
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let n = entry.file_name().to_string_lossy().to_string();
        if n == legacy || temp_parts(&n).is_some_and(|(t, _)| t == name) {
            remove_orphan_temp(&entry.path(), cutoff);
        }
    }
}

/// Encrypt `plaintext` to `path`, replacing whatever is there. Atomic: the
/// ciphertext lands on a sibling temp and is renamed over the target.
pub fn write_all(path: &Path, plaintext: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let (uid, fk) = mint_key()?;
    persist_key(&uid, &fk)?;
    let tmp = tmp_sibling(path, &uid);
    match write_sealed(&tmp, &uid, &fk, DEFAULT_CHUNK_SIZE, plaintext) {
        Ok(()) => {}
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            forget_key(&uid);
            return Err(e);
        }
    }
    // The target may still be a legacy plaintext file or an older ciphertext:
    // its key row dies with it.
    let _swap = swap_lock();
    let old_uid = read_header(path).ok().flatten().map(|(h, _)| h.uid);
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        forget_key(&uid);
        format!("Failed to replace file: {e}")
    })?;
    if let Some(old) = old_uid {
        forget_key(&old);
    }
    Ok(())
}

/// Seal `total_len` bytes read from `src`, one chunk in memory at a time. The
/// boot sweep runs over `shares/`, where a single download can be many gigabytes.
fn write_sealed_from_reader<R: Read>(
    path: &Path,
    uid: &[u8; 16],
    fk: &FileKey,
    chunk_size: u32,
    src: &mut R,
    total_len: u64,
) -> Result<(), String> {
    let mut out = File::create(path).map_err(|e| format!("Failed to create file: {e}"))?;
    out.write_all(&build_header(chunk_size, uid)).map_err(|e| format!("Failed to write file: {e}"))?;
    let cs = chunk_size as u64;
    let n = total_len.div_ceil(cs) as u32;
    let mut buf = vec![0u8; chunk_size as usize];
    for idx in 0..n {
        let want = if idx + 1 == n {
            (total_len - idx as u64 * cs) as usize
        } else {
            chunk_size as usize
        };
        src.read_exact(&mut buf[..want]).map_err(|e| format!("Failed to read file: {e}"))?;
        let ct = seal(fk, uid, idx, idx + 1 == n, &buf[..want])?;
        out.write_all(&ct).map_err(|e| format!("Failed to write file: {e}"))?;
    }
    out.flush().map_err(|e| format!("Failed to flush file: {e}"))
}

fn write_sealed(
    path: &Path,
    uid: &[u8; 16],
    fk: &FileKey,
    chunk_size: u32,
    plaintext: &[u8],
) -> Result<(), String> {
    let mut f = File::create(path).map_err(|e| format!("Failed to create file: {e}"))?;
    f.write_all(&build_header(chunk_size, uid)).map_err(|e| format!("Failed to write file: {e}"))?;
    let cs = chunk_size as usize;
    let n = plaintext.len().div_ceil(cs);
    for idx in 0..n {
        let lo = idx * cs;
        let hi = (lo + cs).min(plaintext.len());
        let ct = seal(fk, uid, idx as u32, idx + 1 == n, &plaintext[lo..hi])?;
        f.write_all(&ct).map_err(|e| format!("Failed to write file: {e}"))?;
    }
    f.flush().map_err(|e| format!("Failed to flush file: {e}"))
}

/// Random-order chunk writer, so a share or transfer chunk maps 1:1 onto one
/// ciphertext chunk and never needs the neighbours it has not downloaded yet.
pub struct Writer {
    file: File,
    uid: [u8; 16],
    fk: FileKey,
    chunk_size: u32,
    total_len: u64,
    chunk_count: u32,
}

impl Writer {
    /// Create `path` at its full ciphertext length with a fresh key row.
    pub fn create(path: &Path, chunk_size: u32, total_len: u64) -> Result<Writer, String> {
        // A wire-supplied chunk size reaches here (a share manifest names it), and a
        // tiny one turns a modest file into a huge sparse allocation: 16 tag bytes
        // per chunk.
        if chunk_size < MIN_CHUNK_SIZE {
            return Err("Chunk size is too small".to_string());
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let (uid, fk) = mint_key()?;
        persist_key(&uid, &fk)?;
        let file = {
            // The target may hold an older ciphertext whose key row would otherwise
            // outlive the bytes it unlocks. The header lands under the lock too, so a
            // swap never reads a truncated file as one without a key.
            let _swap = swap_lock();
            let old_uid = read_header(path).ok().flatten().map(|(h, _)| h.uid);
            let opened = OpenOptions::new().read(true).write(true).create(true).truncate(true).open(path);
            let mut file = match opened {
                Ok(file) => file,
                Err(e) => {
                    forget_key(&uid);
                    return Err(format!("Failed to create file: {e}"));
                }
            };
            if let Some(old) = old_uid {
                forget_key(&old);
            }
            file.write_all(&build_header(chunk_size, &uid))
                .map_err(|e| format!("Failed to write header: {e}"))?;
            file
        };
        file.set_len(cipher_len_for(total_len, chunk_size))
            .map_err(|e| format!("Failed to size file: {e}"))?;
        Ok(Writer {
            file,
            uid,
            fk,
            chunk_size,
            total_len,
            chunk_count: total_len.div_ceil(chunk_size as u64) as u32,
        })
    }

    /// Reopen a partial written by an earlier run, taking its chunk size from
    /// the header.
    pub fn open_existing(path: &Path, total_len: u64) -> Result<Writer, String> {
        let (h, _) = read_header(path)?.ok_or("File is not at-rest encrypted")?;
        let fk = lookup_key(&h.uid).ok_or("File key missing")?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|e| format!("Failed to open file: {e}"))?;
        file.set_len(cipher_len_for(total_len, h.chunk_size))
            .map_err(|e| format!("Failed to size file: {e}"))?;
        Ok(Writer {
            file,
            uid: h.uid,
            fk,
            chunk_size: h.chunk_size,
            total_len,
            chunk_count: total_len.div_ceil(h.chunk_size as u64) as u32,
        })
    }

    pub fn write_chunk(&mut self, index: u32, plaintext: &[u8]) -> Result<(), String> {
        if index >= self.chunk_count {
            return Err("Chunk index is past the end of the file".to_string());
        }
        let cs = self.chunk_size as u64;
        let expect = if index + 1 == self.chunk_count {
            (self.total_len - index as u64 * cs) as usize
        } else {
            cs as usize
        };
        if plaintext.len() != expect {
            return Err("Chunk length does not match the file layout".to_string());
        }
        let at = HEADER_LEN + index as u64 * (cs + TAG_LEN);
        // Re-sealing a slot under the same key and nonce with different plaintext is
        // GCM nonce reuse, so it is refused; an identical rewrite is a retransmit and
        // is dropped. Callers hash-check the chunk first, so this guards the
        // primitive rather than a live path.
        if let Some(existing) = self.sealed_chunk(index, at, expect)? {
            return if existing == plaintext {
                Ok(())
            } else {
                Err("Refusing to rewrite a file chunk with different bytes".to_string())
            };
        }
        let ct = seal(&self.fk, &self.uid, index, index + 1 == self.chunk_count, plaintext)?;
        self.file.seek(SeekFrom::Start(at)).map_err(|e| format!("Failed to seek: {e}"))?;
        self.file.write_all(&ct).map_err(|e| format!("Failed to write chunk: {e}"))?;
        self.file.flush().map_err(|e| format!("Failed to flush file: {e}"))
    }

    /// The plaintext already sealed at `index`, or `None` for an untouched slot.
    /// `set_len` zero-fills, and a real tag is never all zeros, so 16 bytes decide
    /// it without reading the chunk.
    fn sealed_chunk(
        &mut self,
        index: u32,
        at: u64,
        plain_len: usize,
    ) -> Result<Option<Vec<u8>>, String> {
        const TAG: usize = TAG_LEN as usize;
        self.file
            .seek(SeekFrom::Start(at + plain_len as u64))
            .map_err(|e| format!("Failed to seek: {e}"))?;
        let mut tag = [0u8; TAG];
        if self.file.read_exact(&mut tag).is_err() || tag == [0u8; TAG] {
            return Ok(None);
        }
        self.file.seek(SeekFrom::Start(at)).map_err(|e| format!("Failed to seek: {e}"))?;
        let mut buf = vec![0u8; plain_len + TAG];
        if self.file.read_exact(&mut buf).is_err() {
            return Ok(None);
        }
        Ok(open_chunk(&self.fk, &self.uid, index, index + 1 == self.chunk_count, &buf).ok())
    }
}

/// Unlink `path` and destroy its key row, which is the cryptographic erase.
pub fn remove(path: &Path) -> Result<(), String> {
    let _swap = swap_lock();
    let uid = read_header(path).ok().flatten().map(|(h, _)| h.uid);
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("Failed to delete file: {e}")),
    }
    if let Some(uid) = uid {
        forget_key(&uid);
    }
    Ok(())
}

/// Move a file. The uid lives in the header, so a rename costs nothing; a sealed file
/// it replaces loses its key row with its bytes.
pub fn rename(from: &Path, to: &Path) -> Result<(), String> {
    let _swap = swap_lock();
    let moved = read_header(from).ok().flatten().map(|(h, _)| h.uid);
    let replaced = read_header(to).ok().flatten().map(|(h, _)| h.uid).filter(|u| Some(*u) != moved);
    std::fs::rename(from, to).map_err(|e| format!("Failed to move file: {e}"))?;
    if let Some(old) = replaced {
        forget_key(&old);
    }
    Ok(())
}

// ── boot: temp wipe and the plaintext sweep ─────────────────────────────────

/// Empty `data_dir()/temp`, where the recorder, the mic test, pasted images and
/// video posters stage plaintext.
pub fn wipe_temp_dir() {
    let Ok(dir) = crate::identity::data_dir() else { return };
    let temp = dir.join("temp");
    let Ok(entries) = std::fs::read_dir(&temp) else { return };
    for entry in entries.flatten() {
        let _ = match entry.file_type() {
            Ok(t) if t.is_dir() => std::fs::remove_dir_all(entry.path()),
            _ => std::fs::remove_file(entry.path()),
        };
    }
}

/// Progress of the one-per-boot sweep that encrypts files left plaintext by an
/// older version. Polled through [`status`]; the Storage Manager line reads it.
#[derive(Clone, Copy, Debug, Default)]
pub struct AtRestStatus {
    pub total: u32,
    pub done: u32,
    pub failed: u32,
    pub running: bool,
}

static SWEEP_TOTAL: AtomicU32 = AtomicU32::new(0);
static SWEEP_DONE: AtomicU32 = AtomicU32::new(0);
static SWEEP_FAILED: AtomicU32 = AtomicU32::new(0);
static SWEEP_RUNNING: AtomicBool = AtomicBool::new(false);

pub fn status() -> AtRestStatus {
    AtRestStatus {
        total: SWEEP_TOTAL.load(Ordering::Relaxed),
        done: SWEEP_DONE.load(Ordering::Relaxed),
        failed: SWEEP_FAILED.load(Ordering::Relaxed),
        running: SWEEP_RUNNING.load(Ordering::Relaxed),
    }
}

/// Every in-flight temp shape. A dotfile is always transient here, so the sweep
/// would race the transfer that owns it.
fn is_transient(name: &str) -> bool {
    name.starts_with('.') || name.ends_with(".partial") || name.ends_with(".hfe.tmp")
}

/// Encrypt every plaintext file the app owns, one boot at a time. Each entry is
/// either a directory to scan or a single file, so a lone file at the data root
/// converts without sweeping the identity and database files beside it. Blocking:
/// callers run it in `spawn_blocking` and watch [`status`].
pub fn migrate_plaintext(targets: &[PathBuf]) {
    migrate_plaintext_before(targets, first_touch());
}

/// [`migrate_plaintext`], taking only temps modified before `cutoff` as orphans.
fn migrate_plaintext_before(targets: &[PathBuf], cutoff: SystemTime) {
    SWEEP_RUNNING.store(true, Ordering::Relaxed);
    SWEEP_TOTAL.store(0, Ordering::Relaxed);
    SWEEP_DONE.store(0, Ordering::Relaxed);
    SWEEP_FAILED.store(0, Ordering::Relaxed);

    let mut todo: Vec<PathBuf> = Vec::new();
    for target in targets {
        if target.is_file() {
            if !is_encrypted(target) {
                todo.push(target.clone());
            }
            remove_orphan_temps(target, cutoff);
            continue;
        }
        let entries = match std::fs::read_dir(target) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => {
                hollow_log!("[HOLLOW-ATREST] could not look through a folder to protect: {e}");
                continue;
            }
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.ends_with(".hfe.tmp") {
                remove_orphan_temp(&entry.path(), cutoff);
                continue;
            }
            if is_transient(&name) {
                continue;
            }
            if entry.metadata().map(|m| m.is_file()).unwrap_or(false)
                && !is_encrypted(&entry.path())
            {
                todo.push(entry.path());
            }
        }
    }

    let total = todo.len() as u32;
    SWEEP_TOTAL.store(total, Ordering::Relaxed);

    let mut done = 0u32;
    let mut failed = 0u32;
    let mut since_yield = 0u64;
    for path in todo {
        match migrate_one(&path) {
            Ok(bytes) => {
                done += 1;
                since_yield += bytes;
                SWEEP_DONE.store(done, Ordering::Relaxed);
            }
            Err(e) => {
                failed += 1;
                SWEEP_FAILED.store(failed, Ordering::Relaxed);
                hollow_log!("[HOLLOW-ATREST] could not protect a file yet: {e}");
            }
        }
        if since_yield >= 8 * 1024 * 1024 {
            since_yield = 0;
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }
    SWEEP_RUNNING.store(false, Ordering::Relaxed);
    if total > 0 {
        hollow_log!("[HOLLOW-ATREST] sweep finished: {done} of {total} protected, {failed} deferred");
    }
}

/// A folder only an earlier run's writes filled (a cleaned send copy's): its orphan
/// temps go with their keys, then the folder itself once empty.
pub fn sweep_folder(dir: &Path) {
    sweep_folder_before(dir, first_touch());
}

fn sweep_folder_before(dir: &Path, cutoff: SystemTime) {
    let old = older_than(dir, cutoff);
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().ends_with(".hfe.tmp") {
            remove_orphan_temp(&entry.path(), cutoff);
        }
    }
    if old {
        let _ = std::fs::remove_dir(dir);
    }
}

fn migrate_one(path: &Path) -> Result<u64, String> {
    migrate_one_with(path, &|| {}, &|| {})
}

/// `before_swap` runs once the copy is sealed and `in_swap` between the check and the
/// rename: where a live write can land, and where none may.
fn migrate_one_with(path: &Path, before_swap: &dyn Fn(), in_swap: &dyn Fn()) -> Result<u64, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("Failed to stat file: {e}"))?;
    let (total_len, stamp) = (meta.len(), meta.modified().ok());
    let mut src = File::open(path).map_err(|e| format!("Failed to open file: {e}"))?;
    // A live handler may have replaced the file with ciphertext since the scan;
    // re-encrypting that would make it unreadable.
    if total_len >= MAGIC.len() as u64 {
        let mut magic = [0u8; 4];
        src.read_exact(&mut magic).map_err(|e| format!("Failed to read file: {e}"))?;
        if magic == MAGIC {
            return Ok(0);
        }
        src.rewind().map_err(|e| format!("Failed to seek: {e}"))?;
    }

    let (uid, fk) = mint_key()?;
    persist_key(&uid, &fk)?;
    let tmp = tmp_sibling(path, &uid);
    let mut reader = std::io::BufReader::new(src);
    if let Err(e) =
        write_sealed_from_reader(&tmp, &uid, &fk, DEFAULT_CHUNK_SIZE, &mut reader, total_len)
    {
        let _ = std::fs::remove_file(&tmp);
        forget_key(&uid);
        return Err(e);
    }
    drop(reader);
    before_swap();
    let _swap = swap_lock();
    // Sealing takes as long as the file is big: a write that replaced it meanwhile is
    // newer than what we sealed, and stays.
    let now = std::fs::metadata(path).ok();
    let unchanged = now.as_ref().is_some_and(|m| m.len() == total_len && m.modified().ok() == stamp) && !is_encrypted(path);
    if !unchanged {
        let _ = std::fs::remove_file(&tmp);
        forget_key(&uid);
        return if now.is_none() || is_encrypted(path) { Ok(0) } else { Err("The file changed while it was being protected".to_string()) };
    }
    in_swap();
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        forget_key(&uid);
        return Err(format!("Failed to replace file: {e}"));
    }
    Ok(total_len)
}

/// Drop every registered database and the keys loaded from it, so the next read or
/// write re-registers from whatever `messages.db` holds now. Used after an import
/// replaces the file: a ring that outlived its database would hand out keys for
/// rows that no longer exist.
pub fn forget_stores() {
    if let Ok(mut guard) = ring().write() {
        guard.stores.clear();
        guard.keys.clear();
    }
}

/// The uid in a file's header, or `None` for a legacy plaintext file.
#[cfg(test)]
pub(crate) fn uid_of(path: &Path) -> Option<[u8; 16]> {
    read_header(path).ok().flatten().map(|(h, _)| h.uid)
}

#[cfg(test)]
pub(crate) fn key_row_exists_for_test(uid: &[u8; 16]) -> bool {
    let stores = ring().read().ok().map(|g| g.stores.clone()).unwrap_or_default();
    stores.iter().any(|s| {
        MessageStore::open(&s.db_path, &s.passphrase)
            .and_then(|st| st.load_file_keys())
            .map(|rows| rows.iter().any(|(u, _, _)| u == uid))
            .unwrap_or(false)
    })
}

/// The RAW ring, with no reload: what `lookup_key` would find without going back
/// to the database.
#[cfg(test)]
pub(crate) fn key_in_ring_for_test(uid: &[u8; 16]) -> bool {
    ring_key(uid).is_some()
}

#[cfg(test)]
pub(crate) fn reset_for_test() {
    if let Ok(mut g) = ring().write() {
        g.keys.clear();
        g.stores.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ring and the sweep counters are process-global; share the harness lock
    /// so a `cargo test` thread pool cannot interleave two rings.
    fn guard() -> std::sync::MutexGuard<'static, ()> {
        crate::node::resolver::test_lock()
    }

    struct Fixture {
        _dir: crate::test_tmp::TestDir,
        root: PathBuf,
        db: String,
    }

    fn fixture() -> Fixture {
        let dir = crate::test_tmp::tempdir().expect("tempdir");
        let root = dir.path().to_path_buf();
        let db = root.join("messages.db").to_string_lossy().to_string();
        reset_for_test();
        init(&db, &"7a".repeat(32)).expect("init ring");
        Fixture { _dir: dir, root, db }
    }

    /// A sweep cutoff after every temp a test writes, so each counts as an orphan.
    fn later() -> SystemTime {
        SystemTime::now() + Duration::from_secs(3600)
    }

    fn body(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i % 251) as u8).collect()
    }

    #[test]
    fn at_rest_round_trip_empty_small_and_multi_chunk() {
        let _g = guard();
        let f = fixture();
        for len in [0usize, 1, 1024 * 1024, 3_670_016] {
            let p = f.root.join(format!("blob{len}.bin"));
            let data = body(len);
            write_all(&p, &data).expect("write");
            assert!(is_encrypted(&p), "len {len} must land encrypted");
            assert_eq!(plaintext_len(&p).expect("len"), len as u64, "len {len}");
            assert_eq!(read_all(&p).expect("read"), data, "len {len} round trip");
        }
    }

    #[test]
    fn at_rest_range_reads_cross_chunk_borders() {
        let _g = guard();
        let f = fixture();
        let p = f.root.join("ranged.bin");
        let data = body(700_000);
        let mut w = Writer::create(&p, 262_144, data.len() as u64).expect("create");
        let cs = 262_144usize;
        for idx in 0..data.len().div_ceil(cs) {
            let hi = ((idx + 1) * cs).min(data.len());
            w.write_chunk(idx as u32, &data[idx * cs..hi]).expect("chunk");
        }
        drop(w);
        for border in [0u64, 262_144, 524_288] {
            for delta in [-3i64, -1, 0, 1, 3] {
                let off = (border as i64 + delta).max(0) as u64;
                for len in [1usize, 7, 262_144, 300_000] {
                    let got = read_range(&p, off, len).expect("range");
                    let end = ((off as usize) + len).min(data.len());
                    assert_eq!(got, &data[off as usize..end], "offset {off} len {len}");
                }
            }
        }
    }

    #[test]
    fn at_rest_tamper_in_any_chunk_is_detected() {
        let _g = guard();
        let f = fixture();
        let p = f.root.join("tamper.bin");
        let data = body(3_000_000);
        write_all(&p, &data).expect("write");
        let pristine = std::fs::read(&p).expect("raw");
        let cs = DEFAULT_CHUNK_SIZE as u64;
        for idx in [0u64, 1, 2] {
            let mut raw = pristine.clone();
            let at = (HEADER_LEN + idx * (cs + TAG_LEN) + 5) as usize;
            raw[at] ^= 0x40;
            std::fs::write(&p, &raw).expect("rewrite");
            assert!(read_all(&p).is_err(), "a flipped byte in chunk {idx} must fail the read");
            assert!(read_range(&p, idx * cs, 16).is_err(), "chunk {idx} range must fail");
            let other = if idx == 0 { 2 } else { 0 };
            assert!(
                read_range(&p, other * cs, 16).is_ok(),
                "an untouched chunk still reads while chunk {idx} is damaged",
            );
        }
    }

    #[test]
    fn at_rest_truncation_is_detected() {
        let _g = guard();
        let f = fixture();
        let p = f.root.join("trunc.bin");
        let data = body(2_500_000);
        write_all(&p, &data).expect("write");
        let raw = std::fs::read(&p).expect("raw");

        let last_chunk = (data.len() as u64 % DEFAULT_CHUNK_SIZE as u64) + TAG_LEN;
        std::fs::write(&p, &raw[..raw.len() - last_chunk as usize]).expect("drop last chunk");
        assert!(read_all(&p).is_err(), "dropping the final chunk must fail: the new last chunk was sealed as not-last");

        std::fs::write(&p, &raw[..raw.len() - 1]).expect("drop one byte");
        assert!(read_all(&p).is_err(), "dropping one byte must fail the tag");
    }

    #[test]
    fn at_rest_out_of_order_chunk_writes_match_sequential() {
        let _g = guard();
        let f = fixture();
        let data = body(1_100_000);
        let cs = 262_144usize;

        let seq = f.root.join("seq.bin");
        write_all(&seq, &data).expect("write all");

        let shuffled = f.root.join("shuffled.bin");
        let mut w = Writer::create(&shuffled, cs as u32, data.len() as u64).expect("create");
        let n = data.len().div_ceil(cs);
        let mut order: Vec<usize> = (0..n).collect();
        order.swap(0, n - 1);
        order.swap(1, 2);
        for idx in order {
            let hi = ((idx + 1) * cs).min(data.len());
            w.write_chunk(idx as u32, &data[idx * cs..hi]).expect("chunk");
        }
        drop(w);

        assert_eq!(read_all(&shuffled).expect("read"), data);
        assert_eq!(read_all(&seq).expect("read"), read_all(&shuffled).expect("read"));
        assert_eq!(plaintext_len(&shuffled).expect("len"), data.len() as u64);
    }

    #[test]
    fn at_rest_legacy_plaintext_passthrough_and_missing_row_refuses() {
        let _g = guard();
        let f = fixture();
        let legacy = f.root.join("legacy.bin");
        let data = body(4096);
        std::fs::write(&legacy, &data).expect("write legacy");
        assert!(!is_encrypted(&legacy));
        assert_eq!(read_all(&legacy).expect("read"), data);
        assert_eq!(read_range(&legacy, 100, 50).expect("range"), &data[100..150]);
        assert_eq!(plaintext_len(&legacy).expect("len"), data.len() as u64);

        let orphan = f.root.join("orphan.bin");
        write_all(&orphan, &data).expect("write");
        let uid = read_header(&orphan).expect("hdr").expect("encrypted").0.uid;
        forget_key(&uid);
        let err = read_all(&orphan).expect_err("a header with no key row must refuse");
        assert!(err.contains("key missing"), "got {err}");
    }

    #[test]
    fn at_rest_migration_resumes_from_every_crash_point() {
        let _g = guard();
        let f = fixture();
        let dir = f.root.join("files");
        std::fs::create_dir_all(&dir).expect("mkdir");

        let a = dir.join("a.bin");
        let b = dir.join("b.bin");
        let c = dir.join("c.bin");
        let data = body(40_000);
        for p in [&a, &b, &c] {
            std::fs::write(p, &data).expect("seed");
        }
        // Crash point 1: a temp written, no row. Crash point 2: a temp plus a row,
        // no rename. Crash point 3: already done.
        std::fs::write(tmp_sibling(&a, &[0u8; 16]), b"garbage").expect("orphan tmp");
        let (uid, fk) = mint_key().expect("key");
        persist_key(&uid, &fk).expect("row");
        write_sealed(&tmp_sibling(&b, &uid), &uid, &fk, DEFAULT_CHUNK_SIZE, &data).expect("sealed tmp");
        write_all(&c, &data).expect("already done");
        std::fs::write(dir.join(".stream_send_x.tmp"), b"in flight").expect("transient");

        // A loose file at the data root is a target in its own right: the root
        // itself is never scanned, because the identity and the database live there.
        let loose = f.root.join("custom_background.img");
        std::fs::write(&loose, &data).expect("seed the loose file");
        let keep = f.root.join("identity.key");
        std::fs::write(&keep, b"not content").expect("seed a root file");
        let loose_orphan = tmp_sibling(&loose, &[1u8; 16]);
        std::fs::write(&loose_orphan, b"garbage").expect("an orphan temp beside the loose file");

        let targets = vec![dir.clone(), loose.clone()];
        migrate_plaintext_before(&targets, later());
        assert_eq!(status().failed, 0, "nothing should fail");
        assert_eq!(status().done, 3, "a.bin, b.bin and the loose file convert; c.bin was done");
        assert!(is_encrypted(&loose), "a named single file converts");
        assert_eq!(std::fs::read(&keep).expect("root file"), b"not content", "the data root is never swept");
        assert!(!loose_orphan.exists(), "a loose file's orphan temp is swept");
        assert!(!key_row_exists_for_test(&uid), "a swept temp's own key row goes with it");
        migrate_plaintext_before(&targets, later());

        for p in [&a, &b, &c] {
            assert!(is_encrypted(p), "{p:?} converged to ciphertext");
            assert_eq!(read_all(p).expect("read"), data, "{p:?} round trips");
        }
        let temps = std::fs::read_dir(&dir).expect("files").flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".hfe.tmp")).count();
        assert_eq!(temps, 0, "no .hfe.tmp left");
        assert_eq!(
            std::fs::read(dir.join(".stream_send_x.tmp")).expect("transient survives"),
            b"in flight",
            "an in-flight dotfile is never swept",
        );
        assert!(!status().running);
    }

    #[test]
    fn at_rest_remove_deletes_key_row_and_file() {
        let _g = guard();
        let f = fixture();
        let p = f.root.join("doomed.bin");
        write_all(&p, &body(2048)).expect("write");
        let uid = read_header(&p).expect("hdr").expect("encrypted").0.uid;
        let store = MessageStore::open(&f.db, &"7a".repeat(32)).expect("open");
        assert!(store.load_file_keys().expect("rows").iter().any(|(u, _, _)| *u == uid));
        drop(store);

        remove(&p).expect("remove");
        assert!(!p.exists(), "file gone");
        let store = MessageStore::open(&f.db, &"7a".repeat(32)).expect("open");
        assert!(
            !store.load_file_keys().expect("rows").iter().any(|(u, _, _)| *u == uid),
            "the key row dies with the file",
        );
        remove(&p).expect("removing a missing file is not an error");
    }

    #[test]
    fn at_rest_migration_streams_large_files() {
        let _g = guard();
        let f = fixture();
        let dir = f.root.join("files");
        std::fs::create_dir_all(&dir).expect("mkdir");
        let data = body(3_670_016);
        let swept = dir.join("big.bin");
        std::fs::write(&swept, &data).expect("seed");

        migrate_plaintext(std::slice::from_ref(&dir));

        let direct = f.root.join("direct.bin");
        write_all(&direct, &data).expect("write");

        let (hs, ls) = read_header(&swept).expect("hdr").expect("the sweep encrypted it");
        let (hd, ld) = read_header(&direct).expect("hdr").expect("encrypted");
        assert_eq!(hs.chunk_size, hd.chunk_size, "same chunk size");
        assert_eq!(ls, ld, "same ciphertext length");
        let n = chunk_count_from_len(ls, hs.chunk_size);
        assert_eq!(n, chunk_count_from_len(ld, hd.chunk_size), "same chunk count");
        assert_eq!(read_all(&swept).expect("read"), data, "the swept file round trips");
        for idx in 0..n as u64 {
            let off = idx * hs.chunk_size as u64;
            let take = (data.len() as u64 - off).min(hs.chunk_size as u64) as usize;
            assert_eq!(
                read_range(&swept, off, take).expect("swept chunk"),
                read_range(&direct, off, take).expect("direct chunk"),
                "chunk {idx} matches the whole-file layout",
            );
        }
    }

    #[test]
    fn at_rest_writer_refuses_a_differing_rewrite_of_a_chunk() {
        let _g = guard();
        let f = fixture();
        let p = f.root.join("rewrite.bin");
        let cs = 4096usize;
        let data = body(10_000);
        let mut w = Writer::create(&p, cs as u32, data.len() as u64).expect("create");
        for idx in 0..3u32 {
            let lo = idx as usize * cs;
            let hi = (lo + cs).min(data.len());
            w.write_chunk(idx, &data[lo..hi]).expect("first write");
        }
        w.write_chunk(1, &data[cs..2 * cs]).expect("an identical rewrite is a retransmit");

        let mut other = data[cs..2 * cs].to_vec();
        other[0] ^= 0xff;
        let err = w
            .write_chunk(1, &other)
            .expect_err("a differing rewrite reuses the key and nonce and must be refused");
        assert!(err.contains("different bytes"), "got {err}");
        drop(w);
        assert_eq!(read_all(&p).expect("read"), data, "the original chunk survives");
    }

    #[test]
    fn at_rest_lookup_after_forget_stores_reloads_from_db() {
        let _g = guard();
        let dir = crate::test_tmp::tempdir().expect("tempdir");
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", dir.path()) };
        reset_for_test();
        // The ring has to find its own database again from the identity alone, which
        // is all an import (or an FFI read before the node starts) leaves it.
        let id = crate::identity::load_or_create_identity().expect("identity");
        let proto = id.keypair.to_protobuf_encoding().expect("encode keypair");
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        let db = dir.path().join("messages.db").to_string_lossy().to_string();
        init(&db, &passphrase).expect("ring");

        let p = dir.path().join("files").join("reload.bin");
        let data = body(9_000);
        write_all(&p, &data).expect("write");
        let uid = uid_of(&p).expect("header");

        forget_stores();
        assert!(!key_in_ring_for_test(&uid), "an import leaves no keys behind");
        assert_eq!(
            read_all(&p).expect("a read must reload the ring"),
            data,
            "a lookup miss reloads from the database rather than failing",
        );
    }

    #[test]
    fn at_rest_export_decrypts_to_destination() {
        let _g = guard();
        let f = fixture();
        let src = f.root.join("src.bin");
        let dest = f.root.join("out").join("copy.bin");
        let data = body(1_500_000);
        write_all(&src, &data).expect("write");
        let n = export_to(&src, &dest).expect("export");
        assert_eq!(n, data.len() as u64);
        assert_eq!(std::fs::read(&dest).expect("read export"), data);
    }

    /// A send that died mid-way leaves its staging folder; the boot sweep takes it.
    #[test]
    fn the_boot_sweep_empties_temp_folders_too() {
        let _g = guard();
        let dir = crate::test_tmp::tempdir().expect("tempdir");
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", dir.path()) };
        let staged = dir.path().join("temp").join("vthumb_ab12");
        std::fs::create_dir_all(&staged).expect("staging dir");
        std::fs::write(staged.join("mid.webp"), b"plaintext poster").expect("poster");
        std::fs::write(dir.path().join("temp").join("clipboard_1.png"), b"pasted").expect("paste");

        wipe_temp_dir();

        let left: Vec<_> = std::fs::read_dir(dir.path().join("temp")).expect("temp").flatten().collect();
        assert!(left.is_empty(), "the boot sweep left {} entries", left.len());
    }

    /// Two writers replace one path while a reader reads it: every write lands, every
    /// read sees one whole file, and what stays on disk keeps its key.
    #[test]
    fn at_rest_concurrent_replaces_of_one_path_stay_readable() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("raced.bin");
        let data = body(300_000);
        write_all(&path, &data).expect("seed");
        let writing = AtomicU32::new(2);
        std::thread::scope(|s| {
            for _ in 0..2 {
                s.spawn(|| {
                    for _ in 0..40 {
                        write_all(&path, &data).expect("a replace beside another writer");
                    }
                    writing.fetch_sub(1, Ordering::SeqCst);
                });
            }
            s.spawn(|| {
                while writing.load(Ordering::SeqCst) > 0 {
                    assert_eq!(read_all(&path).expect("a read during replaces"), data);
                    assert_eq!(read_range(&path, 262_000, 1_000).expect("a range read during replaces"), &data[262_000..263_000]);
                }
            });
        });
        assert_eq!(read_all(&path).expect("the last write stays readable"), data);
        let rows = MessageStore::lease(&f.db, &"7a".repeat(32)).expect("store").load_file_keys().expect("rows").len();
        assert_eq!(rows, 1, "every replaced file's key row dies with it");
        let temps = std::fs::read_dir(&f.root).expect("root").flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".hfe.tmp")).count();
        assert_eq!(temps, 0, "a replace left its temp behind");
    }

    /// Many writers replacing one small file: a write's swap of the file and its key's
    /// retirement never interleave with another's, so no replaced file's key row stays.
    #[test]
    fn at_rest_concurrent_small_replaces_leave_one_key_row() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("small.bin");
        let data = body(16);
        std::thread::scope(|s| {
            for _ in 0..4 {
                s.spawn(|| {
                    for _ in 0..150 {
                        write_all(&path, &data).expect("a small replace beside other writers");
                    }
                });
            }
        });
        assert_eq!(read_all(&path).expect("the last write stays readable"), data);
        let rows = MessageStore::lease(&f.db, &"7a".repeat(32)).expect("store").load_file_keys().expect("rows").len();
        assert_eq!(rows, 1, "every replaced file's key row dies with it");
    }

    /// A writer swaps a newer file in and retires the old key between a read's open
    /// and its key lookup: the read takes the newer file, never a missing key.
    #[test]
    fn at_rest_a_read_whose_key_a_swap_retired_reads_the_newer_file() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("swapped.bin");
        let (old, new) = (body(5_000), body(7_000));
        write_all(&path, &old).expect("seed");
        let swapped = std::cell::Cell::new(false);
        let lookup = |uid: &[u8; 16]| {
            if !swapped.replace(true) {
                write_all(&path, &new).expect("a swap between the open and the lookup");
            }
            lookup_key(uid)
        };
        let opened = open_for_read_with(&path, &lookup).expect("the read reopens the newer file");
        assert_eq!(read_opened(opened).expect("read"), new);
    }

    /// The push process (iOS NSE) seals a file into the shared files/ and its row into
    /// the shared messages.db; the running app's ring never saw that row.
    #[test]
    fn at_rest_a_file_another_process_sealed_reads_back() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("nse.bin");
        let data = body(10_000);
        let (uid, fk) = mint_key().expect("key");
        MessageStore::lease(&f.db, &"7a".repeat(32)).expect("store").insert_file_key(&uid, &fk.key, &fk.nonce).expect("row");
        write_sealed(&path, &uid, &fk, DEFAULT_CHUNK_SIZE, &data).expect("sealed");
        assert_eq!(read_all(&path).expect("a file another process sealed reads in the app"), data);
        assert!(key_in_ring_for_test(&uid), "the key it found stays in the ring");
    }

    /// A live write replaces a legacy plaintext file while the boot sweep seals it: the
    /// newer file stays, and the sweep's copy goes with its key.
    #[test]
    fn at_rest_a_write_during_the_sweep_is_not_reverted() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("custom.img");
        std::fs::write(&path, body(50_000)).expect("legacy plaintext");
        let new = b"the newer bytes a live handler wrote".to_vec();
        migrate_one_with(&path, &|| write_all(&path, &new).expect("a live write during the sweep"), &|| {}).expect("the sweep");
        let rows = MessageStore::lease(&f.db, &"7a".repeat(32)).expect("store").load_file_keys().expect("rows").len();
        let got = read_all(&path).expect("read");
        assert!(got == new, "the sweep sealed the OLD plaintext over a newer write ({} bytes on disk, {rows} key rows)", got.len());
        assert_eq!(rows, 1, "the sweep's own key row stays");
        let temps = std::fs::read_dir(&f.root).expect("root").flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".hfe.tmp")).count();
        assert_eq!(temps, 0, "the sweep left its temp behind");
    }

    /// A live write arriving between the sweep's check and its swap waits for the swap,
    /// then replaces the sweep's copy.
    #[test]
    fn at_rest_a_write_racing_the_sweeps_swap_waits_for_it() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("raced.img");
        std::fs::write(&path, body(50_000)).expect("legacy plaintext");
        let new = b"the newer bytes a live handler wrote".to_vec();
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        std::thread::scope(|s| {
            let in_swap = || {
                let (path, new, tx) = (&path, &new, tx.clone());
                s.spawn(move || {
                    write_all(path, new).expect("a live write at the swap");
                    let _ = tx.send(());
                });
                let _ = rx.recv_timeout(Duration::from_millis(500));
            };
            migrate_one_with(&path, &|| {}, &in_swap).expect("the sweep");
        });
        assert_eq!(read_all(&path).expect("read"), new, "the sweep's swap reverted a live write");
        let rows = MessageStore::lease(&f.db, &"7a".repeat(32)).expect("store").load_file_keys().expect("rows").len();
        assert_eq!(rows, 1, "the replaced copy's key row stays");
    }

    /// A loose file's orphan sweep takes only `{name}.{16 hex}.hfe.tmp`, never another
    /// file's temp that shares its prefix.
    #[test]
    fn at_rest_the_loose_orphan_sweep_spares_another_file_s_temp() {
        let _g = guard();
        let f = fixture();
        let loose = f.root.join("custom_background.img");
        write_all(&loose, &body(100)).expect("loose");
        let other = tmp_sibling(&f.root.join("custom_background.img.bak"), &[9u8; 16]);
        std::fs::write(&other, b"another file's temp").expect("other temp");
        let own = tmp_sibling(&loose, &[8u8; 16]);
        std::fs::write(&own, b"its own orphan").expect("own temp");
        migrate_plaintext_before(std::slice::from_ref(&loose), later());
        assert!(!own.exists(), "precondition: the sweep took the loose file's own orphan");
        assert!(other.exists(), "the sweep of one loose file removed another file's temp {other:?}");
    }

    /// Temps this process may still be writing are never orphans to the boot sweep,
    /// in a swept folder or beside a loose file.
    #[test]
    fn at_rest_the_sweep_spares_a_temp_this_process_is_writing() {
        let _g = guard();
        let f = fixture();
        let dir = f.root.join("files");
        std::fs::create_dir_all(&dir).expect("dir");
        let (uid, fk) = mint_key().expect("key");
        persist_key(&uid, &fk).expect("row");
        let live = tmp_sibling(&dir.join("x.bin"), &uid);
        write_sealed(&live, &uid, &fk, DEFAULT_CHUNK_SIZE, &body(100)).expect("a live write's temp");
        let loose = f.root.join("custom_background.img");
        write_all(&loose, &body(100)).expect("loose");
        let loose_live = tmp_sibling(&loose, &[7u8; 16]);
        std::fs::write(&loose_live, b"in flight").expect("loose temp");
        migrate_plaintext(&[dir.clone(), loose.clone()]);
        assert!(live.exists() && loose_live.exists(), "the sweep took a temp written after this process started");
        assert!(key_row_exists_for_test(&uid), "the sweep forgot a live write's key");
    }

    /// A cleaned send copy's folder keeps the copy; its orphan temps go with their keys,
    /// and a folder left with nothing goes too.
    #[test]
    fn at_rest_a_folder_sweep_takes_orphan_temps_and_their_keys() {
        let _g = guard();
        let f = fixture();
        let kept = f.root.join("send_aa");
        let copy = kept.join("photo.jpg");
        write_all(&copy, &body(100)).expect("the copy");
        let orphan = |dir: &Path| {
            let (uid, fk) = mint_key().expect("key");
            persist_key(&uid, &fk).expect("row");
            write_sealed(&tmp_sibling(&dir.join("photo.jpg"), &uid), &uid, &fk, DEFAULT_CHUNK_SIZE, &body(100)).expect("sealed temp");
            uid
        };
        let in_kept = orphan(&kept);
        let emptied = f.root.join("send_bb");
        std::fs::create_dir_all(&emptied).expect("dir");
        let in_emptied = orphan(&emptied);
        for dir in [&kept, &emptied] {
            sweep_folder_before(dir, later());
        }
        assert!(!key_row_exists_for_test(&in_kept) && !key_row_exists_for_test(&in_emptied), "a swept temp kept its key row");
        assert_eq!(read_all(&copy).expect("the copy stays"), body(100));
        let left = std::fs::read_dir(&kept).expect("kept").count();
        assert_eq!(left, 1, "only the copy stays in its folder");
        assert!(!emptied.exists(), "a folder left empty goes");
        sweep_folder(&kept);
        assert!(kept.exists(), "a folder holding a copy stays");
    }

    /// Removes beside replaces of the same path: a remove's unlink and its key's
    /// retirement name one file, so no key row outlives its file.
    #[test]
    fn at_rest_a_remove_beside_replaces_leaves_no_stray_row() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("removed.bin");
        let data = body(16);
        let removing = AtomicBool::new(true);
        std::thread::scope(|s| {
            for _ in 0..3 {
                s.spawn(|| {
                    while removing.load(Ordering::SeqCst) {
                        write_all(&path, &data).expect("a replace");
                    }
                });
            }
            s.spawn(|| {
                for _ in 0..3_000 {
                    remove(&path).expect("a remove");
                }
                removing.store(false, Ordering::SeqCst);
            });
        });
        remove(&path).expect("the last remove");
        let rows = MessageStore::lease(&f.db, &"7a".repeat(32)).expect("store").load_file_keys().expect("rows").len();
        assert_eq!(rows, 0, "a key row outlived its file");
    }

    /// A remove, a chunked create and a move each beside a replace of the same path:
    /// every key row left names a file on disk.
    #[test]
    fn at_rest_a_remove_create_or_move_beside_a_replace_leaves_no_stray_row() {
        let _g = guard();
        let f = fixture();
        let path = f.root.join("contended.bin");
        let from = f.root.join("incoming.bin");
        let data = body(16);
        std::thread::scope(|s| {
            for _ in 0..2 {
                s.spawn(|| {
                    for _ in 0..300 {
                        write_all(&path, &data).expect("a replace");
                    }
                });
            }
            s.spawn(|| {
                for _ in 0..300 {
                    remove(&path).expect("a remove");
                }
            });
            s.spawn(|| {
                for _ in 0..300 {
                    drop(Writer::create(&path, MIN_CHUNK_SIZE, data.len() as u64).expect("a chunked create"));
                }
            });
            s.spawn(|| {
                for _ in 0..300 {
                    write_all(&from, &data).expect("a write to move");
                    rename(&from, &path).expect("a move");
                }
            });
        });
        remove(&path).expect("the last remove");
        let rows = MessageStore::lease(&f.db, &"7a".repeat(32)).expect("store").load_file_keys().expect("rows").len();
        assert_eq!(rows, 0, "a key row outlived its file");
    }

    /// A move over a sealed file retires the replaced file's key; moving a file onto
    /// itself keeps its own.
    #[test]
    fn at_rest_a_move_over_a_sealed_file_retires_its_key() {
        let _g = guard();
        let f = fixture();
        let (from, to) = (f.root.join("a.bin"), f.root.join("b.bin"));
        write_all(&from, &body(10)).expect("from");
        write_all(&to, &body(20)).expect("to");
        let (moved, replaced) = (uid_of(&from).expect("sealed"), uid_of(&to).expect("sealed"));
        rename(&from, &to).expect("move");
        assert!(!key_row_exists_for_test(&replaced), "the replaced file's key row stayed");
        rename(&to, &to).expect("a move onto itself");
        assert!(key_row_exists_for_test(&moved) && key_in_ring_for_test(&moved), "the moved file lost its key");
        assert_eq!(read_all(&to).expect("read"), body(10));
    }
}
