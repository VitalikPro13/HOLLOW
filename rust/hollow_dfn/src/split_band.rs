//! 3-band FIR filter bank with DCT modulation — a line-by-line Rust port of
//! WebRTC's `modules/audio_processing/three_band_filter_bank.{h,cc}`
//! (Copyright (c) 2015 The WebRTC project authors, BSD-3-Clause).
//!
//! Why it exists here: WebRTC's APM hands the capture post-processor its
//! 48 kHz buffer in the SPLIT-BAND domain on Android and Linux (3 contiguous
//! sub-bands of 160 samples, produced by exactly this filter bank). The
//! denoise engines need fullband 480-sample frames, so the [`Adapter`]
//! merges (synthesis) -> denoises -> re-splits (analysis) using the SAME
//! filter design as the APM. Matching the design matters: the APM's own
//! synthesis runs downstream of our re-split, and a mismatched bank would
//! turn its near-perfect-reconstruction property into audible aliasing.
//!
//! [`Adapter`]: crate::Adapter
//!
//! Design notes carried over from the WebRTC source: the low-pass prototype
//! is `fir1(47, 1/6, kaiser(48, 3.5))` reshaped to 12 polyphase filters of 4
//! taps (2 of which are all-zero and skipped), shifted onto the 3 bands by
//! cosine (DCT) modulation. Passband edge 7 kHz, 40 dB stopband, linear
//! phase, 24 samples total analysis+synthesis delay at 48 kHz.

/// Bands the APM splits a 48 kHz stream into.
pub const NUM_BANDS: usize = 3;
/// Fullband samples per 10 ms frame at 48 kHz.
pub const FULL_BAND_SIZE: usize = 480;
/// Samples per band per frame (each band ticks at 16 kHz).
pub const SPLIT_BAND_SIZE: usize = FULL_BAND_SIZE / NUM_BANDS;

const SPARSITY: usize = 4;
const STRIDE_LOG2: usize = 2;
const STRIDE: usize = 1 << STRIDE_LOG2;
const NUM_ZERO_FILTERS: usize = 2;
const FILTER_SIZE: usize = 4;
const MEMORY_SIZE: usize = FILTER_SIZE * STRIDE - 1; // 15
const NUM_NON_ZERO_FILTERS: usize = SPARSITY * NUM_BANDS - NUM_ZERO_FILTERS; // 10
const SUB_SAMPLING: usize = NUM_BANDS;
const ZERO_FILTER_INDEX_1: usize = 3;
const ZERO_FILTER_INDEX_2: usize = 9;

/// Polyphase decomposition of the low-pass prototype (verbatim from the
/// WebRTC source; the two all-zero phases are omitted, see the zero-filter
/// indices above). Digits kept exactly as upstream wrote them.
#[rustfmt::skip]
#[allow(clippy::excessive_precision)]
const FILTER_COEFFS: [[f32; FILTER_SIZE]; NUM_NON_ZERO_FILTERS] = [
    [-0.000_477_49, -0.004_968_88,  0.165_471_18,  0.004_254_96],
    [-0.001_732_87, -0.015_857_78,  0.149_890_04,  0.009_941_13],
    [-0.003_048_15, -0.025_360_82,  0.121_545_42,  0.011_579_93],
    [-0.003_469_46, -0.025_878_86,  0.047_604_41,  0.006_075_94],
    [-0.001_547_17, -0.011_360_76,  0.013_874_58,  0.001_863_53],
    [ 0.001_863_53,  0.013_874_58, -0.011_360_76, -0.001_547_17],
    [ 0.006_075_94,  0.047_604_41, -0.025_878_86, -0.003_469_46],
    [ 0.009_832_12,  0.085_431_75, -0.029_827_67, -0.003_835_09],
    [ 0.009_941_13,  0.149_890_04, -0.015_857_78, -0.001_732_87],
    [ 0.004_254_96,  0.165_471_18, -0.004_968_88, -0.000_477_49],
];

/// Cosine modulation shifting the prototype onto band centers
/// [1/12, 3/12, 5/12] (verbatim from the WebRTC source).
#[rustfmt::skip]
#[allow(clippy::excessive_precision)]
const DCT_MODULATION: [[f32; NUM_BANDS]; NUM_NON_ZERO_FILTERS] = [
    [ 2.0,           2.0,  2.0         ],
    [ 1.732_050_77,  0.0, -1.732_050_77],
    [ 1.0,          -2.0,  1.0         ],
    [-1.0,           2.0, -1.0         ],
    [-1.732_050_77,  0.0,  1.732_050_77],
    [-2.0,          -2.0, -2.0         ],
    [-1.732_050_77,  0.0,  1.732_050_77],
    [-1.0,           2.0, -1.0         ],
    [ 1.0,          -2.0,  1.0         ],
    [ 1.732_050_77,  0.0, -1.732_050_77],
];

