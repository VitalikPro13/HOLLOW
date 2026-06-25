import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';

import '../helpers/test_app.dart';

/// a11y Phase 3 (Larger Text) — RenderFlex-overflow guard.
///
/// The mobile text-scale cap was raised from 1.3× to 2.0× (`app.dart`) so the
/// app honors the full OS text-size range on iOS/Android. To back that claim we
/// harden the chrome bars (fixed-height → min-height) and tight rows (names →
/// `Flexible` + ellipsis). This test pumps the real `MobileShell` at 1.0×, 1.5×
/// and 2.0× and asserts NOTHING overflows: in test mode a RenderFlex overflow
/// raises a `FlutterError` that the binding records, so `tester.takeException()`
/// returning null means every laid-out row/column fit at that scale.
///
/// It exercises the surfaces hardened in Phase 3 stage 1: the chats tab (friend
/// rows, DM/server rows), the bottom nav bar (icon + label tabs), and — by
/// cycling tabs — the friends/archive/settings surfaces. It is a headless
/// tripwire; Vitalik's on-device text-scale sweep is still the real sign-off.
///
/// Tapping a nav tab by its (possibly duplicated) label, scoped to the nav bar.
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
  group('Larger Text — no RenderFlex overflow', () {
    // 1.0× is the baseline (should already be clean); 1.5× and 2.0× are the
    // scales the raised cap newly allows and the layouts were hardened for.
    for (final scale in const [1.0, 1.5, 2.0]) {
      testWidgets('MobileShell chats tab fits at ${scale}x text scale',
          (tester) async {
        await pumpHollowMobile(
          tester,
          textScaler: TextScaler.linear(scale),
        );

        // Sanity: the shell + chats tab + nav bar actually rendered (so a null
        // exception below means "fit", not "rendered nothing").
        expect(find.byType(MobileShell), findsOneWidget);
        expect(find.byType(MobileChatsTab), findsOneWidget);
        expect(find.byType(MobileNavBar), findsOneWidget);

        expect(
          tester.takeException(),
          isNull,
          reason: 'Chats tab + nav bar overflowed at ${scale}x text scale',
        );
      });

      testWidgets('MobileShell all tabs fit at ${scale}x text scale',
          (tester) async {
        await pumpHollowMobile(
          tester,
          textScaler: TextScaler.linear(scale),
        );

        for (final tab in const ['Friends', 'Archive', 'Settings', 'Chats']) {
          await _tapNavTab(tester, tab);
          expect(
            tester.takeException(),
            isNull,
            reason: '$tab tab overflowed at ${scale}x text scale',
          );
        }
      });
    }
  });
}
