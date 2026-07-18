#include "flutter_capture_gain_processor.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>

// MSVC: <windows.h> (pulled in transitively) defines max/min macros that
// break std::max/std::min. No-op on GCC/Clang.
#ifdef max
#undef max
#endif
#ifdef min
#undef min
#endif

// AI noise-suppression runtime binding (hollow_dfn_binding.cc).
// Forward-declared instead of included so the offline g++ chain harness can
// keep compiling this file standalone — a harness driver just defines its
// own stubs:
//   namespace hollow_dfn {
//   int ProcessFrameEx(void*, float*, int, int, int, int) { return 1; }
//   float LastVad(void*) { return -1.0f; }
//   }
namespace hollow_dfn {
int ProcessFrameEx(void* handle, float* buf, int len, int num_bands, int rate,
                   int channels);
float LastVad(void* handle);
}

namespace flutter_webrtc_plugin {

namespace {

// ---------------------------------------------------------------------------
// Tuning constants. WebRTC's APM delivers float PCM in int16 scale
// (~ +/-32768), not +/-1.0 — every dBFS figure below is relative to 32768.
// ---------------------------------------------------------------------------
constexpr float kFullScale = 32768.0f;

// --- Legacy (enhance OFF) path: flat gain + -3 dBFS soft limiter. -----------
constexpr float kLegacyCeiling = 0.7079f * kFullScale;  // -3 dBFS ~23197
constexpr float kLegacyKnee = 0.6f * kLegacyCeiling;
constexpr float kLegacyRange = kLegacyCeiling - kLegacyKnee;

// --- Enhance path ------------------------------------------------------------
// The mic-gain slider's "100%" is a linear 2.0 (kMicGainDisplayUnit in
// settings_provider.dart). In enhance mode the chain owns the loudness, so
// the slider becomes a trim around unity: trim = gain * 0.5 (100% -> 1.0).
constexpr float kEnhanceTrimScale = 0.5f;

// EQ (Vitalik's Adobe Audition curve, ported verbatim):
//   HP 100 Hz, 24 dB/oct (2 cascaded Butterworth biquads)
//   Low shelf 110 Hz +6 dB
//   Peak 291 Hz  -3.0 dB Q 1.5
//   Peak 3000 Hz +2.0 dB Q 1.5
//   Peak 7005 Hz +3.5 dB Q 2.0
//   Peak 12000 Hz +1.5 dB Q 2.0
constexpr float kHpFreq = 100.0f;
// 4th-order Butterworth cascade Qs.
constexpr float kHpQ1 = 0.54119610f;
constexpr float kHpQ2 = 1.30656296f;
constexpr float kShelfFreq = 110.0f;
constexpr float kShelfGainDb = 6.0f;
constexpr float kPeakFreq[4] = {291.0f, 3000.0f, 7005.0f, 12000.0f};
constexpr float kPeakGainDb[4] = {-3.0f, 2.0f, 3.5f, 1.5f};
constexpr float kPeakQ[4] = {1.5f, 1.5f, 2.0f, 2.0f};

// Compressor (Audition single-band): threshold -24 dBFS, 3:1, attack 10 ms,
// release 100 ms, gentle 6 dB soft knee. Makeup gain is RUNTIME-set
// (makeup_db_, the user's "strength" knob; dynamic mode uses kDynMakeupDb).
//
// Pass 2 / RVox retune (2026-07-06): threshold LOWERED -18 -> -24 so that the
// servo's -21 dBFS operating point sits ~+3 dB ABOVE threshold and the
// compressor does real gain reduction (crest-factor reduction = RVox density),
// instead of the old -28-below-a-(-18)-threshold config where it barely
// engaged and the chain topped out ~-24 LUFS. Threshold is a compressor
// property so it applies to BOTH manual and dynamic modes. See
// project_voice_agc_loudness_rvox.
constexpr float kCompThresholdDb = -24.0f;
constexpr float kCompRatio = 3.0f;
constexpr float kCompAttackMs = 10.0f;
constexpr float kCompReleaseMs = 100.0f;
constexpr float kCompKneeDb = 6.0f;

// Limiter (Audition hard limiter): -1 dBFS ceiling. No lookahead (live-call
// latency); a fast gain-smoothed limiter + a tanh safety net instead.
constexpr float kLimCeiling = 0.8913f * kFullScale;  // -1 dBFS ~29206
constexpr float kLimAttackMs = 1.0f;
constexpr float kLimReleaseMs = 100.0f;
// tanh safety net engages just below the ceiling for anything the smoothed
// limiter's finite attack lets through.
constexpr float kSafetyKnee = 0.85f * kLimCeiling;
constexpr float kSafetyRange = kLimCeiling - kSafetyKnee;

// --- Gate + upward compression (dynamic mode only) ---------------------------
// The missing RVox ingredient (HOLLOW_PLAN upward-compression item): the chain
// above is downward-only — soft/trailing speech still drops in level. This
// fused stage sits between the EQ and the downward compressor and does BOTH
// motions from ONE shared envelope:
//   - upward compression: content whose envelope falls below the speech
//     operating point is boosted toward it (3:1, capped +8 dB) — word tails,
//     leaning back, mumbling stay present. The boost target is multiplied by
//     TWO presence factors (the gated-AGC rule — boost only exists while
//     speech is present):
//       SNR presence: boost only for content clearly ABOVE the mic's own
//         tracked noise floor (min-statistics: the floor estimate follows
//         envelope minima fast and creeps up at 1 dB/s) — zero within 6 dB
//         of the floor, full 12 dB above it. This is "never lift the floor"
//         encoded directly: gap noise sits AT the floor (zero), a word tail
//         on a clean mic sits 20 dB above it (full lift). An absolute-level
//         ramp can't do this — the harness proved a noisy mic's servo-lifted
//         gap floor lands at the same absolute envelope as a clean mic's
//         word tails.
//       MODULATION presence: speech pumps its envelope 3-8 Hz; a steady
//         floor does not. Positive-only syllabic modulation (fast envelope
//         minus a 250 ms slow mean, clamped, smoothed 400 ms) — positive-only
//         so the level DROP at a word's end cannot read as modulation. Guards
//         steady noise/tones at speech-adjacent levels (the servo cranks a
//         -50 dBFS floor into the boost zone during long silences; with no
//         modulation gate that noise got +7 dB, and a steady tone grew
//         gain-wobble sidebands);
//   - downward expansion (soft gate): below the gate threshold the curve
//     reverses and CUTS (4:1, capped -14 dB) so the boost can never lift the
//     noise floor between words — the NET curve (boost minus cut) crosses
//     zero at env ~-37 dBFS and floors below that end up BELOW the old
//     chain's (down to -6 dB net). The gate is deliberately close (17 dB
//     under speech) and steep because the boost plateaus at +8: a shallower
//     2:1 gate 24 dB down would leave mediocre mic floors (-45..-50 raw)
//     inside the boost plateau, lifted at steady state — the exact failure
//     this stage must never produce.
// Anti-crackle structure mirrors the Giannoulis compressor: one branchless
// envelope follower, a continuous piecewise curve with soft knees, two
// one-pole-smoothed dB gains summed and applied with ONE multiply. No raw
// gain steps, no per-sample decisions.
// TIMING IS THE LOAD-BEARING PART: the envelope release must outrun the
// boost attack. In a word gap the envelope decays THROUGH the boost region
// toward the floor; because the boost grows slowly (~110 ms) while the
// envelope falls fast (~25 ms), the gate wins the race and gap noise never
// receives the boost. Loud onsets take the opposite path: the envelope rises
// in ~1 ms and the boost ducks in ~4 ms, so an onset arriving during a soft
// stretch is never slammed +8 dB into the limiter. Harness-verified offline
// (see HOLLOW_PLAN + memory project_voice_agc_loudness_rvox) before any
// device build.
constexpr float kUpEnvAttackMs = 1.0f;
constexpr float kUpEnvReleaseMs = 25.0f;
// Speech ENVELOPE operating point at this spot in the chain: the servo
// normalizes speech RMS to -21 dBFS at the trim, then EQ + the fast
// envelope's crest bias land normal speech at ~-15 dBFS envelope.
// Calibrated in the offline harness (measured -14.8), NOT derived on-device.
constexpr float kUpThresholdDb = -15.0f;
constexpr float kUpRatio = 3.0f;
constexpr float kUpMaxBoostDb = 8.0f;
constexpr float kUpKneeDb = 6.0f;
constexpr float kUpBoostAttackMs = 50.0f;
constexpr float kUpBoostReleaseMs = 4.0f;
// SNR presence: min-statistics floor tracker + ramp (see block comment).
// Two alternating sub-window minima; the floor estimate = min of both,
// lightly smoothed. Falls to a new quieter floor instantly, accepts a RISEN
// floor within one-to-two windows (~0.75-1.5 s — must outrun the servo's
// 3 dB/s trim slew, which raises the effective floor during long gaps), and
// REMEMBERS the gap floor straight through words, so gaps need no
// re-convergence. A rate-limited tracker failed in the harness: 1 dB/s
// couldn't follow the servo and re-boosted risen floors for ~15 s.
constexpr float kFloorWindowMs = 750.0f;
constexpr float kFloorSmoothMs = 100.0f;
constexpr float kSnrZeroDb = 6.0f;   // no boost within 6 dB of the floor
constexpr float kSnrFullDb = 12.0f;  // full boost 12 dB above it
// Modulation presence: positive-only syllabic modulation depth in dB.
constexpr float kModSlowMs = 250.0f;   // slow envelope mean
constexpr float kModAvgMs = 400.0f;    // depth smoothing (also acts as hold)
constexpr float kModClampDb = 6.0f;    // onset spikes don't overdrive the avg
constexpr float kModZeroDb = 1.0f;     // depth below this = steady noise
constexpr float kModFullDb = 3.0f;     // depth above this = clearly speech
// The gate threshold is the LOWER of an absolute ceiling and tracked-floor +
// 10 dB. Absolute-only gating ate quiet/intimate speech on mid mics (Razer
// BlackShark field report 2026-07-17): a soft close voice lands at env
// -33..-37 — under the absolute threshold — and got expanded away, while on a
// clean mic that content sits 12+ dB above the real floor and is exactly what
// the upward stage exists to lift. Floor-relative gating frees it; the
// absolute cap keeps noisy mics (floor near speech) at today's behavior, and
// gaps always sit AT the floor, 10 dB under the effective threshold → the
// between-words cut is unchanged.
constexpr float kGateThresholdDb = kUpThresholdDb - 17.0f;
constexpr float kGateAboveFloorDb = 10.0f;
constexpr float kGateRatio = 4.0f;  // soft expander, never a hard gate
constexpr float kGateMaxCutDb = 14.0f;
constexpr float kGateKneeDb = 6.0f;
// Open is fast enough for word onsets (natural onsets ramp over ~10 ms;
// harness measured -0.4 dB over an onset's first 30 ms, peak untouched) while
// staying slow enough not to track envelope ripple when content hovers right
// at the gate threshold.
constexpr float kGateOpenMs = 8.0f;
constexpr float kGateCloseMs = 60.0f;
// RNNoise voice-probability presence: while the AI-NS engine is actively
// denoising it hands the chain a per-10 ms voice probability, and that
// REPLACES the SNR+modulation presence for the upward boost — a trained
// speech model discriminates breath/turbulence from voiced speech, which
// level+modulation gating structurally cannot (the 2026-07-18 breath
// regression). Smoothstep ramp: zero boost at/below kVadZeroProb (breath
// lands ~0.1-0.4, unvoiced consonants dip mid-range but are too short for
// the 50 ms boost attack anyway), full boost at/above kVadFullProb (voiced
// speech sits 0.8+). Frame-rate steps are smoothed by the boost's own
// attack/release. -1 = unavailable -> the SNR+modulation gates take over.
constexpr float kVadZeroProb = 0.40f;
constexpr float kVadFullProb = 0.75f;

// --- De-esser (both enhance modes, fullband path only) -----------------------
// The EQ's 7 kHz presence peak sits exactly on measured sibilance (Razer raw
// capture 2026-07-17: ess centroid 6.3-6.9 kHz), so the chain brightens
// esses along with consonants — a de-esser tames what the EQ boosted. Design
// (crackle-safe, no coefficient morphing): split v = lp + hf at a FIXED
// 4.8 kHz Butterworth lowpass (hf := v - lp, so reconstruction at zero cut
// is exact by construction) and duck ONLY hf. Keyed on the HF-to-fullband
// envelope RATIO — sibilance is "HF dominates", independent of absolute
// level, so weak mics and quiet speech de-ess correctly (the gate lesson) —
// times a level gate so floor hiss (HF-heavy by nature) never triggers it.
// One smoothed dB cut, fast attack / moderate release, soft ramps only.
constexpr float kDeEssSplitFreq = 4800.0f;
constexpr float kDeEssEnvAttackMs = 1.0f;
constexpr float kDeEssEnvReleaseMs = 40.0f;
constexpr float kDeEssRatioZeroDb = -10.0f;  // HF this far under full: clean
constexpr float kDeEssRatioFullDb = -3.0f;   // HF this close to full: ess
constexpr float kDeEssLevelFloorDb = -40.0f; // below this the de-esser sleeps
constexpr float kDeEssLevelRampDb = 6.0f;
constexpr float kDeEssMaxCutDb = 10.0f;
constexpr float kDeEssCutAttackMs = 2.0f;
constexpr float kDeEssCutReleaseMs = 40.0f;

// --- Dynamic mode ------------------------------------------------------------
// Calibrated against the reference that sounded right on real hardware
// (Shure MV6, 2026-07-02): speech ~-19 dBFS RMS at the chain input with a
// 0.34x manual trim + 3.6 dB makeup, i.e. speech RMS ~-28 dBFS AT THE
// COMPRESSOR INPUT. The servo reproduces that operating point for ANY mic:
// a slow speech-gated RMS meter measures the pre-trim input and slews ONE
// trim gain toward (target - meter). Frame-rate decisions, dB-domain slew
// limits, per-sample de-zipper — deliberately NOT a per-sample leveler
// (that's what crackled in the reverted adaptive chains).
// Pass 2 / RVox retune (2026-07-06): target -28 -> -21 (speech now sits ~+3 dB
// over the lowered -24 threshold, so the compressor works) and makeup +3.6 ->
// +9 so output lands at the ~-16 LUFS voice standard. With WebRTC AGC now OFF
// the raw mic is hotter + more dynamic than when -28 was calibrated, so the
// servo mostly CUTS to reach -21 (it has -20 dB of cut range — safe).
constexpr float kDynTargetRmsDb = -21.0f;   // speech RMS at compressor input
constexpr float kDynMakeupDb = 12.5f;       // RVox makeup -> -16 dBFS RMS out
// ^ +12.5 verified in the offline g++ harness (scratchpad pass2_harness.cc):
// speech-band input from -32..-8 dBFS ALL converge to -16.1 dBFS out; a -40
// whisper only reaches -18.8. (+9 landed ~-20 — the servo + soft-knee comp at
// only +3 dB over threshold + net-subtractive EQ ate ~4 dB, so makeup carries it.)
constexpr float kDynSpeechFloorDb = -55.0f; // meter gate: ignore silence
constexpr float kDynMeterTauSec = 2.0f;     // meter integration time
constexpr float kDynUpDbPerSec = 3.0f;      // trim slew, boosting
constexpr float kDynDownDbPerSec = 9.0f;    // trim slew, cutting
// Boost is capped harder than cut: boosting also lifts the noise floor,
// while cutting a hot mic is always safe.
constexpr float kDynTrimMinDb = -20.0f;
constexpr float kDynTrimMaxDb = 12.0f;
constexpr float kDynSmoothMs = 5.0f;        // per-sample trim de-zipper

// Crackle insurance.
constexpr float kDenormal = 1e-15f;
constexpr float kLogFloor = 1e-9f;

inline float SoftLimitLegacy(float x) {
  const float ax = std::fabs(x);
  if (ax <= kLegacyKnee) {
    return x;
  }
  const float over = ax - kLegacyKnee;
  const float limited = kLegacyKnee + kLegacyRange * std::tanh(over / kLegacyRange);
  return x < 0.0f ? -limited : limited;
}

inline float SoftLimitSafety(float x) {
  const float ax = std::fabs(x);
  if (ax <= kSafetyKnee) {
    return x;
  }
  const float over = ax - kSafetyKnee;
  const float limited = kSafetyKnee + kSafetyRange * std::tanh(over / kSafetyRange);
  return x < 0.0f ? -limited : limited;
}

// exp(-1/(t_ms * fs)) time-constant coefficient.
inline float AlphaFromMs(float ms, int fs) {
  const float t = ms * 0.001f * static_cast<float>(fs);
  return t <= 0.0f ? 0.0f : std::exp(-1.0f / t);
}

}  // namespace

// RBJ Audio EQ Cookbook coefficients, normalized by a0. A band whose center
// frequency is too close to (or above) Nyquist collapses to identity.
void FlutterCaptureGainProcessor::SetupFilters(int sample_rate_hz) {
  const float fs = static_cast<float>(sample_rate_hz);
  const float pi = 3.14159265358979323846f;

  struct Coef {
    float b0, b1, b2, a1, a2;
  };
  Coef c[kNumEqStages];
  int n = 0;

  auto identity = []() { return Coef{1.0f, 0.0f, 0.0f, 0.0f, 0.0f}; };
  auto usable = [&](float fc) { return fc < 0.45f * fs; };

  // Highpass (x2 cascade).
  auto highpass = [&](float fc, float q) {
    if (!usable(fc)) return identity();
    const float w0 = 2.0f * pi * fc / fs;
    const float cw = std::cos(w0);
    const float alpha = std::sin(w0) / (2.0f * q);
    const float a0 = 1.0f + alpha;
    return Coef{(1.0f + cw) / 2.0f / a0, -(1.0f + cw) / a0,
                (1.0f + cw) / 2.0f / a0, -2.0f * cw / a0, (1.0f - alpha) / a0};
  };
  // Lowpass (de-esser split). At a sample rate too low for the split
  // frequency it collapses to identity -> hf = 0 -> de-esser inert.
  auto lowpass = [&](float fc, float q) {
    if (!usable(fc)) return identity();
    const float w0 = 2.0f * pi * fc / fs;
    const float cw = std::cos(w0);
    const float alpha = std::sin(w0) / (2.0f * q);
    const float a0 = 1.0f + alpha;
    return Coef{(1.0f - cw) / 2.0f / a0, (1.0f - cw) / a0,
                (1.0f - cw) / 2.0f / a0, -2.0f * cw / a0, (1.0f - alpha) / a0};
  };
  // Low shelf, shelf slope S = 1.
  auto lowshelf = [&](float fc, float gain_db) {
    if (!usable(fc)) return identity();
    const float A = std::pow(10.0f, gain_db / 40.0f);
    const float w0 = 2.0f * pi * fc / fs;
    const float cw = std::cos(w0);
    const float alpha = std::sin(w0) / 2.0f * std::sqrt(2.0f);  // S=1
    const float sqA2a = 2.0f * std::sqrt(A) * alpha;
    const float a0 = (A + 1.0f) + (A - 1.0f) * cw + sqA2a;
    return Coef{A * ((A + 1.0f) - (A - 1.0f) * cw + sqA2a) / a0,
                2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw) / a0,
                A * ((A + 1.0f) - (A - 1.0f) * cw - sqA2a) / a0,
                -2.0f * ((A - 1.0f) + (A + 1.0f) * cw) / a0,
                ((A + 1.0f) + (A - 1.0f) * cw - sqA2a) / a0};
  };
  // Peaking EQ.
  auto peaking = [&](float fc, float gain_db, float q) {
    if (!usable(fc)) return identity();
    const float A = std::pow(10.0f, gain_db / 40.0f);
    const float w0 = 2.0f * pi * fc / fs;
    const float cw = std::cos(w0);
    const float alpha = std::sin(w0) / (2.0f * q);
    const float a0 = 1.0f + alpha / A;
    return Coef{(1.0f + alpha * A) / a0, -2.0f * cw / a0,
                (1.0f - alpha * A) / a0, -2.0f * cw / a0,
                (1.0f - alpha / A) / a0};
  };

