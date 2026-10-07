import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/relay_triggers.dart';

/// Source scan of the native halves of [RelayTriggers]: every runner opens the
/// same channel and sends only events Dart maps to a nudge.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const _channelOwners = {
  'android': 'android/app/src/main/kotlin/com/anonlisten/hollow/MainActivity.kt',
  'ios': 'ios/Runner/AppDelegate.swift',
  'macos': 'macos/Runner/MainFlutterWindow.swift',
  'windows': 'windows/runner/flutter_window.cpp',
  'linux': 'linux/runner/my_application.cc',
};

/// Where each platform names the events it forwards.
const _eventSources = {
  'android': 'android/app/src/main/kotlin/com/anonlisten/hollow/MainActivity.kt',
  'ios': 'ios/Runner/RelayTriggers.swift',
  'macos': 'macos/Runner/RelayTriggers.swift',
  'windows': 'windows/runner/relay_triggers.cpp',
  'linux': 'linux/runner/relay_triggers.cc',
};

void main() {
  test('every runner opens the triggers channel', () {
    for (final entry in _channelOwners.entries) {
      expect(_read(entry.value), contains('"${RelayTriggers.channelName}"'),
          reason: entry.key);
    }
  });

  test('each platform forwards network changes', () {
    for (final entry in _eventSources.entries) {
      expect(_read(entry.value), contains('"network"'), reason: entry.key);
    }
  });

  test('desktops forward wake from sleep, phones do not', () {
    for (final platform in ['macos', 'windows', 'linux']) {
      expect(_read(_eventSources[platform]!), contains('"wake"'),
          reason: platform);
    }
    expect(_read(_eventSources['android']!), isNot(contains('"wake"')));
  });

  test('the iOS and macOS Swift copies are identical', () {
    expect(_read('ios/Runner/RelayTriggers.swift'),
        _read('macos/Runner/RelayTriggers.swift'));
  });

  test('both Xcode projects compile the Swift file', () {
    for (final p in ['ios', 'macos']) {
      final project = _read('$p/Runner.xcodeproj/project.pbxproj');
      expect(project, contains('/* RelayTriggers.swift in Sources */,'),
          reason: p);
    }
  });

  test('the Windows and Linux runners build their trigger sources', () {
    expect(_read('windows/runner/CMakeLists.txt'),
        contains('"relay_triggers.cpp"'));
    expect(_read('windows/runner/CMakeLists.txt'), contains('iphlpapi.lib'));
    expect(_read('linux/runner/CMakeLists.txt'),
        contains('"relay_triggers.cc"'));
  });

  test('the flatpak may hear logind', () {
    expect(_read('flatpak/com.anonlisten.Hollow.yml'),
        contains('--system-talk-name=org.freedesktop.login1'));
  });

  test('iOS holds the background task the phone model asks for', () {
    final delegate = _read('ios/Runner/AppDelegate.swift');
    expect(delegate, contains('"${IosRelayBackgroundTask.channelName}"'));
    for (final word in ['"begin"', '"end"', '"expiring"']) {
      expect(delegate, contains(word), reason: word);
    }
    expect(delegate, contains('beginBackgroundTask('));
    expect(delegate, contains('endBackgroundTask('));
  });

  test('Android works with the OS: no battery exemption, no Wi-Fi lock', () {
    // Plan 3.8: Play lists a chat app with high-priority FCM as not acceptable
    // for the exemption, and a Wi-Fi lock does nothing for a background socket.
    expect(_read('android/app/src/main/AndroidManifest.xml'),
        isNot(contains('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS')));
    final activity = _read(_channelOwners['android']!);
    for (final gone in [
      'IGNORE_BATTERY_OPTIMIZATIONS',
      'isIgnoringBatteryOptimizations',
      'WifiLock',
      'WifiManager',
    ]) {
      expect(activity, isNot(contains(gone)), reason: gone);
    }
    for (final dart in [
      'lib/src/core/android_platform.dart',
      'lib/src/ui/shell/hollow_shell.dart',
    ]) {
      final source = _read(dart);
      for (final gone in [
        'BatteryOptimized',
        'BatteryExemption',
        'WifiLock',
      ]) {
        expect(source, isNot(contains(gone)), reason: '$dart: $gone');
      }
    }
  });
}
