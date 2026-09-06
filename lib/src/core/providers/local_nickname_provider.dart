import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const _storageKey = 'local_nicknames';

/// Local peer nicknames — purely local, not synced.
/// Maps peer_id → custom nickname chosen by the user.
class LocalNicknameNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => {};

  Future<void> loadAll() async {
    try {
      final json = await storage_api.loadSetting(key: _storageKey);
      if (json != null && json.isNotEmpty) {
        final map = Map<String, String>.from(jsonDecode(json) as Map);
        state = map;
        setLocalNicknamesRef(state);
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load local nicknames: $e');
    }
  }

  Future<void> setNickname(String peerId, String nickname) async {
    final updated = Map<String, String>.from(state);
    if (nickname.isEmpty) {
      updated.remove(peerId);
    } else {
      updated[peerId] = nickname;
    }
    state = updated;
    // Keep the static cache `displayNameFor()` reads in sync immediately, so
    // names refresh live everywhere, not only after a tab switch.
    setLocalNicknamesRef(state);
    await _save();
  }

  Future<void> clearNickname(String peerId) async {
    if (!state.containsKey(peerId)) return;
    final updated = Map<String, String>.from(state);
    updated.remove(peerId);
    state = updated;
    setLocalNicknamesRef(state);
    await _save();
  }

  // Rethrows so call sites can toast a failed persist: the in-memory update
  // applied, but a swallowed write silently loses the nickname next launch.
  Future<void> _save() async {
    try {
      await storage_api.saveSetting(
        key: _storageKey,
        value: jsonEncode(state),
      );
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save local nicknames: $e');
      rethrow;
    }
  }
}

final localNicknameProvider =
    NotifierProvider<LocalNicknameNotifier, Map<String, String>>(
  LocalNicknameNotifier.new,
);
