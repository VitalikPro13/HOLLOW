/// AR-28: a file on disk reaches Flutter's decoder only through `AttachmentImage`
/// (Rust's image check first), never `Image.file` or `FileImage`, which decode any
/// bytes natively.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no widget decodes a file straight from disk', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.contains('/rust/')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('Image.file(') || line.contains('FileImage(')) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
