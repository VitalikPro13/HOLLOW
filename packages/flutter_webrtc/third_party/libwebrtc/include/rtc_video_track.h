#ifndef LIB_WEBRTC_RTC_VIDEO_TRACK_HXX
#define LIB_WEBRTC_RTC_VIDEO_TRACK_HXX

#include "rtc_media_track.h"
#include "rtc_types.h"
#include "rtc_video_frame.h"
#include "rtc_video_renderer.h"

namespace libwebrtc {

class RTCVideoTrack : public RTCMediaTrack {
 public:
  // Mirrors webrtc::VideoTrackInterface::ContentHint. kDetailed/kText force
  // the screencast encoding pipeline for this track's sender regardless of
  // the source's is_screencast(); kFluid forces the camera pipeline; kNone
  // defers to the source. See pc/rtp_sender.cc in upstream WebRTC.
  enum class ContentHint { kNone = 0, kFluid = 1, kDetailed = 2, kText = 3 };

  virtual void AddRenderer(
      RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>* renderer) = 0;

  virtual void RemoveRenderer(
      RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>* renderer) = 0;

  // NOTE: appended after the pre-existing virtuals on purpose — existing
  // vtable slot indices stay valid against older prebuilt binaries.
  virtual void SetContentHint(ContentHint hint) = 0;

 protected:
  ~RTCVideoTrack() {}
};
}  // namespace libwebrtc

#endif  // LIB_WEBRTC_RTC_VIDEO_TRACK_HXX
