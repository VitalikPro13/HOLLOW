import '../../rust/api/network.dart' as network_api;

/// Tells the relay client whether a real-time session is live, so it can
/// reconnect fast enough to be useful to one.
///
/// ## Why this exists
///
/// The relay socket backs off exponentially toward thirty seconds when it
/// cannot connect. That is correct while the app is idle: the relay has no rate
/// limits by design, so a fleet of clients retrying hard at a relay that is
/// down is the relay's problem.
///
/// It is wrong during a call. Recovering a lapsed media link needs an ICE
/// restart, the offer carrying it rides that socket, and the call's hold-open
/// window is measured in tens of seconds. Field-caught 2026-08-27: a machine
/// lost its network for 25 seconds, the backoff had already climbed to a thirty
/// second sleep, and the socket did not try again until eleven seconds AFTER
/// the call had been given up on. The network had been back for twenty of them.
/// The user's internet was working and they sat watching "Reconnecting".
///
/// So the policy is conditional, not a lower cap for everyone: only clients
/// actually in a call retry fast, and only while they are in one.
///
/// ## Why it refcounts
///
/// DM calls and voice channels are mutually exclusive (issue #49) but
/// conferences and future surfaces need not be, and the failure mode of a plain
/// boolean is silent and bad: leaving one session clears the flag while another
/// is still running, and the next outage is slow to recover for no visible
/// reason. Holders are keyed, so the flag is true while ANY of them holds it.
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

  /// Declare that [key]'s session has ended. Safe to call when it never
  /// started, which matters because teardown paths run on failures too.
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
    // Fire-and-forget with .catchError, never a bare call: a sync try/catch
    // around an un-awaited Future catches nothing and the rejection would hit
    // the zone crash handler. A missed flag costs a slower reconnect, never
    // correctness, so swallowing is right here.
    network_api
        .setRealtimeSessionActive(active: active)
        .catchError((Object _) {});
  }
}
