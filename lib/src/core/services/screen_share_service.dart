import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import '../perf_sentinel.dart';
import 'screen_audio_capturer.dart';
import 'mac_sck_screen_audio_capturer.dart';
import 'mobile_screen_audio_capturer.dart';
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
  // --- Screen audio via native mobile capture + Rust Opus encode ---
  MobileScreenAudioCapturer? _mobileAudioCapturer;


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
          _configureVideoEncoding(
              encoding, sender.track!, maxWidth, maxHeight, fps);
        }
        await sender.setParameters(params);
        break;
      }
    }
  }

  /// Configure one video encoding: downscale to the cap if the capture is
  /// larger, pin the framerate, and set the bitrate tier for the target size.
  void _configureVideoEncoding(
    RTCRtpEncoding encoding,
    MediaStreamTrack track,
    int maxWidth,
    int maxHeight,
    int fps,
  ) {
    final settings = track.getSettings();
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

    final maxBitrateKbps = _maxBitrateKbpsFor(maxWidth, maxHeight);
    encoding.maxBitrate = maxBitrateKbps * 1000; // bps
    _log('[HOLLOW-SCREEN] Set maxBitrate=${maxBitrateKbps}kbps '
        'maxFramerate=${fps}fps for ${maxWidth}x$maxHeight');
  }

  /// Bitrate tiers (screen share — higher than camera because
  /// screen content has sharp edges/text that compress poorly):
  ///   360p  →  800 kbps
  ///   480p  → 1500 kbps
  ///   720p  → 3000 kbps
  ///  1080p  → 6000 kbps
  ///  1440p  → 9000 kbps
  ///  4K     → 15000 kbps
  int _maxBitrateKbpsFor(int maxWidth, int maxHeight) {
    final pixels = maxWidth * maxHeight;
    if (pixels <= 640 * 360) {
      return 800;
    } else if (pixels <= 854 * 480) {
      return 1500;
    } else if (pixels <= 1280 * 720) {
      return 3000;
    } else if (pixels <= 1920 * 1080) {
      return 6000;
    } else if (pixels <= 2560 * 1440) {
      return 9000;
    } else {
      return 15000;
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

    await _requestMacCapturePermissionIfNeeded();

    // Capture screen (+ optional system audio). Source enumeration is
    // desktop-only; mobile captures THE screen (MediaProjection / ReplayKit).
    if (!Platform.isAndroid && !Platform.isIOS) {
      await desktopCapturer.getSources(
          types: [SourceType.Screen, SourceType.Window]);
    }

    // macOS system-audio routing:
    //  - 13.0+ : ScreenCaptureKit audio-only -> data channel (0x03), same as
    //    Windows. Started later via startScreenAudioCapture. We deliberately do
    //    NOT use the CoreAudio Process Tap (14.2+) — it injects audio into the
    //    system default input, which the CoreAudio ADM (our voice-call ADM on
    //    macOS) doesn't follow, so it fed 0 tracks. The data-channel path is
    //    ADM-independent and uniform across all macOS versions.
    //  - <13.0 : no capture API; the UI locks the toggle off, so shareAudio is
    //    false here anyway.
    // Windows, macOS 13.0+, Linux, and MOBILE send audio via the data channel —
    // never request it in getDisplayMedia (the WASAPI/AudioSource path crashes
    // on Windows, isn't available on macOS, yields nothing on Linux, and on
    // mobile a WebRTC track would drag music through the voice-comm AEC/AGC).
    // Android taps AudioPlaybackCapture, iOS the broadcast extension — both
    // stream PCM to Dart, Rust Opus-encodes, 0x03 data channel.
    final useDataChannelAudio = shareAudio &&
        (Platform.isWindows ||
            Platform.isLinux ||
            Platform.isAndroid ||
            Platform.isIOS ||
            (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio));
    final getDisplayAudio = shareAudio && !useDataChannelAudio;

    await _captureScreenStream(sourceId, width, height, fps, getDisplayAudio);

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

    await _preferVp8OnMacOS(screenTrack);

    // Apply resolution cap on the encoder (getDisplayMedia captures at native res).
    await _applyResolutionCap(width, height, fps);

    await _addCapturedAudioTracks(shareAudio);

    // Generate offer.
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    _log('[HOLLOW-SCREEN] Offer created, SDP length=${offer.sdp?.length}');

    // Poll for track ending (onEnded not wired on native desktop).
    _startTrackPoller();

    return offer.sdp!;
  }

  /// macOS / Android need explicit screen-capture permission before any
  /// source enumeration. On macOS this triggers the System Settings →
  /// Privacy & Security → Screen & System Audio Recording prompt; the
  /// first attempt always returns false, the user grants access in
  /// Settings, and the next launch reads granted. Web/Windows/Linux just
  /// return true.
  Future<void> _requestMacCapturePermissionIfNeeded() async {
    if (!Platform.isMacOS) return;
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

  /// Platform-branched getDisplayMedia into [_screenStream].
  Future<void> _captureScreenStream(
    String sourceId,
    int width,
    int height,
    int fps,
    bool getDisplayAudio,
  ) async {
    if (Platform.isAndroid) {
      // Constraints are ignored by the Android plugin (MediaProjection
      // captures the display at native size; the consent dialog handles
      // permission). The encoder cap below does the downscaling.
      _screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
    } else if (Platform.isIOS) {
      // 'broadcast' selects the ReplayKit Broadcast Upload Extension path
      // (system-blessed: whole screen + app audio, keeps running when Hollow
      // is backgrounded) and auto-presents the RPSystemBroadcastPickerView.
      _screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {'deviceId': 'broadcast'},
        'audio': false,
      });
    } else {
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
    }
  }

  /// On macOS prefer VP8 for screen share. Apple's H.264 hardware encoder
  /// can emit a profile (e.g. high) that Windows libwebrtc's software
  /// decoder fails to render — frames decode to a black image with no
  /// error. VP8 has no profile axis and works identically on both ends.
  Future<void> _preferVp8OnMacOS(MediaStreamTrack screenTrack) async {
    if (!Platform.isMacOS) return;
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

  /// Add any audio tracks getDisplayMedia delivered to the PC (macOS Process
  /// Tap path). Logs when audio was requested but no track is available.
  Future<void> _addCapturedAudioTracks(bool shareAudio) async {
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
  /// - Linux: same exe, `--mode pipe` with per-sink-input capture — window
  ///   shares INCLUDE only the shared app's process tree (X id -> _NET_WM_PID),
  ///   entire-screen EXCLUDES Hollow's own tree (anti-echo); whole-monitor
  ///   capture is the in-exe fallback.
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
    if (Platform.isWindows || Platform.isLinux) {
      await _startDesktopAudioCapturer(
          pid: pid,
          windowHwnd: windowHwnd,
          excludePid: excludePid,
          onPacket: onPacket);
      return;
    }

    // macOS 13.0+: ScreenCaptureKit audio path (Process Tap retired).
    if (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio) {
      await _startMacSckAudioCapturer(onPacket);
      return;
    }

    // Mobile: native capture (Android AudioPlaybackCapture / iOS broadcast
    // extension audio) -> PCM to Dart -> Rust Opus encode -> onPacket.
    if (Platform.isAndroid || Platform.isIOS) {
      await _startMobileAudioCapturer(onPacket);
      return;
    }
  }

  Future<void> _startDesktopAudioCapturer({
    required int pid,
    required int windowHwnd,
    required int excludePid,
    required void Function(Uint8List packet) onPacket,
  }) async {
    if (_screenAudioCapturer?.isActive == true) return;
    _log('[HOLLOW-AU-SCREEN] Starting system audio capture '
        '(pid=$pid hwnd=$windowHwnd excludePid=$excludePid)');
    _screenAudioCapturer = ScreenAudioCapturer();
    final ok = await _screenAudioCapturer!.start(
        pid: pid,
        windowHwnd: windowHwnd,
        excludePid: excludePid,
        onPacket: onPacket);
    if (!ok) {
      _log('[HOLLOW-AU-SCREEN] Failed to start system audio capturer');
      _screenAudioCapturer = null;
    }
  }

  Future<void> _startMacSckAudioCapturer(
      void Function(Uint8List packet) onPacket) async {
    if (_macSckAudioCapturer?.isActive == true) return;
    _log('[HOLLOW-AU-SCREEN] Starting ScreenCaptureKit audio capture');
    _macSckAudioCapturer = MacSckScreenAudioCapturer();
    final ok = await _macSckAudioCapturer!.start(onPacket: onPacket);
    if (!ok) {
      _log('[HOLLOW-AU-SCREEN] Failed to start SCK audio capturer');
      _macSckAudioCapturer = null;
    }
  }

  Future<void> _startMobileAudioCapturer(
      void Function(Uint8List packet) onPacket) async {
    if (_mobileAudioCapturer?.isActive == true) return;
    _log('[HOLLOW-AU-SCREEN] Starting mobile screen-audio capture');
    _mobileAudioCapturer = MobileScreenAudioCapturer();
    final ok = await _mobileAudioCapturer!.start(onPacket: onPacket);
    if (!ok) {
      _log('[HOLLOW-AU-SCREEN] Failed to start mobile audio capturer');
      _mobileAudioCapturer = null;
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
    if (_mobileAudioCapturer != null) {
      await _mobileAudioCapturer!.stop();
      _mobileAudioCapturer = null;
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

    await _disableMacSystemAudioTap();

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
    await _disposeRendererSafely(localRenderer, 'local renderer');

    await _disposeOwnedScreenStream();

    // Dispose remote renderer.
    final remoteRenderer = _remoteRenderer;
    _remoteRenderer = null;
    await _disposeRendererSafely(remoteRenderer, 'remote renderer');

    await _disposeSyntheticRemoteStream();

    await _closeAndDisposePc();

    // Restore ownership defaults so the next use of this instance starts clean
    // (createOffer captures+owns; createOfferFromStream re-sets false).
    _ownsScreenStream = true;
    _remoteStreamIsSynthetic = false;

    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
  }

  /// Tear down the macOS system audio tap first so the system default input
  /// reverts before we stop the streams.
  Future<void> _disableMacSystemAudioTap() async {
    if (!_macSystemAudioActive) return;
    try {
      await PerfSentinel.timedChannelCall<bool>(
          _kFlutterWebRTCChannel, 'disableScreenShareSystemAudio');
      _log('[HOLLOW-SCREEN] macOS Process Tap disabled');
    } catch (e) {
      _log('[HOLLOW-SCREEN] disableScreenShareSystemAudio failed: $e');
    }
    _macSystemAudioActive = false;
  }

  /// Defensive renderer disposal: the caller has already nulled the field.
  Future<void> _disposeRendererSafely(
      RTCVideoRenderer? renderer, String label) async {
    if (renderer == null) return;
    try {
      renderer.srcObject = null;
      await renderer.dispose();
    } catch (e) {
      _log('[HOLLOW-SCREEN] $label dispose failed (ignored): $e');
    }
  }

  /// Stop local screen capture — ONLY if we own it. For createOfferFromStream
  /// the capture is shared across many per-peer services and owned by the
  /// provider; disposing it here kills every other peer's share AND double-frees
  /// it (the provider disposes it too) → `corrupted size vs prev_size` abort.
  Future<void> _disposeOwnedScreenStream() async {
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
  }

  /// Dispose the remote stream ONLY if we synthesized it (createLocalMediaStream
  /// fallback). libwebrtc owns the event-provided streams — disposing those
  /// double-frees. We null the reference either way.
  Future<void> _disposeSyntheticRemoteStream() async {
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
  }

  /// Close PC. close() and dispose() get SEPARATE guards — if close() throws on
  /// an already-failing native PC, dispose() (which frees the thread-set) must
  /// still run, or the libwebrtc threads leak.
  Future<void> _closeAndDisposePc() async {
    final pc = _pc;
    _pc = null;
    if (pc == null) return;
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
      _onConnectionStateChanged(state);
    };
  }

  void _onConnectionStateChanged(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        onConnected?.call();
        _scheduleIceRouteLog();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        onDisconnected?.call();
      default:
        break;
    }
  }

  /// Log which ICE route (TURN/STUN/LAN) the connected PC ended up on, one
  /// second after connect. Diagnostic only.
  void _scheduleIceRouteLog() {
    final screenPc = _pc;
    if (screenPc == null) return;
    Future.delayed(const Duration(seconds: 1), () async {
      await _logIceRoute(screenPc);
    });
  }

  Future<void> _logIceRoute(RTCPeerConnection screenPc) async {
    try {
      final stats = await screenPc.getStats();
      for (final report in stats) {
        if (report.type == 'candidate-pair' && report.values['state'] == 'succeeded') {
          final localId = report.values['localCandidateId'] as String?;
          final remoteId = report.values['remoteCandidateId'] as String?;
          final (localType, remoteType, proto) =
              _candidateTypesFor(stats, localId, remoteId);
          final route = _describeIceRoute(localType, remoteType);
          _log('[HOLLOW-SCREEN] ICE route: $route (local=$localType remote=$remoteType proto=$proto)');
          return;
        }
      }
      _log('[HOLLOW-SCREEN] ICE route: no succeeded candidate pair found');
    } catch (e) {
      _log('[HOLLOW-SCREEN] ICE route check failed: $e');
    }
  }

  /// Resolve (localType, remoteType, proto) for a succeeded candidate pair.
  (String, String, String) _candidateTypesFor(
    List<StatsReport> stats,
    String? localId,
    String? remoteId,
  ) {
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
    return (localType, remoteType, proto);
  }

  String _describeIceRoute(String localType, String remoteType) {
    return localType == 'relay' || remoteType == 'relay'
        ? 'TURN (relayed)'
        : localType == 'srflx' || remoteType == 'srflx'
            ? 'STUN (direct P2P)'
            : localType == 'host' && remoteType == 'host'
                ? 'LAN (direct)'
                : 'P2P ($localType/$remoteType)';
  }

  Future<void> _handleRemoteVideoTrack(RTCTrackEvent event) async {
    // Dispose any previously-synthesized remote stream before replacing it
    // (a track-replace on renegotiation re-enters here). libwebrtc-owned
    // streams must NOT be disposed.
    final priorStream = _remoteStream;
    final priorSynthetic = _remoteStreamIsSynthetic;
    _remoteStreamIsSynthetic = false;

    await _resolveRemoteStream(event);

    await _disposePriorSyntheticStream(priorStream, priorSynthetic);

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

  /// Pick the remote stream for the incoming video track: the event's stream,
  /// a PC remote stream with video, or (last resort) a synthetic stream we own.
  Future<void> _resolveRemoteStream(RTCTrackEvent event) async {
    if (event.streams.isNotEmpty) {
      _remoteStream = event.streams.first;
      _log('[HOLLOW-SCREEN] Using stream from onTrack '
          '(streams=${event.streams.length})');
    } else {
      // Windows/libwebrtc may fire onTrack with streams=0.
      // Try to find the stream from the PC's remote streams.
      _log('[HOLLOW-SCREEN] onTrack streams=0, checking PC remote streams');
      final found = _findRemoteVideoStream();
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
  }

  MediaStream? _findRemoteVideoStream() {
    if (_pc == null) return null;
    final remoteStreams = _pc!.getRemoteStreams();
    for (final s in remoteStreams) {
      if (s == null) continue;
      if (s.getVideoTracks().isNotEmpty) {
        _log('[HOLLOW-SCREEN] Found remote stream ${s.id}');
        return s;
      }
    }
    return null;
  }

  /// Dispose the prior synthetic stream now that it's been replaced.
  Future<void> _disposePriorSyntheticStream(
      MediaStream? priorStream, bool priorSynthetic) async {
    if (priorStream != null && priorSynthetic && !identical(priorStream, _remoteStream)) {
      try {
        await priorStream.dispose();
      } catch (e) {
        _log('[HOLLOW-SCREEN] prior synthetic remote stream dispose failed (ignored): $e');
      }
    }
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
