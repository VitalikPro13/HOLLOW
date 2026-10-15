import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/overlay_mic_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/overlay_server.dart' as server_api;
import 'package:hollow/src/theme/hollow_theme.dart';

/// Feeds the OBS overlay server (#97, plan 7 and 16.4): a snapshot of who is
/// shown and how, whenever that changes, and the live speaking states while a
/// page streams. It listens outside any widget and only while the server
/// runs, so Hollow's own UI pays nothing for it.

/// Snapshots and live updates each go out at most this often (20 per second).
const Duration kOverlayPublishGap = Duration(milliseconds: 50);

/// Where people not added to the overlay are numbered from, for the session.
const int kOverlayTransientSlotBase = 1000;

/// One person in our voice room: a MASTER and the devices of theirs seated
/// there.
@immutable
class OverlayRoomEntry {
  final String master;
  final List<String> devices;
  const OverlayRoomEntry(this.master, this.devices);

  @override
  bool operator ==(Object other) =>
      other is OverlayRoomEntry &&
      other.master == master &&
      listEquals(other.devices, devices);

  @override
  int get hashCode => Object.hash(master, Object.hashAll(devices));
}

enum OverlayRoomKind { none, voiceChannel, dmCall }

/// The voice room we sit in (a voice channel, a meeting or a DM call), with
/// the mute and deafen flags the overlay draws. Never contains us.
@immutable
class OverlayRoom {
  final OverlayRoomKind kind;
  final List<OverlayRoomEntry> members;
  final bool selfMuted;
  final bool selfDeafened;

  /// Remote DEVICE id -> its mute and deafen flags.
  final Map<String, ({bool muted, bool deafened})> deviceAudio;

  const OverlayRoom({
    this.kind = OverlayRoomKind.none,
    this.members = const [],
    this.selfMuted = false,
    this.selfDeafened = false,
    this.deviceAudio = const {},
  });

  static const empty = OverlayRoom();

  bool get inRoom => kind != OverlayRoomKind.none;

  @override
  bool operator ==(Object other) =>
      other is OverlayRoom &&
      other.kind == kind &&
      listEquals(other.members, members) &&
      other.selfMuted == selfMuted &&
      other.selfDeafened == selfDeafened &&
      mapEquals(other.deviceAudio, deviceAudio);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(members), selfMuted,
      selfDeafened, Object.hashAll(deviceAudio.keys));
}

/// Our room from the call providers. Participants are DEVICE ids and collapse
/// to their MASTER; we are left out by our master, our own device, and any
/// device of ours (a sibling in the same room is still us).
OverlayRoom overlayRoomFrom({
  required VoiceChannelState vc,
  required CallState call,
  required String Function(String) identityOf,
  required String me,
  String? myDevice,
}) {
  final server = vc.currentServerId;
  final channel = vc.currentChannelId;
  if (server != null && channel != null) {
    final byMaster = <String, List<String>>{};
    final audio = <String, ({bool muted, bool deafened})>{};
    for (final device in vc.getParticipants(server, channel)) {
      if (device == me || device == myDevice) continue;
      final master = identityOf(device);
      if (master == me) continue;
      byMaster.putIfAbsent(master, () => []).add(device);
      final a = vc.getPeerAudioState(device);
      audio[device] = (muted: a.isMuted, deafened: a.isDeafened);
    }
    return OverlayRoom(
      kind: OverlayRoomKind.voiceChannel,
      members: [
        for (final e in byMaster.entries)
          OverlayRoomEntry(e.key, List.unmodifiable(e.value..sort())),
      ],
      selfMuted: vc.isMuted,
      selfDeafened: vc.isDeafened,
      deviceAudio: audio,
    );
  }
  final peer = call.peerId;
  if (call.status == CallStatus.active && peer != null) {
    final master = identityOf(peer);
    return OverlayRoom(
      kind: OverlayRoomKind.dmCall,
      members: [
        if (master != me) OverlayRoomEntry(master, [peer]),
      ],
      selfMuted: call.isMuted,
      selfDeafened: call.isDeafened,
      deviceAudio: {
        peer: (muted: call.remoteMuted, deafened: call.remoteDeafened),
      },
    );
  }
  return OverlayRoom.empty;
}

/// [overlayRoomFrom] over the live providers.
final overlayRoomProvider = Provider<OverlayRoom>((ref) {
  final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';
  return overlayRoomFrom(
    vc: ref.watch(voiceChannelProvider),
    call: ref.watch(callProvider),
    identityOf: ref.watch(deviceLinkProvider).identityOf,
    me: me,
    myDevice: ref.watch(localDevicePeerIdProvider).valueOrNull,
  );
});

