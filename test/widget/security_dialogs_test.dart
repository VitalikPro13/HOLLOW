// The app password, device and backup prompts of Settings.
//
// What is pinned here is where a failure is said: on the field that caused
// it, with the dialog still open and nothing typed lost, and that Enter on
// the last field submits.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/settings/device_management_shared.dart';
import 'package:hollow/src/ui/settings/security_section.dart';

import '../helpers/test_app.dart';

void main() {
  late BuildContext hostContext;
  late WidgetRef hostRef;

  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              hostContext = context;
              hostRef = ref;
              return const SizedBox.expand();
            }),
          ),
        ),
      ),
    );
  }

  group('askSecretDialog', () {
    testWidgets('a mismatch sits on the repeat field and Rust is not asked',
        (tester) async {
      await pumpHost(tester);
      var calls = 0;
      askSecretDialog(hostContext,
          title: 'Set app password',
          ask: SecretAsk.create,
          confirmLabel: 'Set password',
          onSubmit: (_, _) async => calls++);
      await tester.pumpAndSettle();

      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Repeat the password'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'hunter22');
      await tester.enterText(fields.at(1), 'hunter23');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.text("The passwords don't match."), findsOneWidget);
      expect(find.text('Set app password'), findsOneWidget);
    });

    testWidgets('Enter on the last field submits', (tester) async {
      await pumpHost(tester);
      String? got;
      String? result;
      askSecretDialog(hostContext,
              title: 'Set app password',
              ask: SecretAsk.create,
              confirmLabel: 'Set password',
              onSubmit: (_, next) async => got = next)
          .then((v) => result = v);
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'hunter22');
      await tester.enterText(fields.at(1), 'hunter22');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(got, 'hunter22');
      expect(result, 'hunter22');
      expect(find.text('Set app password'), findsNothing);
    });

    testWidgets('a wrong current password lands on its field, dialog open',
        (tester) async {
      await pumpHost(tester);
      askSecretDialog(hostContext,
          title: 'Change password',
          ask: SecretAsk.change,
          confirmLabel: 'Change password',
          onSubmit: (_, _) async =>
              throw 'Wrong password or corrupted identity file');
      await tester.pumpAndSettle();

      expect(find.text('Current password'), findsOneWidget);
      expect(find.text('New password'), findsOneWidget);
      expect(find.text('Repeat the new password'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'old');
      await tester.enterText(fields.at(1), 'newer1');
      await tester.enterText(fields.at(2), 'newer1');
      await tester.pump();
      await tester.tap(find.widgetWithText(HollowButton, 'Change password'));
      await tester.pumpAndSettle();

      expect(find.text("That password isn't right."), findsOneWidget);
      expect(tester.widget<TextField>(fields.at(1)).controller!.text, 'newer1');
    });

    testWidgets('a short PIN is refused on its field', (tester) async {
      await pumpHost(tester);
      var calls = 0;
      askSecretDialog(hostContext,
          title: 'Set a PIN',
          ask: SecretAsk.create,
          isPin: true,
          confirmLabel: 'Turn on',
          onSubmit: (_, _) async => calls++);
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '12');
      await tester.enterText(fields.at(1), '12');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.text('A PIN needs at least 4 digits.'), findsOneWidget);
    });
  });

  testWidgets('syncing from an offline device is refused before any question',
      (tester) async {
    await pumpHost(tester);
    syncFromDeviceFlow(
      hostContext,
      hostRef,
      const MyDevice(
          peerId: 'dev', isThisDevice: false, online: false, label: 'Laptop'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync now'), findsNothing);
    expect(find.text('"Laptop" is offline. Bring it online first.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
