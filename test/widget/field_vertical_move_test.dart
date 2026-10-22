import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';

import '../helpers/test_app.dart';

/// The field-level vertical-move override must not change
/// any field outside a SelectionArea, nor steal arrows from a focusable
/// widget that sits inside the field's decoration.
void main() {
  Future<(TextEditingController, FocusNode, FocusNode, FocusNode)> pump(
      WidgetTester tester,
      {bool inSelectionArea = false}) async {
    final c = TextEditingController();
    final f = FocusNode();
    final above = FocusNode(debugLabel: 'above');
    final trailing = FocusNode(debugLabel: 'trailing');
    addTearDown(c.dispose);
    addTearDown(f.dispose);
    addTearDown(above.dispose);
    addTearDown(trailing.dispose);
    Widget field = HollowTextField(
      controller: c,
      focusNode: f,
      maxLines: 5,
      minLines: 1,
      trailing: Focus(
          focusNode: trailing,
          child: const SizedBox(width: 20, height: 20)),
    );
    if (inSelectionArea) field = chatSelectionArea(child: field);
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Column(children: [
            Focus(
                focusNode: above,
                child: const SizedBox(width: 300, height: 60)),
            SizedBox(width: 300, child: field),
          ]),
        ),
      ),
    ));
    await tester.pump();
    return (c, f, above, trailing);
  }

  for (final inArea in [false, true]) {
    testWidgets('Up, Down, Shift+Down move and extend in a multi-line field '
        '(selection area: $inArea)', (tester) async {
      final (c, f, _, _) = await pump(tester, inSelectionArea: inArea);
      await tester.showKeyboard(find.byType(EditableText));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'first\nsecond\nthird',
        selection: TextSelection.collapsed(offset: 2),
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(c.selection.baseOffset, inInclusiveRange(6, 12));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(c.selection.baseOffset, lessThan(6));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(c.selection.isCollapsed, isFalse);
      expect(f.hasFocus, isTrue);
    }, variant: TargetPlatformVariant.desktop());
  }

  testWidgets('Up on a focusable inside the field decoration still traverses',
      (tester) async {
    final (_, _, above, trailing) = await pump(tester);
    trailing.requestFocus();
    await tester.pump();
    expect(trailing.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(above.hasPrimaryFocus, isTrue);
  }, variant: TargetPlatformVariant.desktop());
}
