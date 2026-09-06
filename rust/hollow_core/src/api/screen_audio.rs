//! Screen-share audio Opus codec (mobile receive + send paths).
//!
//! Desktop codes share audio in an out-of-process exe; a phone cannot spawn one, so it
//! codes here in pure Rust. Decoded PCM plays through a native sink OUTSIDE the WebRTC
//! voice path, so the call's AEC/AGC cannot mangle music. The parameters MUST match
//! that exe exactly (48 kHz stereo s16, OPUS_APPLICATION_AUDIO, 128 kbps, 480-sample
//! frames), wire packets are `[seq:4 LE][opus]`, and one global codec state per
//! direction is enough. Opus is STATEFUL, so each is reset on session start.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::sync::OnceLock;

const SAMPLE_RATE: i32 = 48_000;
const CHANNELS: i32 = 2;
// Max samples PER CHANNEL Opus can emit in one packet (120 ms @ 48 kHz); the
// output buffer is this * CHANNELS.
const MAX_FRAME_PER_CHANNEL: usize = 5760;

// Playback gain (mobile receive path): share audio is mastered content while the voice
// chain converges near −16 LUFS, so unity playback drowns the call. Dart drives the
// target and the decoder ramps fast-down / slow-up, the identical envelope the desktop
// render exe applies.

/// Default −6 dB: the calibrated trim that puts typical mastered content just
/// under the voice chain's −16 LUFS target. Matches the Dart slider's 100%.
const GAIN_DEFAULT: f32 = 0.5;
/// Per-frame-pair smoothing coefficients (48 kHz): τ≈30 ms toward a LOWER target
/// (duck attack), τ≈300 ms toward a HIGHER one (release). One step per stereo pair.
const GAIN_COEF_DOWN: f32 = 1.0 / (0.030 * 48_000.0);
const GAIN_COEF_UP: f32 = 1.0 / (0.300 * 48_000.0);

/// Target playback gain, f32 bits in an atomic (lock-free from the FFI).
static GAIN_TARGET: AtomicU32 = AtomicU32::new(f32::to_bits(GAIN_DEFAULT));

fn gain_target() -> f32 {
    f32::from_bits(GAIN_TARGET.load(Ordering::Relaxed))
}

/// Set the screen-audio playback gain target (0.0..=1.0). The decoder ramps toward
/// it over the next `decode_screen_audio` calls, so changes are click-free.
pub fn set_screen_audio_gain(gain: f32) {
    let clamped = gain.clamp(0.0, 1.0);
    GAIN_TARGET.store(clamped.to_bits(), Ordering::Relaxed);
}

/// Owns the raw `unsafe-libopus` decoder pointer and frees it on drop.
struct ScreenAudioDecoder {
    ptr: *mut unsafe_libopus::OpusDecoder,
    /// Smoothed playback gain, ramping toward [`GAIN_TARGET`].
    gain: f32,
}

// The raw pointer is only ever touched while holding the global Mutex, and libopus
// decoder state is self-contained, so Send is sound.
unsafe impl Send for ScreenAudioDecoder {}

impl ScreenAudioDecoder {
    fn new() -> Result<Self, String> {
        let mut err: i32 = 0;
        // SAFETY: standard libopus create; we check the returned error/null.
        let ptr = unsafe { unsafe_libopus::opus_decoder_create(SAMPLE_RATE, CHANNELS, &mut err) };
        if err != 0 || ptr.is_null() {
            return Err(format!("opus_decoder_create failed (code {err})"));
        }
        // Start AT the target — a session must not fade in from a stale level.
        Ok(Self {
            ptr,
            gain: gain_target(),
        })
    }

    /// Decode one Opus packet into interleaved int16 PCM. Returns the number of
    /// samples PER CHANNEL decoded (negative is an Opus error code).
    fn decode(&self, opus: &[u8], out: &mut [i16]) -> i32 {
        // SAFETY: `out` is sized MAX_FRAME_PER_CHANNEL * CHANNELS; libopus
        // writes at most `frame_size` (per channel) * channels samples.
        unsafe {
            unsafe_libopus::opus_decode(
                self.ptr,
                opus.as_ptr(),
                opus.len() as i32,
                out.as_mut_ptr(),
                MAX_FRAME_PER_CHANNEL as i32,
                0, // no FEC
            )
        }
    }
}

impl Drop for ScreenAudioDecoder {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            // SAFETY: ptr came from opus_decoder_create and is freed once.
            unsafe { unsafe_libopus::opus_decoder_destroy(self.ptr) };
            self.ptr = std::ptr::null_mut();
        }
    }
}

