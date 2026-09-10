import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';

class _FixedRelayDomain extends RelayDomainNotifier {
  _FixedRelayDomain(this.domain);
  final String domain;

  @override
  String build() => domain;
}

void main() {
  group('RelayStatus.fromJson', () {
    test('an older relay omits the new fields', () {
      final status = RelayStatus.fromJson(
          jsonDecode('{"license_required":true}') as Map<String, dynamic>);
      expect(status.licenseRequired, isTrue);
      expect(status.version, isNull);
      expect(status.turn, isNull);
      expect(status.forwarder, isNull);
    });

    test('the new shape', () {
      final status = RelayStatus.fromJson(jsonDecode(
              '{"license_required":false,"version":"0.12.0","turn":false,'
              '"forwarder":true}')
          as Map<String, dynamic>);
      expect(status.licenseRequired, isFalse);
      expect(status.version, '0.12.0');
      expect(status.turn, isFalse);
      expect(status.forwarder, isTrue);
    });

    test('turn true reads as true', () {
      final status = RelayStatus.fromJson(
          jsonDecode('{"turn":true}') as Map<String, dynamic>);
      expect(status.turn, isTrue);
    });

    test('wrong types and an empty version read as unknown', () {
      final status = RelayStatus.fromJson(jsonDecode(
              '{"version":"","turn":"yes","forwarder":1}')
          as Map<String, dynamic>);
      expect(status.version, isNull);
      expect(status.turn, isNull);
      expect(status.forwarder, isNull);
    });

    test('an empty body is all unknown and no licence', () {
      final status =
          RelayStatus.fromJson(jsonDecode('{}') as Map<String, dynamic>);
      expect(status.licenseRequired, isFalse);
      expect(status.turn, isNull);
    });
  });

  group('status feed gate', () {
    test('a self-hosted relay never shows the official notice', () async {
      final container = ProviderContainer(overrides: [
        relayDomainProvider
            .overrideWith(() => _FixedRelayDomain('my.example.com')),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(statusProvider.notifier);
      expect(await notifier.refresh(), isFalse);
      expect(container.read(statusProvider).status.isEmpty, isTrue);
      expect(container.read(statusProvider).showBanner, isFalse);

      notifier.onRelayLoaded();
      expect(container.read(statusProvider).status.isEmpty, isTrue);
      expect(container.read(statusProvider).showBanner, isFalse);
    });
  });
}
