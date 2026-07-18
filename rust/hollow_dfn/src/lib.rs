//! Noise-suppression engines for the voice capture chain: RNNoise (the
//! default) and DeepFilterNet3, behind one format-adapting entry point.
//!
//! One [`Adapter`] instance = one capture stream. The capture
//! post-processor ports call it through the C ABI in
//! `hollow_core/src/dfn_ffi.rs` at the HEAD of the chain (post-AEC,
//! pre-EQ), passing the RAW shape the APM handed them; the adapter does
//! whatever conversion that shape needs (none, 16 kHz resample, or 3-band
//! merge/split) around a mono 48 kHz / 480-sample engine core — both
//! engines share that exact frame contract (480 = 10 ms @ 48 kHz = DFN3's
//! hop = RNNoise's FRAME_SIZE).
//!
//! Sample format contract: the chain works in float PCM at INT16 SCALE
//! (±32768). RNNoise natively speaks that scale; DFN wants ±1.0 and the
//! conversion happens HERE, in one place, so the native ports stay dumb.
//!
//! Realtime rules: construction cost is per-engine — RNNoise is instant,
//! DFN3 is EXPENSIVE (tract model load + graph optimization, 100–500 ms
//! desktop, ~15 s on phones) — never construct on the audio thread.
//! `process()` is allocation-free after construction.

use df::tract::{DfParams, DfTract, RuntimeParams};
use ndarray::{Array2, ArrayView2, ArrayViewMut2};
use nnnoiseless::DenoiseState;

pub mod resample;
pub mod split_band;

/// Samples per process call: 10 ms @ 48 kHz mono (== DFN3 hop size).
pub const FRAME: usize = 480;
/// The chain's full-scale float value (int16 scale).
const FULL_SCALE: f32 = 32768.0;
/// The only sample rate DFN3 models support.
pub const SAMPLE_RATE: usize = 48000;

pub struct Dfn {
    st: DfTract,
    /// Pre-allocated (1 × hop) staging buffers — `process_480` never allocates.
    in_buf: Array2<f32>,
    out_buf: Array2<f32>,
}

impl Dfn {
    /// Load the embedded default DFN3 model. Expensive — background thread only.
    pub fn new() -> Result<Self, String> {
        Self::from_params(DfParams::default())
    }

    /// Load a model from a DeepFilterNet onnx tar.gz byte blob (harness A/B:
    /// standard vs low-latency variant). `'static` because tract borrows the
    /// tar bytes for the model's lifetime — use `include_bytes!` or
    /// `Box::leak` a loaded file.
    pub fn from_model_bytes(bytes: &'static [u8]) -> Result<Self, String> {
        let params = DfParams::from_bytes(bytes)
            .map_err(|e| format!("DfParams::from_bytes: {e}"))?;
        Self::from_params(params)
    }

    fn from_params(params: DfParams) -> Result<Self, String> {
        let rp = RuntimeParams::default_with_ch(1);
        let st = DfTract::new(params, &rp).map_err(|e| format!("DfTract::new: {e}"))?;
        if st.sr != SAMPLE_RATE {
            return Err(format!("model sample rate {} != {SAMPLE_RATE}", st.sr));
        }
        if st.hop_size != FRAME {
            return Err(format!("model hop size {} != {FRAME}", st.hop_size));
        }
        Ok(Self {
            st,
            in_buf: Array2::zeros((1, FRAME)),
            out_buf: Array2::zeros((1, FRAME)),
        })
    }

    /// Denoise one 10 ms frame in place. `frame` is int16-scale floats
    /// (±32768), exactly [`FRAME`] samples. Returns the model's local SNR
    /// estimate (dB) on success.
    pub fn process_480(&mut self, frame: &mut [f32]) -> Result<f32, String> {
        if frame.len() != FRAME {
            return Err(format!("frame len {} != {FRAME}", frame.len()));
        }
        {
            let mut row = self.in_buf.row_mut(0);
            for (dst, &src) in row.iter_mut().zip(frame.iter()) {
                *dst = src / FULL_SCALE;
            }
        }
        let lsnr = self
            .st
            .process(
                ArrayView2::from(&self.in_buf),
                ArrayViewMut2::from(&mut self.out_buf),
            )
            .map_err(|e| format!("DfTract::process: {e}"))?;
        {
            let row = self.out_buf.row(0);
            for (dst, &src) in frame.iter_mut().zip(row.iter()) {
                // The model can slightly overshoot ±1.0; the chain's own
                // limiter sits downstream, so just scale back.
                *dst = src * FULL_SCALE;
            }
        }
        Ok(lsnr)
    }

