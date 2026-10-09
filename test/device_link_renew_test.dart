import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';

class _ClaimApi implements RustLibApi {
  final claims = <String>[];
  int releases = 0;

  @override
  Future<void> crateApiNetworkClaimLinkCode(
      {required String rendezvous, required String secret}) async {
    claims.add(rendezvous + secret);
  }

  @override
  Future<void> crateApiNetworkReleaseLinkCode() async => releases++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _link = StateProvider<OverallConnection>((ref) => OverallConnection.connected);

void main() {
  final api = _ClaimApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.claims.clear();
    api.releases = 0;
  });

  ProviderContainer container([OverallConnection start = OverallConnection.connected]) {
    final c = ProviderContainer(overrides: [
      _link.overrideWith((ref) => start),
      overallConnectionProvider.overrideWith((ref) => ref.watch(_link)),
    ]);
    addTearDown(c.dispose);
    // Keep the provider alive and listening, as the dialog does.
    c.listen(deviceLinkSyncProvider, (_, _) {});
    return c;
  }

  DeviceLinkState read(ProviderContainer c) => c.read(deviceLinkSyncProvider);

  // The relay dropped the session, so its claim on the code is gone.
  Future<void> loseSession(WidgetTester tester, ProviderContainer c) async {
    c.read(deviceLinkSyncProvider.notifier).onDisconnected();
    c.read(_link.notifier).state = OverallConnection.reconnecting;
    await tester.pump();
  }

  // `RelayConnected`, delivered after the status moved, as event_provider does.
  Future<void> relayBack(WidgetTester tester, ProviderContainer c) async {
    c.read(_link.notifier).state = OverallConnection.connected;
    c.read(deviceLinkSyncProvider.notifier).onRelayConnected();
    await tester.pump();
  }

  testWidgets('a lost session renews the code, never shows a dead one', (tester) async {
    final c = container();
    await c.read(deviceLinkSyncProvider.notifier).startShowingCode();
    final first = read(c).code;
    await tester.pump(const Duration(seconds: 10));
    expect(read(c).countdownSeconds, 290);

    await loseSession(tester, c);
    expect(read(c).phase, LinkPhase.renewingCode);
    expect(read(c).code, isNull, reason: 'the relay forgot this code');

    // No countdown runs while there is no code.
    await tester.pump(const Duration(seconds: 30));
    expect(read(c).phase, LinkPhase.renewingCode);
    expect(api.claims, hasLength(1), reason: 'nothing is claimed while offline');

    await relayBack(tester, c);
    expect(read(c).phase, LinkPhase.showingCode);
    expect(read(c).code, isNot(first), reason: 'a fresh code');
    expect(read(c).countdownSeconds, 300);
    expect(api.claims, [first, read(c).code]);
    c.read(deviceLinkSyncProvider.notifier).reset();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('every failed reconnect keeps renewing, one claim once back', (tester) async {
    final c = container();
    await c.read(deviceLinkSyncProvider.notifier).startShowingCode();
    await loseSession(tester, c);
    c.read(deviceLinkSyncProvider.notifier).onDisconnected();
    c.read(deviceLinkSyncProvider.notifier).onDisconnected();
    expect(read(c).phase, LinkPhase.renewingCode);
    await relayBack(tester, c);
    expect(api.claims, hasLength(2));
    c.read(deviceLinkSyncProvider.notifier).reset();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a resumed session keeps the same code and its countdown', (tester) async {
    final c = container();
    await c.read(deviceLinkSyncProvider.notifier).startShowingCode();
    final code = read(c).code;
    await tester.pump(const Duration(seconds: 5));
    // Suspended then resumed: the relay held the claim, no RelayDisconnected.
    c.read(_link.notifier).state = OverallConnection.reconnecting;
    await tester.pump(const Duration(seconds: 5));
    await relayBack(tester, c);
    expect(read(c).phase, LinkPhase.showingCode);
    expect(read(c).code, code);
    expect(read(c).countdownSeconds, 290);
    expect(api.claims, hasLength(1));
    c.read(deviceLinkSyncProvider.notifier).reset();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a lost session during the confirm prompt renews too', (tester) async {
    final c = container();
    final n = c.read(deviceLinkSyncProvider.notifier);
    await n.startShowingCode();
    n.onSiblingLinkAvailable('dev2', 1, 1, true);
    await loseSession(tester, c);
    expect(read(c).phase, LinkPhase.renewingCode);
    n.reset();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('opened while offline, the code waits for the relay', (tester) async {
    final c = container(OverallConnection.connecting);
    await c.read(deviceLinkSyncProvider.notifier).startShowingCode();
    expect(read(c).phase, LinkPhase.renewingCode);
    expect(api.claims, isEmpty);
    c.read(_link.notifier).state = OverallConnection.connected;
    await tester.pump();
    expect(read(c).phase, LinkPhase.showingCode);
    expect(api.claims, hasLength(1));
    c.read(deviceLinkSyncProvider.notifier).reset();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the countdown ends in an expired code, released', (tester) async {
    final c = container();
    await c.read(deviceLinkSyncProvider.notifier).startShowingCode();
    await tester.pump(const Duration(seconds: 299));
    expect(read(c).phase, LinkPhase.showingCode);
    await tester.pump(const Duration(seconds: 1));
    expect(read(c).phase, LinkPhase.codeExpired);
    expect(read(c).code, isNull);
    expect(api.releases, 1);
    // A dead countdown never comes back to life.
    await tester.pump(const Duration(seconds: 10));
    expect(read(c).countdownSeconds, 0);
    c.read(deviceLinkSyncProvider.notifier).reset();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('cancelling stops the countdown', (tester) async {
    final c = container();
    await c.read(deviceLinkSyncProvider.notifier).startShowingCode();
    await c.read(deviceLinkSyncProvider.notifier).cancelShowingCode();
    await tester.pump(const Duration(seconds: 400));
    expect(read(c).phase, LinkPhase.idle);
    expect(api.releases, 1);
  });
}
