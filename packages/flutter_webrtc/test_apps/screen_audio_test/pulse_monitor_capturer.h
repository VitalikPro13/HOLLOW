#ifndef SCREEN_AUDIO_TEST_PULSE_MONITOR_CAPTURER_H_
#define SCREEN_AUDIO_TEST_PULSE_MONITOR_CAPTURER_H_

#ifdef __linux__

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>

// Captures the system audio output on Linux by recording the default sink's
// MONITOR source via PulseAudio (works identically on PipeWire through
// pipewire-pulse). Delivers fixed 10ms frames of 48kHz stereo s16le PCM on a
// dedicated capture thread.
//
// This is the Linux SEND analog of the plain Windows WASAPI loopback
// capturer, and since the per-sink-input capturer landed it is only the
// FALLBACK path: the monitor carries the WHOLE mix including the call audio
// Hollow itself plays (echo). PulseSinkInputCapturer (exclude/include tree)
// is the primary capture; this runs when that can't start.
class PulseMonitorCapturer {
 public:
  static constexpr int kSampleRate = 48000;
  static constexpr int kChannels = 2;
  static constexpr int kFramesPerBuf = kSampleRate / 100;  // 480 = 10ms
  static constexpr int kSamplesPerBuf = kFramesPerBuf * kChannels;
  static constexpr int kBytesPerBuf = kSamplesPerBuf * sizeof(int16_t);

  // pcm: interleaved s16le, exactly kFramesPerBuf frames of kChannels.
  using FrameCallback = std::function<void(const int16_t* pcm, size_t frames)>;

  PulseMonitorCapturer() = default;
  ~PulseMonitorCapturer();

  PulseMonitorCapturer(const PulseMonitorCapturer&) = delete;
  PulseMonitorCapturer& operator=(const PulseMonitorCapturer&) = delete;

  bool Start(FrameCallback callback);
  void Stop();

 private:
  // Asks the PulseAudio server for its default sink name and returns
  // "<sink>.monitor", or "" on failure. Fallback for servers where the
  // "@DEFAULT_MONITOR@" alias doesn't resolve for record streams.
  static std::string QueryDefaultSinkMonitor();

  void CaptureThread();

  void* pa_ = nullptr;  // pa_simple*
  std::thread thread_;
  std::atomic<bool> running_{false};
  FrameCallback callback_;
};

#endif  // __linux__

#endif  // SCREEN_AUDIO_TEST_PULSE_MONITOR_CAPTURER_H_
