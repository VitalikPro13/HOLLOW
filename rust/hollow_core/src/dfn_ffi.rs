//! C-ABI (and Android JNI) surface for DeepFilterNet3 noise suppression.
//!
//! Raw `extern "C"`, intentionally OUTSIDE `api` so flutter_rust_bridge
//! codegen never scans it (same pattern as `push_enrich`). The forked
//! flutter_webrtc capture-processor ports bind these symbols at RUNTIME:
//!   - Windows: `GetProcAddress(GetModuleHandleW(L"hollow_core.dll"))`
//!   - Linux:   `dlopen("libhollow_core.so")` + `dlsym` (Dart's own dlopen
//!              is RTLD_LOCAL — RTLD_DEFAULT will NOT find these)
//!   - darwin:  `dlsym(RTLD_DEFAULT, ...)` (hollow_core is a dynamic
//!              framework; exported symbols are strip roots)
//!   - Android: the JNI exports below, bound to
//!              `com.cloudwebrtc.webrtc.audio.DfnBridge` — if that Java
//!              class is ever renamed/moved, these symbol names MUST move
//!              with it (runtime bypass, not a build error, if they drift).
//!
//! Threading contract (lifecycle rule from the DFN3 plan):
//!   - `hollow_dfn_create` is EXPENSIVE (tract model load, 100–500 ms) and
//!     must run on a background thread, never the audio thread.
//!   - `hollow_dfn_process` is called from EXACTLY ONE thread at a time
//!     (the APM capture thread) — the handle has no internal locking.
//!   - `set_atten_lim`/`set_post_filter_beta` may be called from any
//!     thread: they stage the value in an atomic; the audio thread applies
//!     it at the next frame boundary (lock-free, no race with process).
//!   - The handle lives for the process lifetime once published; `free`
//!     exists for tests/teardown-before-publish only. NEVER free a handle
//!     the audio thread might still enter.

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU32, Ordering};

use hollow_dfn::{Dfn, FRAME};

/// Bump on ANY signature/semantic change; ports refuse to bind on mismatch.
pub const HOLLOW_DFN_ABI_VERSION: u32 = 1;

/// Sentinel bit-pattern meaning "no pending value" (a quiet NaN we never
/// pass as a real parameter).
const PENDING_NONE: u32 = 0x7FC0_DEAD;

struct DfnHandle {
    dfn: Dfn,
    pending_atten_lim: AtomicU32,
    pending_pf_beta: AtomicU32,
}

