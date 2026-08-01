import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/chat/sticker_pack_card.dart';

void main() {
  group('isStickerPackFile', () {
    test('claims only the pack extension', () {
      expect(isStickerPackFile('autumn.hollow-pack'), isTrue);
      expect(isStickerPackFile('my stickers.hollow-pack'), isTrue);
      // Case is the OS's business, not ours — Windows will happily hand back
      // a capitalised name for a file we wrote in lower case.
      expect(isStickerPackFile('Autumn.HOLLOW-PACK'), isTrue);
    });

    test('does not claim the other hollow containers', () {
      // These have their own import paths; grabbing one here would render an
      // "Add to my stickers" button over an archive.
      expect(isStickerPackFile('chat.hollow-archive'), isFalse);
      expect(isStickerPackFile('server.hollow-shards'), isFalse);
      expect(isStickerPackFile('backup.hollow'), isFalse);
    });

    test('does not claim a mere substring', () {
      expect(isStickerPackFile('hollow-pack'), isFalse);
      expect(isStickerPackFile('hollow-pack.zip'), isFalse);
      expect(isStickerPackFile('notes about hollow-packs.txt'), isFalse);
      expect(isStickerPackFile(''), isFalse);
    });
  });
}
