#ifndef FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX
#define FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

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
        servo_hold_(false),
        noise_suppress_ai_(false),
        dfn_handle_(nullptr),
        dfn_engine_(-1),
        dfn_create_in_flight_(false),
        dfn_bailed_(false),
        dfn_format_ok_(true) {}
  ~FlutterCaptureGainProcessor() override { StopCaptureRecord(); }

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

  // AI noise suppression (RNNoise default / DFN3 optional, via hollow_core's
  // C ABI, HOLLOW_PLAN ~2008): runs at the HEAD of Process — after WebRTC's
  // APM AEC, before the enhancement chain. The Rust adapter behind the ABI
  // converts whatever shape the APM delivers (48 kHz fullband, 16 kHz mono,
  // 3-band split) around the engine core; a shape it can't convert flips
  // the format flag for the status getter and passes through. The handle is
  // created on a background thread (DFN3's model load is 100-500 ms;
  // RNNoise is instant), published here, and lives until an engine SWAP
  // publishes a replacement (the old handle deliberately leaks — the audio
  // thread may still be inside it) — the audio thread only ever does one
  // relaxed pointer load per frame.
  void SetNoiseSuppressAi(bool enabled) {
    noise_suppress_ai_.store(enabled, std::memory_order_relaxed);
  }
  // Publish a freshly created engine handle. Also clears the bail/format
  // latches and the watchdog counters: a new engine deserves a fresh
  // verdict (a DFN3 realtime bail must not condemn the RNNoise it was
  // swapped for).
  void PublishDfnHandle(void* handle, int engine) {
    dfn_frames_.store(0, std::memory_order_relaxed);
    dfn_ms_ema_.store(0.0f, std::memory_order_relaxed);
    dfn_bailed_.store(false, std::memory_order_relaxed);
    dfn_format_ok_.store(true, std::memory_order_relaxed);
    dfn_engine_.store(engine, std::memory_order_relaxed);
    dfn_handle_.store(handle, std::memory_order_release);
    dfn_create_in_flight_.store(false, std::memory_order_release);
  }
  // First caller wins and owns starting the background create. Returns
  // true when a create for `engine` should start: nothing loaded yet, or a
  // LIVE ENGINE SWAP (a handle exists but for a different engine).
  bool TryBeginDfnCreate(int engine) {
    if (dfn_handle_.load(std::memory_order_acquire) != nullptr &&
        dfn_engine_.load(std::memory_order_relaxed) == engine) {
      return false;
    }
    bool expected = false;
    return dfn_create_in_flight_.compare_exchange_strong(expected, true);
  }
  // Create failed — allow a later retry (next toggle/reconcile pass).
  void EndDfnCreate() {
    dfn_create_in_flight_.store(false, std::memory_order_release);
  }
  bool DfnReady() const {
    return dfn_handle_.load(std::memory_order_acquire) != nullptr;
  }
  // Engine id of the PUBLISHED handle (-1 = none yet); hollow_dfn binding
  // engine constants.
  int DfnEngine() const {
    return dfn_engine_.load(std::memory_order_relaxed);
  }
  // Latched TRUE when inference overran the realtime budget or errored —
  // DFN stays bypassed for the session (WebRTC NS is Dart's fallback).
  bool DfnBailed() const {
    return dfn_bailed_.load(std::memory_order_relaxed);
  }
  // FALSE once a frame arrived in a shape DFN can't process (split-band,
  // non-48k, stereo).
  bool DfnFormatOk() const {
    return dfn_format_ok_.load(std::memory_order_relaxed);
  }
  bool NoiseSuppressAiEnabled() const {
    return noise_suppress_ai_.load(std::memory_order_relaxed);
  }
  // Diagnostics for the status getter: frames actually denoised this
  // session + smoothed per-frame cost (ms). frames > 0 is THE proof the
  // engine is really in the audio path.
  int DfnFramesProcessed() const {
    return dfn_frames_.load(std::memory_order_relaxed);
  }
  float DfnMsEma() const {
    return dfn_ms_ema_.load(std::memory_order_relaxed);
  }
  // Voice probability of the last denoised frame (-1 = engine not
  // supplying one) — status-getter diagnostic mirror of the audio-thread
  // value the gate stage consumes.
  float DfnVad() const { return dfn_vad_.load(std::memory_order_relaxed); }
  // Capture loudness of the live mic, dBFS, as a decaying peak-hold of the
  // per-frame RMS (-100 = silence/not yet measured). Measured every frame
  // in BOTH enhance modes, right after the AI denoiser, so it reflects the
  // audio actually heading out. This is what the speaking indicator reads
  // (issue #37): getStats carries no outgoing audio level on desktop, and
  // the old `record`-package meter opened a second mic handle that Linux
  // (PipeWire, no `parecord`) could not open at all.
  //
  // Peak-hold rather than a bare frame value: the UI polls at ~5 Hz and a
  // raw 10 ms RMS would let whole syllables fall between polls.
  float CaptureLevelDb() const {
    return level_db_.load(std::memory_order_relaxed);
  }
  // Raw capture shape as last seen by Process() (stored unconditionally,
  // even with DFN off) — lets the status getter say exactly WHY a format
  // was rejected instead of a bare formatOk=false.
  int LastBands() const { return last_bands_.load(std::memory_order_relaxed); }
  int LastBufferSize() const {
    return last_buffer_size_.load(std::memory_order_relaxed);
  }
  int SampleRate() const { return sample_rate_; }
  int Channels() const { return channels_; }
  // -- Performance sentinels (status-map diagnostics; see Process()). --
  // Smoothed whole-chain cost per 10 ms frame (AI-NS + EQ + comp + de-ess +
  // limiter together), and the capture-gap counter/worst since session start.
  float ChainMsEma() const {
    return chain_ms_ema_.load(std::memory_order_relaxed);
  }
  int CaptureGaps() const {
    return capture_gaps_.load(std::memory_order_relaxed);
  }
  int WorstGapMs() const {
    return worst_gap_ms_.load(std::memory_order_relaxed);
  }
  // For live parameter updates from the plugin (atten limit / post-filter);
  // the FFI stages values atomically, so calling with a live handle is safe.
  void* GetDfnHandle() const {
    return dfn_handle_.load(std::memory_order_acquire);
  }

  // ── Mic-test capture recording (issue #40) ──
  // Taps the PROCESSED capture signal — post AI-NS + full enhance chain,
  // byte-for-byte what feeds the Opus encoder — into a mono 16-bit WAV.
  // Start/Stop run on the platform thread; the audio thread only pushes
  // samples into a preallocated SPSC ring (Process() stays allocation-free
  // and lock-free), and a drain thread does all file I/O.
  bool StartCaptureRecord(const std::string& path);
  void StopCaptureRecord();
  bool CaptureRecordActive() const {
    return rec_active_.load(std::memory_order_relaxed);
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

  // Head-of-chain AI-NS step (no-op unless enabled and ready; the Rust
  // adapter handles the shape). Audio thread only.
  void ProcessDfn(int num_bands, int buffer_size, float* buffer);

  // The actual per-frame chain (AI-NS + gain/enhance stages). Process() is
  // a thin sentinel wrapper around this so the whole-chain cost is measured
  // across every early return. Audio thread only.
  void ProcessChain(int num_bands, int buffer_size, float* buffer);
  // Post-chain record tap (mic test). Audio thread only; see the public
  // StartCaptureRecord above.
  void RecordTap(int num_bands, int buffer_size, const float* buffer);
  // Drain-thread body: ring -> s16 -> WAV file.
  void RecordDrainLoop();
  // Frame RMS -> decaying peak-hold in level_db_ (see CaptureLevelDb).
  void MeasureCaptureLevel(int num_bands, int buffer_size,
                           const float* buffer);

  std::atomic<float> gain_;
  std::atomic<bool> enhance_;
  std::atomic<float> makeup_db_;
  std::atomic<bool> dynamic_;
  std::atomic<bool> muted_;
  std::atomic<bool> servo_hold_;
  std::atomic<bool> noise_suppress_ai_;
  std::atomic<void*> dfn_handle_;
  std::atomic<int> dfn_engine_;
  std::atomic<bool> dfn_create_in_flight_;
  std::atomic<bool> dfn_bailed_;
  std::atomic<bool> dfn_format_ok_;
  // DFN realtime watchdog state. Single writer (audio thread); atomics so
  // the status getter can report frames/cost from the platform thread —
  // "silently working" and "silently absent" must be distinguishable.
  std::atomic<float> dfn_ms_ema_{0.0f};
  std::atomic<int> dfn_frames_{0};
  std::atomic<int> last_bands_{0};
  std::atomic<int> last_buffer_size_{0};
  std::atomic<float> dfn_vad_{-1.0f};
  bool dfn_format_logged_ = false;
  // Capture level meter (see CaptureLevelDb). Audio thread is the single
  // writer; the platform thread reads it from the method channel.
  std::atomic<float> level_db_{-100.0f};
  // -- Performance sentinel state (see Process()). Quiet by default: each
  // anomaly logs ONCE (latched bool); counters ride the status map. Atomics
  // because the status getter reads from the platform thread; the audio
  // thread is the single writer.
  std::atomic<float> chain_ms_ema_{0.0f};
  std::atomic<int> chain_frames_{0};
  std::atomic<int> capture_gaps_{0};
  std::atomic<int> worst_gap_ms_{0};
  bool chain_overrun_logged_ = false;
  bool capture_gap_logged_ = false;
  // Last Process() entry time (audio thread only; 0 = fresh stream so the
  // idle time between capture sessions never counts as a gap).
  int64_t last_process_us_ = 0;
  // Speech presence for THIS frame from the AI-NS engine (RNNoise's voice
  // probability; -1 = unavailable — engine off/bailed/DFN3). Written by
  // ProcessDfn and read by GateUpwardGainDb in the SAME Process() call on
  // the audio thread — deliberately not atomic.
  float vad_presence_ = -1.0f;

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

  // ── Mic-test record state (see StartCaptureRecord). SPSC ring: audio
  // thread writes (rec_w_), drain thread reads (rec_r_); indices are
  // monotonically increasing with modulo addressing.
  std::atomic<bool> rec_active_{false};
  std::vector<float> rec_ring_;
  std::atomic<size_t> rec_w_{0};
  std::atomic<size_t> rec_r_{0};
  // WAV rate, latched by the tap from the FIRST live frame's 10 ms shape
  // (never from Initialize's rate — they can disagree; see RecordTap).
  std::atomic<int> rec_rate_{0};
  std::thread rec_thread_;
  FILE* rec_file_ = nullptr;       // drain thread only (after Start hands off)
  uint32_t rec_data_bytes_ = 0;    // drain thread only
  bool rec_shape_logged_ = false;  // audio thread only
};

// Offline mic-test renderer (issue #40 final design): runs a FRESH
// FlutterCaptureGainProcessor instance (same code = bit-exact call
// processing; never the process-global one a live call may own) over a
// mono 16-bit PCM WAV and writes the processed WAV. `dfn_handle` may be
// null (AI-NS off). Blocking file+DSP work — call from a background
// thread. Returns false with `error` set on failure.
bool RenderVoiceWavOffline(const std::string& in_path,
                           const std::string& out_path, float gain,
                           bool enhance, float makeup_db, bool dynamic_mode,
                           void* dfn_handle, int dfn_engine,
                           std::string* error);

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_CAPTURE_GAIN_PROCESSOR_HXX