  c[n++] = highpass(kHpFreq, kHpQ1);
  c[n++] = highpass(kHpFreq, kHpQ2);
  c[n++] = lowshelf(kShelfFreq, kShelfGainDb);
  for (int i = 0; i < 4; ++i) {
    c[n++] = peaking(kPeakFreq[i], kPeakGainDb[i], kPeakQ[i]);
  }

  for (int chan = 0; chan < kMaxChannels; ++chan) {
    for (int i = 0; i < kNumEqStages; ++i) {
      Biquad& bq = ch_[chan].eq[i];
      bq.b0 = c[i].b0;
      bq.b1 = c[i].b1;
      bq.b2 = c[i].b2;
      bq.a1 = c[i].a1;
      bq.a2 = c[i].a2;
    }
  }
  // De-esser: the CUT rides the subtract-split (phase-coherent by
  // construction), but the DETECTOR needs a TRUE steep highpass — (v - lp)
  // has a phase-mismatch skirt (-3 dB of 2.4 kHz leaks in) and a single HP2
  // still reads strong 3-4 kHz content as "HF"; two cascaded stages
  // (24 dB/oct) key on genuine sibilance-band energy only.
  const Coef dl = lowpass(kDeEssSplitFreq, 0.70710678f);
  const Coef dh = highpass(kDeEssSplitFreq, 0.70710678f);
  for (int chan = 0; chan < kMaxChannels; ++chan) {
    Biquad& bq = ch_[chan].deess_lp;
    bq.b0 = dl.b0;
    bq.b1 = dl.b1;
    bq.b2 = dl.b2;
    bq.a1 = dl.a1;
    bq.a2 = dl.a2;
    Biquad* hps[2] = {&ch_[chan].deess_hp, &ch_[chan].deess_hp2};
    for (Biquad* bh : hps) {
      bh->b0 = dh.b0;
      bh->b1 = dh.b1;
      bh->b2 = dh.b2;
      bh->a1 = dh.a1;
      bh->a2 = dh.a2;
    }
  }

