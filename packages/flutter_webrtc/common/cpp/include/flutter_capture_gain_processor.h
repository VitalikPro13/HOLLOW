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
//      12 kHz +1.5 dB Q2) -> [dynamic mode only: gate + upward
//      compression, one fused stage] -> compressor (-24 dBFS, 3:1,
//      10/100 ms, +12.5 dB makeup) -> de-esser (ratio-keyed HF duck,
//      both enhance modes) -> smoothed peak limiter (-1 dBFS) -> tanh
//      safety.
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
    // Fused gate + upward-compression stage (dynamic mode only).
    float up_env = 0.0f;        // shared fast-attack/slow-release envelope (linear)
    float up_boost_db = 0.0f;   // smoothed upward boost (dB >= 0)
    float gate_cut_db = 0.0f;   // smoothed expander attenuation (dB >= 0)
    float mod_slow_db = -80.0f; // slow envelope mean (dB) for modulation
    float mod_depth_db = 0.0f;  // smoothed positive syllabic modulation (dB)
    // Min-statistics noise-floor tracker: two alternating sub-window minima.
    float up_floor_db = 10.0f;       // smoothed floor estimate (dB)
    float floor_sub_min_db = 10.0f;  // current sub-window minimum (dB)
    float floor_prev_min_db = 10.0f; // previous sub-window minimum (dB)
    int floor_count = 0;             // samples into the current sub-window
    // De-esser (both enhance modes): dynamic HF duck keyed on HF/full ratio.
    Biquad deess_lp;                 // fixed split lowpass (hf = v - lp)
    Biquad deess_hp;                 // detector highpass, stage 1
    Biquad deess_hp2;                // detector highpass, stage 2 (24 dB/oct)
    float de_env_hf = 0.0f;          // HF envelope (linear)
    float de_env_fb = 0.0f;          // fullband envelope (linear)
    float de_cut_db = 0.0f;          // smoothed HF cut (dB >= 0)
  };

  void SetupFilters(int sample_rate_hz);
  void ResetState();
  // Per-sample step of the fused gate + upward-compression stage (dynamic
  // mode only): updates the channel's envelope + smoothed gains from the
  // rectified sample and returns the stage gain in dB.
  float GateUpwardGainDb(ChannelState& s, float av);

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
  // Gate + upward-compression stage time constants (dynamic mode only).
  float up_env_alpha_a_ = 0.0f;    // envelope rise (fast)
  float up_env_alpha_r_ = 0.0f;    // envelope fall (slow)
  float up_boost_alpha_up_ = 0.0f; // boost grows (moderate)
  float up_boost_alpha_dn_ = 0.0f; // boost ducks fast (onset guard)
  float gate_alpha_open_ = 0.0f;   // gate opens fast (onset guard)
  float gate_alpha_close_ = 0.0f;  // gate closes slowly (no chatter)
  float mod_slow_alpha_ = 0.0f;    // slow envelope mean
  float mod_avg_alpha_ = 0.0f;     // modulation-depth smoothing
  float floor_smooth_alpha_ = 0.0f;  // floor estimate smoothing
  int floor_win_samples_ = 36000;    // min-statistics sub-window length
  // De-esser time constants.
  float de_env_alpha_a_ = 0.0f;
  float de_env_alpha_r_ = 0.0f;
  float de_cut_alpha_a_ = 0.0f;
  float de_cut_alpha_r_ = 0.0f;
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
