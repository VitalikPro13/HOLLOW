// Issue #35: at an interface scale other than 100%, a left-click in the chat
// list jumped the viewport, and a drag toward the top edge kept auto-scrolling
// after the mouse button was released.
//
// The cause is upstream (Flutter's scroll-aware selection delegate mixes local
// and global coordinate spaces, so a root scale transform leaves an error of
// scrollOffset * (scale - 1) — see the comment in chat_pane_shared.dart).
// reversedChatList works around it by scoping selection to the row whenever
// the interface scale is not 1.0, which removes the Scrollable from between
// the SelectableRegion and the selectables.
//
// NOTE for anyone extending these: the list must be scrolled by DRAGGING.
// ItemScrollController.jumpTo re-anchors ScrollablePositionedList and leaves
// `position.pixels` near zero, and the coordinate error is proportional to
// exactly that number — a jumpTo-based setup reproduces nothing.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../helpers/test_app.dart';

const _itemCount = 300;

/// The live scroll position of the chat list.
ScrollPosition _position(WidgetTester tester) =>
    Scrollable.of(tester.element(find.byType(SizedBox).first)).position;

/// Builds the real [reversedChatList] under an interface scale, then drags it
/// back through the history so the viewport carries a large scroll offset.
Future<void> _pumpScrolledList(
  WidgetTester tester, {
  required double scale,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final itemScrollController = ItemScrollController();
  final itemPositionsListener = ItemPositionsListener.create();

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: UiScaleBox(
            scale: scale,
            child: Builder(
              builder: (context) => reversedChatList(
                context: context,
                itemScrollController: itemScrollController,
                itemPositionsListener: itemPositionsListener,
                itemCount: _itemCount,
                indexByMessageId: {
                  for (var i = 0; i < _itemCount; i++) 'm$i': i,
                },
                itemBuilder: (context, revIndex) {
                  final i = _itemCount - 1 - revIndex;
                  return SizedBox(
                    key: ValueKey('m$i'),
                    height: 60,
                    child: Text('message number $i with selectable words'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  for (var i = 0; i < 12; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final scale in <double>[1.0, 1.25, 1.5]) {
    testWidgets('click in the chat list does not move the viewport '
        '(scale $scale)', (tester) async {
      await _pumpScrolledList(tester, scale: scale);
      final before = _position(tester).pixels;
      expect(before, greaterThan(1000),
          reason: 'setup must leave the list genuinely scrolled back');

      await tester.tapAt(const Offset(400, 400));
      await tester.pumpAndSettle();

      expect(_position(tester).pixels, moreOrLessEquals(before, epsilon: 0.5),
          reason: 'a plain click must not scroll the chat at scale $scale');
    });

    testWidgets('selection drag stops scrolling on mouse release '
        '(scale $scale)', (tester) async {
      await _pumpScrolledList(tester, scale: scale);

      // Drag up into the auto-scroll edge zone, then release.
      final gesture = await tester.startGesture(const Offset(400, 400),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(const Offset(400, 20));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump();

      final atRelease = _position(tester).pixels;
      // Anything still auto-scrolling keeps moving across these frames.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 1500));

      expect(_position(tester).pixels,
          moreOrLessEquals(atRelease, epsilon: 0.5),
          reason: 'the list kept auto-scrolling after mouse-up at $scale');
    });
  }

  testWidgets('text selection survives the workaround', (tester) async {
    await _pumpScrolledList(tester, scale: 1.25);
    // Selection is scoped to rows, not removed: a SelectableRegion must still
    // be in the tree so the fix does not silently cost the user selection.
    expect(find.byType(SelectableRegion), findsWidgets);
  });
}
