import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import '../call_setup_trace.dart';
import 'frame_cryptor_service.dart';
import 'ice_repair.dart';
import 'ice_route_probe.dart';
import 'local_speaking_detector.dart';
import 'pending_ice_queue.dart';
import 'remote_track_volume.dart';
import 'video_quality_ladder.dart';

/// Log to hollow_debug.log (visible in release builds).
void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Manages a dedicated voice/video RTCPeerConnection for 1:1 calls.
///
/// Separate from [WebRtcService] which handles data channel file transfers.
/// Voice has a different lifecycle: no idle timeout, no keepalive, no chunked
/// binary protocol. Created when a call starts, destroyed when it ends.
/// Each call gets its own ICE negotiation — this is critical for cross-internet
/// connectivity where the data channel's ICE path may not carry media.
class VoiceService {
  final String localPeerId;

  /// ICE configuration (STUN + TURN). Updated by CallNotifier.
  Map<String, dynamic> iceServers;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _activePeerId;
  String? _activeCallId;
  bool _isMuted = false;

  /// ICE candidates received before setRemoteDescription is called, keyed by
  /// the call they belong to. See [PendingIceQueue] for why the key matters.
  late final PendingIceQueue _pendingCandidates = PendingIceQueue(log: _log);
  bool _remoteDescriptionSet = false;

  // -- Video state --
  MediaStream? _localVideoStream;
  bool _isVideoEnabled = false;
  bool _useFrontCamera = true;
  /// Serializes [toggleVideo] so rapid on/off (or two concurrent toggles)
  /// can't overlap two `getUserMedia` calls on the same V4L2 device — that
  /// races the old capturer's teardown against the new one's start, which
  /// libwebrtc's RaceChecker aborts on Linux ("video_capture_v4l2.cc:417
  /// RaceDetected") and leaks the orphaned capture thread elsewhere. Each
  /// toggle awaits the previous one's full completion before touching the
  /// camera.
  Future<void> _videoToggleLock = Future<void>.value();
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  MediaStream? _remoteStream;
  /// True if `_remoteStream` was created locally via `createLocalMediaStream`
  /// (and we own it). False if it came from `event.streams.first` in onTrack
  /// (libwebrtc owns it — disposing it from Dart throws "stream not found").
  bool _remoteStreamIsSynthetic = false;

  // Callbacks
  void Function(String peerId)? onConnected;

  /// Raw transport-state changes for the call's peer connection.
  ///
  /// Deliberately raw. This service used to collapse `disconnected`, `failed`
  /// and `closed` into a single "the call is over" callback, and the provider
  /// answered it by signalling `end` to the peer and cleaning up. Since
  /// `disconnected` only means ICE consent has gone unanswered for a couple of
  /// seconds, which is the ordinary signature of a Wi-Fi stutter, one side's
  /// blip hung the call up on both machines.
  ///
  /// The hold-open policy now lives in CallNotifier (see [LinkResilience]),
  /// because only it knows the peer, the call id and when an `end` is
  /// warranted. NOTHING in this service may end a call on its own.
  void Function(RTCPeerConnectionState state)? onTransportState;

  void Function(String peerId)? onRemoteVideoTrack;

  /// Set for the duration of our own teardown. `closed` is reported both when
  /// the remote end goes away and when we call `pc.close()` ourselves, and the
  /// policy owner reads it as terminal; forwarding our own teardown back to it
  /// would race the cleanup that is already running.
  bool _tearingDown = false;

  /// Preferred device IDs (set by CallNotifier from settings providers).
  String? preferredAudioInputDeviceId;
  String? preferredAudioOutputDeviceId;
  String? preferredCameraDeviceId;

  /// Microphone input gain (0.0-2.0). Applied via SetVolume on local audio track.
  double micGain = 1.0;

  /// Voice enhancement: EQ+compressor+limiter chain in the native capture
  /// post-processor (default on; off = legacy flat makeup gain).
  bool voiceEnhance = true;

  /// Enhancement strength = the chain's compressor makeup gain in dB
  /// (0 = no loudness boost, 12 = 100% on the slider).
  double enhanceMakeupDb = 3.6;

  /// Dynamic mode: the native auto-level servo (ignores micGain/makeup).
  bool enhanceDynamic = true;

  /// AI noise suppression — user preference, seeded from
  /// noiseSuppressAiProvider. The engine runs at the HEAD of the native
  /// capture chain (post-AEC); while it's on, WebRTC's legacy NS is dropped
  /// from the capture constraints (double suppression = artifacts).
  bool noiseSuppressAi = false;

  /// Which engine (Helper.nsEngineRnnoise default / nsEngineDfn3), seeded
  /// from noiseSuppressEngineProvider.
  int noiseSuppressEngine = Helper.nsEngineRnnoise;

  /// TRUE when DFN can't actually run here (symbols unbound, unsupported
  /// capture shape, realtime bail) and WebRTC's legacy NS was re-enabled as
  /// the fallback — a call must never end up with NO noise suppression.
  bool _dfnFallbackNsOn = false;

  /// WebRTC's own NS is wanted whenever DFN isn't (or can't be) doing the job.
  bool get _wantWebrtcNs => !noiseSuppressAi || _dfnFallbackNsOn;

  /// SFrame encryption service for DM call E2EE.
  FrameCryptorService? _frameCryptor;
  FrameCryptorService? get frameCryptor => _frameCryptor;

  // -- VAD (voice activity detection) for DM calls --
  Timer? _vadTimer;
  final Map<String, double> _prevEnergy = {};
  bool _localSpeaking = false;
  bool _remoteSpeaking = false;
  bool get isLocalSpeaking => _localSpeaking;
  bool get isRemoteSpeaking => _remoteSpeaking;
  void Function(bool localSpeaking, bool remoteSpeaking)? onSpeakingChanged;

  VoiceService({required this.localPeerId, Map<String, dynamic>? iceServers, String relayDomain = 'relay.anonlisten.com'})
      : iceServers = iceServers ?? _defaultIceServers(domain: relayDomain);

  bool get isMuted => _isMuted;
  bool get hasActiveCall => _pc != null;
  String? get activePeerId => _activePeerId;
  String? get activeCallId => _activeCallId;
  bool get isVideoEnabled => _isVideoEnabled;
  RTCVideoRenderer? get localRenderer => _localRenderer;
  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;
  RTCPeerConnection? get peerConnection => _pc;

  /// Audio quality preset — set by CallNotifier before creating offer/answer.
  /// Controls Opus bitrate and stereo via SDP munging.
  int opusBitrate = 96000;     // default: 96 kbps (voice)
  bool opusStereo = false;     // default: mono

  // ---------------------------------------------------------------------------
  // SDP: offer / answer / ICE
  // ---------------------------------------------------------------------------

  /// Create the initial SDP offer for a DM call. Audio is always captured.
  /// Camera is captured only if [withVideo] is true — for audio-only calls
  /// we do NOT pre-add a video transceiver, matching the voice channel
  /// pattern. When the user later enables video, [toggleVideo] uses
  /// `pc.addTrack` to create a fresh transceiver and renegotiate, which
  /// fires `onTrack` reliably on the remote peer.
  ///
  /// Media is captured BEFORE the peer connection is created so that ICE
  /// gathering starts only when tracks are already available — keeping the
  /// PC→offer window under ~15 ms (same pattern as VoiceChannelService).
  Future<String> createOffer(
    String peerId,
    String callId, {
    bool withVideo = false,
  }) async {
    _log('[HOLLOW-VOICE] Creating offer for $peerId call=$callId withVideo=$withVideo');

    // Tear down any prior session's media BEFORE capturing new media — capture
    // overwrites _localStream/_localVideoStream, so without this a re-entrant
    // call (or a leftover session) would orphan the previous streams + their
    // mic/V4L2 capturers. _initPeerConnection's PC guard alone is not enough.
    await _teardownMedia(keepCandidatesForCallId: callId);

    _activePeerId = peerId;
    _activeCallId = callId;

    try {
      // Pre-capture media BEFORE creating the PC.
      await _captureLocalAudio();
      CallSetupTrace.markCurrent(CallSetupTrace.kGumAudio);
      if (withVideo) {
        await _captureLocalVideo();
        CallSetupTrace.markCurrent(CallSetupTrace.kGumVideo);
      }

      await _initPeerConnection(peerId, callId);
      CallSetupTrace.markCurrent(CallSetupTrace.kPc);
      _addLocalAudioTracks();

      if (withVideo && _localVideoStream != null) {
        await _addLocalVideoTracks();
        _isVideoEnabled = true;
        await _initLocalRenderer();
      }

      final offer = await _pc!.createOffer();
      final mungedOffer = _mungeOpusParams(offer.sdp!);
      CallSetupTrace.markCurrent(CallSetupTrace.kSdp);
      await _pc!.setLocalDescription(
          RTCSessionDescription(mungedOffer, offer.type));
      // Gathering starts here, not at createPeerConnection.
      CallSetupTrace.markCurrent(CallSetupTrace.kSld);

      _log('[HOLLOW-VOICE] Offer created, SDP length=${mungedOffer.length}');
      _dumpSdp('OFFER-OUT', mungedOffer);
      return mungedOffer;
    } catch (e) {
      // A throw mid-setup (bad SDP, getUserMedia/createOffer failure) leaves a
      // partially-built PC + capturers stranded. Tear them down before
      // propagating so their thread-sets can't leak.
      _log('[HOLLOW-VOICE] createOffer failed, tearing down: $e');
      await endCall();
      rethrow;
    }
  }

  /// Handle an incoming SDP offer (answerer side). Creates PC, starts mic,
  /// optionally captures the camera, sets remote description, creates answer.
  /// Camera is only captured when [withVideo] is true (the local user accepted
  /// a video call). If the remote offer has a video m-line but we have no
  /// camera, libwebrtc will produce an `a=recvonly` answer for the video
  /// m-line — that's fine, RTP still flows from sender to receiver.
  ///
  /// Media is captured BEFORE the peer connection is created (see createOffer).
  Future<String> handleOffer(
    String peerId,
    String callId,
    String sdp, {
    bool withVideo = false,
  }) async {
    _log('[HOLLOW-VOICE] Handling offer from $peerId call=$callId');

    // Tear down any prior session's media BEFORE capturing new media (see
    // createOffer) so a second inbound offer during the capture window can't
    // orphan the first session's streams/PC.
    await _teardownMedia(keepCandidatesForCallId: callId);

    _activePeerId = peerId;
    _activeCallId = callId;

    _dumpSdp('OFFER-IN', sdp);

    try {
      // Pre-capture media BEFORE creating the PC.
      await _captureLocalAudio();
      CallSetupTrace.markCurrent(CallSetupTrace.kGumAudio);
      if (withVideo) {
        await _captureLocalVideo();
        CallSetupTrace.markCurrent(CallSetupTrace.kGumVideo);
      }

      await _initPeerConnection(peerId, callId);
      CallSetupTrace.markCurrent(CallSetupTrace.kPc);
      _addLocalAudioTracks();

      if (withVideo && _localVideoStream != null) {
        await _addLocalVideoTracks();
        _isVideoEnabled = true;
        await _initLocalRenderer();
      }

      // Record the BASELINE ICE credentials, even though this is not a
      // restart. Without it the callee starts the call with no remembered
      // ufrag, so its FIRST renegotiation reads as "nothing changed" and the
      // ICE-restart detection misses it entirely.
      //
      // Field-caught 2026-08-27: the callee's SFrame was therefore never
      // re-asserted after a recovery. Its sender cryptor stayed bound to a
      // transport that no longer existed while the caller re-created its
      // receiver, so the callee's microphone went silent to the other side and
      // the caller's audio failed to decrypt. Both directions, one missing
      // baseline.
      _noteRemoteIceCredentials(sdp);
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
      await _flushPendingCandidates();

      final answer = await _pc!.createAnswer();
      final mungedAnswer = _mungeOpusParams(answer.sdp!);
      CallSetupTrace.markCurrent(CallSetupTrace.kSdp);
      await _pc!.setLocalDescription(
          RTCSessionDescription(mungedAnswer, answer.type));
      // Gathering starts here, not at createPeerConnection.
      CallSetupTrace.markCurrent(CallSetupTrace.kSld);

      _log('[HOLLOW-VOICE] Answer created, SDP length=${mungedAnswer.length}');
      _dumpSdp('ANSWER-OUT', mungedAnswer);
      return mungedAnswer;
    } catch (e) {
      // setRemoteDescription on an unsupported-codec SDP is a classic throw
      // point — dispose the partial PC + capturers before propagating.
      _log('[HOLLOW-VOICE] handleOffer failed, tearing down: $e');
      await endCall();
      rethrow;
    }
  }