  comp_alpha_a_ = AlphaFromMs(kCompAttackMs, sample_rate_hz);
  comp_alpha_r_ = AlphaFromMs(kCompReleaseMs, sample_rate_hz);
  lim_alpha_a_ = AlphaFromMs(kLimAttackMs, sample_rate_hz);
  lim_alpha_r_ = AlphaFromMs(kLimReleaseMs, sample_rate_hz);
  dyn_smooth_alpha_ = AlphaFromMs(kDynSmoothMs, sample_rate_hz);
  up_env_alpha_a_ = AlphaFromMs(kUpEnvAttackMs, sample_rate_hz);
  up_env_alpha_r_ = AlphaFromMs(kUpEnvReleaseMs, sample_rate_hz);
  up_boost_alpha_up_ = AlphaFromMs(kUpBoostAttackMs, sample_rate_hz);
  up_boost_alpha_dn_ = AlphaFromMs(kUpBoostReleaseMs, sample_rate_hz);
  gate_alpha_open_ = AlphaFromMs(kGateOpenMs, sample_rate_hz);
  gate_alpha_close_ = AlphaFromMs(kGateCloseMs, sample_rate_hz);
  mod_slow_alpha_ = AlphaFromMs(kModSlowMs, sample_rate_hz);
  mod_avg_alpha_ = AlphaFromMs(kModAvgMs, sample_rate_hz);
  de_env_alpha_a_ = AlphaFromMs(kDeEssEnvAttackMs, sample_rate_hz);
  de_env_alpha_r_ = AlphaFromMs(kDeEssEnvReleaseMs, sample_rate_hz);
  de_cut_alpha_a_ = AlphaFromMs(kDeEssCutAttackMs, sample_rate_hz);
  de_cut_alpha_r_ = AlphaFromMs(kDeEssCutReleaseMs, sample_rate_hz);
  floor_smooth_alpha_ = AlphaFromMs(kFloorSmoothMs, sample_rate_hz);
  floor_win_samples_ = std::max(
      1, static_cast<int>(kFloorWindowMs * 0.001f *
                          static_cast<float>(sample_rate_hz)));
}

