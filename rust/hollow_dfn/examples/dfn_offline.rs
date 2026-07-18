//! Offline DFN3 harness — the Phase-0 go/no-go gate (HOLLOW_PLAN ~2008).
//!
//! Synthesizes speech/noise scenarios with KNOWN ground-truth activity
//! masks, runs them through the standard and low-latency DFN3 models under
//! parameter sweeps, and reports: speech-level delta, noise-gap
//! attenuation, output delay (cross-correlation), spectral deltas, and
//! realtime factor. Writes before/after WAVs for by-ear A/B.
//!
//! Usage:
//!   cargo run --release --example dfn_offline -- \
//!       --ll-model <path/DeepFilterNet3_ll_onnx.tar.gz> \
//!       --out <dir> [--in extra_recording.wav]
//!
//! Real-recording caveat: synthetic scenarios measure the mechanics
//! (suppression, transparency, delay, cost). The QUALITY verdict on real
//! voices comes from processing actual mic captures (--in) and listening.

use hollow_dfn::{Dfn, FRAME};
use rustfft::{num_complex::Complex32, FftPlanner};
use std::path::{Path, PathBuf};
use std::time::Instant;

const SR: usize = 48000;
const FS: f32 = 32768.0;
const DUR_S: usize = 10;

// ---------------------------------------------------------------- signals

