import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/network.dart' as network_api;
import '../providers/call_provider.dart';
import '../providers/conference_provider.dart';
import '../providers/connection_status_provider.dart';
import '../providers/member_panel_provider.dart';
import 'realtime_session_flag.dart';

/// A window back in focus probes only after this long away: a shorter absence
/// sits inside one heartbeat cycle (15 s beat, 10 s deadline, plan 9.5).
const kFocusNudgeMinAway = Duration(seconds: 30);

/// One network change arrives as several callbacks: a burst nudges at once and
/// again after this much quiet, so the settled path is probed too.
const kNudgeSettle = Duration(seconds: 1);

/// A phone closes its relay socket this long after it leaves the screen (plan
/// 9.9, Telegram's keep time); the relay holds the session meanwhile.
const kSuspendAfterBackground = Duration(seconds: 10);

/// iOS: the suspend starts at least this long before the background task runs
/// out, since it may take the client's whole 5 s bound (`SUSPEND_MAX`).
const kBackgroundTaskMargin = Duration(seconds: 6);

/// The nudge a real-time session sends when it needs the socket while the
/// phone is away (a call ringing in, a call kept alive). It ends a suspend.
const kCallNudge = 'call';

/// The nudge a push wake sends so a suspended session comes back for the live
/// node to collect what the push announced. Native code never forwards it.
const kPushNudge = 'push';

const _nativeReasons = {'network', 'wake'};

/// The time iOS keeps a backgrounded app running, so the suspend finishes
/// before the process freezes. Other platforms hold nothing.
abstract class RelayBackgroundTask {
  /// Holds a task; resolves to the time the OS still grants, null for no limit.
  Future<Duration?> begin();

  /// Lets the held task go. Safe without one.
  void end();

  /// [onExpiring] runs when the OS is about to end the task itself.
  void listen(void Function()? onExpiring);
}

class NoRelayBackgroundTask implements RelayBackgroundTask {
  const NoRelayBackgroundTask();

  @override
  Future<Duration?> begin() async => null;

  @override
  void end() {}

  @override
  void listen(void Function()? onExpiring) {}
}

/// `UIApplication.beginBackgroundTask`, held by AppDelegate.swift.
class IosRelayBackgroundTask implements RelayBackgroundTask {
  static const channelName = 'hollow/relay_background';
  static const _channel = MethodChannel(channelName);

  @override
  Future<Duration?> begin() async {
    try {
      final seconds = await _channel.invokeMethod<double>('begin');
      return seconds == null
          ? null
          : Duration(milliseconds: (seconds * 1000).round());
    } catch (_) {
      return null;
    }
  }

  @override
  void end() {
    _channel.invokeMethod<void>('end').catchError((Object _) {});
  }

  @override
  void listen(void Function()? onExpiring) {
    _channel.setMethodCallHandler(onExpiring == null
        ? null
        : (call) async {
            if (call.method == 'expiring') onExpiring();
          });
  }
}

/// A real-time session is live, a call is ringing in, or we wait in a meeting
/// lobby: the relay socket stays up and the phone visible, in the background too.
final relayRealtimeProvider = Provider<bool>((ref) {
  void changed() => ref.invalidateSelf();
  RealtimeSessionFlag.live.addListener(changed);
  ref.onDispose(() => RealtimeSessionFlag.live.removeListener(changed));
  final ringing = ref.watch(callProvider.select((s) =>
      s.status == CallStatus.ringing && s.direction == CallDirection.incoming));
  // A hidden phone drops out of the host's waiting list.
  final inLobby = ref.watch(conferenceProvider.select((s) =>
      s.lobbyStatus == ConferenceLobbyStatus.waiting ||
      s.lobbyStatus == ConferenceLobbyStatus.admitted));
  return ringing || inLobby || RealtimeSessionFlag.isActive;
});

/// Turns app foreground, window focus, network change and wake into
/// `relay_nudge`, and on phones closes the relay socket a while after the app
/// leaves the screen (plan 3.8). Native code only forwards events on
/// [channelName].
///
/// Away on a phone means hidden, paused or detached. `inactive` is still on
/// screen (the notification shade, the app switcher, a system or biometric
/// prompt, split screen without focus), and closing the socket there would cut
/// it under the person looking at the app.
class RelayTriggers with WidgetsBindingObserver {
  RelayTriggers({
    required this.phone,
    void Function(String reason)? nudge,
    void Function(bool background)? setBackground,
    Future<void> Function()? suspend,
    RelayBackgroundTask? backgroundTask,
    DateTime Function()? now,
    bool Function()? inCall,
    void Function(String line)? log,
  })  : _nudge = nudge ?? _ffiNudge,
        _setBackground = setBackground ?? _ffiSetBackground,
        _suspend = suspend ?? _ffiSuspend,
        _task = backgroundTask ??
            (Platform.isIOS
                ? IosRelayBackgroundTask()
                : const NoRelayBackgroundTask()),
        _now = now ?? DateTime.now,
        _inCall = inCall ?? (() => RealtimeSessionFlag.isActive),
        _log = log ?? _ffiLog;

