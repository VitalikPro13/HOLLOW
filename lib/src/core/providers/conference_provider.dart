import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/conference.dart' as conference_api;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Whether the desktop center pane shows the Conferences tab
/// (Archive/Share tab pattern).
final conferenceTabOpenProvider = StateProvider<bool>((ref) => false);

/// A conference is a virtual server: this is the server_id the voice-channel
/// machinery sees for a given conference room.
String conferenceServerId(String confId) => 'conf:$confId';

/// The fixed channel id inside a conference's virtual server.
const String kConferenceChannelId = 'main';

/// Where the local user stands in the active meeting's lobby flow.
enum ConferenceLobbyStatus {
  /// No active meeting.
  none,

  /// Joiner: knock sent, waiting for the host to admit us.
  waiting,

  /// Joiner: the host declined (see [ConferenceState.denyReason]).
  denied,

  /// Joiner: MLS Welcome landed — joining the call now (transient).
  admitted,

  /// In the call (host or admitted joiner).
  inCall,
}

/// Dart-side room model wrapping the FFI [conference_api.ConferenceInfo].
class ConferenceRoom {
  final String confId;
  final String name;
  final bool waitingRoom;
  final bool hasAccessCode;
  final bool broadcastMode;

  /// Millisecond epoch.
  final int createdAt;

  const ConferenceRoom({
    required this.confId,
    required this.name,
    required this.waitingRoom,
    required this.hasAccessCode,
    required this.broadcastMode,
    required this.createdAt,
  });

  factory ConferenceRoom.fromInfo(conference_api.ConferenceInfo info) =>
      ConferenceRoom(
        confId: info.confId,
        name: info.name,
        waitingRoom: info.waitingRoom,
        hasAccessCode: info.hasAccessCode,
        broadcastMode: info.broadcastMode,
        createdAt: info.createdAt.toInt(),
      );

  String get inviteLink => webConferenceInviteLink(confId);
}

/// Someone knocking on the host's waiting room. Carries the display name and
/// avatar HASH from the join request (light announce — never blobs); the
/// friend badge is computed locally from the host's own friend list.
class WaitingEntry {
  final String peerId;
  final String displayName;
  final String avatarHash;
  final bool isFriend;

  const WaitingEntry({
    required this.peerId,
    required this.displayName,
    required this.avatarHash,
    required this.isFriend,
  });
}

class ConferenceState {
  /// This device's rooms (host side), newest first.
  final List<ConferenceRoom> rooms;
  final bool roomsLoaded;

  /// The meeting we're hosting or trying to join (null = none).
  final String? activeConfId;
  final bool isHost;
  final ConferenceLobbyStatus lobbyStatus;

  /// Set when [lobbyStatus] is [ConferenceLobbyStatus.denied].
  final String? denyReason;

  /// Joiner-side lobby banner info (signed by the host, per the handshake).
  final String? hostPeerId;
  final String? hostName;
  final String? hostAvatarHash;

  /// Host side: knocks awaiting admit/deny.
  ///
  /// Meeting CHAT does not live here — it rides `channelChatProvider` under
  /// the RAM-only `'conf:<id>:main'` key so the screen-share chat drawer is
  /// the one and only conference chat surface (cleared on start/leave/end).
  final List<WaitingEntry> waiting;

  const ConferenceState({
    this.rooms = const [],
    this.roomsLoaded = false,
    this.activeConfId,
    this.isHost = false,
    this.lobbyStatus = ConferenceLobbyStatus.none,
    this.denyReason,
    this.hostPeerId,
    this.hostName,
    this.hostAvatarHash,
    this.waiting = const [],
  });

  bool get meetingActive => activeConfId != null;

  /// Virtual server id of the active meeting ('' when none).
  String get activeServerId =>
      activeConfId == null ? '' : conferenceServerId(activeConfId!);

  ConferenceRoom? roomById(String confId) =>
      rooms.where((r) => r.confId == confId).firstOrNull;

