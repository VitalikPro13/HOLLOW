#include "flutter_webrtc_base.h"

#include "flutter_capture_gain_processor.h"
#include "flutter_data_channel.h"
#include "flutter_peerconnection.h"
#ifdef _WIN32
#include "flutter_voice_redirect.h"
#endif

#include "helper.h"

#include <cstdio>

namespace flutter_webrtc_plugin {

const char* kEventChannelName = "FlutterWebRTC.Event";

void HollowAudioOpQueue::Post(const char* op_name, std::function<void()> task) {
  std::unique_lock<std::mutex> lock(mu_);
  if (stop_) {
    return;  // plugin teardown — the drain in Shutdown() already ran
  }
  if (!started_) {
    started_ = true;
    thread_ = std::thread([this]() { Run(); });
  }
  queue_.push_back({op_name, std::chrono::steady_clock::now(), std::move(task)});
  cv_.notify_one();
}

void HollowAudioOpQueue::Run() {
  // [SENTINEL] enqueue->run latency watchdog: the queue keeps a congested
  // signaling thread from freezing the UI, but an op waiting >500 ms is
  // still an anomaly worth ONE line per episode (the latch re-arms once ops
  // run promptly again). KEEP IN SYNC with runAudioTrackOp
  // (MethodCallHandlerImpl.java) and HollowRunAudioTrackOp (darwin).
  bool congested = false;
  for (;;) {
    QueuedOp op;
    {
      std::unique_lock<std::mutex> lock(mu_);
      cv_.wait(lock, [this]() { return stop_ || !queue_.empty(); });
      if (queue_.empty()) {
        return;  // stop_ set and fully drained
      }
      op = std::move(queue_.front());
      queue_.pop_front();
    }
    const long long wait_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - op.enqueued_at)
            .count();
    if (wait_ms > 500) {
      if (!congested) {
        congested = true;
        std::fprintf(stderr,
                     "[SENTINEL] audioTrackOp %s enqueue->run %lldms "
                     "(signaling thread congested)\n",
                     op.name, wait_ms);
      }
    } else if (wait_ms < 100) {
      congested = false;
    }
    op.fn();
  }
}

void HollowAudioOpQueue::Shutdown() {
  {
    std::unique_lock<std::mutex> lock(mu_);
    stop_ = true;
  }
  cv_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }
}

HollowAudioOpQueue::~HollowAudioOpQueue() {
  Shutdown();
}

FlutterWebRTCBase::FlutterWebRTCBase(BinaryMessenger* messenger,
                                     TextureRegistrar* textures,
                                     TaskRunner *task_runner)
    : messenger_(messenger), task_runner_(task_runner), textures_(textures) {
  LibWebRTC::Initialize();
  factory_ = LibWebRTC::CreateRTCPeerConnectionFactory();
  factory_->Initialize();
  audio_device_ = factory_->GetAudioDevice();
  video_device_ = factory_->GetVideoDevice();
  desktop_device_ = factory_->GetDesktopDevice();
  audio_processing_ = factory_->GetAudioProcessing();
  // Hollow fork: install the post-APM makeup gain + limiter so calls aren't
  // left at WebRTC's conservative AGC target. Process-global — covers DM
  // calls and voice channels alike. Gain is driven live via setCaptureGain.
  if (audio_processing_) {
    capture_gain_processor_ = new FlutterCaptureGainProcessor();
    audio_processing_->SetCapturePostProcessing(capture_gain_processor_);
  }
  event_channel_ = EventChannelProxy::Create(messenger_, task_runner_, kEventChannelName);
}

FlutterWebRTCBase::~FlutterWebRTCBase() {
  // Drain queued audio ops while the factory/tracks are still alive.
  audio_op_queue_.Shutdown();
  LibWebRTC::Terminate();
  // Deleted after Terminate() so the audio pipeline no longer references it.
  if (capture_gain_processor_) {
    delete capture_gain_processor_;
    capture_gain_processor_ = nullptr;
  }
}

EventChannelProxy* FlutterWebRTCBase::event_channel() {
  return event_channel_ ? event_channel_.get() : nullptr;
}

#ifdef _WIN32
FlutterVoiceRedirect* FlutterWebRTCBase::voice_redirect() {
  if (!voice_redirect_) {
    voice_redirect_ = std::make_unique<FlutterVoiceRedirect>();
  }
  return voice_redirect_.get();
}
#endif

