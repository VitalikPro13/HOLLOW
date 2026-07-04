#ifndef SCREEN_AUDIO_TEST_PULSE_SINK_INPUT_CAPTURER_H_
#define SCREEN_AUDIO_TEST_PULSE_SINK_INPUT_CAPTURER_H_

#ifdef __linux__

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>

// Forward-declare libpulse types so this header stays libpulse-free.
struct pa_threaded_mainloop;
struct pa_context;
struct pa_stream;
struct pa_sink_input_info;

// Per-sink-input capture + mix on Linux — the PulseAudio analog of the
// Windows MultiProcessCapturer. One record stream per sink-input via
// pa_stream_set_monitor_stream (the same mechanism pavucontrol uses for its
// per-stream meters; implemented by pipewire-pulse too), a subscription keeps
// the set live as streams come and go mid-share, and a wall-clock-paced mixer
// thread sums one 10ms 48k-stereo frame across all captured streams.
//
// Two modes sharing the machinery — only the relevance predicate differs:
//  - kExcludeTree (entire-screen anti-echo): capture every sink-input EXCEPT
//    those in the target pid's process tree or named "Hollow" (the app's own
//    call playback, media, and the render child) — so the remote's voice is
//    not re-captured and echoed back. Hollow's own in-app media is excluded
//    too (same tradeoff as the Windows exclude-self fallback).
//  - kIncludeTree (per-app/window share): capture ONLY sink-inputs whose
//    process ancestry contains the target pid (catches browser/Electron
//    audio-service child processes). A silent or unresolvable app mixes
//    SILENCE — never the system mix (the audio-leak rule from Windows).
class PulseSinkInputCapturer {
 public:
  static constexpr int kSampleRate = 48000;
  static constexpr int kChannels = 2;
  static constexpr int kFramesPerBuf = kSampleRate / 100;  // 480 = 10ms
  static constexpr int kSamplesPerBuf = kFramesPerBuf * kChannels;
  static constexpr int kBytesPerBuf = kSamplesPerBuf * sizeof(int16_t);

  enum class Mode { kExcludeTree, kIncludeTree };

  // pcm: interleaved s16le, exactly kFramesPerBuf frames of kChannels.
  using FrameCallback = std::function<void(const int16_t* pcm, size_t frames)>;

  PulseSinkInputCapturer() = default;
  ~PulseSinkInputCapturer();

  PulseSinkInputCapturer(const PulseSinkInputCapturer&) = delete;
  PulseSinkInputCapturer& operator=(const PulseSinkInputCapturer&) = delete;

  // target_pid: the tree root to exclude (kExcludeTree) or include
  // (kIncludeTree). kIncludeTree with target_pid <= 0 mixes pure silence.
  bool Start(Mode mode, int target_pid, FrameCallback callback);
  void Stop();

 private:
  // Registers the libpulse C callbacks (which need exact pa_* signatures the
  // header can't name) and forwards them to the private handlers below.
  friend struct PulseSinkInputThunks;

  struct SiStream {
    pa_stream* stream = nullptr;
    void* read_ud = nullptr;  // heap StreamUd handed to the read callback
    std::deque<int16_t> buffer;  // 48k stereo interleaved, guarded by mix_mu_
  };

  // --- handlers (run on the threaded-mainloop thread) ---
  void OnContextState();
  void OnSubscribeEvent(int event_type, uint32_t idx);
  void OnSinkInputInfo(const pa_sink_input_info* i, int eol);
  void OnStreamRead(pa_stream* s, uint32_t si_idx);

  // Relevance decision + attach/drop once the owning pid is known. pid may
  // come from the sink-input proplist (pulse-API clients) or, for native
  // PipeWire clients that omit it there, from the CLIENT object's
  // kernel-verified pipewire.sec.pid via an async client-info query.
  void DecideAndAttach(uint32_t si_idx, uint32_t sink_idx, int pid,
                       const std::string& app_name);
  bool IsRelevantPidApp(int pid, const std::string& app_name) const;
  // Creates + connects the monitor stream for one sink-input (mainloop thread).
  void AttachStream(uint32_t si_idx, const std::string& monitor_source);
  void DropStream(uint32_t si_idx);
  void MixerThread();

  pa_threaded_mainloop* ml_ = nullptr;
  pa_context* ctx_ = nullptr;
  Mode mode_ = Mode::kExcludeTree;
  int target_pid_ = 0;
  FrameCallback callback_;

  std::mutex mix_mu_;  // guards every SiStream::buffer + stream_for_idx_ keys
  std::map<uint32_t, SiStream> streams_;          // sink-input idx -> state
  std::map<uint32_t, std::string> sink_monitors_; // sink idx -> monitor name
                                                  // (mainloop thread only)
  std::thread mixer_;
  std::atomic<bool> running_{false};
  std::atomic<uint32_t> attached_{0};  // diagnostics
};

#endif  // __linux__

#endif  // SCREEN_AUDIO_TEST_PULSE_SINK_INPUT_CAPTURER_H_
