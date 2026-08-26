import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Inbound ICE candidates that arrived before a peer connection was ready for
/// them, held per call.
///
/// ## Why the call id is load-bearing
///
/// A candidate can reach us before we have anywhere to put it. The answerer
/// receives the offer, then spends a couple of hundred milliseconds opening
/// the microphone before it builds the peer connection, and the offerer starts
/// trickling the moment its own local description is set. Everything arriving
/// in that window has to wait.
///
/// The queue therefore gets cleared exactly when a peer connection is built,
/// which is also exactly when it is holding the candidates for the call being
/// built. Untagged, "left over from the last call, throw it away" and "for the
/// call starting right now, keep it" look identical, and the code guessed in
/// the direction that loses them.
///
/// A lost candidate does not come back: each one is sent once, so the
/// connection has to survive on whatever travels the other way, via
/// peer-reflexive discovery. That often works, which is what makes the failure
/// intermittent rather than obvious.
class PendingIceQueue {
  PendingIceQueue({
    this.maxEntries = 256,
    void Function(String line)? log,
  }) : _log = log ?? _noop;

  /// Ceiling on queue size. libwebrtc offers on the order of ten candidates
  /// per side, so this is not a functional limit: it exists so a peer holding
  /// a valid call id cannot grow the queue without bound while we are not yet
  /// able to drain it.
  final int maxEntries;

  final void Function(String line) _log;
  final List<_Entry> _entries = [];

  /// Latched so an overflow episode logs once, not once per candidate.
  /// Re-arms when the queue drains, so a later episode is still reported.
  bool _overflowLogged = false;

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  /// Queue [candidate] against [callId].
  ///
  /// Returns false when the cap refused it, so the caller can tell "held" from
  /// "dropped" rather than assuming success.
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

  /// Drop every entry that does NOT belong to [keepCallId], returning how many
  /// were dropped. A null [keepCallId] drops everything, which is what the end
  /// of a call wants.
  int discardExcept(String? keepCallId) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.callId != keepCallId);
    _rearmIfDrained();
    return before - _entries.length;
  }

  /// Remove and return the candidates queued for [callId], oldest first.
  ///
  /// Only that call's: an entry for any other call is stale by definition and
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
