//! Engine: owns every stream + leg, applies the admission policy, spawns the
//! str0m pumps. Fed by `signaling.rs` (decrypted fwd envelopes + room
//! presence); replies flow back as `OutSignal`s for Olm encryption.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot};

use crate::hollow_log;
use crate::node::types::{MessageEnvelope, StreamOrigin};

use super::budget::{BudgetCfg, FwdErrorCode};
use super::dispatch::{
    admit_attach, admit_ingest_offer, admit_owner_op, admit_register, StreamView,
};
use super::leg::{self, Advertise, LegCmd, LegEnded};
use super::stream::{stream_key, LegHandle, StreamKey, StreamState};
use super::ForwarderConfig;

/// Commands into the engine.
pub(crate) enum EngineCmd {
    /// A decrypted, rate-limited fwd envelope from an Olm-authenticated peer.
    Signal { sender: String, envelope: MessageEnvelope },
    /// A peer left the fwd room (or vanished from a members snapshot).
    PeerGone(String),
    /// Drain for shutdown: refuse new work, tear down streams.
    Shutdown,
}

/// A plaintext reply envelope for `signaling.rs` to Olm-encrypt and send.
pub(crate) struct OutSignal {
    pub to_peer: String,
    pub envelope: MessageEnvelope,
}

/// Round-robin port allocation over the configured UDP range. No used-set: a port
/// still held by a live leg simply fails to bind and we try the next. `min == 0` =
/// embedded peer forwarder, which binds an OS-assigned ephemeral port per leg
/// because clients have no firewall config and outbound-first UDP already works.
struct PortAllocator {
    min: u16,
    max: u16,
    next: u16,
}

impl PortAllocator {
    fn new(min: u16, max: u16) -> Self {
        Self { min, max, next: min }
    }

    async fn bind(&mut self) -> Option<(UdpSocket, u16)> {
        if self.min == 0 {
            let sock = UdpSocket::bind(("0.0.0.0", 0)).await.ok()?;
            let port = sock.local_addr().ok()?.port();
            return Some((sock, port));
        }
        let span = (self.max - self.min) as u32 + 1;
        for _ in 0..span {
            let port = self.next;
            self.next = if self.next >= self.max { self.min } else { self.next + 1 };
            if let Ok(sock) = UdpSocket::bind(("0.0.0.0", port)).await {
                return Some((sock, port));
            }
        }
        None
    }
}

/// How legs advertise themselves: a fixed public IP on the VPS, or auto-discovered
/// (LAN IP of the default route plus a per-leg STUN mapping) when embedded.
#[derive(Clone, Copy)]
enum AdvertiseMode {
    Fixed(IpAddr),
    Auto { stun: Option<SocketAddr> },
}

impl AdvertiseMode {
    /// Build the per-leg advertise info. Auto mode re-reads the local IP per leg,
    /// because a laptop can change networks mid-session.
    fn for_leg(&self, port: u16) -> Advertise {
        match *self {
            AdvertiseMode::Fixed(ip) => Advertise { host: SocketAddr::new(ip, port), stun: None },
            AdvertiseMode::Auto { stun } => {
                let ip = local_route_ip(stun).unwrap_or(IpAddr::from([127, 0, 0, 1]));
                Advertise { host: SocketAddr::new(ip, port), stun }
            }
        }
    }
}

/// The local IP of the default-route interface: connect() on a UDP socket sends
/// nothing but resolves the route. The fallbacks exist purely for route selection.
fn local_route_ip(stun: Option<SocketAddr>) -> Option<IpAddr> {
    let target = stun.unwrap_or_else(|| SocketAddr::from(([1, 1, 1, 1], 53)));
    let sock = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect(target).ok()?;
    Some(sock.local_addr().ok()?.ip())
}

/// Resolve the configured STUN server, IPv4-only: an IPv6-first answer with no
/// routable IPv6 leaves media legs stranded.
async fn resolve_stun(server: &str) -> Option<SocketAddr> {
    match tokio::net::lookup_host(server).await {
        Ok(mut addrs) => addrs.find(|a| a.is_ipv4()),
        Err(e) => {
            hollow_log!("[HOLLOW-FWD] STUN server {server} did not resolve: {e}");
            None
        }
    }
}

