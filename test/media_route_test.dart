/// The call route badge's data path (0.14, `project_call_route_badge_014`):
/// which pair carries media, how a lane names it, what the watchdog publishes
/// and what the badge says for a DM, a room and a watched share.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/media_route_provider.dart';
import 'package:hollow/src/core/services/ice_route_probe.dart';
import 'package:hollow/src/core/services/link_watchdog.dart';
import 'package:hollow/src/ui/call/call_route.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';

StatsReport _r(String id, String type, Map<String, dynamic> values) =>
    StatsReport(id, type, 0, values);

/// One pair with its two candidates.
List<StatsReport> _pair(String id, String local, String remote,
        {String state = 'succeeded', bool nominated = true}) =>
    [
      _r(id, 'candidate-pair', {
        'state': state,
        'nominated': nominated,
        'localCandidateId': 'L$id',
        'remoteCandidateId': 'R$id',
      }),
      _r('L$id', 'local-candidate',
          {'candidateType': local, 'protocol': 'udp'}),
      _r('R$id', 'remote-candidate', {'candidateType': remote}),
    ];

/// Answers getStats with whatever the test holds right now.
class _StatsPc implements RTCPeerConnection {
  List<StatsReport> stats = const [];

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => stats;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('the pair carrying media', () {
    test('host on both ends is direct, srflx is direct, relay on either end '
        'is relayed', () {
      expect(iceRouteFromStats(_pair('a', 'host', 'host'))!.mediaRoute,
          MediaRoute.direct);
      expect(iceRouteFromStats(_pair('a', 'srflx', 'prflx'))!.mediaRoute,
          MediaRoute.direct);
      expect(iceRouteFromStats(_pair('a', 'relay', 'host'))!.mediaRoute,
          MediaRoute.relayed);
      expect(iceRouteFromStats(_pair('a', 'host', 'relay'))!.mediaRoute,
          MediaRoute.relayed);
    });

    test('no succeeded pair yet says nothing', () {
      expect(iceRouteFromStats(_pair('a', 'host', 'host', state: 'in-progress')),
          isNull);
      expect(iceRouteFromStats(const []), isNull);
    });

    test("the transport's selected pair wins over an older nominated one",
        () {
      // After an ICE restart to TURN the direct pair can still read
      // succeeded and nominated; the transport names the live one.
      final stats = [
        ..._pair('old', 'host', 'host'),
        ..._pair('new', 'relay', 'srflx', nominated: false),
        _r('T', 'transport', {'selectedCandidatePairId': 'new'}),
      ];
      expect(iceRouteFromStats(stats)!.mediaRoute, MediaRoute.relayed);
    });

    test('without a transport report the nominated pair wins', () {
      final stats = [
        ..._pair('x', 'relay', 'relay', nominated: false),
        ..._pair('y', 'host', 'host'),
      ];
      expect(iceRouteFromStats(stats)!.mediaRoute, MediaRoute.direct);
    });
  });

  group('a share leg', () {
    const relayedPair = IceRoute('relay', 'host', 'udp');
    const directPair = IceRoute('host', 'host', 'udp');

    test('a forwarder leg is named by who forwards, never by its pair', () {
      expect(
          shareRouteOf(directPair,
              viaForwarder: true, byRelayForwarder: true, byOwnApp: false),
          MediaRoute.relayForwarder);
      expect(
          shareRouteOf(relayedPair,
              viaForwarder: true, byRelayForwarder: false, byOwnApp: false),
          MediaRoute.memberForwarder);
    });

    test('a share our own app forwards says nothing, never another member',
        () {
      // The viewer's own engine picked as forwarder: the egress pair is a hop
      // inside this device.
      final r = shareRouteOf(directPair,
          viaForwarder: true, byRelayForwarder: false, byOwnApp: true);
      expect(r, isNull);
      expect(
          shareRouteOf(relayedPair,
              viaForwarder: true, byRelayForwarder: false, byOwnApp: true),
          isNull);
    });

    test('a direct leg is named by its pair', () {
      expect(
          shareRouteOf(relayedPair,
              viaForwarder: false, byRelayForwarder: true, byOwnApp: false),
          MediaRoute.relayed);
      expect(
          shareRouteOf(directPair,
              viaForwarder: false, byRelayForwarder: false, byOwnApp: false),
          MediaRoute.direct);
    });
  });

