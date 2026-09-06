import 'hotkey_binding.dart';

/// Edge callback: [pressed] true on key-down transition, false on release.
typedef HotkeyEdgeCallback = void Function(HotkeyAction action, bool pressed);

/// A hotkey backend observes the configured bindings and reports EDGES only.
/// Exactly ONE instance is live at a time: poller platforms never also
/// register the in-app handler, or a binding would double-fire.
abstract class HotkeyBackend {
  /// Starts observing. [isTextEditing] gates BARE bindings (no modifiers) so
  /// plain Space stays typable in the composer; pollers consult it only while
  /// the window has focus, since an unfocused window cannot be typing.
  void start(
    Map<HotkeyAction, HotkeyBinding> bindings,
    HotkeyEdgeCallback onEdge,
    bool Function() isTextEditing,
  );

  /// Stops observing and releases held state. No release edges fire.
  void stop();

  /// Whether this backend sees keys while the window is unfocused.
  bool get isSystemWide;

  /// Whether this backend can observe [binding] at all (the Win32 poller
  /// needs a virtual-key mapping, X11 a keysym). What a system-wide backend
  /// cannot handle falls back to the in-app one: focused beats silently dead.
  bool canHandle(HotkeyBinding binding);
}
