#import "CaptureGainProcessor.h"

#import <WebRTC/WebRTC.h>
#import <dlfcn.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>
#import <time.h>

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

// --- Gate + upward compression (dynamic mode only) ---------------------------
// Port of the fused stage in flutter_capture_gain_processor.cc — KEEP IN
// SYNC (full design + timing rationale documented there). Sits between the
// EQ and the compressor, driven by ONE shared fast/slow envelope:
//   - upward compression (3:1 toward the speech point, capped +8 dB) lifts
//     word tails / soft speech, gated by TWO presence factors: SNR above a
//     min-statistics noise-floor tracker, and positive-only 3-8 Hz syllabic
//     modulation — boost exists only for content clearly above the mic's own
//     floor that pumps like speech;
//   - a soft downward expander (4:1 below the gate threshold, capped -14 dB)
//     cuts the between-words floor BELOW the old chain's.
static const float kUpEnvAttackMs = 1.0f;
static const float kUpEnvReleaseMs = 25.0f;
static const float kUpThresholdDb = -15.0f;  // speech envelope, harness-calibrated
static const float kUpRatio = 3.0f;
static const float kUpMaxBoostDb = 8.0f;
static const float kUpKneeDb = 6.0f;
static const float kUpBoostAttackMs = 50.0f;
static const float kUpBoostReleaseMs = 4.0f;
static const float kFloorWindowMs = 750.0f;
static const float kFloorSmoothMs = 100.0f;
static const float kSnrZeroDb = 6.0f;
static const float kSnrFullDb = 12.0f;
static const float kModSlowMs = 250.0f;
static const float kModAvgMs = 400.0f;
static const float kModClampDb = 6.0f;
static const float kModZeroDb = 1.0f;
static const float kModFullDb = 3.0f;
// Gate threshold = LOWER of the absolute ceiling and tracked-floor + 10 dB
// (absolute-only gating ate quiet speech on weak mics whose servo trim is
// pinned at +12 — see the C++ port's constants block).
static const float kGateThresholdDb = kUpThresholdDb - 17.0f;
static const float kGateAboveFloorDb = 10.0f;
static const float kGateRatio = 4.0f;
static const float kGateMaxCutDb = 14.0f;
static const float kGateKneeDb = 6.0f;
static const float kGateOpenMs = 8.0f;
static const float kGateCloseMs = 60.0f;
// RNNoise voice-probability presence: replaces SNR+modulation presence for
// the upward boost while the AI-NS engine is actively denoising (breath
// discrimination). KEEP IN SYNC with the C++ port's constants block — full
// rationale there.
static const float kVadZeroProb = 0.40f;
static const float kVadFullProb = 0.75f;

// --- De-esser (both enhance modes) -------------------------------------------
// Port of the de-esser in flutter_capture_gain_processor.cc — KEEP IN SYNC
// (design + placement rationale documented there). AFTER the compressor,
// BEFORE the limiter: split v = lp + hf at a fixed lowpass, duck ONLY hf,
// keyed on the ratio of a TRUE 24 dB/oct highpass detector to the fullband
// envelope, times a level gate.
static const float kDeEssSplitFreq = 4800.0f;
static const float kDeEssEnvAttackMs = 1.0f;
static const float kDeEssEnvReleaseMs = 40.0f;
static const float kDeEssRatioZeroDb = -10.0f;
static const float kDeEssRatioFullDb = -3.0f;
static const float kDeEssLevelFloorDb = -40.0f;
static const float kDeEssLevelRampDb = 6.0f;
static const float kDeEssMaxCutDb = 10.0f;
static const float kDeEssCutAttackMs = 2.0f;
static const float kDeEssCutReleaseMs = 40.0f;

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
  // Fused gate + upward-compression stage (dynamic mode only).
  float up_env;            // fast-attack/slow-release envelope (linear)
  float up_boost_db;       // smoothed upward boost (dB >= 0)
  float gate_cut_db;       // smoothed expander attenuation (dB >= 0)
  float mod_slow_db;       // slow envelope mean (dB) for modulation
  float mod_depth_db;      // smoothed positive syllabic modulation (dB)
  float up_floor_db;       // smoothed noise-floor estimate (dB, min stats)
  float floor_sub_min_db;  // current sub-window minimum (dB)
  float floor_prev_min_db; // previous sub-window minimum (dB)
  int floor_count;         // samples into the current sub-window
  // De-esser (both enhance modes).
  Biquad deess_lp;         // fixed split lowpass (hf = v - lp)
  Biquad deess_hp;         // detector highpass, stage 1
  Biquad deess_hp2;        // detector highpass, stage 2 (24 dB/oct)
  float de_env_hf;         // HF envelope (linear)
  float de_env_fb;         // fullband envelope (linear)
  float de_cut_db;         // smoothed HF cut (dB >= 0)
} ChannelState;

