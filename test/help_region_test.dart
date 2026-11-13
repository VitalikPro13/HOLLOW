/// Get help's starting country on Android: the mobile network first, then
/// the SIM, then the locale; a code off the bundled list falls through, and
/// nothing but the phone's own telephony is asked.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/help_resources.dart';

const _channel = MethodChannel('com.anonlisten.hollow/platform');
const _listed = {'PL', 'DE', 'GB', 'US'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  /// The phone reports [reply] (null = the method threw).
  void phone(Map<String, Object?>? reply) {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (reply == null) throw PlatformException(code: 'boom');
      return reply;
    });
  }

  /// The pick as "CODE/source", so every case also proves what the page
  /// will name as the source.
  Future<String?> region({String? locale = 'US'}) async {
    final r = await helpDeviceRegion(
        listed: _listed.contains, locale: () => locale);
    return r == null ? null : '${r.code}/${r.source.name}';
  }

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test('the mobile network the phone is on comes first', () async {
    phone({'network': 'pl', 'sim': 'de'});
    expect(await region(), 'PL/network');
    expect(calls, ['getTelephonyCountries']);
  });

  test('with no network country the SIM decides', () async {
    phone({'network': '', 'sim': 'de'});
    expect(await region(), 'DE/sim');
    phone({'sim': 'gb'});
    expect(await region(), 'GB/sim');
  });

  test('with neither the locale decides', () async {
    phone({'network': '', 'sim': ''});
    expect(await region(), 'US/locale');
    phone({'network': null, 'sim': null});
    expect(await region(locale: null), isNull);
  });

  test('a code that is not two letters, or not on the list, falls through',
      () async {
    phone({'network': 'pol', 'sim': 'de'});
    expect(await region(), 'DE/sim');
    phone({'network': '1a', 'sim': 'zz'});
    expect(await region(), 'US/locale');
    phone({'network': 'aq', 'sim': 'gb'});
    expect(await region(), 'GB/sim');
    phone({'network': ' pl ', 'sim': null});
    expect(await region(), 'PL/network');
  });

  test('an unlisted locale region still comes back, for the page to say so',
      () async {
    phone({'network': '', 'sim': ''});
    expect(await region(locale: 'AQ'), 'AQ/locale');
  });

  test('a failed read falls back to the locale', () async {
    phone(null);
    expect(await region(), 'US/locale');
    messenger.setMockMethodCallHandler(_channel, null);
    expect(await region(), 'US/locale');
  });

  test('other platforms never ask the channel', () async {
    phone({'network': 'pl', 'sim': 'pl'});
    for (final p in [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = p;
      expect(await region(), 'US/locale', reason: '$p');
    }
    expect(calls, isEmpty);
  });

  test('a region code is two letters, trimmed and upper-cased', () {
    expect(regionCode(' pl '), 'PL');
    expect(regionCode('Gb'), 'GB');
    for (final bad in [null, '', 'pol', 'p1', '1a', 'p', 'p l']) {
      expect(regionCode(bad), isNull, reason: '$bad');
    }
  });

  test('the Android side reads the network, then the SIM, with no permission',
      () {
    final kt = File(
            'android/app/src/main/kotlin/com/anonlisten/hollow/MainActivity.kt')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final at = kt.indexOf('"getTelephonyCountries"');
    expect(at, greaterThan(0));
    final body = kt.substring(at, kt.indexOf('result.success', at) + 200);
    expect(body, contains('"network" to'));
    expect(body, contains('networkCountryIso'));
    expect(body, contains('"sim" to'));
    expect(body, contains('simCountryIso'));
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, isNot(contains('READ_PHONE_STATE')));
  });
}
