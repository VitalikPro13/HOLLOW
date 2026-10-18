import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/shell/key_missing_dialog.dart';

// The phone's secure hardware did not answer an unlock: the person is offered
// the same try again first, never sent straight to the recovery phrase, and a
// retry that fails another way hands its error back to the unlock flow.
void main() {
  Future<void> open(WidgetTester tester, Future<void> Function() retry) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HollowThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showHollowDialog<Object>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => HardwareKeyBusyDialog(retry: retry),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Try again comes first and says when it still did not answer', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, () async {
      calls++;
      if (calls == 1) {
        throw 'hardware_key_busy: this device\'s secure hardware did not answer this time';
      }
    });
    expect(find.text(kHardwareKeyBusyTitle), findsOneWidget);
    expect(
      find.textContaining('chip'),
      findsNothing,
      reason: 'a busy keystore is not a lost key',
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text(kHardwareKeyStillBusy), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(
      find.text(kHardwareKeyBusyTitle),
      findsNothing,
      reason: 'opened, so it closes',
    );
  });

  testWidgets('another failure goes back to the unlock flow', (tester) async {
    await open(tester, () async => throw 'hardware_key_missing: gone');
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text(kHardwareKeyBusyTitle), findsNothing);
  });

  testWidgets('the recovery phrase stays the way out', (tester) async {
    await open(tester, () async {});
    expect(find.text('Use recovery phrase'), findsOneWidget);
    await tester.tap(find.text('Use recovery phrase'));
    await tester.pumpAndSettle();
    expect(find.text(kHardwareKeyBusyTitle), findsNothing);
  });
}
