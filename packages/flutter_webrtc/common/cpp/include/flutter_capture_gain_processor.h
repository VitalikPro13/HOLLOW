#ifndef FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX
#define FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX

#include <atomic>

#include "rtc_audio_processing.h"

namespace flutter_webrtc_plugin {

// Hollow fork addition: a capture-post-processor that runs AFTER WebRTC's
// own APM (AGC/NS/EC) on the local microphone. WebRTC's AGC normalizes to a
// conservative target (~-18 dBFS), leaving the call quieter than users
// expect. The prebuilt libwebrtc wrapper exposes no AGC target-level knob,
// so this post-processor is where the missing loudness/polish is added.
//
// Two modes, switched live via SetEnhance():
//  - enhance OFF (legacy): flat makeup gain + a -3 dBFS soft limiter.
//  - enhance ON (default): a STATIC broadcast voice chain —
//      trim -> EQ (HP 100 Hz 24 dB/oct, low shelf 110 Hz +6 dB,
//      peak 291 Hz -3 dB Q1.5, 3 kHz +2 dB Q1.5, 7 kHz +3.5 dB Q2,
//      12 kHz +1.5 dB Q2) -> compressor (-18 dBFS, 3:1, 10/100 ms,
//      +12 dB makeup) -> smoothed peak limiter (-1 dBFS) -> tanh safety.
//    Every stage has FIXED parameters (no adaptive leveler): fixed biquads
//    are LTI and cannot zipper, and the single compressor uses the
//    Giannoulis decoupled smooth detector with one dB-domain gain and one
//    multiply per sample — the structural anti-crackle rules from the
//    reverted adaptive-chain experiments.
//
// Process() runs on the realtime audio thread, so it is allocation-free and
// lock-free; gain/enhance are read from atomics each frame and can be
// updated live mid-call.
class FlutterCaptureGainProcessor
    : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  FlutterCaptureGainProcessor()
      : gain_(1.0f),
        enhance_(false),
        makeup_db_(12.0f),
        dynamic_(false),
        muted_(false),
        servo_hold_(false) {}
  ~FlutterCaptureGainProcessor() override {}

  // Linear makeup-gain multiplier (1.0 = transparent in legacy mode; in
  // enhance mode it is rescaled so the slider's "100%" (2.0) is unity trim).
  // Thread-safe.
  void SetGain(float gain) { gain_.store(gain, std::memory_order_relaxed); }

  // Enables the EQ+compressor+limiter voice chain. Thread-safe, live.
  void SetEnhance(bool enabled) {
    enhance_.store(enabled, std::memory_order_relaxed);
  }

  // Compressor makeup gain (dB) for the enhance chain — the "strength" knob
  // (0 = no loudness boost, 12 = default). Thread-safe, live.
  void SetEnhanceMakeup(float db) {
    makeup_db_.store(db, std::memory_order_relaxed);
  }

  // Dynamic mode: a slow speech-gated RMS meter servos the input trim so any
  // mic lands at the calibrated speech level; the manual gain/strength knobs
  // are ignored while active. Thread-safe, live.
  void SetEnhanceDynamic(bool enabled) {
    dynamic_.store(enabled, std::memory_order_relaxed);
  }

  // Mic muted: FREEZE the dynamic servo's meter/trim adaptation. The APM
  // capture path (and this processor) keeps running on real mic input while
  // the outbound track is disabled, and whatever the mic hears while muted
  // (e.g. shared music on the speakers) is by definition not call speech —
  // adapting to it slams the trim down (-20 dB range at 9 dB/s) and the
  // voice comes back buried on unmute. Thread-safe, live.
  void SetMuted(bool muted) { muted_.store(muted, std::memory_order_relaxed); }

  // Screen-share audio is ACTIVE somewhere on this device (we are sharing
  // WITH audio, or playing a received share): the room/speaker bleed passes
  // the servo's speech floor continuously, so even between unmuted words the
  // servo would re-calibrate to the music at 9 dB/s and bury the voice.
  // Freeze adaptation for the whole share; the pre-share speech calibration
  // holds. Thread-safe, live.
  void SetServoHold(bool hold) {
    servo_hold_.store(hold, std::memory_order_relaxed);
  }

  // CustomProcessing
  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(int num_bands, int num_frames, int buffer_size,
               float* buffer) override;
  void Reset(int new_rate) override;
  void Release() override;

 private:
  // One RBJ biquad (Direct Form I) with its state. Coefficients are
  // normalized by a0.
  struct Biquad {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    float x1 = 0.0f, x2 = 0.0f, y1 = 0.0f, y2 = 0.0f;
  };

  static constexpr int kMaxChannels = 2;
  static constexpr int kNumEqStages = 7;  // hp1, hp2, shelf, 291, 3k, 7k, 12k

  struct ChannelState {
    Biquad eq[kNumEqStages];
    float comp_y1 = 0.0f;  // decoupled detector intermediate (dB)
    float comp_yl = 0.0f;  // smoothed gain reduction (dB)
    float lim_gr = 1.0f;   // limiter smoothed linear gain
  };

  void SetupFilters(int sample_rate_hz);
  void ResetState();

  std::atomic<float> gain_;
  std::atomic<bool> enhance_;
  std::atomic<float> makeup_db_;
  std::atomic<bool> dynamic_;
  std::atomic<bool> muted_;
  std::atomic<bool> servo_hold_;

  int sample_rate_ = 48000;
  int channels_ = 1;
  ChannelState ch_[kMaxChannels];
  // Detector/limiter time-constant coefficients, recomputed per sample rate.
  float comp_alpha_a_ = 0.0f;
  float comp_alpha_r_ = 0.0f;
  float lim_alpha_a_ = 0.0f;
  float lim_alpha_r_ = 0.0f;
  // Dynamic-mode auto-trim servo (single mic — one servo, not per-channel).
  // The meter reads PRE-trim speech RMS; the trim is slew-limited in dB and
  // de-zippered per sample.
  float dyn_meter_db_ = 0.0f;
  bool dyn_meter_primed_ = false;
  float dyn_trim_db_ = 0.0f;
  float dyn_trim_lin_ = 1.0f;
  float dyn_smooth_alpha_ = 0.0f;

  // Per-frame gain trace, time-aligned across bands/channels: the per-sample
  // TRIM in the fullband path, and trim*compressor-gain in the split-band
  // path (band0's gains re-applied to the higher bands).
  static constexpr int kMaxBandLen = 1024;
  float band_gain_[kMaxBandLen];
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX
