//! Chunked file/shard streaming over WebSocket binary frames.
//!
//! Chunk payload format (inside a WS binary frame):
//!   First chunk:        [type:1][id:64][total_size:8][shard_index:2 (shard only)][data...]
//!   Continuation chunk: [0xFF:1][id:64][data...]
//!
//! One chunk per frame, in order (WS = TCP). The receiver reassembles into a temp
//! file, then returns a `StreamRequest` on completion.

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use tokio::sync::mpsc;

use crate::hollow_log;
use super::ws_client::WsCommand;
use super::file_transfer::files_dir;

// ── Shared stream types (moved from stream_transfer.rs) ─────

/// What kind of transfer this is.
#[derive(Debug, Clone)]
pub enum StreamKind {
    /// P2P file transfer (DM or channel file).
    File,
    /// Vault shard transfer.
    Shard { shard_index: u16 },
    /// Hollow Share encrypted chunk. `id` is the share's root_hash (hex);
    /// `chunk_index` identifies which chunk this is.
    ShareChunk { chunk_index: u32 },
    /// Multi-device link snapshot (full encrypted DB+identity bundle). `id` is the
    /// link session id (hex). Same wire shape as `File` — reassembled to a temp file,
    /// then decrypted+imported by `file_handler::handle_completed_stream`.
    LinkSnapshot,
}

/// The request type used for both sending and receiving.
/// On the sender side, `temp_path` points to the file to stream FROM.
/// On the receiver side, `temp_path` is where the received bytes were written.
#[derive(Debug)]
pub struct StreamRequest {
    pub kind: StreamKind,
    /// Hex identifier (file_id for files, content_id for shards).
    pub id: String,
    /// Total bytes to transfer.
    pub size: u64,
    /// Path to the data file (source on sender, destination on receiver).
    pub temp_path: PathBuf,
}

/// Tracks bytes received per file_id. Polled by the event loop to emit FileProgress events.
#[derive(Debug, Clone)]
pub struct StreamProgress {
    pub bytes_received: Arc<AtomicU64>,
    pub total_bytes: u64,
}

/// Global progress map.
pub fn stream_progress() -> &'static std::sync::Mutex<HashMap<String, StreamProgress>> {
    static INSTANCE: std::sync::OnceLock<std::sync::Mutex<HashMap<String, StreamProgress>>> = std::sync::OnceLock::new();
    INSTANCE.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

// ─────────────────────────────────────────────────────────────

/// 256 KB per WS binary frame payload.
const WS_CHUNK_SIZE: usize = 256 * 1024;

const TYPE_FILE: u8 = 0;
const TYPE_SHARD: u8 = 1;
const TYPE_SHARE_CHUNK: u8 = 2;
const TYPE_LINK: u8 = 3;
const TYPE_CONTINUATION: u8 = 0xFF;

/// Receive streams one peer, and all peers together, may hold open: every open
/// stream is a temp file on disk until it completes or we disconnect.
const MAX_RECV_STREAMS_PER_SENDER: usize = 16;
const MAX_RECV_STREAMS: usize = 128;

/// Numbers each receive temp file of this process.
static RECV_TEMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// How long a stream sits idle before another peer may open its id afresh (the
/// next holder after one that stalled). Until then the id is its opener's alone.
const STREAM_TAKEOVER_IDLE: std::time::Duration = std::time::Duration::from_secs(10);

/// State for an in-progress WS stream transfer (receiver side).
pub struct WsTransferState {
    pub kind: StreamKind,
    pub id: String,
    pub total_size: u64,
    pub bytes_received: u64,
    pub temp_file: std::fs::File,
    pub temp_path: PathBuf,
    pub progress: Option<Arc<AtomicU64>>,
    /// The device that opened the stream: only its frames extend it.
    pub sender: String,
    pub last_frame_at: std::time::Instant,
}

