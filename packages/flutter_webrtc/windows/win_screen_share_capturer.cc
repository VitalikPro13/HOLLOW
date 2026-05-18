#include "win_screen_share_capturer.h"
#include "win_screen_recorder.h"
#include "capture_log.h"

namespace flutter_webrtc_plugin {

WinScreenShareCapturer::WinScreenShareCapturer() = default;

WinScreenShareCapturer::~WinScreenShareCapturer() {
  Stop();
}

bool WinScreenShareCapturer::Start(
    HMONITOR monitor, uint32_t fps,
    libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> video_source) {
  if (!video_source.get()) return false;
  video_source_ = video_source;

  auto& recorder = WinScreenRecorder::GetInstance();
  bool ok = recorder.StartCapture(
      monitor, fps,
      [this](const WinScreenRecorder::NV12Frame& nv12) {
        OnFrame(nv12);
      });

  if (!ok) {
    CAPLOG("WinScreenShareCapturer::Start failed");
    video_source_ = nullptr;
    return false;
  }
  CAPLOG("WinScreenShareCapturer::Start OK");
  return true;
}

void WinScreenShareCapturer::Stop() {
  WinScreenRecorder::GetInstance().StopCapture();
  video_source_ = nullptr;
}

bool WinScreenShareCapturer::IsCapturing() const {
  return WinScreenRecorder::GetInstance().IsCapturing();
}

void WinScreenShareCapturer::OnFrame(
    const WinScreenRecorder::NV12Frame& nv12) {
  if (!video_source_.get()) return;
  if (nv12.width <= 0 || nv12.height <= 0) return;

  // NV12 data goes straight to WebRTC — VP8/VP9/AV1 consume it directly.
  auto frame = libwebrtc::RTCVideoFrame::CreateFromNV12(
      nv12.width, nv12.height,
      nv12.data_y, nv12.stride_y,
      nv12.data_uv, nv12.stride_uv);

  if (frame.get()) {
    static bool first = true;
    if (first) {
      CAPLOG("OnFrame: first NV12 frame → OnCapturedFrame %dx%d", nv12.width, nv12.height);
      first = false;
    }
    video_source_->OnCapturedFrame(frame);
  } else {
    static bool logged = false;
    if (!logged) {
      CAPLOG("OnFrame: CreateFromNV12 returned null!");
      logged = true;
    }
  }
}

}  // namespace flutter_webrtc_plugin
