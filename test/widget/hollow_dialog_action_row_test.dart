import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

Widget _dialog({required List<Widget> leading, required List<Widget> actions}) =>
    MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: HollowDialog(
          title: 'Write down your recovery phrase',
          content: const SizedBox(height: 40),
          leadingActions: leading,
          actions: actions,
        ),
      ),
    );

Future<void> _atWidth(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Rect _rect(WidgetTester tester, String label) =>
    tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(HollowButton)));

/// The phrase dialog on a phone: Copy at the leading edge, Later and the primary
/// at the trailing one (labels shortened for the test font's wide glyphs). They
/// do not fit on one line, and a wrap used to strand
/// one of them on its own; they stack full width with the primary last.
void main() {
  List<Widget> leading() => [
        HollowButton.ghost(onPressed: () {}, child: const Text('Copy')),
      ];
  List<Widget> trailing() => [
        HollowButton.ghost(onPressed: () {}, child: const Text('Later')),
        HollowButton.filled(onPressed: () {}, child: const Text('Written down')),
      ];

  testWidgets('a phone that cannot fit the row stacks every action full width',
      (tester) async {
    await _atWidth(tester, 360);
    await tester.pumpWidget(_dialog(leading: leading(), actions: trailing()));
    await tester.pumpAndSettle();

    final copy = _rect(tester, 'Copy');
    final later = _rect(tester, 'Later');
    final primary = _rect(tester, 'Written down');
    final row = tester.getRect(find.byType(HollowDialogActionRow));

    for (final r in [copy, later, primary]) {
      expect(r.left, moreOrLessEquals(row.left));
      expect(r.width, moreOrLessEquals(row.width));
    }
    expect(copy.bottom, lessThan(later.top));
    expect(later.bottom, lessThan(primary.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row that fits stays one line, leading at the start, primary at the end',
      (tester) async {
    await _atWidth(tester, 1200);
    await tester.pumpWidget(_dialog(leading: leading(), actions: trailing()));
    await tester.pumpAndSettle();

    final copy = _rect(tester, 'Copy');
    final later = _rect(tester, 'Later');
    final primary = _rect(tester, 'Written down');
    final row = tester.getRect(find.byType(HollowDialogActionRow));

    expect(copy.top, moreOrLessEquals(primary.top));
    expect(later.top, moreOrLessEquals(primary.top));
    expect(copy.left, moreOrLessEquals(row.left));
    expect(primary.right, moreOrLessEquals(row.right));
    expect(later.right, lessThan(primary.left));
  });

  testWidgets('two short actions on a phone stay side by side', (tester) async {
    await _atWidth(tester, 360);
    await tester.pumpWidget(_dialog(leading: const [], actions: [
      HollowButton.ghost(onPressed: () {}, child: const Text('Cancel')),
      HollowButton.filled(onPressed: () {}, child: const Text('Save')),
    ]));
    await tester.pumpAndSettle();

    final cancel = _rect(tester, 'Cancel');
    final save = _rect(tester, 'Save');
    expect(cancel.top, moreOrLessEquals(save.top));
    expect(cancel.right, lessThan(save.left));
    expect(save.right, moreOrLessEquals(tester.getRect(find.byType(HollowDialogActionRow)).right));
  });
}
