import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Protocol ceiling, in UTF-8 bytes, of one message body once emote tokens
/// expand. Rust's `MAX_MESSAGE_BYTES` is the same number: every receiver drops a
/// longer message whole, so nothing Hollow sends may exceed it.
const int kMaxMessageBytes = 64 * 1024;

/// The UTF-8 size of [text], without encoding it.
int utf8ByteLength(String text) {
  var bytes = 0;
  for (final rune in text.runes) {
    bytes += utf8RuneLength(rune);
  }
  return bytes;
}

/// The UTF-8 size of one code point. A lone surrogate counts as the 3-byte
/// replacement character it becomes on the way to Rust.
int utf8RuneLength(int rune) => rune < 0x80
    ? 1
    : rune < 0x800
        ? 2
        : rune < 0x10000
            ? 3
            : 4;

/// Keeps a message body within [kMaxMessageBytes] as it is typed or pasted: an
/// insertion is cut to the whole characters that still fit, so a keystroke at
/// the ceiling does not land and a paste keeps its head. [measure] is the wire
/// size of a text (the composer counts an emote as its full token).
class MessageByteLimitFormatter extends TextInputFormatter {
  MessageByteLimitFormatter({this.measure = utf8ByteLength});

  final int Function(String text) measure;

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final newBytes = measure(newValue.text);
    if (newBytes <= kMaxMessageBytes || newBytes <= measure(oldValue.text)) {
      return newValue;
    }
    final before = oldValue.text.characters.toList();
    final after = newValue.text.characters.toList();
    final shorter = math.min(before.length, after.length);
    var head = 0;
    while (head < shorter && before[head] == after[head]) {
      head++;
    }
    var tail = 0;
    while (tail < shorter - head &&
        before[before.length - 1 - tail] == after[after.length - 1 - tail]) {
      tail++;
    }
    final prefix = after.take(head).join();
    final suffix = after.skip(after.length - tail).join();
    var budget = kMaxMessageBytes - measure(prefix) - measure(suffix);
    final kept = StringBuffer();
    for (final char in after.sublist(head, after.length - tail)) {
      final size = measure(char);
      if (size > budget) break;
      budget -= size;
      kept.write(char);
    }
    final caret = prefix.length + kept.length;
    return TextEditingValue(
      text: '$prefix$kept$suffix',
      selection: TextSelection.collapsed(offset: caret),
    );
  }
}
