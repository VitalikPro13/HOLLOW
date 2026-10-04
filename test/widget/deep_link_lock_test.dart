// C-LOCAL-03: nothing routes above the app lock. A hollow:// link that lands
// while it is up waits, and opens its confirm only once the lock lifts.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/services/deep_link_service.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

import '../helpers/test_app.dart';

const _invite = 'hollow://join?server=8f3d5c37a26835ddf04b07f2c91da556';

Future<ProviderContainer> _app(WidgetTester tester) async {
  final container = ProviderContainer(overrides: hollowTestOverrides());
  addTearDown(() {
    DeepLinkService.instance.dispose();
    container.dispose();
    HollowToast.lockedOut = false;
    DeepLinkService.instance.bringToForeground = null;
  });
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: hollowNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: SizedBox.expand()),
    ),
  ));
  DeepLinkService.instance.attachContainer(container);
  DeepLinkService.instance.notifyShellReady();
  return container;
}

Future<void> _closeConfirm(WidgetTester tester) async {
  await tester.tap(find.text('Cancel'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a link that lands while locked opens only after the unlock',
      (tester) async {
    final container = await _app(tester);
    final lock = container.read(appLockedProvider.notifier);

    lock.setLocked(true);
    DeepLinkService.instance.handleUrl(_invite);
    await tester.pumpAndSettle();
    expect(find.text('Join Server?'), findsNothing,
        reason: 'no dialog may sit above the lock');

    lock.setLocked(false);
    await tester.pumpAndSettle();
    expect(find.text('Join Server?'), findsOneWidget);
    await _closeConfirm(tester);
  });

  testWidgets('a lock that rises while the window comes forward holds it too',
      (tester) async {
    final container = await _app(tester);
    final lock = container.read(appLockedProvider.notifier);
    DeepLinkService.instance.bringToForeground = () async {
      lock.setLocked(true);
    };

    DeepLinkService.instance.handleUrl(_invite);
    await tester.pumpAndSettle();
    expect(find.text('Join Server?'), findsNothing);

    DeepLinkService.instance.bringToForeground = null;
    lock.setLocked(false);
    await tester.pumpAndSettle();
    expect(find.text('Join Server?'), findsOneWidget);
    await _closeConfirm(tester);
  });

  testWidgets('unlocked, a link opens its confirm at once', (tester) async {
    await _app(tester);
    DeepLinkService.instance.handleUrl(_invite);
    await tester.pumpAndSettle();
    expect(find.text('Join Server?'), findsOneWidget);
    await _closeConfirm(tester);
  });
}
