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
    /// The transfer's wire id: `file_handler::file_stream_id` for files,
    /// `vault_ops::shard_stream_id` for shards.
    pub id: String,
    /// Total bytes to transfer.
    pub size: u64,
    /// Path to the data file (source on sender, destination on receiver).
    pub temp_path: PathBuf,
}

/// Tracks bytes received per stream. Polled by the event loop to emit FileProgress events.
#[derive(Debug, Clone)]
pub struct StreamProgress {
    pub bytes_received: Arc<AtomicU64>,
    pub total_bytes: u64,
    /// The file the stream carries, when we expected it; progress is shown only for those.
    pub file_id: Option<String>,
}

/// What a receiver expects of a stream it is about to open.
pub struct StreamExpect {
    /// The most bytes the stream may declare.
    pub ceiling: u64,
    /// The file it carries, when a header or an ask of ours names it.
    pub file_id: Option<String>,
}

/// Whether `id` has the shape of a file or shard stream id: 64 lowercase hex.
pub(crate) fn is_stream_id(id: &str) -> bool {
    id.len() == 64 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
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

/// Relay streams one device runs for askers outside our identity, all together and per
/// asking identity (the receiver's own bound).
const MAX_RELAY_STREAMS: usize = 64;
const MAX_RELAY_STREAMS_PER_ASKER: usize = MAX_RECV_STREAMS_PER_SENDER;
/// Bytes those streams may hold staged on disk; one stream alone may hold more.
const RELAY_STAGED_BYTES: u64 = 8 * super::file_transfer::DEFAULT_MAX_FILE_SIZE;
/// Chunk bytes one device's relay streams may have handed its socket and not yet
/// written: a stream goes at the socket's pace instead of queueing the file ahead of it.
pub(crate) const RELAY_STREAM_QUEUE_BYTES: usize = 4 * 1024 * 1024;
/// A stream waiting for credit ends once the socket has taken none of this device's
/// relay chunks for this long; waiting behind other streams' chunks is no stall.
const RELAY_STREAM_STALL: std::time::Duration = std::time::Duration::from_secs(120);
const RELAY_STALL_CHECK: std::time::Duration = std::time::Duration::from_secs(5);

/// Who a relay stream goes to, which decides what gives way when a device's streams
/// are full.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum RelayRank {
    /// A public-channel guest's ask: identities are free, so guests give way first.
    Guest,
    /// A server member's or DM party's ask.
    Member,
    /// A send we started, or an ask from one of our own devices: outside every cap.
    Own,
}

struct CreditHeld {
    _permit: tokio::sync::OwnedSemaphorePermit,
    written: Arc<AtomicU64>,
}

impl Drop for CreditHeld {
    fn drop(&mut self) {
        self.written.fetch_add(1, Ordering::Relaxed);
    }
}

/// A chunk's share of its sender's relay queue budget, given back when the chunk is
/// written to the socket or dropped.
#[derive(Clone, Default)]
pub struct StreamCredit {
    _held: Option<Arc<CreditHeld>>,
}

impl std::fmt::Debug for StreamCredit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("StreamCredit")
    }
}

impl StreamCredit {
    fn new(permit: tokio::sync::OwnedSemaphorePermit, written: &Arc<AtomicU64>) -> Self {
        Self { _held: Some(Arc::new(CreditHeld { _permit: permit, written: written.clone() })) }
    }
}

struct RelayEntry {
    seq: u64,
    id: String,
    /// The device it goes to, and that device's identity.
    target: String,
    asker: String,
    rank: RelayRank,
    bytes: u64,
    /// Its device left every room we share: still delivered to while it only hides, and
    /// replaced when that device asks for it again.
    stale: bool,
    /// Dropping it ends the stream.
    _end: tokio::sync::oneshot::Sender<()>,
}

/// One device's relay streams.
struct RelaySender {
    credit: Arc<tokio::sync::Semaphore>,
    /// Chunks of ours the socket has taken or dropped, all streams together.
    written: Arc<AtomicU64>,
    streams: Vec<RelayEntry>,
}

static RELAY_SEQ: AtomicU64 = AtomicU64::new(1);

fn relay_senders() -> std::sync::MutexGuard<'static, HashMap<String, RelaySender>> {
    static SENDERS: std::sync::OnceLock<std::sync::Mutex<HashMap<String, RelaySender>>> = std::sync::OnceLock::new();
    SENDERS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// What a peer's ask for a relay stream gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RelayAdmit {
    Start,
    /// The same stream to the same device is still going, and the device never left.
    Running,
    /// The asker holds its share already, or everyone it could displace ranks above it.
    Busy,
}

fn relay_rank(us: &str, target: &str, rank: RelayRank) -> RelayRank {
    if super::resolver::same_identity(us, target) { RelayRank::Own } else { rank }
}

