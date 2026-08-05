//! THROWAWAY spike (media forwarding D2): one blind RTP hop between two Hollow
//! app instances through str0m, proving the forwarder architecture before D3.
//!
//! Topology:
//!   sharer app --(WS signaling :9099 + SRTP over UDP)--> spike --> viewer app
//!
//! The spike never holds SFrame keys — payloads stay originator-encrypted
//! ciphertext; str0m only terminates the hop-by-hop DTLS-SRTP layer.
//!
//! Signaling protocol (JSON text frames over one WS per app instance, all SDPs
//! COMPLETE — the Dart shim waits for ICE gathering to finish, no trickle):
//!   sharer -> spike: {"type":"hello","role":"sharer"}
//!                    {"type":"offer","sdp":"..."}       (libwebrtc offers)
//!   spike -> sharer: {"type":"answer","sdp":"..."}      (str0m answers)
//!   viewer -> spike: {"type":"hello","role":"viewer"}   (spike then offers)
//!   spike -> viewer: {"type":"offer","sdp":"..."}
//!   viewer -> spike: {"type":"answer","sdp":"..."}
//!
//! Acceptance instrumentation ([SPIKE] log lines):
//!   - ingest/egress ICE + DTLS state changes
//!   - forwarded packet/byte counters (1s cadence)
//!   - KeyframeRequest propagation egress->ingest (PLI)
//!   - `--drop-pct N`: drop N% of egress MEDIA datagrams at the UDP layer
//!     (post-RTX-cache, so viewer NACK/RTX recovery is genuinely exercised)
//!   - `--bind-ip <ip>`: LAN ip for the VM-viewer test (default 127.0.0.1)

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{bail, Context, Result};
use futures_util::{SinkExt, StreamExt};
use log::{info, warn};
use rand::Rng;
use serde::Deserialize;
use str0m::change::{SdpAnswer, SdpOffer};
use str0m::channel::ChannelId;
use str0m::format::PayloadParams;
use str0m::media::{Direction, MediaKind, Mid};
use rand::rngs::SmallRng;
use rand::SeedableRng;
use std::collections::HashMap;
use str0m::format::Codec;
use str0m::media::{Frequency, Pt};
use str0m::rtp::{RtpPacket, RtpWrite};
use str0m::{Candidate, Event, IceConnectionState, Input, Output, Rtc};
use tokio::net::{TcpListener, UdpSocket};
use tokio::sync::mpsc;

const WS_PORT: u16 = 9099;

#[derive(Debug, Deserialize)]
struct WireMsg {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    sdp: Option<String>,
}

/// Commands into a leg's sans-IO pump.
enum LegCmd {
    /// Ingest leg: an offer arrived from the sharer — answer it (reply goes
    /// out the oneshot).
    AcceptOffer(String, tokio::sync::oneshot::Sender<String>),
    /// Egress leg: the viewer answered our offer.
    AcceptAnswer(String),
    /// Ingest leg: a downstream viewer wants a keyframe (PLI aggregation).
    /// (Packet forwarding itself rides the broadcast channel, not LegCmd.)
    RequestKeyframe,
}

