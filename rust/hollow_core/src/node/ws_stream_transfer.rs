//! Chunked file/shard streaming over WebSocket binary frames.
//!
//! Mirrors the functionality of `stream_transfer.rs` (libp2p streaming) but uses
//! WS `SendBinaryDirect` frames instead of Yamux/QUIC substreams.
//!
//! Chunk payload format (inside WS binary frame):
//!   First chunk:        [type:1][id:64][total_size:8][shard_index:2 (shard only)][data...]
//!   Continuation chunk: [0xFF:1][id:64][data...]
//!
//! Each WS frame carries one chunk. Chunks arrive in order (WS = TCP = ordered).
//! The receiver reassembles into a temp file, then returns a `StreamRequest` on completion.

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use tokio::sync::mpsc;

use crate::hollow_log;
use super::stream_transfer::{StreamKind, StreamRequest, StreamProgress, stream_progress};
use super::ws_client::WsCommand;
use super::file_transfer::files_dir;

/// 256 KB per WS binary frame payload.
const WS_CHUNK_SIZE: usize = 256 * 1024;

const TYPE_FILE: u8 = 0;
const TYPE_SHARD: u8 = 1;
const TYPE_CONTINUATION: u8 = 0xFF;

/// State for an in-progress WS stream transfer (receiver side).
pub struct WsTransferState {
    pub kind: StreamKind,
    pub id: String,
    pub total_size: u64,
    pub bytes_received: u64,
    pub temp_file: std::fs::File,
    pub temp_path: PathBuf,
    pub progress: Option<Arc<AtomicU64>>,
}

/// Send a file or shard to a peer via chunked WS binary frames.
/// Reads from `source_path`, splits into WS_CHUNK_SIZE chunks, sends each via WsCommand::SendBinaryDirect.
pub async fn ws_stream_send(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    room_code: &str,
    target_peer: &str,
    kind: &StreamKind,
    id: &str,
    source_path: &std::path::Path,
    total_size: u64,
) {
    let file_data = match std::fs::read(source_path) {
        Ok(d) => d,
        Err(e) => {
            hollow_log!("[HOLLOW-WS-STREAM] Failed to read source {}: {e}", source_path.display());
            return;
        }
    };

    // Build header for first chunk.
    let id_padded = pad_id(id);
    let shard_index = match kind {
        StreamKind::Shard { shard_index } => Some(*shard_index),
        StreamKind::File => None,
    };

    let header_len = 1 + 64 + 8 + if shard_index.is_some() { 2 } else { 0 };
    let first_data_len = WS_CHUNK_SIZE.saturating_sub(header_len).min(file_data.len());

    // First chunk: [type][id:64][size:8][shard_index:2?][data...]
    let mut first_chunk = Vec::with_capacity(header_len + first_data_len);
    first_chunk.push(match kind { StreamKind::File => TYPE_FILE, StreamKind::Shard { .. } => TYPE_SHARD });
    first_chunk.extend_from_slice(&id_padded);
    first_chunk.extend_from_slice(&total_size.to_le_bytes());
    if let Some(si) = shard_index {
        first_chunk.extend_from_slice(&si.to_le_bytes());
    }
    first_chunk.extend_from_slice(&file_data[..first_data_len]);

    let _ = ws_cmd_tx.send(WsCommand::SendBinaryDirect {
        room_code: room_code.to_string(),
        target_peer: target_peer.to_string(),
        data: first_chunk,
    });

    // Continuation chunks: [0xFF][id:64][data...]
    let mut offset = first_data_len;
    while offset < file_data.len() {
        // Brief yield for backpressure.
        tokio::task::yield_now().await;

        let cont_data_len = WS_CHUNK_SIZE.saturating_sub(65).min(file_data.len() - offset);
        let mut chunk = Vec::with_capacity(65 + cont_data_len);
        chunk.push(TYPE_CONTINUATION);
        chunk.extend_from_slice(&id_padded);
        chunk.extend_from_slice(&file_data[offset..offset + cont_data_len]);

        let _ = ws_cmd_tx.send(WsCommand::SendBinaryDirect {
            room_code: room_code.to_string(),
            target_peer: target_peer.to_string(),
            data: chunk,
        });

        offset += cont_data_len;
    }

    hollow_log!("[HOLLOW-WS-STREAM] Sent {id} ({total_size} bytes) to {target_peer} in {} chunks",
        1 + ((file_data.len().saturating_sub(first_data_len)) + WS_CHUNK_SIZE.saturating_sub(65) - 1) / WS_CHUNK_SIZE.saturating_sub(65).max(1));
}

