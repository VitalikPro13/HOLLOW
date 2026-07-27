import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/macos_version.dart';
import 'package:hollow/src/core/services/mobile_screen_audio_capturer.dart';
import 'package:hollow/src/core/services/screen_audio_receiver.dart';
import 'package:hollow/src/core/services/share_audio_level.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Audio state for a peer in a voice channel.
class PeerAudioState {
  final bool isMuted;
  final bool isDeafened;

  const PeerAudioState({this.isMuted = false, this.isDeafened = false});
}

/// Immutable state for voice channel participation.
class VoiceChannelState {
  /// Map: server_id -> channel_id -> Set<peer_id>
  final Map<String, Map<String, Set<String>>> participants;

  /// The voice channel the local user is currently in (null = not in any).
  final String? currentServerId;
  final String? currentChannelId;
  final String? currentChannelName;

  /// Whether the local user's mic is muted.
  final bool isMuted;

  /// Whether the local user is deafened (muted + no audio output).
  final bool isDeafened;

  /// Remote peer audio states (peer_id -> PeerAudioState).
  final Map<String, PeerAudioState> peerAudioStates;

  // NOTE: speaking (VAD) state deliberately lives in vcSpeakingProvider, NOT
  // here — it changes 1-4x/sec per talker and replacing this state object
  // rebuilt every voiceChannelProvider watcher (shell, panes, tiles) per flip.

  /// Per-peer volume overrides (peer_id -> 0.0-2.0).
  final Map<String, double> peerVolumes;

  /// Current voice mode: "mesh" or "gossip".
  final String voiceMode;

  /// Gossip neighbors for the current voice channel (gossip mode only).
  final Set<String> gossipNeighbors;

  /// When the local user joined the current voice channel.
  final DateTime? joinedAt;

  /// Whether the local user is sharing their screen.
  final bool isScreenSharing;

  /// Quality label for the local screen share (e.g. "1080p60"). Null when not sharing.
  final String? screenShareLabel;

  /// Remote peers currently sharing their screen (peer_id -> true).
  final Map<String, bool> peerScreenSharing;

  /// Quality labels for remote peers' screen shares (peer_id -> label).
  final Map<String, String> peerScreenShareLabels;

  /// Which sharer is displayed full-bleed (null = none).
  final String? focusedScreenSharePeerId;

  /// Type of the focused source in mixed mode: 'screen' or 'camera'.
  /// Only used when both screen share and camera are active.
  final String focusedSourceType;

  /// Whether the local user's camera is on.
  final bool isCameraOn;

  /// Local camera facing (true = front). Local previews mirror only the
  /// front camera — a mirrored back camera shows text reversed.
  final bool isFrontCamera;

  /// Remote peers with camera on (peer_id -> true).
  final Map<String, bool> peerCameraOn;

  /// Mobile audio route: true = loudspeaker, false = earpiece.
  final bool isSpeakerOn;

  const VoiceChannelState({
    this.participants = const {},
    this.currentServerId,
    this.currentChannelId,
    this.currentChannelName,
    this.isMuted = false,
    this.isDeafened = false,
    this.peerAudioStates = const {},
    this.peerVolumes = const {},
    this.voiceMode = 'mesh',
    this.gossipNeighbors = const {},
    this.joinedAt,
    this.isScreenSharing = false,
    this.screenShareLabel,
    this.peerScreenSharing = const {},
    this.peerScreenShareLabels = const {},
    this.focusedScreenSharePeerId,
    this.focusedSourceType = 'screen',
    this.isCameraOn = false,
    this.isFrontCamera = true,
    this.peerCameraOn = const {},
    this.isSpeakerOn = false,
  });

  /// Get participants for a specific voice channel.
  Set<String> getParticipants(String serverId, String channelId) {
    return participants[serverId]?[channelId] ?? {};
  }

  /// Whether the local user is in any voice channel.
  bool get isInVoiceChannel => currentChannelId != null;

  /// Get audio state for a peer (returns default if unknown).
  PeerAudioState getPeerAudioState(String peerId) {
    return peerAudioStates[peerId] ?? const PeerAudioState();
  }

  /// Get saved volume for a peer (default 1.0).
  double getPeerVolume(String peerId) => peerVolumes[peerId] ?? 1.0;

  /// Whether any screen share is active (local or remote).
  bool get isScreenShareActive =>
      isScreenSharing ||
      peerScreenSharing.values.any((v) => v);

  /// Whether any camera video is active (local or remote).
  bool get isCameraActive =>
      isCameraOn ||
      peerCameraOn.values.any((v) => v);

  VoiceChannelState copyWith({
    Map<String, Map<String, Set<String>>>? participants,
    String? currentServerId,
    String? currentChannelId,
    String? currentChannelName,
    bool? isMuted,
    bool? isDeafened,
    Map<String, PeerAudioState>? peerAudioStates,
    Map<String, double>? peerVolumes,
    String? voiceMode,
    Set<String>? gossipNeighbors,
    DateTime? joinedAt,
    bool? isScreenSharing,
    String? screenShareLabel,
    bool clearScreenShareLabel = false,
    Map<String, bool>? peerScreenSharing,
    Map<String, String>? peerScreenShareLabels,
    String? focusedScreenSharePeerId,
    bool clearFocusedSharer = false,
    bool clearCurrent = false,
    String? focusedSourceType,
    bool? isCameraOn,
    bool? isFrontCamera,
    Map<String, bool>? peerCameraOn,
    bool? isSpeakerOn,
  }) {
    return VoiceChannelState(
      participants: participants ?? this.participants,
      currentServerId:
          clearCurrent ? null : (currentServerId ?? this.currentServerId),
      currentChannelId:
          clearCurrent ? null : (currentChannelId ?? this.currentChannelId),
      currentChannelName:
          clearCurrent ? null : (currentChannelName ?? this.currentChannelName),
      isMuted: clearCurrent ? false : (isMuted ?? this.isMuted),
      isDeafened: clearCurrent ? false : (isDeafened ?? this.isDeafened),
      peerAudioStates: clearCurrent
          ? const {}
          : (peerAudioStates ?? this.peerAudioStates),
      peerVolumes: clearCurrent
          ? const {}
          : (peerVolumes ?? this.peerVolumes),
      voiceMode: clearCurrent
          ? 'mesh'
          : (voiceMode ?? this.voiceMode),
      gossipNeighbors: clearCurrent
          ? const {}
          : (gossipNeighbors ?? this.gossipNeighbors),
      joinedAt: clearCurrent
          ? null
          : (joinedAt ?? this.joinedAt),
      isScreenSharing: clearCurrent
          ? false
          : (isScreenSharing ?? this.isScreenSharing),
      screenShareLabel: clearCurrent || clearScreenShareLabel
          ? null
          : (screenShareLabel ?? this.screenShareLabel),
      peerScreenSharing: clearCurrent
          ? const {}
          : (peerScreenSharing ?? this.peerScreenSharing),
      peerScreenShareLabels: clearCurrent
          ? const {}
          : (peerScreenShareLabels ?? this.peerScreenShareLabels),
      focusedScreenSharePeerId: clearCurrent || clearFocusedSharer
          ? null
          : (focusedScreenSharePeerId ?? this.focusedScreenSharePeerId),
      focusedSourceType: clearCurrent
          ? 'screen'
          : (focusedSourceType ?? this.focusedSourceType),
      isCameraOn: clearCurrent
          ? false
          : (isCameraOn ?? this.isCameraOn),
      isFrontCamera: clearCurrent
          ? true
          : (isFrontCamera ?? this.isFrontCamera),
      peerCameraOn: clearCurrent
          ? const {}
          : (peerCameraOn ?? this.peerCameraOn),
      isSpeakerOn: clearCurrent
          ? false
          : (isSpeakerOn ?? this.isSpeakerOn),
    );
  }
}

class VoiceChannelNotifier extends Notifier<VoiceChannelState> {
  static const int maxScreenShareOutgoing = 15;
  static const int maxScreenShareIncoming = 10;

  VoiceChannelService? _service;

  /// Outgoing screen share services (one per peer we're sending to).
  final Map<String, ScreenShareService> _outgoingScreenShares = {};

  /// Incoming screen share services (one per peer sharing their screen to us).
  final Map<String, ScreenShareService> _incomingScreenShares = {};

  /// Early ICE candidates that arrived before the service was created.
  /// Key: "incoming:peerId" or "outgoing:peerId"
  final Map<String, List<Map<String, dynamic>>> _earlyScreenIce = {};

  /// Cached SFrame keys from MLS epoch changes — applied when the service is
  /// (re)created. Keyed by `_sframeCacheKey(serverId, channelId)`:
  ///   * channelId == null → the server-wide MLS group key (non-restricted voice
  ///     channels). Applies to ANY non-restricted channel in that server.
  ///   * channelId != null → a restricted channel's MLS SUBGROUP key (per-channel
  ///     subgroups / "Option B"). Applies ONLY to that voice channel, so a
  ///     non-qualifying member who never receives it can't decode the audio.
  final Map<String, ({int epoch, Uint8List key})> _sframeKeys = {};

