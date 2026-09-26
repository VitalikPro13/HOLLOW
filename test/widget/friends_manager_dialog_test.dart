import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/temporary_nickname_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_tab_bar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/friends_manager_dialog.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

class _Api implements RustLibApi {
  int nicknameSends = 0;

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      null;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<void> crateApiNetworkSendFriendRequestByNickname(
      {required String nickname}) async {
    nicknameSends++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A claim the relay has not answered yet.
class _Nickname extends TemporaryNicknameNotifier {
  @override
  Future<void> claim(String nickname) async {
    state = TemporaryNicknameState(
        status: NicknameStatus.claiming, nickname: nickname);
  }
}

class _Friends extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => testFriends;

  void addOutgoing(String peerId) {
    state = {
      ...state,
      peerId: FriendInfo(
        peerId: peerId,
        status: 'pending',
        direction: 'outgoing',
        requestedAt: 99,
        updatedAt: 99,
      ),
    };
  }
}

class _Favourites extends FavouriteFriendsNotifier {
  _Favourites(this.ids);
  final List<String> ids;
  @override
  List<String> build() => ids;
  @override
  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = [...state];
    list.insert(newIndex, list.removeAt(oldIndex));
    state = list;
  }
}

final _api = _Api();

Future<ProviderContainer> _open(WidgetTester tester, FriendsManagerTab tab,
    {List<String> favourites = const []}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: hollowTestOverrides(extra: [
      temporaryNicknameProvider.overrideWith(_Nickname.new),
      friendsProvider.overrideWith(_Friends.new),
      favouriteFriendsProvider.overrideWith(() => _Favourites(favourites)),
    ]),
  );
  addTearDown(container.dispose);
  late BuildContext host;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Builder(builder: (context) {
        host = context;
        return const SizedBox.expand();
      })),
    ),
  ));
  showFriendsManager(host, tab: tab);
  await tester.pumpAndSettle();
  return container;
}

TextField _field(WidgetTester tester, String hint) => tester.widget<TextField>(
    find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == hint));