/// Send a file or shard to a peer via chunked WS binary frames.
/// Streams from disk in WS_CHUNK_SIZE increments — never loads the full file into memory.
/// If `start_offset > 0`, seeks past already-sent bytes (for transfer resumption).
pub async fn ws_stream_send(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    room_code: &str,
    target_peer: &str,
    kind: &StreamKind,
    id: &str,
    source_path: &std::path::Path,
    total_size: u64,
    start_offset: u64,
) {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};

    let mut file = match tokio::fs::File::open(source_path).await {
        Ok(f) => tokio::io::BufReader::new(f),
        Err(e) => {
            hollow_log!("[HOLLOW-WS-STREAM] Failed to open source {}: {e}", source_path.display());
            return;
        }
    };

    if start_offset > 0 {
        if let Err(e) = file.seek(std::io::SeekFrom::Start(start_offset)).await {
            hollow_log!("[HOLLOW-WS-STREAM] Failed to seek to offset {start_offset}: {e}");
            return;
        }
        hollow_log!("[HOLLOW-WS-STREAM] Resuming {id} from offset {start_offset}/{total_size}");
    }

    // Build header for first chunk.
    // Wire format: [type:1][id:64][size:8][extra...][data]
    //   File:       extra = (none)
    //   Shard:      extra = shard_index:u16 LE (2 bytes)
    //   ShareChunk: extra = chunk_index:u32 LE (4 bytes)
    let id_padded = pad_id(id);
    let extra_len: usize = match kind {
        StreamKind::File | StreamKind::LinkSnapshot => 0,
        StreamKind::Shard { .. } => 2,
        StreamKind::ShareChunk { .. } => 4,
    };
    let header_len = 1 + 64 + 8 + extra_len;
    let first_data_cap = WS_CHUNK_SIZE.saturating_sub(header_len).min(total_size as usize);

    let mut first_chunk = Vec::with_capacity(header_len + first_data_cap);
    first_chunk.push(match kind {
        StreamKind::File => TYPE_FILE,
        StreamKind::Shard { .. } => TYPE_SHARD,
        StreamKind::ShareChunk { .. } => TYPE_SHARE_CHUNK,
        StreamKind::LinkSnapshot => TYPE_LINK,
    });
    first_chunk.extend_from_slice(&id_padded);
    first_chunk.extend_from_slice(&total_size.to_le_bytes());
    match kind {
        StreamKind::Shard { shard_index } => {
            first_chunk.extend_from_slice(&shard_index.to_le_bytes());
        }
        StreamKind::ShareChunk { chunk_index } => {
            first_chunk.extend_from_slice(&chunk_index.to_le_bytes());
        }
        StreamKind::File | StreamKind::LinkSnapshot => {}
    }

    let mut read_buf = vec![0u8; first_data_cap];
    let first_read = match file.read(&mut read_buf).await {
        Ok(n) => n,
        Err(e) => {
            hollow_log!("[HOLLOW-WS-STREAM] Failed to read first chunk: {e}");
            return;
        }
    };
    first_chunk.extend_from_slice(&read_buf[..first_read]);

    let _ = ws_cmd_tx.send(WsCommand::SendBinaryDirect {
        room_code: room_code.to_string(),
        target_peer: target_peer.to_string(),
        data: first_chunk,
    });

    let mut bytes_sent = first_read as u64;
    let mut chunk_count: u64 = 1;
    let cont_data_cap = WS_CHUNK_SIZE.saturating_sub(65);
    let mut cont_buf = vec![0u8; cont_data_cap];

    while bytes_sent < total_size {
        tokio::task::yield_now().await;

        let n = match file.read(&mut cont_buf).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                hollow_log!("[HOLLOW-WS-STREAM] Read error at offset {bytes_sent}: {e}");
                break;
            }
        };

        let mut chunk = Vec::with_capacity(65 + n);
        chunk.push(TYPE_CONTINUATION);
        chunk.extend_from_slice(&id_padded);
        chunk.extend_from_slice(&cont_buf[..n]);

        let _ = ws_cmd_tx.send(WsCommand::SendBinaryDirect {
            room_code: room_code.to_string(),
            target_peer: target_peer.to_string(),
            data: chunk,
        });

        bytes_sent += n as u64;
        chunk_count += 1;
    }

    hollow_log!("[HOLLOW-WS-STREAM] Sent {id} ({total_size} bytes) to {target_peer} in {chunk_count} chunks");
}

