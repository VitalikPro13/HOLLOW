package com.cloudwebrtc.webrtc.audio;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * Hollow fork addition: a capture-post-processor that runs AFTER WebRTC's own
 * APM (AGC/NS/EC) on the local microphone. WebRTC's AGC normalizes to a
 * conservative target (~-18 dBFS), so calls come out quieter than users
 * expect. This applies a makeup gain followed by a soft limiter with a
 * ~-3 dBFS ceiling so the boost can never clip — the OBS-style chain.
 *
 * The prebuilt WebRTC AAR exposes no AGC target-level knob, so this
 * post-processor is how we add the missing loudness.
 *
 * {@link #process} runs on the realtime audio thread, so it is allocation-free
 * and lock-free; the gain is a volatile read each frame and can be updated
 * live mid-call via {@link #setGain}.
 */
public class CaptureGainProcessor
        implements AudioProcessingAdapter.ExternalAudioFrameProcessing {

    // WebRTC's APM delivers float PCM in int16 scale (~ +/-32768), not +/-1.0.
    private static final float FULL_SCALE = 32768.0f;
    // -3 dBFS ceiling: 10^(-3/20) = 0.7079.
    private static final float CEILING = 0.7079f * FULL_SCALE; // ~23197
    // Soft-knee threshold: pass through untouched below this, smoothly
    // saturate above it. 0.6 * ceiling keeps normal speech fully linear.
    private static final float KNEE = 0.6f * CEILING;
    private static final float RANGE = CEILING - KNEE;

    private volatile float gain = 1.0f;

    /** Linear makeup-gain multiplier (1.0 = transparent). Thread-safe. */
    public void setGain(float gain) {
        this.gain = gain;
    }

    @Override
    public void initialize(int sampleRateHz, int numChannels) {}

    @Override
    public void reset(int newRate) {}

    @Override
    public void process(int numBands, int numFrames, ByteBuffer buffer) {
        final float g = gain;
        if (buffer == null) {
            return;
        }
        // Native byte order; the buffer holds deinterleaved 32-bit float PCM.
        final FloatBuffer fb = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer();
        final int count = fb.remaining();
        for (int i = 0; i < count; i++) {
            fb.put(i, softLimit(fb.get(i) * g));
        }
    }

    /**
     * Soft limiter, C1-continuous at the knee, asymptotes to +/-CEILING so the
     * signal can never clip. Transparent below the knee.
     */
    private static float softLimit(float x) {
        final float ax = Math.abs(x);
        if (ax <= KNEE) {
            return x;
        }
        final float over = ax - KNEE;
        final float limited = KNEE + RANGE * (float) Math.tanh(over / RANGE);
        return x < 0.0f ? -limited : limited;
    }
}