/// Slots for people in the room we did not add: from 1000 up, the same for a
/// person all session, never reused.
class OverlayTransientSlots {
  final Map<String, int> _slots = {};
  int _next = kOverlayTransientSlotBase;

  int slotFor(String master) => _slots[master] ??= _next++;
}

/// A slot in the last snapshot: what the live feed reports for.
@immutable
class OverlaySlotEntry {
  final int slot;
  final String master;
  final bool isSelf;
  final bool inRoom;
  final List<String> devices;

  const OverlaySlotEntry({
    required this.slot,
    required this.master,
    required this.isSelf,
    required this.inRoom,
    this.devices = const [],
  });
}

/// A snapshot as published, and the slots it names.
class OverlaySnapshot {
  final String json;
  final List<OverlaySlotEntry> entries;
  const OverlaySnapshot(this.json, this.entries);
}

/// Builds the snapshot of plan 16.4. Ourselves first in slot 0, then the
/// room in its order, then added people who are not in the room. Someone
/// whose field says "off" is left out; everyone else carries `master` (Rust
/// drops a person without one). Added people keep their slot and are drawn
/// with their EFFECTIVE look; others get a transient slot and their avatar.
OverlaySnapshot buildOverlaySnapshot({
  required String me,
  required String selfName,
  required String selfColour,
  required OverlayLook ownLook,
  required OverlayRoom room,
  required List<OverlayPerson> added,
  required String Function(String master) fieldOf,
  required String Function(String master) nameOf,
  required String Function(String master) colourOf,
  required OverlayLayout layout,
  required OverlayTransientSlots slots,
}) {
  final people = <Map<String, dynamic>>[];
  final entries = <OverlaySlotEntry>[];
  final addedBy = {
    for (final p in added)
      if (p.master != me) p.master: p,
  };

  people.add({
    'slot': 0,
    'master': me,
    'is_self': true,
    'in_room': true,
    'added': false,
    'name': selfName,
    'colour': selfColour,
    'look': ownLook.toMap(),
  });
  entries.add(OverlaySlotEntry(slot: 0, master: me, isSelf: true, inRoom: true));

  void addPerson(String master, {required bool inRoom, List<String> devices = const []}) {
    final person = addedBy[master];
    final field = person?.field ?? fieldOf(master);
    if (field == 'off') return;
    final slot = person?.slot ?? slots.slotFor(master);
    people.add({
      'slot': slot,
      'master': master,
      'is_self': false,
      'in_room': inRoom,
      'added': person != null,
      'name': nameOf(master),
      'colour': colourOf(master),
      'look': person == null ? null : _lookMap(person),
    });
    entries.add(OverlaySlotEntry(
        slot: slot, master: master, isSelf: false, inRoom: inRoom, devices: devices));
  }

  final inRoom = <String>{};
  for (final m in room.members) {
    if (m.master == me || !inRoom.add(m.master)) continue;
    addPerson(m.master, inRoom: true, devices: m.devices);
  }
  for (final p in added) {
    if (p.master == me || inRoom.contains(p.master)) continue;
    addPerson(p.master, inRoom: false);
  }

  final json = jsonEncode({'v': 1, 'layout': layout.toJson(), 'people': people});
  return OverlaySnapshot(json, entries);
}

Object? _lookMap(OverlayPerson p) {
  try {
    final m = jsonDecode(p.effectiveJson);
    if (m is Map) return m;
  } catch (_) {}
  return p.effective.toMap();
}

/// What the live feed reads for one tick.
class OverlayLiveInputs {
  final OverlayRoom room;
  final bool selfTalking;
  final double selfLevel;
  final bool listening;

  /// Remote DEVICE ids speaking right now.
  final Set<String> speaking;

  /// Remote DEVICE id -> level 0..1.
  final Map<String, double> levels;

  const OverlayLiveInputs({
    required this.room,
    required this.selfTalking,
    required this.selfLevel,
    required this.listening,
    this.speaking = const {},
    this.levels = const {},
  });
}

const _stateRank = {'talking': 0, 'idle': 1, 'muted': 2, 'deafened': 3};

String _deviceState({required bool muted, required bool deafened, required bool talking}) =>
    deafened ? 'deafened' : muted ? 'muted' : talking ? 'talking' : 'idle';

