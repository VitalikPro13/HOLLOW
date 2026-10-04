import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';

/// A wipe touches only its own profile: profiles.json loses that profile's entry
/// (never the whole file), a pin on it moves to another profile that still holds
/// an identity or clears, and the restart lands there. No FFI and no device.
void main() {
  final sep = Platform.pathSeparator;

  group('registryAfterWipe', () {
    const def = '/hollow/default';
    const a = '/hollow/a';
    const b = '/hollow/b';
    const both = ProfileRegistry(activePath: a, custom: [
      HollowProfile(name: 'A', path: a),
      HollowProfile(name: 'B', path: b),
    ]);

    test('forgets the wiped profile, keeps the others and moves to one of them',
        () {
      final next = registryAfterWipe(both, a,
          runningRoot: a,
          profilePaths: const [def, a, b],
          holdsIdentity: (p) => p == b);

      expect(next.custom.map((p) => p.name), ['B']);
      expect(next.activePath, b);
    });

    test('with no identity left anywhere the pin clears, so Welcome opens', () {
      final next = registryAfterWipe(both, a,
          runningRoot: a,
          profilePaths: const [def, a, b],
          holdsIdentity: (_) => false);

      expect(next.activePath, isNull);
      expect(next.custom.map((p) => p.name), ['B']);
    });

    test('the wiped profile is never chosen, even while it looks alive', () {
      final next = registryAfterWipe(both, a,
          runningRoot: a,
          profilePaths: const [a, def, b],
          holdsIdentity: (_) => true);

      expect(next.activePath, def);
    });

    test('an unpinned launch of the wiped profile moves to one with an identity',
        () {
      const unpinned = ProfileRegistry(custom: [HollowProfile(name: 'B', path: b)]);
      final next = registryAfterWipe(unpinned, def,
          runningRoot: def,
          profilePaths: const [def, b],
          holdsIdentity: (p) => p == b);

      expect(next.activePath, b);
      expect(next.custom.map((p) => p.name), ['B']);
    });

    test('erasing a profile that is not running leaves the pin alone', () {
      final pinned = registryAfterWipe(both, b,
          runningRoot: a,
          profilePaths: const [def, a, b],
          holdsIdentity: (_) => true);
      expect(pinned.activePath, a);
      expect(pinned.custom.map((p) => p.name), ['A']);

      final unpinned = registryAfterWipe(
          const ProfileRegistry(custom: [HollowProfile(name: 'B', path: b)]), b,
          runningRoot: def,
          profilePaths: const [def, b],
          holdsIdentity: (_) => true);
      expect(unpinned.activePath, isNull,
          reason: 'an automatic launch stays automatic');
      expect(unpinned.custom, isEmpty);
    });

    test('matches the wiped path the way the file system does', () {
      if (!Platform.isWindows) return;
      const reg = ProfileRegistry(
        activePath: r'C:\Hollow\Work',
        custom: [HollowProfile(name: 'Work', path: r'C:\Hollow\Work')],
      );
      final next = registryAfterWipe(reg, r'c:\hollow\work\',
          runningRoot: r'c:\hollow\work\',
          profilePaths: const [r'C:\Hollow\Work'],
          holdsIdentity: (_) => true);

      expect(next.custom, isEmpty);
      expect(next.activePath, isNull);
    });
  });

  group('after a wipe on this computer', () {
    late Directory tmp;
    late String defaultRoot;
    late String work;
    late String home;
    late int relaunched;
    late Completer<void> restarting;
    var unfinished = false;
    final never = Completer<Never>();
    final realUnfinished = wipeUnfinished;
    final realRelaunch = relaunchForWipe;

    void holdIdentity(String root) {
      Directory(root).createSync(recursive: true);
      File('$root${sep}identity.key').writeAsBytesSync([0x08, 0x01, 0x12, 0x40]);
    }

    File registryFile() => File('$defaultRoot${sep}profiles.json');

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hollow_profile_wipe');
      defaultRoot = '${tmp.path}${sep}default';
      work = '${tmp.path}${sep}work';
      home = '${tmp.path}${sep}home';
      Directory(defaultRoot).createSync();
      debugDefaultDesktopDataRoot = defaultRoot;
      relaunched = 0;
      restarting = Completer<void>();
      unfinished = false;
      wipeUnfinished = () async => unfinished;
      relaunchForWipe = () {
        relaunched++;
        restarting.complete();
        return never.future;
      };
    });

    tearDown(() {
      debugDefaultDesktopDataRoot = null;
      wipeUnfinished = realUnfinished;
      relaunchForWipe = realRelaunch;
      tmp.deleteSync(recursive: true);
    });

    bool runsOnTheDefaultRoot() {
      final env = Platform.environment['HOLLOW_DATA_DIR'];
      return (env == null || env.isEmpty) &&
          sameProfilePath(runningProfileRoot(), defaultRoot);
    }

    test('erasing another profile takes its entry and keeps the file', () async {
      holdIdentity(defaultRoot);
      await saveProfileRegistry(ProfileRegistry(custom: [
        HollowProfile(name: 'Work', path: work),
        HollowProfile(name: 'Home', path: home),
      ]));

      await forgetWipedProfile(work);

      final left = readProfileRegistrySync();
      expect(registryFile().existsSync(), isTrue);
      expect(left.custom.map((p) => p.name), ['Home']);
      expect(left.activePath, isNull);
    });

    test('a single-profile install never gets a profiles.json', () async {
      if (!runsOnTheDefaultRoot()) return;
      await forgetWipedProfile(defaultRoot);
      expect(registryFile().existsSync(), isFalse);
      expect(nextLaunchLeaves(defaultRoot), isFalse,
          reason: 'the only profile restarts at Welcome where it was');
    });

    test('a finished wipe forgets the profile, then restarts into another',
        () async {
      if (!runsOnTheDefaultRoot()) return;
      holdIdentity(work);
      await saveProfileRegistry(
          ProfileRegistry(custom: [HollowProfile(name: 'Work', path: work)]));

      unawaited(relaunchAfterWipe());
      await restarting.future;

      expect(relaunched, 1);
      final left = readProfileRegistrySync();
      expect(left.activePath, work, reason: 'the restart opens Work');
      expect(left.custom.map((p) => p.name), ['Work']);
      expect(nextLaunchLeaves(defaultRoot), isTrue);
    });

    test('an unfinished wipe restarts into the same profile so its boot wipe '
        'finishes first', () async {
      if (!runsOnTheDefaultRoot()) return;
      holdIdentity(work);
      final before =
          ProfileRegistry(custom: [HollowProfile(name: 'Work', path: work)]);
      await saveProfileRegistry(before);
      final saved = registryFile().readAsStringSync();
      unfinished = true;

      unawaited(relaunchAfterWipe());
      await restarting.future;

      expect(relaunched, 1);
      expect(registryFile().readAsStringSync(), saved);
      expect(nextLaunchLeaves(defaultRoot), isFalse);
    });

    test('the boot wipe of a destroyed profile restarts only when the next '
        'launch opens another one', () async {
      if (!runsOnTheDefaultRoot()) return;
      await settleProfileAfterBootWipe();
      expect(relaunched, 0, reason: 'the only profile goes on to Welcome');

      holdIdentity(work);
      await saveProfileRegistry(
          ProfileRegistry(custom: [HollowProfile(name: 'Work', path: work)]));
      unawaited(settleProfileAfterBootWipe());
      await restarting.future;
      expect(relaunched, 1);
      expect(readProfileRegistrySync().activePath, work);
    });
  });
}
