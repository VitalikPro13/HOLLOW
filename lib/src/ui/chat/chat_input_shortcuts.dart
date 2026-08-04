import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:super_clipboard/super_clipboard.dart';

/// Handles keyboard shortcuts for the chat input field.
///
/// Structural (fixed): Enter → send, Shift+Enter → newline, Ctrl+V → paste
/// image from clipboard (if any), else default text paste.
///
/// Formatting (rebindable, Settings > Shortcuts, defaults in parentheses):
/// bold **…** (Ctrl+B), italic *…* (Ctrl+I), `code` (Ctrl+E),
/// ~~strikethrough~~ (Ctrl+Shift+X), ||spoiler|| (Ctrl+Shift+S).
/// [formatBindings] carries the live map (pass
/// `ref.read(appShortcutsProvider).valueOrNull`); null = defaults.
KeyEventResult handleChatInputKey(
  KeyEvent event,
  TextEditingController controller,
  FocusNode focusNode,
  VoidCallback onSend, {
  void Function(String path, String name)? onPasteImage,
  Map<AppShortcut, HotkeyBinding>? formatBindings,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }

  // AltGr registers as Ctrl+Alt on Windows — a held Alt means the user is
  // typing a layout character (e.g. AZERTY € = AltGr+E), not a shortcut.
  final isCtrl = HardwareKeyboard.instance.isControlPressed &&
      !HardwareKeyboard.instance.isAltPressed;
  final isShift = HardwareKeyboard.instance.isShiftPressed;

  // Enter to send, Shift+Enter for newline.
  if (event.logicalKey == LogicalKeyboardKey.enter && !isCtrl) {
    return _handleEnterKey(controller, onSend, isShift);
  }

  // Ctrl+V — check for clipboard image before letting default paste through.
  if (isCtrl && !isShift && event.logicalKey == LogicalKeyboardKey.keyV) {
    if (onPasteImage != null) {
      _tryPasteImage(onPasteImage);
    }
    // Always return ignored so default text paste still works
    // (if no image is found, the async handler does nothing).
    return KeyEventResult.ignored;
  }

  return _handleFormattingKey(
      event, controller, formatBindings ?? kAppShortcutDefaults);
}

/// Enter → send, Shift+Enter → newline.
KeyEventResult _handleEnterKey(
  TextEditingController controller,
  VoidCallback onSend,
  bool isShift,
) {
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

/// Markdown formatting shortcuts, matched against the live (rebindable)
/// bindings — `matchesEvent` enforces the full modifier state per binding,
/// including the AltGr guard.
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

/// Attempts to read an image from the system clipboard.
/// If found, saves it to a temp file and calls [onPasteImage].
Future<void> _tryPasteImage(
  void Function(String path, String name) onPasteImage,
) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return;

  final reader = await clipboard.read();

  // Check for image formats in priority order.
  for (final format in [Formats.png, Formats.jpeg, Formats.gif, Formats.bmp, Formats.webp]) {
    if (!reader.canProvide(format)) continue;
    if (await _pasteImageForFormat(reader, format, onPasteImage)) return;
  }
}

/// Reads clipboard bytes for [format]; if present, saves them to a temp file
/// and calls [onPasteImage]. Returns true when an image was pasted.
Future<bool> _pasteImageForFormat(
  ClipboardReader reader,
  SimpleFileFormat format,
  void Function(String path, String name) onPasteImage,
) async {
  final bytes = await _readClipboardImageBytes(reader, format);
  if (bytes == null || bytes.isEmpty) return false;

  // Determine extension from format.
  final ext = _extensionForFormat(format);

  // Save to temp file.
  final tempDir = Directory.systemTemp;
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final fileName = 'clipboard_$timestamp.$ext';
  final tempFile = File('${tempDir.path}${Platform.pathSeparator}$fileName');
  await tempFile.writeAsBytes(bytes);

  onPasteImage(tempFile.path, fileName);
  return true;
}

Future<Uint8List?> _readClipboardImageBytes(
  ClipboardReader reader,
  SimpleFileFormat format,
) {
  final completer = Completer<Uint8List?>();
  reader.getFile(format, (file) async {
    final bytes = await file.readAll();
    completer.complete(bytes);
  }, onError: (_) {
    if (!completer.isCompleted) completer.complete(null);
  });
  return completer.future;
}

String _extensionForFormat(SimpleFileFormat format) {
  return format == Formats.png
      ? 'png'
      : format == Formats.jpeg
          ? 'jpg'
          : format == Formats.gif
              ? 'gif'
              : format == Formats.bmp
                  ? 'bmp'
                  : 'webp';
}

/// Copies image bytes to system clipboard.
Future<bool> copyImageToClipboard(String filePath) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false;

  final file = File(filePath);
  if (!file.existsSync()) return false;

  final bytes = await file.readAsBytes();
  final ext = filePath.split('.').last.toLowerCase();

  // Pick the right format based on extension.
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