    /// Cap the maximum suppression, in dB (e.g. 12.0 keeps 12 dB of the
    /// noise — "partial" suppression). `None`/very large = uncapped.
    pub fn set_atten_lim(&mut self, db: f32) {
        self.st.set_atten_lim(db);
    }

    /// Post-filter beta (0 disables): slightly over-attenuates noisy
    /// sections at some risk to speech naturalness.
    pub fn set_post_filter_beta(&mut self, beta: f32) {
        self.st.set_pf_beta(beta);
    }
}

/// Which suppressor runs inside the adapter. Wire values are part of the
/// C ABI (`hollow_dfn_create_engine`) — never renumber.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EngineKind {
    /// RNNoise via `nnnoiseless` — the default: instant init, ~1 MB,
    /// trivial CPU. The engine that actually runs everywhere.
    Rnnoise = 0,
    /// DeepFilterNet3 — higher suppression quality, expensive init
    /// (100–500 ms desktop, ~15 s mobile) and ~10x the CPU.
    Dfn3 = 1,
}

impl EngineKind {
    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(Self::Rnnoise),
            1 => Some(Self::Dfn3),
            _ => None,
        }
    }
}

enum EngineImpl {
    Rnnoise {
        st: Box<DenoiseState<'static>>,
        /// nnnoiseless can't process in place (in/out borrows) — scratch.
        out: Box<[f32; FRAME]>,
    },
    Dfn3(Box<Dfn>),
}

/// One engine behind the shared mono 48 kHz / 480-sample frame contract,
/// int16-scale floats in and out.
pub struct Denoiser {
    imp: EngineImpl,
    /// Voice probability of the LAST successfully processed frame —
    /// RNNoise computes it as a byproduct; DFN3 has none. -1.0 = absent.
    /// Only meaningful immediately after a successful process call.
    last_vad: f32,
}

impl Denoiser {
    /// Construct the given engine. RNNoise is instant; DFN3 blocks on the
    /// model load — background threads only.
    pub fn new(kind: EngineKind) -> Result<Self, String> {
        let imp = match kind {
            EngineKind::Rnnoise => {
                // Compile-time proof the two engines share a frame contract.
                const _: () = assert!(DenoiseState::FRAME_SIZE == FRAME);
                EngineImpl::Rnnoise {
                    st: DenoiseState::new(),
                    out: Box::new([0.0; FRAME]),
                }
            }
            EngineKind::Dfn3 => EngineImpl::Dfn3(Box::new(Dfn::new()?)),
        };
        Ok(Self {
            imp,
            last_vad: -1.0,
        })
    }

    pub fn kind(&self) -> EngineKind {
        match self.imp {
            EngineImpl::Rnnoise { .. } => EngineKind::Rnnoise,
            EngineImpl::Dfn3(_) => EngineKind::Dfn3,
        }
    }

    /// Denoise one 10 ms mono 48 kHz frame in place (int16-scale floats).
    pub fn process_480(&mut self, frame: &mut [f32]) -> Result<(), String> {
        if frame.len() != FRAME {
            return Err(format!("frame len {} != {FRAME}", frame.len()));
        }
        match &mut self.imp {
            EngineImpl::Rnnoise { st, out } => {
                // RNNoise natively works at int16 scale — no conversion.
                // The voice probability it computes anyway feeds the
                // chain's speech-presence gating (breath discrimination).
                let vad = st.process_frame(&mut out[..], frame);
                frame.copy_from_slice(&out[..]);
                self.last_vad = vad.clamp(0.0, 1.0);
                Ok(())
            }
            EngineImpl::Dfn3(dfn) => {
                self.last_vad = -1.0;
                dfn.process_480(frame).map(|_lsnr| ())
            }
        }
    }

