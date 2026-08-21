// Issue #54: "some scrollbars on the app cover other elements instead of being
// on the side". Flutter's desktop default paints the thumb over the last few
// pixels of the scrollable, so any list whose rows end flush at their right
// edge (the label-assign dialog's checkbox column, the profile fields) gets
// covered as soon as it is long enough to scroll.
//
// HollowScrollBehavior fixes that once, for every scrollable in the app, by
// reserving a gutter INSIDE the scrollbar and OUTSIDE the viewport. These
// guard the three properties that make it work — a regression in any of them
// puts the thumb back on top of the content.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';

Widget _build(TargetPlatform platform, AxisDirection direction) {
  const behavior = HollowScrollBehavior();
  const child = SizedBox(key: ValueKey('viewport'));
  return MaterialApp(
    theme: ThemeData(platform: platform),
    home: Builder(
      builder: (context) => behavior.buildScrollbar(
        context,
        child,
        ScrollableDetails(direction: direction),
      ),
    ),
  );
}

void main() {
  for (final platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform reserves a gutter beside the viewport',
        (tester) async {
      await tester.pumpWidget(_build(platform, AxisDirection.down));

      expect(find.byType(Scrollbar), findsOneWidget,
          reason: 'desktop still gets a scrollbar');

      final padding = tester.widget<Padding>(
        find.descendant(
          of: find.byType(Scrollbar),
          matching: find.byType(Padding),
        ),
      );
      expect(
        padding.padding,
        const EdgeInsets.only(right: kScrollGutter),
        reason: 'the viewport is inset so the thumb never covers a row; a '
            'Scrollbar wrapped directly around the child paints on top of it',
      );

      final bar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(bar.thumbVisibility, isNot(true),
          reason: 'the thumb fades like every other one; pinning it reads as '
              'a stuck UI element');
    });
  }

  testWidgets('touch platforms are left alone', (tester) async {
    await tester.pumpWidget(_build(TargetPlatform.android, AxisDirection.down));
    expect(find.byType(Scrollbar), findsNothing,
        reason: 'no scrollbar on touch, so reserving space for one would be a '
            'hole in the layout for nothing');
  });

  testWidgets('horizontal scrollables are left alone', (tester) async {
    await tester.pumpWidget(
        _build(TargetPlatform.windows, AxisDirection.right));
    expect(find.byType(Scrollbar), findsNothing,
        reason: 'Material only decorates the vertical axis, and a horizontal '
            'strip (emote rows, the server folder shelf) has no room to give');
  });
}