  ConferenceState copyWith({
    List<ConferenceRoom>? rooms,
    bool? roomsLoaded,
    String? activeConfId,
    bool? isHost,
    ConferenceLobbyStatus? lobbyStatus,
    String? denyReason,
    String? hostPeerId,
    String? hostName,
    String? hostAvatarHash,
    List<WaitingEntry>? waiting,
    bool clearActive = false,
  }) {
    if (clearActive) {
      return ConferenceState(
        rooms: rooms ?? this.rooms,
        roomsLoaded: roomsLoaded ?? this.roomsLoaded,
      );
    }
    return ConferenceState(
      rooms: rooms ?? this.rooms,
      roomsLoaded: roomsLoaded ?? this.roomsLoaded,
      activeConfId: activeConfId ?? this.activeConfId,
      isHost: isHost ?? this.isHost,
      lobbyStatus: lobbyStatus ?? this.lobbyStatus,
      denyReason: denyReason ?? this.denyReason,
      hostPeerId: hostPeerId ?? this.hostPeerId,
      hostName: hostName ?? this.hostName,
      hostAvatarHash: hostAvatarHash ?? this.hostAvatarHash,
      waiting: waiting ?? this.waiting,
    );
  }
}

class ConferenceNotifier extends Notifier<ConferenceState> {
  @override
  ConferenceState build() => const ConferenceState();

  // ── Desktop tab ─────────────────────────────────────────────────────────

  /// Open the desktop Conferences center tab: set our flag, clear every
  /// sibling tab + selection provider in one synchronous block (the
  /// bottom-bar `_openShare` pattern), then refresh the room list.
  void openTab() {
    final split = ref.read(splitViewProvider);
    if (split.isSplit) {
      ref.read(splitViewProvider.notifier).closeSplit();
    }
    setShellTab(ref.read, ShellTab.conference);
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    ref.read(selectedChannelProvider.notifier).state = null;
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
    unawaited(loadRooms());
  }

  // ── Room management (host side) ─────────────────────────────────────────

  Future<void> loadRooms() async {
    try {
      final infos = await conference_api.conferenceList();
      state = state.copyWith(
        rooms: infos.map(ConferenceRoom.fromInfo).toList(),
        roomsLoaded: true,
      );
    } catch (e) {
      debugPrint('[HOLLOW-CONF] loadRooms failed: $e');
    }
  }

  /// Create a room. Empty [accessCode] means "no code".
  Future<ConferenceRoom?> createRoom({
    required String name,
    required bool waitingRoom,
    String? accessCode,
    bool broadcastMode = false,
  }) async {
    try {
      final info = await conference_api.conferenceUpsert(
        name: name,
        waitingRoom: waitingRoom,
        accessCode: (accessCode == null || accessCode.isEmpty)
            ? null
            : accessCode,
        broadcastMode: broadcastMode,
      );
      final room = ConferenceRoom.fromInfo(info);
      state = state.copyWith(rooms: [
        room,
        ...state.rooms.where((r) => r.confId != room.confId),
      ]);
      return room;
    } catch (e) {
      _toast('Failed to create room: $e', HollowToastType.error);
      return null;
    }
  }

  /// Update a room. [accessCode] follows the FFI COALESCE convention:
  /// null = keep the existing code, '' = clear it, value = set a new one.
  Future<ConferenceRoom?> updateRoom({
    required String confId,
    required String name,
    required bool waitingRoom,
    String? accessCode,
    required bool broadcastMode,
  }) async {
    try {
      final info = await conference_api.conferenceUpsert(
        confId: confId,
        name: name,
        waitingRoom: waitingRoom,
        accessCode: accessCode,
        broadcastMode: broadcastMode,
      );
      final room = ConferenceRoom.fromInfo(info);
      state = state.copyWith(
        rooms: [
          for (final r in state.rooms)
            if (r.confId == confId) room else r,
        ],
      );
      return room;
    } catch (e) {
      _toast('Failed to update room: $e', HollowToastType.error);
      return null;
    }
  }

