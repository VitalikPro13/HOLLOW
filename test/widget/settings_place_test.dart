/// Settings as a place: the rail and page centre as a pair on a wide window
/// and hug the left edge on a narrow one, search finds single settings, and
/// Escape leaves the search before it leaves Settings.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/settings_place.dart';

import '../helpers/test_app.dart';

Future<ProviderContainer> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(overrides: hollowTestOverrides());
  addTearDown(container.dispose);
  openSettings(container.read, category: SettingsCategory.shortcuts);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: SettingsPlace()),
      ),
    ),
  );
  await tester.pump();
  return container;
}

double _railLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byType(SettingsRailItem).first).dx;

void main() {
  testWidgets('a narrow window keeps the rail on the left edge', (tester) async {
    await _pump(tester, 1000);
    expect(_railLeft(tester), lessThan(kSettingsRailWidth / 4));
  });

  testWidgets('a wide window centres the rail and page as a pair',
      (tester) async {
    await _pump(tester, 1920);
    const pair = 1040.0;
    final expected = (1920 - pair) / 2;
    expect(_railLeft(tester), greaterThan(expected));
    expect(_railLeft(tester), lessThan(expected + kSettingsRailWidth / 4));
  });

  testWidgets('search lists single settings with their page', (tester) async {
    await _pump(tester, 1280);
    await tester.enterText(find.byType(TextField).first, 'noise');
    await tester.pump();
    expect(find.text('Noise suppression'), findsWidgets);
    expect(find.text('Audio & Video'), findsWidgets);
  });

  testWidgets('Escape clears a search, then closes Settings', (tester) async {
    final c = await _pump(tester, 1280);
    await tester.enterText(find.byType(TextField).first, 'relay');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(settingsTabOpenProvider), isTrue);
    expect(find.text('Results'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.read(settingsTabOpenProvider), isFalse);
    expect(c.read(openShellTabProvider), isNull);
  });
}
