import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Whether the Hollow Shop has been woken up on this install.
///
/// The shop is put away, not taken away: every surface, the pack import and
/// the wearing of owned art are all still here and still wired, they simply
/// do not appear until someone finds the version row in Settings > About and
/// taps it seven times. Until then the app carries no shop sentence anywhere,
/// which is exactly what a store build shows, so the two share one gate
/// (`shopAvailableProvider` in `shop_availability.dart`).
///
/// Marks already on a profile keep rendering either way. They are ordinary
/// profile data, and hiding a badge someone bought would be the one thing
/// this change must not do.
final shopUnlockedProvider =
    NotifierProvider<ShopUnlockNotifier, bool>(ShopUnlockNotifier.new);

const String _kShopUnlockedKey = 'shop_unlocked';

/// A plain [Notifier] with an explicit [load] called from
/// `HollowShell._bootstrap`, never an `AsyncNotifier` that reads the setting
/// in `build()`: `load_setting` throws until the SQLCipher store is open, and
/// the shell mounts during the local-first render, well before that (#58).
class ShopUnlockNotifier extends Notifier<bool> {
  /// Forced answer for a harness that has no persisted setting to read.
  ///
  /// The UI probe builds the widget tree itself against a copy of a real data
  /// dir, so the seven taps have never happened there and every shop scenario
  /// would boot into a hidden shop. Seeding from the probe's `setUpAll` is the
  /// only place early enough: the store is not open yet, so nothing can be
  /// written, and the shell's `load()` would overwrite an override a moment
  /// later. When it is set, [load] honours it instead of the database.
  static bool? _seed;

  @visibleForTesting
  static void debugSeed(bool? value) => _seed = value;

  @override
  bool build() => _seed ?? false;

  /// Restore the persisted answer. Call from `_bootstrap()` after the store
  /// opens, next to the layout mode.
  Future<void> load() async {
    if (_seed != null) {
      state = _seed!;
      return;
    }
    try {
      final val = await storage_api.loadSetting(key: _kShopUnlockedKey);
      state = val == 'true';
    } catch (e) {
      debugPrint('[HOLLOW] shopUnlocked.load() failed: $e');
    }
  }

  /// Flip the gate. The state moves first so the dock icon and the settings
  /// sections appear on the same frame as the seventh tap; the write is what
  /// makes it survive a restart, and a failed write must never take the app
  /// down from a fire-and-forget call site.
  Future<void> setUnlocked(bool value) async {
    state = value;
    try {
      await storage_api.saveSetting(
        key: _kShopUnlockedKey,
        value: value ? 'true' : 'false',
      );
    } catch (e) {
      debugPrint('[HOLLOW] shopUnlocked.setUnlocked($value) failed: $e');
    }
  }
}
