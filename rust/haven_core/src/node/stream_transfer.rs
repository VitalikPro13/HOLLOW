//! Streaming binary codec for large file/shard transfers over libp2p.
//!
//! Uses a separate `request_response::Behaviour` with protocol `/haven/stream/1.0.0`.
//! Data flows over an ordered Yamux/QUIC substream — no Olm ratchet involvement.
//! Security: file bytes are AES-256-GCM encrypted; the AES key travels via Olm separately.
//!
//! Wire format:
//!   Request:  [1-byte type] [32-byte id (hex)] [8-byte size LE] [2-byte shard_index LE (type=1 only)] [...data bytes...]
//!   Response: [1-byte status (0=ok, 1=error)]

use std::io;
use std::path::PathBuf;

use libp2p::futures::{AsyncReadExt, AsyncWriteExt};
use libp2p::request_response;

use crate::haven_log;

/// 64 KB streaming buffer — only this much in memory at a time.
const STREAM_BUF_SIZE: usize = 64 * 1024;

// ── Wire types ───────────────────────────────────────────────

const TYPE_FILE: u8 = 0;
const TYPE_SHARD: u8 = 1;

// ── Public types ─────────────────────────────────────────────

/// What kind of transfer this is.
#[derive(Debug, Clone)]
pub enum StreamKind {
    /// P2P file transfer (DM or channel file).
    File,
    /// Vault shard transfer.
    Shard { shard_index: u16 },
}

/// The request type used for both sending and receiving.
/// On the sender side, `temp_path` points to the file to stream FROM.
/// On the receiver side, `temp_path` is where the codec WROTE the received bytes.
#[derive(Debug)]
pub struct StreamRequest {
    pub kind: StreamKind,
    /// 32-char hex identifier (file_id for files, content_id for shards).
    pub id: String,
    /// Total bytes to transfer.
    pub size: u64,
    /// Path to the data file (source on sender, destination on receiver).
    pub temp_path: PathBuf,
}

/// Simple ack response.
#[derive(Debug, Clone)]
pub struct StreamResponse {
    pub ok: bool,
}

// ── Codec ────────────────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct FileStreamCodec;

impl request_response::Codec for FileStreamCodec {
    type Protocol = &'static str;
    type Request = StreamRequest;
    type Response = StreamResponse;

    // ── read_request (receiver side) ──────────────────────────

