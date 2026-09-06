import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:hollow/src/core/providers/audio_route_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/viewer_display.dart';
import 'package:hollow/src/core/providers/forwarder_info_provider.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/services/realtime_session_flag.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/services/audio_route.dart';
import 'package:hollow/src/core/services/desktop_capture_support.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/ice_route_probe.dart';
import 'package:hollow/src/core/services/macos_version.dart';
import 'package:hollow/src/core/services/mobile_screen_audio_capturer.dart';
import 'package:hollow/src/core/services/screen_audio_receiver.dart';
import 'package:hollow/src/core/services/share_audio_level.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Log to hollow_debug.log; console-only when the FFI isn't up (tests).
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

  final bool isMuted;

  /// Whether the local user is deafened (muted + no audio output).
  final bool isDeafened;

  final Map<String, PeerAudioState> peerAudioStates;

  // Speaking (VAD) state lives in vcSpeakingProvider, not here: it flips
  // 1-4x/sec per talker and would rebuild every voiceChannelProvider watcher.

  /// Per-peer volume overrides (peer_id -> 0.0-2.0).
  final Map<String, double> peerVolumes;

  /// Current voice mode: "mesh" or "gossip".
  final String voiceMode;

  /// Gossip neighbors for the current voice channel (gossip mode only).
  final Set<String> gossipNeighbors;

  final DateTime? joinedAt;

  final bool isScreenSharing;

  /// Quality label for the local screen share (e.g. "1080p60"). Null when not sharing.
  final String? screenShareLabel;

  final Map<String, bool> peerScreenSharing;

  final Map<String, String> peerScreenShareLabels;

  /// Which sharer is displayed full-bleed (null = none).
  final String? focusedScreenSharePeerId;

  /// Type of the focused source in mixed mode: 'screen' or 'camera'.
  final String focusedSourceType;

  /// Remote sharers we explicitly opted into watching (issue #38): a share
  /// never streams to us until its peer id is here; the rest is just the badge.
  final Set<String> watchingScreenShares;

  /// Shares we asked to receive at SOURCE quality. OFF by default: the sharer
  /// otherwise clamps to our display resolution, and the opt-in is never sticky.

  /// Desktop-only: a tile grid of all sources instead of one full-bleed.
  final bool isGridView;

  final bool isCameraOn;

  /// Local camera facing (true = front). Local previews mirror only the
  /// front camera — a mirrored back camera shows text reversed.
  final bool isFrontCamera;

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
    this.isGridView = false,
    this.isCameraOn = false,
    this.isFrontCamera = true,
    this.peerCameraOn = const {},
    this.isSpeakerOn = false,
  });

  Set<String> getParticipants(String serverId, String channelId) {
    return participants[serverId]?[channelId] ?? {};
  }

  /// The entry in a channel's participant set that is US, in the id form THAT
  /// SET uses, or null when we're genuinely not in the channel. The sets are
  /// keyed by ROUTABLE DEVICE id, so a bare master test never matches.
  String? selfParticipantId(
    String serverId,
    String channelId, {
    required String master,
    String? device,
  }) {
    for (final p in getParticipants(serverId, channelId)) {
      if (p == master || (device != null && device.isNotEmpty && p == device)) {
        return p;
      }
    }
    return null;
  }

  bool get isInVoiceChannel => currentChannelId != null;

  /// Get audio state for a peer (returns default if unknown).
  PeerAudioState getPeerAudioState(String peerId) {
    return peerAudioStates[peerId] ?? const PeerAudioState();
  }

  /// Get saved volume for a peer (default 1.0).
  double getPeerVolume(String peerId) => peerVolumes[peerId] ?? 1.0;

  bool get isWatchingAnyShare => watchingScreenShares.isNotEmpty;

  /// Whether the share surface shows: we're sharing, or watching an opted-in share.
  bool get showsShareSurface => isScreenSharing || isWatchingAnyShare;

  List<String> get unwatchedRemoteShares => [
        for (final e in peerScreenSharing.entries)
          if (e.value && !watchingScreenShares.contains(e.key)) e.key,
      ];

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

/// Sharer-side state for ONE forwarder serving our share: the VPS forwarder
/// or a promoted viewer-peer forwarder, each with its own single ingest leg.
class _FwdBranch {
  _FwdBranch(this.forwarderId, {required this.isPeer});

  final String forwarderId;

  /// True = a promoted viewer-peer forwarder: its own display is downstream
  /// viewer #0, and its remote capacity is [VoiceChannelNotifier.maxPeerForwarderLegs].
  final bool isPeer;

  /// REMOTE downstream viewers served through this branch; a peer branch's own
  /// display is not here (local leg) but is on the allowlist and in the cap.
  final Set<String> viewers = {};

  ScreenShareService? ingest;

  /// The ingest carries 2 simulcast layers (rid f/q) and the engine selects
  /// per-viewer; decided at ingest creation, drives the register's low_viewers.
  bool simulcast = false;

  /// The forwarder this branch's HEAD was elected to feed, so we upload one
  /// copy instead of two when a peer branch and the VPS both serve. Empty = none.
  String feedTarget = '';

  /// The head's feed leg reported up: we may stop supplying [feedTarget]
  /// ourselves. Until then we keep our own ingest there — make-before-break.
  bool feedUp = false;

  /// Gives up on an elected feeder that never reports up.
  Timer? feedTimeout;

  /// A feed leg is an egress leg: it costs the head one remote-leg slot.
  int get usedLegs => viewers.length + (feedTarget.isEmpty ? 0 : 1);

  /// Tears the idle branch down ~30 s after its last viewer leaves.
  Timer? linger;
}

class VoiceChannelNotifier extends Notifier<VoiceChannelState> {
  static const int maxScreenShareOutgoing = 15;
  static const int maxScreenShareIncoming = 10;

  /// Direct per-viewer PCs before further step-3-capable viewers go through
  /// branches. SOFT: with no branch rung the viewer still gets a direct PC.
  static const int maxDirectShareCopies = 1;

  VoiceChannelService? _service;

  final Map<String, ScreenShareService> _outgoingScreenShares = {};

  final Map<String, ScreenShareService> _incomingScreenShares = {};

  /// Early ICE candidates that arrived before the service was created.
  /// Key: "incoming:peerId" or "outgoing:peerId"
  final Map<String, List<Map<String, dynamic>>> _earlyScreenIce = {};

  /// Peers that requested to watch OUR share via screen_watch (issue #38).
  /// We only ever send a screen offer to peers in this set.
  final Set<String> _watchers = {};

  /// Per-watcher display resolution from screen_watch: clamps THAT viewer's
  /// stream to their monitor. Absent / 0x0 = unknown (old client) = no clamp.
  final Map<String, ({int w, int h})> _watcherDisplays = {};

  /// Peers whose audio PC reached connected: the precondition for a screen offer.
  final Set<String> _audioConnectedPeers = {};

  /// Viewer-side "offer never came" timeouts, keyed by sharer peer id.
  final Map<String, Timer> _watchConnectTimers = {};

  /// Our share session's stream id, riding `origin.stream`; minted per share.
  String? _shareSessionId;

  /// The id we self-attribute shares under: our ROUTABLE device peer id.
  String? _shareOriginPeer;

  /// Per-ORIGINATOR record of who DELIVERED their stream plus its wire metadata
  /// (deliverer == originator on direct legs); echoed on answers/ICE.
  final Map<String, ({String deliverer, String kind, String stream})>
      _incomingShareOrigins = {};

  /// Sharer side: one forwarder BRANCH per forwarder peer id, each with ONE
  /// ingest leg; branch viewers hold no per-viewer PC and skip the 15-cap.
  final Map<String, _FwdBranch> _fwdBranches = {};

  /// Sharer side: per-watcher route hint, forwarding capability and privacy
  /// flag from their screen_watch. Candidates = fwd_capable && route ==
  /// 'direct'; relayPrivate viewers only ever route through operator infra.
  final Map<
          String,
          ({
            String route,
            bool fwdCapable,
            bool relayPrivate,
            bool fwdSimulcast,
            bool fwdFeed
          })>
      _watcherRoutes = {};

  /// Forwarders that FAILED for a viewer this share session; never re-assigned
  /// to the same viewer, and two failures mean the viewer goes direct.
  final Map<String, Set<String>> _viewerFwdFailures = {};

  /// Max REMOTE downstream viewers per viewer-peer forwarder (its display is free).
  static const int maxPeerForwarderLegs = 3;

  /// Viewer side: forwarder assignments by ORIGINATOR. fwd_* frames are honored
  /// ONLY for assigned origins from the assigned forwarder, which may be US.
  final Map<String, ({String forwarder, String kind, String stream})>
      _screenAssignments = {};

  /// Viewer side: forwarder fallback attempts per origin this watch session.
  /// Ladder = peer forwarder -> VPS forwarder -> direct+TURN, so two attempts.
  final Map<String, int> _fwdFallbackCount = {};

  /// Our ROUTABLE device peer id, cached for the self-assignment check.
  String? _myDevicePeerId;

  /// Origins whose SELF-attach already got its one bounded retry after an
  /// `unknown_stream` (the local attach can race the sharer's register).
  final Set<String> _selfAttachRetried = {};

  /// Cached SFrame keys from MLS epoch changes, applied when the service is
  /// (re)created. channelId == null is the server-wide group key; a non-null one
  /// is a restricted channel's MLS SUBGROUP key and applies ONLY to that voice
  /// channel, so a non-qualifying member who never gets it cannot decode audio.
  final Map<String, ({int epoch, Uint8List key})> _sframeKeys = {};

  /// Cache key for an SFrame secret. A subgroup key is scoped to its channel; the
  /// server-group key uses a sentinel so it can't collide with any channel id.
  static String _sframeCacheKey(String serverId, String? channelId) =>
      '$serverId ${channelId ?? ''}';

  // SFrame heal ladder (issue #27): sustained MissingKey/DecryptionFailed
  // means we and the peer disagree on key material, so rather than playing
  // garbage forever the ladder re-applies, re-exports, then re-bootstraps MLS.

  /// Cryptor keys ('peer|kind|rx/tx') currently in a failure state → first seen.
  final Map<String, DateTime> _sframeFailures = {};

  final Map<String, ({int step, DateTime at})> _sframeHealProgress = {};

  /// Global cooldown for step 3 (MLS group surgery is expensive).
  DateTime? _lastSframeEscalateAt;

  /// Step-3 attempts per peer this session; after [_kMaxSframeEscalations] the
  /// ladder gives up, or an unhealable peer churns the server MLS group forever.
  final Map<String, int> _sframeEscalations = {};
  static const int _kMaxSframeEscalations = 2;

  Timer? _sframeHealTimer;

  /// MissingKey fast-path throttle: collapses a storm to one round-trip per peer.
  final Map<String, DateTime> _sframeMissingKeyPings = {};

  /// Keyless watchdog (issue #47 -> #27): with NO SFrame key no cryptors exist,
  /// so no cryptor-state callback ever arms the heal ladder and the identity
  /// transmits plaintext against peers' ciphertext. Ticks until the first key.
  Timer? _sframeKeylessTimer;
  int _sframeKeylessTicks = 0;

  /// Whether a channel is cryptographically isolated in its own MLS subgroup:
  /// restricted visibility AND not public. Mirrors Rust `channel_uses_subgroup`;
  /// such a channel's SFrame key comes ONLY from its subgroup.
  bool _channelUsesSubgroup(String channelId) {
    final ch = ref.read(channelListProvider)[channelId];
    if (ch == null) return false;
    // Label-gated channels are subgrouped too. This is a KEY-DOMAIN decision:
    // never rely on the admin-tier stamp, mirror Rust's rule exactly.
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

  /// MOBILE share-audio capture: ONE instance for the whole channel, because the
  /// Rust Opus encoder is a process-global singleton. Fans out at send time.
  MobileScreenAudioCapturer? _mobileShareAudioCapturer;

  /// Entire-screen anti-echo (Windows): the voice-render child pid to EXCLUDE
  /// from screen-audio capture so the VC voices it plays aren't re-captured,
  /// and whether the redirect is armed. Armed once per share, reset on stop.
  int _screenShareExcludePid = 0;
  bool _voiceRedirectActive = false;

  Timer? _screenTrackPoller;

  bool _leaving = false;

  /// Bumped by every join and every teardown. `onLocalJoined` is a long async
  /// bring-up the user can leave or hop straight through; a run that resumes
  /// on a stale generation must abandon its half-built service, not `_service!`.
  int _joinGen = 0;

  /// In-flight teardown from the server-forced `onLocalLeft` path, which its
  /// synchronous caller cannot await. A later `joinChannel` awaits this so new
  /// PCs can't race the old mesh's native teardown (heap corruption on Linux).
  Future<void>? _teardownInFlight;

  /// Channel that was selected before joining the VC (restored on leave).
  String? preVcChannelId;

  RTCVideoRenderer? _localCameraRenderer;

  final Map<String, RTCVideoRenderer> _remoteCameraRenderers = {};

  /// Device-provider listeners registered once (the join path re-runs).
  bool _deviceListenersWired = false;

  @override
  VoiceChannelState build() {
    // The service snapshots its ICE config at join time, so updates are pushed in:
    // a TURN refresh or an Always-relay flip mid-channel would otherwise be lost.
    ref.listen<Map<String, dynamic>>(iceConfigProvider, (_, next) {
      _service?.iceServers = next;
    });
    return const VoiceChannelState();
  }

  /// Live camera device switch: rebind the self-view to the fresh capture stream.
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

  RTCVideoRenderer? getScreenShareRenderer(String peerId) =>
      _incomingScreenShares[peerId]?.remoteRenderer;

  /// The local screen share self-preview renderer, tied to the capture stream
  /// so it works even when alone in the channel.
  RTCVideoRenderer? get localScreenShareRenderer =>
      _localScreenPreviewRenderer;

  RTCVideoRenderer? getCameraRenderer(String peerId) {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    if (peerId == localPeerId) return _localCameraRenderer;
    return _remoteCameraRenderers[peerId];
  }

  /// Returns true only for a peer NOT already in this channel's roster: a join
  /// arrives twice by design and a relay rejoin re-announces.
  bool onPeerJoined(String serverId, String channelId, String peerId) {
    final already =
        state.participants[serverId]?[channelId]?.contains(peerId) ?? false;
    final updated = _deepCopyParticipants();
    updated.putIfAbsent(serverId, () => {});
    updated[serverId]!.putIfAbsent(channelId, () => {});
    updated[serverId]![channelId] =
        {...updated[serverId]![channelId]!, peerId};
    state = state.copyWith(participants: updated);
    return !already;
  }

  void onPeerLeft(String serverId, String channelId, String peerId) {
    final updated = _deepCopyParticipants();
    updated[serverId]?[channelId]?.remove(peerId);
    if (updated[serverId]?[channelId]?.isEmpty ?? false) {
      updated[serverId]!.remove(channelId);
    }
    if (updated[serverId]?.isEmpty ?? false) {
      updated.remove(serverId);
    }
    final audioStates = Map.of(state.peerAudioStates)..remove(peerId);
    state = state.copyWith(participants: updated, peerAudioStates: audioStates);
  }

  /// Drop every REMOTE participant tracked under [serverId] (all channels).
  /// Conferences call this on meeting start/end/leave: a previous meeting's
  /// members linger otherwise, and restarting reuses the same `conf:x:main` key.
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
    // While a voice session is live the relay socket retries every second
    // instead of backing off toward thirty, so a blinking Wi-Fi is back fast.
    RealtimeSessionFlag.acquire('voice-channel');
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

    // Don't build new PCs while a forced teardown's mesh is mid-dispose.
    final pending = _teardownInFlight;
    if (pending != null) {
      debugPrint('[HOLLOW-VC] joinChannel waiting for in-flight teardown');
      try {
        await pending;
      } catch (_) {}
    }

    if (state.isInVoiceChannel) {
      await leaveChannel();
    }

    await network_api.voiceChannelJoin(
      serverId: serverId,
      channelId: channelId,
    );
  }

  /// True once this join has been superseded (left, forced out, or joined
  /// elsewhere) while this bring-up was still walking its awaits.
  ///
  /// Closing [svc] here is only OUR job when another join replaced the field
  /// without a teardown: `_service == null` means a leave already owns it, and
  /// closing again is the double-dispose that corrupts the heap on Linux.
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

