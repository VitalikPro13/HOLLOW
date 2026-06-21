import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';

class RelayStats {
  final int memTotalKb;
  final int memUsedKb;
  final double rxMbps;
  final double txMbps;
  final int bandwidthCapMbps;
  final int onlineUsers;
  final int fetchCount;

  /// Wall-clock time of the last SUCCESSFUL fetch. Null until the first one
  /// lands. Drives [isFresh] — the relay dot must reflect current reachability,
  /// not "has ever connected".
  final DateTime? lastSuccessAt;

  const RelayStats({
    this.memTotalKb = 0,
    this.memUsedKb = 0,
    this.rxMbps = 0,
    this.txMbps = 0,
    this.bandwidthCapMbps = 400,
    this.onlineUsers = 0,
    this.fetchCount = 0,
    this.lastSuccessAt,
  });

  /// True iff a fetch succeeded recently. The poll interval is 7s, so ~3 missed
  /// polls (20s) means the relay is unreachable (offline / no internet).
  bool get isFresh =>
      lastSuccessAt != null &&
      DateTime.now().difference(lastSuccessAt!) < const Duration(seconds: 20);

  double get memUsagePercent =>
      memTotalKb > 0 ? (memUsedKb / memTotalKb).clamp(0.0, 1.0) : 0.0;

  double get bandwidthUsagePercent {
    final total = rxMbps + txMbps;
    return bandwidthCapMbps > 0
        ? (total / bandwidthCapMbps).clamp(0.0, 1.0)
        : 0.0;
  }

  String get memLabel {
    final usedMb = memUsedKb / 1024;
    final totalMb = memTotalKb / 1024;
    return '${usedMb.toStringAsFixed(0)} / ${totalMb.toStringAsFixed(0)} MB';
  }

  String get bandwidthLabel {
    final total = rxMbps + txMbps;
    return '${total.toStringAsFixed(1)} / $bandwidthCapMbps Mbps';
  }
}

class RelayStatsNotifier extends Notifier<RelayStats> {
  Timer? _timer;
  final HttpClient _client = HttpClient();

  static const _interval = Duration(seconds: 7);

  @override
  RelayStats build() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _fetch());
    ref.onDispose(() {
      _timer?.cancel();
      _client.close();
    });
    Future.microtask(_fetch);
    return const RelayStats();
  }

  Future<void> _fetch() async {
    try {
      final domain = ref.read(relayDomainProvider);
      final url = 'https://$domain/server-stats';
      final request = await _client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        state = RelayStats(
          memTotalKb: (json['mem_total_kb'] as num?)?.toInt() ?? 0,
          memUsedKb: (json['mem_used_kb'] as num?)?.toInt() ?? 0,
          rxMbps: (json['rx_mbps'] as num?)?.toDouble() ?? 0,
          txMbps: (json['tx_mbps'] as num?)?.toDouble() ?? 0,
          bandwidthCapMbps:
              (json['bandwidth_cap_mbps'] as num?)?.toInt() ?? 400,
          onlineUsers: (json['online_users'] as num?)?.toInt() ?? 0,
          fetchCount: state.fetchCount + 1,
          lastSuccessAt: DateTime.now(),
        );
      }
    } catch (_) {
      // Keep last known stats on failure, but re-emit so `isFresh` recomputes
      // — otherwise the dot would stay green forever after connectivity drops
      // (a failed poll never produces a new state on its own).
      state = RelayStats(
        memTotalKb: state.memTotalKb,
        memUsedKb: state.memUsedKb,
        rxMbps: state.rxMbps,
        txMbps: state.txMbps,
        bandwidthCapMbps: state.bandwidthCapMbps,
        onlineUsers: state.onlineUsers,
        fetchCount: state.fetchCount,
        lastSuccessAt: state.lastSuccessAt,
      );
    }
  }
}

final relayStatsProvider =
    NotifierProvider<RelayStatsNotifier, RelayStats>(RelayStatsNotifier.new);
