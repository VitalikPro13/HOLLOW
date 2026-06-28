import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/services/macos_version.dart';
import 'package:hollow/src/core/services/screen_audio_renderer.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/voice_service.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

import '../../rust/api/network.dart' as network_api;

/// Log to hollow_debug.log (visible in release builds).
void _callLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// Status of the current call.
enum CallStatus { idle, ringing, connecting, active }

/// Direction of the call.
enum CallDirection { outgoing, incoming }

/// Immutable state for the current call.
class CallState {
  final CallStatus status;
  final String? peerId;
  final String? callId;
  final CallDirection? direction;
  final bool isMuted;
  final DateTime? startedAt;
  final bool isVideoEnabled;
  final bool remoteVideoEnabled;
  final bool isVideoCall;
  final bool isScreenSharing;
  final bool remoteScreenSharing;
  final String sframeKey; // hex-encoded 32-byte SFrame key for E2EE
  final bool isLocalSpeaking;
  final bool isRemoteSpeaking;

  /// Mobile audio route: true = loudspeaker, false = earpiece.
  final bool isSpeakerOn;

  /// Local deafen state (remote audio silenced, mic muted).
  final bool isDeafened;

  /// Remote peer's mute/deafen state (synced via 'audio_state' signals).
  final bool remoteMuted;
  final bool remoteDeafened;

  /// Quality label for the local screen share (e.g. "1080p60"). Null when not sharing.
  final String? screenShareLabel;

  /// Quality label for the remote peer's screen share. Null when they're not sharing.
  final String? remoteScreenShareLabel;

  /// Bumped whenever a remote video renderer becomes ready. The renderer
  /// itself lives outside this state (on VoiceService), so without this the
  /// UI never rebuilds when the track arrives AFTER the video_state signal —
  /// the remote camera stays invisible until some unrelated state change.
  final int remoteVideoTrackSeq;

  const CallState({
    this.status = CallStatus.idle,
    this.peerId,
    this.callId,
    this.direction,
    this.isMuted = false,
    this.startedAt,
    this.isVideoEnabled = false,
    this.remoteVideoEnabled = false,
    this.isVideoCall = false,
    this.isScreenSharing = false,
    this.remoteScreenSharing = false,
    this.sframeKey = '',
    this.isLocalSpeaking = false,
    this.isRemoteSpeaking = false,
    this.isSpeakerOn = false,
    this.isDeafened = false,
    this.remoteMuted = false,
    this.remoteDeafened = false,
    this.screenShareLabel,
    this.remoteScreenShareLabel,
    this.remoteVideoTrackSeq = 0,
  });

  CallState copyWith({
    CallStatus? status,
    String? peerId,
    String? callId,
    CallDirection? direction,
    bool? isMuted,
    DateTime? startedAt,
    bool? isVideoEnabled,
    bool? remoteVideoEnabled,
    bool? isVideoCall,
    bool? isScreenSharing,
    bool? remoteScreenSharing,
    String? sframeKey,
    bool? isLocalSpeaking,
    bool? isRemoteSpeaking,
    bool? isSpeakerOn,
    bool? isDeafened,
    bool? remoteMuted,
    bool? remoteDeafened,
    String? screenShareLabel,
    bool clearScreenShareLabel = false,
    String? remoteScreenShareLabel,
    bool clearRemoteScreenShareLabel = false,
    int? remoteVideoTrackSeq,
  }) =>
      CallState(
        status: status ?? this.status,
        peerId: peerId ?? this.peerId,
        callId: callId ?? this.callId,
        direction: direction ?? this.direction,
        isMuted: isMuted ?? this.isMuted,
        startedAt: startedAt ?? this.startedAt,
        isVideoEnabled: isVideoEnabled ?? this.isVideoEnabled,
        remoteVideoEnabled: remoteVideoEnabled ?? this.remoteVideoEnabled,
        isVideoCall: isVideoCall ?? this.isVideoCall,
        isScreenSharing: isScreenSharing ?? this.isScreenSharing,
        remoteScreenSharing: remoteScreenSharing ?? this.remoteScreenSharing,
        sframeKey: sframeKey ?? this.sframeKey,
        isLocalSpeaking: isLocalSpeaking ?? this.isLocalSpeaking,
        isRemoteSpeaking: isRemoteSpeaking ?? this.isRemoteSpeaking,
        isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
        isDeafened: isDeafened ?? this.isDeafened,
        remoteMuted: remoteMuted ?? this.remoteMuted,
        remoteDeafened: remoteDeafened ?? this.remoteDeafened,
        screenShareLabel: clearScreenShareLabel
            ? null
            : (screenShareLabel ?? this.screenShareLabel),
        remoteScreenShareLabel: clearRemoteScreenShareLabel
            ? null
            : (remoteScreenShareLabel ?? this.remoteScreenShareLabel),
        remoteVideoTrackSeq: remoteVideoTrackSeq ?? this.remoteVideoTrackSeq,
      );

  static const idle = CallState();
}

class CallNotifier extends Notifier<CallState> {
  VoiceService? _voiceService;
  Timer? _ringTimer;
  Timer? _statsTimer;

  /// SECURITY (Phase 6.25): Guard against concurrent renegotiations.
  bool _renegotiationInProgress = false;

  /// Remote renegotiation offer that arrived while we were busy — processed
  /// when the current renegotiation settles instead of being dropped (a
  /// dropped offer means the remote's new track is never announced →
  /// one-way video).
  String? _queuedRenegOfferPeer;
  String? _queuedRenegOfferPayload;
  int _renegOfferAttempts = 0;

  /// Last user-chosen remote volume — restored when un-deafening.
  double _lastRemoteVolume = 1.0;

  /// Separate PCs for screen sharing (one per direction).
  ScreenShareService? _outgoingScreenShare; // We share our screen to them
  ScreenAudioRenderer? _screenAudioRenderer;
  ScreenShareService? _incomingScreenShare; // They share their screen to us

  /// Renderer for the incoming remote screen share. Used by UI.
  RTCVideoRenderer? get screenShareRenderer =>
      _incomingScreenShare?.remoteRenderer;

