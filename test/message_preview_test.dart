import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/models/file_attachment.dart';

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hash2 =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

FileAttachment _att({
  required String name,
  required String ext,
  bool isImage = false,
}) =>
    FileAttachment(
      fileId: 'f1',
      fileName: name,
      fileExt: ext,
      mimeType: 'application/octet-stream',
      sizeBytes: 10,
      isImage: isImage,
      totalChunks: 1,
      isComplete: true,
    );

void main() {
  group('file token', () {
    test('becomes File when the attachment is unknown', () {
      expect(messagePreviewText('[file:36517abc]'), 'File');
    });

    test('becomes Photo for an image that is not a GIF', () {
      expect(
        messagePreviewText('[file:abc]',
            attachment: _att(name: 'cat.png', ext: 'png', isImage: true)),
        'Photo',
      );
    });

    test('becomes GIF for a gif attachment', () {
      expect(
        messagePreviewText('[file:abc]',
            attachment: _att(name: 'party.gif', ext: 'gif', isImage: true)),
        'GIF',
      );
    });

    test('becomes Video for every video extension', () {
      for (final ext in ['mp4', 'webm', 'mov', 'mkv', 'avi', 'm4v', 'MP4']) {
        expect(
          messagePreviewText('[file:abc]',
              attachment: _att(name: 'clip.$ext', ext: ext)),
          'Video',
          reason: ext,
        );
      }
    });

    test('becomes Voice message for both recorder name shapes', () {
      // The mobile display name and the desktop recorder's wire basename
      // (voice_message_recorder.dart), the pair isVoiceMessageFile pins.
      for (final name in [
        'Voice message.ogg',
        'voice_1729_ab12.ogg',
        'voice_1729.ogg',
      ]) {
        expect(
          messagePreviewText('[file:abc]',
              attachment: _att(name: name, ext: 'ogg')),
          'Voice message',
          reason: name,
        );
      }
    });

    test('a file that only looks like a voice note keeps its name', () {
      for (final att in [
        _att(name: 'Bohemian Rhapsody.mp3', ext: 'mp3'),
        _att(name: 'Voice message.exe', ext: 'exe'),
        _att(name: 'Voice message.mp3', ext: 'mp3'),
        _att(name: 'voice_1729.exe', ext: 'exe'),
      ]) {
        expect(
          messagePreviewText('[file:abc]', attachment: att),
          att.fileName,
          reason: att.fileName,
        );
      }
    });

    test('falls back to the file name for anything else', () {
      expect(
        messagePreviewText('[file:abc]',
            attachment: _att(name: 'contract.pdf', ext: 'pdf')),
        'contract.pdf',
      );
    });

    test('is replaced in place inside a caption', () {
      expect(
        messagePreviewText('look [file:abc] here',
            attachment: _att(name: 'cat.png', ext: 'png', isImage: true)),
        'look Photo here',
      );
    });
  });

  group('emote and asset tokens', () {
    test('emote token becomes its shortcode', () {
      expect(messagePreviewText('[e:poggies:$_hash]'), ':poggies:');
    });

    test('gif asset token becomes GIF and sticker becomes Sticker', () {
      expect(messagePreviewText('[a:g:$_hash:200:100]'), 'GIF');
      expect(messagePreviewText('[a:s:$_hash:160:160]'), 'Sticker');
    });

    test('a malformed token is left alone', () {
      expect(messagePreviewText('[e:BAD:$_hash]'), '[e:BAD:$_hash]');
    });

    test('mixed line keeps its words and collapses whitespace', () {
      expect(
        messagePreviewText(
            'hey [e:poggies:$_hash] look [a:g:$_hash2:200:100]\n\nnow'),
        'hey :poggies: look GIF now',
      );
    });
  });

  group('whitespace and empties', () {
    test('newlines and runs collapse to one space and trim', () {
      expect(messagePreviewText('  a\n\n\tb   c  '), 'a b c');
    });

    test('empty text with a known attachment shows its label', () {
      expect(
        messagePreviewText('',
            attachment: _att(name: 'cat.png', ext: 'png', isImage: true)),
        'Photo',
      );
      expect(
        messagePreviewText('   \n ',
            attachment: _att(name: 'clip.mp4', ext: 'mp4')),
        'Video',
      );
    });

    test('empty text with no attachment stays empty', () {
      expect(messagePreviewText(''), '');
      expect(messagePreviewText('   \n\n '), '');
    });

    test('text wins over the attachment label when there is a caption', () {
      expect(
        messagePreviewText('my cat',
            attachment: _att(name: 'cat.png', ext: 'png', isImage: true)),
        'my cat',
      );
    });
  });

  group('multi-line surfaces', () {
    test('singleLine false keeps the line breaks', () {
      expect(
        messagePreviewText('first line\nsecond line', singleLine: false),
        'first line\nsecond line',
      );
    });

    test('singleLine false still collapses spaces and tabs within a line', () {
      expect(
        messagePreviewText('  a\t\tb   c  \n   d  e ',
            singleLine: false),
        'a b c\nd e',
      );
    });

    test('singleLine false drops blank lines at both ends and in between', () {
      expect(
        messagePreviewText('\n\n  \nkeep\n\n\nme\n  \n\n',
            singleLine: false),
        'keep\nme',
      );
    });

    test('singleLine false replaces tokens the same way', () {
      expect(
        messagePreviewText('[a:s:$_hash:160:160]\n[file:abc]',
            singleLine: false),
        'Sticker\nFile',
      );
    });

    test('singleLine false on an empty text falls back to the label', () {
      expect(
        messagePreviewText('\n\n',
            attachment: _att(name: 'cat.png', ext: 'png', isImage: true),
            singleLine: false),
        'Photo',
      );
    });

    test('the default is still one line', () {
      expect(messagePreviewText('first\nsecond'), 'first second');
    });
  });

  group('house rules', () {
    test('no emoji glyph, em dash or trailing colon in a generated label', () {
      final outputs = [
        messagePreviewText('[file:abc]'),
        messagePreviewText('[file:abc]',
            attachment: _att(name: 'cat.png', ext: 'png', isImage: true)),
        messagePreviewText('[file:abc]',
            attachment: _att(name: 'Voice message.ogg', ext: 'ogg')),
        messagePreviewText('[a:s:$_hash:160:160]'),
        messagePreviewText('[a:g:$_hash:200:100]'),
      ];
      for (final out in outputs) {
        expect(out, isNot(contains('—')), reason: out);
        expect(out, isNot(contains('\u{1F4F7}')), reason: out);
        expect(out, isNot(contains('\u{1F4CE}')), reason: out);
        expect(out.endsWith(':'), isFalse, reason: out);
      }
    });

    test('running it twice changes nothing', () {
      final once = messagePreviewText('hey [e:poggies:$_hash]\nthere');
      expect(messagePreviewText(once), once);
    });
  });
}
