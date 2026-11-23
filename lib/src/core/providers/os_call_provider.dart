import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../age_gate.dart';
import '../hidden_notification.dart';
import 'app_lock_provider.dart';
import 'call_provider.dart';
import 'conference_provider.dart';
import 'device_link_provider.dart';
import 'duress_provider.dart';
import 'local_nickname_provider.dart';
import 'profile_provider.dart';
import 'server_provider.dart';
import 'shell_tab.dart' show ProviderRead;
import 'system_notification_provider.dart' show notificationContentAllowed;
import 'voice_channel_provider.dart';

/// What the OS is told the session is (#154, DESIGN_OS_CALLS 1.1).
enum OsCallKind { dm, room, meeting }

/// The one live session this device mirrors to the OS (CallKit, Telecom): a DM
/// call from the moment it is answered (ours or theirs), a voice room, or a
/// meeting. Never a ring either way (decision Q2): a call ringing out under
/// CallKit plays the ringback as call audio, at the ear. The title is not
/// here: it is fixed when the OS call begins (`osCallTitle`), so nothing that
/// changes mid-call renames it.
@immutable
class OsSession {
  /// `dm:<callId>`, `vc:<server>/<channel>` or `meet:<confId>`; a media
  /// rebuild keeps it, so the OS call outlives the rebuild.
  final String key;
  final OsCallKind kind;

  /// Connected: a DM answered, a room or meeting at once.
  final bool live;
  final bool muted;
  final bool video;

  /// Informational: both platforms report every session as a placed call.
  final bool outgoing;

  const OsSession({
    required this.key,
    required this.kind,
    required this.live,
    required this.muted,
    required this.video,
    required this.outgoing,
  });

  @override
  bool operator ==(Object other) =>
      other is OsSession &&
      other.key == key &&
      other.kind == kind &&
      other.live == live &&
      other.muted == muted &&
      other.video == video &&
      other.outgoing == outgoing;

  @override
  int get hashCode => Object.hash(key, kind, live, muted, video, outgoing);

  @override
  String toString() =>
      'OsSession($key, ${kind.name}, live=$live, muted=$muted, video=$video)';
}

/// Lets host tests stand in for a phone.
@visibleForTesting
bool? debugOsCallPlatform;

/// Phones and tablets mirror calls to the OS (CallKit, Telecom); desktops
/// build nothing.
bool get osCallPlatform =>
    debugOsCallPlatform ?? (Platform.isIOS || Platform.isAndroid);

/// Lets host tests stand in for an Android phone.
@visibleForTesting
bool? debugOsCallRingOutService;

/// Android runs its call service (no OS call) while a call we place rings:
/// the microphone foreground type cannot be taken once the app is in the
/// background, and the answer can arrive after the person left the app.
bool get osCallRingOutService =>
    debugOsCallRingOutService ?? Platform.isAndroid;

/// Lets host tests stand in for an Android phone's call notification.
@visibleForTesting
bool? debugOsCallAvatars;

/// Only Android's call notification shows the DM friend's face; CallKit has
/// no place for one.
bool get osCallAvatars => debugOsCallAvatars ?? Platform.isAndroid;

/// Whether a DM call titled [title] may carry the friend's face: on Android,
/// and only while its title is a name. Whatever hides the name (HOL-SEC-155,
/// a name not known yet) hides the face.
bool osCallShowsAvatar(String title) =>
    osCallAvatars &&
    title.trim().isNotEmpty &&
    title != kHiddenNotificationTitle;

/// The MASTER of the DM call's peer, or null.
String? osCallPeerMaster(ProviderRead read) {
  final peer = read(callProvider).peerId;
  return peer == null ? null : read(deviceLinkProvider).identityOf(peer);
}

/// A call we placed that still rings out (never an OS call, decision Q2).
bool ringsOut(CallState call) =>
    call.callId != null &&
    call.status == CallStatus.ringing &&
    call.direction == CallDirection.outgoing;

