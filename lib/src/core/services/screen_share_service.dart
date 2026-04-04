import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;

/// Log to hollow_debug.log (visible in release builds).
void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Manages a dedicated RTCPeerConnection for one direction of screen sharing.
///
/// Each screen share direction (local→remote, remote→local) gets its own
/// instance. This avoids the transceiver conflicts that occur when screen
/// sharing reuses the voice call's PC.
///
/// For outgoing (we share our screen): call [createOffer], then [handleAnswer].
/// For incoming (they share their screen): call [handleOffer], renderer appears
/// via [remoteRenderer].
class ScreenShareService {
  final String localPeerId;
  final Map<String, dynamic> iceServers;

  RTCPeerConnection? _pc;
  MediaStream? _screenStream; // Local screen capture (outgoing only)
  RTCVideoRenderer? _remoteRenderer; // Renderer for incoming screen
  MediaStream? _remoteStream;
  Timer? _screenTrackPoller;

  // ICE candidate queue (same pattern as VoiceService).
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  // Callbacks
  void Function(RTCIceCandidate candidate)? onIceCandidate;
  void Function()? onConnected;
  void Function()? onDisconnected;
  void Function()? onRemoteTrackReady;
  void Function()? onScreenShareEnded; // Track ended (window closed)

  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;
  bool get isActive => _pc != null;

  /// Preferred audio output device — set by CallNotifier before handleOffer.
  String? preferredAudioOutputDeviceId;


  ScreenShareService({
    required this.localPeerId,
    required this.iceServers,
  });

  // ---------------------------------------------------------------------------
  // Outgoing: we share our screen to the remote peer.
  // ---------------------------------------------------------------------------

