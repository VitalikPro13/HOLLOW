import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source scan of the vendored Windows toast plugin. A WinRT error escaping one
/// of its FFI entry points cannot be caught in Dart and ends the process (it
/// killed fresh onboarding where the notification platform is unavailable).
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const _pluginDir = 'packages/flutter_local_notifications_windows';

/// What can throw a C++ exception inside an entry point.
final _throwing = RegExp(
  r'ToastNotificationManager|plugin->notifier|plugin->history|XmlDocument|'
  r'registerApp|std::stoi|winrt::to_hstring',
);

/// Top-level function definitions: `<type> <name>(<args>) {` at column 0.
final _definition = RegExp(
  r'^[A-Za-z_][\w:<>\*\s]*?\b(\w+)\(([^)]*)\)\s*\{',
  multiLine: true,
);

Map<String, String> _bodies(String source) {
  final bodies = <String, String>{};
  for (final match in _definition.allMatches(source)) {
    var depth = 1;
    var end = match.end;
    for (; depth > 0; end++) {
      if (source[end] == '{') depth++;
      if (source[end] == '}') depth--;
    }
    bodies[match.group(1)!] = source.substring(match.end, end);
  }
  return bodies;
}

/// Every call that can throw sits between `try {` and `catch (...)`.
bool _guarded(String body) {
  final open = body.indexOf('try {');
  final close = body.lastIndexOf('catch (...)');
  return _throwing
      .allMatches(body)
      .every((m) => open >= 0 && m.start > open && m.start < close);
}

void main() {
  test('the app builds the vendored plugin, not the pub.dev one', () {
    final pubspec = _read('pubspec.yaml');
    expect(pubspec, contains('\ndependency_overrides:'));
    final overrides = pubspec.substring(
      pubspec.indexOf('\ndependency_overrides:'),
    );
    expect(
      overrides,
      matches(
        RegExp(
          r'flutter_local_notifications_windows:\s*\n\s*path: '
          '$_pluginDir',
        ),
      ),
    );
    expect(_read('pubspec.lock'), contains('path: "$_pluginDir"'));
  });

  test('every entry point that can throw catches everything', () {
    final bodies = _bodies(_read('$_pluginDir/src/ffi_api.cpp'));
    expect(bodies.keys, containsAll(['init', 'showNotification', 'cancelAll']));
    final unguarded = [
      for (final entry in bodies.entries)
        if (!_guarded(entry.value)) entry.key,
    ];
    expect(unguarded, isEmpty);
  });
}