  /// Delete a room — retires its link forever. Ends the meeting first when
  /// it's the one currently active.
  Future<void> deleteRoom(String confId) async {
    if (state.activeConfId == confId) {
      if (state.isHost) {
        await endMeeting();
      } else {
        await leaveMeeting();
      }
    }
    try {
      await conference_api.conferenceDelete(confId: confId);
    } catch (e) {
      _toast('Failed to delete room: $e', HollowToastType.error);
      return;
    }
    state = state.copyWith(
      rooms: state.rooms.where((r) => r.confId != confId).toList(),
    );
  }

  // ── Meeting lifecycle ───────────────────────────────────────────────────

  /// (Host) start a meeting for [room] and join its call.
  Future<void> startMeeting(ConferenceRoom room) async {
    if (ref.read(callProvider).status != CallStatus.idle) {
      _toast('Leave your call first', HollowToastType.error);
      return;
    }
    if (state.activeConfId == room.confId &&
        state.lobbyStatus == ConferenceLobbyStatus.inCall) {
      return; // Already in this meeting.
    }
    if (state.meetingActive) {
      // Hosting/attending another meeting — leave it first.
      if (state.isHost) {
        await endMeeting();
      } else {
        await leaveMeeting();
      }
    }

    final myId = ref.read(identityProvider).peerId ?? '';
    final (displayName, avatarHash) = _ownProfileLight();
    try {
      await conference_api.conferenceStart(
        confId: room.confId,
        hostDisplayName: displayName,
        hostAvatarHash: avatarHash,
      );
    } catch (e) {
      _toast('Failed to start meeting: $e', HollowToastType.error);
      return;
    }
    _clearConfChat(room.confId);
    state = state.copyWith(
      activeConfId: room.confId,
      isHost: true,
      lobbyStatus: ConferenceLobbyStatus.inCall,
      hostPeerId: myId,
      hostName: displayName,
      waiting: const [],
    );
    await ref
        .read(voiceChannelProvider.notifier)
        .joinChannel(conferenceServerId(room.confId), kConferenceChannelId);
  }

  /// (Host) end the meeting for everyone. The room + link survive.
  Future<void> endMeeting() async {
    final confId = state.activeConfId;
    if (confId == null || !state.isHost) return;
    await _leaveVoiceIfInConference(confId);
    try {
      await conference_api.conferenceEnd(confId: confId);
    } catch (e) {
      debugPrint('[HOLLOW-CONF] conferenceEnd failed: $e');
    }
    _clearConfChat(confId);
    state = state.copyWith(clearActive: true);
  }

  /// (Joiner) knock on a conference: enters the relay room and sends the join
  /// request. Progress arrives via ConferenceLobbyInfo / Admitted / Denied.
  Future<void> requestJoin(String confId, {String? accessCode}) async {
    if (ref.read(callProvider).status != CallStatus.idle) {
      _toast('Leave your call first', HollowToastType.error);
      return;
    }

    // Self-check: our OWN room's link means "start the meeting", not "knock
    // on our own door" (the host handler ignores self-knocks, so the lobby
    // would wait forever).
    if (!state.roomsLoaded) await loadRooms();
    final ownRoom = state.roomById(confId);
    if (ownRoom != null) {
      if (state.activeConfId == confId && state.isHost) return; // already in
      _toast('This is your room — starting the meeting',
          HollowToastType.info);
      await startMeeting(ownRoom);
      return;
    }
    if (state.meetingActive && state.activeConfId != confId) {
      if (state.isHost) {
        await endMeeting();
      } else {
        await leaveMeeting();
      }
    }

    final retrying = state.activeConfId == confId;
    state = state.copyWith(
      activeConfId: confId,
      isHost: false,
      lobbyStatus: ConferenceLobbyStatus.waiting,
      denyReason: null,
      // Keep the lobby banner info across a wrong-code retry.
      hostPeerId: retrying ? state.hostPeerId : null,
      hostName: retrying ? state.hostName : null,
      hostAvatarHash: retrying ? state.hostAvatarHash : null,
      waiting: const [],
    );
    if (!retrying) _clearConfChat(confId);

    final (displayName, avatarHash) = _ownProfileLight();
    try {
      await conference_api.conferenceRequestJoin(
        confId: confId,
        displayName: displayName,
        avatarHash: avatarHash,
        accessCode: accessCode,
      );
    } catch (e) {
      if (state.activeConfId == confId) {
        state = state.copyWith(
          lobbyStatus: ConferenceLobbyStatus.denied,
          denyReason: 'request_failed',
        );
      }
      debugPrint('[HOLLOW-CONF] requestJoin failed: $e');
    }
  }