fn decoder() -> &'static Mutex<Option<ScreenAudioDecoder>> {
    static DECODER: OnceLock<Mutex<Option<ScreenAudioDecoder>>> = OnceLock::new();
    DECODER.get_or_init(|| Mutex::new(None))
}

/// (Re)initialize the screen-audio decoder, clearing inter-packet state left by a
/// previous share session.
pub fn reset_screen_audio_decoder() -> Result<(), String> {
    let mut guard = decoder().lock().map_err(|e| e.to_string())?;
    *guard = Some(ScreenAudioDecoder::new()?);
    Ok(())
}

/// Decode one bare Opus packet (seq already stripped by Dart) into interleaved
/// s16le stereo PCM at 48 kHz. Empty input returns an empty `Vec`; the decoder is
/// created lazily if [`reset_screen_audio_decoder`] was not called first.
pub fn decode_screen_audio(opus: Vec<u8>) -> Result<Vec<u8>, String> {
    if opus.is_empty() {
        return Ok(Vec::new());
    }

    let mut guard = decoder().lock().map_err(|e| e.to_string())?;
    if guard.is_none() {
        *guard = Some(ScreenAudioDecoder::new()?);
    }
    let dec = guard.as_mut().expect("decoder just set");

    let mut pcm = vec![0i16; MAX_FRAME_PER_CHANNEL * CHANNELS as usize];
    let samples_per_channel = dec.decode(&opus, &mut pcm);
    if samples_per_channel < 0 {
        return Err(format!("opus_decode error {samples_per_channel}"));
    }

    let total = samples_per_channel as usize * CHANNELS as usize;
    let target = gain_target();
    let mut g = dec.gain;
    let mut bytes = Vec::with_capacity(total * 2);
    let mut i = 0;
    while i < total {
        let coef = if target < g { GAIN_COEF_DOWN } else { GAIN_COEF_UP };
        g += (target - g) * coef;
        for ch in 0..CHANNELS as usize {
            let s = (f32::from(pcm[i + ch]) * g)
                .round()
                .clamp(f32::from(i16::MIN), f32::from(i16::MAX)) as i16;
            bytes.extend_from_slice(&s.to_le_bytes());
        }
        i += CHANNELS as usize;
    }
    dec.gain = g;
    Ok(bytes)
}

// Encode (mobile send path).

// 10 ms @ 48 kHz, matching the desktop exe's `--mode encode` kFrameSamples.
const ENCODE_FRAME_PER_CHANNEL: usize = 480;
const ENCODE_FRAME_BYTES: usize = ENCODE_FRAME_PER_CHANNEL * CHANNELS as usize * 2;
// libopus recommends >= 4000 bytes for the output packet buffer.
const ENCODE_MAX_PACKET: usize = 4000;
const ENCODE_BITRATE: i32 = 128_000;
// Complexity 5, NOT the desktop exe's 10: this runs on a PHONE that is also
// hardware-encoding the video and carrying the call, where complexity 10 encodes
// music slower than realtime and the backlog drops chunks. At 128 kbps stereo the
// quality delta is marginal, the realtime headroom is not.
const ENCODE_COMPLEXITY: i32 = 5;
// Cap the residual PCM backlog (~0.5 s): if Dart stalls we drop the OLDEST audio,
// because for realtime audio a glitch beats unbounded latency growth.
const ENCODE_MAX_BUFFER_BYTES: usize = ENCODE_FRAME_BYTES * 50;

/// Owns the raw encoder pointer, the PCM residual buffer and the wire seq counter.
struct ScreenAudioEncoder {
    ptr: *mut unsafe_libopus::OpusEncoder,
    pending: Vec<u8>,
    seq: u32,
}

// Same argument as the decoder: the pointer is only touched under the global Mutex.
unsafe impl Send for ScreenAudioEncoder {}

impl ScreenAudioEncoder {
    fn new() -> Result<Self, String> {
        let mut err: i32 = 0;
        // SAFETY: standard libopus create; we check the returned error/null.
        let ptr = unsafe {
            unsafe_libopus::opus_encoder_create(
                SAMPLE_RATE,
                CHANNELS,
                unsafe_libopus::OPUS_APPLICATION_AUDIO,
                &mut err,
            )
        };
        if err != 0 || ptr.is_null() {
            return Err(format!("opus_encoder_create failed (code {err})"));
        }
        // SAFETY: valid encoder; ctl requests match the desktop exe's settings.
        unsafe {
            unsafe_libopus::opus_encoder_ctl_impl(
                ptr,
                unsafe_libopus::OPUS_SET_BITRATE_REQUEST,
                unsafe_libopus::varargs!(ENCODE_BITRATE),
            );
            unsafe_libopus::opus_encoder_ctl_impl(
                ptr,
                unsafe_libopus::OPUS_SET_COMPLEXITY_REQUEST,
                unsafe_libopus::varargs!(ENCODE_COMPLEXITY),
            );
        }
        Ok(Self {
            ptr,
            pending: Vec::with_capacity(ENCODE_MAX_BUFFER_BYTES),
            seq: 0,
        })
    }

