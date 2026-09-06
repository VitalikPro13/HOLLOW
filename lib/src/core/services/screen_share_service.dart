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

/// What the shared content mostly is, which drives encoder tuning.
///
/// [text] (code, documents, UI) drops FRAMES under pressure and keeps
/// resolution, since blocky text is the visible failure mode; it prefers
/// AV1/VP9 and defaults to 15 fps. [motion] (gameplay, video) keeps
/// FRAMERATE instead, prefers VP9 and defaults to 60 fps.
enum ScreenContentProfile { text, motion }

/// Manages a dedicated RTCPeerConnection for ONE direction of screen sharing.
///
/// One instance per direction, because reusing the voice call's PC produces
/// transceiver conflicts. Outgoing: [createOffer] then [handleAnswer].
/// Incoming: [handleOffer], and the renderer appears via [remoteRenderer].
class ScreenShareService {
  final String localPeerId;
  final Map<String, dynamic> iceServers;

  /// True when this PC is a media-forwarder leg. Labels the ICE-route log:
  /// route probing cannot tell a forwarder hop from a direct pair, and on an
  /// Always-relay client the old label even read "TURN (relayed)".
  final bool forwarderLeg;

  RTCPeerConnection? _pc;
  MediaStream? _screenStream; // Local screen capture (outgoing only)
  // Whether THIS service owns _screenStream and must dispose it on close().
  // False for createOfferFromStream, where one capture is SHARED across many
  // per-peer services: disposing it here kills every other peer's share and
  // double-frees it, the `corrupted size vs prev_size` abort on share stop.
  bool _ownsScreenStream = true;
  // Whether _remoteStream was SYNTHESIZED by us. We may dispose only those;
  // libwebrtc owns the event-provided streams.
  bool _remoteStreamIsSynthetic = false;
  RTCVideoRenderer? _localRenderer; // Self-preview of outgoing screen
  RTCVideoRenderer? _remoteRenderer; // Renderer for incoming screen
  MediaStream? _remoteStream;
  Timer? _screenTrackPoller;

  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  void Function(RTCIceCandidate candidate)? onIceCandidate;
  void Function()? onConnected;
  void Function()? onDisconnected;
  void Function()? onRemoteTrackReady;
  void Function()? onScreenShareEnded; // Track ended (window closed)

  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;
  RTCVideoRenderer? get localRenderer => _localRenderer;
  RTCPeerConnection? get pc => _pc;
  bool get isActive => _pc != null;

  /// True once the macOS system-audio tap is active, so we stop it once.
  bool _macSystemAudioActive = false;

  /// Preferred audio output device, set by CallNotifier before handleOffer.
  String? preferredAudioOutputDeviceId;

  /// Content profile of the current outgoing share, set by both offer paths.
  ScreenContentProfile _contentProfile = ScreenContentProfile.motion;

  /// Last requested resolution/fps cap for the OUTGOING share; null on an
  /// incoming-only PC.
  int? _capWidth;
  int? _capHeight;
  int? _capFps;

  /// This outgoing PC carries a 2-layer simulcast (forwarder ingest legs
  /// only). A cap change must keep BOTH layers consistent.
  bool _simulcast = false;

  ScreenAudioCapturer? _screenAudioCapturer;
  MacSckScreenAudioCapturer? _macSckAudioCapturer;
  MobileScreenAudioCapturer? _mobileAudioCapturer;


  ScreenShareService({
    required this.localPeerId,
    required this.iceServers,
    this.forwarderLeg = false,
  });

  /// Effective per-viewer resolution cap: the share's cap clamped to what
  /// THIS viewer's display can show. Compared on orientation-normalized
  /// long/short edges so a portrait phone is not over-restricted watching a
  /// landscape share, then mapped back into the share cap's orientation. A
  /// 0x0 viewer size means unknown and leaves the share cap untouched.
  ///
  /// There is deliberately NO per-viewer "Source quality" opt-out: the clamp
  /// is keyed to the viewer's largest MONITOR, so it already delivers every
  /// pixel they can display, and on a shared forwarder branch there is no
  /// per-viewer encoder for an opt-out to apply to.
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

  /// Simulcast layer choice for ONE viewer on a forwarder branch: true = the
  /// low layer (rid `q`, downscaled 2x per axis), false = the full layer `f`.
  ///
  /// [viewerCapWidth]/[viewerCapHeight] is that viewer's ALREADY-EFFECTIVE
  /// cap; the caller owns that math so this stays the single half-cap
  /// comparison the field verified.
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

