//! C-ABI (and Android JNI) surface for AI noise suppression (RNNoise by default,
//! DeepFilterNet3 optional; both engines live in `hollow_dfn`).
//!
//! Raw `extern "C"`, outside `api` so flutter_rust_bridge codegen never scans it.
//! The forked flutter_webrtc capture processors bind these symbols at RUNTIME, so
//! the names are a contract: Linux needs `dlopen` + `dlsym` (Dart's own dlopen is
//! RTLD_LOCAL, RTLD_DEFAULT will NOT find them), and the Android exports are bound
//! to `com.cloudwebrtc.webrtc.audio.DfnBridge`, which drifts silently at runtime
//! rather than failing the build if that Java class ever moves.
//!
//! Threading: `create*` may block (DFN3's model load is up to ~15 s on mobile) so
//! background threads only; `process*` runs on exactly one thread at a time and the
//! handle has no internal locking; the setters stage into an atomic the audio thread
//! reads at a frame boundary. A published handle lives for the process lifetime, so
//! an engine swap leaks the old one rather than free one the audio thread may enter.

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU32, Ordering};

use hollow_dfn::{AdaptStatus, Adapter, EngineKind, FRAME};

/// Bump on ANY signature/semantic change; ports refuse to bind on mismatch.
pub const HOLLOW_DFN_ABI_VERSION: u32 = 3;

/// Sentinel bit-pattern for "no pending value", a quiet NaN never passed as a real
/// parameter.
const PENDING_NONE: u32 = 0x7FC0_DEAD;

struct DfnHandle {
    adapter: Adapter,
    pending_atten_lim: AtomicU32,
    pending_pf_beta: AtomicU32,
}

impl DfnHandle {
    fn apply_pending(&mut self) {
        let a = self.pending_atten_lim.swap(PENDING_NONE, Ordering::AcqRel);
        if a != PENDING_NONE {
            self.adapter.set_atten_lim(f32::from_bits(a));
        }
        let b = self.pending_pf_beta.swap(PENDING_NONE, Ordering::AcqRel);
        if b != PENDING_NONE {
            self.adapter.set_post_filter_beta(f32::from_bits(b));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn hollow_dfn_abi_version() -> u32 {
    HOLLOW_DFN_ABI_VERSION
}

/// Create the given engine (0 = RNNoise, 1 = DFN3) behind the format adapter, NULL
/// on failure. May block, so background threads only.
#[unsafe(no_mangle)]
pub extern "C" fn hollow_dfn_create_engine(engine: i32) -> *mut c_void {
    let Some(kind) = EngineKind::from_i32(engine) else {
        crate::hollow_log!("[dfn] unknown engine id {engine}");
        return std::ptr::null_mut();
    };
    let t0 = std::time::Instant::now();
    let created = catch_unwind(|| Adapter::new(kind));
    match created {
        Ok(Ok(adapter)) => {
            // Success is LOGGED on purpose: "engine silently working" and "engine
            // silently absent" must never look the same in hollow_debug.log.
            crate::hollow_log!(
                "[dfn] engine {kind:?} ready in {} ms",
                t0.elapsed().as_millis()
            );
            Box::into_raw(Box::new(DfnHandle {
                adapter,
                pending_atten_lim: AtomicU32::new(PENDING_NONE),
                pending_pf_beta: AtomicU32::new(PENDING_NONE),
            })) as *mut c_void
        }
        Ok(Err(e)) => {
            crate::hollow_log!("[dfn] engine {kind:?} init failed: {e}");
            std::ptr::null_mut()
        }
        Err(_) => {
            crate::hollow_log!("[dfn] engine {kind:?} init panicked");
            std::ptr::null_mut()
        }
    }
}

/// Create the DEFAULT engine (RNNoise), so a caller that does not care about
/// engines never passes a magic number.
#[unsafe(no_mangle)]
pub extern "C" fn hollow_dfn_create() -> *mut c_void {
    hollow_dfn_create_engine(EngineKind::Rnnoise as i32)
}

/// Shared body for both process entry points. Returns the C return code: 0 =
/// processed in place, 1 = bad args, 2 = engine error, 3 = panic, 4 = unsupported
/// capture shape (frame untouched, and the ports latch formatOk on it so Dart
/// falls back to WebRTC NS rather than bailing).
fn process_impl(
    handle: *mut c_void,
    buf: *mut f32,
    len: i32,
    num_bands: i32,
    rate: i32,
    channels: i32,
) -> i32 {
    if handle.is_null()
        || buf.is_null()
        || len <= 0
        || num_bands <= 0
        || rate <= 0
        || channels <= 0
    {
        return 1;
    }
    let h = unsafe { &mut *(handle as *mut DfnHandle) };
    let buf = unsafe { std::slice::from_raw_parts_mut(buf, len as usize) };
    h.apply_pending();
    // A panic must NEVER unwind across the C boundary into the audio thread. On
    // engine error the frame is whatever was left mid-write, so ports treat rc 2
    // and 3 as "disable for this session".
    let res = catch_unwind(AssertUnwindSafe(|| {
        h.adapter.process(
            buf,
            num_bands as usize,
            rate as usize,
            channels as usize,
        )
    }));
    match res {
        Ok(Ok(AdaptStatus::Processed)) => 0,
        Ok(Ok(AdaptStatus::Unsupported)) => 4,
        Ok(Err(e)) => {
            crate::hollow_log!("[dfn] process error: {e}");
            2
        }
        Err(_) => {
            crate::hollow_log!("[dfn] process panicked");
            3
        }
    }
}

/// ABI v2 entry point: denoise one 10 ms capture frame IN PLACE in whatever shape
/// the APM delivered. `buf`/`len` cover the ENTIRE buffer (all bands and channels,
/// planar, int16-scale floats). Return codes: see [`process_impl`].
///
/// # Safety
/// `handle` must come from a `hollow_dfn_create*` call and `buf` must point to at
/// least `len` valid floats. Single-threaded per handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_process_ex(
    handle: *mut c_void,
    buf: *mut f32,
    len: i32,
    num_bands: i32,
    rate: i32,
    channels: i32,
) -> i32 {
    process_impl(handle, buf, len, num_bands, rate, channels)
}

/// Legacy v1 shape (exactly 480 floats, 48 kHz fullband mono), kept for the offline
/// harness; the ports call [`hollow_dfn_process_ex`].
///
/// # Safety
/// Same contract as [`hollow_dfn_process_ex`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_process(
    handle: *mut c_void,
    frame: *mut f32,
    len: i32,
) -> i32 {
    if len as usize != FRAME {
        return 1;
    }
    process_impl(handle, frame, len, 1, 48000, 1)
}

/// Voice probability of the LAST successfully processed frame (0..1), or -1.0 when
/// unavailable (DFN3, no frame yet, bad handle). RNNoise computes it free and the
/// capture chain uses it for speech presence, falling back to its own gating on -1.
///
/// # Safety
/// Same contract as the process calls: audio thread only, right after a 0-return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_last_vad(handle: *mut c_void) -> f32 {
    if handle.is_null() {
        return -1.0;
    }
    let h = unsafe { &*(handle as *mut DfnHandle) };
    h.adapter.last_vad()
}

