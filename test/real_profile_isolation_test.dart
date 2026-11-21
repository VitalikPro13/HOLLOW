/// #155 review: a suite run must never write the runner's real profile. The
/// global test config (flutter_test_config.dart) gives every test file its own
/// data root and registry anchor before any test runs.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';

void main() {
  test('tests never touch the real data root', () {
    final temp = Directory.systemTemp.path;
    expect(hollowDataDir, startsWith(temp), reason: 'the data root is not a throwaway one');
    expect(defaultDesktopDataRoot(), startsWith(temp),
        reason: 'the profile registry anchors at the real default root');
    expect(profileRegistryPath(), startsWith(temp));
  });
}
