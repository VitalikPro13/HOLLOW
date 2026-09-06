import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Whether the Hollow Shop has been woken up on this install.
///
/// The shop is put away, not taken away: every surface is still wired but
/// hidden until someone taps the version row in Settings > About seven times.
/// Until then the app carries no shop sentence anywhere, which is exactly what
/// a store build shows, so the two share one gate (`shopAvailableProvider`).
///
/// Marks already on a profile keep rendering either way: they are ordinary
/// profile data, and hiding a badge someone bought is the one thing to avoid.
final shopUnlockedProvider =
    NotifierProvider<ShopUnlockNotifier, bool>(ShopUnlockNotifier.new);

const String _kShopUnlockedKey = 'shop_unlocked';

/// A plain [Notifier] with an explicit [load] from `HollowShell._bootstrap`,
/// never an `AsyncNotifier` reading the setting in `build()`: `load_setting`
/// throws until the SQLCipher store is open, well after the shell mounts (#58).
class ShopUnlockNotifier extends Notifier<bool> {
  /// Forced answer for a harness that has no persisted setting to read.
  ///
  /// The UI probe builds the widget tree itself, so the seven taps never
  /// happened there. Seeding from `setUpAll` is the only place early enough:
  /// the store is not open, and the shell's `load()` would overwrite it later.
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

  /// Flip the gate. The state moves first so the dock icon and settings sections
  /// appear on the same frame as the seventh tap; a failed write must never take
  /// the app down from a fire-and-forget call site.
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
