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
        '$hex32:7', // share chunk
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

  group('rtcStreamIdFits', () {
    // One transfer's id, as Rust's file_stream_id / shard_stream_id derive it.
    final streamId = '0123456789abcdef' * 4;

    test('a file or shard stream opens only under a stream id', () {
      for (final kind in ['file', 'shard']) {
        expect(rtcStreamIdFits(kind, streamId), isTrue, reason: kind);
        for (final id in [
          '0123456789abcdef0123456789abcdef', // a bare file id
          streamId.toUpperCase(),
          '${streamId.substring(1)}g',
          '${streamId.substring(2)}:7',
          'link_ABC123',
        ]) {
          expect(rtcStreamIdFits(kind, id), isFalse, reason: '$kind $id');
        }
      }
    });

    test('a share chunk keeps its own id shape', () {
      const chunk = '0123456789abcdef0123456789abcdef:7';
      expect(rtcStreamIdFits('share_chunk', chunk), isTrue);
      expect(isStreamTransferId(chunk), isFalse);
      expect(parseWireTransferId(_frame(streamId), 1), streamId);
    });
  });
}