// Time constants for the gate + upward stage, recomputed per sample rate.
typedef struct {
  float env_a, env_r;       // envelope rise / fall
  float boost_up, boost_dn; // boost grows / ducks
  float gate_open, gate_close;
  float mod_slow, mod_avg;
  float floor_smooth;
  int floor_win;
} StageAlphas;

// Per-sample step of the fused gate + upward-compression stage: updates the
// channel's envelope + smoothed gains from the rectified sample and returns
// the stage gain in dB. Mirrors GateUpwardGainDb in the C++ port.
// `vadPresence` = RNNoise voice probability for this frame (-1 = absent).
static inline float GateUpwardGainDb(ChannelState *s, float av,
                                     const StageAlphas *a,
                                     float vadPresence) {
  // Envelope follower: fast rise, slow fall.
  const float ae = av > s->up_env ? a->env_a : a->env_r;
  s->up_env = ae * s->up_env + (1.0f - ae) * av + kDenormal;
  const float envDb = 20.0f * log10f(fmaxf(s->up_env, kLogFloor) / kFullScale);

  // Upward boost target: soft-knee lift below the speech point, capped.
  const float under = kUpThresholdDb - envDb;
  float bt;
  if (2.0f * under <= -kUpKneeDb) {
    bt = 0.0f;
  } else if (2.0f * under >= kUpKneeDb) {
    bt = under * (1.0f - 1.0f / kUpRatio);
  } else {
    const float t = under + kUpKneeDb * 0.5f;
    bt = (1.0f - 1.0f / kUpRatio) * t * t / (2.0f * kUpKneeDb);
  }
  bt = fminf(bt, kUpMaxBoostDb);
  // SNR presence: min-statistics floor tracker, boost only well above it.
  s->floor_sub_min_db = fminf(s->floor_sub_min_db, envDb);
  if (++s->floor_count >= a->floor_win) {
    s->floor_count = 0;
    s->floor_prev_min_db = s->floor_sub_min_db;
    s->floor_sub_min_db = envDb;
  }
  const float floorRaw = fminf(s->floor_sub_min_db, s->floor_prev_min_db);
  s->up_floor_db =
      a->floor_smooth * s->up_floor_db + (1.0f - a->floor_smooth) * floorRaw;
  float pr = (envDb - s->up_floor_db - kSnrZeroDb) / (kSnrFullDb - kSnrZeroDb);
  pr = fminf(fmaxf(pr, 0.0f), 1.0f);
  // Modulation presence state: kept warm even while the RNNoise VAD is in
  // charge, so a mid-call fallback resumes converged.
  s->mod_slow_db = a->mod_slow * s->mod_slow_db + (1.0f - a->mod_slow) * envDb;
  const float md = fminf(fmaxf(envDb - s->mod_slow_db, 0.0f), kModClampDb);
  s->mod_depth_db = a->mod_avg * s->mod_depth_db + (1.0f - a->mod_avg) * md;
  float pm = (s->mod_depth_db - kModZeroDb) / (kModFullDb - kModZeroDb);
  pm = fminf(fmaxf(pm, 0.0f), 1.0f);
  if (vadPresence >= 0.0f) {
    // RNNoise voice probability REPLACES the SNR+modulation presence
    // (breath discrimination — see the C++ port).
    float pv = (vadPresence - kVadZeroProb) / (kVadFullProb - kVadZeroProb);
    pv = fminf(fmaxf(pv, 0.0f), 1.0f);
    bt *= pv * pv * (3.0f - 2.0f * pv);
  } else {
    bt *= pr * pr * (3.0f - 2.0f * pr);
    bt *= pm * pm * (3.0f - 2.0f * pm);
  }
  const float ab = bt > s->up_boost_db ? a->boost_up : a->boost_dn;
  s->up_boost_db = ab * s->up_boost_db + (1.0f - ab) * bt;

  // Gate cut target: soft-knee downward expansion below the effective
  // threshold (floor-relative, absolute-capped).
  const float gateThresh =
      fminf(kGateThresholdDb, s->up_floor_db + kGateAboveFloorDb);
  const float underG = gateThresh - envDb;
  float gt;
  if (2.0f * underG <= -kGateKneeDb) {
    gt = 0.0f;
  } else if (2.0f * underG >= kGateKneeDb) {
    gt = underG * (kGateRatio - 1.0f);
  } else {
    const float t = underG + kGateKneeDb * 0.5f;
    gt = (kGateRatio - 1.0f) * t * t / (2.0f * kGateKneeDb);
  }
  gt = fminf(gt, kGateMaxCutDb);
  const float ag = gt > s->gate_cut_db ? a->gate_close : a->gate_open;
  s->gate_cut_db = ag * s->gate_cut_db + (1.0f - ag) * gt;

  return s->up_boost_db - s->gate_cut_db;
}

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