/// Deterministic splitmix64 → f32 in [-1, 1).
struct Rng(u64);
impl Rng {
    fn next_f(&mut self) -> f32 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^= z >> 31;
        ((z >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
    }
}

fn gauss_w(f: f32, c: f32, w: f32) -> f32 {
    (-((f - c) * (f - c)) / (2.0 * w * w)).exp()
}

/// Speech-like: 100 Hz harmonic stack with formant weighting, syllabic AM
/// (~4 Hz) inside word bursts with real pauses. Returns (signal, active
/// mask) — the mask is the ground truth for gap/active metrics.
fn synth_speech(len: usize, level_db: f32) -> (Vec<f32>, Vec<bool>) {
    let mut sig = vec![0.0f32; len];
    let mut mask = vec![false; len];
    let f0 = 105.0f32;
    // Word pattern: 700 ms on, 500 ms off, phase-shifted syllables.
    for i in 0..len {
        let t = i as f32 / SR as f32;
        let word = (t % 1.2) < 0.7;
        if !word {
            continue;
        }
        let syll = 0.35 + 0.65 * (0.5 + 0.5 * (2.0 * std::f32::consts::PI * 3.7 * t).sin());
        let vib = 1.0 + 0.01 * (2.0 * std::f32::consts::PI * 5.0 * t).sin();
        let mut s = 0.0f32;
        for h in 1..=40 {
            let f = f0 * vib * h as f32;
            if f > 5500.0 {
                break;
            }
            let rolloff = 1.0 / (h as f32).powf(0.8);
            let formant = 0.35
                + 2.0 * gauss_w(f, 500.0, 160.0)
                + 1.5 * gauss_w(f, 1500.0, 220.0)
                + 1.0 * gauss_w(f, 2500.0, 300.0)
                + 0.4 * gauss_w(f, 3500.0, 400.0);
            s += rolloff * formant * (2.0 * std::f32::consts::PI * f * t).sin();
        }
        sig[i] = s * syll;
        mask[i] = true;
    }
    scale_to_active_rms(&mut sig, &mask, level_db);
    (sig, mask)
}

fn scale_to_active_rms(sig: &mut [f32], mask: &[bool], target_db: f32) {
    let mut sum = 0.0f64;
    let mut n = 0usize;
    for (s, &m) in sig.iter().zip(mask) {
        if m {
            sum += (*s as f64) * (*s as f64);
            n += 1;
        }
    }
    if n == 0 {
        return;
    }
    let rms = (sum / n as f64).sqrt() as f32;
    let target = FS * 10f32.powf(target_db / 20.0);
    let g = target / rms.max(1e-9);
    for s in sig.iter_mut() {
        *s *= g;
    }
}

fn synth_hiss(len: usize, level_db: f32, seed: u64) -> Vec<f32> {
    let mut r = Rng(seed);
    let amp = FS * 10f32.powf(level_db / 20.0);
    (0..len).map(|_| amp * r.next_f() * 1.732).collect()
}

/// Keyboard: sparse 4–6 ms high-frequency transient bursts.
fn synth_keyboard(len: usize, peak_db: f32, seed: u64) -> Vec<f32> {
    let mut r = Rng(seed);
    let mut sig = vec![0.0f32; len];
    let peak = FS * 10f32.powf(peak_db / 20.0);
    let mut i = (0.05 * SR as f32) as usize;
    let mut prev = 0.0f32;
    while i < len {
        let burst = (0.004 * SR as f32) as usize + (r.next_f().abs() * 0.002 * SR as f32) as usize;
        for j in 0..burst.min(len - i) {
            let env = (-(j as f32) / (0.0012 * SR as f32)).exp();
            let w = r.next_f();
            // Differentiate to push energy HF (click character).
            sig[i + j] = peak * env * (w - prev);
            prev = w;
        }
        i += (0.18 * SR as f32) as usize + (r.next_f().abs() * 0.25 * SR as f32) as usize;
    }
    sig
}

/// Fan: heavy low rumble + mild broadband, steady.
fn synth_fan(len: usize, level_db: f32, seed: u64) -> Vec<f32> {
    let mut r = Rng(seed);
    let mut sig = vec![0.0f32; len];
    let mut lp1 = 0.0f32;
    let mut lp2 = 0.0f32;
    let a = 1.0 - (-2.0 * std::f32::consts::PI * 180.0 / SR as f32).exp();
    for s in sig.iter_mut() {
        let w = r.next_f();
        lp1 += a * (w - lp1);
        lp2 += a * (lp1 - lp2);
        *s = lp2 * 6.0 + 0.12 * w;
    }
    let mask = vec![true; len];
    scale_to_active_rms(&mut sig, &mask, level_db);
    sig
}

/// Music bleed: slow triad chords + 2 Hz kick thump.
fn synth_music(len: usize, level_db: f32) -> Vec<f32> {
    let chords: [[f32; 3]; 4] = [
        [220.0, 277.2, 329.6],
        [196.0, 246.9, 293.7],
        [174.6, 220.0, 261.6],
        [246.9, 311.1, 370.0],
    ];
    let mut sig = vec![0.0f32; len];
    for i in 0..len {
        let t = i as f32 / SR as f32;
        let ch = &chords[((t / 1.0) as usize) % 4];
        let mut s = 0.0f32;
        for &f in ch {
            s += (2.0 * std::f32::consts::PI * f * t).sin();
            s += 0.5 * (2.0 * std::f32::consts::PI * f * 2.0 * t).sin();
        }
        // Kick: 2 Hz decaying 60 Hz thump.
        let tk = t % 0.5;
        s += 3.0 * (-tk / 0.06).exp() * (2.0 * std::f32::consts::PI * 60.0 * tk).sin();
        sig[i] = s;
    }
    let mask = vec![true; len];
    scale_to_active_rms(&mut sig, &mask, level_db);
    sig
}

// ---------------------------------------------------------------- metrics

fn rms_db(sig: &[f32], mask: Option<(&[bool], bool)>) -> f32 {
    let mut sum = 0.0f64;
    let mut n = 0usize;
    for (i, s) in sig.iter().enumerate() {
        let keep = match mask {
            None => true,
            Some((m, want)) => i < m.len() && m[i] == want,
        };
        if keep {
            sum += (*s as f64) * (*s as f64);
            n += 1;
        }
    }
    if n == 0 {
        return -160.0;
    }
    20.0 * ((sum / n as f64).sqrt() as f32 / FS).max(1e-8).log10()
}

/// Shrink the mask by `guard` samples on each side of every transition so
/// attack/release edges don't pollute gap measurements.
fn eroded(mask: &[bool], guard: usize) -> Vec<bool> {
    let n = mask.len();
    let mut out = mask.to_vec();
    for i in 0..n {
        if mask[i] {
            continue;
        }
        // i is a gap sample; erode if near an active sample.
        let lo = i.saturating_sub(guard);
        let hi = (i + guard).min(n - 1);
        if mask[lo..=hi].iter().any(|&m| m) {
            out[i] = true; // exclude from "gap" by marking active
        }
    }
    out
}

/// Output lag vs input by cross-correlation (0..=max_lag samples).
fn xcorr_delay(input: &[f32], output: &[f32], max_lag: usize) -> usize {
    let n = input.len().min(output.len());
    let mut best = (0usize, f64::MIN);
    for lag in 0..=max_lag {
        let mut acc = 0.0f64;
        let mut i = 0;
        while i + lag < n {
            acc += input[i] as f64 * output[i + lag] as f64;
            i += 7; // stride — plenty of samples, 7 is coprime with periods
        }
        if acc > best.1 {
            best = (lag, acc);
        }
    }
    best.0
}

/// Mean band energy (dB) over the signal via 4096-pt FFT frames.
fn band_db(sig: &[f32], lo_hz: f32, hi_hz: f32, planner: &mut FftPlanner<f32>) -> f32 {
    const N: usize = 4096;
    let fft = planner.plan_fft_forward(N);
    let mut acc = 0.0f64;
    let mut frames = 0usize;
    let mut buf = vec![Complex32::new(0.0, 0.0); N];
    let mut pos = 0usize;
    while pos + N <= sig.len() {
        for (j, b) in buf.iter_mut().enumerate() {
            // Hann
            let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * j as f32 / N as f32).cos();
            *b = Complex32::new(sig[pos + j] / FS * w, 0.0);
        }
        fft.process(&mut buf);
        let lo = (lo_hz * N as f32 / SR as f32) as usize;
        let hi = ((hi_hz * N as f32 / SR as f32) as usize).min(N / 2);
        let mut e = 0.0f64;
        for b in &buf[lo..hi] {
            e += (b.norm_sqr()) as f64;
        }
        acc += e;
        frames += 1;
        pos += N / 2;
    }
    if frames == 0 {
        return -160.0;
    }
    10.0 * ((acc / frames as f64).max(1e-16)).log10() as f32
}

