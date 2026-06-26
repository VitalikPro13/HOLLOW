#ifndef FLUTTER_SCRREN_CAPTURE_HXX
#define FLUTTER_SCRREN_CAPTURE_HXX

#include "flutter_common.h"
#include "flutter_webrtc_base.h"

#include "loopback_capturer.h"
#include "rtc_audio_source.h"
#include "rtc_audio_track.h"
#include "rtc_desktop_capturer.h"
#include "rtc_desktop_media_list.h"

#include <memory>

#if defined(_WIN32)
namespace flutter_webrtc_plugin {
class ScreenAudioCapturer;
class OpusDecoderWrapper;
class WasapiAudioRenderer;
#if defined(HOLLOW_USE_NATIVE_SCREEN_CAPTURER)
class NativeScreenCapturer;
#endif
}  // namespace flutter_webrtc_plugin
#endif

namespace flutter_webrtc_plugin {

class FlutterScreenCapture : public MediaListObserver,
                             public DesktopCapturerObserver {
 public:
  FlutterScreenCapture(FlutterWebRTCBase* base);
  ~FlutterScreenCapture();

  void GetDisplayMedia(const EncodableMap& constraints,
                       std::unique_ptr<MethodResultProxy> result);

  void CleanupNativeCapturersForStream(const std::string& stream_id);

  void GetDesktopSources(const EncodableList& types,
                         std::unique_ptr<MethodResultProxy> result);

  void UpdateDesktopSources(const EncodableList& types,
                            std::unique_ptr<MethodResultProxy> result);

  void GetDesktopSourceThumbnail(std::string source_id,
                                 int width,
                                 int height,
                                 std::unique_ptr<MethodResultProxy> result);

  void StartScreenAudioCapture(const EncodableMap& params,
                                std::unique_ptr<MethodResultProxy> result);
  void StopScreenAudioCapture(const EncodableMap& params,
                               std::unique_ptr<MethodResultProxy> result);
  void ScreenAudioRender(const EncodableMap& params,
                          std::unique_ptr<MethodResultProxy> result);
  void ScreenAudioRenderStop(const EncodableMap& params,
                              std::unique_ptr<MethodResultProxy> result);

 protected:
  void OnMediaSourceAdded(scoped_refptr<MediaSource> source) override;

  void OnMediaSourceRemoved(scoped_refptr<MediaSource> source) override;

  void OnMediaSourceNameChanged(scoped_refptr<MediaSource> source) override;

  void OnMediaSourceThumbnailChanged(
      scoped_refptr<MediaSource> source) override;

  void OnStart(scoped_refptr<RTCDesktopCapturer> capturer) override;

  void OnPaused(scoped_refptr<RTCDesktopCapturer> capturer) override;

  void OnStop(scoped_refptr<RTCDesktopCapturer> capturer) override;

  void OnError(scoped_refptr<RTCDesktopCapturer> capturer) override;

 private:
  bool BuildDesktopSourcesList(const EncodableList& types, bool force_reload);

 private:
  FlutterWebRTCBase* base_;
  std::map<DesktopType, scoped_refptr<RTCDesktopMediaList>> medialist_;
  std::vector<scoped_refptr<MediaSource>> sources_;

  // Loopback (system/app) audio session for screen share — adopted from
  // upstream 1.5.2 (#2060). Single session (Hollow shares one screen at a
  // time). CreateLoopbackCapturer returns nullptr off-Windows, so these stay
  // null there. Cross-platform interface, so NOT inside the _WIN32 block.
  std::unique_ptr<LoopbackCapturer> loopback_capturer_;
  scoped_refptr<RTCAudioSource> loopback_audio_source_;

#if defined(_WIN32)
  std::map<std::string, std::unique_ptr<ScreenAudioCapturer>>
      screen_audio_capturers_;

  struct AudioRenderSession {
    std::unique_ptr<OpusDecoderWrapper> decoder;
    std::unique_ptr<WasapiAudioRenderer> renderer;
  };
  std::map<std::string, std::unique_ptr<AudioRenderSession>>
      audio_render_sessions_;

#if defined(HOLLOW_USE_NATIVE_SCREEN_CAPTURER)
  // Native Graphics-Capture video — gated off on stock libwebrtc (depends on
  // the custom CreateFromBGRA). See project_flutter_webrtc_152_upgrade.
  std::map<std::string, std::unique_ptr<NativeScreenCapturer>>
      native_capturers_;
#endif
#endif
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_SCRREN_CAPTURE_HXX