static Coef CoefLowpass(float fc, float q, float fs) {
  if (fc >= 0.45f * fs) return CoefIdentity();
  const float w0 = 2.0f * (float)M_PI * fc / fs;
  const float cw = cosf(w0);
  const float alpha = sinf(w0) / (2.0f * q);
  const float a0 = 1.0f + alpha;
  Coef c;
  c.b0 = (1.0f - cw) / 2.0f / a0;
  c.b1 = (1.0f - cw) / a0;
  c.b2 = (1.0f - cw) / 2.0f / a0;
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

// --- AI noise-suppression runtime binding (Hollow fork, HOLLOW_PLAN ~2008) --
// RNNoise by default, DFN3 behind engine id 1, both behind hollow_core's
// Rust format adapter (ABI v2). hollow_core builds as a DYNAMIC framework on
// both darwin platforms (its podspec force-loads libhollow_core.a), so the
// `hollow_dfn_*` C symbols exported by rust/hollow_core/src/dfn_ffi.rs are
// strip roots and visible to dlsym(RTLD_DEFAULT) once the app is loaded.
// ABI handshake guards drift; any resolution failure leaves AI NS
// gracefully unavailable.
typedef uint32_t (*HollowDfnAbiVersionFn)(void);
typedef void *(*HollowDfnCreateEngineFn)(int32_t);
typedef int32_t (*HollowDfnProcessExFn)(void *, float *, int32_t, int32_t,
                                        int32_t, int32_t);
typedef float (*HollowDfnLastVadFn)(void *);
typedef void (*HollowDfnSetF32Fn)(void *, float);

static _Atomic(HollowDfnProcessExFn) gDfnProcessEx;
static HollowDfnCreateEngineFn gDfnCreateEngine = NULL;
static HollowDfnLastVadFn gDfnLastVad = NULL;
static HollowDfnSetF32Fn gDfnSetAttenLim = NULL;
static HollowDfnSetF32Fn gDfnSetPfBeta = NULL;
static BOOL gDfnBound = NO;

static BOOL HollowDfnBind(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    HollowDfnAbiVersionFn abi =
        (HollowDfnAbiVersionFn)dlsym(RTLD_DEFAULT, "hollow_dfn_abi_version");
    if (abi == NULL) {
      NSLog(@"[hollow_dfn] hollow_core symbols not found — AI NS unavailable");
      return;
    }
    if (abi() != 3u) {
      NSLog(@"[hollow_dfn] ABI mismatch (core %u) — AI NS unavailable", abi());
      return;
    }
    HollowDfnCreateEngineFn create = (HollowDfnCreateEngineFn)dlsym(
        RTLD_DEFAULT, "hollow_dfn_create_engine");
    HollowDfnProcessExFn process =
        (HollowDfnProcessExFn)dlsym(RTLD_DEFAULT, "hollow_dfn_process_ex");
    HollowDfnLastVadFn lastVad =
        (HollowDfnLastVadFn)dlsym(RTLD_DEFAULT, "hollow_dfn_last_vad");
    HollowDfnSetF32Fn setAtten =
        (HollowDfnSetF32Fn)dlsym(RTLD_DEFAULT, "hollow_dfn_set_atten_lim");
    HollowDfnSetF32Fn setBeta = (HollowDfnSetF32Fn)dlsym(
        RTLD_DEFAULT, "hollow_dfn_set_post_filter_beta");
    if (create == NULL || process == NULL || lastVad == NULL ||
        setAtten == NULL || setBeta == NULL) {
      NSLog(@"[hollow_dfn] incomplete symbol set — AI NS unavailable");
      return;
    }
    gDfnCreateEngine = create;
    gDfnLastVad = lastVad;
    gDfnSetAttenLim = setAtten;
    gDfnSetPfBeta = setBeta;
    atomic_store_explicit(&gDfnProcessEx, process, memory_order_release);
    gDfnBound = YES;
  });
  return gDfnBound;
}