/// The streams a new one for `asker` displaces, or why it may not start. Past a bound
/// the lowest rank gives way, within it the asker holding the most (streams, or staged
/// bytes), with its newest stream; on a tie the newcomer waits, so equals never churn.
fn relay_plan(streams: &[RelayEntry], id: &str, asker: &str, rank: RelayRank, bytes: u64) -> Result<Vec<u64>, RelayAdmit> {
    let mut displaced = Vec::new();
    if let Some(running) = streams.iter().find(|s| s.id == id) {
        if !running.stale {
            return Err(RelayAdmit::Running);
        }
        displaced.push(running.seq);
    }
    if rank == RelayRank::Own {
        return Ok(displaced);
    }
    let capped = || streams.iter().filter(|s| s.rank != RelayRank::Own && !displaced.contains(&s.seq));
    if capped().filter(|s| s.asker == asker).count() >= MAX_RELAY_STREAMS_PER_ASKER {
        return Err(RelayAdmit::Busy);
    }
    const NEWCOMER: u64 = u64::MAX;
    let mut kept: Vec<(u64, &str, RelayRank, u64)> = capped().map(|s| (s.seq, s.asker.as_str(), s.rank, s.bytes)).collect();
    kept.push((NEWCOMER, asker, rank, bytes));
    loop {
        let by_count = kept.len() > MAX_RELAY_STREAMS;
        let staged: u64 = kept.iter().map(|k| k.3).sum();
        if !by_count && (kept.len() < 2 || staged <= RELAY_STAGED_BYTES) {
            return Ok(displaced);
        }
        let low = kept.iter().map(|k| k.2).min().unwrap_or(rank);
        let mut shares: HashMap<&str, (u64, u64)> = HashMap::new();
        for k in kept.iter().filter(|k| k.2 == low) {
            let share = shares.entry(k.1).or_default();
            share.0 += if by_count { 1 } else { k.3 };
            share.1 = share.1.max(k.0);
        }
        let newest = shares.into_values().max().map_or(NEWCOMER, |(_, newest)| newest);
        if newest == NEWCOMER {
            return Err(RelayAdmit::Busy);
        }
        kept.retain(|k| k.0 != newest);
        displaced.push(newest);
    }
}

/// Whether `us` may start relay stream `id` of `bytes` to `target`, as `rank` ranks it.
pub(crate) fn relay_stream_admits(us: &str, target: &str, id: &str, rank: RelayRank, bytes: u64) -> RelayAdmit {
    let rank = relay_rank(us, target, rank);
    let asker = super::resolver::resolve(target);
    let senders = relay_senders();
    let Some(sender) = senders.get(us) else { return RelayAdmit::Start };
    match relay_plan(&sender.streams, id, &asker, rank, bytes) {
        Ok(_) => RelayAdmit::Start,
        Err(why) => why,
    }
}

/// End every relay stream of `us` to `device`: it came back on a fresh session, so its
/// receive state is gone and its next ask starts a stream afresh.
pub(crate) fn end_relay_streams_to(us: &str, device: &str) -> usize {
    let mut senders = relay_senders();
    let Some(sender) = senders.get_mut(us) else { return 0 };
    let before = sender.streams.len();
    sender.streams.retain(|s| s.target != device);
    before - sender.streams.len()
}

/// `device` left every room `us` shares with it: a hidden device still takes our frames,
/// so its streams go on, but one whose session was lost asks again and that ask replaces
/// the stream.
pub(crate) fn orphan_relay_streams_to(us: &str, device: &str) -> usize {
    let mut senders = relay_senders();
    let Some(sender) = senders.get_mut(us) else { return 0 };
    let mut orphaned = 0;
    for s in sender.streams.iter_mut().filter(|s| s.target == device && !s.stale) {
        s.stale = true;
        orphaned += 1;
    }
    orphaned
}

/// Streams of `us` that send nothing, by the newest sequence each pause holds.
#[cfg(test)]
static PAUSED: std::sync::Mutex<Vec<(String, u64)>> = std::sync::Mutex::new(Vec::new());

/// TEST-ONLY: hold or release every relay stream of `us`, so a test can ask again while
/// one is still running, however fast the machine sends.
#[cfg(test)]
pub(crate) fn pause_relay_streams(us: &str, paused: bool) {
    let mut held = PAUSED.lock().unwrap_or_else(|e| e.into_inner());
    held.retain(|(s, _)| s != us);
    if paused {
        held.push((us.to_string(), u64::MAX));
    }
}

/// TEST-ONLY: how many relay streams `us` runs.
#[cfg(test)]
pub(crate) fn relay_streams_running(us: &str) -> usize {
    relay_senders().get(us).map_or(0, |s| s.streams.len())
}

/// TEST-ONLY: keep holding the relay streams `us` runs now and let later ones go.
#[cfg(test)]
pub(crate) fn pause_only_running_relay_streams(us: &str) {
    let newest = relay_senders().get(us).and_then(|s| s.streams.iter().map(|e| e.seq).max()).unwrap_or(0);
    let mut held = PAUSED.lock().unwrap_or_else(|e| e.into_inner());
    held.retain(|(s, _)| s != us);
    held.push((us.to_string(), newest));
}

