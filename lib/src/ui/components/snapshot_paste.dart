import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/services/win32_clipboard.dart';

/// Reads the clipboard, trying the open the given number of times; null
/// where there is no synchronous read and the engine's paste runs instead.
/// Swapped out only by tests.
@visibleForTesting
ClipboardSnapshot? Function(int attempts)? pasteSnapshotReader =
    Platform.isWindows ? readWin32ClipboardSnapshot : null;

/// Tries during the key event, 5 ms apart: most holders let go within a few
/// ms, and a longer block would stall the UI thread.
const int _keyEventAttempts = 3;

/// A holder that keeps the clipboard longer also keeps a dictation app from
/// putting its old content back, so the text is usually still there; the
/// dictation app waits for the same release, so the first to ask wins.
const int _laterTicks = 500;
const Duration _laterTick = Duration(milliseconds: 2);

/// Pastes from a clipboard read taken now, during the key event, or as soon
/// as another program lets go of the clipboard (#101): a dictation app puts
/// its text there, presses Ctrl+V and restores the clipboard a moment later.
/// False when this platform has no such read and the engine's paste should
/// run. [onImage] hears of an image on offer; the text still lands.
bool pasteFromClipboard(
  EditableTextState state,
  SelectionChangedCause cause, {
  VoidCallback? onImage,
}) {
  final read = pasteSnapshotReader;
  if (read == null) return false;
  final snapshot = read(_keyEventAttempts);
  if (snapshot != null) {
    _apply(state, snapshot, cause, onImage);
  } else {
    unawaited(_pasteWhenFree(state, cause, onImage, read));
  }
  return true;
}

Future<void> _pasteWhenFree(
  EditableTextState state,
  SelectionChangedCause cause,
  VoidCallback? onImage,
  ClipboardSnapshot? Function(int attempts) read,
) async {
  for (var tick = 0; tick < _laterTicks; tick++) {
    await Future<void>.delayed(_laterTick);
    if (!state.mounted) return;
    final snapshot = read(1);
    if (snapshot != null) {
      _apply(state, snapshot, cause, onImage);
      return;
    }
  }
}

void _apply(
  EditableTextState state,
  ClipboardSnapshot snapshot,
  SelectionChangedCause cause,
  VoidCallback? onImage,
) {
  if (snapshot.hasImage) onImage?.call();
  final text = snapshot.text;
  if (text != null && text.isNotEmpty) pasteIntoEditable(state, text, cause);
}

/// Inserts [text] the way the framework's own paste does: replaces the
/// selection, leaves the caret after it, and runs the field's formatters
/// (length limits included).
void pasteIntoEditable(
  EditableTextState state,
  String text,
  SelectionChangedCause cause,
) {
  if (state.widget.readOnly || !state.widget.selectionEnabled) return;
  final value = state.textEditingValue;
  final selection = value.selection;
  if (!selection.isValid) return;
  final end = math.max(selection.baseOffset, selection.extentOffset);
  state.userUpdateTextEditingValue(
    value
        .copyWith(selection: TextSelection.collapsed(offset: end))
        .replaced(selection, text),
    cause,
  );
}

/// Ctrl+V and Shift+Insert in every text field.
class SnapshotPasteTextAction extends ContextAction<PasteTextIntent> {
  @override
  Object? invoke(PasteTextIntent intent, [BuildContext? context]) {
    final state = context?.findAncestorStateOfType<EditableTextState>();
    if (state != null && pasteFromClipboard(state, intent.cause)) return null;
    final fallback = callingAction;
    return fallback is ContextAction<PasteTextIntent>
        ? fallback.invoke(intent, context)
        : fallback?.invoke(intent);
  }
}

/// The app's root actions: the defaults plus the snapshot paste, which every
/// [EditableText] picks up because its paste action is overridable.
Map<Type, Action<Intent>> hollowAppActions() => {
      ...WidgetsApp.defaultActions,
      PasteTextIntent: SnapshotPasteTextAction(),
    };
