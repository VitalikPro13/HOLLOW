import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/viewer_display.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/services/desktop_capture_support.dart';
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
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Log to hollow_debug.log (visible in release builds); console-only when
/// the FFI isn't up (tests).
void _vcLog(String msg) {
  debugPrint(msg);
  try {
    network_api.logFromDart(message: msg).catchError((_) {});
  } catch (_) {}
}

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

  /// Remote sharers we explicitly opted into watching (issue #38).
  /// A remote share never streams to us until its peer id is in this set —
  /// `peerScreenSharing` alone is just the badge.
  final Set<String> watchingScreenShares;

  /// Shares we asked to receive at SOURCE quality (media forwarding step 1).
  /// OFF by default: the sharer clamps our stream to our display resolution
  /// unless the sharer's peer id is in this set. Cleared when we stop
  /// watching that share — the opt-in is per watch session, never sticky.
  final Set<String> sourceQualityShares;

  /// Desktop-only: show all sources as a tile grid instead of one focused
  /// source full-bleed.
  final bool isGridView;

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
    this.watchingScreenShares = const {},
    this.sourceQualityShares = const {},
    this.isGridView = false,
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

  /// Whether we are actually receiving at least one remote share.
  bool get isWatchingAnyShare => watchingScreenShares.isNotEmpty;

  /// Whether the share surface (focus/grid view) should be shown: we're
  /// sharing ourselves or watching someone. A remote share we have NOT
  /// opted into never flips this — it only shows the badge + Watch banner.
  bool get showsShareSurface => isScreenSharing || isWatchingAnyShare;

  /// Remote sharers we have not opted into watching yet.
  List<String> get unwatchedRemoteShares => [
        for (final e in peerScreenSharing.entries)
          if (e.value && !watchingScreenShares.contains(e.key)) e.key,
      ];

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
    Set<String>? watchingScreenShares,
    Set<String>? sourceQualityShares,
    bool? isGridView,
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
      watchingScreenShares: clearCurrent
          ? const {}
          : (watchingScreenShares ?? this.watchingScreenShares),
      sourceQualityShares: clearCurrent
          ? const {}
          : (sourceQualityShares ?? this.sourceQualityShares),
      isGridView: clearCurrent
          ? false
          : (isGridView ?? this.isGridView),
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

  /// Peers that requested to watch OUR share via screen_watch (issue #38).
  /// We only ever send a screen offer to peers in this set.
  final Set<String> _watchers = {};

  /// Per-watcher display resolution + source-quality request, from the
  /// screen_watch payload (media forwarding step 1). Used to clamp THAT
  /// viewer's encoder — per-viewer PCs mean per-viewer encoders, so one 4K
  /// viewer never drags a 1080p room up. Absent / 0x0 = unknown (old
  /// client) = no clamp.
  final Map<String, ({int w, int h, bool source})> _watcherDisplays = {};

  /// Peers whose audio PC to us has reached connected — the precondition for
  /// sending them a screen offer (Olm/MLS transport is warm by then).
  final Set<String> _audioConnectedPeers = {};

  /// Viewer-side "offer never came" timeouts, keyed by sharer peer id.
  final Map<String, Timer> _watchConnectTimers = {};

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

  // ── SFrame heal ladder (issue #27) ──────────────────────────────────────
  // Sustained MissingKey/DecryptionFailed on a cryptor means we and the peer
  // disagree on key material. Rather than playing garbage/silence forever:
  //   step 1: re-apply the cached key + rebind that peer's receiver cryptors
  //   step 2: ask Rust to re-export + re-emit the current MLS epoch key
  //   step 3: (cooldown-guarded) MLS re-bootstrap — converges real epoch forks

  /// Cryptor keys ('peer|kind|rx/tx') currently in a failure state → first seen.
  final Map<String, DateTime> _sframeFailures = {};

  /// Per-peer heal progress: last ladder step run and when.
  final Map<String, ({int step, DateTime at})> _sframeHealProgress = {};

  /// Global cooldown for step 3 (MLS group surgery is expensive).
  DateTime? _lastSframeEscalateAt;

  /// Step-3 attempts per peer this session. After [_kMaxSframeEscalations]
  /// the ladder gives up on that peer — an unhealable peer (e.g. a client
  /// that never encrypts) must not put the server MLS group through
  /// remove+re-add surgery every cooldown window forever.
  final Map<String, int> _sframeEscalations = {};
  static const int _kMaxSframeEscalations = 2;

  Timer? _sframeHealTimer;

  /// Keyless watchdog (issue #47 → #27): with NO SFrame key no cryptors ever
  /// exist, so no cryptor-state callbacks fire and the heal ladder never
  /// arms — an identity that lost its MLS groups (e.g. after a
  /// profile-switch mnemonic recovery) sat keyless, transmitting plaintext
  /// against peers' ciphertext, audibly garbled forever. Ticks after join
  /// until the first key lands, nudging Rust to re-emit / re-bootstrap.
  Timer? _sframeKeylessTimer;
  int _sframeKeylessTicks = 0;

  /// Whether a channel is cryptographically isolated in its own MLS subgroup
  /// (per-channel subgroups / "Option B"): restricted visibility AND not a public
  /// channel. Mirrors Rust `ServerState::channel_uses_subgroup`. Such a channel's
  /// voice SFrame key comes ONLY from its subgroup, never the server-wide group.
  bool _channelUsesSubgroup(String channelId) {
    final ch = ref.read(channelListProvider)[channelId];
    if (ch == null) return false;
    // Label-gated channels are subgrouped too. The Rust handler stamps the
    // tier to admin whenever a label gate turns on, but this is a KEY-DOMAIN
    // decision — never rely on the stamp; mirror Rust's channel_uses_subgroup
    // exactly.
    return !ch.isPublic &&
        (ch.visibility != 'everyone' || ch.visibilityLabels.isNotEmpty);
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

  /// Bumped by every join and every teardown. `onLocalJoined` is a long, fully
  /// async bring-up (device prefs → audio start → SFrame key → dial existing
  /// participants) and the user can leave or hop channels straight through it.
  /// A run that resumes on a stale generation abandons its half-built service
  /// instead of configuring one nobody owns any more — 0.8.5 crashed there
  /// instead ("Null check operator used on a null value": the teardown had
  /// nulled `_service` and the next `_service!` after an await threw).
  int _joinGen = 0;

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
    // Block if in a 1:1 call. Say so — a silent return reads as a dead
    // button (issue #49).
    final callState = ref.read(callProvider);
    if (callState.status != CallStatus.idle) {
      debugPrint('[HOLLOW-VC] Cannot join voice channel — in a call');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          final overlay = hollowNavigatorKey.currentState?.overlay;
          if (overlay == null) return;
          HollowToast.show(
            overlay.context,
            "You're in a call. Hang up to join a voice channel.",
            type: HollowToastType.info,
            overlayState: overlay,
          );
        } catch (e) {
          debugPrint('[HOLLOW-VC] in-call toast failed: $e');
        }
      });
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

  /// True once this join has been superseded — the user left, was forced out,
  /// or joined somewhere else while this bring-up was still walking its awaits.
  ///
  /// Closing [svc] here is only OUR job when another join replaced the field
  /// without a teardown; a leave always closes whatever `_service` held (and
  /// may still be inside that await), so `_service == null` means it is already
  /// handled — closing again from here would be the double-dispose that
  /// corrupts the heap on Linux.
  Future<bool> _joinSuperseded(int gen, VoiceChannelService svc) async {
    if (gen == _joinGen && identical(_service, svc)) return false;
    debugPrint('[HOLLOW-VC] Join superseded mid-bring-up — dropping service');
    final replacement = _service;
    if (replacement != null && !identical(replacement, svc)) {
      try {
        await svc.closeAll();
      } catch (_) {}
    }
    return true;
  }

  /// Called after the local join event arrives to update state and start audio.
  Future<void> onLocalJoined(String serverId, String channelId) async {
    final gen = ++_joinGen;

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

    // Configure through the LOCAL handle, never `_service!`: a leave landing
    // between two of these awaits nulls the field, and the next `!` would throw.
    final svc = VoiceChannelService(
      localPeerId: localPeerId,
      iceServers: iceConfig,
    );
    _service = svc;

    // Load device preferences.
    svc.preferredAudioInputDeviceId =
        await ref.read(audioInputDeviceProvider.future);
    svc.preferredAudioOutputDeviceId =
        await ref.read(audioOutputDeviceProvider.future);
    svc.preferredCameraDeviceId =
        await ref.read(cameraDeviceProvider.future);

    // Load audio quality preset.
    final preset = await ref.read(audioQualityProvider.future);
    svc.opusBitrate = preset.bitrate;
    svc.opusStereo = preset.stereo;

    // Load mic gain + voice enhancement.
    svc.micGain = await ref.read(micGainProvider.future);
    svc.voiceEnhance = await ref.read(voiceEnhanceProvider.future);
    svc.enhanceMakeupDb = enhanceStrengthToMakeupDb(
        await ref.read(voiceEnhanceStrengthProvider.future));
    svc.enhanceDynamic =
        await ref.read(voiceEnhanceDynamicProvider.future);
    svc.noiseSuppressAi =
        await ref.read(noiseSuppressAiProvider.future);
    svc.noiseSuppressEngine = noiseSuppressEngineToNative(
        await ref.read(noiseSuppressEngineProvider.future));

    // Every preference above came from an await — bail before we open the mic
    // if the channel we were joining is already behind us.
    if (await _joinSuperseded(gen, svc)) return;

    _armSframeKeylessWatchdog();

    // Wire VAD callback. Writes go to the dedicated vcSpeakingProvider (NOT
    // VoiceChannelState) so a speaking flip only rebuilds the glow consumers,
    // never every voiceChannelProvider watcher.
    svc.onSpeakingChanged = (speaking, localSpeaking) {
      ref.read(vcSpeakingProvider.notifier).set(speaking);
      ref.read(vcLocalSpeakingProvider.notifier).set(localSpeaking);
      // Sidechain for share-audio ducking: anyone talking (self included)
      // pulls received share audio down.
      ShareAudioLevel.setSpeaking(speaking.isNotEmpty || localSpeaking);
    };

    // Wire peer connected callback — send screen share offer once audio PC is ready.
    svc.onPeerConnected = (peerId) {
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

      _audioConnectedPeers.add(peerId);

      // Opt-in watching (issue #38): only send our share to peers that asked
      // via screen_watch — never unconditionally.
      if (state.isScreenSharing &&
          _screenCaptureStream != null &&
          _watchers.contains(peerId)) {
        if (!_outgoingScreenShares.containsKey(peerId) &&
            _outgoingScreenShares.length < maxScreenShareOutgoing) {
          debugPrint('[HOLLOW-VC] Watcher $peerId connected — sending screen share offer');
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
    svc.onRemoteVideoChanged = (peerId, renderer) {
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

    // Wire the SFrame heal ladder — cryptor failure states drive recovery
    // instead of playing garbage/silence until the call is restarted.
    svc.onSframeCryptorState = _onSframeCryptorState;

    await svc.startAudio(serverId, channelId);

    // The mic is live now — if the channel went away while it was opening,
    // give it straight back.
    if (await _joinSuperseded(gen, svc)) return;

    // Apply the transmit gate now that capture exists: in push-to-talk mode
    // the mic starts gated (capture-muted) while state.isMuted stays false —
    // peers see us unmuted; the key gates actual transmission.
    _applyTxGate();

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
      await svc.setSframeKey(cached.epoch, Uint8List.fromList(cached.key));
    } else if (usesSubgroup) {
      // Subgroup key not delivered yet — the Welcome/Commit → MlsEpochChanged
      // (channelId) will rotate it in. Until then this channel has no SFrame key.
      debugPrint('[HOLLOW-VC] Restricted channel $channelId — awaiting subgroup SFrame key');
    }

    // Connect to existing participants in this channel. Each dial is a full
    // PC bring-up, so re-check between them rather than build a mesh into a
    // channel we've already left.
    final existing = state.getParticipants(serverId, channelId);
    for (final peerId in existing) {
      if (peerId == localPeerId) continue;
      if (await _joinSuperseded(gen, svc)) return;
      await svc.onPeerJoinedMyChannel(peerId);
    }
  }

  /// Called when a remote peer joins our current voice channel.
  Future<void> onRemotePeerJoined(String peerId) async {
    if (_service == null || !state.isInVoiceChannel) return;
    await _service!.onPeerJoinedMyChannel(peerId);

    // If we're sharing our screen, send state to the late joiner so they
    // know we're sharing (badge + Watch banner). The actual screen_offer is
    // only sent if they opt in via screen_watch AND their audio PC reaches
    // connected state (via onPeerConnected callback), ensuring MLS is ready
    // and the peer can decrypt it.
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
    _watchers.remove(peerId);
    _watcherDisplays.remove(peerId);
    _audioConnectedPeers.remove(peerId);
    // A gone peer can't heal — drop its ladder state.
    _sframeFailures.removeWhere((k, _) => k.startsWith('$peerId|'));
    _sframeHealProgress.remove(peerId);
    _sframeEscalations.remove(peerId);
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
    if (signalType == 'screen_watch') {
      await _handleScreenWatch(peerId, payload);
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
    // Retire the current join immediately: a bring-up still walking its awaits
    // must stop before the FFI round-trip below, not after it.
    _joinGen++;

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
    _resetSframeHeal();
    // Also covers the server-FORCED leave, which never goes through
    // leaveChannel(): whatever join is mid-flight no longer owns this call.
    _joinGen++;
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
      _audioConnectedPeers.clear();
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
    ref.read(vcLocalSpeakingProvider.notifier).reset();
  }

  // --- Push-to-talk transmit gate (issue #38) ---------------------------
  // PTT state deliberately lives OUTSIDE VoiceChannelState: key press and
  // release must not rebuild every voiceChannelProvider watcher, and no
  // audio_state signal fans out per press — peers see a PTT user as
  // unmuted and the speaking indicator (level-gated) conveys talk state.
  bool _pttMode = false;
  bool _pttTransmit = false;

  /// The mic transmits only when EVERY gate is open: not manually muted or
  /// deafened, and (in PTT mode) the key is held. Pure function of the four
  /// flags, so a manual mute always wins over a held PTT key.
  void _applyTxGate() {
    final gated =
        state.isMuted || state.isDeafened || (_pttMode && !_pttTransmit);
    if (_pttMode && state.isInVoiceChannel) {
      _vcLog('[HOLLOW-HOTKEY] VC tx gate: gated=$gated '
          '(muted=${state.isMuted} deafened=${state.isDeafened} '
          'held=$_pttTransmit service=${_service != null})');
    }
    _service?.setMuted(gated);
  }

  /// Hotkey layer: PTT key edge (true = held). Idempotent.
  void setPttTransmit(bool active) {
    if (_pttTransmit == active) return;
    _pttTransmit = active;
    if (state.isInVoiceChannel) {
      _vcLog('[HOLLOW-HOTKEY] VC PTT transmit=$active '
          '(mode=$_pttMode muted=${state.isMuted})');
    }
    _applyTxGate();
  }

  /// Hotkey layer: voice input mode changed (true = push-to-talk).
  void setVoiceInputMode(bool ptt) {
    if (_pttMode == ptt) return;
    _pttMode = ptt;
    _pttTransmit = false;
    _applyTxGate();
  }

  void toggleMute() {
    if (_leaving) return;
    final newMuted = !state.isMuted;
    state = state.copyWith(isMuted: newMuted);
    _applyTxGate();
    _broadcastAudioState();
  }

  void toggleDeafen() {
    if (_leaving) return;
    final newDeafened = !state.isDeafened;
    state = state.copyWith(
      isMuted: newDeafened ? true : state.isMuted,
      isDeafened: newDeafened,
    );
    // Mute our mic when deafened (via the gate — PTT-aware).
    _applyTxGate();
    // Silence all remote audio when deafened. Fire-and-forget, so it carries
    // its own catch: a sync try/catch around an un-awaited future catches
    // nothing and the rejection lands in the zone handler.
    unawaited(_service?.setDeafened(newDeafened).catchError((_) {}) ??
        Future.value());
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
    _audioConnectedPeers.remove(peerId);
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
      // A Wayland portal-first share MUST NOT re-enumerate: the native side
      // resolves the sentinel id without a source list, and enumerating here
      // would pop an extra xdg-desktop-portal dialog.
      if (!DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        await desktopCapturer.getSources(
            types: DesktopCaptureSupport.sourceTypes);
      }
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
      // The portal grant now exists (or was just re-used) — the next share
      // this run can offer "same as last time" without a portal prompt.
      if (DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        DesktopCaptureSupport.portalGrantLikely = true;
      }
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

    // Opt-in watching (issue #38): no fan-out here. Peers learn about the
    // share via the screen_state broadcast below and request it with a
    // screen_watch signal — _handleScreenWatch sends the per-peer offer.

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
      _watchers.clear();
      _watcherDisplays.clear();
      final sharePeers = _outgoingScreenShares.keys.toList();
      for (final service in _outgoingScreenShares.values) {
        try { await service.close(); } catch (_) {}
      }
      _outgoingScreenShares.clear();
      for (final peerId in sharePeers) {
        await _dropShareCryptors(peerId);
      }

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
        // Only a share we're actually watching can take focus.
        final remoteSharerId = state.peerScreenSharing.entries
            .where((e) =>
                e.value && state.watchingScreenShares.contains(e.key))
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

  /// Toggle the desktop tile-grid view of all sources (issue #38).
  void setGridView(bool on) {
    if (state.isGridView == on) return;
    state = state.copyWith(isGridView: on);
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
    final priorOutgoing = _outgoingScreenShares.remove(peerId);
    if (priorOutgoing != null) {
      await priorOutgoing.close();
      await _dropShareCryptors(peerId);
    }
    _outgoingScreenShares[peerId] = service;

    try {
      // Per-viewer cap: the share quality clamped to what THIS viewer's
      // display can show (media forwarding step 1).
      final (effMaxW, effMaxH) = _effectiveCapFor(peerId);
      final sdp = await service.createOfferFromStream(
        _screenCaptureStream!,
        maxWidth: effMaxW,
        maxHeight: effMaxH,
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
      await _dropShareCryptors(peerId);
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

    // Opt-in watching (issue #38): an offer we never asked for is dropped.
    // Offers only flow after our screen_watch{want:true} reached the sharer.
    if (!state.watchingScreenShares.contains(peerId)) {
      debugPrint('[HOLLOW-VC] Ignoring unsolicited screen offer from $peerId (not watching)');
      return;
    }

    if (!_incomingScreenShares.containsKey(peerId) &&
        _incomingScreenShares.length >= maxScreenShareIncoming) {
      debugPrint('[HOLLOW-VC] Rejecting screen offer from $peerId — incoming cap ($maxScreenShareIncoming) reached');
      return;
    }

    // Mark this peer as sharing (screen_offer may arrive before screen_state).
    // No auto-focus: watchScreenShare already focused this share when the
    // user opted in — the offer landing must not steal focus.
    final sharing = Map.of(state.peerScreenSharing);
    sharing[peerId] = true;
    state = state.copyWith(peerScreenSharing: sharing);

    final iceConfig = ref.read(iceConfigProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    // Close existing incoming service for this peer if any (and drop its
    // cryptors so the new PC's receivers re-enable cleanly).
    final priorIncoming = _incomingScreenShares.remove(peerId);
    if (priorIncoming != null) {
      await priorIncoming.close();
      await _dropShareCryptors(peerId);
    }

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
      // The share we asked for is live — stop the "offer never came" timer.
      _watchConnectTimers.remove(peerId)?.cancel();
      // Force a state rebuild so the UI picks up the renderer.
      // Also auto-focus if no one is focused yet (only fires for watched shares).
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
      // Badge only — opt-in watching (issue #38) means a new share must
      // never steal focus or flip the view; the user presses Watch.
      sharing[peerId] = true;
      if (quality != null) labels[peerId] = quality;
    } else {
      sharing.remove(peerId);
      labels.remove(peerId);
      // The share is gone — forget any watch state for it.
      _watchConnectTimers.remove(peerId)?.cancel();
      final watching = state.watchingScreenShares.contains(peerId)
          ? ({...state.watchingScreenShares}..remove(peerId))
          : state.watchingScreenShares;
      // Clean up incoming service.
      _cleanupPeerScreenShare(peerId);
      // If the leaving sharer was focused, switch to another WATCHED share.
      if (state.focusedScreenSharePeerId == peerId) {
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        final nextFocus = state.isScreenSharing
            ? localPeerId
            : sharing.entries
                .where((e) => e.value && watching.contains(e.key))
                .map((e) => e.key)
                .firstOrNull;
        state = state.copyWith(
          peerScreenSharing: sharing,
          peerScreenShareLabels: labels,
          watchingScreenShares: watching,
          focusedScreenSharePeerId: nextFocus,
          clearFocusedSharer: nextFocus == null,
        );
        return;
      }
      state = state.copyWith(
        peerScreenSharing: sharing,
        peerScreenShareLabels: labels,
        watchingScreenShares: watching,
      );
      return;
    }
    state = state.copyWith(
      peerScreenSharing: sharing,
      peerScreenShareLabels: labels,
    );
  }

  /// Sharer side of opt-in watching (issue #38): a peer asked to start or
  /// stop receiving our share.
  Future<void> _handleScreenWatch(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final want = v['want'] as bool? ?? false;
    final viewerW = (v['viewer_width'] as num?)?.toInt() ?? 0;
    final viewerH = (v['viewer_height'] as num?)?.toInt() ?? 0;
    final sourceQuality = v['source_quality'] as bool? ?? false;
    debugPrint('[HOLLOW-VC] Screen watch from $peerId: want=$want '
        'viewer=${viewerW}x$viewerH source=$sourceQuality');

    if (want) {
      // Raced against our stop — nothing to send; the peer's badge clears
      // via our screen_state{disabled} broadcast.
      if (!state.isScreenSharing || _screenCaptureStream == null) return;
      _watchers.add(peerId);
      _watcherDisplays[peerId] =
          (w: viewerW, h: viewerH, source: sourceQuality);
      final existing = _outgoingScreenShares[peerId];
      if (existing != null) {
        // Already streaming to this viewer — a re-sent watch is a cap change
        // (Source-quality toggle): try a live setParameters first; when the
        // sender rejects it (Windows libwebrtc always does — field-verified
        // 2026-08-05), renegotiate: fresh offer with the new cap riding the
        // init sendEncodings, the guaranteed path. Brief stream restart.
        final (effW, effH) = _effectiveCapFor(peerId);
        final ok = await existing.updateResolutionCap(effW, effH);
        if (!ok) {
          debugPrint('[HOLLOW-VC] Live cap change rejected for $peerId — '
              're-offering share at ${effW}x$effH');
          await _sendScreenShareToPeer(peerId);
        }
        return;
      }
      if (_outgoingScreenShares.length >= maxScreenShareOutgoing) {
        debugPrint('[HOLLOW-VC] Watch request from $peerId ignored — outgoing cap ($maxScreenShareOutgoing) reached');
        return;
      }
      // Only offer once the audio PC is connected (Olm/MLS transport warm);
      // otherwise onPeerConnected sends it when the PC lands.
      if (_audioConnectedPeers.contains(peerId)) {
        await _sendScreenShareToPeer(peerId);
      }
    } else {
      _watchers.remove(peerId);
      _watcherDisplays.remove(peerId);
      final outgoing = _outgoingScreenShares.remove(peerId);
      if (outgoing != null) {
        await outgoing.close();
        await _dropShareCryptors(peerId);
        debugPrint('[HOLLOW-VC] Stopped sending share to $peerId (viewer opted out)');
      }
    }
  }

  /// The resolution cap for [peerId]'s outgoing share PC: the share's chosen
  /// quality clamped to that viewer's reported display (media forwarding
  /// step 1) — unless they explicitly asked for source quality.
  (int, int) _effectiveCapFor(String peerId) {
    final d = _watcherDisplays[peerId];
    return ScreenShareService.effectiveViewerCap(
      _screenShareMaxWidth,
      _screenShareMaxHeight,
      d?.w ?? 0,
      d?.h ?? 0,
      sourceQuality: d?.source ?? false,
    );
  }

  /// Viewer side of opt-in watching (issue #38): request [peerId]'s share.
  /// Optimistically marks us as watching + focuses the share; the sharer
  /// replies with a screen_offer which _handleScreenOffer now accepts.
  Future<void> watchScreenShare(String peerId) async {
    if (!state.isInVoiceChannel) return;
    if (state.peerScreenSharing[peerId] != true) return;
    if (state.watchingScreenShares.contains(peerId)) return;
    if (_incomingScreenShares.length >= maxScreenShareIncoming) {
      _toast('Watch limit reached ($maxScreenShareIncoming shares)',
          HollowToastType.error);
      return;
    }

    state = state.copyWith(
      watchingScreenShares: {...state.watchingScreenShares, peerId},
      focusedScreenSharePeerId: peerId,
      focusedSourceType: 'screen',
    );

    // Ship our display resolution so the sharer clamps our stream to what
    // we can actually show (media forwarding step 1).
    final (viewerW, viewerH) = largestDisplayResolution();
    network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: peerId,
          signalType: 'screen_watch',
          payload: jsonEncode({
            'want': true,
            'viewer_width': viewerW,
            'viewer_height': viewerH,
            'source_quality': state.sourceQualityShares.contains(peerId),
          }),
        )
        .catchError((_) {});

    // If no offer produces a live track in time, revert so the tile/banner
    // doesn't spin forever (sharer at cap, signal lost, ...).
    _watchConnectTimers.remove(peerId)?.cancel();
    _watchConnectTimers[peerId] = Timer(const Duration(seconds: 20), () {
      _watchConnectTimers.remove(peerId);
      if (!state.watchingScreenShares.contains(peerId)) return;
      if (getScreenShareRenderer(peerId) != null) return;
      debugPrint('[HOLLOW-VC] Watch of $peerId timed out — reverting');
      stopWatchingScreenShare(peerId);
      _toast("Couldn't connect to the screen share", HollowToastType.error);
    });
  }

  /// Viewer side of opt-in watching (issue #38): stop receiving [peerId]'s
  /// share (the badge stays — the peer is still sharing to others).
  Future<void> stopWatchingScreenShare(String peerId) async {
    if (!state.watchingScreenShares.contains(peerId)) return;
    _watchConnectTimers.remove(peerId)?.cancel();
    _earlyScreenIce.remove('incoming:$peerId');

    final watching = {...state.watchingScreenShares}..remove(peerId);
    // Source quality is a per-watch-session opt-in — never sticky.
    final sourceQuality = {...state.sourceQualityShares}..remove(peerId);

    // Focus repair BEFORE closing the service so the UI never renders a
    // focused share whose renderer is being torn down.
    if (state.focusedScreenSharePeerId == peerId &&
        state.focusedSourceType == 'screen') {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final nextWatched = state.peerScreenSharing.entries
          .where((e) => e.value && watching.contains(e.key))
          .map((e) => e.key)
          .firstOrNull;
      final nextFocus =
          nextWatched ?? (state.isScreenSharing ? localPeerId : null);
      String? cameraFocus;
      if (nextFocus == null) {
        cameraFocus = state.isCameraOn
            ? localPeerId
            : state.peerCameraOn.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .firstOrNull;
      }
      state = state.copyWith(
        watchingScreenShares: watching,
        sourceQualityShares: sourceQuality,
        focusedScreenSharePeerId: nextFocus ?? cameraFocus,
        clearFocusedSharer: nextFocus == null && cameraFocus == null,
        focusedSourceType: nextFocus != null
            ? 'screen'
            : (cameraFocus != null ? 'camera' : state.focusedSourceType),
      );
    } else {
      state = state.copyWith(
        watchingScreenShares: watching,
        sourceQualityShares: sourceQuality,
      );
    }

    final incoming = _incomingScreenShares.remove(peerId);
    if (incoming != null) {
      await incoming.close();
      await _dropShareCryptors(peerId);
    }

    if (state.isInVoiceChannel) {
      network_api
          .voiceChannelSendSignal(
            serverId: state.currentServerId!,
            channelId: state.currentChannelId!,
            peerId: peerId,
            signalType: 'screen_watch',
            payload: jsonEncode({'want': false}),
          )
          .catchError((_) {});
    }
  }

  /// Viewer side (media forwarding step 1): ask [peerId] to send us their
  /// share at SOURCE quality instead of clamped to our display — or go back
  /// to the clamp. OFF by default, per watch session. A re-sent screen_watch
  /// live-updates the sharer's encoder cap; no renegotiation, no PC churn.
  Future<void> setShareSourceQuality(String peerId, bool on) async {
    if (state.sourceQualityShares.contains(peerId) == on) return;
    final next = {...state.sourceQualityShares};
    if (on) {
      next.add(peerId);
    } else {
      next.remove(peerId);
    }
    state = state.copyWith(sourceQualityShares: next);

    if (!state.isInVoiceChannel) return;
    if (!state.watchingScreenShares.contains(peerId)) return;
    final (viewerW, viewerH) = largestDisplayResolution();
    network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: peerId,
          signalType: 'screen_watch',
          payload: jsonEncode({
            'want': true,
            'viewer_width': viewerW,
            'viewer_height': viewerH,
            'source_quality': on,
          }),
        )
        .catchError((_) {});
  }

  void _toast(String message, HollowToastType type) {
    final overlay = hollowNavigatorKey.currentState?.overlay;
    final overlayContext = overlay?.context;
    if (overlay == null || overlayContext == null || !overlayContext.mounted) {
      return;
    }
    HollowToast.show(overlayContext, message, type: type, overlayState: overlay);
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

  /// Drop the SFrame cryptors bound to a (now closing) screen share PC for
  /// [peerId]. enableFor* is idempotent per (participant, kind) — without this
  /// a RESTARTED share silently keeps cryptors bound to the dead PC's
  /// senders/receivers and the new PC's tracks go out/come in untransformed.
  Future<void> _dropShareCryptors(String peerId) async {
    try {
      await _service?.frameCryptor?.disableForPeer('screen:$peerId');
    } catch (e) {
      debugPrint('[HOLLOW-VC] dropShareCryptors($peerId) failed: $e');
    }
  }

  /// Clean up screen share services for a specific peer.
  Future<void> _cleanupPeerScreenShare(String peerId) async {
    // Forget watch bookkeeping both ways (viewer + sharer side).
    _watchConnectTimers.remove(peerId)?.cancel();
    _watchers.remove(peerId);
    _watcherDisplays.remove(peerId);
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
    if (incoming != null || outgoing != null) {
      await _dropShareCryptors(peerId);
    }
    // Update peerScreenSharing map + watching set.
    final watching = state.watchingScreenShares.contains(peerId)
        ? ({...state.watchingScreenShares}..remove(peerId))
        : state.watchingScreenShares;
    if (state.peerScreenSharing.containsKey(peerId)) {
      final sharing = Map.of(state.peerScreenSharing)..remove(peerId);
      // If the removed peer was focused, switch to another WATCHED sharer.
      if (state.focusedScreenSharePeerId == peerId) {
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        final nextFocus = state.isScreenSharing
            ? localPeerId
            : sharing.entries
                .where((e) => e.value && watching.contains(e.key))
                .map((e) => e.key)
                .firstOrNull;
        state = state.copyWith(
          peerScreenSharing: sharing,
          watchingScreenShares: watching,
          focusedScreenSharePeerId: nextFocus,
          clearFocusedSharer: nextFocus == null,
        );
      } else {
        state = state.copyWith(
          peerScreenSharing: sharing,
          watchingScreenShares: watching,
        );
      }
    } else if (!identical(watching, state.watchingScreenShares)) {
      state = state.copyWith(watchingScreenShares: watching);
    }
  }

  /// Clean up all screen share services.
  Future<void> _cleanupAllScreenShares() async {
    _screenTrackPoller?.cancel();
    _screenTrackPoller = null;

    for (final t in _watchConnectTimers.values) {
      t.cancel();
    }
    _watchConnectTimers.clear();
    _watchers.clear();
    _watcherDisplays.clear();

    await _stopMobileShareAudio();
    final allSharePeers = <String>{
      ..._outgoingScreenShares.keys,
      ..._incomingScreenShares.keys,
    };
    for (final service in _outgoingScreenShares.values) {
      await service.close();
    }
    _outgoingScreenShares.clear();

    for (final service in _incomingScreenShares.values) {
      await service.close();
    }
    _incomingScreenShares.clear();
    for (final peerId in allSharePeers) {
      await _dropShareCryptors(peerId);
    }

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
      watchingScreenShares: const {},
      isGridView: false,
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
    // Mirror guard: a SERVER-GROUP epoch change (e.g. someone joining the
    // server) must never clobber a restricted channel's SUBGROUP key — that
    // would re-key this VC onto material every non-qualifying member holds
    // (and desync anyone who applies the events in a different order).
    if (channelId == null &&
        state.currentChannelId != null &&
        _channelUsesSubgroup(state.currentChannelId!)) {
      return;
    }

    debugPrint('[HOLLOW-VC] MLS epoch changed: $epoch '
        '(${channelId == null ? "server group" : "subgroup $channelId"}) '
        '— rotating SFrame key');
    await _service!.setSframeKey(epoch, sframeKey);

    // If a screen share started before the FIRST key arrived, its PC has no
    // cryptors yet — enable them now (idempotent for already-enabled PCs;
    // rotateKey above already re-indexed existing share cryptors).
    final fc = _service?.frameCryptor;
    if (fc != null && fc.isEnabled) {
      for (final e in _outgoingScreenShares.entries) {
        if (e.value.pc != null) {
          await _enableSframeOnScreenSharePc(e.value.pc!, fc, e.key,
              isSender: true);
        }
      }
      for (final e in _incomingScreenShares.entries) {
        if (e.value.pc != null) {
          await _enableSframeOnScreenSharePc(e.value.pc!, fc, e.key,
              isSender: false);
        }
      }
    }
  }

  /// Cryptor state transition from the service (participant already collapsed
  /// to the mesh peerId). Failure states arm the heal timer; recovery states
  /// clear the tracking.
  void _onSframeCryptorState(
      String peerId, String kind, bool isReceiver, FrameCryptorState st) {
    final key = '$peerId|$kind|${isReceiver ? 'rx' : 'tx'}';
    if (FrameCryptorService.isFailureState(st)) {
      _sframeFailures.putIfAbsent(key, () => DateTime.now());
      _sframeHealTimer ??= Timer.periodic(
          const Duration(seconds: 2), (_) => _sframeHealTick());
    } else {
      // Ok / KeyRatcheted / New — this cryptor recovered.
      final wasFailing = _sframeFailures.remove(key) != null;
      if (wasFailing &&
          !_sframeFailures.keys.any((k) => k.startsWith('$peerId|'))) {
        debugPrint('[HOLLOW-VC] SFrame healed for $peerId '
            '(step ${_sframeHealProgress[peerId]?.step ?? 0} was enough)');
        _sframeHealProgress.remove(peerId);
        _sframeEscalations.remove(peerId);
      }
    }
  }

  /// Drop all heal tracking (channel leave / service teardown).
  void _resetSframeHeal() {
    _sframeHealTimer?.cancel();
    _sframeHealTimer = null;
    _sframeKeylessTimer?.cancel();
    _sframeKeylessTimer = null;
    _sframeKeylessTicks = 0;
    _sframeFailures.clear();
    _sframeHealProgress.clear();
    _sframeEscalations.clear();
  }

  void _armSframeKeylessWatchdog() {
    _sframeKeylessTimer?.cancel();
    _sframeKeylessTicks = 0;
    _sframeKeylessTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _sframeKeylessTick());
  }

  void _sframeKeylessTick() {
    final svc = _service;
    if (!state.isInVoiceChannel || svc == null) {
      _sframeKeylessTimer?.cancel();
      _sframeKeylessTimer = null;
      return;
    }
    if (svc.frameCryptor?.isEnabled == true) {
      // First key landed — the cryptor-state heal ladder owns recovery now.
      _sframeKeylessTimer?.cancel();
      _sframeKeylessTimer = null;
      return;
    }
    _sframeKeylessTicks++;
    if (_sframeKeylessTicks > 24) {
      // ~2 min without a key (group authority offline). Stop nagging — a
      // later MlsEpochChanged still applies normally via onEpochChanged.
      _sframeKeylessTimer?.cancel();
      _sframeKeylessTimer = null;
      return;
    }
    debugPrint('[HOLLOW-VC] SFrame keyless after join '
        '(tick $_sframeKeylessTicks) — nudging Rust for the group key');
    // Rust's group-less heal branch re-requests the MLS bootstrap (rate
    // limited by MLS_BOOTSTRAP_TIMEOUT); peerId is unused on that branch.
    _sframeHealRust('', escalate: false);
  }

  Future<void> _sframeHealTick() async {
    if (!state.isInVoiceChannel || _service == null) {
      _resetSframeHeal();
      return;
    }
    if (_sframeFailures.isEmpty) {
      _sframeHealTimer?.cancel();
      _sframeHealTimer = null;
      return;
    }
    final now = DateTime.now();
    // Earliest failure per peer.
    final failingPeers = <String, DateTime>{};
    _sframeFailures.forEach((k, t) {
      final peer = k.substring(0, k.indexOf('|'));
      final cur = failingPeers[peer];
      if (cur == null || t.isBefore(cur)) failingPeers[peer] = t;
    });
    for (final e in failingPeers.entries) {
      final peerId = e.key;
      // Give normal epoch-rotation races a moment to settle on their own.
      if (now.difference(e.value) < const Duration(seconds: 2)) continue;
      final prog = _sframeHealProgress[peerId];
      if (prog != null && prog.step >= 4) continue; // gave up on this peer
      if (prog == null) {
        debugPrint('[HOLLOW-VC] SFrame heal 1/3 for $peerId — '
            're-applying key + rebinding receivers');
        await _sframeHealReapply(peerId);
        _sframeHealProgress[peerId] = (step: 1, at: DateTime.now());
      } else if (prog.step == 1 &&
          now.difference(prog.at) >= const Duration(seconds: 4)) {
        debugPrint('[HOLLOW-VC] SFrame heal 2/3 for $peerId — '
            'asking Rust to re-emit the MLS key');
        _sframeHealRust(peerId, escalate: false);
        _sframeHealProgress[peerId] = (step: 2, at: DateTime.now());
      } else if (prog.step >= 2 &&
          now.difference(prog.at) >= const Duration(seconds: 8)) {
        final attempts = _sframeEscalations[peerId] ?? 0;
        if (attempts >= _kMaxSframeEscalations) {
          // Unhealable peer (still failing after repeated group surgery) —
          // stop; further escalation would just churn the server MLS group.
          debugPrint('[HOLLOW-VC] SFrame heal for $peerId exhausted '
              '($attempts escalations) — giving up on this peer');
          _sframeHealProgress[peerId] = (step: 4, at: DateTime.now());
          continue;
        }
        final cooldownOk = _lastSframeEscalateAt == null ||
            now.difference(_lastSframeEscalateAt!) >=
                const Duration(seconds: 60);
        if (cooldownOk) {
          debugPrint('[HOLLOW-VC] SFrame heal 3/3 for $peerId — '
              'requesting MLS re-bootstrap');
          _lastSframeEscalateAt = DateTime.now();
          _sframeEscalations[peerId] = attempts + 1;
          _sframeHealRust(peerId, escalate: true);
          _sframeHealProgress[peerId] = (step: 3, at: DateTime.now());
        } else {
          // Escalation on cooldown — keep cycling the cheap re-emit. This is
          // also what re-keys US promptly after the authority's heal removed
          // and re-added our leaves (the !has_group branch re-bootstraps).
          _sframeHealRust(peerId, escalate: false);
          _sframeHealProgress[peerId] = (step: 2, at: DateTime.now());
        }
      }
    }
  }

  /// Heal step 1: re-apply the cached key for the current channel and rebind
  /// the failing peer's receiver cryptors.
  Future<void> _sframeHealReapply(String peerId) async {
    final sid = state.currentServerId;
    final cid = state.currentChannelId;
    final svc = _service;
    if (sid == null || cid == null || svc == null) return;
    final usesSubgroup = _channelUsesSubgroup(cid);
    final cached = _sframeKeys[_sframeCacheKey(sid, cid)] ??
        (usesSubgroup ? null : _sframeKeys[_sframeCacheKey(sid, null)]);
    if (cached != null) {
      await svc.setSframeKey(cached.epoch, Uint8List.fromList(cached.key));
    }
    await svc.rebindReceiversFor(peerId);
  }

  /// Heal steps 2/3: hand over to Rust (re-export + re-emit the current MLS
  /// key; with [escalate] also re-bootstrap the group / re-add the peer).
  void _sframeHealRust(String peerId, {required bool escalate}) {
    final sid = state.currentServerId;
    final cid = state.currentChannelId;
    if (sid == null || cid == null) return;
    network_api
        .voiceSframeHeal(
            serverId: sid, channelId: cid, peerId: peerId, escalate: escalate)
        .catchError((_) {});
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
    // No key material (MLS-less server) → leave the share PC untransformed on
    // BOTH sides. A keyless sender cryptor would silently DROP every frame,
    // and this unguarded enable used to flip the service's enabled flag on
    // the sharer only — the asymmetry behind issue #27.
    if (!frameCryptor.isEnabled) {
      debugPrint('[HOLLOW-VC] No SFrame key yet — share PC stays untransformed (peer=$peerId)');
      return;
    }
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
