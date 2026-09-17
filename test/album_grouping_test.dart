import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/album_grouping.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/models/file_attachment.dart';

class _M {
  final String id;
  final String sender;
  final String? album;
  final bool file;
  const _M(this.id, this.sender, {this.album, this.file = true});
}

AlbumCollapse<_M> _collapse(List<_M> ms) => collapseAlbums<_M>(
      ms,
      albumIdOf: (m) => m.album,
      messageIdOf: (m) => m.id,
      senderOf: (m) => m.sender,
      isGroupable: (m) => m.file,
    );

FileAttachment _att(String ext, {bool image = false}) => FileAttachment(
      fileId: 'f',
      fileName: 'x.$ext',
      fileExt: ext,
      mimeType: 'application/octet-stream',
      sizeBytes: 1,
      isImage: image,
      totalChunks: 1,
      isComplete: true,
    );

void main() {
  test('album id is a v4 UUID shape', () {
    final id = generateAlbumId();
    expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(id),
        isTrue);
    expect(generateAlbumId(), isNot(id));
  });

  test('a list without albums is returned as is', () {
    final ms = [const _M('a', 's'), const _M('b', 's')];
    expect(identical(_collapse(ms).display, ms), isTrue);
  });

  test('items fold into the earliest one, in order', () {
    final r = _collapse(const [
      _M('t', 'x', file: false),
      _M('a1', 's', album: 'A'),
      _M('o', 'y', file: false),
      _M('a2', 's', album: 'A'),
      _M('a3', 's', album: 'A'),
    ]);
    expect(r.display.map((m) => m.id), ['t', 'a1', 'o']);
    expect(r.itemsFor('a1')!.map((m) => m.id), ['a1', 'a2', 'a3']);
    expect(r.anchorIdByItemId['a3'], 'a1');
    expect(r.itemsFor('t'), isNull);
  });

  test('a lone loaded item renders as a plain message', () {
    final r = _collapse(const [_M('a1', 's', album: 'A'), _M('b', 's')]);
    expect(r.display.map((m) => m.id), ['a1', 'b']);
    expect(r.itemsFor('a1'), isNull);
  });

  test('the same album id from another sender never joins the group', () {
    final r = _collapse(const [
      _M('a1', 's', album: 'A'),
      _M('a2', 's', album: 'A'),
      _M('evil', 'm', album: 'A'),
    ]);
    expect(r.display.map((m) => m.id), ['a1', 'evil']);
    expect(r.itemsFor('a1')!.length, 2);
  });

  test('an eleventh item starts a second group', () {
    final ms = [for (var i = 0; i < 12; i++) _M('m$i', 's', album: 'A')];
    final r = _collapse(ms);
    expect(r.display.map((m) => m.id), ['m0', 'm10']);
    expect(r.itemsFor('m0')!.length, kMaxAlbumItems);
    expect(r.itemsFor('m10')!.length, 2);
  });

  test('non-file rows never group', () {
    final r = _collapse(const [
      _M('a1', 's', album: 'A', file: false),
      _M('a2', 's', album: 'A', file: false),
    ]);
    expect(r.display.length, 2);
  });

  group('album preview', () {
    test('counts photos, videos and files', () {
      expect(albumPreviewText([_att('webp', image: true), _att('webp', image: true)]),
          '2 photos');
      expect(albumPreviewText([_att('mp4'), _att('mov')]), '2 videos');
      expect(albumPreviewText([_att('webp', image: true), _att('mp4')]),
          '2 photos and videos');
      expect(albumPreviewText([_att('pdf'), _att('webp', image: true)]), '2 files');
    });

    test('a caption wins over the count', () {
      expect(
          albumPreviewText([_att('webp', image: true), _att('webp', image: true)],
              caption: 'Our trip'),
          'Our trip');
      expect(
          albumPreviewText([_att('webp', image: true), _att('webp', image: true)],
              caption: '[file:abc]'),
          '2 photos');
    });
  });
}
