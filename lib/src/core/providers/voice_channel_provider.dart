import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
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

  /// Whether the local user's mic is muted.
  final bool isMuted;

  /// Whether the local user is deafened (muted + no audio output).
  final bool isDeafened;

  /// Remote peer audio states (peer_id -> PeerAudioState).
  final Map<String, PeerAudioState> peerAudioStates;

  /// Set of peer IDs currently speaking (VAD).
  final Set<String> speakingPeers;

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

  /// Remote peers with camera on (peer_id -> true).
  final Map<String, bool> peerCameraOn;

  const VoiceChannelState({
    this.participants = const {},
    this.currentServerId,
    this.currentChannelId,
    this.isMuted = false,
    this.isDeafened = false,
    this.peerAudioStates = const {},
    this.speakingPeers = const {},
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
    this.peerCameraOn = const {},
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

  /// Whether a peer is currently speaking (VAD).
  bool isSpeaking(String peerId) => speakingPeers.contains(peerId);

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
    bool? isMuted,
    bool? isDeafened,
    Map<String, PeerAudioState>? peerAudioStates,
    Set<String>? speakingPeers,
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
    Map<String, bool>? peerCameraOn,
  }) {
    return VoiceChannelState(
      participants: participants ?? this.participants,
      currentServerId:
          clearCurrent ? null : (currentServerId ?? this.currentServerId),
      currentChannelId:
          clearCurrent ? null : (currentChannelId ?? this.currentChannelId),
      isMuted: clearCurrent ? false : (isMuted ?? this.isMuted),
      isDeafened: clearCurrent ? false : (isDeafened ?? this.isDeafened),
      peerAudioStates: clearCurrent
          ? const {}
          : (peerAudioStates ?? this.peerAudioStates),
      speakingPeers: clearCurrent
          ? const {}
          : (speakingPeers ?? this.speakingPeers),
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
      peerCameraOn: clearCurrent
          ? const {}
          : (peerCameraOn ?? this.peerCameraOn),
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

  /// Cached SFrame key from last MLS epoch change — applied when service is (re)created.
  int? _lastSframeEpoch;
  Uint8List? _lastSframeKey;
  String? _lastSframeServerId;

  /// Shared screen capture stream (captured once, shared across outgoing PCs).
  MediaStream? _screenCaptureStream;
  RTCVideoRenderer? _localScreenPreviewRenderer;
  int _screenShareMaxWidth = 1920;
  int _screenShareMaxHeight = 1080;

  /// Timer that polls for screen track ending (window closed).
  Timer? _screenTrackPoller;

  /// Guard to prevent concurrent leaveChannel calls and actions during leave.
  bool _leaving = false;

  /// Channel that was selected before joining the VC (restored on leave).
  String? preVcChannelId;

  // ---------------------------------------------------------------
  //  Camera (video) state
  // ---------------------------------------------------------------

  /// Local camera renderer (for self-view in grid).
  RTCVideoRenderer? _localCameraRenderer;

  /// Remote camera renderers (peer_id -> RTCVideoRenderer), managed by service.
  final Map<String, RTCVideoRenderer> _remoteCameraRenderers = {};

  @override
  VoiceChannelState build() => const VoiceChannelState();

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

  /// Join a voice channel. If already in one, leave it first.
  Future<void> joinChannel(String serverId, String channelId) async {
    // Block if in a 1:1 call.
    final callState = ref.read(callProvider);
    if (callState.status != CallStatus.idle) {
      debugPrint('[HOLLOW-VC] Cannot join voice channel — in a call');
      return;
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
    state = state.copyWith(
      currentServerId: serverId,
      currentChannelId: channelId,
      isMuted: false,
      isDeafened: false,
      peerAudioStates: {},
      joinedAt: DateTime.now(),
    );

    // Initialize the WebRTC service.
    final localPeerId = ref.read(identityProvider).peerId ?? '';
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

    // Wire VAD callback.
    _service!.onSpeakingChanged = (speaking) {
      state = state.copyWith(speakingPeers: speaking);
    };

    // Wire peer connected callback — send screen share offer once audio PC is ready.
    _service!.onPeerConnected = (peerId) {
      if (_leaving || _stoppingScreenShare) return;
      if (state.isScreenSharing && _screenCaptureStream != null) {
        if (!_outgoingScreenShares.containsKey(peerId) &&
            _outgoingScreenShares.length < maxScreenShareOutgoing) {
          debugPrint('[HOLLOW-VC] Peer $peerId connected — sending screen share offer');
          _sendScreenShareToPeer(peerId);
        }
      }
    };

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

    // Apply cached SFrame key (may have arrived before the service was created).
    if (_lastSframeKey != null && _lastSframeEpoch != null && _lastSframeServerId == serverId) {
      debugPrint('[HOLLOW-VC] Applying cached SFrame key (epoch=$_lastSframeEpoch) to new service');
      await _service!.setSframeKey(_lastSframeEpoch!, Uint8List.fromList(_lastSframeKey!));
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

      // Clean up screen sharing.
      await _cleanupAllScreenShares();

      // Clean up WebRTC (closes all PCs + stops camera/audio streams).
      if (_service != null) {
        await _service!.closeAll();
        _service = null;
      }
    } catch (e) {
      debugPrint('[HOLLOW-VC] leaveChannel cleanup error: $e');
      _service = null;
    }

    _leaving = false;
  }

  /// Called after the local leave event arrives to update state.
  void onLocalLeft() {
    _leaving = false;
    state = state.copyWith(clearCurrent: true);
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
    _broadcastAudioState();
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

    // Tear down WebRTC connection if they were in our channel.
    _service?.closePeer(peerId);
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

      state = state.copyWith(isCameraOn: true);
      _broadcastCameraState(true);
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

    // Capture screen ONCE.
    await desktopCapturer.getSources(
        types: [SourceType.Screen, SourceType.Window]);
    _screenCaptureStream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': sourceId},
        'mandatory': {'frameRate': fps.toDouble()},
      },
      'audio': shareAudio,
    });

    // Create local preview renderer so the sharer can see their own screen.
    _localScreenPreviewRenderer = RTCVideoRenderer();
    await _localScreenPreviewRenderer!.initialize();
    _localScreenPreviewRenderer!.srcObject = _screenCaptureStream;

    // Build quality label (e.g. "1080p60", "4K30").
    const resLabels = {360: '360p', 480: '480p', 720: '720p', 1080: '1080p', 1440: '1440p', 2160: '4K'};
    final qualityLabel = '${resLabels[height] ?? '${height}p'}$fps';

    final localPeerId = ref.read(identityProvider).peerId ?? '';
    state = state.copyWith(
      isScreenSharing: true,
      screenShareLabel: qualityLabel,
      focusedScreenSharePeerId: localPeerId,
    );

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

    // Broadcast screen_state(enabled: true) to all peers.
    _broadcastScreenState(true);

    // Start track poller (detect window close).
    _startScreenTrackPoller();
  }

  bool _stoppingScreenShare = false;

  /// Stop sharing our screen.
  Future<void> stopScreenShare() async {
    if (!state.isScreenSharing || _stoppingScreenShare) return;
    _stoppingScreenShare = true;
    debugPrint('[HOLLOW-VC] Stopping screen share');

    try {
      _screenTrackPoller?.cancel();
      _screenTrackPoller = null;

      // Close all outgoing screen share PCs.
      for (final service in _outgoingScreenShares.values) {
        try { await service.close(); } catch (_) {}
      }
      _outgoingScreenShares.clear();

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

    _outgoingScreenShares[peerId] = service;

    final sdp = await service.createOfferFromStream(
      _screenCaptureStream!,
      maxWidth: _screenShareMaxWidth,
      maxHeight: _screenShareMaxHeight,
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
  Future<void> onEpochChanged(
      String serverId, int epoch, Uint8List sframeKey) async {
    // Always cache — the event may arrive before onLocalJoined sets currentServerId.
    _lastSframeEpoch = epoch;
    _lastSframeKey = Uint8List.fromList(sframeKey);
    _lastSframeServerId = serverId;

    if (state.currentServerId != serverId) return;
    if (!state.isInVoiceChannel || _service == null) return;

    debugPrint('[HOLLOW-VC] MLS epoch changed: $epoch — rotating SFrame key');
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
