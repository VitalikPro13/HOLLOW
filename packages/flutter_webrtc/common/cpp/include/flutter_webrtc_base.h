#ifndef FLUTTER_WEBRTC_BASE_HXX
#define FLUTTER_WEBRTC_BASE_HXX

#include "flutter_common.h"

#include <string.h>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "libwebrtc.h"

#include "rtc_audio_device.h"
#include "rtc_audio_processing.h"
#include "rtc_desktop_device.h"
#include "rtc_dtmf_sender.h"
#include "rtc_frame_cryptor.h"
#include "rtc_media_stream.h"
#include "rtc_media_track.h"
#include "rtc_mediaconstraints.h"
#include "rtc_peerconnection.h"
#include "rtc_peerconnection_factory.h"
#include "rtc_video_device.h"

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class FlutterVideoRenderer;
class FlutterCaptureGainProcessor;
class FlutterRTCDataChannelObserver;
class FlutterPeerConnectionObserver;
#ifdef _WIN32
class FlutterVoiceRedirect;
#endif

// Hollow fork: serial worker for audio-track ops that are SYNCHRONOUS
// signaling-thread hops (set_enabled, SetVolume, stream->RemoveTrack for
// audio). This build's LiveKit core releases the microphone while all audio
// tracks are disabled/removed, so each of these can carry a full audio-HAL
// teardown (~0.5 s; 662 ms trackDispose hangup stall, sentinel 2026-07-18).
// With Flutter's merged UI/platform thread that blocks rendering — run them
// here instead. Order is preserved (single thread), audible behavior is
// identical. Desktop analog of Java audioTrackOpExecutor / darwin
// HollowAudioTrackOpQueue — KEEP the three in sync.
class HollowAudioOpQueue {
 public:
  ~HollowAudioOpQueue();
  // Queues `task` on the worker (lazily started). `op_name` must be a
  // string literal — it is kept by pointer for the sentinel line.
  void Post(const char* op_name, std::function<void()> task);
  // Drains remaining ops and joins the worker. Idempotent. Must run BEFORE
  // LibWebRTC::Terminate() (~FlutterWebRTCBase calls it explicitly — member
  // destruction alone would run after the Terminate in the dtor body).
  void Shutdown();

 private:
  struct QueuedOp {
    const char* name;
    std::chrono::steady_clock::time_point enqueued_at;
    std::function<void()> fn;
  };
  void Run();
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<QueuedOp> queue_;
  std::thread thread_;
  bool started_ = false;
  bool stop_ = false;
};

class FlutterWebRTCBase {
 public:
  friend class FlutterMediaStream;
  friend class FlutterPeerConnection;
  friend class FlutterVideoRendererManager;
  friend class FlutterDataChannel;
  friend class FlutterPeerConnectionObserver;
  friend class FlutterScreenCapture;
  friend class FlutterFrameCryptor;
  friend class FlutterDataPacketCryptor;
  enum ParseConstraintType { kMandatory, kOptional };

 public:
  FlutterWebRTCBase(BinaryMessenger* messenger,
                    TextureRegistrar* textures,
                    TaskRunner* task_runner);
  ~FlutterWebRTCBase();

  virtual scoped_refptr<RTCAudioProcessing> audio_processing() {
    return audio_processing_;
  }

  // Hollow fork: post-APM capture makeup gain + limiter. May be null if the
  // platform's audio processing module is unavailable.
  FlutterCaptureGainProcessor* capture_gain_processor() {
    return capture_gain_processor_;
  }

#ifdef _WIN32
  // Hollow fork (Windows): out-of-process renderer for remote call/voice audio,
  // used during entire-screen share so the call voices play from a separate pid
  // that the screen capture excludes (anti-echo) while Hollow's own media is
  // still captured. Lazily constructed on first use.
  FlutterVoiceRedirect* voice_redirect();
#endif

  virtual scoped_refptr<RTCMediaTrack> MediaTrackForId(const std::string& id);

  std::string GenerateUUID();

  RTCPeerConnection* PeerConnectionForId(const std::string& id);

  void RemovePeerConnectionForId(const std::string& id);

