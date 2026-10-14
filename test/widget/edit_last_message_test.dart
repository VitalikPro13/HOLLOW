import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';

/// Issue #103: Up in an empty composer edits the newest message I sent.
void main() {
  group('Up arrow in the composer', () {
    late TextEditingController controller;
    late FocusNode focusNode;
    late int editLastCalls;
    late bool editLastResult;
    late KeyEventResult? lastResult;

    Future<void> pump(WidgetTester tester, {String text = ''}) async {
      controller = TextEditingController(text: text);
      focusNode = FocusNode();
      editLastCalls = 0;
      editLastResult = true;
      lastResult = null;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (node, event) {
              final r = handleChatInputKey(
                event,
                controller,
                focusNode,
                () {},
                onEditLast: () {
                  editLastCalls++;
                  return editLastResult;
                },
              );
              if (event is KeyDownEvent) lastResult = r;
              return r;
            },
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('an empty composer opens the edit', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(editLastCalls, 1);
      expect(lastResult, KeyEventResult.handled);
    });

    testWidgets('a composer with text keeps Up for the caret', (tester) async {
      await pump(tester, text: 'draft');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(editLastCalls, 0);
      expect(lastResult, KeyEventResult.ignored);
    });

    testWidgets('a whitespace-only draft is still a draft', (tester) async {
      await pump(tester, text: ' ');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(editLastCalls, 0);
    });

    for (final modifier in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      testWidgets('${modifier.keyLabel}+Up is not the edit shortcut',
          (tester) async {
        await pump(tester);
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyUpEvent(modifier);
        expect(editLastCalls, 0);
      });
    }

    testWidgets('nothing to edit leaves the key to the field', (tester) async {
      await pump(tester);
      editLastResult = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(editLastCalls, 1);
      expect(lastResult, KeyEventResult.ignored);
    });

    testWidgets('a held Up opens the edit once', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      expect(editLastCalls, 1);
    });

    testWidgets('Enter still sends with the edit shortcut wired',
        (tester) async {
      var sends = 0;
      controller = TextEditingController(text: 'hi');
      focusNode = FocusNode();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (node, event) => handleChatInputKey(
                event, controller, focusNode, () => sends++,
                onEditLast: () => true),
            child: TextField(
                controller: controller, focusNode: focusNode, autofocus: true),
          ),
        ),
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sends, 1);
    });
  });

  group('the newest message I can edit', () {
    // Chronological, oldest first; `mine` and `editable` model the pane's rule.
    final rows = [
      (id: 'a', mine: true, editable: true),
      (id: 'b', mine: false, editable: false),
      (id: 'c', mine: true, editable: true),
      (id: 'd', mine: true, editable: false), // a file
      (id: 'e', mine: false, editable: false),
    ];

    test('skips newer rows the edit flow refuses', () {
      final started = <(String, int)>[];
      final start = editNewestAction(
        rows,
        (r, revIndex) =>
            r.editable ? () => started.add((r.id, revIndex)) : null,
      );
      expect(start, isNotNull);
      start!();
      // 'c' is index 2 of 5, so reversed index 2.
      expect(started, [('c', 2)]);
    });

    test('nothing editable means no action', () {
      expect(editNewestAction(rows, (r, _) => null), isNull);
      expect(
          editNewestAction(
              const <({String id, bool mine, bool editable})>[],
              (r, _) => () {}),
          isNull);
    });

    test('the newest row wins when it is editable', () {
      final ids = <String>[];
      editNewestAction(
              [...rows, (id: 'f', mine: true, editable: true)],
              (r, rev) => r.editable ? () => ids.add('${r.id}@$rev') : null)!
          .call();
      expect(ids, ['f@0']);
    });
  });
}
