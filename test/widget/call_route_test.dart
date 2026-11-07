/// The call route badge (0.14, `project_call_route_badge_014`): Direct,
/// Relayed or Forwarded where people look during a call, on the bar of all
/// three stage hosts, the DM call row, a watched share's title, and both phone
/// call screens. Nothing shows until a leg reports a route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/media_route_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_route.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/dm_call_row.dart';
import 'package:hollow/src/ui/call/share_tile.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

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
      theme: HollowThemeData.dark(),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

CallBarModel _bar({DateTime? startedAt, CallRouteSubject? route}) =>
    CallBarModel(
      startedAt: startedAt,
      muted: false,
      deafened: false,
      onMute: () {},
      onDeafen: () {},
      cameraOn: false,
      onCamera: () {},
      sharing: false,
      onShare: () {},
      layout: null,
      onLayout: null,
      fullscreen: false,
      onFullscreen: null,
      watching: false,
      leaveLabel: 'Leave the call',
      onLeave: () {},
      route: route,
    );

Finder _badge(String label) => find.widgetWithText(HollowBadge, label);

/// [_pump] at a phone width and text scale.
Future<ProviderContainer> _pumpScaled(
  WidgetTester tester,
  Widget child, {
  required Size size,
  double scale = 1.0,
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
      theme: HollowThemeData.dark(),
      builder: (ctx, w) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: w!),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

/// A call two hours in, so the timer shows hours.
CallState _longCall() => CallState(
      status: CallStatus.active,
      peerId: kFriendPeerId1,
      callId: 'c1',
      direction: CallDirection.outgoing,
      startedAt: DateTime.now().subtract(const Duration(hours: 2)),
    );

VoiceChannelState _longRoom() => VoiceChannelState(
      currentServerId: 's1',
      currentChannelId: 'v1',
      currentChannelName: 'Jam room',
      joinedAt: DateTime.now().subtract(const Duration(hours: 2)),
      participants: const {
        's1': {
          'v1': {'dev-mira', 'dev-ana'}
        }
      },
    );

/// The badge is on screen: painted and reachable, not merely built.
Finder _shown(String label) => _badge(label).hitTestable();

void main() {
  group('the bar', () {
    testWidgets('a DM call says Direct, then Relayed when the pair moves',
        (tester) async {
      final c = await _pump(
          tester,
          Center(
              child: CallStageBar(
                  model: _bar(
                      startedAt: DateTime.now(),
                      route: const DmCallRoute('Mira')))));
      expect(find.byType(HollowBadge), findsNothing,
          reason: 'no route reported yet');

      c.read(callMediaRouteProvider.notifier).set(MediaRoute.direct);
      await tester.pump();
      expect(_badge('Direct'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Direct\. .*Mira')), findsOneWidget);

      c.read(callMediaRouteProvider.notifier).set(MediaRoute.relayed);
      await tester.pump();
      expect(_badge('Relayed'), findsOneWidget);
      expect(_badge('Direct'), findsNothing);
    });

    testWidgets('nothing while the call is still connecting', (tester) async {
      final c = await _pump(
          tester,
          Center(
              child: CallStageBar(
                  model: _bar(route: const DmCallRoute('Mira')))));
      c.read(callMediaRouteProvider.notifier).set(MediaRoute.direct);
      await tester.pump();
      expect(find.text('Connecting'), findsOneWidget);
      expect(find.byType(HollowBadge), findsNothing);
    });

    testWidgets('a room sums its legs up, partly relayed when they differ',
        (tester) async {
      final c = await _pump(
          tester,
          Center(
              child: CallStageBar(
                  model: _bar(
                      startedAt: DateTime.now(),
                      route: const RoomCallRoute([
                        (id: 'dev-mira', master: 'mira', name: 'Mira'),
                        (id: 'dev-ana', master: 'ana', name: 'Ana'),
                      ])))));
      final routes = c.read(vcMediaRouteProvider.notifier);
      routes.setFor('dev-mira', MediaRoute.direct);
      await tester.pump();
      expect(_badge('Direct'), findsOneWidget);

      routes.setFor('dev-ana', MediaRoute.relayed);
      await tester.pump();
      expect(_badge('Partly relayed'), findsOneWidget);
      expect(
          find.bySemanticsLabel(
              RegExp(r'Straight to Mira\. Through the relay server to Ana')),
          findsOneWidget);
    });
  });

  group('the DM call row', () {
    testWidgets('carries the route beside "Voice call" once the call is up',
        (tester) async {
      final c = await _pump(
        tester,
        const DmCallRow(peerMaster: kFriendPeerId1),
        extra: [
          callProvider.overrideWith(() => _InCall(CallState(
                status: CallStatus.active,
                peerId: kFriendPeerId1,
                callId: 'c1',
                direction: CallDirection.outgoing,
                startedAt: DateTime.now(),
              ))),
        ],
      );
      expect(find.text('Voice call'), findsOneWidget);
      expect(find.byType(HollowBadge), findsNothing);
      c.read(callMediaRouteProvider.notifier).set(MediaRoute.direct);
      await tester.pump();
      expect(_badge('Direct'), findsOneWidget);
    });
  });

  group('a watched share', () {
    final route = StateProvider<MediaRoute?>((_) => null);

    CallShare share() => CallShare(
          owner: 'dev-mira',
          master: 'mira',
          isMine: false,
          name: 'Mira',
          watched: true,
          route: route,
        );

    testWidgets('names a forwarder in its title row', (tester) async {
      final c = await _pump(
        tester,
        SizedBox(
          width: 640,
          height: 360,
          child: ShareTile(share: share(), size: CallTileSize.large),
        ),
      );
      expect(find.text('Forwarded'), findsNothing);

      c.read(route.notifier).state = MediaRoute.relayForwarder;
      await tester.pump();
      expect(find.text('Forwarded'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r"^Forwarded\. The relay's forwarder")),
          findsOneWidget);

      c.read(route.notifier).state = MediaRoute.direct;
      await tester.pump();
      expect(find.text('Direct'), findsOneWidget);
    });

    testWidgets('your own share says nothing about routes', (tester) async {
      await _pump(
        tester,
        const SizedBox(
          width: 640,
          height: 360,
          child: ShareTile(
            share: CallShare(
                owner: 'me',
                master: 'me',
                isMine: true,
                name: 'You',
                watched: true),
            size: CallTileSize.large,
          ),
        ),
      );
      for (final w in ['Direct', 'Relayed', 'Forwarded']) {
        expect(find.text(w), findsNothing);
      }
    });
  });

  group('the phone', () {
    testWidgets('the call screen carries the route beside the timer',
        (tester) async {
      final c = await _pump(
        tester,
        const MobileCallScreen(peerId: kFriendPeerId1),
        size: const Size(390, 844),
        extra: [
          callProvider.overrideWith(() => _InCall(CallState(
                status: CallStatus.active,
                peerId: kFriendPeerId1,
                callId: 'c1',
                direction: CallDirection.outgoing,
                startedAt: DateTime.now(),
              ))),
        ],
      );
      expect(find.byType(HollowBadge), findsNothing);
      c.read(callMediaRouteProvider.notifier).set(MediaRoute.relayed);
      await tester.pump();
      expect(_badge('Relayed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a voice room carries the room summary', (tester) async {
      final joined = DateTime.now();
      final c = await _pump(
        tester,
        const MobileVoiceChannelRoute(
            serverId: 's1', channelId: 'v1', channelName: 'Jam room'),
        size: const Size(390, 844),
        extra: [
          voiceChannelProvider.overrideWith(() => _Room(VoiceChannelState(
                currentServerId: 's1',
                currentChannelId: 'v1',
                currentChannelName: 'Jam room',
                joinedAt: joined,
                participants: const {
                  's1': {
                    'v1': {'dev-mira'}
                  }
                },
              ))),
        ],
      );
      c.read(vcMediaRouteProvider.notifier).setFor('dev-mira', MediaRoute.direct);
      await tester.pump();
      expect(_badge('Direct'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  _fitGroup();
}

void _fitGroup() {
  group('fit', () {
    for (final width in [320.0, 375.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('phone call screen at $width px, text x$scale',
            (tester) async {
          final c = await _pumpScaled(
            tester,
            const MobileCallScreen(peerId: kFriendPeerId1),
            size: Size(width, 667),
            scale: scale,
            extra: [callProvider.overrideWith(() => _InCall(_longCall()))],
          );
          c.read(callMediaRouteProvider.notifier).set(MediaRoute.relayed);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.textContaining(RegExp(r'^\d+:\d\d:\d\d$')),
              findsOneWidget,
              reason: 'the timer stays');
          await tester.pumpWidget(const SizedBox());
        });

        testWidgets('phone voice room at $width px, text x$scale',
            (tester) async {
          final c = await _pumpScaled(
            tester,
            const MobileVoiceChannelRoute(
                serverId: 's1', channelId: 'v1', channelName: 'Jam room'),
            size: Size(width, 700),
            scale: scale,
            extra: [voiceChannelProvider.overrideWith(() => _Room(_longRoom()))],
          );
          final routes = c.read(vcMediaRouteProvider.notifier);
          routes.setFor('dev-mira', MediaRoute.direct);
          routes.setFor('dev-ana', MediaRoute.relayed);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.textContaining(RegExp(r'^\d+:\d\d:\d\d$')),
              findsOneWidget,
              reason: 'the timer stays');
          await tester.pumpWidget(const SizedBox());
        });
      }
    }

    testWidgets('a phone header with no room drops the badge whole',
        (tester) async {
      final c = await _pumpScaled(
        tester,
        const MobileVoiceChannelRoute(
            serverId: 's1', channelId: 'v1', channelName: 'Jam room'),
        size: const Size(320, 700),
        scale: 2.0,
        extra: [voiceChannelProvider.overrideWith(() => _Room(_longRoom()))],
      );
      final routes = c.read(vcMediaRouteProvider.notifier);
      routes.setFor('dev-mira', MediaRoute.direct);
      routes.setFor('dev-ana', MediaRoute.relayed);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(_shown('Partly relayed'), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'^Partly relayed\.')), findsNothing,
          reason: 'a dropped badge is gone for screen readers too');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a phone header with room keeps it', (tester) async {
      final c = await _pumpScaled(
        tester,
        const MobileCallScreen(peerId: kFriendPeerId1),
        size: const Size(375, 667),
        extra: [callProvider.overrideWith(() => _InCall(_longCall()))],
      );
      c.read(callMediaRouteProvider.notifier).set(MediaRoute.relayed);
      await tester.pump();
      expect(_shown('Relayed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    for (final width in [440.0, 480.0, 520.0]) {
      testWidgets('the DM call row at $width px', (tester) async {
        final c = await _pumpScaled(
          tester,
          const DmCallRow(peerMaster: kFriendPeerId1),
          size: Size(width, 300),
          extra: [callProvider.overrideWith(() => _InCall(_longCall()))],
        );
        c.read(callMediaRouteProvider.notifier).set(MediaRoute.relayed);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Voice call'), findsOneWidget);
      });
    }

    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('the stage bar at 800 px, text x$scale', (tester) async {
        final c = await _pumpScaled(
          tester,
          Center(
              child: CallStageBar(
                  model: _bar(
                      startedAt: DateTime.now(),
                      route: const RoomCallRoute([
                        (id: 'dev-mira', master: 'mira', name: 'Mira'),
                        (id: 'dev-ana', master: 'ana', name: 'Ana'),
                      ])))),
          size: const Size(800, 600),
          scale: scale,
        );
        c.read(vcMediaRouteProvider.notifier)
          ..setFor('dev-mira', MediaRoute.direct)
          ..setFor('dev-ana', MediaRoute.relayed);
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);

  @override
  CallState build() => initial;
}

class _Room extends VoiceChannelNotifier {
  final VoiceChannelState initial;
  _Room(this.initial);

  @override
  VoiceChannelState build() => initial;
}

class _QuietStatus extends StatusNotifier {
  @override
  StatusState build() => const StatusState();
}

class _NoRingtone extends RingtonePathNotifier {
  @override
  Future<String?> build() async => null;
}