  /// Cache key for an SFrame secret. A subgroup key is scoped to its channel; the
  /// server-group key uses a sentinel so it can't collide with any channel id.
  static String _sframeCacheKey(String serverId, String? channelId) =>
      '$serverId ${channelId ?? ''}';

  /// Whether a channel is cryptographically isolated in its own MLS subgroup
  /// (per-channel subgroups / "Option B"): restricted visibility AND not a public
  /// channel. Mirrors Rust `ServerState::channel_uses_subgroup`. Such a channel's
  /// voice SFrame key comes ONLY from its subgroup, never the server-wide group.
  bool _channelUsesSubgroup(String channelId) {
    final ch = ref.read(channelListProvider)[channelId];
    if (ch == null) return false;
    return !ch.isPublic && ch.visibility != 'everyone';
  }

  /// Shared screen capture stream (captured once, shared across outgoing PCs).
  MediaStream? _screenCaptureStream;
  RTCVideoRenderer? _localScreenPreviewRenderer;
  int _screenShareMaxWidth = 1920;
  int _screenShareMaxHeight = 1080;
  int _screenShareFps = 60;
  bool _screenShareAudio = false;
  int _screenSharePid = 0;
  int _screenShareHwnd = 0;
  ScreenContentProfile _screenShareProfile = ScreenContentProfile.motion;
  ScreenAudioReceiver? _screenAudioRenderer;

  /// MOBILE share-audio capture — ONE central instance for the whole channel
  /// (the Rust Opus encoder is a process-global singleton; the desktop
  /// per-peer-exe pattern would feed it the same PCM N times). Packets fan
  /// out to every outgoing-share peer at send time.
  MobileScreenAudioCapturer? _mobileShareAudioCapturer;

  /// Entire-screen anti-echo (Windows): the out-of-process voice-render child
  /// pid to EXCLUDE from the screen-audio capture (so the VC voices it plays
  /// aren't re-captured while Hollow's own media is), and whether the redirect
  /// is currently armed. Armed once per share (covers all peers), reset on stop.
  int _screenShareExcludePid = 0;
  bool _voiceRedirectActive = false;

  /// Timer that polls for screen track ending (window closed).
  Timer? _screenTrackPoller;

  /// Guard to prevent concurrent leaveChannel calls and actions during leave.
  bool _leaving = false;

  /// In-flight teardown (set by the server-forced `onLocalLeft` path, which
  /// can't be awaited by its synchronous caller). A subsequent `joinChannel`
  /// awaits this so a new call's PCs can't start while the old call's mesh is
  /// still tearing down its libwebrtc thread-sets (which would race the native
  /// teardown → heap corruption on Linux).
  Future<void>? _teardownInFlight;

  /// Channel that was selected before joining the VC (restored on leave).
  String? preVcChannelId;

  // ---------------------------------------------------------------
  //  Camera (video) state
  // ---------------------------------------------------------------

  /// Local camera renderer (for self-view in grid).
  RTCVideoRenderer? _localCameraRenderer;

  /// Remote camera renderers (peer_id -> RTCVideoRenderer), managed by service.
  final Map<String, RTCVideoRenderer> _remoteCameraRenderers = {};

  /// Device-provider listeners registered once (the join path re-runs).
  bool _deviceListenersWired = false;

  @override
  VoiceChannelState build() {
    // The service snapshots its ICE config at join time and nothing else ever
    // reassigns it (unlike VoiceService/WebRtcService, which re-read on every
    // service-getter access). Push updates in instead — otherwise a TURN
    // credential refresh, or an "Always relay calls" flip made while sitting
    // in a channel, would still hand DIRECT candidates to every peer who joins
    // afterwards.
    ref.listen<Map<String, dynamic>>(iceConfigProvider, (_, next) {
      _service?.iceServers = next;
    });
    return const VoiceChannelState();
  }

  /// Live camera device switch: the service swaps every mesh PC's sender and
  /// returns the fresh capture stream — rebind the self-view to it.
  Future<void> _applyCameraDevice(String? deviceId) async {
    final service = _service;
    if (service == null) return;
    try {
      final newStream = await service.setCameraDevice(deviceId);
      if (newStream != null && _localCameraRenderer != null) {
        _localCameraRenderer!.srcObject = newStream;
      }
    } catch (e) {
      debugPrint('[HOLLOW-VC] Camera device switch failed: $e');
    }
  }

  VoiceChannelService? get service => _service;

  /// Get the renderer for an incoming screen share from a specific peer.
  RTCVideoRenderer? getScreenShareRenderer(String peerId) =>
      _incomingScreenShares[peerId]?.remoteRenderer;

  /// Get the local screen share renderer (self-preview of what we're sharing).
  /// Uses a dedicated renderer tied to the capture stream, independent of
  /// whether any peers are connected (works even when alone in the channel).
  RTCVideoRenderer? get localScreenShareRenderer =>
      _localScreenPreviewRenderer;

  /// Get the camera renderer for a peer (or self).
  RTCVideoRenderer? getCameraRenderer(String peerId) {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    if (peerId == localPeerId) return _localCameraRenderer;
    return _remoteCameraRenderers[peerId];
  }

  /// Handle a peer joining a voice channel (from event).
  void onPeerJoined(String serverId, String channelId, String peerId) {
    final updated = _deepCopyParticipants();
    updated.putIfAbsent(serverId, () => {});
    updated[serverId]!.putIfAbsent(channelId, () => {});
    updated[serverId]![channelId] =
        {...updated[serverId]![channelId]!, peerId};
    state = state.copyWith(participants: updated);
  }

  /// Handle a peer leaving a voice channel (from event).
  void onPeerLeft(String serverId, String channelId, String peerId) {
    final updated = _deepCopyParticipants();
    updated[serverId]?[channelId]?.remove(peerId);
    if (updated[serverId]?[channelId]?.isEmpty ?? false) {
      updated[serverId]!.remove(channelId);
    }
    if (updated[serverId]?.isEmpty ?? false) {
      updated.remove(serverId);
    }
    // Clean up audio state for the leaving peer.
    final audioStates = Map.of(state.peerAudioStates)..remove(peerId);
    state = state.copyWith(participants: updated, peerAudioStates: audioStates);
  }

  /// Drop every REMOTE participant tracked under [serverId] (all channels).
  /// Conferences call this on meeting start/end/leave: a previous meeting's
  /// members linger otherwise — their VoiceChannelLeave broadcast raced the
  /// host's room-leave/group-drop and never arrived, and restarting reuses
  /// the same `conf:x:main` key.
  void clearServerParticipants(String serverId) {
    if (!state.participants.containsKey(serverId)) return;
    final removed = state.participants[serverId]?.values
            .expand((peers) => peers)
            .toSet() ??
        const <String>{};
    final updated = _deepCopyParticipants()..remove(serverId);
    final audioStates = Map.of(state.peerAudioStates)
      ..removeWhere((peerId, _) => removed.contains(peerId));
    state = state.copyWith(participants: updated, peerAudioStates: audioStates);
  }

  /// Join a voice channel. If already in one, leave it first.
  Future<void> joinChannel(String serverId, String channelId) async {
    // Block if in a 1:1 call.
    final callState = ref.read(callProvider);
    if (callState.status != CallStatus.idle) {
      debugPrint('[HOLLOW-VC] Cannot join voice channel — in a call');
      return;
    }

    // Wait for any server-forced teardown still in flight to finish, so we
    // don't build new PCs while the old mesh is mid-dispose.
    final pending = _teardownInFlight;
    if (pending != null) {
      debugPrint('[HOLLOW-VC] joinChannel waiting for in-flight teardown');
      try {
        await pending;
      } catch (_) {}
    }

    // Leave current voice channel if in one.
    if (state.isInVoiceChannel) {
      await leaveChannel();
    }

    // Send join signal via Rust FFI.
    await network_api.voiceChannelJoin(
      serverId: serverId,
      channelId: channelId,
    );
  }