/// Send data to a peer via chunked WS binary frames, reading from an in-memory buffer.
/// Same wire format as `ws_stream_send` but avoids the disk round-trip.
pub async fn ws_stream_send_bytes(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    room_code: &str,
    target_peer: &str,
    kind: &StreamKind,
    id: &str,
    data: &[u8],
) {
    use std::io::Read;

    let total_size = data.len() as u64;
    let mut cursor = std::io::Cursor::new(data);

    let id_padded = pad_id(id);
    let extra_len: usize = match kind {
        StreamKind::File | StreamKind::LinkSnapshot => 0,
        StreamKind::Shard { .. } => 2,
        StreamKind::ShareChunk { .. } => 4,
    };
    let header_len = 1 + 64 + 8 + extra_len;
    let first_data_cap = WS_CHUNK_SIZE.saturating_sub(header_len).min(data.len());

    let mut first_chunk = Vec::with_capacity(header_len + first_data_cap);
    first_chunk.push(match kind {
        StreamKind::File => TYPE_FILE,
        StreamKind::Shard { .. } => TYPE_SHARD,
        StreamKind::ShareChunk { .. } => TYPE_SHARE_CHUNK,
        StreamKind::LinkSnapshot => TYPE_LINK,
    });
    first_chunk.extend_from_slice(&id_padded);
    first_chunk.extend_from_slice(&total_size.to_le_bytes());
    match kind {
        StreamKind::Shard { shard_index } => {
            first_chunk.extend_from_slice(&shard_index.to_le_bytes());
        }
        StreamKind::ShareChunk { chunk_index } => {
            first_chunk.extend_from_slice(&chunk_index.to_le_bytes());
        }
        StreamKind::File | StreamKind::LinkSnapshot => {}
    }

    let mut read_buf = vec![0u8; first_data_cap];
    let first_read = match cursor.read(&mut read_buf) {
        Ok(n) => n,
        Err(e) => {
            hollow_log!("[HOLLOW-WS-STREAM] Failed to read first chunk from bytes: {e}");
            return;
        }
    };
    first_chunk.extend_from_slice(&read_buf[..first_read]);

    let _ = ws_cmd_tx.send(WsCommand::SendBinaryDirect {
        room_code: room_code.to_string(),
        target_peer: target_peer.to_string(),
        data: first_chunk,
    });

    let mut bytes_sent = first_read as u64;
    let mut chunk_count: u64 = 1;
    let cont_data_cap = WS_CHUNK_SIZE.saturating_sub(65);
    let mut cont_buf = vec![0u8; cont_data_cap];

    while bytes_sent < total_size {
        tokio::task::yield_now().await;

        let n = match cursor.read(&mut cont_buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                hollow_log!("[HOLLOW-WS-STREAM] Read error from bytes at offset {bytes_sent}: {e}");
                break;
            }
        };

        let mut chunk = Vec::with_capacity(65 + n);
        chunk.push(TYPE_CONTINUATION);
        chunk.extend_from_slice(&id_padded);
        chunk.extend_from_slice(&cont_buf[..n]);

        let _ = ws_cmd_tx.send(WsCommand::SendBinaryDirect {
            room_code: room_code.to_string(),
            target_peer: target_peer.to_string(),
            data: chunk,
        });

        bytes_sent += n as u64;
        chunk_count += 1;
    }

    hollow_log!("[HOLLOW-WS-STREAM] Sent {id} ({total_size} bytes, in-memory) to {target_peer} in {chunk_count} chunks");
}

