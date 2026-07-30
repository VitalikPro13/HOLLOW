import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// The bug this component exists for: a plain horizontal scroller inside a
/// popup is unreachable on a desktop with a wheel mouse — no drag affordance,
/// no gesture. It showed up first as GIF favourites lists you could create
/// but not scroll to.

Future<void> _pump(WidgetTester tester, int items, {double width = 300}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: EdgeScrollRow(
              height: 34,
              semanticLabel: 'lists',
              children: [
                for (var i = 0; i < items; i++)
                  SizedBox(width: 100, height: 24, child: Text('item $i')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  // Overflow is only knowable after layout — the widget syncs post-frame.
  await tester.pumpAndSettle();
}

Finder get _rightArrow => find.bySemanticsLabel('Scroll lists right');
Finder get _leftArrow => find.bySemanticsLabel('Scroll lists left');

/// The semantics finder lands on a Semantics node — the button is above it.
bool _enabled(WidgetTester tester, Finder arrow) =>
    tester
        .widget<HollowPressable>(
            find.ancestor(of: arrow, matching: find.byType(HollowPressable)).first)
        .onTap !=
    null;

void main() {
  testWidgets('no affordance at all when everything fits', (tester) async {
    await _pump(tester, 2); // 200px of content in 300px
    expect(_leftArrow, findsNothing);
    expect(_rightArrow, findsNothing);
  });

  testWidgets('an overflowing row offers a way forward', (tester) async {
    await _pump(tester, 6); // 600px of content in 300px
    expect(_rightArrow, findsOneWidget);
    // BOTH slots exist once overflowing — the left one is just disabled.
    // (Showing/hiding a sibling arrow would change the viewport width and
    // flip-flop the other one; see the _overflowing comment.)
    expect(_leftArrow, findsOneWidget);
    expect(_enabled(tester, _leftArrow), isFalse,
        reason: 'nothing to the left yet — you start at the beginning');
    expect(_enabled(tester, _rightArrow), isTrue);
  });

  testWidgets('the arrow actually moves the row, and back', (tester) async {
    await _pump(tester, 6);
    final scrollable = find.byType(SingleChildScrollView);
    final controller =
        tester.widget<SingleChildScrollView>(scrollable).controller!;
    expect(controller.offset, 0);

    await tester.tap(_rightArrow);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    // Once moved, the way back becomes usable.
    expect(_enabled(tester, _leftArrow), isTrue);

    await tester.tap(_leftArrow);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(_enabled(tester, _leftArrow), isFalse);
  });

  testWidgets('the layout SETTLES at the end instead of flip-flopping',
      (tester) async {
    await _pump(tester, 4);
    final controller = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle(); // would time out if the arrows oscillated
    expect(_enabled(tester, _rightArrow), isFalse,
        reason: 'at the end, the right arrow is dead');
    expect(_enabled(tester, _leftArrow), isTrue);
    // Both slots are still there — the width never changed.
    expect(_rightArrow, findsOneWidget);
  });

  testWidgets('growing past the edge reveals the affordance', (tester) async {
    // Adding a list is one way a fitting row becomes an overflowing one.
    await _pump(tester, 2);
    expect(_rightArrow, findsNothing);
    await _pump(tester, 6);
    expect(_rightArrow, findsOneWidget);
  });

  testWidgets('RESIZING past the edge reveals the affordance', (tester) async {
    // The other way, and the one that actually bit: narrowing the window (or
    // raising the text scale) changes the EXTENTS without changing the
    // children, so a child-count check never fires. Server Settings tabs
    // stayed unreachable exactly like this.
    await _pump(tester, 6, width: 800);
    expect(_rightArrow, findsNothing, reason: 'six items fit in 800px');

    await _pump(tester, 6, width: 300);
    expect(_rightArrow, findsOneWidget, reason: 'the same six do not fit 300');

    // …and back: widening past the overflow point puts it away again.
    await _pump(tester, 6, width: 800);
    expect(_rightArrow, findsNothing);
  });

  testWidgets('arrows sit BESIDE the scroller, never on top of it',
      (tester) async {
    // Load-bearing for the dock: overlaid arrows would cover the reorder
    // drop zones, which sit exactly at the two ends.
    await _pump(tester, 6);
    final arrow = tester.getRect(_rightArrow);
    final scroller = tester.getRect(find.byType(SingleChildScrollView));
    expect(arrow.left, greaterThanOrEqualTo(scroller.right - 0.5),
        reason: 'the arrow starts where the scroller ends');
  });

  group('center: true (the dock server strip)', () {
    Future<void> pumpCentered(WidgetTester tester, int items,
        {double width = 600}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: EdgeScrollRow(
                semanticLabel: 'servers',
                center: true,
                children: [
                  for (var i = 0; i < items; i++)
                    SizedBox(
                        key: ValueKey('s$i'), width: 44, height: 44),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double firstLeft(WidgetTester tester) =>
        tester.getRect(find.byKey(const ValueKey('s0'))).left;
    Finder serversRight() => find.bySemanticsLabel('Scroll servers right');

    testWidgets('centres while the icons fit', (tester) async {
      // An outer Center CANNOT do this once arrow slots exist — the strip
      // silently went left-aligned when it was tried that way.
      await pumpCentered(tester, 3);
      expect(firstLeft(tester), closeTo((600 - 3 * 44) / 2, 0.5));
      expect(serversRight(), findsNothing);
    });

    testWidgets('gives up centring and scrolls once it overflows',
        (tester) async {
      await pumpCentered(tester, 30);
      expect(serversRight(), findsOneWidget);
      // Hard against the left edge (past the arrow slot) — no slack left to
      // distribute, so the centring is a no-op exactly when it should be.
      expect(firstLeft(tester), lessThan(44));
    });

    testWidgets('goes back to centred when the icons fit again',
        (tester) async {
      await pumpCentered(tester, 30);
      expect(serversRight(), findsOneWidget);
      await pumpCentered(tester, 3);
      expect(firstLeft(tester), closeTo((600 - 3 * 44) / 2, 0.5));
      expect(serversRight(), findsNothing);
    });
  });

  testWidgets('a fade never eats a tap', (tester) async {
    await _pump(tester, 6);
    // The chip under the gradient must stay tappable.
    final fade = find.byKey(const ValueKey('edge-fade-right'));
    expect(fade, findsOneWidget);
    expect(
      find.descendant(of: fade, matching: find.byType(IgnorePointer)),
      findsOneWidget,
    );
  });
}
