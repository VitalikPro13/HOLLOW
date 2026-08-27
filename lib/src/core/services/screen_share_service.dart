import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import '../perf_sentinel.dart';
import 'desktop_capture_support.dart';
import 'ice_route_probe.dart';
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

/// What the shared content mostly is — drives encoder tuning.
///
/// [text]: code, documents, UI. Under pressure the encoder drops FRAMES and
/// keeps resolution (blocky text is the visible failure mode); codec
/// preference leans AV1/VP9 (screen-content compression); dialog defaults
/// to 15 fps so each refresh gets a bigger bit budget.
///
/// [motion]: gameplay, video playback. Under pressure the encoder keeps
/// FRAMERATE (a slideshow hurts more than blur); VP9-first; 60 fps default.
enum ScreenContentProfile { text, motion }

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

  /// True when this PC is a media-forwarder leg (step 3): an ingest to a
  /// forwarder, or an egress attach from one. Labels the ICE-route log —
  /// route probing can't distinguish a forwarder hop from a direct pair
  /// (host↔host to a public forwarder looks "direct"; on an Always-relay
  /// client the old label even read "TURN (relayed)" misleadingly — D6
  /// follow-up #1).
  final bool forwarderLeg;

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

  /// Content profile of the current outgoing share (set by both offer paths).
  /// Will also drive the track contentHint once the fork exposes it.
  ScreenContentProfile _contentProfile = ScreenContentProfile.motion;

  /// Last requested resolution/fps cap for the OUTGOING share (null on
  /// incoming-only PCs). Used by the post-connect re-apply + verification.
  int? _capWidth;
  int? _capHeight;
  int? _capFps;

  /// Phase 3: this outgoing PC carries a 2-layer simulcast (forwarder ingest
  /// legs only — rid 'f' at the cap + rid 'q' at half per axis). Cap changes
  /// must keep BOTH layers consistent.
  bool _simulcast = false;

  // --- Screen audio via out-of-process capturer (Windows) ---
  ScreenAudioCapturer? _screenAudioCapturer;
  // --- Screen audio via ScreenCaptureKit (macOS 13.0–14.1) ---
  MacSckScreenAudioCapturer? _macSckAudioCapturer;
  // --- Screen audio via native mobile capture + Rust Opus encode ---
  MobileScreenAudioCapturer? _mobileAudioCapturer;


  ScreenShareService({
    required this.localPeerId,
    required this.iceServers,
    this.forwarderLeg = false,
  });

  /// Effective per-viewer resolution cap (media forwarding step 1): the
  /// share's chosen cap clamped to what THIS viewer's display can actually
  /// show. Compared on orientation-normalized long/short edges so a portrait
  /// phone isn't over-restricted watching a landscape share, then mapped back
  /// into the share cap's orientation.
  ///
  /// A 0x0 viewer size means unknown (old client that doesn't send it) and
  /// leaves the share cap untouched, preserving pre-step-1 behavior.
  ///
  /// There is deliberately NO per-viewer "Source quality" opt-out (removed
  /// 2026-08-15): the clamp is keyed to the viewer's largest MONITOR, so it
  /// already delivers every pixel they can display, and on a shared forwarder
  /// branch there is no per-viewer encoder for an opt-out to apply to.
  static (int, int) effectiveViewerCap(
    int shareMaxWidth,
    int shareMaxHeight,
    int viewerWidth,
    int viewerHeight,
  ) {
    if (viewerWidth <= 0 || viewerHeight <= 0) {
      return (shareMaxWidth, shareMaxHeight);
    }
    final shareLong =
        shareMaxWidth > shareMaxHeight ? shareMaxWidth : shareMaxHeight;
    final shareShort =
        shareMaxWidth > shareMaxHeight ? shareMaxHeight : shareMaxWidth;
    final viewerLong = viewerWidth > viewerHeight ? viewerWidth : viewerHeight;
    final viewerShort = viewerWidth > viewerHeight ? viewerHeight : viewerWidth;
    final effLong = shareLong < viewerLong ? shareLong : viewerLong;
    final effShort = shareShort < viewerShort ? shareShort : viewerShort;
    return shareMaxWidth >= shareMaxHeight
        ? (effLong, effShort)
        : (effShort, effLong);
  }

  /// Phase-3 simulcast layer choice for ONE viewer on a forwarder branch:
  /// true = serve the low layer (rid `q`, the full layer downscaled 2x per
  /// axis), false = the full layer (rid `f`).
  ///
  /// [fullWidth]/[fullHeight] = the branch's ingest cap (the `f` layer).
  /// [viewerCapWidth]/[viewerCapHeight] = that viewer's ALREADY-EFFECTIVE cap
  /// (display clamped to the share cap) — the caller owns that math so this
  /// stays the single half-cap comparison the field verified.
  ///
  static bool viewerWantsLowLayer(
    int fullWidth,
    int fullHeight,
    int viewerCapWidth,
    int viewerCapHeight,
  ) {
    if (viewerCapWidth <= 0 || viewerCapHeight <= 0) return false;
    final vLong =
        viewerCapWidth > viewerCapHeight ? viewerCapWidth : viewerCapHeight;
    final fLong = fullWidth > fullHeight ? fullWidth : fullHeight;
    return vLong * 2 <= fLong;
  }

  /// Live-update the outgoing resolution cap on a negotiated sender — the
  /// viewer changed what they can show / want (Source quality toggle,
  /// re-sent screen_watch). Rides the same setParameters path the
  /// post-connect enforcement uses, and writes _capWidth/_capHeight FIRST so
  /// that enforcement re-applies THIS cap rather than reverting it.
  ///
  /// Returns false when the sender REJECTED the live change; the caller
  /// must then renegotiate: tear down this service and send a fresh offer
  /// with the new cap in the init encodings. Returns true when nothing
  /// changed or the live update was accepted.
  ///
  /// History: on Windows EVERY live setParameters returned false 2026-07-20
  /// → 2026-08-08. Root cause (phase 3): the native→Dart parameters map
  /// materialized unset optionals (scalabilityMode "" / ssrc 0), and the
  /// write-back turned them into set-but-invalid values — libwebrtc rejects
  /// the whole call with INVALID_MODIFICATION. Fixed in the plugin
  /// (flutter_peerconnection.cc); the renegotiate fallback stays as the
  /// belt.
  Future<bool> updateResolutionCap(int maxWidth, int maxHeight) async {
    if (_capFps == null) return false; // Incoming-only PC / no cap requested.
    if (_capWidth == maxWidth && _capHeight == maxHeight) return true;
    _capWidth = maxWidth;
    _capHeight = maxHeight;
    final screenPc = _pc;
    if (screenPc == null) return false;
    _log('[HOLLOW-SCREEN] Viewer-driven cap update -> ${maxWidth}x$maxHeight');
    final ok = await _reapplyResolutionCap(screenPc);
    if (!ok) {
      _log('[HOLLOW-SCREEN] Live cap update rejected — renegotiation needed');
    }
    return ok;
  }

  /// Wait for ICE gathering to complete and return the full local SDP.
  ///
  /// Media forwarding step 3: forwarder legs exchange COMPLETE SDPs — the
  /// forwarder sits on a fixed public host candidate and has no trickle lane
  /// (`FwdIce` is reserved, unimplemented). Call after createOfferFromStream
  /// (ingest leg) or handleOffer (egress leg answer). Falls back to whatever
  /// has gathered when the [timeout] lapses — a srflx candidate is usually in
  /// well under a second.
  /// A leg whose SDP leaves with zero candidates can never connect, and ICE
  /// then fails SILENTLY (no state transitions at all — the port allocator
  /// never activates the transport). Logging the count here is what turned
  /// that into a one-line diagnosis; keep it.
  Future<String?> gatheredLocalSdp(
      {Duration timeout = const Duration(seconds: 10)}) async {
    final pc = _pc;
    if (pc == null) return null;
    final deadline = DateTime.now().add(timeout);
    String? sdp;
    // Wait for CANDIDATES, not for gatheringState == complete: this fork
    // routinely sits in `gathering` indefinitely even with candidates already
    // in the local description, which turned every forwarder leg into a flat
    // 10-second stall before the SDP was sent (field-measured 2026-08-06).
    // One extra settle poll after the first candidate picks up the srflx that
    // usually lands right behind the host one.
    var polls = 0;
    while (DateTime.now().isBefore(deadline)) {
      sdp = (await pc.getLocalDescription())?.sdp;
      final have = sdp != null && sdp.contains('a=candidate:');
      if (have && polls >= 1) break;
      if (pc.iceGatheringState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        break;
      }
      polls = have ? polls + 1 : 0;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    sdp = (await pc.getLocalDescription())?.sdp;
    final candidates =
        sdp == null ? 0 : RegExp('a=candidate:').allMatches(sdp).length;
    _log('[HOLLOW-SCREEN] Gathered local SDP: $candidates candidate(s), '
        'gathering=${pc.iceGatheringState}');
    if (candidates == 0) {
      _log('[HOLLOW-SCREEN] WARNING: no ICE candidates gathered — this leg '
          'cannot connect');
    }
    return sdp;
  }

  /// Apply resolution, framerate, and bitrate caps on the video sender's
  /// encoding parameters. Even though getDisplayMedia now receives width/height
  /// constraints, the desktop capturer may still deliver native-resolution
  /// frames — this enforces the cap at the encoder level as a second layer.
  ///
  /// [captureWidth]/[captureHeight] override the track.getSettings() capture
  /// size when the caller knows better (post-connect we read the true size
  /// from media-source stats — getSettings is absent for desktop captures on
  /// some platforms and the 1920x1080 fallback computes a wrong scale).
  /// Returns whether the sender ACCEPTED the setParameters call (false on
  /// no PC / no video sender / libwebrtc rejection — callers that need the
  /// cap to actually change must renegotiate on false).
  Future<bool> _applyResolutionCap(
      int maxWidth, int maxHeight, int fps, ScreenContentProfile profile,
      {int? captureWidth, int? captureHeight}) async {
    _capWidth = maxWidth;
    _capHeight = maxHeight;
    _capFps = fps;
    if (_pc == null) return false;
    var applied = false;
    final senders = await _pc!.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        final params = sender.parameters;
        if (params.encodings == null || params.encodings!.isEmpty) {
          params.encodings = [RTCRtpEncoding()];
        }

        // Text content must stay SHARP: under bandwidth/CPU pressure drop
        // frames, never resolution (maintain-resolution is the W3C mapping
        // for detail/text screen content). Motion content is the opposite —
        // a slideshow hurts more than transient blur. The resolution cap
        // itself is enforced by scaleResolutionDownBy below either way.
        params.degradationPreference = profile == ScreenContentProfile.text
            ? RTCDegradationPreference.MAINTAIN_RESOLUTION
            : RTCDegradationPreference.MAINTAIN_FRAMERATE;

        final (capW, capH) = (captureWidth != null &&
                captureHeight != null &&
                captureWidth > 0 &&
                captureHeight > 0)
            ? (captureWidth, captureHeight)
            : _captureSizeOf(sender.track!);
        for (final encoding in params.encodings!) {
          // Simulcast ingest legs: the 'q' layer tracks the cap at half per
          // axis; everything else (incl. the 'f' layer) gets the full cap.
          final low = _simulcast && encoding.rid == 'q';
          final tw = low && maxWidth ~/ 2 >= 2 ? maxWidth ~/ 2 : maxWidth;
          final th = low && maxHeight ~/ 2 >= 2 ? maxHeight ~/ 2 : maxHeight;
          _configureVideoEncoding(encoding, capW, capH, tw, th, fps);
        }
        final ok = await sender.setParameters(params);
        _log('[HOLLOW-SCREEN] setParameters(cap ${maxWidth}x$maxHeight'
            '@${fps}fps) -> ${ok ? 'accepted' : 'REJECTED by libwebrtc'}');
        applied = ok;
        break;
      }
    }
    return applied;
  }

  /// Capture dimensions from track.getSettings(), defaulting to 1920x1080
  /// when the platform reports nothing (desktop captures often do). Logged
  /// loudly because a wrong assumption here computes a wrong scale factor.
  (int, int) _captureSizeOf(MediaStreamTrack track) {
    Map<dynamic, dynamic> settings = const {};
    try {
      settings = track.getSettings();
    } catch (_) {}
    final w = settings['width'] as int?;
    final h = settings['height'] as int?;
    if (w == null || h == null || w <= 0 || h <= 0) {
      _log('[HOLLOW-SCREEN] track.getSettings() has no capture size '
          '($settings) — assuming 1920x1080');
      return (1920, 1080);
    }
    return (w, h);
  }

  /// Build the send encoding handed to addTransceiver. Supplying encodings at
  /// transceiver-init time is the path libwebrtc guarantees to honor across
  /// offer/answer (they become the sender's init parameters and are applied
  /// when the sender attaches at negotiation) — a pre-negotiation
  /// setParameters is NOT reliably carried across that transition, which is
  /// how the receiver ended up with native resolution.
  /// [rid] tags a simulcast layer (forwarder ingest legs, phase 3).
  RTCRtpEncoding _buildScreenSendEncoding(
      MediaStreamTrack track, int maxWidth, int maxHeight, int fps,
      {String? rid}) {
    final encoding = RTCRtpEncoding()
      // Dart defaults this to 1, which would pin the encoder to a single
      // temporal layer; null lets libwebrtc pick per-codec.
      ..numTemporalLayers = null
      ..rid = rid;
    final (capW, capH) = _captureSizeOf(track);
    _configureVideoEncoding(encoding, capW, capH, maxWidth, maxHeight, fps);
    return encoding;
  }

  /// The two simulcast layers for a forwarder ingest leg (phase 3), LOW
  /// FIRST: libwebrtc's rate allocator protects encodings[0] under
  /// congestion, and the small layer is the one every branch viewer must be
  /// able to keep receiving (a starved full layer drops its viewers onto the
  /// low layer via the forwarder engine's dry-layer fallback). Rid names are
  /// the forwarder contract: 'f' = full (the branch cap), 'q' = quarter
  /// (half per axis).
  List<RTCRtpEncoding> _buildSimulcastSendEncodings(
      MediaStreamTrack track, int maxWidth, int maxHeight, int fps) {
    final qW = maxWidth ~/ 2, qH = maxHeight ~/ 2;
    return [
      _buildScreenSendEncoding(
          track, qW < 2 ? maxWidth : qW, qH < 2 ? maxHeight : qH, fps,
          rid: 'q'),
      _buildScreenSendEncoding(track, maxWidth, maxHeight, fps, rid: 'f'),
    ];
  }

  /// Configure one video encoding: downscale to the cap if the capture is
  /// larger, pin the framerate, and set the bitrate tier for the target size.
  void _configureVideoEncoding(
    RTCRtpEncoding encoding,
    int captureWidth,
    int captureHeight,
    int maxWidth,
    int maxHeight,
    int fps,
  ) {
    // Downscale if the capture is larger than the target.
    if (captureWidth > maxWidth || captureHeight > maxHeight) {
      final scaleW = captureWidth / maxWidth;
      final scaleH = captureHeight / maxHeight;
      final scale = scaleW > scaleH ? scaleW : scaleH;
      encoding.scaleResolutionDownBy = scale;
      _log('[HOLLOW-SCREEN] Set scaleResolutionDownBy=$scale '
          '(${captureWidth}x$captureHeight -> ${maxWidth}x$maxHeight)');
    } else {
      encoding.scaleResolutionDownBy = 1.0;
    }

    encoding.maxFramerate = fps;

    final maxBitrateKbps = _maxBitrateKbpsFor(maxWidth, maxHeight);
    encoding.maxBitrate = maxBitrateKbps * 1000; // bps
    // Floor the allocation too: after a congestion episode the bandwidth
    // estimator ramps back slowly, and with no floor the encoder sits at a
    // starvation bitrate long after the link recovers — text turns to QP
    // mush with nothing pushing it back up.
    final minBitrateKbps = _minBitrateKbpsFor(maxWidth, maxHeight);
    encoding.minBitrate = minBitrateKbps * 1000; // bps
    _log('[HOLLOW-SCREEN] Set bitrate=$minBitrateKbps-${maxBitrateKbps}kbps '
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

  /// Minimum bitrate floor per tier — high enough that the encoder is never
  /// starved into blockiness by a stale low bandwidth estimate, low enough
  /// not to overrun genuinely narrow (e.g. TURN-relayed) links.
  int _minBitrateKbpsFor(int maxWidth, int maxHeight) {
    final pixels = maxWidth * maxHeight;
    if (pixels <= 640 * 360) {
      return 300;
    } else if (pixels <= 854 * 480) {
      return 500;
    } else if (pixels <= 1280 * 720) {
      return 800;
    } else if (pixels <= 1920 * 1080) {
      return 1500;
    } else if (pixels <= 2560 * 1440) {
      return 2000;
    } else {
      return 2500;
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
    ScreenContentProfile profile = ScreenContentProfile.motion,
  }) async {
    _log('[HOLLOW-SCREEN] Creating offer: source=$sourceId '
        '${width}x$height @ ${fps}fps audio=$shareAudio '
        'profile=${profile.name}');
    _contentProfile = profile;

    // Idempotent: tear down any prior PC/stream on this service before
    // capturing a new one, so a re-share on the same instance can't strand the
    // old PeerConnection's thread-set.
    if (_pc != null || _screenStream != null || _localRenderer != null) {
      await close();
    }

    await _requestMacCapturePermissionIfNeeded();

    // Capture screen (+ optional system audio). Source enumeration is
    // desktop-only; mobile captures THE screen (MediaProjection / ReplayKit).
    // A Wayland portal-first share MUST NOT re-enumerate: the native side
    // resolves the sentinel id without a source list, and enumerating here
    // would pop an extra xdg-desktop-portal dialog.
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !DesktopCaptureSupport.isPortalSourceId(sourceId)) {
      await desktopCapturer.getSources(
          types: DesktopCaptureSupport.sourceTypes);
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

    // Add screen video track WITH the resolution cap as init sendEncodings —
    // the only pre-negotiation channel libwebrtc reliably folds into the
    // sender at offer/answer (see _buildScreenSendEncoding).
    await _pc!.addTransceiver(
      track: screenTrack,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendRecv,
        streams: [_screenStream!],
        sendEncodings: [
          _buildScreenSendEncoding(screenTrack, width, height, fps),
        ],
      ),
    );
    _log('[HOLLOW-SCREEN] Added screen video transceiver '
        '(init cap ${width}x$height@${fps}fps)');

    await _applyContentHint(screenTrack);
    await _applyScreenCodecPreference(screenTrack, profile);

    // Second layer: setParameters with the same cap (also carries the
    // degradationPreference, which transceiver init cannot). Re-applied
    // post-connect either way — see _scheduleResolutionCapEnforcement.
    await _applyResolutionCap(width, height, fps, profile);

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
      // The portal grant now exists (or was just re-used) — the next share
      // this run can offer "same as last time" without a portal prompt.
      if (DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        DesktopCaptureSupport.portalGrantLikely = true;
      }
    }
  }

  /// Push the content profile down to the native encoder pipeline as a W3C
  /// contentHint. Windows + Linux: the hint rides our patched libwebrtc
  /// binaries (RTCVideoTrack::SetContentHint, vendored in third_party);
  /// darwin/Android capture sources already carry the screencast flag
  /// natively and have no wrapper hint API.
  ///
  /// text → 'detail' (screencast pipeline, explicitly). motion → '' (defer
  /// to the source's is_screencast=true, which our patched desktop capture
  /// source now sets — screencast pipeline with framerate-first
  /// degradation). We deliberately never send 'motion': it would force the
  /// CAMERA pipeline (denoising + QP quality scaler) back on.
  Future<void> _applyContentHint(MediaStreamTrack screenTrack) async {
    if (!Platform.isWindows && !Platform.isLinux) return;
    final hint = _contentProfile == ScreenContentProfile.text ? 'detail' : '';
    try {
      await Helper.setVideoContentHint(screenTrack, hint);
      _log('[HOLLOW-SCREEN] contentHint="$hint" applied '
          '(profile=${_contentProfile.name})');
    } catch (e) {
      _log('[HOLLOW-SCREEN] contentHint set failed (ignored): $e');
    }
  }

  /// Order codec preferences for the screen-share sender (desktop senders
  /// only — mobile hardware encoder support varies; leave its defaults alone).
  ///
  /// - macOS: VP8 first (Apple's H.264 hardware encoder can emit a profile
  ///   that Windows libwebrtc's software decoder renders as pure black with
  ///   no error; VP8 has no profile axis), VP9 second.
  /// - Windows/Linux: VP9 first (≈2x VP8's quality-per-bit on screen
  ///   content), VP8 as the universal fallback. For the TEXT profile AV1
  ///   leads: it has actual screen-content tools (palette mode) and its
  ///   software encode is cheap at text-profile framerates. Receivers
  ///   without AV1/VP9 fall back through normal SDP negotiation.
  Future<void> _applyScreenCodecPreference(
      MediaStreamTrack screenTrack, ScreenContentProfile profile,
      {bool vp8Only = false}) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      final caps = await getRtpSenderCapabilities('video');
      final codecs = caps.codecs ?? [];
      if (codecs.isEmpty) return;

      int rank(RTCRtpCodecCapability c) {
        final mime = c.mimeType.toLowerCase();
        // Simulcast ingest legs (phase 3): VP8 first, unconditionally — the
        // forwarder's layer-switch descriptor rewrite is VP8-only, and VP8
        // is the codec the fwd lane is field-proven on.
        if (vp8Only) return mime == 'video/vp8' ? 0 : 1;
        if (Platform.isMacOS) {
          if (mime == 'video/vp8') return 0;
          if (mime == 'video/vp9') return 1;
          return 2;
        }
        if (profile == ScreenContentProfile.text && mime == 'video/av1') {
          return 0;
        }
        if (mime == 'video/vp9') return 1;
        if (mime == 'video/vp8') return 2;
        return 3;
      }

      // Stable bucket ordering (List.sort is not stable in Dart — rtx/red/
      // ulpfec entries must keep their relative order).
      final buckets = <int, List<RTCRtpCodecCapability>>{};
      for (final c in codecs) {
        buckets.putIfAbsent(rank(c), () => []).add(c);
      }
      final ordered = [
        for (final k in buckets.keys.toList()..sort()) ...buckets[k]!,
      ];

      final transceivers = await _pc!.getTransceivers();
      for (final t in transceivers) {
        if (t.sender.track?.id == screenTrack.id) {
          await t.setCodecPreferences(ordered);
          _log('[HOLLOW-SCREEN] Codec preference: '
              '${ordered.take(3).map((c) => c.mimeType).join(' > ')} '
              '(profile=${profile.name})');
          break;
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
  ///
  /// [simulcast] (phase 3, forwarder ingest legs only): encode TWO rid
  /// layers — 'q' (half per axis, protected under congestion by riding
  /// first) + 'f' (the cap) — so the forwarder engine can pick per-viewer
  /// layers by packet selection. Simulcast legs are constrained to VP8: the
  /// engine's layer-switch rewrite is VP8-descriptor-only, and VP8 is the
  /// codec the whole forwarder lane is field-proven on.
  Future<String> createOfferFromStream(
    MediaStream stream, {
    int maxWidth = 1920,
    int maxHeight = 1080,
    int fps = 60,
    ScreenContentProfile profile = ScreenContentProfile.motion,
    bool simulcast = false,
  }) async {
    _log('[HOLLOW-SCREEN] Creating offer from shared stream '
        '(profile=${profile.name}${simulcast ? ', simulcast f+q' : ''})');
    _contentProfile = profile;
    _simulcast = simulcast;

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

      // Add screen video track WITH the resolution cap as init sendEncodings
      // (see createOffer for why this must ride the transceiver init).
      await _pc!.addTransceiver(
        track: screenTrack,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: [_screenStream!],
          sendEncodings: simulcast
              ? _buildSimulcastSendEncodings(
                  screenTrack, maxWidth, maxHeight, fps)
              : [
                  _buildScreenSendEncoding(
                      screenTrack, maxWidth, maxHeight, fps),
                ],
        ),
      );
      _log('[HOLLOW-SCREEN] Added screen video transceiver '
          '(init cap ${maxWidth}x$maxHeight@${fps}fps'
          '${simulcast ? ' + q layer' : ''})');

      await _applyContentHint(screenTrack);
      await _applyScreenCodecPreference(screenTrack, profile,
          vp8Only: simulcast);

      // Second layer: setParameters (degradationPreference + cap re-assert).
      await _applyResolutionCap(maxWidth, maxHeight, fps, profile);

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

    // Stop the liveness watchdog FIRST: a planned teardown must never be
    // reported as a suspected crash.
    _stopLivenessWatchdog();

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
    _capWidth = null;
    _capHeight = null;
    _capFps = null;
    _simulcast = false;
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
      types: DesktopCaptureSupport.sourceTypes,
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
        _scheduleResolutionCapEnforcement();
        _startLivenessWatchdog();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _stopLivenessWatchdog();
        onDisconnected?.call();
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Hold, do not tear down.
        //
        // `disconnected` means ICE consent has gone unanswered for a couple of
        // seconds, which a Wi-Fi stutter produces routinely and which clears
        // itself most of the time. Firing the recovery ladder here rebuilt a
        // leg that was about to heal, and every rebuild is a visible blink in
        // the share plus a fresh SFrame binding.
        //
        // Nothing is lost by waiting, because the consent watchdog above is
        // still running and is the STRICTER test: it declares the leg dead
        // after three seconds of no inbound activity on the nominated pair,
        // which is exactly what a genuinely dead leg looks like and is still
        // ahead of libwebrtc's own 5 to 7 second expiry. A leg that recovers
        // never reaches it.
        _log('[HOLLOW-SCREEN] transport disconnected — holding the leg while '
            'the consent watchdog decides');
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Fast failover: ICE-consent staleness watchdog
  // ---------------------------------------------------------------------------
  //
  // When the peer at the other end of a screen leg CRASHES, the recovery is
  // same-second (field-proven) but the DETECTION is not: libwebrtc only gives
  // up when ICE consent expires, which measured ~5-7 s of frozen picture. This
  // watchdog shortens that to ~2.5-3.5 s.
  //
  // CRITICAL — the signal is ICE CONSENT, never media bytes. A static screen
  // share is legitimately silent for minutes at a time, so "no frames" says
  // nothing about liveness. ICE consent checks (STUN binding requests) run
  // continuously regardless of media, so a candidate pair whose
  // responses/packets stop advancing is genuinely unreachable.
  //
  // Conservative by construction: TWO consecutive stale polls are required,
  // and a false positive costs one blink (the recovery paths are all
  // idempotent re-requests) rather than a lost stream.

  Timer? _livenessTimer;

  /// Fingerprint of the nominated pair's inbound counters, and the local clock
  /// reading when it last CHANGED. Staleness is "nothing has moved for N
  /// seconds by OUR clock" — never a comparison against a timestamp reported
  /// by the stats themselves, whose unit is not ours to assume (this fork
  /// reports stats timestamps in MICROseconds; an earlier version of this
  /// check compared one against `DateTime.now().millisecondsSinceEpoch`, went
  /// permanently negative, and silently read as "always fresh" — the watchdog
  /// never fired once in the field).
  String? _livenessFingerprint;
  DateTime? _livenessLastMovement;

  /// Timer.periodic does not await an async callback, so a slow `getStats()`
  /// could otherwise overlap the next tick.
  bool _livenessPollInFlight = false;

  /// Logged once per PC: which inbound counters this build actually exposes.
  /// If none are, the watchdog disables itself loudly rather than pretending.
  bool _livenessMembersLogged = false;

  /// How long every inbound counter must sit still before we call the leg
  /// dead. ICE consent checks run about every 2.5 s and RTCP receiver reports
  /// about every 1 s, so 3 s of total silence is well past normal quiet —
  /// while still beating libwebrtc's own ~5-7 s consent expiry.
  static const _kConsentStaleAfter = Duration(seconds: 3);

  /// Inbound counters, most decisive first. Whichever exist are combined into
  /// the fingerprint; all of them stall when the far end stops answering.
  /// Deliberately NOT media-only counters alone — a static screen share is
  /// legitimately silent, which is why ICE consent is the primary signal.
  static const _kLivenessMembers = <String>[
    'responsesReceived',
    'requestsReceived',
    'packetsReceived',
    'bytesReceived',
  ];

  void _startLivenessWatchdog() {
    _stopLivenessWatchdog();
    final watched = _pc;
    if (watched == null) return;
    _livenessTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (watched != _pc) {
        // Torn down or replaced meanwhile (close() nulls _pc).
        t.cancel();
        return;
      }
      if (_livenessPollInFlight) return;
      _livenessPollInFlight = true;
      final bool stale;
      try {
        stale = await _consentLooksStale(watched);
      } finally {
        _livenessPollInFlight = false;
      }
      if (watched != _pc) {
        // Torn down or replaced meanwhile (close() nulls _pc).
        t.cancel();
        return;
      }
      if (!stale) return;
      t.cancel();
      _livenessTimer = null;
      _log('[HOLLOW-SCREEN] suspect-fast: no inbound activity on the nominated '
          'pair for ${_kConsentStaleAfter.inSeconds}s — declaring the leg dead '
          'ahead of libwebrtc');
      // Deliberately does NOT close the PC: the callback owner decides what
      // recovery means for its role (a viewer walks its ladder, a sharer
      // reverts its branch), exactly as it does for a real ICE death.
      onDisconnected?.call();
    });
  }

  void _stopLivenessWatchdog() {
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _livenessFingerprint = null;
    _livenessLastMovement = null;
    _livenessPollInFlight = false;
    _livenessMembersLogged = false;
  }

  /// True when NOTHING has arrived on the nominated candidate pair for
  /// [_kConsentStaleAfter], measured on OUR clock.
  ///
  /// Deliberately unit-agnostic: it only asks "did these counters change since
  /// the last poll?", never "how old is this reported timestamp?". The stats
  /// timestamps in this fork are microseconds, and mixing that with a
  /// millisecond wall clock is what made the first version of this check read
  /// as permanently fresh.
  ///
  /// The primary signal is ICE consent (`responsesReceived` / `requestsReceived`),
  /// which keeps ticking regardless of media — a static screen share sends
  /// almost nothing, so media counters alone would call a healthy leg dead.
  Future<bool> _consentLooksStale(RTCPeerConnection pc) async {
    try {
      final stats = await pc.getStats();
      StatsReport? pair;
      for (final r in stats) {
        if (r.type != 'candidate-pair') continue;
        if (r.values['state'] != 'succeeded') continue;
        pair = r;
        if (r.values['nominated'] == true) break;
      }
      if (pair == null) return false; // nothing to judge yet

      final parts = <String>[];
      for (final name in _kLivenessMembers) {
        final v = pair.values[name];
        if (v is num) parts.add('$name=$v');
      }

      if (parts.isEmpty) {
        // This build exposes none of the counters we can reason about. Say so
        // ONCE and stand down — a watchdog that silently never fires is worse
        // than no watchdog, because it looks like it is working.
        if (!_livenessMembersLogged) {
          _livenessMembersLogged = true;
          _log('[HOLLOW-SCREEN] liveness watchdog DISABLED — candidate-pair '
              'exposes none of $_kLivenessMembers (available: '
              '${pair.values.keys.toList()})');
          _stopLivenessWatchdog();
        }
        return false;
      }

      if (!_livenessMembersLogged) {
        _livenessMembersLogged = true;
        _log('[HOLLOW-SCREEN] liveness watchdog armed on ${parts.length} '
            'counter(s): ${parts.join(' ')}');
      }

      final now = DateTime.now();
      final fingerprint = parts.join('|');
      if (fingerprint != _livenessFingerprint) {
        _livenessFingerprint = fingerprint;
        _livenessLastMovement = now;
        return false;
      }
      final since = _livenessLastMovement;
      if (since == null) {
        _livenessLastMovement = now;
        return false;
      }
      return now.difference(since) >= _kConsentStaleAfter;
    } catch (_) {
      // getStats throws once the PC is closed; the real state handler owns
      // that case.
      return false;
    }
  }

  /// Post-connect enforcement + verification of the resolution cap (outgoing
  /// shares only — no-op when no cap was requested on this PC).
  ///
  /// A live setParameters on a NEGOTIATED sender is the one path the spec
  /// requires to work, so 2s after connect we re-apply the cap — with the
  /// true capture size read from media-source stats, since getSettings() can
  /// be empty for desktop captures — and read the sender's parameters back.
  /// 3s later we log what the encoder ACTUALLY emits (outbound-rtp
  /// frameWidth/frameHeight) with a clear applied/not-applied verdict.
  void _scheduleResolutionCapEnforcement() {
    final screenPc = _pc;
    if (screenPc == null || _capWidth == null) return;
    Future.delayed(const Duration(seconds: 2), () async {
      if (screenPc != _pc) return; // Torn down or replaced meanwhile.
      await _reapplyResolutionCap(screenPc);
      await Future.delayed(const Duration(seconds: 3));
      if (screenPc != _pc) return;
      await _logEncodedResolution(screenPc);
    });
  }

  Future<bool> _reapplyResolutionCap(RTCPeerConnection screenPc) async {
    try {
      int? srcW, srcH;
      final stats = await screenPc.getStats();
      for (final report in stats) {
        final kind = report.values['kind'] ?? report.values['mediaType'];
        if (report.type == 'media-source' && kind == 'video') {
          srcW = (report.values['width'] as num?)?.toInt();
          srcH = (report.values['height'] as num?)?.toInt();
          break;
        }
      }
      _log('[HOLLOW-SCREEN] Post-connect cap re-apply: capture=${srcW}x$srcH '
          'cap=${_capWidth}x$_capHeight@${_capFps}fps');
      final applied = await _applyResolutionCap(
          _capWidth!, _capHeight!, _capFps!, _contentProfile,
          captureWidth: srcW, captureHeight: srcH);

      // Read back what the sender now reports — did the scale survive?
      final senders = await screenPc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          final encodings = sender.parameters.encodings ?? const [];
          final desc = encodings
              .map((e) => 'scale=${e.scaleResolutionDownBy} '
                  'maxBr=${e.maxBitrate} minBr=${e.minBitrate} '
                  'maxFps=${e.maxFramerate}')
              .join(' | ');
          _log('[HOLLOW-SCREEN] Sender params readback: '
              '${encodings.isEmpty ? 'NO ENCODINGS' : desc}');
          break;
        }
      }
      return applied;
    } catch (e) {
      _log('[HOLLOW-SCREEN] Post-connect cap re-apply failed: $e');
      return false;
    }
  }

  Future<void> _logEncodedResolution(RTCPeerConnection screenPc) async {
    try {
      final stats = await screenPc.getStats();
      // SIMULCAST: there is one outbound-rtp per LAYER. Reporting only the
      // first one is how a dead `f` layer hid behind a healthy-looking
      // "CAP APPLIED" for the q layer (field 2026-08-15) — the diagnostic said
      // the cap was applied while the branch was actually serving half
      // resolution. Report every layer, and judge the cap against the LARGEST
      // one that is actually encoding.
      final layers = <String>[];
      int? bestLong;
      int? bestW, bestH;
      String? limit;
      for (final report in stats) {
        final kind = report.values['kind'] ?? report.values['mediaType'];
        if (report.type != 'outbound-rtp' || kind != 'video') continue;
        final w = (report.values['frameWidth'] as num?)?.toInt();
        final h = (report.values['frameHeight'] as num?)?.toInt();
        final fps = report.values['framesPerSecond'];
        final rid = report.values['rid'] as String?;
        limit ??= report.values['qualityLimitationReason'] as String?;
        layers.add('${rid ?? '-'}:${w ?? '?'}x${h ?? '?'}@${fps ?? '?'}fps');
        if (w != null && h != null) {
          final long = w > h ? w : h;
          if (bestLong == null || long > bestLong) {
            bestLong = long;
            bestW = w;
            bestH = h;
          }
        }
      }
      if (layers.isEmpty) {
        _log('[HOLLOW-SCREEN] Encoded output: no outbound-rtp video stats');
        return;
      }
      final capW = _capWidth, capH = _capHeight;
      // Compare LONG edges so portrait window shares don't false-fail;
      // small tolerance for encoder rounding.
      final capLongEdge = (capW ?? 0) > (capH ?? 0) ? capW : capH;
      final verdict = bestLong == null
          ? 'no frames encoded yet'
          : (capLongEdge != null && bestLong <= capLongEdge * 1.05 + 16)
              ? 'CAP APPLIED'
              : 'CAP NOT APPLIED';
      final top = bestW == null ? '?' : '${bestW}x$bestH';
      _log('[HOLLOW-SCREEN] Encoded output: ${layers.length} layer(s) '
          '[${layers.join(', ')}] top=$top limit=$limit '
          'cap=${capW}x$capH -> $verdict');
    } catch (e) {
      _log('[HOLLOW-SCREEN] Encoded resolution check failed: $e');
    }
  }

  /// Log which ICE route (TURN/STUN/LAN) the connected PC ended up on.
  /// Diagnostic only.
  void _scheduleIceRouteLog() {
    if (_pc == null) return;
    _logIceRoute();
  }

  Future<void> _logIceRoute() async {
    // Resolve _pc per attempt — a renegotiation can replace it mid-probe.
    final route = await probeIceRoute(() => _pc);
    // Forwarder legs get their own label (D6 follow-up #1): the probe's
    // TURN/STUN/LAN taxonomy describes DIRECT lanes, and a blind-forwarder
    // hop mislabels there (worst case "TURN (relayed)" on an Always-relay
    // client — forwarder legs are exempt from forced TURN by design).
    final prefix = forwarderLeg
        ? '[HOLLOW-SCREEN] ICE route: Forwarder leg (blind relay hop) — '
        : '[HOLLOW-SCREEN] ICE route: ';
    _log(route == null
        ? '${prefix}no succeeded candidate pair found'
        : forwarderLeg
            ? '${prefix}pair ${route.detail}'
            : '$prefix$route');
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
