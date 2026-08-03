import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';

void main() {
  group('HotkeyBinding.parse / serialize', () {
    test('round-trips the defaults', () {
      for (final s in ['ctrl+space', 'ctrl+shift+m', 'ctrl+shift+d']) {
        final b = HotkeyBinding.parse(s);
        expect(b, isNotNull, reason: s);
        expect(b!.serialize(), s);
      }
    });

    test('parses modifiers and trigger', () {
      final b = HotkeyBinding.parse('ctrl+shift+m')!;
      expect(b.ctrl, isTrue);
      expect(b.shift, isTrue);
      expect(b.alt, isFalse);
      expect(b.trigger, LogicalKeyboardKey.keyM);
      expect(b.isBare, isFalse);
    });

    test('bare keys are flagged bare', () {
      expect(HotkeyBinding.parse('space')!.isBare, isTrue);
      expect(HotkeyBinding.parse('f13')!.isBare, isTrue);
      expect(HotkeyBinding.parse('ctrl+space')!.isBare, isFalse);
      expect(HotkeyBinding.parse('alt+x')!.isBare, isFalse);
    });

    test('rejects garbage, empties and modifier-only strings', () {
      expect(HotkeyBinding.parse(''), isNull);
      expect(HotkeyBinding.parse('   '), isNull);
      expect(HotkeyBinding.parse('ctrl+shift'), isNull);
      expect(HotkeyBinding.parse('ctrl+'), isNull);
      expect(HotkeyBinding.parse('bogus'), isNull);
      expect(HotkeyBinding.parse('ctrl+bogus'), isNull);
    });

    test('parse is case-insensitive', () {
      final b = HotkeyBinding.parse('Ctrl+Shift+M');
      expect(b, isNotNull);
      expect(b!.serialize(), 'ctrl+shift+m');
    });

    test('function keys and punctuation round-trip', () {
      for (final s in ['f1', 'f12', 'f24', 'grave', 'slash', 'ctrl+period']) {
        expect(HotkeyBinding.parse(s)?.serialize(), s, reason: s);
      }
    });
  });

  group('HotkeyBinding.display', () {
    test('formats with capitalized parts', () {
      expect(HotkeyBinding.parse('ctrl+space')!.display(), 'Ctrl + Space');
      expect(
          HotkeyBinding.parse('ctrl+shift+m')!.display(), 'Ctrl + Shift + M');
      expect(HotkeyBinding.parse('f13')!.display(), 'F13');
    });
  });

  group('platform key tables', () {
    test('every parseable key maps to a Windows VK and X11 keysym', () {
      for (final s in [
        'space', 'a', 'z', '0', '9', 'f1', 'f24', 'grave', 'minus',
        'equal', 'bracketleft', 'bracketright', 'backslash', 'semicolon',
        'quote', 'comma', 'period', 'slash', 'capslock', 'insert', 'home',
        'end', 'pageup', 'pagedown',
      ]) {
        final b = HotkeyBinding.parse(s)!;
        expect(b.windowsVk, isNotNull, reason: 'VK for $s');
        expect(b.x11Keysym, isNotNull, reason: 'keysym for $s');
      }
    });

    test('spot-checked codes match the platform headers', () {
      expect(HotkeyBinding.parse('space')!.windowsVk, 0x20);
      expect(HotkeyBinding.parse('a')!.windowsVk, 0x41);
      expect(HotkeyBinding.parse('f1')!.windowsVk, 0x70);
      expect(HotkeyBinding.parse('m')!.windowsVk, 0x4D);
      expect(HotkeyBinding.parse('space')!.x11Keysym, 0x0020);
      expect(HotkeyBinding.parse('a')!.x11Keysym, 0x61);
      expect(HotkeyBinding.parse('f1')!.x11Keysym, 0xFFBE);
    });
  });

  group('equality', () {
    test('same binding compares equal', () {
      expect(HotkeyBinding.parse('ctrl+space'),
          equals(HotkeyBinding.parse('ctrl+space')));
      expect(HotkeyBinding.parse('ctrl+space'),
          isNot(equals(HotkeyBinding.parse('space'))));
    });
  });
}
