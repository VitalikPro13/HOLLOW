import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Handles keyboard shortcuts for the chat input field.
///
/// - Enter → send message
/// - Shift+Enter → insert newline
/// - Ctrl+B → wrap selection in **bold**
/// - Ctrl+I → wrap selection in *italic*
/// - Ctrl+Shift+X → wrap selection in ~~strikethrough~~
/// - Ctrl+E → wrap selection in `code`
/// - Ctrl+Shift+S → wrap selection in ||spoiler||
KeyEventResult handleChatInputKey(
  KeyEvent event,
  TextEditingController controller,
  FocusNode focusNode,
  VoidCallback onSend,
) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }

  final isCtrl = HardwareKeyboard.instance.isControlPressed;
  final isShift = HardwareKeyboard.instance.isShiftPressed;

  // Enter to send, Shift+Enter for newline.
  if (event.logicalKey == LogicalKeyboardKey.enter && !isCtrl) {
    if (isShift) {
      // Insert newline at cursor position.
      final sel = controller.selection;
      final text = controller.text;
      final newText =
          text.replaceRange(sel.start, sel.end, '\n');
      controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + 1),
      );
      return KeyEventResult.handled;
    }
    // Plain Enter → send.
    onSend();
    return KeyEventResult.handled;
  }

  // Formatting shortcuts (Ctrl required).
  if (!isCtrl) return KeyEventResult.ignored;

  if (event.logicalKey == LogicalKeyboardKey.keyB && !isShift) {
    _wrapSelection(controller, '**', '**');
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.keyI && !isShift) {
    _wrapSelection(controller, '*', '*');
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.keyE && !isShift) {
    _wrapSelection(controller, '`', '`');
    return KeyEventResult.handled;
  }
  // Ctrl+Shift+X for strikethrough.
  if (event.logicalKey == LogicalKeyboardKey.keyX && isShift) {
    _wrapSelection(controller, '~~', '~~');
    return KeyEventResult.handled;
  }
  // Ctrl+Shift+S for spoiler.
  if (event.logicalKey == LogicalKeyboardKey.keyS && isShift) {
    _wrapSelection(controller, '||', '||');
    return KeyEventResult.handled;
  }

  return KeyEventResult.ignored;
}

/// Wraps the current selection with [before] and [after] markers.
/// If no text is selected, inserts the markers and places cursor in between.
void _wrapSelection(
  TextEditingController controller,
  String before,
  String after,
) {
  final sel = controller.selection;
  final text = controller.text;

  if (sel.start == sel.end) {
    // No selection — insert markers and place cursor between them.
    final newText = text.replaceRange(sel.start, sel.end, '$before$after');
    controller.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: sel.start + before.length),
    );
  } else {
    // Wrap selected text.
    final selected = text.substring(sel.start, sel.end);
    final newText =
        text.replaceRange(sel.start, sel.end, '$before$selected$after');
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: sel.start + before.length,
        extentOffset: sel.start + before.length + selected.length,
      ),
    );
  }
}