void main() {
  setUpAll(() => RustLib.initMock(api: _api));

  testWidgets('a refused nickname claim keeps what was typed', (tester) async {
    final c = await _open(tester, FriendsManagerTab.add);
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField && w.decoration?.hintText == 'Choose a nickname'),
        'mira_k');
    await tester.tap(find.text('Claim'));
    await tester.pump();
    expect(_field(tester, 'Choose a nickname').controller!.text, 'mira_k',
        reason: 'the name stays while the relay decides');

    c.read(temporaryNicknameProvider.notifier).onClaimFailed('taken');
    await tester.pump();
    expect(_field(tester, 'Choose a nickname').controller!.text, 'mira_k');
    expect(find.text('That nickname is already taken'), findsOneWidget);
  });

  testWidgets('a nickname send stays busy until the request exists',
      (tester) async {
    final c = await _open(tester, FriendsManagerTab.add);
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField &&
            w.decoration?.hintText == 'Paste an ID, or type a nickname'),
        'juno');
    await tester.tap(find.text('Send request'));
    await tester.pump();
    await tester.pump();

    expect(_api.nicknameSends, 1);
    expect(find.textContaining('Looking up'), findsNothing,
        reason: 'no success message before the outcome is known');
    expect(
        tester
            .widgetList<HollowButton>(find.byType(HollowButton))
            .any((b) => b.loading),
        isTrue,
        reason: 'Send request is busy through the lookup');

    (c.read(friendsProvider.notifier) as _Friends).addOutgoing('juno_master');
    await tester.pump();
    await tester.pump();
    expect(find.text('Friend request sent'), findsOneWidget);
    expect(
        _field(tester, 'Paste an ID, or type a nickname').controller!.text, '');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a nickname nobody holds says so at the field, input kept',
      (tester) async {
    await _open(tester, FriendsManagerTab.add);
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField &&
            w.decoration?.hintText == 'Paste an ID, or type a nickname'),
        'nobody');
    await tester.tap(find.text('Send request'));
    await tester.pump();
    await tester.pump();

    expect(handleNicknameLookupFailed('nobody', 'not_found'), isTrue);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('No one has the nickname nobody'),
        findsOneWidget);
    expect(
        _field(tester, 'Paste an ID, or type a nickname').controller!.text,
        'nobody');
    expect(handleNicknameLookupFailed('nobody', 'not_found'), isFalse,
        reason: 'nothing waits on it any more, so the event toasts instead');
  });

  testWidgets('an error under the field leaves Send request beside the field',
      (tester) async {
    await _open(tester, FriendsManagerTab.add);
    final field = find.byWidgetPredicate((w) =>
        w is TextField &&
        w.decoration?.hintText == 'Paste an ID, or type a nickname');
    final send =
        find.ancestor(of: find.text('Send request'), matching: find.byType(HollowButton));
    final before = tester.getCenter(send).dy - tester.getCenter(field).dy;

    await tester.enterText(field, 'nobody');
    await tester.tap(find.text('Send request'));
    await tester.pump();
    await tester.pump();
    handleNicknameLookupFailed('nobody', 'not_found');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('No one has the nickname nobody'),
        findsOneWidget);

    final after = tester.getCenter(send).dy - tester.getCenter(field).dy;
    expect(after.abs(), lessThan(3),
        reason: 'the button stays centred on the field, not on field + error');
    expect(after, closeTo(before, 0.5));
  });

  testWidgets('Decline announces the word it shows', (tester) async {
    await _open(tester, FriendsManagerTab.requests);
    expect(find.bySemanticsLabel('Decline friend request'), findsOneWidget);
    expect(find.bySemanticsLabel('Reject friend request'), findsNothing);
  });

  testWidgets('the tabs are the header: no second "Friends"', (tester) async {
    await _open(tester, FriendsManagerTab.friends);
    expect(find.text('Friends'), findsOneWidget);
    expect(find.widgetWithText(HollowTabBar<FriendsManagerTab>, 'Friends'),
        findsOneWidget);
  });

  testWidgets('a favourite moves down from More, for the keyboard',
      (tester) async {
    final c = await _open(tester, FriendsManagerTab.friends,
        favourites: [kFriendPeerId1, kFriendPeerId2]);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^More for ')).first);
    await tester.pumpAndSettle();
    expect(find.text('Move up'), findsNothing);
    await tester.tap(find.text('Move down'));
    await tester.pumpAndSettle();
    expect(c.read(favouriteFriendsProvider), [kFriendPeerId2, kFriendPeerId1]);
  });

  testWidgets("a favourite's actions sit in the same columns as the others",
      (tester) async {
    await _open(tester, FriendsManagerTab.friends,
        favourites: [kFriendPeerId1]);
    final more = find.ancestor(
        of: find.bySemanticsLabel(RegExp(r'^More for ')),
        matching: find.byType(HollowIconButton));
    expect(more, findsNWidgets(2));
    expect(tester.getTopRight(more.at(0)).dx,
        tester.getTopRight(more.at(1)).dx);
  });

  testWidgets("rows sit on the search field's edge", (tester) async {
    await _open(tester, FriendsManagerTab.friends,
        favourites: [kFriendPeerId1]);
    final edge = tester.getTopLeft(find.byType(HollowTextField)).dx;
    final avatars = find.byType(PresenceAvatar);
    expect(avatars, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      expect(tester.getTopLeft(avatars.at(i)).dx, edge);
    }
    expect(tester.getTopLeft(find.text('Favourites')).dx, edge);
  });

  testWidgets("request rows sit on their section title's edge", (tester) async {
    await _open(tester, FriendsManagerTab.requests);
    final edge = tester.getTopLeft(find.text('Received')).dx;
    expect(tester.getTopLeft(find.byType(HollowAvatar).first).dx, edge);
  });
}
