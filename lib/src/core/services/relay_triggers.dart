import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/network.dart' as network_api;
import '../providers/member_panel_provider.dart';
import 'realtime_session_flag.dart';

/// A window back in focus probes only after this long away: a shorter absence
/// sits inside one heartbeat cycle (15 s beat, 10 s deadline, plan 9.5).
const kFocusNudgeMinAway = Duration(seconds: 30);

/// One network change arrives as several callbacks: a burst nudges at once and
/// again after this much quiet, so the settled path is probed too.
const kNudgeSettle = Duration(seconds: 1);

const _nativeReasons = {'network', 'wake'};

/// Turns app foreground, window focus, network change and wake into
/// `relay_nudge`. Native code only forwards events on [channelName].
class RelayTriggers with WidgetsBindingObserver {
  RelayTriggers({
    required this.phone,
    void Function(String reason)? nudge,
    DateTime Function()? now,
    bool Function()? inCall,
  })  : _nudge = nudge ?? _ffiNudge,
        _now = now ?? DateTime.now,
        _inCall = inCall ?? (() => RealtimeSessionFlag.isActive);

  static const channelName = 'hollow/relay_triggers';

  /// Phones nudge on app foreground; desktops on window focus.
  final bool phone;

  final void Function(String reason) _nudge;
  final DateTime Function() _now;
  final bool Function() _inCall;
  final _channel = const MethodChannel(channelName);
  final _bursts = <String, _Burst>{};
  AppLifecycleState? _lifecycle;
  DateTime? _blurredAt;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    final binding = WidgetsBinding.instance;
    _lifecycle = binding.lifecycleState;
    binding.addObserver(this);
    _channel.setMethodCallHandler(_onNativeEvent);
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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (phone && state == AppLifecycleState.resumed) _fire('foreground');
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

  Future<void> _onNativeEvent(MethodCall call) async {
    final reason = call.method;
    if (!_nativeReasons.contains(reason)) return;
    // A backgrounded phone keeps its socket only for a call; otherwise the
    // foreground nudge probes on return.
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

  static void _ffiNudge(String reason) {
    try {
      network_api.relayNudge(reason: reason).catchError((Object _) {});
    } catch (_) {
      // RustLib not loaded (widget tests) throws synchronously.
    }
  }
}

class _Burst {
  _Burst(this.timer);
  Timer timer;
  bool repeated = false;
}

/// The app's one [RelayTriggers], started by the shell.
final relayTriggersProvider = Provider<RelayTriggers>((ref) => wireRelayTriggers(
    ref, RelayTriggers(phone: Platform.isAndroid || Platform.isIOS)));

/// Feeds window focus to [triggers], starts it and ties it to [ref].
RelayTriggers wireRelayTriggers(Ref ref, RelayTriggers triggers) {
  ref.listen<bool>(
      windowFocusedProvider, (_, focused) => triggers.onFocusChanged(focused));
  ref.onDispose(triggers.dispose);
  return triggers..start();
}