/// Append `payload` to an open stream, ending it when it reaches its declared size.
/// A sender that writes past that size loses the stream.
fn append_frame(
    pending: &mut HashMap<String, WsTransferState>,
    id: &str,
    payload: &[u8],
) -> Option<StreamRequest> {
    let state = pending.get_mut(id)?;
    let received = state.bytes_received.saturating_add(payload.len() as u64);
    if received > state.total_size {
        hollow_log!("[HOLLOW-WS-STREAM] Dropped {id}: {received} bytes past its declared {}", state.total_size);
        abandon(pending, id);
        return None;
    }
    if let Err(e) = state.temp_file.write_all(payload) {
        hollow_log!("[HOLLOW-WS-STREAM] Write failed for {id}: {e}");
        abandon(pending, id);
        return None;
    }
    state.bytes_received = received;
    state.last_frame_at = std::time::Instant::now();
    if let Some(ref progress) = state.progress {
        progress.store(state.bytes_received, Ordering::Relaxed);
    }
    if state.bytes_received >= state.total_size {
        return complete_transfer(pending, id);
    }
    None
}

fn abandon(pending: &mut HashMap<String, WsTransferState>, id: &str) {
    if let Some(state) = pending.remove(id) {
        drop(state.temp_file);
        let _ = std::fs::remove_file(&state.temp_path);
        if let Ok(mut map) = stream_progress().lock() {
            map.remove(id);
        }
    }
}

/// Process a received WS binary chunk from `from`. Called from the swarm when
/// BinaryDirect arrives. Returns `Some(StreamRequest)` when the transfer is complete
/// (all bytes received).
///
/// `ceiling` names the most bytes a new stream of that kind and id may declare.
pub fn ws_stream_receive(
    pending: &mut HashMap<String, WsTransferState>,
    from: &str,
    data: &[u8],
    ceiling: impl Fn(&StreamKind, &str) -> u64,
) -> Option<StreamRequest> {
    if data.is_empty() {
        return None;
    }

    let type_byte = data[0];

    if type_byte == TYPE_CONTINUATION {
        // Continuation chunk: [0xFF][id:64][data...]
        if data.len() < 65 {
            return None;
        }
        let Some(id) = parse_id(&data[1..65]) else {
            hollow_log!("[HOLLOW-WS-STREAM] Dropped continuation: id outside the allowlist");
            return None;
        };
        if pending.get(&id)?.sender != from {
            hollow_log!("[HOLLOW-SECURITY] Dropped a continuation of {id} from {from}: another peer's stream");
            return None;
        }
        append_frame(pending, &id, &data[65..])
    } else if type_byte == TYPE_FILE || type_byte == TYPE_SHARD || type_byte == TYPE_SHARE_CHUNK || type_byte == TYPE_LINK {
        // First chunk: [type][id:64][size:8][extra...][data]
        let min_len = 1 + 64 + 8;
        if data.len() < min_len {
            return None;
        }
        let Some(id) = parse_id(&data[1..65]) else {
            hollow_log!("[HOLLOW-WS-STREAM] Dropped stream frame: id outside the allowlist");
            return None;
        };
        let total_size = u64::from_le_bytes(data[65..73].try_into().unwrap_or([0; 8]));

        let (kind, payload_start) = match type_byte {
            TYPE_SHARD => {
                if data.len() < min_len + 2 {
                    return None;
                }
                let si = u16::from_le_bytes(data[73..75].try_into().unwrap_or([0; 2]));
                (StreamKind::Shard { shard_index: si }, 75)
            }
            TYPE_SHARE_CHUNK => {
                if data.len() < min_len + 4 {
                    return None;
                }
                let ci = u32::from_le_bytes(data[73..77].try_into().unwrap_or([0; 4]));
                (StreamKind::ShareChunk { chunk_index: ci }, 77)
            }
            TYPE_LINK => (StreamKind::LinkSnapshot, 73),
            _ => (StreamKind::File, 73),
        };

        let payload = &data[payload_start..];

        // Check if this is a resumed transfer (partial temp file exists from before disconnect).
        if let Some(state) = pending.get(&id) {
            if state.sender == from {
                return append_frame(pending, &id, payload);
            }
            if state.last_frame_at.elapsed() < STREAM_TAKEOVER_IDLE {
                hollow_log!("[HOLLOW-SECURITY] Dropped a new stream for {id} from {from}: {} holds it", state.sender);
                return None;
            }
            abandon(pending, &id);
        }
        let open_by_sender = pending.values().filter(|s| s.sender == from).count();
        if open_by_sender >= MAX_RECV_STREAMS_PER_SENDER || pending.len() >= MAX_RECV_STREAMS {
            hollow_log!("[HOLLOW-SECURITY] Dropped stream {id} from {from}: {open_by_sender} open from it, {} in all", pending.len());
            return None;
        }
        if payload.len() as u64 > total_size {
            return None;
        }
        let limit = ceiling(&kind, &id);
        if total_size > limit {
            hollow_log!("[HOLLOW-SECURITY] Dropped stream {id} from {from}: it declares {total_size} bytes, {limit} allowed");
            return None;
        }

        // A file per stream, not per id: two receivers on one data dir (the harness's
        // nodes) may take the same id at once.
        let temp_path = files_dir().join(format!(".ws_recv_{id}.{}.tmp", RECV_TEMP_SEQ.fetch_add(1, Ordering::Relaxed)));
        let mut temp_file = match std::fs::File::create(&temp_path) {
            Ok(f) => f,
            Err(e) => {
                hollow_log!("[HOLLOW-WS-STREAM] Failed to create temp file for {id}: {e}");
                return None;
            }
        };

        if let Err(e) = temp_file.write_all(payload) {
            hollow_log!("[HOLLOW-WS-STREAM] Write failed for {id}: {e}");
            return None;
        }

        let bytes_received = payload.len() as u64;

        // Register progress tracking for file + link-snapshot transfers (same global map).
        let progress = if matches!(kind, StreamKind::File | StreamKind::LinkSnapshot) {
            let counter = Arc::new(AtomicU64::new(bytes_received));
            if let Ok(mut map) = stream_progress().lock() {
                map.insert(id.clone(), StreamProgress {
                    bytes_received: counter.clone(),
                    total_bytes: total_size,
                });
            }
            Some(counter)
        } else {
            None
        };

        let state = WsTransferState {
            kind, id: id.clone(), total_size, bytes_received, temp_file, temp_path, progress,
            sender: from.to_string(),
            last_frame_at: std::time::Instant::now(),
        };
        pending.insert(id.clone(), state);
        if bytes_received >= total_size {
            // Single-chunk transfer (small file/shard).
            return complete_transfer(pending, &id);
        }
        None
    } else {
        hollow_log!("[HOLLOW-WS-STREAM] Unknown chunk type: {type_byte:#x}");
        None
    }
}