std::string FlutterWebRTCBase::GenerateUUID() {
  return libwebrtc::Helper::CreateRandomUuid().std_string();
}

RTCPeerConnection* FlutterWebRTCBase::PeerConnectionForId(
    const std::string& id) {
  auto it = peerconnections_.find(id);

  if (it != peerconnections_.end())
    return (*it).second.get();

  return nullptr;
}

void FlutterWebRTCBase::RemovePeerConnectionForId(const std::string& id) {
  auto it = peerconnections_.find(id);
  if (it != peerconnections_.end())
    peerconnections_.erase(it);
}

scoped_refptr<RTCMediaTrack> FlutterWebRTCBase ::MediaTrackForId(const std::string& id) {
  auto it = local_tracks_.find(id);

  if (it != local_tracks_.end())
    return (*it).second;

  for (auto kv : peerconnection_observers_) {
    auto pco = kv.second.get();
    auto track = pco->MediaTrackForId(id);
    if (track != nullptr)
      return track;
  }

  return nullptr;
}

void FlutterWebRTCBase::RemoveMediaTrackForId(const std::string& id) {
  auto it = local_tracks_.find(id);
  if (it != local_tracks_.end())
    local_tracks_.erase(it);
}

FlutterPeerConnectionObserver* FlutterWebRTCBase::PeerConnectionObserversForId(
    const std::string& id) {
  auto it = peerconnection_observers_.find(id);

  if (it != peerconnection_observers_.end())
    return (*it).second.get();

  return nullptr;
}

void FlutterWebRTCBase::RemovePeerConnectionObserversForId(
    const std::string& id) {
  auto it = peerconnection_observers_.find(id);
  if (it != peerconnection_observers_.end())
    peerconnection_observers_.erase(it);
}

scoped_refptr<RTCMediaStream> FlutterWebRTCBase::MediaStreamForId(
    const std::string& id, std::string ownerTag) {
  if (!ownerTag.empty()) {
    if (ownerTag == "local") {
      auto it = local_streams_.find(id);
      if (it != local_streams_.end()) {
        return (*it).second;
      }
    } else {
      auto pco = peerconnection_observers_.find(ownerTag);
      if (peerconnection_observers_.end() != pco) {
        auto stream = pco->second->MediaStreamForId(id);
        if (stream != nullptr) {
          return stream;
        }
      }
    }
  }

  auto it = local_streams_.find(id);
  if (it != local_streams_.end()) {
    return (*it).second;
  }

  return nullptr;
}

void FlutterWebRTCBase::RemoveStreamForId(const std::string& id) {
  auto it = local_streams_.find(id);
  if (it != local_streams_.end())
    local_streams_.erase(it);
}

bool FlutterWebRTCBase::ParseConstraints(const EncodableMap& constraints,
                                         RTCConfiguration* configuration) {
  memset(&configuration->ice_servers, 0, sizeof(configuration->ice_servers));
  return false;
}

void FlutterWebRTCBase::ParseConstraints(
    const EncodableMap& src,
    scoped_refptr<RTCMediaConstraints> mediaConstraints,
    ParseConstraintType type /*= kMandatory*/) {
  for (auto kv : src) {
    EncodableValue k = kv.first;
    EncodableValue v = kv.second;
    std::string key = GetValue<std::string>(k);
    std::string value;
    if (TypeIs<EncodableList>(v) || TypeIs<EncodableMap>(v)) {
    } else if (TypeIs<std::string>(v)) {
      value = GetValue<std::string>(v);
    } else if (TypeIs<double>(v)) {
      value = std::to_string(GetValue<double>(v));
    } else if (TypeIs<int>(v)) {
      value = std::to_string(GetValue<int>(v));
    } else if (TypeIs<bool>(v)) {
      value = GetValue<bool>(v) ? RTCMediaConstraints::kValueTrue
                                : RTCMediaConstraints::kValueFalse;
    } else {
      value = std::to_string(GetValue<int>(v));
    }
    if (type == kMandatory) {
      mediaConstraints->AddMandatoryConstraint(key.c_str(), value.c_str());
    } else {
      mediaConstraints->AddOptionalConstraint(key.c_str(), value.c_str());
      if (key == "DtlsSrtpKeyAgreement") {
        configuration_.srtp_type = GetValue<bool>(v)
                                       ? MediaSecurityType::kDTLS_SRTP
                                       : MediaSecurityType::kSDES_SRTP;
      }
    }
  }
}

