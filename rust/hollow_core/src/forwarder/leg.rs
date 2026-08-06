//! One WebRTC leg (ingest or egress): the sans-IO str0m pump, ported from the
//! passed D2 spike (`rust/spike_str0m/src/main.rs` — see
//! reports/MEDIA_FORWARDING_PLAN.md §7 for the field-test evidence).
//!
//! Spike-proven invariants preserved verbatim:
//! - WSAECONNRESET tolerated on BOTH UDP send and recv (a bounced ICE check's
//!   ICMP error surfaces on a later call and killed the leg right after "ICE
//!   Connected" otherwise). Harmless on Linux, load-bearing when this module
//!   embeds in-app on Windows in phase 2.
//! - `Event::MediaAdded` fires only for REMOTELY-added media — the egress
//!   leg's own SendOnly video line is tracked via the `Mid` returned by
//!   `add_media()`.
//! - Packets pass through with seq/timestamp UNTOUCHED (one source per
//!   stream; payload is SFrame ciphertext end to end); wallclock = arrival
//!   time; `.nackable(true)` puts each packet in str0m's own RTX cache, which
//!   serves egress NACKs — no hand-rolled packet ring (spike criterion 3
//!   passed with loss injected post-cache).
//! - PT translation by (codec, clock_rate) between the legs' independently
//!   numbered `codec_config().params()` spaces.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use str0m::change::{SdpAnswer, SdpOffer, SdpPendingOffer};
use str0m::format::CodecSpec;
use str0m::media::{Direction, MediaKind, Mid, Pt};
use str0m::rtp::{RtpWrite, Ssrc};
use str0m::{Candidate, Event, IceConnectionState, Input, Output, Rtc};
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot};

use crate::hollow_log;

use super::stream::{StreamCounters, StreamWiring};

/// Commands into a leg's pump.
pub(crate) enum LegCmd {
    /// Ingest leg: a complete SDP offer arrived from the sharer — answer it.
    AcceptOffer(String, oneshot::Sender<Result<String, String>>),
    /// Egress leg: the viewer answered our offer.
    AcceptAnswer(String),
    /// Ingest leg: a downstream viewer wants a keyframe (PLI, pre-aggregated
    /// by the stream's 1 s min-interval task).
    RequestKeyframe,
    /// Engine-initiated teardown.
    Shutdown,
}

/// Why the pump ended — reported to the engine so it can drop the leg handle.
pub(crate) struct LegEnded {
    pub stream: super::stream::StreamKey,
    /// `None` = the ingest leg; `Some(viewer)` = that viewer's egress leg.
    pub viewer: Option<String>,
}

/// Build an rtp-mode Rtc advertising ONE host candidate at the forwarder's
/// public address. The socket itself binds 0.0.0.0:port; `public_addr` is what
/// rides the SDP (identical when the VPS carries its public IP on the iface,
/// distinct behind 1:1 NAT).
fn build_rtc(public_addr: SocketAddr) -> Result<Rtc, String> {
    let mut rtc = Rtc::builder().set_rtp_mode(true).build(Instant::now());
    let cand = Candidate::host(public_addr, "udp").map_err(|e| e.to_string())?;
    rtc.add_local_candidate(cand);
    Ok(rtc)
}