    /// Voice probability of the last successfully processed frame, or -1.0
    /// when the engine has none (DFN3) or nothing was processed yet.
    pub fn last_vad(&self) -> f32 {
        self.last_vad
    }

    /// DFN3-only tuning; silently ignored by RNNoise (it has no such knobs).
    pub fn set_atten_lim(&mut self, db: f32) {
        if let EngineImpl::Dfn3(dfn) = &mut self.imp {
            dfn.set_atten_lim(db);
        }
    }

    /// DFN3-only tuning; silently ignored by RNNoise.
    pub fn set_post_filter_beta(&mut self, beta: f32) {
        if let EngineImpl::Dfn3(dfn) = &mut self.imp {
            dfn.set_post_filter_beta(beta);
        }
    }
}

/// What [`Adapter::process`] did with a frame.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AdaptStatus {
    /// The frame was denoised in place.
    Processed,
    /// The capture shape has no conversion path — frame left untouched.
    /// The ports latch this as `formatOk=false` so Dart falls back to
    /// WebRTC NS.
    Unsupported,
}

/// The format-adapting front end: accepts the RAW shape the APM hands the
/// capture post-processor and converts around the engine's mono 48 kHz /
/// 480 contract.
///
/// Supported shapes (everything else returns [`AdaptStatus::Unsupported`]):
/// - 48 kHz, 1 band, mono or stereo (planar) — direct. Stereo strategy:
///   denoise channel 0, copy to channel 1 (voice-call stereo capture is
///   virtually always duplicated mono).
/// - 48 kHz, 3 bands, mono (split-band 3x160) — synthesis merge ->
///   denoise -> analysis re-split with the WebRTC-matched bank.
/// - 16 kHz, 1 band, mono or stereo (Windows 16 kHz-class mics, 160/ch) —
///   1:3 polyphase upsample -> denoise -> 3:1 downsample (3 ms delay).
///
/// FIELD REALITY (2026-07-18): every current port wrapper (libwebrtc
/// desktop AND the Android AAR — both the LiveKit CustomProcessingAdapter
/// code) hands over `audio->channels()[0]` — LIVE FULLBAND MONO — and its
/// `num_bands` describes the APM's internal split, NOT the buffer layout.
/// The ports therefore always call with `num_bands=1, channels=1`; the
/// 3-band path is dormant insurance (kept: oracle-verified, and correct if
/// a future wrapper ever delivers real bands). Feeding fullband PCM
/// through the band path as if split = spectral garbage (the Pixel
/// "pixelated mic" test).
///
/// Known-unsupported by design: 32 kHz (would need a 2:3 resampler;
/// 32 kHz-native devices are rare — WebRTC NS fallback covers them).
pub struct Adapter {
    den: Denoiser,
    /// (rate, bands, channels) of the last accepted frame — conversion
    /// state is reset when it changes (device switch mid-session).
    shape: (usize, usize, usize),
    bank: split_band::ThreeBandFilterBank,
    up: resample::Upsampler3,
    down: resample::Downsampler3,
    full: Box<[f32; FRAME]>,
}

impl Adapter {
    /// Construction cost is the engine's — see [`Denoiser::new`].
    pub fn new(kind: EngineKind) -> Result<Self, String> {
        Ok(Self {
            den: Denoiser::new(kind)?,
            shape: (0, 0, 0),
            bank: split_band::ThreeBandFilterBank::new(),
            up: resample::Upsampler3::new(),
            down: resample::Downsampler3::new(),
            full: Box::new([0.0; FRAME]),
        })
    }

    pub fn engine(&self) -> EngineKind {
        self.den.kind()
    }

    /// Voice probability of the last successfully processed frame (-1.0 =
    /// none — DFN3 engine, or no frame processed yet). Read it right after
    /// a [`AdaptStatus::Processed`] return; the value is per 10 ms frame.
    pub fn last_vad(&self) -> f32 {
        self.den.last_vad()
    }

