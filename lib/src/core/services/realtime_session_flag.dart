import '../../rust/api/network.dart' as network_api;

/// Tells the relay client whether a real-time session is live, so it can
/// reconnect fast enough to be useful to one.
///
/// The socket's exponential backoff toward thirty seconds is right while the
/// app is idle and wrong during a call, where recovering a lapsed media link
/// needs an offer over that same socket inside the hold-open window. Hence a
/// conditional policy rather than a lower cap for everyone.
///
/// Holders are keyed rather than a plain boolean: leaving one session must not
/// clear the flag while another is still running (issue #49 makes DM calls and
/// voice channels exclusive, conferences need not be).
class RealtimeSessionFlag {
  RealtimeSessionFlag._();

  static final _holders = <String>{};

  /// Whether the flag is currently set. Test seam.
  static bool get isActive => _holders.isNotEmpty;

  /// Current holder keys, for tests and diagnostics.
  static Set<String> get holders => Set.unmodifiable(_holders);

  /// Declare that [key] has a live real-time session.
  static void acquire(String key) {
    if (!_holders.add(key)) return;
    if (_holders.length == 1) _push(true);
  }

  /// Declares that [key]'s session has ended. Safe when it never started,
  /// which matters because teardown paths run on failures too.
  static void release(String key) {
    if (!_holders.remove(key)) return;
    if (_holders.isEmpty) _push(false);
  }

  /// Drop every holder. For app shutdown and for tests.
  static void reset() {
    if (_holders.isEmpty) return;
    _holders.clear();
    _push(false);
  }

  /// Overridable for widget tests, which have no Rust library loaded.
  static void Function(bool active)? sink;

  static void _push(bool active) {
    final override = sink;
    if (override != null) {
      override(active);
      return;
    }
    // .catchError, never a bare call: a sync try/catch around an un-awaited
    // Future catches nothing and the rejection reaches the zone crash
    // handler. A missed flag costs a slower reconnect, never correctness.
    network_api
        .setRealtimeSessionActive(active: active)
        .catchError((Object _) {});
  }
}
