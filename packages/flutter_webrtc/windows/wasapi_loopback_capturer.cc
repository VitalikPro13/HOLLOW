#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "wasapi_loopback_capturer.h"

#include <avrt.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ksmedia.h>
#include <mmreg.h>

#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

#pragma comment(lib, "Mmdevapi.lib")
#pragma comment(lib, "Avrt.lib")

namespace flutter_webrtc_plugin {
namespace {

constexpr REFERENCE_TIME kHns100PerSecond = 10'000'000LL;
constexpr REFERENCE_TIME kBufferDurationHns = kHns100PerSecond;  // 1 second
constexpr int kFrameDurationMs = 10;

template <class T>
void SafeRelease(T*& ptr) {
  if (ptr) {
    ptr->Release();
    ptr = nullptr;
  }
}

inline int16_t FloatToInt16(float s) {
  if (s > 1.0f) s = 1.0f;
  if (s < -1.0f) s = -1.0f;
  return static_cast<int16_t>(s * 32767.0f);
}

bool IsFloatFormat(const WAVEFORMATEX* fmt) {
  if (fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  }
  return false;
}

bool IsPcmFormat(const WAVEFORMATEX* fmt) {
  if (fmt->wFormatTag == WAVE_FORMAT_PCM) return true;
  if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_PCM;
  }
  return false;
}

}  // namespace

WasapiLoopbackCapturer::WasapiLoopbackCapturer() = default;

WasapiLoopbackCapturer::~WasapiLoopbackCapturer() {
  Stop();
}

bool WasapiLoopbackCapturer::Start(FrameCallback cb) {
  if (running_.load()) return true;
  callback_ = std::move(cb);

  capture_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!capture_event_) {
    std::cerr << "[WASAPI] CreateEvent failed\n";
    return false;
  }

  running_.store(true);
  thread_ = std::thread(&WasapiLoopbackCapturer::CaptureThread, this);
  return true;
}

void WasapiLoopbackCapturer::Stop() {
  if (!running_.exchange(false)) return;
  if (capture_event_) SetEvent(capture_event_);
  if (thread_.joinable()) thread_.join();
  if (capture_event_) {
    CloseHandle(capture_event_);
    capture_event_ = nullptr;
  }
}

void WasapiLoopbackCapturer::CaptureThread() {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_initialized = SUCCEEDED(hr);

  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* audio_client = nullptr;
  IAudioCaptureClient* capture_client = nullptr;
  WAVEFORMATEX* mix_format = nullptr;
  HANDLE mm_task = nullptr;

  auto cleanup = [&]() {
    if (audio_client) audio_client->Stop();
    if (mm_task) AvRevertMmThreadCharacteristics(mm_task);
    SafeRelease(capture_client);
    SafeRelease(audio_client);
    SafeRelease(device);
    SafeRelease(enumerator);
    if (mix_format) {
      CoTaskMemFree(mix_format);
      mix_format = nullptr;
    }
    if (com_initialized) CoUninitialize();
  };

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] MMDeviceEnumerator create failed: 0x" << std::hex
              << hr << "\n";
    cleanup();
    return;
  }

  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] GetDefaultAudioEndpoint failed: 0x" << std::hex
              << hr << "\n";
    cleanup();
    return;
  }

  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&audio_client));
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] Activate IAudioClient failed: 0x" << std::hex << hr
              << "\n";
    cleanup();
    return;
  }

  hr = audio_client->GetMixFormat(&mix_format);
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] GetMixFormat failed: 0x" << std::hex << hr << "\n";
    cleanup();
    return;
  }

  const bool is_float = IsFloatFormat(mix_format);
  const bool is_pcm = IsPcmFormat(mix_format);
  if (!is_float && !is_pcm) {
    std::cerr << "[WASAPI] Unsupported format\n";
    cleanup();
    return;
  }
  if (is_pcm && mix_format->wBitsPerSample != 16 &&
      mix_format->wBitsPerSample != 32) {
    std::cerr << "[WASAPI] Unsupported PCM bit depth: "
              << mix_format->wBitsPerSample << "\n";
    cleanup();
    return;
  }

  const UINT32 sample_rate = mix_format->nSamplesPerSec;
  const WORD channels = mix_format->nChannels;
  const WORD bytes_per_sample = mix_format->wBitsPerSample / 8;

  hr = audio_client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      kBufferDurationHns, 0, mix_format, nullptr);
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] IAudioClient::Initialize failed: 0x" << std::hex
              << hr << "\n";
    cleanup();
    return;
  }

  hr = audio_client->SetEventHandle(capture_event_);
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] SetEventHandle failed: 0x" << std::hex << hr
              << "\n";
    cleanup();
    return;
  }

  hr = audio_client->GetService(__uuidof(IAudioCaptureClient),
                                reinterpret_cast<void**>(&capture_client));
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] GetService IAudioCaptureClient failed: 0x"
              << std::hex << hr << "\n";
    cleanup();
    return;
  }

  DWORD task_index = 0;
  mm_task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);

  hr = audio_client->Start();
  if (FAILED(hr)) {
    std::cerr << "[WASAPI] IAudioClient::Start failed: 0x" << std::hex << hr
              << "\n";
    cleanup();
    return;
  }

  const size_t frames_per_10ms = sample_rate / (1000 / kFrameDurationMs);
  std::vector<int16_t> accum;
  accum.reserve(frames_per_10ms * channels * 2);

  while (running_.load()) {
    DWORD wait = WaitForSingleObject(capture_event_, 2000);
    if (!running_.load()) break;
    if (wait != WAIT_OBJECT_0) continue;

    UINT32 packet_frames = 0;
    hr = capture_client->GetNextPacketSize(&packet_frames);
    while (SUCCEEDED(hr) && packet_frames != 0 && running_.load()) {
      BYTE* raw = nullptr;
      UINT32 frames_available = 0;
      DWORD flags = 0;
      hr = capture_client->GetBuffer(&raw, &frames_available, &flags, nullptr,
                                     nullptr);
      if (FAILED(hr)) break;

      const size_t total_samples =
          static_cast<size_t>(frames_available) * channels;
      const size_t prev_size = accum.size();
      accum.resize(prev_size + total_samples);
      int16_t* out = accum.data() + prev_size;

      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
        std::memset(out, 0, total_samples * sizeof(int16_t));
      } else if (is_float) {
        const float* src = reinterpret_cast<const float*>(raw);
        for (size_t i = 0; i < total_samples; ++i) {
          out[i] = FloatToInt16(src[i]);
        }
      } else if (bytes_per_sample == 2) {
        std::memcpy(out, raw, total_samples * sizeof(int16_t));
      } else {
        const int32_t* src = reinterpret_cast<const int32_t*>(raw);
        for (size_t i = 0; i < total_samples; ++i) {
          out[i] = static_cast<int16_t>(src[i] >> 16);
        }
      }

      capture_client->ReleaseBuffer(frames_available);

      const size_t samples_per_frame = frames_per_10ms * channels;
      size_t emit_offset = 0;
      while (accum.size() - emit_offset >= samples_per_frame) {
        if (callback_) {
          callback_(accum.data() + emit_offset, 16,
                    static_cast<int>(sample_rate),
                    static_cast<size_t>(channels), frames_per_10ms);
        }
        emit_offset += samples_per_frame;
      }
      if (emit_offset > 0) {
        accum.erase(accum.begin(), accum.begin() + emit_offset);
      }

      hr = capture_client->GetNextPacketSize(&packet_frames);
    }
  }

  cleanup();
}

}  // namespace flutter_webrtc_plugin
