#include "flutter_screen_capture.h"

#if defined(_WIN32)
// Hollow fork native paths kept across the 1.5.2 rebase: the data-channel
// ScreenAudio render pipeline (screen_audio_capturer/opus_decoder/
// wasapi_audio_renderer). The old in-track wasapi_loopback_capturer is gone —
// upstream's loopback_capturer (#2060) supersedes it (see GetDisplayMedia).
// native_screen_capturer is NOT included: it depends on the custom-libwebrtc
// CreateFromBGRA, absent in stock m144. Screen share now uses libwebrtc's own
// desktop capturer. See project_flutter_webrtc_152_upgrade.
#include "../../../windows/screen_audio_capturer.h"
#include "../../../windows/opus_decoder_wrapper.h"
#include "../../../windows/wasapi_audio_renderer.h"
#endif

#include "loopback_capturer.h"
#include "rtc_audio_source.h"
#include "rtc_audio_track.h"

namespace flutter_webrtc_plugin {

FlutterScreenCapture::FlutterScreenCapture(FlutterWebRTCBase* base)
    : base_(base) {}

FlutterScreenCapture::~FlutterScreenCapture() = default;

bool FlutterScreenCapture::BuildDesktopSourcesList(const EncodableList& types,
                                                   bool force_reload) {
  size_t size = types.size();
  sources_.clear();
  for (size_t i = 0; i < size; i++) {
    std::string type_str = GetValue<std::string>(types[i]);
    DesktopType desktop_type = DesktopType::kScreen;
    if (type_str == "screen") {
      desktop_type = DesktopType::kScreen;
    } else if (type_str == "window") {
      desktop_type = DesktopType::kWindow;
    } else {
      // std::cout << "Unknown type " << type_str << std::endl;
      return false;
    }
    scoped_refptr<RTCDesktopMediaList> source_list;
    auto it = medialist_.find(desktop_type);
    if (it != medialist_.end()) {
      source_list = (*it).second;
    } else {
      source_list = base_->desktop_device_->GetDesktopMediaList(desktop_type);
      source_list->RegisterMediaListObserver(this);
      medialist_[desktop_type] = source_list;
    }
    source_list->UpdateSourceList(force_reload);
    int count = source_list->GetSourceCount();
    for (int j = 0; j < count; j++) {
      sources_.push_back(source_list->GetSource(j));
    }
  }
  return true;
}

void FlutterScreenCapture::GetDesktopSources(
    const EncodableList& types,
    std::unique_ptr<MethodResultProxy> result) {
  if (!BuildDesktopSourcesList(types, true)) {
    result->Error("Bad Arguments", "Failed to get desktop sources");
    return;
  }

  EncodableList sources;
  for (auto source : sources_) {
    EncodableMap info;
    info[EncodableValue("id")] = EncodableValue(source->id().std_string());
    info[EncodableValue("name")] = EncodableValue(source->name().std_string());
    info[EncodableValue("type")] =
        EncodableValue(source->type() == kWindow ? "window" : "screen");
    // TODO "thumbnailSize"
    info[EncodableValue("thumbnailSize")] = EncodableMap{
        {EncodableValue("width"), EncodableValue(0)},
        {EncodableValue("height"), EncodableValue(0)},
    };
#if defined(_WIN32)
    if (source->type() == kWindow) {
      int64_t hwnd_val = 0;
      try { hwnd_val = std::stoll(source->id().std_string()); } catch (...) {}
      if (hwnd_val != 0) {
        DWORD pid = 0;
        GetWindowThreadProcessId(reinterpret_cast<HWND>(hwnd_val), &pid);
        info[EncodableValue("pid")] = EncodableValue(static_cast<int64_t>(pid));
      }
    }
#endif
    sources.push_back(EncodableValue(info));
  }

  std::cout << " sources: " << sources.size() << std::endl;
  auto map = EncodableMap();
  map[EncodableValue("sources")] = sources;
  result->Success(EncodableValue(map));
}

void FlutterScreenCapture::UpdateDesktopSources(
    const EncodableList& types,
    std::unique_ptr<MethodResultProxy> result) {
  if (!BuildDesktopSourcesList(types, false)) {
    result->Error("Bad Arguments", "Failed to update desktop sources");
    return;
  }
  auto map = EncodableMap();
  map[EncodableValue("result")] = true;
  result->Success(EncodableValue(map));
}

void FlutterScreenCapture::OnMediaSourceAdded(
    scoped_refptr<MediaSource> source) {
  std::cout << " OnMediaSourceAdded: " << source->id().std_string()
            << std::endl;

  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceAdded";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("name")] = EncodableValue(source->name().std_string());
  info[EncodableValue("type")] =
      EncodableValue(source->type() == kWindow ? "window" : "screen");
  // TODO "thumbnailSize"
  info[EncodableValue("thumbnailSize")] = EncodableMap{
      {EncodableValue("width"), EncodableValue(0)},
      {EncodableValue("height"), EncodableValue(0)},
  };
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceRemoved(
    scoped_refptr<MediaSource> source) {
  std::cout << " OnMediaSourceRemoved: " << source->id().std_string()
            << std::endl;

  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceRemoved";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceNameChanged(
    scoped_refptr<MediaSource> source) {
  std::cout << " OnMediaSourceNameChanged: " << source->id().std_string()
            << std::endl;

  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceNameChanged";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("name")] = EncodableValue(source->name().std_string());
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceThumbnailChanged(
    scoped_refptr<MediaSource> source) {
  std::cout << " OnMediaSourceThumbnailChanged: " << source->id().std_string()
            << std::endl;

  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceThumbnailChanged";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("thumbnail")] =
      EncodableValue(source->thumbnail().std_vector());
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnStart(scoped_refptr<RTCDesktopCapturer> capturer) {
  // std::cout << " OnStart: " << capturer->source()->id().std_string()
  //          << std::endl;
}

void FlutterScreenCapture::OnPaused(
    scoped_refptr<RTCDesktopCapturer> capturer) {
  // std::cout << " OnPaused: " << capturer->source()->id().std_string()
  //          << std::endl;
}

void FlutterScreenCapture::OnStop(scoped_refptr<RTCDesktopCapturer> capturer) {
  // std::cout << " OnStop: " << capturer->source()->id().std_string()
  //          << std::endl;
  // Adopted from upstream 1.5.2: tear down the loopback audio session when the
  // desktop capturer stops.
  if (loopback_capturer_) {
    loopback_capturer_->Stop();
    loopback_capturer_.reset();
    loopback_audio_source_ = nullptr;
  }
}

void FlutterScreenCapture::OnError(scoped_refptr<RTCDesktopCapturer> capturer) {
  // std::cout << " OnError: " << capturer->source()->id().std_string()
  //          << std::endl;
}

void FlutterScreenCapture::GetDesktopSourceThumbnail(
    std::string source_id,
    int width,
    int height,
    std::unique_ptr<MethodResultProxy> result) {
  scoped_refptr<MediaSource> source;
  for (auto src : sources_) {
    if (src->id().std_string() == source_id) {
      source = src;
    }
  }
  if (source.get() == nullptr) {
    result->Error("Bad Arguments", "Failed to get desktop source thumbnail");
    return;
  }
  std::cout << " GetDesktopSourceThumbnail: " << source->id().std_string()
            << std::endl;
  source->UpdateThumbnail();
  result->Success(EncodableValue(source->thumbnail().std_vector()));
}

void FlutterScreenCapture::GetDisplayMedia(
    const EncodableMap& constraints,
    std::unique_ptr<MethodResultProxy> result) {
  std::string source_id = "0";
  // DesktopType source_type = kScreen;
  double fps = 30.0;
  int target_width = 0;
  int target_height = 0;

  const EncodableMap video = findMap(constraints, "video");
  if (video != EncodableMap()) {
    const EncodableMap deviceId = findMap(video, "deviceId");
    if (deviceId != EncodableMap()) {
      source_id = findString(deviceId, "exact");
      if (source_id.empty()) {
        result->Error("Bad Arguments", "Incorrect video->deviceId->exact");
        return;
      }
      if (source_id != "0") {
        // source_type = DesktopType::kWindow;
      }
    }
    const EncodableMap mandatory = findMap(video, "mandatory");
    if (mandatory != EncodableMap()) {
      double frameRate = findDouble(mandatory, "frameRate");
      if (frameRate != 0.0) {
        fps = frameRate;
      }
      int w = findInt(mandatory, "width");
      if (w > 0) target_width = w;
      int h = findInt(mandatory, "height");
      if (h > 0) target_height = h;
    }
  }
  (void)target_width;
  (void)target_height;

  std::string uuid = base_->GenerateUUID();

  scoped_refptr<RTCMediaStream> stream =
      base_->factory_->CreateStream(uuid.c_str());

  EncodableMap params;
  params[EncodableValue("streamId")] = EncodableValue(uuid);

  // AUDIO
  //
  // Adopted from upstream 1.5.2 (#2060). The loopback capturer is a custom
  // RTCAudioSource fed by WASAPI ApplicationLoopbackAudio (full desktop, or a
  // single app when source_id is a window HWND) — it does NOT touch the ADM.
  // This replaces the Hollow fork's old data-channel screen-audio path; the
  // audio now rides the normal WebRTC audio track, so every peer (incl. phones)
  // receives it. CreateLoopbackCapturer returns nullptr on non-Windows.

  bool capture_audio = false;
  {
    auto audio_it = constraints.find(EncodableValue("audio"));
    if (audio_it != constraints.end()) {
      if (TypeIs<bool>(audio_it->second)) {
        capture_audio = GetValue<bool>(audio_it->second);
      } else if (TypeIs<EncodableMap>(audio_it->second)) {
        capture_audio = true;
      }
    }
  }

  if (capture_audio) {
    // Stop any previous loopback session before starting a new one.
    if (loopback_capturer_) {
      loopback_capturer_->Stop();
      loopback_capturer_.reset();
    }

    // Disable all audio processing for loopback capture.  Echo cancellation,
    // AGC, and noise suppression are designed for microphone input; applied to
    // system audio they treat the captured content as echo/noise and destroy it.
    RTCAudioOptions loopback_opts;
    loopback_opts.echo_cancellation = false;
    loopback_opts.auto_gain_control = false;
    loopback_opts.noise_suppression = false;
    const std::string loopback_source_label =
      "screen_loopback_input_" + base_->GenerateUUID();
    loopback_audio_source_ = base_->factory_->CreateAudioSource(
      loopback_source_label.c_str(), RTCAudioSource::SourceType::kCustom,
        loopback_opts);

    std::string audio_uuid = base_->GenerateUUID();
    scoped_refptr<RTCAudioTrack> audio_track =
        base_->factory_->CreateAudioTrack(loopback_audio_source_,
                                          audio_uuid.c_str());

    loopback_capturer_ = CreateLoopbackCapturer(source_id);

    if (loopback_capturer_ && loopback_capturer_->Start(loopback_audio_source_)) {
      EncodableMap audio_info;
      audio_info[EncodableValue("id")] =
          EncodableValue(audio_track->id().std_string());
      audio_info[EncodableValue("label")] =
          EncodableValue(audio_track->id().std_string());
      audio_info[EncodableValue("kind")] =
          EncodableValue(audio_track->kind().std_string());
      audio_info[EncodableValue("enabled")] =
          EncodableValue(audio_track->enabled());

      EncodableList audioTracks;
      audioTracks.push_back(EncodableValue(audio_info));
      params[EncodableValue("audioTracks")] = EncodableValue(audioTracks);

      stream->AddTrack(audio_track);
      base_->local_tracks_[audio_track->id().std_string()] = audio_track;
    } else {
      // Loopback init failed or not supported — continue without audio.
      loopback_capturer_.reset();
      loopback_audio_source_ = nullptr;
      params[EncodableValue("audioTracks")] = EncodableValue(EncodableList());
    }
  } else {
    params[EncodableValue("audioTracks")] = EncodableValue(EncodableList());
  }

  // VIDEO

  EncodableMap video_constraints;
  auto it = constraints.find(EncodableValue("video"));
  if (it != constraints.end() && TypeIs<EncodableMap>(it->second)) {
    video_constraints = GetValue<EncodableMap>(it->second);
  }

  scoped_refptr<MediaSource> source;
  for (auto src : sources_) {
    if (src->id().std_string() == source_id) {
      source = src;
    }
  }

  if (!source.get()) {
    result->Error("Bad Arguments", "source not found!");
    return;
  }

  const char* video_source_label = "screen_capture_input";
  scoped_refptr<RTCVideoSource> video_source;
  bool using_native_capturer = false;

// HOLLOW: the native Graphics-Capture video path (NativeScreenCapturer) depends
// on RTCVideoFrame::CreateFromBGRA, a method only present in the fork's old
// CUSTOM-patched libwebrtc — stock webrtc-sdk m144.7559.09 (adopted in the 1.5.2
// rebase) does not have it. Per Vitalik's call (2026-06-25) we move to STOCK
// libwebrtc and use its own desktop capturer for screen share; the custom native
// capturer stays in-tree (gated off) for a possible future custom build. Define
// HOLLOW_USE_NATIVE_SCREEN_CAPTURER + link a libwebrtc with CreateFromBGRA to
// re-enable. The screen RECORDER (win_screen_recorder.cc) is independent and
// keeps its custom path. See project_flutter_webrtc_152_upgrade.
#if defined(_WIN32) && defined(HOLLOW_USE_NATIVE_SCREEN_CAPTURER)
  // Use native Graphics Capture when target resolution is specified.
  // This bypasses libwebrtc's desktop capturer which ignores resolution
  // constraints and always sends at native monitor resolution.
  if (target_width > 0 && target_height > 0) {
    video_source = base_->factory_->CreateCustomVideoSource(
        video_source_label,
        base_->ParseMediaConstraints(video_constraints));

    if (video_source.get()) {
      auto capturer = std::make_unique<NativeScreenCapturer>();
      bool started = false;

      if (source->type() == kScreen) {
        // Screen capture: find the matching HMONITOR.
        // Source IDs for screens are display indices; use primary monitor
        // for "0", otherwise enumerate to match.
        HMONITOR monitor = nullptr;
        if (source_id == "0") {
          POINT pt = {0, 0};
          monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
        } else {
          // Enumerate monitors to find the right one by index.
          struct EnumData {
            int target_index;
            int current_index;
            HMONITOR result;
          };
          int idx = 0;
          try { idx = std::stoi(source_id); } catch (...) {}
          EnumData data{idx, 0, nullptr};
          EnumDisplayMonitors(nullptr, nullptr,
              [](HMONITOR mon, HDC, LPRECT, LPARAM lp) -> BOOL {
                auto* d = reinterpret_cast<EnumData*>(lp);
                if (d->current_index == d->target_index) {
                  d->result = mon;
                  return FALSE;
                }
                d->current_index++;
                return TRUE;
              }, reinterpret_cast<LPARAM>(&data));
          monitor = data.result;
          if (!monitor) {
            POINT pt = {0, 0};
            monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
          }
        }
        started = capturer->StartMonitor(
            monitor, target_width, target_height,
            static_cast<UINT32>(fps), video_source);
      } else {
        // Window capture: source ID is the HWND as a string.
        HWND hwnd = nullptr;
        try {
          hwnd = reinterpret_cast<HWND>(
              static_cast<uintptr_t>(std::stoull(source_id)));
        } catch (...) {}
        if (hwnd && IsWindow(hwnd)) {
          started = capturer->StartWindow(
              hwnd, target_width, target_height,
              static_cast<UINT32>(fps), video_source);
        }
      }

      if (started) {
        native_capturers_[uuid] = std::move(capturer);
        using_native_capturer = true;
      } else {
        std::cerr << "[FlutterScreenCap] Native capturer failed, "
                     "falling back to libwebrtc\n";
        video_source = nullptr;
      }
    }
  }
#endif

  // Fallback: use libwebrtc's desktop capturer (Linux, or if native failed).
  if (!using_native_capturer) {
    scoped_refptr<RTCDesktopCapturer> desktop_capturer =
        base_->desktop_device_->CreateDesktopCapturer(source);

    if (!desktop_capturer.get()) {
      result->Error("Bad Arguments", "CreateDesktopCapturer failed!");
      return;
    }

    desktop_capturer->RegisterDesktopCapturerObserver(this);

    video_source = base_->factory_->CreateDesktopSource(
        desktop_capturer, video_source_label,
        base_->ParseMediaConstraints(video_constraints));

    desktop_capturer->Start(uint32_t(fps));
  }

  scoped_refptr<RTCVideoTrack> track =
      base_->factory_->CreateVideoTrack(video_source, uuid.c_str());

  EncodableList videoTracks;
  EncodableMap info;
  info[EncodableValue("id")] = EncodableValue(track->id().std_string());
  info[EncodableValue("label")] = EncodableValue(track->id().std_string());
  info[EncodableValue("kind")] = EncodableValue(track->kind().std_string());
  info[EncodableValue("enabled")] = EncodableValue(track->enabled());
  videoTracks.push_back(EncodableValue(info));
  params[EncodableValue("videoTracks")] = EncodableValue(videoTracks);

  stream->AddTrack(track);

  base_->local_tracks_[track->id().std_string()] = track;

  base_->local_streams_[uuid] = stream;

  result->Success(EncodableValue(params));
}

// ---------------------------------------------------------------------------
// Native capturer cleanup
// ---------------------------------------------------------------------------

void FlutterScreenCapture::CleanupNativeCapturersForStream(
    const std::string& stream_id) {
  (void)stream_id;
#if defined(_WIN32) && defined(HOLLOW_USE_NATIVE_SCREEN_CAPTURER)
  // Native Graphics-Capture video is gated off on stock libwebrtc (see the
  // include block + GetDisplayMedia). Map stays empty unless re-enabled.
  auto it = native_capturers_.find(stream_id);
  if (it != native_capturers_.end()) {
    it->second->Stop();
    native_capturers_.erase(it);
  }
#endif

#if defined(_WIN32)
  // Loopback audio is a single session (upstream 1.5.2 model), not keyed by
  // stream_id. Hollow shares one screen at a time, so tearing it down when the
  // share stream is disposed is correct.
  if (loopback_capturer_) {
    loopback_capturer_->Stop();
    loopback_capturer_.reset();
    loopback_audio_source_ = nullptr;
  }
#endif
}

// ---------------------------------------------------------------------------
// Screen Audio Capture (data-channel audio streaming)
// ---------------------------------------------------------------------------

void FlutterScreenCapture::StartScreenAudioCapture(
    const EncodableMap& params,
    std::unique_ptr<MethodResultProxy> result) {
#if defined(_WIN32)
  std::string stream_id = findString(params, "streamId");
  std::string mode = findString(params, "mode");

  if (stream_id.empty()) {
    result->Error("BAD_ARGS", "streamId is required");
    return;
  }

  // Stop any existing capturer for this stream.
  screen_audio_capturers_.erase(stream_id);

  auto capturer = std::make_unique<ScreenAudioCapturer>(
      base_->messenger_, base_->task_runner_, stream_id);

  bool started = false;
  if (mode == "process") {
    int pid = findInt(params, "pid");
    bool include_mode = pid != 0;
    started = capturer->StartProcessCapture(
        static_cast<DWORD>(pid), include_mode);
  } else {
    started = capturer->StartSystemCapture();
  }

  if (started) {
    screen_audio_capturers_[stream_id] = std::move(capturer);
    result->Success(EncodableValue(true));
  } else {
    result->Error("START_FAILED", "Failed to start screen audio capture");
  }
#else
  result->Error("UNSUPPORTED", "Screen audio capture is Windows-only");
#endif
}

void FlutterScreenCapture::StopScreenAudioCapture(
    const EncodableMap& params,
    std::unique_ptr<MethodResultProxy> result) {
#if defined(_WIN32)
  std::string stream_id = findString(params, "streamId");
  auto it = screen_audio_capturers_.find(stream_id);
  if (it != screen_audio_capturers_.end()) {
    it->second->Stop();
    screen_audio_capturers_.erase(it);
  }
  result->Success(EncodableValue(true));
#else
  result->Success(EncodableValue(true));
#endif
}

void FlutterScreenCapture::ScreenAudioRender(
    const EncodableMap& params,
    std::unique_ptr<MethodResultProxy> result) {
#if defined(_WIN32)
  std::string session_id = findString(params, "sessionId");
  if (session_id.empty()) {
    result->Error("BAD_ARGS", "sessionId is required");
    return;
  }

  auto data_it = params.find(EncodableValue("data"));
  if (data_it == params.end() || !TypeIs<std::vector<uint8_t>>(data_it->second)) {
    result->Error("BAD_ARGS", "data (Uint8List) is required");
    return;
  }
  const auto& packet = GetValue<std::vector<uint8_t>>(data_it->second);

  // Lazily create decoder + renderer on first packet.
  auto& session = audio_render_sessions_[session_id];
  if (!session) {
    session = std::make_unique<AudioRenderSession>();
    session->decoder = std::make_unique<OpusDecoderWrapper>(48000, 2);
    session->renderer = std::make_unique<WasapiAudioRenderer>();
    if (!session->decoder->valid() || !session->renderer->Start()) {
      audio_render_sessions_.erase(session_id);
      result->Error("INIT_FAILED", "Failed to init decoder/renderer");
      return;
    }
  }

  // Skip 4-byte sequence header, decode the Opus payload.
  if (packet.size() <= 4) {
    result->Success(EncodableValue(true));
    return;
  }

  // --- DEBUG: dump decoded PCM to WAV file for analysis ---
  static FILE* debug_wav = nullptr;
  static uint32_t debug_wav_bytes = 0;
  static int render_count = 0;
  render_count++;

  if (!debug_wav && render_count == 1) {
    char* appdata = nullptr;
    size_t len = 0;
    if (_dupenv_s(&appdata, &len, "APPDATA") == 0 && appdata) {
      std::string path = std::string(appdata) + "\\.hollow\\screen_audio_debug.wav";
      free(appdata);
      fopen_s(&debug_wav, path.c_str(), "wb");
      if (debug_wav) {
        // Write placeholder WAV header (patched on close).
        uint8_t hdr[44] = {};
        memcpy(hdr, "RIFF", 4);
        memcpy(hdr + 8, "WAVE", 4);
        memcpy(hdr + 12, "fmt ", 4);
        uint32_t v;
        v = 16; memcpy(hdr + 16, &v, 4);  // fmt size
        uint16_t s;
        s = 1; memcpy(hdr + 20, &s, 2);   // PCM
        s = 2; memcpy(hdr + 22, &s, 2);   // stereo
        v = 48000; memcpy(hdr + 24, &v, 4);
        v = 48000 * 4; memcpy(hdr + 28, &v, 4);
        s = 4; memcpy(hdr + 32, &s, 2);
        s = 16; memcpy(hdr + 34, &s, 2);
        memcpy(hdr + 36, "data", 4);
        fwrite(hdr, 1, 44, debug_wav);
      }
    }
  }

  // Extract sequence number for logging (first 4 bytes are seq, rest is opus).
  uint32_t seq = packet[0] | (packet[1] << 8) |
                 (packet[2] << 16) | (packet[3] << 24);

  std::vector<int16_t> pcm;
  int samples = session->decoder->Decode(
      packet.data() + 4, static_cast<int>(packet.size() - 4), pcm);

  if (samples > 0) {
    session->renderer->PushAudio(pcm.data(), samples,
                                  session->decoder->channels());

    // Write decoded PCM to debug WAV.
    if (debug_wav) {
      size_t bytes = samples * 2 * sizeof(int16_t);
      fwrite(pcm.data(), 1, bytes, debug_wav);
      debug_wav_bytes += static_cast<uint32_t>(bytes);
      fflush(debug_wav);
    }
  }

  // Log first packets + periodic to see sequence numbers.
  if (render_count <= 20 || render_count % 200 == 0) {
    fprintf(stderr, "[AU-RENDER] pkt#%d seq=%u opus=%zu bytes -> %d samples\n",
            render_count, seq, packet.size() - 4, samples);
  }

  // After 10 seconds (~1000 packets), finalize WAV for inspection.
  if (render_count == 1000 && debug_wav) {
    // Patch WAV header sizes.
    fseek(debug_wav, 4, SEEK_SET);
    uint32_t riff_size = debug_wav_bytes + 36;
    fwrite(&riff_size, 4, 1, debug_wav);
    fseek(debug_wav, 40, SEEK_SET);
    fwrite(&debug_wav_bytes, 4, 1, debug_wav);
    fclose(debug_wav);
    debug_wav = nullptr;
    fprintf(stderr, "[AU-RENDER] Debug WAV written: %u bytes of PCM\n",
            debug_wav_bytes);
  }

  result->Success(EncodableValue(true));
#else
  result->Error("UNSUPPORTED", "Screen audio render is Windows-only");
#endif
}

void FlutterScreenCapture::ScreenAudioRenderStop(
    const EncodableMap& params,
    std::unique_ptr<MethodResultProxy> result) {
#if defined(_WIN32)
  std::string session_id = findString(params, "sessionId");
  auto it = audio_render_sessions_.find(session_id);
  if (it != audio_render_sessions_.end()) {
    if (it->second && it->second->renderer)
      it->second->renderer->Stop();
    audio_render_sessions_.erase(it);
  }
  result->Success(EncodableValue(true));
#else
  result->Success(EncodableValue(true));
#endif
}

}  // namespace flutter_webrtc_plugin
