import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/services/link_keep_alive.dart';
import 'package:hollow/src/core/services/relay_triggers.dart';

class _Phase extends DeviceLinkSyncNotifier {
  @override
  DeviceLinkState build() => const DeviceLinkState();

  void go(LinkPhase phase) => state = DeviceLinkState(phase: phase);
}

String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  ProviderContainer container() {
    final c = ProviderContainer(overrides: [deviceLinkSyncProvider.overrideWith(_Phase.new)]);
    addTearDown(c.dispose);
    return c;
  }

  test('a phone holds the network only while it presents a link', () {
    const presenting = {
      LinkPhase.showingCode,
      LinkPhase.renewingCode,
      LinkPhase.confirmPush,
      LinkPhase.sending,
    };
    final c = container();
    for (final phase in LinkPhase.values) {
      (c.read(deviceLinkSyncProvider.notifier) as _Phase).go(phase);
      expect(c.read(linkPresentingProvider), presenting.contains(phase), reason: '$phase');
      expect(c.read(relayRealtimeProvider), presenting.contains(phase), reason: '$phase');
    }
  });

  test('the keep-alive starts once and stops once per link', () async {
    final calls = <String>[];
    final c = container();
    final keepAlive = LinkKeepAlive(enabled: true, invoke: (m) async => calls.add(m));
    final sub = c.listen(linkPresentingProvider, (_, p) => keepAlive.hold(p), fireImmediately: true);
    addTearDown(sub.close);
    final phase = c.read(deviceLinkSyncProvider.notifier) as _Phase;
    Future<void> go(LinkPhase p) async {
      phase.go(p);
      await c.pump();
    }

    await go(LinkPhase.showingCode);
    await go(LinkPhase.confirmPush);
    await go(LinkPhase.sending);
    await go(LinkPhase.pushDone);
    await go(LinkPhase.idle);
    expect(calls, ['start', 'stop']);

    await go(LinkPhase.showingCode);
    keepAlive.hold(false);
    expect(calls, ['start', 'stop', 'start', 'stop']);
  });

  test('the app\'s keep-alive asks Android over its channel while a link is presented', () async {
    final messenger = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
    const channel = MethodChannel(LinkKeepAlive.channelName);
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final c = ProviderContainer(overrides: [
      deviceLinkSyncProvider.overrideWith(_Phase.new),
      linkKeepAliveSupportedProvider.overrideWithValue(true),
    ]);
    c.read(linkKeepAliveProvider);
    final phase = c.read(deviceLinkSyncProvider.notifier) as _Phase;
    Future<void> settle() async {
      await c.pump();
      await Future<void>.delayed(Duration.zero);
    }

    phase.go(LinkPhase.showingCode);
    await settle();
    expect(calls, ['start']);
    phase.go(LinkPhase.idle);
    await settle();
    expect(calls, ['start', 'stop']);

    // An app torn down mid-link lets go of the service too.
    phase.go(LinkPhase.renewingCode);
    await settle();
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start', 'stop', 'start', 'stop']);
  });

  test('a platform without the service is never asked', () {
    final calls = <String>[];
    final keepAlive = LinkKeepAlive(enabled: false, invoke: (m) async => calls.add(m));
    keepAlive.hold(true);
    keepAlive.hold(false);
    expect(calls, isEmpty);
  });

  test('Android runs a short foreground service on the keep-alive channel', () {
    final activity = _read('android/app/src/main/kotlin/com/anonlisten/hollow/MainActivity.kt');
    expect(activity, contains('"${LinkKeepAlive.channelName}"'));
    expect(activity, contains('"start"'));
    expect(activity, contains('"stop"'));
    final service = _read('android/app/src/main/kotlin/com/anonlisten/hollow/LinkKeepAliveService.kt');
    expect(service, contains('FOREGROUND_SERVICE_TYPE_SHORT_SERVICE'));
    // A short service that outlives its time limit crashes the app: Android 14 calls the
    // first, 15 and later the second.
    expect(service, contains('override fun onTimeout(startId: Int) {'));
    expect(service, contains('override fun onTimeout(startId: Int, fgsType: Int) {'));
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android:name=".LinkKeepAliveService"'));
    expect(manifest, contains('android:foregroundServiceType="shortService"'));
  });
}
