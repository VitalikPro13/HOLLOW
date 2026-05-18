#ifndef FLUTTER_WEBRTC_WIN_SCREEN_SHARE_CAPTURER_H_
#define FLUTTER_WEBRTC_WIN_SCREEN_SHARE_CAPTURER_H_

#include <windows.h>
#include <cstdint>

#include "rtc_video_frame.h"
#include "rtc_video_source.h"
#include "win_screen_recorder.h"

namespace flutter_webrtc_plugin {

// Feeds native Windows Graphics Capture frames into a WebRTC video source.
// GPU BGRA→NV12 via D3D11 Video Processor (zero CPU color conversion).
// VP8/VP9/AV1 encoders consume NV12 directly.
class WinScreenShareCapturer {
 public:
  WinScreenShareCapturer();
  ~WinScreenShareCapturer();

  WinScreenShareCapturer(const WinScreenShareCapturer&) = delete;
  WinScreenShareCapturer& operator=(const WinScreenShareCapturer&) = delete;

  bool Start(HMONITOR monitor, uint32_t fps,
             libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> video_source);
  void Stop();
  bool IsCapturing() const;

 private:
  void OnFrame(const WinScreenRecorder::NV12Frame& nv12);
  libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> video_source_;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_WIN_SCREEN_SHARE_CAPTURER_H_