void FlutterCaptureGainProcessor::ResetState() {
  for (int chan = 0; chan < kMaxChannels; ++chan) {
    ChannelState& s = ch_[chan];
    for (int i = 0; i < kNumEqStages; ++i) {
      s.eq[i].x1 = s.eq[i].x2 = s.eq[i].y1 = s.eq[i].y2 = 0.0f;
    }
    s.comp_y1 = 0.0f;
    s.comp_yl = 0.0f;
    s.lim_gr = 1.0f;
    s.up_env = 0.0f;
    s.up_boost_db = 0.0f;
    // Boot in the gated state (a stream starts in silence) — the gate opens
    // in ~2 ms on the first word instead of popping the pre-speech floor.
    s.gate_cut_db = kGateMaxCutDb;
    s.mod_slow_db = -80.0f;
    s.mod_depth_db = 0.0f;
    // Floor tracker boots HIGH: no boost until real minima are observed.
    s.up_floor_db = 10.0f;
    s.floor_sub_min_db = 10.0f;
    s.floor_prev_min_db = 10.0f;
    s.floor_count = 0;
    s.deess_lp.x1 = s.deess_lp.x2 = s.deess_lp.y1 = s.deess_lp.y2 = 0.0f;
    s.deess_hp.x1 = s.deess_hp.x2 = s.deess_hp.y1 = s.deess_hp.y2 = 0.0f;
    s.deess_hp2.x1 = s.deess_hp2.x2 = s.deess_hp2.y1 = s.deess_hp2.y2 = 0.0f;
    s.de_env_hf = 0.0f;
    s.de_env_fb = 0.0f;
    s.de_cut_db = 0.0f;
  }
  dyn_meter_db_ = 0.0f;
  dyn_meter_primed_ = false;
  dyn_trim_db_ = 0.0f;
  dyn_trim_lin_ = 1.0f;
}

