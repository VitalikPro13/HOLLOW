//! Simulcast layer selection + RTP rewrite for ONE egress leg (phase 3).
//!
//! The ingest leg may carry 2 rid-keyed simulcast layers (contract rids:
//! `f` = full, `q` = quarter — chosen by OUR sharer, see
//! `ScreenShareService`). Each egress leg forwards exactly ONE layer, chosen
//! by the sharer's `low_viewers` set at attach time, with packet-level
//! selection — no re-encode anywhere.
//!
//! Because the layers are independent RTP sources (own SSRC / sequence /
//! timestamp / PictureID spaces), an egress leg that ever SWITCHES layers
//! must rewrite the forwarded packets into one continuous outgoing stream:
//! seq/ts offsets plus VP8 PictureID / TL0PICIDX / KEYIDX continuity (str0m's
//! `Vp8Patch` applies the descriptor rewrite at serialization; the payload
//! itself is SFrame ciphertext and is never touched — the descriptor rides in
//! the clear BEFORE the encrypted frame data by construction).
//!
//! Iron rules:
//! - A NON-simulcast source (no rids — every old sharer) is passthrough:
//!   seq/ts/payload byte-identical to phases 1/2. Zero regression by
//!   construction.
//! - Switches happen ONLY on the target layer's keyframe start (VP8 S-bit,
//!   partition 0, P-bit 0) — anything else decodes garbage. Non-VP8 layered
//!   streams lock to their first layer and never switch (the descriptor
//!   rewrite is VP8-only; the sharer constrains simulcast ingests to VP8).
//! - The OLD layer keeps flowing while a switch waits for its keyframe —
//!   make-before-break at packet granularity.

use str0m::media::Rid;
use str0m::rtp::{Vp8Descriptor, Vp8Patch};

/// Contract rid names (must match `ScreenShareService`'s simulcast encodings).
pub(crate) const RID_FULL: &str = "f";
pub(crate) const RID_LOW: &str = "q";

/// Nominal 90 kHz timestamp step inserted across a layer switch (one frame at
/// 30 fps). Only playout pacing at the single switch instant depends on it —
/// jitter buffers absorb the estimate error.
const TS_STEP: u32 = 3000;

/// What to do with one fanned-out packet.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Forward with these (possibly rewritten) values.
    Forward {
        seq: u64,
        ts: u32,
        /// VP8 descriptor rewrite to apply at serialization (`None` =
        /// descriptor already continuous, e.g. before any switch).
        patch: Option<Vp8Patch>,
    },
    Drop,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Mode {
    /// Nothing forwarded yet.
    Idle,
    /// Non-rid single stream: byte-identical passthrough (the shipped
    /// phase-1/2 behavior).
    Passthrough,
    /// Rid-keyed source; exactly one layer forwarded at a time.
    Layered { current: Rid },
}

/// Per-egress-leg selection + rewrite state. Pure (no I/O, no clock) — the
/// pump owns timers (dry-layer fallback, keyframe re-requests) and feeds
/// desired-layer changes in via [`LayerSelect::set_desired`].
pub(crate) struct LayerSelect {
    desired: Option<Rid>,
    mode: Mode,
    /// Rewrite offsets — identity (0) until the first switch.
    seq_off: i64,
    ts_off: u32,
    pid_off: u16, // 15-bit PictureID space
    tl0_off: u8,
    key_off: u8, // 5-bit KEYIDX space
    /// Last forwarded OUTPUT values (post-rewrite) — switch continuity.
    last_out_seq: Option<u64>,
    last_out_ts: u32,
    last_out_pid: Option<u16>,
    last_out_tl0: Option<u8>,
    last_out_key: Option<u8>,
    /// The mode has ever switched — from then on VP8 descriptors are patched.
    switched: bool,
}

impl LayerSelect {
    pub(crate) fn new(desired: Option<Rid>) -> Self {
        Self {
            desired,
            mode: Mode::Idle,
            seq_off: 0,
            ts_off: 0,
            pid_off: 0,
            tl0_off: 0,
            key_off: 0,
            last_out_seq: None,
            last_out_ts: 0,
            last_out_pid: None,
            last_out_tl0: None,
            last_out_key: None,
            switched: false,
        }
    }

    /// The layer this leg is trying to forward (pump-owned policy).
    pub(crate) fn desired(&self) -> Option<Rid> {
        self.desired
    }

    pub(crate) fn set_desired(&mut self, desired: Option<Rid>) {
        self.desired = desired;
    }

    /// The layer currently being forwarded, when rid-keyed.
    pub(crate) fn current(&self) -> Option<Rid> {
        match self.mode {
            Mode::Layered { current } => Some(current),
            _ => None,
        }
    }

