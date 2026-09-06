import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'hotkey_backend.dart';
import 'hotkey_binding.dart';

typedef _XOpenDisplayC = Pointer<Void> Function(Pointer<Utf8>);
typedef _XOpenDisplayDart = Pointer<Void> Function(Pointer<Utf8>);
typedef _XQueryKeymapC = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _XQueryKeymapDart = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _XKeysymToKeycodeC = Uint8 Function(Pointer<Void>, UnsignedLong);
typedef _XKeysymToKeycodeDart = int Function(Pointer<Void>, int);

/// System-wide hotkeys on Linux X11 via an XQueryKeymap poll, 25ms and only
/// while in a call, on a PRIVATE Display connection rather than GTK's. Never
/// created under a Wayland session: XWayland only sees keys while X11 apps
/// have focus, so Wayland uses the GlobalShortcuts portal backend instead,
/// falling back to the in-app one on compositors without the portal.
class X11KeyPoller implements HotkeyBackend {
  // X11 keysyms for modifiers.
  static const _xkShiftL = 0xFFE1, _xkShiftR = 0xFFE2;
  static const _xkControlL = 0xFFE3, _xkControlR = 0xFFE4;
  static const _xkAltL = 0xFFE9, _xkAltR = 0xFFEA;

  final Pointer<Void> _display;
  final _XQueryKeymapDart _queryKeymap;
  final _XKeysymToKeycodeDart _keysymToKeycode;
  final Pointer<Uint8> _keymap = calloc<Uint8>(32);

  Timer? _timer;
  Map<HotkeyAction, HotkeyBinding> _bindings = const {};
  final Map<HotkeyAction, int> _triggerKeycodes = {};
  HotkeyEdgeCallback? _onEdge;
  bool Function() _isTextEditing = () => false;
  final Map<HotkeyAction, bool> _pressed = {};
  late final List<int> _ctrlCodes, _shiftCodes, _altCodes;

  X11KeyPoller._(this._display, this._queryKeymap, this._keysymToKeycode) {
    _ctrlCodes = _codes([_xkControlL, _xkControlR]);
    _shiftCodes = _codes([_xkShiftL, _xkShiftR]);
    _altCodes = _codes([_xkAltL, _xkAltR]);
  }

  List<int> _codes(List<int> keysyms) => [
        for (final ks in keysyms)
          if (_keysymToKeycode(_display, ks) != 0)
            _keysymToKeycode(_display, ks),
      ];

  /// Null when not an X11 session or libX11/display is unavailable —
  /// the controller falls back to the in-app backend.
  static X11KeyPoller? tryCreate() {
    if (!Platform.isLinux) return null;
    final env = Platform.environment;
    final isX11 = env['XDG_SESSION_TYPE'] == 'x11' ||
        (env['WAYLAND_DISPLAY'] == null && env['DISPLAY'] != null);
    if (!isX11) return null;
    try {
      final lib = DynamicLibrary.open('libX11.so.6');
      final open = lib
          .lookupFunction<_XOpenDisplayC, _XOpenDisplayDart>('XOpenDisplay');
      final display = open(nullptr); // null name → $DISPLAY
      if (display == nullptr) return null;
      final query = lib.lookupFunction<_XQueryKeymapC, _XQueryKeymapDart>(
          'XQueryKeymap');
      final toCode =
          lib.lookupFunction<_XKeysymToKeycodeC, _XKeysymToKeycodeDart>(
              'XKeysymToKeycode');
      return X11KeyPoller._(display, query, toCode);
    } catch (_) {
      return null;
    }
  }

  @override
  bool get isSystemWide => true;

  @override
  bool canHandle(HotkeyBinding binding) => binding.x11Keysym != null;

  bool _keycodeDown(int kc) =>
      (_keymap[kc >> 3] & (1 << (kc & 7))) != 0;

  bool _anyDown(List<int> codes) => codes.any(_keycodeDown);

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
    _triggerKeycodes.clear();
    for (final entry in _bindings.entries) {
      final ks = entry.value.x11Keysym;
      if (ks == null) continue;
      final kc = _keysymToKeycode(_display, ks);
      if (kc != 0) _triggerKeycodes[entry.key] = kc;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 25), (_) => _tick());
  }

  void _tick() {
    _queryKeymap(_display, _keymap);
    final ctrl = _anyDown(_ctrlCodes);
    final shift = _anyDown(_shiftCodes);
    final alt = _anyDown(_altCodes);
    final textEditing = _isTextEditing();

    for (final entry in _bindings.entries) {
      final action = entry.key;
      final binding = entry.value;
      final kc = _triggerKeycodes[action];
      if (kc == null) continue; // unmapped — in-app backend owns it

      final was = _pressed[action] ?? false;
      bool pressed;
      if (was) {
        // Held actions release on the TRIGGER key alone: mid-hold modifier
        // changes must not chop a PTT transmission, mirroring the in-app
        // backend and the Win32 poller.
        pressed = _keycodeDown(kc);
      } else {
        pressed = _keycodeDown(kc) &&
            ctrl == binding.ctrl &&
            shift == binding.shift &&
            (binding.ctrl && !binding.alt ? !alt : alt == binding.alt);
        if (binding.isBare && textEditing) pressed = false;
      }

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
