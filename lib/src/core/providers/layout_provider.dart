import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Layout modes available in the app.
enum LayoutMode {
  /// Discord/Slack-style 4-panel shell:
  /// ServerStrip | ChannelSidebar | ChatPane | MemberPanel.
  classic,

  /// The default Hollow shell: friends bar on top, dock bar at the bottom.
  dock,
}

/// Persisted layout mode preference. Default: dock.
///
/// A plain [Notifier] with an explicit [LayoutModeNotifier.load] called from
/// `HollowShell._bootstrap` — NOT an `AsyncNotifier` that reads the setting in
/// `build()`. Rust `load_setting` throws until the SQLCipher store is open, and
/// the shell mounts (and watches this provider) during the local-first render,
/// well before the DB is ready. The eager read therefore always lost the race,
/// the error was swallowed by the `valueOrNull ?? dock` fallback at every call
/// site, and Classic mode silently reverted to Dock on every launch (#58).
final layoutModeProvider =
    NotifierProvider<LayoutModeNotifier, LayoutMode>(LayoutModeNotifier.new);

class LayoutModeNotifier extends Notifier<LayoutMode> {
  @override
  LayoutMode build() => LayoutMode.dock;

  /// Restore the persisted mode. Call from `_bootstrap()` after the store opens.
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'layout_mode');
      state = val == 'classic' ? LayoutMode.classic : LayoutMode.dock;
    } catch (e) {
      debugPrint('[HOLLOW] layoutMode.load() failed: $e');
    }
  }

  Future<void> setMode(LayoutMode mode) async {
    state = mode;
    await storage_api.saveSetting(
      key: 'layout_mode',
      value: mode == LayoutMode.classic ? 'classic' : 'dock',
    );
  }
}