    // `duringCall` even though the mic isn't open yet (#55): the clip outlives
    // this line by half a second, by which point WebRTC owns the iOS session.
    SoundService.instance.play(HollowSound.joinVoice, duringCall: true);

    // Group voice channels default to the loudspeaker on mobile.
    _setSpeakerRoute(true);

    // CRITICAL: the service's localPeerId must be the ROUTABLE DEVICE id. VC
    // participants and signal senders are device-keyed, so a master id here
    // makes both sides elect themselves offerer: glare, crossed answers, dead mic.
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

    svc.preferredAudioInputDeviceId =
        await ref.read(audioInputDeviceProvider.future);
    svc.preferredAudioOutputDeviceId =
        await ref.read(audioOutputDeviceProvider.future);
    svc.preferredCameraDeviceId =
        await ref.read(cameraDeviceProvider.future);

    final preset = await ref.read(audioQualityProvider.future);
    svc.opusBitrate = preset.bitrate;
    svc.opusStereo = preset.stereo;

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

    // Bail before opening the mic if the channel is already behind us.
    if (await _joinSuperseded(gen, svc)) return;

    _armSframeKeylessWatchdog();

    // VAD writes go to vcSpeakingProvider, not VoiceChannelState, so a speaking
    // flip rebuilds only the glow consumers.
    svc.onSpeakingChanged = (speaking, localSpeaking) {
      ref.read(vcSpeakingProvider.notifier).set(speaking);
      ref.read(vcLocalSpeakingProvider.notifier).set(localSpeaking);
      // Sidechain: anyone talking pulls received share audio down.
      ShareAudioLevel.setSpeaking(speaking.isNotEmpty || localSpeaking);
    };

    // ICE repair, lever 1: the provider owns policy. Forced-relay users are
    // NEVER repaired, that routing is their deliberate choice.
    svc.isForcedRelay = () => ref.read(alwaysRelayCallsProvider);
    // A member on a bad connection is labelled on their own tile only.
    svc.onLinkHealth = (peerId, snapshot) =>
        ref.read(vcLinkHealthProvider.notifier).setFor(peerId, snapshot);
    // See the DM twin: an ICE restart offer needs the relay to carry it, so a
    // restart fired while our own relay link is down is a wasted attempt.
    svc.canSignal = () =>
        ref.read(connectionStatusProvider).relayStatus ==
        RelayConnectionStatus.connected;
    // Only the provider owns the participant sets, so it answers this.
    svc.isChannelParticipant = (peerId) {
      final sid = state.currentServerId;
      final cid = state.currentChannelId;
      if (sid == null || cid == null) return false;
      return state.getParticipants(sid, cid).contains(peerId);
    };
    // A repaired audio PC changes our route hint, which lets the sharer promote us.
    svc.onIceRouteRepaired = (peerId, direct) {
      if (!direct) return;
      if (state.watchingScreenShares.contains(peerId)) {
        _scheduleRouteReprobe(peerId, delay: const Duration(seconds: 1));
      }
    };

    svc.onPeerConnected = (peerId) {
      if (_leaving || _stoppingScreenShare) return;

      // Screen audio on Windows rides the WebRtcService data channel.
      if (Platform.isWindows) {
        final webrtc = ref.read(webRtcProvider.notifier).service;
        if (!webrtc.hasPeerChannel(peerId)) {
          network_api.logFromDart(message: '[HOLLOW-AU-SCREEN] Ensuring WebRtcService DC for $peerId');
          webrtc.connectToPeer(peerId);
        }
      }

      _audioConnectedPeers.add(peerId);

      // Our route hint was probed before this PC settled; re-probe once, an
      // upgrade to `direct` lets the sharer promote us off the relay path.
      if (state.watchingScreenShares.contains(peerId)) {
        _scheduleRouteReprobe(peerId);
      }

      // Opt-in watching (issue #38): only peers that asked via screen_watch get
      // our share, and forwarder-served viewers never get a direct PC here.
      if (state.isScreenSharing &&
          _screenCaptureStream != null &&
          _watchers.contains(peerId) &&
          _branchOf(peerId) == null &&
          !_fwdBranches.containsKey(peerId)) {
        if (!_outgoingScreenShares.containsKey(peerId) &&
            _outgoingScreenShares.length < maxScreenShareOutgoing) {
          debugPrint('[HOLLOW-VC] Watcher $peerId connected — sending screen share offer');
          _sendScreenShareToPeer(peerId);
        }
      }
    };

    // Incoming Opus share audio from peers. Windows plays it via an
    // out-of-process exe; macOS/Linux not implemented (macOS uses Process Tap).
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

    // Seed the share-audio bus, carrying live deafen state into a rejoin.
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

    svc.onRemoteVideoChanged = (peerId, renderer) {
      if (renderer != null) {
        _remoteCameraRenderers[peerId] = renderer;
      } else {
        _remoteCameraRenderers.remove(peerId);
      }
      final cameras = Map.of(state.peerCameraOn);
      cameras[peerId] = renderer != null;
      if (renderer == null) cameras.remove(peerId);
      state = state.copyWith(peerCameraOn: cameras);
    };

    // Cryptor failure states drive recovery instead of playing garbage.
    svc.onSframeCryptorState = _onSframeCryptorState;

    await svc.startAudio(serverId, channelId);

    // The mic is live: if the channel went away while it opened, give it back.
    if (await _joinSuperseded(gen, svc)) return;

    // In PTT mode the mic starts capture-muted while state.isMuted stays false:
    // peers see us unmuted and the key gates actual transmission.
    _applyTxGate();

