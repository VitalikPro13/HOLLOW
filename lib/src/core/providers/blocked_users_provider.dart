import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Set of blocked MASTER peer_ids, mirrored from the Rust block list.
///
/// Rust enforces blocks at ingest (DMs, friend requests, calls, files are
/// dropped before they reach Dart); this mirror exists so the UI can
/// synchronously toggle Block/Unblock buttons, hide blocked senders' channel
/// messages and suppress their channel notifications.
///
/// The set is MASTER-keyed — always compare
/// `ref.read(deviceLinkProvider).identityOf(peerId)` against it, never a raw
/// (possibly per-device) peer_id.
class BlockedUsersNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Load the persisted block list from the local DB. Called once from
  /// hollow_shell's `_bootstrap` (after the node starts) — never from build().
  Future<void> load() async {
    try {
      final list = await storage_api.loadBlockedPeers();
      state = list.toSet();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load blocked peers: $e');
    }
  }

  /// Block [masterId] (resolve device ids to the master at the call site).
  /// Optimistic: the set updates immediately and reverts if the FFI call
  /// fails — rethrows so callers can toast the failure.
  Future<void> block(String masterId) async {
    if (state.contains(masterId)) return;
    state = {...state, masterId};
    try {
      await storage_api.blockPeer(peerId: masterId);
    } catch (e) {
      state = state.where((id) => id != masterId).toSet();
      rethrow;
    }
  }

  /// Unblock a previously blocked identity. Optimistic, reverts on error.
  Future<void> unblock(String masterId) async {
    if (!state.contains(masterId)) return;
    state = state.where((id) => id != masterId).toSet();
    try {
      await storage_api.unblockPeer(peerId: masterId);
    } catch (e) {
      state = {...state, masterId};
      rethrow;
    }
  }

  bool isBlocked(String masterId) => state.contains(masterId);
}

final blockedUsersProvider =
    NotifierProvider<BlockedUsersNotifier, Set<String>>(
        BlockedUsersNotifier.new);