  void RemoveMediaTrackForId(const std::string& id);

  FlutterPeerConnectionObserver* PeerConnectionObserversForId(
      const std::string& id);

  void RemovePeerConnectionObserversForId(const std::string& id);

  scoped_refptr<RTCMediaStream> MediaStreamForId(
      const std::string& id,
      std::string ownerTag = std::string());

  void RemoveStreamForId(const std::string& id);

  bool ParseConstraints(const EncodableMap& constraints,
                        RTCConfiguration* configuration);

  scoped_refptr<RTCMediaConstraints> ParseMediaConstraints(
      const EncodableMap& constraints);

  bool ParseRTCConfiguration(const EncodableMap& map,
                             RTCConfiguration& configuration);

  scoped_refptr<RTCMediaTrack> MediaTracksForId(const std::string& id);

  void RemoveTracksForId(const std::string& id);

  EventChannelProxy* event_channel();

  libwebrtc::scoped_refptr<libwebrtc::RTCRtpSender> GetRtpSenderById(
      RTCPeerConnection* pc,
      std::string id);

  libwebrtc::scoped_refptr<libwebrtc::RTCRtpReceiver> GetRtpReceiverById(
      RTCPeerConnection* pc,
      std::string id);

  libwebrtc::scoped_refptr<libwebrtc::KeyProvider> GetKeyProviderForId(
      const std::string& keyProviderId);

  HollowAudioOpQueue& audio_op_queue() { return audio_op_queue_; }

 private:
  void ParseConstraints(const EncodableMap& src,
                        scoped_refptr<RTCMediaConstraints> mediaConstraints,
                        ParseConstraintType type = kMandatory);

  bool CreateIceServers(const EncodableList& iceServersArray,
                        IceServer* ice_servers);

 protected:
  scoped_refptr<RTCPeerConnectionFactory> factory_;
  scoped_refptr<RTCAudioDevice> audio_device_;
  scoped_refptr<RTCVideoDevice> video_device_;
  scoped_refptr<RTCDesktopDevice> desktop_device_;
  scoped_refptr<RTCAudioProcessing> audio_processing_;
  // Owned raw pointer (CustomProcessing's destructor is protected, so it
  // can't be deleted through the base interface; we delete the concrete type
  // in ~FlutterWebRTCBase). Held alive for the lifetime of the audio pipeline.
  FlutterCaptureGainProcessor* capture_gain_processor_ = nullptr;
#ifdef _WIN32
  // Owned; lazily created. Its dtor (which tears down the child process + writer
  // thread) runs from ~FlutterWebRTCBase, where the type is complete.
  std::unique_ptr<FlutterVoiceRedirect> voice_redirect_;
#endif
  RTCConfiguration configuration_;

  std::map<std::string, scoped_refptr<libwebrtc::KeyProvider>> key_providers_;
  std::map<std::string, scoped_refptr<RTCPeerConnection>> peerconnections_;
  std::map<std::string, scoped_refptr<RTCMediaStream>> local_streams_;
  std::map<std::string, scoped_refptr<RTCMediaTrack>> local_tracks_;
  std::map<std::string, scoped_refptr<RTCVideoCapturer>> video_capturers_;
  std::map<int64_t, std::shared_ptr<FlutterVideoRenderer>> renders_;
  std::map<std::string, std::shared_ptr<FlutterRTCDataChannelObserver>>
      data_channel_observers_;
  std::map<std::string, std::shared_ptr<FlutterPeerConnectionObserver>>
      peerconnection_observers_;
  mutable std::mutex mutex_;

  void lock() { mutex_.lock(); }
  void unlock() { mutex_.unlock(); }

 protected:
  BinaryMessenger* messenger_;
  TaskRunner* task_runner_;
  TextureRegistrar* textures_;
  std::unique_ptr<EventChannelProxy> event_channel_;
  // LAST member: destroyed first, so the worker drains and joins while the
  // factory/tracks above are still alive.
  HollowAudioOpQueue audio_op_queue_;
};

}  // namespace flutter_webrtc_plugin

#endif  // !FLUTTER_WEBRTC_BASE_HXX
