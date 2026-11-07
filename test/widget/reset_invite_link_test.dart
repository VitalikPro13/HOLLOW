import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/server_settings/pages/access_page.dart';

// Reset invite link (0.14): only the owner sees it on the Access page, its confirm says
// what happens, and a joiner holding a reset link is told why it was refused.

Future<void> _pumpAccess(WidgetTester tester, String role) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      myRoleProvider.overrideWith((ref, _) async => role),
      serverSettingProvider.overrideWith((ref, _) async => ''),
      serverCapacityProvider.overrideWith((ref, _) => null),
    ],
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: AccessPage(serverId: 'srv1')),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  test('a joiner holding a reset link is told so', () {
    expect(pendingJoinReasonText('invite_reset'),
        'This invite link was reset. Ask for a new one.');
  });

  testWidgets('the owner can reset the invite link, after a confirm',
      (tester) async {
    await _pumpAccess(tester, 'owner');
    expect(find.text('Reset invite link'), findsOneWidget);
    await tester.tap(find.text('Reset link'));
    await tester.pumpAndSettle();
    expect(find.text('Reset the invite link?'), findsOneWidget);
    expect(find.textContaining('Anyone still waiting to join through an old link'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Reset the invite link?'), findsNothing);
  });

  testWidgets('an admin does not see it', (tester) async {
    await _pumpAccess(tester, 'admin');
    expect(find.text('Access'), findsWidgets);
    expect(find.text('Reset invite link'), findsNothing);
  });
}
