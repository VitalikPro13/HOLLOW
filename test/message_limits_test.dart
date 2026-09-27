import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/message_limits.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

TextEditingValue _value(String text, [int? caret]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    );

void main() {
  test('utf8ByteLength agrees with the encoder', () {
    for (final s in [
      '',
      'hello',
      'привет',
      '你好',
      '👨‍👩‍👧‍👦',
      'z̷̢̛a̶l̸g̵o̴',
      'lone \uD83D surrogate',
    ]) {
      expect(utf8ByteLength(s), utf8.encode(s).length, reason: s);
    }
  });

  group('MessageByteLimitFormatter', () {
    final formatter = MessageByteLimitFormatter();
    final full = 'a' * kMaxMessageBytes;

    test('an edit that fits passes untouched', () {
      final next = _value('${'я' * 4000}!');
      expect(formatter.formatEditUpdate(_value(''), next), next);
    });

    test('a keystroke at the ceiling does not land', () {
      final out = formatter.formatEditUpdate(_value(full), _value('${full}b'));
      expect(out.text, full);
    });

    test('a paste keeps its head in whole characters and the text after it',
        () {
      final before = 'a' * (kMaxMessageBytes - 7);
      final old = _value('${before}END', before.length);
      final pasted = '👍👍👍';
      final out = formatter.formatEditUpdate(
          old, _value('$before${pasted}END', before.length + pasted.length));
      expect(out.text, '$before👍END');
      expect(utf8ByteLength(out.text), lessThanOrEqualTo(kMaxMessageBytes));
      expect(out.selection.baseOffset, before.length + '👍'.length);
    });

    test('shrinking an over-limit text is always allowed', () {
      final over = '${full}xyz';
      final out = formatter.formatEditUpdate(_value(over), _value('${full}x'));
      expect(out.text, '${full}x');
    });
  });

  test('the composer measures an emote as its full wire token', () {
    final c = EmoteComposerController();
    final p = c.placeholderFor('monkaw', _hash);
    c.text = 'hi $p я';
    expect(c.wireByteLength(c.text), utf8ByteLength(c.expandedText()));
    expect(c.wireByteLength('\uE0FF'), 0, reason: 'an unmapped placeholder');
  });

  test('the composer refuses a body receivers would drop', () {
    expect(composerSendRefusal('я' * 4000), isNull);
    expect(
        composerSendRefusal('[e:pog:$_hash] ' * 1000), kMessageTooLongMessage);
    const sticker = '[a:s:$_hash:200:200]';
    expect(composerSendRefusal('$sticker$sticker'), kAssetLimitMessage);
  });
}