// ---------------------------------------------------------------- driver

struct RunResult {
    act_delta_db: f32,
    gap_in_db: f32,
    gap_out_db: f32,
    delay_ms: f32,
    rtf: f64,
    ms_per_frame: f64,
}

fn run_model(
    dfn: &mut Dfn,
    input: &[f32],
    mask: &[bool],
) -> (Vec<f32>, RunResult) {
    let mut out = Vec::with_capacity(input.len());
    let mut frame = [0.0f32; FRAME];
    let t0 = Instant::now();
    let mut spent = 0.0f64;
    for chunk in input.chunks(FRAME) {
        if chunk.len() < FRAME {
            break;
        }
        frame.copy_from_slice(chunk);
        let tf = Instant::now();
        dfn.process_480(&mut frame).expect("process");
        spent += tf.elapsed().as_secs_f64();
        out.extend_from_slice(&frame);
    }
    let _wall = t0.elapsed();
    let audio_s = out.len() as f64 / SR as f64;

    let delay = xcorr_delay(input, &out, 4800);
    // Delay-compensate: shift output left so masks line up.
    let comp: Vec<f32> = out[delay.min(out.len())..].to_vec();
    let g = eroded(mask, (0.05 * SR as f32) as usize);
    let act_in = rms_db(input, Some((mask, true)));
    let act_out = rms_db(&comp, Some((mask, true)));
    let gap_in = rms_db(input, Some((&g, false)));
    let gap_out = rms_db(&comp, Some((&g, false)));

    (
        out,
        RunResult {
            act_delta_db: act_out - act_in,
            gap_in_db: gap_in,
            gap_out_db: gap_out,
            delay_ms: delay as f32 * 1000.0 / SR as f32,
            rtf: spent / audio_s,
            ms_per_frame: spent * 1000.0 / (audio_s * 100.0),
        },
    )
}

fn write_wav(path: &Path, sig: &[f32]) {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: SR as u32,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).expect("wav create");
    for &s in sig {
        w.write_sample(s.clamp(-32767.0, 32767.0) as i16).expect("wav write");
    }
    w.finalize().expect("wav finalize");
}

