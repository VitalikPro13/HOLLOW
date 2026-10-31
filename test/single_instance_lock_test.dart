@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/single_instance_lock.dart';

void main() {
  late Directory dir;
  late String lockFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hollow_lock_');
    lockFile = SingleInstanceLock.fileIn(dir.path);
  });

  tearDown(() {
    SingleInstanceLock.release();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a fresh data root is taken and the file names this process', () {
    expect(SingleInstanceLock.acquire(dir.path), isTrue);
    expect(File(lockFile).readAsStringSync().trim(), '$pid');
    expect(SingleInstanceLock.heldByAnotherProcess(lockFile), isFalse);
    SingleInstanceLock.release();
    expect(File(lockFile).existsSync(), isFalse);
  });

  test('a stale lock naming this very pid is not another instance (#69)', () {
    // Inside a flatpak every launch is the same small pid, so this is what a
    // restart that never released its lock leaves behind.
    File(lockFile).writeAsStringSync('$pid');
    expect(SingleInstanceLock.heldByAnotherProcess(lockFile), isFalse);
    expect(SingleInstanceLock.acquire(dir.path), isTrue);
  });

  test('a stale lock naming a dead process is taken over', () async {
    final gone = await Process.start(
      Platform.isWindows ? 'cmd' : 'sh',
      Platform.isWindows ? ['/c', 'exit 0'] : ['-c', 'true'],
    );
    await gone.exitCode;
    File(lockFile).writeAsStringSync('${gone.pid}');
    expect(SingleInstanceLock.heldByAnotherProcess(lockFile), isFalse);
    expect(SingleInstanceLock.acquire(dir.path), isTrue);
    expect(File(lockFile).readAsStringSync().trim(), '$pid');
  });

  test('a lock held by another live process is refused until it lets go',
      () async {
    // Run from outside the package: `dart run` inside it first builds every
    // dependency's native build hooks, minutes on a cold checkout.
    const lib = 'package:hollow/src/core/single_instance_lock.dart';
    final source = File('test/helpers/lock_holder.dart').readAsStringSync();
    expect(source, contains(lib));
    final outside = Directory.systemTemp.createTempSync('hollow_lock_holder_');
    addTearDown(() => outside.deleteSync(recursive: true));
    final holder = File('${outside.path}${Platform.pathSeparator}holder.dart')
      ..writeAsStringSync(source.replaceFirst(lib,
          File('lib/src/core/single_instance_lock.dart').absolute.uri.toString()));
    final child = await Process.start(
      'dart',
      ['run', holder.path, dir.path],
      workingDirectory: outside.path,
      runInShell: Platform.isWindows,
    );
    final lines = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final errors = StringBuffer();
    child.stderr.transform(utf8.decoder).listen(errors.write);

    final first = await lines
        .firstWhere((l) => l == 'held' || l == 'refused')
        .timeout(const Duration(seconds: 60));
    expect(first, 'held', reason: errors.toString());

    expect(SingleInstanceLock.acquire(dir.path), isFalse);
    expect(SingleInstanceLock.heldByAnotherProcess(lockFile), isTrue);
    // The refused attempt leaves the holder's pid untouched.
    final holderPid = int.tryParse(File(lockFile).readAsStringSync().trim());
    expect(holderPid, isNotNull);
    expect(holderPid, isNot(pid));

    await child.stdin.close();
    expect(await child.exitCode.timeout(const Duration(seconds: 30)), 0,
        reason: errors.toString());
    expect(SingleInstanceLock.acquire(dir.path), isTrue);
    expect(File(lockFile).readAsStringSync().trim(), '$pid');
  });
}
