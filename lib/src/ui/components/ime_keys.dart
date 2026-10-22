import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The main Enter or the numpad's. One the composer leaves unhandled reaches
/// the text input client, which breaks the line in a multiline field.
bool isEnterKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;

/// The desktops whose engine shows a key to the framework BEFORE the IME.
/// Windows is not one: the IME's keys arrive as VK_PROCESSKEY and never reach
/// the framework, so an Enter it does see over a composing range is a stale
/// range (a commit the engine has not reported yet), and must still send.
bool get _imeSeesKeysLate => switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.linux => true,
      _ => false,
    };

/// Whether [event] is the input method's to handle: the field holds marked
/// text (a Japanese or Chinese composition) on macOS or Linux, and the key is
/// one an IME uses on it, so a handler that took this Enter would send the
/// half-composed text. Phones are left out: Gboard keeps a composing range
/// over the word being typed, so the rule would block every send there.
/// [withTab] adds Tab, which the macOS Japanese IME uses for its predictions,
/// for a suggestion overlay whose own Tab would otherwise win.
bool keyBelongsToIme(KeyEvent event, TextEditingValue value,
    {bool withTab = false}) {
  if (!_imeSeesKeysLate) return false;
  final composing = value.composing;
  if (!composing.isValid || composing.isCollapsed) return false;
  final key = event.logicalKey;
  return isEnterKey(key) ||
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      (withTab && key == LogicalKeyboardKey.tab);
}

/// The input action of a macOS or Linux field whose Enter sends or saves. An
/// Enter the IME hands back after committing (a Korean syllable, a Vietnamese
/// word, a dismissed inline prediction) then reaches [runPlatformEnter]
/// through `onEditingComplete` instead of breaking the line. Windows and
/// phones keep their newline key.
TextInputAction? get enterSubmitsAction =>
    _imeSeesKeysLate ? TextInputAction.send : null;

/// Runs a field's own key handling for an Enter the platform passed back.
/// A composition still open here was committed by the engine without telling
/// the framework (macOS `insertNewline:`), so the text stays as shown and the
/// range closes, but nothing is sent: the next Enter sends what the person
/// sees, never a guess at what they meant.
void runPlatformEnter(
  TextEditingController controller,
  KeyEventResult Function(KeyEvent event) onKey,
) {
  final composing = controller.value.composing;
  if (composing.isValid && !composing.isCollapsed) {
    controller.clearComposing();
    return;
  }
  onKey(const KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.enter,
    logicalKey: LogicalKeyboardKey.enter,
    timeStamp: Duration.zero,
    synthesized: true,
  ));
}

/// [keyBelongsToIme] for whatever text field holds focus, for a handler
/// above the field that cannot see its controller (a place's Escape).
bool keyBelongsToFocusedIme(KeyEvent event) {
  final field = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  return field != null && keyBelongsToIme(event, field.textEditingValue);
}