pub(crate) async fn run(
    cfg: Arc<ForwarderConfig>,
    mut cmd_rx: mpsc::UnboundedReceiver<EngineCmd>,
    out_tx: mpsc::UnboundedSender<OutSignal>,
) {
    let budget = BudgetCfg {
        max_streams_global: cfg.max_streams_global,
        max_streams_per_sender: cfg.max_streams_per_sender,
        max_legs_per_stream: cfg.max_legs_per_stream,
        max_egress_bps: cfg.max_egress_bps,
    };
    // Empty public_ip = embedded peer forwarder (auto-advertise). The VPS
    // config always carries its fixed public IP.
    let advertise = if cfg.public_ip.is_empty() {
        let stun = match &cfg.stun_server {
            Some(s) => resolve_stun(s).await,
            None => None,
        };
        if stun.is_none() {
            hollow_log!("[HOLLOW-FWD] embedded engine has no STUN — LAN-only candidates");
        }
        AdvertiseMode::Auto { stun }
    } else {
        match cfg.public_ip.parse::<IpAddr>() {
            Ok(ip) => AdvertiseMode::Fixed(ip),
            Err(e) => {
                hollow_log!("[HOLLOW-FWD] invalid public_ip {}: {e}", cfg.public_ip);
                return;
            }
        }
    };
    let mut ports = PortAllocator::new(cfg.udp_port_min, cfg.udp_port_max);
    let mut streams: HashMap<StreamKey, StreamState> = HashMap::new();
    let mut shutting_down = false;
    let (ended_tx, mut ended_rx) = mpsc::unbounded_channel::<LegEnded>();

    // Egress bps estimate, sampled over the tick interval. Admission-only
    // granularity, and it never touches existing legs.
    let mut egress_bps: u64 = 0;
    let mut last_egress_bytes: u64 = 0;
    let mut ingest_bps: u64 = 0;
    let mut last_ingest_bytes: u64 = 0;
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    tick.tick().await; // consume the immediate first tick
    let mut ticks: u32 = 0;
    let mut was_active = false;

    loop {
        tokio::select! {
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { break };
                match cmd {
                    EngineCmd::Signal { sender, envelope } => {
                        handle_signal(
                            sender, envelope, &mut streams, &budget, egress_bps,
                            shutting_down, &mut ports, advertise, &out_tx, &ended_tx,
                        ).await;
                    }
                    EngineCmd::PeerGone(peer) => {
                        handle_peer_gone(&peer, &mut streams);
                    }
                    EngineCmd::Shutdown => {
                        shutting_down = true;
                        for (_, s) in streams.drain() {
                            s.shut_down();
                        }
                        hollow_log!("[HOLLOW-FWD] engine drained for shutdown");
                    }
                }
            }
            ended = ended_rx.recv() => {
                let Some(LegEnded { stream, viewer }) = ended else { break };
                if let Some(s) = streams.get_mut(&stream) {
                    match viewer {
                        None => {
                            // Ingest died on its own (ICE loss, sharer gone). Egress legs
                            // stay: viewers' feeds dry up and the receiver-initiates heal
                            // re-requests direct.
                            if let Some(leg) = s.ingest.take() {
                                leg.task.abort();
                            }
                            *s.ingest_cmd.lock().await = None;
                        }
                        Some(v) => {
                            if let Some(leg) = s.egress.remove(&v) {
                                leg.task.abort();
                            }
                        }
                    }
                }
            }
            _ = tick.tick() => {
                ticks += 1;
                sweep_unconnected_legs(&mut streams).await;
                // Reap streams spared by the presence-flap tolerance once their media
                // legs have dried up.
                let orphaned: Vec<StreamKey> = streams.iter()
                    .filter(|(_, s)| s.owner_gone && !s.has_live_media())
                    .map(|(k, _)| k.clone())
                    .collect();
                for key in orphaned {
                    if let Some(s) = streams.remove(&key) {
                        s.shut_down();
                        hollow_log!("[HOLLOW-FWD] swept a stream whose owner left (media legs gone)");
                    }
                }
                let total: u64 = streams.values()
                    .map(|s| s.counters.egress_bytes.load(Ordering::Relaxed))
                    .sum();
                egress_bps = total.saturating_sub(last_egress_bytes) * 8 / 10;
                last_egress_bytes = total;
                let total_in: u64 = streams.values()
                    .map(|s| s.counters.ingest_bytes.load(Ordering::Relaxed))
                    .sum();
                ingest_bps = total_in.saturating_sub(last_ingest_bytes) * 8 / 10;
                last_ingest_bytes = total_in;
                // ONE aggregate line per minute, and ONLY while active plus one trailing
                // idle line: an unchanging "0 streams" line every minute flooded journald
                // and rotated a whole field session's evidence out of retention.
                if ticks % 6 == 0 {
                    let active = !streams.is_empty();
                    if active || was_active {
                        let legs: usize = streams.values()
                            .map(|s| s.egress.len() + usize::from(s.ingest.is_some()))
                            .sum();
                        hollow_log!(
                            "[HOLLOW-FWD] {} stream(s), {} leg(s), ingest ~{} kbps, egress ~{} kbps",
                            streams.len(), legs, ingest_bps / 1000, egress_bps / 1000
                        );
                    }
                    was_active = active;
                }
            }
        }
    }
}