/// Packets fanning out of the ingest leg + keyframe requests fanning back.
struct Wiring {
    /// ingest -> every egress leg
    fanout_tx: tokio::sync::broadcast::Sender<Arc<RtpPacket>>,
    /// egress -> ingest (PLI)
    kf_tx: mpsc::UnboundedSender<()>,
    /// Ingest leg's negotiated payload types: (pt, codec, clock_rate).
    /// Egress legs translate each packet's PT to their own leg's PT for the
    /// same codec — the two negotiations number PTs independently.
    ingest_params: std::sync::Mutex<Vec<(Pt, Codec, Frequency)>>,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let mut bind_ip: IpAddr = "127.0.0.1".parse().unwrap();
    let mut drop_pct: u8 = 0;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--bind-ip" => {
                bind_ip = args.next().context("--bind-ip needs a value")?.parse()?;
            }
            "--drop-pct" => {
                drop_pct = args.next().context("--drop-pct needs a value")?.parse()?;
            }
            other => bail!("unknown arg {other}"),
        }
    }

    let (fanout_tx, _) = tokio::sync::broadcast::channel::<Arc<RtpPacket>>(512);
    let (kf_tx, kf_rx) = mpsc::unbounded_channel::<()>();
    let wiring = Arc::new(Wiring {
        fanout_tx,
        kf_tx,
        ingest_params: std::sync::Mutex::new(Vec::new()),
    });

    // The single ingest leg's command channel, installed when a sharer connects.
    let ingest_cmd: Arc<tokio::sync::Mutex<Option<mpsc::UnboundedSender<LegCmd>>>> =
        Arc::new(tokio::sync::Mutex::new(None));

    // PLI aggregation: fan keyframe requests to the ingest leg, min-interval 1s.
    {
        let ingest_cmd = ingest_cmd.clone();
        let mut kf_rx = kf_rx;
        tokio::spawn(async move {
            let mut last = Instant::now() - std::time::Duration::from_secs(10);
            while kf_rx.recv().await.is_some() {
                if last.elapsed() < std::time::Duration::from_secs(1) {
                    continue;
                }
                last = Instant::now();
                if let Some(tx) = ingest_cmd.lock().await.as_ref() {
                    let _ = tx.send(LegCmd::RequestKeyframe);
                    info!("[SPIKE] PLI: forwarded keyframe request upstream");
                }
            }
        });
    }

    let listener = TcpListener::bind((bind_ip, WS_PORT)).await?;
    info!("[SPIKE] signaling on ws://{bind_ip}:{WS_PORT}  (drop-pct={drop_pct})");

    loop {
        let (stream, from) = listener.accept().await?;
        let wiring = wiring.clone();
        let ingest_cmd = ingest_cmd.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_ws(stream, from, bind_ip, drop_pct, wiring, ingest_cmd).await {
                warn!("[SPIKE] ws session from {from} ended: {e:#}");
            }
        });
    }
}

async fn handle_ws(
    stream: tokio::net::TcpStream,
    from: SocketAddr,
    bind_ip: IpAddr,
    drop_pct: u8,
    wiring: Arc<Wiring>,
    ingest_cmd: Arc<tokio::sync::Mutex<Option<mpsc::UnboundedSender<LegCmd>>>>,
) -> Result<()> {
    let ws = tokio_tungstenite::accept_async(stream).await?;
    let (mut ws_tx, mut ws_rx) = ws.split();

    // First frame must be the hello.
    let role = loop {
        let Some(msg) = ws_rx.next().await else { bail!("closed before hello") };
        let msg = msg?;
        if !msg.is_text() {
            continue;
        }
        let m: WireMsg = serde_json::from_str(msg.to_text()?)?;
        if m.kind == "hello" {
            break m.role.unwrap_or_default();
        }
    };
    info!("[SPIKE] {from} connected as {role}");

    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<LegCmd>();

    match role.as_str() {
        "sharer" => {
            *ingest_cmd.lock().await = Some(cmd_tx.clone());
            // Wait for the offer, run the ingest pump.
            let wiring2 = wiring.clone();
            tokio::spawn(async move {
                if let Err(e) = run_leg(true, bind_ip, drop_pct, cmd_rx, wiring2).await {
                    warn!("[SPIKE] ingest leg died: {e:#}");
                }
            });
            while let Some(msg) = ws_rx.next().await {
                let msg = msg?;
                if !msg.is_text() {
                    continue;
                }
                let m: WireMsg = serde_json::from_str(msg.to_text()?)?;
                if m.kind == "offer" {
                    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
                    cmd_tx.send(LegCmd::AcceptOffer(m.sdp.context("offer without sdp")?, reply_tx))?;
                    let answer = reply_rx.await?;
                    ws_tx
                        .send(serde_json::json!({"type": "answer", "sdp": answer}).to_string().into())
                        .await?;
                    info!("[SPIKE] ingest: answered sharer offer");
                }
            }
        }
        "viewer" => {
            // Egress leg: str0m offers, the viewer answers.
            let wiring2 = wiring.clone();
            let (offer_tx, offer_rx) = tokio::sync::oneshot::channel::<String>();
            tokio::spawn(async move {
                if let Err(e) =
                    run_egress_leg(bind_ip, drop_pct, cmd_rx, wiring2, offer_tx).await
                {
                    warn!("[SPIKE] egress leg died: {e:#}");
                }
            });
            let offer = offer_rx.await?;
            ws_tx
                .send(serde_json::json!({"type": "offer", "sdp": offer}).to_string().into())
                .await?;
            info!("[SPIKE] egress: sent offer to viewer");
            while let Some(msg) = ws_rx.next().await {
                let msg = msg?;
                if !msg.is_text() {
                    continue;
                }
                let m: WireMsg = serde_json::from_str(msg.to_text()?)?;
                if m.kind == "answer" {
                    cmd_tx.send(LegCmd::AcceptAnswer(m.sdp.context("answer without sdp")?))?;
                    info!("[SPIKE] egress: viewer answered");
                }
            }
        }
        other => bail!("unknown role {other}"),
    }
    Ok(())
}

