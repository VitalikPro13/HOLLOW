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
    final flags = RegExp(r'Excludes: "[^"]*"; \\\n\s*Flags: ([^\n]*)').firstMatch(iss);
    expect(flags?.group(1), contains('recursesubdirs'));
    expect(flags!.group(1), isNot(contains('createallsubdirs')),
        reason: 'createallsubdirs creates an excluded hollow_data folder, empty');
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

  String body(String src, String head) {
    final start = src.indexOf(head);
    expect(start, isNot(-1), reason: '$head is gone');
    return src.substring(start, src.indexOf('\nend;', start));
  }

  test('an uninstall sets a profile in the app folder aside and brings it back',
      () {
    // Setups 0.12.1 to 0.14.1 logged hollow_data\messages.db for deletion.
    final iss = read('installer/hollow.iss');
    final steps = body(iss, 'procedure CurUninstallStepChanged(');
    final before = steps.indexOf('if CurUninstallStep = usUninstall then');
    final after = steps.indexOf('if CurUninstallStep = usPostUninstall then');
    expect(before, allOf(isNot(-1), lessThan(after)));
    final aside = steps.substring(before, after);
    expect(aside, contains('if IsSomeonesProfile(PortableDir) then'));
    expect(aside, contains('RenameFile(PortableDir, KeptDir)'));
    expect(aside, contains('while DirExists(KeptDir) or FileExists(KeptDir) do'),
        reason: 'an earlier kept folder must never block the move');
    expect(steps.substring(after), contains('RenameFile(KeptDir, PortableDir)'));
    final someones = body(iss, 'function IsSomeonesProfile(');
    expect(someones, contains('HoldsIdentity(Dir)'));
    expect(someones, contains("not IsShippedDb(Dir + '\\messages.db')"));
    expect(body(iss, 'function HoldsIdentity('), contains("'identity.*'"));
  });

  test('the installer removes only the shipped stray, never a profile', () {
    final iss = read('installer/hollow.iss');
    expect(body(iss, 'function PrepareToInstall('), contains('RemoveShippedStray;'));
    final remove = body(iss, 'procedure RemoveShippedStray;');
    final guard = remove.indexOf('if not DirExists(Dir) or HoldsIdentity(Dir) then');
    expect(guard, isNot(-1));
    expect(guard, lessThan(remove.indexOf('DeleteFile')));
    expect('DeleteFile('.allMatches(remove).length, 2);
    expect(remove, contains("if IsShippedDb(Dir + '\\messages.db') then\n    Removed := DeleteFile(Dir + '\\messages.db')"));
    expect(remove, contains("if IsShippedFile(Dir + '\\hollow.lock', 5, StrayLockSha256) then\n    Removed := DeleteFile(Dir + '\\hollow.lock')"));
    expect(remove, contains('if Removed then\n    RemoveDir(Dir);'),
        reason: 'an empty folder the person made is not the stray');
    expect(remove, isNot(contains('DelTree')));
    final shipped = body(iss, 'function IsShippedFile(');
    expect(shipped, contains('if Actual <> Size then'));
    expect(shipped, contains('CompareText(GetSHA256OfFile(Path), Sha256) = 0'));
    // One set of bytes: the app's own cleanup at start pins the same file.
    final dart = read('lib/src/core/hollow_data_dir.dart');
    final db = RegExp(r"StrayDbSha256 = '([0-9a-f]{64})'").firstMatch(iss)!.group(1)!;
    final lock = RegExp(r"StrayLockSha256 = '([0-9a-f]{64})'").firstMatch(iss)!.group(1)!;
    expect(dart, contains("'$db'"));
    expect(dart, contains("'$lock'"));
    expect(iss, contains('StrayDbSize = 475136;'));
    expect(dart, contains("ShippedStrayFile('messages.db', 475136,"));
  });
}

