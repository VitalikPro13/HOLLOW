#ifdef __linux__

#include "audio_player.h"

#include <pulse/simple.h>
#include <pulse/error.h>

#include <atomic>
#include <cstdio>
#include <thread>
#include <vector>

struct LinuxState {
  pa_simple* pa = nullptr;
  std::thread playback_thread;
  std::atomic<bool> running{false};
  AudioPlayer* player = nullptr;
};

static void PlaybackThread(LinuxState* ls) {
  std::vector<int16_t> buf(AudioPlayer::kSamplesPerBuf);
  int error = 0;

  while (ls->running.load()) {
    size_t n = ls->player->FillBuffer(buf.data(), AudioPlayer::kSamplesPerBuf);
    if (n < AudioPlayer::kSamplesPerBuf)
      std::memset(buf.data() + n, 0,
                  (AudioPlayer::kSamplesPerBuf - n) * sizeof(int16_t));

    if (pa_simple_write(ls->pa, buf.data(), AudioPlayer::kBytesPerBuf,
                         &error) < 0) {
      fprintf(stderr, "[AUDIO-PLAYER] pa_simple_write failed: %s\n",
              pa_strerror(error));
      break;
    }
  }
}

AudioPlayer::AudioPlayer() = default;

AudioPlayer::~AudioPlayer() { Stop(); }

bool AudioPlayer::Start() {
  if (running_) return true;

  auto* ls = new LinuxState();
  ls->player = this;

  pa_sample_spec ss = {};
  ss.format = PA_SAMPLE_S16LE;
  ss.channels = kChannels;
  ss.rate = kSampleRate;

  pa_buffer_attr ba = {};
  ba.maxlength = kBytesPerBuf * 8;
  ba.tlength = kBytesPerBuf * 2;
  ba.prebuf = kBytesPerBuf;
  ba.minreq = kBytesPerBuf;
  ba.fragsize = (uint32_t)-1;

  int error = 0;
  ls->pa = pa_simple_new(nullptr, "Hollow", PA_STREAM_PLAYBACK,
                          nullptr, "Screen Audio", &ss, nullptr, &ba, &error);
  if (!ls->pa) {
    fprintf(stderr, "[AUDIO-PLAYER] pa_simple_new failed: %s\n",
            pa_strerror(error));
    delete ls;
    return false;
  }

  running_ = true;
  ls->running.store(true);
  platform_handle_ = ls;

  ls->playback_thread = std::thread(PlaybackThread, ls);

  return true;
}

void AudioPlayer::Stop() {
  running_ = false;
  auto* ls = static_cast<LinuxState*>(platform_handle_);
  if (!ls) return;

  ls->running.store(false);
  if (ls->playback_thread.joinable()) ls->playback_thread.join();

  if (ls->pa) {
    pa_simple_drain(ls->pa, nullptr);
    pa_simple_free(ls->pa);
  }

  delete ls;
  platform_handle_ = nullptr;
}

// Push/FillBuffer live in audio_player.h (shared jitter pre-buffer logic).

#endif  // __linux__
