#include "flutter_capture_gain_processor.h"

#include <cmath>

namespace flutter_webrtc_plugin {

namespace {
// WebRTC's APM delivers float PCM in int16 scale (~ +/-32768), not +/-1.0.
constexpr float kFullScale = 32768.0f;
// -3 dBFS ceiling: 10^(-3/20) = 0.7079.
constexpr float kCeiling = 0.7079f * kFullScale;  // ~23197
// Soft-knee threshold: below this we pass through untouched; above it we
// smoothly saturate toward the ceiling. 0.6 * ceiling keeps normal speech
// fully linear and only compresses transient peaks.
constexpr float kKnee = 0.6f * kCeiling;
constexpr float kRange = kCeiling - kKnee;

// Soft limiter, C1-continuous at the knee, asymptotes to +/-kCeiling so the
// signal can never clip. Transparent below the knee.
inline float SoftLimit(float x) {
  const float ax = std::fabs(x);
  if (ax <= kKnee) {
    return x;
  }
  const float over = ax - kKnee;
  const float limited = kKnee + kRange * std::tanh(over / kRange);
  return x < 0.0f ? -limited : limited;
}
}  // namespace

void FlutterCaptureGainProcessor::Initialize(int /*sample_rate_hz*/,
                                             int /*num_channels*/) {}

void FlutterCaptureGainProcessor::Process(int num_bands, int /*num_frames*/,
                                          int buffer_size, float* buffer) {
  const float gain = gain_.load(std::memory_order_relaxed);
  // At unity with no peaks above the knee, this is a no-op.
  if (buffer == nullptr || buffer_size <= 0) {
    return;
  }

  // CRITICAL — band-split awareness. WebRTC's APM hands the capture
  // post-processor its buffer in the SPLIT-BAND domain when num_bands > 1
  // (e.g. at 48 kHz the fullband 480-sample frame is split into 3 contiguous
  // sub-bands of 160 samples). The SoftLimit() is a per-sample NONLINEARITY;
  // running it independently across the concatenated bands distorts each
  // frequency band on its own and wrecks the spectral balance on recombination
  // — the low band (most speech energy) gets limited hard while the highs pass,
  // producing the bass-boosted, distorted Linux mic. (macOS/iOS escape this
  // because their wrapper hands fullband per-channel data; Windows/Android
  // typically run the mic at num_bands == 1, so the bug never triggered there.)
  //
  // A LINEAR gain commutes with the filterbank, so it is always safe to apply
  // across all bands. The limiter is only valid on a recombined FULLBAND
  // signal, so we restrict it to num_bands <= 1 (matching the working darwin
  // path). In the split-band case we apply makeup gain only; WebRTC's own APM
  // limiter downstream still prevents hard clipping.
  if (num_bands > 1) {
    if (gain != 1.0f) {
      for (int i = 0; i < buffer_size; ++i) {
        buffer[i] *= gain;
      }
    }
  } else {
    for (int i = 0; i < buffer_size; ++i) {
      buffer[i] = SoftLimit(buffer[i] * gain);
    }
  }
}

void FlutterCaptureGainProcessor::Reset(int /*new_rate*/) {}

void FlutterCaptureGainProcessor::Release() {}

}  // namespace flutter_webrtc_plugin