  /// Live-updates the outgoing resolution cap on a negotiated sender, for a
  /// viewer whose display or wishes changed. Writes _capWidth/_capHeight
  /// FIRST so post-connect enforcement re-applies THIS cap rather than
  /// reverting it.
  ///
  /// False when the sender REJECTED the change: the caller must then tear
  /// this service down and renegotiate with the new cap in the init
  /// encodings. True when nothing changed or the update was accepted.
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

  /// Waits for ICE gathering and returns the full local SDP.
  ///
  /// Forwarder legs exchange COMPLETE SDPs: the forwarder sits on a fixed
  /// public host candidate and has no trickle lane. Falls back to whatever
  /// has gathered when [timeout] lapses. A leg whose SDP leaves with zero
  /// candidates can never connect and ICE then fails SILENTLY, with no state
  /// transitions at all, so the candidate count is logged here deliberately.
  Future<String?> gatheredLocalSdp(
      {Duration timeout = const Duration(seconds: 10)}) async {
    final pc = _pc;
    if (pc == null) return null;
    final deadline = DateTime.now().add(timeout);
    String? sdp;
    // Wait for CANDIDATES, not for gatheringState == complete: this fork
    // routinely sits in `gathering` indefinitely with candidates already in
    // the local description, which turned every forwarder leg into a flat
    // 10-second stall. The settle poll picks up the srflx behind the host.
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

  /// Applies resolution, framerate and bitrate caps on the video sender's
  /// encoding. The desktop capturer can still deliver native-resolution
  /// frames despite the getDisplayMedia constraints, so this is layer two.
  ///
  /// [captureWidth]/[captureHeight] override track.getSettings() when the
  /// caller knows better: getSettings is absent for desktop captures on some
  /// platforms and the 1920x1080 fallback computes a wrong scale. Returns
  /// whether the sender ACCEPTED setParameters; a caller that needs the cap
  /// to actually change must renegotiate on false.
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

        // Text must stay SHARP: under pressure drop frames, never
        // resolution (maintain-resolution is the W3C mapping for
        // detail/text screen content). Motion is the opposite, since a
        // slideshow hurts more than transient blur.
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
  /// when the platform reports nothing. Logged loudly, because a wrong
  /// assumption here computes a wrong scale factor.
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

  /// Builds the send encoding handed to addTransceiver. Encodings supplied
  /// at transceiver-init time are the path libwebrtc reliably folds into the
  /// sender across offer/answer; a pre-negotiation setParameters is NOT,
  /// which is how the receiver ended up with native resolution. [rid] tags a
  /// simulcast layer.
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

  /// The two simulcast layers for a forwarder ingest leg, LOW FIRST:
  /// libwebrtc's rate allocator protects encodings[0] under congestion, and
  /// the small layer is the one every branch viewer must keep receiving. Rid
  /// names are the forwarder contract: 'f' = the branch cap, 'q' = half.
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

  /// Configures one encoding: downscale to the cap, pin the framerate, set
  /// the bitrate tier for the target size.
  void _configureVideoEncoding(
    RTCRtpEncoding encoding,
    int captureWidth,
    int captureHeight,
    int maxWidth,
    int maxHeight,
    int fps,
  ) {
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
    // Floor the allocation too: after congestion the bandwidth estimator
    // ramps back slowly, and with no floor the encoder sits at a starvation
    // bitrate long after the link recovers, text turning to QP mush.
    final minBitrateKbps = _minBitrateKbpsFor(maxWidth, maxHeight);
    encoding.minBitrate = minBitrateKbps * 1000; // bps
    _log('[HOLLOW-SCREEN] Set bitrate=$minBitrateKbps-${maxBitrateKbps}kbps '
        'maxFramerate=${fps}fps for ${maxWidth}x$maxHeight');
  }

  /// Bitrate tiers, higher than camera because screen content has sharp
  /// edges and text that compress poorly.
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

  /// Minimum bitrate floor per tier: high enough that a stale low bandwidth
  /// estimate cannot starve the encoder into blockiness, low enough not to
  /// overrun a genuinely narrow (TURN-relayed) link.
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

  // Outgoing: we share our screen to the remote peer.

  /// Captures the screen, builds a fresh PC, and returns the SDP offer.
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

    // Idempotent: tear down any prior PC and stream first, so a re-share on
    // the same instance cannot strand the old PeerConnection's thread-set.
    if (_pc != null || _screenStream != null || _localRenderer != null) {
      await close();
    }

    await _requestMacCapturePermissionIfNeeded();

    // Source enumeration is desktop-only; mobile captures THE screen. A
    // Wayland portal-first share MUST NOT re-enumerate: the native side
    // resolves the sentinel id, and enumerating pops an extra portal dialog.
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !DesktopCaptureSupport.isPortalSourceId(sourceId)) {
      await desktopCapturer.getSources(
          types: DesktopCaptureSupport.sourceTypes);
    }