// Fused gate + upward-compression step (see the constants block for the
// design + timing rationale). Shared by the fullband and split-band paths so
// the math can never drift between them. Small and branch-light — inlined
// into the per-sample loops by the compiler.
float FlutterCaptureGainProcessor::GateUpwardGainDb(ChannelState& s,
                                                    float av) {
  // Envelope follower: fast rise, slow fall.
  const float ae = av > s.up_env ? up_env_alpha_a_ : up_env_alpha_r_;
  s.up_env = ae * s.up_env + (1.0f - ae) * av + kDenormal;
  const float env_db =
      20.0f * std::log10(std::max(s.up_env, kLogFloor) / kFullScale);

  // Upward boost target: soft-knee 2:1 lift below the speech point, capped.
  const float under = kUpThresholdDb - env_db;  // > 0 when below speech level
  float bt;
  if (2.0f * under <= -kUpKneeDb) {
    bt = 0.0f;
  } else if (2.0f * under >= kUpKneeDb) {
    bt = under * (1.0f - 1.0f / kUpRatio);
  } else {
    const float t = under + kUpKneeDb * 0.5f;
    bt = (1.0f - 1.0f / kUpRatio) * t * t / (2.0f * kUpKneeDb);
  }
  bt = std::min(bt, kUpMaxBoostDb);
  // SNR presence: min-statistics floor tracker, boost only well above it.
  s.floor_sub_min_db = std::min(s.floor_sub_min_db, env_db);
  if (++s.floor_count >= floor_win_samples_) {
    s.floor_count = 0;
    s.floor_prev_min_db = s.floor_sub_min_db;
    s.floor_sub_min_db = env_db;
  }
  const float floor_raw = std::min(s.floor_sub_min_db, s.floor_prev_min_db);
  s.up_floor_db = floor_smooth_alpha_ * s.up_floor_db +
                  (1.0f - floor_smooth_alpha_) * floor_raw;
  float pr = (env_db - s.up_floor_db - kSnrZeroDb) /
             (kSnrFullDb - kSnrZeroDb);
  pr = std::min(std::max(pr, 0.0f), 1.0f);
  // Modulation presence state: kept warm even while the RNNoise VAD is in
  // charge, so a mid-call fallback (engine bail) resumes with converged
  // gates instead of a cold 250-400 ms transient.
  s.mod_slow_db =
      mod_slow_alpha_ * s.mod_slow_db + (1.0f - mod_slow_alpha_) * env_db;
  const float md = std::min(std::max(env_db - s.mod_slow_db, 0.0f),
                            kModClampDb);
  s.mod_depth_db =
      mod_avg_alpha_ * s.mod_depth_db + (1.0f - mod_avg_alpha_) * md;
  float pm = (s.mod_depth_db - kModZeroDb) / (kModFullDb - kModZeroDb);
  pm = std::min(std::max(pm, 0.0f), 1.0f);
  if (vad_presence_ >= 0.0f) {
    // RNNoise voice probability (see the constants block): the trained
    // model's verdict REPLACES the SNR+modulation presence.
    float pv = (vad_presence_ - kVadZeroProb) / (kVadFullProb - kVadZeroProb);
    pv = std::min(std::max(pv, 0.0f), 1.0f);
    bt *= pv * pv * (3.0f - 2.0f * pv);
  } else {
    bt *= pr * pr * (3.0f - 2.0f * pr);
    bt *= pm * pm * (3.0f - 2.0f * pm);
  }
  const float ab =
      bt > s.up_boost_db ? up_boost_alpha_up_ : up_boost_alpha_dn_;
  s.up_boost_db = ab * s.up_boost_db + (1.0f - ab) * bt;

  // Gate cut target: soft-knee downward expansion below the effective
  // threshold (floor-relative, absolute-capped — see the constants block).
  const float gate_thresh =
      std::min(kGateThresholdDb, s.up_floor_db + kGateAboveFloorDb);
  const float under_g = gate_thresh - env_db;
  float gt;
  if (2.0f * under_g <= -kGateKneeDb) {
    gt = 0.0f;
  } else if (2.0f * under_g >= kGateKneeDb) {
    gt = under_g * (kGateRatio - 1.0f);
  } else {
    const float t = under_g + kGateKneeDb * 0.5f;
    gt = (kGateRatio - 1.0f) * t * t / (2.0f * kGateKneeDb);
  }
  gt = std::min(gt, kGateMaxCutDb);
  const float ag = gt > s.gate_cut_db ? gate_alpha_close_ : gate_alpha_open_;
  s.gate_cut_db = ag * s.gate_cut_db + (1.0f - ag) * gt;

  return s.up_boost_db - s.gate_cut_db;
}

void FlutterCaptureGainProcessor::Initialize(int sample_rate_hz,
                                             int num_channels) {
  sample_rate_ = sample_rate_hz > 0 ? sample_rate_hz : 48000;
  channels_ = num_channels > 0 ? num_channels : 1;
  SetupFilters(sample_rate_);
  ResetState();
}

void FlutterCaptureGainProcessor::Reset(int new_rate) {
  if (new_rate > 0) {
    sample_rate_ = new_rate;
    SetupFilters(sample_rate_);
  }
  ResetState();
}

void FlutterCaptureGainProcessor::Release() {}

