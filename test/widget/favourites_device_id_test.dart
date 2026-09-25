/// A friend favourited under a DEVICE id: the phone sheet must offer Remove
/// (not a second Add that stores the master too), and the desktop Friends
/// list, whose favourites are a ReorderableListView keyed by master, must
/// never build two rows for one friend.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/friends_manager_dialog.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

const _device = 'test_friend_device_111aaa';

class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() =>
      const DeviceLinkState(links: {_device: kFriendPeerId1});
}

class _Online extends OnlineIdentitiesNotifier {
  @override
  Set<String> build() => {kFriendPeerId1};
}

class _Stored extends FavouriteFriendsNotifier {
  _Stored(this.raw);
  String raw;
  @override
  Future<String?> readStored() async => raw;
  @override
  Future<void> writeStored(String value) async => raw = value;
}

void main() {
  Future<ProviderContainer> pump(
      WidgetTester tester, List<String> stored, Widget home,
      {Size size = const Size(400, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        deviceLinkProvider.overrideWith(_Links.new),
        onlineIdentitiesProvider.overrideWith(_Online.new),
        favouriteFriendsProvider
            .overrideWith(() => _Stored(json.encode(stored))),
      ]),
    );
    addTearDown(container.dispose);
    await container.read(favouriteFriendsProvider.notifier).load();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(body: home),
      ),
    ));
    await tester.pump();
    return container;
  }

  testWidgets('the phone sheet offers Remove for a device-id favourite',
      (tester) async {
    final c = await pump(tester, [_device], const MobileFriendsTab());
    await tester.longPress(find.text('Online'));
    await tester.pumpAndSettle();
    expect(find.text('Remove favourite'), findsOneWidget);
    expect(find.text('Add to favourites'), findsNothing);

    await tester.tap(find.text('Remove favourite'));
    await tester.pumpAndSettle();
    expect(c.read(favouriteFriendsProvider), isEmpty);
  });

  testWidgets('a device and its master stored together build one row',
      (tester) async {
    await pump(
      tester,
      [_device, kFriendPeerId1, kFriendPeerId2],
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showFriendsManager(context),
            child: const Text('open'),
          ),
        ),
      ),
      size: const Size(1280, 800),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey(kFriendPeerId1)), findsOneWidget);
    expect(find.byKey(const ValueKey(kFriendPeerId2)), findsOneWidget);
  });
}
