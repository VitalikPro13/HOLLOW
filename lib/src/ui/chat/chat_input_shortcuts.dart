import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/ui/components/snapshot_paste.dart';

/// Handles keyboard shortcuts for the chat input field.
///
/// Send, newline and image paste are fixed; the formatting shortcuts are
/// rebindable and [formatBindings] carries the live map, null meaning the
/// defaults. [onEditLast] opens the edit of the newest message we can edit
/// and says whether there was one (#103).
KeyEventResult handleChatInputKey(
  KeyEvent event,
  TextEditingController controller,
  FocusNode focusNode,
  VoidCallback onSend, {
  void Function(String path, String name)? onPasteImage,
  Map<AppShortcut, HotkeyBinding>? formatBindings,
  bool Function()? onEditLast,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }

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

  if (isCtrl && !isShift && event.logicalKey == LogicalKeyboardKey.keyV) {
    return _handlePasteKey(focusNode, onPasteImage);
  }

  return _handleFormattingKey(
      event, controller, formatBindings ?? kAppShortcutDefaults);
}

/// The main Enter or the numpad's. One the composer leaves unhandled reaches
/// the text input client, which breaks the line in a multiline field.
bool isEnterKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;

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

/// Text and image come from ONE clipboard read (#101): an image read started
/// on a text-only clipboard used to race the text read, and a dictation app
/// restores the clipboard right after its Ctrl+V.
KeyEventResult _handlePasteKey(
  FocusNode focusNode,
  void Function(String path, String name)? onPasteImage,
) {
  final state =
      focusNode.context?.findAncestorStateOfType<EditableTextState>();
  final onImage =
      onPasteImage == null ? null : () => _tryPasteImage(onPasteImage);
  if (state != null &&
      pasteFromClipboard(state, SelectionChangedCause.keyboard,
          onImage: onImage)) {
    return KeyEventResult.handled;
  }
  onImage?.call();
  // Ignored, so the engine's text paste still runs when the async image read
  // finds nothing.
  return KeyEventResult.ignored;
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

  // The data root's temp, never the OS one: emptied at every launch and by a
  // wipe, where a copy in the shared temp dir outlived both.
  final sep = Platform.pathSeparator;
  final tempDir = Directory('$hollowDataDir${sep}temp');
  await tempDir.create(recursive: true);
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final fileName = 'clipboard_$timestamp.$ext';
  final tempFile = File('${tempDir.path}$sep$fileName');
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
