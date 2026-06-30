#ifndef SCREEN_AUDIO_TEST_MULTI_PROCESS_CAPTURER_H_
#define SCREEN_AUDIO_TEST_MULTI_PROCESS_CAPTURER_H_

// Windows-only: capture a SET of process ids via WASAPI process-loopback INCLUDE
// and MIX them into one 48kHz-stereo 10ms stream. This is the per-app (window)
// share path — Discord captures each target application's audio with an INCLUDE
// filter and mixes; there is no per-audio-session filter in Windows, so a set of
// INCLUDE captures + a mixer is the correct model.
//
// Each underlying ProcessAudioCapturer delivers 10ms (480-frame) stereo chunks
// asynchronously. We buffer each source independently and a mixer thread emits a
// steady 10ms combined frame, zero-filling any source that is momentarily short
// (a silent app simply contributes silence — exactly the right answer, with NO
// fallback to system-wide capture).

#ifdef _WIN32

#include <windows.h>

#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

class ProcessAudioCapturer;

class MultiProcessCapturer {
 public:
  // Same shape as ProcessAudioCapturer's callback: always 48kHz, 16-bit, 2ch,
  // 480 frames (10ms).
  using FrameCallback = std::function<void(const void* data,
                                           int bits_per_sample,
                                           int sample_rate,
                                           size_t channels,
                                           size_t frames)>;

  MultiProcessCapturer();
  ~MultiProcessCapturer();

  MultiProcessCapturer(const MultiProcessCapturer&) = delete;
  MultiProcessCapturer& operator=(const MultiProcessCapturer&) = delete;

  // Start INCLUDE-capturing every pid in `pids` and mixing. Returns true if at
  // least one source capturer started. An empty `pids` still "succeeds" and
  // emits silence (the app renders no audio) — callers must NOT treat that as a
  // reason to fall back to system capture.
  bool Start(FrameCallback cb, const std::vector<DWORD>& pids);
  void Stop();

 private:
  struct Source {
    std::unique_ptr<ProcessAudioCapturer> capturer;
    DWORD pid = 0;
    std::deque<int16_t> buffer;  // interleaved stereo, guarded by mix_mutex_
  };

  void MixThread();
  void OnSourceFrame(size_t index, const int16_t* pcm, size_t samples);

  FrameCallback callback_;
  std::vector<std::unique_ptr<Source>> sources_;

  std::mutex mix_mutex_;          // guards every Source::buffer
  std::atomic<bool> running_{false};
  std::thread mix_thread_;
  HANDLE stop_event_ = nullptr;
};

#endif  // _WIN32

#endif  // SCREEN_AUDIO_TEST_MULTI_PROCESS_CAPTURER_H_
