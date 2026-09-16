import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard: every one-line preview goes through `messagePreviewText`.
///
/// A preview that prints raw message text leaks the wire tokens a message
/// carries, so a conversation list shows `[file:36517...]`, `[e:poggies:b816...]`
/// or `[a:g:2446...]` where a person expects "Photo", ":poggies:" or "GIF".
/// Each surface that grew its own half-fix knew about a different subset of the
/// tokens, which is why this is one helper and one rule.
///
/// Opt out with `// preview-ignore: <reason>` on the offending line.
void main() {
  const roots = ['lib/src/ui', 'lib/src/core/services'];

  /// Raw-text reads that are always a preview, wherever they appear.
  const banned = <String, String>{
    'lastMessage!.text': 'use messagePreviewText(m.text, attachment: ...)',
    'lastMessage.text': 'use messagePreviewText(m.text, attachment: ...)',
    'emoteTokensToShortcodes(':
        'gone; messagePreviewText covers emote, asset and file tokens',
  };

  /// The notification services must not re-derive a preview from the file
  /// sentinel: that is exactly the half-fix messagePreviewText replaces.
  const sentinelFreeFiles = [
    'lib/src/core/services/push_notification_service.dart',
    'lib/src/core/services/desktop_notification_service.dart',
  ];

  List<File> dartFilesUnder(String root) {
    final dir = Directory(root);
    expect(dir.existsSync(), isTrue,
        reason: 'expected to run from the project root ($root missing)');
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
  }

  test('no preview surface reads raw message text', () {
    final offenders = <String>[];
    for (final root in roots) {
      for (final file in dartFilesUnder(root)) {
        final lines = file.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.contains('preview-ignore:')) continue;
          for (final entry in banned.entries) {
            if (line.contains(entry.key)) {
              offenders.add('${file.path}:${i + 1}  ${entry.key} '
                  '(${entry.value})');
            }
          }
        }
      }
    }

    if (offenders.isNotEmpty) {
      fail('\nA preview reads the raw message text:\n\n'
          '${offenders.map((o) => '  $o').join('\n')}\n\n'
          'Call messagePreviewText (lib/src/core/message_preview.dart) so the '
          'file, emote and asset tokens all read as words.\n');
    }
  });

  test('the notification services build previews from the helper', () {
    for (final path in sentinelFreeFiles) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      final source = file.readAsStringSync();

      expect(source.contains('messagePreviewText('), isTrue,
          reason: '$path must build its preview lines with '
              'messagePreviewText');

      final lines = source.split('\n');
      final offenders = <String>[];
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('preview-ignore:')) continue;
        if (lines[i].contains("startsWith('[file:")) {
          offenders.add('$path:${i + 1}');
        }
      }
      expect(offenders, isEmpty,
          reason: 'a notification preview still branches on the file '
              'sentinel instead of calling messagePreviewText:\n'
              '${offenders.join('\n')}');
    }
  });
}
