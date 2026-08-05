#include "flutter_webrtc.h"
#include "flutter_capture_gain_processor.h"
#include "flutter_data_channel.h"
#include "hollow_dfn_binding.h"

#include <mutex>
#include <thread>

#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"

#ifdef _WIN32
#include "../../../windows/win_screen_recorder.h"
#include "flutter_voice_redirect.h"
#endif

#ifdef __linux__
#include "../../../linux/hollow_pulse_devices.h"
#endif

namespace flutter_webrtc_plugin {

static EventChannelProxy* eventChannelProxy = nullptr;

FlutterWebRTC::FlutterWebRTC(FlutterWebRTCPlugin* plugin)
    : FlutterWebRTCBase::FlutterWebRTCBase(plugin->messenger(),
                                           plugin->textures(),
                                           plugin->task_runner()),
      FlutterVideoRendererManager::FlutterVideoRendererManager(this),
      FlutterMediaStream::FlutterMediaStream(this),
      FlutterPeerConnection::FlutterPeerConnection(this),
      FlutterScreenCapture::FlutterScreenCapture(this),
      FlutterDataChannel::FlutterDataChannel(this),
      FlutterFrameCryptor::FlutterFrameCryptor(this),
      FlutterDataPacketCryptor::FlutterDataPacketCryptor(this) {}

FlutterWebRTC::~FlutterWebRTC() {}

void FlutterWebRTC::HandleMethodCall(
    const MethodCallProxy& method_call,
    std::unique_ptr<MethodResultProxy> result) {
  if (method_call.method_name().compare("initialize") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const EncodableMap options = findMap(params, "options");
    std::string severityStr = findString(options, "logSeverity");
    if (severityStr.empty() == false) {
      RTCLoggingSeverity severity = str2LogSeverity(severityStr);
      initLoggerCallback(severity);
    }
    result->Success();
  } else if (method_call.method_name().compare("createPeerConnection") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const EncodableMap configuration = findMap(params, "configuration");
    const EncodableMap constraints = findMap(params, "constraints");
    CreateRTCPeerConnection(configuration, constraints, std::move(result));
  } else if (method_call.method_name().compare("getUserMedia") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const EncodableMap constraints = findMap(params, "constraints");
    GetUserMedia(constraints, std::move(result));
  } else if (method_call.method_name().compare("getDisplayMedia") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const EncodableMap constraints = findMap(params, "constraints");

    GetDisplayMedia(constraints, std::move(result));
  } else if (method_call.method_name().compare("getDesktopSources") == 0) {
    // types: ["screen", "window"]
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Bad arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const EncodableList types = findList(params, "types");
    if (types.empty()) {
      result->Error("Bad Arguments", "Types is required");
      return;
    }
    GetDesktopSources(types, std::move(result));
  } else if (method_call.method_name().compare("updateDesktopSources") == 0) {
    // types: ["screen", "window"]
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Bad arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const EncodableList types = findList(params, "types");
    if (types.empty()) {
      result->Error("Bad Arguments", "Types is required");
      return;
    }
    UpdateDesktopSources(types, std::move(result));
  } else if (method_call.method_name().compare("getDesktopSourceThumbnail") ==
             0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Bad arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    std::string sourceId = findString(params, "sourceId");
    if (sourceId.empty()) {
      result->Error("Bad Arguments", "Incorrect sourceId");
      return;
    }
    const EncodableMap thumbnailSize = findMap(params, "thumbnailSize");
    if (!thumbnailSize.empty()) {
      int width = 0;
      int height = 0;
      GetDesktopSourceThumbnail(sourceId, width, height, std::move(result));
    } else {
      result->Error("Bad Arguments", "Bad arguments received");
    }
  } else if (method_call.method_name().compare("getSources") == 0) {
    GetSources(std::move(result));
  } else if (method_call.method_name().compare("hollowLinuxAudioDevices") == 0) {
    // Linux mic/speaker enumeration via libpulse. The prebuilt libwebrtc ADM
    // reports 0 audio devices on pipewire-pulse systems (falls back to
    // AudioDeviceDummy), so the Dart side calls this instead on Linux — same
    // {"input":[{id,name,isDefault}],"output":[...]} shape as macOS's
    // hollowMacAudioDevices. See linux/hollow_pulse_devices.cc.
#ifdef __linux__
    std::vector<hollow_pulse::AudioDevice> inputs, outputs;
    if (hollow_pulse::EnumerateDevices(&inputs, &outputs)) {
      EncodableList in_list, out_list;
      for (const auto& d : inputs) {
        EncodableMap m;
        m[EncodableValue("id")] = EncodableValue(d.id);
        m[EncodableValue("name")] = EncodableValue(d.name);
        m[EncodableValue("isDefault")] = EncodableValue(d.is_default);
        in_list.push_back(EncodableValue(m));
      }
      for (const auto& d : outputs) {
        EncodableMap m;
        m[EncodableValue("id")] = EncodableValue(d.id);
        m[EncodableValue("name")] = EncodableValue(d.name);
        m[EncodableValue("isDefault")] = EncodableValue(d.is_default);
        out_list.push_back(EncodableValue(m));
      }
      EncodableMap res;
      res[EncodableValue("input")] = EncodableValue(in_list);
      res[EncodableValue("output")] = EncodableValue(out_list);
      result->Success(EncodableValue(res));
    } else {
      result->Error("PULSE_UNAVAILABLE",
                    "Could not connect to the PulseAudio server");
    }
#else
    result->Error("ERROR", "Linux only");
#endif
  } else if (method_call.method_name().compare("selectAudioInput") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string deviceId = findString(params, "deviceId");
    SelectAudioInput(deviceId, std::move(result));
  } else if (method_call.method_name().compare("selectAudioOutput") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string deviceId = findString(params, "deviceId");
    SelectAudioOutput(deviceId, std::move(result));
  } else if (method_call.method_name().compare("mediaStreamGetTracks") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string streamId = findString(params, "streamId");
    MediaStreamGetTracks(streamId, std::move(result));
  } else if (method_call.method_name().compare("createOffer") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap constraints = findMap(params, "constraints");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("createOfferFailed",
                    "createOffer() peerConnection is null");
      return;
    }
    CreateOffer(constraints, pc, std::move(result));
  } else if (method_call.method_name().compare("createAnswer") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap constraints = findMap(params, "constraints");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("createAnswerFailed",
                    "createAnswer() peerConnection is null");
      return;
    }
    CreateAnswer(constraints, pc, std::move(result));
  } else if (method_call.method_name().compare("addStream") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string streamId = findString(params, "streamId");
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    scoped_refptr<RTCMediaStream> stream = MediaStreamForId(streamId);
    if (!stream) {
      result->Error("addStreamFailed", "addStream() stream not found!");
      return;
    }
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("addStreamFailed", "addStream() peerConnection is null");
      return;
    }
    pc->AddStream(stream);
    result->Success();
  } else if (method_call.method_name().compare("removeStream") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string streamId = findString(params, "streamId");
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    scoped_refptr<RTCMediaStream> stream = MediaStreamForId(streamId);
    if (!stream) {
      result->Error("removeStreamFailed", "removeStream() stream not found!");
      return;
    }
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("removeStreamFailed",
                    "removeStream() peerConnection is null");
      return;
    }
    pc->RemoveStream(stream);
    result->Success();
  } else if (method_call.method_name().compare("setLocalDescription") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap constraints = findMap(params, "description");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("setLocalDescriptionFailed",
                    "setLocalDescription() peerConnection is null");
      return;
    }

    SdpParseError error;
    scoped_refptr<RTCSessionDescription> description =
        RTCSessionDescription::Create(findString(constraints, "type").c_str(),
                                      findString(constraints, "sdp").c_str(),
                                      &error);

    if (description.get() != nullptr) {
      SetLocalDescription(description.get(), pc, std::move(result));
    } else {
      result->Error("setLocalDescriptionFailed", "Invalid type or sdp");
    }
  } else if (method_call.method_name().compare("setRemoteDescription") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap constraints = findMap(params, "description");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("setRemoteDescriptionFailed",
                    "setRemoteDescription() peerConnection is null");
      return;
    }

    SdpParseError error;
    scoped_refptr<RTCSessionDescription> description =
        RTCSessionDescription::Create(findString(constraints, "type").c_str(),
                                      findString(constraints, "sdp").c_str(),
                                      &error);

    if (description.get() != nullptr) {
      SetRemoteDescription(description.get(), pc, std::move(result));
    } else {
      result->Error("setRemoteDescriptionFailed", "Invalid type or sdp");
    }
  } else if (method_call.method_name().compare("addCandidate") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap constraints = findMap(params, "candidate");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("addCandidateFailed",
                    "addCandidate() peerConnection is null");
      return;
    }

    SdpParseError error;
    std::string candidate = findString(constraints, "candidate");
    if (candidate.empty()) {
      // received the end-of-candidates
      result->Success();
      return;
    }
    int sdpMLineIndex = findInt(constraints, "sdpMLineIndex");
    scoped_refptr<RTCIceCandidate> rtc_candidate = RTCIceCandidate::Create(
        candidate.c_str(), findString(constraints, "sdpMid").c_str(),
        sdpMLineIndex == -1 ? 0 : sdpMLineIndex, &error);

    if (rtc_candidate.get() != nullptr) {
      AddIceCandidate(rtc_candidate.get(), pc, std::move(result));
    } else {
      result->Error("addCandidateFailed", "Invalid candidate");
    }
  } else if (method_call.method_name().compare("getStats") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const std::string track_id = findString(params, "trackId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getStatsFailed", "getStats() peerConnection is null");
      return;
    }
    GetStats(track_id, pc, std::move(result));
  } else if (method_call.method_name().compare("createDataChannel") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("createDataChannelFailed",
                    "createDataChannel() peerConnection is null");
      return;
    }

    const std::string label = findString(params, "label");
    const EncodableMap dataChannelDict = findMap(params, "dataChannelDict");

    CreateDataChannel(peerConnectionId, label, dataChannelDict, pc,
                      std::move(result));
  } else if (method_call.method_name().compare("dataChannelSend") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("dataChannelSendFailed",
                    "dataChannelSend() peerConnection is null");
      return;
    }

    const std::string dataChannelId = findString(params, "dataChannelId");
    const std::string type = findString(params, "type");
    const EncodableValue data = findEncodableValue(params, "data");
    RTCDataChannel* data_channel = DataChannelForId(dataChannelId);
    if (data_channel == nullptr) {
      result->Error("dataChannelSendFailed",
                    "dataChannelSend() data_channel is null");
      return;
    }
    DataChannelSend(data_channel, type, data, std::move(result));
  } else if (method_call.method_name().compare(
                 "dataChannelGetBufferedAmount") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("dataChannelGetBufferedAmountFailed",
                    "dataChannelGetBufferedAmount() peerConnection is null");
      return;
    }

    const std::string dataChannelId = findString(params, "dataChannelId");
    RTCDataChannel* data_channel = DataChannelForId(dataChannelId);
    if (data_channel == nullptr) {
      result->Error("dataChannelGetBufferedAmountFailed",
                    "dataChannelGetBufferedAmount() data_channel is null");
      return;
    }
    DataChannelGetBufferedAmount(data_channel, std::move(result));
  } else if (method_call.method_name().compare("dataChannelClose") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("dataChannelCloseFailed",
                    "dataChannelClose() peerConnection is null");
      return;
    }

    const std::string dataChannelId = findString(params, "dataChannelId");
    RTCDataChannel* data_channel = DataChannelForId(dataChannelId);
    if (data_channel == nullptr) {
      result->Error("dataChannelCloseFailed",
                    "dataChannelClose() data_channel is null");
      return;
    }
    DataChannelClose(data_channel, dataChannelId, std::move(result));
  } else if (method_call.method_name().compare("streamDispose") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string stream_id = findString(params, "streamId");
    CleanupNativeCapturersForStream(stream_id);
    MediaStreamDispose(stream_id, std::move(result));
  } else if (method_call.method_name().compare("mediaStreamTrackSetEnable") ==
             0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string track_id = findString(params, "trackId");
    const EncodableValue enable = findEncodableValue(params, "enabled");
    scoped_refptr<RTCMediaTrack> track = MediaTrackForId(track_id);
    if (track != nullptr) {
      const bool value = GetValue<bool>(enable);
      if (track->kind().std_string() == "audio") {
        // Off the platform thread — see HollowAudioOpQueue. Video stays
        // synchronous (camera flows untouched).
        audio_op_queue().Post("setEnabled",
                              [track, value]() { track->set_enabled(value); });
      } else {
        track->set_enabled(value);
      }
    }
    result->Success();
  } else if (method_call.method_name().compare("videoTrackSetContentHint") ==
             0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string track_id = findString(params, "trackId");
    const std::string hint = findString(params, "hint");
    scoped_refptr<RTCMediaTrack> track = MediaTrackForId(track_id);
    if (track != nullptr && track->kind().std_string() == "video") {
      auto content_hint = RTCVideoTrack::ContentHint::kNone;
      if (hint == "motion") {
        content_hint = RTCVideoTrack::ContentHint::kFluid;
      } else if (hint == "detail") {
        content_hint = RTCVideoTrack::ContentHint::kDetailed;
      } else if (hint == "text") {
        content_hint = RTCVideoTrack::ContentHint::kText;
      }
      static_cast<RTCVideoTrack*>(track.get())->SetContentHint(content_hint);
    }
    result->Success();
  } else if (method_call.method_name().compare("trackDispose") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string track_id = findString(params, "trackId");
    MediaStreamTrackDispose(track_id, std::move(result));
  } else if (method_call.method_name().compare("restartIce") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("restartIceFailed", "restartIce() peerConnection is null");
      return;
    }
    pc->RestartIce();
    result->Success();
  } else if (method_call.method_name().compare("peerConnectionClose") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("peerConnectionCloseFailed",
                    "peerConnectionClose() peerConnection is null");
      return;
    }
    RTCPeerConnectionClose(pc, peerConnectionId, std::move(result));
  } else if (method_call.method_name().compare("peerConnectionDispose") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Success();
      return;
    }
    RTCPeerConnectionDispose(pc, peerConnectionId, std::move(result));
  } else if (method_call.method_name().compare("createVideoRenderer") == 0) {
    CreateVideoRendererTexture(std::move(result));
  } else if (method_call.method_name().compare("videoRendererDispose") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    int64_t texture_id = findLongInt(params, "textureId");
    VideoRendererDispose(texture_id, std::move(result));
  } else if (method_call.method_name().compare("videoRendererSetSrcObject") ==
             0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string stream_id = findString(params, "streamId");
    int64_t texture_id = findLongInt(params, "textureId");
    const std::string owner_tag = findString(params, "ownerTag");
    const std::string track_id = findString(params, "trackId");

    VideoRendererSetSrcObject(texture_id, stream_id, owner_tag, track_id);
    result->Success();
  } else if (method_call.method_name().compare(
                 "mediaStreamTrackSwitchCamera") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string track_id = findString(params, "trackId");
    MediaStreamTrackSwitchCamera(track_id, std::move(result));
  } else if (method_call.method_name().compare("setVolume") == 0) {
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments", "setVolume() Null arguments received");
      return;
    }

    const EncodableMap params = GetValue<EncodableMap>(*args);
    const std::string trackId = findString(params, "trackId");
    const std::optional<double> volume = maybeFindDouble(params, "volume");

    if (trackId.empty()) {
      result->Error("Bad Arguments", "setVolume() Empty track provided");
      return;
    }

    if (!volume.has_value()) {
      result->Error("Bad Arguments", "setVolume() No volume provided");
      return;
    }

    if (volume.value() < 0) {
      result->Error("Bad Arguments", "setVolume() Volume must be positive");
      return;
    }

    scoped_refptr<RTCMediaTrack> track = MediaTrackForId(trackId);
    if (nullptr == track.get()) {
      result->Error("setVolume", "setVolume() Unable to find provided track");
      return;
    }

    std::string kind = track->kind().std_string();
    if (0 != kind.compare("audio")) {
      result->Error("setVolume",
                    "setVolume() Only audio tracks can have volume set");
      return;
    }

    // Off the platform thread — SetVolume is a signaling-thread hop that
    // queues behind mic teardown during mute churn (see HollowAudioOpQueue).
    auto audioTrack =
        scoped_refptr<RTCAudioTrack>(static_cast<RTCAudioTrack*>(track.get()));
    const double vol = volume.value();
    audio_op_queue().Post("setVolume",
                          [audioTrack, vol]() { audioTrack->SetVolume(vol); });

    result->Success();
  } else if (method_call.method_name().compare("setCaptureGain") == 0) {
    // Hollow fork: live makeup gain for the post-APM capture processor.
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments", "setCaptureGain() Null arguments received");
      return;
    }
    const EncodableMap params = GetValue<EncodableMap>(*args);
    const std::optional<double> gain = maybeFindDouble(params, "gain");
    if (!gain.has_value()) {
      result->Error("Bad Arguments", "setCaptureGain() No gain provided");
      return;
    }
    if (capture_gain_processor()) {
      capture_gain_processor()->SetGain(static_cast<float>(gain.value()));
    }
    result->Success();
  } else if (method_call.method_name().compare("setVoiceEnhance") == 0) {
    // Hollow fork: toggles the EQ+compressor+limiter voice chain in the
    // post-APM capture processor (OFF = legacy flat gain + limiter).
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments",
                    "setVoiceEnhance() Null arguments received");
      return;
    }
    const EncodableMap params = GetValue<EncodableMap>(*args);
    const bool enabled = findBoolean(params, "enabled");
    const bool dynamic = findBoolean(params, "dynamic");
    const std::optional<double> makeup_db = maybeFindDouble(params, "makeupDb");
    if (capture_gain_processor()) {
      capture_gain_processor()->SetEnhance(enabled);
      capture_gain_processor()->SetEnhanceDynamic(dynamic);
      if (makeup_db.has_value()) {
        capture_gain_processor()->SetEnhanceMakeup(
            static_cast<float>(makeup_db.value()));
      }
    }
    result->Success();
  } else if (method_call.method_name().compare("startCaptureRecord") == 0) {
    // Hollow fork (issue #40): record the PROCESSED capture signal (post
    // AI-NS + enhance chain — exactly what a remote peer receives pre-Opus)
    // to a WAV file for the settings mic test.
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments",
                    "startCaptureRecord() Null arguments received");
      return;
    }
    const EncodableMap params = GetValue<EncodableMap>(*args);
    std::string rec_path = findString(params, "path");
    if (rec_path.empty()) {
      result->Error("Bad Arguments", "startCaptureRecord() No path provided");
      return;
    }
    bool started = false;
    if (capture_gain_processor()) {
      started = capture_gain_processor()->StartCaptureRecord(rec_path);
    }
    result->Success(EncodableValue(started));
  } else if (method_call.method_name().compare("stopCaptureRecord") == 0) {
    if (capture_gain_processor()) {
      capture_gain_processor()->StopCaptureRecord();
    }
    result->Success();
  } else if (method_call.method_name().compare("hollowRenderVoiceWav") == 0) {
    // Hollow fork (issue #40 mic test, final design): offline-render a RAW
    // mic WAV through a FRESH instance of the capture chain (same code as
    // live calls) so the user can A/B raw vs processed with no live WebRTC
    // session involved.
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments",
                    "hollowRenderVoiceWav() Null arguments received");
      return;
    }
    const EncodableMap params = GetValue<EncodableMap>(*args);
    std::string in_path = findString(params, "inPath");
    std::string out_path = findString(params, "outPath");
    if (in_path.empty() || out_path.empty()) {
      result->Error("Bad Arguments", "hollowRenderVoiceWav() paths missing");
      return;
    }
    const double rv_gain = maybeFindDouble(params, "gain").value_or(1.0);
    const bool rv_enhance = findBoolean(params, "enhance");
    const double rv_makeup = maybeFindDouble(params, "makeupDb").value_or(12.0);
    const bool rv_dynamic = findBoolean(params, "dynamic");
    const bool rv_ai_ns = findBoolean(params, "aiNs");
    int rv_engine = findInt(params, "engine");
    if (rv_engine < 0) rv_engine = hollow_dfn::kEngineRnnoise;
    auto shared = std::shared_ptr<MethodResultProxy>(result.release());
    std::thread([in_path, out_path, rv_gain, rv_enhance, rv_makeup,
                 rv_dynamic, rv_ai_ns, rv_engine, shared]() {
      // ONE cached offline engine per process — the DFN ABI has no destroy,
      // so per-render creation would leak a model each run. Renders are
      // UI-serialized; the mutex is hygiene for that assumption.
      static std::mutex offline_mtx;
      static void* offline_dfn = nullptr;
      static int offline_engine = -1;
      std::lock_guard<std::mutex> lock(offline_mtx);
      void* handle = nullptr;
      if (rv_ai_ns && hollow_dfn::Bind()) {
        if (offline_dfn == nullptr || offline_engine != rv_engine) {
          offline_dfn = hollow_dfn::CreateEngine(rv_engine);
          offline_engine = rv_engine;
        }
        handle = offline_dfn;
      }
      std::string err;
      const bool ok = RenderVoiceWavOffline(
          in_path, out_path, static_cast<float>(rv_gain), rv_enhance,
          static_cast<float>(rv_makeup), rv_dynamic, handle, rv_engine, &err);
      if (ok) {
        shared->Success(EncodableValue(true));
      } else {
        shared->Error("RENDER_FAILED", err);
      }
    }).detach();
  } else if (method_call.method_name().compare("setCaptureMuted") == 0) {
    // Hollow fork: mic mute state for the capture processor — freezes the
    // dynamic servo so it can't adapt to non-call audio while muted.
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments",
                    "setCaptureMuted() Null arguments received");
      return;
    }
    const EncodableMap params = GetValue<EncodableMap>(*args);
    const bool muted = findBoolean(params, "muted");
    if (capture_gain_processor()) {
      capture_gain_processor()->SetMuted(muted);
    }
    result->Success();
  } else if (method_call.method_name().compare("setCaptureServoHold") == 0) {
    // Hollow fork: share audio active (sending or playing) — freeze the
    // dynamic servo so continuous music bleed can't re-calibrate the trim.
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments",
                    "setCaptureServoHold() Null arguments received");
      return;
    }
    const EncodableMap params = GetValue<EncodableMap>(*args);
    const bool hold = findBoolean(params, "hold");
    if (capture_gain_processor()) {
      capture_gain_processor()->SetServoHold(hold);
    }
    result->Success();
  } else if (method_call.method_name().compare("setNoiseSuppressAi") == 0) {
    // Hollow fork: AI noise suppression (RNNoise default / DFN3 via the
    // `engine` param) at the HEAD of the capture chain (post-AEC), via
    // hollow_core's C ABI. The first enable spawns a one-shot background
    // create (RNNoise is instant; DFN3's tract model load takes 100-500 ms);
    // frames pass through untouched until the handle is published. A later
    // call with a DIFFERENT engine performs a LIVE SWAP: the new handle is
    // created in the background and published over the old one (which
    // deliberately leaks — the audio thread may still be inside it).
    // Enable/disable itself is a live atomic flip.
    auto args = method_call.arguments();
    if (!args) {
      result->Error("Bad Arguments",
                    "setNoiseSuppressAi() Null arguments received");
      return;
    }
    const EncodableMap params = GetValue<EncodableMap>(*args);
    const bool enabled = findBoolean(params, "enabled");
    int engine = findInt(params, "engine");
    if (engine < 0) engine = hollow_dfn::kEngineRnnoise;
    const std::optional<double> atten = maybeFindDouble(params, "attenLimDb");
    const std::optional<double> beta =
        maybeFindDouble(params, "postFilterBeta");
    auto* proc = capture_gain_processor();
    if (proc) {
      proc->SetNoiseSuppressAi(enabled);
      if (enabled && hollow_dfn::Bind()) {
        void* h = proc->GetDfnHandle();
        if (h != nullptr && proc->DfnEngine() == engine) {
          // Right engine already loaded: apply parameter updates live.
          if (atten.has_value())
            hollow_dfn::SetAttenLim(h, static_cast<float>(atten.value()));
          if (beta.has_value())
            hollow_dfn::SetPostFilterBeta(h, static_cast<float>(beta.value()));
        } else if (proc->TryBeginDfnCreate(engine)) {
          const float atten_v =
              static_cast<float>(atten.value_or(100.0));
          const float beta_v = static_cast<float>(beta.value_or(0.0));
          // proc is the process-global capture processor (never destroyed
          // while the plugin lives) — safe to capture across the load.
          std::thread([proc, engine, atten_v, beta_v]() {
            void* h2 = hollow_dfn::CreateEngine(engine);
            if (h2 != nullptr) {
              hollow_dfn::SetAttenLim(h2, atten_v);
              hollow_dfn::SetPostFilterBeta(h2, beta_v);
              proc->PublishDfnHandle(h2, engine);
            } else {
              proc->EndDfnCreate();
            }
          }).detach();
        }
      }
    }
    result->Success();
  } else if (method_call.method_name().compare("getCaptureLevel") == 0) {
    // Hollow fork: live mic loudness for the speaking indicator (issue #37).
    // Deliberately its OWN call and not part of the status map above — this
    // one is polled several times a second during a call, so it stays a
    // couple of atomic loads with nothing else attached.
    //
    // levelDb: decaying peak-hold of the capture RMS, dBFS (-100 = silence).
    // vad: DFN/RNNoise voice probability 0..1, or -1 when the denoiser is
    // not running. Dart prefers the VAD when it is there and falls back to
    // thresholding levelDb otherwise.
    EncodableMap res;
    auto* proc = capture_gain_processor();
    res[EncodableValue("levelDb")] = EncodableValue(
        proc ? static_cast<double>(proc->CaptureLevelDb()) : -100.0);
    res[EncodableValue("vad")] = EncodableValue(
        proc ? static_cast<double>(proc->DfnVad()) : -1.0);
    result->Success(EncodableValue(res));
  } else if (method_call.method_name().compare("getNoiseSuppressAiActive") ==
             0) {
    // Hollow fork: DFN status snapshot so Dart can fall back to WebRTC NS
    // when DFN can't run here (unbound symbols, unsupported capture shape,
    // realtime bail) instead of leaving a call with NO noise suppression.
    EncodableMap res;
    auto* proc = capture_gain_processor();
    const bool available = hollow_dfn::IsBound();
    const bool enabled = proc && proc->NoiseSuppressAiEnabled();
    const bool ready = proc && proc->DfnReady();
    const bool bailed = proc && proc->DfnBailed();
    const bool format_ok = proc && proc->DfnFormatOk();
    res[EncodableValue("available")] = EncodableValue(available);
    res[EncodableValue("enabled")] = EncodableValue(enabled);
    res[EncodableValue("ready")] = EncodableValue(ready);
    res[EncodableValue("bailed")] = EncodableValue(bailed);
    res[EncodableValue("formatOk")] = EncodableValue(format_ok);
    res[EncodableValue("active")] = EncodableValue(
        enabled && ready && !bailed && format_ok);
    // frames > 0 is the PROOF the engine is actually denoising the mic —
    // Dart logs this map so a field test is never ambiguous again.
    res[EncodableValue("frames")] =
        EncodableValue(proc ? proc->DfnFramesProcessed() : 0);
    res[EncodableValue("emaMs")] = EncodableValue(
        proc ? static_cast<double>(proc->DfnMsEma()) : 0.0);
    // Engine id of the published handle (-1 = none): 0 RNNoise, 1 DFN3.
    res[EncodableValue("engine")] =
        EncodableValue(proc ? proc->DfnEngine() : -1);
    // Voice probability of the last denoised frame (-1 = none) — proves
    // the RNNoise VAD is feeding the chain's speech gate.
    res[EncodableValue("vad")] = EncodableValue(
        proc ? static_cast<double>(proc->DfnVad()) : -1.0);
    // Raw capture shape — says WHY a format was rejected.
    res[EncodableValue("rate")] = EncodableValue(proc ? proc->SampleRate() : 0);
    res[EncodableValue("channels")] =
        EncodableValue(proc ? proc->Channels() : 0);
    res[EncodableValue("bands")] = EncodableValue(proc ? proc->LastBands() : 0);
    res[EncodableValue("bufferSize")] =
        EncodableValue(proc ? proc->LastBufferSize() : 0);
    // Performance sentinels: smoothed WHOLE-chain cost per 10 ms frame, and
    // capture-gap count/worst (>30 ms between Process() calls) this session.
    res[EncodableValue("chainEmaMs")] = EncodableValue(
        proc ? static_cast<double>(proc->ChainMsEma()) : 0.0);
    res[EncodableValue("captureGaps")] =
        EncodableValue(proc ? proc->CaptureGaps() : 0);
    res[EncodableValue("worstGapMs")] =
        EncodableValue(proc ? proc->WorstGapMs() : 0);
    result->Success(EncodableValue(res));
  } else if (method_call.method_name().compare("voiceRedirectStart") == 0) {
    // Hollow fork (Windows): begin out-of-process rendering of the given REMOTE
    // audio track ids so the call voices play from a separate pid (excluded from
    // entire-screen capture for anti-echo) while hollow.exe's media is captured.
    // Returns {"pid": <renderer pid>} so Dart can pass it to the screen-audio
    // capturer's --exclude-pid. {"pid": 0} means it didn't start.
#ifdef _WIN32
    const EncodableMap params =
        method_call.arguments()
            ? GetValue<EncodableMap>(*method_call.arguments())
            : EncodableMap();
    const EncodableList track_list = findList(params, "trackIds");
    std::vector<std::string> track_ids;
    for (const EncodableValue& v : track_list) {
      track_ids.push_back(GetValue<std::string>(v));
    }
    bool ok = voice_redirect()->Start(this, track_ids);
    int pid = ok ? static_cast<int>(voice_redirect()->child_pid()) : 0;
    EncodableMap res;
    res[EncodableValue("pid")] = EncodableValue(pid);
    result->Success(EncodableValue(res));
#else
    EncodableMap res;
    res[EncodableValue("pid")] = EncodableValue(0);
    result->Success(EncodableValue(res));
#endif
  } else if (method_call.method_name().compare("voiceRedirectStop") == 0) {
    // Hollow fork (Windows): stop the redirect — RemoveSink + restore volume on
    // every redirected track, shut the renderer child down.
#ifdef _WIN32
    voice_redirect()->Stop(this);
#endif
    result->Success();
  } else if (method_call.method_name().compare("getLocalDescription") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap constraints = findMap(params, "description");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("GetLocalDescription",
                    "GetLocalDescription() peerConnection is null");
      return;
    }

    GetLocalDescription(pc, std::move(result));
  } else if (method_call.method_name().compare("getRemoteDescription") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap constraints = findMap(params, "description");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("GetRemoteDescription",
                    "GetRemoteDescription() peerConnection is null");
      return;
    }

    GetRemoteDescription(pc, std::move(result));
  } else if (method_call.method_name().compare("mediaStreamAddTrack") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string streamId = findString(params, "streamId");
    const std::string trackId = findString(params, "trackId");

    scoped_refptr<RTCMediaStream> stream = MediaStreamForId(streamId);
    if (stream == nullptr) {
      result->Error("MediaStreamAddTrack",
                    "MediaStreamAddTrack() stream is null");
      return;
    }

    scoped_refptr<RTCMediaTrack> track = MediaTracksForId(trackId);
    if (track == nullptr) {
      result->Error("MediaStreamAddTrack",
                    "MediaStreamAddTrack() track is null");
      return;
    }

    MediaStreamAddTrack(stream, track, std::move(result));
    std::string kind = track->kind().std_string();
    for (int i = 0; i < renders_.size(); i++) {
      FlutterVideoRenderer* renderer = renders_.at(i).get();
      if (renderer->CheckMediaStream(streamId) && 0 == kind.compare("video")) {
        renderer->SetVideoTrack(static_cast<RTCVideoTrack*>(track.get()));
      }
    }
  } else if (method_call.method_name().compare("mediaStreamRemoveTrack") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string streamId = findString(params, "streamId");
    const std::string trackId = findString(params, "trackId");

    scoped_refptr<RTCMediaStream> stream = MediaStreamForId(streamId);
    if (stream == nullptr) {
      result->Error("MediaStreamRemoveTrack",
                    "MediaStreamRemoveTrack() stream is null");
      return;
    }

    scoped_refptr<RTCMediaTrack> track = MediaTracksForId(trackId);
    if (track == nullptr) {
      result->Error("MediaStreamRemoveTrack",
                    "MediaStreamRemoveTrack() track is null");
      return;
    }

    MediaStreamRemoveTrack(stream, track, std::move(result));

    for (int i = 0; i < renders_.size(); i++) {
      FlutterVideoRenderer* renderer = renders_.at(i).get();
      if (renderer->CheckVideoTrack(streamId)) {
        renderer->SetVideoTrack(nullptr);
      }
    }
  } else if (method_call.method_name().compare("addTrack") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const std::string trackId = findString(params, "trackId");
    const EncodableList streamIds = findList(params, "streamIds");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("AddTrack", "AddTrack() peerConnection is null");
      return;
    }

    scoped_refptr<RTCMediaTrack> track = MediaTracksForId(trackId);
    if (track == nullptr) {
      result->Error("AddTrack", "AddTrack() track is null");
      return;
    }
    std::vector<std::string> ids;
    for (EncodableValue value : streamIds) {
      ids.push_back(GetValue<std::string>(value));
    }

    AddTrack(pc, track, ids, std::move(result));

  } else if (method_call.method_name().compare("removeTrack") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const std::string senderId = findString(params, "senderId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("removeTrack", "removeTrack() peerConnection is null");
      return;
    }

    RemoveTrack(pc, senderId, std::move(result));

  } else if (method_call.method_name().compare("addTransceiver") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const EncodableMap transceiverInit = findMap(params, "transceiverInit");
    const std::string mediaType = findString(params, "mediaType");
    const std::string trackId = findString(params, "trackId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("addTransceiver",
                    "addTransceiver() peerConnection is null");
      return;
    }
    AddTransceiver(pc, trackId, mediaType, transceiverInit, std::move(result));
  } else if (method_call.method_name().compare("getTransceivers") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getTransceivers",
                    "getTransceivers() peerConnection is null");
      return;
    }

    GetTransceivers(pc, std::move(result));
  } else if (method_call.method_name().compare("getReceivers") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getReceivers", "getReceivers() peerConnection is null");
      return;
    }

    GetReceivers(pc, std::move(result));

  } else if (method_call.method_name().compare("getSenders") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getSenders", "getSenders() peerConnection is null");
      return;
    }

    GetSenders(pc, std::move(result));
  } else if (method_call.method_name().compare("rtpSenderSetTrack") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("rtpSenderSetTrack",
                    "rtpSenderSetTrack() peerConnection is null");
      return;
    }

    const std::string trackId = findString(params, "trackId");
    RTCMediaTrack* track = MediaTrackForId(trackId);

    const std::string rtpSenderId = findString(params, "rtpSenderId");
    if (rtpSenderId.empty()) {
      result->Error("rtpSenderSetTrack",
                    "rtpSenderSetTrack() rtpSenderId is null or empty");
      return;
    }
    RtpSenderSetTrack(pc, track, rtpSenderId, std::move(result));
  } else if (method_call.method_name().compare("rtpSenderSetStreams") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("rtpSenderSetStream",
                    "rtpSenderSetStream() peerConnection is null");
      return;
    }

    const EncodableList encodableStreamIds = findList(params, "streamIds");
    if (encodableStreamIds.empty()) {
      result->Error("rtpSenderSetStream",
                    "rtpSenderSetStream() streamId is null or empty");
      return;
    }
    std::vector<std::string> streamIds{};
    for (EncodableValue value : encodableStreamIds) {
      streamIds.push_back(GetValue<std::string>(value));
    }

    const std::string rtpSenderId = findString(params, "rtpSenderId");
    if (rtpSenderId.empty()) {
      result->Error("rtpSenderSetStream",
                    "rtpSenderSetStream() rtpSenderId is null or empty");
      return;
    }
    RtpSenderSetStream(pc, streamIds, rtpSenderId, std::move(result));
  } else if (method_call.method_name().compare("rtpSenderReplaceTrack") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("rtpSenderReplaceTrack",
                    "rtpSenderReplaceTrack() peerConnection is null");
      return;
    }

    const std::string trackId = findString(params, "trackId");
    RTCMediaTrack* track = MediaTrackForId(trackId);

    const std::string rtpSenderId = findString(params, "rtpSenderId");
    if (rtpSenderId.empty()) {
      result->Error("rtpSenderReplaceTrack",
                    "rtpSenderReplaceTrack() rtpSenderId is null or empty");
      return;
    }
    RtpSenderReplaceTrack(pc, track, rtpSenderId, std::move(result));
  } else if (method_call.method_name().compare("rtpSenderSetParameters") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("rtpSenderSetParameters",
                    "rtpSenderSetParameters() peerConnection is null");
      return;
    }

    const std::string rtpSenderId = findString(params, "rtpSenderId");
    if (rtpSenderId.empty()) {
      result->Error("rtpSenderSetParameters",
                    "rtpSenderSetParameters() rtpSenderId is null or empty");
      return;
    }

    const EncodableMap parameters = findMap(params, "parameters");
    if (0 == parameters.size()) {
      result->Error("rtpSenderSetParameters",
                    "rtpSenderSetParameters() parameters is null or empty");
      return;
    }

    RtpSenderSetParameters(pc, rtpSenderId, parameters, std::move(result));
  } else if (method_call.method_name().compare("rtpTransceiverStop") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("rtpTransceiverStop",
                    "rtpTransceiverStop() peerConnection is null");
      return;
    }

    const std::string transceiverId = findString(params, "transceiverId");
    if (transceiverId.empty()) {
      result->Error("rtpTransceiverStop",
                    "rtpTransceiverStop() transceiverId is null or empty");
      return;
    }

    RtpTransceiverStop(pc, transceiverId, std::move(result));
  } else if (method_call.method_name().compare(
                 "rtpTransceiverGetCurrentDirection") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error(
          "rtpTransceiverGetCurrentDirection",
          "rtpTransceiverGetCurrentDirection() peerConnection is null");
      return;
    }

    const std::string transceiverId = findString(params, "transceiverId");
    if (transceiverId.empty()) {
      result->Error("rtpTransceiverGetCurrentDirection",
                    "rtpTransceiverGetCurrentDirection() transceiverId is "
                    "null or empty");
      return;
    }

    RtpTransceiverGetCurrentDirection(pc, transceiverId, std::move(result));
  } else if (method_call.method_name().compare("rtpTransceiverSetDirection") ==
             0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("rtpTransceiverSetDirection",
                    "rtpTransceiverSetDirection() peerConnection is null");
      return;
    }

    const std::string transceiverId = findString(params, "transceiverId");
    if (transceiverId.empty()) {
      result->Error("rtpTransceiverSetDirection",
                    "rtpTransceiverSetDirection() transceiverId is "
                    "null or empty");
      return;
    }

    const std::string direction = findString(params, "direction");
    if (transceiverId.empty()) {
      result->Error("rtpTransceiverSetDirection",
                    "rtpTransceiverSetDirection() direction is null or empty");
      return;
    }

    RtpTransceiverSetDirection(pc, transceiverId, direction, std::move(result));
  } else if (method_call.method_name().compare("setConfiguration") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("setConfiguration",
                    "setConfiguration() peerConnection is null");
      return;
    }

    const EncodableMap configuration = findMap(params, "configuration");
    if (configuration.empty()) {
      result->Error("setConfiguration",
                    "setConfiguration() configuration is null or empty");
      return;
    }
    SetConfiguration(pc, configuration, std::move(result));
  } else if (method_call.method_name().compare("captureFrame") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string path = findString(params, "path");
    if (path.empty()) {
      result->Error("captureFrame", "captureFrame() path is null or empty");
      return;
    }

    const std::string trackId = findString(params, "trackId");
    RTCMediaTrack* track = MediaTrackForId(trackId);
    if (nullptr == track) {
      result->Error("captureFrame", "captureFrame() track is null");
      return;
    }
    std::string kind = track->kind().std_string();
    if (0 != kind.compare("video")) {
      result->Error("captureFrame", "captureFrame() track not is video track");
      return;
    }
    CaptureFrame(reinterpret_cast<RTCVideoTrack*>(track), path,
                 std::move(result));

  } else if (method_call.method_name().compare("createLocalMediaStream") == 0) {
    CreateLocalMediaStream(std::move(result));
  } else if (method_call.method_name().compare("canInsertDtmf") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const std::string rtpSenderId = findString(params, "rtpSenderId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("canInsertDtmf", "canInsertDtmf() peerConnection is null");
      return;
    }

    auto rtpSender = GetRtpSenderById(pc, rtpSenderId);

    if (rtpSender == nullptr) {
      result->Error("sendDtmf", "sendDtmf() rtpSender is null");
      return;
    }
    auto dtmfSender = rtpSender->dtmf_sender();
    bool canInsertDtmf = dtmfSender->CanInsertDtmf();

    result->Success(EncodableValue(canInsertDtmf));
  } else if (method_call.method_name().compare("sendDtmf") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    const std::string rtpSenderId = findString(params, "rtpSenderId");
    const std::string tone = findString(params, "tone");
    int duration = findInt(params, "duration");
    int gap = findInt(params, "gap");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("sendDtmf", "sendDtmf() peerConnection is null");
      return;
    }

    auto rtpSender = GetRtpSenderById(pc, rtpSenderId);

    if (rtpSender == nullptr) {
      result->Error("sendDtmf", "sendDtmf() rtpSender is null");
      return;
    }

    auto dtmfSender = rtpSender->dtmf_sender();
    dtmfSender->InsertDtmf(tone, duration, gap);

    result->Success();
  } else if (method_call.method_name().compare("getRtpSenderCapabilities") ==
             0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    RTCMediaType mediaType = RTCMediaType::AUDIO;
    const std::string kind = findString(params, "kind");
    if (0 == kind.compare("video")) {
      mediaType = RTCMediaType::VIDEO;
    } else if (0 == kind.compare("audio")) {
      mediaType = RTCMediaType::AUDIO;
    } else {
      result->Error("getRtpSenderCapabilities",
                    "getRtpSenderCapabilities() kind is null or empty");
      return;
    }
    auto capabilities = factory_->GetRtpSenderCapabilities(mediaType);
    EncodableMap map;
    EncodableList codecsList;
    for (auto codec : capabilities->codecs().std_vector()) {
      EncodableMap codecMap;
      codecMap[EncodableValue("mimeType")] =
          EncodableValue(codec->mime_type().std_string());
      codecMap[EncodableValue("clockRate")] =
          EncodableValue(codec->clock_rate());
      codecMap[EncodableValue("channels")] = EncodableValue(codec->channels());
      codecMap[EncodableValue("sdpFmtpLine")] =
          EncodableValue(codec->sdp_fmtp_line().std_string());
      codecsList.push_back(EncodableValue(codecMap));
    }
    map[EncodableValue("codecs")] = EncodableValue(codecsList);
    map[EncodableValue("headerExtensions")] = EncodableValue(EncodableList());
    map[EncodableValue("fecMechanisms")] = EncodableValue(EncodableList());

    result->Success(EncodableValue(map));
  } else if (method_call.method_name().compare("getRtpReceiverCapabilities") ==
             0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    RTCMediaType mediaType = RTCMediaType::AUDIO;
    const std::string kind = findString(params, "kind");
    if (0 == kind.compare("video")) {
      mediaType = RTCMediaType::VIDEO;
    } else if (0 == kind.compare("audio")) {
      mediaType = RTCMediaType::AUDIO;
    } else {
      result->Error("getRtpSenderCapabilities",
                    "getRtpSenderCapabilities() kind is null or empty");
      return;
    }
    auto capabilities = factory_->GetRtpReceiverCapabilities(mediaType);
    EncodableMap map;
    EncodableList codecsList;
    for (auto codec : capabilities->codecs().std_vector()) {
      EncodableMap codecMap;
      codecMap[EncodableValue("mimeType")] =
          EncodableValue(codec->mime_type().std_string());
      codecMap[EncodableValue("clockRate")] =
          EncodableValue(codec->clock_rate());
      codecMap[EncodableValue("channels")] = EncodableValue(codec->channels());
      codecMap[EncodableValue("sdpFmtpLine")] =
          EncodableValue(codec->sdp_fmtp_line().std_string());
      codecsList.push_back(EncodableValue(codecMap));
    }
    map[EncodableValue("codecs")] = EncodableValue(codecsList);
    map[EncodableValue("headerExtensions")] = EncodableValue(EncodableList());
    map[EncodableValue("fecMechanisms")] = EncodableValue(EncodableList());

    result->Success(EncodableValue(map));
  } else if (method_call.method_name().compare("setCodecPreferences") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    const std::string peerConnectionId = findString(params, "peerConnectionId");
    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("setCodecPreferences",
                    "setCodecPreferences() peerConnection is null");
      return;
    }

    const std::string transceiverId = findString(params, "transceiverId");
    if (transceiverId.empty()) {
      result->Error("setCodecPreferences",
                    "setCodecPreferences() transceiverId is null or empty");
      return;
    }

    const EncodableList codecs = findList(params, "codecs");
    if (codecs.empty()) {
      result->Error("Bad Arguments", "Codecs is required");
      return;
    }
    RtpTransceiverSetCodecPreferences(pc, transceiverId, codecs,
                                      std::move(result));
  } else if (method_call.method_name().compare("getSignalingState") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getSignalingState",
                    "getSignalingState() peerConnection is null");
      return;
    }
    EncodableMap state;
    state[EncodableValue("state")] =
        signalingStateString(pc->signaling_state());
    result->Success(EncodableValue(state));
  } else if (method_call.method_name().compare("getIceGatheringState") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getIceGatheringState",
                    "getIceGatheringState() peerConnection is null");
      return;
    }
    EncodableMap state;
    state[EncodableValue("state")] =
        iceGatheringStateString(pc->ice_gathering_state());
    result->Success(EncodableValue(state));
  } else if (method_call.method_name().compare("getIceConnectionState") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getIceConnectionState",
                    "getIceConnectionState() peerConnection is null");
      return;
    }
    EncodableMap state;
    state[EncodableValue("state")] =
        iceConnectionStateString(pc->ice_connection_state());
    result->Success(EncodableValue(state));
  } else if (method_call.method_name().compare("getConnectionState") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Null constraints arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());

    const std::string peerConnectionId = findString(params, "peerConnectionId");

    RTCPeerConnection* pc = PeerConnectionForId(peerConnectionId);
    if (pc == nullptr) {
      result->Error("getConnectionState",
                    "getConnectionState() peerConnection is null");
      return;
    }
    EncodableMap state;
    state[EncodableValue("state")] =
        peerConnectionStateString(pc->peer_connection_state());
    result->Success(EncodableValue(state));
  } else if (method_call.method_name().compare("setLogSeverity") == 0) {
    if (!method_call.arguments()) {
      result->Error("Bad Arguments", "Bad arguments received");
      return;
    }
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    std::string severityStr = findString(params, "severity");
    if (severityStr.empty() == false) {
      RTCLoggingSeverity severity = str2LogSeverity(severityStr);
      initLoggerCallback(severity);
    }
  }
