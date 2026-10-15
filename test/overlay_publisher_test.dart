import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/services/overlay_publisher.dart';
import 'package:hollow/src/rust/api/overlay.dart' hide overlayImageBytes;
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_overlay_api.dart';

const _me = 'meMaster';
const _myDevice = 'meDevice';
final _hash = 'c' * 64;

String _id(String d) => const {
      'aDev1': 'aliceM',
      'aDev2': 'aliceM',
      'bDev': 'bobM',
      'cDev': 'carolM',
      'meSibling': _me,
      _myDevice: _me,
    }[d] ??
    d;

OverlayPerson _added(String master, int slot, {String field = 'share'}) {
  final eff = '{"v":1,"stamp":5,"states":{"idle":"$_hash"},"effects":{"mirror":true}}';
  return OverlayPerson.fromFfi(OverlayPersonFfi(
    master: master,
    slot: slot,
    field: field,
    theirLookJson: eff,
    effectiveLookJson: eff,
  ));
}

OverlaySnapshot _snap({
  OverlayRoom room = OverlayRoom.empty,
  List<OverlayPerson> added = const [],
  Map<String, String> fields = const {},
  OverlayTransientSlots? slots,
}) =>
    buildOverlaySnapshot(
      me: _me,
      selfName: 'Me',
      selfColour: '#112233',
      ownLook: OverlayLook(effects: OverlayEffects.defaults),
      room: room,
      added: added,
      fieldOf: (m) => fields[m] ?? 'show',
      nameOf: (m) => 'name-$m',
      colourOf: (m) => '#abcdef',
      layout: OverlayLayout(),
      slots: slots ?? OverlayTransientSlots(),
    );

List<Map<String, dynamic>> _people(String json) =>
    ((jsonDecode(json) as Map)['people'] as List).cast<Map<String, dynamic>>();