fn complete_transfer(
    pending: &mut HashMap<String, WsTransferState>,
    id: &str,
) -> Option<StreamRequest> {
    let state = pending.remove(id)?;
    drop(state.temp_file); // flush and close

    // Clean up progress tracking.
    if matches!(state.kind, StreamKind::File | StreamKind::LinkSnapshot) {
        if let Ok(mut map) = stream_progress().lock() {
            map.remove(id);
        }
    }

    hollow_log!("[HOLLOW-WS-STREAM] Transfer complete: {id} ({} bytes)", state.total_size);

    Some(StreamRequest {
        kind: state.kind,
        id: state.id,
        size: state.total_size,
        temp_path: state.temp_path,
    })
}

/// Pad an ID string to exactly 64 bytes (matching the wire format).
fn pad_id(id: &str) -> [u8; 64] {
    let mut buf = [0u8; 64];
    let bytes = id.as_bytes();
    let len = bytes.len().min(64);
    buf[..len].copy_from_slice(&bytes[..len]);
    buf
}

/// Parse an ID from a 64-byte padded buffer (trailing zeroes stripped).
///
/// The id becomes part of a temp file name (`.ws_recv_{id}.{n}.tmp`), so this is the
/// gate: only the characters our own ids use pass (hex, `:` for the share-chunk
/// and shard suffix, `_` for link snapshots, `-`). A `..` or a separator would
/// walk out of the files directory on Windows, where `..` is collapsed lexically
/// before the filesystem is consulted. Mirrors `parseWireTransferId` in Dart.
fn parse_id(buf: &[u8]) -> Option<String> {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    let id = std::str::from_utf8(&buf[..end]).ok()?;
    let allowed = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b':' | b'_' | b'-');
    if id.is_empty() || !id.bytes().all(allowed) {
        return None;
    }
    Some(id.to_string())
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pad_parse_id_roundtrip() {
        let id = "abc123def456";
        let padded = pad_id(id);
        let parsed = parse_id(&padded);
        assert_eq!(parsed.as_deref(), Some(id));
    }

    #[test]
    fn test_pad_64_char_id() {
        let id = "a".repeat(64);
        let padded = pad_id(&id);
        let parsed = parse_id(&padded);
        assert_eq!(parsed.as_deref(), Some(id.as_str()));
    }

    #[test]
    fn test_parse_id_accepts_every_sender_shape() {
        let hex32 = "0123456789abcdef0123456789abcdef";
        for id in [hex32, "0123456789abcdef0123456789abcdef:7", "link_ABC123", "a-b_c"] {
            assert_eq!(parse_id(&pad_id(id)).as_deref(), Some(id), "{id}");
        }
    }

    #[test]
    fn test_parse_id_rejects_path_characters() {
        // The id names `.ws_recv_{id}.{n}.tmp`; none of these may ever reach a path.
        for id in ["/../../escaped", "../x", r"..\x", r"C:\x", "a/b", "a b", "a.b", ""] {
            assert_eq!(parse_id(&pad_id(id)), None, "{id}");
        }
        let mut not_utf8 = [0u8; 64];
        not_utf8[0] = 0xff;
        not_utf8[1] = 0xfe;
        assert_eq!(parse_id(&not_utf8), None);
    }

    fn first_frame(id: &str, total: u64, payload: &[u8]) -> Vec<u8> {
        let mut frame = vec![TYPE_FILE];
        frame.extend_from_slice(&pad_id(id));
        frame.extend_from_slice(&total.to_le_bytes());
        frame.extend_from_slice(payload);
        frame
    }

    fn continuation(id: &str, payload: &[u8]) -> Vec<u8> {
        let mut frame = vec![TYPE_CONTINUATION];
        frame.extend_from_slice(&pad_id(id));
        frame.extend_from_slice(payload);
        frame
    }

    /// No ceiling, for the tests that are not about it.
    fn open(_: &StreamKind, _: &str) -> u64 {
        u64::MAX
    }

    /// A-F7: a stream may not declare more than we expect of it. With no header and no
    /// ask of ours a file stream stays within the send limit, and a share chunk never
    /// rides this lane; a refused stream leaves no temp behind.
    #[test]
    fn a_stream_cannot_declare_past_its_ceiling() {
        use super::super::file_transfer::DEFAULT_MAX_FILE_SIZE;
        let ceiling = |kind: &StreamKind, id: &str| {
            super::super::file_handler::stream_ceiling(
                kind, id, "mallory", &HashMap::new(), &HashMap::new(), &HashMap::new(), &HashMap::new(), &HashMap::new(),
            )
        };
        let temps_of = |id: &str| {
            let prefix = format!(".ws_recv_{id}.");
            std::fs::read_dir(files_dir())
                .map(|dir| dir.flatten().filter(|e| e.file_name().to_string_lossy().starts_with(&prefix)).count())
                .unwrap_or(0)
        };
        let mut pending = HashMap::new();

        let huge = "f7_unasked_huge";
        ws_stream_receive(&mut pending, "mallory", &first_frame(huge, DEFAULT_MAX_FILE_SIZE + 17, &[1u8; 8]), ceiling);
        let (opened, left) = (pending.contains_key(huge), temps_of(huge) > 0);
        abandon(&mut pending, huge);
        assert!(!opened && !left, "A-F7: a stream declaring past the send limit was opened");

        let mut share = vec![TYPE_SHARE_CHUNK];
        share.extend_from_slice(&pad_id("f7_share"));
        share.extend_from_slice(&64u64.to_le_bytes());
        share.extend_from_slice(&7u32.to_le_bytes());
        share.extend_from_slice(&[2u8; 8]);
        ws_stream_receive(&mut pending, "mallory", &share, ceiling);
        let opened = pending.contains_key("f7_share");
        abandon(&mut pending, "f7_share");
        assert!(!opened, "A-F7: a share chunk opened a stream on this lane");

        let within = "f7_within_limit";
        ws_stream_receive(&mut pending, "mallory", &first_frame(within, DEFAULT_MAX_FILE_SIZE + 16, &[1u8; 8]), ceiling);
        let opened = pending.contains_key(within);
        abandon(&mut pending, within);
        assert!(opened, "a stream inside the send limit was refused");

        let swarm = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/swarm.rs"))
            .expect("read swarm.rs");
        let call = &swarm[swarm.find("ws_stream_transfer::ws_stream_receive(").expect("the stream lane")..];
        assert!(
            call[..call.find(") {").expect("its call")].contains("file_handler::stream_ceiling("),
            "A-F7: the stream lane opens streams with no ceiling",
        );
    }

    /// H8, H9: a stream belongs to the peer that opened it. Another peer's frames
    /// for its id are dropped while it is live, nobody writes past the size it
    /// declared, and one peer cannot hold more than its share of open streams.
    #[test]
    fn a_stream_belongs_to_the_peer_that_opened_it() {
        let id = "h8_owned_stream";
        let data = vec![0x5Au8; 1000];
        let mut pending = HashMap::new();
        assert!(ws_stream_receive(&mut pending, "bob", &first_frame(id, 1000, &data[..500]), open).is_none());
        assert!(ws_stream_receive(&mut pending, "mallory", &continuation(id, &[0u8; 500]), open).is_none(), "another peer appended");
        assert!(ws_stream_receive(&mut pending, "mallory", &first_frame(id, 500, &[0u8; 500]), open).is_none(), "another peer reopened it");
        let done = ws_stream_receive(&mut pending, "bob", &continuation(id, &data[500..]), open).expect("the opener completes it");
        assert_eq!(std::fs::read(&done.temp_path).unwrap(), data);
        let _ = std::fs::remove_file(&done.temp_path);

        let over = "h9_past_declared";
        assert!(ws_stream_receive(&mut pending, "mallory", &first_frame(over, 10, &[1u8; 5]), open).is_none());
        assert!(ws_stream_receive(&mut pending, "mallory", &continuation(over, &[1u8; 4096]), open).is_none(), "wrote past its size");
        assert!(!pending.contains_key(over));

        for i in 0..MAX_RECV_STREAMS_PER_SENDER + 4 {
            ws_stream_receive(&mut pending, "mallory", &first_frame(&format!("h9_open_{i}"), 1 << 20, &[1u8; 8]), open);
        }
        let held = pending.len();
        for (_, state) in pending.drain() {
            let _ = std::fs::remove_file(&state.temp_path);
        }
        assert_eq!(held, MAX_RECV_STREAMS_PER_SENDER);
    }

    #[test]
    fn test_single_chunk_file_roundtrip() {
        let id = "test_file_001";
        let file_data = b"hello world file data";
        let total_size = file_data.len() as u64;

        // Build first chunk (same as ws_stream_send would).
        let id_padded = pad_id(id);
        let mut chunk = Vec::new();
        chunk.push(TYPE_FILE);
        chunk.extend_from_slice(&id_padded);
        chunk.extend_from_slice(&total_size.to_le_bytes());
        chunk.extend_from_slice(file_data);

        let mut pending = HashMap::new();
        let result = ws_stream_receive(&mut pending, "peer", &chunk, open);
        assert!(result.is_some());
        let req = result.unwrap();
        assert_eq!(req.id, id);
        assert_eq!(req.size, total_size);
        assert!(matches!(req.kind, StreamKind::File));

        // Verify temp file contents.
        let contents = std::fs::read(&req.temp_path).unwrap();
        assert_eq!(contents, file_data);
        let _ = std::fs::remove_file(&req.temp_path);
    }

    #[test]
    fn test_single_chunk_shard_roundtrip() {
        let id = "test_shard_001";
        let shard_data = b"shard bytes here";
        let total_size = shard_data.len() as u64;
        let shard_index: u16 = 3;

        let id_padded = pad_id(id);
        let mut chunk = Vec::new();
        chunk.push(TYPE_SHARD);
        chunk.extend_from_slice(&id_padded);
        chunk.extend_from_slice(&total_size.to_le_bytes());
        chunk.extend_from_slice(&shard_index.to_le_bytes());
        chunk.extend_from_slice(shard_data);

        let mut pending = HashMap::new();
        let result = ws_stream_receive(&mut pending, "peer", &chunk, open);
        assert!(result.is_some());
        let req = result.unwrap();
        assert_eq!(req.id, id);
        assert!(matches!(req.kind, StreamKind::Shard { shard_index: 3 }));

        let contents = std::fs::read(&req.temp_path).unwrap();
        assert_eq!(contents, shard_data);
        let _ = std::fs::remove_file(&req.temp_path);
    }

    #[test]
    fn test_multi_chunk_reassembly() {
        let id = "test_multi_001";
        let file_data = vec![0xABu8; 1000]; // 1000 bytes, will split into chunks
        let total_size = file_data.len() as u64;

        // First chunk: header + first 500 bytes of data.
        let id_padded = pad_id(id);
        let mut first = Vec::new();
        first.push(TYPE_FILE);
        first.extend_from_slice(&id_padded);
        first.extend_from_slice(&total_size.to_le_bytes());
        first.extend_from_slice(&file_data[..500]);

        let mut pending = HashMap::new();
        let result = ws_stream_receive(&mut pending, "peer", &first, open);
        assert!(result.is_none()); // Not complete yet.
        assert!(pending.contains_key(id));

        // Continuation chunk: remaining 500 bytes.
        let mut cont = Vec::new();
        cont.push(TYPE_CONTINUATION);
        cont.extend_from_slice(&id_padded);
        cont.extend_from_slice(&file_data[500..]);

        let result = ws_stream_receive(&mut pending, "peer", &cont, open);
        assert!(result.is_some());
        let req = result.unwrap();
        assert_eq!(req.id, id);
        assert_eq!(req.size, total_size);

        let contents = std::fs::read(&req.temp_path).unwrap();
        assert_eq!(contents, file_data);
        let _ = std::fs::remove_file(&req.temp_path);
    }

    /// Two receivers on one data dir, as the harness's nodes are, take a stream of the
    /// same id at once: each reassembles its own bytes.
    #[test]
    fn two_streams_of_one_id_never_share_a_temp_file() {
        let id = "two_streams_one_id";
        let (ours, theirs) = (vec![0xA1u8; 1000], vec![0xB2u8; 1000]);
        let (mut here, mut there) = (HashMap::new(), HashMap::new());
        assert!(ws_stream_receive(&mut here, "holder_one", &first_frame(id, 1000, &ours[..500]), open).is_none());
        assert!(ws_stream_receive(&mut there, "holder_two", &first_frame(id, 1000, &theirs[..500]), open).is_none());
        let done_here = ws_stream_receive(&mut here, "holder_one", &continuation(id, &ours[500..]), open).expect("ours completes");
        let done_there = ws_stream_receive(&mut there, "holder_two", &continuation(id, &theirs[500..]), open).expect("theirs completes");
        let (got_here, got_there) = (std::fs::read(&done_here.temp_path).unwrap(), std::fs::read(&done_there.temp_path).unwrap());
        let _ = std::fs::remove_file(&done_here.temp_path);
        let _ = std::fs::remove_file(&done_there.temp_path);
        assert!(got_here == ours && got_there == theirs, "one stream's bytes were written over by the other's");
    }
}