static double HollowDfnNowMs(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

@implementation CaptureGainProcessor {
  _Atomic(float) _gain;
  _Atomic(BOOL) _enhance;
  _Atomic(float) _makeupDb;
  _Atomic(BOOL) _dynamic;
  _Atomic(BOOL) _muted;
  _Atomic(BOOL) _servoHold;
  // AI noise suppression (RNNoise default / DFN3 optional) — mirrors the
  // C++ port's fields. An engine swap publishes a new handle over the old
  // one (which deliberately leaks — the audio thread may still be in it).
  _Atomic(BOOL) _noiseSuppressAi;
  _Atomic(void *) _dfnHandle;
  _Atomic(int) _dfnEngine;
  _Atomic(BOOL) _dfnCreateInFlight;
  _Atomic(BOOL) _dfnBailed;
  _Atomic(BOOL) _dfnFormatOk;
  // DFN realtime watchdog. Single writer (audio thread); atomics so the
  // status getter can report frames/cost from the platform thread.
  _Atomic(float) _dfnMsEma;
  _Atomic(int) _dfnFrames;
  // Raw capture shape as last seen (stored even with DFN off) — the status
  // getter says WHY a format was rejected.
  _Atomic(int) _lastFrameCount;
  _Atomic(int) _lastChannels;
  // Speech presence for THIS frame from the AI-NS engine (RNNoise's voice
  // probability; -1 = unavailable). Written by maybeProcessDfn and read by
  // the gate stage in the SAME process call on the audio thread — plain.
  float _vadPresence;
  // Status-getter diagnostic mirror.
  _Atomic(float) _dfnVad;
  BOOL _dfnFormatLogged;
  // -- Performance sentinels (see audioProcessingProcess:). Quiet by
  // default: each anomaly logs ONCE (latched BOOL); counters ride the
  // status map. Atomics: single audio-thread writer, status getter reads
  // from the platform thread. KEEP IN SYNC with the C++ and Java ports.
  _Atomic(float) _chainMsEma;
  _Atomic(int) _chainFrames;
  _Atomic(int) _captureGaps;
  _Atomic(int) _worstGapMs;
  BOOL _chainOverrunLogged;
  BOOL _captureGapLogged;
  // Last process entry (ms clock, audio thread only; 0 = fresh stream so
  // idle time between capture sessions never counts as a gap).
  double _lastProcessMs;
  ChannelState _ch[2 /* kMaxChannels */];
  int _sampleRate;
  float _compAlphaA;
  float _compAlphaR;
  float _limAlphaA;
  float _limAlphaR;
  StageAlphas _stage;  // gate + upward stage time constants
  // De-esser time constants.
  float _deEnvAlphaA;
  float _deEnvAlphaR;
  float _deCutAlphaA;
  float _deCutAlphaR;
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
    atomic_init(&_muted, NO);
    atomic_init(&_servoHold, NO);
    atomic_init(&_noiseSuppressAi, NO);
    atomic_init(&_dfnHandle, NULL);
    atomic_init(&_dfnEngine, -1);
    atomic_init(&_dfnCreateInFlight, NO);
    atomic_init(&_dfnBailed, NO);
    atomic_init(&_dfnFormatOk, YES);
    atomic_init(&_dfnMsEma, 0.0f);
    atomic_init(&_dfnFrames, 0);
    atomic_init(&_lastFrameCount, 0);
    atomic_init(&_lastChannels, 0);
    _vadPresence = -1.0f;
    atomic_init(&_dfnVad, -1.0f);
    _dfnFormatLogged = NO;
    atomic_init(&_chainMsEma, 0.0f);
    atomic_init(&_chainFrames, 0);
    atomic_init(&_captureGaps, 0);
    atomic_init(&_worstGapMs, 0);
    _chainOverrunLogged = NO;
    _captureGapLogged = NO;
    _lastProcessMs = 0.0;
    _sampleRate = 48000;
    [self setupFilters:_sampleRate];
    [self resetState];
  }
  return self;
}

- (void)setGain:(float)gain {
  atomic_store_explicit(&_gain, gain, memory_order_relaxed);
}

- (void)setNoiseSuppressAi:(BOOL)enabled
                    engine:(int)engine
                attenLimDb:(float)attenLimDb
            postFilterBeta:(float)postFilterBeta {
  atomic_store_explicit(&_noiseSuppressAi, enabled, memory_order_relaxed);
  if (!enabled || !HollowDfnBind()) {
    return;
  }
  void *handle = atomic_load_explicit(&_dfnHandle, memory_order_acquire);
  if (handle != NULL &&
      atomic_load_explicit(&_dfnEngine, memory_order_relaxed) == engine) {
    // Right engine already loaded: live parameter update (lock-free
    // staging in the FFI).
    gDfnSetAttenLim(handle, attenLimDb);
    gDfnSetPfBeta(handle, postFilterBeta);
    return;
  }
  BOOL expected = NO;
  if (!atomic_compare_exchange_strong(&_dfnCreateInFlight, &expected, YES)) {
    return;  // create already in flight
  }
  // One-shot background engine create (RNNoise instant; DFN3 100-500 ms) —
  // NEVER the audio thread. A different-engine call is a LIVE SWAP: the
  // new handle is published over the old one, latches reset.
  __weak CaptureGainProcessor *weakSelf = self;
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void *h = gDfnCreateEngine != NULL ? gDfnCreateEngine(engine) : NULL;
        CaptureGainProcessor *strongSelf = weakSelf;
        if (strongSelf == NULL) {
          return;
        }
        if (h != NULL) {
          gDfnSetAttenLim(h, attenLimDb);
          gDfnSetPfBeta(h, postFilterBeta);
          // Publish + reset the latches/watchdog: a new engine deserves a
          // fresh verdict.
          atomic_store_explicit(&strongSelf->_dfnFrames, 0,
                                memory_order_relaxed);
          atomic_store_explicit(&strongSelf->_dfnMsEma, 0.0f,
                                memory_order_relaxed);
          atomic_store_explicit(&strongSelf->_dfnBailed, NO,
                                memory_order_relaxed);
          atomic_store_explicit(&strongSelf->_dfnFormatOk, YES,
                                memory_order_relaxed);
          atomic_store_explicit(&strongSelf->_dfnEngine, engine,
                                memory_order_relaxed);
          atomic_store_explicit(&strongSelf->_dfnHandle, h,
                                memory_order_release);
        }
        atomic_store_explicit(&strongSelf->_dfnCreateInFlight, NO,
                              memory_order_release);
      });
}

