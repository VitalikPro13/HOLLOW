import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard: a Save dialog suggests a name someone else chose only through
/// `attachment_export.dart` (`pickSavePathFor`, `saveBytesFromPhone`).
///
/// iOS's picker writes `Documents/<name>` before its sheet opens, deleting
/// whatever is already there, so a received file named `hollow` or
/// `../Library/...` reached our own data with one tap on Save. The files listed
/// here suggest names built from constants or scrubbed on the spot.
void main() {
  const ownNames = {
    'lib/src/core/services/attachment_export.dart',
    'lib/src/ui/settings/about_section.dart',
    'lib/src/ui/settings/backup_section.dart',
    'lib/src/ui/settings/server_template.dart',
    'lib/src/ui/dialogs/export_to_file.dart',
    'lib/src/ui/chat/sticker_picker.dart',
  };

  bool callsPicker(File f) => f
      .readAsStringSync()
      .replaceAll(RegExp(r'\s'), '')
      .contains('FilePicker.platform.saveFile(');

  test('only own-named saves call the picker directly', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue,
        reason: 'expected to run from the project root');
    final offenders = <String>[];
    for (final f in lib.listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/src/rust/')) continue;
      if (!ownNames.contains(path) && callsPicker(f)) offenders.add(path);
    }
    expect(offenders, isEmpty,
        reason: 'a Save dialog seeded with a sender\'s name goes through '
            'pickSavePathFor or saveBytesFromPhone');
  });

  test('every listed file still calls the picker', () {
    final stale =
        ownNames.where((p) => !File(p).existsSync() || !callsPicker(File(p)));
    expect(stale, isEmpty, reason: 'drop stale entries from ownNames');
  });
}
