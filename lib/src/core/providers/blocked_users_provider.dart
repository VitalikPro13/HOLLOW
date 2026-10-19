import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/services/push_hints_cache.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Set of blocked MASTER peer_ids, mirrored from the Rust block list.
///
/// Rust enforces blocks at ingest; this mirror exists so the UI can
/// synchronously toggle Block/Unblock, hide blocked senders' channel messages
/// and suppress their notifications. Always compare a peer id resolved through
/// `deviceLinkProvider.identityOf`, never a raw per-device id.
class BlockedUsersNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Load the persisted block list from the local DB. Called once from
  /// hollow_shell's `_bootstrap` (after the node starts) — never from build().
  Future<void> load() async {
    try {
      final list = await storage_api.loadBlockedPeers();
      final before = state;
      state = list.toSet();
      _withdrawNotifications(state.difference(before));
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load blocked peers: $e');
    }
  }

  /// Block [masterId] (resolve device ids at the call site). Optimistic: the set
  /// updates immediately, reverts on failure, and rethrows so callers can toast.
  ///
  /// Only a block the person makes here reports it; one learned from a sibling
  /// arrives through [load] and was reported where it was made.
  Future<void> block(String masterId) async {
    if (state.contains(masterId)) return;
    state = {...state, masterId};
    try {
      await storage_api.blockPeer(peerId: masterId);
    } catch (e) {
      state = state.where((id) => id != masterId).toSet();
      rethrow;
    }
    PushHintsCache.rewriteLast();
    _withdrawNotifications({masterId});
    // Tells us someone blocked [masterId]: one anonymous count at the relay,
    // never who blocked. An older relay drops the category and nothing here
    // waits for its answer.
    unawaited(Future.sync(() => network_api.reportUser(
        target: masterId, category: kBlockedReportCategory)).catchError((_) {}));
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
    PushHintsCache.rewriteLast();
  }

  bool isBlocked(String masterId) => state.contains(masterId);

  /// What the newly blocked already put on screen as notifications goes too,
  /// whichever of their devices it came from.
  void _withdrawNotifications(Set<String> masters) {
    if (masters.isEmpty) return;
    final links = ref.read(deviceLinkProvider).links;
    for (final master in masters) {
      final ids = {
        master,
        for (final e in links.entries)
          if (e.value == master) e.key,
      };
      unawaited(ref
          .read(systemNotificationProvider.notifier)
          .withdrawPerson(ids)
          .catchError((Object _) {}));
    }
  }
}

/// The report category a block sends; the relay counts it like any other.
const kBlockedReportCategory = 'blocked';

final blockedUsersProvider =
    NotifierProvider<BlockedUsersNotifier, Set<String>>(
        BlockedUsersNotifier.new);

/// Whether [peerId], a master or any device of one, belongs to someone we
/// blocked. Calls, headers and menus ask this, never the raw set.
final peerBlockedProvider = Provider.autoDispose.family<bool, String>(
    (ref, peerId) => ref
        .watch(blockedUsersProvider)
        .contains(ref.watch(deviceLinkProvider).identityOf(peerId)));