    /// Encode one 480-sample-per-channel frame; negative is an Opus error code.
    fn encode(&self, frame: &[i16], out: &mut [u8]) -> i32 {
        // SAFETY: `frame` holds exactly ENCODE_FRAME_PER_CHANNEL * CHANNELS
        // samples; `out` is ENCODE_MAX_PACKET bytes.
        unsafe {
            unsafe_libopus::opus_encode(
                self.ptr,
                frame.as_ptr(),
                ENCODE_FRAME_PER_CHANNEL as i32,
                out.as_mut_ptr(),
                out.len() as i32,
            )
        }
    }
}

impl Drop for ScreenAudioEncoder {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            // SAFETY: ptr came from opus_encoder_create and is freed once.
            unsafe { unsafe_libopus::opus_encoder_destroy(self.ptr) };
            self.ptr = std::ptr::null_mut();
        }
    }
}

fn encoder() -> &'static Mutex<Option<ScreenAudioEncoder>> {
    static ENCODER: OnceLock<Mutex<Option<ScreenAudioEncoder>>> = OnceLock::new();
    ENCODER.get_or_init(|| Mutex::new(None))
}

/// (Re)initialize the screen-audio encoder: clears prediction state, the PCM
/// residual and the wire seq, which the desktop exe also starts at 0.
pub fn reset_screen_audio_encoder() -> Result<(), String> {
    let mut guard = encoder().lock().map_err(|e| e.to_string())?;
    *guard = Some(ScreenAudioEncoder::new()?);
    Ok(())
}

/// Drop the encoder when share-audio capture stops; the next start recreates it.
pub fn stop_screen_audio_encoder() {
    if let Ok(mut guard) = encoder().lock() {
        *guard = None;
    }
}