// AI noise suppression (RNNoise default / DFN3 optional) — the HEAD of the
// chain. Sits after WebRTC's APM AEC (this whole processor is the capture
// POST-processor) and before trim/EQ, the same slot Krisp uses; NEVER move
// it pre-AEC (nonlinear suppression breaks echo estimation). The buffer is
// fullband mono (see the layout note at the call below), so the Rust
// adapter (ABI v2) only ever exercises its direct-48 kHz and
// 16 kHz-resample paths here — the v1 "48 kHz only" gate was why no
// engine ever denoised a live frame on a 16 kHz-class mic. A rate the
// adapter can't convert (rc 4, e.g. 32 kHz) passes through untouched and
// flips the format flag so Dart can fall back to WebRTC NS.
void FlutterCaptureGainProcessor::ProcessDfn(int num_bands, int buffer_size,
                                             float* buffer) {
  // Shape breadcrumbs for the status getter — stored even with AI NS off so
  // diagnosis never needs a special build.
  last_bands_.store(num_bands, std::memory_order_relaxed);
  last_buffer_size_.store(buffer_size, std::memory_order_relaxed);
  // Default: no engine VAD this frame — every early-out below leaves the
  // gate stage on its own SNR+modulation presence.
  vad_presence_ = -1.0f;
  dfn_vad_.store(-1.0f, std::memory_order_relaxed);
  if (!noise_suppress_ai_.load(std::memory_order_relaxed) ||
      dfn_bailed_.load(std::memory_order_relaxed)) {
    return;
  }
  void* handle = dfn_handle_.load(std::memory_order_acquire);
  if (handle == nullptr) {
    return;  // engine still loading (or unavailable) — pass through
  }

  // CRITICAL — the buffer is ALWAYS live FULLBAND mono, never split bands:
  // libwebrtc's CustomProcessingAdapter (webrtc-sdk libwebrtc
  // src/rtc_audio_processing_impl.cc) passes audio->channels()[0] — the
  // merged channel-0 samples, buffer_size = one 10 ms frame at
  // sample_rate_ — while num_bands is the APM's INTERNAL split count, not
  // this buffer's layout. Passing num_bands through as if the buffer were
  // banded runs filterbank synthesis on raw PCM chunks = spectral garbage
  // (the 2026-07-18 Pixel "pixelated mic" field test). Same for channels:
  // only channel 0 is ever handed over.
  const auto t0 = std::chrono::steady_clock::now();
  const int rc = hollow_dfn::ProcessFrameEx(handle, buffer, buffer_size,
                                            /*num_bands=*/1, sample_rate_,
                                            /*channels=*/1);
  const float ms = std::chrono::duration<float, std::milli>(
                       std::chrono::steady_clock::now() - t0)
                       .count();
  if (rc == 4) {
    // Unsupported capture shape: frame untouched. Latch formatOk=false so
    // the Dart reconcile pass re-arms WebRTC NS.
    dfn_format_ok_.store(false, std::memory_order_relaxed);
    if (!dfn_format_logged_) {
      dfn_format_logged_ = true;
      std::fprintf(stderr,
                   "[hollow_dfn] unsupported capture shape (bands=%d rate=%d "
                   "size=%d chans=%d) — AI NS bypassed\n",
                   num_bands, sample_rate_, buffer_size, channels_);
    }
    return;
  }
  dfn_format_ok_.store(true, std::memory_order_relaxed);
  if (rc != 0) {
    // Engine error mid-stream: latch bypass — the frame may be half-written
    // and per-frame retry on the audio thread is how glitches are born.
    dfn_bailed_.store(true, std::memory_order_relaxed);
    std::fprintf(stderr, "[hollow_dfn] process rc=%d — bypassed for session\n",
                 rc);
    return;
  }
  // Frame denoised: pick up the engine's voice probability for the gate
  // stage (RNNoise supplies one; DFN3 returns -1 -> fallback gating).
  vad_presence_ = hollow_dfn::LastVad(handle);
  dfn_vad_.store(vad_presence_, std::memory_order_relaxed);
  // Realtime watchdog: EMA of per-frame cost, 100-frame warmup grace (cold
  // caches / first-inference lazy init). Budget is 10 ms; sustained >6 ms
  // means this device can't afford DFN — latch bypass, keep the call alive.
  const int frames = dfn_frames_.load(std::memory_order_relaxed) + 1;
  dfn_frames_.store(frames, std::memory_order_relaxed);
  const float ema =
      frames == 1
          ? ms
          : 0.98f * dfn_ms_ema_.load(std::memory_order_relaxed) + 0.02f * ms;
  dfn_ms_ema_.store(ema, std::memory_order_relaxed);
  if (frames > 100 && ema > 6.0f) {
    dfn_bailed_.store(true, std::memory_order_relaxed);
    std::fprintf(stderr,
                 "[hollow_dfn] realtime overrun (EMA %.2f ms/frame) — "
                 "bypassed for session\n",
                 ema);
  }
}

