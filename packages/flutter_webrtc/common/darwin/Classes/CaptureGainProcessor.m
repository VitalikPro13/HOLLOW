#import "CaptureGainProcessor.h"

#import <WebRTC/WebRTC.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>

// Port of common/cpp/src/flutter_capture_gain_processor.cc — keep in sync.
// WebRTC's APM delivers float PCM in int16 scale (~ +/-32768), not +/-1.0;
// every dBFS figure below is relative to 32768. The darwin wrapper hands
// FULLBAND per-channel data (no split-band path needed here).

static const float kFullScale = 32768.0f;

// --- Legacy (enhance OFF) path: flat gain + -3 dBFS soft limiter. -----------
static const float kLegacyCeiling = 0.7079f * kFullScale;  // ~23197
static const float kLegacyKnee = 0.6f * kLegacyCeiling;
static const float kLegacyRange = kLegacyCeiling - kLegacyKnee;

// --- Enhance path ------------------------------------------------------------
// The mic-gain slider's "100%" is a linear 2.0 (kMicGainDisplayUnit); in
// enhance mode the chain owns the loudness so the slider is a trim: gain*0.5.
static const float kEnhanceTrimScale = 0.5f;

// EQ (Vitalik's Adobe Audition curve).
static const float kHpFreq = 100.0f;
static const float kHpQ1 = 0.54119610f;  // 4th-order Butterworth cascade
static const float kHpQ2 = 1.30656296f;
static const float kShelfFreq = 110.0f;
static const float kShelfGainDb = 6.0f;
static const float kPeakFreq[4] = {291.0f, 3000.0f, 7005.0f, 12000.0f};
static const float kPeakGainDb[4] = {-3.0f, 2.0f, 3.5f, 1.5f};
static const float kPeakQ[4] = {1.5f, 1.5f, 2.0f, 2.0f};

// Compressor: -24 dBFS threshold, 3:1, 10/100 ms, 6 dB knee. Makeup gain is
// RUNTIME-set (_makeupDb, the user's "strength" knob); 12 dB is its default.
// Pass 2 / RVox retune 2026-07-06: -18 -> -24 so the servo's -21 dBFS point
// sits above threshold and the compressor actually works (crest-factor
// reduction). project_voice_agc_loudness_rvox. KEEP IN SYNC w/ the C++/Java ports.
static const float kCompThresholdDb = -24.0f;
static const float kCompRatio = 3.0f;
static const float kCompAttackMs = 10.0f;
static const float kCompReleaseMs = 100.0f;
static const float kCompKneeDb = 6.0f;

// Limiter: -1 dBFS ceiling, gain-smoothed, plus a tanh safety net.
static const float kLimCeiling = 0.8913f * kFullScale;  // ~29206
static const float kLimAttackMs = 1.0f;
static const float kLimReleaseMs = 100.0f;
static const float kSafetyKnee = 0.85f * kLimCeiling;
static const float kSafetyRange = kLimCeiling - kSafetyKnee;

// Dynamic mode: a slow speech-gated RMS meter servos ONE input trim so any
// mic lands at the calibrated speech level (~-28 dBFS RMS at the compressor
// input — the Shure MV6 golden reference, 2026-07-02). Frame-rate decisions,
// dB slew limits, per-sample de-zipper; manual gain/strength are ignored.
// Pass 2 / RVox retune 2026-07-06: -28 -> -21 target + 3.6 -> 9 makeup -> ~-16
// LUFS out (voice standard). With WebRTC AGC off the raw mic is hotter so the
// servo mostly cuts to reach -21 (has -20 dB cut range). KEEP IN SYNC.
static const float kDynTargetRmsDb = -21.0f;
static const float kDynMakeupDb = 12.5f;  // -> -16 dBFS out (harness-verified)
static const float kDynSpeechFloorDb = -55.0f;
static const float kDynMeterTauSec = 2.0f;
static const float kDynUpDbPerSec = 3.0f;
static const float kDynDownDbPerSec = 9.0f;
static const float kDynTrimMinDb = -20.0f;  // cut range wider than boost
static const float kDynTrimMaxDb = 12.0f;
static const float kDynSmoothMs = 5.0f;
#define kMaxTrimFrames 1024

// Crackle insurance.
static const float kDenormal = 1e-15f;
static const float kLogFloor = 1e-9f;

static const int kMaxChannels = 2;
static const int kNumEqStages = 7;  // hp1, hp2, shelf, 291, 3k, 7k, 12k

typedef struct {
  float b0, b1, b2, a1, a2;
  float x1, x2, y1, y2;
} Biquad;

typedef struct {
  Biquad eq[7];
  float comp_y1;  // decoupled detector intermediate (dB)
  float comp_yl;  // smoothed gain reduction (dB)
  float lim_gr;   // limiter smoothed linear gain
} ChannelState;

