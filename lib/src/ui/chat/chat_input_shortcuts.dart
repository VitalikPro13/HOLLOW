import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/ui/chat/clipboard_paste.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/ime_keys.dart';
import 'package:hollow/src/ui/components/snapshot_paste.dart';

export 'package:hollow/src/ui/chat/clipboard_paste.dart' show PastedFile;
export 'package:hollow/src/ui/components/ime_keys.dart';

/// Handles keyboard shortcuts for the chat input field.
///
/// Send, newline and paste are fixed; the formatting shortcuts are
/// rebindable and [formatBindings] carries the live map, null meaning the
/// defaults. [onEditLast] opens the edit of the newest message we can edit
/// and says whether there was one (#103).
KeyEventResult handleChatInputKey(
  KeyEvent event,
  TextEditingController controller,
  FocusNode focusNode,
  VoidCallback onSend, {
  void Function(List<PastedFile> files)? onPasteFiles,
  Map<AppShortcut, HotkeyBinding>? formatBindings,
  bool Function()? onEditLast,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (keyBelongsToIme(event, controller.value)) return KeyEventResult.ignored;

  if (onEditLast != null && _isEditLastKey(event, controller)) {
    return onEditLast() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // AltGr registers as Ctrl+Alt on Windows, so a held Alt means a layout
  // character (AZERTY € is AltGr+E), not a shortcut.
  final isCtrl = HardwareKeyboard.instance.isControlPressed &&
      !HardwareKeyboard.instance.isAltPressed;
  final isShift = HardwareKeyboard.instance.isShiftPressed;

  if (isEnterKey(event.logicalKey) && !isCtrl) {
    return _handleEnterKey(controller, onSend, isShift);
  }

  if (isPasteChord(event)) return _handlePasteKey(focusNode, onPasteFiles);

  final formatted = _handleFormattingKey(
      event, controller, formatBindings ?? kAppShortcutDefaults);
  // Where the field's own Enter action sends (enterSubmitsAction), the line
  // break Ctrl+Enter used to get from the engine is made here.
  if (formatted == KeyEventResult.ignored &&
      isEnterKey(event.logicalKey) &&
      enterSubmitsAction != null) {
    return _handleEnterKey(controller, onSend, true);
  }
  return formatted;
}

/// A bare Up press in an empty composer, as in Discord and Slack. A draft,
/// even a space, keeps Up for the caret; a held key opens the edit once.
bool _isEditLastKey(KeyEvent event, TextEditingController controller) {
  if (event is! KeyDownEvent ||
      event.logicalKey != LogicalKeyboardKey.arrowUp ||
      controller.text.isNotEmpty) {
    return false;
  }
  final hk = HardwareKeyboard.instance;
  return !hk.isShiftPressed &&
      !hk.isControlPressed &&
      !hk.isAltPressed &&
      !hk.isMetaPressed;
}

/// The edit action of the newest row in [chronological] that [startFor]
/// offers one for, or null when none can be edited. [startFor] receives the
/// row's REVERSED index, the space the chat list scrolls in.
VoidCallback? editNewestAction<T>(
  List<T> chronological,
  VoidCallback? Function(T row, int revIndex) startFor,
) {
  for (var i = chronological.length - 1; i >= 0; i--) {
    final start = startFor(chronological[i], chronological.length - 1 - i);
    if (start != null) return start;
  }
  return null;
}

/// Paste: Cmd+V on a Mac or an iPad, Ctrl+V elsewhere. AltGr is Ctrl+Alt on
/// Windows, so a held Alt is a layout character, never a paste.
bool isPasteChord(KeyEvent event) {
  if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
  final hk = HardwareKeyboard.instance;
  if (hk.isShiftPressed || hk.isAltPressed) return false;
  final apple = defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  return apple
      ? hk.isMetaPressed && !hk.isControlPressed
      : hk.isControlPressed && !hk.isMetaPressed;
}

/// Text, files and image come from ONE clipboard read (#101, #142). On
/// Windows the read happens during the key event (a dictation app restores
/// the clipboard right after its Ctrl+V). Elsewhere the key is taken and one
/// read decides: copied files are the whole paste (Finder puts the file name
/// and Nautilus the path in the text beside them), else an image and the
/// text, else the text alone.
KeyEventResult _handlePasteKey(
  FocusNode focusNode,
  void Function(List<PastedFile> files)? onPasteFiles,
) {
  final state =
      focusNode.context?.findAncestorStateOfType<EditableTextState>();
  if (onPasteFiles == null) {
    return state != null &&
            pasteFromClipboard(state, SelectionChangedCause.keyboard)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }
  void notice(String text) {
    final context = focusNode.context;
    if (context != null && context.mounted) {
      HollowToast.show(context, text, type: HollowToastType.info);
    }
  }

  void readFiles() => unawaited(
      pasteFromSystemClipboard(onFiles: onPasteFiles, onNotice: notice));
  if (state == null) {
    readFiles();
    return KeyEventResult.ignored;
  }
  if (pasteFromClipboard(state, SelectionChangedCause.keyboard,
      onImage: readFiles, onFiles: readFiles)) {
    return KeyEventResult.handled;
  }
  unawaited(pasteFromSystemClipboard(
    onFiles: onPasteFiles,
    onNotice: notice,
    onText: (text) {
      if (state.mounted) {
        pasteIntoEditable(state, text, SelectionChangedCause.keyboard);
      }
    },
  ));
  return KeyEventResult.handled;
}

KeyEventResult _handleEnterKey(
  TextEditingController controller,
  VoidCallback onSend,
  bool isShift,
) {
  if (isShift) {
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
  onSend();
  return KeyEventResult.handled;
}

/// Markdown formatting shortcuts against the live rebindable bindings;
/// `matchesEvent` enforces the full modifier state, AltGr guard included.
KeyEventResult _handleFormattingKey(
  KeyEvent event,
  TextEditingController controller,
  Map<AppShortcut, HotkeyBinding> binds,
) {
  const wrappers = {
    AppShortcut.formatBold: '**',
    AppShortcut.formatItalic: '*',
    AppShortcut.formatCode: '`',
    AppShortcut.formatStrikethrough: '~~',
    AppShortcut.formatSpoiler: '||',
  };
  final hk = HardwareKeyboard.instance;
  for (final entry in wrappers.entries) {
    if (binds[entry.key]!.matchesEvent(event, hk)) {
      _wrapSelection(controller, entry.value, entry.value);
      return KeyEventResult.handled;
    }
  }
  return KeyEventResult.ignored;
}

/// Whether this platform has a clipboard that takes image bytes at all, so a
/// surface can hide the control rather than offer one that always fails.
bool get canCopyImageToClipboard => SystemClipboard.instance != null;

/// Copies image bytes to the system clipboard.
Future<bool> copyImageToClipboard(String filePath) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false;

  if (!File(filePath).existsSync()) return false;

  final bytes = await AtRest.read(filePath);
  final ext = filePath.split('.').last.toLowerCase();

  final SimpleFileFormat format;
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      format = Formats.jpeg;
      break;
    case 'gif':
      format = Formats.gif;
      break;
    case 'bmp':
      format = Formats.bmp;
      break;
    case 'webp':
      format = Formats.webp;
      break;
    default:
      format = Formats.png;
  }

  final item = DataWriterItem();
  item.add(format(bytes));
  await clipboard.write([item]);
  return true;
}

/// Wraps the current selection with [before] and [after], or inserts both and
/// places the cursor between them when nothing is selected.
void _wrapSelection(
  TextEditingController controller,
  String before,
  String after,
) {
  final sel = controller.selection;
  final text = controller.text;

  if (sel.start == sel.end) {
    final newText = text.replaceRange(sel.start, sel.end, '$before$after');
    controller.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: sel.start + before.length),
    );
  } else {
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
