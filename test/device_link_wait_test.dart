import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';

class _LinkApi implements RustLibApi {
  int requests = 0;
  String? kind;
  Completer<void>? pending;

  @override
  Future<void> crateApiNetworkResolveLinkCode(
      {required String code, required String kind}) async {
    requests++;
    this.kind = kind;
    await pending?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _LinkApi();
  setUpAll(() => RustLib.initMock(api: api));

  ProviderContainer container(OverallConnection connection) {
    final result = ProviderContainer(overrides: [
      overallConnectionProvider.overrideWithValue(connection),
    ]);
    addTearDown(result.dispose);
    return result;
  }

  test('offline link requests fail before reaching Rust', () async {
    final c = container(OverallConnection.offline);
    final before = api.requests;
    await c.read(deviceLinkSyncProvider.notifier).enterCode('ABC234');
    expect(api.requests, before);
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.failed);
    expect(c.read(deviceLinkSyncProvider).error, contains('not connected'));
  });

  testWidgets('an unanswered link times out across a transient disconnect', (tester) async {
    final c = container(OverallConnection.connected);
    final notifier = c.read(deviceLinkSyncProvider.notifier);
    await notifier.enterCode('ABC234');
    notifier.onDisconnected();
    await tester.pump(const Duration(seconds: 59));
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.waiting);
    await tester.pump(const Duration(seconds: 1));
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.failed);
    expect(c.read(deviceLinkSyncProvider).error, contains('fresh code'));
  });

  test('the request says only what kind of device this is', () async {
    final c = container(OverallConnection.connected);
    await c.read(deviceLinkSyncProvider.notifier).enterCode('ABC234');
    expect(api.kind, 'desktop');
    c.read(deviceLinkSyncProvider.notifier).reset();
  });

  testWidgets('progress cancels the waiting timeout', (tester) async {
    final c = container(OverallConnection.connected);
    final notifier = c.read(deviceLinkSyncProvider.notifier);
    await notifier.enterCode('ABC234');
    await tester.pump(const Duration(seconds: 40));
    notifier.onLinkProgress(12, 100);
    await tester.pump(const Duration(seconds: 60));
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.receiving);
  });

  test('a late failure from a canceled attempt cannot fail its retry', () async {
    final c = container(OverallConnection.connected);
    final notifier = c.read(deviceLinkSyncProvider.notifier);
    final first = Completer<void>();
    api.pending = first;
    final firstRequest = notifier.enterCode('ABC234');
    notifier.reset();
    api.pending = null;
    await notifier.enterCode('DEF567');
    first.completeError(StateError('old request failed'));
    await firstRequest;
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.waiting);
    expect(c.read(deviceLinkSyncProvider).code, 'DEF567');
    notifier.reset();
  });

  testWidgets('reset and retry get a fresh timeout', (tester) async {
    final c = container(OverallConnection.connected);
    final notifier = c.read(deviceLinkSyncProvider.notifier);
    await notifier.enterCode('ABC234');
    await tester.pump(const Duration(seconds: 40));
    notifier.reset();
    await notifier.enterCode('DEF567');
    await tester.pump(const Duration(seconds: 30));
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.waiting);
    notifier.reset();
    await tester.pump(const Duration(seconds: 60));
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.idle);
  });
}