  static const channelName = 'hollow/relay_triggers';

  /// Phones follow the app lifecycle; desktops nudge on window focus.
  final bool phone;

  final void Function(String reason) _nudge;
  final void Function(bool background) _setBackground;
  final Future<void> Function() _suspend;
  final RelayBackgroundTask _task;
  final DateTime Function() _now;

  /// A real-time session needs the socket: no suspend, and native events still
  /// nudge while away.
  final bool Function() _inCall;
  final void Function(String line) _log;
  final _channel = const MethodChannel(channelName);
  final _bursts = <String, _Burst>{};
  AppLifecycleState? _lifecycle;
  DateTime? _blurredAt;
  bool _started = false;

  bool _away = false;
  bool _realtime = false;

  /// The relay was told `relay_set_background(true)` since the phone left the screen.
  bool _toldAway = false;
  Timer? _suspendTimer;
  bool _taskHeld = false;

  void start() {
    if (_started) return;
    _started = true;
    final binding = WidgetsBinding.instance;
    _lifecycle = binding.lifecycleState;
    binding.addObserver(this);
    _channel.setMethodCallHandler(_onNativeEvent);
    if (!phone) return;
    _task.listen(_onTaskExpiring);
    _realtime = _inCall();
    // Launched behind the screen (an iOS background launch): the same rules.
    if (_isAway) _leave();
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    for (final burst in _bursts.values) {
      burst.timer.cancel();
    }
    _bursts.clear();
    if (phone) {
      _cancelSuspend();
      _task.listen(null);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (!phone || !_started || _isAway == _away) return;
    if (_isAway) {
      _leave();
    } else {
      _return();
    }
  }

  /// A real-time session started or ended, or a call began or stopped ringing.
  void onRealtimeChanged() {
    final live = _inCall();
    if (live == _realtime) return;
    _realtime = live;
    if (!phone || !_started || !_away) return;
    if (live) {
      _cancelSuspend();
      _log('[HOLLOW-RELAY-LIFE] a call needs the socket while away');
      _send(kCallNudge);
    } else {
      _tellAway();
      _armSuspend();
    }
  }

  /// The relay session is up again while the phone is away (a push woke it, or
  /// the node started behind the screen): it closes again
  /// [kSuspendAfterBackground] later.
  void onRelayConnected() {
    if (!phone || !_started || !_away) return;
    _armSuspend();
  }

  /// The window gained (true) or lost (false) OS focus. Desktop only.
  void onFocusChanged(bool focused) {
    if (phone) return;
    if (!focused) {
      _blurredAt ??= _now();
      return;
    }
    final blurredAt = _blurredAt;
    _blurredAt = null;
    if (blurredAt != null &&
        _now().difference(blurredAt) >= kFocusNudgeMinAway) {
      _fire('focus');
    }
  }

  /// Off the screen: the relay hears it at once (hidden from others' presence,
  /// slower heartbeat), and the socket closes later. A phone in a real-time
  /// session is still in use: it stays shown and connected until that ends.
  void _leave() {
    _away = true;
    // A session the wiring has not reported yet counts too.
    _realtime = _inCall();
    if (!_realtime) _tellAway();
    _armSuspend();
  }

  void _tellAway() {
    if (_toldAway) return;
    _toldAway = true;
    _log('[HOLLOW-RELAY-LIFE] background: inactive');
    _setBackground(true);
  }

  /// Back on the screen. `relay_set_background(false)` ends a suspend and
  /// probes: it is the phone's one foreground probe, so nothing nudges beside it.
  void _return() {
    _away = false;
    _toldAway = false;
    _cancelSuspend();
    _log('[HOLLOW-RELAY-LIFE] foreground: active');
    _setBackground(false);
  }

  /// Callers have checked that the phone is away.
  void _armSuspend() {
    if (_suspendTimer != null || _inCall()) return;
    final timer = Timer(kSuspendAfterBackground, _suspendNow);
    _suspendTimer = timer;
    // The grant is read a platform round trip after the timer started, which
    // the margin covers.
    _holdTask().then((granted) {
      if (granted == null || !identical(_suspendTimer, timer)) return;
      final beforeExpiry = granted - kBackgroundTaskMargin;
      if (beforeExpiry >= kSuspendAfterBackground) return;
      timer.cancel();
      _suspendTimer = Timer(
          beforeExpiry.isNegative ? Duration.zero : beforeExpiry, _suspendNow);
    });
  }

  Future<void> _suspendNow() async {
    _suspendTimer = null;
    // A session the wiring has not reported yet still holds the socket.
    if (_inCall()) {
      _releaseTask();
      return;
    }
    _log('[HOLLOW-RELAY-LIFE] suspend');
    try {
      await _suspend();
    } catch (_) {}
    // Only now: iOS may freeze the app the moment the task ends.
    if (_suspendTimer == null) _releaseTask();
  }

  /// iOS ends the task itself right after this, so the suspend goes now.
  void _onTaskExpiring() {
    final timer = _suspendTimer;
    if (timer == null) return;
    timer.cancel();
    _log('[HOLLOW-RELAY-LIFE] background task expiring');
    _suspendNow();
  }

  void _cancelSuspend() {
    _suspendTimer?.cancel();
    _suspendTimer = null;
    _releaseTask();
  }

  Future<Duration?> _holdTask() {
    if (_taskHeld) return Future.value(null);
    _taskHeld = true;
    return _task.begin().catchError((Object _) => null);
  }

  void _releaseTask() {
    if (!_taskHeld) return;
    _taskHeld = false;
    _task.end();
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    final reason = call.method;
    if (!_nativeReasons.contains(reason)) return;
    // A backgrounded phone keeps its socket only for a call; otherwise the
    // foreground probes on return.
    if (phone && _isAway && !_inCall()) return;
    _fire(reason);
  }

  bool get _isAway => switch (_lifecycle) {
        AppLifecycleState.paused ||
        AppLifecycleState.hidden ||
        AppLifecycleState.detached =>
          true,
        _ => false,
      };

  /// Leading nudge, plus one trailing nudge if the burst repeated.
  void _fire(String reason) {
    if (!_started) return;
    final burst = _bursts[reason];
    if (burst == null) {
      _send(reason);
      _bursts[reason] = _Burst(Timer(kNudgeSettle, () => _settle(reason)));
      return;
    }
    burst.repeated = true;
    burst.timer.cancel();
    burst.timer = Timer(kNudgeSettle, () => _settle(reason));
  }

  void _settle(String reason) {
    final burst = _bursts.remove(reason);
    if (burst != null && burst.repeated) _send(reason);
  }

  void _send(String reason) {
    debugPrint('[HOLLOW-NUDGE] $reason');
    _nudge(reason);
  }

  // The FFI defaults: RustLib not loaded (widget tests) throws synchronously,
  // and an un-awaited rejection needs its own catchError.
  static void _ffiNudge(String reason) {
    try {
      network_api.relayNudge(reason: reason).catchError((Object _) {});
    } catch (_) {}
  }

  static void _ffiSetBackground(bool background) {
    try {
      network_api
          .relaySetBackground(background: background)
          .catchError((Object _) {});
    } catch (_) {}
  }

  static Future<void> _ffiSuspend() async {
    try {
      await network_api.relaySuspend();
    } catch (_) {}
  }

  static void _ffiLog(String line) {
    debugPrint(line);
    try {
      network_api.logFromDart(message: line).catchError((Object _) {});
    } catch (_) {}
  }
}

class _Burst {
  _Burst(this.timer);
  Timer timer;
  bool repeated = false;
}

/// The app's one [RelayTriggers], started by the shell.
final relayTriggersProvider = Provider<RelayTriggers>((ref) => wireRelayTriggers(
    ref,
    RelayTriggers(
      phone: Platform.isAndroid || Platform.isIOS,
      inCall: () => ref.read(relayRealtimeProvider),
    )));

/// Feeds window focus, real-time sessions and the relay status to [triggers],
/// starts it and ties it to [ref].
RelayTriggers wireRelayTriggers(Ref ref, RelayTriggers triggers) {
  ref.listen<bool>(
      windowFocusedProvider, (_, focused) => triggers.onFocusChanged(focused));
  ref.listen<bool>(relayRealtimeProvider, (_, _) => triggers.onRealtimeChanged());
  ref.listen<RelayConnectionStatus>(
      connectionStatusProvider.select((s) => s.relayStatus), (_, status) {
    if (status == RelayConnectionStatus.connected) triggers.onRelayConnected();
  });
  ref.onDispose(triggers.dispose);
  return triggers..start();
}