/// Run an ingest leg on an already-bound socket. Answers the sharer's offer
/// (via `LegCmd::AcceptOffer`), fans every RtpPacket into the stream's
/// broadcast channel, forwards aggregated keyframe requests upstream.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_ingest_leg(
    socket: UdpSocket,
    public_addr: SocketAddr,
    cmd_rx: mpsc::UnboundedReceiver<LegCmd>,
    wiring: Arc<StreamWiring>,
    counters: Arc<StreamCounters>,
    connected: Arc<AtomicBool>,
    ended: LegEnded,
    ended_tx: mpsc::UnboundedSender<LegEnded>,
) {
    let mut rtc = match build_rtc(public_addr) {
        Ok(r) => r,
        Err(e) => {
            hollow_log!("[HOLLOW-FWD] ingest leg rtc build failed: {e}");
            let _ = ended_tx.send(ended);
            return;
        }
    };
    hollow_log!("[HOLLOW-FWD] ingest leg up (udp :{})", public_addr.port());
    if let Err(e) = pump(
        &mut rtc, socket, public_addr, cmd_rx, wiring, counters, connected, true, None, None,
    )
    .await
    {
        // Aggregate-only logging: which stream died is visible to the engine,
        // never logged with peer identities here.
        hollow_log!("[HOLLOW-FWD] ingest leg ended: {e}");
    }
    let _ = ended_tx.send(ended);
}

/// Run an egress leg: creates the SendOnly video offer (sent to the viewer via
/// the oneshot), then forwards fanned packets after the viewer answers.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_egress_leg(
    socket: UdpSocket,
    public_addr: SocketAddr,
    cmd_rx: mpsc::UnboundedReceiver<LegCmd>,
    wiring: Arc<StreamWiring>,
    counters: Arc<StreamCounters>,
    connected: Arc<AtomicBool>,
    offer_tx: oneshot::Sender<Result<String, String>>,
    ended: LegEnded,
    ended_tx: mpsc::UnboundedSender<LegEnded>,
) {
    let mut rtc = match build_rtc(public_addr) {
        Ok(r) => r,
        Err(e) => {
            let _ = offer_tx.send(Err(e));
            let _ = ended_tx.send(ended);
            return;
        }
    };

    let mut sdp = rtc.sdp_api();
    // Keep the mid: MediaAdded events fire only for REMOTELY-added media, so
    // this is the only handle to our own outgoing video line.
    let mid = sdp.add_media(MediaKind::Video, Direction::SendOnly, None, None, None);
    let Some((offer, pending)) = sdp.apply() else {
        let _ = offer_tx.send(Err("nothing to offer".into()));
        let _ = ended_tx.send(ended);
        return;
    };
    let offer_sdp = offer.to_sdp_string();
    hollow_log!(
        "[HOLLOW-FWD] egress leg up (udp :{}) — offer carries {} candidate line(s), {} byte(s)",
        public_addr.port(),
        offer_sdp.matches("a=candidate:").count(),
        offer_sdp.len()
    );
    let _ = offer_tx.send(Ok(offer_sdp));

    if let Err(e) = pump(
        &mut rtc, socket, public_addr, cmd_rx, wiring, counters, connected, false,
        Some(pending), Some(mid),
    )
    .await
    {
        hollow_log!("[HOLLOW-FWD] egress leg ended: {e}");
    }
    let _ = ended_tx.send(ended);
}

/// Translate an ingest-leg PT to the egress leg's PT for the SAME codec
/// configuration. The two SDP negotiations number payload types
/// independently, so a packet's PT is only meaningful on the leg that
/// negotiated it.
///
/// CRITICAL — the FULL `CodecSpec` must match, format params included, with
/// (codec, clock_rate) only as a last-resort fallback. Several codecs appear
/// MULTIPLE times in one PT space with different formats: VP9 twice
/// (profile-id 0 and 2), H264 seven times (packetization-mode +
/// profile-level-id combinations). Matching on (codec, clock_rate) alone can
/// therefore relabel a profile-0 VP9 stream as profile-2 — the receiver's
/// depacketizer accepts the packets, the decoder produces nothing, and the
/// viewer sees a BLACK SCREEN while byte counters climb happily. Field-
/// diagnosed 2026-08-06 (a VP9-preferring sharer; the D2 spike had only ever
/// exercised VP8, which is unambiguous).
pub(crate) fn map_pt(
    ingest: &[(Pt, CodecSpec)],
    egress: &[(Pt, CodecSpec)],
    pt: Pt,
) -> Option<Pt> {
    let (_, spec) = ingest.iter().find(|(p, _)| *p == pt)?;
    // Exact spec match (codec + clock rate + channels + format params).
    if let Some((p, _)) = egress.iter().find(|(_, s)| s == spec) {
        return Some(*p);
    }
    // Fallback: same codec + clock rate. Better than dropping the stream, but
    // a format mismatch may not decode — logged by the caller.
    egress
        .iter()
        .find(|(_, s)| s.codec == spec.codec && s.clock_rate == spec.clock_rate)
        .map(|(p, _)| *p)
}