  /// (Host) admit a waiting-room entry — Rust commits the MLS add.
  Future<void> admit(String peerId) async {
    final confId = state.activeConfId;
    if (confId == null || !state.isHost) return;
    try {
      await conference_api.conferenceAdmit(confId: confId, peerId: peerId);
    } catch (e) {
      _toast('Failed to admit: $e', HollowToastType.error);
      return;
    }
    state = state.copyWith(
      waiting: state.waiting.where((w) => w.peerId != peerId).toList(),
    );
  }

  /// (Host) decline a waiting-room entry.
  Future<void> deny(String peerId) async {
    final confId = state.activeConfId;
    if (confId == null || !state.isHost) return;
    try {
      await conference_api.conferenceDeny(
          confId: confId, peerId: peerId, reason: 'declined');
    } catch (e) {
      debugPrint('[HOLLOW-CONF] deny failed: $e');
    }
    state = state.copyWith(
      waiting: state.waiting.where((w) => w.peerId != peerId).toList(),
    );
  }

  /// Leave the active meeting (joiner, or a host abandoning the lobby flow
  /// without ending for everyone — v1 hosts use [endMeeting]).
  Future<void> leaveMeeting() async {
    final confId = state.activeConfId;
    if (confId == null) return;
    await _leaveVoiceIfInConference(confId);
    try {
      await conference_api.conferenceLeave(confId: confId);
    } catch (e) {
      debugPrint('[HOLLOW-CONF] conferenceLeave failed: $e');
    }
    _clearConfChat(confId);
    state = state.copyWith(clearActive: true);
  }

  /// Wipe a meeting's RAM state — chat (channelChatProvider 'conf:...' keys)
  /// AND the tracked remote participants — on start/leave/end. A previous
  /// meeting's members otherwise linger as stale tiles: their leave broadcast
  /// races the host's room-leave/group-drop and never lands, and restarting
  /// the room reuses the same virtual server id.
  void _clearConfChat(String confId) {
    final sid = conferenceServerId(confId);
    ref.read(channelChatProvider.notifier).clearServerCache(sid);
    ref.read(voiceChannelProvider.notifier).clearServerParticipants(sid);
  }

  // ── Event handlers (called from event_provider) ─────────────────────────

  void onJoinRequest(
      String confId, String peerId, String displayName, String avatarHash) {
    if (!state.isHost || state.activeConfId != confId) return;
    if (state.waiting.any((w) => w.peerId == peerId)) return;
    // Friend badge from OUR OWN friend list only (no graph queries): collapse
    // the knocking device to its master identity first.
    final master = ref.read(deviceLinkProvider).identityOf(peerId);
    final isFriend = ref.read(friendsProvider)[master]?.status == 'accepted';
    state = state.copyWith(waiting: [
      ...state.waiting,
      WaitingEntry(
        peerId: peerId,
        displayName: displayName,
        avatarHash: avatarHash,
        isFriend: isFriend,
      ),
    ]);
  }

  void onLobbyInfo(
      String confId, String hostPeerId, String hostName, String hostAvatarHash) {
    if (state.activeConfId != confId || state.isHost) return;
    state = state.copyWith(
      hostPeerId: hostPeerId,
      hostName: hostName,
      hostAvatarHash: hostAvatarHash,
    );
  }

  /// (Joiner) admitted — the conference MLS Welcome landed; join the call.
  Future<void> onAdmitted(String confId) async {
    if (state.activeConfId != confId || state.isHost) return;
    state = state.copyWith(lobbyStatus: ConferenceLobbyStatus.admitted);
    await ref
        .read(voiceChannelProvider.notifier)
        .joinChannel(conferenceServerId(confId), kConferenceChannelId);
    if (state.activeConfId == confId) {
      state = state.copyWith(lobbyStatus: ConferenceLobbyStatus.inCall);
    }
  }

