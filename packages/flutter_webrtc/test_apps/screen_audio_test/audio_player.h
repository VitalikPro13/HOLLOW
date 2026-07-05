#ifndef SCREEN_AUDIO_TEST_AUDIO_PLAYER_H_
#define SCREEN_AUDIO_TEST_AUDIO_PLAYER_H_

#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>

// Cross-platform PCM audio player.
// Windows: waveOut, macOS: AudioQueue, Linux: PulseAudio simple API.

class AudioPlayer {
 public:
  static constexpr int kSampleRate = 48000;
  static constexpr int kChannels = 2;
  static constexpr int kFramesPerBuf = kSampleRate / 100;  // 480 = 10ms
  static constexpr int kSamplesPerBuf = kFramesPerBuf * kChannels;
  static constexpr int kBytesPerBuf = kSamplesPerBuf * sizeof(int16_t);

  // Jitter pre-buffer: hold playback (emit silence) until this much audio is
  // queued. Without it, any sender whose packets arrive bursty (mobile sends
  // 2x10ms packets per 20ms capture chunk, each jittered by a main-thread hop
  // + encode hop) underruns the pull callback every cycle -> regular
  // micro-gap distortion. Desktop senders (steady ~10ms WASAPI/SCK cadence)
  // masked this. The extra latency is imperceptible for a screen share.
  static constexpr size_t kPrebufferSamples =
      static_cast<size_t>(kSampleRate) / 1000 * 100 * kChannels;  // 100ms
  // On a mid-stream dry-out, wait only for this much before resuming — a
  // FULL re-prime would quantize every starvation stretch into a long
  // audible hole. Each dry-out still ratchets effective latency up (played
  // silence is never reclaimed), so a clumpy-but-realtime sender converges
  // to gap-free playback at whatever latency its clumping demands.
  static constexpr size_t kRebufferSamples =
      static_cast<size_t>(kSampleRate) / 1000 * 40 * kChannels;  // 40ms

  AudioPlayer();
  ~AudioPlayer();

  AudioPlayer(const AudioPlayer&) = delete;
  AudioPlayer& operator=(const AudioPlayer&) = delete;

  bool Start();
  void Stop();

  // Diagnostics snapshot (counters since the previous TakeStats call, queue
  // levels in samples). Logged periodically by the render loop so a bad
  // device test yields NUMBERS instead of guesses.
  struct Stats {
    size_t queue_now = 0;
    size_t queue_min = 0;
    size_t queue_max = 0;
    unsigned rebuffers = 0;
    unsigned trims = 0;
    uint64_t samples_pushed = 0;
    uint64_t samples_filled = 0;
  };

  Stats TakeStats() {
    std::lock_guard<std::mutex> lock(mu_);
    Stats s = stats_;
    s.queue_now = queue_.size();
    stats_ = Stats{};
    stats_.queue_min = queue_.size();
    stats_.queue_max = queue_.size();
    return s;
  }

  // Shared across all platform backends (the backends only differ in the
  // audio-out API driving FillBuffer).
  void Push(const int16_t* data, size_t frames, int channels) {
    const size_t total = frames * channels;
    std::lock_guard<std::mutex> lock(mu_);
    if (queue_.size() + total > static_cast<size_t>(kSampleRate * kChannels)) {
      size_t drop = queue_.size() + total - kSampleRate / 5 * kChannels;
      if (drop > queue_.size()) drop = queue_.size();
      drop -= drop % channels;
      for (size_t i = 0; i < drop; ++i) queue_.pop_front();
      stats_.trims++;
    }
    for (size_t i = 0; i < total; ++i) queue_.push_back(data[i]);
    stats_.samples_pushed += total;
    if (queue_.size() > stats_.queue_max) stats_.queue_max = queue_.size();
  }

  // Called by the platform callback to fill a buffer. Returns the number of
  // samples written; the callback zero-fills the remainder (silence).
  size_t FillBuffer(int16_t* out, size_t max_samples) {
    std::lock_guard<std::mutex> lock(mu_);
    if (queue_.size() < stats_.queue_min) stats_.queue_min = queue_.size();
    if (buffering_) {
      if (queue_.size() < rebuffer_target_) return 0;  // keep priming
      buffering_ = false;
      rebuffer_target_ = kRebufferSamples;  // later dry-outs re-prime less
    }
    if (queue_.size() < max_samples) {
      // Ran dry: drain the tail, then re-prime briefly before resuming so a
      // struggling sender produces ONE short gap, not a gap per callback.
      buffering_ = true;
      stats_.rebuffers++;
    }
    size_t n = (queue_.size() >= max_samples) ? max_samples : queue_.size();
    for (size_t i = 0; i < n; ++i) {
      out[i] = queue_.front();
      queue_.pop_front();
    }
    stats_.samples_filled += n;
    return n;
  }

  bool running_ = false;
  std::mutex mu_;
  std::deque<int16_t> queue_;
  bool buffering_ = true;
  size_t rebuffer_target_ = kPrebufferSamples;  // initial prime is the full one
  Stats stats_;

  // Platform-specific handle storage.
  void* platform_handle_ = nullptr;
};

#endif  // SCREEN_AUDIO_TEST_AUDIO_PLAYER_H_
