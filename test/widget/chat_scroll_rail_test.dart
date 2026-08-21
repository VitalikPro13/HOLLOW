// Issue #54: "the main feed doesn't have a scrollbar or jump to top, jump to
// bottom". reversedChatList now carries both.
//
// The thing worth guarding is the INDEX MATH. The list is `reverse: true` —
// index 0 is the NEWEST message, pinned to the bottom — so every "up" in the
// scrollbar is a "higher index" in the list, and getting that backwards gives
// a thumb that slides the wrong way and jump buttons that appear at the wrong
// end. That is invisible in a screenshot of a full-height list and obvious
// here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../helpers/test_app.dart';

const _kOldest = 'Jump to the oldest message';
const _kNewest = 'Jump to the newest message';

late ItemScrollController _controller;
late ItemPositionsListener _positions;

Future<void> _pumpList(WidgetTester tester, {required int itemCount}) async {
  tester.view.physicalSize = const Size(600, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  _controller = ItemScrollController();
  _positions = ItemPositionsListener.create();

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => reversedChatList(
              context: context,
              itemScrollController: _controller,
              itemPositionsListener: _positions,
              itemCount: itemCount,
              indexByMessageId: {
                for (var i = 0; i < itemCount; i++) 'm$i': i,
              },
              itemBuilder: (context, revIndex) {
                final i = itemCount - 1 - revIndex;
                return SizedBox(
                  key: ValueKey('m$i'),
                  height: 60,
                  child: Text('message $i'),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a conversation that fits offers nothing to jump to',
      (tester) async {
    await _pumpList(tester, itemCount: 3);
    expect(find.bySemanticsLabel(_kOldest), findsNothing);
    expect(find.bySemanticsLabel(_kNewest), findsNothing);
  });

  testWidgets('at the bottom, only "jump to top" is offered', (tester) async {
    await _pumpList(tester, itemCount: 200);
    // The list opens pinned to the newest message, so there is nothing newer
    // to jump to and a whole history above.
    expect(find.bySemanticsLabel(_kOldest), findsOneWidget);
    expect(find.bySemanticsLabel(_kNewest), findsNothing);
  });

  testWidgets('scrolled up, "jump to present" appears', (tester) async {
    await _pumpList(tester, itemCount: 200);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(_kNewest), findsOneWidget,
        reason: 'reading history is exactly when you need the way back');

    await tester.tap(find.bySemanticsLabel(_kNewest));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(_kNewest), findsNothing,
        reason: 'it took us back to the newest message, so it is gone again');
  });

  testWidgets('"jump to top" reaches the oldest message', (tester) async {
    await _pumpList(tester, itemCount: 200);
    expect(find.text('message 0'), findsNothing);

    await tester.tap(find.bySemanticsLabel(_kOldest));
    await tester.pumpAndSettle();

    expect(find.text('message 0'), findsOneWidget,
        reason: 'the oldest message is the LAST reversed index, not index 0');
    expect(find.bySemanticsLabel(_kOldest), findsNothing);
  });

  testWidgets('pressing the top of the track walks back through history',
      (tester) async {
    await _pumpList(tester, itemCount: 200);
    expect(find.text('message 199'), findsOneWidget,
        reason: 'we start pinned to the newest message');

    final track = find.bySemanticsLabel('Message list scrollbar');
    final rect = tester.getRect(track);
    // Near the top of the track is the OLDEST end: reversed indexes put the
    // newest message at index 0, at the BOTTOM.
    await tester.tapAt(Offset(rect.center.dx, rect.top + 12));
    await tester.pumpAndSettle();

    expect(find.text('message 199'), findsNothing,
        reason: 'a press near the top of the track must move the view, and '
            'must move it toward the OLDEST end, not the newest');
    expect(find.bySemanticsLabel(_kNewest), findsOneWidget);
  });

  testWidgets('dragging the thumb moves the list, not the list under it',
      (tester) async {
    await _pumpList(tester, itemCount: 200);
    final rect = tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
    // Grab the thumb where it sits when pinned to the newest message (the
    // bottom of the track) and pull it up. The message list has a vertical
    // drag recognizer of its own directly underneath, so this also pins down
    // which one wins the gesture arena.
    await tester.dragFrom(
      Offset(rect.center.dx, rect.bottom - 20),
      Offset(0, -(rect.height - 60)),
    );
    await tester.pumpAndSettle();

    expect(find.text('message 199'), findsNothing,
        reason: 'the drag has to reach the rail; if the list swallows it the '
            'scrollbar is decoration');
    expect(find.bySemanticsLabel(_kNewest), findsOneWidget);
  });

  testWidgets('the jump control sits in the gutter, beyond the action bar',
      (tester) async {
    await _pumpList(tester, itemCount: 200);
    final cap = tester.getRect(find.bySemanticsLabel(_kOldest));
    final row = tester.getRect(find.byType(ScrollablePositionedList));

    expect(cap.left, greaterThanOrEqualTo(row.right),
        reason: 'the message hover action bar is an OverlayEntry centred on '
            'whatever row the pointer is over and right-aligned to it, so it '
            'covers anything floating inside the row band — which is exactly '
            'what happened to the first round jump buttons. The gutter is the '
            'only strip it cannot reach.');
  });

  testWidgets('"jump to top" works on a barely-overflowing conversation',
      (tester) async {
    // The real bug this pins: a conversation only a little taller than the
    // viewport. Jumping to the last reversed index asks the list to put the
    // OLDEST message at the bottom edge, which is past the end of the
    // content, and an out-of-range anchor can be corrected straight back to
    // where it started — i.e. the button does nothing.
    await _pumpList(tester, itemCount: 16);
    expect(find.text('message 0'), findsNothing);

    await tester.tap(find.bySemanticsLabel(_kOldest));
    await tester.pumpAndSettle();

    expect(find.text('message 0'), findsOneWidget);
  });

  testWidgets('the rail keeps its controls clear of the window edge',
      (tester) async {
    await _pumpList(tester, itemCount: 200);
    final rail = tester.getRect(find.byType(ChatScrollRail));
    final cap = tester.getRect(find.bySemanticsLabel(_kOldest));

    expect(rail.right - cap.right, greaterThanOrEqualTo(kWindowEdgeDeadStrip),
        reason: 'the chat is the rightmost pane whenever the member list is '
            'closed, and on Windows the frameless resize border eats pointer '
            'events in the outer 8px of the client area — a control centred '
            'in a rail that hugs the edge is simply dead, and every widget '
            'test still passes');
  });

  testWidgets('the rail is a column beside the list, not an overlay on it',
      (tester) async {
    await _pumpList(tester, itemCount: 200);
    final listRect = tester.getRect(find.byType(ScrollablePositionedList));
    final railRect = tester.getRect(find.byType(ChatScrollRail));

    expect(railRect.left, greaterThanOrEqualTo(listRect.right),
        reason: 'as a Stack overlay the rail laid out and PAINTED correctly '
            'and then never received a single pointer — not a tap, not a '
            'hover, not even a translucent Listener at its root. A column '
            'cannot have that argument with anything.');
    expect(railRect.width, kChatRailWidth);
  });
}