  group('the watchdog', () {
    testWidgets('publishes the route when it changes and null when it stops',
        (tester) async {
      final pc = _StatsPc()..stats = _pair('a', 'host', 'srflx');
      final seen = <MediaRoute?>[];
      final dog = LinkWatchdog(
        peerConnection: () => pc,
        isPolite: true,
        onHealth: (_) {},
        onRoute: seen.add,
        onRecoverLink: () async {},
        onGiveUp: () {},
      )..start();

      await tester.pump(const Duration(seconds: 2));
      expect(seen, [MediaRoute.direct]);

      // The same class again publishes nothing.
      await tester.pump(const Duration(seconds: 4));
      expect(seen, [MediaRoute.direct]);

      pc.stats = [
        ..._pair('b', 'relay', 'host'),
        _r('T', 'transport', {'selectedCandidatePairId': 'b'}),
      ];
      await tester.pump(const Duration(seconds: 2));
      expect(seen, [MediaRoute.direct, MediaRoute.relayed]);

      // A reading with no pair (mid-lapse) keeps the last route.
      pc.stats = const [];
      await tester.pump(const Duration(seconds: 4));
      expect(seen, [MediaRoute.direct, MediaRoute.relayed]);

      dog.stop();
      expect(seen.last, isNull);
    });
  });

