#ifndef FLUTTER_WEBRTC_WASAPI_LOOPBACK_CAPTURER_H_
#define FLUTTER_WEBRTC_WASAPI_LOOPBACK_CAPTURER_H_

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

#include <atomic>
#include <functional>
#include <thread>
#include <vector>

namespace flutter_webrtc_plugin {

// Captures the system's default audio render endpoint in loopback mode
// (what would otherwise be played through speakers). Emits 10ms frames of
// 16-bit PCM at the device's native sample rate via the supplied callback.
//
// The callback signature matches libwebrtc's RTCAudioSource::CaptureFrame:
//   (pcm_data, bits_per_sample, sample_rate, channels, frames_per_10ms)
class WasapiLoopbackCapturer {
 public:
  using FrameCallback = std::function<void(const void* data,
                                           int bits_per_sample,
                                           int sample_rate,
                                           size_t channels,
                                           size_t frames)>;

  WasapiLoopbackCapturer();
  ~WasapiLoopbackCapturer();

  WasapiLoopbackCapturer(const WasapiLoopbackCapturer&) = delete;
  WasapiLoopbackCapturer& operator=(const WasapiLoopbackCapturer&) = delete;

  // Opens the default render endpoint in loopback mode and starts the
  // capture thread. Returns false on failure (no device, access denied,
  // unsupported format, etc.).
  bool Start(FrameCallback cb);

  // Stops the capture thread and releases all resources. Safe to call
  // multiple times and from the destructor.
  void Stop();

 private:
  void CaptureThread();

  FrameCallback callback_;
  std::atomic<bool> running_{false};
  std::thread thread_;
  HANDLE capture_event_ = nullptr;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_WASAPI_LOOPBACK_CAPTURER_H_
