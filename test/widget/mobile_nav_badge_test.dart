import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';

import '../helpers/mobile_servers_fixture.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Finds [text] only inside the nav bar. The mobile shell mounts every tab at
/// once (IndexedStack), so any tab body can render the same digits a badge does
/// (e.g. the Settings "Your Stats" card). Scope to the nav bar so these badge
/// assertions test the badge — not "this digit appears nowhere else".
Finder navBarText(String text) => find.descendant(
      of: find.byType(MobileNavBar),
      matching: find.text(text),
    );

/// A tab's screen-reader label: the tab, its count and what is counted.
Finder navTabLabel(String label) => find.descendant(
      of: find.byType(MobileNavBar),
      matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == label),
    );

final _noMentions = UnreadState(
  channelLastSeen: const {},
  dmLastSeen: const {},
  channelUnreadCounts: kFixtureUnread.channelUnreadCounts,
  dmUnreadCounts: kFixtureUnread.dmUnreadCounts,
  channelLatestId: const {},
  dmLatestId: const {},
  channelMentionCounts: const {},
);

void main() {
  group('Mobile nav bar badges', () {
    testWidgets('Chats counts DMs and Servers counts channels', (tester) async {
      await pumpHollowMobile(
        tester,
        extraOverrides: [
          unreadProvider.overrideWith(() => _UnreadWithCounts()),
          serverListProvider.overrideWith(() => FixtureServers(testServers)),
        ],
      );

      // 2 DM unread on Chats; the channel's 3 on Servers, never summed.
      expect(navTabLabel('Chats, 2 unreads'), findsOneWidget);
      expect(navTabLabel('Servers, 3 unreads'), findsOneWidget);
      expect(navBarText('5'), findsNothing);
    });

    testWidgets('a mention puts a red @ on Servers, never on Chats',
        (tester) async {
      await pumpHollowMobile(
        tester,
        viewportSize: const Size(390, 1200),
        extraOverrides: mobileServersFixture(),
      );

      // Pixel Guild's 2 mentions beat every unread post; Chats keeps the DM's 4.
      expect(navTabLabel('Servers, 2 mentions'), findsOneWidget);
      expect(navBarText('@2'), findsOneWidget);
      expect(navTabLabel('Chats, 4 unreads'), findsOneWidget);
    });

    testWidgets('muted and age-hidden servers add nothing', (tester) async {
      await pumpHollowMobile(
        tester,
        viewportSize: const Size(390, 1200),
        extraOverrides: [
          ...mobileServersFixture(),
          unreadProvider.overrideWith(() => FixtureUnread(_noMentions)),
        ],
      );

      // Pixel Guild 6 + Synth Lab 3; Night Owls (muted, 9) and the hidden 50
      // stay out.
      expect(navTabLabel('Servers, 9 unreads'), findsOneWidget);
      expect(navBarText('9'), findsOneWidget);
    });

    testWidgets('shows pending friend request badge', (tester) async {
      await pumpHollowMobile(tester);

      // testFriends has 1 pending incoming request (kFriendPeerId3)
      expect(navBarText('1'), findsOneWidget);
    });

    testWidgets('no badges when no unread and no pending', (tester) async {
      await pumpHollowMobile(
        tester,
        extraOverrides: [
          friendsProvider.overrideWith(() => _EmptyFriends()),
        ],
      );

      // No badge numbers should appear in the nav bar
      expect(navBarText('1'), findsNothing);
      expect(navBarText('2'), findsNothing);
      expect(navBarText('99+'), findsNothing);
    });
  });
}

class _UnreadWithCounts extends UnreadNotifier {
  @override
  UnreadState build() => testUnreadWithCounts;
}

class _EmptyFriends extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => const {};
}
