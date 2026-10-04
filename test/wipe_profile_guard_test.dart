import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every way a wipe ends must leave the profile list as decision B says, so the
/// sites are pinned here: a new one that restarts with a bare `relaunchApp()`
/// would bring the wiped profile back up, empty, instead of moving on.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  Iterable<File> dartSources() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.replaceAll('\\', '/').contains('lib/src/rust/'));

  test('every wipe restarts through relaunchAfterWipe', () {
    final wipe = RegExp(r'wipe_api\.(destroyLocal|destroyWithScope)\(|'
        r'Future<Never> endSessionAfterDuress\(');
    final sites = dartSources().where((f) => wipe.hasMatch(read(f.path)));
    expect(sites, isNotEmpty);
    final bare = [
      for (final f in sites)
        if (!read(f.path).contains('relaunchAfterWipe()')) f.path,
    ];
    expect(bare, isEmpty,
        reason: 'these wipe and restart without settling the profile list');
  });

  test('the boot wipe settles the profile list when it ended an identity', () {
    final shell = read('lib/src/ui/shell/hollow_shell.dart');
    expect(
        RegExp(r'if \(await storage_api\.performPendingWipe\(\)\) \{\s*'
                r'await settleProfileAfterBootWipe\(\);')
            .hasMatch(shell),
        isTrue);
  });

  test('erasing another profile runs the Rust wipe, never a Dart delete', () {
    final card = read('lib/src/ui/settings/profile_locations_card.dart');
    expect(card, contains('wipe_api.eraseProfileAt('));
    expect(card, contains('forgetWipedProfile('));
    expect(card, isNot(contains('.delete(recursive: true)')));
  });

  test('a recording is listed for the wipe before it starts', () {
    final src = read('lib/src/core/services/recording_service.dart');
    final remembered = src.indexOf('wipe_api.rememberRecording(');
    expect(remembered, greaterThan(0));
    for (final start in ['hollowWinStartScreenRecord', 'Process.start(ffmpeg']) {
      expect(remembered, lessThan(src.indexOf(start)),
          reason: 'a crash mid-recording must not leave it off the list');
    }
  });
}