    /// True while a switch is pending (desired != current on a layered
    /// stream) — the pump keeps requesting keyframes for `desired`.
    pub(crate) fn switch_pending(&self) -> bool {
        match self.mode {
            Mode::Layered { current } => {
                self.desired.is_some_and(|d| d != current)
            }
            _ => false,
        }
    }

    /// Decide one packet. `seq`/`ts` are the INPUT stream values; on
    /// `Forward` the caller writes the returned values instead.
    pub(crate) fn on_packet(
        &mut self,
        rid: Option<Rid>,
        seq: u64,
        ts: u32,
        payload: &[u8],
        is_vp8: bool,
    ) -> Verdict {
        match (self.mode, rid) {
            (Mode::Idle, None) => {
                self.mode = Mode::Passthrough;
                self.forward(seq, ts, payload, is_vp8)
            }
            (Mode::Passthrough, None) => self.forward(seq, ts, payload, is_vp8),
            // Source turned out layered after all (late rid resolution):
            // adopt the first rid'd packet's layer; the desired-layer switch
            // machinery corrects the choice afterwards if needed.
            (Mode::Idle | Mode::Passthrough, Some(r)) => {
                if let Some(d) = self.desired {
                    if d != r && self.mode == Mode::Idle {
                        // Wait for the layer we actually want — the pump's
                        // dry-layer fallback re-desires if it never flows.
                        return Verdict::Drop;
                    }
                }
                self.mode = Mode::Layered { current: r };
                self.forward(seq, ts, payload, is_vp8)
            }
            // Rid-keyed source produced an unmapped packet — defensive drop.
            (Mode::Layered { .. }, None) => Verdict::Drop,
            (Mode::Layered { current }, Some(r)) => {
                if r == current {
                    return self.forward(seq, ts, payload, is_vp8);
                }
                let Some(desired) = self.desired else {
                    return Verdict::Drop;
                };
                if r != desired {
                    return Verdict::Drop;
                }
                // Switch target: only on its keyframe start, VP8 only.
                if !is_vp8 {
                    return Verdict::Drop;
                }
                let Ok(desc) = Vp8Descriptor::parse(payload) else {
                    return Verdict::Drop;
                };
                if !desc.starts_keyframe(payload) {
                    return Verdict::Drop;
                }
                // Compute continuity offsets from the last forwarded output.
                if let Some(last) = self.last_out_seq {
                    self.seq_off = (last as i64 + 1) - seq as i64;
                    self.ts_off = self.last_out_ts.wrapping_add(TS_STEP).wrapping_sub(ts);
                } else {
                    self.seq_off = 0;
                    self.ts_off = 0;
                }
                if let (Some(pid), Some(last)) = (desc.picture_id(), self.last_out_pid) {
                    self.pid_off = last.wrapping_add(1).wrapping_sub(pid) & 0x7FFF;
                }
                if let (Some(tl0), Some(last)) = (desc.tl0_pic_idx(), self.last_out_tl0) {
                    self.tl0_off = last.wrapping_add(1).wrapping_sub(tl0);
                }
                if let (Some(key), Some(last)) = (desc.key_idx(), self.last_out_key) {
                    self.key_off = last.wrapping_add(1).wrapping_sub(key) & 0x1F;
                }
                self.switched = true;
                self.mode = Mode::Layered { current: r };
                self.forward(seq, ts, payload, is_vp8)
            }
        }
    }

