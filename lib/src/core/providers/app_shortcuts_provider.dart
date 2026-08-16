import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Rebindable application shortcuts (Settings > Shortcuts). The voice trio
/// (PTT/mute/deafen) is deliberately NOT here — those live in their own
/// providers (settings_provider.dart) because the in-call HotkeyController
/// consumes them system-wide; the Shortcuts page edits both sets.
///
/// Enforcement sites read the live map: HollowShell's `_handleGlobalKey`
/// (General group) and `handleChatInputKey` (formatting group). Enter /
/// Shift+Enter / Ctrl+V are structural, not shortcuts — never listed here.
enum AppShortcut {
  openSettings('Open settings', 'ctrl+comma'),
  toggleMemberPanel('Toggle member panel', 'ctrl+shift+p'),
  quickSearch('Quick search', 'ctrl+k'),
  toggleSplitView('Toggle split view', 'ctrl+shift+backslash'),
  focusLeftPane('Focus left pane', 'ctrl+1'),
  focusRightPane('Focus right pane', 'ctrl+2'),
  zoomIn('Zoom interface in', 'ctrl+equal'),
  zoomOut('Zoom interface out', 'ctrl+minus'),
  zoomReset('Reset zoom', 'ctrl+0'),
  formatBold('Bold', 'ctrl+b'),
  formatItalic('Italic', 'ctrl+i'),
  formatCode('Code', 'ctrl+e'),
  formatStrikethrough('Strikethrough', 'ctrl+shift+x'),
  formatSpoiler('Spoiler', 'ctrl+shift+s');

  const AppShortcut(this.label, this.defaultSerialized);

  /// User-facing row label on the Shortcuts page.
  final String label;
  final String defaultSerialized;

  HotkeyBinding get defaultBinding => HotkeyBinding.parse(defaultSerialized)!;
}

/// Compile-time defaults — the fallback for enforcement sites running
/// before the async load lands (and for tests).
final Map<AppShortcut, HotkeyBinding> kAppShortcutDefaults = {
  for (final s in AppShortcut.values) s: s.defaultBinding,
};

/// One storage key holding a JSON object of OVERRIDES only
/// ({enum name: serialized binding}) — defaults never hit the disk, so
/// changing a default in code reaches every user who didn't rebind it.
const String _kStorageKey = 'app_shortcuts';

final appShortcutsProvider = AsyncNotifierProvider<AppShortcutsNotifier,
    Map<AppShortcut, HotkeyBinding>>(AppShortcutsNotifier.new);

class AppShortcutsNotifier
    extends AsyncNotifier<Map<AppShortcut, HotkeyBinding>> {
  Map<String, String> _overrides = {};

  @override
  Future<Map<AppShortcut, HotkeyBinding>> build() async {
    final raw = await storage_api.loadSetting(key: _kStorageKey);
    _overrides = decodeOverrides(raw);
    return mergeOverrides(_overrides);
  }

  /// Parses the stored override JSON; corrupt data degrades to no overrides.
  static Map<String, String> decodeOverrides(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return {
        for (final e in decoded.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  /// Defaults + overrides. An unparseable override falls back to the
  /// default binding — a bad stored string must never silently kill a
  /// shortcut (the voice-hotkey PTT lesson, 2026-08-04).
  static Map<AppShortcut, HotkeyBinding> mergeOverrides(
      Map<String, String> overrides) {
    return {
      for (final s in AppShortcut.values)
        s: HotkeyBinding.parse(overrides[s.name] ?? s.defaultSerialized) ??
            s.defaultBinding,
    };
  }

  Future<void> setBinding(AppShortcut shortcut, String serialized) async {
    if (serialized == shortcut.defaultSerialized) {
      _overrides.remove(shortcut.name); // back to default = no override
    } else {
      _overrides[shortcut.name] = serialized;
    }
    await storage_api.saveSetting(
        key: _kStorageKey, value: jsonEncode(_overrides));
    state = AsyncData(mergeOverrides(_overrides));
  }

  Future<void> reset(AppShortcut shortcut) =>
      setBinding(shortcut, shortcut.defaultSerialized);
}