  void onDenied(String confId, String reason) {
    if (state.activeConfId != confId || state.isHost) return;
    state = state.copyWith(
      lobbyStatus: ConferenceLobbyStatus.denied,
      denyReason: reason,
    );
  }

  /// Meeting over. Only honored when [byPeerId] is the host we know about
  /// (device→master collapsed) — anyone else claiming "ended" is ignored.
  Future<void> onEnded(String confId, String byPeerId) async {
    if (state.activeConfId != confId) return;
    final links = ref.read(deviceLinkProvider);
    final expectedHost =
        state.hostPeerId ?? (ref.read(identityProvider).peerId ?? '');
    if (expectedHost.isNotEmpty &&
        !links.sameIdentity(byPeerId, expectedHost)) {
      debugPrint(
          '[HOLLOW-CONF] Ignoring ConferenceEnded from non-host $byPeerId');
      return;
    }
    await _leaveVoiceIfInConference(confId);
    try {
      await conference_api.conferenceLeave(confId: confId);
    } catch (_) {}
    _clearConfChat(confId);
    state = state.copyWith(clearActive: true);
    _toast('Meeting ended', HollowToastType.info);
  }

  /// (Host) remove a CURRENT member — Rust commits the MLS remove (their
  /// SFrame key rotates away) and sends the teardown signal.
  Future<void> kick(String peerId) async {
    final confId = state.activeConfId;
    if (confId == null || !state.isHost) return;
    try {
      await conference_api.conferenceKick(confId: confId, peerId: peerId);
    } catch (e) {
      _toast('Failed to remove: $e', HollowToastType.error);
    }
  }

  /// We were removed by the host — same host validation as [onEnded]
  /// (a random member can't fake-kick us out of the UI; the cryptographic
  /// removal already happened either way).
  Future<void> onKicked(String confId, String byPeerId) async {
    if (state.activeConfId != confId || state.isHost) return;
    final links = ref.read(deviceLinkProvider);
    final expectedHost = state.hostPeerId;
    if (expectedHost != null &&
        expectedHost.isNotEmpty &&
        !links.sameIdentity(byPeerId, expectedHost)) {
      debugPrint(
          '[HOLLOW-CONF] Ignoring ConferenceKicked from non-host $byPeerId');
      return;
    }
    await _leaveVoiceIfInConference(confId);
    try {
      await conference_api.conferenceLeave(confId: confId);
    } catch (_) {}
    _clearConfChat(confId);
    state = state.copyWith(clearActive: true);
    _toast('You were removed from the meeting', HollowToastType.info);
  }

  // ── Internals ───────────────────────────────────────────────────────────

  Future<void> _leaveVoiceIfInConference(String confId) async {
    final vc = ref.read(voiceChannelProvider);
    if (vc.currentServerId == conferenceServerId(confId)) {
      await ref.read(voiceChannelProvider.notifier).leaveChannel();
    }
  }

  /// Own display name + avatar hash for handshakes. Light-announce rule:
  /// hashes only, never blobs — the local profile cache doesn't expose the
  /// avatar hash, so v1 sends an empty hash (receivers fall back to initials).
  (String, String) _ownProfileLight() {
    final myId = ref.read(identityProvider).peerId ?? '';
    final profile = ref.read(profileProvider)[myId];
    return (displayNameForPeer(profile, myId), '');
  }

  void _toast(String message, HollowToastType type) {
    final ctx = hollowNavigatorKey.currentContext;
    final overlay = hollowNavigatorKey.currentState?.overlay;
    if (ctx == null || overlay == null) return;
    HollowToast.show(ctx, message, type: type, overlayState: overlay);
  }
}

final conferenceProvider =
    NotifierProvider<ConferenceNotifier, ConferenceState>(
        ConferenceNotifier.new);
