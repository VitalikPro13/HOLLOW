import 'package:flutter/services.dart';

/// Hotkey-driven call actions (issue #38).
enum HotkeyAction { pushToTalk, toggleMute, toggleDeafen }

/// One keyboard binding: optional Ctrl/Shift/Alt modifiers + a trigger key.
/// Serialized as lowercase '+'-joined parts, e.g. 'ctrl+space',
/// 'ctrl+shift+m', 'f13', 'space'. Meta/Win is deliberately out of scope.
class HotkeyBinding {
  final bool ctrl;
  final bool shift;
  final bool alt;
  final LogicalKeyboardKey trigger;

  const HotkeyBinding({
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    required this.trigger,
  });

  /// A binding with no modifiers (e.g. plain Space). Bare bindings are
  /// suppressed while a Hollow text field has focus — they're what you type
  /// with.
  bool get isBare => !ctrl && !shift && !alt;

  /// Whether the trigger key produces a character when typed (letters,
  /// digits, space, punctuation). A BARE binding on a typable trigger is a
  /// foot-gun for always-on app shortcuts (typing "b" would trigger Bold) —
  /// the Shortcuts page refuses those; F-keys/Insert/Home/… stay allowed.
  bool get isTypableTrigger {
    final name = _nameOfKey(trigger);
    if (name == null) return false;
    if (name.length == 1) return true; // letters + digits
    const typable = {
      'space', 'grave', 'minus', 'equal', 'bracketleft', 'bracketright',
      'backslash', 'semicolon', 'quote', 'comma', 'period', 'slash',
    };
    return typable.contains(name);
  }

  static HotkeyBinding? parse(String s) {
    if (s.trim().isEmpty) return null;
    var ctrl = false, shift = false, alt = false;
    LogicalKeyboardKey? trigger;
    for (final raw in s.toLowerCase().split('+')) {
      final part = raw.trim();
      switch (part) {
        case 'ctrl':
        case 'control':
          ctrl = true;
        case 'shift':
          shift = true;
        case 'alt':
          alt = true;
        default:
          trigger = _keyFromName(part);
          if (trigger == null) return null;
      }
    }
    if (trigger == null) return null;
    return HotkeyBinding(ctrl: ctrl, shift: shift, alt: alt, trigger: trigger);
  }

  String serialize() {
    final parts = <String>[
      if (ctrl) 'ctrl',
      if (shift) 'shift',
      if (alt) 'alt',
      _nameOfKey(trigger) ?? '',
    ];
    return parts.where((p) => p.isNotEmpty).join('+');
  }

  /// Human-readable form for the settings UI, e.g. 'Ctrl + Shift + M'.
  String display() {
    final name = _nameOfKey(trigger) ?? '?';
    final pretty = name.length == 1
        ? name.toUpperCase()
        : name[0].toUpperCase() + name.substring(1);
    return [
      if (ctrl) 'Ctrl',
      if (shift) 'Shift',
      if (alt) 'Alt',
      pretty,
    ].join(' + ');
  }

  /// Whether [event]'s key matches the trigger with the modifier state of
  /// [hk].
  bool matchesEvent(KeyEvent event, HardwareKeyboard hk) =>
      event.logicalKey == trigger && modifiersMatch(hk);

  /// Whether the current modifier state of [hk] matches. AltGr guard
  /// (CLAUDE.md): a Ctrl-binding without Alt additionally requires Alt NOT
  /// pressed — AltGr reports as Ctrl+Alt on Windows, and swallowing it
  /// breaks @/€ on AZERTY layouts app-wide.
  bool modifiersMatch(HardwareKeyboard hk) {
    if (hk.isControlPressed != ctrl) return false;
    if (hk.isShiftPressed != shift) return false;
    if (ctrl && !alt && hk.isAltPressed) return false; // AltGr guard
    if (!ctrl && hk.isAltPressed != alt) return false;
    return true;
  }