- (NSDictionary<NSString *, NSNumber *> *)noiseSuppressAiStatus {
  const BOOL available = gDfnBound;
  const BOOL enabled =
      atomic_load_explicit(&_noiseSuppressAi, memory_order_relaxed);
  const BOOL ready =
      atomic_load_explicit(&_dfnHandle, memory_order_acquire) != NULL;
  const BOOL bailed =
      atomic_load_explicit(&_dfnBailed, memory_order_relaxed);
  const BOOL formatOk =
      atomic_load_explicit(&_dfnFormatOk, memory_order_relaxed);
  return @{
    @"available" : @(available),
    @"enabled" : @(enabled),
    @"ready" : @(ready),
    @"bailed" : @(bailed),
    @"formatOk" : @(formatOk),
    @"active" : @(enabled && ready && !bailed && formatOk),
    // frames > 0 is the proof the engine is actually denoising the mic.
    @"frames" : @(atomic_load_explicit(&_dfnFrames, memory_order_relaxed)),
    @"emaMs" : @((double)atomic_load_explicit(&_dfnMsEma,
                                              memory_order_relaxed)),
    // Engine id of the published handle (-1 = none): 0 RNNoise, 1 DFN3.
    @"engine" : @(atomic_load_explicit(&_dfnEngine, memory_order_relaxed)),
    // Voice probability of the last denoised frame (-1 = none) — proves
    // the RNNoise VAD is feeding the chain's speech gate.
    @"vad" : @((double)atomic_load_explicit(&_dfnVad, memory_order_relaxed)),
    // Raw capture shape — says WHY a format was rejected.
    @"rate" : @(_sampleRate),
    @"channels" :
        @(atomic_load_explicit(&_lastChannels, memory_order_relaxed)),
    @"bufferSize" :
        @(atomic_load_explicit(&_lastFrameCount, memory_order_relaxed)),
    // Performance sentinels: smoothed WHOLE-chain cost per 10 ms frame,
    // and capture-gap count/worst (>30 ms between process calls).
    @"chainEmaMs" : @((double)atomic_load_explicit(&_chainMsEma,
                                                   memory_order_relaxed)),
    @"captureGaps" :
        @(atomic_load_explicit(&_captureGaps, memory_order_relaxed)),
    @"worstGapMs" :
        @(atomic_load_explicit(&_worstGapMs, memory_order_relaxed)),
  };
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

// Mic muted: FREEZE the dynamic servo's meter/trim adaptation. The APM
// capture path keeps running on real mic input while the outbound track is
// disabled, and whatever the mic hears while muted (e.g. shared music on the
// speakers) is by definition not call speech — adapting to it slams the trim
// down and the voice comes back buried on unmute. Thread-safe, live.
- (void)setMuted:(BOOL)muted {
  atomic_store_explicit(&_muted, muted, memory_order_relaxed);
}

// Screen-share audio is ACTIVE somewhere on this device (sharing WITH audio,
// or playing a received share): room/speaker bleed passes the servo's speech
// floor continuously, so even between unmuted words it would re-calibrate to
// the music and bury the voice. Freeze adaptation for the whole share; the
// pre-share speech calibration holds. Thread-safe, live.
- (void)setServoHold:(BOOL)hold {
  atomic_store_explicit(&_servoHold, hold, memory_order_relaxed);
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
  // De-esser split + 24 dB/oct detector (see the C++ port for rationale).
  const Coef dl = CoefLowpass(kDeEssSplitFreq, 0.70710678f, fs);
  const Coef dh = CoefHighpass(kDeEssSplitFreq, 0.70710678f, fs);
  for (int chan = 0; chan < kMaxChannels; chan++) {
    Biquad *bq = &_ch[chan].deess_lp;
    bq->b0 = dl.b0; bq->b1 = dl.b1; bq->b2 = dl.b2;
    bq->a1 = dl.a1; bq->a2 = dl.a2;
    Biquad *hps[2] = {&_ch[chan].deess_hp, &_ch[chan].deess_hp2};
    for (int i = 0; i < 2; i++) {
      hps[i]->b0 = dh.b0; hps[i]->b1 = dh.b1; hps[i]->b2 = dh.b2;
      hps[i]->a1 = dh.a1; hps[i]->a2 = dh.a2;
    }
  }
  _compAlphaA = AlphaFromMs(kCompAttackMs, sampleRate);
  _compAlphaR = AlphaFromMs(kCompReleaseMs, sampleRate);
  _limAlphaA = AlphaFromMs(kLimAttackMs, sampleRate);
  _limAlphaR = AlphaFromMs(kLimReleaseMs, sampleRate);
  _dynSmoothAlpha = AlphaFromMs(kDynSmoothMs, sampleRate);
  _stage.env_a = AlphaFromMs(kUpEnvAttackMs, sampleRate);
  _stage.env_r = AlphaFromMs(kUpEnvReleaseMs, sampleRate);
  _stage.boost_up = AlphaFromMs(kUpBoostAttackMs, sampleRate);
  _stage.boost_dn = AlphaFromMs(kUpBoostReleaseMs, sampleRate);
  _stage.gate_open = AlphaFromMs(kGateOpenMs, sampleRate);
  _stage.gate_close = AlphaFromMs(kGateCloseMs, sampleRate);
  _stage.mod_slow = AlphaFromMs(kModSlowMs, sampleRate);
  _stage.mod_avg = AlphaFromMs(kModAvgMs, sampleRate);
  _stage.floor_smooth = AlphaFromMs(kFloorSmoothMs, sampleRate);
  _stage.floor_win = (int)(kFloorWindowMs * 0.001f * (float)sampleRate);
  if (_stage.floor_win < 1) _stage.floor_win = 1;
  _deEnvAlphaA = AlphaFromMs(kDeEssEnvAttackMs, sampleRate);
  _deEnvAlphaR = AlphaFromMs(kDeEssEnvReleaseMs, sampleRate);
  _deCutAlphaA = AlphaFromMs(kDeEssCutAttackMs, sampleRate);
  _deCutAlphaR = AlphaFromMs(kDeEssCutReleaseMs, sampleRate);
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
    _ch[chan].up_env = 0.0f;
    _ch[chan].up_boost_db = 0.0f;
    // Boot in the gated state (a stream starts in silence) — the gate opens
    // on the first word instead of popping the pre-speech floor.
    _ch[chan].gate_cut_db = kGateMaxCutDb;
    _ch[chan].mod_slow_db = -80.0f;
    _ch[chan].mod_depth_db = 0.0f;
    // Floor tracker boots HIGH: no boost until real minima are observed.
    _ch[chan].up_floor_db = 10.0f;
    _ch[chan].floor_sub_min_db = 10.0f;
    _ch[chan].floor_prev_min_db = 10.0f;
    _ch[chan].floor_count = 0;
    Biquad *des[3] = {&_ch[chan].deess_lp, &_ch[chan].deess_hp,
                      &_ch[chan].deess_hp2};
    for (int i = 0; i < 3; i++) {
      des[i]->x1 = des[i]->x2 = des[i]->y1 = des[i]->y2 = 0.0f;
    }
    _ch[chan].de_env_hf = 0.0f;
    _ch[chan].de_env_fb = 0.0f;
    _ch[chan].de_cut_db = 0.0f;
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
  // Fresh stream: idle time since the last capture session is not a
  // capture gap (the gap sentinel only measures WITHIN a stream).
  _lastProcessMs = 0.0;
}

// Head-of-chain AI-NS step (audio thread only). Keep behavior-identical to
// FlutterCaptureGainProcessor::ProcessDfn in the C++ port. darwin's
// RTCAudioBuffer hands channels as SEPARATE buffers, so channel 0 goes to
// the Rust adapter as MONO with its raw rate (the adapter resamples 16 kHz;
// 48 kHz is direct) and the stereo dup-copy stays local — voice-call
// stereo is virtually always duplicated mono. rc 4 = shape the adapter
// can't convert (frame untouched, latch formatOk for the WebRTC-NS
// fallback); other nonzero = engine error (latch session bypass).
- (void)maybeProcessDfn:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer
                 frames:(int)frames
               channels:(int)channels {
  // Shape breadcrumbs for the status getter (stored even with AI NS off).
  atomic_store_explicit(&_lastFrameCount, frames, memory_order_relaxed);
  atomic_store_explicit(&_lastChannels, channels, memory_order_relaxed);
  // Default: no engine VAD this frame — every early-out below leaves the
  // gate stage on its own SNR+modulation presence.
  _vadPresence = -1.0f;
  atomic_store_explicit(&_dfnVad, -1.0f, memory_order_relaxed);
  if (!atomic_load_explicit(&_noiseSuppressAi, memory_order_relaxed) ||
      atomic_load_explicit(&_dfnBailed, memory_order_relaxed)) {
    return;
  }
  void *handle = atomic_load_explicit(&_dfnHandle, memory_order_acquire);
  if (handle == NULL) {
    return;  // engine still loading (or unavailable) — pass through
  }
  float *ch0 = [audioBuffer rawBufferForChannel:0];
  if (ch0 == NULL) {
    return;
  }
  HollowDfnProcessExFn process =
      atomic_load_explicit(&gDfnProcessEx, memory_order_relaxed);
  if (process == NULL) {
    return;
  }
  const double t0 = HollowDfnNowMs();
  const int rc = process(handle, ch0, frames, 1, _sampleRate, 1);
  if (rc == 0 && channels >= 2) {
    float *ch1 = [audioBuffer rawBufferForChannel:1];
    if (ch1 != NULL) {
      memcpy(ch1, ch0, (size_t)frames * sizeof(float));
    }
  }
  const double ms = HollowDfnNowMs() - t0;
  if (rc == 4) {
    atomic_store_explicit(&_dfnFormatOk, NO, memory_order_relaxed);
    if (!_dfnFormatLogged) {
      _dfnFormatLogged = YES;
      NSLog(@"[hollow_dfn] unsupported capture shape (rate=%d ch=%d "
            @"frames=%d) — AI NS bypassed",
            _sampleRate, channels, frames);
    }
    return;
  }
  atomic_store_explicit(&_dfnFormatOk, YES, memory_order_relaxed);
  if (rc != 0) {
    atomic_store_explicit(&_dfnBailed, YES, memory_order_relaxed);
    NSLog(@"[hollow_dfn] process rc=%d — bypassed for session", rc);
    return;
  }
  // Frame denoised: pick up the engine's voice probability for the gate
  // stage (RNNoise supplies one; DFN3 returns -1 -> fallback gating).
  _vadPresence = gDfnLastVad != NULL ? gDfnLastVad(handle) : -1.0f;
  atomic_store_explicit(&_dfnVad, _vadPresence, memory_order_relaxed);
  // Realtime watchdog: EMA of per-frame cost, 100-frame warmup grace.
  // Budget is 10 ms; sustained >6 ms latches bypass (matters on phones).
  const int frames =
      atomic_load_explicit(&_dfnFrames, memory_order_relaxed) + 1;
  atomic_store_explicit(&_dfnFrames, frames, memory_order_relaxed);
  const float ema =
      frames == 1
          ? (float)ms
          : 0.98f * atomic_load_explicit(&_dfnMsEma, memory_order_relaxed) +
                0.02f * (float)ms;
  atomic_store_explicit(&_dfnMsEma, ema, memory_order_relaxed);
  if (frames > 100 && ema > 6.0f) {
    atomic_store_explicit(&_dfnBailed, YES, memory_order_relaxed);
    NSLog(@"[hollow_dfn] realtime overrun (EMA %.2f ms/frame) — bypassed "
          @"for session",
          ema);
  }
}

- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  // [SENTINEL] capture-gap detector: >30 ms between process calls (3 lost
  // 10 ms frames) = a HAL stall (the mute-churn signature) seen from the
  // audio side. Log-once; counter + worst ride the status map. KEEP IN
  // SYNC with the C++ and Java ports.
  const double chainT0 = HollowDfnNowMs();
  if (_lastProcessMs > 0) {
    const double gapMs = chainT0 - _lastProcessMs;
    if (gapMs > 30.0) {
      atomic_store_explicit(
          &_captureGaps,
          atomic_load_explicit(&_captureGaps, memory_order_relaxed) + 1,
          memory_order_relaxed);
      if ((int)gapMs >
          atomic_load_explicit(&_worstGapMs, memory_order_relaxed)) {
        atomic_store_explicit(&_worstGapMs, (int)gapMs,
                              memory_order_relaxed);
      }
      if (!_captureGapLogged) {
        _captureGapLogged = YES;
        NSLog(@"[SENTINEL] capture gap %.0fms (first this session; "
              @"counting further gaps in status)",
              gapMs);
      }
    }
  }
  _lastProcessMs = chainT0;

  [self processChain:audioBuffer];

  // [SENTINEL] whole-chain cost EMA — same pattern as the DFN watchdog
  // (EMA, 100-frame warmup grace) but for the ENTIRE process chain.
  // Budget is 10 ms/frame; sustained >2 ms is an anomaly worth one line.
  // Never bails — the chain stays live.
  const float chainMs = (float)(HollowDfnNowMs() - chainT0);
  const int chainFrames =
      atomic_load_explicit(&_chainFrames, memory_order_relaxed) + 1;
  atomic_store_explicit(&_chainFrames, chainFrames, memory_order_relaxed);
  const float chainEma =
      chainFrames == 1
          ? chainMs
          : 0.98f * atomic_load_explicit(&_chainMsEma,
                                         memory_order_relaxed) +
                0.02f * chainMs;
  atomic_store_explicit(&_chainMsEma, chainEma, memory_order_relaxed);
  if (!_chainOverrunLogged && chainFrames > 100 && chainEma > 2.0f) {
    _chainOverrunLogged = YES;
    NSLog(@"[SENTINEL] audio chain sustained %.2f ms/frame (10 ms budget)",
          chainEma);
  }
}