/// Build an rtp-mode Rtc with a host candidate on our UDP socket.
fn build_rtc(socket_addr: SocketAddr) -> Result<Rtc> {
    let mut rtc = Rtc::builder().set_rtp_mode(true).build(Instant::now());
    let cand = Candidate::host(socket_addr, "udp")?;
    rtc.add_local_candidate(cand);
    Ok(rtc)
}

/// Ingest pump: answers the sharer's offer, fans every RtpPacket into the
/// broadcast channel, forwards keyframe requests upstream.
async fn run_leg(
    is_ingest: bool,
    bind_ip: IpAddr,
    drop_pct: u8,
    cmd_rx: mpsc::UnboundedReceiver<LegCmd>,
    wiring: Arc<Wiring>,
) -> Result<()> {
    assert!(is_ingest);
    let socket = UdpSocket::bind((bind_ip, 0)).await?;
    let local = socket.local_addr()?;
    let mut rtc = build_rtc(local)?;
    info!("[SPIKE] ingest UDP on {local}");
    pump(&mut rtc, socket, drop_pct, cmd_rx, wiring, true, None, None).await
}

/// Egress pump: creates the sendonly video offer, then forwards packets.
async fn run_egress_leg(
    bind_ip: IpAddr,
    drop_pct: u8,
    cmd_rx: mpsc::UnboundedReceiver<LegCmd>,
    wiring: Arc<Wiring>,
    offer_tx: tokio::sync::oneshot::Sender<String>,
) -> Result<()> {
    let socket = UdpSocket::bind((bind_ip, 0)).await?;
    let local = socket.local_addr()?;
    let mut rtc = build_rtc(local)?;
    info!("[SPIKE] egress UDP on {local}");

    let mut sdp = rtc.sdp_api();
    // Keep the mid: MediaAdded events fire only for REMOTELY-added media, so
    // this is the only handle to our own outgoing video line.
    let mid = sdp.add_media(MediaKind::Video, Direction::SendOnly, None, None, None);
    let (offer, pending) = sdp.apply().context("nothing to offer")?;
    let _ = offer_tx.send(offer.to_sdp_string());

    pump(&mut rtc, socket, drop_pct, cmd_rx, wiring, false, Some(pending), Some(mid)).await
}

