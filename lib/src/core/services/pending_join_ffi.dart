/// The ONE file that touches Rust for parked server joins.
///
/// A join whose members were all offline used to fail after 15 seconds; it is
/// now PARKED, and Rust answers it whenever a member comes back, days later
/// if need be. The matching `NetworkEvent` variants (`ServerJoinParked`,
/// `PendingJoinUpdated`) are dispatched from `event_provider.dart`, whose
/// switch is exhaustive over the union, so a new one has to be named there.
library;

import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// The backend the UI talks to; swappable so widget tests need no FFI bridge.
abstract class PendingJoinBackend {
  Future<List<PendingJoinInfo>> list();

  /// Drops the request for good: the row goes, we leave the server's room, and
  /// a late admission can never reach us.
  Future<void> discard(String serverId);

  /// Asks again with a fresh nonce. The only user action that re-deposits into
  /// the relay's join ring.
  Future<void> retry(String serverId);
}

class _RustPendingJoins implements PendingJoinBackend {
  const _RustPendingJoins();

  @override
  Future<List<PendingJoinInfo>> list() async {
    final rows = await crdt_api.listPendingJoins();
    return [
      for (final row in rows)
        PendingJoinInfo(
          serverId: row.serverId,
          // PlatformInt64 is `int` natively and `BigInt` on web; `toInt()` is
          // the one call that reads the same on both.
          requestedAt: row.requestedAt.toInt(),
          state: row.state,
          reason: row.reason,
        ),
    ];
  }

  @override
  Future<void> discard(String serverId) =>
      crdt_api.discardPendingJoin(serverId: serverId);

  @override
  Future<void> retry(String serverId) =>
      crdt_api.retryPendingJoin(serverId: serverId);
}

/// The live backend. Tests assign a fake and restore it in a tearDown.
PendingJoinBackend pendingJoinBackend = const _RustPendingJoins();

Future<List<PendingJoinInfo>> listPendingJoins() =>
    pendingJoinBackend.list();

Future<void> discardPendingJoin(String serverId) =>
    pendingJoinBackend.discard(serverId);

Future<void> retryPendingJoin(String serverId) =>
    pendingJoinBackend.retry(serverId);
