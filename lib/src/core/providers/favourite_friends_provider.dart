import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const _settingsKey = 'favourite_friends';

/// [ids] with every device id collapsed to its master, first place kept.
List<String> collapseFavourites(
    List<String> ids, String Function(String peerId) identityOf) {
  final seen = <String>{};
  return [
    for (final id in ids)
      if (seen.add(identityOf(id))) identityOf(id),
  ];
}

/// Ordered favourite friends, as MASTER ids. When non-empty the FriendsBar
/// shows only these, in this order; when empty it shows all accepted friends.
///
/// Every method takes a device or a master id. Lists saved before a friend's
/// devices were linked (or by a surface that stored a device id) heal on load
/// and whenever the device map changes: a device and its master stored side
/// by side would give the reorderable Friends list two rows with one key.
class FavouriteFriendsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    ref.listen(deviceLinkProvider, (_, _) => _heal());
    return const [];
  }

  String _master(String peerId) =>
      ref.read(deviceLinkProvider).identityOf(peerId);

  @protected
  Future<String?> readStored() => storage_api.loadSetting(key: _settingsKey);

  @protected
  Future<void> writeStored(String value) =>
      storage_api.saveSetting(key: _settingsKey, value: value);

  /// Load from app_settings.
  Future<void> load() async {
    try {
      final raw = await readStored();
      if (raw != null && raw.isNotEmpty) {
        state = (json.decode(raw) as List).cast<String>();
        _heal();
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load favourite friends: $e');
    }
  }

  void _heal() {
    final healed = collapseFavourites(state, _master);
    if (listEquals(healed, state)) return;
    state = healed;
    unawaited(_persist());
  }

  Future<void> _persist() async {
    try {
      await writeStored(json.encode(state));
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save favourite friends: $e');
    }
  }

  /// Add a friend to favourites (appended at end).
  Future<void> add(String peerId) async {
    final master = _master(peerId);
    if (isFavourite(master)) return;
    state = [...state, master];
    await _persist();
  }

  /// Remove a friend from favourites, under any id they were stored as.
  Future<void> remove(String peerId) async {
    final master = _master(peerId);
    if (!isFavourite(master)) return;
    state = state.where((id) => _master(id) != master).toList();
    await _persist();
  }

  /// Toggle favourite status.
  Future<void> toggle(String peerId) async {
    if (isFavourite(peerId)) {
      await remove(peerId);
    } else {
      await add(peerId);
    }
  }

  /// Reorder: move item from oldIndex to newIndex.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = [...state];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    state = list;
    await _persist();
  }

  bool isFavourite(String peerId) {
    final master = _master(peerId);
    return state.any((id) => _master(id) == master);
  }
}

final favouriteFriendsProvider =
    NotifierProvider<FavouriteFriendsNotifier, List<String>>(
        FavouriteFriendsNotifier.new);
