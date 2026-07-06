#include "flutter_capture_gain_processor.h"

#include <algorithm>
#include <cmath>

// MSVC: <windows.h> (pulled in transitively) defines max/min macros that
// break std::max/std::min. No-op on GCC/Clang.
#ifdef max
#undef max
#endif
#ifdef min
#undef min
#endif

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

  comp_alpha_a_ = AlphaFromMs(kCompAttackMs, sample_rate_hz);
  comp_alpha_r_ = AlphaFromMs(kCompReleaseMs, sample_rate_hz);
  lim_alpha_a_ = AlphaFromMs(kLimAttackMs, sample_rate_hz);
  lim_alpha_r_ = AlphaFromMs(kLimReleaseMs, sample_rate_hz);
  dyn_smooth_alpha_ = AlphaFromMs(kDynSmoothMs, sample_rate_hz);
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
  }
  dyn_meter_db_ = 0.0f;
  dyn_meter_primed_ = false;
  dyn_trim_db_ = 0.0f;
  dyn_trim_lin_ = 1.0f;
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

void FlutterCaptureGainProcessor::Process(int num_bands, int /*num_frames*/,
                                          int buffer_size, float* buffer) {
  if (buffer == nullptr || buffer_size <= 0) {
    return;
  }
  const float gain = gain_.load(std::memory_order_relaxed);
  const bool enhance = enhance_.load(std::memory_order_relaxed);
  const bool dynamic = dynamic_.load(std::memory_order_relaxed);
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
  if (dynamic && seg_len > 0) {
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
      const float t = band_gain_[i];
      const float v = buffer[i] * t;
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
