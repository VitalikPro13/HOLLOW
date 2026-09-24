// Settings > Security, the "Lock after" row.
//
// What is pinned here is what a wrong build would silently get wrong: the row
// refusing to offer a lock there is no password to lift, and a chip actually
// writing the span it names.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/app_lock_card.dart';

import '../helpers/test_app.dart';

class _FakeShortcuts extends AppShortcutsNotifier {
  @override
  Future<Map<AppShortcut, HotkeyBinding>> build() async => kAppShortcutDefaults;
}

/// The real notifier without its storage write, which has no FFI in a test.
class _FakeLockAfter extends LockAfterMinutesNotifier {
  @override
  Future<void> setMinutes(int minutes) async => state = minutes;
}

void main() {
  Future<ProviderContainer> pumpCard(
    WidgetTester tester, {
    required bool hasPassword,
  }) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(extra: [
          appShortcutsProvider.overrideWith(_FakeShortcuts.new),
          lockAfterMinutesProvider.overrideWith(_FakeLockAfter.new),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AppLockCard(hasPassword: hasPassword),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(AppLockCard)));
  }

  group('lock after row', () {
    testWidgets('with no password it offers no lock at all', (tester) async {
      await pumpCard(tester, hasPassword: false);

      expect(find.text('Lock after'), findsNothing);
      expect(find.text('Lock now'), findsNothing);
      expect(find.text('Off'), findsNothing);
    });

    testWidgets('with a password it offers every span, Lock now and the '
        'shortcut', (tester) async {
      final container = await pumpCard(tester, hasPassword: true);

      for (final minutes in kLockAfterChoices) {
        expect(find.text(AppLockCard.labelFor(minutes)), findsOneWidget,
            reason: 'span $minutes');
      }
      expect(find.text('Lock now'), findsOneWidget);
      expect(find.text('Ctrl + Shift + L locks it now'), findsOneWidget);
      // Off by default: nobody gets locked out by an upgrade.
      expect(container.read(lockAfterMinutesProvider), 0);
    });

    testWidgets('a chip writes the span it names', (tester) async {
      final container = await pumpCard(tester, hasPassword: true);

      await tester.tap(find.text('15 min'));
      await tester.pumpAndSettle();
      expect(container.read(lockAfterMinutesProvider), 15);

      await tester.tap(find.text('1 hour'));
      await tester.pumpAndSettle();
      expect(container.read(lockAfterMinutesProvider), 60);

      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(container.read(lockAfterMinutesProvider), 0);
    });
  });
}
