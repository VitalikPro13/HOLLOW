// A self-hosted relay may keep its online count and traffic private
// (PUBLIC_STATS=off): the app then shows no counter and no bandwidth bar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/network_section.dart';
import 'package:hollow/src/ui/settings/relay_health_card.dart';

class _FixedStats extends RelayStatsNotifier {
  _FixedStats(this.stats);
  final RelayStats stats;

  @override
  RelayStats build() => stats;
}

class _FixedRelayDomain extends RelayDomainNotifier {
  @override
  String build() => 'relay.example.org';
}

class _FixedRelayList extends SavedRelayListNotifier {
  @override
  List<String> build() => const ['relay.example.org'];
}

class _FixedRelayStatus extends RelayStatusNotifier {
  @override
  RelayStatus build() => const RelayStatus();
}

class _FixedAlwaysRelay extends AlwaysRelayCallsNotifier {
  @override
  bool build() => false;
}

RelayStats _stats({int? online, bool traffic = true}) => RelayStats(
      memTotalKb: 8000000,
      memUsedKb: 2000000,
      rxMbps: traffic ? 10 : 0,
      txMbps: traffic ? 20 : 0,
      hasTraffic: traffic,
      onlineUsers: online,
      fetchCount: 1,
      lastSuccessAt: DateTime.now(),
    );

Future<void> _pump(WidgetTester tester, Widget child, RelayStats stats) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        relayStatsProvider.overrideWith(() => _FixedStats(stats)),
        relayDomainProvider.overrideWith(_FixedRelayDomain.new),
        savedRelayListProvider.overrideWith(_FixedRelayList.new),
        relayStatusProvider.overrideWith(_FixedRelayStatus.new),
        alwaysRelayCallsProvider.overrideWith(_FixedAlwaysRelay.new),
        overallConnectionProvider.overrideWithValue(OverallConnection.connected),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

// RelayLoadBars runs a periodic sweep: unmount it before the test ends.
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

void main() {
  testWidgets('the relay card shows the count and bandwidth a relay reports',
      (tester) async {
    await _pump(tester, const RelayLoadBars(), _stats(online: 7));
    expect(find.text('RAM'), findsOneWidget);
    expect(find.text('Bandwidth'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a relay that keeps them private shows memory only',
      (tester) async {
    await _pump(
        tester, const RelayLoadBars(), _stats(online: null, traffic: false));
    expect(find.text('RAM'), findsOneWidget);
    expect(find.text('Bandwidth'), findsNothing);
    expect(find.text('Online'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('the relay row says how many people are online',
      (tester) async {
    await _pump(tester, const RelaySettingsSection(), _stats(online: 12));
    expect(find.textContaining('12 people online', findRichText: true),
        findsOneWidget);
  });

  testWidgets('and says nothing about it when the relay keeps it private',
      (tester) async {
    await _pump(tester, const RelaySettingsSection(),
        _stats(online: null, traffic: false));
    expect(find.textContaining('online', findRichText: true), findsNothing);
  });

  test('a body with the count and rates reads them', () {
    final s = RelayStats.fromServerStats(
        {'mem_total_kb': 8, 'mem_used_kb': 4, 'rx_mbps': 1.5, 'tx_mbps': 2,
         'bandwidth_cap_mbps': 950, 'online_users': 3},
        fetchCount: 1, at: DateTime.now());
    expect(s.onlineUsers, 3);
    expect(s.hasTraffic, isTrue);
  });

  test('a body without them leaves the count out and the traffic off', () {
    final s = RelayStats.fromServerStats(
        {'mem_total_kb': 8, 'mem_used_kb': 4, 'bandwidth_cap_mbps': 950},
        fetchCount: 1, at: DateTime.now());
    expect(s.onlineUsers, isNull);
    expect(s.hasTraffic, isFalse);
  });
}