// The actual per-frame chain (AI-NS + gain/enhance stages).
// audioProcessingProcess: is a thin sentinel wrapper around this so the
// whole-chain cost is measured across every early return.
- (void)processChain:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  const float gain = atomic_load_explicit(&_gain, memory_order_relaxed);
  const BOOL enhance = atomic_load_explicit(&_enhance, memory_order_relaxed);
  const BOOL dynamic = atomic_load_explicit(&_dynamic, memory_order_relaxed);
  const BOOL muted = atomic_load_explicit(&_muted, memory_order_relaxed);
  const BOOL servoHold = atomic_load_explicit(&_servoHold, memory_order_relaxed);
  const float makeupDb =
      dynamic ? kDynMakeupDb
              : atomic_load_explicit(&_makeupDb, memory_order_relaxed);
  const int frames = (int)audioBuffer.frames;
  const int channels = (int)audioBuffer.channels;

  // AI noise suppression (DFN3) — HEAD of the chain, post-APM-AEC, before
  // trim/EQ, both enhance modes AND the legacy path. Mirrors the C++ port:
  // only 48 kHz mono 10 ms frames are processable; anything else passes
  // through and flips the format flag for the Dart fallback logic.
  [self maybeProcessDfn:audioBuffer frames:frames channels:channels];

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
  // FROZEN while muted and while share audio is active on this device —
  // room bleed (shared music on speakers) passes the speech floor and
  // adapting to non-speech buries the voice.
  float *ch0 = [audioBuffer rawBufferForChannel:0];
  if (dynamic && ch0 != NULL && frames > 0 && !muted && !servoHold) {
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
      // Gate + upward compression (dynamic mode only) between EQ and
      // compressor: gate BEFORE the compressor so its makeup can never lift
      // the pause noise floor.
      if (dynamic) {
        v *= powf(10.0f,
                  GateUpwardGainDb(s, fabsf(v), &_stage, _vadPresence) * 0.05f);
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
      // De-esser (constants block above; mirrors the C++ port): split
      // v = lp + hf, duck ONLY hf, keyed on the 24 dB/oct HF detector to
      // fullband envelope ratio with a level gate.
      {
        Biquad *dl = &s->deess_lp;
        const float lp = dl->b0 * v + dl->b1 * dl->x1 + dl->b2 * dl->x2 -
                         dl->a1 * dl->y1 - dl->a2 * dl->y2 + kDenormal;
        dl->x2 = dl->x1; dl->x1 = v; dl->y2 = dl->y1; dl->y1 = lp;
        const float hf = v - lp;
        Biquad *dh = &s->deess_hp;
        const float hp1 = dh->b0 * v + dh->b1 * dh->x1 + dh->b2 * dh->x2 -
                          dh->a1 * dh->y1 - dh->a2 * dh->y2 + kDenormal;
        dh->x2 = dh->x1; dh->x1 = v; dh->y2 = dh->y1; dh->y1 = hp1;
        Biquad *dh2 = &s->deess_hp2;
        const float hp = dh2->b0 * hp1 + dh2->b1 * dh2->x1 +
                         dh2->b2 * dh2->x2 - dh2->a1 * dh2->y1 -
                         dh2->a2 * dh2->y2 + kDenormal;
        dh2->x2 = dh2->x1; dh2->x1 = hp1; dh2->y2 = dh2->y1; dh2->y1 = hp;
        const float ahf = fabsf(hp);
        const float afb = fabsf(v);
        const float ah = ahf > s->de_env_hf ? _deEnvAlphaA : _deEnvAlphaR;
        s->de_env_hf = ah * s->de_env_hf + (1.0f - ah) * ahf + kDenormal;
        const float af = afb > s->de_env_fb ? _deEnvAlphaA : _deEnvAlphaR;
        s->de_env_fb = af * s->de_env_fb + (1.0f - af) * afb + kDenormal;
        const float hfDb =
            20.0f * log10f(fmaxf(s->de_env_hf, kLogFloor) / kFullScale);
        const float fbDb =
            20.0f * log10f(fmaxf(s->de_env_fb, kLogFloor) / kFullScale);
        float ra = (hfDb - fbDb - kDeEssRatioZeroDb) /
                   (kDeEssRatioFullDb - kDeEssRatioZeroDb);
        ra = fminf(fmaxf(ra, 0.0f), 1.0f);
        float lv = (fbDb - kDeEssLevelFloorDb) / kDeEssLevelRampDb;
        lv = fminf(fmaxf(lv, 0.0f), 1.0f);
        const float ct = kDeEssMaxCutDb * ra * ra * (3.0f - 2.0f * ra) * lv *
                         lv * (3.0f - 2.0f * lv);
        const float ac = ct > s->de_cut_db ? _deCutAlphaA : _deCutAlphaR;
        s->de_cut_db = ac * s->de_cut_db + (1.0f - ac) * ct;
        v = lp + hf * powf(10.0f, -s->de_cut_db * 0.05f);
      }
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
