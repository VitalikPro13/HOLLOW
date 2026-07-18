package com.cloudwebrtc.webrtc.audio;

import android.util.Log;

import java.nio.ByteBuffer;

/**
 * Runtime bridge to the AI noise-suppression C ABI exported by hollow_core
 * (rust/hollow_core/src/dfn_ffi.rs) — RNNoise by default, DFN3 behind
 * engine id 1, both behind the Rust format adapter. The JNI export names
 * over there are derived from THIS class's fully-qualified name — renaming
 * or moving this class silently unbinds them (runtime bypass, not a build
 * error), so keep the two files in sync.
 *
 * flutter_rust_bridge loads libhollow_core.so through Dart FFI's dlopen,
 * which does NOT register it with ART — the System.loadLibrary in the
 * static initializer binds the same already-mapped .so (the loader
 * refcounts it) and registers native-method lookup. Any failure leaves
 * {@link #available()} false and AI NS gracefully unavailable — never
 * broken audio.
 */
final class DfnBridge {
    private static final String TAG = "hollow_dfn";
    private static final int EXPECTED_ABI = 3;
    private static final boolean LOADED;

    /** Engine ids — MUST match hollow_dfn::EngineKind in Rust. */
    static final int ENGINE_RNNOISE = 0;
    static final int ENGINE_DFN3 = 1;

    static {
        boolean ok = false;
        try {
            System.loadLibrary("hollow_core");
            final int abi = nativeAbiVersion();
            ok = abi == EXPECTED_ABI;
            if (!ok) {
                Log.w(TAG, "ABI mismatch (core " + abi + ", plugin expects "
                        + EXPECTED_ABI + ") — AI noise suppression unavailable");
            }
        } catch (Throwable t) {
            Log.w(TAG, "hollow_core natives unavailable — AI noise "
                    + "suppression off: " + t);
        }
        LOADED = ok;
    }

    private DfnBridge() {}

    static boolean available() {
        return LOADED;
    }

    /**
     * Blocking engine create — background threads only (RNNoise is instant;
     * DFN3's model load measured ~15 s on a Pixel). 0 = failed.
     */
    static long createEngine(int engine) {
        if (!LOADED) return 0;
        try {
            return nativeCreateEngine(engine);
        } catch (Throwable t) {
            Log.w(TAG, "create failed: " + t);
            return 0;
        }
    }

    /**
     * Denoise one capture frame in place inside the DIRECT buffer the
     * WebRTC AAR hands the capture processor — the ENTIRE buffer
     * ({@code totalFloats} int16-scale floats from offset 0, all
     * bands/channels planar), with the raw shape passed through; the Rust
     * adapter does the conversion (48 kHz direct, 3-band merge/split,
     * 16 kHz resample). Zero-copy. Returns 0 = processed; 4 = unsupported
     * shape (frame untouched); other nonzero = engine error.
     */
    static int processDirectEx(long handle, ByteBuffer buffer, int totalFloats,
            int numBands, int rate, int channels) {
        if (!LOADED || handle == 0) return 1;
        return nativeProcessDirectEx(
                handle, buffer, totalFloats, numBands, rate, channels);
    }

    /**
     * Voice probability of the LAST successfully processed frame (0..1),
     * or -1 when unavailable (DFN3 engine, no frame yet). Audio thread
     * only, right after a 0-return from processDirectEx.
     */
    static float lastVad(long handle) {
        if (!LOADED || handle == 0) return -1f;
        return nativeLastVad(handle);
    }

    /** DFN3-only tuning; ignored by RNNoise. */
    static void setAttenLim(long handle, float db) {
        if (LOADED && handle != 0) nativeSetAttenLim(handle, db);
    }

    /** DFN3-only tuning; ignored by RNNoise. */
    static void setPostFilterBeta(long handle, float beta) {
        if (LOADED && handle != 0) nativeSetPostFilterBeta(handle, beta);
    }

    private static native int nativeAbiVersion();
    private static native long nativeCreateEngine(int engine);
    private static native int nativeProcessDirectEx(long handle,
            ByteBuffer buffer, int totalFloats, int numBands, int rate,
            int channels);
    private static native float nativeLastVad(long handle);
    private static native void nativeSetAttenLim(long handle, float db);
    private static native void nativeSetPostFilterBeta(long handle, float beta);
}
