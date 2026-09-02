import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/wire_transfer_id.dart';

Uint8List _frame(String id) {
  // [type:1][id:64] with NUL padding, the way senders pack it.
  final buf = Uint8List(65);
  final bytes = utf8.encode(id);
  buf.setRange(1, 1 + bytes.length, bytes);
  return buf;
}

void main() {
  group('parseWireTransferId', () {
    test('accepts every id shape a Hollow sender produces', () {
      const hex32 = '0123456789abcdef0123456789abcdef';
      for (final id in [
        hex32,
        '$hex32:7', // share chunk / shard suffix
        'link_ABC123',
        'a-b_c',
        'a' * 64,
      ]) {
        expect(parseWireTransferId(_frame(id), 1), id, reason: id);
      }
    });

    test('rejects path characters so no temp file can leave the files dir',
        () {
      for (final id in [
        '/../../escaped',
        '../x',
        r'..\x',
        r'C:\x',
        'a/b',
        'a b',
        'a.b',
        '',
      ]) {
        expect(parseWireTransferId(_frame(id), 1), isNull, reason: id);
      }
    });

    test('rejects a field that is not UTF-8 instead of throwing', () {
      final buf = Uint8List(65);
      buf[1] = 0xff;
      buf[2] = 0xfe;
      expect(parseWireTransferId(buf, 1), isNull);
    });
  });
}