  /// Create a renegotiation offer on an existing voice PC (e.g., adding/removing video).
  /// Returns the SDP offer string, or null if no PC exists.
  Future<String?> createRenegotiationOffer() async {
    if (_pc == null) {
      _log('[HOLLOW-VOICE] createRenegotiationOffer: no PC');
      return null;
    }

    // Defensive: a previously failed inbound renegotiation can leave the PC
    // in have-remote-offer, where createOffer errors out ("Error (null)")
    // forever. Roll the stale remote offer back to stable first.
    final ss = _pc!.signalingState;
    if (ss == RTCSignalingState.RTCSignalingStateHaveRemoteOffer ||
        ss == RTCSignalingState.RTCSignalingStateHaveRemotePrAnswer) {
      _log('[HOLLOW-VOICE] createRenegotiationOffer: signaling state $ss — '
          'rolling back stale remote offer');
      try {
        await _pc!.setRemoteDescription(RTCSessionDescription('', 'rollback'));
      } catch (_) {
        try {
          await _pc!.setLocalDescription(RTCSessionDescription('', 'rollback'));
        } catch (e) {
          _log('[HOLLOW-VOICE] Rollback before offer failed: $e');
        }
      }
    }

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    _log('[HOLLOW-VOICE] Renegotiation offer created, SDP length=${offer.sdp?.length}');
    _dumpSdp('RENEG-OFFER-OUT', offer.sdp!);
    return offer.sdp!;
  }

  /// Handle a renegotiation offer on an existing voice PC (e.g., remote added video).
  /// Returns the SDP answer string, or null if no PC exists.
  Future<String?> handleRenegotiationOffer(String sdp) async {
    if (_pc == null) {
      _log('[HOLLOW-VOICE] handleRenegotiationOffer: no PC');
      return null;
    }

    _dumpSdp('RENEG-OFFER-IN', sdp);

    try {
      final iceRestarted = _noteRemoteIceCredentials(sdp);
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      // The transport was rebuilt under us, so the frame cryptors are stale.
      // After setLocalDescription, so the new transport exists to bind to.
      if (iceRestarted) await healSframeAfterTransportRebuild();

      _log('[HOLLOW-VOICE] Renegotiation answer created, SDP length=${answer.sdp?.length}');
      _dumpSdp('RENEG-ANSWER-OUT', answer.sdp!);

      // Defer the safety net by a frame so onTrack has a chance to fire and
      // build the renderer. With H4 it should always fire — the safety net
      // only does work if the renderer is still null after the delay (and
      // even then, _checkRemoteVideoTrack is a no-op when a renderer exists).
      Future.delayed(const Duration(milliseconds: 150), _checkRemoteVideoTrack);

      return answer.sdp!;
    } catch (e) {
      // A failed renegotiation must NOT leave the PC stuck in
      // have-remote-offer — createOffer then errors out forever and this
      // call can never add video in EITHER direction again (seen when the
      // offer carries H.265/AV1 payload types the local decoder factory
      // can't apply). Roll back to stable, then rethrow so the caller's
      // queue/retry logic still observes the failure.
      _log('[HOLLOW-VOICE] Renegotiation answer failed: $e — rolling back to stable');
      try {
        await _pc!.setLocalDescription(RTCSessionDescription('', 'rollback'));
        _log('[HOLLOW-VOICE] Rollback via setLocalDescription succeeded');
      } catch (_) {
        try {
          await _pc!.setRemoteDescription(RTCSessionDescription('', 'rollback'));
          _log('[HOLLOW-VOICE] Rollback via setRemoteDescription succeeded');
        } catch (e2) {
          _log('[HOLLOW-VOICE] Rollback failed (PC may stay wedged): $e2');
        }
      }
      rethrow;
    }
  }

  /// Safety net for when [pc.onTrack] doesn't fire after a renegotiation.
  /// Walks the PC's receivers, and if a video track exists without a
  /// corresponding `_remoteRenderer`, creates one and notifies the UI.
  ///
  /// This is needed because on Windows/libwebrtc, calling `replaceTrack()`
  /// to swap a null sender track for a real camera track on an existing
  /// transceiver does NOT fire `onTrack` on the remote peer — even after
  /// a full SDP renegotiation cycle. Without this safety net, the remote
  /// peer would never create a renderer and the UI would stay audio-only.
  Future<void> _checkRemoteVideoTrack() async {
    final pc = _pc;
    if (pc == null) return;
    // With the H4 addTrack/removeTrack pattern, onTrack fires reliably for
    // every fresh video transceiver. If we already have a remote renderer,
    // trust that the onTrack handler built it correctly — running the
    // safety net here would walk pc.getReceivers() and pick up STALE
    // inactive transceivers from previous toggles, then trash the working
    // renderer trying to rebind to a dead track.
    if (_remoteRenderer != null) return;
    try {
      final receivers = await pc.getReceivers();
      for (final receiver in receivers) {
        if (await _adoptOrphanRemoteVideoReceiver(receiver)) return;
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] _checkRemoteVideoTrack error: $e');
    }
  }

  /// Per-receiver body of [_checkRemoteVideoTrack]: if [receiver] carries a
  /// video track with no renderer, build one manually. Returns true when a
  /// renderer was committed (the caller stops scanning receivers).
  Future<bool> _adoptOrphanRemoteVideoReceiver(RTCRtpReceiver receiver) async {
    final track = receiver.track;
    if (track == null || track.kind != 'video') return false;
    // Capture the id once so a later null on the native side doesn't
    // crash logging or string interpolation.
    final trackId = track.id;
    if (trackId == null) return false;

    _log('[HOLLOW-VOICE] _checkRemoteVideoTrack: found video track '
        '$trackId without renderer — creating manually');

    // Stash old state for post-build dispose (same pattern as
    // _handleRemoteVideoTrack — never dispose the old stream BEFORE
    // the new renderer is committed).
    final oldRenderer = _remoteRenderer;
    final oldStream = _remoteStream;
    final oldWasSynthetic = _remoteStreamIsSynthetic;

    // Re-fetch the track right before addTrack — between awaits the
    // native track may have been GC'd / detached.
    final liveTrack = receiver.track;
    if (liveTrack == null) {
      _log('[HOLLOW-VOICE] _checkRemoteVideoTrack: track went away '
          'before addTrack, skipping');
      return false;
    }
    final newStream =
        await createLocalMediaStream('remote-video-$trackId');
    try {
      await newStream.addTrack(liveTrack);
    } catch (e) {
      _log('[HOLLOW-VOICE] _checkRemoteVideoTrack: addTrack failed '
          '($e), disposing partial stream');
      try {
        await newStream.dispose();
      } catch (_) {}
      return false;
    }

    final newRenderer = RTCVideoRenderer();
    await newRenderer.initialize();
    newRenderer.srcObject = newStream;

    // Commit new state first.
    _remoteRenderer = newRenderer;
    _remoteStream = newStream;
    _remoteStreamIsSynthetic = true;

    // Best-effort dispose of the old.
    await _disposeStaleRemoteMedia(oldRenderer, oldStream, oldWasSynthetic);

    _log('[HOLLOW-VOICE] _checkRemoteVideoTrack: renderer created for '
        'track=$trackId, stream=${_remoteStream?.id}');

    // Give the renderer a moment to settle before notifying UI.
    await Future.delayed(const Duration(milliseconds: 100));

    // Notify UI via the same callback that _handleRemoteVideoTrack uses.
    final activePeerId = _activePeerId;
    if (activePeerId != null) {
      onRemoteVideoTrack?.call(activePeerId);
    }
    return true;
  }

  /// Silent best-effort dispose of a superseded remote renderer/stream
  /// (safety-net path — failures here are expected and stay unlogged, same
  /// as the original inline code).
  Future<void> _disposeStaleRemoteMedia(RTCVideoRenderer? oldRenderer,
      MediaStream? oldStream, bool oldWasSynthetic) async {
    if (oldRenderer != null) {
      try {
        oldRenderer.srcObject = null;
        await oldRenderer.dispose();
      } catch (_) {}
    }
    if (oldStream != null && oldWasSynthetic) {
      try {
        await oldStream.dispose();
      } catch (_) {}
    }
  }

  /// Handle incoming SDP answer (offerer side).
  Future<void> handleAnswer(String sdp) async {
    if (_pc == null) {
      _log('[HOLLOW-VOICE] handleAnswer: no PC, ignoring');
      return;
    }
    _dumpSdp('ANSWER-IN', sdp);
    _log('[HOLLOW-VOICE] Setting remote description (answer)');
    final iceRestarted = _noteRemoteIceCredentials(sdp);
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();

    // Answering an ICE restart obliges the far end to produce fresh
    // credentials too, so this fires on the offering side as well.
    if (iceRestarted) await healSframeAfterTransportRebuild();

    // Defer the safety net by a frame so onTrack has a chance to fire first.
    Future.delayed(const Duration(milliseconds: 150), _checkRemoteVideoTrack);
  }