  /// Called after the local join event arrives to update state and start audio.
  Future<void> onLocalJoined(String serverId, String channelId) async {
    // Resolve channel name: try provider first, then fall back to FFI.
    String? channelName = ref.read(channelListProvider)[channelId]?.name;
    if (channelName == null) {
      try {
        final channels = await crdt_api.getServerChannels(serverId: serverId);
        channelName = channels
            .where((c) => c.channelId == channelId)
            .firstOrNull
            ?.name;
      } catch (_) {}
    }

    state = state.copyWith(
      currentServerId: serverId,
      currentChannelId: channelId,
      currentChannelName: channelName ?? 'Voice',
      isMuted: false,
      isDeafened: false,
      peerAudioStates: {},
      joinedAt: DateTime.now(),
    );

    // Group voice channels default to the loudspeaker on mobile.
    _setSpeakerRoute(true);

    // Initialize the WebRTC service.
    //
    // CRITICAL: the service's localPeerId is compared against ROUTABLE ids
    // (VC participants + signal senders are WS-device-keyed). On a linked
    // multi-device install identityProvider.peerId is the MASTER id — a
    // different keyspace — which made BOTH sides of a VC elect themselves
    // offerer ("lower peer_id offers" ran master-vs-device on one side and
    // device-vs-device on the other): deterministic offer glare, crossed
    // answers, mismatched DTLS, dead mic until the first camera reneg
    // re-synced SDP. Single-device installs never hit it (master == device).
    final localPeerId = await network_api.getLocalDevicePeerId() ??
        (ref.read(identityProvider).peerId ?? '');
    final iceConfig = ref.read(iceConfigProvider);

    _service = VoiceChannelService(
      localPeerId: localPeerId,
      iceServers: iceConfig,
    );

    // Load device preferences.
    _service!.preferredAudioInputDeviceId =
        await ref.read(audioInputDeviceProvider.future);
    _service!.preferredAudioOutputDeviceId =
        await ref.read(audioOutputDeviceProvider.future);
    _service!.preferredCameraDeviceId =
        await ref.read(cameraDeviceProvider.future);

    // Load audio quality preset.
    final preset = await ref.read(audioQualityProvider.future);
    _service!.opusBitrate = preset.bitrate;
    _service!.opusStereo = preset.stereo;

    // Load mic gain + voice enhancement.
    _service!.micGain = await ref.read(micGainProvider.future);
    _service!.voiceEnhance = await ref.read(voiceEnhanceProvider.future);
    _service!.enhanceMakeupDb = enhanceStrengthToMakeupDb(
        await ref.read(voiceEnhanceStrengthProvider.future));
    _service!.enhanceDynamic =
        await ref.read(voiceEnhanceDynamicProvider.future);
    _service!.noiseSuppressAi =
        await ref.read(noiseSuppressAiProvider.future);
    _service!.noiseSuppressEngine = noiseSuppressEngineToNative(
        await ref.read(noiseSuppressEngineProvider.future));

    // Wire VAD callback. Writes go to the dedicated vcSpeakingProvider (NOT
    // VoiceChannelState) so a speaking flip only rebuilds the glow consumers,
    // never every voiceChannelProvider watcher.
    _service!.onSpeakingChanged = (speaking) {
      ref.read(vcSpeakingProvider.notifier).set(speaking);
      // Sidechain for share-audio ducking: anyone talking (self included)
      // pulls received share audio down.
      ShareAudioLevel.setSpeaking(speaking.isNotEmpty);
    };

    // Wire peer connected callback — send screen share offer once audio PC is ready.
    _service!.onPeerConnected = (peerId) {
      if (_leaving || _stoppingScreenShare) return;

      // Ensure the file-transfer data channel (WebRtcService) exists with
      // this peer — needed for screen audio streaming on Windows.
      if (Platform.isWindows) {
        final webrtc = ref.read(webRtcProvider.notifier).service;
        if (!webrtc.hasPeerChannel(peerId)) {
          network_api.logFromDart(message: '[HOLLOW-AU-SCREEN] Ensuring WebRtcService DC for $peerId');
          webrtc.connectToPeer(peerId);
        }
      }

      if (state.isScreenSharing && _screenCaptureStream != null) {
        if (!_outgoingScreenShares.containsKey(peerId) &&
            _outgoingScreenShares.length < maxScreenShareOutgoing) {
          debugPrint('[HOLLOW-VC] Peer $peerId connected — sending screen share offer');
          _sendScreenShareToPeer(peerId);
        }
      }
    };

    // Wire screen audio receiver — incoming Opus packets from peers
    // (Windows sender → data channel → us). On Windows plays via out-of-process
    // exe; macOS/Linux not yet implemented (macOS uses Process Tap instead).
    {
      final webrtc = ref.read(webRtcProvider.notifier).service;
      webrtc.onScreenAudioReceived = (peerId, data) async {
        if (_screenAudioRenderer == null) {
          _screenAudioRenderer = ScreenAudioReceiver.forPlatform();
          final ok = await _screenAudioRenderer!.start();
          if (!ok) {
            _screenAudioRenderer = null;
            return;
          }
          ShareAudioLevel.attach(_screenAudioRenderer!);
        }
        _screenAudioRenderer?.pushPacket(data);
      };
    }

    // Share-audio playback level: seed the bus (carrying any live deafen
    // state into a rejoin) and live-update it when the slider / duck toggle
    // change mid-share.
    ShareAudioLevel.setDeafened(state.isDeafened);
    ShareAudioLevel.setVolumePercent(
        ref.read(shareAudioVolumeProvider).valueOrNull ??
            kShareAudioVolumeDefault);
    ShareAudioLevel.setDuckEnabled(
        ref.read(shareAudioDuckProvider).valueOrNull ?? true);
    ref.listen(shareAudioVolumeProvider, (_, next) {
      ShareAudioLevel.setVolumePercent(
          next.valueOrNull ?? kShareAudioVolumeDefault);
    });
    ref.listen(shareAudioDuckProvider, (_, next) {
      ShareAudioLevel.setDuckEnabled(next.valueOrNull ?? true);
    });

    // Wire camera video callback.
    _service!.onRemoteVideoChanged = (peerId, renderer) {
      if (renderer != null) {
        _remoteCameraRenderers[peerId] = renderer;
      } else {
        _remoteCameraRenderers.remove(peerId);
      }
      // Update peerCameraOn state to trigger UI rebuild.
      final cameras = Map.of(state.peerCameraOn);
      cameras[peerId] = renderer != null;
      if (renderer == null) cameras.remove(peerId);
      state = state.copyWith(peerCameraOn: cameras);
    };

    await _service!.startAudio(serverId, channelId);

    // Re-assert the speaker route now that the audio session actually
    // exists. The early _setSpeakerRoute(true) above ran BEFORE the service
    // was constructed — the platform audio bring-up (audioswitch activate on
    // Android, VPIO unit start on iOS) lands after it and can clobber the
    // route, leaving the channel on the earpiece despite the loudspeaker
    // default. One immediate pass plus one delayed pass once the audio unit
    // settles.
    _setSpeakerRoute(state.isSpeakerOn);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!_leaving && state.isInVoiceChannel) {
        _setSpeakerRoute(state.isSpeakerOn);
      }
    });

    // AI-NS fallback check for sessions that STARTED with the toggle on
    // (the toggle listener only covers mid-session flips). Logs the engine
    // status either way; re-captures internally if fallback is needed.
    if (_service?.noiseSuppressAi == true) {
      unawaited(Future.delayed(const Duration(seconds: 4), () {
        return _service?.reconcileNoiseSuppressAi().catchError((_) {}) ??
            Future.value();
      }));
    }

    // Update mic gain mid-session when user adjusts the slider.
    ref.listen(micGainProvider, (_, next) {
      final gain = next.valueOrNull ?? kMicGainDefault;
      _service?.updateMicGain(gain);
    });

    // Live A/B of the voice-enhancement chain mid-session.
    ref.listen(voiceEnhanceProvider, (_, next) {
      final enabled = next.valueOrNull ?? true;
      _service?.updateVoiceEnhance(enabled);
    });
    ref.listen(voiceEnhanceStrengthProvider, (_, next) {
      final pct = next.valueOrNull ?? kEnhanceStrengthDefault;
      _service?.updateVoiceEnhanceStrength(enhanceStrengthToMakeupDb(pct));
    });
    ref.listen(voiceEnhanceDynamicProvider, (_, next) {
      final enabled = next.valueOrNull ?? true;
      _service?.updateVoiceEnhanceDynamic(enabled);
    });

    // Live device switching mid-session (Settings > Audio & Video pickers).
    // Registered ONCE — this join path re-runs per join and would stack
    // duplicate listeners; the service methods also dedup by captured device.
    // Guard on prev==next: AsyncNotifier listeners also fire on initial load.
    if (!_deviceListenersWired) {
      _deviceListenersWired = true;
      ref.listen(audioInputDeviceProvider, (prev, next) {
        if (prev?.valueOrNull == next.valueOrNull) return;
        unawaited(_service
                ?.setAudioInputDevice(next.valueOrNull)
                .catchError((_) {}) ??
            Future.value());
      });
      ref.listen(cameraDeviceProvider, (prev, next) {
        if (prev?.valueOrNull == next.valueOrNull) return;
        unawaited(_applyCameraDevice(next.valueOrNull));
      });
      ref.listen(audioOutputDeviceProvider, (prev, next) {
        if (prev?.valueOrNull == next.valueOrNull) return;
        unawaited(_service
                ?.setAudioOutputDevice(next.valueOrNull)
                .catchError((_) {}) ??
            Future.value());
      });
      // AI noise suppression: flips the native DFN engine AND the WebRTC-NS
      // capture constraint — the service re-captures the mesh mic, so this
      // is heavy like a device switch and must never stack per join. The
      // delayed pass re-arms legacy NS if DFN proves unable to run here.
      ref.listen(noiseSuppressAiProvider, (prev, next) {
        if (prev?.valueOrNull == next.valueOrNull) return;
        final enabled = next.valueOrNull ?? false;
        unawaited(
            _service?.updateNoiseSuppressAi(enabled).catchError((_) {}) ??
                Future.value());
        if (enabled) {
          unawaited(Future.delayed(const Duration(seconds: 4), () {
            return _service?.reconcileNoiseSuppressAi().catchError((_) {}) ??
                Future.value();
          }));
        }
      });
      // AI-NS engine switch: live native handle swap (no re-capture, no
      // mesh reneg), then the same delayed fallback pass as the toggle.
      ref.listen(noiseSuppressEngineProvider, (prev, next) {
        if (prev?.valueOrNull == next.valueOrNull) return;
        final engine = noiseSuppressEngineToNative(
            next.valueOrNull ?? kNoiseSuppressEngineRnnoise);
        unawaited(
            _service?.updateNoiseSuppressEngine(engine).catchError((_) {}) ??
                Future.value());
        if (_service?.noiseSuppressAi == true) {
          unawaited(Future.delayed(const Duration(seconds: 4), () {
            return _service?.reconcileNoiseSuppressAi().catchError((_) {}) ??
                Future.value();
          }));
        }
      });
    }

    // Apply cached SFrame key (may have arrived before the service was created).
    // A RESTRICTED channel (per-channel MLS subgroup) uses ONLY its subgroup key
    // (serverId, channelId) — never the server-group key, which would defeat the
    // cryptographic isolation. A non-restricted channel uses the server-group key.
    final usesSubgroup = _channelUsesSubgroup(channelId);
    final cached = _sframeKeys[_sframeCacheKey(serverId, channelId)] ??
        (usesSubgroup ? null : _sframeKeys[_sframeCacheKey(serverId, null)]);
    if (cached != null) {
      debugPrint('[HOLLOW-VC] Applying cached SFrame key (epoch=${cached.epoch}) to new service');
      await _service!.setSframeKey(cached.epoch, Uint8List.fromList(cached.key));
    } else if (usesSubgroup) {
      // Subgroup key not delivered yet — the Welcome/Commit → MlsEpochChanged
      // (channelId) will rotate it in. Until then this channel has no SFrame key.
      debugPrint('[HOLLOW-VC] Restricted channel $channelId — awaiting subgroup SFrame key');
    }

    // Connect to existing participants in this channel.
    final existing = state.getParticipants(serverId, channelId);
    for (final peerId in existing) {
      if (peerId == localPeerId) continue;
      await _service!.onPeerJoinedMyChannel(peerId);
    }
  }

  /// Called when a remote peer joins our current voice channel.
  Future<void> onRemotePeerJoined(String peerId) async {
    if (_service == null || !state.isInVoiceChannel) return;
    await _service!.onPeerJoinedMyChannel(peerId);

    // If we're sharing our screen, send state to the late joiner so they
    // know we're sharing. The actual screen_offer is sent once the audio
    // PC reaches connected state (via onPeerConnected callback), ensuring
    // MLS is ready and the peer can decrypt it.
    if (state.isScreenSharing && _screenCaptureStream != null) {
      final json = <String, dynamic>{'enabled': true};
      if (state.screenShareLabel != null) {
        json['quality'] = state.screenShareLabel;
      }
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'screen_state',
        payload: jsonEncode(json),
      );
    }

    // If our camera is on, send camera_state to the late joiner.
    // (Video track is already added in connectToPeer via _addLocalVideoTracks.)
    if (state.isCameraOn) {
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'camera_state',
        payload: jsonEncode({'enabled': true}),
      );
    }

    // If we're muted/deafened, tell the late joiner — audio_state is
    // otherwise only sent on toggle, so they'd never see our badge.
    if (state.isMuted || state.isDeafened) {
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'audio_state',
        payload: jsonEncode({
          'muted': state.isMuted,
          'deafened': state.isDeafened,
        }),
      );
    }
  }

  /// Called when a remote peer leaves our current voice channel.
  Future<void> onRemotePeerLeft(String peerId) async {
    if (_service == null) return;
    await _service!.onPeerLeftMyChannel(peerId);
    // Clean up screen sharing for this peer.
    await _cleanupPeerScreenShare(peerId);
    // Clean up camera state for this peer.
    await _cleanupPeerCamera(peerId);
  }

  /// Handle incoming WebRTC signal for voice channel.
  Future<void> handleSignal(
    String peerId,
    String signalType,
    String payload,
    String serverId,
    String channelId,
  ) async {
    // Handle audio state signals locally (no WebRTC involved).
    if (signalType == 'audio_state') {
      _onRemoteAudioState(peerId, payload);
      return;
    }
    if (signalType == 'recording_start') {
      ref.read(recordingProvider.notifier).onRemoteRecordingStart(peerId);
      return;
    }
    if (signalType == 'recording_stop') {
      ref.read(recordingProvider.notifier).onRemoteRecordingStop(peerId);
      return;
    }
    // Handle camera state signals.
    if (signalType == 'camera_state') {
      _handleCameraState(peerId, payload);
      return;
    }
    // Handle screen share signals.
    if (signalType == 'screen_offer') {
      await _handleScreenOffer(peerId, payload, serverId, channelId);
      return;
    }
    if (signalType == 'screen_answer') {
      await _handleScreenAnswer(peerId, payload);
      return;
    }
    if (signalType == 'screen_ice') {
      await _handleScreenIce(peerId, payload);
      return;
    }
    if (signalType == 'screen_state') {
      _handleScreenState(peerId, payload);
      return;
    }
    if (_service == null) return;
    await _service!.handleSignal(
        peerId, signalType, payload, serverId, channelId);
  }

  /// Leave the current voice channel.
  Future<void> leaveChannel() async {
    if (!state.isInVoiceChannel || _leaving) return;
    _leaving = true;

    // Capture IDs before any state changes.
    final serverId = state.currentServerId!;
    final channelId = state.currentChannelId!;

    // Send leave signal to Rust FIRST — before any cleanup that could throw.
    // This ensures the server knows we left even if cleanup fails.
    try {
      await network_api.voiceChannelLeave(
        serverId: serverId,
        channelId: channelId,
      );
    } catch (e) {
      debugPrint('[HOLLOW-VC] voiceChannelLeave FFI error: $e');
    }

    // Now clean up (best-effort — errors won't block leave).
    await _teardownCall();

    _leaving = false;
  }

  /// Tear down all live call media: camera/screen renderers, screen audio, and
  /// the WebRTC service (closes every PC + stops mic/camera streams). Idempotent
  /// — safe to call when nothing is active. Shared by the user-initiated
  /// `leaveChannel()` and the server-forced leave path in `onLocalLeft()`.
  Future<void> _teardownCall() async {
    try {
      // Dispose local camera renderer.
      if (_localCameraRenderer != null) {
        _localCameraRenderer!.srcObject = null;
        await _localCameraRenderer!.dispose();
        _localCameraRenderer = null;
      }

      // Dispose remote camera renderers.
      for (final renderer in _remoteCameraRenderers.values) {
        renderer.srcObject = null;
        await renderer.dispose();
      }
      _remoteCameraRenderers.clear();

      // Clean up screen sharing (stops the screen-audio capturer).
      await _cleanupAllScreenShares();

      // Disarm the entire-screen anti-echo voice redirect AFTER the capturer is
      // gone (idempotent — also disarmed by stopScreenShare; covers leaving the
      // channel while sharing).
      await _disarmVoiceRedirect();

      // Stop out-of-process screen audio renderer.
      if (_screenAudioRenderer != null) {
        ShareAudioLevel.detach(_screenAudioRenderer!);
        await _screenAudioRenderer!.stop();
        _screenAudioRenderer = null;
      }
      // Channel left — any outgoing-share servo hold is stale.
      ShareAudioLevel.setSendingShareAudio(false);
      // Clear screen audio callback.
      try {
        ref.read(webRtcProvider.notifier).service.onScreenAudioReceived = null;
      } catch (_) {}

      // Clean up WebRTC (closes all PCs + stops camera/audio streams).
      if (_service != null) {
        await _service!.closeAll();
        _service = null;
      }
    } catch (e) {
      debugPrint('[HOLLOW-VC] call teardown error: $e');
      _service = null;
    }
  }

  /// Called after the local leave event arrives to update state.
  ///
  /// Two callers: (1) the user pressed leave → `leaveChannel()` already ran the
  /// media teardown and nulled `_service`; or (2) Rust FORCED us out (lost channel
  /// visibility / demoted / kicked) by emitting `VoiceChannelLeft` directly — in
  /// that case `_service` is still live and the call is still running, so we MUST
  /// run the teardown here. Detect the forced case by a non-null `_service`.
  void onLocalLeft() {
    _leaving = false;
    if (_service != null) {
      // Server-forced leave — the user-initiated path never ran. Hang up for real.
      // This callback is synchronous (a Rust event), so we can't await the
      // teardown here — record it as in-flight so a racing joinChannel waits for
      // it before spinning up a new call's PCs.
      debugPrint('[HOLLOW-VC] Forced leave — tearing down live call');
      final teardown = _teardownCall();
      _teardownInFlight = teardown;
      teardown.whenComplete(() {
        if (identical(_teardownInFlight, teardown)) _teardownInFlight = null;
      });
    }
    // Restore the default audio route (mobile) so the next call doesn't
    // inherit a stale speakerphone state.
    if (_isMobile) {
      unawaited(Helper.setSpeakerphoneOn(false).catchError((_) {}));
    }
    state = state.copyWith(clearCurrent: true);
    // Speaking state lives outside this state object — clear it with the rest.
    ref.read(vcSpeakingProvider.notifier).reset();
  }

  void toggleMute() {
    if (_leaving) return;
    final newMuted = !state.isMuted;
    state = state.copyWith(isMuted: newMuted);
    _service?.setMuted(newMuted);
    _broadcastAudioState();
  }

  void toggleDeafen() {
    if (_leaving) return;
    final newDeafened = !state.isDeafened;
    state = state.copyWith(
      isMuted: newDeafened ? true : state.isMuted,
      isDeafened: newDeafened,
    );
    // Mute our mic when deafened.
    _service?.setMuted(newDeafened || state.isMuted);
    // Silence all remote audio when deafened.
    _service?.setDeafened(newDeafened);
    // setDeafened only zeroes WebRTC voice tracks — share audio rides its own
    // data-channel player and must be silenced explicitly.
    ShareAudioLevel.setDeafened(newDeafened);
    _broadcastAudioState();
  }

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Route audio to the loudspeaker (true) or earpiece (false). Mobile only.
  void _setSpeakerRoute(bool speaker) {
    if (!_isMobile) return;
    unawaited(Helper.setSpeakerphoneOn(speaker).catchError((_) {}));
    state = state.copyWith(isSpeakerOn: speaker);
  }

  /// Toggle loudspeaker/earpiece while in a voice channel. Mobile only.
  void toggleSpeaker() {
    if (_leaving || !state.isInVoiceChannel) return;
    _setSpeakerRoute(!state.isSpeakerOn);
  }

  /// Set per-peer volume and apply it.
  void setPeerVolume(String peerId, double volume) {
    final volumes = Map.of(state.peerVolumes);
    volumes[peerId] = volume;
    state = state.copyWith(peerVolumes: volumes);
    _service?.setRemoteVolume(peerId, volume);
  }

  /// Handle peer disconnect — remove from all voice channels.
  Future<void> onPeerDisconnected(String peerId) async {
    ref.read(recordingProvider.notifier).onPeerDisconnected(peerId);
    final updated = _deepCopyParticipants();
    for (final serverChannels in updated.values) {
      for (final channelPeers in serverChannels.values) {
        channelPeers.remove(peerId);
      }
      serverChannels.removeWhere((_, peers) => peers.isEmpty);
    }
    updated.removeWhere((_, channels) => channels.isEmpty);
    final audioStates = Map.of(state.peerAudioStates)..remove(peerId);
    state = state.copyWith(
        participants: updated, peerAudioStates: audioStates);

    // Tear down WebRTC connection if they were in our channel (awaited so the
    // peer's PC + thread-set is fully gone, not racing the next event).
    await _service?.closePeer(peerId);
    // Clean up screen sharing for this peer.
    await _cleanupPeerScreenShare(peerId);
    // Clean up camera state for this peer.
    await _cleanupPeerCamera(peerId);
  }

  // ---------------------------------------------------------------
  //  Audio state broadcasting
  // ---------------------------------------------------------------

  /// Send our mute/deafen state to all peers in the current voice channel.
  void _broadcastAudioState() {
    if (!state.isInVoiceChannel) return;
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final peers = state.getParticipants(
        state.currentServerId!, state.currentChannelId!);
    final payload = jsonEncode({
      'muted': state.isMuted,
      'deafened': state.isDeafened,
    });
    for (final peerId in peers) {
      if (peerId == localPeerId) continue;
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'audio_state',
        payload: payload,
      );
    }
  }

  /// Handle a remote peer's audio state update.
  void _onRemoteAudioState(String peerId, String payload) {
    try {
      final v = jsonDecode(payload);
      final muted = v['muted'] as bool? ?? false;
      final deafened = v['deafened'] as bool? ?? false;
      final audioStates = Map.of(state.peerAudioStates);
      audioStates[peerId] =
          PeerAudioState(isMuted: muted, isDeafened: deafened);
      state = state.copyWith(peerAudioStates: audioStates);
    } catch (_) {}
  }

  // ---------------------------------------------------------------
  //  Camera (video)
  // ---------------------------------------------------------------

  /// Toggle camera on/off.
  Future<void> toggleCamera() async {
    if (_service == null || !state.isInVoiceChannel || _leaving) return;

    if (!state.isCameraOn) {
      // Turn camera ON.
      final stream = await _service!.startCamera();
      if (stream == null) return;

      // Create local renderer for self-view.
      _localCameraRenderer = RTCVideoRenderer();
      await _localCameraRenderer!.initialize();
      _localCameraRenderer!.srcObject = stream;

      state = state.copyWith(
        isCameraOn: true,
        isFrontCamera: _service!.useFrontCamera,
      );
      _broadcastCameraState(true);

      // Camera on implies hands-off use — switch to the loudspeaker
      // (parity with the DM call path).
      if (_isMobile && !state.isSpeakerOn) {
        _setSpeakerRoute(true);
      }
    } else {
      // Turn camera OFF.
      await _service!.stopCamera();

      // Dispose local renderer.
      if (_localCameraRenderer != null) {
        _localCameraRenderer!.srcObject = null;
        await _localCameraRenderer!.dispose();
        _localCameraRenderer = null;
      }

      state = state.copyWith(isCameraOn: false);
      _broadcastCameraState(false);
    }

    // Either camera flip restarts the platform audio unit (iOS VPIO
    // especially), which can drop the active route — re-assert once it
    // settles (parity with the DM toggleVideo path).
    if (_isMobile) {
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!_leaving && state.isInVoiceChannel) {
          _setSpeakerRoute(state.isSpeakerOn);
        }
      });
    }
  }

  /// Switch between front and back camera (mobile).
  Future<void> switchCamera() async {
    if (_service == null || !state.isCameraOn || _leaving) return;
    final front = await _service!.switchCamera();
    state = state.copyWith(isFrontCamera: front);
  }

  /// Broadcast our camera state to all peers in the current voice channel.
  void _broadcastCameraState(bool enabled) {
    if (!state.isInVoiceChannel) return;
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final peers = state.getParticipants(
        state.currentServerId!, state.currentChannelId!);
    final payload = jsonEncode({'enabled': enabled});
    for (final peerId in peers) {
      if (peerId == localPeerId) continue;
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'camera_state',
        payload: payload,
      );
    }
  }

  /// Clean up camera state for a peer that left.
  Future<void> _cleanupPeerCamera(String peerId) async {
    final renderer = _remoteCameraRenderers.remove(peerId);
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    if (state.peerCameraOn.containsKey(peerId)) {
      final cameras = Map.of(state.peerCameraOn)..remove(peerId);
      state = state.copyWith(peerCameraOn: cameras);
    }
  }

  /// Handle a remote peer's camera state update.
  void _handleCameraState(String peerId, String payload) {
    try {
      final v = jsonDecode(payload);
      final enabled = v['enabled'] as bool? ?? false;
      final cameras = Map.of(state.peerCameraOn);
      if (enabled) {
        cameras[peerId] = true;
      } else {
        cameras.remove(peerId);
        // Don't dispose the renderer here — keep it alive so that when the
        // peer turns camera back on, the same renderer/stream can resume
        // receiving frames (onTrack won't fire again for transceiver reuse).
        // The renderer is only disposed when the peer actually leaves.
      }
      state = state.copyWith(peerCameraOn: cameras);
    } catch (_) {}
  }

  // ---------------------------------------------------------------
  //  Screen sharing
  // ---------------------------------------------------------------

  /// Start sharing our screen to all peers in the current voice channel.
  Future<void> startScreenShare(
    String sourceId,
    int width,
    int height,
    int fps, {
    bool shareAudio = false,
    int pid = 0,
    int windowHwnd = 0,
    ScreenContentProfile profile = ScreenContentProfile.motion,
  }) async {
    if (!state.isInVoiceChannel || _leaving) return;
    if (state.isScreenSharing) return;

    // Block if already sharing in a DM call.
    final callState = ref.read(callProvider);
    if (callState.isScreenSharing) {
      debugPrint('[HOLLOW-VC] Cannot share screen — already sharing in DM call');
      return;
    }

    debugPrint('[HOLLOW-VC] Starting screen share: $sourceId ${width}x$height @${fps}fps');
    _screenShareMaxWidth = width;
    _screenShareMaxHeight = height;
    _screenShareFps = fps;
    _screenShareAudio = shareAudio;
    _screenSharePid = pid;
    _screenShareHwnd = windowHwnd;
    _screenShareProfile = profile;

    // Capture screen ONCE. Source enumeration is desktop-only; mobile
    // captures THE screen (MediaProjection / ReplayKit broadcast).
    if (Platform.isAndroid) {
      // Constraints are ignored by the Android plugin (MediaProjection
      // captures at native display size; the consent dialog handles
      // permission). The per-peer encoder cap does the downscaling.
      _screenCaptureStream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
    } else if (Platform.isIOS) {
      // 'broadcast' selects the ReplayKit Broadcast Upload Extension path and
      // auto-presents the RPSystemBroadcastPickerView.
      _screenCaptureStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {'deviceId': 'broadcast'},
        'audio': false,
      });
    } else {
      await desktopCapturer.getSources(
          types: [SourceType.Screen, SourceType.Window]);
      // On Windows and Linux, audio goes via data channel (not a WebRTC audio
      // track) so never request audio in getDisplayMedia — the old
      // WASAPI→AudioSource path crashes on Windows and yields nothing on Linux.
      final getDisplayAudio =
          shareAudio && !Platform.isWindows && !Platform.isLinux;

      _screenCaptureStream = await navigator.mediaDevices.getDisplayMedia({
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

    // Create local preview renderer so the sharer can see their own screen.
    _localScreenPreviewRenderer = RTCVideoRenderer();
    await _localScreenPreviewRenderer!.initialize();
    _localScreenPreviewRenderer!.srcObject = _screenCaptureStream;

    // Build quality label (e.g. "1080p60", "4K30"). Use the SHORT side so a
    // portrait mobile capture (1080x1920) reads "1080p", same as landscape.
    const resLabels = {360: '360p', 480: '480p', 720: '720p', 1080: '1080p', 1440: '1440p', 2160: '4K'};
    final shortSide = height < width ? height : width;
    final qualityLabel = '${resLabels[shortSide] ?? '${shortSide}p'}$fps';

    final localPeerId = ref.read(identityProvider).peerId ?? '';
    state = state.copyWith(
      isScreenSharing: true,
      screenShareLabel: qualityLabel,
      focusedScreenSharePeerId: localPeerId,
    );

    // Sharing WITH audio: freeze the mic servo for the whole share so
    // speaker bleed of the shared music can't re-calibrate the trim.
    if (shareAudio) {
      ShareAudioLevel.setSendingShareAudio(true);
    }

    // ENTIRE-SCREEN anti-echo (Windows): in a voice channel we're already in a
    // call with everyone, so the peers' voices play from hollow.exe and a
    // whole-system capture would re-capture them. Redirect ALL peers' inbound
    // audio to an out-of-process renderer (one child, mixed) and exclude THAT
    // pid from the capture — keeps Hollow's own in-app media, drops the voices.
    // Armed ONCE here (covers every peer); the per-peer capture below passes the
    // resulting exclude pid. Only for an entire-screen share (no per-app target).
    _screenShareExcludePid = 0;
    _voiceRedirectActive = false;
    final isEntireScreen = pid == 0 && windowHwnd == 0;
    if (Platform.isWindows && shareAudio && isEntireScreen) {
      try {
        final trackIds =
            await _service?.getAllRemoteAudioTrackIds() ?? const <String>[];
        if (trackIds.isNotEmpty) {
          _screenShareExcludePid = await Helper.voiceRedirectStart(trackIds);
          _voiceRedirectActive = _screenShareExcludePid != 0;
          debugPrint('[HOLLOW-AU-SCREEN] VC voice redirect '
              '${_voiceRedirectActive ? "armed (pid=$_screenShareExcludePid, "
                  "${trackIds.length} track(s))" : "did not start"}');
        } else {
          debugPrint('[HOLLOW-AU-SCREEN] VC: no remote audio tracks to redirect');
        }
      } catch (e) {
        debugPrint('[HOLLOW-AU-SCREEN] VC voice redirect failed to arm: $e');
      }
    }

    // Send screen share to each peer in the channel (up to cap).
    final peers = state.getParticipants(
        state.currentServerId!, state.currentChannelId!);
    for (final peerId in peers) {
      if (peerId == localPeerId) continue;
      if (_outgoingScreenShares.length >= maxScreenShareOutgoing) {
        debugPrint('[HOLLOW-VC] Screen share outgoing cap reached ($maxScreenShareOutgoing)');
        break;
      }
      await _sendScreenShareToPeer(peerId);
    }

    // MOBILE: one central audio capture for the whole channel. Fanning at
    // send time over _outgoingScreenShares.keys picks up late joiners
    // automatically (their entry is added by _sendScreenShareToPeer).
    if (shareAudio && (Platform.isAndroid || Platform.isIOS)) {
      final webrtc = ref.read(webRtcProvider.notifier).service;
      _mobileShareAudioCapturer = MobileScreenAudioCapturer();
      final ok = await _mobileShareAudioCapturer!.start(onPacket: (packet) {
        for (final sharePeerId in _outgoingScreenShares.keys) {
          webrtc.sendScreenAudio(sharePeerId, packet);
        }
      });
      if (!ok) {
        debugPrint('[HOLLOW-AU-SCREEN] VC mobile audio capture unavailable');
        _mobileShareAudioCapturer = null;
      }
    }

    // Broadcast screen_state(enabled: true) to all peers.
    _broadcastScreenState(true);

    // Start track poller (detect window close).
    _startScreenTrackPoller();
  }

  /// Stop the central mobile share-audio capture (no-op on desktop / when
  /// not running). Nulls the field FIRST so a re-entrant stop can't double-stop.
  Future<void> _stopMobileShareAudio() async {
    final capturer = _mobileShareAudioCapturer;
    _mobileShareAudioCapturer = null;
    if (capturer != null) {
      try {
        await capturer.stop();
      } catch (_) {}
    }
  }

  bool _stoppingScreenShare = false;

  /// Stop sharing our screen.
  Future<void> stopScreenShare() async {
    if (!state.isScreenSharing || _stoppingScreenShare) return;
    _stoppingScreenShare = true;
    debugPrint('[HOLLOW-VC] Stopping screen share');
    ShareAudioLevel.setSendingShareAudio(false);

    try {
      _screenTrackPoller?.cancel();
      _screenTrackPoller = null;

      // Stop the central mobile audio capture FIRST (it isn't owned by any
      // per-peer service), then close all outgoing screen share PCs (which
      // stops the desktop per-peer capturers) BEFORE disarming the redirect,
      // so the brief window where the VC voices' in-process volume is
      // restored isn't re-captured.
      await _stopMobileShareAudio();
      for (final service in _outgoingScreenShares.values) {
        try { await service.close(); } catch (_) {}
      }
      _outgoingScreenShares.clear();

      // Disarm the entire-screen anti-echo voice redirect (restore VC voices +
      // kill the renderer child) now that the capturer is gone.
      await _disarmVoiceRedirect();

      // Dispose local preview renderer.
      if (_localScreenPreviewRenderer != null) {
        _localScreenPreviewRenderer!.srcObject = null;
        await _localScreenPreviewRenderer!.dispose();
        _localScreenPreviewRenderer = null;
      }

      // Stop capture stream.
      _screenCaptureStream?.getTracks().forEach((t) => t.stop());
      _screenCaptureStream?.dispose();
      _screenCaptureStream = null;

      // Broadcast screen_state(enabled: false).
      _broadcastScreenState(false);

      // Update local state — if we were the focused sharer, clear focus
      // and pick the next remote sharer if any.
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      String? newFocus = state.focusedScreenSharePeerId;
      bool clearFocus = false;
      if (newFocus == localPeerId) {
        final remoteSharerId = state.peerScreenSharing.entries
            .where((e) => e.value)
            .map((e) => e.key)
            .firstOrNull;
        newFocus = remoteSharerId;
        clearFocus = remoteSharerId == null;
      }
      state = state.copyWith(
        isScreenSharing: false,
        clearScreenShareLabel: true,
        focusedScreenSharePeerId: clearFocus ? null : newFocus,
        clearFocusedSharer: clearFocus,
      );
    } finally {
      _stoppingScreenShare = false;
    }
  }

  /// Disarm the entire-screen anti-echo voice redirect if armed: restores the
  /// VC voices to normal in-process playout and shuts the renderer child down.
  /// Safe/no-op when not armed.
  Future<void> _disarmVoiceRedirect() async {
    _screenShareExcludePid = 0;
    if (!_voiceRedirectActive) return;
    _voiceRedirectActive = false;
    try {
      await Helper.voiceRedirectStop();
      debugPrint('[HOLLOW-AU-SCREEN] VC voice redirect disarmed');
    } catch (e) {
      debugPrint('[HOLLOW-AU-SCREEN] VC voice redirect disarm failed: $e');
    }
  }

  /// Set which sharer is displayed full-bleed.
  void setFocusedScreenShare(String peerId) {
    state = state.copyWith(focusedScreenSharePeerId: peerId);
  }

  /// Set which source is focused (for mixed mode: screen share + cameras).
  void setFocusedSource(String peerId, String sourceType) {
    state = state.copyWith(
      focusedScreenSharePeerId: peerId,
      focusedSourceType: sourceType,
    );
  }

  /// Send our screen share to a specific peer (creates outgoing ScreenShareService).
  Future<void> _sendScreenShareToPeer(String peerId) async {
    if (_screenCaptureStream == null) return;

    final iceConfig = ref.read(iceConfigProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    final service = ScreenShareService(
      localPeerId: localPeerId,
      iceServers: iceConfig,
    );

    service.onIceCandidate = (candidate) {
      if (!state.isInVoiceChannel) return;
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'screen_ice',
        payload: jsonEncode({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'role': 'outgoing',
        }),
      );
    };

    // Close+remove any prior outgoing service for this peer before overwriting
    // the map entry — otherwise the old ScreenShareService (with its live PC +
    // thread-set) is orphaned and can never be closed (leak).
    await _outgoingScreenShares.remove(peerId)?.close();
    _outgoingScreenShares[peerId] = service;

    try {
      final sdp = await service.createOfferFromStream(
        _screenCaptureStream!,
        maxWidth: _screenShareMaxWidth,
        maxHeight: _screenShareMaxHeight,
        fps: _screenShareFps,
        profile: _screenShareProfile,
      );

      // Enable SFrame E2EE on the outgoing screen share PC.
      if (service.pc != null && _service?.frameCryptor != null) {
        await _enableSframeOnScreenSharePc(
            service.pc!, _service!.frameCryptor!, peerId, isSender: true);
      }

      // Flush any ICE candidates that arrived before this service was created.
      final earlyKey = 'outgoing:$peerId';
      final early = _earlyScreenIce.remove(earlyKey);
      if (early != null && early.isNotEmpty) {
        debugPrint('[HOLLOW-VC] Flushing ${early.length} early screen ICE for outgoing:$peerId');
        for (final ice in early) {
          await service.handleIceCandidate(
            ice['candidate'] as String,
            ice['sdpMid'] as String?,
            ice['sdpMLineIndex'] as int?,
          );
        }
      }

      if (!state.isInVoiceChannel) return;

      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'screen_offer',
        payload: jsonEncode({'sdp': sdp}),
      );

      // Start screen audio capture via the data channel on the data-channel-audio
      // DESKTOP platforms: Windows (WASAPI), Linux (PulseAudio monitor), and
      // macOS 13.0+ (ScreenCaptureKit) — each peer gets its own capturer exe.
      // MOBILE is deliberately NOT here: it runs ONE central capture in
      // startScreenShare (the Rust encoder is a process-global singleton) that
      // fans packets to _outgoingScreenShares.keys, this peer included.
      // Sends Opus packets via the existing WebRtcService data channel.
      final dcAudio = Platform.isWindows ||
          Platform.isLinux ||
          (Platform.isMacOS && MacOsScreenAudioSupport.hasSckAudio);
      if (_screenShareAudio && dcAudio && _screenCaptureStream != null) {
        final webrtc = ref.read(webRtcProvider.notifier).service;
        debugPrint('[HOLLOW-AU-SCREEN] Starting screen audio for peer $peerId '
            '(hasDC=${webrtc.hasPeerChannel(peerId)})');
        await service.startScreenAudioCapture(
          _screenCaptureStream!.id,
          pid: _screenSharePid,
          windowHwnd: _screenShareHwnd,
          excludePid: _screenShareExcludePid,
          onPacket: (packet) {
            webrtc.sendScreenAudio(peerId, packet);
          },
        );

        // Late-joiner anti-echo: if the voice redirect is already armed (entire-
        // screen+audio share started earlier), redirect THIS peer's voice too so
        // it doesn't play from hollow.exe and get re-captured. voiceRedirectStart
        // is incremental — it only AddSinks track ids not already redirected, and
        // the child pid (hence excludePid) is unchanged, so the capturer needs no
        // restart. No-op if this peer's tracks are already redirected.
        if (_voiceRedirectActive) {
          try {
            final ids =
                await _service?.getAllRemoteAudioTrackIds() ?? const <String>[];
            if (ids.isNotEmpty) {
              await Helper.voiceRedirectStart(ids);
              debugPrint('[HOLLOW-AU-SCREEN] VC redirect refreshed for late peer '
                  '$peerId (${ids.length} track(s))');
            }
          } catch (e) {
            debugPrint('[HOLLOW-AU-SCREEN] late-peer redirect refresh failed: $e');
          }
        }
      }
    } catch (e) {
      // A throw mid-setup leaves a half-built service (live PC) in the map.
      // Tear it down so its thread-set can't leak.
      debugPrint('[HOLLOW-VC] _sendScreenShareToPeer($peerId) failed: $e');
      await _outgoingScreenShares.remove(peerId)?.close();
      rethrow;
    }
  }

  /// Handle incoming screen share offer from a peer.
  /// Uses the serverId/channelId from the signal dispatch (not from state)
  /// because the signal may arrive before onLocalJoined sets the state.
  Future<void> _handleScreenOffer(
    String peerId,
    String payload,
    String serverId,
    String channelId,
  ) async {
    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    debugPrint('[HOLLOW-VC] Received screen offer from $peerId');

    if (!_incomingScreenShares.containsKey(peerId) &&
        _incomingScreenShares.length >= maxScreenShareIncoming) {
      debugPrint('[HOLLOW-VC] Rejecting screen offer from $peerId — incoming cap ($maxScreenShareIncoming) reached');
      return;
    }

    // Mark this peer as sharing and auto-focus (screen_offer may arrive before screen_state).
    final sharing = Map.of(state.peerScreenSharing);
    sharing[peerId] = true;
    state = state.copyWith(
      peerScreenSharing: sharing,
      focusedScreenSharePeerId:
          state.focusedScreenSharePeerId ?? peerId,
    );

    final iceConfig = ref.read(iceConfigProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    // Close existing incoming service for this peer if any.
    await _incomingScreenShares[peerId]?.close();

    final service = ScreenShareService(
      localPeerId: localPeerId,
      iceServers: iceConfig,
    );

    // Set preferred audio output.
    service.preferredAudioOutputDeviceId =
        await ref.read(audioOutputDeviceProvider.future);

    service.onIceCandidate = (candidate) {
      network_api.voiceChannelSendSignal(
        serverId: serverId,
        channelId: channelId,
        peerId: peerId,
        signalType: 'screen_ice',
        payload: jsonEncode({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'role': 'incoming',
        }),
      );
    };

    service.onRemoteTrackReady = () {
      debugPrint('[HOLLOW-VC] Screen share track ready from $peerId');
      // Force a state rebuild so the UI picks up the renderer.
      // Also auto-focus if no one is focused yet.
      state = state.copyWith(
        focusedScreenSharePeerId:
            state.focusedScreenSharePeerId ?? peerId,
      );
    };

    _incomingScreenShares[peerId] = service;

    final answerSdp = await service.handleOffer(sdp);

    // Enable SFrame E2EE on the incoming screen share PC.
    if (service.pc != null && _service?.frameCryptor != null) {
      await _enableSframeOnScreenSharePc(
          service.pc!, _service!.frameCryptor!, peerId, isSender: false);
    }

    // Flush any ICE candidates that arrived before this service was created.
    final earlyKey = 'incoming:$peerId';
    final early = _earlyScreenIce.remove(earlyKey);
    if (early != null && early.isNotEmpty) {
      debugPrint('[HOLLOW-VC] Flushing ${early.length} early screen ICE for incoming:$peerId');
      for (final ice in early) {
        await service.handleIceCandidate(
          ice['candidate'] as String,
          ice['sdpMid'] as String?,
          ice['sdpMLineIndex'] as int?,
        );
      }
    }

    network_api.voiceChannelSendSignal(
      serverId: serverId,
      channelId: channelId,
      peerId: peerId,
      signalType: 'screen_answer',
      payload: jsonEncode({'sdp': answerSdp}),
    );
  }

  /// Handle incoming screen share answer.
  Future<void> _handleScreenAnswer(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    debugPrint('[HOLLOW-VC] Received screen answer from $peerId');
    final service = _outgoingScreenShares[peerId];
    if (service != null) {
      await service.handleAnswer(sdp);
    }
  }

  /// Handle incoming screen share ICE candidate.
  Future<void> _handleScreenIce(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final candidate = v['candidate'] as String? ?? '';
    final sdpMid = v['sdpMid'] as String?;
    final sdpMLineIndex = v['sdpMLineIndex'] as int?;
    final role = v['role'] as String? ?? '';

    // Route to the correct service based on role.
    final ScreenShareService? service;
    final String queueKey;
    if (role == 'incoming') {
      // Their incoming = our outgoing.
      service = _outgoingScreenShares[peerId];
      queueKey = 'outgoing:$peerId';
    } else {
      // Their outgoing = our incoming.
      service = _incomingScreenShares[peerId];
      queueKey = 'incoming:$peerId';
    }
    if (service != null) {
      await service.handleIceCandidate(candidate, sdpMid, sdpMLineIndex);
    } else {
      // Service not created yet — queue for later flush.
      _earlyScreenIce.putIfAbsent(queueKey, () => []).add({
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      });
    }
  }

  /// Handle screen share state change from a peer.
  void _handleScreenState(String peerId, String payload) {
    final v = jsonDecode(payload);
    final enabled = v['enabled'] as bool? ?? false;
    final quality = v['quality'] as String?;

    debugPrint('[HOLLOW-VC] Screen state from $peerId: enabled=$enabled quality=$quality');

    final sharing = Map.of(state.peerScreenSharing);
    final labels = Map.of(state.peerScreenShareLabels);
    if (enabled) {
      sharing[peerId] = true;
      if (quality != null) labels[peerId] = quality;
      // Auto-focus if no one is focused.
      if (state.focusedScreenSharePeerId == null) {
        state = state.copyWith(
          peerScreenSharing: sharing,
          peerScreenShareLabels: labels,
          focusedScreenSharePeerId: peerId,
        );
        return;
      }
    } else {
      sharing.remove(peerId);
      labels.remove(peerId);
      // Clean up incoming service.
      _cleanupPeerScreenShare(peerId);
      // If the leaving sharer was focused, switch to another.
      if (state.focusedScreenSharePeerId == peerId) {
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        final nextFocus = state.isScreenSharing
            ? localPeerId
            : sharing.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .firstOrNull;
        state = state.copyWith(
          peerScreenSharing: sharing,
          peerScreenShareLabels: labels,
          focusedScreenSharePeerId: nextFocus,
          clearFocusedSharer: nextFocus == null,
        );
        return;
      }
    }
    state = state.copyWith(
      peerScreenSharing: sharing,
      peerScreenShareLabels: labels,
    );
  }

  /// Broadcast our screen share state to all peers.
  void _broadcastScreenState(bool enabled) {
    if (!state.isInVoiceChannel) return;
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final peers = state.getParticipants(
        state.currentServerId!, state.currentChannelId!);
    final json = <String, dynamic>{'enabled': enabled};
    if (enabled && state.screenShareLabel != null) {
      json['quality'] = state.screenShareLabel;
    }
    final payload = jsonEncode(json);
    for (final peerId in peers) {
      if (peerId == localPeerId) continue;
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'screen_state',
        payload: payload,
      );
    }
  }

  /// Clean up screen share services for a specific peer.
  Future<void> _cleanupPeerScreenShare(String peerId) async {
    // Close incoming screen share from this peer.
    final incoming = _incomingScreenShares.remove(peerId);
    if (incoming != null) {
      await incoming.close();
    }
    // Close outgoing screen share to this peer.
    final outgoing = _outgoingScreenShares.remove(peerId);
    if (outgoing != null) {
      await outgoing.close();
    }
    // Update peerScreenSharing map.
    if (state.peerScreenSharing.containsKey(peerId)) {
      final sharing = Map.of(state.peerScreenSharing)..remove(peerId);
      // If the removed peer was focused, switch to another sharer.
      if (state.focusedScreenSharePeerId == peerId) {
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        final nextFocus = state.isScreenSharing
            ? localPeerId
            : sharing.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .firstOrNull;
        state = state.copyWith(
          peerScreenSharing: sharing,
          focusedScreenSharePeerId: nextFocus,
          clearFocusedSharer: nextFocus == null,
        );
      } else {
        state = state.copyWith(peerScreenSharing: sharing);
      }
    }
  }

  /// Clean up all screen share services.
  Future<void> _cleanupAllScreenShares() async {
    _screenTrackPoller?.cancel();
    _screenTrackPoller = null;

    await _stopMobileShareAudio();
    for (final service in _outgoingScreenShares.values) {
      await service.close();
    }
    _outgoingScreenShares.clear();

    for (final service in _incomingScreenShares.values) {
      await service.close();
    }
    _incomingScreenShares.clear();

    if (_localScreenPreviewRenderer != null) {
      _localScreenPreviewRenderer!.srcObject = null;
      await _localScreenPreviewRenderer!.dispose();
      _localScreenPreviewRenderer = null;
    }

    _screenCaptureStream?.getTracks().forEach((t) => t.stop());
    await _screenCaptureStream?.dispose();
    _screenCaptureStream = null;
    _earlyScreenIce.clear();

    state = state.copyWith(
      isScreenSharing: false,
      peerScreenSharing: const {},
      clearFocusedSharer: true,
    );
  }

  /// Poll the screen capture track to detect window close (every 2s).
  void _startScreenTrackPoller() {
    _screenTrackPoller?.cancel();
    bool stopping = false;
    _screenTrackPoller = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (stopping) return;
      if (_screenCaptureStream == null) {
        _screenTrackPoller?.cancel();
        return;
      }
      final tracks = _screenCaptureStream!.getVideoTracks();
      if (tracks.isEmpty || tracks.first.muted == true) {
        stopping = true;
        debugPrint('[HOLLOW-VC] Screen track ended — stopping share');
        _screenTrackPoller?.cancel();
        await stopScreenShare();
      }
    });
  }

  /// Handle MLS epoch change — rotate SFrame key for voice E2EE.
  ///
  /// `channelId == null` is the server-wide group key (non-restricted voice
  /// channels); `channelId != null` is a restricted channel's MLS subgroup key
  /// (per-channel subgroups), which applies only to that voice channel.
  Future<void> onEpochChanged(
      String serverId, int epoch, Uint8List sframeKey,
      {String? channelId}) async {
    // Always cache — the event may arrive before onLocalJoined sets currentServerId.
    _sframeKeys[_sframeCacheKey(serverId, channelId)] =
        (epoch: epoch, key: Uint8List.fromList(sframeKey));

    if (state.currentServerId != serverId) return;
    if (!state.isInVoiceChannel || _service == null) return;

    // Only apply a key that belongs to the channel we're actually in: a subgroup
    // key (channelId set) must match the current channel; the server-group key
    // (channelId null) applies to whatever non-restricted channel we're in.
    if (channelId != null && state.currentChannelId != channelId) return;

    debugPrint('[HOLLOW-VC] MLS epoch changed: $epoch '
        '(${channelId == null ? "server group" : "subgroup $channelId"}) '
        '— rotating SFrame key');
    await _service!.setSframeKey(epoch, sframeKey);
  }

  /// Handle voice channel mode change (mesh <-> gossip).
  /// Called by event_provider when Rust emits VoiceChannelModeChanged.
  Future<void> onModeChanged(
    String serverId,
    String channelId,
    String mode,
    List<String> gossipNeighbors,
  ) async {
    if (!state.isInVoiceChannel) return;
    if (state.currentServerId != serverId ||
        state.currentChannelId != channelId) return;

    final neighborSet = gossipNeighbors.toSet();
    final oldMode = state.voiceMode;

    debugPrint(
        '[HOLLOW-VC] Mode: $oldMode → $mode (${gossipNeighbors.length} gossip neighbors)');

    state = state.copyWith(
      voiceMode: mode,
      gossipNeighbors: neighborSet,
    );

    if (_service == null) return;
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    if (mode == 'gossip' && oldMode == 'mesh') {
      // Mesh → Gossip: close audio PCs to non-neighbor peers,
      // keep PCs to gossip neighbors.
      final existing = state.getParticipants(serverId, channelId);
      for (final peerId in existing) {
        if (peerId == localPeerId) continue;
        if (!neighborSet.contains(peerId)) {
          // Not a gossip neighbor — close audio PC.
          debugPrint('[HOLLOW-VC] Gossip: closing non-neighbor $peerId');
          await _service!.onPeerLeftMyChannel(peerId);
        }
      }
      // Ensure we have PCs to all gossip neighbors.
      for (final peerId in neighborSet) {
        if (peerId == localPeerId) continue;
        await _service!.onPeerJoinedMyChannel(peerId);
      }
      // Set gossip mode on the service for track forwarding.
      _service!.gossipMode = true;
      _service!.gossipNeighbors = neighborSet;
    } else if (mode == 'mesh' && oldMode == 'gossip') {
      // Gossip → Mesh: create audio PCs to all participants.
      _service!.gossipMode = false;
      _service!.gossipNeighbors = {};
      final existing = state.getParticipants(serverId, channelId);
      for (final peerId in existing) {
        if (peerId == localPeerId) continue;
        await _service!.onPeerJoinedMyChannel(peerId);
      }
    } else if (mode == 'gossip') {
      // Gossip neighbor update (mode didn't change, just neighbor list).
      _service!.gossipNeighbors = neighborSet;
      // Close PCs to peers no longer in neighbor set.
      final currentPeers = _service!.connectedPeerIds;
      for (final peerId in currentPeers) {
        if (!neighborSet.contains(peerId)) {
          debugPrint('[HOLLOW-VC] Gossip update: closing non-neighbor $peerId');
          await _service!.onPeerLeftMyChannel(peerId);
        }
      }
      // Connect to new neighbors.
      for (final peerId in neighborSet) {
        if (peerId == localPeerId) continue;
        await _service!.onPeerJoinedMyChannel(peerId);
      }
    }
  }

  Map<String, Map<String, Set<String>>> _deepCopyParticipants() {
    return state.participants.map(
      (sid, channels) => MapEntry(
        sid,
        channels.map(
          (cid, peers) => MapEntry(cid, {...peers}),
        ),
      ),
    );
  }

  Future<void> _enableSframeOnScreenSharePc(
      RTCPeerConnection pc, FrameCryptorService frameCryptor,
      String peerId, {required bool isSender}) async {
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
      // Set key index on newly created cryptors to match the current epoch.
      await frameCryptor.setKeyIndexForPeer('screen:$peerId', frameCryptor.currentKeyIndex);
      debugPrint('[HOLLOW-VC] SFrame enabled on screen share (sender=$isSender, peer=$peerId, keyIndex=${frameCryptor.currentKeyIndex})');
    } catch (e) {
      debugPrint('[HOLLOW-VC] Failed to enable SFrame on screen share: $e');
    }
  }
}

final voiceChannelProvider =
    NotifierProvider<VoiceChannelNotifier, VoiceChannelState>(
        VoiceChannelNotifier.new);
