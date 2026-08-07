import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/viewer_display.dart';
import 'package:hollow/src/core/providers/forwarder_info_provider.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/services/desktop_capture_support.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/ice_route_probe.dart';
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

/// Sharer-side state for ONE forwarder serving our share (media forwarding
/// step 3). Phase 1's single infra branch generalized: phase 2 runs several
/// branches at once (the VPS forwarder + promoted viewer-peer forwarders),
/// each with its own single ingest leg.
class _FwdBranch {
  _FwdBranch(this.forwarderId, {required this.isPeer});

  final String forwarderId;

  /// True = a viewer-peer forwarder (phase 2): a watcher we promoted. Its
  /// own display is downstream viewer #0 (rides the ingest through its
  /// embedded engine, so its direct PC is closed on promote and restored on
  /// demote), and its remote capacity is [VoiceChannelNotifier.maxPeerForwarderLegs].
  final bool isPeer;

  /// REMOTE downstream viewers served through this branch. A peer branch's
  /// own display is NOT in here (local leg, not upload-bounded) but IS on
  /// the register allowlist and in the ingest cap.
  final Set<String> viewers = {};

  /// The single ingest leg to this forwarder.
  ScreenShareService? ingest;

  /// Tears the idle branch down ~30 s after its last viewer leaves (a quick
  /// re-watch shouldn't pay a full re-register).
  Timer? linger;
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

  /// Media forwarding step 2: our share session's stream id — rides
  /// `origin.stream` on every outgoing screen offer/ICE. Minted per
  /// startScreenShare, cleared on stop, so a restarted share is
  /// distinguishable from a stale session.
  String? _shareSessionId;

  /// Media forwarding step 2: the id we self-attribute shares under —
  /// our ROUTABLE device peer id (the id VC signal receivers key us by).
  String? _shareOriginPeer;

  /// Media forwarding step 2: per-ORIGINATOR record of who DELIVERED their
  /// stream plus its wire metadata. On every direct leg (all of step 2)
  /// `deliverer == originator`; step-3 forwarder legs set deliverer = the
  /// forwarder's peer id. Used to echo `origin` on answers/ICE and to tear
  /// down delivered streams when their deliverer disconnects.
  final Map<String, ({String deliverer, String kind, String stream})>
      _incomingShareOrigins = {};

  // -- Media forwarding step 3: forwarder lane (phase 1 infra + phase 2
  // viewer-peer forwarders) --

  /// Sharer side: one active forwarder BRANCH per forwarder peer id — the
  /// VPS infra forwarder and/or promoted viewer-peer forwarders (phase 2).
  /// Each branch carries ONE ingest leg fanned to its viewers; branch
  /// viewers hold no per-viewer PC and don't consume the 15-cap. Display
  /// caps stay in [_watcherDisplays]; each ingest is encoded at the max over
  /// its own audience (incl. a peer forwarder's own display).
  final Map<String, _FwdBranch> _fwdBranches = {};

  /// Sharer side: per-watcher route hint + phase-2 forwarding capability +
  /// privacy flag from their screen_watch. Candidates = fwd_capable &&
  /// route == 'direct'; relayPrivate viewers are only ever routed through
  /// operator infrastructure (VPS forwarder / TURN), never a peer.
  final Map<String, ({String route, bool fwdCapable, bool relayPrivate})>
      _watcherRoutes = {};

  /// Sharer side: forwarders that FAILED for a viewer this share session (a
  /// `direct_failed` re-watch names the branch they were on) — never
  /// re-assigned to the same viewer. Two failures ⇒ the viewer goes direct.
  final Map<String, Set<String>> _viewerFwdFailures = {};

  /// Phase 2: max REMOTE downstream viewers per viewer-peer forwarder (its
  /// own display leg is local and free — Vitalik's "2–3 legs" policy).
  static const int maxPeerForwarderLegs = 3;

  /// Viewer side: forwarder assignments by ORIGINATOR
  /// (`vc_screen_assign`) — which forwarder serves that origin's stream to
  /// us. fwd_* frames are honored ONLY for assigned origins from the
  /// assigned forwarder. Phase 2: `forwarder` may be a viewer-peer — or US
  /// (self-assignment: our display rides our own embedded engine).
  final Map<String, ({String forwarder, String kind, String stream})>
      _screenAssignments = {};

  /// Viewer side: forwarder→next-rung fallback attempts per origin this
  /// watch session. Phase 2 ladder = peer forwarder → VPS forwarder →
  /// direct+TURN, so up to TWO attempts before the watch timeout gives up.
  final Map<String, int> _fwdFallbackCount = {};

