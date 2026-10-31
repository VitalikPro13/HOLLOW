import 'dart:io';

import 'package:hollow/src/core/single_instance_lock.dart';

/// Holds the single-instance lock on the directory in argv until stdin closes.
/// A separate process, because a lock never conflicts with its own process.
/// The test runs a copy outside the package that imports the lock by file URI.
Future<void> main(List<String> args) async {
  final ok = SingleInstanceLock.acquire(args.first);
  stdout.writeln(ok ? 'held' : 'refused');
  await stdout.flush();
  if (!ok) exit(2);
  await stdin.drain<void>();
  SingleInstanceLock.release();
  stdout.writeln('released');
  await stdout.flush();
}