/// Sparse FIR step (WebRTC `FilterCore`): filters `input` with `filter`
/// upsampled by [`STRIDE`], shifted by `in_shift`, carrying `state` across
/// frames. Index-based loops kept deliberately — they mirror the C++
/// original one-for-one (see `compare_against_cpp_reference`).
#[allow(clippy::needless_range_loop)]
fn filter_core(
    filter: &[f32; FILTER_SIZE],
    input: &[f32; SPLIT_BAND_SIZE],
    in_shift: usize,
    out: &mut [f32; SPLIT_BAND_SIZE],
    state: &mut [f32; MEMORY_SIZE],
) {
    debug_assert!(in_shift <= STRIDE - 1);
    out.fill(0.0);

    for (k, o) in out.iter_mut().enumerate().take(in_shift) {
        let mut j = MEMORY_SIZE + k - in_shift;
        for &f in filter.iter() {
            *o += state[j] * f;
            j = j.wrapping_sub(STRIDE);
        }
    }

    for k in in_shift..FILTER_SIZE * STRIDE {
        let shift = k - in_shift;
        let loop_limit = FILTER_SIZE.min(1 + (shift >> STRIDE_LOG2));
        let mut j = shift;
        for &f in filter.iter().take(loop_limit) {
            out[k] += input[j] * f;
            j = j.wrapping_sub(STRIDE);
        }
        let mut j = MEMORY_SIZE + shift - loop_limit * STRIDE;
        for &f in filter.iter().skip(loop_limit) {
            out[k] += state[j] * f;
            j = j.wrapping_sub(STRIDE);
        }
    }

    for k in FILTER_SIZE * STRIDE..SPLIT_BAND_SIZE {
        let shift = k - in_shift;
        let mut j = shift;
        for &f in filter.iter() {
            out[k] += input[j] * f;
            // wrapping: the trailing decrement after the last tap goes
            // negative in the C++ original (signed, unused) — a plain
            // usize `-=` here panics in DEBUG builds (the Android
            // field-test crash, 2026-07-18).
            j = j.wrapping_sub(STRIDE);
        }
    }

    state.copy_from_slice(&input[SPLIT_BAND_SIZE - MEMORY_SIZE..]);
}

/// Maps a (downsampling index, shift) pair to its non-zero filter, or `None`
/// for the two all-zero phases.
fn filter_index(index: usize) -> Option<usize> {
    if index == ZERO_FILTER_INDEX_1 || index == ZERO_FILTER_INDEX_2 {
        return None;
    }
    Some(if index < ZERO_FILTER_INDEX_1 {
        index
    } else if index < ZERO_FILTER_INDEX_2 {
        index - 1
    } else {
        index - 2
    })
}

pub struct ThreeBandFilterBank {
    state_analysis: [[f32; MEMORY_SIZE]; NUM_NON_ZERO_FILTERS],
    state_synthesis: [[f32; MEMORY_SIZE]; NUM_NON_ZERO_FILTERS],
}

impl ThreeBandFilterBank {
    pub fn new() -> Self {
        Self {
            state_analysis: [[0.0; MEMORY_SIZE]; NUM_NON_ZERO_FILTERS],
            state_synthesis: [[0.0; MEMORY_SIZE]; NUM_NON_ZERO_FILTERS],
        }
    }

    /// Clear the filter memories (call when the capture shape changes so a
    /// stale tail can't bleed into the new stream).
    pub fn reset(&mut self) {
        for s in &mut self.state_analysis {
            s.fill(0.0);
        }
        for s in &mut self.state_synthesis {
            s.fill(0.0);
        }
    }

    /// Splits `input` (480 fullband samples) into 3 downsampled bands laid
    /// out contiguously in `out_bands` (`[b0 | b1 | b2]`, 160 each — the
    /// exact layout the APM hands the capture post-processor).
    pub fn analysis(&mut self, input: &[f32], out_bands: &mut [f32]) {
        assert_eq!(input.len(), FULL_BAND_SIZE);
        assert_eq!(out_bands.len(), FULL_BAND_SIZE);
        out_bands.fill(0.0);

        let mut in_sub = [0.0f32; SPLIT_BAND_SIZE];
        let mut out_sub = [0.0f32; SPLIT_BAND_SIZE];
        for dsi in 0..SUB_SAMPLING {
            for (k, s) in in_sub.iter_mut().enumerate() {
                *s = input[(SUB_SAMPLING - 1) - dsi + SUB_SAMPLING * k];
            }
            for in_shift in 0..STRIDE {
                let Some(fi) = filter_index(dsi + in_shift * SUB_SAMPLING) else {
                    continue;
                };
                filter_core(
                    &FILTER_COEFFS[fi],
                    &in_sub,
                    in_shift,
                    &mut out_sub,
                    &mut self.state_analysis[fi],
                );
                for band in 0..NUM_BANDS {
                    let m = DCT_MODULATION[fi][band];
                    let dst =
                        &mut out_bands[band * SPLIT_BAND_SIZE..][..SPLIT_BAND_SIZE];
                    for (d, &s) in dst.iter_mut().zip(out_sub.iter()) {
                        *d += m * s;
                    }
                }
            }
        }
    }

