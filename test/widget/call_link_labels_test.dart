/// What a call says about its link (#154, Vitalik Nov 24): the real state
/// (Unstable connection, Reconnecting, Connection lost) on the DM call row,
/// the person tile and the phone call screen, never a catch-all "Weak
/// connection". A DM call the link ended stays up 5 s saying so, on the row,
/// the phone call screen and the minimised bar; a hang-up closes at once and a
/// new call replaces it.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/lost_call_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/dm_call_row.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

final _nav = GlobalKey<NavigatorState>();

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1280, 800),
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(overrides: [
    ...hollowTestOverrides(extra: extra),
    ringtonePathProvider.overrideWith(_NoRingtone.new),
    statusProvider.overrideWith(_QuietStatus.new),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: _nav,
      theme: HollowThemeData.dark(),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

CallState _active() => CallState(
      status: CallStatus.active,
      peerId: kFriendPeerId1,
      callId: 'c1',
      direction: CallDirection.outgoing,
      startedAt: DateTime.now(),
    );

const _states = {
  LinkHealth.unstable: 'Unstable connection',
  LinkHealth.reconnecting: 'Reconnecting',
  LinkHealth.lost: 'Connection lost',
};

/// The call drops by its link: the linger first, then the teardown, as
/// `CallNotifier._endCallForLinkLoss` does it.
void _loseLink(ProviderContainer c, _InCall call) {
  c.read(lostCallProvider.notifier)
      .show(callId: 'c1', peerMaster: kFriendPeerId1);
  call.set(const CallState());
}

void main() {
  group('labels', () {
    for (final MapEntry(key: health, value: label) in _states.entries) {
      testWidgets('the DM call row says "$label"', (tester) async {
        final c = await _pump(tester,
            const DmCallRow(peerMaster: kFriendPeerId1),
            extra: [callProvider.overrideWith(() => _InCall(_active()))]);
        expect(find.text('Voice call'), findsOneWidget);
        c.read(callLinkHealthProvider.notifier)
            .set(LinkHealthSnapshot(health: health));
        await tester.pump();
        expect(find.text(label), findsOneWidget);
        expect(find.text('Voice call'), findsNothing);
      });

      testWidgets('the person tile says "$label", camera or not',
          (tester) async {
        final link = Provider<LinkHealthSnapshot?>(
            (_) => LinkHealthSnapshot(health: health));
        for (final camera in [false, true]) {
          await _pump(
            tester,
            SizedBox(
              width: 480,
              height: 270,
              child: CallPersonTile(
                person: CallPerson(
                  id: 'mira',
                  master: 'mira',
                  isSelf: false,
                  name: 'Mira',
                  cameraOn: camera,
                  muted: false,
                  speaking: Provider<bool>((_) => false),
                  link: link,
                ),
                size: CallTileSize.large,
              ),
            ),
          );
          expect(find.text(label), findsOneWidget, reason: 'camera=$camera');
          expect(find.bySemanticsLabel(RegExp('Mira.*$label')),
              findsOneWidget);
        }
      });

      testWidgets('the phone call screen says "$label"', (tester) async {
        final c = await _pump(
          tester,
          const MobileCallScreen(peerId: kFriendPeerId1),
          size: const Size(390, 844),
          extra: [callProvider.overrideWith(() => _InCall(_active()))],
        );
        c.read(callLinkHealthProvider.notifier)
            .set(LinkHealthSnapshot(health: health));
        await tester.pump();
        expect(find.text(label), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }

    test('no "Weak connection" is left in the app', () {
      final hits = [
        for (final f in Directory('lib').listSync(recursive: true))
          if (f is File &&
              f.path.endsWith('.dart') &&
              f.readAsStringSync().toLowerCase().contains('weak connection'))
            f.path,
      ];
      expect(hits, isEmpty);
    });
  });

  group('a call the link ended', () {
    testWidgets('the row says so for 5 s, counting down, then goes',
        (tester) async {
      final call = _InCall(_active());
      final c = await _pump(tester,
          const DmCallRow(peerMaster: kFriendPeerId1),
          extra: [callProvider.overrideWith(() => call)]);
      _loseLink(c, call);
      await tester.pump();
      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.text('5 s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('4 s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Connection lost'), findsNothing);
    });

    testWidgets('the live call keeps its row until it is over',
        (tester) async {
      final call = _InCall(_active());
      final c = await _pump(tester,
          const DmCallRow(peerMaster: kFriendPeerId1),
          extra: [callProvider.overrideWith(() => call)]);
      c.read(lostCallProvider.notifier)
          .show(callId: 'c1', peerMaster: kFriendPeerId1);
      await tester.pump();
      expect(find.text('Voice call'), findsOneWidget);
      expect(find.text('Connection lost'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets("only on that person's row", (tester) async {
      final call = _InCall(_active());
      final c = await _pump(tester,
          const DmCallRow(peerMaster: kFriendPeerId2),
          extra: [callProvider.overrideWith(() => call)]);
      _loseLink(c, call);
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a hang-up closes the row at once', (tester) async {
      final call = _InCall(_active());
      await _pump(tester, const DmCallRow(peerMaster: kFriendPeerId1),
          extra: [callProvider.overrideWith(() => call)]);
      call.set(const CallState());
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);
      expect(find.text('Voice call'), findsNothing);
    });

    testWidgets('a new call replaces it at once', (tester) async {
      final call = _InCall(_active());
      final c = await _pump(tester,
          const DmCallRow(peerMaster: kFriendPeerId1),
          extra: [callProvider.overrideWith(() => call)]);
      _loseLink(c, call);
      await tester.pump();
      call.set(const CallState(
        status: CallStatus.ringing,
        peerId: kFriendPeerId1,
        callId: 'c2',
        direction: CallDirection.outgoing,
      ));
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);
      expect(find.text('Ringing'), findsOneWidget);
    });

    testWidgets('the phone call screen stays 5 s, then closes',
        (tester) async {
      final call = _InCall(_active());
      final c = await _pump(tester, const SizedBox(),
          size: const Size(390, 844),
          extra: [callProvider.overrideWith(() => call)]);
      _nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const MobileCallScreen(peerId: kFriendPeerId1)));
      await tester.pumpAndSettle();
      _loseLink(c, call);
      await tester.pump();
      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.text('5 s'), findsOneWidget);
      // Long past any pop transition: still the call screen.
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MobileCallScreen), findsOneWidget);
      expect(find.text('4 s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(MobileCallScreen), findsNothing);
    });

    testWidgets('a hang-up still closes the phone call screen at once',
        (tester) async {
      final call = _InCall(_active());
      await _pump(tester, const SizedBox(),
          size: const Size(390, 844),
          extra: [callProvider.overrideWith(() => call)]);
      _nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const MobileCallScreen(peerId: kFriendPeerId1)));
      await tester.pumpAndSettle();
      call.set(const CallState());
      await tester.pumpAndSettle();
      expect(find.byType(MobileCallScreen), findsNothing);
    });

    testWidgets('the minimised bar says so for 5 s', (tester) async {
      final call = _InCall(_active());
      final c = await _pump(tester,
          const Stack(children: [MobileMinimisedCall()]),
          size: const Size(390, 844),
          extra: [callProvider.overrideWith(() => call)]);
      _loseLink(c, call);
      await tester.pump();
      expect(find.text('Connection lost'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Connection lost'), findsNothing);
    });
  });
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);

  @override
  CallState build() => initial;

  void set(CallState s) => state = s;
}

class _QuietStatus extends StatusNotifier {
  @override
  StatusState build() => const StatusState();
}

class _NoRingtone extends RingtonePathNotifier {
  @override
  Future<String?> build() async => null;
}
