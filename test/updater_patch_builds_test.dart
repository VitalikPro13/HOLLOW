/// Quick-patch builds (`0.12.2+1`) and platform-aware update picking: the
/// manifest's `version` stays three-part for apps up to 0.12.1, the build rides
/// its own field, and an entry with no download for this platform is invisible.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/version_compare.dart';

ReleaseId rid(String s) => ReleaseId.parse(s)!;

VersionManifest manifest(List<Map<String, Object?>> entries) =>
    VersionManifest.fromJson(
        jsonDecode(jsonEncode({'latest': '0.12.2', 'versions': entries}))
            as Map<String, dynamic>);

const _all = {
  'url_windows': 'https://h/w.zip',
  'url_macos': 'https://h/m.zip',
  'url_linux': 'https://h/l.flatpak',
  'url_linux_targz': 'https://h/l.tar.gz',
};

void main() {
  tearDown(() {
    updaterPlatformOverride = null;
    linuxInstallKindOverride = null;
  });

  group('ReleaseId', () {
    test('orders by version, then build', () {
      expect(rid('0.12.2+1').isNewerThan(rid('0.12.2')), isTrue);
      expect(rid('0.12.3').isNewerThan(rid('0.12.2+9')), isTrue);
      expect(rid('0.12.2+2').isNewerThan(rid('0.12.2+1')), isTrue);
      expect(rid('0.12.2').isNewerThan(rid('0.12.2+1')), isFalse);
      expect(rid('0.12.2+0'), rid('0.12.2'));
      expect(rid('0.11'), rid('0.11.0'));
    });

    test('display and file tag', () {
      expect(rid('0.12.2').display, '0.12.2');
      expect(rid('0.12.2+1').display, '0.12.2+1');
      expect(rid('0.12.2').tag, '0.12.2');
      expect(rid('0.12.2+1').tag, '0.12.2-b1');
    });

    test('refuses what is not a version', () {
      for (final bad in ['', 'x', '0.12.2+', '0.12.2+x', '0.12.2+-1', '0.12.2++1', '0.12.x']) {
        expect(ReleaseId.parse(bad), isNull, reason: bad);
      }
      expect(ReleaseId.of('0.12.2', -1), isNull);
    });
  });

  group('picking the update', () {
    test('a malformed build or critical skips only its own entry', () {
      updaterPlatformOverride = 'windows';
      for (final bad in <Object?>['1', 1.5, -1, 10000, null, {'n': 1}]) {
        final m = manifest([
          {'version': '0.12.2', ..._all},
          {'version': '0.12.3', 'build': bad, ..._all},
        ]);
        expect(m.updateFor(rid('0.12.1'))?.display, '0.12.2', reason: '$bad');
        expect(m.installable.map((v) => v.display), ['0.12.2'], reason: '$bad');
      }
      final m = manifest([
        {'version': '0.12.2', ..._all},
        {'version': '0.12.3', 'critical': 'yes', ..._all},
        {'version': '0.12.4', 'url_windows': 7},
      ]);
      expect(m.updateFor(rid('0.12.1'))?.display, '0.12.2');
      expect(m.criticalFor(rid('0.12.1')), isFalse);
      final ok = manifest([
        {'version': '0.12.2', ..._all},
        {'version': '0.12.2', 'build': 9999, 'critical': true, ..._all},
      ]);
      expect(ok.updateFor(rid('0.12.1'))?.display, '0.12.2+9999');
    });

    // ReleaseId.of refuses a negative build too; this pins the entry's own check.
    test('a negative build makes its entry unreadable by itself', () {
      final bad = VersionInfo.fromJson({'version': '0.12.3', 'build': -1, ..._all});
      expect(bad.readable, isFalse);
      expect(bad.id, isNull);
      final ok = VersionInfo.fromJson({'version': '0.12.3', 'build': 0, ..._all});
      expect(ok.readable, isTrue);
    });

    test('a patch with a URL for this platform is offered over the release',
        () {
      updaterPlatformOverride = 'windows';
      final m = manifest([
        {'version': '0.12.2', ..._all},
        {'version': '0.12.2', 'build': 1, 'url_windows': 'https://h/w1.zip'},
      ]);
      expect(m.updateFor(rid('0.12.1'))!.display, '0.12.2+1');
      expect(m.updateFor(rid('0.12.2'))!.display, '0.12.2+1');
      expect(m.updateFor(rid('0.12.2+1')), isNull);
    });

    test('a patch without a URL for this platform is invisible', () {
      updaterPlatformOverride = 'macos';
      final m = manifest([
        {'version': '0.12.2', ..._all},
        {'version': '0.12.2', 'build': 1, 'url_windows': 'https://h/w1.zip'},
      ]);
      expect(m.updateFor(rid('0.12.1'))!.display, '0.12.2');
      expect(m.updateFor(rid('0.12.2')), isNull);
      expect(m.installable.map((v) => v.display), ['0.12.2']);
    });

    test('Linux picks by install kind', () {
      updaterPlatformOverride = 'linux';
      final m = manifest([
        {'version': '0.12.2', ..._all},
        {'version': '0.12.2', 'build': 1, 'url_linux': 'https://h/l1.flatpak'},
      ]);
      linuxInstallKindOverride = 'flatpak';
      expect(m.updateFor(rid('0.12.2'))!.display, '0.12.2+1');
      linuxInstallKindOverride = 'tarball';
      expect(m.updateFor(rid('0.12.2')), isNull);
    });

    test('phones never see a desktop download', () {
      updaterPlatformOverride = 'android';
      expect(manifest([{'version': '0.12.2', ..._all}]).updateFor(rid('0.12.1')),
          isNull);
    });

    test('an older entry never reads as an update', () {
      updaterPlatformOverride = 'windows';
      final m = manifest([{'version': '0.12.1', 'build': 3, ..._all}]);
      expect(m.updateFor(rid('0.12.2')), isNull);
    });

    test('the patch file name never collides with the release it patches', () {
      updaterPlatformOverride = 'windows';
      final m = manifest([
        {'version': '0.12.2', ..._all},
        {'version': '0.12.2', 'build': 1, ..._all},
      ]);
      expect(m.installable.map((v) => v.downloadFileName),
          ['0.12.2-b1.zip', '0.12.2.zip']);
    });

    test('critical counts when any newer installable entry carries it', () {
      updaterPlatformOverride = 'windows';
      final m = manifest([
        {'version': '0.12.2', 'critical': true, ..._all},
        {'version': '0.12.2', 'build': 1, ..._all},
        {'version': '0.12.3', 'critical': true, 'url_macos': 'https://h/m.zip'},
      ]);
      expect(m.criticalFor(rid('0.12.1')), isTrue);
      // Already past the critical release, and the critical 0.12.3 is macOS only.
      expect(m.criticalFor(rid('0.12.2')), isFalse);
      // A non-boolean flag is not critical (Rust refuses such a manifest anyway).
      expect(
          manifest([{'version': '0.12.2', 'critical': 'yes', ..._all}])
              .criticalFor(rid('0.12.1')),
          isFalse);
    });

    test('the running build shows its patch number', () {
      const s = UpdateState(currentVersion: '0.12.2', currentBuild: 1);
      expect(s.currentDisplay, '0.12.2+1');
      expect(const UpdateState(currentVersion: '0.12.2').currentDisplay,
          '0.12.2');
    });
  });

  group('changelog', () {
    const text = 'v0.12.2+1 - Desktop voice fix\n\nFIXES\n- Voice works again.\n\n'
        'v0.12.2 - Big release\n\nNEW\n- Something.\n';

    test('a +N header parses and describes only its own build', () {
      final releases = parseChangelog(text);
      expect(releases.map((r) => r.version), ['0.12.2+1', '0.12.2']);
      expect(releases[0].describes('0.12.2+1'), isTrue);
      expect(releases[0].describes('0.12.2'), isFalse);
      expect(releases[1].describes('0.12.2+1'), isFalse);
      expect(releases[1].describes('v0.12.2'), isTrue);
    });

    test('a patch without its own block falls back to the release', () {
      final releases = parseChangelog(text);
      expect(changelogIndexFor(releases, '0.12.2+1'), 0);
      expect(changelogIndexFor(releases, '0.12.2'), 1);
      expect(changelogIndexFor(releases, '0.12.2+2'), 1);
      expect(changelogIndexFor(releases, '0.12.3'), -1);
    });
  });
}