    // Audio never rides getDisplayMedia: the WASAPI path crashes on Windows,
    // is unavailable on macOS, yields nothing on Linux, and on mobile a
    // WebRTC track would drag music through the voice-comm AEC/AGC. Every
    // platform sends share audio over the 0x03 data channel instead.
    //
    // On macOS that is ScreenCaptureKit, deliberately NOT the 14.2+ CoreAudio
    // Process Tap, which injects into the system default input that our
    // CoreAudio ADM does not follow and so fed 0 tracks. Below 13.0 there is
    // no capture API at all and the UI locks the toggle off.
    final useDataChannelAudio = shareAudio &&
        (Platform.isWindows ||
            Platform.isLinux ||
            Platform.isAndroid ||
            Platform.isIOS ||
            (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio));
    final getDisplayAudio = shareAudio && !useDataChannelAudio;

    await _captureScreenStream(sourceId, width, height, fps, getDisplayAudio);

    final videoTracks = _screenStream!.getVideoTracks();
    if (videoTracks.isEmpty) {
      _log('[HOLLOW-SCREEN] getDisplayMedia returned no video tracks — aborting');
      await _screenStream!.dispose();
      _screenStream = null;
      throw StateError('Screen capture returned no video tracks');
    }
    final screenTrack = videoTracks.first;
    _log('[HOLLOW-SCREEN] Got screen track: ${screenTrack.id}');

    _localRenderer = RTCVideoRenderer();
    await _localRenderer!.initialize();
    _localRenderer!.srcObject = _screenStream;

    _pc = await createPeerConnection(iceServers);
    _setupCallbacks();

    // The cap rides the transceiver INIT encodings: the only pre-negotiation
    // channel libwebrtc reliably folds into the sender at offer/answer.
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

    // Second layer: setParameters also carries degradationPreference, which
    // transceiver init cannot. Re-applied post-connect either way.
    await _applyResolutionCap(width, height, fps, profile);

    await _addCapturedAudioTracks(shareAudio);

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    _log('[HOLLOW-SCREEN] Offer created, SDP length=${offer.sdp?.length}');

    // Poll for track ending (onEnded not wired on native desktop).
    _startTrackPoller();