  /// Capture screen, create a fresh RTCPeerConnection, add the screen track,
  /// and return the SDP offer string.
  Future<String> createOffer(
    String sourceId,
    int width,
    int height,
    int fps, {
    bool shareAudio = false,
  }) async {
    _log('[HOLLOW-SCREEN] Creating offer: source=$sourceId '
        '${width}x$height @ ${fps}fps audio=$shareAudio');

    // Capture screen (+ optional system audio).
    await desktopCapturer.getSources(
        types: [SourceType.Screen, SourceType.Window]);

    _screenStream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': sourceId},
        'mandatory': {'frameRate': fps.toDouble()},
      },
      'audio': shareAudio,
    });

    final screenTrack = _screenStream!.getVideoTracks().first;
    _log('[HOLLOW-SCREEN] Got screen track: ${screenTrack.id}');

    // Create PC.
    _pc = await createPeerConnection(iceServers);
    _setupCallbacks();

    // Add screen video track.
    await _pc!.addTrack(screenTrack, _screenStream!);
    _log('[HOLLOW-SCREEN] Added screen video track to PC');

    // Add audio tracks if getDisplayMedia returned any.
    // Note: native flutter_webrtc on Windows does not support audio capture
    // in getDisplayMedia (returns 0 audio tracks). System audio loopback
    // requires a native WASAPI plugin which is not yet implemented.
    // The toggle is kept for future support / other platforms.
    final audioTracks = _screenStream!.getAudioTracks();
    _log('[HOLLOW-SCREEN] getDisplayMedia audio tracks: ${audioTracks.length}');
    if (audioTracks.isNotEmpty) {
      for (final track in audioTracks) {
        await _pc!.addTrack(track, _screenStream!);
      }
      _log('[HOLLOW-SCREEN] Added ${audioTracks.length} audio track(s)');
    } else if (shareAudio) {
      _log('[HOLLOW-SCREEN] Audio sharing requested but not available '
          'on this platform');
    }

    // Generate offer.
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    _log('[HOLLOW-SCREEN] Offer created, SDP length=${offer.sdp?.length}');

    // Poll for track ending (onEnded not wired on native desktop).
    _startTrackPoller();

    return offer.sdp!;
  }

  /// Create an offer using a pre-captured screen stream (for voice channels
  /// where one capture is shared across multiple peer connections).
  /// The caller manages the track poller centrally.
  Future<String> createOfferFromStream(MediaStream stream) async {
    _log('[HOLLOW-SCREEN] Creating offer from shared stream');

    _screenStream = stream;
    final screenTrack = _screenStream!.getVideoTracks().first;
    _log('[HOLLOW-SCREEN] Using shared screen track: ${screenTrack.id}');

    // Create PC.
    _pc = await createPeerConnection(iceServers);
    _setupCallbacks();

    // Add screen video track.
    await _pc!.addTrack(screenTrack, _screenStream!);
    _log('[HOLLOW-SCREEN] Added screen video track to PC');

    // Add audio tracks if available.
    final audioTracks = _screenStream!.getAudioTracks();
    if (audioTracks.isNotEmpty) {
      for (final track in audioTracks) {
        await _pc!.addTrack(track, _screenStream!);
      }
      _log('[HOLLOW-SCREEN] Added ${audioTracks.length} audio track(s)');
    }

    // Generate offer.
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    _log('[HOLLOW-SCREEN] Offer created, SDP length=${offer.sdp?.length}');

    // Note: no track poller here — caller manages centrally for shared stream.
    return offer.sdp!;
  }

  /// Handle the remote peer's SDP answer on our outgoing PC.
  Future<void> handleAnswer(String sdp) async {
    if (_pc == null) {
      _log('[HOLLOW-SCREEN] handleAnswer: no PC');
      return;
    }

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescriptionSet = true;
    _log('[HOLLOW-SCREEN] Remote description set (answer)');
    await _flushPendingCandidates();
  }

  // ---------------------------------------------------------------------------
  // Incoming: the remote peer shares their screen to us.
  // ---------------------------------------------------------------------------

  /// Handle the remote peer's SDP offer. Creates a PC, wires onTrack for the
  /// remote screen renderer, and returns the SDP answer string.
  Future<String> handleOffer(String sdp) async {
    _log('[HOLLOW-SCREEN] Handling incoming screen offer');

    // Create PC.
    _pc = await createPeerConnection(iceServers);
    _setupCallbacks();

    // Wire remote track handler — this is where we get the screen video.
    _pc!.onTrack = (event) {
      _log('[HOLLOW-SCREEN] Remote track: ${event.track.kind} '
          'id=${event.track.id} streams=${event.streams.length}');

      if (event.track.kind == 'video') {
        _handleRemoteVideoTrack(event);
      }
    };

    // Set remote description (the offer).
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();

    // Create answer.
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    // Route audio to the preferred output device (same as voice call).
    if (preferredAudioOutputDeviceId != null) {
      try {
        await Helper.selectAudioOutput(preferredAudioOutputDeviceId!);
        _log('[HOLLOW-SCREEN] Audio output set to '
            '$preferredAudioOutputDeviceId');
      } catch (e) {
        _log('[HOLLOW-SCREEN] Failed to set audio output: $e');
      }
    }

    _log('[HOLLOW-SCREEN] Answer created, SDP length=${answer.sdp?.length}');
    return answer.sdp!;
  }

  // ---------------------------------------------------------------------------
  // ICE
  // ---------------------------------------------------------------------------

  /// Add an ICE candidate. Queued if remote description isn't set yet.
  Future<void> handleIceCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) async {
    final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    if (_remoteDescriptionSet && _pc != null) {
      await _pc!.addCandidate(ice);
    } else {
      _pendingCandidates.add(ice);
    }
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  /// Close the PC, stop tracks, dispose renderers. Safe to call multiple times.
  Future<void> close() async {
    _log('[HOLLOW-SCREEN] Closing screen share service');

    _screenTrackPoller?.cancel();
    _screenTrackPoller = null;

    // Stop local screen capture.
    if (_screenStream != null) {
      for (final track in _screenStream!.getTracks()) {
        await track.stop();
      }
      await _screenStream!.dispose();
      _screenStream = null;
    }

    // Dispose remote renderer.
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
      await _remoteRenderer!.dispose();
      _remoteRenderer = null;
    }
    _remoteStream = null;

    // Close PC.
    if (_pc != null) {
      await _pc!.close();
      await _pc!.dispose();
      _pc = null;
    }

    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
  }

  /// Get available screen/window sources for the picker dialog.
  static Future<List<DesktopCapturerSource>> getDesktopSources() async {
    return desktopCapturer.getSources(
      types: [SourceType.Screen, SourceType.Window],
    );
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _setupCallbacks() {
    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      onIceCandidate?.call(candidate);
    };

    _pc!.onConnectionState = (state) {
      _log('[HOLLOW-SCREEN] Connection state: $state');
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          onConnected?.call();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          onDisconnected?.call();
        default:
          break;
      }
    };
  }

  Future<void> _handleRemoteVideoTrack(RTCTrackEvent event) async {
    if (event.streams.isNotEmpty) {
      _remoteStream = event.streams.first;
      _log('[HOLLOW-SCREEN] Using stream from onTrack '
          '(streams=${event.streams.length})');
    } else {
      // Windows/libwebrtc may fire onTrack with streams=0.
      // Try to find the stream from the PC's remote streams.
      _log('[HOLLOW-SCREEN] onTrack streams=0, checking PC remote streams');
      MediaStream? found;
      if (_pc != null) {
        final remoteStreams = _pc!.getRemoteStreams();
        for (final s in remoteStreams) {
          if (s == null) continue;
          if (s.getVideoTracks().isNotEmpty) {
            found = s;
            _log('[HOLLOW-SCREEN] Found remote stream ${s.id}');
            break;
          }
        }
      }
      if (found != null) {
        _remoteStream = found;
      } else {
        // Last resort: create synthetic stream.
        _remoteStream = await createLocalMediaStream(
          'screen-remote-${event.track.id}',
        );
        _remoteStream!.addTrack(event.track);
        _log('[HOLLOW-SCREEN] Created synthetic stream (last resort)');
      }
    }

    // Create renderer.
    if (_remoteRenderer != null) {
      _remoteRenderer!.srcObject = null;
      await _remoteRenderer!.dispose();
    }

    _remoteRenderer = RTCVideoRenderer();
    await _remoteRenderer!.initialize();
    _remoteRenderer!.srcObject = _remoteStream;
    _log('[HOLLOW-SCREEN] Remote renderer initialized, '
        'track=${event.track.id}, stream=${_remoteStream?.id}');

    await Future.delayed(const Duration(milliseconds: 100));
    onRemoteTrackReady?.call();
  }

  Future<void> _flushPendingCandidates() async {
    if (_pendingCandidates.isNotEmpty) {
      _log('[HOLLOW-SCREEN] Flushing ${_pendingCandidates.length} '
          'pending ICE candidates');
      for (final c in _pendingCandidates) {
        await _pc!.addCandidate(c);
      }
      _pendingCandidates.clear();
    }
  }


  void _startTrackPoller() {
    _screenTrackPoller?.cancel();
    _screenTrackPoller = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        if (_screenStream == null) {
          _screenTrackPoller?.cancel();
          return;
        }
        final tracks = _screenStream!.getVideoTracks();
        if (tracks.isEmpty || !tracks.first.enabled) {
          _log('[HOLLOW-SCREEN] Screen track ended (window closed?)');
          _screenTrackPoller?.cancel();
          onScreenShareEnded?.call();
        }
      },
    );
  }
}
