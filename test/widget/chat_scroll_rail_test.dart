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
import 'package:hollow/src/theme/hollow_spacing.dart';
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

  testWidgets('the rail clears the chrome above and below it', (tester) async {
    // Measured on a real build before this existed: the top cap started at
    // y=125 with the header's bottom border at y=124 — flush, not "nearly".
    // The bottom cap sat on the composer's top border the same way. Two
    // controls jammed into the corners of the message area is most of why the
    // rail read as unfinished.
    await _pumpList(tester, itemCount: 200);
    final rail = tester.getRect(find.byType(ChatScrollRail));
    final cap = tester.getRect(find.bySemanticsLabel(_kOldest));

    expect(cap.top - rail.top, kRailEndInset,
        reason: 'the cap must never touch the header above it');
    expect(rail.right - cap.right, kWindowEdgeDeadStrip,
        reason: 'and the whole control stays flush against the LIVE edge of '
            'the gutter, which is where every other scrollbar in the app '
            'draws itself');
  });

  testWidgets('a thumb at the end of the list is at the end of its track',
      (tester) async {
    // The complaint this exists for, in Vitalik's words: "when it's the last
    // message, no way to scroll and it shows like there is something to
    // scroll, but there are not." Measured on a real build at the time: the
    // track painted down to y=548 while the thumb stopped at y=526, so 22px
    // of empty track sat under it — one _kCapExtent, which the old rail
    // reserved for a cap and then painted groove across anyway. A scrollbar
    // that lies about how much is left is worse than no scrollbar.
    await _pumpList(tester, itemCount: 200);
    final track =
        tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
    final thumb = tester.getRect(find.descendant(
      of: find.bySemanticsLabel('Message list scrollbar'),
      matching: find.byType(AnimatedContainer),
    ));

    expect(thumb.bottom, moreOrLessEquals(track.bottom, epsilon: 0.5),
        reason: 'the list opens pinned to the newest message, so there is '
            'nothing below — and the track must not show room below either');

    await tester.tap(find.bySemanticsLabel(_kOldest));
    await tester.pumpAndSettle();

    final atTop = tester.getRect(find.descendant(
      of: find.bySemanticsLabel('Message list scrollbar'),
      matching: find.byType(AnimatedContainer),
    ));
    expect(atTop.top, moreOrLessEquals(track.top, epsilon: 0.5),
        reason: 'and the same at the oldest end');

    // The half that actually bites. The thumb always reached the ends of the
    // TRACK; what lied was the painted groove, which ran the rail's whole
    // height with the caps drawn inside its ends. Separated segments cannot:
    // a gap between cap and track is proof the track stops where the travel
    // stops. Before this, cap.bottom == track.top exactly.
    final cap = tester.getRect(find.bySemanticsLabel(_kNewest));
    expect(cap.top - track.bottom, kRailSegmentGap,
        reason: 'the track must END above the cap, not run underneath it');
  });

  testWidgets('the caps hold their place when they stop being actionable',
      (tester) async {
    // They used to vanish at the end they point to, which resized the track
    // between them and shifted the thumb every time you reached an end. The
    // pill stays; it just stops being a button.
    await _pumpList(tester, itemCount: 200);
    final trackAtBottom =
        tester.getRect(find.bySemanticsLabel('Message list scrollbar'));

    await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(_kNewest), findsOneWidget,
        reason: 'scrolled up, "jump to present" becomes actionable');

    expect(tester.getRect(find.bySemanticsLabel('Message list scrollbar')),
        trackAtBottom,
        reason: 'and the track it shares the column with does not move');
  });

  testWidgets('the thumb rides centred inside the groove', (tester) async {
    // The groove is the thing that makes a cap, a thumb and a cap read as ONE
    // control instead of three chips scattered down the gutter. A thumb
    // shoved against one wall of its own track undoes that.
    await _pumpList(tester, itemCount: 200);
    final track =
        tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
    final thumb = tester.getRect(find.descendant(
      of: find.bySemanticsLabel('Message list scrollbar'),
      matching: find.byType(AnimatedContainer),
    ));

    expect(thumb.left - track.left, track.right - thumb.right,
        reason: 'centred in the track it rides in');
    expect(thumb.width, 6);
  });

  test('a chat rule ends level with where it starts', () {
    // Pure arithmetic, on purpose: this is the invariant that breaks the
    // moment someone changes kChatRailWidth without looking at the date
    // separator. The rule is the only thing in a chat that draws all the way
    // across, so its two ends are where an unbalanced gutter shows. Measured
    // before this held: 16px from the pane's left edge, 34px from its right.
    expect((kChatRuleEndInset + kChatRailWidth - HollowSpacing.lg).abs(),
        lessThanOrEqualTo(4.0),
        reason: 'the rail already holds kChatRailWidth of the pane edge, so '
            'the rule gives that back out of its own right padding — within '
            'a few px of the HollowSpacing.lg its left end sits at');
  });

  testWidgets('the date rule gives the rail its width back', (tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<double> rightEndOf({required bool railGutter}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: hollowTestOverrides(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: dateSeparatedChatRow(
                rowKey: 'r',
                timestamp: DateTime(2026, 8, 21),
                prevTimestamp: null,
                showHeader: true,
                railGutter: railGutter,
                child: const SizedBox(height: 20),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final box = tester.getRect(find.byType(DateSeparator));
      final rule = tester.getRect(find.descendant(
        of: find.byType(DateSeparator),
        matching: find.byType(Container),
      ).last);
      return box.right - rule.right;
    }

    expect(await rightEndOf(railGutter: false), HollowSpacing.lg,
        reason: 'no rail (mobile, the pinned list) means symmetric padding');
    expect(await rightEndOf(railGutter: true), kChatRuleEndInset,
        reason: 'with a rail beside the list the rule reclaims its width, or '
            'it stops 34px from the pane edge while starting 16px from the '
            'other one');
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