#ifdef _WIN32
  else if (method_call.method_name().compare("hollowWinStartScreenRecord") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    std::string path = findString(params, "path");
    if (path.empty()) {
      result->Error("BAD_PATH", "Output path missing");
      return;
    }
    // MMDevice endpoint ids of the devices Hollow is configured to use
    // (empty = system default) — see WinScreenRecorder::Start.
    std::string render_dev = findString(params, "renderDeviceId");
    std::string capture_dev = findString(params, "captureDeviceId");
    auto shared = std::shared_ptr<MethodResultProxy>(result.release());
    WinScreenRecorder::GetInstance().Start(
        path, render_dev, capture_dev, [shared](const std::string& err) {
          if (err.empty()) {
            EncodableMap m;
            m[EncodableValue("capturedSystemAudio")] = EncodableValue(
                WinScreenRecorder::GetInstance().LastCapturedSystemAudio());
            shared->Success(EncodableValue(m));
          } else {
            shared->Error("START_FAILED", err);
          }
        });
  } else if (method_call.method_name().compare("hollowWinStopScreenRecord") == 0) {
    auto shared = std::shared_ptr<MethodResultProxy>(result.release());
    WinScreenRecorder::GetInstance().Stop(
        [shared](const std::string& err) {
          if (err.empty()) {
            shared->Success(EncodableValue(true));
          } else {
            shared->Error("STOP_FAILED", err);
          }
        });
  } else if (method_call.method_name().compare("startScreenAudioCapture") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    StartScreenAudioCapture(params, std::move(result));
    return;
  } else if (method_call.method_name().compare("stopScreenAudioCapture") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    StopScreenAudioCapture(params, std::move(result));
    return;
  } else if (method_call.method_name().compare("screenAudioRender") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    ScreenAudioRender(params, std::move(result));
    return;
  } else if (method_call.method_name().compare("screenAudioRenderStop") == 0) {
    const EncodableMap params =
        GetValue<EncodableMap>(*method_call.arguments());
    ScreenAudioRenderStop(params, std::move(result));
    return;
  }
#endif
  else {
    if (HandleFrameCryptorMethodCall(method_call, std::move(result), &result)) {
      return;
    } else if (HandleDataPacketCryptorMethodCall(method_call, std::move(result),
                                                 &result)) {
      return;
    } else {
      result->NotImplemented();
    }
  }
}

void FlutterWebRTC::initLoggerCallback(RTCLoggingSeverity severity) {
  if (eventChannelProxy == nullptr) {
    eventChannelProxy = event_channel();
  }

  libwebrtc::LibWebRTCLogging::setLogSink(severity, [](const string& message) {
    EncodableMap info;
    info[EncodableValue("event")] = "onLogData";
    info[EncodableValue("data")] = message.c_string();
    eventChannelProxy->Success(EncodableValue(info), false);
  });
}

RTCLoggingSeverity FlutterWebRTC::str2LogSeverity(std::string str) {
  if (str == "verbose")
    return Verbose;
  else if (str == "info")
    return Info;
  else if (str == "warning")
    return Warning;
  else if (str == "error")
    return Error;
  else if (str == "none")
    return None;

  return None;
}

}  // namespace flutter_webrtc_plugin