/// The live feed of plan 16.4 for the slots in the room. Within one device
/// mute and deafen win over talking; across one person's devices the most
/// active device speaks for them.
String buildOverlayLive(List<OverlaySlotEntry> entries, OverlayLiveInputs input) {
  final room = input.room;
  final people = <Map<String, dynamic>>[];
  for (final e in entries) {
    if (!e.inRoom) continue;
    var state = 'idle';
    var level = 0.0;
    if (e.isSelf) {
      final active = room.inRoom || input.listening;
      state = !active
          ? 'idle'
          : _deviceState(
              muted: room.inRoom && room.selfMuted,
              deafened: room.inRoom && room.selfDeafened,
              talking: input.selfTalking);
      level = active ? input.selfLevel : 0.0;
    } else {
      var best = 'deafened';
      var any = false;
      for (final d in e.devices) {
        final a = room.deviceAudio[d];
        final s = _deviceState(
            muted: a?.muted ?? false,
            deafened: a?.deafened ?? false,
            talking: input.speaking.contains(d));
        if (!any || _stateRank[s]! < _stateRank[best]!) best = s;
        any = true;
        if (s == 'talking' || s == 'idle') {
          final l = input.levels[d] ?? 0.0;
          if (l > level) level = l;
        }
      }
      state = any ? best : 'idle';
    }
    if (state == 'muted' || state == 'deafened') level = 0.0;
    people.add({'slot': e.slot, 'state': state, 'level': level});
  }
  return jsonEncode({
    'people': people,
    'self_active': room.inRoom || input.listening,
  });
}

