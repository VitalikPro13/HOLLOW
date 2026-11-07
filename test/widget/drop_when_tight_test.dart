import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/components/drop_when_tight.dart';

/// The trailing word beside a call timer goes whole when the row is short:
/// never painted, tapped or read aloud, and the lead keeps the room.
void main() {
  Future<void> pumpAt(WidgetTester tester, double width,
      {required void Function() onExtra}) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: DropWhenTight(
            gap: 8,
            lead: const SizedBox(width: 40, height: 20),
            extra: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onExtra,
              child: Semantics(
                label: 'extra',
                child: const SizedBox(width: 80, height: 20),
              ),
            ),
          ),
        ),
      ),
    ));

  }

  testWidgets('shows the extra when lead, gap and extra all fit',
      (tester) async {
    var taps = 0;
    await pumpAt(tester, 128, onExtra: () => taps++);
    final box = tester.renderObject<RenderDropWhenTight>(
        find.byType(DropWhenTight));
    expect(box.showsExtra, isTrue);
    await tester.tapAt(const Offset(48 + 40, 10));
    expect(taps, 1);
    expect(find.bySemanticsLabel('extra'), findsOneWidget);
  });

  testWidgets('drops the extra whole when it would not fit', (tester) async {
    var taps = 0;
    // A tight width: the box is wider than the lead, so the dropped extra
    // would sit inside it.
    await pumpAt(tester, 127, onExtra: () => taps++);
    final box = tester.renderObject<RenderDropWhenTight>(
        find.byType(DropWhenTight));
    expect(box.showsExtra, isFalse);
    expect(box.size.width, 127);
    await tester.tapAt(const Offset(48 + 40, 10));
    expect(taps, 0, reason: 'a dropped extra takes no taps');
    expect(find.bySemanticsLabel('extra'), findsNothing);
  });
}
