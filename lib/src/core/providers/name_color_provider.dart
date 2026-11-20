import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:flutter/painting.dart' show Color;
import 'package:hollow/src/theme/hollow_theme.dart';

/// `app_settings` key of the viewer's "Show custom name colours" switch. Per
/// device: it changes only what this device draws.
const kShowNameColorsSetting = 'show_name_colors';

/// Whether this device draws the colours people chose for their names (#140).
/// On by default; off falls back to everyone's hashed colour.
final showNameColorsProvider =
    NotifierProvider<ShowNameColorsNotifier, bool>(ShowNameColorsNotifier.new);

class ShowNameColorsNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  /// Called once from the bootstrap, after the store is open.
  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: kShowNameColorsSetting);
      state = raw != '0';
    } catch (e) {
      debugPrint('[HOLLOW] showNameColors.load() failed: $e');
    }
  }

  Future<void> setEnabled(bool on) async {
    if (state == on) return;
    state = on;
    try {
      await storage_api.saveSetting(
          key: kShowNameColorsSetting, value: on ? '1' : '0');
    } catch (e) {
      debugPrint('[HOLLOW] showNameColors save failed: $e');
    }
  }
}

/// The name colour field this device shows for [peerId] (a master, or any
/// device of one): theirs, or '' when they have none, custom colours are
/// switched off, or we blocked them (a block takes their words off every
/// surface, and a colour they chose is theirs too).
final shownNameColorProvider = Provider.family<String, String>((ref, peerId) {
  if (!ref.watch(showNameColorsProvider)) return '';
  final master = ref.watch(deviceLinkProvider).identityOf(peerId);
  if (ref.watch(blockedUsersProvider.select((b) => b.contains(master)))) {
    return '';
  }
  return ref.watch(profileProvider.select((p) => p[master]?.nameColor ?? ''));
});

/// Our own MASTER id, '' before the identity loads: the one name that may wear
/// the accent.
final ownNameMasterProvider = Provider<String>((ref) => ref
    .watch(deviceLinkProvider)
    .identityOf(ref.watch(identityProvider).peerId ?? ''));

extension NamePaintRef on WidgetRef {
  bool _isOwn(String master) {
    final own = watch(ownNameMasterProvider);
    return own.isNotEmpty &&
        watch(deviceLinkProvider).identityOf(master) == own;
  }

  /// How [master]'s name is painted here: their chosen colour when this device
  /// shows them, else their hashed one.
  NamePaint namePaint(String master, HollowTheme hollow) => namePaintFor(
      master, hollow,
      field: watch(shownNameColorProvider(master)), self: _isOwn(master));

  /// Their chosen paint only, null when they have none to show: for surfaces
  /// that stay neutral otherwise.
  NamePaint? chosenNamePaintOf(String master, HollowTheme hollow) =>
      chosenNamePaint(hollow, watch(shownNameColorProvider(master)),
          self: _isOwn(master));

  /// A name in a chat or a call: someone else's paint, or for [isSelf] the
  /// colour you chose, else [selfColor] (the accent text unless given).
  NamePaint personNamePaint(String master, HollowTheme hollow,
          {required bool isSelf, Color? selfColor}) =>
      isSelf
          ? chosenNamePaint(hollow, watch(shownNameColorProvider(master)),
                  self: true) ??
              NamePaint([selfColor ?? hollow.accentText])
          : namePaint(master, hollow);
}