/// Cap the maximum suppression in dB (100 = effectively uncapped). Staged
/// atomically, applied at the next frame. DFN3-only, RNNoise ignores it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_set_atten_lim(handle: *mut c_void, db: f32) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &*(handle as *mut DfnHandle) };
    h.pending_atten_lim.store(db.to_bits(), Ordering::Release);
}

/// Post-filter beta (0 disables). Staged like the atten limit, DFN3-only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_set_post_filter_beta(
    handle: *mut c_void,
    beta: f32,
) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &*(handle as *mut DfnHandle) };
    h.pending_pf_beta.store(beta.to_bits(), Ordering::Release);
}

/// Free a handle. ONLY safe when the audio thread can no longer enter a
/// process call with it (tests / failed-publish cleanup).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_free(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(handle as *mut DfnHandle) });
}

// Android JNI bridge for com.cloudwebrtc.webrtc.audio.DfnBridge. That Java class
// calls System.loadLibrary("hollow_core") in its static initializer, because FRB's
// Dart-side dlopen does NOT register the .so with ART.
#[cfg(target_os = "android")]
mod android {
    use super::*;
    use jni::objects::{JByteBuffer, JClass};
    use jni::sys::{jfloat, jint, jlong};
    use jni::JNIEnv;

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeAbiVersion(
        _env: JNIEnv,
        _class: JClass,
    ) -> jint {
        HOLLOW_DFN_ABI_VERSION as jint
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeCreateEngine(
        _env: JNIEnv,
        _class: JClass,
        engine: jint,
    ) -> jlong {
        hollow_dfn_create_engine(engine) as jlong
    }

    /// Processes the ENTIRE frame inside the DIRECT ByteBuffer the WebRTC AAR hands
    /// the Java capture processor. Zero-copy.
    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeProcessDirectEx(
        env: JNIEnv,
        _class: JClass,
        handle: jlong,
        buffer: JByteBuffer,
        total_floats: jint,
        num_bands: jint,
        rate: jint,
        channels: jint,
    ) -> jint {
        if handle == 0 || total_floats <= 0 {
            return 1;
        }
        let addr = match env.get_direct_buffer_address(&buffer) {
            Ok(p) if !p.is_null() => p,
            _ => return 1,
        };
        let cap = match env.get_direct_buffer_capacity(&buffer) {
            Ok(c) => c,
            Err(_) => return 1,
        };
        if total_floats as usize * 4 > cap {
            return 1;
        }
        // The AAR's ByteBuffer is native-order float PCM.
        process_impl(
            handle as *mut c_void,
            addr as *mut f32,
            total_floats,
            num_bands,
            rate,
            channels,
        )
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeLastVad(
        _env: JNIEnv,
        _class: JClass,
        handle: jlong,
    ) -> jfloat {
        unsafe { hollow_dfn_last_vad(handle as *mut c_void) }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeSetAttenLim(
        _env: JNIEnv,
        _class: JClass,
        handle: jlong,
        db: jfloat,
    ) {
        unsafe { hollow_dfn_set_atten_lim(handle as *mut c_void, db) }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeSetPostFilterBeta(
        _env: JNIEnv,
        _class: JClass,
        handle: jlong,
        beta: jfloat,
    ) {
        unsafe { hollow_dfn_set_post_filter_beta(handle as *mut c_void, beta) }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeFree(
        _env: JNIEnv,
        _class: JClass,
        handle: jlong,
    ) {
        unsafe { hollow_dfn_free(handle as *mut c_void) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abi_create_process_roundtrip() {
        assert_eq!(hollow_dfn_abi_version(), HOLLOW_DFN_ABI_VERSION);

        let h = hollow_dfn_create();
        assert!(!h.is_null(), "rnnoise create");

        // Length guard on the legacy entry: wrong len leaves nonzero.
        let mut short = [0.0f32; 128];
        assert_ne!(unsafe { hollow_dfn_process(h, short.as_mut_ptr(), 128) }, 0);
        assert_ne!(
            unsafe { hollow_dfn_process(std::ptr::null_mut(), short.as_mut_ptr(), 128) },
            0
        );
        assert_ne!(
            unsafe {
                hollow_dfn_process_ex(std::ptr::null_mut(), short.as_mut_ptr(), 128, 1, 48000, 1)
            },
            0
        );

        // Stage parameter changes from another thread; RNNoise no-ops on them.
        unsafe {
            hollow_dfn_set_atten_lim(h, 24.0);
            hollow_dfn_set_post_filter_beta(h, 0.0);
        }

        let fill = |frame: &mut [f32], n: u32| {
            let len = frame.len();
            for (i, s) in frame.iter_mut().enumerate() {
                let t = (n as usize * len + i) as f32 / 48000.0;
                let am = 0.5 + 0.5 * (2.0 * std::f32::consts::PI * 4.0 * t).sin();
                *s = 1500.0
                    * am
                    * ((2.0 * std::f32::consts::PI * 220.0 * t).sin()
                        + 0.5 * (2.0 * std::f32::consts::PI * 440.0 * t).sin());
            }
        };

        assert_eq!(unsafe { hollow_dfn_last_vad(std::ptr::null_mut()) }, -1.0);
        assert_eq!(unsafe { hollow_dfn_last_vad(h) }, -1.0);

        let mut frame = [0.0f32; FRAME];
        for n in 0..50u32 {
            fill(&mut frame, n);
            assert_eq!(
                unsafe { hollow_dfn_process(h, frame.as_mut_ptr(), FRAME as i32) },
                0
            );
            assert!(frame.iter().all(|s| s.is_finite() && s.abs() <= 65536.0));
            let vad = unsafe { hollow_dfn_last_vad(h) };
            assert!((0.0..=1.0).contains(&vad), "vad {vad} out of range");
        }

        // v2 shapes through the adapter: split-band 3x160 @48k …
        let mut split = [0.0f32; FRAME];
        for n in 0..10u32 {
            fill(&mut split, n);
            assert_eq!(
                unsafe {
                    hollow_dfn_process_ex(h, split.as_mut_ptr(), FRAME as i32, 3, 48000, 1)
                },
                0
            );
            assert!(split.iter().all(|s| s.is_finite()));
        }
        // … 16 kHz mono 160 (Windows 16 kHz-class mic) …
        let mut mono16 = [0.0f32; 160];
        for n in 0..10u32 {
            fill(&mut mono16, n);
            assert_eq!(
                unsafe { hollow_dfn_process_ex(h, mono16.as_mut_ptr(), 160, 1, 16000, 1) },
                0
            );
            assert!(mono16.iter().all(|s| s.is_finite()));
        }
        // … and an unsupported shape reports 4 (fallback latch, not bail).
        let mut two_band = [0.0f32; 320];
        assert_eq!(
            unsafe { hollow_dfn_process_ex(h, two_band.as_mut_ptr(), 320, 2, 32000, 1) },
            4
        );

        unsafe { hollow_dfn_free(h) };

        // Unknown engine id refuses to create.
        assert!(hollow_dfn_create_engine(7).is_null());

        // DFN3's slow create is the one expensive line in this test.
        let dfn = hollow_dfn_create_engine(1);
        assert!(!dfn.is_null(), "dfn3 create");
        fill(&mut frame, 0);
        assert_eq!(
            unsafe { hollow_dfn_process_ex(dfn, frame.as_mut_ptr(), FRAME as i32, 1, 48000, 1) },
            0
        );
        // DFN3 has no VAD — the chain must see -1 and use its own gating.
        assert_eq!(unsafe { hollow_dfn_last_vad(dfn) }, -1.0);
        unsafe { hollow_dfn_free(dfn) };
    }
}
