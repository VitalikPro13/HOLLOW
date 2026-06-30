//! Screen-share audio Opus decoder (mobile receive path).
//!
//! On desktop, received screen-share audio (data-channel `0x03` frames) is
//! decoded + played by an out-of-process `screen_audio_capturer --mode render`
//! exe. Mobile can't spawn a child process, so the phone decodes here in Rust
//! (pure-Rust `unsafe-libopus` — no C toolchain / NDK) and hands raw PCM to a
//! native `AudioTrack` (Android) / `AVAudioEngine` (iOS) sink that plays it
//! OUTSIDE the WebRTC voice path (so the call's AEC/AGC can't mangle music).
//!
//! The Opus parameters MUST match the senders exactly (see the desktop
//! `OpusDecoderWrapper` and `main.cpp` encode/render modes):
//!   * 48 kHz, 2 channels (stereo), interleaved signed 16-bit PCM.
//!
//! The data-channel payload handed to Dart's `onScreenAudioReceived` is
//! `[seq:4 LE][opus_bytes...]`. Dart strips the 4-byte seq before calling
//! [`decode_screen_audio`], so this module receives the bare Opus packet.
//!
//! A single global decoder is fine: only one shared-audio stream plays at a
//! time. The decoder is STATEFUL (Opus keeps inter-packet prediction state),
//! so it is reset on each player start via [`reset_screen_audio_decoder`].

use std::sync::Mutex;
use std::sync::OnceLock;

const SAMPLE_RATE: i32 = 48_000;
const CHANNELS: i32 = 2;
// Max samples PER CHANNEL Opus can emit in one packet: 120 ms @ 48 kHz.
// Matches the desktop wrapper's 5760 cap. Output buffer is this * CHANNELS.
const MAX_FRAME_PER_CHANNEL: usize = 5760;

/// Owns the raw `unsafe-libopus` decoder pointer and frees it on drop.
struct ScreenAudioDecoder {
    ptr: *mut unsafe_libopus::OpusDecoder,
}

// The raw pointer is only ever touched while holding the global Mutex, so the
// decoder is effectively single-threaded. Assert Send so it can live in the
// static Mutex (libopus decoder state is self-contained, no shared globals).
unsafe impl Send for ScreenAudioDecoder {}

impl ScreenAudioDecoder {
    fn new() -> Result<Self, String> {
        let mut err: i32 = 0;
        // SAFETY: standard libopus create; we check the returned error/null.
        let ptr = unsafe { unsafe_libopus::opus_decoder_create(SAMPLE_RATE, CHANNELS, &mut err) };
        if err != 0 || ptr.is_null() {
            return Err(format!("opus_decoder_create failed (code {err})"));
        }
        Ok(Self { ptr })
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

/// (Re)initialize the screen-audio decoder. Called when a mobile player starts,
/// to clear any inter-packet state left over from a previous share session.
pub fn reset_screen_audio_decoder() -> Result<(), String> {
    let mut guard = decoder().lock().map_err(|e| e.to_string())?;
    *guard = Some(ScreenAudioDecoder::new()?);
    Ok(())
}

/// Decode one bare Opus packet (seq already stripped by Dart) into interleaved
/// signed-16-bit little-endian stereo PCM at 48 kHz, ready to feed a native
/// audio sink. Returns an empty `Vec` for an empty input. Lazily creates the
/// decoder if [`reset_screen_audio_decoder`] wasn't called first.
pub fn decode_screen_audio(opus: Vec<u8>) -> Result<Vec<u8>, String> {
    if opus.is_empty() {
        return Ok(Vec::new());
    }

    let mut guard = decoder().lock().map_err(|e| e.to_string())?;
    if guard.is_none() {
        *guard = Some(ScreenAudioDecoder::new()?);
    }
    let dec = guard.as_ref().expect("decoder just set");

    let mut pcm = vec![0i16; MAX_FRAME_PER_CHANNEL * CHANNELS as usize];
    let samples_per_channel = dec.decode(&opus, &mut pcm);
    if samples_per_channel < 0 {
        return Err(format!("opus_decode error {samples_per_channel}"));
    }

    let total = samples_per_channel as usize * CHANNELS as usize;
    // Pack int16 -> bytes (little-endian) for the platform channel.
    let mut bytes = Vec::with_capacity(total * 2);
    for &s in &pcm[..total] {
        bytes.extend_from_slice(&s.to_le_bytes());
    }
    Ok(bytes)
}
