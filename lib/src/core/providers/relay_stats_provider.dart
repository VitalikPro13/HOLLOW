import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class RelayStats {
  final int memTotalKb;
  final int memUsedKb;
  final double rxMbps;
  final double txMbps;
  final int bandwidthCapMbps;
  final int onlineUsers;
  final int fetchCount;

  const RelayStats({
    this.memTotalKb = 0,
    this.memUsedKb = 0,
    this.rxMbps = 0,
    this.txMbps = 0,
    this.bandwidthCapMbps = 400,
    this.onlineUsers = 0,
    this.fetchCount = 0,
  });

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

  static const _url = 'https://relay.anonlisten.com/server-stats';
  static const _interval = Duration(seconds: 7);

  @override
  RelayStats build() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _fetch());
    ref.onDispose(() {
      _timer?.cancel();
      _client.close();
    });
    // Fire initial fetch.
    Future.microtask(_fetch);
    return const RelayStats();
  }

  Future<void> _fetch() async {
    try {
      final request = await _client
          .getUrl(Uri.parse(_url))
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
        );
      }
    } catch (_) {
      // Silently keep last known state on failure.
    }
  }
}

final relayStatsProvider =
    NotifierProvider<RelayStatsNotifier, RelayStats>(RelayStatsNotifier.new);
