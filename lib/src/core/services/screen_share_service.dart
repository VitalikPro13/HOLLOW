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
  RTCVideoRenderer? _localRenderer; // Self-preview of outgoing screen
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
  RTCVideoRenderer? get localRenderer => _localRenderer;
  RTCPeerConnection? get pc => _pc;
  bool get isActive => _pc != null;

  /// Preferred audio output device — set by CallNotifier before handleOffer.
  String? preferredAudioOutputDeviceId;


  ScreenShareService({
    required this.localPeerId,
    required this.iceServers,
  });

  /// Apply resolution and bitrate cap on the video sender's encoding
  /// parameters. getDisplayMedia captures at native resolution — this
  /// constrains the encoder to downscale before transmitting AND caps
  /// the bitrate so WebRTC's adaptive quality scaler can't ramp back up.
  Future<void> _applyResolutionCap(int maxWidth, int maxHeight) async {
    if (_pc == null) return;
    final senders = await _pc!.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        final params = sender.parameters;
        if (params.encodings == null || params.encodings!.isEmpty) {
          params.encodings = [RTCRtpEncoding()];
        }
        for (final encoding in params.encodings!) {
          final settings = sender.track!.getSettings();
          final captureWidth = settings['width'] as int? ?? 1920;
          final captureHeight = settings['height'] as int? ?? 1080;

          // Downscale if the capture is larger than the target.
          if (captureWidth > maxWidth || captureHeight > maxHeight) {
            final scaleW = captureWidth / maxWidth;
            final scaleH = captureHeight / maxHeight;
            final scale = scaleW > scaleH ? scaleW : scaleH;
            encoding.scaleResolutionDownBy = scale;
            _log('[HOLLOW-SCREEN] Set scaleResolutionDownBy=$scale '
                '(${captureWidth}x$captureHeight -> ${maxWidth}x$maxHeight)');
          }

          // Cap the bitrate to prevent BWE from ramping the quality back
          // up when bandwidth is abundant. Without this, the adaptive
          // quality scaler can override scaleResolutionDownBy.
          // Bitrate tiers (screen share — higher than camera because
          // screen content has sharp edges/text that compress poorly):
          //   360p  →  800 kbps
          //   480p  → 1500 kbps
          //   720p  → 3000 kbps
          //  1080p  → 6000 kbps
          //  1440p  → 9000 kbps
          //  4K     → 15000 kbps
          final pixels = maxWidth * maxHeight;
          final int maxBitrateKbps;
          if (pixels <= 640 * 360) {
            maxBitrateKbps = 800;
          } else if (pixels <= 854 * 480) {
            maxBitrateKbps = 1500;
          } else if (pixels <= 1280 * 720) {
            maxBitrateKbps = 3000;
          } else if (pixels <= 1920 * 1080) {
            maxBitrateKbps = 6000;
          } else if (pixels <= 2560 * 1440) {
            maxBitrateKbps = 9000;
          } else {
            maxBitrateKbps = 15000;
          }
          encoding.maxBitrate = maxBitrateKbps * 1000; // bps
          _log('[HOLLOW-SCREEN] Set maxBitrate=${maxBitrateKbps}kbps '
              'for ${maxWidth}x$maxHeight');
        }
        await sender.setParameters(params);
        break;
      }
    }
  }

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

    // SECURITY (Phase 6.25): Validate stream has video tracks.
    final videoTracks = _screenStream!.getVideoTracks();
    if (videoTracks.isEmpty) {
      _log('[HOLLOW-SCREEN] getDisplayMedia returned no video tracks — aborting');
      await _screenStream!.dispose();
      _screenStream = null;
      throw StateError('Screen capture returned no video tracks');
    }
    final screenTrack = videoTracks.first;
    _log('[HOLLOW-SCREEN] Got screen track: ${screenTrack.id}');

    // Build a local self-preview renderer so the UI can show what we're
    // sharing in the screen share view.
    _localRenderer = RTCVideoRenderer();
    await _localRenderer!.initialize();
    _localRenderer!.srcObject = _screenStream;

    // Create PC.
    _pc = await createPeerConnection(iceServers);
    _setupCallbacks();

    // Add screen video track.
    await _pc!.addTrack(screenTrack, _screenStream!);
    _log('[HOLLOW-SCREEN] Added screen video track to PC');

    // Apply resolution cap on the encoder (getDisplayMedia captures at native res).
    await _applyResolutionCap(width, height);

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
  Future<String> createOfferFromStream(MediaStream stream, {int maxWidth = 1920, int maxHeight = 1080}) async {
    _log('[HOLLOW-SCREEN] Creating offer from shared stream');

    _screenStream = stream;
    final screenTrack = _screenStream!.getVideoTracks().first;
    _log('[HOLLOW-SCREEN] Using shared screen track: ${screenTrack.id}');

    // Build a local self-preview renderer so the UI can show what we're
    // sharing in the screen share view.
    _localRenderer = RTCVideoRenderer();
    await _localRenderer!.initialize();
    _localRenderer!.srcObject = _screenStream;

    // Create PC.
    _pc = await createPeerConnection(iceServers);
    _setupCallbacks();

    // Add screen video track.
    await _pc!.addTrack(screenTrack, _screenStream!);
    _log('[HOLLOW-SCREEN] Added screen video track to PC');

    // Apply resolution cap on the encoder.
    await _applyResolutionCap(maxWidth, maxHeight);

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

    // Dispose local self-preview renderer first (before stream goes away).
    if (_localRenderer != null) {
      _localRenderer!.srcObject = null;
      await _localRenderer!.dispose();
      _localRenderer = null;
    }

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
          final screenPc = _pc;
          if (screenPc != null) {
            Future.delayed(const Duration(seconds: 1), () async {
              try {
                final stats = await screenPc.getStats();
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
                    _log('[HOLLOW-SCREEN] ICE route: $route (local=$localType remote=$remoteType proto=$proto)');
                    return;
                  }
                }
                _log('[HOLLOW-SCREEN] ICE route: no succeeded candidate pair found');
              } catch (e) {
                _log('[HOLLOW-SCREEN] ICE route check failed: $e');
              }
            });
          }
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
