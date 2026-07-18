//! DeepFilterNet3 noise-suppression engine for the voice capture chain.
//!
//! One instance = one mono 48 kHz stream. The capture post-processor ports
//! call this through the C ABI in `hollow_core/src/dfn_ffi.rs` at the HEAD
//! of the chain (post-AEC, pre-EQ). Frames are the APM's native cadence:
//! 480 samples = 10 ms @ 48 kHz — exactly DFN3's hop size.
//!
//! Sample format contract: the chain works in float PCM at INT16 SCALE
//! (±32768). DFN wants ±1.0. The conversion happens HERE, in one place,
//! so the three native ports stay dumb.
//!
//! Realtime rules: `new()` is EXPENSIVE (tract model load + graph
//! optimization, 100–500 ms) — never call it on the audio thread.
//! `process_480()` is allocation-free after construction and takes
//! ~1–2 ms on desktop CPUs (RTF 0.08–0.19).

use df::tract::{DfParams, DfTract, RuntimeParams};
use ndarray::{Array2, ArrayView2, ArrayViewMut2};

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
}
