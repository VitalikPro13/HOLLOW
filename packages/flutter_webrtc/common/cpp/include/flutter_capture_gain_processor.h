#ifndef FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX
#define FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX

#include <atomic>

#include "rtc_audio_processing.h"

namespace flutter_webrtc_plugin {

// Hollow fork addition: a capture-post-processor that runs AFTER WebRTC's
// own APM (AGC/NS/EC) on the local microphone. WebRTC's AGC normalizes to a
// conservative target (~-18 dBFS), leaving the call quieter than users
// expect. This applies a makeup gain followed by a soft limiter with a
// ~-3 dBFS ceiling so the boost can never clip — the OBS-style chain.
//
// The prebuilt libwebrtc wrapper exposes no AGC target-level knob, so this
// post-processor is how we add the missing loudness.
//
// Process() runs on the realtime audio thread, so it is allocation-free and
// lock-free; the gain is read from an atomic each frame and can be updated
// live mid-call via SetGain().
class FlutterCaptureGainProcessor
    : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  FlutterCaptureGainProcessor() : gain_(1.0f) {}
  ~FlutterCaptureGainProcessor() override {}

  // Linear makeup-gain multiplier (1.0 = transparent). Thread-safe.
  void SetGain(float gain) { gain_.store(gain, std::memory_order_relaxed); }

  // CustomProcessing
  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(int num_bands, int num_frames, int buffer_size,
               float* buffer) override;
  void Reset(int new_rate) override;
  void Release() override;

 private:
  std::atomic<float> gain_;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX
