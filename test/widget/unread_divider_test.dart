// Issue #54: "jump to top, jump to last red, jump to bottom". The "last red"
// is the line above the first message that arrived while you were away.
//
// Two separate things can go wrong here and only one of them is visible in a
// screenshot:
//
//  * WHERE the line lands. It is index math against a reversed list, exactly
//    the class of bug that hid in the rail's drag mapping until a test found
//    it, and the rules that keep it honest (your own messages do not open an
//    unread run; a pointer that fell off the front of the window means
//    everything loaded is new) are invisible unless asserted.
//  * WHETHER the line costs the row any layout. It stacks with the date
//    separator, so a row can carry both, and a chat that shifts when a line
//    appears is worse than no line.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';

import '../helpers/test_app.dart';

/// A conversation of [count] messages, `m0` oldest. [mine] are the indexes the
/// local user sent.
int? _divider(int count, String? entrySeenId, {Set<int> mine = const {}}) =>
    unreadDividerIndex(
      count: count,
      entrySeenId: entrySeenId,
      messageIdAt: (i) => 'm$i',
      isMineAt: (i) => mine.contains(i),
    );

Future<void> _pumpRow(
  WidgetTester tester, {
  required bool unreadDivider,
  required bool showDate,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: dateSeparatedChatRow(
                rowKey: 'm1',
                timestamp: DateTime(2026, 1, 5, 12),
                prevTimestamp:
                    showDate ? DateTime(2026, 1, 4, 12) : DateTime(2026, 1, 5, 11),
                showHeader: false,
                unreadDivider: unreadDivider,
                // NO explicit width, on purpose: a grouped continuation row
                // shrink-wraps, and the bug this guards is a separator Column
                // centring exactly that.
                child: const SizedBox(
                    key: ValueKey('body'), height: 40, child: Text('hi')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('where the line lands', () {
    test('no marker for this visit means no line', () {
      expect(_divider(5, null), isNull);
    });

    test('the line goes above the first message after the entry pointer', () {
      expect(_divider(5, 'm2'), 3);
    });

    test('having read the newest message leaves nothing to mark', () {
      expect(_divider(5, 'm4'), isNull);
    });

    test('a conversation never opened marks everything in the window', () {
      expect(_divider(5, ''), 0);
    });

    test('a pointer older than the loaded window marks everything in it', () {
      // 200-row window, the pointer is a message that fell off the front.
      expect(_divider(5, 'm-ancient'), 0);
    });

    // The rule that keeps the line off your own replies: sending is not
    // arriving. Without it, typing one message into a quiet conversation
    // draws a "new messages" line above your own words.
    test('your own messages do not open an unread run', () {
      expect(_divider(5, 'm1', mine: {2, 3}), 4);
    });

    test('a run of nothing but your own messages draws no line', () {
      expect(_divider(5, 'm2', mine: {3, 4}), isNull);
    });

    test('an empty conversation draws no line', () {
      expect(_divider(0, ''), isNull);
    });
  });

  group('what the line costs the row', () {
    testWidgets('the line does not move the message it introduces',
        (tester) async {
      await _pumpRow(tester, unreadDivider: false, showDate: false);
      final bare = tester.getRect(find.byKey(const ValueKey('body')));
      expect(find.text('New'), findsNothing);

      await _pumpRow(tester, unreadDivider: true, showDate: false);
      final marked = tester.getRect(find.byKey(const ValueKey('body')));
      expect(find.text('New'), findsOneWidget);
      // The row moves DOWN by exactly the line's own height and not a pixel
      // sideways — the message keeps its column.
      expect(marked.left, bare.left,
          reason: 'the Column a separator introduces defaults to CENTRE, so a '
              'row that shrink-wraps (any grouped continuation) drifts to the '
              'middle of the pane the moment a line lands above it');
      expect(marked.width, bare.width);
      expect(marked.top, greaterThan(bare.top));
    });

    testWidgets('a row carrying both draws ONE rule, not two', (tester) async {
      // Coming back the next day is the most ordinary way to see this line at
      // all, so the row almost always carries a date too. Stacked, that is two
      // full-width rules about 30px apart with nothing between them — the same
      // double-rule problem the own-message bar had against the scrollbar.
      await _pumpRow(tester, unreadDivider: true, showDate: true);
      expect(find.byType(DateSeparator), findsNothing,
          reason: 'the day merges INTO the unread rule');
      expect(find.byType(UnreadDivider), findsOneWidget);

      final date = tester.getRect(find.text('January 5, 2026'));
      final badge = tester.getRect(find.text('New'));
      final body = tester.getRect(find.byKey(const ValueKey('body')));
      // One row: the day sits between the rule's two halves, the badge at the
      // right end, and the message underneath both.
      expect((date.center.dy - badge.center.dy).abs(), lessThan(2.0));
      expect(date.right, lessThan(badge.left));
      expect(badge.top, lessThan(body.top));
    });

    testWidgets('a date with nothing new keeps the plain day separator',
        (tester) async {
      await _pumpRow(tester, unreadDivider: false, showDate: true);
      expect(find.byType(DateSeparator), findsOneWidget);
      expect(find.byType(UnreadDivider), findsNothing);
    });
  });
}
