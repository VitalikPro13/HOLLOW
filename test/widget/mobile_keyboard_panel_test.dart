import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/mobile_keyboard_panel.dart';

/// The strip under the phone composer: the keyboard's room while it is up,
/// the home indicator's otherwise, always in the composer's own colour.
void main() {
  const composerKey = Key('composer');

  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(child: SizedBox.expand()),
                TextField(key: composerKey),
                MobileKeyboardSpacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the home indicator strip is the composer colour',
      (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 34);
    await pumpHost(tester);
    final spacer = find.byType(MobileKeyboardSpacer);
    expect(tester.getSize(spacer).height, 34);
    expect(tester.getBottomLeft(spacer).dy, 800);
    final box = tester.widget<ColoredBox>(
        find.descendant(of: spacer, matching: find.byType(ColoredBox)));
    final hollow = HollowTheme.of(tester.element(spacer));
    expect(box.color, hollow.surface);
  });

  testWidgets('the keyboard takes the strip, the composer sits on it',
      (tester) async {
    // The platform reports the padding the keyboard leaves uncovered.
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await pumpHost(tester);
    expect(tester.getBottomLeft(find.byKey(composerKey)).dy, 500);
  });
}
