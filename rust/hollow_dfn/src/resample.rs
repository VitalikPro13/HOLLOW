//! Fixed 16 kHz <-> 48 kHz polyphase resampler pair for the denoise adapter.
//!
//! Why it exists: on Windows a 16 kHz-class mic runs the WHOLE capture chain
//! at 16 kHz fullband (160-sample 10 ms frames), but both engines (RNNoise,
//! DFN3) only speak 48 kHz / 480. The [`Adapter`] upsamples 1:3, denoises,
//! and downsamples 3:1 back — this module is that pair.
//!
//! [`Adapter`]: crate::Adapter
//!
//! Design: one linear-phase Kaiser-windowed-sinc prototype (145 taps at
//! 48 kHz, beta 6, -6 dB point 7.6 kHz) shared by both directions. The
//! upsampler runs it as 3 polyphase branches (48 kHz-rate zero-stuffing is
//! never materialized); the downsampler evaluates it only at the kept
//! samples. Odd length makes each direction's group delay an integer 72
//! samples at 48 kHz, so the round trip is a clean 48-sample delay at 16 kHz
//! (3 ms) with no fractional smear. Aliasing note: the downsample side looks
//! lax (transition centered on 8 kHz) but its input is upsampled 16 kHz
//! audio, which has no content above 8 kHz beyond the -60 dB stopband images
//! — the engines only attenuate, they never create HF.

/// Rate ratio between the two fixed rates.
const FACTOR: usize = 3;
/// Prototype length: odd for an integer group delay, padded to a multiple
/// of [`FACTOR`] so the polyphase branches are rectangular.
const TAPS: usize = 145;
const TAPS_PADDED: usize = 147;
const PHASE_TAPS: usize = TAPS_PADDED / FACTOR; // 49
/// Input samples per 10 ms frame at 16 kHz.
pub const FRAME_16K: usize = 160;
/// Output samples per 10 ms frame at 48 kHz.
pub const FRAME_48K: usize = 480;
/// Round-trip (up then down) delay in 16 kHz samples: 72 + 72 at 48 kHz.
pub const ROUND_TRIP_DELAY_16K: usize = (TAPS - 1) / FACTOR; // 48

/// Zeroth-order modified Bessel function (series expansion — converges in
/// ~25 terms for the beta used here). Construction-time only.
fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let half_x = x / 2.0;
    for k in 1..40 {
        term *= (half_x / k as f64) * (half_x / k as f64);
        sum += term;
        if term < 1e-18 * sum {
            break;
        }
    }
    sum
}

/// Kaiser-windowed sinc lowpass, unit DC gain, `TAPS` real taps padded with
/// trailing zeros to `TAPS_PADDED`.
fn prototype() -> [f32; TAPS_PADDED] {
    // -6 dB point at 7.6 kHz on the 48 kHz grid: keeps 16 kHz voice content
    // intact to ~7 kHz and is ~60 dB down by the 8.8 kHz image region.
    const CUTOFF: f64 = 7600.0 / 48000.0; // cycles per 48 kHz sample
    const BETA: f64 = 6.0;
    let mid = (TAPS - 1) as f64 / 2.0;
    let i0_beta = bessel_i0(BETA);
    let mut h = [0.0f32; TAPS_PADDED];
    let mut sum = 0.0f64;
    for (k, tap) in h.iter_mut().enumerate().take(TAPS) {
        let t = k as f64 - mid;
        let x = 2.0 * CUTOFF * t;
        let sinc = if x == 0.0 {
            1.0
        } else {
            (std::f64::consts::PI * x).sin() / (std::f64::consts::PI * x)
        };
        let r = t / mid;
        let w = bessel_i0(BETA * (1.0 - r * r).max(0.0).sqrt()) / i0_beta;
        let v = 2.0 * CUTOFF * sinc * w;
        *tap = v as f32;
        sum += v;
    }
    // Normalize to exactly unit DC gain so the round trip is level-true.
    let inv = (1.0 / sum) as f32;
    for tap in h.iter_mut() {
        *tap *= inv;
    }
    h
}

/// 16 kHz -> 48 kHz, one 10 ms frame per call.
pub struct Upsampler3 {
    /// `phase[p][s] = FACTOR * h[FACTOR * s + p]` — the gain-of-3
    /// compensates the implicit zero-stuffing.
    phases: Box<[[f32; PHASE_TAPS]; FACTOR]>,
    hist: [f32; PHASE_TAPS - 1],
}

impl Upsampler3 {
    pub fn new() -> Self {
        let h = prototype();
        let mut phases = Box::new([[0.0f32; PHASE_TAPS]; FACTOR]);
        for p in 0..FACTOR {
            for s in 0..PHASE_TAPS {
                phases[p][s] = FACTOR as f32 * h[FACTOR * s + p];
            }
        }
        Self {
            phases,
            hist: [0.0; PHASE_TAPS - 1],
        }
    }

    pub fn reset(&mut self) {
        self.hist.fill(0.0);
    }

