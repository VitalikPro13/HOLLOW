/// The phone's app-wide connection indicator: when it speaks (only after the
/// link has been down for 1.5 s on screen), what it says, where it shows (every
/// tab and every route pushed on the phone) and where it never does (under the
/// app lock, over a ringing call, over the call surfaces with their own link
/// state, before there is an identity).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_connection_indicator.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_share_fullscreen.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/lock_cover.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

const _reconnecting = 'Reconnecting…';
const _connecting = 'Connecting…';
const _noConnection = 'No connection';

Finder _said(String label) => find.descendant(
    of: find.byType(MobileConnectionIndicator), matching: find.text(label));

Finder _inIndicator(Finder matching) =>
    find.descendant(of: find.byType(MobileConnectionIndicator), matching: matching);

/// The shell, settled while connected, with the relay link in the test's hands.
Future<TestRelayStatus> _shell(
  WidgetTester tester, {
  List<Override> extra = const [],
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  final relay = TestRelayStatus();
  await pumpHollowMobile(
    tester,
    textScaler: textScaler,
    extraOverrides: [
      connectionStatusProvider.overrideWith(() => relay),
      statusProvider.overrideWith(_QuietStatus.new),
      ringtonePathProvider.overrideWith(_NoRingtone.new),
      ...extra,
    ],
  );
  return relay;
}

/// Takes the link down and waits out the delay, so the indicator is showing.
Future<void> _downAndShown(
    WidgetTester tester, TestRelayStatus relay, RelayConnectionStatus status) async {
  relay.set(status);
  await tester.pump();
  await tester.pump(kConnectionIndicatorDelay);
  await tester.pump(const Duration(milliseconds: 300));
}

/// The shell stays mounted, offstage, under every page pushed above it.
Element _shellElement(WidgetTester tester) =>
    tester.element(find.byType(MobileShell, skipOffstage: false));

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(_shellElement(tester));

NavigatorState _nav(WidgetTester tester) =>
    Navigator.of(_shellElement(tester), rootNavigator: true);

/// Walks the lifecycle the way the platform does, one legal step at a time.
Future<void> _goAway(WidgetTester tester) async {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
  await tester.pump();
}

Future<void> _comeBack(WidgetTester tester) async {
  for (final s in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
  await tester.pump();
}

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(
      find.descendant(of: find.byType(MobileNavBar), matching: find.text(label)));
  await tester.pumpAndSettle();
}

void main() {
  group('timing', () {
    testWidgets('says nothing for the first 1.5 s of an outage, then speaks',
        (tester) async {
      final relay = await _shell(tester);
      relay.set(RelayConnectionStatus.reconnecting);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1400));
      expect(_said(_reconnecting), findsNothing,
          reason: 'a resume takes under a second and must never flash it');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_said(_reconnecting), findsOneWidget);
    });

    testWidgets('a blip shorter than the delay never shows', (tester) async {
      final relay = await _shell(tester);
      relay.set(RelayConnectionStatus.reconnecting);
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(_said(_reconnecting), findsNothing);
      }
      relay.set(RelayConnectionStatus.connected);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(HollowSpinner), findsNothing);
      }
    });

    testWidgets('leaves at once when the link is back', (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      expect(_said(_noConnection), findsOneWidget);

      final semantics = tester.ensureSemantics();
      relay.set(RelayConnectionStatus.connected);
      await tester.pump();
      expect(find.bySemanticsLabel(_noConnection), findsNothing,
          reason: 'nothing announces a state that just ended');
      await tester.pump(HollowDurations.exit);
      await tester.pump(const Duration(milliseconds: 16));
      expect(_said(_noConnection), findsNothing);
      semantics.dispose();
    });

    testWidgets('a second outage waits its own 1.5 s', (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      relay.set(RelayConnectionStatus.connected);
      await tester.pump(const Duration(seconds: 1));
      relay.set(RelayConnectionStatus.reconnecting);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1400));
      expect(_said(_reconnecting), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_said(_reconnecting), findsOneWidget);
    });
  });

  group('what it says', () {
    test('the desktop words, and nothing while connected', () {
      expect(connectionIndicatorContent(OverallConnection.connected), isNull);
      expect(connectionIndicatorContent(OverallConnection.connecting),
          (label: _connecting, busy: true));
      expect(connectionIndicatorContent(OverallConnection.reconnecting),
          (label: _reconnecting, busy: true));
      expect(connectionIndicatorContent(OverallConnection.offline),
          (label: _noConnection, busy: false));
      expect(connectionIndicatorContent(OverallConnection.error),
          (label: _noConnection, busy: false));
      for (final c in OverallConnection.values) {
        final label = connectionIndicatorContent(c)?.label ?? '';
        expect(label.contains('—'), isFalse, reason: 'no em dash in $c');
      }
    });

    testWidgets('reconnecting: a spinner and the word', (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.reconnecting);
      expect(_said(_reconnecting), findsOneWidget);
      expect(_inIndicator(find.byType(HollowSpinner)), findsOneWidget);
      expect(_inIndicator(find.byIcon(LucideIcons.wifiOff)), findsNothing);
    });

    testWidgets('the first connect after launch says Connecting',
        (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.connecting);
      expect(_said(_connecting), findsOneWidget);
      expect(_inIndicator(find.byType(HollowSpinner)), findsOneWidget);
    });

    testWidgets('offline: the wifi-off mark and No connection',
        (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      expect(_said(_noConnection), findsOneWidget);
      expect(_inIndicator(find.byIcon(LucideIcons.wifiOff)), findsOneWidget);
      expect(_inIndicator(find.byType(HollowSpinner)), findsNothing);
    });

    testWidgets('a node that failed to start reads No connection too',
        (tester) async {
      final node = _Node();
      final relay = await _shell(tester,
          extra: [nodeProvider.overrideWith(() => node)]);
      relay.set(RelayConnectionStatus.connected);
      node.set(NodeStatus.error);
      await tester.pump();
      await tester.pump(kConnectionIndicatorDelay);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_said(_noConnection), findsOneWidget);
      expect(_inIndicator(find.byIcon(LucideIcons.wifiOff)), findsOneWidget);
    });

    testWidgets('a live region a screen reader announces', (tester) async {
      final semantics = tester.ensureSemantics();
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      expect(
        tester.getSemantics(find.bySemanticsLabel(_noConnection)),
        isSemantics(label: _noConnection, isLiveRegion: true),
      );
      semantics.dispose();
    });

    testWidgets('grows with the text size and never overflows',
        (tester) async {
      final relay =
          await _shell(tester, textScaler: const TextScaler.linear(2.0));
      await _downAndShown(tester, relay, RelayConnectionStatus.reconnecting);
      expect(_said(_reconnecting), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_said(_reconnecting)).height, greaterThan(24));
    });

    testWidgets('reduce motion: it is simply there, no fade and no drop',
        (tester) async {
      HollowDurations.animationsDisabled = true;
      addTearDown(() => HollowDurations.animationsDisabled = false);
      final relay = await _shell(tester);
      relay.set(RelayConnectionStatus.disconnected);
      await tester.pump();
      await tester.pump(kConnectionIndicatorDelay);
      await tester.pump();
      final fade = tester.widget<FadeTransition>(
          _inIndicator(find.byType(FadeTransition)).first);
      expect(fade.opacity.value, 1.0);
    });
  });

  group('where it shows', () {
    testWidgets('on every tab, in the same spot', (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      final spot = tester.getCenter(_said(_noConnection));
      for (final tab in ['Friends', 'Archive', 'Settings', 'Chats']) {
        await _tapTab(tester, tab);
        expect(_said(_noConnection), findsOneWidget, reason: tab);
        expect(tester.getCenter(_said(_noConnection)), spot, reason: tab);
      }
    });

    testWidgets('just under the status bar, centred', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 47);
      addTearDown(tester.view.resetPadding);
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      final card = tester.getRect(_inIndicator(find.byType(DecoratedBox)).first);
      expect(card.top, greaterThanOrEqualTo(47));
      expect(card.top, lessThan(47 + 24));
      expect(card.center.dx, closeTo(400 / 2, 0.5));
    });

    testWidgets('over a pushed page, a dialog and a sheet', (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      final overlay = tester.state<OverlayState>(find.byType(Overlay).first);

      _nav(tester).push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('a pushed page'))));
      await tester.pumpAndSettle();
      expect(find.text('a pushed page'), findsOneWidget);
      expect(_said(_noConnection), findsOneWidget);
      expect(overlay.debugIsVisible(MobileConnectionIndicatorHost.debugEntry!),
          isTrue,
          reason: 'above the opaque page, not behind it');

      final pageContext = tester.element(find.text('a pushed page'));
      showHollowDialog<void>(
        context: pageContext,
        builder: (_) => const HollowDialog(
            title: 'A dialog', content: SizedBox.shrink()),
      );
      await tester.pumpAndSettle();
      expect(find.text('A dialog'), findsOneWidget);
      expect(_said(_noConnection), findsOneWidget);
      expect(overlay.debugIsVisible(MobileConnectionIndicatorHost.debugEntry!),
          isTrue);
      _nav(tester).pop();
      await tester.pumpAndSettle();

      showHollowSheet<void>(
        context: pageContext,
        builder: (_) => const SizedBox(height: 200, child: Text('a sheet')),
      );
      await tester.pumpAndSettle();
      expect(find.text('a sheet'), findsOneWidget);
      expect(_said(_noConnection), findsOneWidget);
      expect(overlay.debugIsVisible(MobileConnectionIndicatorHost.debugEntry!),
          isTrue);
    });

    testWidgets('never takes a tap meant for the screen under it',
        (tester) async {
      final relay = await _shell(tester);
      var taps = 0;
      _nav(tester).push(MaterialPageRoute<void>(
        builder: (_) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: const SizedBox.expand(),
        ),
      ));
      await tester.pumpAndSettle();
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      await tester.tapAt(tester.getCenter(_said(_noConnection)));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('where it never shows', () {
    testWidgets('under the app lock: the lock takes it down, and back after',
        (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      expect(MobileConnectionIndicatorHost.debugEntry, isNotNull);
      expect(OverlayHosts.openCount, 1, reason: 'registered as a raw host');

      _container(tester).read(appLockedProvider.notifier).setLocked(true);
      _nav(tester).push(lockCoverRoute());
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(MobileConnectionIndicatorHost.debugEntry, isNull,
          reason: 'nothing of ours stays above the cover');
      expect(find.byType(MobileConnectionIndicator), findsNothing);
      expect(OverlayHosts.openCount, 0);

      _nav(tester).pop();
      _container(tester).read(appLockedProvider.notifier).setLocked(false);
      await tester.pump();
      await tester.pump();
      expect(MobileConnectionIndicatorHost.debugEntry, isNotNull,
          reason: 'it comes back once the lock lifts');
      await tester.pump(kConnectionIndicatorDelay);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_said(_noConnection), findsOneWidget);
    });

    testWidgets('the indicator itself stays blank while locked',
        (tester) async {
      Future<void> mount(bool locked) async {
        await tester.pumpWidget(ProviderScope(
          overrides: hollowTestOverrides(extra: [
            connectionStatusProvider.overrideWith(
                () => TestRelayStatus(RelayConnectionStatus.disconnected)),
            appLockedProvider.overrideWith(() => _Locked(locked)),
          ]),
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: const Stack(children: [MobileConnectionIndicator()]),
          ),
        ));
        await tester.pump(kConnectionIndicatorDelay);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await mount(false);
      expect(_said(_noConnection), findsOneWidget, reason: 'the control');
      await tester.pumpWidget(const SizedBox());
      await mount(true);
      expect(_said(_noConnection), findsNothing);
    });

    testWidgets('over a call ringing in full screen', (tester) async {
      final calls = _Calls();
      final relay =
          await _shell(tester, extra: [callProvider.overrideWith(() => calls)]);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      calls.ringIn();
      await tester.pump();
      await tester.pump(HollowDurations.exit);
      await tester.pump(const Duration(milliseconds: 16));
      expect(_said(_noConnection), findsNothing);
      calls.end();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_said(_noConnection), findsOneWidget);
    });

    testWidgets('over a call surface with its own link state, until it is '
        'covered in turn', (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);

      _nav(tester).push(MaterialPageRoute<void>(
        builder: (_) => const ConnectionIndicatorCover(
            child: Scaffold(body: Text('the call'))),
      ));
      await tester.pumpAndSettle();
      expect(find.text('the call'), findsOneWidget);
      expect(_said(_noConnection), findsNothing);

      // An opaque page above it (the chat, opened from the call) shows it again.
      _nav(tester).push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('above the call'))));
      await tester.pumpAndSettle();
      expect(_said(_noConnection), findsOneWidget);

      _nav(tester).pop();
      await tester.pumpAndSettle();
      expect(_said(_noConnection), findsNothing);
      _nav(tester).pop();
      await tester.pumpAndSettle();
      expect(_said(_noConnection), findsOneWidget);
    });

    testWidgets('the DM call screen is such a surface', (tester) async {
      final relay = await _shell(tester, extra: [
        callProvider.overrideWith(() => _Calls(CallState(
              status: CallStatus.active,
              peerId: kFriendPeerId1,
              callId: 'c1',
              direction: CallDirection.outgoing,
              startedAt: DateTime.now(),
            ))),
      ]);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      _nav(tester).push(MaterialPageRoute<void>(
          builder: (_) => const MobileCallScreen(peerId: kFriendPeerId1)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
          find.descendant(
              of: find.byType(MobileCallScreen),
              matching: find.byType(ConnectionIndicatorCover)),
          findsOneWidget);
      expect(_said(_noConnection), findsNothing);
    });

    testWidgets('and so is a share watched full screen', (tester) async {
      await _shell(tester);
      _nav(tester).push(MaterialPageRoute<void>(
          builder: (_) => const MobileShareFullscreen(
              source: DmCallStageSource(kFriendPeerId1),
              owner: kFriendPeerId1)));
      await tester.pump();
      // Its first frame is offstage (the hero pass); the route then closes
      // itself, as nothing is being shared.
      expect(
          find.descendant(
              of: find.byType(MobileShareFullscreen, skipOffstage: false),
              matching:
                  find.byType(ConnectionIndicatorCover, skipOffstage: false),
              skipOffstage: false),
          findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('before there is an identity (welcome, the launch prompt)',
        (tester) async {
      final relay = await _shell(tester,
          extra: [identityProvider.overrideWith(_NoIdentity.new)]);
      relay.set(RelayConnectionStatus.disconnected);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(_said(_noConnection), findsNothing);
    });
  });

  group('the app going away and coming back', () {
    tearDown(() {
      // The binding outlives a test: leave it in the foreground.
      final binding = TestWidgetsFlutterBinding.instance;
      if (binding.lifecycleState != AppLifecycleState.resumed) {
        for (final s in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          binding.handleAppLifecycleStateChanged(s);
        }
      }
    });

    testWidgets('gone while away; on return the 1.5 s starts again',
        (tester) async {
      final relay = await _shell(tester);
      await _downAndShown(tester, relay, RelayConnectionStatus.disconnected);
      // No frames are drawn while away (the binding stops them, as a phone does).
      await _goAway(tester);
      await tester.pump(const Duration(seconds: 5));

      await _comeBack(tester);
      expect(_said(_noConnection), findsNothing,
          reason: 'the first frame back carries no leftover, not even an exit');
      await tester.pump(const Duration(milliseconds: 1400));
      expect(_said(_noConnection), findsNothing,
          reason: 'the delay counts from the return');
      await tester.pump(const Duration(milliseconds: 400));
      expect(_said(_noConnection), findsOneWidget);
    });

    testWidgets('a quick trip that resumes in under a second never flashes it',
        (tester) async {
      final relay = await _shell(tester);
      await _goAway(tester);
      // Ten seconds away the socket is suspended; the relay holds the session.
      relay.set(RelayConnectionStatus.reconnecting);
      await tester.pump(const Duration(seconds: 30));
      relay.set(RelayConnectionStatus.disconnected);
      await tester.pump(const Duration(minutes: 3));

      await _comeBack(tester);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(_said(_noConnection), findsNothing);
      }
      relay.set(RelayConnectionStatus.connected);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(MobileConnectionIndicator), findsOneWidget);
        expect(_said(_noConnection), findsNothing);
        expect(_said(_reconnecting), findsNothing);
      }
    });
  });
}

class _QuietStatus extends StatusNotifier {
  @override
  StatusState build() => const StatusState();
}

class _NoRingtone extends RingtonePathNotifier {
  @override
  Future<String?> build() async => null;
}

class _Node extends NodeNotifier {
  @override
  NodeState build() => testNodeConnected;

  void set(NodeStatus status) => state = NodeState(status: status);
}

class _Locked extends AppLockedNotifier {
  final bool locked;
  _Locked(this.locked);

  @override
  bool build() => locked;
}

class _NoIdentity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState();
}

class _Calls extends CallNotifier {
  final CallState initial;
  _Calls([this.initial = const CallState()]);

  @override
  CallState build() => initial;

  void ringIn() => state = const CallState(
        status: CallStatus.ringing,
        peerId: kFriendPeerId1,
        callId: 'c1',
        direction: CallDirection.incoming,
      );

  void end() => state = const CallState();
}