    /// Denoise one 10 ms capture frame in place. `buf` is the ENTIRE
    /// buffer the APM handed the port (all bands/channels, planar).
    pub fn process(
        &mut self,
        buf: &mut [f32],
        num_bands: usize,
        rate: usize,
        channels: usize,
    ) -> Result<AdaptStatus, String> {
        let new_shape = (rate, num_bands, channels);
        if self.shape != new_shape {
            self.shape = new_shape;
            self.bank.reset();
            self.up.reset();
            self.down.reset();
        }
        match (rate, num_bands, channels) {
            (48000, 1, c @ 1..=2) if buf.len() == FRAME * c => {
                self.den.process_480(&mut buf[..FRAME])?;
                if c == 2 {
                    let (ch0, ch1) = buf.split_at_mut(FRAME);
                    ch1.copy_from_slice(ch0);
                }
                Ok(AdaptStatus::Processed)
            }
            (48000, 3, 1) if buf.len() == FRAME => {
                self.bank.synthesis(buf, &mut self.full[..]);
                self.den.process_480(&mut self.full[..])?;
                self.bank.analysis(&self.full[..], buf);
                Ok(AdaptStatus::Processed)
            }
            (16000, 1, c @ 1..=2) if buf.len() == resample::FRAME_16K * c => {
                self.up
                    .process(&buf[..resample::FRAME_16K], &mut self.full[..]);
                self.den.process_480(&mut self.full[..])?;
                self.down
                    .process(&self.full[..], &mut buf[..resample::FRAME_16K]);
                if c == 2 {
                    let (ch0, ch1) = buf.split_at_mut(resample::FRAME_16K);
                    ch1.copy_from_slice(ch0);
                }
                Ok(AdaptStatus::Processed)
            }
            _ => Ok(AdaptStatus::Unsupported),
        }
    }

    /// DFN3-only tuning passthroughs (no-ops on RNNoise).
    pub fn set_atten_lim(&mut self, db: f32) {
        self.den.set_atten_lim(db);
    }

