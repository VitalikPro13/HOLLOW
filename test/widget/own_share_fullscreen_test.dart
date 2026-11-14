/// Your own screen share never opens full screen (Vitalik 11-14): a full
/// screen of it films the screen showing the capture, a hall of mirrors.
/// Someone else's share keeps full screen exactly as before. Covered on every
/// stage host's source (DM call, voice room, meeting) and on the phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/call/share_tile.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

const _me = kLocalPeerId;
const _mira = kFriendPeerId1;
const _server = kServerId1;
const _channel = kVoiceChannelId;

/// One stage host: its source, and the overrides that put us in its call
/// sharing our screen while watching Mira's, focused on [focusOwner]'s share.
class _Host {
  final String name;
  final CallStageSource source;
  final List<Override> Function(String focusOwner) overrides;

  /// Moves the focus to [owner]'s share from outside the stage.
  final void Function(ProviderContainer c, String owner) focus;
  const _Host(this.name, this.source, this.overrides, this.focus);
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);
  @override
  CallState build() => initial;
}

class _Room extends VoiceChannelNotifier {
  final VoiceChannelState initial;
  final RTCVideoRenderer? ownPreview;
  _Room(this.initial, {this.ownPreview});
  @override
  VoiceChannelState build() => initial;
  @override
  RTCVideoRenderer? get localScreenShareRenderer => ownPreview;
}

/// The voice room stage in [vc], our share previewing through [ownPreview].
_Host _room(VoiceChannelState vc, {RTCVideoRenderer? ownPreview}) => _Host(
      'room',
      const VcCallStageSource(serverId: _server, channelId: _channel),
      (_) => [
        localDevicePeerIdProvider.overrideWith((_) async => null),
        voiceChannelProvider
            .overrideWith(() => _Room(vc, ownPreview: ownPreview)),
      ],
      (_, _) {},
    );

Finder _video(Finder tile) =>
    find.descendant(of: tile, matching: find.byType(RTCVideoView));

_Host _roomHost(String name, String serverId, String channelId) => _Host(
      name,
      VcCallStageSource(serverId: serverId, channelId: channelId),
      (owner) => [
        localDevicePeerIdProvider.overrideWith((_) async => null),
        voiceChannelProvider.overrideWith(() => _Room(VoiceChannelState(
              currentServerId: serverId,
              currentChannelId: channelId,
              joinedAt: DateTime.now(),
              participants: {
                serverId: {
                  channelId: {_me, _mira}
                }
              },
              isScreenSharing: true,
              peerScreenSharing: const {_mira: true},
              watchingScreenShares: const {_mira},
              focusedScreenSharePeerId: owner,
              focusedSourceType: 'screen',
            ))),
      ],
      (c, owner) =>
          c.read(voiceChannelProvider.notifier).setFocusedSource(owner, 'screen'),
    );

final _hosts = [
  _Host(
    'DM call',
    const DmCallStageSource(_mira),
    (owner) => [
      callProvider.overrideWith(() => _InCall(CallState(
            status: CallStatus.active,
            peerId: _mira,
            callId: 'c1',
            direction: CallDirection.outgoing,
            startedAt: DateTime.now(),
            isScreenSharing: true,
            remoteScreenSharing: true,
            watchingRemoteShare: true,
          ))),
      focusedDmSourceProvider.overrideWith(
          (_) => DmFocusedSource(peerId: owner, type: 'screen')),
    ],
    (c, owner) => c.read(focusedDmSourceProvider.notifier).state =
        DmFocusedSource(peerId: owner, type: 'screen'),
  ),
  _roomHost('voice room', _server, _channel),
  _roomHost('meeting', conferenceServerId('m1'), 'main'),
];

Future<ProviderContainer> _pumpStage(
    WidgetTester tester, _Host host, String focusOwner) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: host.overrides(focusOwner)));
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: CallStage(source: host.source)),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

Finder _fullscreenButton() => find.byWidgetPredicate(
    (w) => w is CallToggleButton && w.label == 'Full screen');

