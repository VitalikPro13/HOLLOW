//! Decodes an audio file into a peak envelope for the ringtone trim waveform.

use std::fs::File;
use std::path::Path;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{CODEC_TYPE_NULL, DecoderOptions};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// Frames folded into one fine block while decoding, before the length is
/// known; buckets are built from blocks once it is.
const BLOCK_FRAMES: usize = 256;
/// A ringtone clip is at most 30 s; a file past this is not a ringtone and
/// would hold the decode thread for too long.
const MAX_DECODE_SECS: u64 = 60 * 60;
pub(crate) const MAX_BUCKETS: usize = 8192;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Peaks {
    pub duration_secs: f64,
    /// Per bucket, normalised to the file's loudest sample (so a quiet file
    /// still shows its shape); min <= 0 <= max for any bucket with sound.
    pub min: Vec<f32>,
    pub max: Vec<f32>,
    pub rms: Vec<f32>,
}

#[derive(Default)]
struct Blocks {
    min: Vec<f32>,
    max: Vec<f32>,
    sum_sq: Vec<f64>,
    frames: Vec<u32>,
    total_frames: u64,
}

impl Blocks {
    fn push_frame(&mut self, lo: f32, hi: f32, sq: f64) {
        if self.frames.last().is_none_or(|&n| n as usize >= BLOCK_FRAMES) {
            self.min.push(lo);
            self.max.push(hi);
            self.sum_sq.push(0.0);
            self.frames.push(0);
        }
        let i = self.frames.len() - 1;
        self.min[i] = self.min[i].min(lo);
        self.max[i] = self.max[i].max(hi);
        self.sum_sq[i] += sq;
        self.frames[i] += 1;
        self.total_frames += 1;
    }

    fn push_interleaved(&mut self, samples: &[f32], channels: usize) {
        if channels == 0 {
            return;
        }
        for frame in samples.chunks_exact(channels) {
            let mut lo = f32::MAX;
            let mut hi = f32::MIN;
            let mut sq = 0.0f64;
            for &s in frame {
                let s = if s.is_finite() { s.clamp(-1.0, 1.0) } else { 0.0 };
                lo = lo.min(s);
                hi = hi.max(s);
                sq += f64::from(s) * f64::from(s);
            }
            self.push_frame(lo, hi, sq / channels as f64);
        }
    }

    fn into_peaks(self, sample_rate: u32, buckets: usize) -> Peaks {
        let duration_secs = if sample_rate == 0 {
            0.0
        } else {
            self.total_frames as f64 / f64::from(sample_rate)
        };
        let n_blocks = self.frames.len();
        let n = buckets.clamp(1, MAX_BUCKETS).min(n_blocks);
        let mut out = Peaks {
            duration_secs,
            min: Vec::with_capacity(n),
            max: Vec::with_capacity(n),
            rms: Vec::with_capacity(n),
        };
        for b in 0..n {
            let from = b * n_blocks / n;
            let to = ((b + 1) * n_blocks / n).max(from + 1);
            let mut lo = 0.0f32;
            let mut hi = 0.0f32;
            let mut sq = 0.0f64;
            let mut frames = 0u64;
            for i in from..to {
                lo = lo.min(self.min[i]);
                hi = hi.max(self.max[i]);
                sq += self.sum_sq[i];
                frames += u64::from(self.frames[i]);
            }
            out.min.push(lo);
            out.max.push(hi);
            out.rms.push(if frames == 0 { 0.0 } else { (sq / frames as f64).sqrt() as f32 });
        }
        let peak = out
            .min
            .iter()
            .chain(out.max.iter())
            .fold(0.0f32, |a, v| a.max(v.abs()));
        if peak > 1e-6 {
            let k = 1.0 / peak;
            for v in out.min.iter_mut().chain(out.max.iter_mut()).chain(out.rms.iter_mut()) {
                *v = (*v * k).clamp(-1.0, 1.0);
            }
        }
        out
    }
}

