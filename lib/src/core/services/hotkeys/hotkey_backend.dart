import 'hotkey_binding.dart';

/// Edge callback: [pressed] true on key-down transition, false on release.
typedef HotkeyEdgeCallback = void Function(HotkeyAction action, bool pressed);

/// A hotkey backend observes the configured bindings and reports EDGES only
/// (per-action pressed-state transitions). Exactly ONE backend instance is
/// live at a time — poller platforms never also register the in-app handler,
/// so a binding can't double-fire (pollers see keys while focused too).
abstract class HotkeyBackend {
  /// Start observing. [isTextEditing] gates BARE bindings (no modifiers):
  /// while it returns true they are treated as released — plain Space must
  /// stay typable in Hollow's own composer. Poller backends consult it only
  /// while the window has focus (an unfocused window can't be typing).
  void start(
    Map<HotkeyAction, HotkeyBinding> bindings,
    HotkeyEdgeCallback onEdge,
    bool Function() isTextEditing,
  );

  /// Stop observing and release any held state (no release edges fire —
  /// the controller resets its own action state alongside).
  void stop();

  /// Whether this backend sees keys while the window is unfocused.
  bool get isSystemWide;
}
