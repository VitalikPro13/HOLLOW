import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard (HOL-SEC-187): the macOS release script runs the load gate around
/// signing and signs the app without the library validation waiver.
///
/// `strip` must edit the binaries before anything is signed (the edit voids a
/// signature), `check` must run on every build before signing so a pod that
/// loads from outside the bundle fails early, and `signed` must judge the
/// finished signature. The script runs only on a Mac, so CI reads it here.
void main() {
  const path = 'scripts/build_macos_release.sh';

  final gate = RegExp(
    r'macos_load_gate\.sh"?\s+(strip|check|signed)\s+"?([^"\s]+)"?(\s+\S+)?',
  );
  final signCall = RegExp(r'^\s*(sign\s|codesign\s+--force\b)');

  late List<String> lines;
  setUpAll(() {
    final f = File(path);
    expect(
      f.existsSync(),
      isTrue,
      reason: 'expected to run from the project root',
    );
    lines = f
        .readAsLinesSync()
        .map((l) => l.trimLeft().startsWith('#') ? '' : l)
        .toList();
  });

  int firstWhere(bool Function(String) test, [int from = 0]) {
    for (var i = from; i < lines.length; i++) {
      if (test(lines[i])) return i;
    }
    return -1;
  }

  int lastWhere(bool Function(String) test) {
    for (var i = lines.length - 1; i >= 0; i--) {
      if (test(lines[i])) return i;
    }
    return -1;
  }

  bool gateCall(String l, String mode, [String? target]) {
    final m = gate.firstMatch(l);
    return m != null && m[1] == mode && (target == null || m[2] == target);
  }

  test('every build runs strip then check before the sign stage', () {
    final built = firstWhere((l) => l.contains('flutter build macos'));
    expect(built, isNot(-1));
    final staged = firstWhere((l) => RegExp(r'^\s*if runs sign\b').hasMatch(l));
    final signStart = staged != -1 ? staged : firstWhere(signCall.hasMatch);
    expect(signStart, greaterThan(built));
    final strip = firstWhere((l) => gateCall(l, 'strip'), built);
    expect(
      strip,
      allOf(isNot(-1), lessThan(signStart)),
      reason: 'the build itself must strip and check, not only a release',
    );
    final check = firstWhere((l) => gateCall(l, 'check'), strip);
    expect(check, allOf(isNot(-1), lessThan(signStart)));
  });

  test('the app is stripped and checked before its first signature', () {
    final firstSign = firstWhere(signCall.hasMatch);
    expect(firstSign, isNot(-1));
    final strip = lastWhere((l) => gateCall(l, 'strip', r'$APP'));
    expect(strip, allOf(isNot(-1), lessThan(firstSign)));
    final check = firstWhere((l) => gateCall(l, 'check', r'$APP'), strip);
    expect(check, allOf(isNot(-1), lessThan(firstSign)));
  });

  test('signed judges the app after its last signature', () {
    final appSign = lastWhere(
      (l) => signCall.hasMatch(l) && l.trimRight().endsWith(r'"$APP"'),
    );
    expect(appSign, isNot(-1));
    final signed = firstWhere((l) => gateCall(l, 'signed', r'$APP'), appSign);
    expect(
      signed,
      isNot(-1),
      reason: 'macos_load_gate.sh signed "\$APP" TEAM after the app is signed',
    );
    expect(
      gate.firstMatch(lines[signed])![3],
      isNotNull,
      reason: 'signed needs the team id',
    );
  });

  test('the app is signed with the entitlements minus the waiver', () {
    final withEnt = [
      for (var i = 0; i < lines.length; i++)
        if (signCall.hasMatch(lines[i]) && lines[i].contains('--entitlements'))
          i,
    ];
    expect(withEnt, isNotEmpty);
    for (final i in withEnt) {
      expect(
        lines[i],
        contains(r'--entitlements "$ENT_SHIP"'),
        reason: lines[i],
      );
    }
    final copy = firstWhere(
      (l) => RegExp(r'^\s*cp "\$ENT" "\$ENT_SHIP"').hasMatch(l),
    );
    final drop = firstWhere(
      (l) =>
          l.contains('PlistBuddy') &&
          l.contains(
            'Delete :com.apple.security.cs.disable-library-validation',
          ) &&
          l.contains(r'"$ENT_SHIP"'),
      copy == -1 ? 0 : copy,
    );
    expect(copy, isNot(-1));
    expect(drop, allOf(isNot(-1), lessThan(withEnt.first)));
  });
}
