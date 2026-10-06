import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard: every Android resource Dart names by string is kept in release.
///
/// The release resource shrinker only sees references in Java/Kotlin and XML,
/// so a drawable named only from Dart is stripped from the APK, and
/// flutter_local_notifications then refuses every notification with
/// `invalid_icon` (#96).
void main() {
  test('Dart-named Android resources are listed in res/raw/keep.xml', () {
    final keep = File('android/app/src/main/res/raw/keep.xml');
    expect(keep.existsSync(), isTrue,
        reason: 'expected to run from the project root');
    final kept = keep.readAsStringSync();

    final named = RegExp(r'''['"]@(drawable|mipmap|raw)/(\w+)['"]''');
    final missing = <String>{};
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in dartFiles) {
      for (final m in named.allMatches(file.readAsStringSync())) {
        final ref = '@${m.group(1)}/${m.group(2)}';
        if (!kept.contains(ref)) missing.add('$ref (${file.path})');
      }
    }
    expect(missing, isEmpty,
        reason: 'add these to tools:keep in res/raw/keep.xml, or the release '
            'build strips them:\n${missing.join('\n')}');
  });
}