scoped_refptr<RTCMediaConstraints> FlutterWebRTCBase::ParseMediaConstraints(
    const EncodableMap& constraints) {
  scoped_refptr<RTCMediaConstraints> media_constraints =
      RTCMediaConstraints::Create();

  if (constraints.find(EncodableValue("mandatory")) != constraints.end()) {
    auto it = constraints.find(EncodableValue("mandatory"));
    const EncodableMap mandatory = GetValue<EncodableMap>(it->second);
    ParseConstraints(mandatory, media_constraints, kMandatory);
  } else {
    // Log.d(TAG, "mandatory constraints are not a map");
  }

  auto it = constraints.find(EncodableValue("optional"));
  if (it != constraints.end()) {
    const EncodableValue optional = it->second;
    if (TypeIs<EncodableMap>(optional)) {
      ParseConstraints(GetValue<EncodableMap>(optional), media_constraints,
                       kOptional);
    } else if (TypeIs<EncodableList>(optional)) {
      const EncodableList list = GetValue<EncodableList>(optional);
      for (size_t i = 0; i < list.size(); i++) {
        ParseConstraints(GetValue<EncodableMap>(list[i]), media_constraints,
                         kOptional);
      }
    }
  } else {
    // Log.d(TAG, "optional constraints are not an array");
  }

  return media_constraints;
}

bool FlutterWebRTCBase::CreateIceServers(const EncodableList& iceServersArray,
                                         IceServer* ice_servers) {
  size_t size = iceServersArray.size();
  for (size_t i = 0; i < size; i++) {
    IceServer& ice_server = ice_servers[i];
    EncodableMap iceServerMap = GetValue<EncodableMap>(iceServersArray[i]);

    if (iceServerMap.find(EncodableValue("username")) != iceServerMap.end()) {
      ice_server.username = GetValue<std::string>(
          iceServerMap.find(EncodableValue("username"))->second);
    }
    if (iceServerMap.find(EncodableValue("credential")) != iceServerMap.end()) {
      ice_server.password = GetValue<std::string>(
          iceServerMap.find(EncodableValue("credential"))->second);
    }

    auto it = iceServerMap.find(EncodableValue("url"));
    if (it != iceServerMap.end() && TypeIs<std::string>(it->second)) {
      ice_server.uri = GetValue<std::string>(it->second);
    }
    it = iceServerMap.find(EncodableValue("urls"));
    if (it != iceServerMap.end()) {
      if (TypeIs<std::string>(it->second)) {
        ice_server.uri = GetValue<std::string>(it->second);
      }
      if (TypeIs<EncodableList>(it->second)) {
        const EncodableList urls = GetValue<EncodableList>(it->second);
        for (auto url : urls) {
          if (TypeIs<EncodableMap>(url)) {
            const EncodableMap map = GetValue<EncodableMap>(url);
            std::string value;
            auto it2 = map.find(EncodableValue("url"));
            if (it2 != map.end()) {
              ice_server.uri = GetValue<std::string>(it2->second);
            }
          } else if (TypeIs<std::string>(url)) {
            ice_server.uri = GetValue<std::string>(url);
          }
        }
      }
    }
  }
  return size > 0;
}