    fn read_request<'a, 'b, 'c, 'async_trait, T>(
        &'a mut self,
        _protocol: &'b Self::Protocol,
        io: &'c mut T,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Self::Request>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncRead + Unpin + Send + 'async_trait,
        'a: 'async_trait,
        'b: 'async_trait,
        'c: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            // Read header: [1-byte type][32-byte id][8-byte size LE][optional 2-byte shard_index]
            let mut type_byte = [0u8; 1];
            io.read_exact(&mut type_byte).await?;

            let mut id_bytes = [0u8; 32];
            io.read_exact(&mut id_bytes).await?;
            let id = String::from_utf8_lossy(&id_bytes).trim().to_string();

            let mut size_bytes = [0u8; 8];
            io.read_exact(&mut size_bytes).await?;
            let size = u64::from_le_bytes(size_bytes);

            let kind = match type_byte[0] {
                TYPE_FILE => StreamKind::File,
                TYPE_SHARD => {
                    let mut si_bytes = [0u8; 2];
                    io.read_exact(&mut si_bytes).await?;
                    StreamKind::Shard { shard_index: u16::from_le_bytes(si_bytes) }
                }
                other => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("Unknown stream type: {other}"),
                    ));
                }
            };

            // Stream data bytes to a temp file using std::fs (no tokio::fs needed).
            let temp_dir = super::file_transfer::files_dir();
            let temp_name = format!(".stream_recv_{}.tmp", &id);
            let temp_path = temp_dir.join(&temp_name);

            {
                let mut file = std::fs::File::create(&temp_path)
                    .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("Create temp file: {e}")))?;

                let mut remaining = size;
                let mut buf = vec![0u8; STREAM_BUF_SIZE];

                while remaining > 0 {
                    let to_read = (remaining as usize).min(STREAM_BUF_SIZE);
                    let n = io.read(&mut buf[..to_read]).await?;
                    if n == 0 {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            format!("Stream ended early: got {} of {size} bytes", size - remaining),
                        ));
                    }
                    std::io::Write::write_all(&mut file, &buf[..n])
                        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("Write temp file: {e}")))?;
                    remaining -= n as u64;
                }

                std::io::Write::flush(&mut file)
                    .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("Flush temp file: {e}")))?;
            }

            haven_log!("[HAVEN-STREAM] Received {size} bytes for {id} ({})",
                match &kind { StreamKind::File => "file".to_string(), StreamKind::Shard { shard_index } => format!("shard {shard_index}") });

            Ok(StreamRequest { kind, id, size, temp_path })
        })
    }

    // ── read_response (sender side — reads ack) ──────────────

    fn read_response<'a, 'b, 'c, 'async_trait, T>(
        &'a mut self,
        _protocol: &'b Self::Protocol,
        io: &'c mut T,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Self::Response>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncRead + Unpin + Send + 'async_trait,
        'a: 'async_trait,
        'b: 'async_trait,
        'c: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let mut status = [0u8; 1];
            io.read_exact(&mut status).await?;
            Ok(StreamResponse { ok: status[0] == 0 })
        })
    }

    // ── write_request (sender side — streams file bytes) ─────

    fn write_request<'a, 'b, 'c, 'async_trait, T>(
        &'a mut self,
        _protocol: &'b Self::Protocol,
        io: &'c mut T,
        req: Self::Request,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncWrite + Unpin + Send + 'async_trait,
        'a: 'async_trait,
        'b: 'async_trait,
        'c: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            // Write header: type byte.
            let type_byte = match &req.kind {
                StreamKind::File => TYPE_FILE,
                StreamKind::Shard { .. } => TYPE_SHARD,
            };
            io.write_all(&[type_byte]).await?;

            // Write 32-byte ID (pad with spaces to exactly 32 bytes).
            let mut id_buf = [b' '; 32];
            let id_bytes = req.id.as_bytes();
            let copy_len = id_bytes.len().min(32);
            id_buf[..copy_len].copy_from_slice(&id_bytes[..copy_len]);
            io.write_all(&id_buf).await?;

            // Write 8-byte size LE.
            io.write_all(&req.size.to_le_bytes()).await?;

            // Write shard_index if shard type.
            if let StreamKind::Shard { shard_index } = &req.kind {
                io.write_all(&shard_index.to_le_bytes()).await?;
            }

            // Stream data bytes from disk.
            let mut file = std::fs::File::open(&req.temp_path)
                .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("Open source file: {e}")))?;

            let mut buf = vec![0u8; STREAM_BUF_SIZE];
            loop {
                let n = std::io::Read::read(&mut file, &mut buf)
                    .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("Read source file: {e}")))?;
                if n == 0 { break; }
                io.write_all(&buf[..n]).await?;
            }

            io.close().await?;

            haven_log!("[HAVEN-STREAM] Sent {} bytes for {}", req.size, req.id);
            Ok(())
        })
    }

    // ── write_response (receiver side — sends ack) ───────────

    fn write_response<'a, 'b, 'c, 'async_trait, T>(
        &'a mut self,
        _protocol: &'b Self::Protocol,
        io: &'c mut T,
        res: Self::Response,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncWrite + Unpin + Send + 'async_trait,
        'a: 'async_trait,
        'b: 'async_trait,
        'c: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let status = if res.ok { 0u8 } else { 1u8 };
            io.write_all(&[status]).await?;
            io.close().await?;
            Ok(())
        })
    }
}

// ── Helpers to create outbound requests ──────────────────────

/// Create an outbound file stream request (reads encrypted file from disk).
pub fn file_stream_request(file_id: &str, encrypted_path: PathBuf, size: u64) -> StreamRequest {
    StreamRequest {
        kind: StreamKind::File,
        id: file_id.to_string(),
        size,
        temp_path: encrypted_path,
    }
}

/// Create an outbound shard stream request (writes shard bytes to temp file first).
pub fn shard_stream_request(
    content_id: &str,
    shard_index: u16,
    shard_data: &[u8],
) -> Result<StreamRequest, String> {
    let temp_dir = super::file_transfer::files_dir();
    let safe_prefix = &content_id[..16.min(content_id.len())];
    let temp_name = format!(".stream_shard_{}_{}.tmp", safe_prefix, shard_index);
    let temp_path = temp_dir.join(&temp_name);
    std::fs::write(&temp_path, shard_data)
        .map_err(|e| format!("Write shard temp file: {e}"))?;

    Ok(StreamRequest {
        kind: StreamKind::Shard { shard_index },
        id: content_id.to_string(),
        size: shard_data.len() as u64,
        temp_path,
    })
}