/// The shared sans-IO pump: drain poll_output, select over UDP/commands/timeout.
#[allow(clippy::too_many_arguments)]
async fn pump(
    rtc: &mut Rtc,
    socket: UdpSocket,
    drop_pct: u8,
    mut cmd_rx: mpsc::UnboundedReceiver<LegCmd>,
    wiring: Arc<Wiring>,
    is_ingest: bool,
    mut pending: Option<str0m::change::SdpPendingOffer>,
    egress_mid_init: Option<Mid>,
) -> Result<()> {
    let mut buf = vec![0u8; 2000];
    let mut fanout_rx = if is_ingest { None } else { Some(wiring.fanout_tx.subscribe()) };
    let mut media_flowing = false;
    let mut pkts: u64 = 0;
    let mut bytes: u64 = 0;
    let mut last_stat = Instant::now();
    let mut egress_mid: Option<Mid> = egress_mid_init;
    let mut ingest_mid: Option<Mid> = None;
    let mut pt_map: HashMap<Pt, Option<Pt>> = HashMap::new();
    let mut warned_no_tx = false;
    let mut forwarded_first = false;
    let mut rng = SmallRng::from_entropy();

    loop {
        // Drain outputs until Timeout.
        let deadline = loop {
            match rtc.poll_output()? {
                Output::Transmit(t) => {
                    // Loss simulation AFTER the RTX cache: only egress media
                    // datagrams once media is flowing (never ICE/DTLS).
                    let dropped = !is_ingest
                        && drop_pct > 0
                        && media_flowing
                        && t.contents.len() > 400
                        && rng.gen_range(0..100) < drop_pct;
                    if !dropped {
                        // Windows UDP: sends can surface WSAECONNRESET from a
                        // PRIOR bounced datagram (ICMP port unreachable — ICE
                        // checks to dead candidates guarantee some). Not fatal.
                        if let Err(e) = socket.send_to(&t.contents, t.destination).await {
                            if e.kind() != std::io::ErrorKind::ConnectionReset {
                                return Err(e.into());
                            }
                        }
                    }
                }
                Output::Timeout(t) => break t,
                Output::Event(e) => match e {
                    Event::IceConnectionStateChange(s) => {
                        info!("[SPIKE] {} ICE: {s:?}", if is_ingest { "ingest" } else { "egress" });
                        if s == IceConnectionState::Disconnected {
                            bail!("ICE disconnected");
                        }
                    }
                    Event::Connected => {
                        info!("[SPIKE] {} CONNECTED", if is_ingest { "ingest" } else { "egress" });
                    }
                    Event::MediaAdded(m) => {
                        info!("[SPIKE] media added: {m:?}");
                        if is_ingest {
                            ingest_mid = Some(m.mid);
                        } else {
                            egress_mid = Some(m.mid);
                        }
                    }
                    Event::RtpPacket(pkt) if is_ingest => {
                        pkts += 1;
                        bytes += pkt.payload.len() as u64;
                        media_flowing = true;
                        let _ = wiring.fanout_tx.send(Arc::new(pkt));
                        if last_stat.elapsed().as_secs() >= 1 {
                            info!("[SPIKE] ingest: {pkts} pkts, {bytes} payload bytes");
                            last_stat = Instant::now();
                        }
                    }
                    Event::KeyframeRequest(req) if !is_ingest => {
                        info!("[SPIKE] egress keyframe request: {req:?}");
                        let _ = wiring.kf_tx.send(());
                    }
                    _ => {}
                },
            }
        };

        let timeout = deadline
            .checked_duration_since(Instant::now())
            .unwrap_or(std::time::Duration::from_millis(1));

        tokio::select! {
            r = socket.recv_from(&mut buf) => {
                let (n, source) = match r {
                    Ok(v) => v,
                    // Windows UDP quirk: a prior send that bounced (ICMP port
                    // unreachable, e.g. an ICE check to a dead candidate)
                    // surfaces as WSAECONNRESET on the NEXT recv. Ignore —
                    // the killed-leg symptom this caused was "ingest ICE:
                    // Connected" immediately followed by leg death.
                    Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => continue,
                    Err(e) => return Err(e.into()),
                };
                let input = Input::Receive(
                    Instant::now(),
                    str0m::net::Receive::new(
                        str0m::net::Protocol::Udp,
                        source,
                        socket.local_addr()?,
                        &buf[..n],
                    )?,
                );
                rtc.handle_input(input)?;
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { bail!("signaling gone") };
                match cmd {
                    LegCmd::AcceptOffer(sdp, reply) => {
                        let offer = SdpOffer::from_sdp_string(&sdp)?;
                        let answer = rtc.sdp_api().accept_offer(offer)?;
                        let _ = reply.send(answer.to_sdp_string());
                        // Snapshot the ingest leg's negotiated PT space for
                        // egress-side PT translation.
                        let params: Vec<(Pt, Codec, Frequency)> = rtc
                            .codec_config()
                            .params()
                            .iter()
                            .map(|p| (p.pt(), p.spec().codec, p.spec().clock_rate))
                            .collect();
                        info!("[SPIKE] ingest PT space: {params:?}");
                        *wiring.ingest_params.lock().unwrap() = params;
                    }
                    LegCmd::AcceptAnswer(sdp) => {
                        let answer = SdpAnswer::from_sdp_string(&sdp)?;
                        if let Some(p) = pending.take() {
                            rtc.sdp_api().accept_answer(p, answer)?;
                        }
                    }
                    LegCmd::RequestKeyframe => {
                        // Ingest: ask the sharer for a keyframe (PLI).
                        if let Some(mid) = ingest_mid {
                            let mut api = rtc.direct_api();
                            if let Some(rx) = api.stream_rx_by_mid(mid, None) {
                                rx.request_keyframe(str0m::media::KeyframeRequestKind::Pli);
                            }
                        }
                    }
                }
            }
            pkt = async {
                match fanout_rx.as_mut() {
                    Some(rx) => rx.recv().await.ok(),
                    None => std::future::pending().await,
                }
            }, if !is_ingest => {
                if let (Some(pkt), Some(mid)) = (pkt, egress_mid) {
                    media_flowing = true;
                    // Translate the ingest leg's PT to this leg's PT for the
                    // same (codec, clock rate) — the two SDP negotiations
                    // number payload types independently. Spec-level format
                    // params are deliberately ignored (spike tolerance).
                    let ingest_pt = pkt.header.payload_type;
                    let mapped = *pt_map.entry(ingest_pt).or_insert_with(|| {
                        let ingest = wiring.ingest_params.lock().unwrap();
                        let spec = ingest.iter().find(|(p, _, _)| *p == ingest_pt)?;
                        let egress_pt = rtc
                            .codec_config()
                            .params()
                            .iter()
                            .find(|p| {
                                p.spec().codec == spec.1 && p.spec().clock_rate == spec.2
                            })
                            .map(|p| p.pt());
                        info!("[SPIKE] PT map: ingest {ingest_pt:?} -> egress {egress_pt:?} ({:?})", spec.1);
                        egress_pt
                    });
                    let Some(egress_pt) = mapped else { continue };
                    let mut api = rtc.direct_api();
                    if let Some(tx) = api.stream_tx_by_mid(mid, None) {
                        // Seq/time pass through untouched — one source, one
                        // stream; payload is SFrame ciphertext end to end.
                        // wallclock = arrival time (the doc's simple-SFU rule).
                        tx.write_rtp(
                            RtpWrite::new(
                                egress_pt,
                                pkt.seq_no,
                                pkt.header.timestamp,
                                pkt.timestamp,
                                pkt.payload.clone(),
                            )
                            .marker(pkt.header.marker)
                            .nackable(true),
                        );
                        if !forwarded_first {
                            forwarded_first = true;
                            info!("[SPIKE] egress: FORWARDING STARTED (pt {egress_pt:?})");
                        }
                    } else if !warned_no_tx {
                        warned_no_tx = true;
                        warn!("[SPIKE] egress: no StreamTx for mid {mid:?} — cannot forward (declare_stream_tx needed?)");
                    }
                }
            }
            _ = tokio::time::sleep(timeout) => {
                rtc.handle_input(Input::Timeout(Instant::now()))?;
            }
        }
    }
}

// Silence unused-import warnings for items referenced only in in-flux code
// paths while the spike is iterated against the real str0m 0.21 API.
#[allow(unused)]
fn _keep(_: Option<(ChannelId, PayloadParams)>) {}