/// Reply with a `FwdError` for a refused request.
fn send_error(
    out_tx: &mpsc::UnboundedSender<OutSignal>,
    to_peer: &str,
    origin: &StreamOrigin,
    code: FwdErrorCode,
    detail: &str,
) {
    let _ = out_tx.send(OutSignal {
        to_peer: to_peer.to_string(),
        envelope: MessageEnvelope::FwdError {
            origin: Box::new(origin.clone()),
            code: code.as_wire().to_string(),
            detail: detail.to_string(),
        },
    });
    hollow_log!("[HOLLOW-FWD] refused {}: {}", code.as_wire(), detail);
}

fn view_of(streams: &HashMap<StreamKey, StreamState>, key: &StreamKey, sender: &str) -> Option<StreamView> {
    streams.get(key).map(|s| StreamView {
        owner: s.owner.clone(),
        sender_allowlisted: s.allowlist.contains(sender),
        egress_leg_count: s.egress.len() as u32,
        feeder: s.feeder.clone(),
    })
}

#[allow(clippy::too_many_arguments)]
async fn handle_signal(
    sender: String,
    envelope: MessageEnvelope,
    streams: &mut HashMap<StreamKey, StreamState>,
    budget: &BudgetCfg,
    egress_bps: u64,
    shutting_down: bool,
    ports: &mut PortAllocator,
    advertise: AdvertiseMode,
    out_tx: &mpsc::UnboundedSender<OutSignal>,
    ended_tx: &mpsc::UnboundedSender<LegEnded>,
) {
    match envelope {
        MessageEnvelope::FwdStreamRegister { origin, allowed_viewers, low_viewers, feeder } => {
            let key = stream_key(&origin);
            let already = streams
                .get(&key)
                .is_some_and(|s| s.owner == sender);
            let sender_streams = streams.values().filter(|s| s.owner == sender).count() as u32;
            if let Err(code) = admit_register(
                &origin.peer, &sender, sender_streams, streams.len() as u32,
                already, shutting_down, budget,
            ) {
                send_error(out_tx, &sender, &origin, code, "register refused");
                return;
            }
            let allowlist: HashSet<String> = allowed_viewers.into_iter().collect();
            let low: HashSet<String> = low_viewers.into_iter().collect();
            if already {
                if let Some(s) = streams.get_mut(&key) {
                    s.allowlist = allowlist;
                    s.low_viewers = low;
                    // Feeder election: only an OWNER-authored register can set or clear the
                    // delegation, and `admit_register` has already pinned origin == sender.
                    // Re-registers refresh it, so revoking is just an empty field.
                    s.feeder = feeder;
                    // An admitted owner op proves the owner is back, so undo a presence-flap
                    // mark and let a live re-share survive the sweep.
                    s.owner_gone = false;
                }
            } else {
                let mut state = StreamState::new((*origin).clone(), sender, allowlist);
                state.low_viewers = low;
                state.feeder = feeder;
                streams.insert(key, state);
                hollow_log!("[HOLLOW-FWD] stream registered ({} total)", streams.len());
            }
        }
        MessageEnvelope::FwdStreamAuth { origin, add, remove } => {
            let key = stream_key(&origin);
            if let Err(code) = admit_owner_op(view_of(streams, &key, &sender).as_ref(), &sender) {
                send_error(out_tx, &sender, &origin, code, "auth refused");
                return;
            }
            if let Some(s) = streams.get_mut(&key) {
                for v in add {
                    s.allowlist.insert(v);
                }
                for v in remove {
                    s.allowlist.remove(&v);
                    // De-authorized viewer loses its live leg too.
                    if let Some(leg) = s.egress.remove(&v) {
                        leg.shut_down();
                    }
                }
            }
        }
        MessageEnvelope::FwdStreamUnregister { origin } => {
            let key = stream_key(&origin);
            if let Err(code) = admit_owner_op(view_of(streams, &key, &sender).as_ref(), &sender) {
                send_error(out_tx, &sender, &origin, code, "unregister refused");
                return;
            }
            if let Some(s) = streams.remove(&key) {
                s.shut_down();
            }
        }
        MessageEnvelope::FwdIngestOffer { origin, sdp } => {
            let key = stream_key(&origin);
            // The owner OR its delegated feeder may supply the ingest. This is the only
            // relaxation of the owner binding; everything else stays owner-only.
            if let Err(code) = admit_ingest_offer(view_of(streams, &key, &sender).as_ref(), &sender) {
                send_error(out_tx, &sender, &origin, code, "ingest refused");
                return;
            }
            let Some((socket, port)) = ports.bind().await else {
                send_error(out_tx, &sender, &origin, FwdErrorCode::Full, "no UDP ports free");
                return;
            };
            let s = streams.get_mut(&key).expect("admitted stream exists");
            s.owner_gone = false;
            // A re-offer replaces the previous ingest leg.
            if let Some(old) = s.ingest.take() {
                old.shut_down();
            }
            let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<LegCmd>();
            let connected = Arc::new(AtomicBool::new(false));
            let task = tokio::spawn(leg::run_ingest_leg(
                socket,
                advertise.for_leg(port),
                cmd_rx,
                s.wiring.clone(),
                s.counters.clone(),
                connected.clone(),
                LegEnded { stream: key.clone(), viewer: None },
                ended_tx.clone(),
            ));
            *s.ingest_cmd.lock().await = Some(cmd_tx.clone());
            s.ingest = Some(LegHandle {
                cmd_tx: cmd_tx.clone(),
                task,
                port,
                connected,
                spawned_at: Instant::now(),
            });
            // The pump answers synchronously, so forward it as soon as the oneshot lands
            // rather than blocking the engine loop.
            let (reply_tx, reply_rx) = oneshot::channel();
            let _ = cmd_tx.send(LegCmd::AcceptOffer(sdp, reply_tx));
            let out_tx = out_tx.clone();
            let origin_echo = origin.clone();
            tokio::spawn(async move {
                match reply_rx.await {
                    Ok(Ok(answer)) => {
                        let _ = out_tx.send(OutSignal {
                            to_peer: sender,
                            envelope: MessageEnvelope::FwdIngestAnswer {
                                origin: origin_echo,
                                sdp: answer,
                            },
                        });
                    }
                    Ok(Err(e)) => {
                        hollow_log!("[HOLLOW-FWD] ingest accept_offer failed: {e}");
                    }
                    Err(_) => {}
                }
            });
        }
        MessageEnvelope::FwdAttach { origin } => {
            let key = stream_key(&origin);
            if let Err(code) = admit_attach(
                view_of(streams, &key, &sender).as_ref(), egress_bps, shutting_down, budget,
            ) {
                send_error(out_tx, &sender, &origin, code, "attach refused");
                return;
            }
            let Some((socket, port)) = ports.bind().await else {
                send_error(out_tx, &sender, &origin, FwdErrorCode::Full, "no UDP ports free");
                return;
            };
            let s = streams.get_mut(&key).expect("admitted stream exists");
            // Duplicate attach = tear down the old leg, offer fresh.
            if let Some(old) = s.egress.remove(&sender) {
                old.shut_down();
            }
            // Simulcast layer choice is attach-time: the sharer's register named the
            // viewers that ride the low layer.
            let want_low = s.low_viewers.contains(&sender);
            let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<LegCmd>();
            let connected = Arc::new(AtomicBool::new(false));
            let (offer_tx, offer_rx) = oneshot::channel();
            let task = tokio::spawn(leg::run_egress_leg(
                socket,
                advertise.for_leg(port),
                cmd_rx,
                s.wiring.clone(),
                s.counters.clone(),
                connected.clone(),
                want_low,
                offer_tx,
                LegEnded { stream: key.clone(), viewer: Some(sender.clone()) },
                ended_tx.clone(),
            ));
            s.egress.insert(sender.clone(), LegHandle {
                cmd_tx,
                task,
                port,
                connected,
                spawned_at: Instant::now(),
            });
            let out_tx = out_tx.clone();
            let origin_echo = origin.clone();
            tokio::spawn(async move {
                match offer_rx.await {
                    Ok(Ok(offer)) => {
                        let _ = out_tx.send(OutSignal {
                            to_peer: sender,
                            envelope: MessageEnvelope::FwdEgressOffer {
                                origin: origin_echo,
                                sdp: offer,
                            },
                        });
                    }
                    Ok(Err(e)) => {
                        hollow_log!("[HOLLOW-FWD] egress offer build failed: {e}");
                    }
                    Err(_) => {}
                }
            });
        }
        MessageEnvelope::FwdDetach { origin } => {
            let key = stream_key(&origin);
            if let Some(s) = streams.get_mut(&key) {
                if let Some(leg) = s.egress.remove(&sender) {
                    leg.shut_down();
                }
            }
        }
        MessageEnvelope::FwdEgressAnswer { origin, sdp } => {
            let key = stream_key(&origin);
            if let Some(leg) = streams.get(&key).and_then(|s| s.egress.get(&sender)) {
                let _ = leg.cmd_tx.send(LegCmd::AcceptAnswer(sdp));
            }
        }
        // signaling.rs whitelists, so anything else here is dropped defensively.
        _ => {}
    }
}