  /// Windows virtual-key code for the trigger, or null if unmapped (the
  /// in-app backend then handles this binding even on poller platforms).
  int? get windowsVk => _winVk[trigger];

  /// X11 keysym for the trigger, or null if unmapped.
  int? get x11Keysym => _x11Keysym[trigger];

  /// xkbcommon keysym NAME for the trigger (freedesktop shortcuts spec,
  /// used as the GlobalShortcuts portal `preferred_trigger` hint), or null
  /// if unmapped — the hint is optional; the portal dialog lets the user
  /// pick a trigger either way.
  String? get xkbName => _xkbNames[trigger];

  @override
  bool operator ==(Object other) =>
      other is HotkeyBinding &&
      other.ctrl == ctrl &&
      other.shift == shift &&
      other.alt == alt &&
      other.trigger == trigger;

  @override
  int get hashCode => Object.hash(ctrl, shift, alt, trigger);
}

// ---------------------------------------------------------------------------
// Key name/code tables (letters, digits, space, F1-F24, common punctuation)
// ---------------------------------------------------------------------------

const Map<String, LogicalKeyboardKey> _nameToKey = {
  'space': LogicalKeyboardKey.space,
  'a': LogicalKeyboardKey.keyA, 'b': LogicalKeyboardKey.keyB,
  'c': LogicalKeyboardKey.keyC, 'd': LogicalKeyboardKey.keyD,
  'e': LogicalKeyboardKey.keyE, 'f': LogicalKeyboardKey.keyF,
  'g': LogicalKeyboardKey.keyG, 'h': LogicalKeyboardKey.keyH,
  'i': LogicalKeyboardKey.keyI, 'j': LogicalKeyboardKey.keyJ,
  'k': LogicalKeyboardKey.keyK, 'l': LogicalKeyboardKey.keyL,
  'm': LogicalKeyboardKey.keyM, 'n': LogicalKeyboardKey.keyN,
  'o': LogicalKeyboardKey.keyO, 'p': LogicalKeyboardKey.keyP,
  'q': LogicalKeyboardKey.keyQ, 'r': LogicalKeyboardKey.keyR,
  's': LogicalKeyboardKey.keyS, 't': LogicalKeyboardKey.keyT,
  'u': LogicalKeyboardKey.keyU, 'v': LogicalKeyboardKey.keyV,
  'w': LogicalKeyboardKey.keyW, 'x': LogicalKeyboardKey.keyX,
  'y': LogicalKeyboardKey.keyY, 'z': LogicalKeyboardKey.keyZ,
  '0': LogicalKeyboardKey.digit0, '1': LogicalKeyboardKey.digit1,
  '2': LogicalKeyboardKey.digit2, '3': LogicalKeyboardKey.digit3,
  '4': LogicalKeyboardKey.digit4, '5': LogicalKeyboardKey.digit5,
  '6': LogicalKeyboardKey.digit6, '7': LogicalKeyboardKey.digit7,
  '8': LogicalKeyboardKey.digit8, '9': LogicalKeyboardKey.digit9,
  'f1': LogicalKeyboardKey.f1, 'f2': LogicalKeyboardKey.f2,
  'f3': LogicalKeyboardKey.f3, 'f4': LogicalKeyboardKey.f4,
  'f5': LogicalKeyboardKey.f5, 'f6': LogicalKeyboardKey.f6,
  'f7': LogicalKeyboardKey.f7, 'f8': LogicalKeyboardKey.f8,
  'f9': LogicalKeyboardKey.f9, 'f10': LogicalKeyboardKey.f10,
  'f11': LogicalKeyboardKey.f11, 'f12': LogicalKeyboardKey.f12,
  'f13': LogicalKeyboardKey.f13, 'f14': LogicalKeyboardKey.f14,
  'f15': LogicalKeyboardKey.f15, 'f16': LogicalKeyboardKey.f16,
  'f17': LogicalKeyboardKey.f17, 'f18': LogicalKeyboardKey.f18,
  'f19': LogicalKeyboardKey.f19, 'f20': LogicalKeyboardKey.f20,
  'f21': LogicalKeyboardKey.f21, 'f22': LogicalKeyboardKey.f22,
  'f23': LogicalKeyboardKey.f23, 'f24': LogicalKeyboardKey.f24,
  'grave': LogicalKeyboardKey.backquote,
  'minus': LogicalKeyboardKey.minus,
  'equal': LogicalKeyboardKey.equal,
  'bracketleft': LogicalKeyboardKey.bracketLeft,
  'bracketright': LogicalKeyboardKey.bracketRight,
  'backslash': LogicalKeyboardKey.backslash,
  'semicolon': LogicalKeyboardKey.semicolon,
  'quote': LogicalKeyboardKey.quote,
  'comma': LogicalKeyboardKey.comma,
  'period': LogicalKeyboardKey.period,
  'slash': LogicalKeyboardKey.slash,
  'capslock': LogicalKeyboardKey.capsLock,
  'insert': LogicalKeyboardKey.insert,
  'home': LogicalKeyboardKey.home,
  'end': LogicalKeyboardKey.end,
  'pageup': LogicalKeyboardKey.pageUp,
  'pagedown': LogicalKeyboardKey.pageDown,
};