  /// Renderer for the local outgoing screen share (self-preview).
  /// Used by UI to show what we're currently sharing in the screen share view.
  RTCVideoRenderer? get localScreenShareRenderer =>
      _outgoingScreenShare?.localRenderer;

  VoiceService get _service {
    if (_voiceService == null) {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final iceConfig = ref.read(iceConfigProvider);
      final relayDomain = ref.read(relayDomainProvider);
      _voiceService = VoiceService(
          localPeerId: localPeerId, iceServers: iceConfig, relayDomain: relayDomain);
      _wireCallbacks();
    } else {
      // Keep ICE config up to date (TURN credentials refresh).
      _voiceService!.iceServers = ref.read(iceConfigProvider);
    }
    // Keep device preferences up to date.
    // Use .valueOrNull — async providers may still be loading on first access.
    // _ensureDevicePreferences() awaits them before the first call.
    _voiceService!.preferredAudioInputDeviceId =
        ref.read(audioInputDeviceProvider).valueOrNull;
    _voiceService!.preferredAudioOutputDeviceId =
        ref.read(audioOutputDeviceProvider).valueOrNull;
    _voiceService!.preferredCameraDeviceId =
        ref.read(cameraDeviceProvider).valueOrNull;
    _voiceService!.micGain =
        ref.read(micGainProvider).valueOrNull ?? kMicGainDefault;
    return _voiceService!;
  }

  /// Expose the VoiceService so UI can access video renderers.
  VoiceService? get voiceService => _voiceService;

  @override
  CallState build() => const CallState();

  void _wireCallbacks() {
    _voiceService!.onConnected = (peerId) {
      debugPrint('[HOLLOW-CALL] Voice connected with $peerId');
      if (state.status == CallStatus.connecting) {
        state = state.copyWith(
          status: CallStatus.active,
          startedAt: DateTime.now(),
        );
        _scheduleStatsDump(peerId);

        // Mobile audio route: voice calls start on the earpiece, video
        // calls on the loudspeaker.
        _setSpeakerRoute(state.isVideoCall);

        // Start VAD for speaking indicators.
        _voiceService!.onSpeakingChanged = (localSpeaking, remoteSpeaking) {
          if (state.status == CallStatus.active) {
            state = state.copyWith(
              isLocalSpeaking: localSpeaking,
              isRemoteSpeaking: remoteSpeaking,
            );
          }
        };
        _voiceService!.startVad();

        // Wire screen audio receiver (Windows) for DM calls.
        // Wire screen audio receiver (Windows sender → data channel → us).
        {
          final webrtc = ref.read(webRtcProvider.notifier).service;
          webrtc.onScreenAudioReceived = (fromPeer, data) async {
            if (_screenAudioRenderer == null) {
              _screenAudioRenderer = ScreenAudioRenderer();
              final ok = await _screenAudioRenderer!.start();
              if (!ok) {
                _screenAudioRenderer = null;
                return;
              }
            }
            _screenAudioRenderer?.pushPacket(data);
          };
        }

        // Video call: auto-enable the camera now that the audio connection
        // is up. Both sides do this — the side without a camera will see
        // toggleVideo() return false (no-op) and stay audio-only. The side
        // with a camera goes through the mid-call addTrack/renegotiate
        // path which is the proven-working flow for cross-peer video.
        if (state.isVideoCall) {
          // Stagger the auto-enable deterministically: both sides firing
          // toggleVideo ~simultaneously creates renegotiation glare (both
          // offers collide, one is never processed → one-way video). The
          // polite peer (lower peer_id, same convention as invite glare)
          // goes first; the other waits for that round-trip to settle.
          final autoEnableMs =
              localPeerId.compareTo(peerId) < 0 ? 300 : 1500;
          _callLog('[HOLLOW-CALL] Video call connected — scheduling '
              'auto-toggle in ${autoEnableMs}ms');
          Future.delayed(Duration(milliseconds: autoEnableMs), () {
            if (state.status == CallStatus.active &&
                state.isVideoCall &&
                !state.isVideoEnabled) {
              _callLog('[HOLLOW-CALL] Auto-enabling camera for video call');
              toggleVideo();
            } else {
              _callLog('[HOLLOW-CALL] Auto-toggle skipped: '
                  'status=${state.status} isVideoCall=${state.isVideoCall} '
                  'isVideoEnabled=${state.isVideoEnabled}');
            }
          });
        }
      }
    };

    _voiceService!.onDisconnected = (peerId) async {
      debugPrint('[HOLLOW-CALL] Voice disconnected from $peerId');
      if (state.status == CallStatus.active ||
          state.status == CallStatus.connecting) {
        _sendSignal(peerId, 'end', state.callId ?? '');
        await _cleanup();
      }
    };

    _voiceService!.onRemoteVideoTrack = (peerId) {
      _callLog('[HOLLOW-CALL] Remote video track/renderer ready for $peerId '
          '(status=${state.status}, remoteVideoEnabled=${state.remoteVideoEnabled})');
      // Renderer is now available for when the remote peer explicitly
      // enables their camera via the video_state signal. Don't set
      // remoteVideoEnabled here — on mobile, SDP negotiation can create
      // video transceivers that trigger onTrack/onRemoteVideoTrack even
      // for audio-only calls (stale transceiver from safety net). The
      // explicit video_state signal in _handleVideoState is the only
      // source of truth for remote camera state.
      //
      // DO bump the seq so the UI rebuilds: when video_state lands BEFORE
      // the track (common — the plaintext signal beats the SDP handshake),
      // the screen has already rebuilt with a null renderer and nothing
      // else re-triggers it; the remote camera stays invisible until the
      // peer toggles again.
      if (state.status != CallStatus.idle) {
        state = state.copyWith(
            remoteVideoTrackSeq: state.remoteVideoTrackSeq + 1);
      }
    };

    // Update mic gain mid-call when user adjusts the slider.
    ref.listen(micGainProvider, (_, next) {
      final gain = next.valueOrNull ?? kMicGainDefault;
      _voiceService?.updateMicGain(gain);
    });
  }

