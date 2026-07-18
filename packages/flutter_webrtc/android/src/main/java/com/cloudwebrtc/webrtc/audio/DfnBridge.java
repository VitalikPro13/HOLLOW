package com.cloudwebrtc.webrtc.audio;

import android.util.Log;

import java.nio.ByteBuffer;

/**
 * Runtime bridge to the DeepFilterNet3 C ABI exported by hollow_core
 * (rust/hollow_core/src/dfn_ffi.rs). The JNI export names over there are
 * derived from THIS class's fully-qualified name — renaming or moving this
 * class silently unbinds them (runtime bypass, not a build error), so keep
 * the two files in sync.
 *
 * flutter_rust_bridge loads libhollow_core.so through Dart FFI's dlopen,
 * which does NOT register it with ART — the System.loadLibrary in the
 * static initializer binds the same already-mapped .so (the loader
 * refcounts it) and registers native-method lookup. Any failure leaves
 * {@link #available()} false and DFN gracefully unavailable — never broken
 * audio.
 */
final class DfnBridge {
    private static final String TAG = "hollow_dfn";
    private static final boolean LOADED;

    static {
        boolean ok = false;
        try {
            System.loadLibrary("hollow_core");
            final int abi = nativeAbiVersion();
            ok = abi == 1;
            if (!ok) {
                Log.w(TAG, "ABI mismatch (core " + abi + ", plugin expects 1)"
                        + " — AI noise suppression unavailable");
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

    /** Blocking model load (100-500 ms) — background threads only. 0 = failed. */
    static long create() {
        if (!LOADED) return 0;
        try {
            return nativeCreate();
        } catch (Throwable t) {
            Log.w(TAG, "create failed: " + t);
            return 0;
        }
    }

    /**
     * Denoise 480 int16-scale float samples in place at {@code offsetFloats}
     * inside the DIRECT buffer the WebRTC AAR hands the capture processor.
     * Returns 0 when processed; nonzero = frame untouched.
     */
    static int processDirect(long handle, ByteBuffer buffer, int offsetFloats) {
        if (!LOADED || handle == 0) return 1;
        return nativeProcessDirect(handle, buffer, offsetFloats);
    }

    static void setAttenLim(long handle, float db) {
        if (LOADED && handle != 0) nativeSetAttenLim(handle, db);
    }

    static void setPostFilterBeta(long handle, float beta) {
        if (LOADED && handle != 0) nativeSetPostFilterBeta(handle, beta);
    }

    private static native int nativeAbiVersion();
    private static native long nativeCreate();
    private static native int nativeProcessDirect(
            long handle, ByteBuffer buffer, int offsetFloats);
    private static native void nativeSetAttenLim(long handle, float db);
    private static native void nativeSetPostFilterBeta(long handle, float beta);
}
