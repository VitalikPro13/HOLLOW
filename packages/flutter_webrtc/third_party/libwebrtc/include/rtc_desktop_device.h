#ifndef LIB_WEBRTC_RTC_DESKTOP_DEVICE_HXX
#define LIB_WEBRTC_RTC_DESKTOP_DEVICE_HXX

#include "rtc_types.h"
#include <map>
#include <string>

namespace libwebrtc {

class MediaSource;
class RTCDesktopCapturer;
class RTCDesktopMediaList;

class RTCDesktopDevice : public RefCountInterface {
 public:
  virtual scoped_refptr<RTCDesktopCapturer> CreateDesktopCapturer(
      scoped_refptr<MediaSource> source, bool showCursor = true) = 0;
  virtual scoped_refptr<RTCDesktopMediaList> GetDesktopMediaList(
      DesktopType type) = 0;

  // HOLLOW (appended virtual — keep LAST so pre-existing vtable slots stay
  // valid against older prebuilt binaries): create a capturer WITHOUT a
  // MediaSource from an enumerated media list. The one real user is the
  // Wayland portal-first share path (type == kAnyScreenContent): building a
  // media list on Wayland pops an xdg-desktop-portal dialog just to
  // enumerate, so the picker skips enumeration and starts capture directly —
  // the portal dialog itself is the picker (screens AND windows).
  // source_id is a caller-chosen stable id: webrtc's RestoreTokenManager
  // banks the portal restore token under it, so a later capture with the
  // SAME id restores the previous selection without re-prompting (within
  // this process), while a NEW id forces a fresh portal prompt. Returns
  // nullptr when the session has no backend for the requested type.
  virtual scoped_refptr<RTCDesktopCapturer> CreateDesktopCapturer(
      DesktopType type, int64_t source_id, bool show_cursor) = 0;

 protected:
  virtual ~RTCDesktopDevice() {}
};

}  // namespace libwebrtc

#endif  // LIB_WEBRTC_RTC_VIDEO_DEVICE_HXX