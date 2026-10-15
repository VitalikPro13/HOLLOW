import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/profile_registry.dart';

// md-review
void main() {
  test(
      'a wipe forgets old data relinked from old data once its folder is gone',
      () {
    const reg = ProfileRegistry(custom: [
      HollowProfile(
          name: 'Old data from Oct 10, 2026',
          path: '/d/hollow-old-2026-10-10'),
      HollowProfile(
          name: 'Old data from Oct 11, 2026',
          path: '/d/hollow-old-2026-10-10-old-2026-10-11'),
    ]);
    final next = registryAfterWipe(reg, '/d/hollow',
        runningRoot: '/d/hollow',
        profilePaths: const ['/d/hollow'],
        holdsIdentity: (_) => false,
        folderExists: (_) => false);
    expect(next.custom, isEmpty,
        reason: 'an "Old data" row left after a duress wipe tells that a wipe ran');
  });
}
