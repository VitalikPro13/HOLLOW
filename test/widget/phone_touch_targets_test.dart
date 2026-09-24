import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Phone rows: 44 px buttons, and the friend sheet offers a call.
void main() {
  Future<void> pump(WidgetTester tester, Widget child,
      {List<Override> extra = const []}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: extra),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(body: child),
      ),
    ));
    await tester.pump();
  }

  testWidgets('a touch button is 44 tall; desktop keeps its height',
      (tester) async {
    await pump(
      tester,
      Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          HollowButton.ghost(
              key: const Key('desk'), onPressed: () {}, child: const Text('A')),
          HollowButton.outline(
              key: const Key('touch'),
              touch: true,
              onPressed: () {},
              child: const Text('B')),
          HollowButton.ghost(
              key: const Key('compact'),
              compact: true,
              touch: true,
              onPressed: () {},
              child: const Text('C')),
        ]),
      ),
    );
    Size sizeOf(String key) => tester.getSize(find.byKey(Key(key)));
    expect(sizeOf('desk').height, lessThan(HollowButton.touchHeight));
    expect(sizeOf('touch').height, HollowButton.touchHeight);
    expect(sizeOf('compact').height, HollowButton.touchHeight);
  });

  testWidgets('phone request rows use touch-height buttons', (tester) async {
    await pump(tester, const MobileFriendsTab());
    final accept = find.widgetWithText(HollowButton, 'Accept');
    expect(accept, findsOneWidget);
    expect(tester.getSize(accept).height, HollowButton.touchHeight);
    expect(tester.getSize(find.widgetWithText(HollowButton, 'Decline')).height,
        HollowButton.touchHeight);
  });

  testWidgets('the friend sheet offers a voice call to an online friend',
      (tester) async {
    await pump(tester, const MobileFriendsTab(), extra: [
      onlineIdentitiesProvider.overrideWith(() => _Online({kFriendPeerId1})),
    ]);
    // Friend 1's row is the only one reading Online.
    await tester.longPress(find.text('Online'));
    await tester.pumpAndSettle();
    expect(find.text('Voice call'), findsOneWidget);
  });

  testWidgets('no call is offered to an offline friend', (tester) async {
    await pump(tester, const MobileFriendsTab(), extra: [
      onlineIdentitiesProvider.overrideWith(() => _Online({kFriendPeerId1})),
    ]);
    await tester.longPress(find.text('Offline'));
    await tester.pumpAndSettle();
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Voice call'), findsNothing);
  });
}

class _Online extends OnlineIdentitiesNotifier {
  _Online(this.ids);
  final Set<String> ids;

  @override
  Set<String> build() => ids;
}