/// Snapshot a leg's negotiated payload types as (pt, full spec) pairs.
fn pt_space(rtc: &Rtc) -> Vec<(Pt, CodecSpec)> {
    rtc.codec_config()
        .params()
        .iter()
        .map(|p| (p.pt(), p.spec()))
        .collect()
}

/// The shared sans-IO pump: drain poll_output, select over UDP / commands /
/// fanout / timeout. Direct port of the spike's `pump` minus the loss
/// injection, with counters + connected-flag reporting added.
#[allow(clippy::too_many_arguments)]
async fn pump(
    rtc: &mut Rtc,
    socket: UdpSocket,
    public_addr: SocketAddr,
    mut cmd_rx: mpsc::UnboundedReceiver<LegCmd>,
    wiring: Arc<StreamWiring>,
    counters: Arc<StreamCounters>,
    connected: Arc<AtomicBool>,
    is_ingest: bool,
    mut pending: Option<SdpPendingOffer>,
    egress_mid_init: Option<Mid>,
) -> Result<(), String> {
    let mut buf = vec![0u8; 2000];
    let mut fanout_rx = if is_ingest {
        None
    } else {
        Some(wiring.fanout_tx.subscribe())
    };
    let mut egress_mid: Option<Mid> = egress_mid_init;
    let mut ingest_mid: Option<Mid> = None;
    let mut pt_map: std::collections::HashMap<Pt, Option<Pt>> = std::collections::HashMap::new();
    let mut warned_no_tx = false;
    let mut saw_inbound = false;
    // The ingest stream's SSRC, learned from its packets. `stream_rx_by_mid`
    // is the primary handle for upstream keyframe requests, but it can miss
    // (no MediaAdded yet, rid-less lookup); an SSRC we have literally seen on
    // the wire always resolves.
    let mut ingest_ssrc: Option<Ssrc> = None;
    // CRITICAL: inbound packets must be reported with the ADVERTISED candidate
    // address as their destination — str0m matches `Receive.destination`
    // against local candidates, and the socket binds 0.0.0.0 (its local_addr
    // never equals the public host candidate). Reporting local_addr here made
    // str0m silently discard every inbound STUN check: both legs sat
    // "unconnected" while the clients' ICE timed out (first field test,
    // 2026-08-06). The spike dodged it by binding the LAN IP directly.
    let local = public_addr;

    loop {
        // Drain outputs until Timeout — but never for more than a bounded
        // number of outputs per pass. An egress leg fed by a live ingest can
        // otherwise stay inside this loop indefinitely and never reach the
        // select below, i.e. never read its socket, i.e. never see the peer's
        // ICE checks. Bailing early with a 1 ms deadline just re-enters
        // poll_output on the next tick; nothing is lost.
        let mut drained = 0u32;
        let deadline = loop {
            if drained >= 256 {
                break Instant::now() + std::time::Duration::from_millis(1);
            }
            drained += 1;
            match rtc.poll_output().map_err(|e| e.to_string())? {
                Output::Transmit(t) => {
                    // Windows UDP: sends can surface WSAECONNRESET from a
                    // PRIOR bounced datagram (ICMP port unreachable — ICE
                    // checks to dead candidates guarantee some). Not fatal.
                    if let Err(e) = socket.send_to(&t.contents, t.destination).await {
                        if e.kind() != std::io::ErrorKind::ConnectionReset {
                            return Err(e.to_string());
                        }
                    }
                }
                Output::Timeout(t) => break t,
                Output::Event(e) => match e {
                    Event::IceConnectionStateChange(s) => {
                        hollow_log!(
                            "[HOLLOW-FWD] {} leg ICE -> {s:?} (udp :{})",
                            if is_ingest { "ingest" } else { "egress" },
                            public_addr.port()
                        );
                        if s == IceConnectionState::Disconnected {
                            return Err("ICE disconnected".into());
                        }
                    }
                    Event::Connected => {
                        connected.store(true, Ordering::Relaxed);
                        hollow_log!(
                            "[HOLLOW-FWD] {} leg connected (udp :{})",
                            if is_ingest { "ingest" } else { "egress" },
                            public_addr.port()
                        );
                        // A freshly connected viewer needs an I-frame NOW.
                        // Don't wait for its own PLI to arrive and survive the
                        // trip: ask upstream ourselves the moment the leg is
                        // usable (idempotent — the stream's aggregator
                        // rate-limits and coalesces).
                        if !is_ingest {
                            let _ = wiring.kf_tx.send(());
                        }
                    }
                    Event::MediaAdded(m) => {
                        if is_ingest {
                            ingest_mid = Some(m.mid);
                        } else {
                            egress_mid = Some(m.mid);
                        }
                    }
                    Event::RtpPacket(pkt) if is_ingest => {
                        counters.ingest_pkts.fetch_add(1, Ordering::Relaxed);
                        counters
                            .ingest_bytes
                            .fetch_add(pkt.payload.len() as u64, Ordering::Relaxed);
                        if ingest_ssrc != Some(pkt.header.ssrc) {
                            ingest_ssrc = Some(pkt.header.ssrc);
                        }
                        let _ = wiring.fanout_tx.send(Arc::new(pkt));
                    }
                    Event::KeyframeRequest(_) if !is_ingest => {
                        hollow_log!("[HOLLOW-FWD] egress leg asked for a keyframe");
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
                    Err(e) => return Err(e.to_string()),
                };
                // Decisive diagnostic for a leg that never connects: did the
                // peer's ICE checks reach us at all? (No peer id, no payload —
                // the source port only, which the peer chose.)
                if !saw_inbound {
                    saw_inbound = true;
                    hollow_log!(
                        "[HOLLOW-FWD] {} leg first inbound datagram from :{} ({} bytes)",
                        if is_ingest { "ingest" } else { "egress" },
                        source.port(), n
                    );
                }
                let input = Input::Receive(
                    Instant::now(),
                    str0m::net::Receive::new(
                        str0m::net::Protocol::Udp,
                        source,
                        local,
                        &buf[..n],
                    ).map_err(|e| e.to_string())?,
                );
                rtc.handle_input(input).map_err(|e| e.to_string())?;
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { return Err("engine gone".into()) };
                match cmd {
                    LegCmd::AcceptOffer(sdp, reply) => {
                        let result = SdpOffer::from_sdp_string(&sdp)
                            .map_err(|e| e.to_string())
                            .and_then(|offer| {
                                rtc.sdp_api().accept_offer(offer).map_err(|e| e.to_string())
                            });
                        match result {
                            Ok(answer) => {
                                let _ = reply.send(Ok(answer.to_sdp_string()));
                                // Snapshot the ingest leg's negotiated PT space
                                // for egress-side PT translation.
                                *wiring.ingest_params.lock().unwrap() = pt_space(rtc);
                            }
                            Err(e) => {
                                let _ = reply.send(Err(e.clone()));
                                return Err(format!("accept_offer failed: {e}"));
                            }
                        }
                    }
                    LegCmd::AcceptAnswer(sdp) => {
                        hollow_log!(
                            "[HOLLOW-FWD] egress leg answer in: {} candidate line(s), {} byte(s)",
                            sdp.matches("a=candidate:").count(), sdp.len()
                        );
                        let answer = SdpAnswer::from_sdp_string(&sdp).map_err(|e| e.to_string())?;
                        if let Some(p) = pending.take() {
                            rtc.sdp_api().accept_answer(p, answer).map_err(|e| e.to_string())?;
                        }
                    }
                    LegCmd::RequestKeyframe => {
                        // A viewer joining mid-stream can only start decoding
                        // from a keyframe, and screen-share encoders emit them
                        // very rarely on their own — a request that fails to
                        // reach the sharer costs the viewer MINUTES of black
                        // screen (field-measured 2m50s, 2026-08-06). Try the
                        // mid, then the SSRC we've actually seen.
                        let mut api = rtc.direct_api();
                        let via_mid = ingest_mid
                            .and_then(|mid| api.stream_rx_by_mid(mid, None))
                            .map(|rx| {
                                rx.request_keyframe(str0m::media::KeyframeRequestKind::Pli);
                                "mid"
                            });
                        let how = via_mid.or_else(|| {
                            ingest_ssrc
                                .and_then(|ssrc| api.stream_rx(&ssrc))
                                .map(|rx| {
                                    rx.request_keyframe(str0m::media::KeyframeRequestKind::Pli);
                                    "ssrc"
                                })
                        });
                        match how {
                            Some(h) => hollow_log!("[HOLLOW-FWD] PLI sent upstream (via {h})"),
                            None => hollow_log!(
                                "[HOLLOW-FWD] PLI NOT sent — no ingest StreamRx (mid={ingest_mid:?}, ssrc seen={})",
                                ingest_ssrc.is_some()
                            ),
                        }
                    }
                    LegCmd::Shutdown => return Ok(()),
                }
            }
            pkt = async {
                match fanout_rx.as_mut() {
                    Some(rx) => rx.recv().await.ok(),
                    None => std::future::pending().await,
                }
            }, if !is_ingest => {
                if let (Some(pkt), Some(mid)) = (pkt, egress_mid) {
                    // Translate the ingest leg's PT to this leg's PT for the
                    // same codec CONFIGURATION — the two SDP negotiations
                    // number payload types independently (see map_pt on why
                    // the format params must match, not just the codec).
                    let ingest_pt = pkt.header.payload_type;
                    let mapped = *pt_map.entry(ingest_pt).or_insert_with(|| {
                        let ingest = wiring.ingest_params.lock().unwrap();
                        let egress = pt_space(rtc);
                        let ingest_spec = ingest.iter().find(|(p, _)| *p == ingest_pt).map(|(_, s)| *s);
                        let out = map_pt(&ingest, &egress, ingest_pt);
                        // Once per distinct PT: the mapping decision, so a
                        // silent black screen can never again cost a field
                        // test. Codec identity only — no addresses, no ids.
                        match (ingest_spec, out) {
                            (Some(s), Some(p)) => {
                                let exact = egress.iter().any(|(ep, es)| *ep == p && es == &s);
                                hollow_log!(
                                    "[HOLLOW-FWD] PT map {ingest_pt:?} -> {p:?} ({:?}/{:?}) {}",
                                    s.codec, s.clock_rate,
                                    if exact { "exact" } else { "FORMAT MISMATCH — may not decode" }
                                );
                            }
                            (Some(s), None) => hollow_log!(
                                "[HOLLOW-FWD] PT {ingest_pt:?} ({:?}) has NO egress mapping — dropping these packets",
                                s.codec
                            ),
                            _ => hollow_log!(
                                "[HOLLOW-FWD] PT {ingest_pt:?} unknown on the ingest leg — dropping"
                            ),
                        }
                        out
                    });
                    let Some(egress_pt) = mapped else { continue };
                    let mut api = rtc.direct_api();
                    if let Some(tx) = api.stream_tx_by_mid(mid, None) {
                        // Seq/time pass through untouched — one source, one
                        // stream; payload is SFrame ciphertext end to end.
                        // wallclock = arrival time; nackable(true) = str0m's
                        // own RTX cache serves egress NACKs.
                        counters
                            .egress_bytes
                            .fetch_add(pkt.payload.len() as u64, Ordering::Relaxed);
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
                    } else if !warned_no_tx {
                        warned_no_tx = true;
                        hollow_log!("[HOLLOW-FWD] egress: no StreamTx for negotiated mid — cannot forward");
                    }
                }
            }
            _ = tokio::time::sleep(timeout) => {
                rtc.handle_input(Input::Timeout(Instant::now())).map_err(|e| e.to_string())?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use str0m::format::{Codec, FormatParams};
    use str0m::media::Frequency;

    fn spec(codec: Codec, clock_rate: Frequency, format: FormatParams) -> CodecSpec {
        CodecSpec { codec, clock_rate, channels: None, format }
    }

    fn vp9(profile_id: u32) -> CodecSpec {
        spec(
            Codec::Vp9,
            Frequency::NINETY_KHZ,
            FormatParams { profile_id: Some(profile_id), ..Default::default() },
        )
    }

    fn plain(codec: Codec, clock_rate: Frequency) -> CodecSpec {
        spec(codec, clock_rate, FormatParams::default())
    }

    #[test]
    fn pt_translation_by_codec_and_rate() {
        let ingest = vec![
            (Pt::from(96), plain(Codec::Vp8, Frequency::NINETY_KHZ)),
            (Pt::from(111), plain(Codec::Opus, Frequency::FORTY_EIGHT_KHZ)),
        ];
        let egress = vec![
            (Pt::from(102), plain(Codec::Vp8, Frequency::NINETY_KHZ)),
            (Pt::from(109), plain(Codec::Opus, Frequency::FORTY_EIGHT_KHZ)),
        ];
        assert_eq!(map_pt(&ingest, &egress, Pt::from(96)), Some(Pt::from(102)));
        assert_eq!(map_pt(&ingest, &egress, Pt::from(111)), Some(Pt::from(109)));
        // Unknown ingest PT → None.
        assert_eq!(map_pt(&ingest, &egress, Pt::from(97)), None);
        // Codec absent on egress → None.
        let egress_no_vp8 = vec![(Pt::from(109), plain(Codec::Opus, Frequency::FORTY_EIGHT_KHZ))];
        assert_eq!(map_pt(&ingest, &egress_no_vp8, Pt::from(96)), None);
    }

    /// The black-screen regression: a codec present MULTIPLE times with
    /// different format params must map profile-for-profile, never to the
    /// first entry that merely shares the codec name.
    #[test]
    fn pt_translation_respects_format_params() {
        let ingest = vec![(Pt::from(98), vp9(0)), (Pt::from(100), vp9(2))];
        // Egress numbers them the other way round AND lists profile 2 first.
        let egress = vec![(Pt::from(45), vp9(2)), (Pt::from(46), vp9(0))];
        assert_eq!(
            map_pt(&ingest, &egress, Pt::from(98)),
            Some(Pt::from(46)),
            "profile-0 VP9 must map to the egress profile-0 entry"
        );
        assert_eq!(
            map_pt(&ingest, &egress, Pt::from(100)),
            Some(Pt::from(45)),
            "profile-2 VP9 must map to the egress profile-2 entry"
        );
    }

    /// No exact format match → fall back to codec+clock rate rather than
    /// dropping the stream (the caller logs the mismatch).
    #[test]
    fn pt_translation_falls_back_when_format_absent() {
        let ingest = vec![(Pt::from(98), vp9(0))];
        let egress = vec![(Pt::from(120), vp9(2))];
        assert_eq!(map_pt(&ingest, &egress, Pt::from(98)), Some(Pt::from(120)));
    }
}
