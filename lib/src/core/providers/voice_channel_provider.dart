import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
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

  const VoiceChannelState({
    this.participants = const {},
    this.currentServerId,
    this.currentChannelId,
    this.isMuted = false,
    this.isDeafened = false,
    this.peerAudioStates = const {},
    this.speakingPeers = const {},
    this.peerVolumes = const {},
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

  VoiceChannelState copyWith({
    Map<String, Map<String, Set<String>>>? participants,
    String? currentServerId,
    String? currentChannelId,
    bool? isMuted,
    bool? isDeafened,
    Map<String, PeerAudioState>? peerAudioStates,
    Set<String>? speakingPeers,
    Map<String, double>? peerVolumes,
    bool clearCurrent = false,
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
    );
  }
}

class VoiceChannelNotifier extends Notifier<VoiceChannelState> {
  VoiceChannelService? _service;

  @override
  VoiceChannelState build() => const VoiceChannelState();

  VoiceChannelService? get service => _service;

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

    // Load audio quality preset.
    final preset = await ref.read(audioQualityProvider.future);
    _service!.opusBitrate = preset.bitrate;
    _service!.opusStereo = preset.stereo;

    // Wire VAD callback.
    _service!.onSpeakingChanged = (speaking) {
      state = state.copyWith(speakingPeers: speaking);
    };

    await _service!.startAudio(serverId, channelId);

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
  }

  /// Called when a remote peer leaves our current voice channel.
  Future<void> onRemotePeerLeft(String peerId) async {
    if (_service == null) return;
    await _service!.onPeerLeftMyChannel(peerId);
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
    if (_service == null) return;
    await _service!.handleSignal(
        peerId, signalType, payload, serverId, channelId);
  }

  /// Leave the current voice channel.
  Future<void> leaveChannel() async {
    if (!state.isInVoiceChannel) return;

    // Clean up WebRTC.
    if (_service != null) {
      await _service!.closeAll();
      _service = null;
    }

    await network_api.voiceChannelLeave(
      serverId: state.currentServerId!,
      channelId: state.currentChannelId!,
    );
  }

  /// Called after the local leave event arrives to update state.
  void onLocalLeft() {
    state = state.copyWith(clearCurrent: true);
  }

  void toggleMute() {
    final newMuted = !state.isMuted;
    state = state.copyWith(isMuted: newMuted);
    _service?.setMuted(newMuted);
    _broadcastAudioState();
  }

  void toggleDeafen() {
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
  void onPeerDisconnected(String peerId) {
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
}

final voiceChannelProvider =
    NotifierProvider<VoiceChannelNotifier, VoiceChannelState>(
        VoiceChannelNotifier.new);