  /// Ensure audio device preferences are loaded from SQLCipher before starting
  /// a call. On first access after app launch, the async providers may not have
  /// completed yet, causing the call to use system defaults (wrong device).
  Future<void> _ensureDevicePreferences() async {
    try {
      final input = await ref.read(audioInputDeviceProvider.future);
      final output = await ref.read(audioOutputDeviceProvider.future);
      _voiceService?.preferredAudioInputDeviceId = input;
      _voiceService?.preferredAudioOutputDeviceId = output;

      // Apply audio quality preset.
      final quality = await ref.read(audioQualityProvider.future);
      _voiceService?.opusBitrate = quality.bitrate;
      _voiceService?.opusStereo = quality.stereo;

    } catch (_) {}
  }

  /// Set the remote peer's audio volume (how loud you hear them).
  Future<void> setRemoteVolume(double volume) async {
    _lastRemoteVolume = volume;
    if (state.isDeafened) return; // applied on un-deafen
    await _service.setRemoteAudioVolume(volume);
  }

  // ---------------------------------------------------------------------------
  // Call actions
  // ---------------------------------------------------------------------------

  /// Start an outgoing call to a peer.
  void startCall(String peerId, {bool withVideo = false}) {
    if (state.status != CallStatus.idle) return;

    final callId = _generateCallId();
    final sframeKey = _generateSframeKey();
    state = CallState(
      status: CallStatus.ringing,
      peerId: peerId,
      callId: callId,
      direction: CallDirection.outgoing,
      isVideoCall: withVideo,
      // Do NOT preset isVideoEnabled — the camera isn't actually captured
      // until onConnected → auto-toggleVideo runs after the call goes
      // active. Pre-setting this would make the auto-toggle skip its
      // !state.isVideoEnabled guard and the camera would never turn on.
      isVideoEnabled: false,
      sframeKey: sframeKey,
    );

    final payload = jsonEncode({
      'call_id': callId,
      'video': withVideo,
      'sframe_key': sframeKey,
    });
    _sendSignal(peerId, 'invite', payload);

    // 30-second ring timeout.
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 30), () async {
      if (state.status == CallStatus.ringing &&
          state.direction == CallDirection.outgoing) {
        debugPrint('[HOLLOW-CALL] Ring timeout, ending call');
        _sendSignal(peerId, 'end', callId);
        await _cleanup();
      }
    });
  }

  /// Accept an incoming call.
  Future<void> acceptCall() async {
    if (state.status != CallStatus.ringing ||
        state.direction != CallDirection.incoming) {
      return;
    }

    final peerId = state.peerId!;
    final callId = state.callId!;

    _ringTimer?.cancel();
    state = state.copyWith(status: CallStatus.connecting);

    // Tell caller we accepted — they will send SDP offer.
    final acceptPayload = jsonEncode({
      'call_id': callId,
      'sframe_key': state.sframeKey,
    });
    _sendSignal(peerId, 'accept', acceptPayload);
  }

  /// Reject an incoming call.
  Future<void> rejectCall() async {
    if (state.status != CallStatus.ringing ||
        state.direction != CallDirection.incoming) {
      return;
    }

    _sendSignal(state.peerId!, 'reject', state.callId!);
    await _cleanup();
  }

  /// End the current call (active or ringing).
  Future<void> endCall() async {
    if (state.status == CallStatus.idle) return;

    final peerId = state.peerId;
    final callId = state.callId;
    if (peerId != null && callId != null) {
      _sendSignal(peerId, 'end', callId);
    }

    // Tear down screen share PCs.
    await _outgoingScreenShare?.close();
    _outgoingScreenShare = null;
    await _incomingScreenShare?.close();
    _incomingScreenShare = null;

    await _service.endCall();
    await _cleanup();
  }

  /// Toggle microphone mute.
  void toggleMute() {
    if (state.status != CallStatus.active) return;
    _service.toggleMute();
    state = state.copyWith(isMuted: _service.isMuted);
    _sendAudioState();
  }

  /// Toggle deafen: silence the remote peer AND mute our mic. Mirrors voice
  /// channels — un-deafening keeps the mic muted.
  void toggleDeafen() {
    if (state.status != CallStatus.active) return;
    final newDeafened = !state.isDeafened;
    if (newDeafened && !_service.isMuted) _service.toggleMute();
    unawaited(_service
        .setRemoteAudioVolume(newDeafened ? 0.0 : _lastRemoteVolume)
        .catchError((_) {}));
    state = state.copyWith(
      isDeafened: newDeafened,
      isMuted: _service.isMuted,
    );
    _sendAudioState();
  }

  /// Tell the remote peer our mute/deafen state so their UI can show badges.
  void _sendAudioState() {
    final peerId = state.peerId;
    final callId = state.callId;
    if (peerId == null || callId == null) return;
    _sendSignal(
        peerId,
        'audio_state',
        jsonEncode({
          'call_id': callId,
          'muted': state.isMuted,
          'deafened': state.isDeafened,
        }));
  }

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Route audio to the loudspeaker (true) or earpiece (false). Mobile only.
  void _setSpeakerRoute(bool speaker) {
    if (!_isMobile) return;
    unawaited(Helper.setSpeakerphoneOn(speaker).catchError((_) {}));
    state = state.copyWith(isSpeakerOn: speaker);
  }

  /// Toggle loudspeaker/earpiece during a call. Mobile only.
  void toggleSpeaker() {
    if (state.status == CallStatus.idle) return;
    _setSpeakerRoute(!state.isSpeakerOn);
  }

  /// Toggle camera on/off.
  ///
  /// Sends a plaintext `video_state` signal so the remote UI immediately
  /// knows to update its layout, AND triggers an SDP renegotiation so the
  /// remote peer's WebRTC stack actually receives (or stops receiving) the
  /// video track. Without the renegotiation, `replaceTrack()` alone does
  /// not fire `onTrack` on the remote side — the track is silently swapped
  /// at the sender but never announced to the receiver, so the remote
  /// renderer is never created and the video layout stays audio-only.
  /// Matches the pattern used by voice_channel_service.dart.
  Future<void> toggleVideo() async {
    if (state.status != CallStatus.active) return;

    final wasEnabled = state.isVideoEnabled;
    final enabled = await _service.toggleVideo();
    state = state.copyWith(isVideoEnabled: enabled);

    // Turning the camera on mid-call implies hands-off use — switch to the
    // loudspeaker (mobile). Turning it off keeps whatever route is active.
    if (enabled && !wasEnabled && _isMobile && !state.isSpeakerOn) {
      _setSpeakerRoute(true);
    }

    final peerId = state.peerId;
    final callId = state.callId;
    if (peerId == null || callId == null) return;

    // If the service returned the SAME state we already had, the toggle was
    // a no-op (e.g. tried to enable but no camera available). Don't send
    // any signals or renegotiation — there's nothing to communicate.
    if (enabled == wasEnabled) {
      _callLog('[HOLLOW-CALL] toggleVideo: no-op (enabled=$enabled)');
      return;
    }

    // Send video_state notification so remote UI knows to update the layout.
    final videoStatePayload = jsonEncode({
      'call_id': callId,
      'enabled': enabled,
    });
    _sendSignal(peerId, 'video_state', videoStatePayload);

    // Send SDP renegotiation offer so the remote peer's WebRTC stack
    // picks up the new track. Guarded by _renegotiationInProgress to
    // avoid glare with inbound reneg.
    if (_renegotiationInProgress) {
      _callLog('[HOLLOW-CALL] toggleVideo: renegotiation already in '
          'progress, skipping offer');
      return;
    }
    _renegotiationInProgress = true;
    try {
      final offerSdp = await _service.createRenegotiationOffer();
      if (offerSdp != null) {
        final offerPayload = jsonEncode({
          'call_id': callId,
          'sdp': offerSdp,
        });
        _sendSignal(peerId, 'sdp_offer', offerPayload);
        _callLog('[HOLLOW-CALL] toggleVideo: sent renegotiation offer '
            '(enabled=$enabled)');
      }
    } catch (e) {
      _callLog('[HOLLOW-CALL] toggleVideo: renegotiation failed: $e');
    } finally {
      _renegotiationInProgress = false;
    }
  }

  /// Switch between front and back camera.
  Future<void> switchCamera() async {
    if (state.status != CallStatus.active || !state.isVideoEnabled) return;
    await _service.switchCamera();
  }

  /// Start screen sharing via a dedicated RTCPeerConnection.
  Future<void> startScreenShare({
    required String sourceId,
    required int width,
    required int height,
    required int fps,
    bool shareAudio = false,
    int pid = 0,
  }) async {
    if (state.status != CallStatus.active) return;

    final peerId = state.peerId!;
    final callId = state.callId!;
    final iceConfig = ref.read(iceConfigProvider);

    // Close any prior outgoing share before overwriting the field, so its PC +
    // thread-set can't be orphaned (e.g. re-share without an intervening stop).
    await _outgoingScreenShare?.close();

    // Create outgoing screen share service (separate PC).
    _outgoingScreenShare = ScreenShareService(
      localPeerId: localPeerId,
      iceServers: iceConfig,
    );

    // Wire ICE callback to send screen_ice signals.
    _outgoingScreenShare!.onIceCandidate = (candidate) {
      _sendSignal(peerId, 'screen_ice', jsonEncode({
        'call_id': callId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'role': 'offerer',
      }));
    };

    _outgoingScreenShare!.onScreenShareEnded = () {
      if (state.isScreenSharing) {
        stopScreenShare();
      }
    };

    try {
      final offerSdp = await _outgoingScreenShare!.createOffer(
        sourceId, width, height, fps,
        shareAudio: shareAudio,
      );

      // Enable SFrame E2EE on the screen share PC.
      if (_outgoingScreenShare!.pc != null) {
        await _enableSframeOnScreenShare(
            _outgoingScreenShare!.pc!, peerId, isSender: true);
      }

      // Build quality label (e.g. "1080p60", "4K30").
      const resLabels = {360: '360p', 480: '480p', 720: '720p', 1080: '1080p', 1440: '1440p', 2160: '4K'};
      final qualityLabel = '${resLabels[height] ?? '${height}p'}$fps';
      state = state.copyWith(isScreenSharing: true, screenShareLabel: qualityLabel);

      _sendSignal(peerId, 'screen_offer',
          jsonEncode({'call_id': callId, 'sdp': offerSdp}));
      _sendSignal(peerId, 'screen_state',
          jsonEncode({'call_id': callId, 'enabled': true, 'quality': qualityLabel}));

      // Start screen audio capture via data channel on the data-channel-audio
      // platforms: Windows (WASAPI) and macOS 13.0+ (ScreenCaptureKit).
      final dcAudio = Platform.isWindows ||
          (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio);
      if (shareAudio && dcAudio) {
        final webrtc = ref.read(webRtcProvider.notifier).service;
        // Ensure the file-transfer DC exists with this peer.
        if (!webrtc.hasPeerChannel(peerId)) {
          _callLog('[HOLLOW-AU-SCREEN] Ensuring WebRtcService DC for $peerId');
          await webrtc.connectToPeer(peerId);
        }
        final streamId = _outgoingScreenShare!.pc?.getLocalStreams().firstOrNull?.id ?? 'call_$callId';
        _callLog('[HOLLOW-AU-SCREEN] Starting screen audio capture (stream=$streamId)');
        await _outgoingScreenShare!.startScreenAudioCapture(
          streamId,
          pid: pid,
          onPacket: (packet) {
            webrtc.sendScreenAudio(peerId, packet);
          },
        );
      }
    } catch (e) {
      debugPrint('[HOLLOW-CALL] Failed to start screen share: $e');
      await _outgoingScreenShare?.close();
      _outgoingScreenShare = null;
    }
  }

  /// Stop screen sharing.
  Future<void> stopScreenShare() async {
    await _outgoingScreenShare?.close();
    _outgoingScreenShare = null;
    state = state.copyWith(isScreenSharing: false, clearScreenShareLabel: true);

    final peerId = state.peerId;
    final callId = state.callId;
    if (peerId != null && callId != null) {
      _sendSignal(peerId, 'screen_state',
          jsonEncode({'call_id': callId, 'enabled': false}));
    }
  }

  /// Master dispatcher for incoming call signals from Rust events.
  Future<void> handleCallSignal(
      String peerId, String signalType, String payload) async {
    try {
      switch (signalType) {
        case 'invite':
          _handleInvite(peerId, payload);
        case 'accept':
          await _handleAccept(peerId, payload);
        case 'reject':
          _handleReject(peerId, payload);
        case 'end':
          await _handleEnd(peerId, payload);
        case 'busy':
          _handleBusy(peerId, payload);
        case 'sdp_offer':
          await _handleSdpOffer(peerId, payload);
        case 'sdp_answer':
          await _handleSdpAnswer(peerId, payload);
        case 'ice':
          await _handleIce(peerId, payload);
        case 'video_state':
          _handleVideoState(peerId, payload);
        case 'audio_state':
          _handleAudioState(peerId, payload);
        case 'screen_state':
          await _handleScreenState(peerId, payload);
        case 'screen_offer':
          await _handleScreenOffer(peerId, payload);
        case 'screen_answer':
          await _handleScreenAnswer(peerId, payload);
        case 'screen_ice':
          await _handleScreenIce(peerId, payload);
        case 'recording_start':
          ref.read(recordingProvider.notifier).onRemoteRecordingStart(peerId);
        case 'recording_stop':
          ref.read(recordingProvider.notifier).onRemoteRecordingStop(peerId);
      }
    } catch (e) {
      debugPrint('[HOLLOW-CALL] Signal error ($signalType from $peerId): $e');
    }
  }

  /// Handle peer going offline — auto-end any call with them.
  Future<void> handlePeerDisconnected(String peerId) async {
    ref.read(recordingProvider.notifier).onPeerDisconnected(peerId);
    if (state.peerId == peerId && state.status != CallStatus.idle) {
      debugPrint('[HOLLOW-CALL] Peer $peerId disconnected, ending call');
      await _service.endCall();
      await _cleanup();
    }
  }

  /// Dispose (app shutdown).
  Future<void> disposeAll() async {
    _ringTimer?.cancel();
    _statsTimer?.cancel();
    await _voiceService?.dispose();
    state = const CallState();
  }

  // ---------------------------------------------------------------------------
  // Stats diagnostic
  // ---------------------------------------------------------------------------

  /// Schedule a getStats() dump 5 seconds after call goes active.
  void _scheduleStatsDump(String peerId) {
    _statsTimer?.cancel();
    _statsTimer = Timer(const Duration(seconds: 5), () async {
      final pc = _voiceService?.peerConnection;
      if (pc == null) {
        _callLog('[HOLLOW-STATS] No voice PC — cannot get stats');
        return;
      }

      _callLog('[HOLLOW-STATS] === AUDIO STATS 5s after call active ===');

      try {
        final stats = await pc.getStats();
        for (final report in stats) {
          final type = report.type;
          final values = report.values;

          if (type == 'outbound-rtp' && values['kind'] == 'audio') {
            _callLog('[HOLLOW-STATS] OUTBOUND-AUDIO: '
                'bytesSent=${values['bytesSent']}, '
                'packetsSent=${values['packetsSent']}, '
                'codec=${values['codecId']}');
          }

          if (type == 'inbound-rtp' && values['kind'] == 'audio') {
            _callLog('[HOLLOW-STATS] INBOUND-AUDIO: '
                'bytesReceived=${values['bytesReceived']}, '
                'packetsReceived=${values['packetsReceived']}, '
                'packetsLost=${values['packetsLost']}, '
                'codec=${values['codecId']}');
          }

          if (type == 'candidate-pair' && values['state'] == 'succeeded') {
            _callLog('[HOLLOW-STATS] ICE-PAIR: '
                'localCandidateId=${values['localCandidateId']}, '
                'remoteCandidateId=${values['remoteCandidateId']}, '
                'bytesSent=${values['bytesSent']}, '
                'bytesReceived=${values['bytesReceived']}');
          }
        }
      } catch (e) {
        _callLog('[HOLLOW-STATS] getStats failed: $e');
      }

      _callLog('[HOLLOW-STATS] === END STATS ===');
    });
  }

  // ---------------------------------------------------------------------------
  // Signal handlers
  // ---------------------------------------------------------------------------

  void _handleInvite(String peerId, String payload) {
    // Parse JSON payload {call_id, video, sframe_key}.
    String callId;
    bool withVideo = false;
    String sframeKey = '';
    if (payload.startsWith('{')) {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      callId = json['call_id'] as String;
      withVideo = json['video'] as bool? ?? false;
      sframeKey = json['sframe_key'] as String? ?? '';
    } else {
      callId = payload;
    }

    if (state.status != CallStatus.idle) {
      debugPrint('[HOLLOW-CALL] Busy, rejecting invite from $peerId');
      _sendSignal(peerId, 'busy', callId);
      return;
    }

    // Glare: if we sent an outgoing invite at the same time.
    if (state.status == CallStatus.ringing &&
        state.direction == CallDirection.outgoing &&
        state.peerId == peerId) {
      if (localPeerId.compareTo(peerId) < 0) {
        debugPrint('[HOLLOW-CALL] Glare: we are polite, accepting theirs');
        _ringTimer?.cancel();
        // SECURITY (Phase 6.25): Preserve OUR SFrame key during glare
        // resolution. Accepting the remote peer's key would let an attacker
        // inject their own key via a timed spoofed invite.
        state = CallState(
          status: CallStatus.ringing,
          peerId: peerId,
          callId: callId,
          direction: CallDirection.incoming,
          isVideoCall: withVideo,
          sframeKey: state.sframeKey,
        );
        return;
      } else {
        debugPrint('[HOLLOW-CALL] Glare: we are impolite, ignoring theirs');
        return;
      }
    }

    state = CallState(
      status: CallStatus.ringing,
      peerId: peerId,
      callId: callId,
      direction: CallDirection.incoming,
      isVideoCall: withVideo,
      sframeKey: sframeKey,
    );

    // 30-second auto-reject timeout.
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 30), () {
      if (state.status == CallStatus.ringing &&
          state.direction == CallDirection.incoming &&
          state.callId == callId) {
        debugPrint('[HOLLOW-CALL] Incoming ring timeout, auto-rejecting');
        rejectCall();
      }
    });
  }

  Future<void> _handleAccept(String peerId, String payload) async {
    // Parse JSON payload to extract call_id.
    String callId;
    try {
      final v = jsonDecode(payload);
      callId = v['call_id'] as String? ?? payload;
    } catch (_) {
      callId = payload;
    }

    if (state.status != CallStatus.ringing ||
        state.direction != CallDirection.outgoing ||
        state.callId != callId) {
      return;
    }

    _ringTimer?.cancel();
    state = state.copyWith(status: CallStatus.connecting);

    // Ensure device preferences are loaded before starting media.
    await _ensureDevicePreferences();

    // We are the caller — create a dedicated voice PC, capture audio, create
    // offer. Always start as audio-only — even for video calls. The camera
    // gets turned on automatically once the connection is `active` via the
    // mid-call addTrack/renegotiate path (which is the proven-working flow).
    // Starting with `withVideo: true` here would put us back into the
    // initial-SDP video transceiver mess that broke onTrack on the receiver.
    final sdp = await _service.createOffer(
      peerId,
      callId,
      withVideo: false,
    );

    // Enable SFrame E2EE using the key we generated in startCall.
    final keyHex = state.sframeKey;
    if (keyHex.isNotEmpty) {
      final keyBytes = _hexToBytes(keyHex);
      await _service.setSframeKey(peerId, keyBytes);
      // SECURITY (Phase 6.25): Clear key bytes from memory.
      keyBytes.fillRange(0, keyBytes.length, 0);
    }

    final sdpPayload = jsonEncode({'call_id': callId, 'sdp': sdp});
    _sendSignal(peerId, 'sdp_offer', sdpPayload);
  }

  Future<void> _handleReject(String peerId, String callId) async {
    if (state.callId != callId) return;
    debugPrint('[HOLLOW-CALL] Call rejected by $peerId');
    await _cleanup();
  }

  Future<void> _handleEnd(String peerId, String callId) async {
    if (state.callId != callId) return;
    debugPrint('[HOLLOW-CALL] Call ended by $peerId');
    await _outgoingScreenShare?.close();
    _outgoingScreenShare = null;
    await _incomingScreenShare?.close();
    _incomingScreenShare = null;
    await _service.endCall();
    await _cleanup();
  }

  Future<void> _handleBusy(String peerId, String callId) async {
    if (state.callId != callId) return;
    debugPrint('[HOLLOW-CALL] Peer $peerId is busy');
    // Tear the call down FIRST. The toast below must never be able to block
    // this — a thrown toast used to abort _handleBusy before cleanup, leaving
    // the "Calling..." sheet stuck on screen.
    final busyPeer = peerId;
    await _cleanup();
    _showBusyToast(busyPeer);
  }

  /// Toast the caller that the peer they dialed is already in another call.
  /// Best-effort + fully guarded: the notifier has no BuildContext of its own,
  /// so we reach for the global navigator's Overlay context. Wrapped in a
  /// try/catch + post-frame so an Overlay-lookup failure can never crash the
  /// call teardown.
  void _showBusyToast(String peerId) {
    final profile = ref.read(profileProvider)[peerId];
    final name = displayNameForPeer(profile, peerId);
    final msg = '$name is in a call, try again later';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final overlay = hollowNavigatorKey.currentState?.overlay;
        if (overlay == null) {
          debugPrint('[HOLLOW-CALL] busy toast: no overlay');
          return;
        }
        // Insert directly into the root navigator's Overlay — passing
        // overlayState avoids the Overlay.of() ancestor lookup that fails
        // from a navigator-key context. The positional context is unused
        // when overlayState is set.
        HollowToast.show(
          overlay.context,
          msg,
          type: HollowToastType.info,
          overlayState: overlay,
        );
      } catch (e) {
        debugPrint('[HOLLOW-CALL] busy toast failed: $e');
      }
    });
  }

  Future<void> _handleSdpOffer(String peerId, String payload) async {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;
    final sdp = json['sdp'] as String;

    if (state.callId != callId) return;

    // Route by call identity, NOT by status: `active` is only set in
    // onConnected (ICE/DTLS complete), which lags seconds behind the SDP
    // answer. A renegotiation offer arriving in that window (the staggered
    // camera auto-enable lands right in it) used to fall into the
    // initial-setup branch below and was silently consumed — never answered,
    // never retried → the first camera enable showed nothing until the
    // peer toggled again. If we already have a PC for this call, ANY
    // further offer is a renegotiation.
    if (_service.hasActiveCall) {
      // SECURITY (Phase 6.25): Prevent concurrent renegotiations — but queue
      // the offer instead of dropping it (a dropped offer is never retried by
      // the sender → its new track is never announced → one-way video).
      if (_renegotiationInProgress) {
        _callLog('[HOLLOW-CALL] Renegotiation in progress — queueing offer');
        _queueRenegOffer(peerId, payload);
        return;
      }
      _renegotiationInProgress = true;
      var answered = false;
      try {
        // Renegotiation on existing voice PC (e.g., remote toggled video).
        final answerSdp = await _service.handleRenegotiationOffer(sdp);
        if (answerSdp != null) {
          final answerPayload =
              jsonEncode({'call_id': callId, 'sdp': answerSdp});
          _sendSignal(peerId, 'sdp_answer', answerPayload);
          answered = true;
        }
      } catch (e) {
        _callLog('[HOLLOW-CALL] Renegotiation answer failed: $e');
      } finally {
        _renegotiationInProgress = false;
      }
      if (answered) {
        _renegOfferAttempts = 0;
        _drainQueuedRenegOffer();
      } else if (_renegOfferAttempts < 2) {
        // Likely SDP glare: this offer arrived while our own offer was
        // unanswered (have-local-offer). Retry after our round-trip settles.
        _renegOfferAttempts++;
        _callLog('[HOLLOW-CALL] Scheduling renegotiation offer retry '
            '(attempt $_renegOfferAttempts)');
        Future.delayed(const Duration(milliseconds: 1200), () {
          // hasActiveCall, not status==active — the call may still be in
          // the connecting window (same reason as the routing gate above).
          if (_service.hasActiveCall && state.peerId == peerId) {
            _handleSdpOffer(peerId, payload);
          }
        });
      }
    } else {
      // Ensure device preferences are loaded before starting media.
      await _ensureDevicePreferences();
      // Initial call setup — create a dedicated voice PC, capture audio,
      // answer. Always start as audio-only (matching createOffer above);
      // camera is turned on automatically post-connect via the mid-call
      // addTrack/renegotiate path.
      final answerSdp = await _service.handleOffer(
        peerId,
        callId,
        sdp,
        withVideo: false,
      );

      // Enable SFrame E2EE using the key from the invite.
      final keyHex = state.sframeKey;
      if (keyHex.isNotEmpty) {
        final keyBytes = _hexToBytes(keyHex);
        await _service.setSframeKey(peerId, keyBytes);
        // SECURITY (Phase 6.25): Clear key bytes from memory.
        keyBytes.fillRange(0, keyBytes.length, 0);
      }

      final answerPayload = jsonEncode({'call_id': callId, 'sdp': answerSdp});
      _sendSignal(peerId, 'sdp_answer', answerPayload);
    }
  }

  Future<void> _handleSdpAnswer(String peerId, String payload) async {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;
    final sdp = json['sdp'] as String;

    if (state.callId != callId) return;

    await _service.handleAnswer(sdp);
    // Our renegotiation round-trip just settled (PC back to stable) —
    // process any remote offer that collided with it.
    _drainQueuedRenegOffer();
  }

  void _queueRenegOffer(String peerId, String payload) {
    _queuedRenegOfferPeer = peerId;
    _queuedRenegOfferPayload = payload;
    // Safety net: drain even if no answer ever arrives for our own offer.
    Future.delayed(const Duration(milliseconds: 2000), _drainQueuedRenegOffer);
  }

  void _drainQueuedRenegOffer() {
    final peer = _queuedRenegOfferPeer;
    final payload = _queuedRenegOfferPayload;
    if (peer == null || payload == null) return;
    if (_renegotiationInProgress) return; // drained at next settle point
    _queuedRenegOfferPeer = null;
    _queuedRenegOfferPayload = null;
    if (_service.hasActiveCall && state.peerId == peer) {
      _callLog('[HOLLOW-CALL] Processing queued renegotiation offer');
      unawaited(_handleSdpOffer(peer, payload));
    }
  }

  Future<void> _handleIce(String peerId, String payload) async {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;

    if (state.callId != callId) return;

    await _service.handleIceCandidate(
      json['candidate'] as String,
      json['sdpMid'] as String?,
      (json['sdpMLineIndex'] as num?)?.toInt(),
    );
  }

  void _handleVideoState(String peerId, String payload) {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;
    final enabled = json['enabled'] as bool;

    if (state.callId != callId) {
      _callLog('[HOLLOW-CALL] video_state DROPPED: callId mismatch '
          '(ours=${state.callId} theirs=$callId)');
      return;
    }

    _callLog('[HOLLOW-CALL] Remote video state applied: enabled=$enabled '
        '(status=${state.status})');
    state = state.copyWith(remoteVideoEnabled: enabled);

    if (enabled) {
      // Re-poke the UI after the SDP round-trip typically lands. The remote
      // renderer lives OUTSIDE provider state, so if its ready-callback ever
      // fails to produce a rebuild (one missed frame of state change), the
      // camera stays invisible until the peer re-toggles. Three cheap
      // scheduled bumps make the first enable deterministic.
      for (final d in const [
        Duration(milliseconds: 400),
        Duration(milliseconds: 1200),
        Duration(milliseconds: 2500),
      ]) {
        Future.delayed(d, () {
          if (state.remoteVideoEnabled && state.status != CallStatus.idle) {
            state = state.copyWith(
                remoteVideoTrackSeq: state.remoteVideoTrackSeq + 1);
          }
        });
      }
    }
  }

  void _handleAudioState(String peerId, String payload) {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String?;
    if (callId != null && state.callId != callId) return;

    state = state.copyWith(
      remoteMuted: json['muted'] as bool? ?? false,
      remoteDeafened: json['deafened'] as bool? ?? false,
    );
  }

  Future<void> _handleScreenState(String peerId, String payload) async {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;
    final enabled = json['enabled'] as bool;
    final quality = json['quality'] as String?;

    if (state.callId != callId) return;

    debugPrint(
        '[HOLLOW-CALL] Remote screen share: enabled=$enabled quality=$quality from $peerId');

    if (!enabled) {
      // Remote stopped sharing — tear down the incoming screen share PC.
      // Capture + null synchronously so a concurrent screen_offer doesn't
      // double-tear-down the same PC, then AWAIT the close so the native
      // thread-set is fully gone before we move on (an unawaited close that
      // races a new offer's close() corrupts the PC's threads).
      final incoming = _incomingScreenShare;
      _incomingScreenShare = null;
      await incoming?.close();
    }

    state = state.copyWith(
      remoteScreenSharing: enabled,
      remoteScreenShareLabel: enabled ? quality : null,
      clearRemoteScreenShareLabel: !enabled,
    );
  }

  Future<void> _handleScreenOffer(String peerId, String payload) async {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;
    final sdp = json['sdp'] as String;

    if (state.callId != callId) return;

    debugPrint('[HOLLOW-CALL] Screen offer from $peerId');

    final iceConfig = ref.read(iceConfigProvider);

    // Phase 6.25: Dispose old incoming screen share before creating new one.
    if (_incomingScreenShare != null) {
      await _incomingScreenShare!.close();
      _incomingScreenShare = null;
    }

    // Create incoming screen share service (separate PC to receive their screen).
    _incomingScreenShare = ScreenShareService(
      localPeerId: localPeerId,
      iceServers: iceConfig,
    );

    // Wire ICE callback.
    _incomingScreenShare!.onIceCandidate = (candidate) {
      _sendSignal(peerId, 'screen_ice', jsonEncode({
        'call_id': callId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
        'role': 'answerer',
      }));
    };

    _incomingScreenShare!.onRemoteTrackReady = () {
      // Force UI rebuild so RTCVideoView picks up the renderer.
      debugPrint('[HOLLOW-CALL] Screen share remote track ready');
      state = state.copyWith();
    };

    // Set preferred audio output so screen share audio plays to the right speaker.
    try {
      final output = await ref.read(audioOutputDeviceProvider.future);
      _incomingScreenShare!.preferredAudioOutputDeviceId = output;
    } catch (_) {}

    // Handle the offer and send answer.
    final answerSdp = await _incomingScreenShare!.handleOffer(sdp);

    // Enable SFrame E2EE on the incoming screen share PC.
    if (_incomingScreenShare!.pc != null) {
      await _enableSframeOnScreenShare(
          _incomingScreenShare!.pc!, peerId, isSender: false);
    }

    _sendSignal(peerId, 'screen_answer',
        jsonEncode({'call_id': callId, 'sdp': answerSdp}));
  }

  Future<void> _handleScreenAnswer(String peerId, String payload) async {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;
    final sdp = json['sdp'] as String;

    if (state.callId != callId || _outgoingScreenShare == null) return;

    debugPrint('[HOLLOW-CALL] Screen answer from $peerId');
    await _outgoingScreenShare!.handleAnswer(sdp);
  }

  Future<void> _handleScreenIce(String peerId, String payload) async {
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final callId = json['call_id'] as String;

    if (state.callId != callId) return;

    final candidate = json['candidate'] as String;
    final sdpMid = json['sdpMid'] as String?;
    final sdpMLineIndex = (json['sdpMLineIndex'] as num?)?.toInt();
    final role = json['role'] as String;

    // Route to the opposite PC: offerer's candidates go to our incoming PC,
    // answerer's candidates go to our outgoing PC.
    if (role == 'offerer') {
      await _incomingScreenShare?.handleIceCandidate(
          candidate, sdpMid, sdpMLineIndex);
    } else {
      await _outgoingScreenShare?.handleIceCandidate(
          candidate, sdpMid, sdpMLineIndex);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String get localPeerId => ref.read(identityProvider).peerId ?? '';

  void _sendSignal(String peerId, String signalType, String payload) {
    network_api.callSendSignal(
      peerId: peerId,
      signalType: signalType,
      payload: payload,
    );
  }

  Future<void> _cleanup() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _renegotiationInProgress = false;
    _queuedRenegOfferPeer = null;
    _queuedRenegOfferPayload = null;
    _renegOfferAttempts = 0;
    _lastRemoteVolume = 1.0;
    // Stop out-of-process screen audio renderer.
    if (_screenAudioRenderer != null) {
      await _screenAudioRenderer!.stop();
      _screenAudioRenderer = null;
    }
    try {
      ref.read(webRtcProvider.notifier).service.onScreenAudioReceived = null;
    } catch (_) {}
    // Phase 6.25: Dispose screen share services to prevent GPU/memory leaks.
    await _outgoingScreenShare?.close();
    _outgoingScreenShare = null;
    await _incomingScreenShare?.close();
    _incomingScreenShare = null;
    // Reset the screen-share view focus so the next call starts fresh.
    ref.read(focusedDmSourceProvider.notifier).state =
        const DmFocusedSource.none();
    // Restore the default audio route so the next call doesn't inherit a
    // stale speakerphone state.
    if (_isMobile) {
      unawaited(Helper.setSpeakerphoneOn(false).catchError((_) {}));
    }
    state = const CallState();
  }

  String _generateCallId() {
    final r = Random();
    return List.generate(
            16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Generate a random 32-byte SFrame key (hex-encoded).
  String _generateSframeKey() {
    final r = Random.secure();
    return List.generate(
            32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Enable SFrame E2EE on a screen share RTCPeerConnection's tracks.
  Future<void> _enableSframeOnScreenShare(
      RTCPeerConnection pc, String peerId, {required bool isSender}) async {
    final keyHex = state.sframeKey;
    if (keyHex.isEmpty) return;
    final frameCryptor = _service.frameCryptor;
    if (frameCryptor == null || !frameCryptor.isEnabled) return;

    try {
      if (isSender) {
        final senders = await pc.getSenders();
        for (final sender in senders) {
          final kind = sender.track?.kind ?? 'video';
          await frameCryptor.enableForSender(
              'screen:$peerId', sender, kind: 'screen_$kind');
        }
      } else {
        final receivers = await pc.getReceivers();
        for (final receiver in receivers) {
          final kind = receiver.track?.kind ?? 'video';
          await frameCryptor.enableForReceiver(
              'screen:$peerId', receiver, kind: 'screen_$kind');
        }
      }
      debugPrint('[HOLLOW-CALL] SFrame enabled on screen share (sender=$isSender)');
    } catch (e) {
      debugPrint('[HOLLOW-CALL] Failed to enable SFrame on screen share: $e');
    }
  }

  /// Convert hex string to Uint8List.
  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

final callProvider =
    NotifierProvider<CallNotifier, CallState>(CallNotifier.new);

/// Which DM call source is focused (big tile) in the screen-share view.
/// `peerId` = which peer's source. `type` = 'screen' or 'camera'.
/// `null` means "no explicit focus — use default layout for the current
/// share state". Lifted to a provider so both `_ChatPaneState` (the source
/// switcher pill) and `_ScreenShareFullView` (the big tile renderer) can
/// read and write it. Modeled after voice_channel_pane's
/// focusedScreenSharePeerId / focusedSourceType pair.
class DmFocusedSource {
  final String? peerId;
  final String? type; // 'screen' | 'camera'
  const DmFocusedSource({this.peerId, this.type});
  const DmFocusedSource.none() : peerId = null, type = null;
}

final focusedDmSourceProvider =
    StateProvider<DmFocusedSource>((_) => const DmFocusedSource.none());