    return offer.sdp!;
  }

  /// macOS and Android need explicit screen-capture permission before any
  /// source enumeration. On macOS the first attempt always returns false,
  /// the user grants in System Settings, and the next launch reads granted.
  /// Web, Windows and Linux just return true.
  Future<void> _requestMacCapturePermissionIfNeeded() async {
    if (!Platform.isMacOS) return;
    try {
      final granted = await Helper.requestCapturePermission();
      _log('[HOLLOW-SCREEN] macOS screen recording permission: $granted');
      // Debug builds are ad-hoc signed and every rebuild gets a fresh
      // signature, so TCC reports granted=false until the user re-grants.
      // Try the capture anyway: ScreenCaptureKit surfaces its own error.
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
      // The Android plugin ignores constraints (MediaProjection captures at
      // native size); the encoder cap below does the downscaling.
      _screenStream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
    } else if (Platform.isIOS) {
      // 'broadcast' selects the ReplayKit Broadcast Upload Extension: whole
      // screen plus app audio, and it keeps running when Hollow is
      // backgrounded. It auto-presents RPSystemBroadcastPickerView.
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
      // The portal grant now exists, so the next share this run can offer
      // "same as last time" without a prompt.
      if (DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        DesktopCaptureSupport.portalGrantLikely = true;
      }
    }
  }

  /// Pushes the content profile down as a W3C contentHint. The hint rides
  /// our patched libwebrtc on Windows and Linux; darwin and Android capture
  /// sources already carry the screencast flag natively.
  ///
  /// text sets 'detail'; motion sets '' and defers to the source's
  /// is_screencast. We deliberately never send 'motion': it would force the
  /// CAMERA pipeline (denoising, QP quality scaler) back on.
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

  /// Orders codec preferences for a DESKTOP screen-share sender; mobile
  /// hardware encoder support varies, so its defaults are left alone.
  ///
  /// macOS puts VP8 first because Apple's H.264 hardware encoder can emit a
  /// profile that Windows libwebrtc's software decoder renders as pure black
  /// with no error. Windows and Linux put VP9 first (about twice VP8's
  /// quality-per-bit on screen content), and AV1 leads for TEXT, which has
  /// real screen-content tools. Receivers without them fall back through SDP.
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
        // Simulcast ingest legs are VP8-only: the forwarder's layer-switch
        // descriptor rewrite is VP8-only, and VP8 is what the lane is
        // field-proven on.
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

      // List.sort is not stable in Dart, and rtx/red/ulpfec entries must
      // keep their relative order.
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

  /// Adds any audio tracks getDisplayMedia delivered (macOS Process Tap
  /// path). Logs when audio was requested but no track is available.
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

  /// Creates an offer from a pre-captured screen stream, for voice channels
  /// where one capture is shared across many peer connections. The caller
  /// manages the track poller.
  ///
  /// [simulcast] encodes TWO rid layers, 'q' first so congestion protects
  /// it, letting the forwarder engine pick per-viewer layers by packet
  /// selection. Simulcast legs are constrained to VP8.
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

    // Idempotent: tear an existing PC down before building a new one, or its
    // libwebrtc thread-set leaks on a re-fired offer.
    if (_pc != null || _localRenderer != null || _remoteRenderer != null) {
      await close();
    }

    // The caller owns this shared capture stream; do NOT dispose it here.
    _ownsScreenStream = false;
    _screenStream = stream;

    try {
      final screenTrack = _screenStream!.getVideoTracks().first;
      _log('[HOLLOW-SCREEN] Using shared screen track: ${screenTrack.id}');

      _localRenderer = RTCVideoRenderer();
      await _localRenderer!.initialize();
      _localRenderer!.srcObject = _screenStream;

      _pc = await createPeerConnection(iceServers);
      _setupCallbacks();

      // The cap rides the transceiver init encodings (see createOffer).
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

      // Second layer: setParameters, degradationPreference and cap re-assert.
      await _applyResolutionCap(maxWidth, maxHeight, fps, profile);

      // macOS Process Tap audio arrives as tracks.
      final audioTracks = _screenStream!.getAudioTracks();
      if (audioTracks.isNotEmpty) {
        for (final track in audioTracks) {
          await _pc!.addTrack(track, _screenStream!);
        }
        _log('[HOLLOW-SCREEN] Added ${audioTracks.length} audio track(s)');
      }

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);

      _log('[HOLLOW-SCREEN] Offer created, SDP length=${offer.sdp?.length}');

      // No track poller: the caller manages one for the shared stream.
      return offer.sdp!;
    } catch (e) {
      // Dispose the partially-built PC and renderer, but not the shared
      // stream, before propagating.
      _log('[HOLLOW-SCREEN] createOfferFromStream failed, tearing down: $e');
      await close();
      rethrow;
    }
  }

  /// Handles the remote peer's SDP answer on our outgoing PC.
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

  // Incoming: the remote peer shares their screen to us.

  /// Handles the remote peer's SDP offer, wires onTrack for the remote
  /// screen renderer, and returns the SDP answer.
  Future<String> handleOffer(String sdp) async {
    _log('[HOLLOW-SCREEN] Handling incoming screen offer');

    // Idempotent: a re-fired offer for the same peer must not strand the
    // prior PC on this instance.
    if (_pc != null) {
      await close();
    }

    try {
      _pc = await createPeerConnection(iceServers);
      _setupCallbacks();

      _pc!.onTrack = (event) {
        _log('[HOLLOW-SCREEN] Remote track: ${event.track.kind} '
            'id=${event.track.id} streams=${event.streams.length}');

        if (event.track.kind == 'video') {
          _handleRemoteVideoTrack(event);
        }
      };

      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
      await _flushPendingCandidates();

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      // Route audio to the preferred output device, as a voice call does.
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
      // A throw here (an unsupported remote SDP codec, say) leaves a live PC
      // and its thread-set stranded. Dispose before propagating.
      _log('[HOLLOW-SCREEN] handleOffer failed, tearing down: $e');
      await close();
      rethrow;
    }
  }

  /// Adds an ICE candidate, queued when the remote description is not set.
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

  // Screen audio capture, streamed over the 0x03 data channel.

  /// Starts system-audio capture and Opus encoding; packets reach [onPacket]
  /// for the data channel.
  ///
  /// Windows and Linux use the out-of-process exe, since a separate process
  /// keeps libwebrtc's AudioDeviceModule out of the WASAPI capture; on Linux
  /// a window share INCLUDEs only the shared app's process tree and an
  /// entire-screen share EXCLUDEs Hollow's own, for anti-echo. macOS 13.0+
  /// uses ScreenCaptureKit. Below that there is no capture API and the UI
  /// locks the toggle off, so this is a no-op.
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

    // macOS 13.0+: ScreenCaptureKit (the Process Tap is retired).
    if (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio) {
      await _startMacSckAudioCapturer(onPacket);
      return;
    }

    // Mobile: native capture, PCM to Dart, Rust Opus encode, onPacket.
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

  /// Close the PC, stop tracks, dispose renderers. Safe to call multiple times.
  Future<void> close() async {
    _log('[HOLLOW-SCREEN] Closing screen share service');

    // Stop the watchdog FIRST: a planned teardown is not a suspected crash.
    _stopLivenessWatchdog();

    await _stopScreenAudioCapture();

    await _disableMacSystemAudioTap();

    _screenTrackPoller?.cancel();
    _screenTrackPoller = null;

    // Teardown is DEFENSIVE: each native disposal is wrapped so one failure
    // cannot abort the rest and leak the PC. On Linux `RTCVideoRenderer
    // .dispose()` throws when the texture is already gone, and that uncaught
    // throw used to crash the app on share stop. Null a field BEFORE
    // awaiting so a re-entrant close() cannot double-free.

    final localRenderer = _localRenderer;
    _localRenderer = null;
    await _disposeRendererSafely(localRenderer, 'local renderer');

    await _disposeOwnedScreenStream();

    final remoteRenderer = _remoteRenderer;
    _remoteRenderer = null;
    await _disposeRendererSafely(remoteRenderer, 'remote renderer');

    await _disposeSyntheticRemoteStream();

    await _closeAndDisposePc();

    // Restore ownership defaults so the next use of this instance is clean.
    _ownsScreenStream = true;
    _remoteStreamIsSynthetic = false;

    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
    _capWidth = null;
    _capHeight = null;
    _capFps = null;
    _simulcast = false;
  }

  /// Tears down the macOS system audio tap first, so the system default
  /// input reverts before we stop the streams.
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

  /// Stops local screen capture ONLY if we own it. For createOfferFromStream
  /// the capture is shared and owned by the provider: disposing it here
  /// kills every other peer's share AND double-frees it.
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

  /// Disposes the remote stream ONLY if we synthesized it; libwebrtc owns
  /// the event-provided ones and disposing those double-frees. The reference
  /// is nulled either way.
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

  /// close() and dispose() get SEPARATE guards: if close() throws on an
  /// already-failing native PC, dispose() must still run, or the libwebrtc
  /// threads leak.
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
        // Hold, do not tear down. `disconnected` means ICE consent has gone
        // unanswered for a couple of seconds, which a Wi-Fi stutter produces
        // routinely and which clears itself most of the time; rebuilding
        // here costs a visible blink and a fresh SFrame binding for nothing.
        //
        // Nothing is lost by waiting: the consent watchdog above is the
        // STRICTER test and declares a genuinely dead leg in about three
        // seconds, still ahead of libwebrtc's own 5 to 7 second expiry.
        _log('[HOLLOW-SCREEN] transport disconnected — holding the leg while '
            'the consent watchdog decides');
      default:
        break;
    }
  }

  // Fast failover: when the peer at the other end CRASHES the recovery is
  // same-second, but libwebrtc only gives up when ICE consent expires, about
  // 5 to 7 seconds of frozen picture. This watchdog shortens that to under
  // 3.5 s.
  //
  // CRITICAL: the signal is ICE CONSENT, never media bytes. A static screen
  // share is legitimately silent for minutes, so "no frames" says nothing
  // about liveness, while consent checks run continuously regardless of
  // media. Two consecutive stale polls are required, and a false positive
  // costs one blink rather than a lost stream.

  Timer? _livenessTimer;

  /// Fingerprint of the nominated pair's inbound counters, and OUR clock
  /// reading when it last CHANGED. Never a comparison against a timestamp
  /// the stats report: this fork reports them in MICROseconds, and an earlier
  /// version compared one against `millisecondsSinceEpoch`, went permanently
  /// negative and read as "always fresh" without ever firing.
  String? _livenessFingerprint;
  DateTime? _livenessLastMovement;

  /// Timer.periodic does not await, so a slow `getStats()` could otherwise
  /// overlap the next tick.
  bool _livenessPollInFlight = false;

  /// Logged once per PC: which inbound counters this build actually exposes.
  /// If none are, the watchdog disables itself loudly rather than pretending.
  bool _livenessMembersLogged = false;

  /// How long every inbound counter must sit still before the leg is called
  /// dead. Consent checks run about every 2.5 s and RTCP receiver reports
  /// about every 1 s, so 3 s is well past normal quiet while still beating
  /// libwebrtc's own 5 to 7 second consent expiry.
  static const _kConsentStaleAfter = Duration(seconds: 3);

  /// Inbound counters, most decisive first; whichever exist are combined
  /// into the fingerprint. Deliberately not media-only counters: a static
  /// screen share is legitimately silent, so ICE consent is the primary
  /// signal.
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
      // recovery means for its role, exactly as for a real ICE death.
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
  /// Deliberately unit-agnostic: it asks only "did these counters change
  /// since the last poll?". The primary signal is ICE consent, which keeps
  /// ticking regardless of media, since a static screen share sends almost
  /// nothing and media counters alone would call a healthy leg dead.
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
        // This build exposes none of the counters we can reason about. Say
        // so ONCE and stand down: a watchdog that silently never fires is
        // worse than none, because it looks like it is working.
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
      // getStats throws once the PC is closed; the state handler owns that.
      return false;
    }
  }

  /// Post-connect enforcement and verification of the resolution cap, for
  /// outgoing shares only.
  ///
  /// A live setParameters on a NEGOTIATED sender is the one path the spec
  /// requires to work, so 2s after connect the cap is re-applied with the
  /// true capture size from media-source stats (getSettings can be empty for
  /// desktop captures) and read back; 3s later what the encoder ACTUALLY
  /// emits is logged with an applied/not-applied verdict.
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
      // SIMULCAST has one outbound-rtp per LAYER. Reporting only the first
      // is how a dead `f` layer hid behind a healthy-looking "CAP APPLIED"
      // for the q layer, so every layer is reported and the cap judged
      // against the LARGEST one that is actually encoding.
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
      // Compare LONG edges so portrait window shares do not false-fail;
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

  /// Logs which ICE route (TURN/STUN/LAN) the connected PC ended up on.
  void _scheduleIceRouteLog() {
    if (_pc == null) return;
    _logIceRoute();
  }

  Future<void> _logIceRoute() async {
    // Resolve _pc per attempt — a renegotiation can replace it mid-probe.
    final route = await probeIceRoute(() => _pc);
    // Forwarder legs get their own label: the probe's TURN/STUN/LAN taxonomy
    // describes DIRECT lanes and mislabels a blind-forwarder hop, worst case
    // as "TURN (relayed)" on a client whose forwarder legs are in fact
    // exempt from forced TURN.
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
    // Dispose any previously-synthesized remote stream before replacing it;
    // a track-replace on renegotiation re-enters here. libwebrtc-owned
    // streams must NOT be disposed.
    final priorStream = _remoteStream;
    final priorSynthetic = _remoteStreamIsSynthetic;
    _remoteStreamIsSynthetic = false;

    await _resolveRemoteStream(event);

    await _disposePriorSyntheticStream(priorStream, priorSynthetic);

    // Null the field BEFORE awaiting dispose, so a Linux "texture not
    // found!" throw cannot leave a half-disposed renderer that close()
    // would then double-dispose.
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

  /// Picks the remote stream for the incoming video track: the event's
  /// stream, a PC remote stream with video, or a synthetic stream we own.
  Future<void> _resolveRemoteStream(RTCTrackEvent event) async {
    if (event.streams.isNotEmpty) {
      _remoteStream = event.streams.first;
      _log('[HOLLOW-SCREEN] Using stream from onTrack '
          '(streams=${event.streams.length})');
    } else {
      // Windows/libwebrtc may fire onTrack with streams=0; look for the
      // stream among the PC's remote streams instead.
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
