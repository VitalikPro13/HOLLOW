import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard: every platform decodes peer video with the same mdk release.
///
/// Windows and Linux pin mdk in `third_party/mdk/mdk_pin.cmake`, Android in
/// `android/build.gradle.kts`, Apple through the checksummed Swift package of the
/// fvp version pub resolved. An fvp bump that moves only one of them ships two
/// different native parsers of untrusted bytes (0.14's first builds did).
void main() {
  String read(String path) {
    final f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path missing (run from the root)');
    return f.readAsStringSync();
  }

  String one(RegExp re, String text, String what) {
    final m = re.allMatches(text).toList();
    expect(m, hasLength(1), reason: 'expected exactly one $what');
    return m.single.group(1)!;
  }

  test('desktop, Android and Apple pin one mdk release', () {
    final cmake = read('third_party/mdk/mdk_pin.cmake');
    final desktop = one(
      RegExp(r'set\(HOLLOW_MDK_VERSION "([0-9.]+)"\)'),
      cmake,
      'HOLLOW_MDK_VERSION',
    );
    final digests = RegExp(
      r'set\(_hollow_mdk_sha256 "([0-9a-f]+)"\)',
    ).allMatches(cmake).map((m) => m.group(1)!).toList();
    expect(
      digests,
      hasLength(2),
      reason: 'one digest for Windows, one for Linux',
    );
    for (final d in digests) {
      expect(d, hasLength(64));
    }

    final gradle = read('android/build.gradle.kts');
    final android = one(
      RegExp(
        r'-DFVP_DEPS_URL=https://github\.com/wang-bin/mdk-sdk/releases/download/v([0-9.]+)"',
      ),
      gradle,
      'Android FVP_DEPS_URL',
    );
    one(
      RegExp(r'-DFVP_DEPS_SHA256=([0-9a-f]{64})"'),
      gradle,
      'Android FVP_DEPS_SHA256',
    );

    final config = jsonDecode(read('.dart_tool/package_config.json')) as Map;
    final fvp = (config['packages'] as List).cast<Map>().firstWhere(
      (p) => p['name'] == 'fvp',
    );
    var rootUri = fvp['rootUri'] as String;
    if (!rootUri.endsWith('/')) rootUri = '$rootUri/';
    final fvpRoot = Uri.parse(rootUri);
    final root = fvpRoot.isAbsolute
        ? fvpRoot
        : Directory('.dart_tool').absolute.uri.resolveUri(fvpRoot);
    final swift = read(root.resolve('darwin/fvp/Package.swift').toFilePath());
    final apple = one(
      RegExp(r'mdk-sdk/releases/download/v([0-9.]+)/mdk-sdk-apple\.zip'),
      swift,
      "fvp's Apple mdk binaryTarget",
    );

    expect(android, desktop, reason: 'Android mdk differs from desktop');
    expect(apple, desktop, reason: "fvp's Apple mdk differs from desktop");
  });
}
