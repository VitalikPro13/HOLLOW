import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/rust/api/network.dart';

import 'helpers/test_app.dart';

/// Resumable relay sessions (RESUMABLE_SESSIONS_PLAN.md 3.7): the indicator reads the
/// session. Reconnecting while it is held (nothing is lost), Connected once it is
/// back, Offline only when it is gone and nothing replaced it, and no flicker while
/// attempts come and go. Driven by the node's relay events, as the event stream
/// hands them over.
void main() {
  const connected = NetworkEvent.relayConnected();
  const suspended = NetworkEvent.relaySuspended();
  const lost = NetworkEvent.relayDisconnected();
  NetworkEvent attempt({required bool reconnecting}) =>
      NetworkEvent.relayConnecting(reconnecting: reconnecting);

  ProviderContainer containerFor() {
    final container = ProviderContainer(overrides: hollowTestOverrides());
    addTearDown(container.dispose);
    return container;
  }

  OverallConnection overall(ProviderContainer c) => c.read(overallConnectionProvider);

  testWidgets('a held session reads Reconnecting and a resume Connected, '
      'with every attempt in between changing nothing', (tester) async {
    final c = containerFor();
    final relay = c.read(connectionStatusProvider.notifier);
    expect(overall(c), OverallConnection.connecting);

    relay.onRelayEvent(connected);
    expect(overall(c), OverallConnection.connected);

    relay.onRelayEvent(suspended);
    expect(overall(c), OverallConnection.reconnecting);
    relay.onRelayEvent(attempt(reconnecting: false));
    expect(overall(c), OverallConnection.reconnecting,
        reason: 'an attempt must not flip a held session to Connecting');
    relay.onRelayEvent(attempt(reconnecting: true));
    await tester.pump(const Duration(seconds: 30));
    expect(overall(c), OverallConnection.reconnecting,
        reason: 'a held session never times out into Offline on its own');

    relay.onRelayEvent(connected);
    expect(overall(c), OverallConnection.connected);
    // Riverpod refreshes dependents on a zero timer, which only elapsed time fires.
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a lost session that a fresh one replaces never shows Offline',
      (tester) async {
    final c = containerFor();
    final relay = c.read(connectionStatusProvider.notifier);
    relay.onRelayEvent(connected);

    relay.onRelayEvent(suspended);
    relay.onRelayEvent(lost);
    expect(overall(c), OverallConnection.reconnecting);
    await tester.pump(ConnectionStatusNotifier.offlineGrace -
        const Duration(milliseconds: 500));
    expect(overall(c), OverallConnection.reconnecting);
    relay.onRelayEvent(connected);
    await tester.pump(const Duration(seconds: 10));
    expect(overall(c), OverallConnection.connected,
        reason: 'the grace timer must die with the fresh session');
  });

  testWidgets('a lost session with nothing behind it goes Offline once, and '
      'stays there through every failed attempt', (tester) async {
    final c = containerFor();
    final relay = c.read(connectionStatusProvider.notifier);
    relay.onRelayEvent(connected);

    relay.onRelayEvent(lost);
    expect(overall(c), OverallConnection.reconnecting);
    await tester.pump(ConnectionStatusNotifier.offlineGrace);
    expect(overall(c), OverallConnection.offline);

    for (var i = 0; i < 3; i++) {
      relay.onRelayEvent(attempt(reconnecting: true));
      expect(overall(c), OverallConnection.offline,
          reason: 'attempt $i flickered off Offline');
      relay.onRelayEvent(lost);
      await tester.pump(const Duration(seconds: 5));
      expect(overall(c), OverallConnection.offline);
    }

    relay.onRelayEvent(connected);
    expect(overall(c), OverallConnection.connected);
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a held session that outlasts the relay grace reads Offline, '
      'measured from the first suspension', (tester) async {
    final c = containerFor();
    final relay = c.read(connectionStatusProvider.notifier);
    relay.onRelayEvent(connected);

    relay.onRelayEvent(suspended);
    await tester.pump(ConnectionStatusNotifier.outageOffline -
        const Duration(seconds: 10));
    relay.onRelayEvent(suspended);
    relay.onRelayEvent(attempt(reconnecting: true));
    expect(overall(c), OverallConnection.reconnecting);
    await tester.pump(const Duration(seconds: 10));
    expect(overall(c), OverallConnection.offline,
        reason: 'a second suspension must not restart the outage clock');

    relay.onRelayEvent(connected);
    expect(overall(c), OverallConnection.connected);
    relay.onRelayEvent(suspended);
    await tester.pump(ConnectionStatusNotifier.outageOffline -
        const Duration(seconds: 1));
    expect(overall(c), OverallConnection.reconnecting,
        reason: 'a resume must reset the outage clock');
    relay.onRelayEvent(connected);
    await tester.pump(const Duration(seconds: 5));
    expect(overall(c), OverallConnection.connected,
        reason: 'the outage timer must die with the resume');
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a first connect that fails reads Connecting, then Offline',
      (tester) async {
    final c = containerFor();
    final relay = c.read(connectionStatusProvider.notifier);
    relay.onRelayEvent(attempt(reconnecting: false));
    relay.onRelayEvent(lost);
    expect(overall(c), OverallConnection.connecting);
    await tester.pump(ConnectionStatusNotifier.offlineGrace);
    expect(overall(c), OverallConnection.offline);
    await tester.pump(const Duration(milliseconds: 1));
  });
}
