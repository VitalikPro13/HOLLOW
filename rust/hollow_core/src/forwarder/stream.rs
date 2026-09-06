//! Per-stream state: one ingest leg fanning SFrame-ciphertext RTP to N egress legs,
//! plus the PLI aggregation task and aggregate counters. Zero metadata logging: the
//! only observable per-stream state is the aggregate packet and byte counters,
//! never per-viewer timing or identity.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use str0m::format::CodecSpec;
use str0m::media::{Pt, Rid};
use str0m::rtp::RtpPacket;
use tokio::sync::{broadcast, mpsc};

use crate::hollow_log;
use crate::node::types::StreamOrigin;

use super::leg::LegCmd;

/// One fanned-out packet. The ingest pump resolves each packet's simulcast layer
/// ONCE from str0m's SSRC-rid mapping, which outlives the RID header extension the
/// sender stops emitting after RTCP; `None` = a non-simulcast source.
pub(crate) type FanPkt = (Arc<RtpPacket>, Option<Rid>);

/// Streams key on the full origin triple — `(peer, kind, stream)` — never on
/// "originator is in the viewer mesh" (conference broadcast, locked decision 7).
pub(crate) type StreamKey = (String, String, String);

pub(crate) fn stream_key(o: &StreamOrigin) -> StreamKey {
    (o.peer.clone(), o.kind.clone(), o.stream.clone())
}

/// The shared fabric between a stream's legs (spike `Wiring`, per-stream now).
pub(crate) struct StreamWiring {
    /// ingest -> every egress leg (spike-proven capacity 512).
    pub fanout_tx: broadcast::Sender<FanPkt>,
    /// egress -> PLI aggregation task. `Some(rid)` targets one layer's source, `None`
    /// asks on every source seen, which is safe because the aggregator coalesces.
    pub kf_tx: mpsc::UnboundedSender<Option<Rid>>,
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
    /// The Olm-authenticated registrant, always == origin.peer (admission enforces
    /// it), kept separately so ownership checks survive any origin evolution.
    pub owner: String,
    pub allowlist: HashSet<String>,
    /// Viewers the sharer wants on the LOW layer, applied when a viewer's egress leg
    /// spawns; a later register refresh changes FUTURE attaches only.
    pub low_viewers: HashSet<String>,
    /// Feeder election: the ONE peer the OWNER delegated to supply this stream's
    /// ingest in its place (empty = nobody). Set only from an owner-authored register,
    /// and it grants SUPPLY only, never authority.
    pub feeder: String,
    pub ingest: Option<LegHandle>,
    /// viewer peer_id -> egress leg.
    pub egress: HashMap<String, LegHandle>,
    pub wiring: Arc<StreamWiring>,
    pub counters: Arc<StreamCounters>,
    /// The ingest leg's command sender, shared with the PLI aggregation task
    /// (the leg may not exist yet / may be replaced by a re-offer).
    pub ingest_cmd: Arc<tokio::sync::Mutex<Option<mpsc::UnboundedSender<LegCmd>>>>,
    /// The owner's room presence was lost while the stream still carried live media.
    /// The engine's sweep removes the stream once the media legs dry up: presence
    /// events alone must never kill live forwarding.
    pub owner_gone: bool,
    pli_task: tokio::task::JoinHandle<()>,
}

impl StreamState {
    /// Create the stream shell (no legs yet) and spawn its PLI aggregation task, which
    /// dedupes egress keyframe requests to at most one PLI per second upstream.
    pub(crate) fn new(origin: StreamOrigin, owner: String, allowlist: HashSet<String>) -> Self {
        let (fanout_tx, _) = broadcast::channel::<FanPkt>(512);
        let (kf_tx, mut kf_rx) = mpsc::unbounded_channel::<Option<Rid>>();
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
                while let Some(first) = kf_rx.recv().await {
                    // COALESCE, never drop. Rate limiting upstream matters (k viewers must
                    // not become k PLIs), but discarding a request inside the window can
                    // discard the ONLY one that mattered and leave a viewer black for
                    // minutes. Collapse per LAYER: layers are independent encoders.
                    if let Some(l) = last {
                        let elapsed = l.elapsed();
                        if elapsed < MIN_INTERVAL {
                            tokio::time::sleep(MIN_INTERVAL - elapsed).await;
                        }
                    }
                    let mut rids: Vec<Option<Rid>> = vec![first];
                    while let Ok(r) = kf_rx.try_recv() {
                        if !rids.contains(&r) {
                            rids.push(r);
                        }
                    }
                    // A layer-less request already covers every source.
                    if rids.contains(&None) {
                        rids = vec![None];
                    }
                    last = Some(Instant::now());
                    match ingest_cmd.lock().await.as_ref() {
                        Some(tx) => {
                            for rid in rids {
                                let _ = tx.send(LegCmd::RequestKeyframe(rid));
                            }
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
            low_viewers: HashSet::new(),
            feeder: String::new(),
            ingest: None,
            egress: HashMap::new(),
            wiring,
            counters: Arc::new(StreamCounters::default()),
            ingest_cmd,
            owner_gone: false,
            pli_task,
        }
    }

    /// Any ICE-connected media leg? While true, presence loss may not tear this
    /// stream down: leg death is the only truth.
    pub(crate) fn has_live_media(&self) -> bool {
        self.ingest
            .as_ref()
            .is_some_and(|l| l.connected.load(Ordering::Relaxed))
            || self
                .egress
                .values()
                .any(|l| l.connected.load(Ordering::Relaxed))
    }

    /// Tear the whole stream down, returning the ports the legs held so the allocator
    /// can reclaim them.
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
