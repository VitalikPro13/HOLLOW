// A menu row's hover fills the whole row and sits the same distance from the
// menu's frame on every side. On desktop the scrollbar gutter used to leave a
// wide strip to the right of every hover ("Remove from Your art").
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

Future<void> _openMenu(WidgetTester tester, List<HollowMenuEntry> entries) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      scrollBehavior: const HollowScrollBehavior(),
      theme: HollowThemeData.dark().copyWith(platform: TargetPlatform.windows),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showHollowMenu(
                context: context,
                anchor: const Offset(400, 200),
                builder: (_, _) => entries,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

/// The menu's drawn frame, inside its one-pixel border.
Rect _frameInside(WidgetTester tester) {
  final frame = tester.getRect(find.byWidgetPredicate((w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).boxShadow != null));
  return frame.deflate(1);
}

Rect _row(WidgetTester tester, String label) => tester.getRect(
    find.ancestor(of: find.text(label), matching: find.byType(HollowPressable)));

void main() {
  testWidgets('one row: the same gap on all four sides', (tester) async {
    await _openMenu(tester, [
      HollowMenuItem(
        icon: LucideIcons.trash2,
        label: 'Remove from Your art',
        isDanger: true,
        onTap: () {},
      ),
    ]);
    final inside = _frameInside(tester);
    final row = _row(tester, 'Remove from Your art');
    final left = row.left - inside.left;
    expect(row.top - inside.top, closeTo(left, 0.01));
    expect(inside.right - row.right, closeTo(left, 0.01),
        reason: 'the right gap matches the left');
    expect(inside.bottom - row.bottom, closeTo(left, 0.01));
  });

  testWidgets('every row of a longer menu spans the same width',
      (tester) async {
    await _openMenu(tester, [
      HollowMenuItem(label: 'Copy', onTap: () {}),
      const HollowMenuDivider(),
      HollowMenuItem(label: 'Delete', isDanger: true, onTap: () {}),
    ]);
    final inside = _frameInside(tester);
    final copy = _row(tester, 'Copy');
    final delete = _row(tester, 'Delete');
    expect(copy.width, delete.width);
    expect(inside.right - copy.right, closeTo(copy.left - inside.left, 0.01));
    expect(inside.bottom - delete.bottom,
        closeTo(copy.top - inside.top, 0.01));

    // The hover paints that whole row.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: copy.center);
    await tester.pumpAndSettle();
    final fill = tester.widget<AnimatedContainer>(find.descendant(
        of: find.ancestor(
            of: find.text('Copy'), matching: find.byType(HollowPressable)),
        matching: find.byType(AnimatedContainer)));
    expect((fill.decoration as BoxDecoration?)?.color?.a, greaterThan(0));
  });
}
