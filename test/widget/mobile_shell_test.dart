import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/greeting.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart' show HomeGreeting;
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/ui/components/nav_selection_mark.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_servers_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';

import '../helpers/test_app.dart';

/// Tap a nav bar tab by label. Uses `find.descendant` to target
/// only the label inside MobileNavBar (avoids ambiguity with
/// tab content that may contain the same text, e.g. "Archive").
Future<void> _tapNavTab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(MobileNavBar),
    matching: find.text(label),
  );
  expect(tab, findsOneWidget, reason: '"$label" tab should exist in nav bar');
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

void main() {
  group('Mobile Shell', () {
    testWidgets('renders MobileShell on narrow viewport', (tester) async {
      await pumpHollowMobile(tester);
      expect(find.byType(MobileShell), findsOneWidget);
    });

    testWidgets('the bar reads Chats, Servers, add, Friends, Settings',
        (tester) async {
      await pumpHollowMobile(tester);
      final navBar = find.byType(MobileNavBar);
      double x(Finder f) => tester.getCenter(f).dx;
      final slots = [
        find.descendant(of: navBar, matching: find.text('Chats')),
        find.descendant(of: navBar, matching: find.text('Servers')),
        find.descendant(of: navBar, matching: find.bySemanticsLabel('Add a server')),
        find.descendant(of: navBar, matching: find.text('Friends')),
        find.descendant(of: navBar, matching: find.text('Settings')),
      ];
      for (final slot in slots) {
        expect(slot, findsOneWidget);
      }
      for (var i = 1; i < slots.length; i++) {
        expect(x(slots[i]), greaterThan(x(slots[i - 1])));
      }
      expect(find.descendant(of: navBar, matching: find.text('Archive')),
          findsNothing,
          reason: 'Archive opens from the Chats header now');
    });

    testWidgets('the selection mark sits over the tab that is open',
        (tester) async {
      await pumpHollowMobile(tester);
      for (final tab in ['Chats', 'Servers', 'Friends', 'Settings']) {
        await _tapNavTab(tester, tab);
        final label = find.descendant(
            of: find.byType(MobileNavBar), matching: find.text(tab));
        expect(tester.getCenter(find.byType(NavSelectionMark)).dx,
            moreOrLessEquals(tester.getCenter(label).dx, epsilon: 1),
            reason: tab);
      }
    });

    testWidgets('starts on the Chats tab', (tester) async {
      await pumpHollowMobile(tester);
      expect(find.byType(MobileChatsTab), findsOneWidget);
    });

    testWidgets('tap Friends tab switches view', (tester) async {
      await pumpHollowMobile(tester);
      await _tapNavTab(tester, 'Friends');
      expect(find.byType(MobileFriendsTab), findsOneWidget);
    });

    testWidgets('tap Servers tab switches view', (tester) async {
      await pumpHollowMobile(tester);
      await _tapNavTab(tester, 'Servers');
      expect(find.byType(MobileServersTab), findsOneWidget);
      expect(find.byType(MobileChatsTab), findsNothing);
    });

    testWidgets('tap Settings tab switches view', (tester) async {
      await pumpHollowMobile(tester);
      await _tapNavTab(tester, 'Settings');
      expect(find.byType(MobileSettingsTab), findsOneWidget);
    });

    // Review M2: the server you add lands on the Servers tab, where you see
    // it arrive; servers no longer show in Chats.
    testWidgets('the centre add opens on the Servers tab', (tester) async {
      await pumpHollowMobile(tester);
      final container = ProviderScope.containerOf(
          tester.element(find.byType(MobileShell)));
      expect(container.read(mobileTabProvider), MobileTab.chats);
      await tester.tap(find.descendant(
          of: find.byType(MobileNavBar),
          matching: find.bySemanticsLabel('Add a server')));
      await tester.pumpAndSettle();
      expect(container.read(mobileTabProvider), MobileTab.servers);
    });

    // Review M1: the call bar docks between the tab and the strips under it,
    // so it never covers the last rows, the status strip or its close.
    testWidgets('a minimised call docks above the status strip on every tab',
        (tester) async {
      await pumpHollowMobile(tester, extraOverrides: [
        voiceChannelProvider.overrideWith(() => _InRoom(const VoiceChannelState(
              currentServerId: 's1',
              currentChannelId: 'v1',
              currentChannelName: 'Jam room',
            ))),
      ]);
      for (final tab in ['Chats', 'Servers']) {
        await _tapNavTab(tester, tab);
        final bar = find.byType(MobileMinimisedCall);
        expect(bar, findsOneWidget);
        expect(find.ancestor(of: bar, matching: find.byType(Positioned)),
            findsNothing,
            reason: 'floating over the tab on $tab');
        final call = tester.getRect(bar);
        final body = tester.getRect(find.byType(
            tab == 'Chats' ? MobileChatsTab : MobileServersTab));
        final strip = tester.getRect(find.byType(SystemStatusBanner));
        expect(call.top, greaterThanOrEqualTo(body.bottom), reason: tab);
        expect(call.bottom, lessThanOrEqualTo(strip.top), reason: tab);
        expect(call.bottom,
            lessThanOrEqualTo(tester.getRect(find.byType(MobileNavBar)).top),
            reason: tab);
      }
    });

    // Review L1: the phone header sheds the name before it cuts the
    // greeting; a wide window keeps the whole line. Every greeting at a pinned
    // hour: the test font draws each glyph as a fontSize square, so "Good
    // afternoon, Kind Stranger" needs 580 px and only fits from about 740 px.
    for (final hour in [3, 9, 15, 21]) {
      for (final (width, full) in [(320.0, false), (800.0, true)]) {
        testWidgets('the greeting at $hour:00, $width wide, '
            '${full ? 'keeps' : 'sheds'} the name', (tester) async {
          final at = DateTime(2026, 11, 22, hour);
          debugGreetingClock = () => at;
          addTearDown(() => debugGreetingClock = null);
          await pumpHollowMobile(tester, viewportSize: Size(width, 800));
          final text = tester.widget<Text>(find.descendant(
              of: find.byType(HomeGreeting), matching: find.byType(Text)));
          final greeting = greetingFor(at);
          if (full) {
            expect(text.data, startsWith('$greeting, '));
          } else {
            expect(text.data, greeting);
          }
        });
      }
    }

    testWidgets('can cycle through all tabs and return to Chats',
        (tester) async {
      await pumpHollowMobile(tester);

      for (final tab in ['Servers', 'Friends', 'Settings', 'Chats']) {
        await _tapNavTab(tester, tab);
      }

      expect(find.byType(MobileChatsTab), findsOneWidget);
    });
  });
}

class _InRoom extends VoiceChannelNotifier {
  final VoiceChannelState initial;
  _InRoom(this.initial);

  @override
  VoiceChannelState build() => initial;
}
