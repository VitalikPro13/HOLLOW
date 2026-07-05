#ifdef _WIN32

#include "audio_player.h"

#include <windows.h>
#include <mmsystem.h>

#pragma comment(lib, "winmm.lib")

static constexpr int kNumBuffers = 8;

struct WinState {
  HWAVEOUT hwo = nullptr;
  WAVEHDR hdrs[kNumBuffers] = {};
  int16_t bufs[kNumBuffers][AudioPlayer::kSamplesPerBuf] = {};
  AudioPlayer* player = nullptr;
};

static void CALLBACK WaveOutCb(HWAVEOUT, UINT msg, DWORD_PTR inst,
                                DWORD_PTR p1, DWORD_PTR) {
  if (msg != WOM_DONE) return;
  auto* ws = reinterpret_cast<WinState*>(inst);
  auto* hdr = reinterpret_cast<WAVEHDR*>(p1);
  if (!ws->player) return;

  auto* out = reinterpret_cast<int16_t*>(hdr->lpData);
  size_t n = ws->player->FillBuffer(out, AudioPlayer::kSamplesPerBuf);
  if (n < AudioPlayer::kSamplesPerBuf)
    std::memset(out + n, 0, (AudioPlayer::kSamplesPerBuf - n) * sizeof(int16_t));

  waveOutWrite(ws->hwo, hdr, sizeof(WAVEHDR));
}

AudioPlayer::AudioPlayer() = default;

AudioPlayer::~AudioPlayer() { Stop(); }

bool AudioPlayer::Start() {
  if (running_) return true;

  auto* ws = new WinState();
  ws->player = this;

  WAVEFORMATEX wfx = {};
  wfx.wFormatTag = WAVE_FORMAT_PCM;
  wfx.nChannels = kChannels;
  wfx.nSamplesPerSec = kSampleRate;
  wfx.wBitsPerSample = 16;
  wfx.nBlockAlign = kChannels * sizeof(int16_t);
  wfx.nAvgBytesPerSec = kSampleRate * wfx.nBlockAlign;

  MMRESULT mr = waveOutOpen(&ws->hwo, WAVE_MAPPER, &wfx,
                             reinterpret_cast<DWORD_PTR>(WaveOutCb),
                             reinterpret_cast<DWORD_PTR>(ws),
                             CALLBACK_FUNCTION);
  if (mr != MMSYSERR_NOERROR) {
    delete ws;
    return false;
  }

  running_ = true;
  platform_handle_ = ws;

  for (int i = 0; i < kNumBuffers; ++i) {
    std::memset(ws->bufs[i], 0, kBytesPerBuf);
    ws->hdrs[i].lpData = reinterpret_cast<LPSTR>(ws->bufs[i]);
    ws->hdrs[i].dwBufferLength = kBytesPerBuf;
    ws->hdrs[i].dwFlags = 0;
    waveOutPrepareHeader(ws->hwo, &ws->hdrs[i], sizeof(WAVEHDR));
    waveOutWrite(ws->hwo, &ws->hdrs[i], sizeof(WAVEHDR));
  }

  return true;
}

void AudioPlayer::Stop() {
  running_ = false;
  auto* ws = static_cast<WinState*>(platform_handle_);
  if (!ws) return;

  ws->player = nullptr;
  waveOutReset(ws->hwo);
  for (int i = 0; i < kNumBuffers; ++i)
    waveOutUnprepareHeader(ws->hwo, &ws->hdrs[i], sizeof(WAVEHDR));
  waveOutClose(ws->hwo);

  delete ws;
  platform_handle_ = nullptr;
}

// Push/FillBuffer live in audio_player.h (shared jitter pre-buffer logic).

#endif  // _WIN32
