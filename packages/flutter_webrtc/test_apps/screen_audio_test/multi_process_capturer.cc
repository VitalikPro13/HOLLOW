#include "multi_process_capturer.h"

#ifdef _WIN32

#include <mmsystem.h>

#include <cstring>

#include "capture_log.h"
#include "process_audio_capturer.h"

#pragma comment(lib, "winmm.lib")

namespace {
constexpr int kSampleRate = 48000;
constexpr int kChannels = 2;
constexpr size_t kFrameSamples = 480;                         // 10ms / channel
constexpr size_t kFrameInterleaved = kFrameSamples * kChannels;  // 960
// Cap each source buffer at ~200ms so a runaway/faster source can't grow
// unbounded; drop oldest beyond it (latency stays bounded, like the plugin's
// packet-queue drop).
constexpr size_t kMaxBufferedInterleaved = kFrameInterleaved * 20;  // 200ms
}  // namespace

MultiProcessCapturer::MultiProcessCapturer() {
  stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
}

MultiProcessCapturer::~MultiProcessCapturer() {
  Stop();
  if (stop_event_) {
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
}

bool MultiProcessCapturer::Start(FrameCallback cb,
                                 const std::vector<DWORD>& pids) {
  if (running_.load()) return true;
  callback_ = std::move(cb);
  ResetEvent(stop_event_);

  if (!ProcessAudioCapturer::IsSupported()) {
    CAPLOG("MultiCapturer: process loopback requires Windows 10 2004+");
    return false;
  }

  // Pre-create every source slot so OnSourceFrame's captured index is valid the
  // instant a capture thread fires (capturers start producing immediately).
  for (DWORD pid : pids) {
    auto src = std::make_unique<Source>();
    src->pid = pid;
    src->capturer = std::make_unique<ProcessAudioCapturer>();
    sources_.push_back(std::move(src));
  }

  // Now start each INCLUDE capturer against its slot.
  size_t started = 0;
  for (size_t index = 0; index < sources_.size(); ++index) {
    Source* src = sources_[index].get();
    const DWORD pid = src->pid;
    bool ok = src->capturer->Start(
        [this, index](const void* data, int /*bits*/, int /*rate*/,
                      size_t /*channels*/, size_t frames) {
          OnSourceFrame(index, static_cast<const int16_t*>(data),
                        frames * kChannels);
        },
        pid, /*include_mode=*/true);
    if (ok) {
      ++started;
      CAPLOG("MultiCapturer: started INCLUDE capture for pid %u", pid);
    } else {
      CAPLOG("MultiCapturer: FAILED to start capture for pid %u", pid);
      src->capturer.reset();
    }
  }

  // Even with zero started sources we run the mixer so the stream emits silence
  // (a window whose app renders no audio). This is the CORRECT per-app answer —
  // never fall back to system capture here.
  running_ = true;
  mix_thread_ = std::thread([this]() { MixThread(); });

  CAPLOG("MultiCapturer: %zu/%zu source(s) capturing, mixer running",
         started, pids.size());
  return true;  // per-app path always "starts"; silence is valid output
}

void MultiProcessCapturer::Stop() {
  if (!running_.exchange(false)) return;
  SetEvent(stop_event_);
  if (mix_thread_.joinable()) mix_thread_.join();

  // Stop every source capturer (each joins its own WASAPI thread).
  for (auto& src : sources_) {
    if (src && src->capturer) src->capturer->Stop();
  }
  sources_.clear();
  CAPLOG("MultiCapturer: stopped");
}

void MultiProcessCapturer::OnSourceFrame(size_t index, const int16_t* pcm,
                                         size_t samples) {
  if (!running_.load()) return;
  std::lock_guard<std::mutex> lock(mix_mutex_);
  if (index >= sources_.size() || !sources_[index]) return;
  auto& buf = sources_[index]->buffer;
  buf.insert(buf.end(), pcm, pcm + samples);
  // Drop oldest if over the cap (keeps latency bounded under drift).
  if (buf.size() > kMaxBufferedInterleaved) {
    const size_t excess = buf.size() - kMaxBufferedInterleaved;
    buf.erase(buf.begin(), buf.begin() + excess);
  }
}

void MultiProcessCapturer::MixThread() {
  // 1ms timer resolution so the 10ms pacing wait doesn't drift to ~15ms
  // (which would emit ~64 fps instead of 100 → audible slowdown/glitching).
  timeBeginPeriod(1);

  CAPLOG("MultiCapturer: mix thread started");

  std::vector<int16_t> frame(kFrameInterleaved);

  // Phase-lock emission to wall clock: emit every 10ms of real time regardless
  // of wait jitter, so buffers drain at the true 100 fps rate.
  const ULONGLONG start = GetTickCount64();
  uint64_t emitted_frames = 0;

  while (running_.load()) {
    DWORD wait = WaitForSingleObject(stop_event_, 5);
    if (wait == WAIT_OBJECT_0 || !running_.load()) break;

    const ULONGLONG now = GetTickCount64();
    const uint64_t due_frames = (now - start) / 10;  // 10ms per frame

    while (emitted_frames < due_frames && running_.load()) {
      // Mix one 10ms frame: sum each source's next 480 stereo frames
      // (zero-fill the shortfall), saturating to int16.
      std::memset(frame.data(), 0, kFrameInterleaved * sizeof(int16_t));

      {
        std::lock_guard<std::mutex> lock(mix_mutex_);
        for (auto& src : sources_) {
          if (!src) continue;
          auto& buf = src->buffer;
          if (buf.empty()) continue;

          const size_t take = std::min(buf.size(), kFrameInterleaved);
          for (size_t i = 0; i < take; ++i) {
            int32_t mixed = static_cast<int32_t>(frame[i]) +
                            static_cast<int32_t>(buf[i]);
            if (mixed > 32767) mixed = 32767;
            if (mixed < -32768) mixed = -32768;
            frame[i] = static_cast<int16_t>(mixed);
          }
          buf.erase(buf.begin(), buf.begin() + take);
        }
      }

      if (callback_) {
        callback_(frame.data(), 16, kSampleRate, kChannels, kFrameSamples);
      }
      ++emitted_frames;
    }
  }

  timeEndPeriod(1);
  CAPLOG("MultiCapturer: mix thread exiting (emitted %llu frames)",
         static_cast<unsigned long long>(emitted_frames));
}

#endif  // _WIN32
