import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import 'frame_cryptor_service.dart';

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

  /// ICE candidates received before setRemoteDescription is called.
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // -- Video state --
  MediaStream? _localVideoStream;
  bool _isVideoEnabled = false;
  bool _useFrontCamera = true;
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  MediaStream? _remoteStream;
  /// True if `_remoteStream` was created locally via `createLocalMediaStream`
  /// (and we own it). False if it came from `event.streams.first` in onTrack
  /// (libwebrtc owns it — disposing it from Dart throws "stream not found").
  bool _remoteStreamIsSynthetic = false;

  // Callbacks
  void Function(String peerId)? onConnected;
  void Function(String peerId)? onDisconnected;
  void Function(String peerId)? onRemoteVideoTrack;

  /// Preferred device IDs (set by CallNotifier from settings providers).
  String? preferredAudioInputDeviceId;
  String? preferredAudioOutputDeviceId;
  String? preferredCameraDeviceId;

  /// SFrame encryption service for DM call E2EE.
  FrameCryptorService? _frameCryptor;
  FrameCryptorService? get frameCryptor => _frameCryptor;

  VoiceService({required this.localPeerId, Map<String, dynamic>? iceServers})
      : iceServers = iceServers ?? _defaultIceServers;

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
  int opusBitrate = 32000;     // default: 32 kbps (voice)
  bool opusStereo = false;     // default: mono

  // ---------------------------------------------------------------------------
  // SDP: offer / answer / ICE
  // ---------------------------------------------------------------------------

  /// Start mic + camera capture, create RTCPeerConnection, and generate an SDP offer.
  /// Create the initial SDP offer for a DM call. Audio is always captured.
  /// Camera is captured only if [withVideo] is true — for audio-only calls
  /// we do NOT pre-add a video transceiver, matching the voice channel
  /// pattern. When the user later enables video, [toggleVideo] uses
  /// `pc.addTrack` to create a fresh transceiver and renegotiate, which
  /// fires `onTrack` reliably on the remote peer.
  Future<String> createOffer(
    String peerId,
    String callId, {
    bool withVideo = false,
  }) async {
    _log('[HOLLOW-VOICE] Creating offer for $peerId call=$callId withVideo=$withVideo');
    _activePeerId = peerId;
    _activeCallId = callId;

    await _initPeerConnection(peerId, callId);
    await _startLocalAudio();

    // Only capture camera for video calls. Audio-only calls have no video
    // m-line in the initial SDP — the transceiver is added later via
    // toggleVideo()'s addTrack call.
    if (withVideo) {
      final cameraOk = await _startCamera(_pc!);
      if (cameraOk) {
        _isVideoEnabled = true;
        await _initLocalRenderer();
      }
    }

    final offer = await _pc!.createOffer();
    final mungedOffer = _mungeOpusParams(offer.sdp!);
    await _pc!.setLocalDescription(
        RTCSessionDescription(mungedOffer, offer.type));

    _log('[HOLLOW-VOICE] Offer created, SDP length=${mungedOffer.length}');
    _dumpSdp('OFFER-OUT', mungedOffer);
    return mungedOffer;
  }

  /// Handle an incoming SDP offer (answerer side). Creates PC, starts mic,
  /// optionally captures the camera, sets remote description, creates answer.
  /// Camera is only captured when [withVideo] is true (the local user accepted
  /// a video call). If the remote offer has a video m-line but we have no
  /// camera, libwebrtc will produce an `a=recvonly` answer for the video
  /// m-line — that's fine, RTP still flows from sender to receiver.
  Future<String> handleOffer(
    String peerId,
    String callId,
    String sdp, {
    bool withVideo = false,
  }) async {
    _log('[HOLLOW-VOICE] Handling offer from $peerId call=$callId');
    _activePeerId = peerId;
    _activeCallId = callId;

    _dumpSdp('OFFER-IN', sdp);

    await _initPeerConnection(peerId, callId);
    await _startLocalAudio();

    if (withVideo) {
      final cameraOk = await _startCamera(_pc!);
      if (cameraOk) {
        _isVideoEnabled = true;
        await _initLocalRenderer();
      }
    }

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();

    final answer = await _pc!.createAnswer();
    final mungedAnswer = _mungeOpusParams(answer.sdp!);
    await _pc!.setLocalDescription(
        RTCSessionDescription(mungedAnswer, answer.type));

    _log('[HOLLOW-VOICE] Answer created, SDP length=${mungedAnswer.length}');
    _dumpSdp('ANSWER-OUT', mungedAnswer);
    return mungedAnswer;
  }

  /// Create a renegotiation offer on an existing voice PC (e.g., adding/removing video).
  /// Returns the SDP offer string, or null if no PC exists.
  Future<String?> createRenegotiationOffer() async {
    if (_pc == null) {
      _log('[HOLLOW-VOICE] createRenegotiationOffer: no PC');
      return null;
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

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteDescriptionSet = true;

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    _log('[HOLLOW-VOICE] Renegotiation answer created, SDP length=${answer.sdp?.length}');
    _dumpSdp('RENEG-ANSWER-OUT', answer.sdp!);

    // Defer the safety net by a frame so onTrack has a chance to fire and
    // build the renderer. With H4 it should always fire — the safety net
    // only does work if the renderer is still null after the delay (and
    // even then, _checkRemoteVideoTrack is a no-op when a renderer exists).
    Future.delayed(const Duration(milliseconds: 150), _checkRemoteVideoTrack);

    return answer.sdp!;
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
        final track = receiver.track;
        if (track == null || track.kind != 'video') continue;
        // Capture the id once so a later null on the native side doesn't
        // crash logging or string interpolation.
        final trackId = track.id;
        if (trackId == null) continue;

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
          continue;
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
          continue;
        }

        final newRenderer = RTCVideoRenderer();
        await newRenderer.initialize();
        newRenderer.srcObject = newStream;

        // Commit new state first.
        _remoteRenderer = newRenderer;
        _remoteStream = newStream;
        _remoteStreamIsSynthetic = true;

        // Best-effort dispose of the old.
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

        _log('[HOLLOW-VOICE] _checkRemoteVideoTrack: renderer created for '
            'track=$trackId, stream=${_remoteStream?.id}');

        // Give the renderer a moment to settle before notifying UI.
        await Future.delayed(const Duration(milliseconds: 100));

        // Notify UI via the same callback that _handleRemoteVideoTrack uses.
        final activePeerId = _activePeerId;
        if (activePeerId != null) {
          onRemoteVideoTrack?.call(activePeerId);
        }
        return;
      }
    } catch (e) {
      _log('[HOLLOW-VOICE] _checkRemoteVideoTrack error: $e');
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
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();

    // Defer the safety net by a frame so onTrack has a chance to fire first.
    Future.delayed(const Duration(milliseconds: 150), _checkRemoteVideoTrack);
  }

  /// Handle incoming ICE candidate.
  /// Candidates are queued until setRemoteDescription has been called — adding
  /// them before that causes silent rejection by libwebrtc (the native layer
  /// returns an error if there's no remote description yet).
  Future<void> handleIceCandidate(
      String candidate, String? sdpMid, int? sdpMLineIndex) async {
    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    if (!_remoteDescriptionSet || _pc == null) {
      _pendingCandidates.add(iceCandidate);
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

  /// Toggle microphone mute.
  void toggleMute() {
    if (_localStream == null) return;
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) return;
    _isMuted = !_isMuted;
    audioTracks.first.enabled = !_isMuted;
    _log('[HOLLOW-VOICE] Mute toggled: $_isMuted');
  }

  /// Set the volume of the remote peer's audio (how loud you hear them).
  /// volume: 0.0 = silent, 1.0 = normal, 2.0 = 2x.
  Future<void> setRemoteAudioVolume(double volume) async {
    if (_pc == null) return;
    final receivers = await _pc!.getReceivers();
    for (final r in receivers) {
      if (r.track?.kind == 'audio') {
        await Helper.setVolume(volume, r.track!);
        _log('[HOLLOW-VOICE] Remote audio volume set to '
            '${volume.toStringAsFixed(2)}');
        break;
      }
    }
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
  Future<bool> toggleVideo() async {
    if (_pc == null) return false;

    if (_isVideoEnabled) {
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
        for (final t in _localVideoStream!.getTracks()) {
          await t.stop();
        }
        await _localVideoStream!.dispose();
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
    } else {
      // Turn on: capture camera and addTrack a brand new sender. This
      // creates a fresh transceiver with a fresh ssrc — the remote peer
      // gets a new onTrack event and builds a new renderer.
      _log('[HOLLOW-VOICE] Capturing camera for video enable');
      try {
        final videoConstraints = <String, dynamic>{
          'width': {'ideal': 640},
          'height': {'ideal': 480},
          'frameRate': {'ideal': 30},
        };
        // flutter_webrtc native (Windows/macOS/Linux) uses 'sourceId' in
        // optional array — 'deviceId' is ignored by GetUserVideo().
        if (preferredCameraDeviceId != null) {
          videoConstraints['optional'] = [
            {'sourceId': preferredCameraDeviceId}
          ];
        } else {
          videoConstraints['facingMode'] =
              _useFrontCamera ? 'user' : 'environment';
        }
        final constraints = {
          'audio': false,
          'video': videoConstraints,
        };
        // Belt-and-suspenders cleanup of any leaked stream from a
        // previous failed enable.
        if (_localVideoStream != null) {
          for (final t in _localVideoStream!.getTracks()) {
            await t.stop();
          }
          await _localVideoStream!.dispose();
          _localVideoStream = null;
        }
        _localVideoStream =
            await navigator.mediaDevices.getUserMedia(constraints);
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

        _isVideoEnabled = true;
        await _initLocalRenderer();
        _log('[HOLLOW-VOICE] Video enabled, camera active');
      } catch (e) {
        _log('[HOLLOW-VOICE] Failed to capture camera: $e');
        return false;
      }
    }
    return _isVideoEnabled;
  }

  /// Switch front/back camera (mobile).
  Future<void> switchCamera() async {
    if (!_isVideoEnabled || _localVideoStream == null) return;
    final videoTracks = _localVideoStream!.getVideoTracks();
    if (videoTracks.isEmpty) return;
    await Helper.switchCamera(videoTracks.first);
    _useFrontCamera = !_useFrontCamera;
    _log('[HOLLOW-VOICE] Camera switched, front=$_useFrontCamera');
  }

  // ---------------------------------------------------------------------------
  // Screen sharing
  // ---------------------------------------------------------------------------

  /// End the current call — close PC, stop streams, dispose renderers.
  Future<void> endCall() async {
    _log('[HOLLOW-VOICE] Ending call with $_activePeerId');

    // Stop local audio.
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    // Stop local video.
    if (_localVideoStream != null) {
      for (final track in _localVideoStream!.getTracks()) {
        await track.stop();
      }
      await _localVideoStream!.dispose();
      _localVideoStream = null;
    }

    // Dispose renderers.
    if (_localRenderer != null) {
      _localRenderer!.srcObject = null;
      await _localRenderer!.dispose();
      _localRenderer = null;
    }
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
      await _remoteRenderer!.dispose();
      _remoteRenderer = null;
    }
    _remoteStream = null;
    _remoteStreamIsSynthetic = false;

    // Close the dedicated voice peer connection.
    if (_pc != null) {
      await _pc!.close();
      await _pc!.dispose();
      _pc = null;
    }

    // Dispose SFrame encryption.
    await _frameCryptor?.dispose();
    _frameCryptor = null;

    _pendingCandidates.clear();
    _activePeerId = null;
    _activeCallId = null;
    _isMuted = false;
    _isVideoEnabled = false;
    _remoteDescriptionSet = false;
    _useFrontCamera = true;
  }

  /// Set the SFrame encryption key for this DM call.
  /// Called by CallNotifier after key exchange via signaling.
  Future<void> setSframeKey(String peerId, Uint8List key) async {
    if (_pc == null) return;

    // Initialize FrameCryptorService if not already done.
    _frameCryptor ??= FrameCryptorService();
    if (!_frameCryptor!.isEnabled) {
      await _frameCryptor!.init(sharedKey: true);
    }
    await _frameCryptor!.setSharedKey(0, key);

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

  Future<void> dispose() async => endCall();

  // ---------------------------------------------------------------------------
  // Private — Peer connection
  // ---------------------------------------------------------------------------

  Future<void> _initPeerConnection(String peerId, String callId) async {
    if (_pc != null) {
      await _pc!.close();
      await _pc!.dispose();
      _pc = null;
    }
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;

    // Log ICE config for diagnostics.
    final servers = (iceServers['iceServers'] as List?) ?? [];
    final hasTurn = servers.any((s) {
      final urls = s['urls'];
      if (urls is String) return urls.startsWith('turn');
      if (urls is List) return urls.any((u) => u.toString().startsWith('turn'));
      return false;
    });
    _log('[HOLLOW-VOICE] Creating PC with ${servers.length} ICE server groups, TURN=$hasTurn');

    final pc = await createPeerConnection(iceServers);
    _pc = pc;

    // ICE candidate handler — send to peer via call signaling.
    pc.onIceCandidate = (candidate) {
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
      final payload = jsonEncode({
        'call_id': callId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
      network_api.callSendSignal(
        peerId: peerId,
        signalType: 'ice',
        payload: payload,
      );
    };

    // Remote track handler — audio auto-plays, video needs renderer.
    pc.onTrack = (event) {
      _log('[HOLLOW-VOICE] Remote track: ${event.track.kind} '
          'id=${event.track.id} streams=${event.streams.length}');

      if (event.track.kind == 'video') {
        _handleRemoteVideoTrack(peerId, event);
      }
      // Audio tracks are played automatically by libwebrtc — no renderer needed.
    };

    // ICE connection state handler (ICE layer — checking/connected/failed/disconnected).
    pc.onIceConnectionState = (iceState) {
      _log('[HOLLOW-VOICE] ICE connection state: $iceState');
    };

    // ICE gathering state handler.
    pc.onIceGatheringState = (gatherState) {
      _log('[HOLLOW-VOICE] ICE gathering state: $gatherState');
    };

    // Connection state handler.
    pc.onConnectionState = (state) {
      _log('[HOLLOW-VOICE] Connection state: $state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          onConnected?.call(peerId);
          Future.delayed(const Duration(seconds: 1), () async {
            try {
              final stats = await pc.getStats();
              for (final report in stats) {
                if (report.type == 'candidate-pair' && report.values['state'] == 'succeeded') {
                  final localId = report.values['localCandidateId'] as String?;
                  final remoteId = report.values['remoteCandidateId'] as String?;
                  String localType = '?', remoteType = '?', proto = '';
                  for (final r in stats) {
                    if (r.type == 'local-candidate' && r.id == localId) {
                      localType = (r.values['candidateType'] as String?) ?? '?';
                      proto = (r.values['protocol'] as String?) ?? '';
                    }
                    if (r.type == 'remote-candidate' && r.id == remoteId) {
                      remoteType = (r.values['candidateType'] as String?) ?? '?';
                    }
                  }
                  final route = localType == 'relay' || remoteType == 'relay'
                      ? 'TURN (relayed)'
                      : localType == 'srflx' || remoteType == 'srflx'
                          ? 'STUN (direct P2P)'
                          : localType == 'host' && remoteType == 'host'
                              ? 'LAN (direct)'
                              : 'P2P ($localType/$remoteType)';
                  _log('[HOLLOW-VOICE] ICE route to $peerId: $route (local=$localType remote=$remoteType proto=$proto)');
                  return;
                }
              }
              _log('[HOLLOW-VOICE] ICE route to $peerId: no succeeded candidate pair found');
            } catch (e) {
              _log('[HOLLOW-VOICE] ICE route check failed: $e');
            }
          });
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          onDisconnected?.call(peerId);
        default:
          break;
      }
    };
  }

  // ---------------------------------------------------------------------------
  // Private — Audio
  // ---------------------------------------------------------------------------

  Future<void> _startLocalAudio() async {
    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
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
      final audioTracks = _localStream!.getAudioTracks();
      _log('[HOLLOW-VOICE] Got local audio, '
          'tracks: ${audioTracks.length}'
          '${audioTracks.isNotEmpty ? ", label=${audioTracks.first.label}" : ""}');

      for (final track in audioTracks) {
        await _pc!.addTrack(track, _localStream!);
      }

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

  // ---------------------------------------------------------------------------
  // Private — Video
  // ---------------------------------------------------------------------------

  /// Capture the camera and add it as a fresh sender on [pc]. Returns true
  /// on success, false if no camera is available. Only used for the initial
  /// call setup when the user accepts/places a video call — mid-call camera
  /// enable goes through [toggleVideo] which has its own capture path.
  Future<bool> _startCamera(RTCPeerConnection pc) async {
    _log('[HOLLOW-VOICE] Starting camera (front=$_useFrontCamera, '
        'preferred=${preferredCameraDeviceId ?? "default"})');
    final videoConstraints = <String, dynamic>{
      'width': {'ideal': 640},
      'height': {'ideal': 480},
      'frameRate': {'ideal': 30},
    };
    // flutter_webrtc native (Windows/macOS/Linux) uses 'sourceId' in
    // optional array — 'deviceId' is ignored by GetUserVideo().
    if (preferredCameraDeviceId != null) {
      videoConstraints['optional'] = [
        {'sourceId': preferredCameraDeviceId}
      ];
    } else {
      videoConstraints['facingMode'] =
          _useFrontCamera ? 'user' : 'environment';
    }
    final constraints = {
      'audio': false,
      'video': videoConstraints,
    };

    try {
      _localVideoStream = await navigator.mediaDevices.getUserMedia(constraints);
      final videoTracks = _localVideoStream!.getVideoTracks();
      if (videoTracks.isEmpty) {
        _log('[HOLLOW-VOICE] No video tracks — camera not available');
        await _localVideoStream!.dispose();
        _localVideoStream = null;
        return false;
      }
      final videoTrack = videoTracks.first;
      _log('[HOLLOW-VOICE] Got camera track: ${videoTrack.id}');

      await pc.addTrack(videoTrack, _localVideoStream!);
      _log('[HOLLOW-VOICE] Added video track via addTrack');

      // Caller sets _isVideoEnabled — _startCamera only captures and adds.
      return true;
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to start camera: $e');
      // Don't rethrow — camera failure shouldn't break the call.
      // Audio-only call continues.
      return false;
    }
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

      // Best-effort dispose of the old renderer/stream. Wrapped in try/catch
      // because libwebrtc may have already cleaned up the underlying
      // MediaStream during renegotiation.
      if (oldRenderer != null) {
        try {
          oldRenderer.srcObject = null;
          await oldRenderer.dispose();
        } catch (e) {
          _log('[HOLLOW-VOICE] Old renderer dispose failed (non-fatal): $e');
        }
      }
      // Only dispose streams we actually own. Streams from onTrack events
      // are owned by libwebrtc and disposing them throws "not found".
      if (oldStream != null && oldWasSynthetic) {
        try {
          await oldStream.dispose();
        } catch (e) {
          _log('[HOLLOW-VOICE] Old synthetic stream dispose failed '
              '(non-fatal): $e');
        }
      }

      // Slight delay to ensure renderer is ready for RTCVideoView, then
      // notify the UI.
      await Future.delayed(const Duration(milliseconds: 100));
      onRemoteVideoTrack?.call(peerId);
    } catch (e) {
      _log('[HOLLOW-VOICE] ERROR handling remote video track: $e');
      // Don't trash existing state on error — the previous renderer may
      // still be usable. Just log and bail.
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

  Future<void> _flushPendingCandidates() async {
    if (_pendingCandidates.isEmpty || _pc == null) return;
    _log('[HOLLOW-VOICE] Flushing ${_pendingCandidates.length} pending ICE candidates');
    for (final candidate in _pendingCandidates) {
      try {
        await _pc!.addCandidate(candidate);
      } catch (e) {
        _log('[HOLLOW-VOICE] Failed to add queued ICE candidate: $e');
      }
    }
    _pendingCandidates.clear();
  }

  /// Dump key SDP lines for debugging.
  /// Munge the Opus fmtp line in the SDP to set bitrate and stereo params.
  /// This controls the actual audio quality sent over the wire.
  String _mungeOpusParams(String sdp) {
    // Find the Opus payload type from a=rtpmap lines.
    String? opusPt;
    for (final line in sdp.split('\r\n')) {
      final match = RegExp(r'a=rtpmap:(\d+)\s+opus/48000', caseSensitive: false)
          .firstMatch(line);
      if (match != null) {
        opusPt = match.group(1);
        break;
      }
    }
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
      final rtpmapLine = 'a=rtpmap:$opusPt ';
      final insertResult = <String>[];
      for (final line in result) {
        insertResult.add(line);
        if (line.startsWith(rtpmapLine)) {
          insertResult.add('$fmtpPrefix${params.join(';')}');
        }
      }
      return insertResult.join('\r\n');
    }
    return result.join('\r\n');
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
}

/// Default ICE servers (STUN only — used if no config injected).
final _defaultIceServers = {
  'iceServers': [
    {'urls': 'stun:relay.anonlisten.com:3478'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};
