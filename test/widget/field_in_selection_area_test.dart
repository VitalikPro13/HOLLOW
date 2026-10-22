import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';

import '../helpers/test_app.dart';

/// The message edit box sits inside its row's SelectionArea. Up or Down in it
/// reached SelectableRegion's override of the vertical caret move, which
/// casts the field's own action to the wrong intent type and throws on every
/// press (macOS through the engine's moveUp:/moveDown: selectors, the other
/// desktops through the text shortcuts), so the caret never moved.
void main() {
  for (final key in [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown]) {
    testWidgets('$key moves the caret in the edit box without throwing',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: MessageActionBarScope(
              child: chatSelectionArea(
                child: MessageHoverWrapper(
                  isMe: true,
                  messageId: 'm-1',
                  currentText: 'old words',
                  isEditing: true,
                  onEditSubmit: (_) {},
                  onEditCancel: () {},
                  child: const Text('old words'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'first\nsecond',
        selection: TextSelection.collapsed(offset: 2),
      ));
      await tester.pump();
      if (key == LogicalKeyboardKey.arrowUp) {
        tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: 'first\nsecond',
          selection: TextSelection.collapsed(offset: 8),
        ));
        await tester.pump();
      }
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      final offset = field.controller.selection.baseOffset;
      expect(offset, key == LogicalKeyboardKey.arrowDown ? greaterThan(5) : lessThan(6),
          reason: 'the caret moved to the other line');
    }, variant: TargetPlatformVariant.desktop());
  }
}