    // Re-assert the speaker route: the platform audio bring-up lands after the
    // early _setSpeakerRoute and can clobber it back to the earpiece.
    _setSpeakerRoute(state.isSpeakerOn);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!_leaving && state.isInVoiceChannel) {
        _setSpeakerRoute(state.isSpeakerOn);
      }
    });

    // AI-NS fallback check for sessions that STARTED with the toggle on.
    if (_service?.noiseSuppressAi == true) {
      unawaited(Future.delayed(const Duration(seconds: 4), () {
        return _service?.reconcileNoiseSuppressAi().catchError((_) {}) ??
            Future.value();
      }));
    }

    ref.listen(micGainProvider, (_, next) {
      final gain = next.valueOrNull ?? kMicGainDefault;
      _service?.updateMicGain(gain);
    });

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

    // Registered ONCE: this join path re-runs per join and would stack duplicate
    // listeners. Guard on prev==next because AsyncNotifier fires on initial load.
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
      // AI noise suppression re-captures the mesh mic, so it must not stack per join.
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
      // Live native handle swap: no re-capture, no mesh reneg.
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

    // Apply cached SFrame key. A RESTRICTED channel uses ONLY its subgroup key,
    // never the server-group key, which would defeat the cryptographic isolation.
    final usesSubgroup = _channelUsesSubgroup(channelId);
    final cached = _sframeKeys[_sframeCacheKey(serverId, channelId)] ??
        (usesSubgroup ? null : _sframeKeys[_sframeCacheKey(serverId, null)]);
    if (cached != null) {
      debugPrint('[HOLLOW-VC] Applying cached SFrame key (epoch=${cached.epoch}) to new service');
      await svc.setSframeKey(cached.epoch, Uint8List.fromList(cached.key));
    } else if (usesSubgroup) {
      // Not delivered yet: MlsEpochChanged(channelId) rotates it in later.
      debugPrint('[HOLLOW-VC] Restricted channel $channelId — awaiting subgroup SFrame key');
    }

    // Each dial is a full PC bring-up, so re-check between them rather than
    // build a mesh into a channel we've left. Self-skip covers BOTH id forms:
    // a master-form self entry surviving a device-only skip was the ghost bug.
    final localMaster = ref.read(identityProvider).peerId ?? '';
    final existing = state.getParticipants(serverId, channelId);
    for (final peerId in existing) {
      if (peerId == localPeerId || peerId == localMaster) continue;
      if (await _joinSuperseded(gen, svc)) return;
      await svc.onPeerJoinedMyChannel(peerId);
    }
  }

  /// Called when a remote peer joins our current voice channel.
  Future<void> onRemotePeerJoined(String peerId,
      {bool isNewArrival = true}) async {
    if (_service == null || !state.isInVoiceChannel) return;
    // Deafened means silence, so channel chatter cues stay out; your own
    // toggles still click. [isNewArrival] false is a re-announce, not an arrival.
    if (isNewArrival && !state.isDeafened) {
      SoundService.instance.play(HollowSound.joinVoice, duringCall: true);
    }
    await _service!.onPeerJoinedMyChannel(peerId);

    // Tell a late joiner we're sharing (badge + Watch banner). The screen_offer
    // only follows their screen_watch and a connected audio PC.
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

    if (state.isCameraOn) {
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'camera_state',
        payload: jsonEncode({'enabled': true}),
      );
    }

    // audio_state is otherwise only sent on toggle, so a late joiner would miss it.
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

  /// Called when a remote peer leaves a voice channel.
  ///
  /// [inOurChannel] is false when they left another channel of a server we can
  /// see: the teardown is a no-op, but the leave cue must not fire.
  Future<void> onRemotePeerLeft(String peerId,
      {bool inOurChannel = true}) async {
    if (_service == null) return;
    if (inOurChannel && state.isInVoiceChannel && !state.isDeafened) {
      SoundService.instance.play(HollowSound.leaveVoice, duringCall: true);
    }
    await _service!.onPeerLeftMyChannel(peerId);
    _watchers.remove(peerId);
    _watcherDisplays.remove(peerId);
    _audioConnectedPeers.remove(peerId);
    _sframeFailures.removeWhere((k, _) => k.startsWith('$peerId|'));
    _sframeHealProgress.remove(peerId);
    _sframeEscalations.remove(peerId);
    _sframeMissingKeyPings.remove(peerId);
    await _cleanupPeerScreenShare(peerId);
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
    if (signalType == 'camera_state') {
      _handleCameraState(peerId, payload);
      return;
    }
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
    if (signalType == 'screen_assign') {
      await _handleScreenAssign(peerId, payload);
      return;
    }
    if (signalType == 'screen_feed_state') {
      final v = jsonDecode(payload);
      final origin = v['origin'];
      final originPeer = origin is Map ? (origin['peer'] as String? ?? '') : '';
      // Only about OUR OWN stream — a feeder can only speak for what we sent.
      if (originPeer.isNotEmpty && originPeer == (_shareOriginPeer ?? '')) {
        await _handleFeedState(
          peerId,
          v['forwarder'] as String? ?? '',
          v['up'] as bool? ?? false,
        );
      }
      return;
    }
    if (_service == null) return;
    await _service!.handleSignal(
        peerId, signalType, payload, serverId, channelId);
  }

  /// Leave the current voice channel.
  Future<void> leaveChannel() async {
    RealtimeSessionFlag.release('voice-channel');
    if (!state.isInVoiceChannel || _leaving) return;
    _leaving = true;
    // Retire the join before the FFI round-trip, not after it.
    _joinGen++;

    final serverId = state.currentServerId!;
    final channelId = state.currentChannelId!;

    // Leave Rust FIRST, so a throwing cleanup can't leave us in the channel.
    try {
      await network_api.voiceChannelLeave(
        serverId: serverId,
        channelId: channelId,
      );
    } catch (e) {
      debugPrint('[HOLLOW-VC] voiceChannelLeave FFI error: $e');
    }

    await _teardownCall();

    _leaving = false;
  }

  /// Tear down all live call media. Idempotent; shared by `leaveChannel()` and
  /// the server-forced leave path in `onLocalLeft()`.
  Future<void> _teardownCall() async {
    _resetSframeHeal();
    // Whatever join is mid-flight no longer owns this call.
    _joinGen++;
    try {
      if (_localCameraRenderer != null) {
        _localCameraRenderer!.srcObject = null;
        await _localCameraRenderer!.dispose();
        _localCameraRenderer = null;
      }

      for (final renderer in _remoteCameraRenderers.values) {
        renderer.srcObject = null;
        await renderer.dispose();
      }
      _remoteCameraRenderers.clear();

      _audioConnectedPeers.clear();
      await _cleanupAllScreenShares();

      // AFTER the capturer is gone; idempotent with stopScreenShare.
      await _disarmVoiceRedirect();

      if (_screenAudioRenderer != null) {
        ShareAudioLevel.detach(_screenAudioRenderer!);
        await _screenAudioRenderer!.stop();
        _screenAudioRenderer = null;
      }
      ShareAudioLevel.setSendingShareAudio(false);
      try {
        ref.read(webRtcProvider.notifier).service.onScreenAudioReceived = null;
      } catch (_) {}

      if (_service != null) {
        await _service!.closeAll();
        _service = null;
      }
    } catch (e) {
      debugPrint('[HOLLOW-VC] call teardown error: $e');
      _service = null;
    } finally {
      // A teardown that threw part-way must not leave a stale health flair.
      ref.read(vcLinkHealthProvider.notifier).clear();
    }
  }

  /// Called after the local leave event arrives to update state.
  ///
  /// A non-null `_service` means Rust FORCED us out (lost visibility, demoted,
  /// kicked) and the call is still running, so the media teardown must run here.
  void onLocalLeft() {
    _leaving = false;
    if (state.isInVoiceChannel) {
      SoundService.instance.play(HollowSound.leaveVoice, duringCall: true);
    }
    if (_service != null) {
      // Server-forced leave: this callback is synchronous (a Rust event), so
      // record the teardown in-flight for a racing joinChannel to await.
      debugPrint('[HOLLOW-VC] Forced leave — tearing down live call');
      final teardown = _teardownCall();
      _teardownInFlight = teardown;
      teardown.whenComplete(() {
        if (identical(_teardownInFlight, teardown)) _teardownInFlight = null;
      });
    }
    // So the next call doesn't inherit a stale speakerphone state.
    if (_isMobile) {
      unawaited(Helper.setSpeakerphoneOn(false).catchError((_) {}));
      ref.read(audioRouteProvider.notifier).reset();
    }
    state = state.copyWith(clearCurrent: true);
    // Speaking state lives outside this state object — clear it with the rest.
    ref.read(vcSpeakingProvider.notifier).reset();
    ref.read(vcLocalSpeakingProvider.notifier).reset();
  }

  // Push-to-talk transmit gate (issue #38). PTT state lives OUTSIDE
  // VoiceChannelState: a key press must not rebuild every watcher, and no
  // audio_state fans out per press, so peers see a PTT user as unmuted.
  bool _pttMode = false;
  bool _pttTransmit = false;

  /// The mic transmits only when EVERY gate is open: not muted or deafened,
  /// and in PTT mode the key held. A manual mute always wins over a held key.
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
    SoundService.instance.play(HollowSound.toggle, duringCall: true);
    _applyTxGate();
    _broadcastAudioState();
  }

  void toggleDeafen() {
    if (_leaving) return;
    SoundService.instance.play(HollowSound.toggle, duringCall: true);
    final newDeafened = !state.isDeafened;
    state = state.copyWith(
      isMuted: newDeafened ? true : state.isMuted,
      isDeafened: newDeafened,
    );
    _applyTxGate();
    // Fire-and-forget, so it carries its own catch: a sync try/catch around an
    // un-awaited future catches nothing and the rejection hits the zone handler.
    unawaited(_service?.setDeafened(newDeafened).catchError((_) {}) ??
        Future.value());
    // setDeafened only zeroes WebRTC voice tracks; share audio has its own player.
    ShareAudioLevel.setDeafened(newDeafened);
    _broadcastAudioState();
  }

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Route audio to the loudspeaker (true) or earpiece (false). Mobile only.
  void _setSpeakerRoute(bool speaker) {
    if (!_isMobile) return;
    state = state.copyWith(isSpeakerOn: speaker);
    unawaited(_applySpeakerRoute(speaker));
  }

  // "Speaker on" means the LOUDEST SENSIBLE route, which with a headset
  // attached is the HEADSET: iOS's port override outranks headphones and
  // drags capture to the built-in mic with it. See [AudioRoutes].
  Future<void> _applySpeakerRoute(bool speaker) async {
    await AudioRoutes.preferLoudRoute(speaker);
    try {
      await ref.read(audioRouteProvider.notifier).refresh();
    } catch (_) {
      // Provider torn down mid-join (leave raced the route apply).
    }
  }

  /// Toggle loudspeaker/earpiece while in a voice channel. Mobile only.
  void toggleSpeaker() {
    if (_leaving || !state.isInVoiceChannel) return;
    _setSpeakerRoute(!state.isSpeakerOn);
  }

  Future<void> selectAudioRoute(AudioRoute route) async {
    if (!_isMobile || _leaving || !state.isInVoiceChannel) return;
    // Keep isSpeakerOn meaning "hands-free" for proximity blanking and the row.
    state = state.copyWith(isSpeakerOn: route.kind != AudioRouteKind.earpiece);
    await ref.read(audioRouteProvider.notifier).select(route);
  }

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

    // Awaited so the peer's PC + thread-set is gone before the next event.
    await _service?.closePeer(peerId);
    await _cleanupPeerScreenShare(peerId);
    await _cleanupPeerCamera(peerId);
  }

  void _broadcastAudioState() {
    if (!state.isInVoiceChannel) return;
    // The participant set is DEVICE-keyed (self included): skip both id forms.
    final localMaster = ref.read(identityProvider).peerId ?? '';
    final localDevice = _service?.localPeerId ?? _myDevicePeerId ?? '';
    final peers = state.getParticipants(
        state.currentServerId!, state.currentChannelId!);
    final payload = jsonEncode({
      'muted': state.isMuted,
      'deafened': state.isDeafened,
    });
    for (final peerId in peers) {
      if (peerId == localMaster || peerId == localDevice) continue;
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'audio_state',
        payload: payload,
      );
    }
  }

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

  Future<void> toggleCamera() async {
    if (_service == null || !state.isInVoiceChannel || _leaving) return;

    if (!state.isCameraOn) {
      final stream = await _service!.startCamera();
      if (stream == null) return;

      _localCameraRenderer = RTCVideoRenderer();
      await _localCameraRenderer!.initialize();
      _localCameraRenderer!.srcObject = stream;

      state = state.copyWith(
        isCameraOn: true,
        isFrontCamera: _service!.useFrontCamera,
      );
      // After startCamera: a failed camera must not sound like it turned on.
      SoundService.instance.play(HollowSound.toggle, duringCall: true);
      _broadcastCameraState(true);

      // Camera on implies hands-off use.
      if (_isMobile && !state.isSpeakerOn) {
        _setSpeakerRoute(true);
      }
    } else {
      await _service!.stopCamera();

      if (_localCameraRenderer != null) {
        _localCameraRenderer!.srcObject = null;
        await _localCameraRenderer!.dispose();
        _localCameraRenderer = null;
      }

      state = state.copyWith(isCameraOn: false);
      SoundService.instance.play(HollowSound.toggle, duringCall: true);
      _broadcastCameraState(false);
    }

    // Either camera flip restarts the platform audio unit (iOS VPIO especially),
    // which can drop the active route, so re-assert once it settles.
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

  void _broadcastCameraState(bool enabled) {
    if (!state.isInVoiceChannel) return;
    // Device-keyed set: skip both our id forms (see _broadcastAudioState).
    final localMaster = ref.read(identityProvider).peerId ?? '';
    final localDevice = _service?.localPeerId ?? _myDevicePeerId ?? '';
    final peers = state.getParticipants(
        state.currentServerId!, state.currentChannelId!);
    final payload = jsonEncode({'enabled': enabled});
    for (final peerId in peers) {
      if (peerId == localMaster || peerId == localDevice) continue;
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'camera_state',
        payload: payload,
      );
    }
  }

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

  void _handleCameraState(String peerId, String payload) {
    try {
      final v = jsonDecode(payload);
      final enabled = v['enabled'] as bool? ?? false;
      final cameras = Map.of(state.peerCameraOn);
      if (enabled) {
        cameras[peerId] = true;
      } else {
        cameras.remove(peerId);
        // Keep the renderer alive so the stream can resume when the camera comes
        // back: onTrack won't fire again for transceiver reuse. Disposed on leave.
      }
      state = state.copyWith(peerCameraOn: cameras);
    } catch (_) {}
  }

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

    // Mint this share session's identity; a restart mints a new stream id.
    final rng = Random.secure();
    _shareSessionId =
        List.generate(8, (_) => rng.nextInt(16).toRadixString(16)).join();
    _shareOriginPeer = await network_api.getLocalDevicePeerId() ??
        (ref.read(identityProvider).peerId ?? '');

    // Capture screen ONCE. Source enumeration is desktop-only; mobile
    // captures THE screen (MediaProjection / ReplayKit broadcast).
    if (Platform.isAndroid) {
      // Constraints are ignored by the Android plugin (MediaProjection captures
      // at native display size); the per-peer encoder cap does the downscaling.
      _screenCaptureStream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
    } else if (Platform.isIOS) {
      // 'broadcast' selects the ReplayKit Broadcast Upload Extension path.
      _screenCaptureStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {'deviceId': 'broadcast'},
        'audio': false,
      });
    } else {
      // A Wayland portal-first share MUST NOT re-enumerate: enumerating here
      // would pop an extra xdg-desktop-portal dialog.
      if (!DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        await desktopCapturer.getSources(
            types: DesktopCaptureSupport.sourceTypes);
      }
      // Windows and Linux carry share audio over a data channel, so never ask
      // getDisplayMedia for audio: the WASAPI path crashes Windows.
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
      // The portal grant now exists: the next share can reuse it promptless.
      if (DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        DesktopCaptureSupport.portalGrantLikely = true;
      }
    }

    _localScreenPreviewRenderer = RTCVideoRenderer();
    await _localScreenPreviewRenderer!.initialize();
    _localScreenPreviewRenderer!.srcObject = _screenCaptureStream;

    // Use the SHORT side so a portrait capture (1080x1920) reads "1080p".
    const resLabels = {360: '360p', 480: '480p', 720: '720p', 1080: '1080p', 1440: '1440p', 2160: '4K'};
    final shortSide = height < width ? height : width;
    final qualityLabel = '${resLabels[shortSide] ?? '${shortSide}p'}$fps';

    final localPeerId = ref.read(identityProvider).peerId ?? '';
    state = state.copyWith(
      isScreenSharing: true,
      screenShareLabel: qualityLabel,
      focusedScreenSharePeerId: localPeerId,
    );
    SoundService.instance.play(HollowSound.joinStream, duringCall: true);

    // Freeze the mic servo so speaker bleed can't re-calibrate the trim.
    if (shareAudio) {
      ShareAudioLevel.setSendingShareAudio(true);
    }

    // ENTIRE-SCREEN anti-echo (Windows): a whole-system capture would re-capture
    // the peers' voices, so redirect all inbound audio to an out-of-process
    // renderer and exclude THAT pid. Armed once here, covering every peer.
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

    // Opt-in watching (issue #38): no fan-out here. Peers learn from the
    // screen_state broadcast and request the share with screen_watch.

    // MOBILE: one central audio capture for the whole channel; fanning over
    // _outgoingScreenShares.keys picks up late joiners automatically.
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

    _broadcastScreenState(true);

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
    SoundService.instance.play(HollowSound.leaveStream, duringCall: true);
    ShareAudioLevel.setSendingShareAudio(false);

    try {
      _screenTrackPoller?.cancel();
      _screenTrackPoller = null;

      // Stop the central mobile capture first (no per-peer service owns it),
      // then the outgoing PCs, BEFORE disarming the redirect: otherwise the
      // window where VC voices play in-process is re-captured.
      await _stopMobileShareAudio();
      _watchers.clear();
      _watcherDisplays.clear();
      _watcherRoutes.clear();
      _viewerFwdFailures.clear();
      // Unregister at every forwarder BEFORE the session ids clear, since the
      // unregister envelopes need the origin.
      await _teardownAllBranches(unregister: true, demote: false);
      _shareSessionId = null;
      _shareOriginPeer = null;
      final sharePeers = _outgoingScreenShares.keys.toList();
      for (final service in _outgoingScreenShares.values) {
        try { await service.close(); } catch (_) {}
      }
      _outgoingScreenShares.clear();
      for (final peerId in sharePeers) {
        await _dropShareCryptors(peerId);
      }

      await _disarmVoiceRedirect();

      if (_localScreenPreviewRenderer != null) {
        _localScreenPreviewRenderer!.srcObject = null;
        await _localScreenPreviewRenderer!.dispose();
        _localScreenPreviewRenderer = null;
      }

      // Both are async: an unawaited stop/dispose outlives the share.
      for (final t in _screenCaptureStream?.getTracks() ?? []) {
        try { await t.stop(); } catch (_) {}
      }
      await _screenCaptureStream?.dispose();
      _screenCaptureStream = null;

      _broadcastScreenState(false);

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

  /// Disarm the entire-screen anti-echo voice redirect: restores in-process
  /// playout and shuts the renderer child down. No-op when not armed.
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

  /// The ORIGINATOR of a screen signal: who the stream is FROM, vs [sender]
  /// who DELIVERED it. Equal on every direct leg; forwarder legs differ.
  String _origOf(String sender, Map<String, dynamic> v) {
    final origin = v['origin'];
    if (origin is Map) {
      final p = origin['peer'];
      if (p is String && p.isNotEmpty) return p;
    }
    return sender;
  }

  /// Our own share's `origin` sub-object for outgoing screen offers/ICE. Null
  /// until startScreenShare minted the session (absent origin = sender, so safe).
  Map<String, dynamic>? _myShareOrigin() {
    final stream = _shareSessionId;
    final peer = _shareOriginPeer;
    if (stream == null || peer == null || peer.isEmpty) return null;
    return {'peer': peer, 'kind': 'screen', 'stream': stream};
  }

  /// Send our screen share to [peerId], creating its outgoing service.
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
      final origin = _myShareOrigin();
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
          'origin': ?origin,
        }),
      );
    };

    // Fast failover: without a disconnect handler a crashed viewer left the
    // encoder running and the slot occupied. Free it; the viewer re-watches.
    service.onDisconnected = () {
      if (_outgoingScreenShares[peerId] != service) return; // superseded
      _vcLog('[HOLLOW-VC] Direct share leg to $peerId died — releasing its '
          'slot (its re-watch will re-offer)');
      _outgoingScreenShares.remove(peerId);
      unawaited(service.close());
      unawaited(_dropShareCryptors(peerId));
    };

    // Close any prior outgoing service before overwriting the map entry, or
    // the old PC + thread-set is orphaned and can never be closed.
    final priorOutgoing = _outgoingScreenShares.remove(peerId);
    if (priorOutgoing != null) {
      await priorOutgoing.close();
      await _dropShareCryptors(peerId);
    }
    _outgoingScreenShares[peerId] = service;

    try {
      // Clamp to what THIS viewer's display can show.
      final (effMaxW, effMaxH) = _effectiveCapFor(peerId);
      final sdp = await service.createOfferFromStream(
        _screenCaptureStream!,
        maxWidth: effMaxW,
        maxHeight: effMaxH,
        fps: _screenShareFps,
        profile: _screenShareProfile,
      );

      if (service.pc != null && _service?.frameCryptor != null) {
        await _enableSframeOnScreenSharePc(
            service.pc!, _service!.frameCryptor!, peerId, isSender: true);
      }

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

      final origin = _myShareOrigin();
      network_api.voiceChannelSendSignal(
        serverId: state.currentServerId!,
        channelId: state.currentChannelId!,
        peerId: peerId,
        signalType: 'screen_offer',
        payload: jsonEncode({
          'sdp': sdp,
          'origin': ?origin,
        }),
      );

      // Desktop share audio runs one capturer exe per peer (Windows WASAPI,
      // Linux PulseAudio monitor, macOS 13+ ScreenCaptureKit). MOBILE is
      // deliberately absent: it runs ONE central capture in startScreenShare.
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

        // Late-joiner anti-echo: redirect THIS peer's voice too. voiceRedirectStart
        // is incremental, so no capturer restart and a no-op if already redirected.
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
      // A half-built service left in the map leaks its thread-set.
      debugPrint('[HOLLOW-VC] _sendScreenShareToPeer($peerId) failed: $e');
      await _outgoingScreenShares.remove(peerId)?.close();
      await _dropShareCryptors(peerId);
      rethrow;
    }
  }

  /// Handle an incoming screen share offer. Uses the serverId/channelId from
  /// the dispatch, since the signal can arrive before onLocalJoined sets state.
  Future<void> _handleScreenOffer(
    String peerId,
    String payload,
    String serverId,
    String channelId,
  ) async {
    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    // Everything about WHO the stream is from keys on the ORIGINATOR; [peerId]
    // (the deliverer) keeps transport routing. rawOrigin is echoed verbatim.
    final originPeer = _origOf(peerId, v);
    final rawOrigin =
        v['origin'] is Map ? Map<String, dynamic>.from(v['origin'] as Map) : null;

    debugPrint('[HOLLOW-VC] Received screen offer from $peerId (origin=$originPeer)');

    // Opt-in watching (issue #38): an offer we never asked for is dropped.
    // Consent refers to the ORIGINATOR's share, whoever delivers it.
    if (!state.watchingScreenShares.contains(originPeer)) {
      debugPrint('[HOLLOW-VC] Ignoring unsolicited screen offer for $originPeer (not watching)');
      return;
    }

    // A direct offer supersedes any forwarder assignment for this origin.
    final staleAssignment = _screenAssignments.remove(originPeer);
    if (staleAssignment != null) {
      _maybeLeaveFwdRoom(staleAssignment.forwarder);
    }

    final answerSdp = await _attachIncomingShare(
      originPeer: originPeer,
      delivererPeer: peerId,
      rawOrigin: rawOrigin,
      offerSdp: sdp,
      viaForwarder: false,
      serverId: serverId,
      channelId: channelId,
    );
    if (answerSdp == null) return;

    network_api.voiceChannelSendSignal(
      serverId: serverId,
      channelId: channelId,
      peerId: peerId,
      signalType: 'screen_answer',
      payload: jsonEncode({
        'sdp': answerSdp,
        'origin': ?rawOrigin,
      }),
    );
  }

  /// Shared construction of an incoming share leg: direct and forwarder-egress
  /// offers build the SAME service, keyed by ORIGINATOR everywhere (SFrame
  /// cryptor `'screen:$originPeer'`, renderer lookup), with the DELIVERER kept
  /// only for transport. Returns null when the incoming cap rejected the stream.
  ///
  /// Forwarder legs differ in two transport properties: STUN-only ICE (never
  /// forced-relay TURN, the forwarder IS the relay replacement) and COMPLETE
  /// SDPs, so no trickle lane and no early-ICE flush.
  Future<String?> _attachIncomingShare({
    required String originPeer,
    required String delivererPeer,
    required Map<String, dynamic>? rawOrigin,
    required String offerSdp,
    required bool viaForwarder,
    String? serverId,
    String? channelId,
  }) async {
    if (!_incomingScreenShares.containsKey(originPeer) &&
        _incomingScreenShares.length >= maxScreenShareIncoming) {
      debugPrint('[HOLLOW-VC] Rejecting screen offer for $originPeer — incoming cap ($maxScreenShareIncoming) reached');
      return null;
    }

    // Mark the originator as sharing (the offer can precede screen_state). No
    // auto-focus: watchScreenShare already focused it when the user opted in.
    final sharing = Map.of(state.peerScreenSharing);
    sharing[originPeer] = true;
    state = state.copyWith(peerScreenSharing: sharing);

    final iceConfig =
        viaForwarder ? _forwarderLegIceConfig() : ref.read(iceConfigProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    // Drop the old cryptors too, so the new PC's receivers re-enable cleanly.
    final priorIncoming = _incomingScreenShares.remove(originPeer);
    if (priorIncoming != null) {
      await priorIncoming.close();
      await _dropShareCryptors(originPeer);
    }

    final service = ScreenShareService(
      localPeerId: localPeerId,
      iceServers: iceConfig,
      forwarderLeg: viaForwarder,
    );

    service.preferredAudioOutputDeviceId =
        await ref.read(audioOutputDeviceProvider.future);

    if (!viaForwarder) {
      service.onIceCandidate = (candidate) {
        network_api.voiceChannelSendSignal(
          serverId: serverId!,
          channelId: channelId!,
          peerId: delivererPeer,
          signalType: 'screen_ice',
          payload: jsonEncode({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
            'role': 'incoming',
            'origin': ?rawOrigin,
          }),
        );
      };
    }

    service.onRemoteTrackReady = () {
      debugPrint('[HOLLOW-VC] Screen share track ready from $originPeer');
      _watchConnectTimers.remove(originPeer)?.cancel();
      state = state.copyWith(
        focusedScreenSharePeerId:
            state.focusedScreenSharePeerId ?? originPeer,
      );
    };

    if (viaForwarder) {
      // Forwarder died mid-stream: the ladder re-requests the direct path. The
      // forwarder is an availability helper, never authority.
      service.onDisconnected = () {
        if (_incomingScreenShares[originPeer] != service) return;
        _vcLog('[HOLLOW-VC] Forwarder leg for $originPeer disconnected — '
            'walking the fallback ladder');
        _fallbackToDirect(originPeer);
      };
    } else {
      // Fast failover on a dead direct leg (receiver-initiates, the lane's heal
      // doctrine), but only while the originator still advertises the share.
      service.onDisconnected = () {
        if (_incomingScreenShares[originPeer] != service) return;
        _rerequestDirectShare(originPeer);
      };
    }

    _incomingScreenShares[originPeer] = service;
    _incomingShareOrigins[originPeer] = (
      deliverer: delivererPeer,
      kind: (rawOrigin?['kind'] as String?) ?? 'screen',
      stream: (rawOrigin?['stream'] as String?) ?? '',
    );

    final answerSdp = await service.handleOffer(offerSdp);

    // Keyed on the ORIGINATOR, whose sender key encrypted the frames.
    if (service.pc != null && _service?.frameCryptor != null) {
      await _enableSframeOnScreenSharePc(
          service.pc!, _service!.frameCryptor!, originPeer, isSender: false);
    }

    if (!viaForwarder) {
      final earlyKey = 'incoming:$originPeer';
      final early = _earlyScreenIce.remove(earlyKey);
      if (early != null && early.isNotEmpty) {
        debugPrint('[HOLLOW-VC] Flushing ${early.length} early screen ICE for incoming:$originPeer');
        for (final ice in early) {
          await service.handleIceCandidate(
            ice['candidate'] as String,
            ice['sdpMid'] as String?,
            ice['sdpMLineIndex'] as int?,
          );
        }
      }
    }

    return answerSdp;
  }

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

  Future<void> _handleScreenIce(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final candidate = v['candidate'] as String? ?? '';
    final sdpMid = v['sdpMid'] as String?;
    final sdpMLineIndex = v['sdpMLineIndex'] as int?;
    final role = v['role'] as String? ?? '';

    final ScreenShareService? service;
    final String queueKey;
    if (role == 'incoming') {
      // Sharer side: transport-keyed by the viewer the leg goes to.
      service = _outgoingScreenShares[peerId];
      queueKey = 'outgoing:$peerId';
    } else {
      // Viewer side: keyed by the stream's ORIGINATOR.
      final originPeer = _origOf(peerId, v);
      service = _incomingScreenShares[originPeer];
      queueKey = 'incoming:$originPeer';
    }
    if (service != null) {
      await service.handleIceCandidate(candidate, sdpMid, sdpMLineIndex);
    } else {
      _earlyScreenIce.putIfAbsent(queueKey, () => []).add({
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      });
    }
  }

  void _handleScreenState(String peerId, String payload) {
    final v = jsonDecode(payload);
    final enabled = v['enabled'] as bool? ?? false;
    final quality = v['quality'] as String?;

    debugPrint('[HOLLOW-VC] Screen state from $peerId: enabled=$enabled quality=$quality');

    final sharing = Map.of(state.peerScreenSharing);
    final labels = Map.of(state.peerScreenShareLabels);
    // Only on a real edge: a catch-up screen_state re-announces a live share.
    final wasSharing = sharing[peerId] ?? false;
    if (enabled != wasSharing && !state.isDeafened) {
      SoundService.instance.play(
        enabled ? HollowSound.joinStream : HollowSound.leaveStream,
        duringCall: true,
      );
    }
    if (enabled) {
      // Badge only — opt-in watching (issue #38) means a new share must
      // never steal focus or flip the view; the user presses Watch.
      sharing[peerId] = true;
      if (quality != null) labels[peerId] = quality;
    } else {
      sharing.remove(peerId);
      labels.remove(peerId);
      _watchConnectTimers.remove(peerId)?.cancel();
      final watching = state.watchingScreenShares.contains(peerId)
          ? ({...state.watchingScreenShares}..remove(peerId))
          : state.watchingScreenShares;
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

  /// Sharer side of opt-in watching (issue #38): a peer asked to start or stop.
  Future<void> _handleScreenWatch(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final want = v['want'] as bool? ?? false;
    final viewerW = (v['viewer_width'] as num?)?.toInt() ?? 0;
    final viewerH = (v['viewer_height'] as num?)?.toInt() ?? 0;
    final route = v['route'] as String? ?? '';
    final fwdCapable = v['fwd_capable'] as bool? ?? false;
    final relayPrivate = v['relay_private'] as bool? ?? false;
    final fwdSimulcast = v['fwd_simulcast'] as bool? ?? false;
    final fwdFeed = v['fwd_feed'] as bool? ?? false;
    debugPrint('[HOLLOW-VC] Screen watch from $peerId: want=$want '
        'viewer=${viewerW}x$viewerH route=$route '
        'fwd_capable=$fwdCapable relay_private=$relayPrivate '
        'fwd_simulcast=$fwdSimulcast fwd_feed=$fwdFeed');

    if (want) {
      // Raced our stop; the peer's badge clears via screen_state{disabled}.
      if (!state.isScreenSharing || _screenCaptureStream == null) return;
      _watchers.add(peerId);
      _watcherDisplays[peerId] =
          (w: viewerW, h: viewerH);
      _watcherRoutes[peerId] = (
        route: route,
        fwdCapable: fwdCapable,
        relayPrivate: relayPrivate,
        fwdSimulcast: fwdSimulcast,
        fwdFeed: fwdFeed,
      );

      // A relay-routed step-3-capable viewer (non-empty route; old viewers must
      // never receive vc_screen_assign) is served THROUGH a forwarder: one
      // ingest copy, no per-viewer PC, no 15-cap slot.
      if (route == 'relay' || route == 'direct_failed') {
        // A branch HEAD reporting direct_failed is our own promoted forwarder
        // whose display failed: DEMOTE the branch, never re-ladder the head.
        if (route == 'direct_failed') {
          final headed = _fwdBranches[peerId];
          if (headed != null) {
            _vcLog('[HOLLOW-VC] Forwarder $peerId reported direct_failed — '
                'demoting its branch');
            await _revertBranchViewersToDirect(headed);
          }
        }
        final current = _branchOf(peerId);
        if (route == 'direct_failed' && current != null) {
          (_viewerFwdFailures[peerId] ??= <String>{})
              .add(current.forwarderId);
          await _removeViewerFromBranch(current, peerId);
        }
        if (route == 'relay') {
          // Re-sent watch (cap / Source change): the ingest is encoded at
          // max(effectiveViewerCap) over the branch audience. The
          // `_fwdBranches[peerId]` lookup is load-bearing: a branch HEAD is not
          // in its own `viewers` set, and without it a head's re-watch falls
          // through to a DIRECT offer that collides with the branch ingest's
          // sender cryptor on `screen:<head>` - black screen, then a heal storm.
          final branch = _fwdBranches[peerId] ?? current;
          if (branch != null) {
            await _reofferIngest(branch);
            return;
          }
        }
        final target = _pickForwarderFor(peerId);
        if (target != null) {
          await _assignViewerToForwarder(peerId, target);
          return;
        }
      }
      // A SPREAD direct viewer re-watching stays on its branch: refresh the
      // register's layer set and the ingest cap instead of bouncing it (a blink).
      if (route == 'direct') {
        final riding = _branchOf(peerId);
        if (riding != null &&
            _outgoingScreenShares.length >= maxDirectShareCopies) {
          await _reofferIngest(riding);
          return;
        }
      }
      // Viewer moved OFF the forwarder path (direct / exhausted ladder).
      final stale = _branchOf(peerId);
      if (stale != null) {
        await _removeViewerFromBranch(stale, peerId);
      }
      // Opportunistic rebalancer: relay-routed viewers that watched before any
      // direct fwd-capable watcher existed stayed on the VPS rung forever,
      // costing 2 uploads where a promotion costs 1. The promotion self-assign
      // also serves THIS watcher, so the direct path below must not run.
      if (await _maybeRebalanceOntoCandidate(peerId)) return;
      final existing = _outgoingScreenShares[peerId];
      if (existing != null) {
        // A re-sent watch is a cap change: try live setParameters first, and
        // renegotiate when the sender rejects it (brief stream restart).
        final (effW, effH) = _effectiveCapFor(peerId);
        final ok = await existing.updateResolutionCap(effW, effH);
        if (!ok) {
          debugPrint('[HOLLOW-VC] Live cap change rejected for $peerId — '
              're-offering share at ${effW}x$effH');
          await _sendScreenShareToPeer(peerId);
        }
        return;
      }
      // Upload spreading: a step-3-capable DIRECT viewer past the direct-copy
      // budget is served through a branch, which is what turns "one PC per
      // viewer" into "1-2 copies total" and makes the 15-cap dynamic.
      if (route == 'direct' &&
          _outgoingScreenShares.length >= maxDirectShareCopies) {
        final target = _pickSpreadTargetFor(peerId);
        if (target != null) {
          _vcLog('[HOLLOW-VC] Upload spreading: direct viewer $peerId → '
              '${target == peerId ? 'own branch (self-promotion)' : target} '
              '(${_outgoingScreenShares.length} direct cop'
              '${_outgoingScreenShares.length == 1 ? 'y' : 'ies'} running)');
          await _assignViewerToForwarder(peerId, target);
          return;
        }
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
      _watcherRoutes.remove(peerId);
      final branch = _branchOf(peerId);
      if (branch != null) {
        await _removeViewerFromBranch(branch, peerId);
      }
      // A peer FORWARDER that stopped watching can't keep serving: no watch, no
      // consent. Its viewers revert to direct and re-ladder.
      final headed = _fwdBranches[peerId];
      if (headed != null) {
        _vcLog('[HOLLOW-VC] Peer forwarder $peerId stopped watching — '
            'reverting its branch');
        await _revertBranchViewersToDirect(headed);
      }
      final outgoing = _outgoingScreenShares.remove(peerId);
      if (outgoing != null) {
        await outgoing.close();
        await _dropShareCryptors(peerId);
        debugPrint('[HOLLOW-VC] Stopped sending share to $peerId (viewer opted out)');
      }
    }
  }

  /// The resolution cap for [peerId]'s outgoing share PC: the share quality
  /// clamped to that viewer's reported display, unless they asked for source.
  ///
  /// [honorSource] false sizes by the DISPLAY alone. Used for SHARED ingest
  /// legs: a Source request is a favour to one consenting viewer and may never
  /// inflate a stream everyone else on that branch has to receive.
  (int, int) _effectiveCapFor(String peerId) {
    final d = _watcherDisplays[peerId];
    return ScreenShareService.effectiveViewerCap(
      _screenShareMaxWidth,
      _screenShareMaxHeight,
      d?.w ?? 0,
      d?.h ?? 0,
    );
  }

  /// ICE config for forwarder legs (ingest + egress attach): NO ice servers,
  /// host candidates only.
  ///
  /// DELIBERATELY not [iceConfigProvider]: "Always relay calls" forces a relay
  /// policy there and a forced-TURN leg would blackhole it - the forwarder IS
  /// the relay replacement. Not [shareIceConfigProvider] either (file lane).
  ///
  /// CRITICAL - the list must stay EMPTY. Configuring STUN servers BREAKS the
  /// leg: libwebrtc withholds its host candidates while it waits on them, so a
  /// host with IPv6-first DNS and no routable IPv6 path produced ZERO candidates.
  Map<String, dynamic> _forwarderLegIceConfig() => const {'iceServers': []};

  /// The viewer's `route` hint for screen_watch: one immediate stats pass.
  /// ADVISORY - a wrong hint is corrected by the ladder; "" keeps direct.
  Future<String> _routeHintTo(String peerId) async {
    // Already served through the forwarder: a re-watch (Source toggle) must not
    // bounce us to direct mid-stream. _fallbackToDirect bypasses this.
    if (_screenAssignments.containsKey(peerId)) return 'relay';
    // Lab escape hatch: report "relay" WITHOUT the Always-relay privacy
    // semantics, which a LAN rig cannot otherwise simulate. Unset = inert.
    if (Platform.environment['HOLLOW_FORCE_RELAY_ROUTE'] == '1') {
      _vcLog('[HOLLOW-VC] route hint forced to relay (HOLLOW_FORCE_RELAY_ROUTE)');
      return 'relay';
    }
    // Forced-relay users are relay-routed by policy — no probe needed.
    if (ref.read(alwaysRelayCallsProvider)) return 'relay';
    try {
      final pc = _service?.pcFor(peerId);
      if (pc != null) {
        final route = await probeIceRouteOnce(pc);
        if (route != null) return route.isDirect ? 'direct' : 'relay';
      }
    } catch (_) {}
    return '';
  }

  /// The branch currently serving [viewerPeer], if any.
  _FwdBranch? _branchOf(String viewerPeer) {
    for (final b in _fwdBranches.values) {
      if (b.viewers.contains(viewerPeer)) return b;
    }
    return null;
  }

  /// Static selection for a relay-routed [viewer]: an existing peer branch with
  /// capacity, a promotable candidate, the VPS forwarder, or null (direct+TURN).
  /// Forwarders that already failed for this viewer are skipped, and after two
  /// failed rungs the viewer always goes direct.
  String? _pickForwarderFor(String viewer) {
    // No chains: a branch HEAD never rides ANOTHER forwarder.
    if (_fwdBranches.containsKey(viewer)) return null;
    final failed = _viewerFwdFailures[viewer] ?? const <String>{};
    if (failed.length >= 2) return null;
    // Privacy: a relay_private viewer (Always relay calls) must only touch
    // operator infrastructure — skip the peer rungs entirely.
    final privacyBound = _watcherRoutes[viewer]?.relayPrivate ?? false;
    if (!privacyBound) {
      // Fill existing peer branches before promoting new forwarders.
      for (final b in _fwdBranches.values) {
        if (!b.isPeer) continue;
        if (b.forwarderId == viewer || failed.contains(b.forwarderId)) {
          continue;
        }
        if (b.usedLegs >= maxPeerForwarderLegs) continue;
        return b.forwarderId;
      }
      for (final entry in _watcherRoutes.entries) {
        final cand = entry.key;
        if (cand == viewer || failed.contains(cand)) continue;
        if (!entry.value.fwdCapable || entry.value.route != 'direct') continue;
        if (!_watchers.contains(cand)) continue;
        if (_fwdBranches.containsKey(cand)) continue;
        return cand;
      }
    }
    // The VPS infra forwarder is the reliability floor (and the ONLY
    // forwarder rung for privacy-bound viewers — same trust as TURN).
    final fwd = ref.read(forwarderInfoProvider);
    if (fwd.usable && !failed.contains(fwd.peerId)) return fwd.peerId;
    return null;
  }

  /// Upload spreading: pick a branch for a DIRECT viewer past the direct-copy
  /// budget. Differs from [_pickForwarderFor] in two deliberate ways:
  /// - Promotion prefers a watcher that already HOLDS a direct copy (it closes
  ///   on promotion), then the viewer ITSELF, then any other capable watcher.
  /// - The VPS rung only applies to a branch ALREADY serving. A fresh VPS
  ///   branch would trade zero relay bytes for `B + B.k` and save nothing.
  String? _pickSpreadTargetFor(String viewer) {
    final failed = _viewerFwdFailures[viewer] ?? const <String>{};
    if (failed.length >= 2) return null;
    final privacyBound = _watcherRoutes[viewer]?.relayPrivate ?? false;
    if (!privacyBound) {
      for (final b in _fwdBranches.values) {
        if (!b.isPeer) continue;
        if (b.forwarderId == viewer || failed.contains(b.forwarderId)) {
          continue;
        }
        if (b.usedLegs >= maxPeerForwarderLegs) continue;
        return b.forwarderId;
      }
      bool promotable(String cand) {
        final r = _watcherRoutes[cand];
        return r != null &&
            r.fwdCapable &&
            r.route == 'direct' &&
            _watchers.contains(cand) &&
            !_fwdBranches.containsKey(cand) &&
            _branchOf(cand) == null &&
            !failed.contains(cand);
      }

      for (final cand in _outgoingScreenShares.keys) {
        if (cand != viewer && promotable(cand)) return cand;
      }
      if (promotable(viewer)) return viewer;
      for (final cand in _watcherRoutes.keys) {
        if (cand != viewer && promotable(cand)) return cand;
      }
    }
    final fwd = ref.read(forwarderInfoProvider);
    if (fwd.usable && !failed.contains(fwd.peerId)) {
      final vps = _fwdBranches[fwd.peerId];
      if (vps != null && !vps.isPeer && vps.ingest != null) return fwd.peerId;
    }
    return null;
  }

  /// Opportunistic rebalancer: [candidate] just watched direct + `fwd_capable`
  /// while the VPS branch is serving, so promote it and migrate those viewers
  /// (relay media to 0, sharer upload 2 copies to 1), one blink each. Honors the
  /// same invariants as the pick: relay_private viewers never leave operator
  /// infrastructure, failed-forwarder memory is respected, the branch caps.
  Future<bool> _maybeRebalanceOntoCandidate(String candidate) async {
    if (!state.isScreenSharing || _screenCaptureStream == null) return false;
    final r = _watcherRoutes[candidate];
    if (r == null || !r.fwdCapable || r.route != 'direct' || r.relayPrivate) {
      return false;
    }
    if (!_watchers.contains(candidate)) return false;
    // No chains: an existing head or branch rider is not a promotion target.
    if (_fwdBranches.containsKey(candidate)) return false;
    if (_branchOf(candidate) != null) return false;
    final vpsId = ref.read(forwarderInfoProvider).peerId;
    if (vpsId.isEmpty || vpsId == candidate) return false;
    final vps = _fwdBranches[vpsId];
    if (vps == null || vps.isPeer || vps.viewers.isEmpty) return false;
    final migrate = vps.viewers
        .where((viewer) =>
            _watchers.contains(viewer) &&
            !(_watcherRoutes[viewer]?.relayPrivate ?? false) &&
            !(_viewerFwdFailures[viewer]?.contains(candidate) ?? false))
        .take(maxPeerForwarderLegs)
        .toList();
    if (migrate.isEmpty) return false;
    _vcLog('[HOLLOW-VC] Opportunistic rebalance: promoting $candidate — '
        'migrating ${migrate.length}/${vps.viewers.length} viewer(s) off the '
        'VPS branch');
    for (final viewer in migrate) {
      // MAKE-BEFORE-BREAK: assign to the peer branch and remove the viewer from
      // the VPS branch LOCALLY only. An eager `fwd_stream_auth` removal lets the
      // VPS kill the old egress before the assign lands, which reads as branch
      // failure and permanently marks the fresh candidate failed for that viewer.
      await _assignViewerToForwarder(viewer, candidate);
      vps.viewers.remove(viewer);
    }
    if (vps.viewers.isEmpty) {
      vps.linger?.cancel();
      vps.linger = Timer(const Duration(seconds: 30), () {
        vps.linger = null;
        if (vps.viewers.isEmpty) {
          _teardownBranch(vps, unregister: true, demote: true);
        }
      });
    }
    return true;
  }

  /// FEEDER ELECTION: a mixed-branch case costs TWO upload copies, one ingest
  /// per forwarder. A peer branch head already receives the stream, so it can
  /// re-emit that copy into the VPS ingest and we drop to ONE.
  ///
  /// The delegation is owner-authored end to end (our register names the
  /// feeder, our allowlist admits it, the assign is originator-authenticated)
  /// and is SUPPLY ONLY: a feeder can never change the allowlist or unregister.
  ///
  /// Skipped while any `relay_private` viewer rides the VPS branch: their
  /// ciphertext would TRANSIT a member's machine, and the promise covers transit.
  Future<void> _maybeElectFeeder() async {
    if (!state.isScreenSharing || _screenCaptureStream == null) return;
    final vpsId = ref.read(forwarderInfoProvider).peerId;
    if (vpsId.isEmpty) return;
    final vps = _fwdBranches[vpsId];
    if (vps == null || vps.isPeer || vps.viewers.isEmpty) return;
    if (_feederFor(vps).isNotEmpty) return;
    // Privacy: a forced-relay viewer's media must not transit a member.
    if (vps.viewers
        .any((v) => _watcherRoutes[v]?.relayPrivate ?? false)) {
      return;
    }
    _FwdBranch? head;
    for (final b in _fwdBranches.values) {
      if (!b.isPeer || b.feedTarget.isNotEmpty) continue;
      if (b.ingest == null) continue; // its own ingest must be live first
      if (!(_watcherRoutes[b.forwarderId]?.fwdFeed ?? false)) continue;
      if (_feedFailures.contains(b.forwarderId)) continue;
      if (b.usedLegs >= maxPeerForwarderLegs) continue;
      head = b;
      break;
    }
    if (head == null) return;

    _vcLog('[HOLLOW-VC] Feeder election: delegating ${head.forwarderId} to '
        'feed the VPS forwarder (2 upload copies → 1)');
    head.feedTarget = vpsId;
    head.feedUp = false;
    // BOTH registers must land before the head starts feeding: the VPS needs
    // the `feeder` delegation or it refuses the ingest, and the HEAD needs the
    // VPS on its allowlist because `admit_attach` gates purely on that.
    await _registerStreamAtForwarder(vps);
    await _registerStreamAtForwarder(head);
    await _sendFeedAssign(head.forwarderId, vpsId);

    // Never leave a half-elected branch: without the feed we keep supplying the
    // VPS ourselves and remember the failure so we don't retry it all session.
    head.feedTimeout?.cancel();
    final headId = head.forwarderId;
    head.feedTimeout = Timer(const Duration(seconds: 10), () {
      final b = _fwdBranches[headId];
      if (b == null || b.feedUp) return;
      _vcLog('[HOLLOW-VC] Feeder $headId never reported up — reverting to our '
          'own VPS ingest');
      _feedFailures.add(headId);
      unawaited(_revokeFeed(b));
    });
  }

  /// Heads that failed to feed this share session — never re-elected (the
  /// far forwarder may be an older binary that ignores `feeder` entirely).
  final Set<String> _feedFailures = {};

  /// Tell a branch head to start (or stop) feeding [target].
  Future<void> _sendFeedAssign(String headId, String target) async {
    if (!state.isInVoiceChannel) return;
    final origin = _myShareOrigin();
    if (origin == null) return;
    await network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: headId,
          signalType: 'screen_assign',
          payload: jsonEncode({
            'origin': origin,
            // The head stays assigned to ITSELF; this assign only carries the feed.
            'forwarder': headId,
            'feed_target': target,
          }),
        )
        .catchError((_) {});
  }

  /// Undo a delegation: clear it locally, re-register without `feeder`, tell the
  /// head to stop, and make sure OUR own ingest to that forwarder is back up.
  Future<void> _revokeFeed(_FwdBranch head) async {
    final target = head.feedTarget;
    if (target.isEmpty) return;
    head.feedTimeout?.cancel();
    head.feedTimeout = null;
    head.feedTarget = '';
    head.feedUp = false;
    await _sendFeedAssign(head.forwarderId, '');
    await _registerStreamAtForwarder(head);
    // Our own ingest may have been closed at handover.
    final fed = _fwdBranches[target];
    if (fed != null) {
      await _registerStreamAtForwarder(fed);
      await _ensureIngestLeg(fed);
    }
  }

  /// A delegated feeder reported its leg into [forwarderId] up or down.
  /// UP is what allows us to stop supplying that forwarder ourselves.
  Future<void> _handleFeedState(
      String headId, String forwarderId, bool up) async {
    final head = _fwdBranches[headId];
    if (head == null || head.feedTarget != forwarderId) return;
    if (!up) {
      _vcLog('[HOLLOW-VC] Feeder $headId reported its leg DOWN — resuming our '
          'own ingest to $forwarderId');
      _feedFailures.add(headId);
      await _revokeFeed(head);
      return;
    }
    if (head.feedUp) return;
    head.feedUp = true;
    head.feedTimeout?.cancel();
    head.feedTimeout = null;
    final fed = _fwdBranches[forwarderId];
    if (fed == null) return;
    // MAKE-BEFORE-BREAK: our ingest stayed up until the feeder's copy was
    // admitted, so the audience sees one keyframe, not a gap.
    final ours = fed.ingest;
    if (ours != null) {
      _vcLog('[HOLLOW-VC] Feed to $forwarderId is up — closing our own ingest '
          'there (sharer down to one upload copy)');
      fed.ingest = null;
      await ours.close();
      await _dropShareCryptors(forwarderId);
    }
  }

  /// Sharer side: serve [viewerPeer] through [forwarderPeerId] instead of a
  /// per-viewer PC. For a PEER forwarder, promotion also self-assigns it and
  /// closes our direct PC to it - ONE upload copy for the whole branch.
  Future<void> _assignViewerToForwarder(
      String viewerPeer, String forwarderPeerId) async {
    final origin = _myShareOrigin();
    if (origin == null) return;
    // Self-promotion: the viewer IS the branch, so it never goes into `viewers`
    // (that set is REMOTE legs) and gets its only assign below.
    final selfPromotion = viewerPeer == forwarderPeerId;
    var branch = _fwdBranches[forwarderPeerId];
    final isNewPeerBranch =
        branch == null && _watchers.contains(forwarderPeerId);
    if (branch == null) {
      branch = _FwdBranch(forwarderPeerId,
          isPeer: _watchers.contains(forwarderPeerId));
      // Decide simulcast AT CREATION so the first register already carries the
      // low_viewers set: the viewer's attach races the second register.
      branch.simulcast = !branch.isPeer ||
          (_watcherRoutes[forwarderPeerId]?.fwdSimulcast ?? false);
      _fwdBranches[forwarderPeerId] = branch;
      await network_api
          .joinForwarderRoom(forwarderPeerId: forwarderPeerId)
          .catchError((_) {});
      if (branch.isPeer) {
        _vcLog('[HOLLOW-VC] Promoted $forwarderPeerId to peer forwarder'
            '${branch.simulcast ? ' (simulcast)' : ''}');
      }
    }
    branch.linger?.cancel();
    branch.linger = null;
    if (!selfPromotion) {
      branch.viewers.add(viewerPeer);
    }
    // Register BEFORE any assignment leaves: both ride the SAME relay socket in
    // order, so the engine provably knows the stream before a promoted
    // forwarder's instant local self-attach can race it (unknown_stream).
    await _registerStreamAtForwarder(branch);
    await _ensureIngestLeg(branch);
    if (isNewPeerBranch) {
      // Self-assignment switches the forwarder's display onto its own engine,
      // so the close below lands on an already-superseded leg.
      if (state.isInVoiceChannel) {
        network_api
            .voiceChannelSendSignal(
              serverId: state.currentServerId!,
              channelId: state.currentChannelId!,
              peerId: forwarderPeerId,
              signalType: 'screen_assign',
              payload: jsonEncode(
                  {'origin': origin, 'forwarder': forwarderPeerId}),
            )
            .catchError((_) {});
      }
      final direct = _outgoingScreenShares.remove(forwarderPeerId);
      if (direct != null) {
        await direct.close();
        await _dropShareCryptors(forwarderPeerId);
        // CRYPTOR COLLISION: the ingest leg's sender cryptor is keyed
        // 'screen:<forwarderId>', the SAME (participant, kind) as the direct PC
        // just closed. enableForSender is idempotent per key, so re-enable NOW,
        // after the drop, or the branch carries PLAINTEXT until the next epoch.
        final ingestPc = branch.ingest?.pc;
        final fc = _service?.frameCryptor;
        if (ingestPc != null && fc != null) {
          await _enableSframeOnScreenSharePc(ingestPc, fc, forwarderPeerId,
              isSender: true);
        }
      }
    }
    if (selfPromotion) {
      // A second assign would make the viewer tear down and re-attach its leg.
      _vcLog('[HOLLOW-VC] Self-promoted $forwarderPeerId — its display '
          'rides its own branch (0 remote viewer(s) yet)');
      return;
    }
    if (!state.isInVoiceChannel) return;
    network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: viewerPeer,
          signalType: 'screen_assign',
          payload: jsonEncode({'origin': origin, 'forwarder': forwarderPeerId}),
        )
        .catchError((_) {});
    _vcLog('[HOLLOW-VC] Viewer $viewerPeer assigned to '
        '${branch.isPeer ? "peer" : "infra"} forwarder '
        '(${branch.viewers.length} viewer(s) on that branch)');
    // A mixed-branch case is exactly when a feeder takes 2 upload copies to 1.
    unawaited(_maybeElectFeeder());
  }

  /// A branch's ingest cap: max(effectiveViewerCap) over ITS audience, remote
  /// viewers plus a peer branch's own display.
  ///
  /// Sized by DISPLAYS ONLY (`honorSource: false`): a branch ingest is SHARED,
  /// so honouring one viewer's Source request would inflate it on every other
  /// branch viewer's bandwidth. Source stays honoured on direct per-viewer PCs.
  (int, int) _ingestCap(_FwdBranch branch) {
    var w = 0, h = 0;
    final audience = <String>{
      ...branch.viewers,
      if (branch.isPeer) branch.forwarderId,
    };
    for (final viewer in audience) {
      final (vw, vh) = _effectiveCapFor(viewer);
      if (vw * vh >= w * h) {
        w = vw;
        h = vh;
      }
    }
    if (w == 0 || h == 0) return (_screenShareMaxWidth, _screenShareMaxHeight);
    return (w, h);
  }

  /// (Re-)register our stream + current allowlist at the branch's forwarder.
  /// Idempotent by contract, so every path about to offer an ingest calls it
  /// first: an ingest offer for a stream the forwarder doesn't know is refused
  /// with `unknown_stream`, and a registration can legitimately be missing.
  ///
  /// With a simulcast ingest the register also names the viewers to serve the
  /// LOW layer (rid q); layer choice applies at attach time.
  Future<void> _registerStreamAtForwarder(_FwdBranch branch) async {
    final origin = _myShareOrigin();
    if (origin == null) return;
    final audience = [
      ...branch.viewers,
      if (branch.isPeer) branch.forwarderId,
      // Direction matters: a feed leg is an EGRESS leg on the FEEDER's engine
      // whose "viewer" is the forwarder being fed, so the FED forwarder must be
      // allowlisted HERE - `admit_attach` knows nothing about feeds.
      if (branch.feedTarget.isNotEmpty) branch.feedTarget,
    ];
    await network_api
        .forwarderSendSignal(
          forwarderPeerId: branch.forwarderId,
          signalType: 'fwd_stream_register',
          payload: jsonEncode({
            'origin': origin,
            'allowed_viewers': audience,
            if (branch.simulcast)
              'low_viewers':
                  audience.where((v) => _wantsLowLayer(branch, v)).toList(),
            // Only this owner-authored register can set it: the security anchor.
            if (_feederFor(branch).isNotEmpty) 'feeder': _feederFor(branch),
          }),
        )
        .catchError((_) {});
  }

  /// The peer branch head elected to feed [branch]'s forwarder, if any (stored
  /// on the FEEDING branch as `feedTarget`; this reads it from the fed side).
  String _feederFor(_FwdBranch branch) {
    for (final b in _fwdBranches.values) {
      if (b.isPeer && b.feedTarget == branch.forwarderId) return b.forwarderId;
    }
    return '';
  }

  /// Layer choice for one branch viewer: ride the LOW layer when it already
  /// covers their display. Source-quality viewers always ride the full layer.
  bool _wantsLowLayer(_FwdBranch branch, String viewerPeer) {
    final (fw, fh) = _ingestCap(branch);
    final (vw, vh) = _effectiveCapFor(viewerPeer);
    return ScreenShareService.viewerWantsLowLayer(fw, fh, vw, vh);
  }

  /// Create a branch's single ingest leg (no-op if live).
  Future<void> _ensureIngestLeg(_FwdBranch branch) async {
    if (branch.ingest != null) return;
    if (_screenCaptureStream == null) return;
    final origin = _myShareOrigin();
    if (origin == null) return;
    // Offer a 2-layer simulcast ingest only when the far engine can select
    // layers (the VPS always can; a peer forwarder only if its watch said so),
    // or an old engine would fan both layers interleaved = garbage.
    branch.simulcast = !branch.isPeer ||
        (_watcherRoutes[branch.forwarderId]?.fwdSimulcast ?? false);
    // Never offer an ingest for a stream the forwarder might not hold.
    await _registerStreamAtForwarder(branch);
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final service = ScreenShareService(
      localPeerId: localPeerId,
      iceServers: _forwarderLegIceConfig(),
      forwarderLeg: true,
    );
    branch.ingest = service;
    // Forwarder dropped the ingest: revert this branch's audience to direct.
    service.onDisconnected = () {
      if (branch.ingest != service) return;
      _vcLog('[HOLLOW-VC] Ingest leg to ${branch.forwarderId} disconnected — '
          'reverting its viewers');
      _revertBranchViewersToDirect(branch);
    };
    try {
      final (capW, capH) = _ingestCap(branch);
      await service.createOfferFromStream(
        _screenCaptureStream!,
        maxWidth: capW,
        maxHeight: capH,
        fps: _screenShareFps,
        profile: _screenShareProfile,
        simulcast: branch.simulcast,
      );
      if (service.pc != null && _service?.frameCryptor != null) {
        await _enableSframeOnScreenSharePc(
            service.pc!, _service!.frameCryptor!, branch.forwarderId,
            isSender: true);
      }
      // Forwarder legs ride COMPLETE SDPs (fwd_ice is reserved, unbuilt).
      final fullSdp = await service.gatheredLocalSdp();
      if (fullSdp == null || fullSdp.isEmpty) {
        throw Exception('ingest SDP gathering produced nothing');
      }
      await network_api.forwarderSendSignal(
        forwarderPeerId: branch.forwarderId,
        signalType: 'fwd_ingest_offer',
        payload: jsonEncode({'origin': origin, 'sdp': fullSdp}),
      );
      _vcLog('[HOLLOW-VC] Ingest leg to ${branch.forwarderId} offered '
          '(${capW}x$capH)');
    } catch (e) {
      _vcLog('[HOLLOW-VC] Ingest leg setup failed: $e');
      branch.ingest = null;
      await service.close();
      await _dropShareCryptors(branch.forwarderId);
    }
  }

  /// Re-offer a branch's ingest at the current cap: live setParameters first,
  /// renegotiate when the sender still rejects it.
  Future<void> _reofferIngest(_FwdBranch branch) async {
    // Attach-time only: live legs keep the layer they were given.
    await _registerStreamAtForwarder(branch);
    final svc = branch.ingest;
    if (svc != null) {
      final (capW, capH) = _ingestCap(branch);
      if (await svc.updateResolutionCap(capW, capH)) return;
      _vcLog('[HOLLOW-VC] Live ingest cap change rejected — re-offering at '
          '${capW}x$capH');
      branch.ingest = null;
      await svc.close();
      await _dropShareCryptors(branch.forwarderId);
    }
    await _ensureIngestLeg(branch);
  }

  /// Remove a viewer from its branch; the LAST one starts the ~30 s linger.
  Future<void> _removeViewerFromBranch(
      _FwdBranch branch, String viewerPeer) async {
    if (!branch.viewers.remove(viewerPeer)) return;
    final origin = _myShareOrigin();
    if (origin == null) return;
    await network_api
        .forwarderSendSignal(
          forwarderPeerId: branch.forwarderId,
          signalType: 'fwd_stream_auth',
          payload: jsonEncode({
            'origin': origin,
            'add': const <String>[],
            'remove': [viewerPeer],
          }),
        )
        .catchError((_) {});
    if (branch.viewers.isEmpty) {
      branch.linger?.cancel();
      branch.linger = Timer(const Duration(seconds: 30), () {
        branch.linger = null;
        if (branch.viewers.isEmpty) {
          _teardownBranch(branch, unregister: true, demote: true);
        }
      });
    }
  }

  /// Tear down one branch: ingest leg + registration (when [unregister]),
  /// fwd-room release, and for an idle PEER branch with [demote] a revert to a
  /// direct per-viewer PC, since without viewers the engine detour buys nothing.
  Future<void> _teardownBranch(
    _FwdBranch branch, {
    required bool unregister,
    required bool demote,
  }) async {
    branch.linger?.cancel();
    branch.linger = null;
    branch.feedTimeout?.cancel();
    branch.feedTimeout = null;
    _fwdBranches.remove(branch.forwarderId);
    // This branch's head was feeding another forwarder: tell it to stop and
    // resume supplying the FED forwarder ourselves.
    if (branch.feedTarget.isNotEmpty) {
      final target = branch.feedTarget;
      final wasUp = branch.feedUp;
      branch.feedTarget = '';
      branch.feedUp = false;
      await _sendFeedAssign(branch.forwarderId, '');
      final fed = _fwdBranches[target];
      if (fed != null && wasUp) {
        _vcLog('[HOLLOW-VC] Feeder ${branch.forwarderId} is going away — '
            'resuming our own ingest to $target');
        await _registerStreamAtForwarder(fed);
        await _ensureIngestLeg(fed);
      } else if (fed != null) {
        await _registerStreamAtForwarder(fed);
      }
    }
    // ...and if THIS branch was being fed, the delegation dies with it.
    final feeder = _feederFor(branch);
    if (feeder.isNotEmpty) {
      final head = _fwdBranches[feeder];
      if (head != null) {
        head.feedTimeout?.cancel();
        head.feedTimeout = null;
        head.feedTarget = '';
        head.feedUp = false;
        await _sendFeedAssign(feeder, '');
        // Hygiene: the entry is authorization, not liveness.
        await _registerStreamAtForwarder(head);
      }
    }
    final svc = branch.ingest;
    branch.ingest = null;
    if (svc != null) {
      await svc.close();
      await _dropShareCryptors(branch.forwarderId);
    }
    final origin = _myShareOrigin();
    if (unregister && origin != null) {
      await network_api
          .forwarderSendSignal(
            forwarderPeerId: branch.forwarderId,
            signalType: 'fwd_stream_unregister',
            payload: jsonEncode({'origin': origin}),
          )
          .catchError((_) {});
    }
    _maybeLeaveFwdRoom(branch.forwarderId);
    if (demote && branch.isPeer && _watchers.contains(branch.forwarderId)) {
      if (state.isInVoiceChannel && origin != null) {
        network_api
            .voiceChannelSendSignal(
              serverId: state.currentServerId!,
              channelId: state.currentChannelId!,
              peerId: branch.forwarderId,
              signalType: 'screen_assign',
              payload: jsonEncode({'origin': origin, 'forwarder': ''}),
            )
            .catchError((_) {});
      }
      if (_audioConnectedPeers.contains(branch.forwarderId) &&
          !_outgoingScreenShares.containsKey(branch.forwarderId) &&
          _outgoingScreenShares.length < maxScreenShareOutgoing) {
        await _sendScreenShareToPeer(branch.forwarderId);
      }
    }
  }

  /// Tear down every branch (share stop / channel leave).
  Future<void> _teardownAllBranches({
    required bool unregister,
    required bool demote,
  }) async {
    for (final branch in List.of(_fwdBranches.values)) {
      await _teardownBranch(branch, unregister: unregister, demote: demote);
    }
  }

  /// Leave a forwarder's relay room once neither side references it. NEVER for
  /// our OWN fwd room - the embedded engine's bridge owns that membership.
  void _maybeLeaveFwdRoom(String? forwarderPeerId) {
    if (forwarderPeerId == null || forwarderPeerId.isEmpty) return;
    if (forwarderPeerId == _myDevicePeerId) return;
    if (_fwdBranches.containsKey(forwarderPeerId)) return;
    if (_screenAssignments.values.any((a) => a.forwarder == forwarderPeerId)) {
      return;
    }
    network_api
        .leaveForwarderRoom(forwarderPeerId: forwarderPeerId)
        .catchError((_) {});
  }

  /// Feeder side: which forwarder we currently feed for an originator (empty = none).
  final Map<String, String> _feedingFor = {};

  /// Handle the `feed_target` on an incoming assign. Returns true when this
  /// assign CHANGED our delegation, so the caller leaves its routing alone.
  bool _handleFeedDelegation(
      String originPeer, dynamic origin, String feedTarget) {
    final current = _feedingFor[originPeer] ?? '';
    if (feedTarget == current) return false;
    // A forced-relay user never serves anyone, in any role.
    if (feedTarget.isNotEmpty && ref.read(alwaysRelayCallsProvider)) {
      _vcLog('[HOLLOW-VC] Refusing feeder delegation — Always relay calls is on');
      return false;
    }
    if (feedTarget.isNotEmpty && !_canForwardShares()) return false;
    final kind = origin is Map ? (origin['kind'] as String? ?? 'screen') : 'screen';
    final stream = origin is Map ? (origin['stream'] as String? ?? '') : '';
    if (current.isNotEmpty) {
      _vcLog('[HOLLOW-VC] Stopping feed of $current for $originPeer');
      network_api
          .setForwarderFeed(
            originPeer: originPeer,
            kind: kind,
            stream: stream,
            targetForwarder: current,
            active: false,
          )
          .catchError((_) {});
      _feedingFor.remove(originPeer);
    }
    if (feedTarget.isEmpty) {
      // A revoke: we cleared the old delegation above, which IS a change.
      return true;
    }
    _vcLog('[HOLLOW-VC] Elected as FEEDER for $originPeer → $feedTarget '
        '(re-emitting our copy into its ingest)');
    _feedingFor[originPeer] = feedTarget;
    network_api
        .setForwarderFeed(
          originPeer: originPeer,
          kind: kind,
          stream: stream,
          targetForwarder: feedTarget,
          active: true,
        )
        .catchError((_) {});
    return true;
  }

  /// Tell the stream's owner whether our feed leg is up. `up:false` makes the
  /// owner resume supplying that forwarder; handover completes on `up:true`.
  void _sendFeedState(String originPeer, String forwarderId, bool up) {
    if (!state.isInVoiceChannel) return;
    final assignment = _screenAssignments[originPeer];
    network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: originPeer,
          signalType: 'screen_feed_state',
          payload: jsonEncode({
            'origin': {
              'peer': originPeer,
              'kind': assignment?.kind ?? 'screen',
              'stream': assignment?.stream ?? '',
            },
            'forwarder': forwarderId,
            'up': up,
          }),
        )
        .catchError((_) {});
  }

  /// Viewer side of `vc_screen_assign`: the sharer routed us to a forwarder.
  /// Join its room and attach; the egress offer arrives as a ForwarderSignal.
  ///
  /// Trust model: the assignment is authenticated as coming from the STREAM'S
  /// ORIGINATOR (Rust's `inbound_origin_ok`) and only honored for a share we
  /// explicitly watch, so the sharer may name ANY forwarder for its own stream.
  Future<void> _handleScreenAssign(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final origin = v['origin'];
    final originPeer = origin is Map ? (origin['peer'] as String? ?? '') : '';
    final forwarder = v['forwarder'] as String? ?? '';
    final feedTarget = v['feed_target'] as String? ?? '';
    // Rust already dropped spoofed origins (origin must name the SENDER);
    // consent still gates here — only honored for a share we're watching.
    if (originPeer.isEmpty || !state.watchingScreenShares.contains(originPeer)) {
      return;
    }

    // FEEDER ELECTION, feeder side: the stream's OWNER delegated us to re-emit
    // our copy into another forwarder's ingest. Honoured only for a stream we
    // actually forward, and never under Always-relay.
    final feedChanged = _handleFeedDelegation(originPeer, origin, feedTarget);
    // A delegation-carrying assign leaves our OWN routing untouched: returning
    // here stops a feed set/revoke retiring and re-attaching a good display leg
    // (one needless blink, and worse during a revoke).
    if (feedChanged &&
        forwarder == (_screenAssignments[originPeer]?.forwarder ?? '')) {
      return;
    }
    if (forwarder.isEmpty) {
      // Revert-to-direct: forget the assignment; the direct offer follows.
      final prev = _screenAssignments.remove(originPeer);
      _maybeLeaveFwdRoom(prev?.forwarder);
      // The promised direct offer can be withheld (the sharer gates on a warm
      // audio PC), so re-arm the timeout instead of stranding the tile.
      _armWatchNoShowTimer(originPeer);
      return;
    }
    // Privacy hard gate: with "Always relay calls" on, a PEER forwarder leg
    // would expose our address to another member. Only the operator-run infra
    // forwarder is acceptable; this catches a buggy or malicious sharer.
    if (ref.read(alwaysRelayCallsProvider)) {
      final advertised = ref.read(forwarderInfoProvider).peerId;
      if (advertised.isEmpty || forwarder != advertised) {
        _vcLog('[HOLLOW-VC] screen_assign names a peer forwarder while '
            'Always-relay is on — refusing, walking the ladder');
        _fallbackToDirect(originPeer);
        return;
      }
    }
    _myDevicePeerId ??= await network_api.getLocalDevicePeerId();
    final isSelf = forwarder == _myDevicePeerId;
    _selfAttachRetried.remove(originPeer);
    final prevAssignment = _screenAssignments[originPeer];
    _screenAssignments[originPeer] = (
      forwarder: forwarder,
      kind: origin is Map ? (origin['kind'] as String? ?? 'screen') : 'screen',
      stream: origin is Map ? (origin['stream'] as String? ?? '') : '',
    );
    // Promotion replaces our existing direct leg: retire it OURSELVES, map-first
    // so its onDisconnected guard no-ops when the sharer's side closes.
    final prevService = _incomingScreenShares.remove(originPeer);
    if (prevService != null) {
      await prevService.close();
      await _dropShareCryptors(originPeer);
    }
    if (!isSelf) {
      // Our OWN fwd room is joined by the embedded engine's bridge.
      await network_api
          .joinForwarderRoom(forwarderPeerId: forwarder)
          .catchError((_) {});
    }
    await network_api
        .forwarderSendSignal(
          forwarderPeerId: forwarder,
          signalType: 'fwd_attach',
          payload: jsonEncode({'origin': origin}),
        )
        .catchError((_) {});
    // Forwarder-to-forwarder reassignment: release the OLD forwarder's room once
    // nothing references it - a lingering membership blackholes targeted signals.
    if (prevAssignment != null && prevAssignment.forwarder != forwarder) {
      _maybeLeaveFwdRoom(prevAssignment.forwarder);
    }
    // The attach can die silently and our old delivery leg is already retired:
    // arm the no-show timer so dead air walks the ladder.
    _armWatchNoShowTimer(originPeer);
    _vcLog('[HOLLOW-VC] Assigned to ${isSelf ? "OUR OWN engine" : "forwarder"} '
        'for $originPeer — attaching');
  }

  /// Arm (or re-arm) the 20 s "nothing rendered" watchdog for a share we watch:
  /// a promised delivery can silently never arrive after our previous leg was
  /// retired. No-op when a renderer is already live; the fired timer re-checks.
  void _armWatchNoShowTimer(String originPeer) {
    if (!state.watchingScreenShares.contains(originPeer)) return;
    if (getScreenShareRenderer(originPeer) != null) return;
    _watchConnectTimers.remove(originPeer)?.cancel();
    _watchConnectTimers[originPeer] = Timer(const Duration(seconds: 20), () {
      _watchConnectTimers.remove(originPeer);
      if (!state.watchingScreenShares.contains(originPeer)) return;
      if (getScreenShareRenderer(originPeer) != null) return;
      if ((_fwdFallbackCount[originPeer] ?? 0) < 2) {
        _fallbackToDirect(originPeer);
        return;
      }
      stopWatchingScreenShare(originPeer);
      _toast("Couldn't connect to the screen share", HollowToastType.error);
    });
  }

  /// Client-bound fwd_* signals. Gated hard: ingest answers only from OUR
  /// registered forwarder; egress offers only for origins we were assigned AND
  /// are watching, from that assignment's forwarder.
  Future<void> handleForwarderSignal(
      String fromPeer, String signalType, String payload) async {
    Map<String, dynamic> v;
    try {
      v = Map<String, dynamic>.from(jsonDecode(payload) as Map);
    } catch (_) {
      return;
    }
    switch (signalType) {
      case 'fwd_ingest_answer':
        final branch = _fwdBranches[fromPeer];
        if (branch == null) return;
        final sdp = v['sdp'] as String? ?? '';
        if (sdp.isEmpty) return;
        await branch.ingest?.handleAnswer(sdp);
      case 'fwd_egress_offer':
        await _handleFwdEgressOffer(fromPeer, v);
      case 'fwd_error':
        await _handleFwdError(fromPeer, v);
      case 'fwd_feed_up':
        // The forwarder we were delegated to feed ADMITTED our ingest: tell the
        // owner so it can stop supplying that forwarder itself.
        final origin = v['origin'];
        final originPeer =
            origin is Map ? (origin['peer'] as String? ?? '') : '';
        if (originPeer.isEmpty) return;
        if (_feedingFor[originPeer] != fromPeer) return;
        _vcLog('[HOLLOW-VC] Feed leg into $fromPeer admitted — reporting up');
        _sendFeedState(originPeer, fromPeer, true);
    }
  }

  /// The forwarder's egress offer for an assigned stream: same originator-keyed
  /// path as a direct offer, with the forwarder as DELIVERER. Replies a full SDP.
  Future<void> _handleFwdEgressOffer(
      String fromPeer, Map<String, dynamic> v) async {
    final origin = v['origin'];
    final originPeer = origin is Map ? (origin['peer'] as String? ?? '') : '';
    final sdp = v['sdp'] as String? ?? '';
    if (originPeer.isEmpty || sdp.isEmpty) return;
    final assignment = _screenAssignments[originPeer];
    if (assignment == null || assignment.forwarder != fromPeer) return;
    if (!state.watchingScreenShares.contains(originPeer)) return;
    final rawOrigin =
        origin is Map ? Map<String, dynamic>.from(origin) : null;
    final answer = await _attachIncomingShare(
      originPeer: originPeer,
      delivererPeer: fromPeer,
      rawOrigin: rawOrigin,
      offerSdp: sdp,
      viaForwarder: true,
    );
    if (answer == null) return;
    final fullAnswer =
        await _incomingScreenShares[originPeer]?.gatheredLocalSdp() ?? answer;
    await network_api
        .forwarderSendSignal(
          forwarderPeerId: fromPeer,
          signalType: 'fwd_egress_answer',
          payload: jsonEncode({'origin': rawOrigin, 'sdp': fullAnswer}),
        )
        .catchError((_) {});
  }

  /// FwdError: walk the fallback ladder; the forwarder is never authority.
  Future<void> _handleFwdError(String fromPeer, Map<String, dynamic> v) async {
    final origin = v['origin'];
    final originPeer = origin is Map ? (origin['peer'] as String? ?? '') : '';
    final code = v['code'] as String? ?? '';
    // FEEDER side: most likely a forwarder binary older than feeder election.
    // Report DOWN so the owner resumes supplying it itself.
    if (_feedingFor[originPeer] == fromPeer) {
      _vcLog('[HOLLOW-VC] Fed forwarder $fromPeer refused our ingest ($code) — '
          'reporting the feed down');
      _sendFeedState(originPeer, fromPeer, false);
      _feedingFor.remove(originPeer);
      return;
    }
    // Sharer side: our stream/ingest was refused by one of our branches.
    final branch = _fwdBranches[fromPeer];
    if (branch != null && originPeer == (_shareOriginPeer ?? '')) {
      _vcLog('[HOLLOW-VC] Forwarder ${branch.forwarderId} refused our stream '
          '($code) — reverting its viewers');
      await _revertBranchViewersToDirect(branch);
      return;
    }
    // Viewer side: a SELF-assigned display hitting unknown_stream is the local
    // attach racing our sharer's register - one bounded retry before laddering.
    final assignment = _screenAssignments[originPeer];
    if (assignment != null && assignment.forwarder == fromPeer) {
      if (code == 'unknown_stream' &&
          fromPeer == _myDevicePeerId &&
          _selfAttachRetried.add(originPeer)) {
        _vcLog('[HOLLOW-VC] Self-attach raced the register for $originPeer — '
            'retrying once');
        Timer(const Duration(milliseconds: 700), () {
          final a = _screenAssignments[originPeer];
          if (a == null || a.forwarder != fromPeer) return;
          if (!state.watchingScreenShares.contains(originPeer)) return;
          network_api
              .forwarderSendSignal(
                forwarderPeerId: fromPeer,
                signalType: 'fwd_attach',
                payload: jsonEncode({
                  'origin': {
                    'peer': originPeer,
                    'kind': a.kind,
                    'stream': a.stream,
                  },
                }),
              )
              .catchError((_) {});
        });
        return;
      }
      _fallbackToDirect(originPeer);
    }
  }

  /// Sharer-side fallback: [branch]'s forwarder refused or lost our ingest, so
  /// tear it down and serve its viewers direct PCs. The dead forwarder is
  /// remembered per viewer so a later re-watch never bounces them back onto it.
  Future<void> _revertBranchViewersToDirect(_FwdBranch branch) async {
    final origin = _myShareOrigin();
    final viewers = List.of(branch.viewers);
    await _teardownBranch(branch, unregister: false, demote: true);
    for (final viewer in viewers) {
      (_viewerFwdFailures[viewer] ??= <String>{}).add(branch.forwarderId);
      if (!_watchers.contains(viewer)) continue;
      if (state.isInVoiceChannel && origin != null) {
        network_api
            .voiceChannelSendSignal(
              serverId: state.currentServerId!,
              channelId: state.currentChannelId!,
              peerId: viewer,
              signalType: 'screen_assign',
              payload: jsonEncode({'origin': origin, 'forwarder': ''}),
            )
            .catchError((_) {});
      }
      if (_audioConnectedPeers.contains(viewer) &&
          !_outgoingScreenShares.containsKey(viewer) &&
          _outgoingScreenShares.length < maxScreenShareOutgoing) {
        await _sendScreenShareToPeer(viewer);
      }
    }
  }

  /// Whether this client may serve as a viewer-peer forwarder: desktop only,
  /// gated on the "Peer media forwarding" toggle, and NEVER under "Always relay
  /// calls" - serving is exactly the address exposure that setting promises away.
  bool _canForwardShares() {
    if (kIsWeb) return false;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return false;
    }
    if (ref.read(alwaysRelayCallsProvider)) return false;
    return ref.read(peerForwardingProvider);
  }

  /// Build a want=true screen_watch payload for [sharerPeer], shared by every
  /// send site so the capability flags can never drift. Advertising capability
  /// also arms the engine's expectation (we only forward streams we watch).
  Map<String, dynamic> _watchPayload(String sharerPeer,
      {required String route}) {
    final (viewerW, viewerH) = largestDisplayResolution();
    final canFwd = _canForwardShares();
    if (canFwd) {
      network_api
          .setForwarderExpectation(
              originPeer: sharerPeer, kind: 'screen', active: true)
          .catchError((_) {});
    }
    // Recorded here so every send site is covered without remembering to.
    _lastRouteHintSent[sharerPeer] = route;
    return {
      'want': true,
      'viewer_width': viewerW,
      'viewer_height': viewerH,
      'route': route,
      'fwd_capable': canFwd,
      // Privacy: forced-relay viewers only ever route through OPERATOR
      // infrastructure, so the sharer skips the peer-forwarder rungs.
      'relay_private': ref.read(alwaysRelayCallsProvider),
      // The sharer offers a simulcast ingest only to forwarders that said so:
      // an old engine would interleave both layers down one egress stream.
      'fwd_simulcast': canFwd,
      // Our engine can also FEED another forwarder, so the sharer may elect us
      // when we head a branch. Same capability gate as forwarding itself.
      'fwd_feed': canFwd,
    };
  }

  /// The last `route` hint we actually SENT per sharer: the baseline the
  /// re-probe compares against so a repeat watch only goes out on a real change.
  final Map<String, String> _lastRouteHintSent = {};

  /// Timers for the one-shot post-connect route re-probe, keyed by sharer.
  final Map<String, Timer> _routeReprobeTimers = {};

  /// A FRESH route probe for [peerId], bypassing [_routeHintTo]'s sticky
  /// "already assigned means relay" short-circuit: right for a re-watch, but a
  /// viewer parked on the VPS because the ICE race handed it a relay pair would
  /// report `relay` forever. The privacy/lab short-circuits stay - those are
  /// policy, not measurement.
  Future<String> _probeRouteFresh(String peerId) async {
    if (Platform.environment['HOLLOW_FORCE_RELAY_ROUTE'] == '1') return 'relay';
    if (ref.read(alwaysRelayCallsProvider)) return 'relay';
    try {
      final pc = _service?.pcFor(peerId);
      if (pc != null) {
        final route = await probeIceRouteOnce(pc);
        if (route != null) return route.isDirect ? 'direct' : 'relay';
      }
    } catch (_) {}
    return '';
  }

  /// Lever 2 of "direct whenever direct is possible": the watch `route` hint is
  /// probed ONCE, so a direct-capable viewer that lost the ICE nomination race
  /// would stay `route=relay` all session and never be promoted. Re-probe once
  /// the audio PC settled, and re-send the watch only if the verdict changed.
  void _scheduleRouteReprobe(String sharerPeer,
      {Duration delay = const Duration(seconds: 10)}) {
    if (!_canReprobeRoute(sharerPeer)) return;
    _routeReprobeTimers.remove(sharerPeer)?.cancel();
    _routeReprobeTimers[sharerPeer] = Timer(delay, () async {
      _routeReprobeTimers.remove(sharerPeer);
      if (!_canReprobeRoute(sharerPeer)) return;
      final fresh = await _probeRouteFresh(sharerPeer);
      if (fresh.isEmpty) return;
      final previous = _lastRouteHintSent[sharerPeer];
      if (fresh == previous) return;
      // Only an upgrade is worth acting on: a downgrade would bounce a working
      // path for no gain, and the ladder handles genuine failures.
      if (fresh != 'direct') return;
      if (!_canReprobeRoute(sharerPeer)) return;
      _vcLog('[HOLLOW-VC] Route re-probe for $sharerPeer: '
          '${previous ?? "?"} → direct — re-sending watch');
      network_api
          .voiceChannelSendSignal(
            serverId: state.currentServerId!,
            channelId: state.currentChannelId!,
            peerId: sharerPeer,
            signalType: 'screen_watch',
            payload: jsonEncode(_watchPayload(
              sharerPeer,
              route: fresh,
            )),
          )
          .catchError((_) {});
    });
  }

  /// Guard shared by the schedule and the fire: still in the VC, still watching
  /// this sharer, and not a forced-relay client (whose route is policy).
  bool _canReprobeRoute(String sharerPeer) =>
      state.isInVoiceChannel &&
      state.currentServerId != null &&
      state.currentChannelId != null &&
      state.watchingScreenShares.contains(sharerPeer) &&
      !ref.read(alwaysRelayCallsProvider);

  /// Viewer-side fallback: drop the assignment, detach, and re-watch with route
  /// "direct_failed" so the sharer descends its ladder. Two attempts per watch
  /// session; after that the 20 s watch timeout gives up with the toast.
  void _fallbackToDirect(String originPeer) {
    final prev = _screenAssignments.remove(originPeer);
    if (prev != null) {
      network_api
          .forwarderSendSignal(
            forwarderPeerId: prev.forwarder,
            signalType: 'fwd_detach',
            payload: jsonEncode({
              'origin': {
                'peer': originPeer,
                'kind': prev.kind,
                'stream': prev.stream,
              },
            }),
          )
          .catchError((_) {});
      _maybeLeaveFwdRoom(prev.forwarder);
    }
    if (!state.watchingScreenShares.contains(originPeer)) return;
    final attempts = _fwdFallbackCount[originPeer] ?? 0;
    if (attempts >= 2) return;
    _fwdFallbackCount[originPeer] = attempts + 1;
    if (!state.isInVoiceChannel) return;
    _vcLog('[HOLLOW-VC] Forwarder path failed for $originPeer — '
        're-watching (attempt ${attempts + 1})');
    network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: originPeer,
          signalType: 'screen_watch',
          payload: jsonEncode(_watchPayload(
            originPeer,
            route: 'direct_failed',
          )),
        )
        .catchError((_) {});
    // Fresh 20 s window for the direct offer to land.
    _watchConnectTimers.remove(originPeer)?.cancel();
    _watchConnectTimers[originPeer] = Timer(const Duration(seconds: 20), () {
      _watchConnectTimers.remove(originPeer);
      if (!state.watchingScreenShares.contains(originPeer)) return;
      if (getScreenShareRenderer(originPeer) != null) return;
      debugPrint('[HOLLOW-VC] Direct fallback for $originPeer timed out — reverting');
      stopWatchingScreenShare(originPeer);
      _toast("Couldn't connect to the screen share", HollowToastType.error);
    });
  }

  /// Re-requests per originator for a dead DIRECT incoming leg. Separate from
  /// [_fwdFallbackCount]: this path never claims a forwarder failed.
  final Map<String, int> _directRerequestCount = {};

  /// A direct incoming share leg died while we still want the share.
  ///
  /// Deliberately NOT [_fallbackToDirect]: that re-watches with
  /// `route: "direct_failed"`, telling the sharer to descend onto a forwarder,
  /// the wrong conclusion when nothing about the forwarder lane failed.
  void _rerequestDirectShare(String originPeer) {
    if (!state.watchingScreenShares.contains(originPeer)) return;
    // The originator stopped sharing: a clean end, not a failure.
    if (state.peerScreenSharing[originPeer] != true) return;
    if (!state.isInVoiceChannel) return;
    if (_screenAssignments.containsKey(originPeer)) return; // forwarder-served
    final attempts = _directRerequestCount[originPeer] ?? 0;
    if (attempts >= 2) {
      _vcLog('[HOLLOW-VC] Direct share from $originPeer died again — giving up');
      return;
    }
    _directRerequestCount[originPeer] = attempts + 1;
    _vcLog('[HOLLOW-VC] Direct share leg from $originPeer died — re-requesting '
        '(attempt ${attempts + 1}, receiver-initiates)');
    unawaited(() async {
      final route = await _routeHintTo(originPeer);
      if (!state.watchingScreenShares.contains(originPeer)) return;
      if (!state.isInVoiceChannel) return;
      network_api
          .voiceChannelSendSignal(
            serverId: state.currentServerId!,
            channelId: state.currentChannelId!,
            peerId: originPeer,
            signalType: 'screen_watch',
            payload: jsonEncode(_watchPayload(
              originPeer,
              route: route,
            )),
          )
          .catchError((_) {});
      _armWatchNoShowTimer(originPeer);
    }());
  }

  /// Viewer side of opt-in watching (issue #38): request [peerId]'s share.
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

    // Ship our display resolution so the sharer clamps our stream to what we
    // can show, plus our route hint and forwarding capability.
    final route = await _routeHintTo(peerId);
    network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: peerId,
          signalType: 'screen_watch',
          payload: jsonEncode(_watchPayload(
            peerId,
            route: route,
          )),
        )
        .catchError((_) {});

    // TURN often wins the nomination race by a single RTT on a path where
    // direct works, so take one more look once the audio PC settled.
    _scheduleRouteReprobe(peerId);

    // If no offer produces a live track in time, revert so the tile doesn't
    // spin forever. A dead forwarder assignment walks the ladder first.
    _watchConnectTimers.remove(peerId)?.cancel();
    _watchConnectTimers[peerId] = Timer(const Duration(seconds: 20), () {
      _watchConnectTimers.remove(peerId);
      if (!state.watchingScreenShares.contains(peerId)) return;
      if (getScreenShareRenderer(peerId) != null) return;
      if (_screenAssignments.containsKey(peerId) &&
          (_fwdFallbackCount[peerId] ?? 0) < 2) {
        _fallbackToDirect(peerId);
        return;
      }
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
    _routeReprobeTimers.remove(peerId)?.cancel();
    _lastRouteHintSent.remove(peerId);
    _earlyScreenIce.remove('incoming:$peerId');

    final watching = {...state.watchingScreenShares}..remove(peerId);

    // Before closing the service, so the UI never renders a torn-down renderer.
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
        focusedScreenSharePeerId: nextFocus ?? cameraFocus,
        clearFocusedSharer: nextFocus == null && cameraFocus == null,
        focusedSourceType: nextFocus != null
            ? 'screen'
            : (cameraFocus != null ? 'camera' : state.focusedSourceType),
      );
    } else {
      state = state.copyWith(
        watchingScreenShares: watching,
      );
    }

    final incoming = _incomingScreenShares.remove(peerId);
    _incomingShareOrigins.remove(peerId);
    if (incoming != null) {
      await incoming.close();
      await _dropShareCryptors(peerId);
    }

    // Detach from the forwarder if this origin was served through it; the watch
    // ending also withdraws our forwarding offer for that origin.
    network_api
        .setForwarderExpectation(
            originPeer: peerId, kind: 'screen', active: false)
        .catchError((_) {});
    _fwdFallbackCount.remove(peerId);
    _directRerequestCount.remove(peerId);
    _selfAttachRetried.remove(peerId);
    final assignment = _screenAssignments.remove(peerId);
    if (assignment != null) {
      network_api
          .forwarderSendSignal(
            forwarderPeerId: assignment.forwarder,
            signalType: 'fwd_detach',
            payload: jsonEncode({
              'origin': {
                'peer': peerId,
                'kind': assignment.kind,
                'stream': assignment.stream,
              },
            }),
          )
          .catchError((_) {});
      _maybeLeaveFwdRoom(assignment.forwarder);
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

  void _toast(String message, HollowToastType type) {
    final overlay = hollowNavigatorKey.currentState?.overlay;
    final overlayContext = overlay?.context;
    if (overlay == null || overlayContext == null || !overlayContext.mounted) {
      return;
    }
    HollowToast.show(overlayContext, message, type: type, overlayState: overlay);
  }

  void _broadcastScreenState(bool enabled) {
    if (!state.isInVoiceChannel) return;
    // Device-keyed set: skip both our id forms (see _broadcastAudioState).
    final localMaster = ref.read(identityProvider).peerId ?? '';
    final localDevice = _service?.localPeerId ?? _myDevicePeerId ?? '';
    final peers = state.getParticipants(
        state.currentServerId!, state.currentChannelId!);
    final json = <String, dynamic>{'enabled': enabled};
    if (enabled && state.screenShareLabel != null) {
      json['quality'] = state.screenShareLabel;
    }
    final payload = jsonEncode(json);
    for (final peerId in peers) {
      if (peerId == localMaster || peerId == localDevice) continue;
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
  /// [peerId]. enableFor* is idempotent per (participant, kind), so without this
  /// a RESTARTED share keeps cryptors bound to the dead PC and goes untransformed.
  Future<void> _dropShareCryptors(String peerId) async {
    try {
      await _service?.frameCryptor?.disableForPeer('screen:$peerId');
    } catch (e) {
      debugPrint('[HOLLOW-VC] dropShareCryptors($peerId) failed: $e');
    }
  }

  Future<void> _cleanupPeerScreenShare(String peerId) async {
    _watchConnectTimers.remove(peerId)?.cancel();
    _routeReprobeTimers.remove(peerId)?.cancel();
    _lastRouteHintSent.remove(peerId);
    _watchers.remove(peerId);
    _watcherDisplays.remove(peerId);
    _watcherRoutes.remove(peerId);
    // Their share ending ends our watch, the forwarding offer and the counter.
    network_api
        .setForwarderExpectation(
            originPeer: peerId, kind: 'screen', active: false)
        .catchError((_) {});
    _fwdFallbackCount.remove(peerId);
    _directRerequestCount.remove(peerId);
    // A vanished PEER FORWARDER takes its whole branch down, but PRESENCE CAN
    // FLAP: the relay's ghost-socket eviction broadcasts PeerLeft while the
    // same peer's live socket is still in the room. When the branch has a live
    // ingest leg the LEG is the truth, and its onDisconnected reverts instead.
    final memberBranch = _branchOf(peerId);
    if (memberBranch != null) {
      await _removeViewerFromBranch(memberBranch, peerId);
    }
    final headedBranch = _fwdBranches[peerId];
    if (headedBranch != null) {
      if (headedBranch.ingest == null) {
        await _revertBranchViewersToDirect(headedBranch);
      } else {
        _vcLog('[HOLLOW-VC] Presence drop for forwarder $peerId ignored — '
            'its ingest leg is alive (ghost-eviction flap tolerance)');
      }
    }
    // Incoming shares are ORIGINATOR-keyed: drop the share this peer originated
    // AND any share it was DELIVERING (equal on direct legs).
    final originsToDrop = <String>{
      if (_incomingScreenShares.containsKey(peerId)) peerId,
      ..._incomingShareOrigins.entries
          .where((e) => e.value.deliverer == peerId)
          .map((e) => e.key),
    };
    for (final origin in originsToDrop) {
      // PRESENCE-FLAP TOLERANCE: if the stream this peer DELIVERS is still
      // rendering, the media leg is the truth. A genuinely dead deliverer kills
      // the leg within seconds and its onDisconnected walks the ladder.
      if (origin != peerId &&
          _incomingScreenShares[origin]?.remoteRenderer != null &&
          state.watchingScreenShares.contains(origin)) {
        _vcLog('[HOLLOW-VC] Presence drop for deliverer $peerId ignored — '
            'stream from $origin still rendering');
        continue;
      }
      final incoming = _incomingScreenShares.remove(origin);
      _incomingShareOrigins.remove(origin);
      if (incoming != null) {
        await incoming.close();
        await _dropShareCryptors(origin);
      }
      // [peerId] was only the DELIVERER: the originator is still sharing, so
      // losing the deliverer must never strand the watch. The re-watch rides the
      // relay, so it heals even while the direct audio PC to the sharer is down.
      if (origin != peerId &&
          state.watchingScreenShares.contains(origin) &&
          state.peerScreenSharing[origin] == true) {
        _fallbackToDirect(origin);
      }
    }
    // Close outgoing screen share to this peer (viewer-keyed transport leg).
    // _dropShareCryptors is idempotent, so a double drop is harmless.
    final outgoing = _outgoingScreenShares.remove(peerId);
    if (outgoing != null) {
      await outgoing.close();
      await _dropShareCryptors(peerId);
    }
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

  Future<void> _cleanupAllScreenShares() async {
    _screenTrackPoller?.cancel();
    _screenTrackPoller = null;

    for (final t in _watchConnectTimers.values) {
      t.cancel();
    }
    _watchConnectTimers.clear();
    for (final t in _routeReprobeTimers.values) {
      t.cancel();
    }
    _routeReprobeTimers.clear();
    _lastRouteHintSent.clear();
    _watchers.clear();
    _watcherDisplays.clear();

    // Leaving the channel drops every forwarder relationship; presence in the
    // fwd room is the forwarder's own cleanup signal too.
    _watcherRoutes.clear();
    _viewerFwdFailures.clear();
    // Stop feeding anyone: the far forwarder should learn it now.
    for (final entry in _feedingFor.entries) {
      network_api
          .setForwarderFeed(
            originPeer: entry.key,
            kind: 'screen',
            stream: '',
            targetForwarder: entry.value,
            active: false,
          )
          .catchError((_) {});
    }
    _feedingFor.clear();
    _feedFailures.clear();
    await _teardownAllBranches(unregister: true, demote: false);
    for (final origin in _screenAssignments.keys) {
      network_api
          .setForwarderExpectation(
              originPeer: origin, kind: 'screen', active: false)
          .catchError((_) {});
    }
    for (final origin in state.watchingScreenShares) {
      network_api
          .setForwarderExpectation(
              originPeer: origin, kind: 'screen', active: false)
          .catchError((_) {});
    }
    final fwdRooms =
        _screenAssignments.values.map((a) => a.forwarder).toSet();
    _screenAssignments.clear();
    _fwdFallbackCount.clear();
    _directRerequestCount.clear();
    _selfAttachRetried.clear();
    for (final fwd in fwdRooms) {
      _maybeLeaveFwdRoom(fwd);
    }

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
    _incomingShareOrigins.clear();
    _shareSessionId = null;
    _shareOriginPeer = null;
    for (final peerId in allSharePeers) {
      await _dropShareCryptors(peerId);
    }

    if (_localScreenPreviewRenderer != null) {
      _localScreenPreviewRenderer!.srcObject = null;
      await _localScreenPreviewRenderer!.dispose();
      _localScreenPreviewRenderer = null;
    }

    for (final t in _screenCaptureStream?.getTracks() ?? []) {
      try { await t.stop(); } catch (_) {}
    }
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
  /// `channelId == null` is the server-wide group key; a non-null one is a
  /// restricted channel's MLS subgroup key and applies only to that channel.
  Future<void> onEpochChanged(
      String serverId, int epoch, Uint8List sframeKey,
      {String? channelId}) async {
    // Always cache — the event may arrive before onLocalJoined sets currentServerId.
    _sframeKeys[_sframeCacheKey(serverId, channelId)] =
        (epoch: epoch, key: Uint8List.fromList(sframeKey));

    if (state.currentServerId != serverId) return;
    if (!state.isInVoiceChannel || _service == null) return;

    // Only apply a key that belongs to the channel we're in: a subgroup key must
    // match the current channel; the server-group key applies to unrestricted ones.
    if (channelId != null && state.currentChannelId != channelId) return;
    // A SERVER-GROUP epoch change must never clobber a restricted channel's
    // SUBGROUP key: that would re-key this VC onto material every non-qualifying
    // member holds.
    if (channelId == null &&
        state.currentChannelId != null &&
        _channelUsesSubgroup(state.currentChannelId!)) {
      return;
    }

    debugPrint('[HOLLOW-VC] MLS epoch changed: $epoch '
        '(${channelId == null ? "server group" : "subgroup $channelId"}) '
        '— rotating SFrame key');
    await _service!.setSframeKey(epoch, sframeKey);

    // A share started before the FIRST key has no cryptors yet - enable them
    // now (idempotent; rotateKey already re-indexed existing share cryptors).
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
      // FORWARDER BRANCH INGEST LEGS TOO: they live outside the two maps above,
      // and an ingest sender that misses a rotation keeps encrypting under the
      // OLD index - every viewer behind that forwarder goes MissingKey/black.
      for (final b in _fwdBranches.values) {
        final ingestPc = b.ingest?.pc;
        if (ingestPc != null) {
          await _enableSframeOnScreenSharePc(ingestPc, fc, b.forwarderId,
              isSender: true);
        }
      }
    }
  }

  /// Cryptor state transition from the service. Failure states arm the heal
  /// timer; recovery states clear the tracking.
  void _onSframeCryptorState(
      String peerId, String kind, bool isReceiver, FrameCryptorState st) {
    final key = '$peerId|$kind|${isReceiver ? 'rx' : 'tx'}';
    if (FrameCryptorService.isFailureState(st)) {
      _sframeFailures.putIfAbsent(key, () => DateTime.now());
      _sframeHealTimer ??= Timer.periodic(
          const Duration(seconds: 2), (_) => _sframeHealTick());
      // MissingKey on a RECEIVER means "the frame wants a key slot I don't hold":
      // the join-order epoch race signature. Fire the cheap heal now instead of
      // waiting for ladder step 2; the normal ladder stays the backstop.
      if (st == FrameCryptorState.FrameCryptorStateMissingKey && isReceiver) {
        final last = _sframeMissingKeyPings[peerId];
        if (last == null ||
            DateTime.now().difference(last) >= const Duration(seconds: 5)) {
          _sframeMissingKeyPings[peerId] = DateTime.now();
          debugPrint(
              '[HOLLOW-VC] MissingKey fast-path: immediate heal ping for $peerId');
          _sframeHealRust(peerId, escalate: false);
        }
      }
    } else {
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
    _sframeMissingKeyPings.clear();
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
      // ~2 min without a key: stop nagging, a later epoch change still applies.
      _sframeKeylessTimer?.cancel();
      _sframeKeylessTimer = null;
      return;
    }
    debugPrint('[HOLLOW-VC] SFrame keyless after join '
        '(tick $_sframeKeylessTicks) — nudging Rust for the group key');
    // Rust's group-less heal branch re-requests the MLS bootstrap; peerId unused.
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
          // Further escalation would just churn the server MLS group.
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
          // Escalation on cooldown - keep cycling the cheap re-emit, which is
          // also what re-keys US after the authority re-added our leaves.
          _sframeHealRust(peerId, escalate: false);
          _sframeHealProgress[peerId] = (step: 2, at: DateTime.now());
        }
      }
    }
  }

  /// Heal step 1: re-apply the cached key and rebind the peer's receiver cryptors.
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
    // Share-PC cryptors live under 'screen:$peerId', which the voice rebind
    // above cannot reach (setKeyIndexForPeer prefix-matches '$peerId:').
    final fc = svc.frameCryptor;
    if (fc != null) {
      final incomingPc = _incomingScreenShares[peerId]?.pc;
      if (incomingPc != null) {
        await _enableSframeOnScreenSharePc(incomingPc, fc, peerId,
            isSender: false);
      }
      final outgoingPc = _outgoingScreenShares[peerId]?.pc;
      if (outgoingPc != null) {
        await _enableSframeOnScreenSharePc(outgoingPc, fc, peerId,
            isSender: true);
      }
      // A peer served THROUGH a branch needs the branch's ingest sender healed
      // too - it lives outside the two maps above.
      final ingestPc = _fwdBranches[peerId]?.ingest?.pc;
      if (ingestPc != null) {
        await _enableSframeOnScreenSharePc(ingestPc, fc, peerId,
            isSender: true);
      }
    }
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
    // Self-skip must use the ROUTABLE DEVICE id: participant sets and gossip
    // neighbor lists are device-keyed. The master id is a legacy belt.
    final localPeerId = _service!.localPeerId;
    final localMaster = ref.read(identityProvider).peerId ?? '';
    bool isLocal(String id) => id == localPeerId || id == localMaster;

    if (mode == 'gossip' && oldMode == 'mesh') {
      final existing = state.getParticipants(serverId, channelId);
      for (final peerId in existing) {
        if (isLocal(peerId)) continue;
        if (!neighborSet.contains(peerId)) {
          debugPrint('[HOLLOW-VC] Gossip: closing non-neighbor $peerId');
          await _service!.onPeerLeftMyChannel(peerId);
        }
      }
      for (final peerId in neighborSet) {
        if (isLocal(peerId)) continue;
        await _service!.onPeerJoinedMyChannel(peerId);
      }
      _service!.gossipMode = true;
      _service!.gossipNeighbors = neighborSet;
    } else if (mode == 'mesh' && oldMode == 'gossip') {
      _service!.gossipMode = false;
      _service!.gossipNeighbors = {};
      final existing = state.getParticipants(serverId, channelId);
      for (final peerId in existing) {
        if (isLocal(peerId)) continue;
        await _service!.onPeerJoinedMyChannel(peerId);
      }
    } else if (mode == 'gossip') {
      _service!.gossipNeighbors = neighborSet;
      final currentPeers = _service!.connectedPeerIds;
      for (final peerId in currentPeers) {
        if (!neighborSet.contains(peerId)) {
          debugPrint('[HOLLOW-VC] Gossip update: closing non-neighbor $peerId');
          await _service!.onPeerLeftMyChannel(peerId);
        }
      }
      for (final peerId in neighborSet) {
        if (isLocal(peerId)) continue;
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
    // No key material (MLS-less server): leave the share PC untransformed on
    // BOTH sides. A keyless sender cryptor silently DROPS every frame, and a
    // one-sided enable was the asymmetry behind issue #27.
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