  /// Handle incoming ICE candidate.
  /// Candidates are queued until setRemoteDescription has been called — adding
  /// them before that causes silent rejection by libwebrtc (the native layer
  /// returns an error if there's no remote description yet).
  Future<void> handleIceCandidate(String callId, String candidate,
      String? sdpMid, int? sdpMLineIndex) async {
    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    CallSetupTrace.markCurrent(CallSetupTrace.kRemoteCand);

    if (!_remoteDescriptionSet || _pc == null) {
      _pendingCandidates.add(callId, iceCandidate);
      return;
    }

    try {
      await _pc!.addCandidate(iceCandidate);
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to add ICE candidate: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Media controls
  // ---------------------------------------------------------------------------

  /// Set microphone mute (idempotent — the PTT gate calls this on every key
  /// edge, so repeats must be harmless).
  /// [force] re-applies the state to the CURRENT capture track even when the
  /// cached flag already agrees.
  ///
  /// The flag describes the track it was last applied to, and a media rebuild
  /// replaces that track underneath it. `createOffer` tears media down without
  /// clearing `_isMuted`, so after a rebuild the flag says "muted" while the
  /// freshly captured track is live, and the ordinary early-return below turns
  /// the re-apply into a no-op. Field-caught 2026-08-27: the call recovered,
  /// the mute button still showed muted, and the microphone was open.
  void setMuted(bool muted, {bool force = false}) {
    if (_localStream == null) return;
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) return;
    if (_isMuted == muted && !force) return;
    _isMuted = muted;
    audioTracks.first.enabled = !_isMuted;
    // Freeze the capture processor's dynamic servo while muted — the APM
    // keeps processing real mic input with the track disabled, and adapting
    // to room bleed (e.g. shared music on speakers) buries the voice on
    // unmute.
    Helper.setCaptureMuted(_isMuted).catchError((_) {});
    _log('[HOLLOW-VOICE] Mute set: $_isMuted');
  }

  /// Toggle microphone mute.
  void toggleMute() => setMuted(!_isMuted);

  /// Set the volume of the remote peer's audio (how loud you hear them).
  /// volume: 0.0 = silent, 1.0 = normal, 2.0 = 2x.
  Future<void> setRemoteAudioVolume(double volume) async {
    if (_pc == null) return;
    final receivers = await _pc!.getReceivers();
    for (final r in receivers) {
      if (r.track?.kind == 'audio') {
        await setRemoteTrackVolume(volume, r.track!);
        _log('[HOLLOW-VOICE] Remote audio volume set to '
            '${volume.toStringAsFixed(2)}');
        break;
      }
    }
  }

  /// Track ids of the remote peer's inbound audio (the call voices). Used by the
  /// Windows entire-screen-share anti-echo path to redirect these tracks to an
  /// out-of-process renderer. Empty if no PC / no remote audio yet.
  Future<List<String>> getRemoteAudioTrackIds() async {
    if (_pc == null) return const [];
    final ids = <String>[];
    final receivers = await _pc!.getReceivers();
    for (final r in receivers) {
      final t = r.track;
      if (t != null && t.kind == 'audio' && (t.id?.isNotEmpty ?? false)) {
        ids.add(t.id!);
      }
    }
    return ids;
  }

  /// Toggle camera on/off. Returns the new state.
  ///
  /// Uses the same `addTrack` / `removeTrack` pattern as
  /// [VoiceChannelService.startCamera] / [VoiceChannelService.stopCamera]
  /// — every camera enable creates a fresh transceiver, every disable
  /// removes it. This ensures the remote peer's `onTrack` fires reliably
  /// (the receiver-side `replaceTrack` reuse pattern silently fails on
  /// libwebrtc Windows: the receiver renderer stays bound to a stale
  /// muted track and never recovers when sender RTP resumes).
  ///
  /// The caller must trigger an SDP renegotiation after toggleVideo
  /// returns successfully — see `CallNotifier.toggleVideo`.
  /// Public entry point — serialized so concurrent/rapid toggles can't open two
  /// V4L2 capturers at once (see [_videoToggleLock]). Each call awaits the
  /// previous toggle's full completion (old capturer fully stopped+disposed)
  /// before its own getUserMedia runs.
  Future<bool> toggleVideo() async {
    final prev = _videoToggleLock;
    final completer = Completer<void>();
    _videoToggleLock = completer.future;
    try {
      // Wait for any in-flight toggle to finish before we touch the camera.
      try {
        await prev;
      } catch (_) {}
      return await _toggleVideoInner();
    } finally {
      completer.complete();
    }
  }

  Future<bool> _toggleVideoInner() async {
    if (_pc == null) return false;

    // LINUX: the prebuilt libwebrtc V4L2 capturer's StopCapture() does NOT join
    // its CaptureThread, so any close-then-reopen of /dev/video* races the
    // RaceChecker and ABORTS the process (video_capture_v4l2.cc:417). A timed
    // settle proved insufficient on real hardware. The robust fix: NEVER close
    // the camera device mid-call — open it ONCE on the first enable, then toggle
    // purely via `track.enabled` (pauses/resumes frames; the device + its single
    // CaptureThread stay alive for the whole call and are torn down once at
    // endCall, where nothing reopens after). Tradeoff: on Linux the camera LED
    // may stay lit while "off" (frames are suppressed, nothing is transmitted).
    // Windows/macOS keep the addTrack/removeTrack behavior (no V4L2, no race).
    if (Platform.isLinux) {
      return await _toggleVideoLinux();
    }

    if (_isVideoEnabled) {
      await _disableVideoDesktop();
    } else if (!await _enableVideoDesktop()) {
      return false;
    }
    return _isVideoEnabled;
  }

  /// Desktop (Windows/macOS) video disable branch of [toggleVideo]:
  /// remove the video sender, release the camera, drop the self-preview.
  Future<void> _disableVideoDesktop() async {
    // Turn off: remove video sender from the PC entirely (not just
    // replaceTrack(null)). removeTrack causes the next renegotiation
    // to drop the video m-line, which the remote peer interprets as
    // "no more video" and tears down the receive side cleanly.
    try {
      final senders = await _pc!.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          await _pc!.removeTrack(s);
          _log('[HOLLOW-VOICE] toggleVideo: removed video sender');
          break;
        }
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] toggleVideo: removeTrack failed: $e');
    }

    // Stop & dispose the camera stream (turns off the camera light).
    if (_localVideoStream != null) {
      await _stopTracksAndDispose(_localVideoStream!);
      _localVideoStream = null;
    }

    // Dispose local self-preview renderer.
    if (_localRenderer != null) {
      _localRenderer!.srcObject = null;
      await _localRenderer!.dispose();
      _localRenderer = null;
    }

