//! Per-stream state: one ingest leg fanning SFrame-ciphertext RTP to N egress
//! legs, plus the PLI aggregation task and aggregate counters.
//!
//! Zero metadata logging: the ONLY observable per-stream state is the
//! aggregate packet/byte counters — never per-viewer timing or identity logs.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use str0m::format::CodecSpec;
use str0m::media::Pt;
use str0m::rtp::RtpPacket;
use tokio::sync::{broadcast, mpsc};

use crate::hollow_log;
use crate::node::types::StreamOrigin;

use super::leg::LegCmd;

/// Streams key on the full origin triple — `(peer, kind, stream)` — never on
/// "originator is in the viewer mesh" (conference broadcast, locked decision 7).
pub(crate) type StreamKey = (String, String, String);

pub(crate) fn stream_key(o: &StreamOrigin) -> StreamKey {
    (o.peer.clone(), o.kind.clone(), o.stream.clone())
}

/// The shared fabric between a stream's legs (spike `Wiring`, per-stream now).
pub(crate) struct StreamWiring {
    /// ingest -> every egress leg (spike-proven capacity 512).
    pub fanout_tx: broadcast::Sender<Arc<RtpPacket>>,
    /// egress -> PLI aggregation task.
    pub kf_tx: mpsc::UnboundedSender<()>,
    /// The ingest leg's negotiated payload types: (pt, codec, clock_rate).
    /// Egress legs translate each packet's PT to their own numbering.
    pub ingest_params: std::sync::Mutex<Vec<(Pt, CodecSpec)>>,
}

/// Aggregate counters — the only thing the forwarder ever logs about a stream.
#[derive(Default)]
pub(crate) struct StreamCounters {
    pub ingest_pkts: AtomicU64,
    pub ingest_bytes: AtomicU64,
    pub egress_bytes: AtomicU64,
}

/// A running leg task (ingest or egress).
pub(crate) struct LegHandle {
    pub cmd_tx: mpsc::UnboundedSender<LegCmd>,
    pub task: tokio::task::JoinHandle<()>,
    pub port: u16,
    pub connected: Arc<AtomicBool>,
    pub spawned_at: Instant,
}

impl LegHandle {
    pub(crate) fn shut_down(&self) {
        let _ = self.cmd_tx.send(LegCmd::Shutdown);
        self.task.abort();
    }
}

pub(crate) struct StreamState {
    pub origin: StreamOrigin,
    /// The Olm-authenticated registrant — always == origin.peer (admission
    /// enforces it), kept separately so ownership checks survive any future
    /// origin evolution.
    pub owner: String,
    pub allowlist: HashSet<String>,
    pub ingest: Option<LegHandle>,
    /// viewer peer_id -> egress leg.
    pub egress: HashMap<String, LegHandle>,
    pub wiring: Arc<StreamWiring>,
    pub counters: Arc<StreamCounters>,
    /// The ingest leg's command sender, shared with the PLI aggregation task
    /// (the leg may not exist yet / may be replaced by a re-offer).
    pub ingest_cmd: Arc<tokio::sync::Mutex<Option<mpsc::UnboundedSender<LegCmd>>>>,
    pli_task: tokio::task::JoinHandle<()>,
}

impl StreamState {
    /// Create the stream shell (no legs yet) and spawn its PLI aggregation
    /// task: egress keyframe requests are deduped to at most one PLI per
    /// second upstream (spike-proven interval).
    pub(crate) fn new(origin: StreamOrigin, owner: String, allowlist: HashSet<String>) -> Self {
        let (fanout_tx, _) = broadcast::channel::<Arc<RtpPacket>>(512);
        let (kf_tx, mut kf_rx) = mpsc::unbounded_channel::<()>();
        let wiring = Arc::new(StreamWiring {
            fanout_tx,
            kf_tx,
            ingest_params: std::sync::Mutex::new(Vec::new()),
        });
        let ingest_cmd: Arc<tokio::sync::Mutex<Option<mpsc::UnboundedSender<LegCmd>>>> =
            Arc::new(tokio::sync::Mutex::new(None));

        let pli_task = {
            let ingest_cmd = ingest_cmd.clone();
            tokio::spawn(async move {
                const MIN_INTERVAL: Duration = Duration::from_secs(1);
                let mut last: Option<Instant> = None;
                while kf_rx.recv().await.is_some() {
                    // COALESCE, never drop. Rate limiting upstream matters (k
                    // viewers must not become k PLIs), but discarding a request
                    // inside the window can discard the ONLY one that mattered
                    // and leave a viewer black until the encoder happens to
                    // emit a keyframe — minutes, for screen content. So wait
                    // out the remainder instead, then collapse everything that
                    // piled up into one request.
                    if let Some(l) = last {
                        let elapsed = l.elapsed();
                        if elapsed < MIN_INTERVAL {
                            tokio::time::sleep(MIN_INTERVAL - elapsed).await;
                        }
                    }
                    while kf_rx.try_recv().is_ok() {}
                    last = Some(Instant::now());
                    match ingest_cmd.lock().await.as_ref() {
                        Some(tx) => {
                            let _ = tx.send(LegCmd::RequestKeyframe);
                        }
                        None => hollow_log!(
                            "[HOLLOW-FWD] keyframe request dropped — no ingest leg on this stream"
                        ),
                    }
                }
            })
        };

        Self {
            origin,
            owner,
            allowlist,
            ingest: None,
            egress: HashMap::new(),
            wiring,
            counters: Arc::new(StreamCounters::default()),
            ingest_cmd,
            pli_task,
        }
    }

    /// Tear the whole stream down (unregister / owner gone / shutdown).
    /// Returns the ports the legs held so the allocator can reclaim them.
    pub(crate) fn shut_down(self) -> Vec<u16> {
        let mut ports = Vec::new();
        if let Some(leg) = &self.ingest {
            leg.shut_down();
            ports.push(leg.port);
        }
        for leg in self.egress.values() {
            leg.shut_down();
            ports.push(leg.port);
        }
        self.pli_task.abort();
        hollow_log!(
            "[HOLLOW-FWD] stream closed: {} pkts in, {} bytes in, {} bytes out",
            self.counters.ingest_pkts.load(Ordering::Relaxed),
            self.counters.ingest_bytes.load(Ordering::Relaxed),
            self.counters.egress_bytes.load(Ordering::Relaxed),
        );
        ports
    }
}
