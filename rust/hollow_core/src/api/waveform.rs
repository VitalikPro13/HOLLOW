/// A decoded audio file's peak envelope, for drawing its waveform.
pub struct AudioWaveform {
    /// Decoded length, not the container's claim.
    pub duration_secs: f64,
    /// Per bucket, -1..1 normalised to the loudest sample; empty buckets are 0.
    pub min: Vec<f32>,
    pub max: Vec<f32>,
    pub rms: Vec<f32>,
}

/// Decodes [path] into at most [buckets] buckets (fewer for a very short
/// file). Errors are one plain sentence.
pub fn audio_waveform(path: String, buckets: u32) -> Result<AudioWaveform, String> {
    let peaks = crate::audio_peaks::decode_peaks(std::path::Path::new(&path), buckets as usize)?;
    Ok(AudioWaveform {
        duration_secs: peaks.duration_secs,
        min: peaks.min,
        max: peaks.max,
        rms: peaks.rms,
    })
}