static inline float SoftLimitLegacy(float x) {
  const float ax = fabsf(x);
  if (ax <= kLegacyKnee) {
    return x;
  }
  const float over = ax - kLegacyKnee;
  const float limited = kLegacyKnee + kLegacyRange * tanhf(over / kLegacyRange);
  return x < 0.0f ? -limited : limited;
}

static inline float SoftLimitSafety(float x) {
  const float ax = fabsf(x);
  if (ax <= kSafetyKnee) {
    return x;
  }
  const float over = ax - kSafetyKnee;
  const float limited = kSafetyKnee + kSafetyRange * tanhf(over / kSafetyRange);
  return x < 0.0f ? -limited : limited;
}

static inline float AlphaFromMs(float ms, int fs) {
  const float t = ms * 0.001f * (float)fs;
  return t <= 0.0f ? 0.0f : expf(-1.0f / t);
}

typedef struct {
  float b0, b1, b2, a1, a2;
} Coef;

static Coef CoefIdentity(void) {
  Coef c = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f};
  return c;
}

// RBJ Audio EQ Cookbook, normalized by a0. A band too close to Nyquist
// collapses to identity.
static Coef CoefHighpass(float fc, float q, float fs) {
  if (fc >= 0.45f * fs) return CoefIdentity();
  const float w0 = 2.0f * (float)M_PI * fc / fs;
  const float cw = cosf(w0);
  const float alpha = sinf(w0) / (2.0f * q);
  const float a0 = 1.0f + alpha;
  Coef c;
  c.b0 = (1.0f + cw) / 2.0f / a0;
  c.b1 = -(1.0f + cw) / a0;
  c.b2 = (1.0f + cw) / 2.0f / a0;
  c.a1 = -2.0f * cw / a0;
  c.a2 = (1.0f - alpha) / a0;
  return c;
}

static Coef CoefLowShelf(float fc, float gainDb, float fs) {
  if (fc >= 0.45f * fs) return CoefIdentity();
  const float A = powf(10.0f, gainDb / 40.0f);
  const float w0 = 2.0f * (float)M_PI * fc / fs;
  const float cw = cosf(w0);
  const float alpha = sinf(w0) / 2.0f * sqrtf(2.0f);  // shelf slope S=1
  const float sqA2a = 2.0f * sqrtf(A) * alpha;
  const float a0 = (A + 1.0f) + (A - 1.0f) * cw + sqA2a;
  Coef c;
  c.b0 = A * ((A + 1.0f) - (A - 1.0f) * cw + sqA2a) / a0;
  c.b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw) / a0;
  c.b2 = A * ((A + 1.0f) - (A - 1.0f) * cw - sqA2a) / a0;
  c.a1 = -2.0f * ((A - 1.0f) + (A + 1.0f) * cw) / a0;
  c.a2 = ((A + 1.0f) + (A - 1.0f) * cw - sqA2a) / a0;
  return c;
}

static Coef CoefPeaking(float fc, float gainDb, float q, float fs) {
  if (fc >= 0.45f * fs) return CoefIdentity();
  const float A = powf(10.0f, gainDb / 40.0f);
  const float w0 = 2.0f * (float)M_PI * fc / fs;
  const float cw = cosf(w0);
  const float alpha = sinf(w0) / (2.0f * q);
  const float a0 = 1.0f + alpha / A;
  Coef c;
  c.b0 = (1.0f + alpha * A) / a0;
  c.b1 = -2.0f * cw / a0;
  c.b2 = (1.0f - alpha * A) / a0;
  c.a1 = -2.0f * cw / a0;
  c.a2 = (1.0f - alpha / A) / a0;
  return c;
}

@implementation CaptureGainProcessor {
  _Atomic(float) _gain;
  _Atomic(BOOL) _enhance;
  _Atomic(float) _makeupDb;
  _Atomic(BOOL) _dynamic;
  ChannelState _ch[2 /* kMaxChannels */];
  int _sampleRate;
  float _compAlphaA;
  float _compAlphaR;
  float _limAlphaA;
  float _limAlphaR;
  // Dynamic-mode servo (single mic — one servo, not per-channel).
  float _dynMeterDb;
  BOOL _dynMeterPrimed;
  float _dynTrimDb;
  float _dynTrimLin;
  float _dynSmoothAlpha;
  // Per-sample trim trace, shared time-aligned across channels.
  float _trimBuf[kMaxTrimFrames];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    atomic_init(&_gain, 1.0f);
    atomic_init(&_enhance, NO);
    atomic_init(&_makeupDb, 12.0f);
    atomic_init(&_dynamic, NO);
    _sampleRate = 48000;
    [self setupFilters:_sampleRate];
    [self resetState];
  }
  return self;
}