/// A peer left the fwd room: their owned streams unregister, their egress legs
/// detach. Signaling only reports peers that vanished from the room, never a
/// wholesale clear, so a forwarder-side WS blip does not kill live media.
fn handle_peer_gone(peer: &str, streams: &mut HashMap<StreamKey, StreamState>) {
    // Presence is a WEAK signal: ghost-socket eviction and members-snapshot races
    // report absences for peers whose media legs are alive. THE MEDIA LEG IS THE ONLY
    // TRUTH that may kill live forwarding, so presence loss tears down only what
    // carries no connected media and live streams are marked `owner_gone` for the
    // sweep.
    let owned: Vec<StreamKey> = streams
        .iter()
        .filter(|(_, s)| s.owner == peer)
        .map(|(k, _)| k.clone())
        .collect();
    for key in owned {
        let live = streams.get(&key).is_some_and(|s| s.has_live_media());
        if live {
            if let Some(s) = streams.get_mut(&key) {
                s.owner_gone = true;
            }
            hollow_log!(
                "[HOLLOW-FWD] presence drop for a stream owner ignored — media legs alive (sweep owns cleanup)"
            );
        } else if let Some(s) = streams.remove(&key) {
            s.shut_down();
        }
    }
    for s in streams.values_mut() {
        let connected = s
            .egress
            .get(peer)
            .is_some_and(|l| l.connected.load(Ordering::Relaxed));
        if connected {
            hollow_log!(
                "[HOLLOW-FWD] presence drop for a viewer ignored — its egress leg is alive"
            );
        } else if let Some(leg) = s.egress.remove(peer) {
            leg.shut_down();
        }
    }
}

/// Kill legs that never reached ICE Connected within the TTL (DoS bound).
async fn sweep_unconnected_legs(streams: &mut HashMap<StreamKey, StreamState>) {
    let now = Instant::now();
    for s in streams.values_mut() {
        if let Some(leg) = &s.ingest {
            if super::budget::sweep_unconnected(
                leg.spawned_at, leg.connected.load(Ordering::Relaxed), now,
            ) {
                if let Some(leg) = s.ingest.take() {
                    leg.shut_down();
                }
                *s.ingest_cmd.lock().await = None;
            }
        }
        let stale: Vec<String> = s
            .egress
            .iter()
            .filter(|(_, leg)| {
                super::budget::sweep_unconnected(
                    leg.spawned_at, leg.connected.load(Ordering::Relaxed), now,
                )
            })
            .map(|(v, _)| v.clone())
            .collect();
        for v in stale {
            if let Some(leg) = s.egress.remove(&v) {
                leg.shut_down();
            }
        }
    }
}