/// Process a received WS binary chunk. Called from the swarm when BinaryDirect arrives.
/// Returns `Some(StreamRequest)` when the transfer is complete (all bytes received).
pub fn ws_stream_receive(
    pending: &mut HashMap<String, WsTransferState>,
    data: &[u8],
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
        let id = parse_id(&data[1..65]);
        let payload = &data[65..];

        let state = pending.get_mut(&id)?;
        if let Err(e) = state.temp_file.write_all(payload) {
            hollow_log!("[HOLLOW-WS-STREAM] Write failed for {id}: {e}");
            pending.remove(&id);
            return None;
        }
        state.bytes_received += payload.len() as u64;
        if let Some(ref progress) = state.progress {
            progress.store(state.bytes_received, Ordering::Relaxed);
        }

        if state.bytes_received >= state.total_size {
            return complete_transfer(pending, &id);
        }
        None
    } else if type_byte == TYPE_FILE || type_byte == TYPE_SHARD {
        // First chunk: [type][id:64][size:8][shard_index:2?][data...]
        let min_len = 1 + 64 + 8;
        if data.len() < min_len {
            return None;
        }
        let id = parse_id(&data[1..65]);
        let total_size = u64::from_le_bytes(data[65..73].try_into().unwrap_or([0; 8]));

        let (kind, payload_start) = if type_byte == TYPE_SHARD {
            if data.len() < min_len + 2 {
                return None;
            }
            let si = u16::from_le_bytes(data[73..75].try_into().unwrap_or([0; 2]));
            (StreamKind::Shard { shard_index: si }, 75)
        } else {
            (StreamKind::File, 73)
        };

        let payload = &data[payload_start..];

        // Create temp file for reassembly.
        let temp_path = files_dir().join(format!(".ws_recv_{id}.tmp"));
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

        // Register progress tracking for file transfers (same global map as libp2p).
        let progress = if matches!(kind, StreamKind::File) {
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

        if bytes_received >= total_size {
            // Single-chunk transfer (small file/shard).
            pending.insert(id.clone(), WsTransferState {
                kind, id: id.clone(), total_size, bytes_received, temp_file, temp_path, progress,
            });
            return complete_transfer(pending, &id);
        }

        pending.insert(id, WsTransferState {
            kind, id: parse_id(&data[1..65]), total_size, bytes_received, temp_file, temp_path, progress,
        });
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
    if matches!(state.kind, StreamKind::File) {
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

/// Parse an ID from a 64-byte padded buffer (strip trailing zeroes).
fn parse_id(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).to_string()
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
        assert_eq!(parsed, id);
    }

    #[test]
    fn test_pad_64_char_id() {
        let id = "a".repeat(64);
        let padded = pad_id(&id);
        let parsed = parse_id(&padded);
        assert_eq!(parsed, id);
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
        let result = ws_stream_receive(&mut pending, &chunk);
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
        let result = ws_stream_receive(&mut pending, &chunk);
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
        let result = ws_stream_receive(&mut pending, &first);
        assert!(result.is_none()); // Not complete yet.
        assert!(pending.contains_key(id));

        // Continuation chunk: remaining 500 bytes.
        let mut cont = Vec::new();
        cont.push(TYPE_CONTINUATION);
        cont.extend_from_slice(&id_padded);
        cont.extend_from_slice(&file_data[500..]);

        let result = ws_stream_receive(&mut pending, &cont);
        assert!(result.is_some());
        let req = result.unwrap();
        assert_eq!(req.id, id);
        assert_eq!(req.size, total_size);

        let contents = std::fs::read(&req.temp_path).unwrap();
        assert_eq!(contents, file_data);
        let _ = std::fs::remove_file(&req.temp_path);
    }
}