/// Waits while a test holds stream `seq` of `us`; false once the stream was ended.
async fn wait_while_paused(us: &str, seq: u64, ended: &mut tokio::sync::oneshot::Receiver<()>) -> bool {
    #[cfg(test)]
    while PAUSED.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|(s, newest)| s == us && seq <= *newest) {
        if !matches!(ended.try_recv(), Err(tokio::sync::oneshot::error::TryRecvError::Empty)) {
            return false;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    #[cfg(not(test))]
    let _ = (us, seq);
    matches!(ended.try_recv(), Err(tokio::sync::oneshot::error::TryRecvError::Empty))
}

/// Holds a relay stream's place until it ends, and the temp it streams from.
struct RelayStream {
    us: String,
    seq: u64,
    staged: Option<PathBuf>,
}

impl Drop for RelayStream {
    fn drop(&mut self) {
        if let Some(path) = &self.staged {
            let _ = std::fs::remove_file(path);
        }
        if let Some(sender) = relay_senders().get_mut(&self.us) {
            sender.streams.retain(|s| s.seq != self.seq);
        }
    }
}

struct RelayStart {
    place: RelayStream,
    credit: Arc<tokio::sync::Semaphore>,
    written: Arc<AtomicU64>,
    ended: tokio::sync::oneshot::Receiver<()>,
}

/// Take a place for relay stream `id` to `target`, ending the streams it displaces.
fn start_relay_stream(us: &str, target: &str, id: &str, rank: RelayRank, bytes: u64) -> Result<RelayStart, RelayAdmit> {
    let rank = relay_rank(us, target, rank);
    let asker = super::resolver::resolve(target);
    let mut senders = relay_senders();
    let sender = senders.entry(us.to_string()).or_insert_with(|| RelaySender {
        credit: Arc::new(tokio::sync::Semaphore::new(RELAY_STREAM_QUEUE_BYTES)),
        written: Arc::default(),
        streams: Vec::new(),
    });
    let displaced = relay_plan(&sender.streams, id, &asker, rank, bytes)?;
    if !displaced.is_empty() {
        hollow_log!("[HOLLOW-WS-STREAM] {id} to {target} replaces or displaces {} relay stream(s)", displaced.len());
        sender.streams.retain(|s| !displaced.contains(&s.seq));
    }
    let seq = RELAY_SEQ.fetch_add(1, Ordering::Relaxed);
    let (end, ended) = tokio::sync::oneshot::channel();
    sender.streams.push(RelayEntry {
        seq,
        id: id.to_string(),
        target: target.to_string(),
        asker,
        rank,
        bytes,
        stale: false,
        _end: end,
    });
    Ok(RelayStart {
        place: RelayStream { us: us.to_string(), seq, staged: None },
        credit: sender.credit.clone(),
        written: sender.written.clone(),
        ended,
    })
}

/// Where stream `seq` of `id` stages its bytes: its own name, so no other stream of the
/// same id ever writes or unlinks it.
fn relay_stage_path(id: &str, seq: u64) -> PathBuf {
    let name: String = id.chars().filter(|c| c.is_ascii_alphanumeric()).take(64).collect();
    files_dir().join(format!(".stream_send_relay_{name}_{seq}.tmp"))
}

/// Send a file or shard from `us` to a peer via chunked WS binary frames, from disk in
/// WS_CHUNK_SIZE pieces at the socket's pace. Returns once the stream has its own link
/// (else copy) of `source_path`; a stream of `id` still running is not started again.
/// If `start_offset > 0`, seeks past already-sent bytes (for transfer resumption).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn ws_stream_send(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    us: &str,
    room_code: &str,
    target_peer: &str,
    kind: &StreamKind,
    id: &str,
    source_path: &std::path::Path,
    total_size: u64,
    start_offset: u64,
    rank: RelayRank,
) {
    let mut start = match start_relay_stream(us, target_peer, id, rank, total_size) {
        Ok(start) => start,
        Err(why) => {
            hollow_log!("[HOLLOW-WS-STREAM] {id} to {target_peer} not started ({why:?})");
            return;
        }
    };
    let staged = relay_stage_path(id, start.place.seq);
    if tokio::fs::hard_link(source_path, &staged).await.is_err() && tokio::fs::copy(source_path, &staged).await.is_err() {
        hollow_log!("[HOLLOW-WS-STREAM] Could not stage the relay send of {id}");
        let _ = tokio::fs::remove_file(&staged).await;
        return;
    }
    start.place.staged = Some(staged);
    spawn_relay_stream(ws_cmd_tx, start, room_code, target_peer, kind, id, total_size, start_offset);
}

/// Send bytes held in memory from `us` to a peer: staged to disk and streamed as
/// `ws_stream_send` streams a file, under the same caps and credit.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn ws_stream_send_bytes(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    us: &str,
    room_code: &str,
    target_peer: &str,
    kind: &StreamKind,
    id: &str,
    data: &[u8],
    rank: RelayRank,
) {
    let total_size = data.len() as u64;
    let mut start = match start_relay_stream(us, target_peer, id, rank, total_size) {
        Ok(start) => start,
        Err(why) => {
            hollow_log!("[HOLLOW-WS-STREAM] {id} to {target_peer} not started ({why:?})");
            return;
        }
    };
    let staged = relay_stage_path(id, start.place.seq);
    start.place.staged = Some(staged.clone());
    if let Err(e) = tokio::fs::write(&staged, data).await {
        hollow_log!("[HOLLOW-WS-STREAM] Could not stage the relay send of {id}: {e}");
        return;
    }
    spawn_relay_stream(ws_cmd_tx, start, room_code, target_peer, kind, id, total_size, 0);
}

#[allow(clippy::too_many_arguments)]
fn spawn_relay_stream(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    start: RelayStart,
    room_code: &str,
    target_peer: &str,
    kind: &StreamKind,
    id: &str,
    total_size: u64,
    start_offset: u64,
) {
    let (tx, room, target, kind, id) = (ws_cmd_tx.clone(), room_code.to_string(), target_peer.to_string(), kind.clone(), id.to_string());
    tokio::spawn(async move {
        let RelayStart { place, credit, written, mut ended } = start;
        let Some(source) = place.staged.clone() else { return };
        let stream = RelaySend { us: &place.us, seq: place.seq, credit: &credit, written: &written };
        send_relay_chunks(&tx, stream, &mut ended, &room, &target, &kind, &id, &source, total_size, start_offset).await;
        drop(place);
    });
}

struct RelaySend<'a> {
    us: &'a str,
    seq: u64,
    credit: &'a Arc<tokio::sync::Semaphore>,
    written: &'a Arc<AtomicU64>,
}

