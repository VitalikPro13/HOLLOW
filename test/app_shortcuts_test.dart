// AppShortcut registry tests: override decode/merge behavior — including
// the "bad stored data must never kill a shortcut" rule (the voice-hotkey
// PTT lesson, 2026-08-04).
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';

void main() {
  test('defaults parse and cover every shortcut', () {
    for (final s in AppShortcut.values) {
      expect(kAppShortcutDefaults[s], isNotNull, reason: s.name);
      expect(s.defaultBinding.serialize(), s.defaultSerialized,
          reason: '${s.name} default must round-trip');
    }
  });

  test('no two defaults collide', () {
    final seen = <String, AppShortcut>{};
    for (final s in AppShortcut.values) {
      final key = s.defaultSerialized;
      expect(seen.containsKey(key), isFalse,
          reason: '${s.name} collides with ${seen[key]?.name} on $key');
      seen[key] = s;
    }
  });

  test('decodeOverrides tolerates corrupt JSON and wrong shapes', () {
    expect(AppShortcutsNotifier.decodeOverrides(null), isEmpty);
    expect(AppShortcutsNotifier.decodeOverrides(''), isEmpty);
    expect(AppShortcutsNotifier.decodeOverrides('not json{'), isEmpty);
    expect(AppShortcutsNotifier.decodeOverrides('[1,2]'), isEmpty);
    expect(
        AppShortcutsNotifier.decodeOverrides('{"quickSearch": 7}'), isEmpty);
    expect(
        AppShortcutsNotifier.decodeOverrides(
            '{"quickSearch": "ctrl+shift+k"}'),
        {'quickSearch': 'ctrl+shift+k'});
  });

  test('mergeOverrides applies overrides and keeps the rest default', () {
    final merged = AppShortcutsNotifier.mergeOverrides(
        {'quickSearch': 'ctrl+shift+k'});
    expect(merged[AppShortcut.quickSearch]!.serialize(), 'ctrl+shift+k');
    expect(merged[AppShortcut.formatBold]!.serialize(), 'ctrl+b');
  });

  test('an unparseable override falls back to the default binding', () {
    final merged = AppShortcutsNotifier.mergeOverrides(
        {'quickSearch': 'bogus+nonsense', 'formatBold': ''});
    expect(merged[AppShortcut.quickSearch]!.serialize(), 'ctrl+k');
    expect(merged[AppShortcut.formatBold]!.serialize(), 'ctrl+b');
  });

  test('unknown override keys are ignored', () {
    final merged = AppShortcutsNotifier.mergeOverrides(
        {'someRemovedShortcut': 'ctrl+q'});
    expect(merged.length, AppShortcut.values.length);
  });
}