fn mix(a: &[f32], b: &[f32]) -> Vec<f32> {
    a.iter().zip(b).map(|(x, y)| x + y).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let get = |flag: &str| -> Option<String> {
        args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
    };
    let out_dir = PathBuf::from(get("--out").unwrap_or_else(|| "dfn_out".into()));
    std::fs::create_dir_all(&out_dir).expect("out dir");
    let ll_path = get("--ll-model");
    let extra_in = get("--in");

    let len = SR * DUR_S;
    let (speech, mask) = synth_speech(len, -26.0);
    let all_on = vec![true; len];
    let all_off = vec![false; len];

    // (name, signal, activity mask)
    let scenarios: Vec<(&str, Vec<f32>, &[bool])> = vec![
        ("clean_speech", speech.clone(), &mask),
        ("speech_hiss55", mix(&speech, &synth_hiss(len, -55.0, 7)), &mask),
        ("speech_hiss45", mix(&speech, &synth_hiss(len, -45.0, 11)), &mask),
        ("speech_keyboard", mix(&speech, &synth_keyboard(len, -22.0, 13)), &mask),
        ("speech_fan", mix(&speech, &synth_fan(len, -42.0, 17)), &mask),
        ("speech_music", mix(&speech, &synth_music(len, -38.0)), &mask),
        ("noise_only_keyboard", synth_keyboard(len, -22.0, 13), &all_off),
        ("noise_only_fan", synth_fan(len, -42.0, 17), &all_off),
        ("tone_1k_-30", {
            let mut v: Vec<f32> = (0..len)
                .map(|i| {
                    FS * 10f32.powf(-30.0 / 20.0)
                        * (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / SR as f32).sin()
                })
                .collect();
            let m = vec![true; len];
            scale_to_active_rms(&mut v, &m, -30.0);
            v
        }, &all_on),
    ];

    let mut planner = FftPlanner::<f32>::new();

    // Models: (label, constructor)
    let mut models: Vec<(String, Dfn)> = vec![("std".into(), Dfn::new().expect("std model"))];
    if let Some(p) = &ll_path {
        let bytes: &'static [u8] =
            Box::leak(std::fs::read(p).expect("read ll model").into_boxed_slice());
        models.push(("ll".into(), Dfn::from_model_bytes(bytes).expect("ll model")));
    }

    println!(
        "{:<22} {:<14} {:>8} {:>9} {:>9} {:>8} {:>7} {:>9}",
        "scenario", "model/config", "actΔdB", "gapIn", "gapOut", "gapΔdB", "delay", "RTF"
    );

    for (name, sig, m) in &scenarios {
        for (label, dfn) in models.iter_mut() {
            // Fresh state per run: recreate would re-optimize the graph
            // (slow); instead flush with 2 s of silence — the model's
            // temporal context is ~1 s.
            let mut silence = [0.0f32; FRAME];
            for _ in 0..200 {
                let _ = dfn.process_480(&mut silence);
                silence = [0.0f32; FRAME];
            }
            let (out, r) = run_model(dfn, sig, m);
            println!(
                "{:<22} {:<14} {:>8.2} {:>9.1} {:>9.1} {:>8.1} {:>6.1}ms {:>9.3}",
                name,
                label,
                r.act_delta_db,
                r.gap_in_db,
                r.gap_out_db,
                r.gap_out_db - r.gap_in_db,
                r.delay_ms,
                r.rtf
            );
            let _ = r.ms_per_frame;
            write_wav(&out_dir.join(format!("{name}_in.wav")), sig);
            write_wav(&out_dir.join(format!("{name}_{label}.wav")), &out);

            // Spectral check on clean speech: how much does the model
            // reshape SPEECH when there is no noise to remove?
            if *name == "clean_speech" {
                let b1i = band_db(sig, 300.0, 4000.0, &mut planner);
                let b1o = band_db(&out, 300.0, 4000.0, &mut planner);
                let b2i = band_db(sig, 4000.0, 8000.0, &mut planner);
                let b2o = band_db(&out, 4000.0, 8000.0, &mut planner);
                println!(
                    "    [{label}] clean-speech spectral delta: 300-4k {:+.2} dB, 4-8k {:+.2} dB",
                    b1o - b1i,
                    b2o - b2i
                );
            }
        }
    }

    // ---- parameter sweeps on the harshest realistic mix (speech+hiss45)
    println!("\n--- atten_lim / post-filter sweep (speech_hiss45, std model) ---");
    let (_, sig, m) = &scenarios[2];
    for (cfg, lim, beta) in [
        ("att100_pf0", 100.0f32, 0.0f32),
        ("att24_pf0", 24.0, 0.0),
        ("att12_pf0", 12.0, 0.0),
        ("att100_pf02", 100.0, 0.02),
    ] {
        let (label, dfn) = &mut models[0];
        let _ = label;
        dfn.set_atten_lim(lim);
        dfn.set_post_filter_beta(beta);
        let mut silence = [0.0f32; FRAME];
        for _ in 0..200 {
            let _ = dfn.process_480(&mut silence);
            silence = [0.0f32; FRAME];
        }
        let (out, r) = run_model(dfn, sig, m);
        println!(
            "{:<22} {:<14} {:>8.2} {:>9.1} {:>9.1} {:>8.1} {:>6.1}ms {:>9.3}",
            "speech_hiss45", cfg, r.act_delta_db, r.gap_in_db, r.gap_out_db,
            r.gap_out_db - r.gap_in_db, r.delay_ms, r.rtf
        );
        write_wav(&out_dir.join(format!("sweep_{cfg}.wav")), &out);
    }
    // Reset to defaults for anyone extending below.
    models[0].1.set_atten_lim(100.0);
    models[0].1.set_post_filter_beta(0.0);

    // ---- optional real recording pass-through (mono/stereo, any rate=48k)
    if let Some(p) = extra_in {
        let mut reader = hound::WavReader::open(&p).expect("open --in wav");
        let spec = reader.spec();
        assert_eq!(spec.sample_rate, SR as u32, "--in must be 48 kHz");
        let raw: Vec<f32> = match spec.sample_format {
            hound::SampleFormat::Int => reader
                .samples::<i16>()
                .step_by(spec.channels as usize)
                .map(|s| s.unwrap() as f32)
                .collect(),
            hound::SampleFormat::Float => reader
                .samples::<f32>()
                .step_by(spec.channels as usize)
                .map(|s| s.unwrap() * FS)
                .collect(),
        };
        // Energy-based activity mask (no ground truth for real recordings):
        // per-10ms-frame RMS, threshold at the geometric midpoint between
        // the 15th and 85th percentile frame levels — below = noise gap,
        // above = speech. Good enough to measure gap attenuation vs speech
        // preservation separately.
        let nfr = raw.len() / FRAME;
        let mut frame_db: Vec<f32> = (0..nfr)
            .map(|f| rms_db(&raw[f * FRAME..(f + 1) * FRAME], None))
            .collect();
        let mut sorted = frame_db.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let lo = sorted[(nfr as f32 * 0.15) as usize];
        let hi = sorted[(nfr as f32 * 0.85) as usize];
        let thresh = (lo + hi) * 0.5;
        let mut mask = vec![false; raw.len()];
        for (f, &db) in frame_db.iter().enumerate() {
            if db > thresh {
                for i in f * FRAME..(f + 1) * FRAME {
                    mask[i] = true;
                }
            }
        }
        frame_db.clear();
        println!(
            "\nreal input activity split: floor ~{lo:.1} dBFS, speech ~{hi:.1} dBFS, threshold {thresh:.1}"
        );
        for (label, dfn) in models.iter_mut() {
            let mut silence = [0.0f32; FRAME];
            for _ in 0..200 {
                let _ = dfn.process_480(&mut silence);
                silence = [0.0f32; FRAME];
            }
            let (out, r) = run_model(dfn, &raw, &mask);
            println!(
                "real input [{}]: speech Δ {:+.2} dB | gaps {:.1} -> {:.1} dBFS ({:+.1} dB) | delay {:.1} ms | RTF {:.3}",
                label,
                r.act_delta_db,
                r.gap_in_db,
                r.gap_out_db,
                r.gap_out_db - r.gap_in_db,
                r.delay_ms,
                r.rtf
            );
            let stem = Path::new(&p).file_stem().unwrap().to_string_lossy();
            write_wav(&out_dir.join(format!("real_{stem}_{label}.wav")), &out);
        }

        // Noisy-twin demo: the SAME voice + synthetic keyboard/fan/hiss —
        // what DFN does for a user in a NOISY room. A quiet-room recording
        // has nothing to remove in the gaps (measured floor ~-80 dBFS);
        // this is the honest showcase of the feature's value.
        let noisy: Vec<f32> = {
            let kb = synth_keyboard(raw.len(), -24.0, 13);
            let fan = synth_fan(raw.len(), -45.0, 17);
            let hiss = synth_hiss(raw.len(), -55.0, 7);
            (0..raw.len())
                .map(|i| raw[i] + kb[i] + fan[i] + hiss[i])
                .collect()
        };
        let (label, dfn) = &mut models[0];
        let _ = label;
        let mut silence = [0.0f32; FRAME];
        for _ in 0..200 {
            let _ = dfn.process_480(&mut silence);
            silence = [0.0f32; FRAME];
        }
        let (out, r) = run_model(dfn, &noisy, &mask);
        println!(
            "noisy twin [std]: speech Δ {:+.2} dB | gaps {:.1} -> {:.1} dBFS ({:+.1} dB) | delay {:.1} ms",
            r.act_delta_db, r.gap_in_db, r.gap_out_db,
            r.gap_out_db - r.gap_in_db, r.delay_ms
        );
        let stem = Path::new(&p).file_stem().unwrap().to_string_lossy();
        write_wav(&out_dir.join(format!("real_{stem}_noisy_in.wav")), &noisy);
        write_wav(&out_dir.join(format!("real_{stem}_noisy_std.wav")), &out);
    }

    println!("\nWAVs written to {}", out_dir.display());
}