/// Feed interleaved 48 kHz stereo s16le PCM of any length (capture callbacks are not
/// frame-aligned) and get back COMPLETE `[seq:4 LE][opus]` wire packets. Leftover PCM
/// stays buffered; the encoder is created lazily.
pub fn encode_screen_audio(pcm: Vec<u8>) -> Result<Vec<Vec<u8>>, String> {
    if pcm.is_empty() {
        return Ok(Vec::new());
    }

    let mut guard = encoder().lock().map_err(|e| e.to_string())?;
    if guard.is_none() {
        *guard = Some(ScreenAudioEncoder::new()?);
    }
    let enc = guard.as_mut().expect("encoder just set");

    enc.pending.extend_from_slice(&pcm);
    if enc.pending.len() > ENCODE_MAX_BUFFER_BYTES {
        // Keep frame alignment when dropping the oldest overflow.
        let mut excess = enc.pending.len() - ENCODE_MAX_BUFFER_BYTES;
        excess = excess.div_ceil(ENCODE_FRAME_BYTES) * ENCODE_FRAME_BYTES;
        excess = excess.min(enc.pending.len());
        enc.pending.drain(..excess);
    }

    let mut packets = Vec::new();
    let mut frame = [0i16; ENCODE_FRAME_PER_CHANNEL * CHANNELS as usize];
    let mut out = [0u8; ENCODE_MAX_PACKET];
    let mut consumed = 0;
    while enc.pending.len() - consumed >= ENCODE_FRAME_BYTES {
        let chunk = &enc.pending[consumed..consumed + ENCODE_FRAME_BYTES];
        for (i, s) in frame.iter_mut().enumerate() {
            *s = i16::from_le_bytes([chunk[i * 2], chunk[i * 2 + 1]]);
        }
        consumed += ENCODE_FRAME_BYTES;

        let n = enc.encode(&frame, &mut out);
        if n < 0 {
            enc.pending.drain(..consumed);
            return Err(format!("opus_encode error {n}"));
        }
        // 1-2 byte DTX-style packets are valid and the desktop render path accepts them.
        let mut packet = Vec::with_capacity(4 + n as usize);
        packet.extend_from_slice(&enc.seq.to_le_bytes());
        packet.extend_from_slice(&out[..n as usize]);
        enc.seq = enc.seq.wrapping_add(1);
        packets.push(packet);
    }
    enc.pending.drain(..consumed);

    Ok(packets)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The codec state and gain target are process-global, so these tests serialize.
    fn test_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: Mutex<()> = Mutex::new(());
        LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// 100 ms of a 440 Hz sine encoded to seq-prefixed wire packets.
    fn encode_test_sine() -> Vec<Vec<u8>> {
        reset_screen_audio_encoder().unwrap();
        let frames = 4800usize;
        let mut pcm = Vec::with_capacity(frames * 4);
        for i in 0..frames {
            let s = ((i as f32 * 440.0 * std::f32::consts::TAU / 48_000.0).sin() * 12_000.0) as i16;
            pcm.extend_from_slice(&s.to_le_bytes());
            pcm.extend_from_slice(&s.to_le_bytes());
        }
        // Feed in uneven chunks — native capture callbacks aren't frame-aligned.
        let mut packets = Vec::new();
        for chunk in pcm.chunks(1000) {
            packets.extend(encode_screen_audio(chunk.to_vec()).unwrap());
        }
        packets
    }

    fn max_abs(pcm_bytes: &[u8]) -> i32 {
        pcm_bytes
            .chunks_exact(2)
            .map(|b| i32::from(i16::from_le_bytes([b[0], b[1]])).abs())
            .max()
            .unwrap_or(0)
    }

    /// Mobile send-path smoke test: uneven PCM chunks in, seq-prefixed packets out,
    /// decoded back at the right frame size, so both directions speak one format.
    #[test]
    fn encode_decode_roundtrip() {
        let _guard = test_lock();
        let packets = encode_test_sine();
        reset_screen_audio_decoder().unwrap();

        // 100 ms = 10 complete 10 ms frames (residual < 1 frame stays buffered).
        assert!(packets.len() >= 9, "expected >=9 packets, got {}", packets.len());

        for (i, packet) in packets.iter().enumerate() {
            assert!(packet.len() > 4, "packet {i} too short");
            let seq = u32::from_le_bytes(packet[..4].try_into().unwrap());
            assert_eq!(seq, i as u32, "wire seq must be contiguous from 0");
            let out = decode_screen_audio(packet[4..].to_vec()).unwrap();
            assert_eq!(out.len(), 480 * 2 * 2, "decoded frame size mismatch");
        }

        stop_screen_audio_encoder();
    }

    /// A decoder created at a target scales exactly, and a mid-stream change RAMPS.
    #[test]
    fn playback_gain_scales_and_ramps() {
        let _guard = test_lock();
        let packets = encode_test_sine();
        assert!(packets.len() >= 9);

        // Fresh decoders produce identical PCM, so the two runs differ only by gain.
        set_screen_audio_gain(1.0);
        reset_screen_audio_decoder().unwrap();
        let mut unity_last = 0i32;
        for packet in &packets {
            unity_last = max_abs(&decode_screen_audio(packet[4..].to_vec()).unwrap());
        }
        assert!(unity_last > 8_000, "sine should decode loud, got {unity_last}");

        set_screen_audio_gain(0.25);
        reset_screen_audio_decoder().unwrap();
        let mut quarter_last = 0i32;
        for packet in &packets {
            quarter_last = max_abs(&decode_screen_audio(packet[4..].to_vec()).unwrap());
        }
        let expect = unity_last / 4;
        assert!(
            (quarter_last - expect).abs() <= expect / 20 + 2,
            "quarter gain should scale ~0.25x: unity {unity_last}, quarter {quarter_last}"
        );

        // Mid-stream duck to 0 must RAMP: the next packet is not yet silent, but
        // ~300 ms later it is (τ≈30 ms down).
        set_screen_audio_gain(1.0);
        reset_screen_audio_decoder().unwrap();
        let _ = decode_screen_audio(packets[0][4..].to_vec()).unwrap();
        set_screen_audio_gain(0.0);
        let first = max_abs(&decode_screen_audio(packets[1][4..].to_vec()).unwrap());
        assert!(first > 500, "duck must ramp, not step to silence: {first}");
        let mut last = first;
        for packet in packets.iter().cycle().skip(2).take(30) {
            last = max_abs(&decode_screen_audio(packet[4..].to_vec()).unwrap());
        }
        assert!(last < 50, "after ~300 ms the duck should be settled: {last}");

        set_screen_audio_gain(GAIN_DEFAULT);
        stop_screen_audio_encoder();
    }
}
