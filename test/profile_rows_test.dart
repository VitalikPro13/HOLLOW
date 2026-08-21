import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';

/// The profile list feeds two surfaces now (Settings > Profile and the
/// first-run welcome screen), so what it contains, in what order, and what it
/// deduplicates is worth pinning down. Pure filesystem + environment reads, no
/// FFI and no device.
void main() {
  group('listProfileRows', () {
    test('always leads with Default, and lists customs after it', () {
      final rows = listProfileRows(const ProfileRegistry(custom: [
        HollowProfile(name: 'Artist', path: r'C:\hollow-profiles\artist'),
      ]));

      expect(rows.first.name, 'Default');
      expect(rows.first.path, defaultDesktopDataRoot());
      expect(rows.first.builtin, isTrue);

      final artist = rows.firstWhere((r) => r.name == 'Artist');
      expect(artist.builtin, isFalse);
      expect(artist.portable, isFalse);
      expect(rows.indexOf(artist), greaterThan(0));
    });

    test('lists the portable folder as a builtin row, before customs', () {
      final rows = listProfileRows(const ProfileRegistry(custom: [
        HollowProfile(name: 'Artist', path: r'C:\hollow-profiles\artist'),
      ]));
      final portable = rows.where((r) => r.portable).toList();

      // Desktop test hosts always resolve an executable, so the row is there
      // whether or not the folder itself exists yet.
      expect(portable, hasLength(1));
      expect(portable.single.builtin, isTrue);
      expect(portable.single.path, portableCandidatePath());
      expect(rows.indexOf(portable.single),
          lessThan(rows.indexWhere((r) => r.name == 'Artist')));
    });

    test('a custom entry pointing at Default does not double it up', () {
      final rows = listProfileRows(ProfileRegistry(custom: [
        HollowProfile(name: 'My main', path: defaultDesktopDataRoot()),
      ]));

      expect(rows.where((r) => sameProfilePath(r.path, defaultDesktopDataRoot())),
          hasLength(1));
      expect(rows.any((r) => r.name == 'My main'), isFalse);
    });

    test('a custom entry differing only in case or trailing slash is the same '
        'profile on Windows', () {
      if (!Platform.isWindows) return;
      final rows = listProfileRows(ProfileRegistry(custom: [
        HollowProfile(
            name: 'Shouted', path: '${defaultDesktopDataRoot().toUpperCase()}\\'),
      ]));
      expect(rows.any((r) => r.name == 'Shouted'), isFalse);
    });
  });

  group('profileHasIdentity', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('hollow_profile_row'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('an empty folder holds no identity', () {
      expect(profileHasIdentity(tmp.path), isFalse);
    });

    test('a folder with other Hollow files but no key holds no identity', () {
      File('${tmp.path}${Platform.pathSeparator}messages.db')
          .writeAsStringSync('not a key');
      expect(profileHasIdentity(tmp.path), isFalse);
    });

    test('a folder with identity.key holds one', () {
      File('${tmp.path}${Platform.pathSeparator}identity.key')
          .writeAsBytesSync([0x08, 0x01, 0x12, 0x40]);
      expect(profileHasIdentity(tmp.path), isTrue);
    });

    test('a folder that does not exist holds no identity', () {
      expect(
        profileHasIdentity('${tmp.path}${Platform.pathSeparator}nope'),
        isFalse,
      );
    });
  });

  group('runningProfileRoot', () {
    test('reports a real, absolute path', () {
      final root = runningProfileRoot();
      expect(root, isNotEmpty);
      expect(sameProfilePath(root, root), isTrue);
    });
  });
}
