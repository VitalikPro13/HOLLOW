import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import '../integration_test/probe/probe_relay_guard.dart';

/// The probe's production relay guard (scripts/fleet_relay_guard.ps1 is the
/// tooling half): every way a probe peer could reach the official relay is
/// refused before the dial.
void main() {
  final api = _Api();
  late Directory out;

  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.reset();
    out = Directory.systemTemp.createTempSync('relay-guard-');
  });
  tearDown(() => out.deleteSync(recursive: true));

  final refusals = <String>[];
  ProbeRelayGuard guardWith({bool allow = false, String? expect}) {
    refusals.clear();
    return ProbeRelayGuard(
      outDir: out.path,
      allowProduction: allow,
      expect: expect,
      dataDir: out.path,
      onRefuse: (where, reason) => refusals.add('$where: $reason'),
    );
  }

  Map<String, dynamic> marker() => jsonDecode(
      File('${out.path}/relay_guard.json').readAsStringSync()) as Map<String, dynamic>;

  group('production names', () {
    test('every spelling of the official relay is refused', () {
      for (final d in [
        'relay.anonlisten.com',
        'RELAY.ANONLISTEN.COM.',
        'wss://relay.anonlisten.com/ws',
        'relay.anonlisten.com:443',
        'anonlisten.com',
        'canary.relay.anonlisten.com',
        '141.227.186.209',
        '[2001:41d0:ab01::4:0:d]:443',
        '::ffff:141.227.186.209',
        '',
      ]) {
        expect(productionReason(d), isNotNull, reason: d);
      }
    });

    test('test relays and look-alikes pass', () {
      for (final d in [
        'hollowtest.duckdns.org',
        'hollowtest.duckdns.org:8443',
        'anonlisten.com.evil.example',
        'notanonlisten.com',
        '192.168.18.2',
      ]) {
        expect(productionReason(d), isNull, reason: d);
      }
    });

    test('an unstamped data directory means the official relay', () {
      expect(relayVerdict(kProbeUnstampedRelay)?.production, isTrue);
    });

    test('a relay other than the expected one is refused, opt-in or not', () {
      final v = relayVerdict('other.example', expect: 'hollowtest.duckdns.org');
      expect(v?.production, isFalse);
      expect(relayVerdict('HOLLOWTEST.duckdns.org.',
          expect: 'hollowtest.duckdns.org'), isNull);
    });

    test('only the relay itself is an http refusal, not the website or shop', () {
      expect(httpProductionReason(Uri.parse('https://relay.anonlisten.com/relay-status')),
          isNotNull);
      expect(httpProductionReason(Uri.parse('https://141.227.186.209/x')), isNotNull);
      expect(httpProductionReason(Uri.parse('https://canary.anonlisten.com/relay-status')),
          isNotNull);
      expect(httpProductionReason(Uri.parse('https://hollow.anonlisten.com/gifs/m/x.webp')),
          isNull);
      expect(httpProductionReason(Uri.parse('https://shop.anonlisten.com/')), isNull);
      expect(httpProductionReason(Uri.parse('https://hollowtest.duckdns.org/relay-status')),
          isNull);
    });
  });

  group('the relay setting', () {
    test("a probe's default relay is never the official one", () {
      final c = ProviderContainer(overrides: guardWith().overrides);
      addTearDown(c.dispose);
      expect(c.read(relayDomainProvider), kProbeUnstampedRelay);
    });

    test('a loaded official relay is refused before anything reads it', () async {
      api.settings['relay_domain'] = 'relay.anonlisten.com';
      final c = ProviderContainer(overrides: guardWith().overrides);
      addTearDown(c.dispose);
      await expectLater(c.read(relayDomainProvider.notifier).loadCached(),
          throwsA(isA<RelayGuardRefusal>()));
      expect(refusals.single, startsWith('relay setting'));
      expect(marker()['verdict'], 'refused');
    });

    test('a loaded relay that is not the run\'s is refused', () async {
      api.settings['relay_domain'] = 'stale.example';
      final c = ProviderContainer(
          overrides: guardWith(expect: 'hollowtest.duckdns.org').overrides);
      addTearDown(c.dispose);
      await expectLater(c.read(relayDomainProvider.notifier).loadCached(),
          throwsA(isA<RelayGuardRefusal>()));
    });

    test('no stored relay leaves the unstamped default for node start to refuse',
        () async {
      final c = ProviderContainer(overrides: guardWith().overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).loadCached();
      expect(refusals, isEmpty);
      expect(c.read(relayDomainProvider), kProbeUnstampedRelay);
    });

    test('choosing the official relay is refused and never saved', () async {
      final c = ProviderContainer(overrides: guardWith().overrides);
      addTearDown(c.dispose);
      await expectLater(
          c.read(relayDomainProvider.notifier).setDomain('relay.anonlisten.com'),
          throwsA(isA<RelayGuardRefusal>()));
      expect(api.settings.containsKey('relay_domain'), isFalse);
      expect(refusals.single, startsWith('relay change'));
    });

    test('a test relay loads and saves untouched', () async {
      api.settings['relay_domain'] = 'hollowtest.duckdns.org';
      final c = ProviderContainer(
          overrides: guardWith(expect: 'hollowtest.duckdns.org').overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).loadCached();
      await c.read(relayDomainProvider.notifier).setDomain('hollowtest.duckdns.org');
      expect(refusals, isEmpty);
      expect(api.settings['relay_domain'], 'hollowtest.duckdns.org');
    });

    test('a relay switch between the run\'s test relays passes and restamps',
        () async {
      api.settings['relay_domain'] = 'a.test.example';
      final c = ProviderContainer(
          overrides: guardWith(expect: 'a.test.example, B.test.example.').overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).loadCached();
      await c.read(relayDomainProvider.notifier).setDomain('b.test.example');
      expect(refusals, isEmpty);
      expect(c.read(relayDomainProvider), 'b.test.example');
      expect(File('${out.path}/$kFleetRelayStampFile').readAsStringSync().trim(),
          'b.test.example');
      await expectLater(
          c.read(relayDomainProvider.notifier).setDomain('c.test.example'),
          throwsA(isA<RelayGuardRefusal>()));
      expect(api.settings['relay_domain'], 'b.test.example');
    });

    test('a switch saved for the next launch is judged and restamps, and the '
        'launch takes it', () async {
      api.settings['relay_domain'] = 'a.test.example';
      final c = ProviderContainer(
          overrides: guardWith(expect: 'a.test.example, b.test.example').overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).loadCached();
      await expectLater(
          c.read(relayDomainProvider.notifier)
              .saveForNextLaunch('relay.anonlisten.com'),
          throwsA(isA<RelayGuardRefusal>()));
      expect(api.settings['relay_domain_next'], isNull);

      await c.read(relayDomainProvider.notifier).saveForNextLaunch('b.test.example');
      expect(api.settings['relay_domain'], 'a.test.example');
      expect(File('${out.path}/$kFleetRelayStampFile').readAsStringSync().trim(),
          'b.test.example',
          reason: 'the tooling judges the next launch by the stamp');
      // Taking it back stamps the running relay again.
      await c.read(relayDomainProvider.notifier).saveForNextLaunch('a.test.example');
      expect(File('${out.path}/$kFleetRelayStampFile').readAsStringSync().trim(),
          'a.test.example');
      await c.read(relayDomainProvider.notifier).saveForNextLaunch('b.test.example');
      final next = ProviderContainer(
          overrides: guardWith(expect: 'a.test.example, b.test.example').overrides);
      addTearDown(next.dispose);
      await next.read(relayDomainProvider.notifier).loadCached();
      expect(next.read(relayDomainProvider), 'b.test.example');
      expect(File('${out.path}/$kFleetRelayStampFile').readAsStringSync().trim(),
          'b.test.example');
    });

    test('a launch never takes a saved switch the run does not expect', () async {
      api.settings['relay_domain'] = 'a.test.example';
      api.settings['relay_domain_next'] = 'stale.example';
      final c = ProviderContainer(
          overrides: guardWith(expect: 'a.test.example').overrides);
      addTearDown(c.dispose);
      await expectLater(c.read(relayDomainProvider.notifier).loadCached(),
          throwsA(isA<RelayGuardRefusal>()));
    });

    test('the expected set never admits the official relay', () {
      expect(relayVerdict('relay.anonlisten.com',
              expect: 'hollowtest.duckdns.org,relay.anonlisten.com')
          ?.production, isTrue);
      expect(expectedRelays(' a.example ,, B.example:8443/ws'),
          ['a.example', 'b.example:8443']);
    });

    test('the opt-in lets the official relay through, loudly', () async {
      api.settings['relay_domain'] = 'relay.anonlisten.com';
      final c = ProviderContainer(overrides: guardWith(allow: true).overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).loadCached();
      expect(refusals, isEmpty);
      expect(c.read(relayDomainProvider), 'relay.anonlisten.com');
    });
  });

  group('node start', () {
    Future<void> start(ProviderContainer c) =>
        c.read(networkServiceProvider).startNode();

    test('an unstamped data directory never starts a node', () async {
      final c = ProviderContainer(overrides: guardWith().overrides);
      addTearDown(c.dispose);
      await expectLater(start(c), throwsA(isA<RelayGuardRefusal>()));
      expect(api.nodeStarts, 0);
    });

    test('the official relay never starts a node', () async {
      final service = GuardedNetworkService(guardWith(), () => 'relay.anonlisten.com');
      await expectLater(service.startNode(), throwsA(isA<RelayGuardRefusal>()));
      expect(api.nodeStarts, 0);
    });

    test('a dial override at the official relay never starts a node', () async {
      File('${out.path}/relay_connect').writeAsStringSync('141.227.186.209:443\n');
      final c = ProviderContainer(overrides: guardWith().overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).setDomain('192.168.18.2');
      await expectLater(start(c), throwsA(isA<RelayGuardRefusal>()));
      expect(refusals.single, contains('relay_connect'));
      expect(api.nodeStarts, 0);
    });

    // R1 of the 11-14 review: the opt-in was dead for every data directory the
    // welcome default made, since it names no relay.
    test('the opt-in on an unstamped data directory starts the node on the official relay',
        () async {
      final c = ProviderContainer(overrides: guardWith(allow: true).overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).loadCached();
      await start(c);
      expect(api.nodeStarts, 1);
      expect(c.read(relayDomainProvider), kDefaultRelayDomain,
          reason: 'hollow_shell passes this value to setRelayUrl before startNode');
    });

    test('a test relay starts the node and the verdict says so', () async {
      final c = ProviderContainer(overrides: guardWith().overrides);
      addTearDown(c.dispose);
      await c.read(relayDomainProvider.notifier).setDomain('192.168.18.2');
      await start(c);
      expect(api.nodeStarts, 1);
      expect(marker()['verdict'], 'passed');
    });
  });

  group('http', () {
    test('a Dart request to the official relay is refused before it connects', () {
      final guard = guardWith();
      final overrides = RelayGuardHttpOverrides(guard);
      expect(
          () => overrides.findProxyFromEnvironment(
              Uri.parse('https://relay.anonlisten.com/relay-status'), const {}),
          throwsA(isA<RelayGuardRefusal>()));
      expect(
          overrides.findProxyFromEnvironment(
              Uri.parse('https://hollow.anonlisten.com/gifs/x.webp'), const {}),
          'DIRECT');
    });

    test('a real HttpClient asks the guard first', () async {
      final guard = guardWith();
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        await expectLater(
            client.getUrl(Uri.parse('https://relay.anonlisten.com/relay-status')),
            throwsA(isA<RelayGuardRefusal>()));
      }, RelayGuardHttpOverrides(guard));
      expect(refusals.single, startsWith('http relay.anonlisten.com'));
    });
  });

  test('the probe arms the guard before the app exists', () {
    final probe = File('integration_test/ui_probe_test.dart').readAsStringSync();
    for (final wiring in [
      'HttpOverrides.global = RelayGuardHttpOverrides(guard);',
      'guard.announce();',
      'ProviderContainer(overrides: relayGuard!.overrides)',
    ]) {
      expect(probe, contains(wiring), reason: 'ui_probe_test.dart must keep: $wiring');
    }
  });

  test('announce leaves the armed marker the fleet looks for', () {
    guardWith(expect: 'hollowtest.duckdns.org').announce();
    expect(marker()['guard'], 'on');
    expect(marker()['verdict'], 'armed');
    expect(marker()['expect'], 'hollowtest.duckdns.org');
  });
}

class _Api implements RustLibApi {
  final settings = <String, String>{};
  int nodeStarts = 0;

  void reset() {
    settings.clear();
    nodeStarts = 0;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      settings[key];

  @override
  Future<void> crateApiStorageSaveSetting(
          {required String key, required String value}) async =>
      settings[key] = value;

  @override
  Future<String> crateApiNetworkStartNode() async {
    nodeStarts++;
    return 'peer';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}
