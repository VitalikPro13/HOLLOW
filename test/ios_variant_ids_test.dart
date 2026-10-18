import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source scan of the iOS build variants. The dev variant goes onto a phone
/// that carries the real TestFlight install, so no id the app or an extension
/// uses may be a literal that a dev build could fall back to: every one comes
/// from ios/Flutter/Variant-{prod,dev}.xcconfig.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const _prodId = 'com.anonlisten.hollow';

/// Files the app or an extension reads an id from at build or run time.
const _idSources = [
  'ios/Runner/Info.plist',
  'ios/Runner/Runner.entitlements',
  'ios/Runner/RunnerPersonalTeam.entitlements',
  'ios/Runner/AppDelegate.swift',
  'ios/NotificationService/Info.plist',
  'ios/NotificationService/NotificationService.entitlements',
  'ios/NotificationService/NotificationService.swift',
  'ios/BroadcastExtension/Info.plist',
  'ios/BroadcastExtension/BroadcastExtension.entitlements',
  'ios/BroadcastExtension/SampleHandler.swift',
];

Map<String, String> _settings(String xcconfig) => {
      for (final m in RegExp(r'^([A-Z_]+) =(.*)$', multiLine: true)
          .allMatches(_read(xcconfig)))
        m.group(1)!: m.group(2)!.trim(),
    };

/// Every XCBuildConfiguration body in the project, keyed by its name.
List<(String, String)> _configs() {
  final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
  return [
    for (final m in RegExp(r'isa = XCBuildConfiguration;\n(.*?)\n\t\t\tname = "?([\w-]+)"?;',
            dotAll: true)
        .allMatches(pbx))
      (m.group(2)!, m.group(1)!),
  ];
}

void main() {
  test('no app group, keychain group or bundle id is a literal', () {
    for (final path in _idSources) {
      final src = _read(path)
          // Queue labels name nothing the system resolves.
          .replaceAll(RegExp(r'label: "com\.anonlisten\.hollow[\w.\-\\()]*"'), '');
      expect(src, isNot(contains(_prodId)), reason: path);
    }
  });

  test('each variant names its own ids', () {
    final prod = _settings('ios/Flutter/Variant-prod.xcconfig');
    final dev = _settings('ios/Flutter/Variant-dev.xcconfig');
    expect(prod['HOLLOW_BUNDLE_ID'], _prodId);
    expect(prod['HOLLOW_APS_ENVIRONMENT'], 'production');
    expect(prod['HOLLOW_FIREBASE_PLIST'], isEmpty);
    expect(dev['HOLLOW_BUNDLE_ID'], '$_prodId.dev');
    expect(dev['HOLLOW_APS_ENVIRONMENT'], 'development');
    expect(dev['HOLLOW_URL_SCHEME'], isNot('hollow'));
    expect(dev['HOLLOW_DEV_TEAM'], isNotEmpty);
    for (final v in [prod, dev]) {
      expect(v['HOLLOW_APP_GROUP'], r'group.$(HOLLOW_BUNDLE_ID)');
    }
  });

  test('bundle ids derive from HOLLOW_BUNDLE_ID in every configuration', () {
    final configs = _configs();
    expect(configs.map((c) => c.$1).toSet(),
        {'Debug', 'Release', 'Profile', 'Debug-dev', 'Release-dev', 'Profile-dev'});
    for (final (name, body) in configs) {
      final id = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);').firstMatch(body);
      if (id == null) continue; // project-level
      expect(id.group(1), startsWith(r'"$(HOLLOW_BUNDLE_ID)'), reason: name);
    }
  });

  test('dev configurations sign with the dev team and take the dev variant', () {
    var projectLevel = 0;
    for (final (name, body) in _configs()) {
      final isDev = name.endsWith('-dev');
      if (body.contains('Variant-')) {
        projectLevel++;
        expect(body, contains(isDev ? 'Variant-dev.xcconfig' : 'Variant-prod.xcconfig'),
            reason: name);
      }
      if (!isDev) continue;
      final team = RegExp(r'DEVELOPMENT_TEAM = ([^;]+);').firstMatch(body);
      if (team != null) {
        expect(team.group(1), r'"$(HOLLOW_DEV_TEAM)"', reason: name);
      }
    }
    expect(projectLevel, 6);
  });

  test('the dev scheme builds only dev configurations', () {
    final scheme = _read('ios/Runner.xcodeproj/xcshareddata/xcschemes/dev.xcscheme');
    final used = RegExp(r'buildConfiguration = "([^"]+)"')
        .allMatches(scheme)
        .map((m) => m.group(1)!)
        .toSet();
    expect(used, {'Debug-dev', 'Release-dev', 'Profile-dev'});
  });
}
