import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';

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

void main() {
  group('Mobile nav bar badges', () {
    testWidgets('shows unread count badge on Chats tab', (tester) async {
      await pumpHollowMobile(
        tester,
        extraOverrides: [
          unreadProvider.overrideWith(() => _UnreadWithCounts()),
        ],
      );

      // Total unread = 3 (channel) + 2 (DM) = 5
      expect(navBarText('5'), findsOneWidget);
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
