import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// How long a link that has never connected may sit in `failed` before its
/// lane counts it as a setup failure.
const kSetupFailureGrace = Duration(seconds: 8);

/// Holds a `failed` that arrives before a link's first connect, for [grace].
///
/// libwebrtc reports `failed` as soon as every candidate pair it holds has
/// failed, even while the peer is still trickling candidates, and revives on
/// its own when a later candidate lands. A relay-only ("Always relay calls")
/// peer hits this on every setup: coturn's peer lock refuses the remote's
/// host and srflx pairs in about a millisecond, so ICE fails before the
/// remote relay candidate is added, then goes connecting and connected in
/// the same second.
///
/// One per link attempt. Only `connected` (or [cancel], from the lane's
/// teardown) disarms it; a link revived to `connecting` that fails again keeps
/// the first failure's deadline, so flapping cannot postpone the verdict.
/// [onExpired] fires only when the link is still `failed` at the deadline.
class SetupFailureGrace {
  SetupFailureGrace({required this.onExpired, this.grace = kSetupFailureGrace});

  final void Function() onExpired;
  Duration grace;

  Timer? _timer;
  RTCPeerConnectionState? _last;

  /// Whether a failure is being held.
  bool get isHolding => _timer != null;

  /// Feed a transport state from the lane's `onConnectionState`.
  ///
  /// Returns true when this state is a `failed` that the grace now holds, so
  /// the lane must not tear down for it.
  bool note(RTCPeerConnectionState state) {
    _last = state;
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _timer ??= Timer(grace, _expire);
        return true;
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        cancel();
        return false;
      default:
        return false;
    }
  }

  void _expire() {
    _timer = null;
    if (_last == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      onExpired();
    }
  }

  /// Forget any held failure. Safe to call twice.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
