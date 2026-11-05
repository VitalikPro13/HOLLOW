import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source scan of the vendored Windows audioplayers plugin. A C++ exception
/// escaping a method-channel handler crosses the embedder's C callback and
/// ends the process; one thrown inside its MTA work item left the platform
/// thread waiting forever, so the window froze.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const _pluginDir = 'packages/audioplayers_windows';

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

/// The whole body runs between `try {` and a closing `catch (...)`.
bool _wholeBodyGuarded(String body) {
  final trimmed = body
      .split('\n')
      .where((l) => !l.trim().startsWith('//'))
      .join('\n')
      .trim();
  return trimmed.startsWith('try {') &&
      trimmed.lastIndexOf('catch (...)') >
          trimmed.lastIndexOf('result->Success()');
}

/// The text of the first `{ ... }` block after [anchor].
String _blockAfter(String source, String anchor) {
  final at = source.indexOf(anchor);
  expect(at, isNonNegative, reason: '$anchor is gone');
  final open = source.indexOf('{', at);
  var depth = 1;
  var end = open + 1;
  for (; depth > 0; end++) {
    if (source[end] == '{') depth++;
    if (source[end] == '}') depth--;
  }
  return source.substring(open + 1, end - 1);
}

void main() {
  test('the app builds the vendored plugin, not the pub.dev one', () {
    final pubspec = _read('pubspec.yaml');
    final overrides = pubspec.substring(
      pubspec.indexOf('\ndependency_overrides:'),
    );
    expect(
      overrides,
      matches(
        RegExp(
          r'audioplayers_windows:\s*\n\s*path: '
          '$_pluginDir',
        ),
      ),
    );
    expect(_read('pubspec.lock'), contains('path: "$_pluginDir"'));
  });

  test('every method-channel handler catches everything', () {
    final bodies = _bodies(
      _read('$_pluginDir/windows/audioplayers_windows_plugin.cpp'),
    );
    for (final name in ['HandleMethodCall', 'HandleGlobalMethodCall']) {
      expect(bodies[name], isNotNull, reason: '$name is gone');
      expect(
        _wholeBodyGuarded(bodies[name]!),
        isTrue,
        reason: '$name lets a C++ exception reach the embedder',
      );
    }
  });

  test('a throw inside the MTA work item still wakes the waiting thread', () {
    final helpers = _read('$_pluginDir/windows/MediaFoundationHelpers.h');
    final work = _blockAfter(helpers, 'MFPutWorkItem([&]()');
    final caught = work.indexOf('catch (...)');
    expect(
      caught,
      isNonNegative,
      reason: 'a throw skips SetEvent and the caller waits forever',
    );
    expect(work.indexOf('complete.SetEvent()'), greaterThan(caught));
    expect(
      _blockAfter(helpers, 'inline void RunSyncInMTA('),
      contains('std::rethrow_exception'),
      reason: 'the failure must reach the caller, never vanish',
    );
  });

  test('local_auth is never called on Windows', () {
    // local_auth_windows 2.0.x awaits Windows Hello outside any try in a
    // fire_and_forget coroutine, so a WinRT failure there ends the process.
    // App Lock asks for biometrics on phones only; keep it that way, or fork it.
    const appLock = 'lib/src/core/services/app_lock_service.dart';
    final importers = [
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') &&
            _read(f.path).contains('package:local_auth'))
          f.path.replaceAll(r'\', '/'),
    ];
    expect(
      importers,
      [appLock],
      reason: 'local_auth reached from outside App Lock is not gated to phones',
    );
    final source = _read(appLock);
    expect(
      source,
      contains(
        'static bool get _isMobile => Platform.isAndroid || Platform.isIOS;',
      ),
    );
    final calls = RegExp(r'_localAuth\.').allMatches(source).toList();
    expect(calls, isNotEmpty);
    for (final call in calls) {
      final method = source.lastIndexOf(RegExp(r'\n  Future<'), call.start);
      final gate = source.indexOf('if (!_isMobile) return', method);
      expect(
        gate > method && gate < call.start,
        isTrue,
        reason: 'a local_auth call at ${call.start} is reachable on desktop',
      );
    }
  });

  test('the Media Foundation reference never throws from its destructor', () {
    final helpers = _read('$_pluginDir/windows/MediaFoundationHelpers.h');
    expect(
      _blockAfter(helpers, 'virtual ~MFPlatformRef()'),
      contains('catch (...)'),
    );
  });
}