    /// `input`: 160 samples at 16 kHz; `output`: 480 samples at 48 kHz.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) {
        assert_eq!(input.len(), FRAME_16K);
        assert_eq!(output.len(), FRAME_48K);
        let mut work = [0.0f32; PHASE_TAPS - 1 + FRAME_16K];
        work[..PHASE_TAPS - 1].copy_from_slice(&self.hist);
        work[PHASE_TAPS - 1..].copy_from_slice(input);
        for m in 0..FRAME_16K {
            // Newest input sample for output index m sits at work[m + 48].
            let base = m + PHASE_TAPS - 1;
            for (p, phase) in self.phases.iter().enumerate() {
                let mut acc = 0.0f32;
                for (s, &c) in phase.iter().enumerate() {
                    acc += c * work[base - s];
                }
                output[FACTOR * m + p] = acc;
            }
        }
        self.hist.copy_from_slice(&work[FRAME_16K..]);
    }
}

/// 48 kHz -> 16 kHz, one 10 ms frame per call.
pub struct Downsampler3 {
    taps: Box<[f32; TAPS_PADDED]>,
    hist: [f32; TAPS_PADDED - 1],
}

impl Downsampler3 {
    pub fn new() -> Self {
        Self {
            taps: Box::new(prototype()),
            hist: [0.0; TAPS_PADDED - 1],
        }
    }

    pub fn reset(&mut self) {
        self.hist.fill(0.0);
    }

    /// `input`: 480 samples at 48 kHz; `output`: 160 samples at 16 kHz.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) {
        assert_eq!(input.len(), FRAME_48K);
        assert_eq!(output.len(), FRAME_16K);
        let mut work = [0.0f32; TAPS_PADDED - 1 + FRAME_48K];
        work[..TAPS_PADDED - 1].copy_from_slice(&self.hist);
        work[TAPS_PADDED - 1..].copy_from_slice(input);
        for (m, o) in output.iter_mut().enumerate() {
            let base = FACTOR * m + TAPS_PADDED - 1;
            let mut acc = 0.0f32;
            for (k, &c) in self.taps.iter().enumerate() {
                acc += c * work[base - k];
            }
            *o = acc;
        }
        self.hist.copy_from_slice(&work[FRAME_48K..]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Null test gating the Windows 16 kHz path: up -> down with no
    /// processing must be a delayed identity for band-limited content.
    #[test]
    fn up_down_round_trip_is_delayed_identity() {
        let mut up = Upsampler3::new();
        let mut down = Downsampler3::new();
        let n = FRAME_16K * 50;
        let input: Vec<f32> = (0..n)
            .map(|i| {
                let t = i as f32 / 16000.0;
                let mut s = 0.0;
                for &f in &[300.0f32, 1000.0, 2900.0, 5500.0] {
                    s += (2.0 * std::f32::consts::PI * f * t).sin();
                }
                6000.0 * s
            })
            .collect();
        let mut output = vec![0.0f32; n];
        let mut full = [0.0f32; FRAME_48K];
        for (chunk_in, chunk_out) in input
            .chunks_exact(FRAME_16K)
            .zip(output.chunks_exact_mut(FRAME_16K))
        {
            up.process(chunk_in, &mut full);
            down.process(&full, chunk_out);
        }
        let start = FRAME_16K * 4;
        let mut sig = 0.0f64;
        let mut err = 0.0f64;
        for i in start..n - ROUND_TRIP_DELAY_16K {
            let want = input[i] as f64;
            let got = output[i + ROUND_TRIP_DELAY_16K] as f64;
            sig += want * want;
            err += (want - got) * (want - got);
        }
        let snr_db = 10.0 * (sig / err.max(1e-12)).log10();
        assert!(
            snr_db > 40.0,
            "resampler round trip SNR {snr_db:.1} dB — pair is broken"
        );
        assert!(output.iter().all(|s| s.is_finite()));
    }

    /// The upsampler must not create images: a 1 kHz tone at 16 kHz must
    /// come out of the upsampler with its 15/17 kHz images below -50 dB.
    #[test]
    fn upsampler_suppresses_images() {
        let mut up = Upsampler3::new();
        let n16 = FRAME_16K * 50;
        let mut out48 = vec![0.0f32; n16 * FACTOR];
        let mut full = [0.0f32; FRAME_48K];
        for f16 in 0..n16 / FRAME_16K {
            let input: Vec<f32> = (0..FRAME_16K)
                .map(|i| {
                    let t = (f16 * FRAME_16K + i) as f32 / 16000.0;
                    10000.0 * (2.0 * std::f32::consts::PI * 1000.0 * t).sin()
                })
                .collect();
            up.process(&input, &mut full);
            out48[f16 * FRAME_48K..(f16 + 1) * FRAME_48K].copy_from_slice(&full);
        }
        // Goertzel power at the fundamental vs the first image (15 kHz).
        let power = |freq: f32| -> f64 {
            let start = FRAME_48K * 4;
            let seg = &out48[start..];
            let (mut re, mut im) = (0.0f64, 0.0f64);
            for (i, &s) in seg.iter().enumerate() {
                let ph = 2.0 * std::f64::consts::PI * freq as f64 * i as f64
                    / 48000.0;
                re += s as f64 * ph.cos();
                im += s as f64 * ph.sin();
            }
            re * re + im * im
        };
        let fund = power(1000.0);
        let image = power(15000.0);
        let rej_db = 10.0 * (fund / image.max(1e-12)).log10();
        assert!(
            rej_db > 50.0,
            "image rejection only {rej_db:.1} dB — lowpass is broken"
        );
    }
}
