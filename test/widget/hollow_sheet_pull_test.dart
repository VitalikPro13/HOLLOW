// A sheet closes the way a phone's own sheets do: pulled down from anywhere,
// including from the top of content that scrolls. Before this, a pull on the
// profile sheet's content only overscrolled it and the sheet stayed put.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';

Future<void> _openSheet(WidgetTester tester, {int rows = 60}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showHollowSheet<void>(
              context: context,
              scrollControlled: true,
              maxHeightFactor: kSheetTallHeightFactor,
              builder: (_) => ListView(
                children: [
                  for (var i = 0; i < rows; i++)
                    SizedBox(height: 48, child: Text('Row $i')),
                ],
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
  expect(find.text('Row 0'), findsOneWidget);
}

void main() {
  testWidgets('a pull from the top of scrolling content closes the sheet',
      (tester) async {
    await _openSheet(tester);
    await tester.drag(find.text('Row 2'), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('Row 0'), findsNothing);
  });

  testWidgets('content scrolled down scrolls back first, the sheet stays',
      (tester) async {
    await _openSheet(tester);
    await tester.drag(find.text('Row 5'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Row 0'), findsNothing, reason: 'scrolled away');

    await tester.drag(find.text('Row 10'), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(find.text('Row 10'), findsOneWidget,
        reason: 'the pull went to the content, which was not at its top');
    final sheetTop = tester.getTopLeft(find.byType(ListView)).dy;
    expect(sheetTop, lessThan(800 * (1 - kSheetTallHeightFactor) + 40),
        reason: 'the sheet is still at rest');
  });

  testWidgets('a short pull settles back', (tester) async {
    await _openSheet(tester);
    final restTop = tester.getTopLeft(find.byType(ListView)).dy;
    await tester.timedDrag(
      find.text('Row 2'),
      const Offset(0, 60),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(find.text('Row 0'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(ListView)).dy, closeTo(restTop, 0.5));
  });

  testWidgets('a sheet whose content fits closes on a pull too',
      (tester) async {
    await _openSheet(tester, rows: 3);
    await tester.drag(find.text('Row 1'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Row 0'), findsNothing);
  });

  testWidgets('a tall sheet leaves a strip above it', (tester) async {
    await _openSheet(tester);
    final sheetTop = tester.getTopLeft(find.byType(ListView)).dy;
    expect(sheetTop, greaterThanOrEqualTo(800 * (1 - kSheetTallHeightFactor)));
  });
}