void FlutterCaptureGainProcessor::Process(int num_bands, int /*num_frames*/,
                                          int buffer_size, float* buffer) {
  if (buffer == nullptr || buffer_size <= 0) {
    return;
  }
  ProcessDfn(num_bands, buffer_size, buffer);
  const float gain = gain_.load(std::memory_order_relaxed);
  const bool enhance = enhance_.load(std::memory_order_relaxed);
  const bool dynamic = dynamic_.load(std::memory_order_relaxed);
  const bool muted = muted_.load(std::memory_order_relaxed);
  const bool servo_hold = servo_hold_.load(std::memory_order_relaxed);
  const float makeup_db =
      dynamic ? kDynMakeupDb : makeup_db_.load(std::memory_order_relaxed);

  if (!enhance) {
    // Legacy path — byte-identical to the shipped flat-gain processor.
    //
    // CRITICAL — band-split awareness. WebRTC's APM hands the capture
    // post-processor its buffer in the SPLIT-BAND domain when num_bands > 1
    // (e.g. at 48 kHz on Linux the fullband 480-sample frame is split into 3
    // contiguous sub-bands of 160 samples). A per-sample NONLINEARITY run
    // independently across concatenated bands wrecks the spectral balance on
    // recombination, so the limiter only runs on fullband data; a LINEAR
    // gain commutes with the filterbank and is always safe.
    if (num_bands > 1) {
      if (gain != 1.0f) {
        for (int i = 0; i < buffer_size; ++i) {
          buffer[i] *= gain;
        }
      }
    } else {
      for (int i = 0; i < buffer_size; ++i) {
        buffer[i] = SoftLimitLegacy(buffer[i] * gain);
      }
    }
    return;
  }

  const float manual_trim = gain * kEnhanceTrimScale;
  const float inv_ratio_m1 = (1.0f / kCompRatio) - 1.0f;

  // Segment length carrying ONE time-aligned gain trace: the samples of
  // band 0 (split-band) or of one channel (fullband).
  const int chans_raw = std::min(std::max(channels_, 1), kMaxChannels);
  const int seg_len = num_bands > 1
                          ? buffer_size / num_bands
                          : buffer_size / chans_raw;

  // --- Dynamic-mode servo (frame-rate, speech-gated) -------------------------
  // Measures the PRE-trim RMS of the first segment (band0 / channel 0 — the
  // one real mic), slews the trim toward (target - meter), then the trim is
  // de-zippered per sample in the processing loops below.
  // FROZEN while muted (the APM keeps feeding real mic audio here with the
  // outbound track disabled) and while share audio is active anywhere on the
  // device (room bleed passes the speech floor continuously) — adapting to
  // non-speech buries the voice.
  if (dynamic && seg_len > 0 && !muted && !servo_hold) {
    double sumsq = 0.0;
    for (int i = 0; i < seg_len; ++i) {
      const double v = static_cast<double>(buffer[i]);
      sumsq += v * v;
    }
    const float rms = static_cast<float>(
        std::sqrt(sumsq / static_cast<double>(seg_len)));
    const float rms_db =
        20.0f * std::log10(std::max(rms, kLogFloor) / kFullScale);
    if (rms_db > kDynSpeechFloorDb) {
      // Frame duration: subband samples tick at fs/num_bands.
      const float frame_sec =
          static_cast<float>(seg_len) *
          static_cast<float>(num_bands > 1 ? num_bands : 1) /
          static_cast<float>(sample_rate_);
      if (!dyn_meter_primed_) {
        // First speech: snap straight to the right level (nothing has been
        // heard at the wrong level yet), then servo slowly from there.
        dyn_meter_primed_ = true;
        dyn_meter_db_ = rms_db;
        dyn_trim_db_ = std::min(std::max(kDynTargetRmsDb - rms_db,
                                         kDynTrimMinDb),
                                kDynTrimMaxDb);
      } else {
        const float meter_alpha =
            std::min(frame_sec / kDynMeterTauSec, 1.0f);
        dyn_meter_db_ += meter_alpha * (rms_db - dyn_meter_db_);
        const float desired = std::min(
            std::max(kDynTargetRmsDb - dyn_meter_db_, kDynTrimMinDb),
            kDynTrimMaxDb);
        float step = desired - dyn_trim_db_;
        const float max_up = kDynUpDbPerSec * frame_sec;
        const float max_down = kDynDownDbPerSec * frame_sec;
        if (step > max_up) step = max_up;
        if (step < -max_down) step = -max_down;
        dyn_trim_db_ += step;
      }
    }
  }
  const float trim_target =
      dynamic ? std::pow(10.0f, dyn_trim_db_ * 0.05f) : manual_trim;

  // Fill the per-sample trim trace (de-zippered in dynamic mode; constant in
  // manual mode). Shared time-aligned across channels/bands.
  if (seg_len <= 0 || seg_len > kMaxBandLen) {
    // Shape we don't understand — constant trim, no chain.
    for (int i = 0; i < buffer_size; ++i) {
      buffer[i] = SoftLimitLegacy(buffer[i] * trim_target);
    }
    return;
  }
  for (int i = 0; i < seg_len; ++i) {
    dyn_trim_lin_ += (1.0f - dyn_smooth_alpha_) * (trim_target - dyn_trim_lin_);
    band_gain_[i] = dyn_trim_lin_;
  }

  if (num_bands > 1) {
    // Split-band (Linux 48 kHz): the biquad EQ and the limiter are only
    // valid on recombined FULLBAND audio, so they are skipped here. The
    // compressor's per-sample gain is computed on band0 (where nearly all
    // speech energy lives) and re-applied TIME-ALIGNED to the higher bands
    // — subband samples with the same index describe the same instant, and
    // a linear gain commutes with the filterbank. WebRTC's own downstream
    // limiter still prevents hard clipping.
    ChannelState& s = ch_[0];
    for (int i = 0; i < seg_len; ++i) {
      float t = band_gain_[i];
      float v = buffer[i] * t;
      // Gate + upward compression (dynamic mode only): computed on band0
      // (where nearly all speech energy lives), ridden to the higher bands
      // via band_gain_ like the compressor's gain — a linear gain commutes
      // with the filterbank.
      if (dynamic) {
        const float gs =
            std::pow(10.0f, GateUpwardGainDb(s, std::fabs(v)) * 0.05f);
        v *= gs;
        t *= gs;
      }
      const float av = std::fabs(v);
      const float level_db =
          20.0f * std::log10(std::max(av, kLogFloor) / kFullScale);
      const float over = level_db - kCompThresholdDb;
      float yg;
      if (2.0f * over <= -kCompKneeDb) {
        yg = level_db;
      } else if (2.0f * over >= kCompKneeDb) {
        yg = kCompThresholdDb + over / kCompRatio;
      } else {
        const float tt = over + kCompKneeDb * 0.5f;
        yg = level_db + inv_ratio_m1 * tt * tt / (2.0f * kCompKneeDb);
      }
      const float xl = level_db - yg;
      s.comp_y1 = std::max(
          xl, comp_alpha_r_ * s.comp_y1 + (1.0f - comp_alpha_r_) * xl);
      s.comp_yl =
          comp_alpha_a_ * s.comp_yl + (1.0f - comp_alpha_a_) * s.comp_y1;
      const float g = std::pow(10.0f, (makeup_db - s.comp_yl) * 0.05f);
      band_gain_[i] = t * g;
      buffer[i] = v * g;
    }
    for (int b = 1; b < num_bands; ++b) {
      float* band = buffer + b * seg_len;
      for (int i = 0; i < seg_len; ++i) {
        band[i] = band[i] * band_gain_[i];
      }
    }
    return;
  }

  // Fullband: the APM hands deinterleaved per-channel data. Run the full
  // chain per channel; anything beyond kMaxChannels gets the legacy path.
  if (channels_ > kMaxChannels || buffer_size % chans_raw != 0) {
    for (int i = 0; i < buffer_size; ++i) {
      buffer[i] = SoftLimitLegacy(buffer[i] * gain);
    }
    return;
  }
  const int frames = seg_len;

  for (int chan = 0; chan < chans_raw; ++chan) {
    ChannelState& s = ch_[chan];
    float* x = buffer + chan * frames;
    for (int i = 0; i < frames; ++i) {
      // Trim (per-sample trace, shared time-aligned across channels).
      float v = x[i] * band_gain_[i] + kDenormal;
      // EQ: 7 fixed biquads, Direct Form I.
      for (int f = 0; f < kNumEqStages; ++f) {
        Biquad& bq = s.eq[f];
        const float y = bq.b0 * v + bq.b1 * bq.x1 + bq.b2 * bq.x2 -
                        bq.a1 * bq.y1 - bq.a2 * bq.y2 + kDenormal;
        bq.x2 = bq.x1;
        bq.x1 = v;
        bq.y2 = bq.y1;
        bq.y1 = y;
        v = y;
      }
      // Gate + upward compression (dynamic mode only) between EQ and
      // compressor: gate BEFORE the compressor so its makeup can never lift
      // the pause noise floor.
      if (dynamic) {
        v *= std::pow(10.0f, GateUpwardGainDb(s, std::fabs(v)) * 0.05f);
      }
      // Compressor: Giannoulis soft-knee gain computer + decoupled smooth
      // peak detector, single dB-domain gain, single multiply.
      const float av = std::fabs(v);
      const float level_db =
          20.0f * std::log10(std::max(av, kLogFloor) / kFullScale);
      const float over = level_db - kCompThresholdDb;
      float yg;
      if (2.0f * over <= -kCompKneeDb) {
        yg = level_db;
      } else if (2.0f * over >= kCompKneeDb) {
        yg = kCompThresholdDb + over / kCompRatio;
      } else {
        const float t = over + kCompKneeDb * 0.5f;
        yg = level_db + inv_ratio_m1 * t * t / (2.0f * kCompKneeDb);
      }
      const float xl = level_db - yg;  // gain reduction, dB >= 0
      s.comp_y1 = std::max(
          xl, comp_alpha_r_ * s.comp_y1 + (1.0f - comp_alpha_r_) * xl);
      s.comp_yl =
          comp_alpha_a_ * s.comp_yl + (1.0f - comp_alpha_a_) * s.comp_y1;
      v *= std::pow(10.0f, (makeup_db - s.comp_yl) * 0.05f);
      // De-esser (see the constants block): split v = lp + hf at a fixed
      // lowpass, duck ONLY hf, keyed on the HF/fullband envelope ratio with
      // a level gate. AFTER the compressor so the full cut lands on the
      // output (pre-comp de-essing gave ~half back: a ducked ess compresses
      // less, so makeup re-lifted it — harness-measured). The ratio key is
      // invariant to the comp's broadband gain. Reconstruction at zero cut
      // is exact by construction.
      {
        Biquad& dl = s.deess_lp;
        const float lp = dl.b0 * v + dl.b1 * dl.x1 + dl.b2 * dl.x2 -
                         dl.a1 * dl.y1 - dl.a2 * dl.y2 + kDenormal;
        dl.x2 = dl.x1;
        dl.x1 = v;
        dl.y2 = dl.y1;
        dl.y1 = lp;
        const float hf = v - lp;
        Biquad& dh = s.deess_hp;
        const float hp1 = dh.b0 * v + dh.b1 * dh.x1 + dh.b2 * dh.x2 -
                          dh.a1 * dh.y1 - dh.a2 * dh.y2 + kDenormal;
        dh.x2 = dh.x1;
        dh.x1 = v;
        dh.y2 = dh.y1;
        dh.y1 = hp1;
        Biquad& dh2 = s.deess_hp2;
        const float hp = dh2.b0 * hp1 + dh2.b1 * dh2.x1 + dh2.b2 * dh2.x2 -
                         dh2.a1 * dh2.y1 - dh2.a2 * dh2.y2 + kDenormal;
        dh2.x2 = dh2.x1;
        dh2.x1 = hp1;
        dh2.y2 = dh2.y1;
        dh2.y1 = hp;
        const float ahf = std::fabs(hp);
        const float afb = std::fabs(v);
        const float ah = ahf > s.de_env_hf ? de_env_alpha_a_ : de_env_alpha_r_;
        s.de_env_hf = ah * s.de_env_hf + (1.0f - ah) * ahf + kDenormal;
        const float af = afb > s.de_env_fb ? de_env_alpha_a_ : de_env_alpha_r_;
        s.de_env_fb = af * s.de_env_fb + (1.0f - af) * afb + kDenormal;
        const float hf_db =
            20.0f * std::log10(std::max(s.de_env_hf, kLogFloor) / kFullScale);
        const float fb_db =
            20.0f * std::log10(std::max(s.de_env_fb, kLogFloor) / kFullScale);
        float ra = (hf_db - fb_db - kDeEssRatioZeroDb) /
                   (kDeEssRatioFullDb - kDeEssRatioZeroDb);
        ra = std::min(std::max(ra, 0.0f), 1.0f);
        float lv = (fb_db - kDeEssLevelFloorDb) / kDeEssLevelRampDb;
        lv = std::min(std::max(lv, 0.0f), 1.0f);
        const float ct = kDeEssMaxCutDb * ra * ra * (3.0f - 2.0f * ra) * lv *
                         lv * (3.0f - 2.0f * lv);
        const float ac = ct > s.de_cut_db ? de_cut_alpha_a_ : de_cut_alpha_r_;
        s.de_cut_db = ac * s.de_cut_db + (1.0f - ac) * ct;
        v = lp + hf * std::pow(10.0f, -s.de_cut_db * 0.05f);
      }
      // Limiter: gain-smoothed (never memoryless) peak limiter into a tanh
      // safety net. Fast attack catches overs; slow release avoids pumping.
      const float pv = std::fabs(v);
      const float target = pv > kLimCeiling ? kLimCeiling / pv : 1.0f;
      if (target < s.lim_gr) {
        s.lim_gr = lim_alpha_a_ * s.lim_gr + (1.0f - lim_alpha_a_) * target;
      } else {
        s.lim_gr = lim_alpha_r_ * s.lim_gr + (1.0f - lim_alpha_r_) * target;
      }
      x[i] = SoftLimitSafety(v * s.lim_gr);
    }
  }
}

}  // namespace flutter_webrtc_plugin
