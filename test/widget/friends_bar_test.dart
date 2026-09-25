/// The Dock header's friend strip: unread never reflows a chip, a request is
/// the accent count, and the favourites filter never hides someone waiting on
/// you or empties the strip over stale ids.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

class _Favourites extends FavouriteFriendsNotifier {
  final List<String> ids;
  _Favourites(this.ids);
  @override
  List<String> build() => ids;
}

class _Unread extends UnreadNotifier {
  final Map<String, int> dm;
  _Unread(this.dm);
  @override
  UnreadState build() => UnreadState(dmUnreadCounts: dm);
}

storage_api.UserProfile _profile(String id, String name) =>
    storage_api.UserProfile(
      peerId: id,
      displayName: name,
      status: '',
      aboutMe: '',
      updatedAt: 0,
      twitchUsername: '',
      showcaseBoard: '',
      avatarFrame: '',
      avatarAnim: '',
      bannerAnim: '',
      supportCreds: '',
    );

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        kFriendPeerId1: _profile(kFriendPeerId1, 'alice'),
        kFriendPeerId2: _profile(kFriendPeerId2, 'Bob'),
      };
}

Future<ProviderContainer> _pumpBar(
  WidgetTester tester, {
  List<String> favourites = const [],
  Map<String, int> unread = const {},
}) async {
  tester.view.physicalSize = const Size(1280, 200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: hollowTestOverrides(extra: [
      favouriteFriendsProvider.overrideWith(() => _Favourites(favourites)),
      unreadProvider.overrideWith(() => _Unread(unread)),
      profileProvider.overrideWith(_Profiles.new),
    ]),
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: Align(alignment: Alignment.topCenter, child: FriendsBar()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

FontWeight? _weightOf(WidgetTester tester, String name) =>
    tester.widget<Text>(find.text(name)).style?.fontWeight;

void main() {
  testWidgets('an unread friend keeps the name weight, the count follows it',
      (tester) async {
    await _pumpBar(tester);
    final rest = _weightOf(tester, 'alice');
    expect(find.byType(HollowCountBadge).evaluate().where((e) {
      final w = e.widget as HollowCountBadge;
      return !w.mention && w.count == 4;
    }), isEmpty);

    await _pumpBar(tester, unread: {kFriendPeerId1: 4});
    expect(_weightOf(tester, 'alice'), rest,
        reason: 'a weight change reflows the row under the pointer');
    final badge = find.byWidgetPredicate(
        (w) => w is HollowCountBadge && w.count == 4 && !w.mention);
    expect(badge, findsOneWidget);
    expect(tester.getTopLeft(badge).dx,
        greaterThan(tester.getTopRight(find.text('alice')).dx),
        reason: 'the count sits after the name, off the avatar');
  });

  testWidgets('a friend request is the accent count, not a mention',
      (tester) async {
    await _pumpBar(tester);
    // testFriends carries one pending incoming request.
    final badge = tester.widget<HollowCountBadge>(find.byWidgetPredicate(
        (w) => w is HollowCountBadge && w.count == 1));
    expect(badge.mention, isFalse);
  });

  testWidgets('chips sort by name, case-insensitive', (tester) async {
    await _pumpBar(tester);
    expect(tester.getTopLeft(find.text('alice')).dx,
        lessThan(tester.getTopLeft(find.text('Bob')).dx));
  });

  testWidgets('with favourites set, a non-favourite with unread still shows',
      (tester) async {
    await _pumpBar(tester, favourites: [kFriendPeerId2]);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
    expect(find.text('+1 more'), findsOneWidget);

    await _pumpBar(tester,
        favourites: [kFriendPeerId2], unread: {kFriendPeerId1: 2});
    expect(find.text('alice'), findsOneWidget,
        reason: 'unread beats the filter');
    expect(find.text('+1 more'), findsNothing);
  });

  testWidgets('only stale favourites behave as no favourites', (tester) async {
    final c = await _pumpBar(tester, favourites: ['gone_peer']);
    expect(c.read(friendsBarProvider).leading, hasLength(2));
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('No friends yet'), findsNothing);
  });

  group('Friends Manager', () {
    Future<void> openManager(WidgetTester tester, {FriendsManagerTab? tab,
        List<String> favourites = const []}) async {
      await _pumpBar(tester, favourites: favourites);
      tester.view.physicalSize = const Size(1280, 800);
      showFriendsManager(
          tester.element(find.byType(FriendsBar)), tab: tab);
      await tester.pumpAndSettle();
    }

    testWidgets('opens on Friends with three sentence-case tabs',
        (tester) async {
      await openManager(tester);
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('Add friend'), findsOneWidget);
      expect(find.text('Incoming'), findsNothing);
      expect(find.text('Favourites'), findsNothing,
          reason: 'no favourites set, so no Favourites section');
      expect(find.text('All friends'), findsOneWidget);
      expect(find.text('Search friends'), findsOneWidget);
    });

    testWidgets('favourites sit above all friends, never twice',
        (tester) async {
      await openManager(tester, favourites: [kFriendPeerId2]);
      expect(find.text('Favourites'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Favourites')).dy,
          lessThan(tester.getTopLeft(find.text('All friends')).dy));
      final dialog = find.byType(ReorderableListView);
      expect(find.descendant(of: dialog, matching: find.text('Bob')),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('alice')),
          findsNothing);
    });

    testWidgets('a received request answers with Decline then Accept',
        (tester) async {
      await openManager(tester, tab: FriendsManagerTab.requests);
      expect(find.text('Received'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Accept friend request')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Decline friend request')),
          findsOneWidget);
      expect(tester.getTopLeft(find.text('Decline')).dx,
          lessThan(tester.getTopLeft(find.text('Accept')).dx),
          reason: 'the primary answer is last');
    });

    testWidgets('Add friend has one filled Send request', (tester) async {
      await openManager(tester, tab: FriendsManagerTab.add);
      expect(find.text('Paste an ID, or type a nickname'), findsOneWidget);
      expect(find.text('Send request'), findsOneWidget);
      expect(find.text('How others add you'), findsOneWidget);
      expect(find.text('Claim'), findsOneWidget);
    });
  });
}