- (void)setGain:(float)gain {
  atomic_store_explicit(&_gain, gain, memory_order_relaxed);
}

- (void)setEnhance:(BOOL)enabled {
  atomic_store_explicit(&_enhance, enabled, memory_order_relaxed);
}

- (void)setEnhanceMakeup:(float)db {
  atomic_store_explicit(&_makeupDb, db, memory_order_relaxed);
}

- (void)setEnhanceDynamic:(BOOL)enabled {
  atomic_store_explicit(&_dynamic, enabled, memory_order_relaxed);
}

- (void)setupFilters:(int)sampleRate {
  const float fs = (float)sampleRate;
  Coef c[7];
  int n = 0;
  c[n++] = CoefHighpass(kHpFreq, kHpQ1, fs);
  c[n++] = CoefHighpass(kHpFreq, kHpQ2, fs);
  c[n++] = CoefLowShelf(kShelfFreq, kShelfGainDb, fs);
  for (int i = 0; i < 4; i++) {
    c[n++] = CoefPeaking(kPeakFreq[i], kPeakGainDb[i], kPeakQ[i], fs);
  }
  for (int chan = 0; chan < kMaxChannels; chan++) {
    for (int i = 0; i < kNumEqStages; i++) {
      _ch[chan].eq[i].b0 = c[i].b0;
      _ch[chan].eq[i].b1 = c[i].b1;
      _ch[chan].eq[i].b2 = c[i].b2;
      _ch[chan].eq[i].a1 = c[i].a1;
      _ch[chan].eq[i].a2 = c[i].a2;
    }
  }
  _compAlphaA = AlphaFromMs(kCompAttackMs, sampleRate);
  _compAlphaR = AlphaFromMs(kCompReleaseMs, sampleRate);
  _limAlphaA = AlphaFromMs(kLimAttackMs, sampleRate);
  _limAlphaR = AlphaFromMs(kLimReleaseMs, sampleRate);
  _dynSmoothAlpha = AlphaFromMs(kDynSmoothMs, sampleRate);
}

- (void)resetState {
  for (int chan = 0; chan < kMaxChannels; chan++) {
    for (int i = 0; i < kNumEqStages; i++) {
      _ch[chan].eq[i].x1 = _ch[chan].eq[i].x2 = 0.0f;
      _ch[chan].eq[i].y1 = _ch[chan].eq[i].y2 = 0.0f;
    }
    _ch[chan].comp_y1 = 0.0f;
    _ch[chan].comp_yl = 0.0f;
    _ch[chan].lim_gr = 1.0f;
  }
  _dynMeterDb = 0.0f;
  _dynMeterPrimed = NO;
  _dynTrimDb = 0.0f;
  _dynTrimLin = 1.0f;
}

#pragma mark - ExternalAudioProcessingDelegate

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz
                                       channels:(size_t)channels {
  (void)channels;
  if ((int)sampleRateHz > 0 && (int)sampleRateHz != _sampleRate) {
    _sampleRate = (int)sampleRateHz;
    [self setupFilters:_sampleRate];
  }
  [self resetState];
}

- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  const float gain = atomic_load_explicit(&_gain, memory_order_relaxed);
  const BOOL enhance = atomic_load_explicit(&_enhance, memory_order_relaxed);
  const BOOL dynamic = atomic_load_explicit(&_dynamic, memory_order_relaxed);
  const float makeupDb =
      dynamic ? kDynMakeupDb
              : atomic_load_explicit(&_makeupDb, memory_order_relaxed);
  const int frames = (int)audioBuffer.frames;
  const int channels = (int)audioBuffer.channels;

  if (!enhance) {
    // Legacy path — identical to the shipped flat-gain processor.
    for (int ch = 0; ch < channels; ch++) {
      float *samples = [audioBuffer rawBufferForChannel:ch];
      if (samples == NULL) {
        continue;
      }
      for (int i = 0; i < frames; i++) {
        samples[i] = SoftLimitLegacy(samples[i] * gain);
      }
    }
    return;
  }

  const float manualTrim = gain * kEnhanceTrimScale;
  const float invRatioM1 = (1.0f / kCompRatio) - 1.0f;

  // Dynamic-mode servo: frame-rate, speech-gated, measured on channel 0's
  // PRE-trim samples (the one real mic).
  float *ch0 = [audioBuffer rawBufferForChannel:0];
  if (dynamic && ch0 != NULL && frames > 0) {
    double sumsq = 0.0;
    for (int i = 0; i < frames; i++) {
      sumsq += (double)ch0[i] * (double)ch0[i];
    }
    const float rms = (float)sqrt(sumsq / (double)frames);
    const float rmsDb = 20.0f * log10f(fmaxf(rms, kLogFloor) / kFullScale);
    if (rmsDb > kDynSpeechFloorDb) {
      const float frameSec = (float)frames / (float)_sampleRate;
      if (!_dynMeterPrimed) {
        // First speech: snap straight to the right level, then servo slowly.
        _dynMeterPrimed = YES;
        _dynMeterDb = rmsDb;
        _dynTrimDb =
            fminf(fmaxf(kDynTargetRmsDb - rmsDb, kDynTrimMinDb), kDynTrimMaxDb);
      } else {
        const float meterAlpha = fminf(frameSec / kDynMeterTauSec, 1.0f);
        _dynMeterDb += meterAlpha * (rmsDb - _dynMeterDb);
        const float desired = fminf(
            fmaxf(kDynTargetRmsDb - _dynMeterDb, kDynTrimMinDb), kDynTrimMaxDb);
        float step = desired - _dynTrimDb;
        const float maxUp = kDynUpDbPerSec * frameSec;
        const float maxDown = kDynDownDbPerSec * frameSec;
        if (step > maxUp) step = maxUp;
        if (step < -maxDown) step = -maxDown;
        _dynTrimDb += step;
      }
    }
  }
  const float trimTarget =
      dynamic ? powf(10.0f, _dynTrimDb * 0.05f) : manualTrim;

  // Per-sample trim trace (de-zippered in dynamic mode; constant in manual
  // mode), shared time-aligned across channels.
  const BOOL useTrace = frames > 0 && frames <= kMaxTrimFrames;
  if (useTrace) {
    for (int i = 0; i < frames; i++) {
      _dynTrimLin += (1.0f - _dynSmoothAlpha) * (trimTarget - _dynTrimLin);
      _trimBuf[i] = _dynTrimLin;
    }
  }

  for (int ch = 0; ch < channels; ch++) {
    float *x = [audioBuffer rawBufferForChannel:ch];
    if (x == NULL) {
      continue;
    }
    // Channels beyond our state fall back to the legacy path.
    if (ch >= kMaxChannels) {
      for (int i = 0; i < frames; i++) {
        x[i] = SoftLimitLegacy(x[i] * gain);
      }
      continue;
    }
    ChannelState *s = &_ch[ch];
    for (int i = 0; i < frames; i++) {
      // Trim (per-sample trace, shared time-aligned across channels).
      float v = x[i] * (useTrace ? _trimBuf[i] : trimTarget) + kDenormal;
      // EQ: 7 fixed biquads, Direct Form I.
      for (int f = 0; f < kNumEqStages; f++) {
        Biquad *bq = &s->eq[f];
        const float y = bq->b0 * v + bq->b1 * bq->x1 + bq->b2 * bq->x2 -
                        bq->a1 * bq->y1 - bq->a2 * bq->y2 + kDenormal;
        bq->x2 = bq->x1;
        bq->x1 = v;
        bq->y2 = bq->y1;
        bq->y1 = y;
        v = y;
      }
      // Compressor: Giannoulis soft-knee gain computer + decoupled smooth
      // peak detector, single dB-domain gain, single multiply.
      const float av = fabsf(v);
      const float levelDb =
          20.0f * log10f(fmaxf(av, kLogFloor) / kFullScale);
      const float over = levelDb - kCompThresholdDb;
      float yg;
      if (2.0f * over <= -kCompKneeDb) {
        yg = levelDb;
      } else if (2.0f * over >= kCompKneeDb) {
        yg = kCompThresholdDb + over / kCompRatio;
      } else {
        const float t = over + kCompKneeDb * 0.5f;
        yg = levelDb + invRatioM1 * t * t / (2.0f * kCompKneeDb);
      }
      const float xl = levelDb - yg;  // gain reduction, dB >= 0
      const float rel = _compAlphaR * s->comp_y1 + (1.0f - _compAlphaR) * xl;
      s->comp_y1 = xl > rel ? xl : rel;
      s->comp_yl = _compAlphaA * s->comp_yl + (1.0f - _compAlphaA) * s->comp_y1;
      v *= powf(10.0f, (makeupDb - s->comp_yl) * 0.05f);
      // Limiter: gain-smoothed peak limiter into a tanh safety net.
      const float pv = fabsf(v);
      const float target = pv > kLimCeiling ? kLimCeiling / pv : 1.0f;
      if (target < s->lim_gr) {
        s->lim_gr = _limAlphaA * s->lim_gr + (1.0f - _limAlphaA) * target;
      } else {
        s->lim_gr = _limAlphaR * s->lim_gr + (1.0f - _limAlphaR) * target;
      }
      x[i] = SoftLimitSafety(v * s->lim_gr);
    }
  }
}

- (void)audioProcessingRelease {
}

@end
