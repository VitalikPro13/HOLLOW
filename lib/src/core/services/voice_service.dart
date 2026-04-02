import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;

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

  // Callbacks
  void Function(String peerId)? onConnected;
  void Function(String peerId)? onDisconnected;
  void Function(String peerId)? onRemoteVideoTrack;

  /// Preferred device IDs (set by CallNotifier from settings providers).
  String? preferredAudioInputDeviceId;
  String? preferredAudioOutputDeviceId;

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
  /// Camera is always captured so the video transceiver is in the initial SDP —
  /// this avoids the streams=0 problem when adding video via renegotiation later.
  /// If [withVideo] is false, the camera track is immediately disabled (no data flows).
  /// Returns the SDP offer string.
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

    // Always capture camera so video m-line is in the initial SDP.
    final cameraOk = await _startCamera(_pc!);
    if (cameraOk) {
      if (withVideo) {
        _isVideoEnabled = true;
        await _initLocalRenderer();
      } else {
        // Audio-only: stop the camera hardware (turns off the light) but keep
        // the transceiver in the SDP. We'll recapture when user enables video.
        _isVideoEnabled = false;
        await _releaseCamera();
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

  /// Handle an incoming SDP offer (answerer side). Creates PC, starts mic + camera,
  /// sets remote description, creates answer. Returns the SDP answer string.
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

    // Always capture camera so video m-line is in the answer SDP.
    final cameraOk = await _startCamera(_pc!);
    if (cameraOk) {
      if (withVideo) {
        _isVideoEnabled = true;
        await _initLocalRenderer();
      } else {
        _isVideoEnabled = false;
        await _releaseCamera();
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
    return answer.sdp!;
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

  /// Toggle camera on/off. Returns the new state.
  /// The video transceiver was set up during call init — toggling recaptures
  /// the camera (turning the light on) or releases it (turning it off).
  /// No SDP renegotiation needed since the transceiver is already in the SDP.
  Future<bool> toggleVideo() async {
    if (_pc == null) return false;

    if (_isVideoEnabled) {
      // Turn off: release camera hardware.
      _isVideoEnabled = false;
      await _releaseCamera();
      if (_localRenderer != null) {
        _localRenderer!.srcObject = null;
        await _localRenderer!.dispose();
        _localRenderer = null;
      }
      _log('[HOLLOW-VOICE] Video disabled, camera released');
    } else {
      // Turn on: recapture camera and replace the sender's null track.
      _log('[HOLLOW-VOICE] Recapturing camera for video enable');
      try {
        final constraints = {
          'audio': false,
          'video': {
            'facingMode': _useFrontCamera ? 'user' : 'environment',
            'width': {'ideal': 640},
            'height': {'ideal': 480},
            'frameRate': {'ideal': 30},
          },
        };
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

        // Replace the sender's null track with the new camera track.
        final senders = await _pc!.getSenders();
        for (final s in senders) {
          if (s.track == null || s.track?.kind == 'video') {
            await s.replaceTrack(videoTrack);
            _log('[HOLLOW-VOICE] Replaced sender track with camera');
            break;
          }
        }

        _isVideoEnabled = true;
        await _initLocalRenderer();
        _log('[HOLLOW-VOICE] Video enabled, camera active');
      } catch (e) {
        _log('[HOLLOW-VOICE] Failed to recapture camera: $e');
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

    // Close the dedicated voice peer connection.
    if (_pc != null) {
      await _pc!.close();
      await _pc!.dispose();
      _pc = null;
    }

    _pendingCandidates.clear();
    _activePeerId = null;
    _activeCallId = null;
    _isMuted = false;
    _isVideoEnabled = false;
    _remoteDescriptionSet = false;
    _useFrontCamera = true;
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

    final pc = await createPeerConnection(iceServers);
    _pc = pc;

    // ICE candidate handler — send to peer via call signaling.
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
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

    // Connection state handler.
    pc.onConnectionState = (state) {
      _log('[HOLLOW-VOICE] Connection state: $state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          onConnected?.call(peerId);
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

  /// Start camera. Returns true if successful, false if no camera available.
  /// When the camera is unavailable, a sendrecv video transceiver is still
  /// added (with null track) so the SDP always has a video m-line — this is
  /// required for screen sharing to work on devices without cameras.
  Future<bool> _startCamera(RTCPeerConnection pc) async {
    _log('[HOLLOW-VOICE] Starting camera (front=$_useFrontCamera)');
    final constraints = {
      'audio': false,
      'video': {
        'facingMode': _useFrontCamera ? 'user' : 'environment',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 30},
      },
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

      // Try to reuse an existing stopped video transceiver.
      bool reused = false;
      final transceivers = await pc.getTransceivers();
      for (final t in transceivers) {
        if (t.receiver.track?.kind == 'video' && t.sender.track == null) {
          await t.sender.replaceTrack(videoTrack);
          await t.setDirection(TransceiverDirection.SendRecv);
          _log('[HOLLOW-VOICE] Reused video transceiver mid=${t.mid}');
          reused = true;
          break;
        }
      }

      if (!reused) {
        await pc.addTrack(videoTrack, _localVideoStream!);
        _log('[HOLLOW-VOICE] Added new video track via addTrack');
      }

      // Don't set _isVideoEnabled here — let the caller control it.
      // _startCamera only captures and adds the track to the PC.
      return true;
    } catch (e) {
      _log('[HOLLOW-VOICE] Failed to start camera: $e');
      // Don't rethrow — camera failure shouldn't break the call.
      // Audio-only call continues.
      return false;
    }
  }

  /// Release camera hardware (stop tracks, dispose stream) without removing
  /// the transceiver from the PC. Turns off the camera light.
  Future<void> _releaseCamera() async {
    if (_localVideoStream == null) return;
    // Replace the sender's track with null — keeps transceiver alive.
    if (_pc != null) {
      final senders = await _pc!.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          await s.replaceTrack(null);
          break;
        }
      }
    }
    // Stop the physical camera.
    for (final track in _localVideoStream!.getVideoTracks()) {
      await track.stop();
    }
    await _localVideoStream!.dispose();
    _localVideoStream = null;
    _log('[HOLLOW-VOICE] Camera released (light off)');
  }

  Future<void> _handleRemoteVideoTrack(
      String peerId, RTCTrackEvent event) async {
    if (event.streams.isNotEmpty) {
      _remoteStream = event.streams.first;
      _log('[HOLLOW-VOICE] Using stream from onTrack event (streams=${event.streams.length})');
    } else {
      // Windows/libwebrtc fires onTrack with streams=0 during renegotiation.
      // Get the stream from the receiver's track instead.
      _log('[HOLLOW-VOICE] onTrack fired with streams=0, getting stream from PC receivers');
      if (_pc != null) {
        final receivers = await _pc!.getReceivers();
        for (final r in receivers) {
          if (r.track?.kind == 'video' && r.track?.id == event.track.id) {
            // Found the receiver — but it doesn't have a stream either.
            // Fall back to creating a MediaStream.
            break;
          }
        }
      }
      _remoteStream = await createLocalMediaStream(
        'remote-video-${event.track.id}',
      );
      _remoteStream!.addTrack(event.track);
      _log('[HOLLOW-VOICE] Created synthetic stream for video track');
    }

    // Initialize renderer — dispose old one first to force RTCVideoView rebuild.
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
      await _remoteRenderer!.dispose();
      _remoteRenderer = null;
    }

    _remoteRenderer = RTCVideoRenderer();
    await _remoteRenderer!.initialize();
    _remoteRenderer!.srcObject = _remoteStream;
    _log('[HOLLOW-VOICE] Remote video renderer initialized, '
        'track=${event.track.id}, stream=${_remoteStream?.id}');

    // Notify UI — slight delay to ensure renderer is ready for RTCVideoView.
    await Future.delayed(const Duration(milliseconds: 100));
    onRemoteVideoTrack?.call(peerId);
  }

  Future<void> _initLocalRenderer() async {
    _localRenderer?.dispose();
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
