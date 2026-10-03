/// A peer connection as answer and ICE pairing sees it.
abstract interface class RtcSignalEndpoint {
  /// The id the connection is stored under: the device we answered, or the
  /// id we dialled (a MASTER for a DM call).
  String get peerId;
  String get connId;
}

/// The connection in [conns] an answer or ICE candidate from [fromPeer]
/// carrying [connId] belongs to, or null.
///
/// The relay reads `conn_id`, so it pairs only within one identity: a DM call
/// dials a MASTER and is answered by whichever device Rust picked, and nobody
/// else may answer it. A cold [identityOf] fails closed; the dial times out
/// and redials.
T? pairRtcSignal<T extends RtcSignalEndpoint>(
  Map<String, T> conns,
  String fromPeer,
  String connId,
  String Function(String peerId) identityOf,
) {
  final direct = conns[fromPeer];
  if (direct != null && direct.connId == connId) return direct;
  final who = identityOf(fromPeer);
  for (final conn in conns.values) {
    if (conn.connId == connId && identityOf(conn.peerId) == who) return conn;
  }
  return null;
}

/// ICE candidates that arrived before their offer, held per sender identity
/// so only the offerer's own candidates reach the connection its offer builds.
class PendingRtcIce<T> {
  final Map<String, List<T>> _queued = {};

  static String _key(String identity, String connId) => '$identity|$connId';

  void add(String identity, String connId, T candidate) =>
      _queued.putIfAbsent(_key(identity, connId), () => []).add(candidate);

  /// Removes and returns what [identity] queued for [connId].
  List<T> take(String identity, String connId) =>
      _queued.remove(_key(identity, connId)) ?? const [];

  void clear() => _queued.clear();
}
