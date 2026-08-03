import 'package:flutter/services.dart';

import 'hotkey_backend.dart';
import 'hotkey_binding.dart';

/// Window-focused hotkeys via HardwareKeyboard — the only backend on macOS
/// and Wayland (no sanctioned global observation there yet), and the
/// fallback when a poller can't map a binding or failed to initialize.
/// Handles KeyUp too (PTT needs the release edge); KeyRepeat is ignored.
class InAppKeyBackend implements HotkeyBackend {
  Map<HotkeyAction, HotkeyBinding> _bindings = const {};
  HotkeyEdgeCallback? _onEdge;
  bool Function() _isTextEditing = () => false;
  final Map<HotkeyAction, bool> _pressed = {};
  bool _registered = false;

  @override
  bool get isSystemWide => false;

  @override
  void start(
    Map<HotkeyAction, HotkeyBinding> bindings,
    HotkeyEdgeCallback onEdge,
    bool Function() isTextEditing,
  ) {
    stop();
    _bindings = Map.of(bindings);
    _onEdge = onEdge;
    _isTextEditing = isTextEditing;
    HardwareKeyboard.instance.addHandler(_handleKey);
    _registered = true;
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyRepeatEvent) return false;
    final hk = HardwareKeyboard.instance;
    var consumed = false;

    for (final entry in _bindings.entries) {
      final action = entry.key;
      final binding = entry.value;

      if (event is KeyDownEvent) {
        if (!binding.matchesEvent(event, hk)) continue;
        // Bare keys are what you type with — let the composer have them.
        if (binding.isBare && _isTextEditing()) continue;
        if (_pressed[action] != true) {
          _pressed[action] = true;
          _onEdge?.call(action, true);
        }
        consumed = true;
      } else if (event is KeyUpEvent) {
        // Release matches on the TRIGGER key alone — modifiers may have
        // been released first and must not orphan a held action.
        if (event.logicalKey != binding.trigger) continue;
        if (_pressed[action] == true) {
          _pressed[action] = false;
          _onEdge?.call(action, false);
        }
        // Never consume key-up: other listeners track their own state.
      }
    }
    return consumed;
  }

  /// The window lost focus — KeyUp will never arrive for held keys, so
  /// force-release every pressed action (the controller wires this to the
  /// window-focus provider).
  void releaseAll() {
    for (final entry in _pressed.entries) {
      if (entry.value) _onEdge?.call(entry.key, false);
    }
    _pressed.clear();
  }

  @override
  void stop() {
    if (_registered) {
      HardwareKeyboard.instance.removeHandler(_handleKey);
      _registered = false;
    }
    _pressed.clear();
    _onEdge = null;
  }
}
