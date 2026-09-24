// The message hover: the row paints its own highlight (no layout change, it
// scrolls with the row) and the action bar rides the row's top edge through a
// scroll instead of staying where the pointer first found it.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';

import '../helpers/test_app.dart';

Future<void> _pumpList(WidgetTester tester, ScrollController controller) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: MessageActionBarScope(
            child: SizedBox(
              height: 300,
              child: ListView.builder(
                controller: controller,
                itemCount: 40,
                itemBuilder: (_, i) => MessageHoverWrapper(
                  key: ValueKey(i),
                  isMe: false,
                  messageId: 'm-$i',
                  currentText: 'message $i',
                  onReply: () {},
                  child: SizedBox(height: 40, child: Text('message $i')),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Color? _paintedBehind(WidgetTester tester, String text) {
  final box = tester.widget<DecoratedBox>(find
      .ancestor(of: find.text(text), matching: find.byType(DecoratedBox))
      .first);
  return (box.decoration as BoxDecoration).color;
}

void main() {
  testWidgets('hover highlights the row in place and the bar rides its edge',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pumpList(tester, controller);

    final before = tester.getRect(find.text('message 3'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('message 3')));
    await tester.pump();

    final hollow = HollowTheme.of(tester.element(find.text('message 3')));
    expect(_paintedBehind(tester, 'message 3'), hollow.rowHover);
    expect(_paintedBehind(tester, 'message 2'), isNull);
    expect(tester.getRect(find.text('message 3')), before,
        reason: 'the highlight must not move the layout');

    final bar = find.byType(CompositedTransformFollower);
    expect(bar, findsOneWidget);
    Rect barRect() => tester.getRect(find.descendant(
        of: bar, matching: find.bySemanticsLabel('Reply')).first);
    Rect rowRect(String t) => tester.getRect(find
        .ancestor(of: find.text(t), matching: find.byType(MessageHoverWrapper))
        .first);
    expect(
        (barRect().center.dy - rowRect('message 3').top).abs(), lessThan(16),
        reason: 'the bar straddles the hovered row\'s top edge');

    // Scroll under a still pointer: the bar follows whichever row is under
    // it now, never staying at the old screen position.
    controller.jumpTo(60);
    await tester.pump();
    await tester.pump();
    final hovered = List.generate(40, (i) => 'message $i').firstWhere((t) =>
        find.text(t).evaluate().isNotEmpty &&
        _paintedBehind(tester, t) == hollow.rowHover);
    expect(
        (barRect().center.dy - rowRect(hovered).top).abs(), lessThan(16));
  });
}