/// Credit for `n` chunk bytes; `None` once the stream is ended or the socket took none
/// of our chunks for `stall`, looked at every `check`.
async fn relay_credit(
    stream: &RelaySend<'_>,
    n: usize,
    ended: &mut tokio::sync::oneshot::Receiver<()>,
    stall: std::time::Duration,
    check: std::time::Duration,
) -> Option<tokio::sync::OwnedSemaphorePermit> {
    let acquire = stream.credit.clone().acquire_many_owned(n as u32);
    tokio::pin!(acquire);
    let mut seen = stream.written.load(Ordering::Relaxed);
    let mut since = std::time::Instant::now();
    loop {
        tokio::select! {
            biased;
            _ = &mut *ended => return None,
            permit = &mut acquire => return permit.ok(),
            _ = tokio::time::sleep(check) => {
                let now = stream.written.load(Ordering::Relaxed);
                if now != seen {
                    seen = now;
                    since = std::time::Instant::now();
                } else if since.elapsed() >= stall {
                    return None;
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn send_relay_chunks(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    stream: RelaySend<'_>,
    ended: &mut tokio::sync::oneshot::Receiver<()>,
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
            hollow_log!("[HOLLOW-WS-STREAM] Failed to open source {}: {e}", crate::log::redact_file(source_path));
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

    // First chunk: [type:1][id:64][size:8][extra...][data]
    //   File:       extra = (none)
    //   Shard:      extra = shard_index:u16 LE (2 bytes)
    //   ShareChunk: extra = chunk_index:u32 LE (4 bytes)
    // Continuation: [0xFF][id:64][data]
    let id_padded = pad_id(id);
    let mut header = vec![match kind {
        StreamKind::File => TYPE_FILE,
        StreamKind::Shard { .. } => TYPE_SHARD,
        StreamKind::ShareChunk { .. } => TYPE_SHARE_CHUNK,
        StreamKind::LinkSnapshot => TYPE_LINK,
    }];
    header.extend_from_slice(&id_padded);
    header.extend_from_slice(&total_size.to_le_bytes());
    match kind {
        StreamKind::Shard { shard_index } => header.extend_from_slice(&shard_index.to_le_bytes()),
        StreamKind::ShareChunk { chunk_index } => header.extend_from_slice(&chunk_index.to_le_bytes()),
        StreamKind::File | StreamKind::LinkSnapshot => {}
    }

    let mut bytes_sent = start_offset;
    let mut chunk_count: u64 = 0;
    loop {
        let first = chunk_count == 0;
        if !first && bytes_sent >= total_size {
            break;
        }
        if !first {
            header.clear();
            header.push(TYPE_CONTINUATION);
            header.extend_from_slice(&id_padded);
        }
        if !wait_while_paused(stream.us, stream.seq, ended).await {
            hollow_log!("[HOLLOW-WS-STREAM] {id} to {target_peer} ended at {bytes_sent}/{total_size}");
            return;
        }
        let cap = WS_CHUNK_SIZE.saturating_sub(header.len()).min(total_size.saturating_sub(bytes_sent) as usize);
        let Some(permit) = relay_credit(&stream, header.len() + cap, ended, RELAY_STREAM_STALL, RELAY_STALL_CHECK).await else {
            hollow_log!("[HOLLOW-WS-STREAM] {id} to {target_peer} ended or stalled at {bytes_sent}/{total_size}; dropped");
            return;
        };
        let mut chunk = Vec::with_capacity(header.len() + cap);
        chunk.extend_from_slice(&header);
        chunk.resize(header.len() + cap, 0);
        let n = match file.read(&mut chunk[header.len()..]).await {
            Ok(n) => n,
            Err(e) => {
                hollow_log!("[HOLLOW-WS-STREAM] Read error at offset {bytes_sent}: {e}");
                return;
            }
        };
        if n == 0 && !first {
            break;
        }
        chunk.truncate(header.len() + n);
        let sent = ws_cmd_tx.send(WsCommand::SendBinaryDirect {
            room_code: room_code.to_string(),
            target_peer: target_peer.to_string(),
            data: chunk,
            credit: StreamCredit::new(permit, stream.written),
        });
        if sent.is_err() {
            return;
        }
        bytes_sent += n as u64;
        chunk_count += 1;
    }

    hollow_log!("[HOLLOW-WS-STREAM] Sent {id} ({total_size} bytes) to {target_peer} in {chunk_count} chunks");
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
/// `expect` says what a new stream of that kind and id may declare and which file it carries.
pub fn ws_stream_receive(
    pending: &mut HashMap<String, WsTransferState>,
    from: &str,
    data: &[u8],
    expect: impl Fn(&StreamKind, &str) -> StreamExpect,
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
        if matches!(kind, StreamKind::File | StreamKind::Shard { .. }) && !is_stream_id(&id) {
            hollow_log!("[HOLLOW-WS-STREAM] Dropped stream frame: {id} is not a stream id");
            return None;
        }

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
        let StreamExpect { ceiling: limit, file_id } = expect(&kind, &id);
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
                    file_id,
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
/// suffix, `_` for link snapshots, `-`). A `..` or a separator would
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

    /// No ceiling and no file, for the tests that are not about them.
    fn open(_: &StreamKind, _: &str) -> StreamExpect {
        StreamExpect { ceiling: u64::MAX, file_id: None }
    }

    /// A stream id, as a sender derives one.
    fn sid(tag: &str) -> String {
        super::super::file_handler::file_stream_id(tag, "sender", "receiver")
    }

    /// A file or shard stream opens only under a stream id; other kinds keep their own
    /// ids, which only the general allowlist judges.
    #[test]
    fn a_file_or_shard_stream_opens_only_under_a_stream_id() {
        // Opened streams are temps in the files folder: a throwaway one.
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()); }
        let mut pending = HashMap::new();
        let shard = |id: &str| {
            let mut frame = vec![TYPE_SHARD];
            frame.extend_from_slice(&pad_id(id));
            frame.extend_from_slice(&10u64.to_le_bytes());
            frame.extend_from_slice(&3u16.to_le_bytes());
            frame.extend_from_slice(&[1u8; 4]);
            frame
        };
        let hex32 = "0123456789abcdef0123456789abcdef";
        for id in [hex32.to_string(), "AB".repeat(32), "g".repeat(64), format!("{hex32}:7"), "link_ABC123".into()] {
            ws_stream_receive(&mut pending, "peer", &first_frame(&id, 10, &[1u8; 4]), open);
            ws_stream_receive(&mut pending, "peer", &shard(&id), open);
            assert!(pending.is_empty(), "a file or shard stream opened under {id:?}");
        }
        let id = sid("ok");
        assert!(is_stream_id(&id));
        ws_stream_receive(&mut pending, "peer", &first_frame(&id, 10, &[1u8; 4]), open);
        assert!(pending.contains_key(&id), "a file stream under its stream id was refused");
        abandon(&mut pending, &id);
        ws_stream_receive(&mut pending, "peer", &shard(&id), open);
        assert!(pending.contains_key(&id), "a shard stream under its stream id was refused");
        abandon(&mut pending, &id);

        let mut link = vec![TYPE_LINK];
        link.extend_from_slice(&pad_id("link_ABC123"));
        link.extend_from_slice(&10u64.to_le_bytes());
        link.extend_from_slice(&[1u8; 4]);
        ws_stream_receive(&mut pending, "peer", &link, open);
        assert!(pending.contains_key("link_ABC123"), "a link snapshot keeps its own id");
        abandon(&mut pending, "link_ABC123");
    }

    /// A-F7: a stream may not declare more than we expect of it. With no header and no
    /// ask of ours a file stream stays within the send limit, and a share chunk never
    /// rides this lane; a refused stream leaves no temp behind.
    #[test]
    fn a_stream_cannot_declare_past_its_ceiling() {
        use super::super::file_transfer::DEFAULT_MAX_FILE_SIZE;
        let ceiling = |kind: &StreamKind, id: &str| StreamExpect {
            ceiling: super::super::file_handler::stream_ceiling(
                kind, id, "mallory", "us", &HashMap::new(), &HashMap::new(), &HashMap::new(), &HashMap::new(), &HashMap::new(),
            ),
            file_id: None,
        };
        let temps_of = |id: &str| {
            let prefix = format!(".ws_recv_{id}.");
            std::fs::read_dir(files_dir())
                .map(|dir| dir.flatten().filter(|e| e.file_name().to_string_lossy().starts_with(&prefix)).count())
                .unwrap_or(0)
        };
        let mut pending = HashMap::new();

        let huge = &sid("f7_unasked_huge");
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

        let within = &sid("f7_within_limit");
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
        let id = &sid("h8_owned_stream");
        let data = vec![0x5Au8; 1000];
        let mut pending = HashMap::new();
        assert!(ws_stream_receive(&mut pending, "bob", &first_frame(id, 1000, &data[..500]), open).is_none());
        assert!(ws_stream_receive(&mut pending, "mallory", &continuation(id, &[0u8; 500]), open).is_none(), "another peer appended");
        assert!(ws_stream_receive(&mut pending, "mallory", &first_frame(id, 500, &[0u8; 500]), open).is_none(), "another peer reopened it");
        let done = ws_stream_receive(&mut pending, "bob", &continuation(id, &data[500..]), open).expect("the opener completes it");
        assert_eq!(std::fs::read(&done.temp_path).unwrap(), data);
        let _ = std::fs::remove_file(&done.temp_path);

        let over = &sid("h9_past_declared");
        assert!(ws_stream_receive(&mut pending, "mallory", &first_frame(over, 10, &[1u8; 5]), open).is_none());
        assert!(ws_stream_receive(&mut pending, "mallory", &continuation(over, &[1u8; 4096]), open).is_none(), "wrote past its size");
        assert!(!pending.contains_key(over));

        for i in 0..MAX_RECV_STREAMS_PER_SENDER + 4 {
            ws_stream_receive(&mut pending, "mallory", &first_frame(&sid(&format!("h9_open_{i}")), 1 << 20, &[1u8; 8]), open);
        }
        let held = pending.len();
        for (_, state) in pending.drain() {
            let _ = std::fs::remove_file(&state.temp_path);
        }
        assert_eq!(held, MAX_RECV_STREAMS_PER_SENDER);
    }

    #[test]
    fn test_single_chunk_file_roundtrip() {
        let id = &sid("test_file_001");
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
        assert_eq!(&req.id, id);
        assert_eq!(req.size, total_size);
        assert!(matches!(req.kind, StreamKind::File));

        // Verify temp file contents.
        let contents = std::fs::read(&req.temp_path).unwrap();
        assert_eq!(contents, file_data);
        let _ = std::fs::remove_file(&req.temp_path);
    }

    #[test]
    fn test_single_chunk_shard_roundtrip() {
        let id = &sid("test_shard_001");
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
        assert_eq!(&req.id, id);
        assert!(matches!(req.kind, StreamKind::Shard { shard_index: 3 }));

        let contents = std::fs::read(&req.temp_path).unwrap();
        assert_eq!(contents, shard_data);
        let _ = std::fs::remove_file(&req.temp_path);
    }

    #[test]
    fn test_multi_chunk_reassembly() {
        let id = &sid("test_multi_001");
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
        assert!(pending.contains_key(id.as_str()));

        // Continuation chunk: remaining 500 bytes.
        let mut cont = Vec::new();
        cont.push(TYPE_CONTINUATION);
        cont.extend_from_slice(&id_padded);
        cont.extend_from_slice(&file_data[500..]);

        let result = ws_stream_receive(&mut pending, "peer", &cont, open);
        assert!(result.is_some());
        let req = result.unwrap();
        assert_eq!(&req.id, id);
        assert_eq!(req.size, total_size);

        let contents = std::fs::read(&req.temp_path).unwrap();
        assert_eq!(contents, file_data);
        let _ = std::fs::remove_file(&req.temp_path);
    }

    /// Two receivers on one data dir, as the harness's nodes are, take a stream of the
    /// same id at once: each reassembles its own bytes.
    #[test]
    fn two_streams_of_one_id_never_share_a_temp_file() {
        let id = &sid("two_streams_one_id");
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

    /// Everything waiting in an unread command channel, kept so its credit stays held,
    /// as (bytes, ids of the streams that opened).
    fn queued(rx: &mut mpsc::UnboundedReceiver<WsCommand>, held: &mut Vec<WsCommand>) -> (usize, Vec<String>) {
        while let Ok(cmd) = rx.try_recv() {
            held.push(cmd);
        }
        let mut bytes = 0;
        let mut opened = Vec::new();
        for cmd in held.iter() {
            if let WsCommand::SendBinaryDirect { data, .. } = cmd {
                bytes += data.len();
                if data[0] != TYPE_CONTINUATION {
                    opened.extend(parse_id(&data[1..65]));
                }
            }
        }
        (bytes, opened)
    }

    /// The most bytes ever waiting in `rx` over a second, and the streams that opened.
    async fn watch_queue(rx: &mut mpsc::UnboundedReceiver<WsCommand>) -> (usize, Vec<String>) {
        let mut held = Vec::new();
        let mut most = 0;
        for _ in 0..10 {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            most = most.max(queued(rx, &mut held).0);
        }
        (most, queued(rx, &mut held).1)
    }

    /// A peer that asks for a big file again and again, while no data channel exists and
    /// the socket takes nothing, grows the sender's memory by at most a fixed budget, and
    /// a stream already running for that asker is never started twice.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[allow(clippy::await_holding_lock)] // HOLLOW_DATA_DIR is process-global
    async fn repeated_relay_streams_hold_a_fixed_byte_budget() {
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()); }
        const SIZE: u64 = 34 * 1024 * 1024;
        let source = tmp.path().join("big.bin");
        std::fs::write(&source, vec![0x5Au8; SIZE as usize]).unwrap();
        let (ws_tx, mut ws_rx) = mpsc::unbounded_channel();
        let us = "budget_us";
        let asked = super::super::file_handler::file_stream_id(&"f".repeat(64), us, "asker");
        let others: Vec<String> = (0..2).map(|i| super::super::file_handler::file_stream_id(&format!("{i}").repeat(64), us, "asker")).collect();

        for _ in 0..4 {
            ws_stream_send(&ws_tx, us, "room", "asker", &StreamKind::File, &asked, &source, SIZE, 0, RelayRank::Member).await;
        }
        for id in &others {
            ws_stream_send(&ws_tx, us, "room", "asker", &StreamKind::File, id, &source, SIZE, 0, RelayRank::Member).await;
        }
        let (most, opened) = watch_queue(&mut ws_rx).await;
        assert!(most <= RELAY_STREAM_QUEUE_BYTES, "{most} bytes queued for a socket that takes nothing");
        assert_eq!(opened.iter().filter(|id| **id == asked).count(), 1, "a running stream started again");
    }

    /// Vault shards ride the same credited streams: a member asking for a big shard again
    /// and again queues at most the budget, and its stream starts once.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[allow(clippy::await_holding_lock)] // HOLLOW_DATA_DIR is process-global
    async fn vault_shard_relay_sends_hold_a_fixed_byte_budget() {
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()); }
        let shard = vec![0x3Cu8; 20 * 1024 * 1024];
        let (ws_tx, mut ws_rx) = mpsc::unbounded_channel();
        let us = "shard_us";
        let asked = super::super::vault_ops::shard_stream_id(&"c".repeat(64), 0, us, "member");
        for _ in 0..4 {
            ws_stream_send_bytes(&ws_tx, us, "room", "member", &StreamKind::Shard { shard_index: 0 }, &asked, &shard, RelayRank::Member).await;
        }
        for si in 1..3 {
            let id = super::super::vault_ops::shard_stream_id(&"c".repeat(64), si, us, "member");
            ws_stream_send_bytes(&ws_tx, us, "room", "member", &StreamKind::Shard { shard_index: si }, &id, &shard, RelayRank::Member).await;
        }
        let (most, opened) = watch_queue(&mut ws_rx).await;
        assert!(most <= RELAY_STREAM_QUEUE_BYTES, "{most} shard bytes queued for a socket that takes nothing");
        assert_eq!(opened.iter().filter(|id| **id == asked).count(), 1, "a running shard stream started again");
        assert_eq!(relay_streams_running(us), 3, "the other shards never started");
    }

    /// Sealing a chunk keeps its credit, so the budget still holds it on the far side of
    /// the sealing stage, until the socket writes it; the write counts as progress.
    #[test]
    fn a_sealed_chunk_keeps_its_credit() {
        let budget = Arc::new(tokio::sync::Semaphore::new(10));
        let written = Arc::new(AtomicU64::new(0));
        let permit = budget.clone().try_acquire_many_owned(10).unwrap();
        let chunk = WsCommand::SendBinaryDirect {
            room_code: "room".into(),
            target_peer: "peer".into(),
            data: vec![TYPE_FILE; 80],
            credit: StreamCredit::new(permit, &written),
        };
        let kp = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[3; 32]);
        let sealed = super::super::frame_auth::seal_command(&kp, chunk);
        assert_eq!(budget.available_permits(), 0, "sealing gave the chunk's credit back before the write");
        assert_eq!(written.load(Ordering::Relaxed), 0);
        drop(sealed);
        assert_eq!(budget.available_permits(), 10, "a written chunk kept its credit");
        assert_eq!(written.load(Ordering::Relaxed), 1, "a written chunk did not count as the socket's progress");
    }

    fn stream_of(us: &str, asker: &str, n: usize) -> String {
        super::super::file_handler::file_stream_id(&format!("{n}"), us, asker)
    }

    /// One asker's relay streams are bounded, and a stream's place is free once it ends;
    /// our own sends stand outside every cap.
    #[test]
    fn relay_streams_are_bounded_per_asker() {
        let us = "caps_us";
        let mut places = Vec::new();
        for n in 0..MAX_RELAY_STREAMS_PER_ASKER {
            assert_eq!(relay_stream_admits(us, "greedy", &stream_of(us, "greedy", n), RelayRank::Member, 1), RelayAdmit::Start);
            places.push(start_relay_stream(us, "greedy", &stream_of(us, "greedy", n), RelayRank::Member, 1).expect("a free place"));
        }
        assert_eq!(relay_stream_admits(us, "greedy", &stream_of(us, "greedy", 0), RelayRank::Member, 1), RelayAdmit::Running);
        assert_eq!(relay_stream_admits(us, "greedy", &stream_of(us, "greedy", 999), RelayRank::Member, 1), RelayAdmit::Busy, "one asker took more than its share");
        assert_eq!(relay_stream_admits(us, "other", &stream_of(us, "other", 0), RelayRank::Member, 1), RelayAdmit::Start, "a full asker held up another");
        assert_eq!(relay_stream_admits(us, "greedy", &stream_of(us, "greedy", 999), RelayRank::Own, 1), RelayAdmit::Start, "our own send was capped");
        places.pop();
        assert_eq!(relay_stream_admits(us, "greedy", &stream_of(us, "greedy", 999), RelayRank::Member, 1), RelayAdmit::Start, "an ended stream kept its place");
    }

    /// Whether the stream `start` holds was ended by another taking its place.
    fn was_ended(start: &mut RelayStart) -> bool {
        !matches!(start.ended.try_recv(), Err(tokio::sync::oneshot::error::TryRecvError::Empty))
    }

    /// Four throwaway keys asking a big public file cannot fill a device: a newcomer takes
    /// the newest place of the asker holding the most, and a member always finds room
    /// among guests, while guests never displace members or one another's equal share.
    #[test]
    fn a_full_device_makes_room_from_the_heaviest_lowest_asker() {
        let us = "fair_us";
        let mut guests = Vec::new();
        for g in 0..4 {
            let asker = format!("guest{g}");
            for n in 0..MAX_RELAY_STREAMS / 4 {
                guests.push(start_relay_stream(us, &asker, &stream_of(us, &asker, n), RelayRank::Guest, 1).expect("a free place"));
            }
        }
        let mut fresh = start_relay_stream(us, "guest4", &stream_of(us, "guest4", 0), RelayRank::Guest, 1).expect("a fifth asker was locked out");
        let ended: Vec<usize> = guests.iter_mut().enumerate().filter_map(|(i, s)| was_ended(s).then_some(i)).collect();
        assert_eq!(ended, vec![MAX_RELAY_STREAMS - 1], "not the newest stream of the asker holding the most gave way");
        assert!(!was_ended(&mut fresh));
        drop(guests);
        drop(fresh);

        let us = "fair_us2";
        let mut held = Vec::new();
        for g in 0..MAX_RELAY_STREAMS {
            let asker = format!("one{g}");
            held.push(start_relay_stream(us, &asker, &stream_of(us, &asker, 0), RelayRank::Guest, 1).expect("a free place"));
        }
        assert_eq!(relay_stream_admits(us, "late", &stream_of(us, "late", 0), RelayRank::Guest, 1), RelayAdmit::Busy, "equal guests churned");
        assert_eq!(relay_stream_admits(us, "member", &stream_of(us, "member", 0), RelayRank::Member, 1), RelayAdmit::Start, "a member found no room among guests");
        let mut members = Vec::new();
        for m in 0..MAX_RELAY_STREAMS {
            let asker = format!("member{}", m / MAX_RELAY_STREAMS_PER_ASKER);
            members.push(start_relay_stream(us, &asker, &stream_of(us, &asker, m), RelayRank::Member, 1).expect("a member was turned away"));
        }
        assert!(held.iter_mut().all(was_ended), "a guest outlasted the members that needed its place");
        assert_eq!(relay_stream_admits(us, "late", &stream_of(us, "late", 0), RelayRank::Guest, 1), RelayAdmit::Busy, "a guest displaced a member");
        assert_eq!(relay_stream_admits(us, "us_sibling", &stream_of(us, "us_sibling", 0), RelayRank::Own, 1), RelayAdmit::Start);
    }

    /// The streams of one device hold a fixed number of staged bytes, shared the same way;
    /// one stream alone may hold more.
    #[test]
    fn relay_streams_hold_a_fixed_staged_byte_budget() {
        let us = "disk_us";
        const BIG: u64 = super::super::file_transfer::DEFAULT_MAX_FILE_SIZE;
        let fits = (RELAY_STAGED_BYTES / BIG) as usize;
        let mut held = Vec::new();
        for g in 0..fits {
            let asker = format!("guest{g}");
            held.push(start_relay_stream(us, &asker, &stream_of(us, &asker, 0), RelayRank::Guest, BIG).expect("a free place"));
        }
        assert_eq!(relay_stream_admits(us, "late", &stream_of(us, "late", 0), RelayRank::Guest, BIG), RelayAdmit::Busy, "staged bytes past the budget");
        let _member = start_relay_stream(us, "member", &stream_of(us, "member", 0), RelayRank::Member, BIG).expect("a member found no room among guests");
        assert_eq!(held.iter_mut().map(was_ended).filter(|e| *e).count(), 1, "a member's file displaced more than it needed");

        let alone = "disk_alone";
        let _own = start_relay_stream(alone, "us_sibling", &stream_of(alone, "us_sibling", 0), RelayRank::Own, 4 * RELAY_STAGED_BYTES).unwrap();
        assert_eq!(relay_stream_admits(alone, "member", &stream_of(alone, "member", 0), RelayRank::Member, 4 * RELAY_STAGED_BYTES), RelayAdmit::Start, "a file bigger than the budget can never be served");
    }

    /// A stream that ended leaves its successor of the same id alone: its own staged
    /// file and its place in the registry.
    #[test]
    #[allow(clippy::await_holding_lock)]
    fn an_ended_stream_never_touches_its_successor() {
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()); }
        let us = "race_us";
        let id = stream_of(us, "asker", 1);
        let stage = |start: &mut RelayStart| {
            let path = relay_stage_path(&id, start.place.seq);
            std::fs::write(&path, b"ciphertext").unwrap();
            start.place.staged = Some(path.clone());
            path
        };
        let mut first = start_relay_stream(us, "asker", &id, RelayRank::Member, 10).unwrap();
        let first_path = stage(&mut first);
        assert_eq!(end_relay_streams_to(us, "asker"), 1);
        let mut next = start_relay_stream(us, "asker", &id, RelayRank::Member, 10).expect("an ended stream kept its place");
        let next_path = stage(&mut next);
        drop(first);
        assert!(!first_path.exists(), "an ended stream left its staged file");
        assert!(next_path.exists(), "an ended stream unlinked the file its successor streams from");
        assert_eq!(relay_stream_admits(us, "asker", &id, RelayRank::Member, 10), RelayAdmit::Running, "an ended stream freed its successor's place");
        drop(next);
    }

    /// A device that left every room we share may only be hidden, still taking our
    /// frames, so its stream goes on; when it asks for that stream again its receive state
    /// is gone, and the ask replaces the stream instead of waiting behind it.
    #[test]
    fn a_device_that_left_is_served_again_when_it_asks() {
        let us = "left_us";
        let id = stream_of(us, "asker", 1);
        let mut first = start_relay_stream(us, "asker", &id, RelayRank::Member, 10).unwrap();
        let mut other = start_relay_stream(us, "other", &stream_of(us, "other", 1), RelayRank::Member, 10).unwrap();
        assert_eq!(relay_stream_admits(us, "asker", &id, RelayRank::Member, 10), RelayAdmit::Running);
        assert_eq!(orphan_relay_streams_to(us, "asker"), 1);
        assert!(!was_ended(&mut first), "a device that only hid lost its stream");
        assert_eq!(relay_stream_admits(us, "asker", &id, RelayRank::Member, 10), RelayAdmit::Start, "the asker's retry waits behind a stream it cannot receive");
        let _next = start_relay_stream(us, "asker", &id, RelayRank::Member, 10).expect("the retry was refused");
        assert!(was_ended(&mut first), "the replaced stream kept sending");
        assert!(!was_ended(&mut other), "another device's stream ended");
        assert_eq!(relay_stream_admits(us, "asker", &id, RelayRank::Member, 10), RelayAdmit::Running, "the replacement is no less running");
        assert_eq!(end_relay_streams_to(us, "asker"), 1);
    }

    fn stalled_stream() -> (Arc<tokio::sync::Semaphore>, Arc<AtomicU64>) {
        (Arc::new(tokio::sync::Semaphore::new(0)), Arc::new(AtomicU64::new(0)))
    }

    const STALL: std::time::Duration = std::time::Duration::from_millis(300);
    const CHECK: std::time::Duration = std::time::Duration::from_millis(20);

    /// A stream queued behind others' chunks waits as long as the socket keeps taking
    /// some, however long its own wait.
    #[tokio::test]
    async fn a_stream_waiting_behind_others_is_not_stalled() {
        let (credit, written) = stalled_stream();
        let (_end, mut ended) = tokio::sync::oneshot::channel::<()>();
        let (c, w) = (credit.clone(), written.clone());
        tokio::spawn(async move {
            for _ in 0..6 {
                tokio::time::sleep(STALL / 2).await;
                w.fetch_add(1, Ordering::Relaxed);
            }
            c.add_permits(10);
        });
        let stream = RelaySend { us: "slow", seq: 1, credit: &credit, written: &written };
        let began = std::time::Instant::now();
        assert!(relay_credit(&stream, 10, &mut ended, STALL, CHECK).await.is_some(), "a slow honest stream was dropped");
        assert!(began.elapsed() >= 2 * STALL);
    }

    /// A socket that takes none of our chunks ends the streams waiting on it, and an
    /// ended stream stops waiting at once.
    #[tokio::test]
    async fn a_socket_that_takes_nothing_ends_its_streams() {
        let (credit, written) = stalled_stream();
        let (_end, mut ended) = tokio::sync::oneshot::channel::<()>();
        let stream = RelaySend { us: "dead", seq: 1, credit: &credit, written: &written };
        let began = std::time::Instant::now();
        assert!(relay_credit(&stream, 10, &mut ended, STALL, CHECK).await.is_none());
        assert!(began.elapsed() >= STALL, "the stream ended before the stall time");

        let (end, mut ended) = tokio::sync::oneshot::channel::<()>();
        drop(end);
        let began = std::time::Instant::now();
        assert!(relay_credit(&stream, 10, &mut ended, std::time::Duration::from_secs(60), std::time::Duration::from_secs(60)).await.is_none());
        assert!(began.elapsed() < std::time::Duration::from_secs(5), "an ended stream kept waiting");
    }
}
