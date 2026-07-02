package com.cloudwebrtc.webrtc.audio;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * Hollow fork addition: a capture-post-processor that runs AFTER WebRTC's own
 * APM (AGC/NS/EC) on the local microphone. WebRTC's AGC normalizes to a
 * conservative target (~-18 dBFS), so calls come out quieter than users
 * expect. The prebuilt WebRTC AAR exposes no AGC target-level knob, so this
 * post-processor is where the missing loudness/polish is added.
 *
 * Two modes, switched live via {@link #setEnhance}:
 * <ul>
 *   <li>enhance OFF (legacy): flat makeup gain + a -3 dBFS soft limiter.</li>
 *   <li>enhance ON (default from the app): a STATIC broadcast voice chain —
 *   trim -> EQ (HP 100 Hz 24 dB/oct, low shelf 110 Hz +6 dB, peaking 291/-3,
 *   3k/+2, 7k/+3.5, 12k/+1.5 dB) -> compressor (-18 dBFS, 3:1, 10/100 ms,
 *   +12 dB makeup) -> smoothed peak limiter (-1 dBFS) -> tanh safety net.
 *   All parameters are FIXED (no adaptive leveler): fixed biquads cannot
 *   zipper, and the single compressor uses the Giannoulis decoupled smooth
 *   detector — the anti-crackle rules from the reverted adaptive chain.
 *   Java port of common/cpp/src/flutter_capture_gain_processor.cc — keep
 *   them in sync.</li>
 * </ul>
 *
 * {@link #process} runs on the realtime audio thread, so it is allocation-free
 * and lock-free; gain/enhance are volatile reads and can be updated live
 * mid-call.
 */
public class CaptureGainProcessor
        implements AudioProcessingAdapter.ExternalAudioFrameProcessing {

    // WebRTC's APM delivers float PCM in int16 scale (~ +/-32768), not +/-1.0.
    private static final float FULL_SCALE = 32768.0f;

    // --- Legacy (enhance OFF) path: flat gain + -3 dBFS soft limiter. ------
    private static final float LEGACY_CEILING = 0.7079f * FULL_SCALE; // ~23197
    private static final float LEGACY_KNEE = 0.6f * LEGACY_CEILING;
    private static final float LEGACY_RANGE = LEGACY_CEILING - LEGACY_KNEE;

    // --- Enhance path -------------------------------------------------------
    // The mic-gain slider's "100%" is a linear 2.0 (kMicGainDisplayUnit); in
    // enhance mode the chain owns the loudness so the slider is a trim.
    private static final float ENHANCE_TRIM_SCALE = 0.5f;

    // EQ (Vitalik's Adobe Audition curve).
    private static final float HP_FREQ = 100.0f;
    private static final float HP_Q1 = 0.54119610f; // 4th-order Butterworth
    private static final float HP_Q2 = 1.30656296f;
    private static final float SHELF_FREQ = 110.0f;
    private static final float SHELF_GAIN_DB = 6.0f;
    private static final float[] PEAK_FREQ = {291.0f, 3000.0f, 7005.0f, 12000.0f};
    private static final float[] PEAK_GAIN_DB = {-3.0f, 2.0f, 3.5f, 1.5f};
    private static final float[] PEAK_Q = {1.5f, 1.5f, 2.0f, 2.0f};

    // Compressor: -18 dBFS, 3:1, 10/100 ms, 6 dB knee. Makeup gain is
    // RUNTIME-set (makeupDb, the user's "strength" knob); 12 dB default.
    private static final float COMP_THRESHOLD_DB = -18.0f;
    private static final float COMP_RATIO = 3.0f;
    private static final float COMP_ATTACK_MS = 10.0f;
    private static final float COMP_RELEASE_MS = 100.0f;
    private static final float COMP_KNEE_DB = 6.0f;

    // Limiter: -1 dBFS ceiling, gain-smoothed, plus a tanh safety net.
    private static final float LIM_CEILING = 0.8913f * FULL_SCALE; // ~29206
    private static final float LIM_ATTACK_MS = 1.0f;
    private static final float LIM_RELEASE_MS = 100.0f;
    private static final float SAFETY_KNEE = 0.85f * LIM_CEILING;
    private static final float SAFETY_RANGE = LIM_CEILING - SAFETY_KNEE;

    // Dynamic mode: a slow speech-gated RMS meter servos ONE input trim so
    // any mic lands at the calibrated speech level (~-28 dBFS RMS at the
    // compressor input — the Shure MV6 golden reference, 2026-07-02).
    // Frame-rate decisions, dB slew limits, per-sample de-zipper; the manual
    // gain/strength knobs are ignored while active.
    private static final float DYN_TARGET_RMS_DB = -28.0f;
    private static final float DYN_MAKEUP_DB = 3.6f;
    private static final float DYN_SPEECH_FLOOR_DB = -55.0f;
    private static final float DYN_METER_TAU_SEC = 2.0f;
    private static final float DYN_UP_DB_PER_SEC = 3.0f;
    private static final float DYN_DOWN_DB_PER_SEC = 9.0f;
    private static final float DYN_TRIM_MIN_DB = -20.0f; // cut wider than boost
    private static final float DYN_TRIM_MAX_DB = 12.0f;
    private static final float DYN_SMOOTH_MS = 5.0f;

    // Crackle insurance.
    private static final float DENORMAL = 1e-15f;
    private static final float LOG_FLOOR = 1e-9f;

    private static final int MAX_CHANNELS = 2;
    private static final int NUM_EQ_STAGES = 7; // hp1, hp2, shelf, 4 peaks
    // Per-frame gain trace for the split-band path.
    private static final int MAX_BAND_LEN = 1024;

    private volatile float gain = 1.0f;
    private volatile boolean enhance = false;
    private volatile float makeupDb = 12.0f;
    private volatile boolean dynamic = false;

    // Dynamic-mode servo (single mic — one servo, not per-channel).
    private float dynMeterDb;
    private boolean dynMeterPrimed;
    private float dynTrimDb;
    private float dynTrimLin = 1.0f;
    private float dynSmoothAlpha;
    // Per-sample trim trace, shared time-aligned across channels/bands.
    private final float[] trimBuf = new float[MAX_BAND_LEN];

    // Per-channel biquad coefficients (identical per channel) + state.
    private final float[] cB0 = new float[NUM_EQ_STAGES];
    private final float[] cB1 = new float[NUM_EQ_STAGES];
    private final float[] cB2 = new float[NUM_EQ_STAGES];
    private final float[] cA1 = new float[NUM_EQ_STAGES];
    private final float[] cA2 = new float[NUM_EQ_STAGES];
    private final float[][] eqX1 = new float[MAX_CHANNELS][NUM_EQ_STAGES];
    private final float[][] eqX2 = new float[MAX_CHANNELS][NUM_EQ_STAGES];
    private final float[][] eqY1 = new float[MAX_CHANNELS][NUM_EQ_STAGES];
    private final float[][] eqY2 = new float[MAX_CHANNELS][NUM_EQ_STAGES];
    private final float[] compY1 = new float[MAX_CHANNELS];
    private final float[] compYl = new float[MAX_CHANNELS];
    private final float[] limGr = new float[MAX_CHANNELS];
    private final float[] bandGain = new float[MAX_BAND_LEN];

    private int sampleRate = 48000;
    private int channels = 1;
    private float compAlphaA;
    private float compAlphaR;
    private float limAlphaA;
    private float limAlphaR;

    public CaptureGainProcessor() {
        setupFilters(sampleRate);
        resetState();
    }

    /**
     * Linear makeup-gain multiplier (1.0 = transparent in legacy mode; in
     * enhance mode rescaled so the slider's "100%" (2.0) is unity trim).
     * Thread-safe.
     */
    public void setGain(float gain) {
        this.gain = gain;
    }

    /** Enables the EQ+compressor+limiter voice chain. Thread-safe, live. */
    public void setEnhance(boolean enabled) {
        this.enhance = enabled;
    }

    /**
     * Compressor makeup gain (dB) for the enhance chain — the "strength"
     * knob (0 = no loudness boost, 12 = default). Thread-safe, live.
     */
    public void setEnhanceMakeup(float db) {
        this.makeupDb = db;
    }

    /**
     * Dynamic mode: a slow speech-gated RMS meter servos the input trim so
     * any mic lands at the calibrated speech level; the manual gain/strength
     * knobs are ignored while active. Thread-safe, live.
     */
    public void setEnhanceDynamic(boolean enabled) {
        this.dynamic = enabled;
    }

    @Override
    public void initialize(int sampleRateHz, int numChannels) {
        if (sampleRateHz > 0) {
            sampleRate = sampleRateHz;
        }
        channels = numChannels > 0 ? numChannels : 1;
        setupFilters(sampleRate);
        resetState();
    }

    @Override
    public void reset(int newRate) {
        if (newRate > 0) {
            sampleRate = newRate;
            setupFilters(sampleRate);
        }
        resetState();
    }

    @Override
    public void process(int numBands, int numFrames, ByteBuffer buffer) {
        final float g = gain;
        final boolean enh = enhance;
        final boolean dyn = dynamic;
        final float mkDb = dyn ? DYN_MAKEUP_DB : makeupDb;
        if (buffer == null) {
            return;
        }
        // Native byte order; the buffer holds deinterleaved 32-bit float PCM.
        final FloatBuffer fb = buffer.order(ByteOrder.nativeOrder()).asFloatBuffer();
        final int count = fb.remaining();
        if (count <= 0) {
            return;
        }

        if (!enh) {
            // Legacy path — identical to the shipped flat-gain processor.
            for (int i = 0; i < count; i++) {
                fb.put(i, softLimitLegacy(fb.get(i) * g));
            }
            return;
        }

        final float manualTrim = g * ENHANCE_TRIM_SCALE;

        // Segment length carrying ONE time-aligned gain trace: the samples
        // of band 0 (split-band) or of one channel (fullband).
        final int chansRaw = Math.min(Math.max(channels, 1), MAX_CHANNELS);
        final int segLen = numBands > 1 ? count / numBands : count / chansRaw;

        // Dynamic-mode servo: frame-rate, speech-gated, measured on the
        // first segment's PRE-trim samples (band0 / channel 0 = the mic).
        if (dyn && segLen > 0) {
            double sumsq = 0.0;
            for (int i = 0; i < segLen; i++) {
                final double v = fb.get(i);
                sumsq += v * v;
            }
            final float rms = (float) Math.sqrt(sumsq / segLen);
            final float rmsDb =
                    20.0f * (float) Math.log10(Math.max(rms, LOG_FLOOR) / FULL_SCALE);
            if (rmsDb > DYN_SPEECH_FLOOR_DB) {
                // Subband samples tick at fs/numBands.
                final float frameSec =
                        (float) segLen * (numBands > 1 ? numBands : 1) / sampleRate;
                if (!dynMeterPrimed) {
                    // First speech: snap straight to the right level, then
                    // servo slowly from there.
                    dynMeterPrimed = true;
                    dynMeterDb = rmsDb;
                    dynTrimDb = clamp(DYN_TARGET_RMS_DB - rmsDb,
                            DYN_TRIM_MIN_DB, DYN_TRIM_MAX_DB);
                } else {
                    final float meterAlpha =
                            Math.min(frameSec / DYN_METER_TAU_SEC, 1.0f);
                    dynMeterDb += meterAlpha * (rmsDb - dynMeterDb);
                    final float desired = clamp(DYN_TARGET_RMS_DB - dynMeterDb,
                            DYN_TRIM_MIN_DB, DYN_TRIM_MAX_DB);
                    float step = desired - dynTrimDb;
                    final float maxUp = DYN_UP_DB_PER_SEC * frameSec;
                    final float maxDown = DYN_DOWN_DB_PER_SEC * frameSec;
                    if (step > maxUp) step = maxUp;
                    if (step < -maxDown) step = -maxDown;
                    dynTrimDb += step;
                }
            }
        }
        final float trimTarget =
                dyn ? (float) Math.pow(10.0, dynTrimDb * 0.05) : manualTrim;

        // Per-sample trim trace (de-zippered in dynamic mode; constant in
        // manual mode), shared time-aligned across channels/bands.
        if (segLen <= 0 || segLen > MAX_BAND_LEN) {
            // Shape we don't understand — constant trim, no chain.
            for (int i = 0; i < count; i++) {
                fb.put(i, softLimitLegacy(fb.get(i) * trimTarget));
            }
            return;
        }
        for (int i = 0; i < segLen; i++) {
            dynTrimLin += (1.0f - dynSmoothAlpha) * (trimTarget - dynTrimLin);
            trimBuf[i] = dynTrimLin;
        }

        if (numBands > 1) {
            // Split-band: EQ/limiter are only valid on fullband audio; apply
            // trim + the band0 compressor gain time-aligned to higher bands
            // (a linear gain commutes with the filterbank).
            for (int i = 0; i < segLen; i++) {
                final float t = trimBuf[i];
                final float v = fb.get(i) * t;
                final float gc = compressorGain(0, v, mkDb);
                bandGain[i] = t * gc;
                fb.put(i, v * gc);
            }
            for (int b = 1; b < numBands; b++) {
                final int off = b * segLen;
                for (int i = 0; i < segLen; i++) {
                    fb.put(off + i, fb.get(off + i) * bandGain[i]);
                }
            }
            return;
        }

        // Fullband: deinterleaved per-channel segments. Full chain per
        // channel; anything beyond MAX_CHANNELS gets the legacy path.
        if (channels > MAX_CHANNELS || count % chansRaw != 0) {
            for (int i = 0; i < count; i++) {
                fb.put(i, softLimitLegacy(fb.get(i) * g));
            }
            return;
        }
        final int frames = segLen;

        for (int ch = 0; ch < chansRaw; ch++) {
            final int base = ch * frames;
            final float[] x1 = eqX1[ch];
            final float[] x2 = eqX2[ch];
            final float[] y1 = eqY1[ch];
            final float[] y2 = eqY2[ch];
            for (int i = 0; i < frames; i++) {
                // Trim (per-sample trace, shared across channels).
                float v = fb.get(base + i) * trimBuf[i] + DENORMAL;
                // EQ: 7 fixed biquads, Direct Form I.
                for (int f = 0; f < NUM_EQ_STAGES; f++) {
                    final float y = cB0[f] * v + cB1[f] * x1[f] + cB2[f] * x2[f]
                            - cA1[f] * y1[f] - cA2[f] * y2[f] + DENORMAL;
                    x2[f] = x1[f];
                    x1[f] = v;
                    y2[f] = y1[f];
                    y1[f] = y;
                    v = y;
                }
                // Compressor.
                v *= compressorGain(ch, v, mkDb);
                // Limiter: gain-smoothed peak limiter into a tanh safety net.
                final float pv = Math.abs(v);
                final float target = pv > LIM_CEILING ? LIM_CEILING / pv : 1.0f;
                if (target < limGr[ch]) {
                    limGr[ch] = limAlphaA * limGr[ch] + (1.0f - limAlphaA) * target;
                } else {
                    limGr[ch] = limAlphaR * limGr[ch] + (1.0f - limAlphaR) * target;
                }
                fb.put(base + i, softLimitSafety(v * limGr[ch]));
            }
        }
    }

    /**
     * Giannoulis soft-knee gain computer + decoupled smooth peak detector.
     * Returns the linear gain (makeup minus smoothed gain reduction) and
     * advances channel {@code ch}'s detector state.
     */
    private float compressorGain(int ch, float v, float mkDb) {
        final float av = Math.abs(v);
        final float levelDb =
                20.0f * (float) Math.log10(Math.max(av, LOG_FLOOR) / FULL_SCALE);
        final float over = levelDb - COMP_THRESHOLD_DB;
        final float yg;
        if (2.0f * over <= -COMP_KNEE_DB) {
            yg = levelDb;
        } else if (2.0f * over >= COMP_KNEE_DB) {
            yg = COMP_THRESHOLD_DB + over / COMP_RATIO;
        } else {
            final float t = over + COMP_KNEE_DB * 0.5f;
            yg = levelDb + ((1.0f / COMP_RATIO) - 1.0f) * t * t / (2.0f * COMP_KNEE_DB);
        }
        final float xl = levelDb - yg; // gain reduction, dB >= 0
        final float rel = compAlphaR * compY1[ch] + (1.0f - compAlphaR) * xl;
        compY1[ch] = Math.max(xl, rel);
        compYl[ch] = compAlphaA * compYl[ch] + (1.0f - compAlphaA) * compY1[ch];
        return (float) Math.pow(10.0, (mkDb - compYl[ch]) * 0.05);
    }

    private static float clamp(float v, float lo, float hi) {
        return Math.min(Math.max(v, lo), hi);
    }

    private void setupFilters(int fsHz) {
        final float fs = (float) fsHz;
        int n = 0;
        n = putCoef(n, highpass(HP_FREQ, HP_Q1, fs));
        n = putCoef(n, highpass(HP_FREQ, HP_Q2, fs));
        n = putCoef(n, lowShelf(SHELF_FREQ, SHELF_GAIN_DB, fs));
        for (int i = 0; i < 4; i++) {
            n = putCoef(n, peaking(PEAK_FREQ[i], PEAK_GAIN_DB[i], PEAK_Q[i], fs));
        }
        compAlphaA = alphaFromMs(COMP_ATTACK_MS, fsHz);
        compAlphaR = alphaFromMs(COMP_RELEASE_MS, fsHz);
        limAlphaA = alphaFromMs(LIM_ATTACK_MS, fsHz);
        limAlphaR = alphaFromMs(LIM_RELEASE_MS, fsHz);
        dynSmoothAlpha = alphaFromMs(DYN_SMOOTH_MS, fsHz);
    }

    private void resetState() {
        for (int ch = 0; ch < MAX_CHANNELS; ch++) {
            for (int f = 0; f < NUM_EQ_STAGES; f++) {
                eqX1[ch][f] = eqX2[ch][f] = eqY1[ch][f] = eqY2[ch][f] = 0.0f;
            }
            compY1[ch] = 0.0f;
            compYl[ch] = 0.0f;
            limGr[ch] = 1.0f;
        }
        dynMeterDb = 0.0f;
        dynMeterPrimed = false;
        dynTrimDb = 0.0f;
        dynTrimLin = 1.0f;
    }

    private int putCoef(int idx, float[] c) {
        cB0[idx] = c[0];
        cB1[idx] = c[1];
        cB2[idx] = c[2];
        cA1[idx] = c[3];
        cA2[idx] = c[4];
        return idx + 1;
    }

    private static float[] identity() {
        return new float[]{1.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    }

    // RBJ Audio EQ Cookbook, normalized by a0. A band too close to Nyquist
    // collapses to identity.
    private static float[] highpass(float fc, float q, float fs) {
        if (fc >= 0.45f * fs) return identity();
        final float w0 = 2.0f * (float) Math.PI * fc / fs;
        final float cw = (float) Math.cos(w0);
        final float alpha = (float) Math.sin(w0) / (2.0f * q);
        final float a0 = 1.0f + alpha;
        return new float[]{
                (1.0f + cw) / 2.0f / a0, -(1.0f + cw) / a0,
                (1.0f + cw) / 2.0f / a0, -2.0f * cw / a0, (1.0f - alpha) / a0};
    }

    private static float[] lowShelf(float fc, float gainDb, float fs) {
        if (fc >= 0.45f * fs) return identity();
        final float A = (float) Math.pow(10.0, gainDb / 40.0);
        final float w0 = 2.0f * (float) Math.PI * fc / fs;
        final float cw = (float) Math.cos(w0);
        final float alpha = (float) Math.sin(w0) / 2.0f * (float) Math.sqrt(2.0); // S=1
        final float sqA2a = 2.0f * (float) Math.sqrt(A) * alpha;
        final float a0 = (A + 1.0f) + (A - 1.0f) * cw + sqA2a;
        return new float[]{
                A * ((A + 1.0f) - (A - 1.0f) * cw + sqA2a) / a0,
                2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw) / a0,
                A * ((A + 1.0f) - (A - 1.0f) * cw - sqA2a) / a0,
                -2.0f * ((A - 1.0f) + (A + 1.0f) * cw) / a0,
                ((A + 1.0f) + (A - 1.0f) * cw - sqA2a) / a0};
    }

    private static float[] peaking(float fc, float gainDb, float q, float fs) {
        if (fc >= 0.45f * fs) return identity();
        final float A = (float) Math.pow(10.0, gainDb / 40.0);
        final float w0 = 2.0f * (float) Math.PI * fc / fs;
        final float cw = (float) Math.cos(w0);
        final float alpha = (float) Math.sin(w0) / (2.0f * q);
        final float a0 = 1.0f + alpha / A;
        return new float[]{
                (1.0f + alpha * A) / a0, -2.0f * cw / a0,
                (1.0f - alpha * A) / a0, -2.0f * cw / a0,
                (1.0f - alpha / A) / a0};
    }

    private static float alphaFromMs(float ms, int fs) {
        final float t = ms * 0.001f * (float) fs;
        return t <= 0.0f ? 0.0f : (float) Math.exp(-1.0f / t);
    }

    /**
     * Soft limiter, C1-continuous at the knee, asymptotes to +/-LEGACY_CEILING
     * so the signal can never clip. Transparent below the knee.
     */
    private static float softLimitLegacy(float x) {
        final float ax = Math.abs(x);
        if (ax <= LEGACY_KNEE) {
            return x;
        }
        final float over = ax - LEGACY_KNEE;
        final float limited = LEGACY_KNEE + LEGACY_RANGE * (float) Math.tanh(over / LEGACY_RANGE);
        return x < 0.0f ? -limited : limited;
    }

    private static float softLimitSafety(float x) {
        final float ax = Math.abs(x);
        if (ax <= SAFETY_KNEE) {
            return x;
        }
        final float over = ax - SAFETY_KNEE;
        final float limited = SAFETY_KNEE + SAFETY_RANGE * (float) Math.tanh(over / SAFETY_RANGE);
        return x < 0.0f ? -limited : limited;
    }
}
