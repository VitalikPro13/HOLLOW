import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';

/// #155: 0.12.1 to 0.14.1 shipped `hollow_data/messages.db` in every Windows
/// release, and counting a database as an identity moved each updated copy off
/// the person's own profile.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hollow_portable_'));
  tearDown(() => dir.deleteSync(recursive: true));

  void touch(String name) =>
      File('${dir.path}${Platform.pathSeparator}$name').writeAsStringSync('x');

  test('a lone database or lock is not an identity', () {
    touch('messages.db');
    touch('hollow.lock');
    touch('hollow_crash.log');
    expect(portableFolderHoldsIdentity(dir.path), isFalse);
  });

  test('an empty folder is not an identity', () {
    expect(portableFolderHoldsIdentity(dir.path), isFalse);
  });

  test('either identity file is', () {
    touch('identity.key');
    expect(portableFolderHoldsIdentity(dir.path), isTrue);
    File('${dir.path}${Platform.pathSeparator}identity.key').deleteSync();
    touch('identity.device');
    expect(portableFolderHoldsIdentity(dir.path), isTrue);
  });

  test('nothing is left behind when detection did not choose the folder', () {
    // A test process never boots through portable detection, even with an
    // identity in the default profile.
    touch('identity.key');
    debugDefaultDesktopDataRoot = dir.path;
    addTearDown(() => debugDefaultDesktopDataRoot = null);
    expect(defaultProfileLeftBehind(), isNull);
  });
}