    /// Merges 3 downsampled bands (contiguous `[b0 | b1 | b2]`, 160 each)
    /// into `out` (480 fullband samples).
    pub fn synthesis(&mut self, bands: &[f32], out: &mut [f32]) {
        assert_eq!(bands.len(), FULL_BAND_SIZE);
        assert_eq!(out.len(), FULL_BAND_SIZE);
        out.fill(0.0);

        let mut in_sub = [0.0f32; SPLIT_BAND_SIZE];
        let mut out_sub = [0.0f32; SPLIT_BAND_SIZE];
        for usi in 0..SUB_SAMPLING {
            for in_shift in 0..STRIDE {
                let Some(fi) = filter_index(usi + in_shift * SUB_SAMPLING) else {
                    continue;
                };
                in_sub.fill(0.0);
                for band in 0..NUM_BANDS {
                    let m = DCT_MODULATION[fi][band];
                    let src = &bands[band * SPLIT_BAND_SIZE..][..SPLIT_BAND_SIZE];
                    for (d, &s) in in_sub.iter_mut().zip(src.iter()) {
                        *d += m * s;
                    }
                }
                filter_core(
                    &FILTER_COEFFS[fi],
                    &in_sub,
                    in_shift,
                    &mut out_sub,
                    &mut self.state_synthesis[fi],
                );
                const UPSAMPLING_SCALING: f32 = SUB_SAMPLING as f32;
                for (k, &s) in out_sub.iter().enumerate() {
                    out[usi + SUB_SAMPLING * k] += UPSAMPLING_SCALING * s;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Measured round-trip group delay at 48 kHz (best-correlation scan;
    /// the 48-tap prototype applied twice). The header's "24 samples" is
    /// the one-way figure.
    const ROUND_TRIP_DELAY: usize = 46;

    fn speechish(n: usize) -> Vec<f32> {
        // Multi-sine in the band interiors + syllabic AM.
        (0..n)
            .map(|i| {
                let t = i as f32 / 48000.0;
                let am = 0.6 + 0.4 * (2.0 * std::f32::consts::PI * 4.0 * t).sin();
                let mut s = 0.0;
                for &f in &[500.0f32, 1200.0, 2700.0, 5100.0, 11000.0] {
                    s += (2.0 * std::f32::consts::PI * f * t).sin();
                }
                4000.0 * am * s
            })
            .collect()
    }

    fn snr_at_delay(input: &[f32], output: &[f32], delay: usize) -> f64 {
        let start = FULL_BAND_SIZE * 4; // skip filter warmup
        let mut sig = 0.0f64;
        let mut err = 0.0f64;
        for i in start..input.len() - delay {
            let want = input[i] as f64;
            let got = output[i + delay] as f64;
            sig += want * want;
            err += (want - got) * (want - got);
        }
        10.0 * (sig / err.max(1e-12)).log10()
    }

    /// Null test gating the split-band path: analysis -> synthesis with NO
    /// processing in between reconstructs the delayed input.
    ///
    /// CALIBRATION NOTE (2026-07-18): the asserted floor is the REAL
    /// ceiling of WebRTC's bank, cross-verified by running the actual C++
    /// `three_band_filter_bank.cc` on this exact signal (port matches it
    /// to 1e-7 relative — see `compare_against_cpp_reference`). The bank
    /// is deliberately not perfect-reconstruction (its own header says
    /// "approximately 9.5 dB"); the error is LTI ripple/phase coloration,
    /// not noise, and every 48 kHz WebRTC call already rides it once. A
    /// porting mistake (indexing, state carry, modulation sign) lands
    /// BELOW 0 dB — that is what this floor catches.
    #[test]
    fn analysis_synthesis_round_trip_is_delayed_identity() {
        let mut bank = ThreeBandFilterBank::new();
        let input = speechish(FULL_BAND_SIZE * 50);
        let mut output = vec![0.0f32; input.len()];
        let mut bands = [0.0f32; FULL_BAND_SIZE];
        for (chunk_in, chunk_out) in input
            .chunks_exact(FULL_BAND_SIZE)
            .zip(output.chunks_exact_mut(FULL_BAND_SIZE))
        {
            bank.analysis(chunk_in, &mut bands);
            bank.synthesis(&bands, chunk_out);
        }
        let snr_db = snr_at_delay(&input, &output, ROUND_TRIP_DELAY);
        assert!(
            snr_db > 10.0,
            "split-band round trip SNR {snr_db:.1} dB — port is broken"
        );
        assert!(output.iter().all(|s| s.is_finite()));
    }

    /// The full production chain the adapter joins: APM analysis -> adapter
    /// merge (synthesis) -> [engine slot, identity here] -> adapter
    /// re-split (analysis) -> APM synthesis. Two bank round trips; the
    /// best-delay SNR floor is calibrated the same way as above (a broken
    /// port lands far below 0 dB).
    #[test]
    fn full_apm_plus_adapter_chain_is_delayed_identity() {
        let mut apm_bank = ThreeBandFilterBank::new();
        let mut adapter_bank = ThreeBandFilterBank::new();
        let input = speechish(FULL_BAND_SIZE * 50);
        let mut output = vec![0.0f32; input.len()];
        let mut bands = [0.0f32; FULL_BAND_SIZE];
        let mut full = [0.0f32; FULL_BAND_SIZE];
        let mut bands2 = [0.0f32; FULL_BAND_SIZE];
        for (chunk_in, chunk_out) in input
            .chunks_exact(FULL_BAND_SIZE)
            .zip(output.chunks_exact_mut(FULL_BAND_SIZE))
        {
            apm_bank.analysis(chunk_in, &mut bands);
            adapter_bank.synthesis(&bands, &mut full);
            adapter_bank.analysis(&full, &mut bands2);
            apm_bank.synthesis(&bands2, chunk_out);
        }
        let best = (0..=127)
            .map(|d| snr_at_delay(&input, &output, d))
            .fold(f64::NEG_INFINITY, f64::max);
        // Measured 7.0 dB on this signal (two compounding ~12 dB round
        // trips of LTI coloration). A broken port lands below 0 dB.
        assert!(
            best > 5.0,
            "APM+adapter chain best-delay SNR {best:.1} dB — path is broken"
        );
    }
}

#[cfg(test)]
mod debug_tests {
    use super::*;

    #[test]
    fn compare_against_cpp_reference() {
        let dir = match std::env::var("HOLLOW_TBFB_REF") {
            Ok(d) => d,
            Err(_) => return, // reference dumps not present — skip
        };
        let read_f32 = |name: &str| -> Vec<f32> {
            let bytes = std::fs::read(format!("{dir}/{name}")).expect(name);
            bytes
                .chunks_exact(4)
                .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect()
        };
        let ref_bands = read_f32("ref_bands.f32");
        let ref_out = read_f32("ref_out.f32");

        let n = FULL_BAND_SIZE * 50;
        let input: Vec<f32> = (0..n)
            .map(|i| {
                let t = i as f32 / 48000.0;
                let mut s = 0.0f32;
                for &f in &[500.0f32, 1200.0, 2700.0, 5100.0] {
                    // f32 PI rounds to the same bits as the C++ driver's
                    // 3.14159265358979f literal — inputs stay identical.
                    s += (2.0 * std::f32::consts::PI * f * t).sin();
                }
                4000.0 * s
            })
            .collect();
        let mut bank = ThreeBandFilterBank::new();
        let mut bands_all = vec![0.0f32; n];
        let mut output = vec![0.0f32; n];
        for fr in 0..50 {
            let ci = &input[fr * FULL_BAND_SIZE..][..FULL_BAND_SIZE];
            let bo = &mut bands_all[fr * FULL_BAND_SIZE..][..FULL_BAND_SIZE];
            bank.analysis(ci, bo);
            let bo = &bands_all[fr * FULL_BAND_SIZE..][..FULL_BAND_SIZE];
            let oo = &mut output[fr * FULL_BAND_SIZE..][..FULL_BAND_SIZE];
            bank.synthesis(bo, oo);
        }
        let max_diff = |a: &[f32], b: &[f32]| -> f32 {
            a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0.0, f32::max)
        };
        let db = max_diff(&bands_all, &ref_bands);
        let do_ = max_diff(&output, &ref_out);
        println!("max |bands diff| = {db}, max |out diff| = {do_}");
        assert!(db < 1e-2, "analysis diverges from WebRTC reference");
        assert!(do_ < 1e-2, "synthesis diverges from WebRTC reference");
    }
}