  /// Our ROUTABLE device peer id (VC signals key us by it) — cached for the
  /// self-assignment check (`vc_screen_assign{forwarder: us}`).
  String? _myDevicePeerId;

  /// Origins whose SELF-attach already got its one bounded retry after an
  /// `unknown_stream` (the local attach can race the sharer's register even
  /// with register-first send ordering — e.g. an Olm re-key in between).
  final Set<String> _selfAttachRetried = {};

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
      // via screen_watch — never unconditionally. Forwarder-served viewers
      // (step 3) never get a direct per-viewer PC from this path either, and
      // neither does a promoted peer forwarder (its display rides its own
      // engine leg).
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
    // Media forwarding step 3: the sharer routed us to a forwarder.
    if (signalType == 'screen_assign') {
      await _handleScreenAssign(peerId, payload);
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

    // Media forwarding step 2: mint this share session's identity — the
    // stream id rides `origin.stream` on every screen signal (a restart mints
    // a new one), the origin peer is our routable device id.
    final rng = Random.secure();
    _shareSessionId =
        List.generate(8, (_) => rng.nextInt(16).toRadixString(16)).join();
    _shareOriginPeer = await network_api.getLocalDevicePeerId() ??
        (ref.read(identityProvider).peerId ?? '');

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
      _watcherRoutes.clear();
      _viewerFwdFailures.clear();
      // Step 3: unregister at every forwarder + close the ingest legs BEFORE
      // the session ids clear (the unregister envelopes need the origin).
      // The share is ending, so demoted peer forwarders get no direct offer.
      await _teardownAllBranches(unregister: true, demote: false);
      // This share session is over — a restart mints a fresh origin.
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

  /// Media forwarding step 2 — the ORIGINATOR of a screen signal: who the
  /// stream is FROM, vs [sender] who DELIVERED it. Equal on every direct leg
  /// (and Rust drops any other combination on this lane); step-3 forwarder
  /// legs ride the fwd_* namespace with deliverer = the forwarder.
  String _origOf(String sender, Map<String, dynamic> v) {
    final origin = v['origin'];
    if (origin is Map) {
      final p = origin['peer'];
      if (p is String && p.isNotEmpty) return p;
    }
    return sender;
  }

  /// Our own share's `origin` sub-object for outgoing screen offers/ICE.
  /// Null until startScreenShare minted the session (old-wire shape: absent
  /// origin = sender is the originator, so null is always safe).
  Map<String, dynamic>? _myShareOrigin() {
    final stream = _shareSessionId;
    final peer = _shareOriginPeer;
    if (stream == null || peer == null || peer.isEmpty) return null;
    return {'peer': peer, 'kind': 'screen', 'stream': stream};
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

    // Media forwarding step 2: everything about WHO the stream is from keys
    // on the ORIGINATOR; [peerId] (the deliverer) keeps transport routing
    // (answers/ICE go back to whoever delivered the offer). Equal on every
    // direct leg today. rawOrigin is echoed verbatim on answer/ICE so the
    // sharer's Rust guard (origin.peer == themselves) accepts it.
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

    // A direct offer supersedes any forwarder assignment for this origin
    // (revert-to-direct / fallback-ladder outcome).
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

  /// Shared construction of an incoming share leg — direct offers
  /// (_handleScreenOffer) and forwarder egress offers (step 3) build the
  /// SAME service, keyed by ORIGINATOR everywhere (attribution, SFrame
  /// cryptor `'screen:$originPeer'`, renderer lookup), with the DELIVERER
  /// kept only for transport routing. Returns the answer SDP, or null when
  /// the incoming cap rejected the stream.
  ///
  /// Forwarder legs differ in exactly two transport properties: STUN-only
  /// ICE (never forced-relay TURN — the forwarder IS the relay replacement)
  /// and COMPLETE SDPs (no trickle lane, so no onIceCandidate wiring and no
  /// early-ICE flush).
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

    // Mark the originator as sharing (screen_offer may arrive before screen_state).
    // No auto-focus: watchScreenShare already focused this share when the
    // user opted in — the offer landing must not steal focus.
    final sharing = Map.of(state.peerScreenSharing);
    sharing[originPeer] = true;
    state = state.copyWith(peerScreenSharing: sharing);

    final iceConfig =
        viaForwarder ? _forwarderLegIceConfig() : ref.read(iceConfigProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    // Close existing incoming service for this originator if any (and drop
    // its cryptors so the new PC's receivers re-enable cleanly).
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

    // Set preferred audio output.
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
      // The share we asked for is live — stop the "offer never came" timer.
      _watchConnectTimers.remove(originPeer)?.cancel();
      // Force a state rebuild so the UI picks up the renderer.
      // Also auto-focus if no one is focused yet (only fires for watched shares).
      state = state.copyWith(
        focusedScreenSharePeerId:
            state.focusedScreenSharePeerId ?? originPeer,
      );
    };

    if (viaForwarder) {
      // Forwarder died / dropped our leg mid-stream: the feed dies, the
      // fallback ladder re-requests the direct path (availability helper,
      // never authority — the share must survive its assist).
      service.onDisconnected = () {
        if (_incomingScreenShares[originPeer] != service) return;
        _vcLog('[HOLLOW-VC] Forwarder leg for $originPeer disconnected — '
            'walking the fallback ladder');
        _fallbackToDirect(originPeer);
      };
    }

    _incomingScreenShares[originPeer] = service;
    _incomingShareOrigins[originPeer] = (
      deliverer: delivererPeer,
      kind: (rawOrigin?['kind'] as String?) ?? 'screen',
      stream: (rawOrigin?['stream'] as String?) ?? '',
    );

    final answerSdp = await service.handleOffer(offerSdp);

    // Enable SFrame E2EE on the incoming screen share PC — keyed on the
    // ORIGINATOR, whose sender key encrypted the frames.
    if (service.pc != null && _service?.frameCryptor != null) {
      await _enableSframeOnScreenSharePc(
          service.pc!, _service!.frameCryptor!, originPeer, isSender: false);
    }

    if (!viaForwarder) {
      // Flush any ICE candidates that arrived before this service was created.
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
      // Their incoming = our outgoing (sharer side: transport-keyed by the
      // viewer the leg goes to).
      service = _outgoingScreenShares[peerId];
      queueKey = 'outgoing:$peerId';
    } else {
      // Their outgoing = our incoming — keyed by the stream's ORIGINATOR
      // (media forwarding step 2; equals the sender on every direct leg).
      final originPeer = _origOf(peerId, v);
      service = _incomingScreenShares[originPeer];
      queueKey = 'incoming:$originPeer';
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
    final route = v['route'] as String? ?? '';
    final fwdCapable = v['fwd_capable'] as bool? ?? false;
    final relayPrivate = v['relay_private'] as bool? ?? false;
    debugPrint('[HOLLOW-VC] Screen watch from $peerId: want=$want '
        'viewer=${viewerW}x$viewerH source=$sourceQuality route=$route '
        'fwd_capable=$fwdCapable relay_private=$relayPrivate');

    if (want) {
      // Raced against our stop — nothing to send; the peer's badge clears
      // via our screen_state{disabled} broadcast.
      if (!state.isScreenSharing || _screenCaptureStream == null) return;
      _watchers.add(peerId);
      _watcherDisplays[peerId] =
          (w: viewerW, h: viewerH, source: sourceQuality);
      _watcherRoutes[peerId] =
          (route: route, fwdCapable: fwdCapable, relayPrivate: relayPrivate);

      // Media forwarding step 3: a relay-routed NEW-client viewer (non-empty
      // route = step-3-capable; old viewers must never receive
      // vc_screen_assign) is served THROUGH a forwarder — one ingest copy,
      // no per-viewer PC, no 15-cap slot. Phase 2 ladder: viewer-peer
      // forwarder → VPS infra forwarder → direct+TURN. A "direct_failed"
      // re-watch marks the branch it was on as failed and descends one rung.
      if (route == 'relay' || route == 'direct_failed') {
        // A branch HEAD reporting direct_failed is our own promoted
        // forwarder whose display path failed — DEMOTE the branch (its
        // viewers revert and re-ladder; the head falls through to the
        // direct path below), never re-ladder the head onto another
        // forwarder (field-hit 2026-08-06: the sharer put its own peer
        // forwarder's display onto the VPS).
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
        if (route == 'relay' && current != null) {
          // Re-sent watch (cap / Source-quality change): the ingest is
          // encoded at max(effectiveViewerCap) over the branch audience.
          await _reofferIngest(current);
          return;
        }
        final target = _pickForwarderFor(peerId);
        if (target != null) {
          await _assignViewerToForwarder(peerId, target);
          return;
        }
        // No rung left — fall through to the direct path.
      }
      // Viewer moved OFF the forwarder path (direct / exhausted ladder).
      final stale = _branchOf(peerId);
      if (stale != null) {
        await _removeViewerFromBranch(stale, peerId);
      }
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
      _watcherRoutes.remove(peerId);
      final branch = _branchOf(peerId);
      if (branch != null) {
        await _removeViewerFromBranch(branch, peerId);
      }
      // Phase 2: a peer FORWARDER that stopped watching can't keep serving
      // (its display is downstream viewer #0 — no watch, no consent, no
      // engine expectation). Its viewers revert to direct and re-ladder.
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

  // -- Media forwarding step 3: forwarder lane --

  /// ICE config for forwarder legs (ingest + egress attach): NO ice servers
  /// at all — host candidates only.
  ///
  /// DELIBERATELY not [iceConfigProvider]: "Always relay calls" forces
  /// `iceTransportPolicy: relay` there, and a forced-TURN leg to the
  /// forwarder would blackhole it — the forwarder IS the relay replacement
  /// (same operator infra as TURN, so nothing new is disclosed). Also NOT
  /// [shareIceConfigProvider]: that is the Hollow Share FILE lane with its
  /// own bandwidth doctrine.
  ///
  /// CRITICAL — the list must stay EMPTY. The forwarder answers on a fixed
  /// PUBLIC address, so a server-reflexive candidate buys nothing: our host
  /// candidate plus our own outbound checks are sufficient, and the forwarder
  /// learns our NAT mapping as a peer-reflexive candidate from those checks.
  /// Configuring STUN servers here actively BREAKS the leg: libwebrtc's UDP
  /// port withholds its candidates while it waits on the configured STUN
  /// servers, so on a host whose DNS answers IPv6-first without a routable
  /// IPv6 path (the D6 test VM: ULA address, IPv6-only default gateway) the
  /// allocator produced ZERO candidates, never activated ICE, and the leg
  /// silently timed out — three field tests, 2026-08-06. The D2 spike used an
  /// empty list and connected first try.
  Map<String, dynamic> _forwarderLegIceConfig() => const {'iceServers': []};

  /// The viewer's `route` hint for screen_watch: one immediate stats pass on
  /// the audio PC to [peerId]. ADVISORY — a wrong hint is corrected by the
  /// fallback ladder; "" (unknown) keeps today's direct path.
  Future<String> _routeHintTo(String peerId) async {
    // Already served through the forwarder for this sharer: stay put — a
    // re-watch (Source toggle) must not bounce us to direct mid-stream.
    // (_fallbackToDirect bypasses this with an explicit "direct_failed".)
    if (_screenAssignments.containsKey(peerId)) return 'relay';
    // Lab escape hatch (phase-2 field verification): report "relay" WITHOUT
    // the Always-relay privacy semantics. A genuinely NAT-restricted viewer
    // can't be simulated on a LAN test rig any other way — Always-relay now
    // steers to the VPS rung by design (relay_private), so it no longer
    // exercises the peer-forwarder path. Unset in production = inert.
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

  /// Phase-2 static selection for a relay-routed [viewer]: an existing peer
  /// branch with capacity → a promotable candidate (fwd-capable watcher on a
  /// direct route) → the VPS infra forwarder → null (= direct+TURN).
  /// Forwarders that already failed for this viewer are skipped; after two
  /// failed rungs the viewer always goes direct (both sides bound the
  /// ladder — the viewer's own counter caps at two as well).
  String? _pickForwarderFor(String viewer) {
    // A branch HEAD's own display rides its branch's engine or a direct
    // offer — never ANOTHER forwarder (no chains in v1).
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
        if (b.viewers.length >= maxPeerForwarderLegs) continue;
        return b.forwarderId;
      }
      // Promote a fresh candidate.
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

  /// Sharer side: serve [viewerPeer] through [forwarderPeerId] instead of a
  /// per-viewer PC. Creates the branch on first use — for a PEER forwarder
  /// that promotion also self-assigns it (its display switches from its
  /// direct PC to its embedded engine's egress leg) and closes our direct PC
  /// to it (ONE upload copy for the whole branch). Registers the stream
  /// (idempotent full-allowlist replace), ensures the branch's single ingest
  /// leg, then assigns the viewer.
  Future<void> _assignViewerToForwarder(
      String viewerPeer, String forwarderPeerId) async {
    final origin = _myShareOrigin();
    if (origin == null) return;
    var branch = _fwdBranches[forwarderPeerId];
    final isNewPeerBranch =
        branch == null && _watchers.contains(forwarderPeerId);
    if (branch == null) {
      branch = _FwdBranch(forwarderPeerId,
          isPeer: _watchers.contains(forwarderPeerId));
      _fwdBranches[forwarderPeerId] = branch;
      await network_api
          .joinForwarderRoom(forwarderPeerId: forwarderPeerId)
          .catchError((_) {});
      if (branch.isPeer) {
        _vcLog('[HOLLOW-VC] Promoted $forwarderPeerId to peer forwarder');
      }
    }
    branch.linger?.cancel();
    branch.linger = null;
    branch.viewers.add(viewerPeer);
    // Register BEFORE any assignment leaves: the register and the assigns
    // ride the SAME relay socket in order, so the engine provably knows the
    // stream before the promoted forwarder's INSTANT local self-attach can
    // race it (field-hit 2026-08-06: assign-first lost that race —
    // unknown_stream — and the forwarder's own display laddered away).
    // Registers (idempotently) inside _ensureIngestLeg too; when the leg is
    // already live this call still refreshes the allowlist with the new viewer.
    await _registerStreamAtForwarder(branch);
    await _ensureIngestLeg(branch);
    if (isNewPeerBranch) {
      // Self-assignment (switches the forwarder's display onto its own
      // engine), then close our per-viewer PC to it — the viewer side
      // retires its direct service deliberately on the assign, so the close
      // lands on an already-superseded leg.
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
      }
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
  }

  /// A branch's ingest cap: max(effectiveViewerCap) over ITS audience —
  /// remote viewers plus, on a peer branch, the forwarder's own display
  /// (step-1 machinery reused). One pixel-peeper's Source request raises
  /// only this one stream until phase-3 simulcast.
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
  /// Idempotent by contract (a re-register replaces the allowlist), so every
  /// path that is about to offer an ingest calls this first: an ingest offer
  /// for a stream the forwarder doesn't know is refused outright with
  /// `unknown_stream`, and a registration can legitimately be missing
  /// (dropped first send, forwarder restart, our own room churn). A peer
  /// forwarder is on its OWN allowlist — its display leg attaches through
  /// the same engine admission as everyone else.
  Future<void> _registerStreamAtForwarder(_FwdBranch branch) async {
    final origin = _myShareOrigin();
    if (origin == null) return;
    await network_api
        .forwarderSendSignal(
          forwarderPeerId: branch.forwarderId,
          signalType: 'fwd_stream_register',
          payload: jsonEncode({
            'origin': origin,
            'allowed_viewers': [
              ...branch.viewers,
              if (branch.isPeer) branch.forwarderId,
            ],
          }),
        )
        .catchError((_) {});
  }

  /// Create a branch's single ingest leg (no-op if live).
  Future<void> _ensureIngestLeg(_FwdBranch branch) async {
    if (branch.ingest != null) return;
    if (_screenCaptureStream == null) return;
    final origin = _myShareOrigin();
    if (origin == null) return;
    // Never offer an ingest for a stream the forwarder might not hold.
    await _registerStreamAtForwarder(branch);
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final service = ScreenShareService(
      localPeerId: localPeerId,
      iceServers: _forwarderLegIceConfig(),
      forwarderLeg: true,
    );
    branch.ingest = service;
    // Forwarder died / dropped the ingest mid-stream: revert this branch's
    // audience to direct per-viewer PCs.
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

  /// Re-offer a branch's ingest at the current cap (a branch viewer's cap or
  /// Source-quality changed): live setParameters first, renegotiate when the
  /// sender rejects it (Windows always does — the step-1 verdict).
  Future<void> _reofferIngest(_FwdBranch branch) async {
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

  /// Remove a viewer from its branch; the LAST one starts the ~30 s linger
  /// (a quick re-watch shouldn't pay a full re-register round).
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
  /// fwd-room release, and — for an idle PEER branch with [demote] — restore
  /// the forwarder's own viewing to a direct per-viewer PC (revert-to-direct
  /// assign + offer), since without downstream viewers the engine detour
  /// buys nothing.
  Future<void> _teardownBranch(
    _FwdBranch branch, {
    required bool unregister,
    required bool demote,
  }) async {
    branch.linger?.cancel();
    branch.linger = null;
    _fwdBranches.remove(branch.forwarderId);
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

  /// Leave a forwarder's relay room once neither side needs it (no sharer
  /// branch AND no viewer assignment references it). NEVER for our OWN fwd
  /// room — the embedded engine's bridge owns that membership (phase 2).
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

  /// Viewer side of `vc_screen_assign`: the sharer routed us to a forwarder.
  /// Join its room and attach; the egress offer arrives as a ForwarderSignal.
  ///
  /// Phase 2 trust model: the assignment is authenticated as coming from the
  /// STREAM'S ORIGINATOR (Rust's `inbound_origin_ok` — origin must name the
  /// sender) and only honored for a share we explicitly watch, so the sharer
  /// may name ANY forwarder for its own stream — the VPS infra forwarder, a
  /// viewer-peer forwarder, or US (self-assignment: we were promoted, and
  /// our display switches to our own embedded engine's egress leg). The
  /// fwd_* signal-source gate stays per-assignment in _handleFwdEgressOffer.
  Future<void> _handleScreenAssign(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final origin = v['origin'];
    final originPeer = origin is Map ? (origin['peer'] as String? ?? '') : '';
    final forwarder = v['forwarder'] as String? ?? '';
    // Rust already dropped spoofed origins (origin must name the SENDER);
    // consent still gates here — only honored for a share we're watching.
    if (originPeer.isEmpty || !state.watchingScreenShares.contains(originPeer)) {
      return;
    }
    if (forwarder.isEmpty) {
      // Revert-to-direct: forget the assignment; the direct offer follows.
      final prev = _screenAssignments.remove(originPeer);
      _maybeLeaveFwdRoom(prev?.forwarder);
      // The promised direct offer can be withheld (the sharer gates offers
      // on a warm audio PC) — re-arm the watch timeout so a no-show walks
      // the ladder or gives up visibly instead of stranding the tile.
      if (state.watchingScreenShares.contains(originPeer) &&
          getScreenShareRenderer(originPeer) == null) {
        _watchConnectTimers.remove(originPeer)?.cancel();
        _watchConnectTimers[originPeer] =
            Timer(const Duration(seconds: 20), () {
          _watchConnectTimers.remove(originPeer);
          if (!state.watchingScreenShares.contains(originPeer)) return;
          if (getScreenShareRenderer(originPeer) != null) return;
          if ((_fwdFallbackCount[originPeer] ?? 0) < 2) {
            _fallbackToDirect(originPeer);
            return;
          }
          stopWatchingScreenShare(originPeer);
          _toast("Couldn't connect to the screen share",
              HollowToastType.error);
        });
      }
      return;
    }
    // Privacy hard gate: with "Always relay calls" on, a PEER forwarder leg
    // would expose our address to another member — only the operator-run
    // infra forwarder (same trust domain as TURN) is acceptable. The sharer
    // normally honors our relay_private flag; this catches buggy or
    // malicious sharers, at the cost of one ladder attempt.
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
    _screenAssignments[originPeer] = (
      forwarder: forwarder,
      kind: origin is Map ? (origin['kind'] as String? ?? 'screen') : 'screen',
      stream: origin is Map ? (origin['stream'] as String? ?? '') : '',
    );
    // Promotion replaces our existing direct leg for this origin: retire it
    // OURSELVES (map-first so its onDisconnected guard no-ops when the
    // sharer's side closes) — the engine egress offer re-populates it.
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
    _vcLog('[HOLLOW-VC] Assigned to ${isSelf ? "OUR OWN engine" : "forwarder"} '
        'for $originPeer — attaching');
  }

  /// Client-bound fwd_* signals (NetworkEvent.forwarderSignal). Gated hard:
  /// ingest answers only from OUR registered forwarder; egress offers only
  /// for origins we were assigned AND are watching, from that assignment's
  /// forwarder.
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
    }
  }

  /// The forwarder's egress offer for a stream we were assigned: identical
  /// attribution/SFrame/renderer path as a direct offer (D1's originator
  /// keys), with the forwarder as the DELIVERER. Replies a COMPLETE SDP.
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

  /// FwdError: walk the fallback ladder — the forwarder is an availability
  /// helper, never authority. Sharer side reverts its forwarder audience to
  /// direct offers; viewer side re-watches with route "direct_failed".
  Future<void> _handleFwdError(String fromPeer, Map<String, dynamic> v) async {
    final origin = v['origin'];
    final originPeer = origin is Map ? (origin['peer'] as String? ?? '') : '';
    final code = v['code'] as String? ?? '';
    // Sharer side: our stream/ingest was refused by one of our branches.
    final branch = _fwdBranches[fromPeer];
    if (branch != null && originPeer == (_shareOriginPeer ?? '')) {
      _vcLog('[HOLLOW-VC] Forwarder ${branch.forwarderId} refused our stream '
          '($code) — reverting its viewers');
      await _revertBranchViewersToDirect(branch);
      return;
    }
    // Viewer side: our attach was refused. A SELF-assigned display hitting
    // unknown_stream is (only ever) the local attach racing our sharer's
    // register — one bounded retry before laddering.
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

  /// Sharer-side fallback: [branch]'s forwarder refused or lost our ingest —
  /// tear that branch down and serve its viewers a direct per-viewer PC
  /// (revert-to-direct assign + offer, up to the 15-cap). The dead forwarder
  /// is remembered per viewer so a later re-watch never bounces them back
  /// onto it; a demoted PEER forwarder gets its own direct feed back via the
  /// teardown's demote path.
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

  /// Whether this client may serve as a viewer-peer forwarder (phase 2):
  /// desktop only, never mobile, gated on the "Peer media forwarding"
  /// Settings toggle (ON by default) — and NEVER while "Always relay calls"
  /// is on: serving means members connect straight to this machine, which is
  /// exactly the address exposure that setting promises away.
  bool _canForwardShares() {
    if (kIsWeb) return false;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return false;
    }
    if (ref.read(alwaysRelayCallsProvider)) return false;
    return ref.read(peerForwardingProvider);
  }

  /// Build a want=true screen_watch payload for [sharerPeer] — shared by the
  /// initial watch, the Source-quality re-watch, and the fallback ladder so
  /// the phase-2 capability flag can never drift between them. Advertising
  /// capability also arms the embedded engine's expectation for this origin
  /// (the abuse gate: we only ever forward streams we watch).
  Map<String, dynamic> _watchPayload(String sharerPeer,
      {required String route, required bool sourceQuality}) {
    final (viewerW, viewerH) = largestDisplayResolution();
    final canFwd = _canForwardShares();
    if (canFwd) {
      network_api
          .setForwarderExpectation(
              originPeer: sharerPeer, kind: 'screen', active: true)
          .catchError((_) {});
    }
    return {
      'want': true,
      'viewer_width': viewerW,
      'viewer_height': viewerH,
      'source_quality': sourceQuality,
      'route': route,
      'fwd_capable': canFwd,
      // Privacy: forced-relay viewers must only ever be routed through
      // OPERATOR infrastructure (TURN / the infra forwarder) — the sharer
      // skips the peer-forwarder rungs for them.
      'relay_private': ref.read(alwaysRelayCallsProvider),
    };
  }

  /// Viewer-side fallback: drop the assignment, detach, and re-watch with
  /// route "direct_failed" — the sharer descends its ladder (another
  /// forwarder rung, or today's direct+TURN path). Two attempts per watch
  /// session (peer forwarder + VPS forwarder); after that the normal 20 s
  /// watch timeout gives up with the toast.
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
            sourceQuality: state.sourceQualityShares.contains(originPeer),
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
    // we can actually show (media forwarding step 1), plus our route hint
    // (step 3) and phase-2 forwarding capability.
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
            sourceQuality: state.sourceQualityShares.contains(peerId),
          )),
        )
        .catchError((_) {});

    // If no offer produces a live track in time, revert so the tile/banner
    // doesn't spin forever (sharer at cap, signal lost, ...). A forwarder
    // assignment that never delivered walks the fallback ladder first.
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
    _incomingShareOrigins.remove(peerId);
    if (incoming != null) {
      await incoming.close();
      await _dropShareCryptors(peerId);
    }

    // Step 3: detach from the forwarder if this origin was served through it.
    // Phase 2: the watch ending also withdraws our forwarding offer for this
    // origin (the embedded engine stops accepting/serving its stream).
    network_api
        .setForwarderExpectation(
            originPeer: peerId, kind: 'screen', active: false)
        .catchError((_) {});
    _fwdFallbackCount.remove(peerId);
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
    final route = await _routeHintTo(peerId);
    network_api
        .voiceChannelSendSignal(
          serverId: state.currentServerId!,
          channelId: state.currentChannelId!,
          peerId: peerId,
          signalType: 'screen_watch',
          payload: jsonEncode(
              _watchPayload(peerId, route: route, sourceQuality: on)),
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
    _watcherRoutes.remove(peerId);
    // Phase 2 viewer side: their share ending ends our watch of it — the
    // forwarding offer and the ladder counter go with it.
    network_api
        .setForwarderExpectation(
            originPeer: peerId, kind: 'screen', active: false)
        .catchError((_) {});
    _fwdFallbackCount.remove(peerId);
    // Step 3 sharer side: drop the peer from its branch; a vanished PEER
    // FORWARDER takes its whole branch down (its viewers revert to direct
    // and re-ladder). PRESENCE-FLAP TOLERANCE (field-hit 2026-08-06, run 2:
    // the relay's ghost-socket eviction after an app restart broadcasts
    // PeerLeft while the SAME peer's live socket is still in the room — that
    // spurious signal tore down a working branch): when the branch has a
    // live ingest leg, the LEG is the truth — a genuinely dead forwarder
    // kills it within seconds and the leg's onDisconnected reverts then.
    // Only a branch with no leg to speak for it is torn down on presence.
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
    // Incoming shares are ORIGINATOR-keyed (media forwarding step 2): drop
    // the share this peer originated AND any share this peer was DELIVERING
    // (step-3 forwarder legs; on direct legs deliverer == originator so the
    // set collapses to the one key).
    final originsToDrop = <String>{
      if (_incomingScreenShares.containsKey(peerId)) peerId,
      ..._incomingShareOrigins.entries
          .where((e) => e.value.deliverer == peerId)
          .map((e) => e.key),
    };
    for (final origin in originsToDrop) {
      // PRESENCE-FLAP TOLERANCE (same field lesson as the branch above): if
      // the stream this peer DELIVERS to us is still rendering, the media
      // leg is the truth — a spurious PeerLeft (relay ghost eviction after
      // the deliverer's app restart) must not tear down a working share. A
      // genuinely dead deliverer kills the leg within seconds and its
      // onDisconnected walks the ladder.
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
      // Phase 2 ladder: [peerId] was only the DELIVERER of this stream — the
      // originator is still sharing and we still watch it, so losing the
      // deliverer must never strand the watch. Walk the fallback ladder (the
      // direct_failed re-watch lets the sharer descend to its next rung:
      // another forwarder, or a direct offer). Field-hit in run 2 of the
      // 2026-08-06 verification: this teardown was silent AND the sharer's
      // own revert offer was audio-PC-gated — "Connecting to screen
      // share..." forever. The re-watch rides the relay, so it heals even
      // while the direct audio PC to the sharer is down.
      if (origin != peerId &&
          state.watchingScreenShares.contains(origin) &&
          state.peerScreenSharing[origin] == true) {
        _fallbackToDirect(origin);
      }
    }
    // Close outgoing screen share to this peer (viewer-keyed transport leg).
    // _dropShareCryptors is idempotent, so a double drop when this peer's own
    // incoming share was also just torn down is a harmless no-op.
    final outgoing = _outgoingScreenShares.remove(peerId);
    if (outgoing != null) {
      await outgoing.close();
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

    // Step 3: leaving the channel drops every forwarder relationship — the
    // branches (sharer side) and all assignments (viewer side). Presence in
    // the fwd room is the forwarder's own cleanup signal too. Phase 2: our
    // engine expectations are withdrawn per watched origin.
    _watcherRoutes.clear();
    _viewerFwdFailures.clear();
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
      // FORWARDER BRANCH INGEST LEGS TOO (media forwarding step 3) — they
      // live outside the two maps above, and an ingest sender that misses a
      // rotation keeps encrypting under the OLD index: every viewer behind
      // that forwarder goes MissingKey/black while the heals bump epochs and
      // dig the hole deeper. Field-diagnosed 2026-08-06 (the "black on every
      // promotion" afternoon): the epoch sweep re-keyed 3 PCs and never the
      // branch ingest.
      for (final b in _fwdBranches.values) {
        final ingestPc = b.ingest?.pc;
        if (ingestPc != null) {
          await _enableSframeOnScreenSharePc(ingestPc, fc, b.forwarderId,
              isSender: true);
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
    // Share-PC cryptors live under 'screen:$peerId' — the voice rebind above
    // can't reach them (setKeyIndexForPeer prefix-matches '$peerId:'), so
    // re-run the idempotent share enable on both directions' PCs; it ends
    // with setKeyIndexForPeer('screen:$peerId', …) which is the actual heal.
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
      // A heal aimed at a peer we serve THROUGH a branch must reach the
      // branch's ingest sender as well (same key-index rule as the epoch
      // sweep — the ingest lives outside the two maps above).
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