/// `#rrggbb` for a colour.
String overlayHexColour(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The two FFI calls, swappable in tests.
@visibleForTesting
Future<void> Function(String json) overlayPublishSnapshotCall =
    (json) => server_api.overlayPublish(snapshotJson: json);
@visibleForTesting
Future<void> Function(String json) overlayPublishLiveCall =
    (json) => server_api.overlayPublishLive(liveJson: json);

/// The one publisher, created by the shell after the node starts.
final overlayPublisherProvider = Provider<OverlayPublisher>((ref) {
  final p = OverlayPublisher(ref.container);
  ref.onDispose(p.dispose);
  p.start();
  return p;
});

class OverlayPublisher {
  OverlayPublisher(this._c);

  final ProviderContainer _c;

  final OverlayTransientSlots _slots = OverlayTransientSlots();
  final List<ProviderSubscription<Object?>> _subs = [];
  ProviderSubscription<bool>? _runningSub;

  OverlaySnapshot? _snapshot;
  String? _lastLive;

  late final _snapLane = _Lane(_flushSnapshot);
  late final _liveLane = _Lane(_flushLive);

  final Map<double, HollowTheme> _themes = {};

  bool get attached => _subs.isNotEmpty;

  /// The last snapshot sent; null while the server is off.
  OverlaySnapshot? get lastSnapshot => _snapshot;

  void start() {
    _runningSub = _c.listen<bool>(overlayServerRunningProvider, (_, running) {
      running ? _attach() : _detach();
    }, fireImmediately: true);
  }

  void dispose() {
    _runningSub?.close();
    _detach();
  }

  void _attach() {
    if (attached) return;
    void snap(Object? _, Object? _) => _markSnapshot();
    void live(Object? _, Object? _) => _markLive();
    _subs.addAll([
      _c.listen<OverlayRoom>(overlayRoomProvider, snap),
      _c.listen(overlayPeopleProvider, snap),
      _c.listen<AsyncValue<OverlayOwn>>(overlayOwnProvider, (_, own) {
        _feedHold(own.valueOrNull?.look);
        _markSnapshot();
      }),
      _c.listen<OverlayLayout>(overlayLayoutProvider, snap),
      _c.listen(profileProvider, snap),
      _c.listen<double>(accentHueProvider, snap),
      _c.listen<int>(overlayFieldRevisionProvider, snap),
      _c.listen<String?>(identityProvider.select((s) => s.peerId), snap),
      _c.listen<int>(overlayOpenStreamsProvider, live),
      _c.listen<Set<String>>(vcSpeakingProvider, live),
      _c.listen<bool>(vcLocalSpeakingProvider, live),
      _c.listen(callSpeakingProvider, live),
      _c.listen<bool>(overlayMicSpeakingProvider, live),
      _c.listen<bool>(overlayMicProvider.select((s) => s.listening), live),
      _c.listen<Map<String, double>>(vcLevelsProvider, live),
      _c.listen<double>(vcLocalLevelProvider, live),
      _c.listen(callLevelProvider, live),
      _c.listen<double>(listenLevelProvider, live),
    ]);
    _feedHold(_c.read(overlayOwnProvider).valueOrNull?.look);
    // A fresh server holds nothing: send even an unchanged snapshot.
    _snapshot = null;
    _lastLive = null;
    _markSnapshot();
  }

  void _detach() {
    for (final s in _subs) {
      s.close();
    }
    _subs.clear();
    _snapLane.cancel();
    _liveLane.cancel();
    _snapshot = null;
    _lastLive = null;
  }

  void _feedHold(OverlayLook? look) {
    final ms = look?.effects.holdMs ?? OverlayEffects.defaults.holdMs!;
    _c.read(overlayMicProvider.notifier).setHold(Duration(milliseconds: ms));
  }

  void _markSnapshot() {
    if (!attached) return;
    _snapLane.schedule();
  }

  void _markLive() {
    if (!attached || _c.read(overlayOpenStreamsProvider) <= 0) return;
    _liveLane.schedule();
  }

  void _flushSnapshot() {
    if (!attached) return;
    final next = _buildSnapshot();
    if (next.json == _snapshot?.json) return;
    _snapshot = next;
    _send(overlayPublishSnapshotCall, next.json, 'snapshot');
    // New slots start idle on the page until the next live update.
    _lastLive = null;
    _markLive();
  }

  void _flushLive() {
    final snap = _snapshot;
    if (!attached || snap == null) return;
    final json = buildOverlayLive(snap.entries, _gatherLive());
    if (json == _lastLive) return;
    _lastLive = json;
    _send(overlayPublishLiveCall, json, 'live');
  }

  void _send(Future<void> Function(String) call, String json, String what) {
    try {
      call(json).catchError((Object e) => _log('[OVERLAY] $what refused: $e'));
    } catch (e) {
      _log('[OVERLAY] $what refused: $e');
    }
  }

  OverlaySnapshot _buildSnapshot() {
    final me = _c.read(identityProvider).peerId ?? '';
    final profiles = _c.read(profileProvider);
    final hue = _c.read(accentHueProvider);
    final theme = _themes[hue] ??= HollowTheme.darkWithHue(hue);
    final own = _c.read(overlayOwnProvider).valueOrNull;
    return buildOverlaySnapshot(
      me: me,
      selfName: displayNameFor(profiles, me),
      selfColour: overlayHexColour(theme.accentText),
      ownLook: own?.look ?? OverlayLook(effects: OverlayEffects.defaults),
      room: _c.read(overlayRoomProvider),
      added: _c.read(overlayPeopleProvider).valueOrNull ?? const [],
      fieldOf: (m) => _c.read(overlayFieldProvider(m)),
      nameOf: (m) => displayNameFor(profiles, m),
      colourOf: (m) => overlayHexColour(nameColorFor(m, theme)),
      layout: _c.read(overlayLayoutProvider),
      slots: _slots,
    );
  }

  OverlayLiveInputs _gatherLive() {
    final room = _c.read(overlayRoomProvider);
    final listening = _c.read(overlayMicProvider).listening;
    switch (room.kind) {
      case OverlayRoomKind.voiceChannel:
        return OverlayLiveInputs(
          room: room,
          selfTalking: _c.read(vcLocalSpeakingProvider),
          selfLevel: _c.read(vcLocalLevelProvider),
          listening: listening,
          speaking: _c.read(vcSpeakingProvider),
          levels: _c.read(vcLevelsProvider),
        );
      case OverlayRoomKind.dmCall:
        final speaking = _c.read(callSpeakingProvider);
        final level = _c.read(callLevelProvider);
        final devices = [for (final m in room.members) ...m.devices];
        return OverlayLiveInputs(
          room: room,
          selfTalking: speaking.local,
          selfLevel: level.local,
          listening: listening,
          speaking: speaking.remote ? devices.toSet() : const {},
          levels: {for (final d in devices) d: level.remote},
        );
      case OverlayRoomKind.none:
        return OverlayLiveInputs(
          room: room,
          selfTalking: listening && _c.read(overlayMicSpeakingProvider),
          selfLevel: listening ? _c.read(listenLevelProvider) : 0.0,
          listening: listening,
        );
    }
  }
}

/// Coalesces bursts into one send and never sends twice within
/// [kOverlayPublishGap]; the last change of a burst always goes out.
class _Lane {
  _Lane(this._flush);

  final void Function() _flush;
  Timer? _timer;
  bool _pending = false;

  void schedule() {
    _pending = true;
    _timer ??= Timer(Duration.zero, _fire);
  }

  void _fire() {
    if (!_pending) {
      _timer = null;
      return;
    }
    _pending = false;
    _timer = Timer(kOverlayPublishGap, _fire);
    _flush();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = false;
  }
}

void _log(String message) {
  debugPrint(message);
  try {
    network_api.logFromDart(message: message).catchError((_) {});
  } catch (_) {}
}