Finder _shareTile({required bool mine, required CallTileSize size}) =>
    find.byWidgetPredicate((w) =>
        w is ShareTile && w.share.isMine == mine && w.size == size);

/// A route change plus its 150 ms fade.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _leaveFullscreen(WidgetTester tester) async {
  final route = find.byType(CallFullscreenRoute);
  if (route.evaluate().isEmpty) return;
  Navigator.of(tester.element(route)).pop();
  await _settle(tester);
}

CallShare _liveShare(String owner, {required bool mine}) => CallShare(
      owner: owner,
      master: owner,
      isMine: mine,
      name: mine ? 'You' : owner,
      watched: true,
    );

void main() {
  for (final host in _hosts) {
    group('${host.name}: your own share', () {
      testWidgets('focused, it offers no full screen', (tester) async {
        await _pumpStage(tester, host, _me);
        final mine = _shareTile(mine: true, size: CallTileSize.large);
        expect(mine, findsOneWidget, reason: 'our share is the focus');
        expect(_fullscreenButton(), findsNothing,
            reason: 'the bar has no Full screen for our own share');

        await tester.tap(mine);
        await _settle(tester);
        expect(find.byType(CallFullscreenRoute), findsNothing,
            reason: 'clicking our own focused share opens nothing');
        expect(tester.widget<ShareTile>(mine).onTap, isNull);
      });

      testWidgets("someone else's focused share still opens full screen",
          (tester) async {
        await _pumpStage(tester, host, _mira);
        expect(_fullscreenButton(), findsOneWidget);

        await tester.tap(_shareTile(mine: false, size: CallTileSize.large));
        await _settle(tester);
        expect(find.byType(CallFullscreenRoute), findsOneWidget);
        await _leaveFullscreen(tester);

        await tester.tap(_fullscreenButton());
        await _settle(tester);
        expect(find.byType(CallFullscreenRoute), findsOneWidget);
        await _leaveFullscreen(tester);
      });

      testWidgets('in full screen it never takes the stage', (tester) async {
        final container = await _pumpStage(tester, host, _mira);
        await tester.tap(_fullscreenButton());
        await _settle(tester);
        expect(find.byType(CallFullscreenRoute), findsOneWidget);

        final strip = _shareTile(mine: true, size: CallTileSize.strip);
        expect(strip, findsOneWidget, reason: 'our share sits in the strip');
        expect(tester.widget<ShareTile>(strip).onTap, isNull,
            reason: 'clicking it would fill the full screen with itself');

        // However the focus lands on it (the Layout control, a share that
        // ended), full screen gives way to the pane.
        host.focus(container, _me);
        await _settle(tester);
        expect(find.byType(CallFullscreenRoute), findsNothing);
        expect(_shareTile(mine: true, size: CallTileSize.large),
            findsOneWidget);
        expect(_fullscreenButton(), findsNothing);
      });
    });
  }

  group('full screen', () {
    testWidgets("another person's strip share still takes focus",
        (tester) async {
      const kai = kFriendPeerId2;
      final container = await _pumpStage(
          tester,
          _room(VoiceChannelState(
            currentServerId: _server,
            currentChannelId: _channel,
            joinedAt: DateTime.now(),
            participants: {
              _server: {
                _channel: {_me, _mira, kai}
              }
            },
            isScreenSharing: true,
            peerScreenSharing: const {_mira: true, kai: true},
            watchingScreenShares: const {_mira, kai},
            focusedScreenSharePeerId: _mira,
            focusedSourceType: 'screen',
          )),
          _mira);
      await tester.tap(_fullscreenButton());
      await _settle(tester);
      expect(find.byType(CallFullscreenRoute), findsOneWidget);
      final strip = find.byWidgetPredicate((w) =>
          w is ShareTile &&
          w.share.owner == kai &&
          w.size == CallTileSize.strip);
      expect(strip, findsOneWidget);
      expect(tester.widget<ShareTile>(strip).onTap, isNotNull);
      await tester.tap(strip);
      await _settle(tester);
      expect(container.read(voiceChannelProvider).focusedScreenSharePeerId,
          kai);
      expect(find.byType(CallFullscreenRoute), findsOneWidget);
    });

    testWidgets('the grid shows our own share as its placeholder, never live',
        (tester) async {
      final preview = RTCVideoRenderer();
      await _pumpStage(
          tester,
          _room(
            VoiceChannelState(
              currentServerId: _server,
              currentChannelId: _channel,
              joinedAt: DateTime.now(),
              participants: {
                _server: {
                  _channel: {_me}
                }
              },
              isScreenSharing: true,
              focusedScreenSharePeerId: _me,
              focusedSourceType: 'screen',
              isGridView: true,
            ),
            ownPreview: preview,
          ),
          _me);
      final mine = _shareTile(mine: true, size: CallTileSize.large);
      expect(_video(mine), findsOneWidget,
          reason: 'the pane grid keeps its preview');
      expect(_fullscreenButton(), findsOneWidget,
          reason: 'the grid still offers Full screen while we share');

      await tester.tap(_fullscreenButton());
      await _settle(tester);
      expect(find.byType(CallFullscreenRoute), findsOneWidget);
      final full = find.descendant(
          of: find.byType(CallFullscreenRoute), matching: mine);
      expect(full, findsOneWidget);
      expect(_video(full), findsNothing,
          reason: 'a live preview here films the full screen showing it');
      expect(tester.widget<ShareTile>(full).share.renderer, isNull);
      await _leaveFullscreen(tester);
    });
  });

  group('phone', () {
    Future<void> pumpPhone(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(body: child),
        ),
      ));
      await tester.pump();
    }

    Finder fullScreen() => find.bySemanticsLabel('Full screen');

    testWidgets('a live share of our own offers no full screen',
        (tester) async {
      var opened = 0;
      await pumpPhone(
          tester,
          MobileLiveShare(
            share: _liveShare(_me, mine: true),
            onFullscreen: () => opened++,
          ));
      expect(fullScreen(), findsNothing);
      await tester.tap(find.byType(ShareTile));
      await tester.pump();
      expect(opened, 0);
    });

    testWidgets("someone else's live share opens full screen both ways",
        (tester) async {
      var opened = 0;
      await pumpPhone(
          tester,
          MobileLiveShare(
            share: _liveShare(_mira, mine: false),
            onFullscreen: () => opened++,
          ));
      expect(fullScreen(), findsOneWidget);
      await tester.tap(fullScreen());
      await tester.tap(find.byType(ShareTile));
      await tester.pump();
      expect(opened, 2);
    });

    testWidgets('the watching screen previews only the share we watch',
        (tester) async {
      final data = CallStageData(
        people: const [],
        shares: [
          _liveShare(_mira, mine: false),
          _liveShare(_me, mine: true),
        ],
        focus: const CallSourceId.screen(_me),
        gridOn: false,
        onFocus: (_) {},
        onGrid: (_) {},
        onWatch: (_) {},
        onStopWatching: (_) {},
        onStopSharing: () {},
      );
      final watched = watchedShareOf(data);
      expect(watched?.owner, _mira,
          reason: 'our own share, even focused, is never the one watched');
      await pumpPhone(
          tester,
          MobileWatchingView(
            data: data,
            share: watched!,
            peopleTitle: 'In the room',
            onFullscreen: () {},
          ));
      expect(find.byType(MobileOwnShare), findsOneWidget);
      expect(fullScreen(), findsOneWidget, reason: "only Mira's share");
      expect(find.byType(MobileLiveShare), findsOneWidget);
    });

    test('with only our own share live there is nothing to watch', () {
      final data = CallStageData(
        people: const [],
        shares: [_liveShare(_me, mine: true)],
        focus: const CallSourceId.screen(_me),
        gridOn: false,
        onFocus: (_) {},
        onGrid: (_) {},
        onWatch: (_) {},
        onStopWatching: (_) {},
        onStopSharing: () {},
      );
      expect(watchedShareOf(data), isNull);
    });
  });
}