    _isVideoEnabled = false;
    _log('[HOLLOW-VOICE] Video disabled, camera released');
  }

  /// Desktop (Windows/macOS) video enable branch of [toggleVideo]. Returns
  /// false when capture fails or no camera is available.
  Future<bool> _enableVideoDesktop() async {
    // Turn on: capture camera and addTrack a brand new sender. This
    // creates a fresh transceiver with a fresh ssrc — the remote peer
    // gets a new onTrack event and builds a new renderer.
    _log('[HOLLOW-VOICE] Capturing camera for video enable');
    try {
      final constraints = _videoCaptureConstraints(preferredCameraDeviceId);
      // Belt-and-suspenders cleanup of any leaked stream from a
      // previous failed enable.
      if (_localVideoStream != null) {
        await _stopTracksAndDispose(_localVideoStream!);
        _localVideoStream = null;
      }
      _localVideoStream =
          await navigator.mediaDevices.getUserMedia(constraints);
      _capturedCameraDeviceId = preferredCameraDeviceId;
      final videoTracks = _localVideoStream!.getVideoTracks();
      if (videoTracks.isEmpty) {
        _log('[HOLLOW-VOICE] No camera available');
        await _localVideoStream!.dispose();
        _localVideoStream = null;
        return false;
      }
      final videoTrack = videoTracks.first;

      await _pc!.addTrack(videoTrack, _localVideoStream!);
      _log('[HOLLOW-VOICE] toggleVideo: added new video track via addTrack');

      // All platforms: constrain the offer to universal codecs (VP8 first).
      // Desktop builds otherwise advertise H.265/AV1 payload types that
      // break the iOS answerer; macOS additionally needs VP8-first because
      // its H.264 hw profile doesn't decode on Windows libwebrtc.
      if (videoTrack.id != null) {
        await _constrainCameraCodecs(videoTrack.id!);
      }

      // Hold the fresh sender to whatever rung this call has already fallen
      // to. Best-effort here (the sender is not negotiated yet, and a
      // pre-negotiation setParameters is dropped on the native path); the
      // quality sampler re-asserts it until it takes.
      await applyVideoRung(_videoRung);

      _isVideoEnabled = true;
      await _initLocalRenderer();
      _log('[HOLLOW-VOICE] Video enabled, camera active');
      _scheduleVideoStatsProbes('send');
      return true;
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to capture camera: $e');
      return false;
    }
  }

  /// Linux video toggle that NEVER closes/reopens the V4L2 device (which would
  /// race the libwebrtc CaptureThread → abort). The camera is opened ONCE on the
  /// first enable and the same track is paused/resumed via `enabled` thereafter;
  /// the device is released only at endCall.
  Future<bool> _toggleVideoLinux() async {
    if (_isVideoEnabled) {
      // Pause: stop frames flowing WITHOUT stopping the track / closing the
      // device. The remote sees frames cease. Keep the sender + m-line in place.
      final track = _localVideoStream?.getVideoTracks().firstOrNull;
      if (track != null) track.enabled = false;
      _isVideoEnabled = false;
      // Drop the local self-preview so the UI doesn't show a frozen last frame.
      // (The capture stream stays alive — only the renderer is torn down.)
      if (_localRenderer != null) {
        _localRenderer!.srcObject = null;
        await _localRenderer!.dispose();
        _localRenderer = null;
      }
      _log('[HOLLOW-VOICE] Video paused (Linux: device kept open)');
      return false;
    }

    // Enable.
    try {
      if (_localVideoStream != null) {
        // Camera already open from a prior enable this call — just resume frames.
        final track = _localVideoStream!.getVideoTracks().firstOrNull;
        if (track != null) {
          track.enabled = true;
          _isVideoEnabled = true;
          // Ensure the sender still exists (it does — we never removed it); make
          // sure the local preview is showing again.
          await _initLocalRenderer();
          _log('[HOLLOW-VOICE] Video resumed (Linux: reused open device)');
          _scheduleVideoStatsProbes('send');
          return true;
        }
        // Track somehow gone — fall through to a fresh capture.
        await _localVideoStream!.dispose();
        _localVideoStream = null;
      }

      // First enable of the call: open the device ONCE.
      final constraints = _videoCaptureConstraints(preferredCameraDeviceId,
          useFacingFallback: false);
      _localVideoStream =
          await navigator.mediaDevices.getUserMedia(constraints);
      _capturedCameraDeviceId = preferredCameraDeviceId;
      final videoTracks = _localVideoStream!.getVideoTracks();
      if (videoTracks.isEmpty) {
        _log('[HOLLOW-VOICE] No camera available');
        await _localVideoStream!.dispose();
        _localVideoStream = null;
        return false;
      }
      final videoTrack = videoTracks.first;
      await _pc!.addTrack(videoTrack, _localVideoStream!);
      _log('[HOLLOW-VOICE] toggleVideo: opened camera + added track (Linux)');
      if (videoTrack.id != null) {
        await _constrainCameraCodecs(videoTrack.id!);
      }
      await applyVideoRung(_videoRung);
      _isVideoEnabled = true;
      await _initLocalRenderer();
      _log('[HOLLOW-VOICE] Video enabled, camera active');
      _scheduleVideoStatsProbes('send');
      return true;
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to capture camera (Linux): $e');
      return false;
    }
  }

  /// Stop every track on [stream], then dispose it. Shared teardown shape
  /// for mic/camera streams — callers wrap the call in their own try/catch
  /// where failures must be swallowed or logged.
  Future<void> _stopTracksAndDispose(MediaStream stream) async {
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }

  /// Build getUserMedia constraints for a camera capture. flutter_webrtc
  /// native (Windows/macOS/Linux) uses 'sourceId' in the optional array —
  /// 'deviceId' is ignored by GetUserVideo(). When [useFacingFallback] is
  /// true and no device id is given, facingMode picks front/back (mobile);
  /// the Linux toggle path omits it entirely.
  Map<String, dynamic> _videoCaptureConstraints(String? deviceId,
      {bool useFacingFallback = true}) {
    final videoConstraints = <String, dynamic>{
      'width': {'ideal': 640},
      'height': {'ideal': 480},
      'frameRate': {'ideal': 30},
    };
    if (deviceId != null) {
      videoConstraints['optional'] = [
        {'sourceId': deviceId}
      ];
    } else if (useFacingFallback) {
      videoConstraints['facingMode'] =
          _useFrontCamera ? 'user' : 'environment';
    }
    return {'audio': false, 'video': videoConstraints};
  }

  /// Local camera facing (true = front). UI reads this to mirror the local
  /// preview only for the front camera.
  bool get useFrontCamera => _useFrontCamera;

  /// Switch front/back camera (mobile). Returns the new facing (true =
  /// front) from the native side — devices with >2 cameras make a blind
  /// toggle drift out of sync.
  Future<bool> switchCamera() async {
    if (!_isVideoEnabled || _localVideoStream == null) return _useFrontCamera;
    final videoTracks = _localVideoStream!.getVideoTracks();
    if (videoTracks.isEmpty) return _useFrontCamera;
    _useFrontCamera = await Helper.switchCamera(videoTracks.first);
    _log('[HOLLOW-VOICE] Camera switched, front=$_useFrontCamera');
    return _useFrontCamera;
  }

  // ---------------------------------------------------------------------------
  // Live device switching (Settings picker changed mid-call)
  // ---------------------------------------------------------------------------

  /// Device id the live audio stream was actually captured from (dedup guard
  /// for duplicate provider listeners firing the same switch twice).
  String? _capturedAudioInputDeviceId;
  /// Device id the live camera stream was actually captured from.
  String? _capturedCameraDeviceId;

  /// Live mid-call microphone switch. Captures a fresh stream from
  /// [deviceId], swaps the PC's audio sender via removeTrack + addTrack
  /// (NEVER replaceTrack — silently fails on Windows libwebrtc), re-binds
  /// SFrame to the new sender, and releases the old mic. Returns true when a
  /// swap happened — the caller MUST send a renegotiation offer afterwards
  /// (same contract as [toggleVideo]).
  Future<bool> setAudioInputDevice(String? deviceId) async {
    preferredAudioInputDeviceId = deviceId;
    if (_pc == null || _localStream == null) return false; // next call uses it
    if (_capturedAudioInputDeviceId == deviceId) return false; // already live
    return _recaptureMic(deviceId);
  }

  /// Shared live mic re-capture — device switch OR an NS-constraint flip
  /// (the AI-noise-suppression toggle changes what getUserMedia must ask
  /// for). Same renegotiation contract as [setAudioInputDevice].
  Future<bool> _recaptureMic(String? deviceId) async {
    // Capture the NEW mic first — if it fails, keep the old one working.
    final newStream = await _captureSwitchMicStream(deviceId);
    if (newStream == null) return false;
    final newTrack = newStream.getAudioTracks().first;
    newTrack.enabled = !_isMuted; // preserve mute state across the swap

    // Swap the PC's audio sender.
    if (!await _swapAudioSender(newTrack, newStream)) return false;

    final oldStream = _localStream;
    _localStream = newStream;
    _capturedAudioInputDeviceId = deviceId;

    // Re-assert the capture chain (process-global, but defensive).
    try {
      await Helper.setCaptureGain(micGain);
      await Helper.setVoiceEnhance(voiceEnhance,
          makeupDb: enhanceMakeupDb, dynamicMode: enhanceDynamic);
    } catch (_) {}

    await _rebindSframeSenderTo(newTrack);

    // Release the old mic.
    if (oldStream != null) {
      try {
        for (final t in oldStream.getAudioTracks()) {
          await t.stop();
        }
        await oldStream.dispose();
      } catch (_) {}
    }
    _log('[HOLLOW-VOICE] Mic switched live to ${deviceId ?? "default"}');
    return true;
  }

  /// Capture a fresh mic stream for a live device switch. Returns null
  /// (after cleanup) when getUserMedia fails or yields no audio track —
  /// the caller keeps the old mic working.
  Future<MediaStream?> _captureSwitchMicStream(String? deviceId) async {
    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      // Legacy NS off while DFN3 owns suppression (unless fallback re-armed).
      'noiseSuppression': _wantWebrtcNs,
      'googNoiseSuppression': _wantWebrtcNs,
      // AGC stays OFF — see _captureLocalAudio.
      'autoGainControl': false,
      'googAutoGainControl': false,
    };
    if (deviceId != null) {
      audioConstraints['optional'] = [
        {'sourceId': deviceId}
      ];
    }
    MediaStream newStream;
    try {
      newStream = await navigator.mediaDevices
          .getUserMedia({'audio': audioConstraints, 'video': false});
    } catch (e) {
      _log('[HOLLOW-VOICE] Mic switch: getUserMedia failed: $e');
      return null;
    }
    if (newStream.getAudioTracks().isEmpty) {
      await newStream.dispose();
      return null;
    }
    return newStream;
  }

  /// Swap the PC's audio sender to [newTrack] via removeTrack + addTrack
  /// (NEVER replaceTrack — silently fails on Windows libwebrtc). On failure
  /// the new capture is released and false is returned.
  Future<bool> _swapAudioSender(
      MediaStreamTrack newTrack, MediaStream newStream) async {
    try {
      final senders = await _pc!.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'audio') {
          await _pc!.removeTrack(s);
          break;
        }
      }
      await _pc!.addTrack(newTrack, newStream);
      return true;
    } catch (e) {
      _log('[HOLLOW-VOICE] Mic switch: sender swap failed: $e');
      try {
        await newTrack.stop();
        await newStream.dispose();
      } catch (_) {}
      return false;
    }
  }

  /// Re-bind SFrame to the NEW audio sender — enableForSender is idempotent
  /// per (peer, kind), so the cryptor bound to the removed sender must be
  /// dropped first or the new track is never encrypted.
  Future<void> _rebindSframeSenderTo(MediaStreamTrack newTrack) async {
    if (_frameCryptor == null ||
        !_frameCryptor!.isEnabled ||
        _activePeerId == null) {
      return;
    }
    try {
      await _frameCryptor!.disableSender(_activePeerId!);
      final senders = await _pc!.getSenders();
      for (final sender in senders) {
        if (sender.track?.id == newTrack.id) {
          await _frameCryptor!.enableForSender(_activePeerId!, sender);
          break;
        }
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] Mic switch: SFrame re-bind failed: $e');
    }
  }

  /// Live mid-call camera device switch (desktop picker). NO-OP on Linux —
  /// the V4L2 device must never be closed mid-call (_toggleVideoLinux);
  /// there the new device applies on the next call. Returns true when a swap
  /// happened — the caller MUST send a renegotiation offer afterwards.
  Future<bool> setCameraDevice(String? deviceId) async {
    preferredCameraDeviceId = deviceId;
    if (_pc == null || !_isVideoEnabled) return false; // next enable uses it
    if (Platform.isLinux) return false;
    if (_capturedCameraDeviceId == deviceId) return false;

    final prev = _videoToggleLock;
    final completer = Completer<void>();
    _videoToggleLock = completer.future;
    try {
      try {
        await prev;
      } catch (_) {}
      return await _switchCameraDeviceLocked(deviceId);
    } finally {
      completer.complete();
    }
  }

  /// Body of [setCameraDevice], run under [_videoToggleLock].
  Future<bool> _switchCameraDeviceLocked(String? deviceId) async {
    if (_pc == null || !_isVideoEnabled) return false;

    // Capture the NEW camera first — on failure keep the old one.
    MediaStream newStream;
    try {
      newStream = await navigator.mediaDevices
          .getUserMedia(_videoCaptureConstraints(deviceId));
    } catch (e) {
      _log('[HOLLOW-VOICE] Camera switch: getUserMedia failed: $e');
      return false;
    }
    final videoTracks = newStream.getVideoTracks();
    if (videoTracks.isEmpty) {
      await newStream.dispose();
      return false;
    }
    final newTrack = videoTracks.first;

    if (!await _swapVideoSender(newTrack, newStream)) return false;

    final oldStream = _localVideoStream;
    _localVideoStream = newStream;
    _capturedCameraDeviceId = deviceId;

    // Rebind the self-preview to the new camera.
    await _initLocalRenderer();

    if (oldStream != null) {
      try {
        await _stopTracksAndDispose(oldStream);
      } catch (_) {}
    }
    _log('[HOLLOW-VOICE] Camera switched live to ${deviceId ?? "default"}');
    return true;
  }

  /// Swap the PC's video sender to [newTrack] via removeTrack + addTrack,
  /// then re-apply the codec constraint. On failure the new capture is
  /// released and false is returned.
  Future<bool> _swapVideoSender(
      MediaStreamTrack newTrack, MediaStream newStream) async {
    try {
      final senders = await _pc!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await _pc!.removeTrack(sender);
          break;
        }
      }
      await _pc!.addTrack(newTrack, newStream);
      // Same VP8-first constraint as every camera enable (iOS answerer).
      if (newTrack.id != null) {
        await _constrainCameraCodecs(newTrack.id!);
      }
      return true;
    } catch (e) {
      _log('[HOLLOW-VOICE] Camera switch: sender swap failed: $e');
      try {
        await newTrack.stop();
        await newStream.dispose();
      } catch (_) {}
      return false;
    }
  }

  /// Live audio output (speaker) switch. selectAudioOutput is process-global
  /// on desktop, so this applies to the call immediately.
  Future<void> setAudioOutputDevice(String? deviceId) async {
    preferredAudioOutputDeviceId = deviceId;
    if (deviceId == null) return; // system default — applies on next call
    try {
      await Helper.selectAudioOutput(deviceId);
      _log('[HOLLOW-VOICE] Audio output switched live to $deviceId');
    } catch (e) {
      _log('[HOLLOW-VOICE] Audio output switch failed: $e');
    }
    // Defensive capture revive (device test 2026-07-17: after a mid-call
    // output switch the REMOTE side stopped hearing this machine's mic —
    // the ADM's playout restart appears to take the capture stream with it
    // on Windows). Re-asserting the recording device forces a
    // StopRecording -> InitRecording -> StartRecording cycle, which is
    // harmless (~100 ms gap) when capture is healthy and revives it when
    // the playout restart killed it. Only possible when a concrete input
    // device is selected — the ADM API can't re-assert "system default".
    if (_localStream != null) {
      final inputId = _capturedAudioInputDeviceId;
      if (inputId != null) {
        try {
          await Helper.selectAudioInput(inputId);
          _log('[HOLLOW-VOICE] Re-asserted audio input after output switch');
        } catch (e) {
          _log('[HOLLOW-VOICE] Input re-assert failed: $e');
        }
      } else {
        _log('[HOLLOW-VOICE] Output switched with default input — '
            'no capture re-assert possible');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Screen sharing
  // ---------------------------------------------------------------------------

  /// End the current call — close PC, stop streams, dispose renderers.
  void startVad() {
    _vadTimer?.cancel();
    _vadTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _pollVad();
    });
  }

  void stopVad() {
    _vadTimer?.cancel();
    _vadTimer = null;
    _prevEnergy.clear();
    _localSpeakingDetector.reset();
    if (_localSpeaking || _remoteSpeaking) {
      _localSpeaking = false;
      _remoteSpeaking = false;
      onSpeakingChanged?.call(false, false);
    }
  }

  /// One-shot diagnostic: issue #37 showed the LOCAL speaking indicator never
  /// lighting on Windows even with a peer connected, which points at getStats
  /// simply not carrying an outgoing audio level on this platform (the spec
  /// puts `audioLevel` on media-source and inbound-rtp; outbound-rtp is NOT
  /// required to have it). Logged once per call so a single test run settles
  /// what is actually available instead of another round of inference.
  bool _vadStatsLogged = false;

  /// Our own speaking state, from the native capture meter (issue #37).
  final _localSpeakingDetector = LocalSpeakingDetector();

  void _logVadStatsOnce(List<StatsReport> stats) {
    if (_vadStatsLogged) return;
    _vadStatsLogged = true;
    final lines = <String>[];
    for (final report in stats) {
      if (report.values['kind'] != 'audio') continue;
      if (report.type != 'media-source' &&
          report.type != 'outbound-rtp' &&
          report.type != 'inbound-rtp') {
        continue;
      }
      lines.add('${report.type}: audioLevel=${report.values['audioLevel']} '
          'totalAudioEnergy=${report.values['totalAudioEnergy']} '
          'keys=${report.values.keys.join(",")}');
    }
    _log('[HOLLOW-VAD-DIAG] '
        '${lines.isEmpty ? "no audio reports" : lines.join(" | ")}');
  }

  Future<void> _pollVad() async {
    if (_pc == null) return;
    bool newRemote = false;

    // LOCAL: the native capture meter, never getStats — see
    // [LocalSpeakingDetector] for why. Muting is handled inside it.
    bool newLocal = await _localSpeakingDetector.poll(muted: _isMuted);

    try {
      final stats = await _pc!.getStats();
      _logVadStatsOnce(stats);
      for (final report in stats) {
        // REMOTE: inbound-rtp genuinely carries audioLevel everywhere.
        if (report.type == 'inbound-rtp' &&
            report.values['kind'] == 'audio') {
          newRemote = _detectSpeech(report.values, 'in-remote');
        }
        // Fallback for a plugin build without the capture meter (an app
        // updated ahead of its native side): the old getStats guess is
        // better than an indicator that never lights.
        if (!_localSpeakingDetector.hasMeter &&
            !newLocal &&
            !_isMuted &&
            (report.type == 'media-source' || report.type == 'outbound-rtp') &&
            report.values['kind'] == 'audio') {
          newLocal = _detectSpeech(report.values, 'out-local');
        }
      }
    } catch (_) {}

    if (_isMuted) newLocal = false;

    if (newLocal != _localSpeaking || newRemote != _remoteSpeaking) {
      _localSpeaking = newLocal;
      _remoteSpeaking = newRemote;
      onSpeakingChanged?.call(_localSpeaking, _remoteSpeaking);
    }
  }

  bool _detectSpeech(Map<dynamic, dynamic> values, String key) {
    final level = (values['audioLevel'] as num?)?.toDouble();
    if (level != null) return level > 0.01;

    final energy =
        (values['totalAudioEnergy'] as num?)?.toDouble() ?? 0.0;
    final prev = _prevEnergy[key] ?? 0.0;
    _prevEnergy[key] = energy;
    final delta = energy - prev;
    return delta > 0.0001;
  }

  /// Tear down ALL media resources of the current session: local mic/camera
  /// streams, renderers, the remote stream, the PeerConnection (close+dispose),
  /// and the SFrame cryptor. Every disposal is awaited and individually guarded
  /// so one failure can't strand the rest (a stranded PC leaks its whole
  /// libwebrtc thread-set). Used by [endCall] AND at the start of
  /// [createOffer]/[handleOffer] so a re-entrant call (e.g. a second inbound
  /// offer during the capture window) can't orphan the prior session's streams.
  ///
  /// [keepCandidatesForCallId] survives the teardown: when this runs at the
  /// START of a new call, the peer may already have trickled candidates for
  /// that call and they must not be swept out with the previous session's.
  Future<void> _teardownMedia({String? keepCandidatesForCallId}) async {
    await _teardownLocalStreams();
    await _teardownRenderersAndRemoteStream();
    await _teardownPeerConnection();
    await _teardownFrameCryptor();

    _discardPendingCandidates('teardown',
        keepCallId: keepCandidatesForCallId);
    _isVideoEnabled = false;
    _remoteDescriptionSet = false;
  }

  /// Stop + dispose the local mic and camera streams (each individually
  /// guarded so one failure can't strand the other).
  Future<void> _teardownLocalStreams() async {
    // Stop local audio.
    if (_localStream != null) {
      try {
        await _stopTracksAndDispose(_localStream!);
      } catch (e) {
        _log('[HOLLOW-VOICE] local audio dispose failed (ignored): $e');
      }
      _localStream = null;
    }

    // Stop local video.
    if (_localVideoStream != null) {
      try {
        await _stopTracksAndDispose(_localVideoStream!);
      } catch (e) {
        _log('[HOLLOW-VOICE] local video dispose failed (ignored): $e');
      }
      _localVideoStream = null;
    }
  }

  /// Dispose both renderers (nulled BEFORE awaiting so a Linux "texture not
  /// found!" throw can't leave a stale half-disposed renderer), then the
  /// remote stream — but only if we synthesized it (libwebrtc owns the
  /// event-provided ones).
  Future<void> _teardownRenderersAndRemoteStream() async {
    final localRenderer = _localRenderer;
    _localRenderer = null;
    if (localRenderer != null) {
      try {
        localRenderer.srcObject = null;
        await localRenderer.dispose();
      } catch (e) {
        _log('[HOLLOW-VOICE] local renderer dispose failed (ignored): $e');
      }
    }
    final remoteRenderer = _remoteRenderer;
    _remoteRenderer = null;
    if (remoteRenderer != null) {
      try {
        remoteRenderer.srcObject = null;
        await remoteRenderer.dispose();
      } catch (e) {
        _log('[HOLLOW-VOICE] remote renderer dispose failed (ignored): $e');
      }
    }
    final remoteStream = _remoteStream;
    final remoteSynthetic = _remoteStreamIsSynthetic;
    _remoteStream = null;
    _remoteStreamIsSynthetic = false;
    if (remoteStream != null && remoteSynthetic) {
      try {
        await remoteStream.dispose();
      } catch (e) {
        _log('[HOLLOW-VOICE] remote stream dispose failed (ignored): $e');
      }
    }
  }

  /// Close the dedicated voice peer connection. close() and dispose() get
  /// SEPARATE guards so a close() throw can't skip the thread-set-freeing
  /// dispose().
  Future<void> _teardownPeerConnection() async {
    final pc = _pc;
    _pc = null;
    if (pc == null) return;
    try {
      await pc.close();
    } catch (e) {
      _log('[HOLLOW-VOICE] pc close failed (ignored): $e');
    }
    try {
      await pc.dispose();
    } catch (e) {
      _log('[HOLLOW-VOICE] pc dispose failed (ignored): $e');
    }
  }

  /// Dispose SFrame encryption.
  Future<void> _teardownFrameCryptor() async {
    try {
      await _frameCryptor?.dispose();
    } catch (e) {
      _log('[HOLLOW-VOICE] frame cryptor dispose failed (ignored): $e');
    }
    _frameCryptor = null;
    _cryptorInited = false;
    _lastSframeHealPing = null;
  }

  Future<void> endCall() async {
    _log('[HOLLOW-VOICE] Ending call with $_activePeerId');
    // Our own `pc.close()` is about to report `closed`; the policy owner reads
    // that as the remote end going away.
    _tearingDown = true;
    stopVad();

    await _teardownMedia();

    _activePeerId = null;
    _activeCallId = null;
    _isMuted = false;
    Helper.setCaptureMuted(false).catchError((_) {});
    _useFrontCamera = true;
  }

  /// Fired (throttled) when a cryptor reports a sustained failure state —
  /// the provider re-applies the call key (heal-lite; the DM key is static,
  /// so failures are almost always wedged bindings or a lost key apply).
  void Function()? onSframeHealNeeded;
  DateTime? _lastSframeHealPing;
  bool _cryptorInited = false;

  /// Public rebind for the heal path: re-bind the receiver cryptor to the
  /// newest inbound audio receiver.
  Future<void> rebindSframeReceivers() => _rebindSframeAudioReceiver(null);

  /// Set the SFrame encryption key for this DM call.
  /// Called by CallNotifier after key exchange via signaling.
  Future<void> setSframeKey(String peerId, Uint8List key) async {
    if (_pc == null) return;

    // Initialize FrameCryptorService if not already done.
    _frameCryptor ??= FrameCryptorService();
    if (!_cryptorInited) {
      _cryptorInited = true;
      await _frameCryptor!.init(sharedKey: true);
      _frameCryptor!.onCryptorStateChanged =
          (participantId, kind, isReceiver, st) {
        if (!FrameCryptorService.isFailureState(st)) return;
        final now = DateTime.now();
        if (_lastSframeHealPing != null &&
            now.difference(_lastSframeHealPing!) < const Duration(seconds: 5)) {
          return;
        }
        _lastSframeHealPing = now;
        _log('[HOLLOW-VOICE] SFrame cryptor failing ($kind '
            '${isReceiver ? 'rx' : 'tx'}: $st) — healing');
        unawaited(rebindSframeReceivers());
        onSframeHealNeeded?.call();
      };
    }
    // rotateKey, not setSharedKey: also updates the key index on any existing
    // cryptors (DM keys are fixed at index 0, but a re-keyed call must never
    // leave a live cryptor pointed at a stale index).
    await _frameCryptor!.rotateKey(0, key);

    // Enable on sender (outgoing audio).
    try {
      final senders = await _pc!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'audio') {
          await _frameCryptor!.enableForSender(peerId, sender);
          break;
        }
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to enable SFrame sender: $e');
    }

    // Enable on receiver (incoming audio).
    try {
      final receivers = await _pc!.getReceivers();
      for (final receiver in receivers) {
        if (receiver.track?.kind == 'audio') {
          await _frameCryptor!.enableForReceiver(peerId, receiver);
          break;
        }
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to enable SFrame receiver: $e');
    }

    _log('[HOLLOW-VOICE] SFrame E2EE enabled for DM call with $peerId');
  }

  /// (Re)bind the SFrame receiver cryptor to the CURRENT inbound audio
  /// receiver. Fired from onTrack: a remote mid-call mic switch arrives as
  /// a NEW audio transceiver via renegotiation, and enableForReceiver is
  /// idempotent per (peer, kind) — the old cryptor must be dropped first or
  /// the new track is never decrypted. Harmless on the initial track (drop
  /// is a no-op / re-binds the same receiver); skipped before key exchange
  /// (setSframeKey binds the receiver itself once the key lands).
  /// The remote ICE username fragment from the last remote description.
  ///
  /// A change in this is the signal that an ICE RESTART happened, and it is
  /// the same signal on BOTH sides: the offerer restarts, and per spec the
  /// answerer must generate fresh credentials to answer a restart offer. So
  /// one check, applied wherever a remote description is set, catches both.
  String? _remoteIceUfrag;

  /// When the last SFrame re-assert ran, to collapse the two triggers that
  /// legitimately arrive together on one recovery.
  DateTime? _lastSframeHeal;

  /// Record the remote ICE credentials from [sdp]. Returns true when they
  /// CHANGED, meaning the transport underneath us was rebuilt.
  bool _noteRemoteIceCredentials(String sdp) {
    final ufrag = iceUfragOf(sdp);
    if (ufrag == null) return false;
    final changed = _remoteIceUfrag != null && _remoteIceUfrag != ufrag;
    _remoteIceUfrag = ufrag;
    return changed;
  }

  /// Re-assert SFrame after the ICE transport was rebuilt underneath us.
  ///
  /// ## The bug this exists for (field-caught 2026-08-27)
  ///
  /// After a long outage the call recovered, the audio came back, and it was
  /// NOISE: the receiving cryptor was gone, so ciphertext went straight to the
  /// decoder. An ICE restart keeps the same SSRC and the same msid, so no new
  /// transceiver appears, `onTrack` never fires, and the one existing rebind
  /// path (`_rebindSframeAudioReceiver`) is never reached. The cryptor was not
  /// FAILING either, it was detached, so `onFrameCryptorStateChanged` reported
  /// nothing and the heal ping never fired. The logs from that call contain
  /// zero SFrame lines after recovery, which is exactly the signature.
  ///
  /// The cryptors are idempotent per (peer, kind), so a plain re-enable is a
  /// no-op on a stale binding. The binding has to be dropped first, which is
  /// why this is a ladder and not a call.
  ///
  /// ## Why this is NOT run on every renegotiation
  ///
  /// [FrameCryptorService.disableSender] disposes the cryptor, so between the
  /// drop and the re-enable there is a window where outbound frames carry no
  /// SFrame layer. For a DM call that window is still inside DTLS-SRTP, but on
  /// the forwarder lane a terminating hop is exactly what SFrame defends
  /// against. A camera toggle or a mic switch does not rebuild the transport
  /// and does not need this, so it is spent only where the alternative is
  /// audio that is already broken.
  Future<void> healSframeAfterTransportRebuild() async {
    final peerId = _activePeerId;
    final fc = _frameCryptor;
    if (peerId == null || fc == null || !fc.isEnabled) return;

    // Two independent triggers reach this (a changed remote ufrag, and a lapse
    // that recovered after we tried restarts), and on a healthy recovery they
    // fire within milliseconds of each other. Re-asserting twice would drop
    // and re-create working cryptors for no reason, which is its own audible
    // blip. Short window on purpose: a genuine SECOND rebuild seconds later
    // still gets its own heal.
    final now = DateTime.now();
    final last = _lastSframeHeal;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      _log('[HOLLOW-VOICE] SFrame re-assert skipped (just did one)');
      return;
    }
    _lastSframeHeal = now;

    _log('[HOLLOW-VOICE] Transport rebuilt — re-asserting SFrame on both '
        'directions');
    try {
      RTCRtpSender? outbound;
      final senders = await _pc?.getSenders() ?? const <RTCRtpSender>[];
      for (final sender in senders) {
        if (sender.track?.kind == 'audio') {
          outbound = sender;
          break;
        }
      }

      // The NEWEST audio receiver: transceivers are in creation order, and
      // dead ones from earlier switches come first.
      RTCRtpReceiver? inbound;
      final receivers = await _pc?.getReceivers() ?? const <RTCRtpReceiver>[];
      for (final r in receivers) {
        if (r.track?.kind == 'audio') inbound = r;
      }

      // WHICH objects we bound to, not just that we bound. A re-assert that
      // reports success and still decrypts to noise is almost always bound to
      // a stale transceiver, and without the ids that is unanswerable from a
      // log. Counts included: more than one live audio receiver means the
      // "newest wins" rule above is picking between real candidates.
      final audioSenders =
          senders.where((x) => x.track?.kind == 'audio').length;
      final audioReceivers =
          receivers.where((x) => x.track?.kind == 'audio').length;
      _log('[HOLLOW-VOICE] SFrame re-assert targets: '
          'senders=$audioSenders receivers=$audioReceivers '
          'sendTrack=${outbound?.track?.id} recvTrack=${inbound?.track?.id} '
          'recvMuted=${inbound?.track?.muted}');

      // One atomic ladder, not five separate mutations: the heal ping and a
      // device switch can both be touching these cryptors at the same moment.
      await fc.reassert(peerId: peerId, sender: outbound, receiver: inbound);
      _log('[HOLLOW-VOICE] SFrame re-asserted after transport rebuild');
    } catch (e) {
      _log('[HOLLOW-VOICE] SFrame re-assert failed: $e');
    }
  }

  Future<void> _rebindSframeAudioReceiver(RTCRtpReceiver? receiver) async {
    final peerId = _activePeerId;
    if (peerId == null) return;
    final fc = _frameCryptor;
    if (fc == null || !fc.isEnabled) return;
    try {
      await fc.disableReceiver(peerId);
      var target = receiver;
      if (target == null) {
        // Fallback: the NEWEST audio receiver on the PC (transceivers are
        // in creation order; dead ones from prior switches come first).
        final receivers = await _pc?.getReceivers() ?? const <RTCRtpReceiver>[];
        for (final r in receivers) {
          if (r.track?.kind == 'audio') target = r;
        }
      }
      if (target == null) return;
      await fc.enableForReceiver(peerId, target);
      _log('[HOLLOW-VOICE] SFrame receiver re-bound to new audio track');
    } catch (e) {
      _log('[HOLLOW-VOICE] SFrame receiver rebind failed: $e');
    }
  }

  Future<void> dispose() async => endCall();

  // ---------------------------------------------------------------------------
  // Private — Peer connection
  // ---------------------------------------------------------------------------

  Future<void> _initPeerConnection(String peerId, String callId) async {
    _tearingDown = false;
    _remoteIceUfrag = null;
    _lastSframeHeal = null;
    if (_pc != null) {
      await _pc!.close();
      await _pc!.dispose();
      _pc = null;
    }
    _discardPendingCandidates('initPeerConnection', keepCallId: callId);
    _remoteDescriptionSet = false;

    _logIceServerConfig();

    final pc = await createPeerConnection(iceServers);
    _pc = pc;

    // ICE candidate handler — send to peer via call signaling.
    pc.onIceCandidate =
        (candidate) => _sendLocalIceCandidate(peerId, callId, candidate);

    // Remote track handler — audio auto-plays, video needs renderer.
    pc.onTrack = (event) => _onRemoteTrack(peerId, event);

    // ICE connection state handler (ICE layer — checking/connected/failed/disconnected).
    pc.onIceConnectionState = (iceState) {
      _log('[HOLLOW-VOICE] ICE connection state: $iceState');
      if (iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        CallSetupTrace.markCurrent(CallSetupTrace.kIceConnected);
      }
    };

    // ICE gathering state handler.
    pc.onIceGatheringState = (gatherState) {
      _log('[HOLLOW-VOICE] ICE gathering state: $gatherState');
      if (gatherState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        CallSetupTrace.markCurrent(CallSetupTrace.kGatherDone);
      }
    };

    // Connection state handler.
    pc.onConnectionState =
        (state) => _onConnectionStateChanged(pc, peerId, state);
  }

  /// Log ICE config for diagnostics.
  void _logIceServerConfig() {
    final servers = (iceServers['iceServers'] as List?) ?? [];
    final hasTurn = servers.any((s) {
      final urls = s['urls'];
      if (urls is String) return urls.startsWith('turn');
      if (urls is List) return urls.any((u) => u.toString().startsWith('turn'));
      return false;
    });
    _log('[HOLLOW-VOICE] Creating PC with ${servers.length} ICE server groups, TURN=$hasTurn');
  }

  /// Body of pc.onIceCandidate — forward a freshly gathered local candidate
  /// to the peer via call signaling.
  void _sendLocalIceCandidate(
      String peerId, String callId, RTCIceCandidate candidate) {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
    // Log candidate type for diagnostics (host/srflx/relay).
    final c = candidate.candidate!;
    final type = c.contains('typ host')
        ? 'host'
        : c.contains('typ srflx')
            ? 'srflx'
            : c.contains('typ relay')
                ? 'relay'
                : 'unknown';
    _log('[HOLLOW-VOICE] ICE candidate: $type mid=${candidate.sdpMid}');
    // First of each type only (the trace keeps the first write) — when the
    // srflx arrives is what decides whether a direct pair could have raced.
    if (type != 'unknown') CallSetupTrace.markCurrent('cand-$type');
    final payload = jsonEncode({
      'call_id': callId,
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
    // .catchError, not try/catch: fire-and-forget — a sync try/catch around
    // the un-awaited Future catches nothing. Safe to swallow: ICE candidates
    // are best-effort (the connection retries/renegotiates without this one).
    network_api.callSendSignal(
      peerId: peerId,
      signalType: 'ice',
      payload: payload,
    ).catchError((_) {});
  }

  /// Body of pc.onTrack — audio auto-plays, video needs a renderer.
  void _onRemoteTrack(String peerId, RTCTrackEvent event) {
    _log('[HOLLOW-VOICE] Remote track: ${event.track.kind} '
        'id=${event.track.id} streams=${event.streams.length}');

    if (event.track.kind == 'video') {
      _handleRemoteVideoTrack(peerId, event);
    } else if (event.track.kind == 'audio') {
      // Audio auto-plays (no renderer), but a remote mid-call mic switch
      // lands as a NEW transceiver — the SFrame decryptor is still bound
      // to the dead receiver, so without a rebind the fresh track plays
      // as ciphertext gibberish. No-op before the key exchange.
      unawaited(_rebindSframeAudioReceiver(event.receiver));
    }
  }

  /// Body of pc.onConnectionState.
  ///
  /// Reports what happened and decides nothing. Every state, `disconnected`
  /// included, is forwarded to [onTransportState] untouched.
  void _onConnectionStateChanged(RTCPeerConnection pc, String peerId,
      RTCPeerConnectionState state) {
    _log('[HOLLOW-VOICE] Connection state: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      // Mark BEFORE the callback: the provider finishes the trace there.
      CallSetupTrace.markCurrent(CallSetupTrace.kConnected);
      onConnected?.call(peerId);
      _logIceRoute(pc, peerId);
    }
    if (_tearingDown) return;
    onTransportState?.call(state);
  }

  /// Restart ICE on the live call, so the next renegotiation offer carries
  /// fresh credentials and re-runs the connectivity checks.
  ///
  /// Make-before-break by construction: media keeps flowing on the existing
  /// candidate pair until the new one connects, so a restart fired at a link
  /// that was about to heal on its own costs nothing but one offer.
  ///
  /// The caller must follow this with a renegotiation offer; see
  /// `restartIceOn` in `ice_repair.dart` for why it is `restartIce()` and not
  /// an `iceRestart` constraint on `createOffer`.
  Future<bool> restartIce() async {
    final pc = _pc;
    if (pc == null) return false;
    return restartIceOn(pc);
  }

  /// Post-connect diagnostic: log which ICE route (TURN / STUN / LAN / P2P)
  /// the succeeded candidate pair took.
  Future<void> _logIceRoute(RTCPeerConnection pc, String peerId) async {
    final route = await probeIceRoute(() => pc);
    _log(route == null
        ? '[HOLLOW-VOICE] ICE route to $peerId: no succeeded candidate pair found'
        : '[HOLLOW-VOICE] ICE route to $peerId: $route');
  }

  // ---------------------------------------------------------------------------
  // Private — Audio
  // ---------------------------------------------------------------------------

  /// Capture microphone audio into [_localStream]. Called BEFORE creating the
  /// peer connection so that getUserMedia latency (100-500 ms on Windows)
  /// doesn't eat into the ICE gathering window.
  Future<void> _captureLocalAudio() async {
    // AI NS (DFN3): kick the engine (first enable = background model load)
    // and decide the WebRTC-NS fallback BEFORE building constraints — the
    // native bail/format flags are latched, so a device that already proved
    // it can't run DFN keeps legacy NS from the very first frame.
    await _syncNoiseSuppressAiEngine();
    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      // Legacy NS off while DFN3 owns suppression (unless fallback re-armed).
      'noiseSuppression': _wantWebrtcNs,
      'googNoiseSuppression': _wantWebrtcNs,
      // AGC OFF: WebRTC's AGC targets a conservative ~-18 dBFS and, on desktop,
      // rides the OS mic slider DOWN to hold it — fighting (and beating) our
      // post-APM Voice Enhancement chain's makeup gain, which is why the mic is
      // "quiet no matter what" and boosting distorts. We own loudness in the
      // enhancement chain instead (keep AEC+NS). Reaches the native APM via the
      // RTCAudioOptions plumbing in flutter_media_stream.cc (desktop) /
      // GetUserMediaImpl (Android, under 'optional'); iOS already forces APM-AGC
      // off and uses Apple VPIO — do NOT bypass that. See
      // project_voice_agc_loudness_rvox.
      'autoGainControl': false,
      'googAutoGainControl': false,
    };
    // flutter_webrtc on Windows uses 'sourceId' for input device selection
    // (not 'deviceId' — that selects output devices in GetUserAudio).
    if (preferredAudioInputDeviceId != null) {
      audioConstraints['optional'] = [
        {'sourceId': preferredAudioInputDeviceId}
      ];
      _log('[HOLLOW-VOICE] Requesting input device: $preferredAudioInputDeviceId');
    }

    final constraints = {
      'audio': audioConstraints,
      'video': false,
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      _capturedAudioInputDeviceId = preferredAudioInputDeviceId;
      final audioTracks = _localStream!.getAudioTracks();
      _log('[HOLLOW-VOICE] Got local audio, '
          'tracks: ${audioTracks.length}'
          '${audioTracks.isNotEmpty ? ", label=${audioTracks.first.label}" : ""}');

      // Apply mic gain via the native post-APM capture processor (makeup
      // gain + -3 dBFS limiter). Process-global, so always set it — at 1.0
      // it's transparent. NOT setVolume(): that only scales remote tracks.
      try {
        await Helper.setCaptureGain(micGain);
        await Helper.setVoiceEnhance(voiceEnhance,
            makeupDb: enhanceMakeupDb, dynamicMode: enhanceDynamic);
        _log('[HOLLOW-VOICE] Applied capture gain: ${micGain.toStringAsFixed(2)} '
            'enhance=$voiceEnhance makeup=${enhanceMakeupDb.toStringAsFixed(1)}dB '
            'dynamic=$enhanceDynamic');
      } catch (e) {
        _log('[HOLLOW-VOICE] Failed to apply capture gain: $e');
      }

      // NOTE: do NOT bypass Apple's Voice-Processing IO here (tried
      // 2026-07-02 to recover its ~6-10 dB playback attenuation): the bypass
      // kills Apple's hardware AEC → echo on every route, and on the
      // loudspeaker a feedback howl (loud/distorted/bass-boosted mic) that
      // persists after toggling back. The sender-side enhancement chain
      // already delivers hot audio, so VPIO's attenuation is affordable.

      // Apply preferred output device if set.
      if (preferredAudioOutputDeviceId != null) {
        try {
          await Helper.selectAudioOutput(preferredAudioOutputDeviceId!);
          _log('[HOLLOW-VOICE] Audio output set to $preferredAudioOutputDeviceId');
        } catch (e) {
          _log('[HOLLOW-VOICE] Failed to set audio output: $e');
        }
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to get microphone: $e');
      rethrow;
    }
  }

  Future<void> updateMicGain(double gain) async {
    micGain = gain;
    // Live mid-call update — native processor reads the new gain atomically.
    // Process-global, so this works even before/without a local stream.
    await Helper.setCaptureGain(gain);
    _log('[HOLLOW-VOICE] Updated capture gain: ${gain.toStringAsFixed(2)}');
  }

  Future<void> updateVoiceEnhance(bool enabled) async {
    voiceEnhance = enabled;
    // Live mid-call A/B toggle — same process-global atomic as the gain.
    await Helper.setVoiceEnhance(enabled,
        makeupDb: enhanceMakeupDb, dynamicMode: enhanceDynamic);
    _log('[HOLLOW-VOICE] Updated voice enhance: $enabled');
  }

  Future<void> updateVoiceEnhanceStrength(double makeupDb) async {
    enhanceMakeupDb = makeupDb;
    await Helper.setVoiceEnhance(voiceEnhance,
        makeupDb: makeupDb, dynamicMode: enhanceDynamic);
    _log('[HOLLOW-VOICE] Updated voice enhance strength: '
        '${makeupDb.toStringAsFixed(1)}dB');
  }

  Future<void> updateVoiceEnhanceDynamic(bool enabled) async {
    enhanceDynamic = enabled;
    await Helper.setVoiceEnhance(voiceEnhance,
        makeupDb: enhanceMakeupDb, dynamicMode: enabled);
    _log('[HOLLOW-VOICE] Updated voice enhance dynamic: $enabled');
  }

  /// Toggle AI noise suppression live. Returns true when the mic was
  /// re-captured (the WebRTC-NS constraint flipped with it) — the caller
  /// MUST send a renegotiation offer, same contract as
  /// [setAudioInputDevice].
  Future<bool> updateNoiseSuppressAi(bool enabled) async {
    noiseSuppressAi = enabled;
    _dfnFallbackNsOn = false;
    await _syncNoiseSuppressAiEngine();
    _log('[HOLLOW-VOICE] Updated AI noise suppression: $enabled');
    if (_pc == null || _localStream == null) return false;
    return _recaptureMic(_capturedAudioInputDeviceId);
  }

  /// Switch the AI-NS engine (Helper.nsEngineRnnoise / nsEngineDfn3). The
  /// native side swaps the engine handle in place — no constraint flip, no
  /// re-capture, no renegotiation — so this is safe mid-call. Clears the
  /// fallback latch (the new engine deserves a fresh verdict); the caller
  /// should schedule [reconcileNoiseSuppressAi] like after an enable.
  Future<void> updateNoiseSuppressEngine(int engine) async {
    noiseSuppressEngine = engine;
    if (!noiseSuppressAi) return;
    _dfnFallbackNsOn = false;
    await _syncNoiseSuppressAiEngine();
    _log('[HOLLOW-VOICE] Updated AI-NS engine: $engine');
  }

  /// Post-enable safety net (schedule a few seconds after enabling): if the
  /// engine reports it cannot run here while legacy NS is off, re-arm
  /// WebRTC NS and re-capture — a call must never sit with NO suppression.
  /// Returns true when the caller must renegotiate.
  Future<bool> reconcileNoiseSuppressAi() async {
    if (!noiseSuppressAi || _dfnFallbackNsOn) return false;
    Map<String, dynamic> st;
    try {
      st = await Helper.getNoiseSuppressAiActive();
    } catch (_) {
      return false;
    }
    // ALWAYS log — "silently working" and "silently absent" must never
    // look the same (2026-07-17 field-test lesson). frames > 0 is the
    // proof the engine is denoising.
    _log('[HOLLOW-VOICE] AI-NS reconcile status: $st');
    if (st.isEmpty) return false;
    final cannotRun = st['available'] != true ||
        st['bailed'] == true ||
        st['formatOk'] == false;
    if (!cannotRun) return false;
    _dfnFallbackNsOn = true;
    _log('[HOLLOW-VOICE] DFN cannot run here — falling back to WebRTC NS');
    if (_pc == null || _localStream == null) return false;
    return _recaptureMic(_capturedAudioInputDeviceId);
  }

  /// Push the AI-NS preference into the native engine and refresh the
  /// fallback decision from the engine's latched status flags (a device
  /// that already bailed keeps legacy NS from the first frame).
  Future<void> _syncNoiseSuppressAiEngine() async {
    try {
      await Helper.setNoiseSuppressAi(noiseSuppressAi,
          engine: noiseSuppressEngine);
      if (noiseSuppressAi) {
        final st = await Helper.getNoiseSuppressAiActive();
        _dfnFallbackNsOn = st.isNotEmpty &&
            (st['available'] != true ||
                st['bailed'] == true ||
                st['formatOk'] == false);
        _log('[HOLLOW-VOICE] AI-NS engine status at capture: $st '
            '(webrtcNsFallback=$_dfnFallbackNsOn)');
      } else {
        _dfnFallbackNsOn = false;
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] AI-NS engine sync failed: $e');
    }
  }

  /// Add pre-captured audio tracks to the peer connection (synchronous aside
  /// from the addTrack FFI call). Called immediately after _initPeerConnection.
  void _addLocalAudioTracks() {
    if (_localStream == null || _pc == null) return;
    for (final track in _localStream!.getAudioTracks()) {
      _pc!.addTrack(track, _localStream!);
    }
  }

  // ---------------------------------------------------------------------------
  // Private — Video
  // ---------------------------------------------------------------------------

  /// Capture camera video into [_localVideoStream]. Called BEFORE creating the
  /// peer connection (same pre-capture pattern as audio). Only used for the
  /// initial call setup — mid-call camera enable goes through [toggleVideo].
  Future<void> _captureLocalVideo() async {
    _log('[HOLLOW-VOICE] Capturing camera (front=$_useFrontCamera, '
        'preferred=${preferredCameraDeviceId ?? "default"})');
    final constraints = _videoCaptureConstraints(preferredCameraDeviceId);

    try {
      _localVideoStream = await navigator.mediaDevices.getUserMedia(constraints);
      _capturedCameraDeviceId = preferredCameraDeviceId;
      final videoTracks = _localVideoStream!.getVideoTracks();
      if (videoTracks.isEmpty) {
        _log('[HOLLOW-VOICE] No video tracks — camera not available');
        await _localVideoStream!.dispose();
        _localVideoStream = null;
        return;
      }
      _log('[HOLLOW-VOICE] Got camera track: ${videoTracks.first.id}');
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to capture camera: $e');
    }
  }

  /// Add pre-captured video tracks to the peer connection. Called immediately
  /// after _initPeerConnection + _addLocalAudioTracks, BEFORE the offer is
  /// created so the codec constraint shapes the initial m-line too.
  Future<void> _addLocalVideoTracks() async {
    if (_localVideoStream == null || _pc == null) return;
    for (final track in _localVideoStream!.getVideoTracks()) {
      await _pc!.addTrack(track, _localVideoStream!);
      if (track.id != null) {
        await _constrainCameraCodecs(track.id!);
      }
    }
    _log('[HOLLOW-VOICE] Added video track via addTrack');
  }

  Future<void> _handleRemoteVideoTrack(
      String peerId, RTCTrackEvent event) async {
    // Stash the OLD renderer/stream so we can dispose them AFTER the new
    // renderer is built. This way a dispose failure on the old (e.g.
    // libwebrtc already cleaned up the event-owned stream during the
    // renegotiation that triggered this onTrack) doesn't trash the new
    // renderer that we still need.
    final oldRenderer = _remoteRenderer;
    final oldStream = _remoteStream;
    final oldWasSynthetic = _remoteStreamIsSynthetic;

    try {
      // Pick the new stream — prefer the event-provided one (libwebrtc owns
      // it, we must NOT dispose it), fall back to a synthetic one if the
      // event came with streams=0 (Windows/libwebrtc renegotiation quirk).
      MediaStream newStream;
      bool newIsSynthetic;
      if (event.streams.isNotEmpty) {
        newStream = event.streams.first;
        newIsSynthetic = false;
        _log('[HOLLOW-VOICE] Using stream from onTrack event '
            '(streams=${event.streams.length})');
      } else {
        _log('[HOLLOW-VOICE] onTrack fired with streams=0, creating '
            'synthetic stream');
        newStream =
            await createLocalMediaStream('remote-video-${event.track.id}');
        await newStream.addTrack(event.track);
        newIsSynthetic = true;
      }

      // Build the new renderer.
      final newRenderer = RTCVideoRenderer();
      await newRenderer.initialize();
      newRenderer.srcObject = newStream;
      _log('[HOLLOW-VOICE] Remote video renderer initialized, '
          'track=${event.track.id}, stream=${newStream.id}');

      // Commit the new state BEFORE attempting to dispose the old, so even
      // if the dispose throws we still have a working renderer.
      _remoteRenderer = newRenderer;
      _remoteStream = newStream;
      _remoteStreamIsSynthetic = newIsSynthetic;

      // Best-effort dispose of the old renderer/stream.
      await _disposeReplacedRemoteMedia(
          oldRenderer, oldStream, oldWasSynthetic);

      // Slight delay to ensure renderer is ready for RTCVideoView, then
      // notify the UI.
      await Future.delayed(const Duration(milliseconds: 100));
      onRemoteVideoTrack?.call(peerId);
      _scheduleVideoStatsProbes('recv');

      _scheduleRendererReassert(newRenderer, newStream);
    } catch (e) {
      _log('[HOLLOW-VOICE] ERROR handling remote video track: $e');
      // Don't trash existing state on error — the previous renderer may
      // still be usable. Just log and bail.
    }
  }

  /// Best-effort dispose of the previous remote renderer/stream AFTER the
  /// new one is committed. Wrapped in try/catch because libwebrtc may have
  /// already cleaned up the underlying MediaStream during renegotiation.
  /// Only synthetic streams are disposed — streams from onTrack events are
  /// owned by libwebrtc and disposing them throws "not found".
  Future<void> _disposeReplacedRemoteMedia(RTCVideoRenderer? oldRenderer,
      MediaStream? oldStream, bool oldWasSynthetic) async {
    if (oldRenderer != null) {
      try {
        oldRenderer.srcObject = null;
        await oldRenderer.dispose();
      } catch (e) {
        _log('[HOLLOW-VOICE] Old renderer dispose failed (non-fatal): $e');
      }
    }
    if (oldStream != null && oldWasSynthetic) {
      try {
        await oldStream.dispose();
      } catch (e) {
        _log('[HOLLOW-VOICE] Old synthetic stream dispose failed '
            '(non-fatal): $e');
      }
    }
  }

  /// Re-assert the native track binding: on iOS the first srcObject bind
  /// can race the native stream's track-list population — Dart-side
  /// srcObject is set and frames decode, but videoRendererSetSrcObject
  /// found videoTracks empty and the renderer silently stays trackless
  /// (black) until a NEW renderer binds on the next toggle. Re-setting
  /// srcObject re-runs the native lookup; it's idempotent when the first
  /// bind worked. renderer.value tells us whether frames ever reached the
  /// texture (width/height stay 0 + renderVideo=false when they didn't).
  void _scheduleRendererReassert(
      RTCVideoRenderer newRenderer, MediaStream newStream) {
    for (final d in const [
      Duration(milliseconds: 400),
      Duration(milliseconds: 1200),
    ]) {
      Future.delayed(d, () {
        if (_remoteRenderer != newRenderer || _remoteStream != newStream) {
          return; // superseded by a newer track
        }
        _log('[HOLLOW-VOICE] Remote renderer value before re-assert: '
            '${newRenderer.value}');
        try {
          newRenderer.srcObject = newStream;
        } catch (e) {
          _log('[HOLLOW-VOICE] Renderer binding re-assert failed: $e');
        }
      });
    }
  }

  Future<void> _initLocalRenderer() async {
    if (_localRenderer != null) {
      _localRenderer!.srcObject = null;
      await _localRenderer!.dispose();
    }
    _localRenderer = RTCVideoRenderer();
    await _localRenderer!.initialize();
    _localRenderer!.srcObject = _localVideoStream;
    _log('[HOLLOW-VOICE] Local video renderer initialized');
  }

  // _initRemoteRenderer is inlined into _handleRemoteVideoTrack above.

  // ---------------------------------------------------------------------------
  // Private — Helpers
  // ---------------------------------------------------------------------------

  /// Drop queued candidates that do NOT belong to [keepCallId], saying so
  /// when there were any. A null [keepCallId] drops everything (call over).
  ///
  /// Dropping a candidate for the call currently being set up is a real loss,
  /// not bookkeeping: the peer sends each candidate exactly once, so a
  /// discarded one is gone for the lifetime of the call and the connection has
  /// to survive on whatever travels the other way. That is why this is keyed
  /// rather than a blanket clear, and why it marks the setup trace.
  void _discardPendingCandidates(String where, {String? keepCallId}) {
    final dropped = _pendingCandidates.discardExcept(keepCallId);
    if (dropped == 0) return;
    _log('[HOLLOW-VOICE] Discarding $dropped queued ICE candidate(s) at $where');
    CallSetupTrace.markCurrent(CallSetupTrace.kCandDropped);
  }

  /// Hand the active call's queued candidates to the peer connection.
  ///
  /// Only the active call's: an entry for any other call is stale by
  /// definition and libwebrtc would reject it against these ICE credentials.
  Future<void> _flushPendingCandidates() async {
    final callId = _activeCallId;
    if (_pc == null || callId == null) return;
    final ready = _pendingCandidates.take(callId);
    if (ready.isEmpty) return;
    _log('[HOLLOW-VOICE] Flushing ${ready.length} pending ICE candidates');
    for (final candidate in ready) {
      try {
        await _pc!.addCandidate(candidate);
      } catch (e) {
        _log('[HOLLOW-VOICE] Failed to add queued ICE candidate: $e');
      }
    }
  }

  /// Dump key SDP lines for debugging.
  /// Munge the Opus fmtp line in the SDP to set bitrate and stereo params.
  /// This controls the actual audio quality sent over the wire.
  String _mungeOpusParams(String sdp) {
    // Find the Opus payload type from a=rtpmap lines.
    final opusPt = _findOpusPayloadType(sdp);
    if (opusPt == null) return sdp; // No Opus found, return as-is.

    // Build the desired fmtp params.
    final params = <String>[
      'minptime=10',
      'useinbandfec=1',
      'maxaveragebitrate=$opusBitrate',
      if (opusStereo) 'stereo=1',
      if (opusStereo) 'sprop-stereo=1',
    ];

    _log('[HOLLOW-VOICE] Opus SDP munge: PT=$opusPt '
        'bitrate=$opusBitrate stereo=$opusStereo');

    // Replace existing fmtp line for Opus, or add one.
    final fmtpPrefix = 'a=fmtp:$opusPt ';
    final lines = sdp.split('\r\n');
    final result = <String>[];
    bool replaced = false;
    for (final line in lines) {
      if (line.startsWith(fmtpPrefix)) {
        result.add('$fmtpPrefix${params.join(';')}');
        replaced = true;
      } else {
        result.add(line);
      }
    }
    // If no existing fmtp line, insert after rtpmap.
    if (!replaced) {
      return _insertFmtpAfterRtpmap(
          result, opusPt, '$fmtpPrefix${params.join(';')}');
    }
    return result.join('\r\n');
  }

  /// Extract the Opus payload type from the SDP's a=rtpmap lines.
  String? _findOpusPayloadType(String sdp) {
    for (final line in sdp.split('\r\n')) {
      final match = RegExp(r'a=rtpmap:(\d+)\s+opus/48000', caseSensitive: false)
          .firstMatch(line);
      if (match != null) {
        return match.group(1);
      }
    }
    return null;
  }

  /// Insert [fmtpLine] directly after the Opus a=rtpmap line and rejoin the
  /// SDP (used when the offer/answer had no fmtp line to replace).
  String _insertFmtpAfterRtpmap(
      List<String> lines, String opusPt, String fmtpLine) {
    final rtpmapLine = 'a=rtpmap:$opusPt ';
    final insertResult = <String>[];
    for (final line in lines) {
      insertResult.add(line);
      if (line.startsWith(rtpmapLine)) {
        insertResult.add(fmtpLine);
      }
    }
    return insertResult.join('\r\n');
  }

  /// Dump video RTP stats — diagnostics for the remote-camera black screen
  /// (desktop → iOS). The sender's outbound probe shows whether frames are
  /// being encoded/sent at all; the receiver's inbound probe shows whether
  /// they arrive and decode. Both land in hollow_debug.log.
  Future<void> _probeVideoStats(String label) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final reports = await pc.getStats();
      for (final r in reports) {
        if (r.type == 'codec') {
          _logVideoCodecStat(label, r);
        } else if (r.type == 'inbound-rtp' || r.type == 'outbound-rtp') {
          _logVideoRtpStat(label, r);
        }
      }
    } catch (e) {
      _log('[HOLLOW-VIDEO-STATS] $label probe failed: $e');
    }
  }

  /// Log a video codec stats report (skips non-video codecs).
  void _logVideoCodecStat(String label, StatsReport r) {
    final v = r.values;
    final mime = (v['mimeType'] ?? '').toString().toLowerCase();
    if (!mime.startsWith('video')) return;
    _log('[HOLLOW-VIDEO-STATS] $label codec id=${r.id}: '
        '${v['mimeType']} payloadType=${v['payloadType']} '
        'fmtp=${v['sdpFmtpLine']}');
  }

  /// Log an inbound-rtp / outbound-rtp video stats report (skips audio).
  void _logVideoRtpStat(String label, StatsReport r) {
    final v = r.values;
    final kind = (v['kind'] ?? v['mediaType'] ?? '').toString();
    if (kind != 'video') return;
    if (r.type == 'inbound-rtp') {
      _log('[HOLLOW-VIDEO-STATS] $label inbound: '
          'bytes=${v['bytesReceived']} packets=${v['packetsReceived']} '
          'framesReceived=${v['framesReceived']} '
          'framesDecoded=${v['framesDecoded']} '
          'framesDropped=${v['framesDropped']} '
          'keyFramesDecoded=${v['keyFramesDecoded']} '
          'pli=${v['pliCount']} nack=${v['nackCount']} '
          'size=${v['frameWidth']}x${v['frameHeight']} '
          'decoder=${v['decoderImplementation']} '
          'codecId=${v['codecId']}');
    } else {
      _log('[HOLLOW-VIDEO-STATS] $label outbound: '
          'bytes=${v['bytesSent']} packets=${v['packetsSent']} '
          'framesEncoded=${v['framesEncoded']} '
          'framesSent=${v['framesSent']} '
          'keyFramesEncoded=${v['keyFramesEncoded']} '
          'size=${v['frameWidth']}x${v['frameHeight']} '
          'encoder=${v['encoderImplementation']} '
          'qualityLimitation=${v['qualityLimitationReason']} '
          'codecId=${v['codecId']}');
    }
  }

  /// Probe a few times after a video track appears so the log shows whether
  /// counters actually advance (one snapshot can't distinguish "never
  /// started" from "stalled").
  void _scheduleVideoStatsProbes(String label) {
    for (final delay in const [
      Duration(seconds: 2),
      Duration(seconds: 6),
      Duration(seconds: 12),
    ]) {
      Future.delayed(delay, () => _probeVideoStats(label));
    }
  }

  void _dumpSdp(String label, String sdp) {
    _log('[HOLLOW-SDP-DUMP] === $label (${sdp.length} bytes) ===');
    for (final line in sdp.split('\r\n')) {
      if (line.startsWith('m=') ||
          line.startsWith('a=sendrecv') ||
          line.startsWith('a=recvonly') ||
          line.startsWith('a=sendonly') ||
          line.startsWith('a=inactive') ||
          line.startsWith('a=ssrc:') ||
          line.startsWith('a=mid:') ||
          line.startsWith('a=msid:')) {
        _log('[HOLLOW-SDP-DUMP] $label: $line');
      }
    }
    _log('[HOLLOW-SDP-DUMP] === END $label ===');
  }

  /// Constrain the transceiver carrying [trackId] to VP8 only (plus
  /// rtx/red/ulpfec infrastructure). VP8 is software (libvpx) on every
  /// platform and is what negotiation picks anyway. Anything stronger in
  /// the offer only exists to break receivers: H.265/AV1 payload types kill
  /// the iOS answerer outright, and even H264/VP9 entries make iOS's FIRST
  /// call fail applying its own answer ("Failed to set local video
  /// description recv parameters") while its hardware codec path is still
  /// cold — first call black, all later calls fine. Also covers the older
  /// macOS issue (Apple H.264 hw profile not decoding on Windows).
  /// The rung the camera sender is currently held to. Kept so a sender built
  /// later in the call (a camera toggle, a device switch, a renegotiation)
  /// inherits the ladder position instead of springing back to full quality on
  /// a link that has already proved it cannot carry it.
  VideoRung _videoRung = kCameraLadder.first;

  VideoRung get videoRung => _videoRung;

  /// Hold the outbound camera to [rung].
  ///
  /// Returns whether the sender accepted it. A live `setParameters` on a
  /// negotiated sender is the one path the spec guarantees, and it is what the
  /// screen share lane has used since 2026-07; the DM camera had no cap at all
  /// until now, which is why a congested uplink took the whole call with it.
  ///
  /// [VideoRung.paused] deactivates the encoding rather than removing the
  /// track: the transceiver, its SFrame cryptor and the negotiated m-line all
  /// stay in place, so coming back up is another `setParameters` rather than a
  /// renegotiation on a link that is already struggling.
  Future<bool> applyVideoRung(VideoRung rung) async {
    _videoRung = rung;
    final pc = _pc;
    if (pc == null) return false;
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) {
          // Nothing negotiated yet. The rung is remembered above and applied
          // by the next call, once the sender has an encoding to hold.
          return false;
        }
        for (final e in encodings) {
          e.active = !rung.isPaused;
          e.maxBitrate = rung.isPaused ? null : rung.maxBitrateBps;
          e.maxFramerate = rung.maxFramerate;
          e.scaleResolutionDownBy = rung.scaleDownBy;
        }
        // Faces stay legible longer when the frame rate goes before the
        // resolution, which is the opposite of what a screen share wants.
        params.degradationPreference =
            RTCDegradationPreference.MAINTAIN_RESOLUTION;
        final ok = await sender.setParameters(params);
        _log('[HOLLOW-VOICE] Video rung "${rung.label}" '
            '(scale=${rung.scaleDownBy} '
            'max=${(rung.maxBitrateBps / 1000).round()}kbps '
            'fps=${rung.maxFramerate}) accepted=$ok');
        return ok;
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] applyVideoRung failed: $e');
    }
    return false;
  }

  Future<void> _constrainCameraCodecs(String trackId) async {
    if (_pc == null) return;
    try {
      final caps = await getRtpSenderCapabilities('video');
      final all = caps.codecs ?? const <RTCRtpCodecCapability>[];
      bool mimeIs(RTCRtpCodecCapability c, String name) =>
          c.mimeType.toLowerCase() == 'video/$name';
      final safe = [
        ...all.where((c) => mimeIs(c, 'vp8')),
        ...all.where(
            (c) => mimeIs(c, 'rtx') || mimeIs(c, 'red') || mimeIs(c, 'ulpfec')),
      ];
      if (safe.isEmpty) return;
      final transceivers = await _pc!.getTransceivers();
      for (final t in transceivers) {
        if (t.sender.track?.id == trackId) {
          await t.setCodecPreferences(safe);
          _log('[HOLLOW-VOICE] Constrained camera codecs for track $trackId '
              '(${safe.length}/${all.length} kept)');
          return;
        }
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] _constrainCameraCodecs failed: $e');
    }
  }
}

/// The ICE username fragment carried by [sdp], or null when there is none.
///
/// A change in this value between two remote descriptions IS an ICE restart:
/// the offerer generates fresh credentials, and per RFC 8445 the answerer must
/// generate fresh ones to answer a restart offer, so the same check works on
/// both sides. That is the signal SFrame has to be re-asserted on, because an
/// ICE restart rebuilds the transport while keeping the SSRC and msid, which
/// means nothing else in the stack announces it.
///
/// Deliberately takes the FIRST occurrence: with BUNDLE every media section
/// carries the same credentials, and without BUNDLE the first section's
/// restart is still a restart.
String? iceUfragOf(String sdp) =>
    RegExp(r'^a=ice-ufrag:(\S+)', multiLine: true).firstMatch(sdp)?.group(1);

/// Default ICE servers (STUN only — used if no config injected).
Map<String, dynamic> _defaultIceServers({String domain = 'relay.anonlisten.com'}) => {
  'iceServers': [
    {'urls': 'stun:$domain:3478'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};
