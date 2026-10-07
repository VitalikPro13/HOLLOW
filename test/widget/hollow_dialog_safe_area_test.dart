// A tall dialog on a phone keeps its margin clear of the status bar and the
// home indicator. It used to measure the margin from the screen's edge, so the
// title ran under the clock and the frame met the home indicator.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

Future<void> _openTallDialog(WidgetTester tester,
    {required FakeViewPadding padding, required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = padding;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showHollowDialog<void>(
              context: context,
              builder: (_) => HollowDialog(
                title: 'What is new',
                showClose: true,
                content: Column(
                  children: [
                    for (var i = 0; i < 80; i++) Text('Line $i'),
                  ],
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

/// The drawn frame: the one box with the floating shadow.
Rect _frame(WidgetTester tester) => tester.getRect(find.byWidgetPredicate((w) =>
    w is DecoratedBox &&
    w.decoration is BoxDecoration &&
    (w.decoration as BoxDecoration).boxShadow != null));

void main() {
  testWidgets('a phone dialog keeps its gap below the status bar and above '
      'the home indicator', (tester) async {
    await _openTallDialog(tester,
        size: const Size(375, 812),
        padding: const FakeViewPadding(top: 50, bottom: 34));
    final frame = _frame(tester);
    expect(frame.top, greaterThanOrEqualTo(50 + HollowSpacing.xl));
    expect(frame.bottom, lessThanOrEqualTo(812 - 34 - HollowSpacing.xl));
  });

  testWidgets('a desktop window keeps the plain margin', (tester) async {
    await _openTallDialog(tester,
        size: const Size(1200, 800), padding: FakeViewPadding.zero);
    final frame = _frame(tester);
    expect(frame.top, HollowSpacing.xl);
    expect(frame.bottom, 800 - HollowSpacing.xl);
  });
}