/// Decodes the whole file (the container's length header is not trusted, so
/// a file without one still gets its real duration) into [buckets] buckets.
pub(crate) fn decode_peaks(path: &Path, buckets: usize) -> Result<Peaks, String> {
    let file = File::open(path).map_err(|e| format!("Cannot open the file: {e}"))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| format!("Unsupported audio format: {e}"))?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or("The file has no audio track")?;
    let track_id = track.id;
    let mut sample_rate = track.codec_params.sample_rate.unwrap_or(0);
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| format!("Unsupported audio codec: {e}"))?;

    let mut blocks = Blocks::default();
    let mut buf: Option<SampleBuffer<f32>> = None;
    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymError::IoError(_)) | Err(SymError::ResetRequired) => break,
            Err(e) => return Err(format!("Cannot read the audio: {e}")),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            // One corrupt frame should not cost the whole waveform.
            Err(SymError::DecodeError(_)) => continue,
            Err(SymError::IoError(_)) => break,
            Err(e) => return Err(format!("Cannot decode the audio: {e}")),
        };
        let spec = *decoded.spec();
        if sample_rate == 0 {
            sample_rate = spec.rate;
        }
        let needed = decoded.capacity() as u64;
        if buf.as_ref().is_none_or(|b| (b.capacity() as u64) < needed) {
            buf = Some(SampleBuffer::<f32>::new(needed, spec));
        }
        let sb = buf.as_mut().expect("sample buffer allocated above");
        sb.copy_interleaved_ref(decoded);
        blocks.push_interleaved(sb.samples(), spec.channels.count());
        if sample_rate > 0 && blocks.total_frames > MAX_DECODE_SECS * u64::from(sample_rate) {
            return Err("The file is too long to use as a ringtone".into());
        }
    }
    if blocks.total_frames == 0 || sample_rate == 0 {
        return Err("The file has no audio".into());
    }
    Ok(blocks.into_peaks(sample_rate, buckets))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// PCM16 WAV; [declared_len] overrides the RIFF and data sizes, as a
    /// streamed writer that never learned its length leaves them.
    fn write_wav(path: &Path, rate: u32, channels: u16, samples: &[i16], declared_len: Option<u32>) {
        let data_len = (samples.len() * 2) as u32;
        let (riff, data) = match declared_len {
            Some(v) => (v, v),
            None => (36 + data_len, data_len),
        };
        let mut f = File::create(path).unwrap();
        f.write_all(b"RIFF").unwrap();
        f.write_all(&riff.to_le_bytes()).unwrap();
        f.write_all(b"WAVEfmt ").unwrap();
        f.write_all(&16u32.to_le_bytes()).unwrap();
        f.write_all(&1u16.to_le_bytes()).unwrap();
        f.write_all(&channels.to_le_bytes()).unwrap();
        f.write_all(&rate.to_le_bytes()).unwrap();
        f.write_all(&(rate * u32::from(channels) * 2).to_le_bytes()).unwrap();
        f.write_all(&(channels * 2).to_le_bytes()).unwrap();
        f.write_all(&16u16.to_le_bytes()).unwrap();
        f.write_all(b"data").unwrap();
        f.write_all(&data.to_le_bytes()).unwrap();
        for s in samples {
            f.write_all(&s.to_le_bytes()).unwrap();
        }
    }

    /// 1 s of a quiet tone, 1 s of silence, 1 s of a loud tone (mono).
    fn quiet_silent_loud(rate: u32) -> Vec<i16> {
        let mut out = Vec::new();
        for (amp, secs) in [(0.1f32, 1u32), (0.0, 1), (0.8, 1)] {
            for i in 0..rate * secs {
                let t = i as f32 / rate as f32;
                out.push((amp * (t * 440.0 * std::f32::consts::TAU).sin() * 32767.0) as i16);
            }
        }
        out
    }

    #[test]
    fn wav_gives_real_duration_and_shape() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("tone.wav");
        write_wav(&p, 8000, 1, &quiet_silent_loud(8000), None);
        let peaks = decode_peaks(&p, 30).unwrap();
        assert!((peaks.duration_secs - 3.0).abs() < 0.01, "{}", peaks.duration_secs);
        assert_eq!(peaks.max.len(), 30);
        assert_eq!(peaks.rms.len(), 30);
        // Inner buckets of each second only: a 256-frame block can straddle
        // a boundary.
        let third = |v: &[f32], k: usize| v[k * 10 + 1..(k + 1) * 10 - 1].iter().cloned().fold(0.0f32, f32::max);
        // Normalised to the loudest part, so the loud third reaches the top.
        assert!(third(&peaks.max, 2) > 0.95);
        assert!(third(&peaks.max, 0) > 0.05 && third(&peaks.max, 0) < 0.2);
        assert!(third(&peaks.max, 1) < 0.01, "silence stays flat");
        assert!(peaks.min.iter().all(|&v| v <= 0.0));
        for i in 0..30 {
            assert!(peaks.rms[i] <= peaks.max[i].max(-peaks.min[i]) + 1e-4);
        }
    }

    #[test]
    fn stereo_frames_fold_to_one_envelope() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("stereo.wav");
        // Left loud, right silent: the envelope must not average the left away.
        let mono = quiet_silent_loud(8000);
        let mut interleaved = Vec::new();
        for s in mono {
            interleaved.push(s);
            interleaved.push(0);
        }
        write_wav(&p, 8000, 2, &interleaved, None);
        let peaks = decode_peaks(&p, 30).unwrap();
        assert!((peaks.duration_secs - 3.0).abs() < 0.01);
        assert!(peaks.max.iter().cloned().fold(0.0, f32::max) > 0.95);
    }

    #[test]
    fn a_file_without_a_length_still_gets_its_real_duration() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("streamed.wav");
        write_wav(&p, 8000, 1, &quiet_silent_loud(8000), Some(u32::MAX));
        let peaks = decode_peaks(&p, 64).unwrap();
        assert!((peaks.duration_secs - 3.0).abs() < 0.01, "{}", peaks.duration_secs);
    }

    #[test]
    fn short_files_return_fewer_buckets_than_asked() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("short.wav");
        write_wav(&p, 8000, 1, &vec![1000i16; 1000], None);
        let peaks = decode_peaks(&p, 2048).unwrap();
        assert_eq!(peaks.max.len(), 1000usize.div_ceil(BLOCK_FRAMES));
    }

    #[test]
    fn silence_is_not_normalised_into_noise() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("silent.wav");
        write_wav(&p, 8000, 1, &vec![0i16; 8000], None);
        let peaks = decode_peaks(&p, 16).unwrap();
        assert!(peaks.max.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn missing_and_garbage_files_error() {
        let dir = tempfile::tempdir().unwrap();
        assert!(decode_peaks(&dir.path().join("nope.mp3"), 16).is_err());
        let g = dir.path().join("garbage.mp3");
        std::fs::write(&g, b"not audio at all, just some bytes").unwrap();
        assert!(decode_peaks(&g, 16).is_err());
    }

    /// Real files of other formats: `HOLLOW_WAVEFORM_SAMPLES=<dir> cargo test
    /// --lib audio_peaks -- --ignored --nocapture` decodes every file in it.
    #[test]
    #[ignore]
    fn decodes_sample_dir() {
        let Ok(dir) = std::env::var("HOLLOW_WAVEFORM_SAMPLES") else { return };
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let t = std::time::Instant::now();
            match decode_peaks(&path, 2048) {
                Ok(p) => println!(
                    "{}: {:.2} s, {} buckets, {} ms",
                    path.display(),
                    p.duration_secs,
                    p.max.len(),
                    t.elapsed().as_millis()
                ),
                Err(e) => println!("{}: ERROR {e}", path.display()),
            }
        }
    }
}
