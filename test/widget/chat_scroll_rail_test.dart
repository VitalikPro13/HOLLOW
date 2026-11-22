// Issue #54: "the main feed doesn't have a scrollbar or jump to top, jump to
// bottom". reversedChatList now carries both.
//
// The thing worth guarding is the INDEX MATH. The list is `reverse: true` —
// index 0 is the NEWEST message, pinned to the bottom — so every "up" in the
// scrollbar is a "higher index" in the list, and getting that backwards gives
// a thumb that slides the wrong way and jump buttons that appear at the wrong
// end. That is invisible in a screenshot of a full-height list and obvious
// here.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/guest/guest_chat_pane.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../helpers/test_app.dart';

const _kOldest = 'Jump to the oldest message';
const _kNewest = 'Jump to the newest message';

late ItemScrollController _controller;
late ItemPositionsListener _positions;
late ScrollOffsetController _offsets;
var _builds = 0;

Future<void> _pumpList(WidgetTester tester,
    {required int itemCount,
    int? unreadRevIndex,
    double Function(int i)? heightOf,
    Size size = const Size(600, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  _controller = ItemScrollController();
  _positions = ItemPositionsListener.create();
  _offsets = ScrollOffsetController();

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
              scrollOffsetController: _offsets,
              itemCount: itemCount,
              unreadRevIndex: unreadRevIndex,
              indexByMessageId: {
                for (var i = 0; i < itemCount; i++) 'm$i': i,
              },
              itemBuilder: (context, revIndex) {
                _builds++;
                final i = itemCount - 1 - revIndex;
                return SizedBox(
                  key: ValueKey('m$i'),
                  height: heightOf?.call(i) ?? 60,
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

Rect thumbRect(WidgetTester tester) => tester.getRect(find.descendant(
      of: find.bySemanticsLabel('Message list scrollbar'),
      matching: find.byType(AnimatedContainer),
    ));

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

  // A jump shares no row with where the list was, so it is no motion and
  // nothing holds the thumb where it last stood.
  testWidgets('a jump either way puts the thumb where the list went',
      (tester) async {
    await _pumpList(tester, itemCount: 200);
    final track =
        tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
    await tester.tap(find.bySemanticsLabel(_kOldest));
    await tester.pumpAndSettle();
    expect(thumbRect(tester).top, moreOrLessEquals(track.top, epsilon: 0.5));
    await tester.tap(find.bySemanticsLabel(_kNewest));
    await tester.pumpAndSettle();
    expect(thumbRect(tester).bottom,
        moreOrLessEquals(track.bottom, epsilon: 0.5),
        reason: 'back at the newest message, the thumb is at the bottom');
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

  // Issue #54's "jump to last red": the rail marks where reading left off.
  // The mark is 3px in a 10px gutter, so the thing that decides whether it is
  // usable is not the paint, it is the snap — see kRailUnreadSnap.
  group('the unread mark', () {
    testWidgets('is absent when the visit has no line', (tester) async {
      await _pumpList(tester, itemCount: 200);
      expect(find.bySemanticsLabel('Jump to the first unread message'),
          findsNothing);
    });

    testWidgets('marks the message position in the conversation',
        (tester) async {
      // Reversed indexes: 150 of 200 is well up the track, toward the OLDEST
      // end, which is the TOP. A mark that lands near the bottom means the
      // reversed mapping was dropped somewhere.
      await _pumpList(tester, itemCount: 200, unreadRevIndex: 150);
      final mark =
          find.bySemanticsLabel('Jump to the first unread message');
      expect(mark, findsOneWidget);
      final markRect = tester.getRect(mark);
      final railRect = tester.getRect(find.byType(ChatScrollRail));
      expect(markRect.center.dy, lessThan(railRect.center.dy),
          reason: 'an older message is further UP the track');
      // A quarter of the way down the conversation is a quarter of the way
      // down the TRACK, not a quarter of the thumb's travel: a thumb filling
      // most of a barely-overflowing track squeezes every mark into its
      // middle, which is what it did on a real build before this.
      final track =
          tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
      final quarter = track.top + track.height * (1 - 150 / 199);
      expect((markRect.center.dy - quarter).abs(), lessThan(3.0));
      expect(markRect.height, kRailUnreadSnap * 2,
          reason: '3px of ink is not a target; the hit box is the snap');
      // Inside the track, not floating over the caps' reservations.
      expect(markRect.top, greaterThan(railRect.top));
      expect(markRect.bottom, lessThan(railRect.bottom));
    });

    testWidgets('the newest and oldest ends land at opposite ends',
        (tester) async {
      await _pumpList(tester, itemCount: 200, unreadRevIndex: 0);
      final atNewest = tester
          .getRect(find.bySemanticsLabel('Jump to the first unread message'))
          .center
          .dy;
      await _pumpList(tester, itemCount: 200, unreadRevIndex: 199);
      final atOldest = tester
          .getRect(find.bySemanticsLabel('Jump to the first unread message'))
          .center
          .dy;
      expect(atOldest, lessThan(atNewest),
          reason: 'index 0 is the NEWEST message, pinned to the bottom');
    });

    testWidgets('a tap near the mark lands on the message, not near it',
        (tester) async {
      await _pumpList(tester, itemCount: 200, unreadRevIndex: 150);
      final markCentre = tester
          .getRect(find.bySemanticsLabel('Jump to the first unread message'))
          .center;
      // Miss it by 6px, which is inside kRailUnreadSnap: aiming at the line
      // and hitting the line are the same intent, and "roughly there" is the
      // one thing this control must not be.
      await tester.tapAt(markCentre.translate(0, 6));
      await tester.pumpAndSettle();
      final visible = _positions.itemPositions.value.map((p) => p.index);
      expect(visible, contains(150));
    });

    testWidgets('stays pressable where the thumb covers it', (tester) async {
      await _pumpList(tester, itemCount: 40, unreadRevIndex: 10);
      final mark = find.bySemanticsLabel('Jump to the first unread message');
      final thumb = find.descendant(
          of: find.byType(ChatScrollRail),
          matching: find.byWidgetPredicate((w) => w is Positioned && w.width == 6));
      final markCentre = tester.getRect(mark).center;
      expect(tester.getRect(thumb).contains(markCentre), isTrue,
          reason: 'the case under test: the thumb sits over the mark');
      final hit = tester.hitTestOnBinding(markCentre);
      expect(hit.path.any((e) => e.target == tester.renderObject(mark)), isTrue,
          reason: 'a thumb painted over the mark took the click, and the '
              'list scrolled to the pointer instead of the first unread');
    });
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

// #158: a voice room's chat is a narrow side panel, where one link card or
// sticker is many text lines tall. A thumb sized by the COUNT of visible rows
// grew and shrank with whatever happened to be on screen, and dragging it fed
// that size back into where the pointer pointed, so the list flicked between
// two places under a still pointer.
group('rows of very different heights (#158)', () {
  // Every fourth message is a card ten times the height of a text line.
  double mixed(int i) => i % 4 == 0 ? 400 : 40;
  Future<void> wheel(WidgetTester tester, double dy) async {
    final list = tester.getCenter(find.byType(ScrollablePositionedList));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(list));
    await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
    await tester.pumpAndSettle();
  }

  testWidgets('the thumb keeps its size while the wheel scrolls',
      (tester) async {
    await _pumpList(tester,
        itemCount: 24, heightOf: mixed, size: const Size(400, 700));
    // One pass up and back measures every row once.
    for (var i = 0; i < 40; i++) {
      await wheel(tester, -120);
    }
    for (var i = 0; i < 40; i++) {
      await wheel(tester, 120);
    }
    final heights = <double>[];
    for (var i = 0; i < 40; i++) {
      await wheel(tester, -120);
      heights.add(thumbRect(tester).height);
    }
    final spread = heights.reduce((a, b) => a > b ? a : b) -
        heights.reduce((a, b) => a < b ? a : b);
    expect(spread, lessThan(2),
        reason: 'the conversation does not change length while you scroll '
            'it, so neither may the thumb: $heights');
  });

  testWidgets('dragging the thumb moves the list one way only',
      (tester) async {
    await _pumpList(tester,
        itemCount: 24, heightOf: mixed, size: const Size(400, 700));
    final track =
        tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
    final start = thumbRect(tester).center;
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    final tops = <int>[];
    final thumbs = <double>[];
    for (var dy = 0.0; start.dy - dy > track.top; dy += 6) {
      await gesture.moveTo(Offset(start.dx, start.dy - dy));
      await tester.pump();
      await tester.pump();
      tops.add(_positions.itemPositions.value
          .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
          .map((p) => p.index)
          .reduce((a, b) => a > b ? a : b));
      thumbs.add(thumbRect(tester).height);
    }
    await gesture.up();
    await tester.pumpAndSettle();
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThanOrEqualTo(tops[i - 1]),
          reason: 'pulling the thumb up only ever shows older messages: $tops');
    }
    expect(
        thumbs.reduce((a, b) => a > b ? a : b) -
            thumbs.reduce((a, b) => a < b ? a : b),
        lessThan(0.01),
        reason: 'the thumb under the pointer keeps its size for the drag');
    expect(find.text('message 0'), findsOneWidget,
        reason: 'the top of the track is the oldest message');
  });

  testWidgets('"jump to top" leaves no empty space above the oldest message',
      (tester) async {
    await _pumpList(tester,
        itemCount: 24, heightOf: mixed, size: const Size(400, 700));
    await tester.tap(find.bySemanticsLabel(_kOldest));
    await tester.pumpAndSettle();
    final oldest =
        _positions.itemPositions.value.firstWhere((p) => p.index == 23);
    expect(oldest.itemTrailingEdge, greaterThanOrEqualTo(0.97),
        reason: 'the oldest message starts at the top of the list, not '
            'somewhere down it with blank space over it');
    expect(find.bySemanticsLabel(_kOldest), findsNothing);
  });

  // #158 review: a press that rests on the thumb before moving (tap down fires
  // after 100 ms) recentred the thumb under the pointer.
  testWidgets('a still press on the thumb leaves the list where it is',
      (tester) async {
    await _pumpList(tester, itemCount: 200);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 4000));
    await tester.pumpAndSettle();
    Set<int> visible() => _positions.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
        .map((p) => p.index)
        .toSet();
    final before = visible();
    final thumb = thumbRect(tester);
    final g = await tester.startGesture(Offset(thumb.center.dx, thumb.top + 3),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(visible(), before,
        reason: 'grabbing the thumb moves nothing until the pointer does');
    await g.up();
    await tester.pumpAndSettle();
    expect(visible(), before);
  });

  // #158 review: a pixel drag lays out every row it passes, so a quick flick
  // of the thumb over a long history built hundreds of rows in one frame.
  // A long step lands by index instead, which costs what any jump costs,
  // however far it goes.
  testWidgets('a long drag step builds about what a jump builds',
      (tester) async {
    await _pumpList(tester, itemCount: 10000);
    final g = await tester.startGesture(thumbRect(tester).center,
        kind: PointerDeviceKind.mouse);
    await tester.pump();
    await g.moveBy(const Offset(0, -2));
    await tester.pump();
    final small = _positions.itemPositions.value.map((p) => p.index).toSet();
    _builds = 0;
    await g.moveBy(const Offset(0, -40));
    await tester.pump();
    final built = _builds;
    final after = _positions.itemPositions.value.map((p) => p.index).toSet();
    await g.up();
    await tester.pumpAndSettle();
    expect(after.intersection(small), isEmpty,
        reason: 'the list still moved the whole way');
    expect(after.reduce((a, b) => a < b ? a : b),
        greaterThan(small.reduce((a, b) => a > b ? a : b)),
        reason: 'pulling the thumb up shows older messages');

    // A jump lays out about two screens and the cache extent: ~120 rows here.
    expect(built, lessThan(200),
        reason: 'a 40 px thumb move built $built rows in one frame');
  });

  // #158: rows never seen count as the average of those measured, and each
  // first measurement moves that average; the thumb must not step back
  // against a steady wheel while it does.
  testWidgets('a steady wheel moves the thumb one way on a first pass',
      (tester) async {
    double ragged(int i) => const <double>[40, 400, 40, 120, 40, 40, 260, 40][i % 8];
    await _pumpList(tester,
        itemCount: 60, heightOf: ragged, size: const Size(400, 700));
    final tops = <double>[thumbRect(tester).top];
    while (find.bySemanticsLabel(_kOldest).evaluate().isNotEmpty &&
        tops.length < 400) {
      await wheel(tester, -60);
      tops.add(thumbRect(tester).top);
    }
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], lessThanOrEqualTo(tops[i - 1] + 0.01),
          reason: 'step $i of a wheel toward older messages: $tops');
    }
    final track =
        tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
    expect(tops.last, closeTo(track.top, 0.5),
        reason: 'the oldest message puts the thumb at the top');
  });
});

// #158 review: the guest pane built its rail without row keys, so measured
// heights were kept by index and slid onto the wrong row with every arrival.
testWidgets('the guest pane keys its rail rows by message id', (tester) async {
  tester.view.physicalSize = const Size(900, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: hollowTestOverrides());
  addTearDown(container.dispose);
  const key = 'srv:general';
  List<ChannelChatMessage> rows(int n) => [
        for (var i = 0; i < n; i++)
          ChannelChatMessage(
              senderId: 'carol',
              text: 'message $i',
              isMe: false,
              messageId: 'm$i',
              timestamp: DateTime(2026, 11, 22, 12, i)),
      ];
  container.read(guestHasMoreProvider.notifier).state = {key: true};
  container.read(channelChatProvider.notifier).state = {key: rows(40)};
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const Scaffold(
          body: GuestChatPane(serverId: 'srv', channelId: 'general')),
    ),
  ));
  await tester.pump();
  ChatScrollRail rail() => tester.widget(find.byType(ChatScrollRail));
  expect(rail().rowKeyAt, isNotNull);
  expect(rail().rowKeyAt!(0), 'm39', reason: 'the newest row');
  expect(rail().rowKeyAt!(39), 'm0');
  expect(rail().rowKeyAt!(40), isNot(anyOf('m0', 40)),
      reason: '"Load more" has a key of its own');

  container.read(channelChatProvider.notifier).state = {key: rows(41)};
  await tester.pump();
  expect(rail().rowKeyAt!(1), 'm39',
      reason: 'a row keeps its key when a new message shifts every index');
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 13));
});
}