LogicalKeyboardKey? _keyFromName(String name) => _nameToKey[name];

final Map<LogicalKeyboardKey, String> _keyToName = {
  for (final e in _nameToKey.entries) e.value: e.key,
};

String? _nameOfKey(LogicalKeyboardKey key) => _keyToName[key];

/// LogicalKeyboardKey → Windows virtual-key code (user32 GetAsyncKeyState).
final Map<LogicalKeyboardKey, int> _winVk = {
  LogicalKeyboardKey.space: 0x20,
  // A-Z: VK == ASCII uppercase.
  for (var i = 0; i < 26; i++)
    _nameToKey[String.fromCharCode(0x61 + i)]!: 0x41 + i,
  // 0-9: VK == ASCII digit.
  for (var i = 0; i < 10; i++)
    _nameToKey[String.fromCharCode(0x30 + i)]!: 0x30 + i,
  // F1-F24: VK_F1 = 0x70.
  for (var i = 1; i <= 24; i++) _nameToKey['f$i']!: 0x70 + (i - 1),
  LogicalKeyboardKey.backquote: 0xC0, // VK_OEM_3
  LogicalKeyboardKey.minus: 0xBD, // VK_OEM_MINUS
  LogicalKeyboardKey.equal: 0xBB, // VK_OEM_PLUS
  LogicalKeyboardKey.bracketLeft: 0xDB, // VK_OEM_4
  LogicalKeyboardKey.bracketRight: 0xDD, // VK_OEM_6
  LogicalKeyboardKey.backslash: 0xDC, // VK_OEM_5
  LogicalKeyboardKey.semicolon: 0xBA, // VK_OEM_1
  LogicalKeyboardKey.quote: 0xDE, // VK_OEM_7
  LogicalKeyboardKey.comma: 0xBC, // VK_OEM_COMMA
  LogicalKeyboardKey.period: 0xBE, // VK_OEM_PERIOD
  LogicalKeyboardKey.slash: 0xBF, // VK_OEM_2
  LogicalKeyboardKey.capsLock: 0x14,
  LogicalKeyboardKey.insert: 0x2D,
  LogicalKeyboardKey.home: 0x24,
  LogicalKeyboardKey.end: 0x23,
  LogicalKeyboardKey.pageUp: 0x21,
  LogicalKeyboardKey.pageDown: 0x22,
};

