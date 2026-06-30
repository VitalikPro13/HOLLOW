import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import 'screen_audio_capturer.dart';
import 'mac_sck_screen_audio_capturer.dart';
import 'macos_version.dart';

/// Method channel exposed by the forked `flutter_webrtc` for the macOS-only
/// system audio Process Tap (see `MacScreenShareAudioTap.m`).
const MethodChannel _kFlutterWebRTCChannel = MethodChannel('FlutterWebRTC.Method');

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
  // Whether THIS service owns _screenStream and must stop+dispose it on close().
  // True for createOffer (we captured it). FALSE for createOfferFromStream:
  // there one capture is SHARED across many per-peer services (voice channels),
  // so the provider owns it — disposing it here would (a) kill the share for
  // every other peer and (b) double-free it (the provider disposes it too),
  // which is the `corrupted size vs prev_size` heap abort on screen-share stop.
  bool _ownsScreenStream = true;
  // Whether _remoteStream was SYNTHESIZED by us (createLocalMediaStream in the
  // onTrack fallback) vs. handed to us by libwebrtc. We may only dispose the
  // ones we synthesized; libwebrtc owns the event-provided streams.
  bool _remoteStreamIsSynthetic = false;
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

  /// True once the macOS system-audio Process Tap has been activated for this
  /// share. Used so we tear it down exactly once on close.
  bool _macSystemAudioActive = false;

  /// Preferred audio output device — set by CallNotifier before handleOffer.
  String? preferredAudioOutputDeviceId;

  // --- Screen audio via out-of-process capturer (Windows) ---
  ScreenAudioCapturer? _screenAudioCapturer;
  // --- Screen audio via ScreenCaptureKit (macOS 13.0–14.1) ---
  MacSckScreenAudioCapturer? _macSckAudioCapturer;


  ScreenShareService({
    required this.localPeerId,
    required this.iceServers,
  });

  /// Apply resolution, framerate, and bitrate caps on the video sender's
  /// encoding parameters. Even though getDisplayMedia now receives width/height
  /// constraints, the desktop capturer may still deliver native-resolution
  /// frames — this enforces the cap at the encoder level as a second layer.
  Future<void> _applyResolutionCap(int maxWidth, int maxHeight, int fps) async {
    if (_pc == null) return;
    final senders = await _pc!.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        final params = sender.parameters;
        if (params.encodings == null || params.encodings!.isEmpty) {
          params.encodings = [RTCRtpEncoding()];
        }

        // Prevent WebRTC's adaptive quality scaler from overriding our
        // resolution cap. "maintain-framerate" tells the encoder to drop
        // resolution (not frames) under bandwidth pressure — and with a
        // tight maxBitrate it can't ramp resolution back up either.
        params.degradationPreference =
            RTCDegradationPreference.MAINTAIN_FRAMERATE;

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

          encoding.maxFramerate = fps;

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
              'maxFramerate=${fps}fps for ${maxWidth}x$maxHeight');
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

    // Idempotent: tear down any prior PC/stream on this service before
    // capturing a new one, so a re-share on the same instance can't strand the
    // old PeerConnection's thread-set.
    if (_pc != null || _screenStream != null || _localRenderer != null) {
      await close();
    }

    // macOS / Android need explicit screen-capture permission before any
    // source enumeration. On macOS this triggers the System Settings →
    // Privacy & Security → Screen & System Audio Recording prompt; the
    // first attempt always returns false, the user grants access in
    // Settings, and the next launch reads granted. Web/Windows/Linux just
    // return true.
    if (Platform.isMacOS) {
      try {
        final granted = await Helper.requestCapturePermission();
        _log('[HOLLOW-SCREEN] macOS screen recording permission: $granted');
        // Debug builds are ad-hoc signed and every rebuild gets a fresh
        // signature, so TCC reports `granted=false` until the user re-grants.
        // We still try the capture: ScreenCaptureKit will surface its own
        // error (and possibly show the system prompt the first time) if
        // access is truly denied — much friendlier than hard-aborting here.
      } catch (e) {
        _log('[HOLLOW-SCREEN] permission probe failed: $e');
      }
    }

    // Capture screen (+ optional system audio).
    await desktopCapturer.getSources(
        types: [SourceType.Screen, SourceType.Window]);

    // macOS system-audio routing:
    //  - 13.0+ : ScreenCaptureKit audio-only -> data channel (0x03), same as
    //    Windows. Started later via startScreenAudioCapture. We deliberately do
    //    NOT use the CoreAudio Process Tap (14.2+) — it injects audio into the
    //    system default input, which the CoreAudio ADM (our voice-call ADM on
    //    macOS) doesn't follow, so it fed 0 tracks. The data-channel path is
    //    ADM-independent and uniform across all macOS versions.
    //  - <13.0 : no capture API; the UI locks the toggle off, so shareAudio is
    //    false here anyway.
    // Windows and macOS 13.0+ send audio via the data channel — never request
    // it in getDisplayMedia (the WASAPI/AudioSource path crashes on Windows and
    // isn't available on macOS). The macOS CoreAudio Process Tap is retired (it
    // was ADM-coupled and fed 0 tracks under the CoreAudio ADM).
    final useDataChannelAudio = shareAudio &&
        (Platform.isWindows ||
            (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio));
    final getDisplayAudio = shareAudio && !useDataChannelAudio;

    _screenStream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': sourceId},
        'mandatory': {
          'frameRate': fps.toDouble(),
          'width': width,
          'height': height,
        },
      },
      'audio': getDisplayAudio,
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

    // On macOS prefer VP8 for screen share. Apple's H.264 hardware encoder
    // can emit a profile (e.g. high) that Windows libwebrtc's software
    // decoder fails to render — frames decode to a black image with no
    // error. VP8 has no profile axis and works identically on both ends.
    if (Platform.isMacOS) {
      try {
        final caps = await getRtpSenderCapabilities('video');
        final vp8 = caps.codecs
                ?.where((c) => c.mimeType.toLowerCase().endsWith('vp8'))
                .toList() ??
            [];
        if (vp8.isNotEmpty) {
          final transceivers = await _pc!.getTransceivers();
          for (final t in transceivers) {
            if (t.sender.track?.id == screenTrack.id) {
              // Put VP8 first; keep other codecs as fallback in case the
              // remote peer can't negotiate VP8 for some reason.
              final ordered = [
                ...vp8,
                ...(caps.codecs ?? []).where(
                    (c) => !c.mimeType.toLowerCase().endsWith('vp8')),
              ];
              await t.setCodecPreferences(ordered);
              _log('[HOLLOW-SCREEN] Forced VP8 codec preference on macOS');
              break;
            }
          }
        }
      } catch (e) {
        _log('[HOLLOW-SCREEN] codec preference set failed: $e');
      }
    }

    // Apply resolution cap on the encoder (getDisplayMedia captures at native res).
    await _applyResolutionCap(width, height, fps);

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
  Future<String> createOfferFromStream(MediaStream stream, {int maxWidth = 1920, int maxHeight = 1080, int fps = 60}) async {
    _log('[HOLLOW-SCREEN] Creating offer from shared stream');

    // Idempotent: if this service already holds a PC (re-fired offer on
    // reconnect), tear the old one down before building a new one so its
    // libwebrtc thread-set can't leak.
    if (_pc != null || _localRenderer != null || _remoteRenderer != null) {
      await close();
    }

    // The caller owns this shared capture stream — do NOT dispose it on close().
    _ownsScreenStream = false;
    _screenStream = stream;

    try {
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
      await _applyResolutionCap(maxWidth, maxHeight, fps);

      // Add audio tracks if available (macOS Process Tap audio goes via tracks).
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
    } catch (e) {
      // Dispose the partially-built PC/renderer (NOT the shared stream — we
      // don't own it) before propagating.
      _log('[HOLLOW-SCREEN] createOfferFromStream failed, tearing down: $e');
      await close();
      rethrow;
    }
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

    // Idempotent: a re-fired offer for the same peer must not strand the prior
    // PC on this instance.
    if (_pc != null) {
      await close();
    }

    try {
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
    } catch (e) {
      // A throw here (e.g. unsupported remote SDP codec) leaves a live PC +
      // its thread-set stranded. Dispose before propagating.
      _log('[HOLLOW-SCREEN] handleOffer failed, tearing down: $e');
      await close();
      rethrow;
    }
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
  // Screen audio capture (Windows data-channel streaming)
  // ---------------------------------------------------------------------------

  /// Start out-of-process system-audio capture + Opus encoding. Encoded packets
  /// are delivered to [onPacket] for sending over the data channel (0x03).
  ///
  /// - Windows: WASAPI loopback exe (`--mode pipe`). A separate process avoids
  ///   libwebrtc's AudioDeviceModule interfering with the WASAPI capture.
  /// - macOS 13.0–14.1: ScreenCaptureKit audio-only capture -> exe `--mode
  ///   encode`. (macOS 14.2+ uses the Process Tap -> WebRTC track in createOffer,
  ///   never this method.)
  /// - macOS < 13.0 / other: no-op (no capture API; the toggle is locked off
  ///   in the UI for those versions).
  Future<void> startScreenAudioCapture(
    String streamId, {
    String mode = 'system',
    int pid = 0,
    int windowHwnd = 0,
    int excludePid = 0,
    required void Function(Uint8List packet) onPacket,
  }) async {
    if (Platform.isWindows) {
      if (_screenAudioCapturer?.isActive == true) return;
      _log('[HOLLOW-AU-SCREEN] Starting WASAPI capture '
          '(pid=$pid hwnd=$windowHwnd excludePid=$excludePid)');
      _screenAudioCapturer = ScreenAudioCapturer();
      final ok = await _screenAudioCapturer!.start(
          pid: pid,
          windowHwnd: windowHwnd,
          excludePid: excludePid,
          onPacket: onPacket);
      if (!ok) {
        _log('[HOLLOW-AU-SCREEN] Failed to start WASAPI capturer');
        _screenAudioCapturer = null;
      }
      return;
    }

    // macOS 13.0+: ScreenCaptureKit audio path (Process Tap retired).
    if (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio) {
      if (_macSckAudioCapturer?.isActive == true) return;
      _log('[HOLLOW-AU-SCREEN] Starting ScreenCaptureKit audio capture');
      _macSckAudioCapturer = MacSckScreenAudioCapturer();
      final ok = await _macSckAudioCapturer!.start(onPacket: onPacket);
      if (!ok) {
        _log('[HOLLOW-AU-SCREEN] Failed to start SCK audio capturer');
        _macSckAudioCapturer = null;
      }
      return;
    }
  }

  Future<void> _stopScreenAudioCapture() async {
    if (_screenAudioCapturer != null) {
      await _screenAudioCapturer!.stop();
      _screenAudioCapturer = null;
    }
    if (_macSckAudioCapturer != null) {
      await _macSckAudioCapturer!.stop();
      _macSckAudioCapturer = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  /// Close the PC, stop tracks, dispose renderers. Safe to call multiple times.
  Future<void> close() async {
    _log('[HOLLOW-SCREEN] Closing screen share service');

    // Stop screen audio capture before tearing down PC.
    await _stopScreenAudioCapture();

    // Tear down macOS system audio tap first so the system default input
    // reverts before we stop the streams.
    if (_macSystemAudioActive) {
      try {
        await _kFlutterWebRTCChannel
            .invokeMethod<bool>('disableScreenShareSystemAudio');
        _log('[HOLLOW-SCREEN] macOS Process Tap disabled');
      } catch (e) {
        _log('[HOLLOW-SCREEN] disableScreenShareSystemAudio failed: $e');
      }
      _macSystemAudioActive = false;
    }

    _screenTrackPoller?.cancel();
    _screenTrackPoller = null;

    // Teardown must be DEFENSIVE: each native disposal is wrapped so one
    // failure can't abort the rest, leaking the PC/streams. On Linux
    // `RTCVideoRenderer.dispose()` throws "VideoRendererDispose() texture not
    // found!" when the texture is already gone — that uncaught throw used to
    // crash the app on screen-share stop (it skipped the PC/stream cleanup).
    // Null the field BEFORE awaiting so a re-entrant close() can't double-free.

    // Dispose local self-preview renderer first (before stream goes away).
    final localRenderer = _localRenderer;
    _localRenderer = null;
    if (localRenderer != null) {
      try {
        localRenderer.srcObject = null;
        await localRenderer.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] local renderer dispose failed (ignored): $e');
      }
    }

    // Stop local screen capture — ONLY if we own it. For createOfferFromStream
    // the capture is shared across many per-peer services and owned by the
    // provider; disposing it here kills every other peer's share AND double-frees
    // it (the provider disposes it too) → `corrupted size vs prev_size` abort.
    final screenStream = _screenStream;
    final ownsScreenStream = _ownsScreenStream;
    _screenStream = null;
    if (screenStream != null && ownsScreenStream) {
      try {
        for (final track in screenStream.getTracks()) {
          await track.stop();
        }
        await screenStream.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] screen stream dispose failed (ignored): $e');
      }
    }

    // Dispose remote renderer.
    final remoteRenderer = _remoteRenderer;
    _remoteRenderer = null;
    if (remoteRenderer != null) {
      try {
        remoteRenderer.srcObject = null;
        await remoteRenderer.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] remote renderer dispose failed (ignored): $e');
      }
    }
    // Dispose the remote stream ONLY if we synthesized it (createLocalMediaStream
    // fallback). libwebrtc owns the event-provided streams — disposing those
    // double-frees. We null the reference either way.
    final remoteStream = _remoteStream;
    final remoteSynthetic = _remoteStreamIsSynthetic;
    _remoteStream = null;
    if (remoteStream != null && remoteSynthetic) {
      try {
        await remoteStream.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] remote stream dispose failed (ignored): $e');
      }
    }

    // Close PC. close() and dispose() get SEPARATE guards — if close() throws on
    // an already-failing native PC, dispose() (which frees the thread-set) must
    // still run, or the libwebrtc threads leak.
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (e) {
        _log('[HOLLOW-SCREEN] pc close failed (ignored): $e');
      }
      try {
        await pc.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] pc dispose failed (ignored): $e');
      }
    }

    // Restore ownership defaults so the next use of this instance starts clean
    // (createOffer captures+owns; createOfferFromStream re-sets false).
    _ownsScreenStream = true;
    _remoteStreamIsSynthetic = false;

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
    // Dispose any previously-synthesized remote stream before replacing it
    // (a track-replace on renegotiation re-enters here). libwebrtc-owned
    // streams must NOT be disposed.
    final priorStream = _remoteStream;
    final priorSynthetic = _remoteStreamIsSynthetic;
    _remoteStreamIsSynthetic = false;

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
        // Last resort: create synthetic stream (we own this one).
        _remoteStream = await createLocalMediaStream(
          'screen-remote-${event.track.id}',
        );
        _remoteStream!.addTrack(event.track);
        _remoteStreamIsSynthetic = true;
        _log('[HOLLOW-SCREEN] Created synthetic stream (last resort)');
      }
    }

    // Dispose the prior synthetic stream now that it's been replaced.
    if (priorStream != null && priorSynthetic && !identical(priorStream, _remoteStream)) {
      try {
        await priorStream.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] prior synthetic remote stream dispose failed (ignored): $e');
      }
    }

    // Create renderer. Null the field BEFORE awaiting dispose so a Linux
    // "texture not found!" throw can't leave a stale half-disposed renderer
    // that close() would then double-dispose.
    final oldRenderer = _remoteRenderer;
    _remoteRenderer = null;
    if (oldRenderer != null) {
      oldRenderer.srcObject = null;
      try {
        await oldRenderer.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] old remote renderer dispose failed (ignored): $e');
      }
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