  group('route maps', () {
    test('null forgets a key, an equal value changes nothing', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(vcMediaRouteProvider.notifier);
      n.setFor('d1', MediaRoute.direct);
      final first = c.read(vcMediaRouteProvider);
      n.setFor('d1', MediaRoute.direct);
      expect(identical(c.read(vcMediaRouteProvider), first), isTrue);
      n.setFor('d1', null);
      expect(c.read(vcMediaRouteProvider), isEmpty);
    });
  });

  group('the words', () {
    const mira = (id: 'dev-mira', master: 'mira', name: 'Mira');
    const sam = (id: 'dev-sam', master: 'sam', name: 'Sam');
    const ana = (id: 'dev-ana', master: 'ana', name: 'Ana');

    test('a DM says the route and who it reaches', () {
      expect(dmRouteWords(MediaRoute.direct, 'Mira').label, 'Direct');
      expect(dmRouteWords(MediaRoute.direct, 'Mira').tip, contains('Mira'));
      expect(dmRouteWords(MediaRoute.relayed, 'Mira').label, 'Relayed');
    });

    test('a room with every leg the same says that route', () {
      expect(
          roomRouteWords(
              {mira.id: MediaRoute.direct, sam.id: MediaRoute.direct},
              [mira, sam])!.label,
          'Direct');
      expect(
          roomRouteWords(
              {mira.id: MediaRoute.relayed, sam.id: MediaRoute.relayed},
              [mira, sam])!.label,
          'Relayed');
    });

    test('a mixed room is partly relayed and names who goes which way', () {
      final words = roomRouteWords({
        mira.id: MediaRoute.direct,
        sam.id: MediaRoute.direct,
        ana.id: MediaRoute.relayed,
      }, [mira, sam, ana])!;
      expect(words.label, 'Partly relayed');
      expect(words.tip, contains('Mira and Sam'));
      expect(words.tip, contains('to Ana'));
    });

    test('legs still connecting and people who left do not count', () {
      expect(roomRouteWords(const {}, [mira]), isNull);
      expect(
          roomRouteWords({'gone': MediaRoute.relayed, mira.id: MediaRoute.direct},
              [mira, sam])!.label,
          'Direct');
    });

    test('a peer whose leg never connected is not "everyone here"', () {
      final words = roomRouteWords(
          {mira.id: MediaRoute.direct, sam.id: MediaRoute.direct},
          [mira, sam, ana])!;
      expect(words.label, 'Direct');
      expect(words.tip, isNot(contains('everyone here')));
      expect(words.tip, contains('Mira and Sam'));
      expect(
          roomRouteWords(
              {mira.id: MediaRoute.direct, sam.id: MediaRoute.direct},
              [mira, sam])!.tip,
          contains('everyone here'));
    });

    test('a person with two devices is named once', () {
      const pc = (id: 'dev-mira-pc', master: 'mira', name: 'Mira');
      const phone = (id: 'dev-mira-phone', master: 'mira', name: 'Mira');
      final mixed = roomRouteWords(
          {pc.id: MediaRoute.direct, phone.id: MediaRoute.relayed},
          [pc, phone])!;
      expect(mixed.label, 'Partly relayed');
      expect('Mira'.allMatches(mixed.tip).length, 1, reason: mixed.tip);
      expect(mixed.tip,
          isNot(contains('Straight to Mira. Through the relay server to Mira')));

      final both = roomRouteWords(
          {pc.id: MediaRoute.direct, phone.id: MediaRoute.direct, sam.id: MediaRoute.direct},
          [pc, phone, sam])!;
      expect(both.tip, contains('everyone here'));
      final withSam = roomRouteWords({
        pc.id: MediaRoute.direct,
        phone.id: MediaRoute.relayed,
        sam.id: MediaRoute.direct,
      }, [pc, phone, sam])!;
      expect(withSam.tip, startsWith('Straight to Sam. Through the relay server to Mira.'));
    });

    test('our own other device is named as ours', () {
      const mine = (id: 'dev-me-phone', master: 'me', name: 'Vitalik');
      final w = roomRouteWords(
          {mine.id: MediaRoute.relayed, mira.id: MediaRoute.direct},
          [mine, mira],
          selfMaster: 'me')!;
      expect(w.tip, contains('to your other device'));
      expect(w.tip, isNot(contains('Vitalik')));
      final solo = roomRouteWords({mine.id: MediaRoute.direct}, [mine],
          selfMaster: 'me')!;
      expect(solo.tip, contains('straight to your other device'));
    });

    test("a stage's people become the room's peers, ours named as ours", () {
      CallPerson person(String id, String master, String name,
              {bool self = false}) =>
          CallPerson(
              id: id,
              master: master,
              isSelf: self,
              name: name,
              speaking: StateProvider<bool>((_) => false));
      final subject = roomRouteOf(CallStageData(
        people: [
          person('me', 'me', 'You', self: true),
          person('dev-me-phone', 'me', 'Vitalik'),
          person('dev-mira', 'mira', 'Mira'),
        ],
        shares: const [],
        focus: null,
        gridOn: false,
        onFocus: (_) {},
        onGrid: (_) {},
        onWatch: (_) {},
        onStopWatching: (_) {},
        onStopSharing: () {},
      ));
      expect(subject.selfMaster, 'me');
      expect(subject.peers.map((p) => p.id), ['dev-me-phone', 'dev-mira']);
      final w = roomRouteWords(
          {'dev-me-phone': MediaRoute.direct, 'dev-mira': MediaRoute.relayed},
          subject.peers,
          selfMaster: subject.selfMaster)!;
      expect(w.tip, contains('Straight to your other device.'));
    });

    test('a forwarded share says who passes it along', () {
      expect(shareRouteWords(MediaRoute.relayForwarder, 'Mira').label,
          'Forwarded');
      expect(shareRouteWords(MediaRoute.memberForwarder, 'Mira').label,
          'Forwarded');
      expect(shareRouteWords(MediaRoute.relayForwarder, 'Mira').tip,
          isNot(shareRouteWords(MediaRoute.memberForwarder, 'Mira').tip));
    });

    test('names join in plain English', () {
      expect(joinNames(['A']), 'A');
      expect(joinNames(['A', 'B']), 'A and B');
      expect(joinNames(['A', 'B', 'C']), 'A, B and C');
      expect(joinNames(['A', 'B', 'C', 'D', 'E']), 'A, B and 3 others');
    });

    test('no em dash and no colon anywhere the badge speaks', () {
      final all = <String>[
        for (final r in MediaRoute.values) ...[
          dmRouteWords(r, 'Mira').label,
          dmRouteWords(r, 'Mira').tip,
          shareRouteWords(r, 'Mira').label,
          shareRouteWords(r, 'Mira').tip,
        ],
        ...[
          roomRouteWords({mira.id: MediaRoute.direct}, [mira])!,
          roomRouteWords(
              {mira.id: MediaRoute.direct, sam.id: MediaRoute.direct},
              [mira, sam])!,
          roomRouteWords({mira.id: MediaRoute.relayed}, [mira])!,
          roomRouteWords(
              {mira.id: MediaRoute.direct, ana.id: MediaRoute.relayed},
              [mira, ana])!,
          roomRouteWords({mira.id: MediaRoute.direct}, [mira, ana])!,
          roomRouteWords({
            'dev-mira-pc': MediaRoute.direct,
            'dev-mira-phone': MediaRoute.relayed,
          }, [
            (id: 'dev-mira-pc', master: 'mira', name: 'Mira'),
            (id: 'dev-mira-phone', master: 'mira', name: 'Mira'),
          ])!,
          roomRouteWords({'dev-me-2': MediaRoute.direct},
              [(id: 'dev-me-2', master: 'me', name: 'Me')],
              selfMaster: 'me')!,
        ].expand((w) => [w.label, w.tip]),
      ];
      for (final s in all) {
        expect(s.contains('—'), isFalse, reason: s);
        expect(s.contains(':'), isFalse, reason: s);
      }
    });
  });
}