/// LogicalKeyboardKey → X11 keysym (X11/keysymdef.h).
final Map<LogicalKeyboardKey, int> _x11Keysym = {
  LogicalKeyboardKey.space: 0x0020,
  // a-z: keysym == ASCII lowercase.
  for (var i = 0; i < 26; i++)
    _nameToKey[String.fromCharCode(0x61 + i)]!: 0x61 + i,
  // 0-9: keysym == ASCII digit.
  for (var i = 0; i < 10; i++)
    _nameToKey[String.fromCharCode(0x30 + i)]!: 0x30 + i,
  // F1-F24: XK_F1 = 0xFFBE.
  for (var i = 1; i <= 24; i++) _nameToKey['f$i']!: 0xFFBE + (i - 1),
  LogicalKeyboardKey.backquote: 0x0060, // grave
  LogicalKeyboardKey.minus: 0x002D,
  LogicalKeyboardKey.equal: 0x003D,
  LogicalKeyboardKey.bracketLeft: 0x005B,
  LogicalKeyboardKey.bracketRight: 0x005D,
  LogicalKeyboardKey.backslash: 0x005C,
  LogicalKeyboardKey.semicolon: 0x003B,
  LogicalKeyboardKey.quote: 0x0027,
  LogicalKeyboardKey.comma: 0x002C,
  LogicalKeyboardKey.period: 0x002E,
  LogicalKeyboardKey.slash: 0x002F,
  LogicalKeyboardKey.capsLock: 0xFFE5,
  LogicalKeyboardKey.insert: 0xFF63,
  LogicalKeyboardKey.home: 0xFF50,
  LogicalKeyboardKey.end: 0xFF57,
  LogicalKeyboardKey.pageUp: 0xFF55,
  LogicalKeyboardKey.pageDown: 0xFF56,
};

/// LogicalKeyboardKey → xkbcommon keysym name (xkbcommon-keysyms.h without
/// the XKB_KEY_ prefix — the freedesktop shortcuts-spec key identifiers).
final Map<LogicalKeyboardKey, String> _xkbNames = {
  LogicalKeyboardKey.space: 'space',
  // a-z / 0-9: names are the characters themselves.
  for (var i = 0; i < 26; i++)
    _nameToKey[String.fromCharCode(0x61 + i)]!: String.fromCharCode(0x61 + i),
  for (var i = 0; i < 10; i++)
    _nameToKey[String.fromCharCode(0x30 + i)]!: String.fromCharCode(0x30 + i),
  for (var i = 1; i <= 24; i++) _nameToKey['f$i']!: 'F$i',
  LogicalKeyboardKey.backquote: 'grave',
  LogicalKeyboardKey.minus: 'minus',
  LogicalKeyboardKey.equal: 'equal',
  LogicalKeyboardKey.bracketLeft: 'bracketleft',
  LogicalKeyboardKey.bracketRight: 'bracketright',
  LogicalKeyboardKey.backslash: 'backslash',
  LogicalKeyboardKey.semicolon: 'semicolon',
  LogicalKeyboardKey.quote: 'apostrophe',
  LogicalKeyboardKey.comma: 'comma',
  LogicalKeyboardKey.period: 'period',
  LogicalKeyboardKey.slash: 'slash',
  LogicalKeyboardKey.capsLock: 'Caps_Lock',
  LogicalKeyboardKey.insert: 'Insert',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'Prior',
  LogicalKeyboardKey.pageDown: 'Next',
};

/// Build a binding from a captured key-down: the pressed non-modifier key +
/// the live modifier state. Returns null for modifier-only or unmapped keys.
HotkeyBinding? bindingFromCapture(KeyEvent event, HardwareKeyboard hk) {
  final key = event.logicalKey;
  // Not const: LogicalKeyboardKey overrides == (const sets forbid that).
  final modifiers = {
    LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.meta,
  };
  if (modifiers.contains(key)) return null;
  if (!_keyToName.containsKey(key)) return null;
  final alt = hk.isAltPressed;
  final ctrl = hk.isControlPressed;
  // AltGr (Ctrl+Alt together) is not capturable as a modifier combo — it's
  // how AZERTY layouts type. Treat it as a bare-Alt binding attempt: reject.
  if (ctrl && alt) return null;
  return HotkeyBinding(
    ctrl: ctrl,
    shift: hk.isShiftPressed,
    alt: alt,
    trigger: key,
  );
}
