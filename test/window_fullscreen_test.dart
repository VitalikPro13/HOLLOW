import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';

/// Part A of the media viewer plan: true fullscreen. Hollow's window is
/// frameless, and window_manager 0.5.1 skips its enter branch for exactly that
/// case while its exit path clears framelessness and the DWM margins, which is
/// the squished restore. So Windows goes through the runner's own
/// `hollow/window` channel, and these are the guards that keep both halves of
/// that decision in one file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  Iterable<File> dartFilesUnderLib() sync* {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue,
        reason: 'expected to run from the project root (lib missing)');
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) yield entity;
    }
  }

  void expectOnlyIn(String needle, String fileName) {
    final offenders = <String>[];
    for (final file in dartFilesUnderLib()) {
      if (file.path.endsWith(fileName)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains(needle)) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '\n`$needle` belongs to $fileName alone:\n'
          '  ${offenders.join('\n  ')}\n',
    );
  }

  test('window_manager fullscreen is confined to window_fullscreen.dart', () {
    expectOnlyIn('windowManager.setFullScreen(', 'window_fullscreen.dart');
    expectOnlyIn('setFullScreen(', 'window_fullscreen.dart');
  });

  test('the runner channel name is confined to window_fullscreen.dart', () {
    expectOnlyIn("'hollow/window'", 'window_fullscreen.dart');
  });

  test('the backend per platform', () {
    expect(
      fullscreenBackendFor(isWindows: true, isMacOS: false, isLinux: false),
      FullscreenBackend.native,
    );
    expect(
      fullscreenBackendFor(isWindows: false, isMacOS: true, isLinux: false),
      FullscreenBackend.windowManager,
    );
    expect(
      fullscreenBackendFor(isWindows: false, isMacOS: false, isLinux: true),
      FullscreenBackend.windowManager,
    );
    expect(
      fullscreenBackendFor(isWindows: false, isMacOS: false, isLinux: false),
      FullscreenBackend.none,
    );
  });

  test('the window starts boxed', () {
    expect(container().read(fullscreenProvider), isFalse);
  });

  test('locking exits fullscreen and survives a channel with no host',
      () async {
    final c = container();
    expect(c.read(fullscreenProvider), isFalse);

    c.read(appLockedProvider.notifier).setLocked(true);
    // The exit runs on the platform channel, which has no host here; the
    // service has to swallow that rather than hand it to the lock.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(c.read(fullscreenProvider), isFalse);
    expect(c.read(appLockedProvider), isTrue);

    // The lock also raises a process-global toast flag; putting it back keeps
    // a later test in this file from running under a suppressed toast host.
    c.read(appLockedProvider.notifier).setLocked(false);
  });
}
