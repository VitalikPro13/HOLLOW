import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

/// Issue #104: the bundled Noto Color Emoji is one large bitmap strike the
/// Windows renderer shrinks with jagged edges. Every Windows draws its own
/// vector Segoe UI Emoji first, with a flags-only Noto ahead of it (Segoe has
/// no flag glyphs and would print "UA" for a flag) and full Noto behind it for
/// anything newer than the system font.
void main() {
  List<String>? chain({bool windows = false, bool linux = false}) =>
      emojiFontFallbackFor(windows: windows, linux: linux);

  test('Windows leads with Segoe, flags from Noto first, Noto last', () {
    expect(chain(windows: true),
        ['NotoColorEmojiFlags', 'Segoe UI Emoji', 'NotoColorEmoji']);
  });

  test('Linux keeps Noto, other platforms their own emoji', () {
    expect(chain(linux: true), ['NotoColorEmoji']);
    expect(chain(), isNull);
  });

  test('every family in the chain except the system one is bundled', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final family
        in chain(windows: true)!.where((f) => f != 'Segoe UI Emoji')) {
      expect(pubspec, contains('- family: $family'));
    }
    expect(File('assets/fonts/NotoColorEmojiFlags.ttf').existsSync(), isTrue);
    // Small enough to be the flags alone, not a second copy of the font.
    expect(File('assets/fonts/NotoColorEmojiFlags.ttf').lengthSync(),
        lessThan(2 * 1024 * 1024));
  });
}