bool FlutterWebRTCBase::ParseRTCConfiguration(const EncodableMap& map,
                                              RTCConfiguration& conf) {
  auto it = map.find(EncodableValue("iceServers"));
  if (it != map.end()) {
    const EncodableList iceServersArray = GetValue<EncodableList>(it->second);
    CreateIceServers(iceServersArray, conf.ice_servers);
  }
  // iceTransportPolicy (public API)
  it = map.find(EncodableValue("iceTransportPolicy"));
  if (it != map.end() && TypeIs<std::string>(it->second)) {
    std::string v = GetValue<std::string>(it->second);
    if (v == "all")  // public
      conf.type = IceTransportsType::kAll;
    else if (v == "relay")
      conf.type = IceTransportsType::kRelay;
    else if (v == "nohost")
      conf.type = IceTransportsType::kNoHost;
    else if (v == "none")
      conf.type = IceTransportsType::kNone;
  }

  // bundlePolicy (public api)
  it = map.find(EncodableValue("bundlePolicy"));
  if (it != map.end() && TypeIs<std::string>(it->second)) {
    std::string v = GetValue<std::string>(it->second);
    if (v == "balanced")  // public
      conf.bundle_policy = kBundlePolicyBalanced;
    else if (v == "max-compat")  // public
      conf.bundle_policy = kBundlePolicyMaxCompat;
    else if (v == "max-bundle")  // public
      conf.bundle_policy = kBundlePolicyMaxBundle;
  }

  // rtcpMuxPolicy (public api)
  it = map.find(EncodableValue("rtcpMuxPolicy"));
  if (it != map.end() && TypeIs<std::string>(it->second)) {
    std::string v = GetValue<std::string>(it->second);
    if (v == "negotiate")  // public
      conf.rtcp_mux_policy = RtcpMuxPolicy::kRtcpMuxPolicyNegotiate;
    else if (v == "require")  // public
      conf.rtcp_mux_policy = RtcpMuxPolicy::kRtcpMuxPolicyRequire;
  }

  // FIXME: peerIdentity of type DOMString (public API)
  // FIXME: certificates of type sequence<RTCCertificate> (public API)
  // iceCandidatePoolSize of type unsigned short, defaulting to 0
  it = map.find(EncodableValue("iceCandidatePoolSize"));
  if (it != map.end()) {
    conf.ice_candidate_pool_size = GetValue<int>(it->second);
  }

  // sdpSemantics (public api)
  it = map.find(EncodableValue("sdpSemantics"));
  if (it != map.end() && TypeIs<std::string>(it->second)) {
    std::string v = GetValue<std::string>(it->second);
    if (v == "plan-b")  // public
      conf.sdp_semantics = SdpSemantics::kPlanB;
    else if (v == "unified-plan")  // public
      conf.sdp_semantics = SdpSemantics::kUnifiedPlan;
  } else {
    conf.sdp_semantics = SdpSemantics::kUnifiedPlan;
  }

  it = map.find(EncodableValue("enableDscp"));
  if (it != map.end() && TypeIs<bool>(it->second)) {
    conf.enable_dscp = GetValue<bool>(it->second);
  }

  // maxIPv6Networks
  it = map.find(EncodableValue("maxIPv6Networks"));
  if (it != map.end()) {
    conf.max_ipv6_networks = GetValue<int>(it->second);
  }
  return true;
}

scoped_refptr<RTCMediaTrack> FlutterWebRTCBase::MediaTracksForId(
    const std::string& id) {
  auto it = local_tracks_.find(id);
  if (it != local_tracks_.end()) {
    return (*it).second;
  }

  for (auto it2 : peerconnection_observers_) {
    auto pco = it2.second;
    auto t = pco->MediaTrackForId(id);
    if (t != nullptr) {
      return t;
    }
  }

  return nullptr;
}

void FlutterWebRTCBase::RemoveTracksForId(const std::string& id) {
  auto it = local_tracks_.find(id);
  if (it != local_tracks_.end())
    local_tracks_.erase(it);
}

libwebrtc::scoped_refptr<libwebrtc::RTCRtpSender>
FlutterWebRTCBase::GetRtpSenderById(RTCPeerConnection* pc, std::string id) {
  libwebrtc::scoped_refptr<libwebrtc::RTCRtpSender> result;
  auto senders = pc->senders();
  for (scoped_refptr<RTCRtpSender> item : senders.std_vector()) {
    std::string itemId = item->id().std_string();
    if (nullptr == result.get() && 0 == id.compare(itemId)) {
      result = item;
    }
  }
  return result;
}

libwebrtc::scoped_refptr<libwebrtc::RTCRtpReceiver>
FlutterWebRTCBase::GetRtpReceiverById(RTCPeerConnection* pc,
                                          std::string id) {
  libwebrtc::scoped_refptr<libwebrtc::RTCRtpReceiver> result;
  auto receivers = pc->receivers();
  for (scoped_refptr<RTCRtpReceiver> item : receivers.std_vector()) {
    std::string itemId = item->id().std_string();
    if (nullptr == result.get() && 0 == id.compare(itemId)) {
      result = item;
    }
  }
  return result;
}

libwebrtc::scoped_refptr<libwebrtc::KeyProvider> FlutterWebRTCBase::GetKeyProviderForId(
      const std::string& keyProviderId) {
  auto it = key_providers_.find(keyProviderId);
  if (it != key_providers_.end()) {
    return it->second;
  }
  return nullptr;
}

}  // namespace flutter_webrtc_plugin
