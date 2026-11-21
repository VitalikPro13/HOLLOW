import 'dart:io';

import 'package:crypto/crypto.dart';

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
    final previous = debugDefaultDesktopDataRoot;
    debugDefaultDesktopDataRoot = dir.path;
    addTearDown(() => debugDefaultDesktopDataRoot = previous);
    expect(defaultProfileLeftBehind(), isNull);
  });

  group('the stray an old release shipped', () {
    // Stand-ins for the shipped bytes: the real 475 KB database is not in the repo.
    final strayDb = List<int>.generate(4096, (i) => (i * 7) & 0xff);
    final strayLock = '12864'.codeUnits;
    final shipped = [
      ShippedStrayFile(
          'messages.db', strayDb.length, sha256.convert(strayDb).toString()),
      ShippedStrayFile(
          'hollow.lock', strayLock.length, sha256.convert(strayLock).toString()),
    ];
    late String data;
    setUp(() {
      data = '${dir.path}${Platform.pathSeparator}hollow_data';
      Directory(data).createSync();
    });
    File at(String name) => File('$data${Platform.pathSeparator}$name');
    void seed() {
      at('messages.db').writeAsBytesSync(strayDb);
      at('hollow.lock').writeAsBytesSync(strayLock);
    }

    test('a shipped stray database is removed, a folder with an identity is untouched',
        () {
      seed();
      expect(removeShippedStrayData(data, shipped: shipped),
          ['messages.db', 'hollow.lock']);
      expect(Directory(data).existsSync(), isFalse,
          reason: 'the emptied folder stays and lists as a profile');

      Directory(data).createSync();
      seed();
      at('identity.key').writeAsStringSync('the person');
      expect(removeShippedStrayData(data, shipped: shipped), isEmpty);
      expect(at('messages.db').readAsBytesSync(), strayDb);
      expect(at('hollow.lock').existsSync(), isTrue);

      at('identity.key').deleteSync();
      at('identity.device').writeAsStringSync('the person');
      expect(removeShippedStrayData(data, shipped: shipped), isEmpty);
      expect(at('messages.db').existsSync(), isTrue);
    });

    test('a database that is not the shipped one is never removed', () {
      final changed = List<int>.of(strayDb)..[100] ^= 1;
      at('messages.db').writeAsBytesSync(changed);
      at('hollow.lock').writeAsBytesSync(strayLock);
      expect(removeShippedStrayData(data, shipped: shipped), ['hollow.lock']);
      expect(at('messages.db').readAsBytesSync(), changed);
      expect(Directory(data).existsSync(), isTrue);

      at('messages.db').writeAsBytesSync([...strayDb, 0]);
      expect(removeShippedStrayData(data, shipped: shipped), isEmpty,
          reason: 'one byte longer is someone else\'s database');
      expect(at('messages.db').existsSync(), isTrue);
    });

    test('an empty folder the person made stays', () {
      expect(removeShippedStrayData(data, shipped: shipped), isEmpty);
      expect(Directory(data).existsSync(), isTrue);
    });

    test('anything else in the folder keeps the folder', () {
      seed();
      at('hollow_crash.log').writeAsStringSync('x');
      expect(removeShippedStrayData(data, shipped: shipped),
          ['messages.db', 'hollow.lock']);
      expect(at('hollow_crash.log').existsSync(), isTrue);
    });

    test('the shipped file is pinned by its size and hash', () {
      final db = shippedStrayFiles.firstWhere((f) => f.name == 'messages.db');
      expect(db.size, 475136);
      expect(db.sha256,
          'c69bfe5028c930ad5e69fab0ae3977f45d269ea758437473707d728d0b0e7499');
      final lock = shippedStrayFiles.firstWhere((f) => f.name == 'hollow.lock');
      expect(lock.sha256, sha256.convert('12864'.codeUnits).toString());
    });
  });
}

