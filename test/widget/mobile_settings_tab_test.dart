/// The phone's Settings tab lists the desktop rail's pages in its groups and
/// pushes the same shared page widgets; Profile carries its Save in the bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/settings/pages/profile_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/test_app.dart';

Future<void> _openSettingsTab(WidgetTester tester) async {
  // Tall enough that the lazy list builds every page row.
  await pumpHollowMobile(tester, viewportSize: const Size(400, 1400));
  await tester.tap(find.descendant(
    of: find.byType(MobileNavBar),
    matching: find.text('Settings'),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the rail groups and pages, without desktop-only ones',
      (tester) async {
    await _openSettingsTab(tester);

    for (final caption in ['Account', 'App', 'Connection and data']) {
      expect(find.text(caption), findsOneWidget, reason: caption);
    }
    for (final page in [
      'Security',
      'Devices',
      'Appearance',
      'Accessibility',
      'Notifications',
      'Audio & Video',
      'Network',
      'Files & Storage',
      'About',
      'Help',
    ]) {
      expect(find.text(page), findsOneWidget, reason: page);
    }
    // Shortcuts need a keyboard; the three lists live inside Security now.
    for (final gone in [
      'Shortcuts',
      'Backup',
      'Blocked Users',
      'Verified Contacts',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
  });

  testWidgets('Profile opens at touch density with Save in its bar',
      (tester) async {
    await _openSettingsTab(tester);

    // The identity row may read "Profile" too; the page row is below it.
    await tester.tap(find.text('Profile').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(ProfileSettingsPage), findsOneWidget);
    final density = tester.widget<SettingsDensity>(find.ancestor(
      of: find.byType(ProfileSettingsPage),
      matching: find.byType(SettingsDensity),
    ).first);
    expect(density.touch, isTrue);

    final save = find.widgetWithText(HollowButton, 'Save');
    expect(save, findsOneWidget);
    // Nothing is edited yet, so there is nothing to save or reset.
    expect(tester.widget<HollowButton>(save).onPressed, isNull);
    expect(find.widgetWithText(HollowButton, 'Reset'), findsNothing);

    // An edit arms Save and brings Reset beside it; Reset drops the edit.
    await tester.enterText(find.byType(TextField).first, 'New name');
    await tester.pump();
    expect(tester.widget<HollowButton>(save).onPressed, isNotNull);
    final reset = find.widgetWithText(HollowButton, 'Reset');
    expect(reset, findsOneWidget);
    await tester.tap(reset);
    await tester.pump();
    expect(tester.widget<HollowButton>(save).onPressed, isNull);
  });

  testWidgets('every page opens at phone width without overflow',
      (tester) async {
    await _openSettingsTab(tester);
    tester.view.physicalSize = const Size(360, 1400);
    await tester.pump();
    for (final page in [
      'Security',
      'Devices',
      'Appearance',
      'Accessibility',
      'Notifications',
      'Audio & Video',
      'Network',
      'Files & Storage',
      // About is left out: on this desktop host its updater arms a recheck
      // timer that outlives the test.
    ]) {
      await tester.tap(find.text(page));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull, reason: page);
      expect(find.byType(SettingsDensity), findsWidgets, reason: page);
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
  });

  for (final scale in const [1.0, 2.0]) {
    testWidgets('Profile fits a 360 px phone at ${scale}x text', (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(360, 740),
          textScaler: TextScaler.linear(scale));
      await tester.tap(find.descendant(
        of: find.byType(MobileNavBar),
        matching: find.text('Settings'),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Profile').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}