impl DfnHandle {
    fn apply_pending(&mut self) {
        let a = self.pending_atten_lim.swap(PENDING_NONE, Ordering::AcqRel);
        if a != PENDING_NONE {
            self.dfn.set_atten_lim(f32::from_bits(a));
        }
        let b = self.pending_pf_beta.swap(PENDING_NONE, Ordering::AcqRel);
        if b != PENDING_NONE {
            self.dfn.set_post_filter_beta(f32::from_bits(b));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn hollow_dfn_abi_version() -> u32 {
    HOLLOW_DFN_ABI_VERSION
}

/// Load the embedded DFN3 model and return an opaque handle, or NULL on
/// failure. Blocking and slow — background threads only.
#[unsafe(no_mangle)]
pub extern "C" fn hollow_dfn_create() -> *mut c_void {
    let t0 = std::time::Instant::now();
    let created = catch_unwind(|| Dfn::new());
    match created {
        Ok(Ok(dfn)) => {
            // Success is LOGGED on purpose: "engine silently working" and
            // "engine silently absent" must never look the same in
            // hollow_debug.log (the 2026-07-17 field-test lesson).
            crate::hollow_log!(
                "[dfn] model loaded in {} ms",
                t0.elapsed().as_millis()
            );
            Box::into_raw(Box::new(DfnHandle {
                dfn,
                pending_atten_lim: AtomicU32::new(PENDING_NONE),
                pending_pf_beta: AtomicU32::new(PENDING_NONE),
            })) as *mut c_void
        }
        Ok(Err(e)) => {
            crate::hollow_log!("[dfn] model load failed: {e}");
            std::ptr::null_mut()
        }
        Err(_) => {
            crate::hollow_log!("[dfn] model load panicked");
            std::ptr::null_mut()
        }
    }
}

/// Denoise one 10 ms frame IN PLACE: exactly 480 float samples at int16
/// scale (±32768), 48 kHz mono. Returns 0 when the frame was processed;
/// nonzero when it was left untouched (bad args or internal error) — the
/// caller passes the frame through unmodified either way it likes.
///
/// # Safety
/// `handle` must be a live pointer from [`hollow_dfn_create`]; `frame`
/// must point to at least `len` valid floats. Single-threaded per handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_process(
    handle: *mut c_void,
    frame: *mut f32,
    len: i32,
) -> i32 {
    if handle.is_null() || frame.is_null() || len as usize != FRAME {
        return 1;
    }
    let h = unsafe { &mut *(handle as *mut DfnHandle) };
    let buf = unsafe { std::slice::from_raw_parts_mut(frame, FRAME) };
    h.apply_pending();
    // A panic must NEVER unwind across the C boundary into the audio
    // thread. On panic or error the frame content is whatever the engine
    // left mid-write — report failure and copy back is not possible
    // (in-place), so ports treat nonzero as "disable DFN for this session".
    let res = catch_unwind(AssertUnwindSafe(|| h.dfn.process_480(buf)));
    match res {
        Ok(Ok(_lsnr)) => 0,
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

/// Cap the maximum suppression in dB (100 = effectively uncapped). Staged
/// atomically; applied by the audio thread at the next frame.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_set_atten_lim(handle: *mut c_void, db: f32) {
    if handle.is_null() {
        return;
    }
    let h = unsafe { &*(handle as *mut DfnHandle) };
    h.pending_atten_lim.store(db.to_bits(), Ordering::Release);
}

/// Post-filter beta (0 disables). Staged atomically like the atten limit.
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

/// Free a handle. ONLY safe when the audio thread can no longer enter
/// `hollow_dfn_process` with it (tests / failed-publish cleanup).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_dfn_free(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(handle as *mut DfnHandle) });
}

// ---------------------------------------------------------------------------
// Android JNI bridge — com.cloudwebrtc.webrtc.audio.DfnBridge
//
// The fork's Java class declares:
//   static native int  nativeAbiVersion();
//   static native long nativeCreate();
//   static native int  nativeProcessDirect(long handle, ByteBuffer buf, int offsetFloats);
//   static native void nativeSetAttenLim(long handle, float db);
//   static native void nativeSetPostFilterBeta(long handle, float beta);
//   static native void nativeFree(long handle);
// and calls System.loadLibrary("hollow_core") in its static initializer
// (FRB's Dart-side dlopen does NOT register the .so with ART).
// ---------------------------------------------------------------------------
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
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeCreate(
        _env: JNIEnv,
        _class: JClass,
    ) -> jlong {
        hollow_dfn_create() as jlong
    }

    /// Processes 480 floats at `offset_floats` inside the DIRECT ByteBuffer
    /// the WebRTC AAR hands the Java capture processor. Zero-copy.
    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_cloudwebrtc_webrtc_audio_DfnBridge_nativeProcessDirect(
        env: JNIEnv,
        _class: JClass,
        handle: jlong,
        buffer: JByteBuffer,
        offset_floats: jint,
    ) -> jint {
        if handle == 0 || offset_floats < 0 {
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
        let off = offset_floats as usize;
        if (off + FRAME) * 4 > cap {
            return 1;
        }
        // The AAR's ByteBuffer is native-order float PCM (the Java port
        // already reinterprets it as FloatBuffer the same way).
        let frame = unsafe { (addr as *mut f32).add(off) };
        unsafe { hollow_dfn_process(handle as *mut c_void, frame, FRAME as i32) }
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
        assert!(!h.is_null(), "model load");

        // Length guard: wrong len leaves nonzero.
        let mut short = [0.0f32; 128];
        assert_ne!(unsafe { hollow_dfn_process(h, short.as_mut_ptr(), 128) }, 0);
        // Null guards.
        assert_ne!(
            unsafe { hollow_dfn_process(std::ptr::null_mut(), short.as_mut_ptr(), 128) },
            0
        );

        // Stage parameter changes from "another thread" (same thread is
        // fine — the point is the staging path executes).
        unsafe {
            hollow_dfn_set_atten_lim(h, 24.0);
            hollow_dfn_set_post_filter_beta(h, 0.0);
        }

        // Process 50 frames of low speech-ish noise; output stays finite
        // and in range (suppression policy is the model's business).
        let mut frame = [0.0f32; FRAME];
        for n in 0..50u32 {
            for (i, s) in frame.iter_mut().enumerate() {
                let t = (n as usize * FRAME + i) as f32 / 48000.0;
                let am = 0.5 + 0.5 * (2.0 * std::f32::consts::PI * 4.0 * t).sin();
                *s = 1500.0
                    * am
                    * ((2.0 * std::f32::consts::PI * 220.0 * t).sin()
                        + 0.5 * (2.0 * std::f32::consts::PI * 440.0 * t).sin());
            }
            assert_eq!(unsafe { hollow_dfn_process(h, frame.as_mut_ptr(), FRAME as i32) }, 0);
            assert!(frame.iter().all(|s| s.is_finite() && s.abs() <= 65536.0));
        }

        unsafe { hollow_dfn_free(h) };
    }
}