/// The session, from provider state alone. A DM call goes first: accepting
/// one from inside a room sets it connecting before the room is left, and the
/// OS must follow the call the person chose.
OsSession? deriveOsSession({
  required CallState call,
  required VoiceChannelState voice,
  required ConferenceState conference,
}) {
  final callId = call.callId;
  if (callId != null) {
    final outgoing = call.direction == CallDirection.outgoing;
    if (call.status == CallStatus.connecting ||
        call.status == CallStatus.active) {
      return OsSession(
        key: 'dm:$callId',
        kind: OsCallKind.dm,
        live: call.status == CallStatus.active,
        muted: call.isMuted,
        video: call.isVideoCall ||
            call.isVideoEnabled ||
            call.remoteVideoEnabled ||
            call.isScreenSharing ||
            call.remoteScreenSharing,
        outgoing: outgoing,
      );
    }
  }
  final serverId = voice.currentServerId;
  final channelId = voice.currentChannelId;
  if (serverId == null || channelId == null) return null;
  final video = voice.isCameraOn ||
      voice.isScreenSharing ||
      voice.peerCameraOn.values.any((on) => on) ||
      voice.peerScreenSharing.values.any((on) => on);
  final confId = conference.activeConfId;
  final meeting = confId != null && serverId == conference.activeServerId;
  if (meeting || serverId.startsWith('conf:')) {
    return OsSession(
      key: 'meet:${meeting ? confId : serverId.substring(5)}',
      kind: OsCallKind.meeting,
      live: true,
      muted: voice.isMuted,
      video: video,
      outgoing: true,
    );
  }
  return OsSession(
    key: 'vc:$serverId/$channelId',
    kind: OsCallKind.room,
    live: true,
    muted: voice.isMuted,
    video: video,
    outgoing: true,
  );
}

final osSessionProvider = Provider<OsSession?>((ref) {
  if (!osCallPlatform) return null;
  return deriveOsSession(
    call: ref.watch(callProvider),
    voice: ref.watch(voiceChannelProvider),
    conference: ref.watch(conferenceProvider),
  );
});

/// Whether the OS call may carry a name: the phone notification rule
/// (HOL-SEC-155), watched so the title can blank when it stops holding.
final osContentAllowedProvider = Provider<bool>((ref) {
  ref.watch(appLockedProvider);
  ref.watch(identityProtectionProvider);
  return notificationContentAllowed(ref.read, mobile: true);
});

/// The name the OS shows for [session], read once when its OS call begins:
/// the person, `<channel> · <server>`, or the meeting, and only while a phone
/// notification may show content. Never an id: anything not known yet, or any
/// failure, is "Hollow".
String osCallTitle(ProviderRead read, OsSession session) {
  try {
    if (!notificationContentAllowed(read, mobile: true)) {
      return kHiddenNotificationTitle;
    }
    final String? name = switch (session.kind) {
      OsCallKind.dm => _dmName(read),
      OsCallKind.room => _roomName(read),
      OsCallKind.meeting => _meetingName(read),
    };
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? kHiddenNotificationTitle : trimmed;
  } catch (_) {
    return kHiddenNotificationTitle;
  }
}

/// The ring-out notification's name, by the same rule as a DM call's title.
String osRingOutTitle(ProviderRead read) => osCallTitle(
    read,
    const OsSession(
        key: 'ring',
        kind: OsCallKind.dm,
        live: false,
        muted: false,
        video: false,
        outgoing: true));

String? _dmName(ProviderRead read) {
  final master = osCallPeerMaster(read);
  if (master == null) return null;
  final nick = read(localNicknameProvider)[master];
  if (nick != null && nick.trim().isNotEmpty) return nick;
  return read(profileProvider)[master]?.displayName;
}

String? _roomName(ProviderRead read) {
  final voice = read(voiceChannelProvider);
  final serverId = voice.currentServerId;
  final channel = voice.currentChannelName;
  if (serverId == null || channel == null || channel.trim().isEmpty) {
    return null;
  }
  // An 18+ server this phone hides is never named on any surface.
  if (read(serverAgeHiddenProvider(serverId))) return null;
  final server = read(keptServersProvider)[serverId]?.name.trim() ?? '';
  return server.isEmpty ? channel : '$channel · $server';
}

String? _meetingName(ProviderRead read) {
  final conference = read(conferenceProvider);
  final confId = conference.activeConfId;
  if (confId == null) return null;
  if (conference.isHost) return conference.roomById(confId)?.name;
  final host = conference.hostName?.trim() ?? '';
  return host.isEmpty ? null : 'Meeting with $host';
}
