import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/showcase_board.dart';

ShowcaseBlock _art(String hash, [String caption = '']) => ShowcaseBlock(
  type: ShowcaseBlockType.artwork,
  data: {'image': hash, if (caption.isNotEmpty) 'caption': caption},
);

void main() {
  test('a wide artwork round-trips with its place', () {
    final board = ShowcaseBoard(
      left: [_art('a' * 64)],
      wide: _art('b' * 64, 'Night shift'),
      wideAtTop: false,
    );
    final back = ShowcaseBoard.decode(board.encode());
    expect(back.wide?.artworkHash, 'b' * 64);
    expect(back.wide?.artworkCaption, 'Night shift');
    expect(back.wideAtTop, isFalse);
    expect(back.left, hasLength(1));
  });

  test(
    'a board holding only a wide artwork is not empty and keeps its asset',
    () {
      final board = ShowcaseBoard(wide: _art('c' * 64));
      expect(board.isEmpty, isFalse);
      expect(board.encode(), isNotEmpty);
      expect(board.referencedAssetHashes(), contains('c' * 64));
    },
  );

  test('wide defaults to the top and omits the key there', () {
    final encoded = ShowcaseBoard(wide: _art('d' * 64)).encode();
    expect(jsonDecode(encoded), isNot(contains('wideTop')));
    expect(ShowcaseBoard.decode(encoded).wideAtTop, isTrue);
  });

  test('anything but an artwork in the wide slot decodes as absent', () {
    final encoded = jsonEncode({
      'v': 1,
      'wide': {
        't': ShowcaseBlockType.text.wireId,
        'd': {'title': 'x', 'body': 'y'},
      },
    });
    expect(ShowcaseBoard.decode(encoded).wide, isNull);
  });

  test('a board from before the wide slot decodes unchanged', () {
    final encoded = jsonEncode({
      'v': 1,
      'left': [_art('e' * 64).toJson()],
    });
    final board = ShowcaseBoard.decode(encoded);
    expect(board.wide, isNull);
    expect(board.left, hasLength(1));
  });

  test('copyWith can clear the wide slot', () {
    final board = ShowcaseBoard(wide: _art('f' * 64));
    expect(board.copyWith(clearWide: true).wide, isNull);
    expect(board.copyWith().wide, isNotNull);
  });
}
