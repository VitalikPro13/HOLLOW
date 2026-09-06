import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const _settingsKey = 'favourite_friends';

/// Ordered list of favourite friend peer IDs. When non-empty the FriendsBar
/// shows only these, in this order; when empty it shows all accepted friends.
class FavouriteFriendsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  /// Load from app_settings.
  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: _settingsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (json.decode(raw) as List).cast<String>();
        state = list;
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load favourite friends: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await storage_api.saveSetting(
        key: _settingsKey,
        value: json.encode(state),
      );
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save favourite friends: $e');
    }
  }

  /// Add a friend to favourites (appended at end).
  Future<void> add(String peerId) async {
    if (state.contains(peerId)) return;
    state = [...state, peerId];
    await _persist();
  }

  /// Remove a friend from favourites.
  Future<void> remove(String peerId) async {
    if (!state.contains(peerId)) return;
    state = state.where((id) => id != peerId).toList();
    await _persist();
  }

  /// Toggle favourite status.
  Future<void> toggle(String peerId) async {
    if (state.contains(peerId)) {
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

  bool isFavourite(String peerId) => state.contains(peerId);
}

final favouriteFriendsProvider =
    NotifierProvider<FavouriteFriendsNotifier, List<String>>(
        FavouriteFriendsNotifier.new);
