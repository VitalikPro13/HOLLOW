/// #155: 0.12.1 to 0.14.1 shipped the build machine's `hollow_data\messages.db`
/// in the zip and the installer. The release script refuses such a Release folder
/// before it signs or packs anything, and the installer excludes it as well. The
/// guard's own cases run in scripts/release_payload_guard_selftest.ps1.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  test('the release script checks the Release folder before signing or packing',
      () {
    final src = read('scripts/build_release.ps1');
    final check = src.indexOf('Assert-ReleasePayloadClean \$releaseDir');
    expect(check, isNot(-1), reason: 'build_release.ps1 no longer runs the guard');
    expect(src.indexOf(". (Join-Path \$PSScriptRoot 'release_payload_guard.ps1')"),
        allOf(isNot(-1), lessThan(check)));
    for (final step in [
      "'sign_release.ps1') -Path \$releaseDir",
      '& \$iscc ',
      "[System.IO.Compression.ZipFile]::Open(\$zipPath, 'Create')",
    ]) {
      final at = src.indexOf(step);
      expect(at, isNot(-1), reason: '$step moved; recheck the guard order');
      expect(check, lessThan(at), reason: 'the guard runs after $step');
    }
    expect('Assert-ReleasePayloadClean'.allMatches(src).length, 1);
  });

  test('the installer leaves profile data and portable markers out', () {
    final iss = read('installer/hollow.iss');
    final m = RegExp(r'Source: "\{#SourceDir\}\\\*";[^\n]*\n\s*Excludes: "([^"]*)"')
        .firstMatch(iss);
    expect(m, isNotNull, reason: 'the Release folder Source line changed');
    final excludes = m!.group(1)!.split(',');
    for (final p in [
      r'\hollow_data\',
      '*.db',
      '*.db-wal',
      '*.db-shm',
      'hollow.lock',
      'identity.*',
      'portable',
      'portable.txt',
      'portable.txt.txt',
      '*.log',
    ]) {
      expect(excludes, contains(p), reason: 'hollow.iss Excludes lost $p');
    }
  });

  test('a silent uninstall answers the delete-data question with No', () {
    final iss = read('installer/hollow.iss');
    expect(iss, isNot(contains(' MsgBox(')),
        reason: 'a plain MsgBox ignores /SUPPRESSMSGBOXES and hangs a silent uninstall');
    expect(iss, contains('MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES'));
  });
}
