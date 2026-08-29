/// One parked server join, as the UI sees it.
///
/// Mirrors Rust's `PendingJoinFfi` row (`pending_server_joins`). A join lands
/// here when every member of the server was offline at request time: instead
/// of failing after 15 seconds, Rust persists the request and answers it
/// whenever a member finally returns. That can be days, so nothing about this
/// state spins.
class PendingJoinInfo {
  /// The only thing an invite link carries, and therefore the only identity a
  /// parked join has: there is no name and no icon until a member answers.
  final String serverId;

  /// Unix milliseconds. Doubles as the request nonce on the wire.
  final int requestedAt;

  /// `pending` while we wait, `rejected` once a member turned us down.
  /// Kept as the raw string the FFI hands over so the two sides can never
  /// drift over an enum name.
  final String state;

  /// The raw rejection reason (`banned`, `server_private:{name}`, ...).
  /// Empty while pending. Render it through [pendingJoinReasonText].
  final String reason;

  const PendingJoinInfo({
    required this.serverId,
    required this.requestedAt,
    this.state = statePending,
    this.reason = '',
  });

  static const String statePending = 'pending';
  static const String stateRejected = 'rejected';

  bool get isRejected => state == stateRejected;

  PendingJoinInfo copyWith({String? state, String? reason, int? requestedAt}) {
    return PendingJoinInfo(
      serverId: serverId,
      requestedAt: requestedAt ?? this.requestedAt,
      state: state ?? this.state,
      reason: reason ?? this.reason,
    );
  }
}

/// Turns a wire rejection reason into the one sentence the user reads.
///
/// ONE function, shared by the toast, the desktop menu and the mobile sheet:
/// the same rejection must not be worded three ways depending on where you
/// happen to be looking when it arrives.
String pendingJoinReasonText(String reason) {
  if (reason == 'banned') return 'You are banned from this server';

  if (reason.startsWith('server_private:')) {
    final name = reason.substring('server_private:'.length).trim();
    return name.isEmpty ? 'This server is private' : '$name is private';
  }

  if (reason.startsWith('server_full:')) {
    // server_full:{name}:{max}
    final parts = reason.split(':');
    final name = parts.length > 1 ? parts[1].trim() : '';
    return name.isEmpty ? 'This server is full' : '$name is full';
  }

  if (reason.startsWith('twitch_failed:')) return 'Twitch verification failed';

  return reason.trim().isEmpty ? 'The request was declined' : reason;
}
