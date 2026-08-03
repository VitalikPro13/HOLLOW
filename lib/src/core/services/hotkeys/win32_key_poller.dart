import 'dart:async';
import 'dart:ffi';

import 'hotkey_backend.dart';
import 'hotkey_binding.dart';

/// System-wide hotkeys on Windows via a GetAsyncKeyState poll (25ms, only
/// while in a call). Deliberately NOT RegisterHotKey: that CONSUMES the
/// combo system-wide, which would make a PTT key dead inside games. Polling
/// observes without stealing.
class Win32KeyPoller implements HotkeyBackend {
  static const _vkControl = 0x11;
  static const _vkShift = 0x10;
  static const _vkMenu = 0x12; // Alt

  final int Function(int) _getAsyncKeyState;
  Timer? _timer;
  Map<HotkeyAction, HotkeyBinding> _bindings = const {};
  HotkeyEdgeCallback? _onEdge;
  bool Function() _isTextEditing = () => false;
  final Map<HotkeyAction, bool> _pressed = {};

  Win32KeyPoller._(this._getAsyncKeyState);

  /// Returns null if user32 can't be loaded (never expected on Windows).
  static Win32KeyPoller? tryCreate() {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final fn = user32.lookupFunction<Int16 Function(Int32),
          int Function(int)>('GetAsyncKeyState');
      return Win32KeyPoller._(fn);
    } catch (_) {
      return null;
    }
  }

  @override
  bool get isSystemWide => true;

  bool _down(int vk) => (_getAsyncKeyState(vk) & 0x8000) != 0;

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
    _timer = Timer.periodic(const Duration(milliseconds: 25), (_) => _tick());
  }

  void _tick() {
    final ctrl = _down(_vkControl);
    final shift = _down(_vkShift);
    final alt = _down(_vkMenu);
    final textEditing = _isTextEditing();

    for (final entry in _bindings.entries) {
      final action = entry.key;
      final binding = entry.value;
      final vk = binding.windowsVk;
      if (vk == null) continue; // unmapped — in-app backend owns it

      bool pressed = _down(vk) &&
          ctrl == binding.ctrl &&
          shift == binding.shift &&
          // AltGr guard: a ctrl-binding without alt must see alt UP.
          (binding.ctrl && !binding.alt ? !alt : alt == binding.alt);
      // Bare keys are what you type with — never fire them mid-typing.
      if (binding.isBare && textEditing) pressed = false;

      final was = _pressed[action] ?? false;
      if (pressed != was) {
        _pressed[action] = pressed;
        _onEdge?.call(action, pressed);
      }
    }
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
    _pressed.clear();
    _onEdge = null;
  }
}