    fn forward(&mut self, seq: u64, ts: u32, payload: &[u8], is_vp8: bool) -> Verdict {
        let out_seq = (seq as i64 + self.seq_off) as u64;
        let out_ts = ts.wrapping_add(self.ts_off);
        self.last_out_seq = Some(out_seq);
        self.last_out_ts = out_ts;
        let mut patch = None;
        if is_vp8 && matches!(self.mode, Mode::Layered { .. }) {
            // Track descriptor continuity (and patch it once offsets exist).
            if let Ok(desc) = Vp8Descriptor::parse(payload) {
                if let Some(pid) = desc.picture_id() {
                    self.last_out_pid = Some(pid.wrapping_add(self.pid_off) & 0x7FFF);
                }
                if let Some(tl0) = desc.tl0_pic_idx() {
                    self.last_out_tl0 = Some(tl0.wrapping_add(self.tl0_off));
                }
                if let Some(key) = desc.key_idx() {
                    self.last_out_key = Some(key.wrapping_add(self.key_off) & 0x1F);
                }
                if self.switched {
                    let mut b = desc.patch();
                    if let Some(pid) = self.last_out_pid {
                        b = b.picture_id(pid);
                    }
                    if let Some(tl0) = self.last_out_tl0 {
                        b = b.tl0_pic_idx(tl0);
                    }
                    if let Some(key) = self.last_out_key {
                        b = b.key_idx(key);
                    }
                    // A build failure (field absent / value doesn't fit the
                    // 7-bit representation) forwards unpatched — the fields
                    // the receiver can see are then the source's own, which
                    // only matters across a switch on descriptors that carry
                    // them (in which case build succeeds).
                    patch = b.build().ok();
                }
            }
        }
        Verdict::Forward { seq: out_seq, ts: out_ts, patch }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rid(s: &str) -> Rid {
        Rid::from(s)
    }

    /// VP8 payload: X|S set, I (15-bit pid) + L (tl0) + T + K (keyidx)
    /// present (str0m's parser requires T whenever L is set, matching
    /// libwebrtc's real descriptors), then the payload header byte (P bit
    /// 0 = keyframe start).
    fn vp8_key(pid: u16, tl0: u8, key: u8) -> Vec<u8> {
        vec![
            0x90,                          // X | S, partition 0
            0xF0,                          // I | L | T | K
            0x80 | ((pid >> 8) as u8),     // pid hi (M bit = 15-bit)
            (pid & 0xFF) as u8,            // pid lo
            tl0,
            key & 0x1F, // TID 0 | Y 0 | KEYIDX
            0x00, // payload header: P=0 → keyframe
            0xAA, 0xBB,
        ]
    }

    fn vp8_delta(pid: u16, tl0: u8, key: u8) -> Vec<u8> {
        let mut p = vp8_key(pid, tl0, key);
        p[6] = 0x01; // P=1 → interframe
        p
    }

    /// Continuation packet of a frame (S bit clear) — never a switch point.
    fn vp8_cont(pid: u16, tl0: u8, key: u8) -> Vec<u8> {
        let mut p = vp8_key(pid, tl0, key);
        p[0] = 0x80; // X only, S clear
        p
    }

    fn fwd(v: Verdict) -> (u64, u32, Option<Vp8Patch>) {
        match v {
            Verdict::Forward { seq, ts, patch } => (seq, ts, patch),
            Verdict::Drop => panic!("expected Forward, got Drop"),
        }
    }

    #[test]
    fn non_rid_source_is_pure_passthrough() {
        let mut s = LayerSelect::new(Some(rid(RID_LOW)));
        // Even with a desired layer set, a rid-less source passes through
        // untouched — old sharers must see phase-1/2 behavior byte for byte.
        let (seq, ts, patch) = fwd(s.on_packet(None, 1000, 90_000, &vp8_key(5, 1, 0), true));
        assert_eq!((seq, ts), (1000, 90_000));
        assert!(patch.is_none());
        let (seq, ts, patch) = fwd(s.on_packet(None, 1001, 93_000, &vp8_delta(6, 1, 0), true));
        assert_eq!((seq, ts), (1001, 93_000));
        assert!(patch.is_none());
    }

    #[test]
    fn waits_for_desired_layer_then_forwards_identity() {
        let mut s = LayerSelect::new(Some(rid(RID_LOW)));
        // Full-layer packets before the low layer flows are dropped.
        assert_eq!(
            s.on_packet(Some(rid(RID_FULL)), 10, 1000, &vp8_key(1, 1, 0), true),
            Verdict::Drop
        );
        // First low-layer packet forwards with identity values.
        let (seq, ts, patch) = fwd(s.on_packet(Some(rid(RID_LOW)), 500, 7000, &vp8_key(9, 2, 1), true));
        assert_eq!((seq, ts), (500, 7000));
        assert!(patch.is_none());
        assert_eq!(s.current(), Some(rid(RID_LOW)));
        // Other-layer packets keep dropping.
        assert_eq!(
            s.on_packet(Some(rid(RID_FULL)), 11, 1030, &vp8_delta(2, 1, 0), true),
            Verdict::Drop
        );
    }

    #[test]
    fn switch_waits_for_keyframe_and_rewrites_continuously() {
        let mut s = LayerSelect::new(Some(rid(RID_FULL)));
        // Forward the full layer for a while.
        fwd(s.on_packet(Some(rid(RID_FULL)), 100, 3000, &vp8_key(50, 4, 2), true));
        let (seq, ts, _) = fwd(s.on_packet(Some(rid(RID_FULL)), 101, 6000, &vp8_delta(51, 4, 2), true));
        assert_eq!((seq, ts), (101, 6000));
        // Policy moves this leg to the low layer.
        s.set_desired(Some(rid(RID_LOW)));
        assert!(s.switch_pending());
        // Low-layer DELTA frames must not switch (would decode garbage)...
        assert_eq!(
            s.on_packet(Some(rid(RID_LOW)), 900, 500_000, &vp8_delta(7, 1, 0), true),
            Verdict::Drop
        );
        // ...and the old layer keeps flowing meanwhile (make-before-break).
        let (seq, _, _) = fwd(s.on_packet(Some(rid(RID_FULL)), 102, 9000, &vp8_delta(52, 4, 2), true));
        assert_eq!(seq, 102);
        // The low layer's keyframe start lands: switch with continuity.
        let (seq, ts, patch) =
            fwd(s.on_packet(Some(rid(RID_LOW)), 901, 512_000, &vp8_key(8, 2, 1), true));
        assert_eq!(seq, 103, "seq continues from the last forwarded packet");
        assert_eq!(ts, 9000 + 3000, "ts advances one nominal frame step");
        assert!(patch.is_some(), "descriptor continuity patch after a switch");
        assert!(!s.switch_pending());
        assert_eq!(s.current(), Some(rid(RID_LOW)));
        // Following low-layer packets stay continuous.
        let (seq, ts, patch) =
            fwd(s.on_packet(Some(rid(RID_LOW)), 902, 515_000, &vp8_delta(9, 2, 1), true));
        assert_eq!(seq, 104);
        assert_eq!(ts, 12_000 + 3000);
        assert!(patch.is_some());
        // Old-layer packets now drop.
        assert_eq!(
            s.on_packet(Some(rid(RID_FULL)), 103, 12_000, &vp8_delta(53, 4, 2), true),
            Verdict::Drop
        );
    }

    #[test]
    fn switch_ignores_continuation_packets() {
        let mut s = LayerSelect::new(Some(rid(RID_FULL)));
        fwd(s.on_packet(Some(rid(RID_FULL)), 1, 0, &vp8_key(1, 1, 0), true));
        s.set_desired(Some(rid(RID_LOW)));
        // A continuation packet (S clear) of a low-layer keyframe cannot be
        // the switch point — starts_keyframe requires the S bit.
        assert_eq!(
            s.on_packet(Some(rid(RID_LOW)), 40, 999, &vp8_cont(2, 1, 0), true),
            Verdict::Drop
        );
    }

    #[test]
    fn non_vp8_layered_locks_and_never_switches() {
        let mut s = LayerSelect::new(Some(rid(RID_FULL)));
        let payload = [0x12, 0x34, 0x56];
        fwd(s.on_packet(Some(rid(RID_FULL)), 1, 0, &payload, false));
        s.set_desired(Some(rid(RID_LOW)));
        // Non-VP8: the switch machinery refuses (no keyframe detection, no
        // descriptor patch) — the leg stays on its locked layer.
        assert_eq!(s.on_packet(Some(rid(RID_LOW)), 2, 30, &payload, false), Verdict::Drop);
        let (seq, _, patch) = fwd(s.on_packet(Some(rid(RID_FULL)), 2, 30, &payload, false));
        assert_eq!(seq, 2);
        assert!(patch.is_none());
    }

    #[test]
    fn picture_id_wraps_across_switch() {
        let mut s = LayerSelect::new(Some(rid(RID_FULL)));
        // Last full-layer pid near the 15-bit wrap.
        fwd(s.on_packet(Some(rid(RID_FULL)), 10, 0, &vp8_key(0x7FFE, 250, 30), true));
        s.set_desired(Some(rid(RID_LOW)));
        let (_, _, patch) = fwd(s.on_packet(Some(rid(RID_LOW)), 90, 100, &vp8_key(3, 9, 4), true));
        assert!(patch.is_some());
        // last_out_pid advanced with wrap: 0x7FFE + 1 = 0x7FFF.
        assert_eq!(s.last_out_pid, Some(0x7FFF));
        // Next low frame gets 0x0000 (wrapped).
        fwd(s.on_packet(Some(rid(RID_LOW)), 91, 200, &vp8_delta(4, 9, 4), true));
        assert_eq!(s.last_out_pid, Some(0x0000));
    }

    #[test]
    fn late_rid_resolution_adopts_first_layer() {
        let mut s = LayerSelect::new(None);
        // Passthrough begins rid-less...
        fwd(s.on_packet(None, 5, 0, &vp8_key(1, 1, 0), true));
        // ...then rids resolve: adopt the first tagged layer, keep identity.
        let (seq, _, _) = fwd(s.on_packet(Some(rid(RID_FULL)), 6, 3000, &vp8_delta(2, 1, 0), true));
        assert_eq!(seq, 6);
        assert_eq!(s.current(), Some(rid(RID_FULL)));
    }
}
