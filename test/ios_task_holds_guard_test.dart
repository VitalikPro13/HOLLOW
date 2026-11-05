import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The iOS counted background task (`hollow/storage_background`): an end that
/// arrives after an expiry is spent on the hold that expiry ended, so it never
/// ends a task taken since. The struct is compiled and run by
/// `scripts/ios_task_holds_test.sh` (here on a Mac, and in the iOS release job).
void main() {
  const appDelegate = 'ios/Runner/AppDelegate.swift';
  const script = 'scripts/ios_task_holds_test.sh';

  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  test('the task counts its holders only through TaskHolds', () {
    final source = read(appDelegate);
    final begin = source.indexOf('// TASK-HOLDS-BEGIN\n');
    final end = source.indexOf('// TASK-HOLDS-END\n');
    expect(begin, greaterThanOrEqualTo(0));
    expect(end, greaterThan(begin));
    expect(source.substring(begin, end), contains('struct TaskHolds'));
    final task = source.substring(
        source.indexOf('final class RelayBackgroundTask'), begin);
    expect(task, contains('holds.take()'));
    expect(task, contains('holds.release()'));
    expect(task, contains('holds.expire()'),
        reason: 'an expiry that forgets its holds lets their late ends end a '
            'newer task');
    expect(task, isNot(contains('holders')),
        reason: 'a second count beside TaskHolds');
  });

  test('the iOS release job runs the holds tests', () {
    expect(read('.github/workflows/release-apple.yml'),
        contains('bash $script'));
  });

  test('the holds pass their scenarios', () async {
    final run = await Process.run('bash', [script]);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
  }, skip: Platform.isMacOS ? false : 'needs swiftc');
}