    pub fn set_post_filter_beta(&mut self, beta: f32) {
        self.den.set_post_filter_beta(beta);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_process_roundtrip_and_len_guard() {
        let mut dfn = Dfn::new().expect("model load");
        // Wrong length must be rejected untouched.
        let mut short = vec![0.0f32; 128];
        assert!(dfn.process_480(&mut short).is_err());

        // Sanity only — never assert the model's suppression POLICY here
        // (a steady tone is "noise" to DFN and gets zeroed, correctly; the
        // quality gate is the offline harness on real recordings). Feed
        // FRESH frames each call (never the processor's own output) of a
        // speech-shaped signal: 100 Hz harmonic stack, 4 Hz syllabic AM.
        for n in 0..100u32 {
            let mut frame: Vec<f32> = (0..FRAME)
                .map(|i| {
                    let t = (n as usize * FRAME + i) as f32 / 48000.0;
                    let am = 0.5 + 0.5 * (2.0 * std::f32::consts::PI * 4.0 * t).sin();
                    let mut s = 0.0f32;
                    for h in 1..=8 {
                        s += (2.0 * std::f32::consts::PI * 100.0 * h as f32 * t).sin()
                            / h as f32;
                    }
                    0.05 * FULL_SCALE * am * s
                })
                .collect();
            let lsnr = dfn.process_480(&mut frame).expect("process");
            assert!(lsnr.is_finite());
            assert!(frame.iter().all(|s| s.is_finite()));
            assert!(frame.iter().all(|s| s.abs() <= FULL_SCALE * 2.0));
        }

        // Silence in → (near-)silence out, finite.
        let mut quiet = vec![0.0f32; FRAME];
        dfn.process_480(&mut quiet).expect("process silence");
        assert!(quiet.iter().all(|s| s.is_finite()));
    }

    fn speech_frame(n: u32, len: usize, rate: f32) -> Vec<f32> {
        (0..len)
            .map(|i| {
                let t = (n as usize * len + i) as f32 / rate;
                let am = 0.5 + 0.5 * (2.0 * std::f32::consts::PI * 4.0 * t).sin();
                let mut s = 0.0f32;
                for h in 1..=8 {
                    s += (2.0 * std::f32::consts::PI * 110.0 * h as f32 * t).sin()
                        / h as f32;
                }
                2000.0 * am * s
            })
            .collect()
    }

    /// RNNoise engine sanity through the plain 480 contract: instant init,
    /// finite in-range output, silence stays near-silent.
    #[test]
    fn rnnoise_engine_process() {
        let mut den = Denoiser::new(EngineKind::Rnnoise).expect("rnnoise init");
        assert_eq!(den.kind(), EngineKind::Rnnoise);
        assert_eq!(den.last_vad(), -1.0, "no frame processed yet");
        for n in 0..100u32 {
            let mut frame = speech_frame(n, FRAME, 48000.0);
            den.process_480(&mut frame).expect("process");
            assert!(frame.iter().all(|s| s.is_finite()));
            assert!(frame.iter().all(|s| s.abs() <= FULL_SCALE * 2.0));
            // The free VAD byproduct is a probability once frames flow.
            let vad = den.last_vad();
            assert!((0.0..=1.0).contains(&vad), "vad {vad} out of range");
        }
        // DFN3-only knobs must be harmless no-ops here.
        den.set_atten_lim(24.0);
        den.set_post_filter_beta(0.02);
        let mut quiet = vec![0.0f32; FRAME];
        den.process_480(&mut quiet).expect("silence");
        assert!(quiet.iter().all(|s| s.is_finite()));
    }

    /// All three adapter conversion paths + the unsupported latch, on the
    /// instant engine. The conversion DSP itself is gated by the null tests
    /// in `split_band` and `resample`; this exercises the routing.
    #[test]
    fn adapter_routes_all_supported_shapes() {
        let mut ad = Adapter::new(EngineKind::Rnnoise).expect("adapter");
        assert_eq!(ad.engine(), EngineKind::Rnnoise);

        // 48 kHz fullband mono.
        for n in 0..20u32 {
            let mut buf = speech_frame(n, FRAME, 48000.0);
            let st = ad.process(&mut buf, 1, 48000, 1).expect("mono 48k");
            assert_eq!(st, AdaptStatus::Processed);
            assert!(buf.iter().all(|s| s.is_finite()));
        }

        // 48 kHz fullband stereo (planar dup-mono): channels come out equal.
        for n in 0..20u32 {
            let mono = speech_frame(n, FRAME, 48000.0);
            let mut buf = mono.clone();
            buf.extend_from_slice(&mono);
            let st = ad.process(&mut buf, 1, 48000, 2).expect("stereo 48k");
            assert_eq!(st, AdaptStatus::Processed);
            assert_eq!(buf[..FRAME], buf[FRAME..]);
        }

        // 48 kHz split-band mono (Android/Linux): 3x160 in one buffer.
        for n in 0..20u32 {
            let mut buf = speech_frame(n, FRAME, 48000.0); // stand-in bands
            let st = ad.process(&mut buf, 3, 48000, 1).expect("split 48k");
            assert_eq!(st, AdaptStatus::Processed);
            assert!(buf.iter().all(|s| s.is_finite()));
        }

        // 16 kHz fullband mono (Windows 16 kHz-class mic).
        for n in 0..20u32 {
            let mut buf = speech_frame(n, resample::FRAME_16K, 16000.0);
            let st = ad.process(&mut buf, 1, 16000, 1).expect("mono 16k");
            assert_eq!(st, AdaptStatus::Processed);
            assert!(buf.iter().all(|s| s.is_finite()));
        }

        // Unsupported shapes are reported, never errors: 32 kHz two-band,
        // wrong buffer length, zero channels.
        let mut two_band = vec![0.0f32; 320];
        assert_eq!(
            ad.process(&mut two_band, 2, 32000, 1).expect("2-band"),
            AdaptStatus::Unsupported
        );
        let mut short = vec![0.0f32; 100];
        assert_eq!(
            ad.process(&mut short, 1, 48000, 1).expect("short"),
            AdaptStatus::Unsupported
        );
        let mut none = vec![0.0f32; FRAME];
        assert_eq!(
            ad.process(&mut none, 1, 48000, 0).expect("no chans"),
            AdaptStatus::Unsupported
        );
    }
}
