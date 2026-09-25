// Settings > Security as one page.
//
// What is pinned here is what a wrong build would silently get wrong: the
// backup options living inside the export flow, the proof checker no longer
// hinting at the refused v1 format, and the people lists hiding behind their
// counts.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/settings/pages/security_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/test_app.dart';

const _peerA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peerB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _FakeBlocked extends BlockedUsersNotifier {
  @override
  Set<String> build() => {_peerA, _peerB};
}

class _FakeVerified extends VerifiedPeersNotifier {
  @override
  Set<String> build() => {_peerA};
}

void main() {
  Future<void> pumpPage(WidgetTester tester, {bool phone = false}) async {
    tester.view.physicalSize = Size(phone ? 360 : 900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(extra: [
          blockedUsersProvider.overrideWith(_FakeBlocked.new),
          verifiedPeersProvider.overrideWith(_FakeVerified.new),
          duressStatusProvider.overrideWith((ref) async =>
              const identity_api.DuressStatus(
                enabled: false,
                scope: 'device',
                notifyFriends: false,
                available: false,
              )),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SettingsDensity(
                  touch: phone,
                  child: const SecuritySettingsPage(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every section is on the page, danger zone last', (tester) async {
    await pumpPage(tester);

    for (final title in [
      'App lock',
      'Recovery',
      'Privacy',
      'People',
      'Danger zone',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Duress code'), findsOneWidget);
    expect(find.text('Needs a password first'), findsOneWidget);
    expect(find.text('Backup file'), findsOneWidget);
    expect(find.text('Always relay calls'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Danger zone')).dy,
      greaterThan(tester.getTopLeft(find.text('Advanced')).dy),
    );
  });

  testWidgets('the people lists show counts and open on demand',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('1 person, checked by safety number'), findsOneWidget);
    expect(find.text("2 people can't message, call or friend you"),
        findsOneWidget);
    expect(find.text('Unblock'), findsNothing);

    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();
    expect(find.text('Unblock'), findsNWidgets(2));
  });

  testWidgets('the backup options live inside the export flow',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('Include downloaded files'), findsNothing);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(find.text('Include downloaded files'), findsOneWidget);
    expect(find.text('Include files you keep for your servers'), findsOneWidget);
  });

  testWidgets('Export waits for both passphrase fields', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    final export = find.widgetWithText(HollowButton, 'Export').last;
    expect(tester.widget<HollowButton>(export).onPressed, isNull);
    await tester.enterText(find.byType(TextField).at(0), 'correct horse');
    await tester.pump();
    expect(tester.widget<HollowButton>(export).onPressed, isNull);
    await tester.enterText(find.byType(TextField).at(1), 'wrong horse');
    await tester.pump();
    await tester.tap(export);
    await tester.pumpAndSettle();
    expect(find.text("The passphrases don't match."), findsOneWidget);
    expect(find.text('Export a backup'), findsOneWidget);
  });

  testWidgets('the proof checker opens as a dialog without a v1 hint',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Check a message proof'), findsNWidgets(2));
    expect(find.text('Paste a proof here'), findsOneWidget);
    expect(find.textContaining('"version":1'), findsNothing);
    // Nothing pasted is nothing to verify, not a toast after the tap.
    final verify = find.widgetWithText(HollowButton, 'Verify');
    expect(tester.widget<HollowButton>(verify).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, '{}');
    await tester.pump();
    expect(tester.widget<HollowButton>(verify).onPressed, isNotNull);
  });

  testWidgets('fits a phone at touch density', (tester) async {
    await pumpPage(tester, phone: true);
    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
