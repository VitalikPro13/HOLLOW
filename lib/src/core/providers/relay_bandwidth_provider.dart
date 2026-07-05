import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart'
    show formatBytes;
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// This connection's daily relay byte budget, as reported by the relay over
/// the authenticated WS (`request_relay_bandwidth()` →
/// `NetworkEvent.bandwidthStatus`). The counter lives in relay RAM only,
/// keyed per IP (v6 per /64), covers binary frames both directions, and
/// resets at the fixed UTC-day rollover.
class RelayBandwidth {
  final int usedBytes;
  final int budgetBytes;

  /// Local wall-clock deadline of the UTC-day reset, computed from the
  /// relay's `reset_in_secs` at receipt — immune to client clock skew.
  final DateTime? resetAt;

  /// True after the relay closed the connection with "bandwidth_limit".
  /// Cleared by the first status reply that shows headroom again (the next
  /// UTC day).
  final bool limited;

  const RelayBandwidth({
    this.usedBytes = 0,
    this.budgetBytes = 0,
    this.resetAt,
    this.limited = false,
  });

  bool get hasData => budgetBytes > 0;

  double get usagePercent =>
      budgetBytes > 0 ? (usedBytes / budgetBytes).clamp(0.0, 1.0) : 0.0;

  String get usageLabel =>
      '${formatBytes(usedBytes)} of ${formatBytes(budgetBytes)}';
}

/// Demand-driven (autoDispose, same model as [relayStatsProvider]): the
/// 30s request loop runs ONLY while a relay card actually watches this
/// provider. Each tick fire-and-forgets `request_relay_bandwidth()` over the
/// live WS; the reply lands via the event stream (event_provider dispatch →
/// [RelayBandwidthNotifier.onStatus]).
class RelayBandwidthNotifier extends AutoDisposeNotifier<RelayBandwidth> {
  Timer? _timer;

  static const _interval = Duration(seconds: 30);

  @override
  RelayBandwidth build() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _request());
    ref.onDispose(() => _timer?.cancel());
    // At app launch the card mounts BEFORE the relay WS is up — the first
    // request dies on "Node is not running" and the data only appeared at
    // the next 30s tick. Re-request the moment the relay (re)connects so
    // today's usage survives restarts without a visible gap.
    ref.listen<OverallConnection>(overallConnectionProvider, (prev, next) {
      if (next.isOnline && !(prev?.isOnline ?? false)) _request();
    });
    Future.microtask(_request);
    return const RelayBandwidth();
  }

  void _request() {
    // Skip while backgrounded — same lifecycle gate as the relay stats poll.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached) {
      return;
    }
    // Fire-and-forget FFI: a sync try/catch around an un-awaited Future
    // catches NOTHING — rejections need .catchError (node not running yet /
    // relay offline are both normal here; the card just shows no data).
    network_api.requestRelayBandwidth().catchError((_) {});
  }

  /// Called from event_provider on `NetworkEvent.bandwidthStatus`.
  void onStatus({
    required int usedBytes,
    required int budgetBytes,
    required int resetInSecs,
  }) {
    state = RelayBandwidth(
      usedBytes: usedBytes,
      budgetBytes: budgetBytes,
      resetAt: DateTime.now().toUtc().add(Duration(seconds: resetInSecs)),
      // A fresh status showing headroom clears a previous limit strike.
      limited: state.limited && usedBytes >= budgetBytes && budgetBytes > 0,
    );
  }

  /// Called from event_provider on `NetworkEvent.bandwidthLimited`.
  void onLimited() {
    state = RelayBandwidth(
      usedBytes: state.budgetBytes > 0 ? state.budgetBytes : state.usedBytes,
      budgetBytes: state.budgetBytes,
      resetAt: state.resetAt,
      limited: true,
    );
  }
}

final relayBandwidthProvider =
    NotifierProvider.autoDispose<RelayBandwidthNotifier, RelayBandwidth>(
        RelayBandwidthNotifier.new);
