import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Inbound ICE candidates that arrived before a peer connection was ready for
/// them, held per call.
///
/// The call id is load-bearing: the queue is cleared exactly when a peer
/// connection is built, which is also exactly when it holds the candidates for
/// the call being built. Untagged, "left over from the last call" and "for the
/// call starting right now" look identical. A lost candidate never comes back,
/// since each is sent once, so the connection has to survive on peer-reflexive
/// discovery, which often works and makes the failure intermittent.
class PendingIceQueue {
  PendingIceQueue({
    this.maxEntries = 256,
    void Function(String line)? log,
  }) : _log = log ?? _noop;

  /// Ceiling on queue size. libwebrtc offers ten or so candidates per side,
  /// so this is not a functional limit: it stops a peer holding a valid call
  /// id from growing the queue without bound before we can drain it.
  final int maxEntries;

  final void Function(String line) _log;
  final List<_Entry> _entries = [];

  /// Latched so an overflow episode logs once; re-arms when the queue drains.
  bool _overflowLogged = false;

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// Queues [candidate] against [callId]. False when the cap refused it, so
  /// the caller can tell "held" from "dropped" rather than assuming success.
  bool add(String callId, RTCIceCandidate candidate) {
    if (_entries.length >= maxEntries) {
      if (!_overflowLogged) {
        _overflowLogged = true;
        _log('[HOLLOW-VOICE] [SENTINEL] pending ICE queue hit $maxEntries — '
            'dropping further candidates until the peer connection is ready');
      }
      return false;
    }
    _entries.add(_Entry(callId, candidate));
    return true;
  }

  /// Drops every entry that does NOT belong to [keepCallId] and returns how
  /// many went. Null drops everything, which is what the end of a call wants.
  int discardExcept(String? keepCallId) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.callId != keepCallId);
    _rearmIfDrained();
    return before - _entries.length;
  }

  /// Removes and returns the candidates queued for [callId], oldest first.
  /// Only that call's: an entry for any other is stale by definition and
  /// libwebrtc would reject it against these ICE credentials anyway.
  List<RTCIceCandidate> take(String callId) {
    final ready = <RTCIceCandidate>[];
    for (final e in _entries) {
      if (e.callId == callId) ready.add(e.candidate);
    }
    if (ready.isNotEmpty) {
      _entries.removeWhere((e) => e.callId == callId);
      _rearmIfDrained();
    }
    return ready;
  }

  void _rearmIfDrained() {
    if (_entries.isEmpty) _overflowLogged = false;
  }

  static void _noop(String _) {}
}

class _Entry {
  const _Entry(this.callId, this.candidate);

  final String callId;
  final RTCIceCandidate candidate;
}
