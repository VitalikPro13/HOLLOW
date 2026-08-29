import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/services/pending_join_ffi.dart'
    show listPendingJoins;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Every parked join we are holding, keyed by server id.
///
/// A synchronous [Notifier] loaded once from `HollowShell._bootstrap` AFTER
/// the node starts, never an `AsyncNotifier` that reads the store from
/// `build()` (issue #58: the strip watches this on the first frame, and a
/// build-time read races the store open).
class PendingJoinsNotifier extends Notifier<Map<String, PendingJoinInfo>> {
  @override
  Map<String, PendingJoinInfo> build() => const {};

  /// Reads the persisted rows. Call from `_bootstrap` after `startNode`.
  ///
  /// A failure leaves whatever tiles the saved strip layout restored: the
  /// rows live in Rust, and a transient read error is not a reason to tell
  /// the user their join request is gone.
  Future<void> load() async {
    try {
      final rows = await listPendingJoins();
      state = {for (final row in rows) row.serverId: row};
      _syncStrip();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load pending joins: $e');
    }
  }

  /// Rust parked a join we just made.
  void park(String serverId) {
    final existing = state[serverId];
    state = {
      ...state,
      serverId: PendingJoinInfo(
        serverId: serverId,
        requestedAt:
            existing?.requestedAt ?? DateTime.now().millisecondsSinceEpoch,
      ),
    };
    _syncStrip();
  }

  /// A member answered, and the answer was no.
  void markRejected(String serverId, String reason) {
    final existing = state[serverId];
    state = {
      ...state,
      serverId: (existing ??
              PendingJoinInfo(
                serverId: serverId,
                requestedAt: DateTime.now().millisecondsSinceEpoch,
              ))
          .copyWith(state: PendingJoinInfo.stateRejected, reason: reason),
    };
    _syncStrip();
  }

  /// Back to pending after "Request again": a new nonce, no stale reason.
  void markRequestedAgain(String serverId) {
    state = {
      ...state,
      serverId: PendingJoinInfo(
        serverId: serverId,
        requestedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    };
    _syncStrip();
  }

  /// The join completed, was discarded, or the row went away.
  void remove(String serverId) {
    if (!state.containsKey(serverId)) return;
    final next = Map<String, PendingJoinInfo>.from(state)..remove(serverId);
    state = next;
    _syncStrip();
  }

  /// The strip is a VIEW of this map: one mutation path, and it is here.
  void _syncStrip() {
    ref.read(serverStripLayoutProvider.notifier).setPendingJoins(state.keys.toSet());
  }
}

final pendingJoinsProvider =
    NotifierProvider<PendingJoinsNotifier, Map<String, PendingJoinInfo>>(
  PendingJoinsNotifier.new,
);

/// Servers we were admitted to whose MLS group has not formed yet.
///
/// Between `admitted` and `ready` the server is real, joinable and listed, but
/// a member still has to be online with us once to add our leaf. RAM only: if
/// the app restarts in that window the flair simply does not show, and the
/// next co-presence completes the setup either way.
class AwaitingSetupNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String serverId) {
    if (state.contains(serverId)) return;
    state = {...state, serverId};
  }

  void remove(String serverId) {
    if (!state.contains(serverId)) return;
    state = state.where((id) => id != serverId).toSet();
  }
}

final awaitingSetupProvider =
    NotifierProvider<AwaitingSetupNotifier, Set<String>>(
  AwaitingSetupNotifier.new,
);

/// The `state` values `NetworkEvent_PendingJoinUpdated` carries.
const String kPendingJoinRejected = 'rejected';
const String kPendingJoinAdmitted = 'admitted';
const String kPendingJoinReady = 'ready';
const String kPendingJoinDiscarded = 'discarded';

/// `NetworkEvent_ServerJoinParked`: nobody was online to answer, so Rust is
/// holding the request. This is NOT a failure and must never read as one.
void onServerJoinParked(Ref ref, String serverId) {
  debugPrint('[HOLLOW] Server join parked: $serverId');
  ref.read(pendingJoinsProvider.notifier).park(serverId);
  _toast(
    'Nobody from this server is online. You will be added when a member '
    'returns',
    HollowToastType.info,
  );
}

/// `NetworkEvent_PendingJoinUpdated`.
void onPendingJoinUpdated(
    Ref ref, String serverId, String state, String reason) {
  debugPrint('[HOLLOW] Pending join $serverId: $state $reason');
  switch (state) {
    case kPendingJoinRejected:
      ref.read(pendingJoinsProvider.notifier).markRejected(serverId, reason);
      _toast(
        'Join request declined: ${pendingJoinReasonText(reason)}',
        HollowToastType.error,
      );
    case kPendingJoinAdmitted:
      // Fires just BEFORE ServerJoined: the row goes, and the flair takes over
      // until a member has been online with us long enough to add our leaf.
      ref.read(pendingJoinsProvider.notifier).remove(serverId);
      ref.read(awaitingSetupProvider.notifier).add(serverId);
    case kPendingJoinReady:
      ref.read(awaitingSetupProvider.notifier).remove(serverId);
    case kPendingJoinDiscarded:
      ref.read(pendingJoinsProvider.notifier).remove(serverId);
  }
}

void _toast(String message, HollowToastType type) {
  final context = hollowNavigatorKey.currentContext;
  if (context == null) return;
  HollowToast.show(context, message, type: type);
}
