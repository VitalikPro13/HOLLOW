import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:super_clipboard/super_clipboard.dart';

/// Handles keyboard shortcuts for the chat input field.
///
/// Send, newline and image paste are fixed; the formatting shortcuts are
/// rebindable and [formatBindings] carries the live map, null meaning the
/// defaults.
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

  // AltGr registers as Ctrl+Alt on Windows, so a held Alt means a layout
  // character (AZERTY € is AltGr+E), not a shortcut.
  final isCtrl = HardwareKeyboard.instance.isControlPressed &&
      !HardwareKeyboard.instance.isAltPressed;
  final isShift = HardwareKeyboard.instance.isShiftPressed;

  if (event.logicalKey == LogicalKeyboardKey.enter && !isCtrl) {
    return _handleEnterKey(controller, onSend, isShift);
  }

  if (isCtrl && !isShift && event.logicalKey == LogicalKeyboardKey.keyV) {
    if (onPasteImage != null) {
      _tryPasteImage(onPasteImage);
    }
    // Ignored either way, so default text paste still works when the async
    // handler finds no image.
    return KeyEventResult.ignored;
  }

  return _handleFormattingKey(
      event, controller, formatBindings ?? kAppShortcutDefaults);
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

/// Reads an image from the system clipboard, saving it to a temp file and
/// calling [onPasteImage].
Future<void> _tryPasteImage(
  void Function(String path, String name) onPasteImage,
) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return;

  final reader = await clipboard.read();

  // Priority order.
  for (final format in [Formats.png, Formats.jpeg, Formats.gif, Formats.bmp, Formats.webp]) {
    if (!reader.canProvide(format)) continue;
    if (await _pasteImageForFormat(reader, format, onPasteImage)) return;
  }
}

/// Reads clipboard bytes for [format] into a temp file and calls
/// [onPasteImage]. True when an image was pasted.
Future<bool> _pasteImageForFormat(
  ClipboardReader reader,
  SimpleFileFormat format,
  void Function(String path, String name) onPasteImage,
) async {
  final bytes = await _readClipboardImageBytes(reader, format);
  if (bytes == null || bytes.isEmpty) return false;

  final ext = _extensionForFormat(format);

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

/// Copies image bytes to the system clipboard.
Future<bool> copyImageToClipboard(String filePath) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false;

  final file = File(filePath);
  if (!file.existsSync()) return false;

  final bytes = await file.readAsBytes();
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