/// The overlay publisher (plan 7, 16.4): who is shown and how, and the live
/// states, built from the call providers and sent only while the server runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = FakeOverlayApi();
  setUpAll(() => RustLib.initMock(api: api));

  group('room', () {
    test('voice channel devices collapse to masters and never include us', () {
      const vc = VoiceChannelState(
        participants: {
          's': {
            'v': {'aDev1', 'bDev', 'aDev2', _myDevice, 'meSibling', _me}
          }
        },
        currentServerId: 's',
        currentChannelId: 'v',
        isMuted: true,
        peerAudioStates: {'bDev': PeerAudioState(isDeafened: true)},
      );
      final room = overlayRoomFrom(
          vc: vc,
          call: const CallState(),
          identityOf: _id,
          me: _me,
          myDevice: _myDevice);
      expect(room.kind, OverlayRoomKind.voiceChannel);
      expect(room.members.map((m) => m.master), ['aliceM', 'bobM']);
      expect(room.members.first.devices, ['aDev1', 'aDev2']);
      expect(room.selfMuted, isTrue);
      expect(room.deviceAudio['bDev']!.deafened, isTrue);
      expect(room.deviceAudio.keys, isNot(contains(_myDevice)));
    });

    test('an active DM call is a room of one, by master; a ringing one is not',
        () {
      const call = CallState(
          status: CallStatus.active,
          peerId: 'cDev',
          remoteMuted: true,
          isDeafened: true);
      final room = overlayRoomFrom(
          vc: const VoiceChannelState(),
          call: call,
          identityOf: _id,
          me: _me);
      expect(room.kind, OverlayRoomKind.dmCall);
      expect(room.members.single.master, 'carolM');
      expect(room.members.single.devices, ['cDev']);
      expect(room.deviceAudio['cDev']!.muted, isTrue);
      expect(room.selfDeafened, isTrue);
      final ringing = overlayRoomFrom(
          vc: const VoiceChannelState(),
          call: const CallState(status: CallStatus.ringing, peerId: 'cDev'),
          identityOf: _id,
          me: _me);
      expect(ringing.inRoom, isFalse);
    });
  });

  group('snapshot', () {
    const room = OverlayRoom(kind: OverlayRoomKind.voiceChannel, members: [
      OverlayRoomEntry('aliceM', ['aDev1', 'aDev2']),
      OverlayRoomEntry('bobM', ['bDev']),
      OverlayRoomEntry('offM', ['offDev']),
      OverlayRoomEntry(_me, ['meSibling']),
    ]);

    test('self first in slot 0; room by master; off left out; slots', () {
      final s = _snap(
        room: room,
        added: [_added('aliceM', 3), _added('daveM', 4), _added('eveM', 5, field: 'off'), _added(_me, 9)],
        fields: {'offM': 'off'},
      );
      final p = _people(s.json);
      expect(p.first['slot'], 0);
      expect(p.first['is_self'], true);
      expect(p.first['master'], _me);
      expect(p.first['in_room'], true);
      expect(p.where((x) => x['is_self'] == true), hasLength(1));
      expect(p.where((x) => x['master'] == _me), hasLength(1),
          reason: 'never ourselves inside the set, not even a sibling');
      final byMaster = {for (final x in p) x['master']: x};
      expect(byMaster.keys, [_me, 'aliceM', 'bobM', 'daveM']);
      expect(byMaster['aliceM']!['slot'], 3);
      expect(byMaster['aliceM']!['added'], true);
      expect(byMaster['aliceM']!['in_room'], true);
      expect((byMaster['aliceM']!['look'] as Map)['states']['idle'], _hash,
          reason: 'the EFFECTIVE look');
      expect(byMaster['bobM']!['slot'], kOverlayTransientSlotBase);
      expect(byMaster['bobM']!['added'], false);
      expect(byMaster['bobM']!['look'], isNull, reason: 'avatar only');
      expect(byMaster['daveM']!['in_room'], false);
      expect(byMaster['daveM']!['slot'], 4);
      for (final x in p) {
        expect(x['master'], isA<String>());
        expect((x['master'] as String), isNotEmpty);
        expect(x['name'], isA<String>());
        expect(x['colour'], matches(RegExp(r'^#[0-9a-f]{6}$')));
      }
      expect(s.entries.firstWhere((e) => e.master == 'aliceM').devices,
          ['aDev1', 'aDev2']);
    });

    test('transient slots hold for the session and are never reused', () {
      final slots = OverlayTransientSlots();
      final first = _people(_snap(room: room, slots: slots).json);
      expect({for (final x in first) x['master']: x['slot']},
          {_me: 0, 'aliceM': 1000, 'bobM': 1001, 'offM': 1002});
      const later = OverlayRoom(kind: OverlayRoomKind.voiceChannel, members: [
        OverlayRoomEntry('frankM', ['fDev']),
        OverlayRoomEntry('bobM', ['bDev']),
      ]);
      final second = _people(_snap(room: later, slots: slots).json);
      expect({for (final x in second) x['master']: x['slot']},
          {_me: 0, 'frankM': 1003, 'bobM': 1001});
    });

    test('the layout rides along', () {
      final root = jsonDecode(_snap().json) as Map;
      expect(root['v'], 1);
      expect((root['layout'] as Map)['size'], 160);
    });
  });

  group('live', () {
    const entries = [
      OverlaySlotEntry(slot: 0, master: _me, isSelf: true, inRoom: true),
      OverlaySlotEntry(
          slot: 3, master: 'aliceM', isSelf: false, inRoom: true, devices: ['aDev1', 'aDev2']),
      OverlaySlotEntry(slot: 1000, master: 'bobM', isSelf: false, inRoom: true, devices: ['bDev']),
      OverlaySlotEntry(slot: 4, master: 'daveM', isSelf: false, inRoom: false),
    ];

    Map<int, Map<String, dynamic>> live(OverlayLiveInputs i) {
      final root = jsonDecode(buildOverlayLive(entries, i)) as Map;
      return {
        for (final x in (root['people'] as List).cast<Map<String, dynamic>>())
          x['slot'] as int: x,
      };
    }

    test('self comes from the bool, never from the device set', () {
      const room = OverlayRoom(kind: OverlayRoomKind.voiceChannel);
      final quiet = live(const OverlayLiveInputs(
          room: room,
          selfTalking: false,
          selfLevel: 0,
          listening: false,
          speaking: {_me, _myDevice}));
      expect(quiet[0]!['state'], 'idle');
      final talking = live(const OverlayLiveInputs(
          room: room, selfTalking: true, selfLevel: 0.6, listening: false));
      expect(talking[0]!['state'], 'talking');
      expect(talking[0]!['level'], 0.6);
    });

    test('mute and deafen win over talking, for us and for others', () {
      const room = OverlayRoom(
        kind: OverlayRoomKind.voiceChannel,
        selfMuted: true,
        deviceAudio: {
          'bDev': (muted: false, deafened: true),
        },
      );
      final l = live(const OverlayLiveInputs(
          room: room,
          selfTalking: true,
          selfLevel: 0.9,
          listening: false,
          speaking: {'bDev'},
          levels: {'bDev': 0.7}));
      expect(l[0]!['state'], 'muted');
      expect(l[0]!['level'], 0.0);
      expect(l[1000]!['state'], 'deafened');
      expect(l[1000]!['level'], 0.0);
    });

    test('one talking device speaks for the person; levels by device', () {
      const room = OverlayRoom(
        kind: OverlayRoomKind.voiceChannel,
        deviceAudio: {'aDev1': (muted: true, deafened: false)},
      );
      final l = live(const OverlayLiveInputs(
          room: room,
          selfTalking: false,
          selfLevel: 0,
          listening: false,
          speaking: {'aDev2'},
          levels: {'aDev2': 0.4, 'aDev1': 0.9}));
      expect(l[3]!['state'], 'talking');
      expect(l[3]!['level'], 0.4, reason: 'the muted device adds nothing');
      expect(l[1000]!['state'], 'idle');
      expect(l.containsKey(4), isFalse, reason: 'not in the room');
    });

    test('self_active: in a room or listening', () {
      Map root(OverlayLiveInputs i) =>
          jsonDecode(buildOverlayLive(entries, i)) as Map;
      expect(
          root(const OverlayLiveInputs(
              room: OverlayRoom.empty, selfTalking: true, selfLevel: 0.5, listening: false))['self_active'],
          false);
      final idle = root(const OverlayLiveInputs(
          room: OverlayRoom.empty, selfTalking: true, selfLevel: 0.5, listening: false));
      expect((idle['people'] as List).first['state'], 'idle');
      final listening = root(const OverlayLiveInputs(
          room: OverlayRoom.empty, selfTalking: true, selfLevel: 0.5, listening: true));
      expect(listening['self_active'], true);
      expect((listening['people'] as List).first['state'], 'talking');
      expect(
          root(const OverlayLiveInputs(
              room: OverlayRoom(kind: OverlayRoomKind.dmCall),
              selfTalking: false,
              selfLevel: 0,
              listening: false))['self_active'],
          true);
    });
  });

  group('publisher', () {
    late List<(DateTime, String)> snaps;
    late List<(DateTime, String)> lives;
    late StateProvider<OverlayRoom> roomState;

    ProviderContainer container(WidgetTester tester) {
      snaps = [];
      lives = [];
      DateTime now() => tester.binding.clock.now();
      overlayPublishSnapshotCall = (j) async => snaps.add((now(), j));
      overlayPublishLiveCall = (j) async => lives.add((now(), j));
      debugOverlayMic = OverlayMic(log: (_) {});
      roomState = StateProvider<OverlayRoom>((_) => OverlayRoom.empty);
      api.people = [];
      api.ownLookJson =
          '{"v":1,"stamp":1,"states":{},"effects":{"hold_ms":400}}';
      final c = ProviderContainer(overrides: [
        overlayRoomProvider.overrideWith((ref) => ref.watch(roomState)),
        identityProvider.overrideWith(_Identity.new),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    Future<void> wait(WidgetTester tester, int ms) =>
        tester.pump(Duration(milliseconds: ms));

    testWidgets('nothing goes out while the server is off', (tester) async {
      final c = container(tester);
      final p = OverlayPublisher(c)..start();
      addTearDown(p.dispose);
      c.read(overlayLayoutProvider.notifier).update(OverlayLayout(gap: 20));
      c.read(vcLocalSpeakingProvider.notifier).set(true);
      c.read(overlayOpenStreamsProvider.notifier).state = 2;
      await wait(tester, 1000);
      expect(snaps, isEmpty);
      expect(lives, isEmpty);
      expect(p.attached, isFalse);
    });

    testWidgets('server on: a snapshot; bursts coalesce, 20 per second at most',
        (tester) async {
      final c = container(tester);
      final p = OverlayPublisher(c)..start();
      addTearDown(p.dispose);
      c.read(overlayServerRunningProvider.notifier).state = true;
      await wait(tester, 200);
      expect(snaps, isNotEmpty);
      final first = snaps.length;
      // The own look loaded: the mic's hold follows the look's hold_ms.
      expect(overlayMic.hold, const Duration(milliseconds: 400));

      for (var i = 0; i < 40; i++) {
        c.read(overlayLayoutProvider.notifier).update(OverlayLayout(gap: i));
        await wait(tester, 10);
      }
      await wait(tester, 200);
      final burst = snaps.sublist(first);
      expect(burst.length, lessThanOrEqualTo(10),
          reason: '400 ms of changes, one send per 50 ms at most');
      expect(burst.length, greaterThanOrEqualTo(5));
      for (var i = 1; i < snaps.length; i++) {
        expect(snaps[i].$1.difference(snaps[i - 1].$1),
            greaterThanOrEqualTo(kOverlayPublishGap));
      }
      expect(jsonDecode(snaps.last.$2)['layout']['gap'], 39,
          reason: 'the trailing change is never lost');

      // Unchanged inputs send nothing.
      final n = snaps.length;
      c.read(overlayLayoutProvider.notifier).update(OverlayLayout(gap: 39));
      await wait(tester, 200);
      expect(snaps, hasLength(n));
    });

    testWidgets('live only while a page streams, throttled, following the room',
        (tester) async {
      final c = container(tester);
      final p = OverlayPublisher(c)..start();
      addTearDown(p.dispose);
      c.read(overlayServerRunningProvider.notifier).state = true;
      c.read(roomState.notifier).state = const OverlayRoom(
          kind: OverlayRoomKind.voiceChannel,
          members: [
            OverlayRoomEntry('bobM', ['bDev'])
          ]);
      await wait(tester, 200);
      expect(_people(snaps.last.$2).map((x) => x['master']), [_me, 'bobM']);
      c.read(vcLocalSpeakingProvider.notifier).set(true);
      await wait(tester, 200);
      expect(lives, isEmpty, reason: 'no page open');

      c.read(overlayOpenStreamsProvider.notifier).state = 1;
      await wait(tester, 100);
      expect(lives, hasLength(1));
      final l = jsonDecode(lives.last.$2) as Map;
      expect(l['self_active'], true);
      expect((l['people'] as List).first,
          {'slot': 0, 'state': 'talking', 'level': 0.0});
      expect((l['people'] as List)[1]['slot'], kOverlayTransientSlotBase);

      final start = tester.binding.clock.now();
      for (var i = 0; i < 100; i++) {
        c.read(vcSpeakingProvider.notifier).set(i.isEven ? {'bDev'} : {});
        c.read(vcLevelsProvider.notifier).set({'bDev': (i % 10 + 1) / 10});
        await wait(tester, 10);
      }
      await wait(tester, 100);
      final perSecond = lives.where((x) {
        final t = x.$1.difference(start);
        return t >= Duration.zero && t < const Duration(seconds: 1);
      });
      expect(perSecond.length, lessThanOrEqualTo(20));
      expect(perSecond.length, greaterThanOrEqualTo(10));

      c.read(overlayOpenStreamsProvider.notifier).state = 0;
      await wait(tester, 100);
      final n = lives.length;
      c.read(vcSpeakingProvider.notifier).set({'bDev'});
      await wait(tester, 200);
      expect(lives, hasLength(n), reason: 'the last page closed');
    });

    testWidgets('server off detaches every listener', (tester) async {
      final c = container(tester);
      final p = OverlayPublisher(c)..start();
      addTearDown(p.dispose);
      c.read(overlayServerRunningProvider.notifier).state = true;
      c.read(overlayOpenStreamsProvider.notifier).state = 1;
      await wait(tester, 200);
      c.read(overlayServerRunningProvider.notifier).state = false;
      await wait(tester, 10);
      expect(p.attached, isFalse);
      final s = snaps.length, l = lives.length;
      c.read(overlayLayoutProvider.notifier).update(OverlayLayout(gap: 3));
      c.read(vcLocalSpeakingProvider.notifier).set(true);
      await wait(tester, 300);
      expect(snaps, hasLength(s));
      expect(lives, hasLength(l));
      // On again: a fresh server gets a snapshot even if nothing changed.
      c.read(overlayServerRunningProvider.notifier).state = true;
      await wait(tester, 100);
      expect(snaps, hasLength(s + 1));
    });
  });
}

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState(peerId: _me, isLoaded: true);
}
